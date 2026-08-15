#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_C_ABI_WORK:-"$ROOT/build/c-abi"}
CC=${CC:-cc}
SOURCE="$ROOT/tests/ffi/c_abi.kofun"
ASSERT_CONTEXT=c-abi
. "$ROOT/tests/assertions/assert.sh"

command -v rustc >/dev/null 2>&1 || {
    printf '%s\n' \
        "FAIL: rustc is required by the active C ABI acceptance gate" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

(
    cd "$ROOT/bootstrap/c_abi"
    "$ROOT/bin/kofun-digest" -c SHA256SUMS
)

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/c_abi/compiler.c" -o "$WORK/kofun-c-abi"

"$WORK/kofun-c-abi" "$SOURCE" "$WORK/first.c"
"$WORK/kofun-c-abi" "$SOURCE" "$WORK/second.c"
cmp "$WORK/first.c" "$WORK/second.c"

set +e
"$WORK/kofun-c-abi" \
    "$ROOT/tests/ffi/malformed.kofun" "$WORK/malformed.c" \
    >"$WORK/malformed.stdout" 2>"$WORK/malformed.stderr"
malformed_status=$?
set -e
assert_num "malformed status" "$malformed_status" -ne 0
assert_absent "malformed.c" "$WORK/malformed.c"
assert_grep "malformed.stderr" \
    -q 'only `extern "C"` is supported' "$WORK/malformed.stderr"

# libc is available to the explicit host-C path without a separate library.
sed '/rust_add/d; /^extern "C" fn rust_stack_sum(/,/^) -> CLong$/d; /rust_transform/d; /let answer/d; /let stack_answer/d; /let transformed/d; /print(answer)/d; /print(stack_answer)/d; /print(transformed/d' \
    "$SOURCE" >"$WORK/puts.kofun"
"$ROOT/bin/kofun" build "$WORK/puts.kofun" \
    --backend c --c-abi --emit-c "$WORK/puts.c" -o "$WORK/puts"
assert_eq "puts program output" "$("$WORK/puts")" "hello from Kofun C ABI"
assert_grep "puts.c" \
    -Fqx 'extern int puts(const char * message);' "$WORK/puts.c"

set +e
"$ROOT/bin/kofun" build "$WORK/puts.kofun" --c-abi \
    -o "$WORK/implicit-backend" \
    >"$WORK/implicit-backend.stdout" 2>"$WORK/implicit-backend.stderr"
implicit_status=$?
set -e
assert_num "implicit status" "$implicit_status" -ne 0
assert_absent "implicit-backend" "$WORK/implicit-backend"
assert_grep "implicit-backend.stderr" \
    -q \
    -- \
    '--c-abi requires explicit --backend c' \
    "$WORK/implicit-backend.stderr"

expect_link_rejection() {
    label=$1
    candidate=$2
    set +e
    "$ROOT/bin/kofun" build "$WORK/puts.kofun" \
        --backend c --c-abi --link-library "$candidate" \
        -o "$WORK/rejected-$label" \
        >"$WORK/rejected-$label.stdout" \
        2>"$WORK/rejected-$label.stderr"
    rejected_status=$?
    set -e
    assert_num "rejection status for link input $label" \
        "$rejected_status" -ne 0
    assert_absent "executable for rejected link input $label" \
        "$WORK/rejected-$label"
}

expect_link_rejection option '-Wl,--export-dynamic'
expect_link_rejection nonregular "$WORK"
newline_path=$(printf 'bad\npath')
expect_link_rejection newline "$newline_path"

printf '%s\n' \
    "PASS: C ABI compiler is deterministic and rejects a non-C ABI" \
    "PASS: Kofun called puts from libc through explicit --backend c --c-abi" \
    "PASS: --c-abi cannot silently select the host-C backend" \
    "PASS: link inputs reject options, non-regular files, and newlines"

if command -v ar >/dev/null 2>&1; then
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror \
        -c "$ROOT/tests/ffi/static_ffi.c" -o "$WORK/static_ffi.o"
    ar rcs "$WORK/libkofun static.a" "$WORK/static_ffi.o"
    "$ROOT/bin/kofun" build "$ROOT/tests/ffi/static_ffi.kofun" \
        --backend c --c-abi \
        --link-library "$WORK/libkofun static.a" \
        --link-library "$WORK/libkofun static.a" \
        -o "$WORK/static-caller"
    assert_eq "static-caller program output" "$("$WORK/static-caller")" 42
    printf '%s\n' \
        "PASS: repeated --link-library preserves an archive path with spaces"
else
    printf '%s\n' "SKIP: static archive link gate (ar unavailable)"
fi

rustc --crate-type=cdylib \
    "$ROOT/tests/ffi/rust_ffi.rs" -o "$WORK/libkofun_issue21.so"

"$ROOT/bin/kofun" build "$SOURCE" \
    --backend c --c-abi \
    --link-library "$WORK/libkofun_issue21.so" \
    --emit-c "$WORK/kofun.c" -o "$WORK/kofun-caller"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/tests/ffi/c_caller.c" "$WORK/libkofun_issue21.so" \
    -o "$WORK/c-caller"

"$WORK/kofun-caller" >"$WORK/kofun.stdout"
"$WORK/c-caller" >"$WORK/c.stdout"
sed -n '2,$p' "$WORK/kofun.stdout" >"$WORK/kofun-abi.stdout"
cmp "$WORK/c.stdout" "$WORK/kofun-abi.stdout"
assert_eq "first line of kofun.stdout" \
    "$(sed -n '1p' "$WORK/kofun.stdout")" "hello from Kofun C ABI"
assert_eq "c.stdout" "$(cat "$WORK/c.stdout")" "42
36
41
2
3"

assert_grep "kofun.c" -Fqx 'typedef struct Pair {' "$WORK/kofun.c"
assert_grep "kofun.c" \
    -Fqx 'extern Pair rust_transform(Pair value);' "$WORK/kofun.c"
assert_grep "kofun.c" -Fq '_Static_assert(sizeof(Pair) == 24,' "$WORK/kofun.c"
assert_grep "kofun.c" -Fq '_Static_assert(_Alignof(Pair) == 8,' "$WORK/kofun.c"
assert_grep "kofun.c" \
    -Fqx \
    'extern long rust_stack_sum(long one, long two, long three, long four, long five, long six, long seven, long eight);' \
    "$WORK/kofun.c"

# The last PASS below is exactly what this `readelf` reads, so the claim and
# its evidence travel together (#1496). Without `readelf` the gate used to skip
# the check and print the claim anyway — a line asserting dynamic linkage on a
# host where nothing had looked. The `ar` gate forty lines above already prints
# a `SKIP` when it degrades; this is the same shape.
if command -v readelf >/dev/null 2>&1; then
    readelf -d "$WORK/kofun-caller" >"$WORK/dynamic.txt"
    assert_grep "dynamic.txt" \
        -q 'NEEDED.*libkofun_issue21.so' "$WORK/dynamic.txt"
    dynamic_linkage="PASS: the C ABI output is a dynamically linked executable"
else
    dynamic_linkage="SKIP: dynamic linkage of the C ABI output (readelf unavailable)"
fi

printf '%s\n' \
    "PASS: Kofun called Rust extern \"C\" functions from a cdylib" \
    "PASS: 24-byte repr(C) hidden-sret pass/return matches the C caller" \
    "PASS: an eight-argument foreign call exercises SysV stack arguments" \
    "$dynamic_linkage"
