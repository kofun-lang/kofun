#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/patterns"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-patterns.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "patterns: $*" >&2
    exit 1
}

STAGE2="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$STAGE2"

for implementation in \
    "$ROOT/bootstrap/stage2/compiler.c" \
    "$ROOT/bootstrap/stage2/compiler.kofun"
do
    grep 'kofun-pattern-tree/v1' "$implementation" >/dev/null ||
        fail "$implementation omits the Pattern IR version"
    grep 'limits|depth|32|nodes-per-compilation|256' \
        "$implementation" >/dev/null ||
        fail "$implementation omits the shared limits"
    grep 'pattern-diagnostic|E2S58|' "$implementation" >/dev/null ||
        fail "$implementation omits the shared diagnostic record"
    grep 'empty-constructor-payload' "$implementation" >/dev/null ||
        fail "$implementation diverges on zero-field constructor syntax"
    grep 'parse_pattern_trees' "$implementation" >/dev/null ||
        fail "$implementation omits the general parser entrypoint"
done

mkdir -p "$WORK/remapped"
cp "$CASES/positive.kofun" "$WORK/remapped/positive.kofun"
for suffix in first remapped; do
    source="$CASES/positive.kofun"
    test "$suffix" = first || source="$WORK/remapped/positive.kofun"
    "$STAGE2" --parse-patterns "$source" "$WORK/positive-$suffix.patterns" \
        >"$WORK/positive-$suffix.stdout" \
        2>"$WORK/positive-$suffix.stderr"
    test ! -s "$WORK/positive-$suffix.stdout" ||
        fail 'positive parser wrote stdout'
    test ! -s "$WORK/positive-$suffix.stderr" ||
        fail 'positive parser wrote stderr'
done
cmp "$WORK/positive-first.patterns" "$WORK/positive-remapped.patterns" ||
    fail 'pattern tree depends on input path'
cmp "$CASES/positive.patterns" "$WORK/positive-first.patterns" ||
    fail 'positive pattern tree differs from golden'
for literal in 'Bool|true' 'Bool|false' 'Null|null' \
    'Int|0' 'Int|42' 'Int|4_2'
do
    grep "|LiteralPattern|.*|$literal|" \
        "$WORK/positive-first.patterns" >/dev/null ||
        fail "literal token spelling is not lossless for $literal"
done

"$STAGE2" "$CASES/positive.kofun" "$WORK/positive.kofun" \
    "$WORK/positive.ir" "$WORK/positive.tokens" \
    >"$WORK/positive-compile.stdout" 2>"$WORK/positive-compile.stderr"
cmp "$CASES/positive.kofun" "$WORK/positive.kofun" ||
    fail 'structural projection changed positive source bytes'
test ! -s "$WORK/positive-compile.stderr" ||
    fail 'positive structural compile wrote stderr'
sed -n '/^kofun-pattern-tree\/v1$/,$p' "$WORK/positive.ir" \
    >"$WORK/positive.ir.patterns"
cmp "$CASES/positive.patterns" "$WORK/positive.ir.patterns" ||
    fail 'versioned Pattern section differs from focused output'

set +e
"$STAGE2" "$CASES/positive.kofun" "$WORK/positive.c" \
    "$WORK/positive-c.ir" "$WORK/positive-c.tokens" \
    >"$WORK/positive-c.stdout" 2>"$WORK/positive-c.stderr"
positive_c_status=$?
set -e
test "$positive_c_status" -eq 1 ||
    fail 'general patterns unexpectedly reached Core lowering'
grep '^error\[E2S24\]: general pattern syntax is parsed but not executable' \
    "$WORK/positive-c.stdout" >/dev/null ||
    fail 'general executable boundary did not report E2S24'
if grep 'E2S35' "$WORK/positive-c.stdout" >/dev/null; then
    fail 'general patterns leaked into lexical-use resolution'
fi
test ! -e "$WORK/positive.c" ||
    fail 'general patterns produced C'
test ! -s "$WORK/positive-c.stderr" ||
    fail 'general executable boundary wrote stderr'

expect_invalid() {
    stem=$1
    reason=$2
    set +e
    "$STAGE2" --parse-patterns "$CASES/$stem.kofun" \
        "$WORK/$stem.patterns" >"$WORK/$stem.stdout" \
        2>"$WORK/$stem.stderr"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem focused parser exited $status"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.stdout" ||
        fail "$stem first diagnostic differs"
    test ! -s "$WORK/$stem.stderr" || fail "$stem wrote stderr"
    grep "|ErrorPattern|.*|$reason$" "$WORK/$stem.patterns" >/dev/null ||
        fail "$stem omitted ErrorPattern reason $reason"

    normal="$WORK/$stem-normal"
    mkdir -p "$normal"
    set +e
    "$STAGE2" "$CASES/$stem.kofun" "$normal/output.c" \
        "$normal/output.ir" "$normal/output.tokens" \
        >"$normal/stdout" 2>"$normal/stderr"
    normal_status=$?
    set -e
    test "$normal_status" -eq 1 ||
        fail "$stem normal compile exited $normal_status"
    cmp "$CASES/$stem.stdout" "$normal/stdout" ||
        fail "$stem normal compile diagnostic differs"
    test ! -s "$normal/stderr" || fail "$stem normal compile wrote stderr"
    test ! -e "$normal/output.c" || fail "$stem left rejected C"
    test ! -e "$normal/output.ir" || fail "$stem left rejected IR"
    test ! -e "$normal/output.tokens" || fail "$stem left rejected tokens"
}

