# Call arguments v1

Status: accepted design contract for issue #625, partly executable. The
compiler accepts and lowers **direct top-level labelled calls whose fixed
parameter and result slots use `Int`, `Text`, `List[Int]`, `Int?`, a concrete
enum, or a nominal record carrier**, and **the expression-bodied trailing
lambda**, which binds the final functional parameter as a lifted function's
address. A bare binding passed to a parameter declared `take` is invalidated in
source order and a later transfer is refused as `E2S123`. Supplying that final
parameter both by label and by the trailing lambda is `E2S167`, a binding
failure rather than a lowering boundary.

`subject |> callee(arguments)` is implemented for one-stage direct top-level
calls on Stage 2/C11, within the fixed carrier matrix above. `|>` is the
lowest-precedence boundary in the expression grammar, so `a ?? b |> f(c)` has
`a ?? b` as its subject. The subject binds declaration/ABI slot zero, counts
toward effective arity, and is checked against that slot. A bare binding piped
to a declared `take` slot moves exactly once; a compound subject records no
move. C11 lowering evaluates the subject first and exactly once, evaluates each
explicit argument once in source order, stores every value in a fixed slot, and
invokes only after all slots are assigned. #1190, #1226, #1227, and #1228 are
landed and gated by `task call-arguments`.

A pipeline chain is that production iterated: it associates left, every stage
binds, counts, checks and moves its own subject into slot 0, and the C11
lowering nests each stage inside the next subject rather than adding a second
temporary family. `a |> f(x) |> g(y)` is `(a |> f(x)) |> g(y)`, so a stage's
subject is the declared result of the stage before it. #1396 is landed and
gated by the same task.

Bare pipeline targets, pipelines with trailing lambdas,
block-bodied trailing lambdas, labelled calls inside lifted lambdas,
and lexical/member/indirect targets remain at their existing `E2S158` or
earlier named refusal boundaries. Direct-native and Wasm behavior is measured
by the same corpus: the labelled Int call executes on both and is compared
against the C11 golden, and every other shape stops at one named source-located
boundary per backend. #1192 landed the direct-native and Wasm differential.

Naming a boundary is not admitting it. Those refusals previously described the
punctuation each parser wanted next — a missing `,`, a missing `)`, or print's
argument count — about tokens the author had written correctly, and none of
them named the pipeline, the Optional, or the function type that was actually
unsupported. The shapes refuse exactly as before; only the wording moved.

The layers landed in order:

- **#880** — surface. `spec/syntax/call-arguments/parser.mjs` and `format.mjs`
  implement the grammar, the ambiguity boundary, and the canonical form, held
  to `surface-corpus.json` by `check-surface.sh`. Before its refusal existed,
  `fn add(to base: Int, ...)` reported an unknown lexical binding for `base`,
  because the parameter list was read as `to: <type base>` and the internal
  name never bound.
- **#881** — front end. Labels bind to fixed declaration slots in HIR, with
  checking, callable identity, and the KIF digest.
- **#1097, #1107, #1189** — backend. The Stage 2 C11 emitter assigns each written
  argument to a function-local temporary of its own carrier type, in source
  order through the comma operator, then calls the declaration-order ABI
  vector. #1189 adds `Int?`, concrete enum, and nominal record carriers and
  preserves a `take` slot as one semantic transfer. `task call-arguments` is
  the executable gate.
- **#1190, #1226, #1227, #1228** — pipeline. #1190 recognizes the production and
  publishes its spans; #1226 binds the subject to slot zero; #1227 checks
  effective arity, slot-zero type, and the bounded `take` transfer; and #1228
  lowers the checked call through the shared fixed-slot C11 emitter.

The words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative.

## Decision

Kofun will support declaration-site external labels and exactly one trailing
lambda spelling.

```kofun
fn replace(in text: Text, from old: Text, to replacement: Text) -> Text

replace(in: source, from: "a", to: "b")
items.fold(initial: 0) fn(acc, item) => acc + item
```

An external label is distinct from the internal parameter name. A parameter
without an external label is positional. A parameter with an external label is
labelled and the label is mandatory at every ordinary call site. This differs
from Gleam's optional call-site labels: mandatory labels preserve the reversal
protection that motivated the feature. It also differs from Kotlin's use of the
internal parameter name and its overload filtering by names.

The trailing form reuses Kofun's canonical `fn` lambda syntax. There is no
brace lambda, receiver lambda, implicit `it`, or alternate anonymous-function
form in the trailing position.

### Amendment: ordinary lambda spellings (#943)

The accepted contract originally said there was no second anonymous-function
form. That was too broad: the Stage 2 conformance gate already and deliberately
accepts three spellings in ordinary expression position:

```kofun
fn(value: Int) => value * 2
(left, right) => left + right
value => value * 3
```

