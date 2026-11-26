#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_TYPED_SIDECAR_CLI_WORK:-"$ROOT/build/typed-sidecar-cli"}
COMPLETE="$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun"
FAILED="$ROOT/bootstrap/stage2/function_unknown_error.kofun"
BORROWED="$ROOT/bootstrap/stage2/fixtures/borrowed_copy_int.kofun"
ASSERT_CONTEXT='typed-sidecar cli'
. "$ROOT/tests/assertions/assert.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */typed-sidecar-cli|*/typed-sidecar-cli.*) ;;
    *) fail "work directory must end in typed-sidecar-cli[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/output" "$WORK/build"

run_kofun() {
    KOFUN_BUILD_DIR="$WORK/build/stage1" \
    KOFUN_STAGE2_BUILD_DIR="$WORK/build/stage2" \
    KOFUN_STAGE2_EVENTS_BUILD_DIR="$WORK/build/events" \
        "$ROOT/bin/kofun" "$@"
}

expect_status() (
    expected=$1
    label=$2
    shift 2
    set +e
    run_kofun "$@" >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    actual=$?
    set -e
    test "$actual" -eq "$expected" ||
        fail "$label exited $actual instead of $expected"
)

run_kofun --help >"$WORK/help"
assert_grep "help" -q -- '--emit-typed-sidecar' "$WORK/help"
assert_grep "help" -q 'non-authoritative tooling data' "$WORK/help"

expect_status 0 complete check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/complete.kofun-semantic.json" \
    --generation 1
assert_grep "complete.stdout" -Fx "ok: $COMPLETE" "$WORK/complete.stdout"
assert_file_empty "complete.stderr" "$WORK/complete.stderr"
assert_file_nonempty "output/complete.kofun-semantic.json" \
    "$WORK/output/complete.kofun-semantic.json"

expect_status 0 borrowed-plain check "$BORROWED"
expect_status 0 borrowed-sidecar check "$BORROWED" \
    --emit-typed-sidecar "$WORK/output/borrowed.json" --generation 4
cmp "$WORK/borrowed-plain.stdout" "$WORK/borrowed-sidecar.stdout"
cmp "$WORK/borrowed-plain.stderr" "$WORK/borrowed-sidecar.stderr"
assert_file_nonempty "output/borrowed.json" "$WORK/output/borrowed.json"

expect_status 0 reverse-order check "$COMPLETE" \
    --generation 2 \
    --emit-typed-sidecar "$WORK/output/reverse.kofun-semantic.json"
expect_status 0 maximum check "$COMPLETE" \
    --generation 9007199254740991 \
    --emit-typed-sidecar "$WORK/output/maximum.kofun-semantic.json"

node --input-type=module - \
    "$WORK/output/complete.kofun-semantic.json" \
    "$WORK/output/reverse.kofun-semantic.json" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import { readTypedSidecar } from "./tooling/typed-sidecar/codec.mjs";
for (const [index, filename] of process.argv.slice(2).entries()) {
  const result = readTypedSidecar(fs.readFileSync(filename));
  assert.equal(result.ok, true, result.error?.message);
  assert.equal(result.document.authoritative, false);
  assert.equal(result.document.generation.sequence, index + 1);
}
NODE

# The callable effects research note's x16 dispatch, with each admitted
# callable arity and an inferred pure function beside the explicit declaration.
cat >"$WORK/callables.kofun" <<'KOFUN'
fn noisy(x: Int) -> Int {
    print(x)
    return x
}
pure fn forward(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}
fn unary(f: Int -> Int) -> Int {
    return f(1)
}
fn shapes(zero: () -> Int, one: pure Int -> Int, two: (Int, Int) -> Int) -> Int {
    return 7
}
fn main() -> Int {
    return forward(noisy, 7)
}
KOFUN
expect_status 0 implicit-v1 check "$WORK/callables.kofun" --generation 9 \
    --emit-typed-sidecar "$WORK/output/implicit.json"
for version in 1 3; do
    expect_status 0 "version-$version" check "$WORK/callables.kofun" \
        --typed-sidecar-version "$version" --generation 9 \
        --emit-typed-sidecar "$WORK/output/v$version.json"
done
cmp "$WORK/output/implicit.json" "$WORK/output/v1.json"
cmp "$WORK/version-1.stdout" "$WORK/version-3.stdout"
cmp "$WORK/version-1.stderr" "$WORK/version-3.stderr"

