# Bounded `pure` / `io` inference v1

Stage 2 infers one effect summary for every top-level function in a successful
bounded compilation unit. The lattice is exactly:

```text
pure < io
```

`print` is the only direct `io` root in this profile. A caller is `io` when it
can reach that root through the compiler's resolved top-level function-call
observations; otherwise it is `pure`. The monotone analysis computes the least
fixed point, so self-recursive and mutually recursive components without a
root stay `pure`, while a root makes every reaching caller `io`. Divergence and
panic remain `pure`: this summary does not claim termination or totality.

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

## The `pure fn` boundary

The inference above is a summary this slice computes; it decides nothing. #1245
adds the one source annotation `pure fn`, the spelling #1241 froze, which
requires that summary to be `pure` for the function it prefixes.

It introduces no effect semantics of its own. The lattice, the root, and the
least fixed point are the ones defined above; the boundary asks that same
question at compile time, before a semantic-event stream exists, and refuses
the program when the answer is `io` — naming the root reached directly, or the
first call in the body that carries it, as `E2S176`. Because the answer is one
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
