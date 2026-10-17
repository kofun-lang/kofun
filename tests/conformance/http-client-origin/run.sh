#!/usr/bin/env sh
# #1696. The HTTP origin carrier: `HttpOrigin` = {host: Bytes, target: Bytes,
# port: Int} and its checked construction, `stage2_http_origin(origin)`,
# preceding the HTTP error and header children of #1258.
#
# The carrier is built by its own record constructor; the builtin validates it
# in place and fails closed with a named runtime diagnostic, exactly as the
# R038 append validates a full list. Per #1258's Q2 the admitted sets are the
# #1257 oracle's: host 1..255 visible-ASCII bytes without a comma, target an
# origin-form `/`-prefixed path of 1..2048 visible-ASCII bytes, and port `-1`
# (absent) or `0..65535`.
#
# What is proved, one block per acceptance line:
#
#   1. a valid origin constructs, validates, and reads host/target/port back,
#      and `-1` is an accepted absent-port sentinel;
#   2. a host with a comma and a host over 255 bytes each refuse R039, a target
#      without a leading slash and a target over 2048 bytes each refuse R040,
#      and a port over 65535 refuses R041, all with exit 1 and no output after;
#   3. a non-record and a record of the wrong shape are refused E2S15 before
#      any C;
#   4. `CoreLimits` and the caller limit map are values a program reads;
#   5. both halves of the pair agree on outcome, emitted C, and scope HIR.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/http-client-origin"
WORK=${KOFUN_HTTP_CLIENT_ORIGIN_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-origin"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: http client origin: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */http-client-origin|*/http-client-origin.*) ;;
    *) fail "work directory must end in http-client-origin[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

build() {
    program=$1
    source=$2
    "$COMPILER" --compile-outcome \
        "$source" "$program.c" "$program.ir" "$program.tokens" \
        >"$program.build.stdout" 2>"$program.build.stderr" ||
        fail "$(basename "$source") did not compile: $(head -n 1 "$program.build.stdout")"
    if test -s "$program.build.stderr"; then
        fail "$(basename "$source") wrote internal stderr"
    fi
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$program.c" -o "$program" 2>"$program.cc" ||
        fail "$(basename "$source") emitted C that does not compile: $(head -n 1 "$program.cc")"
}

expect_stdout() {
    stem=$1
    shift
    printf '%s\n' "$@" >"$WORK/$stem.expected"
    "$WORK/$stem" >"$WORK/$stem.stdout" ||
        fail "$stem exited non-zero"
    if ! cmp -s "$WORK/$stem.expected" "$WORK/$stem.stdout"; then
        diff "$WORK/$stem.expected" "$WORK/$stem.stdout" >&2 || true
        fail "$stem printed the wrong output"
    fi
}

# 1. Construction, validation, read-back, and the absent-port sentinel.
build "$WORK/construct" "$CASES/construct.kofun"
grep -Fq 'kofun_http_origin_check(&(k_b2).f_host, &(k_b2).f_target, (k_b2).f_port)' \
    "$WORK/construct.c" ||
    fail 'the checked construction did not lower to the origin validator'
grep -Fq 'error[R039]' "$WORK/construct.c" ||
    fail 'the origin prelude does not carry the R039 refusal'
expect_stdout construct 443 11 /index.html
build "$WORK/absent_port" "$CASES/absent_port.kofun"
expect_stdout absent_port -1

# 2. Runtime refusals, one per admitted-set clause, with no output after.
refuse_runtime() {
    stem=$1
    code=$2
    build "$WORK/$stem" "$CASES/$stem.kofun"
    status=0
    "$WORK/$stem" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" || status=$?
    test "$status" -eq 1 ||
        fail "$stem exited $status, not 1"
    if test -s "$WORK/$stem.stdout"; then
        fail "$stem printed after the $code refusal"
    fi
    cmp -s "$CASES/$stem.stderr" "$WORK/$stem.stderr" ||
        fail "$stem did not report $code: $(head -n 1 "$WORK/$stem.stderr")"
}
refuse_runtime host_comma_refused R039
refuse_runtime host_over_bound R039
refuse_runtime target_no_slash_refused R040
refuse_runtime target_over_bound R040
refuse_runtime port_out_of_range_refused R041

# 3. Compile-time refusals, with no C emitted.
refuse_compile() {
    stem=$1
    code=$2
    status=0
    "$COMPILER" --compile-outcome \
        "$CASES/$stem.kofun" "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" \
        >"$WORK/$stem.out" 2>"$WORK/$stem.err" || status=$?
    test "$status" -ne 0 || fail "$stem was accepted"
    grep -Fq "error[$code]" "$WORK/$stem.out" ||
        fail "$stem was not refused $code: $(head -n 1 "$WORK/$stem.out")"
    if test -e "$WORK/$stem.c"; then
        fail "$stem emitted C despite the refusal"
    fi
}
refuse_compile not_record_refused E2S15
refuse_compile wrong_shape_refused E2S15

# 4. CoreLimits and the caller limit map.
build "$WORK/limits" "$CASES/limits.kofun"
expect_stdout limits 65536 128 8388608 67108864

# 5. Both halves agree.
node "$ROOT/tests/conformance/record-list/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/construct.kofun" \
    "$CASES/absent_port.kofun" \
    "$CASES/host_comma_refused.kofun" \
    "$CASES/host_over_bound.kofun" \
    "$CASES/target_no_slash_refused.kofun" \
    "$CASES/target_over_bound.kofun" \
    "$CASES/port_out_of_range_refused.kofun" \
    "$CASES/not_record_refused.kofun" \
    "$CASES/wrong_shape_refused.kofun" \
    "$CASES/limits.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: HttpOrigin constructs with checked host/target/port bounds, refuses R039/R040/R041, reads CoreLimits, and both halves agree'
