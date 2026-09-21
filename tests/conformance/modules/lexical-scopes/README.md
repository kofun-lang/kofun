# Executable lexical scopes

`run.sh` fixes the Stage 2 Core lexical-scope contract at an executable
boundary. The positive fixture combines nested `if`, guarded Bool `match`,
payload-free enum `match`, shadowing, outer reads, and assignment to an outer
`let mut`. Its generated C must use `BindingId` storage rather than source
spellings, and its scope HIR has an exact deterministic golden.

Negative fixtures cover direct and nested self-reference, sibling/child escape,
use before declaration, unknown nested names, cross-function isolation, and an
enum-constructor/local-name collision with `E2S35`. Assignment through a child
scope still preserves `E2S22` for an immutable or unknown target.

Three of them exist because the others share a shape that is narrower than the
rule. `sibling_leak` and `enum_constructor_scope_escape` both declare at depth
one and read at depth zero, so a resolver that popped exactly one level on `}`
would pass both. `nested_scope_escape` declares at depth two and reads at depth
one, which that resolver cannot survive. `loop_body_escape` and
`loop_bound_escape` cover the scopes a loop introduces — a `while` body binding
read after the loop, and a `for` bound read after its body — because a resolver
that gave `if` a scope and a loop none would otherwise pass every other
negative here.

The bounded resolver accepts at most 32 lexical levels, 256 scopes, 256
bindings, and 4096 binding uses per function. `run.sh` exercises every accepted
boundary and its first rejected value. The use budget is the one that differs,
and it is a budget on time rather than a capacity: `bootstrap/stage2/compiler.c`
says beside `use_count` why it is 4096 and what a use costs (#1483). That cost
is visible here — the two use cases take about 40 seconds between them where
the other six boundary cases take about one — and it is the price of exercising
the boundary the compiler actually enforces rather than a cheaper one it does
not. It also recompiles identical source from
a remapped path and requires byte-identical C, token tape, and scope HIR.

Run `sh tests/conformance/modules/lexical-scopes/run.sh`.
