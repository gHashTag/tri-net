// tools/tri.rs — TRI-NET unified CLI (v3, all bottlenecks handled)
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::path::Path;

const SSHPASS: &str = "/opt/homebrew/bin/sshpass";
const PASSWORD: &str = "analog";

fn ssh(ip: &str, cmd: &str) -> Option<String> {
    let _ = Command::new("ssh-keygen").args(&["-R", ip, "-f", "/dev/null"]).output();
    let o = Command::new(SSHPASS)
        .args(&["-p", PASSWORD, "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=5"])
        .arg(format!("root@{}", ip))
        .arg(cmd).output().ok()?;
    if o.status.success() { Some(String::from_utf8_lossy(&o.stdout).trim().to_string()) }
    else { None }
}

fn ssh_pipe(ip: &str, data: &[u8], remote_cmd: &str) -> bool {
    let mut child = Command::new(SSHPASS)
        .args(&["-p", PASSWORD, "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=10"])
        .arg(format!("root@{}", ip))
        .arg(remote_cmd)
        .stdin(std::process::Stdio::piped())
        .spawn().unwrap();
    if let Some(stdin) = child.stdin.as_mut() { use std::io::Write; stdin.write_all(data).ok(); }
    child.wait().map(|s| s.success()).unwrap_or(false)
}

fn ping(ip: &str) -> bool {
    Command::new("ping").args(&["-c","1","-t","2",ip])
        .output().map(|o| o.status.success()).unwrap_or(false)
}

fn arp_d(ip: &str) { let _ = Command::new("arp").args(&["-d", ip]).output(); }

fn header(t: &str) { println!("\n=== {} ===\n", t); }

