# Stage 2 `List[Int]` function signatures

This focused gate owns #1103, increment 3 of #868. It extends the existing
immutable, 64-element `List[Int]` local-value slice across direct top-level C11
function parameters and results without claiming general list lowering.

Function ABIs use a fixed `KofunIntListValue` structure passed and returned by
value. A local literal is copied once from the existing AggregateLayout view
into that carrier; passing and returning the carrier then copies its checked
length and initialized `Int` elements. No list pointer crosses the function
ABI, and the slice introduces no heap allocation, mutation, destructor, or
ownership transfer.

Calls with a `List[Int]` parameter reserve typed argument slots at function
scope. A comma expression assigns every list and companion `Int` argument once
in written source order before invoking the declaration-order C ABI. The
positive fixture makes that ordering observable and then passes the returned
carrier through a second function. #1113 gives direct and labelled calls one
`kofun_call_arg_<call-byte>_<slot>` namespace, one emitter, and one function-
body temporary walker; `mixed_call_shapes.kofun` exercises both modes in the
same function.

The gate covers empty, one-element, and exactly-64-element pass/return values,
`len`, checked positive/negative/dynamic indexing, strict C11 under GCC and
Clang when available, sanitizers, supported static analysis, repetition, and
absolute-path remapping. Refusals keep deterministic parsed IR and token tapes
but publish no C.

Scope IR v1 records `List[Int]` parameter bindings and returned whole-value
bindings. It has no function-result type field; the declared result position
is instead pinned by the canonical compiler-pair checks and the generated
`KofunIntListValue` C prototype.

Direct list-literal arguments/returns, mutable lists, `List[Text]`, nested or
general lists, indirect calls, lambdas, record fields, and non-C11 backends
remain explicit boundaries. Labelled list calls are no longer among them:
#1107 widened the labelled fixed-slot lowering to `Text` and `List[Int]`, so
`labelled_argument.kofun` is an accept case here. The general
`c11-stage2/list` capability therefore remains unsupported until #868's later
record-field increments land.

The shared predicate keeps the two mode boundaries explicit. Labelled calls
use the current call-slot carrier vocabulary (`Int`, `Text`, `List[Int]`,
`Int?`, concrete enums, and nominal records); direct calls remain restricted
to `Int`/`List[Int]` parameters with at least one list. Accordingly,
`positional_text_list.kofun` remains on the ordinary positional call path and
this refactor does not widen it into fixed-slot sequencing. The predicate also
keeps no direct return-carrier guard, while the complete compiler still rejects
the `List[Int] -> Bool` shape earlier as `E2S15`, pinned by
`direct_bool_result.kofun`. That structural distinction is not a shipped
Bool-result capability.

Lambda-contained `List[Int]` annotations, literals, binding reads, carrier
calls, and direct results (including transparent parentheses) fail closed with
exact `E2S157` and no generated C because
lifted parameters, captures, and results still use the scalar ABI. Explicit
`read`, `edit`, and `take` parameter modes are likewise outside this immutable
copy-only increment.

Run:

```sh
task list-int-signatures
```
