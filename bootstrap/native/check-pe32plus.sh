#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NATIVE="$ROOT/bootstrap/native"
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_NATIVE_PE32PLUS_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}native-pe32plus-check"}
ASSERT_CONTEXT=native-pe32plus
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

# The canonical List[Int] writer is accepted and indexed by Stage 2 in the
# caller. Until List-returning user functions lower through the full compiler,
# this Stage 1 bridge materialises the same scalar fields, just as the existing
# ELF checkpoint fixtures do.
"$KOFUN" build "$NATIVE/fixtures/pe32plus_images.kofun" \
    --emit-c "$WORK/emitter.c" \
    -o "$WORK/emitter" >/dev/null
"$WORK/emitter" >"$WORK/stream.first"
"$WORK/emitter" >"$WORK/stream.second"
cmp "$WORK/stream.first" "$WORK/stream.second"

: >"$WORK/x86_64-windows.pe"
: >"$WORK/aarch64-windows.pe"
state=x86
while IFS= read -r field; do
    case $field in
        ''|*[!0-9]*)
            printf '%s\n' "native-pe32plus: invalid numeric field: $field" >&2
            exit 1
            ;;
    esac
    if test "$field" -eq 999; then
        test "$state" = x86 || exit 1
        state=arm
        continue
    fi
    test "$field" -le 255 || {
        printf '%s\n' "native-pe32plus: byte outside 0..255: $field" >&2
        exit 1
    }
    octal=$(printf '%03o' "$field")
    if test "$state" = x86; then
        printf "\\$octal" >>"$WORK/x86_64-windows.pe"
    else
        printf "\\$octal" >>"$WORK/aarch64-windows.pe"
    fi
done <"$WORK/stream.first"
test "$state" = arm || {
    printf '%s\n' "native-pe32plus: AArch64 image delimiter is absent" >&2
    exit 1
}

assert_num "x86-64 PE32+ size" \
    "$(wc -c <"$WORK/x86_64-windows.pe" | tr -d ' ')" -eq 1024
assert_num "AArch64 PE32+ size" \
    "$(wc -c <"$WORK/aarch64-windows.pe" | tr -d ' ')" -eq 1024

# Execute the exact scalar predicate the canonical List[Int] writer calls.
# This keeps the refusal proof on one implementation even while the image
# materialisation itself uses the bounded Stage 1 bridge above.
awk '
    /^# pe32plus-request-validator:start$/ { emit = 1; next }
    /^# pe32plus-request-validator:end$/ { emit = 0; next }
    emit { print }
' "$NATIVE/encoder.kofun" >"$WORK/request-validator.kofun"
cat >>"$WORK/request-validator.kofun" <<'KOFUN'

fn main() {
    print(pe32plus_request_status(34404, 3, 49, 195))
    print(pe32plus_request_status(0, 3, 49, 195))
    print(pe32plus_request_status(34404, 0, 0, 0))
    print(pe32plus_request_status(43620, 513, 0, 255))
    print(pe32plus_request_status(34404, 3, -1, 195))
    print(pe32plus_request_status(43620, 8, 0, 256))
}
KOFUN
"$KOFUN" build "$WORK/request-validator.kofun" \
    --emit-c "$WORK/request-validator.c" \
    -o "$WORK/request-validator" >/dev/null
"$WORK/request-validator" >"$WORK/request-validator.actual"
cat >"$WORK/request-validator.expected" <<'EXPECTED'
0
1
2
2
3
3
EXPECTED
cmp "$WORK/request-validator.expected" "$WORK/request-validator.actual"

node "$NATIVE/pe32plus-check.mjs" \
    "$WORK/x86_64-windows.pe" \
    "$WORK/aarch64-windows.pe"

printf '%s\n' \
    "PASS: Kofun emitted deterministic x86-64 and AArch64 PE32+ images"
printf '%s\n' \
    "PASS: PE32+ invalid machine/code/size inputs refuse before image writing"
