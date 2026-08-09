#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_ENUM_MATCH_FUZZ_WORK:-"$ROOT/build/enum-match-fuzz"}
CASES=${KOFUN_ENUM_MATCH_FUZZ_CASES:-32}
CC=${CC:-cc}
. "$ROOT/tests/fuzz/semantic_protocol.sh"
. "$ROOT/bootstrap/stage2/build.sh"

case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "enum-match fuzz: case count must be positive" >&2
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

compare_optional_artifact() {
    left=$1
    right=$2
    label=$3
    if test -e "$left" || test -e "$right"; then
        test -f "$left" && test -f "$right" ||
            fail "$label exists for only one compiler"
        cmp "$left" "$right" ||
            fail "$label differs between compilers"
    fi
}

run_valid() {
    case_work=$1
    source=$2
    expected=$3
    label=$4

    "$WORK/kofun-stage2" \
        "$source" \
        "$case_work/program.c" \
        "$case_work/program.ir" \
        "$case_work/program.tokens" \
        >"$case_work/compiler.stdout" 2>"$case_work/compiler.stderr"
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-stage2-sanitized" \
        "$source" \
        "$case_work/program-sanitized.c" \
        "$case_work/program-sanitized.ir" \
        "$case_work/program-sanitized.tokens" \
        >"$case_work/compiler-sanitized.stdout" \
        2>"$case_work/compiler-sanitized.stderr"

    test ! -s "$case_work/compiler.stderr" ||
        fail "$label: normal compiler wrote stderr"
    test ! -s "$case_work/compiler-sanitized.stderr" ||
        fail "$label: sanitized compiler wrote stderr"
    cmp "$case_work/program.c" "$case_work/program-sanitized.c" ||
        fail "$label: C artifacts differ"
    cmp "$case_work/program.ir" "$case_work/program-sanitized.ir" ||
        fail "$label: IR artifacts differ"
    cmp "$case_work/program.tokens" "$case_work/program-sanitized.tokens" ||
        fail "$label: token artifacts differ"

    "$CC" -std=c11 -O2 -Wall -Wextra -Werror \
        "$case_work/program.c" -o "$case_work/program"
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        "$case_work/program.c" -o "$case_work/program-sanitized"

    set +e
    "$case_work/program" \
        >"$case_work/actual.stdout" 2>"$case_work/actual.stderr"
    actual_status=$?
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$case_work/program-sanitized" \
        >"$case_work/actual-sanitized.stdout" \
        2>"$case_work/actual-sanitized.stderr"
    sanitized_status=$?
    set -e
    : >"$case_work/expected.stderr"
    semantic_wrap_observation_pair \
        enum-match "$case_work" enum-match-shell-model stage2-c11 \
        "$expected" "$case_work/expected.stderr" 0 \
        "$case_work/actual.stdout" "$case_work/actual.stderr" "$actual_status" ||
        fail "$label: $KOFUN_SEMANTIC_MISMATCH"
    semantic_wrap_observation_pair \
        enum-match "$case_work" enum-match-shell-model stage2-c11-sanitized \
        "$expected" "$case_work/expected.stderr" 0 \
        "$case_work/actual-sanitized.stdout" \
        "$case_work/actual-sanitized.stderr" "$sanitized_status" ||
        fail "$label sanitized runtime: $KOFUN_SEMANTIC_MISMATCH"
}

