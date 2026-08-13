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
# twice in normalized clean directories under the declared environment,
# requires the two runs to reproduce every artifact byte for byte, runs the
# full driver corpus through A1 and A2 differentially, and promotes one copy
# with path-independent provenance under OUTPUT only.
#
# The criterion this family of gates enforces is stated by
# generations-lib.sh and printed below: equality is asserted from
# generation 2 on, and `C1 == C2` is reported, not required.
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

. "$repo_root/bootstrap/selfhost/generations-lib.sh"
. "$repo_root/bootstrap/stage2/build.sh"

kofun_generations_toolchain

# Every declared source, seed, profile, and evidence digest, before any
# build. The sums files are authoritative; the profile pin must agree with
# them rather than being hashed a second time.
(cd bootstrap/stage1 && "$repo_root/bin/kofun-sha256" -c SHA256SUMS >/dev/null) ||
    fail "bootstrap/stage1/SHA256SUMS does not match the checkout"
"$repo_root/bin/kofun-sha256" -c bootstrap/stage2/SHA256SUMS >/dev/null ||
    fail "bootstrap/stage2/SHA256SUMS does not match the checkout"

profile_digest=$(recorded_value bootstrap/selfhost/profile.meta source_sha256)
stage1_declared_digest=$(awk '$2 == "compiler.kofun" { print $1 }' \
    bootstrap/stage1/SHA256SUMS)
test "$profile_digest" = "$stage1_declared_digest" ||
    fail "profile.meta source_sha256 disagrees with bootstrap/stage1/SHA256SUMS"
seed_digest=$(awk '$2 == "bootstrap/stage2/compiler.c" { print $1 }' \
    bootstrap/stage2/SHA256SUMS)
test -n "$seed_digest" ||
    fail "bootstrap/stage2/SHA256SUMS declares no compiler.c digest"

test -s bootstrap/selfhost/driver/S.c ||
    fail "checked-in C1 evidence bootstrap/selfhost/driver/S.c is missing"
input_corpus_digest=$(corpus_digest)
input_runtime_digest=$(runtime_digest)

# All work happens in a fresh bounded directory; a failed run leaves any
# prior promoted output untouched, because promotion is the last step.
work="$output/.work.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/tools"

kofun_stage2_build "$repo_root" "$work/tools/kofun-stage2" ||
    fail "the trusted Stage 2 seed compiler did not build"

# The first generation comes from the seed's own driver interface and must
# reproduce the checked-in evidence byte for byte; later generations are the
# shared derive_generation shape.
derive_first_generation() {
    first_run=$1
    mkdir -p "$first_run/gen1"
    bounded "$work/tools/kofun-stage2" --selfhost-compile \
        bootstrap/stage1/compiler.kofun "$first_run/gen1/kofun.c" \
        "$profile_digest" \
        >"$first_run/gen1/compile.stdout" \
        2>"$first_run/gen1/compile.stderr" ||
        fail "the trusted seed could not compile S"
    test -s "$first_run/gen1/kofun.c" ||
        fail "the trusted seed produced an empty C1"
    cmp "$first_run/gen1/kofun.c" bootstrap/selfhost/driver/S.c ||
        fail "derived C1 differs from the checked-in evidence"
    (cd "$first_run/gen1" &&
        "$compiler" $kofun_generations_flags -I "$repo_root/unicode" \
            kofun.c -o compiler) || fail "A1 did not build from C1"
}

run_generations() {
    run=$1
    derive_first_generation "$run"
    derive_generation "$run/gen2" "$run/gen1/compiler" "A1"
}

run_generations "$work/run-a"
run_generations "$work/run-b"

for artifact in gen1/kofun.c gen1/compiler \
    gen1/compile.stdout gen1/compile.stderr \
    gen2/kofun.c gen2/compiler \
    gen2/compile.stdout gen2/compile.stderr; do
    cmp "$work/run-a/$artifact" "$work/run-b/$artifact" ||
        fail "two normalized clean runs disagree on $artifact"
done

