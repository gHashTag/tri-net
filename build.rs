// Optional regeneration step. If t27c is on $PATH, re-emit gen/rust/wire.rs
// from specs/wire.t27 so the tree stays honest about spec drift. If t27c is
// not available (CI / most contributor machines), skip silently — gen/rust/
// is committed and does not require t27c to build.
//
// Anchor: phi^2 + phi^-2 = 3.

use std::path::Path;
use std::process::Command;

fn main() {
    let spec = Path::new("specs/wire.t27");
    if !spec.exists() {
        // Not a t27-flipped module tree — nothing to do.
        return;
    }
    println!("cargo:rerun-if-changed=specs/wire.t27");
    println!("cargo:rerun-if-env-changed=T27C");

    // Off by default. Contributors who want spec/gen drift enforcement can set
    // T27C_REGENERATE=1 and either put t27c on $PATH or point T27C at it.
    if std::env::var_os("T27C_REGENERATE").is_none() {
        return;
    }

    let t27c = std::env::var("T27C").unwrap_or_else(|_| "t27c".to_string());
    let out = Command::new(&t27c)
        .args(["gen-rust", "specs/wire.t27"])
        .output();
    let out = match out {
        Ok(o) => o,
        Err(e) => {
            println!("cargo:warning=t27c invocation failed ({e}); skipping regen");
            return;
        }
    };
    if !out.status.success() {
        println!(
            "cargo:warning=t27c gen-rust returned {:?}; keeping committed gen/rust/wire.rs",
            out.status
        );
        return;
    }
    // We do NOT overwrite gen/rust/wire.rs from build.rs, because t27c-0.1.0
    // emits `return ();` on bit-shifts and would clobber the hand-written
    // be_byte / u32_be stubs. Once the parser bug is fixed upstream, delete
    // the stubs from gen/rust/wire.rs and enable direct overwrite here.
    println!("cargo:warning=t27c ran cleanly; compare stdout against gen/rust/wire.rs manually");
}
