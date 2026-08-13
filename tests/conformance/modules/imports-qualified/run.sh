#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/imports-qualified"
CC=${CC:-cc}
# This script is a gate in its own right *and* a helper that imports-selective,
# re-exports, and the `imports` diagnostic adapter each run. `task verify` runs
# those as separate concurrent targets, so without a per-caller namespace they
# all drive this script into one directory that it deletes on entry (#713).
WORK=${KOFUN_IMPORTS_QUALIFIED_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}imports-qualified"}
TOOL="$WORK/imports-qualified"
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
MAIN_MODULE=2222222222222222222222222222222222222222222222222222222222222222
MATH_MODULE=3333333333333333333333333333333333333333333333333333333333333333
MAIN_FILE=4444444444444444444444444444444444444444444444444444444444444444
MATH_FILE=5555555555555555555555555555555555555555555555555555555555555555
OTHER_MODULE=6666666666666666666666666666666666666666666666666666666666666666
OTHER_FILE=7777777777777777777777777777777777777777777777777777777777777777
NUMBERS_MODULE=8888888888888888888888888888888888888888888888888888888888888888
NUMBERS_FILE=9999999999999999999999999999999999999999999999999999999999999999
ASSERT_CONTEXT='imports qualified'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_TEST_DIAGNOSTIC_FAULTS \
    "$ROOT/bootstrap/stage2/imports_qualified.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$TOOL"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/module_symbols.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/module-symbols"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$CASES/identity_reference.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/identity-reference"

write_inventory() {
    main_path=$1
    math_path=$2
    output=$3
    {
        printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
            "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$main_path"
        printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
            "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$math_path"
    } > "$output"
}

expect_failure() {
    expected=$1
    inventory=$2
    output=$3
    log=$4
    backend=$output.c
    printf '%s\n' stale > "$output"
    printf '%s\n' stale > "$backend"
    if "$TOOL" "$inventory" "$output" "$backend" > "$log" 2>&1; then
        printf '%s\n' "expected $expected failure" >&2
        exit 1
    fi
    assert_grep "log" -F "error[$expected]:" "$log"
    assert_absent "output" "$output"
    test ! -e "$backend"
}

expect_backend_failure() {
    expected=$1
    inventory=$2
    hir=$3
    backend=$4
    log=$5
    if "$TOOL" "$inventory" "$hir" "$backend" > "$log" 2>&1; then
        printf '%s\n' "expected $expected backend failure" >&2
        exit 1
    fi
    assert_grep "log" -F "error[$expected]:" "$log"
    assert_absent "hir" "$hir"
    test ! -e "$backend"
}

write_inventory "$CASES/fixtures/main.kofun" "$CASES/fixtures/math.kofun" "$WORK/ok.inventory"
"$TOOL" "$WORK/ok.inventory" "$WORK/ok.hir" "$WORK/ok.c"
cmp "$CASES/expected.hir" "$WORK/ok.hir"
assert_grep "ok.hir" -Fx 'kofun-imports-qualified/v1' "$WORK/ok.hir"
assert_grep "ok.hir" \
    -F \
    "|local=math|target=$MATH_MODULE|form=qualified-module-v1|" \
    "$WORK/ok.hir"
assert_grep "ok.hir" \
    -F "|target-module=$MATH_MODULE|target-symbol=" "$WORK/ok.hir"
assert_grep "ok.hir" -F '|name=identity|' "$WORK/ok.hir"
assert_grep "ok.hir" \
    -F '|access=Allowed|reason=Allowed|proof=17|' "$WORK/ok.hir"
