#!/bin/sh
set -eu

# The three-generation C11 fixed point (#272), closing roadmap B4/B5:
#
#     sh bootstrap/selfhost/check-fixed-point.sh OUTPUT
#
#     S --trusted seed--> C1 --declared cc--> A1
#     S --------A1-----> C2 --declared cc--> A2
#     S --------A2-----> C3 --declared cc--> A3
#
# The command consumes #271's generation bundle by rebuilding it with the one
# documented `build-a1-a2.sh` command under a declared normalized environment,
# validates it with `check-a1-a2.sh`, then derives the third generation twice
# in normalized clean directories and asserts the criterion decided on #271:
#
#     C2 == C3 and A2 == A3, byte for byte, from generation 2 on.
#
# C1/A1 remain hash-pinned runnable provenance. The full driver corpus runs
# through A3 and must agree with A1 (A1 against A2 is already asserted inside
# build-a1-a2.sh), so success and failure observations are identical across
# all three executable generations. No compiler semantics are added here.

fail() {
    printf '%s\n' "FAIL: selfhost fixed point: $*" >&2
    exit 1
}

test "$#" -eq 1 || fail "usage: sh bootstrap/selfhost/check-fixed-point.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

# Declared normalized environment: every generation below, including the
# rebuilt #271 bundle, is produced under the same locale, timezone, and umask,
# and the values are recorded in the fixed-point provenance.
LC_ALL=C
TZ=UTC
export LC_ALL TZ
umask 022

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    fail "a C11 compiler is required"
fi
compiler_flags='-std=c11 -O2 -Wall -Wextra -Werror'
compiler_identity=$("$compiler" --version 2>/dev/null | head -n 1)
test -n "$compiler_identity" || fail "the host C compiler reports no identity"

selfhost_vmem_kib=${KOFUN_SELFHOST_VMEM_KIB:-1572864}
selfhost_timeout_seconds=${KOFUN_SELFHOST_TIMEOUT:-120}
case "$selfhost_vmem_kib" in
    ''|*[!0-9]*|0) fail "KOFUN_SELFHOST_VMEM_KIB must be a positive integer" ;;
esac
case "$selfhost_timeout_seconds" in
    ''|*[!0-9]*|0) fail "KOFUN_SELFHOST_TIMEOUT must be a positive integer" ;;
esac

digest_of() {
    sha256sum "$1" | awk '{ print $1 }'
}

# The #271 bundle, rebuilt by its own documented command and validated by its
# own gate. A stale or tampered bundle never reaches the third generation.
sh bootstrap/selfhost/build-a1-a2.sh "$output" ||
    fail "the A1/A2 generation bundle did not build"
sh bootstrap/selfhost/check-a1-a2.sh "$output" ||
    fail "the A1/A2 generation bundle did not validate"

bounded() {
    (
        if ulimit -v "$selfhost_vmem_kib" 2>/dev/null; then :; fi
        if command -v timeout >/dev/null 2>&1; then
            timeout "${selfhost_timeout_seconds}s" "$@"
        else
            "$@"
        fi
    )
}

work="$output/.fixed-point.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
rm -rf "$work"

# The third generation, twice, in normalized clean directories. C3 is written
# under the same `kofun.c` basename as every other generation's C, so the
# host compiler's recorded source name cannot manufacture an A2/A3 difference.
derive_gen3() {
    run=$1
    mkdir -p "$run/gen3"
    cp bootstrap/stage1/compiler.kofun "$run/gen3/S.kofun"
    cmp bootstrap/stage1/compiler.kofun "$run/gen3/S.kofun" ||
        fail "generation 3 input differs from canonical S"
    (cd "$run/gen3" &&
        bounded "$output/generations/gen2/compiler" S.kofun kofun.c \
            >compile.stdout 2>compile.stderr) ||
        fail "A2 could not compile S into C3"
    test -s "$run/gen3/kofun.c" || fail "A2 produced an empty C3"
    (cd "$run/gen3" &&
        "$compiler" $compiler_flags -I "$repo_root/unicode" \
            kofun.c -o compiler) || fail "A3 did not build from C3"
    test -x "$run/gen3/compiler" || fail "A3 is not runnable"
}

derive_gen3 "$work/run-a"
derive_gen3 "$work/run-b"

for artifact in gen3/kofun.c gen3/compiler gen3/compile.stdout \
    gen3/compile.stderr; do
    cmp "$work/run-a/$artifact" "$work/run-b/$artifact" ||
        fail "two normalized clean runs disagree on $artifact"
