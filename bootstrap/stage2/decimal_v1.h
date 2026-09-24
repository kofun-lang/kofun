#ifndef KOFUN_STAGE2_DECIMAL_V1_H
#define KOFUN_STAGE2_DECIMAL_V1_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Compiler-native Decimal, slice 2 of #710: the runtime representation, its
 * canonical form, and the versioned resource profile that bounds it.
 *
 * A Decimal is a canonical `(significand, scale)` pair whose significand is an
 * arbitrary-precision binary integer, per #710's frozen decision 1. The value
 * is `significand * 10^-scale`. Scale may be negative, so `1e3` and `1000`
 * are the same canonical value.
 *
 * Slice 2 constructs, canonicalizes, compares and renders. Slice 4 adds exact
 * arithmetic and checked division; slice 5 adds explicit rounding, rounded
 * division, parsing, and scale-preserving display. `docs/DECIMAL.md` is
 * normative for every layer.
 */

/*
 * Resource profile. `docs/DECIMAL.md` says the first concrete thresholds "are
 * deferred, but must be versioned together when introduced" — this is that
 * introduction, so the version and every limit move as one unit.
 *
 * Every backend registered for this profile observes these limits and these
 * diagnostics. Exceeding one fails before an unbounded allocation and never
 * clamps, wraps, rounds, or changes representation.
 */
#define KOFUN_DECIMAL_PROFILE_VERSION 1u
#define KOFUN_DECIMAL_MAX_SIGNIFICAND_DIGITS 4096u
#define KOFUN_DECIMAL_MAX_SCALE 6144L
#define KOFUN_DECIMAL_MIN_SCALE (-6144L)

typedef enum {
    KOFUN_DECIMAL_OK = 0,
    /* More significand digits than the profile admits. */
    KOFUN_DECIMAL_DIGIT_LIMIT = 1,
    /* Scale outside the profile's range, before or after canonicalization. */
    KOFUN_DECIMAL_SCALE_LIMIT = 2,
    /* Not a literal this profile's grammar accepts. */
    KOFUN_DECIMAL_MALFORMED = 3,
    /* Allocation refused. */
    KOFUN_DECIMAL_MEMORY = 4,
    /* Rounded division by zero has no Decimal result. */
    KOFUN_DECIMAL_DIVISION_ZERO = 5,
    /* A value outside the five pinned rounding modes reached the runtime. */
    KOFUN_DECIMAL_ROUNDING_MODE = 6,
    /* Formatting at the requested scale would discard a non-zero digit. */
    KOFUN_DECIMAL_FORMAT_INEXACT = 7
} KofunDecimalStatus;

/* Stable diagnostic code, `D001`-style, or "" for OK. */
const char *kofun_decimal_status_code(KofunDecimalStatus status);

/* Stable one-line message with no source location, or "" for OK. */
const char *kofun_decimal_status_message(KofunDecimalStatus status);

unsigned kofun_decimal_profile_version(void);

/*
 * A canonical Decimal.
 *
 * `sign` is -1, 0 or +1, and is 0 exactly when the value is zero. A zero
 * carries `scale == 0` and no limbs, so there is one representation of zero.
 *
 * `limbs` is the significand's magnitude in base 2^32, least significant
 * first, with no leading zero limb. Canonical form additionally requires that
 * the magnitude is not divisible by ten: trailing decimal zeros are moved into
 * `scale` instead, which is what makes `1.0`, `1.00` and `1` one value
 * (#710 frozen decision 6).
 *
 * `inline_storage` records whether the significand fits the small-value path.
 * It is diagnostics for the conformance gate only. Frozen decision 1 permits
 * small storage solely as an unobservable optimization, so nothing outside the
 * gate that proves that invisibility may branch on it.
 */
typedef struct {
    int sign;
    int32_t scale;
    uint32_t *limbs;
    size_t limb_count;
    bool inline_storage;
} KofunDecimal;

void kofun_decimal_init(KofunDecimal *value);
void kofun_decimal_free(KofunDecimal *value);

