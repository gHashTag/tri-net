//! Single-carrier BPSK modem — the radio PHY core for the 5.8 GHz drone-mesh link.
//!
//! Turns bytes into baseband IQ symbols and back, with a 13-chip **Barker**
//! preamble for frame synchronization and 180° phase-ambiguity resolution. The
//! frame is self-delimiting (a length byte precedes the payload), so the
//! receiver needs no external length. Host-testable over a simulated AWGN
//! channel (`-sim`); on hardware these symbols feed the AD9361 sample stream.
//! Single-carrier is the low-PAPR fallback while OFDM is the stretch target
//! (tri-net#9). References: Barker-13 sync (near-ideal autocorrelation).
//!
//! The [`tx_shaped`]/[`rx_recover`] sample layer wraps this symbol core with an
//! RRC pulse shape, feedforward symbol-timing recovery, and a data-aided CFO +
//! phase estimate off the Barker pilot — the band-limited, timing/CFO-tolerant
//! signal that actually feeds the AD9361 DAC/ADC. [`ModemTransport`] plugs that
//! into the mesh [`Transport`] so frames route over the modem instead of UDP.

use crate::daemon::Transport;
use num_complex::Complex32;
use std::collections::VecDeque;
use std::io;

/// Barker-13: near-ideal autocorrelation → robust frame sync at low SNR.
const BARKER13: [f32; 13] = [1., 1., 1., 1., 1., -1., -1., 1., 1., -1., 1., -1., 1.];
/// Coarse frame-sync gate on the Barker correlation (peak ≈ 13 for a clean,
/// CFO-free preamble). This is a *detector*, not a validator: at low SNR noise
/// can occasionally cross it, so a synced frame is only provisional — the
/// downstream AEAD (Poly1305) tag is the real accept/reject. See [`rx_recover`].
const SYNC_THRESHOLD: f32 = 8.0;

/// Largest frame the single-carrier modem carries: the frame length rides in one
/// BPSK-coded byte, so a frame must be ≤ 255 bytes. A mesh IP payload also pays
/// `Header::LEN + 8 (counter) + 16 (tag)` bytes of overhead on top of this.
pub const MAX_FRAME: usize = 255;

fn push_byte(sym: &mut Vec<Complex32>, byte: u8) {
    for i in 0..8 {
        let bit = (byte >> i) & 1;
        sym.push(Complex32::new(if bit == 1 { 1.0 } else { -1.0 }, 0.0));
    }
}

/// BPSK-modulate `payload` (≤255 bytes) into baseband symbols:
/// `[Barker-13 preamble][length byte][payload]`, one symbol per bit.
pub fn modulate(payload: &[u8]) -> Vec<Complex32> {
    assert!(payload.len() <= 255, "payload must be ≤ 255 bytes");
    let mut sym: Vec<Complex32> = BARKER13.iter().map(|&c| Complex32::new(c, 0.0)).collect();
    push_byte(&mut sym, payload.len() as u8);
    for &b in payload {
        push_byte(&mut sym, b);
    }
    sym
}

/// Find the Barker preamble in `samples`, then demodulate the length byte and
/// that many payload bytes. Resolves the BPSK 180° ambiguity from the preamble
/// correlation sign. `None` if no strong preamble or the frame runs off the end.
pub fn demodulate(samples: &[Complex32]) -> Option<Vec<u8>> {
    if samples.len() < BARKER13.len() + 8 {
        return None;
    }
    // 1) Frame sync: the Barker preamble leads the frame, so lock to the FIRST
    //    correlation excursion above threshold. A global argmax could be
    //    dethroned by a chance Barker match in the trailing payload (whose
    //    symbols, after matched filtering, are not exactly ±1).
    let last = samples.len() - BARKER13.len();
    let corr_at = |start: usize| -> Complex32 {
        let mut c = Complex32::new(0.0, 0.0);
        for (k, &chip) in BARKER13.iter().enumerate() {
            c += samples[start + k] * chip;
        }
        c
    };
    let mut start = 0;
    while start <= last && corr_at(start).norm() < SYNC_THRESHOLD {
        start += 1;
    }
    if start > last {
        return None;
    }
    // Keep climbing to the peak of this first above-threshold excursion.
    let mut corr = corr_at(start);
    let mut s = start + 1;
    while s <= last {
        let c = corr_at(s);
        if c.norm() < SYNC_THRESHOLD {
            break;
        }
        if c.norm() > corr.norm() {
            corr = c;
            start = s;
        }
        s += 1;
    }
    // 2) The preamble's real-part sign tells us whether the channel inverted us.
    let flip = corr.re < 0.0;
    let data = start + BARKER13.len();
    let decode = |sym_start: usize, out_len: usize| -> Option<Vec<u8>> {
        if sym_start + out_len * 8 > samples.len() {
            return None;
        }
        let mut bytes = Vec::with_capacity(out_len);
        for bi in 0..out_len {
            let mut v = 0u8;
            for i in 0..8 {
                let positive = samples[sym_start + bi * 8 + i].re > 0.0;
                v |= u8::from(positive ^ flip) << i;
            }
            bytes.push(v);
        }
        Some(bytes)
    };
    // 3) Length byte, then that many payload bytes.
    let len = decode(data, 1)?[0] as usize;
    decode(data + 8, len)
}