assert_grep "ok.hir" -F '|signature=fn(1:Int)->Int' "$WORK/ok.hir"
ACTUAL_BINDING=$(sed -n 's/^import|binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/ok.hir")
EXPECTED_BINDING=$("$WORK/identity-reference" "$MAIN_MODULE" "$MAIN_FILE" math "$MATH_MODULE")
assert_eq "ACTUAL BINDING" "$ACTUAL_BINDING" "$EXPECTED_BINDING"
TARGET_SYMBOL=$(sed -n 's/^qualified-call|.*|target-symbol=\([0-9a-f]*\)|.*/\1/p' "$WORK/ok.hir")
assert_num "${#TARGET_SYMBOL}" "${#TARGET_SYMBOL}" -eq 64
assert_grep "ok.c" -F "kofun_s_$TARGET_SYMBOL(" "$WORK/ok.c"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$WORK/ok.c" -o "$WORK/ok-program"
set +e
"$WORK/ok-program"
RUNTIME_STATUS=$?
set -e
assert_num "RUNTIME STATUS" "$RUNTIME_STATUS" -eq 42

printf '%s\n' stale >"$WORK/internal-fault.hir"
printf '%s\n' stale >"$WORK/internal-fault.c"
set +e
KOFUN_DIAGNOSTIC_FAULT=qualified-declared-path-attachment \
    "$TOOL" "$WORK/ok.inventory" "$WORK/internal-fault.hir" \
    "$WORK/internal-fault.c" >"$WORK/internal-fault.stdout" \
    2>"$WORK/internal-fault.stderr"
INTERNAL_FAULT_STATUS=$?
set -e
assert_num "INTERNAL FAULT STATUS" "$INTERNAL_FAULT_STATUS" -eq 1
assert_file_empty "internal-fault.stderr" "$WORK/internal-fault.stderr"
assert_absent "internal-fault.hir" "$WORK/internal-fault.hir"
assert_absent "internal-fault.c" "$WORK/internal-fault.c"
printf '%s\n' 'error[E2S68]: declared-path attachment invariant failed' \
    >"$WORK/internal-fault.expected"
cmp "$WORK/internal-fault.expected" "$WORK/internal-fault.stdout"

sed 's/math\.identity(42)/math.identity(math.identity(42))/' \
    "$CASES/fixtures/main.kofun" > "$WORK/nested.kofun"
write_inventory "$WORK/nested.kofun" "$CASES/fixtures/math.kofun" "$WORK/nested.inventory"
"$TOOL" "$WORK/nested.inventory" "$WORK/nested.hir" "$WORK/nested.c"
assert_num "^qualified-call| lines in nested.hir" \
    "$(grep -c '^qualified-call|' "$WORK/nested.hir")" -eq 2
assert_num "distinct qualified-call binding ids in nested.hir" \
    "$(sed -n 's/^qualified-call|.*|binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/nested.hir" | sort -u | wc -l)" \
    -eq 1
assert_num "distinct qualified-call target-symbol ids in nested.hir" \
    "$(sed -n 's/^qualified-call|.*|target-symbol=\([0-9a-f]*\)|.*/\1/p' "$WORK/nested.hir" | sort -u | wc -l)" \
    -eq 1
sed -n 's/^qualified-call|.*|expression-span=\([^|]*\)|.*/\1/p' \
    "$WORK/nested.hir" > "$WORK/nested-expression-spans.actual"
printf '%s\n' '63..95' '77..94' > "$WORK/nested-expression-spans.expected"
cmp "$WORK/nested-expression-spans.expected" "$WORK/nested-expression-spans.actual"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$WORK/nested.c" -o "$WORK/nested-program"
set +e
"$WORK/nested-program"
NESTED_STATUS=$?
set -e
assert_num "NESTED STATUS" "$NESTED_STATUS" -eq 42

printf '%s\n' \
    'module app.main' \
    'import lib.math' \
    'private fn local(value: Int) -> Int {' \
    '    return value' \
    '}' \
    'fn main() -> Int {' \
    '    return local(42)' \
    '}' > "$WORK/private-local.kofun"
write_inventory "$WORK/private-local.kofun" "$CASES/fixtures/math.kofun" "$WORK/private-local.inventory"
"$TOOL" "$WORK/private-local.inventory" "$WORK/private-local.hir" "$WORK/private-local.c"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$WORK/private-local.c" -o "$WORK/private-local-program"
set +e
"$WORK/private-local-program"
PRIVATE_LOCAL_STATUS=$?
set -e
assert_num "PRIVATE LOCAL STATUS" "$PRIVATE_LOCAL_STATUS" -eq 42

