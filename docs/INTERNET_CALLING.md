# Internet Calling

Multi-device owner identity, trusted-device linking, and first-answer-wins call
fan-out are documented in [MULTI_DEVICE_IDENTITY.md](MULTI_DEVICE_IDENTITY.md).

TRI-NET uses two media transports behind one call UI:

- Local/Mesh UDP mode keeps the direct encrypted UDP/radio path.
- Internet mode uses LiveKit WebRTC for ICE, TURN, congestion control, audio,
  video, and reliable call data.
- Auto mode uses an explicit mesh peer when one is selected and otherwise uses
  the internet contact directory. Automatic peer discovery is a separate mesh
  service and is not inferred from a display name.

The display name, such as `ssd26`, is not a security identity. Each installation
creates a random user ID, a random device ID, and a P-256 signing key. The
private key stays in the Apple Keychain and is marked as non-migrating. The
public key and its SHA-256 fingerprint are registered with the call service.

## Development connection

The iOS and macOS settings screens support a direct LiveKit mode. Create a room
token for the same room and configure both peers with:

- LiveKit URL: `wss://...`
- Development room token: a short-lived token with room join, publish, and
  subscribe grants

The app skips the directory and push API in this mode. Use distinct participant
identities in tokens. Static or long-lived room tokens are development-only.

For Xcode builds, the same values can be supplied through these build settings:

- `TRINET_LIVEKIT_URL`
- `TRINET_DEVELOPMENT_ROOM_TOKEN`
- `TRINET_API_BASE_URL`
- `TRINET_SERVICE_ACCESS_TOKEN`

Do not commit real tokens to the project or an Info.plist file.

For a same-LAN development test, run LiveKit in development mode bound to all
interfaces, create two short-lived tokens for the same room with distinct
participant identities, and save one token on each client. A local endpoint can
use `ws://host.local:7880`; production endpoints must use TLS (`wss://`). This
test validates WebRTC signaling and media, but it does not provide production
contact lookup, remote ringing, or APNs delivery.

## Production API

The client currently consumes this HTTPS API:

Nickname creation and contact lookup use the companion endpoints documented in
`NICKNAME_DIRECTORY.md`. Call creation accepts a normalized nickname in the
`callee` field; the service resolves it to the registered destination devices.
The originating account must first own an atomically claimed nickname. That
exact verified nickname is stored as the caller identity, placed in the
callee's incoming-call payload, and used as the LiveKit participant label;
device display names are never substituted for it.
Directory lookup is exact-only: the service returns zero or one account summary
and never returns substring, prefix, or nickname-catalog results. A query that
does not normalize to a valid complete nickname returns `400 Bad Request`.

### Register a device

`POST /v1/devices/register`

The JSON body contains `user_id`, `device_id`, `display_name`,
`signing_public_key`, `key_fingerprint`, `platform`, `voip_push_token`,
`alert_push_token`, `push_environment`, and `capabilities`. A client that can
receive end-to-end encrypted direct messages also registers its independent
`text_encryption_public_key`; see [E2EE_DIRECT_MESSAGES.md](E2EE_DIRECT_MESSAGES.md).
Display labels are trimmed and bounded. An empty label or a raw IPv4/IPv6
address is stored and presented as `TRI-NET peer`, so an incoming call never
uses a network address as the caller's visible identity.

### Start a call

`POST /v1/calls`

The signed JSON body is:

```json
{
  "client_call_id": "09afb17e-af72-455b-8599-8f99c6c6912d",
  "callee": "alice_net",
  "caller_user_id": "opaque-user-id",
  "caller_device_id": "opaque-device-id",
  "audio": true,
  "video": true
}
```

`client_call_id` is a client-generated UUID and is required. It is an
idempotency key scoped to the exact originating device. Repeating a request
with the same normalized callee and the same audio/video intent never creates a
second call or sends a second ring. A retry returns another short-lived session
only while the invitation is still fresh and `ringing`, or while that call is
`active`. A retry after expiry or any terminal state returns `409 Conflict`
with `call_id`, the current `status`, and a `reason`, and does not mint another
LiveKit token. Reusing the UUID with different call intent also returns
`409 Conflict`.

At least one of `audio` or `video` must be true. The originating device must
advertise Internet audio/WebRTC capability, and a request with `video: true`
also requires video capability. A destination device is selected only when it
supports the requested media; an audio-only device is never targeted by a
video call. A target device is also excluded while it is participating in a
fresh ringing or active call, including when that device originated the other
call. If no eligible destination device remains, creation returns
`409 Conflict` instead of presenting overlapping call UI.

The response is:

```json
{
  "call_id": "opaque-call-id",
  "room_id": "opaque-room-id",
  "livekit_url": "wss://livekit.example.net",
  "token": "short-lived-participant-token",
  "media_key": null
}
```

