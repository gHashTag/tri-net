# TRI-NET Call API

This service is the signed Internet directory and call-signaling adapter for
the Apple clients. The policy remains in `specs/internet_call.t27`,
`specs/nickname_directory.t27`, `specs/account_identity.t27`, and
`specs/group_chat.t27`; this crate provides HTTP, P-256 proof verification,
replay protection, SQLite transactions, persistent account-level group chat,
and short-lived room-scoped LiveKit tokens.

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
call fan-out with first-answer-wins semantics, group membership, idempotent
messages, recipient authorization, and room-token issuance.

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
`BadDeviceToken` response is checked once against the other endpoint before
the exact token is invalidated, and transient network, `429`, and `5xx`
failures receive a short bounded retry.

Run one API replica while SQLite is used. A multi-replica deployment should
replace the persistence adapter with PostgreSQL while preserving the atomic
nickname transaction and nonce uniqueness constraints.

Build the container from the repository root:

```console
docker build -f services/call-api/Dockerfile -t trinet-call-api .
```

Terminate public TLS at the hosting platform or a reverse proxy and expose
only HTTPS to clients. Keep the LiveKit API secret server-side.
