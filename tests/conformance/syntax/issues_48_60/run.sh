#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
ASSERT_CONTEXT='syntax 48-60'
. "$root/tests/assertions/assert.sh"
. "$root/bootstrap/stage2/build.sh"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    echo "issues 48-60 conformance: a C11 compiler is required" >&2
    exit 1
fi

temporary=${TMPDIR:-/tmp}/kofun-syntax-48-60.$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

CC=$compiler kofun_stage2_build "$root" "$temporary/kofun-stage2"

"$temporary/kofun-stage2" \
    "$here/token-spans.kofun" \
    "$temporary/output.kofun" \
    "$temporary/output.ir" \
    "$temporary/output.tokens" >/dev/null

cmp "$here/token-spans.kofun" "$temporary/output.kofun"
cmp "$here/token-spans.tokens" "$temporary/output.tokens"

"$temporary/kofun-stage2" \
    "$here/token-spans.kofun" \
    "$temporary/replay.kofun" \
    "$temporary/replay.ir" \
    "$temporary/replay.tokens" >/dev/null

cmp "$temporary/output.tokens" "$temporary/replay.tokens"

source_size=$(wc -c <"$here/token-spans.kofun" | tr -d ' ')
awk -F '|' -v source_size="$source_size" '
    NR == 1 {
        if ($0 != "kofun-token-tape/v1") exit 10
        next
    }
    NF != 4 { exit 11 }
    $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ {
        exit 12
    }
    $2 >= $3 || $3 > source_size { exit 13 }
    seen && $2 < previous_end { exit 14 }
    {
        previous_end = $3
        seen = 1
    }
    END {
        if (!seen) exit 15
    }
' "$temporary/output.tokens"

tail -n +2 "$temporary/output.tokens" |
while IFS='|' read -r kind start end line; do
    width=$((end - start))
    dd if="$here/token-spans.kofun" bs=1 skip="$start" count="$width" \
        2>/dev/null >"$temporary/slice"
    assert_num "size of $temporary/slice" \
        "$(wc -c <"$temporary/slice" | tr -d ' ')" -eq "$width"

    case "$kind" in
        keyword|identifier|integer|string|punctuation) ;;
        *)
            echo "unexpected token kind: $kind" >&2
            exit 1
            ;;
    esac

    newline_count=$(
        dd if="$here/token-spans.kofun" bs=1 count="$start" 2>/dev/null |
        tr -cd '\n' |
        wc -c |
        tr -d ' '
    )
    actual_line=$((newline_count + 1))
    assert_num "line" "$line" -eq "$actual_line"
done

assert_grep "output.tokens" '^punctuation|.*|.*|.*$' "$temporary/output.tokens"
assert_grep "output.tokens" '^string|.*|.*|.*$' "$temporary/output.tokens"
assert_grep "output.tokens" '^integer|.*|.*|.*$' "$temporary/output.tokens"

pair_line=$(grep '^punctuation|.*|.*|.*$' "$temporary/output.tokens" |
    while IFS='|' read -r kind start end line; do
        width=$((end - start))
        if test "$width" -eq 2; then
            printf '%s\n' "$kind|$start|$end|$line"
        fi
    done)
assert_nonempty "pair line" "$pair_line"

set +e
"$temporary/kofun-stage2" \
    "$here/unterminated-string.kofun" \
    "$temporary/broken.kofun" \
    "$temporary/broken.ir" \
    "$temporary/broken.tokens" \
    >"$temporary/broken.stdout" 2>"$temporary/broken.stderr"
broken_status=$?
set -e

assert_num "broken status" "$broken_status" -eq 1
assert_file_empty "$temporary/broken.stderr" "$temporary/broken.stderr"
printf '%s\n' 'error[E2S01]: unterminated string at byte 24' \
    >"$temporary/expected-broken.stdout"
cmp "$temporary/expected-broken.stdout" "$temporary/broken.stdout"
assert_absent "$temporary/broken.tokens" "$temporary/broken.tokens"

awk -F '\t' '
    NF != 3 { exit 20 }
    $1 < 48 || $1 > 59 { exit 21 }
    $2 != "valid" && $2 != "invalid" { exit 22 }
    $3 == "" { exit 23 }
    { count[$1, $2]++ }
    END {
        for (issue = 48; issue <= 59; issue++) {
            if (count[issue, "valid"] < 2) exit 24
            if (count[issue, "invalid"] < 2) exit 25
        }
    }
' "$here/surface-cases.tsv"

printf '%s\n' \
    "PASS: issues 48-59 valid/invalid surface inventory" \
    "PASS: issue 60 deterministic token-span prototype"
