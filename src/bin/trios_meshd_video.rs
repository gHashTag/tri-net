//! trios_meshd_video — UDP datagram bridge for P203 mesh nodes.
//!
//! A node carries opaque datagrams between an attached device (phone/Mac) and a
//! peer node. The payload is sealed end-to-end by the app, so this daemon can
//! NOT read it and must never try: it fragments whatever arrives into VSTREAM
//! packets small enough for the radio, relays them, and reassembles on the far
//! side.
//!
//! Two directions, two sockets, two ports — never one port with a magic byte
//! (see PORTS below):
//!
//!   device --(VIDEO_IN_PORT 7000)--> [node] --(MESH_PORT 5000)--> [peer node]
//!   [peer node] --(MESH_PORT 5000)--> [node] --(VIDEO_OUT_PORT 7001)--> device
//!
//! Wire format per fragment (from gen/rust/video_bridge.rs):
//!   [VSTREAM_TYPE:1][seq_lo:1][seq_hi:1][frag_idx:1][frag_count:1][data:≤70]
//!
//! Usage:
//!   trios_meshd_video <listen_addr> <peer_addr> [device_addr]
//!   e.g. trios_meshd_video 0.0.0.0:7000 192.168.1.12
//!
//!   device_addr is optional: the node LEARNS it from the first datagram the
//!   attached device sends. Pass it explicitly only for a relay that has no
//!   device of its own (e.g. a test rig).
//!
//! Environment:
//!   VIDEO_OUT_PORT (default 7001) — port on the device that receives payloads.
//!   FRAG_RATE_PER_SEC (default 800) — fragments/sec ceiling, see RATE below.
//!
//! phi^2 + phi^-2 = 3

use std::collections::HashMap;
use std::env;
use std::net::{SocketAddr, UdpSocket};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use trios_mesh::video_bridge;

/// Outbound VSTREAM fragments are tiny (5B header + <=70B payload), but this
/// buffer also receives INBOUND payloads from the device, and an I-frame is
/// 3-10 KB. It used to be 1500, which silently truncated every payload above
/// that: the log read "TX 1500B" for a 9000B frame and the peer reassembled a
/// maimed I-frame. recv_from does not error on truncation — it just hands back
/// a short read — so nothing anywhere reported it. Sized to MAX_NAL, which is
/// what the code already claimed to support.
const MAX_NAL: usize = 65_535;
const MAX_PACKET: usize = MAX_NAL;

/// RATE. Fragments/sec ceiling, ~75B each => 800/s is ~60 KB/s ~= 480 kbps.
/// This is a GUESS at the radio's capacity, which has never been measured
/// (only one AD9361 has ever come up at a time). Override via env once a real
/// link exists; do not treat the default as a measurement.
const DEFAULT_FRAG_RATE_PER_SEC: u32 = 800;

/// Per-sequence reassembly state (loss-resistant: tracks which fragments came).
struct ReassemblyState {
    expected_frags: u8,
    received: Vec<bool>,
    data: Vec<u8>,
    /// Byte length of the FINAL fragment. The total size is
    /// (count-1)*MAX_FRAG_DATA + last_len — it cannot be inferred from the
    /// buffer contents (see the emit path). Carried by the last fragment AND
    /// by every parity, so losing the last fragment does not cost the length.
    last_len: Option<usize>,
    /// XOR parity per group. A group missing exactly one fragment is repairable.
    parity: HashMap<u8, Vec<u8>>,
    /// Groups repaired so far for this payload. Accumulated, because
    /// repair_groups runs per packet and each parity repairs its own group: the
    /// final call's return value is 1 no matter how many the parity actually
    /// saved, so reporting it made a 9-loss NAL read as a 1-loss NAL.
    repaired: u32,
    /// Already delivered. The entry outlives delivery until the GC sweeps it,
    /// because parity trails its data fragments on the wire: dropping the entry
    /// at delivery let a late parity re-create it from scratch, "repair" the
    /// whole NAL out of the parity alone (for a one-fragment group the parity
    /// IS the fragment) and deliver a DUPLICATE.
    done: bool,
    last_update: Instant,
}

