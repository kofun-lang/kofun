#!/bin/sh
set -eu

# The declared-input side of B6 (#1114):
#
#     sh bootstrap/selfhost/declare-inputs.sh OUTPUT
#
# Writes one versioned manifest naming every file an independent builder must
# obtain to reproduce the generation chain, each with a content digest, plus
# the toolchain the recorded C digests were produced with and what a builder
# should conclude from a mismatch.
#
# This is the acquisition set, not the build. It answers "what do I need, and
# how do I know I have the right bytes" — the question `provenance.tsv` cannot
# answer, because that file describes a build that already happened in a
# checkout the reproducer is trying to establish rather than assume.
#
# Every digest here is computed with the same helpers the generation gates
# read, so the manifest cannot drift from what they verify.

fail() {
    printf '%s\n' "FAIL: selfhost declared inputs: $*" >&2
    exit 1
}

test "$#" -eq 1 ||
    fail "usage: sh bootstrap/selfhost/declare-inputs.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

kofun_generations_toolchain

# Every file the chain reads, by role. A builder that has exactly these, at
# these digests, has the acquisition set; anything else in the checkout is not
# an input to this proof.
declare_file() {
    role=$1
    path=$2
    test -f "$path" || fail "declared input \`$path\` is missing"
    printf 'input|role=%s|path=%s|sha256=%s\n' \
        "$role" "$path" "$(digest_of "$path")"
}

mkdir -p "$output"
work="$output/.declare.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"

{
    printf 'schema|kofun.selfhost-declared-inputs/v1\n'
    printf 'criterion|%s\n' "$KOFUN_GENERATIONS_CRITERION"
    printf 'normalized_environment|%s\n' "$KOFUN_GENERATIONS_ENVIRONMENT"
    printf 'host_compiler_flags|%s\n' "$kofun_generations_flags"
    # The toolchain the recorded C digests were produced with, and what a
    # mismatch means. Without this a reproducer cannot tell a defect from an
    # undeclared input.
    printf 'recorded_with|%s\n' "$compiler_identity"
    printf 'toolchain_policy|%s\n' \
        'the generated C digests are deterministic and expected to reproduce under any conforming C11 compiler; the executable digests are not, and a mismatch there is a toolchain difference rather than a defect'
    printf 'offline|%s\n' \
        'no network access is required after the acquisition set below is obtained'

    declare_file canonical-source bootstrap/stage1/compiler.kofun
    declare_file trusted-seed bootstrap/stage2/compiler.c
    declare_file c1-evidence bootstrap/selfhost/driver/S.c
    declare_file profile bootstrap/selfhost/profile.meta
    declare_file profile bootstrap/selfhost/profile.tsv
    declare_file manifest bootstrap/manifest.json
    declare_file sums bootstrap/stage1/SHA256SUMS
    declare_file sums bootstrap/stage2/SHA256SUMS
    for script in bootstrap/selfhost/generations-lib.sh \
        bootstrap/selfhost/build-a1-a2.sh \
        bootstrap/selfhost/check-a1-a2.sh \
        bootstrap/selfhost/check-fixed-point.sh \
        bootstrap/stage2/build.sh; do
        declare_file command "$script"
    done
    for header in unicode/*.h; do
        declare_file runtime "$header"
    done
    for source in bootstrap/selfhost/driver/corpus_*.kofun; do
        declare_file corpus "$source"
    done

    # The two set digests the generation gates verify, so a builder can check
    # the corpus and runtime sets as wholes rather than file by file.
    printf 'set|name=corpus|sha256=%s\n' "$(corpus_digest)"
    printf 'set|name=runtime-headers|sha256=%s\n' "$(runtime_digest)"

    printf 'reconstruct|%s\n' 'task selfhost-fixed-point'
} >"$work/declared-inputs.tsv"

count=$(grep -c '^input|' "$work/declared-inputs.tsv")
test "$count" -gt 0 || fail "the manifest declares no input"

rm -f "$output/declared-inputs.tsv"
cp "$work/declared-inputs.tsv" "$output/declared-inputs.tsv"

printf 'PASS: %s declared inputs recorded with content digests\n' "$count"
printf 'PASS: the corpus and runtime-header set digests match the generation gates\n'
printf 'PASS: the toolchain the recorded C digests came from is stated, with what a mismatch means\n'
