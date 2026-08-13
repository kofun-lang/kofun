#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_WASM_CHECK_WORK:-"$ROOT/build/wasm-check"}
CC=${CC:-cc}
ASSERT_CONTEXT=wasm
. "$ROOT/tests/assertions/assert.sh"

for tool in "$CC" node "$ROOT/bin/kofun-sha256" cmp
do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "wasm32 gate requires $tool" >&2
        exit 1
    }
done

rm -rf "$WORK"
mkdir -p "$WORK"

repeat_character() (
    count=$1
    character=$2
    index=0
    while test "$index" -lt "$count"
    do
        printf '%s' "$character"
        index=$((index + 1))
    done
)

{
    printf '%s\n' 'fn main() {'
    printf '%s' '    print('
    repeat_character 256 '('
    printf '1'
    repeat_character 256 ')'
    printf '%s\n' ')'
    printf '%s' '    print('
    repeat_character 256 '+'
    printf '%s\n' '1)'
    printf '%s' '    print('
    repeat_character 128 '('
    repeat_character 128 '+'
    printf '1'
    repeat_character 128 ')'
    printf '%s\n' ')' '}'
} >"$WORK/expression-nesting-256.kofun"

{
    printf '%s\n' 'fn main() {'
    printf '%s' '    print('
    repeat_character 257 '('
    printf '1'
    repeat_character 257 ')'
    printf '%s\n' ')' '}'
} >"$WORK/parenthesized-nesting-257.kofun"

{
    printf '%s\n' 'fn main() {'
    printf '%s' '    print('
    repeat_character 257 '+'
    printf '%s\n' '1)' '}'
} >"$WORK/unary-nesting-257.kofun"

{
    printf '%s\n' 'fn main() {'
    printf '%s' '    print('
    repeat_character 128 '('
    repeat_character 129 '+'
    printf '1'
    repeat_character 128 ')'
    printf '%s\n' ')' '}'
} >"$WORK/mixed-nesting-257.kofun"

printf '%s\n' \
    'fn main() {' \
    '    print(-9223372036854775808)' \
    '}' >"$WORK/int64-minimum.kofun"

printf '%s\n' \
    'fn main() {' \
    '    print(--9223372036854775808)' \
    '}' >"$WORK/negated-int64-minimum.kofun"

(
    cd "$ROOT/bootstrap/wasm"
    "$ROOT/bin/kofun-sha256" -c SHA256SUMS
)

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler-sanitized"

"$WORK/compiler" \
    "$ROOT/examples/wasm_arithmetic.kofun" "$WORK/direct.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$ROOT/examples/wasm_arithmetic.kofun" "$WORK/sanitized.wasm"
cmp "$WORK/direct.wasm" "$WORK/sanitized.wasm"

"$WORK/compiler" \
    "$WORK/expression-nesting-256.kofun" "$WORK/nesting-256.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/expression-nesting-256.kofun" \
    "$WORK/nesting-256-sanitized.wasm"
cmp "$WORK/nesting-256.wasm" "$WORK/nesting-256-sanitized.wasm"
node "$ROOT/bootstrap/wasm/run.mjs" "$WORK/nesting-256.wasm" \
    >"$WORK/nesting-256.stdout" 2>"$WORK/nesting-256.stderr"
printf '1\n1\n1\n' >"$WORK/nesting-256.expected"
cmp "$WORK/nesting-256.expected" "$WORK/nesting-256.stdout"
assert_file_empty "nesting-256.stderr" "$WORK/nesting-256.stderr"

"$WORK/compiler" \
    "$WORK/int64-minimum.kofun" "$WORK/int64-minimum.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/int64-minimum.kofun" "$WORK/int64-minimum-sanitized.wasm"
cmp "$WORK/int64-minimum.wasm" "$WORK/int64-minimum-sanitized.wasm"
node "$ROOT/bootstrap/wasm/run.mjs" "$WORK/int64-minimum.wasm" \
    >"$WORK/int64-minimum.stdout" 2>"$WORK/int64-minimum.stderr"
printf '%s\n' '-9223372036854775808' >"$WORK/int64-minimum.expected"
cmp "$WORK/int64-minimum.expected" "$WORK/int64-minimum.stdout"
assert_file_empty "int64-minimum.stderr" "$WORK/int64-minimum.stderr"

