# CLAUDE.md — tri-net agent instructions

Read together with SOUL.md and AGENTS.md. Repo-specific law always overrides generic tooling defaults.

## Golden Pipeline (MANDATORY)

All logic MUST follow this pipeline — NO exceptions:

```
.t27 spec → t27c parse/typecheck → t27c gen-rust → src/ (generated) → cargo build → deploy
```

### FORBIDDEN
- Writing `.rs` files by hand for any business logic (crypto, mesh, routing, wire format)
- Writing `.py`/`.sh` scripts on critical path
- Editing files under `gen/` (they are generated from `.t27` specs)
- Writing comments or identifiers in any language other than English
- Committing `.t27` specs without `test` or `invariant` blocks

### ALLOWED (non-pipeline)
- `docs/*.md` — documentation (English only)
- `smoke/*.sh` — test runner scripts (not business logic)
- `tools/` — hardware bring-up utilities (JTAG scripts, etc.)
- `Cargo.toml` — dependency manifest
- `.cargo/config.toml` — build configuration
- Hardware-specific configs (`uEnv.txt`, `BOOT.BIN` handling)

### Source of Truth
- `.t27` specs in `specs/` are the SINGLE SOURCE OF TRUTH
- `src/` Rust code is GENERATED from specs (except thin binary wrappers in `src/bin/`)
- `gen/` is read-only output of t27c
- No logic duplication between spec and code

## Hardware target
- 3x P201Mini (Zynq 7020 + AD9361, armv7l, Linux 5.10)
- SSH: `sshpass -p analog ssh -o PubkeyAuthentication=no root@192.168.1.{11,12,13}`
  (quote each `-o` separately; an unquoted options variable breaks ssh parsing.
  Boards get reflashed, so host keys change: add `-o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null`. No scp server on the busybox rootfs — upload
  with `cat file | ssh ... 'cat > /root/x && chmod +x /root/x'`.)
- Cross-compile: `cargo zigbuild --release --target armv7-unknown-linux-musleabihf`
- Read SOUL.md Articles IV-V before touching a board. Radio inventory first:
  a board is only a radio node if `/sys/bus/iio/devices/*/name` contains
  `ad9361-phy` AND dmesg says "successfully initialized". Two are needed for a link.

## The phone app (`phone/`)

The macOS app is **TriNetMonitor — three tabs: Network | RTI Heatmap | Video Call**
(`TriNetMonitor.swift`). That shell is the product; never ship a single-view build
or drop a tab. `desktop/project.yml` lists sources explicitly — add new files there
and re-run `xcodegen generate`. The iOS target compiles a STATIC file list: never
regenerate it (it breaks signing); embed shared types into existing files instead.

**Launch it with `open -n /Applications/TriNetMonitor.app`.** Running the binary
directly (`.../Contents/MacOS/TriNetMonitor`) starts a process with NO WINDOW — it
looks like the app vanished. Logs no longer need that trick: `LogBus` tees stderr
into the in-app Log pane.

### Media invariants (each was a real, shipped bug)

Working audio is tagged `phone-v0.13-audio-works` — return to it if audio breaks.
Every rule below broke audio **silently**: no error, meters and counters healthy,
the far end simply hears nothing. Do not "clean up" any of them.

- **`converter.channelMap = [0]` when the input node has >1 channel.** Voice
  processing RE-TUNES the input layout: a 3-channel built-in mic becomes a NINE
  channel node. AVAudioConverter will not downmix an unlabelled 9->1 and yields
  SILENCE — which Opus then faithfully encodes into 10-byte frames while every
  counter looks fine. A 10B Opus frame means silence; a real one is ~40-60B.
- **Emit only whole 20ms frames (320-sample accumulator).** The tap's buffer is
  not a multiple of 320, and Opus cannot encode a partial frame: it declines and
  the code falls back to raw PCM. Measured, the remainder was only 12% of packets
  but **58% of audio bytes** — the fallback cost more than all the Opus saved.
- **Audio datagrams must stay under `maxPayload` (1200B).** The capture tap hands
  out whatever the device I/O buffer is (~100ms). An oversized audio packet
  silently enters the video fragmentation path.
- **Never send raw PCM on a constrained link.** 16k x 16-bit = 256 kbps EACH WAY.
  Opus (AudioToolbox, no dependency) gives ~63B per 20ms = 24.7 kbps, and fits the
  mesh's 70-byte fragment.
- **AVAudioEngine drops every tap when the graph reconfigures.** Observe
  `AVAudioEngineConfigurationChange` (+ iOS interruption / route /
  mediaServicesWereReset) and rebuild, or the mic dies ~200ms in, forever.
  Install taps with `format: nil` — a format snapshot taken before voice
  processing settles is stale, and that race IS the ~200ms death.
- **Voice processing goes on the CAPTURE engine only.** That is safe *because* the
  engines are split: a VPIO failure (-10875 on this Mac) can cost the mic, never
  the far end's audio. Do not merge the engines back.
- **`0xFA` is reserved for the framing layer.** Drop unknown subtypes; never hand
  them to the H.264 decoder.
