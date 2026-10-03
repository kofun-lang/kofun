#!/bin/sh
set -eu

# `kofun digest` is built from Kofun, with no invocation of the retired
# wrapper, and it verifies every tracked checksum manifest.
# #1455.
#
# The command's SHA-256 comes from the block `bootstrap/stage2/compiler.kofun`
# carries between its `# ---- SHA-256` marker and `fn main`, extracted at build
# time by `bootstrap/digest/build.sh` (the #1668 decision, option a). The build
# is Stage 2 to C plus one `cc` link, so nothing here reaches for the tool it
# replaces.
#
# Two properties are proved, and the acceptance criteria name both:
#
#   1. the build runs zero `kofun-digest` commands. A PATH spy named exactly
#      that logs any invocation; the build must leave the log empty.
#   2. the command verifies every manifest whose entries are tracked in this
#      checkout. Manifests whose entries are generated or downloaded are proved
#      by their owning gates (`task native`, `task stdlib`), not here.
#
# The pre-build seed checks stay non-circular: they use the C verifier
# `kofun_seed_digest_build` builds from `sha256_tool.c`, which does not depend
# on `compiler.c` or on this command (#1668, question 2). The gate proves that
# path still works, so a future change cannot make the seed verify itself.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${KOFUN_DIGEST_COMMAND_WORK:-"$ROOT/build/digest-command"}
CC=${CC:-cc}

fail() {
    printf 'FAIL: digest command: %s\n' "$1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'

case $WORK in
    */digest-command|*/digest-command.*) ;;
    *) fail "work directory must end in digest-command[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

. "$ROOT/bootstrap/digest/build.sh"
. "$ROOT/bootstrap/stage2/build.sh"

# The retired wrapper must be gone, and the builder must not name it. A line
# kept as history in the canonical pair or an RFC record is outside these two
# paths and is listed in the pull request. This gate is the one place the
# retired name is still written, because it is what proves the name is gone.
retired=bin/kofun-digest
test ! -e "$ROOT/$retired" ||
    fail "$retired still exists"
if git -C "$ROOT" grep -q "$retired" -- \
    bootstrap/digest bin/kofun; then
    fail "the digest build still names $retired"
fi

# 1. The spy. A command named `kofun-digest` on PATH logs its own invocation;
#    the build runs with KOFUN_DIGEST_TOOL unset so nothing can short-circuit
#    through an already-built binary.
spy="$WORK/spy"
mkdir -p "$spy"
spy_log="$WORK/spy.log"
: >"$spy_log"
cat >"$spy/kofun-digest" <<SPY
#!/bin/sh
printf '%s\n' "\$*" >>"$spy_log"
exit 1
SPY
chmod +x "$spy/kofun-digest"

env -u KOFUN_DIGEST_TOOL PATH="$spy:$PATH" \
    sh -c '. "$1/bootstrap/digest/build.sh"; kofun_digest_build "$1" "$2"' \
    sh "$ROOT" "$WORK/kofun-digest" ||
    fail 'the command did not build'
test ! -s "$spy_log" ||
    fail "the build invoked kofun-digest: $(cat "$spy_log")"
test -x "$WORK/kofun-digest" ||
    fail 'the build left no executable'

# The build recipe is Kofun, not C: the builder drives Stage 2 to C. This is
# the property the spy alone cannot see.
grep -q -- '--compile-outcome' "$ROOT/bootstrap/digest/build.sh" ||
    fail 'the digest builder no longer compiles Kofun through Stage 2'
grep -q 'bootstrap/digest/command.kofun.in' \
    "$ROOT/bootstrap/digest/build.sh" ||
    fail 'the digest builder no longer reads the Kofun command source'

# 2. Every tracked manifest verifies. Each is run from the directory its owning
#    gate uses, because the entries are relative to different roots.
verify() {
    manifest_dir=$1
    manifest=$2
    ( cd "$ROOT/$manifest_dir" && "$WORK/kofun-digest" -c "$manifest" >/dev/null ) ||
        fail "$manifest did not verify"
}
verify bootstrap/c_abi SHA256SUMS
verify bootstrap/stage1 SHA256SUMS
verify . bootstrap/stage2/SHA256SUMS
verify bootstrap/wasm SHA256SUMS
verify framework/cli SHA256SUMS
verify unicode SHA256SUMS

# 3. The pre-build seed verifier is still non-circular and still works.
kofun_seed_digest_build "$ROOT" "$WORK/seed-digest" ||
    fail 'the C seed verifier did not build'
( cd "$ROOT/bootstrap/stage1" && "$WORK/seed-digest" -c SHA256SUMS >/dev/null ) ||
    fail 'the C seed verifier did not verify bootstrap/stage1/SHA256SUMS'
( cd "$ROOT" && "$WORK/seed-digest" -c bootstrap/stage2/SHA256SUMS >/dev/null ) ||
    fail 'the C seed verifier did not verify bootstrap/stage2/SHA256SUMS'

printf '%s\n' \
    'PASS: kofun digest builds from Kofun with zero kofun-digest invocations, verifies the tracked manifests, and leaves the C seed verifier non-circular'
