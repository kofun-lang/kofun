# Stage 2 semantic frontend checkpoint

`compiler.kofun` is the canonical implementation. It stays inside the typed
bootstrap subset already exercised by the Stage 1 seed:

- `Int`, `Bool`, `Text`, and `List[Text]`;
- typed functions and direct calls;
- `if`, `while`, and indexed text/character traversal;
- `args`, `read_text`, `write_text`, `chars`, `len`, `text_slice`,
  `contains`, `starts_with`, `is_digit`, `is_space`, and `to_text`.

The frontend performs five concrete operations:

1. lexical scanning that ignores comments and treats escaped strings as single
   tokens, producing a deterministic token-span tape;
2. structural parsing of a compilation unit into textual function,
   immutable integer module-constant, zero/one-`Int`-payload enum, and
   bounded nominal `Int`/`Bool` record IR,
   including names, constructor tags or declaration-order fields, arities,
   byte spans, and top-level function/type visibility metadata;
3. an identity source projection gated by successful lexing and parsing.
4. statement and precedence-aware expression parsing for a deliberately small
   integer Core, followed by deterministic standalone C11 lowering.
5. a type-directed ownership slice for explicitly typed borrowed Lists:
   returning an `Int`, `Float`, `Bool`, or `Unit` iteration element is Copy,
   while moving a non-Copy element such as `Text` is rejected with `E007`.

The identity operation is deliberately conservative. Reapplying it reaches a
byte fixed point, which gives later lowering work a deterministic frontend
boundary. When the output path ends in `.c`, the same frontend instead accepts
one zero-argument `fn main()` plus zero or more `Int` Core functions and lowers:

- immutable or mutable `let` bindings, with optional `Int` annotations;
- assignment to declared mutable `Int` bindings, with immutable and unknown
  targets rejected before C emission;
- integer literals, bindings, parentheses, unary `+`/`-`, `+`, `-`, `*`,
  floor `//`, and floor `%`;
- `Int` parameters and returns;
- direct calls in value or statement position, including forward references
  and recursion;
- direct top-level labelled calls whose parameters and result are all `Int`;
  written arguments are sequenced once into function-local C11 temporaries
  before declaration-order ABI placement;
- statement-position `if` with mandatory braces, optional `else`, nesting,
  Bool literals, and integer `==`, `!=`, `<`, `<=`, `>`, `>=` conditions;
- bounded Int-valued `if` in `let`, `print`, assignment, and `return`, with
  mandatory `else`, nested values, and selected-only evaluation;
- exhaustive statement-position Bool `match` with `true`, `false`, and `_`
  block arms, including nested matches and ordered optional Bool guards;
- bounded Int-valued Bool `match` in `let`, `print`, assignment, and `return`,
  with nested value `if`/`match` and selected-only evaluation;
- top-level, non-generic enums whose constructors carry zero or one `Int`
  payload, explicitly typed immutable bindings, same-typed function
  arguments/results, and exhaustive statement-position enum `match` with
  ordered guards, payload bindings, `_`, and binding catch-alls;
- top-level nominal records with one or more `Int`/`Bool` fields, labelled
  construction evaluated left to right in written order, declaration-order
  AggregateLayout C structs, typed field reads, and same-typed whole-record
  function arguments/results;
- `print(Int)` and `return Int`.

The emitted C11 uses checked arithmetic helpers and preserves Kofun floor
division/modulo behavior for negative operands. Assignment evaluates and checks
the replacement value before changing the binding. Conditions evaluate once
and only the selected branch executes. Value `if` requires one final Int
expression in each branch; general typed value blocks, `else if`, general Bool
expressions, and loops remain outside this Core slice. Bool match uses a finite
`{true, false}` coverage check; `E2S25` names missing patterns and `E2S26`
rejects duplicate or unreachable arms. Guards run only after their pattern
matches; false continues to the next arm, and guarded arms do not provide
static coverage. `E2S29` rejects non-Bool guards. `E2S30` rejects bounded value
arms that do not produce Int. Concrete enum matches apply the same finite
coverage rules to their declared constructor set; `E2S31` rejects malformed or
colliding bounded declarations and `E2S32` rejects unresolved or mismatched
enum uses. Enum values use an internal tag-plus-Int-payload aggregate and may
cross same-typed function arguments and returns; they cannot enter Int
expressions. Payload bindings are visible to guards and arm bodies, and a
binding catch-all may be re-matched. A concrete-enum match also produces one
`Int` in `let`, `print`, assignment, and `return`, under the same coverage
rules and the same `E2S30` arm rule the Bool value match uses; the scrutinee is
read once before any arm is tested and only the selected arm's result
expression runs. Generic enums, wider/nested payloads, and enum-valued match
results remain outside this executable slice.
Record values are untagged per-type structs rather than the enum
tag-plus-payload representation. Generated `offsetof`/`sizeof` assertions pin
their LP64 layout to AggregateLayout v1. Direct construction is lowered only
into an immutable typed binding so separate assignments preserve source
evaluation order; pass and return positions accept an existing binding or a
same-typed function result. `Text`, `List`, ADT, nested-record, generic,
mutable, partial-move, native, and stable-ABI record support remain outside
this executable slice.
Independently, the canonical frontend
appends a versioned `kofun-pattern-tree/v1` syntax section for wildcard,
Bool/null/Int literal, unresolved name, constructor, nested, or-pattern, and
parenthesized forms. Literal records retain `literal_kind`, exact token
spelling, and token span; all other nodes likewise retain their required byte
spans and delimiter/separator spans. Because unary minus is a separate token,
`-42` is not accepted as an Int literal pattern. The tree does no resolution,
typing, arity, exhaustiveness, binding, or lowering.
`E2S58` covers malformed/deferred families and 32-depth/256-node budgets; the
focused `--parse-patterns` mode preserves recovered `ErrorPattern` nodes while
normal compilation remains transactional. Exhausting the node budget emits
one fatal `ErrorPattern` for the failing arm and stops the remaining Pattern
scan, so no later occurrence can reuse its ID or span. After a Pattern, only
`if` or `=>` may continue the arm; other tokens produce `E2S58` without leaking
to name resolution. The first reported Pattern diagnostic is selected by the
smallest source start byte, including across nested matches. The bounded validator permits 256
enum-related identifier occurrences per function and keeps unrelated Int code
on a pre-indexed fast path.
Arm-arrow recovery never crosses a top-level comma; it records the malformed
arm without an arrow and resumes at the following independent arm.
Assignment is currently block-local: changing an outer binding from inside an
`if` or `match` branch is rejected with `E2S22` rather than being silently
miscompiled.
Top-level prototypes make
declaration order irrelevant. The lowerer rejects unknown calls, duplicate
function names, wrong arity, non-`Int` parameters, and non-`Int` helper return
types before invoking the host compiler.

