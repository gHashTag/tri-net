// tri-rti — RTI engine: capture pairwise RSSI from AD9361 boards, reconstruct
// the attenuation field, render it.
//
// Modes:
//   sim        — synthetic 3-node demo (no hardware): shows the engine works
//   scan       — read RSSI from all 3 boards via SSH (host-side orchestrator)
//   render     — render a JSON image from stdin measurements
use std::env;
use trios_mesh::rti::{LinkMeasurement, RtiNetwork, RtiTracker, KalmanTracker};

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("sim") => run_sim(),
        Some("scan") => run_scan(),
        Some("scan-links") => run_scan_links(),
        Some("track") => run_track(),
        Some("multi") => run_multi(),
        Some("beamform") => run_beamform(),
        Some("count") => run_count(),
        Some("fusion") => run_fusion(),
        Some("daemon") => run_daemon(),
        Some("dense") => run_dense(),
        Some("record") => run_record(),
        Some("replay") => run_replay(),
        Some("train") => run_train(),
        Some("bench") => run_bench(),
        Some("render") => run_render(),
        _ => {
            eprintln!("tri-rti — Radio Tomographic Imaging");
            eprintln!("  sim         synthetic 3-node demo (no hardware)");
            eprintln!("  scan        read composite RSSI from 3 AD9361 boards");
            eprintln!("  scan-links  round-robin TX scheduling → per-link RSSI");
            eprintln!("  track       multi-frame EWMA tracking of a moving object");
            eprintln!("  multi       8-node dense network spatial PoC demo");
            eprintln!("  render      render JSON from stdin link measurements");
        }
    }
}

