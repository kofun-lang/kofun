# Releasing

A Kofun release is a tag, a set of published notes, and the evidence pack that
was true at that commit. This document is the procedure; `VERSION` is the
authority for the number.

## What a version number promises

Kofun is a research compiler, and the version number says so. `README.md`
states the project status; this section says what the digits mean.

`MAJOR.MINOR.PATCH-seed` while the leading digit is `0`:

- **`-seed`** marks every release cut before the compiler is a general parser
  and type checker. It is not decoration: a `-seed` release promises exactly
  the bounded slices `release/claims.json` evidences, and nothing wider.
- **MINOR** rises when a published claim's state rises, when a claim is added,
  or when a bounded slice widens.
- **PATCH** rises for everything else, including fixes and internal work.
- **No compatibility promise exists at `0.x`.** An accepted RFC does not
  create one; only a claim in `release/claims.json` whose state is
  `implemented` describes something a user may depend on, and even then the
  claim's own `compatibility` field is the promise, not the version number.

The `-seed` suffix is dropped, and a compatibility policy replaces this
section, when the milestones in `docs/ROADMAP.md` say it may — not before.
`docs/ROADMAP.md` §M4 lists what 1.0 requires and, for each item, where it
stands with the command that measured it; none of it is a version-number
decision. Six of the sixteen items are documents nobody has started, and four
of those need a decision rather than engineering time, so the distance to 1.0
is not something a release procedure can shorten.

## The number lives in one place

`VERSION` is the single authority. `bin/kofun --version` reads it, `tests/cli.sh`
asserts what it reads, and `task repository-check` refuses a second copy of the
number written anywhere under `bin/` or in `tests/cli.sh`.

This gate exists because the number had drifted: `bin/kofun` printed a literal
`0.3.38-seed` while the repository was eleven tags further on, and the test
asserted the stale string rather than catching it. Two copies of one fact with
nothing binding them is the drift this repository gates against everywhere
else.

## Release window

Before the first merge of a named, ordered release queue, the release owner
posts a tracker-visible `FREEZE` naming the owner, target tag, starting `main`
SHA, and queue. The freeze takes effect when that post is visible and lasts
through publication and verification of the tag, assets, digests, and final
notes. Only the named owner may write `main`, `VERSION`, a tag, or the release
during that window. A successor may do so only after a tracker-visible handoff
names them and they accept it; no unlisted write may cross the window.

The owner ends the window with a tracker-visible `THAW` that names the exact
final commit SHA, exact tag ref, and published release URL, after completing
the postconditions in steps 7 and 8. A timeout, a green branch, or a pushed tag
does not imply a thaw.

## Procedure

Run the whole procedure in one POSIX shell, beginning with `set -eu`; every
command block below assumes that same fail-closed shell. Use a clean checkout
of `main`, with the working tree clean. Bind every fetch and push to the
intended repository explicitly; do not assume that a remote named `origin` is
`kofun-lang/kofun`.

