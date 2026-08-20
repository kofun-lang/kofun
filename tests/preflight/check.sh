#!/bin/sh
# Every structural obligation a new task or fixture carries, reported at once
# (#1523).
#
# Adding one `task` target and one diagnostic fixture obliges six other files,
# each enforced by a different gate — and each discoverable only after the
# previous one is satisfied, because the gate that finds it does not run until
# the gate before it passes. Two of the six are twelve lines apart in one file
# and still fail one at a time.
#
# This target exists to collapse that schedule into one run of a few seconds.
# It changes no obligation and replaces no gate: every rule below still belongs
# to the file that owns it, and the owning gate is still the authority.
#
# TWO RULES THIS SCRIPT KEEPS, because breaking either makes it worse than
# nothing:
#
#   1. It never stops at the first failure. A preflight that reported one
#      obligation per run would reproduce the schedule it exists to remove.
#   2. It never restates an expectation. Counters are read out of the file that
#      owns them and the byte bound out of the header that defines it, so a
#      preflight that disagreed with the gate it anticipates cannot arise. Where
#      the owning tool is itself fast, this runs that tool rather than
#      reimplementing its rule.
#
# And extraction failure is loud. A regex that silently matches nothing yields
# an empty expectation that compares equal to nothing — a restatement wearing a
# reference's clothes — so every extraction is checked for emptiness and names
# the anchor that moved.
#
#   sh tests/preflight/check.sh             report every obligation
#   sh tests/preflight/check.sh --prove     demonstrate each check can refuse
#
# NOT IN `task verify`, deliberately. Six of these seven checks are the fast
# half of gates `verify` already runs; adding them there would pay for each
# twice and slow the thing this speeds up. Recorded in
# `tooling/gate-reachability/unreachable.tsv` with that reason.

set -u

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)

# Seams, so `--prove` can point one check at a mutated copy without disturbing
# the tree, and so the three delegating checks can be shown to propagate a
# failure rather than swallow it.
EVENTS=${KOFUN_PREFLIGHT_EVENTS:-"$ROOT/tests/typed-sidecar/stage2-events.sh"}
INPUTS=${KOFUN_PREFLIGHT_INPUTS:-"$ROOT/tests/pair-coverage/inputs.tsv"}
HEADER=${KOFUN_PREFLIGHT_HEADER:-"$ROOT/bootstrap/stage2/semantic_events.h"}
TASK_HELP=${KOFUN_PREFLIGHT_TASK_HELP:-"node $ROOT/tooling/task-help.mjs --check"}
CENSUS=${KOFUN_PREFLIGHT_CENSUS:-"node $ROOT/tooling/forbidden-requirements/check.mjs"}
EVIDENCE=${KOFUN_PREFLIGHT_EVIDENCE:-"node $ROOT/tests/release/validate-claims.mjs"}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-preflight.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

failures=0

# Paths are printed relative to the repository root: an absolute path from a
# scratch worktree is not something a reader can paste into an editor.
relative() {
    printf '%s' "${1#"$ROOT"/}"
}

fail() {
    printf 'UNSATISFIED: %s\n' "$1" >&2
    printf '             edit %s\n' "$2" >&2
    failures=$((failures + 1))
}

ok() {
    printf 'ok: %s\n' "$1"
}

# 1. Every visible task has a help group. The owning tool is fast, so it runs
#    rather than being reimplemented.
check_help_groups() {
    if $TASK_HELP >"$WORK/help.out" 2>"$WORK/help.err"; then
        ok 'every visible task has a help group'
        return
    fi
    fail "$(sed -n '1p' "$WORK/help.err" "$WORK/help.out" | sed -n '1p')" \
        'tooling/task-help.mjs — add the task to exactly one group'
}

# 2. Every forbidden core build requirement a tracked script uses has a census
#    row. Same reasoning: the owner is 1.4 s, so it is the authority here too.
check_census() {
    if $CENSUS >"$WORK/census.out" 2>"$WORK/census.err"; then
        ok 'the forbidden-requirements census matches the tree'
        return
    fi
    # `-h`, because grep prefixes the filename when given more than one file and
    # a scratch path in the middle of a message is noise the reader cannot use.
    fail "$(grep -h -m 1 . "$WORK/census.err" "$WORK/census.out" 2>/dev/null |
        sed -n '1p')" \
        "tooling/forbidden-requirements/census.tsv — regenerate with: node tooling/forbidden-requirements/check.mjs --count"
}

