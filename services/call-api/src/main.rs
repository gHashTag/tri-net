//! TRI-NET Internet directory and call-signaling adapter.
//!
//! Business policy is generated from `specs/*.t27`. This binary owns only
//! HTTP, cryptographic proof verification, SQLite persistence, and LiveKit
//! participant-token generation.

use std::{
    env, fs,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose, Engine as _};
use hmac::{Hmac, Mac};
use p256::{
    ecdsa::{
        signature::{Signer, Verifier},
        Signature, SigningKey, VerifyingKey,
    },
    pkcs8::DecodePrivateKey,
};
use rand_core::{OsRng, RngCore};
use reqwest::header::{HeaderMap as RequestHeaders, HeaderValue, AUTHORIZATION};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[path = "../../../gen/rust/account_identity.rs"]
mod account_identity;
#[path = "../../../gen/rust/group_chat.rs"]
mod group_chat;
#[path = "../../../gen/rust/internet_call.rs"]
mod internet_call;
#[path = "../../../gen/rust/nickname_directory.rs"]
mod nickname_directory;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
struct AppState {
    database: Arc<Mutex<Connection>>,
    configuration: Arc<Configuration>,
}

struct Configuration {
    bind: SocketAddr,
    livekit_url: String,
    livekit_api_key: String,
    livekit_api_secret: String,
    service_access_token: Option<String>,
    apns: Option<ApnsConfiguration>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApnsEnvironment {
    Sandbox,
    Production,
}

impl ApnsEnvironment {
    fn parse(value: &str) -> Result<Self, String> {
        match value.trim().to_ascii_lowercase().as_str() {
            "sandbox" | "development" => Ok(Self::Sandbox),
            "production" => Ok(Self::Production),
            _ => Err("APNs environment must be sandbox, development, or production".to_string()),
        }
    }

    fn as_database_value(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Production => "production",
        }
    }

    fn endpoint(self) -> &'static str {
        match self {
            Self::Sandbox => "https://api.sandbox.push.apple.com",
            Self::Production => "https://api.push.apple.com",
        }
    }

    fn alternate(self) -> Self {
        match self {
            Self::Sandbox => Self::Production,
            Self::Production => Self::Sandbox,
        }
    }
}

#[derive(Clone)]
struct ApnsConfiguration {
    team_id: String,
    key_id: String,
    bundle_id: String,
    fallback_environment: ApnsEnvironment,
    signing_key: SigningKey,
    client: reqwest::Client,
    provider_token_cache: Arc<Mutex<Option<CachedProviderToken>>>,
}

struct CachedProviderToken {
    value: String,
    issued_at: i64,
}

#[derive(Debug)]
struct ApnsDeliveryError {
    status: Option<u16>,
    permanent: bool,
    bad_device_token: bool,
    transient: bool,
    alternate_attempted: bool,
}

struct ApnsDeliverySuccess {
    environment: ApnsEnvironment,
    environment_changed: bool,
}

impl std::fmt::Display for ApnsDeliveryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.status {
            Some(status) => write!(
                formatter,
                "APNs request failed (status {status}, permanent={}, transient={}, alternate_attempted={})",
                self.permanent, self.transient, self.alternate_attempted
            ),
            None => write!(formatter, "APNs transport request failed"),
        }
    }
}

#[derive(Serialize)]
struct ApnsProviderHeader<'a> {
    alg: &'static str,
    kid: &'a str,
}

#[derive(Serialize)]
struct ApnsProviderClaims<'a> {
    iss: &'a str,
    iat: i64,
}

#[derive(Serialize)]
struct ApnsBackgroundContent {
    #[serde(rename = "content-available")]
    content_available: u8,
}

#[derive(Serialize)]
struct VoipPushPayload<'a> {
    aps: ApnsBackgroundContent,
    call_id: &'a str,
    call_uuid: &'a str,
    caller: &'a str,
    audio: bool,
    video: bool,
}

#[derive(Serialize)]
struct AlertPushAps<'a> {
    alert: AlertPushText<'a>,
    badge: u32,
    sound: &'a str,
    #[serde(rename = "thread-id", skip_serializing_if = "Option::is_none")]
    thread_id: Option<&'a str>,
}

#[derive(Serialize)]
struct AlertPushText<'a> {
    title: &'a str,
    body: &'a str,
}

#[derive(Serialize)]
struct AlertPushPayload<'a> {
    aps: AlertPushAps<'a>,
    #[serde(flatten)]
    data: serde_json::Value,
}

#[derive(Deserialize)]
struct ApnsErrorResponse {
    reason: Option<String>,
}

impl ApnsConfiguration {
    fn load_from_environment() -> Result<Option<Self>, String> {
        let team_id = optional_environment("TRINET_APNS_TEAM_ID");
        let key_id = optional_environment("TRINET_APNS_KEY_ID");
        let private_key_path = optional_environment("TRINET_APNS_PRIVATE_KEY_PATH");
        let configured = team_id.is_some() || key_id.is_some() || private_key_path.is_some();
        if !configured {
            return Ok(None);
        }
        let team_id = team_id.ok_or_else(|| {
            "missing required environment variable TRINET_APNS_TEAM_ID".to_string()
        })?;
        let key_id = key_id.ok_or_else(|| {
            "missing required environment variable TRINET_APNS_KEY_ID".to_string()
        })?;
        let private_key_path = private_key_path.ok_or_else(|| {
            "missing required environment variable TRINET_APNS_PRIVATE_KEY_PATH".to_string()
        })?;
        validate_apns_identifier("TRINET_APNS_TEAM_ID", &team_id)?;
        validate_apns_identifier("TRINET_APNS_KEY_ID", &key_id)?;
        let bundle_id =
            env::var("TRINET_APNS_BUNDLE_ID").unwrap_or_else(|_| "com.trinet.video".to_string());
        validate_bundle_id(&bundle_id)?;
        let fallback_environment = ApnsEnvironment::parse(
            &env::var("TRINET_APNS_ENVIRONMENT").unwrap_or_else(|_| "sandbox".to_string()),
        )?;
        let key_pem = fs::read_to_string(PathBuf::from(private_key_path))
            .map_err(|_| "could not read TRINET_APNS_PRIVATE_KEY_PATH".to_string())?;
        let signing_key = SigningKey::from_pkcs8_pem(&key_pem)
            .map_err(|_| "TRINET_APNS_PRIVATE_KEY_PATH is not an ES256 .p8 key".to_string())?;
        let client = reqwest::Client::builder()
            .http2_adaptive_window(true)
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| "could not initialize APNs HTTP client".to_string())?;
        Ok(Some(Self {
            team_id,
            key_id,
            bundle_id,
            fallback_environment,
            signing_key,
            client,
            provider_token_cache: Arc::new(Mutex::new(None)),
        }))
    }

    fn provider_token(&self, issued_at: i64) -> Result<String, String> {
        let mut cache = self
            .provider_token_cache
            .lock()
            .map_err(|_| "APNs provider-token cache is unavailable".to_string())?;
        if let Some(cached) = cache.as_ref() {
            let age = issued_at.saturating_sub(cached.issued_at);
            if (0..3000).contains(&age) {
                return Ok(cached.value.clone());
            }
        }
        let header = encode_json_url(&ApnsProviderHeader {
            alg: "ES256",
            kid: &self.key_id,
        })?;
        let claims = encode_json_url(&ApnsProviderClaims {
            iss: &self.team_id,
            iat: issued_at,
        })?;
        let unsigned = format!("{header}.{claims}");
        let signature: Signature = self.signing_key.sign(unsigned.as_bytes());
        let value = format!(
            "{unsigned}.{}",
            general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes())
        );
        *cache = Some(CachedProviderToken {
            value: value.clone(),
            issued_at,
        });
        Ok(value)
    }

    fn can_route_environment(&self, value: &str) -> bool {
        ApnsEnvironment::parse(value).is_ok()
    }

    async fn send_voip(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        call_id: &str,
        call_uuid: &str,
        caller: &str,
        audio: bool,
        video: bool,
    ) -> Result<ApnsDeliverySuccess, ApnsDeliveryError> {
        let payload = VoipPushPayload {
            aps: ApnsBackgroundContent {
                content_available: 1,
            },
            call_id,
            call_uuid,
            caller,
            audio,
            video,
        };
        self.send_with_environment_fallback(
            token,
            environment,
            &format!("{}.voip", self.bundle_id),
            "voip",
            "10",
            "0",
            Some(call_uuid),
            &payload,
        )
        .await
    }

    #[allow(dead_code)]
    async fn send_alert(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        title: &str,
        body: &str,
        badge: u32,
        sound: &str,
        thread_id: Option<&str>,
        data: serde_json::Value,
    ) -> Result<ApnsDeliverySuccess, ApnsDeliveryError> {
        let payload = AlertPushPayload {
            aps: AlertPushAps {
                alert: AlertPushText { title, body },
                badge,
                sound,
                thread_id,
            },
            data,
        };
        self.send_with_environment_fallback(
            token,
            environment,
            &self.bundle_id,
            "alert",
            "10",
            &unix_time().saturating_add(3600).to_string(),
            None,
            &payload,
        )
        .await
    }

    async fn send_with_environment_fallback<T: Serialize + ?Sized>(
        &self,
        token: &str,
        preferred_environment: ApnsEnvironment,
        topic: &str,
        push_type: &str,
        priority: &str,
        expiration: &str,
        apns_id: Option<&str>,
        payload: &T,
    ) -> Result<ApnsDeliverySuccess, ApnsDeliveryError> {
        match self
            .send_with_retry(
                token,
                preferred_environment,
                topic,
                push_type,
                priority,
                expiration,
                apns_id,
                payload,
            )
            .await
        {
            Ok(()) => Ok(ApnsDeliverySuccess {
                environment: preferred_environment,
                environment_changed: false,
            }),
            Err(error)
                if internet_call::apns_should_try_alternate_environment(
                    error.bad_device_token,
                    error.alternate_attempted,
                ) =>
            {
                let alternate = preferred_environment.alternate();
                match self
                    .send_with_retry(
                        token, alternate, topic, push_type, priority, expiration, apns_id, payload,
                    )
                    .await
                {
                    Ok(()) => Ok(ApnsDeliverySuccess {
                        environment: alternate,
                        environment_changed: true,
                    }),
                    Err(mut alternate_error) => {
                        alternate_error.alternate_attempted = true;
                        Err(alternate_error)
                    }
                }
            }
            Err(error) => Err(error),
        }
    }

    async fn send_with_retry<T: Serialize + ?Sized>(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        topic: &str,
        push_type: &str,
        priority: &str,
        expiration: &str,
        apns_id: Option<&str>,
        payload: &T,
    ) -> Result<(), ApnsDeliveryError> {
        let mut attempts_completed = 0_u32;
        loop {
            attempts_completed = attempts_completed.saturating_add(1);
            match self
                .send_once(
                    token,
                    environment,
                    topic,
                    push_type,
                    priority,
                    expiration,
                    apns_id,
                    payload,
                )
                .await
            {
                Ok(()) => return Ok(()),
                Err(error)
                    if internet_call::apns_should_retry(error.transient, attempts_completed) =>
                {
                    let jitter = OsRng.next_u32() % (internet_call::APNS_RETRY_MAX_JITTER_MS + 1);
                    let delay = internet_call::apns_retry_delay_ms(attempts_completed, jitter);
                    tokio::time::sleep(Duration::from_millis(u64::from(delay))).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn send_once<T: Serialize + ?Sized>(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        topic: &str,
        push_type: &str,
        priority: &str,
        expiration: &str,
        apns_id: Option<&str>,
        payload: &T,
    ) -> Result<(), ApnsDeliveryError> {
        if !valid_apns_token(token) {
            return Err(ApnsDeliveryError {
                status: None,
                permanent: true,
                bad_device_token: false,
                transient: false,
                alternate_attempted: false,
            });
        }
        let provider_token = self
            .provider_token(unix_time())
            .map_err(|_| ApnsDeliveryError {
                status: None,
                permanent: false,
                bad_device_token: false,
                transient: false,
                alternate_attempted: false,
            })?;
        let mut headers = RequestHeaders::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("bearer {provider_token}")).map_err(|_| {
                ApnsDeliveryError {
                    status: None,
                    permanent: false,
                    bad_device_token: false,
                    transient: false,
                    alternate_attempted: false,
                }
            })?,
        );
        for (name, value) in [
            ("apns-topic", topic),
            ("apns-push-type", push_type),
            ("apns-priority", priority),
            ("apns-expiration", expiration),
        ] {
            headers.insert(
                reqwest::header::HeaderName::from_static(name),
                HeaderValue::from_str(value).map_err(|_| ApnsDeliveryError {
                    status: None,
                    permanent: false,
                    bad_device_token: false,
                    transient: false,
                    alternate_attempted: false,
                })?,
            );
        }
        if let Some(apns_id) = apns_id {
            headers.insert(
                reqwest::header::HeaderName::from_static("apns-id"),
                HeaderValue::from_str(apns_id).map_err(|_| ApnsDeliveryError {
                    status: None,
                    permanent: false,
                    bad_device_token: false,
                    transient: false,
                    alternate_attempted: false,
                })?,
            );
        }
        let response = self
            .client
            .post(format!("{}/3/device/{token}", environment.endpoint()))
            .headers(headers)
            .json(payload)
            .send()
            .await
            .map_err(|_| ApnsDeliveryError {
                status: None,
                permanent: false,
                bad_device_token: false,
                transient: internet_call::apns_delivery_failure_is_retryable(true, 0),
                alternate_attempted: false,
            })?;
        if response.status().is_success() {
            return Ok(());
        }
        let status = response.status();
        let reason = response
            .json::<ApnsErrorResponse>()
            .await
            .ok()
            .and_then(|body| body.reason)
            .unwrap_or_else(|| "unknown".to_string());
        let permanent = apns_failure_is_permanent(&reason);
        let bad_device_token = reason == "BadDeviceToken";
        let status_code = u32::from(status.as_u16());
        Err(ApnsDeliveryError {
            status: Some(status.as_u16()),
            permanent,
            bad_device_token,
            transient: internet_call::apns_delivery_failure_is_retryable(false, status_code),
            alternate_attempted: false,
        })
    }
}

impl Configuration {
    fn load() -> Result<(Self, String), String> {
        let bind = env::var("TRINET_BIND")
            .unwrap_or_else(|_| "127.0.0.1:8080".to_string())
            .parse()
            .map_err(|error| format!("invalid TRINET_BIND: {error}"))?;
        let database_path =
            env::var("TRINET_DB_PATH").unwrap_or_else(|_| "trinet-call.db".to_string());
        let livekit_url = required_environment("TRINET_LIVEKIT_URL")?;
        let livekit_api_key = required_environment("LIVEKIT_API_KEY")?;
        let livekit_api_secret = required_environment("LIVEKIT_API_SECRET")?;
        let service_access_token = env::var("TRINET_SERVICE_ACCESS_TOKEN")
            .ok()
            .filter(|value| !value.is_empty());
        let apns = ApnsConfiguration::load_from_environment()?;
        Ok((
            Self {
                bind,
                livekit_url,
                livekit_api_key,
                livekit_api_secret,
                service_access_token,
                apns,
            },
            database_path,
        ))
    }
}

fn required_environment(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable {name}"))
}

fn optional_environment(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.is_empty())
}

