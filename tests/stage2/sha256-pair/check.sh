#!/usr/bin/env sh
set -eu

# The Stage 2 pair computes the same SHA-256 as the C oracle (#1382).
#
# Every identity this compiler assigns — ModuleId, FileId, SymbolId — is a
# SHA-256 preimage, and until RFC-0013 step 4 the digest was computed by
# `bootstrap/stage2/sha256.c`, so a compiler specified to assign its own
# identities could not reach the operation that defines them.
#
# The trusted C seed, the Kofun compiler's own SHA functions, and the
# digest-pinned include must all agree. The include boundaries and target
# bytes are part of the compiler contract and checked independently below.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
# The diagnostic runner calls registered scripts without arguments.
mode=${1:---include-form}
case "$mode" in
    --include-form|--sha256-pair) ;;
    *) printf 'unknown SHA-256 pair gate mode: %s\n' "$mode" >&2; exit 2 ;;
esac
WORK=${KOFUN_SHA256_PAIR_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}sha256-pair"}

if test "$mode" = --include-form; then
    WORK=${KOFUN_INCLUDE_FORM_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}include-form"}
fi

. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || assert_fail 'a C11 compiler is required'

# Verify acquisition and retention failure modes using a private source root.
# A manifest can name a path but cannot add it to the acquisition inventory.
if test "$mode" = --include-form; then
    . "$ROOT/bootstrap/stage2/build.sh"
    kofun_stage2_include_bundle "$ROOT" "$WORK"
    shasource=bootstrap/stage2/includes/sha256.kofun
    tracked_files="$ROOT/bootstrap/stage2/includes-v1.files"
    git -C "$ROOT" ls-files --stage -- "$shasource" |
        grep -Eq "^100644 [0-9a-f]+ 0[[:space:]]$shasource$" ||
        assert_fail 'SHA-256 include must be a tracked regular file'
    printf '%s\n' "$shasource" >"$WORK/expected.files"
    cmp "$tracked_files" "$WORK/expected.files"
    digest=$(cut -f3 "$ROOT/bootstrap/stage2/includes-v1.tsv")
    printf 'KOFUN-INCLUDES-1\nsha256\t%s\n' "$(wc -c <"$ROOT/$shasource" | tr -d ' ')" \
        >"$WORK/expected.bundle"
    cat "$ROOT/$shasource" >>"$WORK/expected.bundle"
    printf '\n' >>"$WORK/expected.bundle"
    cmp "$WORK/expected.bundle" "$WORK/includes-v1.bundle"

    fixture="$WORK/fixture"
    fixture_dir="$fixture/bootstrap/stage2"
    mkdir -p "$fixture_dir/includes"
    cp "$ROOT/$shasource" "$fixture/$shasource"
    cp "$ROOT/bootstrap/stage2/includes-v1.tsv" "$fixture_dir/includes-v1.tsv"
    cp "$tracked_files" "$fixture_dir/includes-v1.files"
    "$WORK/include-bundle" "$fixture" "$WORK/fixture.bundle"
    cmp "$WORK/fixture.bundle" "$WORK/expected.bundle"

    # A checkout cannot add an untracked file to the approved acquisition
    # just by modifying the working inventory and manifest together.
    git_fixture="$WORK/checkout"
    git_dir="$git_fixture/bootstrap/stage2"
    cp -R "$fixture" "$git_fixture"
    cp "$ROOT/bootstrap/stage2/include_bundle.c" "$ROOT/bootstrap/stage2/sha256.c" \
        "$ROOT/bootstrap/stage2/sha256.h" "$git_dir/"
    git -C "$git_fixture" init -q
    git -C "$git_fixture" add -- "$shasource" bootstrap/stage2/includes-v1.files \
        bootstrap/stage2/includes-v1.tsv
    mkdir "$WORK/git-catalog"
    kofun_stage2_include_bundle "$git_fixture" "$WORK/git-catalog"
    cmp "$WORK/git-catalog/includes-v1.bundle" "$WORK/expected.bundle"
    cp "$git_fixture/$shasource" "$git_dir/includes/untracked.kofun"
    printf '%s\n' bootstrap/stage2/includes/untracked.kofun >>"$git_dir/includes-v1.files"
    printf 'untracked\tbootstrap/stage2/includes/untracked.kofun\t%s\n' "$digest" >>"$git_dir/includes-v1.tsv"
    for index_state in unstaged staged; do
        if test "$index_state" = staged; then git -C "$git_fixture" add -- bootstrap/stage2/includes-v1.files; fi
        status=0
        kofun_stage2_include_bundle "$git_fixture" "$WORK/git-catalog" >"$WORK/git-refusal.out" || status=$?
        assert_num "$index_state untracked file refused" "$status" -eq 1
        assert_grep "$index_state untracked file diagnostic" -Fq 'error[E2S226]' "$WORK/git-refusal.out"
        cmp "$WORK/git-catalog/includes-v1.bundle" "$WORK/expected.bundle"
    done

    expect_catalog_refusal() {
        code=$1
        label=$2
        status=0
        "$WORK/include-bundle" "$fixture" \
            "$WORK/fixture.bundle" >"$WORK/refusal.out" 2>"$WORK/refusal.err" || status=$?
        assert_num "$label exit status" "$status" -eq 1
        test ! -s "$WORK/refusal.err" || assert_fail "$label wrote to stderr"
        assert_grep "$label diagnostic" -Fq "error[$code]" "$WORK/refusal.out"
        cmp "$WORK/fixture.bundle" "$WORK/expected.bundle"
    }
    printf '\n' >>"$fixture/$shasource"
    expect_catalog_refusal E2S225 'changed target'
    cp "$ROOT/$shasource" "$fixture/$shasource"
    : >"$fixture_dir/includes-v1.files"
    expect_catalog_refusal E2S226 'untracked target'
    cp "$tracked_files" "$fixture_dir/includes-v1.files"
    mv "$fixture/$shasource" "$WORK/outside.kofun"
    ln -s "$WORK/outside.kofun" "$fixture/$shasource"
    expect_catalog_refusal E2S226 'symbolic link target'
    rm "$fixture/$shasource"
    rmdir "$fixture_dir/includes"
    mkdir "$WORK/outside-dir"
    cp "$ROOT/$shasource" "$WORK/outside-dir/sha256.kofun"
    ln -s "$WORK/outside-dir" "$fixture_dir/includes"
    expect_catalog_refusal E2S226 'symbolic link ancestor'
    rm "$fixture_dir/includes"
    mkdir "$fixture_dir/includes"
    cp "$ROOT/$shasource" "$fixture/$shasource"
    printf 'sha256\t../outside.kofun\t%s\n' "$digest" >"$fixture_dir/includes-v1.tsv"
    expect_catalog_refusal E2S226 'parent path'
    printf 'sha256\t%s\t%s\nsha256\t%s\t%s\n' "$shasource" "$digest" "$shasource" "$digest" \
        >"$fixture_dir/includes-v1.tsv"
    expect_catalog_refusal E2S226 'duplicate manifest name'
    printf 'PASS: verified bounded catalog matches the tracked source; refused catalogs preserve prior bytes\n'