expect_invalid recovery missing-closing-parenthesis
cmp "$CASES/recovery.patterns" "$WORK/recovery.patterns" ||
    fail 'recovery tree differs from golden'
grep '|NamePattern|90|95|Later|' "$WORK/recovery.patterns" >/dev/null ||
    fail 'recovery did not reach the later arm after missing close'
grep '|NamePattern|187|192|Final|' "$WORK/recovery.patterns" >/dev/null ||
    fail 'recovery did not reach the later arm after missing comma'
expect_invalid empty_constructor empty-constructor-payload
expect_invalid leading_or leading-or
expect_invalid trailing_or trailing-or
expect_invalid doubled_or doubled-or
expect_invalid doubled_or_after_separator doubled-or
cmp "$CASES/doubled_or_after_separator.patterns" \
    "$WORK/doubled_or_after_separator.patterns" ||
    fail 'A | || B rollback tree differs from golden'
expect_invalid tail_doubled_or doubled-or
expect_invalid tail_range unsupported-range-pattern
expect_invalid unexpected_after_pattern unexpected-token-after-pattern
cmp "$CASES/unexpected_after_pattern.patterns" \
    "$WORK/unexpected_after_pattern.patterns" ||
    fail 'adjacent atomic rollback tree differs from golden'
if grep 'E2S35' "$WORK/unexpected_after_pattern-normal/stdout" >/dev/null; then
    fail 'adjacent atomic pattern leaked into name resolution'
fi
# #1508: the recovery scanners' depth handling. Each arm of these two fixtures
# is refused, and the refusal's END OFFSET is the assertion -- it is where
# `pattern_recovery_end` and `pattern_arm_arrow` stopped scanning, which is the
# only externally visible statement of how they treat a bracket, a parenthesis,
# and a brace at depth. The golden trees carry one record per arm, so one file
# pins five behaviours rather than one.
#
# They exist because the pattern-parser region of #1408's ledger reported these
# scanners as entirely undefended: 39 untaken branches across
# `pattern_recovery_end`, `pattern_match_open` and `pattern_arm_arrow`, every
# one of them reachable. These three fixtures take 34 of the region's 103.
expect_invalid recovery_depth unsupported-pattern-token
cmp "$CASES/recovery_depth.patterns" "$WORK/recovery_depth.patterns" ||
    fail 'recovery depth tree differs from golden'
test "$(grep -c '^node|' "$WORK/recovery_depth.patterns")" -eq 5 ||
    fail 'recovery depth lost an arm to recovery'
expect_invalid arm_arrow_depth leading-or
cmp "$CASES/arm_arrow_depth.patterns" "$WORK/arm_arrow_depth.patterns" ||
    fail 'arm arrow depth tree differs from golden'

# `pattern_match_open` scans the scrutinee, which no refusal reports, so this
# one is a POSITIVE case: the parse succeeds and the tree is the assertion.
"$STAGE2" --parse-patterns "$CASES/match_open_scan.kofun" \
    "$WORK/match_open_scan.patterns" >"$WORK/match_open_scan.stdout" \
    2>"$WORK/match_open_scan.stderr"
test ! -s "$WORK/match_open_scan.stdout" ||
    fail 'match open scan wrote stdout'
test ! -s "$WORK/match_open_scan.stderr" ||
    fail 'match open scan wrote stderr'
cmp "$CASES/match_open_scan.patterns" "$WORK/match_open_scan.patterns" ||
    fail 'match open scan tree differs from golden'
test "$(grep -c '^match|' "$WORK/match_open_scan.patterns")" -eq 4 ||
    fail 'match open scan did not find four match blocks'

expect_invalid comma_recovery unsupported-pattern-token
cmp "$CASES/comma_recovery.patterns" "$WORK/comma_recovery.patterns" ||
    fail 'comma recovery tree differs from golden'
grep '|NamePattern|.*|Later|' "$WORK/comma_recovery.patterns" >/dev/null ||
    fail 'comma recovery did not preserve the later arm'
grep '|NamePattern|.*|Final|' "$WORK/comma_recovery.patterns" >/dev/null ||
    fail 'adjacent-token comma recovery did not preserve the later arm'
