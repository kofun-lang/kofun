# Generic-ADT HIR v1 (analysis document)

This document defines the closed, versioned analysis artifact
[#1675](https://github.com/kofun-lang/kofun/issues/1675) publishes as the second
half of the generics-v1 nominal identity core. It is the ADT child of
[#1268](https://github.com/kofun-lang/kofun/issues/1268), built on the identity
core [#1674](https://github.com/kofun-lang/kofun/issues/1674) froze in
[`../generic-record-hir-v1/generic-record-hir-v1.md`](../generic-record-hir-v1/generic-record-hir-v1.md).
It is the contract the compiler entry `--emit-generic-adt-hir`, the JSON schema
[`kofun.generic-adt-hir.v1.schema.json`](kofun.generic-adt-hir.v1.schema.json)
and the independent oracle [`model.mjs`](model.mjs) all implement.

It is a *contract* first: the artifact, the identity preimages, the limits and
the refusal codes are frozen here, and the compiler agrees with this document
rather than the document describing whatever the compiler happened to emit.
Both halves of the canonical pair — `compiler.kofun` through the bounded host
driver and the maintained `compiler.c` — reproduce these goldens byte for byte
and refuse every negative fixture with its registered code.

## What is reused, and what is new

The identity core is the one #1674 froze, **unchanged**: the #303 frame, the
two KIF v3 domains `kofun.id.type-parameter/v3` and
`kofun.id.constructed-type/v3`, `PrimitiveTypeId`, the canonical `TypeRef` byte
encoding, `nominal(TypeId, ordered TypeRef arguments)` with a derived
`ConstructedTypeId` beside it, and the file identity over `LOGICAL-PATH`. The
oracle imports those definitions from the record oracle instead of copying
them, and both compiler halves call the record half's functions for them
(`generic_record_parameter_id`, `generic_record_primitive_id`,
`generic_record_constructed_id`, and their `gr_*` twins), so there is one
definition of each.

What this document adds on top of that core:

- **ADT binders.** A sum type `type Opt[T] = | None | Some(value: T)` binds up to
  two type parameters; each mints a `TypeParameterId` from its owner `TypeId`,
  the binder kind and its ordinal, exactly as a record binder does.
- **Constructor payload substitution over nested `TypeRef`s.** An application
  `Wrapped[Box[Int]]` substitutes its arguments into every constructor payload,
  capture-avoiding and applied recursively through nested `nominal` arguments.
- **By-value cycle classification over records and ADTs together**: ADT-to-ADT
  and mixed record/ADT cycles are classified and refused before any output, in
  both halves.
- **The declaration kind in the `TypeId`.** See *Identity*.

Out of scope, and recorded as deferred rather than done: variant layout,
matching, exhaustiveness, backend emission and execution
([#1269](https://github.com/kofun-lang/kofun/issues/1269) /
[#1270](https://github.com/kofun-lang/kofun/issues/1270) own layout). In
particular this slice classifies by-value cycles on the *declaration graph*; the
exact per-instantiation layout cycle (a phantom parameter that is never stored,
reference-indirected recursion) is deferred to #1269/#1270. See *By-value
cycles*.

## Why a separate analysis document

[#1673](https://github.com/kofun-lang/kofun/issues/1673) decision 1(a) chose a
new closed, versioned analysis document behind its own entry, and its recorded
answers say the ADT child follows the same frozen identity core with the same
choice. So this is **not** a new `kind` inside
[`kofun.generic-record-hir/v1`](../generic-record-hir-v1/kofun.generic-record-hir.v1.schema.json),
whose schema is frozen and closed (`"kind": {"const": "record"}`). The record
entry `--emit-generic-record-hir` is unchanged in what it accepts: it still sees
only record declarations, so a record field that names an ADT is still refused
there (`E2S196` for an applied name, `E2S194` for a bare one). The ADT entry's
document lists records too, because a mixed cycle cannot be classified without
them.

The document is not the structural IR, not scope-HIR v1/v2, and not KIF.

## Entry and publication

```sh
kofun-stage2 --emit-generic-adt-hir INPUT.kofun OUTPUT.json LOGICAL-PATH
```

- `LOGICAL-PATH` is validated exactly as in the record contract: explicit valid
  UTF-8, 1–4096 bytes, already NFC, relative and slash-separated; empty, `.` and
  `..` segments, NUL, Unicode Cc/Cf/Zl/Zp, backslashes, absolute paths and a
  leading ASCII URI scheme are refused. Physical paths never enter an identity.
- Input and output must be distinct files; the destination is replaced
  atomically after the complete document validates. Any refusal writes **no**
  document and leaves a pre-existing destination byte-identical.
- The source is lexed first, as `--compile-outcome` lexes it: a lexical error is
  reported with its own `E2S0x` code and nothing else runs.
- The document is canonical JSON on one line terminated by `\n`, with object
  keys in lexicographic order.

Ordinary compilation and `--compile-outcome` keep refusing every generic ADT and
generic record exactly as they do today (`E2S148` on a type parameter, exit 1,
no C and no artifact). [#1673](https://github.com/kofun-lang/kofun/issues/1673)
decision 3(a): only the analysis entries accept, so the two public modes cannot
disagree and the Stage 1 compatibility path is never entered. The gate asserts
this for the positive fixture in both halves.

## Source surface

The analysis reads the bounded declaration surface below. Functions and module
constants at the top level are stepped over by the ordinary declaration walker;
a top-level item that walker cannot step over, a type alias among them
(#1673 excludes aliases), is refused as malformed (`E2S213`); and anything
unsupported inside a declaration this analysis lists is refused.

```text
record := "type" Name [ "[" Binder ("," Binder)* "]" ] "=" "{" (field ("," field)* ","?)? "}"
adt    := "type" Name [ "[" Binder ("," Binder)* "]" ] "=" ("|" Constructor [ "(" field ")" ])+
field  := Identifier ":" TypeRef
TypeRef := Int | Bool | Text | Unit        # a closed builtin
         | Binder                          # the declaration's own type parameter
         | Name                            # a non-generic record or ADT
         | Name "[" TypeRef ("," TypeRef)* "]"
```

- A constructor carries no payload or exactly one named payload field. This is
  the shape the ordinary ADT frontend accepts (`E2S41` refuses a second payload
  field there); the HIR does not accept more than the language does.
- An ADT declares at least two and at most 64 constructors, none repeated
  (`E2S39` is the ordinary frontend's rule for fewer than two).
- A declaration that carries **at least one type binder** is *listed* in the
  document. A declaration with none (including a record whose parameter list is
  exactly `[const NAME: Int]`) is *context*: it contributes a `TypeId`, an arity
  of zero and by-value edges, but is not listed and its members are not
  validated beyond the edges they contribute.
- Every record and ADT declaration in the file, listed or not, counts toward the
  64-declaration bound, because each is a node of the by-value graph.
- `function` TypeRefs (RFC-0017 tag 5) are out of this slice and refused.

## Identity

The two #1673 identities, the primitive identity and the `TypeRef` encoding are
the record contract's, unchanged:

| ID | domain | canonical payload |
| --- | --- | --- |
| `TypeParameterId` | `kofun.id.type-parameter/v3` | owner `TypeId` (32 raw bytes), binder kind `u8` (1 = type), ordinal `u16be` |
| `ConstructedTypeId` | `kofun.id.constructed-type/v3` | declaration `TypeId` (32 raw bytes), `sequence` of the ordered canonical argument `TypeRef`s |
| `PrimitiveTypeId` | `kofun.id.primitive/v1` | the closed builtin name as ASCII bytes |

A `TypeRef` is `1 PrimitiveTypeId`, `2 TypeParameterId`, `3 TypeId
sequence(arguments)` or `4 ConstructedTypeId`, and `sequence(items)` is
`count:u16be` followed by the concatenated encodings. A multi-argument
`nominal` nested inside another type encodes all of its arguments, in order.

### The declaration kind is part of the `TypeId`

The nominal declaration identity is the existing module-identity `SymbolId`
([`spec/modules/module-identity.md`](../modules/module-identity.md): "the kind
distinguishes, for example, a value function from a value constructor"): the
synthetic-root `ModuleId`, the tag-1 `type` `NamespaceId`, the declaration-kind
text and the declaration name, framed under `kofun.id.symbol/v1`.

| declaration | kind TLV (`0x8003`) |
| --- | --- |
| record | `8003 00000006 7265636f7264` (`record`) — the exact preimage #1674 froze |
| ADT | `8003 00000003 616474` (`adt`) |

so `type X[T] = { … }` and `type X[T] = | … ` mint different `TypeId`s, and a
record's `TypeId` here equals its `TypeId` in the record document. The oracle
asserts that equality rather than assuming it. Both spellings still occupy one
`type` namespace, so two declarations of one name are refused (`E2S215`)
regardless of kind.

A constructor is addressed as `(declaration TypeId, ordinal)` — the shape the
#328 frontend already uses — and **no `ConstructorId` is minted here**: a
constructor `SymbolId` belongs to the KIF producer, not to this analysis.

## Document

```json
{
  "declarations": [ … ],
  "file_id": "<64 hex>",
  "limits": { … },
  "profile": "kofun.stage2-analysis/generic-adt/v1",
  "schema": "kofun.generic-adt-hir/v1"
}
```

`file_id` is the existing anonymous-single-file `kofun.id.file/v1` identity over
`LOGICAL-PATH`. A listed `declaration` is one of two shapes. A record:

```json
{
  "applications": [ … ],
  "binders": [ … ],
  "fields": [ {"name": "value", "type": TypeRef} ],
  "id": "<TypeId>",
  "kind": "record",
  "name": "Box"
}
```

and an ADT:

```json
{
  "applications": [ … ],
  "binders": [ … ],
  "constructors": [
    {"name": "None", "ordinal": 0, "payload": []},
    {"name": "Some", "ordinal": 1, "payload": [ {"name": "value", "type": TypeRef} ]}
  ],
  "id": "<TypeId>",
  "kind": "adt",
  "name": "Opt"
}
```

- `binders` — one per type parameter, in declaration order, each
  `{"id": "<TypeParameterId>", "kind": "type", "ordinal": 0..1}`. One or two.
- `fields` / `constructors` — in declaration order. `ordinal` is the
  constructor's position, `payload` holds zero or one entry.
- `applications` — at most eight per declaration, in first-use source order,
  each `{"arguments": [TypeRef], "fields"|"constructors": [substituted members],
  "id": "<ConstructedTypeId>"}`. The member list is the declaration's own with
  every `parameter` TypeRef replaced by the corresponding argument
  (capture-avoiding, applied recursively through nested `nominal` arguments). A
  surrogate `TypeParameterId` never appears in a substituted member.

An application is *source-mentioned*: it is a concrete `Name[Arg, …]` the source
text writes, found by reading the whole file token by token, outer application
before the applications nested in its arguments, each distinct argument tuple
once. An application whose arguments mention a type parameter is not concrete and
is not recorded. The transitive instantiation closure (the `Opt[Text]` that
`Wrapped[Text]` stores) is a specialization concern, not part of this document.

A worked substitution: `Wrapped[Text]` over
`| Present(inner: Opt[T])` writes `inner: nominal(Opt, [primitive Text])`, and
`Wrapped[Box[Int]]` writes `inner: nominal(Opt, [nominal(Box, [primitive Int])])`.

## By-value cycles

A reference held behind no indirection is by value; this slice has no
indirection form, so every field and payload reference is by value and every
cycle is refused before any output.

The graph has a node for every record and ADT declaration in the file, listed or
not. A declaration's edges are the declared nominal heads its members write, in
first-use order without repeats, **including heads nested in type arguments**:
a constructed type holds its arguments by value, so `Node` holding
`Opt[Node]` holds `Node`. A primitive, a type parameter, and a name that is no
record or ADT contribute no edge.

Roots are visited in source order and edges in first-use order; a declaration
whose whole reachable subgraph holds no cycle is not explored again, which keeps
the walk linear in edges. The first edge that returns to a declaration on the
current path closes the cycle, and the path from that declaration through the
current one names its members:

| cycle | refusal |
| --- | --- |
| an edge from a declaration to itself, ADT | `E2S210` |
| an edge from a declaration to itself, record | `E2S199` |
| longer, every member an ADT (ADT-to-ADT) | `E2S211` |
| longer, every member a record | `E2S200` |
| longer, at least one record and one ADT (mixed) | `E2S212` |

`E2S199` and `E2S200` are the generic-record contract's codes, kept unchanged:
a record-only cycle is refused identically by both documents. The label of an
edge a type argument contributes is attributed to the declaration that writes
the argument.

This classification is **conservative and declaration-level**. It refuses every
by-value cycle, and also refuses one a precise per-instantiation layout would
accept: a generic whose parameter is never stored (`type Phantom[T] = { n: Int }`
with `type A = { p: Phantom[A] }`) holds no `A`, yet `A` writes `A` as an
argument. Exact layout-cycle classification — and the reference-indirected
recursion that makes some cycles legal — belongs to
[#1269](https://github.com/kofun-lang/kofun/issues/1269) /
[#1270](https://github.com/kofun-lang/kofun/issues/1270); this issue records the
deferral and those issues must record the matching one.

## Limits

Every limit is part of `limits` in the document and is evaluated before any
output; an over-limit input refuses with no document.

| Limit | Value |
| --- | --- |
| type parameters per declaration | 2 |
| concrete instantiations per declaration | 8 |
| constructed `TypeRef` depth | 8 |
| record and ADT declarations per file | 64 |
| constructors per ADT | 64 |
| payload fields per constructor | 1 |
| fields per record | 256 |
| declaration, constructor and field name bytes | 65535 |
| document bytes | 1048576 |

`limits` is the closed object `{binders_per_declaration, constructed_depth,
constructors_per_declaration, declarations, document_bytes,
fields_per_declaration, instantiations_per_declaration, name_bytes,
payload_fields_per_constructor}`. The record contract's `display_bytes` and
`field_name_bytes` are not carried: neither was enforced by either compiler
half, and a limit the document names must be one it checks.

Instantiations are *concrete*: only applications whose arguments are fully
concrete (no free parameter) count toward the eight limit, and each distinct
argument tuple is counted once.

## Refusals

Every refusal is a registered Stage 2 code reported on stdout, exit 1, with no
C and no document. `E2S192`–`E2S202` are the record contract's, so this slice
allocates from **`E2S203`** (#1673's "from `E2S189`" predates both allocations).

| Code | Refusal |
| --- | --- |
| `E2S203` | more than two type parameters on a declaration |
| `E2S204` | duplicate type parameter in a declaration |
| `E2S205` | unbound type parameter in a field or payload: a bare name that is neither a binder nor a declaration |
| `E2S206` | application arity does not match the declaration's binder count |
| `E2S207` | unknown nominal type in a field or payload: an applied name `Nope[…]` that is no record or ADT |
| `E2S208` | more than eight concrete instantiations of one declaration |
| `E2S209` | constructed `TypeRef` depth above eight |
| `E2S210` | direct by-value ADT cycle (`type L[T] = \| End \| Next(next: L[T])`) |
| `E2S211` | mutual by-value ADT-to-ADT cycle |
| `E2S212` | mixed record/ADT by-value cycle |
| `E2S213` | unsupported payload or field form, or malformed declaration |
| `E2S214` | unsupported binder kind (a const binder on an ADT, or beside a type binder) |
| `E2S215` | duplicate type declaration (a record and an ADT share one namespace) |
| `E2S216` | constructor shape: duplicate constructor, fewer than two, or more than one payload field |
| `E2S217` | a bound is exceeded: declarations, constructors, fields, a name, the document, or an entry argument |

A record-only cycle in this document is `E2S199`/`E2S200`.

### Refusal order

The compiler reports the first refusal of these phases, and the oracle applies
them in the same order, so a source with two defects has one defined answer:

1. **Scan**, one record or ADT declaration at a time in source order: its name
   bound, its binder list (`E2S214`, `E2S203`, `E2S204`), a duplicate name
   (`E2S215`), the 64-declaration bound, the 64-constructor bound; then a
   malformed top-level declaration (`E2S213`).
2. **Cycles** over the whole graph (`E2S199`–`E2S200`, `E2S210`–`E2S212`).
3. **Members** of each listed declaration in source order: an ADT's constructor
   shape first (`E2S216`), then the types of its members left to right
   (`E2S205`–`E2S207`, `E2S209`, `E2S213`); a record's fields.
4. **Applications**, one listed declaration at a time in source order: each of
   its applications in first-use order is materialized (`E2S206`, `E2S209`) and
   the ninth distinct tuple refuses (`E2S208`); the document size (`E2S217`) is
   last.

## Determinism

Repeat runs, `-O0`/`-O2` builds, and a physical-path remap that preserves the
same `LOGICAL-PATH` produce byte-identical documents. The document never depends
on host table order, addresses, wall-clock time, or process identity.

Identities do not depend on declaration order: reordering the declarations of
the file yields the same `TypeId`, `TypeParameterId` and `ConstructedTypeId`
for each declaration. The *document* lists declarations and applications in
source order, so a reordered file lists the same entries in a different order;
the gate checks the identities, and the entries keyed by them.

## Gate

`task generic-adt-hir` runs [`check.sh`](check.sh), which executes
[`check.mjs`](check.mjs). It recomputes every `TypeParameterId` and
`ConstructedTypeId` from its preimage with the frame above, checks the schema,
the canonical order, every limit boundary, and every refusal, and applies
mutations to the preimage so a name-based, kind-blind or discovery-order
identity is caught. It then drives both halves of the entry — the canonical
Kofun half through the bounded host driver and the maintained C half as the
built binary — requires each to reproduce the positive golden byte for byte and
to refuse each negative fixture with its registered code and no artifact, and
requires the two halves to agree on the diagnostic text. It checks:

- a record-only file produces the same declaration entries through
  `--emit-generic-record-hir` and `--emit-generic-adt-hir`, which is the
  executable form of "the core is reused unchanged";
- ordinary compilation and `--compile-outcome` keep refusing the same generic
  sources with `E2S148`, exit 1 and no artifact, in both halves;
- the boundary of every limit, with sources generated at the boundary.

### Defects this exposed in the #1674 record half

Reusing the core on ADT payloads surfaced two defects in the record half, both
fixed here without changing any frozen golden, and both asserted by this gate:

- A multi-argument nominal type nested inside another type (`Box[Pair[Int,
  Bool]]`) encoded only its first argument into the enclosing type's preimage, so
  the `ConstructedTypeId` disagreed with the frozen algebra. The record golden
  has no such shape, which is why it passed. Both halves now flatten the
  argument rows.
- A source with an unterminated string reached the declaration scan without
  being lexed and read before the start of the buffer. Both entries now lex
  first and report the lexical error.

No C, KIF, or capability is claimed here.
