#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/modules/import-aliases"
FIXTURES="$CASES/fixtures"
EXPECTED="$CASES/expected"
CC=${CC:-cc}
WORK=${KOFUN_IMPORT_ALIASES_WORK:-"$ROOT/build/import-aliases"}
TOOL="$WORK/imports-qualified"
SELECTIVE_TOOL="$WORK/imports-selective"
PACKAGE_ID=1111111111111111111111111111111111111111111111111111111111111111
MAIN_MODULE=2222222222222222222222222222222222222222222222222222222222222222
TARGET_MODULE=3333333333333333333333333333333333333333333333333333333333333333
MAIN_FILE=4444444444444444444444444444444444444444444444444444444444444444
TARGET_FILE=5555555555555555555555555555555555555555555555555555555555555555
OTHER_MODULE=6666666666666666666666666666666666666666666666666666666666666666
OTHER_FILE=7777777777777777777777777777777777777777777777777777777777777777
ASSERT_CONTEXT='import aliases'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/imports_qualified.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$TOOL"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/imports_selective.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$SELECTIVE_TOOL"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$CASES/alias_identity_reference.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/alias-identity-reference"

write_inventory() {
    main_source=$1
    output=$2
    {
        printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
            "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$main_source"
        printf '%s|%s|%s|data.formats.delimited.reader|data/formats/delimited/reader.kofun|%s\n' \
            "$PACKAGE_ID" "$TARGET_MODULE" "$TARGET_FILE" "$FIXTURES/reader.kofun"
    } >"$output"
}

write_collision_inventory() {
    main_source=$1
    output=$2
    {
        printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
            "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$main_source"
        printf '%s|%s|%s|data.formats.delimited.reader|data/formats/delimited/reader.kofun|%s\n' \
            "$PACKAGE_ID" "$TARGET_MODULE" "$TARGET_FILE" "$FIXTURES/reader.kofun"
        printf '%s|%s|%s|other.reader|other/reader.kofun|%s\n' \
            "$PACKAGE_ID" "$OTHER_MODULE" "$OTHER_FILE" "$FIXTURES/other_reader.kofun"
    } >"$output"
}

run_program() {
    source=$1
    stem=$2
    write_inventory "$source" "$WORK/$stem.inventory"
    "$TOOL" "$WORK/$stem.inventory" "$WORK/$stem.hir" "$WORK/$stem.c"
    "$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
        "$WORK/$stem.c" -o "$WORK/$stem-program"
    set +e
    "$WORK/$stem-program"
    status=$?
    set -e
    test "$status" -eq 42
}

expect_failure() {
    expected_code=$1
    source=$2
    stem=$3
    expected_output=$4
    inventory="$WORK/$stem.inventory"
    if test "$stem" = qualifier-collision; then
        write_collision_inventory "$source" "$inventory"
    else
        write_inventory "$source" "$inventory"
    fi
    printf '%s\n' stale >"$WORK/$stem.hir"
    printf '%s\n' stale >"$WORK/$stem.c"
    if "$TOOL" "$inventory" "$WORK/$stem.hir" "$WORK/$stem.c" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"; then
        printf '%s\n' "expected $expected_code failure for $stem" >&2
        exit 1
    fi
    assert_file_empty "$stem.stderr" "$WORK/$stem.stderr"
    assert_grep "$stem.stdout" -F "error[$expected_code]:" "$WORK/$stem.stdout"
    cmp "$expected_output" "$WORK/$stem.stdout"
    assert_absent "$stem.hir" "$WORK/$stem.hir"
    test ! -e "$WORK/$stem.c"
}

run_program "$FIXTURES/main_csv.kofun" csv
cmp "$CASES/expected.hir" "$WORK/csv.hir"
assert_grep "csv.hir" \
    -F \
    "|local=csv|target=$TARGET_MODULE|form=qualified-module-v1|" \
    "$WORK/csv.hir"
assert_grep "csv.hir" -F '|alias-binding=' "$WORK/csv.hir"
assert_grep "csv.hir" -F '|alias-span=' "$WORK/csv.hir"
assert_grep "csv.hir" -F '|reexport=false' "$WORK/csv.hir"
if grep -F '|local=reader|' "$WORK/csv.hir" >/dev/null; then
    printf '%s\n' 'default final-component qualifier was bound beside the alias' >&2
    exit 1
fi

