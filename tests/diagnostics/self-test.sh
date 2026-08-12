#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
REGISTRY="$ROOT/tests/diagnostics/registry.tsv"
ADAPTERS="$ROOT/tests/diagnostics/adapters.tsv"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-diagnostic-self-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

: >"$WORK/observed.tsv"
while IFS='	' read -r adapter command bless report; do
    case $adapter in ''|\#*) continue ;; esac
    awk '!/^#/ && NF != 0' "$ROOT/$report" >>"$WORK/observed.tsv"
done <"$ADAPTERS"

expect_rejection() {
    name=$1
    expected=$2
    registry=$3
    observed=$4
    set +e
    KOFUN_DIAGNOSTIC_REGISTRY="$registry" \
    KOFUN_DIAGNOSTIC_ADAPTERS="$ADAPTERS" \
    KOFUN_DIAGNOSTIC_OBSERVED="$observed" \
        sh "$ROOT/tests/diagnostics/check.sh" \
        >"$WORK/$name.stdout" 2>"$WORK/$name.stderr"
    status=$?
    set -e
    test "$status" -ne 0 || {
        printf '%s\n' "diagnostic self-test: $name was accepted" >&2
        exit 1
    }
    grep -F "$expected" "$WORK/$name.stderr" >/dev/null || {
        printf '%s\n' \
            "diagnostic self-test: $name did not report '$expected'" >&2
        exit 1
    }
    printf '%s\n' "PASS [diagnostic-negative] $name"
}

cp "$REGISTRY" "$WORK/duplicate.tsv"
awk -F '\t' '!/^#/ && NF { print; exit }' "$REGISTRY" \
    >>"$WORK/duplicate.tsv"
expect_rejection duplicate-code "duplicate code" \
    "$WORK/duplicate.tsv" "$WORK/observed.tsv"

cp "$WORK/observed.tsv" "$WORK/duplicate-observation.tsv"
awk -F '\t' '$1 == "R010" && $2 == "int-bits" { print; exit }' \
    "$WORK/observed.tsv" >>"$WORK/duplicate-observation.tsv"
expect_rejection duplicate-observation "duplicate observed code/adapter" \
    "$REGISTRY" "$WORK/duplicate-observation.tsv"

cp "$WORK/observed.tsv" "$WORK/unknown-observed.tsv"
printf '%s\n' \
    'Z999	stage2	stdout	1	required	not-applicable	forbidden' \
    >>"$WORK/unknown-observed.tsv"
expect_rejection unknown-observed "unknown observed code: Z999" \
    "$REGISTRY" "$WORK/unknown-observed.tsv"

awk -F '\t' 'BEGIN { OFS = FS }
    $1 == "R010" { $13 = "runtime" }
    { print }
' "$REGISTRY" >"$WORK/unregistered-observer.tsv"
expect_rejection unregistered-observer "unregistered observing adapter for R010: int-bits" \
    "$WORK/unregistered-observer.tsv" "$WORK/observed.tsv"

awk -F '\t' '!( $1 == "R010" && $2 == "int-bits" )' \
    "$WORK/observed.tsv" >"$WORK/missing-observer.tsv"
expect_rejection missing-observer "declared-but-unobserved active codes" \
    "$REGISTRY" "$WORK/missing-observer.tsv"

awk -F '\t' 'BEGIN { OFS = FS }
    $1 == "R010" { $10 = "stage2" }
    { print }
' "$REGISTRY" >"$WORK/owner-not-observer.tsv"
expect_rejection owner-not-observer "canonical fixture owner is not an observer" \
    "$WORK/owner-not-observer.tsv" "$WORK/observed.tsv"

awk -F '\t' 'BEGIN { OFS = FS }
    /^#/ || changed { print; next }
    { $11 = "file:tests/diagnostics/does-not-exist.kofun"; changed = 1; print }
' "$REGISTRY" >"$WORK/missing-fixture.tsv"
expect_rejection missing-fixture "missing active fixture" \
    "$WORK/missing-fixture.tsv" "$WORK/observed.tsv"

awk -F '\t' 'BEGIN { OFS = FS }
    changed { print; next }
    { $3 = ($3 == "stdout" ? "stderr" : "stdout"); changed = 1; print }
' "$WORK/observed.tsv" >"$WORK/routing.tsv"
expect_rejection routing-mismatch "routing mismatch" \
    "$REGISTRY" "$WORK/routing.tsv"

awk -F '\t' 'BEGIN { OFS = FS }
    changed { print; next }
    { $7 = "present"; changed = 1; print }
' "$WORK/observed.tsv" >"$WORK/artifact.tsv"
expect_rejection forbidden-artifact "forbidden partial artifact observed" \
    "$REGISTRY" "$WORK/artifact.tsv"

printf '%s\n' "9 diagnostic registry negative self-tests passed"
