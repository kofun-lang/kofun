#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/imports-selective"
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
# #1449. The four common sources this gate's analyzer arm links are
# analysed once per verify run and reused; unset the bundle and they are
# compiled from source here, which keeps this gate standalone.
kofun_stage2_analyzer_common_inputs "$ROOT"
WORK=${KOFUN_IMPORTS_SELECTIVE_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}imports-selective"}
TOOL="$WORK/imports-selective"
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
MAIN_MODULE=2222222222222222222222222222222222222222222222222222222222222222
MATH_MODULE=3333333333333333333333333333333333333333333333333333333333333333
MAIN_FILE=4444444444444444444444444444444444444444444444444444444444444444
MATH_FILE=5555555555555555555555555555555555555555555555555555555555555555
ASSERT_CONTEXT='imports selective'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_TEST_DIAGNOSTIC_FAULTS \
    "$ROOT/bootstrap/stage2/imports_selective.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$TOOL"

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
    code=$1
    source=$2
    name=$3
    inventory="$WORK/$name.inventory"
    hir="$WORK/$name.hir"
    backend="$WORK/$name.c"
    log="$WORK/$name.log"
    write_inventory "$source" "$CASES/fixtures/math.kofun" "$inventory"
    printf '%s\n' stale > "$hir"
    printf '%s\n' stale > "$backend"
    if "$TOOL" "$inventory" "$hir" "$backend" > "$log" 2>&1; then
        printf '%s\n' "expected $code failure for $name" >&2
        exit 1
    fi
    assert_grep "log" -F "error[$code]:" "$log"
    assert_absent "hir" "$hir"
    test ! -e "$backend"
}

write_inventory "$CASES/fixtures/main.kofun" "$CASES/fixtures/math.kofun" \
    "$WORK/positive.inventory"
"$TOOL" "$WORK/positive.inventory" "$WORK/positive.hir"

assert_grep "positive.hir" \
    -Fx 'kofun-imports-selective/v1' "$WORK/positive.hir"
assert_grep "positive.hir" -F '|local=identity|' "$WORK/positive.hir"
assert_grep "positive.hir" -F '|local=answer|' "$WORK/positive.hir"
assert_num "|local=Value| lines in positive.hir" \
    "$(grep -c '|local=Value|' "$WORK/positive.hir")" -eq 2
assert_grep "positive.hir" \
    -F '|namespace-name=value|local=Value|' "$WORK/positive.hir"
assert_grep "positive.hir" \
    -F '|namespace-name=type|local=Value|' "$WORK/positive.hir"
assert_grep "positive.hir" -F 'qualified-import|' "$WORK/positive.hir"
assert_grep "positive.hir" -F 'selective-call|' "$WORK/positive.hir"
assert_grep "positive.hir" -F 'qualified-call|' "$WORK/positive.hir"
assert_grep "positive.hir" -F 'type-reference|' "$WORK/positive.hir"
assert_grep "positive.hir" -F '|reexport=false' "$WORK/positive.hir"
assert_grep "positive.hir" -F '|interface=no|' "$WORK/positive.hir"

# The product resolver checks the effective visible set after selective and
# visibility filtering, before either requested artifact is published.
write_inventory "$CASES/fixtures/confusable_local_import.kofun" \
    "$CASES/fixtures/confusable_math.kofun" \
    "$WORK/eunicode008.inventory"
printf '%s\n' stale >"$WORK/eunicode008.hir"
printf '%s\n' stale >"$WORK/eunicode008.c"
set +e
"$TOOL" "$WORK/eunicode008.inventory" "$WORK/eunicode008.hir" \
    "$WORK/eunicode008.c" >"$WORK/eunicode008.stdout" \
    2>"$WORK/eunicode008.stderr"
eunicode008_status=$?
set -e
assert_num "EUNICODE008 status" "$eunicode008_status" -eq 1
assert_file_empty "eunicode008.stderr" "$WORK/eunicode008.stderr"
assert_grep "eunicode008.stdout" -F 'error[EUNICODE008]:' \
    "$WORK/eunicode008.stdout"
assert_grep "eunicode008.stdout" -F '`paypal`' "$WORK/eunicode008.stdout"
assert_grep "eunicode008.stdout" -F '`pаypal`' "$WORK/eunicode008.stdout"
assert_absent "eunicode008.hir" "$WORK/eunicode008.hir"
assert_absent "eunicode008.c" "$WORK/eunicode008.c"

# Reversing inventory discovery order does not perturb diagnostic bytes.
sed -n '2p;1p' "$WORK/eunicode008.inventory" \
    >"$WORK/eunicode008-reversed.inventory"
set +e
"$TOOL" "$WORK/eunicode008-reversed.inventory" \
    "$WORK/eunicode008-reversed.hir" \
    >"$WORK/eunicode008-reversed.stdout" \
    2>"$WORK/eunicode008-reversed.stderr"
