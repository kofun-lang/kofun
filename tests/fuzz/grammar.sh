#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_GRAMMAR_FUZZ_WORK:-"$ROOT/build/grammar-fuzz"}
CASES=${KOFUN_GRAMMAR_FUZZ_CASES:-128}
. "$ROOT/bootstrap/stage2/build.sh"

command -v timeout >/dev/null 2>&1 || {
    printf '%s\n' "grammar fuzz: timeout is required" >&2
    exit 1
}
case $CASES in
    ''|*[!0-9]*|0)
        printf '%s\n' "grammar fuzz: case count must be positive" >&2
        exit 2
        ;;
esac

rm -rf "$WORK"
mkdir -p "$WORK"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

# The default is the seed this corpus was recorded with, so `task verify`
# generates the same programs it always has. It is overridable so a lane
# that runs more than once can explore more than one input set; a fixed
# seed means accumulated machine time buys no coverage.
seed=${KOFUN_GRAMMAR_FUZZ_SEED:-12648430}
case $seed in
    ''|*[!0-9]*)
        printf '%s\n' "grammar fuzz: KOFUN_GRAMMAR_FUZZ_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "grammar fuzz: seed=$seed"
next_random() {
    seed=$(((seed * 1103515245 + 12345) % 2147483648))
}

token_for() {
    case $1 in
        0) printf '%s' 'fn' ;;
        1) printf '%s' 'main' ;;
        2) printf '%s' '(' ;;
        3) printf '%s' ')' ;;
        4) printf '%s' '{' ;;
        5) printf '%s' '}' ;;
        6) printf '%s' 'let' ;;
        7) printf '%s' 'value' ;;
        8) printf '%s' '=' ;;
        9) printf '%s' 'print' ;;
        10) printf '%s' 'return' ;;
        11) printf '%s' '0' ;;
        12) printf '%s' '42' ;;
        13) printf '%s' '+' ;;
        14) printf '%s' '-' ;;
        15) printf '%s' '*' ;;
        16) printf '%s' '//' ;;
        17) printf '%s' '%' ;;
        18) printf '%s' ',' ;;
        19) printf '%s' ':' ;;
        20) printf '%s' 'Int' ;;
        21) printf '%s' '"text"' ;;
        22) printf '%s' '"' ;;
        23) printf '%s' '#' ;;
        24) printf '%s' 'if' ;;
        25) printf '%s' 'else' ;;
        26) printf '%s' 'true' ;;
        27) printf '%s' 'false' ;;
        28) printf '%s' '<' ;;
        29) printf '%s' '==' ;;
        30) printf '%s' 'unexpected-token' ;;
        31) printf '%s' 'match' ;;
        32) printf '%s' '=>' ;;
        33) printf '%s' '_' ;;
        34) printf '%s' '|' ;;
        35) printf '%s' 'Present' ;;
        36) printf '%s' 'null' ;;
        37) printf '%s' '..' ;;
        38) printf '%s' '[' ;;
        *) printf '%s' ']' ;;
    esac
}

case_index=0
while test "$case_index" -lt "$CASES"; do
    source="$WORK/case-$case_index.kofun"
    next_random
    token_count=$((seed % 80 + 1))
    token_index=0
    : >"$source"
    while test "$token_index" -lt "$token_count"; do
        next_random
        token=$(token_for $((seed % 40)))
        printf '%s ' "$token" >>"$source"
        token_index=$((token_index + 1))
    done
    printf '\n' >>"$source"

    set +e
    timeout 2 "$WORK/kofun-stage2" \
        "$source" \
        "$WORK/case-$case_index.out.kofun" \
        "$WORK/case-$case_index.ir" \
        "$WORK/case-$case_index.tokens" \
        >"$WORK/case-$case_index.stdout" \
        2>"$WORK/case-$case_index.stderr"
    status=$?
    set -e
    case $status in
        0|1) ;;
        124|137)
            printf '%s\n' \
                "grammar fuzz: case $case_index timed out" >&2
            exit 1
            ;;
        *)
            printf '%s\n' \
                "grammar fuzz: case $case_index crashed with status $status" >&2
            exit 1
            ;;
    esac
    case_index=$((case_index + 1))
done

printf '%s\n' \
    "PASS: grammar fuzz completed $CASES deterministic malformed/valid inputs"
