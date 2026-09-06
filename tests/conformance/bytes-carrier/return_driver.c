/* #1581: count actual allocations around the emitted producer's terminal
 * transfer. The injected failure is a compiler-template probe, not a claim
 * that a source program can currently enter that state. */
#include <stdio.h>
#include <stdlib.h>

static int live_allocations;
static int allocations;
static int releases;
static int inject_transfer_failure;

static void *witness_allocate(size_t size) {
    void *value = malloc(size);
    if (value != NULL) {
        ++live_allocations;
        ++allocations;
    }
    return value;
}

static void witness_release(void *value) {
    if (value != NULL) {
        --live_allocations;
        ++releases;
    }
    free(value);
}

#define malloc witness_allocate
#define free witness_release
#define main kofun_source_main
#include "return-probe.c"
#undef main
#undef free
#undef malloc

static void require(int holds, const char *message) {
    if (!holds) {
        fprintf(stderr, "FAIL: Bytes return ownership: %s\n", message);
        exit(1);
    }
}

int main(void) {
    KofunBytesValue result = kofun_fn_produce();
    require(!kofun_failed, "the successful transfer raised failure");
    require(result.data != NULL && result.length == 512,
            "success did not transfer the result storage");
    require(allocations == 2 && releases == 1 && live_allocations == 1,
            "success did not release only the other owner");
    kofun_bytes_release(&result);
    require(live_allocations == 0 && releases == 2,
            "the caller could not release the transferred storage");

    allocations = releases = 0;
    inject_transfer_failure = 1;
    result = kofun_fn_produce();
    require(kofun_failed, "the failure probe did not reach the transfer");
    require(result.data == NULL && result.length == 0 && result.capacity == 0,
            "failure did not return the empty carrier");
    require(allocations == 2 && releases == 2 && live_allocations == 0,
            "failure discarded live result storage or another owner");
    puts("PASS: Bytes return transfers on success and releases both owners on failure");
    return 0;
}
