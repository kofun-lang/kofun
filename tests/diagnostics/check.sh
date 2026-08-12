#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
REGISTRY=${KOFUN_DIAGNOSTIC_REGISTRY:-"$ROOT/tests/diagnostics/registry.tsv"}
ADAPTERS=${KOFUN_DIAGNOSTIC_ADAPTERS:-"$ROOT/tests/diagnostics/adapters.tsv"}
OBSERVED=${KOFUN_DIAGNOSTIC_OBSERVED:-}
MODE=${1:-check}

fail() {
    printf '%s\n' "diagnostic registry: $*" >&2
    exit 1
}

test -f "$REGISTRY" || fail "missing registry: $REGISTRY"
test -f "$ADAPTERS" || fail "missing adapter registry: $ADAPTERS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-diagnostic-registry.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

: >"$WORK/gaps"

awk -F '\t' '
    BEGIN { expected = 13 }
    /^#/ || NF == 0 { next }
    NF != expected {
        printf "diagnostic registry: registry row %d has %d fields; expected %d\n",
            NR, NF, expected > "/dev/stderr"
        exit 1
    }
    $1 !~ /^[A-Z][A-Z0-9]*[0-9]$/ {
        printf "diagnostic registry: invalid stable code at row %d: %s\n",
            NR, $1 > "/dev/stderr"
        exit 1
    }
    seen[$1]++ {
        printf "diagnostic registry: duplicate code: %s\n", $1 > "/dev/stderr"
        exit 1
    }
    $2 == "" || $3 !~ /^(compile|frontend|backend|runtime|host-io)$/ ||
    $4 == "" || $5 !~ /^(stdout|stderr)$/ || $6 !~ /^[0-9]+$/ {
        printf "diagnostic registry: invalid identity/routing policy for %s\n",
            $1 > "/dev/stderr"
        exit 1
    }
    $7 !~ /^(required|not-applicable|debt\([a-z0-9-]+\))$/ ||
    $8 !~ /^(required|not-applicable|debt\([a-z0-9-]+\))$/ {
        printf "diagnostic registry: invalid span policy for %s\n",
            $1 > "/dev/stderr"
        exit 1
    }
    $9 !~ /^(forbidden|required|preserve|not-applicable)$/ {
        printf "diagnostic registry: invalid artifact policy for %s\n",
            $1 > "/dev/stderr"
        exit 1
    }
    $10 == "" || $11 !~ /^(file|inline):/ || $12 !~ /^(file|inline):/ ||
    $13 == "" {
        printf "diagnostic registry: incomplete evidence ownership for %s\n",
            $1 > "/dev/stderr"
        exit 1
    }
    {
        print $1
        if ($13 ~ /^gap\([a-z0-9-]+\)$/) {
            print $1 "\t" $13 > gaps
        } else {
            count = split($13, observers, ",")
            for (observer_index = 1; observer_index <= count; ++observer_index) {
                print $1 "\t" observers[observer_index] > covered
            }
        }
    }
' gaps="$WORK/gaps" covered="$WORK/covered.codes" \
    "$REGISTRY" >"$WORK/registry.codes"

LC_ALL=C sort "$WORK/registry.codes" >"$WORK/registry.sorted"
cmp "$WORK/registry.codes" "$WORK/registry.sorted" >/dev/null ||
    fail "registry codes are not bytewise sorted"
LC_ALL=C sort "$WORK/covered.codes" >"$WORK/covered.sorted"

awk -F '\t' '
    /^#/ || NF == 0 { next }
    NF != 4 {
        printf "diagnostic registry: adapter row %d has %d fields; expected 4\n",
            NR, NF > "/dev/stderr"
        exit 1
    }
    seen[$1]++ {
        printf "diagnostic registry: duplicate adapter: %s\n", $1 > "/dev/stderr"
        exit 1
    }
    $1 == "" || $2 == "" || $3 == "" || $4 == "" {
        printf "diagnostic registry: incomplete adapter row %d\n",
            NR > "/dev/stderr"
        exit 1
    }
    { print $1 "\t" $2 "\t" $3 "\t" $4 }
' "$ADAPTERS" >"$WORK/adapters"

while IFS='	' read -r adapter command bless report; do
    test -f "$ROOT/$command" ||
        fail "adapter $adapter has stale executable owner: $command"
    test -f "$ROOT/$report" ||
        fail "adapter $adapter has stale report owner: $report"
    if test "$bless" != verify; then
        test -f "$ROOT/$bless" ||
            fail "adapter $adapter has stale bless owner: $bless"
    fi
done <"$WORK/adapters"

while IFS='	' read -r code family phase emitter channel exit_class primary \
    secondary artifact owner fixture golden adapters
