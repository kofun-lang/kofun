#!/bin/sh
# Gate `bootstrap/stage2/module-inventory.sh`.
#
# The producer's whole job is to derive three identities the way
# `spec/modules/module-identity.md` and `spec/modules/source-file-mapping.md`
# say, so the load-bearing assertion is not "it produces six fields" but "it
# produces the same bytes the specification's own reference vector produces".
# The package and module goldens below are copied from
# `spec/module-identity/check.sh`; if that gate's goldens move because the
# scheme changed, this one fails too, which is the intended coupling.
#
# The end-to-end case is the other half. Before this producer existed the
# resolver could only be driven with `1111…`/`2222…` placeholders, so "the
# resolver works" and "the toolchain can resolve a real program" were different
# claims. This gate runs a two-module program through real identities to a
# running binary.
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${KOFUN_MODULE_INVENTORY_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}module-inventory"}
PRODUCER="$ROOT/bootstrap/stage2/module-inventory.sh"
CC=${CC:-cc}
ASSERT_CONTEXT='module inventory'
. "$ROOT/tests/assertions/assert.sh"

# The specification's own reference vector, for package `demo` and module
# `demo.api`. These are not this gate's numbers.
SPEC_PACKAGE_ID=eb09a959d6f2a46fbe09c6bc699748d4c0cae7b243987736d5f837493382937f
SPEC_MODULE_ID=6afda3bdd9875c08bbe21e1be7ea0ff08483939e3c010c59ff41f2d94d3b98cb

rm -rf "$WORK"
mkdir -p "$WORK/demo"

printf 'module demo.api\n\nfn main() -> Int {\n    0\n}\n' >"$WORK/demo/api.kofun"
sh "$PRODUCER" demo "$WORK/demo" "$WORK/demo/api.kofun" >"$WORK/demo.inventory"

assert_num "one row per file" \
    "$(wc -l <"$WORK/demo.inventory" | tr -d ' ')" -eq 1

assert_eq "package id matches the specification's reference vector" \
    "$(cut -d'|' -f1 "$WORK/demo.inventory")" "$SPEC_PACKAGE_ID"
assert_eq "module id matches the specification's reference vector" \
    "$(cut -d'|' -f2 "$WORK/demo.inventory")" "$SPEC_MODULE_ID"
assert_eq "module path is the declared one" \
    "$(cut -d'|' -f4 "$WORK/demo.inventory")" demo.api
assert_eq "logical path is relative to the package root" \
    "$(cut -d'|' -f5 "$WORK/demo.inventory")" api.kofun

file_id=$(cut -d'|' -f3 "$WORK/demo.inventory")
assert_num "file id is 64 hex characters" "${#file_id}" -eq 64

# The specification states that the logical path participates in FileId, so
# moving a file changes its identity even when the bytes and the module
# declaration do not. That is a claim about the payload this producer builds,
# and it is only true if the producer actually puts the path in.
mkdir -p "$WORK/demo/nested"
cp "$WORK/demo/api.kofun" "$WORK/demo/nested/api.kofun"
sh "$PRODUCER" demo "$WORK/demo" "$WORK/demo/nested/api.kofun" >"$WORK/moved.inventory"
assert_eq "moving a file keeps its module id" \
    "$(cut -d'|' -f2 "$WORK/moved.inventory")" "$SPEC_MODULE_ID"
if test "$(cut -d'|' -f3 "$WORK/moved.inventory")" = "$file_id"; then
    printf '%s\n' \
        "FAIL: module inventory: the logical path does not participate in FileId" >&2
    exit 1
fi

# Determinism: the same inputs must produce the same bytes, or the inventory
# cannot be an identity at all.
sh "$PRODUCER" demo "$WORK/demo" "$WORK/demo/api.kofun" >"$WORK/again.inventory"
cmp "$WORK/demo.inventory" "$WORK/again.inventory"

# Refusals.
printf 'fn main() -> Int {\n    0\n}\n' >"$WORK/demo/headless.kofun"
set +e
sh "$PRODUCER" demo "$WORK/demo" "$WORK/demo/headless.kofun" >"$WORK/headless.out" 2>"$WORK/headless.err"
headless_status=$?
sh "$PRODUCER" demo "$WORK/demo" "$ROOT/README.md" >"$WORK/outside.out" 2>"$WORK/outside.err"
outside_status=$?
set -e
assert_num "a file declaring no module is refused" "$headless_status" -ne 0
assert_grep "headless diagnostic" -F "declares no module" "$WORK/headless.err"
assert_num "a file outside the package root is refused" "$outside_status" -ne 0
assert_grep "outside diagnostic" -F "outside the package root" "$WORK/outside.err"

# End to end: real identities, the shipped resolver, a running binary.
mkdir -p "$WORK/pkg/app" "$WORK/pkg/lib"
printf 'module app.main\nimport lib.math\n\nfn main() -> Int {\n    return math.identity(42)\n}\n' \
    >"$WORK/pkg/app/main.kofun"
printf 'module lib.math\n\npub fn identity(value: Int) -> Int {\n    return value\n}\n' \
    >"$WORK/pkg/lib/math.kofun"

sh "$PRODUCER" demo "$WORK/pkg" \
    "$WORK/pkg/app/main.kofun" "$WORK/pkg/lib/math.kofun" >"$WORK/pkg.inventory"
assert_num "two modules" "$(wc -l <"$WORK/pkg.inventory" | tr -d ' ')" -eq 2

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/imports_qualified.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/resolver"

"$WORK/resolver" "$WORK/pkg.inventory" "$WORK/pkg.hir" "$WORK/pkg.c"
assert_file_nonempty "resolved HIR" "$WORK/pkg.hir"
assert_file_nonempty "reference C" "$WORK/pkg.c"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/pkg.c" -o "$WORK/program"
set +e
"$WORK/program"
program_status=$?
set -e
assert_num "the two-module program runs and returns its value" "$program_status" -eq 42

printf '%s\n' \
    "PASS: inventory identities match the specification's reference vector, and a two-module program resolves and runs"
