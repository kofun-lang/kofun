#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
cd "$repo_root"

fail() {
    printf '%s\n' "FAIL: selfhost frontend: $*" >&2
    exit 1
}

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    fail "a C11 compiler is required"
fi

temporary=${TMPDIR:-/tmp}/kofun-selfhost-frontend.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

. "$repo_root/bootstrap/stage2/build.sh"
kofun_stage2_build "$repo_root" "$temporary/kofun-stage2" ||
    fail "the Stage 2 seed compiler did not build"

# The frozen S emits one complete typed kofun.selfhost-hir/v1 document,
# byte-identical to the checked-in evidence and across repeated runs. The
# digest is the exact profile digest, so profile drift fails here too.
profile_digest=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    bootstrap/selfhost/profile.meta)
actual_digest=$(sha256sum bootstrap/stage1/compiler.kofun | awk '{ print $1 }')
test "$profile_digest" = "$actual_digest" ||
    fail "S digest differs from the frozen profile"

"$temporary/kofun-stage2" --emit-selfhost-hir \
    bootstrap/stage1/compiler.kofun \
    "$temporary/S.hir" \
    "$profile_digest" >/dev/null
cmp bootstrap/selfhost/frontend/S.hir "$temporary/S.hir" ||
    fail "S typed document differs from the checked-in evidence"
"$temporary/kofun-stage2" --emit-selfhost-hir \
    bootstrap/stage1/compiler.kofun \
    "$temporary/S.second.hir" \
    "$profile_digest" >/dev/null
cmp "$temporary/S.hir" "$temporary/S.second.hir" ||
    fail "S typed document is not deterministic"

grep '^status|complete$' "$temporary/S.hir" >/dev/null ||
    fail "S document must be complete"
# One function record per declaration in S: the byte-identity check above
# already pins the exact document, so this derives the count instead of
# hand-maintaining a literal that drifts on every helper split.
declared_functions=$(grep -c '^fn ' bootstrap/stage1/compiler.kofun)
test "$(grep -c "^function|" "$temporary/S.hir")" -eq "$declared_functions" ||
    fail "S must type all $declared_functions functions"

# Every positive fixture emits its exact checked-in complete document,
# deterministically; one accepted document exists per profile row family.
accepted=0
for fixture in \
    bootstrap/selfhost/frontend/accept_*.kofun \
    bootstrap/selfhost/frontend/differential_core.kofun; do
    stem=$(basename "$fixture" .kofun)
    digest=$(sha256sum "$fixture" | awk '{ print $1 }')
    "$temporary/kofun-stage2" --emit-selfhost-hir \
        "$fixture" \
        "$temporary/$stem.hir" \
        "$digest" >"$temporary/$stem.stdout" 2>"$temporary/$stem.stderr"
    test ! -s "$temporary/$stem.stdout" ||
        fail "$stem wrote unexpected diagnostics"
    test ! -s "$temporary/$stem.stderr" ||
        fail "$stem wrote unexpected internal stderr"
    cmp "bootstrap/selfhost/frontend/$stem.hir" "$temporary/$stem.hir" ||
        fail "$stem typed document differs from the checked-in evidence"
    "$temporary/kofun-stage2" --emit-selfhost-hir \
        "$fixture" \
        "$temporary/$stem.second.hir" \
        "$digest" >/dev/null
    cmp "$temporary/$stem.hir" "$temporary/$stem.second.hir" ||
        fail "$stem typed document is not deterministic"
    grep '^status|complete$' "$temporary/$stem.hir" >/dev/null ||
        fail "$stem document must be complete"
    accepted=$((accepted + 1))
done

# Differential check one: every accepted document's parameter and local
# binding names, mutability, and types must agree with the audited seed's
# independent scope-HIR inference, joined on the declaration byte.
cat > "$temporary/cross-check.awk" <<'AWK'
BEGIN { FS = "|" }
FNR == 1 { file += 1 }
file == 1 && $1 == "type" { typekey[$2] = $3 }
file == 1 && $1 == "symbol" { symbolkind[$2] = $3; symboltype[$2] = $5 }
file == 1 && $1 == "binding" {
    if (symbolkind[$4] == "parameter" || symbolkind[$4] == "local") {
        selfname[$7] = $5
        selfmut[$7] = $6
        selftype[$7] = typekey[symboltype[$4]]
        selfcount += 1
    }
}
file == 2 && $1 == "binding" {
    scopecount += 1
    surface = $6
    mapped = ""
    if (surface == "Int") mapped = "int"
    if (surface == "Bool") mapped = "bool"
    if (surface == "Text") mapped = "text"
    if (surface == "List") mapped = "list-text"
    mut = $5 == "mutable" ? "mut" : "imm"
    at = $9
    if (selfname[at] != $4 || selfmut[at] != mut || selftype[at] != mapped) {
        printf "binding mismatch at byte %s: %s/%s/%s vs %s/%s/%s\n", \
            at, selfname[at], selfmut[at], selftype[at], $4, mut, mapped \
            > "/dev/stderr"
        failed = 1
    }
}
END {
    if (selfcount != scopecount) {
        printf "binding count mismatch: %d typed vs %d scoped\n", \
            selfcount, scopecount > "/dev/stderr"
        failed = 1
    }
    exit failed
}
AWK
cross_checked=0
for fixture in \
    bootstrap/stage1/compiler.kofun \
    bootstrap/selfhost/frontend/accept_*.kofun \
    bootstrap/selfhost/frontend/differential_core.kofun; do
    stem=$(basename "$fixture" .kofun)
    typed="$temporary/$stem.hir"
    if test "$fixture" = bootstrap/stage1/compiler.kofun; then
        typed="$temporary/S.hir"
    fi
    "$temporary/kofun-stage2" --emit-scope-hir \
        "$fixture" \
        "$temporary/$stem.scope-hir" >/dev/null
    awk -f "$temporary/cross-check.awk" \
        "$typed" "$temporary/$stem.scope-hir" ||
        fail "$stem typed bindings diverge from the scope-HIR reference"
    cross_checked=$((cross_checked + 1))
