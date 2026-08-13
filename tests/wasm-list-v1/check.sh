#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_WASM_LIST_WORK:-"$ROOT/build/wasm-list-v1"}
CC=${CC:-cc}
ASSERT_CONTEXT='wasm32-hostabi1 List'
. "$ROOT/tests/assertions/assert.sh"

for tool in "$CC" node "$ROOT/bin/kofun-sha256" cmp
do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "wasm32-hostabi1 List gate requires $tool" >&2
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

SOURCE="$ROOT/tests/wasm-list-v1/program.kofun"
"$WORK/compiler" --hostabi1 "$SOURCE" "$WORK/lists.wasm"
"$WORK/compiler" --hostabi1 "$SOURCE" "$WORK/lists-second.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" --hostabi1 \
    "$SOURCE" "$WORK/lists-sanitized.wasm"
cmp "$WORK/lists.wasm" "$WORK/lists-second.wasm"
cmp "$WORK/lists.wasm" "$WORK/lists-sanitized.wasm"

node "$ROOT/spec/wasm-host-abi-v1/hostabi.mjs" vectors >"$WORK/vectors.json"
node "$ROOT/spec/wasm-host-abi-v1/hostabi.mjs" module "$WORK/lists.wasm" \
    >"$WORK/module.json"
assert_grep "host ABI module acceptance" -Fq '"contract": "accepted"' \
    "$WORK/module.json"
assert_grep "host ABI validation did not execute guest code" \
    -Fq '"guest_ran": false' "$WORK/module.json"
node "$ROOT/tests/wasm-list-v1/run.mjs" \
    "$WORK/lists.wasm" "$WORK/vectors.json" >"$WORK/observed.json"
printf '%s\n' \
    '[{"import":"list_int_out","value":[]},{"import":"list_int_out","value":["10","42","99"]},{"import":"list_int_out","value":["3","10","42"]},{"import":"list_text_out","value":[]},{"import":"list_text_out","value":["古墳","hello"]},{"import":"list_int_out","value":["2"]},{"import":"list_text_out","value":["hello","古墳"]}]' \
    >"$WORK/expected.json"
cmp "$WORK/expected.json" "$WORK/observed.json"

# A bracket in a comment does not widen the established Text-only import
# surface. Activation follows source syntax, not incidental documentation.
"$WORK/compiler" --hostabi1 \
    "$ROOT/tests/wasm-list-v1/text-comment-bracket.kofun" \
    "$WORK/text-comment.wasm"
node -e '
  const fs = require("fs");
  const imports = WebAssembly.Module.imports(
    new WebAssembly.Module(fs.readFileSync(process.argv[1]))
  ).map(({ module, name }) => `${module}.${name}`);
  process.stdout.write(imports.join("\n") + "\n");
' "$WORK/text-comment.wasm" >"$WORK/text-comment.imports"
printf '%s\n' \
    'kofun:host-abi-v1.abort' \
    'kofun:host-abi-v1.text_out' \
    >"$WORK/text-comment.expected-imports"
cmp "$WORK/text-comment.expected-imports" "$WORK/text-comment.imports"

# The native backend independently observes the same length and valid Int
# index values. Its bounded aggregate profile admits one observable expression
# per source, so three established oracle fixtures are compiled independently.
for native_case in len first last
do
    case $native_case in
        len) native_source="$ROOT/bootstrap/native/fixtures/core_list_len_42.kofun" ;;
        first) native_source="$ROOT/tests/wasm-list-v1/native-oracle.kofun" ;;
        last) native_source="$ROOT/bootstrap/native/fixtures/core_list_positive_42.kofun" ;;
    esac
    "$ROOT/bin/kofun" build "$native_source" --target x86_64-linux \
        -o "$WORK/native-$native_case" \
        >"$WORK/native-$native_case.build.stdout"
    "$WORK/native-$native_case" >>"$WORK/native.stdout"
done
for native_text_case in length index
do
    native_text_source="$ROOT/tests/wasm-list-v1/native-text-$native_text_case.kofun"
    "$ROOT/bin/kofun" build "$native_text_source" --target x86_64-linux \
        -o "$WORK/native-text-$native_text_case" \
        >"$WORK/native-text-$native_text_case.build.stdout"
    "$WORK/native-text-$native_text_case" >>"$WORK/native.stdout"
done
node -e '
  const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const ints = value[2].value;
  const textLength = value[5].value[0];
  const textIndex = value[6].value[0];
  process.stdout.write([
    String(Number(ints[0]) + 39), ...ints.slice(1),
    String(Number(textLength) + 40), textIndex,
  ].join("\n") + "\n");
' "$WORK/observed.json" >"$WORK/wasm-semantic.stdout"
cmp "$WORK/native.stdout" "$WORK/wasm-semantic.stdout"

for mode in negative upper
do
    "$WORK/compiler" --hostabi1 \
        "$ROOT/tests/wasm-list-v1/$mode-index.kofun" \
        "$WORK/$mode.wasm"
    node "$ROOT/tests/wasm-list-v1/run.mjs" \
        "$WORK/$mode.wasm" "$WORK/vectors.json" "$mode"
done

set +e
"$WORK/compiler" --hostabi1 \
    "$ROOT/tests/wasm-list-v1/unsupported-append.kofun" \
    "$WORK/unsupported.wasm" >"$WORK/unsupported.stdout" \
    2>"$WORK/unsupported.stderr"
unsupported_status=$?
set -e
assert_num "unsupported List operation status" "$unsupported_status" -eq 1
assert_absent "unsupported List artifact" "$WORK/unsupported.wasm"
assert_file_empty "unsupported List stdout" "$WORK/unsupported.stdout"
assert_grep "unsupported List diagnostic" \
    -Fq 'unknown direct List function' "$WORK/unsupported.stderr"

# Bare wasm32 remains byte-compatible with the pre-profile binding.
"$WORK/compiler" "$ROOT/examples/wasm_arithmetic.kofun" "$WORK/legacy.wasm"
legacy_digest=$("$ROOT/bin/kofun-sha256" "$WORK/legacy.wasm" | awk '{print $1}')
test "$legacy_digest" = \
    'ead99da7862aee50ec77099e16d8382cd5ef3b75920136c78734e788525856da' || {
    printf '%s\n' "FAIL: legacy wasm32 byte digest changed: $legacy_digest" >&2
    exit 1
}

printf '%s\n' \
    'PASS: empty/non-empty List[Int] and List[Text] use v1 u64 headers and 8/4-byte strides' \
    'PASS: locals and direct parameter/result transport preserve list references' \
    'PASS: len and valid indexing agree with native x86-64 observations' \
    'PASS: negative and upper-bound indexing abort(1, index) before any value read or output' \
    'PASS: repeated and sanitized builds are identical; unsupported operations write no artifact' \
    'PASS: bare wasm32 keeps its pinned legacy module bytes'
