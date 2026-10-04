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
