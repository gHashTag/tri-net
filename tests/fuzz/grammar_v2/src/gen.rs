// SPDX-License-Identifier: Apache-2.0
// tri-net/tests/fuzz/grammar_v2/src/gen.rs
//
// W7.3 E1 — Grammar-directed T27 generator (YARPGen-style, subset).
//
// Emits syntactically valid T27 modules to target/fuzz/w7_3/*.t27 for later
// round-trip (E2) and backend-differential (E3, blocked on upstream Stmt::Let)
// analysis. This binary only generates; parsing / round-tripping lives in E2.
//
// Grammar coverage (initial subset + collection-params expansion):
//   Module     ::= "module" ident "{" ConstDecl* FnDecl+ "}"
//   ConstDecl  ::= "const" IDENT ":" "u32" "=" IntLiteral ";"
//   FnDecl     ::= "fn" ident "(" Params? ")" ("->" Type)? "{" Stmt+ Return "}"
//   Params     ::= Param ("," Param)*
//   Param      ::= ident ":" (Type | CollType)
//   CollType   ::= "[" "u32" ";" IDENT "]"          // [u32; NAMED_CONST]
//   Stmt       ::= LetStmt | IfStmt | ExprStmt
//   LetStmt    ::= "let" ident ":" Type "=" Expr ";"
//   Expr       ::= Literal | Ident | BinOp | Cast
//   Type       ::= u8 | u16 | u32 | u64 | usize | bool
//   IntType    ::= u8 | u16 | u32 | u64 | usize
//
// Collection-params grammar (W7.3 target #1) — CORRECTED per PR #47 GLM
// re-review @ 247427d + ground-truth verification against tri-net/specs
// on PR #39 branch (feat/strategic-audit-2026-07-04):
//
//   - Corpus of interest: tri-net/specs/*.t27 (68 modules, W6.2 audit corpus)
//   - Only collection form observed there: [u32; NAMED_CONST] (159 occurrences)
//   - Element type always u32
//   - Named-const size always resolves via a module-scope `const NAME: u32 = ...`
//   - This is the exact syntactic path that t27c lowers to `Vec<>` in gen/rust
//     (see specs/anomaly_detector.t27:68 -> gen/rust/anomaly_detector.rs
//     calculate_baseline(history: Vec<>, count: u32)).
//
//   Zig-style forms ([]const T / []T / [N]T literal) previously emitted by
//   this generator were dropped: they exist in the parallel ../t27/ Zig
//   backend tree but NOT in tri-net/specs, and they exercise different
//   parser/lowering paths than the Vec<>-defect surface the audit targets.
//
// Isolation constraint (unchanged from initial expansion):
//   Collection-typed params are declared in the signature (parser-exercise
//   of param-position for the Vec<>-defect class W6.2 Class 2 surface),
//   but are NOT pushed into the scalar ident pool used by gen_expr. This
//   prevents ill-typed expressions (e.g. vec + 1u32) that t27c would
//   reject and would confound the whitespace-invariance signal. Body-use
//   of collections (Index expressions) is deferred to a separate commit.
//
// Depth-bounded (max_depth = 6). Seed-reproducible via ChaCha20 RNG.
// See docs/W7_3_FUZZ_BASELINE_PLAN.md.
//
// phi^2 + phi^-2 = 3

use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha20Rng;
use std::env;
use std::fs;
use std::path::PathBuf;

const TYPES: &[&str] = &["u8", "u16", "u32", "u64", "usize", "bool"];
const INT_TYPES: &[&str] = &["u8", "u16", "u32", "u64", "usize"];
const BIN_OPS: &[&str] = &["+", "-", "*", "&", "|", "^", "<<", ">>"];
const CMP_OPS: &[&str] = &["==", "!=", "<", "<=", ">", ">="];

