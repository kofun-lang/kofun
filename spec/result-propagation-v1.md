# Result propagation v1

Status: accepted normative design for GitHub issue #626. Stage 2 parses
postfix `?` as a typed scope-HIR node and implements refusals 1–3 of
*Diagnostics* below — operand is not a `Result` (`E2S189`), optional operand
(`E2S190`), and `?` on a pipeline stage (`E2S191`) — gated by
`task result-propagation` (#1662). Stage 2 has no `Result` type, so every `?`
it sees is refused. Pending in #1250: positive lowering, the non-Result
enclosing function refusal, and the hand-desugared twin corpus. The
error-type mismatch refusal stays unimplemented until two `Result` error types
exist. No formatter, debugger mapping, Stage 1, or direct/Wasm backend
implements the syntax.

The words **must**, **must not**, and **may** are normative.

## Decision

Kofun adopts exactly one initial sequencing sugar: **Result-specific postfix
propagation**, written `?`, restricted to expressions of type
`Result[T, E]` inside functions returning `Result[U, E]` with the same `E`.

```kofun
fn load(read path: Text) -> Result[Config, ConfigError] {
    let source = fs.read_text(path).map_err(ConfigError.Io)?
    let raw = parse(source)?
    let config = validate(raw)?
    return Ok(lower(config))
}
```

The baseline always works without it: ordinary functions, exhaustive
`match`, and pipelines with `result.flat_map` / `result.map` remain
sufficient, and the formatter never rewrites between the two forms.

## Desugaring

`expr?` desugars, after name and type resolution, to the typed core:

```kofun
match expr {
    Ok(value) => value,
    Err(error) => return Err(error),
}
```

- **Evaluation**: `expr` is evaluated exactly once, in its ordinary
  left-to-right position; `?` adds no second evaluation and no reordering.
- **Ownership**: the operand is consumed (`take`). On `Ok` the payload
  moves into the surrounding expression; on `Err` the error moves into the
  early return. No continuation is captured — this is early return, not a
  callback.
- **Effects**: the desugaring introduces no effect; the expression's
  inferred effects are exactly those of `expr` plus the enclosing
  function's ordinary return path. Deterministic cleanup scheduled in the
  enclosing scopes runs on the early return exactly as for a written
  `return`.
- **Errors**: v1 requires the operand's `E` to equal the enclosing
  function's error type. There is no implicit conversion; `.map_err(...)`
  before `?` is the explicit bridge. A conversion trait may be layered on
  later as a separate decision — additive, and only after traits (#DD-032)
  have law-checked evidence.

## Grammar and the `T?` boundary

- `?` is a postfix operator on expressions, binding tighter than any binary
  operator and equal to other postfix forms (call, field access):
  `f(x)?.name` parses as `(f(x)?).name`.
- Type position and expression position are disjoint grammatical contexts,
  so optional types `T?` (DD-002) and expression propagation never compete
  for the same token occurrence. The overlap is visual, not grammatical.
- Two guardrails keep diagnostics unambiguous:
  1. `?` applied to a `T?` optional value is a dedicated refusal that
     suggests `optional.ok_or(error)?` — optionals do **not** propagate in
     v1, so `?` always means the same thing.
  2. a bare `?` directly on a pipeline stage (`a |> f?`) is refused with a
     parenthesize suggestion (`(a |> f)?`), because the tight postfix
     binding would otherwise apply it to the stage function rather than
     the piped result.
- Statement termination: `?` never ends a statement by itself; automatic
  termination rules are unchanged.

## Diagnostics

Each refusal has a stable code and names the fix:

- propagation outside a `Result`-returning function → names the enclosing
  return type and suggests `match` or changing the return type;
- operand is not `Result` → names the operand type; the optional-operand
  case additionally suggests `ok_or`;
- error-type mismatch → names both error types and suggests `map_err`;
- `?` on a pipeline stage → suggests parentheses.

Diagnostic spans point at the `?` token, with a secondary span at the
operand. After desugaring, debug info maps the generated `match` to the `?`
token: stepping stops there on the `Err` path, and stack traces show the
enclosing function with the `?` line, never synthetic frames.

## Alternatives considered

Exactly the four families #626 required, one accepted:

**1. Result-specific postfix propagation — accepted.** Merits: the dominant
`Result` pain (multi-step sequencing) becomes shallow immediately; no
dependency on traits, laws, or higher-kinded types; the desugaring is four
lines of typed core; Rust demonstrates a decade of fluency. Demerits:
visual overlap with `T?` demands the two guardrails above; it serves
`Result` only, so optionals and future monads gain nothing until their own
decisions land.

**2. Gleam-style `use value <- result.try(call())`.** Merits: generalizes
past `Result` (resources, callbacks) without new semantics per type.
Demerits: desugars to a captured continuation, so ownership, early return,
debugger stepping, and stack traces all become callback-shaped — the
heaviest specification burden of the four for the least common case.
Rejected for v1; not precluded later.

**3. Bind statement `let value <- expression` over a lawful trait.**
Merits: the cleanest connection to #551 law declarations and the only path
to generic monadic sugar. Demerits: requires trait capabilities plus
law-evidence plumbing before any ergonomic payoff, and #626 forbids
resolving sugar through an unverified `bind` name; choosing it now would
block everyday `Result` code on the law engine. Rejected for v1; the law
boundary below keeps the road open.

**4. No sugar yet.** Merits: zero grammar risk; keeps pressure on library
ergonomics. Demerits: the three-step corpus stays three nested matches or
a `flat_map` ladder, and the cost lands on the language's most common
error-handling path indefinitely. Rejected.

Token alternatives inside family 1: `!` postfix (reads as assertion and
collides with future never-type conventions — rejected); a `try` keyword
prefix (reintroduces rightward drift the postfix form exists to remove —
rejected); `?` accepted with the guardrails above.

## Law boundary

`Monad` remains an ordinary library law/trait under #551 — nothing here
adds a lexer keyword or resolves through a method name. If a generic bind
sugar ever lands, it requires an explicit trait capability with law
evidence carried separately (`bounded-exhaustive` / `proven-finite` /
`proven`), and lack of proof limits optimization claims, never runtime
semantics. This spec's `?` is deliberately monomorphic to `Result` so that
no law claim is needed for it at all.

## Non-goals

- optional (`T?`) propagation, exception semantics, implicit truthiness,
  or unchecked unwrap;
- introducing `do`, `use`, or `<-` alongside `?`;
- implicit error conversion in v1;
- making beginners learn Monad terminology for ordinary errors.

## Validation

The gate lands with the implementation children (parser/HIR, type/effect,
formatter, debugger, backends — split only after this document is
accepted):

| Check | Fixture | Expected result |
|---|---|---|
| Corpus | three-step parser with `?` and its hand-desugared twin | identical observations, byte-identical backend IR |
| Refusals | optional operand, non-Result operand, mismatched `E`, pipeline-stage `?`, non-Result function | each stable code fires with its suggestion |
| Grammar | `T?` declarations mixed with `?` expressions, `|>`, assignment, statement ends | no ambiguity, formatter round-trips |
| Ownership | moved operand reused after `?` | ordinary move refusal, span on the reuse |
