# End-to-end encrypted direct messages

This document defines the server transport contract for durable one-to-one
messages addressed by exact normalized nickname. The call API is a
server-blind mailbox: it resolves devices, validates routing and signatures,
stores opaque encrypted envelopes, tracks read cursors, and sends metadata-only
alerts. The API has no plaintext-message field and the service never decrypts
the submitted `ciphertext` bytes.

These endpoints do not make an Apple client message-capable by themselves. A
client must generate and protect its X25519 private key, encrypt and decrypt
each message locally, and verify the sender signature before displaying any
plaintext.

The policy source of truth is `specs/direct_message.t27`. Device proof headers
and nickname rules are documented in [INTERNET_CALLING.md](INTERNET_CALLING.md)
and [NICKNAME_DIRECTORY.md](NICKNAME_DIRECTORY.md).

## Device encryption key registration

`POST /v1/devices/register` accepts an optional
`text_encryption_public_key` in addition to the device P-256 signing key. The
value is the Base64 encoding of a raw, nonzero 32-byte X25519 public key. A
device without a valid text-encryption key cannot receive a direct-message
envelope.

The X25519 key is independent from the P-256 key used to authenticate HTTP
requests and sign envelopes. The recipient-resolution response binds each
device ID to a `text_encryption_key_fingerprint`, defined as the lowercase hex
encoding of the first 12 bytes of SHA-256 over the raw X25519 public key. The
sender must echo that 24-character fingerprint in its envelope so a key
rotation cannot silently redirect a message to stale key material.

This is a server-blind storage and transport contract under an authenticated,
honest-directory assumption. The current response does not carry a
recipient-generated P-256 signature over the X25519 key and has no key
transparency or out-of-band safety-number check. A compromised service or
database could therefore substitute a recipient key and intercept future
messages. Resistance to that threat requires a recipient-signed key binding,
client key pinning and rotation rules, and preferably an auditable transparency
log or user-verifiable safety numbers; those mechanisms are not implemented by
this backend contract.

## Resolve every recipient device

`POST /v1/direct-messages/recipients`

```json
{
  "user_id": "sender-user-id",
  "device_id": "sender-device-id",
  "nickname": "alice_net"
}
```

The request uses exact normalized nickname lookup. The response identifies the
recipient account and lists every active destination device with its device ID,
X25519 public key, and `text_encryption_key_fingerprint`. Sending is rejected
unless the submitted envelope set contains each listed device exactly once.
This all-device fan-out is required because linked devices have independent
private keys. The sender must already own a verified nickname, self-messages
are rejected, and resolution succeeds only when all 1 through 32 active
recipient devices have registered text-encryption keys.

```json
{
  "crypto_version": 1,
  "nickname": "alice_net",
  "user_id": "recipient-user-id",
  "devices": [
    {
      "device_id": "recipient-device-id",
      "text_encryption_public_key": "base64-raw-x25519-public-key",
      "text_encryption_key_fingerprint": "sha256-fingerprint",
      "key_fingerprint": "p256-signing-key-fingerprint"
    }
  ]
}
```

Resolve the recipient immediately before encryption. If a destination key is
rotated between resolution and send, the send operation rejects the stale
fingerprint and the client must resolve and encrypt again.

## Send encrypted envelopes

`POST /v1/direct-messages`

```json
{
  "user_id": "sender-user-id",
  "device_id": "sender-device-id",
  "recipient": "alice_net",
  "client_message_id": "63ba0be3-542e-4c59-903c-85e5634969e0",
  "envelopes": [
    {
      "crypto_version": 1,
      "recipient_device_id": "recipient-device-id",
      "recipient_key_fingerprint": "sha256-fingerprint",
      "ephemeral_public_key": "base64-raw-x25519-public-key",
      "nonce": "base64-12-byte-nonce",
      "ciphertext": "base64-ciphertext-and-authentication-tag",
      "sender_signature": "base64-p256-der-signature"
    }
  ]
}
```

`crypto_version` must be `1`; unknown versions are rejected.
`client_message_id` is a client-generated UUID and is the idempotency key for
the exact sending device. Repeating the same message intent returns the stored
message without inserting another row or sending another APNs alert. Reusing
the UUID with a different recipient, destination-device/key set, ephemeral
public key, crypto version, nonce, or ciphertext is rejected. A retry signature
may have different DER bytes, but it must still verify against the registered
sender key.

If trusted-device linking moves that physical device to another account, its
old `client_message_id` values remain owned by the original sender account and
cannot be resumed from the new account.

The response contains `message_id`, normalized `client_message_id`,
`recipient_user_id`, normalized `recipient_nickname`, `created_at`, and an
`inserted` flag. `inserted` is `false` for an idempotent retry.

Every envelope contains a nonzero raw 32-byte ephemeral X25519 public key, a
12-byte nonce, and ciphertext that includes a 16-byte authentication tag. The
supported plaintext size is 1 through 4,096 bytes, so ciphertext is 17 through
4,112 bytes. The server validates sizes and the sender signature but cannot
decrypt the payload or prove that a noncompliant client did not place plaintext
bytes in the `ciphertext` field.

### Version 1 encryption profile

For each recipient device, generate a fresh ephemeral X25519 key pair and
derive the shared secret with that device's registered static X25519 public
key. The recipient derives the same secret from its static private key and the
stored ephemeral public key. Both sides must abort if X25519 produces an
all-zero shared secret.

Derive a 32-byte content key with HKDF-SHA256 using the X25519 shared secret as
input keying material and an empty salt. The HKDF `info` starts with ASCII
`TRINET-DIRECT-MESSAGE-KEY-V1`, followed by each field as a four-byte unsigned
big-endian length and the raw field bytes in this order:

