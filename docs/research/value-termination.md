# Value-level structural termination research

Status: decision for issue #1715. Research only: it changes no compiler,
specification, or law-engine behavior. Every Kofun measurement below was taken
on `origin/main@638842470f622bbabb50c34a8bd9540e61dcbf33` on 2026-10-04.

## Decision

Defer a value-level structural termination check, the Kofun counterpart of
Flix's `@Terminates`. It needs two things and today has neither:

- **Something to recurse on.** Stage 2 enum constructors carry at most one
  `Int` payload. A recursive payload is refused at its first use (E9 below), so
  on the executable surface no value has a strict subterm of its own type. A
  rule built now would accept nothing a user could write.
- **Someone who needs the answer.** Law evidence is computed by complete
  evaluation and gains no level from a static fact. `pure fn` deliberately
  claims no termination. No compile-time path evaluates value-level code. No
  optimization is promised.

Reject these as consumers: the computed law evidence levels, optimization, and
`pure fn` itself. Reject the name `total`, Flix's annotation surface, Flix's
any-argument descent rule, and Flix's unchecked mutual recursion. A termination
boundary is deferred with the check, not rejected (question 1).

Keep, as the starting constraints of the RFC this deferral names, the rule
changes of question 2, the inferred fact with an assertive boundary of
question 3, the diagnostics of question 4, and the cost statement of
question 5. The next artifact is that RFC. It is tracked as #1718, which is
`blocked` on #30, and it should be opened only when both triggers hold:

1. Stage 2 accepts a recursive enum payload; and
2. a consumer needs a source-level refusal. Generic proof is not that
   consumer yet. RFC-0017 §5 restricts propositions to "pure total typed Core"
   and refuses "general recursion" without defining either at value level,
   but its v1 certificates do no recursive unfolding (lines 263–264) and defer
   recursion (lines 360–362). The likely first consumer is a later proof
   profile that admits recursion, or an RFC that lets compile-time code call a
   value-level function.

