#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SHIM="$ROOT/examples/rust-shim"
WORK=${KOFUN_RUST_SHIM_BENCH_WORK:-"$ROOT/build/rust-shim-benchmark"}
CC=${CC:-cc}
SAMPLES=${KOFUN_RUST_SHIM_BENCH_SAMPLES:-5}

test "$SAMPLES" -ge 3
test $((SAMPLES % 2)) -eq 1
for required in cargo rustc "$CC" date sed sort "$ROOT/bin/kofun-sha256" uname getconf; do
    command -v "$required" >/dev/null 2>&1 || {
        printf '%s\n' "missing benchmark tool: $required" >&2
        exit 1
    }
done
git -C "$ROOT" diff --quiet
git -C "$ROOT" diff --cached --quiet
test -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)"

rm -rf "$WORK"
mkdir -p "$WORK/cargo-home"

elapsed_ms() {
    start=$1
    finish=$2
    printf '%s\n' $(((finish - start + 500000) / 1000000))
}

median() {
    middle=$((SAMPLES / 2 + 1))
    for sample in "$@"; do
        printf '%s\n' "$sample"
    done | LC_ALL=C sort -n | sed -n "${middle}p"
}

json_string() {
    printf '%s' "$1" |
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
        tr '\n' ';'
}

rust_samples=
iteration=1
while test "$iteration" -le "$SAMPLES"; do
    rm -rf "$WORK/rust-target"
    start=$(date +%s%N)
    (
        cd "$SHIM"
        CARGO_HOME="$WORK/cargo-home" \
        CARGO_TARGET_DIR="$WORK/rust-target" \
        CARGO_NET_OFFLINE=true \
            cargo build --offline --locked --release --lib \
            >"$WORK/rust-$iteration.stdout" \
            2>"$WORK/rust-$iteration.stderr"
    )
    finish=$(date +%s%N)
    sample=$(elapsed_ms "$start" "$finish")
    rust_samples="$rust_samples $sample"
    iteration=$((iteration + 1))
done

LIBRARY="$WORK/rust-target/release/libkofun_unicode_shim.so"
test -s "$LIBRARY"
"$ROOT/bin/kofun" build "$SHIM/graphemes.kofun" \
    --backend c --c-abi --link-library "$LIBRARY" \
    --emit-c "$WORK/warm.c" -o "$WORK/warm" >/dev/null

kofun_samples=
iteration=1
while test "$iteration" -le "$SAMPLES"; do
    start=$(date +%s%N)
    "$ROOT/bin/kofun" build "$SHIM/graphemes.kofun" \
        --backend c --c-abi --link-library "$LIBRARY" \
        --emit-c "$WORK/relink.c" -o "$WORK/relink" \
        >"$WORK/kofun-$iteration.stdout" \
        2>"$WORK/kofun-$iteration.stderr"
    finish=$(date +%s%N)
    sample=$(elapsed_ms "$start" "$finish")
    kofun_samples="$kofun_samples $sample"
    iteration=$((iteration + 1))
done

rust_median=$(median $rust_samples)
kofun_median=$(median $kofun_samples)
rust_array=$(printf '%s' "$rust_samples" | sed -e 's/^ //' -e 's/ /, /g')
kofun_array=$(printf '%s' "$kofun_samples" | sed -e 's/^ //' -e 's/ /, /g')
source_commit=$(git -C "$ROOT" rev-parse HEAD)
source_tree=$(git -C "$ROOT" show -s --format=%T HEAD)
measured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
uname_value=$(json_string "$(uname -srm)")
cpu_value=$(json_string "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | sed -n '1p')")
rustc_value=$(json_string "$(rustc -Vv)")
cargo_value=$(json_string "$(cargo --version)")
cc_value=$(json_string "$("$CC" --version | sed -n '1p')")
library_sha=$("$ROOT/bin/kofun-sha256" "$LIBRARY" | sed 's/[[:space:]].*//')
library_bytes=$(wc -c <"$LIBRARY" | tr -d ' ')
kofun_bytes=$(wc -c <"$WORK/relink" | tr -d ' ')

printf '%s\n' \
    '{' \
    '  "schema": "kofun.rust-shim-build-cost/v1",' \
    "  \"measured_at_utc\": \"$measured_at\"," \
    "  \"source_commit\": \"$source_commit\"," \
    "  \"source_tree\": \"$source_tree\"," \
    '  "worktree_clean": true,' \
    "  \"sample_count\": $SAMPLES," \
    '  "clock": "wall milliseconds from date +%s%N; cleanup and warmup excluded",' \
    '  "machine": {' \
    "    \"uname\": \"$uname_value\"," \
    "    \"cpu_model\": \"$cpu_value\"," \
    "    \"logical_cpus\": $(getconf _NPROCESSORS_ONLN)" \
    '  },' \
    '  "toolchain": {' \
    "    \"rustc\": \"$rustc_value\"," \
    "    \"cargo\": \"$cargo_value\"," \
    "    \"cc\": \"$cc_value\"" \
    '  },' \
    '  "rust_clean_cdylib_build": {' \
    '    "definition": "target directory removed before each sample; vendored Cargo source and cargo-home retained; release cdylib only",' \
    '    "command": "CARGO_HOME=<isolated> CARGO_TARGET_DIR=<removed-per-sample> CARGO_NET_OFFLINE=true cargo build --offline --locked --release --lib",' \
    "    \"samples_ms\": [$rust_array]," \
    "    \"median_ms\": $rust_median" \
    '  },' \
    '  "kofun_prebuilt_rebuild_relink": {' \
    '    "definition": "unchanged prebuilt cdylib; full single-file Kofun C-ABI emit, host-C compile, and dynamic link; one warmup excluded; no incremental cache claimed",' \
    '    "command": "./bin/kofun build examples/rust-shim/graphemes.kofun --backend c --c-abi --link-library <prebuilt-so> --emit-c <output.c> -o <output>",' \
    "    \"samples_ms\": [$kofun_array]," \
    "    \"median_ms\": $kofun_median" \
    '  },' \
    '  "artifacts": {' \
    "    \"shim_sha256\": \"$library_sha\"," \
    "    \"shim_bytes\": $library_bytes," \
    "    \"kofun_executable_bytes\": $kofun_bytes" \
    '  }' \
    '}'
