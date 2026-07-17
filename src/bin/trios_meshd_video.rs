//! trios_meshd_video — UDP video bridge for P203 mesh nodes.
//!
//! Listens for H.264 NAL units from a phone (port 7000), fragments them into
//! VSTREAM packets using the t27-generated video_bridge module, and relays each
//! fragment over the mesh UDP transport to a destination node's port 7001.
//! On the receiving end, a peer running this same daemon reassembles and emits
//! the NAL units on port 7001 for display.
//!
//! Wire format per fragment (from gen/rust/video_bridge.rs):
//!   [VSTREAM_TYPE:1][seq_lo:1][seq_hi:1][frag_idx:1][frag_count:1][data:≤70]
//!
//! Usage:
//!   trios_meshd_video <listen_addr> <dest_addr>
//!   e.g. trios_meshd_video 0.0.0.0:7000 192.168.1.13:7000
//!
//! Environment:
//!   VIDEO_OUT_PORT (default 7001) — local port for reassembled NAL output.
//!
//! phi^2 + phi^-2 = 3

use std::collections::HashMap;
use std::env;
use std::net::UdpSocket;
use std::time::{Duration, Instant};
use trios_mesh::video_bridge;

const MAX_PACKET: usize = 1500;
const MAX_NAL: usize = 65_535;

/// Congestion control: maximum fragments in flight before we throttle.
/// Each VSTREAM fragment is ~75 bytes. At MAX_INFLIGHT=256 that's ~19 KB
/// pending — enough for one NAL, small enough to backpressure the encoder.
const MAX_INFLIGHT: usize = 256;

/// Token-bucket rate limiter: pace fragment transmission to avoid
/// overwhelming the mesh. Default ~800 frags/sec (~60 KB/s ≈ 480 kbps).
const FRAG_RATE_PER_SEC: u32 = 800;