**That instruction is now checked rather than trusted, in both directions.**
Cutting `v0.11.0-seed`, step 7's block printed `PASS: remote tag ...` while no
such tag existed on the remote: it had been pasted into a shell where `set -eu`
was not in effect, so every `test` in it was advisory and the summary ran
anyway. So each block opens by sourcing `release/fail-closed.sh` — from the
checkout root, where the whole procedure runs — which refuses a shell missing
`e` or `u` and defines `fail`, and every check in every block ends
`|| fail '<what was being proved>'`. The guard catches the shell; the failure
actions mean a block that reaches a wrong answer stops there even if the guard
never ran. `task release-procedure` proves both halves, and runs the guard
rather than only looking for it (#1603).

Read the exit status of each block, not the last line it printed. Step 1 makes
the same point about a pipeline ending in `tail`; it applies to the blocks
themselves:

```sh
set -eu
. ./release/fail-closed.sh || exit 1
release_repo=kofun-lang/kofun
release_remote=release-target
release_url=ssh://git@github.com/kofun-lang/kofun
if ! git remote get-url "$release_remote" >/dev/null 2>&1; then
    git remote add "$release_remote" "$release_url" ||
        fail "adding the $release_remote remote"
fi
fetch_urls=$(git remote get-url --all "$release_remote") ||
    fail "reading the $release_remote fetch URLs"
push_urls=$(git remote get-url --push --all "$release_remote") ||
    fail "reading the $release_remote push URLs"
test "$fetch_urls" = "$release_url" ||
    fail "fetch URL is $fetch_urls, not $release_url"
test "$push_urls" = "$release_url" ||
    fail "push URL is $push_urls, not $release_url"
test "$(gh repo view "$fetch_urls" \
    --json nameWithOwner --jq .nameWithOwner)" = "$release_repo" ||
    fail "$release_remote does not resolve to $release_repo"
git fetch --tags "$release_remote" main ||
    fail "fetching main and tags from $release_remote"
test "$(git rev-parse HEAD)" = "$(git rev-parse "$release_remote/main")" ||
    fail "HEAD is not $release_remote/main"
```

Before admitting a late fix to the release queue, decide whether its defect was
created by the range since the previous tag. **A release does not ship a
regression it created.** Hold the tag until that regression is fixed. A defect
that the previous tag already contains may remain, but the release notes must
name its issue and bounded effect; an available fix alone is not a reason to
widen the release window.

Make that classification from the selected previous release tag, not from
memory. Record that tag in `previous_tag`, then use both an exact byte witness
and ancestry, for example:

```sh
. ./release/fail-closed.sh || exit 1
previous_tag=$(git describe --tags --abbrev=0 --match 'v*-seed' HEAD) ||
    fail 'no v*-seed tag is reachable from HEAD'
test "$(gh release view "$previous_tag" --repo "$release_repo" \
    --json tagName --jq .tagName)" = "$previous_tag" ||
    fail "$previous_tag is not published on $release_repo"
test "$(gh release view "$previous_tag" --repo "$release_repo" \
    --json isDraft --jq .isDraft)" = false ||
    fail "$previous_tag is still a draft"
git show "${previous_tag}:path/to/file" |
    rg --fixed-strings 'exact defective bytes' ||
    fail "those bytes are not in ${previous_tag}"
if git merge-base --is-ancestor SUSPECTED_INTRODUCER "$previous_tag"; then
    printf '%s\n' 'introducer is in the previous release'
else
    ancestry_status=$?
    test "$ancestry_status" -eq 1 ||
        fail "merge-base exited $ancestry_status, so ancestry was not decided"
    printf '%s\n' 'ancestry is inconclusive; reproduce at both refs'
fi
```

The first command proves only that those exact bytes were present. When the
claim is about behavior, build both refs from `git archive` and run the same
reproducer against each. An exit status of 0 from the ancestry command confirms
that the suspected introducing commit was already in the previous tag; an exit
status of 1 proves neither classification by itself, so inspect that commit and
reproduce at both ends of the range. The previous-tag behavior is the deciding
evidence. The `v0.10.0-seed` notes must be the first worked record of this rule:
they must name the inherited defects kept out of its queue, link their issues,
and state whether the queue widened for any of them. Do not cite those notes as
published evidence until the release exists.

1. **Pre-flight the tree locally.** Reserve a quiet machine and run
   `task verify`; it must exit 0 before the release proceeds. Its purpose is to
   catch a broken tree before spending the rest of the procedure on it. It is
   one required gate in the proof chain, followed by exact-main CI in step 6
   and the tag workflow's independent `task verify` in step 7. Neither remote
   run substitutes for a red, killed, incomplete, or missing local run.

   Check the exit status, not the tail of the output — a pipeline ending in
   `tail` reports `tail`'s status and can make a failing run read as green. The
   canonical inventory and classification of load-sensitive assertions and
   timeouts is `tooling/machine-dependent/ledger.tsv`; an `unmeasured` row is
   unknown, not a safe exception. If contention prevents a trustworthy result,
   preserve the exact assertion or case and diagnostic output, commit SHA,
   command and relevant environment (including `CC` and `VERIFY_JOBS`), start
   and end load samples, elapsed time, and exit status. That record diagnoses
   the failed attempt; it does not waive it. Stop, obtain a quiet window, and
   rerun until this step is green.

2. **Refresh the evidence pack.** `task release-evidence`, then
   `task release-claims`. The pack under `artifacts/release-evidence/` is a
   deterministic projection of `release/claims.json`; CI regenerates it and
   requires a byte-identical result, so a stale pack fails the release rather
   than shipping.

3. **Set the number.** Edit `VERSION` to the version being released, following
   the rules above. Commit it alone, so the version bump is one reviewable
   change:

   ```sh
   . ./release/fail-closed.sh || exit 1
   printf '%s\n' 0.3.50-seed >VERSION || fail 'writing VERSION'
   git commit -m "release: 0.3.50-seed" VERSION ||
       fail 'committing the version bump'
   ```

4. **Bind the evidence pack to the number.** The pack records `VERSION` and its
   digest, so changing the number makes the pack from step 2 stale by design.
   Run `task release-evidence`, then `task release-claims`, and commit the
   regenerated pack separately before pushing:

   ```sh
   . ./release/fail-closed.sh || exit 1
   task release-evidence || fail 'regenerating the evidence pack'
   task release-claims || fail 'the regenerated pack does not join its claims'
   git commit -m "release: bind evidence to $(cat VERSION)" \
     -- artifacts/release-evidence || fail 'committing the regenerated pack'
   ```

   Keeping this commit separate preserves the reviewable VERSION-only commit
   without leaving the release commit bound to the previous version's pack.

5. **Confirm the tree agrees.** `task repository-check` must pass; it compares
   `bin/kofun --version` against `VERSION` and refuses a literal written
   elsewhere.

6. **Push and let exact-main CI prove it.** Record `release_sha=$(git rev-parse
   HEAD)`, push `HEAD` to `refs/heads/main` on the validated `release_remote`,
   fetch that remote again, and require `release-target/main` to equal that SHA.
   Wait for all four GitHub-hosted CI jobs required by this procedure at that
   exact SHA to pass: Kofun verification, Backlog issue state, Native host
   evidence binding, and Release evidence pack. Record the CI run URL and its
   `head_sha`. The native binding is a separate required proof because the
   shallow, tokenless `task verify` lane cannot resolve the provenance of the
   committed six-host evidence.

   ```sh
   . ./release/fail-closed.sh || exit 1
   release_sha=$(git rev-parse HEAD) || fail 'resolving HEAD'
   git push "$release_remote" "HEAD:refs/heads/main" ||
       fail "pushing HEAD to $release_remote main"
   git fetch "$release_remote" main || fail "fetching $release_remote main"
   test "$(git rev-parse "$release_remote/main")" = "$release_sha" ||
       fail "$release_remote/main is not $release_sha"
   remote_main_record=$(git ls-remote --exit-code "$release_remote" \
       refs/heads/main) || fail "$release_remote has no main"
   remote_main_sha=${remote_main_record%%[[:space:]]*}
   test "$remote_main_sha" = "$release_sha" ||
       fail "remote main is $remote_main_sha, not $release_sha"
   ```

7. **Tag the proven commit and verify publication.** Confirm that local `HEAD`
   and remote `main` still equal `release_sha`. Fetch again *after* the CI wait
   so the comparison cannot use a stale remote-tracking ref. The tag is `v`
   followed by `VERSION`, exactly, and it must resolve to that same SHA:

   ```sh
   . ./release/fail-closed.sh || exit 1
   tag="v$(cat VERSION)" || fail 'reading VERSION'
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
   git tag "$tag" "$release_sha" || fail "creating $tag"
   test "$(git rev-list -n 1 "$tag")" = "$release_sha" ||
       fail "$tag does not resolve to $release_sha"
   git push "$release_remote" "refs/tags/${tag}:refs/tags/${tag}" ||
       fail "pushing $tag"
   remote_tag_record=$(git ls-remote --exit-code "$release_remote" \
       "refs/tags/${tag}") || fail "$tag is not on $release_remote"
   remote_tag_sha=${remote_tag_record%%[[:space:]]*}
   test "$remote_tag_sha" = "$release_sha" ||
       fail "remote $tag is $remote_tag_sha, not $release_sha"
   ```

   Pushing that tag runs `.github/workflows/release.yml`, which **refuses a
   tag that disagrees with `VERSION`**, runs `task verify` at the tagged
   commit rather than trusting the branch run, builds a reproducible source
   archive with `git archive`, rebuilds the six bounded native checkpoint
   images, and attaches them with Kofun-computed SHA-256 manifests to the
   release. Wait for that workflow to succeed at `release_sha`, and record its
   URL and `head_sha`.

   The release is not complete merely because the workflow is green. Fetch the
   tag again and require local tag, remote tag, workflow head, and
   `release_sha` to agree. Inspect the published release and require a `-seed`
   version to be marked as a pre-release. A new release is created with that
   flag; the workflow's existing-release upload path preserves existing
   metadata, so correct a pre-existing release before declaring success.
   Require exactly nine assets with the expected versioned names: the source
   archive and its digest, six native checkpoint images, and native
   `SHA256SUMS`. Download them and verify both digest files against the seven
   payload assets.

   ```sh
   . ./release/fail-closed.sh || exit 1
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

   version=$(cat VERSION) || fail 'reading VERSION'
   asset_dir=$(mktemp -d) || fail 'creating a download directory'
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

   digest_tool=$(pwd)/bin/kofun-digest || fail 'resolving the checkout root'
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
   ```

8. **Write the notes.** The workflow generates notes from the commit range;
   replace them with what changed in terms of claims — which capability rose,
   which bounded slice widened, which refusals moved.
   `artifacts/release-evidence/CLAIMS.md` is the source for that wording, so
   the release notes and the claims manifest do not describe one capability
   two different ways. Also list each inherited defect deliberately left for a
   later release, with its issue number, bounded effect, and previous-tag
   evidence. Link the exact-main CI and exact-tag workflow recorded in steps 6
   and 7. A failed contention attempt from step 1 may be recorded as diagnostic
   context, but the notes must not describe it as a release-gate waiver. Recheck
   the published notes and all step 7 postconditions after editing them; only
   then post `THAW` with the final SHA, tag ref, and release URL.

## What a release includes, and what it does not

**It includes** a source archive and its SHA-256. That is the acquisition
artifact an independent builder starts from, and the digest is what makes
"the right bytes" checkable — the same question
`bootstrap/selfhost/declare-inputs.sh` answers file by file.

It also includes the exact six x86-64/AArch64 Linux, Windows, and macOS images
covered by the `native-six-host-execution` claim, plus one Kofun-computed digest
manifest. Their names contain `native-checkpoint`: Linux prints `42`; the
Windows and macOS images return zero with no output. They prove final-image
encoding and matching-host execution; they are not general compiler CLIs.

**It does not include a multi-platform compiler install.** That remains an M4
deliverable (`docs/ROADMAP.md` §M4, "multi-platform release"). The distinction
is deliberate: publishing bounded executable evidence must not imply that the
full language or toolchain already runs on those six targets.
