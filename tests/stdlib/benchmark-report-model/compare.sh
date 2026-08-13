#!/bin/sh
set -eu

# The lasting comparison gate for issue #1313.
#
# The model gate next door proves the reports; this proves what a caller asks
# of two of them. Three things are joined rather than asserted:
#
#   * every verdict, change, and refusal is compared to
#     `spec/benchmark-report-v1/model.mjs`, which computes the same value in
#     arbitrary-precision arithmetic while production computes it in a bounded
#     `Int` by the contract's digit-at-a-time decomposition;
#   * the precedence between an invalid report, an invalid threshold, and an
#     incompatible pair is pinned by fixtures that are wrong in two ways at
#     once, because a rule about order is invisible to a corpus that is only
#     ever wrong in one; and
#   * five reintroduced defects must each change the output.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/benchmark-report-model"
ASSERT_CONTEXT='benchmark report comparison'
. "$ROOT/tests/assertions/assert.sh"

WORK=${KOFUN_BENCHMARK_REPORT_COMPARISON_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}benchmark-report-comparison"}
case $WORK in
    */benchmark-report-comparison|*/benchmark-report-comparison.*) ;;
    *) assert_fail "work directory must end in benchmark-report-comparison[.suffix]: $WORK" ;;
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
assert_regular_file 'Kofun comparison' "$compare"

# ------------------------------------------------------------------ scope
#
# This child owns comparison. It publishes nothing, reads nothing, and claims
# no capability, and the source says so rather than a reviewer having to.

grep -vE '^[[:space:]]*#' "$compare" >"$WORK/compare.code"
assert_not_grep 'comparison reaches for a codec, bytes, or the filesystem' \
    -qE -- 'Bytes|encode|decode|write_text|read_text' "$WORK/compare.code"
assert_not_grep 'comparison names host time, file, network, or randomness' \
    -qE -- 'clock_gettime|nanosleep|fopen|open\(|socket\(|connect\(|random|rand\(' \
    "$compare"
assert_not_grep 'comparison declares its own main' -q -- '^fn main' "$compare"

# The product the contract forbids evaluating in `Int`. Its absence is the
# whole reason the digit loop exists, so the gate reads for it.
assert_not_grep 'comparison evaluates difference * 10000 directly' \
    -qE -- '(difference|change)[[:space:]]*\*[[:space:]]*10000' "$WORK/compare.code"

# ----------------------------------------------------------------- groups

run_case_group() {
    driver=$1
    group=$2
    stem="$3$group"
    {
        printf 'fn main() {\n'
        printf '    let mut cases = run_group(6) + run_comparison_group(6) + run_vector_group(6)\n'
        printf '    cases = cases + %s(%s)\n' "$driver" "$group"
        printf '    print("cases " + to_text(cases))\n'
        printf '}\n'
    } >"$WORK/$stem.main.kofun"
    cat "$model" "$compare" "$corpus" "$WORK/$stem.main.kofun" >"$WORK/$stem.kofun"

    "$ROOT/bin/kofun" build "$WORK/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" \
        >"$WORK/$stem.build.stdout" 2>"$WORK/$stem.build.stderr" ||
        assert_fail "$stem did not build: $(cat "$WORK/$stem.build.stderr")"

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

    node "$oracle" "$4" "$group" >"$WORK/$stem.expected"
    cmp "$WORK/$stem.expected" "$WORK/$stem.stdout" ||
        assert_fail "$stem disagrees with the benchmark-report-v1 oracle"
}

for group in 0 1 2 3 4 5
do
    run_case_group run_comparison_group "$group" comparison comparison
done

# ------------------------------------------------- frozen boundary vectors
#
# #1310's thirteen comparison boundaries, run by name against the production
# comparison (#1367). The value join above uses cases chosen here; this one
# uses cases chosen by the contract, and its coverage is asserted from the
# manifest's side so a boundary added upstream cannot go unrun.

for group in 0 1 2
do
    run_case_group run_vector_group "$group" vectors vectors
done

covered=$(node "$oracle" vector-names | wc -w | tr -d ' ')
assert_num 'every frozen comparison vector has a Kofun case' "$covered" -eq 13

# --------------------------------------------------- coverage mutations
#
# The coverage rule is the point of this join, so it is proved rather than
# read: a vector added upstream with no case must fail, and a case removed
# from the corpus must fail.

add_one_vector() {
    node -e '
        const { readFileSync, writeFileSync } = require("node:fs")
        const manifest = JSON.parse(readFileSync(process.argv[1], "utf8"))
        manifest.vectors.push({
            name: "added-upstream",
            direction: "lower-is-better",
            baseline: 10000,
            candidate: 10001,
            threshold_bps: 0,
            expected: { kind: "comparable", verdict: "regressed", change_bps: 1, threshold_bps: 0 },
        })
        writeFileSync(process.argv[2], JSON.stringify(manifest, null, 2))
    ' "$ROOT/spec/benchmark-report-v1/vectors/comparison.json" "$WORK/comparison-plus-one.json"
}

add_one_vector
if KOFUN_COMPARISON_VECTORS="$WORK/comparison-plus-one.json" \
    node "$oracle" vectors 0 >"$WORK/coverage-added.stdout" 2>"$WORK/coverage-added.stderr"
then
    assert_fail 'a frozen vector with no Kofun case did not fail the coverage check'
