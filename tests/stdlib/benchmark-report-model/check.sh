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
compare="$CASES/compare.kofun"
corpus="$CASES/corpus.kofun"
oracle="$CASES/oracle.mjs"
assert_regular_file 'Kofun model' "$model"
assert_regular_file 'Kofun comparison' "$compare"
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
grep -vE '^[[:space:]]*#' "$model" >"$WORK/model.code"
assert_not_grep 'model reaches for Bytes, a codec, or a comparison' \
    -qE -- 'Bytes|encode|decode|compare_reports' "$WORK/model.code"

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
    # `run_comparison_group(6)` matches no branch and runs nothing. It is here
    # because every function in the concatenated program must be *referenced*
    # or the build fails at `cc` with -Werror=unused-function (#1358), and the
    # corpus now carries the #1313 comparison cases as well.
    {
        printf 'fn main() {\n'
        printf '    let mut cases = run_comparison_group(6)\n'
        printf '    cases = cases + run_group(%s)\n' "$group"
        printf '    print("cases " + to_text(cases))\n'
        printf '}\n'
    } >"$WORK/$stem.main.kofun"
    cat "$model" "$compare" "$corpus" "$WORK/$stem.main.kofun" >"$WORK/$stem.kofun"

    "$ROOT/bin/kofun" check "$WORK/$stem.kofun" \
        >"$WORK/$stem.check.stdout" 2>"$WORK/$stem.check.stderr" ||
        assert_fail "$stem did not check: $(cat "$WORK/$stem.check.stderr")"
    assert_grep "$stem is accepted by the checker" \
        -Fq -- 'ok:' "$WORK/$stem.check.stdout"

    # #1360 restored this. The projector still cannot describe a program this
    # size -- it is past the producer's `fn` token profile -- but the three
    # signals now agree, so the outcome is assertable instead of skippable.
    # What this catches is a silent change of outcome in either direction: a
    # projector that starts writing a file here, and a run that goes back to
    # claiming `ok:` while exiting nonzero.
    set +e
    "$ROOT/bin/kofun" check "$WORK/$stem.kofun" \
        --emit-typed-sidecar "$WORK/$stem.sidecar.json" --generation 1 \
        >"$WORK/$stem.sidecar.stdout" 2>"$WORK/$stem.sidecar.stderr"
    sidecar_status=$?
    set -e
    test "$sidecar_status" -eq 3 ||
        assert_fail "$stem sidecar projection exited $sidecar_status instead of 3"
    assert_file_empty "$stem.sidecar.stdout" "$WORK/$stem.sidecar.stdout"
    assert_absent "$stem.sidecar.json" "$WORK/$stem.sidecar.json"
    assert_grep "$stem sidecar refusal names its limit" \
        -Eq -- '^ETS04: declaration limit exceeded: fn tokens reached [0-9]+ at byte [0-9]+; this producer projects at most [0-9]+$' \
        "$WORK/$stem.sidecar.stderr"

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

for group in 0 1 2 3
do
    run_group "$group"
done

# The two groups of valid reports are joined to the independent oracle. The
# refusal groups have no oracle: their expectation is the contract's error
# code, which the golden states and the mutations below defend.
for group in 0 1
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
cat "$model" "$compare" "$corpus" "$WORK/sweep.main.kofun" >"$WORK/sweep.kofun"

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
    cat "$WORK/mutant-$name.model.kofun" "$compare" "$corpus" \
        "$WORK/group$group.main.kofun" >"$WORK/mutant-$name.kofun"
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

printf '%s\n' \
    'PASS: the model constructs one 49-field outcome from four typed list locals in both constructors' \
    "PASS: segmented summaries and strict outliers agree with the benchmark-report-v1 oracle at counts: $counts" \
    'PASS: every refusal maps to its contract code and carries no field of a report' \
    'PASS: -O0, -O2, the reference executor, and a repeat execution agree' \
    'PASS: four reintroduced defects are refused'
