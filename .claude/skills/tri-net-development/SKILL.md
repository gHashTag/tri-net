# Skill: tri-net-development

## Description
Complete development workflow for the TRI-NET FPGA mesh communication project (github.com/gHashTag/tri-net). Covers spec-first golden pipeline, hardware bring-up, security auditing, and autonomous development loops.

## When to Use
- Working on TRI-NET (tri-net repo) or trios-mesh implementation
- Writing .t27 specifications and generating Rust via t27c
- P201Mini board bring-up (Zynq 7020 + AD9361)
- Mesh network debugging and security auditing
- Writing specs for new features (ALWAYS before implementation)

## Core Rules (NON-NEGOTIABLE)

### Golden Pipeline (Article II)
```
specs/*.t27 -> t27c parse -> t27c gen-rust -> gen/rust/*.rs -> src/lib.rs
```
- **NEVER write .rs files by hand for business logic** (L6 violation)
- **NEVER edit files under gen/** (L2 violation)
- **ALWAYS write .t27 specs FIRST**, then generate
- src/bin/ and tools/ are ALLOWED to have logic

### Repository Structure
- **tri-net** (github.com/gHashTag/tri-net): THE repo. Specs, generated code, docs, tools.
- **trios-mesh** (github.com/gHashTag/trios-mesh): Runtime implementation crate (historical, pre-pipeline)

### t27c Compiler Location
```bash
export T27C=~/Desktop/PROJECTS/CLAUDE/t27/target/release/t27c
$T27C parse specs/foo.t27    # typecheck
$T27C gen-rust specs/foo.t27  # generate Rust -> stdout
```

### .t27 Format Key Patterns
- Module: `module Name { use base::types; ... }`
- Constants: `const NAME: u8 = 5;`
- Functions: `fn name(args) -> ret { ... return x; }`
- Mutable locals: `let x: u8 = 0; x = x + 1;`
- Tests: `test name { assert(cond, "msg"); }` or `test name given x = f() then x == y`
- Invariants: `invariant name assert COND`
- **No bool let bindings** (t27c can't generate them) — use u8 (0/1) instead
- **No byte arrays** — model as integer functions (header_byte(idx))

### Hardware (SOUL.md Article IV)
- Cold power cycle only (warm reboot hangs Zynq PS)
- SD boot is primary path (bypasses QSPI POR issue)
- UART: FT2232H channel B (NOT A), 115200 8N1, root/analog
- Boot switch position is IRRELEVANT for SD boot
- SSH: `sshpass -p analog ssh -o PreferredAuthentications=password root@192.168.1.1N`
- Boards get reflashed -> host keys change. Add `-o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null`. Quote EACH `-o` separately (an unquoted
  options variable breaks ssh parsing). No scp server on busybox: upload with
  `cat f | ssh ... 'cat > /root/f && chmod +x /root/f'`.

### TRAP: "just reflash it" (added 2026-07-17)
A board whose AD9361 is missing is NOT a flashing problem until proven so.
Measured on .11 (no radio) vs .12 (radio): **all four QSPI partitions**
(fsbl-uboot, uboot-env, nvmfs, qspi-linux = kernel+dtb+bitstream), the SD
(BOOT.BIN, devicetree.dtb), the 54-var u-boot env, and the live DT
(`adi,ad9364`, `2rx-2tx`, 40 MHz refclk) were **byte-identical**. Reflashing
identical bytes is a no-op that only risks the POR damage in Article IV.
- `ad9361_probe : enter` then `Division by zero` in `ad9361_rx_adc_setup` = the
  driver read a ZERO clock rate. With identical firmware that is PHYSICAL.
- **Radio state is not stable across power events**: .13 went from `xadc`-only to
  the full AD9361 stack with zero software change. ALWAYS re-measure the
  inventory before concluding. `reboot` does not reset the RF power domain — only
  a cold cycle clears a latched XO.
- Radio inventory check (do this FIRST):
  `ls /sys/bus/iio/devices/*/name | xargs cat` -> need `ad9361-phy`;
  `dmesg | grep -E "successfully initialized|Calibration TIMEOUT|Division by zero"`.
  A Calibration TIMEOUT means marginal, not healthy. **Two** healthy nodes are
  required for a link (SOUL Article V). OTA needs human confirmation; cabled
  (SMA + 30-40 dB attenuator) or simulated only.

### Debugging Doctrine (Article VIII)
1. Independent channel first (UART before network diagnosis)
2. Observability before mutation (read before write)
3. RTFM before reverse-engineering
4. Enumerate hypothesis classes (hardware/config/network)
5. Identity before shared medium (grep ethaddr)

## Feature Areas

### Specs by Domain (94 total)
- PHY: channel_t/p/v_modem, fpga_bpsk_tx, csma_timing
- FEC: reed_solomon, viterbi_k5, crc16
- Crypto: aes256_gcm, lite_crypto, key_management, trng
- Chat: chat_protocol, codec2_voice, pq, padding, store
- Routing: etx, mesh_routing, mesh_convergence, olsr
- Network: wire, tun, gateway, qos_scheduler, nat_traversal, mesh_metrics
- Link: link_budget, link_negotiation, link_quality_monitor
- System: health_monitoring, self_healing, fault_detection, production_deployment

### Daemon Environment Variables
```
TRIOS_TUN=1       IP-over-mesh (TUN device)
TRIOS_GATEWAY=1   Internet gateway for mesh
TRIOS_QOS=1       Priority scheduling
TRIOS_QPSK=1      QPSK modulation (2x throughput)
TRIOS_FEC=1       Viterbi FEC (100x fewer lost frames)
TRIOS_SCAN=1      Auto-scan clean channel
TRIOS_SEND=D:msg  Send text message
TRIOS_SENDFILE=D:path  Transfer file
TRIOS_FETCH=GW    Fetch internet via gateway
TRIOS_KEY=path    Real identity key (not derived)
TRIOS_TXGAIN=-12  TX gain for poor-isolation nodes
TRIOS_FREQ=hz     Fixed channel frequency
```

### Cross-Compile
```bash
brew unlink rust  # Homebrew shadows rustup
cargo zigbuild --release --target armv7-unknown-linux-musleabihf
```

### Key Scientific References
- ETX: Couto et al., SIGCOMM 2003
- CSMA: Bianchi, IEEE J-SAC 2000
- RS erasure: Bloemer et al., ICPP 1995
- Ratchet: Cohn-Gordon et al., IEEE S&P 2017
- PQXDH: Signal IETF draft + NIST FIPS 203
- Phase tracking: Mengali & D'Andrea, Springer 1997

## Common Mistakes (AVOID)
1. Writing Rust directly instead of .t27 specs
2. Writing to trios-mesh instead of tri-net
3. Using bool let in .t27 (use u8 0/1 instead)
4. Forgetting test/invariant blocks (L4 violation)
5. Committing non-ASCII characters (L3 violation)
6. Creating .sh/.py scripts (L7 violation)

## TRAP I: Vendor-Reference Anchor (hardware bring-up)

**The deadliest anchor in hardware bring-up:** using a reference design from the
WRONG FPGA vendor for the SAME peripheral module.

**Real case (2026-07-12, 20 hours lost):** AX7203 (Xilinx Artix-7) + AN430 LCD.
The AN430 ships with an Altera/Cyclone IV demo (`sd_sdram_lcd`, Quartus 2015).
Copied its timing logic verbatim. Three differences caused white screen for 20h:

| Setting | Altera demo (WRONG) | ALINX Xilinx demo (CORRECT) |
|---------|--------------------|-----------------------------|
| DCLK | `assign lcd_dclk = clk_clk` | `assign lcd_dclk = ~lcd_clk` |
| HSYNC/VSYNC | `assign lcd_hsync = 1'bz` | `assign lcd_hsync = hsync_r` |
| H_BackPorch | 45 | 2 |