# 3. The published evidence pack still describes the tree. Regenerated into a
#    scratch directory and compared, so this never writes to the repository.
check_release_evidence() {
    mkdir -p "$WORK/evidence"
    if ! $EVIDENCE evidence "$WORK/evidence" >"$WORK/evidence.log" 2>&1; then
        fail 'the release evidence pack could not be regenerated' \
            'tests/release/validate-claims.mjs — see the log above'
        return
    fi
    if diff -r "$ROOT/artifacts/release-evidence" "$WORK/evidence" \
        >"$WORK/evidence.diff" 2>&1
    then
        ok 'the release evidence pack is current'
        return
    fi
    fail "the release evidence pack is stale: $(grep -c '^[<>]' "$WORK/evidence.diff") changed line(s)" \
        'artifacts/release-evidence — regenerate with: task release-evidence'
}

# 4 and 5. The two corpus counters in one file, twelve lines of context apart,
#    which the owning gate fails one at a time. Both expectations are read out
#    of that file; neither is written here.
check_corpus_counters() {
    expected_diagnostics=$(sed -n \
        's/^test "\$diagnostic_cases" -eq \([0-9][0-9]*\) ||$/\1/p' "$EVENTS")
    if test -z "$expected_diagnostics"; then
        fail 'the diagnostic-fixture counter could not be read; its anchor moved' \
            "$(relative "$EVENTS") — and tests/preflight/check.sh, which reads it"
    else
        actual_diagnostics=$(find "$ROOT/tests/diagnostics/stage2" \
            -maxdepth 1 -name '*.kofun' | wc -l | tr -d ' ')
        if test "$actual_diagnostics" -eq "$expected_diagnostics"; then
            ok "the Stage 2 diagnostic corpus counter is $expected_diagnostics"
        else
            fail "the Stage 2 diagnostic corpus counter says $expected_diagnostics, the tree has $actual_diagnostics" \
                "$(printf '%s:%s' "$(relative "$EVENTS")" "$(grep -n 'diagnostic_cases" -eq' "$EVENTS" | sed -n '1s/:.*//p')")"
        fi
    fi

    expected_companions=$(sed -n \
        's/^test "\$repository_error_cases" -eq \([0-9][0-9]*\) ||$/\1/p' "$EVENTS")
    if test -z "$expected_companions"; then
        fail 'the error-companion counter could not be read; its anchor moved' \
            "$(relative "$EVENTS") — and tests/preflight/check.sh, which reads it"
        return
    fi

    # The code band is read out of the owning file too. It is the part of this
    # rule most likely to change — RFC-0005 added `E3xx` once already — and a
    # band restated here would drop a companion silently, which is the exact
    # failure the owning file's own comment warns about.
    band=$(sed -n 's/^        \(E2S\*|E007|E3\[[^)]*\)) ;;$/\1/p' "$EVENTS")
    if test -z "$band"; then
        fail 'the error-companion code band could not be read; its anchor moved' \
            "$(relative "$EVENTS") — and tests/preflight/check.sh, which reads it"
        return
    fi

    find "$ROOT/tests" "$ROOT/bootstrap" -type f \
        \( -name '*.stdout' -o -name '*.stderr' \) \
        -exec grep -l '^error\[' {} + 2>/dev/null |
        sort >"$WORK/companions"
    actual_companions=0
    while IFS= read -r expected
    do
        stem=${expected%.*}
        test -f "$stem.kofun" || continue
        code=$(sed -n 's/^error\[\([^]]*\)\].*/\1/p' "$expected" | sed -n '1p')
        eval "case \$code in $band) ;; *) continue ;; esac"
        actual_companions=$((actual_companions + 1))
    done <"$WORK/companions"

    if test "$actual_companions" -eq "$expected_companions"; then
        ok "the repository error-companion counter is $expected_companions"
    else
        fail "the error-companion counter says $expected_companions, the tree has $actual_companions" \
            "$(printf '%s:%s' "$EVENTS" "$(grep -n 'repository_error_cases" -eq' "$EVENTS" | sed -n '1s/:.*//p')")"
    fi
}