node --input-type=module - "$WORK/output" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import { readTypedSidecar } from "./tooling/typed-sidecar/codec.mjs";
import { validateAgainstSchema } from "./tests/lib/json-schema.mjs";

const [v1, v3] = [1, 3].map(version => {
  const result = readTypedSidecar(fs.readFileSync(`${process.argv[2]}/v${version}.json`));
  assert.equal(result.ok, true, result.error?.message);
  assert.equal(result.document.schema, `kofun.typed-sidecar/v${version}`);
  assert.equal(result.document.generation.sequence, 9);
  return result.document;
});
const functions = doc => doc.nodes.filter(node => node.kind === "function.declaration");
const signatures = doc => functions(doc).map(node => node.type.display);
assert.deepEqual(signatures(v1), [
  "Int -> Int", "(Fn, Int) -> Int", "Fn -> Int", "(Fn, Fn[pure], Fn) -> Int", "() -> Int",
]);
assert.deepEqual(signatures(v3), [
  "Int -> Int", "((Int) -> Int, Int) -> Int", "((Int) -> Int) -> Int",
  "(() -> Int, pure (Int) -> Int, (Int, Int) -> Int) -> Int", "() -> Int",
]);
assert.deepEqual(v3.nodes.filter(node => node.kind === "parameter.binding").map(node => node.type.display),
  ["Int", "(Int) -> Int", "Int", "(Int) -> Int", "() -> Int", "pure (Int) -> Int", "(Int, Int) -> Int"]);
for (const doc of [v1, v3]) {
  assert.deepEqual(functions(doc).map(node => node.effect.display), ["io", "pure", "pure", "pure", "io"]);
}
assert.deepEqual(v3.declared_pure_functions, [functions(v3)[1].id]);
assert.deepEqual(v3.nodes.map(node => node.id), v1.nodes.map(node => node.id));

// Resolve the repository's relative schema references into local JSON pointers
// so the shared schema interpreter validates the CLI's actual output offline.
const schemaFiles = {};
for (const version of [1, 2, 3]) {
  const file = `kofun.typed-sidecar.v${version}.schema.json`;
  schemaFiles[file] = JSON.parse(fs.readFileSync(`spec/typed-sidecar/${file}`, "utf8"), (key, value) => {
    if (key !== "$ref") return value;
    const [owner, pointer] = value.split("#");
    return `#/$defs/${owner || file}${pointer}`;
  });
}
const schema = schemaFiles["kofun.typed-sidecar.v3.schema.json"];
function schemaErrors(doc) {
  const errors = [];
  validateAgainstSchema({ $defs: schemaFiles }, schema, doc, "$", errors);
  return errors;
}
assert.deepEqual(schemaErrors(v3), []);
assert.notEqual(schemaErrors({ ...v3, declared_pure_functions: ["not-an-id"] }).length, 0);
assert.notEqual(schemaErrors({ ...v3, captures: [] }).length, 0);
NODE

# A callable can be small in v1 ("Fn") and longer than 159 bytes when expanded.
node --input-type=module - "$WORK/wide.kofun" <<'NODE'
import fs from "node:fs";
const params = Array.from({ length: 6 }, (_, i) => `f${i}: (Int, Int, Int, Int, Int) -> Int`);
fs.writeFileSync(process.argv[2], `fn wide(${params.join(", ")}, x: Int) -> Int { return x }
fn main() -> Int { return 0 }
`);
NODE
expect_status 0 wide-signature check "$WORK/wide.kofun" \
    --typed-sidecar-version 3 --emit-typed-sidecar "$WORK/output/wide.json" --generation 1
node --input-type=module - "$WORK/output/wide.json" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
const {nodes} = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const slots = Array(6).fill("(Int, Int, Int, Int, Int) -> Int");
assert.equal(nodes.find(n => n.kind === "function.declaration").type.display,
  `(${slots.join(", ")}, Int) -> Int`);
NODE

# A stale write may request a different schema. It must preserve the stored
# bytes and fail through the same atomic replacement path.
cp "$WORK/output/v3.json" "$WORK/version.before"
expect_status 3 stale-version check "$WORK/callables.kofun" \
    --typed-sidecar-version 1 --emit-typed-sidecar "$WORK/output/v3.json" --generation 8