/// Repair every group that is missing exactly one fragment.
///
/// Reassembly is all-or-nothing, so without this ONE lost 70-byte packet
/// destroys a whole NAL — and an I-frame is 129 packets. The XOR is over cells
/// padded to MAX_FRAG_DATA, which is why `data` is zero-initialised: a short
/// final fragment leaves the same zero padding the sender XORed over.
fn repair_groups(state: &mut ReassemblyState) -> u32 {
    let max_data = video_bridge::MAX_FRAG_DATA as usize;
    let count = state.expected_frags;
    let mut repaired = 0;

    for group in 0..video_bridge::fec_group_count(count) {
        let Some(par) = state.parity.get(&group) else { continue };
        let first = video_bridge::fec_group_first(group) as usize;
        let len = video_bridge::fec_group_len(group, count) as usize;

        let mut missing = None;
        let mut missing_count: u8 = 0;
        for i in first..first + len {
            if !state.received[i] {
                missing_count += 1;
                missing = Some(i);
            }
        }
        if !video_bridge::fec_can_recover(missing_count) {
            continue; // 0 = nothing to do; 2+ = one XOR cannot separate them
        }
        let lost = missing.expect("fec_can_recover(1) implies one missing index");

        let mut cell = par.clone();
        for i in first..first + len {
            if i == lost {
                continue;
            }
            for b in 0..max_data {
                cell[b] ^= state.data[i * max_data + b];
            }
        }
        state.data[lost * max_data..lost * max_data + max_data].copy_from_slice(&cell);
        state.received[lost] = true;
        repaired += 1;
    }
    repaired
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: {} <listen_addr> <peer_addr> [device_addr]", args[0]);
        eprintln!("  listen: 0.0.0.0:7000     (attached device sends payloads here)");
        eprintln!("  peer:   192.168.1.12     (next mesh hop; fragments go to its port 5000)");
        eprintln!("  device: 192.168.1.105    (optional — learned from ingress if omitted)");
        std::process::exit(1);
    }
    let listen_addr = &args[1];
    let peer_ip: std::net::IpAddr = args[2]
        .split(':')
        .next()
        .unwrap_or(&args[2])
        .parse()
        .expect("peer must be a bare IP address");
    let out_port: u16 = env::var("VIDEO_OUT_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(video_bridge::VIDEO_OUT_PORT);
    let frag_rate: u32 = env::var("FRAG_RATE_PER_SEC")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_FRAG_RATE_PER_SEC);
    // Sender-side kill switch. A receiver needs no flag: no parity arrives, so
    // nothing is repaired. Exists so the parity's benefit can be A/B measured on
    // one binary and one link instead of argued from arithmetic.
    let fec_enabled = env::var("FEC").map(|v| v != "0").unwrap_or(true);

    // PORTS. The device's payload and the peer's fragments MUST arrive on
    // different ports. This used to be one socket that told them apart by
    // `buf[0] == VSTREAM_TYPE` (8) — but the app seals every datagram with
    // ChaChaPoly, whose `.combined` layout is nonce||ciphertext||tag and whose
    // nonce is RANDOM. So one datagram in 256 starts with 0x08 and was
    // swallowed as a mesh fragment: at ~100 datagrams/sec, a corruption every
    // ~2.5 seconds, forever, at random. A magic byte cannot demux a channel
    // that carries ciphertext. The spec already declared MESH_PORT for exactly
    // this and the daemon simply never used it.
    let app_sock = UdpSocket::bind(listen_addr).expect("bind device listen");
    let mesh_sock = UdpSocket::bind(("0.0.0.0", video_bridge::MESH_PORT)).expect("bind mesh");
    let peer_mesh = SocketAddr::new(peer_ip, video_bridge::MESH_PORT);

    // The attached device announces itself by sending. Pinning this to
    // 127.0.0.1 (as it once was) meant a reassembled payload never left the
    // node and the attached phone could never receive anything — silently,
    // because send_to(127.0.0.1) succeeds.
    let device: Mutex<Option<SocketAddr>> = Mutex::new(
        args.get(3)
            .and_then(|a| a.split(':').next())
            .and_then(|ip| ip.parse().ok())
            .map(|ip| SocketAddr::new(ip, out_port)),
    );

    let started = Instant::now();
    println!(
        "[video] bridge {listen_addr} <-> peer {peer_mesh} | device port {out_port} \
         (device: {}) | rate {frag_rate} frags/s | FEC {}",
        match *device.lock().unwrap() {
            Some(d) => format!("pinned {}", d.ip()),
            None => "awaiting ingress".to_string(),
        },
        if fec_enabled { "on" } else { "OFF" }
    );

    std::thread::scope(|s| {
        s.spawn(|| uplink(&app_sock, peer_mesh, &device, out_port, frag_rate, fec_enabled, started));
        s.spawn(|| downlink(&mesh_sock, &app_sock, &device, started));
    });
}

