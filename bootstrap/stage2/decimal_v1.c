/*
 * Compiler-native Decimal, slice 2 of #710.
 *
 * The significand is a binary big integer in base 2^32 rather than BCD or a
 * fixed `i128`, which is the choice `docs/DECIMAL.md` records and its reasons:
 * BCD wastes space and gets no help from the CPU, and a fixed width would make
 * ordinary exact expressions fail at an arbitrary magnitude boundary.
 *
 * Slice 2 starts with four big-integer primitives: multiply by a small factor,
 * add a small term, divide by a small divisor, and compare. Construction is
 * `((0 * 10 + d) * 10 + d) ...`; canonicalization is repeated division by
 * ten. Slice 4 extends those primitives below with exact signed arithmetic and
 * arbitrary-width division.
 */

#include "decimal_v1.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIMB_BITS 32
#define LIMB_BASE (1ULL << LIMB_BITS)

/*
 * The small-value path. Frozen decision 1 allows keeping small significands
 * inline and promoting on overflow, but only as an optimization that cannot be
 * observed. Here "inline" means the magnitude fits two limbs, so the whole
 * significand is one `uint64_t`; nothing about the observable value changes at
 * the boundary, and `inline_storage` exists so a gate can prove that.
 */
#define INLINE_LIMBS 2u

const char *kofun_decimal_status_code(KofunDecimalStatus status) {
    switch (status) {
        case KOFUN_DECIMAL_OK: return "";
        case KOFUN_DECIMAL_DIGIT_LIMIT: return "D001";
        case KOFUN_DECIMAL_SCALE_LIMIT: return "D002";
        case KOFUN_DECIMAL_MALFORMED: return "D003";
        case KOFUN_DECIMAL_MEMORY: return "D004";
        case KOFUN_DECIMAL_DIVISION_ZERO: return "D005";
        case KOFUN_DECIMAL_ROUNDING_MODE: return "D006";
        case KOFUN_DECIMAL_FORMAT_INEXACT: return "D007";
    }
    return "";
}

const char *kofun_decimal_status_message(KofunDecimalStatus status) {
    switch (status) {
        case KOFUN_DECIMAL_OK:
            return "";
        case KOFUN_DECIMAL_DIGIT_LIMIT:
            return "error[D001]: Decimal significand exceeds the profile's "
                   "digit limit";
        case KOFUN_DECIMAL_SCALE_LIMIT:
            return "error[D002]: Decimal scale is outside the profile's range";
        case KOFUN_DECIMAL_MALFORMED:
            return "error[D003]: malformed Decimal literal";
        case KOFUN_DECIMAL_MEMORY:
            return "error[D004]: Decimal allocation refused";
        case KOFUN_DECIMAL_DIVISION_ZERO:
            return "error[D005]: rounded Decimal division by zero";
        case KOFUN_DECIMAL_ROUNDING_MODE:
            return "error[D006]: invalid Decimal rounding mode";
        case KOFUN_DECIMAL_FORMAT_INEXACT:
            return "error[D007]: Decimal format scale would discard digits";
    }
    return "";
}

unsigned kofun_decimal_profile_version(void) {
    return KOFUN_DECIMAL_PROFILE_VERSION;
}

void kofun_decimal_init(KofunDecimal *value) {
    if (value == NULL) return;
    value->sign = 0;
    value->scale = 0;
    value->limbs = NULL;
    value->limb_count = 0;
    value->inline_storage = true;
}

void kofun_decimal_free(KofunDecimal *value) {
    if (value == NULL) return;
    free(value->limbs);
    kofun_decimal_init(value);
}

/* --- magnitude primitives ------------------------------------------------ */

typedef struct {
    uint32_t *limbs;
    size_t count;
    size_t capacity;
} Magnitude;

static void magnitude_init(Magnitude *m) {
    m->limbs = NULL;
    m->count = 0;
    m->capacity = 0;
}

static void magnitude_free(Magnitude *m) {
    free(m->limbs);
    magnitude_init(m);
}

static bool magnitude_reserve(Magnitude *m, size_t wanted) {
    if (wanted <= m->capacity) return true;
    size_t capacity = m->capacity == 0 ? 8 : m->capacity;
    while (capacity < wanted) {
        if (capacity > (size_t)-1 / 2) return false;
        capacity *= 2;
    }
    uint32_t *grown = realloc(m->limbs, capacity * sizeof(*grown));
    if (grown == NULL) return false;
    m->limbs = grown;
    m->capacity = capacity;
    return true;
}

static void magnitude_trim(Magnitude *m) {
    while (m->count > 0 && m->limbs[m->count - 1] == 0) --m->count;
}

/* m = m * factor + addend, both small. */
static bool magnitude_mul_add_small(
    Magnitude *m,
    uint32_t factor,
    uint32_t addend
) {
    uint64_t carry = addend;
    for (size_t index = 0; index < m->count; ++index) {
        uint64_t product = (uint64_t)m->limbs[index] * factor + carry;
        m->limbs[index] = (uint32_t)(product & 0xFFFFFFFFu);
        carry = product >> LIMB_BITS;
    }
    while (carry != 0) {
        if (!magnitude_reserve(m, m->count + 1)) return false;
        m->limbs[m->count++] = (uint32_t)(carry & 0xFFFFFFFFu);
        carry >>= LIMB_BITS;
    }
    return true;
}

/* m /= divisor, returning the remainder. `divisor` must be non-zero. */
static uint32_t magnitude_divmod_small(Magnitude *m, uint32_t divisor) {
    uint64_t remainder = 0;
    for (size_t index = m->count; index-- > 0;) {
        uint64_t current = (remainder << LIMB_BITS) | m->limbs[index];
        m->limbs[index] = (uint32_t)(current / divisor);
        remainder = current % divisor;
    }
    magnitude_trim(m);
    return (uint32_t)remainder;
}

/* Remainder of m / divisor without modifying m. */
static uint32_t magnitude_mod_small(const Magnitude *m, uint32_t divisor) {
    uint64_t remainder = 0;
    for (size_t index = m->count; index-- > 0;) {
        remainder = ((remainder << LIMB_BITS) | m->limbs[index]) % divisor;
    }
    return (uint32_t)remainder;
}

static bool magnitude_is_zero(const Magnitude *m) {
    return m->count == 0;
}

static int magnitude_compare(const Magnitude *a, const Magnitude *b) {
    if (a->count != b->count) return a->count < b->count ? -1 : 1;
    for (size_t index = a->count; index-- > 0;) {
        if (a->limbs[index] != b->limbs[index]) {
            return a->limbs[index] < b->limbs[index] ? -1 : 1;
        }
    }
    return 0;
}

/* --- construction -------------------------------------------------------- */

static bool ascii_digit(char symbol) {
    return symbol >= '0' && symbol <= '9';
}

/*
 * Split a literal into its digit sequence and its decimal exponent, without
 * building any number. `digits` receives every significant digit in order and
 * `exponent` the power of ten the digit string must be multiplied by, so the
 * value is `digits * 10^exponent` exactly.
 *
 * Underscores are dropped here rather than rejected: the lexer has already
 * refused any that sit outside a position between two digits (`E2S98`), so
 * anything reaching this function is well formed.
 */