// ---------------------------------------------------------------------------
// Sample-domain layer: RRC pulse shaping + feedforward timing + data-aided CFO.
//
// The symbol core above is unchanged; this wraps it so the same Barker
// correlator now works on band-limited, timing- and carrier-offset-corrupted
// samples — what an AD9361 actually delivers. All estimates are one-shot and
// data-aided off the known Barker pilot (a short burst has no steady state to
// track), so there are no PLL/Gardner feedback loops.
// ---------------------------------------------------------------------------

/// Samples per symbol out of the shaping filter (also the ADC oversample).
const SPS: usize = 4;
/// Root-raised-cosine roll-off. 0.35 is the classic bandwidth/PAPR compromise.
const RRC_BETA: f32 = 0.35;
/// RRC support in symbols. `NTAPS = RRC_SPAN * SPS + 1 = 25`, group delay
/// `gd = (NTAPS-1)/2 = 12`; a TX+RX filter cascade delays symbol 0 to `2*gd = 24`.
const RRC_SPAN: usize = 6;

/// Energy-normalized (`sum(h²) = 1`) root-raised-cosine taps, `NTAPS` long and
/// symmetric. Normalizing to unit energy makes the matched-filter cascade a
/// raised cosine with a unit peak, so the clean Barker correlation stays ≈ 13
/// and [`SYNC_THRESHOLD`] transfers unchanged.
fn rrc_taps() -> Vec<f32> {
    let ntaps = RRC_SPAN * SPS + 1;
    let gd = (ntaps - 1) as f32 / 2.0;
    let beta = RRC_BETA;
    let pi = std::f32::consts::PI;
    let mut h = vec![0.0f32; ntaps];
    for (i, hv) in h.iter_mut().enumerate() {
        let t = (i as f32 - gd) / SPS as f32; // time in symbol units
        *hv = if t.abs() < 1e-6 {
            1.0 + beta * (4.0 / pi - 1.0)
        } else if ((4.0 * beta * t).abs() - 1.0).abs() < 1e-4 {
            // Removable singularity at t = ±1/(4β): use the L'Hôpital limit.
            let a = pi / (4.0 * beta);
            (beta / 2.0_f32.sqrt()) * ((1.0 + 2.0 / pi) * a.sin() + (1.0 - 2.0 / pi) * a.cos())
        } else {
            let num =
                (pi * t * (1.0 - beta)).sin() + 4.0 * beta * t * (pi * t * (1.0 + beta)).cos();
            let den = pi * t * (1.0 - (4.0 * beta * t).powi(2));
            num / den
        };
    }
    let norm = h.iter().map(|x| x * x).sum::<f32>().sqrt();
    for hv in h.iter_mut() {
        *hv /= norm;
    }
    h
}

/// Full linear convolution of a complex signal with real taps. Shared by the TX
/// pulse shaper and the RX matched filter (they use the same `rrc_taps`).
fn convolve(x: &[Complex32], taps: &[f32]) -> Vec<Complex32> {
    if x.is_empty() {
        return Vec::new();
    }
    let mut y = vec![Complex32::new(0.0, 0.0); x.len() + taps.len() - 1];
    for (i, &xi) in x.iter().enumerate() {
        for (j, &tj) in taps.iter().enumerate() {
            y[i + j] += xi.scale(tj);
        }
    }
    y
}

