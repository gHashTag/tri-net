# Nickname Directory

TRI-NET resolves human-readable nicknames to stable cryptographic device
identities. A nickname is never used as the security identity itself.

## Nickname rules

- 3 to 20 characters
- lowercase ASCII letters, decimal digits, and underscore
- the first character must be a letter
- exact normalized collisions are rejected
- edit distance 1 is rejected as a near-copy
- edit distance 2 is rejected when at least four prefix characters match

Restricting the alphabet removes Unicode homograph ambiguity. The authoritative
service performs normalization, similarity checks, and the unique database
insert in one atomic claim operation. Client checks are only early feedback.

## Claim levels

- `verified`: the internet registry has atomically reserved the nickname for the
  signed user and device identity.
- `mesh-local`: the nickname does not conflict with currently reachable signed
  mesh peers, but has not been checked against the global registry.

A disconnected network partition cannot mathematically guarantee global
uniqueness. A mesh-local claim is therefore provisional and must be reconciled
when the internet registry becomes reachable.

## Internet API

Every request uses the device-proof headers defined in `INTERNET_CALLING.md`.

### Atomic claim

`POST /v1/directory/nicknames/claim`

```json
{
  "nickname": "alice_net",
  "user_id": "opaque-user-id",
  "device_id": "opaque-device-id"
}
```

Accepted response:

```json
{
  "claimed": true,
  "normalized": "alice_net",
  "reason": null,
  "suggestions": []
}
```

Rejected response:

```json
{
  "claimed": false,
  "normalized": "alice",
  "reason": "Nickname is already used or too similar",
  "suggestions": ["alice_net384", "alice_mesh421", "alice_tri458"]
}
```

The service must not implement availability check and reservation as separate
operations. A unique index on the normalized nickname and one atomic claim
transaction prevent a race between two clients.

### Search

`POST /v1/directory/search`

```json
{
  "query": "alice",
  "limit": 20
}
```

The response contains `results` with `user_id`, `device_id`, `nickname`,
`display_name`, `key_fingerprint`, and `online`. Search should prefer exact and
prefix matches and must not expose private profile data.

## Local and routed-mesh discovery

Apple clients advertise `_trinet-call._udp` through Bonjour. Each TXT record
contains the normalized nickname, display label, user ID, device ID, public
key, fingerprint, and a P-256 signature. Bonjour advertises UDP port 7001 for
signed call invitations; encrypted media uses UDP port 7000. The directory
signature input is:

```text
NORMALIZED_NICKNAME
USER_ID
DEVICE_ID
UDP_PORT
```

Unsigned, malformed, or invalid cards are ignored. A selected mesh result is
resolved to its current IPv4 address. The caller then sends a short-lived,
P-256-signed invitation with a one-time nonce. The receiver rings only when the
embedded public key, fingerprint, device identity, and signature agree. Prior
Bonjour visibility is not required to accept a valid invitation, which allows
a routed mesh peer with a known address to ring through multiple hops.
Replayed, expired, self-originated, or forged invitations are rejected. Media
starts on UDP port 7000 only after the recipient accepts and a fresh
authenticated media handshake completes.

After a valid Bonjour resolution, the adapter caches the signed peer identity
and last usable address for at most seven days. This lets nickname routing keep
working while iOS temporarily suspends Bonjour publication. The media
handshake remains authoritative, so a stale or redirected address cannot
establish a secure session as another device.

Bonjour on one Wi-Fi or hotspot segment is the bootstrap discovery mechanism,
not proof of a radio mesh route. A routed radio mesh can use a cached nickname
route or a direct routed IPv4 address; distributing a brand-new nickname
between isolated segments still requires mDNS relay or an equivalent signed
directory gossip service. Product UI uses `Local/Mesh UDP` until node telemetry
can prove the selected route.

The source-of-truth policy is `specs/nickname_directory.t27`.
