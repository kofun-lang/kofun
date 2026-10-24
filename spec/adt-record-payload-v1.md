# Flat record payloads for concrete enums

The flat, non-generic record-payload slice that
[#1258](https://github.com/kofun-lang/kofun/issues/1258) Q1(c) carved out of the
ADT-match umbrella [#30](https://github.com/kofun-lang/kofun/issues/30) so that
the closed `HttpError` ([#1697](https://github.com/kofun-lang/kofun/issues/1697),
[`spec/http-error-v1.md`](http-error-v1.md)) did not have to wait for
[#1287](https://github.com/kofun-lang/kofun/issues/1287), which is six
pair-editing issues deep behind #1268.

It is the bounded widening
[`spec/adt-match-v2/PROFILE.md`](adt-match-v2/PROFILE.md) section 1 already
names: *zero or one payload TypeRef per constructor; multiple logical fields use
one nominal record payload.* It is not the general lowering. It adds no generic
payload, no nested or or-pattern, no ownership destructuring, and no result join;
#1287 and its predecessors still own those, and nothing here is a step they may
skip.

This file says exactly what the compiler could already carry, what this slice
adds, and where it stops. The gate that pins every line of it is
`task http-client-errors`.

## What Stage 2 carried before

Measured on `origin/main@79df6079` with `kofun-stage2 --compile-outcome`:

| Shape | Result |
|---|---|
| `| Ready(value: Int)` constructed and matched | carried: a tag and one `int64_t` payload slot, `KofunEnumValue` |
| `| Protocol(detail: ProtocolDetail)`, record declared, constructor unused | accepted, and the IR records the constructor with payload type `ProtocolDetail` |
| the same constructor constructed, named in a pattern, or in a value match | `E2S32`: "declares a payload outside this Core slice; one `Int` field is supported" |
| `| Broken(code: Int, retry_safe: Bool)` used | `E2S32`, the same sentence |
| a record with a `Phase`-typed (enum) field | `E2S32` at the record declaration |
| a record of `Int`, `Bool`, `Text`, `List[Int]`, `Bytes` fields | carried, as a whole binding or call, by value |

So the declaration was already admitted and recorded; the construction, the
pattern, and the representation were the missing parts. The standalone ADT
frontend `bootstrap/stage2/adt_frontend.c` (zero or one `Int` field, `E2S41`
beyond) is a separate checkpoint and is unchanged.

## The slice

A **flat payload record** is a declared, non-generic, non-const-parameterized
record with at least one field, every field `Int` or `Bool`. It is trivially
copyable, so a constructor carries it by value and nothing needs cleanup.

A constructor of a non-generic top-level enum may declare exactly one payload
field whose type is a flat payload record: `Protocol(detail: ProtocolDetail)`.
The same enum may mix payload-free, one-`Int`, and record-carrying constructors,
and a record type may be named by several constructors.

| Position | Behaviour |
|---|---|
| construction | `Ctor(record)`, where `record` is a whole binding of that exact record type, or a call returning it. In an annotated `let`, an argument, and a `return`: the positions a one-`Int` enum value already has. |
| statement `match` | `Ctor(name)` binds `name` as a **copy** of the payload record, declared before the guard; `Ctor(_)` binds nothing. `name.field` reads a field. |
| value-position `match` | the same binding and reads, in every arm and guard |
| guard | may read a payload field: `Ctor(d) if d.retry_safe => ...` |
| catch-all | `_` and a binding catch-all, as before |
| exhaustiveness | unchanged: `E2S25` names a missing constructor, `E2S26` a duplicate or unreachable arm |

Because the binding is a copy and the record is flat, the record that built an
error stays readable afterwards, and one record may seed two errors.

### Representation

Every enum in a source shares one C type, `KofunEnumValue`. A source that
declares **no** record payload is emitted exactly as before: a tag and one
`int64_t payload`. A source that declares at least one record payload gets a
tagged union, emitted after the record declarations because its members are
those record types:

```c
typedef struct {
    int64_t tag;
    union {
        int64_t payload;
        KofunRecord_ProtocolDetail payload_Protocol;
        ...
    };
} KofunEnumValue;
```

There is one member per record-carrying constructor, named after the
constructor, and `payload` stays the first member, so a one-`Int` constructor
keeps its slot. Initializers in such a source are named (`{.tag = INT64_C(0),
.payload_Protocol = k_b0}`), because positional braces on the anonymous union
fail `-Wmissing-braces` under `-Wall -Wextra -Werror -pedantic`. The widened
value is shared by every enum in that source, so one program never mixes the two
spellings. The widening is decided by the same declaration scan in both halves of
the pair.

## Where it stops

Each of these is refused or left out, and `tests/conformance/http-client-errors`
holds the edge with the exact diagnostic (`refusals.tsv`).

- **A payload record with a `Text`, `List[Int]`, or `Bytes` field**, or a
  const-parameterized record: not flat. `E2S32`, the widened "declares a payload
  outside this Core slice" sentence, at the constructor's first use.
- **An enum-typed field** stays `E2S32` at the record's own declaration. The
  slice does not widen what a record may hold; this is why `HttpError` carries
  phase and dimension as `Int` codes.
- **More than one payload field**: still `E2S32`. Several logical fields travel
  as one record.
- **The wrong record, an `Int`, an inline `Ctor(R(...))` construction, a bare
  `Ctor`, or a pattern that names the constructor alone**: `E2S32`, each with its
  own sentence.
- **The checked-capture HIR emitters** (`--emit-capture-hir-v2` and the scoped
  ownership emitter built on it) type a constructor formal as `Int`. They refuse
  a record payload with `E2S154` in both halves rather than mistype it. The
  ordinary `check` and `build` paths carry it.
- **Nested patterns, record sub-patterns, `take` or field-level moves of a
  payload, and generic payloads**: unchanged from adt-match-v2 section 2 and
  sections 4-5; a flat record needs no move because it is copyable.
- **Native and Wasm backends**: not touched. This is C11 Stage 2 only.

## Found, not fixed here

Both predate this slice and are measured on `origin/main@79df6079`:

- The two halves disagree on value-position matches independently of any record
  payload: the Kofun half refuses `return match ...` (`E2S03`, "missing function
  close") and, for `let x: Int = match ...`, records the end of the whole match
  as the binding's `visible_start` where the C half records an earlier byte. The
  gate holds that fixture to outcome, emitted C, and tokens, and requires the IR
  to differ only in `binding|` rows.
- A record binding in an `Int` position compiles to C that does not compile
  (`print(detail)`, or `Ready(detail)` for a one-`Int` payload). The gate does
  not pin it, because pinning it would record a hole as behaviour.

## Compatibility

`additive`. Every tracked `.kofun` source other than the two payload-refusal
fixtures below compiles to byte-identical C, IR, and tokens, with the same exit
status and printed outcome, before and after (1,468 sources compared). The one
visible delta is the `E2S32` sentence, which now says "one `Int` field or one
flat `Int`/`Bool` record is supported"; its two pinned goldens
(`tests/conformance/syntax/issues_35_47/enum_payload_multiple_fields.stdout` and
`enum_payload_unsupported_field.stdout`) changed with it and still refuse.
