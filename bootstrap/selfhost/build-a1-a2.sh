#!/bin/sh
set -eu

# One documented, versioned generation-orchestration command (#271):
#
#     sh bootstrap/selfhost/build-a1-a2.sh OUTPUT
#
#     S --trusted seed--> C1 --declared cc--> A1
#     S --------A1-----> C2 --declared cc--> A2
#
# The command verifies every declared input digest, derives each generation
# twice in normalized clean directories, requires the two runs to reproduce
# every artifact byte for byte, and promotes one copy with path-independent
# provenance under OUTPUT only.
#
# Generation-equality criterion, decided on #271: byte equality is asserted
# from generation 2 on — `C2 == C3` and `A2 == A3`, owned by #272. C1 and A1
# are provenance: C1 comes from the trusted seed's independent emitter, so
# `C1 == C2` is not required and is reported, not asserted. The criterion the
# gate enforces is stated in this command's own output.
#
# The ordinary `A1(S) -> C2` semantics are consumed from the compilers this
# command builds; no compiler semantics are added here. The full self-compile
# proof (path independence, the audited hand-port differential, sanitizers)
# stays in check-compiler-driver.sh and is not re-implemented.

fail() {
    printf '%s\n' "FAIL: selfhost generations: $*" >&2
    exit 1
}

test "$#" -eq 1 || fail "usage: sh bootstrap/selfhost/build-a1-a2.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

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

require_digest() {
    expected=$1
    file=$2
    test -f "$file" || fail "declared input \`$file\` is missing"
    actual=$(digest_of "$file")
    test "$expected" = "$actual" ||
        fail "\`$file\` digest $actual differs from declared $expected"
}

# Every declared source, seed, profile, and evidence digest, before any build.
profile_digest=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    bootstrap/selfhost/profile.meta)
test -n "$profile_digest" || fail "profile.meta declares no source_sha256"
require_digest "$profile_digest" bootstrap/stage1/compiler.kofun

while read -r declared file; do
    test -n "$declared" || continue
    require_digest "$declared" "bootstrap/stage1/$file"
done <bootstrap/stage1/SHA256SUMS

while read -r declared file; do
    test -n "$declared" || continue
    require_digest "$declared" "$file"
done <bootstrap/stage2/SHA256SUMS

test -s bootstrap/selfhost/driver/S.c ||
    fail "checked-in C1 evidence bootstrap/selfhost/driver/S.c is missing"
evidence_digest=$(digest_of bootstrap/selfhost/driver/S.c)

