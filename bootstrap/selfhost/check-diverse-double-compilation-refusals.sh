#!/bin/sh
set -eu

# The refusal corpus for diverse double compilation (B7):
#
#     sh bootstrap/selfhost/check-diverse-double-compilation-refusals.sh OUTPUT
#
# A security gate that cannot fail is worse than no gate, and this one has a
# specific way to become worthless: comparing a toolchain against itself. Two
# names for one compiler, or one compiler reported under two names, would make
# every byte equality the gate asserts a comparison of a run with its own
# output — all green, all vacuous.
#
# So the vacuity guards are exercised here rather than trusted, and so is the
# case the gate exists for: a host C compiler carrying a payload.
#
# Each case states the refusal it expects and the diagnostic that refusal must
# name. A checker that stopped enforcing a rule would otherwise keep reporting
# PASS on an honest pair, and the first sign of trouble would be a backdoored
# toolchain reading as verified.

fail() {
    printf '%s\n' "FAIL: selfhost ddc refusals: $*" >&2
    exit 1
}

test "$#" -eq 1 ||
    fail "usage: sh bootstrap/selfhost/check-diverse-double-compilation-refusals.sh OUTPUT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

gate=bootstrap/selfhost/check-diverse-double-compilation.sh
test -f "$gate" || fail "the gate under test is missing: $gate"

work="$output/.refusals.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin"

honest=$(command -v gcc 2>/dev/null) ||
    fail "the refusal corpus needs \`gcc\` on PATH as its honest reference"
diverse=$(command -v clang 2>/dev/null) ||
    fail "the refusal corpus needs \`clang\` on PATH to back its payload case; it is the gate's own default second toolchain"

# A compiler that is a different binary but reports the honest one's identity.
# This is the case the binary-path guard alone would let through.
cat >"$work/bin/twin-cc" <<EOF
#!/bin/sh
exec "$honest" "\$@"
EOF
chmod +x "$work/bin/twin-cc"

# A simulated Thompson payload: it builds an altered compiler from Kofun
# compiler C while restoring the source it found, so every source digest the
# repository pins still verifies and only what the built compiler emits moves.
#
# It is backed by the *second* toolchain, not the honest reference, because a
# payload wearing the honest compiler's identity is refused by the diversity
# guard before it ever compiles anything — which is that guard working, but
# would leave the payload case untested.
cat >"$work/bin/payload-cc" <<EOF
#!/bin/sh
set -eu
restore=""
cleanup() {
    for pair in \$restore; do
        mv -f "\${pair%%::*}" "\${pair#*::}"
    done
}
trap cleanup EXIT HUP INT TERM
for arg in "\$@"; do
    case "\$arg" in
        *.c)
            if test -f "\$arg" && grep -q 'cannot open input file' "\$arg" 2>/dev/null; then
                cp -p "\$arg" "\$arg.payload-backup"
                restore="\$restore \$arg.payload-backup::\$arg"
                sed -i 's/cannot open input file/cannot open input FILE/g' "\$arg"
            fi
            ;;
    esac
done
"$diverse" "\$@"
EOF
chmod +x "$work/bin/payload-cc"

refusals=0

# Run the gate expecting failure, and require the diagnostic to name `blame`.
refuse() {
    refuse_label=$1
    refuse_blame=$2
    refuse_a=$3
    refuse_b=$4
    refusals=$((refusals + 1))
    if KOFUN_DDC_CC_A="$refuse_a" KOFUN_DDC_CC_B="$refuse_b" \
        sh "$gate" "$work/case-$refusals" \
        >"$work/case-$refusals.stdout" 2>"$work/case-$refusals.stderr"
    then
        fail "the gate accepted \`$refuse_label\`"
    fi
    grep -qF -- "$refuse_blame" "$work/case-$refusals.stderr" ||
        {
            cat "$work/case-$refusals.stderr" >&2
            fail "the \`$refuse_label\` refusal does not name \`$refuse_blame\`"
        }
    printf 'PASS: %s is refused, naming %s\n' "$refuse_label" "$refuse_blame"
}

refuse 'one compiler named twice' \
    'resolve to the same binary' \
    gcc gcc

refuse 'two binaries reporting one identity' \
    'report the same identity' \
    gcc "$work/bin/twin-cc"

refuse 'a compiler that is not installed' \
    'KOFUN_DDC_CC_A and KOFUN_DDC_CC_B' \
    gcc "$work/bin/no-such-compiler"

# The case the gate exists for. The payload leaves every pinned source digest
# intact and changes only what the compiler it builds emits, so the honest
# chain reproduces the checked-in evidence and the payload chain does not.
# That asymmetry is the signal, and the gate must report it as one.
refuse 'a host compiler carrying a Thompson payload' \
    'did not reproduce the pinned evidence' \
    gcc "$work/bin/payload-cc"

printf 'PASS: %s diverse-double-compilation refusals fire and pin their diagnostic\n' \
    "$refusals"
printf 'PASS: the gate cannot pass by comparing a toolchain against itself\n'