One character (`~`) cost 20 hours. Vendor conventions for clock polarity and
sync signaling DIFFER. Altera non-inverted + high-Z; Xilinx inverted + active.

**Countermeasure:** Before iterating ANY hardware parameter, find a WORKING
reference design for the EXACT same FPGA family + peripheral combination.
GitHub `alinxalinx/AX7103` had `08_lcd_test` with correct values all along.
A single working `.bit` from the vendor eliminates entire hypothesis classes.

**Anti-pattern that extends debugging 10×:** iterating the search space you
THINK is wrong (pin mapping: 8 permutations) while the real bug is in a
dimension you never tried (clock polarity from wrong reference).

## REALM-CHECK DISCIPLINE (v1.5 — added 2026-07-13)

Before reporting numbers (compile errors, test counts, cargo verdicts) from
a local workspace, **always cite the full context**, not just the repo SHA:

1. **Host identity** — machine name or hostname
2. **Binary sha256** — `shasum -a 256 target/release/t27c` (or equivalent)
3. **Working tree state** — `git status --short` (clean? uncommitted? staged?)
4. **Exact command** — verbatim invocation that produced the number
5. **Repo SHA** — `git rev-parse HEAD`

Without all five, a reviewer in a different workspace cannot reproduce the
number and must treat it as a claim, not a measurement.

