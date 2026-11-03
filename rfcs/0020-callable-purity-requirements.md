# RFC-0020: Callable purity is a one-bit requirement on callable types and trait methods

- Shepherd: hjosugi
- Opened: 2026-11-01
- Status: proposed

Decision record for [#1719](https://github.com/kofun-lang/kofun/issues/1719),
which #1713 kept as its follow-up. It states target semantics. It implements
nothing: no callable type, trait method, diagnostic, KIF field, or typed-sidecar
fact exists because of it.

The source of the decisions is
[`docs/research/callable-effects.md`](../docs/research/callable-effects.md).
That note's questions 2, 4, 6, and 7 are this document's section list. Where the
note predicts behavior after #1711, this document records the target; #1711 has
merged, so the examples here are measured rather than predicted.

Measured against `origin/main@b8b31171` unless a row says otherwise.

## Summary

A callable type may carry a one-bit `pure` requirement:

```kofun
fn apply_pure(f: pure (Int) -> Int, x: Int) -> Int {
    return f(x)
}
```

- An unannotated callable type means **no requirement**, not `io`. `pure (A) ->
  R` is accepted where `(A) -> R` is expected and not the reverse.
- An argument meets a `pure` requirement when it is a named function whose
  inferred summary is `pure`, a lambda whose body is `pure`, or a callable
  parameter that itself carries `pure`. An unannotated parameter forwarded to a
  `pure` one is refused; unknown is never classified as pure.
- `pure fn` before a trait method declaration requires every implementation to
  be pure.
- `pure` becomes contextual in type position: it is the callable requirement
  when it immediately precedes a callable type, and an ordinary identifier
  elsewhere.
- Three new Stage 2 refusals report an impure argument, an unproven argument,
  and an impure trait implementation. `E2S176` keeps its current meaning.
- KIF v3's callable and trait effect fields are assigned exactly two values:
  `0` no requirement and `1` pure. Every other value is refused on read, and
  the absent-field default is removed.
- Across a package boundary a declaration publishes its **declared** purity
  (`pure fn`), never its inferred summary.
- The order is `pub pure fn`.
- The typed sidecar moves to v3 so callable parameter types and their
  requirement are visible to tooling.

Nothing a program can write today changes meaning. The callable syntax and the
three refusals are new surface.

## Motivating consumers

A requirement is needed only when purity must be decided *inside a callee*,
where the argument is a parameter rather than a creation site. Three consumers
need it:

1. **Generic `proven` rewrites over a callable binder** (RFC-0017 §5). A fusion
   law such as `map(map(xs, f), g) == map(xs, fn(x) => g(f(x)))` reorders the
   calls of its arguments. RFC-0017 v1 refuses effects in propositions but
   cannot say that a binder ranges over pure functions.
2. **Standard-library comparators, equality, and hash.** A comparator that
   prints makes the number and order of comparisons observable, so the sort
   algorithm becomes contract.
3. **Explicit parallel library variants**, such as `par_count` beside `count`.
   An `io` callback run in parallel interleaves its output.

The law evaluator, `par` task bodies, `meta`/`const` evaluation, and any
transparent parallel selection do **not** need a callable requirement. The
first names every argument at its call site and uses the joined effect; the
other two either do not classify concurrency as `io` or have no implemented
surface. The requirement belongs where impurity would expose an algorithm, not
on every callback.

## The callable type

### Spelling

`pure` belongs to the callable-type former, written between the binding name and
the parameter list:

```kofun
f: pure (Int) -> Int
```

Because `->` is the lowest-precedence type operator, the position is
unambiguous:

| Source | Meaning |
|---|---|
| `pure Int -> Int` | a pure unary callable |
| `Int -> pure Int -> Int` | `Int -> (pure (Int -> Int))` |
| `(pure (Int) -> Int)?` | an optional pure unary callable |

`pure f: (Int) -> Int` is refused: `pure` there is an external parameter label,
not a type word (measured `E2S164`). `io` is refused in every type and
annotation position; `spec/effects/pure-io-v1.md` names one spelling. The
effect-row suffix `! …`, including `! {}` and `! io`, stays free for a later
row design and is not accepted by this RFC.

### Contextual `pure`

`pure` is contextual in type position. It is the callable requirement only when
the next token begins a callable type; otherwise it is the ordinary identifier
it is today.

- `type pure = { a: Int, }` continues to declare an ordinary nominal record
  (measured `ok`).
- A parameter over that type, `f: pure -> Int`, is refused `E2S218`'s *syntax*
  sibling rather than silently reinterpreted. No accepted program spells it at
  the audited commit.
- A local or top-level binding named `pure` is unchanged. The keyword is
  contextual in type position only; it never becomes reserved as an expression
  identifier.

### Identity and subsumption

The bit is part of callable type identity, alongside ownership modes
(`docs/TYPE_SYSTEM.md` § Callable types). Two identities exist for each
callable shape: the requirement and the absence of one.

Exactly one subsumption rule relates them:

```text
pure (A) -> R  ≤  (A) -> R
```

The relation is covariant in a callable's own effect and contravariant through
a callable-typed parameter: a parameter that requires `pure` may be passed
where an unannotated callable is expected, but a `pure`-requiring parameter
cannot accept an unannotated callable. `pure` is *not* a general type operator
and does not distribute through records, lists, or optionals; it attaches to
one callable former.

## The argument rule

An argument meets a `pure` requirement when it is one of:

1. **a named function whose inferred summary is `pure`.** `inc` needs no
   annotation; its summary answers.
2. **a lambda whose body's summary is `pure`.**
3. **a callable parameter that itself carries `pure`.**

Every other argument is refused. In particular, an unannotated callable
parameter forwarded to a `pure` one is refused, because its effect is unknown
and v1 never classifies the unknown optimistically. The refusal is distinct
from "this argument is `io`": the compiler may know one is impure and not know
the other, and the two need different fixes.

The rule uses the same summary `pure-io-v1.md` already defines, and #1711's
value-reference edge is unchanged: a name is charged to the function whose body
creates it, and a call through a parameter adds nothing.

`pure fn` keeps both meanings it has today:

- `pure fn forward(f: pure (Int) -> Int, x: Int) -> Int` is pure outright;
- `pure fn forward(f: (Int) -> Int, x: Int) -> Int` stays "pure apart from
  `f`", and a call through `f` is not a root.

This RFC does not reinterpret the second. It adds a way to remove the
qualification, not a replacement for it.

## Trait methods

A trait method declaration may carry the same word:

```kofun
trait Same[T] {
    pure fn same(read left: T, read right: T) -> Int
}
```

The declaration requires every implementation's method to be pure. It adds no
requirement to callers: a call through the dictionary is charged at the
selection site, as RFC-0017 §3 already requires, and the method's purity is a
property of the implementation, not of the trait name.

Associated effects — letting each implementation choose its own effect — are
deferred. With one effect bit the creation-site rule already gives
per-implementation precision: the site that selects an implementation is where
that implementation's method values are created. A later effect vocabulary
beyond `pure < io`, or associated types in the traits frontend, reopens the
question.

## Diagnostics

`E2S176` is unchanged. It means "this declaration's own summary is `io`", and
its offset is the annotated declaration's `fn` keyword. This RFC adds three
codes fixed at an argument or a signature instead:

| Code | Meaning | Primary span | Related span | Example |
|---|---|---|---|---|
| `E2S218` | impure argument | the argument | the parameter's `pure` | ``argument `noisy` to `pure` parameter `f` of `apply_pure` reaches `print` directly`` |
| `E2S219` | unproven argument | the argument | the forwarded parameter's declaration | ``argument `g` to `pure` parameter `f` of `apply_pure` is parameter `g` of `outer`, which has no `pure` requirement`` |
| `E2S220` | impure trait implementation | the implementing method | the trait method's `pure` | ``method `same` of `impl Same[Int]` reaches `print` through `log`; trait `Same` declares it `pure` `` |

Rules:

- A lambda argument is named "lambda argument". The root and first hop follow
  `E2S176`'s rule, so the two codes never name different hops for one edge.
- `E2S219` names no root, because none is known. Its fix is a signature in
  another function, so it does not borrow "reaches `print`".
- They are new Stage 2 codes, not `E2S176`, and they stay out of the `E3xx`
  band for the reason `pure-io-v1.md` gives.
- One fault gets one diagnostic. When a `pure fn` passes `noisy` to a `pure`
  parameter, report the argument refusal, not `E2S176` as well. The first
  offending argument in source order is reported.
- The published fact for a value-reference edge reuses `effect-io-callee`, as
  #1711 does.

The codes are allocated here and registered when the implementing child lands.

## KIF

RFC-0017's KIF v3 reserves a `u16` effect field on the callable `TypeRef`, the
`GenericFunctionDeclaration`, and the `TraitMethod`. Its codec currently writes
`0` when the field is absent and reads any value back. This RFC assigns the
field:

| Value | Meaning |
|---|---|
| `0` | no requirement (callable type), or no declared effect (declaration) |
| `1` | `pure` |

Every other value is refused on read. The absent-field default is removed: the
field is required in v3, because the bit is covariant in a declaration's own
effect and contravariant in a parameter's requirement, so neither value is
conservative in both positions. A dropped parameter requirement would let a
consumer pass `io` to a callee that relies on purity.

Across a package boundary a declaration publishes its **declared** purity
(`pure fn`), not its inferred summary. An inferred summary in an interface
turns a body edit — one added `print` — into an interface break consumers see as
a digest change. Within one package the inferred summary stays the input.

`pub` comes before `pure`: `pub pure fn`. `pure pub fn` is refused.

## Typed sidecar

The typed sidecar moves to **v3**. v2 displays callable parameter types as
`Fn`, so `apply`'s published type is `(Fn, Int) -> Int` and a requirement is
invisible to tooling. v3 displays the callable shape and its requirement, and
publishes the declared `pure fn` assertion the same way `pure-io-v1.md` already
requires a version bump to publish.

`spec/concurrency/scoped-captures-v1/v1.sha256` freezes the v1 files. v2 and v3
inherit the unchanged v1 definitions and own every changed definition; neither
edits a v1 file in place.

## Documentation

`docs/TYPE_SYSTEM.md` § Effects replaces the sentence that says the `pure`
keyword "will be decided after evaluating effect inference and diagnostic UX".
It points at this RFC and `spec/effects/pure-io-v1.md` for the decided surface.
`docs/TYPE_SYSTEM.md` § Callable types lists the requirement in callable type
identity, beside ownership modes.

## Worked examples

Each example is the header in
[`docs/research/callable-effects.md` § Checked examples](../docs/research/callable-effects.md#checked-examples)
followed by that section. The commands are `bin/kofun check FILE` on
`origin/main@b8b31171`.

| Example | Source | Today | This RFC |
|---|---|---|---|
| x02 | `pure fn quiet` passes `noisy` to `apply` | `E2S176`: ``pure fn quiet` reaches `print` through `noisy` at byte 361`` | unchanged |
| x13 | `f: pure (Int) -> Int` | `E2S35`: `malformed parameter head at byte 378` | accepted |
| x18 | `trait Same[T] { pure fn same(…) -> Int }` | `E2S02`: `expected top-level fn, type, or let at byte 356` | accepted |
| x20 | `pub pure fn quiet` | `E2S33`: `visibility modifier pub must be followed by a top-level fn or type declaration at bytes 356..359` | accepted; `pure pub fn` refused |
| x30 | `type pure = { a: Int, }` | `ok` | unchanged |

x05, x09, x16, and x25 measure the creation-site rule this RFC builds on; they
are unchanged by it and remain checked in the research note.

## Compatibility

**Additive.** The callable requirement, the trait-method requirement, the three
refusals, the KIF values, and the sidecar v3 are new surface. No tracked
program writes a `pure` callable type or a `pure` trait method, and no
production KIF v3 or typed-sidecar v3 artifact exists. `type pure` and a binding
named `pure` keep their meaning. `pub pure fn` becomes accepted where it was
`E2S33`; no program depends on that refusal.

Corpus query:

```sh
git grep -nE 'pure +\(' -- '*.kofun' | wc -l
git grep -nE 'pure fn' -- '*.kofun' | wc -l
```

Result at `origin/main@b8b31171`: `0` callable requirements and `0` trait
method declarations. The `pure fn` matches that exist are top-level function
boundaries, whose meaning this RFC does not change.

## Non-goals

- effect variables, associated effects, effect rows, handlers, or any effect
  label beyond `io`;
- purity reflection (`purityOf`, `@ParallelWhenPure`);
- implementation of any of the above, which is a later child;
- restarting #1714's discarded-pure-result refusal, which `spec/effects/pure-io-v1.md`
  already records;
- a second spelling for the requirement.

## Implementation split

This RFC opens the following children, each with its own Definition-of-Ready
body:

1. callable type parsing, contextual `pure`, identity, and subsumption;
2. the argument rule and the three diagnostics, with the first-in-source-order
   rule;
3. `pure fn` trait method declarations and the implementation check;
4. KIF v3 effect values, the required-field change, and declared purity across
   package boundaries;
5. typed sidecar v3 and the `TYPE_SYSTEM.md` effect section.

Each child that edits the canonical Stage 2 pair serializes with the live pair
owner. This document implements none of them.