reversed_status=$?
set -e
assert_num "reversed EUNICODE008 status" "$reversed_status" -eq 1
assert_file_empty "eunicode008-reversed.stderr" \
    "$WORK/eunicode008-reversed.stderr"
cmp "$WORK/eunicode008.stdout" "$WORK/eunicode008-reversed.stdout"
assert_absent "eunicode008-reversed.hir" "$WORK/eunicode008-reversed.hir"

# Omitted/private spellings are absent from the vector; namespaces remain
# semantic rather than skeleton-global.
write_inventory "$CASES/fixtures/confusable_omitted.kofun" \
    "$CASES/fixtures/confusable_math.kofun" \
    "$WORK/eunicode008-omitted.inventory"
"$TOOL" "$WORK/eunicode008-omitted.inventory" \
    "$WORK/eunicode008-omitted.hir"
assert_not_grep "omitted HIR does not disclose private dependency spelling" \
    -F 'pаypal_private' "$WORK/eunicode008-omitted.hir"
write_inventory "$CASES/fixtures/confusable_namespace_near_miss.kofun" \
    "$CASES/fixtures/confusable_math.kofun" \
    "$WORK/eunicode008-namespace.inventory"
"$TOOL" "$WORK/eunicode008-namespace.inventory" \
    "$WORK/eunicode008-namespace.hir"

write_inventory "$CASES/fixtures/runtime.kofun" "$CASES/fixtures/math.kofun" \
    "$WORK/runtime.inventory"
"$TOOL" "$WORK/runtime.inventory" "$WORK/runtime.hir" "$WORK/runtime.c"
cc -std=c11 -Wall -Wextra -Werror -pedantic "$WORK/runtime.c" -o "$WORK/runtime"
if "$WORK/runtime"; then
    runtime_status=0
else
    runtime_status=$?
fi
assert_num "runtime status" "$runtime_status" -eq 42

# Declaration order and host path remapping cannot perturb semantic output.
write_inventory "$CASES/fixtures/main.kofun" "$CASES/fixtures/math_reordered.kofun" \
    "$WORK/reordered.inventory"
"$TOOL" "$WORK/reordered.inventory" "$WORK/reordered.hir"
cmp "$WORK/positive.hir" "$WORK/reordered.hir"
mkdir -p "$WORK/remapped/a" "$WORK/remapped/b"
cp "$CASES/fixtures/main.kofun" "$WORK/remapped/a/main.kofun"
cp "$CASES/fixtures/math.kofun" "$WORK/remapped/b/math.kofun"
write_inventory "$WORK/remapped/a/main.kofun" "$WORK/remapped/b/math.kofun" \
    "$WORK/remapped.inventory"
"$TOOL" "$WORK/remapped.inventory" "$WORK/remapped.hir"
cmp "$WORK/positive.hir" "$WORK/remapped.hir"

expect_failure E2S69 "$CASES/fixtures/empty.kofun" empty
expect_failure E2S70 "$CASES/fixtures/duplicate.kofun" duplicate
expect_failure E2S71 "$CASES/fixtures/missing.kofun" missing
expect_failure E2S72 "$CASES/fixtures/inaccessible.kofun" inaccessible
expect_failure E2S73 "$CASES/fixtures/local_collision.kofun" local-collision
expect_failure E2S73 "$CASES/fixtures/import_collision.kofun" import-collision
expect_failure E2S69 "$CASES/fixtures/wildcard.kofun" wildcard
expect_failure E2S69 "$CASES/fixtures/alias.kofun" alias
expect_failure E2S69 "$CASES/fixtures/malformed_commas.kofun" malformed-commas
expect_failure E2S69 "$CASES/fixtures/after_declaration.kofun" after-declaration
expect_failure E2S74 "$CASES/fixtures/unlisted.kofun" unlisted
expect_failure E2S74 "$CASES/fixtures/wrong_namespace.kofun" wrong-namespace

expect_exact_forbidden() {
    code=$1
    name=$2
    expected=$3
    shift 3
    hir="$WORK/$name.hir"
    backend="$WORK/$name.c"
    stdout="$WORK/$name.stdout"
    stderr="$WORK/$name.stderr"
    printf '%s\n' stale >"$hir"
    printf '%s\n' stale >"$backend"
    set +e
    "$@" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    test "$status" -eq 1 || {
        printf '%s\n' "$name exited $status instead of 1" >&2
        exit 1
    }
    assert_file_empty "stderr" "$stderr"
    assert_absent "hir" "$hir"
    assert_absent "backend" "$backend"
    printf '%s\n' "$expected" >"$WORK/$name.expected"
    cmp "$WORK/$name.expected" "$stdout"
    grep -F "error[$code]:" "$stdout" >/dev/null
}

{
    printf '%s\n' 'module app.main'
    index=0
    while test "$index" -lt 257; do
        printf '%s\n' 'from lib.math import identity'
        index=$((index + 1))
    done
    printf '%s\n' 'fn main() -> Int {' '    return 0' '}'
} >"$WORK/selective-declarations-over.kofun"
write_inventory "$WORK/selective-declarations-over.kofun" \
    "$CASES/fixtures/math.kofun" "$WORK/selective-declarations-over.inventory"
