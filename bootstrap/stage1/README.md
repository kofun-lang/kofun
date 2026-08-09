# Python-free Stage 1 seed

`compiler.kofun` is the canonical source. `compiler.c` is its checked-in,
auditable bootstrap seed. A host C11 compiler is enough to build and run this
Kofun-written compiler.

Two things here are deliberately written twice, and
[`DD-022`](../../docs/DESIGN_DECISIONS.md) says why they must stay that way: the
`compiler.kofun`/`compiler.c` pair, and the `valid_source`/`emit_statements`
walks. Both are differential evidence — sharing either derivation would leave
its gate passing while proving nothing.

```sh
sh bootstrap/stage1/check.sh
```

Stage 1 accepts the documented Int/Bool/Text/List[Text] Core:

```text
kofun-stage1 INPUT.kofun OUTPUT.c
```

The compatibility parser requires one explicit line-oriented `fn main() {`
body containing only `let` statements, `print(...)` and `write_text(...)`
statements, `if`/`else if`/`else` blocks, and `while`/`for` loops, plus blank
lines and comments. `let` may infer or explicitly name `Int`, `Bool`, `Text`,
or `List[Text]`; `print(...)` accepts `Int` and `Text`. Unknown structural
lines are rejected; they are never ignored while extracting an otherwise
valid `print`.

## Expressions are compiled, not deferred

Each expression is tokenized, parsed by precedence, name-resolved and
range-checked *by this compiler*, then lowered to a C11 statement sequence over
checked Int64, Text, and List[Text] helpers. The emitted program contains no
parser or symbol table and no expression source beyond the Text literals the
program executes — the earlier seed passed each expression's source to an
`evaluate()` interpreter that it emitted verbatim from string literals, which
meant arithmetic, precedence, name lookup and overflow checking all happened at
the emitted program's runtime.

One C statement is emitted per operator, into a temporary named after that
operator's path from the root of the expression. That is what makes evaluation
order observable and fixed: C leaves the order of function arguments
unspecified, so a nested call tree would let the host C compiler decide which
of two failing operators reports its diagnostic first.

Because names are resolved here, these are now compile errors rather than
runtime traps in the emitted program:

- a reference to a name that is not bound, including one whose block has closed
- a second `let` for a name already visible (the language rejects shadowing)
- a binding named `true` or `false` (the Bool literals are reserved)
- an explicit annotation other than the inferred `Int`, `Bool`, `Text`, or
  `List[Text]`
