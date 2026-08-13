#!/bin/sh

# The one place that knows the generation gates' shared vocabulary (#271/#272).
# This file is sourced by build-a1-a2.sh, check-a1-a2.sh, and
# check-fixed-point.sh. It is not a gate itself, it runs nothing on its own,
# and it is deliberately not executable — the same role bootstrap/stage2/
# build.sh plays for the Stage 2 compile line.
#
# Caller contract: define `fail()` first (each gate keeps its own prefix, the
# tests/assertions/assert.sh convention), set `repo_root`, and run from the
# repository root. Sourcing validates the resource-bound environment once.

# The single normative statement of the fixed-point criterion decided on #271.
# Scripts print and record this string; prose quotes it instead of re-deriving
# its own wording.
KOFUN_GENERATIONS_CRITERION='byte equality from generation 2 on - C2 == C3 and A2 == A3 (#271); C1/A1 are hash-pinned runnable provenance'

# One flags spelling for every compile these gates perform, recorded verbatim
# in provenance and asserted by the checker.
kofun_generations_flags='-std=c11 -O2 -Wall -Wextra -Werror'

# Every generation is produced under one declared environment, so two runs —
# or two gates — can require byte equality without an undeclared locale,
# timezone, or umask difference explaining a mismatch away.
KOFUN_GENERATIONS_ENVIRONMENT='LC_ALL=C TZ=UTC umask=022'
LC_ALL=C
TZ=UTC
export LC_ALL TZ
umask 022

# Host toolchain: honour an explicit CC first, then the cascade the sibling
# gates use. Sets `compiler` and `compiler_identity`.
kofun_generations_toolchain() {
    if test -n "${CC:-}" && command -v "$CC" >/dev/null 2>&1; then
        compiler=$CC
    elif command -v cc >/dev/null 2>&1; then
        compiler=cc
    elif command -v clang >/dev/null 2>&1; then
        compiler=clang
    elif command -v gcc >/dev/null 2>&1; then
        compiler=gcc
    else
        fail "a C11 compiler is required"
    fi
    compiler_identity=$("$compiler" --version 2>/dev/null | head -n 1)
    test -n "$compiler_identity" || fail "the host C compiler reports no identity"
}

selfhost_vmem_kib=${KOFUN_SELFHOST_VMEM_KIB:-1572864}
selfhost_timeout_seconds=${KOFUN_SELFHOST_TIMEOUT:-120}
case "$selfhost_vmem_kib" in
    ''|*[!0-9]*|0) fail "KOFUN_SELFHOST_VMEM_KIB must be a positive integer" ;;
esac
case "$selfhost_timeout_seconds" in
    ''|*[!0-9]*|0) fail "KOFUN_SELFHOST_TIMEOUT must be a positive integer" ;;
esac

bounded() {
    (
        # Linux and the CI shell support this bound. Other POSIX shells may
        # not expose -v; they still run the proof, but never turn a portable
        # shell feature check into a product failure.
        if ulimit -v "$selfhost_vmem_kib" 2>/dev/null; then :; fi
        if command -v timeout >/dev/null 2>&1; then
            timeout "${selfhost_timeout_seconds}s" "$@"
        else
            "$@"
        fi
    )
}

digest_of() {
    "$repo_root/bin/kofun-sha256" "$1" | awk '{ print $1 }'
}

# One digest over a set of files, independent of glob order. The build gate
# records these and the check gate recomputes them, so the two computations
# must be this one function or "stale" becomes a false positive.
tree_digest() {
    "$repo_root/bin/kofun-sha256" "$@" | LC_ALL=C sort | "$repo_root/bin/kofun-sha256" | awk '{ print $1 }'
}

corpus_digest() {
    tree_digest bootstrap/selfhost/driver/corpus_*.kofun
}

