#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_VALUE_IF_FUZZ_WORK:-"$ROOT/build/value-if-fuzz"}
CASES=${KOFUN_VALUE_IF_FUZZ_CASES:-32}
CC=${CC:-cc}
. "$ROOT/tests/fuzz/semantic_protocol.sh"
. "$ROOT/bootstrap/stage2/build.sh"

case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "value-if fuzz: case count must be positive" >&2
        exit 2
        ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/compiler.c" \
    -o "$WORK/kofun-stage2-sanitized"

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_VALUE_IF_FUZZ_SEED:-324508639}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "value_if fuzz: KOFUN_VALUE_IF_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "value_if fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    left=$((seed % 41))
    next_random
    right=$((seed % 41))
    next_random
    offset=$((seed % 17 + 1))

    if test "$left" -lt "$right"; then
        then_expression="$left + $offset"
        else_expression="1 // 0"
        expected=$((left + offset))
    else
        then_expression="1 // 0"
        else_expression="$right + $offset"
        expected=$((right + offset))
    fi

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/program.kofun"
    {
        printf '%s\n' 'fn main() {'
        printf '    let selected: Int = if %s < %s {\n' "$left" "$right"
        printf '        %s\n' "$then_expression"
        printf '%s\n' '    } else {'
        printf '        %s\n' "$else_expression"
        printf '%s\n' '    }'
        printf '%s\n' '    print(selected)'
        printf '%s\n' '}'
    } >"$source"

    "$WORK/kofun-stage2" \
        "$source" \
        "$case_work/program.c" \
        "$case_work/program.ir" \
        "$case_work/program.tokens" >/dev/null
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-stage2-sanitized" \
        "$source" \
        "$case_work/program-sanitized.c" \
        "$case_work/program-sanitized.ir" \
        "$case_work/program-sanitized.tokens" >/dev/null
    cmp "$case_work/program.c" "$case_work/program-sanitized.c"
    cmp "$case_work/program.ir" "$case_work/program-sanitized.ir"
    cmp "$case_work/program.tokens" "$case_work/program-sanitized.tokens"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror \
        "$case_work/program.c" -o "$case_work/program"
    set +e
    "$case_work/program" \
        >"$case_work/actual.stdout" 2>"$case_work/actual.stderr"
    actual_status=$?
    set -e
    printf '%s\n' "$expected" >"$case_work/expected.stdout"
    : >"$case_work/expected.stderr"
    if ! semantic_wrap_observation_pair \
        value-if "$case_work" value-if-shell-model stage2-c11 \
        "$case_work/expected.stdout" "$case_work/expected.stderr" 0 \
        "$case_work/actual.stdout" "$case_work/actual.stderr" "$actual_status"
    then
        printf '%s\n' \
            "value-if fuzz: case $case_index: $KOFUN_SEMANTIC_MISMATCH" >&2
        exit 1
    fi

    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: value-if fuzz selected exactly one branch for $CASES programs"
