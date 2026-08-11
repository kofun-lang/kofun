#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/adt-exhaustiveness"
CC=${CC:-cc}
WORK=${KOFUN_ADT_EXHAUSTIVENESS_WORK:-"$ROOT/build/adt-exhaustiveness"}
STAGE2="$WORK/kofun-stage2"
SYMBOLS="$WORK/module-symbols"
TOOL="$WORK/adt-exhaustiveness"
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
TARGET_MODULE=2222222222222222222222222222222222222222222222222222222222222222
TARGET_FILE=3333333333333333333333333333333333333333333333333333333333333333
OTHER_MODULE=4444444444444444444444444444444444444444444444444444444444444444
OTHER_FILE=5555555555555555555555555555555555555555555555555555555555555555
LOGICAL=demo/matching.kofun
ASSERT_CONTEXT='adt exhaustiveness'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

kofun_stage2_build "$ROOT" "$STAGE2"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/module_symbols.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" -o "$SYMBOLS"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/adt_exhaustiveness.c" -o "$TOOL"

write_inventory() {
    source=$1
    output=$2
    logical=${3:-$LOGICAL}
    printf '%s|%s|%s|%s|%s\n' \
        "$PACKAGE_ID" "$TARGET_MODULE" "$TARGET_FILE" "$logical" "$source" \
        > "$output"
}

prepare() {
    stem=$1
    source=$2
    write_inventory "$source" "$WORK/$stem.inventory"
    "$SYMBOLS" "$WORK/$stem.inventory" "$WORK/$stem.symbols"
    "$STAGE2" --parse-patterns "$source" "$WORK/$stem.patterns"
    "$STAGE2" --emit-scope-hir "$source" "$WORK/$stem.scopes"
}

run_success() {
    stem=$1
    source=$2
    prepare "$stem" "$source"
    "$TOOL" "$source" "$LOGICAL" "$WORK/$stem.symbols" \
        "$WORK/$stem.patterns" "$WORK/$stem.scopes" "$WORK/$stem.typed"
}

expect_failure() {
    stem=$1
    source=$2
    code=$3
    prepare "$stem" "$source"
    printf '%s\n' stale > "$WORK/$stem.typed"
    if "$TOOL" "$source" "$LOGICAL" "$WORK/$stem.symbols" \
        "$WORK/$stem.patterns" "$WORK/$stem.scopes" "$WORK/$stem.typed" \
        > "$WORK/$stem.actual" 2>&1
    then
        printf '%s\n' "expected $code failure for $stem" >&2
        exit 1
    fi
    assert_grep "$stem.actual" -F "error[$code]:" "$WORK/$stem.actual"
    test ! -e "$WORK/$stem.typed"
}

run_success exhaustive "$CASES/fixtures/exhaustive.kofun"
assert_grep "exhaustive.typed" \
    -Fx 'kofun-typed-adt-match/v1' "$WORK/exhaustive.typed"
assert_grep "exhaustive.typed" \
    -F '|adt=Result|adt-symbol=' "$WORK/exhaustive.typed"
assert_grep "exhaustive.typed" \
    -F '|constructor=Ok|constructor-symbol=' "$WORK/exhaustive.typed"
assert_grep "exhaustive.typed" \
    -F '|constructor=Err|constructor-symbol=' "$WORK/exhaustive.typed"
assert_grep "exhaustive.typed" \
    -F '|name=item|role=payload|' "$WORK/exhaustive.typed"
assert_grep "exhaustive.typed" \
    -F '|binding=2|name=item|role=read' "$WORK/exhaustive.typed"

run_success wildcard "$CASES/fixtures/wildcard.kofun"
assert_grep "wildcard.typed" -F '|role=wildcard|' "$WORK/wildcard.typed"
run_success binding "$CASES/fixtures/binding.kofun"
assert_grep "binding.typed" -F '|role=binding|' "$WORK/binding.typed"
assert_grep "binding.typed" \
    -F '|name=anything|role=catchall|' "$WORK/binding.typed"