// Named-const pool for [u32; NAMED_CONST] collection params. Names match
// tri-net/specs vocabulary (top-10 by occurrence: MAX_NODES 29, MAX_PARAMS 18,
// MAX_METRICS 12, MAX_FLOWS 11, MAX_ENTRIES 11, MAX_MODULES 10, MAX_TASKS 7,
// MAX_FUNCTIONS 7, MAX_SAMPLES 6, MAX_RESULTS 6). Values match the range
// observed in real const-decls (2..32).
const NAMED_CONST_POOL: &[&str] = &[
    "MAX_NODES",
    "MAX_PARAMS",
    "MAX_METRICS",
    "MAX_FLOWS",
    "MAX_ENTRIES",
    "MAX_MODULES",
    "MAX_TASKS",
    "MAX_FUNCTIONS",
    "MAX_SAMPLES",
    "MAX_RESULTS",
];

struct Ctx {
    rng: ChaCha20Rng,
    // Scalar idents visible to gen_expr (BinOp/Cast eligible). Populated by
    // let-stmts and by scalar-typed params. Collection-typed params live in
    // `coll_params` instead — see isolation constraint at top of file.
    idents: Vec<(String, String)>, // (name, type)
    // Collection-typed params: name + rendered type string (only "[u32; NAME]"
    // form is emitted). Recorded for signature emission only. Not exposed to
    // gen_expr — collection idents are dead in the body pending Index support.
    coll_params: Vec<(String, String)>,
    // Module-scope const-decls emitted for this module. Any [u32; NAME] used
    // in a param signature must reference a NAME that is declared here.
    // Populated by gen_module before any fn is generated.
    declared_consts: Vec<(String, u32)>, // (NAME, value)
    max_depth: u32,
    max_stmts_per_fn: u32,
    max_params_per_fn: u32,
    coll_param_prob: u32, // percent chance a param is a collection (else scalar)
}

impl Ctx {
    fn new(seed: u64) -> Self {
        Self {
            rng: ChaCha20Rng::seed_from_u64(seed),
            idents: Vec::new(),
            coll_params: Vec::new(),
            declared_consts: Vec::new(),
            max_depth: 6,
            max_stmts_per_fn: 20,
            max_params_per_fn: 4,
            coll_param_prob: 50,
        }
    }

    fn fresh_ident(&mut self, prefix: &str) -> String {
        let n = self.rng.gen_range(0u32..10_000);
        format!("{}_{}", prefix, n)
    }

    fn pick_type(&mut self) -> String {
        TYPES[self.rng.gen_range(0..TYPES.len())].to_string()
    }

    fn pick_int_type(&mut self) -> String {
        INT_TYPES[self.rng.gen_range(0..INT_TYPES.len())].to_string()
    }

    /// Pick a random module-scope named const to reference. Assumes
    /// `declared_consts` is non-empty (guarded by caller).
    fn pick_const_name(&mut self) -> String {
        let idx = self.rng.gen_range(0..self.declared_consts.len());
        self.declared_consts[idx].0.clone()
    }
}

fn gen_literal(ctx: &mut Ctx, ty: &str) -> String {
    match ty {
        "bool" => if ctx.rng.gen::<bool>() { "true".into() } else { "false".into() },
        "u8" => format!("{}u8", ctx.rng.gen_range(0u32..=255)),
        "u16" => format!("{}u16", ctx.rng.gen_range(0u32..=65535)),
        "u32" => format!("{}u32", ctx.rng.gen_range(0u32..=1_000_000)),
        "u64" => format!("{}u64", ctx.rng.gen_range(0u64..=1_000_000)),
        "usize" => format!("{}", ctx.rng.gen_range(0usize..=1024)),
        _ => "0".into(),
    }
}

