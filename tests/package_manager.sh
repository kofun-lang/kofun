#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KOFUN="$ROOT/bin/kofun"
WORK=${KOFUN_PACKAGE_TEST_WORK:-"$ROOT/build/package-manager-test"}
CC=${CC:-cc}
REAL_CC=$(command -v "$CC")
REAL_CP=$(command -v cp)
ASSERT_CONTEXT='package manager'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK/project" "$WORK/upstream" "$WORK/cache"
cp "$ROOT/tests/packages/consumer.kofun" "$WORK/project/main.kofun"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -c "$ROOT/tests/packages/answer.c" -o "$WORK/upstream/answer.o"
ar rcsD "$WORK/upstream/libanswer.a" "$WORK/upstream/answer.o"
cp "$WORK/upstream/libanswer.a" "$WORK/original-libanswer.a"
sed 's/return 42/return 41/' \
    "$ROOT/tests/packages/answer.c" >"$WORK/replacement-answer.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -c "$WORK/replacement-answer.c" -o "$WORK/replacement-answer.o"
ar rcsD "$WORK/replacement-libanswer.a" "$WORK/replacement-answer.o"

printf '%s\n' \
    'format = 1' \
    '' \
    '[dependency.answer]' \
    'source = "file:../upstream/libanswer.a"' \
    'kind = "static-library"' \
    >"$WORK/project/kofun.packages.toml"

package_command() (
    cd "$WORK/project"
    KOFUN_PACKAGE_CACHE="$WORK/cache" "$KOFUN" package "$@"
)

package_command lock >"$WORK/lock.stdout"
assert_grep "lock.stdout" -Fqx 'locked 1 package(s)' "$WORK/lock.stdout"
cp "$WORK/project/kofun.packages.lock" "$WORK/first.lock"
package_command lock >"$WORK/relock.stdout"
cmp "$WORK/first.lock" "$WORK/project/kofun.packages.lock"

expected_hash=$("$ROOT/bin/kofun-digest" "$WORK/original-libanswer.a" | awk '{ print $1 }')
assert_grep "project/kofun.packages.lock" \
    -Fqx "sha256 = \"$expected_hash\"" "$WORK/project/kofun.packages.lock"
cache_entry=$WORK/cache/sha256/$expected_hash
assert_regular_file "cache entry" "$cache_entry"
assert_eq "digest of $cache_entry" \
    "$("$ROOT/bin/kofun-digest" "$cache_entry" | awk '{ print $1 }')" "$expected_hash"

# A parser failure must not be hidden by a successful downstream sort.
cp "$WORK/project/kofun.packages.toml" "$WORK/valid-manifest"
printf '%s\n' 'unsupported = true' \
    >>"$WORK/project/kofun.packages.toml"
set +e
package_command lock \
    >"$WORK/invalid-manifest.stdout" \
    2>"$WORK/invalid-manifest.stderr"
invalid_manifest_status=$?
set -e
assert_num "invalid manifest status" "$invalid_manifest_status" -ne 0
assert_grep "invalid-manifest.stderr" \
    -q 'unsupported manifest syntax' "$WORK/invalid-manifest.stderr"
cmp "$WORK/first.lock" "$WORK/project/kofun.packages.lock"
cp "$WORK/valid-manifest" "$WORK/project/kofun.packages.toml"

cp "$WORK/project/kofun.packages.lock" "$WORK/valid.lock"
printf '%s\n' 'unsupported = true' \
    >>"$WORK/project/kofun.packages.lock"
set +e
package_command fetch --offline \
    >"$WORK/invalid-lock.stdout" 2>"$WORK/invalid-lock.stderr"
invalid_lock_status=$?
set -e
assert_num "invalid lock status" "$invalid_lock_status" -ne 0
assert_grep "invalid-lock.stderr" \
    -q 'unsupported lockfile syntax' "$WORK/invalid-lock.stderr"
cp "$WORK/valid.lock" "$WORK/project/kofun.packages.lock"

# Collisions with the old .tmp.$$ names must not redirect cache population or
# atomic lock writes. The copy wrapper creates those old names while the
# resolver is live; mktemp-created names remain independent.
mkdir -p "$WORK/collision-cache/sha256" "$WORK/collision-bin"
cp "$ROOT/tests/packages/cp-temp-name-collision.sh" \
    "$WORK/collision-bin/cp"
chmod +x "$WORK/collision-bin/cp"
printf '%s\n' cache-sentinel >"$WORK/cache-victim"
printf '%s\n' lock-sentinel >"$WORK/lock-victim"
(
    cd "$WORK/project"
    PATH="$WORK/collision-bin:$PATH" \
    KOFUN_PACKAGE_CACHE="$WORK/collision-cache" \
    KOFUN_TEST_CACHE="$WORK/collision-cache" \
    KOFUN_TEST_CACHE_SENTINEL="$WORK/cache-victim" \
    KOFUN_TEST_LOCK_DIRECTORY="$WORK/project" \
    KOFUN_TEST_LOCK_SENTINEL="$WORK/lock-victim" \
    KOFUN_REAL_CP="$REAL_CP" \
        "$KOFUN" package lock
) >"$WORK/collision.stdout"
assert_eq "contents of cache-victim" \
    "$(cat "$WORK/cache-victim")" cache-sentinel
assert_eq "contents of lock-victim" "$(cat "$WORK/lock-victim")" lock-sentinel
assert_eq "digest of collision-cache/sha256/$expected_hash" \
    "$("$ROOT/bin/kofun-digest" "$WORK/collision-cache/sha256/$expected_hash" | awk '{ print $1 }')" \
    "$expected_hash"

