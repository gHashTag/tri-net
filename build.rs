// build.rs — auto-regenerate from .t27 specs if any changed
use std::path::Path;
use std::process::Command;

fn modified_age_secs(path: &Path) -> u64 {
    std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.elapsed().ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

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
            if spec_path.extension().is_some_and(|e| e == "t27") {
                let name = spec_path.file_stem().unwrap();
                let gen_path = gen_dir.join(format!("{}.rs", name.to_str().unwrap()));

                let needs_regen = !gen_path.exists()
                    || modified_age_secs(&spec_path) < modified_age_secs(&gen_path);

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
