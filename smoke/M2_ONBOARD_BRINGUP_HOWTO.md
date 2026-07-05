# M2 step 2 — one-board bring-up: how to run

**Scope**: one P201/P203 Mini, real network interface (not loopback), single
`trios_meshd` instance. Property gate — NOT convergence (that is step 3).

**Anchor**: `phi^2 + phi^-2 = 3`

## What this run proves (and does NOT prove)

Proves on real ARM hardware:

- G1: daemon binds to a real interface (`IP:PORT`, not `127.0.0.1`)
- G2: HELLO/beacon loop alive (periodic neighbor-tick observed in log)
- G3: no crash markers in log
- G4: log output produced

Does NOT prove (still `-sim` until later steps):

- Neighbor discovery / ETX convergence — needs a second board (step 3)
- ETX stability under real radio noise — needs 2 boards + radio (step 3+)
- TUN/iperf3 throughput — step 4

README `-sim` flag **does not clear** after this run. It clears only after
step 4 (three boards + TUN + iperf3).

## Files

- `target/armv7-unknown-linux-gnueabihf/release/trios_meshd` — cross-built
  daemon, ELF 32-bit ARM EABI5, dynamically linked (uses
  `/lib/ld-linux-armhf.so.3` present on Zynq Mini rootfs)
- `smoke/m2_onboard_bringup.sh` — single run, POSIX sh, prints one JSON line
- `smoke/m2_onboard_bringup_n_runs.sh` — N=5 wrapper

## 10-minute run flow

On host (build already done in sandbox, sha256 recorded below):

```
scp target/armv7-unknown-linux-gnueabihf/release/trios_meshd  root@<mini>:/tmp/trios_meshd
scp smoke/m2_onboard_bringup.sh                                root@<mini>:/tmp/
scp smoke/m2_onboard_bringup_n_runs.sh                         root@<mini>:/tmp/
```

On the Mini:

```
chmod +x /tmp/trios_meshd /tmp/m2_onboard_bringup.sh /tmp/m2_onboard_bringup_n_runs.sh
ip -4 -o addr                                        # note the real iface name
BIN=/tmp/trios_meshd IFACE=eth0 DURATION=4 /tmp/m2_onboard_bringup.sh
# if that PASSes, run the N=5 wrapper (put both scripts in same dir):
BIN=/tmp/trios_meshd IFACE=eth0 DURATION=4 N=5 /tmp/m2_onboard_bringup_n_runs.sh
```

Replace `eth0` with the actual interface (`ip -4 -o addr` shows the real
name; on some Mini images it may be `enp0s3`, `wlan0`, or a bridge).

## Expected output

Each run prints one JSON line, exit 0 on PASS. Example (from sandbox
`x86_64` sanity run against `eth0` with the `x86_64` binary — real Mini
output will differ in `uname` and `bin_sha256`):

```json
{"verdict":"PASS","fail_reason":"","iface":"eth0","ip":"169.254.0.21","port":5011,"node_id":11,"duration_s":4,"daemon_rc":143,"bin":"./target/release/trios_meshd","bin_sha256":"7f0c...","uname":"Linux 6.1.155+ x86_64","log_lines":5,"bind_evidence":1,"beacon_ticks":4,"crash_marks":0,...}
```

- `daemon_rc=143` = 128 + 15 (SIGTERM) — expected, we send TERM after the
  DURATION window.
- `bind_evidence >= 1` — G1 hit
- `beacon_ticks >= 1` — G2 hit
- `crash_marks == 0` — G3 hit

## FAIL modes — what to do

Return the JSON as-is; each `fail_reason` maps to one exact issue:

- `iface_lookup` / `err: no IPv4 on interface` → wrong `IFACE=` value, check
  `ip -4 -o addr`
- `iface_lookup` / `err: loopback rejected` → you passed `lo`, don't
- `binary_check` → binary not scp'd or not chmod +x
- `no_log_output` → daemon didn't write anything; capture `strace -f` or
  `ldd /tmp/trios_meshd` to find missing lib
- `no_bind_evidence` → daemon started but couldn't bind; typically port in
  use or interface without IPv4 at run-time; try another `PORT=` or
  another `IFACE=`
- `no_beacon_loop_evidence` → bound but crashed inside main loop; log is
  at `log_path` in the JSON, dump it
- `crash_markers_in_log` → panic; log contains the stack

## Cross-build reproducibility

Build performed in sandbox (2026-07-06):

- toolchain: `stable-x86_64-unknown-linux-gnu` (rustc 1.96.1)
- target: `armv7-unknown-linux-gnueabihf` via `rustup target add`
- linker: `arm-linux-gnueabihf-gcc` (15.2.0)
- command: `cargo build --bin trios_meshd --release --target armv7-unknown-linux-gnueabihf`
- output: `target/armv7-unknown-linux-gnueabihf/release/trios_meshd`
- size: 703356 bytes
- sha256: `24cfbdc9e7c811cfbc381fc84660afc281d382826ffe2b0a3429ab60eadfa4a2`
- `file`: `ELF 32-bit LSB pie executable, ARM, EABI5 version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-armhf.so.3, for GNU/Linux 3.2.0, not stripped`

Verify locally after `scp`:

```
sha256sum /tmp/trios_meshd   # must equal 24cfbdc9e7c811cfbc381fc84660afc281d382826ffe2b0a3429ab60eadfa4a2
```

Sandbox host-sanity result (x86_64 binary against real eth0, `169.254.0.21`,
DURATION=4, N=5):

- passed: 5/5
- log_lines per run: 5
- bind_evidence per run: 1
- beacon_ticks per run: 4
- crash_marks per run: 0

Same gate script running with the armv7 binary on the Mini should produce
analogous numbers (different `bin_sha256`, different `uname`, same PASS
verdict per run).

phi^2 + phi^-2 = 3
