# Compiler-derived checked places

`task concurrency-places` exercises the maintained compiler pair's
`--emit-place-hir-v2 INPUT OUTPUT LOGICAL-PATH TASK-INDEX START END` entry.
The selected half-open UTF-8 range is inside one actual resolved task lambda.
The output extends the existing lifecycle document with one canonical known
place or explicit unknown. It does not collect captures or accept execution.

The test constructs expected lifecycle IDs from authored source spans and
resolver allocation numbers, nominal type IDs from the existing module/type
namespace/symbol TLV preimages, and place/unknown bytes independently with
Node crypto. Production IDs, projections and status are never oracle inputs.
It compares complete JSON against both canonical Kofun and maintained C,
strict C11 O0/O2, repeated calls and Clang ASan/UBSan. Original output bytes
must survive rejected selections, indices, types, ranges and provenance.

Nested owner transitions, shadowed bindings, field-display renames, exact
i64 extremes, normalized zero, dynamic arithmetic/call bounds, distinct equal
spelling occurrences, consecutive slices and projection depths 8/9/64/65 are
covered. Blocks in task lambdas permit the full candidate corpus without
expanding the ordinary compiler's bounded arrow-lambda grammar. The existing
`concurrency-hir` gate independently owns lifecycle syntax and provenance.

Analysis record declarations are bounded at 64 types and 64 fields each;
nested nominal fields are checked independently of the runtime's flat record
layout. Lists are the existing Int/Text carriers. Dynamic bounds require Int
from checked literals, local initializers, resolved places, parentheses,
arithmetic, or declared direct calls with checked argument types and arity.
Only well-typed unrepresentable candidates remain explicit unknowns. Missing
fields, invalid receivers, non-Int bounds and invalid local initializers are
diagnostics. Checked indexing stays unnameable and retains its resolved base
and element type internally; it never becomes a fabricated slice. Deep known
candidates likewise retain their checked base before public unknown projection.
The maximum eight-dynamic-slice source fixture checks all 574 KPL bytes.
No fallback
inference, display spelling or caller-supplied semantic ID can create a known
projection. These expression forms are an analysis profile, not new C/runtime
acceptance, an effect summary, or a promise to evaluate a bound.
