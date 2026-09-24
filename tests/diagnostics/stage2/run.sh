#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
SUITE="$ROOT/tests/diagnostics/stage2"
WORK=${KOFUN_DIAGNOSTIC_WORK:-"$ROOT/build/diagnostics-stage2"}
. "$ROOT/bootstrap/stage2/build.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"

passed=0
span_count=0
span_debt=0
: >"$WORK/observed.codes"

for source in "$SUITE"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    golden="$SUITE/$stem.stderr"
    actual="$WORK/$stem.actual"
    internal_stderr="$WORK/$stem.internal.stderr"
    output="$WORK/$stem.c"
    ir="$WORK/$stem.ir"
    tokens="$WORK/$stem.tokens"

    test -f "$golden" || {
        printf '%s\n' "diagnostics: missing golden for $source" >&2
        exit 1
    }
    mode=$(sed -n 's/^# diagnostic-mode: //p' "$source")
    code=$(sed -n 's/^# expect-code: //p' "$source")
    span=$(sed -n 's/^# expect-span: //p' "$source")
    test -n "$mode" && test -n "$code" && test -n "$span" || {
        printf '%s\n' \
            "diagnostics: missing mode/code/span directive in $source" >&2
        exit 1
    }

    set +e
    if test "$mode" = ownership; then
        "$WORK/kofun-stage2" --check-ownership "$source" \
            >"$actual" 2>"$internal_stderr"
    elif test "$mode" = compile; then
        "$WORK/kofun-stage2" \
            "$source" "$output" "$ir" "$tokens" \
            >"$actual" 2>"$internal_stderr"
    elif test "$mode" = scoped-ownership; then
        "$WORK/kofun-stage2" --check-scoped-ownership "$source" \
            "$WORK/$stem.ownership.json" "tests/diagnostics/stage2/$stem.kofun" \
            >"$actual" 2>"$internal_stderr"
    else
        printf '%s\n' \
            "diagnostics: unknown mode '$mode' in $source" >&2
        exit 1
    fi
    status=$?
    set -e

    test "$status" -eq 1 || {
        printf '%s\n' \
            "diagnostics: $source exited $status instead of 1" >&2
        exit 1
    }
    test ! -s "$internal_stderr" || {
        printf '%s\n' \
            "diagnostics: $source wrote unexpected internal stderr" >&2
        exit 1
    }
    test ! -e "$output" || {
        printf '%s\n' \
            "diagnostics: rejected source produced $output" >&2
        exit 1
    }
    if test "$mode" = scoped-ownership; then
        # The analysis succeeded and its decision is the rejection: the
        # document is the entry's required artifact, not a partial output.
        grep -F '"status":"rejected"}' "$WORK/$stem.ownership.json" >/dev/null || {
            printf '%s\n' \
                "diagnostics: $source wrote no rejected ownership decision" >&2
            exit 1
        }
    fi
    cmp "$golden" "$actual" || {
        printf '%s\n' \
            "diagnostics: golden mismatch for $source; run bless.sh intentionally" >&2
        exit 1
    }
    grep -F "error[$code]:" "$actual" >/dev/null || {
        printf '%s\n' \
            "diagnostics: expected code $code was not emitted for $source" >&2
        exit 1
    }
    if test "$span" = none; then
        span_debt=$((span_debt + 1))
    else
        grep -F "at $span" "$actual" >/dev/null || {
            printf '%s\n' \
                "diagnostics: expected span '$span' was not emitted for $source" >&2
            exit 1
        }
        span_count=$((span_count + 1))
    fi
    printf '%s\n' "$code" >>"$WORK/observed.codes"
    passed=$((passed + 1))
    printf '%s\n' "PASS [stage2-diagnostic] $source"
done

LC_ALL=C sort -u "$WORK/observed.codes" >"$WORK/observed.sorted"
awk -F '\t' '
    !/^#/ && $10 == "stage2" && $13 !~ /^gap\(/ { print $1 }
' "$ROOT/tests/diagnostics/registry.tsv" >"$WORK/registry.codes"
cmp "$WORK/registry.codes" "$WORK/observed.sorted" || {
    printf '%s\n' \
        "diagnostics: registry and executable Stage 2 cases differ" >&2
    exit 1
}

printf '%s\n' \
    "$passed passed; 0 failed" \
    "diagnostic-code coverage: $passed/$passed Stage 2 codes" \
    "precise source spans: $span_count; recorded span debt: $span_debt"
