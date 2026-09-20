// tools/deploy.rs — deploy tri-net binaries to P201Mini boards
// Usage: rustc -O tools/deploy.rs -o tools/deploy && ./tools/deploy
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::path::Path;

const BOARDS: &[&str] = &["192.168.1.11", "192.168.1.12", "192.168.1.13"];
const PASSWORD: &str = "analog";
const SSH_OPTS: &[&str] = &["-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no", "-o", "ConnectTimeout=10"];

fn main() {
    let bin_dir = "target/armv7-unknown-linux-musleabihf/release";
    let binaries = ["trios_meshd", "smoke-m1"];

    for bin in &binaries {
        let path = format!("{}/{}", bin_dir, bin);
        if !Path::new(&path).exists() {
            eprintln!("SKIP: {} not found. Run cargo zigbuild first.", path);
            continue;
        }
    }

    for ip in BOARDS {
        println!("=== Deploy to {} ===", ip);
        for bin in &binaries {
            let path = format!("{}/{}", bin_dir, bin);
            if !Path::new(&path).exists() { continue; }

            let data = std::fs::read(&path).expect("read binary");
            
            let mut child = Command::new("sshpass")
                .args(&["-p", PASSWORD])
                .args(SSH_OPTS)
                .arg(format!("root@{}", ip))
                .arg(format!("cat > /tmp/{} && chmod +x /tmp/{}", bin, bin))
                .stdin(std::process::Stdio::piped())
                .spawn()
                .expect("ssh");

            if let Some(stdin) = child.stdin.as_mut() {
                use std::io::Write;
                stdin.write_all(&data).ok();
            }
            
            let status = child.wait().expect("wait");
            println!("  {}: {}", bin, if status.success() { "OK" } else { "FAIL" });
        }
    }
    println!("\nDeploy complete.");
}
