#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/lexical-scopes"
CC=${CC:-cc}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-lexical-scopes.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "lexical scopes: $*" >&2
    exit 1
}

STAGE2="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$STAGE2"

compile_positive() {
    suffix=$1
    source="$CASES/positive.kofun"
    if test "$suffix" = remapped; then
        source="$WORK/remapped/positive.kofun"
    fi
    "$STAGE2" \
        "$source" \
        "$WORK/positive-$suffix.c" \
        "$WORK/positive-$suffix.ir" \
        "$WORK/positive-$suffix.tokens" \
        >"$WORK/compiler-$suffix.stdout" \
        2>"$WORK/compiler-$suffix.stderr"
    test ! -s "$WORK/compiler-$suffix.stderr" ||
        fail "compiler wrote stderr for the positive fixture"
}

compile_positive first
mkdir -p "$WORK/remapped"
cp "$CASES/positive.kofun" "$WORK/remapped/positive.kofun"
compile_positive remapped
cmp "$WORK/positive-first.c" "$WORK/positive-remapped.c" ||
    fail "C output is not deterministic"
cmp "$WORK/positive-first.ir" "$WORK/positive-remapped.ir" ||
    fail "IR output is not deterministic"
cmp "$WORK/positive-first.tokens" "$WORK/positive-remapped.tokens" ||
    fail "token output is not deterministic"

sed -n '/^kofun-scope-hir\/v1$/,$p' "$WORK/positive-first.ir" \
    >"$WORK/positive.scope-hir"
cmp "$CASES/positive.scope-hir" "$WORK/positive.scope-hir" ||
    fail "scope HIR differs from its structural golden"

grep 'int64_t k_b0' "$WORK/positive-first.c" >/dev/null ||
    fail "generated C does not use BindingId storage"
if grep -E 'k_(seed|total|value|signal)' "$WORK/positive-first.c" >/dev/null; then
    fail "generated C re-resolved a source spelling"
fi

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/positive-first.c" -o "$WORK/positive"
"$WORK/positive" >"$WORK/positive.stdout" 2>"$WORK/positive.stderr"
cmp "$CASES/positive.stdout" "$WORK/positive.stdout" ||
    fail "positive runtime output differs"
test ! -s "$WORK/positive.stderr" ||
    fail "positive program wrote stderr"

expect_failure() {
    name=$1
    set +e
    "$STAGE2" \
        "$CASES/$name.kofun" \
        "$WORK/$name.c" \
        "$WORK/$name.ir" \
        "$WORK/$name.tokens" \
        >"$WORK/$name.stdout" 2>"$WORK/$name.stderr"
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$name returned $status instead of 1"
    cmp "$CASES/$name.stdout" "$WORK/$name.stdout" ||
        fail "$name diagnostic differs"
    test ! -s "$WORK/$name.stderr" ||
        fail "$name wrote stderr"
    test ! -e "$WORK/$name.c" ||
        fail "$name emitted C after a lexical error"
}

expect_failure self_reference
expect_failure nested_self_reference
expect_failure sibling_leak
expect_failure immutable_outer
expect_failure later_declaration
expect_failure unknown_nested
expect_failure cross_function_name
expect_failure enum_constructor_scope_escape
expect_failure nested_scope_escape
expect_failure loop_body_escape
expect_failure loop_bound_escape

"$STAGE2" \
    "$CASES/enum_local_collision.kofun" \
    "$WORK/enum-local.c" \
    "$WORK/enum-local.ir" \
    "$WORK/enum-local.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/enum-local.c" -o "$WORK/enum-local"
"$WORK/enum-local" >"$WORK/enum-local.stdout"
cmp "$CASES/enum_local_collision.stdout" "$WORK/enum-local.stdout" ||
    fail "a local binding colliding with an enum constructor misresolved"

generate_depth() {
    output=$1
    count=$2
    {
        printf '%s\n' 'fn main() {'
        index=0
        while test "$index" -lt "$count"; do
            printf '%s\n' 'if true {'
            index=$((index + 1))
        done
        printf '%s\n' 'print(1)'
        index=0
        while test "$index" -lt "$count"; do
            printf '%s\n' '}'
            index=$((index + 1))
        done
        printf '%s\n' '}'
    } >"$output"
}