do
    case $code in ''|\#*) continue ;; esac
    awk -F '\t' -v owner="$owner" '$1 == owner { found = 1 } END { exit !found }' \
        "$WORK/adapters" ||
        fail "stale fixture owner for $code: $owner"
    case $fixture in
        file:*|inline:*) fixture_path=${fixture#*:} ;;
        *) fail "invalid fixture reference for $code: $fixture" ;;
    esac
    test -f "$ROOT/$fixture_path" ||
        fail "missing active fixture for $code: $fixture_path"
    case $golden in
        file:*|inline:*) golden_path=${golden#*:} ;;
        *) fail "invalid golden reference for $code: $golden" ;;
    esac
    test -f "$ROOT/$golden_path" ||
        fail "missing golden evidence for $code: $golden_path"
    case $adapters in
        gap\(*\)) ;;
        *)
            old_ifs=$IFS
            IFS=,
            set -- $adapters
            IFS=$old_ifs
            for allowed in "$@"; do
                awk -F '\t' -v owner="$allowed" \
                    '$1 == owner { found = 1 } END { exit !found }' \
                    "$WORK/adapters" ||
                    fail "unknown observing adapter for $code: $allowed"
            done
            case ",$adapters," in
                *,"$owner",*) ;;
                *) fail "canonical fixture owner is not an observer for $code: $owner" ;;
            esac
            ;;
    esac
done <"$REGISTRY"

if test -n "$OBSERVED"; then
    test -f "$OBSERVED" || fail "missing observed report: $OBSERVED"
    cp "$OBSERVED" "$WORK/observed.tsv"
else
    : >"$WORK/observed.tsv"
    while IFS='	' read -r adapter command bless report; do
        awk -F '\t' -v adapter="$adapter" '
            /^#/ || NF == 0 { next }
            $2 != adapter {
                printf "diagnostic registry: report %s claims adapter %s\n",
                    adapter, $2 > "/dev/stderr"
                exit 1
            }
            { print }
        ' "$ROOT/$report" >>"$WORK/observed.tsv"
    done <"$WORK/adapters"
fi

awk -F '\t' '
    BEGIN { expected = 7 }
    /^#/ || NF == 0 { next }
    NF != expected {
        printf "diagnostic registry: observed row %d has %d fields; expected %d\n",
            NR, NF, expected > "/dev/stderr"
        exit 1
    }
    seen[$1 SUBSEP $2]++ {
        printf "diagnostic registry: duplicate observed code/adapter: %s/%s\n",
            $1, $2 > "/dev/stderr"
        exit 1
    }
    { print $1 "\t" $2 }
' "$WORK/observed.tsv" >"$WORK/observed.codes"

while IFS='	' read -r code owner channel exit_class primary secondary artifact
do
    case $code in ''|\#*) continue ;; esac
    registry_row=$(awk -F '\t' -v code="$code" '$1 == code { print; found = 1 }
        END { exit !found }' "$REGISTRY") ||
        fail "unknown observed code: $code"
    registry_owner=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $10 }')
    registry_channel=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $5 }')
    registry_exit=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $6 }')
    registry_primary=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $7 }')
    registry_secondary=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $8 }')
    registry_artifact=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $9 }')
    registry_adapters=$(printf '%s\n' "$registry_row" | awk -F '\t' '{ print $13 }')

    case ",$registry_adapters," in
        *,"$owner",*) ;;
        *) fail "unregistered observing adapter for $code: $owner" ;;
    esac
    test "$channel" = "$registry_channel" ||
        fail "routing mismatch for $code: $channel != $registry_channel"
    test "$exit_class" = "$registry_exit" ||
        fail "exit status mismatch for $code: $exit_class != $registry_exit"
    test "$primary" = "$registry_primary" ||
        fail "primary span policy mismatch for $code"
    test "$secondary" = "$registry_secondary" ||
        fail "secondary span policy mismatch for $code"
    if test "$registry_artifact" = forbidden &&
       test "$artifact" != forbidden
    then
        fail "forbidden partial artifact observed for $code"
    fi
    test "$artifact" = "$registry_artifact" ||
        fail "artifact policy mismatch for $code: $artifact != $registry_artifact"
done <"$WORK/observed.tsv"

LC_ALL=C sort "$WORK/observed.codes" >"$WORK/observed.sorted"
cmp "$WORK/covered.sorted" "$WORK/observed.sorted" >/dev/null || {
    missing=$(comm -23 "$WORK/covered.sorted" "$WORK/observed.sorted" |
        paste -sd, -)
    unknown=$(comm -13 "$WORK/covered.sorted" "$WORK/observed.sorted" |
        paste -sd, -)
    test -z "$missing" || printf '%s\n' \
        "diagnostic registry: declared-but-unobserved active codes: $missing" >&2
    test -z "$unknown" || printf '%s\n' \
        "diagnostic registry: observed-but-undeclared codes: $unknown" >&2
    exit 1
}

count=$(wc -l <"$WORK/registry.codes" | tr -d ' ')
covered_count=$(wc -l <"$WORK/covered.codes" | tr -d ' ')
gap_count=$(wc -l <"$WORK/gaps" | tr -d ' ')
printf '%s\n' \
    "diagnostic registry: $count stable codes; $covered_count registered adapter observations agree; $gap_count explicit evidence gaps"

if test "$MODE" != check && test "$MODE" != --registry-only; then
    fail "unknown mode: $MODE"
fi
