#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/trait-dictionary-c11"
CC=${CC:-cc}
ANALYZER_CC=${ANALYZER_CC:-gcc}
WORK=${KOFUN_TRAIT_DICTIONARY_C11_WORK:-"$ROOT/build/trait-dictionary-c11"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v "$ANALYZER_CC" >/dev/null 2>&1 ||
    fail 'GCC is required for the static analyzer gate'
case $WORK in
    */trait-dictionary-c11|*/trait-dictionary-c11.*) ;;
    *) fail "work directory must end in trait-dictionary-c11[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/traits_frontend.c" \
    -o "$WORK/kofun-traits-frontend"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/traits_dictionary_c11.c" \
    -o "$WORK/kofun-traits-dictionary-c11"
"$ANALYZER_CC" -std=c11 -O0 -g -Wall -Wextra -Werror -pedantic \
    -fanalyzer "$ROOT/bootstrap/stage2/traits_dictionary_c11.c" \
    -o "$WORK/kofun-traits-dictionary-c11-analyzer"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/bootstrap/stage2/traits_dictionary_c11.c" \
    -o "$WORK/kofun-traits-dictionary-c11-sanitize"

for pass in first second; do
    "$WORK/kofun-traits-frontend" "$CASES/equal_int.kofun" \
        "$WORK/equal_int.$pass.ir" "$WORK/equal_int.$pass.tokens" \
        >"$WORK/producer.$pass.stdout" 2>"$WORK/producer.$pass.stderr"
    test ! -s "$WORK/producer.$pass.stdout" ||
        fail "producer $pass pass wrote stdout"
    test ! -s "$WORK/producer.$pass.stderr" ||
        fail "producer $pass pass wrote stderr"
done
cmp "$WORK/equal_int.first.ir" "$WORK/equal_int.second.ir" ||
    fail 'repeated trait IR differs'
cmp "$WORK/equal_int.first.tokens" "$WORK/equal_int.second.tokens" ||
    fail 'repeated token tape differs'
cmp "$CASES/equal_int.ir" "$WORK/equal_int.first.ir" ||
    fail 'Equal[Int] typed IR differs from its golden'
test "$(grep -Fxc '        return true' "$CASES/equal_int.kofun")" -eq 1 ||
    fail 'the fixed C11 callback no longer matches the fixture method body'

for pass in first second; do
    "$WORK/kofun-traits-dictionary-c11" "$WORK/equal_int.first.ir" \
        >"$WORK/consumer.$pass.stdout" 2>"$WORK/consumer.$pass.stderr"
    cmp "$CASES/equal_int.stdout" "$WORK/consumer.$pass.stdout" ||
        fail "consumer $pass observation differs"
    test ! -s "$WORK/consumer.$pass.stderr" ||
        fail "consumer $pass wrote stderr"
done
cmp "$WORK/consumer.first.stdout" "$WORK/consumer.second.stdout" ||
    fail 'repeated C11 observations differ'

"$WORK/kofun-traits-dictionary-c11-sanitize" \
    "$WORK/equal_int.first.ir" >"$WORK/sanitize.stdout" \
    2>"$WORK/sanitize.stderr"
cmp "$CASES/equal_int.stdout" "$WORK/sanitize.stdout" ||
    fail 'sanitized C11 observation differs'
test ! -s "$WORK/sanitize.stderr" ||
    fail 'sanitized C11 execution wrote stderr'

expect_refusal() {
    stem=$1
    expected=$2
    set +e
    "$WORK/kofun-traits-dictionary-c11" "$WORK/$stem.ir" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.stdout" || fail "$stem wrote stdout"
    grep -F "$expected" "$WORK/$stem.stderr" >/dev/null ||
        fail "$stem did not emit its exact refusal"
}

sed 's#^dictionary|dictionary-id=dictionary:abi1/#dictionary|dictionary-id=dictionary:abi2/#' \
    "$WORK/equal_int.first.ir" >"$WORK/wrong-identity.ir"
expect_refusal wrong-identity "field 'dictionary-id' is 'dictionary:abi2/"

sed 's/|slots=1|slot-methods=/|slots=2|slot-methods=/' \
    "$WORK/equal_int.first.ir" >"$WORK/wrong-slot-count.ir"