sed 's/return value/return value + 1/' "$CASES/fixtures/math.kofun" > "$WORK/backend-unsupported-math.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/backend-unsupported-math.kofun" "$WORK/backend-unsupported.inventory"
expect_backend_failure E2S65 "$WORK/backend-unsupported.inventory" \
    "$WORK/backend-unsupported.hir" "$WORK/backend-unsupported.c" "$WORK/backend-unsupported.log"

cp "$CASES/fixtures/main.kofun" "$WORK/main-copy.kofun"
cp "$CASES/fixtures/math.kofun" "$WORK/math-copy.kofun"
write_inventory "$WORK/main-copy.kofun" "$WORK/math-copy.kofun" "$WORK/copy.inventory"
"$TOOL" "$WORK/copy.inventory" "$WORK/copy.hir"
cmp "$WORK/ok.hir" "$WORK/copy.hir"

{
    printf '%s|%s|%s|app.other|app/other.kofun|%s\n' \
        "$PACKAGE_ID" "$OTHER_MODULE" "$OTHER_FILE" "$CASES/fixtures/other.kofun"
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$CASES/fixtures/math.kofun"
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
} > "$WORK/two-importers.inventory"
"$TOOL" "$WORK/two-importers.inventory" "$WORK/two-importers.hir"
assert_num "module rows for the math module in two-importers.hir" \
    "$(grep -c "^module|id=$MATH_MODULE|" "$WORK/two-importers.hir")" -eq 1
assert_num "rows targeting the math module in two-importers.hir" \
    "$(grep -c "|target=$MATH_MODULE|" "$WORK/two-importers.hir")" -eq 2
assert_num "distinct import binding ids targeting the math module in two-importers.hir" \
    "$(sed -n 's/^import|binding=\([0-9a-f]*\)|.*|target=3333333333333333333333333333333333333333333333333333333333333333|.*/\1/p' "$WORK/two-importers.hir" | sort -u | wc -l)" \
    -eq 2
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$CASES/fixtures/math.kofun"
    printf '%s|%s|%s|app.other|app/other.kofun|%s\n' \
        "$PACKAGE_ID" "$OTHER_MODULE" "$OTHER_FILE" "$CASES/fixtures/other.kofun"
} > "$WORK/two-importers-reversed.inventory"
"$TOOL" "$WORK/two-importers-reversed.inventory" "$WORK/two-importers-reversed.hir"
cmp "$WORK/two-importers.hir" "$WORK/two-importers-reversed.hir"

sed 's/import lib\.math/import missing.math/' "$CASES/fixtures/main.kofun" > "$WORK/missing.kofun"
write_inventory "$WORK/missing.kofun" "$CASES/fixtures/math.kofun" "$WORK/missing.inventory"
expect_failure E2S60 "$WORK/missing.inventory" "$WORK/missing.hir" "$WORK/missing.log"

sed 's/import lib\.math/import app.main/' "$CASES/fixtures/main.kofun" > "$WORK/self.kofun"
write_inventory "$WORK/self.kofun" "$CASES/fixtures/math.kofun" "$WORK/self.inventory"
expect_failure E2S61 "$WORK/self.inventory" "$WORK/self.hir" "$WORK/self.log"

sed '/import lib\.math/a import lib.math' "$CASES/fixtures/main.kofun" > "$WORK/duplicate.kofun"
write_inventory "$WORK/duplicate.kofun" "$CASES/fixtures/math.kofun" "$WORK/duplicate.inventory"
expect_failure E2S62 "$WORK/duplicate.inventory" "$WORK/duplicate.hir" "$WORK/duplicate.log"

cat > "$WORK/other-math.kofun" <<'EOF'
module other.math

