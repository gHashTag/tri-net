// Persistent compile gate for the whole generated Rust corpus (#399).
//
// The drift check proves that gen/rust/<spec>.rs equals the pinned t27c
// output for specs/<spec>.t27. It does not prove that the output is valid
// Rust: most gen/rust modules are not reachable from any Cargo target, so a
// matching but uncompilable artifact passed every gate. This test compiles
// every committed gen/rust/*.rs as its own library crate with
// `-D warnings`, under the generated-module policy used by the crate
// (`allow(clippy::all, unused)`), and fails on any error.
//
// Negative controls run first through the same compile path: the defect
// classes that #399 found must be rejected, so a gate that silently accepts
// everything cannot pass.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::thread;

/// Number of committed gen/rust artifacts. Raise it when a spec gains a Rust
/// artifact; a lower count fails, so coverage cannot shrink silently.
const CORPUS_FLOOR: usize = 102;

const WRAPPER_POLICY: &str = "#![allow(clippy::all, unused)]\n";

fn rustc() -> String {
    std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string())
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join("gen_rust_corpus")
        .join(name);
    fs::create_dir_all(&dir).expect("create scratch directory");
    dir
}

/// Compile `module` as a library crate wrapped in the generated-module
/// policy. Returns the compiler diagnostics on failure.
fn compile_module(module: &Path, out_dir: &Path, crate_name: &str) -> Result<(), String> {
    let wrapper = out_dir.join(format!("{crate_name}_wrapper.rs"));
    let module = module.canonicalize().expect("canonical module path");
    let source = format!(
        "{WRAPPER_POLICY}#[path = {:?}]\nmod generated;\n",
        module.to_string_lossy()
    );
    fs::write(&wrapper, source).expect("write wrapper crate");
    let output = Command::new(rustc())
        .args(["--edition=2021", "--crate-type=lib", "-D", "warnings"])
        .arg("--crate-name")
        .arg(crate_name)
        .arg("--out-dir")
        .arg(out_dir)
        .arg(&wrapper)
        .output()
        .expect("run rustc");
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

fn first_errors(diagnostics: &str) -> String {
    diagnostics
        .lines()
        .filter(|line| line.starts_with("error") || line.trim_start().starts_with("-->"))
        .take(8)
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn negative_controls_are_rejected() {
    let dir = scratch_dir("controls");
    let controls = [
        (
            "assigned_value_argument",
            "pub fn clamp(limit: u32, value: u32) -> u32 {\n    if value > limit {\n        value = limit;\n    }\n    value\n}\n",
            "E0384",
        ),
        (
            "written_array_argument",
            "pub fn clear(slots: [u32; 4], index: u32) -> u32 {\n    slots[index as usize] = 0;\n    1\n}\n",
            "E0594",
        ),
        (
            "u32_repeat_count",
            "pub const COUNT: u32 = 4;\npub fn zeros() -> [u32; COUNT as usize] {\n    [0; COUNT]\n}\n",
            "E0308",
        ),
        (
            "useless_unsigned_comparison",
            "pub fn non_negative(value: u32) -> bool {\n    value >= 0\n}\n",
            "unused_comparisons",
        ),
        (
            "lowercase_constant",
            "pub const type_documentation: u32 = 2;\n",
            "non_upper_case_globals",
        ),
    ];
    for (name, body, expected) in controls {
        let module = dir.join(format!("{name}.rs"));
        fs::write(&module, body).expect("write control module");
        match compile_module(&module, &dir, name) {
            Ok(()) => panic!("negative control {name} compiled; the gate accepts {expected}"),
            Err(diagnostics) => assert!(
                diagnostics.contains(expected),
                "negative control {name} failed without {expected}:\n{diagnostics}"
            ),
        }
    }
    // Positive control: the same path accepts a valid module, so the
    // rejections above come from the defects, not from the harness.
    let valid = dir.join("valid_control.rs");
    fs::write(
        &valid,
        "pub fn clamp(limit: u32, value: u32) -> u32 {\n    let mut v = value;\n    if v > limit {\n        v = limit;\n    }\n    v\n}\n",
    )
    .expect("write positive control");
    if let Err(diagnostics) = compile_module(&valid, &dir, "valid_control") {
        panic!("positive control failed to compile:\n{diagnostics}");
    }
}

#[test]
fn every_generated_rust_module_compiles() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut modules: Vec<PathBuf> = fs::read_dir(root.join("gen/rust"))
        .expect("read gen/rust")
        .map(|entry| entry.expect("gen/rust entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "rs"))
        .collect();
    modules.sort();
    assert!(
        modules.len() >= CORPUS_FLOOR,
        "gen/rust has {} modules, below the floor of {CORPUS_FLOOR}",
        modules.len()
    );

    let dir = scratch_dir("corpus");
    let next = AtomicUsize::new(0);
    let failures = Mutex::new(Vec::new());
    let workers = thread::available_parallelism().map_or(2, |n| n.get().min(8));
    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(module) = modules.get(index) else {
                    break;
                };
                let stem = module
                    .file_stem()
                    .expect("module stem")
                    .to_string_lossy()
                    .into_owned();
                let crate_name = format!("gen_{stem}");
                if let Err(diagnostics) = compile_module(module, &dir, &crate_name) {
                    failures.lock().expect("failure list").push(format!(
                        "gen/rust/{stem}.rs:\n{}",
                        first_errors(&diagnostics)
                    ));
                }
            });
        }
    });

    let mut failures = failures.into_inner().expect("failure list");
    failures.sort();
    println!(
        "gen/rust corpus: {} of {} modules compile",
        modules.len() - failures.len(),
        modules.len()
    );
    assert!(
        failures.is_empty(),
        "{} generated Rust module(s) do not compile with -D warnings:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}