assert_grep "stale-version.stderr" -q '^ETS05: ' "$WORK/stale-version.stderr"
cmp "$WORK/output/v3.json" "$WORK/version.before"

for value in '' 00 01 +1 -1 1e3 1_000 9007199254740992
do
    label=$(printf '%s' "${value:-empty}" | tr '+_-' 'pmm')
    expect_status 2 "generation-$label" check "$COMPLETE" \
        --emit-typed-sidecar "$WORK/output/generation-$label.json" \
        --generation "$value"
    assert_grep "generation-$label.stderr" \
        -q '^ETS01: ' "$WORK/generation-$label.stderr"
done

expect_status 2 missing-generation check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/missing.json"
expect_status 2 missing-output check "$COMPLETE" --generation 1
expect_status 2 duplicate-output check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/a.json" \
    --emit-typed-sidecar "$WORK/output/b.json"
expect_status 2 duplicate-generation check "$COMPLETE" \
    --generation 1 --generation 2
expect_status 2 unknown-option check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/unknown.json" --unknown 1
expect_status 2 unknown-version check "$COMPLETE" --generation 1 \
    --emit-typed-sidecar "$WORK/output/unknown-version.json" --typed-sidecar-version 4
expect_status 2 missing-version check "$COMPLETE" --generation 1 \
    --emit-typed-sidecar "$WORK/output/unknown-version.json" --typed-sidecar-version
expect_status 2 repeated-version check "$COMPLETE" --generation 1 \
    --emit-typed-sidecar "$WORK/output/unknown-version.json" --typed-sidecar-version 1 --typed-sidecar-version 3
assert_absent "unknown-version artifact" "$WORK/output/unknown-version.json"
for label in missing-generation missing-output duplicate-output \
    duplicate-generation unknown-option unknown-version missing-version repeated-version
do
    assert_grep "$label.stderr" -q '^ETS01: ' "$WORK/$label.stderr"
done

expect_status 2 dash check "$COMPLETE" \
    --emit-typed-sidecar - --generation 3
mkdir "$WORK/output/directory.json"
expect_status 2 directory check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/directory.json" --generation 3
printf '%s\n' keep >"$WORK/output/victim"
ln -s victim "$WORK/output/symlink.json"
expect_status 2 symlink check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/symlink.json" --generation 3
expect_status 2 source-output check "$COMPLETE" \
    --emit-typed-sidecar "$COMPLETE" --generation 3
expect_status 2 missing-parent check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/missing/out.json" --generation 3
if command -v mkfifo >/dev/null 2>&1; then
    mkfifo "$WORK/output/fifo.json"
    expect_status 2 fifo check "$COMPLETE" \
        --emit-typed-sidecar "$WORK/output/fifo.json" --generation 3
fi
for label in dash directory symlink source-output missing-parent
do
    assert_grep "$label.stderr" -q '^ETS01: ' "$WORK/$label.stderr"
done
assert_eq "contents of output/victim" "$(cat "$WORK/output/victim")" keep

expect_status 1 failed-plain check "$FAILED"
expect_status 1 failed check "$FAILED" \
    --emit-typed-sidecar "$WORK/output/failed.json" --generation 20
cmp "$WORK/failed-plain.stdout" "$WORK/failed.stdout"
cmp "$WORK/failed-plain.stderr" "$WORK/failed.stderr"
assert_file_empty "failed.stdout" "$WORK/failed.stdout"
assert_grep "failed.stderr" -Fq 'error[' "$WORK/failed.stderr"
assert_file_nonempty "output/failed.json" "$WORK/output/failed.json"
expect_status 1 failed-v3 check "$FAILED" --typed-sidecar-version 3 \
    --emit-typed-sidecar "$WORK/output/failed-v3.json" --generation 20
cmp "$WORK/failed.stdout" "$WORK/failed-v3.stdout"
cmp "$WORK/failed.stderr" "$WORK/failed-v3.stderr"
node --input-type=module - "$WORK/output/failed.json" "$WORK/output/failed-v3.json" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import { readTypedSidecar } from "./tooling/typed-sidecar/codec.mjs";
const result = readTypedSidecar(fs.readFileSync(process.argv[2]));
assert.equal(result.ok, true, result.error?.message);
assert.equal(result.document.completeness, "partial");
assert.equal(result.document.source_status, "failed");
assert.ok(result.document.diagnostics.some((item) => item.severity === "error"));
const v3 = readTypedSidecar(fs.readFileSync(process.argv[3]));
assert.equal(v3.ok, true, v3.error?.message);
assert.equal(v3.document.schema, "kofun.typed-sidecar/v3");
assert.equal(v3.document.completeness, "partial");
assert.equal(v3.document.source_status, "failed");
assert.deepEqual(v3.document.diagnostics, result.document.diagnostics);
assert.deepEqual(v3.document.declared_pure_functions, []);
NODE

