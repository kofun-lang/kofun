# Kofun runtime semantics

The normative rules live in `spec/semantics.md`. This document records
the numeric decision that backend and standard-library implementers must not
inherit accidentally from their host language.

## `Int` and overflow

`Int` is always a signed 64-bit value with the range
`-9223372036854775808 .. 9223372036854775807`.

Kofun uses checked arithmetic. Overflow in integer `+`, `-`, `*`, unary `-`,
or `INT64_MIN // -1` is runtime error `R010` and exit status 1. It never wraps
or saturates, and debug and release builds have identical behavior. The
diagnostic names the operator.

Checked arithmetic was selected because it makes mistakes observable without
making `Int` heap allocated. Ordinary arithmetic remains checked; the explicit
wrapping operation is `wrapping_add`, below.

## Bit operations

`Int` carries eight bit operations, spelled as postfix methods (RFC-0013).
There are no bitwise operator symbols: `|` already delimits the `par` scope
token and separates ADT variants, so a symbol set would have covered four of
the five and left the fifth spelled differently in the same expression.

| Method | Meaning |
|---|---|
| `a.and(b)` | bitwise AND |
| `a.or(b)` | bitwise OR |
| `a.xor(b)` | bitwise XOR |
| `a.not()` | bitwise complement |
| `a.shl(n)` | left shift, checked |
| `a.shr(n)` | right shift, arithmetic |
| `a.rotr(n, width)` | right rotate within `width` bits |
| `a.wrapping_add(b, width)` | addition modulo `2^width` |

These methods exist only on an `Int` receiver, and every parameter is
positional, unlabelled, and `Int`. The eight names remain ordinary function
and field names anywhere else. Receiver resolution leads; then each ordinary
argument is checked left to right (label before type), followed by an
expression trailing lambda and finally arity. A non-`Int` receiver or argument
is `E2S168`; labels, expression trailing lambdas, and arity are `E2S169`.
Block trailing lambdas remain the parser-owned `E2S158` boundary.

The four decisions an implementer must not inherit from their host language:

- **Operands are two's complement.** `(-1).and(255)` is `255` and `(0).not()`
  is `-1`. A negative operand is ordinary, not refused.
- **`shr` is arithmetic.** It replicates the sign bit, so `(-8).shr(1)` is
  `-4`. Kofun has no unsigned type, so there is no second logical form; a
  caller who wants a logical shift masks first. C leaves this
  implementation-defined, which is exactly why it is stated here.
- **A shift count outside `0..63` is `R011`,** checked before overflow, not a
  mask and not a
  saturation. Masking is the behaviour that computes `x.shl(64)` as `x`, which
  is a wrong answer that looks like an answer. C leaves it undefined. A width
  outside `1..64` is `R011` for the same reason.
- **`shl` traps on overflow as `R010`** when the mathematical value
  `a × 2^n` leaves signed Int64. This definition does not rely on an executable
  `**` operator. A shift is not an exception to ordinary checked arithmetic,
  which is why `wrapping_add` exists as a separately named operation rather
  than as a mode.

`rotr` and `wrapping_add` take an explicit `width` because Kofun has one
integer type. Both reduce their value operands modulo `2^width` first, and
`rotr` reduces its already-range-checked count modulo `width`, so a caller
working in 32 bits does not mask before every call. `rotr` checks `width`
before `n`; thus `(1).rotr(64, 0)` reports the width error, while
`(1).rotr(64, 32)` reports the count error. The result is the width-bit
pattern, non-negative below width 64; at width 64 the high bit maps to signed
Int64, so `0x8000000000000000` is `-9223372036854775808` and all ones is `-1`.
Runtime diagnostics use the exact `error[CODE]: MESSAGE\n` framing and carry no
source span. The overflow line is exactly:

```text
error[R010]: integer overflow in `shl`
```

It terminates with one newline. Range errors are `R011` lines naming the method
and count or width bound.

The eight names are not reserved. `fn and()` still declares, `type P = { xor:
Int }` still has a field, and both keep working in a file that uses the
operations: a name is meaningful only as a member of an `Int` receiver, exactly
as `join` is.

## Integer division

`//` floors toward negative infinity. `%` is defined with the paired floor
quotient, so a non-zero remainder has the divisor's sign.

```text
-7 // 2 == -4
-7 % 2 == 1
7 // -2 == -4
7 % -2 == -1
```

A zero divisor in `//` or `%` is `R010`, writes one canonical diagnostic line
to stderr, and exits with status 1. Backends must check runtime values, not
only zero literals.

`/` is not defined on `Int` and `Int / Int` is a compile error, so `//` is the
only integer quotient. See `spec/semantics.md`.

## Conformance

Every registered backend executes the same `.kofun` corpus. The active
`c11-stage1` backend passes all twelve numeric cases, and
`tests/conformance/stage1-adapter/check.sh` is what runs them. The runner
compares stdout, stderr, and exit status exactly. Unsupported compilation is an
explicit, reported skip and reduces coverage; it never counts as a silent pass.

Three of the twelve are rejection cases rather than runs — `/` has no meaning
on `Int`, and two numeric conversions are inexact — so what every backend must
agree on there is that it compiles nothing and leaves no artifact.

A backend name has to mean the compiler it names. `c11-stage1` reaches the
Stage 1 seed directly, not through `bin/kofun`, whose fallback order would
answer with Stage 2 for every source Stage 2 accepts; and the C it emits is
checked for the Stage 1 provenance banner before it is compiled.

See `spec/backend-differential-contract.md` and
`tests/conformance/numeric/README.md` for the runner contract and corpus.
