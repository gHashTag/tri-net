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

phi^2 + phi^-2 = 3 | TRINITY
