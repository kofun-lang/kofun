# Expressions and literals

Status: normative language-design contract for issues 48 through 59.

This document fixes the intended full-language surface and semantics. It does
not imply that every construct is accepted by the current bootstrap compiler.
The implementation status in each section is part of the contract: a compiler
MUST reject an unsupported construct rather than silently reinterpret it.

The words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative.

## Shared evaluation rules

- Subexpressions evaluate from left to right unless a section explicitly says
  that an operand is conditional.
- Every syntactic subexpression evaluates at most once.
- Delimited lists MAY have one trailing comma.
- Whitespace and line comments MAY appear between tokens.
- A sign is a unary operator, not part of a numeric literal.
- Examples marked `valid` define canonical accepted forms. Examples marked
  `invalid` MUST be rejected by a complete parser or checker.

## Issue 48: range expressions

### User stories and non-goals

Users need a compact, end-exclusive sequence for loops, indexing algorithms,
and finite collection construction:

```kofun
for index in 0 .. len(values) {
    print(values[index])
}
```

Users should be able to recognize the stopping condition without remembering a
special library name. Range construction must evaluate each bound once.

This design does not add inclusive ranges, open-ended ranges, non-integer
bounds, a configurable step, slicing, or implicit materialization as a List.
Those may be specified separately. In particular, `..=` is reserved and is
not accepted by this contract.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Rust `start..end` | Familiar end-exclusive spelling and a first-class range value | Rust also has open and inclusive variants; copying all variants would expand the bootstrap grammar prematurely |
| Python `range(start, end)` | Explicit constructor and mature step semantics | Function syntax obscures the common loop boundary and permits dynamic behavior not intended for a core syntactic form |
| Haskell `[start..end]` | Concise enumeration | The upper bound is inclusive and the notation materializes a list, both of which conflict with Kofun loop conventions |
| Swift `start..<end` | Visually explicit exclusion | A distinct `<` suffix is noisier than the already documented Kofun `..` convention |

Kofun selects Rust-like spelling, Python-like end exclusion, and lazy
range-value semantics.

### Normative semantics and syntax

The canonical grammar is:

```text
range-expression = additive-expression, [ "..", additive-expression ]
```

Both operands MUST have type `Int`. `start .. end` evaluates `start`, then
`end`, exactly once and produces a finite `Range[Int]` containing each integer
`x` such that `start <= x < end`, in increasing order with implicit step one.
It is empty when `start >= end`. Constructing a range MUST NOT allocate a List.
Iteration count is `max(end - start, 0)` computed without overflowing signed
`Int`; an implementation may compare the current value to `end` rather than
forming that subtraction.

`..` binds less tightly than additive operators and more tightly than
comparison operators. It is non-associative.

Valid:

```kofun
0 .. 10
start + 1 .. finish - 1
for index in 0 .. len(values) { print(index) }
```

Invalid:

```kofun
0 ..= 10       # inclusive syntax is not specified
0 .. 10 .. 20  # chained ranges are ambiguous
0.0 .. 1.0     # only Int bounds are specified
.. 10          # no open start
```

### Current status

The Stage 0 draft grammar and semantic note describe `..` and an exclusive
upper bound. The current Stage 2 token scanner recognizes `..`, but its
executable integer Core does not parse or lower range values or `for`.
AST/HIR, static typing, diagnostics, backends, and tooling for this contract
remain open.

## Issue 49: pipeline operator

### User stories and non-goals

Users need to read a transformation in data-flow order and split it over
several lines without nested calls:

```kofun
values
    |> filter(is_ready)
    |> map(render)
    |> join(", ")
```