The lexical scope layer records every block as a `ScopeId` and every parameter
and `let` as a `BindingId`. A `for` range header declares its loop variable as
an immutable binding owned by the loop body scope: the header name is a
declaration rather than a use, body uses resolve to the loop binding through
nested scopes, and sibling loops may reuse a name without a false `E2S47`.
Valid `for` sources therefore reach their true lowering boundary (`E2S10`
unsupported statement) instead of a false-invalid `E2S35`.

The 16 builtins of the frozen self-host profile (`args`, `chars`, `contains`,
`find`, `is_digit`, `is_space`, `is_xid_continue`, `len`, `print`,
`read_text`, `replace`, `starts_with`, `text_slice`, `trim`,
`validate_unicode_source`, `write_text`) are known, arity-checked names.
A builtin call with wrong arity is a real `E2S17`; a well-formed builtin call
is valid source outside the bounded Int C11 slice and classifies as
unsupported lowering (`E2S10`, compile-outcome exit 3), never as `E2S16`.
Consequently the frozen self-host source `S`
(`bootstrap/stage1/compiler.kofun`) clears the complete lexical binding layer
and call resolution: `S` is valid source whose remaining boundary is typed
builtin lowering, owned by the #653/#620 slices of #619.

Unannotated `let` bindings carry inferred types in the scope-HIR rather than
a blind `Int` default: literals by token kind, calls by the declared or
builtin result type, name references by their resolved binding, indexing the
profile's `List[Text]` by its `Text` element, bare enum constructors by
their owner, and top-level comparison/boolean operators by `Bool`. The type
vocabulary stays the existing single tokens (`Int`/`Bool`/`Text`/`List`/
`Void`); annotations and value-control initializers keep their previous
behavior, and the conservative fallback remains `Int`, never a new error.
Every one of the 49 bindings in the frozen `S` now records its true type,
pinned in the gate.

Builtin calls are additionally checked against their frozen parameter
types (`chars(Text)`, `contains(Text, Text)`, `text_slice(Text, Int,
Int)`, …, with `len` accepting its Text/List overload): a mismatched
argument is a real `E2S15` naming the builtin, expected type, argument
index, and byte, while well-typed builtin calls continue to classify as
unsupported lowering. Text-literal arguments count correctly toward call
arity. Value-control arguments are skipped rather than rejected.

Statement `if`/`while` conditions and value returns are typed across the
whole profile surface, ordered before the unsupported classification: a
confidently non-Bool condition is `E2S23` (the historical `if` message is
reused byte for byte, `while` gains its own form), and a confidently
mismatched `return` against the declared result type is `E2S15`. Match
guards, value-position `if`, and value-control operands are skipped rather
than guessed, and the conservative unknown falls through to the later
bounded-slice checks. The frozen `S` passes condition and return typing
completely; its frontier remains typed builtin lowering.

Top-level functions accept an omitted modifier, `private`, `internal`, or
`pub`. Structural IR preserves semantic visibility, implicit versus explicit
origin, the modifier/declaration spans, `file:0`, and a declaration-order
symbol identity. These spellings remain identifier tokens elsewhere. `E2S33`
rejects malformed, duplicate, conflicting, or misplaced basic modifiers;
`E2S34` rejects Java/Rust aliases and deferred `pub(...)` forms. This slice
does not enforce access across files, modules, packages, imports, signatures,
tooling, FFI, or linker symbols.

The main CLI tries this Stage 2 C11 Core first. Its internal
`--compile-outcome` mode reports `0` for successful C emission, `1` for invalid
source, `2` for usage/infrastructure failure, and `3` for validated source
whose lowering is unsupported. Only status `3` may enter the explicit Stage 1
compatibility path; a language diagnostic is never retried by another
frontend. The Stage 1 seed independently requires its exact line-oriented
`fn main()`/`let`/`print` Core before it can commit C output. Direct-native
user-function lowering is not implemented yet.

