#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ROADMAP="$ROOT/spec/roadmap-31-34"
STAGE2="$ROOT/bootstrap/stage2"
CC=${CC:-cc}
ASSERT_CONTEXT='roadmap 31-34'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

case ${1-} in
    "")
        ;;
    --full)
        sh "$STAGE2/check.sh"
        KOFUN_GATE_WORK_NAMESPACE=roadmap \
            sh "$ROOT/bootstrap/native/check.sh"
        ;;
    *)
        printf '%s\n' "usage: $0 [--full]" >&2
        exit 2
        ;;
esac

command -v "$CC" >/dev/null 2>&1 || {
    printf '%s\n' "roadmap 31-34: C11 compiler not found: $CC" >&2
    exit 1
}

temporary=${TMPDIR:-/tmp}/kofun-roadmap-31-34.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

CC=$CC kofun_stage2_build "$ROOT" "$temporary/kofun-stage2"

"$temporary/kofun-stage2" \
    "$ROADMAP/current-core-probe.kofun" \
    "$temporary/current-core-probe.c" \
    "$temporary/current-core-probe.ir" \
    "$temporary/current-core-probe.tokens" >/dev/null

assert_grep "current-core-probe.ir" \
    -q '^kofun-stage2-ir/v1$' "$temporary/current-core-probe.ir"
assert_grep "current-core-probe.tokens" \
    -q '^kofun-token-tape/v1$' "$temporary/current-core-probe.tokens"
assert_grep "current-core-probe.c" \
    -q 'kofun_floor_div' "$temporary/current-core-probe.c"
assert_grep "current-core-probe.c" \
    -q 'kofun_floor_mod' "$temporary/current-core-probe.c"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$temporary/current-core-probe.c" \
    -o "$temporary/current-core-probe"

set +e
"$temporary/current-core-probe" \
    >"$temporary/current-core-probe.stdout" \
    2>"$temporary/current-core-probe.stderr"
status=$?
set -e

assert_num "current-core-probe exit status" "$status" -eq 42
cmp \
    "$ROADMAP/current-core-probe.stdout" \
    "$temporary/current-core-probe.stdout"
assert_file_empty "$temporary/current-core-probe.stderr" \
    "$temporary/current-core-probe.stderr"

assert_grep "bootstrap/manifest.json" \
    -q '"stage1_self_recompile": "working"' "$ROOT/bootstrap/manifest.json"
assert_grep "bootstrap/manifest.json" \
    -q \
    '"stage1_stage2_artifact_equivalence": "working"' \
    "$ROOT/bootstrap/manifest.json"
sed -n '/"stage2": {/,/^[[:space:]]*}/p' \
    "$ROOT/bootstrap/manifest.json" |
    grep -q '"status": "working"'
assert_grep "bootstrap/manifest.json" \
    -q \
    '"generated_c_three_generation_equivalence": "working"' \
    "$ROOT/bootstrap/manifest.json"
assert_grep "bootstrap/manifest.json" \
    -q '"diverse_double_compilation": "working"' "$ROOT/bootstrap/manifest.json"
# B7 (#1136) moved from `open` to `working`, so this row now asserts the gate
# that earned it exists rather than only the manifest word. A manifest that
# claims `working` with no gate behind it is the drift the row is here for.
assert_regular_file "bootstrap/selfhost/check-diverse-double-compilation.sh" \
    "$ROOT/bootstrap/selfhost/check-diverse-double-compilation.sh"
assert_regular_file \
    "bootstrap/selfhost/check-diverse-double-compilation-refusals.sh" \
    "$ROOT/bootstrap/selfhost/check-diverse-double-compilation-refusals.sh"

assert_executable "tooling/lsp/kofun-lsp" "$ROOT/tooling/lsp/kofun-lsp"
assert_regular_file "tooling/lsp/server.js" "$ROOT/tooling/lsp/server.js"
assert_regular_file "tests/lsp/check.sh" "$ROOT/tests/lsp/check.sh"

if find "$ROADMAP" -type f \
    \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' \) |
    grep -q .
then
    printf '%s\n' "roadmap 31-34: Python artifact found" >&2
    exit 1
fi

# A failure here is reported by go-task as `Failed to run task "roadmap"`, and
# `roadmap` is an issues-31-34 gate whose name has no connection to the language
# server. #1379 measured the cost of that: a reader is sent to the wrong
# subsystem, and the cheapest discriminator -- running the named gate alone --
# was written down nowhere. Name it here, where the invocation is.
sh "$ROOT/tests/lsp/check.sh" || {
    printf '%s\n' \
        "roadmap 31-34: the LSP gate failed. The subject is tests/lsp/check.sh, not this task." \
        "roadmap 31-34: reproduce it alone with \`sh tests/lsp/check.sh\`." >&2
    exit 1
}

printf '%s\n' \
    "PASS: current Stage 2 integer Core probe printed -3 and 2, then exited 42" \
    "PASS: Stage 2 self-recompile, artifact-equivalence, and B7 diverse double compilation gates are closed working; B6 stays open" \
    "PASS: the stdio language server is present and its gate runs"