The design must keep ordinary call signatures and evaluate the piped value
once. It does not add placeholders, implicit currying, method lookup, async
awaiting, error propagation, or a second “pipe into last argument” operator.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Elixir `value |> call(args)` | Simple rewrite into the first call argument | Macro-driven and language-specific expansion rules are not copied |
| F# `value |> function` | Clear unary composition and left-to-right reading | A curried-call model would not fit Kofun's ordinary multi-argument calls |
| R `value |> call()` | Standard first-argument flow | Placeholder and environment rules vary by R generation and are deliberately excluded |
| Hack `value |> $$ + 1` | Arbitrary right-hand expressions | A magic placeholder increases scope and makes repeated evaluation easier to misunderstand |

Kofun uses an Elixir-style first-argument rewrite without macro expansion or
placeholder syntax.

### Normative semantics and syntax

Canonical rewrites are:

```text
value |> function          => function(value)
value |> function(a, b)    => function(value, a, b)
value |> module.function() => module.function(value)
```

The left operand is evaluated first and exactly once. The callee expression is
then evaluated, followed by the explicit arguments from left to right. The
temporary left value is passed as argument zero. Ownership mode checking
applies exactly as it would to that explicit first argument.

The right operand MUST be a callable name/member expression or a call whose
callee is such an expression. A pipeline chain associates left-to-right.
`|>` has the lowest expression precedence in this document; `??` therefore
binds within either pipeline operand.

Valid:

```kofun
source |> parse
source |> parse(mode)
source |> parse |> validate |> emit(target)
maybe ?? fallback |> consume
```

The last example means `(maybe ?? fallback) |> consume`.

Invalid:

```kofun
source |> 1 + 2       # right side is not a callable form
source |> fn(x) => x  # parenthesize or bind a lambda before piping
source | > consume    # the operator is one token
```

### Current status

The Stage 0 draft grammar and design decision DD-011 record the full `|>`
language and its first-argument rewrite. Stage 2/C11 now parses, type-checks,
and lowers the bounded one-stage `subject |> callee(arguments)` subset when
`callee` is a direct top-level function in the current carrier matrix: the
subject binds slot zero, counts toward effective arity, is checked against that
slot, and observes the bounded bare-binding `take` rule; fixed-slot C11
lowering evaluates it first and exactly once before explicit arguments in
source order. Bare/member targets, chains, pipeline-plus-trailing-lambda, and
the other full-language pipeline shapes remain open at their existing Stage 2
refusal boundaries. Direct-native/Wasm pipeline behavior is unclaimed and
uncovered by this C11 slice; #1192 owns its exact support-or-source-refusal
differential.

## Issue 50: null literal

### User stories and non-goals

Users need one unsurprising spelling for absence when an optional value is
expected:

```kofun
let port: Int? = null
```

APIs and data formats should not require aliases such as `nil` or `None`.
This design does not make every reference nullable, introduce truthiness, or
permit implicit conversion from `null` to a non-optional type.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Kotlin `null` with `T?` | Nullability is visible in the type | Platform types and Java interop escape hatches are outside this contract |
| Swift `nil` with `Optional<T>` | Absence is type-directed | A second spelling is unnecessary and less familiar to JavaScript users |
| Rust `None` | Explicit enum constructor and exhaustive matching | Constructor verbosity conflicts with the intended lightweight optional syntax |
| TypeScript `null` and `undefined` | Familiar web vocabulary | Two absence values and permissive widening are explicitly rejected |

Kofun chooses one `null` value and Kotlin-like optional typing.

### Normative semantics and syntax

`null` is a keyword and a primary expression. It denotes absence and has no
standalone non-optional type. Contextual typing MUST infer an expected `T?`;
otherwise the checker MUST request an annotation or another constraining
context. It MUST reject `null` where `T` is required.

`null` has no fields, methods, numeric conversion, or truth value. Equality of
two values already known to have the same optional type is true when both are
absent. `value ?? fallback` evaluates `fallback` only when `value` is absent.

Valid:

```kofun
let missing: Int? = null
let effective = missing ?? 42
```

Invalid:

```kofun
let answer: Int = null
let unknown = null       # no type constrains T
if null { print("yes") } # no truthiness
let legacy = nil         # nil is an identifier, not an absence literal
```

