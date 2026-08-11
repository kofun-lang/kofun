# Stage 2 aggregate bridge

This corpus is one vertical proof of the bounded C11 path already delivered by
#891, #919, #1103, #1181, #1183, and #1197. `bridge.kofun` constructs a nominal
`BridgeReport` with `Text`, capacity-64 `List[Int]`, and `Int` fields; passes
and returns the whole record; reads every field; takes `len`; indexes with the
checked list path; prints a non-ASCII identity; and proves that reading the
list field produces a value copy rather than a view into the record.

`run.sh` lowers that source once, builds the emitted program with
`-std=c11 -O2 -Wall -Wextra -Werror -pedantic`, and requires two executions to
match the single committed `bridge.stdout` byte for byte. It deliberately does
not call `bin/kofun run` as an independent interpreter: `run` and `build` share
the same Stage 2 C11 route. The independent evidence is the committed output
bytes and `spec/aggregate-layout-v1/layout.mjs`, which computes the focused
`layout.json` descriptor before `check-layout.mjs` joins every field offset and
the record size to the emitted `_Static_assert` values.

The complete non-authoritative typed sidecar is emitted through the public
`kofun check --emit-typed-sidecar` path and validated against v1. The frozen
Stage 2 semantic-event producer has no field-selector node kind. The sidecar
therefore proves only what it actually publishes here: the nominal `TypeId`,
the exact function types, copy-typed `BridgeReport` parameters, resolved
`BindingId` edges for their typed base-name references, and concrete
`BridgeReport`, `Text`, `List[Int]`, and `Int` type occurrences. It does not
identify any base reference as a field use or say which field was selected.

`check-production-field-access.mjs` owns the separate cross-artifact boundary.
It labels the three `report.field` strings as raw source-syntax witnesses, not
semantic facts, then requires the production emitted C functions to read the
corresponding `.f_identity`, `.f_samples`, and `.f_count` members. The strict
C11 executable must still reproduce the exact UTF-8 golden twice. A
comment/string-aware brace scan confines every member read to its own accessor
body; constant-return, string/comment-decoy, and later-`main`-only mutations
prove that another occurrence cannot satisfy it. Thus the sidecar gate and the
production field-access/runtime gate support distinct claims; a source grep is
never promoted into typed-sidecar evidence.

Two refusal inputs are reused from their owning gates:

- `tests/stage2/list-int-values/oversized.kofun` is the exact capacity-65
  boundary;
- `tests/conformance/records/stage2_unsupported_field.kofun` is the exact
  `List[Text]` record-field boundary.

`nested_record_list.kofun` adds the missing named nested path: its inner record
contains an otherwise admitted `List[Int]`, but a field of that named record
type remains outside the lowering slice. All three refusals require status 1,
their exact committed diagnostic, and no C artifact. The capacity refusal is a
backend-lowering boundary, so the existing compiler intentionally retains its
already-committed typed-HIR and token analysis artifacts; this gate does not
misreport those frontend artifacts as absent.

Finally, `check-capability-truth.mjs` keeps the general list and Text profiles
`unsupported` while requiring their notes to enumerate this bounded slice.
Four structurally valid mutations prove that both old false denials and both
accidental promotions are rejected.

Run the focused gate with:

```sh
task aggregate-bridge
```