**Self-caught example (2026-07-13):** Three times in one session, numbers
from one workspace (macbook, 114-commits-ahead branch) were presented as
facts and caught by realm-check in another workspace. Pattern: stale binary
built from uncommitted working tree, branch divergence masked as "master",
cached build artifacts. Cost: ~40 minutes per incident to reconstruct
conditions. The fix is the 5-point citation above.

**Anti-anchor pattern #5 (overclaim source):** "cargo check gives 0 errors"
without binary sha256 + working tree state is a claim, not a measurement.
A reviewer who cannot reproduce it will (correctly) reject it.

## MEASUREMENT-SCOPE-MISMATCH (v1.5 — added 2026-07-13)

When two careful people measure the "same" thing and get wildly different
numbers, the cause is almost never "one is wrong" or "the system is too
complex." It is almost always **scope mismatch** — they measured with
different sets of fixes applied, different branches, or different modules
wired in.

**Self-caught examples (2026-07-13 cascade debugging):**

1. "let; regression on master" — I measured with 2 optimizer fixes applied,
   investigator measured with 3. Same commit SHA, different **uncommitted
   working tree**. My 275 errors was correct for my fix set; his 28 was
   correct for his. Neither was wrong — they measured **different scopes**.

2. "141→0" — real, but only on a branch with 114 commits containing all
   optimizer fixes together. On origin/main it was 4→4 (gen/rust already
   clean). Same repo, same spec files, different **branch context**.

3. "26 vs 28 errors" — same commit, same t27c, but macOS arm64 vs linux.
   Binary sha256 diverges (platform-specific codegen). ±2 count is platform
   noise, not a bug. **Binary sha is NOT a cross-env fingerprint** — use
   commit SHA + cargo output count ± epsilon instead.

**Rule:** When numbers disagree, before arguing about correctness, list
explicitly: (a) which fixes/patches are applied, (b) which branch, (c)
which modules are wired in lib.rs, (d) platform + toolchain version.
The disagreement almost always dissolves once scope is made explicit.

## REALM = COMMAND + SCOPE + POLICY (v1.6 — added 2026-07-13)

A "realm" is defined by THREE independent axes. Any difference in any
axis means the two measurements are in **different realms** and cannot
be directly compared:

1. **Command** — `cargo check` vs `cargo clippy` vs `cargo build`
2. **Scope** — `--lib` (library only) vs `--all-targets` (lib + bins + tests + benches)
3. **Warning policy** — default (warnings allowed) vs `-D warnings` (warnings = errors)

**Self-caught example (2026-07-13):** Optimizer fix'ы измерялись with
`cargo check --lib` (no `-D warnings`) = 26 errors. CI uses `cargo clippy
--all-targets -- -D warnings` = 424 errors. Both measurements were correct
in their own realm. The fix'ы worked (E0384/E0425 eliminated), but CI
requires clippy-clean codegen output — a different problem entirely.

**Rule:** Before claiming "CI will pass" or "N errors", state all three:
`(command, scope, policy)`. "26 errors" is meaningless without
"`(cargo check, --lib, default)`" attached.

phi^2 + phi^-2 = 3 | TRINITY

## THE PHONE APP (`phone/`) — added 2026-07-17

**The macOS product is TriNetMonitor: THREE tabs — Network | RTI Heatmap | Video
Call** (`TriNetMonitor.swift`). That shell IS the product. Never ship a
single-view build, never drop a tab. Regressions here are the most visible kind.

- `desktop/project.yml` lists sources explicitly -> add new files there, then
  `xcodegen generate`. Safe for the Mac (`CODE_SIGN_IDENTITY: "-"`).
- The **iOS target compiles a STATIC file list — never regenerate it** (it breaks
  signing: "No Account for Team"). Embed shared types into existing files
  (MeshCrypto, DS, BackgroundBlur, OpusCodec all live inside VideoPipeline.swift).
- **Launch with `open -n /Applications/TriNetMonitor.app`.** Running the binary
  directly (`.../Contents/MacOS/TriNetMonitor`) yields a process with NO WINDOW —
  it looks exactly like the app was deleted. Logs no longer justify that trick:
  `LogBus` tees stderr into the in-app Log pane.