### Current status

The Stage 0 grammar and semantic draft contain `null`, optional values, and
coalescing. Stage 2 now contextually types `null` into `Optional(TypeId)`, and
the executable #924 slice constructs present and absent `Optional(Int)` values
with AggregateLayout v1, carries them through same-typed arguments and
returns, and narrows a direct immutable binding after a `null` comparison.
`??` coalescing remains an exact E2S147 refusal. Generic Optional payloads,
mutable refinement, propagation, safe navigation, matching, and force unwrap
remain outside this bounded backend slice.

## Issue 51: optional type suffix

### User stories and non-goals

Users need nullability to be visible next to the underlying type:

```kofun
fn lookup(key: Text) -> Value?
```

The common case should not require a generic wrapper spelling. This design
does not define arbitrary postfix type operators, nested optional layers,
implicit optional unwrapping, or nullable ownership views.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Kotlin `T?` | Compact and immediately visible | Flexible platform nullability is not copied |
| Swift `T?` / `T!` | Familiar suffix and optional chaining ecosystem | Implicitly unwrapped `T!` is unsafe and excluded |
| TypeScript `T | null` | Reuses general union types | Verbose common case and distributive-union complexity are avoided |
| Rust `Option<T>` | Uniform algebraic data type | Wrapper syntax is heavier for routine absence |

Kofun selects `T?` as syntax for one optional layer.

### Normative semantics and syntax

The canonical type grammar is:

```text
optional-type = primary-type, [ "?" ]
```

`T?` denotes exactly `T` or `null`. The suffix binds more tightly than any
future union/intersection type operator and applies to the complete preceding
primary type, so `List[Int]?` is an optional list. A List of optional integers
is `List[Int?]`.

`T??` is invalid; optional normalization and nested absence are not part of
this contract. `Void?` and an optional ownership mode such as `read File?`
require their own semantic design and MUST be rejected for now.

Valid:

```kofun
Int?
List[Int]?
List[Int?]
fn lookup(key: Text) -> User?
```

Invalid:

```kofun
Int??
?Int
Void?
```

### Current status

The Stage 0 grammar accepts one suffix and the semantic draft represents `T?`
as `T` or `Null`. The bounded Stage 2 frontend now represents one postfix `?`
structurally, including the distinction between `List[Int]?` and `List[Int?]`.
The executable #924 backend slice is narrower: it constructs and carries
`Optional(Int)` and narrows direct immutable bindings after a `null`
comparison. `??` coalescing remains an exact E2S147 refusal; generic Optional
payloads, nested optionals, mutable refinement, optional ownership modes, and
the other broader Optional features are not implemented by this slice.

## Issue 52: tuple literals

### User stories and non-goals

Users need a small heterogeneous product without declaring a named record,
especially for multiple results and short local pairings:

```kofun
let entry = ("answer", 42)
```

This design does not add named tuple fields, tuple comprehensions, implicit
flattening, a separate unit literal, or unlimited backend support.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Python `(a, b)` and `(a,)` | Familiar comma-based distinction from grouping | Dynamic tuple length and indexing do not determine Kofun typing |
| Rust `(A, B)` and `(a,)` | Statically typed heterogeneous product | The unit `()` is not adopted by this contract |
| Haskell `(a, b)` | Strong product typing and destructuring | Special tuple constructors and currying details are excluded |
| Gleam `#(a, b)` | Lexically unambiguous tuple marker | The extra `#` is unnecessary when comma rules suffice |

Kofun chooses parentheses with a mandatory comma to distinguish tuples from
grouping.

### Normative semantics and syntax

```text
group        = "(", expression, ")"
tuple        = "(", expression, ",",
               [ expression, { ",", expression }, [ "," ] ], ")"
```

Tuple elements evaluate left-to-right. `(value)` is grouping; `(value,)` is a
one-element tuple. A tuple's type records element types and arity, such as
`Tuple[Text, Int]`. Tuples are immutable values. An empty tuple is not defined
by this contract.

