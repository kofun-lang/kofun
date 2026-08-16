#!/bin/sh
# Proof that the #1504 path log classifies, and that it is inert when unset.
#
# Exercises `tests/typed-sidecar/path-log.sh` DIRECTLY rather than through a
# `stage2-events` run, which builds five binaries and drives 400+ companions.
# That is not only about cost: a self-test that can only run inside a
# ten-minute gate is one nobody runs while changing the thing it checks.
#
# The must-not-fire case is first and is the point. This instrument exists to
# make a null result meaningful -- "no shared paths were found" is worth
# something only if the log could have held one. An instrument that records
# nothing, or that files every path under the same class, reports exactly the
# same silence as a clean machine.
set -eu

LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF/../.." && pwd)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/kofun-path-log-self-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

WORK="$TMP/stage2-semantic-events"
mkdir -p "$WORK/plain"

pass=0
fail=0
check() {
    if test "$2" = "$3"; then
        printf 'ok   %-46s %s\n' "$1" "$3"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s: wanted [%s], got [%s]\n' "$1" "$3" "$2" >&2
        fail=$((fail + 1))
    fi
}

# shellcheck source=tests/typed-sidecar/path-log.sh
. "$ROOT/tests/typed-sidecar/path-log.sh"

# 1. MUST NOT FIRE: with the variable unset the recorder writes nothing at all.
#
#    Checked against a log that ALREADY EXISTS and has known content, not
#    against a path the recorder was never given. The first version of this case
#    asserted that an unrelated file had not appeared, which no defect could
#    have falsified -- it would have passed against a recorder that wrote to the
#    log on every call. A must-not-fire case has to be reachable by the failure
#    it excludes.
#
#    WHAT THIS CASE COVERS, measured by mutating the recorder rather than
#    assumed, because "the mutation misses" is the usual way a proof like this
#    is worth nothing:
#
#      guard deleted from kofun_path_log_record   CAUGHT, by `set -u` --
#        the unbound variable aborts before any assertion runs. That is the
#        realistic defect and it is caught loudly, but it is caught by the
#        shell, not by the check below.
#      recorder defaults to a path of its own when unset   NOT CAUGHT.
#        A mutation writing to /tmp/leaked.log left this sentinel untouched and
#        every case here passed. Nothing cheap distinguishes "wrote nowhere"
#        from "wrote somewhere I did not name", and pretending otherwise would
#        be the kind of reassurance this file exists to refuse.
SENTINEL="$TMP/sentinel.log"
printf 'untouched\n' >"$SENTINEL"
( unset KOFUN_STAGE2_EVENTS_PATH_LOG
  kofun_path_log_init
  kofun_path_log_record "$ROOT/tests/x" "$WORK/y" /etc/hosts
  kofun_path_log_finish )
check "unset: an existing log is untouched" "$(cat "$SENTINEL")" untouched
check "unset: nothing new appeared beside it" \
    "$(find "$TMP" -maxdepth 1 -name '*.log' | wc -l | tr -d ' ')" 1

#    And the same recorder, given the same paths WITH the variable set, must
#    write. Otherwise the case above passes because the recorder is broken.
KOFUN_STAGE2_EVENTS_PATH_LOG="$SENTINEL" kofun_path_log_init
KOFUN_STAGE2_EVENTS_PATH_LOG="$SENTINEL" kofun_path_log_record /etc/hosts
check "set: the same call does write" "$(grep -c '^outside	/etc/hosts$' "$SENTINEL")" 1

# 2. Each class lands where it belongs, and repo/work rows are relative.
KOFUN_STAGE2_EVENTS_PATH_LOG="$TMP/log"
export KOFUN_STAGE2_EVENTS_PATH_LOG
kofun_path_log_init
kofun_path_log_record \
    "$ROOT/tests/typed-sidecar/fixtures/stage2_events.kofun" \
    "$WORK/plain/repository-error-companions" \
    /var/tmp/some-shared-thing \
    "$ROOT" \
    "$WORK"
kofun_path_log_finish

check "repo row is relative" \
    "$(grep -c '^repo	tests/typed-sidecar/fixtures/stage2_events.kofun$' "$TMP/log")" 1
check "work row is relative" \
    "$(grep -c '^work	plain/repository-error-companions$' "$TMP/log")" 1
check "outside row stays absolute" \
    "$(grep -c '^outside	/var/tmp/some-shared-thing$' "$TMP/log")" 1
check "the roots themselves are recorded" \
    "$(grep -c '	\.$' "$TMP/log")" 2

# 3. WORK sits under ROOT in a real run, so the WORK arm must win. If `repo`
#    matched first, every private path would be filed as worktree state and the
#    only class that can collide would be diluted by hundreds of rows.
WORK_UNDER_ROOT="$ROOT/build/stage2-semantic-events"
( WORK="$WORK_UNDER_ROOT"
  kofun_path_log_init
  kofun_path_log_record "$WORK_UNDER_ROOT/plain/out"
  kofun_path_log_finish )
check "WORK under ROOT classifies as work, not repo" \
    "$(grep -c '^work	plain/out$' "$TMP/log")" 1

# 4. Sorted and deduplicated, because `comm` gives nonsense on unsorted input
#    rather than refusing it -- a wrong answer that looks like an answer.
kofun_path_log_init
kofun_path_log_record "$ROOT/b" "$ROOT/a" "$ROOT/b" "$ROOT/a"
kofun_path_log_finish
check "deduplicated" "$(grep -c . "$TMP/log")" 2
check "sorted" \
    "$(LC_ALL=C sort -c "$TMP/log" 2>/dev/null && echo sorted || echo unsorted)" sorted

# 5. Two logs from different roots are comparable by `comm`, which is the whole
#    point: absolute paths differ by prefix, so a comm over them finds nothing
#    no matter what is shared.
A="$TMP/a.log"; B="$TMP/b.log"
KOFUN_STAGE2_EVENTS_PATH_LOG="$A" WORK="$TMP/wa" \
    ROOT=/somewhere/worktree-a sh -c '
        . "'"$ROOT"'/tests/typed-sidecar/path-log.sh"
        kofun_path_log_init
        kofun_path_log_record /somewhere/worktree-a/tests/shared.stderr /var/tmp/collide
        kofun_path_log_finish'
KOFUN_STAGE2_EVENTS_PATH_LOG="$B" WORK="$TMP/wb" \
    ROOT=/elsewhere/worktree-b sh -c '
        . "'"$ROOT"'/tests/typed-sidecar/path-log.sh"
        kofun_path_log_init
        kofun_path_log_record /elsewhere/worktree-b/tests/shared.stderr /var/tmp/collide
        kofun_path_log_finish'
check "comm finds the repo path common to both roots" \
    "$(comm -12 "$A" "$B" | grep -c '^repo	tests/shared.stderr$')" 1
check "comm finds the outside path common to both roots" \
    "$(comm -12 "$A" "$B" | grep -c '^outside	/var/tmp/collide$')" 1

printf '\n%s case(s) passed, %s failed\n' "$pass" "$fail"
test "$fail" -eq 0 || exit 1
printf 'PASS: the path log classifies, stays inert when unset, and diffs across roots\n'