cp "$WORK/output/complete.kofun-semantic.json" "$WORK/equal.before"
expect_status 3 equal-clean check "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/complete.kofun-semantic.json" \
    --generation 1
assert_grep "equal-clean.stderr" -q '^ETS05: ' "$WORK/equal-clean.stderr"
# This compared `equal-clean.stdout` with the accepting run's `ok:` line, to
# state that a tooling failure does not change the language channel. #1360
# keeps the intent and moves where it is read: a run that exits nonzero prints
# no `ok:`, because that line is a claim about the whole run and this run did
# not do what was asked. What must not change is the *verdict*, and that is
# asserted directly below by checking the same source again without the flag.
assert_file_empty "equal-clean.stdout" "$WORK/equal-clean.stdout"
expect_status 0 equal-clean-verdict check "$COMPLETE"
assert_grep "equal-clean-verdict.stdout" -Fx "ok: $COMPLETE" \
    "$WORK/equal-clean-verdict.stdout"
cmp "$WORK/equal.before" "$WORK/output/complete.kofun-semantic.json"

cp "$WORK/output/failed.json" "$WORK/equal-failed.before"
expect_status 1 equal-failed check "$FAILED" \
    --emit-typed-sidecar "$WORK/output/failed.json" --generation 20
cmp "$WORK/failed.stdout" "$WORK/equal-failed.stdout"
sed '$d' "$WORK/equal-failed.stderr" >"$WORK/equal-failed.language.stderr"
cmp "$WORK/failed.stderr" "$WORK/equal-failed.language.stderr"
tail -n 1 "$WORK/equal-failed.stderr" | grep -q '^ETS05: '
cmp "$WORK/equal-failed.before" "$WORK/output/failed.json"

printf '\303\050' >"$WORK/invalid-utf8.kofun"
expect_status 1 invalid-utf8 check "$WORK/invalid-utf8.kofun" \
    --emit-typed-sidecar "$WORK/output/invalid-utf8.json" --generation 1
assert_absent "output/invalid-utf8.json" "$WORK/output/invalid-utf8.json"

# The production adapter rejects its bounded declaration profile before
# entering an oversized observer transaction.  The public CLI must report one
# bounded ETS04 line, never an allocator/core diagnostic.
: >"$WORK/declaration-limit.kofun"
declaration=0
while test "$declaration" -le 64
do
    printf 'fn f%s(value: Int) -> Int { return value }\n' "$declaration" \
        >>"$WORK/declaration-limit.kofun"
    declaration=$((declaration + 1))
done
printf 'fn main() { print(42) }\n' >>"$WORK/declaration-limit.kofun"
set +e
run_kofun check "$WORK/declaration-limit.kofun" \
    >"$WORK/declaration-limit-plain.stdout" \
    2>"$WORK/declaration-limit-plain.stderr"
declaration_plain_status=$?
run_kofun check "$WORK/declaration-limit.kofun" \
    --emit-typed-sidecar "$WORK/output/declaration-limit.json" \
    --generation 1 \
    >"$WORK/declaration-limit.stdout" \
    2>"$WORK/declaration-limit.stderr"
declaration_sidecar_status=$?
set -e
if test "$declaration_plain_status" -eq 0; then
    test "$declaration_sidecar_status" -eq 3 ||
        fail "clean declaration-limit check did not return tooling status"
else
    test "$declaration_sidecar_status" -eq "$declaration_plain_status" ||
        fail "declaration-limit check changed the source failure status"
fi
# #1360. This run exits 3, so it prints no `ok:`. It used to print one, and
# the three signals disagreed: stdout said the program was fine, stderr said
# the projection failed, and the exit code said the check failed. The plain
# run below is what states the verdict is unchanged.
assert_file_empty "declaration-limit.stdout" "$WORK/declaration-limit.stdout"
test "$declaration_plain_status" -ne 0 ||
    assert_grep "declaration-limit-plain.stdout" \
        -Fx "ok: $WORK/declaration-limit.kofun" \
        "$WORK/declaration-limit-plain.stdout"