ALIAS_BINDING=$(sed -n 's/^import|.*|alias-binding=\([0-9a-f]*\)|.*/\1/p' \
    "$WORK/csv.hir")
ALIAS_SPAN=$(sed -n 's/^import|.*|alias-span=\([0-9]*\.\.[0-9]*\)|.*/\1/p' \
    "$WORK/csv.hir")
ALIAS_START=${ALIAS_SPAN%%..*}
ALIAS_END=${ALIAS_SPAN##*..}
EXPECTED_ALIAS_BINDING=$(
    "$WORK/alias-identity-reference" "$MAIN_MODULE" "$MAIN_FILE" \
        "$ALIAS_START" "$ALIAS_END" csv "$TARGET_MODULE"
)
assert_eq "ALIAS BINDING" "$ALIAS_BINDING" "$EXPECTED_ALIAS_BINDING"
assert_num "${#ALIAS_BINDING}" "${#ALIAS_BINDING}" -eq 64
"$SELECTIVE_TOOL" "$WORK/csv.inventory" \
    "$WORK/csv-selective.hir" "$WORK/csv-selective.c"
assert_grep "csv-selective.hir" \
    -F "|local=csv|target=$TARGET_MODULE|" "$WORK/csv-selective.hir"
assert_grep "csv-selective.hir" \
    -F \
    "|alias-binding=$ALIAS_BINDING|alias-span=$ALIAS_SPAN|reexport=false" \
    "$WORK/csv-selective.hir"
"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    "$WORK/csv-selective.c" -o "$WORK/csv-selective-program"
set +e
"$WORK/csv-selective-program"
SELECTIVE_STATUS=$?
set -e
assert_num "SELECTIVE STATUS" "$SELECTIVE_STATUS" -eq 42

# Alias spellings enter the actual module namespace visible set only after
# ordinary import resolution. A safe alias resolves the collision; a
# confusable alias fails before either HIR or backend output is published.
write_collision_inventory "$FIXTURES/non_confusable_aliases.kofun" \
    "$WORK/non-confusable-aliases.inventory"
"$SELECTIVE_TOOL" "$WORK/non-confusable-aliases.inventory" \
    "$WORK/non-confusable-aliases.hir" \
    "$WORK/non-confusable-aliases.c"
assert_grep "non-confusable-aliases.hir" -F '|local=paypal|' \
    "$WORK/non-confusable-aliases.hir"
assert_grep "non-confusable-aliases.hir" -F '|local=other_reader|' \
    "$WORK/non-confusable-aliases.hir"

write_collision_inventory "$FIXTURES/confusable_aliases.kofun" \
    "$WORK/confusable-aliases.inventory"
printf '%s\n' stale >"$WORK/confusable-aliases.hir"
printf '%s\n' stale >"$WORK/confusable-aliases.c"
set +e
"$SELECTIVE_TOOL" "$WORK/confusable-aliases.inventory" \
    "$WORK/confusable-aliases.hir" "$WORK/confusable-aliases.c" \
    >"$WORK/confusable-aliases.stdout" \
    2>"$WORK/confusable-aliases.stderr"
confusable_alias_status=$?
set -e
assert_num "confusable alias status" "$confusable_alias_status" -eq 1
assert_file_empty "confusable-aliases.stderr" \
    "$WORK/confusable-aliases.stderr"
assert_grep "confusable-aliases.stdout" -F 'error[EUNICODE008]:' \
    "$WORK/confusable-aliases.stdout"
assert_grep "confusable-aliases.stdout" -F '`paypal`' \
    "$WORK/confusable-aliases.stdout"
assert_grep "confusable-aliases.stdout" -F '`pаypal`' \
    "$WORK/confusable-aliases.stdout"
assert_absent "confusable-aliases.hir" "$WORK/confusable-aliases.hir"
assert_absent "confusable-aliases.c" "$WORK/confusable-aliases.c"

run_program "$FIXTURES/main_table.kofun" table
assert_ne "import binding ids in csv.hir and table.hir" \
    "$(sed -n 's/^import|binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/csv.hir")" \
    "$(sed -n 's/^import|binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/table.hir")"
assert_ne "alias-binding ids in csv.hir and table.hir" \
    "$(sed -n 's/^import|.*|alias-binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/csv.hir")" \
    "$(sed -n 's/^import|.*|alias-binding=\([0-9a-f]*\)|.*/\1/p' "$WORK/table.hir")"
