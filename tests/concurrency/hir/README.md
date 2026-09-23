# Production scoped identities

`task concurrency-hir` executes the analysis-only `--emit-scope-hir-v2 INPUT
OUTPUT LOGICAL-PATH` entry in the maintained C compiler and the canonical
Kofun source. The latter uses the existing bounded host driver; this is not
native self-compilation or scoped-parallel execution.

The lexical resolver adds a file-enclosing scope and real bindings for par
scope tokens. Spawn receivers and joins must resolve to those exact token and
handle bindings. Nested blocks may shadow handle names without conflating
identities. Standalone spawns allocate hidden handles after ordinary bindings,
in source order; immediate chained joins use those handles explicitly. The
fixture table includes mixed named/unnamed tasks and two-function Unicode and
comment spans. Alias/dynamic receivers, duplicate joins and unsupported v1
shapes refuse; an unjoined task has one scope-exit join. The closed v2 document has
only par, task and join records in this delivery.

`cases.json` freezes source bytes, explicit half-open node spans, resolver
scope/binding numbers and joins. The independent oracle uses those authored
facts and Node crypto to reconstruct FileId, ScopeId, BindingId, NodeId,
ParId, TaskId and JoinId from raw bytes. It never copies production identities.
Every output is also checked by the existing closed schema's reference
validator and canonical encoder. The maintained Kofun and C resolvers agree
on their complete private HIR, not just the projected records.

The gate checks strict C11 O0/O2, repeats, Clang ASan/UBSan, Unicode and long
hidden displays, same-width display renames, physical relocation with explicit
logical provenance, 4096-byte logical paths, 64/65 pars and tasks, exact prior
unsupported/malformed E2S154 spans, malformed functions, source NUL/NFC,
input/output aliases, and preservation of prior artifacts on refusal. Raw-byte
framing vectors include NUL payloads, nine SHA blocks and all SHA padding
transitions at 55/56/63/64/119/120 total message bytes. Node kind/span uniqueness
is asserted independently before using occurrence zero. The 32+32 and 33+32
task fixtures enforce the document-wide bound; empty files/pars are accepted.

45,299 NFC differential vectors use the pinned C normalizer as oracle against
the Kofun decomposition/order/composition implementation. They cover every
canonical mapping, Hangul syllable, composition pair, blocking witnesses and
seeded mixed sequences, including the decomposed-precomposed counterexample
Ê + dot-below + combining-wavy-hamza-below. Full path tests pin NFC, categories,
URI schemes, 4096/4097 UTF-8 bytes, invalid scalars and NUL. The existing
host-primitives gate also exercises the new writer's complete alias and
lookup-failure matrix, with invalid logical provenance to prove precedence.
Existing v1 HIR and normal compilation refusals remain unchanged; the ordinary
block-lambda argument has its earlier E2S158 boundary before E2S154.

The test C driver exposes read-only probes and delegates all analysis to the
maintained compiler. `KOFUN_STAGE2_COMPILER` additionally exercises the supplied
production CLI for coverage collection; sanitizers and fault probes stay in
invocation-owned builds. No compiler test mode is added to production.

This gate adds no places, captures, effect propagation, conflict checking,
ownership acceptance, KSE2 transport, scheduler, backend or release capability.