### Media invariants (each was a real, shipped bug)
| Rule | Why |
|---|---|
| Audio datagram < `maxPayload` (1200B) — slice the tap to 20ms/320 samples | the tap returns ~100ms device buffers -> 3200B -> silently fragmented |
| Never raw PCM on a constrained link | 16k x 16bit = 256 kbps EACH WAY; Opus = 63B/20ms = 24.7 kbps and fits the mesh 70B fragment |
| Observe `AVAudioEngineConfigurationChange` (+ iOS interruption/route/mediaServicesReset) and rebuild | the engine stops and drops EVERY tap; mic died ~200ms in, forever |
| `installTap(format: nil)` | a format read before voice processing settles is stale — that race IS the 200ms death |
| `0xFA` is reserved for framing; drop unknown subtypes | handing unknown magic to the H.264 decoder caused a PLI/keyframe storm |

### Verification (no two-endpoint rig exists)
- Prove codecs with a standalone `swiftc` harness that round-trips through
  **naked wire bytes** — buffer-to-buffer hides packet descriptions and passes
  when the real path would return silence.
- Verify UI in the iOS Simulator (`simctl io <id> screenshot`), never edit layout
  blind. Control bars: equal-width `maxWidth: .infinity` cells, <=6 primary
  buttons (fixed widths overflow small phones).
- **Never call a wire change "backward-compatible" without testing a REAL old
  peer.** Gate new formats OFF until both ends run the new build.

## THE INVESTOR PITCH ARTIFACT (keep it current) — added 2026-07-18

There is ONE living pitch page for TRI-NET. It is in Russian, self-contained
HTML, and its source of truth lives in the repo:

- **Source:** `docs/pitch/tri-net-pitch.html`
- **Published (stable) URL:** https://claude.ai/code/artifact/2d7ed62c-592f-45a0-867c-2b76ebb6627a

**After any milestone that changes what the project can claim** (a new hardware
result, a corrected number, a boundary crossed or newly honest), UPDATE this
pitch — do not create a second one:

1. Edit `docs/pitch/tri-net-pitch.html` (Russian text; keep the existing design
   system, CSS variables, and both light/dark themes intact).
2. Republish to the SAME URL: call the Artifact tool with
   `file_path` = the repo file (or copy it to the session scratchpad first and
   publish that), and pass `url: "https://claude.ai/code/artifact/2d7ed62c-592f-45a0-867c-2b76ebb6627a"`
   so it redeploys in place instead of minting a new link. Keep the `📡` favicon
   and a stable `<title>` across redeploys.
3. Commit the source change to the repo.

**Rules for the pitch content:** every number must be a real, verified result
(no projections stated as facts); keep the honest "What is NOT done" section
current -- it is a feature, not a weakness, for a technical/investor audience;
mirror the milestone tables in `fpga/ternary/nn/on_chip/README.md` and the
`fpga/ternary/README.md` headline table. When a claim in the repo docs changes,
the pitch changes with it.

## STRATEGIC CONTEXT: SSI / IEC 61499 / ITU-T Network 2030 (added 2026-07-18)

TRI-NET is not just a drone-mesh -- it is a working silicon instance of the
compute+telecom convergence that a real Russian government track is asking for.
This context frames every milestone; keep it in mind when reporting or planning.

**The external opportunity.** A.L. Balyberdin (rutel@mail.ru, Novosibirsk,
Verilog/FPGA engineer) is building a DataFlow compute paradigm + deterministic
network for ITU-T SG-13 "Network 2030" and sovereign open ACS/APCS (АСУ ТП).
A signed PAO Rostelecom letter (RF gov order 3339-P) makes him an EXPERT in the
inter-industry working group for a sovereign OPEN industrial-control data bus (OCF)
-- with Rostelecom, NPC Elvis, Exara Group and others, under ITU-T SG-13, ISO/IEC
29181, GOST 58210. He specs an ASU_TP_SOM module: RISC-V compute + 4-port SSI
network controller + 80 programmable I/O pins on one 50x30mm module, IEC 61499
function blocks, ternary {0, 1, no-data} semantics, "wave of detonation" over a
mesh with per-node local memory (no RAM bottleneck), all sovereign + open.

**Why it maps 1:1 to what we built.** The week's tri-net work IS a hardware
instance of that paradigm: one Zynq-7020 = his ASU_TP_SOM (compute + radio/mesh +
PL I/O on one die); ternary sign-select {-1,0,+1} 0-DSP MAC = his {0,1,no-data}
firing rule; systolic wavefront + BER=0 DSSS link + Costas/timing recovery = his
SSI deterministic channel + FIFO+PLL clock recovery (ADC->DAC scenario);
weight-stationary PEs = his "no RAM bottleneck"; AI-driven CSMA MAC = IEC 61499
event-triggered function block; fully OPEN FPGA flow (no Vivado) = the sovereignty
requirement, with the loadable PS7 bitstream proving SoM-class integration.

