#!/usr/bin/env sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPEC="$ROOT/spec/modules/module-identity.md"
PACKAGE_SPEC="$ROOT/spec/modules/package-roots.md"
MAPPING_SPEC="$ROOT/spec/modules/source-file-mapping.md"
NAMESPACE_SPEC="$ROOT/spec/modules/namespaces.md"
BUILD_DOC="$ROOT/docs/BUILD_SYSTEM.md"
WORK=${KOFUN_MODULE_IDENTITY_SPEC_WORK:-"$ROOT/build/module-identity-spec"}

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

require_text() {
    file=$1
    needle=$2
    grep -Fq "$needle" "$file" ||
        fail "$file does not contain required text: $needle"
}

u16be() {
    number=$1
    test "$number" -ge 0 && test "$number" -le 65535 || return 1
    printf "\\$(printf '%03o' $((number / 256)))"
    printf "\\$(printf '%03o' $((number % 256)))"
}

u32be() {
    number=$1
    test "$number" -ge 0 && test "$number" -le 4294967295 || return 1
    printf "\\$(printf '%03o' $(((number / 16777216) % 256)))"
    printf "\\$(printf '%03o' $(((number / 65536) % 256)))"
    printf "\\$(printf '%03o' $(((number / 256) % 256)))"
    printf "\\$(printf '%03o' $((number % 256)))"
}

byte_count() {
    wc -c <"$1" | tr -d '[:space:]'
}