Issue #943 chooses to retain and document all three. Removing the two shorthand
forms would break a checked-in capability without a language-level reason, and
encoding the future trailing-call restriction in the general lambda grammar
would put call attachment in the wrong layer; issue #880 owns that parser
context. Call-arguments v1 remains narrower: only the canonical `fn(...)`
spelling may follow a closed ordinary call. No new lambda spelling is
introduced by this amendment.

Primary comparisons:

- Gleam labelled arguments separate the external label from the internal name,
  require positional arguments before labelled arguments, and have no runtime
  dictionary cost: <https://tour.gleam.run/functions/labelled-arguments/>.
- Kotlin permits named arguments and one lambda outside the parentheses when
  the last parameter is functional: <https://kotlinlang.org/docs/functions.html>
  and <https://kotlinlang.org/docs/lambdas.html#passing-trailing-lambdas>.
- Kofun keeps the useful declaration label and single trailing position while
  rejecting optional labels, default arguments, argument-driven overload
  filtering, and alternate lambda syntax in v1.

## Grammar

```text
parameter           = [ ownership-mode ], [ external-label ], internal-name,
                      ":", type
external-label      = identifier
ordinary-call       = callee, "(", [ argument-list ], ")"
argument-list       = positional-argument, { ",", positional-argument },
                      [ ",", labelled-argument,
                        { ",", labelled-argument } ]
                    | labelled-argument, { ",", labelled-argument }
positional-argument = expression
labelled-argument   = identifier, ":", expression
trailing-call       = ordinary-call, lambda-expression
lambda-expression   = "fn", "(", [ lambda-parameters ], ")",
                      ( "=>", expression | block )
```

The parser MUST treat a newline or comment between `)` and `fn` as trivia when
the resolved call still needs its final functional parameter. Otherwise `fn`
begins the next expression or declaration according to the ordinary grammar.
The grammar never inserts a trailing lambda before overload resolution: the
callee's single resolved signature must establish that the final parameter is
functional.

Canonical formatting keeps all ordinary arguments inside parentheses, closes
the parenthesis, writes one space, and then writes the trailing `fn` expression.
Expression lambdas stay on the same line when they fit. Block lambdas use the
existing block formatter and are not rewritten into expression lambdas.

**The block body is accepted design, not current capability.** Stage 2 parses
no block-body lambda in any spelling, so every rule above that mentions one
describes the contract an implementation owes rather than behaviour a reader
can rely on today. `spec/grammar.ebnf` therefore does not derive it, per #943,
and the current boundary is pinned executably by `unsupported_block_lambda` in
`tests/conformance/syntax/issues_35_47/run.sh`. That fixture also records that
the present failure is a misparse rather than a named refusal: the parameter
list is not recognised, so `E2S35` reports an unknown lexical binding for a
symbol the author did not write. A named refusal is owed before the feature is.

```kofun
items.fold(initial: 0) fn(acc, item) => acc + item

items.visit(order: depth_first) fn(item) {
    audit(item)
    consume(item)
}
```

Parentheses MUST remain even when the lambda is the only argument:

```kofun
transaction() fn(tx) => commit(tx)
```

`transaction fn(...)` is not valid v1 syntax.

## Binding and diagnostics

Declaration order defines parameter and ABI order. At a call:

1. zero or more positional arguments bind the leading unlabelled parameters;
2. labelled arguments follow all positional arguments and may appear in any
   source order;
3. each declared external label occurs exactly once;
4. internal names are not accepted as labels unless they are also explicitly
   declared external labels;
5. unknown, duplicate, missing, positional-after-labelled, and label-on-an-
   unlabelled-parameter cases are errors;
6. a trailing lambda binds only the final functional parameter and is an error
   if that parameter was already supplied.

Stable diagnostic categories are required; final numeric codes belong to the
frontend implementation child. A diagnostic MUST point to the call-site label
or argument and the corresponding declaration when one exists.

Labels MUST NOT participate in overload selection. Candidate discovery and
overload selection use the same callable identity and type rules as an ordinary
positional call. Only after one signature is selected does label binding
validate that call. Two declarations that differ only by external labels are a
duplicate API, not overloads.

Default arguments are rejected in v1. This prevents omitted arguments from
changing evaluation or API behavior and keeps the pipeline and trailing rules
independent of default selection.

## Evaluation, ownership, effects, and lowering

Every explicit expression evaluates exactly once, from left to right in source
order. A pipeline subject evaluates first. The trailing lambda value evaluates
after all expressions inside the parentheses. These values are then placed in
declaration-order parameter slots before the call.

For example:

```kofun
replace(to: effect_c(), in: effect_a(), from: effect_b())
```

