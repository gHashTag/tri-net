// trios_meshd_video.rs — TRI-NET mesh daemon with UDP video bridge
//
// Adds phone video bridge to trios_meshd:
//   TRIOS_VIDEO_IN=0.0.0.0:7000  — phone sends H.264 NAL units here
//   TRIOS_VIDEO_OUT=phone_ip:7001 — mesh sends reassembled H.264 back to phone
//   TRIOS_VIDEO_DST=<node_id>    — destination mesh node for video
//
// Phone app (TriNetVideo iOS) sends H.264 NAL units via UDP.
// Daemon fragments them into VSTREAM packets and sends through the mesh.
// On the receiving side, VSTREAM fragments are reassembled by Playout
// and sent back to the phone app via UDP for display.

use std::env;
use std::net::UdpSocket;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

// App-layer type byte for video (matches vstream.rs)
const VSTREAM: u8 = 8;

// VSTREAM fragment header: [type][seq_lo][seq_hi][frag_idx][frag_count]
const VSTREAM_HDR: usize = 5;
const VFRAG_DATA: usize = 70; // max data bytes per fragment

fn main() {
    let cfg_path = env::args().nth(1).expect("usage: trios_meshd_video <config>");
    let video_in = env::var("TRIOS_VIDEO_IN").unwrap_or_else(|_| "0.0.0.0:7000".into());
    let video_out = env::var("TRIOS_VIDEO_OUT").unwrap_or_else(|_| "127.0.0.1:7001".into());
    let video_dst: u32 = env::var("TRIOS_VIDEO_DST")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(12);

    // Parse mesh config (same as trios_meshd)
    let (my_id, listen_addr, peers) = parse_cfg(&cfg_path);

    // Mesh socket
    let sock = Arc::new(
        UdpSocket::bind(&listen_addr).expect("mesh bind"),
    );

    // Video sockets
    let vsock_in = Arc::new(
        UdpSocket::bind(&video_in).expect("video-in bind"),
    );
    let vsock_out = UdpSocket::bind("0.0.0.0:0").expect("video-out bind");
    let vsock_out = Arc::new(vsock_out);

    // Parse video_out address
    let (out_ip, out_port): (std::net::IpAddr, u16) = {
        let parts: Vec<&str> = video_out.split(':').collect();
        let ip: std::net::IpAddr = parts[0].parse().expect("valid video-out ip");
        let port: u16 = parts.get(1).and_then(|p| p.parse().ok()).unwrap_or(7001);
        (ip, port)
    };
    let out_addr = std::net::SocketAddr::new(out_ip, out_port);

    // Build mesh router (simplified — no crypto for this bridge test)
    let router = Arc::new(Mutex::new(SimpleRouter::new(my_id, sock.clone())));

    // Register peers
    for (pid, addr) in &peers {
        let peer_addr = *addr;
        router.lock().unwrap().add_peer(*pid, peer_addr);
    }

    eprintln!("[video] mesh node {} listening on {}", my_id, listen_addr);
    eprintln!("[video] phone video-in: {}", video_in);
    eprintln!("[video] phone video-out: {} ({})", video_out, out_addr);
    eprintln!("[video] video dst: node {}", video_dst);

    // === Thread 1: Phone H.264 → Mesh (fragment + send) ===
    {
        let router = router.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 65536];
            let mut seq: u16 = 0;
            loop {
                match vsock_in.recv_from(&mut buf) {
                    Ok((n, src)) => {
                        if n <= 4 { continue; } // too small for NAL unit
                        eprintln!("[video-in] {} bytes from {}", n, src);
                        // Fragment the H.264 NAL unit into VSTREAM packets
                        let frags = fragment_frame(seq, &buf[..n]);
                        for frag in frags {
                            // Send through mesh to video_dst
                            router.lock().unwrap().send_to(video_dst, &frag);
                        }
                        seq = seq.wrapping_add(1);
                    }
                    Err(e) => {
                        eprintln!("[video-in] error: {}", e);
                        thread::sleep(Duration::from_millis(100));
                    }
                }
            }
        });
    }

    // === Thread 2: Mesh RX loop (receive frames + deliver video to phone) ===
    {
        let router = router.clone();
        let vsock_out = vsock_out.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 65536];
            // Simple frame reassembly buffer
            let mut frame_buf: Vec<u8> = Vec::new();

            loop {
                match sock.recv_from(&mut buf) {
                    Ok((n, src)) => {
                        if n < 5 { continue; }

                        // Check if this is a VSTREAM frame
                        // Mesh frame format: [dst_node][data...]
                        // For simple router: data starts at byte 0
                        if buf[0] == VSTREAM {
                            // Parse VSTREAM fragment
                            let frag = parse_vstream_fragment(&buf[..n]);
                            if let Some((seq, frag_idx, frag_count, data)) = frag {
                                // Accumulate fragments (simple version)
                                frame_buf.extend_from_slice(data);

                                // If this is the last fragment, send complete frame
                                if frag_idx + 1 >= frag_count {
                                    // Send reassembled H.264 to phone
                                    let _ = vsock_out.send_to(&frame_buf, out_addr);
                                    eprintln!(
                                        "[video-out] {} bytes to phone (seq={}, frags={})",
                                        frame_buf.len(), seq, frag_count
                                    );
                                    frame_buf.clear();
                                }
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("[mesh-rx] error: {}", e);
                        thread::sleep(Duration::from_millis(10));
                    }
                }
            }
        });
    }

    // === Main thread: keep alive ===
    loop {
        thread::sleep(Duration::from_secs(60));
    }
}

