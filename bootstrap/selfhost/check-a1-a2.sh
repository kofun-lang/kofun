#!/bin/sh
set -eu

# Validates a completed build-a1-a2.sh OUTPUT directory (#271):
#
#     sh bootstrap/selfhost/check-a1-a2.sh OUTPUT
#
# Missing, empty, stale, or non-runnable output is rejected. Stale means the
# provenance no longer describes the repository's declared inputs — the
# recorded canonical-source, seed, evidence, corpus, or runtime digest differs
# from what the checkout carries now — or an artifact no longer matches its own
# recorded digest. Runnable means A2 still compiles a pinned corpus program to
# the same C as A1 and that program still executes to its golden.

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

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    fail "a C11 compiler is required"
fi

provenance="$output/provenance.tsv"
test -s "$provenance" || fail "provenance.tsv is missing or empty"

recorded() {
    row=$(awk -F '|' -v key="$1" '$1 == key { print $2 }' "$provenance")
    test -n "$row" || fail "provenance declares no \`$1\`"
    printf '%s\n' "$row"
}

digest_of() {
    sha256sum "$1" | awk '{ print $1 }'
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
test -x "$output/generations/gen1/compiler" || fail "A1 is not executable"
test -x "$output/generations/gen2/compiler" || fail "A2 is not executable"

# Stale against the repository: every recorded input digest must still be the
# checkout's declared input.
current_source=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    bootstrap/selfhost/profile.meta)
test "$(recorded canonical_source_sha256)" = "$current_source" ||
    fail "stale: recorded canonical source digest differs from profile.meta"
test "$(recorded trusted_seed_sha256)" = \
    "$(digest_of bootstrap/stage2/compiler.c)" ||
    fail "stale: recorded trusted seed digest differs from the checkout"
test "$(recorded c1_evidence_sha256)" = \
    "$(digest_of bootstrap/selfhost/driver/S.c)" ||
    fail "stale: recorded C1 evidence digest differs from the checkout"
current_corpus=$(
    for source in bootstrap/selfhost/driver/corpus_*.kofun; do
        sha256sum "$source"
    done | LC_ALL=C sort | sha256sum | awk '{ print $1 }'
)
test "$(recorded corpus_sha256)" = "$current_corpus" ||
    fail "stale: recorded corpus digest differs from the checkout"
current_runtime=$(
    for header in unicode/*.h; do
        sha256sum "$header"
    done | LC_ALL=C sort | sha256sum | awk '{ print $1 }'
)
test "$(recorded runtime_headers_sha256)" = "$current_runtime" ||
    fail "stale: recorded runtime header digest differs from the checkout"

# Stale against itself: every artifact must match its recorded digest.
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
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    "$temporary/a1/output.c" -o "$temporary/answer-program"
"$temporary/answer-program" >"$temporary/answer.stdout"
cmp bootstrap/selfhost/driver/corpus_answer.stdout "$temporary/answer.stdout" ||
    fail "corpus program output differs from its pinned golden"

printf 'PASS: criterion: %s\n' "$(recorded criterion)"
printf 'PASS: OUTPUT artifacts are present, nonempty, current, and runnable\n'
printf 'PASS: provenance matches the checkout and records no absolute path\n'
printf 'report: c1_equals_c2 is %s\n' "$(recorded c1_equals_c2)"
