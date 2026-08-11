#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_MATCH_VALUE_FUZZ_WORK:-"$ROOT/build/match-value-fuzz"}
CASES=${KOFUN_MATCH_VALUE_FUZZ_CASES:-32}
CC=${CC:-cc}
. "$ROOT/tests/fuzz/semantic_protocol.sh"
. "$ROOT/bootstrap/stage2/build.sh"
. "$ROOT/bootstrap/stage2/semantic-objects.sh"
. "$ROOT/bootstrap/stage2/fuzz-sanitizer-object.sh"

case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "match-value fuzz: case count must be positive" >&2
        exit 2
        ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
kofun_stage2_fuzz_sanitized_compiler \
    "$ROOT" "$WORK/kofun-stage2-sanitized" match-value

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_MATCH_VALUE_FUZZ_SEED:-1432778632}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "match_value fuzz: KOFUN_MATCH_VALUE_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "match_value fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    first_probe=$((seed % 1000 + 10))
    next_random
    second_probe=$((seed % 1000 + 1010))
    next_random
    selected=$((seed % 1000 + 2010))

    if test $((case_index % 2)) -eq 0; then
        scrutinee=true
        matching=true
        nonmatching=false
    else
        scrutinee=false
        matching=false
        nonmatching=true
    fi

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/program.kofun"
    {
        printf '%s\n' 'fn probe(value: Int) -> Int {'
        printf '%s\n' '    print(value)'
        printf '%s\n' '    return value'
        printf '%s\n' '}'
        printf '%s\n' ''
        printf '%s\n' 'fn main() -> Int {'
        printf '    let selected: Int = match %s {\n' "$scrutinee"
        printf '        %s if 1 // 0 == 0 => {\n' "$nonmatching"
        printf '%s\n' '            9001'
        printf '%s\n' '        },'
        printf '        %s if probe(%s) == %s => {\n' \
            "$matching" "$first_probe" "$((first_probe + 1))"
        printf '%s\n' '            9002'
        printf '%s\n' '        },'
        printf '        %s if probe(%s) == %s => {\n' \
            "$matching" "$second_probe" "$second_probe"
        printf '%s\n' '            if true {'
        printf '                %s\n' "$selected"
        printf '%s\n' '            } else {'
        printf '%s\n' '                1 // 0'
        printf '%s\n' '            }'
        printf '%s\n' '        },'
        printf '        %s if 1 // 0 == 0 => {\n' "$matching"
        printf '%s\n' '            9003'
        printf '%s\n' '        },'
        printf '%s\n' '        true => {'
        printf '%s\n' '            1 // 0'
        printf '%s\n' '        },'
        printf '%s\n' '        false => {'
        printf '%s\n' '            1 // 0'
        printf '%s\n' '        },'
        printf '%s\n' '    }'
        printf '%s\n' '    print(selected)'
        printf '%s\n' '    return 0'
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
        >"$case_work/actual.stdout" \
        2>"$case_work/actual.stderr"
    actual_status=$?
    set -e
    {
        printf '%s\n' "$first_probe"
        printf '%s\n' "$second_probe"
        printf '%s\n' "$selected"
    } >"$case_work/expected.stdout"
    : >"$case_work/expected.stderr"
    if ! semantic_wrap_observation_pair \
        match-value "$case_work" match-value-shell-model stage2-c11 \
        "$case_work/expected.stdout" "$case_work/expected.stderr" 0 \
        "$case_work/actual.stdout" "$case_work/actual.stderr" "$actual_status"
    then
        printf '%s\n' \
            "match-value fuzz: case $case_index: $KOFUN_SEMANTIC_MISMATCH" >&2
        exit 1
    fi

    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: match-value fuzz preserved ordered selected-only evaluation for $CASES programs"