"$WORK/compiler" \
    "$WORK/negated-int64-minimum.kofun" \
    "$WORK/negated-int64-minimum.wasm"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/negated-int64-minimum.kofun" \
    "$WORK/negated-int64-minimum-sanitized.wasm"
cmp \
    "$WORK/negated-int64-minimum.wasm" \
    "$WORK/negated-int64-minimum-sanitized.wasm"
set +e
node "$ROOT/bootstrap/wasm/run.mjs" \
    "$WORK/negated-int64-minimum.wasm" \
    >"$WORK/negated-int64-minimum.stdout" \
    2>"$WORK/negated-int64-minimum.stderr"
negated_minimum_status=$?
set -e
assert_num "negated minimum status" "$negated_minimum_status" -eq 1
assert_file_empty "negated-int64-minimum.stdout" \
    "$WORK/negated-int64-minimum.stdout"
assert_grep "negated-int64-minimum.stderr" \
    -Fxq \
    'error[R010]: integer overflow in unary operator `-`' \
    "$WORK/negated-int64-minimum.stderr"

"$ROOT/bin/kofun" build "$ROOT/examples/wasm_arithmetic.kofun" \
    --target wasm32 -o "$WORK/cli.wasm" >/dev/null
"$ROOT/bin/kofun" build "$ROOT/examples/wasm_arithmetic.kofun" \
    --target wasm32 -o "$WORK/cli-second.wasm" >/dev/null
cmp "$WORK/direct.wasm" "$WORK/cli.wasm"
cmp "$WORK/cli.wasm" "$WORK/cli-second.wasm"

cp "$WORK/cli.wasm" "$WORK/preserved.wasm"
set +e
"$ROOT/bin/kofun" build \
    "$WORK/parenthesized-nesting-257.kofun" \
    --target wasm32 -o "$WORK/preserved.wasm" \
    >"$WORK/nesting-257.stdout" 2>"$WORK/nesting-257.stderr"
nesting_status=$?
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/parenthesized-nesting-257.kofun" \
    "$WORK/parenthesized-nesting-257.wasm" \
    >"$WORK/parenthesized-nesting-257.stdout" \
    2>"$WORK/parenthesized-nesting-257.stderr"
sanitized_parenthesized_nesting_status=$?
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/unary-nesting-257.kofun" "$WORK/unary-nesting-257.wasm" \
    >"$WORK/unary-nesting-257.stdout" \
    2>"$WORK/unary-nesting-257.stderr"
sanitized_nesting_status=$?
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" \
    "$WORK/mixed-nesting-257.kofun" "$WORK/mixed-nesting-257.wasm" \
    >"$WORK/mixed-nesting-257.stdout" \
    2>"$WORK/mixed-nesting-257.stderr"
sanitized_mixed_nesting_status=$?
set -e
assert_num "nesting status" "$nesting_status" -eq 1
assert_num "sanitized parenthesized nesting status" \
    "$sanitized_parenthesized_nesting_status" -eq 1
assert_num "sanitized nesting status" "$sanitized_nesting_status" -eq 1
assert_num "sanitized mixed nesting status" \
    "$sanitized_mixed_nesting_status" -eq 1
cmp "$WORK/cli.wasm" "$WORK/preserved.wasm"
assert_absent "parenthesized-nesting-257.wasm" \
    "$WORK/parenthesized-nesting-257.wasm"
assert_absent "unary-nesting-257.wasm" "$WORK/unary-nesting-257.wasm"
assert_absent "mixed-nesting-257.wasm" "$WORK/mixed-nesting-257.wasm"
assert_file_empty "nesting-257.stdout" "$WORK/nesting-257.stdout"
assert_file_empty "parenthesized-nesting-257.stdout" \
    "$WORK/parenthesized-nesting-257.stdout"
assert_file_empty "unary-nesting-257.stdout" "$WORK/unary-nesting-257.stdout"
assert_file_empty "mixed-nesting-257.stdout" "$WORK/mixed-nesting-257.stdout"
assert_grep "nesting-257.stderr" \
    -Fxq \
    'kofun wasm32: line 2: expression nesting exceeds wasm32 limit of 256' \
    "$WORK/nesting-257.stderr"
assert_grep "parenthesized-nesting-257.stderr" \
    -Fxq \
    'kofun wasm32: line 2: expression nesting exceeds wasm32 limit of 256' \
    "$WORK/parenthesized-nesting-257.stderr"
