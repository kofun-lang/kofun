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
- More than256 task-local reads remain outside the observation budget;
  local indexed receivers with256 enclosing index reads succeed, while257
  retained enclosing reads refuse. Local receivers produce no unknowns.
- Initializer/assignment/condition/call type and syntax failures, local-only
  invalid bodies, partial/borrowed takes, possible moves across branches,
  and outer moves in loops. Fresh loop-local moves and never-invoked nested
  moves have positive controls.

Partial/use-after-take, duplicate nested parameters and label/arity failures
assert their established E2S122/123/47/162/163/164 diagnostic classes. A valid
`print(combine(...))` counterpart prevents blanket nested-call refusal from
satisfying the labelled-call negative cases.

The smaller positive corpus runs through strict C11 O0/O2, ASan/UBSan and
canonical Kofun file entries, with repeated complete-byte equality checks.
Refusals must agree across implementations, leave an absent destination
absent and preserve an existing sentinel byte-for-byte. Unicode, malformed
source and logical-path refusals exercise the same publication boundary.
`KOFUN_STAGE2_COMPILER` optionally adds an independently supplied production
binary; it never replaces the freshly built O0/O2/sanitized binaries.

The full cardinality source is generated from the closed dimensions in
`cases.json` without adding tracked `.kofun` files:64 functions, one par per
function, one task per par and64 distinct checked indexed accesses per task.
Independent arithmetic requires64 pars,64 tasks,64 joins,4,096 unknowns and
4,096 captures, exactly8,384 records with unique IDs. Splitting functions
keeps each inherited lexical-use budget below4,096 and reduces the existing
resolver's quadratic per-function work without reducing the required
cardinality. This expensive boundary runs once in C O0 and once in canonical
Kofun; the smaller boundaries already cover optimization, repetition and
sanitizers. Only the full canonical case gets a dedicated subprocess so its
synchronous interpreter call can be bounded; the ordinary corpus reuses one
interpreter. A timeout fails the gate and indicates processing cost, not a
language-semantic refusal. The gate prints its measured duration rather than
silently skipping or truncating the source.
The full canonical child has a600-second wall-time budget; native subprocesses
retain120 seconds. These are explicit gate resource bounds, not changed
language limits, and a timeout is never a pass or a skipped comparison.

`--oracle-only` validates the authored expectations and full-cardinality
model without compiling or invoking production. It explicitly reports that
production output was not tested, and is useful while integrating a new
committed producer. It is not the lasting production gate's success result.

This child covers checked lexical direct captures. Same-unit nonlexical call
summary propagation belongs to #1223; conflict checking, runtime execution
and real KSE2 source production remain separate children.