/// device -> mesh: fragment whatever arrives and relay it to the peer.
fn uplink(
    app_sock: &UdpSocket,
    peer_mesh: SocketAddr,
    device: &Mutex<Option<SocketAddr>>,
    out_port: u16,
    frag_rate: u32,
    fec_enabled: bool,
    started: Instant,
) {
    let mut rx_buf = vec![0u8; MAX_PACKET];
    let mut seq: u16 = 0;
    let mut spent: u32 = 0;
    let mut window_start = Instant::now();
    let mut dropped: u32 = 0;

    // PACING. A per-second budget alone makes the AVERAGE rate right while the
    // INSTANTANEOUS rate is ~100x the target: the whole NAL leaves in under a
    // millisecond and the link idles for the rest of the second. Measured: a
    // 138-packet NAL burst cost 44 packets at the peer's socket buffer
    // (RcvbufErrors), and a 480 kbps radio queue would drop the same way. Space
    // fragments one token apart so the wire sees the rate we actually promised.
    let slot = Duration::from_secs_f64(1.0 / frag_rate as f64);
    let mut next_slot = Instant::now();
    let mut send_paced = |sock: &UdpSocket, pkt: &[u8], to: SocketAddr| {
        let now = Instant::now();
        if next_slot > now {
            std::thread::sleep(next_slot - now);
        }
        sock.send_to(pkt, to).ok();
        // max(now) so an idle link does not bank credit and then blast.
        next_slot = next_slot.max(now) + slot;
    };

    loop {
        let now = Instant::now();
        if now.duration_since(window_start) >= Duration::from_secs(1) {
            // Carry unpaid debt into the next window rather than forgiving it,
            // so the average rate still holds; cap it at one window so a single
            // burst cannot stall the link for seconds.
            spent = spent.saturating_sub(frag_rate).min(frag_rate);
            window_start = now;
        }

        app_sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let (n, from) = match app_sock.recv_from(&mut rx_buf) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Learn where to deliver inbound payloads.
        {
            let mut d = device.lock().unwrap();
            if d.is_none() {
                let addr = SocketAddr::new(from.ip(), out_port);
                println!("[video] device attached: {} -> delivering inbound to {addr}", from.ip());
                *d = Some(addr);
            }
        }

        let size = n.min(MAX_NAL);
        let nfrags = video_bridge::fragment_count(size as u16);

        // Admission is decided BEFORE looking at the size. Testing
        // `spent + nfrags > rate` makes the BIGGEST payload the one that never
        // fits — and in H.264 the biggest NAL is the IDR keyframe, the one
        // frame a decoder cannot resume without, while the small P-frames that
        // reference it sail through. Measured on hardware: at budget=680/800 a
        // 129-frag payload was dropped and a 1-frag payload 10ms later passed,
        // with 120 fragments still free. The bridge cannot tell an IDR from a
        // P-frame anyway (the payload is sealed), so admission must be blind to
        // size: admit while the budget is open, then let the count run into
        // debt and pay it back next window.
        if spent >= frag_rate {
            dropped += 1;
            println!(
                "[video] DROP {size}B ({nfrags} frags) budget={spent}/{frag_rate} \
                 (dropped {dropped} total) t={:.1}s",
                started.elapsed().as_secs_f32()
            );
            continue;
        }

        seq = seq.wrapping_add(1);
        let max_data = video_bridge::MAX_FRAG_DATA as usize;
        for frag_idx in 0..nfrags {
            let offset = (frag_idx as usize) * max_data;
            let end = (offset + max_data).min(size);
            let chunk = &rx_buf[offset..end];

            let mut pkt = Vec::with_capacity(video_bridge::FRAG_HEADER_LEN as usize + chunk.len());
            pkt.push(video_bridge::VSTREAM_TYPE);
            pkt.push(video_bridge::seq_lo(seq));
            pkt.push(video_bridge::seq_hi(seq));
            pkt.push(frag_idx);
            pkt.push(nfrags);
            pkt.extend_from_slice(chunk);

            send_paced(app_sock, &pkt, peer_mesh);
            spent += 1;
        }

        // One XOR parity per group, so a single lost fragment does not destroy
        // the NAL. The parity is over cells padded to max_data — the same
        // padding a receiver's zero-initialised buffer reproduces.
        let last_len = size - (nfrags as usize - 1) * max_data;
        let ngroups = if fec_enabled { video_bridge::fec_group_count(nfrags) } else { 0 };
        for group in 0..ngroups {
            let first = video_bridge::fec_group_first(group) as usize;
            let len = video_bridge::fec_group_len(group, nfrags) as usize;

            let mut xor = vec![0u8; max_data];
            for i in first..first + len {
                let offset = i * max_data;
                let end = (offset + max_data).min(size);
                for (b, byte) in rx_buf[offset..end].iter().enumerate() {
                    xor[b] ^= byte;
                }
            }

            let mut pkt = Vec::with_capacity(video_bridge::fec_packet_size() as usize);
            pkt.push(video_bridge::VSTREAM_FEC_TYPE);
            pkt.push(video_bridge::seq_lo(seq));
            pkt.push(video_bridge::seq_hi(seq));
            pkt.push(group);
            pkt.push(nfrags);
            pkt.push(last_len as u8);
            pkt.extend_from_slice(&xor);

            send_paced(app_sock, &pkt, peer_mesh);
            spent += 1; // parity is not free; it pays from the same budget
        }

        println!(
            "[video] TX {size}B -> {nfrags} frags + {ngroups} parity (seq={seq}) from {from} \
             budget={spent}/{frag_rate} t={:.1}s",
            started.elapsed().as_secs_f32()
        );
    }
}

