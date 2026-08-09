#!/bin/sh
set -eu

# The three-generation C11 fixed point (#272), closing roadmap B4/B5:
#
#     sh bootstrap/selfhost/check-fixed-point.sh OUTPUT [BUNDLE]
#
#     S --trusted seed--> C1 --declared cc--> A1
#     S --------A1-----> C2 --declared cc--> A2
#     S --------A2-----> C3 --declared cc--> A3
#
# With one argument the command is self-contained: it rebuilds the #271
# generation bundle into OUTPUT with the one documented build-a1-a2.sh
# command and validates it with check-a1-a2.sh. With a BUNDLE argument it
# consumes an existing bundle instead — check-a1-a2.sh proves the bundle
# present, current against the checkout, digest-consistent, and runnable,
# which is exactly what the rebuild would have bought — and never writes
# into it. Either way it then derives the third generation twice in
# normalized clean directories and asserts the criterion decided on #271:
#
#     C2 == C3 and A2 == A3, byte for byte, from generation 2 on.
#
# C1/A1 remain hash-pinned runnable provenance. The full driver corpus runs
# through A3 and must agree with the A1 observations promoted inside the
# bundle, so success and failure observations are identical across all three
# executable generations. The machine-independent digests recorded in
# bootstrap/manifest.json's fixed_point_closure entry are declared inputs:
# they are asserted here, not left as prose. No compiler semantics are added.

fail() {
    printf '%s\n' "FAIL: selfhost fixed point: $*" >&2
    exit 1
}

test "$#" -ge 1 && test "$#" -le 2 ||
    fail "usage: sh bootstrap/selfhost/check-fixed-point.sh OUTPUT [BUNDLE]"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac
