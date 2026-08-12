# TRI-NET phone — handoff

**For:** the next agent picking this up in a fresh session.
**Written:** 12 August 2026. **Branch:** `feat/ring-hardening`. **Head:** `3b32bf04`.

Read this whole file before touching anything. Section 3 contains a defect that is
still open and is the first thing to look for.

---

## 0. What this is

`tri-net/phone/TriNetVideo` — a native iOS app (Swift/SwiftUI, no third-party
dependencies) for encrypted peer-to-peer calls and chat over a local mesh, part of the
wider TRI-NET / ДОМОВОЙ project by Dmitrii Vasilev (`gHashTag`).

The product promise is that **data does not leave the house**. There is no server, no
account, no phone number. Two phones on the same network find each other and talk
directly.

| file | lines | what lives there |
|---|---:|---|
| `VideoPipeline.swift` | 3246 | crypto, transport, discovery, rendezvous, camera, the profile and chat stores |
| `ViewModel.swift` | 1232 | `StreamViewModel` — call state, chat send/receive, idle listener |
| `Views.swift` | 1658 | every screen |
| `MeshMapView.swift` | 395 | mesh visualisation |
| `App.swift` | 16 | entry point |

Deployment target **iOS 16.0**. Team `5EM4M85VSQ`, automatic signing, bundle
`com.trinet.video`.

---

## 1. How to build, install and read logs

Two physical iPhones exist: `ssd26` (iPhone 17 Pro Max) and `t27_dev` (iPhone 13 Pro).
Both are network-paired, not USB.

```bash
# device build
xcodebuild -project TriNetVideo.xcodeproj -scheme TriNetVideo \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath /tmp/dev -allowProvisioningUpdates build

# install + launch, with the app's stdout attached
xcrun devicectl device install app --device ssd26 \
  /tmp/dev/Build/Products/Debug-iphoneos/TriNetVideo.app
xcrun devicectl device process launch --device ssd26 \
  --terminate-existing --console com.trinet.video
```

### Instrument traps, each of which cost real time

- **`xctrace list devices` lies.** It reports both phones as *offline* while
  `xcrun devicectl list devices` reports them *available (paired)*. Trust `devicectl`.
- **`log stream --device-name` does not exist** in this Xcode's `log`. Device logs come
  from `devicectl … --console` and nowhere else.
- **`log` is shadowed in this zsh.** Use `/usr/bin/log` if you ever need it.
- **A locked phone refuses to launch anything.** The error says so explicitly:
  `Unable to launch … because the device was not, or could not be, unlocked`. This is
  not a build failure and it happened four times; check for it before diagnosing.
- **Without `--console` the app suspends** when the screen locks and Bonjour stops.
  Two phones can only be observed together if both are unlocked and both have a console
  attached.
- **The simulator cannot test this app meaningfully.** No camera (so `video sent=0` is
  the simulator, not a bug), and two simulators share the host's single address and
  port 7000 — the second logs `idle listener bind(:7000) busy — skip`, so a two-way call
  is structurally impossible there. Use it for looking at screens only.

### Repo rules the pre-commit hook enforces

`lefthook` runs `ascii-only`, `no-cyrillic`, `no-gen-edits`, `no-handwritten-logic`,
`no-shell-scripts`, `specs-typecheck`, `dispatcher-parity`.

**Never `git add -A` from the repo root.** The working tree carries pre-existing
violations in `gen/`, `src/crypto.rs`, `specs/` and shell scripts; staging them blocks
your commit for someone else's debt. Stage your own paths only.

Code and repo documentation are **English**. Chat with the owner is Russian. The
`no-cyrillic` hook does *not* cover Swift, so nothing will catch a Russian comment but
a reread.

---

## 2. What works, verified on hardware

Every line here was observed in a device log, not reasoned about.

| what | evidence |
|---|---|
| Discovery by handle, both directions | `roster 1 peer(s): iPhone 17 Pro@iphone_17_pro_a445` |
| Idle listener | `idle listener up on :7000 (waiting for calls)` |
| Server-reflexive address (the internet path) | `srflx=182.232.227.15:15428` — **only on device**; the simulator reports `srflx=none` |
| Audio capture → Opus → transmit | `audio tx #5000 128B sent=OPUS`, ~50 packets/s |
| Opus encoder *and* decoder initialise | 48 kHz mono, both |
| Build clean for device and simulator | `BUILD SUCCEEDED` |
| App runs with zero errors in the launch log | last verified at head `3b32bf04` |

