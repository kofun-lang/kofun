#!/bin/sh
set -eu

# The import boundary between generated raw bindings and reviewed code (#1217,
# RFC-0012 steps 5-6).
#
# `../check.sh` proves the generator: that one header becomes one module and
# one report, deterministically, with the ABI facts checked against the C
# compiler. It proves nothing about who may import the result, because until
# #1217 nothing could: the generated module carried its trust as a comment and
# a JSON field, and neither is read by anything that resolves an import.
#
# This gate proves the crossing. Its positive case is the three-module chain
# RFC-0012 describes — generated raw bindings, a hand-written reviewed facade,
# an ordinary consumer — built and run by the toolchain a user invokes. Its
# negatives are the point: each one is a way of reaching the raw module without
# writing the crossing down, and each must fail closed.
#
#   ordinary import          E2S171   the crossing is not recorded
#   aliased import           E2S171   an alias is not a crossing either
#   renamed copy             E2S171   `.raw.` is a convention, the `trust`
#                                     line is the authority -- this is the
#                                     fixture that distinguishes RFC-0012
#                                     from the status quo it replaced
#   trusted import of an
#     ordinary module        E2S172   the marker is not decorative
#   trust line removed       E2S174   the class is required, not inferred
#
# Two shapes are deliberately NOT asserted here, and saying why is part of the
# gate. A selective import (`from ffi.kbscale import ...`) and a public
# re-export (`pub import ffi.kbscale`) are both refused on this path with
# `E2S59` -- but so is the same syntax against an *ordinary* module, because
# the module-resolving build path does not implement either form. A negative
# that refuses for a reason unrelated to trust proves nothing about trust. The
# raw-origin re-export refusal (`E2S173`) is owned and gated by
# `tests/conformance/modules/raw-re-exports/`, which runs the resolver that
# implements re-exports.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/interop/bindgen-c/import-boundary"
ASSERT_CONTEXT="bindgen-c import-boundary"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-bindgen-boundary.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'bindgen-c import-boundary: FAIL: %s\n' "$*" >&2
    exit 1
}

for required in clang node; do
    command -v "$required" >/dev/null 2>&1 ||
        fail "required tool unavailable: $required"
done

# ------------------------------------------------- generate the raw module

node "$ROOT/tooling/bindgen-c/bindgen-c.mjs" "$CASES/fixture/kbscale.h" \
    --out-dir "$WORK/generated" --module ffi.kbscale \
    >"$WORK/bindgen.stdout" 2>"$WORK/bindgen.stderr" ||
    fail "bindgen failed: $(cat "$WORK/bindgen.stderr")"

module=$WORK/generated/ffi/kbscale.raw.kofun
report=$WORK/generated/kbscale.bindgen.json
assert_regular_file 'generated raw module' "$module"
assert_regular_file 'generated audit report' "$report"

# The declaration is the first thing in the file, before the banner. A comment
# may precede a module header and the compiler accepts either order; first is
# what makes the class the first thing a reader and a diff both see.
head -2 "$module" >"$WORK/header.actual"
printf 'module ffi.kbscale\ntrust raw-foreign\n' >"$WORK/header.expected"
cmp "$WORK/header.expected" "$WORK/header.actual" ||
    fail 'the generated module does not begin with its module header and trust class'

# The dotted path decides the directory, so the file lands where a package root
# expects it without the caller moving it.
assert_absent 'the flat pre-#1217 filename' "$WORK/generated/ffi.kbscale.raw.kofun"

# Every bound declaration is `pub`: a raw module exists to be consumed through
# a facade, and one that is not `pub` cannot be.
assert_num 'every bound declaration is exported' \
    "$(grep -c '^pub extern "C" fn ' "$module")" -eq 2
assert_num 'no bound declaration is left unexported' \
    "$(grep -c '^extern "C" fn ' "$module")" -eq 0

# The report records the class the language reads, the path, and the digest of
# the exact bytes written -- recomputed here rather than trusted.
node -e '
const fs = require("node:fs");
const crypto = require("node:crypto");
const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const bytes = fs.readFileSync(process.argv[2]);
const digest = crypto.createHash("sha256").update(bytes).digest("hex");
const problems = [];
if (report.module.path !== "ffi.kbscale") problems.push("module.path");
if (report.module.file !== "ffi/kbscale.raw.kofun") problems.push("module.file");
if (report.module.trust_class !== "raw-foreign") problems.push("module.trust_class");
if (report.module.trust !== "raw-trusted-foreign") problems.push("module.trust");
if (report.module.sha256 !== digest) problems.push("module.sha256");
if (problems.length) {
  process.stderr.write("report fields wrong: " + problems.join(" ") + "\n");
  process.exit(1);
}
' "$report" "$module" ||
    fail 'the report does not record the module path, class, and exact digest'