expect_invalid nested_error_order doubled-or
cmp "$CASES/nested_error_order.patterns" \
    "$WORK/nested_error_order.patterns" ||
    fail 'nested source-order diagnostic tree differs from golden'
expect_invalid negative_int unsupported-pattern-token
expect_invalid unsupported unsupported-record-pattern
for reason in unsupported-range-pattern unsupported-rest-pattern; do
    grep "|ErrorPattern|.*|$reason$" "$WORK/unsupported.patterns" >/dev/null ||
        fail "unsupported families omitted $reason"
done

make_depth_case() {
    wrappers=$1
    output=$2
    pattern=x
    index=0
    while test "$index" -lt "$wrappers"; do
        pattern="Node($pattern)"
        index=$((index + 1))
    done
    printf '%s\n' \
        'fn bounded(value: Tree) {' \
        '    match value {' \
        "        $pattern => { print(1) }," \
        '        Later => { print(2) },' \
        '    }' \
        '}' \
        'fn main() {}' >"$output"
}

make_depth_case 31 "$WORK/depth-32.kofun"
"$STAGE2" --parse-patterns "$WORK/depth-32.kofun" \
    "$WORK/depth-32.patterns" >"$WORK/depth-32.stdout"
test ! -s "$WORK/depth-32.stdout" || fail 'tree depth 32 was rejected'
test "$(grep -c '^node|' "$WORK/depth-32.patterns")" -eq 33 ||
    fail 'tree depth 32 node count differs'

make_depth_case 32 "$WORK/depth-33.kofun"
set +e
"$STAGE2" --parse-patterns "$WORK/depth-33.kofun" \
    "$WORK/depth-33.patterns" >"$WORK/depth-33.stdout"
depth_status=$?
set -e
test "$depth_status" -eq 1 || fail 'tree depth 33 was accepted'
grep 'pattern-diagnostic|E2S58|depth-limit|' \
    "$WORK/depth-33.patterns" >/dev/null || fail 'depth limit omitted E2S58'
grep '|NamePattern|.*|Later|' "$WORK/depth-33.patterns" >/dev/null ||
    fail 'depth recovery did not reach the later arm'

make_node_case() {
    alternatives=$1
    output=$2
    later=${3:-false}
    index=0
    pattern=''
    while test "$index" -lt "$alternatives"; do
        test "$index" -eq 0 || pattern="$pattern | "
        pattern="${pattern}N$index"
        index=$((index + 1))
    done
    {
        printf '%s\n' \
            'fn bounded(value: Tree) {' \
            '    match value {' \
            "        $pattern => { print(1) },"
        if test "$later" = true; then
            printf '%s\n' '        Later => { print(2) },'
        fi
        printf '%s\n' \
            '    }' \
            '}' \
            'fn main() {}'
    } >"$output"
}

make_node_case 255 "$WORK/nodes-256.kofun"
"$STAGE2" --parse-patterns "$WORK/nodes-256.kofun" \
    "$WORK/nodes-256.patterns" >"$WORK/nodes-256.stdout"
test ! -s "$WORK/nodes-256.stdout" || fail '256 Pattern nodes were rejected'
test "$(grep -c '^node|' "$WORK/nodes-256.patterns")" -eq 256 ||
    fail '256-node boundary did not preserve all nodes'

make_node_case 256 "$WORK/nodes-257.kofun" true
set +e
"$STAGE2" --parse-patterns "$WORK/nodes-257.kofun" \
    "$WORK/nodes-257.patterns" >"$WORK/nodes-257.stdout"
nodes_status=$?
set -e
test "$nodes_status" -eq 1 || fail '257 Pattern nodes were accepted'
grep 'pattern-diagnostic|E2S58|node-limit|' \
    "$WORK/nodes-257.patterns" >/dev/null ||
    fail 'node limit omitted E2S58 ErrorPattern'
test "$(grep -c '^node|.*|ErrorPattern|.*|node-limit$' \
    "$WORK/nodes-257.patterns")" -eq 1 ||
    fail 'node limit did not emit exactly one ErrorPattern occurrence'
test "$(grep -c '^arm|' "$WORK/nodes-257.patterns")" -eq 1 ||
    fail 'node limit fabricated an arm after the fatal occurrence'
grep '^arm|0|0|256|' "$WORK/nodes-257.patterns" >/dev/null ||
    fail 'node-limit arm does not reference its own ErrorPattern occurrence'
if grep '|NamePattern|.*|Later|' "$WORK/nodes-257.patterns" >/dev/null ||
   grep '^arm|0|1|' "$WORK/nodes-257.patterns" >/dev/null; then
    fail 'node limit reused its ErrorPattern root for the later arm'
fi
grep '^match|0|.*|1$' "$WORK/nodes-257.patterns" >/dev/null ||
    fail 'fatal node limit did not truncate the match to one emitted arm'

printf '%s\n' \
    'PASS: lossless general Pattern trees, recovery, spans, and limits'