expect_failure missing-payload "$CASES/fixtures/missing_payload.kofun" E2S25
cmp "$CASES/fixtures/missing_payload.stderr" "$WORK/missing-payload.actual"
expect_failure missing-multiple "$CASES/fixtures/missing_multiple.kofun" E2S25
cmp "$CASES/fixtures/missing_multiple.stderr" "$WORK/missing-multiple.actual"
expect_failure guarded-only "$CASES/fixtures/guarded_only.kofun" E2S25
cmp "$CASES/fixtures/guarded_only.stderr" "$WORK/guarded-only.actual"
expect_failure duplicate-constructor "$CASES/fixtures/duplicate_constructor.kofun" E2S26
cmp "$CASES/fixtures/duplicate_constructor.stderr" "$WORK/duplicate-constructor.actual"
expect_failure after-catchall "$CASES/fixtures/after_catchall.kofun" E2S26
cmp "$CASES/fixtures/after_catchall.stderr" "$WORK/after-catchall.actual"
expect_failure redundant-catchall "$CASES/fixtures/redundant_catchall.kofun" E2S26
cmp "$CASES/fixtures/redundant_catchall.stderr" "$WORK/redundant-catchall.actual"
expect_failure nested-payload "$CASES/fixtures/nested_payload.kofun" E2S79
assert_grep "nested-payload.actual" \
    -F 'nested payload usefulness is unsupported' "$WORK/nested-payload.actual"

# Or-pattern alternatives are tested left to right and each one covers its own
# constructor. Grouping parentheses carry no coverage meaning.
run_success or-exhaustive "$CASES/fixtures/or_exhaustive.kofun"
assert_grep "or-exhaustive.typed" \
    -F \
    '|role=or|constructor=-|constructor-symbol=-|' \
    "$WORK/or-exhaustive.typed"
assert_num "^typed-alternative| lines in or-exhaustive.typed" \
    "$(grep -c '^typed-alternative|' "$WORK/or-exhaustive.typed")" -eq 4
assert_grep "or-exhaustive.typed" \
    -F \
    '|arm=1|index=1|node=6|role=constructor|constructor=Err|' \
    "$WORK/or-exhaustive.typed"
# Both alternatives of the first arm publish the one BindingId the body reads.
OR_BINDING=$(sed -n '/^pattern-binding|/s/^pattern-binding|id=\([^|]*\)|.*|name=item|.*/\1/p' \
    "$WORK/or-exhaustive.typed")
assert_nonempty "OR BINDING" "$OR_BINDING"
assert_num "constructor rows binding $OR_BINDING in or-exhaustive.typed" \
    "$(grep -c "|arm=0|index=[01]|node=[0-9]*|role=constructor|constructor=[^|]*|constructor-symbol=[^|]*|binding=$OR_BINDING|" "$WORK/or-exhaustive.typed")" \
    -eq 2
assert_num "^pattern-binding| lines in or-exhaustive.typed" \
    "$(grep -c '^pattern-binding|' "$WORK/or-exhaustive.typed")" -eq 1
assert_grep "or-exhaustive.typed" \
    -F "|binding=$OR_BINDING|name=item|role=read" "$WORK/or-exhaustive.typed"

expect_failure or-missing "$CASES/fixtures/or_missing.kofun" E2S25
cmp "$CASES/fixtures/or_missing.stderr" "$WORK/or-missing.actual"
expect_failure or-guarded "$CASES/fixtures/or_guarded.kofun" E2S25
cmp "$CASES/fixtures/or_guarded.stderr" "$WORK/or-guarded.actual"
expect_failure or-alternative-redundant \
    "$CASES/fixtures/or_alternative_redundant.kofun" E2S26
cmp "$CASES/fixtures/or_alternative_redundant.stderr" \
    "$WORK/or-alternative-redundant.actual"
