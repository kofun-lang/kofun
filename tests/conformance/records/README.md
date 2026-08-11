# Bounded nominal record frontend

This issue [#546](https://github.com/kofun-lang/kofun/issues/546) gate implements
the accepted v1 record decision recorded in
[`spec/records-v1.md`](../../../spec/records-v1.md) over one deliberately small
Stage 2 surface:

- `type Name = { field: Type, ... }` nominal record declarations;
- `Name(field: value, ...)` labelled call-form construction;
- `value.field` typed reads;
- flat payload-free `type Name = | A | B` enumerations, so a record can carry a
  `TokenKind` beside `Text` and `Int`;
- functions with `read`/`take` parameter access, `let`/`let mut`, `if`/`else`,
  `while`, `for ... in`, `List[T]` literals and indexing, and the `len`,
  `char_code`, `slice`, `count`, and `push` builtins.

The surface exists to make the record claim observable. `token_pipeline.kofun`
is a working scanner: `scan` produces a `List[Token]` from real input and
`render`, `width`, and `last_start` consume it. That is the value #546 says
Kofun cannot currently express, so a scanner that runs is the evidence, not a
`Point(x, y)` toy.

## Artifacts

Each accepted source produces three deterministic text artifacts.

| Artifact | Header | Contents |
|---|---|---|
| `.ir` | `kofun-record-ir/v1` | nominal record/field/enum/variant identities, declaration-order fields, function signatures and parameter access, every construction with its written and declared field order, and every field read with its declared type |
| `.layout` | `kofun-record-layout/v1` | the named data-layout inputs for each target, untagged declaration-order field offsets for `x86_64-linux` and `aarch64-linux`, and a cross-target agreement row |
| `.run` | `kofun-record-run/v1` | the evaluated result of every zero-parameter function |

`run.sh` recomputes cross-target agreement from the emitted rows rather than
trusting the agreement row, and it runs the token pipeline twice and compares
all three artifacts so nothing depends on allocation or iteration order.

## Boundaries

There is intentionally no module system, visibility enforcement, generic
record, trait, method, default value, spread/update form, pattern
destructuring, tuple, structural row, C/native/wasm lowering, or stable ABI
here. The layout table is a target-parameterized semantic computation, not an
emitted object layout: `#120` owns the production `AggregateLayout` contract
and the backends that consume it.

Record fields are immutable in v1, `take` moves a whole record, and
`take value.field` is rejected, so no partially initialized or partially
dropped record state exists.

## Diagnostics

| Code | Rejected input |
|---|---|
| `E2S106` | a bound of this gate is exceeded |
| `E2S107` | malformed declaration, block, or expression |
| `E2S108` | duplicate type, variant, or function name |
| `E2S109` | duplicate field in a record declaration |
| `E2S110` | unknown field, parameter, or result type |
| `E2S111` | generic record or generic type argument |
| `E2S112` | recursive record declaration |
| `E2S113` | unknown name, function, or record type |
| `E2S114` | duplicate field in a construction |
| `E2S115` | missing field in a construction |
| `E2S116` | unknown field in a construction |
| `E2S117` | wrong field type in a construction |
| `E2S118` | positional construction, or labels on a call |
| `E2S119` | `Name { ... }` brace construction |
| `E2S120` | unknown field read, or a field read on a non-record |
| `E2S121` | field assignment, `edit` access, or assignment to an immutable binding |
| `E2S122` | partial move such as `take value.field` |
| `E2S123` | use after `take` |
| `E2S124` | any other type or arity mismatch |
| `E2S125` | `{` in expression position, including a map literal |
| `E2S126` | a bounded evaluation failure |

A rejected source produces the diagnostic on stdout, exit status 1, no
artifact, and nothing on stderr.

## The same ownership rule in the compiler a user runs

The table above is the standalone `bootstrap/stage2/record_frontend.c`, which
is not linked into `bootstrap/stage2/compiler.c`. Before
[#946](https://github.com/kofun-lang/kofun/issues/946) none of it reached
`bin/kofun check`: the production frontend read `take` as a name nobody
declared and answered `E2S35`.

The canonical `compiler.kofun`/`compiler.c` pair now carries the whole-binding
slice of that rule, with the wording above rather than a paraphrase of it. The
`production_*.kofun` fixtures gate that production path, while their siblings
gate the standalone record frontend. They remain separate because they hold
two producers to one language; Int-only is no longer a field-type prerequisite
now that the production slice admits `Text` and bounded `List[Int]` fields.

| Fixture | Result |
|---|---|
| `production_take_accepted.kofun` | accepted, lowered, built under `-Werror`, and run |
| `production_partial_move.kofun` | `E2S122`, the whole `take value.field` statement |
| `production_double_take.kofun` | `E2S123` *already moved*, both spans whole statements |
| `production_use_after_move.kofun` | `E2S123` *cannot be used again*, use site primary, move site related |
| `production_read_parameter.kofun` | accepted `read` parameter, lowered, built, and run |

Three of the standalone frontend's four ownership refusals are reproduced.
The fourth, `E2S122` for moving a `read` binding, remains outside the bounded
production move validator. #881 did retire the older prerequisite boundary:
`fn peek(read token: Token)` now binds `token` in HIR, lowers its record field
read, builds under `-Werror`, and runs. `production_read_parameter.kofun` pins
that accepted path rather than retaining the obsolete E2S35 refusal helper.

Everything else the standalone frontend decides — loops, branches, inferred
moves, partial-move state, `Text` — stays out of the production rule. A moved
binding is refused where it is mentioned again in the same function body, in
source order; nothing about control flow is guessed at.

Compiling all 979 checked-in `.kofun` sources with the compiler before and
after the rule found **one** difference outside these fixtures, and it is a
diagnostic rather than a program:
`tests/conformance/inference/hm-levels/ownership.kofun` is `fn main() { take
value }`, with no `value` in scope. It used to be refused as
`E2S35: unknown lexical binding \`take\``, blaming the statement's own keyword;
it is now refused as `E2S35: unknown lexical binding \`value\``, blaming the
name that is actually missing. Its owning gate reads that file with
`bootstrap/stage2/hm_levels_frontend.c` against an `HML006` golden, which is
unchanged. No accepted program's emitted C, IR, or token tape moved.

Run:

```sh
sh tests/conformance/records/run.sh
```