fn validate_apns_identifier(name: &str, value: &str) -> Result<(), String> {
    if value.len() > 64 || !value.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        return Err(format!(
            "{name} must contain only ASCII letters and numbers"
        ));
    }
    Ok(())
}

fn validate_bundle_id(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 255
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-')
    {
        return Err("TRINET_APNS_BUNDLE_ID must be a valid ASCII bundle identifier".to_string());
    }
    Ok(())
}

fn valid_apns_token(value: &str) -> bool {
    (32..=256).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn apns_failure_is_permanent(reason: &str) -> bool {
    matches!(
        reason,
        "BadDeviceToken" | "DeviceTokenNotForTopic" | "Unregistered"
    )
}

fn normalize_apns_token(value: Option<&str>) -> Result<Option<String>, ApiError> {
    let token = value.map(str::trim).filter(|value| !value.is_empty());
    match token {
        Some(value) if valid_apns_token(value) => Ok(Some(value.to_ascii_lowercase())),
        Some(_) => Err(ApiError::bad_request("invalid APNs device token")),
        None => Ok(None),
    }
}

fn encode_json_url<T: Serialize + ?Sized>(value: &T) -> Result<String, String> {
    serde_json::to_vec(value)
        .map(|bytes| general_purpose::URL_SAFE_NO_PAD.encode(bytes))
        .map_err(|_| "could not encode APNs provider token".to_string())
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.into(),
        }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
        }
    }

    fn conflict(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, self.message).into_response()
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        Self::internal(format!("database error: {error}"))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct DeviceRegistrationRequest {
    user_id: String,
    device_id: String,
    display_name: String,
    signing_public_key: String,
    key_fingerprint: String,
    platform: String,
    voip_push_token: Option<String>,
    alert_push_token: Option<String>,
    push_environment: Option<String>,
    capabilities: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct NicknameClaimRequest {
    nickname: String,
    user_id: String,
    device_id: String,
}

#[derive(Serialize)]
struct NicknameClaimResponse {
    claimed: bool,
    normalized: String,
    reason: Option<String>,
    suggestions: Vec<String>,
}

#[derive(Deserialize)]
struct NicknameSearchRequest {
    query: String,
    limit: usize,
}

#[derive(Serialize)]
struct NicknameSearchResponse {
    results: Vec<DirectoryContact>,
}

#[derive(Serialize)]
struct DirectoryContact {
    user_id: String,
    device_id: String,
    nickname: String,
    display_name: Option<String>,
    key_fingerprint: String,
    online: bool,
    device_count: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct CreateCallRequest {
    callee: String,
    caller_user_id: String,
    caller_device_id: String,
    audio: bool,
    video: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct JoinCallRequest {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct EndCallRequest {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct IncomingCallsRequest {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct AccountRequest {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct LinkDeviceRequest {
    user_id: String,
    device_id: String,
    link_code: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct RevokeDeviceRequest {
    user_id: String,
    device_id: String,
}

#[derive(Serialize)]
struct LinkCodeResponse {
    link_code: String,
    expires_at: i64,
}

#[derive(Serialize)]
struct AccountSnapshotResponse {
    account_id: String,
    nickname: Option<String>,
    devices: Vec<AccountDeviceSummary>,
}

#[derive(Serialize)]
struct AccountDeviceSummary {
    device_id: String,
    display_name: String,
    platform: String,
    key_fingerprint: String,
    last_seen: i64,
    current: bool,
    revoked: bool,
}

#[derive(Serialize)]
struct IncomingCallsResponse {
    calls: Vec<IncomingCall>,
}

#[derive(Serialize)]
struct IncomingCall {
    call_id: String,
    call_uuid: String,
    caller: String,
    audio: bool,
    video: bool,
    created_at: i64,
}

struct CallTarget {
    device_id: String,
    capabilities: u8,
    last_seen: i64,
    voip_push_token: Option<String>,
    push_environment: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct CreateGroupChatRequest {
    creator_user_id: String,
    creator_device_id: String,
    title: Option<String>,
    members: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct GroupChatsRequest {
    user_id: String,
    device_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct SendGroupMessageRequest {
    user_id: String,
    device_id: String,
    client_message_id: String,
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct GroupMessagesRequest {
    user_id: String,
    device_id: String,
    after_message_id: i64,
    limit: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct MarkGroupChatReadRequest {
    user_id: String,
    device_id: String,
    through_message_id: i64,
}

#[derive(Serialize)]
struct GroupChatsResponse {
    chats: Vec<GroupChatSummary>,
    total_unread_count: u32,
}

#[derive(Serialize)]
struct GroupChatSummary {
    chat_id: String,
    title: String,
    members: Vec<String>,
    created_at: i64,
    last_message: Option<String>,
    last_message_at: Option<i64>,
    unread_count: u32,
}

#[derive(Serialize)]
struct GroupMessagesResponse {
    messages: Vec<GroupChatMessage>,
}

#[derive(Serialize)]
struct GroupChatMessage {
    message_id: i64,
    chat_id: String,
    sender_user_id: String,
    sender_nickname: String,
    text: String,
    created_at: i64,
}

#[derive(Serialize)]
struct InternetCallSession {
    call_id: String,
    room_id: String,
    livekit_url: String,
    token: String,
    media_key: Option<String>,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Clone)]
struct AuthenticatedDevice {
    user_id: String,
    device_id: String,
    display_name: String,
    capabilities: u8,
}

#[derive(Serialize)]
struct LiveKitClaims<'a> {
    iss: &'a str,
    sub: &'a str,
    name: &'a str,
    nbf: i64,
    exp: i64,
    video: LiveKitVideoGrant<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveKitVideoGrant<'a> {
    room_join: bool,
    room: &'a str,
    can_publish: bool,
    can_subscribe: bool,
    can_publish_data: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let (configuration, database_path) =
        Configuration::load().map_err(|error| format!("configuration error: {error}"))?;
    let bind = configuration.bind;
    let connection = Connection::open(database_path)?;
    initialize_database(&connection)?;
    let state = AppState {
        database: Arc::new(Mutex::new(connection)),
        configuration: Arc::new(configuration),
    };

    let application = application(state);

    let listener = tokio::net::TcpListener::bind(bind).await?;
    println!("TRI-NET call API listening on {bind}");
    axum::serve(listener, application)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

fn application(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/devices/register", post(register_device))
        .route("/v1/account", post(account_snapshot))
        .route("/v1/account/link-code", post(create_link_code))
        .route("/v1/account/link", post(link_device))
        .route(
            "/v1/account/devices/{device_id}/revoke",
            post(revoke_device),
        )
        .route("/v1/directory/nicknames/claim", post(claim_nickname))
        .route("/v1/directory/search", post(search_nicknames))
        .route("/v1/calls", post(create_call))
        .route("/v1/calls/incoming", post(incoming_calls))
        .route("/v1/calls/{call_id}/join", post(join_call))
        .route("/v1/calls/{call_id}/cancel", post(cancel_call))
        .route("/v1/chats", post(create_group_chat))
        .route("/v1/chats/list", post(list_group_chats))
        .route("/v1/chats/{chat_id}/messages", post(send_group_message))
        .route(
            "/v1/chats/{chat_id}/messages/list",
            post(list_group_messages),
        )
        .route("/v1/chats/{chat_id}/read", post(mark_group_chat_read))
        .with_state(state)
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

fn initialize_database(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;
         CREATE TABLE IF NOT EXISTS accounts (
             user_id TEXT PRIMARY KEY,
             created_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS devices (
             device_id TEXT PRIMARY KEY,
             user_id TEXT NOT NULL,
             display_name TEXT NOT NULL,
             signing_public_key TEXT NOT NULL,
             key_fingerprint TEXT NOT NULL,
             platform TEXT NOT NULL,
             voip_push_token TEXT,
             alert_push_token TEXT,
             push_environment TEXT NOT NULL DEFAULT 'sandbox',
             capabilities INTEGER NOT NULL,
             last_seen INTEGER NOT NULL,
             linked_at INTEGER NOT NULL DEFAULT 0,
             revoked_at INTEGER
         );
         CREATE INDEX IF NOT EXISTS devices_user_id ON devices(user_id);
         CREATE TABLE IF NOT EXISTS nicknames (
             nickname TEXT PRIMARY KEY,
             user_id TEXT NOT NULL,
             device_id TEXT NOT NULL UNIQUE REFERENCES devices(device_id),
             updated_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS calls (
             call_id TEXT PRIMARY KEY,
             call_uuid TEXT NOT NULL,
             room_id TEXT NOT NULL UNIQUE,
             caller_user_id TEXT NOT NULL,
             caller_device_id TEXT NOT NULL,
             callee_user_id TEXT NOT NULL,
             callee_device_id TEXT NOT NULL,
             caller_name TEXT NOT NULL,
             audio INTEGER NOT NULL,
             video INTEGER NOT NULL,
             status INTEGER NOT NULL,
             created_at INTEGER NOT NULL,
             answered_at INTEGER,
             answered_device_id TEXT
         );
         CREATE INDEX IF NOT EXISTS calls_callee_status
             ON calls(callee_device_id, status, created_at);
         CREATE TABLE IF NOT EXISTS call_targets (
             call_id TEXT NOT NULL REFERENCES calls(call_id),
             device_id TEXT NOT NULL REFERENCES devices(device_id),
             state INTEGER NOT NULL,
             PRIMARY KEY(call_id, device_id)
         );
         CREATE INDEX IF NOT EXISTS call_targets_device_state
             ON call_targets(device_id, state);
         CREATE TABLE IF NOT EXISTS device_link_codes (
             code_hash TEXT PRIMARY KEY,
             user_id TEXT NOT NULL,
             created_by_device_id TEXT NOT NULL,
             created_at INTEGER NOT NULL,
             expires_at INTEGER NOT NULL,
             consumed_at INTEGER
         );
         CREATE TABLE IF NOT EXISTS request_nonces (
             device_id TEXT NOT NULL,
             nonce TEXT NOT NULL,
             expires_at INTEGER NOT NULL,
             PRIMARY KEY(device_id, nonce)
         );
         CREATE TABLE IF NOT EXISTS group_chats (
             chat_id TEXT PRIMARY KEY,
             title TEXT NOT NULL,
             created_by_user_id TEXT NOT NULL,
             created_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS group_chat_members (
             chat_id TEXT NOT NULL REFERENCES group_chats(chat_id),
             user_id TEXT NOT NULL,
             nickname TEXT NOT NULL,
             joined_at INTEGER NOT NULL,
             left_at INTEGER,
             PRIMARY KEY(chat_id, user_id)
         );
         CREATE INDEX IF NOT EXISTS group_chat_members_user
             ON group_chat_members(user_id, left_at, chat_id);
         CREATE TABLE IF NOT EXISTS group_chat_messages (
             message_id INTEGER PRIMARY KEY AUTOINCREMENT,
             chat_id TEXT NOT NULL REFERENCES group_chats(chat_id),
             sender_user_id TEXT NOT NULL,
             sender_device_id TEXT NOT NULL,
             sender_nickname TEXT NOT NULL,
             client_message_id TEXT NOT NULL,
             text TEXT NOT NULL,
             created_at INTEGER NOT NULL,
             UNIQUE(chat_id, sender_device_id, client_message_id)
         );
         CREATE INDEX IF NOT EXISTS group_chat_messages_chat
             ON group_chat_messages(chat_id, message_id);
         CREATE TABLE IF NOT EXISTS group_chat_read_state (
             chat_id TEXT NOT NULL REFERENCES group_chats(chat_id),
             user_id TEXT NOT NULL,
             last_read_message_id INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY(chat_id, user_id)
         );",
    )?;
    ensure_column(
        connection,
        "devices",
        "linked_at",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(connection, "devices", "revoked_at", "INTEGER")?;
    ensure_column(connection, "devices", "alert_push_token", "TEXT")?;
    ensure_column(
        connection,
        "devices",
        "push_environment",
        "TEXT NOT NULL DEFAULT 'sandbox'",
    )?;
    ensure_column(connection, "calls", "answered_device_id", "TEXT")?;
    ensure_column(connection, "calls", "call_uuid", "TEXT")?;
    connection.execute(
        "UPDATE calls
         SET call_uuid =
             substr(call_id, 6, 8) || '-' ||
             substr(call_id, 14, 4) || '-' ||
             substr(call_id, 18, 4) || '-' ||
             substr(call_id, 22, 4) || '-' ||
             substr(call_id, 26, 12)
         WHERE call_uuid IS NULL AND length(call_id) = 37
           AND call_id LIKE 'call_%'",
        [],
    )?;
    connection.execute(
        "INSERT OR IGNORE INTO accounts(user_id, created_at)
         SELECT DISTINCT user_id, ?1 FROM devices",
        params![unix_time()],
    )?;
    connection.execute(
        "UPDATE devices SET linked_at = last_seen WHERE linked_at = 0",
        [],
    )?;
    Ok(())
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    declaration: &str,
) -> rusqlite::Result<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|name| name == column) {
        connection.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {declaration}"),
            [],
        )?;
    }
    Ok(())
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let request: DeviceRegistrationRequest = decode_json(&body)?;
    let voip_push_token = normalize_apns_token(request.voip_push_token.as_deref())?;
    let alert_push_token = normalize_apns_token(request.alert_push_token.as_deref())?;
    let push_environment = match request.push_environment.as_deref() {
        Some(value) => ApnsEnvironment::parse(value).map_err(ApiError::bad_request)?,
        None => state
            .configuration
            .apns
            .as_ref()
            .map(|configuration| configuration.fallback_environment)
            .unwrap_or(ApnsEnvironment::Sandbox),
    };
    let public_key = decode_public_key(&request.signing_public_key)?;
    let actual_fingerprint = fingerprint(&public_key);
    if actual_fingerprint != request.key_fingerprint {
        return Err(ApiError::bad_request("public-key fingerprint mismatch"));
    }
    let capabilities = capability_bits(&request.capabilities);
    if !internet_call::device_is_valid(
        stable_id(&request.user_id),
        stable_id(&request.device_id),
        stable_id(&request.key_fingerprint),
        capabilities,
    ) || !internet_call::supports_internet_call(capabilities)
    {
        return Err(ApiError::bad_request(
            "device must support audio and WebRTC",
        ));
    }

    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/devices/register",
        &body,
        Some((&request.user_id, &request.signing_public_key)),
    )?;
    if auth.device_id != request.device_id || auth.user_id != request.user_id {
        return Err(ApiError::forbidden(
            "device identity does not match request",
        ));
    }

    let now = unix_time();
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let registered_user = transaction
        .query_row(
            "SELECT user_id FROM devices WHERE device_id = ?1",
            params![request.device_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let existing_members = transaction.query_row(
        "SELECT COUNT(*) FROM devices
         WHERE user_id = ?1 AND revoked_at IS NULL AND device_id != ?2",
        params![request.user_id, request.device_id],
        |row| row.get::<_, u16>(0),
    )?;
    if registered_user.is_none() && existing_members > 0 {
        return Err(ApiError::forbidden(
            "account already has devices; use a trusted-device link code",
        ));
    }
    transaction.execute(
        "INSERT OR IGNORE INTO accounts(user_id, created_at) VALUES (?1, ?2)",
        params![request.user_id, now],
    )?;
    transaction.execute(
        "INSERT INTO devices
         (device_id, user_id, display_name, signing_public_key, key_fingerprint,
          platform, voip_push_token, alert_push_token, push_environment,
          capabilities, last_seen, linked_at, revoked_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11, NULL)
         ON CONFLICT(device_id) DO UPDATE SET
           display_name = excluded.display_name,
           platform = excluded.platform,
           voip_push_token = excluded.voip_push_token,
           alert_push_token = excluded.alert_push_token,
           push_environment = excluded.push_environment,
           capabilities = excluded.capabilities,
           last_seen = excluded.last_seen",
        params![
            request.device_id,
            request.user_id,
            request.display_name,
            request.signing_public_key,
            request.key_fingerprint,
            request.platform,
            voip_push_token,
            alert_push_token,
            push_environment.as_database_value(),
            capabilities,
            now,
        ],
    )?;
    transaction.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

async fn account_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<AccountSnapshotResponse>, ApiError> {
    let request: AccountRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/account", &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let database = lock_database(&state)?;
    Ok(Json(load_account_snapshot(&database, &auth)?))
}

async fn create_link_code(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<LinkCodeResponse>, ApiError> {
    let request: AccountRequest = decode_json(&body)?;
    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/account/link-code",
        &body,
        None,
    )?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let now = unix_time();
    let expires_at = now + i64::from(account_identity::LINK_CODE_TTL_SECONDS);
    let link_code = random_id("link_");
    let code_hash = lowercase_hex(&Sha256::digest(link_code.as_bytes()));
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute(
        "DELETE FROM device_link_codes
         WHERE expires_at < ?1 OR created_by_device_id = ?2",
        params![now, auth.device_id],
    )?;
    transaction.execute(
        "INSERT INTO device_link_codes
         (code_hash, user_id, created_by_device_id, created_at, expires_at, consumed_at)
         VALUES (?1, ?2, ?3, ?4, ?5, NULL)",
        params![code_hash, auth.user_id, auth.device_id, now, expires_at],
    )?;
    transaction.commit()?;
    Ok(Json(LinkCodeResponse {
        link_code,
        expires_at,
    }))
}

async fn link_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<AccountSnapshotResponse>, ApiError> {
    let request: LinkDeviceRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/account/link", &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    if request.link_code.len() != 37 || !request.link_code.starts_with("link_") {
        return Err(ApiError::bad_request("invalid link code"));
    }
    let code_hash = lowercase_hex(&Sha256::digest(request.link_code.as_bytes()));
    let now = unix_time();
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let code = transaction
        .query_row(
            "SELECT user_id, created_at, expires_at, consumed_at
             FROM device_link_codes WHERE code_hash = ?1",
            params![code_hash],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| ApiError::forbidden("link code is invalid"))?;
    if code.0 == auth.user_id {
        return Err(ApiError::conflict("device already belongs to this account"));
    }
    let source_device_count = transaction.query_row(
        "SELECT COUNT(*) FROM devices WHERE user_id = ?1 AND revoked_at IS NULL",
        params![auth.user_id],
        |row| row.get::<_, u16>(0),
    )?;
    let code_fresh = code.1 >= 0
        && now >= 0
        && code.2 >= now
        && account_identity::link_code_is_fresh(code.1 as u32, now as u32);
    let source_is_single_device = source_device_count == 1;
    if !account_identity::may_adopt_account(
        true,
        code.3.is_none(),
        code_fresh,
        source_is_single_device,
    ) {
        return Err(ApiError::forbidden(
            "link code expired, was already used, or this account has multiple devices",
        ));
    }
    let old_user_id = auth.user_id.clone();
    let updated = transaction.execute(
        "UPDATE devices SET user_id = ?1, linked_at = ?2
         WHERE device_id = ?3 AND user_id = ?4 AND revoked_at IS NULL",
        params![code.0, now, auth.device_id, old_user_id],
    )?;
    if updated != 1 {
        return Err(ApiError::conflict("device membership changed concurrently"));
    }
    let consumed = transaction.execute(
        "UPDATE device_link_codes SET consumed_at = ?1
         WHERE code_hash = ?2 AND consumed_at IS NULL",
        params![now, code_hash],
    )?;
    if consumed != 1 {
        return Err(ApiError::conflict("link code was used concurrently"));
    }
    transaction.execute(
        "DELETE FROM nicknames WHERE user_id = ?1",
        params![old_user_id],
    )?;
    transaction.execute(
        "DELETE FROM accounts
         WHERE user_id = ?1 AND NOT EXISTS
             (SELECT 1 FROM devices WHERE devices.user_id = accounts.user_id)",
        params![old_user_id],
    )?;
    transaction.commit()?;
    let linked_auth = AuthenticatedDevice {
        user_id: code.0,
        device_id: auth.device_id,
        display_name: auth.display_name,
        capabilities: auth.capabilities,
    };
    Ok(Json(load_account_snapshot(&database, &linked_auth)?))
}

async fn revoke_device(
    State(state): State<AppState>,
    Path(target_device_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let request: RevokeDeviceRequest = decode_json(&body)?;
    let path = format!("/v1/account/devices/{target_device_id}/revoke");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let now = unix_time();
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let target = transaction
        .query_row(
            "SELECT user_id, revoked_at FROM devices WHERE device_id = ?1",
            params![target_device_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("device not found"))?;
    let active_devices = transaction.query_row(
        "SELECT COUNT(*) FROM devices WHERE user_id = ?1 AND revoked_at IS NULL",
        params![auth.user_id],
        |row| row.get::<_, u16>(0),
    )?;
    if !account_identity::may_revoke_device(
        target.0 == auth.user_id,
        target.1.is_none(),
        active_devices,
    ) {
        return Err(ApiError::forbidden(
            "device is not active in this account or is the last active device",
        ));
    }
    transaction.execute(
        "UPDATE devices SET revoked_at = ?1, voip_push_token = NULL
         WHERE device_id = ?2 AND revoked_at IS NULL",
        params![now, target_device_id],
    )?;
    transaction.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

fn load_account_snapshot(
    database: &Connection,
    auth: &AuthenticatedDevice,
) -> Result<AccountSnapshotResponse, ApiError> {
    let nickname = database
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let mut statement = database.prepare(
        "SELECT device_id, display_name, platform, key_fingerprint,
                last_seen, revoked_at
         FROM devices WHERE user_id = ?1
         ORDER BY revoked_at IS NOT NULL, linked_at, device_id",
    )?;
    let devices = statement
        .query_map(params![auth.user_id], |row| {
            let device_id = row.get::<_, String>(0)?;
            Ok(AccountDeviceSummary {
                current: device_id == auth.device_id,
                device_id,
                display_name: row.get(1)?,
                platform: row.get(2)?,
                key_fingerprint: row.get(3)?,
                last_seen: row.get(4)?,
                revoked: row.get::<_, Option<i64>>(5)?.is_some(),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(AccountSnapshotResponse {
        account_id: auth.user_id.clone(),
        nickname,
        devices,
    })
}

async fn claim_nickname(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<NicknameClaimResponse>, ApiError> {
    let request: NicknameClaimRequest = decode_json(&body)?;
    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/directory/nicknames/claim",
        &body,
        None,
    )?;
    require_identity(&auth, &request.user_id, &request.device_id)?;

    let normalized = normalize_nickname(&request.nickname);
    let shape_valid = nickname_shape_valid(&normalized);
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let existing = {
        let mut statement = transaction.prepare("SELECT nickname, user_id FROM nicknames")?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let confusing = existing.iter().any(|(nickname, user_id)| {
        user_id != &request.user_id && nicknames_are_confusing(&normalized, nickname)
    });

    if !shape_valid || confusing {
        let reason = if !shape_valid {
            "Nickname must be 3-20 lowercase ASCII letters, numbers, or underscore and start with a letter"
        } else {
            "Nickname is already used or too similar"
        };
        let suggestions = nickname_suggestions(
            &normalized,
            &request.user_id,
            existing.iter().map(|(nickname, _)| nickname.as_str()),
        );
        transaction.commit()?;
        return Ok(Json(NicknameClaimResponse {
            claimed: false,
            normalized,
            reason: Some(reason.to_string()),
            suggestions,
        }));
    }

    if nickname_directory::claim_status(true, false, true, true)
        != nickname_directory::CLAIM_VERIFIED
        || !nickname_directory::nickname_owner_matches(
            stable_id(&request.user_id),
            stable_id(&auth.user_id),
        )
    {
        return Err(ApiError::internal(
            "generated nickname policy rejected claim",
        ));
    }
    transaction.execute(
        "DELETE FROM nicknames WHERE user_id = ?1",
        params![request.user_id],
    )?;
    transaction
        .execute(
            "INSERT INTO nicknames(nickname, user_id, device_id, updated_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![normalized, request.user_id, request.device_id, unix_time()],
        )
        .map_err(|error| match error {
            rusqlite::Error::SqliteFailure(_, _) => {
                ApiError::conflict("nickname was claimed concurrently")
            }
            other => ApiError::from(other),
        })?;
    transaction.commit()?;
    Ok(Json(NicknameClaimResponse {
        claimed: true,
        normalized,
        reason: None,
        suggestions: Vec::new(),
    }))
}

async fn search_nicknames(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<NicknameSearchResponse>, ApiError> {
    let request: NicknameSearchRequest = decode_json(&body)?;
    let _auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/directory/search",
        &body,
        None,
    )?;
    let query = normalize_nickname(&request.query);
    let limit = request.limit.clamp(1, 50) as i64;
    let now = unix_time();
    let database = lock_database(&state)?;
    let mut statement = database.prepare(
        "SELECT n.user_id,
                (SELECT d.device_id FROM devices d
                 WHERE d.user_id = n.user_id AND d.revoked_at IS NULL
                 ORDER BY d.last_seen DESC LIMIT 1),
                n.nickname,
                (SELECT d.display_name FROM devices d
                 WHERE d.user_id = n.user_id AND d.revoked_at IS NULL
                 ORDER BY d.last_seen DESC LIMIT 1),
                (SELECT d.key_fingerprint FROM devices d
                 WHERE d.user_id = n.user_id AND d.revoked_at IS NULL
                 ORDER BY d.last_seen DESC LIMIT 1),
                (SELECT MAX(d.last_seen) FROM devices d
                 WHERE d.user_id = n.user_id AND d.revoked_at IS NULL),
                (SELECT COUNT(*) FROM devices d
                 WHERE d.user_id = n.user_id AND d.revoked_at IS NULL)
         FROM nicknames n
         WHERE n.nickname LIKE '%' || ?1 || '%'
           AND EXISTS (SELECT 1 FROM devices d
                       WHERE d.user_id = n.user_id AND d.revoked_at IS NULL)
         ORDER BY CASE
             WHEN n.nickname = ?1 THEN 0
             WHEN n.nickname LIKE ?1 || '%' THEN 1
             ELSE 2 END,
             n.nickname
         LIMIT ?2",
    )?;
    let results = statement
        .query_map(params![query, limit], |row| {
            let last_seen: i64 = row.get(5)?;
            Ok(DirectoryContact {
                user_id: row.get(0)?,
                device_id: row.get(1)?,
                nickname: row.get(2)?,
                display_name: row.get(3)?,
                key_fingerprint: row.get(4)?,
                online: device_is_online(last_seen, now),
                device_count: row.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(NicknameSearchResponse { results }))
}

async fn create_call(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<InternetCallSession>, ApiError> {
    let request: CreateCallRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/calls", &body, None)?;
    require_identity(&auth, &request.caller_user_id, &request.caller_device_id)?;
    let callee = normalize_nickname(&request.callee);
    if !nickname_shape_valid(&callee) {
        return Err(ApiError::bad_request("invalid callee nickname"));
    }

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let target_user_id = transaction
        .query_row(
            "SELECT user_id FROM nicknames WHERE nickname = ?1",
            params![callee],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("nickname not found"))?;
    let targets = {
        let mut statement = transaction.prepare(
            "SELECT device_id, capabilities, last_seen, voip_push_token,
                    push_environment
             FROM devices
             WHERE user_id = ?1 AND revoked_at IS NULL",
        )?;
        let rows = statement
            .query_map(params![target_user_id], |row| {
                Ok(CallTarget {
                    device_id: row.get(0)?,
                    capabilities: row.get(1)?,
                    last_seen: row.get(2)?,
                    voip_push_token: row.get(3)?,
                    push_environment: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let targets = targets
        .into_iter()
        .filter(|target| {
            internet_call::call_target_is_available(
                stable_id(&auth.user_id),
                stable_id(&auth.device_id),
                stable_id(&target_user_id),
                stable_id(&target.device_id),
                target.capabilities,
                device_is_online(target.last_seen, unix_time()),
                voip_push_is_reachable(&state.configuration, target),
            )
        })
        .collect::<Vec<_>>();
    if targets.is_empty() {
        return Err(ApiError::conflict(
            "destination is offline or cannot receive an Internet call",
        ));
    }
    let caller_name = transaction
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| auth.display_name.clone());
    let call_id = random_id("call_");
    let call_uuid = Uuid::new_v4().to_string();
    let room_id = random_id("room_");
    let status = internet_call::next_status(internet_call::CALL_IDLE, true);
    transaction.execute(
        "INSERT INTO calls
         (call_id, call_uuid, room_id, caller_user_id, caller_device_id, callee_user_id,
          callee_device_id, caller_name, audio, video, status, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            call_id,
            call_uuid,
            room_id,
            auth.user_id,
            auth.device_id,
            target_user_id,
            targets[0].device_id,
            caller_name,
            request.audio,
            request.video,
            status,
            unix_time(),
        ],
    )?;
    for target in &targets {
        transaction.execute(
            "INSERT INTO call_targets(call_id, device_id, state)
             VALUES (?1, ?2, ?3)",
            params![call_id, target.device_id, internet_call::CALL_RINGING],
        )?;
    }
    transaction.commit()?;
    drop(database);
    if let Some(apns) = state.configuration.apns.clone() {
        for token in targets
            .iter()
            .filter(|target| {
                internet_call::voip_push_may_be_sent(
                    status,
                    true,
                    voip_push_is_reachable(&state.configuration, target),
                )
            })
            .filter_map(|target| {
                Some((
                    target.device_id.clone(),
                    target.voip_push_token.clone()?,
                    ApnsEnvironment::parse(&target.push_environment).ok()?,
                ))
            })
        {
            let (device_id, token, environment) = token;
            let apns = apns.clone();
            let call_id = call_id.clone();
            let call_uuid = call_uuid.clone();
            let caller = caller_name.clone();
            let database = state.database.clone();
            tokio::spawn(async move {
                let result = apns
                    .send_voip(
                        &token,
                        environment,
                        &call_id,
                        &call_uuid,
                        &caller,
                        request.audio,
                        request.video,
                    )
                    .await;
                match result {
                    Ok(delivery)
                        if internet_call::apns_environment_should_be_updated(
                            delivery.environment_changed,
                            true,
                        ) =>
                    {
                        if let Ok(database) = database.lock() {
                            let _ = database.execute(
                                "UPDATE devices SET push_environment = ?1
                                 WHERE device_id = ?2 AND voip_push_token = ?3",
                                params![delivery.environment.as_database_value(), device_id, token],
                            );
                        }
                    }
                    Err(error)
                        if internet_call::apns_token_should_be_invalidated(
                            error.permanent,
                            error.bad_device_token,
                            error.alternate_attempted,
                            true,
                        ) =>
                    {
                        if let Ok(database) = database.lock() {
                            let _ = database.execute(
                                "UPDATE devices SET voip_push_token = NULL
                                 WHERE device_id = ?1 AND voip_push_token = ?2",
                                params![device_id, token],
                            );
                        }
                        eprintln!(
                            "APNs VoIP delivery invalidated exact token for {call_id}: {error}"
                        );
                    }
                    Err(error) => {
                        eprintln!("APNs VoIP delivery failed for {call_id}: {error}");
                    }
                    Ok(_) => {}
                }
            });
        }
    }
    session_for(
        &state.configuration,
        &call_id,
        &room_id,
        &auth,
        &caller_name,
    )
    .map(Json)
}

async fn incoming_calls(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<IncomingCallsResponse>, ApiError> {
    let request: IncomingCallsRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/calls/incoming", &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let minimum_created_at = unix_time() - i64::from(internet_call::INVITE_TTL_SECONDS);
    let database = lock_database(&state)?;
    let mut statement = database.prepare(
        "SELECT c.call_id, c.call_uuid, c.caller_name, c.audio, c.video, c.created_at
         FROM call_targets t JOIN calls c ON c.call_id = t.call_id
         WHERE t.device_id = ?1 AND t.state = ?2 AND c.status = ?2
           AND c.created_at >= ?3
         ORDER BY c.created_at ASC LIMIT 10",
    )?;
    let calls = statement
        .query_map(
            params![
                auth.device_id,
                internet_call::CALL_RINGING,
                minimum_created_at
            ],
            |row| {
                Ok(IncomingCall {
                    call_id: row.get(0)?,
                    call_uuid: row.get(1)?,
                    caller: row.get(2)?,
                    audio: row.get(3)?,
                    video: row.get(4)?,
                    created_at: row.get(5)?,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(IncomingCallsResponse { calls }))
}

async fn join_call(
    State(state): State<AppState>,
    Path(call_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<InternetCallSession>, ApiError> {
    let request: JoinCallRequest = decode_json(&body)?;
    let path = format!("/v1/calls/{call_id}/join");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let call = transaction
        .query_row(
            "SELECT c.room_id, c.callee_user_id, t.device_id, c.status,
                    created_at, caller_name
             FROM calls c JOIN call_targets t ON t.call_id = c.call_id
             WHERE c.call_id = ?1 AND t.device_id = ?2",
            params![call_id, auth.device_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, u8>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| ApiError::forbidden("call is unavailable to this device"))?;
    let now = unix_time();
    let invite_fresh =
        call.4 >= 0 && now >= 0 && internet_call::invite_is_fresh(call.4 as u32, now as u32);
    let device_valid = internet_call::device_is_valid(
        stable_id(&auth.user_id),
        stable_id(&auth.device_id),
        stable_id(&auth.device_id),
        auth.capabilities,
    );
    if !internet_call::join_is_authorized(
        stable_id(&auth.user_id),
        stable_id(&auth.device_id),
        stable_id(&call.1),
        stable_id(&call.2),
        call.3,
        invite_fresh,
        device_valid,
    ) {
        return Err(ApiError::forbidden(
            "call is expired, already answered, or belongs to another device",
        ));
    }
    let answered = transaction.execute(
        "UPDATE calls SET status = ?1, answered_at = ?2, answered_device_id = ?3
         WHERE call_id = ?4 AND status = ?5",
        params![
            internet_call::next_status(call.3, true),
            now,
            auth.device_id,
            call_id,
            internet_call::CALL_RINGING
        ],
    )?;
    if answered != 1 {
        return Err(ApiError::conflict("call was answered on another device"));
    }
    transaction.execute(
        "UPDATE call_targets
         SET state = CASE WHEN device_id = ?1 THEN ?2 ELSE ?3 END
         WHERE call_id = ?4",
        params![
            auth.device_id,
            internet_call::CALL_ACTIVE,
            internet_call::CALL_ENDED,
            call_id
        ],
    )?;
    transaction.commit()?;
    drop(database);
    session_for(
        &state.configuration,
        &call_id,
        &call.0,
        &auth,
        &auth.display_name,
    )
    .map(Json)
}

async fn cancel_call(
    State(state): State<AppState>,
    Path(call_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let request: EndCallRequest = decode_json(&body)?;
    let path = format!("/v1/calls/{call_id}/cancel");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let call = transaction
        .query_row(
            "SELECT caller_user_id, caller_device_id, status
             FROM calls WHERE call_id = ?1",
            params![call_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u8>(2)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| ApiError::forbidden("call is unavailable to this device"))?;
    let exact_originating_device = auth.user_id == call.0 && auth.device_id == call.1;
    if !exact_originating_device
        || !internet_call::caller_may_end(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&call.0),
            stable_id(&call.1),
            call.2,
        )
    {
        return Err(ApiError::forbidden(
            "only the originating device may end this call",
        ));
    }
    if call.2 != internet_call::CALL_ENDED {
        let ended = transaction.execute(
            "UPDATE calls SET status = ?1
             WHERE call_id = ?2 AND status = ?3",
            params![internet_call::next_status(call.2, false), call_id, call.2],
        )?;
        if ended != 1 {
            return Err(ApiError::conflict("call state changed before cancellation"));
        }
        transaction.execute(
            "UPDATE call_targets SET state = ?1 WHERE call_id = ?2",
            params![internet_call::CALL_ENDED, call_id],
        )?;
    }
    transaction.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

async fn create_group_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<GroupChatSummary>, ApiError> {
    let request: CreateGroupChatRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/chats", &body, None)?;
    require_identity(&auth, &request.creator_user_id, &request.creator_device_id)?;
    if request.members.len() >= group_chat::MAX_GROUP_MEMBERS as usize {
        return Err(ApiError::bad_request("group has too many members"));
    }

    let requested_members = request
        .members
        .iter()
        .map(|nickname| normalize_nickname(nickname))
        .collect::<Vec<_>>();
    if requested_members
        .iter()
        .any(|nickname| !nickname_shape_valid(nickname))
    {
        return Err(ApiError::bad_request("group contains an invalid nickname"));
    }
    let unique_nicknames = requested_members
        .iter()
        .enumerate()
        .filter(|(index, nickname)| !requested_members[..*index].contains(nickname))
        .count();
    if unique_nicknames != requested_members.len() {
        return Err(ApiError::bad_request("group contains duplicate nicknames"));
    }

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let creator_nickname = transaction
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or_else(|| ApiError::conflict("create your nickname before creating a group"))?;

    let mut resolved_members = Vec::with_capacity(requested_members.len());
    for nickname in &requested_members {
        let user_id = transaction
            .query_row(
                "SELECT user_id FROM nicknames WHERE nickname = ?1",
                params![nickname],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| ApiError::not_found(format!("nickname @{nickname} was not found")))?;
        resolved_members.push((user_id, nickname.clone()));
    }
    let unique_accounts = resolved_members
        .iter()
        .enumerate()
        .filter(|(index, member)| {
            member.0 != auth.user_id
                && !resolved_members[..*index]
                    .iter()
                    .any(|existing| existing.0 == member.0)
        })
        .count();
    let requested_count = requested_members.len() as u8;
    if !group_chat::group_may_be_created(
        true,
        requested_count,
        resolved_members.len() as u8,
        unique_accounts as u8,
    ) {
        return Err(ApiError::bad_request(
            "group must contain distinct accounts other than your own",
        ));
    }

    let title = request
        .title
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| default_group_title(&creator_nickname, &requested_members));
    let title_length = title.len().min(u16::MAX as usize) as u16;
    if !group_chat::title_is_valid(title_length) {
        return Err(ApiError::bad_request("group title must be 1-80 bytes"));
    }

    let chat_id = random_id("chat_");
    let now = unix_time();
    transaction.execute(
        "INSERT INTO group_chats(chat_id, title, created_by_user_id, created_at)
         VALUES (?1, ?2, ?3, ?4)",
        params![chat_id, title, auth.user_id, now],
    )?;
    transaction.execute(
        "INSERT INTO group_chat_members(chat_id, user_id, nickname, joined_at, left_at)
         VALUES (?1, ?2, ?3, ?4, NULL)",
        params![chat_id, auth.user_id, creator_nickname, now],
    )?;
    transaction.execute(
        "INSERT INTO group_chat_read_state(chat_id, user_id, last_read_message_id)
         VALUES (?1, ?2, 0)",
        params![chat_id, auth.user_id],
    )?;
    for (user_id, nickname) in resolved_members {
        transaction.execute(
            "INSERT INTO group_chat_members(chat_id, user_id, nickname, joined_at, left_at)
             VALUES (?1, ?2, ?3, ?4, NULL)",
            params![chat_id, &user_id, nickname, now],
        )?;
        transaction.execute(
            "INSERT INTO group_chat_read_state(chat_id, user_id, last_read_message_id)
             VALUES (?1, ?2, 0)",
            params![chat_id, user_id],
        )?;
    }
    transaction.commit()?;
    Ok(Json(load_group_chat_summary(
        &database,
        &chat_id,
        &auth.user_id,
    )?))
}

async fn list_group_chats(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<GroupChatsResponse>, ApiError> {
    let request: GroupChatsRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/chats/list", &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let database = lock_database(&state)?;
    let chat_ids = {
        let mut statement = database.prepare(
            "SELECT c.chat_id
             FROM group_chats c
             JOIN group_chat_members m ON m.chat_id = c.chat_id
             WHERE m.user_id = ?1 AND m.left_at IS NULL
             ORDER BY COALESCE(
                 (SELECT MAX(message.created_at)
                  FROM group_chat_messages message
                  WHERE message.chat_id = c.chat_id),
                 c.created_at
             ) DESC, c.chat_id",
        )?;
        let chat_ids = statement
            .query_map(params![auth.user_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        chat_ids
    };
    let chats = chat_ids
        .iter()
        .map(|chat_id| load_group_chat_summary(&database, chat_id, &auth.user_id))
        .collect::<Result<Vec<_>, _>>()?;
    let total_unread_count = chats
        .iter()
        .fold(0_u32, |total, chat| total.saturating_add(chat.unread_count));
    Ok(Json(GroupChatsResponse {
        chats,
        total_unread_count,
    }))
}

async fn send_group_message(
    State(state): State<AppState>,
    Path(chat_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<GroupChatMessage>, ApiError> {
    let request: SendGroupMessageRequest = decode_json(&body)?;
    let path = format!("/v1/chats/{chat_id}/messages");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    if request.client_message_id.len() < 8
        || request.client_message_id.len() > 64
        || !request.client_message_id.is_ascii()
    {
        return Err(ApiError::bad_request("invalid client message ID"));
    }
    let text = request.text.trim();
    let text_length = text.len().min(u16::MAX as usize) as u16;

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let active_member = active_group_member(&transaction, &chat_id, &auth.user_id)?;
    if !group_chat::message_may_be_sent(active_member, true, text_length) {
        return Err(if active_member {
            ApiError::bad_request("message must be 1-4096 bytes")
        } else {
            ApiError::forbidden("device account is not a member of this group")
        });
    }
    let sender_nickname = transaction
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_else(|| auth.display_name.clone());
    let now = unix_time();
    let inserted = transaction.execute(
        "INSERT OR IGNORE INTO group_chat_messages
         (chat_id, sender_user_id, sender_device_id, sender_nickname,
          client_message_id, text, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            chat_id,
            auth.user_id,
            auth.device_id,
            sender_nickname,
            request.client_message_id,
            text,
            now
        ],
    )? == 1;
    let message = transaction.query_row(
        "SELECT message_id, chat_id, sender_user_id, sender_nickname, text, created_at
         FROM group_chat_messages
         WHERE chat_id = ?1 AND sender_device_id = ?2 AND client_message_id = ?3",
        params![chat_id, auth.device_id, request.client_message_id],
        group_chat_message_from_row,
    )?;
    let alert_jobs = if inserted && state.configuration.apns.is_some() {
        let member_user_ids = {
            let mut statement = transaction.prepare(
                "SELECT user_id FROM group_chat_members
                 WHERE chat_id = ?1 AND left_at IS NULL",
            )?;
            let members = statement
                .query_map(params![chat_id], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            members
        };
        let mut jobs = Vec::new();
        for user_id in member_user_ids {
            let sender_is_recipient = user_id == auth.user_id;
            let badge = total_unread_count_for_user(&transaction, &user_id)?;
            let devices = {
                let mut statement = transaction.prepare(
                    "SELECT device_id, alert_push_token, push_environment
                     FROM devices
                     WHERE user_id = ?1 AND revoked_at IS NULL
                       AND alert_push_token IS NOT NULL",
                )?;
                let devices = statement
                    .query_map(params![user_id], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                devices
            };
            jobs.extend(
                devices
                    .into_iter()
                    .filter(|(_, token, environment)| {
                        group_chat::push_alert_may_be_sent(
                            sender_is_recipient,
                            true,
                            alert_push_is_reachable(&state.configuration, token, environment),
                            inserted,
                        )
                    })
                    .map(|(device_id, token, environment)| (device_id, token, environment, badge)),
            );
        }
        jobs
    } else {
        Vec::new()
    };
    transaction.commit()?;
    drop(database);
    if let Some(apns) = state.configuration.apns.clone() {
        for (device_id, token, environment, badge) in alert_jobs {
            let Ok(environment) = ApnsEnvironment::parse(&environment) else {
                continue;
            };
            let apns = apns.clone();
            let chat_id = chat_id.clone();
            let sender = sender_nickname.clone();
            let database = state.database.clone();
            tokio::spawn(async move {
                let data = serde_json::json!({
                    "type": "group_chat_message",
                    "chat_id": chat_id.clone()
                });
                let result = apns
                    .send_alert(
                        &token,
                        environment,
                        "TRI-NET",
                        &format!("New message from @{sender}"),
                        badge,
                        "trinet-chat.caf",
                        Some(&chat_id),
                        data,
                    )
                    .await;
                match result {
                    Ok(delivery)
                        if internet_call::apns_environment_should_be_updated(
                            delivery.environment_changed,
                            true,
                        ) =>
                    {
                        if let Ok(database) = database.lock() {
                            let _ = database.execute(
                                "UPDATE devices SET push_environment = ?1
                                 WHERE device_id = ?2 AND alert_push_token = ?3",
                                params![delivery.environment.as_database_value(), device_id, token],
                            );
                        }
                    }
                    Err(error)
                        if internet_call::apns_token_should_be_invalidated(
                            error.permanent,
                            error.bad_device_token,
                            error.alternate_attempted,
                            true,
                        ) =>
                    {
                        if let Ok(database) = database.lock() {
                            let _ = database.execute(
                                "UPDATE devices SET alert_push_token = NULL
                                 WHERE device_id = ?1 AND alert_push_token = ?2",
                                params![device_id, token],
                            );
                        }
                        eprintln!("APNs chat alert invalidated exact token for {chat_id}: {error}");
                    }
                    Err(error) => {
                        eprintln!("APNs chat alert delivery failed for {chat_id}: {error}");
                    }
                    Ok(_) => {}
                }
            });
        }
    }
    Ok(Json(message))
}

async fn list_group_messages(
    State(state): State<AppState>,
    Path(chat_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<GroupMessagesResponse>, ApiError> {
    let request: GroupMessagesRequest = decode_json(&body)?;
    let path = format!("/v1/chats/{chat_id}/messages/list");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let database = lock_database(&state)?;
    let active_member = active_group_member(&database, &chat_id, &auth.user_id)?;
    if !group_chat::member_may_read(active_member, true) {
        return Err(ApiError::forbidden(
            "device account is not a member of this group",
        ));
    }
    let after_message_id = request.after_message_id.max(0);
    let limit = i64::from(group_chat::message_page_size(request.limit));
    let messages = {
        let mut statement = database.prepare(
            "SELECT message_id, chat_id, sender_user_id, sender_nickname, text, created_at
             FROM group_chat_messages
             WHERE chat_id = ?1 AND message_id > ?2
             ORDER BY message_id ASC LIMIT ?3",
        )?;
        let messages = statement
            .query_map(
                params![chat_id, after_message_id, limit],
                group_chat_message_from_row,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        messages
    };
    Ok(Json(GroupMessagesResponse { messages }))
}

async fn mark_group_chat_read(
    State(state): State<AppState>,
    Path(chat_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let request: MarkGroupChatReadRequest = decode_json(&body)?;
    let path = format!("/v1/chats/{chat_id}/read");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    if request.through_message_id < 0 {
        return Err(ApiError::bad_request(
            "through_message_id must not be negative",
        ));
    }

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if !active_group_member(&transaction, &chat_id, &auth.user_id)? {
        return Err(ApiError::forbidden(
            "device account is not a member of this group",
        ));
    }
    let current = transaction
        .query_row(
            "SELECT last_read_message_id FROM group_chat_read_state
             WHERE chat_id = ?1 AND user_id = ?2",
            params![chat_id, auth.user_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0)
        .max(0);
    let observed = transaction.query_row(
        "SELECT COALESCE(MAX(message_id), 0)
         FROM group_chat_messages
         WHERE chat_id = ?1 AND message_id <= ?2",
        params![chat_id, request.through_message_id],
        |row| row.get::<_, i64>(0),
    )?;
    let next = group_chat::advance_read_cursor(current as u64, observed.max(0) as u64)
        .min(i64::MAX as u64) as i64;
    transaction.execute(
        "INSERT INTO group_chat_read_state(chat_id, user_id, last_read_message_id)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(chat_id, user_id) DO UPDATE SET
           last_read_message_id = excluded.last_read_message_id",
        params![chat_id, auth.user_id, next],
    )?;
    transaction.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

fn active_group_member(
    database: &Connection,
    chat_id: &str,
    user_id: &str,
) -> Result<bool, ApiError> {
    Ok(database.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM group_chat_members
             WHERE chat_id = ?1 AND user_id = ?2 AND left_at IS NULL
         )",
        params![chat_id, user_id],
        |row| row.get::<_, bool>(0),
    )?)
}

fn load_group_chat_summary(
    database: &Connection,
    chat_id: &str,
    user_id: &str,
) -> Result<GroupChatSummary, ApiError> {
    let (title, created_at) = database
        .query_row(
            "SELECT title, created_at FROM group_chats WHERE chat_id = ?1",
            params![chat_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("group chat not found"))?;
    let members = {
        let mut statement = database.prepare(
            "SELECT COALESCE(
                 (SELECT nickname FROM nicknames n WHERE n.user_id = m.user_id),
                 m.nickname
             )
             FROM group_chat_members m
             WHERE m.chat_id = ?1 AND m.left_at IS NULL
             ORDER BY 1",
        )?;
        let members = statement
            .query_map(params![chat_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        members
    };
    let last_message = database
        .query_row(
            "SELECT text, created_at FROM group_chat_messages
             WHERE chat_id = ?1 ORDER BY message_id DESC LIMIT 1",
            params![chat_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    Ok(GroupChatSummary {
        chat_id: chat_id.to_string(),
        title,
        members,
        created_at,
        last_message: last_message.as_ref().map(|message| message.0.clone()),
        last_message_at: last_message.map(|message| message.1),
        unread_count: unread_count_for_chat(database, chat_id, user_id)?,
    })
}

fn unread_count_for_chat(
    database: &Connection,
    chat_id: &str,
    user_id: &str,
) -> Result<u32, ApiError> {
    let read_cursor = database
        .query_row(
            "SELECT last_read_message_id FROM group_chat_read_state
             WHERE chat_id = ?1 AND user_id = ?2",
            params![chat_id, user_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0)
        .max(0) as u64;
    let mut statement = database.prepare(
        "SELECT message_id, sender_user_id
         FROM group_chat_messages
         WHERE chat_id = ?1 AND message_id > ?2
         ORDER BY message_id",
    )?;
    let messages = statement
        .query_map(
            params![chat_id, read_cursor.min(i64::MAX as u64) as i64],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(messages.iter().fold(0_u32, |count, (message_id, sender)| {
        if group_chat::message_counts_as_unread(
            (*message_id).max(0) as u64,
            read_cursor,
            sender == user_id,
        ) {
            count.saturating_add(1)
        } else {
            count
        }
    }))
}

fn total_unread_count_for_user(database: &Connection, user_id: &str) -> Result<u32, ApiError> {
    let chat_ids = {
        let mut statement = database.prepare(
            "SELECT chat_id FROM group_chat_members
             WHERE user_id = ?1 AND left_at IS NULL",
        )?;
        let chat_ids = statement
            .query_map(params![user_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        chat_ids
    };
    chat_ids.iter().try_fold(0_u32, |total, chat_id| {
        unread_count_for_chat(database, chat_id, user_id).map(|count| total.saturating_add(count))
    })
}

fn alert_push_is_reachable(configuration: &Configuration, token: &str, environment: &str) -> bool {
    valid_apns_token(token)
        && configuration
            .apns
            .as_ref()
            .is_some_and(|apns| apns.can_route_environment(environment))
}

fn group_chat_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GroupChatMessage> {
    Ok(GroupChatMessage {
        message_id: row.get(0)?,
        chat_id: row.get(1)?,
        sender_user_id: row.get(2)?,
        sender_nickname: row.get(3)?,
        text: row.get(4)?,
        created_at: row.get(5)?,
    })
}

fn default_group_title(creator: &str, members: &[String]) -> String {
    let mut title = format!("@{creator}");
    for member in members {
        let fragment = format!(", @{member}");
        if title.len() + fragment.len() > group_chat::MAX_GROUP_TITLE_BYTES as usize - "...".len() {
            title.push_str("...");
            break;
        }
        title.push_str(&fragment);
    }
    title
}

fn authenticate(
    state: &AppState,
    headers: &HeaderMap,
    method: &str,
    path: &str,
    body: &[u8],
    bootstrap: Option<(&str, &str)>,
) -> Result<AuthenticatedDevice, ApiError> {
    verify_service_token(&state.configuration, headers)?;
    let device_id = header(headers, "x-trinet-device-id")?;
    let timestamp_text = header(headers, "x-trinet-timestamp")?;
    let nonce = header(headers, "x-trinet-nonce")?;
    let signature_text = header(headers, "x-trinet-signature")?;
    let timestamp: i64 = timestamp_text
        .parse()
        .map_err(|_| ApiError::unauthorized("invalid request timestamp"))?;
    let now = unix_time();
    let signed_at = u32::try_from(timestamp)
        .map_err(|_| ApiError::unauthorized("request signature is stale"))?;
    let current_time = u32::try_from(now)
        .map_err(|_| ApiError::unauthorized("request signature is stale"))?;
    if !internet_call::request_signature_is_fresh(signed_at, current_time) {
        return Err(ApiError::unauthorized("request signature is stale"));
    }
    if nonce.len() < 16 || nonce.len() > 64 || !nonce.is_ascii() {
        return Err(ApiError::unauthorized("invalid request nonce"));
    }

    let mut database = lock_database(state)?;
    let stored = database
        .query_row(
            "SELECT user_id, display_name, signing_public_key, capabilities,
                    key_fingerprint, revoked_at
             FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, u8>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                ))
            },
        )
        .optional()?;
    let (user_id, display_name, public_key, capabilities) = match stored {
        Some(record) => {
            if record.5.is_some()
                || !account_identity::device_membership_is_valid(
                    stable_id(&record.0),
                    stable_id(device_id),
                    stable_id(&record.4),
                    account_identity::DEVICE_ACTIVE,
                )
            {
                return Err(ApiError::forbidden("device membership is revoked"));
            }
            (record.0, record.1, record.2, record.3)
        }
        None => {
            let (bootstrap_user_id, bootstrap_public_key) =
                bootstrap.ok_or_else(|| ApiError::unauthorized("device is not registered"))?;
            (
                bootstrap_user_id.to_string(),
                bootstrap_user_id.to_string(),
                bootstrap_public_key.to_string(),
                0,
            )
        }
    };
    if let Some((bootstrap_user_id, _)) = bootstrap {
        if user_id != bootstrap_user_id {
            return Err(ApiError::forbidden("registered user ID cannot be changed"));
        }
    }

    let body_hash = lowercase_hex(&Sha256::digest(body));
    let canonical = format!(
        "{}\n{}\n{}\n{}\n{}",
        method.to_ascii_uppercase(),
        path,
        timestamp_text,
        nonce,
        body_hash
    );
    verify_signature(&public_key, signature_text, canonical.as_bytes())?;

    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute(
        "DELETE FROM request_nonces WHERE expires_at < ?1",
        params![now],
    )?;
    let inserted = transaction.execute(
        "INSERT OR IGNORE INTO request_nonces(device_id, nonce, expires_at)
         VALUES (?1, ?2, ?3)",
        params![
            device_id,
            nonce,
            i64::from(signed_at) + i64::from(internet_call::REQUEST_SIGNATURE_TTL_SECONDS)
        ],
    )?;
    if inserted != 1 {
        return Err(ApiError::unauthorized("request nonce was already used"));
    }
    transaction.execute(
        "UPDATE devices SET last_seen = ?1 WHERE device_id = ?2",
        params![now, device_id],
    )?;
    transaction.commit()?;
    Ok(AuthenticatedDevice {
        user_id,
        device_id: device_id.to_string(),
        display_name,
        capabilities,
    })
}

fn verify_service_token(
    configuration: &Configuration,
    headers: &HeaderMap,
) -> Result<(), ApiError> {
    let Some(expected) = &configuration.service_access_token else {
        return Ok(());
    };
    let actual = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or_else(|| ApiError::unauthorized("missing service access token"))?;
    if actual.as_bytes() != expected.as_bytes() {
        return Err(ApiError::unauthorized("invalid service access token"));
    }
    Ok(())
}

fn verify_signature(public_key: &str, signature: &str, message: &[u8]) -> Result<(), ApiError> {
    let public_key = decode_public_key(public_key)?;
    let verifying_key = VerifyingKey::from_sec1_bytes(&public_key)
        .map_err(|_| ApiError::unauthorized("invalid device public key"))?;
    let signature = general_purpose::STANDARD
        .decode(signature)
        .map_err(|_| ApiError::unauthorized("invalid signature encoding"))?;
    let signature = Signature::from_der(&signature)
        .map_err(|_| ApiError::unauthorized("invalid signature format"))?;
    verifying_key
        .verify(message, &signature)
        .map_err(|_| ApiError::unauthorized("device signature verification failed"))
}

fn session_for(
    configuration: &Configuration,
    call_id: &str,
    room_id: &str,
    device: &AuthenticatedDevice,
    participant_name: &str,
) -> Result<InternetCallSession, ApiError> {
    let token = livekit_token(configuration, room_id, &device.device_id, participant_name)?;
    Ok(InternetCallSession {
        call_id: call_id.to_string(),
        room_id: room_id.to_string(),
        livekit_url: configuration.livekit_url.clone(),
        token,
        media_key: None,
    })
}

fn livekit_token(
    configuration: &Configuration,
    room: &str,
    identity: &str,
    name: &str,
) -> Result<String, ApiError> {
    let now = unix_time();
    let header = general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let claims = LiveKitClaims {
        iss: &configuration.livekit_api_key,
        sub: identity,
        name,
        nbf: now - 5,
        exp: now + i64::from(internet_call::TOKEN_TTL_SECONDS),
        video: LiveKitVideoGrant {
            room_join: true,
            room,
            can_publish: true,
            can_subscribe: true,
            can_publish_data: true,
        },
    };
    let payload = serde_json::to_vec(&claims)
        .map_err(|error| ApiError::internal(format!("token encoding failed: {error}")))?;
    let payload = general_purpose::URL_SAFE_NO_PAD.encode(payload);
    let signing_input = format!("{header}.{payload}");
    let mut signer = HmacSha256::new_from_slice(configuration.livekit_api_secret.as_bytes())
        .map_err(|_| ApiError::internal("invalid LiveKit API secret"))?;
    signer.update(signing_input.as_bytes());
    let signature = general_purpose::URL_SAFE_NO_PAD.encode(signer.finalize().into_bytes());
    Ok(format!("{signing_input}.{signature}"))
}

fn decode_json<T: DeserializeOwned>(body: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body)
        .map_err(|error| ApiError::bad_request(format!("invalid JSON body: {error}")))
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Result<&'a str, ApiError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| ApiError::unauthorized(format!("missing {name} header")))
}

fn lock_database(state: &AppState) -> Result<MutexGuard<'_, Connection>, ApiError> {
    state
        .database
        .lock()
        .map_err(|_| ApiError::internal("database lock is poisoned"))
}

fn require_identity(
    auth: &AuthenticatedDevice,
    user_id: &str,
    device_id: &str,
) -> Result<(), ApiError> {
    if auth.user_id != user_id || auth.device_id != device_id {
        return Err(ApiError::forbidden(
            "signed device does not match request body",
        ));
    }
    Ok(())
}

fn capability_bits(capabilities: &[String]) -> u8 {
    capabilities.iter().fold(0, |bits, capability| {
        bits | match capability.as_str() {
            "audio" => internet_call::CAP_AUDIO,
            "video" => internet_call::CAP_VIDEO,
            "mesh" => internet_call::CAP_MESH,
            "webrtc" => internet_call::CAP_WEBRTC,
            _ => 0,
        }
    })
}

fn decode_public_key(encoded: &str) -> Result<Vec<u8>, ApiError> {
    general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| ApiError::bad_request("invalid public-key encoding"))
}

fn fingerprint(public_key: &[u8]) -> String {
    lowercase_hex(&Sha256::digest(public_key)[..12])
}

fn stable_id(value: &str) -> u64 {
    let digest = Sha256::digest(value.as_bytes());
    let mut bytes = [0_u8; 8];
    bytes.copy_from_slice(&digest[..8]);
    u64::from_be_bytes(bytes).max(1)
}

fn unix_time() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn random_id(prefix: &str) -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}{}", lowercase_hex(&bytes))
}

fn lowercase_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn normalize_nickname(value: &str) -> String {
    value.trim().trim_start_matches('@').to_ascii_lowercase()
}

fn device_is_online(last_seen: i64, now: i64) -> bool {
    last_seen >= 0 && now >= 0 && internet_call::device_is_online(last_seen as u32, now as u32)
}

fn voip_push_is_reachable(configuration: &Configuration, target: &CallTarget) -> bool {
    target
        .voip_push_token
        .as_deref()
        .filter(|token| valid_apns_token(token))
        .zip(configuration.apns.as_ref())
        .is_some_and(|(_, apns)| apns.can_route_environment(&target.push_environment))
}

fn nickname_shape_valid(nickname: &str) -> bool {
    let starts_with_letter = nickname
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_lowercase());
    let invalid_characters = nickname
        .bytes()
        .filter(|byte| !byte.is_ascii_lowercase() && !byte.is_ascii_digit() && *byte != b'_')
        .count()
        .min(u8::MAX as usize) as u8;
    nickname_directory::nickname_shape_is_valid(
        nickname.len().min(u8::MAX as usize) as u8,
        starts_with_letter,
        invalid_characters,
    )
}

fn nicknames_are_confusing(candidate: &str, existing: &str) -> bool {
    let distance =
        edit_distance(candidate.as_bytes(), existing.as_bytes()).min(u8::MAX as usize) as u8;
    let shared_prefix = candidate
        .bytes()
        .zip(existing.bytes())
        .take_while(|(left, right)| left == right)
        .count()
        .min(u8::MAX as usize) as u8;
    nickname_directory::nickname_is_confusing(candidate == existing, distance, shared_prefix)
}

fn edit_distance(left: &[u8], right: &[u8]) -> usize {
    if left.is_empty() {
        return right.len();
    }
    if right.is_empty() {
        return left.len();
    }
    let mut previous: Vec<usize> = (0..=right.len()).collect();
    for (left_index, left_value) in left.iter().enumerate() {
        let mut current = vec![left_index + 1];
        for (right_index, right_value) in right.iter().enumerate() {
            current.push(
                (current[right_index] + 1)
                    .min(previous[right_index + 1] + 1)
                    .min(previous[right_index] + usize::from(left_value != right_value)),
            );
        }
        previous = current;
    }
    previous[right.len()]
}

fn nickname_suggestions<'a>(
    candidate: &str,
    seed: &str,
    existing: impl Iterator<Item = &'a str>,
) -> Vec<String> {
    let existing = existing.map(str::to_string).collect::<Vec<_>>();
    let mut base = candidate
        .bytes()
        .filter(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
        .map(char::from)
        .collect::<String>();
    if !base
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_lowercase())
    {
        base = format!("user_{base}");
    }
    if base.len() < nickname_directory::NICKNAME_MIN_LENGTH as usize {
        base.push_str("net");
    }
    base.truncate(nickname_directory::NICKNAME_MAX_LENGTH as usize - 3);
    let seed = stable_id(seed) % 1000;
    let mut suggestions = Vec::new();
    for offset in 0..40_u64 {
        let suffix = format!("{:03}", (seed + offset * 37) % 1000);
        let mut proposal = base.clone();
        proposal.truncate(nickname_directory::NICKNAME_MAX_LENGTH as usize - suffix.len());
        proposal.push_str(&suffix);
        if !existing
            .iter()
            .any(|nickname| nicknames_are_confusing(&proposal, nickname))
        {
            suggestions.push(proposal);
            if suggestions.len() == 3 {
                break;
            }
        }
    }
    suggestions
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use http_body_util::BodyExt;
    use p256::ecdsa::{signature::Signer, SigningKey};
    use serde_json::{json, Value};
    use tower::ServiceExt;

    struct TestDevice {
        user_id: String,
        device_id: String,
        display_name: String,
        signing_key: SigningKey,
        public_key: String,
        fingerprint: String,
    }

    impl TestDevice {
        fn new(user_id: &str, device_id: &str, display_name: &str) -> Self {
            let signing_key = SigningKey::random(&mut OsRng);
            let public_key_bytes = signing_key.verifying_key().to_encoded_point(false);
            Self {
                user_id: user_id.to_string(),
                device_id: device_id.to_string(),
                display_name: display_name.to_string(),
                public_key: general_purpose::STANDARD.encode(public_key_bytes.as_bytes()),
                fingerprint: fingerprint(public_key_bytes.as_bytes()),
                signing_key,
            }
        }

        fn registration(&self) -> Value {
            json!({
                "user_id": self.user_id,
                "device_id": self.device_id,
                "display_name": self.display_name,
                "signing_public_key": self.public_key,
                "key_fingerprint": self.fingerprint,
                "platform": "test",
                "voip_push_token": null,
                "capabilities": ["audio", "video", "mesh", "webrtc"]
            })
        }
    }

    fn test_state() -> AppState {
        let connection = Connection::open_in_memory().unwrap();
        initialize_database(&connection).unwrap();
        AppState {
            database: Arc::new(Mutex::new(connection)),
            configuration: Arc::new(Configuration {
                bind: "127.0.0.1:8080".parse().unwrap(),
                livekit_url: "ws://127.0.0.1:7880".to_string(),
                livekit_api_key: "devkey".to_string(),
                livekit_api_secret: "secret".to_string(),
                service_access_token: None,
                apns: None,
            }),
        }
    }

    fn test_apns_configuration() -> ApnsConfiguration {
        ApnsConfiguration {
            team_id: "TEAM123456".to_string(),
            key_id: "KEY1234567".to_string(),
            bundle_id: "com.trinet.video".to_string(),
            fallback_environment: ApnsEnvironment::Sandbox,
            signing_key: SigningKey::random(&mut OsRng),
            client: reqwest::Client::builder().build().unwrap(),
            provider_token_cache: Arc::new(Mutex::new(None)),
        }
    }

    async fn signed_post(
        application: Router,
        path: &str,
        body: Value,
        device: &TestDevice,
    ) -> (StatusCode, Option<Value>) {
        signed_post_at(
            application,
            path,
            body,
            device,
            unix_time(),
            &random_id("nonce_"),
        )
        .await
    }

    async fn signed_post_at(
        application: Router,
        path: &str,
        body: Value,
        device: &TestDevice,
        timestamp: i64,
        nonce: &str,
    ) -> (StatusCode, Option<Value>) {
        let body = serde_json::to_vec(&body).unwrap();
        let timestamp = timestamp.to_string();
        let body_hash = lowercase_hex(&Sha256::digest(&body));
        let canonical = format!("POST\n{path}\n{timestamp}\n{nonce}\n{body_hash}");
        let signature: p256::ecdsa::Signature = device.signing_key.sign(canonical.as_bytes());
        let request = Request::builder()
            .method("POST")
            .uri(path)
            .header("content-type", "application/json")
            .header("x-trinet-device-id", &device.device_id)
            .header("x-trinet-timestamp", timestamp)
            .header("x-trinet-nonce", nonce)
            .header(
                "x-trinet-signature",
                general_purpose::STANDARD.encode(signature.to_der().as_bytes()),
            )
            .body(Body::from(body))
            .unwrap();
        let response = application.oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value = (!bytes.is_empty())
            .then(|| serde_json::from_slice(&bytes).ok())
            .flatten();
        (status, value)
    }

    #[test]
    fn adapter_similarity_matches_generated_policy() {
        assert!(nicknames_are_confusing("alice", "alica"));
        assert!(nicknames_are_confusing("alice", "alice2"));
        assert!(!nicknames_are_confusing("alice", "bob_net"));
    }

    #[test]
    fn request_signature_future_skew_matches_generated_policy() {
        assert!(internet_call::request_signature_is_fresh(100, 160));
        assert!(!internet_call::request_signature_is_fresh(100, 161));
        assert!(internet_call::request_signature_is_fresh(106, 100));
        assert!(internet_call::request_signature_is_fresh(110, 100));
        assert!(!internet_call::request_signature_is_fresh(111, 100));
    }

    #[tokio::test]
    async fn request_signature_accepts_measured_clock_skew_and_retains_nonce() {
        let state = test_state();
        let device = TestDevice::new("user_skew", "device_skew", "Skewed Phone");
        let signed_at = unix_time() + 6;
        let nonce = "nonce_future_skew_accepted";
        let (status, _) = signed_post_at(
            application(state.clone()),
            "/v1/devices/register",
            device.registration(),
            &device,
            signed_at,
            nonce,
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);

        let expires_at: i64 = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT expires_at FROM request_nonces WHERE device_id = ?1 AND nonce = ?2",
                params![device.device_id, nonce],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            expires_at,
            signed_at + i64::from(internet_call::REQUEST_SIGNATURE_TTL_SECONDS)
        );

        let (status, _) = signed_post_at(
            application(state),
            "/v1/devices/register",
            device.registration(),
            &device,
            unix_time() + 20,
            "nonce_future_skew_rejected",
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn suggestions_are_valid_and_distinct() {
        let existing = ["alice", "alice001"];
        let suggestions = nickname_suggestions("alice", "device", existing.into_iter());
        assert_eq!(suggestions.len(), 3);
        assert!(suggestions.iter().all(|value| nickname_shape_valid(value)));
        assert!(suggestions.iter().all(|value| existing
            .iter()
            .all(|item| !nicknames_are_confusing(value, item))));
    }

    #[test]
    fn livekit_token_is_room_scoped() {
        let configuration = Configuration {
            bind: "127.0.0.1:8080".parse().unwrap(),
            livekit_url: "ws://127.0.0.1:7880".to_string(),
            livekit_api_key: "devkey".to_string(),
            livekit_api_secret: "secret".to_string(),
            service_access_token: None,
            apns: None,
        };
        let token = livekit_token(&configuration, "room_one", "device_one", "Alice").unwrap();
        let payload = token.split('.').nth(1).unwrap();
        let decoded = general_purpose::URL_SAFE_NO_PAD.decode(payload).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(value["video"]["room"], "room_one");
        assert_eq!(value["sub"], "device_one");
        assert_eq!(value["video"]["roomJoin"], true);
    }

    #[test]
    fn apns_provider_token_is_signed_and_reused_for_fifty_minutes() {
        let apns = test_apns_configuration();
        let token = apns.provider_token(1_000).unwrap();
        assert_eq!(apns.provider_token(3_999).unwrap(), token);
        assert_ne!(apns.provider_token(4_000).unwrap(), token);

        let parts = token.split('.').collect::<Vec<_>>();
        assert_eq!(parts.len(), 3);
        let header: Value =
            serde_json::from_slice(&general_purpose::URL_SAFE_NO_PAD.decode(parts[0]).unwrap())
                .unwrap();
        let claims: Value =
            serde_json::from_slice(&general_purpose::URL_SAFE_NO_PAD.decode(parts[1]).unwrap())
                .unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "KEY1234567");
        assert_eq!(claims["iss"], "TEAM123456");
        assert_eq!(claims["iat"], 1_000);
        let signature =
            Signature::from_slice(&general_purpose::URL_SAFE_NO_PAD.decode(parts[2]).unwrap())
                .unwrap();
        apns.signing_key
            .verifying_key()
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .unwrap();
    }

    #[test]
    fn voip_payload_contains_callkit_uuid_without_credentials() {
        let payload = serde_json::to_value(VoipPushPayload {
            aps: ApnsBackgroundContent {
                content_available: 1,
            },
            call_id: "call_1234",
            call_uuid: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            caller: "alice_net",
            audio: true,
            video: true,
        })
        .unwrap();
        assert_eq!(payload["aps"]["content-available"], 1);
        assert_eq!(payload["call_uuid"], "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");
        assert_eq!(payload["caller"], "alice_net");
        assert!(payload.get("token").is_none());
    }

    #[test]
    fn chat_alert_payload_uses_absolute_badge_and_omits_message_text() {
        let payload = serde_json::to_value(AlertPushPayload {
            aps: AlertPushAps {
                alert: AlertPushText {
                    title: "TRI-NET",
                    body: "New message from @alice_net",
                },
                badge: 7,
                sound: "trinet-chat.caf",
                thread_id: Some("chat_1234"),
            },
            data: json!({
                "type": "group_chat_message",
                "chat_id": "chat_1234"
            }),
        })
        .unwrap();
        assert_eq!(payload["aps"]["badge"], 7);
        assert_eq!(payload["aps"]["sound"], "trinet-chat.caf");
        assert_eq!(payload["aps"]["thread-id"], "chat_1234");
        assert_eq!(payload["chat_id"], "chat_1234");
        assert!(payload.to_string().find("Meet at point").is_none());
    }

    #[test]
    fn apns_retry_and_environment_recovery_follow_generated_policy() {
        assert!(internet_call::apns_delivery_failure_is_retryable(true, 0));
        assert!(internet_call::apns_delivery_failure_is_retryable(
            false, 429
        ));
        assert!(internet_call::apns_delivery_failure_is_retryable(
            false, 503
        ));
        assert!(!internet_call::apns_delivery_failure_is_retryable(
            false, 400
        ));
        assert!(internet_call::apns_should_retry(true, 1));
        assert!(internet_call::apns_should_retry(true, 2));
        assert!(!internet_call::apns_should_retry(true, 3));
        assert!(internet_call::apns_should_try_alternate_environment(
            true, false
        ));
        assert!(!internet_call::apns_should_try_alternate_environment(
            true, true
        ));

        assert!(apns_failure_is_permanent("BadDeviceToken"));
        assert!(!internet_call::apns_token_should_be_invalidated(
            true, true, false, true,
        ));
        assert!(internet_call::apns_token_should_be_invalidated(
            true, true, true, true,
        ));
        for reason in ["DeviceTokenNotForTopic", "Unregistered"] {
            assert!(apns_failure_is_permanent(reason));
            assert!(internet_call::apns_token_should_be_invalidated(
                apns_failure_is_permanent(reason),
                false,
                false,
                true,
            ));
        }
        for reason in ["TooManyRequests", "InternalServerError", "Shutdown"] {
            assert!(!apns_failure_is_permanent(reason));
            assert!(!internet_call::apns_token_should_be_invalidated(
                apns_failure_is_permanent(reason),
                false,
                false,
                true,
            ));
        }
        assert!(!internet_call::apns_token_should_be_invalidated(
            true, true, true, false,
        ));
    }

    #[test]
    fn configured_provider_routes_both_apns_environments_per_token() {
        let apns = test_apns_configuration();
        let configuration = Configuration {
            bind: "127.0.0.1:8080".parse().unwrap(),
            livekit_url: "ws://127.0.0.1:7880".to_string(),
            livekit_api_key: "devkey".to_string(),
            livekit_api_secret: "secret".to_string(),
            service_access_token: None,
            apns: Some(apns),
        };
        let target = CallTarget {
            device_id: "callee_device".to_string(),
            capabilities: internet_call::CAP_AUDIO | internet_call::CAP_WEBRTC,
            last_seen: 0,
            voip_push_token: Some("ab".repeat(32)),
            push_environment: "sandbox".to_string(),
        };
        assert!(voip_push_is_reachable(&configuration, &target));
        assert!(internet_call::call_target_is_available(
            1,
            2,
            3,
            4,
            target.capabilities,
            false,
            voip_push_is_reachable(&configuration, &target),
        ));
        let mismatched = CallTarget {
            push_environment: "production".to_string(),
            ..target
        };
        assert!(voip_push_is_reachable(&configuration, &mismatched));
    }

    #[tokio::test]
    async fn signed_nickname_to_call_flow_is_end_to_end() {
        let state = test_state();
        let caller = TestDevice::new("user_alice", "device_alice", "Alice Phone");
        let callee = TestDevice::new("user_bob", "device_bob", "Bob Phone");

        for device in [&caller, &callee] {
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                device.registration(),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
        }

        for (device, nickname) in [(&caller, "alice_net"), (&callee, "bob_net")] {
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/directory/nicknames/claim",
                json!({
                    "nickname": nickname,
                    "user_id": device.user_id,
                    "device_id": device.device_id
                }),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response.unwrap()["claimed"], true);
        }

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/directory/search",
            json!({"query": "bob", "limit": 20}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["results"][0]["nickname"], "bob_net");

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "callee": "bob_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": true
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let created = response.unwrap();
        let call_id = created["call_id"].as_str().unwrap();
        let room_id = created["room_id"].as_str().unwrap();
        assert!(!created["token"].as_str().unwrap().is_empty());

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls/incoming",
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let incoming = response.unwrap();
        assert_eq!(incoming["calls"][0]["call_id"], call_id);
        Uuid::parse_str(incoming["calls"][0]["call_uuid"].as_str().unwrap()).unwrap();

        let join_path = format!("/v1/calls/{call_id}/join");
        let (status, _) = signed_post(
            application(state.clone()),
            &join_path,
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let (status, response) = signed_post(
            application(state),
            &join_path,
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["room_id"], room_id);
    }

    #[tokio::test]
    async fn device_registration_persists_separate_voip_and_alert_tokens() {
        let state = test_state();
        let device = TestDevice::new("user_push", "device_push", "Push Phone");
        let voip_token = "ab".repeat(32);
        let alert_token = "cd".repeat(32);
        let mut registration = device.registration();
        registration["voip_push_token"] = Value::String(voip_token.clone());
        registration["alert_push_token"] = Value::String(alert_token.clone());
        registration["push_environment"] = Value::String("development".to_string());
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/devices/register",
            registration,
            &device,
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let stored = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT voip_push_token, alert_push_token, push_environment
                 FROM devices WHERE device_id = ?1",
                params![device.device_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(stored, (voip_token, alert_token, "sandbox".to_string()));

        let invalid_device =
            TestDevice::new("user_invalid_push", "device_invalid_push", "Invalid Push");
        let mut invalid_registration = invalid_device.registration();
        invalid_registration["voip_push_token"] = Value::String("not-a-token".to_string());
        let (status, _) = signed_post(
            application(state),
            "/v1/devices/register",
            invalid_registration,
            &invalid_device,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn originating_device_can_cancel_pending_call_idempotently() {
        let state = test_state();
        let caller = TestDevice::new("user_caller", "device_caller", "Caller Phone");
        let caller_other_device = TestDevice::new(
            "user_caller_temporary",
            "device_caller_other",
            "Caller Tablet",
        );
        let callee = TestDevice::new("user_callee", "device_callee", "Callee Phone");

        for device in [&caller, &caller_other_device, &callee] {
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                device.registration(),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
        }
        for (device, nickname) in [(&caller, "caller_net"), (&callee, "receiver_net")] {
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/directory/nicknames/claim",
                json!({
                    "nickname": nickname,
                    "user_id": device.user_id,
                    "device_id": device.device_id
                }),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response.unwrap()["claimed"], true);
        }

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/account/link-code",
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let link_code = response.unwrap()["link_code"].as_str().unwrap().to_string();
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/account/link",
            json!({
                "user_id": caller_other_device.user_id,
                "device_id": caller_other_device.device_id,
                "link_code": link_code
            }),
            &caller_other_device,
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "callee": "receiver_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": true
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let call_id = response.unwrap()["call_id"].as_str().unwrap().to_string();
        let cancel_path = format!("/v1/calls/{call_id}/cancel");

        let (status, _) = signed_post(
            application(state.clone()),
            &cancel_path,
            json!({
                "user_id": caller.user_id,
                "device_id": caller_other_device.device_id
            }),
            &caller_other_device,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let (status, _) = signed_post(
            application(state.clone()),
            &cancel_path,
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        for _ in 0..2 {
            let (status, _) = signed_post(
                application(state.clone()),
                &cancel_path,
                json!({"user_id": caller.user_id, "device_id": caller.device_id}),
                &caller,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
        }

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls/incoming",
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(response.unwrap()["calls"].as_array().unwrap().is_empty());

        let join_path = format!("/v1/calls/{call_id}/join");
        let (status, _) = signed_post(
            application(state),
            &join_path,
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn linked_devices_share_nickname_and_first_answer_wins() {
        let state = test_state();
        let caller = TestDevice::new("user_caller", "device_caller", "Caller Phone");
        let owner_phone = TestDevice::new("user_owner", "device_owner_phone", "Owner iPhone");
        let owner_mac = TestDevice::new("user_temporary", "device_owner_mac", "Owner Mac");

        for device in [&caller, &owner_phone, &owner_mac] {
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                device.registration(),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
        }

        for (device, nickname) in [
            (&caller, "caller_net"),
            (&owner_phone, "owner_net"),
            (&owner_mac, "old_mac_net"),
        ] {
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/directory/nicknames/claim",
                json!({
                    "nickname": nickname,
                    "user_id": device.user_id,
                    "device_id": device.device_id
                }),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response.unwrap()["claimed"], true);
        }

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/account/link-code",
            json!({"user_id": owner_phone.user_id, "device_id": owner_phone.device_id}),
            &owner_phone,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let link_code = response.unwrap()["link_code"].as_str().unwrap().to_string();

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/account/link",
            json!({
                "user_id": owner_mac.user_id,
                "device_id": owner_mac.device_id,
                "link_code": link_code
            }),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let snapshot = response.unwrap();
        assert_eq!(snapshot["account_id"], owner_phone.user_id);
        assert_eq!(snapshot["nickname"], "owner_net");
        assert_eq!(snapshot["devices"].as_array().unwrap().len(), 2);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "callee": "owner_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": true
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let call_id = response.unwrap()["call_id"].as_str().unwrap().to_string();

        for device in [&owner_phone, &owner_mac] {
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/calls/incoming",
                json!({"user_id": owner_phone.user_id, "device_id": device.device_id}),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response.unwrap()["calls"][0]["call_id"], call_id);
        }

        let join_path = format!("/v1/calls/{call_id}/join");
        let (status, _) = signed_post(
            application(state.clone()),
            &join_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_mac.device_id}),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, _) = signed_post(
            application(state),
            &join_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_phone.device_id}),
            &owner_phone,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn group_chat_is_shared_by_member_accounts_and_messages_are_idempotent() {
        let state = test_state();
        let alice = TestDevice::new("user_alice", "device_alice", "Alice Phone");
        let bob = TestDevice::new("user_bob", "device_bob", "Bob Phone");
        let carol = TestDevice::new("user_carol", "device_carol", "Carol Phone");
        let outsider = TestDevice::new("user_dave", "device_dave", "Dave Phone");

        for (device, nickname) in [
            (&alice, "alice_net"),
            (&bob, "bob_net"),
            (&carol, "carol_net"),
            (&outsider, "dave_net"),
        ] {
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                device.registration(),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/directory/nicknames/claim",
                json!({
                    "nickname": nickname,
                    "user_id": device.user_id,
                    "device_id": device.device_id
                }),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(response.unwrap()["claimed"], true);
        }

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/chats",
            json!({
                "creator_user_id": alice.user_id,
                "creator_device_id": alice.device_id,
                "title": "Field team",
                "members": ["@bob_net", "carol_net"]
            }),
            &alice,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let created = response.unwrap();
        let chat_id = created["chat_id"].as_str().unwrap().to_string();
        assert_eq!(created["members"].as_array().unwrap().len(), 3);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/chats/list",
            json!({"user_id": bob.user_id, "device_id": bob.device_id}),
            &bob,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["chats"][0]["chat_id"], chat_id);

        let message_path = format!("/v1/chats/{chat_id}/messages");
        let message_body = json!({
            "user_id": alice.user_id,
            "device_id": alice.device_id,
            "client_message_id": "message-0001",
            "text": "Meet at point three"
        });
        let (status, response) = signed_post(
            application(state.clone()),
            &message_path,
            message_body.clone(),
            &alice,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let first_message_id = response.unwrap()["message_id"].as_i64().unwrap();
        let (status, response) = signed_post(
            application(state.clone()),
            &message_path,
            message_body,
            &alice,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            response.unwrap()["message_id"].as_i64().unwrap(),
            first_message_id
        );

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/chats/list",
            json!({"user_id": bob.user_id, "device_id": bob.device_id}),
            &bob,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let chats = response.unwrap();
        assert_eq!(chats["chats"][0]["unread_count"], 1);
        assert_eq!(chats["total_unread_count"], 1);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/chats/list",
            json!({"user_id": alice.user_id, "device_id": alice.device_id}),
            &alice,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["total_unread_count"], 0);

        let read_path = format!("/v1/chats/{chat_id}/read");
        let (status, _) = signed_post(
            application(state.clone()),
            &read_path,
            json!({
                "user_id": bob.user_id,
                "device_id": bob.device_id,
                "through_message_id": first_message_id
            }),
            &bob,
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/chats/list",
            json!({"user_id": bob.user_id, "device_id": bob.device_id}),
            &bob,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["total_unread_count"], 0);

        let list_path = format!("/v1/chats/{chat_id}/messages/list");
        let (status, response) = signed_post(
            application(state.clone()),
            &list_path,
            json!({
                "user_id": carol.user_id,
                "device_id": carol.device_id,
                "after_message_id": 0,
                "limit": 50
            }),
            &carol,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            response.unwrap()["messages"][0]["text"],
            "Meet at point three"
        );

        let (status, _) = signed_post(
            application(state),
            &list_path,
            json!({
                "user_id": outsider.user_id,
                "device_id": outsider.device_id,
                "after_message_id": 0,
                "limit": 50
            }),
            &outsider,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn nickname_call_rejects_a_stale_destination() {
        let state = test_state();
        let caller = TestDevice::new("user_online", "device_online", "Online Phone");
        let callee = TestDevice::new("user_stale", "device_stale", "Stale Phone");
        for (device, nickname) in [(&caller, "online_net"), (&callee, "stale_net")] {
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                device.registration(),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/directory/nicknames/claim",
                json!({
                    "nickname": nickname,
                    "user_id": device.user_id,
                    "device_id": device.device_id
                }),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
        }
        state
            .database
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET last_seen = ?1 WHERE device_id = ?2",
                params![
                    unix_time() - i64::from(internet_call::PRESENCE_TTL_SECONDS) - 1,
                    callee.device_id
                ],
            )
            .unwrap();

        let (status, _) = signed_post(
            application(state),
            "/v1/calls",
            json!({
                "callee": "stale_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": true
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
    }
}
