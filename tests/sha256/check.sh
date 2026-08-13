#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SHA256="$ROOT/bin/kofun-sha256"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-sha256.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: sha256: $*" >&2
    exit 1
}

digest_of() {
    "$SHA256" "$1" | awk '{ print $1 }'
}

printf '' >"$WORK/empty"
printf 'a' >"$WORK/one-byte"
awk 'BEGIN { for (i = 0; i < 65; i += 1) printf "a" }' >"$WORK/block-boundary"

cat >"$WORK/vectors.tsv" <<'EOF'
empty	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
one-byte	ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb
block-boundary	635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0
EOF

while IFS="$(printf '\t')" read -r name expected
do
    actual=$(digest_of "$WORK/$name")
    test "$actual" = "$expected" ||
        fail "$name known-answer mismatch: expected $expected, got $actual"

    node_digest=$(node -e \
        'const fs=require("node:fs"), crypto=require("node:crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' \
        "$WORK/$name")
    test "$node_digest" = "$actual" ||
        fail "$name differs between the C implementation and Node crypto"
done <"$WORK/vectors.tsv"

stdin_digest=$(printf 'a' | "$SHA256" | awk '{ print $1 }')
test "$stdin_digest" = ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb ||
    fail 'stdin digest mode disagrees with the one-byte vector'

cat >"$WORK/SHA256SUMS" <<'EOF'
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  empty
ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb  one-byte
EOF
(
    cd "$WORK"
    "$SHA256" empty one-byte >printed-sums
    cmp SHA256SUMS printed-sums ||
        fail 'digest mode did not emit SHA256SUMS-compatible records'
    "$SHA256" -c SHA256SUMS >check.stdout
)
grep -Fx 'empty: OK' "$WORK/check.stdout" >/dev/null ||
    fail 'verify mode did not name the verified empty file'
grep -Fx 'one-byte: OK' "$WORK/check.stdout" >/dev/null ||
    fail 'verify mode did not name the verified one-byte file'

printf 'changed' >"$WORK/one-byte"
if (cd "$WORK" && "$SHA256" -c SHA256SUMS >mismatch.stdout 2>mismatch.stderr)
then
    fail 'verify mode accepted a digest mismatch'
fi
grep -Fx 'one-byte: FAILED' "$WORK/mismatch.stdout" >/dev/null ||
    fail 'digest mismatch did not name the mismatched file'

mkdir "$WORK/concurrent-build"
index=0
while test "$index" -lt 4
do
    KOFUN_SHA256_BUILD_DIR="$WORK/concurrent-build" \
        "$SHA256" "$WORK/empty" >"$WORK/concurrent-$index" &
    index=$((index + 1))
done
wait
index=0
while test "$index" -lt 4
do
    grep -Fqx \
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  $WORK/empty" \
        "$WORK/concurrent-$index" ||
        fail "concurrent first build $index did not produce the expected digest"
    index=$((index + 1))
done

external_tool="sha256""sum"
if git -C "$ROOT" grep -n "$external_tool" -- '*.sh' '*.yml' >/dev/null
then
    fail "an executable $external_tool dependency remains"
fi

for source in \
    tooling/lsp/semantic-sidecar.mjs \
    tooling/typed-sidecar/from-stage2.mjs \
    tooling/bindgen-c/bindgen-c.mjs
do
    grep -F 'createHash' "$ROOT/$source" | grep -F 'sha256' >/dev/null ||
        fail "$source no longer exposes the Node SHA-256 path covered above"
done
grep -F 'cp "$ROOT/tooling/typed-sidecar/from-stage2.mjs"' \
    "$ROOT/tooling/lsp/build-semantic-bundle.sh" >/dev/null ||
    fail 'the generated LSP projector no longer comes from the checked Node path'

printf '%s\n' \
    'PASS: repository SHA-256 CLI vectors, verify mode, and Node agreement'
