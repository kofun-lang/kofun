# Bounded `pure` / `io` inference v1

Stage 2 infers one effect summary for every top-level function in a successful
bounded compilation unit. The lattice is exactly:

```text
pure < io
```

`print` is the only direct `io` root in this profile. A caller is `io` when it
can reach that root through the compiler's resolved top-level function-call
observations; otherwise it is `pure`. A value reference — a top-level function
named in value position — is one of those observations, as
[Function values](#function-values) defines. The monotone analysis computes
the least fixed point, so self-recursive and mutually recursive components
without a root stay `pure`, while a root makes every reaching caller `io`.
Divergence and panic remain `pure`: this summary does not claim termination or
totality.

The result is emitted as the existing typed-sidecar `effect` fact on each
function declaration. Its display is exactly `pure` or `io`. Direct roots use
the public reason `effect-io-root-print`. Transitive facts use
`effect-io-callee` and depend on the lexicographically first immediate resolved
`io` callee's function node, which names the explanation without copying a
possibly private identifier into a free-form reason string. That choice is
made after convergence, making it independent of declaration and traversal
order.

Inference runs only after Stage 2 reports a successful compilation. Unknown
calls therefore keep their existing compiler diagnostic and are never
optimistically classified. Failed or cancelled partial semantic-event streams
do not fabricate effect facts.

This slice has no effect rows or row variables, subtyping, polymorphism,
handlers, resumptions, capability checking, runtime change, or optimization
promise. The representation can be widened by a later version, but `pure` and
`io` are the complete executable set in v1.

## Function values

An edge is a may-call. A top-level function `g` named in value position inside
the body of `f` — passed by name as a callable argument, as in
`apply(noisy, x)` — adds the edge `f → g`, exactly as the call `g(...)` would.
Naming the root as a value, `apply(print, x)`, reaches the root directly.
Value position is the one place this profile accepts a bare function name as a
value: a whole call argument, decided by the compiler's own
`call_argument_position`. Anywhere else the name is refused (`E2S35`), so no
program using it there compiles and there is no other value position to
observe. The `pure fn` boundary below and the published `effect` fact ask this
one predicate, so they charge the same names.

The effect is charged where the value is created, not where it is called. A
call through a callable parameter — `f(x)` inside `apply` — names no top-level
function and adds no edge, so `apply` itself stays `pure` whatever it is
handed. That is sound rather than optimistic: every caller that hands `apply`
an `io` function has already named that function, and is `io` through the
value it named. Passing a `pure` function keeps the caller `pure`. The charge
does not ask whether the receiver ever calls the value: `ignore(noisy, x)`,
where `ignore` never calls its callable parameter, still makes its caller `io`.
That over-approximation is the rule, not an accident of it; a summary for
`apply` or `ignore` that depended on its argument would be effect
polymorphism, which v1 does not have.

A function value has exactly two origins in this profile: naming a top-level
function, which adds the edge above, and a lambda, whose body lies inside the
enclosing function, so its calls are already that function's observations —
`let g = fn(y: Int) => noisy(y)` followed by `apply(g, x)` makes the
enclosing function `io` through `noisy` without any value edge.
Returning a function by name, binding one to a local, passing one after an
argument label, binding one at module level, and storing one in a record field
are each refused, so no program carrying one compiles; admitting any of them
has to add the same edge, and `task pure-boundary` pins each refusal so that
admitting one changes a golden. The match is by name, as it is for calls: a
parameter or local that shadows a top-level function's name is charged as that
function, which over-approximates and never classifies optimistically.

A callee reached through a value reference is explained like any other:
`effect-io-callee`, with the fact dependency naming the referenced function's
node. The reason vocabulary is unchanged.

## The `pure fn` boundary

The inference above is a summary this slice computes; it decides nothing. #1245
adds the one source annotation `pure fn`, the spelling #1241 froze, which
requires that summary to be `pure` for the function it prefixes.

It introduces no effect semantics of its own. The lattice, the root, and the
least fixed point are the ones defined above; the boundary asks that same
question at compile time, before a semantic-event stream exists, and refuses
the program when the answer is `io` — naming the root reached directly, or the
first call or value reference in the body that carries it, as `E2S176`. Because the answer is one
question asked in two places, an accepted program's published `effect` fact and
the boundary's silence have to agree, and `task pure-boundary` compiles the
same sources through both to check that they do.

That is an ordinary Stage 2 code and deliberately not an `E3xx` one. The `E3xx`
space holds RFC design identities that no emitter produces yet, and every band
in it is allocated or is a gap beside its owner — including `E350`-`E356`,
where RFC-0002 and #1241 reserve `E356` for the environment-specific violation
the integration child will emit through this same query. The boundary is
checked after the authority refusals, so a program with both faults answers
with the authority one.

A refusal is a compilation failure, so it happens before the inference above
runs and no effect fact is published for that unit. `pure` outside the position
before `fn` remains an ordinary identifier, and an unannotated function that
reaches a root is still inferred `io` rather than refused.

The annotation publishes nothing of its own. A boundary fact beside the
`effect` fact would need a typed-sidecar fact kind, a public reason, or a node
kind, and all three are declared in files that
`spec/concurrency/scoped-captures-v1/v1.sha256` freezes — §10 of that contract
states that no v1 file is extended in place. So the checked query is the whole
interface in v1: a consumer asks it, rather than reading an answer the
sidecar carries. Publishing the assertion is a typed-sidecar version bump.

`pure fn` is the whole surface. `io fn` is not an annotation: the profile named
one spelling, and the other word in the same position stays the unknown
visibility modifier it already was. A later version that wants it has to say so
rather than inherit it by omission.

## Discarded pure results

**Accepted target semantics. No compiler implements this section yet.** It
records the decision on
[#1714](https://github.com/kofun-lang/kofun/issues/1714), which the decision
owner accepted on 2026-10-04 as amended by the argument-effect rule. The ledger
indexes it as `DD-042`. Until the refusal is implemented, every program this
section refuses still compiles, as measured below. The implementation is
#1730, which is ordered after #1711.

### Current behavior

Measured on `origin/main@7d2caf6f3fa3bf733533b08ccf20b6551c3e13f0`,
2026-10-04, where `twice` is `fn twice(x: Int) -> Int { return x + x }` and
`noisy` is the function in the program under *Arguments carry effects*:

| Statement in `main` | Command | Result |
|---|---|---|
| `twice(21)`, then `print(1)` | `bin/kofun check` / `bin/kofun run` | `ok`, exit 0 / prints `1`, exit 0. `--emit-typed-sidecar … --generation 1` publishes `twice` as `pure`, status `validated` |
| `1 + 2` | `bin/kofun check` | ``error[E2S10]: unsupported Core statement at byte 23``, exit 3 |
| `let _ = twice(21)`, then `print(1)` | `bin/kofun check` / `bin/kofun run` | `ok`, exit 0 / prints `1`, exit 0 |
| `forward(noisy, 7)` | `bin/kofun check` / `bin/kofun run` | `ok`, exit 0 / prints `7`, exit 0. The sidecar publishes `forward` and `main` as `pure`, `noisy` as `io` |
| `twice(noisy(3))` | `bin/kofun run` | prints `3`, exit 0 |

A call is therefore the only expression a statement can discard today, and
nothing refuses the discard.

### The rule

A statement that is a call and nothing else discards the call's result. Such a
statement is refused when all three conditions hold:

1. the call's result type is not `Unit`;
2. the callee is a top-level function whose `effect` fact is `pure` with status
   `validated`; and
3. every argument's own summary is `pure`.

An argument's summary is what evaluating that argument contributes under the
observations the first section defines. It is `io` when the argument calls a
function whose summary is `io`, the root `print` included, or names one as a
value; otherwise it is `pure`. An argument that names a top-level function
counts as that function's effect, which is the same edge #1711 adds to the
published fact.

The refusal is fatal, like every registered diagnostic. Kofun has no non-fatal
diagnostic class — at the commit above `tests/diagnostics/registry.tsv` has 213
rows that exit `1`, one that exits `2`, and none that exit `0` — and this rule
does not add one. Its code is an ordinary Stage 2 code that the implementation
allocates and registers; this section allocates none.

This does not extend the shadowing rule in
`spec/syntax/FOUNDATIONS_AND_CONTROL.md` (§ #41), which stands as written. That
rule keeps a linter's *opinion* about shadowing out of the compiler. Whether a
discarded result is useless is decided by a fact the compiler already computes
and publishes.

### Arguments carry effects

```kofun
fn noisy(x: Int) -> Int {
    print(x)
    return x
}

fn forward(f: (Int) -> Int, x: Int) -> Int {
    return f(x)
}

fn main() -> Int {
    forward(noisy, 7)
    return 0
}
```

`forward` is `pure`, and stays `pure` after #1711, because #1711 charges an
effect where a function value is named, not inside the function that calls it.
Yet the statement `forward(noisy, 7)` prints `7`. A rule that read only the
callee's fact would refuse a program with a real effect. Condition 3 accepts
this program because the argument `noisy` is `io`. `twice(noisy(3))` is accepted
for the same reason: `twice` is `pure`, but its argument calls `noisy`.

A call through a callable parameter or local, such as `f(x)` inside `forward`,
names no top-level function. It has no `effect` fact, so condition 2 never
holds and the statement is never refused.

A lambda written directly as a call argument is outside the current slice:
`forward(fn(y: Int) => noisy(y), 7)` as a statement is
``error[E2S12]: invalid expression statement at byte 142``, exit 1, on the
commit above. Under the first section a lambda's calls belong to the function
whose body contains it, so a lambda argument whose body reaches `print` has an
`io` summary when a slice admits one.

### Exemptions and the explicit discard

**A `Unit` result is exempt.** The first section keeps divergence and panic
`pure`. A `pure` call that returns `Unit` can therefore be made only for its
panic, as an invariant check is, and that is a legitimate use. Stage 2 cannot
express the case yet. It refuses a non-`main` function without an admitted
result type, so `fn check(x: Int) -> Unit` with a body is
``error[E2S15]: Core function `check` requires Int or concrete enum parameters and return``,
exit 1, on the commit above. The exemption is stated now so that admitting
`Unit` results does not turn every invariant check into a refusal.

**An effectful call is never refused.** When the callee is `io`, or any
argument is, the statement has an effect, and this section concerns only
statements that have none.

**`let _ = e` is the sanctioned explicit discard.** No new form is added. Flix
spells the explicit discard `discard e`, and Kofun does not adopt that. The
form already checks `ok`, as the table above shows. Measured on the same
commit, though, `_` in that position is an ordinary binding name, not a
wildcard. A second `let _ =` in one scope is
``error[E2S47]: duplicate binding `_` in lexical scope at byte 95; first declaration at byte 73``,
exit 1, and `return _` after `let _ = twice(21)` checks `ok`. This section does
not decide whether `let _` becomes a non-binding discard so that it can repeat.
The question is recorded for the decision owner under *Open conflicts* below.

### Only a validated answer refuses

The rule asks the question the published `effect` fact answers, and it acts
only on a `validated` answer. Like the `pure fn` boundary, it asks at compile
time, through the same query, so an accepted program's published facts and the
refusal's silence agree. A refusal fails compilation, so a refused unit
publishes no fact, as with `E2S176`. The rule never fires on a partial, failed
or cancelled semantic-event stream. It also never fires on a `provisional`,
`error` or `unavailable` fact (`spec/tooling/typed-sidecar.md`, § Fact status
lattice). A refusal resting on a fact the compiler could not validate would
reject a program on a guess.

The refusal cannot read a sidecar file, because its own failure prevents that
file from being written. The typed-sidecar producer's projection budget
therefore does not enter into it. On the commit above, the concatenated program
that `tests/stdlib/benchmark-report-codec/check.sh` builds checks `ok`. With
`--emit-typed-sidecar` it fails with `ETS04`, because it declares 103 top-level
functions and the producer projects at most 64. The refusal applies to that
program as to any other that compiles.

### Ordering after #1711

The refusal is implemented only after #1711 merges. Until then, a function that
passes an `io` function by name is published `pure`. On the commit above,
`main` in the program above is published `pure` and prints `7`. A discarded
call to such a function, such as `quiet(7)` in #1711's own reproducer, would
be refused although it prints. #1711 also makes "names a top-level function" in
condition 3 the same edge that the published fact charges.

### Must-use is deferred

This section does not refuse discarding a `Result` or `Validated` from an `io`
call, which Flix does with `@MustUse`. Must-use is deferred to #1729. When it
is taken up, it starts from a compiler-known set of types, not a
user-declared attribute. Stage 2 has no `Result` runtime yet, and DD-036's `?`
is the primary consumer.

`spec/effects/validation-accumulation.md` (DD-034) already lists *"a
`Validated` result dropped without observing its state"* as a must-use refusal
condition of its own first implementation. This section does not amend that
text. The overlap is recorded on #1729.

### Open conflicts

These are recorded here, not resolved. Each needs the decision owner's answer
before the refusal is enabled, and #1730 carries both.

**Mutation through a borrow.** The decision rests on a discarded `pure` call
being deletable without changing what the program does. In this profile `pure`
means only that a function cannot reach `print`. It says nothing about a write
through an `edit` parameter, which DD-006 and `spec/bytes-bounded-v1.md` § 3
admit. Measured on the commit above:

```kofun
fn put(edit buffer: Bytes, at: Int, value: Int) -> Int {
    stage2_bytes_byte_set(buffer, at, value)
    return 0
}

fn main() -> Int {
    let buffer = stage2_bytes_empty()
    stage2_bytes_assign_zeroed(buffer, 2)
    put(buffer, 1, 42)
    print(stage2_bytes_byte_at(buffer, 1))
    return 0
}
```

The sidecar publishes `put` as `pure`, status `validated`. Its result is `Int`,
and its arguments are a local and two literals. All three conditions hold, so
the rule as accepted refuses `put(buffer, 1, 42)`. Yet `bin/kofun run` prints
`42`, and deleting the statement would leave the byte at `0`. Tracked sources
have the same shape: `codec_put16(ends, at * 2, end)` in
`tests/stdlib/benchmark-report-codec/codec.kofun`, and `edit_relay(spare)` in
`tests/conformance/bytes-mutation/borrowed_carrier.kofun`.

**A discard that can be written only once per scope.** As measured above,
`let _ = e` binds the name `_`. A scope can therefore use the sanctioned
spelling once. A second discarded result in the same scope needs a distinct
name: `let _second = twice(4)` after `let _ = twice(21)` checks `ok` on the
commit above. Making `_` non-binding in `let` would change what `return _`
means today, and the decision does not address that.
