# Kofun design status

## Active implementation

The active toolchain is the Kofun-written arithmetic compiler at
`bootstrap/stage1/compiler.kofun`. Its hash-pinned C11 seed starts the compiler
without a Python runtime. `bootstrap/stage1/check.sh` is the executable gate.
`bootstrap/stage2/` additionally owns bounded semantic checkpoints, including
the Copy/borrow rule below; these do not yet constitute a general type checker.

## Target language

The target design includes static typing, `read` / `edit` / `take` ownership,
ADTs, exhaustive matching, closures, collections, law checking, and native and
WebAssembly backends. These remain design work unless
`docs/MVP_IMPLEMENTED.md` and an executable Kofun test say otherwise.

Kofun source uses `.kofun`; legacy `.kf` files are rejected.

The semantic authority is `spec/semantics.md` plus the conformance corpus.
Unsupported behavior must be diagnosed or explicitly skipped, never silently
counted as passing.

## Decision: Copy elements from borrowed collections

Kofun chooses a type-directed Copy/non-Copy split. Iterating a named `read`
collection borrows its storage. An element may leave that borrow by value only
when its type is Copy; moving a non-Copy element is `E007`.

The initial Copy set is closed and compiler-defined:

| Type | Copy? | Borrowed iteration result |
|---|---:|---|
| `Int`, `Float`, `Bool`, `Unit` | yes | may be returned or otherwise copied |
| `Text`, `List[T]`, records, closures, resources | no | may be read; moving is `E007` |

Copy is not user-implementable in the initial language. This keeps copying
independent of user code, allocation, cleanup, and observable side effects.
Later tuple or record Copy inference requires a separate design decision; it
is not implied by every field being Copy today.

This selects candidate A from issue #29. Rust, Swift, Mojo, and Hylo use the
same essential type distinction, and the rule remains local: the element type
explains whether a value can leave borrowed storage. Candidate B—borrow when
the iterable is a name, own when it is a temporary—was rejected because a
small refactor of the iterable expression would silently change move
semantics. Ownership must not depend on distant expression shape.

The active Stage 2 checkpoint implements the first narrow executable slice:
an explicitly typed `read xs: List[T]`, `for x in xs`, and a same-line
`return` that contains `x`. It accepts Copy scalars and rejects a `Text` move
with `E007`. This is not yet the general type/ownership checker: nested control
flow, calls with `take` parameters, inferred collection types, and code
generation for collection iteration remain open and receive explicit
unsupported diagnostics rather than being counted as checked.
