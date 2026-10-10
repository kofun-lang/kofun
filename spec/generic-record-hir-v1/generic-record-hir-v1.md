# Generic-record HIR v1 (analysis document)

This document defines the closed, versioned analysis artifact
[#1674](https://github.com/kofun-lang/kofun/issues/1674) publishes as the first
half of the generics-v1 nominal identity core. It is the contract the compiler
entry `--emit-generic-record-hir`, the JSON schema
[`kofun.generic-record-hir.v1.schema.json`](kofun.generic-record-hir.v1.schema.json)
and the independent oracle [`model.mjs`](model.mjs) all implement.

It is a *contract* first: the artifact, the identity preimages, the limits and
the refusal codes are frozen here, and the compiler agrees with this document
rather than the document describing whatever the compiler happened to emit.
The compiler entry lands in the following slice and is required to reproduce
these goldens byte for byte; until then this gate proves only the contract and
its oracle, and the compiler-agreement assertions are added beside it.

## Why an analysis document

[#1673](https://github.com/kofun-lang/kofun/issues/1673) decision 1(a) chose a
new closed, versioned analysis document behind its own entry rather than
structural IR or a KIF record set. The scoped-parallelism lane
([`spec/concurrency/scoped-captures-v1.md`](../concurrency/scoped-captures-v1.md)
§§11–14) is the precedent: canonical JSON, a schema file, goldens, an explicit
`LOGICAL-PATH`, transactional publication (the whole document or nothing), and
ordinary compilation unchanged.

The document is not the structural IR, not scope-HIR v1/v2, and not KIF. It
carries only what the record slice of the identity core needs: binders,
canonical `TypeRef`s, `TypeId`s, `TypeParameterId`s and derived
`ConstructedTypeId`s.

## Entry and publication

```sh
kofun-stage2 --emit-generic-record-hir INPUT.kofun OUTPUT.json LOGICAL-PATH
```

- `LOGICAL-PATH` is validated exactly as scope-HIR v2 validates it: explicit
  valid UTF-8, 1–4096 bytes, already NFC, relative and slash-separated; empty,
  `.` and `..` segments, NUL, Unicode Cc/Cf/Zl/Zp, backslashes, absolute paths
  and a leading ASCII URI scheme are refused. Physical paths never enter an
  identity.
- Input and output must be distinct files; the destination is replaced
  atomically after the complete document validates. Any refusal writes **no**
  document and leaves a pre-existing destination byte-identical.
- The document is canonical JSON on one line terminated by `\n`, with object
  keys in lexicographic order.

Ordinary compilation and `--compile-outcome` keep refusing every generic record
exactly as they do today (`E2S148` on a type parameter, exit 1, no C and no
artifact). #1673 decision 3(a): only this analysis entry accepts, so the two
public modes cannot disagree and the Stage 1 compatibility path is never
entered.

## Identity framing

Both identities use the #303 frame from
[`spec/modules/module-identity.md`](../modules/module-identity.md): SHA-256 over
`"KOFUN\0"`, a u16 big-endian domain length, the ASCII domain, a u32 big-endian
payload length, then the exact canonical payload. Concatenating an unframed
domain and payload is forbidden.

| ID | domain | canonical payload |
| --- | --- | --- |
| `TypeParameterId` | `kofun.id.type-parameter/v3` | owner `TypeId` (32 raw bytes), binder kind `u8` (1 = type), ordinal `u16be` |
| `ConstructedTypeId` | `kofun.id.constructed-type/v3` | declaration `TypeId` (32 raw bytes), `sequence` of the ordered canonical argument `TypeRef`s |
| `PrimitiveTypeId` | `kofun.id.primitive/v1` | the closed builtin name as ASCII bytes |

`TypeParameterId` and `ConstructedTypeId` are the two domains RFC-0017 §2
amendment A01 ([#1689](https://github.com/kofun-lang/kofun/issues/1689)) fixes.
A spelling that carries a display name or source order — the standalone
`generics_frontend.c` checkpoint's `type-parameter:function:NAME:ORD` — is
refused as an identity: `TypeParameterId` is derived from the owner identity,
the binder kind and the ordinal, never from the parameter's spelling, and
`ConstructedTypeId` is derived from the declaration identity and the ordered
arguments, never from the application's source position.

`PrimitiveTypeId` is introduced here because the KIF v3 model takes primitive
identities as inputs and no earlier document pins one. Primitives are a closed
builtin set (`Int`, `Bool`, `Text`, `Unit`), so their identity may be a framed
function of the builtin name: the set is closed, a name cannot be redefined
(§ reserved names), and the name is not a user display name.

### `sequence` and `TypeRef` encoding

`sequence(items)` is `count:u16be` followed by the concatenated encodings. A
`TypeRef` is tagged with one lead byte:

| tag | bytes | meaning |
| --- | --- | --- |
| `1` | `PrimitiveTypeId` (32) | a closed builtin |
| `2` | `TypeParameterId` (32) | a declaration's own binder |
| `3` | `TypeId` (32), `sequence(arguments)` | a nominal application `Name[Arg, …]` |
| `4` | `ConstructedTypeId` (32) | a derived constructed identity |

`nominal(TypeId, ordered arguments)` is what the HIR writes; a
`ConstructedTypeId` is **derived** beside it and is never an input (#1673
decision 2(a)). The bounded surface has one-level applications at most
(`Box[Int]`) and nested applications (`Box[Box[Int]]`) up to the depth limit;
`function` TypeRefs (RFC-0017 tag 5) are out of this slice and refused as an
unsupported form.

## Document

```json
{
  "declarations": [ … ],
  "file_id": "<64 hex>",
  "limits": { … },
  "profile": "kofun.stage2-analysis/generic-record/v1",
  "schema": "kofun.generic-record-hir/v1"
}
```

`file_id` is the existing anonymous-single-file `kofun.id.file/v1` identity over
`LOGICAL-PATH` (scope-HIR v2 §11 reuses the same preimage). A `declaration` is:

```json
{
  "applications": [ … ],
  "binders": [ … ],
  "fields": [ … ],
  "id": "<TypeId>",
  "kind": "record",
  "name": "Box"
}
```

- `binders` — one per type parameter, in declaration order, each
  `{"id": "<TypeParameterId>", "kind": "type", "ordinal": 0..1}`. At most two.
- `fields` — in declaration order, each `{"name": "…", "type": TypeRef}`.
- `applications` — at most eight per declaration, in first-use source order,
  each `{"arguments": [TypeRef], "fields": [substituted fields], "id":
  "<ConstructedTypeId>"}`. `fields` is the declaration's field list with every
  `parameter` TypeRef replaced by the corresponding argument (capture-avoiding,
  applied recursively through nested `nominal` arguments). A surrogate
  `TypeParameterId` never appears in a substituted field.

Field names are carried as `u16be`-bounded UTF-8 (the KIF shape rules); a name
over 65535 bytes refuses.

## Limits

Every limit is part of `limits` in the document and is evaluated before any
output; an over-limit input refuses with no document.

| Limit | Value |
| --- | --- |
| type parameters per declaration | 2 |
| concrete instantiations per declaration | 8 |
| constructed `TypeRef` depth | 8 |
| declarations per document | 64 |
| fields per declaration | 256 |
| field-name bytes | 65535 |
| display bytes | 128 |
| document bytes | 1048576 |

Instantiations are *concrete*: only applications whose arguments are fully
concrete (no free parameter) count toward the eight limit, and each distinct
argument tuple is counted once.

## Refusals

Every refusal is a registered Stage 2 code reported on stdout, exit 1, with no
C and no document. `E2S189`–`E2S191` are already taken by result propagation, so
this slice allocates from **`E2S192`** (#1673's "from `E2S189`" predates that
allocation).

| Code | Refusal |
| --- | --- |
| `E2S192` | more than two type parameters on a record |
| `E2S193` | duplicate type parameter in a declaration |
| `E2S194` | unbound type parameter in a field |
| `E2S195` | application arity does not match the declaration's binder count |
| `E2S196` | unknown nominal type in a field |
| `E2S197` | more than eight concrete instantiations of one declaration |
| `E2S198` | constructed `TypeRef` depth above eight |
| `E2S199` | direct by-value record cycle (`type A = { a: A }`) |
| `E2S200` | mutual by-value record cycle (`A` holds `B`, `B` holds `A`) |
| `E2S201` | unsupported field form (a function TypeRef) |
| `E2S202` | unsupported binder kind on a record (a const/value binder) |

A reference held behind no indirection is by value; this slice has no
indirection form, so every field reference is by value and both cycles refuse.
A name-based spelling used as an identity is refused rather than accepted.

## Determinism

Repeat runs, `-O0`/`-O2` builds, declaration-order reversal of the surrounding
file, and a logical-path remap that preserves the same `LOGICAL-PATH` produce
byte-identical documents. The document never depends on host table order,
addresses, wall-clock time, or process identity.

## Gate

`task generic-record-hir` runs [`check.sh`](check.sh), which executes
[`check.mjs`](check.mjs): it recomputes every `TypeParameterId` and
`ConstructedTypeId` from its preimage with the frame above, checks the schema,
the canonical order, every limit boundary, and every refusal, and applies
mutations to the preimage so a name-based or discovery-order identity is caught.
