#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPEC="$ROOT/spec/modules/source-file-mapping.md"
PACKAGE_SPEC="$ROOT/spec/modules/package-roots.md"
SYNTAX_SPEC="$ROOT/spec/syntax/FOUNDATIONS_AND_CONTROL.md"
BUILD_DOC="$ROOT/docs/BUILD_SYSTEM.md"
WORK=${KOFUN_SOURCE_MAPPING_SPEC_WORK:-"$ROOT/build/source-file-mapping-spec"}
ASSERT_CONTEXT='source-file mapping'
. "$ROOT/tests/assertions/assert.sh"

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

manifest_package_payload() {
    name=$1
    printf '%s\n' \
        'kofun.package-id/v1' \
        'kind=manifest' \
        "name=$name" \
        'version=unspecified' \
        'source=workspace-root' \
        'edition=unspecified' \
        'manifest-schema=1'
}

anonymous_package_payload() {
    logical_source=$1
    printf '%s\n' \
        'kofun.package-id/v1' \
        'kind=anonymous-single-file' \
        "logical-source=$logical_source"
}

file_id_input() {
    package_file=$1
    logical_path=$2
    source_role=$3
    provenance=$4
    printf '%s\n' \
        'kofun.file-id-input/v1' \
        'package-payload-begin'
    cat "$package_file"
    printf '%s\n' \
        'package-payload-end' \
        "logical-path=$logical_path" \
        "source-role=$source_role" \
        "provenance=$provenance"
}

module_id_input() {
    package_file=$1
    module_path=$2
    printf '%s\n' \
        'kofun.module-id-input/v1' \
        'package-payload-begin'
    cat "$package_file"
    printf '%s\n' \
        'package-payload-end' \
        'kind=declared' \
        "module-path=$module_path"
}

anonymous_module_id_input() {
    package_file=$1
    printf '%s\n' \
        'kofun.module-id-input/v1' \
        'package-payload-begin'
    cat "$package_file"
    printf '%s\n' \
        'package-payload-end' \
        'kind=synthetic-root'
}

fingerprint() {
    "$ROOT/bin/kofun-sha256" | sed 's/[[:space:]].*//'
}

ascii_identifier() {
    value=$1
    case $value in
        ''|_|fn|let|mut|own|read|edit|take|return|if|else|for|in|while|break|continue|match|true|false|null|law|monad|meta)
            return 1
            ;;
        [A-Za-z_]* ) ;;
        * ) return 1 ;;
    esac
    case $value in
        *[!A-Za-z0-9_]*) return 1 ;;
    esac
    test "$(printf %s "$value" | wc -c)" -le 255
}

ascii_module_path() {
    path=$1
    test -n "$path" || return 1
    test "$(printf %s "$path" | wc -c)" -le 4096 || return 1
    case $path in
        .*|*.|*..*|*' '*|*"$(printf '\t')"*) return 1 ;;
    esac
    old_ifs=$IFS
    IFS=.
    set -- $path
    IFS=$old_ifs
    test "$#" -le 64 || return 1
    for component do
        ascii_identifier "$component" || return 1
    done
}

header_path() {
    file=$1
    awk '
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        { first += 1 }
        first == 1 && /^module [^[:space:]]+$/ {
            path = substr($0, 8)
            next
        }
        /^module([[:space:]]|$)/ { bad = 1 }
        END {
            if (first == 0 || path == "" || bad) exit 1
            print path
        }
    ' "$file"
}

expect_bad_header() {
    file=$1
    if path=$(header_path "$file") && ascii_module_path "$path"; then
        fail "invalid module header accepted: $file"
    fi
}

valid_source_for_mode() {
    mode=$1
    file=$2
    if test "$mode" = anonymous; then
        ! grep -Eq '^[[:space:]]*module([[:space:]]|$)' "$file"
        return
    fi
    test "$mode" = manifest || return 1
    path=$(header_path "$file") || return 1
    ascii_module_path "$path"
}

