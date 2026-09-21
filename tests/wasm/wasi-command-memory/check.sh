#!/bin/sh
# Gate #1297: wasm32-wasi-command1 command memory.
#
# The runtime under test is the adapter-private storage the WASI operation
# slices will hand to `wasi_snapshot_preview1`: byte sequences, pointer
# vectors, iovec vectors, checked UTF-8 conversion, and the command-lifetime
# allocator behind them. The issue asks that the gate "execute canary-protected
# memory fixtures and mutations, not merely inspect generated constants", and
# that independent layout calculations agree with what is emitted. So:
#
# - the layout is computed three ways — by JavaScript from first principles,
#   by a C probe compiled against the header the emitter uses, and by the
#   running module — and all three must agree (`memory_check.mjs`);
# - every property drives the exported runtime under a real engine against
#   canary-filled memory and reads bytes back;
# - the emitter carries four announced seams, each removing one check, and
#   each is shown to be caught by exactly the property that guards it;
# - the module the runtime lives in still satisfies #1098's normative
#   validator and runs on a Preview 1 host, so the runtime has not widened the
#   command shape it will be emitted into.
#
# WHAT THIS DOES NOT CLAIM: no argv, environment, stdio, clock, random, or
# path operation is implemented here (the probe imports nothing, and the
# validator confirms it), and none of this is the public Kofun `Bytes`
# identity. The production `build` path does not carry the runtime yet — a
# program still cannot reach a host operation in this slice — and the one
# production change here is that a manifest's page ceiling now becomes the
# command module's memory maximum, which the gate checks at the end.
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${KOFUN_WASI_COMMAND_MEMORY_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}wasi-command-memory"}
CC=${CC:-cc}
KOFUN_ROOT=$ROOT
KOFUN_WORK=$WORK
export KOFUN_ROOT KOFUN_WORK
ASSERT_CONTEXT='wasi command memory'
. "$ROOT/tests/assertions/assert.sh"

for tool in "$CC" node cmp "$ROOT/bin/kofun-digest"
do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "wasi command memory gate requires $tool" >&2
        exit 1
    }
done

rm -rf "$WORK"
mkdir -p "$WORK/first" "$WORK/second"

HERE="$ROOT/tests/wasm/wasi-command-memory"
PAGES=4

# The emitter, twice: optimized, and instrumented. The probe must be
# byte-identical between them, and the instrumented one must be clean, or the
# bytes are an accident of one compiler configuration.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/wasm/compiler.c" -o "$WORK/compiler-sanitized"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$HERE/layout_probe.c" -o "$WORK/layout-probe"

"$WORK/compiler" --wasi-command1-memory-probe "$WORK/first/probe.wasm" "$PAGES"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/compiler-sanitized" --wasi-command1-memory-probe "$WORK/sanitized.wasm" "$PAGES"
cmp "$WORK/first/probe.wasm" "$WORK/sanitized.wasm"

# Determinism across working directories: the second build runs from a
# different directory with a different output path, and the bytes must not
# know. Then neither path may appear in the artifact at all.
(cd "$WORK/second" && "$WORK/compiler" --wasi-command1-memory-probe "./probe.wasm" "$PAGES")
cmp "$WORK/first/probe.wasm" "$WORK/second/probe.wasm"
assert_num "no host path enters the module bytes" \
    "$(grep -c -F "$WORK" "$WORK/first/probe.wasm" || true)" -eq 0
assert_num "no home path enters the module bytes" \
    "$(grep -c -F "${HOME:-/nonexistent}" "$WORK/first/probe.wasm" || true)" -eq 0

# The layout, from the header the emitter compiles against.
"$WORK/layout-probe" "$PAGES" 0 1 7 255 4096 >"$WORK/layout.txt"
assert_grep "the probe prints the arena base" -Fx "arena_base 1024" "$WORK/layout.txt"

# The properties, under the engine.
node "$HERE/memory_check.mjs" "$WORK/first/probe.wasm" "$WORK/layout.txt" "$PAGES" \
    >"$WORK/properties.txt"
assert_grep "twelve properties hold" -Fx \
    "PASS: 12 command-memory properties hold under the engine" "$WORK/properties.txt"

# The probe is still a command in every respect #1098's validator reads, so the
# runtime has not widened the shape it will be emitted into: one exported
# memory, the version global, `_start`, and — the load-bearing part — no
# imports, because no operation is implemented by this carrier-only slice.
node "$ROOT/tests/wasm/wasi-command/validate.mjs" "$WORK/first/probe.wasm" \
    >"$WORK/validated.txt"
assert_grep "the normative validator accepts the probe" \
    -Fx "exports memory,kofun_wasi_command_version,_start" "$WORK/validated.txt"
node "$ROOT/tests/wasm/wasi-command/inspect.mjs" "$WORK/first/probe.wasm" \
    >"$WORK/sections.txt"
assert_not_grep "the probe declares no import section" -Fx "section import" "$WORK/sections.txt"
assert_grep "the probe's memory maximum is the page ceiling" \
    -Fx "memory min 1 max $PAGES" "$WORK/sections.txt"
node "$ROOT/tests/wasm/wasi-command/run.mjs" "$WORK/first/probe.wasm" \
    >"$WORK/run.txt" 2>&1 ||
    {
        printf '%s\n' "FAIL: wasi command memory: the probe did not run: $(cat "$WORK/run.txt")" >&2
        exit 1
    }