evaluates `effect_c`, `effect_a`, and `effect_b` in that source order, then
passes their temporaries in `in`, `from`, `to` ABI order. Reordering labels does
not reorder effects.

`source |> replace(from: old, to: new)` evaluates `source` first and binds it to
the first parameter. That parameter MAY have an external label; the synthetic
pipeline binding satisfies it without spelling `in:`. No other label may bind
the first parameter again.

Ownership modes precede the external label in a declaration:

```kofun
fn write(take into file: File, bytes data: Bytes) -> Result[Unit, IoError]
```

`take` is the parameter's ownership mode, `into` is its external label, and
`file` is its internal name. Binding labels never weakens `read`, `edit`, or
`take`. The ownership and effect check is performed on the already-bound
declaration-order arguments, while diagnostics retain source-order spans.
The current executable ownership increment is deliberately smaller than that
full rule: it recognizes a bare resolved binding in a direct top-level
labelled argument bound to a `take` slot, invalidates it at that source
position, and reports the existing `E2S123` on a later transfer. It does not
infer moves from compound expressions or implement alias, branch, loop,
lifetime, destructor, or cleanup analysis.

Lowering MUST use ordinary temporaries and fixed parameter slots. It MUST NOT
allocate a dictionary, construct a label table at runtime, pass labels through
the ABI, evaluate an expression twice, or dispatch by string. The KIF/public
interface identity includes each external label or an explicit `unlabelled`
marker in declaration order. Renaming an external public label is an API digest
change; renaming only an internal parameter is not.

## Ambiguity boundary

- `call() fn(x) => x` is one trailing call only when the resolved final formal
  is functional.
- `call()` followed by a newline and a top-level `fn named(...)` is two
  declarations because `fn` is followed by an identifier, not `(`.
- A comment or newline between `)` and `fn(` does not terminate a valid trailing
  call.
- `value |> fold(initial: 0) fn(...)` attaches the lambda to `fold`, then applies
  the pipeline rewrite.
- Nested trailing calls associate with the nearest preceding unresolved call:
  `outer(inner() fn(x) => x) fn(y) => y`.
- A second trailing lambda is always rejected.

The executable decision model in `spec/syntax/call-arguments/` checks these
boundaries, binding failures, evaluation order, fixed ABI slots, public
fingerprints, and the no-runtime-label lowering shape.

## Usability corpus conclusion

Labels are required only when the declaration author identifies semantic risk.
They materially distinguish same-typed arguments such as `from`/`to`, surface a
pipeline subject, and name Boolean or policy values. Short mathematical calls
and ordinary unary functions remain positional. The corpus rejects examples in
which labels merely repeat obvious one-argument names.

The selected rule therefore improves the calls that are hard to review without
taxing every call or admitting optional style drift.

## Implementation slices

The decision deliberately separates follow-up work:

1. #880: parser plus canonical formatter surface and ambiguity corpus — landed,
   gated by `task call-arguments-surface`;
2. #881: HIR/type checking, binding diagnostics, callable identity, and KIF
   digest — landed, gated by `task call-arguments-spec`;
3. #882: pipeline/trailing lowering plus C11/direct-native differential
   evidence — its carrier children landed (#1097 all-`Int`, #1107 widened to
   `Text`/`List[Int]`, and #1189 widened to `Int?`, concrete enum, nominal
   record, and a bounded `take` transfer); #1191 landed the expression-bodied
   trailing lambda; and #1190, #1226, #1227, and #1228 landed recognition,
   slot-zero binding, checking, and shared fixed-slot C11 lowering for the
   one-stage direct top-level pipeline. `task call-arguments` gates that result.
   The other pipeline and lambda shapes named above remain refused, and #1192
   closed the direct-backend differential: the same corpus now runs on
   direct-native and wasm32, one shape executing against C11's own golden and
   every other stopping at a named source-located boundary.

Each child lifts this document's unsupported-current-compiler boundary exactly
as far as its own executable gate reaches, and no further. #880 lifted none of
it: the parser it added deliberately stops short of binding. #1190 first moved
the pipeline production from misleading argument failures to a refusal that
names the form and publishes its spans. #1226, #1227, and #1228 then moved the
one-stage direct top-level Stage 2/C11 shape through binding, checking, and
lowering. The other pipeline, lambda, and target shapes listed above retain
their named refusals; #1192 changes only the direct backend coverage.

The one place the surface parser touches a signature is trailing-lambda
attachment, because this document requires it to: the callee's resolved
signature must establish that the final parameter is functional before the
grammar may insert a lambda. `parser.mjs` reads that single fact and refuses —
as `trailing-callee-unresolved` — when it cannot. Everything else about
binding, including whether a label is known or mandatory, stays with #881 and
its `bindCall` in `spec/syntax/call-arguments/model.mjs`.
