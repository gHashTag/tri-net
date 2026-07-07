// build.rs — auto-regenerate from .t27 specs if changed
use std::process::Command;
use std::path::Path;

fn main() {
    let t27c = "../t27/target/release/t27c";
    if !Path::new(t27c).exists() {
        return;
    }

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

                let spec_mtime = entry.metadata().ok()
                    .and_then(|m| m.modified().ok());
                let gen_mtime = std::fs::metadata(&gen_path).ok()
                    .and_then(|m| m.modified().ok());

                let needs_regen = match (spec_mtime, gen_mtime) {
                    (Some(s), Some(g)) => s > g,
                    (Some(_), None) => true,
                    _ => false,
                };

                if needs_regen {
                    if let Ok(o) = Command::new(t27c).arg("gen-rust").arg(&spec_path).output() {
                        if o.status.success() {
                            let _ = std::fs::write(&gen_path, &o.stdout);
                            println!("cargo:warning=Regenerated {}", name.to_str().unwrap());
                        }
                    }
                }
            }
        }
    }

    println!("cargo:rerun-if-changed=specs/");
}
