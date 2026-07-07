// tools/e2e_test.rs — E2E test runner for 3 P201Mini boards
// Usage: rustc -O tools/e2e_test.rs -o tools/e2e && ./tools/e2e
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::net::{TcpStream, SocketAddr};
use std::time::Duration;
use std::str::FromStr;

const BOARDS: &[&str] = &["192.168.1.11", "192.168.1.12", "192.168.1.13"];
const PASSWORD: &str = "analog";
const SSH_OPTS: &[&str] = &["-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no", "-o", "ConnectTimeout=5"];

fn ssh(ip: &str, cmd: &str) -> Option<String> {
    let result = Command::new("sshpass")
        .args(&["-p", PASSWORD])
        .args(SSH_OPTS)
        .arg(format!("root@{}", ip))
        .arg(cmd)
        .output()
        .ok()?;
    if result.status.success() {
        Some(String::from_utf8_lossy(&result.stdout).to_string())
    } else {
        None
    }
}

fn ping(ip: &str) -> bool {
    Command::new("ping")
        .args(&["-c", "1", "-t", "2", ip])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn main() {
    println!("======================================================");
    println!("  TRI-NET E2E TEST");
    println!("======================================================\n");

    let mut pass = 0u32;
    let mut fail = 0u32;

    for (i, ip) in BOARDS.iter().enumerate() {
        let n = i + 1;
        println!("--- Board {} ({}) ---", n, ip);

        if !ping(ip) {
            println!("  FAIL: ping\n");
            fail += 1;
            continue;
        }
        println!("  PASS: ping");
        pass += 1;

        if let Some(out) = ssh(ip, "uname -r") {
            println!("  PASS: kernel {}", out.trim());
            pass += 1;
        } else {
            println!("  FAIL: ssh\n");
            fail += 1;
            continue;
        }

        if let Some(out) = ssh(ip, "cat /sys/bus/iio/devices/iio:device0/name") {
            println!("  PASS: AD9361 {}", out.trim());
            pass += 1;
        } else {
            println!("  FAIL: AD9361");
            fail += 1;
        }

        if let Some(out) = ssh(ip, "ip addr show eth0 | grep 'inet '") {
            println!("  PASS: eth {}", out.trim());
            pass += 1;
        } else {
            println!("  FAIL: eth");
            fail += 1;
        }
        println!();
    }

    // Mesh connectivity
    println!("--- Mesh ---");
    for ip in BOARDS {
        for other in BOARDS {
            if ip != other {
                let ok = ssh(ip, &format!("ping -c 1 -W 1 {}", other)).is_some();
                if ok {
                    println!("  {} -> {}: ALIVE", ip, other);
                    pass += 1;
                } else {
                    println!("  {} -> {}: FAIL", ip, other);
                    fail += 1;
                }
            }
        }
    }

    println!("\n======================================================");
    println!("  RESULTS: {} passed, {} failed", pass, fail);
    println!("  phi^2 + phi^-2 = 3");
    println!("======================================================");
}
