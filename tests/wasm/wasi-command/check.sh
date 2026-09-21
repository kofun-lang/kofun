#!/bin/sh
# Gate the wasm32-wasi-command1 target's minimal command shape.
#
# #1296 says the focused gate "must execute the module, inspect its binary
# sections independently, mutate manifest/import/profile bytes, and assert no
# artifact for every refusal; source-text grep is insufficient." All four
# clauses apply: the section reader below decodes the module rather than
# trusting the emitter's own account of it, the manifest is mutated four ways
# (three of #1293's refusals and one non-canonical spelling), and every refusal
# -- including a forced LATE write failure and an output path that is a
# directory -- is shown to leave no artifact, not merely to exit non-zero.
#
# WHAT THIS DOES NOT COVER, because the profile says it cannot yet: a program
# that reaches a checked operation. #1293 §"The binding constraint" has `build`
# refuse the root/environment carrier until #1242-#1246 exist, so every host
# operation is refused here, at the operation's span, and the import projection
# for reachable operations is the adapter issues' (#1297-#1301) once that
# carrier lands. A gate that accepted a `print` today would be accepting the
# ambient-builtin Option B the contract rejected.
#
# The load-bearing assertion is the *absence* of an import section. #1293's
# projection contract states that a program reaching no checked operation emits
# no import, and an import added "just in case" would still run — it would only
# make the module's declared surface wider than its behaviour, which is the one
# thing a reader of the binary cannot detect by running it.
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${KOFUN_WASI_COMMAND_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}wasi-command"}
KOFUN_ROOT=$ROOT
KOFUN_WORK=$WORK
export KOFUN_ROOT KOFUN_WORK
ASSERT_CONTEXT='wasi command'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

printf 'fn main() {\n    let unused: Int = 1 + 1\n}\n' >"$WORK/command.kofun"
# The print is on line 3 on purpose: the refusal has to name the operation's
# span (#1293 §5), and a fixture whose only print is on line 1 cannot tell
# "line 1" from "the operation's line".
printf 'fn main() {\n    let unused: Int = 1\n    print(42)\n}\n' >"$WORK/prints.kofun"

"$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/command.wasm" >/dev/null

assert_file_nonempty "command module" "$WORK/command.wasm"

# An independent section decoder. It reads the binary rather than asking the
# emitter what it wrote, because those are different claims.
node "$ROOT/tests/wasm/wasi-command/inspect.mjs" "$WORK/command.wasm" \
    >"$WORK/sections.txt"

assert_grep "one exported memory" -Fx "export memory memory" "$WORK/sections.txt"
assert_grep "_start is exported as a function" -Fx "export _start func" "$WORK/sections.txt"
assert_grep "the profile version global is exported" -Fx "export kofun_wasi_command_version global" "$WORK/sections.txt"
assert_grep "memory section present" -Fx "section memory" "$WORK/sections.txt"

if grep -qx "section import" "$WORK/sections.txt"; then
    printf '%s\n' \
        "FAIL: wasi command: a program with no host operation declared an import section" >&2
    exit 1
fi
if grep -qx "export main func" "$WORK/sections.txt"; then
    printf '%s\n' \
        "FAIL: wasi command: main is exported; a command is entered through _start" >&2
    exit 1
fi

# #1098's normative validator, which is the strictest reading available and the
# one that caught this emitter's first version: it produced memory and `_start`,
# looked right against the profile document, and was refused for the missing
# `kofun_wasi_command_version` global. A hand-written checklist of profile
# requirements is the artifact that drifts from the profile; this cannot.
node "$ROOT/tests/wasm/wasi-command/validate.mjs" "$WORK/command.wasm" \
    >"$WORK/validated.txt"
assert_grep "the normative validator accepts the module" \
    -Fx "exports memory,kofun_wasi_command_version,_start" "$WORK/validated.txt"

# Determinism. A module that is not byte-identical across builds cannot be
# bound into artifact identity, which #1296 requires of it.
"$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/again.wasm" >/dev/null
cmp "$WORK/command.wasm" "$WORK/again.wasm"

# Execution on a real Preview 1 host, which is the half a section reader cannot
# stand in for: a structurally valid module that traps on entry is still broken.
node "$ROOT/tests/wasm/wasi-command/run.mjs" "$WORK/command.wasm" \
    >"$WORK/run.txt" 2>&1 ||
    {
        printf '%s\n' "FAIL: wasi command: the module did not run: $(cat "$WORK/run.txt")" >&2
        exit 1
    }
assert_grep "the host reports no imports" -Fx "imports 0" "$WORK/run.txt"
assert_grep "_start returns cleanly" -Fx "exit 0" "$WORK/run.txt"

