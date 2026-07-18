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

phi^2 + phi^-2 = 3 | TRINITY
