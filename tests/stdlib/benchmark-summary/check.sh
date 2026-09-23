#!/bin/sh
set -eu

# Deterministic benchmark-summary gate for issue #859.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/benchmark-summary"
ASSERT_CONTEXT="benchmark summary"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-benchmark-summary.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'benchmark summary: FAIL: %s\n' "$*" >&2
    exit 1
}

model="$ROOT/tests/stdlib/benchmark-report-model/model.kofun"
fixture="$CASES/summary.kofun"
producer="$WORK/summary.kofun"
expected="$CASES/summary.stdout"
assert_regular_file 'Kofun report model' "$model"
assert_regular_file 'Kofun summary witness' "$fixture"
# Keep the complete-HIR witness small enough for the current projector. Read
# the production summary closure directly; never keep a second implementation.
# A new dependency fails compilation until it is included in this closure.
awk '
    BEGIN {
        count = split("ReportSummary ceil_div absolute_distance sorted_copy merged_rank deviation_segment summarize_segments", names, " ")
        for (i = 1; i <= count; i++) wanted[names[i]] = 1
    }
    /^type / || /^fn / {
        if (selected) exit 1
        name = $2
        sub(/\(.*/, "", name)
        if (name in wanted) {
            if (seen[name]++) exit 1
            selected = 1
        }
    }
    selected { print }
    selected && /^}$/ { selected = 0; print "" }
    END {
        if (selected) exit 1
        for (name in wanted) if (seen[name] != 1) exit 1
    }
' "$model" >"$producer" ||
    assert_fail 'shared summary declarations are missing, duplicated, or unterminated'
cat "$fixture" >>"$producer"
assert_regular_file 'summary golden' "$expected"

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' \
    "$WORK/forbidden"

assert_not_grep 'summary producer imports an ambient dependency' \
    -q -- '^import ' "$producer"
assert_not_grep 'summary producer names host time, file, network, or randomness' \
    -qE -- 'clock_gettime|nanosleep|fopen|open\(|socket\(|connect\(|random|rand\(' \
    "$producer"

"$ROOT/bin/kofun" check "$producer" \
    --emit-typed-sidecar "$WORK/summary-semantic.json" --generation 1 \
    >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "producer did not check: $(cat "$WORK/check.stderr")"
assert_file_nonempty 'typed summary sidecar' "$WORK/summary-semantic.json"
assert_grep 'typed sidecar uses the Stage 2 semantic schema' \
    -Fq -- '"stage2-semantic-v1"' "$WORK/summary-semantic.json"
assert_grep 'typed sidecar is a complete projection' \
    -Fq -- '"completeness": "complete"' "$WORK/summary-semantic.json"
assert_grep 'typed sidecar carries the shared segmented summary' \
    -Fq -- '"ReportSummary"' "$WORK/summary-semantic.json"
assert_grep 'typed sidecar carries the raw sample segment type' \
    -Fq -- '"List[Int]"' "$WORK/summary-semantic.json"

"$ROOT/bin/kofun" build "$producer" -o "$WORK/summary" \
    --emit-c "$WORK/summary.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "producer did not build: $(cat "$WORK/build.stderr")"

"$WORK/summary" >"$WORK/backend.stdout"
cmp "$expected" "$WORK/backend.stdout" ||
    fail 'C11 backend output differs from the summary golden'

"$ROOT/bin/kofun" run "$producer" \
    >"$WORK/reference.stdout" 2>"$WORK/reference.stderr" ||
    fail "reference executor did not run: $(cat "$WORK/reference.stderr")"
cmp "$expected" "$WORK/reference.stdout" ||
    fail 'reference executor output differs from the summary golden'

"$WORK/summary" >"$WORK/backend.second"
cmp "$WORK/backend.stdout" "$WORK/backend.second" ||
    fail 'two executions of the same summary binary differ'

assert_not_grep 'emitted C reaches host time, file, network, or randomness' \
    -qE -- 'time\.h|clock_gettime|gettimeofday|nanosleep|fopen|socket|connect|rand\(' \
    "$WORK/summary.c"

field() {
    sed -n "$1p" "$expected"
}

assert_eq 'minimum of the sorted sample vector' "$(field 1)" '3'
assert_eq 'maximum of the sorted sample vector' "$(field 2)" '41'
assert_eq 'nearest-rank median uses the lower middle observation' \
    "$(field 3)" '17'
assert_eq 'nearest-rank p25 uses rank 2' "$(field 4)" '7'
assert_eq 'nearest-rank p75 uses rank 6' "$(field 5)" '23'
assert_eq 'MAD uses rank 4 of the sorted absolute deviations' \
    "$(field 6)" '6'

lines=$(wc -l <"$expected" | tr -d ' ')
assert_num 'summary golden contains exactly six named fields' "$lines" -eq 6

printf 'benchmark summary: nearest-rank quantiles and MAD: PASS\n'
printf 'benchmark summary: reference and C11 bytes agree deterministically: PASS\n'