require_text "$SPEC" 'explicit module declaration as the sole authority'
require_text "$SPEC" 'kofun.file-id-input/v1'
require_text "$SPEC" 'kofun.module-id-input/v1'
require_text "$SPEC" 'V1 requires exactly one source file per `ModuleId`'
require_text "$PACKAGE_SPEC" 'Source-file and'
require_text "$SYNTAX_SPEC" 'Unicode 17.0.0 `XID_Start`'
require_text "$BUILD_DOC" 'spec/modules/source-file-mapping.md'

case $WORK in
    */source-file-mapping-spec|*/source-file-mapping-spec.*) ;;
    *) fail "test work directory must end in source-file-mapping-spec[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/path-a/src/user" "$WORK/path-b/moved" "$WORK/generated"

manifest_package_payload demo >"$WORK/package.payload"
manifest_package_payload other >"$WORK/other-package.payload"
anonymous_package_payload main.kofun >"$WORK/anonymous-package.payload"

file_id_input "$WORK/package.payload" src/user/service.kofun authored \
    manifest-source >"$WORK/file-before.input"
file_id_input "$WORK/package.payload" moved/service.kofun authored \
    manifest-source >"$WORK/file-after.input"
test "$(fingerprint <"$WORK/file-before.input")" != \
    "$(fingerprint <"$WORK/file-after.input")" ||
    fail 'a logical file move did not change FileId input'

module_id_input "$WORK/package.payload" user.service \
    >"$WORK/module-before.input"
module_id_input "$WORK/package.payload" user.service \
    >"$WORK/module-after.input"
cmp "$WORK/module-before.input" "$WORK/module-after.input"

module_id_input "$WORK/package.payload" user.renamed \
    >"$WORK/module-renamed.input"
test "$(fingerprint <"$WORK/module-before.input")" != \
    "$(fingerprint <"$WORK/module-renamed.input")" ||
    fail 'a module rename did not change ModuleId input'

module_id_input "$WORK/other-package.payload" user.service \
    >"$WORK/other-package-module.input"
test "$(fingerprint <"$WORK/module-before.input")" != \
    "$(fingerprint <"$WORK/other-package-module.input")" ||
    fail 'PackageId did not separate ModuleId input'

anonymous_module_id_input "$WORK/anonymous-package.payload" \
    >"$WORK/anonymous-module.input"
require_text "$WORK/anonymous-module.input" 'kind=synthetic-root'

file_id_input "$WORK/package.payload" generated/service.kofun generated \
    action-v1-service >"$WORK/generated-file.input"
file_id_input "$WORK/package.payload" generated/service.kofun authored \
    manifest-source >"$WORK/authored-file.input"
test "$(fingerprint <"$WORK/generated-file.input")" != \
    "$(fingerprint <"$WORK/authored-file.input")" ||
    fail 'generated and authored FileId inputs collided'

cp "$WORK/package.payload" "$WORK/path-a/package.payload"
cp "$WORK/package.payload" "$WORK/path-b/package.payload"
module_id_input "$WORK/path-a/package.payload" user.service \
    >"$WORK/path-a/module.input"
module_id_input "$WORK/path-b/package.payload" user.service \
    >"$WORK/path-b/module.input"
cmp "$WORK/path-a/module.input" "$WORK/path-b/module.input"
case $(cat "$WORK/path-a/module.input") in
    *"$WORK"*) fail 'identity input contains an absolute checkout path' ;;
esac

printf '%s\n' \
    '# source may move without renaming its module' \
    '' \
    'module user.service' \
    '' \
    'fn run() {}' >"$WORK/path-a/src/user/service.kofun"
cp "$WORK/path-a/src/user/service.kofun" \
    "$WORK/path-b/moved/service.kofun"
cp "$WORK/path-a/src/user/service.kofun" \
    "$WORK/generated/service.kofun"
path_a=$(header_path "$WORK/path-a/src/user/service.kofun")
path_b=$(header_path "$WORK/path-b/moved/service.kofun")
test "$path_a" = user.service && test "$path_b" = user.service ||
    fail 'a file move changed the declared module path'
ascii_module_path "$path_a" || fail 'valid module path rejected'
generated_path=$(header_path "$WORK/generated/service.kofun")
test "$generated_path" = "$path_a" ||
    fail 'generated/authored duplicate-module fixture lost its collision'

