#!/bin/sh
set -eu

csv_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$csv_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-csv-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'csv checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$csv_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$csv_dir/csv.kofun"
for declaration in \
    'type CsvLineEnding =' \
    'type CsvDialect = {' \
    'type CsvDocument = {' \
    'type CsvError =' \
    'fn csv_default_dialect()' \
    'fn csv_validate_dialect(' \
    'fn csv_parse(' \
    'fn csv_render('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for error in \
    InvalidDelimiter InvalidQuote ConflictingDelimiterAndQuote \
    UnexpectedQuote UnexpectedCharacterAfterQuote BareCarriageReturn \
    UnclosedQuotedField
do
    grep -Fq "| $error" "$source_file" ||
        fail "missing typed CSV error: $error"
done

grep -Fq 'symbols[offset + 1] == dialect.quote' "$source_file" ||
    fail 'doubled-quote decoding is missing'
grep -Fq 'replace(field, dialect.quote, dialect.quote + dialect.quote)' \
    "$source_file" || fail 'quote escaping is missing'
grep -Fq 'offset + 1 >= len(symbols) || symbols[offset + 1] != "\n"' \
    "$source_file" || fail 'bare CR rejection is missing'

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `CsvDialect` has a field type outside the Stage 2 Int/Bool/Text/List[Int] slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

"$repo_dir/bin/kofun" run "$csv_dir/tests/checkpoint.kofun" \
    >"$work/checkpoint.stdout"
cmp "$csv_dir/tests/checkpoint.stdout" "$work/checkpoint.stdout" ||
    fail 'Kofun CSV state-machine vectors differ'

[ "$(sed -n '2p' "$work/checkpoint.stdout")" -eq 20404 ] ||
    fail 'mixed LF/CRLF record vector differs'
[ "$(sed -n '6p' "$work/checkpoint.stdout")" -eq 10103 ] ||
    fail 'doubled quote did not decode as one character'
[ "$(sed -n '7p' "$work/checkpoint.stdout")" -eq 10204 ] ||
    fail 'quoted line ending was not preserved as field content'
[ "$(sed -n '8p' "$work/checkpoint.stdout")" -eq 1000000 ] &&
[ "$(sed -n '9p' "$work/checkpoint.stdout")" -eq 2000000 ] &&
[ "$(sed -n '10p' "$work/checkpoint.stdout")" -eq 3000000 ] &&
[ "$(sed -n '11p' "$work/checkpoint.stdout")" -eq 4000000 ] ||
    fail 'malformed CSV statuses are not distinct'

printf 'csv deterministic parse and render vectors: PASS\n'
printf 'csv malformed-boundary errors: PASS\n'