# Refusals leave no artifact. A half-written module is worse than none: it is a
# file a later step will happily read.
set +e
"$ROOT/bin/kofun" build "$WORK/prints.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/prints.wasm" \
    >"$WORK/prints.stdout" 2>"$WORK/prints.stderr"
prints_status=$?
set -e
assert_num "a host operation is refused in this slice" "$prints_status" -ne 0
assert_grep "the refusal says what to do" -F "no host operations in this slice" \
    "$WORK/prints.stderr"
assert_grep "the refusal is at the operation's span, not line 1" -F "line 3:" \
    "$WORK/prints.stderr"
assert_absent "no artifact from a refused build" "$WORK/prints.wasm"

# Late-failure atomicity, #1296's sixth criterion, in the two shapes a write
# can fail. Both used to leave something behind: the directory case moved a
# COMPLETE module into the directory under its temporary name and exited 0.
#
# First, an output path that is a directory. Refused by name before anything
# is written, and the directory stays empty.
mkdir -p "$WORK/taken.wasm"
set +e
"$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/taken.wasm" \
    >"$WORK/taken.stdout" 2>"$WORK/taken.stderr"
taken_status=$?
set -e
assert_num "an output path that is a directory is refused" "$taken_status" -ne 0
assert_grep "the refusal names the shape" -F "is a directory" "$WORK/taken.stderr"
assert_num "nothing was moved into the directory" \
    "$(find "$WORK/taken.wasm" -mindepth 1 | wc -l | tr -d ' ')" -eq 0

# Second, a failure AFTER lowering, during the write itself -- the only way to
# prove that is to force one, so the emitter carries an announced seam that
# writes half the module and fails. No module, and no temporary either: the
# driver's trap and the emitter's own cleanup are both exercised.
set +e
KOFUN_WASM_CORE_FAULT=write "$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/faulted.wasm" \
    >"$WORK/faulted.stdout" 2>"$WORK/faulted.stderr"
faulted_status=$?
set -e
assert_num "a forced late write failure is a failure" "$faulted_status" -ne 0
assert_grep "the seam announced itself" -F "KOFUN_WASM_CORE_FAULT=write is set" \
    "$WORK/faulted.stderr"
assert_absent "no partial artifact from a late failure" "$WORK/faulted.wasm"
assert_num "no temporary survives a late failure" \
    "$(find "$WORK" -maxdepth 1 -name 'faulted.wasm.tmp.*' | wc -l | tr -d ' ')" -eq 0

# The manifest. #1296 asks for "malformed/unknown manifest data" to be refused
# before publication, and the refusals are #1293's vocabulary by name — a caller
# fixing `UnknownCapabilityKey` does something different from one fixing
# `IncompleteManifest`, and one message for both makes them guess.
#
# The validator calls the projection model's `project` rather than restating its
# rules, for the reason the normative-validator assertion above exists.
node -e '
const fs = require("node:fs");
import("'"$ROOT"'/spec/wasi-command-profile-v1/model.mjs").then((m) => {
    // Every manifest is written with the model function `canonical()`: #1293
    // section 4 byte-freezes the format, and the validator refuses any other
    // spelling, so a pretty-printed fixture here would be refused for the
    // wrong reason and the case it was meant to prove would never be reached.
    const manifest = m.makeManifest([]);
    manifest.memoryPages = 16;
    fs.writeFileSync("'"$WORK"'/manifest.json", m.canonical(manifest));
    const unknown = JSON.parse(JSON.stringify(manifest));
    unknown.capabilities.telepathy = true;
    fs.writeFileSync("'"$WORK"'/unknown.json", m.canonical(unknown));
    const incomplete = JSON.parse(JSON.stringify(manifest));
    delete incomplete.capabilities.random;
    fs.writeFileSync("'"$WORK"'/incomplete.json", m.canonical(incomplete));
    const pages = JSON.parse(JSON.stringify(manifest));
    pages.memoryPages = 0;
    fs.writeFileSync("'"$WORK"'/pages.json", m.canonical(pages));
    // The same manifest, spelled differently. Its SHA-256 binds into the
    // artifact, so two spellings of one set of grants would be two artifact
    // identities; the only honest answer is to refuse the second spelling.
    fs.writeFileSync("'"$WORK"'/pretty.json", JSON.stringify(manifest, null, 2) + "\n");
});
'

"$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 --wasi-manifest "$WORK/manifest.json" \
    -o "$WORK/granted.wasm" >/dev/null

# Deliberately NOT `cmp` against the manifest-less module. Supplying a manifest
# binds its digest into the artifact, so the two differ by design — an earlier
# version of this gate asserted they were identical, which was true only while
# the manifest bound nothing.
node "$ROOT/tests/wasm/wasi-command/validate.mjs" "$WORK/granted.wasm" >/dev/null

