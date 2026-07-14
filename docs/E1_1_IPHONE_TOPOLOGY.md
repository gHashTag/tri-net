# E1.1 - iPhone <-> P201 Mini topology decision

phi^2 + phi^-2 = 3 | TRINITY

**Status:** DECISION COMPLETE - HARDWARE UNVERIFIED
(The architecture decision below is closed. Implementation validation on real
hardware is a separate gate defined in section 7; it is NOT a reason to keep
this record in DRAFT.)
**Owner:** Lane A (PWA-first) - first task, unblocked without merging other PRs
**Related:** wave report `docs/WAVE_IPHONE_ADMIN_2026-07-14.md`, PR #79 (M2 TUN),
PR #63/#65 (Noise)

**Board naming:** the current hardware target is the **P201 Mini** (Zynq-7020,
ARM Cortex-A9 dual + Artix-7 PL). Older documents call the same board "P203";
"P203" is a deprecated alias. This document uses **P201 Mini** throughout.

## 1 - Problem

Choose the **physical channel** between an iPhone (end-user client - admin
dashboard PWA + PTT) and a P201 Mini (mesh node). The channel must:

1. Work without jailbreak, without MFi certification, without App Store
   distribution (Lane A constraints).
2. Carry IP traffic for Opus PTT plus an admin WebSocket. The aggregate
   requirement is tiny (order of tens of kbps); the exact figure is an
   acceptance measurement on real hardware, not a design constant.
3. Allow the iPhone to reach the node's admin surface by a deterministic entry
   path (see section 4 - not by browser-side service discovery).
4. Be measurable in the lab (no OTA emissions license required).

## 2 - Three candidates

### Variant A - USB Personal Hotspot (iPhone -> P201 Mini)

**Direction:** the iPhone shares its connection to the P201 Mini. The iPhone is
the DHCP server (typically `172.20.10.1/28`); the P201 Mini is the client.