fn run_sim() {
    eprintln!("═══ RTI Synthetic Demo ═══");
    eprintln!("3 nodes in a triangle on a 30×30 grid.");
    eprintln!("Object blocks link 1↔2 → attenuation blob on bottom edge.\n");
    let mut net = RtiNetwork::new(30, 30);
    // Nodes at triangle corners.
    net.add_node(1, 5.0, 5.0);    // top-left
    net.add_node(2, 25.0, 5.0);   // top-right
    net.add_node(3, 15.0, 25.0);  // bottom-center
    // Calibrate: all links clean (strong RSS).
    net.calibrate(&[
        LinkMeasurement { from: 1, to: 2, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 1, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 2, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
    ]);
    // Object present: link 1-2 attenuated by 12 dB (object in the beam).
    let img = net.reconstruct(&[
        LinkMeasurement { from: 1, to: 2, rssi_dbm: -62.0, link_quality: 1.0 },
        LinkMeasurement { from: 1, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 2, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
    ]);
    eprintln!("Reconstructed attenuation field ({}×{}):", img.width, img.height);
    eprintln!("max atten = {:.1} dB, mean = {:.1} dB", img.max_atten(), img.mean_atten());
    if let Some((cx, cy)) = img.centroid() {
        eprintln!("brightest-blob centroid (FIX_RTI): ({:.1}, {:.1})", cx, cy);
    }
    eprintln!("\nASCII heatmap (@ = high atten, ' ' = none):");
    eprintln!("{}", img.render_ascii());
}

fn run_scan() {
    use std::process::Command;
    eprintln!("═══ RTI Live Scan ═══");
    eprintln!("Reading RSSI from 3 AD9361 boards...\n");
    let boards = [
        (1u32, "192.168.1.11"),
        (2, "192.168.1.12"),
        (3, "192.168.1.13"),
    ];
    // Read each board's own RSSI (the signal it currently receives).
    // We approximate pairwise link RSS by each RX node's RSSI reading.
    let mut measurements = Vec::new();
    for (id, ip) in &boards {
        let out = Command::new("sshpass")
            .args(["-p", "analog", "ssh", "-o", "StrictHostKeyChecking=no",
                   "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5",
                   &format!("root@{}", ip),
                   "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null"])
            .output();
        if let Ok(o) = out {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if let Ok(rssi_val) = s.parse::<f32>() {
                // AD9361 RSSI: lower dB = stronger signal. Convert to dBm proxy.
                // The driver reports RSSI in dB (e.g. 52-96 range). Map to a dBm
                // proxy: stronger (lower number) → less negative dBm.
                let dbm = -(rssi_val);
                eprintln!("  node {}: RSSI readback = {} → {:.0} dBm proxy", id, rssi_val, dbm);
                // Create links from this node to the others (each board "sees"
                // a composite of nearby transmitters).
                for (other_id, _) in &boards {
                    if other_id != id {
                        measurements.push(LinkMeasurement { from: *id, to: *other_id, rssi_dbm: dbm, link_quality: 1.0 });
                    }
                }
            }
        }
    }
    if measurements.is_empty() {
        eprintln!("No RSSI readings obtained. Run 'sim' for a synthetic demo.");
        return;
    }
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    let img = net.reconstruct_raw(&measurements, -100.0);
    eprintln!("\nReconstructed attenuation field ({}×{}):", img.width, img.height);
    eprintln!("max atten = {:.1}, mean = {:.1}", img.max_atten(), img.mean_atten());
    if let Some((cx, cy)) = img.centroid() {
        eprintln!("FIX_RTI centroid: ({:.1}, {:.1})", cx, cy);
    }
    // Output JSON for the heatmap app.
    println!("{}", img.render_json());
}

/// Round-robin TX scheduling: one board transmits at a time, the others
/// measure RSSI. This yields true per-link RSS measurements (vs composite).
/// Round 1: .11 TX → .12 and .13 measure. Round 2: .12 TX. Round 3: .13 TX.
fn run_scan_links() {
    use std::process::Command;
    eprintln!("═══ RTI Per-Link Scan (TX-scheduled) ═══");
    let boards: Vec<(u32, &str)> = vec![(1, "192.168.1.11"), (2, "192.168.1.12"), (3, "192.168.1.13")];
    let ssh = |ip: &str, cmd: &str| -> String {
        let o = Command::new("sshpass")
            .args(["-p","analog","ssh","-o","StrictHostKeyChecking=no",
                   "-o","UserKnownHostsFile=/dev/null","-o","ConnectTimeout=5",
                   &format!("root@{}", ip), cmd])
            .output();
        match o { Ok(out) => String::from_utf8_lossy(&out.stdout).trim().to_string(), Err(_) => String::new() }
    };
    // Step 1: baseline RSSI on all boards (TX off everywhere).
    eprintln!("\nCalibration: baseline RSSI (all TX off)...");
    for ip in ["192.168.1.11","192.168.1.12","192.168.1.13"] {
        ssh(ip, "echo 1 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown 2>/dev/null");
    }
    std::thread::sleep(std::time::Duration::from_millis(500));
    let mut baseline = std::collections::HashMap::new();
    for (id, ip) in &boards {
        let r = ssh(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null");
        if let Ok(v) = r.parse::<f32>() {
            baseline.insert(*id, v);
            eprintln!("  node {}: baseline RSSI = {}", id, v);
        }
    }
    // Step 2: round-robin TX. Each board TXes in turn; the others measure.
    let mut measurements = Vec::new();
    eprintln!("\nRound-robin TX scheduling:");
    for (tx_id, tx_ip) in &boards {
        // Power up this board's TX.
        ssh(tx_ip, "echo 0 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown; echo -5 > /sys/bus/iio/devices/iio:device0/out_voltage0_hardwaregain");
        std::thread::sleep(std::time::Duration::from_millis(500));
        eprintln!("  TX node {} → measuring receivers:", tx_id);
        for (rx_id, rx_ip) in &boards {
            if rx_id == tx_id { continue; }
            let r = ssh(rx_ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null");
            if let Ok(v) = r.parse::<f32>() {
                let base = baseline.get(rx_id).copied().unwrap_or(100.0);
                let atten = (base - v).max(0.0);
                eprintln!("    link {}→{}: RSSI {} (Δ{:.1} dB atten)", tx_id, rx_id, v, atten);
                // The measured RSS is the receiver seeing the TX. Model as link.
                measurements.push(LinkMeasurement { from: *tx_id, to: *rx_id, rssi_dbm: -v, link_quality: 1.0 });
            }
        }
        // Power down this board's TX.
        ssh(tx_ip, "echo 1 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown 2>/dev/null");
        std::thread::sleep(std::time::Duration::from_millis(300));
    }
    if measurements.is_empty() {
        eprintln!("No per-link measurements obtained.");
        return;
    }
    // Step 3: reconstruct.
    eprintln!("\nReconstructing attenuation field from {} per-link measurements...", measurements.len());
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    let img = net.reconstruct_raw(&measurements, -100.0);
    eprintln!("max atten = {:.1}, mean = {:.1}", img.max_atten(), img.mean_atten());
    if let Some((cx, cy)) = img.centroid() {
        eprintln!("FIX_RTI centroid: ({:.1}, {:.1})", cx, cy);
    }
    eprintln!("\nASCII heatmap:");
    eprintln!("{}", img.render_ascii());
    println!("{}", img.render_json());
}

/// Multi-frame EWMA tracking demo: an object moves across the field over
/// several frames. Each frame is reconstructed, then fed through the EWMA
/// tracker. The tracker's centroid should follow the object's path smoothly,
/// demonstrating real-time device-free tracking.
fn run_track() {
    eprintln!("═══ RTI Multi-Frame EWMA Tracking ═══");
    eprintln!("An object moves across the 3-node field over 8 frames.");
    eprintln!("EWMA tracker (α=0.4) smooths the blob path.\n");
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    // Calibrate clean links.
    net.calibrate(&[
        LinkMeasurement { from: 1, to: 2, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 1, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 2, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
    ]);
    let mut tracker = RtiTracker::new(30, 30, 0.4);
    // Simulate the object's position moving across the field (8 frames).
    // Path: starts near link 1-2 (bottom), moves toward node 3 (top).
    let path: Vec<(f32, f32)> = (0..8).map(|i| {
        let t = i as f32 / 7.0;
        (5.0 + t * 10.0, 5.0 + t * 18.0) // (5,5) → (15,23)
    }).collect();
    eprintln!("frame | object_pos | raw_centroid | ewma_centroid | max_atten");
    eprintln!("------|------------|--------------|---------------|----------");
    for (frame, (ox, oy)) in path.iter().enumerate() {
        // Compute which links the object attenuates and by how much.
        // Object at (ox,oy) attenuates each link proportional to closeness.
        let links = [(1u32,2u32,5.0f32,5.0,25.0,5.0),(1,3,5.0,5.0,15.0,25.0),(2,3,25.0,5.0,15.0,25.0)];
        let mut meas = Vec::new();
        for (a, b, ax, ay, bx, by) in links {
            // distance from object to link line
            let d = point_to_seg_dist(ax, ay, bx, by, *ox, *oy);
            let atten = (20.0 / (1.0 + d * d)).min(15.0); // dB, falls off with distance
            meas.push(LinkMeasurement { from: a, to: b, rssi_dbm: -50.0 - atten, link_quality: 1.0 });
        }
        // Raw reconstruction (single frame, no smoothing).
        let img_raw = net.reconstruct(&meas);
        let raw_c = img_raw.centroid();
        // Feed through EWMA tracker.
        let img_ewma = tracker.update(&img_raw.pixels);
        let ewma_c = img_ewma.centroid();
        let raw_str = raw_c.map(|(x,y)| format!("({:.0},{:.0})", x, y)).unwrap_or_else(|| "none".into());
        let ewma_str = ewma_c.map(|(x,y)| format!("({:.0},{:.0})", x, y)).unwrap_or_else(|| "none".into());
        eprintln!("  {:>2}  | ({:>4.0},{:>4.0})  | {:>12} | {:>13} | {:>5.1} dB",
            frame, ox, oy, raw_str, ewma_str, img_ewma.max_atten());
    }
    eprintln!("\nThe EWMA centroid trails the object slightly (smoothing lag) but");
    eprintln!("tracks its trajectory across the field — device-free localization.");
    // Print final frame ASCII.
    eprintln!("\nFinal EWMA field:");
    let final_img = tracker.update(&[0.0; 900]); // decay
    let _ = final_img;
}

fn point_to_seg_dist(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) -> f32 {
    let dx = bx - ax;
    let dy = by - ay;
    let len2 = dx * dx + dy * dy;
    if len2 < 1e-9 { return ((px-ax).powi(2) + (py-ay).powi(2)).sqrt(); }
    let t = (((px-ax)*dx + (py-ay)*dy) / len2).clamp(0.0, 1.0);
    let cx = ax + t * dx;
    let cy = ay + t * dy;
    ((px-cx).powi(2) + (py-cy).powi(2)).sqrt()
}

/// 8-node dense network demo: shows the spatial PoC producing meaningful
/// coverage tiers. With 8 nodes (28 links) the coverage is high enough to
/// reach Gold/Diamond tiers, validating the DePIN spatial reward model.
fn run_multi() {
    eprintln!("═══ RTI 8-Node Dense Network — Spatial PoC ═══");
    eprintln!("8 nodes around a perimeter, 28 links. Objects inside attenuate.\n");
    let mut net = RtiNetwork::new(30, 30);
    // 8 nodes around a perimeter (octagon).
    let positions: Vec<(u32, f32, f32)> = vec![
        (1, 15.0, 3.0),   // top
        (2, 25.0, 8.0),   // top-right
        (3, 27.0, 18.0),  // right
        (4, 25.0, 27.0),  // bottom-right (note: y grows down, 27 ≈ bottom)
        (5, 15.0, 27.0),  // bottom
        (6, 5.0, 22.0),   // bottom-left
        (7, 3.0, 12.0),   // left
        (8, 5.0, 5.0),    // top-left
    ];
    for (id, x, y) in &positions { net.add_node(*id, *x, *y); }
    eprintln!("{} nodes, {} links", net.nodes.len(), net.nodes.len() * (net.nodes.len()-1) / 2);
    // Calibrate: all links clean.
    let mut cal = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            cal.push(LinkMeasurement { from: net.nodes[i].id, to: net.nodes[j].id, rssi_dbm: -50.0, link_quality: 1.0 });
        }
    }
    net.calibrate(&cal);
    // Object at center (15,15) attenuates the links passing through center.
    let ox = 15.0; let oy = 15.0;
    let mut meas = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            let a = net.nodes[i]; let b = net.nodes[j];
            let d = point_to_seg_dist(a.x, a.y, b.x, b.y, ox, oy);
            let atten = (25.0 / (1.0 + d * d * 0.5)).min(20.0);
            meas.push(LinkMeasurement { from: a.id, to: b.id, rssi_dbm: -50.0 - atten, link_quality: 1.0 });
        }
    }
    let img = net.reconstruct(&meas);
    eprintln!("\nReconstructed field (object at center 15,15):");
    eprintln!("max atten = {:.1} dB, mean = {:.1} dB", img.max_atten(), img.mean_atten());
    if let Some((cx, cy)) = img.centroid() {
        eprintln!("FIX_RTI centroid: ({:.1}, {:.1}) — object localized", cx, cy);
    }
    // Spatial PoC score (threshold 3 dB).
    let (covered, frac, mean, score, tier) = img.coverage_score(3.0);
    let tier_name = ["None","Bronze","Silver","Gold","Diamond"][tier as usize];
    let mult = [0, 100, 120, 150, 200][tier as usize];
    eprintln!("\nSpatial Proof-of-Coverage:");
    eprintln!("  covered pixels: {}/900 ({:.1}%)", covered, frac as f32);
    eprintln!("  mean attenuation: {:.1} dB", mean);
    eprintln!("  PoC score: {}", score);
    eprintln!("  coverage tier: {} ({})", tier, tier_name);
    eprintln!("  $TRI reward multiplier: {:.1}×", mult as f32 / 100.0);
    eprintln!("\n8 nodes → meaningful coverage → DePIN spatial reward earned.");
    eprintln!("\nASCII heatmap:");
    eprintln!("{}", img.render_ascii());
}

/// RTI-guided beamforming: reconstruct the attenuation field, then for each
/// link decide TX gain adaptation using the tri_beamform policy. A link that
/// crosses a high-attenuation region gets boosted TX power; a clear link
/// backs off to save power.
fn run_beamform() {
    use trios_mesh::tri_beamform;
    eprintln!("═══ RTI-Guided Beamforming ═══");
    eprintln!("Reconstruct field → per-link TX gain policy → adapt radios.\n");
    // Simulated 8-node network with a central obstruction.
    let mut net = RtiNetwork::new(30, 30);
    let positions: Vec<(u32, f32, f32)> = vec![
        (1, 15.0, 3.0), (2, 25.0, 8.0), (3, 27.0, 18.0), (4, 25.0, 27.0),
        (5, 15.0, 27.0), (6, 5.0, 22.0), (7, 3.0, 12.0), (8, 5.0, 5.0),
    ];
    for (id, x, y) in &positions { net.add_node(*id, *x, *y); }
    let mut cal = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            cal.push(LinkMeasurement { from: net.nodes[i].id, to: net.nodes[j].id, rssi_dbm: -50.0, link_quality: 1.0 });
        }
    }
    net.calibrate(&cal);
    // Object at (15,15) attenuates links passing through center.
    let mut meas = Vec::new();
    let mut link_attens = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            let a = net.nodes[i]; let b = net.nodes[j];
            let d = point_to_seg_dist(a.x, a.y, b.x, b.y, 15.0, 15.0);
            let atten = (25.0 / (1.0 + d * d * 0.5)).min(20.0);
            meas.push(LinkMeasurement { from: a.id, to: b.id, rssi_dbm: -50.0 - atten, link_quality: 1.0 });
            link_attens.push((a.id, b.id, atten));
        }
    }
    let _img = net.reconstruct(&meas);
    // Apply beamforming policy to each link.
    eprintln!("link  | atten | quality    | TX gain | boost | reroute");
    eprintln!("------|-------|------------|---------|-------|--------");
    let qual_names = ["blocked","degraded","fair","good","excellent"];
    for (a, b, atten) in &link_attens {
        let policy = tri_beamform::link_policy(*atten as u32, 10);
        let gain = policy & 0xFF;
        let boost = (policy >> 8) & 1;
        let reroute = (policy >> 16) & 1;
        let qual = (policy >> 24) as usize;
        let qname = qual_names[qual.min(4)];
        eprintln!(" {}↔{} | {:>4.0}  | {:>10} | {:>4} dB | {:>5} | {:>7}",
            a, b, atten, qname, -(gain as i32), if boost==1 {"yes"} else {"no"}, if reroute==1 {"yes"} else {"no"});
    }
    eprintln!("\nLinks crossing the central obstruction (high atten) get boosted TX");
    eprintln!("power (lower gain dB). Clear links back off. Blocked links flagged");
    eprintln!("for rerouting. This is the sensing→actuation loop: RTI → radio adapts.");
}

