#!/bin/sh
set -eu

stdlib_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$stdlib_dir/.." && pwd)
abi="$stdlib_dir/linux_x86_64/abi.kofun"

fail() {
    printf 'stdlib contract: FAIL: %s\n' "$*" >&2
    exit 1
}

# This gate requires `readelf`, and says so here rather than discovering it in
# the middle (#1496). It used to look optional: the ELF-shape assertions below
# were wrapped in `if command -v readelf`, silently checking less without it.
# That conditional could never have been taken — `set/tests/verify.sh`, run
# from this file sixty lines earlier, invokes `readelf` unguarded and fails
# with `command not found` before the conditional is reached. Optional in one
# place and required in another is the same fact written twice, and only one
# of them was true.
command -v readelf >/dev/null 2>&1 ||
    fail 'readelf is required: the ELF shape of the native fixtures is what this gate checks'

if find "$stdlib_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

check_constant() {
    name=$1
    value=$2
    grep -Fqx "let $name = $value" "$abi" ||
        fail "missing Linux x86-64 constant $name=$value"
}

while read -r name value
do
    check_constant "$name" "$value"
done <<'SYSCALLS'
SYS_READ 0
SYS_WRITE 1
SYS_OPEN 2
SYS_CLOSE 3
SYS_STAT 4
SYS_LSEEK 8
SYS_MMAP 9
SYS_MUNMAP 11
SYS_NANOSLEEP 35
SYS_SOCKET 41
SYS_CONNECT 42
SYS_BIND 49
SYS_LISTEN 50
SYS_SETSOCKOPT 54
SYS_EXIT 60
SYS_CLOCK_GETTIME 228
SYS_EXIT_GROUP 231
SYS_EPOLL_WAIT 232
SYS_EPOLL_CTL 233
SYS_ACCEPT4 288
SYS_EPOLL_CREATE1 291
SYS_GETRANDOM 318
SYSCALLS

for arity in 0 1 2 3 4 5 6
do
    grep -Fq "intrinsic fn __linux_syscall$arity(" "$abi" ||
        fail "missing syscall$arity intrinsic"
done

grep -Fq 'raw >= LINUX_ERROR_LOW && raw <= LINUX_ERROR_HIGH' "$abi" ||
    fail 'negative Linux return range is not checked'
grep -Fq 'errno: -raw' "$abi" ||
    fail 'negative Linux return is not converted to positive errno'
grep -Fq 'type SysResult[T]' "$abi" ||
    fail 'SysResult value type is missing'
grep -Fq '| Err(SysError)' "$abi" ||
    fail 'SysResult does not carry SysError'

trusted_outside_abi=$(
    find "$stdlib_dir/linux_x86_64" -type f -name '*.kofun' \
        ! -name 'abi.kofun' -exec grep -Hn 'trusted intrinsic' {} + || true
)
[ -z "$trusted_outside_abi" ] ||
    fail 'trusted intrinsic declaration escaped abi.kofun'

intrinsic_outside_abi=$(
    find "$stdlib_dir/linux_x86_64" -type f -name '*.kofun' \
        ! -name 'abi.kofun' -exec grep -Hn '__linux_syscall\|__[a-z]' {} + ||
        true
)
[ -z "$intrinsic_outside_abi" ] ||
    fail 'trusted intrinsic invocation escaped abi.kofun'

for function in \
    raw_open raw_close raw_read raw_write raw_lseek raw_stat \
    raw_mmap raw_munmap raw_socket raw_bind raw_listen raw_accept4 \
    raw_connect raw_setsockopt raw_epoll_create1 raw_epoll_ctl \
    raw_epoll_wait raw_clock_gettime raw_nanosleep raw_getrandom \
    raw_exit raw_exit_group
do
    grep -Fq "fn $function(" "$abi" ||
        fail "missing raw wrapper $function"
done

for signature in \
    'fn file_close(take file: File)' \
    'fn socket_close(take socket: Socket)' \
    'fn epoll_close(take epoll: Epoll)' \
    'fn memory_unmap(take mapping: MemoryMap)'
do
    grep -R -Fq "$signature" "$stdlib_dir/linux_x86_64" ||
        fail "missing affine signature: $signature"
done

for operation in \
    open close read write lseek stat mmap munmap socket bind listen \
    accept4 connect setsockopt epoll_create1 epoll_ctl epoll_wait \
    clock_gettime nanosleep getrandom
do
    grep -R -Fq "\"$operation\"" "$stdlib_dir/linux_x86_64" ||
        fail "safe error operation is missing: $operation"
done

roundtrip="$stdlib_dir/tests/file_roundtrip.kofun"
for call in file_create file_write_all file_seek file_read_exact file_close
do
    grep -Fq "$call(" "$roundtrip" ||
        fail "file round-trip fixture does not call $call"
done
grep -Fq 'bytes_same(payload, received)' "$roundtrip" ||
    fail 'file round-trip fixture does not compare bytes'

tmp_dir=${TMPDIR:-/tmp}/kofun-stdlib-verify.$$
mkdir -p "$tmp_dir"
fixture_file="$tmp_dir/kofun-syscall-roundtrip.fixture"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

"$repo_dir/bin/kofun" run "$stdlib_dir/tests/errno_core.kofun" \
    >"$tmp_dir/errno-core.out"
printf '1\n2\n4095\n7\n' >"$tmp_dir/errno-core.expected"
cmp "$tmp_dir/errno-core.expected" "$tmp_dir/errno-core.out" ||
    fail 'Stage 1 executable errno Core fixture differs'

printf 'stdlib contract: PASS\n'
printf 'stdlib Stage 1 errno Core: PASS\n'

