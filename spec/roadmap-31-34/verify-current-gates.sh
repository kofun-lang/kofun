#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ROADMAP="$ROOT/spec/roadmap-31-34"
STAGE2="$ROOT/bootstrap/stage2"
CC=${CC:-cc}
ASSERT_CONTEXT='roadmap 31-34'
. "$ROOT/tests/assertions/assert.sh"

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

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$STAGE2/compiler.c" -o "$temporary/kofun-stage2"

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
    -q '"diverse_double_compilation": "open"' "$ROOT/bootstrap/manifest.json"

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

sh "$ROOT/tests/lsp/check.sh"

printf '%s\n' \
    "PASS: current Stage 2 integer Core probe printed -3 and 2, then exited 42" \
    "PASS: Stage 2 self-recompile and artifact-equivalence gates are closed working; B7 stays open" \
    "PASS: the stdio language server is present and its gate runs"