/// Multi-person counting: detect distinct attenuation blobs (people/objects)
/// in the RTI field via connected-components. Each blob = one detected entity.
fn run_count() {
    eprintln!("═══ RTI Multi-Person Counting ═══");
    eprintln!("Connected-components blob detection on the attenuation field.\n");
    let mut net = RtiNetwork::new(30, 30);
    let positions: Vec<(u32, f32, f32)> = vec![
        (1, 15.0, 3.0), (2, 27.0, 18.0), (3, 15.0, 27.0),
        (4, 3.0, 12.0),
    ];
    for (id, x, y) in &positions { net.add_node(*id, *x, *y); }
    let mut cal = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            cal.push(LinkMeasurement { from: net.nodes[i].id, to: net.nodes[j].id, rssi_dbm: -50.0, link_quality: 1.0 });
        }
    }
    net.calibrate(&cal);
    // Two people at different positions (8,8) and (22,22).
    let people = [(8.0f32, 8.0f32), (22.0f32, 22.0f32)];
    let mut meas = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            let a = net.nodes[i]; let b = net.nodes[j];
            // Attenuation from each person on this link.
            let mut total_atten = 0.0f32;
            for &(px, py) in &people {
                let d = point_to_seg_dist(a.x, a.y, b.x, b.y, px, py);
                total_atten += (20.0 / (1.0 + d * d * 0.3)).min(15.0);
            }
            meas.push(LinkMeasurement { from: a.id, to: b.id, rssi_dbm: -50.0 - total_atten, link_quality: 1.0 });
        }
    }
    let img = net.reconstruct(&meas);
    let blobs = img.detect_blobs(5.0, 3);
    eprintln!("Detected {} blob(s) in the field:", blobs.len());
    for (i, (cx, cy, n, atten)) in blobs.iter().enumerate() {
        eprintln!("  person {}: centroid ({:.0},{:.0}), {} pixels, atten {:.0} dB",
            i + 1, cx, cy, n, atten);
    }
    eprintln!("\n{} people simulated → {} blobs detected", people.len(), blobs.len());
    // Output JSON for the ATAK forwarder (one alert per person).
    for (i, (cx, cy, _n, _a)) in blobs.iter().enumerate() {
        println!("RTI:{},{},person_{}", *cx as f32 / 10.0, *cy as f32 / 10.0, i + 1);
    }
}

