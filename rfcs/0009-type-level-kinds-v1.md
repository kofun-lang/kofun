# RFC-0009: Type-level kinds v1 — `Nat`, `Symbol`, and `Bool` as type-level data

- Shepherd: hjosugi
- Opened: 2026-08-09
- Review closed: 2026-08-09
- Decided: 2026-08-09
- Status: accepted

Proposal for [#1133](https://github.com/kofun-lang/kofun/issues/1133). This
document records target semantics only; nothing in it is parsed, kinded, or
reduced by any active compiler. Acceptance decides the semantics and nothing
else — the three data kinds, the `kofun.type-reduction/kinds-v1` profile, the
eleven builtins, the two views, and `E394`–`E401` are decided target
semantics with no implementation behind them, and `release/claims.json`
remains the authority on what the compiler can actually do.

This proposal does not amend DD-031's rejection row. The row is owned by the
termination axis, and [RFC-0008](0008-type-level-general-v2.md) carries the
amendment that moves it.

This is the other half of the decision split recorded on
[#1130](https://github.com/kofun-lang/kofun/issues/1130).
[RFC-0008](0008-type-level-general-v2.md) owns the termination axis; this
document owns the **kind axis**, which the #1130 analysis measured as the
axis where most of the cited value actually lives: `Add[A: Nat, B: Nat]` is
unspellable in a Type-only profile at any fuel budget, and so is every
symbol-consuming parser. The two proposals are separable by design —
everything here recurses under v1's structural termination discipline, and
this document introduces the one thing that discipline does not supply on
its own: a budget sized for data.

## Summary

Type-level declarations gain three data kinds beside `Type`: `Nat`,
`Symbol`, and `Bool`. Literals of the data kinds are type expressions.
Nominal type declarations may take data-kind parameters as erased indices —
`type Vector[T: Type, N: Nat]` — with type equality decided on reduced
normal forms, so `Vector[Int, Add[1, 2]]` and `Vector[Int, 3]` are one
type. Builtin type functions give arithmetic, comparison, and symbol
operations at one logical step each. Two builtin pattern views — `Succ` on
`Nat`, `Cons` on `Symbol` — make the data kinds inductively matchable, and
the shrinking binder a view introduces counts as a strict subterm for the
structural termination check, so induction over numbers and strings lives
inside the v1 discipline. A root that reaches type-level data reduces under
a new named profile, `kofun.type-reduction/kinds-v1`, whose limits are sized
for a symbol-length descent rather than for v1's Type-shape transforms.

For someone writing Kofun: a `RouteParams["/users/:id/posts/:slug"]` that
derives parameter types, a `printf` checker, and a units library that adds
and subtracts exponents all become expressible — structurally, without any
of RFC-0008.

## Motivation

V1 is Type-only by decision: every parameter and result has kind `Type`,
and DD-031 defers higher-kinded computation. The #1130 issue motivates
type-level programming with three applications — arithmetic, parsing, and
fixpoints — and its own analysis then shows the first two are blocked on
kinds, not on termination. No fuel budget produces a `Nat`.

The blocked applications are the ones people actually want a strong type
system for. A typed router derives its parameter types from a route
literal, so `"/users/:id"` yields a `Param["id", Text]` and a handler that
names a parameter the route does not declare fails to compile; a units
library adds exponents in `Mul[Metre, Second^-1]`-shaped types; a
format-string checker walks a `Symbol` one scalar at a time. Under
this proposal each of these is a structural recursion: the router and the
checker descend on a `Cons` tail, and exponent arithmetic is a builtin
application per operation. Measured against the
[kofun-lang/kofun-type-challenges](https://github.com/kofun-lang/kofun-type-challenges)
corpus, this axis gates most of `medium` and much of `hard`; what it cannot
express at any kind is the non-structural residue that RFC-0008 owns.

The alternative that needs no new kinds — encoding numbers as nominal
`Zero`/`Succ` types — is spellable in v1 today and is the strongest
argument *for* this proposal: it has no literals (a vector of length 300 is
a 300-deep nominal spelling), no efficient arithmetic (`Mul[1000, 1000]`
constructs a million nodes against a 256-node budget), and no strings at
all. The existing named forms are insufficient in exactly the way the v1
review checklist asks a proposal to demonstrate.

## Detailed design

### Kinds

```text
kind := "Type" | "Nat" | "Symbol" | "Bool"
```

A kind annotation may appear on `type fn` parameters and results and on
nominal type declaration parameters. Four productions change, and with the
patterns below they are the whole grammar delta:

```text
type-function-declaration :=
    "type" "fn" TypeName "[" type-parameter ("," type-parameter)* "]"
    "->" kind "{" type-match "}"

type-parameter := TypeName ":" kind

type-declaration-parameters :=
    "[" type-parameter ("," type-parameter)* "]"

type-expression :=
    TypeName
  | nat-literal
  | symbol-literal
  | bool-literal
  | TypeName "[" type-expression ("," type-expression)* "]"
```

Each is load-bearing for something the document uses. V1 hard-codes
`"->" "Type"`, so without the first a `type fn` could not return a `Nat`.
V1's `type-parameter` is Type-only and belongs to type functions alone, so
without the second and third `type Vector[T: Type, N: Nat]` could not be
declared — today's nominal declarations take bare parameter names and no
kinds at all. Without the fourth, `Vector[Int, 3]` could not be written.

If RFC-0008 is also accepted, its optional `general` modifier composes with
the first production unchanged; the two proposals change disjoint parts of
it.

Any kind name outside the four is refused (`E395`), kind inference remains
unsupported, and higher kinds remain deferred exactly as DD-031 records —
this proposal adds data kinds, not kind polymorphism.

### Literals

- A `Nat` literal is an unsigned decimal, with no sign, no separators, and
  no leading zero except the single digit `0`. Its value is bounded to the
  checked 64-bit range `0 ..= 2^64 - 1`, matching the repository's refusal
  of silent numeric wrap — `spec/semantics.md` R010 requires a checked
  integer operation to refuse rather than wrap or saturate. A builtin whose
  result would cross the bound is a deterministic error (`E397`), never a
  wrapped value.
- A `Symbol` literal is a string literal without interpolation. Its value
  is a sequence of Unicode scalar values in NFC — the same normalization
  the v1 trace contract already fixes for its strings — and is bounded to
  65,536 UTF-8 bytes. A builtin whose result would cross that bound is
  refused (`E399`).
- A `Bool` literal is `true` or `false`.

The `Symbol` byte cap is the one bound that does not follow from the step
and node budgets, and that is why it exists: node *count* does not bound
node *size*. Twenty `Concat` doublings are twenty steps and twenty nodes —
comfortably inside any budget here — and produce a single logical node of a
megabyte. The trace is not the exposure (every trace string is capped at
4,096 bytes by the v1 schema, and this document elides symbols over 256
bytes in trace records); reducer memory is. A cap on the value is the only
place that blowup can be seen.

Literals are type expressions and valid match patterns for a scrutinee of
their kind.

### Nominal indices

A nominal type declaration may declare data-kind parameters:

```kofun
type Vector[T: Type, N: Nat]
type Param[Name: Symbol, T: Type]
```

Indices are **erased**: no field may read them, no layout computation may
depend on them, and `Vector[Int, 3]` and `Vector[Int, 4]` are two type
identities with one layout story, because a field can only be typed by a
`Type`-kinded expression and the term↔index boundary below keeps values
out of index position entirely.

Type equality reduces indices first: two applications of one nominal
constructor are equal when their `Type` arguments are equal and their
data-kind arguments have identical reduced normal forms. The reduction an
equality obligation performs is charged to that root obligation under
whichever profile the root selects.

**The v1-kinds boundary, stated hard: no term informs an index, and no
index constrains a term.** Indices come from literals and type-level
computation only. There is no promotion of a runtime value to a `Nat`, no
proof obligation that a list's length equals `N`, and no refinement
solving. Refinement, const, and shape systems retain their own owners, as
v1 already states; this proposal does not become their back door.

### Builtin type functions

| Builtin | Signature | Notes |
| --- | --- | --- |
| `Add`, `Mul` | `[Nat, Nat] -> Nat` | `E397` past `2^64 - 1` |
| `Monus` | `[Nat, Nat] -> Nat` | truncated subtraction; total, `Monus[3, 5]` is `0` |
| `Div`, `Mod` | `[Nat, Nat] -> Nat` | divisor `0` is refused (`E398`) |
| `NatEq`, `NatLt`, `NatLe` | `[Nat, Nat] -> Bool` | |
| `Concat` | `[Symbol, Symbol] -> Symbol` | `E399` past 65,536 bytes |
| `Length` | `[Symbol] -> Nat` | Unicode scalar count |
| `SymbolEq` | `[Symbol, Symbol] -> Bool` | scalar-sequence equality after NFC |

One builtin application is one logical step and one constructed node,
whatever the operand sizes. Builtins are structural by definition —
callable from both of RFC-0008's cost classes without affecting its class
rules — and they are the closed, constant-step surface that keeps "add a
builtin" from becoming the escape hatch RFC-0008's alternatives reject.

The eleven names occupy the type-function namespace. A user declaration
that reuses one is refused (`E401`) rather than shadowing or being
shadowed, because a silently shadowed `Add` would change reduction
arithmetic without changing any call site. The set is closed and grows only
by amending this document, exactly as RFC-0007's derive set does.

### Views and patterns

Two builtin pattern forms make the data kinds inductive:

- `Succ[p]` matches a `Nat` scrutinee `n >= 1` and binds `p = n - 1`.
- `Cons[h, t]` matches a nonempty `Symbol`, binding `h` to its first
  Unicode scalar (a one-scalar `Symbol`) and `t` to the remainder.

Views are pattern-only; construction goes through `Add` and `Concat`. The
pattern grammar, extending v1's `type-pattern` production, is exactly:

```text
type-pattern :=
    "_"
  | nat-literal
  | symbol-literal
  | bool-literal
  | "Succ" "[" binder "]"
  | "Cons" "[" binder "," binder "]"
  | TypeName
  | TypeName "[" argument-pattern ("," argument-pattern)* "]"

argument-pattern := type-pattern   -- in a `Type` argument position
                  | binder         -- in a data-kind argument position

binder := "_" | TypeName
```

Which alternative of `argument-pattern` applies is fixed by the
constructor's declared kind at that position, so the grammar is
unambiguous once declarations are resolved — which v1 already requires
before any pattern is tested. A pattern outside this grammar is refused as
`E396` rather than as a bare parse error, so the diagnostic names the rule
that excluded it.

Two restrictions do the work, and both are refused as `E396`:

**A view subpattern is a plain binder, never a nested pattern.**
`Succ[Succ[p]]`, `Succ[0]`, and `Cons[h, Cons[h2, t]]` are refused. This is
what makes the residual-arm rule below true rather than approximately true:
with irrefutable subpatterns a view arm's domain is exactly "every value of
the kind except the literals listed above it, and except zero or the empty
symbol", which is statically known. Nested views would make an arm's domain
depend on its subpattern and are deliberately left for a later amendment,
which would owe its own domain analysis.

**A data-kind argument position of a nominal pattern is a binder too.**
`Vector[t, 3]`, `Vector[t, Succ[n]]`, and `Param["id", t]` are refused;
`Vector[t, n]` is the way to match an indexed nominal, and the bound `n` is
then scrutinized by a helper declaration that takes it as a `Nat`
parameter. This keeps v1's rule for `Type` scrutinees exactly as written —
arms are non-overlapping nominal constructor heads —
and it keeps exhaustiveness a question about heads alone: with irrefutable
index positions, two arms with the same head cover exactly the same domain
and are duplicates, which v1 already refuses by comparing heads. Matching
an index inline would instead make two same-head arms cover *different,
possibly overlapping* domains, requiring an overlap and exhaustiveness
analysis over the product of the head and every index position — a design
this document deliberately does not attempt.

For the structural termination check, `p` and `t` are strict subterms of
the scrutinee, as is a `n` bound in a nominal index position — it is an
argument of the matched constructor, exactly like v1's `item` in
`List[item]`. `h` is **not** a strict subterm — a one-scalar symbol is not
smaller than a one-scalar scrutinee, and counting it would let `F["a"]`
recurse into `F[h]` forever. This is the rule that puts numeric and string
induction inside v1's structural discipline: a parser that peels
`Cons[h, t]` and recurses on `t` needs no fuel and keeps the v1 guarantee.

Views resolve **kind-directedly**, not by import: a `Nat` scrutinee admits
literal arms, `Succ`, and `_`; a `Symbol` scrutinee admits literal arms,
`Cons`, and `_`; a `Bool` scrutinee admits literal arms and `_`; a `Type`
scrutinee admits the v1 pattern forms, with data-kind argument positions
restricted to binders as above. Any pattern form the scrutinee's kind does
not admit is refused as `E396`, which therefore also covers a nominal
constructor pattern or a bare binder arm written against a data-kind
scrutinee. A user-declared nominal type named `Succ` is unaffected, because
pattern namespaces never mix across kinds — the view names are the one
place this document deliberately does *not* reserve a global name, and
`E401` covers the builtin functions, which are reachable from every
expression position and therefore cannot be disambiguated by kind.

### Matching over data kinds

V1's non-overlap rule cannot carry over unchanged — every literal overlaps
its kind's view (`3` is `Succ[2]`) — so data-kind matches get **residual
arm semantics**, the same idea v1 already uses for `_`: each arm matches
the domain left over by the arms before it. The static discipline that
keeps arms' domains describable (`E396` refuses violations):

1. literal arms first, mutually distinct;
2. then at most one view arm, whose subpatterns are binders and whose
   domain is the residual — every value of the kind except the listed
   literals (and except zero/empty, which the view never matches);
3. then at most one final `_`, exactly as v1.

Exhaustiveness for a `Nat` scrutinee needs `0` (or `_`) alongside `Succ`;
for `Symbol`, `""` (or `_`) alongside `Cons`; for `Bool`, both literals or
`_`. Every arm's domain is statically known, so diagnosability and v1's
determinism sentence — arms fire in source order over statically
partitioned domains — survive intact.

### The kinds-v1 budget

V1's budget was sized for Type-shape transforms, and it is the frame limit,
not the step limit, that a data-kind induction hits first: v1 has no tail
replacement, so a `Cons` descent whose recursive call sits in the result
expression consumes one frame per scalar, plus one for the base case, and
dies at scalar 32. A 40-byte route literal does not fit. A profile is
therefore not optional here; it is the piece the kind axis needs from the
reduction discipline, and it is scoped to roots that touch data.

A root runs under `kofun.type-reduction/kinds-v1` when its statically
resolved graph reaches a data-kind literal, a builtin, a view, or a
declaration with a data-kind parameter. Otherwise it runs under
`kofun.type-reduction/default-v1` verbatim. If RFC-0008 is also accepted, a
root that additionally reaches a `general` declaration selects general-v2,
whose limits are ≥ these in every dimension, so widening the reachable
graph never narrows the budget.

| Resource | default-v1 | kinds-v1 | Exact count |
| --- | ---: | ---: | --- |
| Active frames | 32 | 1,024 | entered alias/type-function frames not yet returned, after tail replacement |
| Logical steps | 256 | 262,144 | alias expansions, fired arms, and builtin applications |
| Constructed logical nodes | 256 | 1,048,576 | nodes constructed during the root reduction, including view bindings |

Three rules come with the numbers, and all three are semantics rather than
optimizations, because each decides which programs are refused:

- **Tail replacement.** When the entire result expression of a fired arm is
  a single type-function or builtin call, entering the callee replaces the
  current frame rather than stacking on it. Steps are still charged.
  RFC-0008 states the same rule for its own profile; the only difference in
  wording is that this document also names builtin calls, which RFC-0008
  cannot define alone. Accepting either proposal alone introduces the rule
  for that proposal's profile only.
- **A view match constructs its bindings.** `Succ[p]` constructs one node
  and `Cons[h, t]` constructs two, charged when the arm fires. Without this
  the node counter — which decides `E400` — would be undefined for exactly
  the descent this profile is sized for, since `h` and `t` do not exist
  before the match. Pattern testing itself remains free of steps, as v1
  states.
- **The frame number is a non-tail depth.** With tail replacement, 1,024
  frames is the depth of a recursion that builds its result *around* the
  recursive call rather than returning it directly — the shape a router
  has when it collects each parameter into a growing record. A descent
  deeper than that is rewritten so the recursive call is the whole result,
  and is then bounded by steps rather than frames.

The two data numbers are derived from the `Symbol` cap, which bounds a
descent at 65,536 scalars: 262,144 steps is four per scalar, and 1,048,576
nodes is sixteen per scalar, of which two are the `Cons` bindings and the
rest is the per-scalar result the descent builds.

Limits are checked before entering frame 1,025, performing step 262,145, or
constructing node 1,048,577. No command-line, manifest, source-language,
editor, or environment option raises a limit — v1's sentence, unchanged in
force. Crossing one is a deterministic type error (`E400`) that never
produces `Any`, a partial type, or a cacheable success.

Every declaration reachable from a kinds-v1 root is structural, so a
definite reduction cycle cannot arise from an admitted program; v1's
requirement that the runtime cycle guard fail closed against a corrupt or
stale artifact is unchanged and needs no new code here. If RFC-0008 is also
accepted, a root that reaches a `general` declaration is under general-v2
and `E393` is its cycle diagnostic.

### Rendering and traces

`Nat` values display in decimal, always — `Succ` is a pattern, not a
display form. `Symbol` values display quoted with the existing string
escape rules. The 4,096-byte display and diagnostic budgets are unchanged,
with truncation only at a scalar boundary, stated explicitly. Named
display stays named, as v1 requires: a hover shows
`Vector[Int, Add[1, 2]]` as written, and equality — not display — is what
reduces.

A kinds-v1 root produces `kofun.type-reduction-trace/v2`, the sibling
schema to v1 jointly defined by this proposal and RFC-0008. The two
proposals contribute disjoint field sets and v2 lands containing whichever
are accepted; RFC-0008's contribution is the `cost_class`/`tail` step fields
and the root attribution table, and a v2 producer built from this proposal
alone never emits them.

Two structural changes to v1's frame are shared, and each document states
them in full so that either can be accepted alone:

- **`profile` and the limit record are values, not constants.** V1 pins
  both to `default-v1`; v2 carries whichever profile the root selected and
  that profile's three limits. This is what lets one schema serve a profile
  other than default-v1.
- **Step retention is bounded at 256 records.** A reduction of at most 256
  steps retains all of them, and retention equals v1's. A longer one
  retains the first 128 and the last 128, and the root records the exact
  `elided_steps` count and the two boundary step indices. This supersedes,
  for v2 roots only, v1's every-step retention rule and its requirement
  that `cumulative_steps` equal the record index.

This proposal's own contributions to v2:

- a third step-record discriminant, `builtin-application`, alongside
  `alias-expansion` and `type-function-arm`. A builtin has no declaration
  and no arm, so the record carries the builtin's name and the span of the
  application site in place of v1's `declaration_symbol_id` and
  `arm_index`. Without it a builtin step would be a charged step with no
  representable record, which no retention rule can reconcile;
- data-kind value forms in the named input and output fields, with a
  symbol longer than 256 bytes rendered elided and carrying its exact byte
  count. The trace is non-authoritative tooling data, so elision loses no
  authority.

Roots that reduce entirely under default-v1 keep producing the v1 trace,
byte for byte.

### The v1 review checklist

| # | Item | Where |
| --- | --- | --- |
| 1 | name, owner, kinds, grammar delta | Kinds; Views and patterns — the `kind`, `type-function-declaration`, `type-parameter`, `type-declaration-parameters`, `type-expression`, and `type-pattern` productions; profile `kofun.type-reduction/kinds-v1` |
| 2 | why v1 forms are insufficient | Motivation: the nominal `Zero`/`Succ` encoding and its three failures |
| 3 | termination proof and accounting | Views: strict-subterm status; builtins one step/node each; the kinds-v1 budget and its derivation |
| 4 | deterministic evaluation and cache identity | Matching: statically partitioned domains; Semantics: stuck-term equality; indices in type identity |
| 5 | named rendering | Rendering and traces |
| 6 | new trace records or schema | Rendering and traces: the `builtin-application` discriminant and data-kind value forms, contributed to the jointly defined v2 schema |
| 7 | executable vectors | Validation |
| 8 | CLI/LSP/debugger consumers | `kofun type eval`/`explain` accept data-kind literals; same structured facts |
| 9 | maximum diagnostic and trace sizes | unchanged: 4,096 bytes and 4 MiB |
| 10 | compatibility and migration | Compatibility and migration |

## Semantics

Type expressions are kind-sorted; kind checking precedes reduction, and a
kind error is static (`E394`), never a reduction outcome. The builtins
reduce as total functions on their domains except the three named
refusals — overflow (`E397`), zero divisor (`E398`), length cap (`E399`)
— each of which is a deterministic error with structured facts and never
`Any`, a partial type, or a cacheable success, exactly as v1 words it.

Equality of closed data-kind values is equality of reduced normal forms:
numeric equality for `Nat`, scalar-sequence equality after NFC for
`Symbol`, literal equality for `Bool`. Nominal type equality compares
constructor identity, `Type` arguments structurally, and data-kind
arguments by value equality after reduction.

**A builtin applied to an operand that is not a closed value is a stuck
term**, and two stuck terms are equal exactly when their reduced normal
forms are syntactically identical. So inside a declaration parameterized
over `N: Nat`, `Add[N, 1]` equals `Add[N, 1]` and does *not* equal
`Add[1, N]`. This is deliberate and is the boundary that keeps the proposal
from being a dependent-type system by accident: there is no commutativity,
associativity, or cancellation reasoning, and no decision procedure over
open arithmetic. A design that wants `Add[N, 1] ≡ Add[1, N]` is proposing
a solver, which refinement retains its own owner for.

Deliberately left undefined in v1 kinds: negative numbers and any signed
kind; a character kind distinct from one-scalar `Symbol`; ordering on
`Symbol`; nested view subpatterns; non-decimal `Nat` literal syntax; and
any layout interaction — indices are erased, so there is none.

## Diagnostics

| Code | Refusal | What the message names |
| --- | --- | --- |
| `E394` | a kind mismatch | the expression, the kind it has, the kind its position requires |
| `E395` | an unknown kind name | the name, and the four admitted kinds |
| `E396` | a pattern the scrutinee's kind does not admit, or an invalid arm sequence | the duplicated literal, the literal after a view arm, the second view arm, the nested view subpattern, the literal or view in a nominal index position, the pattern form the kind does not admit, or the missing base case — whichever it is, with the arm spans |
| `E397` | `Nat` overflow past `2^64 - 1` | the builtin, both operands, and the bound |
| `E398` | `Div` or `Mod` by zero | the builtin and the dividend |
| `E399` | a `Symbol` result past 65,536 UTF-8 bytes | the builtin, both operand lengths, and the bound |
| `E400` | a kinds-v1 limit crossed | which limit; measured frames, steps, and nodes; all three limits; the last declaration or builtin, arm index, and span |
| `E401` | a declaration reusing a builtin type-function name | the name, the declaration span, and the closed builtin set |

`E390`–`E393` are RFC-0008's. `E402`+ are unclaimed. If both proposals are
accepted, `E400` and RFC-0008's `E390` are the same refusal under two
profiles and may be merged into one code by amendment; they are kept apart
here so that accepting either proposal alone yields a complete, unshared
diagnostic set.

## Ownership and effects

No interaction. Indices are erased and the term↔index boundary keeps
values out of type position, so no binding, move, or effect-row entry
exists to interact with. `read`/`edit`/`take` never see a data-kind value.

## Alternatives

**The nominal encoding, today, with no new kinds.** Covered in Motivation:
spellable and useless at scale — no literals, no constant-step arithmetic,
no strings. Doing nothing has the same shape with less honesty, because
the corpus value this axis gates stays uncited on any decided record while
#1130 alone would carry, per its own analysis, the cost without the
headline benefit.

**Opaque `Nat`/`Symbol` with builtins only, no views** — GHC's TypeLits.
Rejected: induction becomes impossible without axioms, which is GHC's
documented pain, and every recursive algorithm then needs RFC-0008's fuel
even when it is structurally a descent. The views are the piece that keeps
user recursion inside the guarantee.

**Views without a new profile**, leaving data-kind roots on default-v1.
Rejected on measurement rather than taste: v1's 32 active frames cap a
non-tail `Cons` descent at 31 scalars, so
`"/api/v1/organizations/:org/projects/:project"` — 44 scalars, and not an
unusual route — would not fit. Shipping the kinds without the budget would
make the headline claim false.

**Full promotion of user ADTs to kinds** (DataKinds). Deferred with higher
kinds, as DD-031 already records: it requires the kind-polymorphism,
coherence, and evidence decisions v1 deliberately separated. `Nat`,
`Symbol`, and `Bool` are the bounded core with measured demand.

**Template-literal multi-hole patterns** — TS-style `"${a}/${b}"`.
Rejected for v1: their ambiguity-resolution rule is a design of its own,
and `Cons` plus literal arms already expresses the same parsers with the
recursion made explicit. A prefix-literal sugar can arrive later as an
amendment carrying its own ambiguity rule.

## Drawbacks

This is the largest type-checker surface since traits: kind sorting,
literal forms, two pattern namespaces, a third reduction profile, value
equality inside type equality, and reduction reachable from the term
checker's equality path. Each piece is bounded, but the sum is real.

Eleven builtin names become unusable as user type-function names, and
`E401` is a refusal someone will hit on `Length` before they have written
any type-level code at all.

The caps — `2^64`, 65,536 bytes, and the three kinds-v1 limits — are five
new refusal surfaces whose constants someone will hit. All follow the
repository's refuse-rather-than-wrap precedent, and all are semantics, so
all version with the language.

Kind-directed pattern namespaces are one more resolution rule a reader
must know, chosen over imports precisely because an importable `Succ`
could collide with user code.

Scalar-peel parsing is verbose. A route pattern is read one Unicode scalar
at a time, and the resulting declarations are longer and less obvious than
the template-literal spelling this document rejects for v1.

## Compatibility and migration

**Additive.** No accepted program changes meaning and none stops
compiling: neither kind annotations on type parameters nor `type fn`
exists in any tracked source.

Compatibility queries, run on `main@a654f7fe`:

```sh
git grep -nE '\[[A-Za-z_]+:[[:space:]]*(Nat|Symbol|Bool)\b' -- '*.kofun' | wc -l
git grep -nE '^type fn ' -- '*.kofun' | wc -l
git grep -nE '^type (Add|Mul|Monus|Div|Mod|NatEq|NatLt|NatLe|Concat|Length|SymbolEq)\b' -- '*.kofun' | wc -l
```

all return `0` — no tracked Kofun source annotates a type parameter with a
data kind, declares a type-level function, or declares a type whose name
this document reserves. `Nat` and `Symbol` are new type-namespace names in
kind position only, so no existing nominal type is shadowed.

If this proposal is accepted, DD-031's "Type-only" sentence gains the
ledger amendment pointer, alongside whatever RFC-0008's disposition adds.
There is no migration action for any program until an implementation
enables the syntax.

## Implementation plan

In order, each independently reviewable and separately gated:

1. **Kind checking and literals as surface**: parse kind annotations and
   data-kind literals, refuse `E394`–`E396` and `E401`, keep reduction
   refused — fail-closed, mirroring RFC-0007's first slice and RFC-0008's
   second.
2. **Trace v2's shared frame plus this document's contributions**: the
   `builtin-application` discriminant and data-kind value rendering, with
   schema vectors under `spec/type-reduction-trace/`. Provable before any
   reducer exists, exactly as v1's contract was. If RFC-0008 is accepted
   first, this slice extends the v2 artifact its first slice landed.
3. **Builtins, caps, and the kinds-v1 profile** in the structural reducer:
   `E397`–`E400`, tail replacement, one step and one node per builtin
   application.
4. **Views and data-kind matching**: kind-directed patterns, residual arm
   validation, the strict-subterm extension to the structural check.
5. **Nominal indices**: erased data-kind parameters and
   equality-by-reduction in the term checker, including stuck-term
   equality — the largest slice, gated alone.
6. **The corpus**, shared with RFC-0008's plan: each ported problem
   records which proposal unblocks it, so this document's central claim —
   that the kind axis carries most of the value — is measured on the
   record that decides both.

Acceptance of this proposal is not a commitment to a schedule, and no
implementation child is created until it is accepted.

## Validation

| Gate | Proves |
| --- | --- |
| a future `task type-level` gate, kinds leg | a route-literal parse by `Cons` descent reduces to the expected named form under the *structural* kinds-v1 profile — the headline claim, executable, with a literal long enough that v1's 32 frames would not have held it |
| the same gate's arithmetic leg | exponent bookkeeping through `Add`/`Monus` at one step per operation; `Vector[Int, Add[1, 2]]` equal to `Vector[Int, 3]` and unequal to `Vector[Int, 4]`; `Add[N, 1]` unequal to `Add[1, N]` under an open `N` |
| the same gate's refusal corpus | `E394`–`E401` each fire with exact structured facts; `Add` at the 64-bit boundary and `Concat` at the byte cap refuse at the crossing step; a duplicated literal arm, a nested view subpattern, a literal in a nominal index position, and a missing `0` base are refused statically |
| the same gate's budget leg | a non-tail descent 1,025 frames deep is refused as `E400` naming the frame limit, and its accumulator-passing rewrite of the same computation succeeds — the tail rule, executable |
| the trace leg of `task type-reduction-trace` | builtin steps appear as `builtin-application` records; data-kind values render with the 256-byte elision rule; warm and cold runs are byte-identical |

The negative fixture that bounds the claim is the term↔index boundary: a
nominal `Vector[T, N]` applied to a value expression in index position is
refused as `E394` naming the kind boundary, with no reduction attempted —
proving the proposal adds type-level data without opening a dependent-type
back door.

## Unresolved questions

**Are 1,024 frames, 2¹⁸ steps, and 2²⁰ nodes the right constants?** Settled by
porting the corpus onto the first kinds reducer before review closes; they
freeze at acceptance and change afterward only as `kinds-v2`.

**Is scalar-peel parsing readable enough in practice**, or does the
prefix-literal sugar (`"users/" ++ rest`-shaped patterns) need to arrive
with v1 kinds rather than as a later amendment? Settled by porting the
router and `printf` problems from the corpus and reading them.

**Is 65,536 bytes the right `Symbol` cap** against real reducer memory?
Settled with the first builtin implementation, which is slice 3.

**Should `E400` and RFC-0008's `E390` be one code** if both proposals are
accepted? Settled at the second acceptance, by amendment, not before.

Every other question this proposal raises is answered above.