sed -n 's/^target|/target|/p; s/^qualified-call|.*|target-module=/target-module=/p' \
    "$WORK/csv.hir" |
    sed 's/|qualifier-span=.*//' >"$WORK/csv-targets"
sed -n 's/^target|/target|/p; s/^qualified-call|.*|target-module=/target-module=/p' \
    "$WORK/table.hir" |
    sed 's/|qualifier-span=.*//' >"$WORK/table-targets"
cmp "$WORK/csv-targets" "$WORK/table-targets"

mkdir -p "$WORK/remapped/source" "$WORK/remapped/dependency"
cp "$FIXTURES/main_csv.kofun" "$WORK/remapped/source/entry.kofun"
cp "$FIXTURES/reader.kofun" "$WORK/remapped/dependency/input.kofun"
{
    printf '%s|%s|%s|app.main|app/main.kofun|%s\n' \
        "$PACKAGE_ID" "$MAIN_MODULE" "$MAIN_FILE" "$WORK/remapped/source/entry.kofun"
    printf '%s|%s|%s|data.formats.delimited.reader|data/formats/delimited/reader.kofun|%s\n' \
        "$PACKAGE_ID" "$TARGET_MODULE" "$TARGET_FILE" \
        "$WORK/remapped/dependency/input.kofun"
} >"$WORK/remapped.inventory"
"$TOOL" "$WORK/remapped.inventory" "$WORK/remapped.hir" "$WORK/remapped.c"
cmp "$WORK/csv.hir" "$WORK/remapped.hir"
cmp "$WORK/csv.c" "$WORK/remapped.c"

expect_failure E2S59 "$FIXTURES/missing_alias.kofun" missing-alias \
    "$EXPECTED/missing_alias.txt"
expect_failure E2S59 "$FIXTURES/keyword_alias.kofun" keyword-alias \
    "$EXPECTED/keyword_alias.txt"
expect_failure E2S59 "$FIXTURES/invalid_alias.kofun" invalid-alias \
    "$EXPECTED/invalid_alias.txt"
expect_failure E2S63 "$FIXTURES/qualifier_collision.kofun" qualifier-collision \
    "$EXPECTED/qualifier_collision.txt"
expect_failure E2S62 "$FIXTURES/duplicate_target.kofun" duplicate-target \
    "$EXPECTED/duplicate_target.txt"
expect_failure E2S59 "$FIXTURES/public_alias.kofun" public-alias \
    "$EXPECTED/public_alias.txt"
expect_failure E2S59 "$FIXTURES/chained_alias.kofun" chained-alias \
    "$EXPECTED/chained_alias.txt"
expect_failure E2S59 "$FIXTURES/per_symbol_alias.kofun" per-symbol-alias \
    "$EXPECTED/per_symbol_alias.txt"
expect_failure E2S59 "$FIXTURES/external_package_alias.kofun" external-package-alias \
    "$EXPECTED/external_package_alias.txt"
expect_failure E2S59 "$FIXTURES/relative_alias.kofun" relative-alias \
    "$EXPECTED/relative_alias.txt"
expect_failure E2S59 "$FIXTURES/malformed_as.kofun" malformed-as \
    "$EXPECTED/malformed_as.txt"
expect_failure E2S65 "$FIXTURES/default_qualifier.kofun" default-qualifier \
    "$EXPECTED/default_qualifier.txt"

"$CC" -std=c11 -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/imports_qualified.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/visibility_access.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$WORK/imports-qualified-sanitized"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/imports-qualified-sanitized" \
    "$WORK/csv.inventory" "$WORK/sanitized.hir"
cmp "$WORK/csv.hir" "$WORK/sanitized.hir"
set +e
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/imports-qualified-sanitized" \
    "$WORK/missing-alias.inventory" "$WORK/sanitized-failure.hir" \
    >"$WORK/sanitized-failure.stdout"
SANITIZED_STATUS=$?
set -e
assert_num "SANITIZED STATUS" "$SANITIZED_STATUS" -eq 1
cmp "$EXPECTED/missing_alias.txt" "$WORK/sanitized-failure.stdout"
assert_absent "sanitized-failure.hir" "$WORK/sanitized-failure.hir"

printf '%s\n' \
    'PASS: module aliases preserve target identities and reject malformed or widening forms'
