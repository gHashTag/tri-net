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

### Register a device

`POST /v1/devices/register`

The JSON body contains `user_id`, `device_id`, `display_name`,
`signing_public_key`, `key_fingerprint`, `platform`, `voip_push_token`, and
`capabilities`.

### Start a call

`POST /v1/calls`

The JSON body contains `callee`, `caller_user_id`, `caller_device_id`, `audio`,
and `video`. The response is:

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
shape as the start-call response.

### Poll foreground incoming calls

`POST /v1/calls/incoming`

The JSON body contains `user_id` and `device_id`. The response contains a
`calls` array with `call_id`, `caller`, `audio`, `video`, and `created_at`.
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

For background production delivery, the deployment must add an APNs adapter
that sends a VoIP push whose payload contains:

```json
{
  "call_id": "opaque-call-id",
  "call_uuid": "b5afbcb6-2c2c-4e46-a86e-7e5444aa5b62",
  "caller_name": "Alice",
  "video": true
}
```

The iOS app immediately reports the call to CallKit and joins the room only
after the user answers. Production deployment requires the Push Notifications
and VoIP background capabilities, an APNs signing key, and a provisioning
profile for the application bundle identifier.

## Call API service

The Rust service lives in `services/call-api`. It implements device
registration, atomic nickname claims, search, call creation, signed incoming
polling, recipient-only join authorization, replay-protected request proofs,
and five-minute room-scoped LiveKit JWTs. Its isolated test covers the complete
nickname-to-call signaling flow with two generated P-256 identities.

See `services/call-api/README.md` for local execution and deployment
configuration. An arbitrary-network deployment still requires a public HTTPS
address for this API and a public `wss://` LiveKit Cloud or self-hosted
LiveKit/TURN endpoint. Local `.local` and RFC1918 addresses cannot provide that
Internet reachability.

## Security boundary

WebRTC media is encrypted in transit. If `media_key` is present, the client also
enables LiveKit frame encryption. A production service should distribute a
per-call media key encrypted separately to each registered device; returning a
plain shared key from a trusted API is only an integration stage, not a
server-blind end-to-end key exchange.

The `.t27` source of truth for routing, token freshness, device validity, and
call lifecycle is `specs/internet_call.t27`.
