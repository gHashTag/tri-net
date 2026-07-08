// tools/board_init.rs — set unique MAC + IP per board at runtime
// Usage: rustc -O tools/board_init.rs -o tools/board_init && ./tools/board_init <1|2|3>
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::env;

const BOARDS: &[(u8, &str, &str)] = &[
    (1, "02:00:00:00:00:01", "192.168.1.11"),
    (2, "02:00:00:00:00:02", "192.168.1.12"),
    (3, "02:00:00:00:00:03", "192.168.1.13"),
];

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: board_init <1|2|3>");
        std::process::exit(1);
    }

    let board_num: u8 = args[1].parse().unwrap_or(0);
    let entry = BOARDS.iter().find(|(n, _, _)| *n == board_num);

    match entry {
        Some((_, mac, ip)) => {
            println!("Setting board {} MAC={} IP={}", board_num, mac, ip);

            // Remove old IP aliases
            for old_ip in &["192.168.1.10", "192.168.1.11", "192.168.1.12", "192.168.1.13"] {
                let _ = Command::new("ip")
                    .args(&["addr", "del", &format!("{}/24", old_ip), "dev", "eth0"])
                    .output();
            }

            // Set MAC
            let _ = Command::new("ip").args(&["link", "set", "eth0", "down"]).status();
            let _ = Command::new("ip").args(&["link", "set", "eth0", "address", mac]).status();
            let _ = Command::new("ip").args(&["link", "set", "eth0", "up"]).status();

            // Set IP
            let _ = Command::new("ip")
                .args(&["addr", "add", &format!("{}/24", ip), "dev", "eth0"])
                .status();

            println!("Done. Board {} ready at {}", board_num, ip);
        }
        None => {
            eprintln!("Invalid board number. Use 1, 2, or 3.");
            std::process::exit(1);
        }
    }
}
