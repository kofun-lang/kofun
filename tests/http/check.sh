#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
ASSERT_CONTEXT='http'
. "$root/tests/assertions/assert.sh"

if [ "$(uname -s)" != "Linux" ]; then
    echo "http integration requires Linux" >&2
    exit 1
fi

for tool in cc ar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "http integration requires $tool" >&2
        exit 1
    fi
done

# This gate used to also assert that benchmarks/http/results.json was
# coherent, and to hash-pin four sources against the digests recorded in it.
# Both left with the benchmark corpus in #1139: the pin existed to prove the
# recorded numbers were measured on those exact bytes, so with the numbers
# recorded in kofun-lang/kofun-benchmarks there is nothing here for it to keep
# honest. What remains is the part that was always the integration test —
# building a real server from Kofun source, serving it, and refusing an
# invalid route configuration.

mkdir -p build
./framework/http/build.sh examples/api_server.kofun build/http-api-test
./framework/http/build.sh \
    tests/http/invalid_route.kofun \
    build/http-invalid-route-test
cc -std=c11 -O2 -Wall -Wextra -Werror \
    tests/http/http_integration.c \
    -o build/http-integration-check
./build/http-integration-check ./build/http-api-test

set +e
./build/http-invalid-route-test \
    >build/http-invalid-route.stdout \
    2>build/http-invalid-route.stderr
invalid_route_status=$?
set -e
assert_num "invalid route status" "$invalid_route_status" -eq 2
assert_file_empty "build/http-invalid-route.stdout" \
    build/http-invalid-route.stdout
assert_file_empty "build/http-invalid-route.stderr" \
    build/http-invalid-route.stderr

printf '%s\n' \
    "http integration: served a real HTTP server built from Kofun source" \
    "http integration: rejected invalid Kofun route configuration"
