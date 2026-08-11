#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
cd "$repo_root"

fail() {
    printf '%s\n' "FAIL: selfhost c11: $*" >&2
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

temporary=${TMPDIR:-/tmp}/kofun-selfhost-c11.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

. "$repo_root/bootstrap/stage2/build.sh"
kofun_stage2_build "$repo_root" "$temporary/kofun-stage2" ||
    fail "the Stage 2 seed compiler did not build"

# Every positive fixture: the frozen typed document re-emits and lowers
# byte-identically to the checked-in evidence, deterministically; the
# compiled program's observations (stdout, stderr, exit status) match the
# pinned goldens. The generated C consumes only the document records and
# compiles with the repository's Unicode 17 tables.
accepted=0
for fixture in \
    bootstrap/selfhost/c11/accept_*.kofun \
    bootstrap/selfhost/c11/trap_division.kofun \
    bootstrap/selfhost/c11/trap_list_index.kofun; do
    stem=$(basename "$fixture" .kofun)
    digest=$("$repo_root/bin/kofun-digest" "$fixture" | awk '{ print $1 }')
    "$temporary/kofun-stage2" --emit-selfhost-hir \
        "$fixture" "$temporary/$stem.hir" "$digest" >/dev/null
    cmp "bootstrap/selfhost/c11/$stem.hir" "$temporary/$stem.hir" ||
        fail "$stem typed document differs from the checked-in evidence"
    "$temporary/kofun-stage2" --lower-selfhost-c11 \
        "$temporary/$stem.hir" "$temporary/$stem.c" >/dev/null
    cmp "bootstrap/selfhost/c11/$stem.c" "$temporary/$stem.c" ||
        fail "$stem generated C differs from the checked-in evidence"
    "$temporary/kofun-stage2" --lower-selfhost-c11 \
        "$temporary/$stem.hir" "$temporary/$stem.second.c" >/dev/null
    cmp "$temporary/$stem.c" "$temporary/$stem.second.c" ||
        fail "$stem generated C is not deterministic"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I unicode "$temporary/$stem.c" -o "$temporary/$stem"
    set +e
    "$temporary/$stem" \
        >"$temporary/$stem.stdout" 2>"$temporary/$stem.stderr"
    status=$?
    set -e
    test "$status" = "$(cat "bootstrap/selfhost/c11/$stem.status")" ||
        fail "$stem exit status $status differs from the pinned golden"
    test ! -s "$temporary/$stem.stdout" ||
        fail "$stem wrote unexpected stdout"
    if test -f "bootstrap/selfhost/c11/$stem.stderr"; then
        cmp "bootstrap/selfhost/c11/$stem.stderr" \
            "$temporary/$stem.stderr" ||
            fail "$stem stderr differs from the pinned golden"
    else
        test ! -s "$temporary/$stem.stderr" ||
            fail "$stem wrote unexpected stderr"
    fi
    accepted=$((accepted + 1))
done

# Negative evidence. A structurally valid document whose function can
# complete without returning is invalid (exit 1); frontend-accepted
# constructs outside the executable slice (`/`, Text ordering) classify
# as unsupported (exit 3, E2S10) without emitting any C; a rejected
# frontend document is refused as incomplete input (exit 1). Unsupported
# is never conflated with invalid.
expect() {
    wanted_status=$1
    wanted_prefix=$2
    document=$3
    set +e
    "$temporary/kofun-stage2" --lower-selfhost-c11 \
        "$document" "$temporary/negative.c" >"$temporary/negative.stdout"
    status=$?
    set -e
    test "$status" -eq "$wanted_status" ||
        fail "$document must exit $wanted_status, got $status"
    grep "^$wanted_prefix" "$temporary/negative.stdout" >/dev/null ||
        fail "$document diagnostic drifted: $(cat "$temporary/negative.stdout")"
}

reject_digest=$("$repo_root/bin/kofun-digest" bootstrap/selfhost/c11/reject_missing_return.kofun |
    awk '{ print $1 }')
"$temporary/kofun-stage2" --emit-selfhost-hir \
    bootstrap/selfhost/c11/reject_missing_return.kofun \
    "$temporary/reject_missing_return.hir" \
    "$reject_digest" >/dev/null
cmp bootstrap/selfhost/c11/reject_missing_return.hir \
    "$temporary/reject_missing_return.hir" ||
    fail "reject_missing_return typed document drifted"
expect 1 \
    'error\[E2S19\]: selfhost-C11 function may complete without returning' \
    bootstrap/selfhost/c11/reject_missing_return.hir
expect 3 'error\[E2S10\]: unsupported selfhost-C11 operator `/`' \
    bootstrap/selfhost/c11/reject_slash_operator.hir
expect 3 'error\[E2S10\]: unsupported selfhost-C11 operator `<`' \
    bootstrap/selfhost/c11/reject_text_ordering.hir
expect 1 'error\[E2S35\]: selfhost-C11 input must be a complete typed' \
    bootstrap/selfhost/frontend/reject_if_condition.hir
test ! -e "$temporary/negative.c" ||
    fail "a refused document must not leave partial C"

# The execution differential now closes over three independent paths:
# the frontend gate evaluates differential_core's typed node records, the
# Int-core --compile-outcome lowering executes the same source, and this
# document-driven lowering must reproduce the same pinned exit status.
"$temporary/kofun-stage2" --lower-selfhost-c11 \
    bootstrap/selfhost/frontend/differential_core.hir \
    "$temporary/differential_core.c" >/dev/null
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I unicode "$temporary/differential_core.c" \
    -o "$temporary/differential_core"
set +e
"$temporary/differential_core"
differential_status=$?
set -e
test "$differential_status" = \
    "$(cat bootstrap/selfhost/frontend/differential_core.status)" ||
    fail "document-driven lowering diverges from the pinned differential"

printf '%s\n' \
    "PASS: $accepted C11 slice fixtures lower, compile, and run to their pinned observations" \
    "PASS: out-of-slice constructs and invalid documents are refused distinctly"
