# Type system

## Design target

This section is the target, not a description of the compiler. The Kofun type
system is designed around two entry points.

1. Beginners can write local programs without annotations.
2. Advanced users can use ADTs, traits, effects, row polymorphism, and
   type-level computation.

Code that does not use the hard type features does not pay for their
complexity.

**What the active compiler does today is narrower than either line.** ADTs,
traits, and effects exist as bounded slices; row polymorphism and type-level
computation have no implementation at all. Each section below states its own
boundary, and
[the implemented-status matrix](https://kofun-lang.github.io/kofun/docs/implemented-status/)
is the authority for what is claimed. Reading this page as a feature list is
the misreading it is written to prevent.

## Primitive types

```text
Bool
Int
Float
Decimal
Complex
Text
Bytes
Null
Void
Never
```

`String` may be provided as an alias, but the canonical name is `Text`.

## Optional types

```kofun
let age: Int? = null
let safe_age = age ?? 0
```

Rules:

- `null` can only be assigned to `T?`
- no implicit null injection into `T`
- no implicit conversion from `T?` to `T`
- narrowing happens through `??`, pattern matching, or guards

### Narrowing direct bindings

A narrowing refinement is a fact about one edge of the control-flow graph. It
does not change the binding's declared type, it does not survive its function,
and it never becomes part of an inferred signature. `x` stays `Optional(T)`
everywhere the declaration is read; only a *use* on a refined edge is typed as
`T`.

Recognized conditions, and only these:

| Condition | Refined edge |
|---|---|
| `x != null` | true |
| `null != x` | true |
| `x == null` | false |
| `null == x` | false |

Either of those as the condition of an `if` whose taken branch definitely
returns is an early-return guard: the opposite edge's refinement continues past
the guard.

```kofun
fn describe(x: Int?) -> Int {
    if x == null {
        return 0
    }
    return x + 1        # x is Int here
}
```

`x` must be a direct local binding — a parameter or a `let` — whose declared
type is `Optional(T)`, and the comparison must not be overloaded. Any other
condition is still a legal `Bool`; it simply refines nothing, and a use of `x`
as `T` under it stays an error.

Invalidation. The rule when anything is uncertain is to discard, never to
assume:

| Event | Effect on the refinement |
|---|---|
| sibling branch | never sees it; each edge has its own environment |
| control-flow join | merged by intersection |
| `x = value` | discarded, after `value` is checked against the declared `Optional(T)` |
| mutable `x` passed to an `edit`/`own`/unknown-effect call | discarded after the call |
| immutable `let x` passed to a call | retained; it can be neither reassigned nor mutably aliased |
| loop backedge | discards every refinement that is not loop-invariant |

Not recognized, and refused rather than guessed at: compound boolean
conditions, property and index paths, aliases (`let y = x` refines `y` alone),
captured variables, interprocedural summaries, `match`, safe navigation,
truthiness, user-defined equality, and general union narrowing. Narrowing
chooses no runtime representation.

**Implementation status:** the analysis lives in
`bootstrap/stage2/optional_frontend.c`, gated by
`tests/conformance/optional-narrowing/run.sh` and
`tests/fuzz/optional_narrowing.sh`.

`Optional(Int)` is additionally **executable** through the Stage 2 C11 path
(#924): present and absent values are constructed under the AggregateLayout v1
`Optional[Int]` descriptor — explicit `tag_width` 1 at `tag_offset` 0 and an
`Int` payload at offset 8, never a niche — they cross a same-typed argument and
return with the tag intact, and each of the four recognized shapes plus the
definitely-returning guard is lowered so the narrowed use runs. That slice is
gated by `tests/conformance/optional-construction/run.sh`.

Two bounds of the executable slice, stated so the claim is not read wider than
it is. Every `Int?` binding it lowers is immutable — `let mut x: Int?` is
refused — so the invalidation rules that need mutation are refused at the
declaration rather than at the use; the frontend, which does admit a mutable
`Int?`, still pins them. And no other optional type is executable: `Int?` is
the whole backend claim.

The Stage 2 C11 path also executes the bounded coalescing form
`Optional(Int) ?? Int -> Int` (#314). The left is evaluated once; its explicit
tag selects either the present payload or a lazily evaluated fallback. The form
works in let, print, return, and function-argument position, and checked errors
propagate only from the selected evaluation. Parentheses are transparent around
the exact binding/call/null left shapes; arithmetic binds inside the fallback
and comparison remains outside the complete coalescing expression. The
executable contract and its
strict C11/determinism checks live in
`tests/conformance/optional-coalescing/run.sh`.

Generic optional payloads, chained `??`, `?` propagation, safe navigation,
Optional `match`, and every form of extraction remain unimplemented, and no
force-unwrap operator exists.

Planned pattern:

```kofun
match user.name {
    null => "anonymous"
    name => name
}
```

Separate constructors named `None` or `Nil` are not used for the optional case. Domain-specific ADTs may use any constructor name.

## Type inference

```kofun
let count = 42          # Int
let ratio = 0.5         # Decimal, not Float: see `docs/DECIMAL.md`
let binary = 0.5f64     # Float
let names = ["a", "b"] # List[Text]
```

Inference covers:

- local bindings
- return types
- lambda parameters when a call context exists
- generic arguments
- effects
- optional branch joins

For public APIs, annotations are recommended for stability and documentation.

## Callable types

Every callable has a fixed, exact arity. The canonical forms are:

```kofun
Int -> Text
(Int, Text) -> Bool
() -> Int
Int -> (Text -> Bool)
Tuple[Int, Text] -> Bool
```

`A -> R` is unary, `(A, B) -> R` is binary, and `() -> R` is nullary.
`A -> (B -> R)` is a unary callable whose result is another callable.
`Tuple[A, B] -> R` is also unary: its one argument is a tuple. These types are
distinct, and the type checker performs no implicit currying, partial
application, curry/uncurry conversion, or tuple/parameter-list conversion.

The callable type of a declaration follows its written parameter list
exactly:

```kofun
fn add(left: Int, right: Int) -> Int
# callable type: (Int, Int) -> Int
```

Calling `add(1)` is therefore an arity error. Partial application is written
explicitly with a function value.

`->` is the lowest-precedence type operator and associates to the right.
`A -> B?` parses as `A -> (B?)`, while `(A -> B)?` is an optional callable.
Writing `A -> (B -> R)` makes the callable-valued result explicit; it is not
equivalent to `(A, B) -> R`.

Parameter ownership modes participate in callable type identity:

```kofun
read File -> Metadata
(edit Buffer, take Request) -> Response
```

An omitted mode is value mode. Parameter names are documentation at the
declaration and are excluded from callable type identity in v1.

The historical `Fn[...]` form is removed rather than kept as an alias.
Migration diagnostics must provide a targeted fix from `Fn[A, R]` to
`A -> R` and from historical multi-argument forms to `(A, B, ...) -> R`.
Once migrated, `Fn` is an ordinary identifier. Function declarations retain
`->` before the result type; a bare Go-style result type is rejected.

## Numeric conversion

Planned rules:

- there are no implicit numeric conversions in either direction; a mixed-type
  arithmetic expression is a type error rather than a promotion
- one operator set is resolved per operand type, so there is no separate `+.`
  family for fractional values
- mixing a fractional type with `Int` in one expression is a type error —
  `Int + Float` does not promote
- `Int // Int -> Int`, taking the floor of the quotient
- the overflow mode is not changed implicitly between debug and release; it is stated explicitly in the build profile

`Int / Int` is a compile error today: `/` is not defined on `Int`, because with
no promotion it cannot produce a fractional value from two `Int` operands. It is
left without a meaning rather than given the truncating one, so it can be
defined later without silently changing any expression that compiles now.

`Decimal` and `Float` are distinct checker and lowering types. Literals and
`let` bindings carry them, annotations are checked against them, and mixing two
numeric types in one operator is a type error. The Stage 2 C11 backend lowers
exact Decimal `+`, `-`, `*`, comparison/equality, checked exact `/`, and the
binary64 Float counterparts. Its bounded member surface also lowers
`Decimal.round(value, scale, mode)`, `Decimal.divide(left, right, scale, mode)`,
`Decimal.format(value, display_scale)`, and `Decimal.parse(text)`. A rounding
scale or mode cannot be omitted, and formatting never rounds. Other declared backends refuse the
`decimal-arithmetic` capability explicitly rather than changing values.

So `let x: Float = 0.5` is rejected because `0.5` is a `Decimal` and there is
no implicit conversion to `Float`; `let x: Float = 0.5f64` lowers as binary64.
`Decimal / Decimal` produces the checked `DecimalResult`, while `Float / Float`
keeps binary64 division. `/` remains undefined on `Int`.

```kofun
let exact = 7 // 2 # 3
let floor = -7 // 2 # -4, the floor rather than the truncation
# let ratio = 7 / 2 # compile error: `/` is not defined on Int
```

## Generics

Square brackets are used instead of angle brackets.

```kofun
fn identity[T](value: T) -> T = value

type Pair[A, B] = {
    first: A,
    second: B,
}
```

Reasons:

- it reduces lexer ambiguity with comparison operators
- `List[Int]` is readable to Python and TypeScript users as well
- type application and indexing can be distinguished by parser context

Executable checkpoint: the separate Stage 2 generic-function frontend
type-checks explicitly instantiated, unbounded direct calls such as
`identity[Int](42)`. It assigns each declaration-scoped type parameter a
stable identity, substitutes explicit type arguments before checking value
arguments, and preserves the original declaration identity and source spans
in typed IR. The checkpoint does not infer omitted arguments, accept generic
nominal types or bounds, select trait dictionaries, monomorphize, or emit
backend code; see `tests/conformance/generics/README.md`.

Integer const generics: a nominal record may be declared
`type Fixed[const scale: Int]` and written `Fixed[2]` in a declaration or an
annotation, on the ordinary compile path as well as in a second bounded Stage 2
frontend. The literal is normalized by value, giving each instantiation its own
identity: `Fixed[2]` and `Fixed[3]` are different types, `Fixed[02]` is the same
type as `Fixed[2]`, and a mismatch is refused at compile time. A const parameter
is not a type and not a value: it may not be a field type or an expression, so it
cannot be erased into a runtime field, and it propagates no ownership kind, so
every instantiation of one declaration classifies identically while staying a
distinct type. The ordinary compile path specializes per distinct literal:
`Fixed[2]` and `Fixed[3]` reach different emitted structs, so a const generic
value can be constructed and run, and collapsing two identities onto one struct
is refused with `E2S153`. A record field typed by an instantiation is
separately refused, so a const argument never reaches layout. Const
expressions, const inference,
const parameters on functions, arithmetic on type-level values, ordinary type
parameters on a nominal record, construction of a const generic value, and
per-literal specialization on any backend all remain unimplemented; see
`tests/conformance/const-generics/README.md`.

## Algebraic data types

```kofun
type Tree[T] =
    | Empty
    | Node(value: T, left: Tree[T], right: Tree[T])
```

Pattern matching:

```kofun
fn size[T](tree: Tree[T]) -> Int {
    return match tree {
        Empty => 0
        Node(_, left, right) => 1 + size(left) + size(right)
    }
}
```

The compiler checks exhaustiveness and unreachable patterns.

Executable checkpoints: Stage 2 performs this check for bounded statement-
position and Int-valued `Bool` matches over `true`, `false`, and `_`, including
ordered Bool guards with conservative unguarded coverage. It also executes
concrete zero/one-`Int`-payload enum declarations, explicitly typed local
constructor bindings, same-typed function arguments/results, and exhaustive
statement-position enum matches with payload and catch-all bindings. See
`spec/bool-match-exhaustiveness.md` and
`spec/enum-match-exhaustiveness.md`. Generic enums, wider or nested payload
patterns, ownership-aware destructuring, and general arm-type unification
remain planned.

A separate typed-only Stage 2 checkpoint now accepts one bounded payload
surface before layout and matching are implemented:

```kofun
type MaybeInt =
    | Missing
    | Present(value: Int)

fn present() -> MaybeInt {
    return Present(42)
}
```

It supports non-generic top-level ADTs with at least two constructors, where a
constructor has zero fields or exactly one named `Int` field. All constructors
are collected before function bodies are resolved, and typed IR records
nominal ADT/constructor identities plus declaration and use spans. The
checkpoint emits no runtime layout or backend code and does not add payload
patterns or exhaustiveness; see `tests/conformance/adt/README.md`.

The separate top-level declaration-table checkpoint assigns these bounded ADT
types and constructors production module-scoped `SymbolId` values alongside
functions. It proves namespace separation and declaration-order independence,
but still performs only same-module lookup; imports and cross-module calls are
the next module-resolution slice.

## Records

Nominal record:

```kofun
type User = {
    id: Int,
    name: Text,
}

let user = User(id: 1, name: "ada")
let name = user.name
```

`type Name = { ... }` is the only record declaration and `Name(field: value)`
is the only construction form. Identity is nominal, so a second record with the
same field names and types is a different type. Fields are immutable in v1,
`take` moves a whole record, and partial moves are rejected. Layout is untagged
and follows declaration order.
[`spec/records-v1.md`](../spec/records-v1.md) is normative and
`task records` is its gate.

Structural record boundary:

```kofun
fn render(user: { name: Text, ..R }) -> Text
```

Row polymorphism is useful for JSON, web APIs, data frames, and testing doubles, but nominal types are preferred for layout-sensitive system APIs.

Byte layout for flat records, flat ADT variants, `Text`, and `List` is not a
property of the type system: it is decided per target by
[`spec/aggregate-layout-v1.md`](../spec/aggregate-layout-v1.md). Fields keep
declaration order, ADT tags follow constructor declaration order from zero,
and `Optional[T]` carries an explicit tag — no backend may apply a niche
optimization. Source semantics stay target-independent; only the computed
bytes differ between `x86_64-linux` and `wasm32`.

## Union and intersection types

The expressiveness of TypeScript is adopted, but uncontrolled union explosion is avoided.

```kofun
type Input = Text | Bytes
```

Main uses:

- external data boundaries
- gradual migration
- generated API bindings
- pattern narrowing

For internal domain models, ADTs are recommended.

Intersection types are restricted to limited uses such as capability composition.

## Traits

```kofun
trait Eq[T] {
    fn equals(read left: T, read right: T) -> Bool
}

trait Iterator[I, Item] {
    fn next(edit iterator: I) -> Item?
}
```

`trait` is the only public keyword for this abstraction. It describes a
compile-time contract and statically selected dictionary, not a runtime
interface or message-dispatch object. `protocol` and `interface` are not
aliases.

### Coherence and orphan rule

For an implementation of the form:

```kofun
impl Trait[Arguments] for SelfType {
    # methods
}
```

the implementing package must own either the trait or the outer nominal type
constructor of `SelfType`.

Ownership is based on stable declaration identity:

- a package owns a trait only when it declares that trait;
- a package owns a type only when it declares its outer nominal constructor;
- importing or re-exporting a declaration does not transfer ownership;
- a type alias does not create ownership;
- primitive types and imported C or Rust ABI types are foreign; and
- a locally declared nominal wrapper is local, even when its field or generic
  argument is foreign.

Generic arguments do not decide ownership. If the current package declares
`LocalBox[T]`, then `LocalBox[foreign.Handle]` is local because its outer
nominal constructor is `LocalBox`.

The resulting matrix is:

| Trait | Outer nominal type | Result |
| --- | --- | --- |
| local | local | accepted |
| local | foreign | accepted |
| foreign | local | accepted |
| foreign | foreign | rejected; introduce a local nominal wrapper |

A fully resolved trait/self tuple has at most one applicable implementation
across the complete dependency graph. Duplicate or overlapping candidates are
compile errors when declarations or dependency interfaces are combined.
Lexical order, import order, link order, and runtime state never choose a
winner.

M2-alpha rejects blanket implementations, negative implementations,
specialization, and ordered fallback. These forms must fail explicitly rather
than acquire provisional precedence. A later specialization design must be
versioned, preserve coherent dictionary identity, and leave programs with no
specialization semantically unchanged.

### What the frontend implements today

`bootstrap/stage2/traits_frontend.c` implements the rules above as a frontend
and nothing more. It is bounded to one-method traits with one type parameter,
concrete implementations, and generic functions carrying exactly one explicit
non-recursive bound. Within that shape it assigns `TraitId`, `MethodId`, and
`ImplementationId`, checks method signatures after substitution, enforces the
orphan matrix and the overlap rule exactly as written, and records the selected
implementation in typed IR. `sh tests/conformance/traits/run.sh` is the
evidence.

The typed IR also carries the elaborated dictionary shape (#923): a
`dictionary-descriptor` per trait giving the ABI schema version and one
`MethodId` per slot in declaration order; a `dictionary` per admissible
implementation whose `DictionaryId` is the `ImplementationId` with the `impl:`
tag replaced and the `/decl=N` ordinal dropped, so it is the coherence key and
is unchanged by declaration order; a `dictionary-parameter` per declared bound;
and an explicit dictionary argument at each bounded call. A trait method call
inside a generic body resolves to a (dictionary parameter, method slot) pair.

The boundary is that **the dictionary is elaborated but not lowered: nothing is
monomorphised, no vtable is laid out, and no runtime search is emitted or
implied**. The frontend names the dictionary a bounded call passes; it does not
execute it, and it emits no backend artifact. Backend execution of the
elaborated dictionary is a separate follow-up, and #256 carries the generic law
propositions.

Overlap is refused where implementations are declared rather than where they
are used, so no candidate set is ever ordered at a use site. The gate asserts
this rather than claiming it: it compiles the same program with every
implementation declared in the opposite order and requires each call to select
the same trait and self-type.

Forms outside the bounded shape — blanket and generic implementations, default
methods, a second bound, more than one trait type parameter, and a bound whose
argument is not the bounded parameter — fail explicitly with their own
diagnostics rather than being silently accepted or ignored.

### Visibility and exported APIs

M2-alpha has no private, package-local, or lexical `impl` candidate. An
accepted implementation participates in dependency-graph coherence; hiding it
cannot create local precedence.

An exported signature may mention only public traits and public nominal types
under the normal visibility rules. A trait bound is part of that signature,
not an implementation detail. An implementation absent from the
consumer-visible semantic interface cannot satisfy a consumer's bound or
change how the consumer type-checks an exported API.

Visibility does not cause runtime implementation lookup. The compiler selects
one implementation from validated semantic interfaces and passes its
statically shaped dictionary.

### Worked examples

These examples state the design contract; traits are not yet accepted by the
active compiler.

```kofun
# This package owns Printable, so a foreign type may implement it.
trait Printable[T] {
    fn print_value(read value: T) -> Text
}

impl Printable[dependency.Widget] for dependency.Widget {
    # accepted: local trait
}

# This package owns LocalWidget, so it may implement a foreign trait.
type LocalWidget = {
    value: dependency.Widget,
}

impl dependency.Hash[LocalWidget] for LocalWidget {
    # accepted: local outer nominal type
}
```

The following direct implementation is rejected because both identities are
foreign:

```kofun
impl dependency.Hash[ffi.Handle] for ffi.Handle {
    # error: foreign trait for foreign type
}
```

The remedy is a local nominal wrapper, not an alias:

```kofun
type LocalHandle = {
    raw: ffi.Handle,
}

impl dependency.Hash[LocalHandle] for LocalHandle {
    # accepted: LocalHandle is local
}
```

If the trait-owning package and the type-owning package both publish an
implementation for the same fully resolved tuple, a consumer that combines
those interfaces reports overlap. Reordering the imports cannot select either
candidate.

### Implementation and law evidence identity

The selected dictionary is keyed by a stable `ImplementationId`. Its semantic
identity covers the implementing package, trait identity and canonical
arguments, canonical self type including its outer nominal identity and
arguments, implementation declaration/binders/constraints, and coherence
mode. The dictionary ABI version is carried with that identity in compiler
artifacts and cache keys. Source location, source order, import order, and
discovery order do not participate.

Trait declarations own their laws. Evidence for those laws is stored in a
separate versioned artifact and names the exact selected
`ImplementationId`. `LawEvidenceId` also commits to the law declaration,
evidence contract version, quantified type arguments, and semantic evidence
digest. Evidence for one implementation cannot be reused for a different
implementation merely because the surface types or method bodies look equal.
The assurance levels `bounded-exhaustive`, `proven-finite`, and `proven`
remain distinct.

Planned trait capabilities include generic traits, associated types, default
methods, and auto traits for send/share/copy. They do not weaken the coherence
rules above. The first implementation slice remains the concrete,
non-overlapping frontend described in
[`../spec/roadmap-31-34/generics-and-traits.md`](../spec/roadmap-31-34/generics-and-traits.md).

## Effects

Ordinary function syntax is kept, while the effect row is inferred.

Conceptual types:

```text
Text -> User
Path -> User ! {io, error[FsError]}
Url -> User ! {async, io, error[HttpError]}
```

Effect annotations do not have to be written every time in source. They can be stated explicitly for public APIs, trait contracts, and no-effect guarantees.

```kofun
pure fn normalize(value: Float) -> Float
```

Whether to adopt the `pure` keyword will be decided after evaluating effect inference and diagnostic UX.

## Result and error propagation

```kofun
fn load_user(path: Path) -> Result[User, LoadError] {
    let text = File.read_text(path)?
    return Json.decode[User](text)?
}
```

The parser resolves the contextual conflict between `?` and the optional suffix.

Errors can be carried as a type parameter, and the API for adding context is standardized.

## Ownership in types

Parameter modes are expressed as a call contract, not as a type constructor.

```kofun
fn hash(read bytes: Bytes) -> Digest
fn fill(edit buffer: Buffer) -> Void
fn submit(take request: Request) -> Response
```

This reduces the notational load of `&T`, `&mut T`, and explicit lifetimes.

Advanced APIs can expose view lifetimes at the type level, but standard user code does not see them.

## Const generics and shapes

```kofun
fn dot[N](left: Array[Float, N], right: Array[Float, N]) -> Float
```

For N-dimensional arrays, the rank and some shapes are treated as compile-time values.

Dynamic shapes remain first class as well.

```kofun
Array[Float, rank = 2]
DynArray[Float]
```

## Type-level functions

Kofun has selected a deliberately bounded v1 profile, specified normatively in
[`type-level-programming-v1.md`](../spec/type-level-programming-v1.md). This is
a design target, not an implemented compiler feature: the active compiler does
not parse, kind-check, reduce, or emit traces for `type fn`.

```kofun
type fn Flatten[T: Type] -> Type {
    match T {
        List[item] => Flatten[item]
        _ => T
    }
}
```

The selected profile permits only:

- non-recursive transparent aliases and nominal constructor application;
- module-level named `type fn` declarations whose explicit parameter and
  result kinds are `Type`;
- exhaustive matches with non-overlapping nominal constructor heads, bound
  variables, and at most one final residual `_` fallback;
- an acyclic inter-function call graph; and
- direct self-recursion only on a strict matched subterm.

It rejects anonymous conditional and mapped types, `infer` chains,
template-literal types, type lambdas, higher-kinded parameters, implicit union
distribution, recursive aliases, mutual/general recursion, effects, value
reflection, and type-level string computation. Trait, law, refinement, const,
shape, and associated-type solving remain separate features rather than hidden
steps in this evaluator.

`kofun.type-reduction/default-v1` fixes the root-reduction budget at 32 active
frames, 256 logical reduction steps, and 256 constructed logical type nodes.
Programs cannot raise those limits. Exceeding a limit is a deterministic type
error, never silent acceptance as `Any`, an unknown type, or a partial result.

Every future implementation must produce the versioned
`kofun.type-reduction-trace/v1` artifact and pass its
[schema](../spec/type-reduction-trace/kofun.type-reduction-trace.v1.schema.json)
and [vector gate](../spec/type-reduction-trace/). Ordinary output keeps named
forms and is capped at 4,096 UTF-8 bytes; normal diagnostics show at most eight
trace frames. The complete structured trace retains at most 256 records and
4 MiB, while `kofun type explain` text is capped at 64 KiB with an exact
omitted-step count. `kofun type eval`, `kofun type explain`, LSP one-step
expansion, and an interactive debugger must consume the same logical trace
rather than scrape expanded diagnostic text.

## Current implementation

Implemented:

- `Int`, `Float`, `Bool`, `Text`, `Null`, `Void`, `Any`
- `List[T]`, Tuple
- `T?`
- basic function types
- local inference
- numeric promotion
- branch/list joins
- part of the built-in polymorphic behavior
- `read` / `edit` / `take` parameter metadata

Not implemented:

- typed law-family, law-implementation, and law-check declarations
- compiler-integrated finite-model law evaluation and evidence emission
- active assurance checking for `bounded-exhaustive` or `proven-finite`
- user-defined generics
- ADTs, match
- traits
- union/intersection
- row polymorphism
- effect rows
- const generics
- type-level functions
- principal-type guarantee
- higher-kinded types and lawful traits
- generic proof terms and trusted proof kernel

Historical `law monad` examples and v1 JSON artifacts document an earlier
bounded prototype, but the active CLI rejects that syntax. The accepted
concrete-first replacement is documented in
[`LAW_SYSTEM.md`](LAW_SYSTEM.md); its parser, evaluator, and v2 evidence
emitter remain unimplemented and do not require higher-kinded types.
