#!/bin/sh
set -eu

# The declared acquisition set is sufficient, not merely accurate (#1114, B6):
#
#     sh bootstrap/selfhost/check-inputs-sufficient.sh OUTPUT
#
# `declare-inputs.sh` writes what a builder must obtain and
# `check-declared-inputs.sh` refuses a declared input that is missing, altered,
# or undeclared. Between them they prove the manifest describes the checkout.
# Neither proves the other direction — that a builder who obtains exactly the
# manifest can reproduce anything.
#
# That gap was real. Materialising the manifest at the commit before this gate
# landed produced a tree that failed at
# `bootstrap/stage1/SHA256SUMS does not match the checkout`, before compiling
# a line: 59 files were declared and 70 were needed. The missing eleven were
# the two files the sums manifests list, the seed's own `#include` siblings,
# the Unicode runtime `.c` and its table, the vendored utf8proc, and the two
# pinned answer artifacts `check-a1-a2.sh` reads unconditionally.
#
# So this gate copies the declared files, and only the declared files, into a
# clean tree and runs the manifest's own reconstruction command there. A file
# the chain reads but the manifest omits is absent in that tree, and the
# reproduction fails naming it.
#
# The isolation needed is over files, not over the toolchain: the question is
# which bytes a builder must obtain. A clean directory answers it with no
# container, no image, and no network, so every contributor can run this.

fail() {
    printf '%s\n' "FAIL: selfhost inputs sufficient: $*" >&2
    exit 1
}

test "$#" -eq 1 ||
    fail "usage: sh bootstrap/selfhost/check-inputs-sufficient.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

manifest="$output/declared-inputs.tsv"
test -s "$manifest" ||
    fail "declared-inputs.tsv is missing or empty; run declare-inputs.sh into $output first"

work="$output/.sufficient.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/tree"

# Exactly the declared set, at the declared digests. Copying by digest rather
# than by tree means a manifest row whose bytes drifted fails here as well,
# which keeps this gate honest if it ever runs without its sibling.
copied=0
while IFS= read -r row; do
    case "$row" in
        'input|'*) ;;
        *) continue ;;
    esac
    path=$(printf '%s\n' "$row" | sed -n 's/.*|path=\([^|]*\)|.*/\1/p')
    want=$(printf '%s\n' "$row" | sed -n 's/.*|sha256=\(.*\)$/\1/p')
    test -n "$path" || fail "a declared input row records no path"
    test -f "$path" || fail "declared input \`$path\` is not in this checkout"
    have=$(digest_of "$path")
    test "$have" = "$want" ||
        fail "declared input \`$path\` is $have, not the declared $want"
    mkdir -p "$work/tree/$(dirname "$path")"
    cp "$path" "$work/tree/$path"
    copied=$((copied + 1))
done <"$manifest"
test "$copied" -gt 0 || fail "the manifest declares no input to materialise"

# Nothing else may reach the reproduction. A build that succeeds only because
# it found a file outside the acquisition set is the failure this gate exists
# to make visible, so the command runs with the clean tree as its whole world.
present=$(find "$work/tree" -type f | wc -l | tr -d ' ')
test "$present" -eq "$copied" ||
    fail "materialised $present files from $copied declared rows"

reconstruct=$(recorded_value "$manifest" reconstruct)
case "$reconstruct" in
    'sh '*' OUTPUT') ;;
    *) fail "the reconstruction command \`$reconstruct\` is not the expected \`sh SCRIPT OUTPUT\` form" ;;
esac
reconstruct_script=$(printf '%s\n' "$reconstruct" | awk '{ print $2 }')
test -f "$work/tree/$reconstruct_script" ||
    fail "the reconstruction command names \`$reconstruct_script\`, which the manifest does not declare"

# Run it where the builder would: inside the acquisition set, with the output
# directory outside it so the proof's own artifacts are not mistaken for
# inputs on a rerun.
mkdir -p "$work/out"
if (cd "$work/tree" &&
    sh "$reconstruct_script" "$work/out" \
        >"$work/reconstruct.stdout" 2>"$work/reconstruct.stderr")
then
    :
else
    printf '%s\n' "----- the acquisition set reproduced nothing, and said:" >&2
    tail -n 20 "$work/reconstruct.stdout" >&2 || true
    tail -n 20 "$work/reconstruct.stderr" >&2 || true
    printf '%s\n' "-----" >&2
    fail "the declared inputs are not sufficient to reproduce; a file the chain reads is not declared, and the diagnostic above names the first one reached"
fi

grep -q '^PASS: the three-generation C11 fixed point holds' \
    "$work/reconstruct.stdout" ||
    fail "the reconstruction ran but did not report the fixed point"

{
    printf 'schema|kofun.selfhost-inputs-sufficient/v1\n'
    printf 'criterion|the declared acquisition set alone reproduces the fixed point\n'
    printf 'normalized_environment|%s\n' "$KOFUN_GENERATIONS_ENVIRONMENT"
    printf 'declared_inputs|%s\n' "$copied"
    printf 'reconstruct|%s\n' "$reconstruct"
    printf 'isolation|a clean directory holding the declared files and nothing else\n'
    printf 'does_not_close|B6 independent clean-builder reproduction; the builder here is this checkout, not another party\n'
} >"$work/inputs-sufficient.tsv"

rm -f "$output/inputs-sufficient.tsv"
cp "$work/inputs-sufficient.tsv" "$output/inputs-sufficient.tsv"

printf 'PASS: %s declared inputs materialised into a tree holding nothing else\n' \
    "$copied"
printf 'PASS: `%s` reproduced the three-generation fixed point from that tree alone\n' \
    "$reconstruct"
printf 'PASS: the acquisition set is sufficient, not merely accurate\n'
printf 'note: this does not close B6 — the builder is this checkout, so it proves the set is complete, not that another party reproduced it\n'
