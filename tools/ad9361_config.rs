// tools/ad9361_config.rs — configure AD9361 on all boards
// Usage: rustc -O tools/ad9361_config.rs -o tools/ad9361_config && ./tools/ad9361_config
// phi^2 + phi^-2 = 3

use std::process::Command;

const BOARDS: &[&str] = &["192.168.1.11", "192.168.1.12", "192.168.1.13"];
const PASSWORD: &str = "analog";
const SSH_OPTS: &[&str] = &["-o", "StrictHostKeyChecking=no", "-o", "PubkeyAuthentication=no", "-o", "ConnectTimeout=5"];

// Thailand NBTC ISM bands
const FREQ_2_4G: u64 = 2_400_000_000;
const FREQ_5_8G: u64 = 5_800_000_000;

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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let freq = if args.len() > 1 && args[1] == "5.8" {
        FREQ_5_8G
    } else {
        FREQ_2_4G
    };
    let bw: u64 = 2_000_000;
    let rate: u64 = 4_000_000;

    println!("=== AD9361 config: {} Hz, {} Hz BW, {} Hz rate ===\n", freq, bw, rate);

    for ip in BOARDS {
        let cmd = format!(
            "echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency && \
             echo {} > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_frequency && \
             echo {} > /sys/bus/iio/devices/iio:device0/in_voltage_rf_bandwidth && \
             echo {} > /sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency && \
             echo {} > /sys/bus/iio/devices/iio:device0/out_voltage_sampling_frequency",
            freq, freq, bw, rate, rate
        );
        if ssh(ip, &cmd) {
            let rssi = Command::new("sshpass")
                .args(&["-p", PASSWORD])
                .args(SSH_OPTS)
                .arg(format!("root@{}", ip))
                .arg("cat /sys/bus/iio/devices/iio:device0/in_voltage0_rssi")
                .output()
                .ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_default();
            println!("  {}: OK (RSSI: {})", ip, rssi);
        } else {
            println!("  {}: FAIL", ip);
        }
    }
    println!("\nDone.");
}