corpus_digest=$(
    for source in bootstrap/selfhost/driver/corpus_*.kofun; do
        sha256sum "$source"
    done | LC_ALL=C sort | sha256sum | awk '{ print $1 }'
)
runtime_digest=$(
    for header in unicode/*.h; do
        sha256sum "$header"
    done | LC_ALL=C sort | sha256sum | awk '{ print $1 }'
)

# All work happens in a fresh bounded directory; a failed run leaves any prior
# promoted output untouched, because promotion is the last step.
mkdir -p "$output"
work="$output/.work.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
rm -rf "$work"
mkdir -p "$work/tools"

"$compiler" $compiler_flags \
    bootstrap/stage2/compiler.c -o "$work/tools/kofun-stage2"

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

# One normalized clean generation run. Each generation's C is written under
# the same basename `kofun.c` in its own directory, so the host compiler's
# recorded source name never manufactures a byte difference between
# generations — the failure mode #271 measured at A2/A3.
run_generations() {
    run=$1
    mkdir -p "$run/gen1" "$run/gen2"

    bounded "$work/tools/kofun-stage2" --selfhost-compile \
        bootstrap/stage1/compiler.kofun "$run/gen1/kofun.c" \
        "$profile_digest" >"$run/gen1/compile.stdout" 2>"$run/gen1/compile.stderr" ||
        fail "the trusted seed could not compile S"
    test -s "$run/gen1/kofun.c" || fail "the trusted seed produced an empty C1"
    cmp "$run/gen1/kofun.c" bootstrap/selfhost/driver/S.c ||
        fail "derived C1 differs from the checked-in evidence"

    (cd "$run/gen1" &&
        "$compiler" $compiler_flags -I "$repo_root/unicode" \
            kofun.c -o compiler) || fail "A1 did not build from C1"
    test -x "$run/gen1/compiler" || fail "A1 is not runnable"

    cp bootstrap/stage1/compiler.kofun "$run/gen2/S.kofun"
    cmp bootstrap/stage1/compiler.kofun "$run/gen2/S.kofun" ||
        fail "generation 2 input differs from canonical S"
    (cd "$run/gen2" &&
        bounded ../gen1/compiler S.kofun kofun.c \
            >compile.stdout 2>compile.stderr) ||
        fail "A1 could not compile S into C2"
    test -s "$run/gen2/kofun.c" || fail "A1 produced an empty C2"

    (cd "$run/gen2" &&
        "$compiler" $compiler_flags -I "$repo_root/unicode" \
            kofun.c -o compiler) || fail "A2 did not build from C2"
    test -x "$run/gen2/compiler" || fail "A2 is not runnable"
}

run_generations "$work/run-a"
run_generations "$work/run-b"

for artifact in gen1/kofun.c gen1/compiler gen2/kofun.c gen2/compiler \
    gen2/compile.stdout gen2/compile.stderr; do
    cmp "$work/run-a/$artifact" "$work/run-b/$artifact" ||
        fail "two normalized clean runs disagree on $artifact"
done

# Success and failure corpus cases through A1 and A2: generated C, stdout,
# stderr, and exit status must agree exactly, and where the repository pins
# emitted C, both must match it. This is the behavioral A1/A2 differential;
# the semantics under test come from the compilers, not from this harness.
corpus_cases=0
for source in bootstrap/selfhost/driver/corpus_*.kofun; do
    stem=$(basename "$source" .kofun)
    left="$work/corpus/$stem-a1"
    right="$work/corpus/$stem-a2"
    mkdir -p "$left" "$right"
    cp "$source" "$left/input.kofun"
    cp "$source" "$right/input.kofun"

    set +e
    (cd "$left" &&
        ../../run-a/gen1/compiler input.kofun output.c \
            >stdout.txt 2>stderr.txt)
    left_status=$?
    (cd "$right" &&
        ../../run-a/gen2/compiler input.kofun output.c \
            >stdout.txt 2>stderr.txt)
    right_status=$?
    set -e

    test "$left_status" -eq "$right_status" ||
        fail "A1 and A2 exit differently on $stem ($left_status vs $right_status)"
    cmp "$left/stdout.txt" "$right/stdout.txt" ||
        fail "A1 and A2 differ on $stem stdout"
    cmp "$left/stderr.txt" "$right/stderr.txt" ||
        fail "A1 and A2 differ on $stem stderr"
    if test -f "$left/output.c" || test -f "$right/output.c"; then
        cmp "$left/output.c" "$right/output.c" ||
            fail "A1 and A2 emit different C for $stem"
    fi
    if test -f "bootstrap/selfhost/driver/$stem.c"; then
        cmp "bootstrap/selfhost/driver/$stem.c" "$left/output.c" ||
            fail "$stem emission differs from the checked-in evidence"
    fi
    corpus_cases=$((corpus_cases + 1))
done
test "$corpus_cases" -gt 0 || fail "no corpus case was exercised"

# Runnability beyond compiling: the answer corpus program built from A1's
# emission executes to its pinned golden.
"$compiler" $compiler_flags \
    "$work/corpus/corpus_answer-a1/output.c" -o "$work/corpus/answer-program"
"$work/corpus/answer-program" >"$work/corpus/answer.stdout"
cmp bootstrap/selfhost/driver/corpus_answer.stdout \
    "$work/corpus/answer.stdout" ||
    fail "the answer corpus program output differs from its pinned golden"

c1_digest=$(digest_of "$work/run-a/gen1/kofun.c")
a1_digest=$(digest_of "$work/run-a/gen1/compiler")
c2_digest=$(digest_of "$work/run-a/gen2/kofun.c")
a2_digest=$(digest_of "$work/run-a/gen2/compiler")
c1_bytes=$(wc -c <"$work/run-a/gen1/kofun.c" | tr -d ' ')
c2_bytes=$(wc -c <"$work/run-a/gen2/kofun.c" | tr -d ' ')
if cmp -s "$work/run-a/gen1/kofun.c" "$work/run-a/gen2/kofun.c"; then
    c1_equals_c2=true
else
    c1_equals_c2=false
fi

# Path-independent provenance: repository-relative names, digests, identities,
# and counts only — never a temporary or absolute path.
{
    printf 'schema|kofun.selfhost-generations/v1\n'
    printf 'criterion|byte-equality-from-generation-2 (C2 == C3, A2 == A3, #272); C1/A1 provenance only\n'
    printf 'canonical_source|bootstrap/stage1/compiler.kofun\n'
    printf 'canonical_source_sha256|%s\n' "$profile_digest"
    printf 'trusted_seed|bootstrap/stage2/compiler.c\n'
    printf 'trusted_seed_sha256|%s\n' \
        "$(digest_of bootstrap/stage2/compiler.c)"
    printf 'c1_evidence|bootstrap/selfhost/driver/S.c\n'
    printf 'c1_evidence_sha256|%s\n' "$evidence_digest"
    printf 'corpus_sha256|%s\n' "$corpus_digest"
    printf 'corpus_cases|%s\n' "$corpus_cases"
    printf 'runtime_headers_sha256|%s\n' "$runtime_digest"
    printf 'host_compiler_identity|%s\n' "$compiler_identity"
    printf 'host_compiler_flags|%s\n' "$compiler_flags"
    printf 'c1_sha256|%s\n' "$c1_digest"
    printf 'c1_bytes|%s\n' "$c1_bytes"
    printf 'a1_sha256|%s\n' "$a1_digest"
    printf 'c2_sha256|%s\n' "$c2_digest"
    printf 'c2_bytes|%s\n' "$c2_bytes"
    printf 'a2_sha256|%s\n' "$a2_digest"
    printf 'c1_equals_c2|%s\n' "$c1_equals_c2"
} >"$work/provenance.tsv"

# Promotion is atomic with respect to failure: everything above either
# succeeded, or prior output was never touched.
rm -rf "$output/generations" "$output/provenance.tsv"
mkdir -p "$output/generations/gen1" "$output/generations/gen2"
cp "$work/run-a/gen1/kofun.c" "$output/generations/gen1/kofun.c"
cp "$work/run-a/gen1/compiler" "$output/generations/gen1/compiler"
cp "$work/run-a/gen2/kofun.c" "$output/generations/gen2/kofun.c"
cp "$work/run-a/gen2/compiler" "$output/generations/gen2/compiler"
cp "$work/provenance.tsv" "$output/provenance.tsv"

printf 'PASS: criterion: byte equality is asserted from generation 2 on (C2 == C3, A2 == A3, #272); C1/A1 are provenance\n'
printf 'PASS: every declared source, seed, profile, corpus, and runtime digest verified\n'
printf 'PASS: C1 (%s bytes) equals the checked-in evidence and built runnable A1\n' "$c1_bytes"
printf 'PASS: A1(S) produced C2 (%s bytes) and built runnable A2\n' "$c2_bytes"
printf 'PASS: two normalized clean runs reproduced every artifact byte for byte\n'
printf 'PASS: %s corpus cases agree across A1 and A2 in C, stdout, stderr, and status\n' "$corpus_cases"
printf 'report: C1 == C2 is %s (provenance, not a criterion: independent emitters)\n' "$c1_equals_c2"
