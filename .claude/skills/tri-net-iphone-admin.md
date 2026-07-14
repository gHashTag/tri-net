# tri-net-iphone-admin

phi^2 + phi^-2 = 3 | TRINITY

Skill for the iPhone <-> P201 Mini admin/PTT lane (E1.x/E2.x/E3.x). Load when
working on iPhone connectivity, the admin PWA, mDNS advertisement, or PTT
transport for tri-net.

## Hard facts (verified, cite these)

- **Board name is P201 Mini** (Zynq-7020). "P203" in older docs is a deprecated
  alias for the same board. Use P201 Mini.
- **iOS Personal Hotspot shares the CELLULAR connection.** It is not a
  SIM-independent USB Ethernet mode. Carrier plan support may be required, and
  MDM/MVNO profiles can disable it entirely. There is no verified
  "Airplane Mode + Wi-Fi off => hotspot without SIM" configuration. Treat
  carrier/enterprise restriction as a PRIMARY risk.
  (Apple: support.apple.com/guide/iphone/iph45447ca6 ; support.apple.com/en-us/111785)
- **iOS Safari / PWA has NO public Web API for DNS-SD / Bonjour service
  browsing.** A web page cannot enumerate `_trinet-admin._tcp.local`.
  `NSLocalNetworkUsageDescription` is a NATIVE-app Info.plist key; it does not
  grant a Safari PWA an mDNS-browse prompt.
  (Apple NetServices FAQ ; DTS forum thread 704037)
  => For a PWA client, use a **deterministic entry path**: QR code / printed URL
  (numeric IP), or a stable `trinet-admin.local` hostname only after real-device
  name resolution is proven. Keep Avahi advertisement for native tooling only.
- **Self-signed `https://<ip>` does NOT satisfy Safari trust.** `curl -k` /
  `websocat -k` prove endpoints answer, NOT that Safari will connect. A trusted
  certificate/profile (E2.2: certificate/pairing/bootstrap) is a prerequisite.
- **Linux tethering stack**: `usbmuxd` + `libimobiledevice` + kernel `ipheth`
  (enable `CONFIG_USB_IPHETH`) + DHCP client. iPhone is DHCP server
  (~172.20.10.1/28); node is client. (ArchWiki: iPhone_tethering)

## Topology decision (E1.1, DECISION COMPLETE - HARDWARE UNVERIFIED)

Variant A (USB Personal Hotspot, iPhone -> P201 Mini via ipheth) is the
PROVISIONAL PRIMARY for v0.1, gated on a real-device acceptance gate. Variant B
(reverse tether, custom usbmuxd) = fallback. Variant C (Wi-Fi AP) = future
(needs a radio the board lacks). Record: `docs/E1_1_IPHONE_TOPOLOGY.md`.

Architecture decisions can be COMPLETE while hardware is UNVERIFIED - do not keep
a closed decision in DRAFT just because a hardware gate is pending. State the two
statuses separately.

## Smoke is two levels

- **Level 1 (sandbox)**: IP/API simulation on 127.0.0.1. `smoke/e1_1_admin_httpd_smoke.sh`
  builds admin_httpd standalone (rustc + `#[path]` generated modules, since the
  crate root does not fully build), checks `/api/status`, static file, WS 101.
  Does NOT prove Safari trust or tethering.
- **Level 2 (real-device gate, BLOCKING)**: real iPhone + cable + P201 image.
  Must record: carrier/hotspot availability, Trust prompt, ipheth iface, DHCP
  lease, Safari-reaches-HTTPS-by-IP, stable hostname/QR path, aggregate PTT+admin
  traffic measurement, reconnect across 5 cable cycles. mDNS browse is optional
  native-tool evidence, not a PWA criterion.

## Honesty rules for this lane

- No uncited goodput numbers; no "all iPhones" universals. Bandwidth need is
  tiny; acceptance = measured throughput/latency on the real device.
- Never present `curl -k` as browser evidence.
- Cite Apple/ArchWiki for any external-behavior claim.

phi^2 + phi^-2 = 3 | TRINITY
