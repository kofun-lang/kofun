/*
 * Driver for the Fixed[S] runtime entry points (#1661).
 *
 * RFC-0015 asks for two things a golden cannot show: that construction and
 * clone fail by status rather than by aborting, and that a failure "leaves
 * outputs uninitialized/absent and releases temporary storage". Both are
 * about allocation, so this driver owns allocation.
 *
 * The seam: in this translation unit only, `malloc`, `realloc` and `free`
 * are redirected to wrappers that count live blocks and can refuse the Nth
 * allocation attempt. The redirection exists because this file defines the
 * macros and then includes `decimal_v1.c`; the object every other build
 * links has no hook. Anything `decimal_v1.c` allocates must therefore be
 * released through `seam_free`, which is why the driver never calls `free`
 * on runtime-owned memory after the include.
 *
 * Every check names itself on failure and exits 1. On success each section
 * prints one deterministic line, which the gate compares with a golden.
 */

#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long seam_attempts;
static unsigned long seam_refuse_at;
static unsigned long seam_refused;
static long seam_live;

static bool seam_refuses(void) {
    ++seam_attempts;
    if (seam_refuse_at != 0 && seam_attempts == seam_refuse_at) {
        ++seam_refused;
        return true;
    }
    return false;
}

static void *seam_malloc(size_t size) {
    if (seam_refuses()) return NULL;
    void *block = malloc(size);
    if (block != NULL) ++seam_live;
    return block;
}

static void *seam_realloc(void *old, size_t size) {
    if (seam_refuses()) return NULL;
    void *block = realloc(old, size);
    if (block != NULL && old == NULL) ++seam_live;
    return block;
}

static void seam_free(void *block) {
    if (block != NULL) --seam_live;
    free(block);
}

#define malloc(size) seam_malloc(size)
#define realloc(old, size) seam_realloc(old, size)
#define free(block) seam_free(block)
#include "decimal_v1.c"
#undef malloc
#undef realloc
#undef free

static void check(bool condition, const char *section, const char *what) {
    if (!condition) {
        fprintf(stderr, "FAIL: fixed runtime: %s: %s\n", section, what);
        exit(1);
    }
}

static const KofunDecimalRounding modes[] = {
    KOFUN_DECIMAL_HALF_UP,
    KOFUN_DECIMAL_HALF_EVEN,
    KOFUN_DECIMAL_TOWARD_ZERO,
    KOFUN_DECIMAL_FLOOR,
    KOFUN_DECIMAL_CEILING,
};
#define MODE_COUNT (sizeof modes / sizeof modes[0])

static KofunDecimal parse_or_die(const char *text, const char *section) {
    KofunDecimal value;
    KofunDecimalStatus status = kofun_decimal_parse(text, strlen(text), &value);
    check(status == KOFUN_DECIMAL_OK, section, "an input did not parse");
    return value;
}

static bool is_empty(const KofunDecimal *value) {
    return value->sign == 0 && value->scale == 0 && value->limbs == NULL &&
        value->limb_count == 0;
}

/* A byte-exact copy of a value, kept outside the seam's accounting. */
typedef struct {
    int sign;
    int32_t scale;
    size_t limb_count;
    uint32_t limbs[512];
} Snapshot;

static void snapshot_take(Snapshot *snapshot, const KofunDecimal *value) {
    check(value->limb_count <= 512, "snapshot", "value too large to snapshot");
    snapshot->sign = value->sign;
    snapshot->scale = value->scale;
    snapshot->limb_count = value->limb_count;
    if (value->limb_count != 0) {
        memcpy(snapshot->limbs, value->limbs,
               value->limb_count * sizeof(*value->limbs));
    }
}

static bool snapshot_matches(const Snapshot *snapshot, const KofunDecimal *value) {
    return snapshot->sign == value->sign && snapshot->scale == value->scale &&
        snapshot->limb_count == value->limb_count &&
        (value->limb_count == 0 ||
         memcmp(snapshot->limbs, value->limbs,
                value->limb_count * sizeof(*value->limbs)) == 0);
}

/*
 * `Fixed[S].format()` emits exactly S fractional digits and never rounds, so
 * formatting a constructed value at its own S must succeed and have that
 * shape. This is what makes the canonical payload sufficient: the static S
 * recovers the display the payload canonicalized away.
 */
static char *format_at(const KofunDecimal *value, long scale,
                       const char *section) {
    char *text = NULL;
    KofunDecimalStatus status = kofun_decimal_format(value, scale, &text);
    check(status == KOFUN_DECIMAL_OK, section,
          "a constructed value did not format exactly at its own scale");
    const char *point = strchr(text, '.');
    size_t fraction = point == NULL ? 0 : strlen(point + 1);
    check(fraction == (size_t)scale, section,
          "a constructed value formatted with the wrong number of digits");
    return text;
}