Valid:

```kofun
(1, 2)
("only",)
(first(), second(),)
(1 + 2) # group, not tuple
```

Invalid:

```kofun
()
(1 2)
(, 1)
```

### Current status

The Stage 0 grammar distinguishes grouping and tuple literals, though the
single-element/trailing-comma production needs conformance tightening. Stage
2 structurally scans delimiters but its executable Core accepts parentheses
only as grouping. Tuple type checking, evaluation, and lowering remain open.

## Issue 53: list literals

### User stories and non-goals

Users need concise ordered homogeneous data for everyday algorithms and
pipeline examples:

```kofun
let primes = [2, 3, 5, 7]
```

This contract does not add comprehensions, spread elements, sparse lists,
implicit element flattening, or a fixed-capacity array syntax.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| ML `[a, b]` | Familiar immutable functional collection | Cons-cell syntax and linked-list representation are not implied |
| Python `[a, b]` | Universally recognizable | Heterogeneous dynamic typing and eager comprehensions are excluded |
| Rust `vec![a, b]` | Makes allocation explicit | Macro punctuation is too heavy for Kofun's default collection |
| Gleam `[a, b]` | Homogeneous typed list and FP ergonomics | Its specific persistent representation is not mandated |

Kofun uses brackets for a homogeneous `List[T]` without specifying physical
representation.

### Normative semantics and syntax

```text
list = "[", [ expression, { ",", expression }, [ "," ] ], "]"
```

Elements evaluate left-to-right. Every element MUST be compatible with one
inferred element type `T`. An empty list needs an expected `List[T]` context
or explicit annotation. The literal creates an independent immutable List
value; mutability and capacity are separate APIs.

Valid:

```kofun
[1, 2, 3]
[compute(), reuse(),]
let empty: List[Int] = []
```

Invalid:

```kofun
let unknown = []  # no element type context
[1, "two"]        # no common element type in the baseline
[1,, 2]
```

### Current status

The Stage 0 grammar and language examples use list literals, and the bootstrap
runtime has a narrow `List[Text]` capability for compiler internals. The
current Stage 2 executable Core does not parse or lower general list literals.
Generic list inference, evaluation, and native support remain open.

## Issue 54: map literals

### User stories and non-goals

Users need readable key/value construction for counts, indexes, and structured
lookup:

```kofun
let counts = {"red": 2, "blue": 1}
```

This design does not merge map and record syntax, define comprehensions or
spread, accept duplicate keys silently, or promise insertion-order iteration.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Python `{key: value}` | Compact and familiar | Python's empty-map/set ambiguity is removed by explicit `set {}` |
| Rust `HashMap::from([(k, v)])` | Container and hashing are explicit | Constructor ceremony is excessive for a standard literal |
| JavaScript `{name: value}` | Excellent record ergonomics | Identifier-key shorthand would blur records and maps |
| Swift `[key: value]` | Statically typed dictionary | Brackets conflict visually with Kofun List literals |

Kofun selects brace-and-colon map entries and reserves record construction for
a leading type name.

### Normative semantics and syntax

```text
map = "{", [ expression, ":", expression,
            { ",", expression, ":", expression }, [ "," ] ], "}"
```

Map entries evaluate left-to-right, key before value. All keys MUST share a
hashable/equatable type `K`; all values MUST share a type `V`. A duplicate key
in one literal is a static error when equality is compile-time decidable and a
runtime construction error otherwise. It is never silently last-wins.
Iteration order is unspecified by this contract.

`{}` is the empty map literal. It requires an expected `Map[K, V]` context.
In expression position braces followed by colon-separated entries are a map;
statement blocks occur only where the enclosing grammar expects a block.

Valid:

```kofun
{"a": 1, "b": 2}
let empty: Map[Text, Int] = {}
{key(): value(),}
```

Invalid:

```kofun
{"a", 1}
{"a": 1, "a": 2}
{["mutable"]: 1} # List is not a baseline hashable key
```