fn gen_expr(ctx: &mut Ctx, ty: &str, depth: u32) -> String {
    if depth >= ctx.max_depth {
        return gen_literal(ctx, ty);
    }

    // Weighted choice: literal 30%, ident 25%, binop 30%, cast 15%
    let choice = ctx.rng.gen_range(0u32..100);
    let same_type_idents: Vec<_> = ctx.idents.iter().filter(|(_, t)| t == ty).cloned().collect();

    if choice < 30 || (choice < 55 && same_type_idents.is_empty()) {
        gen_literal(ctx, ty)
    } else if choice < 55 && !same_type_idents.is_empty() {
        // Use existing ident of matching type
        let (name, _) = &same_type_idents[ctx.rng.gen_range(0..same_type_idents.len())];
        name.clone()
    } else if choice < 85 && ty != "bool" {
        // BinOp — arithmetic on ints
        let op = BIN_OPS[ctx.rng.gen_range(0..BIN_OPS.len())];
        let lhs = gen_expr(ctx, ty, depth + 1);
        let rhs = gen_expr(ctx, ty, depth + 1);
        // Shift RHS must be small — clamp to literal for shifts
        if op == "<<" || op == ">>" {
            let sh = ctx.rng.gen_range(0u32..8);
            format!("({} {} {}u32)", lhs, op, sh)
        } else {
            format!("({} {} {})", lhs, op, rhs)
        }
    } else if ty == "bool" {
        // Comparison on ints
        let int_ty = INT_TYPES[ctx.rng.gen_range(0..INT_TYPES.len())].to_string();
        let op = CMP_OPS[ctx.rng.gen_range(0..CMP_OPS.len())];
        let lhs = gen_expr(ctx, &int_ty, depth + 1);
        let rhs = gen_expr(ctx, &int_ty, depth + 1);
        format!("({} {} {})", lhs, op, rhs)
    } else {
        // Cast — pick a source int type, generate expr of that type, cast
        let src = ctx.pick_int_type();
        let inner = gen_expr(ctx, &src, depth + 1);
        format!("({} as {})", inner, ty)
    }
}

fn gen_let_stmt(ctx: &mut Ctx) -> String {
    let ty = ctx.pick_type();
    let name = ctx.fresh_ident("v");
    let expr = gen_expr(ctx, &ty, 0);
    ctx.idents.push((name.clone(), ty.clone()));
    format!("        let {}: {} = {};", name, ty, expr)
}

fn gen_return(ctx: &mut Ctx, ret_ty: &str) -> String {
    let expr = gen_expr(ctx, ret_ty, 0);
    format!("        return {};", expr)
}

/// Emit the parameter list. Mixes scalar and collection params.
///
/// Scalar params are pushed into `ctx.idents` so `gen_expr` can reference
/// them in BinOp / Cast / return. Collection params ([u32; NAMED_CONST])
/// are pushed into `ctx.coll_params` only — they appear in the signature
/// but are dead in the body. This is the isolation constraint that lets
/// whitespace-invariance signal reflect param-position parser behavior
/// without ill-typed body noise.
///
/// A collection param can only be emitted if `ctx.declared_consts` is
/// non-empty (which it will be after `gen_module` initializes it). If
/// somehow empty, we fall back to a scalar param for that slot.
fn gen_params(ctx: &mut Ctx) -> String {
    let n_params = ctx.rng.gen_range(0u32..=ctx.max_params_per_fn);
    if n_params == 0 {
        return String::new();
    }

    let mut parts: Vec<String> = Vec::with_capacity(n_params as usize);
    for _ in 0..n_params {
        let name = ctx.fresh_ident("p");
        let want_coll = ctx.rng.gen_range(0u32..100) < ctx.coll_param_prob;
        let can_coll = !ctx.declared_consts.is_empty();
        if want_coll && can_coll {
            let const_name = ctx.pick_const_name();
            let ty = format!("[u32; {}]", const_name);
            parts.push(format!("{}: {}", name, ty));
            ctx.coll_params.push((name, ty));
        } else {
            let ty = ctx.pick_type();
            parts.push(format!("{}: {}", name, ty));
            ctx.idents.push((name, ty));
        }
    }
    parts.join(", ")
}