/// BPSK-modulate then RRC pulse-shape `payload` into `SPS`-oversampled baseband
/// samples ready for the AD9361 DAC: `modulate` → zero-stuff ×`SPS` → RRC.
///
/// Panics if `payload.len() > `[`MAX_FRAME`] (inherits [`modulate`]'s length
/// cap); callers handling untrusted sizes must check first — [`ModemTransport`]
/// does.
pub fn tx_shaped(payload: &[u8]) -> Vec<Complex32> {
    let syms = modulate(payload);
    let mut up = vec![Complex32::new(0.0, 0.0); syms.len() * SPS];
    for (k, &s) in syms.iter().enumerate() {
        up[k * SPS] = s;
    }
    convolve(&up, &rrc_taps())
}

/// Linear interpolation of the matched-filter output at a fractional index.
fn interp(mf: &[Complex32], x: f32) -> Complex32 {
    let i = x.floor() as usize;
    let frac = x - i as f32;
    let a = mf[i];
    let b = if i + 1 < mf.len() { mf[i + 1] } else { mf[i] };
    a.scale(1.0 - frac) + b.scale(frac)
}

/// Feedforward symbol timing: slide the Barker correlator over the matched
/// filter at `SPS`-spaced taps and lock to the *first* correlation excursion
/// above [`SYNC_THRESHOLD`], then a single parabolic sub-sample refine. Returns
/// the fractional index of symbol 0, or `None` if nothing crosses threshold.
///
/// It takes the first strong peak, not the global maximum: the Barker preamble
/// always leads the burst, and random payload symbols can ripple the (non-
/// integer) matched-filter output slightly above the preamble's own peak — a
/// global argmax would then lock onto mid-frame data.
fn find_timing(mf: &[Complex32]) -> Option<f32> {
    let span = BARKER13.len();
    let reach = (span - 1) * SPS;
    if mf.len() <= reach {
        return None;
    }
    let last = mf.len() - 1 - reach;
    let corr_at = |start: usize| -> f32 {
        let mut c = Complex32::new(0.0, 0.0);
        for (k, &chip) in BARKER13.iter().enumerate() {
            c += mf[start + k * SPS] * chip;
        }
        c.norm()
    };
    // Advance to the first sample that crosses threshold (the preamble's rising
    // edge), then take the peak of that excursion within a one-symbol window.
    let mut start = 0;
    while start <= last && corr_at(start) < SYNC_THRESHOLD {
        start += 1;
    }
    if start > last {
        return None;
    }
    let window = (start + 2 * SPS).min(last);
    let mut best = start;
    let mut best_mag = corr_at(start);
    for s in (start + 1)..=window {
        let m = corr_at(s);
        if m > best_mag {
            best_mag = m;
            best = s;
        }
    }
    // Parabolic vertex over the two ±1-sample neighbors (smooth ×SPS grid).
    let mu = if best >= 1 && best < last {
        let (ym1, yp1) = (corr_at(best - 1), corr_at(best + 1));
        let denom = ym1 - 2.0 * best_mag + yp1;
        if denom.abs() > 1e-6 {
            (0.5 * (ym1 - yp1) / denom).clamp(-0.5, 0.5)
        } else {
            0.0
        }
    } else {
        0.0
    };
    Some(best as f32 + mu)
}

/// Coherent absolute phase of the known Barker pilot given a carrier rate `w`:
/// strip the Barker signs, de-slope by `w`, take the mean angle. Anchored on
/// known symbols, so it is exact regardless of the payload decisions.
fn pilot_theta(pilot: &[Complex32], w: f32) -> f32 {
    let mut acc = Complex32::new(0.0, 0.0);
    for (k, (&s, &c)) in pilot.iter().zip(BARKER13.iter()).enumerate() {
        acc += s.scale(c) * Complex32::from_polar(1.0, -w * k as f32);
    }
    acc.arg()
}

/// Data-aided carrier acquisition off the 13-symbol Barker pilot. Stripping the
/// known signs leaves `A·exp(j(θ₀ + ω·k))`; a lag-1 differential gives ω
/// (radians/symbol), then [`pilot_theta`] gives θ₀. Because the strip happens
/// first, a 180° channel flip lands in θ₀ (constant) while CFO stays in ω
/// (slope), so the two never alias. Usable for `|ω| < π/13 ≈ 0.24 rad/sym`.
fn estimate_cfo_phase(pilot: &[Complex32]) -> (f32, f32) {
    let stripped: Vec<Complex32> = pilot
        .iter()
        .zip(BARKER13.iter())
        .map(|(&s, &c)| s.scale(c))
        .collect();
    let mut diff = Complex32::new(0.0, 0.0);
    for k in 1..stripped.len() {
        diff += stripped[k] * stripped[k - 1].conj();
    }
    let w = diff.arg();
    (w, pilot_theta(pilot, w))
}