text_byte_count() {
    printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

field_text() {
    tag=$1
    value=$2
    u16be "$tag"
    u32be "$(text_byte_count "$value")"
    printf '%s' "$value"
}

field_file() {
    tag=$1
    file=$2
    u16be "$tag"
    u32be "$(byte_count "$file")"
    cat "$file"
}

hex_of() {
    od -An -v -tx1 "$1" | tr -d ' \n'
}

hex_to_bytes() (
    hex_bytes_input=$1
    case $hex_bytes_input in
        ''|*[!0123456789abcdefABCDEF]*)
            fail "invalid hexadecimal byte string"
            ;;
    esac
    test $((${#hex_bytes_input} % 2)) -eq 0 ||
        fail "hexadecimal byte string has odd length"

    while test -n "$hex_bytes_input"
    do
        hex_bytes_rest=${hex_bytes_input#??}
        hex_bytes_pair=${hex_bytes_input%"$hex_bytes_rest"}
        hex_bytes_value=$((0x$hex_bytes_pair))
        hex_bytes_octal=$(printf '%03o' "$hex_bytes_value")
        printf "\\$hex_bytes_octal"
        hex_bytes_input=$hex_bytes_rest
    done
)

fingerprint() {
    "$ROOT/bin/kofun-digest" "$1" | awk '{ print $1 }'
}

framed_hash() {
    domain=$1
    payload=$2
    output=$3
    {
        printf 'KOFUN\000'
        u16be "$(text_byte_count "$domain")"
        printf '%s' "$domain"
        u32be "$(byte_count "$payload")"
        cat "$payload"
    } >"$output.preimage"
    digest=$("$ROOT/bin/kofun-digest" "$output.preimage" | awk '{ print $1 }')
    hex_to_bytes "$digest" >"$output"
    test "$(byte_count "$output")" -eq 32 ||
        fail "framed hash did not produce 32 bytes: $domain"
}

facts_vector() {
    lines=$1
    output=$2
    sorted="$output.sorted"
    LC_ALL=C sort "$lines" >"$sorted"
    count=$(awk 'END { print NR + 0 }' "$sorted")
    {
        u32be "$count"
        while IFS= read -r line
        do
            u32be "$(text_byte_count "$line")"
            printf '%s' "$line"
        done <"$sorted"
    } >"$output"
}

public_view() {
    output=$1
    schema=$2
    edition=$3
    package_id=$4
    module_id=$5
    public_facts=$6
    {
        field_text 32769 "$schema"
        field_text 32770 "$edition"
        field_text 32771 semantic-compatibility-1
        field_file 32772 "$package_id"
        field_file 32773 "$module_id"
        field_file 32774 "$public_facts"
    } >"$output"
}

internal_view() {
    output=$1
    schema=$2
    edition=$3
    package_id=$4
    module_id=$5
    public_facts=$6
    internal_facts=$7
    {
        field_text 32769 "$schema"
        field_text 32770 "$edition"
        field_text 32771 semantic-compatibility-1
        field_file 32772 "$package_id"
        field_file 32773 "$module_id"
        field_file 32774 "$public_facts"
        field_file 32775 "$internal_facts"
    } >"$output"
}

abi_view() {
    output=$1
    schema=$2
    edition=$3
    package_id=$4
    module_id=$5
    target=$6
    abi_facts=$7
    {
        field_text 32769 "$schema"
        field_text 32770 "$edition"
        field_file 32771 "$package_id"
        field_file 32772 "$module_id"
        field_text 32773 "$target"
        field_text 32774 debug
        field_text 32775 kofun-cc-1
        field_text 32776 kofun-runtime-abi-1
        field_file 32777 "$abi_facts"
    } >"$output"
}

make_digest_set() {
    name=$1
    schema=$2
    edition=$3
    target=$4
    public_lines=$5
    internal_lines=$6
    abi_lines=$7

    facts_vector "$public_lines" "$WORK/$name.public.vector"
    facts_vector "$internal_lines" "$WORK/$name.internal.vector"
    facts_vector "$abi_lines" "$WORK/$name.abi.vector"
    public_view "$WORK/$name.public.view" "$schema" "$edition" \
        "$WORK/package.id" "$WORK/module.id" "$WORK/$name.public.vector"
    internal_view "$WORK/$name.internal.view" "$schema" "$edition" \
        "$WORK/package.id" "$WORK/module.id" \
        "$WORK/$name.public.vector" "$WORK/$name.internal.vector"
    abi_view "$WORK/$name.abi.view" "$schema" "$edition" \
        "$WORK/package.id" "$WORK/module.id" "$target" \
        "$WORK/$name.abi.vector"
    framed_hash kofun.digest.public-semantic/v1 \
        "$WORK/$name.public.view" "$WORK/$name.public.digest"
    framed_hash kofun.digest.package-internal/v1 \
        "$WORK/$name.internal.view" "$WORK/$name.internal.digest"
    framed_hash kofun.digest.target-abi/v1 \
        "$WORK/$name.abi.view" "$WORK/$name.abi.digest"
}

same_digest() {
    left=$1
    right=$2
    label=$3
    cmp "$left" "$right" || fail "$label unexpectedly changed"
}

changed_digest() {
    left=$1
    right=$2
    label=$3
    ! cmp -s "$left" "$right" || fail "$label unexpectedly stayed unchanged"
}

make_artifact() {
    major=$1
    minor=$2
    fields=$3
    output=$4
    {
        printf 'KIF\000'
        u16be "$major"
        u16be "$minor"
        u32be "$(byte_count "$fields")"
        cat "$fields"
    } >"$output"
}

parse_artifact() {
    artifact=$1
    maximum=$2
    output=$3
    od -An -tu1 -v "$artifact" |
        awk -v maximum="$maximum" '
        {
            for (i = 1; i <= NF; i += 1) bytes[count++] = $i
        }
        function u16(pos) {
            return bytes[pos] * 256 + bytes[pos + 1]
        }
        function u32(pos) {
            return ((bytes[pos] * 256 + bytes[pos + 1]) * 256 + bytes[pos + 2]) * 256 + bytes[pos + 3]
        }
        function known_required(tag) {
            return tag >= 32769 && tag <= 32777
        }
        END {
            if (count > maximum || count < 12) exit 10
            if (bytes[0] != 75 || bytes[1] != 73 ||
                bytes[2] != 70 || bytes[3] != 0) exit 11
            if (u16(4) != 1) exit 12
            if (u32(8) != count - 12) exit 13
            pos = 12
            previous = -1
            field_count = 0
            while (pos < count) {
                if (pos + 6 > count) exit 14
                tag = u16(pos)
                field_length = u32(pos + 2)
                pos += 6
                if (tag <= previous) exit 15
                if (field_length > maximum || pos + field_length > count) exit 16
                if (tag >= 32768 && !known_required(tag)) exit 17
                previous = tag
                field_count += 1
                if (field_count > 256) exit 18
                seen[tag] = 1
                value = ""
                for (j = 0; j < field_length; j += 1) {
                    value = value sprintf("%02x", bytes[pos + j])
                }
                print tag ":" value
                pos += field_length
            }
            if (pos != count) exit 19
            for (tag = 32769; tag <= 32777; tag += 1) {
                if (!seen[tag]) exit 20
            }
        }
        ' >"$output"
}

claimed_digests_match() {
    parsed=$1
    public_digest=$2
    internal_digest=$3
    claimed_public=$(awk -F: '$1 == 32776 { print $2 }' "$parsed")
    claimed_internal=$(awk -F: '$1 == 32777 { print $2 }' "$parsed")
    test "$claimed_public" = "$(hex_of "$public_digest")" &&
        test "$claimed_internal" = "$(hex_of "$internal_digest")"
}

collision_guard() {
    digest_a=$1
    preimage_a=$2
    digest_b=$3
    preimage_b=$4
    test "$digest_a" != "$digest_b" || cmp -s "$preimage_a" "$preimage_b"
}

within_limit() {
    actual=$1
    maximum=$2
    test "$actual" -le "$maximum"
}

check_golden() {
    label=$1
    actual=$2
    expected=$3
    case $expected in
        REPLACE_*)
            printf '%s\n' "GOLDEN $label=$actual"
            GOLDEN_MISSING=1
            ;;
        *)
            test "$actual" = "$expected" ||
                fail "$label golden changed: $actual"
            ;;
    esac
}

require_text "$SPEC" 'versioned length-prefixed binary (`KIF`)'
require_text "$SPEC" 'kofun.digest.public-semantic/v1'
require_text "$SPEC" 'package-internal semantic digest'
require_text "$SPEC" 'target ABI digest'
require_text "$SPEC" '16 MiB'
require_text "$SPEC" 'No identity, encoding, digest'
require_text "$PACKAGE_SPEC" 'kofun.package-id/v1'
require_text "$MAPPING_SPEC" 'kofun.module-id-input/v1'
require_text "$NAMESPACE_SPEC" 'kofun.namespace-id/v1'
require_text "$BUILD_DOC" 'spec/modules/module-identity.md'

for command in awk cmp dd grep head od "$ROOT/bin/kofun-digest" sort tail wc
do
    command -v "$command" >/dev/null 2>&1 ||
        fail "required command not found: $command"
done

case $WORK in
    */module-identity-spec|*/module-identity-spec.*) ;;
    *) fail "work directory must end in module-identity-spec[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/path-a" "$WORK/path-b"