internal fn answer() -> Int {
    return 42
}
EOF
sed '/import lib\.math/a import other.math' "$CASES/fixtures/main.kofun" > "$WORK/collision.kofun"
OTHER_MODULE=6666666666666666666666666666666666666666666666666666666666666666
OTHER_FILE=7777777777777777777777777777777777777777777777777777777777777777
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$WORK/collision.kofun"
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$CASES/fixtures/math.kofun"
    printf '%s|%s|%s|other.math|other/math.kofun|%s\n' \
        "$PACKAGE_ID" "$OTHER_MODULE" "$OTHER_FILE" "$WORK/other-math.kofun"
} > "$WORK/collision.inventory"
expect_failure E2S63 "$WORK/collision.inventory" "$WORK/collision.hir" "$WORK/collision.log"

sed 's/internal fn/private fn/' "$CASES/fixtures/math.kofun" > "$WORK/private-math.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/private-math.kofun" "$WORK/private.inventory"
expect_failure E2S66 "$WORK/private.inventory" "$WORK/private.hir" "$WORK/private.log"
cmp "$CASES/expected-access.txt" "$WORK/private.log"
if grep -F 'lib/math.kofun' "$WORK/private.log" >/dev/null ||
    grep -Eq 'target-symbol=|f83a0ebcff4c1717' "$WORK/private.log"; then
    printf '%s\n' 'private target details leaked through access denial' >&2
    exit 1
fi

sed 's/internal fn/pub fn/' "$CASES/fixtures/math.kofun" > "$WORK/public-math.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/public-math.kofun" "$WORK/public.inventory"
"$TOOL" "$WORK/public.inventory" "$WORK/public.hir"
assert_grep "public.hir" \
    -F '|access=Allowed|reason=Allowed|' "$WORK/public.hir"

sed 's/math\.identity(42)/identity(42)/' "$CASES/fixtures/main.kofun" > "$WORK/unqualified.kofun"
write_inventory "$WORK/unqualified.kofun" "$CASES/fixtures/math.kofun" "$WORK/unqualified.inventory"
expect_failure E2S65 "$WORK/unqualified.inventory" "$WORK/unqualified.hir" "$WORK/unqualified.log"
assert_grep "unqualified.log" \
    -F 'requires its module qualifier' "$WORK/unqualified.log"

write_inventory "$WORK/unqualified.kofun" "$WORK/private-math.kofun" "$WORK/private-unqualified.inventory"
expect_failure E2S53 "$WORK/private-unqualified.inventory" \
    "$WORK/private-unqualified.hir" "$WORK/private-unqualified.log"
cmp "$CASES/expected-private-unqualified.txt" "$WORK/private-unqualified.log"
if grep -F 'lib/math.kofun' "$WORK/private-unqualified.log" >/dev/null ||
    grep -Eq 'target-symbol=|f83a0ebcff4c1717' "$WORK/private-unqualified.log"; then
    printf '%s\n' 'private target existence leaked through unqualified lookup' >&2
    exit 1
fi

sed 's/value: Int/value: Bool/' "$CASES/fixtures/math.kofun" > "$WORK/bool-parameter.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/bool-parameter.kofun" "$WORK/bool-parameter.inventory"
expect_failure E2S65 "$WORK/bool-parameter.inventory" \
    "$WORK/bool-parameter.hir" "$WORK/bool-parameter.log"
cmp "$CASES/expected-bool-parameter.txt" "$WORK/bool-parameter.log"

printf '%s\n' \
    'module app.main' \
    'fn main() -> Int {' \
    '    return 0' \
    '}' > "$WORK/no-qualified-use.kofun"
write_inventory "$WORK/no-qualified-use.kofun" "$WORK/bool-parameter.kofun" \
    "$WORK/backend-bool-parameter.inventory"
expect_failure E2S65 "$WORK/backend-bool-parameter.inventory" \
    "$WORK/backend-bool-parameter.hir" "$WORK/backend-bool-parameter.log"
cmp "$CASES/expected-bool-parameter.txt" "$WORK/backend-bool-parameter.log"