/*
 * Build a canonical Decimal from a literal, which must be the exact bytes the
 * lexer retained: `digits [ "." digits ] [ exponent ]`, `_` only between two
 * digits, no `f64` suffix and no sign.
 *
 * The digits are consumed as written and scaled by the exponent. No host
 * `double` is on this path, which `docs/DECIMAL.md` requires.
 */
KofunDecimalStatus kofun_decimal_from_literal(
    const char *text,
    size_t length,
    KofunDecimal *out
);

/* Two canonical values are equal exactly when their fields match. */
bool kofun_decimal_equal(const KofunDecimal *left, const KofunDecimal *right);

/* -1, 0, +1 by numeric value. */
int kofun_decimal_compare(const KofunDecimal *left, const KofunDecimal *right);

/*
 * `<significand>e<-scale>`, the canonical observation used by the gates: two
 * spellings of one value render identically, and the rendering is exact
 * because it never leaves the integer domain. Caller frees.
 */
char *kofun_decimal_to_canonical_text(const KofunDecimal *value);

/* Signed decimal digits of the significand. Caller frees. */
char *kofun_decimal_significand_text(const KofunDecimal *value);

/*
 * Binary64 for the `f64` suffix, correctly rounded to nearest-even from the
 * exact decimal value.
 *
 * `literal` is the literal without its `f64` suffix. This deliberately does
 * not go through `strtod`: the conversion must be identical on every backend
 * and independent of the host locale, so it is computed from the same
 * arbitrary-precision significand Decimal uses.
 */
KofunDecimalStatus kofun_float_from_literal(
    const char *text,
    size_t length,
    double *out
);

/* --- exact arithmetic (slice 4 of #710, issue #723) ----------------------- */

/*
 * Addition, subtraction and multiplication are exact: the result's scale
 * follows from the operands and no digit is discarded (frozen decision 5).
 * `+` and `-` align the two scales with an exact power of ten and take the
 * larger; `*` adds the scales. The result is canonicalized, so trailing
 * decimal zeros produced by the operation move into the scale and
 * `0.1 + 0.2` and `0.3` are one value.
 *
 * The only failures are resource failures: a result may exceed the profile's
 * digit or scale limit, and then it fails rather than rounding. There is no
 * rounding mode here because these operations never round.
 *
 * `out` is initialized by the callee and owned by the caller on success; on
 * failure it is left as a valid empty value that `kofun_decimal_free` accepts.
 */
KofunDecimalStatus kofun_decimal_add(
    const KofunDecimal *left,
    const KofunDecimal *right,
    KofunDecimal *out
);
KofunDecimalStatus kofun_decimal_subtract(
    const KofunDecimal *left,
    const KofunDecimal *right,
    KofunDecimal *out
);
KofunDecimalStatus kofun_decimal_multiply(
    const KofunDecimal *left,
    const KofunDecimal *right,
    KofunDecimal *out
);

/*
 * The outcome of an exact division, which is a fact about the two values
 * rather than a resource failure — so it is a separate enum from
 * `KofunDecimalStatus`. Conflating them would let a caller treat "this
 * quotient needs more digits than the profile allows" and "this quotient does
 * not terminate at all" as the same thing; only the first would be fixed by a
 * larger profile.
 *
 * There are exactly three outcomes and no fourth. In particular there is no
 * "rounded" outcome: rounded division is a different operation that requires a
 * destination scale and a mode, and it is slice 5.
 */
typedef enum {
    KOFUN_DECIMAL_DIVISION_EXACT = 0,
    KOFUN_DECIMAL_DIVISION_INEXACT = 1,
    KOFUN_DECIMAL_DIVISION_BY_ZERO = 2
} KofunDecimalDivision;

/* Stable spelling of an outcome, matching `docs/DECIMAL.md`. */
const char *kofun_decimal_division_name(KofunDecimalDivision outcome);

/*
 * Exact division. `out` receives the quotient only when `*outcome` is
 * `KOFUN_DECIMAL_DIVISION_EXACT`; otherwise it is a valid empty value.
 *
 * A quotient terminates exactly when, after reducing, the denominator has no
 * prime factor other than two and five. This is decided rather than
 * approximated: the divisor's factors of two and five are removed, and the
 * quotient is exact precisely when what remains divides the dividend.
 */
