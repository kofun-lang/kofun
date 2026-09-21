/*
 * #1322. The Text bridge's exact contract -- tag, detail, precedence, and
 * transactionality -- is private to the emitted C, the arrangement the
 * mutation family already has (#1321, #1559), so it is proved where it lives:
 * this driver is compiled against a prelude extracted from a program the
 * compiler just emitted, and measures the shipped bytes rather than a copy of
 * them kept in step by hand.
 *
 * What a source program sees of the bridge is narrower and proved by the
 * fixtures beside this file: `stage2_bytes_text` returns the Text or raises
 * one of four runtime diagnostics with an empty result, and
 * `stage2_bytes_assign_text` is a discarded statement. The status matrix
 * below is what those diagnostics are projected from.
 *
 * Details are absolute offsets into the carrier, so every content case is
 * written at a nonzero base: a check that reported offsets relative to the
 * requested range would pass at base zero and nowhere else.
 */
#include "prelude.h"
#include <stdio.h>
#include <string.h>

static int failures;

static void expect(const char *what, long long got, long long want) {
    if (got != want) {
        printf("FAIL: %s: got %lld, want %lld\n", what, got, want);
        ++failures;
    }
}

static void expect_status(const char *what, KofunBytesStatus s,
                          long long tag, long long detail) {
    if (s.tag != tag || s.detail != detail) {
        printf("FAIL: %s: got tag %lld detail %lld, want tag %lld detail %lld\n",
            what, (long long)s.tag, (long long)s.detail, tag, detail);
        ++failures;
    }
}

/* The source-facing half runs only under the ordinary allocator; the spent
 * budget build proves transactionality and nothing else. */
#ifndef KOFUN_BYTES_INJECT_ALLOC_BUDGET
static void expect_text(const char *what, const char *got, const char *want) {
    if (strcmp(got, want) != 0) {
        printf("FAIL: %s: got \"%s\", want \"%s\"\n", what, got, want);
        ++failures;
    }
}

static void expect_clean(const char *what) {
    if (kofun_failed) {
        printf("FAIL: %s: a succeeding conversion raised the runtime flag\n", what);
        ++failures;
        kofun_failed = false;
    }
}

static void expect_refused(const char *what) {
    if (!kofun_failed) {
        printf("FAIL: %s: a refused conversion raised no runtime flag\n", what);
        ++failures;
    }
    kofun_failed = false;
}
#endif

#ifndef KOFUN_BYTES_INJECT_ALLOC_BUDGET
/* A carrier holding `prefix` ASCII bytes and then `sequence`, so the
 * sequence's details are checked at an absolute base. */
static KofunBytesValue carrier_with(int64_t prefix, const unsigned char *sequence,
                                    int64_t width) {
    KofunBytesValue v = KOFUN_BYTES_EMPTY;
    for (int64_t index = 0; index < prefix; ++index) {
        expect_status("prefix append", stage2_bytes_append(&v, 'a'), 0, 0);
    }
    for (int64_t index = 0; index < width; ++index) {
        expect_status("sequence append", stage2_bytes_append(&v, sequence[index]), 0, 0);
    }
    return v;
}

/* One ill-formed or well-formed sequence at base 7, checked over the whole
 * carrier and over the sequence alone. `want_detail` is relative to the
 * sequence; -1 means well-formed. */
static void utf8_case(const char *what, const unsigned char *sequence,
                      int64_t width, long long want_detail) {
    enum { BASE = 7 };
    KofunBytesValue v = carrier_with(BASE, sequence, width);
    KofunBytesStatus whole = stage2_bytes_text_check(&v, 0, BASE + width);
    KofunBytesStatus alone = stage2_bytes_text_check(&v, BASE, width);
    if (want_detail < 0) {
        expect_status(what, whole, KOFUN_BYTES_SUCCEEDED, 0);
        expect_status(what, alone, KOFUN_BYTES_SUCCEEDED, 0);
    } else {
        expect_status(what, whole, KOFUN_BYTES_INVALID_UTF8, BASE + want_detail);
        expect_status(what, alone, KOFUN_BYTES_INVALID_UTF8, BASE + want_detail);
    }
    kofun_bytes_release(&v);
}
#endif