/* RFC-0015's worked examples, and their negations. */
static void section_rfc(void) {
    static const struct {
        const char *input;
        long scale;
        KofunDecimalRounding mode;
        const char *formatted;
    } cases[] = {
        {"1.999", 2, KOFUN_DECIMAL_HALF_UP, "2.00"},
        {"2.5", 0, KOFUN_DECIMAL_HALF_EVEN, "2"},
        {"3.5", 0, KOFUN_DECIMAL_HALF_EVEN, "4"},
        {"-1.999", 2, KOFUN_DECIMAL_HALF_UP, "-2.00"},
        {"-2.5", 0, KOFUN_DECIMAL_HALF_EVEN, "-2"},
        {"-3.5", 0, KOFUN_DECIMAL_HALF_EVEN, "-4"},
    };
    size_t count = sizeof cases / sizeof cases[0];
    for (size_t index = 0; index < count; ++index) {
        KofunDecimal input = parse_or_die(cases[index].input, "rfc");
        KofunDecimal fixed;
        check(kofun_fixed_from_decimal(&input, cases[index].scale,
                                       cases[index].mode, &fixed) ==
                  KOFUN_DECIMAL_OK,
              "rfc", "an RFC-0015 example did not construct");
        char *text = format_at(&fixed, cases[index].scale, "rfc");
        check(strcmp(text, cases[index].formatted) == 0, "rfc",
              "an RFC-0015 example formatted differently from the RFC");
        seam_free(text);
        kofun_fixed_drop(&fixed);
        kofun_decimal_free(&input);
    }
    printf("rfc: %zu RFC-0015 examples construct and format as written\n",
           count);
}

/* Construction is exactly `kofun_decimal_round`, digit for digit. */
static void section_modes(void) {
    static const char *inputs[] = {
        "0", "7", "1.005", "-1.005", "2.5", "-2.5", "0.125", "-0.125",
        "1000", "-0.0049",
        "123456789012345678901234567890.123456789",
        "-99999999999999999999999999999999999999.99999",
    };
    static const long scales[] = {0, 1, 2, 3, 10, 40};
    size_t checked = 0;
    for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; ++i) {
        KofunDecimal input = parse_or_die(inputs[i], "modes");
        for (size_t s = 0; s < sizeof scales / sizeof scales[0]; ++s) {
            for (size_t m = 0; m < MODE_COUNT; ++m) {
                KofunDecimal fixed;
                KofunDecimal rounded;
                KofunDecimalStatus fixed_status = kofun_fixed_from_decimal(
                    &input, scales[s], modes[m], &fixed);
                KofunDecimalStatus round_status = kofun_decimal_round(
                    &input, scales[s], modes[m], &rounded);
                check(fixed_status == KOFUN_DECIMAL_OK &&
                          round_status == KOFUN_DECIMAL_OK,
                      "modes", "an in-domain construction failed");
                check(kofun_decimal_equal(&fixed, &rounded), "modes",
                      "construction differs from kofun_decimal_round");
                seam_free(format_at(&fixed, scales[s], "modes"));
                kofun_fixed_drop(&fixed);
                kofun_decimal_free(&rounded);
                ++checked;
            }
        }
        kofun_decimal_free(&input);
    }
    printf("modes: %zu constructions equal kofun_decimal_round and format at S\n",
           checked);
}

static char *repeat(const char *prefix, char digit, size_t count,
                    const char *suffix) {
    size_t head = strlen(prefix);
    size_t tail = strlen(suffix);
    char *text = malloc(head + count + tail + 1);
    check(text != NULL, "witness", "the driver could not build an input");
    memcpy(text, prefix, head);
    memset(text + head, digit, count);
    memcpy(text + head + count, suffix, tail + 1);
    return text;
}

/*
 * The #1250 refinement's reachability witness, kept as a regression fixture:
 * profile-boundary inputs at nine scales across the Fixed domain. None may
 * fail with D001, D002 or D003. Only allocation (D004) is a failure a caller
 * can observe from an in-domain construction, and the refusal section below
 * is where that one is exercised. This is a bounded witness, not a proof.
 */
