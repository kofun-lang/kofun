#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
EVIDENCE="$ROOT/artifacts/native-host-evidence.tsv"
PROVENANCE="$ROOT/artifacts/native-host-provenance.tsv"
SUMS="$ROOT/bootstrap/native/SHA256SUMS"
ASSERT_CONTEXT=native-host-evidence
. "$ROOT/tests/assertions/assert.sh"

assert_file_nonempty "host observation file" "$EVIDENCE"
assert_file_nonempty "host provenance file" "$PROVENANCE"
assert_num "host observation row count" "$(wc -l <"$EVIDENCE" | tr -d ' ')" -eq 6
assert_num "provenance row count" "$(wc -l <"$PROVENANCE" | tr -d ' ')" -eq 3

commit=$(awk -F '\t' '$1 == "commit" { print $2 }' "$PROVENANCE")
run=$(awk -F '\t' '$1 == "run" { print $2 }' "$PROVENANCE")
attempt=$(awk -F '\t' '$1 == "attempt" { print $2 }' "$PROVENANCE")
assert_num "commit digest width" "${#commit}" -eq 40
case $commit in *[!0-9a-f]*) assert_fail "commit digest is not lowercase hexadecimal: $commit" ;; esac
case $run in ''|*[!0-9]*) assert_fail "run identity is not numeric: $run" ;; esac
case $attempt in ''|*[!0-9]*) assert_fail "run attempt is not numeric: $attempt" ;; esac

# The two fields above are what make a row an attestation rather than a table,
# and until #1425 they were only shape-checked: a run identity that had never
# existed and a commit that named nothing both passed. The digest, row-count and
# platform assertions were solid throughout — the blind spot was precisely the
# pair that says where the observation came from.
#
# Both are resolved here, and they refuse for separate reasons on purpose. A
# fabricated run and an invented commit are different mistakes, and one shared
# message would leave a reviewer unable to tell which they had made.

# Reachability is judged against a named ref rather than HEAD. The backlog stamp
# checker does it against HEAD and a stale worktree makes it invent failures that
# name real commits; the failure message here therefore says which ref the
# judgement used, so the same confusion costs one line instead of an
# investigation.
# A shallow checkout cannot answer the reachability question at all, and the
# repository's default CI checkout is shallow. Failing there would report a
# false "unreachable" against a commit that is genuinely in the history — the
# exact false alarm the backlog stamp checker produces from a stale worktree.
# Absence of the answer is announced; it is never reported as a wrong answer.
commit_ref=${KOFUN_NATIVE_HOST_EVIDENCE_REF:-origin/main}
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' \
        "native-host-evidence: NOT VERIFIED: no git repository, so evidence commit $commit was not resolved" >&2
elif [ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    printf '%s\n' \
        "native-host-evidence: NOT VERIFIED: shallow checkout, so evidence commit $commit was not resolved" >&2
elif git -C "$ROOT" rev-parse --verify --quiet "$commit_ref" >/dev/null 2>&1; then
    if ! git -C "$ROOT" merge-base --is-ancestor "$commit" "$commit_ref" 2>/dev/null; then
        assert_fail "evidence commit $commit is not reachable from $commit_ref"
    fi
elif ! git -C "$ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
    assert_fail "evidence commit $commit is not an object in this repository ($commit_ref is absent)"
elif ! git -C "$ROOT" merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
    assert_fail "evidence commit $commit is not reachable from HEAD ($commit_ref is absent)"
fi

# Resolving the run needs the API. Absence of a token is a real condition in a
# fresh clone, so it is tolerated — but it prints, because a silent skip is the
# defect this check exists to remove, wearing a different hat.
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && command -v gh >/dev/null 2>&1; then
    run_sha=$(gh run view "$run" --repo kofun-lang/kofun --json headSha \
        --jq .headSha 2>/dev/null || true)
    if [ -z "$run_sha" ]; then
        assert_fail "evidence names workflow run $run, which does not resolve"
    fi
    if [ "$run_sha" != "$commit" ]; then
        assert_fail "workflow run $run ran on $run_sha, not on the evidence commit $commit"
    fi
else
    printf '%s\n' \
        "native-host-evidence: NOT VERIFIED: no API token, so workflow run $run was not resolved" >&2
fi

seen=''
tab=$(printf '\t')
while IFS="$tab" read -r schema row_commit row_run row_attempt target runner platform digest result; do
    assert_eq "$target schema" "$schema" native-host-execution/v1
    assert_eq "$target commit" "$row_commit" "$commit"
    assert_eq "$target run" "$row_run" "$run"
    assert_eq "$target attempt" "$row_attempt" "$attempt"
    case " $seen " in *" $target "*) assert_fail "duplicate target: $target" ;; esac
    seen="$seen $target"

    case $target in
        linux-x86_64)
            path=core_return_42-x86_64.elf
            assert_eq "$target runner" "$runner" ubuntu-24.04
            assert_eq "$target platform" "$platform" linux/x86_64
            assert_eq "$target result" "$result" 'output=42;status=0'
            ;;
        linux-aarch64)
            path=core_return_42-aarch64.elf
            assert_eq "$target runner" "$runner" ubuntu-24.04-arm
            assert_eq "$target platform" "$platform" linux/aarch64
            assert_eq "$target result" "$result" 'output=42;status=0'
            ;;
        windows-x86_64)
            path=pe32plus/x86_64-windows.pe
            assert_eq "$target runner" "$runner" windows-2025
            assert_eq "$target platform" "$platform" windows/X64
            assert_eq "$target result" "$result" 'output=empty;status=0'
            ;;
        windows-aarch64)
            path=pe32plus/aarch64-windows.pe
            assert_eq "$target runner" "$runner" windows-11-arm
            assert_eq "$target platform" "$platform" windows/Arm64
            assert_eq "$target result" "$result" 'output=empty;status=0'
            ;;
        macos-x86_64)
            path=macho64-signed/x86_64-macos-signed.macho
            assert_eq "$target runner" "$runner" macos-15-intel
            assert_eq "$target platform" "$platform" macos/x86_64
            assert_eq "$target result" "$result" 'codesign=valid;output=empty;status=0'
            ;;
        macos-aarch64)
            path=macho64-signed/aarch64-macos-signed.macho
            assert_eq "$target runner" "$runner" macos-15
            assert_eq "$target platform" "$platform" macos/arm64
            assert_eq "$target result" "$result" 'codesign=valid;output=empty;status=0'
            ;;
        *) assert_fail "unexpected target: $target" ;;
    esac
    expected=$(awk -v path="$path" '$2 == path { print $1 }' "$SUMS")
    assert_nonempty "$target pinned digest" "$expected"
    assert_eq "$target digest" "$digest" "$expected"
done <"$EVIDENCE"

for target in \
    linux-x86_64 linux-aarch64 \
    windows-x86_64 windows-aarch64 \
    macos-x86_64 macos-aarch64
do
    case " $seen " in *" $target "*) ;; *) assert_fail "missing target: $target" ;; esac
done

printf '%s\n' \
    "PASS: six Kofun-emitted images executed on matching Linux, Windows, and macOS hosts"
