#!/usr/bin/env sh
# #1242. The three RFC-0002 authority types selected by #1241: recognized as
# opaque nominal types, Root and Environment authority affine, EnvironmentKey
# unrestricted, and no route from safe source to a value of any of them.
#
# The name set is read out of `spec/native-toolchain-v1/contract.json` rather
# than written here, so a fourth authority type added to the profile makes this
# gate fail instead of quietly testing three of four. That is the whole reason
# the compiler keeps the set in one function per half of the pair.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/authority-carrier"
WORK=${KOFUN_AUTHORITY_CARRIER_WORK:-"$ROOT/build/authority-carrier"}

fail() {
    printf '%s\n' "FAIL: authority carrier: $1" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

# The declared set, from the profile. `</dev/null` because a command inside a
# `while read` loop otherwise eats the list it is iterating.
node -e '
const c = require("fs").readFileSync(process.argv[1], "utf8");
const decisions = JSON.parse(c).decisions;
// Found by issue number rather than by key, so renaming the decision key does
// not silently drop this gate back to testing nothing.
const entry = Object.values(decisions).find((d) => d && d.issue === 1241);
if (!entry || !Array.isArray(entry.types)) {
    console.error("no #1241 decision with a types array");
    process.exit(1);
}
process.stdout.write(entry.types.join("\n") + "\n");
' "$ROOT/spec/native-toolchain-v1/contract.json" >"$WORK/types.txt" 2>"$WORK/types.err" ||
    fail "could not read the #1241 type set: $(head -1 "$WORK/types.err")"

declared=$(grep -c . "$WORK/types.txt")
test "$declared" -eq 3 ||
    fail "the profile declares $declared authority types; this gate covers 3 — add the cases"

for expected in RootAuthority EnvironmentAuthority EnvironmentKey; do
    grep -Fqx "$expected" "$WORK/types.txt" ||
        fail "the profile no longer declares $expected"
done

# `run` is used rather than `check` because it is the mode #1241 requires to
# refuse: `refuse-before-authority-carrier-abi` for both `build` and `run`.
# `if` rather than a bare call: under `set -e` a failing command in a function
# body exits the script before the status can be printed, and the gate then
# produces no output at all rather than a diagnosis.
outcome() {
    if "$ROOT/bin/kofun" run "$1" \
        >"$WORK/out.stdout" 2>"$WORK/out.stderr" </dev/null
    then
        printf '0'
    else
        printf '%s' "$?"
    fi
}

# stderr, not stdout: `registry.tsv` records `channel: stdout` for the raw
# compiler, and `bin/kofun` re-emits the diagnostic on stderr. Reading the
# wrong stream gives an empty string that compares unequal to everything, so
# the gate fails for the right reason with the wrong explanation.
first_line() {
    head -1 "$WORK/out.stderr" 2>/dev/null
}

# --- the carrier is recognized, and withheld -------------------------------
# Every admitted (type, mode) pair reaches the carrier refusal rather than
# `E2S15 ... not a type`. That distinction is the whole of this child: the name
# is a type whose ABI does not exist yet, not an unknown word.
attempted=0
while IFS= read -r type; do
    for mode in read edit take; do
        attempted=$((attempted + 1))
        printf 'fn holder(%s subject: %s) -> Int {\n    return 0\n}\n\nfn main() -> Int {\n    return 0\n}\n' \
            "$mode" "$type" >"$WORK/case.kofun"
        status=$(outcome "$WORK/case.kofun")
        test "$status" -eq 3 ||
            fail "$mode $type exited $status; #1241 requires the carrier refusal, not a hard error"
        case $(first_line) in
            "error[E2S10]: unsupported Core parameter type $type"*) ;;
            *) fail "$mode $type reported $(first_line)" ;;
        esac
    done
done <"$WORK/types.txt"

test "$attempted" -eq $((declared * 3)) ||
    fail "attempted $attempted (type, mode) pairs for $declared types; the loop lost cases"

# --- Owned versus unrestricted ---------------------------------------------
# A parameter head with no mode is a copy in. Root and Environment authority
# refuse it; EnvironmentKey accepts it, because it names a variable rather than
# carrying the right to read one.
for owned in RootAuthority EnvironmentAuthority; do
    printf 'fn holder(subject: %s) -> Int {\n    return 0\n}\n\nfn main() -> Int {\n    return 0\n}\n' \
        "$owned" >"$WORK/case.kofun"
    status=$(outcome "$WORK/case.kofun")
    test "$status" -eq 1 ||
        fail "$owned copied into a parameter exited $status, not 1"
    case $(first_line) in
        "error[E353]: $owned is an Owned authority and cannot be copied"*) ;;
        *) fail "$owned copied into a parameter reported $(first_line)" ;;
    esac
done

printf 'fn holder(subject: EnvironmentKey) -> Int {\n    return 0\n}\n\nfn main() -> Int {\n    return 0\n}\n' \
    >"$WORK/case.kofun"
status=$(outcome "$WORK/case.kofun")
test "$status" -eq 3 ||
    fail "EnvironmentKey without a mode exited $status; it is unrestricted and must reach the carrier refusal"
case $(first_line) in
    "error[E2S10]: unsupported Core parameter type EnvironmentKey"*) ;;
    *) fail "EnvironmentKey without a mode reported $(first_line)" ;;
esac

# --- no forge route ---------------------------------------------------------
# Every authority type, not just the first: a creation route reintroduced for
# one of them is the shape a single-case gate misses.
while IFS= read -r type; do
    printf 'fn main() -> Int {\n    let subject: %s = 0\n    return 0\n}\n' \
        "$type" >"$WORK/case.kofun"
    status=$(outcome "$WORK/case.kofun")
    test "$status" -eq 1 ||
        fail "creating a $type exited $status, not 1"
    case $(first_line) in
        "error[E352]: no source construct creates a value of type $type"*) ;;
        *) fail "creating a $type reported $(first_line)" ;;
    esac
done <"$WORK/types.txt"

# --- no copy, no equality ---------------------------------------------------
"$ROOT/bin/kofun" run "$CASES/copy.kofun" >"$WORK/out.stdout" 2>"$WORK/out.stderr" </dev/null && copy_status=0 || copy_status=$?
test "$copy_status" -eq 1 || fail "copying an authority binding exited $copy_status, not 1"
case $(first_line) in
    "error[E353]: RootAuthority is an Owned authority and cannot be copied"*) ;;
    *) fail "copying an authority binding reported $(first_line)" ;;
esac

"$ROOT/bin/kofun" run "$CASES/equality.kofun" >"$WORK/out.stdout" 2>"$WORK/out.stderr" </dev/null && eq_status=0 || eq_status=$?
test "$eq_status" -eq 1 || fail "comparing authority bindings exited $eq_status, not 1"
case $(first_line) in
    "error[E353]: RootAuthority is an Owned authority and has no equality"*) ;;
    *) fail "comparing authority bindings reported $(first_line)" ;;
esac

# --- the refusal is not the whole language ----------------------------------
# A negative control. Without it, a compiler that refused every program would
# pass everything above.
"$ROOT/bin/kofun" run "$CASES/control.kofun" >"$WORK/control.stdout" 2>"$WORK/control.stderr" </dev/null ||
    fail "the control program did not run: $(head -1 "$WORK/control.stderr")"
cmp "$CASES/control.stdout" "$WORK/control.stdout" ||
    fail "the control program printed unexpected output"

printf 'PASS: authority carrier: %s declared types, %s (type, mode) pairs withheld, forge/copy/equality refused\n' \
    "$declared" "$attempted"
