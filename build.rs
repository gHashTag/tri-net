// build.rs — auto-regenerate from .t27 specs when a spec is newer than its
// generated .rs sibling. Skips silently if t27c is not built or specs/ is
// absent (e.g. `cargo publish` sandbox).
//
// phi^2 + phi^-2 = 3
use std::path::Path;
use std::process::Command;
use std::time::SystemTime;

fn mtime(path: &Path) -> SystemTime {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH)
}

fn main() {
    let t27c = "../t27/target/release/t27c";
    if !Path::new(t27c).exists() {
        return; // t27c not available, skip regen
    }

    let specs_dir = Path::new("specs");
    let gen_dir = Path::new("gen/rust");
    if !specs_dir.exists() || !gen_dir.exists() {
        return;
    }

    let entries = match std::fs::read_dir(specs_dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let spec_path = entry.path();
        if spec_path.extension().and_then(|s| s.to_str()) != Some("t27") {
            continue;
        }
        let name = match spec_path.file_stem().and_then(|s| s.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let gen_path = gen_dir.join(format!("{name}.rs"));

        let needs_regen = !gen_path.exists() || mtime(&spec_path) > mtime(&gen_path);

        if needs_regen {
            if let Ok(o) = Command::new(t27c).arg("gen-rust").arg(&spec_path).output() {
                if o.status.success() {
                    let _ = std::fs::write(&gen_path, &o.stdout);
                    println!("cargo:warning=Regenerated {name}");
                }
            }
        }
    }

    println!("cargo:rerun-if-changed=specs/");
}