assert_grep "the Preview 1 host sees no imports" -Fx "imports 0" "$WORK/run.txt"
assert_grep "_start returns cleanly with the runtime present" -Fx "exit 0" "$WORK/run.txt"

# Each seam removes one check. The property that guards that check must be
# the one that fails, by name, and the seam must announce itself. Two seams
# caught by the same property would mean the gate cannot tell the mistakes
# apart, which is a failure of the gate, not a pass.
for case in memory-align:alloc-alignment \
            memory-scope-zero:scope-lifetime \
            memory-iovec-range:iovecs \
            memory-utf8-overlong:utf8-conversion; do
    seam=${case%%:*}
    guard=${case#*:}
    KOFUN_WASM_CORE_FAULT=$seam "$WORK/compiler" \
        --wasi-command1-memory-probe "$WORK/$seam.wasm" "$PAGES" 2>"$WORK/$seam.emit.stderr"
    assert_grep "the $seam seam announces itself" \
        -F "KOFUN_WASM_CORE_FAULT=$seam is set" "$WORK/$seam.emit.stderr"
    if cmp -s "$WORK/first/probe.wasm" "$WORK/$seam.wasm"; then
        printf '%s\n' "FAIL: wasi command memory: the $seam seam changed nothing" >&2
        exit 1
    fi
    set +e
    node "$HERE/memory_check.mjs" "$WORK/$seam.wasm" "$WORK/layout.txt" "$PAGES" \
        >"$WORK/$seam.stdout" 2>"$WORK/$seam.stderr"
    mutated_status=$?
    set -e
    assert_num "the $seam seam is caught" "$mutated_status" -ne 0
    assert_grep "the $seam seam is caught by $guard and nothing before it" \
        -F "FAIL: $guard:" "$WORK/$seam.stderr"
    assert_not_grep "the $guard property did not pass under $seam" \
        -Fx "PASS: $guard" "$WORK/$seam.stdout"
done

# Existing profiles keep their bytes. The hostabi1 empty module and the legacy
# wasm32 sample are pinned by digest, measured before this runtime existed;
# their own gates check semantics, this checks that nothing moved.
"$WORK/compiler" --hostabi1 "$ROOT/bootstrap/wasm/fixtures/hostabi1_empty.kofun" \
    "$WORK/hostabi1-empty.wasm"
assert_eq "wasm32-hostabi1 empty module digest" \
    "$("$ROOT/bin/kofun-digest" "$WORK/hostabi1-empty.wasm" | cut -d ' ' -f 1)" \
    4ffbb355c39e1f4cad8a707b143b22d61b9eb59184428904b0f89b17fa62f4af
"$WORK/compiler" "$ROOT/examples/wasm_arithmetic.kofun" "$WORK/legacy.wasm"
assert_eq "legacy wasm32 sample digest" \
    "$("$ROOT/bin/kofun-digest" "$WORK/legacy.wasm" | cut -d ' ' -f 1)" \
    ead99da7862aee50ec77099e16d8382cd5ef3b75920136c78734e788525856da

# The production change: a manifest's page ceiling is the command module's
# memory maximum, through `bin/kofun`, and without a manifest the module keeps
# its single fixed page. The probe is never what `build` produces.
printf 'fn main() {\n    let unused: Int = 1 + 1\n}\n' >"$WORK/command.kofun"
node -e '
const fs = require("node:fs");
import(process.env.KOFUN_ROOT + "/spec/wasi-command-profile-v1/model.mjs").then((m) => {
    const manifest = m.makeManifest([]);
    manifest.memoryPages = 7;
    fs.writeFileSync(process.env.KOFUN_WORK + "/manifest.json", m.canonical(manifest));
});
'
KOFUN_WASM_BUILD_DIR="$WORK/cli-compiler" "$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 --wasi-manifest "$WORK/manifest.json" \
    -o "$WORK/granted.wasm" >/dev/null
node "$ROOT/tests/wasm/wasi-command/inspect.mjs" "$WORK/granted.wasm" >"$WORK/granted.txt"
assert_grep "a manifest's memoryPages is the module's memory maximum" \
    -Fx "memory min 1 max 7" "$WORK/granted.txt"
assert_not_grep "build does not export the runtime" -F "export kofun_wasi_alloc" "$WORK/granted.txt"
KOFUN_WASM_BUILD_DIR="$WORK/cli-compiler" "$ROOT/bin/kofun" build "$WORK/command.kofun" \
    --target wasm32-wasi-command1 -o "$WORK/bare.wasm" >/dev/null
node "$ROOT/tests/wasm/wasi-command/inspect.mjs" "$WORK/bare.wasm" >"$WORK/bare.txt"
assert_grep "without a manifest the module keeps one fixed page" \
    -Fx "memory min 1 max 1" "$WORK/bare.txt"
node "$ROOT/tests/wasm/wasi-command/validate.mjs" "$WORK/granted.wasm" >"$WORK/granted-validated.txt"
assert_grep "the ceiling does not disturb what the validator reads" \
    -Fx "exports memory,kofun_wasi_command_version,_start" "$WORK/granted-validated.txt"

printf '%s\n' \
    "PASS: wasm32-wasi-command1 command memory: layout agrees three ways, the allocator, scopes, byte sequences, vectors, iovecs, and UTF-8 conversion hold under the engine with canaries, each of four seams is caught by its own property, the probe still satisfies #1098's validator and runs on a Preview 1 host, existing profile bytes are unchanged, and a manifest's page ceiling is the command module's memory maximum"
