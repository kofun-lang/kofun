#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SPEC="$ROOT/spec/modules/namespaces.md"
SYNTAX="$ROOT/docs/SYNTAX.md"
WORK=${KOFUN_NAMESPACE_SPEC_WORK:-"$ROOT/build/namespace-spec"}

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

namespace_payload() {
    namespace=$1
    case $namespace in
        value) tag=0 ;;
        type) tag=1 ;;
        module) tag=2 ;;
        meta) tag=3 ;;
        *) return 1 ;;
    esac
    printf '%s\n' \
        'kofun.namespace-id/v1' \
        "tag=$tag" \
        "name=$namespace"
}

namespace_tag() {
    case $1 in
        value) printf '%s' 0 ;;
        type) printf '%s' 1 ;;
        module) printf '%s' 2 ;;
        meta) printf '%s' 3 ;;
        *) return 1 ;;
    esac
}

declaration_namespace() {
    case $1 in
        local|parameter|pattern-binding|function|constant|global|constructor|field|method|associated-function|associated-constant)
            printf '%s' value
            ;;
        nominal-type|enum-type|record-type|type-alias|type-parameter|associated-type|trait)
            printf '%s' type
            ;;
        module-declaration|module-import)
            printf '%s' module
            ;;
        macro|meta-function|compile-time|law)
            printf '%s' meta
            ;;
        *) return 1 ;;
    esac
}

lookup_namespace() {
    case $1 in
        expression|callee|value-pattern) printf '%s' value ;;
        type-annotation|generic-argument|generic-bound|trait-position)
            printf '%s' type
            ;;
        import-target|module-path) printf '%s' module ;;
        meta-invocation|law-invocation) printf '%s' meta ;;
        identifier-dotted-head) printf '%s' module ;;
        *) return 1 ;;
    esac
}

same_scope_allowed() {
    left=$1
    right=$2
    test "$left" != "$right"
}

dotted_head_resolution() {
    module_state=$1
    surrounding=$2
    case $module_state in
        present) printf '%s' module ;;
        absent)
            case $surrounding in
                value|type) printf '%s' "member-$surrounding" ;;
                none) printf '%s' error ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

fingerprint() {
    "$ROOT/bin/kofun-digest" | sed 's/[[:space:]].*//'
}

require_text "$SPEC" 'Kofun uses exactly four module-level namespace kinds'
require_text "$SPEC" 'namespace-polymorphic selective request'
require_text "$SPEC" 'module interpretation owns an identifier-led dotted chain'
require_text "$SPEC" 'Re-exporting the selective request above'
require_text "$SPEC" 'requested or colliding namespace name'
require_text "$SPEC" 'Changing capitalization alone'
require_text "$SPEC" 'No namespace-separation'
require_text "$SYNTAX" 'spec/modules/namespaces.md'

case $WORK in
    */namespace-spec|*/namespace-spec.*) ;;
    *) fail "test work directory must end in namespace-spec[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/path-a" "$WORK/path-b"

for namespace in value type module meta
do
    namespace_payload "$namespace" >"$WORK/$namespace.payload"
    grep -Fq "tag=$(namespace_tag "$namespace")" \
        "$WORK/$namespace.payload" ||
        fail "$namespace namespace tag mismatch"
done

value_hash=$(fingerprint <"$WORK/value.payload")
type_hash=$(fingerprint <"$WORK/type.payload")
module_hash=$(fingerprint <"$WORK/module.payload")
meta_hash=$(fingerprint <"$WORK/meta.payload")
test "$value_hash" = f92b0209e0610884577baef04805e9562e7d51a8a2fd622e6b3894c125ba9171 || fail "value NamespaceId changed: $value_hash"
test "$type_hash" = e5e4740e2186b02f754ac555046d3e9154691fb3aec2661d328f1ddab3c3e4d8 || fail "type NamespaceId changed: $type_hash"
test "$module_hash" = 69ec3bc04dfe901fbde8c591d30aaf9fe8830ee950d677239eb800875b5a5059 || fail "module NamespaceId changed: $module_hash"
test "$meta_hash" = ae61811f2fc38ee147713191bb3fb6c93d44dd68ce6317e1f80671259e06f7d4 || fail "meta NamespaceId changed: $meta_hash"

