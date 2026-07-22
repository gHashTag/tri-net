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

Run one API replica while SQLite is used. A multi-replica deployment should
replace the persistence adapter with PostgreSQL while preserving the atomic
nickname transaction and nonce uniqueness constraints.

Build the container from the repository root:

```console
docker build -f services/call-api/Dockerfile -t trinet-call-api .
```

Terminate public TLS at the hosting platform or a reverse proxy and expose
only HTTPS to clients. Keep the LiveKit API secret server-side.
