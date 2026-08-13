#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CORPUS=${1-}
test -n "$CORPUS" && test -d "$CORPUS" || {
    printf '%s\n' \
        "conformance observations: corpus directory is required" >&2
    exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-observations.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15
contract="$work/contract"
: >"$contract"

LC_ALL=C
export LC_ALL
for source in "$CORPUS"/*.kofun; do
    test -f "$source" || continue
    test "$(basename "$source")" != expectations.kofun || continue

    name=$(basename "$source")
    if ! grep -Eq \
        '^# expect(-stdout|-stderr|-exit|-reject)?: ' \
        "$source"
    then
        printf '%s\n' \
            "conformance observations: case has no explicit # expect-* header: $source" >&2
        exit 2
    fi

    # A rejection case observes a refusal rather than a run, so it pins the
    # recorded reason instead of an exit status and two streams. Declaring both
    # would leave two contradictory contracts in one file.
    reject_reason=$(sed -n 's/^# expect-reject: //p' "$source")
    if test -n "$reject_reason"; then
        if grep -Eq '^# expect(-stdout|-stderr|-exit)?: ' "$source"; then
            printf '%s\n' \
                "conformance observations: rejection case must not declare execution observations: $source" >&2
            exit 2
        fi
        printf '%s\n' "$reject_reason" >"$work/reject"
        reject_bytes=$(wc -c <"$work/reject" | tr -d ' ')
        printf '%s\n' \
            "case $name" \
            "reject $reject_bytes" >>"$contract"
        cat "$work/reject" >>"$contract"
        continue
    fi

    expected_status=$(sed -n 's/^# expect-exit: //p' "$source")
    test -n "$expected_status" || expected_status=0
    case $expected_status in
        *[!0-9]*|'')
            printf '%s\n' \
                "conformance observations: invalid expected exit status: $source" >&2
            exit 2
            ;;
    esac
    if test "$expected_status" -gt 127; then
        printf '%s\n' \
            "conformance observations: expected exit must be between 0 and 127: $source" >&2
        exit 2
    fi
    if test "$expected_status" -eq 124; then
        printf '%s\n' \
            "conformance observations: expected exit 124 is reserved for the timeout harness: $source" >&2
        exit 2
    fi

    sed -n \
        -e 's/^# expect: //p' \
        -e 's/^# expect-stdout: //p' \
        "$source" >"$work/stdout"
    sed -n 's/^# expect-stderr: //p' "$source" >"$work/stderr"
    stdout_bytes=$(wc -c <"$work/stdout" | tr -d ' ')
    stderr_bytes=$(wc -c <"$work/stderr" | tr -d ' ')

    printf '%s\n' \
        "case $name" \
        "exit $expected_status" \
        "stdout $stdout_bytes" >>"$contract"
    cat "$work/stdout" >>"$contract"
    printf '%s\n' "stderr $stderr_bytes" >>"$contract"
    cat "$work/stderr" >>"$contract"
done

"$ROOT/bin/kofun-sha256" "$contract" | awk '{ print $1 }'
