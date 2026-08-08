# Decimal design

Status: accepted language design for issue #545. The executable
[`stdlib/decimal`](../stdlib/decimal/) checkpoint now uses the compiler-native
arbitrary-precision value through slice 5: literals, exact arithmetic, explicit
rounding and rounded division, and exact format/parse boundaries. It no longer
carries the former signed-64-bit significand implementation.

## Goals

`Decimal` is Kofun's exact base-10 value type for money, ledgers, measurements,
and ordinary fractional arithmetic. It must make these statements true without
passing through binary floating point:

```kofun
0.1 + 0.2 == 0.3
1.20 == 1.2
```

The design has five non-negotiable properties.

- Unsuffixed fractional literals denote `Decimal`, not `Float`.
- Decimal arithmetic never rounds implicitly.
- No operation implicitly promotes between `Int`, `Decimal`, and `Float`.
- All backends observe the same value, result, diagnostic, and explicitly
  requested textual rendering.
- Resource limits may reject an operation explicitly, but may not change its
  mathematical result.

`Float` remains the opt-in binary64 type for numerical computing and native
library interoperability. Decimal is not a replacement for BLAS, LAPACK, FFT,
NaN, infinities, or signed zero.

## Abstract value and canonical form

A Decimal value is a pair `(significand, scale)` denoting

```text
significand × 10^(-scale)
```

The significand is a signed arbitrary-precision integer stored in binary.
Semantically, scale is an unbounded signed integer; a conformance profile may
choose a bounded physical encoding and reject values outside it explicitly. A
negative scale therefore represents positive powers of ten without
materializing zero digits:

```text
(12, 1)  = 1.2
(12, 0)  = 12
(12, -2) = 1200
```

Values have one canonical form.

- Zero is `(0, 0)`.
- A nonzero significand has no factor of ten.
- Removing one trailing decimal zero from the significand decrements scale by
  one and does not change the value.

Consequently `(120, 2)` normalizes to `(12, 1)`. `Decimal` is opaque: literal
construction, public constructors, deserialization, FFI adapters, and backend
boundaries must all establish this invariant. Equality, ordering, and hashing
use the mathematical value and therefore agree with canonical representation.
Decimal has no NaN, infinity, signed zero, or payload representation.

### Why a variable-length binary significand

The language representation uses a variable-length significand rather than
BCD or a fixed `i128`.

- BCD makes decimal digit shifts and digit inspection cheap, but wastes space
  and receives little help from general-purpose CPUs.
- A fixed `i128` makes the validity of ordinary exact expressions depend on an
  arbitrary magnitude boundary. It would also make associativity fail through
  overflow unless every operator returned a checked result.
- A binary big integer gives exact integer arithmetic, compact storage, and a
  straightforward implementation on all target backends.

An implementation may keep small values inline in `i64` or `i128` and promote
on overflow. This is an unobservable optimization: the threshold must not
alter equality, rounding, diagnostics, or backend agreement. Falling back to
`Float` is never allowed.

A conformance profile may impose declared limits on digit count, scale
magnitude, allocation, or operation cost. Every backend registered for that
profile must use the same observable limits and diagnostics. Exceeding a limit
produces a stable resource error before an unbounded allocation. It never
clamps, wraps, rounds, or silently changes representation.

### Profile v1

The thresholds this document previously deferred are now introduced, and are
versioned as one unit — a limit cannot move without the version moving with it.

| Limit | Value |
|---|---|
| Profile version | 1 |
| Significand digits | 4096 |
| Scale | `-6144 .. 6144` |

| Code | Condition |
|---|---|
| `D001` | significand exceeds the digit limit |
| `D002` | scale outside the range, before or after canonicalization |
| `D003` | not a literal this grammar accepts |
| `D004` | allocation refused |
| `D005` | rounded division by zero |
| `D006` | invalid rounding mode reached the runtime boundary |
| `D007` | formatting at the requested scale would discard digits |

