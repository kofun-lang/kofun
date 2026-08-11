# RFC-0015: Decimal and Fixed keep one value model across direct backends

- Shepherd: hjosugi
- Opened: 2026-08-11
- Status: accepted
- Decided: 2026-08-11

This RFC decides [#1249](https://github.com/kofun-lang/kofun/issues/1249)
and [#1255](https://github.com/kofun-lang/kofun/issues/1255). It refines the
accepted value semantics in `docs/DECIMAL.md` without claiming a new compiler
or backend capability.

## Summary

`Fixed[S]` is a compiler-known nominal wrapper over the existing arbitrary-
precision Decimal carrier. `S` is type identity, not mutable runtime identity.
Construction and cloning are typed, fallible operations; conversion back to
Decimal is exact. The first profile admits literal `S` in `0..6144`, exact
same-scale addition/subtraction, exact scale-additive multiplication, and exact
formatting at `S`. Fixed division is deferred to the existing explicit Decimal
division API.

The current direct x86-64 and AArch64 target identities remain linker-free
static ELF. They eventually emit the bounded Decimal/Float runtime as target
machine code. Bare `wasm32` remains its current Int-only binding; the distinct
`wasm32-hostabi1` target owns Decimal-capable Wasm. Every supporting target
uses Decimal resource profile v1 and D001-D007.

## Motivation

The current C11 Stage 2 Decimal implementation is executable, but copying its C
runtime into another backend would silently introduce a host compiler or
linker dependency. The direct targets exist specifically to avoid that.

The type system can distinguish `Fixed[2]` and `Fixed[3]`, while the shipped
Decimal surface has only runtime scales. A test-local Int significand is not an
acceptable product carrier. The carrier and backend strategy therefore have to
be fixed together.

## Detailed design

### Fixed[S]

The profile ID is `kofun.fixed-decimal/v1`.

- `S` is an integer literal in `0..6144` and participates in the canonical
  constructed TypeId. The wider generic identity bound does not enlarge this
  executable numeric domain.
- The runtime payload is the canonical `KofunDecimal` value. It stores the
  mathematical Decimal scale required by canonicalization, not a second
  mutable Fixed identity. The static `S` determines validation and formatting.
- `Fixed[2]` and `Fixed[3]` are distinct invariant nominal types even when the
  canonical Decimal payload is equal.
- The contextual construction form is:

  ```kofun
  let amount: Fixed[2] = Fixed.from_decimal(value, HalfEven)?
  ```

  The expected type supplies `S`. An unconstrained call is E407. The spelling
  `Fixed[S].from_decimal` is not a separate v1 form.
- Construction returns `Result[Fixed[S], DecimalError]`. It rounds only under
  the explicit mode and reports D001-D004; there is no ambient rounding mode,
  clamp, fatal generated-program shortcut, or partial value.
- `Decimal.from_fixed(value)` is exact and canonicalizes trailing zeroes.
  Assignment/coercion in either direction is never implicit.
- A Fixed value is `Owned`, non-Copy, and follows Decimal allocation lifetime.
  `read` borrows, `edit` is unique, and `take` transfers. `clone` is explicit
  and returns `Result[Fixed[S], DecimalError]` because allocation can fail.
- `Fixed[S] + Fixed[S]` and subtraction return `Fixed[S]` exactly.
  `Fixed[A] * Fixed[B]` returns `Fixed[A+B]` or D002 if `A+B` leaves the profile.
  Division stays `Decimal.divide(left, right, scale, mode)` until a separate
  Fixed result-scale rule is accepted.
- `Fixed[S].format()` is exact and always emits exactly `S` fractional digits.
  Thus `Fixed[2]` can display `2.00`, while `Decimal.from_fixed` is the canonical
  Decimal value `2`.

HalfUp and HalfEven retain their accepted positive and negative tie behavior.
For example `1.999` to `Fixed[2]` under HalfUp is `2.00`; `2.5` to `Fixed[0]`
under HalfEven is `2`; `3.5` is `4`.

### Backend set and target identity

The conformance registry may name six adapters:

1. `c11-stage1`;
2. `c11-stage2`;
3. `native-x86_64`;
4. `native-aarch64`;
5. `wasm32-node` for the existing bare binding; and
6. `wasm32-hostabi1` for the versioned object-capable binding.

"Every declared backend" means every adapter whose capability row says the
specific Decimal or Fixed corpus is supported. An adapter recorded as
unsupported must refuse with no artifact. Bare `wasm32-node` remains a valid,
deliberately Int-only target and does not satisfy Wasm Decimal coverage.

`wasm32-hostabi1` uses the existing checked 64-KiB arena and its versioned
imports/exports. Arena exhaustion maps to D004 before publishing a partial
result or artifact. The nominal 4096-digit and scale limits remain the same;
the smaller live arena can make D004 observable sooner, but may not alter a
successful mathematical value.

### Direct native runtime and ABI

Option A from #1255 is selected. Existing direct native target commands retain
their current architecture:

- no C compiler, assembler, linker, libc, or shared Decimal runtime is invoked;
- the compiler lowers the common Decimal IR and emits the bounded allocator,
  limb operations, formatting, and binary64 operations as deterministic target
  machine code in the ELF image;
- Linux syscalls remain the external ABI;
- x86-64 and AArch64 share the same frontend, numeric IR, value layout, call
  ABI, status mapping, and resource profile; and
- any target-specific instruction sequence is differentially checked against
  the common model and the C11 checkpoint.

The value ABI is an owned descriptor containing sign, canonical scale, limb
length/capacity, and allocated limb storage. Descriptor fields and call status
are versioned; callers never free a Decimal using a foreign allocator. Copy is
explicit allocation, move transfers descriptor ownership, and every failure
leaves outputs uninitialized/absent and releases temporary storage.

### Decimal and Float observations

Supporting targets implement Decimal v1 exactly: 4096 significand digits,
scale `-6144..6144`, exact arithmetic/division, five rounding modes, canonical
parse/format, and D001-D007. There is no substitution through Int, Float, a
host decimal library, or a lower limit presented under the same profile.

Float is a separate IEEE-754 binary64 profile. It specifies literal rounding,
`+ - * /`, comparison including unordered NaN, signed zero observations,
infinity, and canonical formatting. Decimal never inherits NaN/infinity or
hardware rounding. Cross-target tests include the known non-associativity
witness and raw-bit or canonical-text observations where the language exposes
them.

### Promotion matrix

A target changes a Decimal corpus from unsupported only after it executes:

- literals, canonical equality, parse and format;
- exact `+ - *` and exact/inexact division;
- every rounding mode with positive/negative ties;
- D001-D007 and allocation cleanup;
- O0/O2, repeated/path/order builds; and
- differential results against the common Decimal model.

`decimal-fixed` is a separate capability row and never advances merely because
plain Decimal does.

## Semantics

Decimal and Fixed mathematical values are target-independent. Resource errors
are explicit outcomes rather than alternate values. The same successful input
has the same canonical value and text on every supporting target. A target that
cannot meet the profile refuses before output instead of lowering to Float or a
fixed-width approximation.

## Diagnostics

D001-D007 keep their existing meanings. Fixed adds design-time compiler codes:

| Code | Meaning |
|---|---|
| E407 | `Fixed.from_decimal` has no expected `Fixed[S]` result type. |
| E408 | `S` is not a literal in `0..6144`. |
| E409 | an implicit cross-scale or Decimal/Fixed conversion was requested. |

The backend-independent diagnostic names the selected profile and target. It
never exposes allocator addresses or host-library text.

## Ownership and effects

Decimal and Fixed allocation is an explicit fallible value operation. Values
are owned and deterministically released. Read-only numeric operations may be
semantically pure while returning a resource error; allocation does not grant
host authority. Wasm arena handles and native heap descriptors cannot cross
their target ABI unwrapped.

## Alternatives

A distinct Fixed significand carrier is rejected because it duplicates the
arbitrary-precision implementation and risks drift. A mutable runtime scale is
rejected because it would make two static Fixed types observationally alias.
Fatal construction is rejected for the new surface; a Rust/Zig-class systems
language needs the resource boundary in its type.

Linked native targets under existing names are rejected because they destroy
the direct-ELF contract. A separately named linked interoperability target may
be proposed later. Widening bare `wasm32` is rejected because target identity
already names a different import/export and memory model.

## Drawbacks

Typed failure makes Fixed construction more verbose than the design-era direct
assignment. Emitting an arbitrary-precision runtime twice is more work than
linking one C object. A 64-KiB Wasm arena can report D004 in workloads that fit
on native even though successful values remain identical.

## Compatibility and migration

Category: `additive`. No current compiler implements Decimal-backed Fixed, and
unsupported direct/Wasm Decimal inputs keep refusing. Existing C11 Decimal v1
bytes and D001-D007 meanings stay unchanged. The design-era Fixed example gains
`?` because the previously unspecified resource boundary is now a typed result;
no accepted executable program uses that form.

## Implementation plan

1. Land #1254 so Stage 1 evidence cannot borrow Stage 2.
2. Implement #1249-#1253 on C11 Stage 2 under the Fixed profile.
3. Add a common numeric IR/ABI harness, then x86-64 and AArch64 slices together.
4. Add the `wasm32-hostabi1` conformance adapter and bounded arena operations.
5. Promote plain Decimal, Float, and Fixed capability rows separately.

## Validation

`task fixed-decimal-profile` and `task decimal-backend-profiles` validate the
decision contract and fail mutations that introduce implicit conversion, a
host linker, a shared runtime, a changed target identity, or weaker resource
limits. The accepted artifact also requires `task decimal const-generics
rfc-registry capabilities release-claims repository-check` and full verify.

## Unresolved questions

Fixed division/result-scale semantics, hardware decimal adapters, locale-aware
formatting, non-Linux native ABIs, and arena growth are separate amendments.
None may introduce implicit rounding or a hidden hosted linker.