# Package use cannot silently opt an ordinary build into the host-C ABI.
set +e
(
    cd "$WORK/project"
    KOFUN_PACKAGE_CACHE="$WORK/cache" \
        "$KOFUN" build main.kofun --package answer \
        -o "$WORK/project/implicit-c-abi"
) >"$WORK/implicit.stdout" 2>"$WORK/implicit.stderr"
implicit_status=$?
set -e
assert_num "implicit status" "$implicit_status" -ne 0
assert_absent "project/implicit-c-abi" "$WORK/project/implicit-c-abi"
assert_grep "implicit.stderr" \
    -q -- '--package requires --backend c --c-abi' "$WORK/implicit.stderr"

# The declared source disappears. The content-addressed cache alone must be
# sufficient for both an explicit fetch and the actual Kofun C ABI build.
rm -rf "$WORK/upstream"
package_command fetch --offline >"$WORK/offline-fetch.stdout"
assert_grep "offline-fetch.stdout" \
    -Fqx 'fetched 1 package(s)' "$WORK/offline-fetch.stdout"
(
    cd "$WORK/project"
    KOFUN_PACKAGE_CACHE="$WORK/cache" \
        "$KOFUN" build main.kofun \
        --backend c --c-abi --package answer --offline \
        -o "$WORK/project/app" >/dev/null
)
assert_eq "output of project/app" "$("$WORK/project/app")" 42

# Change the verified shared cache entry while the C ABI compiler is being
# built. The output must keep using the build-private snapshot, and that
# snapshot must be removed after linking.
mkdir -p "$WORK/cc-consistency-bin"
cp "$ROOT/tests/packages/cc-snapshot-consistency.sh" \
    "$WORK/cc-consistency-bin/cc"
chmod +x "$WORK/cc-consistency-bin/cc"
(
    cd "$WORK/project"
    CC="$WORK/cc-consistency-bin/cc" \
    KOFUN_BUILD_DIR="$WORK/consistency-stage1" \
    KOFUN_C_ABI_BUILD_DIR="$WORK/consistency-c-abi" \
    KOFUN_PACKAGE_CACHE="$WORK/cache" \
    KOFUN_TEST_CACHE_ENTRY="$cache_entry" \
    KOFUN_TEST_REPLACEMENT="$WORK/replacement-libanswer.a" \
    KOFUN_TEST_CHANGE_MARKER="$WORK/cache-changed" \
    KOFUN_TEST_SNAPSHOT_LOG="$WORK/snapshot-path" \
    KOFUN_REAL_CC="$REAL_CC" \
    KOFUN_REAL_CP="$REAL_CP" \
        "$KOFUN" build main.kofun \
        --backend c --c-abi --package answer --offline \
        -o "$WORK/project/consistent-app" >/dev/null
)
assert_present "cache-changed" "$WORK/cache-changed"
assert_eq "output of project/consistent-app" \
    "$("$WORK/project/consistent-app")" 42
snapshot_path=$(cat "$WORK/snapshot-path")
assert_nonempty "snapshot path" "$snapshot_path"
assert_absent "snapshot path" "$snapshot_path"
assert_ne "digest of $cache_entry" \
    "$("$ROOT/bin/kofun-digest" "$cache_entry" | awk '{ print $1 }')" "$expected_hash"
chmod u+w "$cache_entry"
cp "$WORK/original-libanswer.a" "$cache_entry"
chmod 444 "$cache_entry"

# Cache bytes are verified on every use rather than trusted because the path
# happens to contain the expected digest.
chmod u+w "$cache_entry"
printf '%s\n' corrupt >"$cache_entry"
set +e
package_command fetch --offline \
    >"$WORK/corrupt.stdout" 2>"$WORK/corrupt.stderr"
corrupt_status=$?
set -e
assert_num "corrupt status" "$corrupt_status" -ne 0
assert_grep "corrupt.stderr" \
    -q 'cached content hash mismatch' "$WORK/corrupt.stderr"

# A missing cache entry may be fetched online/file-locally, but the fetched
# artifact still has to match the exact lock hash.
rm -f "$cache_entry"
mkdir -p "$WORK/upstream"
sed 's/return 42/return 41/' \
    "$ROOT/tests/packages/answer.c" >"$WORK/upstream/answer.c"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -c "$WORK/upstream/answer.c" -o "$WORK/upstream/answer.o"
ar rcsD "$WORK/upstream/libanswer.a" "$WORK/upstream/answer.o"
set +e
package_command fetch \
    >"$WORK/mismatch.stdout" 2>"$WORK/mismatch.stderr"
mismatch_status=$?
set -e
assert_num "mismatch status" "$mismatch_status" -ne 0
assert_grep "mismatch.stderr" \
    -q 'content hash mismatch for package answer' "$WORK/mismatch.stderr"
assert_absent "cache entry" "$cache_entry"

set +e
package_command fetch --offline \
    >"$WORK/miss.stdout" 2>"$WORK/miss.stderr"
miss_status=$?
set -e
assert_num "miss status" "$miss_status" -ne 0
assert_grep "miss.stderr" \
    -q 'offline cache miss for package answer' "$WORK/miss.stderr"

printf '%s\n' \
    "PASS: dependency declaration locked exact SHA-256 artifact bytes" \
    "PASS: Kofun linked and called the declared external package" \
    "PASS: offline fetch and build used only the content-addressed cache" \
    "PASS: corrupt cache and changed upstream content failed verification"