# 6. The pinned input set still describes the tree, in both directions. This is
#    the one obligation no gate in `verify` reaches: `stage2-pair-coverage` is
#    deliberately outside it because the measurement takes hours, so a new
#    fixture leaves the ledger describing a checkout that no longer exists and
#    nothing says so. Checking it is three milliseconds.
check_pinned_inputs() {
    ( cd "$ROOT" && git ls-files '*.kofun' ) | sort >"$WORK/tracked"
    grep -v '^#' "$INPUTS" | grep -v '^$' | sort >"$WORK/pinned"
    missing=$(comm -23 "$WORK/tracked" "$WORK/pinned" | wc -l | tr -d ' ')
    extra=$(comm -13 "$WORK/tracked" "$WORK/pinned" | wc -l | tr -d ' ')
    if test "$missing" -eq 0 && test "$extra" -eq 0; then
        ok "the pinned input set matches the tree ($(wc -l <"$WORK/tracked" | tr -d ' ') files)"
        return
    fi
    fail "the pinned input set is stale: $missing tracked file(s) unpinned, $extra pinned file(s) untracked" \
        "$(relative "$INPUTS") — regenerate with: git ls-files \"*.kofun\" | sort"
    comm -23 "$WORK/tracked" "$WORK/pinned" | sed -n '1,5s/^/               unpinned: /p' >&2
    comm -13 "$WORK/tracked" "$WORK/pinned" | sed -n '1,5s/^/               untracked: /p' >&2
}