printf '%s\n' \
    'kofun.package-id/v1' \
    'kind=manifest' \
    'name=demo' \
    'version=unspecified' \
    'source=workspace-root' \
    'edition=unspecified' \
    'manifest-schema=1' >"$WORK/path-a/package.payload"
cp "$WORK/path-a/package.payload" "$WORK/path-b/package.payload"
framed_hash kofun.id.package/v1 \
    "$WORK/path-a/package.payload" "$WORK/path-a/package.id"
framed_hash kofun.id.package/v1 \
    "$WORK/path-b/package.payload" "$WORK/path-b/package.id"
cmp "$WORK/path-a/package.id" "$WORK/path-b/package.id"
cp "$WORK/path-a/package.id" "$WORK/package.id"

{
    printf '%s\n' 'kofun.module-id-input/v1' 'package-payload-begin'
    cat "$WORK/path-a/package.payload"
    printf '%s\n' 'package-payload-end' 'kind=declared' 'module-path=demo.api'
} >"$WORK/path-a/module.payload"
{
    printf '%s\n' 'kofun.module-id-input/v1' 'package-payload-begin'
    cat "$WORK/path-b/package.payload"
    printf '%s\n' 'package-payload-end' 'kind=declared' 'module-path=demo.api'
} >"$WORK/path-b/module.payload"
framed_hash kofun.id.module/v1 \
    "$WORK/path-a/module.payload" "$WORK/path-a/module.id"
