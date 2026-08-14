#!/bin/sh
# Gate the wasm32-wasi-command1 target's minimal command shape.
#
# #1296 says the focused gate "must execute the module, inspect its binary
# sections independently, mutate manifest/import/profile bytes, and assert no
# artifact for every refusal; source-text grep is insufficient." This slice
# covers the no-host-operation path, so there is no manifest to mutate yet — but
# the other three clauses apply in full, and the section reader below decodes
# the module rather than trusting the emitter's own account of it.
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
printf 'fn main() {\n    print(42)\n}\n' >"$WORK/prints.kofun"

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
assert_absent "no artifact from a refused build" "$WORK/prints.wasm"

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
    const manifest = m.makeManifest([]);
    manifest.memoryPages = 16;
    fs.writeFileSync("'"$WORK"'/manifest.json", JSON.stringify(manifest, null, 2) + "\n");
    const unknown = JSON.parse(JSON.stringify(manifest));
    unknown.capabilities.telepathy = true;
    fs.writeFileSync("'"$WORK"'/unknown.json", JSON.stringify(unknown, null, 2));
    const incomplete = JSON.parse(JSON.stringify(manifest));
    delete incomplete.capabilities.random;
    fs.writeFileSync("'"$WORK"'/incomplete.json", JSON.stringify(incomplete, null, 2));
    const pages = JSON.parse(JSON.stringify(manifest));
    pages.memoryPages = 0;
    fs.writeFileSync("'"$WORK"'/pages.json", JSON.stringify(pages, null, 2));
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
for case in unknown:UnknownCapabilityKey incomplete:IncompleteManifest pages:InvalidMemoryCeiling; do
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
    fs.writeFileSync(process.env.KOFUN_WORK + "/grant-none.json", JSON.stringify(none, null, 2) + "\n");
    const stdout = m.makeManifest(["stdout"]);
    stdout.memoryPages = 16;
    fs.writeFileSync(process.env.KOFUN_WORK + "/grant-stdout.json", JSON.stringify(stdout, null, 2) + "\n");
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
    "PASS: a wasm32-wasi-command1 command satisfies #1098's normative validator, imports nothing, runs on a Preview 1 host, and refuses each malformed manifest by name, and binds the manifest into its bytes"