**The living brief** (Russian): docs/integration/tri-net-asutp.html ->
https://claude.ai/code/artifact/3db909af-a869-45a1-9a8c-da9dbb565962 -- update it
(same-URL republish) when a milestone changes a parallel or number, same rule as
the pitch. We hold the ALU/radio/AI + open-flow + reproducibility layer; he holds
the SSI network fabric + the polyhedral "large-cycle extraction" math (his stage 5,
5+ years). Complementary, NOT a code merge -- "100% integration" = the parallels +
concrete bridges + plan in the brief, plus buildable pieces (semantics bridge,
ADC->DAC clock recovery on our timing-recovery path, AI over SSI). Never send email
or make external commitments on the user's behalf.

**$TRI DePIN + the 6G framing (added 2026-07-18).** The user's thesis: TRI-NET is a
DePIN -- node holders earn a $TRI token for real physical work (relaying mesh
traffic over the radio), Helium Proof-of-Coverage style. The on-node substrate is
`specs/tri_depin.t27` (Proof-of-Relay): a tamper-evident / order-sensitive / size-
bound / identity-bound / epoch-bound accumulator over forwarded-packet receipts,
from which a settlement layer mints $TRI. Multiply-free (T27 has no `*`) xorshift+
shift-add mixer. 14 invariants; seal diffusion 15.91/32 bits. The seal BINDS
total_bytes (a wave fix -- otherwise a node presents an honest acc/seal but claims
inflated bytes, since reward is paid on total_bytes). **Proven on real hardware
(2026-07-18, smoke/DEPIN_RELAY_HW_2026-07-18.md):** an armv7 musl meter (t27c
gen-rust in a thin wrapper, cargo zigbuild) run on node .12 mints a receipt over a
real file; x86 host and a 2nd ARM node (.13) recompute the seal BIT-EXACT;
byte-inflation and 1-byte content tamper both rejected. Cross-arch bit-exactness is
the settlement property. **This is accounting
logic, so it MUST live in a `.t27` spec through the golden pipeline -- never hand-
write it in Rust/Python (repo law + the `no-handwritten-logic` hook enforces it).**
Verify pattern (no `.sh` -- the `no-shell-scripts` hook forbids new shell scripts):
`t27c gen-rust specs/<x>.t27 > g.rs`, append Rust `#[test]` mirrors of the spec's
test blocks, `rustc --test -O g.rs` (release = production wrapping semantics), run.
Honest 6G answer: ITU-**R** IMT-2030 (Jun 2023) has 6 scenarios; TRI-NET fits 3
directly -- Integrated Sensing & Communication (our RF-sensing/RTI), AI & Communi-
cation (on-node AI), Ubiquitous Connectivity (mesh) -- and Hyper-Reliable Low-
Latency partially (deterministic clkrec). ITU-**T** SG-13 does the network
architecture side (Network 2030). The $TRI token and open sovereign flow are a
COMPLEMENTARY layer on top of the standard, NOT part of the standard -- say so; do
not claim the token is "in 6G".

**$TRI A+B+C proven on hardware (2026-07-18b, smoke/DEPIN_ABC_HW_2026-07-18.md).**
(A) Real network relay: node .13 serves the payload via `busybox httpd`, node .12
fetches over the wired net via `wget` and meters the received stream -- the boards
have NO `nc`/`socat`/python/`/dev/tcp`, only `wget`+`httpd`, so HTTP is the only
board-to-board transport. (B) `epoch_seal` is signed with Ed25519 (ed25519-dalek,
cross-compiled armv7 musl); verifiers use the PUBLIC key only (no shared secret).
Ed25519 is a crate PRIMITIVE (fine, like the mesh's ChaCha/X25519) -- the seal it
signs is still t27. (C) `specs/tri_settle.t27`: round aggregation + proportional
pool split (u64, floor div => no over-issuance), 8 invariants. Next real step:
the RF/over-the-air leg (raise the .13->.12 radio link, meter what the radio
forwarded) and wiring into the live mesh daemon; secure key storage; on-chain
issuance. Board hygiene: after httpd, `killall httpd` misses it (busybox name is
`busybox`) -- kill by pid; always leave TX LO pd=1.

phi^2 + phi^-2 = 3 | TRINITY