run_invalid() {
    case_work=$1
    source=$2
    expected_code=$3
    label=$4

    set +e
    "$WORK/kofun-stage2" \
        "$source" \
        "$case_work/invalid.c" \
        "$case_work/invalid.ir" \
        "$case_work/invalid.tokens" \
        >"$case_work/invalid.stdout" 2>"$case_work/invalid.stderr"
    normal_status=$?
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/kofun-stage2-sanitized" \
        "$source" \
        "$case_work/invalid-sanitized.c" \
        "$case_work/invalid-sanitized.ir" \
        "$case_work/invalid-sanitized.tokens" \
        >"$case_work/invalid-sanitized.stdout" \
        2>"$case_work/invalid-sanitized.stderr"
    sanitized_status=$?
    set -e

    test "$normal_status" -eq 1 ||
        fail "$label: normal compiler returned $normal_status"
    test "$sanitized_status" -eq 1 ||
        fail "$label: sanitized compiler returned $sanitized_status"
    test ! -s "$case_work/invalid.stderr" ||
        fail "$label: normal compiler wrote stderr"
    test ! -s "$case_work/invalid-sanitized.stderr" ||
        fail "$label: sanitized compiler wrote stderr"
    test ! -e "$case_work/invalid.c" ||
        fail "$label: normal compiler emitted C"
    test ! -e "$case_work/invalid-sanitized.c" ||
        fail "$label: sanitized compiler emitted C"
    cmp "$case_work/invalid.stdout" "$case_work/invalid-sanitized.stdout" ||
        fail "$label: diagnostics differ between compilers"
    observed_code=$(sed -n 's/^error\[\([^]]*\)\]:.*/\1/p' \
        "$case_work/invalid.stdout")
    test "$observed_code" = "$expected_code" ||
        fail "$label: expected $expected_code, observed $observed_code"
    compare_optional_artifact \
        "$case_work/invalid.ir" \
        "$case_work/invalid-sanitized.ir" \
        "$label IR artifact"
    compare_optional_artifact \
        "$case_work/invalid.tokens" \
        "$case_work/invalid-sanitized.tokens" \
        "$label token artifact"
}

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_ENUM_MATCH_FUZZ_SEED:-1516993677}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "enum_match fuzz: KOFUN_ENUM_MATCH_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "enum_match fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    next_random
    selected_index=$((seed % 3))
    next_random
    result=$((seed % 10000 + 100))
    next_random
    first_probe=$((seed % 10000 + 20100))
    second_probe=$((first_probe + 1))

    case $selected_index in
        0)
            selected=Red
            nonmatching=Green
            ;;
        1)
            selected=Green
            nonmatching=Blue
            ;;
        2)
            selected=Blue
            nonmatching=Red
            ;;
    esac

    case_work="$WORK/case-$case_index"
    mkdir -p "$case_work"
    source="$case_work/valid.kofun"
    expected="$case_work/expected.stdout"
    if test "$case_index" -eq 0; then
        valid_variant=4
    else
        valid_variant=$((case_index % 4))
    fi
    case $valid_variant in
        0)
            valid_name=constructor-selection
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' ''
                printf '%s\n' 'fn main() {'
                printf '    let signal: Signal = %s\n' "$selected"
                printf '%s\n' '    match signal {'
                printf '        Red => { print(%s) },\n' "$((result + 10))"
                printf '        Green => { print(%s) },\n' "$((result + 20))"
                printf '        Blue => { print(%s) },\n' "$((result + 30))"
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$source"
            case $selected in
                Red) expected_value=$((result + 10)) ;;
                Green) expected_value=$((result + 20)) ;;
                Blue) expected_value=$((result + 30)) ;;
            esac
            printf '%s\n' "$expected_value" >"$expected"
            ;;
        1)
            valid_name=ordered-guards
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' ''
                printf '%s\n' 'fn probe(value: Int) -> Int {'
                printf '%s\n' '    print(value)'
                printf '%s\n' '    return value'
                printf '%s\n' '}'
                printf '%s\n' ''
                printf '%s\n' 'fn main() {'
                printf '    let signal: Signal = %s\n' "$selected"
                printf '%s\n' '    match signal {'
                printf '        %s if 1 // 0 == 0 => { print(90001) },\n' \
                    "$nonmatching"
                printf '        %s if probe(%s) == %s => { print(90002) },\n' \
                    "$selected" "$first_probe" "$second_probe"
                printf '        %s if probe(%s) == %s => { print(%s) },\n' \
                    "$selected" "$second_probe" "$second_probe" "$result"
                printf '        %s if 1 // 0 == 0 => { print(90003) },\n' \
                    "$selected"
                printf '%s\n' '        _ => { print(90004) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$source"
            {
                printf '%s\n' "$first_probe"
                printf '%s\n' "$second_probe"
                printf '%s\n' "$result"
            } >"$expected"
            ;;
        2)
            valid_name=wildcard-fallback
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' ''
                printf '%s\n' 'fn main() {'
                printf '    let signal: Signal = %s\n' "$selected"
                printf '%s\n' '    match signal {'
                printf '        %s => { print(90005) },\n' "$nonmatching"
                printf '        _ => { print(%s) },\n' "$result"
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$source"
            printf '%s\n' "$result" >"$expected"
            ;;
        3)
            valid_name=post-selection-guard
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' ''
                printf '%s\n' 'fn main() {'
                printf '    let signal: Signal = %s\n' "$selected"
                printf '%s\n' '    match signal {'
                printf '        %s if true => { print(%s) },\n' \
                    "$selected" "$result"
                printf '%s\n' '        _ if 1 // 0 == 0 => { print(90006) },'
                printf '%s\n' '        _ => { print(90007) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$source"
            printf '%s\n' "$result" >"$expected"
            ;;
        4)
            valid_name=identifier-limit-256
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' ''
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Red'
                printf '%s\n' '    let other: Signal = Green'
                match_index=0
                while test "$match_index" -lt 126; do
                    printf '%s\n' '    match signal { _ => { } }'
                    match_index=$((match_index + 1))
                done
                printf '%s\n' '    match other { _ => { } }'
                printf '    print(%s)\n' "$result"
                printf '%s\n' '}'
            } >"$source"
            printf '%s\n' "$result" >"$expected"
            ;;
    esac

    run_valid \
        "$case_work" "$source" "$expected" \
        "case $case_index valid $valid_name"

    invalid="$case_work/invalid.kofun"
    invalid_variant=$((case_index % 19))
    case $invalid_variant in
        0)
            invalid_name=non-exhaustive
            expected_code=E2S25
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Red'
                printf '%s\n' '    match signal {'
                printf '%s\n' '        Red => { print(1) },'
                printf '%s\n' '        Green => { print(2) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        1)
            invalid_name=duplicate-pattern
            expected_code=E2S26
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Red'
                printf '%s\n' '    match signal {'
                printf '%s\n' '        Red => { print(1) },'
                printf '%s\n' '        Red => { print(2) },'
                printf '%s\n' '        Green => { print(3) },'
                printf '%s\n' '        Blue => { print(4) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        2)
            invalid_name=after-wildcard
            expected_code=E2S26
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Green'
                printf '%s\n' '    match signal {'
                printf '%s\n' '        _ => { print(1) },'
                printf '%s\n' '        Blue => { print(2) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        3)
            invalid_name=malformed-declaration
            expected_code=E2S31
            {
                printf '%s\n' 'type Signal | Red | Green | Blue'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        4)
            invalid_name=duplicate-constructor-declaration
            expected_code=E2S31
            {
                printf '%s\n' 'type Signal = | Red | Green | Red'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        5)
            invalid_name=duplicate-type-declaration
            expected_code=E2S31
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'type Signal = | Up | Down'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        6)
            invalid_name=constructor-namespace-collision
            expected_code=E2S31
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'type Shade = | Light | Red | Dark'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        7)
            invalid_name=unknown-type
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Missing = Red'
                printf '%s\n' '    print(0)'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        8)
            invalid_name=unknown-constructor
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Yellow'
                printf '%s\n' '    print(0)'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        9)
            invalid_name=constructor-type-mismatch
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'type Color = | Cyan | Magenta | Yellow'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Cyan'
                printf '%s\n' '    print(0)'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        10)
            invalid_name=unknown-pattern-constructor
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Blue'
                printf '%s\n' '    match signal {'
                printf '%s\n' '        Red => { print(1) },'
                printf '%s\n' '        Green => { print(2) },'
                printf '%s\n' '        Yellow => { print(3) },'
                printf '%s\n' '        Blue => { print(4) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        11)
            invalid_name=invalid-guard
            expected_code=E2S29
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Red'
                printf '%s\n' '    match signal {'
                printf '%s\n' '        Red if 1 + 2 => { print(1) },'
                printf '%s\n' '        _ => { print(2) },'
                printf '%s\n' '    }'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        12)
            invalid_name=constructor-limit
            expected_code=E2S31
            {
                printf '%s' 'type Large ='
                constructor_index=0
                while test "$constructor_index" -lt 65; do
                    printf ' | C%s' "$constructor_index"
                    constructor_index=$((constructor_index + 1))
                done
                printf '\n%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        13)
            invalid_name=type-limit
            expected_code=E2S31
            {
                type_index=0
                while test "$type_index" -lt 33; do
                    printf 'type T%s = | C%s\n' "$type_index" "$type_index"
                    type_index=$((type_index + 1))
                done
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        14)
            invalid_name=builtin-type-namespace-collision
            expected_code=E2S31
            {
                printf '%s\n' 'type Int = | X'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        15)
            invalid_name=wildcard-constructor-collision
            expected_code=E2S31
            {
                printf '%s\n' 'type Signal = | _ | Red'
                printf '%s\n' 'fn main() { print(0) }'
            } >"$invalid"
            ;;
        16)
            invalid_name=enum-binding-tag-leak
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Blue'
                printf '%s\n' '    print(signal)'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        17)
            invalid_name=constructor-in-int-expression
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let leaked = Red'
                printf '%s\n' '    print(leaked)'
                printf '%s\n' '}'
            } >"$invalid"
            ;;
        18)
            invalid_name=identifier-limit-257
            expected_code=E2S32
            {
                printf '%s\n' 'type Signal = | Red | Green | Blue'
                printf '%s\n' 'fn main() {'
                printf '%s\n' '    let signal: Signal = Red'
                printf '%s\n' '    let other: Signal = Green'
                printf '%s\n' '    let overflow: Signal = Blue'
                match_index=0
                while test "$match_index" -lt 127; do
                    printf '%s\n' '    match signal { _ => { } }'
                    match_index=$((match_index + 1))
                done
                printf '%s\n' '}'
            } >"$invalid"
            ;;
    esac

    run_invalid \
        "$case_work" "$invalid" "$expected_code" \
        "case $case_index invalid $invalid_name"

    printf '%s\n' \
        "PASS enum match $case_index: $valid_name / $invalid_name -> $expected_code"
    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: enum-match fuzz checked $CASES valid and $CASES invalid programs"

# The focused structural lane catches a return to per-arm C dispatch. Keeping
# it behind the ordinary enum fuzz task makes the codegen contract part of the
# repository gate without overlapping the shared Taskfile.yml ownership.
sh "$ROOT/tests/conformance/codegen/dense-enum-dispatch/run.sh"