The service resolves `callee`, sends a VoIP push to the callee devices, and
returns a participant-scoped LiveKit token. The token should expire in no more
than five minutes and grant access to one room only.

### Answer a call

`POST /v1/calls/{call_id}/join`

The JSON body contains `user_id` and `device_id`; the response has the same
shape as the start-call response. Only the exact device recorded as a target
may answer. The first successful answer atomically changes the call to
`active`; every other target becomes `ended` and cannot join the room. Retrying
the answer on the device that already won returns the same session, while a
different target cannot reuse it.

### Decline on one callee device

`POST /v1/calls/{call_id}/decline`

```json
{
  "user_id": "callee-user-id",
  "device_id": "exact-target-device-id"
}
```

Only the authenticated target device can decline its own invitation. A linked
device cannot decline on another device's behalf. Declining one target leaves
the call `ringing` while another target can still answer; the final target
decline changes the call to `declined`. Repeating the same decline is
idempotent and returns the current call status.

### Read call status

`POST /v1/calls/{call_id}/status`

The body contains the authenticated `user_id` and `device_id`. Access is
limited to the exact originating caller device and exact callee target devices;
another device linked to either account does not gain access automatically.

```json
{
  "call_id": "opaque-call-id",
  "call_uuid": "b5afbcb6-2c2c-4e46-a86e-7e5444aa5b62",
  "status": "ringing",
  "role": "callee",
  "target_status": "declined",
  "answered_here": false,
  "created_at": 1787360000,
  "answered_at": null,
  "ended_at": null
}
```

Global `status` values are `ringing`, `active`, `ended`, `declined`,
`cancelled`, and `missed`. A stale ringing invitation becomes `missed` when a
join or status operation observes that its invitation lifetime has expired.
`target_status` is `null` for the caller and reports the per-device state for a
callee target.

### End an established call

`POST /v1/calls/{call_id}/end`

The body contains `user_id` and `device_id`. For an `active` call, either the
exact originating caller device or the exact callee device that won the answer
race may end the session. Other linked devices are not authorized. The call and
all target records become `ended`, and the response is the call-status JSON
shown above. Retrying from either authorized participant after that transition
is idempotent and returns the ended status. After the SQLite transaction
commits, the service starts a best-effort LiveKit RoomService `DeleteRoom`
request. LiveKit documents that this operation requires `roomCreate` and
forcibly disconnects all current room participants:
<https://docs.livekit.io/reference/other/roomservice-api/#deleteroom>.
Cleanup failure is logged without credentials or room data and does not roll
back the terminal call state.

Use this endpoint for normal in-call hangup.

### Cancel before answer

`POST /v1/calls/{call_id}/cancel`

The body contains the originating caller's `user_id` and `device_id`. Only the
exact device that created the call is authorized. Cancelling while ringing
sets the global status to `cancelled`. For backward compatibility this endpoint
also lets that same originating device end an active call, but new clients use
`/end` so the answering callee has symmetric hangup authorization. A retry
after a terminal transition is a no-op. A successful response has status
`204 No Content`. The same post-commit best-effort LiveKit room cleanup runs for
authorized cancellation and its idempotent retry.

### Poll foreground incoming calls

`POST /v1/calls/incoming`

The JSON body contains `user_id` and `device_id`. The response contains a
`calls` array with `call_id`, `call_uuid`, `caller`, `audio`, `video`, and
`created_at`.
The signed foreground client polls this endpoint every three seconds and
reports a new iPhone call through CallKit. This makes development and
foreground calling work without an APNs credential. It is not a replacement
for VoIP push when the iPhone app is suspended or terminated.

## Device proof headers

Every API request is signed with the device P-256 key and includes:

- `X-TRINET-Device-ID`
- `X-TRINET-Timestamp`
- `X-TRINET-Nonce`
- `X-TRINET-Signature`

The signature is DER-encoded ECDSA, then Base64 encoded. Its canonical input is
UTF-8 text with newline separators:

```text
UPPERCASE_HTTP_METHOD
REQUEST_PATH
UNIX_TIMESTAMP_SECONDS
LOWERCASE_UUID_NONCE
LOWERCASE_HEX_SHA256_OF_EXACT_BODY
```

The service must reject timestamps outside the 60-second policy window and
must reject a nonce already used by that device. Registration is a signed
bootstrap: verify the request against the public key in its body before storing
the device record. Later requests use the stored key. An account access token
can be required in addition to this device proof.

## Incoming iPhone calls

For background delivery, configure the call service APNs provider. It sends a
VoIP push whose payload contains:

```json
{
  "call_id": "opaque-call-id",
  "call_uuid": "b5afbcb6-2c2c-4e46-a86e-7e5444aa5b62",
  "caller": "alice_net",
  "video": true
}
```

