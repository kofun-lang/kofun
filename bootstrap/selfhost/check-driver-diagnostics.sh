#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_SELFHOST_DRIVER_DIAGNOSTIC_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}selfhost-driver-diagnostics"}
CC=${CC:-cc}
cd "$ROOT"

fail() {
    printf '%s\n' "FAIL: selfhost driver diagnostics: $*" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

. "$ROOT/bootstrap/stage2/build.sh"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2" ||
    fail "the Stage 2 seed compiler did not build"

profile_digest=$(awk -F '|' '$1 == "source_sha256" { print $2 }' \
    "$ROOT/bootstrap/selfhost/profile.meta")
actual_digest=$("$ROOT/bin/kofun-sha256" "$ROOT/bootstrap/stage1/compiler.kofun" |
    awk '{ print $1 }')
test "$profile_digest" = "$actual_digest" ||
    fail "canonical source differs from profile.meta"

"$WORK/kofun-stage2" --selfhost-compile \
    bootstrap/stage1/compiler.kofun "$WORK/S.c" \
    "$profile_digest" >/dev/null
cmp "$ROOT/bootstrap/selfhost/driver/S.c" "$WORK/S.c" ||
    fail "generated A1 differs from checked-in driver/S.c"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I "$ROOT/unicode" \
    "$WORK/S.c" -o "$WORK/kofun-a1"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/bootstrap/stage1/compiler.c" -o "$WORK/kofun-stage1"

check_refusal() {
    source=$1
    golden=$2
    label=$3
    a1_c="$WORK/$label.a1.c"
    seed_c="$WORK/$label.seed.c"

    set +e
    "$WORK/kofun-a1" "$source" "$a1_c" \
        >"$WORK/$label.a1.stdout" 2>"$WORK/$label.a1.stderr"
    a1_status=$?
    "$WORK/kofun-stage1" "$source" "$seed_c" \
        >"$WORK/$label.seed.stdout" 2>"$WORK/$label.seed.stderr"
    seed_status=$?
    set -e

    test "$a1_status" -eq 1 || fail "$label A1 status is $a1_status, expected 1"
    test "$seed_status" -eq 1 ||
        fail "$label audited-seed status is $seed_status, expected 1"
    cmp "$golden" "$WORK/$label.a1.stdout" ||
        fail "$label A1 stdout differs from its golden"
    cmp "$WORK/$label.a1.stdout" "$WORK/$label.seed.stdout" ||
        fail "$label A1/audited-seed stdout differs"
    test ! -s "$WORK/$label.a1.stderr" || fail "$label A1 wrote stderr"
    test ! -s "$WORK/$label.seed.stderr" ||
        fail "$label audited seed wrote stderr"
    test ! -e "$a1_c" || fail "$label A1 wrote partial C"
    test ! -e "$seed_c" || fail "$label audited seed wrote partial C"
}

file_checked=0
for source in "$ROOT"/bootstrap/selfhost/driver/corpus_reject*.kofun
do
    stem=$(basename "$source" .kofun)
    golden="${source%.kofun}.stdout"
    test -f "$golden" || fail "$stem has no same-stem golden"
    check_refusal "$source" "$golden" "$stem"
    file_checked=$((file_checked + 1))
done
test "$file_checked" -eq 32 ||
    fail "ran $file_checked file refusals, expected 32"

file_golden_count=0
for golden in "$ROOT"/bootstrap/selfhost/driver/corpus_reject*.stdout
do
    test -f "$golden" || continue
    file_golden_count=$((file_golden_count + 1))
done
test "$file_golden_count" -eq "$file_checked" ||
    fail "$file_golden_count file goldens do not join $file_checked fixtures"

: >"$WORK/expected-builtin-goldens"
builtin_checked=0
while IFS='|' read -r label statement
do
    case $label in
        ''|*[!a-z0-9-]*) fail "invalid builtin refusal label: $label" ;;
    esac
    source="$WORK/builtin-$label.kofun"
    {
        printf '%s\n' 'fn main() {'
        printf '    %s\n' "$statement"
        printf '%s\n' '    print(0)' '}'
    } >"$source"
    golden="$ROOT/bootstrap/selfhost/driver/goldens/builtin-$label.stdout"
    test -f "$golden" || fail "$label has no builtin golden"
    printf '%s\n' "$(basename "$golden")" >>"$WORK/expected-builtin-goldens"
    check_refusal "$source" "$golden" "builtin-$label"
    builtin_checked=$((builtin_checked + 1))
done <"$ROOT/bootstrap/selfhost/driver/corpus_builtin_rejects.tsv"
test "$builtin_checked" -eq 30 ||
    fail "ran $builtin_checked builtin refusals, expected 30"

: >"$WORK/actual-builtin-goldens"
for golden in "$ROOT"/bootstrap/selfhost/driver/goldens/builtin-*.stdout
do
    test -f "$golden" || continue
    basename "$golden" >>"$WORK/actual-builtin-goldens"
done
sort "$WORK/expected-builtin-goldens" >"$WORK/expected-builtin-goldens.sorted"
sort "$WORK/actual-builtin-goldens" >"$WORK/actual-builtin-goldens.sorted"
cmp "$WORK/expected-builtin-goldens.sorted" \
    "$WORK/actual-builtin-goldens.sorted" ||
    fail "builtin matrix and checked-in goldens do not join one-to-one"

printf '%s\n' \
    "PASS: 62 A1 refusals have exact codes, messages, byte spans, and goldens" \
    "PASS: generated A1 and audited Stage 1 seed agree on routing, status, and artifacts" \
    "PASS: 32 file and 30 builtin goldens join one-to-one with no orphans"
