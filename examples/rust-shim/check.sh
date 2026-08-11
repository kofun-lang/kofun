#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SHIM="$ROOT/examples/rust-shim"
MEASUREMENT="$ROOT/artifacts/rust-shim-build-cost.json"
WORK=${KOFUN_RUST_SHIM_WORK:-"$ROOT/build/rust-shim"}
CC=${CC:-cc}

for required in cargo rustc "$CC" readelf; do
    command -v "$required" >/dev/null 2>&1 || {
        printf '%s\n' "FAIL: required Rust shim tool unavailable: $required" >&2
        exit 1
    }
done

rm -rf "$WORK"
mkdir -p "$WORK/cargo-home" "$WORK/target"

test -s "$SHIM/vendor/unicode-segmentation/LICENSE-MIT"
test -s "$SHIM/vendor/unicode-segmentation/LICENSE-APACHE"
grep -Fq 'name = "unicode-segmentation"' "$SHIM/Cargo.lock"
grep -Fq 'version = "1.13.3"' "$SHIM/Cargo.lock"
grep -Fq \
    'checksum = "c6f5d3c3b1bf09027a88a6bc961fc00497d651009560b5463668dc81b0fa87a8"' \
    "$SHIM/Cargo.lock"
grep -Fq \
    '"package":"c6f5d3c3b1bf09027a88a6bc961fc00497d651009560b5463668dc81b0fa87a8"' \
    "$SHIM/vendor/unicode-segmentation/.cargo-checksum.json"

export CARGO_HOME="$WORK/cargo-home"
export CARGO_TARGET_DIR="$WORK/target"
export CARGO_NET_OFFLINE=true

(
    cd "$SHIM"
    cargo metadata --offline --locked --format-version 1 \
        >"$WORK/metadata.json"
    cargo test --offline --locked
    cargo build --offline --locked --release --lib
    cargo build --offline --locked --release --bin direct_reference
)

LIBRARY="$WORK/target/release/libkofun_unicode_shim.so"
RUST_REFERENCE="$WORK/target/release/direct_reference"
test -s "$LIBRARY"
test -x "$RUST_REFERENCE"

"$ROOT/bin/kofun" build "$SHIM/graphemes.kofun" \
    --backend c --c-abi \
    --link-library "$LIBRARY" \
    --emit-c "$WORK/graphemes.c" \
    -o "$WORK/kofun-reference"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -I"$SHIM/include" \
    "$SHIM/tests/c_reference.c" "$LIBRARY" \
    -o "$WORK/c-reference"

set +e
"$WORK/kofun-reference" \
    >"$WORK/kofun.stdout" 2>"$WORK/kofun.stderr"
kofun_status=$?
"$WORK/c-reference" \
    >"$WORK/c.stdout" 2>"$WORK/c.stderr"
c_status=$?
"$RUST_REFERENCE" \
    >"$WORK/rust.stdout" 2>"$WORK/rust.stderr"
rust_status=$?
set -e

test "$kofun_status" -eq 0
test "$c_status" -eq 0
test "$rust_status" -eq 0
cmp "$WORK/kofun.stdout" "$WORK/c.stdout"
cmp "$WORK/kofun.stdout" "$WORK/rust.stdout"
test "$(cat "$WORK/kofun.stdout")" = "0
1
1
0
1
2"
grep -Fq 'intentional Kofun C ABI panic probe' "$WORK/kofun.stderr"
grep -Fq 'intentional Kofun C ABI panic probe' "$WORK/c.stderr"
grep -Fq 'intentional direct Rust panic probe' "$WORK/rust.stderr"

grep -Fq 'const void * bytes, size_t length' "$WORK/graphemes.c"
grep -Fq '_Static_assert(sizeof(GraphemeResult) == 24,' "$WORK/graphemes.c"
grep -Fq '_Static_assert(_Alignof(GraphemeResult) == 8,' "$WORK/graphemes.c"
readelf --wide --dyn-syms "$LIBRARY" >"$WORK/shim-symbols.txt"
grep -Fq 'kofun_unicode_grapheme_count' "$WORK/shim-symbols.txt"
grep -Fq 'kofun_unicode_panic_probe' "$WORK/shim-symbols.txt"
readelf -d "$WORK/kofun-reference" >"$WORK/kofun-dynamic.txt"
grep -Fq 'libkofun_unicode_shim.so' "$WORK/kofun-dynamic.txt"

test -s "$MEASUREMENT"
grep -Fq '"schema": "kofun.rust-shim-build-cost/v1"' "$MEASUREMENT"
grep -Fq '"source_commit": "11dd1f48e84afe583ebbb9a8994d9fb408e6492b"' \
    "$MEASUREMENT"
grep -Fq '"worktree_clean": true' "$MEASUREMENT"
grep -Fq '"samples_ms": [2701, 2715, 3307, 3190, 2607]' "$MEASUREMENT"
grep -Fq '"samples_ms": [140, 120, 105, 116, 137]' "$MEASUREMENT"
grep -Fq '"median_ms": 2715' "$MEASUREMENT"
grep -Fq '"median_ms": 120' "$MEASUREMENT"

if grep -Eq 'String|Vec|Result<|dyn ' "$SHIM/include/kofun_unicode_shim.h"; then
    printf '%s\n' "FAIL: Rust-managed type exposed by the C header" >&2
    exit 1
fi

printf '%s\n' \
    "PASS: unicode-segmentation 1.13.3 built from the locked vendor offline" \
    "PASS: Kofun, C, and direct Rust agreed on grapheme and UTF-8 results" \
    "PASS: borrowed input survived repeated calls without mutation" \
    "PASS: invalid UTF-8 and null input mapped to explicit status values" \
    "PASS: a caught Rust panic returned status 2 without crossing C ABI" \
    "PASS: the Kofun executable dynamically linked the Rust crate shim" \
    "PASS: measured build-cost evidence has five samples for both paths"
