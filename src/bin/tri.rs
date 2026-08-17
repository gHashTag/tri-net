//! tri - the operator's command line for a TRI-NET node.
//!
//! Why this exists. The README opens its Metrics table with "Все числа - с
//! on-device логов, без hearsay", and on 2026-08-17 three of those numbers had
//! drifted from the repository they claim to describe: 110 test blocks against
//! 118 actual, 4 463 source lines against 6 697, and one ported T27 spec
//! against 86. Nothing was measured wrongly. The numbers were written once and
//! never recomputed, which is a different failure and the only one a document
//! cannot catch by itself.
//!
//! So the commands here are built around one rule: a number that a machine can
//! re-derive is never stored as prose. `tri facts` recomputes the repository
//! side of the Metrics table and exits non-zero when the stored value and the
//! measured value disagree. `tri status` checks that every claim marked `hw`
//! still has its evidence file on disk.
//!
//! The second rule follows from the same session. A probe that could not run is
//! reported as UNKNOWN, never as zero and never as a failure. `tri boards`
//! distinguishes "answered", "did not answer" and "not probed", because a node
//! that was never contacted is not a node that is down.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const FACTS_FILE: &str = "tri-facts.json";

/// One re-derivable claim: what it asserts, and how a machine checks it.
struct Fact {
    key: &'static str,
    claim: &'static str,
    /// Why this exact value and not another. A number without this is a number
    /// nobody can audit.
    note: &'static str,
    measure: fn(&Path) -> Result<i64, String>,
}

fn facts() -> Vec<Fact> {
    vec![
        Fact {
            key: "rust_test_blocks",
            claim: "Rust #[test] blocks in the repository",
            note: "counted over src/ and tests/; the README's own source column \
                   says grep -rE '^\\s*#\\[test\\]' src tests",
            measure: |root| count_matching(root, &["src", "tests"], "rs", |l| {
                l.trim_start().starts_with("#[test]")
            }),
        },
        Fact {
            key: "rust_source_lines",
            claim: "Rust source lines",
            note: "every .rs file under src/, counted by line, matching the \
                   README's find src -name '*.rs' | xargs wc -l",
            measure: |root| count_lines(root, &["src"], "rs"),
        },
        Fact {
            key: "t27_specs",
            claim: "T27 spec files present",
            note: "the README said 1 (specs/wire.t27) while 86 were on disk; \
                   the count is the whole point of the row",
            measure: |root| count_files(root, &["specs"], "t27"),
        },
        Fact {
            key: "rust_source_files",
            claim: "Rust source files",
            note: "a denominator for the line count, so a large change in one \
                   is visible against the other",
            measure: |root| count_files(root, &["src"], "rs"),
        },
        Fact {
            key: "declared_binaries",
            claim: "binaries declared in Cargo.toml",
            note: "autobins is off because binaries in src/bin/ have not \
                   compiled (issue #96); the declared count is therefore not \
                   the file count, and the gap is meant to be visible",
            measure: |root| {
                let s = read(&root.join("Cargo.toml"))?;
                Ok(s.lines().filter(|l| l.trim() == "[[bin]]").count() as i64)
            },
        },
        Fact {
            key: "binary_sources",
            claim: "binary sources in src/bin/",
            note: "compare against declared_binaries: the difference is the \
                   number of binaries that exist but are not built",
            measure: |root| count_files(root, &["src/bin"], "rs"),
        },
    ]
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = repo_root();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("help");
    let rest: Vec<&str> = args.iter().skip(1).map(|s| s.as_str()).collect();

    let code = match cmd {
        "facts" => cmd_facts(&root, &rest),
        "status" => cmd_status(&root),
        "boards" => cmd_boards(&rest),
        "smoke" => cmd_smoke(&root),
        "help" | "-h" | "--help" => {
            usage();
            0
        }
        other => {
            eprintln!("tri: unknown command '{other}'");
            usage();
            2
        }
    };
    std::process::exit(code);
}

fn usage() {
    println!(
        "tri - operator command line for a TRI-NET node

  tri facts            recompute the repository metrics and diff them against
                       {FACTS_FILE}; exit 1 on any disagreement
  tri facts --update   store the measured values as the new baseline
  tri status           check that every claim marked hw still has its evidence
                       file on disk
  tri boards           probe the node addresses; answered / silent / not probed
  tri smoke            run the M1 crypto smoke test

A number this tool can re-derive is never trusted from prose. A probe that did
not run is reported UNKNOWN, never as zero."
    );
}

// ---------------------------------------------------------------- facts

