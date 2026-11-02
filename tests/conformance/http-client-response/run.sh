#!/usr/bin/env sh
# #1262. The bounded HTTP/1.1 response head and framing-plan decoder.
#
# The bytes and the offsets are compared with `tests/http/client-model`'s own
# result documents, not with a hand-written golden.
#
# Proved here:
#
#   1. content-length, no-body, chunked, and close-delimited heads produce the
#      model's status, ordered headers, body, counters, and reuse eligibility;
#   2. fifteen protocol, limit, and premature-close refusals carry the model's
#      kind and exact offset;
#   3. every prefix of a head is incomplete until the whole message is present,
#      and exactly one terminal result is printed, equal to the whole run;
#   4. the emitted C compiles at -O0 and -O2 under ASan/UBSan, and repeated runs
#      print the same bytes; and
#   5. both halves of the Stage 2 pair agree on outcome, emitted C, IR, tokens,
#      and scope HIR.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/http-client-response"
WORK=${KOFUN_HTTP_CLIENT_RESPONSE_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-response"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: http client response: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the model and pair checks'
case $WORK in
    */http-client-response|*/http-client-response.*) ;;
    *) fail "work directory must end in http-client-response[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

"$COMPILER" --compile-outcome \
    "$CASES/decode.kofun" \
    "$WORK/decode.c" "$WORK/decode.ir" "$WORK/decode.tokens" \
    >"$WORK/decode.build" 2>"$WORK/decode.build.err" ||
    fail "decode.kofun did not compile: $(head -n 1 "$WORK/decode.build")"
test ! -s "$WORK/decode.build.err" ||
    fail 'decode.kofun wrote internal stderr'

for level in 0 2; do
    "$CC" -std=c11 "-O$level" -g -fsanitize=address,undefined -Wall -Wextra \
        -Werror -pedantic "$WORK/decode.c" -o "$WORK/decode.O$level" \
        2>"$WORK/decode.cc.O$level" ||
        fail "the emitted C does not compile at -O$level"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/decode.O$level" >"$WORK/decode.O$level.out" 2>&1 ||
        fail "decode did not run clean at -O$level"
done
cmp "$WORK/decode.O0.out" "$WORK/decode.O2.out" ||
    fail 'the -O0 and -O2 runs printed different bytes'
"$WORK/decode.O2" >"$WORK/decode.repeat" 2>&1 ||
    fail 'a repeated run exited non-zero'
cmp "$WORK/decode.O0.out" "$WORK/decode.repeat" ||
    fail 'a repeated run printed different bytes'

node "$CASES/check.mjs" "$WORK/decode.O2.out" "$ROOT" ||
    fail 'the decoder did not match the reference model'

node "$ROOT/tests/conformance/record-list/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/decode.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: four framing plans and fifteen refusals match the #1257 model; fragmentation converges; both halves agree'
