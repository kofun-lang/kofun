# AggregateLayout v1

Status: accepted. Owner: repository maintainer. Issue: #120.

This document is the normative target-parameterized layout contract for
`Text`, `List`, flat records, and flat ADT variants. It defines byte layout
only. It does not change code generation, and no backend may claim
AggregateLayout v1 without agreeing with the golden vectors in
`spec/aggregate-layout-v1/examples/`.

The executable form of this contract is
`spec/aggregate-layout-v1/layout.mjs`, gated by
`sh spec/aggregate-layout-v1/check.sh`.

## The decision

Three options were on the table.

**Option A — one byte-identical layout on every target.** Rejected. It makes
golden files trivial, but only by deciding pointer width for wasm32 in
advance: a 32-bit target would carry 8-byte references so that its bytes
match a 64-bit producer's. That trades real wasm32 space for a convenience
in this repository, and it hides the pointer-width decision inside a
diff that looks like formatting.

**Option C — an opaque handle for every aggregate.** Rejected as the
universal internal representation. Indirection through a handle table is
the right answer at some FFI boundaries, but as the default it costs an
allocation and a dereference per aggregate and forfeits predictable native
layout — which is the reason a layout contract is being written at all.

**Option B — a target-parameterized deterministic layout descriptor. Accepted.**
Source and typed IR keep fields, constructors, and ownership. A declared
`TargetDataLayout` then computes bytes deterministically. Layout identity is
the v1 schema plus the complete target parameters plus type identity, so the
same type on two targets is two descriptors and neither is privileged.

The consequence that decided it: a 32-bit target gets 4-byte references and
a 64-bit target gets 8-byte references *without either one changing source
semantics*. `spec/aggregate-layout-v1/check.sh` asserts the two targets do
not produce identical descriptors, so a future change that collapses them
back into option A fails the gate rather than passing it quietly.

## Byte quantities are decimal strings

Every size, alignment, offset, and object-size bound in this contract — in
both the target inputs and the computed descriptors — is a **decimal string**,
not a JSON number.

Offsets and object-size bounds exceed the exactly-representable range of an
IEEE-754 double. A number-typed contract would silently round precisely the
values the overflow rules exist to reject, so an overflow test could pass by
losing the digits that made it an overflow. Strings keep the contract exact
and independent of any host's number representation.

`layout.mjs` rejects a JSON number, a negative value, or a non-canonical
spelling such as `08` where a quantity is required.

## TargetDataLayout — the input

| Field | Meaning |
|---|---|
| `schema` | `kofun.target-data-layout/v1` |
| `name` | target identity, part of the layout identity |
| `endianness` | `little`; v1 defines little-endian targets only |
| `pointer_size` | reference width in bytes |
| `pointer_align` | reference alignment in bytes, a power of two |
| `max_object_size` | inclusive upper bound on every computed size and offset |
| `scalars` | per-scalar `size` and `align` |

v1 defines two targets:

| Target | `pointer_size` | `pointer_align` | `max_object_size` |
|---|---|---|---|
| `x86_64-linux` | 8 | 8 | 140737488355328 (2^47) |
| `wasm32` | 4 | 4 | 4294967296 (2^32) |

Kofun `Int` is signed 64-bit on **every** target: `size` 8, `align` 8 on both
of the above. References use the target pointer width and never convert to or
from `Int` implicitly. A target whose `endianness` is not `little`, whose
alignment is not a power of two, or whose `max_object_size` is not positive is
refused rather than approximated.

## TypeLayout — the output

Every field below is normative. A descriptor that omits one is not a v1
descriptor.

| Field | Meaning |
|---|---|
| `id` | type identity |
| `kind` | `scalar`, `text`, `list`, `bounded_list`, `record`, `adt`, or `optional` |
| `size` | total bytes, always a multiple of `align` |
| `align` | alignment in bytes, a power of two |
| `fields` | records only: `name`, `type`, `offset`, `size` in declaration order |
| `tag_width` | `adt`/`optional` only: discriminant width in bytes |
| `tag_offset` | `adt`/`optional` only: always `0` in v1 |
| `payload_offset` | `adt`/`optional` only: first payload byte |
| `payload_size` | `adt`/`optional` only: the largest payload |
| `constructors` | `adt`/`optional` only: `name`, `tag`, `payload`, `payload_size` |
| `element` | `bounded_list` only: the element type's identity |
| `capacity` | `bounded_list` only: the fixed slot count, part of type identity |
| `length_offset` | `bounded_list` only: always `0` in v1 |
| `length_size` | `bounded_list` only: the `u64` length, eight bytes |
| `elements_offset` | `bounded_list` only: first element byte |
| `element_size` | `bounded_list` only: one slot's size |
| `pointers` | ascending offsets holding a reference — the pointer bitmap |
| `drop` | `trivial` when `pointers` is empty, otherwise `managed` |