sed 's/) -> Int/) -> Bool/' "$CASES/fixtures/math.kofun" > "$WORK/bool-return.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/bool-return.kofun" "$WORK/bool-return.inventory"
expect_failure E2S65 "$WORK/bool-return.inventory" \
    "$WORK/bool-return.hir" "$WORK/bool-return.log"
cmp "$CASES/expected-bool-return.txt" "$WORK/bool-return.log"

sed 's/math\.identity(42)/math.missing(42)/' "$CASES/fixtures/main.kofun" > "$WORK/unknown-member.kofun"
write_inventory "$WORK/unknown-member.kofun" "$CASES/fixtures/math.kofun" "$WORK/unknown-member.inventory"
expect_failure E2S65 "$WORK/unknown-member.inventory" "$WORK/unknown-member.hir" "$WORK/unknown-member.log"

sed 's/math\.identity(42)/math.identity()/' "$CASES/fixtures/main.kofun" > "$WORK/wrong-arity.kofun"
write_inventory "$WORK/wrong-arity.kofun" "$CASES/fixtures/math.kofun" "$WORK/wrong-arity.inventory"
expect_failure E2S65 "$WORK/wrong-arity.inventory" "$WORK/wrong-arity.hir" "$WORK/wrong-arity.log"

sed 's/import lib\.math/import lib.9math/' "$CASES/fixtures/main.kofun" > "$WORK/invalid-path.kofun"
write_inventory "$WORK/invalid-path.kofun" "$CASES/fixtures/math.kofun" "$WORK/invalid-path.inventory"
expect_failure E2S59 "$WORK/invalid-path.inventory" "$WORK/invalid-path.hir" "$WORK/invalid-path.log"

sed -e 's/import lib\.math/import lib.math as m/' \
    -e 's/math\.identity/m.identity/' \
    "$CASES/fixtures/main.kofun" > "$WORK/alias.kofun"
write_inventory "$WORK/alias.kofun" "$CASES/fixtures/math.kofun" "$WORK/alias.inventory"
"$TOOL" "$WORK/alias.inventory" "$WORK/alias.hir"
assert_grep "alias.hir" \
    -F \
    "|local=m|target=$MATH_MODULE|form=qualified-module-v1|" \
    "$WORK/alias.hir"
assert_grep "alias.hir" -F '|alias-binding=' "$WORK/alias.hir"

sed 's/import lib\.math/import lib.*/' "$CASES/fixtures/main.kofun" > "$WORK/wildcard.kofun"
write_inventory "$WORK/wildcard.kofun" "$CASES/fixtures/math.kofun" "$WORK/wildcard.inventory"
expect_failure E2S59 "$WORK/wildcard.inventory" "$WORK/wildcard.hir" "$WORK/wildcard.log"

sed 's/import lib\.math/pub import lib.math/' "$CASES/fixtures/main.kofun" > "$WORK/re-export.kofun"
write_inventory "$WORK/re-export.kofun" "$CASES/fixtures/math.kofun" "$WORK/re-export.inventory"
expect_failure E2S59 "$WORK/re-export.inventory" "$WORK/re-export.hir" "$WORK/re-export.log"
assert_grep "re-export.log" \
    -F 'outside the ordinary qualified-import slice' "$WORK/re-export.log"

{
    printf '%s|%s|%s|app.main|../app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$CASES/fixtures/math.kofun"
} > "$WORK/escape.inventory"
expect_failure E2S48 "$WORK/escape.inventory" "$WORK/escape.hir" "$WORK/escape.log"

printf '%s\n' \
    'module app.main' \
    'fn helper() -> Int {' \
    '    return 1' \
    '}' \
    'import lib.math' \
    'fn main() -> Int {' \
    '    return math.identity(42)' \
    '}' > "$WORK/late-import.kofun"
write_inventory "$WORK/late-import.kofun" "$CASES/fixtures/math.kofun" "$WORK/late-import.inventory"
expect_failure E2S59 "$WORK/late-import.inventory" "$WORK/late-import.hir" "$WORK/late-import.log"