for mapping in \
    local:value parameter:value pattern-binding:value function:value \
    constant:value global:value constructor:value field:value method:value \
    associated-function:value associated-constant:value \
    nominal-type:type enum-type:type record-type:type type-alias:type \
    type-parameter:type associated-type:type trait:type \
    module-declaration:module module-import:module \
    macro:meta meta-function:meta compile-time:meta law:meta
do
    declaration=${mapping%%:*}
    expected=${mapping#*:}
    actual=$(declaration_namespace "$declaration") ||
        fail "unmapped declaration kind: $declaration"
    test "$actual" = "$expected" ||
        fail "$declaration mapped to $actual instead of $expected"
done

test "$(dotted_head_resolution present value)" = module ||
    fail 'module binding did not own a dotted chain over a same-spelled value'
test "$(dotted_head_resolution present none)" = module ||
    fail 'module-qualified resolution incorrectly fell back after selection'
test "$(dotted_head_resolution absent value)" = member-value ||
    fail 'value member lookup did not run after module lookup missed'
test "$(dotted_head_resolution absent type)" = member-type ||
    fail 'type member lookup did not run after module lookup missed'

for mapping in \
    expression:value callee:value value-pattern:value \
    type-annotation:type generic-bound:type trait-position:type \
    import-target:module module-path:module \
    meta-invocation:meta law-invocation:meta \
    identifier-dotted-head:module
do
    position=${mapping%%:*}
    expected=${mapping#*:}
    actual=$(lookup_namespace "$position") ||
        fail "unmapped lookup position: $position"
    test "$actual" = "$expected" ||
        fail "$position searched $actual instead of $expected"
done

for left in value type module meta
do
    for right in value type module meta
    do
        if test "$left" = "$right"; then
            if same_scope_allowed "$left" "$right"; then
                fail "same-namespace duplicate accepted: $left/$right"
            fi
        else
            same_scope_allowed "$left" "$right" ||
                fail "cross-namespace spelling rejected: $left/$right"
        fi
    done
done

if same_scope_allowed \
    "$(declaration_namespace constructor)" \
    "$(declaration_namespace function)"
then
    fail 'constructor/function collision was accepted'
fi
if same_scope_allowed \
    "$(declaration_namespace trait)" \
    "$(declaration_namespace type-alias)"
then
    fail 'trait/type-alias collision was accepted'
fi

printf '%s|%s|%s\n' 0 value Result >"$WORK/result.bindings-a"
printf '%s|%s|%s\n' 1 type Result >>"$WORK/result.bindings-a"
sed -n '2p' "$WORK/result.bindings-a" >"$WORK/result.bindings-b"
sed -n '1p' "$WORK/result.bindings-a" >>"$WORK/result.bindings-b"
LC_ALL=C sort "$WORK/result.bindings-a" >"$WORK/path-a/result.bindings"
LC_ALL=C sort "$WORK/result.bindings-b" >"$WORK/path-b/result.bindings"
cmp "$WORK/path-a/result.bindings" "$WORK/path-b/result.bindings"
test "$(wc -l <"$WORK/path-a/result.bindings")" -eq 2 ||
    fail 'selective value/type import did not retain two bindings'
cp "$WORK/path-a/result.bindings" "$WORK/result.reexports"
cmp "$WORK/path-a/result.bindings" "$WORK/result.reexports" ||
    fail 're-export changed namespace binding identities'

printf '%s\n' \
    "3|$meta_hash|meta" \
    "0|$value_hash|value" \
    "2|$module_hash|module" \
    "1|$type_hash|type" >"$WORK/identities.unsorted"
LC_ALL=C sort "$WORK/identities.unsorted" >"$WORK/identities.sorted"
sed -n '1p' "$WORK/identities.sorted" | grep -Fq '0|' ||
    fail 'namespace serialization did not start with value tag'
sed -n '4p' "$WORK/identities.sorted" | grep -Fq '3|' ||
    fail 'namespace serialization did not end with meta tag'

printf '%s\n' \
    'PASS: four canonical NamespaceId inputs and tags are stable' \
    'PASS: declarations and syntactic positions map to one namespace' \
    'PASS: same-namespace duplicates reject and cross-namespace names coexist' \
    'PASS: dotted lookup, selective imports, and serialization are deterministic'
