#!/usr/bin/env python3
"""
W6.1 structural fuzz — random .t27 spec generator.

Emits spec bodies covering three buckets:
  - valid     : syntactically well-formed under the grammar t27c currently accepts.
  - malformed : intentional lexical/syntactic damage (missing brace, bad type name,
                truncated const, etc.). Every backend must reject.
  - semi-valid: parseable shell with one semantically dubious inside
                (unknown identifier in body, wrong-arity call, type mismatch).
                Whether a backend accepts is what the harness will find out.

Anchor: phi^2 + phi^-2 = 3.
Seed  : 0xF1F1F1F1 (fixed for reproducibility).
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Callable

SEED = 0xF1F1F1F1

# ---- grammar primitives observed in specs/wire.t27, specs/byte_utils.t27 ----
INT_TYPES = ["u8", "u16", "u32", "usize"]
BOOL_TYPE = "bool"
IDENT_HEAD = "abcdefghijklmnopqrstuvwxyz"
IDENT_TAIL = IDENT_HEAD + IDENT_HEAD.upper() + "0123456789_"


def ident(rng: random.Random, minlen: int = 3, maxlen: int = 10) -> str:
    n = rng.randint(minlen, maxlen)
    head = rng.choice(IDENT_HEAD)
    tail = "".join(rng.choice(IDENT_TAIL) for _ in range(n - 1))
    return head + tail


def literal_int(rng: random.Random, ty: str) -> str:
    # keep well inside u8 range so u8 constants are always valid.
    if ty == "u8":
        return str(rng.randint(0, 255))
    if ty == "u16":
        return str(rng.randint(0, 65535))
    if ty == "u32":
        return str(rng.randint(0, 4_000_000))
    if ty == "usize":
        return str(rng.randint(0, 4_000_000))
    return "0"


# ---- expression generator ------------------------------------------------
def expr_int(rng: random.Random, depth: int, params: list[tuple[str, str]]) -> str:
    """Build an integer-valued expression."""
    int_params = [name for name, ty in params if ty in INT_TYPES]
    if depth <= 0 or (int_params and rng.random() < 0.35):
        # leaf: literal or param
        if int_params and rng.random() < 0.6:
            base = rng.choice(int_params)
            # sometimes cast
            if rng.random() < 0.2:
                target = rng.choice(INT_TYPES)
                return f"({base} as {target})"
            return base
        return literal_int(rng, "u32")

    op = rng.choice(["+", "-", "&", "|", "^", ">>", "<<"])
    a = expr_int(rng, depth - 1, params)
    b = expr_int(rng, depth - 1, params)
    if op in (">>", "<<"):
        # limit shift amount to keep it well-formed
        b = str(rng.randint(0, 24))
    return f"({a} {op} {b})"


def expr_bool(rng: random.Random, depth: int, params: list[tuple[str, str]]) -> str:
    op = rng.choice(["==", "!=", "<", "<=", ">", ">="])
    a = expr_int(rng, depth, params)
    b = expr_int(rng, depth, params)
    return f"({a} {op} {b})"


# ---- item generators -----------------------------------------------------
def gen_const(rng: random.Random) -> str:
    name = ident(rng).upper()
    ty = rng.choice(INT_TYPES)
    val = literal_int(rng, ty)
    return f"    const {name} : {ty} = {val};"


def gen_fn(rng: random.Random, name: str, ret_kind: str) -> str:
    """ret_kind: 'int' or 'bool'."""
    nparams = rng.randint(0, 3)
    params = [(ident(rng), rng.choice(INT_TYPES)) for _ in range(nparams)]
    ret_ty = rng.choice(INT_TYPES) if ret_kind == "int" else BOOL_TYPE
    param_str = ", ".join(f"{p}: {t}" for p, t in params)
    body_expr = (
        expr_int(rng, rng.randint(1, 3), params)
        if ret_kind == "int"
        else expr_bool(rng, rng.randint(1, 3), params)
    )
    # sometimes wrap in an if/else to mirror real specs
    if rng.random() < 0.3 and nparams >= 1 and ret_kind == "int":
        p0 = params[0][0]
        alt = expr_int(rng, 1, params)
        body = (
            f"        if ({p0} == 0) {{\n"
            f"            return {alt};\n"
            f"        }} else {{\n"
            f"            return {body_expr};\n"
            f"        }}"
        )
    else:
        body = f"        return {body_expr};"

    # cast final expression to ret type if returning int
    if ret_kind == "int":
        # ensure body_expr casts appropriately (some may already be casted)
        pass

    return (
        f"    fn {name}({param_str}) -> {ret_ty} {{\n"
        f"{body}\n"
        f"    }}"
    )


def gen_module_valid(rng: random.Random, mod_name: str) -> str:
    """Well-formed spec-body."""
    lines: list[str] = []
    lines.append(f"// fuzz-generated spec (valid bucket)")
    lines.append(f"module {mod_name} {{")
    lines.append("    use base::types;")
    lines.append("")
    # 0-3 constants
    for _ in range(rng.randint(0, 3)):
        lines.append(gen_const(rng))
    if lines[-1].startswith("    const"):
        lines.append("")
    # 1-4 functions
    nfns = rng.randint(1, 4)
    for i in range(nfns):
        fname = ident(rng, 4, 8)
        rk = rng.choice(["int", "int", "bool"])  # bias toward int
        lines.append(gen_fn(rng, fname, rk))
        lines.append("")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---- malformed injectors -------------------------------------------------
def malform(rng: random.Random, spec: str) -> tuple[str, str]:
    """Return (mutated_spec, damage_class)."""
    variants: list[Callable[[str], tuple[str, str]]] = [
        _drop_closing_brace,
        _drop_semicolon,
        _bad_type,
        _bad_return_arrow,
        _unclosed_paren,
        _rename_keyword,
    ]
    fn = rng.choice(variants)
    return fn(spec)


def _drop_closing_brace(s: str) -> tuple[str, str]:
    # remove the last '}' in the file
    idx = s.rfind("}")
    if idx < 0:
        return s, "drop-close-brace/no-op"
    return s[:idx] + s[idx + 1 :], "drop-close-brace"


def _drop_semicolon(s: str) -> tuple[str, str]:
    idx = s.find(";")
    if idx < 0:
        return s, "drop-semicolon/no-op"
    return s[:idx] + s[idx + 1 :], "drop-semicolon"


def _bad_type(s: str) -> tuple[str, str]:
    return s.replace("u8", "u9", 1), "bad-type-name"


def _bad_return_arrow(s: str) -> tuple[str, str]:
    return s.replace("->", "=>", 1), "bad-return-arrow"


def _unclosed_paren(s: str) -> tuple[str, str]:
    idx = s.find("(")
    if idx < 0:
        return s, "unclosed-paren/no-op"
    return s[: idx + 1] + s[idx + 2 :], "unclosed-paren"


def _rename_keyword(s: str) -> tuple[str, str]:
    return s.replace("return ", "returnn ", 1), "rename-return-keyword"


# ---- semi-valid ----------------------------------------------------------
def semi_valid(rng: random.Random, spec: str) -> tuple[str, str]:
    """Parseable shell, but with something semantically odd inside."""
    tweaks: list[Callable[[str], tuple[str, str]]] = [
        _unknown_ident_in_expr,
        _arity_swap,
        _type_mismatch_cast,
    ]
    fn = rng.choice(tweaks)
    return fn(spec)


def _unknown_ident_in_expr(s: str) -> tuple[str, str]:
    # replace an identifier reference inside a return expression with an unknown one
    return s.replace("return ", "return zzz_unknown_ + ", 1), "unknown-ident-in-body"


def _arity_swap(s: str) -> tuple[str, str]:
    # add a bogus extra argument in fn signature body if pattern matches; else no-op
    if "fn " in s and "()" not in s:
        return s.replace(") ->", ", ghost: u8) ->", 1), "arity-inflate"
    return s, "arity-swap/no-op"


def _type_mismatch_cast(s: str) -> tuple[str, str]:
    # cast bool return via `as u32`
    return s.replace("return ", "return (0 as bool) as u32 + ", 1), "bool-cast-mismatch"


# ---- driver --------------------------------------------------------------
@dataclass
class SpecRecord:
    idx: int
    bucket: str  # 'valid' | 'malformed' | 'semi-valid'
    damage: str  # class label; 'ok' for valid bucket
    filename: str


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100, help="number of specs to generate")
    ap.add_argument("--seed", type=lambda x: int(x, 0), default=SEED)
    ap.add_argument("--outdir", type=Path, required=True)
    ap.add_argument("--valid-frac", type=float, default=0.4)
    ap.add_argument("--malformed-frac", type=float, default=0.4)
    args = ap.parse_args()

    args.outdir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    manifest: list[SpecRecord] = []
    for i in range(args.n):
        r = rng.random()
        mod = f"Fuzz{i:05d}"
        base_spec = gen_module_valid(rng, mod)
        if r < args.valid_frac:
            bucket = "valid"
            spec = base_spec
            damage = "ok"
        elif r < args.valid_frac + args.malformed_frac:
            bucket = "malformed"
            spec, damage = malform(rng, base_spec)
        else:
            bucket = "semi-valid"
            spec, damage = semi_valid(rng, base_spec)

        fname = f"fuzz_{i:05d}_{bucket}.t27"
        (args.outdir / fname).write_text(spec, encoding="utf-8")
        manifest.append(SpecRecord(idx=i, bucket=bucket, damage=damage, filename=fname))

    (args.outdir / "manifest.json").write_text(
        json.dumps([asdict(r) for r in manifest], indent=2), encoding="utf-8"
    )
    print(f"generated {args.n} specs under {args.outdir}", file=sys.stderr)
    print(f"seed = 0x{args.seed:X}", file=sys.stderr)
    counts = {"valid": 0, "malformed": 0, "semi-valid": 0}
    for r in manifest:
        counts[r.bucket] += 1
    print(f"buckets: {counts}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
