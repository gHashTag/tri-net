// build.rs — auto-regenerate from .t27 specs if any changed
use std::process::Command;
use std::path::Path;

fn main() {
    let t27c = "../t27/target/release/t27c";
    if !Path::new(t27c).exists() {
        return; // t27c not available, skip regen
    }
    
    // Check if any spec is newer than its generated output
    let specs_dir = Path::new("specs");
    let gen_dir = Path::new("gen/rust");
    
    if !specs_dir.exists() || !gen_dir.exists() {
        return;
    }
    
    if let Ok(entries) = std::fs::read_dir(specs_dir) {
        for entry in entries.flatten() {
            let spec_path = entry.path();
            if spec_path.extension().map_or(false, |e| e == "t27") {
                let name = spec_path.file_stem().unwrap();
                let gen_path = gen_dir.join(format!("{}.rs", name.to_str().unwrap()));
                
                let needs_regen = !gen_path.exists() || {
                    let spec_time = entry.metadata().ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.elapsed().ok())
                        .map_or(0, |d| d.as_secs());
                    let gen_time = std::fs::metadata(&gen_path).ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.elapsed().ok())
                        .map_or(0, |d| d.as_secs());
                    spec_time < gen_time // spec is newer
                };
                
                if needs_regen {
                    let _ = Command::new(t27c)
                        .arg("gen-rust")
                        .arg(&spec_path)
                        .output()
                        .map(|o| {
                            if o.status.success() {
                                let _ = std::fs::write(&gen_path, &o.stdout);
                                println!("cargo:warning=Regenerated {}", name.to_str().unwrap());
                            }
                        });
                }
            }
        }
    }
    
    println!("cargo:rerun-if-changed=specs/");
}