The enclosing document also carries `schema`, `abi_version`, and the echoed
`target`, so a descriptor names the parameters it was computed under and
cannot be reused against a different target by accident.

`pointers` and `drop` are properties of `TypeLayout`, not bytes inside the
object. Nothing in a user-visible object encodes them.

## The v1 rules

**Records.** Fields keep source **declaration order**. Each offset is
`align_up(previous_end, field_align)`; the total size is `align_up(end,
aggregate_align)`, where the aggregate alignment is the maximum field
alignment. Backends may not reorder fields, and an optimizer that did would
be producing a different type, not the same one laid out better.

**Flat ADTs.** Layout is `[tag][padding][payload]`. Tags follow constructor
declaration order starting at zero, so reordering a source declaration is a
layout change and is visible as one. `tag_width` is the smallest of 1, 2, 4,
or 8 bytes that holds the constructor count — deterministic, not a backend
preference. The payload area begins at `align_up(tag_width, payload_align)`
and is sized to the largest payload.

A tagged union's pointer bitmap is the **union** over its constructors'
payloads: a byte that is a reference under any constructor must be treated as
one, because the tag is a runtime value. `Shape` below shows this — offset 8
is a reference even though two of its three constructors put a scalar there.

**`Optional[T]`.** Explicit tag and payload, exactly as any two-constructor
ADT. No backend may invent its own niche optimization — that is, discover
that a type has a spare bit pattern and pack the discriminant into it.
Permitting it per-backend would make `Optional[T]` mean different bytes in
different places while every positive test still passed. A niche rule, if it
is ever wanted, belongs to a separately versioned and separately reviewed
contract.

**Text and List values.** Both are exactly one reference; the object is
described separately. The object headers are `byte_length: u64` and
`length: u64` respectively — eight bytes on both targets, which is what lets a
32-bit reference address a header a 64-bit producer wrote. Immutable `List`
v1 has no capacity field.

**Bounded list values.** `bounded_list` is the one list-shaped value that is
not a reference. It is stored inline, by value: a `u64` length at offset 0,
then `capacity` element slots beginning at `align_up(8, element_align)`, with
no separate object and no indirection. `capacity` is part of type identity, so
two bounded lists differing only in capacity are two types with two
descriptors, exactly as one type on two targets is two descriptors.

Its alignment is `max(8, element_align)` and is never derived from its size —
a 520-byte carrier is 8-aligned. Its pointer bitmap is the element's bitmap
repeated at every slot, because a bounded list holds its elements rather than
addressing them, so a bounded list of a scalar has an empty bitmap and
`trivial` drop. That is what separates it from `list` for deciding whether a
record containing one is `Copy`: `List[Int]` as a field contributes one
pointer and `managed` drop, while `bounded_list` of `Int` contributes neither.

Slots at or beyond the length hold unspecified bytes and may not be read. They
are still copied, so two bounded lists with equal lengths and equal elements
may differ byte for byte past the length: comparing whole values as bytes is
not comparing them as values, and a canonical-bytes producer must serialize
from the length.

This kind exists because the Stage 2 C11 backend stores a `List[Int]` by value
in 520 bytes while this contract described every list value as one reference.
`spec/aggregate-layout-v1/check.sh` now joins the two, reading the emitter's
own `_Static_assert` numbers, so the carrier and the contract cannot drift
apart again. Added by RFC-0011 and recorded as the ledger amendment
`DD-033/A01`; the `list` kind is unchanged.

An object has no trailing padding: it is individually referenced and never
inlined into an array, so nothing follows it that would need alignment.

**Padding.** Padding bytes in deterministic serialized artifacts are zero.

**Checked arithmetic.** Every size, offset, and alignment computation is
checked against `max_object_size` before any value is reported. Overflow is a
failure at layout time, before artifact emission — never a wrapped value that
reaches a backend.

## Golden vectors

Recomputed and byte-compared by `check.sh`. Full descriptors are in
`spec/aggregate-layout-v1/examples/core.x86_64-linux.json` and
`core.wasm32.json`.

### Values