### Current status

The older syntax guide labels this spelling as planned and unresolved. This
contract resolves the design choice, but neither the Stage 0 grammar nor
Stage 2 Core implements map literals. Parser, type, runtime, duplicate-key
diagnostic, and backend work remain open.

## Issue 55: numeric literals

### User stories and non-goals

Users need readable decimal integers and floating-point values with separators
for long magnitudes:

```kofun
let population = 8_100_000_000
let ratio = 0.125
```

The baseline does not add hexadecimal/binary/octal forms, suffixes, arbitrary
precision, imaginary values, decimal fixed point, hexadecimal floats, or
locale-sensitive separators.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Rust literals | Rich bases, separators, and typed suffixes | Suffix and base complexity is deferred |
| Python literals | Familiar underscores and decimal/float forms | Arbitrary-precision integer behavior conflicts with fixed `Int` |
| JavaScript Number/BigInt | Simple default plus explicit big integers | A trailing `n` and binary64-only number model are not adopted |
| Julia literals | Scientific syntax and scientific-computing familiarity | Numeric juxtaposition and extensive literal types are deferred |

Kofun starts with strict decimal `Int` and `Float` forms and separator rules
that can be checked lexically.

### Normative semantics and syntax

```text
digits       = digit, { [ "_" ], digit }
integer      = digits
float        = digits, ".", digits,
               [ ( "e" | "E" ), [ "+" | "-" ], digits ]
             | digits, ( "e" | "E" ), [ "+" | "-" ], digits
```

Underscores MUST occur only between decimal digits. They do not affect value.
Leading zeroes are allowed and have no octal meaning. A leading sign is unary
syntax. `Int` is checked against the signed 64-bit range after unary handling;
out-of-range literals MUST be rejected or produce the specified numeric
diagnostic, never wrap. `Float` conversion MUST use locale-independent decimal
syntax; exact IEEE representation and rounding are specified by the numeric
semantic contract, not by this surface section.

The lexer uses maximal munch, except `1..2` MUST tokenize as integer `1`,
range `..`, integer `2`, not as a malformed float.

Valid:

```kofun
0
9_223_372_036_854_775_807
3.1415
1e9
6.02e+23
-42 # unary minus plus integer literal
1..2
```

Invalid:

```kofun
_1
1_
1__0
1.
.5
0xFF
12kg
```

### Current status

The Stage 0 grammar names integer and float tokens and the numeric semantic
contract defines checked `Int`. Stage 2 tokenizes decimal digit/underscore
runs as integers and lowers a checked integer subset. It does not validate all
underscore placements and does not tokenize or lower Float/scientific forms.
Full lexical validation and Float conformance remain open.

## Issue 56: string interpolation

### User stories and non-goals

Users need to combine text and small values without manual concatenation:

```kofun
let message = "processed ${count} rows"
```

Interpolation must preserve expression evaluation order and source spans.
This design does not provide arbitrary format specifiers, shell expansion,
compile-time evaluation, implicit localization, multiline strings, or
interpolation in raw strings.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Kotlin `"value ${expr}"` | Clear braces and expression support | `$name` shorthand is excluded so one form covers all cases |
| Swift `"value \\(expr)"` | Delimiter nests naturally in strings | Backslash-heavy syntax is less readable next to escape sequences |
| JavaScript template literals | Multiline text and expressions | Backtick delimiters and tag execution add a second string system |
| Python f-strings | Powerful formatting and familiar braces | Prefixes, conversion flags, and format mini-language are deferred |

Kofun uses `${expression}` only inside ordinary double-quoted strings.

### Normative semantics and syntax

An unescaped `${` inside a string starts an interpolation. The matching `}`
is found using normal delimiter nesting while respecting nested strings and
comments in the expression. Empty interpolation is invalid. Literal text,
then each interpolation expression, evaluates left-to-right. Each expression
MUST be `Text` or a primitive with a canonical `to_text` conversion. The
result is one `Text`.