**Never verified end to end:** a real two-phone call. `t27_dev` has been unavailable or
locked at every attempt. Audio *sending* is proven; audio *arriving* is not.

---

## 3. OPEN DEFECT — look here first

`disconnect()` now calls `crypto.resetSession()`, which drops the session key and rolls
the ephemeral key. Before that fix, `consumeHandshake` ended in an **unconditional**
`sessionKey = key`, and that unconditional assignment was **load-bearing**: `crypto` is a
per-process singleton and `disconnect()` never cleared anything, so the *second* call in
an app session worked only because the assignment overwrote stale state.

**So: a second call in one app session may no longer establish.** It has not been tested.
This is the first thing to check when two phones are available:

1. call, confirm media
2. hang up
3. call again — does it connect?

If it does not, the fix is in the handshake path, not in `resetSession()` — the reset is
correct and the old behaviour was the vulnerability.

---

## 4. Security work already done — do not reintroduce any of this

Three defects were found by reading the source and are closed. All three would come back
easily if someone optimises for convenience.

**Remote camera and microphone (`ViewModel.swift`, was ~line 788).** An invite with more
than two participants, or one whose room matched ours, called `acceptIncoming()` with no
ring. Invites are authenticated with a key derived from `SHA256("tri-net-psk-v1")` — a
compiled-in constant **public in this repository** — so anyone able to send a datagram to
:7000 could forge one and open the camera without a tap. Auto-accept is gone. Every
invite rings. There is no version of that convenience that is safe.

**Session hijack (`VideoPipeline.swift`).** A handshake was honoured from any source at
any time. Now accepted only when no session exists, or from the address we already
completed one with (`handshakePeer`).

**Per-launch keys sold as per-call.** `ephPriv` was a `let` on that singleton — one X25519
private key for every peer and call in a run, under a comment reading `forward-secret`.
It is a `var`, rolled by `resetSession()`.

**Also corrected: post-quantum claims.** `gen/rust/pq_hybrid.rs` carries Kyber-sized
constants and a 32-bit XOR combiner. No lattice arithmetic, no PQ dependency in
`Cargo.toml`, nothing calls the module. As a t27 *specification of message shapes* that is
legitimate. Stating `ML-KEM/Kyber768 (NIST FIPS 203)` and `EO 14412 compliant` in
submissions to **DIU and AFWERX** was not. Those documents (`docs/diu_cso_tri_net.md`,
`docs/afwerx_open_topic.md`) were corrected on disk. **They are untracked by git and were
deliberately not committed** — by the owner's own rule, submission drafts live in
`~/Desktop/PROJECTS/CLAUDE/business/`, not in a public repo.

**The shared PSK is still a public constant.** It now only gates a ring, which is
tolerable, but any new feature that trusts it for anything else inherits the hole. Text
messages are signed with the device's **Ed25519 identity** instead, and anything new
should be too.

---

## 5. What the app does now, and the rules behind it

### Handles

Each phone has a short handle. Dialling one is enough — no address, no address book.

Normalised hard: lowercase, `[a-z0-9_]`, 20 max, `@` stripped. So `Vasya`, `VASYA` and
`@vasya` are one address.

The default is a base plus a tail of the persistent uid, and **that tail earned itself
immediately**: iOS returned the same `UIDevice.current.name` for both test phones, so
without it they would have advertised **one address between them**.

Two resolution paths: on the LAN the handle is already in the Bonjour TXT record; off it,
**the handle is the rendezvous key** — a phone publishes under `hash("@own")` and a caller
under `hash("@theirs")`, so they meet without agreeing anything in advance.
`startNickListener()` keeps the former alive while idle.

### Chat before calls

Chat used to exist only inside a call — in memory, gone when the call ended. Now:

- Off-call text travels on the same idle :7000 socket the invite listener owns
  (`TextFrame` in `VideoPipeline.swift`).