static KofunDecimalStatus split_literal(
    const char *text,
    size_t length,
    char *digits,
    size_t digits_capacity,
    size_t *digit_count,
    long *exponent
) {
    size_t written = 0;
    long fraction_digits = 0;
    long explicit_exponent = 0;
    bool seen_digit = false;
    bool seen_point = false;
    size_t cursor = 0;

    for (; cursor < length; ++cursor) {
        char symbol = text[cursor];
        if (symbol == '_') continue;
        if (symbol == '.') {
            if (seen_point) return KOFUN_DECIMAL_MALFORMED;
            seen_point = true;
            continue;
        }
        if (symbol == 'e' || symbol == 'E') break;
        if (!ascii_digit(symbol)) return KOFUN_DECIMAL_MALFORMED;
        seen_digit = true;
        if (seen_point) ++fraction_digits;
        /* Leading zeros contribute nothing and must not consume the budget. */
        if (written == 0 && symbol == '0' && !seen_point) continue;
        if (written >= digits_capacity) return KOFUN_DECIMAL_DIGIT_LIMIT;
        digits[written++] = symbol;
    }
    if (!seen_digit) return KOFUN_DECIMAL_MALFORMED;

    if (cursor < length && (text[cursor] == 'e' || text[cursor] == 'E')) {
        ++cursor;
        int exponent_sign = 1;
        if (cursor < length && (text[cursor] == '+' || text[cursor] == '-')) {
            if (text[cursor] == '-') exponent_sign = -1;
            ++cursor;
        }
        bool seen_exponent_digit = false;
        for (; cursor < length; ++cursor) {
            if (text[cursor] == '_') continue;
            if (!ascii_digit(text[cursor])) return KOFUN_DECIMAL_MALFORMED;
            seen_exponent_digit = true;
            /* Clamp the accumulator, not the value: anything past the scale
             * limit is refused below, and this only keeps the counter from
             * overflowing on absurd input. */
            if (explicit_exponent < 1000000L) {
                explicit_exponent = explicit_exponent * 10 +
                    (text[cursor] - '0');
            }
        }
        if (!seen_exponent_digit) return KOFUN_DECIMAL_MALFORMED;
        explicit_exponent *= exponent_sign;
    }

    *digit_count = written;
    *exponent = explicit_exponent - fraction_digits;
    return KOFUN_DECIMAL_OK;
}

/*
 * Move every factor of ten out of the magnitude and into the scale, which is
 * what makes the form canonical: `1.0`, `1.00`, `0.1e1` and `1` all arrive
 * here as different `(magnitude, scale)` pairs and leave as the same one.
 */
static void canonicalize(Magnitude *m, long *scale) {
    if (magnitude_is_zero(m)) {
        *scale = 0;
        return;
    }
    while (magnitude_mod_small(m, 10) == 0) {
        (void)magnitude_divmod_small(m, 10);
        --*scale;
        if (magnitude_is_zero(m)) {
            *scale = 0;
            return;
        }
    }
}

