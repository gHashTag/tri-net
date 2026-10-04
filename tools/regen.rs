// Explicit Rust regeneration and read-only staged artifact verification.
// phi^2 + phi^-2 = 3

use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn checked_output(command: &mut Command, label: &str) -> Result<Vec<u8>> {
    let output = command.output()?;
    if !output.status.success() {
        return Err(format!(
            "{label} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    Ok(output.stdout)
}

fn compiler() -> OsString {
    std::env::var_os("T27C").unwrap_or_else(|| "../t27/target/release/t27c".into())
}

fn generate(compiler: &OsString, subcommand: &str, spec: &Path) -> Result<Vec<u8>> {
    let generated = checked_output(
        Command::new(compiler).arg(subcommand).arg(spec),
        "t27c generation (set T27C to the pinned compiler)",
    )?;
    if generated.is_empty() {
        return Err(format!("empty generated output for {}", spec.display()).into());
    }
    Ok(generated)
}

fn index_blob(path: &str) -> Result<Vec<u8>> {
    checked_output(
        Command::new("git").args(["show", &format!(":{path}")]),
        &format!("staged {path}"),
    )
}

fn normalized_rust(bytes: &[u8]) -> Result<Vec<u8>> {
    let formatter = std::env::var_os("RUSTFMT").unwrap_or_else(|| "rustfmt".into());
    let mut child = Command::new(formatter)
        .args(["--edition", "2021"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut input = child.stdin.take().ok_or("missing formatter stdin")?;
    input.write_all(bytes)?;
    drop(input);
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(format!(
            "rustfmt failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    if output.stdout.is_empty() {
        return Err("empty rustfmt output".into());
    }
    Ok(output.stdout)
}

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Result<Self> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let path = std::env::temp_dir().join(format!(
            "trinet-staged-generation-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn check_staged() -> Result<()> {
    let names = checked_output(
        Command::new("git").args([
            "diff",
            "--cached",
            "--name-only",
            "--diff-filter=ACMR",
            "-z",
        ]),
        "staged file inventory",
    )?;
    let mut paths = Vec::new();
    for name in names
        .split(|byte| *byte == 0)
        .filter(|name| !name.is_empty())
    {
        let name = std::str::from_utf8(name)?;
        if name.starts_with("gen/") {
            paths.push(name.to_owned());
        }
    }
    if paths.is_empty() {
        println!("No staged generated artifacts.");
        return Ok(());
    }
    let compiler = compiler();
    let scratch = Scratch::new()?;
    for name in &paths {
        let path = Path::new(name);
        let segments: Vec<_> = name.split('/').collect();
        if segments.len() != 3 || segments[0] != "gen" {
            return Err(format!("unsupported generated artifact: {name}").into());
        }
        let (extension, subcommand) = match segments[1] {
            "rust" => ("rs", "gen-rust"),
            "zig" => ("zig", "gen"),
            "c" => ("c", "gen-c"),
            _ => return Err(format!("unsupported generated backend: {name}").into()),
        };
        if path.extension().and_then(|s| s.to_str()) != Some(extension) {
            return Err(format!("wrong generated extension: {name}").into());
        }
        let stem = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .ok_or("invalid artifact name")?;
        let spec_name = format!("specs/{stem}.t27");
        let spec = scratch.0.join(format!("{stem}.t27"));
        // Both inputs come from the index. Unstaged changes cannot bless a
        // different source or artifact than the one this commit publishes.
        fs::write(&spec, index_blob(&spec_name)?)?;
        let expected = generate(&compiler, subcommand, &spec)?;
        let staged = index_blob(name)?;
        let matches = if segments[1] == "rust" {
            normalized_rust(&expected)? == normalized_rust(&staged)?
        } else {
            expected == staged
        };
        if !matches {
            return Err(
                format!("VIOLATION L2: staged {name} differs from staged {spec_name}").into(),
            );
        }
        println!("Verified staged {name} from staged {spec_name}.");
    }
    println!("Verified {} staged generated artifacts.", paths.len());
    Ok(())
}

fn regenerate_rust() -> Result<()> {
    let compiler = compiler();
    let mut specs = Vec::new();
    for entry in fs::read_dir("specs")? {
        let path = entry?.path();
        if path.extension().is_some_and(|extension| extension == "t27") {
            specs.push(path);
        }
    }
    specs.sort();
    if specs.is_empty() {
        return Err("no specifications found".into());
    }
    fs::create_dir_all("gen/rust")?;
    for spec in &specs {
        checked_output(Command::new(&compiler).arg("parse").arg(spec), "t27c parse")?;
        let generated = generate(&compiler, "gen-rust", spec)?;
        let stem = spec.file_stem().ok_or("missing spec stem")?;
        let mut output = PathBuf::from("gen/rust").join(stem);
        output.set_extension("rs");
        fs::write(output, generated)?;
    }
    println!("Generated {} Rust files explicitly.", specs.len());
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.is_empty() {
        regenerate_rust()
    } else if args.len() == 1 && args[0] == "--check-staged" {
        check_staged()
    } else {
        Err("usage: trinet-regen [--check-staged] (set T27C to the pinned compiler)".into())
    }
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