generate_bindings() {
    output=$1
    count=$2
    {
        printf '%s\n' 'fn main() {'
        printf '%s\n' 'let b0 = 0'
        index=1
        while test "$index" -lt "$count"; do
            previous=$((index - 1))
            printf 'let b%s = b%s + 1\n' "$index" "$previous"
            index=$((index + 1))
        done
        last=$((count - 1))
        printf 'print(b%s)\n' "$last"
        printf '%s\n' '}'
    } >"$output"
}

generate_scope_count() {
    output=$1
    count=$2
    {
        printf '%s\n' 'fn main() {'
        index=0
        while test "$index" -lt "$count"; do
            printf '%s\n' 'if true { print(1) }'
            index=$((index + 1))
        done
        printf '%s\n' '}'
    } >"$output"
}

generate_uses() {
    output=$1
    count=$2
    {
        printf '%s\n' 'fn main() {'
        index=0
        while test "$index" -lt "$count"; do
            printf '%s\n' 'missing = 1'
            index=$((index + 1))
        done
        printf '%s\n' '}'
    } >"$output"
}

expect_budget_failure() {
    name=$1
    expected=$2
    set +e
    "$STAGE2" \
        "$WORK/$name.kofun" \
        "$WORK/$name.c" \
        "$WORK/$name.ir" \
        "$WORK/$name.tokens" \
        >"$WORK/$name.stdout" 2>"$WORK/$name.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$name unexpectedly compiled"
    test ! -s "$WORK/$name.stderr" || fail "$name wrote stderr"
    test ! -e "$WORK/$name.c" || fail "$name emitted C"
    actual=$(cat "$WORK/$name.stdout")
    test "$actual" = "$expected" || {
        printf '%s\n' "$name actual: $actual" >&2
        fail "$name budget diagnostic differs"
    }
}

generate_depth "$WORK/depth-32.kofun" 31
"$STAGE2" "$WORK/depth-32.kofun" "$WORK/depth-32.c" \
    "$WORK/depth-32.ir" "$WORK/depth-32.tokens" >/dev/null
generate_depth "$WORK/depth-33.kofun" 32
expect_budget_failure depth-33 \
    'error[E2S35]: lexical scope depth limit is 32 at byte 330'

generate_scope_count "$WORK/scopes-256.kofun" 254
"$STAGE2" "$WORK/scopes-256.kofun" "$WORK/scopes-256.c" \
    "$WORK/scopes-256.ir" "$WORK/scopes-256.tokens" >/dev/null
generate_scope_count "$WORK/scopes-257.kofun" 255
expect_budget_failure scopes-257 \
    'error[E2S35]: lexical scope limit is 256 per function at byte 5354'

generate_bindings "$WORK/bindings-256.kofun" 256
"$STAGE2" "$WORK/bindings-256.kofun" "$WORK/bindings-256.c" \
    "$WORK/bindings-256.ir" "$WORK/bindings-256.tokens" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/bindings-256.c" -o "$WORK/bindings-256"
test "$("$WORK/bindings-256")" = 255 ||
    fail "256-binding boundary program returned the wrong value"
generate_bindings "$WORK/bindings-257.kofun" 257
expect_budget_failure bindings-257 \
    'error[E2S35]: lexical binding limit is 256 per function at byte 4909'

# The use budget is 4096 where the other three are 256: bootstrap/stage2/
# compiler.c says why beside `use_count`, and 12 + 4096 * 12 is the byte of the
# 4097th `missing = 1` (#1483).
generate_uses "$WORK/uses-4096.kofun" 4096
expect_budget_failure uses-4096 \
    'error[E2S22]: unknown assignment target `missing` at byte 12; declare it before assignment'
generate_uses "$WORK/uses-4097.kofun" 4097
expect_budget_failure uses-4097 \
    'error[E2S35]: lexical use limit is 4096 per function at byte 49164'

printf '%s\n' \
    'PASS: lexical ScopeId/BindingId resolution, lowering, and diagnostics'
