#!/bin/sh
# Prove `release/prepare.sh` fails closed (#1685).
#
# The command exists so an operator cannot half-cut a release, so the proof has
# to show it *refuses* the ways a half-cut looks: a dirty tree, a malformed
# version, a version whose tag already exists, and an evidence pack that did not
# actually change with VERSION. It also shows the honest path makes exactly the
# two reviewable commits and never pushes.
#
# The scratch repository is a real `git init` with `release/` copied into it and
# a `task` shim first on PATH, so `release/prepare.sh` runs unmodified against
# cheap stand-ins for the two evidence commands and repository-check. Running
# the real `task release-evidence` here would cost minutes and prove a different
# thing; that path is exercised by every real release and by `task verify`.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)

TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
WORK=$(mktemp -d "$TMP_PARENT/release-prepare-self-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

repo="$WORK/repo"
mkdir -p "$repo/release" "$repo/artifacts/release-evidence" "$WORK/bin"
cp "$ROOT/release/prepare.sh" "$ROOT/release/fail-closed.sh" "$repo/release/"
printf '{"pack":"initial"}\n' >"$repo/artifacts/release-evidence/index.json"
printf '0.0.0-seed\n' >"$repo/VERSION"

log="$WORK/task.log"
: >"$log"

# A `task` stand-in. `release-evidence` rewrites the pack unless TASK_NOCHANGE is
# set, so the self-test can drive both the honest path and the empty-binding
# refusal. TASK_LOG names a file it appends its argv to, so the test can require
# that prepare actually invoked the evidence lane.
cat >"$WORK/bin/task" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >>"${TASK_LOG:?}"
case "$1" in
    release-evidence)
        if test -z "${TASK_NOCHANGE:-}"; then
            printf 'x' >>"${TASK_REPO:?}/artifacts/release-evidence/index.json"
        fi
        ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/task"

git -C "$repo" init -q
git -C "$repo" config user.email self-test@example.invalid
git -C "$repo" config user.name 'release self-test'
git -C "$repo" add -A
git -C "$repo" commit -q -m 'base'

failures=0
note() { printf 'FAIL: release prepare self-test: %s\n' "$1" >&2; failures=$((failures + 1)); }

run_prepare() {
    # run_prepare VERSION; stdout+stderr captured by the caller's redirection
    PATH="$WORK/bin:$PATH" TASK_LOG="$log" TASK_REPO="$repo" \
        sh "$repo/release/prepare.sh" "$1"
}

# 1. A dirty tree is refused before anything is written.
printf 'scratch\n' >"$repo/untracked"
if ( cd "$repo" && run_prepare 0.0.2-seed ) >"$WORK/dirty.out" 2>&1; then
    note 'a dirty tree was accepted'
fi
if ! grep -q 'dirty' "$WORK/dirty.out"; then
    note 'the dirty-tree refusal does not say `dirty`'
fi
rm -f "$repo/untracked"

# 2. A malformed version is refused.
for bad in 1.2 0.1.2 0.1.2-rc1 x.y.z-seed; do
    if ( cd "$repo" && run_prepare "$bad" ) >"$WORK/bad.out" 2>&1; then
        note "the malformed version \`$bad\` was accepted"
    fi
done

# 3. A version whose tag already exists is refused.
git -C "$repo" tag v0.0.1-seed
if ( cd "$repo" && run_prepare 0.0.1-seed ) >"$WORK/tag.out" 2>&1; then
    note 'a version with an existing tag was accepted'
fi
if ! grep -q 'already exists' "$WORK/tag.out"; then
    note 'the existing-tag refusal does not say `already exists`'
fi

# 4. An evidence pack that does not change with VERSION is refused: the binding
#    commit would be empty, which is a release whose pack is not bound.
if ( cd "$repo" && PATH="$WORK/bin:$PATH" TASK_LOG="$log" TASK_REPO="$repo" \
        TASK_NOCHANGE=1 sh "$repo/release/prepare.sh" 0.0.3-seed ) \
        >"$WORK/nochange.out" 2>&1; then
    note 'a pack that did not change with VERSION was accepted'
fi
if ! grep -q 'did not change' "$WORK/nochange.out"; then
    note 'the empty-binding refusal does not say `did not change`'
fi

# 5. The honest path: exactly two commits, the right subjects, VERSION written,
#    and the evidence lane invoked.
if ! ( cd "$repo" && run_prepare 0.0.2-seed ) >"$WORK/happy.out" 2>&1; then
    note 'the honest path failed'
    cat "$WORK/happy.out" >&2
fi
test "$(cat "$repo/VERSION")" = '0.0.2-seed' || note 'VERSION was not written'
newest_two=$(git -C "$repo" log --format=%s -n 2 | tr '\n' '|')
test "$newest_two" = 'release: bind evidence to 0.0.2-seed|release: 0.0.2-seed|' ||
    note "the two commit subjects are not the reviewable pair: $newest_two"
test "$(git -C "$repo" log --format=%s -n 1)" = 'release: bind evidence to 0.0.2-seed' ||
    note 'the newest commit is not the evidence binding'
if ! grep -q '^release-evidence$' "$log"; then
    note 'prepare never invoked the evidence lane'
fi
if grep -q 'push' "$log"; then
    note 'prepare invoked a push, which step 6 owns'
fi
# The version-only commit must contain only VERSION.
test "$(git -C "$repo" show --name-only --format= 'HEAD~1')" = 'VERSION' ||
    note 'the version commit touched more than VERSION'

if test "$failures" -ne 0; then
    exit 1
fi
printf '%s\n' 'PASS: release/prepare.sh refuses a dirty tree, a bad version, an existing tag and an unbound pack, and writes the two reviewable commits without pushing'
