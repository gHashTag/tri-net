# W10 dist/ — prebuilt armv7 binaries for M2 step 2

**Do NOT clone the repo to use these** — download the two files you need
directly from GitHub via `curl` or your browser.

## Files

| File | Size | sha256 |
|------|------|--------|
| `trios_meshd.armv7-musl` | 731888 | `a0c03c91bd0102528d5caf208be620647f92b9755aa404882c74f4344a6bc064` |
| `trios_meshd.armv7-glibc` | 703356 | `24cfbdc9e7c811cfbc381fc84660afc281d382826ffe2b0a3429ab60eadfa4a2` |
| `SHA256SUMS` | — | — |

- **`trios_meshd.armv7-musl`** — **preferred**. Statically linked. Runs on
  any linux/armv7 (glibc, musl, alpine, armbian, Debian). No dynamic loader
  needed.
- `trios_meshd.armv7-glibc` — fallback. Dynamically linked to
  `/lib/ld-linux-armhf.so.3`. Use only if musl variant somehow fails.

Gate scripts and HOWTO live in `smoke/` (same branch/commit as these
binaries).

## Direct download URLs (raw)

Once merged to `main`:

```
https://github.com/gHashTag/tri-net/raw/main/dist/trios_meshd.armv7-musl
https://github.com/gHashTag/tri-net/raw/main/dist/trios_meshd.armv7-glibc
https://github.com/gHashTag/tri-net/raw/main/smoke/m2_onboard_bringup.sh
https://github.com/gHashTag/tri-net/raw/main/smoke/m2_onboard_bringup_n_runs.sh
```

Before merge (from this PR branch):

```
https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/dist/trios_meshd.armv7-musl
https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/dist/trios_meshd.armv7-glibc
https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/smoke/m2_onboard_bringup.sh
https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/smoke/m2_onboard_bringup_n_runs.sh
```

## 10-minute run

```
curl -LO https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/dist/trios_meshd.armv7-musl
curl -LO https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/smoke/m2_onboard_bringup.sh
curl -LO https://github.com/gHashTag/tri-net/raw/feat/w10-m2-onboard-bringup/smoke/m2_onboard_bringup_n_runs.sh
sha256sum -c <(grep -E "musl|onboard" <<'EOF'
a0c03c91bd0102528d5caf208be620647f92b9755aa404882c74f4344a6bc064  trios_meshd.armv7-musl
EOF
)

chmod +x trios_meshd.armv7-musl m2_onboard_bringup.sh m2_onboard_bringup_n_runs.sh
scp trios_meshd.armv7-musl        root@<mini>:/tmp/trios_meshd
scp m2_onboard_bringup.sh         root@<mini>:/tmp/
scp m2_onboard_bringup_n_runs.sh  root@<mini>:/tmp/
ssh root@<mini> "chmod +x /tmp/trios_meshd /tmp/m2_onboard_bringup*.sh && ip -4 -o addr"
# note the real interface, then:
ssh root@<mini> "BIN=/tmp/trios_meshd IFACE=<real_iface> DURATION=4 N=5 /tmp/m2_onboard_bringup_n_runs.sh"
```

See `smoke/M2_ONBOARD_BRINGUP_HOWTO.md` for full FAIL-mode triage.

phi^2 + phi^-2 = 3
