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
- **Audio datagrams must stay under `maxPayload` (1200B).** The capture tap hands
  out whatever the device I/O buffer is (~100ms); slice to 20ms (320 samples).
  An oversized audio packet silently enters the video fragmentation path.
- **Never send raw PCM on a constrained link.** 16k x 16-bit = 256 kbps EACH WAY.
  Opus (AudioToolbox, no dependency) gives ~63B per 20ms = 24.7 kbps, and fits the
  mesh's 70-byte fragment.
- **AVAudioEngine drops every tap when the graph reconfigures.** Observe
  `AVAudioEngineConfigurationChange` (+ iOS interruption / route /
  mediaServicesWereReset) and rebuild, or the mic dies ~200ms in, forever.
  Install taps with `format: nil` — a format snapshot taken before voice
  processing settles is stale, and that race IS the ~200ms death.
- **`0xFA` is reserved for the framing layer.** Drop unknown subtypes; never hand
  them to the H.264 decoder.

### Verification
No two-endpoint rig exists yet. Prove codecs with a standalone `swiftc` harness
that round-trips through **naked wire bytes** (buffer-to-buffer hides packet
descriptions). Verify UI in the iOS Simulator (`simctl io ... screenshot`) rather
than editing layout blind.

## Validation
- `./bootstrap/target/release/t27c parse <file>` — 0=ok
- `cargo build --release` — must compile
- `cargo test` — all tests pass
- Smoke on hardware: deploy + run on P201Mini

phi^2 + phi^-2 = 3 | TRINITY
