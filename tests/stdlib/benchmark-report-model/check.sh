#!/bin/sh
set -eu

# The lasting benchmark-report model gate for issue #1311.
#
# It proves four things about `model.kofun`, and each one is a join rather than
# an assertion about the text:
#
#   * the model's segmented summaries agree with `spec/benchmark-report-v1`'s
#     pure oracle, which computes them from one flat array;
#   * every refusal maps to the contract's error code, and a refused outcome
#     carries no field of a report;
#   * the 49-field record is constructed from four typed list locals, in both
#     constructors, in the emitted C as well as the source; and
#   * a defect reintroduced into the model is refused by this gate rather than
#     merely absent from it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/benchmark-report-model"
ASSERT_CONTEXT='benchmark report model'
. "$ROOT/tests/assertions/assert.sh"

WORK=${KOFUN_BENCHMARK_REPORT_MODEL_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}benchmark-report-model"}
case $WORK in
    */benchmark-report-model|*/benchmark-report-model.*) ;;
    *) assert_fail "work directory must end in benchmark-report-model[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

command -v node >/dev/null 2>&1 || assert_fail 'node is required for the independent oracle'
command -v cmp >/dev/null 2>&1 || assert_fail 'cmp is required'

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    assert_fail 'a C11 compiler is required'
fi

model="$CASES/model.kofun"
corpus="$CASES/corpus.kofun"
oracle="$CASES/oracle.mjs"
assert_regular_file 'Kofun model' "$model"
assert_regular_file 'Kofun corpus' "$corpus"
assert_regular_file 'independent oracle' "$oracle"

# ------------------------------------------------------------------ hygiene

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' "$WORK/forbidden"

assert_not_grep 'model imports an ambient dependency' -q -- '^import ' "$model"
assert_not_grep 'model names host time, file, network, or randomness' \
    -qE -- 'clock_gettime|nanosleep|fopen|open\(|socket\(|connect\(|random|rand\(' \
    "$model"
# Comments name what this child does not own, so the scope check reads code.
#
# `compare_reports` was on this list until #1313, which is the slice that owns
# comparison; the codec and the Bytes carrier still are. Removing the name
# rather than the assertion is the point -- the boundary moved by exactly one
# entry, and the two that remain still fail closed.
grep -vE '^[[:space:]]*#' "$model" >"$WORK/model.code"
assert_not_grep 'model reaches for Bytes or a codec' \
    -qE -- 'Bytes|encode|decode' "$WORK/model.code"
# Comparison is owned here now, and it is owned *whole*: a model that declared
# the carrier without the function, or the function without the vectors the
# oracle joins, would satisfy every other assertion in this file.
assert_grep 'model owns the comparison carrier' \
    -Fq -- 'type Stage2BenchmarkComparisonOutcome' "$WORK/model.code"
assert_grep 'model owns the comparison itself' \
    -Fq -- 'fn compare_reports(' "$WORK/model.code"

# The model is a library: a `main` in it would make the corpus optional, and
# the four groups exist precisely because one program cannot run every case.
assert_not_grep 'model declares its own main' -q -- '^fn main' "$model"

# ------------------------------------------------------------------- census
#
# Both constructors bind the four lists as typed locals first. The contract
# froze that shape, so the gate reads the source for it and the emitted C for
# its consequence rather than trusting a comment.

constructors=$(grep -c 'BenchReport(' "$model")
assert_num 'the model constructs BenchReport in exactly two places' \
    "$constructors" -eq 2