static void section_witness(void) {
    static const struct {
        const char *prefix;
        size_t nines;
        const char *suffix;
        bool rescale;
        int32_t scale;
    } shapes[] = {
        {"0.", 4096, "", false, 0},
        {"", 4095, ".5", false, 0},
        {"-", 4095, ".5", false, 0},
        {"", 4096, "", true, -6144},
        {"", 0, "1", true, 6144},
        {"", 4096, "", true, 6144},
        {"-", 4096, "", true, 6144},
    };
    static const long scales[] = {0, 1, 2, 2047, 2048, 4095, 4096, 6143, 6144};
    size_t checked = 0;
    for (size_t i = 0; i < sizeof shapes / sizeof shapes[0]; ++i) {
        char *text = repeat(shapes[i].prefix, '9', shapes[i].nines,
                            shapes[i].suffix);
        KofunDecimal input = parse_or_die(text, "witness");
        free(text);
        if (shapes[i].rescale) input.scale = shapes[i].scale;
        for (size_t s = 0; s < sizeof scales / sizeof scales[0]; ++s) {
            for (size_t m = 0; m < MODE_COUNT; ++m) {
                KofunDecimal fixed;
                check(kofun_fixed_from_decimal(&input, scales[s], modes[m],
                                               &fixed) == KOFUN_DECIMAL_OK,
                      "witness",
                      "a profile-boundary input failed to construct in domain");
                seam_free(format_at(&fixed, scales[s], "witness"));
                kofun_fixed_drop(&fixed);
                ++checked;
            }
        }
        kofun_decimal_free(&input);
    }
    printf("witness: %zu profile-boundary constructions in 0..6144 succeed\n",
           checked);
}

/* Out of domain is a status. Nothing aborts, allocates, or writes. */
static void section_domain(void) {
    static const long scales[] = {-1, KOFUN_FIXED_MAX_SCALE + 1, LONG_MIN,
                                  LONG_MAX};
    KofunDecimal input = parse_or_die("1.999", "domain");
    Snapshot before;
    snapshot_take(&before, &input);
    long live = seam_live;
    for (size_t s = 0; s < sizeof scales / sizeof scales[0]; ++s) {
        KofunDecimal fixed;
        seam_attempts = 0;
        check(kofun_fixed_from_decimal(&input, scales[s],
                                       KOFUN_DECIMAL_HALF_UP, &fixed) ==
                  KOFUN_DECIMAL_SCALE_LIMIT,
              "domain", "a scale outside 0..6144 was not D002");
        check(is_empty(&fixed), "domain", "a refused scale wrote an output");
        check(seam_attempts == 0, "domain", "a refused scale allocated");
    }
    KofunDecimal fixed;
    check(kofun_fixed_from_decimal(&input, 2, (KofunDecimalRounding)5,
                                   &fixed) == KOFUN_DECIMAL_ROUNDING_MODE,
          "domain", "an unknown rounding mode was not D006");
    check(is_empty(&fixed), "domain", "an unknown mode wrote an output");
    check(kofun_fixed_from_decimal(NULL, 2, KOFUN_DECIMAL_HALF_UP, &fixed) ==
              KOFUN_DECIMAL_MALFORMED,
          "domain", "a missing input was not D003");
    check(kofun_fixed_clone(NULL, &fixed) == KOFUN_DECIMAL_MALFORMED,
          "domain", "a missing clone source was not D003");
    check(snapshot_matches(&before, &input), "domain",
          "a refused construction changed its input");
    check(seam_live == live, "domain", "a refused construction leaked");
    kofun_decimal_free(&input);
    printf("domain: S -1, 6145, LONG_MIN and LONG_MAX are D002, mode 5 is "
           "D006, missing operands are D003; none allocates or writes\n");
}

typedef enum { OP_ROUND, OP_COPY, OP_CLONE } Operation;

static KofunDecimalStatus run(Operation op, const KofunDecimal *input,
                              KofunDecimal *out) {
    switch (op) {
        case OP_ROUND:
            return kofun_fixed_from_decimal(input, 2, KOFUN_DECIMAL_HALF_EVEN,
                                            out);
        case OP_COPY:
            return kofun_fixed_from_decimal(input, 6144,
                                            KOFUN_DECIMAL_HALF_EVEN, out);
        case OP_CLONE:
            return kofun_fixed_clone(input, out);
    }
    return KOFUN_DECIMAL_MALFORMED;
}

/*
 * Refuse the 1st allocation, then the 2nd, and so on, until the operation
 * no longer needs the refused one. Every refused run must return D004 with
 * an empty output, an input equal byte for byte, and no block left live.
 */