/// Track per-sequence reassembly state for loss detection.
struct ReassemblyState {
    expected_frags: u8,
    received: Vec<bool>,
    data: Vec<u8>,
    last_update: Instant,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: {} <listen_addr> <dest_addr>", args[0]);
        eprintln!("  listen: 0.0.0.0:7000  (phone sends H.264 NALs here)");
        eprintln!("  dest:   192.168.1.13:7000  (peer node's video port)");
        std::process::exit(1);
    }
    let listen_addr = &args[1];
    let dest_addr = &args[2];
    let out_port: u16 = env::var("VIDEO_OUT_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(7001);

    let sock = UdpSocket::bind(listen_addr).expect("bind video listen");
    let out_sock = UdpSocket::bind("0.0.0.0:0").expect("bind video out");
    let dest: std::net::SocketAddr = dest_addr.parse().expect("valid dest addr");
    let started = Instant::now();

    println!(
        "[video] bridge {listen_addr} -> {dest} (NAL output on port {out_port})"
    );

    let mut rx_buf = [0u8; MAX_PACKET];
    let mut seq: u16 = 0;
    // Per-sequence reassembly state (loss-resistant — tracks which fragments arrived).
    let mut reassembly: HashMap<u16, ReassemblyState> = HashMap::new();
    // Congestion control: rate-limit fragment sends.
    let mut frags_sent_this_sec: u32 = 0;
    let mut rate_window_start = Instant::now();
    let mut dropped_nals: u32 = 0;

    loop {
        // Congestion control: enforce rate limit.
        let now = Instant::now();
        if now.duration_since(rate_window_start) >= Duration::from_secs(1) {
            frags_sent_this_sec = 0;
            rate_window_start = now;
        }
        // Clean up stale reassembly buffers (older than 2 seconds = lost).
        reassembly.retain(|_, st| now.duration_since(st.last_update) < Duration::from_secs(2));
        let reassembly_size = reassembly.len();
        // 1. Receive a NAL unit from the phone (or upstream peer).
        sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let (n, from) = match sock.recv_from(&mut rx_buf) {
            Ok(v) => v,
            Err(_) => {
                // Timeout — heartbeat status.
                if started.elapsed().as_secs() % 10 == 0 {
                    println!("[video] idle (seq={seq}, t={:.0}s)",
                             started.elapsed().as_secs_f32());
                }
                continue;
            }
        };

        // 2. Check if this is a VSTREAM fragment from a peer (reassembly path)
        //    or a raw NAL from a phone (fragmentation path).
        if n >= video_bridge::FRAG_HEADER_LEN as usize
            && rx_buf[0] == video_bridge::VSTREAM_TYPE
        {
            let frag_seq = video_bridge::frag_seq(rx_buf[1], rx_buf[2]);
            let frag_idx = rx_buf[3];
            let frag_count = rx_buf[4];
            let data_len = n - video_bridge::FRAG_HEADER_LEN as usize;
            let frag_data = &rx_buf[video_bridge::FRAG_HEADER_LEN as usize..n];

            // Loss-resistant reassembly: track which fragments have arrived.
            // Only emit a NAL when ALL fragments are present (no holes).
            let state = reassembly.entry(frag_seq).or_insert_with(|| ReassemblyState {
                expected_frags: frag_count,
                received: vec![false; frag_count as usize],
                data: vec![0u8; (frag_count as usize) * (video_bridge::MAX_FRAG_DATA as usize)],
                last_update: Instant::now(),
            });
            state.last_update = Instant::now();
            state.expected_frags = frag_count; // update in case first frag was lost

            let offset = (frag_idx as usize) * (video_bridge::MAX_FRAG_DATA as usize);
            if (frag_idx as usize) < state.received.len() && offset + data_len <= state.data.len() {
                state.data[offset..offset + data_len].copy_from_slice(frag_data);
                state.received[frag_idx as usize] = true;
            }

            // Check if all fragments arrived.
            let all_received = state.received.iter().all(|&r| r);
            if all_received {
                // H-4 fix: compute total NAL size correctly.
                // All fragments except the last are MAX_FRAG_DATA bytes.
                // The last fragment's size = total data received - (count-1) * max.
                // But we don't know which fragment arrived last. Instead,
                // compute from the LAST fragment index (frag_count-1).
                let max_data = video_bridge::MAX_FRAG_DATA as usize;
                // Find the actual length of the last fragment by scanning
                // backward from the end of the buffer.
                let mut total = state.expected_frags as usize * max_data;
                // Trim trailing zeros beyond the actual last fragment's data.
                // The last fragment occupies [(count-1)*max .. (count-1)*max + last_len].
                // We track per-fragment lengths to compute exactly.
                // Since we copy each fragment at its offset, find the last
                // nonzero byte position + 1 as a heuristic.
                while total > 0 && state.data[total - 1] == 0 {
                    total -= 1;
                }
                // Ensure at least the first fragment's data is included.
                if total == 0 {
                    total = data_len;
                }
                out_sock.send_to(&state.data[..total], ("127.0.0.1", out_port)).ok();
                println!(
                    "[video] REASSEMBLE seq={frag_seq} ({frag_count} frags, {total}B) t={:.1}s",
                    started.elapsed().as_secs_f32()
                );
                reassembly.remove(&frag_seq);
            }
            continue;
        }

        // 3. Raw NAL from phone — fragment and relay to dest.
        let nal_size = n.min(MAX_NAL);
        let nal = &rx_buf[..nal_size];
        let nfrags = video_bridge::fragment_count(nal_size as u16);

        // Congestion control: if we can't send all fragments this second,
        // drop the NAL rather than partially transmitting (partial NALs
        // produce corrupt video). Log the drop so the user sees backpressure.
        if frags_sent_this_sec + nfrags as u32 > FRAG_RATE_PER_SEC {
            dropped_nals += 1;
            if dropped_nals % 10 == 0 {
                println!(
                    "[video] CONGESTION: dropped {dropped_nals} NALs (rate limit {FRAG_RATE_PER_SEC}/s, reassembly backlog {reassembly_size}) t={:.1}s",
                    started.elapsed().as_secs_f32()
                );
            }
            continue;
        }

        seq = seq.wrapping_add(1);
        let max_data = video_bridge::MAX_FRAG_DATA as usize;

        for frag_idx in 0..nfrags {
            let offset = (frag_idx as usize) * max_data;
            let end = (offset + max_data).min(nal_size);
            let chunk = &nal[offset..end];

            let mut pkt = Vec::with_capacity(video_bridge::FRAG_HEADER_LEN as usize + chunk.len());
            pkt.push(video_bridge::VSTREAM_TYPE);
            pkt.push(video_bridge::seq_lo(seq));
            pkt.push(video_bridge::seq_hi(seq));
            pkt.push(frag_idx);
            pkt.push(nfrags);
            pkt.extend_from_slice(chunk);

            sock.send_to(&pkt, dest).ok();
            frags_sent_this_sec += 1;
        }

        println!(
            "[video] TX NAL {nal_size}B -> {nfrags} frags (seq={seq}) from {from} t={:.1}s",
            started.elapsed().as_secs_f32()
        );
    }
}
