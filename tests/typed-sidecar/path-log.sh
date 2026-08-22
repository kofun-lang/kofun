#!/bin/sh
# Records the paths a gate reads, so two concurrent runs can be diffed for a
# path they share. (#1504, from #1315 and #1408)
#
# WHY THIS EXISTS. Two `task verify` runs at once corrupt the companion census
# in tests/typed-sidecar/stage2-events.sh -- "expected all N repository error
# companions, saw N-1" -- on a commit where the gate passes standalone. The
# recorded instance had the two runs in DIFFERENT worktrees with distinct
# KOFUN_GATE_WORK_NAMESPACE values, so whatever they share is not separated by
# the namespace and nobody has found it.
#
# Two sessions reasoned about it from the outside and were wrong in opposite
# directions: one searched every gate script for fixed shared paths, found only
# a worktree-local `mktemp`, and concluded no shared state exists -- a sound
# search answering a narrower question than the one asked of it. The other read
# a concurrent run that exited non-zero as a data point, when that run had
# failed at an earlier task and never reached this gate.
#
# A scheduled experiment cannot settle it, because the effect is not
# deterministic: a run that does not reproduce it is not evidence of absence.
# So this records what was read instead of inferring it from what came out.
#
#   KOFUN_STAGE2_EVENTS_PATH_LOG=/path/to/log   opt-in; unset changes nothing
#
# THE CLASSIFICATION IS THREE-WAY, not the two the issue asked for, because two
# cannot answer the question. "Outside $WORK" contains both paths private to
# this worktree and paths shared with every other one, and only the second kind
# can collide:
#
#   work     under this run's own $WORK          private to the run
#   repo     under $ROOT but not $WORK           private to the worktree
#   outside  neither                             THE ONLY KIND THAT CAN COLLIDE
#
# `work` and `repo` rows are recorded RELATIVE to their root. That is what makes
# two worktrees comparable at all: absolute paths differ by prefix, so a plain
# `comm` over absolute paths reports every line as unique and finds nothing,
# every time, no matter what is shared. Relative rows let `comm` answer the
# question the census actually raises -- which companion did one run see and the
# other not -- and `outside` rows stay absolute because for those the literal
# path IS the shared thing.

# Set by the caller before sourcing: ROOT, WORK.
kofun_path_log_init() {
    test -n "${KOFUN_STAGE2_EVENTS_PATH_LOG:-}" || return 0
    : >"$KOFUN_STAGE2_EVENTS_PATH_LOG"
}

kofun_path_log_record() {
    test -n "${KOFUN_STAGE2_EVENTS_PATH_LOG:-}" || return 0
    for kofun_path_log_item in "$@"; do
        test -n "$kofun_path_log_item" || continue
        case $kofun_path_log_item in
            "$WORK"/*)
                printf 'work\t%s\n' "${kofun_path_log_item#"$WORK"/}"
                ;;
            "$WORK")
                printf 'work\t.\n'
                ;;
            "$ROOT"/*)
                printf 'repo\t%s\n' "${kofun_path_log_item#"$ROOT"/}"
                ;;
            "$ROOT")
                printf 'repo\t.\n'
                ;;
            *)
                printf 'outside\t%s\n' "$kofun_path_log_item"
                ;;
        esac
    done >>"$KOFUN_STAGE2_EVENTS_PATH_LOG"
}

# Sorted and deduplicated, because `comm` requires sorted input and silently
# reports nonsense on unsorted input rather than refusing it.
kofun_path_log_finish() {
    test -n "${KOFUN_STAGE2_EVENTS_PATH_LOG:-}" || return 0
    LC_ALL=C sort -u "$KOFUN_STAGE2_EVENTS_PATH_LOG" \
        >"$KOFUN_STAGE2_EVENTS_PATH_LOG.sorted"
    mv "$KOFUN_STAGE2_EVENTS_PATH_LOG.sorted" \
        "$KOFUN_STAGE2_EVENTS_PATH_LOG"
}
