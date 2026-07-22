# Multi-device owner identity

## Decision

TRI-NET uses three separate identity layers:

1. An account is the stable owner identity.
2. One globally unique nickname belongs to the account.
3. Every app installation is a separately keyed and separately revocable device.

A password and a device private key are never copied between devices. This is
important for both Internet and mesh operation: losing one iPhone must allow
that iPhone to be revoked without changing every other device key.

For production account recovery and sign-in, the preferred credential is a
passkey. Apple passkeys use public-key credentials, user verification, and
iCloud Keychain synchronization. Native passkey support requires a stable HTTPS
relying-party domain, an Apple associated-domain entitlement, and WebAuthn
challenge verification on the server. The local development deployment does
not have that domain, so the currently operational bootstrap is trusted-device
approval with a one-time link code.

Primary references:

- Apple passkeys: <https://developer.apple.com/passkeys/>
- Apple passkey integration: <https://developer.apple.com/documentation/authenticationservices/supporting-passkeys>
- W3C WebAuthn Level 3: <https://www.w3.org/TR/webauthn-3/>
- Apple Secure Enclave keys: <https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>
- Apple multi-device PushKit tokens: <https://developer.apple.com/documentation/pushkit/supporting-pushkit-notifications-in-your-app>
- MLS for future durable group chat: <https://www.rfc-editor.org/rfc/rfc9420.html>

## Implemented behavior

- A first installation creates an account and a device P-256 signing key.
- The device key remains in the device Keychain and is not synchronized.
- A nickname claim is account-owned. Linked devices share the same nickname.
- A trusted device can create a 128-bit, single-use link code valid for ten
  minutes. Only a signed request from that trusted device can create it.
- A new device signs its own link request. Linking changes its account ID but
  preserves its independent key and device ID.
- Linking a previous single-device account relinquishes its previous nickname.
  An account with multiple devices cannot be silently merged into another one.
- Settings on iOS and macOS show the account ID, nickname, device list, link
  controls, and per-device revocation.
- Calls target an account and fan out to every active WebRTC device. The first
  device to accept wins an immediate SQLite transaction; all other targets are
  marked ended and cannot join the room.
- Search returns one account result even when that account has several devices.
- Revoked devices cannot authenticate, receive new call targets, or retain a
  PushKit token. The final active device cannot be revoked through this flow.
- Mesh advertisements may contain the same nickname on several devices only
  when their signed account ID is the same.

## User flow

1. Configure the same Directory API URL on the iPhone and Mac.
2. On the device whose nickname should be kept, open Settings, choose
   `Create One-Time Code`, and copy the displayed code.
3. On the other device, paste it into `link_... from trusted device` and choose
   `Link This Device` or `Link This Mac`.
4. Both devices now display the same account ID and nickname but different
   device IDs and key fingerprints.
5. A call to that nickname rings every active device. Answering on one prevents
   all other devices from joining that call.

Linking requires access to the authoritative Directory API. After provisioning,
the account ID and device key are cached locally, so signed local/mesh discovery
and calls continue without the Internet when a valid mesh route is available.

## Production completion gates

The following require deployment credentials or infrastructure and are not
simulated by the client:

- Public HTTPS API and WSS LiveKit/TURN endpoints.
- A production domain and `webcredentials` associated-domain file for passkeys.
- Server-side WebAuthn registration, assertion, recovery, and credential
  revocation endpoints.
- APNs VoIP signing credentials. PushKit must store a separate token for every
  device and CallKit must be notified immediately for each incoming VoIP push.
- Durable asynchronous chat. The current chat channel is call-scoped. A future
  durable store should use client-generated message IDs, idempotent submission,
  server sequence numbers, per-device acknowledgements, and encrypted envelopes
  for every active device. MLS (RFC 9420) is the preferred standards direction
  for multi-device group encryption, forward secrecy, and post-compromise
  security.

## Why not a shared login and password

A shared password is phishable, can be reused, and does not identify which
device performed an action. A synchronized passkey is the best user credential
for the owner, while independent device keys provide device-level audit and
revocation. The two roles complement each other: the passkey proves the person;
the device key proves the installed endpoint for every call, mesh invite, and
API request.