// Fragment an H.264 NAL unit into VSTREAM packets
fn fragment_frame(seq: u16, data: &[u8]) -> Vec<Vec<u8>> {
    let chunks: Vec<&[u8]> = data.chunks(VFRAG_DATA).collect();
    let frag_count = chunks.len() as u8;
    let seq_lo = (seq & 0xFF) as u8;
    let seq_hi = ((seq >> 8) & 0xFF) as u8;

    chunks
        .iter()
        .enumerate()
        .map(|(i, chunk)| {
            let mut frag = Vec::with_capacity(VSTREAM_HDR + chunk.len());
            frag.push(VSTREAM);       // type
            frag.push(seq_lo);         // seq low byte
            frag.push(seq_hi);         // seq high byte
            frag.push(i as u8);        // fragment index
            frag.push(frag_count);     // total fragments
            frag.extend_from_slice(chunk);
            frag
        })
        .collect()
}

// Parse a VSTREAM fragment
fn parse_vstream_fragment(data: &[u8]) -> Option<(u16, u8, u8, &[u8])> {
    if data.len() < VSTREAM_HDR + 1 { return None; }
    if data[0] != VSTREAM { return None; }
    let seq = (data[1] as u16) | ((data[2] as u16) << 8);
    let frag_idx = data[3];
    let frag_count = data[4];
    Some((seq, frag_idx, frag_count, &data[VSTREAM_HDR..]))
}

// === Simplified mesh router (no crypto for bridge testing) ===

struct SimpleRouter {
    my_id: u32,
    sock: Arc<UdpSocket>,
    peers: Vec<(u32, std::net::SocketAddr)>,
}

impl SimpleRouter {
    fn new(my_id: u32, sock: Arc<UdpSocket>) -> Self {
        SimpleRouter { my_id, sock, peers: Vec::new() }
    }

    fn add_peer(&mut self, id: u32, addr: std::net::SocketAddr) {
        self.peers.push((id, addr));
    }

    fn send_to(&self, dst: u32, data: &[u8]) {
        // Find the peer (direct link for now — no multi-hop in this simplified version)
        for (pid, addr) in &self.peers {
            if *pid == dst {
                // Prefix with destination node ID (simplified wire format)
                let mut frame = Vec::with_capacity(4 + data.len());
                frame.extend_from_slice(&dst.to_be_bytes());
                frame.extend_from_slice(data);
                let _ = self.sock.send_to(&frame, addr);
                return;
            }
        }
        // If dst not a direct peer, send to first peer (relay)
        if let Some((_, addr)) = self.peers.first() {
            let mut frame = Vec::with_capacity(4 + data.len());
            frame.extend_from_slice(&dst.to_be_bytes());
            frame.extend_from_slice(data);
            let _ = self.sock.send_to(&frame, addr);
        }
    }
}

// Config parser (same as trios_meshd)
fn parse_cfg(path: &str) -> (u32, String, Vec<(u32, std::net::SocketAddr)>) {
    let content = std::fs::read_to_string(path).expect("read config");
    let mut id = 11u32;
    let mut listen = "0.0.0.0:5000".to_string();
    let mut peers = Vec::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let parts: Vec<&str> = line.split_whitespace().collect();
        match parts[0] {
            "id" => id = parts[1].parse().unwrap_or(11),
            "listen" => listen = parts[1].to_string(),
            "peer" => {
                if parts.len() >= 3 {
                    let pid: u32 = parts[1].parse().unwrap_or(0);
                    let addr: std::net::SocketAddr = parts[2].parse().expect("valid peer addr");
                    peers.push((pid, addr));
                }
            }
            _ => {}
        }
    }
    (id, listen, peers)
}
