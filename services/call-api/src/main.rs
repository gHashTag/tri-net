//! TRI-NET Internet directory and call-signaling adapter.
//!
//! Business policy is generated from `specs/*.t27`. This binary owns only
//! HTTP, cryptographic proof verification, SQLite persistence, and LiveKit
//! participant-token generation.

use std::{
    collections::HashSet,
    env, fs,
    net::{IpAddr, SocketAddr},
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
#[path = "../../../gen/rust/direct_message.rs"]
mod direct_message;
#[path = "../../../gen/rust/group_chat.rs"]
mod group_chat;
#[path = "../../../gen/rust/internet_call.rs"]
mod internet_call;
#[path = "../../../gen/rust/nickname_directory.rs"]
mod nickname_directory;

type HmacSha256 = Hmac<Sha256>;

const APNS_OUTBOX_CALL_INVITE: &str = "call_invite";
const APNS_OUTBOX_DIRECT_MESSAGE: &str = "direct_message";
const APNS_OUTBOX_IDLE_POLL_MS: u64 = 250;
const APNS_OUTBOX_ERROR_POLL_MS: u64 = 1_000;
const LIVEKIT_TWIRP_ERROR_MAX_BYTES: usize = 1_024;

#[derive(Clone)]
struct AppState {
    database: Arc<Mutex<Connection>>,
    configuration: Arc<Configuration>,
    apns_outbox_owner: String,
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
    reason: Option<String>,
    token_invalid_at_ms: Option<i64>,
    permanent: bool,
    bad_device_token: bool,
    token_invalid: bool,
    refresh_provider_token: bool,
    transient: bool,
    alternate_attempted: bool,
}

struct ApnsDeliverySuccess {
    environment: ApnsEnvironment,
    environment_changed: bool,
}

struct ApnsOutboxEvent {
    event_id: String,
    event_kind: String,
    object_id: String,
    target_device_id: String,
    payload_json: String,
    attempts: u32,
    claimed_at: i64,
    claim_owner: String,
    delivery_environment: Option<String>,
    delivery_token_digest: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct CallInviteOutboxPayload {
    call_id: String,
    call_uuid: String,
    caller: String,
    audio: bool,
    video: bool,
}

#[derive(Deserialize, Serialize)]
struct DirectMessageOutboxPayload {
    sender_user_id: String,
    sender_nickname: String,
}

enum ApnsOutboxDelivery {
    CallInvite {
        token: String,
        environment: ApnsEnvironment,
        used_environment_override: bool,
        call_id: String,
        call_uuid: String,
        caller: String,
        audio: bool,
        video: bool,
    },
    DirectMessage {
        token: String,
        environment: ApnsEnvironment,
        used_environment_override: bool,
        sender: String,
        sender_user_id: String,
        badge: u32,
        expiration: i64,
    },
}

impl ApnsOutboxDelivery {
    fn token(&self) -> &str {
        match self {
            Self::CallInvite { token, .. } | Self::DirectMessage { token, .. } => token,
        }
    }

    fn token_column(&self) -> &'static str {
        match self {
            Self::CallInvite { .. } => "voip_push_token",
            Self::DirectMessage { .. } => "alert_push_token",
        }
    }

    fn environment(&self) -> ApnsEnvironment {
        match self {
            Self::CallInvite { environment, .. } | Self::DirectMessage { environment, .. } => {
                *environment
            }
        }
    }

    fn used_environment_override(&self) -> bool {
        match self {
            Self::CallInvite {
                used_environment_override,
                ..
            }
            | Self::DirectMessage {
                used_environment_override,
                ..
            } => *used_environment_override,
        }
    }
}

impl std::fmt::Display for ApnsDeliveryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.status {
            Some(status) => write!(
                formatter,
                "APNs request failed (status {status}, reason={}, permanent={}, transient={}, alternate_attempted={})",
                self.reason.as_deref().unwrap_or("unknown"),
                self.permanent,
                self.transient,
                self.alternate_attempted
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
    timestamp: Option<i64>,
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

    fn discard_cached_provider_token(&self) {
        if let Ok(mut cache) = self.provider_token_cache.lock() {
            *cache = None;
        }
    }

    fn can_route_environment(&self, value: &str) -> bool {
        ApnsEnvironment::parse(value).is_ok()
    }

    async fn send_voip_once(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        call_id: &str,
        call_uuid: &str,
        caller: &str,
        audio: bool,
        video: bool,
    ) -> Result<(), ApnsDeliveryError> {
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
        self.send_once(
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
        expiration: i64,
        apns_id: Option<&str>,
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
            &expiration.max(0).to_string(),
            apns_id,
            &payload,
        )
        .await
    }

    async fn send_alert_once(
        &self,
        token: &str,
        environment: ApnsEnvironment,
        title: &str,
        body: &str,
        badge: u32,
        sound: &str,
        thread_id: Option<&str>,
        expiration: i64,
        apns_id: Option<&str>,
        data: serde_json::Value,
    ) -> Result<(), ApnsDeliveryError> {
        let payload = AlertPushPayload {
            aps: AlertPushAps {
                alert: AlertPushText { title, body },
                badge,
                sound,
                thread_id,
            },
            data,
        };
        self.send_once(
            token,
            environment,
            &self.bundle_id,
            "alert",
            "10",
            &expiration.max(0).to_string(),
            apns_id,
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
                Err(error) => {
                    if error.refresh_provider_token {
                        self.discard_cached_provider_token();
                    }
                    if internet_call::apns_should_retry(error.transient, attempts_completed) {
                        let jitter =
                            OsRng.next_u32() % (internet_call::APNS_RETRY_MAX_JITTER_MS + 1);
                        let delay = internet_call::apns_retry_delay_ms(attempts_completed, jitter);
                        tokio::time::sleep(Duration::from_millis(u64::from(delay))).await;
                        continue;
                    }
                    return Err(error);
                }
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
                reason: None,
                token_invalid_at_ms: None,
                permanent: true,
                bad_device_token: false,
                token_invalid: false,
                refresh_provider_token: false,
                transient: false,
                alternate_attempted: false,
            });
        }
        let provider_token = self
            .provider_token(unix_time())
            .map_err(|_| ApnsDeliveryError {
                status: None,
                reason: None,
                token_invalid_at_ms: None,
                permanent: false,
                bad_device_token: false,
                token_invalid: false,
                refresh_provider_token: false,
                transient: false,
                alternate_attempted: false,
            })?;
        let mut headers = RequestHeaders::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("bearer {provider_token}")).map_err(|_| {
                ApnsDeliveryError {
                    status: None,
                    reason: None,
                    token_invalid_at_ms: None,
                    permanent: false,
                    bad_device_token: false,
                    token_invalid: false,
                    refresh_provider_token: false,
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
                    reason: None,
                    token_invalid_at_ms: None,
                    permanent: false,
                    bad_device_token: false,
                    token_invalid: false,
                    refresh_provider_token: false,
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
                    reason: None,
                    token_invalid_at_ms: None,
                    permanent: false,
                    bad_device_token: false,
                    token_invalid: false,
                    refresh_provider_token: false,
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
                reason: None,
                token_invalid_at_ms: None,
                permanent: false,
                bad_device_token: false,
                token_invalid: false,
                refresh_provider_token: false,
                transient: internet_call::apns_delivery_failure_is_retryable(true, 0),
                alternate_attempted: false,
            })?;
        if response.status().is_success() {
            return Ok(());
        }
        let status = response.status();
        let response_body = response.json::<ApnsErrorResponse>().await.ok();
        let token_invalid_at_ms = response_body
            .as_ref()
            .and_then(|body| body.timestamp)
            .filter(|timestamp| *timestamp >= 0);
        let reason = response_body
            .and_then(|body| body.reason)
            .map(|reason| bounded_apns_reason(&reason))
            .unwrap_or_else(|| "unknown".to_string());
        let status_code = u32::from(status.as_u16());
        let refresh_provider_token = reason == "ExpiredProviderToken";
        let transient = internet_call::apns_delivery_failure_is_retryable(false, status_code)
            || refresh_provider_token
            || reason == "IdleTimeout";
        let permanent = apns_failure_is_terminal(&reason);
        let bad_device_token = reason == "BadDeviceToken";
        let token_invalid = apns_failure_invalidates_token(&reason);
        Err(ApnsDeliveryError {
            status: Some(status.as_u16()),
            reason: Some(reason),
            token_invalid_at_ms: token_invalid.then_some(token_invalid_at_ms).flatten(),
            permanent,
            bad_device_token,
            token_invalid,
            refresh_provider_token,
            transient,
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

fn apns_failure_invalidates_token(reason: &str) -> bool {
    matches!(
        reason,
        "BadDeviceToken" | "DeviceTokenNotForTopic" | "ExpiredToken" | "Unregistered"
    )
}

fn bounded_apns_reason(reason: &str) -> String {
    if !reason.is_empty()
        && reason.len() <= 64
        && reason.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        reason.to_string()
    } else {
        "unknown".to_string()
    }
}

fn apns_failure_is_terminal(reason: &str) -> bool {
    matches!(
        reason,
        "BadCollapseId"
            | "BadDeviceToken"
            | "BadExpirationDate"
            | "BadMessageId"
            | "BadPriority"
            | "DeviceTokenNotForTopic"
            | "DuplicateHeaders"
            | "ExpiredToken"
            | "MissingDeviceToken"
            | "MissingTopic"
            | "PayloadEmpty"
            | "PayloadTooLarge"
            | "Unregistered"
            | "BadPath"
            | "MethodNotAllowed"
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

fn normalize_text_encryption_public_key(value: Option<&str>) -> Result<Option<String>, ApiError> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    if value.len() > 48 {
        return Err(ApiError::bad_request("invalid text-encryption public key"));
    }
    let decoded = general_purpose::STANDARD
        .decode(value)
        .map_err(|_| ApiError::bad_request("invalid text-encryption public key"))?;
    let all_zero = decoded.iter().all(|byte| *byte == 0);
    if !direct_message::text_key_is_valid(decoded.len().min(u16::MAX as usize) as u16, all_zero) {
        return Err(ApiError::bad_request(
            "text-encryption public key must be a non-zero 32-byte X25519 key",
        ));
    }
    Ok(Some(general_purpose::STANDARD.encode(decoded)))
}

fn normalize_uuid(value: &str, field: &str) -> Result<String, ApiError> {
    Uuid::parse_str(value.trim())
        .map(|value| value.to_string())
        .map_err(|_| ApiError::bad_request(format!("invalid {field}")))
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

    fn too_many_requests(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
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
    text_encryption_public_key: Option<String>,
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
    client_call_id: String,
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
struct CallParticipantRequest {
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

#[derive(Serialize)]
struct CallStatusResponse {
    call_id: String,
    call_uuid: String,
    status: &'static str,
    role: &'static str,
    target_status: Option<&'static str>,
    answered_here: bool,
    created_at: i64,
    answered_at: Option<i64>,
    ended_at: Option<i64>,
}

struct CallTarget {
    device_id: String,
    capabilities: u8,
    last_seen: i64,
    voip_push_token: Option<String>,
    push_environment: String,
}

struct CallStatusRecord {
    room_id: String,
    call_uuid: String,
    caller_user_id: String,
    caller_device_id: String,
    callee_user_id: String,
    status: u8,
    created_at: i64,
    answered_at: Option<i64>,
    answered_device_id: Option<String>,
    ended_at: Option<i64>,
    target_status: Option<u8>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct DirectMessageRecipientRequest {
    user_id: String,
    device_id: String,
    nickname: String,
}

#[derive(Serialize)]
struct DirectMessageRecipientResponse {
    crypto_version: u8,
    nickname: String,
    user_id: String,
    devices: Vec<DirectMessageRecipientDevice>,
}

#[derive(Serialize)]
struct DirectMessageRecipientDevice {
    device_id: String,
    text_encryption_public_key: String,
    text_encryption_key_fingerprint: String,
    key_fingerprint: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct SendDirectMessageRequest {
    user_id: String,
    device_id: String,
    recipient: String,
    client_message_id: String,
    envelopes: Vec<DirectMessageEnvelopeRequest>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct DirectMessageEnvelopeRequest {
    crypto_version: u8,
    recipient_device_id: String,
    recipient_key_fingerprint: String,
    ephemeral_public_key: String,
    nonce: String,
    ciphertext: String,
    sender_signature: String,
}

struct NormalizedDirectMessageEnvelope {
    crypto_version: u8,
    recipient_device_id: String,
    recipient_key_fingerprint: String,
    ephemeral_public_key: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    sender_signature: Vec<u8>,
}

#[derive(Serialize)]
struct DirectMessageSendResponse {
    message_id: i64,
    client_message_id: String,
    recipient_user_id: String,
    recipient_nickname: String,
    created_at: i64,
    inserted: bool,
}

struct ExistingDirectMessage {
    sender_user_id: String,
    response: DirectMessageSendResponse,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct DirectMessageInboxRequest {
    user_id: String,
    device_id: String,
    after_message_id: i64,
    limit: u16,
}

#[derive(Serialize)]
struct DirectMessageInboxResponse {
    messages: Vec<DirectMessageInboxMessage>,
    total_unread_count: u32,
}

#[derive(Serialize)]
struct DirectMessageInboxMessage {
    message_id: i64,
    client_message_id: String,
    sender_user_id: String,
    sender_device_id: String,
    sender_nickname: String,
    sender_signing_public_key: String,
    sender_key_fingerprint: String,
    recipient_nickname: String,
    crypto_version: u8,
    recipient_device_id: String,
    recipient_key_fingerprint: String,
    ephemeral_public_key: String,
    nonce: String,
    ciphertext: String,
    sender_signature: String,
    created_at: i64,
    read: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
struct MarkDirectMessageReadRequest {
    user_id: String,
    device_id: String,
    sender_user_id: String,
    through_message_id: i64,
}

#[derive(Serialize)]
struct DirectMessageReadResponse {
    last_read_message_id: i64,
    total_unread_count: u32,
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
struct CreateCallConflictResponse {
    call_id: String,
    status: &'static str,
    reason: &'static str,
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
    signing_public_key: String,
    key_fingerprint: String,
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
struct LiveKitRoomServiceClaims<'a> {
    iss: &'a str,
    nbf: i64,
    exp: i64,
    video: LiveKitRoomServiceGrant,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveKitRoomServiceGrant {
    room_create: bool,
}

#[derive(Serialize)]
struct LiveKitDeleteRoomRequest<'a> {
    room: &'a str,
}

#[derive(Deserialize)]
struct LiveKitTwirpErrorResponse {
    code: String,
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
        apns_outbox_owner: Uuid::new_v4().to_string(),
    };

    if state.configuration.apns.is_some() {
        for _ in 0..internet_call::APNS_VOIP_OUTBOX_WORKERS {
            tokio::spawn(run_apns_outbox_worker(
                state.clone(),
                APNS_OUTBOX_CALL_INVITE,
            ));
        }
        tokio::spawn(run_apns_outbox_worker(
            state.clone(),
            APNS_OUTBOX_DIRECT_MESSAGE,
        ));
    }

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
        .route("/v1/calls/{call_id}/decline", post(decline_call))
        .route("/v1/calls/{call_id}/status", post(call_status))
        .route("/v1/calls/{call_id}/end", post(end_call))
        .route("/v1/calls/{call_id}/cancel", post(cancel_call))
        .route(
            "/v1/direct-messages/recipients",
            post(resolve_direct_message_recipient),
        )
        .route("/v1/direct-messages", post(send_direct_message))
        .route("/v1/direct-messages/inbox", post(list_direct_messages))
        .route("/v1/direct-messages/read", post(mark_direct_messages_read))
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
             text_encryption_public_key TEXT,
             key_fingerprint TEXT NOT NULL,
             platform TEXT NOT NULL,
             voip_push_token TEXT,
             voip_push_token_registered_at_ms INTEGER,
             alert_push_token TEXT,
             alert_push_token_registered_at_ms INTEGER,
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
             client_call_id TEXT,
             call_uuid TEXT NOT NULL,
             room_id TEXT NOT NULL UNIQUE,
             caller_user_id TEXT NOT NULL,
             caller_device_id TEXT NOT NULL,
             callee_user_id TEXT NOT NULL,
             callee_device_id TEXT NOT NULL,
             callee_nickname TEXT,
             caller_name TEXT NOT NULL,
             audio INTEGER NOT NULL,
             video INTEGER NOT NULL,
             status INTEGER NOT NULL,
             created_at INTEGER NOT NULL,
             answered_at INTEGER,
             answered_device_id TEXT,
             ended_at INTEGER
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
         );
         CREATE TABLE IF NOT EXISTS direct_messages (
             message_id INTEGER PRIMARY KEY AUTOINCREMENT,
             sender_user_id TEXT NOT NULL,
             sender_device_id TEXT NOT NULL,
             sender_nickname TEXT NOT NULL,
             sender_signing_public_key TEXT NOT NULL,
             sender_key_fingerprint TEXT NOT NULL,
             recipient_user_id TEXT NOT NULL,
             recipient_nickname TEXT NOT NULL,
             client_message_id TEXT NOT NULL,
             created_at INTEGER NOT NULL,
             UNIQUE(sender_device_id, client_message_id)
         );
         CREATE INDEX IF NOT EXISTS direct_messages_recipient
             ON direct_messages(recipient_user_id, message_id);
         CREATE TABLE IF NOT EXISTS direct_message_envelopes (
             message_id INTEGER NOT NULL REFERENCES direct_messages(message_id)
                 ON DELETE CASCADE,
             crypto_version INTEGER NOT NULL,
             recipient_device_id TEXT NOT NULL REFERENCES devices(device_id),
             recipient_key_fingerprint TEXT NOT NULL,
             ephemeral_public_key BLOB NOT NULL,
             nonce BLOB NOT NULL,
             ciphertext BLOB NOT NULL,
             sender_signature BLOB NOT NULL,
             PRIMARY KEY(message_id, recipient_device_id)
         );
         CREATE INDEX IF NOT EXISTS direct_message_envelopes_inbox
             ON direct_message_envelopes(recipient_device_id, message_id);
         CREATE TABLE IF NOT EXISTS direct_message_read_state (
             owner_user_id TEXT NOT NULL,
             peer_user_id TEXT NOT NULL,
             last_read_message_id INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY(owner_user_id, peer_user_id)
         );
         CREATE TABLE IF NOT EXISTS apns_outbox (
             event_id TEXT PRIMARY KEY,
             event_kind TEXT NOT NULL,
             object_id TEXT NOT NULL,
             target_device_id TEXT NOT NULL,
             payload_json TEXT NOT NULL,
             attempts INTEGER NOT NULL DEFAULT 0,
             next_attempt_at INTEGER NOT NULL,
             claimed_at INTEGER,
             claim_owner TEXT,
             blocked_owner TEXT,
             delivery_environment TEXT,
             delivery_token_digest TEXT,
             last_failure_kind TEXT,
             last_status INTEGER,
             created_at INTEGER NOT NULL,
             UNIQUE(event_kind, object_id, target_device_id)
         );
         CREATE INDEX IF NOT EXISTS apns_outbox_due
             ON apns_outbox(next_attempt_at, claimed_at, created_at);",
    )?;
    ensure_column(connection, "apns_outbox", "claim_owner", "TEXT")?;
    ensure_column(connection, "apns_outbox", "blocked_owner", "TEXT")?;
    ensure_column(connection, "apns_outbox", "delivery_environment", "TEXT")?;
    ensure_column(connection, "apns_outbox", "delivery_token_digest", "TEXT")?;
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
        "voip_push_token_registered_at_ms",
        "INTEGER",
    )?;
    ensure_column(
        connection,
        "devices",
        "alert_push_token_registered_at_ms",
        "INTEGER",
    )?;
    ensure_column(connection, "devices", "text_encryption_public_key", "TEXT")?;
    ensure_column(
        connection,
        "devices",
        "push_environment",
        "TEXT NOT NULL DEFAULT 'sandbox'",
    )?;
    ensure_column(connection, "calls", "answered_device_id", "TEXT")?;
    ensure_column(connection, "calls", "call_uuid", "TEXT")?;
    ensure_column(connection, "calls", "client_call_id", "TEXT")?;
    ensure_column(connection, "calls", "callee_nickname", "TEXT")?;
    ensure_column(connection, "calls", "ended_at", "INTEGER")?;
    ensure_column(
        connection,
        "direct_message_envelopes",
        "crypto_version",
        "INTEGER NOT NULL DEFAULT 1",
    )?;
    connection.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS calls_caller_client_id
         ON calls(caller_device_id, client_call_id)",
        [],
    )?;
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
    connection.execute(
        "UPDATE devices
         SET voip_push_token_registered_at_ms = last_seen * 1000
         WHERE voip_push_token IS NOT NULL
           AND voip_push_token_registered_at_ms IS NULL",
        [],
    )?;
    connection.execute(
        "UPDATE devices
         SET alert_push_token_registered_at_ms = last_seen * 1000
         WHERE alert_push_token IS NOT NULL
           AND alert_push_token_registered_at_ms IS NULL",
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

fn apns_outbox_event_id(event_kind: &str, object_id: &str, target_device_id: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"TRINET-APNS-OUTBOX-V1");
    for field in [
        event_kind.as_bytes(),
        object_id.as_bytes(),
        target_device_id.as_bytes(),
    ] {
        digest.update(u32::try_from(field.len()).unwrap_or(u32::MAX).to_be_bytes());
        digest.update(field);
    }
    let digest = digest.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes).to_string()
}

fn direct_message_alert_data(sender_user_id: &str, sender_nickname: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "direct_message",
        "sender_user_id": sender_user_id,
        "sender_nickname": sender_nickname
    })
}

fn apns_token_digest(token: &str) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

fn apns_outbox_delivery_environment(
    event: &ApnsOutboxEvent,
    token: &str,
    registered_environment: ApnsEnvironment,
) -> (ApnsEnvironment, bool) {
    let token_matches = event.delivery_token_digest.as_deref() == Some(&apns_token_digest(token));
    let override_environment = event
        .delivery_environment
        .as_deref()
        .and_then(|value| ApnsEnvironment::parse(value).ok());
    match (token_matches, override_environment) {
        (true, Some(environment)) => (environment, true),
        _ => (registered_environment, false),
    }
}

fn enqueue_apns_outbox_event<T: Serialize>(
    transaction: &rusqlite::Transaction<'_>,
    event_kind: &str,
    object_id: &str,
    target_device_id: &str,
    payload: &T,
    now: i64,
) -> Result<(), ApiError> {
    let event_id = apns_outbox_event_id(event_kind, object_id, target_device_id);
    let payload_json = serde_json::to_string(payload)
        .map_err(|_| ApiError::internal("could not serialize APNs outbox payload"))?;
    transaction.execute(
        "INSERT OR IGNORE INTO apns_outbox
         (event_id, event_kind, object_id, target_device_id, payload_json,
          attempts, next_attempt_at, claimed_at, last_failure_kind,
          last_status, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, NULL, NULL, NULL, ?6)",
        params![
            event_id,
            event_kind,
            object_id,
            target_device_id,
            payload_json,
            now
        ],
    )?;
    Ok(())
}

fn claim_due_apns_outbox_event(
    database: &mut Connection,
    event_kind: &str,
    claim_owner: &str,
    now: i64,
) -> Result<Option<ApnsOutboxEvent>, ApiError> {
    let lease_cutoff =
        now.saturating_sub(i64::from(internet_call::APNS_OUTBOX_CLAIM_LEASE_SECONDS));
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let candidate = transaction
        .query_row(
            "SELECT event_id, event_kind, object_id, target_device_id,
                    payload_json, attempts, claimed_at, claim_owner,
                    delivery_environment, delivery_token_digest, blocked_owner
             FROM apns_outbox
             WHERE next_attempt_at <= ?1
               AND (blocked_owner IS NULL OR blocked_owner != ?3)
               AND (claimed_at IS NULL OR claim_owner IS NULL
                    OR claim_owner != ?3 OR claimed_at <= ?2)
               AND event_kind = ?4
             ORDER BY next_attempt_at, created_at, event_id
             LIMIT 1",
            params![now, lease_cutoff, claim_owner, event_kind],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<String>>(10)?,
                ))
            },
        )
        .optional()?;
    let Some(candidate) = candidate else {
        transaction.commit()?;
        return Ok(None);
    };
    if let Some(blocked_owner) = candidate.10.as_deref() {
        let same_process_owner = blocked_owner == claim_owner;
        if !internet_call::apns_outbox_block_is_recoverable(same_process_owner) {
            transaction.commit()?;
            return Ok(None);
        }
    }
    if let Some(claimed_at) = candidate.6 {
        let same_process_owner = candidate.7.as_deref() == Some(claim_owner);
        let recoverable = u32::try_from(claimed_at)
            .ok()
            .zip(u32::try_from(now).ok())
            .is_some_and(|(claimed_at, now)| {
                internet_call::apns_outbox_claim_is_recoverable(same_process_owner, claimed_at, now)
            });
        if !recoverable {
            transaction.commit()?;
            return Ok(None);
        }
    }
    let claimed = transaction.execute(
        "UPDATE apns_outbox SET claimed_at = ?1, claim_owner = ?2
         WHERE event_id = ?3
           AND next_attempt_at <= ?1
           AND (blocked_owner IS NULL OR blocked_owner != ?2)
           AND (claimed_at IS NULL OR claim_owner IS NULL
                OR claim_owner != ?2 OR claimed_at <= ?4)",
        params![now, claim_owner, candidate.0, lease_cutoff],
    )?;
    if claimed != 1 {
        transaction.commit()?;
        return Ok(None);
    }
    let event = ApnsOutboxEvent {
        event_id: candidate.0,
        event_kind: candidate.1,
        object_id: candidate.2,
        target_device_id: candidate.3,
        payload_json: candidate.4,
        attempts: u32::try_from(candidate.5.max(0)).unwrap_or(u32::MAX),
        claimed_at: now,
        claim_owner: claim_owner.to_string(),
        delivery_environment: candidate.8,
        delivery_token_digest: candidate.9,
    };
    transaction.commit()?;
    Ok(Some(event))
}

fn load_apns_outbox_delivery(
    database: &Connection,
    event: &ApnsOutboxEvent,
    now: i64,
) -> Result<Option<ApnsOutboxDelivery>, ApiError> {
    match event.event_kind.as_str() {
        APNS_OUTBOX_CALL_INVITE => {
            let payload: CallInviteOutboxPayload = serde_json::from_str(&event.payload_json)
                .map_err(|_| ApiError::internal("invalid call APNs outbox payload"))?;
            if payload.call_id != event.object_id {
                return Ok(None);
            }
            let record = database
                .query_row(
                    "SELECT c.call_uuid, c.caller_name, c.audio, c.video,
                            c.status, c.created_at, t.state,
                            d.voip_push_token, d.push_environment
                     FROM calls c
                     JOIN call_targets t ON t.call_id = c.call_id
                     JOIN devices d ON d.device_id = t.device_id
                     WHERE c.call_id = ?1 AND t.device_id = ?2
                       AND d.user_id = c.callee_user_id AND d.revoked_at IS NULL",
                    params![event.object_id, event.target_device_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, bool>(2)?,
                            row.get::<_, bool>(3)?,
                            row.get::<_, u8>(4)?,
                            row.get::<_, i64>(5)?,
                            row.get::<_, u8>(6)?,
                            row.get::<_, Option<String>>(7)?,
                            row.get::<_, String>(8)?,
                        ))
                    },
                )
                .optional()?;
            let Some(record) = record else {
                return Ok(None);
            };
            let payload_matches = payload.call_uuid == record.0
                && payload.caller == record.1
                && payload.audio == record.2
                && payload.video == record.3;
            let invite_fresh = u32::try_from(record.5)
                .ok()
                .zip(u32::try_from(now).ok())
                .is_some_and(|(created_at, now)| internet_call::invite_is_fresh(created_at, now));
            let Some(token) = record.7.filter(|token| valid_apns_token(token)) else {
                return Ok(None);
            };
            let registered_environment = match ApnsEnvironment::parse(&record.8) {
                Ok(environment) => environment,
                Err(_) => return Ok(None),
            };
            let (environment, used_environment_override) =
                apns_outbox_delivery_environment(event, &token, registered_environment);
            if !payload_matches
                || record.6 != internet_call::CALL_RINGING
                || !internet_call::voip_push_may_be_sent(record.4, invite_fresh, true)
            {
                return Ok(None);
            }
            Ok(Some(ApnsOutboxDelivery::CallInvite {
                token,
                environment,
                used_environment_override,
                call_id: payload.call_id,
                call_uuid: payload.call_uuid,
                caller: payload.caller,
                audio: payload.audio,
                video: payload.video,
            }))
        }
        APNS_OUTBOX_DIRECT_MESSAGE => {
            let payload: DirectMessageOutboxPayload = serde_json::from_str(&event.payload_json)
                .map_err(|_| ApiError::internal("invalid direct-message APNs outbox payload"))?;
            let message_id = event
                .object_id
                .parse::<i64>()
                .ok()
                .filter(|message_id| *message_id > 0);
            let Some(message_id) = message_id else {
                return Ok(None);
            };
            let record = database
                .query_row(
                    "SELECT m.sender_user_id, m.sender_nickname,
                            m.recipient_user_id, d.alert_push_token,
                            d.push_environment, m.created_at,
                            COALESCE(r.last_read_message_id, 0)
                     FROM direct_messages m
                     JOIN direct_message_envelopes e ON e.message_id = m.message_id
                     JOIN devices d ON d.device_id = e.recipient_device_id
                     LEFT JOIN direct_message_read_state r
                       ON r.owner_user_id = m.recipient_user_id
                      AND r.peer_user_id = m.sender_user_id
                     WHERE m.message_id = ?1 AND e.recipient_device_id = ?2
                       AND d.user_id = m.recipient_user_id AND d.revoked_at IS NULL",
                    params![message_id, event.target_device_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, Option<String>>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, i64>(5)?,
                            row.get::<_, i64>(6)?,
                        ))
                    },
                )
                .optional()?;
            let Some(record) = record else {
                return Ok(None);
            };
            if payload.sender_user_id != record.0 || payload.sender_nickname != record.1 {
                return Ok(None);
            }
            let fresh = u32::try_from(record.5)
                .ok()
                .zip(u32::try_from(now).ok())
                .is_some_and(|(created_at, now)| {
                    direct_message::push_alert_is_fresh(created_at, now)
                });
            let unread = message_id > record.6;
            let newer_event_pending = database.query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM apns_outbox newer
                     JOIN direct_messages newer_message
                       ON newer_message.message_id = CAST(newer.object_id AS INTEGER)
                     WHERE newer.event_kind = ?1
                       AND newer.target_device_id = ?2
                       AND CAST(newer.object_id AS INTEGER) > ?3
                       AND newer_message.sender_user_id = ?4
                       AND newer_message.recipient_user_id = ?5
                 )",
                params![
                    APNS_OUTBOX_DIRECT_MESSAGE,
                    event.target_device_id,
                    message_id,
                    record.0,
                    record.2
                ],
                |row| row.get::<_, bool>(0),
            )?;
            if !direct_message::push_alert_outbox_event_should_deliver(
                unread,
                fresh,
                newer_event_pending,
            ) {
                return Ok(None);
            }
            let Some(token) = record.3.filter(|token| valid_apns_token(token)) else {
                return Ok(None);
            };
            let registered_environment = match ApnsEnvironment::parse(&record.4) {
                Ok(environment) => environment,
                Err(_) => return Ok(None),
            };
            let (environment, used_environment_override) =
                apns_outbox_delivery_environment(event, &token, registered_environment);
            if !direct_message::push_alert_outbox_event_may_enqueue(false, true, true) {
                return Ok(None);
            }
            let badge = total_badge_count_for_device(database, &record.2, &event.target_device_id)?;
            Ok(Some(ApnsOutboxDelivery::DirectMessage {
                token,
                environment,
                used_environment_override,
                sender: payload.sender_nickname,
                sender_user_id: payload.sender_user_id,
                badge,
                expiration: record
                    .5
                    .saturating_add(i64::from(direct_message::PUSH_ALERT_MAX_AGE_SECONDS)),
            }))
        }
        _ => Ok(None),
    }
}

