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
whose fixed parameter and result slots use `Int`, `Text`, `List[Int]`, `Int?`,
a concrete enum, or a nominal record carrier. `source_order_carriers.kofun`
mixes the first three in one call written out of declaration order:
the markers `1` and `3` print before the callee body's `42`, proving
source-order exactly-once evaluation. `source_order_wide.kofun` does the same
for `Int?`, enum, record, and `Int` slots in written order 3, 2, 0, 1 before
the declaration-order ABI vector 0, 1, 2, 3. `reordered_optional.kofun` pins
the Optional narrowing path independently.

Each slot is also asserted to be reserved with its own C carrier. A carrier
regression would already fail the strict `-Werror` build of the generated C,
but as an opaque diagnostic inside emitted code; these assertions name the
defect instead. They share one call-site key read out of slot 0, so they
describe a single call rather than three unrelated sites.

`owned_carrier.kofun` proves that a bare nominal-record binding passed to a
parameter declared `take` becomes one semantic move even though the C carrier
assignment is mechanically a copy. `double_move_carrier.kofun` pins the later
transfer to the existing exact E2S123 diagnostic. This is a source-order,
whole-binding increment, not general ownership inference or control-flow
analysis.

Pipeline subjects, the trailing-lambda form, labelled calls inside lifted
lambdas, indirect/lexical callees, and direct-native/Wasm lowering retain
E2S158 and remain owned by #882.

`shadowed_callable.kofun` keeps lexical resolution load-bearing: a callable
parameter named like a supported top-level function must not be redirected to
that top-level ABI. The bounded slice refuses it before C emission.

`lifted_lambda_call.kofun` pins a second function-scope boundary. Lifted
lambdas become separate generated C functions, so this slice refuses a
labelled call in their body rather than declaring its temporaries in the
enclosing source function.
