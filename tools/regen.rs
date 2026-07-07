// tools/regen.rs — regenerate gen/rust/ from specs/*.t27
// Usage: rustc -O tools/regen.rs -o tools/regen && ./tools/regen
// phi^2 + phi^-2 = 3

use std::process::Command;
use std::path::{Path, PathBuf};

fn main() {
    let t27c = std::env::var("T27C")
        .unwrap_or_else(|_| "../t27/target/release/t27c".to_string());
    
    if !Path::new(&t27c).exists() {
        eprintln!("ERROR: t27c not found at {}", t27c);
        eprintln!("Build: cd ../t27 && cargo build --release");
        std::process::exit(1);
    }
    
    let specs_dir = Path::new("specs");
    let gen_dir = Path::new("gen/rust");
    
    if !specs_dir.is_dir() {
        eprintln!("ERROR: specs/ not found");
        std::process::exit(1);
    }
    
    std::fs::create_dir_all(gen_dir).ok();
    
    let mut count = 0u32;
    let mut failed = 0u32;
    
    if let Ok(entries) = std::fs::read_dir(specs_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "t27") {
                let name = path.file_stem().unwrap().to_str().unwrap();
                let output = gen_dir.join(format!("{}.rs", name));
                
                let result = Command::new(&t27c)
                    .arg("parse")
                    .arg(&path)
                    .output();
                
                match result {
                    Ok(o) if o.status.success() => {
                        let gen_result = Command::new(&t27c)
                            .arg("gen-rust")
                            .arg(&path)
                            .output();
                        if let Ok(go) = gen_result {
                            if go.status.success() {
                                std::fs::write(&output, &go.stdout).ok();
                                count += 1;
                            } else {
                                eprintln!("  GEN FAIL: {}", name);
                                failed += 1;
                            }
                        }
                    }
                    _ => {
                        eprintln!("  PARSE FAIL: {}", name);
                        failed += 1;
                    }
                }
            }
        }
    }
    
    println!("Generated: {} files", count);
    if failed > 0 {
        eprintln!("Failed: {} files", failed);
        std::process::exit(1);
    }
    println!("All specs generated.");
}