KofunDecimalStatus kofun_decimal_divide_exact(
    const KofunDecimal *left,
    const KofunDecimal *right,
    KofunDecimal *out,
    KofunDecimalDivision *outcome
);

/* --- explicit rounding and formatting (slice 5, issue #724) ------------- */

typedef enum {
    KOFUN_DECIMAL_HALF_UP = 0,
    KOFUN_DECIMAL_HALF_EVEN = 1,
    KOFUN_DECIMAL_TOWARD_ZERO = 2,
    KOFUN_DECIMAL_FLOOR = 3,
    KOFUN_DECIMAL_CEILING = 4
} KofunDecimalRounding;

const char *kofun_decimal_rounding_name(KofunDecimalRounding mode);

/*
 * Round to `target_scale`, then canonicalize the Decimal result. The scale and
 * mode are mandatory even when the particular value already fits, so callers
 * cannot acquire an ambient or data-dependent default.
 */
KofunDecimalStatus kofun_decimal_round(
    const KofunDecimal *value,
    long target_scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
);

/* Rounded division with an explicit destination scale and rounding mode. */
KofunDecimalStatus kofun_decimal_divide_rounded(
    const KofunDecimal *left,
    const KofunDecimal *right,
    long target_scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
);

/*
 * Parse signed decimal text into the canonical native value. Unlike source
 * literals this accepts a leading `+` or `-`, because formatted runtime text
 * must round-trip negative values too.
 */
KofunDecimalStatus kofun_decimal_parse(
    const char *text,
    size_t length,
    KofunDecimal *out
);

/*
 * Render exactly `display_scale` fractional digits. This never rounds: if the
 * requested scale would discard a non-zero digit it reports D007. Caller
 * frees the returned text.
 */
KofunDecimalStatus kofun_decimal_format(
    const KofunDecimal *value,
    long display_scale,
    char **out
);

/* --- Fixed[S] carrier (RFC-0015, issue #1661) ---------------------------- */

/*
 * The runtime half of `Fixed[S]`. RFC-0015 makes the payload the canonical
 * `KofunDecimal` itself -- "not a second mutable Fixed identity" -- so these
 * entry points take and produce `KofunDecimal`, and the static `S` exists
 * only at construction and formatting. No compiler calls them yet; #1250 is
 * the first caller.
 *
 * They differ from the value shim below in the one way RFC-0015 requires:
 * there is "no ambient rounding mode, clamp, fatal generated-program
 * shortcut, or partial value". Every failure is a returned status, and
 * reporting one allocates nothing. On any failure `out` is a valid empty
 * value, the input is unchanged, and no temporary survives.
 *
 * Ownership: an `out` argument must not own a payload when passed; it is
 * overwritten. A successful `out` is owned by the caller and released exactly
 * once by `kofun_fixed_drop`.
 */
#define KOFUN_FIXED_MIN_SCALE 0L
#define KOFUN_FIXED_MAX_SCALE KOFUN_DECIMAL_MAX_SCALE

/*
 * `Fixed.from_decimal(value, mode)` at the expected `Fixed[scale]`: round
 * `input` to `scale` under the explicit `mode`, then canonicalize. The result
 * is exactly `kofun_decimal_round`'s. A `scale` outside
 * `KOFUN_FIXED_MIN_SCALE..KOFUN_FIXED_MAX_SCALE` is D002 -- the compiler
 * refuses it statically as E408, so reaching the runtime with one is a
 * status, never an abort -- and an unknown mode is D006.
 */
KofunDecimalStatus kofun_fixed_from_decimal(
    const KofunDecimal *input,
    long scale,
    KofunDecimalRounding mode,
    KofunDecimal *out
);

/* Explicit `clone`: a deep copy into a fresh owner, or D004. */
KofunDecimalStatus kofun_fixed_clone(
    const KofunDecimal *source,
    KofunDecimal *out
);

/* `take`: `out` receives the payload and `source` is left empty. */
void kofun_fixed_move(KofunDecimal *source, KofunDecimal *out);

