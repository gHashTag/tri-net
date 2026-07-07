// tools/tri.rs — unified TRI-NET CLI
// Usage: rustc -O tools/tri.rs -o tools/tri && ./tri <command>
// Commands: status, deploy, test, regen, config, rf, mesh
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::env;

const BOARDS: &[&str] = &["192.168.1.11", "192.168.1.12", "192.168.1.13"];
const PASSWORD: &str = "analog";
const SSH_OPTS: &[&str] = &["-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no", "-o", "ConnectTimeout=5"];

fn ssh(ip: &str, cmd: &str) -> bool {
    Command::new("sshpass")
        .args(&["-p", PASSWORD])
        .args(SSH_OPTS)
        .arg(format!("root@{}", ip))
        .arg(cmd)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ssh_output(ip: &str, cmd: &str) -> String {
    Command::new("sshpass")
        .args(&["-p", PASSWORD])
        .args(SSH_OPTS)
        .arg(format!("root@{}", ip))
        .arg(cmd)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "N/A".to_string())
}

fn ping(ip: &str) -> bool {
    Command::new("ping").args(&["-c", "1", "-t", "2", ip])
        .output().map(|o| o.status.success()).unwrap_or(false)
}

fn print_header(title: &str) {
    println!("\n======================================================");
    println!("  {} ", title);
    println!("======================================================\n");
}

fn cmd_status() {
    print_header("TRI-NET STATUS");
    for ip in BOARDS {
        let alive = ping(ip);
        if !alive {
            println!("  {}: DEAD", ip);
            continue;
        }
        let kernel = ssh_output(ip, "uname -r");
        let hostname = ssh_output(ip, "cat /etc/hostname");
        let ad9361 = ssh_output(ip, "cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null");
        let rssi = ssh_output(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null");
        let mem = ssh_output(ip, "free -m | grep Mem | awk '{print $2\"MB\"}'");
        let temp = ssh_output(ip, "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null");
        let meshd = ssh_output(ip, "pgrep trios_meshd > /dev/null && echo running || echo stopped");
        
        println!("  {} [{}]", ip, if alive { "ALIVE" } else { "DEAD" });
        println!("    kernel:  {}", kernel);
        println!("    host:    {}", hostname);
        println!("    ad9361:  {} (RSSI: {})", ad9361, rssi);
        println!("    ram:     {}", mem);
        if !temp.is_empty() && temp != "N/A" {
            let t: u32 = temp.parse().unwrap_or(0);
            println!("    temp:    {}C", t / 1000);
        }
        println!("    meshd:   {}", meshd);
        println!();
    }
}

fn cmd_deploy() {
    print_header("DEPLOY");
    let bin = "target/armv7-unknown-linux-musleabihf/release/trios_meshd";
    if !std::path::Path::new(bin).exists() {
        eprintln!("Binary not found. Run: cargo zigbuild --release --target armv7-unknown-linux-musleabihf");
        std::process::exit(1);
    }
    let data = std::fs::read(bin).expect("read binary");
    for ip in BOARDS {
        print!("  {} -> ", ip);
        let mut child = Command::new("sshpass")
            .args(&["-p", PASSWORD])
            .args(SSH_OPTS)
            .arg(format!("root@{}", ip))
            .arg("cat > /tmp/trios_meshd && chmod +x /tmp/trios_meshd && echo OK")
            .stdin(std::process::Stdio::piped())
            .spawn().expect("ssh");
        if let Some(stdin) = child.stdin.as_mut() {
            use std::io::Write;
            stdin.write_all(&data).ok();
        }
        child.wait().expect("wait");
    }
    println!("\n  Deploy complete.");
}

fn cmd_test() {
    print_header("E2E TEST");
    let mut pass = 0;
    let mut fail = 0;
    for ip in BOARDS {
        if ping(ip) {
            println!("  {}: ping PASS", ip);
            pass += 1;
        } else {
            println!("  {}: ping FAIL", ip);
            fail += 1;
            continue;
        }
        let kernel = ssh_output(ip, "uname -r");
        if kernel.contains("5.10") {
            println!("  {}: kernel PASS", ip);
            pass += 1;
        } else { fail += 1; }
        
        let ad9361 = ssh_output(ip, "cat /sys/bus/iio/devices/iio:device0/name");
        if ad9361.contains("ad9361") {
            println!("  {}: AD9361 PASS", ip);
            pass += 1;
        } else { fail += 1; }
        
        if ssh(ip, "/tmp/smoke-m1 > /dev/null 2>&1") {
            println!("  {}: M1 crypto PASS", ip);
            pass += 1;
        } else {
            println!("  {}: M1 crypto FAIL", ip);
            fail += 1;
        }
    }
    println!("\n  Results: {} passed, {} failed", pass, fail);
}

fn cmd_regen() {
    print_header("REGEN");
    let t27c = "../t27/target/release/t27c";
    if !std::path::Path::new(t27c).exists() {
        eprintln!("t27c not found at {}", t27c);
        std::process::exit(1);
    }
    let specs_dir = std::path::Path::new("specs");
    let gen_dir = std::path::Path::new("gen/rust");
    let verilog_dir = std::path::Path::new("gen/verilog");
    std::fs::create_dir_all(gen_dir).ok();
    std::fs::create_dir_all(verilog_dir).ok();
    
    let mut count = 0;
    if let Ok(entries) = std::fs::read_dir(specs_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "t27") {
                let name = path.file_stem().unwrap().to_str().unwrap();
                
                // Rust
                if let Ok(o) = Command::new(t27c).arg("gen-rust").arg(&path).output() {
                    if o.status.success() {
                        std::fs::write(gen_dir.join(format!("{}.rs", name)), &o.stdout).ok();
                    }
                }
                // Verilog
                if let Ok(o) = Command::new(t27c).arg("gen-verilog").arg(&path).output() {
                    if o.status.success() {
                        std::fs::write(verilog_dir.join(format!("{}.v", name)), &o.stdout).ok();
                    }
                }
                count += 1;
            }
        }
    }
    println!("  Regenerated {} specs -> Rust + Verilog", count);
}

