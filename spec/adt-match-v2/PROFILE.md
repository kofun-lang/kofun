# ADT match v2 profile

The first general production ADT-match profile beyond flat zero/one-`Int`
enums. Ten decisions were settled on
[#1281](https://github.com/kofun-lang/kofun/issues/1281) on 2026-08-14; this
file is the normative form of all ten, and `model.mjs` is the same contract
executable so each can be mutated before any of it exists in the compiler.

It changes no compiler and claims no backend. #1282 and the later
HIR, checker, lowering, ownership, result, and backend children implement
against it.

## 1. Payload shape

Zero or one payload TypeRef per constructor. Multiple logical fields use **one
nominal record payload**. There is no tuple layout and no tuple syntax.

This is a bounded widening of an accepted carrier rather than a new feature:
nominal records already work in Stage 2, and `E2S32` already reports the
one-`Int` limit at the constructor's own span, so the diagnostic site is
correct today and only its answer changes.

## 2. The pattern fragment

Admitted: constructor patterns with zero or one payload subpattern, wildcard,
catch-all binding, parentheses, nested constructors, and or-patterns. `Int`
literals are admitted exactly where the current enum-value slice already
admits them.

**Refused in v2, each with a stable diagnostic**: ranges, and record
subpatterns. Bind the payload and project fields in the arm body. These are v2
boundaries, not promises — a later profile may admit them, and until it does
the refusal is the contract.

## 3. Or-pattern bindings

Every alternative binds identical **normalized names, resolved types, field
paths, and ownership modes**. One stable `BindingId` per arm body, shared
across alternatives.

All four parts, not the name. Comparing names alone is the implementation an
unwary reader writes, and it accepts `Ready(p: Point) | Failed(p: Int)` —
one name, two types. The model takes its binding-identity function as a
parameter for exactly this reason, and the gate passes a name-only key as a
mutation: if the other three parts were decorative, that mutation would pass.

## 4. Scrutinee access

The mode is **inherited from the scrutinee expression**. `match take value`
consumes and destructures by move; plain `match value` borrows and read-binds.
No hidden clone. No `edit` projection in v2.

There is no per-arm choice, and a binding whose mode disagrees with the
scrutinee is refused rather than coerced.

## 5. Partial move

A take-arm transfers **the whole selected payload**. Field-level takes wait for
the general place/move contract.

After transfer the scrutinee is moved-out under existing ownership rules. Drop
flags and join cleanup operate at whole-payload granularity only — a binding
whose field path is deeper than its constructor is a field-level take and is
refused.

## 6. Result join

**Exact canonical TypeRef equality** across reachable arms. No implicit numeric
conversion. The join's ownership mode is the exact common mode.

A `Never` or terminating arm participates only if `Never` is already
represented in production HIR. v2 says it is not, so a match whose every arm
terminates is refused explicitly rather than joined to nothing.

## 7. Guards

Conservative coverage: **a guarded arm never counts toward exhaustiveness**.
Left-to-right evaluation, arm bindings visible in the guard, and no static
truth inference.

The tempting implementation counts a guarded arm's constructor as covered,
which turns a non-exhaustive match into an accepted one. The gate mutates the
model to do that and requires coverage to fall through.

## 8. Usefulness semantics

Constructor enumeration and **witness ordering follow nominal declaration
order**, not alphabetical order and not the order the arms happen to appear.
Redundancy is reported per arm and per or-alternative. Uninhabited and
inaccessible types participate only through decision 6's `Never` rule. Generic
matrices are analyzed on resolved, substituted constructor sets;
schema-level analysis is out of v2.

## 9. Bounds

All limits are explicit, checked, and **fail before emission**. Exhaustion is a
stable compile error — never implicit acceptance, and never a hidden
requirement to add a wildcard.

| bound | v1 |
|---|---:|
| constructors per enum | 64 |
| arms per match | 64 |
| or-alternatives per arm | 8 |
| pattern nodes per match | 512 |
| nesting depth | 16 |
| matrix cells | 65536 |

The constructor limit of 64 is the existing one and is unchanged. Changing any
number here is a versioned profile revision.

## 10. Backend profile

C11 Stage 2 executes v2 first. Direct-native, wasm, and C-ABI remain
unsupported until their own evidence.

**"Explicit unsupported" must be a checked fact, not prose.** Measured on
2026-08-14: `adt`, `adt-exhaustiveness`, and `enum-match-value` are self-driven
gates without an `expectations.kofun`, so `check-capabilities.sh` never
enumerates them and no backend is recorded as unsupported for ADT match — it is
**unasked**. Following the #1383 precedent, those three corpora are registered
in `tests/conformance/capabilities.tsv` so a per-backend row is demanded in
both directions, and each `unsupported` row is held to an executed refusal that
names the construct.

## Compatibility

Existing Bool and flat-enum semantics, the constructor limit of 64,
diagnostic and evaluation order, and current C11 output stay compatible unless
an explicit migration is accepted.

## The gate

```sh
task adt-match-v2-contract
```

11 properties covering all ten decisions, then ten plausible checker mistakes
each of which must be caught **by a distinct set of properties**. Two mistakes
caught by the same set would mean the model cannot tell them apart, and that is
a failure rather than a pass.
