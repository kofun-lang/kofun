#!/bin/sh
# Prove `release/verify-publication.sh` fails closed (#1685).
#
# The command is the eighty-line publication block from `docs/RELEASING.md`,
# moved out so it can be run against fixtures. Moving a check out of the
# document must not move it out of the proof, so this drives the command with a
# scratch git remote, a `gh` stand-in and a digest stand-in, and asserts that
# each way a broken publication can look is refused: a draft, a non-prerelease,
# a short asset list, a missing asset, a digest mismatch, and a release commit
# that disagrees with `HEAD`.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)

TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
WORK=$(mktemp -d "$TMP_PARENT/release-publication-self-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

repo="$WORK/repo"
mkdir -p "$repo/release" "$repo/bin" "$WORK/bin"
cp "$ROOT/release/verify-publication.sh" "$ROOT/release/fail-closed.sh" "$repo/release/"
cp "$ROOT/bin/kofun-digest" "$repo/bin/kofun-digest"
printf '0.0.1-seed\n' >"$repo/VERSION"
printf 'payload\n' >"$repo/payload.txt"

git -C "$repo" init -q -b main
git -C "$repo" config user.email self-test@example.invalid
git -C "$repo" config user.name 'release self-test'
git -C "$repo" add -A
git -C "$repo" commit -q -m base
git -C "$repo" tag v0.0.1-seed
sha=$(git -C "$repo" rev-parse HEAD)

git init -q --bare "$WORK/remote.git"
git -C "$repo" remote add release-target "$WORK/remote.git"
git -C "$repo" push -q release-target main
git -C "$repo" push -q release-target v0.0.1-seed

# A `gh` stand-in for the two subcommands the script uses.
cat >"$WORK/bin/gh" <<'SHIM'
#!/bin/sh
command=$1
sub=$2
case "$command $sub" in
    'release view')
        json=; jqexpr=
        shift 2
        while test "$#" -gt 0; do
            case "$1" in
                --json) json=$2; shift 2 ;;
                --jq) jqexpr=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$jqexpr" in
            .isDraft) cat "${GH_FIXTURE:?}/is_draft" ;;
            .isPrerelease) cat "${GH_FIXTURE:?}/is_prerelease" ;;
            '.assets | length') cat "${GH_FIXTURE:?}/asset_count" ;;
            *) printf 'fake gh: unknown --jq %s\n' "$jqexpr" >&2; exit 2 ;;
        esac
        ;;
    'release download')
        dir=
        shift 2
        while test "$#" -gt 0; do
            case "$1" in
                --dir) dir=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        cp "${GH_FIXTURE:?}"/assets/* "$dir/" || exit 1
        ;;
    *)
        printf 'fake gh: unsupported: %s\n' "$*" >&2
        exit 2
        ;;
esac
SHIM
chmod +x "$WORK/bin/gh"

# A digest stand-in: `-c FILE` fails when FILE contains BAD, which is how the
# digest-mismatch mutation is expressed without real hashes.
cat >"$WORK/bin/fake-digest" <<'SHIM'
#!/bin/sh
if test "${1:-}" = '-c'; then
    if grep -q BAD "$2"; then
        printf 'fake digest: mismatch\n' >&2
        exit 1
    fi
fi
exit 0
SHIM
chmod +x "$WORK/bin/fake-digest"

version=0.0.1-seed
make_fixture() {
    dir=$1
    rm -rf "$dir"
    mkdir -p "$dir/assets"
    for asset in \
        "kofun-$version.tar.gz" \
        "kofun-native-checkpoint-$version-linux-aarch64.elf" \
        "kofun-native-checkpoint-$version-linux-x86_64.elf" \
        "kofun-native-checkpoint-$version-macos-aarch64.macho" \
        "kofun-native-checkpoint-$version-macos-x86_64.macho" \
        "kofun-native-checkpoint-$version-windows-aarch64.exe" \
        "kofun-native-checkpoint-$version-windows-x86_64.exe"
    do
        printf 'x\n' >"$dir/assets/$asset"
    done
    printf '0000000000000000000000000000000000000000000000000000000000000000  kofun-%s.tar.gz\n' \
        "$version" >"$dir/assets/kofun-$version.tar.gz.sha256"
    : >"$dir/assets/kofun-native-checkpoint-$version-SHA256SUMS"
    for asset in \
        "kofun-native-checkpoint-$version-linux-aarch64.elf" \
        "kofun-native-checkpoint-$version-linux-x86_64.elf" \
        "kofun-native-checkpoint-$version-macos-aarch64.macho" \
        "kofun-native-checkpoint-$version-macos-x86_64.macho" \
        "kofun-native-checkpoint-$version-windows-aarch64.exe" \
        "kofun-native-checkpoint-$version-windows-x86_64.exe"
    do
        printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' \
            "$asset" >>"$dir/assets/kofun-native-checkpoint-$version-SHA256SUMS"
    done
    printf 'false\n' >"$dir/is_draft"
    printf 'true\n' >"$dir/is_prerelease"
    printf '9\n' >"$dir/asset_count"
}
make_fixture "$WORK/fx-ok"

run_verify() {
    fixture=$1
    shift
    ( cd "$repo" && PATH="$WORK/bin:$PATH" GH_FIXTURE="$fixture" \
        KOFUN_DIGEST_TOOL="$WORK/bin/fake-digest" RELEASE_SHA="$sha" \
        RELEASE_REPO=example/repo RELEASE_REMOTE=release-target \
        sh "$repo/release/verify-publication.sh" "$@" )
}

failures=0
note() { printf 'FAIL: release publication self-test: %s\n' "$1" >&2; failures=$((failures + 1)); }

# 1. The honest publication passes.
if ! run_verify "$WORK/fx-ok" >"$WORK/ok.out" 2>&1; then
    note 'the honest publication was refused'
    cat "$WORK/ok.out" >&2
fi

# 2. A draft is refused.
cp -r "$WORK/fx-ok" "$WORK/fx-draft"
printf 'true\n' >"$WORK/fx-draft/is_draft"
if run_verify "$WORK/fx-draft" >"$WORK/draft.out" 2>&1; then
    note 'a draft release was accepted'
fi
grep -q 'still a draft' "$WORK/draft.out" || note 'the draft refusal does not say `still a draft`'

# 3. A non-prerelease is refused.
cp -r "$WORK/fx-ok" "$WORK/fx-pre"
printf 'false\n' >"$WORK/fx-pre/is_prerelease"
if run_verify "$WORK/fx-pre" >"$WORK/pre.out" 2>&1; then
    note 'a release not marked pre-release was accepted'
fi
grep -q 'pre-release' "$WORK/pre.out" || note 'the prerelease refusal does not say `pre-release`'

# 4. An asset count other than nine is refused.
cp -r "$WORK/fx-ok" "$WORK/fx-count"
printf '8\n' >"$WORK/fx-count/asset_count"
if run_verify "$WORK/fx-count" >"$WORK/count.out" 2>&1; then
    note 'a short asset list was accepted'
fi
grep -q 'nine assets' "$WORK/count.out" || note 'the count refusal does not say `nine assets`'

# 5. A missing expected asset is refused even when the count is nine.
cp -r "$WORK/fx-ok" "$WORK/fx-missing"
rm "$WORK/fx-missing/assets/kofun-$version.tar.gz"
printf 'x\n' >"$WORK/fx-missing/assets/kofun-$version-unexpected.bin"
if run_verify "$WORK/fx-missing" >"$WORK/missing.out" 2>&1; then
    note 'a wrong asset name was accepted'
fi
grep -q 'nine expected names' "$WORK/missing.out" ||
    note 'the asset-name refusal does not say `nine expected names`'

# 6. A digest mismatch is refused. The manifest stays one line naming the
#    archive, so the `is not one line` check does not fire first; the digest
#    stand-in rejects the BAD hash.
cp -r "$WORK/fx-ok" "$WORK/fx-bad"
printf 'BAD  kofun-%s.tar.gz\n' "$version" \
    >"$WORK/fx-bad/assets/kofun-$version.tar.gz.sha256"
if run_verify "$WORK/fx-bad" >"$WORK/bad.out" 2>&1; then
    note 'a digest mismatch was accepted'
fi
grep -q 'does not match its digest' "$WORK/bad.out" ||
    note 'the digest refusal does not say `does not match its digest`'

# 7. A release commit that disagrees with HEAD is refused.
if ( cd "$repo" && PATH="$WORK/bin:$PATH" GH_FIXTURE="$WORK/fx-ok" \
        KOFUN_DIGEST_TOOL="$WORK/bin/fake-digest" RELEASE_SHA=0000000000000000000000000000000000000000 \
        RELEASE_REPO=example/repo RELEASE_REMOTE=release-target \
        sh "$repo/release/verify-publication.sh" ) >"$WORK/sha.out" 2>&1; then
    note 'a release SHA that disagrees with HEAD was accepted'
fi
grep -q 'HEAD moved off' "$WORK/sha.out" || note 'the SHA refusal does not say `HEAD moved off`'

if test "$failures" -ne 0; then
    exit 1
fi
printf '%s\n' 'PASS: release/verify-publication.sh refuses a draft, a non-prerelease, a short list, a wrong name, a digest mismatch and a disagreeing SHA, and passes the honest publication'