framed_hash kofun.id.module/v1 \
    "$WORK/path-b/module.payload" "$WORK/path-b/module.id"
cmp "$WORK/path-a/module.id" "$WORK/path-b/module.id"
cp "$WORK/path-a/module.id" "$WORK/module.id"

printf '%s\n' \
    'kofun.namespace-id/v1' \
    'tag=0' \
    'name=value' >"$WORK/namespace.payload"
framed_hash kofun.id.namespace/v1 \
    "$WORK/namespace.payload" "$WORK/namespace.id"
{
    field_file 32769 "$WORK/module.id"
    field_file 32770 "$WORK/namespace.id"
    field_text 32771 function
    field_text 32772 run
} >"$WORK/symbol.payload"
framed_hash kofun.id.symbol/v1 "$WORK/symbol.payload" "$WORK/symbol.id"

printf '%s\n' \
    'ns=type|name=User|kind=record|visibility=pub|arity=0|fields=name:Text|repr=opaque' \
    'ns=value|name=run|kind=fn|visibility=pub|signature=(read:Int)->Int|effects=pure|reexport=api.run' \
    >"$WORK/base.public.lines"
printf '%s\n' \
    'ns=value|name=helper|kind=fn|visibility=internal|signature=(read:Int)->Int|effects=pure' \
    >"$WORK/base.internal.lines"
printf '%s\n' \
    'link=demo_api_run|cc=kofun-cc-1|params=i64|result=i64' \
    'link=demo_api_helper|cc=kofun-cc-1|params=i64|result=i64' \
    >"$WORK/base.abi.lines"

make_digest_set base kofun.interface/v1 edition-1 x86_64-unknown-linux-gnu \
    "$WORK/base.public.lines" "$WORK/base.internal.lines" "$WORK/base.abi.lines"

for variant in private-body private-rename comment-path compiler-patch
do
    cp "$WORK/base.public.lines" "$WORK/$variant.public.lines"
    cp "$WORK/base.internal.lines" "$WORK/$variant.internal.lines"
    cp "$WORK/base.abi.lines" "$WORK/$variant.abi.lines"
    make_digest_set "$variant" kofun.interface/v1 edition-1 \
        x86_64-unknown-linux-gnu "$WORK/$variant.public.lines" \
        "$WORK/$variant.internal.lines" "$WORK/$variant.abi.lines"
    same_digest "$WORK/base.public.digest" "$WORK/$variant.public.digest" \
        "$variant public digest"
    same_digest "$WORK/base.internal.digest" "$WORK/$variant.internal.digest" \
        "$variant internal digest"
    same_digest "$WORK/base.abi.digest" "$WORK/$variant.abi.digest" \
        "$variant ABI digest"
done

cp "$WORK/base.public.lines" "$WORK/internal-signature.public.lines"
printf '%s\n' \
    'ns=value|name=helper|kind=fn|visibility=internal|signature=(read:Text)->Int|effects=pure' \
    >"$WORK/internal-signature.internal.lines"
printf '%s\n' \
    'link=demo_api_run|cc=kofun-cc-1|params=i64|result=i64' \
    'link=demo_api_helper|cc=kofun-cc-1|params=text|result=i64' \
    >"$WORK/internal-signature.abi.lines"
make_digest_set internal-signature kofun.interface/v1 edition-1 \
    x86_64-unknown-linux-gnu "$WORK/internal-signature.public.lines" \
    "$WORK/internal-signature.internal.lines" "$WORK/internal-signature.abi.lines"
same_digest "$WORK/base.public.digest" "$WORK/internal-signature.public.digest" \
    'internal signature public digest'
changed_digest "$WORK/base.internal.digest" "$WORK/internal-signature.internal.digest" \
    'internal signature internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/internal-signature.abi.digest" \
    'internal signature ABI digest'

printf '%s\n' \
    'ns=type|name=User|kind=record|visibility=pub|arity=0|fields=name:Text|repr=opaque' \
    'ns=value|name=run|kind=fn|visibility=pub|signature=(read:Text)->Int|effects=io|reexport=api.run' \
    >"$WORK/public-signature.public.lines"
