# Callable effects research

Status: research decision for issue #1713. It changes no compiler,
specification, KIF, or typed-sidecar artifact. Every Kofun result below was
measured on `origin/main@638842470f622bbabb50c34a8bd9540e61dcbf33` on
2026-10-04 with the commands in [Checked examples](#checked-examples). The
soundness fix this note starts from, #1711, was open with no pull request at
that commit, so each statement about Kofun *after* #1711 is a prediction from
the rule #1711 states and is marked "predicted".

## Decision

Keep creation-site charging, the rule #1711 adds, as the v1 rule: a function
value's effect is charged to the function whose body creates it, and a call
through a callable parameter adds nothing. It is sound on the current surface,
needs no syntax, and over-approximates in the same way v1 already does for
lambdas and for calls on untaken paths.

Keep one addition: a one-bit `pure` requirement, written on a callable type
(`f: pure (Int) -> Int`) and on a trait method declaration, so that a callee can
refuse an impure argument. Its consumers are comparators and equality, explicit
parallel library variants, and generic rewrite laws over callable binders. Its
next artifact is a proposed RFC, "the callable-purity RFC" below, tracked as
#1719 and opened after #1711 merges. Its number is assigned when it opens (see
[Follow-up](#follow-up)).

Defer effect variables and associated effects. While `pure < io` is the whole
lattice they buy two things: precision where a function is passed and never
called, and purity-preserving adapters that the current surface cannot write.
They become necessary when Kofun accepts a second effect label or a construct
that discharges an effect of a callable argument.

Reject purity reflection (`purityOf`, `@ParallelWhenPure`). Flix resolves it
while specializing an effect variable. Kofun has neither the variable nor a
specialization that may change behavior, and the explicit alternative, a
separately named parallel function whose parameter is `pure`, refuses at
compile time instead of silently running sequentially.

Flix is the reference because it ships all four mechanisms in one language,
with complete Hindley–Milner inference ([`DIDYOUKNOW.md`][dyk-hm]) over effect
set formulas ([`effect-polymorphism.md`][poly-formulas]). At the pinned commit
those formulas are unified in a Zhegalkin algebra
([`EffUnification3.scala`][eff-zhegalkin]); the BDD representation that 0.35.0
introduced ([`CHANGELOG.md`][changelog-bdd]) is history. This note keeps Flix's
pure-argument requirement for the proposed RFC to specify, and none of the
rest. Flix enforces that equality and ordering functions are pure
([`DIDYOUKNOW.md`][dyk-eq]), and `Eq.eq`, `Order.compare`, and
`List.sortWith`'s comparator carry no effect variable ([`Eq.flix`][eq],
[`Order.flix`][order], [`List.flix`][list-sort]).

## What creation-site charging means

Three consequences of #1711's rule settle most of the questions below.

1. **A function's summary is local.** `pure fn forward(f: (Int) -> Int, x: Int)
   -> Int { return f(x) }` is accepted and published `pure` today (x16), and
   #1711 keeps `apply` `pure` by design. `pure fn` on a higher-order function
   therefore says "adds no effect of its own". Flix writes the same signature
   with one effect variable, `f: a -> b \ ef` and result effect `ef`
   ([`effect-polymorphism.md`][poly-map]).
2. **A call expression's effect is not its callee's summary.** It is the
   callee's summary joined with the summary of every function named, and every
   lambda written, in its arguments. `forward(noisy, 7)` has a `pure` callee and
   prints `7` (x16). A consumer that reads only the callee's fact is unsound for
   higher-order calls. #1714's discarded-pure-call rule is the first such
   consumer; this point is recorded on #1714
   ([comment](https://github.com/kofun-lang/kofun/issues/1714#issuecomment-5977026701)).
3. **When a requirement is needed.** A consumer needs a purity requirement on a
   callable parameter exactly when it must decide purity *inside the callee*,
   where the argument is a parameter rather than a creation site. Any call site
   that names its arguments can already answer with the joined effect in (2).

## Research questions and answers

### 1. Sufficiency — keep creation-site charging as the v1 rule

The rule is sound on the current surface. #1711 asks its implementation to
enumerate every way to create a function value, and the current compiler
refuses each form other than the two it charges:

- a local `let` of a function name: x04, `E2S35`;
- a module-level binding of a function name: x24, `E2S159`;
- returning a function name: x10, `E2S35`;
- a callable result type: x11, `E2S15`;
- a callable record field: x12, `E2S32`.

What remains is naming a function as an argument, which #1711 charges, and a
lambda, whose calls are already charged to the enclosing function. A lambda
bound with `let` and passed to `apply` is refused inside a `pure fn` (x03,
`E2S176`). The same function without `pure` checks `ok` and prints `7` (x25).
A lambda written directly as an argument is not expressible: it is refused with
`E2S12` even without `pure` (x27).

Both alternatives are worse for v1. Charging an unknown call through a
parameter as `io` makes every higher-order function `io`, so `pure fn quiet`
calling `apply(inc, x)` would be refused although nothing prints. Flix-style
effect variables are precise, but they need effect-carrying callable types and
inference machinery (question 3).

The rule over-approximates in the cases below. Each program cannot print
through the charged path. Every `pure fn` below is a valid program without the
annotation: the "Without `pure`" column checks the same body unannotated.

| Case | Example | Today, in a `pure fn` | Without `pure` | After #1711 (predicted) |
|---|---|---|---|---|
| a named function passed and never called | x05, `ignore(noisy, x)` | `ok`; `run` prints nothing | — | `E2S176` naming `noisy` |
| a named function called only on an untaken path | x09, `choose(0, noisy, inc, x)` | `ok`; `run` prints nothing | — | `E2S176` naming `noisy` |
| a `let`-bound lambda passed and never called | x06, `ignore(g, x)` | `E2S176` | x26: `ok`; `run` prints nothing | unchanged |
| a `let`-bound lambda never passed or called | x07 | `E2S176` | x28: `ok` | unchanged |
| a direct call on an untaken path, not callable-specific | x08, `if false { return noisy(x) }` | `E2S176` | x29: `ok`; `run` prints nothing | unchanged |
| a function value stored or returned and never called | x10–x12, x24 | not expressible | — | #1711 adds the edge or keeps the form refused |

Rows three to five already happen today: the lambda rule and the
flow-insensitive direct-call rule over-approximate the same way. #1711 extends
an existing precision class to names instead of creating a new one.

The second row has an in-tree instance. `stub_unreachable` in the test
library prints when called and exists to be passed as an `Int -> Int`
collaborator that must not be called
([`stdlib/testing/kotest.kofun:342-351`](../../stdlib/testing/kotest.kofun#L342-L351)).
`examples/stdlib/testing_sample_test.kofun:30` passes it to `line_subtotal`
with a quantity of `0`. `line_subtotal` calls its price book only for a
positive quantity
([`examples/stdlib/testing_sample.kofun:39-44`](../../examples/stdlib/testing_sample.kofun#L39-L44)),
so the stub is never called. Under #1711 the test function that names the stub
is charged `io` for it (predicted). Nothing observable changes there: the same
function already calls `expect_eq_int`, which prints, and it is not `pure fn`.
A `pure fn` written the same way would be refused.

`bin/kofun run` on x28 fails in the C compiler: the unused lifted lambda trips
`-Werror=unused-function` (`program.c:218:16: error: 'kofun_lambda_12'
defined but not used`). That is a separate lowering defect in the class of
#1358, and is not an effect question.

Flix's effect variables would remove the never-called rows, because creating a
lambda or passing a function has no effect there: `List.map` with a pure
lambda is pure ([`effect-polymorphism.md`][poly-map]). They would not remove the
untaken-path rows. A callee that mentions an argument's effect variable in its
own effect is charged it whether the call runs or not, as the union in `>>`'s
`ef1 + ef2` shows ([`effect-polymorphism.md`][poly-compose]).

Next artifact: #1711 itself. For #1714, the joined call-expression effect
(consequence 2) is already recorded there.

### 2. Parameter purity — keep, as a one-bit requirement (proposed RFC, #1719)

A callable type should be able to carry `pure`. Without it, none of the
question 4 consumers that decide purity inside a callee can be written. With it,
the creation-site rule still does all the inference.

**Subsumption.** A `pure` callable is accepted where an unannotated one is
expected: `pure (A) -> R` ≤ `(A) -> R`. The relation is covariant in a
callable's own effect and contravariant through a callable-typed parameter. The
bit should join ownership modes in callable type identity
([`TYPE_SYSTEM.md` § Callable types](../TYPE_SYSTEM.md#callable-types)), with
this one subsumption rule relating the two identities. An argument meets a
`pure` requirement when it is:

- a named function whose summary is `pure`. This is the inferred summary, so
  `inc` needs no annotation;
- a lambda whose body's summary is `pure`;
- a callable parameter that itself carries `pure`. An unannotated callable
  parameter forwarded to a `pure` one is refused, because its effect is unknown
  and v1 never classifies the unknown optimistically
  ([`pure-io-v1.md`](../../spec/effects/pure-io-v1.md)).

An unannotated callable type must mean *no requirement*, not *`io`*. The two
read the same today. Only the first lets a later effect-variable design
reinterpret it as an inferred variable, which accepts more programs (x05 after
#1711) rather than breaking any.

The requirement also separates two meanings of `pure fn`.
`pure fn forward(f: pure (Int) -> Int, x: Int) -> Int` is pure outright, while
`pure fn forward(f: (Int) -> Int, x: Int) -> Int` stays "pure apart from `f`"
(consequence 1). The callable-purity RFC must not reinterpret the second.

**Spelling.** #1241 froze `pure`, before `fn`, as the only effect word
([`pure-io-v1.md` § The `pure fn` boundary](../../spec/effects/pure-io-v1.md#the-pure-fn-boundary)).
[`TYPE_SYSTEM.md` § Effects](../TYPE_SYSTEM.md#effects) still says the keyword
"will be decided after evaluating effect inference and diagnostic UX". That
sentence predates #1241, and the callable-purity RFC should replace it.

| Spelling | Current surface | Decision |
|---|---|---|
| `f: pure (Int) -> Int` | refused, `E2S35` malformed parameter head (x13); this exact form is unused, but `pure` is not reserved in types (x30) | keep: it reuses the frozen word as a prefix, as `pure fn` does |
| `f: (Int) -> Int ! io` or `! {}` | refused, `E2S35` (x14); free | defer: the conceptual effect-row form of `TYPE_SYSTEM.md` § Effects. With one bit it would spell `pure` as `! {}`. The callable-purity RFC must leave the suffix position free for rows |
| `pure f: (Int) -> Int` | taken: `pure` there is an external label (x15, `E2S164`; also [`annotated_parameter.stderr`](../../tests/conformance/effects/pure-boundary/annotated_parameter.stderr)) | reject |
| `io` in any position | `io fn` is the unknown visibility modifier `E2S33` ([`io_annotation.stderr`](../../tests/conformance/effects/pure-boundary/io_annotation.stderr)) | reject: `pure-io-v1.md` names one spelling |

`pure` belongs to the callable-type former, not a prefix type operator,
because `->` is the lowest-precedence type operator. `pure Int -> Int` is a pure
unary callable, `Int -> pure Int -> Int` is `Int -> (pure (Int -> Int))`, and an
optional pure callable is `(pure (Int) -> Int)?`.

`pure` is not free in type position. `type pure = { a: Int, }` checks `ok`
(x30), and `pure-io-v1.md` says `pure` outside the position before `fn`
"remains an ordinary identifier". x13's refusal lands on the `(` after `pure`,
so the parser read `pure` as a type name. A callable parameter over that type,
`f: pure -> Int`, is refused today (x31, `E2S35` at the `->`), so no accepted
program spells the ambiguous form yet. The callable-purity RFC must still make
`pure` contextual in type position, and say what an existing type named `pure`
means there.

**KIF.** No callable effect can cross a package boundary today, for three
independent reasons:

- KIF v2 does not serialize callable signatures. `--emit-kif` on a public
  function with a callable parameter fails with `EKI02: KIF v2 supports only
  complete Int or flat nominal function signatures`, exit 3 (x19). The same
  shape with an `Int` parameter emits (x22).
- KIF v2 refuses effect components outright.
  `bootstrap/stage2/semantic_producer.c` lines 515–520 refuse `async`,
  `effect`, and `throws` in a published signature with `EKI02` and the message
  "KIF v2 does not support effect components in published signatures". The
  codec has no effect field: `grep -c -i effect` prints `0` for
  `bootstrap/stage2/kif_v1.c`, `bootstrap/stage2/kif_v1.h`, and
  `bootstrap/stage2/stage2_kif_producer.c`.
- A public function cannot be `pure`: `pub pure fn` is `E2S33` (x20), and
  `pure pub fn` is `E2S02` (x21).

RFC-0017's KIF v3 already reserves the slot. Its `function` TypeRef carries
"modes, effect summary", and its `GenericFunctionDeclaration` and `TraitMethod`
records carry effects ([RFC-0017 §4](../../rfcs/0017-generics-kif-proof-profile.md)).
Its codec model encodes each as an uninterpreted `u16`. It writes `0` when the
field is absent (`spec/kif-generics-v1/model.mjs:255`) and reads the value back
without validation (`model.mjs:1057`). Its mutation suite only requires that
changing the field to `7` moves the digest (`spec/kif-generics-v1/check.mjs:188`).
The callable-purity RFC must:

1. assign two values, *no requirement* and *`pure`*, and refuse every other
   value on read;
2. remove the absent-field default. The bit is covariant in a declaration's
   own effect and contravariant in a parameter's requirement, so neither value
   is conservative in both positions. A dropped parameter requirement would let
   a consumer pass `io` to a callee that relies on purity;
3. publish a declaration's *declared* purity (`pure fn`) across a package
   boundary, not its inferred summary. An inferred summary in an interface turns
   a body edit — one added `print` — into an interface break that consumers
   find as a digest change. Flix makes the same choice: a top-level function's
   effect is part of its written signature, an omitted one is the empty set
   ([`effect-polymorphism.md`][poly-default]), and it is never widened
   ([`effect-polymorphism.md`][poly-toplevel]). Within one package the inferred
   summary stays the input;
4. choose the order of `pub` and `pure` (x20, x21), and make `pure`
   contextual in type position (x30);
5. version the typed sidecar to display callable parameter types. It shows
   them as `Fn` today, so `apply`'s published type is `(Fn, Int) -> Int` (x02)
   and a requirement would be invisible to tooling. `pure-io-v1.md` already
   states that publishing the `pure fn` assertion is a typed-sidecar version
   bump; displaying a requirement is the same kind of change.

Next artifact: the callable-purity RFC, tracked as #1719.

### 3. Effect variables — defer

With `pure < io` every effect formula collapses to one bit, and `ef1 + ef2` is
OR. Compared with a `pure` marker plus creation-site charging, Flix-style
variables add:

- precision for a callee that never calls its argument (the never-called rows
  of question 1);
- purity-preserving adapters. `>>` returns a callable whose effect is
  `ef1 + ef2` ([`effect-polymorphism.md`][poly-compose]). With only the
  marker, a `compose` whose result must reach a `pure` parameter needs a
  second, `pure`-only version. Kofun cannot return a callable at all today
  (x11, `E2S15`), or store one in a record (x12, `E2S32`);
- nothing for forwarding: an argument passed on to a `pure` parameter must be
  pure under either design.

That does not pay for generalization and instantiation at every call, a new
binder kind in KIF v3's `TypeBinder`, and Boolean unification. Flix has
changed that machinery's representation at least once. 0.35.0 introduced BDDs
([`CHANGELOG.md`][changelog-bdd]), and the pinned commit unifies effects in a
Zhegalkin algebra ([`EffUnification3.scala`][eff-zhegalkin]). Its authors also
published the unification algorithms separately
([`research-literature.md`][lit]).

Variables start to pay at the first construct that **removes** an effect from
a callable argument. Flix's `handleAmb(f: a -> b \ ef): a -> List[b] \ ef - Amb`
handles `Amb` raised inside `f` ([`effects-and-handlers.md`][handlers-amb]).
Under creation-site charging, the lambda's creator keeps `Amb` although the
handler discharges it, so `pure fn` would refuse correct programs. The rule
would then be wrong, not merely imprecise. Effect exclusion, `ef - Block`
([`effect-polymorphism.md`][poly-exclusion]), is the same case. Both need a
second effect label first, and `spec/effects/affine-resumption.md` is an
accepted contract with no handler implementation.

That contract also limits what a variable would track. A resumption cannot be
captured by a closure, or transferred through an unknown, generic, or
dynamically selected parameter (`EAF002`), so a callable value never carries
one. An effect variable on a callable argument would range over effect labels
only, never over resumption linearity.

Trigger to revisit: the first accepted proposal that adds an effect label
beyond `io`, or a handler. The callable-purity RFC carries three
forward-compatibility obligations: the *no requirement* reading of question 2,
its distinct KIF value, and the free suffix position.

### 4. Consumers — a requirement for three of them, not for the others

The table applies consequence 3 to each consumer.

| Consumer | Where purity is decided | Requirement on a callable argument? | What breaks without one |
|---|---|---|---|
| law operations, equations, custom equality: the finite checks of [`LAW_SYSTEM.md`](../LAW_SYSTEM.md) | in the evaluator, which builds every argument: `all_functions` tables, or functions named in the `check laws` declaration | no | nothing, provided a `check laws` declaration owns an effect summary that the functions named in it are charged to (a requirement on the law implementation, not on callable types) |
| generic `proven` rewrites over a callable binder ([RFC-0017 §5](../../rfcs/0017-generics-kif-proof-profile.md)) | at any call site, including a higher-order body where the argument is a parameter | **yes**, on the binder | a fusion law such as `map(map(xs, f), g) == map(xs, fn(x) => g(f(x)))` reorders the calls of an `io` argument. RFC-0017 v1 refuses effects in propositions but cannot say that a callable binder ranges over pure functions. Not expressible today: Stage 2 Core has no `map` (x23, `E2S16`) |
| standard-library comparators, equality, hash | inside the library | **yes** | the library cannot refuse an `io` comparator, so the number and order of comparisons become observable and the sort algorithm becomes contract. None exists yet. The 21 callable parameters in `stdlib/` are `transform`, `predicate`, and `combine` callbacks, a test predicate, and an injected clock, and set and map document their traversal order (`stdlib/set/set.kofun:3`, `:152`; `stdlib/map/map.kofun:181`), so those need no requirement. Flix splits the same way: `List.map` and `Set.exists` take `\ ef` ([`List.flix`][list-map], [`Set.flix`][set-exists]); `sortWith` does not ([`List.flix`][list-sort]) |
| explicit parallel library variants, such as a `par_count` beside `count` | inside the library | **yes** | an `io` callback run in parallel interleaves its output, a race condition the caller did not choose |
| RFC-0003 `par` task bodies | nowhere: a task body may be `io` | no | nothing. RFC-0003 promises data-race freedom through ownership, not race-condition freedom, and does not "classify concurrency itself as `io`" ([RFC-0003 § Ownership and effects](../../rfcs/0003-scoped-parallelism.md#ownership-and-effects)). Flix separates the same two: `par-yield` accepts only pure expressions, and effectful parallelism uses threads ([`parallelism.md`][par]). `par` is not implemented (x17, `E2S154`) |
| compile-time evaluation: `meta` and `const` ([`METAPROGRAMMING.md`](../METAPROGRAMMING.md)) | at the `meta` call site, which names every argument | no | nothing, if the evaluator asks for the joined effect of consequence 2 rather than the callee's summary |
| transparent parallel selection | inside the library | see question 5 | — |

Flix's book gives the comparator reason for `Set.exists` — a pure predicate
hides the set's iteration order — and in the same passage calls requiring
purity "unless necessary" bad style ([`effect-polymorphism.md`][poly-exists]).
Its library at the pinned commit made `Set.exists` effect-polymorphic anyway
([`Set.flix`][set-exists]). The requirement belongs where impurity would expose
an algorithm, not on every callback.

Next artifact: the callable-purity RFC (#1719) for the three "yes" rows.
Proposed note: the law implementation
([`LAW_SYSTEM.md` § Implementation sequence](../LAW_SYSTEM.md#implementation-sequence),
step 2) charges `check laws` declarations. The joined effect for #1714 is
already recorded there
([comment](https://github.com/kofun-lang/kofun/issues/1714#issuecomment-5977026701)).

### 5. Purity reflection — reject

Flix's `Set.count` matches on `purityOf(f)` and counts in parallel when `f` is
pure and the tree is large enough ([`purity-reflection.md`][reflect];
[`Set.flix`][set-count]; threshold in [`Set.flix`][set-threshold]). Whether a
call runs in parallel therefore depends on the purity of an argument that may
be defined far away, fixed at compile time, and on the set's size, checked at
run time. `purityOf` is library code over `Reflect.reflectEff`
and an `unchecked_cast` ([`Prelude.flix`][prelude-purity]). The compiler
resolves `reflectEff` while specializing: it becomes the constant `Pure` only
when the substituted effect is exactly `Pure`, and `Impure` otherwise
([`Specialization.scala`][spec-reflect]). Free effect variables are defaulted
to `Pure` ([`Specialization.scala`][spec-default]). The library carries 27
`@ParallelWhenPure` annotations at the pinned commit, in `Set`, `Map`,
`MultiMap`, `DelayMap`, and `RedBlackTree` (command in
[Checked examples](#checked-examples)).

Kofun should not adopt it, for three reasons.

1. **It presupposes what Kofun lacks.** A Kofun `count(f: (Int) -> Bool, ...)`
   is not generic in an effect. It is compiled once, and there is nothing to
   specialize. Reflection would need a purity tag in every callable value, a new
   runtime ABI field. Specialization at instantiation is no better. For
   trait-bounded generics, monomorphization is optional, "must preserve the
   observable result of the dictionary form", and "must be removable without
   changing whether a program type-checks"
   ([`generics-and-traits.md`](../../spec/roadmap-31-34/generics-and-traits.md);
   DD-032). The unspecialized dictionary form would need the same runtime tag.
2. **It acts at a distance.** One `print` added to a predicate in another module
   silently turns a parallel call sequential. Flix surfaces this through an
   editor code hint ([`DIDYOUKNOW.md`][dyk-hints]). A separately named parallel
   function whose parameter is `pure` refuses the same edit in every build, with
   the diagnostic of question 7.
3. **It has no target.** `par` is not implemented (x17), and RFC-0003 v1
   refuses loop spawning and recursive scope creation. Flix's recursive
   `RedBlackTree.parCount` ([`RedBlackTree.flix`][rbt-par]) cannot be written
   even once `par` exists.

An optimizer that parallelizes a call whose argument is statically pure at that
call site needs no source construct. DD-032's rule that a specialization cannot
change the observable result bounds it, and it is out of scope here.

Next artifact: none. The explicit parallel variant is covered by the
callable-purity RFC (#1719).

### 6. Associated effects — defer

Flix lets each trait instance choose an effect. `Dividable.div` is pure for
`Float32` and raises `DivByZero` for `Int32`, and `ForEach.forEach` adds a
region effect for mutable collections ([`associated-effects.md`][assoc]). Flix
added them in 0.47.0 together with associated effects on `Iterable` and
`Foldable` ([`CHANGELOG.md`][changelog-assoc]). Fourteen of the 50 trait
declarations in its library declare one, for example `Foldable`, `Iterable`,
`Readable`, and `Writable` (commands in [Checked examples](#checked-examples)).

For DD-032 traits they buy nothing yet:

- the active compiler does not accept traits (x18, `E2S02`). The traits
  frontend is bounded to one-method traits, and associated types are planned
  but unimplemented ([`TYPE_SYSTEM.md` § Traits](../TYPE_SYSTEM.md#traits));
- Flix's motivating effects, exceptions and heap regions, have no Kofun
  counterpart. Kofun uses `Result` and ownership modes instead;
- in a one-bit lattice the creation-site rule already gives per-implementation
  precision. The site that selects an `ImplementationId` is where that
  implementation's method values are created. RFC-0017 already makes effects
  "substituted facts" and requires that "a dictionary method's effect must fit
  the bound signature" (§3). Charging the selected implementation's method
  summaries at the selection site makes a generic `fold` over a pure instance
  pure where it is used. That rule belongs in RFC-0017's production work
  (#1268–#1280).

What is needed now is the fixed form: a trait method declared `pure`, as
Flix's `Eq.eq` and `Order.compare` are ([`Eq.flix`][eq],
[`Order.flix`][order]), so a law or a comparator can require purity of every
implementation. It uses the bit and KIF field of question 2 (RFC-0017's
`TraitMethod` effects) and is part of the callable-purity RFC. Writing it as
`pure fn` inside a `trait` body is not checkable today (x18).

Trigger to revisit: associated types in the traits frontend, and an effect
vocabulary beyond `pure < io`.

### 7. Diagnostics — keep E2S176 unchanged; add argument refusals in the RFC

E2S176 has two shapes today. Its byte offset is the annotated declaration's
`fn` keyword, not the offending call:

```text
error[E2S176]: `pure fn calc` reaches `print` directly at byte 5
error[E2S176]: `pure fn quiet` reaches `print` through `noisy` at byte 362
```

The first line is
[`direct.stderr`](../../tests/conformance/effects/pure-boundary/direct.stderr).
The second is x03, where byte 362 starts `fn quiet(x: Int)`. The root is always
`print`, the only root. The named hop is the first call in the body that
carries it; `order_a.stderr` and `order_b.stderr` both name `first`.

After #1711 (predicted), x02 is refused with the second shape naming `noisy`;
that is #1711's acceptance criterion. "through" then covers a reference that is
not a call, and the span still points at `fn`. This is acceptable for #1711,
which reuses the reason `effect-io-callee` to keep the closed reason vocabulary.
The callable-purity RFC should add the reference's span as a related span.

The callable-purity RFC needs three refusals that E2S176 cannot express:

| Refusal | Primary span | Related span | Example message |
|---|---|---|---|
| impure argument | the argument | the parameter's `pure` | ``argument `noisy` to `pure` parameter `f` of `apply_pure` reaches `print` directly`` |
| unproven argument | the argument | the forwarded parameter's declaration | ``argument `g` to `pure` parameter `f` of `apply_pure` is parameter `g` of `outer`, which has no `pure` requirement`` |
| impure trait implementation | the implementing method | the trait method's `pure` | ``method `same` of `impl Same[Int]` reaches `print` through `log`; trait `Same` declares it `pure` `` |

Rules for those refusals:

- A lambda argument is named "lambda argument". The root and the hop follow
  E2S176's rule, so the two codes never name different hops for one edge.
- The unproven case names no root, because none is known. Its fix is a
  signature in another function, so it needs its own code or reason, not
  "reaches `print`".
- They are new Stage 2 codes, not E2S176. E2S176 means "this declaration's own
  summary is `io`" and is fixed in the body. These are fixed at an argument or
  a signature. They stay out of the `E3xx` band for the reason
  `pure-io-v1.md` gives.
- One fault gets one diagnostic. When a `pure fn` passes `noisy` to a `pure`
  parameter, report the argument refusal and not E2S176 as well: it names the
  exact site, and fixing it clears both. The first offending argument in source
  order is reported.
- The published fact for a value-reference edge reuses `effect-io-callee`, as
  #1711 does.

Next artifact: the callable-purity RFC, tracked as #1719.

## Checked examples

Each example is the header below followed by one section of the second block.
Split the second block at the `# ---` lines and leave those lines out. The
header ends with one empty line, and its SHA-256 is
`3452c51f3a92b66c5f2c196721b6aa8a640c062d74561e8a07f665f2633b575f`, so the byte
offsets reproduce exactly.

```kofun
fn noisy(x: Int) -> Int {
    print(x)
    return x
}

fn inc(x: Int) -> Int {
    return x + 1
}

fn apply(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

fn ignore(f: (Int) -> Int, x: Int) -> Int {
    return x
}

fn choose(flag: Int, f: (Int) -> Int, g: (Int) -> Int, x: Int) -> Int {
    if flag == 1 {
        return f(x)
    }
    return g(x)
}
```

```kofun
# --- x01
fn main() -> Int {
    return apply(inc, 41)
}
# --- x02
pure fn quiet(x: Int) -> Int {
    return apply(noisy, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x03
pure fn quiet(x: Int) -> Int {
    let g = fn(y: Int) => noisy(y)
    return apply(g, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x04
pure fn quiet(x: Int) -> Int {
    let g = noisy
    return g(x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x05
pure fn quiet(x: Int) -> Int {
    return ignore(noisy, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x06
pure fn quiet(x: Int) -> Int {
    let g = fn(y: Int) => noisy(y)
    return ignore(g, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x07
pure fn quiet(x: Int) -> Int {
    let later = fn(y: Int) => noisy(y)
    return x
}

fn main() -> Int {
    return quiet(7)
}
# --- x08
pure fn quiet(x: Int) -> Int {
    if false {
        return noisy(x)
    }
    return x
}

fn main() -> Int {
    return quiet(7)
}
# --- x09
pure fn quiet(x: Int) -> Int {
    return choose(0, noisy, inc, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x10
fn pick() -> (Int) -> Int {
    return noisy
}

fn main() -> Int {
    return 0
}
# --- x11
fn compose(f: (Int) -> Int, g: (Int) -> Int) -> (Int) -> Int {
    return fn(x: Int) => g(f(x))
}

fn main() -> Int {
    return 0
}
# --- x12
type Handler = {
    run: (Int) -> Int,
}

fn main() -> Int {
    return 0
}
# --- x13
fn apply_pure(f: pure (Int) -> Int, x: Int) -> Int {
    return f(x)
}

fn main() -> Int {
    return apply_pure(inc, 41)
}
# --- x14
fn apply_io(f: (Int) -> Int ! io, x: Int) -> Int {
    return f(x)
}

fn main() -> Int {
    return apply_io(inc, 41)
}
# --- x15
fn apply_labelled(x: Int, pure f: (Int) -> Int) -> Int {
    return f(x)
}

fn main() -> Int {
    return apply_labelled(41, inc)
}
# --- x16
pure fn forward(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

fn main() -> Int {
    return forward(noisy, 7)
}
# --- x17
fn main() -> Int {
    return par |scope| {
        let left = scope.spawn(fn() => inc(1))
        left.join()
    }
}
# --- x18
trait Same[T] {
    pure fn same(read left: T, read right: T) -> Int
}

fn main() -> Int {
    return 0
}
# --- x19
pub fn apply_public(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

fn main() -> Int {
    return apply_public(inc, 41)
}
# --- x20
pub pure fn inc_public(x: Int) -> Int {
    return x + 1
}

fn main() -> Int {
    return inc_public(41)
}
# --- x21
pure pub fn inc_public(x: Int) -> Int {
    return x + 1
}

fn main() -> Int {
    return inc_public(41)
}
# --- x22
pub fn inc_public(x: Int) -> Int {
    return x + 1
}

fn main() -> Int {
    return inc_public(41)
}
# --- x23
pure fn quiet(x: Int) -> Int {
    let values = map([x], noisy)
    return x
}

fn main() -> Int {
    return quiet(7)
}
# --- x24
let handler = noisy

fn main() -> Int {
    return 0
}
# --- x25
fn quiet(x: Int) -> Int {
    let g = fn(y: Int) => noisy(y)
    return apply(g, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x26
fn quiet(x: Int) -> Int {
    let g = fn(y: Int) => noisy(y)
    return ignore(g, x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x27
fn quiet(x: Int) -> Int {
    return apply(fn(y: Int) => noisy(y), x)
}

fn main() -> Int {
    return quiet(7)
}
# --- x28
fn quiet(x: Int) -> Int {
    let later = fn(y: Int) => noisy(y)
    return x
}

fn main() -> Int {
    return quiet(7)
}
# --- x29
fn quiet(x: Int) -> Int {
    if false {
        return noisy(x)
    }
    return x
}

fn main() -> Int {
    return quiet(7)
}
# --- x30
type pure = {
    a: Int,
}

fn main() -> Int {
    return 0
}
# --- x31
type pure = {
    a: Int,
}

fn take(f: pure -> Int) -> Int {
    return 0
}

fn main() -> Int {
    return 0
}
```

x25, x26, x28, and x29 are x03, x06, x07, and x08 without `pure`, which shows
that each refused program is otherwise valid.

Every example was checked with `bin/kofun check FILE`. x02, x05, x09, x16, x25,
x26, x28, and x29 were also run with `bin/kofun run FILE`. x19 and x22 were also
checked with `bin/kofun check FILE --emit-kif OUT.kif`, and x02 and x16 with
`bin/kofun check FILE --emit-typed-sidecar OUT.json --generation 1`.

| ID | What it shows | `bin/kofun check` | Other commands |
|---|---|---|---|
| x01 | a callable parameter | `ok`, exit 0 | |
| x02 | #1711's program | `ok`, exit 0 | `run` prints `7`, exit 7. Sidecar: `noisy` `io` (`effect-io-root-print`); `apply`, `ignore`, `choose`, `quiet`, `main` `pure`; `apply`'s type is `(Fn, Int) -> Int` |
| x03 | a `let`-bound lambda that calls `noisy`, passed to `apply` | ``error[E2S176]: `pure fn quiet` reaches `print` through `noisy` at byte 362``, exit 1 (byte 362 starts `fn quiet`) | |
| x04 | a local `let` of a function name | ``error[E2S35]: unknown lexical binding `noisy` at byte 400``, exit 1 | |
| x05 | a named function never called | `ok`, exit 0 | `run` prints nothing, exit 7 |
| x06 | a `let`-bound lambda passed to `ignore`, never called | same `E2S176` as x03, byte 362, exit 1 | |
| x07 | a local lambda never called | same `E2S176` as x03, byte 362, exit 1 | |
| x08 | a direct call on an untaken path | same `E2S176` as x03, byte 362, exit 1 | |
| x09 | a named function on an untaken path | `ok`, exit 0 | `run` prints nothing, exit 8 |
| x10 | returning a function name | ``error[E2S35]: unknown lexical binding `noisy` at byte 396``, exit 1 | |
| x11 | returning a lambda | ``error[E2S15]: Core function `compose` returns Int, expected ( at byte 431``, exit 1 | |
| x12 | a callable record field | `error[E2S32]: malformed nominal record declaration at byte 357`, exit 1 | |
| x13 | `pure` on a callable type | `error[E2S35]: malformed parameter head at byte 379`, exit 1 | |
| x14 | an effect suffix on a callable type | `error[E2S35]: malformed parameter head at byte 385`, exit 1 | |
| x15 | `pure` before a parameter name is a label | `error[E2S164]: labelled parameter requires its external label at byte 482`, exit 1 | |
| x16 | `pure fn` on a higher-order function | `ok`, exit 0 | `run` prints `7`, exit 7. Sidecar: `forward` and `main` `pure`; `noisy` `io` |
| x17 | `par` | ``error[E2S154]: scoped parallelism `par` is specified but not implemented at byte 387``, exit 1 | |
| x18 | a `pure` trait method | ``error[E2S02]: expected top-level `fn`, `type`, or `let` at byte 357``, exit 1 | |
| x19 | KIF for a callable signature | `ok`, exit 0 | `--emit-kif`: `EKI02: KIF v2 supports only complete Int or flat nominal function signatures`, exit 3 |
| x20 | `pub pure fn` | ``error[E2S33]: visibility modifier `pub` must be followed by a top-level `fn` or `type` declaration at bytes 357..360``, exit 1 | |
| x21 | `pure pub fn` | ``error[E2S02]: expected top-level `fn`, `type`, or `let` at byte 357``, exit 1 | |
| x22 | KIF for an `Int` signature | `ok`, exit 0 | `--emit-kif`: `ok: ... (authoritative KIF v2)`, exit 0 |
| x23 | the built-in `map` in Stage 2 Core | ``error[E2S16]: unknown Core function `map` at byte 405``, exit 1 | |
| x24 | a module-level binding of a function name | ``error[E2S159]: module constant must be `let NAME = <integer literal>` at byte 357``, exit 1 | |
| x25 | x03 without `pure` | `ok`, exit 0 | `run` prints `7`, exit 7 |
| x26 | x06 without `pure` | `ok`, exit 0 | `run` prints nothing, exit 7 |
| x27 | a lambda written directly as an argument, without `pure` | `error[E2S12]: invalid return expression at byte 394`, exit 1 | |
| x28 | x07 without `pure` | `ok`, exit 0 | `run` exits 1: the C compiler reports `program.c:218:16: error: 'kofun_lambda_12' defined but not used [-Werror=unused-function]` |
| x29 | x08 without `pure` | `ok`, exit 0 | `run` prints nothing, exit 7 |
| x30 | a type named `pure` | `ok`, exit 0 | |
| x31 | a callable parameter over the type named `pure` | `error[E2S35]: malformed parameter head at byte 402`, exit 1 (byte 402 is the `->`) | |

The current surface cannot express an effect on a callable type (x13, x14), a
trait method (x18), `par` (x17), a callable result, record field, or module
binding (x10–x12, x24), a lambda written directly as an argument (x27), a
callable over a nominal record type (x31), a public `pure fn` (x20, x21), KIF
for a callable signature (x19), or a generic `map` for a fusion law (x23).
Those examples record the refusal that shows it.

The other counts quoted above were measured with these commands. The Kofun
rows ran in this repository at `638842470f622bbabb50c34a8bd9540e61dcbf33`; the
Flix rows ran in a checkout of `flix/flix` at
`35533f982dd75ee806dde039e60702c71a432c2d`.

```sh
git grep -n -E '[a-z_]+: *((fn)?\([^)]*\)|[A-Z][A-Za-z0-9_]*(\[[^]]*\])?) *-> *[A-Z(]' -- 'stdlib/*.kofun'
# observed: 21 lines. 19 are `transform`, `transform_first`, `transform_second`,
# `predicate`, or `combine` in array, list, map, set, tuple, and vector; the
# other two are `predicate: Int -> Int` at stdlib/testing/kotest.kofun:126 and
# `clock: Int -> Int` at stdlib/testing/tests/kotest_selfcheck_test.kofun:129
```

| Claim | Command | Result |
|---|---|---|
| KIF v2 effect field | `grep -c -i effect bootstrap/stage2/kif_v1.c bootstrap/stage2/kif_v1.h bootstrap/stage2/stage2_kif_producer.c` | `0` for each file |
| last allocated RFC | `node -e 'const d=require("./rfcs/index.json"); console.log(d.rfcs.map(r=>r.id).filter(i=>/^RFC-/.test(i)).sort().at(-1))'` | `RFC-0018` |
| Flix `@ParallelWhenPure` sites | `grep -rn '@ParallelWhenPure' main/src/library \| wc -l` | `27` |
| Flix traits with an associated effect | `grep -rn -E 'type Aef[^=]*: *Eff' main/src/library \| wc -l` | `14` |
| Flix trait declarations | `grep -rn -E '^\s*(pub )?trait ' main/src/library \| wc -l` | `50` |

## Follow-up

1. **The callable-purity RFC, tracked as #1719.** It is filed `blocked` on
   #1711, because its argument rule extends #1711's edge.
   - **Scope:**
     - the `pure` callable type (question 2), including `pure` becoming
       contextual in type position;
     - `pure` trait methods (question 6);
     - the three refusals (question 7);
     - the KIF value assignment and the declared-purity rule;
     - the order of `pub` and `pure`;
     - the typed-sidecar version that displays callable types.
   - **Number:** assigned when the RFC opens. `RFC-0018` is currently the last
     entry in `rfcs/index.json`.
2. Proposed notes on existing work, not new issues:
   - #1714: a discarded call's effect is the joined call-expression effect, not
     the callee's fact (consequence 2). This is already recorded there
     ([comment](https://github.com/kofun-lang/kofun/issues/1714#issuecomment-5977026701));
   - the law implementation: a `check laws` declaration owns an effect summary,
     so the functions named in its domains and equality are charged to it;
   - RFC-0017 production (#1268–#1280): charge a selected implementation's
     method summaries at the dictionary-selection site, and do not carry the v3
     model's absent-field default into the effect fields.

[dyk-hm]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/docs/DIDYOUKNOW.md?plain=1#L68-L76
[dyk-eq]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/docs/DIDYOUKNOW.md?plain=1#L122-L126
[dyk-hints]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/docs/DIDYOUKNOW.md?plain=1#L167-L168
[changelog-bdd]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/docs/CHANGELOG.md?plain=1#L316-L333
[changelog-assoc]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/docs/CHANGELOG.md?plain=1#L204-L207
[eff-zhegalkin]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/unification/EffUnification3.scala#L24-L26
[eq]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Eq.flix#L13-L18
[order]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Order.flix#L13-L18
[list-map]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/List.flix#L427
[list-sort]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/List.flix#L1418
[set-exists]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Set.flix#L359
[set-count]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Set.flix#L335-L346
[set-threshold]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Set.flix#L119-L122
[prelude-purity]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/Prelude.flix#L195-L205
[spec-reflect]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/monomorph/Specialization.scala#L544-L557
[spec-default]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/monomorph/Specialization.scala#L1441-L1445
[rbt-par]: https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/library/RedBlackTree.flix#L788-L808
[poly-default]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L8-L21
[poly-exists]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L72-L87
[poly-map]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L89-L105
[poly-compose]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L107-L119
[poly-formulas]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L121-L128
[poly-exclusion]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L134-L159
[poly-toplevel]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effect-polymorphism.md?plain=1#L220-L242
[reflect]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/purity-reflection.md?plain=1#L1-L34
[assoc]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/associated-effects.md?plain=1#L29-L166
[handlers-amb]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/effects-and-handlers.md?plain=1#L186-L198
[par]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/parallelism.md?plain=1#L18-L41
[lit]: https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/research-literature.md?plain=1#L13-L30