expect_exact_forbidden E2S75 selective-declarations-over \
    'error[E2S75]: module `app/main.kofun` exceeds 256 combined qualified/selective imports; hint: combine or remove imports' \
    "$TOOL" "$WORK/selective-declarations-over.inventory" \
    "$WORK/selective-declarations-over.hir" "$WORK/selective-declarations-over.c"

sed 's/identity(42)/identity()/' "$CASES/fixtures/main.kofun" \
    >"$WORK/selective-wrong-arity.kofun"
write_inventory "$WORK/selective-wrong-arity.kofun" "$CASES/fixtures/math.kofun" \
    "$WORK/selective-wrong-arity.inventory"
expect_exact_forbidden E2S76 selective-wrong-arity \
    'error[E2S76]: selective call `identity` expects 1 arguments but got 0 in `app/main.kofun`; hint: pass exactly 1 arguments' \
    "$TOOL" "$WORK/selective-wrong-arity.inventory" \
    "$WORK/selective-wrong-arity.hir" "$WORK/selective-wrong-arity.c"

mkdir -p "$WORK/selective-transaction/preserved.hir"
printf '%s\n' sentinel >"$WORK/selective-transaction/preserved.hir/marker"
write_inventory "$CASES/fixtures/runtime.kofun" "$CASES/fixtures/math.kofun" \
    "$WORK/selective-transaction.inventory"
set +e
(
    cd "$WORK/selective-transaction"
    "$TOOL" "$WORK/selective-transaction.inventory" preserved.hir \
        >e2s77.stdout 2>e2s77.stderr
)
transaction_status=$?
set -e
assert_num "transaction status" "$transaction_status" -eq 1
assert_file_empty "selective-transaction/e2s77.stderr" \
    "$WORK/selective-transaction/e2s77.stderr"
assert_dir "selective-transaction/preserved.hir" \
    "$WORK/selective-transaction/preserved.hir"
assert_grep "selective-transaction/preserved.hir/marker" \
    -Fx sentinel "$WORK/selective-transaction/preserved.hir/marker"
printf '%s\n' \
    'error[E2S77]: cannot clear requested output `preserved.hir` before the transaction' \
    >"$WORK/selective-transaction/e2s77.expected"
cmp "$WORK/selective-transaction/e2s77.expected" \
    "$WORK/selective-transaction/e2s77.stdout"

expect_exact_forbidden E2S78 selective-internal \
    'error[E2S78]: type-resolution signature token invariant failed' \
    env KOFUN_DIAGNOSTIC_FAULT=selective-type-resolution-token \
    "$TOOL" "$WORK/positive.inventory" "$WORK/selective-internal.hir" \
    "$WORK/selective-internal.c"

# The qualified-import helper remains independently buildable and passing. It
# gets its own build namespace so this nested run cannot collide with the
# `imports-qualified` target running concurrently under `task verify` (#713).
KOFUN_GATE_WORK_NAMESPACE="${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}nested-imports-selective" \
    sh "$ROOT/tests/conformance/modules/imports-qualified/run.sh"

if command -v clang >/dev/null 2>&1; then
    clang -std=c11 -Wall -Wextra -Werror -pedantic \
        "$ROOT/bootstrap/stage2/imports_selective.c" \
        "$ROOT/bootstrap/stage2/kif_v1.c" \
        "$ROOT/bootstrap/stage2/visibility_access.c" \
        "$ROOT/unicode/kofun_unicode.c" \
        "$ROOT/bootstrap/stage2/sha256.c" \
        -o "$WORK/imports-selective-clang"
    "$WORK/imports-selective-clang" "$WORK/positive.inventory" "$WORK/clang.hir"
    cmp "$WORK/positive.hir" "$WORK/clang.hir"
fi

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/imports_selective.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/imports-selective-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/imports-selective-sanitized" \
    "$WORK/positive.inventory" "$WORK/sanitized.hir"
cmp "$WORK/positive.hir" "$WORK/sanitized.hir"

if KOFUN_STAGE2_COMMON_LINK_ID=imports-selective/analyzed \
    "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
    "$ROOT/bootstrap/stage2/imports_selective.c" \
    "$KOFUN_STAGE2_ANALYZER_KIF_V1_INPUT" \
    "$KOFUN_STAGE2_ANALYZER_VISIBILITY_INPUT" \
    "$KOFUN_STAGE2_ANALYZER_UNICODE_INPUT" \
    "$KOFUN_STAGE2_ANALYZER_SHA256_INPUT" \
    -o "$WORK/imports-selective-analyzed" >/dev/null 2>&1
then
    printf '%s\n' 'PASS: GCC analyzer accepts the selective-import resolver'
fi

printf '%s\n' 'PASS: selective imports preserve namespaces, identities, explicit edges, and transactional failures'
