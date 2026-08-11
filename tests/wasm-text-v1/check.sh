#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_WASM_TEXT_WORK:-"$ROOT/build/wasm-text-v1"}
CC=${CC:-cc}
ASSERT_CONTEXT='wasm32-hostabi1 Text'
. "$ROOT/tests/assertions/assert.sh"

for tool in "$CC" node "$ROOT/bin/kofun-digest" cmp
do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "wasm32-hostabi1 Text gate requires $tool" >&2
        exit 1
    }
done

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler-sanitized"

SOURCE="$ROOT/bootstrap/wasm/fixtures/hostabi1_text.kofun"
"$WORK/compiler" --hostabi1 "$SOURCE" "$WORK/text.wasm"
"$WORK/compiler" --hostabi1 "$SOURCE" "$WORK/text-second.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" --hostabi1 \
    "$SOURCE" "$WORK/text-sanitized.wasm"
cmp "$WORK/text.wasm" "$WORK/text-second.wasm"
cmp "$WORK/text.wasm" "$WORK/text-sanitized.wasm"

node "$ROOT/spec/wasm-host-abi-v1/hostabi.mjs" vectors >"$WORK/vectors.json"
node "$ROOT/spec/wasm-host-abi-v1/hostabi.mjs" module "$WORK/text.wasm" \
    >"$WORK/module.json"
assert_grep "host ABI module acceptance" -Fq '"contract": "accepted"' \
    "$WORK/module.json"
assert_grep "host ABI validation did not execute guest code" \
    -Fq '"guest_ran": false' "$WORK/module.json"
node "$ROOT/tests/wasm-text-v1/run.mjs" \
    "$WORK/text.wasm" "$WORK/vectors.json" >"$WORK/wasm.stdout"

"$ROOT/bin/kofun" build "$SOURCE" --target x86_64-linux \
    -o "$WORK/native" >"$WORK/native.build.stdout"
"$WORK/native" >"$WORK/native.stdout"
cmp "$WORK/native.stdout" "$WORK/wasm.stdout"
printf '\nhello\n古墳\n' >"$WORK/expected.stdout"
cmp "$WORK/expected.stdout" "$WORK/wasm.stdout"

# The legacy target's bytes are pinned independently of the new profile path.
"$WORK/compiler" "$ROOT/examples/wasm_arithmetic.kofun" "$WORK/legacy.wasm"
legacy_digest=$("$ROOT/bin/kofun-digest" "$WORK/legacy.wasm" | awk '{print $1}')
test "$legacy_digest" = \
    'ead99da7862aee50ec77099e16d8382cd5ef3b75920136c78734e788525856da' || {
    printf '%s\n' "FAIL: legacy wasm32 byte digest changed: $legacy_digest" >&2
    exit 1
}

# Unsupported syntax and invalid UTF-8 fail before an artifact exists.
for fixture in unsupported_concat unsupported_int_parameter
do
    set +e
    "$WORK/compiler" --hostabi1 \
        "$ROOT/tests/wasm-text-v1/$fixture.kofun" "$WORK/$fixture.wasm" \
        >"$WORK/$fixture.stdout" 2>"$WORK/$fixture.stderr"
    status=$?
    set -e
    assert_num "$fixture status" "$status" -eq 1
    assert_absent "$fixture artifact" "$WORK/$fixture.wasm"
    assert_file_empty "$fixture stdout" "$WORK/$fixture.stdout"
done
assert_grep "unsupported Text operation diagnostic" \
    -Fq 'unsupported operation in wasm32-hostabi1 Text slice' \
    "$WORK/unsupported_concat.stderr"
assert_grep "non-Text parameter diagnostic" \
    -Fq 'wasm32-hostabi1 parameters must be Text' \
    "$WORK/unsupported_int_parameter.stderr"

printf 'fn main() {\n    print("bad' >"$WORK/invalid-utf8.kofun"
printf '\377' >>"$WORK/invalid-utf8.kofun"
printf '")\n}\n' >>"$WORK/invalid-utf8.kofun"
set +e
"$WORK/compiler" --hostabi1 "$WORK/invalid-utf8.kofun" \
    "$WORK/invalid-utf8.wasm" >"$WORK/invalid-utf8.stdout" \
    2>"$WORK/invalid-utf8.stderr"
invalid_status=$?
set -e
assert_num "invalid UTF-8 status" "$invalid_status" -eq 1
assert_absent "invalid UTF-8 artifact" "$WORK/invalid-utf8.wasm"
assert_grep "invalid UTF-8 diagnostic" \
    -Fq 'Text literal is not well-formed UTF-8' "$WORK/invalid-utf8.stderr"

{
    printf '%s\n' 'fn identity(value: Text) -> Text { return value }'
    printf '%s' 'fn main() { print('
    nesting=0
    while test "$nesting" -lt 257
    do
        printf '%s' 'identity('
        nesting=$((nesting + 1))
    done
    printf '%s' '"x"'
    nesting=0
    while test "$nesting" -lt 257
    do
        printf '%s' ')'
        nesting=$((nesting + 1))
    done
    printf '%s\n' ') }'
} >"$WORK/nesting-257.kofun"
set +e
"$WORK/compiler" --hostabi1 "$WORK/nesting-257.kofun" \
    "$WORK/nesting-257.wasm" >"$WORK/nesting-257.stdout" \
    2>"$WORK/nesting-257.stderr"
nesting_status=$?
set -e
assert_num "Text nesting status" "$nesting_status" -eq 1
assert_absent "Text nesting artifact" "$WORK/nesting-257.wasm"
assert_grep "Text nesting diagnostic" \
    -Fq 'Text expression nesting exceeds wasm32 limit of 256' \
    "$WORK/nesting-257.stderr"

# A valid literal larger than the remaining fixed arena reaches abort(2,
# object_size); it cannot wrap, publish a partial object, or become null Text.
{
    printf '%s' 'fn main() { print("'
    awk 'BEGIN { for (i = 0; i < 64505; ++i) printf "a" }'
    printf '%s\n' '") }'
} >"$WORK/exhaustion.kofun"
"$WORK/compiler" --hostabi1 "$WORK/exhaustion.kofun" \
    "$WORK/exhaustion.wasm"
node "$ROOT/tests/wasm-text-v1/run.mjs" \
    "$WORK/exhaustion.wasm" "$WORK/vectors.json" expect-abort

printf '%s\n' \
    'PASS: wasm32-hostabi1 lowers empty, ASCII, and Japanese Text through direct parameter/result calls' \
    'PASS: text_out receives only aligned in-bounds v1 objects with fatal UTF-8 decoding' \
    'PASS: native x86-64 observations match and repeated/sanitized wasm builds are byte-identical' \
    'PASS: unsupported, invalid UTF-8, and depth-257 sources write no artifact; exhaustion calls abort(2, detail)' \
    'PASS: bare wasm32 keeps its pinned legacy module bytes'