fi

# The oracle is `bootstrap/stage2/sha256.c`, reached through the C seed
# verifier. `kofun digest` would be the pair's own Kofun block, so comparing
# against it would be comparing the block with itself (#1455).
. "$ROOT/bootstrap/stage2/build.sh"
kofun_seed_digest_build "$ROOT" "$WORK/oracle" ||
    assert_fail 'the C seed oracle did not build'

PAIR_KOFUN=${KOFUN_INCLUDE_PAIR_SOURCE:-"$ROOT/bootstrap/stage2/compiler.kofun"}

# ------------------------------------------------------------ the C half

kofun_stage2_build "$ROOT" "$WORK/pair-c"
"$WORK/pair-c" --sha256-selftest >"$WORK/c.digests"
assert_num 'the C half printed one line per vector' "$(grep -c . "$WORK/c.digests")" -eq 4

# --------------------------------------------------------- the Kofun half
#
# A module-headed program reaches the include through the public driver.
mkdir -p "$WORK/package/app"
entry="$WORK/package/app/main.kofun"
printf 'module app.main\ninclude "sha256"\nfn main() -> Int { return sha256_selftest() }\n' >"$entry"
KOFUN_STAGE2_COMPILER="$WORK/pair-c" "$ROOT/bin/kofun" build "$entry" -o "$WORK/pair-kofun" \
    --emit-c "$WORK/block.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "the Kofun include did not build: $(cat "$WORK/build.stderr")"
