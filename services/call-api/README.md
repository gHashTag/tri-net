# TRI-NET Call API

This service is the signed Internet directory and call-signaling adapter for
the Apple clients. The policy remains in `specs/internet_call.t27`,
`specs/direct_message.t27`, `specs/nickname_directory.t27`,
`specs/account_identity.t27`, and `specs/group_chat.t27`; this crate provides
HTTP, P-256 proof verification, replay protection, SQLite transactions,
persistent account-level chat, and short-lived room-scoped LiveKit tokens.
Directory lookup is exact-only and returns at most one account summary; partial
nickname catalog enumeration is not exposed.

## Run locally

Start LiveKit first, then run:

```console
TRINET_BIND=127.0.0.1:8080 \
TRINET_DB_PATH=/tmp/trinet-call.sqlite \
TRINET_LIVEKIT_URL=ws://127.0.0.1:7880 \
LIVEKIT_API_KEY=devkey \
LIVEKIT_API_SECRET=secret \
cargo run --manifest-path services/call-api/Cargo.toml
```

The `devkey` and `secret` values are only for a local LiveKit server started
in development mode. Never use them on a reachable host.

Run the isolated service tests with:

```console
cargo test --manifest-path services/call-api/Cargo.toml --locked
```

The end-to-end tests create independent P-256 device identities and exercise
signed registration, atomic nickname claims, account linking, online presence,
idempotent call creation, call fan-out with first-answer-wins semantics,
authenticated decline/status/cancel/end operations, group membership,
idempotent messages, recipient authorization, and room-token issuance.

## Required production configuration

- `TRINET_BIND`: listener address, normally `0.0.0.0:8080`
- `TRINET_DB_PATH`: durable SQLite path mounted on persistent storage
- `TRINET_LIVEKIT_URL`: public `wss://` LiveKit endpoint
- `LIVEKIT_API_KEY`: LiveKit server API key
- `LIVEKIT_API_SECRET`: LiveKit server API secret
- `TRINET_SERVICE_ACCESS_TOKEN`: optional second factor shared by approved app
  builds; device P-256 signatures remain mandatory
- `TRINET_APNS_TEAM_ID`: Apple Developer team ID for the APNs provider key
- `TRINET_APNS_KEY_ID`: key ID printed when the APNs `.p8` key is created
- `TRINET_APNS_PRIVATE_KEY_PATH`: absolute path to the mode-0600 APNs `.p8` key
- `TRINET_APNS_BUNDLE_ID`: app bundle ID, normally `com.trinet.video`
- `TRINET_APNS_ENVIRONMENT`: fallback only when an older device registration
  has no environment; use `sandbox` for development builds

APNs is optional at process startup so foreground LAN development keeps
working without Apple credentials. It is required for calls to suspended or
terminated iPhones and for background chat notifications. The server routes
each registered token to its saved sandbox or production endpoint. A
`BadDeviceToken` response schedules one durable check against the other endpoint
on a new claim before the exact token registration is invalidated. Per-token registration timestamps
are compared with APNs `410` timestamps, so rotation or later re-registration
during an in-flight request retains the event for the current token. Each outbox
claim performs at most one APNs HTTP request. Transient network, `429`, and
`5xx` failures receive a capped durable retry after the worker revalidates the
current call/message state, and an expired provider JWT is evicted before retry.
Non-transient provider/configuration failures remain durable but are blocked
for the current process generation, preventing a tight loop; a corrected
service restart gets one fresh attempt and retains the recorded APNs reason and
status without logging tokens or payloads.

Initial call invitations and direct-message alerts are persisted as unique
per-device events in the same SQLite transaction as the call or encrypted
message. Eight bounded VoIP workers and a separate direct-message worker drain
pending events. A per-start process-generation owner lets a restarted single
SQLite replica reclaim abandoned work immediately; the 120-second lease is a
same-process stuck-worker fallback. Workers delete acknowledged/terminal
events and apply capped durable backoff to repairable failures. Delivery is at
least once, so clients still deduplicate authenticated call IDs and fetch
messages from the idempotent inbox. Direct-message alerts are coalesced within
the same sender to the newest pending event per device and suppressed after
account-wide read or one hour of age.

New calls are limited per authenticated originating device to six per minute
and two simultaneous fresh ringing calls. With APNs enabled, admission also
keeps the global fresh VoIP event count within the eight-worker pool. Exact
`client_call_id` retries are checked before this gate and are not duplicated.

`POST /v1/calls` requires a caller-generated `client_call_id` UUID. The key is
scoped to the exact caller device: an identical retry never creates another
call or ring. It returns a new short-lived media session only for a fresh
`ringing` call or an `active` call; an expired or terminal retry returns
`409 Conflict` without a token. Reuse with a different normalized callee or
audio/video intent also returns `409 Conflict`. The caller account must own an
atomically claimed nickname; that exact nickname is used for the incoming-call
identity and both LiveKit participant labels instead of the mutable device
display name. Video calls target only devices
that advertise video plus Internet audio/WebRTC capability. The exact
originating device can inspect status and cancel; an exact callee target can
inspect status, answer, or decline. One target decline does not prevent another
linked target from answering, and the first successful answer wins atomically.
Devices already participating in a fresh ringing or active call, as either a
target or the originating device, are excluded from new call fan-out.
For an active call,
`POST /v1/calls/{call_id}/end` authorizes only the exact originating caller and
the exact callee device that answered; either participant can retry an ended
call idempotently. After the terminal SQLite transaction commits, `/end` and
`/cancel` start a best-effort LiveKit RoomService `DeleteRoom` request with a
short-lived `roomCreate` grant. This forcibly disconnects participants when
LiveKit accepts it, while a cleanup failure never rolls back the committed call
state or changes the endpoint response.

The durable direct-message endpoints accept per-device encrypted envelopes,
not plaintext. Recipient devices register an X25519 public key, clients encrypt
and sign one envelope for every active destination device, and the service
persists only ciphertext, nonce, routing metadata, key fingerprints, and sender
signatures. Crypto version 1 uses ephemeral X25519, HKDF-SHA256, and
ChaCha20-Poly1305. Alert pushes contain sender/message metadata and never
message plaintext; they request the system `default` sound. The current
directory response is not a recipient-signed or transparent key directory, so
the documented malicious-directory limitation still applies. The full
client/server contract is documented in
[`docs/E2EE_DIRECT_MESSAGES.md`](../../docs/E2EE_DIRECT_MESSAGES.md).

Run one API replica while SQLite is used. A multi-replica deployment should
replace the persistence adapter with PostgreSQL while preserving the atomic
nickname transaction and nonce uniqueness constraints.

Build the container from the repository root:

```console
docker build -f services/call-api/Dockerfile -t trinet-call-api .
```

Terminate public TLS at the hosting platform or a reverse proxy and expose
only HTTPS to clients. Keep the LiveKit API secret server-side.

The repository configuration and tests do not prove that a public deployment,
APNs delivery, or background wakeup is live. Those checks require the actual
public HTTPS/WSS/TURN endpoints, Apple credentials, provisioned app build, and
physical-device validation. Lifecycle transitions currently update SQLite but
do not send follow-up APNs events. LiveKit room deletion on `/end` and `/cancel`
is best-effort and not itself stored in a durable retry queue, so production
must still monitor cleanup failures.