Flix and Kofun hold the same rule at opposite levels. Flix checks structural
recursion on ordinary functions
([book `termination-checking.md`](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L3-L16)).
`@Terminates` is an annotation on `def`s, so it does not cover Flix's
type-level features. Those are Boolean formulas decided by equivalence
([book `type-level-programming.md`](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/type-level-programming.md?plain=1#L8-L19))
and associated types chosen per trait instance
([book `associated-types.md`](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/associated-types.md?plain=1#L1-L5)).
This note did not examine how Flix bounds associated-type reduction. Kofun
decided structural termination for `type fn` (DD-031,
`spec/type-level-programming-v1.md` lines 166–183, RFC-0008) and has nothing at
value level. The Flix evidence below comes from reading its book and checker
at the pinned commits. Flix was not built or run for this note.

## Current Kofun behavior

`git rev-parse HEAD` printed `638842470f622bbabb50c34a8bd9540e61dcbf33`. Each
row is `bin/kofun check FILE` on the probe of that name. The appendix gives
every source exactly, and byte offsets refer to those files. E10b was added
after review. It was measured at `d2be8d45e85009913f681d662d009c1bc0ee44a0`,
which differs from that commit only by this note.

| # | Probe | Result |
| --- | --- | --- |
| E1 | `spin`: `pure fn spin(x: Int) -> Int { return spin(x) }` | `ok`, exit 0 |
| E1s | E1 with `--emit-typed-sidecar spin.sidecar.json --generation 1` | `ok`, exit 0; `kofun.typed-sidecar/v1`; the `spin` declaration (span 5..50, type `Int -> Int`) carries `effect` `{"display":"pure","status":"validated"}` |
| E2 | `countdown`: `pure fn`s recursing on `n - 1` and on `n + 1`, both after `if n <= 0 { return 0 }` | `ok`, exit 0; the two are not distinguished |
| E3 | `mutual`: `pure fn ping` calls `pong`, `pure fn pong` calls `ping` | `ok`, exit 0 |
| E4 | `while_loop`: `while i >= 0 { i = i + 1 }` in a `pure fn` | `ok`, exit 0 |
| E5 | `for_literal`: `for i in 0 .. 4 { ... }` in an `Int`-returning `pure fn` | `error[E2S10]: unsupported Core statement at byte 55` (the `for`), exit 3 |
| E6 | `callable_cycle`: `pure fn knot(x: Int) -> Int { return apply(knot, x) }` | `ok`, exit 0 |
| E7 | `enum_alias`: catch-all arm `other => { result = settle(other) }` inside `settle` | `ok`, exit 0 |
| E8 | `recursive_enum`: `type Nat = \| Zero \| Succ(prev: Nat)`, declared and unused | `ok`, exit 0 |
| E9 | `nat_use2`: E8 plus `Succ(p) => { result = 1 + depth(p) }` | `` error[E2S32]: constructor `Succ` of enum `Nat` declares a payload outside this Core slice; one `Int` field is supported at byte 153 ``, exit 1 |
| E10 | `landin_knot`: `let mut g = fn(y: Int) => y`, then `g = fn(y: Int) => g(y)` | `error[E2S12]: invalid Int expression at byte 70` (the reassigned lambda), exit 1 |
| E10b | `lambda_reassign`: E10 with the plain reassignment `g = fn(y: Int) => y + 1` | `error[E2S12]: invalid Int expression at byte 70`, exit 1: the same refusal without a knot |
| E11 | `lambda_local`: `return apply(fn(y: Int) => y + 1, x)` | `error[E2S12]: invalid return expression at byte 103`, exit 1 |

Two further measurements on the same commit:

- `bin/kofun check examples/lawful_list_monad.kofun` printed
  ``error[E2S02]: expected top-level `fn`, `type`, or `let` at byte 489``,
  exit 1. The compiler does not parse laws, so the `standard-v1` evaluator
  caps are target design, as `docs/LAW_SYSTEM.md` § *Status* says.
- `grep -rn -i -l "tarjan\|strongly connected\|\bscc\b\|lowlink" bootstrap/stage2/`
  printed nothing, exit 1. No Stage 2 source names a
  strongly-connected-component pass.

Read together: nothing on today's surface separates a terminating function
from a diverging one. E1–E4, E6 and E7 are accepted, and `pure` is published
for a function whose only action is to call itself (E1s). That is correct per
`spec/effects/pure-io-v1.md` lines 14–15: *"Divergence and panic remain
`pure`: this summary does not claim termination or totality."* This note
recommends no change to that sentence.

## What Flix's `@Terminates` checks

The book is pinned at `flix/book@687ccf7c`, and the compiler at
`flix/flix@35533f98`. `Terminator.scala` below is
`main/src/ca/uwaterloo/flix/language/phase/Terminator.scala`.

1. **Rule.** Every self-recursive call passes, in some argument position, a
   variable bound inside a constructor pattern on the formal parameter in that
   same position. Let-bindings and variable patterns are tracked as aliases
   and do not count as decreasing
   ([Terminator.scala L28–L33](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L28-L33)).
2. **Multiple parameters.** The book says only one parameter needs to
   decrease, and *"the other parameters may be passed unchanged"*
   ([book L61–L82](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L61-L82)).
   That is a permission, not a restriction: the book's own `loop(xs, acc + 1)`
   grows an accumulator
   ([book L102–L108](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L102-L108)).
   The implementation accepts a call when
   `argInfos.exists(_.status == Decreasing)` and constrains no other argument
   ([L371–L390](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L371-L390)).
   This admits accumulators such as `rev(xs, Cons(x, acc))`
   ([Test.Terminator.flix L29–L32](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/test/flix/Test.Terminator.flix#L29-L32)).
   It also admits two call sites that decrease different positions while each
   one grows the other. By our reading of those lines (not executed), Flix
   accepts the function below, and `f(L.Cons(0, L.Nil), L.Nil)` alternates
   between the first two arms forever:

   ```flix
   enum L { case Nil, case Cons(Int32, L) }

   @Terminates
   def f(x: L, y: L): Int32 = match (x, y) {
       case (L.Cons(_, xs), _)     => f(xs, L.Cons(0, y))
       case (L.Nil, L.Cons(_, ys)) => f(L.Cons(0, L.Nil), ys)
       case (L.Nil, L.Nil)         => 0
   }
   ```

3. **Mutual recursion is not checked.** The checker's own header lists this
   as *"Known unsoundness"*: two `@Terminates` definitions may call each other
   without any decrease. The same header says trait-signature calls go
   unchecked *"because ubiquitous operations like `+`, `-`, and `==` are trait
   sigs"*
   ([L55–L63](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L55-L63),
   [L525–L528](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L525-L528)).
   None of the eight `TerminationError` kinds is about a call cycle
   ([TerminationError.scala](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/errors/TerminationError.scala#L28-L242)).
4. **Callees.** A `@Terminates` function may call only `@Terminates`
   definitions
   ([book L154–L186](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L154-L186),
   [L460–L476](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L460-L476)).
5. **Closures.** It may apply a closure only when the callee is a formal
   parameter or a tracked alias of one
   ([L447–L458](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L447-L458),
   [L857–L866](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L857-L866)).
   The fact is conditional: `map` terminates *"assuming its function argument
   `f` also terminates"*
   ([book L115–L152](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L115-L152)).
6. **Forbidden expressions.** Mutable state, Java interop, concurrency,
   channels, unchecked casts and `unsafe` are refused inside the function
   ([L39–L40](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L39-L40)).
7. **Strict positivity.** An enum used for recursion may not mention itself
   left of an arrow
   ([book L188–L216](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L188-L216),
   [L34–L35](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L34-L35)).
8. **Integers.** Only constructor (`Tag`) patterns yield strict
   substructures. A constant pattern adds nothing
   ([L962–L990](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L962-L990)).
   Flix's own tests recurse on a user-declared
   `enum Nat { case Zero, case Succ(Nat) }`
   ([Test.Terminator.flix L6, L66–L77](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/test/flix/Test.Terminator.flix#L66-L77)).
9. **Cost.** The phase runs per definition, in parallel
   ([L76–L83](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/phase/Terminator.scala#L76-L83)),
   after pattern-match checking
   ([Flix.scala L549–L558](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/api/Flix.scala#L549-L558)).
10. **Consumers.** Outside the checker, the only reader of the
    decreasing-parameter fact is an editor inlay hint
    ([InlayHintProvider.scala L175–L190, L261–L275](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/api/lsp/provider/InlayHintProvider.scala#L175-L190)).
    The book also warns that the check says nothing about stack safety
    ([book L84–L89](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L84-L89)).

## Research questions and answers

### 1. Consumers

- **Law custom equality and operations: reject.** This is the target design;
  the compiler does not parse laws today (see above). A checked fact would
  raise no evidence level. It would only replace a resource failure with an
  earlier static refusal, and that refusal would also catch functions that do
  terminate. `docs/LAW_SYSTEM.md` line 158 requires custom equality to be
  *"total for the evaluated domain"*. Line 341 says assurance *"is computed by
  the checker"*. `bounded-exhaustive` and `proven-finite` (lines 344–355) are
  statements about evaluated cases. A case either completes, which is an
  observed termination, or crosses the 10,000,000-step or depth-256 cap. Lines
  333–336 make that a distinct stable diagnostic that fails `kofun check` and
  `kofun build`. So on a finite evaluated domain, termination is observed
  rather than assumed. A structural check is not necessary for these two
  levels.

  It is not sufficient either. Checked `Int` arithmetic aborts with `R010`
  (`spec/semantics.md` lines 18–23), and a structural check does not exclude
  that. It would also refuse terminating equalities that are not structural,
  such as normalizing a fraction by Euclid's descent on `Int`, which the
  evaluator would accept.
- **Law `proven`: defer.** RFC-0017 §5 (lines 221–233) admits propositions
  over *"pure total typed Core"* and refuses *"general recursion"*. Lines
  319–322 say `proven` does not mean *"a general theorem prover, termination
  checker, or mathematics"* beyond the closed rule set. At value level, this
  note's fact is the natural definition of "total". It is not sufficient,
  though. The v1 certificate rules (lines 240–257) include ADT case reduction
  but no induction. *"No recursive unfolding occurs in v1 certificates"*
  (lines 263–264), and recursion is deferred (lines 360–362). So v1 generic
  proof, #1278 included, is not the consumer. The trigger is a later proof
  profile that admits recursion.
- **`pure fn`: reject as a consumer and leave it unchanged.** `pure fn` does
  not need termination, and pure-io-v1's divergence sentence stays as written.
- **A termination boundary beside `pure fn`: defer, with the check.** An
  assertive boundary earns its place only when a consumer needs a place to
  refuse. That is how `pure fn` was justified: RFC-0014 (lines 51–52) selects
  the assertion, and lines 201–202 reject inference-only purity because
  *"authority would be invisible and E356 unexpressible"*. Nothing refuses a
  program today because a function might diverge, so termination has no
  analogue of E356 yet. That is trigger 2 of the deferral. Question 3 keeps
  the boundary's shape and question 4 keeps its refusals, both for the RFC.

  Reject the name `total`. The check bounds recursion only. It says nothing
  about `R010`, stack exhaustion, or other runtime errors, and RFC-0017 lines
  232–233 already refuse to *"pretend an overflowing operation is total"*.
- **Compile-time evaluation, and type-level functions calling value-level
  ones: defer.** No such path exists. Type-level v1 rejects value reflection
  (`spec/type-level-programming-v1.md` line 148). RFC-0008 line 399 says
  reduction *"introduces no value"*. A module-level binding is one integer
  literal (RFC-0006, `docs/SYNTAX.md` § *Module constants*).

  Suppose a later RFC adds such a path. RFC-0008 class rule 1 (line 115)
  already covers a callee with unknown termination: classify the value
  function `general` and let general-v2 fuel bound it. The fact would only let
  a structural root stay on the smaller default-v1 budget. That is a cost
  saving, not a soundness requirement, and the RFC that adds the path is the
  trigger.
- **Optimization: reject.** `spec/effects/pure-io-v1.md` lines 31–34 promise
  no optimization, and this note promises none either. Flix's only consumer
  outside its checker is an editor hint (item 10 above). One consequence for
  #1714 (discarded `pure` calls): `pure` does not license deleting a call
  (E1s), and a structural termination fact would not license it either,
  because `R010` stays observable.

### 2. Rule

The type-level steps cannot be reused unchanged. Steps 4 and 5 (build the
complete call graph; reject every inter-function cycle) carry over in content
but not in reach. At type level they apply to every declaration. At value
level DD-009 keeps the unrestricted default, so they apply only to the graph
reachable from asserted functions, with value references counted as edges. A
cycle elsewhere in the program is not an error. Step 6 changes:

| Concern | Type-level rule | Value-level form | Verdict |
| --- | --- | --- | --- |
| several parameters | one scrutinee; *"every argument is a strict matched subterm"* (lines 178–179) | one **structural parameter** per declaration: every direct self-call passes a strict subterm of that parameter in that parameter's position; other positions are unconstrained | keep |
| loops (DD-009) | none | `for` over a `List` or range: allowed if the iterated value is fixed at loop entry; `while`: refused inside a checked function | keep `for`, reject `while` |
| integers | RFC-0009 `Succ[p]` view on `Nat` | no value-level `Int` view; no guard reasoning | defer |
| ownership | *"No interaction"* (RFC-0008 line 398) | structural parameter in value, `read` or `take` mode; never `edit` | keep |
| lambdas and callable parameters | not applicable | #1711's edge: naming a function in value position is a call; calling a parameter adds no edge | keep |
| mutual recursion | rejected (line 144, step 5) | rejected unchanged, including a function naming itself in value position | keep |

**Several parameters.** Read literally, the type-level sentence forbids an
unchanged or accumulating second argument, which ordinary value code needs.
Flix accepts accumulators. Its book's *"may be passed unchanged"* is a
permission, not a restriction, and its own `loop(xs, acc + 1)` example grows
one
([book L91–L113](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L91-L113)).
But its implementation lets two call sites decrease different positions,
which is unsound (item 2). A fixed structural parameter is sound and accepts
accumulators. For a one-parameter declaration it coincides with the
type-level rule. Select it deterministically: the first parameter, in
declaration order, that decreases at every self-call. Aliases are tracked as
Flix tracks them. E7's `other` is an alias of `signal`, so `settle(other)` is
accepted today and would be refused.

**Loops.** DD-009 keeps `for` and `while` for ordinary code. The restriction
applies only inside a function that asserts termination.

- `for` over a `List` runs a fixed number of times only if the list cannot
  change during the loop. `docs/MEMORY_MODEL.md` lines 45–47 says only that
  the surface is *"immutable by default"*, so the RFC must require the
  iterated value to be fixed at loop entry, as the table says.
- For a range, `spec/semantics.md` line 67 does not say that `start .. end` is
  evaluated once. The RFC must pin that.
- `while` has no measure. A user-written measure would be a proof
  obligation, which `docs/LAW_SYSTEM.md` line 447 defers to refinement work
  after the ordinary type checker. Reject it for v1.

Today the measured surface has `while` (E4) but not `for` in an `Int` function
(E5).

**Integers.** Kofun has accepted numeric descent at type level only as a view.
RFC-0009 lines 211 and 267–274 bind `p = n - 1` under `Succ[p]` for `n >= 1`
and count `p` as a strict subterm. Value-level `Int` is signed and checked
(`spec/semantics.md` lines 15–23), and Stage 2 has no `Int` pattern view.
`countdown` and `countup` (E2) differ only in whether a guard bounds the
descent, and telling them apart is range analysis, not structure. Defer a
value-level view to the RFC. Reject guard inference for v1. Counted iteration
is `for i in 0 .. n`.

**Ownership.** The measure is the size of the structural argument, and
neither a `read` view nor a `take` changes it:

- A `read` view excludes a concurrent `edit` (`docs/MEMORY_MODEL.md` §3.1–3.2,
  lines 84–116), so the subterm cannot change while it is viewed.
- A `take` match moves the subterm out, and an affine value cannot own
  itself.
- `edit` must be refused for the structural parameter. An exclusive mutable
  view lets the body lengthen the subterm between the match and the recursive
  call. Then "a strict subterm when matched" no longer bounds the argument
  that the callee receives.

The rule also assumes immutable inductive data. That holds today: managed
values are immutable by default, and the enum slice rejects mutation
(`spec/enum-match-exhaustiveness.md` line 91). Any later proposal for mutable
fields must recheck it. Flix forbids mutable structures inside `@Terminates`
for the same reason (item 6).

**Lambdas and callable parameters.** Flix's fact is conditional on its closure
arguments (item 5). #1711 (open, in progress) fixes the same edge for
effects:

- a top-level function named in value position becomes a may-call edge from
  the function that names it;
- a call through a callable parameter adds no edge;
- a lambda body's calls are attributed to the enclosing function.

Reusing that edge does not make the fact unconditional. A call through a
callable parameter adds no edge, so an asserted `apply(f, x)` or `map(f, xs)`
is accepted. An unchecked caller can then pass it a diverging function such
as `spin`. The fact for a function with callable parameters is therefore
conditional on its callable arguments, exactly as Flix's is.

The edge buys something narrower: the fact is unconditional at a closed root.
A closed root is an asserted function with no callable inputs, whose
reachable graph is all checked. Every callable that reaches a function during
such a root's execution was created inside that checked graph. It was either
named, which is an edge to a checked function, or written as a lambda, whose
calls are attributed to its checked enclosing function. A consumer that
quantifies over function-typed values must check its callable inputs itself.

E6 shows the edge at work: `knot` passes itself to `apply` and is accepted
today. Under the rule, naming `knot` inside `knot` is a self-edge that is not
a call on a strict subterm, so it is refused.

Three preconditions remain:

- #1711's list of creation sites must be complete: module-level callable
  bindings (RFC-0006), callable record fields, and returned function names.
- A callable binding must not be reassignable inside a checked function.
  E10 shows Landin's knot is refused today at the reassignment, but E10b
  shows the refusal is incidental. A plain lambda reassignment is refused
  identically, because assignment in this slice accepts only `Int`. The RFC
  has to make the refusal a rule, so a wider assignment slice cannot admit the
  knot.
- Strict positivity applies once a recursive payload can be callable (item 7).

E11 shows that a lambda as a call argument is not lowered today in that
position.

**Mutual recursion.** Keep the type-level rejection unchanged. Reject Flix's
behavior, which the Flix header itself calls unsound (item 3). A measure that
spans several functions is left out of the RFC's first version. E3 is accepted
today.

### 3. Surface

**Keep the inferred fact with an assertive boundary, the shape of `pure fn`
over `effect`.** Reject the alternatives:

- **An annotation (Flix `@Terminates`): reject.** Kofun has no annotation
  syntax, and `#` begins a comment (`docs/SYNTAX.md` § *Comments*). Flix's
  callee restriction makes the annotation viral: every callee must carry it
  (item 4). Flix gave up on trait signatures because the arithmetic and
  equality operators are signatures (item 3). An annotation that has to spread
  through every callee reaches the operators first.
- **A declaration modifier on its own: reject.** It has the same virality in
  a different spelling. `type fn general` works at type level because the
  unmarked form is the checked default and every type function must
  terminate. At value level the default must stay unrestricted (DD-009), so a
  modifier would mark the restricted form and spread through callees exactly
  as the annotation does.
- **An inferred fact plus a boundary: keep.** #1245 shaped `pure fn` as one
  question asked in two places (`spec/effects/pure-io-v1.md` lines 38–49). The
  inference computes the summary for every function. The boundary refuses
  only where it is written, naming the first forcing call. `task pure-boundary`
  holds the two to agreement, and callees need no annotation.

  The termination question has the same shape: a least fixed point over "may
  diverge" roots. The roots are a non-structural self-call, a `while`, a
  member of a multi-function cycle, and a self value reference. The Stage 2
  query is already parameterized by root and code
  (`pure_boundary_violation(source, "print", "E2S176")`,
  `bootstrap/stage2/compiler.c` lines 31996–31997).

Publishing the fact needs a typed-sidecar version bump: v1 files are frozen
(`spec/effects/pure-io-v1.md` lines 64–70). Until then, the boundary can ship
as a checked query, as `pure fn` did. The spelling is the RFC's choice, with
one constraint: it is not `total` (question 1).

### 4. Diagnostics

**Keep, for the RFC.** These rules apply to every refusal:

- It is an ordinary Stage 2 code, not an `E3xx` one, for the reason
  `spec/effects/pure-io-v1.md` lines 51–57 give.
- It is ordered after the authority and `pure fn` refusals.
- It is independent of declaration order.

The refusals, by cause:

- **A self-call not on a strict subterm** names the call and gives a
  per-argument status. Flix's table is the model
  ([book L218–L248](https://github.com/flix/book/blob/687ccf7c6bd6a9872568c4dd8b2def7a7665c614/src/termination-checking.md?plain=1#L218-L248),
  [TerminationError.scala L82–L127](https://github.com/flix/flix/blob/35533f982dd75ee806dde039e60702c71a432c2d/main/src/ca/uwaterloo/flix/language/errors/TerminationError.scala#L82-L127)).
  Each argument is a strict subterm of its own parameter, an alias of `p`
  (E7), a strict subterm of `q` in the wrong position, a constructed value,
  or untracked. When the self-calls disagree on the structural parameter, the
  refusal names two calls that disagree.
- **Mutual recursion** gets no diagnostic in Flix, which accepts it. Kofun
  names the cycle, with its members in canonical identity order (the RFC-0008
  `E392` precedent, line 391). It also names the first call or value
  reference in the asserted body that enters the cycle, in source order, as
  `E2S176` does (`bootstrap/stage2/compiler.c` lines 31780–31781). The
  message says that descent is checked only on direct self-calls. It names
  the two remedies: merge the functions into one with a structural parameter,
  or drop the assertion. An illustration for E3, with no code allocated:

  ```text
  error[E2Sxxx]: `ping` is not structurally terminating: the call `pong(n)`
  enters the call cycle `ping` -> `pong` -> `ping`; descent is checked only
  on direct self-calls
  ```
- **A non-terminating callee** names the first such callee in source order,
  as `effect-io-callee` does.
- **A value reference** says that the function *names* `knot` in value
  position, rather than that it calls it (E6).
- **A loop** names the `while`.

### 5. Cost

**Keep "per-declaration walk plus one cycle pass" as the RFC's cost
statement.** Cost is not the reason to defer.

- **Local check.** One walk per declaration body, keeping each binding's
  relation to a parameter (alias or strict subterm). The cost is linear in the
  body size times the parameter count. Flix runs the equivalent per
  definition, in parallel (item 9).
- **Cycle check.** A strongly-connected-component pass over the unit's call
  and value-reference graph, linear in functions plus edges. No Stage 2
  source names such a pass (grep above). Its `pure fn` reachability is a
  token-level fixed point, bounded by one round per function
  (`bootstrap/stage2/compiler.c` lines 31704–31707, 31905–31912), and each
  round rescans function bodies. That is superlinear but adequate at Stage 2
  unit sizes. A check built on the same query inherits that bound.
- **Missing from the Stage 2 pair:**
  - recursive enum payloads (E9; the standalone
    `bootstrap/stage2/adt_frontend.c` lines 576–584 names the same refusal
    `E2S45`);
  - `for` in Core functions (E5);
  - value-reference edges (#1711);
  - binding provenance through match arms. The boundary matches an identifier
    followed by `(` (`function_calls_name`, lines 31708–31731). That is
    enough for reachability, but not for "this argument is a strict subterm
    of that parameter". The ownership checker's `BindingId`
    (`docs/MEMORY_MODEL.md` line 145) is the nearest existing structure.

  Each addition lands in both halves of the pair, `compiler.kofun` and
  `compiler.c`, as #1711's list of code sites shows.

## Decision matrix

| Item | Decision | Next artifact |
| --- | --- | --- |
| value-level structural termination check | defer | #1718 (the RFC), `blocked` on #30; opened when both triggers in *Decision* hold |
| law `bounded-exhaustive` / `proven-finite` consumer | reject | none |
| law `proven` consumer | defer | a later proof profile that admits recursion; RFC-0017 v1, and so #1278, does not |
| `pure fn` as the consumer, or any change to `pure fn` | reject | none; pure-io-v1 stays as written |
| a termination boundary beside `pure fn` | defer | #1718; its trigger is a consumer that needs a refusal |
| the name `total` | reject | none |
| compile-time / type-level consumer | defer | the RFC that first lets compile-time code call a value function |
| optimization | reject | none |
| rule changes (question 2), surface (question 3), diagnostics (question 4), cost (question 5) | keep | sections of the proposed RFC |
| Flix annotation surface, any-argument rule, unchecked mutual recursion | reject | none |

The RFC is filed as #1718. Its state is `blocked` and its `Blocked by` line
names #30, the open umbrella that owns widening production ADT payloads beyond
one `Int`. No open child of #30 plans a self-referential payload yet: #1270's
acceptance criteria refuse a "recursive infinite layout". So #1718 says to
re-refine rather than promote it when #30 closes. Trigger 2 is recorded there
as a precondition, not a tracker item.

One further follow-up is proposed rather than filed. Whichever proof profile
first admits recursion should cite this note for what "total" means at value
level, together with the induction rule that RFC-0017 v1 lacks.

## Validation

Run on `638842470f622bbabb50c34a8bd9540e61dcbf33`, and E10b on
`d2be8d45e85009913f681d662d009c1bc0ee44a0`:

- `bin/kofun check FILE` on each probe in the appendix reproduces E1–E11 and
  E10b.
- `bin/kofun check examples/lawful_list_monad.kofun` reproduces `E2S02`.
- The `grep` for a component pass prints nothing.

## Appendix: probe sources

Each file was saved as shown under an ignored `build/` directory.

`spin.kofun` (E1, E1s):

```kofun
pure fn spin(x: Int) -> Int {
    return spin(x)
}

fn main() -> Int {
    return 0
}
```

`countdown.kofun` (E2):

```kofun
pure fn countdown(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    return countdown(n - 1)
}

pure fn countup(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    return countup(n + 1)
}

fn main() -> Int {
    return countdown(3)
}
```

`mutual.kofun` (E3):

```kofun
pure fn ping(n: Int) -> Int {
    return pong(n)
}

pure fn pong(n: Int) -> Int {
    return ping(n)
}

fn main() -> Int {
    return 0
}
```

`while_loop.kofun` (E4):

```kofun
pure fn forever(n: Int) -> Int {
    let mut i = n
    while i >= 0 {
        i = i + 1
    }
    return i
}

fn main() -> Int {
    return 0
}
```

`for_literal.kofun` (E5):

```kofun
pure fn sum_small() -> Int {
    let mut total = 0
    for i in 0 .. 4 {
        total = total + i
    }
    return total
}

fn main() -> Int {
    return sum_small()
}
```

`callable_cycle.kofun` (E6):

```kofun
fn apply(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

pure fn knot(x: Int) -> Int {
    return apply(knot, x)
}

fn main() -> Int {
    return 0
}
```

`enum_alias.kofun` (E7):

```kofun
type Signal = | Red | Yellow(code: Int) | Green

pure fn settle(signal: Signal) -> Int {
    let mut result = 0
    match signal {
        Yellow(code) => { result = code },
        other => { result = settle(other) },
    }
    return result
}

fn main() -> Int {
    return 0
}
```

`recursive_enum.kofun` (E8):

```kofun
type Nat =
    | Zero
    | Succ(prev: Nat)

fn main() -> Int {
    return 0
}
```

`nat_use2.kofun` (E9):

```kofun
type Nat =
    | Zero
    | Succ(prev: Nat)

pure fn depth(n: Nat) -> Int {
    let mut result = 0
    match n {
        Zero => { result = 0 },
        Succ(p) => { result = 1 + depth(p) },
    }
    return result
}

fn main() -> Int {
    let zero: Nat = Zero
    return depth(zero)
}
```

`landin_knot.kofun` (E10):

```kofun
pure fn knot(x: Int) -> Int {
    let mut g = fn(y: Int) => y
    g = fn(y: Int) => g(y)
    return g(x)
}

fn main() -> Int {
    return 0
}
```

`lambda_reassign.kofun` (E10b):

```kofun
pure fn knot(x: Int) -> Int {
    let mut g = fn(y: Int) => y
    g = fn(y: Int) => y + 1
    return g(x)
}

fn main() -> Int {
    return 0
}
```

`lambda_local.kofun` (E11):

```kofun
fn apply(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

pure fn bump(x: Int) -> Int {
    return apply(fn(y: Int) => y + 1, x)
}

fn main() -> Int {
    return bump(1)
}
```