expect_failure or-arm-redundant "$CASES/fixtures/or_arm_redundant.kofun" E2S26
cmp "$CASES/fixtures/or_arm_redundant.stderr" "$WORK/or-arm-redundant.actual"
expect_failure or-binding-mismatch "$CASES/fixtures/or_binding_mismatch.kofun" E2S105
cmp "$CASES/fixtures/or_binding_mismatch.stderr" "$WORK/or-binding-mismatch.actual"
expect_failure or-catchall-binding "$CASES/fixtures/or_catchall_binding.kofun" E2S105
cmp "$CASES/fixtures/or_catchall_binding.stderr" "$WORK/or-catchall-binding.actual"

# Same spelling in another module cannot steal the target constructor identity.
{
    printf '%s|%s|%s|target/main.kofun|%s\n' \
        "$PACKAGE_ID" "$TARGET_MODULE" "$TARGET_FILE" "$CASES/fixtures/same_target.kofun"
    printf '%s|%s|%s|other/main.kofun|%s\n' \
        "$PACKAGE_ID" "$OTHER_MODULE" "$OTHER_FILE" "$CASES/fixtures/same_other.kofun"
} > "$WORK/same.inventory"
"$SYMBOLS" "$WORK/same.inventory" "$WORK/same.symbols"
"$STAGE2" --parse-patterns "$CASES/fixtures/same_target.kofun" "$WORK/same.patterns"
"$STAGE2" --emit-scope-hir "$CASES/fixtures/same_target.kofun" "$WORK/same.scopes"
"$TOOL" "$CASES/fixtures/same_target.kofun" target/main.kofun \
    "$WORK/same.symbols" "$WORK/same.patterns" "$WORK/same.scopes" "$WORK/same.typed"
TARGET_SAME=$(sed -n '/module=0|.*kind=constructor|name=Same|/s/.*|symbol=\([^|]*\)|.*/\1/p' \
    "$WORK/same.symbols")
assert_num "${#TARGET_SAME}" "${#TARGET_SAME}" -eq 64
assert_grep "same.typed" \
    -F "|constructor=Same|constructor-symbol=$TARGET_SAME|" "$WORK/same.typed"

# Repeated runs and host-path remapping preserve the typed projection.
"$TOOL" "$CASES/fixtures/exhaustive.kofun" "$LOGICAL" "$WORK/exhaustive.symbols" \
    "$WORK/exhaustive.patterns" "$WORK/exhaustive.scopes" "$WORK/exhaustive.second.typed"
cmp "$WORK/exhaustive.typed" "$WORK/exhaustive.second.typed"
mkdir -p "$WORK/remapped"
cp "$CASES/fixtures/exhaustive.kofun" "$WORK/remapped/input.kofun"
run_success remapped "$WORK/remapped/input.kofun"
cmp "$WORK/exhaustive.typed" "$WORK/remapped.typed"

# Corrupt/stale artifacts are rejected transactionally.
sed 's/name=Result/name=StaleResult/' "$WORK/exhaustive.symbols" \
    > "$WORK/stale.symbols"
printf '%s\n' stale > "$WORK/stale.typed"
if "$TOOL" "$CASES/fixtures/exhaustive.kofun" "$LOGICAL" \
    "$WORK/stale.symbols" "$WORK/exhaustive.patterns" \
    "$WORK/exhaustive.scopes" "$WORK/stale.typed" > "$WORK/stale.actual" 2>&1
then
    printf '%s\n' 'expected stale artifact failure' >&2
    exit 1
fi
assert_grep "stale.actual" -F 'error[E2S79]:' "$WORK/stale.actual"
assert_absent "stale.typed" "$WORK/stale.typed"

# Generate a 64-constructor ADT and prove the declared operation boundary.
generate_budget_source() {
    match_count=$1
    output=$2
    {
        printf '%s\n' 'module budget.main' '' 'type Wide ='
        constructor=0
        while test "$constructor" -lt 64; do
            printf '    | C%s\n' "$constructor"
            constructor=$((constructor + 1))
        done
        printf '%s\n' '' 'fn inspect(value: Wide) -> Int {'
        match=0
        while test "$match" -lt "$match_count"; do
            printf '%s\n' '    match value {' '        _ => { 0 }' '    }'
            match=$((match + 1))
        done
        printf '%s\n' '    return 0' '}'
    } > "$output"
}
generate_budget_source 61 "$WORK/budget-boundary.kofun"
run_success budget-boundary "$WORK/budget-boundary.kofun"
generate_budget_source 62 "$WORK/budget-over.kofun"
expect_failure budget-over "$WORK/budget-over.kofun" E2S79
assert_grep "budget-over.actual" \
    -F 'exceeds 4096 operations' "$WORK/budget-over.actual"

