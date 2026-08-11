#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_UNICODE_WORK:-"$ROOT/build/unicode"}
CC=${CC:-cc}
. "$ROOT/bootstrap/stage2/build.sh"
ASSERT_CONTEXT='unicode'
. "$ROOT/tests/assertions/assert.sh"

mkdir -p "$WORK"

(
    cd "$ROOT/unicode"
    "$ROOT/bin/kofun-digest" -c SHA256SUMS
)

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/tests/unicode/unicode_test.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    -o "$WORK/unicode-test"

"$WORK/unicode-test"

KOFUN_CONFUSABLE_VISIBLE_SET_WORK="$WORK/confusable-visible-set" \
    sh "$ROOT/tests/conformance/modules/confusable-visible-set/run.sh"

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

"$WORK/kofun-stage2" \
    "$ROOT/tests/unicode/stage2_identifiers.kofun" \
    "$WORK/stage2-identifiers.c" \
    "$WORK/stage2-identifiers.ir" \
    "$WORK/stage2-identifiers.tokens" >/dev/null

assert_grep "stage2-identifiers.ir" \
    -F 'function|main|0|' "$WORK/stage2-identifiers.ir"
assert_grep "stage2-identifiers.tokens" \
    -F 'identifier|' "$WORK/stage2-identifiers.tokens"
assert_grep "stage2-identifiers.c" \
    -F 'kofun_fn_k_u005408_u008A08' "$WORK/stage2-identifiers.c"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/stage2-identifiers.c" \
    -o "$WORK/stage2-identifiers"
assert_eq "output of stage2-identifiers" "$("$WORK/stage2-identifiers")" "42"

set +e
KOFUN_DIAGNOSTIC_LOCALE=ja_JP \
    "$WORK/kofun-stage2" \
    "$ROOT/tests/unicode/non_nfc_identifier.kofun" \
    "$WORK/non-nfc.c" \
    "$WORK/non-nfc.ir" \
    "$WORK/non-nfc.tokens" \
    >"$WORK/non-nfc.stdout" 2>"$WORK/non-nfc.stderr"
non_nfc_status=$?

"$WORK/kofun-stage2" \
    "$ROOT/tests/unicode/confusable_identifier.kofun" \
    "$WORK/confusable.c" \
    "$WORK/confusable.ir" \
    "$WORK/confusable.tokens" \
    >"$WORK/confusable.stdout" 2>"$WORK/confusable.stderr"
confusable_status=$?
set -e

assert_num "non nfc status" "$non_nfc_status" -eq 1
assert_num "confusable status" "$confusable_status" -eq 1
assert_file_empty "non-nfc.stderr" "$WORK/non-nfc.stderr"
assert_file_empty "confusable.stderr" "$WORK/confusable.stderr"
assert_grep "non-nfc.stdout" -F 'error[EUNICODE005]' "$WORK/non-nfc.stdout"
assert_grep "non-nfc.stdout" -F 'NFCではありません' "$WORK/non-nfc.stdout"
assert_grep "confusable.stdout" \
    -F 'error[EUNICODE006]' "$WORK/confusable.stdout"
assert_grep "confusable.stdout" \
    -F 'confusable with `paypal`' "$WORK/confusable.stdout"

# Keep same-unit behavior and the accepted resolver boundary explicit. The
# focused visible-set gate above owns cross-module enforcement without routing
# EUNICODE008 through the single-unit compiler frontend.
assert_grep "syntax guide same-unit confusable hard error" \
    -F 'in one compilation unit are a hard error (`EUNICODE006`)' \
    "$ROOT/docs/SYNTAX.md"
assert_grep "syntax guide preserves name resolution" \
    -F 'does not change identifier equality or name resolution' \
    "$ROOT/docs/SYNTAX.md"
assert_grep "normative cross-module diagnostic is distinct" \
    -F 'distinct diagnostic code' \
    "$ROOT/spec/syntax/FOUNDATIONS_AND_CONTROL.md"
assert_grep "normative cross-module code is EUNICODE008" \
    -F '`EUNICODE008`' \
    "$ROOT/spec/syntax/FOUNDATIONS_AND_CONTROL.md"
assert_not_grep "syntax guide does not promise a public-API warning" \
    -F 'Confusable characters produce a warning in public APIs.' \
    "$ROOT/docs/SYNTAX.md"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/native/core_compiler.c" \
    -o "$WORK/kofun-native-core"
"$WORK/kofun-native-core" \
    "$ROOT/tests/unicode/native_identifiers.kofun" \
    x86_64-linux \
    "$WORK/native-identifiers"
chmod +x "$WORK/native-identifiers"
assert_eq "output of native-identifiers" "$("$WORK/native-identifiers")" "42"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/stage1/compiler.c" \
    -lm \
    -o "$WORK/kofun-stage1"
"$WORK/kofun-stage1" \
    "$ROOT/tests/unicode/native_identifiers.kofun" \
    "$WORK/stage1-identifiers.c" >/dev/null
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$WORK/stage1-identifiers.c" \
    -o "$WORK/stage1-identifiers"
assert_eq "output of stage1-identifiers" "$("$WORK/stage1-identifiers")" "42"

printf '%s\n' \
    "PASS: Stage 2 lowered Japanese and Hangul identifiers through ASCII-safe C names" \
    "PASS: Stage 1 and native Core resolved Japanese and Hangul bindings" \
    "PASS: Stage 2 rejected non-NFC and same-unit confusable identifiers with localized diagnostics" \
    "PASS: Stage 2 resolver rejected cross-module effective-visible-set collisions as EUNICODE008"