`caller` is the exact nickname atomically claimed by the originating account,
not a mutable device label. The iOS app immediately reports the call to CallKit
and joins the room only after the user answers. Production deployment requires the Push Notifications
and VoIP background capabilities, an APNs signing key, and a provisioning
profile for the application bundle identifier. See
`services/call-api/README.md` for the APNs environment variables. Foreground
polling is only a development fallback; iOS cannot wake a suspended app for a
local UDP packet.

## Call API service

The Rust service lives in `services/call-api`. It implements device
registration, atomic nickname claims, search, call creation, signed incoming
polling, authenticated decline/status/cancel operations, atomic
first-answer-wins authorization, symmetric active-call hangup for the exact
participants, replay-protected request proofs, and five-minute room-scoped
LiveKit JWTs. Call creation and successful lifecycle retries are idempotent
under the rules above.

See `services/call-api/README.md` for local execution and deployment
configuration. An arbitrary-network deployment still requires a public HTTPS
address for this API and a public `wss://` LiveKit Cloud or self-hosted
LiveKit/TURN endpoint. Local `.local` and RFC1918 addresses cannot provide that
Internet reachability.

### Remaining production lifecycle work

The implemented answer, decline, cancel, end, and expiry transitions are
durable in SQLite and visible through the authenticated status endpoint. The
service does not yet fan those later lifecycle transitions out to every target
through APNs, so a suspended linked device needs client-side status
reconciliation before it can reliably dismiss an `answered_elsewhere`,
`cancelled`, or `ended` CallKit UI. Authorized `/end` and `/cancel` requests do
start a post-commit LiveKit RoomService `DeleteRoom`, which forcibly disconnects
participants when accepted. That cleanup is best-effort rather than a durable
outbox event; an unavailable LiveKit service can therefore leave the room alive
until LiveKit's own room timeout, even though SQLite remains terminal.

Initial VoIP and direct-message alert events use a transactional SQLite outbox.
The call/message row and one unique metadata-only event per target device commit
together. A startup worker drains due events, reclaims a claim after its
process-generation owner disappears, deletes successful or terminal events,
and returns repairable failures to durable storage with capped
2-to-300-second backoff. A restarted single SQLite-backed replica gets a new
owner and can therefore reclaim an abandoned invite immediately rather than
waiting for the same-process 120-second stuck-worker lease. Eight bounded VoIP
workers run separately from the direct-message worker so an alert or another
slow invite does not serialize all fresh 30-second call invitations. API
retries do not add another event for the same object and target.
Each outbox claim performs at most one APNs HTTP request. The next transient
retry or alternate-environment check requires a new claim and therefore reloads
the authoritative call/message state, invitation age, destination token, and
read state before another request starts. A non-transient provider or
configuration response such as `Forbidden` remains durable but is blocked for
the current process generation; a corrected restart gets one fresh attempt
without an in-process retry loop.

New non-idempotent calls are admitted at no more than six per originating
device per minute and two simultaneous fresh ringing calls per device. When
APNs is configured, the transaction also refuses a new call if its target
events would raise the fresh global VoIP queue above the eight-worker delivery
capacity. An exact `client_call_id` retry is resolved before this admission
gate and therefore remains idempotent.

Token-specific terminal responses clear only the exact token registration that
APNs rejected. The service stores per-token registration time and compares the
millisecond timestamp from a `410` response, so a later registration of even
the same token string is preserved. If registration rotated while delivery was
in flight, the conditional invalidation changes no row and the event is
retained for immediate delivery through the current token.
`ExpiredProviderToken` clears the cached provider JWT before retry; repairable
provider configuration errors remain durable for a corrected service restart.

Delivery is intentionally at least once. A process failure after APNs accepts a
push but before SQLite records acknowledgement can cause a resend after claim
recovery. Clients must continue deduplicating call invitations by authenticated
`call_id`; direct-message clients fetch the idempotent inbox rather than treating
the notification as message content.

## Security boundary

WebRTC media is encrypted in transit. If `media_key` is present, the client also
enables LiveKit frame encryption. A production service should distribute a
per-call media key encrypted separately to each registered device; returning a
plain shared key from a trusted API is only an integration stage, not a
server-blind end-to-end key exchange.

The `.t27` source of truth for routing, token freshness, device validity, and
call lifecycle is `specs/internet_call.t27`.

Durable one-to-one text messages use a separate server-blind encrypted envelope
contract documented in [E2EE_DIRECT_MESSAGES.md](E2EE_DIRECT_MESSAGES.md). The
server stores ciphertext, nonces, routing metadata, key fingerprints, and
sender signatures; it does not store message plaintext.