The sequence `\${` contributes literal `${` and starts no interpolation.
Ordinary string escape processing occurs before literal segments are joined,
but interpolation expressions are parsed as source rather than as escape
text.

Valid:

```kofun
"hello ${name}"
"${left + right}"
"literal \\${not_interpolated}"
"nested ${choose({\"a\": 1})}"
```

Invalid:

```kofun
"empty ${}"
"missing ${value"
"resource ${file}" # no canonical primitive Text conversion
```

### Current status

The design syntax appears in planned examples, but the Stage 0 grammar treats
a string as one opaque token and does not specify interpolation. Stage 2 also
scans the entire escaped double-quoted string as one token. No interpolation
AST, nested scanner, type conversion, evaluator, or lowering exists yet.

## Issue 57: set literals

### User stories and non-goals

Users need explicit construction of unique values without confusing it with
an empty map:

```kofun
let ids = set {10, 20, 30}
```

This design does not use bare braces for sets, promise iteration order, accept
unhashable elements, define mathematical set comprehensions, or silently
evaluate duplicate element expressions more than once.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Python `{a, b}` / `set()` | Concise non-empty form | `{}` means map and makes the empty spelling inconsistent |
| Rust `HashSet::from([a, b])` | Container choice is explicit | Constructor verbosity and implementation naming leak into source |
| Swift `Set([a, b])` | Type-directed and unambiguous | Nested delimiters are noisy for a standard collection |
| Clojure `#{a b}` | Distinct literal with no empty ambiguity | `#` already starts Kofun comments |

Kofun uses the keyword-led `set { ... }` form for both empty and non-empty
sets.

### Normative semantics and syntax

```text
set = "set", "{", [ expression, { ",", expression }, [ "," ] ], "}"
```

Elements evaluate left-to-right exactly once. All elements MUST share one
hashable/equatable type `T`. Duplicate values collapse to one member after
their expressions have been evaluated; this differs deliberately from map
duplicate keys because no value would be discarded. Iteration order is
unspecified.

An empty set requires an expected `Set[T]` context.

Valid:

```kofun
set {1, 2, 3}
set {compute(), compute(),}
let empty: Set[Text] = set {}
```

Invalid:

```kofun
{1, 2, 3}   # braces alone are not a set
set [1, 2]
set {[]}
```

### Current status

The older syntax guide labels `set { ... }` as planned. This contract settles
the surface and duplicate behavior, but no current grammar, parser, type
checker, runtime, or backend implements set literals.

## Issue 58: operator precedence

### User stories and non-goals

Users need one table that makes mixed expressions predictable and minimizes
parentheses in ordinary arithmetic, optional handling, and pipelines. Parser,
formatter, macro, and diagnostics work must share the same table.

This design does not allow user-defined precedence, operator declarations,
implicit multiplication, chained range construction, or comparison chaining.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| C-family precedence | Familiar arithmetic, comparison, and logical tiers | Bitwise tiers and assignment expressions are not copied |
| Python precedence | Clear power, arithmetic, comparison, and Boolean ordering | Python's chained-comparison semantics are excluded |
| Rust precedence | Strict typing and range operators | Rust ranges have several forms and special parsing contexts |
| F#/Elixir pipelines | Low-precedence data flow | Language-specific custom-operator precedence is excluded |

Kofun keeps conventional arithmetic at the top and puts coalescing and
pipeline near the bottom.

### Normative table

Rows are ordered from tightest binding to loosest:

| Tier | Forms | Associativity |
| --- | --- | --- |
| postfix | call `()`, member `.`, index `[]` | left |
| power | `**` | right |
| unary | prefix `!`, `+`, `-` | right |
| multiplicative | `*`, `/`, `//`, `%` | left |
| additive | `+`, `-` | left |
| range | `..` | non-associative |
| comparison | `<`, `<=`, `>`, `>=` | non-associative |
| equality | `==`, `!=` | non-associative |
| logical-and | `&&` | left, short-circuit |
| logical-or | `||` | left, short-circuit |
| coalescing | `??` | right, short-circuit |
| pipeline | `|>` | left |