sh "$stdlib_dir/testing/tests/verify.sh"
sh "$stdlib_dir/logging/tests/verify.sh"
sh "$stdlib_dir/list/tests/verify.sh"
sh "$stdlib_dir/vector/tests/verify.sh"
sh "$stdlib_dir/array/tests/verify.sh"
sh "$stdlib_dir/tuple/tests/verify.sh"
sh "$stdlib_dir/set/tests/verify.sh"
sh "$stdlib_dir/map/tests/verify.sh"
sh "$stdlib_dir/binary_heap/tests/verify.sh"

[ "$(uname -s)" = Linux ] ||
    fail 'native file round-trip requires Linux'
[ "$(uname -m)" = x86_64 ] ||
    fail 'native file round-trip requires x86-64'

native_source="$stdlib_dir/tests/file_roundtrip_native.packed.kofun"
native_emitter="$tmp_dir/emit-file-roundtrip"
native_image="$tmp_dir/file_roundtrip.elf"

"$repo_dir/bin/kofun" build "$native_source" \
    -o "$native_emitter" \
    --emit-c "$tmp_dir/emit-file-roundtrip.c" >/dev/null
"$native_emitter" >"$tmp_dir/file_roundtrip.packed"

# Transport six-byte little-endian words from Kofun stdout into the ELF file.
# This loop does not select or generate any ELF header or instruction value.
: >"$native_image"
packed=
while IFS= read -r field
do
    case $field in
        ''|*[!0-9]*)
            fail "invalid native packed field: $field"
            ;;
    esac

    if [ -z "$packed" ]
    then
        [ "$field" -le 281474976710655 ] ||
            fail "packed native word exceeds six bytes: $field"
        packed=$field
        continue
    fi

    count=$field
    [ "$count" -ge 1 ] && [ "$count" -le 6 ] ||
        fail "invalid packed native byte count: $count"
    while [ "$count" -gt 0 ]
    do
        byte=$((packed % 256))
        octal=$(printf '%03o' "$byte")
        printf "\\$octal" >>"$native_image"
        packed=$((packed / 256))
        count=$((count - 1))
    done
    [ "$packed" -eq 0 ] ||
        fail 'packed native word has data beyond its declared byte count'
    packed=
done <"$tmp_dir/file_roundtrip.packed"
[ -z "$packed" ] ||
    fail 'packed native stream ended without a byte count'

[ "$(wc -c <"$native_image" | tr -d ' ')" -eq 459 ] ||
    fail 'native file round-trip ELF has the wrong size'
(
    cd "$tmp_dir"
    "$repo_dir/bin/kofun-digest" -c "$stdlib_dir/tests/SHA256SUMS"
) >/dev/null

# Unconditional: the requirement is declared at the top of this file (#1496).
readelf -h "$native_image" >"$tmp_dir/elf-header.txt"
readelf -l "$native_image" >"$tmp_dir/program-headers.txt"
grep -Eq 'Class:[[:space:]]+ELF64' "$tmp_dir/elf-header.txt" ||
    fail 'native fixture is not ELF64'
grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
    "$tmp_dir/elf-header.txt" ||
    fail 'native fixture is not x86-64'
[ "$(grep -c 'LOAD' "$tmp_dir/program-headers.txt")" -eq 2 ] ||
    fail 'native fixture does not have separate RX and RW load segments'

[ ! -e "$fixture_file" ] ||
    fail 'native fixture path unexpectedly exists before execution'
chmod +x "$native_image"

# Force open(2) to return -EISDIR and prove the image takes a nonzero failure
# path instead of treating a negative raw return as a descriptor.
mkdir "$fixture_file"
set +e
(
    cd "$tmp_dir"
    ./file_roundtrip.elf
) >"$tmp_dir/negative.out" 2>"$tmp_dir/negative.err"
negative_status=$?
set -e
[ "$negative_status" -eq 1 ] ||
    fail "native negative-return probe exited $negative_status instead of 1"
[ ! -s "$tmp_dir/negative.out" ] ||
    fail 'native negative-return probe printed a success result'
[ ! -s "$tmp_dir/negative.err" ] ||
    fail 'native negative-return probe wrote to stderr'
rmdir "$fixture_file"

set +e
(
    cd "$tmp_dir"
    ./file_roundtrip.elf
) >"$tmp_dir/roundtrip.out" 2>"$tmp_dir/roundtrip.err"
native_status=$?
set -e
[ "$native_status" -eq 0 ] ||
    fail "native file round-trip exited $native_status"
[ ! -s "$tmp_dir/roundtrip.err" ] ||
    fail 'native file round-trip wrote to stderr'
printf 'syscall-file-roundtrip: ok\n' >"$tmp_dir/roundtrip.expected"
cmp "$tmp_dir/roundtrip.expected" "$tmp_dir/roundtrip.out" ||
    fail 'native file round-trip output differs'
[ -f "$fixture_file" ] ||
    fail 'native file round-trip did not create the fixture'
[ "$(wc -c <"$fixture_file" | tr -d ' ')" -eq 6 ] ||
    fail 'native file round-trip fixture has the wrong size'
rm -f "$fixture_file"
[ ! -e "$fixture_file" ] ||
    fail 'native file round-trip fixture cleanup failed'

printf 'stdlib native file round-trip: PASS\n'

sh "$stdlib_dir/decimal/tests/verify.sh"
sh "$stdlib_dir/date_time/tests/verify.sh"
sh "$stdlib_dir/random/tests/verify.sh"
sh "$stdlib_dir/entropy/tests/verify.sh"
sh "$stdlib_dir/csv/tests/verify.sh"
sh "$stdlib_dir/toml/tests/verify.sh"
sh "$stdlib_dir/regex/tests/verify.sh"
sh "$stdlib_dir/clock/tests/verify.sh"
sh "$stdlib_dir/json/tests/verify.sh"