fn cmd_facts(root: &Path, args: &[&str]) -> i32 {
    let update = args.contains(&"--update");
    let stored = load_facts(root);
    let mut measured: BTreeMap<String, i64> = BTreeMap::new();
    let mut drift = 0usize;
    let mut unmeasurable = 0usize;

    println!("{:<22} {:>10} {:>10}  {}", "fact", "stored", "measured", "verdict");
    println!("{}", "-".repeat(72));

    for f in facts() {
        match (f.measure)(root) {
            Err(e) => {
                // Could not measure is not a disagreement. Saying otherwise
                // would make an absent probe look like a failed one.
                println!(
                    "{:<22} {:>10} {:>10}  UNKNOWN ({e})",
                    f.key,
                    stored.get(f.key).map(|v| v.to_string()).unwrap_or("-".into()),
                    "-"
                );
                unmeasurable += 1;
            }
            Ok(m) => {
                measured.insert(f.key.to_string(), m);
                match stored.get(f.key) {
                    None => {
                        println!("{:<22} {:>10} {:>10}  NEW     {}", f.key, "-", m, f.claim);
                        drift += 1;
                    }
                    Some(&s) if s == m => {
                        println!("{:<22} {:>10} {:>10}  agrees  {}", f.key, s, m, f.claim)
                    }
                    Some(&s) => {
                        println!("{:<22} {:>10} {:>10}  DISAGREES", f.key, s, m);
                        println!("{:<22} {}", "", f.claim);
                        println!("{:<22} {}", "", f.note);
                        drift += 1;
                    }
                }
            }
        }
    }

    println!();
    if update {
        match write_facts(root, &measured) {
            Ok(p) => {
                println!("stored the measured values in {}", p.display());
                return 0;
            }
            Err(e) => {
                eprintln!("could not write the baseline: {e}");
                return 1;
            }
        }
    }

    if drift > 0 {
        println!(
            "FACTS DISAGREE - {drift} of {} re-derivable numbers no longer match the \
             repository.",
            facts().len()
        );
        println!(
            "A stored number that changed does not mean the number needs editing. It \
             means the repository moved, and the note on each row says what would have \
             to be true for the new value to be right. Run 'tri facts --update' once \
             the new value is the intended one."
        );
        return 1;
    }
    if unmeasurable > 0 {
        println!(
            "FACTS INCOMPLETE - {unmeasurable} could not be measured here; the rest agree."
        );
        return 2;
    }
    println!("FACTS AGREE - all {} re-derived from the repository.", facts().len());
    0
}

fn load_facts(root: &Path) -> BTreeMap<String, i64> {
    let mut out = BTreeMap::new();
    let Ok(text) = fs::read_to_string(root.join(FACTS_FILE)) else {
        return out;
    };
    // Deliberately a hand-rolled scan of "key": number rather than a serde
    // model: the file is a flat map, and a parser that cannot fail on shape is
    // one less thing to keep in step with the schema.
    for line in text.lines() {
        let line = line.trim().trim_end_matches(',');
        let Some((k, v)) = line.split_once(':') else { continue };
        let k = k.trim().trim_matches('"');
        let v = v.trim();
        if let Ok(n) = v.parse::<i64>() {
            out.insert(k.to_string(), n);
        }
    }
    out
}

fn write_facts(root: &Path, measured: &BTreeMap<String, i64>) -> Result<PathBuf, String> {
    let path = root.join(FACTS_FILE);
    let mut s = String::from("{\n");
    let n = measured.len();
    for (i, (k, v)) in measured.iter().enumerate() {
        s.push_str(&format!("  \"{k}\": {v}{}\n", if i + 1 < n { "," } else { "" }));
    }
    s.push_str("}\n");
    fs::write(&path, s).map_err(|e| e.to_string())?;
    Ok(path)
}

// ---------------------------------------------------------------- status

/// Claims the README marks `hw`, with the file it cites as evidence. A claim
/// whose evidence file is gone is reported, because "hw" without a log on disk
/// is the same shape of assertion this tool exists to refuse.
const HW_CLAIMS: &[(&str, &str)] = &[
    ("M1 crypto on ARM (X25519 + ChaCha20-Poly1305)", "smoke/M1_RESULTS.md"),
    ("AD9361 5.8 GHz PHY digital loopback", "radio/README.md"),
];

const SIM_CLAIMS: &[&str] = &[
    "M2 TUN/IP routing (ETX + discovery)",
    "M3 iperf3 over 2 hops",
    "M4 3-node triangle, shared uplink",
];