assert_grep "unary-nesting-257.stderr" \
    -Fxq \
    'kofun wasm32: line 2: expression nesting exceeds wasm32 limit of 256' \
    "$WORK/unary-nesting-257.stderr"
assert_grep "mixed-nesting-257.stderr" \
    -Fxq \
    'kofun wasm32: line 2: expression nesting exceeds wasm32 limit of 256' \
    "$WORK/mixed-nesting-257.stderr"
for temporary in "$WORK"/preserved.wasm.tmp.*
do
    test ! -e "$temporary" && test ! -L "$temporary"
done

node --check "$ROOT/bootstrap/wasm/run.mjs"
node --check "$ROOT/examples/wasm-browser/main.mjs"
node --check "$ROOT/examples/wasm-browser/check.mjs"
node --check "$ROOT/examples/wasm-browser/serve.mjs"
node "$ROOT/bootstrap/wasm/run.mjs" "$WORK/cli.wasm" \
    >"$WORK/sample.stdout" 2>"$WORK/sample.stderr"
printf '42\n-4\n' >"$WORK/sample.expected"
cmp "$WORK/sample.expected" "$WORK/sample.stdout"
assert_file_empty "sample.stderr" "$WORK/sample.stderr"

"$ROOT/examples/wasm-browser/build.sh" "$WORK/browser" \
    >"$WORK/browser-build.stdout"
node "$ROOT/examples/wasm-browser/check.mjs" "$WORK/browser/app.wasm" \
    >"$WORK/browser-check.stdout"
assert_grep "browser-check.stdout" \
    -Fq \
    'PASS: browser host loaded and rendered Kofun WebAssembly' \
    "$WORK/browser-check.stdout"
assert_grep "browser-check.stdout" \
    -Fq \
    'PASS: viewport lazy loading deferred the wasm fetch' \
    "$WORK/browser-check.stdout"
assert_grep "browser/index.html" \
    -Fq 'data-kofun-wasm="./app.wasm"' "$WORK/browser/index.html"
assert_grep "browser/index.html" \
    -Fq 'src="./main.mjs"' "$WORK/browser/index.html"
cmp "$ROOT/examples/wasm-browser/main.mjs" "$WORK/browser/main.mjs"

set +e
"$ROOT/bin/kofun" build \
    "$ROOT/bootstrap/wasm/fixtures/unsupported_text.kofun" \
    --target wasm32 -o "$WORK/unsupported.wasm" \
    >"$WORK/unsupported.stdout" 2>"$WORK/unsupported.stderr"
unsupported_status=$?
"$ROOT/bin/kofun" build "$ROOT/examples/wasm_arithmetic.kofun" \
    --target wasm32 -g -o "$WORK/debug.wasm" \
    >"$WORK/debug.stdout" 2>"$WORK/debug.stderr"
debug_status=$?
# `/` is not defined on Int (#687): with no implicit numeric promotion it
# cannot produce a fractional value from two Ints, and truncating it while `//`
# floors would make two near-identical operators disagree on negatives. wasm32
# must refuse it exactly as the two native targets do, and emit no module.
"$ROOT/bin/kofun" build \
    "$ROOT/bootstrap/wasm/fixtures/reject_slash_operator.kofun" \
    --target wasm32 -o "$WORK/reject-slash.wasm" \
    >"$WORK/reject-slash.stdout" 2>"$WORK/reject-slash.stderr"
slash_status=$?
set -e
assert_num "unsupported status" "$unsupported_status" -eq 1
assert_num "debug status" "$debug_status" -eq 2
assert_absent "unsupported.wasm" "$WORK/unsupported.wasm"
assert_absent "debug.wasm" "$WORK/debug.wasm"
assert_num "slash status" "$slash_status" -eq 1
assert_absent "reject-slash.wasm" "$WORK/reject-slash.wasm"
assert_file_empty "reject-slash.stdout" "$WORK/reject-slash.stdout"
assert_grep "reject-slash.stderr" \
    -Fq \
    '`/` is not defined on Int; use `//` for the integer quotient' \
    "$WORK/reject-slash.stderr"
assert_grep "unsupported.stderr" \
    -Fq \
    'unsupported token in wasm32 arithmetic Core' \
    "$WORK/unsupported.stderr"
