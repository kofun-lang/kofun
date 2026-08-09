# Call arguments

This gate owns the accepted declaration/call surface, the checked-HIR fixed
slot binding, and the first executable backend slice.

`source_order_int.kofun` deliberately writes `as_second` before `as_first`.
Each value calls `observe`, so its golden distinguishes source evaluation
order (`2`, then `1`) from declaration/ABI order; the final `12` proves the
ordinary ABI vector is still `(left, right)`. The Stage 2 C11 emitter stores
each expression once in a function-local `int64_t` temporary through the C11
comma operator before making the declaration-order call.

The executable slice is intentionally limited to direct top-level functions
whose parameters and result are `Int`, `Text`, or `List[Int]` — the carriers
the positional path already executes. `source_order_carriers.kofun` mixes all
three in one call written out of declaration order: the markers `1` and `3`
print before the callee body's `42`, proving source-order exactly-once
evaluation.

Each slot is also asserted to be reserved with its own C carrier. A carrier
regression would already fail the strict `-Werror` build of the generated C,
but as an opaque diagnostic inside emitted code; these assertions name the
defect instead. They share one call-site key read out of slot 0, so they
describe a single call rather than three unrelated sites.

Optional and enum/record carriers, ownership-bearing values, pipeline
subjects, the trailing-lambda form, labelled calls inside lifted lambdas, and
direct-native/Wasm lowering retain E2S158 and remain owned by #882.

`shadowed_callable.kofun` keeps lexical resolution load-bearing: a callable
parameter named like a supported top-level function must not be redirected to
that top-level ABI. The bounded slice refuses it before C emission.

`lifted_lambda_call.kofun` pins a second function-scope boundary. Lifted
lambdas become separate generated C functions, so this slice refuses a
labelled call in their body rather than declaring its temporaries in the
enclosing source function.