| Type | x86_64 size/align | wasm32 size/align | `pointers` | `drop` |
|---|---|---|---|---|
| `Bool` | 1 / 1 | 1 / 1 | — | trivial |
| `Int` | 8 / 8 | 8 / 8 | — | trivial |
| `Text` | 8 / 8 | **4 / 4** | [0] | managed |
| `List[Int]` | 8 / 8 | **4 / 4** | [0] | managed |
| `List[Text]` | 8 / 8 | **4 / 4** | [0] | managed |
| `BoundedList[Int, 64]` | 520 / 8 | 520 / 8 | — | trivial |
| `BoundedList[Int, 2]` | 24 / 8 | 24 / 8 | — | trivial |
| `BoundedList[Text, 3]` | **32** / 8 | **24** / 8 | **[8, 16, 24]** / **[8, 12, 16]** | managed |
| `Bag { samples: BoundedList[Int, 64], count: Int }` | 528 / 8 | 528 / 8 | — | trivial |
| `Counter { flag: Bool, count: Int }` | 16 / 8 | 16 / 8 | — | trivial |
| `Maybe = Missing \| Present(Int)` | 16 / 8 | 16 / 8 | — | trivial |
| `Shape = Narrow(Bool) \| Wide(Int) \| Handle(Text)` | 16 / 8 | 16 / 8 | [8] | managed |
| `Optional[Int]` | 16 / 8 | 16 / 8 | — | trivial |

`Counter` is `flag` at offset 0, `count` at offset 8: seven padding bytes,
identical on both targets because `Int` is 64-bit everywhere.

`Maybe`, `Shape`, and `Optional[Int]` are each `tag_width` 1 at
`tag_offset` 0, `payload_offset` 8, `payload_size` 8.

### Objects

| Object | x86_64 total | wasm32 total | payload offset | payload bytes |
|---|---|---|---|---|
| `Text "ok"` | 10 | 10 | 8 | 2 |
| `Text "a日本語"` | 18 | 18 | 8 | 10 |
| `Text ""` | 8 | 8 | 8 | 0 |
| `List[Int]` × 3 | 32 | 32 | 8 | 24 |
| `List[Text]` × 2 | **24** | **16** | 8 | 16 / 8 |
| `List[Int]` × 0 | 8 | 8 | 8 | 0 |

`a日本語` is one ASCII byte plus three 3-byte UTF-8 sequences: 10 bytes, not
4 characters. `List[Text]` × 2 is where the targets visibly diverge — 8-byte
references on x86-64, 4-byte on wasm32 — which is option B doing the work it
was chosen for.

Zero-length `Text` and `List` are header-only: 8 bytes, payload offset 8,
payload size 0. Neither is a null reference.

```
Text "ok"  on x86_64-linux and wasm32
  offset 0  [ byte_length: u64 = 2      ]  8 bytes
  offset 8  [ 'o' 'k'                   ]  2 bytes
  total 10

List[Text] x2 on x86_64-linux        List[Text] x2 on wasm32
  offset 0  [ length: u64 = 2   ] 8      offset 0  [ length: u64 = 2   ] 8
  offset 8  [ ref               ] 8      offset 8  [ ref               ] 4
  offset 16 [ ref               ] 8      offset 12 [ ref               ] 4
  total 24                               total 16
```

## Explicit failures

These are refused with a message and a nonzero status, and **no descriptor is
written** — a partial layout is worse than none, because a consumer cannot
tell it apart from a complete one. Each is gated by `check.sh`.

| Case | Fixture |
|---|---|
| Size or offset overflow | `invalid/tiny-target.json` against the core vectors |
| Element-count overflow | `invalid/overflow-elements.json` |
| Recursive layout | `invalid/recursive.json` |
| Non-little-endian target | `invalid/big-endian-target.json` |

Recursive layout, generics, packed layout, `repr(C)`, user-controlled layout,
SIMD, optimizer-driven field reordering, unsized types other than `Text`/`List`
payload bytes, and a stable public FFI ABI are all out of scope for v1.

## Relationship to the current native layout

The shipped x86-64 backend uses `[byte_length: i64][UTF-8 bytes]` for `Text`
(`bootstrap/native/check.sh`) and `[length: i64][elements]` for `List`.

v1 specifies `u64` headers where the native backend uses `i64`. The two agree
on width, offset, and byte order for every value either can represent; they
differ in signedness, and therefore in what a negative header means — the
native ABI can encode one, and v1 cannot.

**This is a comparison, not a compatibility requirement.** The historical
native bytes are evidence about what already runs; they do not constrain v1,
and specifically they must not be used to argue wasm32 into 64-bit references.
Where a backend adopts v1, the difference is a versioned migration or an
adapter boundary, recorded as such rather than described as preservation.

## Consumers

`#201` (wasm Text/List host ABI), `#118` (ADT runtime lowering), and `#314`
(executable coalescing) depend on this artifact rather than on prose
assumptions. `#328` records constructor and payload types without choosing
layout and continues to do so; its runtime follow-up depends on this document.

Production lowering to these layouts is a later issue. This document and its
checker are the contract those issues are measured against.