assert_grep "debug.stderr" \
    -Fq \
    -- \
    '-g currently requires --target x86_64-linux or --target aarch64-linux' \
    "$WORK/debug.stderr"

# The bounded Int function profile (#222). Every case in the maintained
# corpus is compiled three ways — direct seed, sanitized seed, and public CLI —
# and the three must agree byte for byte, so "deterministic" covers functions
# and not only the single-`main` arithmetic Core.
: >"$WORK/function-modules.list"
for source in "$ROOT"/tests/conformance/functions/*.kofun
do
    stem=$(basename "${source%.kofun}")
    test "$stem" != expectations || continue
    "$WORK/compiler" "$source" "$WORK/function-$stem.wasm"
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/compiler-sanitized" \
        "$source" "$WORK/function-$stem-sanitized.wasm"
    cmp "$WORK/function-$stem.wasm" "$WORK/function-$stem-sanitized.wasm"
    "$ROOT/bin/kofun" build "$source" \
        --target wasm32 -o "$WORK/function-$stem-cli.wasm" >/dev/null
    "$ROOT/bin/kofun" build "$source" \
        --target wasm32 -o "$WORK/function-$stem-cli-second.wasm" >/dev/null
    cmp "$WORK/function-$stem.wasm" "$WORK/function-$stem-cli.wasm"
    cmp "$WORK/function-$stem-cli.wasm" "$WORK/function-$stem-cli-second.wasm"
    printf '%s\n' "$WORK/function-$stem.wasm" >>"$WORK/function-modules.list"
done

# `run.mjs` already refuses to instantiate a module the engine rejects, but the
# claim "WebAssembly.validate accepts every emitted module" deserves its own
# gate rather than riding on a runtime that could stop checking.
node --input-type=module -e '
import { readFile } from "node:fs/promises";
const [, listPath] = process.argv;
const list = (await readFile(listPath, "utf8")).split("\n").filter(Boolean);
if (list.length === 0) {
  console.error("wasm32 gate: no function modules were emitted");
  process.exit(1);
}
for (const path of list) {
  const bytes = await readFile(path);
  if (!WebAssembly.validate(bytes)) {
    console.error(`wasm32 gate: engine rejected ${path}`);
    process.exit(1);
  }
}
console.log(`validated ${list.length} function modules`);
' "$WORK/function-modules.list" >"$WORK/function-validate.stdout"
assert_grep "function-validate.stdout" \
    -Fxq 'validated 12 function modules' "$WORK/function-validate.stdout"

# A call evaluates its arguments left to right and exactly once. Both arguments
# below overflow under a different checked operator, so the diagnostic that
# reaches stderr names the one evaluated first; the mirrored fixture swaps them
# and must swap the operator. Observing only "some trap" would not tell the two
# orders apart.
"$ROOT/bin/kofun" build \
    "$ROOT/bootstrap/wasm/fixtures/argument_order.kofun" \
    --target wasm32 -o "$WORK/argument-order.wasm" >/dev/null
"$ROOT/bin/kofun" build \
    "$ROOT/bootstrap/wasm/fixtures/argument_order_mirrored.kofun" \
    --target wasm32 -o "$WORK/argument-order-mirrored.wasm" >/dev/null
set +e
node "$ROOT/bootstrap/wasm/run.mjs" "$WORK/argument-order.wasm" \
    >"$WORK/argument-order.stdout" 2>"$WORK/argument-order.stderr"
argument_order_status=$?
node "$ROOT/bootstrap/wasm/run.mjs" "$WORK/argument-order-mirrored.wasm" \
    >"$WORK/argument-order-mirrored.stdout" \
    2>"$WORK/argument-order-mirrored.stderr"
argument_order_mirrored_status=$?
set -e
assert_num "argument order status" "$argument_order_status" -eq 1
assert_num "argument order mirrored status" \
    "$argument_order_mirrored_status" -eq 1
assert_file_empty "argument-order.stdout" "$WORK/argument-order.stdout"
assert_file_empty "argument-order-mirrored.stdout" \
    "$WORK/argument-order-mirrored.stdout"
assert_grep "argument-order.stderr" \
    -Fxq \
    'error[R010]: integer overflow in operator `+`' \
    "$WORK/argument-order.stderr"
assert_grep "argument-order-mirrored.stderr" \
    -Fxq \
    'error[R010]: integer overflow in operator `-`' \
    "$WORK/argument-order-mirrored.stderr"

# Every refused function signature, call, and body fails through both the
# public CLI and the sanitized seed, with a stable source-located diagnostic,
# empty stdout, and no module left behind.
reject_function_fixture() {
    fixture=$1
    expected=$2
    rm -f "$WORK/reject-$fixture.wasm" "$WORK/reject-$fixture-sanitized.wasm"
    set +e
    "$ROOT/bin/kofun" build \
        "$ROOT/bootstrap/wasm/fixtures/$fixture.kofun" \
        --target wasm32 -o "$WORK/reject-$fixture.wasm" \
        >"$WORK/reject-$fixture.stdout" 2>"$WORK/reject-$fixture.stderr"
    reject_status=$?
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1 \
        "$WORK/compiler-sanitized" \
        "$ROOT/bootstrap/wasm/fixtures/$fixture.kofun" \
        "$WORK/reject-$fixture-sanitized.wasm" \
        >"$WORK/reject-$fixture-sanitized.stdout" \
        2>"$WORK/reject-$fixture-sanitized.stderr"
    reject_sanitized_status=$?
    set -e
    assert_num "reject status" "$reject_status" -eq 1
    assert_num "reject sanitized status" "$reject_sanitized_status" -eq 1
    assert_absent "reject-$fixture.wasm" "$WORK/reject-$fixture.wasm"
    assert_absent "reject-$fixture-sanitized.wasm" \
        "$WORK/reject-$fixture-sanitized.wasm"
    assert_file_empty "reject-$fixture.stdout" "$WORK/reject-$fixture.stdout"
    assert_file_empty "reject-$fixture-sanitized.stdout" \
        "$WORK/reject-$fixture-sanitized.stdout"
    assert_grep "reject-$fixture.stderr" \
        -Fxq "kofun wasm32: $expected" "$WORK/reject-$fixture.stderr"
    grep -Fxq "kofun wasm32: $expected" \
        "$WORK/reject-$fixture-sanitized.stderr"
}

reject_function_fixture reject_unknown_function \
    'line 3: call to a function the wasm32 Core program does not declare'
reject_function_fixture reject_duplicate_function \
    'line 6: duplicate function declaration in wasm32 Core'
reject_function_fixture reject_duplicate_parameter \
    'line 2: duplicate parameter in wasm32 Core'
reject_function_fixture reject_call_arity \
    'line 7: call passes a different number of arguments than the declaration accepts'
reject_function_fixture reject_seven_parameters \
    'line 2: wasm32 Core accepts at most six Int parameters'
reject_function_fixture reject_seven_arguments \
    'line 7: call passes a different number of arguments than the declaration accepts'
reject_function_fixture reject_non_int_parameter \
    'line 2: wasm32 Core accepts only Int parameters'
reject_function_fixture reject_non_int_result \
    'line 2: wasm32 Core requires an `-> Int` result on every function other than `main`'
reject_function_fixture reject_missing_return \
    'line 2: a wasm32 Core function declaring `-> Int` must end with `return`'
reject_function_fixture reject_function_value \
    'line 7: wasm32 Core has no function values; write a direct call instead'
reject_function_fixture reject_indirect_call \
    'line 4: wasm32 Core does not support calling a binding; only direct calls to declared functions'

sh "$ROOT/tests/conformance/run.sh" \
    "$ROOT/tests/conformance/numeric"

sh "$ROOT/tests/conformance/run.sh" \
    "$ROOT/tests/conformance/functions"

# The v1 Text profile deliberately remains separate from the legacy numeric
# corpus, but `task wasm` owns both wasm32 bindings and must not omit it.
sh "$ROOT/tests/wasm-text-v1/check.sh"

printf '%s\n' \
    'PASS: Kofun emitted deterministic, engine-validated WebAssembly' \
    'PASS: separate and mixed nesting accepted 256 levels and rejected 257 atomically' \
    'PASS: direct Int64 minimum parsing and checked re-negation stayed exact' \
    'PASS: wasm32-node matched C11 for all numeric Core observations' \
    'PASS: wasm32-node executed the bounded Int function corpus against C11' \
    'PASS: calls evaluated arguments left to right, exactly once' \
    'PASS: Kofun browser sample rendered through a lazy DOM host' \
    'PASS: unsupported source, `/`, and debug mode failed without artifacts' \
    'PASS: refused signatures, calls, and bodies left no module behind'