static KofunDecimalStatus build(
    const char *text,
    size_t length,
    Magnitude *magnitude,
    long *scale
) {
    char *digits = malloc(KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS);
    if (digits == NULL) return KOFUN_DECIMAL_MEMORY;
    size_t digit_count = 0;
    long exponent = 0;
    KofunDecimalStatus status = split_literal(
        text,
        length,
        digits,
        KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS,
        &digit_count,
        &exponent
    );
    if (status != KOFUN_DECIMAL_OK) {
        free(digits);
        return status;
    }

    magnitude_init(magnitude);
    for (size_t index = 0; index < digit_count; ++index) {
        if (!magnitude_mul_add_small(
                magnitude,
                10u,
                (uint32_t)(digits[index] - '0'))) {
            free(digits);
            magnitude_free(magnitude);
            return KOFUN_DECIMAL_MEMORY;
        }
    }
    free(digits);
    magnitude_trim(magnitude);

    /* The stored scale is the negated exponent: value = significand * 10^-scale. */
    *scale = -exponent;
    canonicalize(magnitude, scale);

    if (*scale > KOFUN_DECIMAL_MAX_SCALE || *scale < KOFUN_DECIMAL_MIN_SCALE) {
        magnitude_free(magnitude);
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    return KOFUN_DECIMAL_OK;
}

KofunDecimalStatus kofun_decimal_from_literal(
    const char *text,
    size_t length,
    KofunDecimal *out
) {
    if (text == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;
    kofun_decimal_init(out);

    Magnitude magnitude;
    long scale = 0;
    KofunDecimalStatus status = build(text, length, &magnitude, &scale);
    if (status != KOFUN_DECIMAL_OK) return status;

    out->limbs = magnitude.limbs;
    out->limb_count = magnitude.count;
    out->scale = (int32_t)scale;
    out->sign = magnitude.count == 0 ? 0 : 1;
    out->inline_storage = magnitude.count <= INLINE_LIMBS;
    if (out->sign == 0) {
        /* One representation of zero: no limbs, scale zero. */
        free(out->limbs);
        out->limbs = NULL;
        out->limb_count = 0;
        out->scale = 0;
        out->inline_storage = true;
    }
    return KOFUN_DECIMAL_OK;
}

/* --- observation --------------------------------------------------------- */

bool kofun_decimal_equal(const KofunDecimal *left, const KofunDecimal *right) {
    if (left == NULL || right == NULL) return false;
    if (left->sign != right->sign) return false;
    if (left->scale != right->scale) return false;
    if (left->limb_count != right->limb_count) return false;
    /* Zero has no limbs, and `memcmp` on a null pointer is undefined even
     * for length zero; UBSan reports it once Fixed's gate compares zeros. */
    if (left->limb_count == 0) return true;
    return memcmp(
        left->limbs,
        right->limbs,
        left->limb_count * sizeof(*left->limbs)
    ) == 0;
}

/*
 * Compare by value. Two canonical values with different scales may still be
 * ordered without arithmetic: scale up the one with the smaller scale by
 * repeated multiplication, on copies, and compare magnitudes.
 */
int kofun_decimal_compare(const KofunDecimal *left, const KofunDecimal *right) {
    if (left->sign != right->sign) return left->sign < right->sign ? -1 : 1;
    if (left->sign == 0) return 0;

    Magnitude a;
    Magnitude b;
    magnitude_init(&a);
    magnitude_init(&b);
    if (!magnitude_reserve(&a, left->limb_count == 0 ? 1 : left->limb_count) ||
        !magnitude_reserve(&b, right->limb_count == 0 ? 1 : right->limb_count)) {
        magnitude_free(&a);
        magnitude_free(&b);
        return 0;
    }
    memcpy(a.limbs, left->limbs, left->limb_count * sizeof(*a.limbs));
    a.count = left->limb_count;
    memcpy(b.limbs, right->limbs, right->limb_count * sizeof(*b.limbs));
    b.count = right->limb_count;

    /* A larger scale means more negative powers of ten, so the other side is
     * the one that must grow. */
    long difference = (long)left->scale - (long)right->scale;
    Magnitude *grow = difference > 0 ? &b : &a;
    long steps = difference > 0 ? difference : -difference;
    for (long step = 0; step < steps; ++step) {
        if (!magnitude_mul_add_small(grow, 10u, 0u)) {
            magnitude_free(&a);
            magnitude_free(&b);
            return 0;
        }
    }

    int order = magnitude_compare(&a, &b);
    magnitude_free(&a);
    magnitude_free(&b);
    return left->sign < 0 ? -order : order;
}

static char *magnitude_to_text(const KofunDecimal *value, bool signed_text) {
    if (value->sign == 0) {
        char *zero = malloc(2);
        if (zero == NULL) return NULL;
        zero[0] = '0';
        zero[1] = '\0';
        return zero;
    }

    Magnitude work;
    magnitude_init(&work);
    if (!magnitude_reserve(&work, value->limb_count)) return NULL;
    memcpy(work.limbs, value->limbs, value->limb_count * sizeof(*work.limbs));
    work.count = value->limb_count;

    /* Ten decimal digits per 32-bit limb is a safe upper bound. */
    size_t capacity = value->limb_count * 10 + 4;
    char *reversed = malloc(capacity);
    if (reversed == NULL) {
        magnitude_free(&work);
        return NULL;
    }
    size_t written = 0;
    while (!magnitude_is_zero(&work)) {
        uint32_t digit = magnitude_divmod_small(&work, 10u);
        reversed[written++] = (char)('0' + digit);
    }
    magnitude_free(&work);

    size_t prefix = (signed_text && value->sign < 0) ? 1u : 0u;
    char *text = malloc(written + prefix + 1);
    if (text == NULL) {
        free(reversed);
        return NULL;
    }
    if (prefix) text[0] = '-';
    for (size_t index = 0; index < written; ++index) {
        text[prefix + index] = reversed[written - 1 - index];
    }
    text[prefix + written] = '\0';
    free(reversed);
    return text;
}

char *kofun_decimal_significand_text(const KofunDecimal *value) {
    if (value == NULL) return NULL;
    return magnitude_to_text(value, true);
}

char *kofun_decimal_to_canonical_text(const KofunDecimal *value) {
    if (value == NULL) return NULL;
    char *significand = magnitude_to_text(value, true);
    if (significand == NULL) return NULL;
    /* `<significand>e<exponent>`, exponent being the negated scale, so the
     * rendering is the value and never a rounded decimal expansion. */
    size_t capacity = strlen(significand) + 16;
    char *text = malloc(capacity);
    if (text == NULL) {
        free(significand);
        return NULL;
    }
    long exponent = -(long)value->scale;
    int written = snprintf(text, capacity, "%se%ld", significand, exponent);
    free(significand);
    if (written < 0 || (size_t)written >= capacity) {
        free(text);
        return NULL;
    }
    return text;
}

/* --- binary64 ------------------------------------------------------------ */

/*
 * Correctly rounded binary64, computed from the same exact significand rather
 * than through `strtod`. The host's conversion is locale-sensitive and is not
 * guaranteed identical across backends, and #710 requires every backend to
 * observe the same value.
 *
 * The value is `magnitude * 10^exponent`. Both sides are scaled into integers
 * — numerator and denominator — and a long division produces enough bits to
 * round to nearest, ties to even.
 */
KofunDecimalStatus kofun_float_from_literal(
    const char *text,
    size_t length,
    double *out
) {
    if (text == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;

    Magnitude magnitude;
    long scale = 0;
    KofunDecimalStatus status = build(text, length, &magnitude, &scale);
    if (status != KOFUN_DECIMAL_OK) return status;

    if (magnitude_is_zero(&magnitude)) {
        magnitude_free(&magnitude);
        *out = 0.0;
        return KOFUN_DECIMAL_OK;
    }

    /*
     * Reduce to `numerator / denominator` with both exact integers:
     * value = magnitude * 10^-scale.
     */
    Magnitude numerator;
    Magnitude denominator;
    magnitude_init(&numerator);
    magnitude_init(&denominator);
    if (!magnitude_reserve(&numerator, magnitude.count) ||
        !magnitude_reserve(&denominator, 1)) {
        magnitude_free(&magnitude);
        magnitude_free(&numerator);
        magnitude_free(&denominator);
        return KOFUN_DECIMAL_MEMORY;
    }
    memcpy(
        numerator.limbs,
        magnitude.limbs,
        magnitude.count * sizeof(*numerator.limbs)
    );
    numerator.count = magnitude.count;
    denominator.limbs[0] = 1u;
    denominator.count = 1;
    magnitude_free(&magnitude);

    for (long step = 0; step < scale; ++step) {
        if (!magnitude_mul_add_small(&denominator, 10u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            return KOFUN_DECIMAL_MEMORY;
        }
    }
    for (long step = 0; step > scale; --step) {
        if (!magnitude_mul_add_small(&numerator, 10u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            return KOFUN_DECIMAL_MEMORY;
        }
    }

    /*
     * Long division producing 54 significant bits plus a sticky flag: 53 for
     * the mantissa, one to round on, and stickiness to break ties correctly.
     */
    int exponent = 0;
    /* Align so the quotient's leading bit is known: scale the numerator up
     * until it is at least the denominator, and the denominator up while it
     * exceeds the numerator by more than a factor of two. */
    while (magnitude_compare(&numerator, &denominator) < 0) {
        if (!magnitude_mul_add_small(&numerator, 2u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            return KOFUN_DECIMAL_MEMORY;
        }
        --exponent;
    }
    for (;;) {
        Magnitude twice;
        magnitude_init(&twice);
        if (!magnitude_reserve(&twice, denominator.count + 1)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            magnitude_free(&twice);
            return KOFUN_DECIMAL_MEMORY;
        }
        memcpy(
            twice.limbs,
            denominator.limbs,
            denominator.count * sizeof(*twice.limbs)
        );
        twice.count = denominator.count;
        if (!magnitude_mul_add_small(&twice, 2u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            magnitude_free(&twice);
            return KOFUN_DECIMAL_MEMORY;
        }
        bool needs_shift = magnitude_compare(&numerator, &twice) >= 0;
        magnitude_free(&twice);
        if (!needs_shift) break;
        if (!magnitude_mul_add_small(&denominator, 2u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            return KOFUN_DECIMAL_MEMORY;
        }
        ++exponent;
    }

    /*
     * numerator/denominator is now in [1, 2), and the value is that ratio
     * times 2^exponent.
     *
     * How many bits to extract is not a constant, and getting it wrong is how
     * subnormals go bad. A normal result has 53 significand bits wherever it
     * sits, so 54 bits — 53 plus one to round on — is right. A **subnormal**
     * result instead has a fixed ulp of 2^-1074 and *fewer* significand bits
     * the smaller it is, so extracting 54 and scaling down afterwards rounds
     * twice: once to 53 bits, once again on the way into the subnormal range.
     * That double rounding was measured against `strtod` on 3 of 3013 random
     * cases, all below 2^-1022.
     *
     * So the ulp is chosen first and the extraction is sized to it.
     */
    bool subnormal = exponent < -1022;
    int keep_bits = 54;
    if (subnormal) {
        /* Bits available above a fixed ulp of 2^-1074, plus one to round on. */
        keep_bits = (exponent + 1074) + 2;
    }
    if (keep_bits < 1) {
        /* Below half the smallest subnormal. */
        magnitude_free(&numerator);
        magnitude_free(&denominator);
        *out = 0.0;
        return KOFUN_DECIMAL_OK;
    }

    uint64_t mantissa = 0;
    bool sticky = false;
    for (int bit = 0; bit < keep_bits; ++bit) {
        mantissa <<= 1;
        if (magnitude_compare(&numerator, &denominator) >= 0) {
            mantissa |= 1u;
            /* numerator -= denominator, borrow-propagating subtract. */
            int64_t borrow = 0;
            for (size_t index = 0; index < numerator.count; ++index) {
                int64_t limb = (int64_t)numerator.limbs[index] - borrow -
                    (index < denominator.count
                         ? (int64_t)denominator.limbs[index]
                         : 0);
                if (limb < 0) {
                    limb += (int64_t)LIMB_BASE;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                numerator.limbs[index] = (uint32_t)limb;
            }
            magnitude_trim(&numerator);
        }
        if (!magnitude_mul_add_small(&numerator, 2u, 0u)) {
            magnitude_free(&numerator);
            magnitude_free(&denominator);
            return KOFUN_DECIMAL_MEMORY;
        }
    }
    sticky = !magnitude_is_zero(&numerator);
    magnitude_free(&numerator);
    magnitude_free(&denominator);

    /*
     * Round to nearest, ties to even, on the last extracted bit.
     *
     * The loop leaves `floor(ratio * 2^(keep_bits-1))`, so shifting the guard
     * bit off leaves `floor(ratio * 2^(keep_bits-2))` and the value is
     * `mantissa * 2^shift` for the shift below. For the normal case that is
     * `exponent - 52`; using 53 there halves every result, which is exactly
     * what it did before this was measured.
     */
    int shift = subnormal ? -1074 : exponent - 52;
    uint64_t guard = mantissa & 1u;
    mantissa >>= 1;
    if (guard && (sticky || (mantissa & 1u))) {
        ++mantissa;
        /*
         * Carrying out of 53 bits renormalizes. A subnormal that carries into
         * bit 52 has become the smallest normal, and `mantissa * 2^-1074` is
         * already exactly that, so only the normal case adjusts.
         */
        if (!subnormal && mantissa == (1ULL << 53)) {
            mantissa >>= 1;
            ++shift;
        }
    }

    /*
     * Compose without touching the host's decimal parser. Every intermediate
     * is `mantissa * 2^-k` with `mantissa < 2^53`, and the final value is at
     * least the smallest subnormal, so each halving is exact and no rounding
     * happens here.
     */
    double result = (double)mantissa;
    while (shift > 0) {
        result *= 2.0;
        --shift;
    }
    while (shift < 0) {
        result /= 2.0;
        ++shift;
    }
    *out = result;
    return KOFUN_DECIMAL_OK;
}

/* --- exact arithmetic (slice 4 of #710, issue #723) ----------------------- */

static bool magnitude_copy_from(Magnitude *out, const uint32_t *limbs,
                                size_t count) {
    magnitude_init(out);
    if (count == 0) return true;
    if (!magnitude_reserve(out, count)) return false;
    memcpy(out->limbs, limbs, count * sizeof(*out->limbs));
    out->count = count;
    magnitude_trim(out);
    return true;
}

/* sum = a + b. */
static bool magnitude_add(const Magnitude *a, const Magnitude *b,
                          Magnitude *sum) {
    size_t wide = a->count > b->count ? a->count : b->count;
    magnitude_init(sum);
    if (!magnitude_reserve(sum, wide + 1)) return false;
    uint64_t carry = 0;
    for (size_t index = 0; index < wide; ++index) {
        uint64_t total = carry;
        if (index < a->count) total += a->limbs[index];
        if (index < b->count) total += b->limbs[index];
        sum->limbs[index] = (uint32_t)(total & 0xFFFFFFFFu);
        carry = total >> LIMB_BITS;
    }
    sum->limbs[wide] = (uint32_t)carry;
    sum->count = wide + 1;
    magnitude_trim(sum);
    return true;
}

/* difference = a - b, which requires a >= b. */
static bool magnitude_subtract(const Magnitude *a, const Magnitude *b,
                               Magnitude *difference) {
    magnitude_init(difference);
    if (!magnitude_reserve(difference, a->count == 0 ? 1 : a->count)) {
        return false;
    }
    int64_t borrow = 0;
    for (size_t index = 0; index < a->count; ++index) {
        int64_t total = (int64_t)a->limbs[index] - borrow;
        if (index < b->count) total -= (int64_t)b->limbs[index];
        if (total < 0) {
            total += (int64_t)1 << LIMB_BITS;
            borrow = 1;
        } else {
            borrow = 0;
        }
        difference->limbs[index] = (uint32_t)total;
    }
    difference->count = a->count;
    magnitude_trim(difference);
    return true;
}

/* product = a * b, schoolbook. Exactness needs every partial product kept. */
static bool magnitude_multiply(const Magnitude *a, const Magnitude *b,
                               Magnitude *product) {
    magnitude_init(product);
    if (a->count == 0 || b->count == 0) return true;
    size_t wide = a->count + b->count;
    if (!magnitude_reserve(product, wide)) return false;
    memset(product->limbs, 0, wide * sizeof(*product->limbs));
    product->count = wide;
    for (size_t i = 0; i < a->count; ++i) {
        uint64_t carry = 0;
        for (size_t j = 0; j < b->count; ++j) {
            uint64_t total = (uint64_t)a->limbs[i] * b->limbs[j] +
                             product->limbs[i + j] + carry;
            product->limbs[i + j] = (uint32_t)(total & 0xFFFFFFFFu);
            carry = total >> LIMB_BITS;
        }
        size_t index = i + b->count;
        while (carry != 0) {
            uint64_t total = product->limbs[index] + carry;
            product->limbs[index] = (uint32_t)(total & 0xFFFFFFFFu);
            carry = total >> LIMB_BITS;
            ++index;
        }
    }
    magnitude_trim(product);
    return true;
}

/* m *= 10^power, exactly. */
static bool magnitude_scale_pow10(Magnitude *m, long power) {
    if (magnitude_is_zero(m)) return true;
    while (power >= 9) {
        if (!magnitude_mul_add_small(m, 1000000000u, 0u)) return false;
        power -= 9;
    }
    while (power > 0) {
        if (!magnitude_mul_add_small(m, 10u, 0u)) return false;
        --power;
    }
    return true;
}

/* m *= small^power, exactly. Used for the 2s and 5s an exact quotient needs. */
static bool magnitude_scale_pow_small(Magnitude *m, uint32_t base, long power) {
    while (power > 0) {
        if (!magnitude_mul_add_small(m, base, 0u)) return false;
        --power;
    }
    return true;
}

/*
 * quotient, remainder = numerator / divisor, for a divisor of any width.
 *
 * Knuth's algorithm D. The single-limb case is split out because the general
 * path needs a two-limb estimate and so cannot run with a one-limb divisor.
 *
 * This exists for one question — does the divisor's non-2-non-5 residue divide
 * the dividend — but that question is exactly divisibility, so an approximate
 * answer would be a wrong answer rather than a coarse one.
 */
/*
 * On failure both `quotient` and `remainder` are released and empty. Before
 * #1661 a refused remainder allocation returned with the quotient still
 * owned, and every caller freed only its own operands, so each such refusal
 * leaked one block.
 */
static bool magnitude_divmod(const Magnitude *numerator,
                             const Magnitude *divisor,
                             Magnitude *quotient,
                             Magnitude *remainder) {
    magnitude_init(quotient);
    magnitude_init(remainder);
    if (magnitude_compare(numerator, divisor) < 0) {
        return magnitude_copy_from(remainder, numerator->limbs,
                                   numerator->count);
    }
    if (divisor->count == 1) {
        if (!magnitude_copy_from(quotient, numerator->limbs,
                                 numerator->count)) {
            return false;
        }
        uint32_t rest = magnitude_divmod_small(quotient, divisor->limbs[0]);
        if (rest != 0) {
            if (!magnitude_reserve(remainder, 1)) {
                magnitude_free(quotient);
                return false;
            }
            remainder->limbs[0] = rest;
            remainder->count = 1;
        }
        return true;
    }

    /* Normalize so the divisor's top limb has its high bit set. */
    unsigned shift = 0;
    uint32_t top = divisor->limbs[divisor->count - 1];
    while ((top & 0x80000000u) == 0) {
        top <<= 1;
        ++shift;
    }
    size_t n = divisor->count;
    size_t m = numerator->count - n;

    Magnitude u;
    Magnitude v;
    magnitude_init(&u);
    magnitude_init(&v);
    if (!magnitude_reserve(&u, numerator->count + 1) ||
        !magnitude_reserve(&v, n)) {
        magnitude_free(&u);
        magnitude_free(&v);
        return false;
    }
    for (size_t index = 0; index < n; ++index) {
        uint32_t low = divisor->limbs[index] << shift;
        uint32_t high = shift == 0 || index == 0
            ? 0u
            : (uint32_t)((uint64_t)divisor->limbs[index - 1] >>
                         (LIMB_BITS - shift));
        v.limbs[index] = low | high;
    }
    v.count = n;
    for (size_t index = 0; index < numerator->count; ++index) {
        uint32_t low = numerator->limbs[index] << shift;
        uint32_t high = shift == 0 || index == 0
            ? 0u
            : (uint32_t)((uint64_t)numerator->limbs[index - 1] >>
                         (LIMB_BITS - shift));
        u.limbs[index] = low | high;
    }
    u.limbs[numerator->count] = shift == 0
        ? 0u
        : (uint32_t)((uint64_t)numerator->limbs[numerator->count - 1] >>
                     (LIMB_BITS - shift));
    u.count = numerator->count + 1;

    if (!magnitude_reserve(quotient, m + 1)) {
        magnitude_free(&u);
        magnitude_free(&v);
        return false;
    }
    memset(quotient->limbs, 0, (m + 1) * sizeof(*quotient->limbs));
    quotient->count = m + 1;

    const uint64_t base = (uint64_t)1 << LIMB_BITS;
    for (size_t j = m + 1; j-- > 0;) {
        uint64_t two = ((uint64_t)u.limbs[j + n] << LIMB_BITS) |
                       u.limbs[j + n - 1];
        uint64_t qhat = two / v.limbs[n - 1];
        uint64_t rhat = two % v.limbs[n - 1];
        while (qhat >= base ||
               qhat * v.limbs[n - 2] > (rhat << LIMB_BITS) + u.limbs[j + n - 2]) {
            --qhat;
            rhat += v.limbs[n - 1];
            if (rhat >= base) break;
        }

        /* Multiply and subtract. */
        int64_t borrow = 0;
        uint64_t carry = 0;
        for (size_t index = 0; index < n; ++index) {
            uint64_t product = qhat * v.limbs[index] + carry;
            carry = product >> LIMB_BITS;
            int64_t total = (int64_t)u.limbs[index + j] -
                            (int64_t)(product & 0xFFFFFFFFu) - borrow;
            if (total < 0) {
                total += (int64_t)base;
                borrow = 1;
            } else {
                borrow = 0;
            }
            u.limbs[index + j] = (uint32_t)total;
        }
        int64_t total = (int64_t)u.limbs[j + n] - (int64_t)carry - borrow;
        if (total < 0) {
            total += (int64_t)base;
            borrow = 1;
        } else {
            borrow = 0;
        }
        u.limbs[j + n] = (uint32_t)total;

        if (borrow != 0) {
            /* qhat was one too large: add the divisor back. */
            --qhat;
            uint64_t back = 0;
            for (size_t index = 0; index < n; ++index) {
                uint64_t sum = (uint64_t)u.limbs[index + j] +
                               v.limbs[index] + back;
                u.limbs[index + j] = (uint32_t)(sum & 0xFFFFFFFFu);
                back = sum >> LIMB_BITS;
            }
            u.limbs[j + n] = (uint32_t)(u.limbs[j + n] + back);
        }
        quotient->limbs[j] = (uint32_t)qhat;
    }
    magnitude_trim(quotient);

    /* Denormalize the remainder. */
    if (!magnitude_reserve(remainder, n)) {
        magnitude_free(&u);
        magnitude_free(&v);
        magnitude_free(quotient);
        return false;
    }
    for (size_t index = 0; index < n; ++index) {
        uint32_t low = (uint32_t)((uint64_t)u.limbs[index] >> shift);
        uint32_t high = shift == 0 || index + 1 >= n
            ? 0u
            : (uint32_t)(u.limbs[index + 1] << (LIMB_BITS - shift));
        remainder->limbs[index] = low | high;
    }
    remainder->count = n;
    magnitude_trim(remainder);

    magnitude_free(&u);
    magnitude_free(&v);
    return true;
}

/* Exact decimal digit count, for the profile's digit limit. */
static bool magnitude_digit_count(const Magnitude *m, size_t *digits) {
    *digits = 0;
    if (magnitude_is_zero(m)) {
        *digits = 1;
        return true;
    }
    Magnitude scratch;
    if (!magnitude_copy_from(&scratch, m->limbs, m->count)) return false;
    while (!magnitude_is_zero(&scratch)) {
        uint32_t chunk = magnitude_divmod_small(&scratch, 1000000000u);
        if (magnitude_is_zero(&scratch)) {
            while (chunk != 0) {
                ++*digits;
                chunk /= 10u;
            }
        } else {
            *digits += 9;
        }
    }
    magnitude_free(&scratch);
    return true;
}

/*
 * Turn a computed (sign, magnitude, scale) into a canonical result, applying
 * the profile's limits.
 *
 * The limits are checked *after* canonicalization on purpose. `0.1 + 0.2`
 * produces 3 with scale 1 only once the trailing zero is moved into the scale;
 * a check before that would reject results the profile does admit. Frozen
 * decision 8 requires the limit to fail rather than clamp, so this consumes
 * the magnitude either way.
 */
static KofunDecimalStatus finish(int sign, Magnitude *magnitude, long scale,
                                 KofunDecimal *out) {
    kofun_decimal_init(out);
    magnitude_trim(magnitude);
    if (magnitude_is_zero(magnitude)) {
        magnitude_free(magnitude);
        return KOFUN_DECIMAL_OK;
    }
    canonicalize(magnitude, &scale);
    size_t digits = 0;
    if (!magnitude_digit_count(magnitude, &digits)) {
        magnitude_free(magnitude);
        return KOFUN_DECIMAL_MEMORY;
    }
    if (digits > KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS) {
        magnitude_free(magnitude);
        return KOFUN_DECIMAL_DIGIT_LIMIT;
    }
    if (scale > KOFUN_DECIMAL_MAX_SCALE || scale < KOFUN_DECIMAL_MIN_SCALE) {
        magnitude_free(magnitude);
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    out->limbs = magnitude->limbs;
    out->limb_count = magnitude->count;
    out->scale = (int32_t)scale;
    out->sign = sign;
    out->inline_storage = magnitude->count <= INLINE_LIMBS;
    return KOFUN_DECIMAL_OK;
}

/*
 * Both operands as magnitudes at one common scale.
 *
 * The common scale is the larger of the two, reached by multiplying the
 * coarser operand by an exact power of ten. Scaling the coarser one up is what
 * keeps the alignment exact: scaling the finer one down would divide, and
 * dividing is where digits get lost.
 */
static KofunDecimalStatus align(const KofunDecimal *left,
                                const KofunDecimal *right,
                                Magnitude *a, Magnitude *b, long *scale) {
    long left_scale = left->scale;
    long right_scale = right->scale;
    *scale = left_scale > right_scale ? left_scale : right_scale;
    if (!magnitude_copy_from(a, left->limbs, left->limb_count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (!magnitude_copy_from(b, right->limbs, right->limb_count)) {
        magnitude_free(a);
        return KOFUN_DECIMAL_MEMORY;
    }
    if (*scale - left_scale > KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS ||
        *scale - right_scale > KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS) {
        /* The alignment alone would exceed the digit limit. Refuse before
         * allocating it rather than after. */
        magnitude_free(a);
        magnitude_free(b);
        return KOFUN_DECIMAL_DIGIT_LIMIT;
    }
    if (!magnitude_scale_pow10(a, *scale - left_scale) ||
        !magnitude_scale_pow10(b, *scale - right_scale)) {
        magnitude_free(a);
        magnitude_free(b);
        return KOFUN_DECIMAL_MEMORY;
    }
    return KOFUN_DECIMAL_OK;
}

/* Signed addition of two aligned magnitudes. `right_sign` flips for subtract. */
static KofunDecimalStatus add_signed(const KofunDecimal *left,
                                     const KofunDecimal *right,
                                     int right_sign, KofunDecimal *out) {
    kofun_decimal_init(out);
    Magnitude a;
    Magnitude b;
    long scale = 0;
    KofunDecimalStatus status = align(left, right, &a, &b, &scale);
    if (status != KOFUN_DECIMAL_OK) return status;

    Magnitude result;
    int sign;
    if (left->sign == 0) {
        sign = right_sign;
        if (!magnitude_copy_from(&result, b.limbs, b.count)) {
            magnitude_free(&a);
            magnitude_free(&b);
            return KOFUN_DECIMAL_MEMORY;
        }
    } else if (right_sign == 0) {
        sign = left->sign;
        if (!magnitude_copy_from(&result, a.limbs, a.count)) {
            magnitude_free(&a);
            magnitude_free(&b);
            return KOFUN_DECIMAL_MEMORY;
        }
    } else if (left->sign == right_sign) {
        sign = left->sign;
        if (!magnitude_add(&a, &b, &result)) {
            magnitude_free(&a);
            magnitude_free(&b);
            return KOFUN_DECIMAL_MEMORY;
        }
    } else {
        int order = magnitude_compare(&a, &b);
        bool ok;
        if (order >= 0) {
            sign = left->sign;
            ok = magnitude_subtract(&a, &b, &result);
        } else {
            sign = right_sign;
            ok = magnitude_subtract(&b, &a, &result);
        }
        if (!ok) {
            magnitude_free(&a);
            magnitude_free(&b);
            return KOFUN_DECIMAL_MEMORY;
        }
    }
    magnitude_free(&a);
    magnitude_free(&b);
    return finish(sign, &result, scale, out);
}

KofunDecimalStatus kofun_decimal_add(const KofunDecimal *left,
                                     const KofunDecimal *right,
                                     KofunDecimal *out) {
    if (left == NULL || right == NULL || out == NULL) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    return add_signed(left, right, right->sign, out);
}

KofunDecimalStatus kofun_decimal_subtract(const KofunDecimal *left,
                                          const KofunDecimal *right,
                                          KofunDecimal *out) {
    if (left == NULL || right == NULL || out == NULL) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    return add_signed(left, right, -right->sign, out);
}

KofunDecimalStatus kofun_decimal_multiply(const KofunDecimal *left,
                                          const KofunDecimal *right,
                                          KofunDecimal *out) {
    if (left == NULL || right == NULL || out == NULL) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    kofun_decimal_init(out);
    if (left->sign == 0 || right->sign == 0) return KOFUN_DECIMAL_OK;

    Magnitude a;
    Magnitude b;
    if (!magnitude_copy_from(&a, left->limbs, left->limb_count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (!magnitude_copy_from(&b, right->limbs, right->limb_count)) {
        magnitude_free(&a);
        return KOFUN_DECIMAL_MEMORY;
    }
    Magnitude product;
    bool ok = magnitude_multiply(&a, &b, &product);
    magnitude_free(&a);
    magnitude_free(&b);
    if (!ok) return KOFUN_DECIMAL_MEMORY;

    /* Scales add, and the sum is computed in long so it cannot wrap before
     * the profile's range check sees it. */
    long scale = (long)left->scale + (long)right->scale;
    return finish(left->sign * right->sign, &product, scale, out);
}

const char *kofun_decimal_division_name(KofunDecimalDivision outcome) {
    switch (outcome) {
        case KOFUN_DECIMAL_DIVISION_EXACT: return "Exact";
        case KOFUN_DECIMAL_DIVISION_INEXACT: return "InexactDivision";
        case KOFUN_DECIMAL_DIVISION_BY_ZERO: return "DivisionByZero";
    }
    return "Exact";
}

KofunDecimalStatus kofun_decimal_divide_exact(const KofunDecimal *left,
                                              const KofunDecimal *right,
                                              KofunDecimal *out,
                                              KofunDecimalDivision *outcome) {
    if (left == NULL || right == NULL || out == NULL || outcome == NULL) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    kofun_decimal_init(out);
    *outcome = KOFUN_DECIMAL_DIVISION_EXACT;
    if (right->sign == 0) {
        *outcome = KOFUN_DECIMAL_DIVISION_BY_ZERO;
        return KOFUN_DECIMAL_OK;
    }
    if (left->sign == 0) return KOFUN_DECIMAL_OK;

    Magnitude numerator;
    Magnitude divisor;
    if (!magnitude_copy_from(&numerator, left->limbs, left->limb_count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (!magnitude_copy_from(&divisor, right->limbs, right->limb_count)) {
        magnitude_free(&numerator);
        return KOFUN_DECIMAL_MEMORY;
    }

    /*
     * Write the divisor as 2^twos * 5^fives * residue. The quotient
     * terminates exactly when `residue` divides the dividend — the residue is
     * coprime to ten, so it cannot be cancelled by any power of ten, and it
     * survives reduction unless the dividend already contains it.
     */
    long twos = 0;
    long fives = 0;
    while (magnitude_mod_small(&divisor, 2u) == 0) {
        (void)magnitude_divmod_small(&divisor, 2u);
        ++twos;
    }
    while (magnitude_mod_small(&divisor, 5u) == 0) {
        (void)magnitude_divmod_small(&divisor, 5u);
        ++fives;
    }

    Magnitude quotient;
    magnitude_init(&quotient);
    bool residue_is_one = divisor.count == 1 && divisor.limbs[0] == 1u;
    if (residue_is_one) {
        if (!magnitude_copy_from(&quotient, numerator.limbs,
                                 numerator.count)) {
            magnitude_free(&numerator);
            magnitude_free(&divisor);
            return KOFUN_DECIMAL_MEMORY;
        }
    } else {
        Magnitude remainder;
        if (!magnitude_divmod(&numerator, &divisor, &quotient, &remainder)) {
            magnitude_free(&numerator);
            magnitude_free(&divisor);
            return KOFUN_DECIMAL_MEMORY;
        }
        bool exact = magnitude_is_zero(&remainder);
        magnitude_free(&remainder);
        if (!exact) {
            magnitude_free(&numerator);
            magnitude_free(&divisor);
            magnitude_free(&quotient);
            *outcome = KOFUN_DECIMAL_DIVISION_INEXACT;
            return KOFUN_DECIMAL_OK;
        }
    }
    magnitude_free(&numerator);
    magnitude_free(&divisor);

    /*
     * quotient / (2^twos * 5^fives) is made exact by scaling to a common
     * power of ten: multiply by the factor each side is short of, and record
     * the ten's power in the scale.
     */
    long tens = twos > fives ? twos : fives;
    if (!magnitude_scale_pow_small(&quotient, 2u, tens - twos) ||
        !magnitude_scale_pow_small(&quotient, 5u, tens - fives)) {
        magnitude_free(&quotient);
        return KOFUN_DECIMAL_MEMORY;
    }

    long scale = (long)left->scale - (long)right->scale + tens;
    return finish(left->sign * right->sign, &quotient, scale, out);
}

/* --- explicit rounding and formatting (slice 5, issue #724) ------------- */

const char *kofun_decimal_rounding_name(KofunDecimalRounding mode) {
    switch (mode) {
        case KOFUN_DECIMAL_HALF_UP: return "HalfUp";
        case KOFUN_DECIMAL_HALF_EVEN: return "HalfEven";
        case KOFUN_DECIMAL_TOWARD_ZERO: return "TowardZero";
        case KOFUN_DECIMAL_FLOOR: return "Floor";
        case KOFUN_DECIMAL_CEILING: return "Ceiling";
    }
    return "";
}

static bool decimal_rounding_valid(KofunDecimalRounding mode) {
    return mode >= KOFUN_DECIMAL_HALF_UP &&
           mode <= KOFUN_DECIMAL_CEILING;
}

/* Decide whether a non-zero remainder increments the unsigned quotient. */
static KofunDecimalStatus rounding_increment(
    int sign,
    const Magnitude *quotient,
    const Magnitude *remainder,
    const Magnitude *divisor,
    KofunDecimalRounding mode,
    bool *increment
) {
    *increment = false;
    if (magnitude_is_zero(remainder)) return KOFUN_DECIMAL_OK;
    if (!decimal_rounding_valid(mode)) return KOFUN_DECIMAL_ROUNDING_MODE;

    if (mode == KOFUN_DECIMAL_TOWARD_ZERO) return KOFUN_DECIMAL_OK;
    if (mode == KOFUN_DECIMAL_FLOOR) {
        *increment = sign < 0;
        return KOFUN_DECIMAL_OK;
    }
    if (mode == KOFUN_DECIMAL_CEILING) {
        *increment = sign > 0;
        return KOFUN_DECIMAL_OK;
    }

    Magnitude twice;
    if (!magnitude_copy_from(&twice, remainder->limbs, remainder->count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (!magnitude_mul_add_small(&twice, 2u, 0u)) {
        magnitude_free(&twice);
        return KOFUN_DECIMAL_MEMORY;
    }
    int half = magnitude_compare(&twice, divisor);
    magnitude_free(&twice);
    if (half > 0) {
        *increment = true;
    } else if (half == 0) {
        *increment = mode == KOFUN_DECIMAL_HALF_UP ||
            magnitude_mod_small(quotient, 2u) != 0;
    }
    return KOFUN_DECIMAL_OK;
}

/*
 * Divide two positive magnitudes, round the signed quotient, and consume both
 * inputs. The result is finalized at the caller's explicit destination scale.
 */
static KofunDecimalStatus divide_and_round(
    int sign,
    Magnitude *numerator,
    Magnitude *divisor,
    long target_scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
) {
    Magnitude quotient;
    Magnitude remainder;
    bool divided = magnitude_divmod(
        numerator,
        divisor,
        &quotient,
        &remainder
    );
    magnitude_free(numerator);
    if (!divided) {
        magnitude_free(divisor);
        return KOFUN_DECIMAL_MEMORY;
    }

    bool increment = false;
    KofunDecimalStatus status = rounding_increment(
        sign,
        &quotient,
        &remainder,
        divisor,
        mode,
        &increment
    );
    magnitude_free(&remainder);
    magnitude_free(divisor);
    if (status != KOFUN_DECIMAL_OK) {
        magnitude_free(&quotient);
        return status;
    }
    if (increment && !magnitude_mul_add_small(&quotient, 1u, 1u)) {
        magnitude_free(&quotient);
        return KOFUN_DECIMAL_MEMORY;
    }
    return finish(sign, &quotient, target_scale, out);
}

KofunDecimalStatus kofun_decimal_round(
    const KofunDecimal *value,
    long target_scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
) {
    if (value == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;
    kofun_decimal_init(out);
    if (target_scale > KOFUN_DECIMAL_MAX_SCALE ||
        target_scale < KOFUN_DECIMAL_MIN_SCALE) {
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    if (!decimal_rounding_valid(mode)) return KOFUN_DECIMAL_ROUNDING_MODE;

    Magnitude numerator;
    if (!magnitude_copy_from(
            &numerator,
            value->limbs,
            value->limb_count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (target_scale >= value->scale || value->sign == 0) {
        return finish(value->sign, &numerator, value->scale, out);
    }

    Magnitude divisor;
    magnitude_init(&divisor);
    if (!magnitude_reserve(&divisor, 1)) {
        magnitude_free(&numerator);
        return KOFUN_DECIMAL_MEMORY;
    }
    divisor.limbs[0] = 1u;
    divisor.count = 1;
    if (!magnitude_scale_pow10(&divisor, (long)value->scale - target_scale)) {
        magnitude_free(&numerator);
        magnitude_free(&divisor);
        return KOFUN_DECIMAL_MEMORY;
    }
    return divide_and_round(
        value->sign,
        &numerator,
        &divisor,
        target_scale,
        mode,
        out
    );
}

KofunDecimalStatus kofun_decimal_divide_rounded(
    const KofunDecimal *left,
    const KofunDecimal *right,
    long target_scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
) {
    if (left == NULL || right == NULL || out == NULL) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    kofun_decimal_init(out);
    if (target_scale > KOFUN_DECIMAL_MAX_SCALE ||
        target_scale < KOFUN_DECIMAL_MIN_SCALE) {
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    if (!decimal_rounding_valid(mode)) return KOFUN_DECIMAL_ROUNDING_MODE;
    if (right->sign == 0) return KOFUN_DECIMAL_DIVISION_ZERO;
    if (left->sign == 0) return KOFUN_DECIMAL_OK;

    Magnitude numerator;
    Magnitude divisor;
    if (!magnitude_copy_from(
            &numerator,
            left->limbs,
            left->limb_count)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    if (!magnitude_copy_from(
            &divisor,
            right->limbs,
            right->limb_count)) {
        magnitude_free(&numerator);
        return KOFUN_DECIMAL_MEMORY;
    }

    long exponent = (long)right->scale + target_scale - (long)left->scale;
    bool scaled = exponent >= 0
        ? magnitude_scale_pow10(&numerator, exponent)
        : magnitude_scale_pow10(&divisor, -exponent);
    if (!scaled) {
        magnitude_free(&numerator);
        magnitude_free(&divisor);
        return KOFUN_DECIMAL_MEMORY;
    }
    return divide_and_round(
        left->sign * right->sign,
        &numerator,
        &divisor,
        target_scale,
        mode,
        out
    );
}

KofunDecimalStatus kofun_decimal_parse(
    const char *text,
    size_t length,
    KofunDecimal *out
) {
    if (text == NULL || out == NULL || length == 0) {
        return KOFUN_DECIMAL_MALFORMED;
    }
    bool negative = false;
    size_t offset = 0;
    if (text[0] == '+' || text[0] == '-') {
        negative = text[0] == '-';
        offset = 1;
    }
    if (offset == length) return KOFUN_DECIMAL_MALFORMED;
    KofunDecimalStatus status = kofun_decimal_from_literal(
        text + offset,
        length - offset,
        out
    );
    if (status == KOFUN_DECIMAL_OK && negative && out->sign != 0) {
        out->sign = -out->sign;
    }
    return status;
}

KofunDecimalStatus kofun_decimal_format(
    const KofunDecimal *value,
    long display_scale,
    char **out
) {
    if (value == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;
    *out = NULL;
    if (display_scale < 0 || display_scale > KOFUN_DECIMAL_MAX_SCALE) {
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    if (display_scale < value->scale) {
        return KOFUN_DECIMAL_FORMAT_INEXACT;
    }

    char *digits = magnitude_to_text(value, false);
    if (digits == NULL) return KOFUN_DECIMAL_MEMORY;
    size_t digit_count = strlen(digits);
    size_t trailing = (size_t)(display_scale - (long)value->scale);
    long integer_digits = (long)digit_count - (long)value->scale;
    size_t leading = integer_digits > 0 ? 0u : (size_t)(1 - integer_digits);
    size_t sign = value->sign < 0 ? 1u : 0u;
    size_t point = display_scale > 0 ? 1u : 0u;
    size_t capacity = sign + leading + digit_count + trailing + point + 1u;
    char *text = malloc(capacity);
    if (text == NULL) {
        free(digits);
        return KOFUN_DECIMAL_MEMORY;
    }

    size_t written = 0;
    if (sign != 0) text[written++] = '-';
    if (integer_digits <= 0) {
        text[written++] = '0';
        if (display_scale > 0) text[written++] = '.';
        for (size_t index = 1; index < leading; ++index) {
            text[written++] = '0';
        }
        memcpy(text + written, digits, digit_count);
        written += digit_count;
        for (size_t index = 0; index < trailing; ++index) {
            text[written++] = '0';
        }
    } else {
        size_t whole = (size_t)integer_digits;
        size_t copied_whole = whole < digit_count ? whole : digit_count;
        memcpy(text + written, digits, copied_whole);
        written += copied_whole;
        size_t whole_zeroes = whole - copied_whole;
        size_t zeroes_before_point = whole_zeroes < trailing
            ? whole_zeroes
            : trailing;
        for (size_t index = 0; index < zeroes_before_point; ++index) {
            text[written++] = '0';
        }
        trailing -= zeroes_before_point;
        if (display_scale > 0) {
            text[written++] = '.';
            if (copied_whole < digit_count) {
                size_t fraction = digit_count - copied_whole;
                memcpy(text + written, digits + copied_whole, fraction);
                written += fraction;
            }
            for (size_t index = 0; index < trailing; ++index) {
                text[written++] = '0';
            }
        }
    }
    text[written] = '\0';
    free(digits);
    *out = text;
    return KOFUN_DECIMAL_OK;
}

/* --- Fixed[S] carrier (RFC-0015, issue #1661) ---------------------------- */

KofunDecimalStatus kofun_fixed_from_decimal(
    const KofunDecimal *input,
    long scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
) {
    if (input == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;
    kofun_decimal_init(out);
    /*
     * Decimal rounding accepts a negative target scale; `Fixed[S]` does not.
     * Checked here rather than left to `kofun_decimal_round`, whose wider
     * domain would otherwise make `Fixed[-1]` a successful construction.
     */
    if (scale < KOFUN_FIXED_MIN_SCALE || scale > KOFUN_FIXED_MAX_SCALE) {
        return KOFUN_DECIMAL_SCALE_LIMIT;
    }
    return kofun_decimal_round(input, scale, mode, out);
}

KofunDecimalStatus kofun_fixed_clone(
    const KofunDecimal *source,
    KofunDecimal *out
) {
    if (source == NULL || out == NULL) return KOFUN_DECIMAL_MALFORMED;
    kofun_decimal_init(out);
    if (source->limb_count == 0) return KOFUN_DECIMAL_OK;
    if (source->limb_count > (size_t)-1 / sizeof(*source->limbs)) {
        return KOFUN_DECIMAL_MEMORY;
    }
    uint32_t *limbs = malloc(source->limb_count * sizeof(*limbs));
    if (limbs == NULL) return KOFUN_DECIMAL_MEMORY;
    memcpy(limbs, source->limbs, source->limb_count * sizeof(*limbs));
    out->sign = source->sign;
    out->scale = source->scale;
    out->limbs = limbs;
    out->limb_count = source->limb_count;
    out->inline_storage = source->inline_storage;
    return KOFUN_DECIMAL_OK;
}

void kofun_fixed_move(KofunDecimal *source, KofunDecimal *out) {
    if (source == NULL || out == NULL) return;
    *out = *source;
    kofun_decimal_init(source);
}

void kofun_fixed_drop(KofunDecimal *value) {
    kofun_decimal_free(value);
}

/* --- Float, for contrast (slice 4 of #710, issue #723) -------------------- */

/*
 * Binary64, with its ordinary behavior and no checking.
 *
 * These are one line each and exist as named functions rather than inline
 * arithmetic so that the two types' operations are reachable through one
 * surface. The contrast is the deliverable: `kofun_float_divide(1.0, 0.0)`
 * is an infinity, where `kofun_decimal_divide_exact` reports
 * `DivisionByZero` and produces no value at all.
 */
double kofun_float_add(double left, double right) {
    return left + right;
}

double kofun_float_subtract(double left, double right) {
    return left - right;
}

double kofun_float_multiply(double left, double right) {
    return left * right;
}

double kofun_float_divide(double left, double right) {
    return left / right;
}

/* --- value shim for generated code (issue #723) --------------------------- */

/*
 * A flat arena of every Decimal a generated program has produced.
 *
 * It grows and is released once; there is no per-value free, because the
 * lowering has no place to put one. A Kofun expression is a tree and its
 * intermediate values have no names, so the alternative is emitting
 * temporaries and unwinding them through every path out of the enclosing
 * function — which is how generated code leaks.
 */
static KofunDecimal **decimal_arena;
static size_t decimal_arena_count;
static size_t decimal_arena_capacity;
static KofunDecimalResult **decimal_result_arena;
static size_t decimal_result_arena_count;
static size_t decimal_result_arena_capacity;
static char **decimal_text_arena;
static size_t decimal_text_arena_count;
static size_t decimal_text_arena_capacity;

/*
 * A resource limit reaching generated code is fatal.
 *
 * Frozen decision 8 forbids clamping or changing representation, and there is
 * no value a program could continue with that would be the answer. So this
 * reports the profile's own code and stops, rather than the integer path's
 * "record the failure and keep going" — an integer overflow has a defined
 * wrong value to carry, an unrepresentable Decimal does not.
 */
static void decimal_fatal(KofunDecimalStatus status) {
    fputs(kofun_decimal_status_message(status), stderr);
    fputc('\n', stderr);
    exit(1);
}

static KofunDecimal *decimal_arena_push(void) {
    if (decimal_arena_count == decimal_arena_capacity) {
        size_t capacity = decimal_arena_capacity == 0
            ? 16
            : decimal_arena_capacity * 2;
        KofunDecimal **grown = realloc(
            decimal_arena,
            capacity * sizeof(*grown)
        );
        if (grown == NULL) decimal_fatal(KOFUN_DECIMAL_MEMORY);
        decimal_arena = grown;
        decimal_arena_capacity = capacity;
    }
    KofunDecimal *value = malloc(sizeof(*value));
    if (value == NULL) decimal_fatal(KOFUN_DECIMAL_MEMORY);
    kofun_decimal_init(value);
    decimal_arena[decimal_arena_count++] = value;
    return value;
}

KofunDecimal *kofun_decimal_value_literal(const char *text, size_t length) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_from_literal(
        text,
        length,
        value
    );
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_from_int(int64_t source) {
    char digits[32];
    uint64_t magnitude = source < 0
        ? (uint64_t)(-(source + 1)) + UINT64_C(1)
        : (uint64_t)source;
    int written = snprintf(digits, sizeof digits, "%" PRIu64, magnitude);
    if (written < 0 || (size_t)written >= sizeof digits) {
        decimal_fatal(KOFUN_DECIMAL_MALFORMED);
    }
    KofunDecimal *value = kofun_decimal_value_literal(
        digits,
        (size_t)written
    );
    if (source < 0 && value->sign != 0) value->sign = -value->sign;
    return value;
}

KofunDecimal *kofun_decimal_value_add(
    const KofunDecimal *left,
    const KofunDecimal *right
) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_add(left, right, value);
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_subtract(
    const KofunDecimal *left,
    const KofunDecimal *right
) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_subtract(left, right, value);
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_multiply(
    const KofunDecimal *left,
    const KofunDecimal *right
) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_multiply(left, right, value);
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_negate(const KofunDecimal *source) {
    KofunDecimal zero;
    kofun_decimal_init(&zero);
    KofunDecimal *value = kofun_decimal_value_subtract(&zero, source);
    kofun_decimal_free(&zero);
    return value;
}

KofunDecimal *kofun_decimal_value_round(
    const KofunDecimal *source,
    long target_scale,
    KofunDecimalRounding mode
) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_round(
        source,
        target_scale,
        mode,
        value
    );
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_divide_rounded(
    const KofunDecimal *left,
    const KofunDecimal *right,
    long target_scale,
    KofunDecimalRounding mode
) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_divide_rounded(
        left,
        right,
        target_scale,
        mode,
        value
    );
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

KofunDecimal *kofun_decimal_value_parse(const char *text, size_t length) {
    KofunDecimal *value = decimal_arena_push();
    KofunDecimalStatus status = kofun_decimal_parse(text, length, value);
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

static const char *decimal_text_arena_push(char *text) {
    if (decimal_text_arena_count == decimal_text_arena_capacity) {
        size_t capacity = decimal_text_arena_capacity == 0
            ? 8
            : decimal_text_arena_capacity * 2;
        char **grown = realloc(decimal_text_arena, capacity * sizeof(*grown));
        if (grown == NULL) {
            free(text);
            decimal_fatal(KOFUN_DECIMAL_MEMORY);
        }
        decimal_text_arena = grown;
        decimal_text_arena_capacity = capacity;
    }
    decimal_text_arena[decimal_text_arena_count++] = text;
    return text;
}

const char *kofun_decimal_value_format(
    const KofunDecimal *value,
    long display_scale
) {
    char *text = NULL;
    KofunDecimalStatus status = kofun_decimal_format(
        value,
        display_scale,
        &text
    );
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return decimal_text_arena_push(text);
}

static KofunDecimalResult *decimal_result_arena_push(void) {
    if (decimal_result_arena_count == decimal_result_arena_capacity) {
        size_t capacity = decimal_result_arena_capacity == 0
            ? 8
            : decimal_result_arena_capacity * 2;
        KofunDecimalResult **grown = realloc(
            decimal_result_arena,
            capacity * sizeof(*grown)
        );
        if (grown == NULL) decimal_fatal(KOFUN_DECIMAL_MEMORY);
        decimal_result_arena = grown;
        decimal_result_arena_capacity = capacity;
    }
    KofunDecimalResult *result = malloc(sizeof(*result));
    if (result == NULL) decimal_fatal(KOFUN_DECIMAL_MEMORY);
    result->outcome = KOFUN_DECIMAL_DIVISION_INEXACT;
    kofun_decimal_init(&result->value);
    decimal_result_arena[decimal_result_arena_count++] = result;
    return result;
}

KofunDecimalResult *kofun_decimal_value_divide_exact(
    const KofunDecimal *left,
    const KofunDecimal *right
) {
    KofunDecimalResult *result = decimal_result_arena_push();
    KofunDecimalStatus status = kofun_decimal_divide_exact(
        left,
        right,
        &result->value,
        &result->outcome
    );
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return result;
}

const char *kofun_decimal_value_division_name(
    const KofunDecimalResult *result
) {
    return kofun_decimal_division_name(result->outcome);
}

double kofun_float_value_literal(const char *text, size_t length) {
    double value = 0.0;
    KofunDecimalStatus status = kofun_float_from_literal(text, length, &value);
    if (status != KOFUN_DECIMAL_OK) decimal_fatal(status);
    return value;
}

void kofun_decimal_arena_release(void) {
    for (size_t index = 0; index < decimal_arena_count; ++index) {
        kofun_decimal_free(decimal_arena[index]);
        free(decimal_arena[index]);
    }
    free(decimal_arena);
    decimal_arena = NULL;
    decimal_arena_count = 0;
    decimal_arena_capacity = 0;
    for (size_t index = 0; index < decimal_result_arena_count; ++index) {
        kofun_decimal_free(&decimal_result_arena[index]->value);
        free(decimal_result_arena[index]);
    }
    free(decimal_result_arena);
    decimal_result_arena = NULL;
    decimal_result_arena_count = 0;
    decimal_result_arena_capacity = 0;
    for (size_t index = 0; index < decimal_text_arena_count; ++index) {
        free(decimal_text_arena[index]);
    }
    free(decimal_text_arena);
    decimal_text_arena = NULL;
    decimal_text_arena_count = 0;
    decimal_text_arena_capacity = 0;
}