runtime_digest() {
    tree_digest unicode/*.h
}

# Read one `key|value` row that must occur exactly once — the
# check-profile.sh meta_value contract, shared here so provenance readers
# reject a duplicated key instead of comparing a two-line value.
recorded_value() {
    recorded_file=$1
    recorded_key=$2
    recorded_count=$(awk -F '|' -v key="$recorded_key" \
        '$1 == key { count += 1 } END { print count + 0 }' "$recorded_file")
    test "$recorded_count" -eq 1 ||
        fail "\`$recorded_file\` must declare \`$recorded_key\` exactly once (found $recorded_count)"
    awk -F '|' -v key="$recorded_key" '$1 == key { print $2 }' "$recorded_file"
}

# Derive the next generation in its own directory: copy canonical S, compile
# it with the previous generation's executable, and build the successor. Each
# generation's C is written under the same `kofun.c` basename because the
# host C compiler records the source basename in the binary it produces — a
# mismatch there reports a fixed-point failure that has nothing to do with
# Kofun.
derive_generation() {
    derive_dir=$1
    derive_source_compiler=$2
    derive_label=$3
    mkdir -p "$derive_dir"
    cp bootstrap/stage1/compiler.kofun "$derive_dir/S.kofun"
    (cd "$derive_dir" &&
        bounded "$derive_source_compiler" S.kofun kofun.c \
            >compile.stdout 2>compile.stderr) ||
        fail "$derive_label could not compile S"
    test -s "$derive_dir/kofun.c" || fail "$derive_label produced an empty C"
    (cd "$derive_dir" &&
        "$compiler" $kofun_generations_flags -I "$repo_root/unicode" \
            kofun.c -o compiler) ||
        fail "the $derive_label successor did not build from its C"
}

# Compile every driver corpus case with one compiler, capturing emitted C,
# stdout, stderr, and exit status per case. Sets
# `kofun_generations_corpus_cases`.
corpus_run() {
    corpus_bin=$1
    corpus_root=$2
    kofun_generations_corpus_cases=0
    for corpus_source in bootstrap/selfhost/driver/corpus_*.kofun; do
        corpus_stem=$(basename "$corpus_source" .kofun)
        corpus_dir="$corpus_root/$corpus_stem"
        mkdir -p "$corpus_dir"
        cp "$corpus_source" "$corpus_dir/input.kofun"
        set +e
        (cd "$corpus_dir" &&
            "$corpus_bin" input.kofun output.c >stdout.txt 2>stderr.txt)
        printf '%s\n' "$?" >"$corpus_dir/status.txt"
        set -e
        kofun_generations_corpus_cases=$((kofun_generations_corpus_cases + 1))
    done
    test "$kofun_generations_corpus_cases" -gt 0 ||
        fail "no corpus case was exercised"
}

# Compare two corpus_run trees case by case: same exit status, stdout,
# stderr, and emitted C. This is the executed cross-generation evidence — a
# byte-equal binary makes agreement certain, but the gates observe it rather
# than infer it.
corpus_compare() {
    compare_left=$1
    compare_right=$2
    compare_left_label=$3
    compare_right_label=$4
    for compare_source in bootstrap/selfhost/driver/corpus_*.kofun; do
        compare_stem=$(basename "$compare_source" .kofun)
        cmp "$compare_left/$compare_stem/status.txt" \
            "$compare_right/$compare_stem/status.txt" ||
            fail "$compare_left_label and $compare_right_label exit differently on $compare_stem"
        cmp "$compare_left/$compare_stem/stdout.txt" \
            "$compare_right/$compare_stem/stdout.txt" ||
            fail "$compare_left_label and $compare_right_label differ on $compare_stem stdout"
        cmp "$compare_left/$compare_stem/stderr.txt" \
            "$compare_right/$compare_stem/stderr.txt" ||
            fail "$compare_left_label and $compare_right_label differ on $compare_stem stderr"
        if test -f "$compare_left/$compare_stem/output.c" ||
            test -f "$compare_right/$compare_stem/output.c"; then
            cmp "$compare_left/$compare_stem/output.c" \
                "$compare_right/$compare_stem/output.c" ||
                fail "$compare_left_label and $compare_right_label emit different C for $compare_stem"
        fi
    done
}

# Read one string field out of bootstrap/manifest.json's fixed_point_closure
# record. The record is a declared input to the fixed-point gate — a drifted
# digest there must fail the gate, not sit unread as prose.
manifest_closure_value() {
    manifest_key=$1
    manifest_row=$(sed -n '/"fixed_point_closure": {/,/^  }/p' \
        bootstrap/manifest.json |
        awk -F '"' -v key="$manifest_key" '$2 == key { print $4; exit }')
    test -n "$manifest_row" ||
        fail "bootstrap/manifest.json fixed_point_closure declares no \`$manifest_key\`"
    printf '%s\n' "$manifest_row"
}
