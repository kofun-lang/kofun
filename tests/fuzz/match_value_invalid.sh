#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_MATCH_VALUE_INVALID_FUZZ_WORK:-"$ROOT/build/match-value-invalid-fuzz"}
CASES=${KOFUN_MATCH_VALUE_INVALID_FUZZ_CASES:-32}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "match-value invalid fuzz: case count must be positive" >&2
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

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_MATCH_VALUE_INVALID_FUZZ_SEED:-1831565813}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "match_value_invalid fuzz: KOFUN_MATCH_VALUE_INVALID_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "match_value_invalid fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    value=$((seed % 10000 + 1))
    variant=$((case_index % 8))
    expected_code=
    case_name=

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/program.kofun"

    case $variant in
        0)
            expected_code=E2S25
            case_name=missing-false
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '%s\n' '        true => {'
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        1)
            expected_code=E2S26
            case_name=duplicate-true
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match false {'
                printf '%s\n' '        true => {'
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '        true => {'
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 2))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        2)
            expected_code=E2S26
            case_name=after-catchall
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '%s\n' '        _ => {'
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        3)
            expected_code=E2S29
            case_name=invalid-guard
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '        true if %s + 1 => {\n' "$value"
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '        true => {'
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 2))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        4)
            expected_code=E2S30
            case_name=void-arm
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '%s\n' '        true => {'
                printf '            print(%s)\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        5)
            expected_code=E2S30
            case_name=empty-arm
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match false {'
                printf '%s\n' '        true => {'
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        6)
            expected_code=E2S30
            case_name=two-expressions
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '%s\n' '        true => {'
                printf '            %s\n' "$value"
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 2))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
        7)
            expected_code=E2S25
            case_name=guard-only-true
            {
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let selected: Int = match true {'
                printf '%s\n' '        true if true => {'
                printf '            %s\n' "$value"
                printf '%s\n' '        },'
                printf '%s\n' '        false => {'
                printf '            %s\n' "$((value + 1))"
                printf '%s\n' '        },'
                printf '%s\n' '    }'
                printf '%s\n' '    print(selected)'
                printf '%s\n' '}'
            } >"$source"
            ;;
    esac

    set +e
    "$WORK/kofun-stage2" \
        "$source" \
        "$case_work/program.c" \
        "$case_work/program.ir" \
        "$case_work/program.tokens" \
        >"$case_work/normal.stdout" 2>"$case_work/normal.stderr"
    normal_status=$?
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-stage2-sanitized" \
        "$source" \
        "$case_work/program-sanitized.c" \
        "$case_work/program-sanitized.ir" \
        "$case_work/program-sanitized.tokens" \
        >"$case_work/sanitized.stdout" 2>"$case_work/sanitized.stderr"
    sanitized_status=$?
    set -e

    test "$normal_status" -eq 1 ||
        fail "case $case_index ($case_name): normal compiler returned $normal_status"
    test "$sanitized_status" -eq 1 ||
        fail "case $case_index ($case_name): sanitized compiler returned $sanitized_status"
    test ! -s "$case_work/normal.stderr" ||
        fail "case $case_index ($case_name): normal compiler wrote stderr"
    test ! -s "$case_work/sanitized.stderr" ||
        fail "case $case_index ($case_name): sanitized compiler wrote stderr"
    test ! -e "$case_work/program.c" ||
        fail "case $case_index ($case_name): normal compiler emitted C"
    test ! -e "$case_work/program-sanitized.c" ||
        fail "case $case_index ($case_name): sanitized compiler emitted C"
    cmp "$case_work/normal.stdout" "$case_work/sanitized.stdout" ||
        fail "case $case_index ($case_name): compiler diagnostics differ"
    observed_code=$(sed -n 's/^error\[\([^]]*\)\]:.*/\1/p' \
        "$case_work/normal.stdout")
    test "$observed_code" = "$expected_code" ||
        fail "case $case_index ($case_name): expected $expected_code, observed $observed_code"
    test -f "$case_work/program.ir" &&
        test -f "$case_work/program-sanitized.ir" ||
        fail "case $case_index ($case_name): missing IR artifact"
    test -f "$case_work/program.tokens" &&
        test -f "$case_work/program-sanitized.tokens" ||
        fail "case $case_index ($case_name): missing token artifact"
    cmp "$case_work/program.ir" "$case_work/program-sanitized.ir" ||
        fail "case $case_index ($case_name): IR artifacts differ"
    cmp "$case_work/program.tokens" "$case_work/program-sanitized.tokens" ||
        fail "case $case_index ($case_name): token artifacts differ"

    printf '%s\n' \
        "PASS invalid value match $case_index: $case_name -> $expected_code"
    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: invalid value-match fuzz rejected $CASES deterministic programs"