bundle=""
if test "$#" -eq 2; then
    case "$2" in
        /*) bundle=$2 ;;
        *) bundle=$PWD/$2 ;;
    esac
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

kofun_generations_toolchain

if test -z "$bundle"; then
    sh bootstrap/selfhost/build-a1-a2.sh "$output" ||
        fail "the A1/A2 generation bundle did not build"
    bundle=$output
fi
sh bootstrap/selfhost/check-a1-a2.sh "$bundle" ||
    fail "the A1/A2 generation bundle did not validate"

work="$output/.fixed-point.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM

derive_generation "$work/run-a/gen3" "$bundle/generations/gen2/compiler" "A2"
derive_generation "$work/run-b/gen3" "$bundle/generations/gen2/compiler" "A2"

for artifact in gen3/kofun.c gen3/compiler gen3/compile.stdout \
    gen3/compile.stderr; do
    cmp "$work/run-a/$artifact" "$work/run-b/$artifact" ||
        fail "two normalized clean runs disagree on $artifact"
done

# The fixed-point criterion decided on #271, asserted byte for byte.
cmp "$bundle/generations/gen2/kofun.c" "$work/run-a/gen3/kofun.c" ||
    fail "C2 and C3 differ: the generated-C fixed point does not hold"
cmp "$bundle/generations/gen2/compiler" "$work/run-a/gen3/compiler" ||
    fail "A2 and A3 differ: the executable fixed point does not hold"

# Success and failure corpus through A3, compared against the A1
# observations promoted inside the validated bundle: same emitted C, stdout,
# stderr, and exit status. With the bundle's own A1/A2 differential,
# observations are identical across all three executables.
corpus_run "$work/run-a/gen3/compiler" "$work/corpus-a3"
corpus_cases=$kofun_generations_corpus_cases
corpus_compare "$bundle/corpus" "$work/corpus-a3" "A1" "A3"

c2_digest=$(recorded_value "$bundle/provenance.tsv" c2_sha256)
a2_digest=$(recorded_value "$bundle/provenance.tsv" a2_sha256)
c3_digest=$(digest_of "$work/run-a/gen3/kofun.c")
a3_digest=$(digest_of "$work/run-a/gen3/compiler")
c3_bytes=$(wc -c <"$work/run-a/gen3/kofun.c" | tr -d ' ')
test "$c2_digest" = "$c3_digest" ||
    fail "recorded C2 digest disagrees with measured C3 after byte equality"
test "$a2_digest" = "$a3_digest" ||
    fail "recorded A2 digest disagrees with measured A3 after byte equality"

# The manifest closure record is a declared input, not prose: its schema,
# gate name, and every machine-independent digest must describe this
# checkout and this run. The closure_measurement block stays a record of the
# closing toolchain — the executables are re-proven live above, not compared
# against it.
test "$(manifest_closure_value schema)" = 'kofun.selfhost-fixed-point-closure/v1' ||
    fail "bootstrap/manifest.json fixed_point_closure schema is unknown"
test "$(manifest_closure_value gate)" = 'selfhost-fixed-point' ||
    fail "bootstrap/manifest.json fixed_point_closure names the wrong gate"
test "$(manifest_closure_value canonical_source_sha256)" = \
    "$(recorded_value "$bundle/provenance.tsv" canonical_source_sha256)" ||
    fail "manifest canonical source digest differs from the validated bundle"
test "$(manifest_closure_value trusted_seed_sha256)" = \
    "$(recorded_value "$bundle/provenance.tsv" trusted_seed_sha256)" ||
    fail "manifest trusted seed digest differs from the validated bundle"
test "$(manifest_closure_value corpus_sha256)" = \
    "$(recorded_value "$bundle/provenance.tsv" corpus_sha256)" ||
    fail "manifest corpus digest differs from the validated bundle"
test "$(manifest_closure_value c1_sha256)" = \
    "$(recorded_value "$bundle/provenance.tsv" c1_sha256)" ||
    fail "manifest C1 digest differs from the validated bundle"
test "$(manifest_closure_value c2_sha256)" = "$c2_digest" ||
    fail "manifest C2 digest differs from the validated bundle"
test "$(manifest_closure_value c3_sha256)" = "$c3_digest" ||
    fail "manifest C3 digest differs from the measured third generation"

# Path-independent fixed-point record, owned by this gate alone.
{
    printf 'schema|kofun.selfhost-fixed-point/v1\n'
    printf 'criterion|%s\n' "$KOFUN_GENERATIONS_CRITERION"
    printf 'normalized_environment|%s\n' "$KOFUN_GENERATIONS_ENVIRONMENT"
    printf 'host_compiler_identity|%s\n' "$compiler_identity"
    printf 'host_compiler_flags|%s\n' "$kofun_generations_flags"
    printf 'c3_sha256|%s\n' "$c3_digest"
    printf 'c3_bytes|%s\n' "$c3_bytes"
    printf 'a3_sha256|%s\n' "$a3_digest"
    printf 'corpus_cases_a1_a3|%s\n' "$corpus_cases"
} >"$work/fixed-point.tsv"

rm -rf "$output/gen3" "$output/fixed-point.tsv"
mkdir -p "$output/gen3"
cp "$work/run-a/gen3/kofun.c" "$output/gen3/kofun.c"
cp "$work/run-a/gen3/compiler" "$output/gen3/compiler"
cp "$work/fixed-point.tsv" "$output/fixed-point.tsv"

printf 'PASS: criterion: %s\n' "$KOFUN_GENERATIONS_CRITERION"
printf 'PASS: A2(S) reproduced C3 (%s bytes) identical to C2, and A3 identical to A2\n' "$c3_bytes"
printf 'PASS: two normalized clean runs reproduced generation 3 byte for byte\n'
printf 'PASS: %s corpus cases agree across A1 and A3 in C, stdout, stderr, and status\n' "$corpus_cases"
printf 'PASS: the manifest closure record matches the validated bundle and measured C3\n'
printf 'PASS: the three-generation C11 fixed point holds: Kofun'\''s S chain reproduces itself\n'
