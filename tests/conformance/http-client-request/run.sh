#!/usr/bin/env sh
# #1261. The deterministic HTTP/1.1 request serializer and scripted write
# cursor over the landed `HttpOrigin`, `Header`/`List[Header]`, and `Bytes`
# carriers.
#
# The bytes are not compared with a hand-written golden. They are compared with
# `tests/http/client-model`'s `serializeRequest` through its own result files,
# so the four model owners (#1261, #1262, #1263, #1264) cannot quietly grow four
# spellings of one request.
#
# Proved here:
#
#   1. GET, POST, and empty POST request bytes are the #1257 model's bytes;
#   2. a refused request writes zero bytes: bad header name, reserved framing
#      header, invalid field value, and a GET carrying a body;
#   3. every short-write boundary converges, a zero-progress write fails closed,
#      and the injected cancel/deadline/failure outcomes carry the model's
#      retry-safety fact;
#   4. the emitted C compiles at -O0 and -O2 under ASan/UBSan, and repeated
#      runs print the same bytes; and
#   5. both halves of the Stage 2 pair agree on outcome, emitted C, IR, tokens,
#      and scope HIR.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/http-client-request"
WORK=${KOFUN_HTTP_CLIENT_REQUEST_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}http-client-request"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: http client request: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the model and pair checks'
case $WORK in
    */http-client-request|*/http-client-request.*) ;;
    *) fail "work directory must end in http-client-request[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

"$COMPILER" --compile-outcome \
    "$CASES/serialize.kofun" \
    "$WORK/serialize.c" "$WORK/serialize.ir" "$WORK/serialize.tokens" \
    >"$WORK/serialize.build" 2>"$WORK/serialize.build.err" ||
    fail "serialize.kofun did not compile: $(head -n 1 "$WORK/serialize.build")"
test ! -s "$WORK/serialize.build.err" ||
    fail 'serialize.kofun wrote internal stderr'

for level in 0 2; do
    "$CC" -std=c11 "-O$level" -g -fsanitize=address,undefined -Wall -Wextra \
        -Werror -pedantic "$WORK/serialize.c" -o "$WORK/serialize.O$level" \
        2>"$WORK/serialize.cc.O$level" ||
        fail "the emitted C does not compile at -O$level"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/serialize.O$level" >"$WORK/serialize.O$level.out" 2>&1 ||
        fail "serialize did not run clean at -O$level"
done
cmp "$WORK/serialize.O0.out" "$WORK/serialize.O2.out" ||
    fail 'the -O0 and -O2 runs printed different bytes'
"$WORK/serialize.O2" >"$WORK/serialize.repeat" 2>&1 ||
    fail 'a repeated run exited non-zero'
cmp "$WORK/serialize.O0.out" "$WORK/serialize.repeat" ||
    fail 'a repeated run printed different bytes'

node "$CASES/check.mjs" "$WORK/serialize.O2.out" "$ROOT" ||
    fail 'the serializer did not match the reference model'

node "$ROOT/tests/conformance/record-list/pair.mjs" "$COMPILER" "$WORK/pair" \
    "$CASES/serialize.kofun" ||
    fail 'the two halves disagree'

printf '%s\n' 'PASS: GET/POST/empty-POST bytes match the #1257 model; refusals write nothing; short writes converge; both halves agree'