// tri status
fn cmd_status() {
    header("STATUS");
    let ips = if ping("192.168.1.11") { vec!["192.168.1.11","192.168.1.12","192.168.1.13"] }
              else if ping("192.168.1.10") { vec!["192.168.1.10"] }
              else { vec![] };
    if ips.is_empty() { println!("  No boards. Power-cycle needed."); return; }
    for ip in ips {
        if !ping(ip) { println!("  {}: DEAD", ip); continue; }
        let mac = ssh(ip, "cat /sys/class/net/eth0/address").unwrap_or_default();
        let krn = ssh(ip, "uname -r").unwrap_or_default();
        let ad  = ssh(ip, "cat /sys/bus/iio/devices/iio:device0/name 2>/dev/null").unwrap_or_default();
        let rs  = ssh(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi 2>/dev/null").unwrap_or_default();
        let md  = ssh(ip, "pgrep trios_meshd > /dev/null && echo running || echo stopped").unwrap_or_default();
        println!("  {} MAC={} kernel={} AD9361={} RSSI={} meshd={}",
                 ip, mac, krn, ad, rs, md);
    }
}

// tri separate — ARP dance for runtime IP split
fn cmd_separate() {
    header("SEPARATE (.10 -> .11/.12/.13)");
    if !ping("192.168.1.10") { println!("  .10 not reachable"); return; }
    for target in &["192.168.1.11","192.168.1.12","192.168.1.13"] {
        arp_d("192.168.1.10");
        match ssh("192.168.1.10", &format!("ip addr add {}/24 dev eth0 2>/dev/null; echo OK", target)) {
            Some(r) if r.contains("OK") => println!("  {} -> OK", target),
            _ => println!("  {} -> FAIL", target),
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    println!("\n  Result:");
    for ip in &["192.168.1.11","192.168.1.12","192.168.1.13"] {
        println!("    {}: {}", ip, if ping(ip) { "ALIVE" } else { "DEAD" });
    }
}

// tri flash-uenv N — modify uEnv.txt on SD card via SSH (no card reader!)
fn cmd_flash_uenv(board: u8) {
    header(&format!("FLASH UENV — Board {} (via SSH, no card reader)", board));
    let ip = "192.168.1.10";
    if !ping(ip) { println!("  Board not reachable on .10"); return; }

    let mac = format!("02:00:00:00:00:{:02x}", board);
    let board_ip = format!("192.168.1.1{}", board);

    // Read current uEnv, modify ethaddr+ipaddr, add boardargs
    let script = format!(r#"
mount /dev/mmcblk0p1 /mnt/sd 2>/dev/null
sed -i 's/^ethaddr=.*/ethaddr={}/' /mnt/sd/uEnv.txt
sed -i 's/^ipaddr=.*/ipaddr={}/' /mnt/sd/uEnv.txt
sed -i '/^boardargs=/d; /^uenvcmd=/d' /mnt/sd/uEnv.txt
echo '' >> /mnt/sd/uEnv.txt
echo 'boardargs=setenv bootargs ${{bootargs}} ip={}::192.168.1.1:255.255.255.0::eth0:off' >> /mnt/sd/uEnv.txt
echo 'uenvcmd=run boardargs; run sdboot' >> /mnt/sd/uEnv.txt
grep '^ethaddr' /mnt/sd/uEnv.txt
grep '^ipaddr=' /mnt/sd/uEnv.txt
grep '^boardargs' /mnt/sd/uEnv.txt
sync; umount /mnt/sd
echo DONE
"#, mac, board_ip, board_ip);

    match ssh(ip, &script) {
        Some(out) => println!("  {}", out),
        None => println!("  FAIL — SSH error. arp -d and retry."),
    }
    println!("\n  Power-cycle board {}. It will boot on {} with MAC {}.", board, board_ip, mac);
}

// tri deploy — push binary
fn cmd_deploy() {
    header("DEPLOY");
    let bin = "target/armv7-unknown-linux-musleabihf/release/trios_meshd";
    if !Path::new(bin).exists() { println!("  Run: cargo zigbuild --release --target armv7-unknown-linux-musleabihf"); return; }
    let data = std::fs::read(bin).unwrap();
    let ips: Vec<&str> = if ping("192.168.1.11") { vec!["192.168.1.11","192.168.1.12","192.168.1.13"] }
                         else { vec!["192.168.1.10"] };
    for ip in ips {
        if !ping(ip) { continue; }
        print!("  {} -> ", ip);
        if ssh_pipe(ip, &data, "cat > /tmp/trios_meshd && chmod +x /tmp/trios_meshd && echo OK") {
            println!("OK");
        } else { println!("FAIL"); }
    }
}

// tri test — M1 crypto
fn cmd_test() {
    header("M1 CRYPTO");
    let ip = if ping("192.168.1.11") { "192.168.1.11" } else { "192.168.1.10" };
    if !ping(ip) { println!("  DEAD"); return; }
    let smoke = "target/armv7-unknown-linux-musleabihf/release/smoke-m1";
    if Path::new(smoke).exists() {
        let data = std::fs::read(smoke).unwrap();
        ssh_pipe(ip, &data, "cat > /tmp/smoke-m1 && chmod +x /tmp/smoke-m1");
    }
    match ssh(ip, "/tmp/smoke-m1 2>&1") {
        Some(out) => for l in out.lines() { println!("  {}", l); },
        None => println!("  FAIL"),
    }
}

// tri mesh — 3-node loopback mesh on board
fn cmd_mesh() {
    header("MESH (loopback, 3-node on 1 board)");
    let ip = if ping("192.168.1.11") { "192.168.1.11" } else { "192.168.1.10" };
    if !ping(ip) { println!("  DEAD"); return; }
    let script = r#"
killall -9 trios_meshd 2>/dev/null; sleep 1
printf "id 11\nlisten 127.0.0.1:5001\npeer 12 127.0.0.1:5002\npeer 13 127.0.0.1:5003\n" > /tmp/n11.conf
printf "id 12\nlisten 127.0.0.1:5002\npeer 11 127.0.0.1:5001\npeer 13 127.0.0.1:5003\n" > /tmp/n12.conf
printf "id 13\nlisten 127.0.0.1:5003\npeer 11 127.0.0.1:5001\npeer 12 127.0.0.1:5002\n" > /tmp/n13.conf
/tmp/trios_meshd /tmp/n12.conf > /tmp/n12.log 2>&1 &
sleep 1; /tmp/trios_meshd /tmp/n13.conf > /tmp/n13.log 2>&1 &
sleep 1; TRIOS_SEND=13:hello_from_11 /tmp/trios_meshd /tmp/n11.conf > /tmp/n11.log 2>&1 &
sleep 8; killall trios_meshd 2>/dev/null
echo "=== N11 ==="; cat /tmp/n11.log
echo "=== N13 ==="; tail -3 /tmp/n13.log
"#;
    match ssh(ip, script) {
        Some(out) => println!("{}", out),
        None => println!("  FAIL"),
    }
}

// tri regen
fn cmd_regen() {
    header("REGEN");
    let t27c = "../t27/target/release/t27c";
    if !Path::new(t27c).exists() { println!("  t27c not found"); return; }
    let mut count = 0;
    for entry in std::fs::read_dir("specs").ok().into_iter().flatten() {
        if let Ok(e) = entry {
            let p = e.path();
            if p.extension().map_or(false, |x| x == "t27") {
                let n = p.file_stem().unwrap().to_str().unwrap();
                if let Ok(o) = Command::new(t27c).arg("gen-rust").arg(&p).output() {
                    if o.status.success() { let _ = std::fs::write(format!("gen/rust/{}.rs", n), &o.stdout); }
                }
                if let Ok(o) = Command::new(t27c).arg("gen-verilog").arg(&p).output() {
                    if o.status.success() { let _ = std::fs::create_dir_all("gen/verilog"); let _ = std::fs::write(format!("gen/verilog/{}.v", n), &o.stdout); }
                }
                count += 1;
            }
        }
    }
    println!("  {} specs -> Rust + Verilog", count);
}

// tri rf FREQ
fn cmd_rf(freq: &str) {
    header(&format!("RF {} GHz", freq));
    let hz: u64 = match freq { "2.4"=>2400000000, "5.8"=>5800000000, "915"=>915000000, _=>2400000000 };
    let ips: Vec<&str> = if ping("192.168.1.11") { vec!["192.168.1.11","192.168.1.12","192.168.1.13"] }
                         else if ping("192.168.1.10") { vec!["192.168.1.10"] } else { vec![] };
    if ips.is_empty() { println!("  No boards"); return; }
    for ip in ips {
        let cmd = format!("echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency && echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_frequency", hz, hz);
        match ssh(ip, &cmd) {
            Some(_) => { let r = ssh(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi").unwrap_or_default(); println!("  {}: RSSI {}", ip, r); }
            None => println!("  {}: FAIL", ip),
        }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    println!("\n  TRI-NET CLI v3 | phi^2 + phi^-2 = 3");
    match a.get(1).map(|s| s.as_str()) {
        Some("status") => cmd_status(),
        Some("separate") => cmd_separate(),
        Some("flash-uenv") => { let n: u8 = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(1); cmd_flash_uenv(n); }
        Some("deploy") => cmd_deploy(),
        Some("test") => cmd_test(),
        Some("mesh") => cmd_mesh(),
        Some("regen") => cmd_regen(),
        Some("rf") => cmd_rf(a.get(2).map(|s| s.as_str()).unwrap_or("2.4")),
        _ => { println!(r"
Usage: tri <command> [args]

  status        Check boards (ping, MAC, kernel, AD9361, meshd)
  separate      Runtime IP split (.10 -> .11/.12/.13 via ARP dance)
  flash-uenv N  Modify uEnv.txt on SD card via SSH (N = 1/2/3)
                Unique MAC + IP. NO card reader needed!
  deploy        Push trios_meshd binary to board(s)
  test          M1 crypto smoke (X25519 + ChaCha20-Poly1305)
  mesh          3-node loopback mesh on 1 board (ETX convergence)
  regen         Regenerate gen/ from specs/*.t27
  rf FREQ       Configure AD9361 (2.4, 5.8, 915 MHz)

Bottlenecks handled:
  B1  FTDI blocks card reader  B2  Identical MAC collision
  B3  SSH host key changes     B4  ipaddr does NOT set Linux IP
  B5  Don't delete .10 via SSH B6  sshpass full path
  B7  macOS blocks dd          B8  .Spotlight junk files
  B9  Cold power cycle only    B10 QSPI driver bug

phi^2 + phi^-2 = 3"); }
    }
}