fn cmd_rf(freq: &str) {
    print_header("RF CONFIG");
    let freq_hz: u64 = match freq {
        "2.4" => 2_400_000_000,
        "5.8" => 5_800_000_000,
        "915" => 915_000_000,
        _ => 2_400_000_000,
    };
    println!("  Setting {} Hz on all boards", freq_hz);
    for ip in BOARDS {
        let cmd = format!(
            "echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency && \
             echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_frequency",
            freq_hz, freq_hz
        );
        if ssh(ip, &cmd) {
            let rssi = ssh_output(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi");
            println!("  {}: OK (RSSI: {})", ip, rssi);
        } else {
            println!("  {}: FAIL", ip);
        }
    }
}

fn cmd_mesh() {
    print_header("MESH START");
    let configs = [
        ("192.168.1.11", "id 11\nlisten 0.0.0.0:5000\npeer 12 192.168.1.12:5000\npeer 13 192.168.1.13:5000"),
        ("192.168.1.12", "id 12\nlisten 0.0.0.0:5000\npeer 11 192.168.1.11:5000\npeer 13 192.168.1.13:5000"),
        ("192.168.1.13", "id 13\nlisten 0.0.0.0:5000\npeer 11 192.168.1.11:5000\npeer 12 192.168.1.12:5000"),
    ];
    for (ip, conf) in &configs {
        print!("  {} -> ", ip);
        if ssh(ip, &format!("echo '{}' > /tmp/mesh.conf && killall trios_meshd 2>/dev/null; /tmp/trios_meshd /tmp/mesh.conf & echo OK", conf)) {
            println!("started");
        } else {
            println!("FAIL");
        }
    }
    println!("\n  Mesh started. Check 'tri status' for meshd state.");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    
    println!("\n  TRI-NET CLI | phi^2 + phi^-2 = 3\n");
    
    match args.get(1).map(|s| s.as_str()) {
        Some("status") => cmd_status(),
        Some("deploy") => cmd_deploy(),
        Some("test") => cmd_test(),
        Some("regen") => cmd_regen(),
        Some("rf") => cmd_rf(args.get(2).map(|s| s.as_str()).unwrap_or("2.4")),
        Some("mesh") => cmd_mesh(),
        _ => {
            println!("Usage: tri <command>");
            println!();
            println!("Commands:");
            println!("  status   Check all boards (ping, kernel, AD9361, meshd)");
            println!("  deploy   Deploy trios_meshd to all boards");
            println!("  test     Run E2E + M1 crypto smoke test");
            println!("  regen    Regenerate gen/ from specs/*.t27 (Rust + Verilog)");
            println!("  rf       Configure AD9361 frequency (2.4, 5.8, 915)");
            println!("  mesh     Start 3-node mesh on all boards");
            println!();
            println!("  phi^2 + phi^-2 = 3");
        }
    }
}
