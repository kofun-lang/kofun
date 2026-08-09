#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
CC=${CC:-cc}
NODE=${NODE:-node}
CASES=${KOFUN_HM_LEVELS_CASES:-128}
SEED=${KOFUN_HM_LEVELS_SEED:-5572026}
case $SEED in
    ''|*[!0-9]*)
        printf '%s\n' "hm_levels fuzz: KOFUN_HM_LEVELS_SEED must be a non-negative integer" >&2
        exit 2
        ;;
esac
printf '%s\n' "hm_levels fuzz: seed=$SEED"
WORK=${KOFUN_HM_LEVELS_FUZZ_WORK:-"$ROOT/build/hm-levels-fuzz"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

validate_work_path() {
    case $WORK in
        "$ROOT/build/hm-levels-fuzz") return ;;
        "$ROOT/build/hm-levels-fuzz."*)
            suffix=${WORK#"$ROOT/build/hm-levels-fuzz."}
            case $suffix in
                ''|*[!A-Za-z0-9_-]*) ;;
                *) return ;;
            esac
            ;;
    esac
    fail "work directory must be $ROOT/build/hm-levels-fuzz or use a safe suffix: $WORK"
}

case $CASES in
    ''|*[!0-9]*) fail "KOFUN_HM_LEVELS_CASES must be an integer: $CASES" ;;
esac
test "$CASES" -ge 1 && test "$CASES" -le 512 ||
    fail "KOFUN_HM_LEVELS_CASES must be between 1 and 512: $CASES"
validate_work_path
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v "$NODE" >/dev/null 2>&1 || fail 'Node.js is required for the independent oracle'

rm -rf "$WORK"
mkdir -p "$WORK/first" "$WORK/second" "$WORK/results"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/hm_levels_frontend.c" \
    -o "$WORK/kofun-hm-levels-frontend"

"$NODE" "$ROOT/tests/fuzz/hm_levels_oracle.mjs" \
    "$WORK/first" "$CASES" "$SEED" >"$WORK/oracle.first"
"$NODE" "$ROOT/tests/fuzz/hm_levels_oracle.mjs" \
    "$WORK/second" "$CASES" "$SEED" >"$WORK/oracle.second"
cmp "$WORK/oracle.first" "$WORK/oracle.second" ||
    fail 'oracle summary is not deterministic'
diff -ru "$WORK/first" "$WORK/second" >/dev/null ||
    fail 'oracle corpus is not deterministic'

accepted=0
rejected=0
while IFS='	' read -r file expected expected_type; do
    test -n "$file" || continue
    stem=${file%.kofun}
    set +e
    "$WORK/kofun-hm-levels-frontend" "$WORK/first/$file" \
        "$WORK/results/$stem.ir" "$WORK/results/$stem.tokens" \
        >"$WORK/results/$stem.stdout" 2>"$WORK/results/$stem.stderr"
    status=$?
    set -e
    test ! -s "$WORK/results/$stem.stderr" ||
        fail "$file wrote internal stderr"
    case $expected in
        accepted)
            test "$status" -eq 0 ||
                fail "$file: oracle accepted but frontend exited $status"
            test ! -s "$WORK/results/$stem.stdout" ||
                fail "$file: accepted frontend wrote stdout"
            actual_type=$(sed -n \
                's/^result|type=\(.*\)|span=[0-9][0-9]*\.\.[0-9][0-9]*$/\1/p' \
                "$WORK/results/$stem.ir")
            test -n "$actual_type" || fail "$file: result type is missing"
            test "$actual_type" = "$expected_type" ||
                fail "$file: oracle type $expected_type, frontend type $actual_type"
            sed -n \
                's/^binding|binding-id=[^|]*|name=\([^|]*\)|role=let|scheme=\(.*\)|span=[0-9][0-9]*\.\.[0-9][0-9]*$/\1|\2/p' \
                "$WORK/results/$stem.ir" | sort \
                >"$WORK/results/$stem.schemes"
            cmp "$WORK/first/$file.schemes" "$WORK/results/$stem.schemes" ||
                fail "$file: oracle and frontend canonical schemes differ"
            accepted=$((accepted + 1))
            ;;
        rejected)
            test "$status" -eq 1 ||
                fail "$file: oracle rejected but frontend exited $status"
            grep '^error\[HML00[1234]\]:' "$WORK/results/$stem.stdout" >/dev/null ||
                fail "$file: rejection was not a typing/binding diagnostic"
            test ! -e "$WORK/results/$stem.ir" ||
                fail "$file: rejected frontend emitted typed IR"
            test ! -e "$WORK/results/$stem.tokens" ||
                fail "$file: rejected frontend emitted tokens"
            rejected=$((rejected + 1))
            ;;
        *) fail "$file: unknown oracle status $expected" ;;
    esac
done <"$WORK/first/expected.tsv"

test "$accepted" -gt 0 || fail 'generated corpus has no accepted cases'
test "$rejected" -gt 0 || fail 'generated corpus has no rejected cases'
test $((accepted + rejected)) -eq "$CASES" ||
    fail "ran $((accepted + rejected)) cases instead of $CASES"

printf '%s\n' \
    "PASS: independent substitution-based oracle agrees on $CASES generated terms" \
    "PASS: generated corpus is deterministic ($accepted accepted, $rejected rejected; seed $SEED)"
