#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_SEMANTIC_FUZZ_WORK:-"$ROOT/build/semantic-fuzz"}
CASES=${KOFUN_SEMANTIC_FUZZ_CASES:-48}
MANIFEST="$ROOT/tests/fuzz/families/arithmetic.tsv"
RUNNER="$ROOT/tests/fuzz/semantic_runner.sh"
GENERATOR=arithmetic-lcg-v1
# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
INITIAL_SEED=${KOFUN_SEMANTIC_FUZZ_SEED:-195936478}
case $INITIAL_SEED in
    ''|*[!0-9]*)
        printf '%s\n' "semantic_differential fuzz: KOFUN_SEMANTIC_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "semantic_differential fuzz: seed=$INITIAL_SEED"

if test "${1-}" = --replay; then
    test "$#" -eq 2 || {
        printf '%s\n' \
            'usage: semantic_differential.sh --replay ARTIFACT' >&2
        exit 2
    }
    artifact=$2
    test -f "$artifact/family.manifest" &&
        test -f "$artifact/source.kofun" &&
        test -f "$artifact/case.tsv" || {
        printf '%s\n' "semantic fuzz: incomplete replay artifact: $artifact" >&2
        exit 2
    }
    replay_work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-semantic-replay.XXXXXX")
    trap 'rm -rf "$replay_work"' 0 1 2 15
    case_index=$(sed -n 's/^case-index	//p' "$artifact/case.tsv")
    "$RUNNER" \
        "$artifact/family.manifest" \
        "$artifact/source.kofun" \
        "$artifact/case.tsv" \
        "$replay_work/case" \
        "$replay_work/failures" \
        "replay-case-$case_index"
    printf '%s\n' "PASS: semantic replay case $case_index now agrees"
    exit 0
fi
test "$#" -eq 0 || {
    printf '%s\n' \
        'usage: semantic_differential.sh [--replay ARTIFACT]' >&2
    exit 2
}

case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "semantic fuzz: case count must be positive" >&2
        exit 2
        ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"

seed=$INITIAL_SEED
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    left=$((seed % 9 + 1))
    next_random
    right=$((seed % 9 + 1))
    next_random
    factor=$((seed % 4 + 1))
    next_random
    shape=$((seed % 3))

    case $shape in
        0)
            expression="$left + $right + 20"
            expected=$((left + right + 20))
            ;;
        1)
            expression="($left + $right) * $factor"
            expected=$(((left + right) * factor))
            ;;
        *)
            expression="$left * $right + 10"
            expected=$((left * right + 10))
            ;;
    esac
    if test "$expected" -lt 10 || test "$expected" -gt 99; then
        continue
    fi

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/program.kofun"
    {
        printf '%s\n' 'fn main() {'
        printf '    print(%s)\n' "$expression"
        printf '%s\n' '}'
    } >"$source"
    {
        printf '%s\t%s\n' \
            protocol kofun.semantic-case/v1 \
            family arithmetic-int-core \
            generator "$GENERATOR" \
            seed "$INITIAL_SEED" \
            case-index "$case_index" \
            left "$left" \
            right "$right" \
            factor "$factor" \
            shape "$shape"
    } >"$case_work/case.tsv"

    "$RUNNER" \
        "$MANIFEST" "$source" "$case_work/case.tsv" \
        "$case_work/protocol" "$WORK/failures" "case-$case_index"
    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: semantic fuzz matched independent model and all declared backends for $CASES programs"
