# TRI-NET phone — the last state where calling worked, for two-phone testing

**Written:** 12 August 2026. **Repo:** `github.com/gHashTag/tri-net`, branch
`feat/ring-hardening`.

You want a version whose video call is known to work, to test on two physical iPhones in
a fresh session. This is it, with the exact commit, how to run it, and — importantly —
what is wrong with it, because two of its defects are serious and you should know before
you put it on a phone.

---

## 1. The commit

```
1d425ab3  fix(nat): peer-reflexive candidates — the gap that actually breaks symmetric NAT
2026-07-24
```

This is the last `phone/` commit before the current session's UI and messenger work
began. Everything up to it is the NAT-traversal and security line; nothing after it in
`phone/` is present.

```bash
git clone https://github.com/gHashTag/tri-net.git
cd tri-net
git checkout 1d425ab3        # detached; branch it if you intend to change anything
cd phone
```

An earlier tag exists and is **not** what you want: `phone-v0.13-audio-works`
(`031cc760`) is where audio was fixed, but it predates the whole NAT stack, the device
identity, the Keychain, anti-replay and the video NACK path.

---

## 2. What that state does, and how it was verified

Established before this session, so treat these as inherited claims rather than
measurements I took:

| capability | commit that landed it |
|---|---|
| Video call iPhone ↔ Mac | pre-`v0.13` line; audio fixed at `031cc760` |
| Call across a blind rendezvous, two peers sharing only a room passphrase | `631eb03f` — "a real call establishes … the main thing works" |
| STUN, UDP hole-punch, ICE, symmetric-NAT scope | `0fbc42a7`, `b468cd2a`, `5b17ea85`, `f4864dbb`, `1d425ab3` |
| Per-device Ed25519 identity + trust-on-first-use pinning, MITM refusal | `cd9f897e` |
| Identity key in the Keychain rather than a plist | `e5a85817` |
| Anti-replay on the encrypted data path | `df55009e` |
| Crypto bound to a room passphrase, not only the hardcoded PSK | `5336194d` |
| Per-fragment NACK — video loss recovery 60% → 96% | `b369ae8c` |

What I verified myself on hardware **in the current code**, and which is the same
transport as here: Opus audio captured, encoded and transmitted at ~50 packets/s; a
server-reflexive address obtained on a real device (`srflx=182.232.227.15:15428`);
Bonjour discovery in both directions.

**Never verified end to end by me:** a complete two-phone call. Both phones were only
simultaneously available and unlocked at the very end of the session.

---

## 3. Read this before installing it — two serious defects live in this commit

I found both by reading the source in this session. They are **present at `1d425ab3`**
and were fixed afterwards. Neither is theoretical.

### 3.1 The invite is a remote camera and microphone switch

`ViewModel.swift`, in the idle listener:

```swift
if participants.count > 2 || (!room.isEmpty && room == PeerDiscovery.myRoom) {
    self.acceptIncoming()
    return
}
```

An invite carrying more than two participants — or any invite whose room matches yours —
is accepted **with no ring**. Invites are authenticated with a key derived from
`SHA256("tri-net-psk-v1")`, a constant compiled into the binary and public in this
repository, so anyone able to send a UDP datagram to port 7000 can forge one and open
the phone's camera and microphone without a tap.

I demonstrated the forgery from a Mac in Python and the phone rang, which is the same
path.

### 3.2 One packet steals the session mid-call

A handshake is honoured from **any source at any time**, and `consumeHandshake` ends in
an unconditional `sessionKey = key`. There is no check that a session already exists, nor
that the sender is the peer you are talking to. Combined with the public key above, a
third party can rebind a call in progress onto their own key.

### 3.3 Also worth knowing

`ephPriv` is a `let` on a per-process singleton — one X25519 private key for every peer
and every call in a run, under a comment reading `forward-secret`. Forward secrecy there
is per-launch, not per-call.

**If you test on this commit, do it on a network you control, and do not leave the app
running unattended.**

---

## 4. Taking the fixes without the rest

The security work is one commit and applies cleanly on its own:

```bash
git cherry-pick bdbce0b0   # security: close the remote camera switch and the session hijack
```

It removes auto-accept entirely (every invite rings), accepts a handshake only when no
session exists or from the peer already handshaked with, makes the ephemeral key
per-call, and adds `resetSession()` on disconnect.