printf '%s\n' \
    'module user.service' \
    'module user.duplicate' \
    'fn run() {}' >"$WORK/duplicate-header.kofun"
printf '%s\n' \
    'fn run() {}' \
    'module user.late' >"$WORK/late-header.kofun"
printf '%s\n' 'module user..service' >"$WORK/invalid-component.kofun"
printf '%s\n' 'module user.fn' >"$WORK/keyword-component.kofun"
printf '%s\n' 'fn run() {}' >"$WORK/missing-header.kofun"
for invalid in duplicate-header late-header invalid-component \
    keyword-component missing-header
do
    expect_bad_header "$WORK/$invalid.kofun"
done

printf '%s\n' \
    'module anonymous.must_be_rejected' \
    'fn main() {}' >"$WORK/anonymous-with-header.kofun"
if anonymous_path=$(header_path "$WORK/anonymous-with-header.kofun") &&
   ascii_module_path "$anonymous_path"
then
    test "$anonymous_path" = anonymous.must_be_rejected ||
        fail 'anonymous header probe changed unexpectedly'
else
    fail 'anonymous header probe must be syntactically valid before mode rejection'
fi
if valid_source_for_mode anonymous "$WORK/anonymous-with-header.kofun"; then
    fail 'anonymous source accepted an explicit module header'
fi
valid_source_for_mode anonymous "$WORK/missing-header.kofun" ||
    fail 'anonymous source rejected the synthetic-root form'
valid_source_for_mode manifest "$WORK/path-a/src/user/service.kofun" ||
    fail 'manifest source rejected its required valid module header'
require_text "$SPEC" 'anonymous single-file source must not contain a module header'

module_hash=$(fingerprint <"$WORK/module-before.input")
file_before_hash=$(fingerprint <"$WORK/file-before.input")
file_after_hash=$(fingerprint <"$WORK/file-after.input")
printf '%s|%s\n' "$module_hash" "$file_before_hash" \
    >"$WORK/inventory-a"
printf '%s|%s\n' "$module_hash" "$file_after_hash" \
    >>"$WORK/inventory-a"
sed -n '2p' "$WORK/inventory-a" >"$WORK/inventory-b.unsorted"
sed -n '1p' "$WORK/inventory-a" >>"$WORK/inventory-b.unsorted"
LC_ALL=C sort "$WORK/inventory-a" >"$WORK/inventory-a.sorted"
LC_ALL=C sort "$WORK/inventory-b.unsorted" >"$WORK/inventory-b.sorted"
cmp "$WORK/inventory-a.sorted" "$WORK/inventory-b.sorted"

printf '%s\n' "$module_hash" "$module_hash" |
    LC_ALL=C sort | uniq -d >"$WORK/duplicate-module"
test -s "$WORK/duplicate-module" ||
    fail 'duplicate ModuleId input was not detected'

file_fingerprint=$(fingerprint <"$WORK/file-before.input")
module_fingerprint=$(fingerprint <"$WORK/module-before.input")
anonymous_fingerprint=$(fingerprint <"$WORK/anonymous-module.input")
test "$file_fingerprint" = 53e127cc1bdf84acc28d9887b9bb321e3ba283eee03771b17032e38a005ca957 ||
    fail "FileId example fingerprint changed: $file_fingerprint"
test "$module_fingerprint" = 6622f92f463c088056299ee20d702cfcdc2b63894ce552dbf5c940c426e6137d ||
    fail "ModuleId example fingerprint changed: $module_fingerprint"
test "$anonymous_fingerprint" = 36a7bf4989cf23d4e2196d50ebc00556f6d60863bd223dc53d5ab27a8afe0ee8 ||
    fail "anonymous ModuleId example fingerprint changed: $anonymous_fingerprint"

printf '%s\n' \
    'PASS: explicit module headers are the sole manifest module authority' \
    'PASS: FileId changes on move while ModuleId remains stable' \
    'PASS: package/module renames and generated provenance separate identities' \
    'PASS: header, duplicate, ordering, and path-remap examples are deterministic'