Postfix binds tighter than power. Power binds tighter than unary, so `-2 ** 2`
means `-(2 ** 2)`. `2 ** -3` remains syntactically valid because the right
operand of power accepts unary syntax. Assignment is a statement form and is
not part of the expression precedence table.

Canonical interpretations:

```text
a + b * c          == a + (b * c)
-x ** 2            == -(x ** 2)
a ?? b |> consume  == (a ?? b) |> consume
a || b && c        == a || (b && c)
0 .. n + 1         == 0 .. (n + 1)
```

Valid:

```kofun
base ** exponent ** next
ready && present || fallback
(a < b) == expected
```

Invalid:

```kofun
a < b < c
a == b != c
0 .. 10 .. 20
```

### Current status

The Stage 0 EBNF has matching tiers except that it currently permits repeated
range/comparison/equality productions and places unary above power in a way
that needs reconciliation with this explicit `-2 ** 2` rule. Stage 2 Core has
an executable subset for parentheses, unary, multiplicative, and additive
operators; it has no complete shared precedence table for the other tiers.
Parser reconciliation, diagnostics, formatter behavior, and full conformance
remain open.

## Issue 59: comment syntax

### User stories and non-goals

Users need a line comment that is easy to type, survives formatting, and
cannot be confused with division:

```kofun
# explain why this branch is safe
```

Compiler and tooling authors need comments retained as source trivia even
when semantic stages ignore them. This baseline does not add documentation
comments, pragmas, shebang semantics, or block comments.

### Prior designs and tradeoffs

| Design | Useful property | Failure mode avoided or accepted |
| --- | --- | --- |
| Python/Ruby `#` | Visually light and familiar for scripting | A shebang exception is not specified |
| Rust/C `//` and `/* */` | Familiar systems-language convention | `//` is Kofun floor division, so line comments would be ambiguous |
| Haskell `--` and `{- -}` | Supports nested block comments | `--` conflicts visually with two subtraction operators |
| Lisp `;` | Simple line trivia | Semicolon remains an optional statement separator |

Kofun selects `#` line comments. Nested block comments remain reserved design
work and are not accepted by this baseline.

### Normative semantics and syntax

A `#` outside a string begins a comment at that byte and continues up to, but
not including, the next line-feed or end of file. Comment contents are trivia:
they produce no semantic token and cannot join tokens on either side. The
terminating line-feed remains a newline separator. `#` inside a string is
ordinary text.

Source-preserving syntax trees and formatters MUST retain the exact comment
bytes and their source span. Semantic trees MAY omit comment nodes after a
lossless syntax layer has taken ownership of the source. Comments MUST NOT
change runtime behavior.

Valid:

```kofun
# whole line
let answer = 42 # trailing
let marker = "# not a comment"
let sum = left + # explanation
    right
```

Invalid:

```kofun
/* block comments are not in the baseline */
// this is floor division, not a comment
```

### Current status

Both canonical Stage 2 sources skip `#` through line end and preserve the
original source during identity projection. The token tape intentionally
omits comments and other trivia. There is no lossless comment node, formatter
attachment model, block-comment scanner, recovery, or stable tooling API yet.

## Conformance and lifecycle evidence

The design fixture directory
`tests/conformance/syntax/issues_48_60/` inventories canonical valid and
invalid examples for issues 48 through 59. These fixtures are specification
evidence, not a claim that Stage 2 implements the forms. Its executable span
prototype covers the currently supported lexical subset and issue 60.

For issues 48 through 59, this document supplies evidence for these lifecycle
items only:

1. user stories and non-goals;
2. prior art and failure modes;
3. normative semantics;
4. surface syntax and ergonomics.

All later lifecycle items remain open unless separately implemented and
validated.
