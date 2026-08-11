#!/usr/bin/env sh

set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/tests/interfaces/fixtures"
WORK=${KOFUN_VISIBILITY_FILTER_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}visibility-filtering"}
CC=${CC:-cc}
PRODUCER="$WORK/kofun-stage2-kif"
KIF_TOOL="$WORK/kofun-kif-v1"
LOGICAL_PATH=demo/api.kofun
EXTERNAL_PACKAGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
. "$ROOT/bootstrap/stage2/semantic-objects.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

case $WORK in
    */visibility-filtering|*/visibility-filtering.*) ;;
    *) fail "work directory must end in visibility-filtering[.suffix]: $WORK" ;;
esac
command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required'
rm -rf "$WORK"
mkdir -p "$WORK"

kofun_stage2_semantic_inputs "$ROOT" library
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/stage2_kif_producer.c" \
    "$KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT" \
    "$KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$KOFUN_STAGE2_SEMANTIC_SHA256_INPUT" \
    -o "$PRODUCER"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/kif_v1_tool.c" \
    "$ROOT/bootstrap/stage2/kif_v1.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    "$ROOT/unicode/kofun_unicode.c" \
    -o "$KIF_TOOL"

for fixture in visibility_ok visibility_ok_private_edit \
    visibility_ok_internal_edit visibility_ok_public_edit
do
    "$PRODUCER" "$CASES/$fixture.kofun" "$LOGICAL_PATH" \
        "$WORK/$fixture.kif" 2026 >/dev/null
    "$KIF_TOOL" read "$WORK/$fixture.kif" "$WORK/$fixture.json"
done

node - "$WORK/visibility_ok.json" <<'NODE'
const fs = require('fs');
const dump = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const facts = dump.facts;
const fact = (name) => facts.find((entry) => entry.name === name);
const publicType = fact('PublicValue');
const publicFunction = fact('public_identity');
const publicPayload = fact('PublicWrap');
const internalType = fact('PackageValue');
const internalFunction = fact('package_identity');
if (!publicType || publicType.kind !== 'adt' || publicType.visibility !== 'pub') {
  throw new Error('public nominal type fact is absent');
}
const publicReference = `nominal:${publicType.symbol_id}`;
if (!publicFunction || publicFunction.visibility !== 'pub' ||
    publicFunction.parameter_types[0] !== publicReference ||
    publicFunction.result !== publicReference) {
  throw new Error('public function nominal identities are not exact');
}
if (!publicPayload || publicPayload.payload_type !== publicReference) {
  throw new Error('public constructor payload nominal identity is not exact');
}
const internalReference = `nominal:${internalType.symbol_id}`;
if (!internalType || internalType.visibility !== 'internal' ||
    !internalFunction || internalFunction.visibility !== 'internal' ||
    internalFunction.parameter_types[0] !== internalReference ||
    internalFunction.result !== internalReference) {
  throw new Error('package-internal nominal identities are not exact');
}
if (facts.some((entry) => /File|file/.test(entry.name))) {
  throw new Error('private name reached the decoded KIF');
}
NODE

digest() {
    key=$1
    file=$2
    sed -n "s/.*\"$key\": \"\([0-9a-f]*\)\".*/\1/p" "$file"
}

base_public=$(digest public_semantic_digest "$WORK/visibility_ok.json")
base_internal=$(digest package_internal_semantic_digest "$WORK/visibility_ok.json")
private_public=$(digest public_semantic_digest "$WORK/visibility_ok_private_edit.json")
private_internal=$(digest package_internal_semantic_digest "$WORK/visibility_ok_private_edit.json")
internal_public=$(digest public_semantic_digest "$WORK/visibility_ok_internal_edit.json")
internal_internal=$(digest package_internal_semantic_digest "$WORK/visibility_ok_internal_edit.json")
public_public=$(digest public_semantic_digest "$WORK/visibility_ok_public_edit.json")
public_internal=$(digest package_internal_semantic_digest "$WORK/visibility_ok_public_edit.json")

test "$base_public" = "$private_public" || fail 'private edit changed public digest'
test "$base_internal" = "$private_internal" || fail 'private edit changed internal digest'
test "$base_public" = "$internal_public" || fail 'internal edit changed public digest'
test "$base_internal" != "$internal_internal" || fail 'internal edit did not change internal digest'
test "$base_public" != "$public_public" || fail 'public edit did not change public digest'
test "$base_internal" != "$public_internal" || fail 'public edit did not change internal digest'

if grep -aEq 'FileValue|FileZero|file_identity' "$WORK/visibility_ok.kif"; then
    fail 'private spelling reached KIF bytes'
fi
if grep -aF "$ROOT" "$WORK/visibility_ok.kif" >/dev/null; then
    fail 'absolute checkout path reached KIF bytes'
fi

"$KIF_TOOL" resolve "$WORK/visibility_ok.kif" "$EXTERNAL_PACKAGE" \
    demo.api "$CASES/consumer_nominal.kofun" "$WORK/public-consumer.hir"
grep -F '|qualifier=api|name=public_identity|' "$WORK/public-consumer.hir" >/dev/null ||
    fail 'source-free public consumer did not resolve nominal API'
grep -F '|view=public|' "$WORK/public-consumer.hir" >/dev/null ||
    fail 'external consumer did not select public view'
public_type_id=$(sed -n \
    '/"name": "PublicValue"/s/.*"symbol_id": "\([0-9a-f]*\)".*/\1/p' \
    "$WORK/visibility_ok.json")
grep -F "|signature=fn(1:nominal:$public_type_id)->nominal:$public_type_id|" \
    "$WORK/public-consumer.hir" >/dev/null ||
    fail 'source-free consumer did not retain the nominal callable signature'

set +e
"$KIF_TOOL" resolve "$WORK/visibility_ok.kif" "$EXTERNAL_PACKAGE" \
    demo.api "$CASES/consumer_internal.kofun" "$WORK/external-internal.hir" \
    >"$WORK/external-internal.stdout" 2>"$WORK/external-internal.stderr"
external_status=$?
set -e
test "$external_status" -ne 0 || fail 'external consumer resolved internal API'
test ! -e "$WORK/external-internal.hir" || fail 'failed external resolution published HIR'

package_id=$(sed -n 's/.*"package_id": "\([0-9a-f]*\)".*/\1/p' \
    "$WORK/visibility_ok.json")
"$KIF_TOOL" resolve "$WORK/visibility_ok.kif" "$package_id" \
    demo.api "$CASES/consumer_internal.kofun" "$WORK/internal-consumer.hir"
grep -F '|qualifier=api|name=package_identity|' "$WORK/internal-consumer.hir" >/dev/null ||
    fail 'same-package source-free consumer did not resolve internal API'
grep -F '|view=package-internal|' "$WORK/internal-consumer.hir" >/dev/null ||
    fail 'same-package consumer did not select internal view'

printf '%s\n' \
    'PASS: compiler facts retain exact nominal parameter/result/payload identities' \
    'PASS: public/internal KIF views omit private facts and select by PackageId' \
    'PASS: private/internal/public edits change semantic digests exactly'