fn acknowledge_apns_outbox_event(
    database: &mut Connection,
    event: &ApnsOutboxEvent,
    delivery: Option<&ApnsOutboxDelivery>,
    accepted_environment: Option<ApnsEnvironment>,
) -> Result<(), ApiError> {
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let acknowledged = transaction.execute(
        "DELETE FROM apns_outbox
         WHERE event_id = ?1 AND claimed_at = ?2 AND claim_owner = ?3",
        params![event.event_id, event.claimed_at, event.claim_owner],
    )?;
    if acknowledged == 1 {
        if let (Some(delivery), Some(environment)) = (delivery, accepted_environment) {
            let statement = match delivery.token_column() {
                "voip_push_token" => {
                    "UPDATE devices SET push_environment = ?1
                 WHERE device_id = ?2 AND voip_push_token = ?3"
                }
                _ => {
                    "UPDATE devices SET push_environment = ?1
                 WHERE device_id = ?2 AND alert_push_token = ?3"
                }
            };
            transaction.execute(
                statement,
                params![
                    environment.as_database_value(),
                    event.target_device_id,
                    delivery.token()
                ],
            )?;
        }
    }
    transaction.commit()?;
    Ok(())
}

fn invalidate_apns_outbox_token(
    database: &mut Connection,
    event: &ApnsOutboxEvent,
    delivery: &ApnsOutboxDelivery,
    status: Option<u16>,
    token_invalid_at_ms: Option<i64>,
    now: i64,
) -> Result<bool, ApiError> {
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let owns_claim = transaction.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM apns_outbox
             WHERE event_id = ?1 AND claimed_at = ?2 AND claim_owner = ?3
         )",
        params![event.event_id, event.claimed_at, event.claim_owner],
        |row| row.get::<_, bool>(0),
    )?;
    if !owns_claim {
        transaction.commit()?;
        return Ok(false);
    }
    let statement = match delivery.token_column() {
        "voip_push_token" => {
            "UPDATE devices
             SET voip_push_token = NULL,
                 voip_push_token_registered_at_ms = NULL
             WHERE device_id = ?1 AND voip_push_token = ?2
               AND (?3 IS NULL OR voip_push_token_registered_at_ms IS NULL
                    OR voip_push_token_registered_at_ms <= ?3)"
        }
        _ => {
            "UPDATE devices
             SET alert_push_token = NULL,
                 alert_push_token_registered_at_ms = NULL
             WHERE device_id = ?1 AND alert_push_token = ?2
               AND (?3 IS NULL OR alert_push_token_registered_at_ms IS NULL
                    OR alert_push_token_registered_at_ms <= ?3)"
        }
    };
    let invalidated = transaction.execute(
        statement,
        params![
            event.target_device_id,
            delivery.token(),
            token_invalid_at_ms
        ],
    )?;
    if invalidated == 1 {
        transaction.execute(
            "DELETE FROM apns_outbox
             WHERE event_id = ?1 AND claimed_at = ?2 AND claim_owner = ?3",
            params![event.event_id, event.claimed_at, event.claim_owner],
        )?;
    } else {
        // Registration rotated the token while the APNs request was in flight.
        // Keep the same idempotent event and immediately retry against the
        // current token selected by load_apns_outbox_delivery.
        transaction.execute(
            "UPDATE apns_outbox
             SET next_attempt_at = ?1, claimed_at = NULL,
                 claim_owner = NULL, last_failure_kind = 'token_rotated',
                 last_status = ?2
             WHERE event_id = ?3 AND claimed_at = ?4 AND claim_owner = ?5",
            params![
                now,
                status.map(i64::from),
                event.event_id,
                event.claimed_at,
                event.claim_owner
            ],
        )?;
    }
    transaction.commit()?;
    Ok(invalidated == 1)
}