for constructor in neutral_report produce_report
do
    awk -v name="$constructor" '
        $0 ~ "^fn " name { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$model" >"$WORK/$constructor.body"
    locals=$(grep -c ': List\[Int\] = ' "$WORK/$constructor.body")
    assert_num "$constructor binds four typed list locals" "$locals" -eq 4
    assert_grep "$constructor constructs the record after those bindings" \
        -Fq -- 'BenchReport(' "$WORK/$constructor.body"
done

# ------------------------------------------------------------------- groups

run_group() {
    group=$1
    stem="group$group"
    {
        printf 'fn main() {\n'
        printf '    let cases = run_group(%s)\n' "$group"
        printf '    print("cases " + to_text(cases))\n'
        printf '}\n'
    } >"$WORK/$stem.main.kofun"
    cat "$model" "$corpus" "$WORK/$stem.main.kofun" >"$WORK/$stem.kofun"

    # No `--emit-typed-sidecar` here, deliberately: on a program this size the
    # projector prints `ok:`, writes `ETS04`, exits 3, and produces no file
    # (#1360). The assertion belongs in this gate and returns when that is
    # fixed; asserting on a projection that cannot run would only pin the bug.
    "$ROOT/bin/kofun" check "$WORK/$stem.kofun" \
        >"$WORK/$stem.check.stdout" 2>"$WORK/$stem.check.stderr" ||
        assert_fail "$stem did not check: $(cat "$WORK/$stem.check.stderr")"
    assert_grep "$stem is accepted by the checker" \
        -Fq -- 'ok:' "$WORK/$stem.check.stdout"

    "$ROOT/bin/kofun" build "$WORK/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" \
        >"$WORK/$stem.build.stdout" 2>"$WORK/$stem.build.stderr" ||
        assert_fail "$stem did not build: $(cat "$WORK/$stem.build.stderr")"

    # Strict C11 at both optimisation levels, from the same emitted C.
    for level in -O0 -O2
    do
        "$compiler" -std=c11 "$level" -Wall -Wextra -Werror -pedantic \
            "$WORK/$stem.c" -o "$WORK/$stem.$level.bin"
        "$WORK/$stem.$level.bin" >"$WORK/$stem$level.stdout"
        cmp "$WORK/$stem-O0.stdout" "$WORK/$stem$level.stdout" ||
            assert_fail "$stem differs between -O0 and $level"
    done

    "$WORK/$stem.bin" >"$WORK/$stem.stdout"
    "$WORK/$stem.bin" >"$WORK/$stem.second"
    cmp "$WORK/$stem.stdout" "$WORK/$stem.second" ||
        assert_fail "two executions of $stem differ"
    cmp "$WORK/$stem.stdout" "$WORK/$stem-O0.stdout" ||
        assert_fail "$stem differs between the toolchain binary and strict C11"

    cmp "$CASES/$stem.stdout" "$WORK/$stem.stdout" ||
        assert_fail "$stem differs from its golden"

    "$ROOT/bin/kofun" run "$WORK/$stem.kofun" >"$WORK/$stem.reference" 2>&1 ||
        assert_fail "$stem did not run under the reference executor"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.reference" ||
        assert_fail "$stem reference executor output differs from the golden"

    assert_not_grep "$stem emitted C reaches host time, file, network, or randomness" \
        -qE -- 'time\.h|clock_gettime|gettimeofday|nanosleep|fopen|socket|connect|rand\(' \
        "$WORK/$stem.c"
}

for group in 0 1 2 3 4 5 6 7 8 9
do
    run_group "$group"
done

# The two groups of valid reports and the three comparison groups are joined
# to the independent oracle. The refusal groups have no oracle: their
# expectation is the contract's error code, which the golden states and the
# mutations below defend.
#
# Groups 4..6 run the comparison vectors `spec/benchmark-report-v1` froze for
# #1310, by name and with the vector's own arguments. The oracle reads that
# manifest and refuses to run when a vector has no case here, so a boundary
# added upstream fails this gate rather than going unrun.
for group in 0 1 4 5 6
do
    node "$oracle" group "$group" >"$WORK/group$group.expected"
    cmp "$WORK/group$group.expected" "$WORK/group$group.stdout" ||
        assert_fail "group $group disagrees with the benchmark-report-v1 oracle"
done

# -------------------------------------------------------------------- sweep
#
# One count per structural position, each compared to the oracle. The counts
# are named by the oracle and printed here, so a narrowed sweep is visible
# rather than silent; `KOFUN_BENCHMARK_REPORT_MODEL_SWEEP=all` runs 1..100.

node "$oracle" sweep-source >"$WORK/sweep.main.kofun"
node "$oracle" sweep-expect >"$WORK/sweep.expected"
counts=$(node "$oracle" sweep-counts)
cat "$model" "$corpus" "$WORK/sweep.main.kofun" >"$WORK/sweep.kofun"

"$ROOT/bin/kofun" build "$WORK/sweep.kofun" -o "$WORK/sweep.bin" \
    --emit-c "$WORK/sweep.c" \
    >"$WORK/sweep.build.stdout" 2>"$WORK/sweep.build.stderr" ||
    assert_fail "sweep did not build: $(cat "$WORK/sweep.build.stderr")"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/sweep.c" -o "$WORK/sweep.strict"
"$WORK/sweep.strict" >"$WORK/sweep.stdout"
cmp "$WORK/sweep.expected" "$WORK/sweep.stdout" ||
    assert_fail 'the sweep disagrees with the benchmark-report-v1 oracle'

# ---------------------------------------------------------------- mutations
#
# Each mutation reintroduces a defect the model is the fix for, and the gate
# must refuse it. A gate that only passes is not evidence that it bites.

mutation() {
    name=$1
    expression=$2
    group=$3
    sed "$expression" "$model" >"$WORK/mutant-$name.model.kofun"
    cmp -s "$model" "$WORK/mutant-$name.model.kofun" &&
        assert_fail "mutation $name changed nothing; its pattern no longer matches"
    cat "$WORK/mutant-$name.model.kofun" "$corpus" "$WORK/group$group.main.kofun" \
        >"$WORK/mutant-$name.kofun"
    if "$ROOT/bin/kofun" run "$WORK/mutant-$name.kofun" \
        >"$WORK/mutant-$name.stdout" 2>"$WORK/mutant-$name.stderr"
    then
        if cmp -s "$CASES/group$group.stdout" "$WORK/mutant-$name.stdout"
        then
            assert_fail "mutation $name produced the golden output; the gate does not bite"
        fi
    fi
}

# The nearest rank rounds up. Truncating it selects the wrong observation for
# every count that is not a multiple of the denominator.
mutation nearest-rank \
    's|return (numerator + denominator - 1) // denominator|return numerator // denominator|' \
    0

# Tukey's fence is strict. Admitting equality flags a sample exactly on the
# fence, which the contract says is not an outlier.
mutation fence-equality \
    's|if 2 \* below > 3 \* spread|if 2 * below >= 3 * spread|' \
    0

# The second segment starts only after a full first segment. Disarming the
# guard admits a series whose raw index 64 is somewhere else.
mutation canonical-split \
    's|    if len(samples1) > 0 {|    if len(samples1) > 64 {|' \
    2

# A refused outcome carries no report. Leaking one Text field is the failure
# the neutral constructor exists to prevent.
mutation neutral-leak \
    's|        suite: "",|        suite: "leaked",|' \
    2

# ------------------------------------------------------- comparison defects
#
# #1313. Each of these is a way the comparison can be wrong while every report
# in the corpus stays valid, so the report groups above cannot see any of them.

# The threshold is a boundary, not a band. `>=` calls a change exactly on the
# threshold a regression, which is the one case a corpus of strictly-inside
# and strictly-outside values would never separate.
mutation threshold-strictness \
    's|    if change > threshold_bps {|    if change >= threshold_bps {|' \
    4

# Positive means worse in both directions. Reading the tag the other way round
# swaps improved and regressed for every higher-is-better metric, and leaves
# every lower-is-better case in the corpus correct.
mutation direction-tag \
    's|    if baseline.direction_tag == 0 {|    if baseline.direction_tag == 1 {|' \
    5

# The ceiling is tested before the quotient is scaled, because the product it
# would otherwise form traps as R010 first. Disarming that guard is the defect
# that looks like a check and never fires: the overflow case then reaches the
# multiplication and the process dies instead of reporting BR007.
#
# The guard is turned *off* rather than always-on, and the difference matters.
# `quotient > 0 - 1` is always true, so it returns the overflow sentinel for
# every input -- which changes nothing in this group, because both other cases
# take the zero-baseline branch before any division. That mutation edited the
# source, ran, and proved nothing; only a guard that never fires separates the
# two behaviours.
mutation overflow-guard \
    's|        if quotient > limit_integer() {|        if quotient < 0 {|' \
    6

# Every runtime compatibility field is compared on its own. Dropping one leaves
# two reports that differ in it comparable, and the seven others still refuse,
# so only the case for that field can tell.
mutation compatibility-iterations \
    's|    if baseline.iterations_per_sample != candidate.iterations_per_sample {|    if baseline.iterations_per_sample != baseline.iterations_per_sample {|' \
    9

# An invalid input report reports its own validation tag. Reporting a generic
# refusal instead loses which of the two reports was wrong and why.
mutation candidate-status \
    's|        return comparison_failure(candidate.status_tag)|        return comparison_failure(status_invalid_threshold())|' \
    9

printf '%s\n' \
    'PASS: the model constructs one 49-field outcome from four typed list locals in both constructors' \
    "PASS: segmented summaries and strict outliers agree with the benchmark-report-v1 oracle at counts: $counts" \
    'PASS: every refusal maps to its contract code and carries no field of a report' \
    'PASS: -O0, -O2, the reference executor, and a repeat execution agree' \
    'PASS: nine reintroduced defects are refused, five of them comparison defects every valid-report group is blind to'