fn gen_fn(ctx: &mut Ctx, name: &str) -> String {
    ctx.idents.clear();
    ctx.coll_params.clear();
    let params = gen_params(ctx);
    let ret_ty = ctx.pick_type();
    let n_stmts = ctx.rng.gen_range(1u32..=ctx.max_stmts_per_fn);

    let mut body = String::new();
    for _ in 0..n_stmts {
        body.push_str(&gen_let_stmt(ctx));
        body.push('\n');
    }
    body.push_str(&gen_return(ctx, &ret_ty));

    format!(
        "    fn {}({}) -> {} {{\n{}\n    }}",
        name, params, ret_ty, body
    )
}

/// Emit module-scope const-decls. Samples 1-4 names from `NAMED_CONST_POOL`
/// (no repeats within a module) and assigns each a literal u32 value in
/// [2, 32] — the range observed in tri-net/specs const-decls. Populates
/// `ctx.declared_consts` so subsequent `pick_const_name` calls only
/// reference names that were actually declared.
fn gen_const_decls(ctx: &mut Ctx) -> String {
    ctx.declared_consts.clear();
    let n_consts = ctx.rng.gen_range(1u32..=4) as usize;
    let n_consts = n_consts.min(NAMED_CONST_POOL.len());

    // Sample without replacement via index shuffle.
    let mut indices: Vec<usize> = (0..NAMED_CONST_POOL.len()).collect();
    for i in (1..indices.len()).rev() {
        let j = ctx.rng.gen_range(0..=i);
        indices.swap(i, j);
    }
    let picked: Vec<&str> = indices.iter().take(n_consts).map(|&i| NAMED_CONST_POOL[i]).collect();

    let mut lines = Vec::with_capacity(n_consts);
    for name in picked {
        let value = ctx.rng.gen_range(2u32..=32);
        ctx.declared_consts.push((name.to_string(), value));
        lines.push(format!("    const {}: u32 = {};", name, value));
    }
    lines.join("\n")
}

fn gen_module(ctx: &mut Ctx, mod_idx: u32) -> String {
    let mod_name = format!("W73Fuzz{}", mod_idx);
    // Emit const-decls FIRST so gen_params can reference them via
    // ctx.declared_consts. This ordering matters — collection params depend
    // on the const pool being populated.
    let const_decls = gen_const_decls(ctx);

    let n_fns = ctx.rng.gen_range(1u32..=3);
    let mut fns = Vec::new();
    for i in 0..n_fns {
        fns.push(gen_fn(ctx, &format!("f{}", i)));
    }
    format!(
        "// SPDX-License-Identifier: Apache-2.0\n\
         // W7.3 fuzz gen — seed-derived, mod_idx={}\n\
         // phi^2 + phi^-2 = 3\n\
         \n\
         module {} {{\n\
         {}\n\
         \n\
         {}\n\
         }}\n",
        mod_idx,
        mod_name,
        const_decls,
        fns.join("\n\n")
    )
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let count: u32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(100);
    let base_seed: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0xC0FFEE_u64);

    let out_dir = PathBuf::from(env::var("W73_OUT").unwrap_or_else(|_| "target/fuzz/w7_3".into()));
    fs::create_dir_all(&out_dir).expect("create out dir");

    eprintln!("W7.3 gen: count={} base_seed={:#x} out={}", count, base_seed, out_dir.display());

    for i in 0..count {
        let seed = base_seed.wrapping_add(i as u64);
        let mut ctx = Ctx::new(seed);
        let src = gen_module(&mut ctx, i);
        let path = out_dir.join(format!("fuzz_{:05}_seed_{:016x}.t27", i, seed));
        fs::write(&path, src).expect("write module");
    }

    eprintln!("W7.3 gen: {} modules written to {}", count, out_dir.display());
}
