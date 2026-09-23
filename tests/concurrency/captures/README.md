# Checked complete task captures

`task concurrency-captures` exercises the maintained public C CLI
`--emit-complete-capture-hir-v2 INPUT OUTPUT LOGICAL-PATH` and canonical Kofun
`emit_complete_capture_hir_v2_file`. The source profile is specified in
`spec/concurrency/scoped-captures-v1.md` §14. This is an analysis entry; the
programs containing cyclic calls or scoped tasks are never executed.

The 52 positive fixtures contain complete authored source, resolver ordinals,
literal byte spans, formal/actual effect expectations and whole lifecycle
facts. The shared independent `../captures-direct/oracle.mjs` frames identities
and normalizes those facts without importing compiler or model code. The gate
compares every whole expected document with the accepted `buildScopeHir` model,
then compares complete production bytes against that expectation. The model
is used only for the capture contract, not scheduling or liveness.

The corpus covers direct plus transitive fields, actual-base separation,
labelled and aliased formal slots, scalar edit temporaries, local copies,
three-function/reversed declaration chains, recursive read/edit SCCs, empty
cycles and formal-slot permutation. Pure resolved lambdas retain their own
checked effects under same-name shadows; unavailable environments and typed
callbacks yield explicit reason1 unknowns. Diamond paths merge to one unknown
per outer call, while separate calls retain separate witnesses.

Slice controls distinguish constants, real outer bound occurrences, identical
text at different occurrences, two-hop reversed formal slots and compound
outer actual expressions. Compound callee bounds use the documented explicit
unavailable-summary fallback. Static projection prefixes compose exactly;
known depth8 becomes reason2 at depth9, and growing recursive candidates refuse
above64 rather than publishing a truncated fixed point. Element indices remain
reason3, including a substituted unnameable actual. Arrow task tails retain
both the direct actual read and the complete call origin.

Deep bound controls retain private validation through an eight-slice actual
prefix, an already-deep callee and reordered forwarding. Valid counterparts
still publish reason2 unknowns. Inverted instantiated bounds refuse even for
task-local or materialized actuals, indexed effects, and a separate slice whose
neighboring bound is unavailable. A resolved arrow over a captured List
parameter retains its complete range and explicit unavailable environment.

Positive/negative boundaries cover64/65 callable bodies,1024/1025 checked call
sites and256/257 per-callable target keys. The public observation budget counts
both direct and instantiated effects:128 identity calls retain256 origins,
while129 calls refuse.32 distinct actuals plus their field effects produce64
captures;33 refuse. Two formal effects aliased to one actual target at one
call normalize before the observation charge.

The nineteen source/summary refusals assert diagnostic classes and deterministic
C/Kofun messages. All refusals, including Unicode/path/malformed input controls,
check both absent and preexisting output destinations. Public writer alias,
lookup-fault and transactional host behavior is also exercised through the
entry table in `tests/stage2/host-primitives/check.mjs`.

Every positive is compared twice through strict C11 O0, O2, ASan/UBSan and the
canonical file API. An optional `KOFUN_STAGE2_COMPILER` adds the supplied
production compiler; it never replaces the fresh binaries. Every canonical
invocation has its own120-second child-process bound, including recursive
and capacity sources. Native invocations have the same wall-time bound.
Timeouts fail the gate and are not semantic refusals.

Four paired C/Kofun mutation controls must be caught by independent expectations:
dropping formal effects, selecting the wrong actual slot, omitting unavailable
calls and choosing the wrong bound occurrence. Two further paired controls
lower the substitution-work and fixed-point-sweep limits to force exhaustion;
both must issue E2S154 while preserving prior output. No production guard or
accepted expectation is weakened for these controls.

The unchanged direct-capture gate independently checks the original lexical
entry and full8,384-record boundary. This gate exercises the new composer and
its shared public normalization; it does not claim another maximum-document
run through the complete entry. `--oracle-only` checks fixture/model agreement
without claiming any production result.