/*
 * Release the payload and leave `value` empty. Dropping an empty or
 * moved-from value does nothing, so cleanup can run unconditionally on every
 * path and still release each payload exactly once.
 */
void kofun_fixed_drop(KofunDecimal *value);

/*
 * The same four operations on `Float`, where they are binary64 and therefore
 * *not* exact. They exist here, beside the exact ones, because keeping the two
 * types apart is only meaningful if both are implemented and the difference is
 * observable — `0.1 + 0.2` is `0.3` in one and `0.30000000000000004` in the
 * other, and a corpus that showed only the Decimal side would not prove the
 * types are distinct.
 *
 * These are thin wrappers on the host's binary64 operations. That is the
 * point: `Float` is IEEE 754 binary64 with its ordinary behavior, including
 * infinities from division by zero rather than the checked outcome Decimal
 * gives. There is no rounding-mode argument because binary64 rounding is
 * round-to-nearest-even and is a property of the type, not a choice.
 */
double kofun_float_add(double left, double right);
double kofun_float_subtract(double left, double right);
double kofun_float_multiply(double left, double right);
double kofun_float_divide(double left, double right);

/* --- value shim for generated code (issue #723) --------------------------- */

/*
 * The operations above take an out-parameter and leave ownership to the
 * caller, which is right for a library but wrong for generated code: a Kofun
 * expression like `0.1 + 0.2 == 0.3` is a tree, and lowering a tree onto
 * out-parameters means inventing temporaries and threading frees through every
 * early return the surrounding program might take.
 *
 * These return borrowed pointers into an arena instead, so the lowering is a
 * direct structural map from the expression tree to a C expression. The arena
 * is released once at the end of the program.
 *
 * Ownership rule: nothing returned here is freed by the caller, and nothing
 * returned here survives `kofun_decimal_arena_release`.
 *
 * A resource limit is fatal on this path. Frozen decision 8 forbids clamping
 * or changing representation, and a generated program has no value to
 * substitute, so the shim reports the profile's own diagnostic code and stops
 * rather than continuing with something that is not the answer.
 */
KofunDecimal *kofun_decimal_value_literal(const char *text, size_t length);
KofunDecimal *kofun_decimal_value_from_int(int64_t value);
KofunDecimal *kofun_decimal_value_add(
    const KofunDecimal *left,
    const KofunDecimal *right
);
KofunDecimal *kofun_decimal_value_subtract(
    const KofunDecimal *left,
    const KofunDecimal *right
);
KofunDecimal *kofun_decimal_value_multiply(
    const KofunDecimal *left,
    const KofunDecimal *right
);
KofunDecimal *kofun_decimal_value_negate(const KofunDecimal *value);
KofunDecimal *kofun_decimal_value_round(
    const KofunDecimal *value,
    long target_scale,
    KofunDecimalRounding mode
);
KofunDecimal *kofun_decimal_value_divide_rounded(
    const KofunDecimal *left,
    const KofunDecimal *right,
    long target_scale,
    KofunDecimalRounding mode
);
KofunDecimal *kofun_decimal_value_parse(const char *text, size_t length);
const char *kofun_decimal_value_format(
    const KofunDecimal *value,
    long display_scale
);

/*
 * Checked `/` stays a value.  The outcome is always observable; `value` is
 * meaningful only for `KOFUN_DECIMAL_DIVISION_EXACT`.  Keeping the result in
 * the same program-lifetime arena lets generated code bind and print it
 * without unwrapping, trapping, or inventing an ambient rounding policy.
 */
typedef struct {
    KofunDecimalDivision outcome;
    KofunDecimal value;
} KofunDecimalResult;

KofunDecimalResult *kofun_decimal_value_divide_exact(
    const KofunDecimal *left,
    const KofunDecimal *right
);
const char *kofun_decimal_value_division_name(
    const KofunDecimalResult *result
);

/* Deterministic literal construction for generated binary64 code. */
double kofun_float_value_literal(const char *text, size_t length);
void kofun_decimal_arena_release(void);

#endif