`bootstrap/stage2/adt_frontend.c` is a separate typed-only checkpoint for flat
nominal ADTs. It collects non-generic zero/one-`Int`-payload constructors before
resolving bounded constructor-returning functions, then emits token and typed
IR artifacts with nominal IDs and byte spans. It deliberately emits no C,
native, Wasm, layout, allocation, match, or runtime representation. The main
CLI does not route ordinary builds through this helper yet.

`bootstrap/stage2/generics_frontend.c` is the separate typed-only checkpoint
for explicitly instantiated, unbounded generic functions. It collects every
function signature before bodies, assigns declaration-scoped
`TypeParameterId` values, resolves forward direct calls, checks explicit type
arity before value arguments, and records normalized substitutions and exact
declaration/use spans in `kofun-generics-ir/v1`. `E2S80`–`E2S84` freeze the
bounded declaration, application, substitution, unsupported-feature, and
resource diagnostics. This helper performs no type-argument inference,
generic nominal typing, bounds, traits, recursive generic calls,
monomorphization, dictionary selection, layout, or backend emission. The main
CLI does not route ordinary builds through it. Run its analyzer- and
sanitizer-backed gate with `task generics`.

`bootstrap/stage2/const_generics_frontend.c` is the separate typed-only
checkpoint for integer const generics (#916). It accepts a nominal type
declared with one `const NAME: Int` parameter, gives every instantiation an
identity keyed by the *value* of its literal argument — so `Fixed[2]` and
`Fixed[3]` are different types and `Fixed[02]` is the same type as `Fixed[2]`
— and records one monomorphization row per distinct instantiation in
`kofun-const-generics-ir/v1`. A const argument normalizes into its own
`const:Int:N` namespace, disjoint from the `builtin:`/`nominal:` namespaces a
type argument keeps, so an enclosing identity that embeds a normalized
argument stays injective. `E2S148`–`E2S152` freeze the declaration, argument,
arity, instantiation-mismatch, and resource diagnostics. This helper performs
no const expressions, const inference, const parameters on functions, generic
functions, dictionary selection, layout, or backend emission.

The same surface is reachable through the ordinary compile path, because a
frontend-only fact does not complete #916. `compiler.kofun` and `compiler.c`
accept a `[const NAME: Int]` parameter list on a nominal record, carry the
normalized argument inside the annotation's type text so `Fixed[2]` and
`Fixed[3]` never compare equal, and **specialize per distinct literal**: each
instantiation reaches its own emitted C struct, so a const generic value can be
constructed, passed, returned, and run. `validate_struct_identity` refuses any
collapse of two distinct identities onto one struct with `E2S153` before any C
is written, and `validate_const_erasure` separately keeps a const argument out
of a field type so it never reaches layout. Ordinary type parameters on a
nominal record stay unbuilt and are refused by name; only the C11 Stage 2
backend specializes, and every other declared backend records its gap in
`tests/conformance/capabilities.tsv`. Run the analyzer- and sanitizer-backed
gate for both paths with `task const-generics`.

`bootstrap/stage2/hm_levels_frontend.c` is the separate typed-only checkpoint
for bounded Algorithm J inference over immutable local lambda bindings. It
owns mutable metavariables, occurs checking with level lowering, conservative
lambda-only generalization, fresh instantiation, shadow-safe `BindingId`
resolution, and deterministic `kofun-hm-levels-ir/v1`. `HML001`-`HML007` are
registered to its transactional fixture owner. The focused gate proves
alpha-renaming, declaration-order, path, and repetition invariance and checks
the independent substitution oracle with analyzers and sanitizers. Recursion,
named-function inference, traits, rows, records, matches, effects, ownership
modes, mutable locals, and backend lowering remain explicit refusals. The main
CLI does not route ordinary builds through this helper. Run its complete gate
with `task hm-levels`.

`bootstrap/stage2/adt_exhaustiveness.c` is the resolved flat-ADT match
checkpoint. It defensively joins the declaration table, lossless Pattern tree,
and lexical ScopeId/BindingId artifact for one source module, then publishes a
typed match projection only after all identities and spans agree. Constructor
coverage is keyed by the resolved owner `SymbolId`; same-spelled constructors
in another module cannot affect the result. An arm is analyzed as the
alternatives it tests left to right, so `A | B` and a grouping `(A | B)` cover
the same constructors as two separate arms would. Unguarded whole-constructor
alternatives remove one constructor each, unguarded wildcard or binding
alternatives remove the remaining set, and guarded arms remove nothing.
Every alternative of one arm must bind the same names with the same payload
roles, which is `E2S105`; the arm body then reads one `BindingId` whichever
alternative matched. `E2S25` lists missing witnesses in declaration order and
`E2S26` points to a redundant pattern and its earlier cover, naming the
alternative rather than the arm when the arm has more than one. One arm accepts
at most 64 alternatives. One-`Int` payload constructors accept `_` or one
binding; nested payload usefulness remains outside this bounded slice. Run the
transactional, sanitizer-backed gate with `task adt-exhaustiveness`.

`bootstrap/stage2/module_symbols.c` is the next resolver-side checkpoint. It
consumes a validated inventory of raw `PackageId`, `ModuleId`, and `FileId`
values with exactly one source per module, collects supported function and
flat-ADT headers before inspecting bodies, and emits
`kofun-module-symbols/v1`. Its `NamespaceId` and `SymbolId` values use the
production framed SHA-256/KIF inputs from the accepted module specifications;
file paths, spans, visibility, bodies, and declaration order are excluded from
symbol identity. The adapter inventory used by its test is not manifest
syntax. Imports, partial modules, KIF emission, layout, and backend lowering
remain outside this helper.

`bootstrap/stage2/imports_qualified.c` is the focused same-package qualified
import checkpoint. Its validated adapter inventory has six pipe-delimited
fields:

```text
PackageId|ModuleId|FileId|declared-module-path|logical-path|host-source
```

The declared path is semantic inventory data, not a path inferred from the
filesystem. An optional source `module` header must match it. A leading
`import a.b` resolves exactly one inventoried `ModuleId` in the current
`PackageId` and introduces only the final-component qualifier `b`. The
contextual form `import a.b as local` instead introduces only `local`; the
final component is not additionally bound. The alias is one non-keyword
identifier and remains local to the importing file/module. Neither form
introduces an unqualified member, transitive binding, export, or re-export.
In particular, an ordinary import is a private local binding under the
explicit non-widening re-export contract. `pub import` and `pub from` are
reserved re-export forms and are rejected by this ordinary-import checkpoint
rather than being silently treated as private imports.
All declarations and import edges are collected before function bodies.
Import cycles are reported canonically by shortest edge count, rotation to the
smallest raw `ModuleId`, and then lexicographic raw-`ModuleId` sequence. The
bounded dynamic diagnostic retains every edge span and the closing node; it
never truncates a valid package cycle to the fixed base diagnostic buffer.

The helper emits `kofun-imports-qualified/v1`. Import bindings use the
production `kofun.id.import-binding/v1` framed SHA-256 domain over importer
`ModuleId`/`FileId`, the module `NamespaceId`, local qualifier, target
`ModuleId`, and stable numeric tag 1 for the `qualified-module-v1` form.
An aliased import additionally emits `AliasBindingId` under
`kofun.id.alias-binding/v1`, framed over the importing `ModuleId`/`FileId`,
alias identifier span, local spelling, and unchanged target `ModuleId`.
Qualified-call HIR retains the import and alias bindings, target `ModuleId`,
target `SymbolId`, component/use spans, validated signature, and the
identity-only access result/proof from
`visibility_access.c`. Private declarations in another file are denied;
`internal` and `pub` declarations are usable inside the package.
The executable qualified-call checkpoint accepts only `Int` parameter and
return types. It validates those tokens before projecting an `Int` signature
or lowering C, so another identifier type fails transactionally with `E2S65`.
This line-oriented artifact is a non-authoritative structural test projection,
not KIF and not the canonical `kofun.typed-sidecar/v1` tooling document. It is
never accepted as compiler input and this transactional helper emits no
partial projection after failure; a future typed-sidecar producer must use the
separate #603 status, disclosure, canonical JSON, and trust boundary.

An optional third output operand emits a bounded reference C lowering for
single-return Int functions. Its linker names are derived from the resolved
target `SymbolId`; the conformance gate compiles and executes the lowering.
This helper and its six-field inventory are not yet routed through `bin/kofun`
or manifest loading. The include boundary around `module_symbols.c` is a
temporary way to reuse production declaration identities; it is deliberately
guarded so the existing standalone collector remains independently buildable.
A later compiler-library extraction can replace that adapter without changing
the HIR schema or identities.

`bootstrap/stage2/imports_selective.c` extends the same resolver boundary with
bounded `from a.b import Name, Other` declarations. Each requested spelling
binds the accessible declaration in every matching semantic namespace, keeps
the target `SymbolId`, and derives a distinct selective `ImportBindingId` using
stable form tag 2. The resolver retains every keyword, path component, name,
comma, declaration, call, and type-reference span in its deterministic test
projection. Qualified module aliases and selective bindings may coexist;
neither introduces unlisted, transitive, or re-exported names. Per-name
aliases remain unsupported. Duplicate requests, missing or inaccessible
names, local/import collisions, wrong-namespace uses, per-name aliases,
wildcards, malformed lists, and imports after declarations fail before the
HIR or optional reference C output is committed. The two outputs are
installed as one rollback-capable transaction. Run the gates with
`task import-aliases` and `task imports-selective`.

`bootstrap/stage2/re_exports.c` builds on both import binding forms for the
accepted `pub import a.b` and `pub from a.b import Name` header declarations.
It creates a distinct `ExportBindingId` for each facade namespace/name while
retaining the original target `ModuleId`/`NamespaceId`/`SymbolId`. A public
request must remain public across the target, enclosing facts, bounded
signature, and every forwarded edge; the helper never silently narrows one.
Same-spelled value/type targets expand independently. Local/import/export
collisions, missing or hidden targets, malformed/deferred forms, canonical
cycles, and a 65th chain edge fail before HIR, KIF, or tooling publication.
Exactly 64 edges and 1,024 expanded bindings in one facade are executable
boundaries.

The resolver writes `kofun-re-exports/v1`, an authoritative KIF interface for
the selected facade, and a non-authoritative documentation projection that
retains both facade and canonical paths. Export KIF records store the
`ExportBindingId` as edge identity and the original target `SymbolId`
separately; a defensive source-free consumer proves the distinction. These
source exports do not grant linker, FFI, or runtime forwarding. The helper and
its six-field inventory are not yet routed through ordinary `bin/kofun`
builds. Run the sanitizer-, analyzer-, and boundary-backed gate with
`task re-exports`.

`bootstrap/stage2/incremental_graph.c` is the persisted compiler semantic
dependency graph built on those digests. It resolves one package inventory,
derives every module's public and package-internal semantic digest through the
same KIF writer, and stores nodes and edges under a cache directory. A later
run recomputes each module's source digest and outgoing edge digest, then
decides per module whether its interface must be executed or may be reused.
Reuse is a real skip: a reused module's interface is neither rebuilt nor
republished, and its digests come from the verified cache entry.

Invalidation follows the digests rather than the file graph. A comment,
formatting, private body, or unused private declaration edit recomputes only
its own module because no interface digest moves. A package-internal signature
change invalidates same-package consumers with matching edges while leaving the
public view, and therefore any external consumer, reusable. A public change
invalidates consumers, and continues past them only when their own interfaces
also move. Removing a selected import or a re-export changes the importing or
facade module's recorded edge set, so its consumers are never silently reused.
Modules are decided dependencies-first in canonical `ModuleId` order, so
inventory discovery order cannot change the persisted graph.

The cache is defensive rather than trusted. An unknown schema tag, malformed
record, foreign `PackageId`, exceeded node/edge/byte limit, or mutated
interface blob is a bounded cache miss that recomputes, never a crash and never
a stale reuse; a corrupt blob demotes only its own module. Manifests and
interfaces are replaced atomically, and a rejected source commits nothing, so
a failure is never reusable as a success. The maintained gate also injects a
deterministic cancellation after semantic work and proves that no manifest or
report is committed; its repaired successor executes from cold rather than
reusing the unreferenced partial artifact. Oversized manifests and KIF blobs
are exercised at their real 4 MiB and 16 MiB bounds.

Report schema `kofun-incremental-report/v3` records an `artifact BYTES PATH`
row for each KIF and an `artifact-summary executed-bytes=N reused-bytes=N`
row. Together with the semantic and target work-count summaries, this makes the
cold baseline directly comparable to warm reuse without treating time as a
correctness signal: cold executed bytes must equal warm reused bytes.

The fourth argument is a 64-digit `TARGET_PROFILE_DIGEST` supplied by the
upstream target ABI/profile fact producer. The digest, never a host path, is
part of the persisted target action key. A profile-only change reuses unchanged
semantic nodes but conservatively rebuilds every target artifact; an unchanged
profile may reuse a target artifact only when its module's semantic work was
also reused. This is the compiler-to-action boundary, not Frost's full
target/action graph: the helper does not derive ABI facts, schedule work, or
make timing claims. The gate also proves that clean copies under different
physical source roots produce byte-identical manifests and reports. Run all ten
edit-matrix rows, failure/repair, path-remap, sanitizer, and analyzer checks
with `task incremental`. The optional fifth argument,
`CANCEL_AFTER_EXECUTIONS`, is a bounded conformance fault-injection input; it
stops before manifest/report commitment after the requested number of executed
semantic modules and is not part of the persisted action key.

Focused import diagnostics are `E2S59` malformed/order/path/alias, `E2S60`
missing module, `E2S61` self import, `E2S62` duplicate target/import, `E2S63`
module qualifier collision,
`E2S64` canonical cycle, `E2S65` qualified lookup/signature/arity/lowering,
`E2S66` access denial, `E2S67` bounded-resource exhaustion, and `E2S68`
allocation/invariant/output failure. Re-export diagnostics occupy `E2S85`
through `E2S94`. Semantic failure removes every requested artifact.

`bootstrap/stage2/semantic_events.h` is the compiler-owned, bounded semantic
sink boundary for tooling. `semantic_producer.c` attaches that sink to the
audited Stage 2 compiler-owned compile or focused-ownership outcome. It
projects type, constructor, and function declarations from committed parser
IR and scopes, bindings, and uses from committed scope HIR; it does not
reclassify rejected source. Diagnostics are captured as structured records at
their compiler construction sites before the rendered fallback is returned.
Parser and scope-HIR commit hooks retain only complete declarations, scopes,
bindings, and uses that precede a later failure. Lowering hooks similarly
publish only successfully validated calls, constructors, patterns, and
control expressions. These nullable hooks are seed-only C instrumentation
enabled by the internal semantic-event process; ordinary `compiler.c`
execution leaves them disabled. The canonical source and audited C seed both
accept basic visibility on bounded top-level functions and nominal types. The
internal event executable remains a process boundary for the later projector,
not a user-facing `bin/kofun` option.

The reference sink writes the internal
`kofun-stage2-semantic-events/v1` KSE framing only after source/span
commitment, status/dependency/disclosure closure, counts, size, and SHA-256
validate. Early source/span failure, sink rejection, encoding failure, or
cancellation before commitment publishes no stream. The producer is a
separate executable, so no-sink Stage 2 stdout, stderr, diagnostics, exits,
and artifacts remain byte-identical; the focused gate compares them.

The KSE transport is not KIF or the public typed-sidecar JSON and is never
accepted as compiler/cache authority. The exact event-kind, field-tag, wire,
phase, bound, and `ETS03`/`ETS04` contracts are checked in at
`semantic-events-v1.md`. The one-way #609 projector validates those bytes
independently and maps them into an explicitly requested, non-authoritative
single-file sidecar; its complete field table is
`../../tooling/typed-sidecar/stage2-projection-v1.md`. Run the producer and
projector gates with `task stage2-events` and `task typed-sidecar-projector`.

## Verification

Run:

```sh
sh bootstrap/stage2/check.sh
```

`build.sh` in this directory is not a gate and is not executable. It is sourced
by the twenty gates that need a Stage 2 compiler binary, and it is the single
definition of how one is produced:

```sh
. "$ROOT/bootstrap/stage2/build.sh"
kofun_stage2_build "$ROOT" "$WORK/kofun-stage2"
```

Every one of those gates therefore honours `KOFUN_STAGE2_COMPILER`. Export it
with a compiler you have already built and each gate copies it instead of
spending about 4.6s recompiling `compiler.c`.

The check validates the canonical-source and seed hashes, compiles the audited
C11 seed, round-trips the fixture, current Stage 1 compiler, and Stage 2
compiler byte-for-byte, inspects their function IR, checks token-tape
determinism, and rejects a missing closing brace. It also lowers
`core_fixture.kofun` twice, compares the C/IR/token artifacts, compiles the C11
with warnings as errors, executes it, and compares exact output and status. A
second generated program verifies the division-by-zero status/stderr contract,
and `functions_fixture.kofun` proves arguments, results, recursion, an ignored
zero-argument call, and a forward reference through both the seed and the main
CLI. Exact golden diagnostics cover unknown functions and arity mismatch. A
structurally valid non-Core function verifies explicit lowering rejection.
Dedicated positive and negative fixtures exercise the ownership slice both
through the Stage 2 seed and `kofun check`; unrelated structural programs are
explicitly rejected as outside that slice. The gate uses only POSIX shell, a
C11 compiler, `sha256sum`, and standard comparison/search tools.

`tests/conformance/modules/visibility-syntax/run.sh` separately covers all
basic visibility forms, same-file forward calls and execution, contextual
identifier uses, exact modifier diagnostics, artifact absence, and
byte-identical repeated output.

`tests/conformance/adt/run.sh` covers the typed-only MaybeInt checkpoint,
constructor-before-declaration resolution, deterministic IR/token artifacts,
zero/one-payload typing, and exact E2S36–E2S46 diagnostics for invalid or
explicitly deferred ADT forms.

`tests/conformance/modules/top-level-declarations/run.sh` covers production
identity framing, same-module forward/recursive/mutual references, value/type
namespace separation, canonical multi-module inventory order, path and source
order invariance, transaction failure, fixed resource limits, and exact
E2S48–E2S56 inventory. It also runs the collector with C11 warnings as errors,
GCC analyzer when available, AddressSanitizer, and UndefinedBehaviorSanitizer.

`tests/conformance/patterns/run.sh` covers the canonical lossless Pattern tree,
path-independent deterministic goldens, statement/value arm nesting, hard
recovery synchronization, normal-compile transactionality, exact `E2S58`,
and the depth/node boundary plus one-over cases. General Pattern syntax is not
evidence of executable destructuring.

`tests/conformance/modules/imports-qualified/run.sh` covers two-module
qualified resolution, production binding/target identities, absolute source
remapping, no unqualified leakage, missing/self/duplicate/colliding imports,
canonical cycles, visibility enforcement, resource rejection, transaction
failure, and reference-backend execution through the resolved `SymbolId`.

`kif_v1.c` and `kif_v1.h` implement the compiler-authoritative KIF v2 binary
writer/reader for bounded function, flat-ADT, and public re-export facts.
Export records preserve source import, facade edge, original target, and
canonical chain identities without changing existing declaration-only bytes.
Records use explicit
schema tags and big-endian widths, canonical identity ordering, distinct
public and package-internal semantic views, defensive limits, full self-read,
and atomic replacement. `kif_v1_tool.c` projects the committed declaration
table, emits non-authoritative JSON only after validation, and resolves the
qualified-import slice from a validated KIF while the dependency source is
absent. `tests/conformance/modules/kif-v1/run.sh` covers deterministic bytes,
visibility, digests, source-free consumption, corruption mutations, exact
limits, failed publication, C11 warnings, sanitizers, and static analysis.
`tests/conformance/modules/re-exports/run.sh` adds export-fact digest,
round-trip, mutation, and source-free facade-consumption coverage.

Function signatures carry a canonical external-label/unlabelled entry beside
each parameter type. The defensive reader validates those entries before
publication; internal parameter names remain excluded from interface identity.

`stage2_kif_producer.c` is the normal Stage 2 source-to-KIF bridge. It asks the
same committed compiler run used by `semantic_producer.c` for structured
function, ADT, constructor, identity, visibility, and type facts; it never
reconstructs authority from rendered event text or an adapter inventory. KIF
KIF v2 keeps the existing type-reference encoding and adds resolved flat
nominal ADT SymbolIds to function parameters/results and zero/one-field
constructor payloads. Public signatures may reference only public ADTs;
package-internal signatures may reference public or internal ADTs. A private,
absent, or non-ADT identity fails closed before the writer, and the reader
rechecks the same relationship before exposing decoded facts. Private facts
are omitted. Records, generics, effects, and ownership signature components
fail explicitly until their canonical KIF producers exist. Cancellation,
leakage, unsupported publication, or any compiler failure reaches the atomic
writer neither on a cold destination nor over a prior interface.
`kofun check INPUT.kofun --emit-kif OUTPUT.kif` exposes this authoritative
path. `task stage2-kif-producer` retains the producer transaction baseline;
`task visibility-filtering`, `task visibility-api-leaks`, and
`task module-interface-artifact` cover exact nominal identities, digest-view
changes, non-disclosing source diagnostics, source-free view selection, and
malicious hidden/absent identity rejection.

`tests/conformance/incremental/run.sh` pins the semantic and target-action
invalidation decisions on a four-module `core <- service <- app` package plus
an unrelated `util`. It records the exact executed/reused or rebuilt/reused set
for all ten Required edit matrix rows, including target-profile changes, a
cold failed compile followed by repair, and path-remapped clean copies. It also
covers the transitive case where a changed intermediate interface continues to
propagate, the external public boundary through source-free KIF resolution,
inventory-order invariance, bounded recovery from unknown schemas and corrupt
manifests and blobs, and failure non-publication. The collector's rejection of
top-level comments remains an explicit `SKIP`, never an implicit pass.

`bootstrap/stage2/visibility_access.c` is the pure access primitive for the
next resolver slice. It compares only schema-tagged 32-byte package, module,
file, and optional type-owner identities; it has no filesystem, name, import,
target, linker, or runtime input. The table-driven
`tests/conformance/modules/visibility-access/run.sh` gate verifies exact
allowed, denied, and unsupported results. The focused qualified-import
resolver calls it for each cross-file target; the main CLI is not routed
through that resolver yet.

`compiler.c` is an audited executable transliteration of the Kofun source so
this checkpoint can run before Stage 1 accepts all of Stage 2. It is part of the
temporary trusted seed, not evidence that Kofun has completed self-hosting. The
integer Core lowering is real, but Stage 2 still cannot lower its own Text,
List[Text], file-I/O, and control-flow-heavy implementation. Full semantic
self-compilation therefore remains open. The next bootstrap milestone is to
extend the Kofun compiler path until it can rebuild this seed from
`compiler.kofun`, then compare the resulting artifact.

The Copy/borrow checker is likewise intentionally bounded. It recognizes one
explicit `read List[T]` parameter per function, a named `for` iteration, and a
same-line return that contains the element. It does not claim full inference,
borrow lifetimes, `take` call resolution, or collection code generation.

The trait frontend is bounded in the same deliberate way. `traits_frontend.c`
accepts one-method traits with one type parameter, concrete implementations,
and generic functions carrying exactly one explicit non-recursive bound. Inside
that shape it is complete: it assigns `TraitId`, `MethodId`, and
`ImplementationId`, checks method signatures after substitution, enforces the
coherence and orphan rules `docs/TYPE_SYSTEM.md` records, and writes the
implementation each call selected into typed IR.

It also elaborates the dictionary that selection denotes (#923): a descriptor
per trait, a dictionary value per admissible implementation with a
`DictionaryId` derived from the `ImplementationId`, a dictionary parameter per
declared bound, and an explicit dictionary argument at each bounded call.
Elaboration runs last, only on the accepted path, so a refused program never
gets one.

It lowers none of it below that. Nothing is monomorphised, no vtable is laid
out, and no runtime search is emitted — the gate asserts the IR names no
monomorphisation, vtable, or search, and that no backend artifact is written.
Naming the dictionary a call passes is not the same claim as being able to run
it.

`foreign` marks a declaration as belonging to another package. It is the
synthetic stand-in that makes the orphan rule testable in one file while
cross-package loading stays out of scope, and it is not proposed surface
syntax.

The Optional frontend is bounded in the same way. `optional_frontend.c`
classifies `null` as a keyword, parses one postfix `?` on a primary type, and
represents the result as `Optional(TypeId)`. The suffix binds to the complete
primary type before it, so `List[Int]?` and `List[Int?]` are structurally
distinct rather than two spellings of one type.

`null` is contextual: it has no standalone type, it takes an expected
`Optional(T)`, and it is refused under an expected `T`. A concrete `T`
satisfies an expected `Optional(T)` through one injection rule, and the typed
IR records that injection rather than silently rewriting the type, so the rule
cannot spread past an expected optional context unnoticed.

Runtime representation is deferred and cannot be inferred from the typed node —
the gate asserts the IR names no tag, niche, layout, or discriminant.
Coalescing, matching, and propagation are separate issues, and `??` is not
parsed here at all.

Flow-sensitive narrowing (#312) is layered on that typed node, and is
**frontend-only**: it decides how a use of `x` is typed, and nothing else. It
selects no runtime representation, emits no lowering, and no backend consumes
it. `optional_frontend.c` recognizes exactly four conditions — `x != null` and
`null != x` refine the true edge, `x == null` and `null == x` refine the false
edge — over a direct local binding declared `Optional(T)`, plus the
early-return guard forms where a definitely-returning branch carries the
opposite edge past it. Every other condition still types as a `Bool` and
refines nothing.

A refinement is a fact about one edge, never a change to a declared type and
never something that escapes its function. The typed IR carries that
distinction explicitly: `refinement` rows print the declared type beside the
refined one, `narrowed-use` rows mark each use the frontend typed as `T`
rather than `Optional(T)`, and `refinement-discarded` rows record every
invalidation with its reason — `assignment`, `call`, or `loop-backedge` —
rather than leaving the discard to be inferred from the absence of an error.
Each branch gets its own environment, joins merge by intersection, an
assignment is checked against the declared `Optional(T)` before it discards,
a mutable binding loses its refinement to any call because this frontend
refuses ownership modes and therefore has only unknown effects, an immutable
`let` keeps its refinement, and a loop backedge discards the refinement of
every mutable binding the body mentions.

Unsupported shapes stay errors rather than optimistic assumptions: property
and index paths are refused (`E2S142`), as is `null` in any comparison outside
the four recognized ones, and assignment to an immutable binding is refused
(`E2S143`) because the retain-across-calls rule depends on it. Compound
conditions, aliases, captured variables, interprocedural summaries, `match`,
safe navigation, truthiness, and user-defined equality are all out of the
slice. The gate is `tests/conformance/optional-narrowing/run.sh`, with
generated control-flow graphs in `tests/fuzz/optional_narrowing.sh`.

`E2S142` and `E2S143` are registered in `tests/diagnostics/registry.tsv` under
the `optional-narrowing` adapter. `E2S134`-`E2S141` are still unregistered:
see the note in `tests/conformance/optional/README.md` for why the registry's
completeness check cannot see codes emitted from a separate frontend.

### Executable bounded `List[Int]` in the C11 slice (#919, #1103)

The ordinary Stage 2 path admits immutable `List[Int]` literals and locals up
to 64 elements. The AggregateLayout view remains a checked `u64` length
followed by contiguous `Int` payload bytes; `len` and positive, negative, or
dynamic indexing use that view, with runtime `R023` on a dynamic out-of-range
read.

Direct top-level function signatures now carry the same bounded value (#1103).
The generated ABI uses `KofunIntListValue`, a fixed-capacity structure passed
and returned by value. A literal is copied into that carrier at its immutable
local binding; whole bindings and same-typed calls may then cross direct
function parameters/results without a heap allocation or pointer alias in the
ABI. Calls containing a list parameter evaluate every list and companion `Int`
argument exactly once in written order through typed C11 temporary slots.

This is not general list lowering. Direct literal arguments/returns, mutable
lists, `List[Text]`, nested/general lists, labelled or indirect list calls,
list fields in nominal records, non-C11 backends, variable capacities, and
collection ownership inference remain refused. The focused gates are
`tests/stage2/list-int-values/run.sh` and
`tests/stage2/list-int-signatures/run.sh`; the general list capability remains
unsupported until the later #868 record-field increments land.

### Executable `Optional(Int)` in the C11 slice (#924)

The paragraphs above describe `optional_frontend.c`, which is still
frontend-only. Separately, the canonical `compiler.kofun` source and its
audited `compiler.c` seed make **one** optional type executable:
`Optional(Int)`.

The representation is not chosen here. `spec/aggregate-layout-v1/examples/
core.x86_64-linux.json` carries the accepted `Optional[Int]` descriptor —
`kind` optional, `size` 16, `align` 8, `tag_width` 1 at `tag_offset` 0,
`payload_offset` 8, `payload_size` 8, constructors `None` at tag 0 and `Some`
at tag 1 — and the lowering emits exactly that as

```c
typedef struct {
    uint8_t tag;
    int64_t payload;
} KofunOptionalInt;
```

with six generated `_Static_assert`s pinning every quantity. The tag is
explicit because AggregateLayout v1 forbids a backend from inventing a niche,
so a translation unit that disagreed with the descriptor fails to compile
rather than meaning different bytes.

What executes: `let x: Int? = null` and `let x: Int? = 7` construct the absent
and present values; an `Int?` parameter and an `Int?` result carry a value
across a function boundary by value, tag and payload together; a call declared
`Int?` and another `Int?` binding both initialize an `Int?` whole; and the four
recognized narrowing shapes plus the definitely-returning guard are lowered, so
`if x != null { print(x + 1) }` runs. A narrowing condition lowers to a tag
test and a narrowed use lowers to the payload — and only because
`validate_optional_uses` has already proved, before any C exists, that every
such use sits on an edge that tested the tag. There is no extraction operator,
and no force unwrap.

The same exact carrier now supports the bounded coalescing form
`Optional(Int) ?? Int -> Int` (#314). `??` binds below arithmetic and above
comparison, so `value ?? 0 == 0` is `(value ?? 0) == 0`. Balanced ordinary
parentheses are transparent around the exact accepted binding/call/null left
shapes. A
function-local `KofunOptionalInt` carrier keyed by the operator source byte
stores the left exactly once; C11's conditional operator tests its tag and
evaluates the fallback only for `None`. A failed left suppresses the fallback,
while a failure in a selected fallback propagates through the existing checked
runtime path. The expression works without special statement lowering in let,
print, return, and function-argument position.

Refusals carry `E2S147`, registered under the `optional-construction` adapter:
an unnarrowed use, a sibling-branch or non-dominating-guard use, a mutable
`Int?`, an assignment to one, `Int??`, a `null` with no expected `Int?` to type
it, a property or index path, an `Int?` where an `Int` is expected, and an
`Int?` result used anywhere but whole. Coalescing additionally refuses a
non-`Int?` left, a non-`Int` fallback, optional payloads other than `Int`, and
chaining before emitting a backend artifact.

Two bounds are worth stating rather than leaving to be discovered. Every `Int?`
binding this slice lowers is immutable, so the invalidation rules that need
mutation cannot arise — the declaration that would create one is refused first,
and the frontend gate still pins those rules for the mutable spelling. And
`while` is not lowered by this C11 slice at all, independently of Optional, so
the loop-backedge *positive* is not expressible here. The gate is
`tests/conformance/optional-construction/run.sh`, which recomputes the
descriptor with `spec/aggregate-layout-v1/layout.mjs` rather than reading a
checked-in copy, so a drift on either side fails it. The companion
`tests/conformance/optional-coalescing/run.sh` gate makes evaluation order,
selected checked failures, expression positions, signed payloads, refusal
boundaries, strict C11, and deterministic emission executable. The companion
`tests/stage2/optional-pair/run.sh` gate derives the Optional semantic family
from both canonical files, pins its load-bearing dispatch points, and mutates a
member and validation call to prove that source/seed drift cannot pass silently.