sed '/module lib\.math/a import app.main' "$CASES/fixtures/math.kofun" > "$WORK/cycle-math.kofun"
write_inventory "$CASES/fixtures/main.kofun" "$WORK/cycle-math.kofun" "$WORK/cycle.inventory"
expect_failure E2S64 "$WORK/cycle.inventory" "$WORK/cycle.hir" "$WORK/cycle.log"
cmp "$CASES/expected-cycle.txt" "$WORK/cycle.log"
{
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$WORK/cycle-math.kofun"
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
} > "$WORK/cycle-reversed.inventory"
expect_failure E2S64 "$WORK/cycle-reversed.inventory" "$WORK/cycle-reversed.hir" "$WORK/cycle-reversed.log"
cmp "$WORK/cycle.log" "$WORK/cycle-reversed.log"

: > "$WORK/cycle-64.inventory"
index=0
while test "$index" -lt 64; do
    name=$(printf 'm%02d' "$index")
    next=$(printf 'm%02d' $(((index + 1) % 64)))
    source="$WORK/cycle-64-$name.kofun"
    printf 'module cycle.%s\nimport cycle.%s\n' "$name" "$next" > "$source"
    printf '%s|%s|%s|cycle.%s|cycle/%s.kofun|%s\n' \
        "$PACKAGE_ID" "$(printf '%064x' $((1000 + index)))" \
        "$(printf '%064x' $((2000 + index)))" "$name" "$name" "$source" \
        >> "$WORK/cycle-64.inventory"
    index=$((index + 1))
done
expect_failure E2S64 "$WORK/cycle-64.inventory" "$WORK/cycle-64.hir" "$WORK/cycle-64.log"
assert_num "size of cycle-64.log" \
    "$(wc -c < "$WORK/cycle-64.log" | tr -d '[:space:]')" -gt 1400
assert_num "'-->' edges in cycle-64.log" \
    "$(awk '{ count = 0; rest = $0; token = "-->"; while ((at = index(rest, token)) > 0) { count += 1; rest = substr(rest, at + length(token)); } print count; }' "$WORK/cycle-64.log")" \
    -eq 64
assert_num "':17..33-->' spans in cycle-64.log" \
    "$(awk '{ count = 0; rest = $0; token = ":17..33-->"; while ((at = index(rest, token)) > 0) { count += 1; rest = substr(rest, at + length(token)); } print count; }' "$WORK/cycle-64.log")" \
    -eq 64
assert_grep "cycle-64.log" \
    -F \
    'error[E2S64]: canonical import cycle: cycle.m00 --cycle/m00.kofun:17..33-->' \
    "$WORK/cycle-64.log"
assert_grep "cycle-64.log" \
    -F \
    -- \
    '--> cycle.m00; hint: remove one import edge from this cycle' \
    "$WORK/cycle-64.log"

sed '/module lib\.math/a import core.numbers' "$CASES/fixtures/math.kofun" > "$WORK/transitive-math.kofun"
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
    printf '%s|%s|%s|lib.math|lib/math.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$WORK/transitive-math.kofun"
    printf '%s|%s|%s|core.numbers|core/numbers.kofun|%s\n' \
        "$PACKAGE_ID" "$NUMBERS_MODULE" "$NUMBERS_FILE" "$CASES/fixtures/numbers.kofun"
} > "$WORK/transitive.inventory"
"$TOOL" "$WORK/transitive.inventory" "$WORK/transitive.hir"
sed 's/math\.identity(42)/numbers.answer()/' "$CASES/fixtures/main.kofun" > "$WORK/transitive-leak.kofun"
sed "s|$CASES/fixtures/main.kofun|$WORK/transitive-leak.kofun|" \
    "$WORK/transitive.inventory" > "$WORK/transitive-leak.inventory"
expect_failure E2S65 "$WORK/transitive-leak.inventory" "$WORK/transitive-leak.hir" "$WORK/transitive-leak.log"