/// Decision-directed residual carrier rate over an already-derotated frame:
/// hard-decide each BPSK symbol, strip it, take the lag-1 differential. The
/// differential measures only the phase *step* between neighbors, so it stays
/// accurate even where the residual has drifted past ±π and the hard decisions
/// flip — a slow drift flips adjacent decisions together and they cancel in the
/// product. This is what lets ω hold coherence across a long (many-symbol) frame.
fn dd_residual_omega(frame: &[Complex32]) -> f32 {
    let stripped: Vec<Complex32> = frame
        .iter()
        .map(|&s| s.scale(if s.re >= 0.0 { 1.0 } else { -1.0 }))
        .collect();
    let mut diff = Complex32::new(0.0, 0.0);
    for k in 1..stripped.len() {
        diff += stripped[k] * stripped[k - 1].conj();
    }
    diff.arg()
}

/// Derotate every symbol by `θ + ω·i`.
fn derotate(sym: &[Complex32], w: f32, theta: f32) -> Vec<Complex32> {
    sym.iter()
        .enumerate()
        .map(|(i, &s)| s * Complex32::from_polar(1.0, -(theta + w * i as f32)))
        .collect()
}

/// Recover the payload from RRC-shaped, timing/CFO-corrupted baseband samples:
/// matched filter → timing → decimate → data-aided carrier recovery → hand
/// ~±1 real symbols to [`demodulate`]. `None` if no preamble syncs.
///
/// Expects the samples of a *single* burst (one frame). It locks to the first
/// preamble it finds, so it is not yet a continuous-stream receiver — multi-burst
/// demux and idle-noise burst detection belong to the hardware RX layer.
/// Reliable for `|CFO| ≲ 0.03 cyc/symbol`; sync margin then degrades toward the
/// estimator's `π/13 ≈ 0.038` wall (the Barker peak itself shrinks under
/// uncompensated CFO), so the guaranteed-clean range is the tighter 0.03.
///
/// Carrier recovery is feedforward (no per-symbol tracking loop): acquire ω and
/// θ from the Barker pilot, then iterate a decision-directed whole-frame refine.
/// The 13-symbol pilot's ω estimate alone cannot stay phase-coherent across a
/// many-hundred-symbol frame; each refine pass re-derotates, remeasures the
/// residual ω over the (now better-decided) frame, and re-anchors θ on the
/// pilot — converging in a few passes so the frame tail stays bit-exact.
pub fn rx_recover(samples: &[Complex32]) -> Option<Vec<u8>> {
    let mf = convolve(samples, &rrc_taps());
    let grid0 = find_timing(&mf)?;
    let mut sym = Vec::new();
    let mut x = grid0;
    while x <= (mf.len() - 1) as f32 {
        sym.push(interp(&mf, x));
        x += SPS as f32;
    }
    let pilot_len = BARKER13.len();
    if sym.len() < pilot_len {
        return None;
    }
    let (mut w, mut theta) = estimate_cfo_phase(&sym[..pilot_len]);
    for _ in 0..4 {
        let dw = dd_residual_omega(&derotate(&sym, w, theta));
        w += dw;
        theta = pilot_theta(&sym[..pilot_len], w);
        if dw.abs() < 1e-5 {
            break;
        }
    }
    demodulate(&derotate(&sym, w, theta))
}

/// In-process burst loopback implementing the byte-level mesh [`Transport`]:
/// each `send` pulse-shapes one frame into its own IQ burst and queues it;
/// `recv` pops the oldest burst and recovers it. Modeling one discrete burst per
/// frame (not one merged sample stream) matches a real keyed radio transmission
/// and keeps queued frames from being concatenated and silently dropped. Host
/// only — the real radio swaps this queue for the AD9361 sample stream (cabled
/// loopback; no OTA under Thai rules).
#[derive(Default)]
pub struct ModemTransport {
    bursts: VecDeque<Vec<Complex32>>,
}

impl ModemTransport {
    pub fn new() -> Self {
        Self::default()
    }
}

