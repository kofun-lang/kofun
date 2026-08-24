#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_SELFHOST_HIR_IDENTIFIERS_WORK:-"$ROOT/build/selfhost-hir-identifiers"}
CC=${CC:-cc}

fail() {
    printf '%s\n' "FAIL: selfhost HIR identifiers: $*" >&2
    exit 1
}

case $WORK in
    */selfhost-hir-identifiers|*/selfhost-hir-identifiers.*) ;;
    *) fail "work directory must end in selfhost-hir-identifiers[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$ROOT"

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    bootstrap/stage2/compiler.c -o "$WORK/stage2"

accepted=bootstrap/selfhost/frontend/accept_long_identifiers.kofun
accepted_digest=$("$ROOT/bin/kofun-digest" "$accepted" | awk '{ print $1 }')
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/stage2" --emit-selfhost-hir "$accepted" \
    "$WORK/accepted.hir" "$accepted_digest" >"$WORK/accepted.stdout" \
    2>"$WORK/accepted.stderr" || fail 'the long-name document was refused'
test ! -s "$WORK/accepted.stdout" || fail 'accepted source wrote diagnostics'
test ! -s "$WORK/accepted.stderr" || fail 'accepted source tripped a sanitizer'
cmp bootstrap/selfhost/frontend/accept_long_identifiers.hir \
    "$WORK/accepted.hir" || fail 'accepted long-name evidence differs'

# Under LC_ALL=C awk length is byte length. Every emitted source-backed name
# must cover exactly the same bytes as its recorded half-open span.
LC_ALL=C awk -F '|' '
    $1 == "symbol" && ($3 == "function" || $3 == "local") {
        if (length($4) != $7 - $6) exit 1
        if ($3 == "function" && length($4) == 255) long_function = 1
        if ($3 == "local" && length($4) == 64) local64 += 1
        if ($3 == "local" && length($4) == 65) local65 = 1
    }
    $1 == "binding" && $4 >= 0 && $5 != "main" {
        if (length($5) != $8 - $7) exit 1
    }
    END { exit !(long_function && local64 >= 2 && local65) }
' "$WORK/accepted.hir" ||
    fail 'name bytes and source spans disagree at the 64/255 boundaries'

rejected=bootstrap/selfhost/frontend/reject_long_prefix.kofun
rejected_digest=$("$ROOT/bin/kofun-digest" "$rejected" | awk '{ print $1 }')
set +e
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/stage2" --emit-selfhost-hir "$rejected" \
    "$WORK/rejected.hir" "$rejected_digest" >"$WORK/rejected.stdout" \
    2>"$WORK/rejected.stderr"
rejected_status=$?
set -e
test "$rejected_status" -eq 1 || fail "prefix case exited $rejected_status"
test ! -s "$WORK/rejected.stderr" || fail 'prefix case tripped a sanitizer'
cmp bootstrap/selfhost/frontend/reject_long_prefix.hir \
    "$WORK/rejected.hir" || fail 'prefix rejection evidence differs'
grep -F 'error[E2S35]: unknown lexical binding' "$WORK/rejected.stdout" \
    >/dev/null || fail 'the 63-byte prefix did not produce E2S35'

long_function=$(sed -n 's/^fn \([^ (]*\).*/\1/p' "$accepted" | head -1)
printf 'fn %s() -> Int {\n    return 1\n}\nfn %s() -> Int {\n    return 2\n}\nfn main() {\n    print("x")\n}\n' \
    "$long_function" "$long_function" >"$WORK/duplicate.kofun"
duplicate_digest=$("$ROOT/bin/kofun-digest" "$WORK/duplicate.kofun" |
    awk '{ print $1 }')
set +e
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/stage2" --emit-selfhost-hir "$WORK/duplicate.kofun" \
    "$WORK/duplicate.hir" "$duplicate_digest" \
    >"$WORK/duplicate.stdout" 2>"$WORK/duplicate.stderr"
duplicate_status=$?
set -e
test "$duplicate_status" -eq 1 ||
    fail "duplicate long function exited $duplicate_status"
test ! -s "$WORK/duplicate.stderr" ||
    fail 'duplicate long function tripped a sanitizer'
grep -F 'error[E2S16]: duplicate Core function' "$WORK/duplicate.stdout" \
    >/dev/null || fail 'the exact duplicate long function did not produce E2S16'

printf '%s\n' \
    'PASS: 64/65-byte locals and a 255-byte function retain complete spellings and exact spans' \
    'PASS: names sharing 63 bytes remain distinct and the 63-byte prefix is unresolved' \
    'PASS: an exact duplicate 255-byte function is E2S16 under ASan/UBSan with no leak'