Both boundaries and their one-over cases are gated, so exceeding a limit is
observably a `D00x` code and never a clamped value. Leading zeros do not
consume the digit budget, and trailing zeros are canonicalized away before the
scale is checked, so `1000.000` costs one digit and not seven.

The representation is `bootstrap/stage2/decimal_v1.c`; `task decimal` is its
gate. A significand is a base-2^32 magnitude with no width ceiling, and the
small-value path is proven unobservable by constructing the last inline value
and the first promoted one and comparing every public observation.

## Literal syntax and lexing

The target literal grammar is:

```text
digits          = digit, { [ "_" ], digit }
exponent        = ( "e" | "E" ), [ "+" | "-" ], digits
decimal         = digits, ".", digits, [ exponent ]
                | digits, exponent
float64         = digits, "f64"
                | digits, ".", digits, [ exponent ], "f64"
                | digits, exponent, "f64"
```

Examples:

```kofun
42          # Int
0.1         # Decimal: exactly one tenth
6.02e23     # Decimal
1e-9        # Decimal
0.1f64      # Float: explicitly binary64
42f64       # Float
```

There is no Decimal suffix because Decimal is the default fractional type.
`f64` is part of the numeric token, not an identifier or an implicit
conversion. A future additional binary-float width requires a distinct suffix.

The lexer must use maximal munch with the range exception:

```text
1.0   -> one Decimal token
1e3   -> one Decimal token
1f64  -> one Float token
1..2  -> Int(1), range(..), Int(2)
```

`1.`, `.5`, malformed exponents, and underscores outside positions between two
digits are lexical errors. Stage 2 reports all of them as **`E2S98`**, before a
token tape exists and with no artifact written. The token retains the original
digit sequence and the positions of the decimal point, exponent, and suffix.
The lexer must not convert through a host `double`; semantic construction
removes underscores, builds the integer significand, applies the exponent to
scale, and normalizes.

`_1` is not in that list. It is a well-formed identifier under the identifier
grammar rather than a numeric literal, and it reports as an unknown binding at
its own byte. The underscore rule constrains the numeric grammar; it does not
remove an identifier spelling.

The scanner stays permissive about `.` on purpose, and the malformed forms are
diagnosed from the token sequence instead. Deciding between the range operator
and a fraction inside the scanner needs a character of lookahead at exactly the
point where the range exception above says not to — so `1..2` and `1.` both
lex, and `E2S98` reads the result, where `..` and a lone `.` are already
distinct tokens.

A well-formed Decimal or Float literal now lowers through the Stage 2 C11
backend. Decimal construction never passes through a host `double`; Float
construction uses the deterministic correctly-rounded binary64 conversion.
The versioned D001/D002 limits are still checked before an artifact is written
and again by the generated runtime. Backends without that runtime declare the
`decimal-arithmetic` corpus unsupported, with a reason, in
`tests/conformance/capabilities.tsv`.

This deliberately revises older planning text that calls every unsuffixed
fractional or scientific literal a `Float`. That text is migration input, not
the final Decimal rule. Parser and conformance changes must update the
normative syntax documents atomically when literal support is implemented.

## Typing and conversions

There is no implicit numeric promotion.

```kofun
1 + 0.5          # type error: Int + Decimal
0.5 + 1.0f64    # type error: Decimal + Float
```

Each numeric operator resolves against one operand type. Conversions use named,
explicit operations:

```kofun
Decimal.from_int(count)
Float.from_decimal(value, rounding: ...)
Decimal.from_float(value, policy: ...)
```

The conversion APIs must state whether they preserve the exact source value,
round to a requested decimal scale, or reject an inexact result. A displayed
`Float` string is not silently treated as the exact binary value, and a binary
value is not silently treated as the decimal text a user originally typed.

Of the three conversions, `Decimal.from_int` is implemented because it is exact
for every input. The two cross-radix conversions remain rejected by name: a
rounding mode alone does not settle their complete binary/decimal policy.
Slice 5 instead implements the operations whose destination is unambiguous:
`Decimal.round`, `Decimal.divide`, `Decimal.format`, and `Decimal.parse`. No
conversion or operation acquires an ambient policy.