# One arm may list every constructor of a 64-constructor ADT as an alternative.
# The 65th alternative is refused by the declared arm boundary, not by the
# Pattern artifact reader.
generate_alternative_source() {
    alternative_count=$1
    output=$2
    {
        printf '%s\n' 'module wide.main' '' 'type Wide ='
        constructor=0
        while test "$constructor" -lt 64; do
            printf '    | C%s\n' "$constructor"
            constructor=$((constructor + 1))
        done
        printf '%s\n' '' 'fn inspect(value: Wide) -> Int {' \
            '    let selected: Int = match value {'
        printf '        '
        alternative=0
        while test "$alternative" -lt "$alternative_count"; do
            test "$alternative" -eq 0 || printf ' | '
            printf 'C%s' "$((alternative % 64))"
            alternative=$((alternative + 1))
        done
        printf '%s\n' ' => { 0 }' '    }' '    return selected' '}'
    } > "$output"
}
generate_alternative_source 64 "$WORK/alternatives-boundary.kofun"
run_success alternatives-boundary "$WORK/alternatives-boundary.kofun"
assert_num "^typed-alternative| lines in alternatives-boundary.typed" \
    "$(grep -c '^typed-alternative|' "$WORK/alternatives-boundary.typed")" \
    -eq 64
generate_alternative_source 65 "$WORK/alternatives-over.kofun"
expect_failure alternatives-over "$WORK/alternatives-over.kofun" E2S79
assert_grep "alternatives-over.actual" \
    -F 'exceeds 64 alternatives in one arm' "$WORK/alternatives-over.actual"

if command -v clang >/dev/null 2>&1; then
    clang -std=c11 -Wall -Wextra -Werror -pedantic \
        "$ROOT/bootstrap/stage2/adt_exhaustiveness.c" -o "$WORK/adt-exhaustiveness-clang"
    "$WORK/adt-exhaustiveness-clang" "$CASES/fixtures/exhaustive.kofun" "$LOGICAL" \
        "$WORK/exhaustive.symbols" "$WORK/exhaustive.patterns" \
        "$WORK/exhaustive.scopes" "$WORK/clang.typed"
    cmp "$WORK/exhaustive.typed" "$WORK/clang.typed"
fi

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/adt_exhaustiveness.c" -o "$WORK/adt-exhaustiveness-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/adt-exhaustiveness-sanitized" "$CASES/fixtures/exhaustive.kofun" "$LOGICAL" \
    "$WORK/exhaustive.symbols" "$WORK/exhaustive.patterns" \
    "$WORK/exhaustive.scopes" "$WORK/sanitized.typed"
cmp "$WORK/exhaustive.typed" "$WORK/sanitized.typed"

if "$CC" -std=c11 -O0 -Wall -Wextra -Werror -pedantic -fanalyzer \
    "$ROOT/bootstrap/stage2/adt_exhaustiveness.c" \
    -o "$WORK/adt-exhaustiveness-analyzed" >/dev/null 2>&1
then
    printf '%s\n' 'PASS: GCC analyzer accepts the ADT exhaustiveness adapter'
fi

# #1099 is a standalone resolved-matrix checkpoint, but it is part of the
# lasting ADT exhaustiveness capability. Keep its dedicated runner reachable
# from this existing `task verify` edge without adding another Taskfile row.
KOFUN_ADT_NESTED_USEFULNESS_WORK="$WORK/adt-nested-usefulness" \
    sh "$ROOT/tests/conformance/adt-nested-usefulness/run.sh"

printf '%s\n' 'PASS: resolved ADT identities drive exhaustive, redundant, guarded, and bounded match diagnostics'