- Signed with the device Ed25519 identity. `decode()` rejects a bad signature, a truncated
  frame, or a timestamp older than a week, silent-safe on any input.
- Threads persist on the device (`ChatStore`).
- **Delivery is reported honestly.** The message is stored either way so the thread never
  lies about what you wrote, but an unreachable peer logs *stored, not delivered* rather
  than showing a tick.

### The interface

Every row — nearby or recent — opens a **conversation**. Calling happens inside it. The
header carries three actions in the order people reach for them: assistant, audio call,
video call. Audio-only is the video path with the camera off.

**No addresses anywhere on screen.** Not the peer field, not candidate chips, not the
local address, not in settings, **not the port number**. A person picks a person; the
machine works out how to reach them. `grep myIP Views.swift` must stay at zero. The call
journal stays — how a link behaved is worth seeing, where it went is not.

A profile is a **name and a photo**. Photo downscaled to 256px and stored as JPEG; a
full-resolution camera-roll image in `UserDefaults` is megabytes reloaded at every launch.

### Visual language

Two sources, and they agree:

- The repo's own `phone/BRANDBOOK.md`: **monochrome first** — black surfaces, white ink,
  colour reserved for the live dot and for danger. The site's neon green is deliberately
  *not* carried into the app.
- `mainframecomputer/fullmoon-ios`, which the owner named. Read the actual repo, not a
  description of it — I did the latter first and it produced the wrong thing. What matters:

| | fullmoon |
|---|---|
| bubble | **only your own message has one**; the other side is plain text |
| inset | 48pt on the far side, not a `Spacer` |
| radius | 24 |
| composer | field and send button inside **one** rounded container, `minHeight: 48` |
| timestamps | none inside a bubble |
| list | a plain `List` with `.searchable`, headline/subheadline rows, no cards |

---

## 6. Platform traps that already bit

- **`.searchable` lives in the navigation bar.** Hiding the bar and drawing your own
  header with `safeAreaInset` leaves search with nowhere to be and **takes the whole
  screen with it on device**. The simulator tolerated it; the phone showed nothing, which
  read as "the app doesn't launch". Use the real navigation bar.
- SwiftUI's type-checker gives up on a long inline expression in a row builder. Extract it
  into a function.
- Applying a short string replacement after a longer one that contains it produces
  `vm.vm.`. Order replacements longest-first, or anchor them.

---

## 7. What is next, in order

1. **Two-phone call test.** The open defect in §3, then: message without a call, call from
   the thread, hang up, call again. Both phones unlocked, both with a console attached.
2. **Transcription.** The assistant toggle exists per conversation and currently only
   stores a flag; nothing listens yet. The design work is done — see the messenger
   research output referenced below. On-device Russian is the hard part and must be
   checked, not assumed: `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, the
   newer `SpeechAnalyzer`/`SpeechTranscriber`, or `whisper.cpp` with a quantised model.
   Both call legs are already separate streams, so speaker attribution is nearly free —
   tap the local capture before Opus encode and the far-end PCM after decode.
3. **Photo exchange.** `Profile.peerPhoto(_:)` reads a store that nothing writes yet.
4. **Offline delivery.** Text only reaches a peer that is reachable now. Store-and-forward
   and iOS push are the open questions; note that on iOS **no phone can wake another** —
   only APNs or a `NEAppPushProvider` entitlement can, which is a real constraint on the
   no-server promise and must be stated to users rather than designed around.

A full messenger design study (Telegram's mechanisms, Signal/Matrix/SimpleX/Briar,
on-device transcription, and an audit of this codebase) was produced by a 13-agent
workflow. Its findings are what §3 and §4 above are drawn from.

---

## 8. How the owner works — follow this

- **Every number carries a status and a date.** Hardware-measured, post-route, simulated,
  or estimated. Never mix them in one table.
- **A measurement that refutes the hypothesis is a delivered result**, not a failure.
  Report it in the same voice as a success.
- **State the limits before signing, not after.** In this project the honest boundary is
  the most valuable part of a report.
- **Do not trust an instrument that sits inside the failure domain.** Several traps in §1
  are exactly that, and they cost hours before being spotted.
- Merging own PRs is authorised; **force-push is not**.