fn reschedule_apns_outbox_event(
    database: &mut Connection,
    event: &ApnsOutboxEvent,
    error: &ApnsDeliveryError,
    now: i64,
) -> Result<(), ApiError> {
    let attempts = event.attempts.saturating_add(1);
    let jitter =
        OsRng.next_u32() % (internet_call::APNS_OUTBOX_RETRY_MAX_JITTER_SECONDS.saturating_add(1));
    let delay = internet_call::apns_outbox_retry_delay_seconds(attempts, jitter);
    let next_attempt_at = now.saturating_add(i64::from(delay));
    let failure_kind = error.reason.as_deref().unwrap_or(if error.transient {
        "transient"
    } else {
        "provider"
    });
    database.execute(
        "UPDATE apns_outbox
         SET attempts = ?1, next_attempt_at = ?2, claimed_at = NULL,
             claim_owner = NULL, last_failure_kind = ?3, last_status = ?4
         WHERE event_id = ?5 AND claimed_at = ?6 AND claim_owner = ?7",
        params![
            i64::from(attempts),
            next_attempt_at,
            failure_kind,
            error.status.map(i64::from),
            event.event_id,
            event.claimed_at,
            event.claim_owner
        ],
    )?;
    Ok(())
}

fn schedule_apns_outbox_alternate_environment(
    database: &mut Connection,
    event: &ApnsOutboxEvent,
    delivery: &ApnsOutboxDelivery,
    environment: ApnsEnvironment,
    error: &ApnsDeliveryError,
    now: i64,
) -> Result<(), ApiError> {
    database.execute(
        "UPDATE apns_outbox
         SET next_attempt_at = ?1, claimed_at = NULL, claim_owner = NULL,
             blocked_owner = NULL, delivery_environment = ?2,
             delivery_token_digest = ?3, last_failure_kind = ?4,
             last_status = ?5
         WHERE event_id = ?6 AND claimed_at = ?7 AND claim_owner = ?8",
        params![
            now,
            environment.as_database_value(),
            apns_token_digest(delivery.token()),
            error.reason.as_deref().unwrap_or("BadDeviceToken"),
            error.status.map(i64::from),
            event.event_id,
            event.claimed_at,
            event.claim_owner
        ],
    )?;
    Ok(())
}

fn block_apns_outbox_event_for_process(
    database: &mut Connection,
    event: &ApnsOutboxEvent,
    error: &ApnsDeliveryError,
) -> Result<(), ApiError> {
    let attempts = event.attempts.saturating_add(1);
    let failure_kind = error.reason.as_deref().unwrap_or("configuration");
    database.execute(
        "UPDATE apns_outbox
         SET attempts = ?1, claimed_at = NULL, claim_owner = NULL,
             blocked_owner = ?2, last_failure_kind = ?3, last_status = ?4
         WHERE event_id = ?5 AND claimed_at = ?6 AND claim_owner = ?7",
        params![
            i64::from(attempts),
            event.claim_owner,
            failure_kind,
            error.status.map(i64::from),
            event.event_id,
            event.claimed_at,
            event.claim_owner
        ],
    )?;
    Ok(())
}

async fn process_one_apns_outbox_event(
    state: &AppState,
    event_kind: &str,
) -> Result<bool, ApiError> {
    debug_assert_eq!(internet_call::APNS_OUTBOX_HTTP_ATTEMPTS_PER_CLAIM, 1);
    let event = {
        let mut database = lock_database(state)?;
        claim_due_apns_outbox_event(
            &mut database,
            event_kind,
            &state.apns_outbox_owner,
            unix_time(),
        )?
    };
    let Some(event) = event else {
        return Ok(false);
    };
    let delivery = {
        let database = lock_database(state)?;
        load_apns_outbox_delivery(&database, &event, unix_time())?
    };
    let Some(delivery) = delivery else {
        let mut database = lock_database(state)?;
        acknowledge_apns_outbox_event(&mut database, &event, None, None)?;
        return Ok(true);
    };
    let Some(apns) = state.configuration.apns.as_ref() else {
        return Ok(false);
    };
    let result = match &delivery {
        ApnsOutboxDelivery::CallInvite {
            token,
            environment,
            used_environment_override: _,
            call_id,
            call_uuid,
            caller,
            audio,
            video,
        } => apns
            .send_voip_once(
                token,
                *environment,
                call_id,
                call_uuid,
                caller,
                *audio,
                *video,
            )
            .await
            .map(|()| ApnsDeliverySuccess {
                environment: *environment,
                environment_changed: delivery.used_environment_override(),
            }),
        ApnsOutboxDelivery::DirectMessage {
            token,
            environment,
            used_environment_override: _,
            sender,
            sender_user_id,
            badge,
            expiration,
        } => {
            let data = direct_message_alert_data(sender_user_id, sender);
            apns.send_alert_once(
                token,
                *environment,
                "TRI-NET",
                &format!("New encrypted message from @{sender}"),
                *badge,
                "default",
                Some("direct-messages"),
                *expiration,
                Some(&event.event_id),
                data,
            )
            .await
            .map(|()| ApnsDeliverySuccess {
                environment: *environment,
                environment_changed: delivery.used_environment_override(),
            })
        }
    };
    if result
        .as_ref()
        .err()
        .is_some_and(|error| error.refresh_provider_token)
    {
        apns.discard_cached_provider_token();
    }
    match result {
        Ok(success) => {
            let accepted_environment = success.environment_changed.then_some(success.environment);
            let mut database = lock_database(state)?;
            acknowledge_apns_outbox_event(
                &mut database,
                &event,
                Some(&delivery),
                accepted_environment,
            )?;
        }
        Err(error)
            if error.bad_device_token
                && internet_call::apns_should_try_alternate_environment(
                    true,
                    delivery.used_environment_override(),
                ) =>
        {
            let mut database = lock_database(state)?;
            schedule_apns_outbox_alternate_environment(
                &mut database,
                &event,
                &delivery,
                delivery.environment().alternate(),
                &error,
                unix_time(),
            )?;
            eprintln!("APNs outbox scheduled a state-revalidated alternate endpoint");
        }
        Err(mut error) if error.permanent => {
            error.alternate_attempted = delivery.used_environment_override();
            let invalidate = internet_call::apns_token_should_be_invalidated(
                error.token_invalid,
                error.bad_device_token,
                error.alternate_attempted,
                true,
            );
            let mut database = lock_database(state)?;
            let discarded = if invalidate {
                let invalidated = invalidate_apns_outbox_token(
                    &mut database,
                    &event,
                    &delivery,
                    error.status,
                    error.token_invalid_at_ms,
                    unix_time(),
                )?;
                if !invalidated {
                    eprintln!(
                        "APNs outbox retained an event after token rotation or claim handoff"
                    );
                }
                invalidated
            } else {
                acknowledge_apns_outbox_event(&mut database, &event, Some(&delivery), None)?;
                true
            };
            if discarded {
                eprintln!("APNs outbox discarded a terminal event: {error}");
            }
        }
        Err(error) if internet_call::apns_outbox_should_retry(error.permanent, error.transient) => {
            let mut database = lock_database(state)?;
            reschedule_apns_outbox_event(&mut database, &event, &error, unix_time())?;
            eprintln!("APNs outbox scheduled a durable retry: {error}");
        }
        Err(error) if internet_call::apns_outbox_should_block(error.permanent, error.transient) => {
            let mut database = lock_database(state)?;
            block_apns_outbox_event_for_process(&mut database, &event, &error)?;
            eprintln!(
                "APNs outbox blocked a non-retryable provider/configuration failure until restart: {error}"
            );
        }
        Err(_) => return Err(ApiError::internal("unclassified APNs delivery failure")),
    }
    Ok(true)
}