"$WORK/pair-kofun" >"$WORK/kofun.digests"
if test "$mode" = --include-form; then
    (cd "$WORK/package" && KOFUN_STAGE2_COMPILER="$WORK/pair-c" "$ROOT/bin/kofun" check app/main.kofun) \
        >"$WORK/relative-check.stdout" 2>"$WORK/relative-check.stderr" ||
        assert_fail "checking the package-relative include failed: $(cat "$WORK/relative-check.stderr")"
    node "$ROOT/tests/stage2/sha256-pair/include.mjs" \
        "$PAIR_KOFUN" "$WORK/pair-c" "$entry" "$WORK" "$ROOT"
fi

# ---------------------------------------------------- the three-way compare

assert_eq 'the two halves of the pair agree' \
    "$(cat "$WORK/kofun.digests")" "$(cat "$WORK/c.digests")"

# The same bytes, materialised for the oracle. Spelled here a third time on
# purpose: if this gate built them from either half it would be comparing a
# half against itself.
printf '' >"$WORK/empty.bin"
printf 'abc' >"$WORK/abc.bin"
printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' >"$WORK/nist448.bin"
printf '%s%s' \
    'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn' \
    'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu' >"$WORK/nist896.bin"

compared=0
for name in empty abc nist448 nist896
do
    oracle=$("$WORK/oracle" "$WORK/$name.bin" | cut -d' ' -f1)
    pair=$(grep "^$name " "$WORK/kofun.digests" | cut -d' ' -f2)
    assert_nonempty "the oracle digested $name" "$oracle"
    assert_nonempty "the pair digested $name" "$pair"
    assert_eq "the pair and bootstrap/stage2/sha256.c agree on $name" "$pair" "$oracle"
    compared=$((compared + 1))
done
assert_num 'every vector was compared with the oracle' "$compared" -eq 4

# ------------------------------------------------------- the mutation proof
#
# Three agreeing implementations prove nothing if the comparison cannot fail.
# One round constant is flipped in an independent pinned include, and the
# rebuilt program must disagree with the oracle — otherwise this gate would
# pass on a broken digest.

# Pin a changed target in an independent source acquisition. A stale pin
# is refused separately by E2S225; this test proves the independent oracle
# detects a *correctly pinned* but numerically wrong implementation.
mutant_root="$WORK/mutant-root"
mutant_dir="$mutant_root/bootstrap/stage2"
mkdir -p "$mutant_dir/includes"
source_path=bootstrap/stage2/includes/sha256.kofun
cp "$ROOT/bootstrap/stage2/includes-v1.files" "$mutant_dir/includes-v1.files"
sed 's/1116352408/1116352409/' "$ROOT/$source_path" >"$mutant_root/$source_path"
assert_not_grep 'the mutation changed the block' -Fq -- '1116352408' "$mutant_root/$source_path"
changed_digest=$("$WORK/oracle" "$mutant_root/$source_path" | cut -d' ' -f1)
printf 'sha256\t%s\t%s\n' "$source_path" "$changed_digest" >"$mutant_dir/includes-v1.tsv"
if test ! -x "$WORK/include-bundle"; then kofun_stage2_include_bundle "$ROOT" "$WORK"; fi
"$WORK/include-bundle" "$mutant_root" "$WORK/mutant.bundle"
"$WORK/pair-c" --include-bundle "$WORK/mutant.bundle" --compile-outcome \
    "$entry" "$WORK/mutant.c" "$WORK/mutant.ir" "$WORK/mutant.tokens" >"$WORK/mutant.stdout"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic "$WORK/mutant.c" -o "$WORK/mutant"
"$WORK/mutant" >"$WORK/mutant.digests"

mutant_abc=$(grep '^abc ' "$WORK/mutant.digests" | cut -d' ' -f2)
oracle_abc=$("$WORK/oracle" "$WORK/abc.bin" | cut -d' ' -f1)
assert_nonempty 'the mutant produced a digest' "$mutant_abc"
assert_ne 'a flipped round constant does not reproduce the oracle digest' \
    "$mutant_abc" "$oracle_abc"

printf 'PASS: the Stage 2 pair and bootstrap/stage2/sha256.c agree on four NIST vectors\n'
printf 'PASS: both halves of the pair print identical digests, and a flipped round constant does not\n'