An unknown member of a numeric type is an unknown *conversion*, and says so.
Before the conversions existed, `Decimal.from_text("1")` reported an unknown
lexical binding named `Decimal`, which described the compiler's internals
rather than the program.

A conversion is one primary. `Decimal.from_int(1) + 1` mixes `Decimal` and
`Int` and is rejected; `Decimal.from_int(1) + 1.5` is two `Decimal` operands
and is not.

A mixed-arithmetic rejection names the conversion that fixes the pair —
`Decimal.from_int` for `Int` with `Decimal`, `Float.from_decimal` for `Decimal`
with `Float`. There is no `Int`/`Float` conversion in either direction, so that
pair is told so rather than pointed at a function that does not exist. That is
a gap in the set above, not in the checker: `Int` to binary64 is exact only
below 2^53, so it needs the same policy argument the other inexact conversions
take, and it should be settled when they are.

Annotations are checked in both directions. `let x: Decimal = 1` is rejected
for the same reason `let x: Int = 1.5` is: a rule that rejected only the
narrowing direction would still be promoting, one way and quietly.

```kofun
let a: Decimal = 1.5     # ok
let b: Float = 1.5f64    # ok
let c: Int = 1.5         # type error: value is Decimal
let d: Decimal = 1       # type error: value is Int
let e: Decimal = 1.5f64  # type error: value is Float
```

An unannotated binding takes its literal's type, so `let f = 1.5` is a
`Decimal` binding and `let g = 1.5f64` is a `Float` one.

## Exact arithmetic

Addition and subtraction align scales with exact powers of ten. Multiplication
multiplies significands and adds scales. Results normalize to canonical form.
These operations do not accept a rounding mode because they never round.

Negation, absolute value, comparison, and equality are exact. `%` and `//`
must specify their same-type quotient/remainder relation and preserve the
identity

```text
left = (left // right) * right + (left % right)
```

for every nonzero right operand. Their final signed convention must be landed
with executable positive and negative examples before those operators become
available for Decimal.

### Division

Decimal division has two explicit forms.

1. Exact division either returns the unique terminating Decimal result or a
   checked `InexactDivision` / `DivisionByZero` result.
2. Rounded division requires both a destination scale and a rounding mode.

The `/` operator is the exact form. Its static result is a checked result; it
does not unwrap, trap, consult a process-wide context, or choose a rounding
mode:

```kofun
let quarter = 1.0 / 4.0  # DecimalResult containing 0.25
let third = 1.0 / 3.0    # DecimalResult containing InexactDivision
let bad = 1.0 / 0.0      # DecimalResult containing DivisionByZero
```

A quotient terminates exactly when, after reducing numerator and denominator,
the denominator has no prime factors other than two and five. Rounded division
uses a named API:

```kofun
Decimal.divide(
    amount,
    divisor,
    scale: 2,
    rounding: HalfEven,
)
```

Even if the particular operands happen to divide exactly, this API still
requires both arguments. There is no thread-local, module-local, build-profile,
or ambient default rounding context.

## Rounding

Every operation that can discard digits requires a destination scale and one
of these modes:

| Mode | Result |
| --- | --- |
| `HalfUp` | nearest; an exact tie goes away from zero |
| `HalfEven` | nearest; an exact tie makes the retained digit even |
| `TowardZero` | discard digits toward zero |
| `Floor` | toward negative infinity |
| `Ceiling` | toward positive infinity |

The names above define Kofun behavior for positive and negative values.
`HalfUp` therefore maps both `2.5` to `3` and `-2.5` to `-3`.

Rounding operates on the exact value. It must not first convert to `Float`, and
it must produce the same carry behavior at every magnitude:

```text
round(1.999, scale=2, HalfUp) = canonical Decimal 2
Fixed[2].from_decimal(1.999, HalfUp) = scale-preserving 2.00
round(2.5,   scale=0, HalfEven) = 2
round(3.5,   scale=0, HalfEven) = 4
```

A plain Decimal normalizes after rounding, so formatting scale is not part of
its identity. Code that must retain `2.00` uses `Fixed` or an explicit format
scale.

### Formatting and parsing

The bounded Stage 2 surface uses positional arguments because named arguments
are not part of this compiler profile:

```kofun
let rounded = Decimal.round(value, 2, HalfEven)
let quotient = Decimal.divide(left, right, 2, HalfUp)
let text = Decimal.format(rounded, 2)
let restored = Decimal.parse(text)
```

Formatting has an explicit non-negative display scale and never rounds. If the
value needs more fractional digits than requested, it fails with `D007` rather
than discarding them. Successful formatted text parses back to the same
canonical value; requested trailing zeroes are a text observation, not part of
Decimal identity.

## Fixed point

`Fixed[scale]` is the target scale-carrying type. Its scale is a compile-time
integer parameter, and assignment or construction requires an explicit
rounding mode whenever digits may be discarded:

```kofun
let tax: Fixed[2] = Fixed.from_decimal(
    exact_tax,
    rounding: HalfUp,
)
```

Values with different scales are different types. Cross-scale conversion is
explicit. Addition and subtraction of the same `Fixed[S]` type retain `S` and
are exact. Exact multiplication has type `Fixed[A] * Fixed[B] -> Fixed[A+B]`.
Converting that product to a different target scale requires an explicit mode
when it discards digits. Other operations that can exceed a requested scale
likewise specify their result type and rounding boundary.

### Interim profile: `runtime-scale/v1`

Literal integer const generics are implemented for nominal record identity and
the bounded ordinary C11 Stage 2 specialization.

Literal integer const generics already distinguish Fixed[2] from Fixed[3]; that type-system checkpoint is not a Decimal-backed Fixed[scale] implementation.

**`runtime-scale/v1` is what native Decimal operations ship.** Destination and
display scales are ordinary runtime `Int` arguments. `stdlib/decimal` declares
no Decimal-backed `Fixed` value, constructor, conversion, or arithmetic, so no
Decimal value carries or statically checks a storage scale. The earlier
`Fixed { significand: Int, scale: Int }` checkpoint was removed when the stdlib
moved to native Decimal; keeping it would preserve the fixed-width
representation under a second name.

The type system can therefore express distinct nominal scale identities, but
current stdlib Decimal operations do not use them. Explicit runtime arguments
prevent implicit rounding, but provide **no static scale safety**. A future
Decimal-backed Fixed implementation must reuse the existing const-generic
identity, move scale into the Decimal-backed value type, and replace this
profile rather than presenting runtime arguments as that guarantee.

## Laws

Arbitrary-precision exact Decimal addition forms a commutative monoid.
Multiplication is associative and distributes over addition. These statements
hold over mathematical Decimal values because ordinary operations neither
overflow nor round.

Resource exhaustion is an explicit operation failure, not a different Decimal
value. Law evidence must state whether it proves the value operation or a
bounded implementation profile.

Exact same-scale Fixed addition is associative while its declared resource
profile succeeds. A computation that rounds after each store or cross-scale
conversion is not generally associative. Such law declarations must name the
scale and rounding boundary rather than inheriting Decimal laws.

`Float` is not forbidden in a law declaration at the type level. Instead, the
law checker evaluates the claim and reports a counterexample when binary64
addition violates associativity. Preventing the declaration would hide useful
evidence and would make the law system less general.

Initial executable evidence must include:

- bounded exhaustive Decimal addition associativity with no overflow shortcut;
- the known binary64 associativity counterexample;
- positive and negative tie cases for every rounding mode;
- distributivity and normalization cases across differing scales;
- explicit failures for division by zero, inexact exact-division, and resource
  limits.

