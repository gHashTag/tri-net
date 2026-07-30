# TRI-NET — Handoff (continue this work)

This doc lets another AI/engineer pick up a live TRI-NET call-app test setup on this Mac.
TRI-NET is a video-call app: **iOS + macOS clients + a Rust `call-api` server**, calling over
**LiveKit (Internet)** or **local mesh UDP**, with a **nickname directory** as the user identity.

Machine: `MacBook-Pro.local` · WiFi IP **`192.168.1.102`** · Apple Silicon (arm64).

---

## 0. TL;DR — current state (already working)

- **call-api server** running on `0.0.0.0:8080` (LAN-reachable) — the prebuilt binary the user sent.
- **LiveKit dev server** running on `0.0.0.0:7880` (devkey/secret, node-ip 192.168.1.102).
- **macOS client `TriNetVideo` built + running + registered** on the server as nickname **`@m4mac`**.
- SQLite DB at `/tmp/trinet-call.sqlite` (accounts / devices / nicknames / calls / group_chats).
- iPhone (`ssd26`, nickname `@zames`) has the unified app installed but its Settings pointed at the
  wrong host `SSDs-MacBook-Pro.local` — must be changed to `http://192.168.1.102:8080`.

Verify server up:
```bash
curl -s http://192.168.1.102:8080/healthz            # -> {"status":"ok"}
curl -s http://192.168.1.102:7880/                   # -> OK  (LiveKit)
sqlite3 /tmp/trinet-call.sqlite "select nickname,platform from nicknames n join devices d on n.device_id=d.device_id;"
```

---

## 1. Folders on disk (IMPORTANT — three different codebases)

| Path | What it is | Use it for |
|---|---|---|
| `~/Desktop/PROJECTS/CLAUDE/trinet-unified/` | **Clone of `gHashTag/tri-net` @ `feat/regen-final` (90869fc)** — the UNIFIED app: iOS client + Mac client + `services/call-api`. **THIS is the app on the iPhone.** | Build iOS + Mac clients, edit features |
| `~/Desktop/PROJECTS/CLAUDE/call-api/` | The user's **zip server** (`trinet-call-api`), newer (main.rs 135 KB) than the checkout's (84 KB). Source does NOT compile standalone (needs regenerated `gen/`), but `prebuilt/trinet-call-api` (arm64) **runs** and already implements **full APNs**. | Run the server (prebuilt binary) |
| `~/Desktop/PROJECTS/CLAUDE/tri-net/` | An OLDER **P2P mesh-only** branch (no nicknames, no LiveKit). **DO NOT build the iPhone from here** — it downgrades the app. | ignore for this task |

> The `feat/regen-final` branch name is diverged between the local `tri-net/` (P2P) and the remote
> (unified). The unified truth is the fresh clone in `trinet-unified/`.

---

## 2. How to run everything

### Server (call-api) — the prebuilt binary (has APNs)
The binary was quarantined by macOS on first run; strip + ad-hoc sign once:
```bash
cd ~/Desktop/PROJECTS/CLAUDE/call-api
xattr -cr prebuilt/trinet-call-api && codesign --force -s - prebuilt/trinet-call-api
TRINET_BIND=0.0.0.0:8080 \
TRINET_DB_PATH=/tmp/trinet-call.sqlite \
TRINET_LIVEKIT_URL=ws://192.168.1.102:7880 \
LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret \
./prebuilt/trinet-call-api        # add APNs env (section 4) to enable closed-app push
```

### LiveKit (media SFU, dev mode)
```bash
livekit-server --dev --bind 0.0.0.0 --node-ip 192.168.1.102
# devkey/secret; ws://192.168.1.102:7880 ; RTC tcp 7881, udp 7882
```

### macOS client (TriNetVideo, unified)
```bash
cd ~/Desktop/PROJECTS/CLAUDE/trinet-unified/phone/desktop
xcodegen generate --spec project_video.yml
xcodebuild -project TriNetVideo.xcodeproj -scheme TriNetVideo -configuration Debug \
  -derivedDataPath .dd-macvideo -clonedSourcePackagesDirPath .spm \
  -destination 'platform=macOS,arch=arm64' build
# point the client at the server (UserDefaults, NOT env — see section 3):
defaults write com.trinet.video internetAPIBaseURL "http://192.168.1.102:8080"
defaults write com.trinet.video liveKitURL "ws://192.168.1.102:7880"
open -n .dd-macvideo/Build/Products/Debug/TriNetVideo.app
```
Built app is at `.dd-macvideo/Build/Products/Debug/TriNetVideo.app`. Ad-hoc signed (`CODE_SIGN_IDENTITY "-"`).