async fn run_apns_outbox_worker(state: AppState, event_kind: &'static str) {
    loop {
        match process_one_apns_outbox_event(&state, event_kind).await {
            Ok(true) => tokio::task::yield_now().await,
            Ok(false) => tokio::time::sleep(Duration::from_millis(APNS_OUTBOX_IDLE_POLL_MS)).await,
            Err(_) => {
                eprintln!("APNs outbox worker could not process an event");
                tokio::time::sleep(Duration::from_millis(APNS_OUTBOX_ERROR_POLL_MS)).await;
            }
        }
    }
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
    let display_name = safe_display_name(&request.display_name);
    let voip_push_token = normalize_apns_token(request.voip_push_token.as_deref())?;
    let alert_push_token = normalize_apns_token(request.alert_push_token.as_deref())?;
    let text_encryption_public_key =
        normalize_text_encryption_public_key(request.text_encryption_public_key.as_deref())?;
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
    let now_ms = unix_time_millis();
    let voip_push_token_registered_at_ms = voip_push_token.as_ref().map(|_| now_ms);
    let alert_push_token_registered_at_ms = alert_push_token.as_ref().map(|_| now_ms);
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
         (device_id, user_id, display_name, signing_public_key,
          text_encryption_public_key, key_fingerprint,
          platform, voip_push_token, voip_push_token_registered_at_ms,
          alert_push_token, alert_push_token_registered_at_ms,
          push_environment, capabilities, last_seen, linked_at, revoked_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14, NULL)
         ON CONFLICT(device_id) DO UPDATE SET
           display_name = excluded.display_name,
           text_encryption_public_key = COALESCE(
               excluded.text_encryption_public_key,
               devices.text_encryption_public_key
           ),
           platform = excluded.platform,
           voip_push_token = excluded.voip_push_token,
           voip_push_token_registered_at_ms = excluded.voip_push_token_registered_at_ms,
           alert_push_token = excluded.alert_push_token,
           alert_push_token_registered_at_ms = excluded.alert_push_token_registered_at_ms,
           push_environment = excluded.push_environment,
           capabilities = excluded.capabilities,
           last_seen = excluded.last_seen",
        params![
            request.device_id,
            request.user_id,
            display_name,
            request.signing_public_key,
            text_encryption_public_key,
            request.key_fingerprint,
            request.platform,
            voip_push_token,
            voip_push_token_registered_at_ms,
            alert_push_token,
            alert_push_token_registered_at_ms,
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
        signing_public_key: auth.signing_public_key,
        key_fingerprint: auth.key_fingerprint,
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
        "UPDATE devices
         SET revoked_at = ?1,
             voip_push_token = NULL,
             voip_push_token_registered_at_ms = NULL,
             alert_push_token = NULL,
             alert_push_token_registered_at_ms = NULL
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
    if !nickname_shape_valid(&query) {
        return Err(ApiError::bad_request(
            "directory lookup requires an exact valid nickname",
        ));
    }
    let _requested_limit = request.limit;
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
         WHERE n.nickname = ?1
           AND EXISTS (SELECT 1 FROM devices d
                       WHERE d.user_id = n.user_id AND d.revoked_at IS NULL)
         LIMIT 1",
    )?;
    let results = statement
        .query_map(params![query], |row| {
            let last_seen: i64 = row.get(5)?;
            let nickname = row.get::<_, String>(2)?;
            let device_count = row.get::<_, usize>(6)?;
            Ok((
                nickname_directory::exact_lookup_may_return(
                    true,
                    nickname == query.as_str(),
                    u16::try_from(device_count).unwrap_or(u16::MAX),
                ),
                DirectoryContact {
                    user_id: row.get(0)?,
                    device_id: row.get(1)?,
                    nickname,
                    display_name: row.get(3)?,
                    key_fingerprint: row.get(4)?,
                    online: device_is_online(last_seen, now),
                    device_count,
                },
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter_map(|(may_return, contact)| may_return.then_some(contact))
        .collect();
    Ok(Json(NicknameSearchResponse { results }))
}

async fn create_call(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    let request: CreateCallRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/calls", &body, None)?;
    require_identity(&auth, &request.caller_user_id, &request.caller_device_id)?;
    if !internet_call::call_media_request_is_valid(request.audio, request.video, auth.capabilities)
    {
        return Err(ApiError::bad_request(
            "call requires audio or video supported by the caller device",
        ));
    }
    let callee = normalize_nickname(&request.callee);
    if !nickname_shape_valid(&callee) {
        return Err(ApiError::bad_request("invalid callee nickname"));
    }
    let client_call_id = normalize_uuid(&request.client_call_id, "client_call_id")?;

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let caller_name = transaction
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or_else(|| ApiError::conflict("claim a nickname before calling"))?;
    let existing_call = transaction
        .query_row(
            "SELECT call_id, room_id, callee_nickname, audio, video, caller_name,
                    caller_user_id, status, created_at
             FROM calls
             WHERE caller_device_id = ?1 AND client_call_id = ?2",
            params![auth.device_id, client_call_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, bool>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, u8>(7)?,
                    row.get::<_, i64>(8)?,
                ))
            },
        )
        .optional()?;
    if let Some(existing) = existing_call {
        if existing.6 != auth.user_id {
            return Err(ApiError::forbidden(
                "client_call_id belongs to the device's previous account",
            ));
        }
        if !internet_call::create_retry_matches(
            existing.2.as_deref() == Some(callee.as_str()),
            existing.3 == request.audio,
            existing.4 == request.video,
        ) {
            return Err(ApiError::conflict(
                "client_call_id was already used with different call intent",
            ));
        }
        if existing.5 != caller_name {
            return Err(ApiError::conflict(
                "caller nickname changed after this call attempt was created",
            ));
        }
        let now = unix_time();
        let invite_fresh = u32::try_from(existing.8)
            .ok()
            .zip(u32::try_from(now).ok())
            .is_some_and(|(created_at, current)| {
                internet_call::invite_is_fresh(created_at, current)
            });
        let mut status = existing.7;
        if internet_call::call_should_expire(status, invite_fresh) {
            expire_ringing_call(&transaction, &existing.0, now)?;
            status = internet_call::CALL_MISSED;
        }
        if !internet_call::create_retry_may_issue_session(true, status, invite_fresh) {
            let response = CreateCallConflictResponse {
                call_id: existing.0,
                status: call_status_label(status),
                reason: "existing call cannot issue another media session",
            };
            transaction.commit()?;
            return Ok((StatusCode::CONFLICT, Json(response)).into_response());
        }
        transaction.commit()?;
        drop(database);
        return session_for(
            &state.configuration,
            &existing.0,
            &existing.1,
            &auth,
            &existing.5,
        )
        .map(|session| Json(session).into_response());
    }
    let target_user_id = transaction
        .query_row(
            "SELECT user_id FROM nicknames WHERE nickname = ?1",
            params![callee],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("nickname not found"))?;
    if target_user_id == auth.user_id {
        return Err(ApiError::conflict("cannot call your own account"));
    }
    let admission_now = unix_time();
    let fresh_since = admission_now.saturating_sub(i64::from(internet_call::INVITE_TTL_SECONDS));
    let busy_target_device_ids = {
        let mut statement = transaction.prepare(
            "SELECT DISTINCT device_id FROM (
                 SELECT t.device_id AS device_id
                 FROM call_targets t JOIN calls c ON c.call_id = t.call_id
                 WHERE c.status = ?1 OR (c.status = ?2 AND c.created_at >= ?3)
                 UNION
                 SELECT c.caller_device_id AS device_id
                 FROM calls c
                 WHERE c.status = ?1 OR (c.status = ?2 AND c.created_at >= ?3)
             )",
        )?;
        let busy = statement
            .query_map(
                params![
                    internet_call::CALL_ACTIVE,
                    internet_call::CALL_RINGING,
                    fresh_since
                ],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<HashSet<_>, _>>()?;
        busy
    };
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
            !busy_target_device_ids.contains(&target.device_id)
                && internet_call::call_target_supports_media(request.video, target.capabilities)
                && internet_call::call_target_is_available(
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
    let recent_since =
        admission_now.saturating_sub(i64::from(internet_call::CALL_RATE_WINDOW_SECONDS));
    let recent_device_calls = transaction.query_row(
        "SELECT COUNT(*) FROM calls
         WHERE caller_device_id = ?1 AND created_at >= ?2",
        params![auth.device_id, recent_since],
        |row| row.get::<_, u32>(0),
    )?;
    let pending_device_calls = transaction.query_row(
        "SELECT COUNT(*) FROM calls
         WHERE caller_device_id = ?1 AND status = ?2 AND created_at >= ?3",
        params![auth.device_id, internet_call::CALL_RINGING, fresh_since],
        |row| row.get::<_, u32>(0),
    )?;
    let pending_voip_events = transaction.query_row(
        "SELECT COUNT(*) FROM apns_outbox WHERE event_kind = ?1",
        params![APNS_OUTBOX_CALL_INVITE],
        |row| row.get::<_, u32>(0),
    )?;
    let new_voip_events = targets
        .iter()
        .filter(|target| {
            target
                .voip_push_token
                .as_deref()
                .is_some_and(valid_apns_token)
                && ApnsEnvironment::parse(&target.push_environment).is_ok()
        })
        .count()
        .min(u32::MAX as usize) as u32;
    if !internet_call::new_call_admission_is_allowed(
        recent_device_calls,
        pending_device_calls,
        pending_voip_events,
        new_voip_events,
        state.configuration.apns.is_some(),
    ) {
        return Err(ApiError::too_many_requests(
            "call rate or fresh VoIP delivery capacity exceeded; retry shortly",
        ));
    }
    let call_id = random_id("call_");
    let call_uuid = Uuid::new_v4().to_string();
    let room_id = random_id("room_");
    let status = internet_call::next_status(internet_call::CALL_IDLE, true);
    let created_at = unix_time();
    transaction.execute(
        "INSERT INTO calls
         (call_id, client_call_id, call_uuid, room_id, caller_user_id,
          caller_device_id, callee_user_id, callee_device_id, callee_nickname,
          caller_name, audio, video, status, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            call_id,
            client_call_id,
            call_uuid,
            room_id,
            auth.user_id,
            auth.device_id,
            target_user_id,
            targets[0].device_id,
            callee,
            caller_name,
            request.audio,
            request.video,
            status,
            created_at,
        ],
    )?;
    let outbox_payload = CallInviteOutboxPayload {
        call_id: call_id.clone(),
        call_uuid: call_uuid.clone(),
        caller: caller_name.clone(),
        audio: request.audio,
        video: request.video,
    };
    for target in &targets {
        transaction.execute(
            "INSERT INTO call_targets(call_id, device_id, state)
             VALUES (?1, ?2, ?3)",
            params![call_id, target.device_id, internet_call::CALL_RINGING],
        )?;
        let token_valid = target
            .voip_push_token
            .as_deref()
            .is_some_and(valid_apns_token)
            && ApnsEnvironment::parse(&target.push_environment).is_ok();
        if internet_call::voip_outbox_event_may_enqueue(status, true, token_valid, true) {
            enqueue_apns_outbox_event(
                &transaction,
                APNS_OUTBOX_CALL_INVITE,
                &call_id,
                &target.device_id,
                &outbox_payload,
                created_at,
            )?;
        }
    }
    transaction.commit()?;
    drop(database);
    session_for(
        &state.configuration,
        &call_id,
        &room_id,
        &auth,
        &caller_name,
    )
    .map(|session| Json(session).into_response())
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
           AND c.created_at >= ?3 AND c.callee_user_id = ?4
         ORDER BY c.created_at ASC LIMIT 10",
    )?;
    let calls = statement
        .query_map(
            params![
                auth.device_id,
                internet_call::CALL_RINGING,
                minimum_created_at,
                auth.user_id
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
                    c.created_at, c.caller_name, t.state, c.answered_device_id,
                    c.callee_nickname
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
                    row.get::<_, u8>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
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
    let exact_callee_target = auth.user_id == call.1 && auth.device_id == call.2;
    let exact_answer_retry = call.7.as_deref() == Some(auth.device_id.as_str());
    if exact_callee_target
        && exact_answer_retry
        && internet_call::join_retry_is_authorized(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&call.1),
            stable_id(call.7.as_deref().unwrap_or("")),
            call.3,
            device_valid,
        )
    {
        transaction.commit()?;
        drop(database);
        return session_for(
            &state.configuration,
            &call_id,
            &call.0,
            &auth,
            call.8.as_deref().unwrap_or("TRI-NET peer"),
        )
        .map(Json);
    }
    if internet_call::call_should_expire(call.3, invite_fresh) {
        expire_ringing_call(&transaction, &call_id, now)?;
        transaction.commit()?;
        return Err(ApiError::forbidden("call invitation expired"));
    }
    if !exact_callee_target
        || !internet_call::join_is_authorized(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&call.1),
            stable_id(&call.2),
            call.3,
            call.6,
            invite_fresh,
            device_valid,
        )
    {
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
        call.8.as_deref().unwrap_or("TRI-NET peer"),
    )
    .map(Json)
}

async fn decline_call(
    State(state): State<AppState>,
    Path(call_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<CallStatusResponse>, ApiError> {
    let request: CallParticipantRequest = decode_json(&body)?;
    let path = format!("/v1/calls/{call_id}/decline");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let now = unix_time();
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut record = load_call_status_record(&transaction, &call_id, &auth.device_id)?;
    let is_target = record.target_status.is_some();
    let exact_target = auth.user_id == record.callee_user_id && is_target;
    if !exact_target
        || !internet_call::participant_may_read_status(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&record.caller_user_id),
            stable_id(&record.caller_device_id),
            stable_id(&record.callee_user_id),
            is_target,
        )
    {
        return Err(ApiError::forbidden("call is unavailable to this device"));
    }
    refresh_expired_call(&transaction, &call_id, &mut record, now)?;
    let target_status = record
        .target_status
        .ok_or_else(|| ApiError::forbidden("call is unavailable to this device"))?;
    let may_decline = internet_call::callee_may_decline(
        stable_id(&auth.user_id),
        stable_id(&auth.device_id),
        stable_id(&record.callee_user_id),
        stable_id(&auth.device_id),
        record.status,
        target_status,
    );
    if may_decline
        && record.status == internet_call::CALL_RINGING
        && target_status == internet_call::CALL_RINGING
    {
        transaction.execute(
            "UPDATE call_targets SET state = ?1
             WHERE call_id = ?2 AND device_id = ?3 AND state = ?4",
            params![
                internet_call::CALL_DECLINED,
                call_id,
                auth.device_id,
                internet_call::CALL_RINGING
            ],
        )?;
        let remaining = transaction.query_row(
            "SELECT COUNT(*) FROM call_targets WHERE call_id = ?1 AND state = ?2",
            params![call_id, internet_call::CALL_RINGING],
            |row| row.get::<_, u16>(0),
        )?;
        let next_status = internet_call::status_after_decline(record.status, remaining);
        if next_status != record.status {
            transaction.execute(
                "UPDATE calls SET status = ?1, ended_at = ?2
                 WHERE call_id = ?3 AND status = ?4",
                params![next_status, now, call_id, record.status],
            )?;
            record.status = next_status;
            record.ended_at = Some(now);
        }
        record.target_status = Some(internet_call::CALL_DECLINED);
    } else if !may_decline && record.status == internet_call::CALL_RINGING {
        return Err(ApiError::conflict("call target can no longer be declined"));
    }
    let response = call_status_response(&call_id, &record, &auth);
    transaction.commit()?;
    Ok(Json(response))
}

async fn call_status(
    State(state): State<AppState>,
    Path(call_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<CallStatusResponse>, ApiError> {
    let request: CallParticipantRequest = decode_json(&body)?;
    let path = format!("/v1/calls/{call_id}/status");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let now = unix_time();
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut record = load_call_status_record(&transaction, &call_id, &auth.device_id)?;
    let exact_caller =
        auth.user_id == record.caller_user_id && auth.device_id == record.caller_device_id;
    let exact_target = auth.user_id == record.callee_user_id && record.target_status.is_some();
    if !(exact_caller || exact_target)
        || !internet_call::participant_may_read_status(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&record.caller_user_id),
            stable_id(&record.caller_device_id),
            stable_id(&record.callee_user_id),
            record.target_status.is_some(),
        )
    {
        return Err(ApiError::forbidden("call is unavailable to this device"));
    }
    refresh_expired_call(&transaction, &call_id, &mut record, now)?;
    let response = call_status_response(&call_id, &record, &auth);
    transaction.commit()?;
    Ok(Json(response))
}

async fn end_call(
    State(state): State<AppState>,
    Path(call_id): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<CallStatusResponse>, ApiError> {
    let request: CallParticipantRequest = decode_json(&body)?;
    let path = format!("/v1/calls/{call_id}/end");
    let auth = authenticate(&state, &headers, "POST", &path, &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut record = load_call_status_record(&transaction, &call_id, &auth.device_id)?;
    let exact_caller =
        auth.user_id == record.caller_user_id && auth.device_id == record.caller_device_id;
    let exact_target = auth.user_id == record.callee_user_id && record.target_status.is_some();
    let exact_answerer = auth.user_id == record.callee_user_id
        && record.answered_device_id.as_deref() == Some(auth.device_id.as_str());
    if !(exact_caller || exact_target)
        || !internet_call::participant_may_read_status(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&record.caller_user_id),
            stable_id(&record.caller_device_id),
            stable_id(&record.callee_user_id),
            record.target_status.is_some(),
        )
    {
        return Err(ApiError::forbidden("call is unavailable to this device"));
    }
    if !(exact_caller || exact_answerer)
        || !internet_call::active_participant_may_end(
            stable_id(&auth.user_id),
            stable_id(&auth.device_id),
            stable_id(&record.caller_user_id),
            stable_id(&record.caller_device_id),
            stable_id(&record.callee_user_id),
            stable_id(record.answered_device_id.as_deref().unwrap_or("")),
            record.status,
        )
    {
        return Err(ApiError::conflict(
            "only the originating caller or answering callee may end an active call",
        ));
    }
    if record.status == internet_call::CALL_ACTIVE {
        let now = unix_time();
        let ended = transaction.execute(
            "UPDATE calls SET status = ?1, ended_at = ?2
             WHERE call_id = ?3 AND status = ?4",
            params![
                internet_call::CALL_ENDED,
                now,
                call_id,
                internet_call::CALL_ACTIVE
            ],
        )?;
        if ended != 1 {
            return Err(ApiError::conflict("call state changed before hangup"));
        }
        transaction.execute(
            "UPDATE call_targets SET state = ?1 WHERE call_id = ?2",
            params![internet_call::CALL_ENDED, call_id],
        )?;
        record.status = internet_call::CALL_ENDED;
        record.ended_at = Some(now);
        if record.target_status.is_some() {
            record.target_status = Some(internet_call::CALL_ENDED);
        }
    }
    let response = call_status_response(&call_id, &record, &auth);
    let cleanup_room_id = record.room_id.clone();
    let should_cleanup = internet_call::livekit_room_cleanup_should_start(record.status, true);
    transaction.commit()?;
    drop(database);
    if should_cleanup {
        schedule_livekit_room_cleanup(state.configuration.clone(), cleanup_room_id);
    }
    Ok(Json(response))
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
            "SELECT caller_user_id, caller_device_id, status, room_id
             FROM calls WHERE call_id = ?1",
            params![call_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u8>(2)?,
                    row.get::<_, String>(3)?,
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
    let next_status = internet_call::status_after_caller_end(call.2);
    if next_status != call.2 {
        let ended = transaction.execute(
            "UPDATE calls SET status = ?1, ended_at = ?2
             WHERE call_id = ?3 AND status = ?4",
            params![next_status, unix_time(), call_id, call.2],
        )?;
        if ended != 1 {
            return Err(ApiError::conflict("call state changed before cancellation"));
        }
        transaction.execute(
            "UPDATE call_targets SET state = ?1 WHERE call_id = ?2",
            params![internet_call::CALL_ENDED, call_id],
        )?;
    }
    let cleanup_room_id = call.3.clone();
    let should_cleanup = internet_call::livekit_room_cleanup_should_start(next_status, true);
    transaction.commit()?;
    drop(database);
    if should_cleanup {
        schedule_livekit_room_cleanup(state.configuration.clone(), cleanup_room_id);
    }
    Ok(StatusCode::NO_CONTENT)
}

fn load_call_status_record(
    transaction: &rusqlite::Transaction<'_>,
    call_id: &str,
    request_device_id: &str,
) -> Result<CallStatusRecord, ApiError> {
    transaction
        .query_row(
            "SELECT c.room_id, c.call_uuid, c.caller_user_id, c.caller_device_id,
                    c.callee_user_id, c.status, c.created_at, c.answered_at,
                    c.answered_device_id, c.ended_at, t.state
             FROM calls c
             LEFT JOIN call_targets t
               ON t.call_id = c.call_id AND t.device_id = ?2
             WHERE c.call_id = ?1",
            params![call_id, request_device_id],
            |row| {
                Ok(CallStatusRecord {
                    room_id: row.get(0)?,
                    call_uuid: row.get(1)?,
                    caller_user_id: row.get(2)?,
                    caller_device_id: row.get(3)?,
                    callee_user_id: row.get(4)?,
                    status: row.get(5)?,
                    created_at: row.get(6)?,
                    answered_at: row.get(7)?,
                    answered_device_id: row.get(8)?,
                    ended_at: row.get(9)?,
                    target_status: row.get(10)?,
                })
            },
        )
        .optional()?
        .ok_or_else(|| ApiError::forbidden("call is unavailable to this device"))
}

fn refresh_expired_call(
    transaction: &rusqlite::Transaction<'_>,
    call_id: &str,
    record: &mut CallStatusRecord,
    now: i64,
) -> Result<(), ApiError> {
    let invite_fresh = record.created_at >= 0
        && now >= 0
        && internet_call::invite_is_fresh(record.created_at as u32, now as u32);
    let next_status = internet_call::status_after_expiry(record.status, invite_fresh);
    if next_status == record.status {
        return Ok(());
    }
    let updated = transaction.execute(
        "UPDATE calls SET status = ?1, ended_at = ?2
         WHERE call_id = ?3 AND status = ?4",
        params![next_status, now, call_id, record.status],
    )?;
    if updated != 1 {
        return Err(ApiError::conflict("call state changed while expiring"));
    }
    transaction.execute(
        "UPDATE call_targets SET state = ?1
         WHERE call_id = ?2 AND state = ?3",
        params![
            internet_call::CALL_ENDED,
            call_id,
            internet_call::CALL_RINGING
        ],
    )?;
    if record.target_status == Some(internet_call::CALL_RINGING) {
        record.target_status = Some(internet_call::CALL_ENDED);
    }
    record.status = next_status;
    record.ended_at = Some(now);
    Ok(())
}

fn expire_ringing_call(
    transaction: &rusqlite::Transaction<'_>,
    call_id: &str,
    now: i64,
) -> Result<(), ApiError> {
    let updated = transaction.execute(
        "UPDATE calls SET status = ?1, ended_at = ?2
         WHERE call_id = ?3 AND status = ?4",
        params![
            internet_call::CALL_MISSED,
            now,
            call_id,
            internet_call::CALL_RINGING
        ],
    )?;
    if updated != 1 {
        return Err(ApiError::conflict("call state changed while expiring"));
    }
    transaction.execute(
        "UPDATE call_targets SET state = ?1
         WHERE call_id = ?2 AND state = ?3",
        params![
            internet_call::CALL_ENDED,
            call_id,
            internet_call::CALL_RINGING
        ],
    )?;
    Ok(())
}

fn call_status_response(
    call_id: &str,
    record: &CallStatusRecord,
    auth: &AuthenticatedDevice,
) -> CallStatusResponse {
    let caller = auth.user_id == record.caller_user_id && auth.device_id == record.caller_device_id;
    CallStatusResponse {
        call_id: call_id.to_string(),
        call_uuid: record.call_uuid.clone(),
        status: call_status_label(record.status),
        role: if caller { "caller" } else { "callee" },
        target_status: record.target_status.map(call_status_label),
        answered_here: record.answered_device_id.as_deref() == Some(auth.device_id.as_str()),
        created_at: record.created_at,
        answered_at: record.answered_at,
        ended_at: record.ended_at,
    }
}

fn call_status_label(status: u8) -> &'static str {
    match status {
        internet_call::CALL_IDLE => "idle",
        internet_call::CALL_RINGING => "ringing",
        internet_call::CALL_ACTIVE => "active",
        internet_call::CALL_ENDED => "ended",
        internet_call::CALL_DECLINED => "declined",
        internet_call::CALL_CANCELLED => "cancelled",
        internet_call::CALL_MISSED => "missed",
        _ => "unknown",
    }
}

async fn resolve_direct_message_recipient(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<DirectMessageRecipientResponse>, ApiError> {
    let request: DirectMessageRecipientRequest = decode_json(&body)?;
    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/direct-messages/recipients",
        &body,
        None,
    )?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let nickname = normalize_nickname(&request.nickname);
    if !nickname_shape_valid(&nickname) {
        return Err(ApiError::bad_request("invalid recipient nickname"));
    }
    let database = lock_database(&state)?;
    Ok(Json(load_direct_message_recipient(
        &database, &auth, &nickname,
    )?))
}

async fn send_direct_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<DirectMessageSendResponse>, ApiError> {
    let request: SendDirectMessageRequest = decode_json(&body)?;
    let auth = authenticate(&state, &headers, "POST", "/v1/direct-messages", &body, None)?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    let recipient_nickname = normalize_nickname(&request.recipient);
    if !nickname_shape_valid(&recipient_nickname) {
        return Err(ApiError::bad_request("invalid recipient nickname"));
    }
    let client_message_id = normalize_uuid(&request.client_message_id, "client_message_id")?;
    if request.envelopes.is_empty()
        || request.envelopes.len() > direct_message::MAX_RECIPIENT_DEVICES as usize
    {
        return Err(ApiError::bad_request(
            "encrypted envelope fanout must contain 1-32 devices",
        ));
    }
    let mut envelopes = request
        .envelopes
        .iter()
        .map(|envelope| {
            normalize_direct_message_envelope(
                envelope,
                &auth,
                &recipient_nickname,
                &client_message_id,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    let unique_devices = envelopes
        .iter()
        .map(|envelope| envelope.recipient_device_id.as_str())
        .collect::<HashSet<_>>()
        .len();
    if unique_devices != envelopes.len() {
        return Err(ApiError::bad_request(
            "each recipient device must have exactly one encrypted envelope",
        ));
    }
    envelopes.sort_by(|left, right| left.recipient_device_id.cmp(&right.recipient_device_id));

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(existing) =
        load_existing_direct_message(&transaction, &auth.device_id, &client_message_id)?
    {
        if existing.sender_user_id != auth.user_id {
            return Err(ApiError::forbidden(
                "client_message_id belongs to the device's previous account",
            ));
        }
        let same_recipient = existing.response.recipient_nickname == recipient_nickname;
        let envelope_intent_matches = direct_message_envelope_intent_matches(
            &transaction,
            existing.response.message_id,
            &envelopes,
        )?;
        if !direct_message::message_retry_is_idempotent(
            true,
            same_recipient,
            envelope_intent_matches,
        ) {
            return Err(ApiError::conflict(
                "client_message_id was already used with different encrypted content",
            ));
        }
        transaction.commit()?;
        return Ok(Json(existing.response));
    }

    let recipient = load_direct_message_recipient(&transaction, &auth, &recipient_nickname)?;
    let expected_devices = recipient.devices.len();
    let envelope_set_complete = direct_message::envelope_set_is_complete(
        u16::try_from(expected_devices).unwrap_or(u16::MAX),
        u16::try_from(envelopes.len()).unwrap_or(u16::MAX),
        u16::try_from(unique_devices).unwrap_or(u16::MAX),
    );
    let expected_key_fingerprints = recipient
        .devices
        .iter()
        .map(|device| {
            (
                device.device_id.as_str(),
                device.text_encryption_key_fingerprint.as_str(),
            )
        })
        .collect::<std::collections::HashMap<_, _>>();
    let every_envelope_matches_current_key = envelopes.iter().all(|envelope| {
        expected_key_fingerprints
            .get(envelope.recipient_device_id.as_str())
            .is_some_and(|fingerprint| **fingerprint == envelope.recipient_key_fingerprint)
    });
    if !direct_message::message_may_be_committed(
        true,
        envelope_set_complete,
        every_envelope_matches_current_key,
        true,
    ) {
        return Err(ApiError::conflict(
            "encrypted envelopes must match every current recipient device and key",
        ));
    }
    let sender_nickname = transaction
        .query_row(
            "SELECT nickname FROM nicknames WHERE user_id = ?1",
            params![auth.user_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .ok_or_else(|| ApiError::conflict("claim a nickname before sending direct messages"))?;
    let now = unix_time();
    transaction.execute(
        "INSERT INTO direct_messages
         (sender_user_id, sender_device_id, sender_nickname,
          sender_signing_public_key, sender_key_fingerprint,
          recipient_user_id, recipient_nickname, client_message_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            auth.user_id,
            auth.device_id,
            sender_nickname,
            auth.signing_public_key,
            auth.key_fingerprint,
            recipient.user_id,
            recipient.nickname,
            client_message_id,
            now
        ],
    )?;
    let message_id = transaction.last_insert_rowid();
    for envelope in &envelopes {
        transaction.execute(
            "INSERT INTO direct_message_envelopes
             (message_id, crypto_version, recipient_device_id,
              recipient_key_fingerprint, ephemeral_public_key, nonce,
              ciphertext, sender_signature)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                message_id,
                envelope.crypto_version,
                envelope.recipient_device_id,
                envelope.recipient_key_fingerprint,
                envelope.ephemeral_public_key,
                envelope.nonce,
                envelope.ciphertext,
                envelope.sender_signature
            ],
        )?;
    }
    let outbox_payload = DirectMessageOutboxPayload {
        sender_user_id: auth.user_id.clone(),
        sender_nickname: sender_nickname.clone(),
    };
    for recipient_device in &recipient.devices {
        let push = transaction
            .query_row(
                "SELECT alert_push_token, push_environment
                 FROM devices
                 WHERE device_id = ?1 AND user_id = ?2 AND revoked_at IS NULL",
                params![recipient_device.device_id, recipient.user_id],
                |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        let Some((Some(token), environment)) = push else {
            continue;
        };
        let token_valid = valid_apns_token(&token) && ApnsEnvironment::parse(&environment).is_ok();
        if direct_message::push_alert_outbox_event_may_enqueue(false, token_valid, true) {
            enqueue_apns_outbox_event(
                &transaction,
                APNS_OUTBOX_DIRECT_MESSAGE,
                &message_id.to_string(),
                &recipient_device.device_id,
                &outbox_payload,
                now,
            )?;
        }
    }
    let response = DirectMessageSendResponse {
        message_id,
        client_message_id,
        recipient_user_id: recipient.user_id.clone(),
        recipient_nickname: recipient.nickname.clone(),
        created_at: now,
        inserted: true,
    };
    transaction.commit()?;
    drop(database);
    Ok(Json(response))
}

async fn list_direct_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<DirectMessageInboxResponse>, ApiError> {
    let request: DirectMessageInboxRequest = decode_json(&body)?;
    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/direct-messages/inbox",
        &body,
        None,
    )?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    if request.after_message_id < 0 {
        return Err(ApiError::bad_request(
            "after_message_id must not be negative",
        ));
    }
    let database = lock_database(&state)?;
    let limit = i64::from(direct_message::message_page_size(request.limit));
    let messages = {
        let mut statement = database.prepare(
            "SELECT m.message_id, m.client_message_id, m.sender_user_id,
                    m.sender_device_id, m.sender_nickname,
                    m.sender_signing_public_key, m.sender_key_fingerprint,
                    m.recipient_nickname, e.crypto_version,
                    e.recipient_device_id, e.recipient_key_fingerprint,
                    e.ephemeral_public_key,
                    e.nonce, e.ciphertext, e.sender_signature, m.created_at,
                    COALESCE(r.last_read_message_id, 0)
             FROM direct_messages m
             JOIN direct_message_envelopes e ON e.message_id = m.message_id
             LEFT JOIN direct_message_read_state r
               ON r.owner_user_id = m.recipient_user_id
              AND r.peer_user_id = m.sender_user_id
             WHERE m.recipient_user_id = ?1 AND e.recipient_device_id = ?2
               AND m.message_id > ?3
             ORDER BY m.message_id ASC LIMIT ?4",
        )?;
        let messages = statement
            .query_map(
                params![
                    auth.user_id,
                    auth.device_id,
                    request.after_message_id,
                    limit
                ],
                direct_message_from_row,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        messages
    };
    let total_unread_count =
        direct_unread_count_for_device(&database, &auth.user_id, &auth.device_id)?;
    Ok(Json(DirectMessageInboxResponse {
        messages,
        total_unread_count,
    }))
}

async fn mark_direct_messages_read(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<DirectMessageReadResponse>, ApiError> {
    let request: MarkDirectMessageReadRequest = decode_json(&body)?;
    let auth = authenticate(
        &state,
        &headers,
        "POST",
        "/v1/direct-messages/read",
        &body,
        None,
    )?;
    require_identity(&auth, &request.user_id, &request.device_id)?;
    if request.sender_user_id.is_empty()
        || request.sender_user_id.len() > 128
        || !request.sender_user_id.is_ascii()
        || request.sender_user_id == auth.user_id
    {
        return Err(ApiError::bad_request("invalid sender_user_id"));
    }
    if request.through_message_id < 0 {
        return Err(ApiError::bad_request(
            "through_message_id must not be negative",
        ));
    }

    let mut database = lock_database(&state)?;
    let transaction = database.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current_record = transaction
        .query_row(
            "SELECT last_read_message_id FROM direct_message_read_state
             WHERE owner_user_id = ?1 AND peer_user_id = ?2",
            params![auth.user_id, request.sender_user_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    let current = current_record.unwrap_or(0).max(0);
    let observed = transaction.query_row(
        "SELECT COALESCE(MAX(m.message_id), 0)
         FROM direct_messages m
         JOIN direct_message_envelopes e ON e.message_id = m.message_id
         WHERE m.recipient_user_id = ?1 AND m.sender_user_id = ?2
           AND e.recipient_device_id = ?3 AND m.message_id <= ?4",
        params![
            auth.user_id,
            request.sender_user_id,
            auth.device_id,
            request.through_message_id
        ],
        |row| row.get::<_, i64>(0),
    )?;
    if observed == 0 && current_record.is_none() {
        return Err(ApiError::not_found(
            "no direct-message conversation with this sender",
        ));
    }
    let next = direct_message::advance_read_cursor(current as u64, observed.max(0) as u64)
        .min(i64::MAX as u64) as i64;
    if observed > 0 && (current_record.is_none() || next > current) {
        transaction.execute(
            "INSERT INTO direct_message_read_state
             (owner_user_id, peer_user_id, last_read_message_id)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(owner_user_id, peer_user_id) DO UPDATE SET
               last_read_message_id = excluded.last_read_message_id",
            params![auth.user_id, request.sender_user_id, next],
        )?;
    }
    let total_unread_count =
        direct_unread_count_for_device(&transaction, &auth.user_id, &auth.device_id)?;
    transaction.commit()?;
    Ok(Json(DirectMessageReadResponse {
        last_read_message_id: next,
        total_unread_count,
    }))
}

fn load_direct_message_recipient(
    database: &Connection,
    auth: &AuthenticatedDevice,
    nickname: &str,
) -> Result<DirectMessageRecipientResponse, ApiError> {
    let sender_has_nickname = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM nicknames WHERE user_id = ?1)",
        params![auth.user_id],
        |row| row.get::<_, bool>(0),
    )?;
    let recipient_user_id = database
        .query_row(
            "SELECT user_id FROM nicknames WHERE nickname = ?1",
            params![nickname],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(recipient_user_id) = recipient_user_id else {
        return Err(ApiError::not_found("recipient nickname not found"));
    };
    let devices = {
        let mut statement = database.prepare(
            "SELECT device_id, text_encryption_public_key, key_fingerprint
             FROM devices
             WHERE user_id = ?1 AND revoked_at IS NULL
             ORDER BY device_id",
        )?;
        let devices = statement
            .query_map(params![recipient_user_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        devices
    };
    let active_devices = u16::try_from(devices.len()).unwrap_or(u16::MAX);
    let keyed_devices = u16::try_from(devices.iter().filter(|(_, key, _)| key.is_some()).count())
        .unwrap_or(u16::MAX);
    if !direct_message::recipient_may_resolve(
        auth.user_id == recipient_user_id,
        sender_has_nickname,
        true,
        active_devices,
        keyed_devices,
    ) {
        if auth.user_id == recipient_user_id {
            return Err(ApiError::conflict(
                "direct messages to your own account are not allowed",
            ));
        }
        if !sender_has_nickname {
            return Err(ApiError::conflict(
                "claim a nickname before sending direct messages",
            ));
        }
        return Err(ApiError::conflict(
            "recipient devices are not ready for end-to-end encrypted messages",
        ));
    }
    let devices = devices
        .into_iter()
        .map(|(device_id, key, key_fingerprint)| {
            let text_encryption_public_key =
                key.ok_or_else(|| ApiError::internal("recipient text-encryption key is missing"))?;
            let decoded = general_purpose::STANDARD
                .decode(&text_encryption_public_key)
                .map_err(|_| ApiError::internal("stored text-encryption key is invalid"))?;
            if !direct_message::text_key_is_valid(
                u16::try_from(decoded.len()).unwrap_or(u16::MAX),
                decoded.iter().all(|byte| *byte == 0),
            ) {
                return Err(ApiError::internal("stored text-encryption key is invalid"));
            }
            Ok(DirectMessageRecipientDevice {
                device_id,
                text_encryption_key_fingerprint: fingerprint(&decoded),
                text_encryption_public_key,
                key_fingerprint,
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    Ok(DirectMessageRecipientResponse {
        crypto_version: direct_message::CRYPTO_VERSION_V1,
        nickname: nickname.to_string(),
        user_id: recipient_user_id,
        devices,
    })
}

fn normalize_direct_message_envelope(
    envelope: &DirectMessageEnvelopeRequest,
    auth: &AuthenticatedDevice,
    recipient_nickname: &str,
    client_message_id: &str,
) -> Result<NormalizedDirectMessageEnvelope, ApiError> {
    let recipient_device_id = envelope.recipient_device_id.trim();
    if recipient_device_id.is_empty()
        || recipient_device_id.len() > 128
        || !recipient_device_id.is_ascii()
    {
        return Err(ApiError::bad_request("invalid recipient device ID"));
    }
    let recipient_key_fingerprint = envelope
        .recipient_key_fingerprint
        .trim()
        .to_ascii_lowercase();
    if recipient_key_fingerprint.len() != 24
        || !recipient_key_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(ApiError::bad_request("invalid recipient key fingerprint"));
    }
    let ephemeral_public_key = decode_bounded_base64(
        &envelope.ephemeral_public_key,
        usize::from(direct_message::X25519_PUBLIC_KEY_BYTES),
        "ephemeral public key",
    )?;
    let nonce = decode_bounded_base64(
        &envelope.nonce,
        usize::from(direct_message::AEAD_NONCE_BYTES),
        "direct-message nonce",
    )?;
    let ciphertext = decode_bounded_base64(
        &envelope.ciphertext,
        usize::from(direct_message::MAX_CIPHERTEXT_BYTES),
        "direct-message ciphertext",
    )?;
    let sender_signature = decode_bounded_base64(
        &envelope.sender_signature,
        128,
        "direct-message sender signature",
    )?;
    let signature_payload = direct_message_signature_payload(
        &auth.user_id,
        &auth.device_id,
        recipient_nickname,
        envelope.crypto_version,
        recipient_device_id,
        &recipient_key_fingerprint,
        client_message_id,
        &ephemeral_public_key,
        &nonce,
        &ciphertext,
    );
    verify_signature(
        &auth.signing_public_key,
        &general_purpose::STANDARD.encode(&sender_signature),
        &signature_payload,
    )
    .map_err(|_| ApiError::bad_request("invalid direct-message sender signature"))?;
    let ephemeral_all_zero = ephemeral_public_key.iter().all(|byte| *byte == 0);
    if !direct_message::envelope_is_valid(
        envelope.crypto_version,
        u16::try_from(ephemeral_public_key.len()).unwrap_or(u16::MAX),
        ephemeral_all_zero,
        u16::try_from(nonce.len()).unwrap_or(u16::MAX),
        u16::try_from(ciphertext.len()).unwrap_or(u16::MAX),
        true,
    ) {
        return Err(ApiError::bad_request(
            "invalid encrypted direct-message envelope",
        ));
    }
    Ok(NormalizedDirectMessageEnvelope {
        crypto_version: envelope.crypto_version,
        recipient_device_id: recipient_device_id.to_string(),
        recipient_key_fingerprint,
        ephemeral_public_key,
        nonce,
        ciphertext,
        sender_signature,
    })
}

fn decode_bounded_base64(
    value: &str,
    maximum_bytes: usize,
    label: &str,
) -> Result<Vec<u8>, ApiError> {
    let value = value.trim();
    let maximum_encoded_length = maximum_bytes.saturating_add(2) / 3 * 4;
    if value.is_empty() || value.len() > maximum_encoded_length.saturating_add(4) {
        return Err(ApiError::bad_request(format!("invalid {label}")));
    }
    let decoded = general_purpose::STANDARD
        .decode(value)
        .map_err(|_| ApiError::bad_request(format!("invalid {label}")))?;
    if decoded.len() > maximum_bytes {
        return Err(ApiError::bad_request(format!("invalid {label}")));
    }
    Ok(decoded)
}

fn direct_message_signature_payload(
    sender_user_id: &str,
    sender_device_id: &str,
    recipient_nickname: &str,
    crypto_version: u8,
    recipient_device_id: &str,
    recipient_key_fingerprint: &str,
    client_message_id: &str,
    ephemeral_public_key: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
) -> Vec<u8> {
    let mut payload = b"TRINET-DIRECT-MESSAGE-V1".to_vec();
    for field in [
        sender_user_id.as_bytes(),
        sender_device_id.as_bytes(),
        recipient_nickname.as_bytes(),
        std::slice::from_ref(&crypto_version),
        recipient_device_id.as_bytes(),
        recipient_key_fingerprint.as_bytes(),
        client_message_id.as_bytes(),
        ephemeral_public_key,
        nonce,
        ciphertext,
    ] {
        let length = u32::try_from(field.len()).unwrap_or(u32::MAX);
        payload.extend_from_slice(&length.to_be_bytes());
        payload.extend_from_slice(field);
    }
    payload
}

fn load_existing_direct_message(
    database: &Connection,
    sender_device_id: &str,
    client_message_id: &str,
) -> Result<Option<ExistingDirectMessage>, ApiError> {
    Ok(database
        .query_row(
            "SELECT sender_user_id, message_id, client_message_id,
                    recipient_user_id, recipient_nickname, created_at
             FROM direct_messages
             WHERE sender_device_id = ?1 AND client_message_id = ?2",
            params![sender_device_id, client_message_id],
            |row| {
                Ok(ExistingDirectMessage {
                    sender_user_id: row.get(0)?,
                    response: DirectMessageSendResponse {
                        message_id: row.get(1)?,
                        client_message_id: row.get(2)?,
                        recipient_user_id: row.get(3)?,
                        recipient_nickname: row.get(4)?,
                        created_at: row.get(5)?,
                        inserted: false,
                    },
                })
            },
        )
        .optional()?)
}

fn direct_message_envelope_intent_matches(
    database: &Connection,
    message_id: i64,
    requested: &[NormalizedDirectMessageEnvelope],
) -> Result<bool, ApiError> {
    let stored = {
        let mut statement = database.prepare(
            "SELECT crypto_version, recipient_device_id,
                    recipient_key_fingerprint, ephemeral_public_key, nonce,
                    ciphertext
             FROM direct_message_envelopes
             WHERE message_id = ?1 ORDER BY recipient_device_id",
        )?;
        let envelopes = statement
            .query_map(params![message_id], |row| {
                Ok((
                    row.get::<_, u8>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Vec<u8>>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, Vec<u8>>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        envelopes
    };
    Ok(stored.len() == requested.len()
        && stored.iter().zip(requested).all(|(stored, requested)| {
            stored.0 == requested.crypto_version
                && stored.1 == requested.recipient_device_id
                && stored.2 == requested.recipient_key_fingerprint
                && stored.3 == requested.ephemeral_public_key
                && stored.4 == requested.nonce
                && stored.5 == requested.ciphertext
        }))
}

fn direct_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DirectMessageInboxMessage> {
    let message_id = row.get::<_, i64>(0)?;
    let read_cursor = row.get::<_, i64>(16)?.max(0);
    Ok(DirectMessageInboxMessage {
        message_id,
        client_message_id: row.get(1)?,
        sender_user_id: row.get(2)?,
        sender_device_id: row.get(3)?,
        sender_nickname: row.get(4)?,
        sender_signing_public_key: row.get(5)?,
        sender_key_fingerprint: row.get(6)?,
        recipient_nickname: row.get(7)?,
        crypto_version: row.get(8)?,
        recipient_device_id: row.get(9)?,
        recipient_key_fingerprint: row.get(10)?,
        ephemeral_public_key: general_purpose::STANDARD.encode(row.get::<_, Vec<u8>>(11)?),
        nonce: general_purpose::STANDARD.encode(row.get::<_, Vec<u8>>(12)?),
        ciphertext: general_purpose::STANDARD.encode(row.get::<_, Vec<u8>>(13)?),
        sender_signature: general_purpose::STANDARD.encode(row.get::<_, Vec<u8>>(14)?),
        created_at: row.get(15)?,
        read: message_id <= read_cursor,
    })
}

fn direct_unread_count_for_device(
    database: &Connection,
    user_id: &str,
    device_id: &str,
) -> Result<u32, ApiError> {
    let mut statement = database.prepare(
        "SELECT m.message_id, m.sender_user_id,
                COALESCE(r.last_read_message_id, 0)
         FROM direct_messages m
         JOIN direct_message_envelopes e ON e.message_id = m.message_id
         LEFT JOIN direct_message_read_state r
           ON r.owner_user_id = m.recipient_user_id
          AND r.peer_user_id = m.sender_user_id
         WHERE m.recipient_user_id = ?1 AND e.recipient_device_id = ?2",
    )?;
    let messages = statement
        .query_map(params![user_id, device_id], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(messages
        .iter()
        .fold(0_u32, |count, (message_id, sender_user_id, read_cursor)| {
            if direct_message::message_counts_as_unread(
                (*message_id).max(0) as u64,
                (*read_cursor).max(0) as u64,
                sender_user_id == user_id,
            ) {
                count.saturating_add(1)
            } else {
                count
            }
        }))
}

fn total_badge_count_for_device(
    database: &Connection,
    user_id: &str,
    device_id: &str,
) -> Result<u32, ApiError> {
    let group = total_unread_count_for_user(database, user_id)?;
    let direct = direct_unread_count_for_device(database, user_id, device_id)?;
    Ok(group.saturating_add(direct))
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
            for (device_id, token, environment) in devices {
                if group_chat::push_alert_may_be_sent(
                    sender_is_recipient,
                    true,
                    alert_push_is_reachable(&state.configuration, &token, &environment),
                    inserted,
                ) {
                    let badge = total_badge_count_for_device(&transaction, &user_id, &device_id)?;
                    jobs.push((device_id, token, environment, badge));
                }
            }
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
                        "default",
                        Some(&chat_id),
                        unix_time().saturating_add(3600),
                        None,
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
                            error.token_invalid,
                            error.bad_device_token,
                            error.alternate_attempted,
                            true,
                        ) =>
                    {
                        if let Ok(database) = database.lock() {
                            let _ = database.execute(
                                "UPDATE devices
                                 SET alert_push_token = NULL,
                                     alert_push_token_registered_at_ms = NULL
                                 WHERE device_id = ?1 AND alert_push_token = ?2
                                   AND (?3 IS NULL
                                        OR alert_push_token_registered_at_ms IS NULL
                                        OR alert_push_token_registered_at_ms <= ?3)",
                                params![device_id, token, error.token_invalid_at_ms],
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
    let current_time =
        u32::try_from(now).map_err(|_| ApiError::unauthorized("request signature is stale"))?;
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
    let (user_id, display_name, public_key, key_fingerprint, capabilities) = match stored {
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
            (
                record.0,
                safe_display_name(&record.1),
                record.2,
                record.4,
                record.3,
            )
        }
        None => {
            let (bootstrap_user_id, bootstrap_public_key) =
                bootstrap.ok_or_else(|| ApiError::unauthorized("device is not registered"))?;
            (
                bootstrap_user_id.to_string(),
                bootstrap_user_id.to_string(),
                bootstrap_public_key.to_string(),
                fingerprint(&decode_public_key(bootstrap_public_key)?),
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
        signing_public_key: public_key,
        key_fingerprint,
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
    sign_livekit_claims(configuration, &claims)
}

fn livekit_room_service_token(configuration: &Configuration) -> Result<String, ApiError> {
    let now = unix_time();
    let claims = LiveKitRoomServiceClaims {
        iss: &configuration.livekit_api_key,
        nbf: now - 5,
        exp: now + i64::from(internet_call::LIVEKIT_ROOM_SERVICE_TOKEN_TTL_SECONDS),
        video: LiveKitRoomServiceGrant { room_create: true },
    };
    sign_livekit_claims(configuration, &claims)
}

fn sign_livekit_claims<T: Serialize>(
    configuration: &Configuration,
    claims: &T,
) -> Result<String, ApiError> {
    let header = general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
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

fn livekit_delete_room_endpoint(livekit_url: &str) -> Result<reqwest::Url, &'static str> {
    let mut endpoint =
        reqwest::Url::parse(livekit_url).map_err(|_| "invalid LiveKit service URL")?;
    let http_scheme = match endpoint.scheme() {
        "wss" => "https",
        "ws" => "http",
        "https" => "https",
        "http" => "http",
        _ => return Err("unsupported LiveKit service URL scheme"),
    };
    endpoint
        .set_scheme(http_scheme)
        .map_err(|_| "invalid LiveKit service URL scheme")?;
    endpoint.set_path("/twirp/livekit.RoomService/DeleteRoom");
    endpoint.set_query(None);
    endpoint.set_fragment(None);
    Ok(endpoint)
}

async fn delete_livekit_room(
    configuration: &Configuration,
    room_id: &str,
) -> Result<(), &'static str> {
    let endpoint = livekit_delete_room_endpoint(&configuration.livekit_url)?;
    let token = livekit_room_service_token(configuration)
        .map_err(|_| "could not sign LiveKit RoomService token")?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|_| "could not initialize LiveKit RoomService client")?;
    let response = client
        .post(endpoint)
        .bearer_auth(token)
        .json(&LiveKitDeleteRoomRequest { room: room_id })
        .send()
        .await
        .map_err(|_| "LiveKit DeleteRoom transport request failed")?;
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    if status == reqwest::StatusCode::NOT_FOUND {
        let body = read_bounded_livekit_error_body(response).await?;
        let error = serde_json::from_slice::<LiveKitTwirpErrorResponse>(&body)
            .map_err(|_| "LiveKit DeleteRoom returned an invalid Twirp error response")?;
        if error.code == "not_found" {
            return Ok(());
        }
    }
    Err("LiveKit DeleteRoom returned a non-success status")
}

async fn read_bounded_livekit_error_body(
    mut response: reqwest::Response,
) -> Result<Vec<u8>, &'static str> {
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "could not read LiveKit Twirp error response")?
    {
        if body.len().saturating_add(chunk.len()) > LIVEKIT_TWIRP_ERROR_MAX_BYTES {
            return Err("LiveKit Twirp error response exceeded the size limit");
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn schedule_livekit_room_cleanup(configuration: Arc<Configuration>, room_id: String) {
    tokio::spawn(async move {
        if let Err(error) = delete_livekit_room(&configuration, &room_id).await {
            eprintln!("LiveKit cleanup failed after terminal call state was committed: {error}");
        }
    });
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

fn unix_time_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
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

fn is_raw_ip_address(value: &str) -> bool {
    let candidate = value.trim().trim_start_matches('@');
    let host = if let Some(bracketed) = candidate.strip_prefix('[') {
        bracketed
            .split_once(']')
            .map_or(candidate, |(host, _)| host)
    } else if candidate.matches(':').count() == 1 {
        candidate
            .rsplit_once(':')
            .filter(|(_, port)| !port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()))
            .map_or(candidate, |(host, _)| host)
    } else {
        candidate
    };
    host.split('%')
        .next()
        .unwrap_or(host)
        .parse::<IpAddr>()
        .is_ok()
}

fn safe_display_name(value: &str) -> String {
    let candidate = value.trim();
    if candidate.is_empty() || candidate.chars().count() > 64 || is_raw_ip_address(candidate) {
        "TRI-NET peer".to_string()
    } else {
        candidate.to_string()
    }
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
        text_encryption_public_key: String,
        text_encryption_key_fingerprint: String,
    }

    #[derive(Clone, Default)]
    struct LiveKitRequestCapture {
        request: Arc<Mutex<Option<(HeaderMap, Bytes)>>>,
    }

    async fn capture_livekit_delete_room(
        State(capture): State<LiveKitRequestCapture>,
        headers: HeaderMap,
        body: Bytes,
    ) -> StatusCode {
        *capture.request.lock().unwrap() = Some((headers, body));
        StatusCode::OK
    }

    async fn simulate_livekit_delete_room_error(body: Bytes) -> Response {
        let request: Value = serde_json::from_slice(&body).unwrap();
        match request["room"].as_str().unwrap() {
            "missing_room" => (
                StatusCode::NOT_FOUND,
                Json(json!({"code": "not_found", "msg": "room does not exist"})),
            )
                .into_response(),
            "bad_route" => (
                StatusCode::NOT_FOUND,
                Json(json!({"code": "bad_route", "msg": "wrong Twirp route"})),
            )
                .into_response(),
            "oversized" => (
                StatusCode::NOT_FOUND,
                "x".repeat(LIVEKIT_TWIRP_ERROR_MAX_BYTES + 1),
            )
                .into_response(),
            _ => (StatusCode::NOT_FOUND, "<html>proxy not found</html>").into_response(),
        }
    }

    impl TestDevice {
        fn new(user_id: &str, device_id: &str, display_name: &str) -> Self {
            let signing_key = SigningKey::random(&mut OsRng);
            let public_key_bytes = signing_key.verifying_key().to_encoded_point(false);
            let mut text_encryption_public_key = [0_u8; 32];
            OsRng.fill_bytes(&mut text_encryption_public_key);
            Self {
                user_id: user_id.to_string(),
                device_id: device_id.to_string(),
                display_name: display_name.to_string(),
                public_key: general_purpose::STANDARD.encode(public_key_bytes.as_bytes()),
                fingerprint: fingerprint(public_key_bytes.as_bytes()),
                text_encryption_public_key: general_purpose::STANDARD
                    .encode(text_encryption_public_key),
                text_encryption_key_fingerprint: fingerprint(&text_encryption_public_key),
                signing_key,
            }
        }

        fn registration(&self) -> Value {
            json!({
                "user_id": self.user_id,
                "device_id": self.device_id,
                "display_name": self.display_name,
                "signing_public_key": self.public_key,
                "text_encryption_public_key": self.text_encryption_public_key,
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
            apns_outbox_owner: "test-process-owner".to_string(),
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

    fn signed_direct_envelope(
        sender: &TestDevice,
        recipient: &TestDevice,
        recipient_nickname: &str,
        client_message_id: &str,
        marker: u8,
    ) -> Value {
        let ephemeral_public_key = vec![marker.max(1); 32];
        let nonce = vec![marker.wrapping_add(1).max(1); 12];
        let ciphertext = vec![marker.wrapping_add(2).max(1); 17];
        let payload = direct_message_signature_payload(
            &sender.user_id,
            &sender.device_id,
            recipient_nickname,
            direct_message::CRYPTO_VERSION_V1,
            &recipient.device_id,
            &recipient.text_encryption_key_fingerprint,
            client_message_id,
            &ephemeral_public_key,
            &nonce,
            &ciphertext,
        );
        let signature: p256::ecdsa::Signature = sender.signing_key.sign(&payload);
        json!({
            "crypto_version": direct_message::CRYPTO_VERSION_V1,
            "recipient_device_id": recipient.device_id,
            "recipient_key_fingerprint": recipient.text_encryption_key_fingerprint,
            "ephemeral_public_key": general_purpose::STANDARD.encode(ephemeral_public_key),
            "nonce": general_purpose::STANDARD.encode(nonce),
            "ciphertext": general_purpose::STANDARD.encode(ciphertext),
            "sender_signature": general_purpose::STANDARD.encode(signature.to_der().as_bytes())
        })
    }

    #[test]
    fn adapter_similarity_matches_generated_policy() {
        assert!(nicknames_are_confusing("alice", "alica"));
        assert!(nicknames_are_confusing("alice", "alice2"));
        assert!(!nicknames_are_confusing("alice", "bob_net"));
    }

    #[test]
    fn display_name_never_exposes_a_raw_network_address() {
        assert_eq!(safe_display_name("192.168.1.20"), "TRI-NET peer");
        assert_eq!(safe_display_name("@192.168.1.20:7000"), "TRI-NET peer");
        assert_eq!(safe_display_name("[fe80::1%en0]:7000"), "TRI-NET peer");
        assert_eq!(safe_display_name(" Alice "), "Alice");
    }

    #[test]
    fn database_upgrade_adds_call_idempotency_column_before_unique_index() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE calls (
                    call_id TEXT PRIMARY KEY,
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
                    answered_at INTEGER
                );",
            )
            .unwrap();
        initialize_database(&connection).unwrap();
        let columns = {
            let mut statement = connection.prepare("PRAGMA table_info(calls)").unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        let index_exists = connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'index' AND name = 'calls_caller_client_id'
                )",
                [],
                |row| row.get::<_, bool>(0),
            )
            .unwrap();
        assert!(columns.iter().any(|column| column == "client_call_id"));
        assert!(index_exists);
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

    #[tokio::test]
    async fn livekit_delete_room_uses_twirp_and_room_create_grant() {
        let capture = LiveKitRequestCapture::default();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server_application = Router::new()
            .route(
                "/twirp/livekit.RoomService/DeleteRoom",
                post(capture_livekit_delete_room),
            )
            .with_state(capture.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, server_application).await.unwrap();
        });
        let configuration = Configuration {
            bind: "127.0.0.1:8080".parse().unwrap(),
            livekit_url: format!("ws://{address}/rtc?ignored=true"),
            livekit_api_key: "devkey".to_string(),
            livekit_api_secret: "secret".to_string(),
            service_access_token: None,
            apns: None,
        };

        let endpoint = livekit_delete_room_endpoint("wss://livekit.example/rtc?x=1").unwrap();
        assert_eq!(
            endpoint.as_str(),
            "https://livekit.example/twirp/livekit.RoomService/DeleteRoom"
        );
        delete_livekit_room(&configuration, "room_to_delete")
            .await
            .unwrap();

        let (headers, body) = capture.request.lock().unwrap().take().unwrap();
        let authorization = headers
            .get("authorization")
            .unwrap()
            .to_str()
            .unwrap()
            .strip_prefix("Bearer ")
            .unwrap();
        let claims = authorization.split('.').nth(1).unwrap();
        let claims = general_purpose::URL_SAFE_NO_PAD.decode(claims).unwrap();
        let claims: Value = serde_json::from_slice(&claims).unwrap();
        assert_eq!(claims["iss"], "devkey");
        assert_eq!(claims["video"]["roomCreate"], true);
        assert!(claims.get("sub").is_none());
        assert!(claims["exp"].as_i64().unwrap() > claims["nbf"].as_i64().unwrap());
        let request: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(request, json!({"room": "room_to_delete"}));

        server.abort();
        let _ = server.await;
    }

    #[tokio::test]
    async fn livekit_delete_room_accepts_only_structured_twirp_not_found() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server_application = Router::new().route(
            "/twirp/livekit.RoomService/DeleteRoom",
            post(simulate_livekit_delete_room_error),
        );
        let server = tokio::spawn(async move {
            axum::serve(listener, server_application).await.unwrap();
        });
        let configuration = Configuration {
            bind: "127.0.0.1:8080".parse().unwrap(),
            livekit_url: format!("ws://{address}"),
            livekit_api_key: "devkey".to_string(),
            livekit_api_secret: "secret".to_string(),
            service_access_token: None,
            apns: None,
        };

        delete_livekit_room(&configuration, "missing_room")
            .await
            .unwrap();
        assert_eq!(
            delete_livekit_room(&configuration, "bad_route")
                .await
                .unwrap_err(),
            "LiveKit DeleteRoom returned a non-success status"
        );
        assert_eq!(
            delete_livekit_room(&configuration, "proxy_404")
                .await
                .unwrap_err(),
            "LiveKit DeleteRoom returned an invalid Twirp error response"
        );
        assert_eq!(
            delete_livekit_room(&configuration, "oversized")
                .await
                .unwrap_err(),
            "LiveKit Twirp error response exceeded the size limit"
        );

        server.abort();
        let _ = server.await;
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
                sound: "default",
                thread_id: Some("chat_1234"),
            },
            data: json!({
                "type": "group_chat_message",
                "chat_id": "chat_1234"
            }),
        })
        .unwrap();
        assert_eq!(payload["aps"]["badge"], 7);
        assert_eq!(payload["aps"]["sound"], "default");
        assert_eq!(payload["aps"]["thread-id"], "chat_1234");
        assert_eq!(payload["chat_id"], "chat_1234");
        assert!(payload.to_string().find("Meet at point").is_none());
    }

    #[test]
    fn direct_message_alert_metadata_has_normalized_sender_without_content() {
        let data = direct_message_alert_data("sender-user", "sender_net");
        let payload = serde_json::to_value(AlertPushPayload {
            aps: AlertPushAps {
                alert: AlertPushText {
                    title: "TRI-NET",
                    body: "New encrypted message from @sender_net",
                },
                badge: 3,
                sound: "default",
                thread_id: Some("direct-messages"),
            },
            data,
        })
        .unwrap();
        assert_eq!(payload["type"], "direct_message");
        assert_eq!(payload["sender_user_id"], "sender-user");
        assert_eq!(payload["sender_nickname"], "sender_net");
        assert_eq!(payload["aps"]["sound"], "default");
        assert!(payload.get("text").is_none());
        assert!(payload.get("ciphertext").is_none());
    }

    #[test]
    fn apns_outbox_is_transactional_idempotent_and_crash_recoverable() {
        let mut database = Connection::open_in_memory().unwrap();
        initialize_database(&database).unwrap();
        let payload = DirectMessageOutboxPayload {
            sender_user_id: "sender-user".to_string(),
            sender_nickname: "sender_net".to_string(),
        };

        {
            let transaction = database
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            enqueue_apns_outbox_event(
                &transaction,
                APNS_OUTBOX_DIRECT_MESSAGE,
                "42",
                "device-one",
                &payload,
                100,
            )
            .unwrap();
            transaction.rollback().unwrap();
        }
        let rolled_back = database
            .query_row("SELECT COUNT(*) FROM apns_outbox", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap();
        assert_eq!(rolled_back, 0);

        {
            let transaction = database
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            for _ in 0..2 {
                enqueue_apns_outbox_event(
                    &transaction,
                    APNS_OUTBOX_DIRECT_MESSAGE,
                    "42",
                    "device-one",
                    &payload,
                    100,
                )
                .unwrap();
            }
            transaction.commit().unwrap();
        }
        let persisted = database
            .query_row(
                "SELECT COUNT(*), payload_json FROM apns_outbox",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .unwrap();
        assert_eq!(persisted.0, 1);
        let persisted_payload: Value = serde_json::from_str(&persisted.1).unwrap();
        assert_eq!(persisted_payload["sender_nickname"], "sender_net");
        assert!(persisted_payload.get("text").is_none());
        assert!(persisted_payload.get("ciphertext").is_none());

        let first_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-a",
            100,
        )
        .unwrap()
        .unwrap();
        assert_eq!(first_claim.attempts, 0);
        Uuid::parse_str(&first_claim.event_id).unwrap();
        assert!(claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-a",
            101,
        )
        .unwrap()
        .is_none());
        let recovered = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            101,
        )
        .unwrap()
        .unwrap();
        assert_eq!(recovered.event_id, first_claim.event_id);

        let failure = ApnsDeliveryError {
            status: Some(503),
            reason: Some("ServiceUnavailable".to_string()),
            token_invalid_at_ms: None,
            permanent: false,
            bad_device_token: false,
            token_invalid: false,
            refresh_provider_token: false,
            transient: true,
            alternate_attempted: false,
        };
        let retry_scheduled_at = recovered.claimed_at;
        reschedule_apns_outbox_event(&mut database, &recovered, &failure, retry_scheduled_at)
            .unwrap();
        let retry = database
            .query_row(
                "SELECT attempts, next_attempt_at, claimed_at,
                        last_failure_kind, last_status
                 FROM apns_outbox WHERE event_id = ?1",
                params![recovered.event_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<i64>>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(retry.0, 1);
        assert!(retry.1 >= retry_scheduled_at + 2 && retry.1 <= retry_scheduled_at + 7);
        assert_eq!(retry.2, None);
        assert_eq!(retry.3, "ServiceUnavailable");
        assert_eq!(retry.4, 503);
        assert!(claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            retry.1 - 1
        )
        .unwrap()
        .is_none());

        let retry_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            retry.1,
        )
        .unwrap()
        .unwrap();
        assert_eq!(retry_claim.attempts, 1);
        acknowledge_apns_outbox_event(&mut database, &retry_claim, None, None).unwrap();
        let remaining = database
            .query_row("SELECT COUNT(*) FROM apns_outbox", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap();
        assert_eq!(remaining, 0);

        {
            let transaction = database
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            enqueue_apns_outbox_event(
                &transaction,
                APNS_OUTBOX_DIRECT_MESSAGE,
                "alternate-environment",
                "device-one",
                &payload,
                300,
            )
            .unwrap();
            transaction.commit().unwrap();
        }
        let preferred_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-a",
            300,
        )
        .unwrap()
        .unwrap();
        let preferred_token = "cc".repeat(32);
        let preferred_delivery = ApnsOutboxDelivery::DirectMessage {
            token: preferred_token.clone(),
            environment: ApnsEnvironment::Sandbox,
            used_environment_override: false,
            sender: "sender_net".to_string(),
            sender_user_id: "sender-user".to_string(),
            badge: 1,
            expiration: 3_600,
        };
        let bad_device = ApnsDeliveryError {
            status: Some(400),
            reason: Some("BadDeviceToken".to_string()),
            token_invalid_at_ms: None,
            permanent: true,
            bad_device_token: true,
            token_invalid: true,
            refresh_provider_token: false,
            transient: false,
            alternate_attempted: false,
        };
        schedule_apns_outbox_alternate_environment(
            &mut database,
            &preferred_claim,
            &preferred_delivery,
            ApnsEnvironment::Production,
            &bad_device,
            301,
        )
        .unwrap();
        let alternate_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-a",
            301,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            alternate_claim.delivery_environment.as_deref(),
            Some("production")
        );
        assert_eq!(
            alternate_claim.delivery_token_digest.as_deref(),
            Some(apns_token_digest(&preferred_token).as_str())
        );
        assert_eq!(
            apns_outbox_delivery_environment(
                &alternate_claim,
                &preferred_token,
                ApnsEnvironment::Sandbox,
            ),
            (ApnsEnvironment::Production, true)
        );
        assert_eq!(
            apns_outbox_delivery_environment(
                &alternate_claim,
                &"dd".repeat(32),
                ApnsEnvironment::Sandbox,
            ),
            (ApnsEnvironment::Sandbox, false)
        );

        let forbidden = ApnsDeliveryError {
            status: Some(403),
            reason: Some("Forbidden".to_string()),
            token_invalid_at_ms: None,
            permanent: false,
            bad_device_token: false,
            token_invalid: false,
            refresh_provider_token: false,
            transient: false,
            alternate_attempted: false,
        };
        block_apns_outbox_event_for_process(&mut database, &alternate_claim, &forbidden).unwrap();
        assert!(claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-a",
            302,
        )
        .unwrap()
        .is_none());
        let restart_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            302,
        )
        .unwrap()
        .unwrap();
        let blocked_diagnostics = database
            .query_row(
                "SELECT attempts, last_failure_kind, last_status, blocked_owner
                 FROM apns_outbox WHERE event_id = ?1",
                params![restart_claim.event_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(blocked_diagnostics.0, 1);
        assert_eq!(blocked_diagnostics.1, "Forbidden");
        assert_eq!(blocked_diagnostics.2, 403);
        assert_eq!(blocked_diagnostics.3, "process-owner-a");
        acknowledge_apns_outbox_event(&mut database, &restart_claim, None, None).unwrap();

        let old_token = "aa".repeat(32);
        let rotated_token = "bb".repeat(32);
        database
            .execute(
                "INSERT INTO devices
                 (device_id, user_id, display_name, signing_public_key,
                  key_fingerprint, platform, alert_push_token,
                  push_environment, capabilities, last_seen, linked_at)
                 VALUES ('device-rotated', 'recipient-user', 'Recipient',
                         'public-key', 'fingerprint', 'test', ?1,
                         'sandbox', 9, 100, 100)",
                params![rotated_token],
            )
            .unwrap();
        {
            let transaction = database
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            enqueue_apns_outbox_event(
                &transaction,
                APNS_OUTBOX_DIRECT_MESSAGE,
                "43",
                "device-rotated",
                &payload,
                200,
            )
            .unwrap();
            transaction.commit().unwrap();
        }
        let rotation_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            200,
        )
        .unwrap()
        .unwrap();
        let stale_delivery = ApnsOutboxDelivery::DirectMessage {
            token: old_token,
            environment: ApnsEnvironment::Sandbox,
            used_environment_override: false,
            sender: "sender_net".to_string(),
            sender_user_id: "sender-user".to_string(),
            badge: 1,
            expiration: 3_600,
        };
        assert!(!invalidate_apns_outbox_token(
            &mut database,
            &rotation_claim,
            &stale_delivery,
            Some(410),
            Some(150_000),
            201,
        )
        .unwrap());
        let retained = database
            .query_row(
                "SELECT COUNT(*), claimed_at, claim_owner, last_failure_kind,
                        last_status
                 FROM apns_outbox WHERE event_id = ?1",
                params![rotation_claim.event_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(retained.0, 1);
        assert_eq!(retained.1, None);
        assert_eq!(retained.2, None);
        assert_eq!(retained.3, "token_rotated");
        assert_eq!(retained.4, 410);
        let stored_token = database
            .query_row(
                "SELECT alert_push_token FROM devices WHERE device_id = 'device-rotated'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert_eq!(stored_token, rotated_token);

        database
            .execute(
                "UPDATE devices
                 SET alert_push_token = ?1,
                     alert_push_token_registered_at_ms = 300000
                 WHERE device_id = 'device-rotated'",
                params![stale_delivery.token()],
            )
            .unwrap();
        let same_token_reregistered_claim = claim_due_apns_outbox_event(
            &mut database,
            APNS_OUTBOX_DIRECT_MESSAGE,
            "process-owner-b",
            202,
        )
        .unwrap()
        .unwrap();
        assert!(!invalidate_apns_outbox_token(
            &mut database,
            &same_token_reregistered_claim,
            &stale_delivery,
            Some(410),
            Some(250_000),
            203,
        )
        .unwrap());
        let fresh_same_token = database
            .query_row(
                "SELECT alert_push_token, alert_push_token_registered_at_ms
                 FROM devices WHERE device_id = 'device-rotated'",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap();
        assert_eq!(fresh_same_token.0, stale_delivery.token());
        assert_eq!(fresh_same_token.1, 300_000);
    }

    #[test]
    fn apns_retry_and_environment_recovery_follow_generated_policy() {
        assert!(internet_call::APNS_VOIP_OUTBOX_WORKERS > 1);
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

        assert!(apns_failure_is_terminal("BadDeviceToken"));
        assert!(apns_failure_invalidates_token("BadDeviceToken"));
        assert!(!internet_call::apns_token_should_be_invalidated(
            true, true, false, true,
        ));
        assert!(internet_call::apns_token_should_be_invalidated(
            true, true, true, true,
        ));
        for reason in ["DeviceTokenNotForTopic", "ExpiredToken", "Unregistered"] {
            assert!(apns_failure_is_terminal(reason));
            assert!(apns_failure_invalidates_token(reason));
            assert!(internet_call::apns_token_should_be_invalidated(
                apns_failure_invalidates_token(reason),
                false,
                false,
                true,
            ));
        }
        for reason in ["PayloadTooLarge", "MissingTopic", "MethodNotAllowed"] {
            assert!(apns_failure_is_terminal(reason));
            assert!(!apns_failure_invalidates_token(reason));
        }
        for reason in [
            "ExpiredProviderToken",
            "BadCertificate",
            "Forbidden",
            "TooManyRequests",
            "InternalServerError",
            "Shutdown",
        ] {
            assert!(!apns_failure_is_terminal(reason));
            assert!(!apns_failure_invalidates_token(reason));
            assert!(!internet_call::apns_token_should_be_invalidated(
                apns_failure_invalidates_token(reason),
                false,
                false,
                true,
            ));
        }
        assert!(!internet_call::apns_token_should_be_invalidated(
            true, true, true, false,
        ));
        assert_eq!(
            bounded_apns_reason("InvalidProviderToken"),
            "InvalidProviderToken"
        );
        assert_eq!(bounded_apns_reason(&"x".repeat(65)), "unknown");
        assert_eq!(bounded_apns_reason("BadTopic\nsecret"), "unknown");
        let expired: ApnsErrorResponse = serde_json::from_value(json!({
            "reason": "ExpiredToken",
            "timestamp": 250000
        }))
        .unwrap();
        assert_eq!(expired.reason.as_deref(), Some("ExpiredToken"));
        assert_eq!(expired.timestamp, Some(250_000));
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
            let mut registration = device.registration();
            if device.device_id == callee.device_id {
                registration["voip_push_token"] = Value::String("ab".repeat(32));
                registration["push_environment"] = Value::String("sandbox".to_string());
            }
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                registration,
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
            json!({"query": "@BOB_NET", "limit": 20}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["results"][0]["nickname"], "bob_net");

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/directory/search",
            json!({"query": "bob", "limit": 20}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(response.unwrap()["results"].as_array().unwrap().is_empty());

        let call_request = json!({
            "client_call_id": "10000000-0000-4000-8000-000000000001",
            "callee": "bob_net",
            "caller_user_id": caller.user_id,
            "caller_device_id": caller.device_id,
            "audio": true,
            "video": true
        });
        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            call_request.clone(),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let created = response.unwrap();
        let call_id = created["call_id"].as_str().unwrap();
        let room_id = created["room_id"].as_str().unwrap();
        let caller_token = created["token"].as_str().unwrap();
        let caller_claims = general_purpose::URL_SAFE_NO_PAD
            .decode(caller_token.split('.').nth(1).unwrap())
            .unwrap();
        let caller_claims: Value = serde_json::from_slice(&caller_claims).unwrap();
        assert_eq!(caller_claims["name"], "alice_net");

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            call_request.clone(),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["call_id"], call_id);
        let mut conflicting_call_request = call_request;
        conflicting_call_request["video"] = Value::Bool(false);
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/calls",
            conflicting_call_request,
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        let call_count = state
            .database
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM calls", [], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(call_count, 1);
        let call_outbox = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*), event_kind, target_device_id
                 FROM apns_outbox WHERE object_id = ?1",
                params![call_id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(call_outbox.0, 1);
        assert_eq!(call_outbox.1, APNS_OUTBOX_CALL_INVITE);
        assert_eq!(call_outbox.2, callee.device_id);

        // A process crash after claiming must not consume the invite's
        // 30-second freshness window. A new process-generation owner reclaims
        // immediately, and the authoritative call is still deliverable.
        {
            let mut database = state.database.lock().unwrap();
            let call_created_at = database
                .query_row(
                    "SELECT created_at FROM calls WHERE call_id = ?1",
                    params![call_id],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap();
            let abandoned = claim_due_apns_outbox_event(
                &mut database,
                APNS_OUTBOX_CALL_INVITE,
                "crashed-process-owner",
                call_created_at,
            )
            .unwrap()
            .unwrap();
            assert!(claim_due_apns_outbox_event(
                &mut database,
                APNS_OUTBOX_CALL_INVITE,
                "crashed-process-owner",
                call_created_at + 1,
            )
            .unwrap()
            .is_none());
            let recovered = claim_due_apns_outbox_event(
                &mut database,
                APNS_OUTBOX_CALL_INVITE,
                "restarted-process-owner",
                call_created_at + 1,
            )
            .unwrap()
            .unwrap();
            assert_eq!(recovered.event_id, abandoned.event_id);
            assert!(matches!(
                load_apns_outbox_delivery(&database, &recovered, call_created_at + 1).unwrap(),
                Some(ApnsOutboxDelivery::CallInvite { .. })
            ));
            acknowledge_apns_outbox_event(&mut database, &recovered, None, None).unwrap();
        }

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
        assert_eq!(incoming["calls"][0]["caller"], "alice_net");
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
            application(state.clone()),
            &join_path,
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let joined = response.unwrap();
        assert_eq!(joined["room_id"], room_id);
        let callee_claims = general_purpose::URL_SAFE_NO_PAD
            .decode(joined["token"].as_str().unwrap().split('.').nth(1).unwrap())
            .unwrap();
        let callee_claims: Value = serde_json::from_slice(&callee_claims).unwrap();
        assert_eq!(callee_claims["name"], "bob_net");

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
    async fn internet_call_requires_a_verified_caller_nickname() {
        let state = test_state();
        let caller = TestDevice::new("user_unclaimed", "device_unclaimed", "bank_support");
        let callee = TestDevice::new("user_claimed", "device_claimed", "Bob Phone");
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
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/directory/nicknames/claim",
            json!({
                "nickname": "bob_net",
                "user_id": callee.user_id,
                "device_id": callee.device_id
            }),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, _response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "client_call_id": "10000000-0000-4000-8000-000000000099",
                "callee": "bob_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": false
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        let call_count = state
            .database
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM calls", [], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(call_count, 0);
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
                "SELECT voip_push_token, alert_push_token, push_environment,
                        voip_push_token_registered_at_ms,
                        alert_push_token_registered_at_ms
                 FROM devices WHERE device_id = ?1",
                params![device.device_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(stored.0, voip_token);
        assert_eq!(stored.1, alert_token);
        assert_eq!(stored.2, "sandbox");
        assert!(stored.3 > 0);
        assert!(stored.4 >= stored.3);

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
                "client_call_id": "10000000-0000-4000-8000-000000000002",
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
        let status_path = format!("/v1/calls/{call_id}/status");

        let (status, _) = signed_post(
            application(state.clone()),
            &status_path,
            json!({
                "user_id": caller.user_id,
                "device_id": caller_other_device.device_id
            }),
            &caller_other_device,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let (status, response) = signed_post(
            application(state.clone()),
            &status_path,
            json!({"user_id": callee.user_id, "device_id": callee.device_id}),
            &callee,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["status"], "ringing");

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
            &status_path,
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["status"], "cancelled");

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
            application(state.clone()),
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
                "client_call_id": "10000000-0000-4000-8000-000000000003",
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
            application(state.clone()),
            &join_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_phone.device_id}),
            &owner_phone,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let status_path = format!("/v1/calls/{call_id}/status");
        let (status, response) = signed_post(
            application(state.clone()),
            &status_path,
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let caller_status = response.unwrap();
        assert_eq!(caller_status["status"], "active");
        assert_eq!(caller_status["role"], "caller");

        let (status, response) = signed_post(
            application(state.clone()),
            &status_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_mac.device_id}),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let answerer_status = response.unwrap();
        assert_eq!(answerer_status["status"], "active");
        assert_eq!(answerer_status["target_status"], "active");
        assert_eq!(answerer_status["answered_here"], true);

        let end_path = format!("/v1/calls/{call_id}/end");
        let (status, _) = signed_post(
            application(state.clone()),
            &end_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_phone.device_id}),
            &owner_phone,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);

        let (status, response) = signed_post(
            application(state.clone()),
            &end_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_mac.device_id}),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["status"], "ended");

        let (status, response) = signed_post(
            application(state.clone()),
            &end_path,
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["status"], "ended");
        let non_ended_targets = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM call_targets WHERE call_id = ?1 AND state != ?2",
                params![call_id, internet_call::CALL_ENDED],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(non_ended_targets, 0);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "client_call_id": "10000000-0000-4000-8000-000000000003",
                "callee": "owner_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": true
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        let terminal_retry = response.unwrap();
        assert_eq!(terminal_retry["call_id"], call_id);
        assert_eq!(terminal_retry["status"], "ended");
        assert!(terminal_retry.get("token").is_none());

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "client_call_id": "10000000-0000-4000-8000-000000000103",
                "callee": "owner_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": false
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let declined_call_id = response.unwrap()["call_id"].as_str().unwrap().to_string();
        let decline_path = format!("/v1/calls/{declined_call_id}/decline");

        for _ in 0..2 {
            let (status, response) = signed_post(
                application(state.clone()),
                &decline_path,
                json!({
                    "user_id": owner_phone.user_id,
                    "device_id": owner_phone.device_id
                }),
                &owner_phone,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            let partial_decline = response.unwrap();
            assert_eq!(partial_decline["status"], "ringing");
            assert_eq!(partial_decline["target_status"], "declined");
        }

        let (status, response) = signed_post(
            application(state.clone()),
            &decline_path,
            json!({
                "user_id": owner_phone.user_id,
                "device_id": owner_mac.device_id
            }),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let final_decline = response.unwrap();
        assert_eq!(final_decline["status"], "declined");
        assert_eq!(final_decline["target_status"], "declined");

        let declined_status_path = format!("/v1/calls/{declined_call_id}/status");
        let (status, response) = signed_post(
            application(state.clone()),
            &declined_status_path,
            json!({"user_id": caller.user_id, "device_id": caller.device_id}),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["status"], "declined");

        let declined_join_path = format!("/v1/calls/{declined_call_id}/join");
        let (status, _) = signed_post(
            application(state),
            &declined_join_path,
            json!({"user_id": owner_phone.user_id, "device_id": owner_mac.device_id}),
            &owner_mac,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn encrypted_direct_messages_fan_out_idempotently_and_share_read_state() {
        let state = test_state();
        let mut sender = TestDevice::new("user_dm_sender", "device_dm_sender", "Sender Phone");
        let recipient_phone = TestDevice::new(
            "user_dm_recipient",
            "device_dm_recipient_phone",
            "Recipient Phone",
        );
        let recipient_tablet = TestDevice::new(
            "user_dm_temporary",
            "device_dm_recipient_tablet",
            "Recipient Tablet",
        );
        for device in [&sender, &recipient_phone, &recipient_tablet] {
            let mut registration = device.registration();
            if device.device_id == recipient_phone.device_id {
                registration["alert_push_token"] = Value::String("cd".repeat(32));
                registration["push_environment"] = Value::String("sandbox".to_string());
            } else if device.device_id == recipient_tablet.device_id {
                registration["alert_push_token"] = Value::String("ef".repeat(32));
                registration["push_environment"] = Value::String("production".to_string());
            }
            let (status, _) = signed_post(
                application(state.clone()),
                "/v1/devices/register",
                registration,
                device,
            )
            .await;
            assert_eq!(status, StatusCode::NO_CONTENT);
        }
        for (device, nickname) in [(&sender, "sender_net"), (&recipient_phone, "recipient_net")] {
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
        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/account/link-code",
            json!({
                "user_id": recipient_phone.user_id,
                "device_id": recipient_phone.device_id
            }),
            &recipient_phone,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let link_code = response.unwrap()["link_code"].as_str().unwrap().to_string();
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/account/link",
            json!({
                "user_id": recipient_tablet.user_id,
                "device_id": recipient_tablet.device_id,
                "link_code": link_code
            }),
            &recipient_tablet,
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/direct-messages/recipients",
            json!({
                "user_id": sender.user_id,
                "device_id": sender.device_id,
                "nickname": "@RECIPIENT_NET"
            }),
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let recipient = response.unwrap();
        assert_eq!(recipient["nickname"], "recipient_net");
        assert_eq!(recipient["crypto_version"], 1);
        assert_eq!(recipient["devices"].as_array().unwrap().len(), 2);

        let client_message_id = "20000000-0000-4000-8000-000000000001";
        let send_body = json!({
            "user_id": sender.user_id,
            "device_id": sender.device_id,
            "recipient": "recipient_net",
            "client_message_id": client_message_id,
            "envelopes": [
                signed_direct_envelope(
                    &sender,
                    &recipient_phone,
                    "recipient_net",
                    client_message_id,
                    10,
                ),
                signed_direct_envelope(
                    &sender,
                    &recipient_tablet,
                    "recipient_net",
                    client_message_id,
                    20,
                )
            ]
        });
        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/direct-messages",
            send_body.clone(),
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let first_send = response.unwrap();
        assert_eq!(first_send["inserted"], true);
        let message_id = first_send["message_id"].as_i64().unwrap();

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/direct-messages",
            send_body,
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let retry = response.unwrap();
        assert_eq!(retry["inserted"], false);
        assert_eq!(retry["message_id"], message_id);
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/direct-messages",
            json!({
                "user_id": sender.user_id,
                "device_id": sender.device_id,
                "recipient": "recipient_net",
                "client_message_id": client_message_id,
                "envelopes": [
                    signed_direct_envelope(
                        &sender,
                        &recipient_phone,
                        "recipient_net",
                        client_message_id,
                        11,
                    ),
                    signed_direct_envelope(
                        &sender,
                        &recipient_tablet,
                        "recipient_net",
                        client_message_id,
                        21,
                    )
                ]
            }),
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        let database = state.database.lock().unwrap();
        let message_count = database
            .query_row("SELECT COUNT(*) FROM direct_messages", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap();
        let envelope_count = database
            .query_row("SELECT COUNT(*) FROM direct_message_envelopes", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap();
        let ciphertext_type = database
            .query_row(
                "SELECT typeof(ciphertext) FROM direct_message_envelopes LIMIT 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        let direct_message_columns = {
            let mut statement = database
                .prepare("PRAGMA table_info(direct_messages)")
                .unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        let outbox_events = {
            let mut statement = database
                .prepare(
                    "SELECT event_kind, target_device_id, payload_json
                     FROM apns_outbox WHERE object_id = ?1
                     ORDER BY target_device_id",
                )
                .unwrap();
            statement
                .query_map(params![message_id.to_string()], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        drop(database);
        assert_eq!(message_count, 1);
        assert_eq!(envelope_count, 2);
        assert_eq!(ciphertext_type, "blob");
        assert!(!direct_message_columns.iter().any(|column| column == "text"));
        assert_eq!(outbox_events.len(), 2);
        assert!(outbox_events
            .iter()
            .all(|event| event.0 == APNS_OUTBOX_DIRECT_MESSAGE));
        assert_eq!(
            outbox_events
                .iter()
                .map(|event| event.1.as_str())
                .collect::<HashSet<_>>()
                .len(),
            2
        );
        for event in outbox_events {
            let payload: Value = serde_json::from_str(&event.2).unwrap();
            assert_eq!(payload["sender_user_id"], sender.user_id);
            assert_eq!(payload["sender_nickname"], "sender_net");
            assert!(payload.get("text").is_none());
            assert!(payload.get("ciphertext").is_none());
        }

        let inbox_body = |device: &TestDevice| {
            json!({
                "user_id": recipient_phone.user_id,
                "device_id": device.device_id,
                "after_message_id": 0,
                "limit": 50
            })
        };
        for device in [&recipient_phone, &recipient_tablet] {
            let (status, response) = signed_post(
                application(state.clone()),
                "/v1/direct-messages/inbox",
                inbox_body(device),
                device,
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            let inbox = response.unwrap();
            assert_eq!(inbox["messages"].as_array().unwrap().len(), 1);
            assert_eq!(
                inbox["messages"][0]["recipient_device_id"],
                device.device_id
            );
            assert_eq!(inbox["messages"][0]["read"], false);
            assert_eq!(inbox["total_unread_count"], 1);
            assert!(inbox["messages"][0].get("text").is_none());
        }

        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/direct-messages/read",
            json!({
                "user_id": recipient_phone.user_id,
                "device_id": recipient_phone.device_id,
                "sender_user_id": "unknown_sender",
                "through_message_id": message_id
            }),
            &recipient_phone,
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let read_state_count = state
            .database
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM direct_message_read_state",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(read_state_count, 0);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/direct-messages/read",
            json!({
                "user_id": recipient_phone.user_id,
                "device_id": recipient_phone.device_id,
                "sender_user_id": sender.user_id,
                "through_message_id": message_id
            }),
            &recipient_phone,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response.unwrap()["total_unread_count"], 0);

        let (status, response) = signed_post(
            application(state.clone()),
            "/v1/direct-messages/inbox",
            inbox_body(&recipient_tablet),
            &recipient_tablet,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let tablet_inbox = response.unwrap();
        assert_eq!(tablet_inbox["messages"][0]["read"], true);
        assert_eq!(tablet_inbox["total_unread_count"], 0);

        {
            let mut database = state.database.lock().unwrap();
            let now = unix_time();
            let delayed_alert = claim_due_apns_outbox_event(
                &mut database,
                APNS_OUTBOX_DIRECT_MESSAGE,
                "read-suppression-owner",
                now,
            )
            .unwrap()
            .unwrap();
            assert!(load_apns_outbox_delivery(&database, &delayed_alert, now)
                .unwrap()
                .is_none());
            acknowledge_apns_outbox_event(&mut database, &delayed_alert, None, None).unwrap();
        }

        let incomplete_message_id = "20000000-0000-4000-8000-000000000002";
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/direct-messages",
            json!({
                "user_id": sender.user_id,
                "device_id": sender.device_id,
                "recipient": "recipient_net",
                "client_message_id": incomplete_message_id,
                "envelopes": [signed_direct_envelope(
                    &sender,
                    &recipient_phone,
                    "recipient_net",
                    incomplete_message_id,
                    30,
                )]
            }),
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);

        let invalid_signature_message_id = "20000000-0000-4000-8000-000000000003";
        let mut tampered = signed_direct_envelope(
            &sender,
            &recipient_phone,
            "recipient_net",
            invalid_signature_message_id,
            40,
        );
        tampered["ciphertext"] = Value::String(general_purpose::STANDARD.encode(vec![99_u8; 17]));
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/direct-messages",
            json!({
                "user_id": sender.user_id,
                "device_id": sender.device_id,
                "recipient": "recipient_net",
                "client_message_id": invalid_signature_message_id,
                "envelopes": [tampered]
            }),
            &sender,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        state
            .database
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET user_id = ?1 WHERE device_id = ?2",
                params!["user_dm_sender_after_link", sender.device_id],
            )
            .unwrap();
        sender.user_id = "user_dm_sender_after_link".to_string();
        let (status, _) = signed_post(
            application(state),
            "/v1/direct-messages",
            json!({
                "user_id": sender.user_id,
                "device_id": sender.device_id,
                "recipient": "recipient_net",
                "client_message_id": client_message_id,
                "envelopes": [
                    signed_direct_envelope(
                        &sender,
                        &recipient_phone,
                        "recipient_net",
                        client_message_id,
                        10,
                    ),
                    signed_direct_envelope(
                        &sender,
                        &recipient_tablet,
                        "recipient_net",
                        client_message_id,
                        20,
                    )
                ]
            }),
            &sender,
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
                "UPDATE devices SET capabilities = ?1 WHERE device_id = ?2",
                params![
                    internet_call::CAP_AUDIO | internet_call::CAP_WEBRTC,
                    callee.device_id
                ],
            )
            .unwrap();
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "client_call_id": "10000000-0000-4000-8000-000000000005",
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
        let (status, _) = signed_post(
            application(state.clone()),
            "/v1/calls",
            json!({
                "client_call_id": "10000000-0000-4000-8000-000000000006",
                "callee": "stale_net",
                "caller_user_id": caller.user_id,
                "caller_device_id": caller.device_id,
                "audio": true,
                "video": false
            }),
            &caller,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
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
                "client_call_id": "10000000-0000-4000-8000-000000000004",
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
