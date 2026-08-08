# Stage 2 `List[Int]` values

This focused gate owns issue #919's local-value slice. It proves that both an
explicit `List[Int]` annotation and an inferred integer-list literal reach the
scope HIR, lower to one AggregateLayout v1 reference addressing an exact-size
`u64 length` plus `Int` payload object, execute `len`, and perform positive,
negative, and dynamic checked index reads.

The capacity is 64 elements. A larger literal, a non-`Int` element or index,
an out-of-range literal index, a mutable list, and any local list annotation
other than exactly `List[Int]` fail compilation with `E2S157` and no C
artifact. A dynamic out-of-range index exits 1 with `R023` before printing.
Direct top-level `List[Int]` parameters and results are covered by the
separate `tests/stage2/list-int-signatures` gate. This local-value gate keeps
the argument fixture that proves a list still cannot cross an `Int` parameter
as an `E2S15` mismatch.

The executable observation is compared with the independent native Core C11
reference, and two different absolute source directories must produce
byte-identical generated C, typed HIR, and token tapes.

The gate recomputes the x86-64 AggregateLayout descriptor, joins its offsets
and widths to the emitted C, then moves the payload offset by one descriptor
element and requires the emitted `_Static_assert` to reject the drift. The
layout claim is therefore a checked join, not a comment or copied constant.

Run:

```sh
sh tests/stage2/list-int-values/run.sh
```