- **Never fail silently in an audio path.** `guard let x = codec?.decode(f) else
  { return }` dropped every packet with no log — indistinguishable from "the peer
  isn't sending". Log the failure and count it.
- **Log what WENT OUT, not the flag.** `opus=\(opusEnabled)` printed beside a 642B
  raw packet claimed a 10x saving that never happened. Report the actual format.

### Verification
No two-endpoint rig exists yet. Prove codecs with a standalone `swiftc` harness
that round-trips through **naked wire bytes** (buffer-to-buffer hides packet
descriptions). Verify UI in the iOS Simulator (`simctl io ... screenshot`) rather
than editing layout blind.

## The mesh bridge (`src/bin/trios_meshd_video.rs`)

The daemon carries **opaque** datagrams: the app seals them end-to-end, so the
node cannot read the payload and must never assume it can. Every rule below was a
real defect, and every one of them was silent.

- **Demux by PORT, never by a magic byte.** The payload is ciphertext, and
  `ChaChaPoly.combined` is nonce||ciphertext||tag with a RANDOM nonce, so the
  first wire byte is uniformly distributed: `buf[0] == VSTREAM_TYPE` swallowed 1
  datagram in 256 (~every 2.5s on a live call). The spec's `MESH_PORT` exists for
  this. Any "unambiguous magic" claim dies the moment the channel is encrypted.
- **Rate limiting must be blind to payload size.** `spent + nfrags > LIMIT`
  drops whatever is biggest — which in H.264 is the IDR keyframe, the one frame
  a decoder cannot resume without, while the P-frames referencing it pass. A PLI
  storm then answers each drop with a bigger IDR. Decide admission *before*
  looking at the size, then let the count run into debt.
- **A budget is not a rate. PACE the fragments.** Enforcing only "N per second"
  makes the AVERAGE right while the INSTANTANEOUS rate is ~100x the target: a
  whole NAL leaves in under a millisecond and the link idles for the rest of the
  second. Measured: a 138-packet NAL burst cost 44 packets at the peer's socket
  buffer (~140 small packets), and a 480 kbps radio queue drops the same way. A
  9000B I-frame paced at 800 frags/s takes 172ms — that is what 480 kbps costs,
  not a bug.
- **Parity trails its data on the wire.** Dropping a reassembly entry the moment
  it is delivered lets a late parity re-create it, "repair" the payload out of
  the parity alone (for a one-fragment group the parity IS the fragment) and
  deliver a DUPLICATE. Keep entries until the GC sweeps them.
- **Count repairs across the whole payload, not per packet.** `repair_groups`
  runs per packet and each parity fixes its own group, so the last call returns
  1 no matter how many were saved — a NAL rescued from 9 losses logged
  "repaired 1". FEC exists to make loss survivable; a counter that hides the
  loss by 9x defeats the point of having it.
- **The node is a relay AND an endpoint.** One `dest` for both "next hop" and
  "my device" only works on a linear test rig. Learn the device's address from
  its ingress; never default it to `127.0.0.1` (send_to succeeds and the payload
  silently never leaves the node).
- **A length is knowable — never guess it from the payload.** Reassembly once
  sized NALs by trimming trailing zeros; H.264 ends in 0x00 constantly. Record
  the last fragment's length and compute it.
- **`recv_from` does not report truncation.** It returns a short read. Size the
  buffer to the largest payload you claim to support, or every I-frame is quietly
  maimed and the log cheerfully prints the truncated size.
- **Log the number the decision is made on.** The rate limiter's budget was
  printed nowhere and drops printed only every 10th, so a dropped keyframe left
  no trace and no experiment could see the counter it was trying to measure.
  Instrument first — a probe against invisible state is the broken-ruler error.
- **The radio's capacity has never been measured** (only one AD9361 has ever come
  up at a time). `FRAG_RATE_PER_SEC` is a guess; treat it as one.

## Validation
- `../t27/target/release/t27c parse <file>` — 0=ok (dumps the whole AST to
  stdout; redirect it). This path is what `build.rs` uses; there is no
  `bootstrap/` directory in this repo, the compiler lives in the sibling `t27`
  repo.
- `cargo build --release` — must compile. **`build.rs` regenerates `gen/` from
  `specs/` whenever t27c is present, and silently skips when it is not.**
- `cargo test` — all tests pass
- Smoke on hardware: deploy + run on P201Mini

### gen/ is a trap — do not "clean up" a dirty gen/

The committed contents of `gen/` **do not compile**. The local t27c has drifted
from whatever produced them (it now emits `as u32` casts), so `cargo build`
rewrites 68 tracked files on every fresh checkout and the tree is permanently
dirty. `git checkout -- gen/` looks like tidying and **breaks the build**;
recover by touching `specs/*.t27` and rebuilding. The `no-gen-edits` hook then
forbids committing the working versions, so the contradiction cannot be resolved
from inside this repo.

16 of the 84 generated modules — including `video_bridge.rs`, which the whole
mesh bridge depends on — are **untracked**, with no ignore rule. This repo builds
only on a machine with the `t27` repo beside it.

phi^2 + phi^-2 = 3 | TRINITY
