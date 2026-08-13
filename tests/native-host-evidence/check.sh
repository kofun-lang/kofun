#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
EVIDENCE="$ROOT/artifacts/native-host-evidence.tsv"
PROVENANCE="$ROOT/artifacts/native-host-provenance.tsv"
SUMS="$ROOT/bootstrap/native/SHA256SUMS"
ASSERT_CONTEXT=native-host-evidence
. "$ROOT/tests/assertions/assert.sh"

assert_file_nonempty "host observation file" "$EVIDENCE"
assert_file_nonempty "host provenance file" "$PROVENANCE"
assert_num "host observation row count" "$(wc -l <"$EVIDENCE" | tr -d ' ')" -eq 6
assert_num "provenance row count" "$(wc -l <"$PROVENANCE" | tr -d ' ')" -eq 3

commit=$(awk -F '\t' '$1 == "commit" { print $2 }' "$PROVENANCE")
run=$(awk -F '\t' '$1 == "run" { print $2 }' "$PROVENANCE")
attempt=$(awk -F '\t' '$1 == "attempt" { print $2 }' "$PROVENANCE")
assert_num "commit digest width" "${#commit}" -eq 40
case $commit in *[!0-9a-f]*) assert_fail "commit digest is not lowercase hexadecimal: $commit" ;; esac
case $run in ''|*[!0-9]*) assert_fail "run identity is not numeric: $run" ;; esac
case $attempt in ''|*[!0-9]*) assert_fail "run attempt is not numeric: $attempt" ;; esac

seen=''
tab=$(printf '\t')
while IFS="$tab" read -r schema row_commit row_run row_attempt target runner platform digest result; do
    assert_eq "$target schema" "$schema" native-host-execution/v1
    assert_eq "$target commit" "$row_commit" "$commit"
    assert_eq "$target run" "$row_run" "$run"
    assert_eq "$target attempt" "$row_attempt" "$attempt"
    case " $seen " in *" $target "*) assert_fail "duplicate target: $target" ;; esac
    seen="$seen $target"

    case $target in
        linux-x86_64)
            path=core_return_42-x86_64.elf
            assert_eq "$target runner" "$runner" ubuntu-24.04
            assert_eq "$target platform" "$platform" linux/x86_64
            assert_eq "$target result" "$result" 'output=42;status=0'
            ;;
        linux-aarch64)
            path=core_return_42-aarch64.elf
            assert_eq "$target runner" "$runner" ubuntu-24.04-arm
            assert_eq "$target platform" "$platform" linux/aarch64
            assert_eq "$target result" "$result" 'output=42;status=0'
            ;;
        windows-x86_64)
            path=pe32plus/x86_64-windows.pe
            assert_eq "$target runner" "$runner" windows-2025
            assert_eq "$target platform" "$platform" windows/X64
            assert_eq "$target result" "$result" 'output=empty;status=0'
            ;;
        windows-aarch64)
            path=pe32plus/aarch64-windows.pe
            assert_eq "$target runner" "$runner" windows-11-arm
            assert_eq "$target platform" "$platform" windows/Arm64
            assert_eq "$target result" "$result" 'output=empty;status=0'
            ;;
        macos-x86_64)
            path=macho64-signed/x86_64-macos-signed.macho
            assert_eq "$target runner" "$runner" macos-15-intel
            assert_eq "$target platform" "$platform" macos/x86_64
            assert_eq "$target result" "$result" 'codesign=valid;output=empty;status=0'
            ;;
        macos-aarch64)
            path=macho64-signed/aarch64-macos-signed.macho
            assert_eq "$target runner" "$runner" macos-15
            assert_eq "$target platform" "$platform" macos/arm64
            assert_eq "$target result" "$result" 'codesign=valid;output=empty;status=0'
            ;;
        *) assert_fail "unexpected target: $target" ;;
    esac
    expected=$(awk -v path="$path" '$2 == path { print $1 }' "$SUMS")
    assert_nonempty "$target pinned digest" "$expected"
    assert_eq "$target digest" "$digest" "$expected"
done <"$EVIDENCE"

for target in \
    linux-x86_64 linux-aarch64 \
    windows-x86_64 windows-aarch64 \
    macos-x86_64 macos-aarch64
do
    case " $seen " in *" $target "*) ;; *) assert_fail "missing target: $target" ;; esac
done

printf '%s\n' \
    "PASS: six Kofun-emitted images executed on matching Linux, Windows, and macOS hosts"
