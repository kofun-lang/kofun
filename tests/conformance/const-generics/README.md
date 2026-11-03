# Integer const generics: literal `Int` type arguments

This focused Stage 2 checkpoint (#916) delivers the smallest integer const
generic capability a type can be parameterized by, so `Scaled[scale]` has a
type-level scale for #725 Part B to build on. It does not implement `Fixed`
decimal semantics, and it does not change what `docs/DECIMAL.md` says about
the `runtime-scale/v1` interim profile.

A nominal record declares at most one parameter. On the ordinary compile path
it must be a `const` parameter of type `Int`; the bounded frontend also models
an ordinary type parameter, which is what gives the kind-mismatch diagnostics
something to be a mismatch against.

```kofun
type Scaled[const scale: Int] = {
    significand: Int,
}

type Boxed[T] = {          # bounded frontend only; the product path refuses it
    value: T,
}
```

## What a literal argument means

- **Identity is by value.** `Scaled[2]` and `Scaled[3]` are different types;
  `Scaled[02]` is the same type as `Scaled[2]` and folds into the same
  monomorphization. A mismatch between two instantiations is a compile-time
  error, not a coercion.
- **A const argument normalizes into its own namespace.** The identity of an
  instantiation is `nominal:Scaled/args=const:Int:2`, where a type argument
  would give `args=builtin:Int` or `args=nominal:Money`. The tags are
  disjoint, so a const argument can never be mistaken for a type argument by
  anything that embeds a normalized argument — including the `args=`
  component #936's `ImplementationId` is assembled from, and the
  `DictionaryId` derived from it by dropping only the declaration ordinal.
- **A const parameter is not a value.** It cannot be a field type and cannot
  appear in an expression, so a const parameter can never be silently erased
  into a runtime field the way a stored scale field would be.
- **A const parameter is not a type.** It carries no ownership kind, so
  RFC-0004's K-SUBST substitutes nothing through it and K-PARAM does not
  classify it. Every instantiation of one declaration classifies identically
  while remaining a distinct type. An ordinary type parameter still
  propagates its argument's kind, and the IR records which of the two each
  parameter is.

## Two paths, one surface

A frontend-only fact does not complete #916, so the capability is reachable
through the compiler the CLI actually runs as well as through the bounded
frontend, and `cases/positive.kofun` is accepted by **both**.

The ordinary compile path is `bootstrap/stage2/compiler.{kofun,c}` under
`--compile-outcome`, which is what `kofun check` and `kofun build` invoke. It
accepts a `[const NAME: Int]` parameter list and carries the normalized
argument in the annotation's type text, so `Scaled[2]` and `Scaled[3]` never
compare equal and a scale mismatch is refused with `E2S151`.

**It specializes per distinct literal.** `Scaled[2]` and `Scaled[3]` reach two
different emitted C structs, `KofunRecord_Scaled__2` and `KofunRecord_Scaled__3`,
so the C type system keeps apart exactly what the Kofun type system keeps
apart. A const generic value can be constructed, passed, returned, and run.

`validate_struct_identity` is the gate on that. Distinct type identities must
reach distinct emitted structs; a collapse is refused with `E2S153` before any
C is written. An earlier revision of this work dropped the const argument on
the way to the struct name and justified it in a comment — a const parameter
carries no storage, so one shared struct was argued to be safe. That was a
true statement about *miscompiles* standing in for an unexamined one about
*identity* and about what `capabilities.tsv` was claiming. The gate now
observes the proposition that failed, and `run.sh` falsifies it by collapsing
the specialization deliberately and requiring the refusal.

`validate_const_erasure` remains as a separate, narrower guard: a const
argument must never reach *layout*, so a record field typed by an
instantiation is refused. Keeping both is deliberate — they are different
propositions, and conflating them is what let the shared struct ship.

## Layout

- `expectations.kofun` and `fixed_scale_instantiation.kofun` are the backend
  capability corpus, and the #725 Part B handoff: two scales constructed, kept
  apart by the type system, and observed at runtime. `c11-stage2` is
  `supported` for it in `tests/conformance/capabilities.tsv` and executes it;
  `c11-stage1`, both native backends, and `wasm32-node` record `unsupported`
  with their own reasons. `run.sh` holds every backend to its row, and refuses
  a `supported` claim from any backend it has not proved specialization for.
- `cases/` is the frontend corpus. `positive.kofun` is the shared positive,
  accepted by the bounded frontend and by the product path.
  `frontend_surface.kofun` is the wider surface only the bounded frontend
  models — an ordinary type parameter, a `Scaled[2]` field, a `Text` field —
  and `run.sh` pins the product path's refusal of it rather than assuming it.
  Both carry byte-exact `.ir` goldens. The negative fixtures freeze the
  const-parameter-as-field-type, const-parameter-as-value, non-`Int` const
  parameter, multiple-parameter, non-literal, negative, out-of-range, both
  kind-mismatch directions, missing and excess argument,
  argument-on-plain-type, annotation and argument scale mismatch, and
  one-over-limit diagnostics. Each refusal leaves neither typed IR nor a token
  tape behind.
- `product/` holds the same refusals as the ordinary compile path sees them,
  with byte-exact goldens. `scale_mismatch.kofun` is the erasure sentinel: an
  annotation reader that returns only the head token makes `Scaled[3]` and
  `Scaled[2]` one type, so that source would compile and every other check
  would stay green. `const_argument_reaches_layout.kofun` falsifies the layout
  premise. `struct_identity_collision.kofun` falsifies the identity premise
  from source, by declaring a record whose own name is the C name an
  instantiation generates.

The bounded frontend remains typed-only: it performs no const evaluation,
const inference, monomorphization, lowering, layout, or execution. The product
path specializes per literal on the C11 Stage 2 backend only; no other backend
does, and each says so.

Run `sh tests/conformance/const-generics/run.sh`.