# ------------------------------------------------------- the fixture library

clang -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC \
    "$CASES/fixture/kbscale.c" -o "$WORK/libkbscale.so" ||
    fail 'fixture library did not compile'

# ------------------------------------------- the package root, three modules

build_root() {
    rm -rf "$WORK/pkg"
    mkdir -p "$WORK/pkg/lib" "$WORK/pkg/app"
    cp -R "$WORK/generated/ffi" "$WORK/pkg/ffi"
    cp "$CASES/facade.kofun" "$WORK/pkg/lib/facade.kofun"
}

# Each attempt gets a fresh artifact path, so "no artifact" is a statement
# about this run rather than about whether a previous one cleaned up.
attempt=0
build_program() {
    attempt=$((attempt + 1))
    program=$WORK/program.$attempt
    set +e
    "$ROOT/bin/kofun" build "$WORK/pkg/app/main.kofun" --backend c \
        --link-library "$WORK/libkbscale.so" -o "$program" \
        >"$WORK/build.$attempt.stdout" 2>"$WORK/build.$attempt.stderr"
    build_status=$?
    set -e
}

refuses() {
    label=$1
    code=$2
    build_program
    assert_num "$label exit status" "$build_status" -eq 1
    assert_absent "$label wrote an artifact" "$program"
    # `bin/kofun` relays the resolver's own stdout to stderr, so the refusal
    # arrives there whichever stream the resolver wrote it on. Both are
    # searched rather than guessing, and the empty-other-stream check is not
    # made: this gate is about the boundary, and `../check.sh` owns stream
    # discipline for the generator.
    cat "$WORK/build.$attempt.stdout" "$WORK/build.$attempt.stderr" \
        >"$WORK/build.$attempt.output"
    assert_grep "$label diagnostic" -Fq -- "error[$code]:" \
        "$WORK/build.$attempt.output"
}

build_root
cp "$CASES/app_facade.kofun" "$WORK/pkg/app/main.kofun"
build_program
test "$build_status" -eq 0 ||
    fail "the facade chain did not build: $(cat "$WORK/build.$attempt.stderr")"
assert_regular_file 'the facade chain produced a program' "$program"

set +e
"$program"
program_status=$?
set -e
assert_num 'the facade chain runs and doubles 21' "$program_status" -eq 42

# The consumer reaches the raw module only through the facade: it names the
# facade and nothing else.
assert_grep 'the consumer imports the facade' -Fq -- 'import lib.facade' \
    "$CASES/app_facade.kofun"
if grep -Fq 'ffi.kbscale' "$CASES/app_facade.kofun"; then
    fail 'the consumer names the raw module directly'
fi

# ------------------------------------------------------------- the negatives

build_root
cp "$CASES/app_ordinary.kofun" "$WORK/pkg/app/main.kofun"
refuses 'an ordinary import of the raw module' E2S171

build_root
cp "$CASES/app_alias.kofun" "$WORK/pkg/app/main.kofun"
refuses 'an aliased import of the raw module' E2S171

# The fixture RFC-0012 exists for. `.raw.` is a filename convention and carries
# no authority; renaming the generated file changes nothing, because the class
# is the `trust` line inside it. A design that kept the marker in the name
# would accept this program.
build_root
mv "$WORK/pkg/ffi/kbscale.raw.kofun" "$WORK/pkg/ffi/kbscale.kofun"
cp "$CASES/app_ordinary.kofun" "$WORK/pkg/app/main.kofun"
refuses 'an ordinary import of a renamed copy' E2S171

build_root
cp "$CASES/app_trusted_ordinary.kofun" "$WORK/pkg/app/main.kofun"
refuses 'a trusted import of an ordinary module' E2S172

# The class is required rather than inferred: strip the line the generator
# writes and the same declarations stop being admissible at all.
build_root
grep -v '^trust raw-foreign$' "$WORK/pkg/ffi/kbscale.raw.kofun" \
    >"$WORK/untrusted.kofun"
mv "$WORK/untrusted.kofun" "$WORK/pkg/ffi/kbscale.raw.kofun"
cp "$CASES/app_facade.kofun" "$WORK/pkg/app/main.kofun"
refuses 'a raw module with its trust line removed' E2S174

printf '%s\n' \
    'PASS: the generated module declares its own path and trust class, and the report records both plus the digest of the exact bytes' \
    'PASS: generated raw bindings, a reviewed facade, and an ordinary consumer build and run as three modules' \
    'PASS: ordinary, aliased, and renamed-copy reaches of the raw module each fail closed with E2S171 and write no artifact' \
    'PASS: the trusted marker is refused on an ordinary module and the trust class is required rather than inferred'