**One caveat, and it is the reason it is a separate decision.** The unconditional
handshake overwrite that fix removes was *load-bearing*: `crypto` is a per-process
singleton and `disconnect()` never cleared it, so the **second call in one app session**
worked only because the assignment overwrote stale state. With the fix, `disconnect()`
clears the session — and **that path is untested**. If a second call fails to establish
after cherry-picking, that is where to look, and the reset is correct; the old behaviour
was the vulnerability.

---

## 5. Building and installing on two phones

Signing is automatic, team `5EM4M85VSQ`, bundle `com.trinet.video`. Deployment target at
this commit is **iOS 15**.

```bash
xcodebuild -project TriNetVideo.xcodeproj -scheme TriNetVideo \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath /tmp/dev -allowProvisioningUpdates build

xcrun devicectl list devices                       # get the device names
xcrun devicectl device install app --device <NAME> \
  /tmp/dev/Build/Products/Debug-iphoneos/TriNetVideo.app
xcrun devicectl device process launch --device <NAME> \
  --terminate-existing --console com.trinet.video
```

### Traps that will cost you an hour each if you do not know them

- **`xcrun xctrace list devices` reports both phones offline while they are fine.** Use
  `xcrun devicectl list devices`, which says `available (paired)`. They pair over the
  network, not USB.
- **A locked phone refuses to launch anything.** The error is explicit — *"Unable to
  launch … because the device was not, or could not be, unlocked"* — and it is not a build
  failure. It happened five times in one session. Both phones must be unlocked *and*
  stay awake.
- **Without `--console` the app suspends** when the screen locks, and Bonjour stops with
  it. To observe two phones together, attach a console to each.
- **`log stream --device-name` does not exist** in this Xcode's `log`, and `log` itself is
  shadowed in zsh — use `/usr/bin/log` if you ever need it. Device output comes from
  `devicectl … --console`.
- **The simulator cannot test this.** No camera, so `video sent=0` there means nothing;
  and two simulators share the host's single address and port 7000, so the second logs
  `idle listener bind(:7000) busy — skip` and a two-way call is structurally impossible.
- **Both phones must be on the same network segment.** Bonjour is per-link. One of the
  test phones sat on `169.254.x` — a self-assigned address, meaning Wi-Fi was joined but
  DHCP never answered — and the two simply never saw each other. Check that each has a
  `192.168.x` address before concluding anything about the code.

### What to check, in order

1. Both apps launch, each logs `idle listener up on :7000` and a roster containing the
   other.
2. Place a call. The callee should ring.
3. Media both ways: the caller's log shows `audio tx …`, and `framesReceived` climbs on
   both.
4. Hang up, call again. **This is the interesting one** if you cherry-picked §4.

---

## 6. What the current head has that this commit does not

For deciding whether you want the baseline or the newer work. Head is `9ad5af67`.

| | at `1d425ab3` | at head |
|---|---|---|
| Identity | IP address typed by hand | a **handle**; dialling one is enough |
| Chat | only during a call, in memory, lost on hang-up | persists; sent **without** a call, signed with the device Ed25519 identity |
| Flow | call first | write first, call from inside the conversation; audio or video |
| List | discovered peers and raw addresses | contacts **you added by handle** only |
| Profile | none | name and photo |
| Addresses on screen | everywhere | none, by rule |
| Ringback for the caller | **none — silence** | telephone cadence, tied to call state |
| Auto-accept camera hole | **present** | removed |
| Session hijack | **present** | closed |
| Deployment target | iOS 15 | iOS 16 |

The newer work is untested end to end on two phones. The baseline's call path is the one
with history behind it. That is the trade, and it is why this document exists rather than
a recommendation.

---

## 7. House rules for whoever picks this up

- Every number carries a **status and a date** — hardware, post-route, simulated, or
  estimated — and they never share a table.
- A measurement that **refutes** the hypothesis is a delivered result, reported in the
  same voice as a success.
- Never `git add -A` from the repo root: the working tree carries pre-existing hook
  violations in `gen/`, `src/crypto.rs`, `specs/` and shell scripts, and staging them
  blocks your commit for someone else's debt.
- Code and repo documentation in **English**. The `no-cyrillic` hook does not cover Swift,
  so nothing but a reread will catch a Russian comment.
- Force-push is not authorised.

A fuller handover of the current state is in `phone/HANDOFF.md`.
