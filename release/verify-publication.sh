#!/bin/sh
# `docs/RELEASING.md` step 4's publication verification, in one command (#1685).
#
# The document used to carry this as an eighty-line shell block. That block was
# guarded and proved by `tests/release/procedure-blocks.mjs`, but it could not be
# run against a fixture, so nothing showed which refusal a broken release would
# produce. This file is the block, moved out so `tests/release/publication-self-test.sh`
# can drive it with stand-ins and assert each refusal, and `task release-procedure`
# runs that self-test.
#
# It verifies what is already published: that local `HEAD`, remote `main` and the
# remote tag all resolve to the release commit, that the release is a nondraft
# pre-release with exactly the nine expected assets, and that both digest
# manifests verify the seven payloads. It does not create or push anything; the
# tag itself stays in the document, where a human decides to place it.
#
# Overridable for the self-test: RELEASE_REPO, RELEASE_REMOTE, RELEASE_SHA.
set -eu
. "$(dirname -- "$0")/fail-closed.sh" || exit 1

root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'resolving the checkout root'
cd "$root" || fail "entering $root"

release_repo=${RELEASE_REPO:-kofun-lang/kofun}
release_remote=${RELEASE_REMOTE:-release-target}
release_sha=${RELEASE_SHA:-$(git rev-parse HEAD)} || fail 'resolving HEAD'
tag="v$(cat VERSION)" || fail 'reading VERSION'
version=$(cat VERSION) || fail 'reading VERSION'

git fetch --tags "$release_remote" main ||
    fail "fetching main and tags from $release_remote"
test "$(git rev-parse HEAD)" = "$release_sha" ||
    fail "HEAD moved off $release_sha"
test "$(git rev-parse "$release_remote/main")" = "$release_sha" ||
    fail "$release_remote/main is not $release_sha"
remote_main_record=$(git ls-remote --exit-code "$release_remote" \
    refs/heads/main) || fail "$release_remote has no main"
remote_main_sha=${remote_main_record%%[[:space:]]*}
test "$remote_main_sha" = "$release_sha" ||
    fail "remote main is $remote_main_sha, not $release_sha"
remote_tag_record=$(git ls-remote --exit-code "$release_remote" \
    "refs/tags/${tag}") || fail "$tag is not on $release_remote"
remote_tag_sha=${remote_tag_record%%[[:space:]]*}
test "$remote_tag_sha" = "$release_sha" ||
    fail "remote $tag is $remote_tag_sha, not $release_sha"

test "$(gh release view "$tag" --repo "$release_repo" \
    --json isDraft --jq .isDraft)" = false ||
    fail "$tag is still a draft"
test "$(gh release view "$tag" --repo "$release_repo" \
    --json isPrerelease --jq .isPrerelease)" = true ||
    fail "$tag is not marked as a pre-release"
test "$(gh release view "$tag" --repo "$release_repo" \
    --json assets --jq '.assets | length')" -eq 9 ||
    fail "$tag does not carry exactly nine assets"

asset_dir=$(mktemp -d) || fail 'creating a download directory'
trap 'rm -rf "$asset_dir"' EXIT HUP INT TERM
gh release download "$tag" --repo "$release_repo" --dir "$asset_dir" ||
    fail "downloading the $tag assets"
expected_assets=$(printf '%s\n' \
    "kofun-$version.tar.gz" \
    "kofun-$version.tar.gz.sha256" \
    "kofun-native-checkpoint-$version-linux-aarch64.elf" \
    "kofun-native-checkpoint-$version-linux-x86_64.elf" \
    "kofun-native-checkpoint-$version-macos-aarch64.macho" \
    "kofun-native-checkpoint-$version-macos-x86_64.macho" \
    "kofun-native-checkpoint-$version-SHA256SUMS" \
    "kofun-native-checkpoint-$version-windows-aarch64.exe" \
    "kofun-native-checkpoint-$version-windows-x86_64.exe" | LC_ALL=C sort) ||
    fail 'building the expected asset list'
actual_assets=$(for asset in "$asset_dir"/*; do
    printf '%s\n' "${asset##*/}"
done | LC_ALL=C sort) || fail 'listing the downloaded assets'
test "$actual_assets" = "$expected_assets" ||
    fail 'the published assets are not the nine expected names'

digest_tool=$root/bin/kofun-digest || fail 'resolving the checkout root'
(
    cd "$asset_dir" || fail "entering $asset_dir"
    source_sums="kofun-$version.tar.gz.sha256"
    native_sums="kofun-native-checkpoint-$version-SHA256SUMS"
    test "$(wc -l <"$source_sums" | tr -d ' ')" -eq 1 ||
        fail "$source_sums is not one line"
    test "$(wc -l <"$native_sums" | tr -d ' ')" -eq 6 ||
        fail "$native_sums is not six lines"
    test "$(awk 'NF == 2 { print $2 }' "$source_sums")" = \
        "kofun-$version.tar.gz" ||
        fail "$source_sums does not name the source archive"
    expected_native_payloads=$(printf '%s\n' \
        "kofun-native-checkpoint-$version-linux-aarch64.elf" \
        "kofun-native-checkpoint-$version-linux-x86_64.elf" \
        "kofun-native-checkpoint-$version-macos-aarch64.macho" \
        "kofun-native-checkpoint-$version-macos-x86_64.macho" \
        "kofun-native-checkpoint-$version-windows-aarch64.exe" \
        "kofun-native-checkpoint-$version-windows-x86_64.exe" | \
        LC_ALL=C sort) || fail 'building the expected payload list'
    actual_native_payloads=$(awk 'NF == 2 { print $2 }' "$native_sums" | \
        LC_ALL=C sort) || fail "reading the payload names from $native_sums"
    test "$actual_native_payloads" = "$expected_native_payloads" ||
        fail "$native_sums does not name the six checkpoint images"
    "$digest_tool" -c "$source_sums" ||
        fail 'the published source archive does not match its digest'
    "$digest_tool" -c "$native_sums" ||
        fail 'a published checkpoint image does not match its digest'
) || exit 1

printf 'PASS: %s is published at %s with nine assets and both digests verify\n' \
    "$tag" "$release_sha"
