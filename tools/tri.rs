use std::process::Command;

fn ping(ip: &str) -> bool {
    Command::new("ping").args(&["-c","1","-t","2",ip])
        .output().map(|o| o.status.success()).unwrap_or(false)
}

fn ssh(ip: &str, cmd: &str) -> String {
    let o = Command::new("/opt/homebrew/bin/sshpass")
        .args(&["-p","analog","ssh","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=/dev/null","-o","PubkeyAuthentication=no","-o","ConnectTimeout=5"])
        .arg(format!("root@{}", ip)).arg(cmd).output();
    match o {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => "FAIL".to_string(),
    }
}

fn main() {
    let ip = "192.168.1.10";
    println!("\n  TRI-NET | phi^2 + phi^-2 = 3\n");
    if !ping(ip) { println!("  {}: DEAD", ip); return; }
    println!("  {}: ALIVE", ip);
    println!("    MAC:  {}", ssh(ip, "cat /sys/class/net/eth0/address"));
    println!("    kernel: {}", ssh(ip, "uname -r"));
    println!("    AD9361: {}", ssh(ip, "cat /sys/bus/iio/devices/iio:device0/name"));
    println!("    RSSI:  {}", ssh(ip, "cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi"));
}