# 7. Every Stage 2 golden fits the producer's detail buffer. Otherwise this is
#    found as a `cmp` mismatch inside a slow gate, which reports that two files
#    differ rather than that a message is too long.
check_golden_bound() {
    bound=$(sed -n 's/^#define KOFUN_SEMANTIC_ERROR_DETAIL_BYTES \([0-9][0-9]*\)u\{0,1\}$/\1/p' \
        "$HEADER")
    if test -z "$bound"; then
        fail 'the semantic error detail bound could not be read; its anchor moved' \
            "$(relative "$HEADER") — and tests/preflight/check.sh, which reads it"
        return
    fi
    over=0
    for golden in "$ROOT"/tests/diagnostics/stage2/*.stderr
    do
        test -f "$golden" || continue
        size=$(wc -c <"$golden" | tr -d ' ')
        if test "$size" -gt "$bound"; then
            over=$((over + 1))
            printf '               %s is %s bytes\n' \
                "${golden#"$ROOT"/}" "$size" >&2
        fi
    done
    if test "$over" -eq 0; then
        ok "every Stage 2 golden fits the ${bound}-byte detail bound"
        return
    fi
    fail "$over Stage 2 golden(s) exceed the ${bound}-byte detail bound" \
        'the diagnostic wording — the producer truncates silently past it'
}

if test "${1:-}" = "--prove"; then
    # The directory defaults to this run's own scratch space. A fixed path
    # under `build/` would be the shape of #1518: two gates recursively
    # replacing one directory, discovered as exit 126 somewhere unrelated.
    PROVE=${2:-"$WORK/proof"}
    rm -rf "$PROVE"
    mkdir -p "$PROVE"
    proved=0
    refused=0

    # A case must fail *for its own reason*. Without the needle this proof is
    # vacuous the moment any other obligation is unmet — and one is, on this
    # tree: the pinned input set is stale, so every case would "refuse" whether
    # or not its mutation did anything.
    prove() {
        case_name=$1
        case_needle=$2
        shift 2
        if env "$@" sh "$0" >"$PROVE/$case_name.out" 2>"$PROVE/$case_name.err"
        then
            printf 'FAIL: prove %s: preflight passed when the obligation was unmet\n' \
                "$case_name" >&2
            proved=$((proved + 1))
            return
        fi
        proved=$((proved + 1))
        if grep -qF "$case_needle" "$PROVE/$case_name.err" ||
           grep -qF "$case_needle" "$PROVE/$case_name.out"
        then
            refused=$((refused + 1))
            printf 'PASS [preflight-refuses] %s\n' "$case_name"
            return
        fi
        printf 'FAIL: prove %s: refused, but never named it — expected %s\n' \
            "$case_name" "$case_needle" >&2
    }

    # The four file-backed checks, each against a mutated copy.
    sed 's/^test "\$diagnostic_cases" -eq [0-9][0-9]*/test "$diagnostic_cases" -eq 99999/' \
        "$ROOT/tests/typed-sidecar/stage2-events.sh" >"$PROVE/events-diagnostics.sh"
    prove diagnostic-counter 'diagnostic corpus counter says 99999' \
        "KOFUN_PREFLIGHT_EVENTS=$PROVE/events-diagnostics.sh"

    sed 's/^test "\$repository_error_cases" -eq [0-9][0-9]*/test "$repository_error_cases" -eq 99999/' \
        "$ROOT/tests/typed-sidecar/stage2-events.sh" >"$PROVE/events-companions.sh"
    prove companion-counter 'error-companion counter says 99999' \
        "KOFUN_PREFLIGHT_EVENTS=$PROVE/events-companions.sh"

    # An anchor that moved must be louder than a number that changed: an
    # extraction yielding nothing compares equal to nothing.
    sed 's/^test "\$diagnostic_cases" -eq/test "$diagnostic_case_total" -eq/' \
        "$ROOT/tests/typed-sidecar/stage2-events.sh" >"$PROVE/events-anchor.sh"
    prove moved-anchor 'its anchor moved' \
        "KOFUN_PREFLIGHT_EVENTS=$PROVE/events-anchor.sh"

    # One line shorter than the tree, on top of whatever drift already exists,
    # so the needle is the count and not merely the word "stale".
    unpinned_now=$(( $( ( cd "$ROOT" && git ls-files '*.kofun' ) | wc -l ) - \
        $(grep -vc '^#' "$ROOT/tests/pair-coverage/inputs.tsv") + 1 ))
    sed '$d' "$ROOT/tests/pair-coverage/inputs.tsv" >"$PROVE/inputs-short.tsv"
    prove pinned-inputs "$unpinned_now tracked file(s) unpinned" \
        "KOFUN_PREFLIGHT_INPUTS=$PROVE/inputs-short.tsv"

    sed 's/^#define KOFUN_SEMANTIC_ERROR_DETAIL_BYTES .*/#define KOFUN_SEMANTIC_ERROR_DETAIL_BYTES 8u/' \
        "$ROOT/bootstrap/stage2/semantic_events.h" >"$PROVE/header-tight.h"
    prove golden-bound 'exceed the 8-byte detail bound' \
        "KOFUN_PREFLIGHT_HEADER=$PROVE/header-tight.h"

    # The three delegating checks add exactly one thing to their owner: they
    # propagate its failure instead of swallowing it. That is what is proved,
    # and the needle is the file each one sends the reader to.
    printf '#!/bin/sh\nexit 1\n' >"$PROVE/refuses"
    chmod +x "$PROVE/refuses"
    prove delegated-task-help 'edit tooling/task-help.mjs' \
        "KOFUN_PREFLIGHT_TASK_HELP=$PROVE/refuses"
    prove delegated-census 'edit tooling/forbidden-requirements/census.tsv' \
        "KOFUN_PREFLIGHT_CENSUS=$PROVE/refuses"
    prove delegated-evidence 'edit tests/release/validate-claims.mjs' \
        "KOFUN_PREFLIGHT_EVIDENCE=$PROVE/refuses"

    # The regenerator refusing and the pack being stale are different failures
    # with different fixes, so the staleness branch is proved on its own: a stub
    # that succeeds and writes a pack one line different from the committed one.
    # Without this, the only proved evidence path is the one where nothing was
    # compared.
    {
        printf '#!/bin/sh\n'
        printf 'mkdir -p "$2"\n'
        printf 'cp -R %s/artifacts/release-evidence/. "$2"/\n' "$ROOT"
        printf 'printf %s >>"$2/CLAIMS.md"\n' "'drift\\n'"
    } >"$PROVE/stale-evidence"
    chmod +x "$PROVE/stale-evidence"
    prove stale-evidence 'edit artifacts/release-evidence' \
        "KOFUN_PREFLIGHT_EVIDENCE=$PROVE/stale-evidence"

    printf '%s of %s obligations are refused when unmet\n' "$refused" "$proved"
    test "$refused" -eq "$proved" || exit 1
    exit 0
fi

check_help_groups
check_census
check_release_evidence
check_corpus_counters
check_pinned_inputs
check_golden_bound

if test "$failures" -eq 0; then
    printf 'PASS: every structural obligation is satisfied\n'
    exit 0
fi
printf '\n%s obligation(s) unsatisfied. All of them are above; none is hidden behind another.\n' \
    "$failures" >&2
exit 1
