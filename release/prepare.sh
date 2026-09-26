#!/bin/sh
# `docs/RELEASING.md` steps 2-5 in one command (#1685).
#
# The procedure used to be four manual commands and two hand-written commits
# with prose between them, and the whole point of this file is that a release
# operator cannot half-do it: either the two reviewable commits exist and
# `task repository-check` passed, or the command exited non-zero. It never
# pushes, so the push in step 6 stays the one deliberate act that crosses to
# the remote.
#
# Usage: sh release/prepare.sh VERSION
#        e.g. sh release/prepare.sh 0.13.3-seed
#
# It refuses a dirty tree before it writes anything, refuses a version that is
# not `MAJOR.MINOR.PATCH-seed` while the leading digit is 0, and refuses a
# version whose tag already exists. The two commits it makes are exactly:
#
#   release: VERSION
#   release: bind evidence to VERSION
#
# which is the pair a reviewer reads; folding them into one commit would hide
# the version bump inside a regenerated evidence pack.
set -eu
. "$(dirname -- "$0")/fail-closed.sh" || exit 1

root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd) ||
    fail 'resolving the checkout root'
cd "$root" || fail "entering $root"

test "$#" -eq 1 || fail 'usage: sh release/prepare.sh VERSION'

version=$1
major=${version%%-seed}
test "$major" != "$version" ||
    fail "VERSION must end in -seed before 1.0; got \`$version\`"
test "$(printf '%s' "$major" | tr -cd '.' | wc -c | tr -d ' ')" -eq 2 ||
    fail "VERSION must be MAJOR.MINOR.PATCH-seed; got \`$version\`"
case $major in
    *[!0-9.]*) fail "VERSION has a non-digit in its numeric part: \`$version\`" ;;
esac
case $major in
    .*|*.|*..*) fail "VERSION has an empty numeric component: \`$version\`" ;;
esac

test -z "$(git status --porcelain)" ||
    fail 'the tree is dirty; commit or stash before release-prepare'
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null 2>&1; then
    fail "the tag v$version already exists"
fi

# Steps 2 and 3. The pre-flight refresh catches a pack that a merged change
# left behind before the number moves, and the VERSION-only commit is the first
# of the two reviewable commits.
task release-evidence || fail 'refreshing the evidence pack before VERSION'
task release-claims || fail 'the pre-VERSION pack does not join its claims'
printf '%s\n' "$version" >VERSION || fail 'writing VERSION'
git commit -m "release: $version" VERSION || fail 'committing the version bump'

# Step 4. The pack records VERSION and its digest, so changing the number makes
# it stale by design; regenerate it and commit it alone.
task release-evidence || fail 'regenerating the evidence pack for VERSION'
task release-claims || fail 'the regenerated pack does not join its claims'
if git diff --quiet -- artifacts/release-evidence; then
    fail 'the evidence pack did not change with VERSION, so the binding commit is empty'
fi
git commit -m "release: bind evidence to $version" -- artifacts/release-evidence ||
    fail 'committing the regenerated evidence pack'

# Step 5.
task repository-check || fail 'repository-check after the two release commits'

printf 'PASS: release-prepare wrote %s as two commits and did not push\n' "$version"