### iOS client (physical iPhone) — done BY THE USER in Xcode
Open **`~/Desktop/PROJECTS/CLAUDE/trinet-unified/phone/TriNetVideo.xcodeproj`** (NOT `tri-net/…`),
select the iPhone, press **Run**. Signing team is already set (`DEVELOPMENT_TEAM`; note there is a
mismatch: iOS pbxproj = `5EM4M85VSQ`, `phone/project.yml` = `5H75B24AH5` — reconcile before device signing).
Then on the phone: **Settings → Internet service** → `http://192.168.1.102:8080`, LiveKit `ws://192.168.1.102:7880`, **Save**.
The unified iOS target builds cleanly for the Simulator (verified). VoIP push/CallKit need a **physical** device.

---

## 3. Client configuration model (how the client finds the server)

`InternetCallConfiguration.load()` in `phone/shared/CallIdentity.swift:43` reads, in order:
1. **UserDefaults** key (`internetAPIBaseURL`, `liveKitURL`, `serviceAccessToken`, `developmentRoomToken`), then
2. **Info.plist** key (`TRINET_API_BASE_URL`, …). **NOT environment variables** — `--env` is ignored.

So configure via `defaults write com.trinet.video <key> <value>` (macOS) or the in-app **Settings** screen (iOS).

---

## 4. The four feature requests — status + exact work

Findings came from a 4-agent code scout. File:line pointers are into `trinet-unified/`.

### (A) Incoming call when app is CLOSED  → mostly DONE, needs your APNs key
- **iOS device side: PRESENT.** PushKit VoIP registry + CallKit `CXProvider` + `didReceiveIncomingPush`
  reporting to CallKit; Info.plist `UIBackgroundModes=[audio,voip,remote-notification]`; entitlement
  `aps-environment`. Files: `phone/TriNetVideo/CallKitCoordinator.swift` (9, 42, 123, 143), `App.swift`.
- **Server side: the ZIP binary ALREADY sends APNs VoIP push** (strings show `api.push.apple.com`,
  `apns-push-type:voip`, ES256 JWT, `VoipPushPayload{IncomingCall: call_id, call_uuid, caller}`).
  The 90869fc `services/call-api` source does NOT (older). **We run the zip binary → push works.**
- **What's missing = credentials only.** Set these env vars on the server and restart it:
  ```
  TRINET_APNS_TEAM_ID=<your Apple team id>
  TRINET_APNS_KEY_ID=<key id of the .p8>
  TRINET_APNS_PRIVATE_KEY_PATH=/absolute/path/AuthKey_XXXX.p8   (mode 0600, ES256 .p8)
  TRINET_APNS_BUNDLE_ID=com.trinet.video
  TRINET_APNS_ENVIRONMENT=sandbox     (dev builds use api.sandbox.push.apple.com)
  ```
  Get the `.p8` at developer.apple.com → Certificates/Keys → new Key → **Apple Push Notifications service**.
  Requires a **physical iPhone** (VoIP pushes are never delivered to the Simulator).
- If you must use the 90869fc source server instead of the zip binary, implement the sender there:
  `services/call-api/src/main.rs` — extend the targets SELECT at ~1079 to include `voip_push_token`,
  add an ES256-JWT + HTTP/2 APNs POST after `commit()` at ~1149. The `p256` crate is already a dep.

### (B) Beautiful/original incoming-call screen  → STARTED this session
- Redesigned `struct IncomingCallOverlay` in **`phone/TriNetVideo/Views.swift:394`** (gradient backdrop +
  breathing glow, 3 rippling rings, gradient avatar disc with glow, `ENCRYPTED · FORWARD-SECRET` badge,
  glowing Accept button). Ring/haptics/accept/decline wiring preserved (`RingSynth`, `vm.acceptIncoming`/`declineIncoming`).
- macOS twin to match: `phone/desktop/VideoCallTab.swift:147` (`IncomingCallBanner`) — not yet redesigned.
- **TODO: verify the iOS build is green** (a build was kicked off this session; check `/tmp/iosverify2.log`
  for `BUILD SUCCEEDED`) and screenshot in the Simulator per CLAUDE.md.

### (C) Chat: sound + unread count  → in-call chat DONE, group chat TODO (client-side)
- **In-call 1:1 chat (peer UDP, `0xFB 0xCA`): sound + numeric badge already PRESENT** (both platforms).
- **Server-backed GROUP chat: the ZIP server already returns `unread_count` / `total_unread_count`**
  and sends an APNs **Alert** push (`AlertPushAps{badge,sound,thread-id}`). The 90869fc **client does NOT
  use it** — no sound, no badge; group chat polls every 3s.
