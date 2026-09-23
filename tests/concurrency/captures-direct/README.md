# Checked lexical direct captures

Run `node tests/concurrency/captures-direct/check.mjs`. The gate exercises the
public `--emit-capture-hir-v2 INPUT OUTPUT LOGICAL-PATH` entry and the canonical
Kofun `emit_capture_hir_v2_file` function with the same three Text arguments.
It requires the production entry to exist; ordinary compiler acceptance or
the lifecycle-only entry does not stand in for capture checking.

`cases.json` contains whole authored sources, literal UTF-8 byte spans,
resolver ordinals and operation expectations. Those ordinals follow scoped
capture specification §§11–12: function parameters, par tokens, lambda
parameters, ordinary declarations/pattern bindings, then hidden spawn handles.
They are not copied from generated compiler output. The enum-pattern case
uses the capture entry's resolved-pattern mode; the older lifecycle and
selected-place interfaces retain their own candidate-preservation behavior.

`oracle.mjs` independently frames FileId, ScopeId, BindingId, nominal owner
TypeId, lifecycle/analysis NodeIds, ParId, TaskId, JoinId, KPL/PlaceId,
KUN/UnknownId and CaptureId with Node crypto. It substitutes authored source
facts into those preimages, merges exact targets by read < edit < take,
deduplicates and source-orders origins, and sorts complete record phases.
It imports no compiler or reference-model implementation. The gate then
compares its complete document against `buildScopeHir` and validates the
actual production document against the accepted model.

The source corpus covers:

- Repeated reads, assignment/RHS read-edit merging, genuine nominal-record
  read-to-take calls, and distinct whole/field/field-path targets.
- Task-local/shadow/enum-payload exclusions, nested callable lexical union,
  invocation without duplicated origins, both branches and lexical loops.
- Enclosing callable reads, callable shadowing, reordered labelled formal
  modes, and permitted edit-scalar temporary operands that remain reads.
- External and local slice/index receivers with independent bound/RHS reads;
  indexing remains an occurrence-specific unknown. Local depth-nine bases
  are excluded before unknown creation.
- Known depths8, explicit unknown depths9/64 and refused65; eight dynamic
  slices produce the full574-byte KPL; exact signed-i64 and empty slices.
- UTF-8/grouped target spans, 128/129-byte display behavior,64/65 captures,
  256/257 observations, and64/65 tasks across separate pars.
- Initializer/assignment/condition/call type and syntax failures, local-only
  invalid bodies, partial/borrowed takes, possible moves across branches,
  and outer moves in loops. Fresh loop-local moves and never-invoked nested
  moves have positive controls.

The smaller positive corpus runs through strict C11 O0/O2, ASan/UBSan and
canonical Kofun file entries, with repeated complete-byte equality checks.
Refusals must agree across implementations, leave an absent destination
absent and preserve an existing sentinel byte-for-byte. Unicode, malformed
source and logical-path refusals exercise the same publication boundary.
`KOFUN_STAGE2_COMPILER` optionally adds an independently supplied production
binary; it never replaces the freshly built O0/O2/sanitized binaries.

The full cardinality source is generated from the closed dimensions in
`cases.json` without adding tracked `.kofun` files: two functions,32 pars per
function, one task per par and64 distinct checked indexed accesses per task.
Independent arithmetic requires64 pars,64 tasks,64 joins,4,096 unknowns and
4,096 captures, exactly8,384 records with unique IDs. Splitting functions
keeps each inherited lexical-use budget below4,096. This expensive boundary
runs once in C O0 and once in canonical Kofun; the smaller boundaries already
cover optimization, repetition and sanitizers. The gate prints its measured
duration rather than silently skipping or truncating it.

`--oracle-only` validates the authored expectations and full-cardinality
model without compiling or invoking production. It explicitly reports that
production output was not tested, and is useful while integrating a new
committed producer. It is not the lasting production gate's success result.

This child covers checked lexical direct captures. Same-unit nonlexical call
summary propagation belongs to #1223; conflict checking, runtime execution
and real KSE2 source production remain separate children.