done

# Differential check two: evaluating the typed-HIR node records of the
# executable core fixture must reproduce the exit status of its compiled
# deterministic C11, pinned in differential_core.status. The backend
# consumes exactly these records, so the typing claims meet an
# independent execution of the same source.
cat > "$temporary/tree-eval.awk" <<'AWK'
BEGIN { FS = "|" }
$1 == "node" {
    id = $2
    kind[id] = $3
    first[id] = $8
    second[id] = $9
    third[id] = $10
    order[++nodes] = id
}
function fdiv(l, r, q) {
    q = int(l / r)
    if (q * r != l && ((l < 0) != (r < 0))) q -= 1
    return q
}
function ev(id, k, l, r, op) {
    k = kind[id]
    if (k == "literal-int") return first[id] + 0
    if (k == "name") return env[first[id]]
    if (k == "unary") return -ev(second[id])
    if (k == "binary") {
        l = ev(second[id])
        r = ev(third[id])
        op = first[id]
        if (op == "+") return l + r
        if (op == "-") return l - r
        if (op == "*") return l * r
        if (op == "//") return fdiv(l, r)
        if (op == "%") return l - fdiv(l, r) * r
    }
    return 0
}
END {
    for (position = 1; position <= nodes; position += 1) {
        id = order[position]
        k = kind[id]
        if (k == "let" || k == "let-mut" || k == "assign") {
            env[first[id]] = ev(second[id])
        } else if (k == "return") {
            print ev(first[id])
            exit 0
        }
    }
    exit 1
}
AWK
evaluated=$(awk -f "$temporary/tree-eval.awk" \
    "$temporary/differential_core.hir") ||
    fail "differential_core typed document has no evaluable return"
"$temporary/kofun-stage2" --compile-outcome \
    bootstrap/selfhost/frontend/differential_core.kofun \
    "$temporary/differential_core.c" \
    "$temporary/differential_core.ir" \
    "$temporary/differential_core.tokens" >/dev/null
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    "$temporary/differential_core.c" -o "$temporary/differential_core"
set +e
"$temporary/differential_core"
executed=$?
set -e
expected=$(cat bootstrap/selfhost/frontend/differential_core.status)
test "$evaluated" = "$expected" ||
    fail "typed-HIR evaluation $evaluated differs from pinned $expected"
test "$executed" = "$expected" ||
    fail "C11 execution $executed differs from pinned $expected"

# Every rejection fixture produces exit 1 and its exact rejected document:
# diagnostics with stable codes and spans, never a partial typed document.
rejected=0
for fixture in bootstrap/selfhost/frontend/reject_*.kofun; do
    stem=$(basename "$fixture" .kofun)
    digest=$(sha256sum "$fixture" | awk '{ print $1 }')
    set +e
    "$temporary/kofun-stage2" --emit-selfhost-hir \
        "$fixture" \
        "$temporary/$stem.hir" \
        "$digest" >"$temporary/$stem.stdout" 2>"$temporary/$stem.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem must reject with exit 1"
    test ! -s "$temporary/$stem.stderr" ||
        fail "$stem wrote unexpected internal stderr"
    cmp "bootstrap/selfhost/frontend/$stem.hir" "$temporary/$stem.hir" ||
        fail "$stem rejected document differs from the checked-in evidence"
    grep '^status|rejected$' "$temporary/$stem.hir" >/dev/null ||
        fail "$stem document must be rejected"
    grep '^node|' "$temporary/$stem.hir" >/dev/null &&
        fail "$stem rejected document must not carry typed nodes"
    rejected=$((rejected + 1))
done

printf '%s\n' \
    "PASS: the frozen S emits one complete, deterministic typed-HIR document" \
    "PASS: $accepted positive fixtures pin byte-stable accepted documents" \
    "PASS: $cross_checked typed documents agree with the scope-HIR reference" \
    "PASS: typed-HIR evaluation and C11 execution agree on $expected" \
    "PASS: $rejected rejection fixtures pin stable diagnostics without partial documents"