plain_stderr_lines=$(wc -l <"$WORK/declaration-limit-plain.stderr")
head -n "$plain_stderr_lines" "$WORK/declaration-limit.stderr" \
    >"$WORK/declaration-limit.language.stderr"
cmp "$WORK/declaration-limit-plain.stderr" \
    "$WORK/declaration-limit.language.stderr"
# The diagnostic has to start an investigation. `ETS04` alone named neither
# which of the two limits was reached, nor the bound, nor where, so the first
# thing anyone did with it was bisect the source -- the work the message
# exists to save.
tail -n 1 "$WORK/declaration-limit.stderr" >"$WORK/declaration-limit.ets04"
assert_grep "declaration-limit ETS04 names the limit, count, offset, and bound" \
    -Eq -- '^ETS04: declaration limit exceeded: fn tokens reached 65 at byte [0-9]+; this producer projects at most 64$' \
    "$WORK/declaration-limit.ets04"
# The offset is the token that crossed the limit, not the start of the file.
declaration_limit_offset=$(sed -n 's/.*at byte \([0-9][0-9]*\);.*/\1/p' \
    "$WORK/declaration-limit.ets04")
test -n "$declaration_limit_offset" ||
    fail 'the ETS04 detail carried no byte offset'
dd if="$WORK/declaration-limit.kofun" bs=1 \
    skip="$declaration_limit_offset" count=2 2>/dev/null \
    >"$WORK/declaration-limit.at-offset"
assert_grep "the ETS04 offset lands on a fn token" \
    -Fx -- 'fn' "$WORK/declaration-limit.at-offset"
! grep -Eq 'double free|free\\(\\)|Aborted|core dumped|sanitizer' \
    "$WORK/declaration-limit.stderr" ||
    fail "declaration-limit path exposed a process abort"
assert_absent "output/declaration-limit.json" \
    "$WORK/output/declaration-limit.json"

# One `fn` token fewer projects, so the refusal above is the limit itself and
# not something about a file of generated declarations.
: >"$WORK/within-profile.kofun"
declaration=0
while test "$declaration" -lt 63
do
    printf 'fn g%s(value: Int) -> Int { return value }\n' "$declaration" \
        >>"$WORK/within-profile.kofun"
    declaration=$((declaration + 1))
done
printf 'fn main() { print(42) }\n' >>"$WORK/within-profile.kofun"
expect_status 0 within-profile check "$WORK/within-profile.kofun" \
    --emit-typed-sidecar "$WORK/output/within-profile.json" --generation 1
assert_grep "within-profile.stdout" -Fx "ok: $WORK/within-profile.kofun" \
    "$WORK/within-profile.stdout"
assert_file_empty "within-profile.stderr" "$WORK/within-profile.stderr"
assert_file_nonempty "output/within-profile.json" \
    "$WORK/output/within-profile.json"

expect_status 2 build-reject build "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/build.json" --generation 1
expect_status 2 run-reject run "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/run.json" --generation 1
expect_status 2 test-reject test "$COMPLETE" \
    --emit-typed-sidecar "$WORK/output/test.json" --generation 1
expect_status 2 package-reject package lock \
    --emit-typed-sidecar "$WORK/output/package.json" --generation 1

run_kofun check "$ROOT/bootstrap/fixtures/answer.kofun" \
    >"$WORK/no-flag-a.stdout" 2>"$WORK/no-flag-a.stderr"
run_kofun check "$ROOT/bootstrap/fixtures/answer.kofun" \
    >"$WORK/no-flag-b.stdout" 2>"$WORK/no-flag-b.stderr"
cmp "$WORK/no-flag-a.stdout" "$WORK/no-flag-b.stdout"
cmp "$WORK/no-flag-a.stderr" "$WORK/no-flag-b.stderr"
assert_absent "$ROOT/bootstrap/fixtures/answer.kofun-semantic.json" \
    "$ROOT/bootstrap/fixtures/answer.kofun-semantic.json"


printf '%s\n' \
    'PASS: typed-sidecar CLI grammar, exact fallback channels, races, exit precedence, no-flag compatibility, and one agreeing set of signals when a program is outside the declaration profile'