1. sender user ID as UTF-8
2. sender device ID as UTF-8
3. normalized recipient nickname as UTF-8
4. `crypto_version` as one raw byte (`0x01`)
5. recipient device ID as UTF-8
6. recipient X25519 key fingerprint as lowercase UTF-8
7. normalized lowercase `client_message_id` UUID as UTF-8
8. raw ephemeral X25519 public key

Encrypt with ChaCha20-Poly1305 and a fresh random 12-byte nonce. The associated
data starts with ASCII `TRINET-DIRECT-MESSAGE-AAD-V1`, followed by the same
length-prefixed fields as the HKDF `info`, then the raw nonce as another
length-prefixed field. Store the nonce separately. The `ciphertext` field is
the encrypted bytes followed by the 16-byte Poly1305 tag and does not include
the nonce.

The sender signs this binary canonical value with ECDSA P-256 and SHA-256 using
its registered device key, and encodes the resulting DER signature in Base64.
Start with the unprefixed ASCII domain `TRINET-DIRECT-MESSAGE-V1`, then append
every field below as a four-byte unsigned big-endian length followed by the raw
field bytes, in this exact order:

1. sender user ID as UTF-8
2. sender device ID as UTF-8
3. normalized recipient nickname as UTF-8
4. `crypto_version` as one raw byte (`0x01`)
5. recipient device ID as UTF-8
6. recipient X25519 key fingerprint as lowercase UTF-8
7. normalized lowercase `client_message_id` UUID as UTF-8
8. raw ephemeral X25519 public key
9. raw nonce
10. raw ciphertext followed by its authentication tag

Length-prefixing prevents ambiguous concatenation. A receiver must reconstruct
the same bytes and verify `sender_signature` against the returned sender
`sender_signing_public_key` and `sender_key_fingerprint` before attempting
decryption.

## Fetch a device inbox

`POST /v1/direct-messages/inbox`

```json
{
  "user_id": "recipient-user-id",
  "device_id": "exact-recipient-device-id",
  "after_message_id": 0,
  "limit": 100
}
```

The signed request returns only envelopes addressed to the exact authenticated
device. Each item includes the opaque envelope fields, sender nickname and
identity metadata, sender P-256 signing public key and fingerprint, creation
time, `crypto_version`, and read state. `after_message_id` is an exclusive
server cursor. The page size is clamped to 1 through 100, and the response
includes the exact device's current direct-message unread count under the
shared account read cursors.

The service returns ciphertext unchanged. Decryption and signature validation
remain client responsibilities; a client must not display content when either
operation fails.

## Advance the read cursor

`POST /v1/direct-messages/read`

```json
{
  "user_id": "recipient-user-id",
  "device_id": "recipient-device-id",
  "sender_user_id": "sender-user-id",
  "through_message_id": 42
}
```

The service selects the greatest existing message ID at or below
`through_message_id` that came from the specified sender and has an envelope
for the exact authenticated device. The per-peer cursor only moves forward;
replaying an older read request cannot make messages unread again. Read state
is account-scoped so linked recipient devices converge on the same cursor. The
response contains `last_read_message_id` and `total_unread_count`.

## Storage and notification boundary

SQLite stores message IDs, sender and recipient routing identifiers, normalized
nickname metadata, recipient key fingerprints, ephemeral public keys, nonces,
ciphertext, timestamps, and sender signatures. Its direct-message schema has no
plaintext column and the service does not create a decrypted message copy.
This property does not by itself protect message metadata, prevent directory
key substitution, or prove that a client actually encrypted the submitted
opaque bytes.

For a newly inserted message, the service may send a standard APNs alert to
eligible recipient devices. The alert contains routing metadata needed to fetch
the inbox, `type: direct_message`, `sender_user_id`, the normalized
`sender_nickname`, a generic sender notification, and the system `default`
sound; it does not contain plaintext or ciphertext. The metadata-only outbox
payload is stored in the same SQLite transaction as the ciphertext envelopes.
An idempotent retry does not schedule another alert.

The dedicated direct-message worker uses per-device unique events, a
process-generation claim owner, and capped retry metadata. A restarted single
SQLite-backed replica reclaims abandoned work immediately. Success acknowledges
and deletes the event. Each claim makes at most one APNs HTTP request, so a
durable retry rechecks message age, unread state, newer pending alerts, and the
current token before sending again. Non-transient provider/configuration
failures remain stored with bounded diagnostics but are blocked until a new
process generation loads corrected configuration. If registration rotates a token during delivery, a
failed conditional invalidation retains the event for the current token. APNs
`410` invalidation also compares its millisecond timestamp with the exact
token's registration time, preserving a later re-registration of the same
token string. Alerts older than one hour, messages already marked read by any
linked device, and older same-sender per-device events when a newer event is
pending are suppressed. The surviving generic alert uses the original
message's absolute one-hour APNs expiration and causes the client to fetch the
full idempotent inbox.
Delivery is at least once because a process can stop after APNs accepts a
request but before the acknowledgement transaction deletes its event.

APNs is optional at service startup. This repository does not demonstrate a
live public APNs provider, background wakeup, or Internet deployment; those
remain physical-device and production-infrastructure validation gates.

The server-side policy and storage contract do not prove live client
interoperability. A successful two-device test must still show that
independently implemented clients derive the same key, validate the P-256
signature, decrypt the ChaCha20-Poly1305 payload, reject tampering, and recover
after a recipient X25519 key rotation.