static unsigned long sweep(Operation op, const char *literal,
                           const char *name) {
    KofunDecimal input = parse_or_die(literal, name);
    KofunDecimal expected;
    check(run(op, &input, &expected) == KOFUN_DECIMAL_OK, name,
          "the unrefused operation failed");
    Snapshot before;
    snapshot_take(&before, &input);
    long live = seam_live;
    unsigned long refused_runs = 0;
    for (unsigned long nth = 1;; ++nth) {
        check(nth <= 10000, name, "the sweep did not terminate");
        KofunDecimal out;
        seam_attempts = 0;
        seam_refused = 0;
        seam_refuse_at = nth;
        KofunDecimalStatus status = run(op, &input, &out);
        seam_refuse_at = 0;
        check(snapshot_matches(&before, &input), name,
              "a refused allocation changed the input");
        if (seam_refused == 0) {
            check(status == KOFUN_DECIMAL_OK, name,
                  "an operation with nothing refused failed");
            check(kofun_decimal_equal(&out, &expected), name,
                  "the first unrefused run produced a different value");
            kofun_fixed_drop(&out);
            break;
        }
        check(status == KOFUN_DECIMAL_MEMORY, name,
              "a refused allocation was not reported as D004");
        check(is_empty(&out), name, "a refused allocation left an output");
        check(seam_live == live, name,
              "a refused allocation left a temporary live");
        ++refused_runs;
    }
    check(refused_runs > 0, name, "the sweep refused nothing, so proved nothing");
    check(seam_live == live, name, "the sweep leaked");
    kofun_fixed_drop(&expected);
    kofun_decimal_free(&input);
    return refused_runs;
}

static void section_refusal(void) {
    const char *large =
        "-123456789012345678901234567890123456789.987654321987654321";
    /*
     * Two rounding shapes, because the division underneath has two paths: a
     * divisor of several limbs (10^16 here) and a single-limb one (10^1).
     * Both leaked the quotient when the remainder's allocation was refused.
     */
    unsigned long wide = sweep(OP_ROUND, large, "refusal round wide divisor");
    unsigned long narrow = sweep(OP_ROUND, "-12345.678",
                                 "refusal round narrow divisor");
    unsigned long copying = sweep(OP_COPY, large, "refusal copy");
    unsigned long cloning = sweep(OP_CLONE, large, "refusal clone");
    check(wide > 0 && narrow > 0 && copying > 0 && cloning > 0, "refusal",
          "a sweep was vacuous");
    printf("refusal: every refused allocation in construct (wide and narrow "
           "divisor rounding, and exact), and clone, is D004 with an empty "
           "output, an unchanged input and nothing live\n");
}

/* Move, clone and drop release each payload exactly once, on every path. */
static void section_ownership(void) {
    long live = seam_live;
    KofunDecimal empty;
    kofun_decimal_init(&empty);
    kofun_fixed_drop(&empty);
    kofun_fixed_drop(&empty);
    check(is_empty(&empty) && seam_live == live, "ownership",
          "dropping an empty value was not a no-op");

    KofunDecimal input = parse_or_die("98765.4321", "ownership");
    KofunDecimal fixed;
    check(kofun_fixed_from_decimal(&input, 2, KOFUN_DECIMAL_HALF_UP,
                                   &fixed) == KOFUN_DECIMAL_OK,
          "ownership", "construction failed");
    KofunDecimal copy;
    check(kofun_fixed_clone(&fixed, &copy) == KOFUN_DECIMAL_OK, "ownership",
          "clone failed");
    check(kofun_decimal_equal(&copy, &fixed) && copy.limbs != fixed.limbs,
          "ownership", "clone did not produce an equal, separate payload");

    KofunDecimal moved;
    const uint32_t *payload = fixed.limbs;
    kofun_fixed_move(&fixed, &moved);
    check(is_empty(&fixed) && moved.limbs == payload, "ownership",
          "move did not transfer the payload and empty the source");
    long before_drop = seam_live;
    kofun_fixed_drop(&fixed);
    check(seam_live == before_drop, "ownership",
          "dropping a moved-from value released something");

    kofun_fixed_drop(&moved);
    kofun_fixed_drop(&moved);
    kofun_fixed_drop(&copy);
    kofun_decimal_free(&input);
    check(is_empty(&moved) && is_empty(&copy), "ownership",
          "drop did not leave the value empty");
    check(seam_live == live, "ownership",
          "construct, clone, move and drop did not release exactly once");

    KofunDecimal zero = parse_or_die("0", "ownership");
    KofunDecimal zero_copy;
    check(kofun_fixed_clone(&zero, &zero_copy) == KOFUN_DECIMAL_OK &&
              kofun_decimal_equal(&zero, &zero_copy) && seam_live == live,
          "ownership", "cloning zero allocated or changed it");
    kofun_fixed_drop(&zero_copy);
    kofun_decimal_free(&zero);
    printf("ownership: move empties its source, clone is deep, and drop is "
           "exactly once and idempotent\n");
}

int main(void) {
    section_rfc();
    section_modes();
    section_witness();
    section_domain();
    section_refusal();
    section_ownership();
    check(seam_live == 0, "exit", "a block is still live at exit");
    return 0;
}
