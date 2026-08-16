/*
 * #1315. The status is private to the emitted C, so it is proved where it
 * lives rather than through a source-level surface the issue does not want.
 *
 * The prelude under test is extracted from a program the compiler just
 * emitted, so this driver measures the shipped bytes rather than a copy of
 * them kept in step by hand.
 *
 * Every check tests the destination pointer before reading through it. A
 * mutation that frees the destination before allocating leaves it NULL, and a
 * driver that dereferenced first would crash instead of reporting -- a
 * detection that cannot say what it detected.
 */
#include "prelude.h"
#include <stdio.h>

static int failures;

static void expect(const char *what, long long got, long long want) {
    if (got != want) {
        printf("FAIL: %s: got %lld, want %lld\n", what, got, want);
        ++failures;
    }
}

static void expect_intact(const char *what, const KofunBytesValue *v,
                          long long length, unsigned char first) {
    if (v->data == NULL) {
        printf("FAIL: %s: the destination lost its storage\n", what);
        ++failures;
        return;
    }
    expect(what, (long long)v->length, length);
    expect(what, (long long)v->capacity, length);
    if (v->data[0] != first) {
        printf("FAIL: %s: the destination bytes changed\n", what);
        ++failures;
    }
}

/* Setup that refuses to dereference a destination the allocator did not
 * give us. Writing the marker byte without this check is how the budget build
 * crashed before printing anything -- a failure with no sentence. */
static int seeded(const char *what, KofunBytesValue *v, long long length,
                  unsigned char marker) {
    KofunBytesStatus s = stage2_bytes_assign_zeroed(v, length);
    if (s.tag != KOFUN_BYTES_SUCCEEDED || v->data == NULL) {
        printf("FAIL: %s: could not seed the destination\n", what);
        ++failures;
        return 0;
    }
    v->data[0] = marker;
    return 1;
}

int main(void) {
#ifndef KOFUN_BYTES_INJECT_ALLOC_BUDGET
    static const long long lengths[] = {0, 1, 255, 16384, 65536};
    for (unsigned i = 0; i < sizeof lengths / sizeof lengths[0]; ++i) {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        KofunBytesStatus s = stage2_bytes_assign_zeroed(&v, lengths[i]);
        expect("succeeded tag", s.tag, KOFUN_BYTES_SUCCEEDED);
        expect("succeeded detail", s.detail, 0);
        expect("length", (long long)v.length, lengths[i]);
        expect("capacity", (long long)v.capacity, lengths[i]);
        if (lengths[i] == 0) {
            if (v.data != NULL) {
                printf("FAIL: empty is not {0,0,NULL}\n");
                ++failures;
            }
        } else if (v.data == NULL) {
            printf("FAIL: positive capacity allocated nothing\n");
            ++failures;
        } else {
            long long nonzero = 0;
            for (long long b = 0; b < lengths[i]; ++b) {
                if (v.data[b] != 0u) ++nonzero;
            }
            expect("zeroed bytes", nonzero, 0);
        }
        kofun_bytes_release(&v);
    }

    /* Over the ceiling. The destination keeps its fields and its bytes. */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("ceiling", &v, 8, 0xABu)) {
            KofunBytesStatus s = stage2_bytes_assign_zeroed(&v, 65537);
            expect("ceiling tag", s.tag, KOFUN_BYTES_CAPACITY_EXCEEDED);
            expect("ceiling detail", s.detail, 65537);
            expect_intact("ceiling", &v, 8, 0xABu);
        }
        kofun_bytes_release(&v);
    }

    /* Negative length is checked before the ceiling, so it reports its own
     * tag rather than the ceiling's. */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("negative", &v, 4, 0xCDu)) {
            KofunBytesStatus s = stage2_bytes_assign_zeroed(&v, -3);
            expect("negative tag", s.tag, KOFUN_BYTES_NEGATIVE_LENGTH);
            expect("negative detail", s.detail, -3);
            expect_intact("negative", &v, 4, 0xCDu);
        }
        kofun_bytes_release(&v);
    }
#else
    /* The budget build runs only the injected-failure case. Sharing one
     * budget with the checks above spent it on their allocations and left
     * this one measuring the wrong call. */
    /* The budget spends its one allocation on the first call, so the second
     * is refused and must leave the first one's storage untouched. */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("oom", &v, 4, 0xEEu)) {
            KofunBytesStatus s = stage2_bytes_assign_zeroed(&v, 32);
            expect("oom tag", s.tag, KOFUN_BYTES_ALLOCATION_FAILED);
            expect("oom detail", s.detail, 32);
            expect_intact("oom", &v, 4, 0xEEu);
        }
        kofun_bytes_release(&v);
    }
#endif

    if (failures != 0) return 1;
    printf("ok\n");
    return 0;
}