- Implement on the client:
  - Light sound on new group message: reuse the in-call `ChatChime` idea; add to `GroupChatController`
    in `phone/shared/InternetCall.swift:599-696` (detect new message id in `refresh()`, play a chime).
  - Unread badge: `GroupChatSummary` (`phone/shared/InternetCall.swift:130`) + add a client `unread` map;
    render a numeric badge in `phone/TriNetVideo/Views.swift` chat list. (Server already supplies the count.)

### (D) Nickname = unique identity bound to the iPhone  → uniqueness DONE, binding to tighten
- **Unique: PRESENT.** `nickname` is PRIMARY KEY; claim is an IMMEDIATE (atomic) transaction with
  confusable rejection; a live nickname held by another account cannot be stolen
  (`services/call-api/src/main.rs` ~470, 920, 961). Client model in `phone/shared/NicknameDirectory.swift`.
- **Identity is UUID + P-256 signing key; nickname is a directory alias**, currently bound to the ACCOUNT,
  not hard-bound to the one device. To pin it to a single device/key: `main.rs:961-970` (claim deletes+inserts
  by user_id → bind to device_id/key_fingerprint) + `main.rs:469-474` (nicknames schema, add immutable device col).
- Truly hardware-bound key = generate the P-256 key in the **Secure Enclave** (`CallIdentity.swift:204`),
  needs a physical iPhone (Simulator has no SE). Add a recovery/expiry so a lost device's nick isn't squatted forever.

---

## 5. Mesh vs Internet connectivity (both requested)
- **Internet path**: client → call-api (`/v1/devices/register`, `/v1/directory`, `/v1/calls`) → LiveKit room token → media over LiveKit. Verified: the Mac client registered `@m4mac` end-to-end against the server.
- **Mesh path**: local UDP + Bonjour (`_trinet-call._udp`), encrypted forward-secret, no server. The app's
  "Transport: Local/Mesh UDP + LiveKit WebRTC" toggles/auto-selects. Two devices on the same WiFi discover each other.
- For any LAN test: **all devices on the same WiFi router**; the iPhone in the screenshot was on **5G** — turn WiFi on.

---

## 6. Network / firewall
- macOS Application Firewall is **ON**. If iPhones can't reach `192.168.1.102:8080/7880`, either click **Allow**
  on the macOS prompt for `trinet-call-api` + `livekit-server`, or (user runs, needs their password):
  ```bash
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off   # re-enable with 'on' after
  ```
  (The AI assistant must NOT type the user's sudo password or change the firewall — the user does this.)

---

## 7. What was done this session
1. Unzipped the user's `call-api.zip` → `~/Desktop/PROJECTS/CLAUDE/call-api/` (dropped the 471 MB build cache).
2. Ran the prebuilt server + installed & ran LiveKit (`brew install livekit`).
3. Discovered the source needs `gen/rust/*` (monorepo) — cloned the unified repo for the coherent version.
4. Built the **macOS unified client** (LiveKit SDK) → it **registered `@m4mac`** on the server (verified in DB).
5. Verified the **unified iOS target compiles** for the Simulator.
6. Scouted the 4 feature areas (above) and found the zip server already implements APNs push + unread counts.
7. **Redesigned the iOS incoming-call screen** (`Views.swift:394`), fixed `answerButton` signature (added `glow`).

## 8. Immediate next steps for whoever continues
1. Confirm `/tmp/iosverify2.log` shows `** BUILD SUCCEEDED **` for the incoming-UI change; screenshot it in the Simulator.
2. Implement group-chat sound + unread badge on the client (section 4C) — server already provides the data.
3. Get the user's APNs `.p8` + Key ID + Team ID, set the server env vars (section 4A), test closed-app ring on a physical iPhone.
4. Optionally tighten nickname→device binding (section 4D) — needs editing the SOURCE server (the 90869fc `services/call-api`, which builds in-place) and switching to it, or a new server build.
5. Point the iPhone Settings at `http://192.168.1.102:8080` + `ws://192.168.1.102:7880` and do a live @nick call.

## 9. Repo state
This checkout is `gHashTag/tri-net` @ `feat/regen-final` `90869fc` (shallow clone). The only local edit is the
incoming-UI redesign in `phone/TriNetVideo/Views.swift`, committed on branch `feature/incoming-ui-and-notes`.
To push: `git -C ~/Desktop/PROJECTS/CLAUDE/trinet-unified push -u origin feature/incoming-ui-and-notes` (repo is `gHashTag/tri-net`).
