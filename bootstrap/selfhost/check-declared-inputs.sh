#!/bin/sh
set -eu

# Fail closed on declared-input drift (#1114):
#
#     sh bootstrap/selfhost/check-declared-inputs.sh OUTPUT
#
# Reads the manifest `declare-inputs.sh` wrote and refuses three classes,
# each by name and each before any artifact would be accepted:
#
#   missing  -- a declared input is not in the checkout
#   altered  -- a declared input is present with different bytes
#   extra    -- the checkout carries an input the manifest does not declare
#
# The third is the one a digest list alone cannot catch, and it is the one
# that matters for reproduction: a build that silently reads a file nobody
# declared is not reproducible from the declared set, however well every
# declared digest matches.

fail() {
    printf '%s\n' "FAIL: selfhost declared inputs check: $*" >&2
    exit 1
}

test "$#" -eq 1 ||
    fail "usage: sh bootstrap/selfhost/check-declared-inputs.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

manifest="$output/declared-inputs.tsv"
test -s "$manifest" || fail "declared-inputs.tsv is missing or empty"

schema=$(recorded_value "$manifest" schema)
test "$schema" = 'kofun.selfhost-declared-inputs/v2' ||
    fail "unknown declared-input schema \`$schema\`"
test "$(recorded_value "$manifest" acquisition_identity_schema)" = \
    'kofun.selfhost-b6-acquisition/v1' ||
    fail "unknown acquisition identity schema"

# The manifest states facts about the checkout, so a path inside it is
# repository-relative by construction; an absolute one would describe one
# machine rather than the source.
if grep -E '\|path=/' "$manifest" >/dev/null; then
    fail "the manifest records an absolute path"
fi

work=${TMPDIR:-/tmp}/kofun-declared-inputs.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"

declared=0
while IFS= read -r row; do
    case "$row" in
        'input|'*) ;;
        *) continue ;;
    esac
    path=$(printf '%s\n' "$row" | sed -n 's/.*|path=\([^|]*\)|.*/\1/p')
    want=$(printf '%s\n' "$row" | sed -n 's/.*|sha256=\(.*\)$/\1/p')
    test -n "$path" || fail "a declared input row records no path"
    test -n "$want" || fail "declared input \`$path\` records no digest"
    printf '%s\n' "$path" >>"$work/declared"
    declared=$((declared + 1))
    if ! test -f "$path"; then
        fail "missing: declared input \`$path\` is not in this checkout"
    fi
    have=$(digest_of "$path")
    test "$have" = "$want" ||
        fail "altered: declared input \`$path\` is $have, not the declared $want"
done <"$manifest"
test "$declared" -gt 0 || fail "the manifest declares no input"

grep -qF '|path=bootstrap/manifest.json|' "$manifest" ||
    fail "the complete bootstrap manifest is not an acquisition input"
grep -qF '|path=bootstrap/selfhost/b6/POLICY.md|' "$manifest" ||
    fail "the B6 policy is not present in the external packet"
grep -qF '|path=bootstrap/selfhost/b6/producer-identities.tsv|' "$manifest" ||
    fail "the producer identity boundary is not present in the external packet"
if grep -qF '|path=bootstrap/selfhost/b6/closure-registry.json|' "$manifest"; then
    fail "the mutable B6 closure registry is an acquisition input"
fi

# Every file the chain reads must be declared. The corpus and runtime sets
# grow by adding files, and a file added there without a manifest row is
# exactly the undeclared input this class exists to catch.
LC_ALL=C sort -u "$work/declared" >"$work/declared.sorted"
{
    ls unicode/*.h
    ls bootstrap/selfhost/driver/corpus_*.kofun
    ls bootstrap/selfhost/driver/corpus_*.c
    ls bootstrap/selfhost/driver/corpus_*.stdout
    ls vendor/utf8proc/utf8proc.c vendor/utf8proc/utf8proc_data.c \
        vendor/utf8proc/utf8proc.h
} | LC_ALL=C sort -u >"$work/present"
extra=$(comm -13 "$work/declared.sorted" "$work/present")
if test -n "$extra"; then
    printf '%s\n' \
        "FAIL: selfhost declared inputs check: extra: the checkout carries inputs the manifest does not declare:" \
        "$extra" >&2
    exit 1
fi

# The set digests must still be the ones the generation gates compute, or the
# manifest and the gates disagree about what the corpus is.
test "$(sed -n 's/^set|name=corpus|sha256=//p' "$manifest")" = "$(corpus_digest)" ||
    fail "the recorded corpus set digest differs from the checkout"
test "$(sed -n 's/^set|name=runtime-headers|sha256=//p' "$manifest")" = \
    "$(runtime_digest)" ||
    fail "the recorded runtime-header set digest differs from the checkout"

# The reconstruction command must resolve, or the manifest names a path to
# nowhere.
# The reconstruction command has to be runnable by a builder holding the
# acquisition set and nothing else, so it must name a declared file. Naming a
# task was the earlier form and could not be run from the manifest: neither
# Taskfile.yml nor go-task is an input, and neither is obtainable from here.
reconstruct=$(recorded_value "$manifest" reconstruct)
case "$reconstruct" in
    'sh '*)
        target=$(printf '%s\n' "$reconstruct" | awk '{ print $2 }')
        test -f "$target" ||
            fail "the reconstruction command names the missing file \`$target\`"
        grep -qxF "$target" "$work/declared.sorted" ||
            fail "the reconstruction command names \`$target\`, which the manifest does not declare as an input"
        ;;
    *) fail "the reconstruction command \`$reconstruct\` does not invoke a declared script" ;;
esac

test -n "$(recorded_value "$manifest" recorded_with)" ||
    fail "the manifest states no toolchain the C digests were recorded with"
test -n "$(recorded_value "$manifest" toolchain_policy)" ||
    fail "the manifest states no policy for a toolchain mismatch"

printf 'PASS: %s declared inputs are present with their declared bytes\n' "$declared"
printf 'PASS: the checkout carries no corpus, evidence, runtime, or vendored input the manifest omits\n'
printf 'PASS: the set digests and toolchain policy resolve, and the reconstruction command names a declared file\n'
printf 'PASS: the whole manifest and policy bundle are inputs while the B6 closure registry is not\n'
