#!/bin/sh
set -eu

# Validates a completed build-a1-a2.sh OUTPUT directory (#271):
#
#     sh bootstrap/selfhost/check-a1-a2.sh OUTPUT
#
# Missing, empty, stale, or non-runnable output is rejected. Stale means the
# provenance no longer describes the repository's declared inputs — the
# recorded canonical-source, seed, evidence, corpus, or runtime digest
# differs from what the checkout carries now — or an artifact no longer
# matches its own recorded digest, or the recorded flags and environment
# differ from the ones this gate family declares. Runnable means A2 still
# compiles a pinned corpus program to the same C as A1 and that program
# still executes to its golden.

fail() {
    printf '%s\n' "FAIL: selfhost generations check: $*" >&2
    exit 1
}

test "$#" -eq 1 || fail "usage: sh bootstrap/selfhost/check-a1-a2.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

kofun_generations_toolchain

provenance="$output/provenance.tsv"
test -s "$provenance" || fail "provenance.tsv is missing or empty"

recorded() {
    recorded_value "$provenance" "$1"
}

schema=$(recorded schema)
test "$schema" = 'kofun.selfhost-generations/v1' ||
    fail "unknown provenance schema \`$schema\`"

if grep -E '(^|\|)/' "$provenance" >/dev/null; then
    fail "provenance contains an absolute path"
fi

for artifact in generations/gen1/kofun.c generations/gen1/compiler \
    generations/gen2/kofun.c generations/gen2/compiler; do
    test -s "$output/$artifact" || fail "$artifact is missing or empty"
done

# Stale against this gate family's own declarations: the recorded flags and
# environment must be the ones the scripts compile and run under, or the
# provenance asserts a build nobody can reproduce with these gates.
test "$(recorded host_compiler_flags)" = "$kofun_generations_flags" ||
    fail "stale: recorded compiler flags differ from the declared flags"
test "$(recorded normalized_environment)" = "$KOFUN_GENERATIONS_ENVIRONMENT" ||
    fail "stale: recorded environment differs from the declared normalization"

# Stale against the repository: every recorded input digest must still be
# the checkout's declared input.
test "$(recorded canonical_source_sha256)" = \
    "$(recorded_value bootstrap/selfhost/profile.meta source_sha256)" ||
    fail "stale: recorded canonical source digest differs from profile.meta"
test "$(recorded trusted_seed_sha256)" = \
    "$(digest_of bootstrap/stage2/compiler.c)" ||
    fail "stale: recorded trusted seed digest differs from the checkout"
test "$(recorded corpus_sha256)" = "$(corpus_digest)" ||
    fail "stale: recorded corpus digest differs from the checkout"
test "$(recorded runtime_headers_sha256)" = "$(runtime_digest)" ||
    fail "stale: recorded runtime header digest differs from the checkout"

# Stale against itself: every artifact must match its recorded digest, and
# the promoted A1 corpus tree must cover every recorded case.
test "$(recorded c1_sha256)" = "$(digest_of "$output/generations/gen1/kofun.c")" ||
    fail "stale: C1 no longer matches its recorded digest"
test "$(recorded a1_sha256)" = "$(digest_of "$output/generations/gen1/compiler")" ||
    fail "stale: A1 no longer matches its recorded digest"
test "$(recorded c2_sha256)" = "$(digest_of "$output/generations/gen2/kofun.c")" ||
    fail "stale: C2 no longer matches its recorded digest"
test "$(recorded a2_sha256)" = "$(digest_of "$output/generations/gen2/compiler")" ||
    fail "stale: A2 no longer matches its recorded digest"

cmp "$output/generations/gen1/kofun.c" bootstrap/selfhost/driver/S.c ||
    fail "C1 differs from the checked-in evidence"

corpus_cases=$(recorded corpus_cases)
promoted_cases=$(find "$output/corpus" -name status.txt 2>/dev/null | wc -l |
    tr -d ' ')
test "$promoted_cases" = "$corpus_cases" ||
    fail "the promoted corpus tree has $promoted_cases cases; provenance records $corpus_cases"

# Runnable, not merely present: both generations still compile the answer
# corpus to identical C and the program still reaches its pinned golden.
temporary=${TMPDIR:-/tmp}/kofun-selfhost-generations-check.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary/a1" "$temporary/a2"
cp bootstrap/selfhost/driver/corpus_answer.kofun "$temporary/a1/input.kofun"
cp bootstrap/selfhost/driver/corpus_answer.kofun "$temporary/a2/input.kofun"
(cd "$temporary/a1" &&
    "$output/generations/gen1/compiler" input.kofun output.c \
        >stdout.txt 2>stderr.txt) || fail "A1 could not compile the corpus"
(cd "$temporary/a2" &&
    "$output/generations/gen2/compiler" input.kofun output.c \
        >stdout.txt 2>stderr.txt) || fail "A2 could not compile the corpus"
cmp "$temporary/a1/output.c" "$temporary/a2/output.c" ||
    fail "A1 and A2 emit different corpus C"
cmp bootstrap/selfhost/driver/corpus_answer.c "$temporary/a1/output.c" ||
    fail "corpus emission differs from the checked-in evidence"
"$compiler" $kofun_generations_flags \
    "$temporary/a1/output.c" -o "$temporary/answer-program"
"$temporary/answer-program" >"$temporary/answer.stdout"
cmp bootstrap/selfhost/driver/corpus_answer.stdout "$temporary/answer.stdout" ||
    fail "corpus program output differs from its pinned golden"

printf 'PASS: criterion: %s\n' "$(recorded criterion)"
printf 'PASS: OUTPUT artifacts are present, nonempty, current, and runnable\n'
printf 'PASS: provenance matches the checkout and records no absolute path\n'
printf 'report: c1_equals_c2 is %s\n' "$(recorded c1_equals_c2)"
