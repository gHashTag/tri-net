# Bitstream seals

A SHA-256 over the raw `.bit` file attests to nothing, because `xc7frames2bit`
stamps the wall clock into header fields `c` and `d`. Measured: two runs from an
identical `.frames` differ in exactly **one byte** -- the seconds digit of the
build time. See `REPRODUCTION.md`.

Seal one of these two instead. Both are stable across runs.

## Payload hash (preferred)

SHA-256 over the `e` field only -- the configuration payload, every byte of
which reaches the silicon and nothing else.

```
python3 bitcanon.py build/ps7_corr.bit --payload-hash
```

| Design | Payload bytes | SHA-256 |
|---|---|---|
| `ps7_corr` | 4 045 564 | `6ee32275dbcebaa3720fefdcff021540ace9673644fb7cd4df45329da6a346c2` |
| `ps7_probe` | 4 045 564 | `c4a07388e1a4cc25747272718dfd48bb21fddbef38a5c3d67825c535eb074828` |

## Canonicalised file hash

SHA-256 over the whole file after pinning `c` and `d` to a fixed epoch
(`2000/01/01 00:00:00`). Useful when the artefact that must be shipped is a
`.bit` rather than a hash.

```
python3 bitcanon.py in.bit -o out.bit
```

Verified 2026-08-03: five consecutive `xc7frames2bit` runs on the same
`ps7_corr.frames`, one second apart, produced five different raw hashes and a
single canonicalised hash `6bba2955d5dd6bdb...` -- `distinct hashes: 1`.

## What a seal does and does not buy

It buys configuration-management evidence: this artefact came from that source,
and anyone can re-derive it. It buys a cross-node built-in test where a mismatch
is unambiguously a fault rather than a tolerance argument.

It does **not** buy verification credit. Proving the bitstream implements the
RTL additionally requires RTL-to-netlist-to-bitstream equivalence checking,
which this flow does not do and does not claim.

## Updated 2026-08-03

Payload hash for `ps7_pn_tree`, confirmed identical across **five complete
builds** from the same source:

```
24e8e27f8518ff4156cd5939121eb2e13407acc6cf7026ec9a74ea231927b1bd
```

Canonicalised whole-file hash for the same five: `8638c6f02a4ac94e...`.

`bitcanon.py` now pins header field `'a'` (design name, which carries the input
filename) in addition to the date and time. Before that fix it left the name
varying and five canonicalised builds still produced five hashes.