The library-owned v2 evidence now executes Decimal addition associativity over
its declared ordered finite domain and records the result as
`bounded-exhaustive`. A separate versioned artifact records the expected Float
associativity failure and its witness. The ledger/tax fixture is compared
digit-for-digit with an independent BigInt scaled-integer reference, and the
strict differential gate turns every unsupported declared backend into a
failure instead of a skip. These are release evidence for the current bounded
profile, not compiler support for `law` declarations and not a universal
Decimal proof.

Decimal has an infinite carrier, so execution over a finite set cannot produce
`proven-finite` evidence for Decimal as a whole. Slice 5's native checkpoint is
labeled `bounded-examples`; even a future exhaustive finite model must remain
`bounded-exhaustive`, not a universal proof. A universal Decimal law claim
requires future proof-kernel evidence labeled `proven`.

## Relationship to IEEE decimal formats

The language value described here is arbitrary precision and is not IEEE
decimal64 or decimal128. Adapters for those interchange formats may be added,
but they must require an explicit precision, exponent range, rounding mode,
and overflow policy. IEEE NaN, infinity, signed zero, and payload behavior do
not enter the core Decimal value through an adapter implicitly.

This separation gives Kofun deterministic language arithmetic while retaining
a path to databases, financial protocols, and hardware or library decimal
formats.

## Deferred decisions

The following details are intentionally not invented by this design:

- the first cross-backend digit, scale, allocation, and operation-cost limits;
- stable diagnostic codes for those resource failures;
- the implementation schedule for Decimal-backed `Fixed[scale]` and for const
  expressions or inference beyond the shipped literal nominal profile;
- locale-aware formatting and exponent-selection thresholds beyond the exact
  fixed-display-scale API;
- the signed quotient/remainder convention for Decimal `//` and `%`;
- concrete IEEE decimal, database, and wire-format adapters.

These are separate design slices. They may not introduce implicit rounding,
backend-specific observable limits within one conformance profile, or a public
noncanonical Decimal representation.

## Migration from the checkpoint

The migrated `stdlib/decimal` checkpoint demonstrates compiler-native exact
arithmetic, all five signed rounding modes, explicit rounded division,
format/parse round trips, bounded evidence, and a native ledger/tax example.
The Stage 2 C11 backend and direct runtime gates establish arbitrary precision
for their declared profile. `Fixed[scale]`, general compiler law declarations,
other backend runtimes, and interchange formats remain open.

Implementation should land in this order:

1. update the numeric token contract and parser with byte-exact literal tests;
2. add the arbitrary-precision runtime representation and canonicalization;
3. enforce same-type operators and explicit conversions in the type checker;
4. implement exact operations and checked exact division across every backend;
5. implement explicit rounding and formatting, then migrate the checkpoint
   (landed in issue #724);
6. add Decimal-backed `Fixed[scale]` on the existing literal const-generic
   identity checkpoint;
7. connect versioned law evidence and backend differential tests.

Each step must reject unsupported behavior explicitly. A backend that lacks the
new representation may not lower through `Float`, use a smaller fixed integer
silently, or disappear from declared conformance.

## Implementation acceptance

Language-level Decimal is not complete until all of the following hold.

- `0.1 + 0.2 == 0.3` is accepted and true on every declared backend.
- Literal tokens preserve exact digits and distinguish `1.0`, `1..2`, and
  `1.0f64`.
- The public representation is arbitrary precision; small-integer
  optimizations are observationally invisible.
- No `Int`/`Decimal`/`Float` expression receives an implicit promotion.
- Exact division, inexact division, division by zero, and every rounding mode
  have deterministic checked behavior.
- `Fixed[scale]` or an explicitly named interim profile carries storage scale
  without pretending runtime scale is static. The interim profile is
  `runtime-scale/v1` above, and `task decimal` holds this document to it.
- Decimal laws pass at their stated assurance level and the Float
  associativity counterexample is reported.
- The ledger/tax example agrees digit for digit with its decimal reference.
- Resource failures and backend omissions fail conformance instead of changing
  results or weakening evidence.