# Success and failure corpus cases through A1 and A2: generated C, stdout,
# stderr, and exit status must agree exactly, and where the repository pins
# emitted C, A1 must match it. The A1 tree is promoted with the bundle so
# downstream gates compare against it instead of re-deriving it.
corpus_run "$work/run-a/gen1/compiler" "$work/corpus-a1"
corpus_cases=$kofun_generations_corpus_cases
corpus_run "$work/run-a/gen2/compiler" "$work/corpus-a2"
corpus_compare "$work/corpus-a1" "$work/corpus-a2" "A1" "A2"
for source in bootstrap/selfhost/driver/corpus_*.kofun; do
    stem=$(basename "$source" .kofun)
    if test -f "bootstrap/selfhost/driver/$stem.c"; then
        cmp "bootstrap/selfhost/driver/$stem.c" \
            "$work/corpus-a1/$stem/output.c" ||
            fail "$stem emission differs from the checked-in evidence"
    fi
done

# Runnability beyond compiling: the answer corpus program built from A1's
# emission executes to its pinned golden.
"$compiler" $kofun_generations_flags \
    "$work/corpus-a1/corpus_answer/output.c" -o "$work/answer-program"
"$work/answer-program" >"$work/answer.stdout"
cmp bootstrap/selfhost/driver/corpus_answer.stdout "$work/answer.stdout" ||
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

# Path-independent provenance: repository-relative names, digests,
# identities, and counts only — never a temporary or absolute path.
{
    printf 'schema|kofun.selfhost-generations/v1\n'
    printf 'criterion|%s\n' "$KOFUN_GENERATIONS_CRITERION"
    printf 'normalized_environment|%s\n' "$KOFUN_GENERATIONS_ENVIRONMENT"
    printf 'canonical_source|bootstrap/stage1/compiler.kofun\n'
    printf 'canonical_source_sha256|%s\n' "$profile_digest"
    printf 'trusted_seed|bootstrap/stage2/compiler.c\n'
    printf 'trusted_seed_sha256|%s\n' "$seed_digest"
    printf 'corpus_sha256|%s\n' "$input_corpus_digest"
    printf 'corpus_cases|%s\n' "$corpus_cases"
    printf 'runtime_headers_sha256|%s\n' "$input_runtime_digest"
    printf 'host_compiler_identity|%s\n' "$compiler_identity"
    printf 'host_compiler_flags|%s\n' "$kofun_generations_flags"
    printf 'c1_sha256|%s\n' "$c1_digest"
    printf 'c1_bytes|%s\n' "$c1_bytes"
    printf 'a1_sha256|%s\n' "$a1_digest"
    printf 'c2_sha256|%s\n' "$c2_digest"
    printf 'c2_bytes|%s\n' "$c2_bytes"
    printf 'a2_sha256|%s\n' "$a2_digest"
    printf 'c1_equals_c2|%s\n' "$c1_equals_c2"
} >"$work/provenance.tsv"

# Promotion is atomic with respect to failure: everything above either
# succeeded, or prior output was never touched. A rewrite owns the whole
# promoted set, including the fixed-point layer. Under `task verify` the two
# gates use separate directories so that layer is absent here, but
# check-fixed-point.sh's one-argument form writes both into one directory —
# and there a stale fixed-point.tsv describing deleted generations is exactly
# the drift these gates exist to refuse.
rm -rf "$output/generations" "$output/corpus" \
    "$output/provenance.tsv" "$output/gen3" "$output/fixed-point.tsv"
mkdir -p "$output/generations/gen1" "$output/generations/gen2"
cp "$work/run-a/gen1/kofun.c" "$output/generations/gen1/kofun.c"
cp "$work/run-a/gen1/compiler" "$output/generations/gen1/compiler"
cp "$work/run-a/gen2/kofun.c" "$output/generations/gen2/kofun.c"
cp "$work/run-a/gen2/compiler" "$output/generations/gen2/compiler"
cp -R "$work/corpus-a1" "$output/corpus"
cp "$work/provenance.tsv" "$output/provenance.tsv"

printf 'PASS: criterion: %s\n' "$KOFUN_GENERATIONS_CRITERION"
printf 'PASS: every declared source, seed, profile, corpus, and runtime digest verified\n'
printf 'PASS: C1 (%s bytes) equals the checked-in evidence and built runnable A1\n' "$c1_bytes"
printf 'PASS: A1(S) produced C2 (%s bytes) and built runnable A2\n' "$c2_bytes"
printf 'PASS: two normalized clean runs reproduced every artifact byte for byte\n'
printf 'PASS: %s corpus cases agree across A1 and A2 in C, stdout, stderr, and status\n' "$corpus_cases"
printf 'report: C1 == C2 is %s (provenance, not a criterion: independent emitters)\n' "$c1_equals_c2"
