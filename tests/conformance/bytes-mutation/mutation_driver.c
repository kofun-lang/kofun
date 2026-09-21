/*
 * #1321. The bounded mutation surface is private to the emitted C (all but
 * `len`, `capacity`, and -- since #1499 -- `byte_at`), so it is proved where
 * it lives — the same arrangement #1315 made for the status, and
 * for the same reason: surfacing it would add language surface this child is
 * explicitly not for.
 *
 * The prelude under test is extracted from a program the compiler just
 * emitted, so this driver measures the shipped bytes rather than a copy of
 * them kept in step by hand.
 *
 * Every failure check tests the carrier pointer before reading through it. A
 * mutation that frees the carrier before allocating leaves it NULL,
 * and a driver that dereferenced first would crash instead of reporting — a
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

/* A refusal is two numbers and a promise about the destination, so it is one
 * assertion rather than three written out at every site. */
static void expect_status(const char *what, KofunBytesStatus s,
                          long long tag, long long detail) {
    if (s.tag != tag || s.detail != detail) {
        printf("FAIL: %s: got tag %lld detail %lld, want tag %lld detail %lld\n",
            what, (long long)s.tag, (long long)s.detail, tag, detail);
        ++failures;
    }
}

/* #1499. A byte read is an `Int`, and an offset outside the carrier is the
 * runtime diagnostic R025 plus a zero result rather than a private carrier.
 * This driver includes the prelude, so `kofun_failed` is the flag the read
 * raised; reading it back and resetting it is how one driver observes several
 * refusals, and the harness compares the diagnostics they printed. */
static void expect_clean(const char *what) {
    if (kofun_failed) {
        printf("FAIL: %s: a succeeding operation raised the runtime flag\n",
            what);
        ++failures;
        kofun_failed = false;
    }
}

static void expect_refused(const char *what) {
    if (!kofun_failed) {
        printf("FAIL: %s: a refused operation raised no runtime flag\n", what);
        ++failures;
    }
    kofun_failed = false;
}

static void expect_byte(const char *what, long long got, long long want) {
    expect_clean(what);
    expect(what, got, want);
}

static void expect_read_refused(const char *what, long long got) {
    expect_refused(what);
    expect(what, got, 0);
}

#ifndef KOFUN_BYTES_INJECT_ALLOC_BUDGET
/* A path that cannot be opened reports detail 0; one that opened and then
 * failed to read (a directory, on the hosts that let `fopen` open one)
 * reports 1. Which of the two a directory takes is the host's choice, so the
 * driver pins the tag and accepts either detail. The budget build never
 * reaches a path, so it has no use for this. */
static void expect_unreadable(const char *what, KofunBytesStatus s) {
    if (s.tag != KOFUN_BYTES_FILE_UNREADABLE ||
        (s.detail != 0 && s.detail != 1)) {
        printf("FAIL: %s: got tag %lld detail %lld, want tag %d detail 0 or 1\n",
            what, (long long)s.tag, (long long)s.detail,
            (int)KOFUN_BYTES_FILE_UNREADABLE);
        ++failures;
    }
}
#endif

/* The three fields and the bytes, all of them. `expect_intact` in the #1315
 * driver checks the first byte; a mutation surface can corrupt the last one
 * just as easily, so this compares the whole span against a saved copy. The
 * pointer is part of the promise too: copying the same bytes into replacement
 * storage on a refusal would leave an outstanding edit address dangling. */
typedef struct {
    const unsigned char *data;
    unsigned char bytes[KOFUN_BYTES_CAPACITY_LIMIT];
} BytesWitness;

static BytesWitness witness;

static void remember_into(BytesWitness *saved, const KofunBytesValue *v) {
    saved->data = v->data;
    if (v->data != NULL && v->length > 0) {
        memcpy(saved->bytes, v->data, (size_t)v->length);
    }
}

static void remember(const KofunBytesValue *v) {
    remember_into(&witness, v);
}