/// mesh -> device: reassemble the peer's fragments and deliver to the device.
fn downlink(
    mesh_sock: &UdpSocket,
    out_sock: &UdpSocket,
    device: &Mutex<Option<SocketAddr>>,
    started: Instant,
) {
    let mut rx_buf = vec![0u8; MAX_PACKET];
    let mut reassembly: HashMap<u16, ReassemblyState> = HashMap::new();

    loop {
        let now = Instant::now();
        // Drop stale partial payloads (older than 2s = their fragments are lost).
        reassembly.retain(|_, st| now.duration_since(st.last_update) < Duration::from_secs(2));

        mesh_sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let n = match mesh_sock.recv_from(&mut rx_buf) {
            Ok((n, _)) => n,
            Err(_) => continue,
        };
        let is_parity = rx_buf[0] == video_bridge::VSTREAM_FEC_TYPE;
        let header = if is_parity {
            video_bridge::FEC_HEADER_LEN as usize
        } else {
            video_bridge::FRAG_HEADER_LEN as usize
        };
        // The mesh port carries VSTREAM only. An unknown type is dropped rather
        // than guessed at — a peer running an older daemon simply ignores parity
        // instead of feeding it to reassembly as data.
        if n < header || (!is_parity && rx_buf[0] != video_bridge::VSTREAM_TYPE) {
            continue;
        }

        let frag_seq = video_bridge::frag_seq(rx_buf[1], rx_buf[2]);
        let frag_idx = rx_buf[3]; // group_idx when is_parity
        let frag_count = rx_buf[4];
        if frag_count == 0 {
            continue;
        }
        let data_len = n - header;
        let payload = &rx_buf[header..n];

        let state = reassembly.entry(frag_seq).or_insert_with(|| ReassemblyState {
            expected_frags: frag_count,
            received: vec![false; frag_count as usize],
            data: vec![0u8; (frag_count as usize) * (video_bridge::MAX_FRAG_DATA as usize)],
            last_len: None,
            parity: HashMap::new(),
            repaired: 0,
            done: false,
            last_update: Instant::now(),
        });
        state.last_update = Instant::now();
        if state.done {
            continue; // already delivered; this is a trailing parity
        }
        state.expected_frags = frag_count; // in case the first fragment was lost

        if is_parity {
            // Every parity carries last_len, so losing the final fragment does
            // not also cost the NAL's length.
            state.last_len = Some(rx_buf[5] as usize);
            state.parity.insert(frag_idx, payload.to_vec());
        } else {
            let offset = (frag_idx as usize) * (video_bridge::MAX_FRAG_DATA as usize);
            if (frag_idx as usize) < state.received.len() && offset + data_len <= state.data.len() {
                state.data[offset..offset + data_len].copy_from_slice(payload);
                state.received[frag_idx as usize] = true;
                if video_bridge::is_last_fragment(frag_idx, frag_count) {
                    state.last_len = Some(data_len);
                }
            }
        }

        state.repaired += repair_groups(state);
        if !state.received.iter().all(|&r| r) {
            continue;
        }
        state.done = true;
        let repaired = state.repaired;
        let ngroups = video_bridge::fec_group_count(frag_count);

        // Size the payload from the LAST fragment's recorded length.
        //
        // This used to trim trailing zeros off the buffer as "a heuristic".
        // H.264 NALs routinely end in 0x00, so that silently truncated real
        // frames — a corruption no test caught because the fixtures happened
        // not to end in zero. The length is knowable exactly; never guess it
        // from the payload.
        let max_data = video_bridge::MAX_FRAG_DATA as usize;
        let count = state.expected_frags as usize;
        let total = match state.last_len {
            Some(last) => (count - 1) * max_data + last,
            // `all_received` cannot be true without the last fragment, so this
            // is unreachable — but drop rather than emit a guessed length.
            None => {
                reassembly.remove(&frag_seq);
                continue;
            }
        };

        match *device.lock().unwrap() {
            Some(dev) => {
                out_sock.send_to(&state.data[..total], dev).ok();
                // Report repairs: a silent FEC is indistinguishable from no loss,
                // and then nobody knows whether the link is healthy or the parity
                // is carrying it.
                let fec = if repaired > 0 {
                    format!(" [FEC repaired {repaired} of {ngroups} groups]")
                } else {
                    String::new()
                };
                println!(
                    "[video] RX seq={frag_seq} ({frag_count} frags, {total}B) -> {dev}{fec} t={:.1}s",
                    started.elapsed().as_secs_f32()
                );
            }
            None => println!(
                "[video] RX seq={frag_seq} ({total}B) DISCARDED: no device attached yet t={:.1}s",
                started.elapsed().as_secs_f32()
            ),
        }
    }
}