sed '/module core\.numbers/a import app.main' "$CASES/fixtures/numbers.kofun" > "$WORK/cycle-numbers.kofun"
sed "s|$CASES/fixtures/numbers.kofun|$WORK/cycle-numbers.kofun|" \
    "$WORK/transitive.inventory" > "$WORK/three-cycle.inventory"
expect_failure E2S64 "$WORK/three-cycle.inventory" "$WORK/three-cycle.hir" "$WORK/three-cycle.log"
assert_grep "three-cycle.log" \
    -F \
    'canonical import cycle: app.main --app/main.kofun:' \
    "$WORK/three-cycle.log"
assert_grep "three-cycle.log" \
    -F -- '--> lib.math --lib/math.kofun:' "$WORK/three-cycle.log"
assert_grep "three-cycle.log" \
    -F -- '--> core.numbers --core/numbers.kofun:' "$WORK/three-cycle.log"

{
    printf '%s\n' 'module app.main'
    index=0
    while test "$index" -lt 257; do
        printf '%s\n' 'import lib.math'
        index=$((index + 1))
    done
    printf '%s\n' 'fn main() -> Int {' '    return 0' '}'
} > "$WORK/too-many-imports.kofun"
write_inventory "$WORK/too-many-imports.kofun" "$CASES/fixtures/math.kofun" "$WORK/too-many-imports.inventory"
expect_failure E2S67 "$WORK/too-many-imports.inventory" "$WORK/too-many-imports.hir" "$WORK/too-many-imports.log"

{
    printf '%s\n' 'module app.main'
    index=0
    while test "$index" -lt 256; do
        printf '%s\n' 'import lib.math'
        index=$((index + 1))
    done
    printf '%s\n' 'fn main() -> Int {' '    return 0' '}'
} > "$WORK/imports-256.kofun"
write_inventory "$WORK/imports-256.kofun" "$CASES/fixtures/math.kofun" "$WORK/imports-256.inventory"
expect_failure E2S62 "$WORK/imports-256.inventory" "$WORK/imports-256.hir" "$WORK/imports-256.log"

: > "$WORK/empty.kofun"
: > "$WORK/modules-256.inventory"
index=0
while test "$index" -lt 256; do
    module_id=$(printf '%064x' "$index")
    file_id=f$(printf '%063x' "$index")
    printf '%s|%s|%s|m.m%s|m/m%s.kofun|%s\n' \
        "$PACKAGE_ID" "$module_id" "$file_id" "$index" "$index" "$WORK/empty.kofun" \
        >> "$WORK/modules-256.inventory"
    index=$((index + 1))
done
"$TOOL" "$WORK/modules-256.inventory" "$WORK/modules-256.hir"
assert_num "^module| lines in modules-256.hir" \
    "$(grep -c '^module|' "$WORK/modules-256.hir")" -eq 256
cp "$WORK/modules-256.inventory" "$WORK/modules-257.inventory"
module_id=$(printf '%064x' 256)
file_id=f$(printf '%063x' 256)
printf '%s|%s|%s|m.m256|m/m256.kofun|%s\n' \
    "$PACKAGE_ID" "$module_id" "$file_id" "$WORK/empty.kofun" \
    >> "$WORK/modules-257.inventory"
expect_failure E2S67 "$WORK/modules-257.inventory" "$WORK/modules-257.hir" "$WORK/modules-257.log"

{
    printf '%s\n' 'module app.main'
    index=1
    while test "$index" -lt 256; do
        printf 'import m.m%s\n' "$index"
        index=$((index + 1))
    done
    printf '%s\n' 'fn main() -> Int {' '    return 0' '}'
} > "$WORK/imports-255.kofun"
: > "$WORK/imports-255.inventory"
printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
    "$PACKAGE_ID" "$(printf '%064x' 0)" "f$(printf '%063x' 0)" "$WORK/imports-255.kofun" \
    >> "$WORK/imports-255.inventory"
index=1
while test "$index" -lt 256; do
    printf '%s|%s|%s|m.m%s|m/m%s.kofun|%s\n' \
        "$PACKAGE_ID" "$(printf '%064x' "$index")" "f$(printf '%063x' "$index")" \
        "$index" "$index" "$WORK/empty.kofun" >> "$WORK/imports-255.inventory"
    index=$((index + 1))