int main(void) {
#ifdef KOFUN_BYTES_INJECT_ALLOC_BUDGET
    /* ---------------------------------------- transactional on allocation
     * Built with a spent budget: the first assignment into an empty carrier
     * needs storage and cannot get it, and must leave the carrier exactly as
     * it found it; the same assignment into a carrier that already has the
     * capacity needs no allocation and succeeds. */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        expect_status("a spent budget refuses the first assignment with the growth target",
            stage2_bytes_assign_text(&v, "kofun"), KOFUN_BYTES_ALLOCATION_FAILED, 16);
        expect("a refused assignment leaves the length", (long long)v.length, 0);
        expect("a refused assignment leaves the capacity", (long long)v.capacity, 0);
        expect("a refused assignment leaves the storage", v.data == NULL, 1);
        kofun_bytes_release(&v);
    }
    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("PASS: a refused assignment leaves the carrier exactly as it found it\n");
    return 0;
#else
    /* ------------------------------------------------ range, the shared rule */
    {
        KofunBytesValue v = carrier_with(5, (const unsigned char *)"", 0);
        expect_status("negative offset reports the offset",
            stage2_bytes_text_check(&v, -1, 1), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -1);
        expect_status("negative count reports the count",
            stage2_bytes_text_check(&v, 0, -4), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -4);
        expect_status("negative offset wins over negative count",
            stage2_bytes_text_check(&v, -2, -3), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, -2);
        expect_status("offset past the length reports the offset",
            stage2_bytes_text_check(&v, 6, 0), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 6);
        expect_status("offset at the length with count zero is inside",
            stage2_bytes_text_check(&v, 5, 0), KOFUN_BYTES_SUCCEEDED, 0);
        expect_status("count past length - offset reports the count",
            stage2_bytes_text_check(&v, 2, 4), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 4);
        expect_status("count exactly length - offset is inside",
            stage2_bytes_text_check(&v, 2, 3), KOFUN_BYTES_SUCCEEDED, 0);
        /* The sum is never evaluated: this count would overflow it. */
        expect_status("a count that would overflow the sum reports the count",
            stage2_bytes_text_check(&v, 1, INT64_MAX), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, INT64_MAX);
        expect_status("range is checked before the Text limit",
            stage2_bytes_text_check(&v, 0, 300), KOFUN_BYTES_RANGE_OUT_OF_BOUNDS, 300);
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ the Text limit */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        for (int64_t index = 0; index < 300; ++index) {
            expect_status("limit carrier append", stage2_bytes_append(&v, 'x'), 0, 0);
        }
        expect_status("255 bytes is the largest Text",
            stage2_bytes_text_check(&v, 0, 255), KOFUN_BYTES_SUCCEEDED, 0);
        expect_status("256 bytes exceeds the Text limit, detail is the count",
            stage2_bytes_text_check(&v, 0, 256), KOFUN_BYTES_TEXT_LIMIT_EXCEEDED, 256);
        expect_status("the limit does not depend on the offset",
            stage2_bytes_text_check(&v, 40, 260), KOFUN_BYTES_TEXT_LIMIT_EXCEEDED, 260);
        /* A NUL and an ill-formed byte inside the range, and the limit is
         * still what the conversion says: bytes past 255 are never read. */
        expect_status("plant a NUL", stage2_bytes_byte_set(&v, 10, 0), 0, 0);
        expect_status("plant 0xFF", stage2_bytes_byte_set(&v, 20, 0xFF), 0, 0);
        expect_status("over-limit range with a NUL and an ill-formed byte reports the limit",
            stage2_bytes_text_check(&v, 0, 256), KOFUN_BYTES_TEXT_LIMIT_EXCEEDED, 256);
        expect_status("in-limit range reaches the earliest content failure",
            stage2_bytes_text_check(&v, 0, 255), KOFUN_BYTES_TEXT_CONTAINS_NUL, 10);
        expect_status("a range starting after the NUL reaches the ill-formed byte",
            stage2_bytes_text_check(&v, 11, 30), KOFUN_BYTES_INVALID_UTF8, 20);
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ NUL, absolute */
    {
        static const unsigned char nul_late[] = { 'k', 'o', 0, 'f' };
        KofunBytesValue v = carrier_with(3, nul_late, 4);
        expect_status("an embedded NUL names its absolute offset",
            stage2_bytes_text_check(&v, 0, 7), KOFUN_BYTES_TEXT_CONTAINS_NUL, 5);
        expect_status("the same NUL from a later base names the same offset",
            stage2_bytes_text_check(&v, 3, 4), KOFUN_BYTES_TEXT_CONTAINS_NUL, 5);
        expect_status("a range that stops before the NUL is Text",
            stage2_bytes_text_check(&v, 0, 5), KOFUN_BYTES_SUCCEEDED, 0);
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ earliest wins */
    {
        static const unsigned char nul_then_bad[] = { 'a', 0, 'b', 0xFF };
        static const unsigned char bad_then_nul[] = { 'a', 0xFF, 'b', 0 };
        KofunBytesValue first = carrier_with(2, nul_then_bad, 4);
        KofunBytesValue second = carrier_with(2, bad_then_nul, 4);
        expect_status("a NUL before an ill-formed byte wins",
            stage2_bytes_text_check(&first, 0, 6), KOFUN_BYTES_TEXT_CONTAINS_NUL, 3);
        expect_status("an ill-formed byte before a NUL wins",
            stage2_bytes_text_check(&second, 0, 6), KOFUN_BYTES_INVALID_UTF8, 3);
        kofun_bytes_release(&first);
        kofun_bytes_release(&second);
    }

    /* ------------------------------------------------ every UTF-8 family */
    {
        static const unsigned char two[] = { 0xC3, 0xA9 };
        static const unsigned char three[] = { 0xE5, 0x8F, 0xA4 };
        static const unsigned char four[] = { 0xF0, 0x9F, 0x8C, 0x8D };
        static const unsigned char edges[] = {
            0xC2, 0x80, 0xDF, 0xBF, 0xE0, 0xA0, 0x80, 0xED, 0x9F, 0xBF,
            0xEE, 0x80, 0x80, 0xEF, 0xBF, 0xBF, 0xF0, 0x90, 0x80, 0x80,
            0xF4, 0x8F, 0xBF, 0xBF
        };
        utf8_case("a two-byte scalar is Text", two, 2, -1);
        utf8_case("a three-byte scalar is Text", three, 3, -1);
        utf8_case("a four-byte scalar is Text", four, 4, -1);
        utf8_case("every window edge is Text", edges, sizeof edges, -1);

        static const unsigned char overlong2a[] = { 0xC0, 0x80 };
        static const unsigned char overlong2b[] = { 0xC1, 0xBF };
        static const unsigned char overlong3a[] = { 0xE0, 0x80, 0x80 };
        static const unsigned char overlong3b[] = { 0xE0, 0x9F, 0xBF };
        static const unsigned char overlong4a[] = { 0xF0, 0x80, 0x80, 0x80 };
        static const unsigned char overlong4b[] = { 0xF0, 0x8F, 0xBF, 0xBF };
        static const unsigned char surrogate_low[] = { 0xED, 0xA0, 0x80 };
        static const unsigned char surrogate_high[] = { 0xED, 0xBF, 0xBF };
        static const unsigned char above_max[] = { 0xF4, 0x90, 0x80, 0x80 };
        static const unsigned char lead_f5[] = { 0xF5, 0x80, 0x80, 0x80 };
        static const unsigned char lead_ff[] = { 0xFF };
        static const unsigned char stray[] = { 0x80 };
        static const unsigned char stray_late[] = { 'a', 'b', 0xBF };
        static const unsigned char truncated2[] = { 0xC3 };
        static const unsigned char truncated3[] = { 0xE2, 0x82 };
        static const unsigned char truncated4[] = { 0xF0, 0x9F, 0x8C };
        static const unsigned char bad2[] = { 0xC3, 'A' };
        static const unsigned char bad3[] = { 0xE2, 0x82, 'A' };
        static const unsigned char bad4[] = { 0xF0, 0x9F, 0x8C, 'A' };
        static const unsigned char bad3_second[] = { 0xE2, 'A', 0x82 };
        static const unsigned char after_valid[] = { 0xC3, 0xA9, 0xE2, 0x82 };
        /* Overlong, surrogate, and above-max forms name the lead byte. */
        utf8_case("overlong two-byte C0 names the lead", overlong2a, 2, 0);
        utf8_case("overlong two-byte C1 names the lead", overlong2b, 2, 0);
        utf8_case("overlong three-byte E0 80 names the lead", overlong3a, 3, 0);
        utf8_case("overlong three-byte E0 9F names the lead", overlong3b, 3, 0);
        utf8_case("overlong four-byte F0 80 names the lead", overlong4a, 4, 0);
        utf8_case("overlong four-byte F0 8F names the lead", overlong4b, 4, 0);
        utf8_case("a surrogate ED A0 names the lead", surrogate_low, 3, 0);
        utf8_case("a surrogate ED BF names the lead", surrogate_high, 3, 0);
        utf8_case("above U+10FFFF names the lead", above_max, 4, 0);
        /* An invalid lead names itself. */
        utf8_case("F5 is never a lead", lead_f5, 4, 0);
        utf8_case("FF is never a lead", lead_ff, 1, 0);
        utf8_case("a stray continuation names itself", stray, 1, 0);
        utf8_case("a late stray continuation names itself", stray_late, 3, 2);
        /* Truncation names the lead. */
        utf8_case("a truncated two-byte sequence names the lead", truncated2, 1, 0);
        utf8_case("a truncated three-byte sequence names the lead", truncated3, 2, 0);
        utf8_case("a truncated four-byte sequence names the lead", truncated4, 3, 0);
        /* A byte that is not a continuation names itself. */
        utf8_case("a bad second byte names the second byte", bad2, 2, 1);
        utf8_case("a bad third byte names the third byte", bad3, 3, 2);
        utf8_case("a bad fourth byte names the fourth byte", bad4, 4, 3);
        utf8_case("a bad second byte of three names the second byte", bad3_second, 3, 1);
        utf8_case("the failure after a valid scalar names its own lead", after_valid, 4, 2);
    }

    /* ------------------------------------------------ assign_text */
    {
        KofunBytesValue v = KOFUN_BYTES_EMPTY;
        expect_status("assign a Text", stage2_bytes_assign_text(&v, "kofun"), 0, 0);
        expect("assigned length is the byte width", (long long)v.length, 5);
        expect("assigned bytes are exact", memcmp(v.data, "kofun", 5), 0);
        uint64_t capacity = v.capacity;
        unsigned char *pointer = v.data;
        expect_status("assign an empty Text", stage2_bytes_assign_text(&v, ""), 0, 0);
        expect("an empty Text leaves length zero", (long long)v.length, 0);
        expect("an empty Text keeps the capacity", (long long)v.capacity, (long long)capacity);
        expect("an empty Text keeps the storage", v.data == pointer, 1);
        expect_status("assign a multibyte Text", stage2_bytes_assign_text(&v, "a\xC3\xA9\xE5\x8F\xA4"), 0, 0);
        expect("multibyte width is counted in bytes", (long long)v.length, 6);
        expect("no terminator is written into the carrier", (long long)v.length, 6);
        expect_status("the assigned bytes are Text again",
            stage2_bytes_text_check(&v, 0, 6), KOFUN_BYTES_SUCCEEDED, 0);
        expect_status("a Text that fits the capacity does not reallocate",
            stage2_bytes_assign_text(&v, "ab"), 0, 0);
        expect("no reallocation for a fitting Text", v.data == pointer, 1);
        kofun_bytes_release(&v);
    }

    /* ------------------------------------------------ the source-facing half */
    {
        KofunBytesValue v = carrier_with(0, (const unsigned char *)"kofun", 5);
        expect_text("text returns the range", stage2_bytes_text(&v, 1, 3), "ofu");
        expect_clean("a Text conversion");
        expect_text("text returns an empty range", stage2_bytes_text(&v, 5, 0), "");
        expect_clean("an empty conversion");
        expect_text("an out-of-range conversion is empty", stage2_bytes_text(&v, 3, 9), "");
        expect_refused("an out-of-range conversion");
        expect_status("plant a NUL", stage2_bytes_byte_set(&v, 2, 0), 0, 0);
        expect_text("a NUL conversion is empty", stage2_bytes_text(&v, 0, 5), "");
        expect_refused("a NUL conversion");
        expect_status("plant 0xFF", stage2_bytes_byte_set(&v, 2, 0xFF), 0, 0);
        expect_text("an ill-formed conversion is empty", stage2_bytes_text(&v, 0, 5), "");
        expect_refused("an ill-formed conversion");
        kofun_bytes_release(&v);
    }

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("PASS: the Text bridge's range, limit, NUL, UTF-8, precedence, and assignment contract holds in the emitted C\n");
    return 0;
#endif
}