done

# The fixed-point criterion decided on #271, asserted byte for byte.
cmp "$output/generations/gen2/kofun.c" "$work/run-a/gen3/kofun.c" ||
    fail "C2 and C3 differ: the generated-C fixed point does not hold"
cmp "$output/generations/gen2/compiler" "$work/run-a/gen3/compiler" ||
    fail "A2 and A3 differ: the executable fixed point does not hold"

# Success and failure corpus through A3, compared against A1 case by case:
# same emitted C, stdout, stderr, and exit status. With build-a1-a2.sh's
# A1/A2 differential, observations are identical across all three
# executables.
corpus_cases=0
for source in bootstrap/selfhost/driver/corpus_*.kofun; do
    stem=$(basename "$source" .kofun)
    left="$work/corpus/$stem-a1"
    right="$work/corpus/$stem-a3"
    mkdir -p "$left" "$right"
    cp "$source" "$left/input.kofun"
    cp "$source" "$right/input.kofun"

    set +e
    (cd "$left" &&
        "$output/generations/gen1/compiler" input.kofun output.c \
            >stdout.txt 2>stderr.txt)
    left_status=$?
    (cd "$right" &&
        ../../run-a/gen3/compiler input.kofun output.c \
            >stdout.txt 2>stderr.txt)
    right_status=$?
    set -e

    test "$left_status" -eq "$right_status" ||
        fail "A1 and A3 exit differently on $stem ($left_status vs $right_status)"
    cmp "$left/stdout.txt" "$right/stdout.txt" ||
        fail "A1 and A3 differ on $stem stdout"
    cmp "$left/stderr.txt" "$right/stderr.txt" ||
        fail "A1 and A3 differ on $stem stderr"
    if test -f "$left/output.c" || test -f "$right/output.c"; then
        cmp "$left/output.c" "$right/output.c" ||
            fail "A1 and A3 emit different C for $stem"
    fi
    corpus_cases=$((corpus_cases + 1))
done
test "$corpus_cases" -gt 0 || fail "no corpus case was exercised"

c2_digest=$(digest_of "$output/generations/gen2/kofun.c")
c3_digest=$(digest_of "$work/run-a/gen3/kofun.c")
a2_digest=$(digest_of "$output/generations/gen2/compiler")
a3_digest=$(digest_of "$work/run-a/gen3/compiler")
c3_bytes=$(wc -c <"$work/run-a/gen3/kofun.c" | tr -d ' ')

# Path-independent fixed-point provenance beside the bundle's own.
{
    printf 'schema|kofun.selfhost-fixed-point/v1\n'
    printf 'criterion|C2 == C3 and A2 == A3 from generation 2 on (#271); C1/A1 provenance only\n'
    printf 'normalized_environment|LC_ALL=C TZ=UTC umask=022\n'
    printf 'host_compiler_identity|%s\n' "$compiler_identity"
    printf 'host_compiler_flags|%s\n' "$compiler_flags"
    printf 'c2_sha256|%s\n' "$c2_digest"
    printf 'c3_sha256|%s\n' "$c3_digest"
    printf 'c3_bytes|%s\n' "$c3_bytes"
    printf 'a2_sha256|%s\n' "$a2_digest"
    printf 'a3_sha256|%s\n' "$a3_digest"
    printf 'c2_equals_c3|true\n'
    printf 'a2_equals_a3|true\n'
    printf 'corpus_cases_a1_a3|%s\n' "$corpus_cases"
} >"$work/fixed-point.tsv"

rm -f "$output/fixed-point.tsv"
mkdir -p "$output/generations/gen3"
cp "$work/run-a/gen3/kofun.c" "$output/generations/gen3/kofun.c"
cp "$work/run-a/gen3/compiler" "$output/generations/gen3/compiler"
cp "$work/fixed-point.tsv" "$output/fixed-point.tsv"

printf 'PASS: criterion: C2 == C3 and A2 == A3 asserted byte for byte (#271); C1/A1 are provenance\n'
printf 'PASS: A2(S) reproduced C3 (%s bytes) identical to C2, and A3 identical to A2\n' "$c3_bytes"
printf 'PASS: two normalized clean runs reproduced generation 3 byte for byte\n'
printf 'PASS: %s corpus cases agree across A1 and A3 in C, stdout, stderr, and status\n' "$corpus_cases"
printf 'PASS: the three-generation C11 fixed point holds: Kofun'\''s S chain reproduces itself\n'