fi
assert_grep 'the coverage refusal names the uncovered vector' \
    -Fq -- 'added-upstream' "$WORK/coverage-added.stderr"

sed '/run_vector("zero-baseline"/d' "$corpus" >"$WORK/corpus-missing-case.kofun"
cmp -s "$corpus" "$WORK/corpus-missing-case.kofun" &&
    assert_fail 'the removed-case mutation changed nothing; its pattern no longer matches'
if KOFUN_COMPARISON_CORPUS="$WORK/corpus-missing-case.kofun" \
    node "$oracle" vector-names >"$WORK/coverage-removed.stdout" 2>"$WORK/coverage-removed.stderr"
then
    assert_fail 'a corpus missing a frozen vector case did not fail the coverage check'
fi
assert_grep 'the coverage refusal names the missing vector' \
    -Fq -- 'zero-baseline' "$WORK/coverage-removed.stderr"

# -------------------------------------------------------------- mutations

# A mutation is evidence only if the mutant **builds**. #1377 required this of
# the other two harnesses and deliberately left this one to #1358, because the
# mutation that exposed the whole problem lives here: `precedence` deleted the
# only call to `comparison_compatible`, the mutant failed `-Werror=unused-function`,
# and the harness read that non-zero exit as "the gate bit". It had never run.
#
# So the build is a required step with its own failure, and the comparison is
# unconditional -- a mutant that builds and then traps at runtime leaves an
# empty stdout, which differs from the golden and is a real refusal.
mutation() {
    name=$1
    expression=$2
    group=$3
    sed "$expression" "$compare" >"$WORK/mutant-$name.compare.kofun"
    cmp -s "$compare" "$WORK/mutant-$name.compare.kofun" &&
        assert_fail "mutation $name changed nothing; its pattern no longer matches"
    cat "$model" "$WORK/mutant-$name.compare.kofun" "$corpus" \
        "$WORK/comparison$group.main.kofun" >"$WORK/mutant-$name.kofun"
    "$ROOT/bin/kofun" build "$WORK/mutant-$name.kofun" \
        -o "$WORK/mutant-$name.bin" \
        >"$WORK/mutant-$name.build.stdout" 2>"$WORK/mutant-$name.build.stderr" ||
        assert_fail "mutation $name does not build; it is testing the compiler rather than the model: $(head -1 "$WORK/mutant-$name.build.stderr")"
    "$WORK/mutant-$name.bin" >"$WORK/mutant-$name.stdout" \
        2>"$WORK/mutant-$name.stderr" || true
    if cmp -s "$CASES/comparison$group.stdout" "$WORK/mutant-$name.stdout"
    then
        assert_fail "mutation $name produced the golden output; the gate does not bite"
    fi
}

# An exact half rounds away from zero. Dropping the rounding step keeps every
# other case identical and moves 312.5 to 312 in both directions.
mutation half-rounding 's|    if 2 \* remainder >= base {|    if 2 * remainder > base + base {|' 0

# The threshold is strict. Admitting equality at the boundary turns the
# at-threshold case into a regression.
mutation threshold-strictness 's|    if change > threshold_bps {|    if change >= threshold_bps {|' 1

# The whole quotient is bounded before it is scaled. Without that check the
# overflow case produces a number instead of BR007.
mutation overflow-guard 's|    if whole > limit_integer() // 10000 {|    if whole > limit_integer() {|' 2

# `iterations_per_sample` is compatibility, not an allowed delta. Dropping it
# makes two different batch shapes comparable.
mutation batch-compatibility \
    's|    if baseline.iterations_per_sample != candidate.iterations_per_sample {|    if baseline.iterations_per_sample == 0 - 1 {|' 4

# The threshold is decided before compatibility. Disabling the threshold guard
# makes the pair that is both incompatible and given an invalid threshold
# report BR008 instead of BR009, which is precisely that precedence failing.
#
# This mutation used to disable the *compatibility* guard instead, and it
# proved nothing: with compatibility unchecked, the group-5 pair still reports
# BR009 because the threshold refusal fires first, so the golden did not move.
# It passed only because deleting the sole call to `comparison_compatible`
# made that function unused and the mutant failed to *build* -- the gate was
# reading a `-Werror=unused-function` failure as evidence about precedence.
# #1358 gave every generated function a reference, the mutant started
# building, and the mutation stopped biting. The build failure had been
# carrying it.
mutation precedence \
    's|    if threshold_bps < 0 {|    if threshold_bps == 0 - 2 {|' 5

# Compatibility is checked at all. Group 3 is where that shows: those pairs
# carry a valid threshold, so an unchecked compatibility turns BR008 into a
# comparable verdict, where in group 5 it changes nothing.
mutation compatibility-checked \
    's|    if comparison_compatible(baseline, candidate) == 0 {|    if threshold_bps == 0 - 2 {|' 3

printf '%s\n' \
    'PASS: every verdict, change, and refusal agrees with the benchmark-report-v1 oracle' \
    "PASS: all 13 frozen comparison vectors run by name, and an uncovered one fails the gate" \
    'PASS: exact halves round away from zero and both threshold boundaries are strict' \
    'PASS: invalid report, invalid threshold, and incompatibility keep their stated precedence' \
    'PASS: -O0, -O2, and a repeat execution agree' \
    'PASS: six reintroduced defects are refused'