static void expect_unchanged_from(const char *what,
                                  const KofunBytesValue *v,
                                  const BytesWitness *saved,
                                  long long length, long long capacity) {
    if (v->data == NULL && capacity > 0) {
        printf("FAIL: %s: the carrier lost its storage\n", what);
        ++failures;
        return;
    }
    if (v->data != saved->data) {
        printf("FAIL: %s: the carrier pointer changed\n", what);
        ++failures;
    }
    expect(what, (long long)v->length, length);
    expect(what, (long long)v->capacity, capacity);
    /* If the pointer changed, its replacement may be smaller than the saved
     * span. The pointer failure is already exact; do not turn it into an OOB
     * read. If only the length field changed, compare the saved length rather
     * than trusting the corrupted field as a byte count. */
    if (v->data == saved->data && v->data != NULL && length > 0 &&
        memcmp(saved->bytes, v->data, (size_t)length) != 0) {
        printf("FAIL: %s: the carrier bytes changed\n", what);
        ++failures;
    }
}

static void expect_unchanged(const char *what, const KofunBytesValue *v,
                             long long length, long long capacity) {
    expect_unchanged_from(what, v, &witness, length, capacity);
}

static int seeded(const char *what, KofunBytesValue *v, long long length) {
    KofunBytesStatus s = stage2_bytes_assign_zeroed(v, length);
    if (s.tag != KOFUN_BYTES_SUCCEEDED || (length > 0 && v->data == NULL)) {
        printf("FAIL: %s: could not seed the destination\n", what);
        ++failures;
        return 0;
    }
    for (long long i = 0; i < length; ++i) {
        v->data[i] = (unsigned char)((i * 7 + 3) & 0xff);
    }
    remember(v);
    return 1;
}

#ifdef KOFUN_BYTES_INJECT_ALLOC_BUDGET
static unsigned append_range_oom_attempts;

#ifndef KOFUN_BYTES_PROVE_RANGE_ATTEMPT_OMISSION
static KofunBytesStatus attempt_append_range_under_oom(
    KofunBytesValue *destination,
    const KofunBytesValue *source,
    long long offset,
    long long count
) {
    KofunBytesStatus status = stage2_bytes_append_range(
        destination, source, offset, count);
    ++append_range_oom_attempts;
    return status;
}
#endif
#endif