fn cmd_status(root: &Path) -> i32 {
    let mut missing = 0;
    println!("claims marked hw - evidence must be on disk\n");
    for (claim, ev) in HW_CLAIMS {
        let p = root.join(ev);
        if p.is_file() {
            let bytes = fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
            println!("  [ok]      {claim}\n            {ev} ({bytes} bytes)");
        } else {
            println!("  [MISSING] {claim}\n            {ev} is not on disk");
            missing += 1;
        }
    }
    println!("\nclaims marked -sim - no on-device run is asserted\n");
    for c in SIM_CLAIMS {
        println!("  [-sim]    {c}");
    }
    println!(
        "\nA -sim row is not a weaker version of hw. It is the absence of a run, and \
         it stays that way until a log says otherwise."
    );
    if missing > 0 {
        println!("\nSTATUS FAIL - {missing} hw claim(s) have no evidence file.");
        return 1;
    }
    println!("\nSTATUS OK - every hw claim has its evidence file.");
    0
}

// ---------------------------------------------------------------- boards

/// The three P203 Mini nodes. Override with TRI_NODES as a comma-separated list.
fn node_addrs() -> Vec<String> {
    match std::env::var("TRI_NODES") {
        Ok(v) if !v.trim().is_empty() => {
            v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
        }
        _ => vec![
            "192.168.1.10".into(),
            "192.168.1.11".into(),
            "192.168.1.12".into(),
        ],
    }
}

fn cmd_boards(args: &[&str]) -> i32 {
    let addrs = node_addrs();
    println!("probing {} node address(es)\n", addrs.len());
    let mut answered = 0;
    let mut silent = 0;
    let mut unprobed = 0;

    for a in &addrs {
        match ping(a) {
            Ok(true) => {
                println!("  [answered]   {a}");
                answered += 1;
            }
            Ok(false) => {
                println!("  [silent]     {a}");
                silent += 1;
            }
            Err(e) => {
                // No ping binary, no permission, no route: the probe did not
                // run. That is not the same as the node being down and is not
                // reported as such.
                println!("  [NOT PROBED] {a} - {e}");
                unprobed += 1;
            }
        }
    }

    println!();
    println!("answered {answered}, silent {silent}, not probed {unprobed}");
    if unprobed > 0 {
        println!(
            "A node that was not probed is not a node that is down. Nothing about \
             those addresses is known from this run."
        );
    }
    if answered == addrs.len() {
        println!("BOARDS OK - every address answered.");
        return 0;
    }
    if args.contains(&"--strict") {
        return 1;
    }
    0
}

fn ping(addr: &str) -> Result<bool, String> {
    let out = Command::new("ping")
        .args(["-c", "1", "-W", "800", addr])
        .output()
        .map_err(|e| format!("could not run ping: {e}"))?;
    Ok(out.status.success())
}

// ---------------------------------------------------------------- smoke

fn cmd_smoke(root: &Path) -> i32 {
    println!("running the M1 crypto smoke test\n");
    let status = Command::new("cargo")
        .args(["run", "--quiet", "--bin", "smoke-m1"])
        .current_dir(root)
        .status();
    match status {
        Ok(s) if s.success() => {
            println!(
                "\nSMOKE OK on the host. A host pass says the arithmetic is right and \
                 says nothing about the node: append an on-device RC to \
                 smoke/M1_RESULTS.md before any row claims hw."
            );
            0
        }
        Ok(s) => {
            println!("\nSMOKE FAIL - exit {:?}", s.code());
            1
        }
        Err(e) => {
            println!("\nSMOKE NOT RUN - could not start cargo: {e}");
            2
        }
    }
}

// ---------------------------------------------------------------- helpers

fn repo_root() -> PathBuf {
    // The manifest directory at compile time is the crate root, which is what
    // every path here is relative to. Falling back to the current directory
    // would silently measure whatever tree the operator happened to be in.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read(p: &Path) -> Result<String, String> {
    fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))
}

fn walk(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, ext, out);
        } else if p.extension().and_then(|s| s.to_str()) == Some(ext) {
            out.push(p);
        }
    }
}

fn collect(root: &Path, dirs: &[&str], ext: &str) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    let mut any_dir = false;
    for d in dirs {
        let p = root.join(d);
        if p.is_dir() {
            any_dir = true;
            walk(&p, ext, &mut files);
        }
    }
    if !any_dir {
        return Err(format!("none of {dirs:?} is a directory"));
    }
    Ok(files)
}

fn count_files(root: &Path, dirs: &[&str], ext: &str) -> Result<i64, String> {
    Ok(collect(root, dirs, ext)?.len() as i64)
}

fn count_lines(root: &Path, dirs: &[&str], ext: &str) -> Result<i64, String> {
    let mut n = 0i64;
    for f in collect(root, dirs, ext)? {
        n += read(&f)?.lines().count() as i64;
    }
    Ok(n)
}

fn count_matching(
    root: &Path,
    dirs: &[&str],
    ext: &str,
    pred: fn(&str) -> bool,
) -> Result<i64, String> {
    let mut n = 0i64;
    for f in collect(root, dirs, ext)? {
        n += read(&f)?.lines().filter(|l| pred(l)).count() as i64;
    }
    Ok(n)
}