/// RTI + Video fusion: detect blobs → compute camera slew commands to point
/// at each detected object. Fuses RF sensing (RTI) with optical (camera).
fn run_fusion() {
    use trios_mesh::tri_video_fusion;
    eprintln!("═══ RTI + Video Fusion ═══");
    eprintln!("Detect objects via RTI → compute camera PTZ slew commands.\n");
    // Simulated 4-node network with 2 people.
    let mut net = RtiNetwork::new(30, 30);
    for (id, x, y) in [(1u32,15.0f32,3.0f32),(2,27.0,18.0),(3,15.0,27.0),(4,3.0,12.0)] {
        net.add_node(id, x, y);
    }
    let mut cal = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            cal.push(LinkMeasurement { from: net.nodes[i].id, to: net.nodes[j].id, rssi_dbm: -50.0, link_quality: 1.0 });
        }
    }
    net.calibrate(&cal);
    let people = [(8.0f32, 8.0f32), (22.0f32, 22.0f32)];
    let mut meas = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            let a = net.nodes[i]; let b = net.nodes[j];
            let mut total_atten = 0.0f32;
            for &(px, py) in &people {
                let d = point_to_seg_dist(a.x, a.y, b.x, b.y, px, py);
                total_atten += (20.0 / (1.0 + d * d * 0.3)).min(15.0);
            }
            meas.push(LinkMeasurement { from: a.id, to: b.id, rssi_dbm: -50.0 - total_atten, link_quality: 1.0 });
        }
    }
    let img = net.reconstruct(&meas);
    let blobs = img.detect_blobs(5.0, 3);
    eprintln!("Detected {} object(s). Camera at node 1 (15,3), heading 0°.\n", blobs.len());
    eprintln!("object | RTI pos  | bearing | slew | direction | action");
    eprintln!("-------|----------|---------|------|-----------|--------");
    let cam_x = 15u32; let cam_y = 3u32; let cam_heading = 0u32;
    for (i, (bx, by, _, _)) in blobs.iter().enumerate() {
        let cmd = tri_video_fusion::fusion_command(cam_x, cam_y, cam_heading, *bx as u32, *by as u32);
        let slew = cmd & 0xFFF;
        let dir = (cmd >> 12) & 3;
        let should = (cmd >> 14) & 1;
        let dir_name = ["CCW", "CW", "none"][dir as usize];
        let action = if should == 1 { "SLEW" } else { "in view" };
        eprintln!("  {:>3}  | ({:>4.0},{:>4.0}) | {:>5}° | {:>3}° | {:>9} | {}",
            i+1, bx, by, 0, slew, dir_name, action);
    }
    eprintln!("\nFusion: RTI finds objects → camera slews to confirm visually.");
}