int main(void) {
#ifndef KOFUN_BYTES_INJECT_ALLOC_BUDGET
    /* ------------------------------------------------ exact byte values
     *
     * 0x00, 0x7f, 0x80, 0xff at every named length. 0x80 and 0xff are the two
     * that a carrier typed `char` rather than `unsigned char` would sign-extend
     * on the way back out, which is the defect this pins.
     */
    {
        static const long long lengths[] = {0, 1, 255, 16384, 65536};
        static const unsigned char values[] = {0x00u, 0x7fu, 0x80u, 0xffu};
        unsigned matrix_attempts = 0;
        unsigned matrix_successes = 0;
        unsigned matrix_refusals = 0;
        for (unsigned l = 0; l < sizeof lengths / sizeof lengths[0]; ++l) {
            long long length = lengths[l];
            for (unsigned b = 0; b < sizeof values / sizeof values[0]; ++b) {
                KofunBytesValue v = KOFUN_BYTES_EMPTY;
                KofunBytesStatus s = stage2_bytes_assign_zeroed(&v, length);
                expect("seed tag", s.tag, KOFUN_BYTES_SUCCEEDED);
                expect("len", stage2_bytes_len(&v), length);
                expect("capacity", stage2_bytes_capacity(&v), length);
                /* First, middle, and last, so a length of 16,384 does not cost
                 * 16,384 calls to say the same thing four times. */
                long long spots[3];
                spots[0] = 0;
                spots[1] = length / 2;
                spots[2] = length - 1;
                for (unsigned p = 0; p < 3 && length > 0; ++p) {
                    long long at = spots[p];
                    expect_status("byte_set",
                        stage2_bytes_byte_set(&v, at, values[b]), 0, 0);
                    expect_byte("byte_at", stage2_bytes_byte_at(&v, at),
                        values[b]);
                }
                /* The same bytes survive a copy into a second carrier. */
                KofunBytesValue copy = KOFUN_BYTES_EMPTY;
                expect_status("copy",
                    stage2_bytes_append_range(&copy, &v, 0, length), 0, 0);
                expect("copy len", stage2_bytes_len(&copy), length);
                if (length > 0 &&
                    memcmp(copy.data, v.data, (size_t)length) != 0) {
                    printf("FAIL: a copy of %lld bytes differs\n", length);
                    ++failures;
                }
                kofun_bytes_release(&copy);

                /* Append one exact byte at every named starting length. At
                 * the ceiling that operation is the capacity refusal cell of
                 * the same matrix and must preserve the carrier exactly. */
                ++matrix_attempts;
                if (length < KOFUN_BYTES_CAPACITY_LIMIT) {
                    expect_status("matrix append",
                        stage2_bytes_append(&v, values[b]), 0, 0);
                    ++matrix_successes;
                    expect("matrix append len", stage2_bytes_len(&v),
                        length + 1);
                    expect_byte("matrix appended byte",
                        stage2_bytes_byte_at(&v, length), values[b]);
                } else {
                    remember(&v);
                    expect_status("matrix append at ceiling",
                        stage2_bytes_append(&v, values[b]),
                        KOFUN_BYTES_CAPACITY_EXCEEDED,
                        KOFUN_BYTES_CAPACITY_LIMIT + 1);
                    ++matrix_refusals;
                    expect_unchanged("matrix append at ceiling", &v,
                        length, length);
                }
                kofun_bytes_release(&v);
            }
        }
        expect("matrix attempt count", matrix_attempts, 20);
        expect("matrix success count", matrix_successes, 16);
        expect("matrix refusal count", matrix_refusals, 4);
    }

    /* ------------------------------------------------ the byte read
     *
     * Four refusals, each printing R025 once (the harness counts them), each
     * yielding 0, and each leaving the carrier as it was. */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("read", &v, 4)) {
            expect_read_refused("read negative", stage2_bytes_byte_at(&v, -1));
            expect_unchanged("read negative", &v, 4, 4);
            expect_read_refused("read at length", stage2_bytes_byte_at(&v, 4));
            expect_unchanged("read at length", &v, 4, 4);
            expect_read_refused("read past length",
                stage2_bytes_byte_at(&v, 99));
            expect_unchanged("read past length", &v, 4, 4);
            /* The refusal is a diagnostic, not a poisoned carrier: the next
             * in-range read answers, and raises nothing. */
            expect_byte("read after refusal", stage2_bytes_byte_at(&v, 1),
                (1 * 7 + 3) & 0xff);
        }
        kofun_bytes_release(&v);
        /* An empty carrier has no byte 0. */
        KofunBytesValue e = KOFUN_BYTES_EMPTY;
        remember(&e);
        expect_read_refused("read empty", stage2_bytes_byte_at(&e, 0));
        expect_unchanged("read empty", &e, 0, 0);
    }

    /* ------------------------------------------------ the file read
     *
     * The harness prepares the files under KOFUN_BYTES_MUTATION_READ_DIR.
     * Three refusals, each also its named diagnostic (R026, R026, R027) and
     * each leaving the seeded carrier exactly as it was; then three reads that
     * replace the bytes and the length, growing capacity as append would, and
     * an empty file that leaves the allocation in place. */
    {
        const char *dir = getenv("KOFUN_BYTES_MUTATION_READ_DIR");
        if (dir == NULL) {
            printf("FAIL: KOFUN_BYTES_MUTATION_READ_DIR is not set\n");
            ++failures;
        }
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        char path[4096];
        if (dir != NULL && seeded("read_file", &v, 4)) {
            snprintf(path, sizeof path, "%s/missing.bin", dir);
            expect_status("read_file missing path",
                stage2_bytes_read_file(&v, path),
                KOFUN_BYTES_FILE_UNREADABLE, 0);
            expect_refused("read_file missing path");
            expect_unchanged("read_file missing path", &v, 4, 4);
            snprintf(path, sizeof path, "%s/directory", dir);
            expect_unreadable("read_file directory",
                stage2_bytes_read_file(&v, path));
            expect_refused("read_file directory");
            expect_unchanged("read_file directory", &v, 4, 4);
            snprintf(path, sizeof path, "%s/over.bin", dir);
            expect_status("read_file over the ceiling",
                stage2_bytes_read_file(&v, path),
                KOFUN_BYTES_CAPACITY_EXCEEDED, KOFUN_BYTES_CAPACITY_LIMIT + 1);
            expect_refused("read_file over the ceiling");
            expect_unchanged("read_file over the ceiling", &v, 4, 4);

            snprintf(path, sizeof path, "%s/small.bin", dir);
            expect_status("read_file small",
                stage2_bytes_read_file(&v, path), 0, 0);
            expect_clean("read_file small");
            expect("read_file small len", stage2_bytes_len(&v), 5);
            expect("read_file small capacity", stage2_bytes_capacity(&v),
                KOFUN_BYTES_GROWTH_FLOOR);
            expect_byte("read_file small first byte",
                stage2_bytes_byte_at(&v, 0), 'H');
            expect_byte("read_file small last byte",
                stage2_bytes_byte_at(&v, 4), 'o');
            expect_read_refused("read_file small past the end",
                stage2_bytes_byte_at(&v, 5));

            snprintf(path, sizeof path, "%s/exact.bin", dir);
            expect_status("read_file at the ceiling",
                stage2_bytes_read_file(&v, path), 0, 0);
            expect_clean("read_file at the ceiling");
            expect("read_file at the ceiling len", stage2_bytes_len(&v),
                KOFUN_BYTES_CAPACITY_LIMIT);
            expect("read_file at the ceiling capacity",
                stage2_bytes_capacity(&v), KOFUN_BYTES_CAPACITY_LIMIT);
            expect_byte("read_file at the ceiling last byte",
                stage2_bytes_byte_at(&v, KOFUN_BYTES_CAPACITY_LIMIT - 1), 'b');

            snprintf(path, sizeof path, "%s/empty.bin", dir);
            expect_status("read_file empty",
                stage2_bytes_read_file(&v, path), 0, 0);
            expect_clean("read_file empty");
            expect("read_file empty len", stage2_bytes_len(&v), 0);
            expect("read_file empty capacity", stage2_bytes_capacity(&v),
                KOFUN_BYTES_CAPACITY_LIMIT);
        }
        kofun_bytes_release(&v);
    }

    /* ------------------------------------- byte_set precedence and refusals
     *
     * Offset negativity and bounds precede the byte check, so a call that is
     * wrong twice reports the offset. The reverse order would let a caller fix
     * the byte and meet a second, different refusal.
     */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("set", &v, 4)) {
            expect_status("set negative offset, invalid byte",
                stage2_bytes_byte_set(&v, -2, 999),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -2);
            expect_unchanged("set negative offset", &v, 4, 4);
            expect_status("set at length, invalid byte",
                stage2_bytes_byte_set(&v, 4, 999),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 4);
            expect_unchanged("set at length", &v, 4, 4);
            expect_status("set invalid byte low",
                stage2_bytes_byte_set(&v, 1, -1),
                KOFUN_BYTES_INVALID_BYTE, -1);
            expect_unchanged("set invalid byte low", &v, 4, 4);
            expect_status("set invalid byte high",
                stage2_bytes_byte_set(&v, 1, 256),
                KOFUN_BYTES_INVALID_BYTE, 256);
            expect_unchanged("set invalid byte high", &v, 4, 4);
            expect_status("set 255", stage2_bytes_byte_set(&v, 1, 255), 0, 0);
            expect_byte("set 255 reads back", stage2_bytes_byte_at(&v, 1), 255);
        }
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ clear and reserve */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("clear", &v, 32)) {
            unsigned char *before = v.data;
            stage2_bytes_clear(&v);
            expect("clear length", stage2_bytes_len(&v), 0);
            expect("clear capacity", stage2_bytes_capacity(&v), 32);
            if (v.data != before) {
                printf("FAIL: clear reallocated\n");
                ++failures;
            }
            /* Clearing twice is the same fact stated twice. */
            stage2_bytes_clear(&v);
            expect("clear again", stage2_bytes_capacity(&v), 32);
        }
        kofun_bytes_release(&v);
    }
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("reserve", &v, 8)) {
            expect_status("reserve negative", stage2_bytes_reserve(&v, -1),
                KOFUN_BYTES_NEGATIVE_LENGTH, -1);
#ifdef KOFUN_BYTES_PROVE_POINTER_WITNESS
            /* A proof build replaces the storage while preserving capacity
             * and bytes. Only the pointer witness can distinguish it. */
            unsigned char *original = v.data;
            unsigned char *replacement = (unsigned char *)malloc(v.capacity);
            if (replacement != NULL) {
                memcpy(replacement, v.data, (size_t)v.length);
                v.data = replacement;
            }
#endif
            expect_unchanged("reserve negative", &v, 8, 8);
#ifdef KOFUN_BYTES_PROVE_POINTER_WITNESS
            if (replacement != NULL) {
                v.data = original;
                free(replacement);
            }
#endif
            expect_status("reserve over ceiling",
                stage2_bytes_reserve(&v, KOFUN_BYTES_CAPACITY_LIMIT + 1),
                KOFUN_BYTES_CAPACITY_EXCEEDED, KOFUN_BYTES_CAPACITY_LIMIT + 1);
            expect_unchanged("reserve over ceiling", &v, 8, 8);
            expect_status("reserve below capacity",
                stage2_bytes_reserve(&v, 4), 0, 0);
            expect_unchanged("reserve below capacity", &v, 8, 8);
            expect_status("reserve grows", stage2_bytes_reserve(&v, 40), 0, 0);
            expect("reserve length is untouched", stage2_bytes_len(&v), 8);
            expect("reserve capacity", stage2_bytes_capacity(&v), 64);
            if (memcmp(witness.bytes, v.data, 8) != 0) {
                printf("FAIL: reserve changed the bytes it kept\n");
                ++failures;
            }
            expect_status("reserve to the ceiling",
                stage2_bytes_reserve(&v, KOFUN_BYTES_CAPACITY_LIMIT), 0, 0);
            expect("ceiling capacity", stage2_bytes_capacity(&v),
                KOFUN_BYTES_CAPACITY_LIMIT);
        }
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ the growth ladder
     *
     * 0 -> 16, then each doubling edge, then the ceiling and one over it. The
     * ladder is walked rather than spot-checked, because "doubles until the
     * request fits" is a rule about every step and a defect at one step is
     * invisible from the two around it.
     */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        expect("empty capacity", stage2_bytes_capacity(&v), 0);
        expect_status("first append", stage2_bytes_append(&v, 1), 0, 0);
        expect("first growth", stage2_bytes_capacity(&v), 16);
        long long expected = 16;
        while (expected < KOFUN_BYTES_CAPACITY_LIMIT) {
            while (stage2_bytes_len(&v) < expected) {
                expect_status("fill", stage2_bytes_append(&v, 2), 0, 0);
            }
            expect("filled to capacity", stage2_bytes_capacity(&v), expected);
            expect_status("append past the edge",
                stage2_bytes_append(&v, 3), 0, 0);
            expected = expected * 2;
            expect("doubled", stage2_bytes_capacity(&v), expected);
        }
        while (stage2_bytes_len(&v) < KOFUN_BYTES_CAPACITY_LIMIT) {
            expect_status("fill to the ceiling",
                stage2_bytes_append(&v, 4), 0, 0);
        }
        expect("at the ceiling", stage2_bytes_len(&v),
            KOFUN_BYTES_CAPACITY_LIMIT);
        remember(&v);
        expect_status("one over the ceiling", stage2_bytes_append(&v, 5),
            KOFUN_BYTES_CAPACITY_EXCEEDED, KOFUN_BYTES_CAPACITY_LIMIT + 1);
        expect_unchanged("one over the ceiling", &v,
            KOFUN_BYTES_CAPACITY_LIMIT, KOFUN_BYTES_CAPACITY_LIMIT);
        /* The byte is validated before the capacity, so a full carrier asked
         * to append a non-byte reports the byte. */
        expect_status("full carrier, invalid byte",
            stage2_bytes_append(&v, 256), KOFUN_BYTES_INVALID_BYTE, 256);
        expect_unchanged("full carrier, invalid byte", &v,
            KOFUN_BYTES_CAPACITY_LIMIT, KOFUN_BYTES_CAPACITY_LIMIT);
        expect_status("full carrier, negative byte",
            stage2_bytes_append(&v, -1), KOFUN_BYTES_INVALID_BYTE, -1);
        expect_unchanged("full carrier, negative byte", &v,
            KOFUN_BYTES_CAPACITY_LIMIT, KOFUN_BYTES_CAPACITY_LIMIT);
        kofun_bytes_release(&v);
    }

    /* --------------------------------------- append_range: order and detail
     *
     * The four range rules in the order they run, each proved by a call that
     * is also wrong in a later way — so a reordering changes the answer rather
     * than merely reordering equal answers.
     */
    {
        static BytesWitness range_source_before;
        static BytesWitness range_destination_before;
        KofunBytesValue src = KOFUN_BYTES_EMPTY;
        KofunBytesValue dst = KOFUN_BYTES_EMPTY;
        if (seeded("range source", &src, 8)) {
            remember_into(&range_source_before, &src);
            remember_into(&range_destination_before, &dst);
            expect_status("negative offset beats negative count",
                stage2_bytes_append_range(&dst, &src, -3, -9),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -3);
            expect_unchanged_from("negative-offset source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("negative-offset destination", &dst,
                &range_destination_before, 0, 0);
            expect_status("negative count",
                stage2_bytes_append_range(&dst, &src, 2, -9),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -9);
            expect_unchanged_from("negative-count source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("negative-count destination", &dst,
                &range_destination_before, 0, 0);
            expect_status("offset past length beats an oversized count",
                stage2_bytes_append_range(&dst, &src, 9, 100),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 9);
            expect_unchanged_from("past-length source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("past-length destination", &dst,
                &range_destination_before, 0, 0);
            expect_status("count past the end",
                stage2_bytes_append_range(&dst, &src, 6, 3),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 3);
            expect_unchanged_from("past-end source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("past-end destination", &dst,
                &range_destination_before, 0, 0);
            /*
             * The mathematical sum overflows int64_t; the refusal does not
             * compute it. `offset > length` refuses first and reports the
             * offset, so nothing evaluates INT64_MAX + INT64_MAX.
             */
            expect_status("offset and count that would overflow their sum",
                stage2_bytes_append_range(&dst, &src, INT64_MAX, INT64_MAX),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, INT64_MAX);
            expect_unchanged_from("overflow-offset source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("overflow-offset destination", &dst,
                &range_destination_before, 0, 0);
            /* At the end, the same sum overflows and the count is reported. */
            expect_status("count at the end that would overflow the sum",
                stage2_bytes_append_range(&dst, &src, 8, INT64_MAX),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, INT64_MAX);
            expect_unchanged_from("overflow-count source", &src,
                &range_source_before, 8, 8);
            expect_unchanged_from("overflow-count destination", &dst,
                &range_destination_before, 0, 0);

            /* Zero length at the end is the one empty range that succeeds. */
            expect_status("zero count at the end",
                stage2_bytes_append_range(&dst, &src, 8, 0), 0, 0);
            expect("zero count appended nothing", stage2_bytes_len(&dst), 0);
            expect_status("zero count at zero",
                stage2_bytes_append_range(&dst, &src, 0, 0), 0, 0);

            /* The maximal in-range request, and a real one. */
            expect_status("whole source",
                stage2_bytes_append_range(&dst, &src, 0, 8), 0, 0);
            expect("appended eight", stage2_bytes_len(&dst), 8);
            if (memcmp(dst.data, src.data, 8) != 0) {
                printf("FAIL: append_range copied the wrong bytes\n");
                ++failures;
            }
            expect_status("tail of the source",
                stage2_bytes_append_range(&dst, &src, 5, 3), 0, 0);
            expect("appended three more", stage2_bytes_len(&dst), 11);
            if (memcmp(dst.data + 8, src.data + 5, 3) != 0) {
                printf("FAIL: append_range copied the wrong tail\n");
                ++failures;
            }
            expect("source is untouched", stage2_bytes_len(&src), 8);
        }
        kofun_bytes_release(&dst);
        kofun_bytes_release(&src);
    }

    /*
     * Source range validation precedes destination capacity. A destination at
     * the ceiling and a source range that is also invalid reports the range:
     * the caller's first error is the one they are told about.
     */
    {
        static BytesWitness full_source_before;
        static BytesWitness full_destination_before;
        KofunBytesValue src = KOFUN_BYTES_EMPTY;
        KofunBytesValue dst = KOFUN_BYTES_EMPTY;
        if (seeded("full destination", &dst, KOFUN_BYTES_CAPACITY_LIMIT) &&
            seeded("small source", &src, 4)) {
            remember_into(&full_source_before, &src);
            remember_into(&full_destination_before, &dst);
            expect_status("bad source range, full destination",
                stage2_bytes_append_range(&dst, &src, -1, 2),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -1);
            expect_unchanged_from("bad-range full destination", &dst,
                &full_destination_before, KOFUN_BYTES_CAPACITY_LIMIT,
                KOFUN_BYTES_CAPACITY_LIMIT);
            expect_unchanged_from("bad-range source", &src,
                &full_source_before, 4, 4);
            expect_status("good source range, full destination",
                stage2_bytes_append_range(&dst, &src, 0, 4),
                KOFUN_BYTES_CAPACITY_EXCEEDED,
                KOFUN_BYTES_CAPACITY_LIMIT + 4);
            expect_unchanged_from("capacity full destination", &dst,
                &full_destination_before, KOFUN_BYTES_CAPACITY_LIMIT,
                KOFUN_BYTES_CAPACITY_LIMIT);
            expect_unchanged_from("capacity source", &src,
                &full_source_before, 4, 4);
        }
        kofun_bytes_release(&dst);
        kofun_bytes_release(&src);
    }

    /* ------------------------------------------------ append_self
     *
     * Both cases the criterion names: one that fits in the capacity already
     * held, and one that must reallocate first and then read the range out of
     * the new buffer. The second is where a helper that kept a pointer across
     * the growth reads freed storage, which is what the sanitizer build below
     * is for.
     */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("self pre-growth", &v, 4)) {
            expect_status("reserve headroom", stage2_bytes_reserve(&v, 16), 0, 0);
            expect_status("self append inside capacity",
                stage2_bytes_append_self(&v, 1, 3), 0, 0);
            expect("self length", stage2_bytes_len(&v), 7);
            expect("self did not reallocate", stage2_bytes_capacity(&v), 16);
            if (memcmp(v.data + 4, witness.bytes + 1, 3) != 0) {
                printf("FAIL: self append copied the wrong bytes\n");
                ++failures;
            }
        }
        kofun_bytes_release(&v);
    }
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("self reallocating", &v, 12)) {
            expect("exact capacity", stage2_bytes_capacity(&v), 12);
            expect_status("self append that must grow",
                stage2_bytes_append_self(&v, 0, 12), 0, 0);
            expect("self grew", stage2_bytes_capacity(&v), 32);
            expect("self length", stage2_bytes_len(&v), 24);
            if (memcmp(v.data, witness.bytes, 12) != 0 ||
                memcmp(v.data + 12, witness.bytes, 12) != 0) {
                printf("FAIL: self append across a growth lost bytes\n");
                ++failures;
            }
        }
        kofun_bytes_release(&v);
    }
    {
        /* The adjacent range: `offset + count == length`, the closest the
         * source and destination regions ever come. They still do not overlap,
         * because the bound one line above the copy is what keeps them apart. */
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("self adjacent", &v, 6)) {
            expect_status("self append of the tail",
                stage2_bytes_append_self(&v, 3, 3), 0, 0);
            expect("self adjacent length", stage2_bytes_len(&v), 9);
            if (memcmp(v.data + 6, witness.bytes + 3, 3) != 0) {
                printf("FAIL: an adjacent self append copied the wrong bytes\n");
                ++failures;
            }
        }
        kofun_bytes_release(&v);
    }
    {
        /* The same four range rules, on the self operation, against the old
         * length rather than the grown one. */
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("self refusals", &v, 6)) {
            expect_status("self negative offset",
                stage2_bytes_append_self(&v, -1, -1),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -1);
            expect_unchanged("self negative offset", &v, 6, 6);
            expect_status("self negative count",
                stage2_bytes_append_self(&v, 1, -4),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -4);
            expect_unchanged("self negative count", &v, 6, 6);
            expect_status("self offset past length",
                stage2_bytes_append_self(&v, 7, 0),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 7);
            expect_unchanged("self offset past length", &v, 6, 6);
            expect_status("self count past the end",
                stage2_bytes_append_self(&v, 4, 3),
                KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 3);
            expect_unchanged("self count past the end", &v, 6, 6);
            expect_status("self zero count at the end",
                stage2_bytes_append_self(&v, 6, 0), 0, 0);
            expect_unchanged("self zero count", &v, 6, 6);
        }
        kofun_bytes_release(&v);
    }
    {
        /* Over the ceiling through the self operation, reported as the
         * requested final length. */
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("self ceiling", &v, 40000)) {
            expect_status("self past the ceiling",
                stage2_bytes_append_self(&v, 0, 40000),
                KOFUN_BYTES_CAPACITY_EXCEEDED, 80000);
            expect_unchanged("self past the ceiling", &v, 40000, 40000);
        }
        kofun_bytes_release(&v);
    }