- an integer literal outside the Int64 range
- `/`, which is not defined on Int (#687); `//` is the integer quotient
- arithmetic or ordered comparisons with a `Bool` or `Text` operand
- `&&`, `||`, or `!` with an `Int` operand
- the non-Core single-character `|` or `&` operators
- a `Bool` passed to the `Int`/`Text` `print` boundary
- a `Text`/`Int` `+`, `==`, or `!=` in either operand order
- an index whose receiver is not `Text` or `List[Text]`, or whose index is not
  `Int`
- `len` applied to a value other than `Text` or `List[Text]`, or `chars`
  applied to a value other than `Text`
- any profile builtin with the wrong arity or argument type, including a
  value-returning use of the `Void` builtin `write_text`
- a Text escape other than `\n`, `\"`, or `\\`
- a block condition that is not `Bool`
- an `else` with no `if` to attach to, or a second `else` in one chain
- a block left open at the end of the source, or a `}` that closes nothing
- a `while` condition that is not `Bool`, or a range end that is not `Int`
- a `for` bound name that shadows a visible binding, or a range written without
  the spaced `..` separator

The six Int comparisons produce `Bool`; `==` and `!=` additionally compare two
Bool or two Text operands. `+` concatenates two Text operands and remains
checked addition for two Int operands. `&&` and `||` short-circuit their right
operands, and `!` has unary precedence. The compiler tracks each local as
`Int`, `Bool`, `Text`, or `List[Text]` before emission, so no representation
crossing is accepted merely because C could express it. List equality is not
part of this Core.

## Text is a typed emitted-runtime value

A Text literal retains only its C-compatible literal bytes after `\n`, `\"`,
and `\\` have been validated. Operator, quote, and parenthesis scanners carry
string/escape state, so bytes such as `(+ || ==)` inside a literal never become
syntax.

Only a program that uses Text or List[Text] receives `<stdlib.h>`, `<string.h>`,
`kofun_rt_text_concat`, and `kofun_rt_text_equal`; the pre-existing arithmetic,
Bool, branch, loop, and non-indexing Text C goldens therefore stay
byte-identical. Concatenation allocates one flexible-array node per result,
links it into a program-local allocation list, checks every size addition, and
registers one cleanup with `atexit` before execution. Literal-only programs use
the same runtime boundary without allocating.

## List[Text] and indexing are byte-oriented

`chars(TEXT)` is this slice's one List[Text] constructor, and
`len(TEXT_OR_LIST)` returns its byte/item length. A postfix `BASE[INDEX]`
accepts a `Text` or `List[Text]` base and an `Int` index, returning one-byte
`Text`. `chars` and direct Text indexing deliberately follow the existing
Stage 2 profile's UTF-8 byte semantics: `len(chars("k字n"))` is `5`, not `3`.

The list representation is a length plus an immutable Text pointer array.
Programs using it receive a conditional flexible-array allocation list and one
`atexit` cleanup. Negative or too-large indexes exit 1 with the stable
`error[R010]` Text/List bounds diagnostic; invalid receiver/index types are
compile-time refusals.

## The frozen profile builtins are typed

Stage 1 accepts the 15 builtins used by its own frozen source:
`args`, `chars`, `contains`, `find`, `is_digit`, `is_space`,
`is_xid_continue`, `len`, `print`, `read_text`, `starts_with`, `text_slice`,
`trim`, `validate_unicode_source`, and `write_text`. Calls have exact arity and
typed arguments; their results are `Int`, `Bool`, `Text`, `List[Text]`, or
`Void`. Arguments lower once, left to right, before the runtime call.

Only programs using this extended host surface receive its conditional runtime,
`<ctype.h>`, and `#include "kofun_unicode.c"`; compile those emitted programs
with the repository's `unicode/` directory on the include path. The Unicode
shim uses the real Unicode tables. The Stage 1 compiler process retains
its historical non-ASCII `is_xid_continue` approximation, so the seed
differential deliberately tests that predicate with ASCII while separately
linking and executing real Unicode source validation.

The line-oriented Core still declares only `fn main()`. `Text` and `List[Text]`
are first-class binding/expression types and their C representations are fixed
for later parameter/result work. Non-main declarations — including Text/List
parameters and results — remain #751 rather than being accepted as untyped
special cases here.

`-9223372036854775808` still compiles: a negated decimal literal is folded at
compile time, so the one magnitude with no positive counterpart keeps a C
spelling.

## Blocks nest, and their bindings leave scope

`if COND {`, `} else if COND {`, `} else {` and `}` each occupy their own line.
Both structural walks keep one stack of open blocks, so the depth they agree on
is the stack's length rather than a separate counter, and an `else` is accepted
only when the block it closes is a branch no `else` has followed yet. A `let`
inside a block is visible until that block's `}`, after which its name is free
again — the scope stack lives in the same text as the bindings, so leaving a
block truncates back to the marker its `{` pushed.

Each Kofun block becomes exactly one C branch brace, and each `}` closes exactly
one, so an `else if` chain never leaves the closing line counting braces. A
chain also gets one enclosing C scope holding the flag that says an earlier
branch already ran; that flag is what keeps a later `else if` condition
unevaluated, exactly as `&&` and `||` keep their right operands unevaluated.

Nothing in the accepted Core returns a value yet, so `main` has no path that
must end in `return`; the per-branch `returned` state arrives with the
declaration slice that introduces `return` (#751).

## Loops nest with branches, on one stack

`while COND {` and `for NAME in START .. END {` each occupy their own line and
join the same stack of open blocks, so a loop and a branch nest inside each
other without either keeping a second counter. Only an `if` block admits an
`else`, so a `}` that closes a loop can never have one attached to it.

A `while` condition is re-evaluated every iteration. C cannot hold the
condition's statement sequence in its `while` header, so the loop is emitted as
`while (true)` with the condition lowered as the first statements of the body
and a `break` when it is false. That keeps one evaluation per iteration rather
than the two a duplicated condition would cost.

A `for` range is evaluated once, into the enclosing scope, before the loop
starts: re-evaluating the end per iteration would let a failing end expression
report its diagnostic more than once and would make the trip count depend on the
body. The range is half-open, and both ends must be `Int`. The bound name is an
ordinary immutable binding — it may not shadow a visible one, it is confined to
the loop body's scope, and the same name is free to bind again after the loop's
`}`.

The Core has no assignment statement yet, so nothing can write to a loop bound;
a line that tries is refused as an unknown structural line rather than by a
mutability rule. `corpus_reject_loop_assignment.kofun` pins that refusal so the
mutable-local slice cannot make a loop bound assignable by accident.

This file is the canonical `S` of the self-host chain: `task
selfhost-self-compile` proves the seed accepts every construct in it, and
`task selfhost-fixed-point` closed the three-generation gate on it —
`C2 == C3` and `A2 == A3` byte for byte. That fixed point covers this frozen
profile, not the full language; independent reproduction (B6) and diverse
double compilation (B7) are the remaining bootstrap tracks.