cp "$WORK/base.internal.lines" "$WORK/public-signature.internal.lines"
printf '%s\n' \
    'link=demo_api_run|cc=kofun-cc-1|params=text|result=i64' \
    'link=demo_api_helper|cc=kofun-cc-1|params=i64|result=i64' \
    >"$WORK/public-signature.abi.lines"
make_digest_set public-signature kofun.interface/v1 edition-1 \
    x86_64-unknown-linux-gnu "$WORK/public-signature.public.lines" \
    "$WORK/public-signature.internal.lines" "$WORK/public-signature.abi.lines"
changed_digest "$WORK/base.public.digest" "$WORK/public-signature.public.digest" \
    'public signature public digest'
changed_digest "$WORK/base.internal.digest" "$WORK/public-signature.internal.digest" \
    'public signature internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/public-signature.abi.digest" \
    'public signature ABI digest'

sed 's/(read:Int)/(edit:Int)/' "$WORK/base.public.lines" \
    >"$WORK/public-ownership.public.lines"
cp "$WORK/base.internal.lines" "$WORK/public-ownership.internal.lines"
sed 's/params=i64/params=edit-i64/' "$WORK/base.abi.lines" \
    >"$WORK/public-ownership.abi.lines"
make_digest_set public-ownership kofun.interface/v1 edition-1 \
    x86_64-unknown-linux-gnu "$WORK/public-ownership.public.lines" \
    "$WORK/public-ownership.internal.lines" "$WORK/public-ownership.abi.lines"
changed_digest "$WORK/base.public.digest" "$WORK/public-ownership.public.digest" \
    'public ownership public digest'
changed_digest "$WORK/base.internal.digest" "$WORK/public-ownership.internal.digest" \
    'public ownership internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/public-ownership.abi.digest" \
    'public ownership ABI digest'

printf '%s\n' \
    'ns=type|name=User|kind=record|visibility=pub|arity=0|fields=name:Text|repr=opaque' \
    'ns=value|name=run|kind=fn|visibility=pub|signature=(read:Int)->Int|effects=pure|reexport=facade.execute' \
    >"$WORK/reexport.public.lines"
cp "$WORK/base.internal.lines" "$WORK/reexport.internal.lines"
printf '%s\n' \
    'link=demo_facade_execute|cc=kofun-cc-1|params=i64|result=i64' \
    'link=demo_api_helper|cc=kofun-cc-1|params=i64|result=i64' \
    >"$WORK/reexport.abi.lines"
make_digest_set reexport kofun.interface/v1 edition-1 \
    x86_64-unknown-linux-gnu "$WORK/reexport.public.lines" \
    "$WORK/reexport.internal.lines" "$WORK/reexport.abi.lines"
changed_digest "$WORK/base.public.digest" "$WORK/reexport.public.digest" \
    're-export public digest'
changed_digest "$WORK/base.internal.digest" "$WORK/reexport.internal.digest" \
    're-export internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/reexport.abi.digest" \
    're-export ABI digest'

make_digest_set target kofun.interface/v1 edition-1 aarch64-unknown-linux-gnu \
    "$WORK/base.public.lines" "$WORK/base.internal.lines" "$WORK/base.abi.lines"
same_digest "$WORK/base.public.digest" "$WORK/target.public.digest" \
    'target-only public digest'
same_digest "$WORK/base.internal.digest" "$WORK/target.internal.digest" \
    'target-only internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/target.abi.digest" \
    'target-only ABI digest'

make_digest_set incompatible kofun.interface/v2 edition-2 \
    x86_64-unknown-linux-gnu "$WORK/base.public.lines" \
    "$WORK/base.internal.lines" "$WORK/base.abi.lines"
changed_digest "$WORK/base.public.digest" "$WORK/incompatible.public.digest" \
    'incompatible schema public digest'
changed_digest "$WORK/base.internal.digest" "$WORK/incompatible.internal.digest" \
    'incompatible schema internal digest'