impl Transport for ModemTransport {
    fn send(&mut self, frame: &[u8]) -> io::Result<()> {
        if frame.len() > MAX_FRAME {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "frame exceeds the 255-byte single-carrier modem limit",
            ));
        }
        self.bursts.push_back(tx_shaped(frame));
        Ok(())
    }

    fn recv(&mut self) -> io::Result<Vec<u8>> {
        let burst = self
            .bursts
            .pop_front()
            .ok_or_else(|| io::Error::new(io::ErrorKind::WouldBlock, "no burst queued"))?;
        rx_recover(&burst)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "burst failed to demodulate"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic Gaussian noise (LCG + Box–Muller) so tests are reproducible
    /// without a `rand` dependency.
    struct Awgn(u64);
    impl Awgn {
        fn unit(&mut self) -> f32 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((self.0 >> 40) as f32) / ((1u64 << 24) as f32)
        }
        fn gauss(&mut self) -> f32 {
            let u1 = self.unit().max(1e-7);
            let u2 = self.unit();
            (-2.0 * u1.ln()).sqrt() * (std::f32::consts::TAU * u2).cos()
        }
        fn apply(&mut self, sym: &[Complex32], sigma: f32) -> Vec<Complex32> {
            sym.iter()
                .map(|s| s + Complex32::new(sigma * self.gauss(), sigma * self.gauss()))
                .collect()
        }
    }

    #[test]
    fn clean_roundtrip_is_exact() {
        let msg = b"tri-net 5.8GHz";
        assert_eq!(demodulate(&modulate(msg)).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn frame_is_self_delimiting() {
        // Trailing garbage past the framed length must be ignored.
        let mut s = modulate(b"abc");
        s.extend(std::iter::repeat_n(Complex32::new(0.3, -0.2), 40));
        assert_eq!(demodulate(&s).as_deref(), Some(&b"abc"[..]));
    }

    #[test]
    fn sync_finds_preamble_after_leading_junk() {
        let mut s: Vec<Complex32> = (0..17)
            .map(|k| Complex32::new((k % 3) as f32 - 1.0, 0.1))
            .collect();
        s.extend(modulate(b"offset"));
        assert_eq!(demodulate(&s).as_deref(), Some(&b"offset"[..]));
    }

    #[test]
    fn phase_inversion_is_resolved() {
        // A 180° channel flip negates every sample; the preamble sign recovers it.
        let flipped: Vec<Complex32> = modulate(b"flipme").iter().map(|s| -s).collect();
        assert_eq!(demodulate(&flipped).as_deref(), Some(&b"flipme"[..]));
    }

    #[test]
    fn recovers_through_awgn() {
        let msg = b"noisy channel ok";
        let mut ch = Awgn(0xC0FFEE);
        let rx = ch.apply(&modulate(msg), 0.35); // high SNR → BER ~ 0
        assert_eq!(demodulate(&rx).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn pure_noise_finds_no_frame() {
        let mut ch = Awgn(0x1234);
        let noise = ch.apply(&vec![Complex32::new(0.0, 0.0); 200], 1.0);
        assert!(demodulate(&noise).is_none());
    }

    // --- sample-domain layer: RRC + timing + CFO + Transport --------------

    /// Delay a signal by `mu` fractional samples via linear interpolation.
    fn frac_delay(x: &[Complex32], mu: f32) -> Vec<Complex32> {
        (0..x.len())
            .map(|i| {
                let s = i as f32 + mu;
                let j = s.floor() as usize;
                let f = s - j as f32;
                let a = x.get(j).copied().unwrap_or(Complex32::new(0.0, 0.0));
                let b = x.get(j + 1).copied().unwrap_or(Complex32::new(0.0, 0.0));
                a.scale(1.0 - f) + b.scale(f)
            })
            .collect()
    }

    /// Apply a carrier frequency offset (`fcyc` cycles/symbol) + phase at the
    /// sample rate: per-sample rotation is `fcyc / SPS` cycles.
    fn apply_cfo(x: &[Complex32], fcyc: f32, phi0: f32) -> Vec<Complex32> {
        let two_pi = std::f32::consts::TAU;
        x.iter()
            .enumerate()
            .map(|(k, &s)| {
                s * Complex32::from_polar(1.0, phi0 + two_pi * fcyc * k as f32 / SPS as f32)
            })
            .collect()
    }

    #[test]
    fn rrc_taps_unit_energy_and_symmetric() {
        let h = rrc_taps();
        assert_eq!(h.len(), 25);
        let energy: f32 = h.iter().map(|x| x * x).sum();
        assert!((energy - 1.0).abs() < 1e-5, "energy = {energy}");
        for i in 0..h.len() {
            assert!((h[i] - h[h.len() - 1 - i]).abs() < 1e-6);
        }
        assert!((h[12] - 0.548).abs() < 0.01, "h[mid] = {}", h[12]);
    }

    #[test]
    fn clean_shaped_roundtrip_is_exact() {
        let msg = b"tri-net 5.8GHz";
        assert_eq!(rx_recover(&tx_shaped(msg)).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn recovers_through_fractional_delay() {
        let msg = b"fractional timing";
        let rx = frac_delay(&tx_shaped(msg), 0.4);
        assert_eq!(rx_recover(&rx).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn recovers_through_cfo_and_awgn() {
        let msg = b"noisy radio link";
        let rx = apply_cfo(&tx_shaped(msg), 0.01, 1.2);
        let mut ch = Awgn(0xC0FFEE);
        let rx = ch.apply(&rx, 0.06);
        assert_eq!(rx_recover(&rx).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn cfo_and_flip_do_not_alias() {
        // A 180° channel flip + CFO: the flip must land in θ₀, CFO in ω.
        let msg = b"flip+cfo";
        let flipped: Vec<Complex32> = tx_shaped(msg).iter().map(|&s| -s).collect();
        let rx = apply_cfo(&flipped, 0.01, 0.0);
        assert_eq!(rx_recover(&rx).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn recovers_through_delay_cfo_and_awgn() {
        let msg = b"delay+cfo+awgn";
        let rx = frac_delay(&tx_shaped(msg), 0.4);
        let rx = apply_cfo(&rx, 0.01, 0.7);
        let mut ch = Awgn(0xBEEF);
        let rx = ch.apply(&rx, 0.05);
        assert_eq!(rx_recover(&rx).as_deref(), Some(&msg[..]));
    }

    #[test]
    fn shaped_noise_false_alarm_rate_is_bounded() {
        // SYNC_THRESHOLD is a coarse detector, not a P_fa=0 floor: at σ=1.0 the
        // Barker correlation of pure noise clears it on a small fraction of
        // bursts (the AEAD tag is the real gate). Assert that fraction stays low
        // across many seeds rather than trusting one lucky seed to see nothing.
        let mut alarms = 0;
        for seed in 0..500u64 {
            let mut ch = Awgn(seed.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(1));
            let noise = ch.apply(&vec![Complex32::new(0.0, 0.0); 200], 1.0);
            if rx_recover(&noise).is_some() {
                alarms += 1;
            }
        }
        assert!(alarms < 25, "false-alarm rate {alarms}/500 exceeds 5%");
    }

    #[test]
    fn transport_iq_loopback() {
        let mut tp = ModemTransport::new();
        tp.send(b"mesh-over-radio").unwrap();
        assert_eq!(tp.recv().unwrap(), b"mesh-over-radio");
    }

    #[test]
    fn send_rejects_oversize_frame() {
        let mut tp = ModemTransport::new();
        assert!(tp.send(&vec![0u8; MAX_FRAME + 1]).is_err()); // would panic modulate
        assert!(tp.send(&vec![0u8; MAX_FRAME]).is_ok());
    }

    #[test]
    fn queued_bursts_recover_in_order() {
        // Three sends before any recv must yield all three frames in FIFO order,
        // not merge into one burst and drop two.
        let mut tp = ModemTransport::new();
        let frames: [&[u8]; 3] = [b"first", b"second frame", b"third-and-final"];
        for f in frames {
            tp.send(f).unwrap();
        }
        for f in frames {
            assert_eq!(tp.recv().unwrap(), f);
        }
        assert!(tp.recv().is_err()); // channel now empty
    }

    #[test]
    fn recovers_long_frame_tail_coherent() {
        // A long frame stresses carrier-phase coherence at the tail: a pilot-only
        // ω estimate would drift and corrupt the last bytes. The iterative
        // decision-directed refine must hold the whole 220-byte frame bit-exact
        // under delay + in-range CFO + noise.
        let msg: Vec<u8> = (0..220u32)
            .map(|i| i.wrapping_mul(37).wrapping_add(11) as u8)
            .collect();
        let rx = apply_cfo(&frac_delay(&tx_shaped(&msg), 0.4), 0.02, 0.9);
        let mut ch = Awgn(0x5EED);
        let rx = ch.apply(&rx, 0.05);
        assert_eq!(rx_recover(&rx).as_deref(), Some(&msg[..]));
    }
}