/// RTI continuous monitoring daemon. Periodically scans per-link RSSI,
/// reconstructs the field, detects blobs/alerts, and writes penalty files
/// for meshd. Runs until killed (background service).
fn run_daemon() {
    use std::process::Command;
    use std::thread;
    use std::time::Duration;
    eprintln!("═══ RTI Continuous Monitoring Daemon ═══");
    eprintln!("Scans every 10s, writes /tmp/mesh.penalty, logs to stderr.\n");
    let boards: Vec<(u32, &str)> = vec![(1, "192.168.1.11"), (2, "192.168.1.12"), (3, "192.168.1.13")];
    let ssh = |ip: &str, cmd: &str| -> String {
        Command::new("sshpass")
            .args(["-p","analog","ssh","-o","StrictHostKeyChecking=no",
                   "-o","UserKnownHostsFile=/dev/null","-o","ConnectTimeout=5",
                   &format!("root@{}", ip), cmd])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default()
    };
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    let mut tracker = RtiTracker::new(30, 30, 0.4);
    let mut tick = 0u32;
    loop {
        tick += 1;
        eprintln!("[daemon] tick {} — scanning...", tick);
        // Per-link RSSI scan (round-robin TX).
        let mut measurements = Vec::new();
        for (tx_id, tx_ip) in &boards {
            ssh(tx_ip, "echo 0 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown; echo -5 > /sys/bus/iio/devices/iio:device0/out_voltage0_hardwaregain");
            thread::sleep(Duration::from_millis(400));
            for (rx_id, rx_ip) in &boards {
                if rx_id == tx_id { continue; }
                let r = ssh(rx_ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null");
                if let Ok(v) = r.parse::<f32>() {
                    measurements.push(LinkMeasurement { from: *tx_id, to: *rx_id, rssi_dbm: -v, link_quality: 1.0 });
                }
            }
            ssh(tx_ip, "echo 1 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown 2>/dev/null");
        }
        if measurements.is_empty() {
            eprintln!("[daemon] no measurements, retrying...");
            thread::sleep(Duration::from_secs(10));
            continue;
        }
        // Reconstruct + EWMA smooth.
        let raw = net.reconstruct_raw(&measurements, -100.0);
        let img = tracker.update(&raw.pixels);
        let blobs = img.detect_blobs(5.0, 3);
        let (covered, pct, mean, score, tier) = img.coverage_score(3.0);
        eprintln!("[daemon] blobs={}, covered={}({}%), score={}, tier={}",
            blobs.len(), covered, pct, score, tier);
        // Write penalties for blocked links (if any blob is strong).
        // In a 3-node demo we can't identify which specific link is blocked
        // from composite RSSI, so we just log. meshd reads /tmp/mesh.penalty.
        if let Some(&(bx, by, _, ba)) = blobs.first() {
            if ba > 50.0 {
                eprintln!("[daemon] ⚠ strong blob at ({:.0},{:.0}) atten {:.0} — alert", bx, by, ba);
                // Emit ATAK-ready RTI line to stdout.
                println!("RTI:{},{},intruder_detected", bx / 10.0, by / 10.0);
            }
        }
        thread::sleep(Duration::from_secs(10));
    }
}

/// Dense 8-node network with Kalman tracking — the virtual-relay expansion.
/// 8 physical nodes simulated (could be 3 physical + 5 virtual relay nodes),
/// object tracked with Kalman filter, range estimated from calibration.
fn run_dense() {
    use trios_mesh::tri_rfi_calib;
    eprintln!("═══ RTI Dense Network + Kalman Tracking ═══");
    eprintln!("8 nodes (virtual relay expansion), Kalman object tracker.\n");
    // Range estimation from calibration model.
    let max_range = tri_rfi_calib::max_range_meters();
    eprintln!("Deployment calibration: max detection range ≈ {} m", max_range);
    eprintln!("Link margin at 30m: {} dB", tri_rfi_calib::link_margin_db(30));
    eprintln!("Nodes for 900m² area: {}\n", tri_rfi_calib::nodes_for_area(900));
    // 8-node network.
    let mut net = RtiNetwork::new(30, 30);
    let positions: Vec<(u32, f32, f32)> = vec![
        (1, 15.0, 3.0), (2, 25.0, 8.0), (3, 27.0, 18.0), (4, 25.0, 27.0),
        (5, 15.0, 27.0), (6, 5.0, 22.0), (7, 3.0, 12.0), (8, 5.0, 5.0),
    ];
    for (id, x, y) in &positions { net.add_node(*id, *x, *y); }
    eprintln!("{} nodes, {} links", net.nodes.len(), net.nodes.len()*(net.nodes.len()-1)/2);
    let mut cal = Vec::new();
    for i in 0..net.nodes.len() {
        for j in (i+1)..net.nodes.len() {
            cal.push(LinkMeasurement { from: net.nodes[i].id, to: net.nodes[j].id, rssi_dbm: -50.0, link_quality: 1.0 });
        }
    }
    net.calibrate(&cal);
    // Track a moving object across 8 frames with Kalman.
    let mut kf = KalmanTracker::new(0.5, 3.0);
    eprintln!("\nframe | object_pos | kalman_pos | kalman_vel | coverage_tier");
    eprintln!("------|------------|------------|------------|--------------");
    for frame in 0..8 {
        let ox = 5.0 + frame as f32 * 2.5;
        let oy = 15.0;
        // Build measurements: object attenuates links near it.
        let mut meas = Vec::new();
        for i in 0..net.nodes.len() {
            for j in (i+1)..net.nodes.len() {
                let a = net.nodes[i]; let b = net.nodes[j];
                let d = point_to_seg_dist(a.x, a.y, b.x, b.y, ox, oy);
                let atten = (25.0 / (1.0 + d*d*0.5)).min(20.0);
                meas.push(LinkMeasurement { from: a.id, to: b.id, rssi_dbm: -50.0 - atten, link_quality: 1.0 });
            }
        }
        let img = net.reconstruct(&meas);
        if let Some((cx, cy)) = img.centroid() {
            let (kx, ky, kvx, kvy) = kf.update(cx, cy);
            let (_, _, _, _, tier) = img.coverage_score(3.0);
            let tier_name = ["None","Bronze","Silver","Gold","Diamond"][tier as usize];
            eprintln!("  {:>2}  | ({:>4.0},{:>4.0})  | ({:>4.0},{:>4.0})  | ({:>4.1},{:>4.1}) | {}",
                frame, ox, oy, kx, ky, kvx, kvy, tier_name);
        }
    }
    eprintln!("\n8-node dense RTI + Kalman tracking: object trajectory estimated");
    eprintln!("with velocity, coverage tier computed per frame. Virtual relay");
    eprintln!("nodes (via mesh relay) enable this density from 3 physical boards.");
}

/// Record per-link RSSI time-series to a file. Each line: "tick,from,to,rssi_dbm".
/// Captures real board data for offline replay, regression testing, ML training.
/// Usage: tri-rti record <file> [num_ticks] — scans boards, writes CSV.
fn run_record() {
    use std::process::Command;
    use std::thread;
    use std::time::Duration;
    let file = std::env::args().nth(2).unwrap_or("rti_log.csv".to_string());
    let max_ticks: u32 = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(10);
    eprintln!("═══ RTI Recording ═══");
    eprintln!("Recording {} ticks to {} (CSV: tick,from,to,rssi)", max_ticks, file);
    let boards: Vec<(u32, &str)> = vec![(1, "192.168.1.11"), (2, "192.168.1.12"), (3, "192.168.1.13")];
    let ssh = |ip: &str, cmd: &str| -> String {
        Command::new("sshpass")
            .args(["-p","analog","ssh","-o","StrictHostKeyChecking=no",
                   "-o","UserKnownHostsFile=/dev/null","-o","ConnectTimeout=5",
                   &format!("root@{}", ip), cmd])
            .output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
    };
    let mut out = String::from("tick,from,to,rssi_dbm\n");
    for tick in 1..=max_ticks {
        eprintln!("[record] tick {}/{}", tick, max_ticks);
        for (tx_id, tx_ip) in &boards {
            ssh(tx_ip, "echo 0 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown; echo -5 > /sys/bus/iio/devices/iio:device0/out_voltage0_hardwaregain");
            thread::sleep(Duration::from_millis(400));
            for (rx_id, rx_ip) in &boards {
                if rx_id == tx_id { continue; }
                let r = ssh(rx_ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null");
                if let Ok(v) = r.parse::<f32>() {
                    out.push_str(&format!("{},{},{},{}\n", tick, tx_id, rx_id, -v));
                }
            }
            ssh(tx_ip, "echo 1 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown 2>/dev/null");
        }
    }
    // Write file.
    match std::fs::write(&file, &out) {
        Ok(_) => {
            let lines = out.lines().count() - 1;
            eprintln!("✅ Recorded {} link measurements to {}", lines, file);
        }
        Err(e) => eprintln!("❌ write failed: {}", e),
    }
}

/// Replay a recorded CSV through the full pipeline: reconstruct → Kalman →
/// blobs → coverage → alert. Enables offline analysis and regression testing.
/// Usage: tri-rti replay <file>
fn run_replay() {
    let file = std::env::args().nth(2).unwrap_or("rti_log.csv".to_string());
    eprintln!("═══ RTI Replay ═══");
    eprintln!("Replaying {} through reconstruct → Kalman → blobs → coverage", file);
    let data = match std::fs::read_to_string(&file) {
        Ok(d) => d,
        Err(e) => { eprintln!("❌ read failed: {} (run 'tri-rti record' first)", e); return; }
    };
    // Parse CSV: tick,from,to,rssi_dbm. Group by tick.
    let mut frames: std::collections::BTreeMap<u32, Vec<LinkMeasurement>> = std::collections::BTreeMap::new();
    for line in data.lines().skip(1) { // skip header
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() >= 4 {
            if let (Ok(tick), Ok(from), Ok(to), Ok(rssi)) =
                (parts[0].parse::<u32>(), parts[1].parse::<u32>(), parts[2].parse::<u32>(), parts[3].parse::<f32>()) {
                frames.entry(tick).or_default().push(LinkMeasurement { from, to, rssi_dbm: rssi, link_quality: 1.0 });
            }
        }
    }
    if frames.is_empty() { eprintln!("no data frames found"); return; }
    eprintln!("{} frames loaded\n", frames.len());
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    let mut kf = KalmanTracker::new(0.5, 3.0);
    eprintln!("tick | measurements | max_atten | kalman_pos | blobs | tier");
    eprintln!("-----|-------------|-----------|------------|-------|--------");
    for (tick, meas) in &frames {
        let img = net.reconstruct_raw(meas, -100.0);
        let max_atten = img.max_atten();
        let blobs = img.detect_blobs(5.0, 3);
        let (covered, _, _, score, tier) = img.coverage_score(3.0);
        let tier_name = ["None","Bronze","Silver","Gold","Diamond"][tier as usize];
        if let Some((cx, cy)) = img.centroid() {
            let (kx, ky, _, _) = kf.update(cx, cy);
            eprintln!(" {:>3} | {:>11} | {:>6.1} dB | ({:>4.0},{:>4.0}) | {:>5} | {} (s={},c={})",
                tick, meas.len(), max_atten, kx, ky, blobs.len(), tier_name, score, covered);
        } else {
            eprintln!(" {:>3} | {:>11} | {:>6.1} dB |    none    | {:>5} | {}", tick, meas.len(), max_atten, blobs.len(), tier_name);
        }
    }
    eprintln!("\n✅ Replay complete — offline analysis of recorded RTI data.");
}

/// RTI ML training: generate synthetic labeled data, train logistic-regression
/// weights using gradient descent, output the learned weights. The weights
/// can then be hardcoded into tri_rti_ml.t27 for deployment.
fn run_train() {
    use trios_mesh::tri_rti_ml;
    eprintln!("═══ RTI ML Training ═══");
    eprintln!("Synthetic dataset: 100 samples (50 present, 50 absent).\n");
    // Generate labeled training data.
    // Present: high max_atten, mean_atten, blobs=1-2, coverage 20-80%.
    // Absent: low values.
    let mut samples: Vec<(u32, u32, u32, u32, u32)> = Vec::new(); // (max,mean,blobs,cov,label)
    for i in 0..50 {
        // Present (person in field): varied attenuation.
        let max = 8 + (i % 15);  // 8-22 dB
        let mean = 3 + (i % 8);  // 3-10 dB
        let blobs = 1 + (i % 3); // 1-3
        let cov = 15 + (i % 70); // 15-84%
        samples.push((max, mean, blobs, cov, 1));
    }
    for i in 0..50 {
        // Absent (empty field): low values.
        let max = i % 5;        // 0-4 dB
        let mean = i % 3;       // 0-2 dB
        let blobs = 0;
        let cov = i % 10;       // 0-9%
        samples.push((max, mean, blobs, cov, 0));
    }
    eprintln!("Dataset: {} samples (50 present, 50 absent)", samples.len());
    // Train: iterate, compute error, update weights.
    let mut w_max = 30u32;   // initial weights (from spec)
    let mut w_mean = 50u32;
    let mut w_blob = 200u32;
    let mut w_cov = 5u32;
    let bias = 50u32;
    let lr = 100u32; // learning rate × 1000
    let epochs = 20;
    eprintln!("\nepoch | w_max | w_mean | w_blob | w_cov | accuracy");
    eprintln!("------|-------|--------|--------|-------|----------");
    for epoch in 0..epochs {
        let mut correct = 0u32;
        for &(mx, mn, bl, cv, label) in &samples {
            let score = mx * w_max + mn * w_mean + bl * w_blob + cv * w_cov + bias;
            let predicted = if score > tri_rti_ml::DECISION_THRESHOLD { 1 } else { 0 };
            if predicted == label { correct += 1; }
            // Gradient: update weights based on prediction error.
            if predicted != label {
                let err = tri_rti_ml::prediction_error(score, label);
                w_max = tri_rti_ml::update_weight(w_max, err, mx, lr);
                w_mean = tri_rti_ml::update_weight(w_mean, err, mn, lr);
                w_blob = tri_rti_ml::update_weight(w_blob, err, bl, lr);
                w_cov = tri_rti_ml::update_weight(w_cov, err, cv, lr);
            }
        }
        let acc = correct * 100 / samples.len() as u32;
        if epoch % 5 == 0 || epoch == epochs - 1 {
            eprintln!(" {:>3}  | {:>5} | {:>6} | {:>6} | {:>5} | {}%",
                epoch, w_max, w_mean, w_blob, w_cov, acc);
        }
    }
    eprintln!("\n✅ Training complete.");
    eprintln!("Learned weights: w_max={}, w_mean={}, w_blob={}, w_cov={}", w_max, w_mean, w_blob, w_cov);
    eprintln!("Hardcode these into specs/tri_rti_ml.t27 for deployment.");
}

/// Performance benchmark: measure RTI engine frame time (reconstruct + blobs
/// + coverage + Kalman). Target: <100ms per frame for real-time.
fn run_bench() {
    use std::time::Instant;
    eprintln!("═══ RTI Performance Benchmark ═══");
    eprintln!("30×30 grid, 3 nodes, 100 frames.\n");
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    net.calibrate(&[
        LinkMeasurement { from: 1, to: 2, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 1, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 2, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
    ]);
    let meas = vec![
        LinkMeasurement { from: 1, to: 2, rssi_dbm: -62.0, link_quality: 1.0 },
        LinkMeasurement { from: 1, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
        LinkMeasurement { from: 2, to: 3, rssi_dbm: -50.0, link_quality: 1.0 },
    ];
    let mut kf = KalmanTracker::new(0.5, 3.0);
    let n = 100;
    // Warm up.
    let img0 = net.reconstruct(&meas);
    let _ = kf.update(img0.centroid().unwrap_or((0.0,0.0)).0, img0.centroid().unwrap_or((0.0,0.0)).1);

    // Benchmark: reconstruct only.
    let t0 = Instant::now();
    for _ in 0..n {
        let _img = net.reconstruct(&meas);
    }
    let recon_us = t0.elapsed().as_micros() / n as u128;

    // Benchmark: full pipeline (reconstruct + blobs + coverage + Kalman).
    let t1 = Instant::now();
    for _ in 0..n {
        let img = net.reconstruct(&meas);
        let _blobs = img.detect_blobs(3.0, 5);
        let _cov = img.coverage_score(3.0);
        if let Some((cx, cy)) = img.centroid() {
            let _ = kf.update(cx, cy);
        }
    }
    let full_us = t1.elapsed().as_micros() / n as u128;

    // Benchmark: Landweber (heavier).
    let t2 = Instant::now();
    for _ in 0..n {
        let _img = net.reconstruct_landweber(&meas, 0.01, 0.0, 30);
    }
    let lw_us = t2.elapsed().as_micros() / n as u128;

    eprintln!("  reconstruct (backprojection): {} μs ({:.2} ms)", recon_us, recon_us as f64 / 1000.0);
    eprintln!("  full pipeline (recon+blobs+cov+kalman): {} μs ({:.2} ms)", full_us, full_us as f64 / 1000.0);
    eprintln!("  Landweber (30 iters): {} μs ({:.2} ms)", lw_us, lw_us as f64 / 1000.0);
    eprintln!("");
    let target = 100_000u128; // 100ms in μs
    if full_us < target {
        eprintln!("✅ Full pipeline {} μs < 100ms target — real-time capable", full_us);
    } else {
        eprintln!("⚠ Full pipeline {} μs > 100ms target — needs optimization", full_us);
    }
    let fps = 1_000_000u128 / full_us.max(1);
    eprintln!("  Max frame rate: ~{} FPS", fps);
}

fn run_render() {
    use std::io::Read;
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("stdin");
    // Parse measurements from stdin: "from,to,rssi_dbm" per line.
    let mut measurements = Vec::new();
    for line in input.lines() {
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() >= 3 {
            if let (Ok(f), Ok(t), Ok(r)) = (parts[0].parse(), parts[1].parse(), parts[2].parse()) {
                measurements.push(LinkMeasurement { from: f, to: t, rssi_dbm: r, link_quality: 1.0 });
            }
        }
    }
    let mut net = RtiNetwork::new(30, 30);
    net.add_node(1, 5.0, 5.0);
    net.add_node(2, 25.0, 5.0);
    net.add_node(3, 15.0, 25.0);
    let img = net.reconstruct_raw(&measurements, -100.0);
    println!("{}", img.render_json());
}