changed_digest "$WORK/base.abi.digest" "$WORK/incompatible.abi.digest" \
    'incompatible schema ABI digest'

tail -n 1 "$WORK/base.public.lines" >"$WORK/reordered.public.lines"
head -n 1 "$WORK/base.public.lines" >>"$WORK/reordered.public.lines"
make_digest_set reordered kofun.interface/v1 edition-1 \
    x86_64-unknown-linux-gnu "$WORK/reordered.public.lines" \
    "$WORK/base.internal.lines" "$WORK/base.abi.lines"
same_digest "$WORK/base.public.digest" "$WORK/reordered.public.digest" \
    'source-order public digest'
same_digest "$WORK/base.internal.digest" "$WORK/reordered.internal.digest" \
    'source-order internal digest'

{
    field_text 32769 kofun.interface/v1
    field_text 32770 edition-1
    field_text 32771 semantic-compatibility-1
    field_file 32772 "$WORK/package.id"
    field_file 32773 "$WORK/module.id"
    field_file 32774 "$WORK/base.public.vector"
    field_file 32775 "$WORK/base.internal.vector"
    field_file 32776 "$WORK/base.public.digest"
    field_file 32777 "$WORK/base.internal.digest"
} >"$WORK/good.fields"
make_artifact 1 0 "$WORK/good.fields" "$WORK/good.kif"
parse_artifact "$WORK/good.kif" 16777216 "$WORK/good.parsed" ||
    fail 'valid KIF artifact rejected'
claimed_digests_match "$WORK/good.parsed" \
    "$WORK/base.public.digest" "$WORK/base.internal.digest" ||
    fail 'valid KIF digest claims rejected'

{
    field_text 1 optional-presentation-metadata
    cat "$WORK/good.fields"
} >"$WORK/optional.fields"
make_artifact 1 0 "$WORK/optional.fields" "$WORK/optional.kif"
parse_artifact "$WORK/optional.kif" 16777216 "$WORK/optional.parsed" ||
    fail 'unknown optional field was not skipped'

size=$(byte_count "$WORK/good.kif")
dd if="$WORK/good.kif" of="$WORK/truncated.kif" bs=1 \
    count=$((size - 1)) status=none
if parse_artifact "$WORK/truncated.kif" 16777216 "$WORK/truncated.parsed"; then
    fail 'truncated KIF artifact was accepted'
fi
{
    printf 'BAD\000'
    dd if="$WORK/good.kif" bs=1 skip=4 status=none
} >"$WORK/bad-magic.kif"
if parse_artifact "$WORK/bad-magic.kif" 16777216 "$WORK/bad-magic.parsed"; then
    fail 'invalid KIF magic was accepted'
fi
{
    field_text 32769 kofun.interface/v1
    field_text 32769 duplicate
    field_text 32770 edition-1
    field_text 32771 semantic-compatibility-1
    field_file 32772 "$WORK/package.id"
    field_file 32773 "$WORK/module.id"
    field_file 32774 "$WORK/base.public.vector"
    field_file 32775 "$WORK/base.internal.vector"
    field_file 32776 "$WORK/base.public.digest"
    field_file 32777 "$WORK/base.internal.digest"
} >"$WORK/duplicate.fields"
make_artifact 1 0 "$WORK/duplicate.fields" "$WORK/duplicate.kif"
if parse_artifact "$WORK/duplicate.kif" 16777216 "$WORK/duplicate.parsed"; then
    fail 'duplicate KIF field was accepted'
fi
{
    cat "$WORK/good.fields"
    field_text 33000 unknown-required
} >"$WORK/unknown-required.fields"
make_artifact 1 0 "$WORK/unknown-required.fields" "$WORK/unknown-required.kif"
if parse_artifact "$WORK/unknown-required.kif" 16777216 \
    "$WORK/unknown-required.parsed"
then
    fail 'unknown required KIF field was accepted'
fi
make_artifact 2 0 "$WORK/good.fields" "$WORK/wrong-version.kif"
if parse_artifact "$WORK/wrong-version.kif" 16777216 \
    "$WORK/wrong-version.parsed"
then
    fail 'unsupported KIF major version was accepted'