# Each refusal by its own name, and none of them writes a module. Two refusals
# sharing a message would mean the tool cannot tell the two mistakes apart.
for case in unknown:UnknownCapabilityKey incomplete:IncompleteManifest pages:InvalidMemoryCeiling pretty:NonCanonicalManifest; do
    name=${case%%:*}
    code=${case#*:}
    set +e
    "$ROOT/bin/kofun" build "$WORK/command.kofun" \
        --target wasm32-wasi-command1 --wasi-manifest "$WORK/$name.json" \
        -o "$WORK/$name.wasm" >"$WORK/$name.stdout" 2>"$WORK/$name.stderr"
    manifest_status=$?
    set -e
    assert_num "$name manifest is refused" "$manifest_status" -ne 0
    assert_grep "$name manifest names $code" -F "$code:" "$WORK/$name.stderr"
    assert_absent "$name manifest leaves no artifact" "$WORK/$name.wasm"
done

# Artifact identity. The binding is only real if changing the manifest changes
# the artifact, so this asserts *distinguishability* rather than the presence of
# a section — a section present but constant would satisfy a presence check and
# bind nothing.
#
# Three states, three digests: no manifest at all, a manifest granting nothing,
# and a manifest granting one capability. "No grants" and "no manifest" are
# different statements and a reader must be able to tell them apart.
node -e '
const fs = require("node:fs");
import(process.env.KOFUN_ROOT + "/spec/wasi-command-profile-v1/model.mjs").then((m) => {
    const none = m.makeManifest([]);
    none.memoryPages = 16;
    fs.writeFileSync(process.env.KOFUN_WORK + "/grant-none.json", m.canonical(none));
    const stdout = m.makeManifest(["stdout"]);
    stdout.memoryPages = 16;
    fs.writeFileSync(process.env.KOFUN_WORK + "/grant-stdout.json", m.canonical(stdout));
});
'

"$ROOT/bin/kofun" build "$WORK/command.kofun" --target wasm32-wasi-command1 \
    --wasi-manifest "$WORK/grant-none.json" -o "$WORK/grant-none.wasm" >/dev/null
"$ROOT/bin/kofun" build "$WORK/command.kofun" --target wasm32-wasi-command1 \
    --wasi-manifest "$WORK/grant-stdout.json" -o "$WORK/grant-stdout.wasm" >/dev/null

if cmp -s "$WORK/grant-none.wasm" "$WORK/grant-stdout.wasm"; then
    printf '%s\n' \
        "FAIL: wasi command: two manifests differing in one grant produced the same module" >&2
    exit 1
fi
if cmp -s "$WORK/command.wasm" "$WORK/grant-none.wasm"; then
    printf '%s\n' \
        "FAIL: wasi command: a module built with no manifest matches one built with an all-false manifest" >&2
    exit 1
fi

# And it stays deterministic with a manifest, or the identity is noise.
"$ROOT/bin/kofun" build "$WORK/command.kofun" --target wasm32-wasi-command1 \
    --wasi-manifest "$WORK/grant-stdout.json" -o "$WORK/grant-again.wasm" >/dev/null
cmp "$WORK/grant-stdout.wasm" "$WORK/grant-again.wasm"

# The identity section must not disturb what the validator reads.
node "$ROOT/tests/wasm/wasi-command/validate.mjs" "$WORK/grant-stdout.wasm" \
    >"$WORK/validated-identity.txt"
assert_grep "the module with an identity section still validates" \
    -Fx "exports memory,kofun_wasi_command_version,_start" "$WORK/validated-identity.txt"

# The other two targets are untouched. Their bytes are the evidence other gates
# pin, so a change here that moved them would be caught there and blamed on the
# wrong commit.
"$ROOT/bin/kofun" build "$ROOT/examples/wasm_arithmetic.kofun" \
    --target wasm32 -o "$WORK/legacy.wasm" >/dev/null
node "$ROOT/tests/wasm/wasi-command/inspect.mjs" "$WORK/legacy.wasm" \
    >"$WORK/legacy.txt"
assert_grep "wasm32 still exports main" -Fx "export main func" "$WORK/legacy.txt"
assert_grep "wasm32 still imports its host functions" -Fx "section import" \
    "$WORK/legacy.txt"

printf '%s\n' \
    "PASS: a wasm32-wasi-command1 command satisfies #1098's normative validator, imports nothing, runs on a Preview 1 host, refuses each malformed or non-canonical manifest by name, refuses a host operation at its span, leaves no artifact on a late write failure, and binds the manifest into its bytes"
