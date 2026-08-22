#!/bin/sh
set -eu

# The repository computes SHA-256 in two places: `bootstrap/stage2/sha256.c`,
# reached through `bin/kofun-digest`, and Node's `crypto.createHash` in the
# `.mjs` tooling. Before #1213 there was a third, GNU `sha256sum`, and nothing
# compared any of them.
#
# This gate does three things: pins the implementation to published SHA-256
# vectors, proves the two surviving implementations agree byte for byte over a
# corpus chosen to hit the block-boundary cases a hand-written SHA-256 gets
# wrong, and proves the verify mode actually refuses a mutated file rather than
# reporting OK.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIGEST="$ROOT/bin/kofun-digest"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-digest.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'FAIL: digest: %s\n' "$1" >&2
    exit 1
}

digest_of_stdin() {
    "$DIGEST" | awk '{ print $1 }'
}

# 1. Known answers. These are the published SHA-256 vectors; if the
#    implementation is wrong, every digest in the repository is wrong with it,
#    so this is checked before anything is compared to anything else.
actual=$(printf '' | digest_of_stdin)
test "$actual" = \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ||
    fail "empty input digest is $actual"

actual=$(printf 'abc' | digest_of_stdin)
test "$actual" = \
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ||
    fail "\"abc\" digest is $actual"

actual=$(printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' |
    digest_of_stdin)
test "$actual" = \
    248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1 ||
    fail "two-block vector digest is $actual"

printf '%s\n' 'PASS: published SHA-256 vectors'

# 2. Agreement with the other implementation still in the tree. The sizes
#    bracket the 64-byte block and the 56-byte length-field boundary, which is
#    where a padding mistake hides: a wrong implementation usually agrees on
#    short inputs and diverges exactly here.
if command -v node >/dev/null 2>&1; then
    sizes='0 1 55 56 57 63 64 65 127 128 129 1000'
    for size in $sizes; do
        node -e '
            const fs = require("node:fs");
            const size = Number(process.argv[1]);
            const bytes = Buffer.alloc(size);
            for (let i = 0; i < size; i += 1) bytes[i] = (i * 37 + 11) & 0xff;
            fs.writeFileSync(process.argv[2], bytes);
        ' "$size" "$WORK/case-$size.bin"

        theirs=$(node -e '
            const fs = require("node:fs");
            const crypto = require("node:crypto");
            const hash = crypto.createHash("sha256");
            hash.update(fs.readFileSync(process.argv[1]));
            process.stdout.write(hash.digest("hex"));
        ' "$WORK/case-$size.bin")
        ours=$("$DIGEST" "$WORK/case-$size.bin" | awk '{ print $1 }')

        test "$theirs" = "$ours" ||
            fail "size $size: C says $ours, node says $theirs"
    done
    printf '%s\n' \
        'PASS: the C and node implementations agree across the block boundaries'
else
    printf '%s\n' \
        'SKIP: node is absent, so cross-implementation agreement is unchecked'
fi

# 3. The verify mode must refuse. A checker that reports OK on a changed file
#    protects nothing, and this is the property the trusted seed depends on.
printf 'seed\n' >"$WORK/subject"
"$DIGEST" "$WORK/subject" >"$WORK/SHA256SUMS"
( cd "$WORK" && "$DIGEST" -c SHA256SUMS >/dev/null ) ||
    fail 'an unmodified file did not verify'

printf 'tampered\n' >"$WORK/subject"
if ( cd "$WORK" && "$DIGEST" -c SHA256SUMS >/dev/null 2>&1 ); then
    fail 'a modified file still verified'
fi

# An empty or fully malformed list must not pass either: a truncated
# SHA256SUMS would otherwise stop protecting anything while still exiting 0.
: >"$WORK/empty-sums"
if ( cd "$WORK" && "$DIGEST" -c empty-sums >/dev/null 2>&1 ); then
    fail 'a checksum file with no entries reported success'
fi

printf '%s\n' 'PASS: verify mode refuses a modified file and an empty list'

# 4. And nothing in the tree still reaches for a host's digest tool. #1213 is
#    recorded as done in the census, the package manager, and this file's own
#    header, and it was not: one workflow still ran GNU `sha256sum` on its
#    Linux lanes and BSD `shasum` on its macOS ones against each emitted native
#    image, which is the comparison that decides whether the six-host evidence
#    a release binds is accepted. Sections 1 to 3 prove the tool is right; this
#    proves it is the one being used.
if command -v node >/dev/null 2>&1; then
    node "$ROOT/tests/digest/no-host-digest-tools.mjs" ||
        fail 'a call site still computes a digest with a host tool'
else
    printf '%s\n' \
        'SKIP: node is absent, so the call-site scan did not run'
fi