expect_refusal wrong-slot-count "field 'slots' is '2', expected '1'"

sed '/^dictionary-entry|/d' "$WORK/equal_int.first.ir" \
    >"$WORK/missing-entry.ir"
expect_refusal missing-entry 'profile must contain exactly one trait/method/dictionary/bound/dispatch, two type parameters/functions, and 14 records'

sed 's#|dictionary-arguments=dictionary:abi1/#|dictionary-arguments=dictionary:abi2/#' \
    "$WORK/equal_int.first.ir" >"$WORK/wrong-argument.ir"
expect_refusal wrong-argument "field 'dictionary-arguments' is 'dictionary:abi2/"

for line in 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    stem="unknown-field-$line"
    awk -v target="$line" '{
        if (NR == target) print $0 "|authority=writer"
        else print
    }' "$WORK/equal_int.first.ir" >"$WORK/$stem.ir"
    expect_refusal "$stem" "unknown field 'authority' for record kind"
done

sed '2s/$/|span=0..58/' "$WORK/equal_int.first.ir" \
    >"$WORK/duplicate-span.ir"
expect_refusal duplicate-span "duplicate field 'span' for record kind 'trait'"

sed '2s/$/|/' "$WORK/equal_int.first.ir" >"$WORK/trailing-field.ir"
expect_refusal trailing-field 'record contains an empty field segment'

sed '2s/span=0..58/span=bogus/' "$WORK/equal_int.first.ir" \
    >"$WORK/malformed-span.ir"
expect_refusal malformed-span "field 'span' is 'bogus', expected '0..58'"

sed '/^method-call|/s/use-span=222..246/use-span=0222..246/' \
    "$WORK/equal_int.first.ir" >"$WORK/noncanonical-use-span.ir"
expect_refusal noncanonical-use-span "field 'use-span' is '0222..246', expected '222..246'"

sed '/^call|/s/declaration-span=161..248/declaration-span=248..161/' \
    "$WORK/equal_int.first.ir" >"$WORK/descending-declaration-span.ir"
expect_refusal descending-declaration-span "field 'declaration-span' is '248..161', expected '161..248'"

sed '2s/span=0..58/span=0..1048577/' "$WORK/equal_int.first.ir" \
    >"$WORK/oversized-span.ir"
expect_refusal oversized-span "field 'span' is '0..1048577', expected '0..58'"

sed '2s/span=0..58/span=0..58=writer/' "$WORK/equal_int.first.ir" \
    >"$WORK/extra-equals-span.ir"
expect_refusal extra-equals-span "field 'span' is '0..58=writer', expected '0..58'"

awk '{ print; if ($0 ~ /^method\|/) print }' "$WORK/equal_int.first.ir" \
    >"$WORK/duplicate-method.ir"
expect_refusal duplicate-method 'profile must contain exactly one trait/method/dictionary/bound/dispatch, two type parameters/functions, and 14 records'

awk '{ print; if ($0 ~ /^bound\|/) print }' "$WORK/equal_int.first.ir" \
    >"$WORK/extra-bound.ir"
expect_refusal extra-bound 'profile must contain exactly one trait/method/dictionary/bound/dispatch, two type parameters/functions, and 14 records'

awk 'NR < 15 { print } NR == 15 { printf "%s", $0 }' \
    "$WORK/equal_int.first.ir" >"$WORK/truncated.ir"
expect_refusal truncated 'line exceeds 2046 bytes or lacks its terminating newline'

awk 'BEGIN { print "kofun-traits-ir/v2"; for (i = 0; i < 2100; i++) printf "x"; print "" }' \
    >"$WORK/oversized.ir"
expect_refusal oversized 'line exceeds 2046 bytes or lacks its terminating newline'

awk 'BEGIN { print "kofun-traits-ir/v2" } /^trait\|/ { for (i = 0; i < 65; i++) print }' \
    "$WORK/equal_int.first.ir" >"$WORK/record-limit.ir"
expect_refusal record-limit 'profile exceeds 64 records'

printf '%s\n' 'trait dictionary C11 tests passed'