done
"$TOOL" "$WORK/imports-255.inventory" "$WORK/imports-255.hir"
assert_num "^import| lines in imports-255.hir" \
    "$(grep -c '^import|' "$WORK/imports-255.hir")" -eq 255

long_path=
index=0
while test "$index" -lt 64; do
    component=
    component_length=63
    if test "$index" -eq 63; then component_length=64; fi
    byte=0
    while test "$byte" -lt "$component_length"; do
        component=${component}a
        byte=$((byte + 1))
    done
    if test "$index" -eq 0; then long_path=$component; else long_path=$long_path.$component; fi
    index=$((index + 1))
done
assert_num "${#long_path}" "${#long_path}" -eq 4096
{
    printf 'module app.main\nimport %s\nfn main() -> Int {\n    return 0\n}\n' "$long_path"
} > "$WORK/path-4096.kofun"
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$WORK/path-4096.kofun"
    printf '%s|%s|%s|%s|long/target.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$long_path" "$WORK/empty.kofun"
} > "$WORK/path-4096.inventory"
"$TOOL" "$WORK/path-4096.inventory" "$WORK/path-4096.hir"
long_path=${long_path}a
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$WORK/path-4096.kofun"
    printf '%s|%s|%s|%s|long/target.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$long_path" "$WORK/empty.kofun"
} > "$WORK/path-4097.inventory"
expect_failure E2S59 "$WORK/path-4097.inventory" "$WORK/path-4097.hir" "$WORK/path-4097.log"

component_path=a
index=1
while test "$index" -lt 65; do
    component_path=$component_path.a
    index=$((index + 1))
done
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$CASES/fixtures/main.kofun"
    printf '%s|%s|%s|%s|too/many/components.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$component_path" "$WORK/empty.kofun"
} > "$WORK/components-65.inventory"
expect_failure E2S59 "$WORK/components-65.inventory" "$WORK/components-65.hir" "$WORK/components-65.log"

identifier=
index=0
while test "$index" -lt 256; do
    identifier=${identifier}a
    index=$((index + 1))
done
{
    printf 'module app.main\nimport x.%s\nfn main() -> Int {\n    return 0\n}\n' "$identifier"
} > "$WORK/identifier-256.kofun"
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$WORK/identifier-256.kofun"
    printf '%s|%s|%s|x.%s|identifier/target.kofun|%s\n' \
        "$PACKAGE_ID" "$MATH_MODULE" "$MATH_FILE" "$identifier" "$WORK/empty.kofun"
} > "$WORK/identifier-256.inventory"
"$TOOL" "$WORK/identifier-256.inventory" "$WORK/identifier-256.hir"
identifier=${identifier}a
{
    printf 'module app.main\nimport x.%s\nfn main() -> Int {\n    return 0\n}\n' "$identifier"
} > "$WORK/identifier-257.kofun"
write_inventory "$WORK/identifier-257.kofun" "$CASES/fixtures/math.kofun" "$WORK/identifier-257.inventory"
expect_failure E2S55 "$WORK/identifier-257.inventory" "$WORK/identifier-257.hir" "$WORK/identifier-257.log"

assert_grep "bootstrap/stage2/imports_qualified.c" \
    -F \
    '#define IMPORT_EDGE_LIMIT 65536u' \
    "$ROOT/bootstrap/stage2/imports_qualified.c"
assert_grep "bootstrap/stage2/imports_qualified.c" \
    -F \
    '#define QUALIFIED_USE_LIMIT 65536u' \
    "$ROOT/bootstrap/stage2/imports_qualified.c"
assert_grep "bootstrap/stage2/imports_qualified.c" \
    -F \
    '#define IMPORT_GRAPH_WORK_LIMIT UINT64_C(20000000)' \
    "$ROOT/bootstrap/stage2/imports_qualified.c"

printf '%s\n' 'PASS: qualified same-package imports and HIR projection'
