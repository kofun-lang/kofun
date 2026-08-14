#!/bin/sh
# Gate `extern "C" fn` on the path a user runs.
#
# `task raw-imports` proves the trust boundary inside the resolver, driven by
# its own harness. This gate proves the same program compiles, links against a
# real C library, and runs **through `bin/kofun`** — because #1217 and #902 are
# about what a user gets when they type a command, and evidence collected only
# under a conformance harness is evidence about a different program.
#
# The three cases are the three outcomes a caller can produce, and each one
# fails differently if the wiring is wrong:
#
#   1. declared class, trusted import, library supplied — runs;
#   2. same program, no library — refused **by name**, not by a linker error
#      naming a symbol the author never typed;
#   3. `extern "C"` without `trust raw-foreign` — refused, because otherwise
#      the boundary is bypassable by construction.
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${KOFUN_EXTERN_C_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}extern-c"}
CC=${CC:-cc}
ASSERT_CONTEXT='extern c'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK/pkg/app" "$WORK/pkg/sys" "$WORK/bad/app" "$WORK/bad/sys"

# The library the declaration promises. Building it here rather than checking in
# a binary keeps the gate honest about what it links.
printf '#include <stdint.h>\nint64_t kofun_double(int64_t value) { return value * 2; }\n' \
    >"$WORK/lib.c"
"$CC" -std=c11 -O2 -c "$WORK/lib.c" -o "$WORK/lib.o"
ar rcs "$WORK/libkofundemo.a" "$WORK/lib.o"

printf 'module sys.libm\ntrust raw-foreign\n\npub extern "C" fn kofun_double(value: Int) -> Int\n' \
    >"$WORK/pkg/sys/libm.kofun"
printf 'module app.main\ntrusted import sys.libm\n\nfn main() -> Int {\n    return libm.kofun_double(21)\n}\n' \
    >"$WORK/pkg/app/main.kofun"

# Same program, minus the class declaration, imported ordinarily.
printf 'module sys.libm\n\npub extern "C" fn kofun_double(value: Int) -> Int\n' \
    >"$WORK/bad/sys/libm.kofun"
printf 'module app.main\nimport sys.libm\n\nfn main() -> Int {\n    return libm.kofun_double(21)\n}\n' \
    >"$WORK/bad/app/main.kofun"

# 1. The whole path: resolve, emit, link, run.
"$ROOT/bin/kofun" build "$WORK/pkg/app/main.kofun" \
    --backend c --link-library "$WORK/libkofundemo.a" -o "$WORK/program" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr"
assert_file_empty "build.stderr" "$WORK/build.stderr"
set +e
"$WORK/program"
program_status=$?
set -e
assert_num "the linked program runs and returns the C result" "$program_status" -eq 42

# The emitted C must declare the external symbol by its source name and define
# nothing for it: a hashed name would be a prototype no library satisfies.
"$ROOT/bin/kofun" emit-c "$WORK/pkg/app/main.kofun" "$WORK/program.c" >/dev/null
assert_grep "external prototype uses the source name" \
    -Fx "int64_t kofun_double(int64_t k_p0);" "$WORK/program.c"
if grep -q "^int64_t kofun_double(int64_t k_p0) {" "$WORK/program.c"; then
    printf '%s\n' "FAIL: extern c: a definition was emitted for an external symbol" >&2
    exit 1
fi

# 2. No library: refused by name, before the linker speaks.
set +e
"$ROOT/bin/kofun" build "$WORK/pkg/app/main.kofun" -o "$WORK/unlinked" \
    >"$WORK/unlinked.stdout" 2>"$WORK/unlinked.stderr"
unlinked_status=$?
set -e
assert_num "an unlinked extern program is refused" "$unlinked_status" -eq 2
assert_grep "the refusal names the declaration" \
    -F 'declares `extern "C" fn`' "$WORK/unlinked.stderr"
if grep -qi "undefined reference" "$WORK/unlinked.stderr"; then
    printf '%s\n' "FAIL: extern c: the linker reported this instead of the driver" >&2
    exit 1
fi
assert_absent "no binary from a refused build" "$WORK/unlinked"

# 3. The class is not optional.
set +e
"$ROOT/bin/kofun" build "$WORK/bad/app/main.kofun" \
    --backend c --link-library "$WORK/libkofundemo.a" -o "$WORK/bad-program" \
    >"$WORK/bad.stdout" 2>"$WORK/bad.stderr"
bad_status=$?
set -e
assert_num "extern \"C\" without trust raw-foreign is refused" "$bad_status" -ne 0
assert_grep "the refusal names the missing class" \
    -F "requires \`trust raw-foreign\`" "$WORK/bad.stderr" 2>/dev/null ||
    assert_grep "the refusal names the missing class" \
        -F "requires \`trust raw-foreign\`" "$WORK/bad.stdout"
assert_absent "no binary from a refused build" "$WORK/bad-program"

printf '%s\n' \
    "PASS: an extern \"C\" module links and runs through bin/kofun, an unlinked build is refused by name, and the raw-foreign class is not optional"