#else
    /*
     * The budget build spends its one allocation on the seed, so the growth
     * that follows is refused. Every field and every byte survives it: the
     * fresh block is taken before the old pointer is released, so a failure
     * has nothing to undo.
     */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        if (seeded("oom", &v, 8)) {
            expect_status("append under a spent budget",
                stage2_bytes_append(&v, 1),
                KOFUN_BYTES_ALLOCATION_FAILED, 16);
            expect_unchanged("append under a spent budget", &v, 8, 8);
            expect_status("reserve under a spent budget",
                stage2_bytes_reserve(&v, 64),
                KOFUN_BYTES_ALLOCATION_FAILED, 64);
            expect_unchanged("reserve under a spent budget", &v, 8, 8);
            expect_status("self append under a spent budget",
                stage2_bytes_append_self(&v, 0, 8),
                KOFUN_BYTES_ALLOCATION_FAILED, 16);
            expect_unchanged("self append under a spent budget", &v, 8, 8);
            /* A read needs no allocator, so it still answers -- and still
             * refuses, since the refusal allocates nothing either. */
            expect_byte("read under a spent budget",
                stage2_bytes_byte_at(&v, 0), 3);
            expect_read_refused("read past length under a spent budget",
                stage2_bytes_byte_at(&v, 8));
            expect_unchanged("read past length under a spent budget", &v, 8, 8);
            /* A file read takes its window before touching the carrier, so
             * a spent budget refuses it whole: R028, status 5, and every
             * field and byte as it was. The path need not exist for that --
             * it is never opened when there is no window -- but the harness
             * prepares one anyway so the refusal is the allocator's alone. */
            const char *dir = getenv("KOFUN_BYTES_MUTATION_READ_DIR");
            if (dir == NULL) {
                printf("FAIL: KOFUN_BYTES_MUTATION_READ_DIR is not set\n");
                ++failures;
            } else {
                char path[4096];
                snprintf(path, sizeof path, "%s/small.bin", dir);
                expect_status("read_file under a spent budget",
                    stage2_bytes_read_file(&v, path),
                    KOFUN_BYTES_ALLOCATION_FAILED,
                    KOFUN_BYTES_CAPACITY_LIMIT + 1);
                expect_refused("read_file under a spent budget");
                expect_unchanged("read_file under a spent budget", &v, 8, 8);
            }
        }
        kofun_bytes_release(&v);
    }
    {
        /* append_range is the only allocating operation with two carriers.
         * Give setup one allocation per carrier, then spend the budget before
         * the call. Both values must retain every field and every byte. */
        static BytesWitness source_before;
        static BytesWitness destination_before;
        KofunBytesValue source = KOFUN_BYTES_EMPTY;
        KofunBytesValue destination = KOFUN_BYTES_EMPTY;
        kofun_bytes_alloc_budget = 1;
        int source_seeded = seeded("range oom source", &source, 8);
        kofun_bytes_alloc_budget = 1;
        int destination_seeded = seeded(
            "range oom destination", &destination, 8);
        if (source_seeded && destination_seeded) {
            source.data[0] = 0x11u;
            source.data[3] = 0x22u;
            source.data[7] = 0x33u;
            destination.data[0] = 0xa1u;
            destination.data[3] = 0xb2u;
            destination.data[7] = 0xc3u;
            remember_into(&source_before, &source);
            remember_into(&destination_before, &destination);
            kofun_bytes_alloc_budget = 0;
#ifndef KOFUN_BYTES_PROVE_RANGE_ATTEMPT_OMISSION
            expect_status("append_range under a spent budget",
                attempt_append_range_under_oom(
                    &destination, &source, 0, 8),
                KOFUN_BYTES_ALLOCATION_FAILED, 16);
#endif
#ifdef KOFUN_BYTES_PROVE_RANGE_SOURCE_WITNESS
            /* Copy the peer's distinct bytes into the read-only input after
             * refusal. The source witness must name the cross-carrier write. */
            memcpy(source.data, destination_before.bytes, 8);
#endif
#ifdef KOFUN_BYTES_PROVE_RANGE_DESTINATION_WITNESS
            memcpy(destination.data, source_before.bytes, 8);
#endif
            expect_unchanged_from("append_range destination under OOM",
                &destination, &destination_before, 8, 8);
            expect_unchanged_from("append_range source under OOM",
                &source, &source_before, 8, 8);
        }
        kofun_bytes_release(&destination);
        kofun_bytes_release(&source);
    }
    expect("append_range OOM attempt count", append_range_oom_attempts, 1);
#endif

    if (failures != 0) return 1;
    printf("ok\n");
    return 0;
}