**How it works on Linux:**
The `usbmuxd` + `libimobiledevice` stack plus the kernel `ipheth` driver
presents the iPhone as a USB Ethernet interface; a DHCP client on the Linux
side obtains a lease. The ArchWiki
[iPhone tethering](https://wiki.archlinux.org/title/IPhone_tethering) page
documents the full flow (`usbmuxd`, the on-device Trust prompt, `ipheth`, DHCP).
Apple documents USB Personal Hotspot and the Trust flow at
[support.apple.com/en-us/111785](https://support.apple.com/en-us/111785).

**Pros:**
- Apple-supported, documented USB path; no Apple-side code required.
- Zynq Yocto/PetaLinux kernels can enable `CONFIG_USB_IPHETH`.
- User action is a single tap ("Personal Hotspot") plus the Trust prompt.

**Cons / risks (primary, not marginal):**
- **Personal Hotspot shares the iPhone's cellular connection.** Apple's
  [Share your internet connection](https://support.apple.com/guide/iphone/share-your-internet-connection-iph45447ca6/ios)
  guide states Personal Hotspot shares the cellular data connection and that
  carrier plan support may be required. There is **no verified configuration**
  in which Airplane Mode + Wi-Fi off yields a working Personal Hotspot without
  cellular/carrier support; the earlier claim to that effect is **removed** as
  unsupported. **Enterprise-managed (MDM) and some MVNO/carrier profiles disable
  Personal Hotspot entirely** - treat this as a primary adoption risk.
- The iPhone owns the IP plan; the node is a DHCP client on the iPhone's subnet,
  so the PWA must reach the node at its iPhone-assigned address (see section 4).
- Requires a physical cable (Lightning or USB-C depending on iPhone model).

**Verdict: PROVISIONAL PRIMARY for v0.1**, conditional on passing the
real-device acceptance gate in section 7. Until that gate passes, Variant A is
an architecture decision, not a validated implementation.

### Variant B - Reverse tethering (P201 Mini -> iPhone)

**Direction:** the P201 Mini provides the network to the iPhone, via a
non-standard `usbmuxd` device mode
([libimobiledevice#1348](https://github.com/libimobiledevice/libimobiledevice/issues/1348)).

**Pros:** the node controls the IP plan and can route the iPhone directly into
the mesh TUN interface; does not consume iPhone cellular data.

**Cons:** requires a custom `usbmuxd` build (not mainline); undocumented by
Apple and may break on any iOS release; iOS does not reliably start a DHCP
client for USB Ethernet outside Personal Hotspot mode; requires PetaLinux
rootfs changes.

**Verdict: FALLBACK.** Not for v0.1. Track under Lane B (native app), which
needs a custom stack regardless.

### Variant C - Wi-Fi hotspot from P201 Mini, iPhone as station

**Direction:** the P201 Mini is the AP; the iPhone is a station.

**How it works:** needs a Wi-Fi radio the mainline P201 Mini config does not
have (AD9361 is not an 802.11 modem; options are a USB Wi-Fi dongle or an R&D
802.11-on-AD9361 effort such as [openwifi, arXiv:2003.09525](https://arxiv.org/abs/2003.09525)).

**Pros:** full wireless mobility; natural fit for a walkie-talkie use case; iOS
joins Wi-Fi networks without special permissions.

**Cons:** requires hardware not currently present; a USB dongle drags in
drivers + hostapd + DHCP server; double network layer to bridge.

**Verdict: FUTURE (Sprint 4+).** Prove the pipeline over USB first.

## 3 - Decision matrix

| Criterion | A (Personal Hotspot) | B (Reverse tether) | C (Wi-Fi AP) |
|---|---|---|---|
| iPhone support | documented USB path | undocumented | supported (Wi-Fi join) |
| P201 Mini kernel | mainline `ipheth` | custom `usbmuxd` | USB dongle + hostapd |
| Hardware cost | $0 (cable) | $0 (cable) | >= $15 (dongle) |
| Setup complexity | Settings tap + Trust | rebuild + env var | full 802.11 config |
| Long-term stability | Apple-supported | undocumented | R&D if openwifi |
| Carrier/MDM risk | **primary risk** | none (no hotspot) | none |
| Mobility | tethered by cable | tethered by cable | free-roam |
| **v0.1 priority** | **PROVISIONAL PRIMARY** | fallback | future |

## 4 - Chosen path for v0.1

**Variant A - USB Personal Hotspot**, provisional-primary pending the section-7
gate.

Rationale:
1. Works today without custom kernel builds.
2. Zero hardware BOM addition.
3. Lets us measure everything else (admin API, WebSocket, Opus) over an honest
   IP link.
4. Does not block Variant C; the same PWA/WebSocket/mDNS-advertisement stack is
   reused when a Wi-Fi radio arrives.

### 4.1 - Entry path (deterministic, NOT browser service discovery)

The iPhone-side client is a **Safari PWA**. iOS Safari provides **no public Web
API for arbitrary DNS-SD / Bonjour service browsing**: a web page cannot
enumerate `_trinet-admin._tcp.local`. (`NSLocalNetworkUsageDescription` is a
**native app** Info.plist key and does **not** grant a Safari PWA an mDNS-browse
prompt; the earlier claim to that effect is removed.) Apple's Bonjour
[NetServices FAQ](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NetServices/Articles/faq.html)
describes native DNS-SD / link-local behavior, and Apple DTS confirms in
[forum thread 704037](https://developer.apple.com/forums/thread/704037) that iOS
Safari does not expose a Bonjour service-list UI to web content.

Therefore, for Lane A the PWA reaches the node through a **deterministic entry
path**, in priority order:

1. **QR code / printed URL** carrying the node's admin URL (numeric IP for the
   iPhone-assigned subnet, e.g. `https://172.20.10.2:8443`).
2. A **stable `trinet-admin.local` hostname**, used only **after** name
   resolution to the node is proven on the real device (mDNS `.local`
   resolution of a single known name by the OS resolver - distinct from
   service browsing).

**Avahi advertisement of `_trinet-admin._tcp.local` is preserved** on the node
for native tooling and future clients (Bonjour-capable native apps, `dns-sd`,
`avahi-browse`). It is **not** an acceptance criterion for the PWA.

## 5 - Reference network topology

```
+-------------+   USB (Lightning/USB-C)   +--------------+   Tri-Net mesh   +--------------+
|   iPhone    |<--------------------------|  P201 Mini   |<--- UDP+radio -->|  P201 Mini   |
|  (Safari    |  iOS Personal Hotspot;    |  (Zynq-7020, |                  |  (peer node) |
|   PWA)      |  iPhone = DHCP server     |  Yocto Linux)|                  |              |
|  172.20.10.x|                           |  172.20.10.2 |                  |              |
+-------------+                           +------+-------+                  +--------------+
                                                 |
                                                 | Avahi advertises (native tooling only):
                                                 |   _trinet-admin._tcp.local
                                                 |   port 8443 (admin PWA + WS)
                                                 |   port 5000 (mesh UDP, existing)
                                                 |
                                                 v
                                         +--------------+
                                         | admin_httpd  |  <- E2.1/E2.2
                                         | (this repo)  |
                                         +--------------+
```

## 6 - Sandbox smoke (Level 1: IP/API simulation, NO iPhone)

Level 1 verifies the IP/API layer on a dev host. It is a simulation of the
iPhone side, **not** evidence that Safari will connect (see section 8 on TLS).

```bash
# /api/status over the numeric IP (proxy for the PWA fetch)
curl -k https://<node-ip>:8443/api/status
# expected: JSON with node_id, uptime, neighbor list, ETX table

# Node-side advertisement present (native-tool evidence, NOT a PWA criterion)
avahi-browse -r _trinet-admin._tcp
# expected: single record, TXT includes node_id + version

# WebSocket upgrade (proxy for the PWA subscription)
websocat -k wss://<node-ip>:8443/ws
# send: {"type":"subscribe","topic":"neighbors"}
# expect: heartbeat every 1s
```

`curl -k` / `websocat -k` disable certificate verification and therefore prove
only that the endpoints answer - **not** that iOS Safari will trust the
connection (section 8). The runnable Level-1 harness is
`smoke/e1_1_admin_httpd_smoke.sh` (build + status + WS + static file, all on
`127.0.0.1`).

## 7 - Real-device acceptance gate (Level 2: BLOCKING for hardware-validated)

Variant A is **not** hardware-validated until every item below is recorded on a
real iPhone + cable + a real P201 Mini image. This gate is what promotes the
status line from HARDWARE UNVERIFIED to hardware-validated.

1. **Carrier / hotspot availability confirmed** on the test iPhone (Personal
   Hotspot enabled, not blocked by MDM/MVNO); record carrier + iOS version.
2. **Trust prompt** accepted; the pairing recorded.
3. **`ipheth` interface** appears on the P201 Mini; record interface name.
4. **DHCP lease** obtained by the node; record the assigned node IP.
5. **iPhone Safari reaches the HTTPS admin URL by numeric IP** and loads the PWA
   (subject to the section-8 certificate/profile prerequisite).
6. **Stable hostname / QR entry path** works: either QR-encoded numeric URL, or
   `trinet-admin.local` resolving on-device after real resolution is proven.
7. **Aggregate PTT + admin traffic measured** on the real link (throughput and
   latency of the actual Opus PTT + admin WebSocket load) - report measured
   numbers, no theoretical USB rate.
8. **Reconnect across 5 cable unplug/replug cycles**; the admin surface recovers
   each time.

mDNS/DNS-SD **browse** from the device is **optional native-tool evidence**, not
a PWA acceptance criterion (section 4.1).

## 8 - TLS / trust prerequisite (feeds E2.2)

A self-signed `https://<ip>` endpoint will **not** satisfy normal Safari trust:
Safari will refuse or hard-warn without a trusted certificate. `curl -k` is
**not** evidence that Safari will connect. Therefore **E2.2 must define the
certificate / pairing / bootstrap story** - for example a device-provisioned
certificate installed via a configuration profile, or an equivalent trust
anchor - before the section-7 item 5 can pass on an unmodified iPhone. Do not
treat `curl -k` success as browser success.

## 9 - What this document does not decide

- **Authentication / trust bootstrap** - E2.2 (see section 8).
- **Background audio on iOS** - foreground-only for v0.1 (wave report section 7).
- **Real latency / throughput** - measured only in the section-7 gate.
- **iPhones without Personal Hotspot capability** (enterprise-managed, some
  MVNOs) - those users wait for Variant C. This is a primary risk, not an edge
  case.

## 10 - What unblocks after this decision

- E2.1 (PWA skeleton + node-side mDNS advertisement) - ready to start.
- E2.2 (admin API + certificate/pairing/mTLS) - starts in parallel; owns the
  section-8 trust story.
- E3.x (PTT pipeline) - independent of topology; starts independently.

phi^2 + phi^-2 = 3 | TRINITY
