# Result propagation: Stage 2 refusals

`task result-propagation` holds the Stage 2 pair to the part of
[`spec/result-propagation-v1.md`](../../../spec/result-propagation-v1.md) it can
reach before a `Result` type exists (#1662). Stage 2 parses postfix `?` and
records each one as a typed scope-HIR node, and since nothing it can type is a
`Result[T, E]`, every `?` is refused. Positive lowering is #1250's.

## What is parsed

`?` is a postfix step at the level of a call or a field read. The shared
expression reader steps over it, so `f(x)?.name` is one expression,
`(f(x)?).name`, and a `?` never ends a statement or an expression early.
Optional types `T?` are a different grammatical context: the `?` of a `let`
annotation, a lambda parameter list, or a `->` result is never read as
propagation.

Every `?` in expression position becomes one scope-HIR record, in source order:

```text
propagate|QUESTION|OPERAND-START|OPERAND-END|SCOPE|OPERAND-TYPE
```

An operand is a postfix chain (a primary, then calls, indexes, field reads and
earlier `?`s), or a whole value `if`/`else` chain or `match` whose closing `}`
the `?` follows. It appears once, as a byte span. Its type is the one an
unannotated `let` initializer of the same expression would get, with these
shapes answered first: `null` is `null`; a parenthesized operand is typed by
what it encloses; a value `if` or `match` is `Int`, the only join value control
has in this slice; `print(...)` is `Void`; a call to a declared `-> Int?`
function is `Int?`; and a call whose callee resolves to nothing has no type,
recorded as an empty type field.
`kofun-stage2 --emit-scope-hir` shows the records; `grammar.propagate` is the
exact list for `grammar.kofun`.

## What is refused

| Code | Refusal | Where | Checkpoints |
| --- | --- | --- | --- |
| `E2S191` | `?` directly on a pipeline stage (`a \|> f?`, `a \|> f()?`); suggests `(a \|> f())?` | while parsing, before `E2S158` | none |
| `E2S190` | the operand is an optional; suggests `ok_or(error)?` | before lowering | IR and tokens |
| `E2S189` | the operand is not a `Result[T, E]`; names its type | before lowering | IR and tokens |

Each refusal exits 1, writes no C, and puts the primary span on the `?` token
and the secondary span on the operand (`at byte Q; operand at byte S`). The C
half also publishes the operand as a related span of the structured
diagnostic.

An operand with no type is not refused as `E2S189`, because there is no type to
name and inventing the historical `Int` default would hide the real defect. The
spec desugars `expr?` after name and type resolution, so the operand keeps its
own resolution diagnostic: `E2S16` at the unknown callee, byte for byte the
line the source gives without the `?`, just as an unknown binding operand
already gets `E2S35` from scope construction. It is still exit 1 and never
reaches `E2S10`.

The check order is syntactic, then operand. `E2S191` runs while parsing, so it
wins over any operand refusal anywhere in the program. The operand refusals run
after the move rules and before every typing and lowering validator, the first
`?` in source order is reported, and for that `?` the optional refusal is
checked before the general one: an optional is also not a `Result`, and the
specific suggestion is the useful one.

## What the gate checks

- The seven measured rows of #1662 (`let_call` through `decimal_division`) and
  the order, optional, and grammar fixtures each exit 1 with their golden, the
  `?` at the primary span, the operand before it, and the pinned checkpoints.
  None reaches `E2S10` or exit 3.
- Sixteen generated sources, one `?` each, cover every expression position:
  `let` initializer, statement, `return`, positional and labelled arguments,
  `if` condition, both operands of a binary operator, a group, an inner group,
  assignment, a lambda body, a field read after the `?`, a value `if`, an
  `else if` chain in statement position, and a `match` on a Bool.
- `value_if_operand` and `match_operand` pin operands that end in `}`;
  `unknown_callee` pins the `E2S16` rule above against the same source without
  its `?`.
- `bin/kofun check` and `bin/kofun build --emit-c` print the same line, exit 1,
  write nothing, and never run the Stage 1 compiler.
- `pair.mjs` runs the Kofun half under the canonical interpreter against the C
  half on every fixture and generated source: same exit, output, checkpoints,
  and scope HIR.
- Six rebuilt mutants: the old path (reader stops at `?` and the nodes are
  unread) answers `E2S10`/exit 3 and `E2S147` again; unread nodes alone let
  `one()?` compile with the `?` dropped, which is why the refusal runs ahead of
  lowering; a skipped stage check falls back to `E2S158`; a reader that stops
  at `?` mis-spans the lambda body in `grammar.kofun`; with no value `if` or
  `match` operand, `value_if_operand` is `E2S10`/exit 3 again; and with every
  callee resolved, `unknown_callee` is `E2S189` naming an invented `Int`.

## Boundaries

- `let v: Int? = null?` is refused by scope construction as `E2S35`: `null`
  resolves only where it is the whole value of an `Int?` slot, and `null?` is
  not. `null? ?? 0` is such a slot, and `optional_null.kofun` pins it.
- The non-Result enclosing function refusal is unreachable here, because the
  operand is refused first; #1250 registers it. The error-type mismatch
  refusal needs two `Result` error types.
