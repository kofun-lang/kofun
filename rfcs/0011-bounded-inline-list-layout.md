# RFC-0011: AggregateLayout gains a bounded inline list kind, and Stage 2 record fields use it

- Shepherd: hjosugi
- Opened: 2026-08-10
- Status: accepted
- Decided: 2026-08-10

Proposal for [#1183](https://github.com/kofun-lang/kofun/issues/1183), the
fifth and last increment of [#868](https://github.com/kofun-lang/kofun/issues/868).
This proposal records target semantics only. No emitter, checker, layout
vector, diagnostic, or release capability is implemented by it.

It widens what `spec/aggregate-layout-v1` admits, so it arrives against DD-033
as the recorded amendment `DD-033/A01` rather than as an edit to that decision's
text, and a reader of `docs/DESIGN_DECISIONS.md` sees the semantics moved.

Measured against `origin/main@43d53d38ef30ec5ef234eb976c3e39a7ae949bb5`.

## Summary

`spec/aggregate-layout-v1` gains a sixth value kind, `bounded_list`: a
fixed-capacity list stored **inline and by value**, with a `u64` length
followed by a fixed element array, no pointers, and trivial drop. The existing
`list` kind is untouched — a `List` value is still exactly one reference — and
the two are different kinds rather than two readings of one kind.

The Stage 2 C11 bootstrap profile lowers a `List[Int]` **record field** to
`bounded_list` with capacity 64, which is the carrier it already uses for
`List[Int]` locals, parameters, and results. `type Bag = { samples: List[Int],
count: Int }` therefore lowers and runs, and a record containing one stays
`Copy`-shaped: no pointer bitmap entry, no managed drop.

## Motivation

The carrier and the layout contract disagree today, and the disagreement is
what blocks the increment.

The Stage 2 backend's carrier is by value —
`bootstrap/stage2/compiler.kofun` emits

```c
typedef struct { uint64_t length; int64_t elements[64]; } KofunIntListValue;
```

with `_Static_assert`s fixing its size at 520, `length` at offset 0, `elements`
at offset 8, and its alignment at 8.

`spec/aggregate-layout-v1/layout.mjs` says a List value is a reference:

> A Text or List value is exactly one reference. The object it addresses is
> described separately, so the value layout does not depend on the payload.

returning `size: pointerSize`, `align: pointerAlign`, `pointers: [0n]`,
`drop: "managed"`.

For a `List[Int]` record field the two answer differently about what is stored:
eight bytes with one pointer at offset 0 and managed drop, or 520 bytes with no
pointers and trivial copy. They give different offsets for every field after it
and different answers to whether the containing record is `Copy`. Nothing can
lower the field until one of them is chosen.

The cost of leaving it unchosen is measured, not hypothetical. On the audited
commit, **28 record fields across 13 tracked `.kofun` files** are typed
`List[...]`; **19 of them across 6 files** are `List[Int]`. Four are canonical
standard-library sources — `stdlib/array`, `stdlib/binary_heap`, `stdlib/set`,
and `stdlib/vector` — whose own `verify.sh` asserts the refusal verbatim, for
example:

```
error[E2S32]: record `IntVector` has a field type outside the Stage 2 Int/Bool/Text slice
```

So four shipped standard-library modules are currently required by their own
gates to be un-executable on the C11 backend, and
[#847](https://github.com/kofun-lang/kofun/issues/847) and
[#646](https://github.com/kofun-lang/kofun/issues/646) — the benchmark report
producer and its codec — are blocked behind #868 for exactly this field shape.
#847's `Samples8` workaround is a fixed-width eight-field record that the issue
itself marks as test evidence and explicitly not the public raw-sample
representation.

## Detailed design

### The new kind

`AggregateLayout v1`'s `kind` field admits `scalar`, `text`, `list`, `record`,
`adt`, and `optional`. This proposal adds `bounded_list`.

A `bounded_list` type declares an element type and a capacity. Its layout is
computed, not declared:

| Property | Value |
|---|---|
| `size` | `align_up(header + capacity × element_size, align)` |
| `align` | `max(header_align, element_align)` |
| `pointers` | the element bitmap repeated at each slot, empty when the element has none |
| `drop` | `trivial` when the element bitmap is empty, else `managed` |

The header is the same eight-byte `u64` length the `list` object header already
uses, at offset 0, with the element array beginning at
`align_up(8, element_align)`. For `bounded_list` of `Int` at capacity 64 on a
64-bit target this gives size 520, align 8, elements at offset 8, an empty
pointer bitmap, and trivial drop — the carrier Stage 2 already emits, now
derived from the contract rather than asserted beside it.

Capacity is part of type identity. Two `bounded_list` types differing only in
capacity are two types with two descriptors, exactly as one type on two targets
is two descriptors under DD-033.

### What Stage 2 does with it

The Stage 2 C11 bootstrap profile lowers a `List[Int]` record field to
`bounded_list[Int, 64]`. The profile boundary is where this mapping lives; the
mapping is not a property of `List[Int]` in the language.

`List[T]` for every other `T` stays refused in record fields. Nine of the 28
tracked fields have a non-`Int` element — `List[Text]`, `List[LogField]`,
`List[Transition]`, `List[List[Text]]`, and others — and none of them is
admitted by this proposal.

### The alignment coupling

The emitter currently derives alignment from size. `bootstrap/stage2/compiler.kofun`
carries the assumption at two sites, the struct emitter and the `_Static_assert`
offset walk, each computing `record_align_up(extent, field_size)` and taking
`field_size` as the field's alignment. That is right for 1- and 8-byte scalars
and wrong for a 520-byte struct whose alignment is 8. Both sites must take
alignment from the field's layout rather than its size. This is a defect the
new kind exposes rather than one it introduces, and it must be fixed in the
same change that admits the kind.

## Semantics

A `bounded_list` value holds between zero and `capacity` elements. Its length is
the first eight bytes; slots at or beyond the length hold unspecified bytes and
may not be read.

- **Copy.** A `bounded_list` whose element has no pointers is copied by value,
  bytes and all, including the unspecified tail. A record containing one is
  therefore `Copy`-shaped where it otherwise would be, which is the property
  that distinguishes this kind from `list`.
- **Capacity is a static bound, not a runtime one.** Constructing a value with
  more than `capacity` elements is a refusal, not a reallocation. `bounded_list`
  never grows.
- **Zero length is not a null reference,** matching the existing rule for
  header-only `Text` and `List`: a zero-length `bounded_list` is a full-size
  inline value whose length field is 0.
- **`bounded_list` is not `List`.** No implicit conversion is decided here.
  Whether a `bounded_list` may be viewed as a `List` — Stage 2 has
  `kofun_list_int_view` and `kofun_list_int_value` for exactly this, at the C
  level — is left to the implementing change.

Deliberately left undefined: `bounded_list` of an owned element, nested
`bounded_list`, and any capacity other than the one a profile names.

## Diagnostics

No new code. `E2S32` already owns the refusal and keeps it for every field type
outside the widened slice.

Its **message changes**, because the slice it names changes. The current
sentence is

```
record `Bag` has a field type outside the Stage 2 Int/Bool/Text slice
```

and the slice after this proposal is Int, Bool, Text, and bounded `List[Int]`.
The exact sentence occurs at **17 sites in 17 files** on the audited commit, of
which 11 are `stdlib/**/tests/verify.sh` assertions pinned on it verbatim, plus
`tests/stdlib/clock-adapters/check.sh` and `tests/stdlib/tzdb/check.sh`. The
broader token `Int/Bool/Text` occurs 36 times across 28 files, including
`release/claims.json`, `docs/MVP_IMPLEMENTED.md`, `docs/ROADMAP.md`,
`bootstrap/manifest.json`, and `artifacts/release-evidence/LIMITS.md`. The
implementing change pays that sweep; #1181 paid it once already when `Text` was
admitted, and this is the second and last time under #868.

Four of those assertions — `stdlib/array`, `stdlib/binary_heap`, `stdlib/set`,
`stdlib/vector` — do not merely change wording. They flip from asserting a
refusal to asserting execution, because their records become lowerable. That is
the point of the increment and must be visible in the diff as a behaviour
change rather than a string edit.

## Ownership and effects

No interaction with `read`/`edit`/`take` beyond what the kind's `drop` already
determines. A `bounded_list` with an empty pointer bitmap is trivially
droppable and copyable; one whose element carries pointers is managed and
composes under [RFC-0004](0004-ownership-kind-classification.md)'s structural
join with no rule restated here. Since only `List[Int]` is admitted by the
Stage 2 profile, the managed case is unreachable in this increment.

No effect discipline interaction.

## Alternatives

**The field holds a reference, matching the spec unchanged.** Rejected as this
increment. Nothing in Stage 2 produces or consumes a managed `List[Int]`
reference today — the entire `List[Int]` story it ships, from locals (#919)
through parameters and results (#1103), is the by-value bounded carrier. Making
record fields the one place that is a reference would require inventing the
managed representation first, which is a larger piece than #868's remaining
increment and would leave the field inconsistent with every other position.
This remains the right long-term representation, and this proposal does not
foreclose it: `bounded_list` is a separate kind, so adopting a reference
representation for `List` later removes no rule stated here.

**Refuse `List[Int]` record fields explicitly and close #868 on four
increments.** Rejected. It is the cheapest option and the most honest about
current capability, but it abandons #868's stated goal of carrying "a nominal
report record, bounded `List[Int]` raw samples, and canonical `Text` bytes" in
one producer, and leaves #847 and #646 blocked with no named path — their only
alternative is the `Samples8` fixed-width record their own issues rule out as
the public representation. It would also leave four standard-library modules
permanently gated on being un-executable.

**Redefine `list` as by-value rather than adding a kind.** Rejected outright.
It would promote a bootstrap-local bounded carrier into the meaning of `List`
for every target and every backend, contradicting DD-033's reference layout for
`List[Text]` and the wasm32 divergence the layout contract exists to
demonstrate. Adding a kind costs a schema entry; redefining one costs the
contract.

**Do nothing.** Rejected: it is the status quo the issue was filed against, and
it leaves the carrier and the contract disagreeing in the tree.

## Drawbacks

A record grows by 520 bytes per `List[Int]` field, whatever the actual length.
A record with three sample lists is 1560 bytes of mostly-unspecified tail, and
it is copied whole on every move. This is the cost of by-value, and it is why
the reference representation stays the right long-term answer.

The unspecified tail is copied. Two records with equal lengths and equal
elements may differ byte-for-byte past the length, so byte comparison of whole
records is not value comparison. Any canonical-bytes producer — which is
exactly what #646 is — must serialize from the length, never from the carrier.

Capacity 64 is now a number with semantic weight in a contract that otherwise
derives everything from a declared target. It is a profile's choice and the
kind is capacity-generic, but the only capacity anything uses is 64.

`AggregateLayout v1` grows a kind after being accepted, which is what the
amendment below records.

## Compatibility and migration

`additive`. No tracked program changes meaning and none stops compiling. The
change is additive in the direction that matters: source that is **refused**
today begins to compile, and nothing that compiles today is refused.

`bounded_list` is a new kind name reachable from no existing layout vector, and
the `list` kind's size, alignment, pointer bitmap, and drop are unchanged, so
every committed golden vector stays byte-identical. The visible delta is that
`E2S32`'s message names a wider slice, and that four standard-library modules
stop being refused by the Stage 2 backend.

Migration: none for user programs. Within the repository, the implementing
change updates the `E2S32` sentence at its 17 sites and flips the four stdlib
assertions from refusal to execution.

## Implementation plan

Acceptance commits to no schedule. When it is built, the order is:

1. `bounded_list` added to `spec/aggregate-layout-v1/layout.mjs`, the spec
   prose, and the golden vectors, with a target-divergence vector proving
   capacity and element size drive the result;
2. the two `field_size`-as-alignment sites in `bootstrap/stage2/compiler.kofun`
   decoupled, taking alignment from the field layout;
3. `List[Int]` record fields admitted in the Stage 2 profile, lowering to
   `bounded_list[Int, 64]`;
4. the `E2S32` message sweep across its 17 sites;
5. the four stdlib gates flipped from asserting refusal to asserting execution.

Steps 1 and 2 are separately reviewable and land first; nothing in step 1
changes behaviour.

## Validation

The gate is `task records`, extended to execute a record with a `List[Int]`
field through Stage 2 C11 and to observe its values, plus
`sh spec/aggregate-layout-v1/check.sh` for the layout vectors.

The negative fixture that proves the boundary is
`tests/conformance/records/stage2_unsupported_field.kofun`, which must be
re-pointed at a field type still outside the slice — a non-`Int` element such
as `List[Text]` — so it keeps refusing after `List[Int]` is admitted. A fixture
that stops refusing because its subject was admitted proves nothing, and this
one currently uses `samples: List[Int]` as its refused shape.

`task stdlib`, `task list-int-values`, `task text-results`, `task diagnostics`,
`task release-claims`, and `task verify` hold the rest.

This proposal records no `implementation` in the ledger, because nothing is
implemented.

## Unresolved questions

- **Whether a `bounded_list` may be viewed as a `List` without copying.**
  Stage 2 has `kofun_list_int_view` at the C level; whether that becomes a
  language-visible conversion is left to the implementing change and is not
  decided here.
- **The capacity beyond 64.** The kind is capacity-generic and the profile names
  64. What names a different capacity — a type parameter, a profile knob, or
  nothing — is deliberately open, and would be settled by the first consumer
  that needs a second value.
- **When the reference representation arrives** for `List` in record fields.
  This proposal keeps it available and decides nothing about its timing.