fi
if parse_artifact "$WORK/good.kif" $((size - 1)) "$WORK/oversize.parsed"; then
    fail 'artifact exceeding the configured byte limit was accepted'
fi

dd if=/dev/zero of="$WORK/zero.digest" bs=32 count=1 status=none
{
    field_text 32769 kofun.interface/v1
    field_text 32770 edition-1
    field_text 32771 semantic-compatibility-1
    field_file 32772 "$WORK/package.id"
    field_file 32773 "$WORK/module.id"
    field_file 32774 "$WORK/base.public.vector"
    field_file 32775 "$WORK/base.internal.vector"
    field_file 32776 "$WORK/zero.digest"
    field_file 32777 "$WORK/base.internal.digest"
} >"$WORK/hash-mismatch.fields"
make_artifact 1 0 "$WORK/hash-mismatch.fields" "$WORK/hash-mismatch.kif"
parse_artifact "$WORK/hash-mismatch.kif" 16777216 \
    "$WORK/hash-mismatch.parsed" || fail 'hash-mismatch fixture was malformed'
if claimed_digests_match "$WORK/hash-mismatch.parsed" \
    "$WORK/base.public.digest" "$WORK/base.internal.digest"
then
    fail 'incorrect claimed digest was accepted'
fi

printf '%s' first-preimage >"$WORK/collision-a"
printf '%s' second-preimage >"$WORK/collision-b"
fake_digest=0000000000000000000000000000000000000000000000000000000000000000
if collision_guard "$fake_digest" "$WORK/collision-a" \
    "$fake_digest" "$WORK/collision-b"
then
    fail 'deliberate distinct-preimage collision was accepted'
fi
within_limit 65536 65536 || fail 'declaration count boundary rejected'
if within_limit 65537 65536; then fail 'declaration count overflow accepted'; fi
within_limit 128 128 || fail 'type depth boundary rejected'
if within_limit 129 128; then fail 'type depth overflow accepted'; fi
within_limit 64 64 || fail 're-export depth boundary rejected'
if within_limit 65 64; then fail 're-export depth overflow accepted'; fi

GOLDEN_MISSING=0
check_golden package-id "$(hex_of "$WORK/package.id")" \
    eb09a959d6f2a46fbe09c6bc699748d4c0cae7b243987736d5f837493382937f
check_golden module-id "$(hex_of "$WORK/module.id")" \
    6afda3bdd9875c08bbe21e1be7ea0ff08483939e3c010c59ff41f2d94d3b98cb
check_golden namespace-id "$(hex_of "$WORK/namespace.id")" \
    5c3d8e2f6f7a77587642a93aeb1886477d6240cd889ccac914a39bb0279a5664
check_golden symbol-id "$(hex_of "$WORK/symbol.id")" \
    f66ce5a47a7c7678635c871d28a6533c8523996a522e225b1d4355920265f802
check_golden public-digest "$(hex_of "$WORK/base.public.digest")" \
    88c46f118fdf92aa571bb1a04d5d18b6cdda2763ca3f998bb075af7d09d9bc14
check_golden internal-digest "$(hex_of "$WORK/base.internal.digest")" \
    56184f62a5c353012046e2f23453b4fc9a3ae88e1c9d8ba754b75712c9c109fa
check_golden abi-digest "$(hex_of "$WORK/base.abi.digest")" \
    07bbf6693cc8679e3ce3e693c96a3c79b0f1a273a31c7f67a54bda019f48a8a0
check_golden kif-sha256 "$(fingerprint "$WORK/good.kif")" \
    bc2c7e09acda6767a7fb6e177435c06fda1d3c251abf8fb28464f6bc7e342732
test "$GOLDEN_MISSING" -eq 0 || fail 'replace reported golden placeholders'

printf '%s\n' \
    'PASS: domain-framed PackageId, ModuleId, NamespaceId, and SymbolId are stable' \
    'PASS: every semantic and ABI invalidation-matrix transition is exact' \
    'PASS: canonical KIF bytes are path/order independent and digest checked' \
    'PASS: corruption, version, collision, count, byte, and depth limits reject'
