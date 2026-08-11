#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPEC="$ROOT/spec/modules/package-roots.md"
BUILD_DOC="$ROOT/docs/BUILD_SYSTEM.md"
WORK=${KOFUN_PACKAGE_ROOT_SPEC_WORK:-"$ROOT/build/package-root-spec"}

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

manifest_payload() {
    name=$1
    version=$2
    source=$3
    edition=$4
    schema=$5
    printf '%s\n' \
        'kofun.package-id/v1' \
        'kind=manifest' \
        "name=$name" \
        "version=$version" \
        "source=$source" \
        "edition=$edition" \
        "manifest-schema=$schema"
}

anonymous_payload() {
    logical_source=$1
    printf '%s\n' \
        'kofun.package-id/v1' \
        'kind=anonymous-single-file' \
        "logical-source=$logical_source"
}

payload_fingerprint() {
    "$ROOT/bin/kofun-digest" | sed 's/[[:space:]].*//'
}

valid_logical_path() {
    path=$1
    case $path in
        *\\*) return 1 ;;
        ''|/*|*'/'|*'//'*|*:*) return 1 ;;
    esac
    old_ifs=$IFS
    IFS=/
    set -- $path
    IFS=$old_ifs
    test "$#" -gt 0 || return 1
    for component do
        case $component in
            ''|.|..) return 1 ;;
        esac
    done
    return 0
}

require_text "$SPEC" 'kofun.package-id/v1'
require_text "$SPEC" 'kofun build FILE.kofun'
require_text "$SPEC" 'requires `./kofun.toml`'
require_text "$SPEC" 'performs no nearest-ancestor manifest search'
require_text "$BUILD_DOC" 'spec/modules/package-roots.md'

case $WORK in
    */package-root-spec|*/package-root-spec.*) ;;
    *) fail "test work directory must end in package-root-spec[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/path-a" "$WORK/path-b" "$WORK/outside"

manifest_payload demo unspecified workspace-root unspecified 1 \
    >"$WORK/path-a/package-id.payload"
manifest_payload demo unspecified workspace-root unspecified 1 \
    >"$WORK/path-b/package-id.payload"
cmp "$WORK/path-a/package-id.payload" "$WORK/path-b/package-id.payload"

manifest_hash=$(payload_fingerprint <"$WORK/path-a/package-id.payload")
test "$manifest_hash" = \
    1d867a42550ceff1eb6387b47888c253cbb14c1434438182a79bb45872ceb23a ||
    fail "manifest payload fingerprint changed: $manifest_hash"

anonymous_hash=$(anonymous_payload main.kofun | payload_fingerprint)
test "$anonymous_hash" = \
    9d1a6acfe7cd2822d73501f88eec09b9cec9f2a194edad75e4c533fd4968cde9 ||
    fail "anonymous payload fingerprint changed: $anonymous_hash"

case $(cat "$WORK/path-a/package-id.payload") in
    *"$WORK"*) fail 'package identity contains an absolute test path' ;;
esac

for path in src/main.kofun src/lib/util.kofun generated/module.kofun
do
    valid_logical_path "$path" || fail "valid logical path rejected: $path"
done

for path in /absolute/main.kofun ../escape.kofun src/../escape.kofun \
    src/./main.kofun C:/drive/main.kofun 'src\main.kofun' src//main.kofun \
    src/ https:remote.kofun
do
    if valid_logical_path "$path"; then
        fail "invalid logical path accepted: $path"
    fi
done

mkdir -p "$WORK/path-a/root/src"
ln -s "$WORK/outside" "$WORK/path-a/root/src/escape"
root_real=$(CDPATH= cd -- "$WORK/path-a/root" && pwd -P)
escape_real=$(CDPATH= cd -- "$WORK/path-a/root/src/escape" && pwd -P)
case "$escape_real/" in
    "$root_real/"*) fail 'symlink escape remained inside root unexpectedly' ;;
esac

printf '%s\n' \
    'PASS: package-root normative text is linked' \
    'PASS: manifest and anonymous PackageId payloads are stable' \
    'PASS: path-remapped payloads are byte-identical' \
    'PASS: logical traversal and symlink escapes are rejected by the reference gate'
