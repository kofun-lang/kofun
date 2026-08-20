# Typed semantic sidecar v1

Status: accepted normative design for GitHub issue #601.

This document defines Kofun's first complete/partial semantic artifact for
editors and developer tools. It is intentionally separate from the
compiler-authoritative KIF interface in `spec/modules/module-identity.md`.

The words **must**, **must not**, **should**, and **may** are normative.

## Decision

V1 uses canonical UTF-8 JSON with media type:

~~~text
application/vnd.kofun.typed-sidecar+json;version=1
~~~

and conventional suffix `.kofun-semantic.json`.

Every document contains:

~~~json
{
  "authoritative": false,
  "completeness": "complete",
  "schema": "kofun.typed-sidecar/v1",
  "source_status": "checked"
}
~~~

`authoritative` is required and must be the JSON boolean `false`. A compiler,
package manager, build cache, linker, KIF reader, or semantic invalidation
graph must reject this document as an authoritative input. Renaming the file,
removing fields, or embedding it inside another artifact never upgrades its
trust.

JSON is selected for the first sidecar because partial/tooling data benefits
from inspectability and broad reader support more than compact binary layout.
This does not make arbitrary JSON canonical or authoritative. A later binary
transport requires a new media/schema version and must preserve the trust and
fact-status model below.

## Trust separation from KIF

| Property | KIF compiled interface | Typed sidecar |
| --- | --- | --- |
| Compiler/package authority | yes after full validation | never |
| Separate name/type checking | yes | forbidden |
| Semantic cache success | yes | forbidden |
| Public/internal digests | authoritative fields | display/reference only |
| Paths/spans/locals/diagnostics | non-authoritative side data at most | primary purpose |
| Partial artifact after error | no successful interface | yes, explicitly marked |
| Reader failure | rebuild/recheck | discard/recompute tooling data |

The two formats use separate entry points and result types. A generic “load
compiler artifact” function must not dispatch a sidecar into the KIF reader.

## Root record

The normative JSON Schema is
`spec/typed-sidecar/kofun.typed-sidecar.v1.schema.json`. A v1 root contains:

- `schema`: exactly `kofun.typed-sidecar/v1`;
- `authoritative`: exactly `false`;
- `compiler`: language edition and semantic-compatibility version;
- `completeness`: `complete` or `partial`;
- `source_status`: `checked`, `failed`, or `cancelled`;
- `file`: validated package/module/file identity and logical source facts;
- `generation`: caller-supplied monotonic sequence;
- `limits`: the named bounded profile used by the producer;
- `nodes`: typed syntax/semantic facts;
- `references`: resolved, hidden, provisional, or failed uses; and
- `diagnostics`: structured diagnostics and remedies.

Compatibility pairs are:

| completeness | source_status | Meaning |
| --- | --- | --- |
| complete | checked | the requested file check completed and every emitted fact is validated |
| partial | failed | checking failed; validated prefix/independent facts may coexist with provisional/error/unavailable facts |
| partial | cancelled | work stopped; no newly derived fact may be presented as validated unless it was committed before cancellation |

`complete` with `failed`/`cancelled`, and `partial` with `checked`, are invalid.
A complete document has no error diagnostic and no provisional/error/
unavailable node or reference.

## Source and generation identity

The `file` record contains:

- raw lowercase-hex `PackageId`, `ModuleId`, and `FileId`;
- validated logical source path;
- exact source byte length;
- SHA-256 of the exact source bytes; and
- an optional stable path-remap root ID, never an absolute path.

The source digest is content provenance, not a replacement for `FileId` or a
semantic digest. Absolute checkout roots, URIs, inodes, mtimes, timestamps,
process IDs, random IDs, pointers, and filesystem case-folded spellings are
forbidden.

`generation.sequence` is an unsigned JSON integer supplied monotonically by
the workspace/document owner. It is not a clock. A writer may replace an
existing sidecar only when:

1. both records name the same `FileId`;
2. the new sequence is greater than the stored sequence;
3. the new source digest equals the caller's current source digest; and
4. the new complete/partial document passes all validation.

Thus a new partial result for edited bytes may replace an older complete
result, while a stale or cancelled older task cannot overwrite a newer
complete result. Equality is not “last writer wins”; equal sequence is denied.

## Canonical JSON

V1 canonical bytes are:

- UTF-8 without BOM;
- exactly one JSON value followed by one LF;
- no comments or trailing data;
- every object key unique and serialized in Unicode code-unit/ASCII
  lexicographic order (all v1 keys are ASCII);
- arrays ordered by the semantic rules below;
- valid Unicode strings already in NFC;
- lowercase 64-hex IDs/digests;
- JSON integers only where the schema declares bounded integers;
- no floating-point values, exponent spellings, `NaN`, or infinities; and
- compact scalar spelling with two-space indentation as shown by the checked
  examples.

Key order is canonical for byte-identical goldens but is not semantic. Readers
must reject duplicate keys before converting to an ordinary map. They may
accept noncanonical key whitespace/order only in an explicit diagnostic/import
mode; such bytes cannot be stored as a canonical sidecar without re-emission.
The v1 compiler/tooling reader used for cacheable editor data accepts canonical
bytes only.

## Fact status lattice

Every node/reference has one status:

| Status | Meaning |
| --- | --- |
| `validated` | fully checked under this document's recorded source/compiler/schema inputs |
| `provisional` | structurally plausible but depends on failed/unknown semantic input |
| `error` | rejected and linked to at least one diagnostic ID |
| `unavailable` | deliberately absent because of recovery, cancellation, privacy, or budget |

There is no implicit “probably valid” status. Rules:

- a `validated` fact may depend only on `validated` facts;
- `provisional`, `error`, or `unavailable` can never satisfy a validated fact;
- an `error` fact has at least one `diagnostic_id`;
- `unavailable` may carry a reason code but no fabricated type/target value;
- a cancelled producer cannot create a new validated dependency closure after
  cancellation; and
- readers that do not recognize a future status treat it as unavailable, not
  validated.

Tools display the distinction. Hover may show a provisional type with an
explicit marker; definition navigation cannot jump to a fabricated target.

## Semantic nodes

Each node includes:

- `id`: a sidecar-local 64-hex `NodeId`;
- `kind`: versioned syntax/semantic kind text;
- exact half-open UTF-8 byte `span`;
- `status` and ordered `diagnostic_ids`;
- ordered `depends_on` NodeIds;
- zero or more typed stable identities; and
- optional type/effect/ownership/origin records with their own fact status.

The sidecar-local ID is produced with the #303 framed SHA-256 construction:

~~~text
domain = kofun.sidecar.node/v1
payload = FileId || syntax-kind || start:u32be || end:u32be || occurrence:u32be
~~~

It addresses one syntax occurrence. It is never a declaration identity and
cannot replace `ScopeId`, `BindingId`, `NamespaceId`, `SymbolId`, `TypeId`,
`ImportBindingId`, `ExportBindingId`, `ImplementationId`, or `LawEvidenceId`.

Stable identities are records with an explicit kind and 64-hex value. Unknown
identity kinds are unavailable to a v1 reader. A node may contain both a local
`BindingId` and a resolved type `SymbolId`; their kinds cannot be inferred from
the bytes.

Nodes are sorted by `(span.start, span.end, kind, id)`. A parent need not appear
before a child. `depends_on` and `diagnostic_ids` are unique,
lexicographically sorted ID sets. Stable identities are unique and sorted by
`(kind, value)`. All spans satisfy
`0 <= start <= end <= file.byte_length`.

## References and safe disclosure

A reference contains its own sidecar-local ID/span/status, `from_node`, target
namespace/expected kind, diagnostic links, and exactly one target shape:

- `resolved`: explicit stable target identity and optional declaration node;
- `hidden`: the safe-disclosure marker and optional identity kind, with no
  target value/path/name;
- `provisional`: unresolved spelling/namespace context marked provisional; or
- `unavailable`: reason only.

The identity-only access decision from #582 controls disclosure. A denied use
may retain the caller's span and an inaccessible-target category but cannot
serialize a dependency's private name, path, span, or ID when disclosure says
use-only.

References are sorted by `(span.start, span.end, id)`. Resolved references
retain original target identity through imports/re-exports; facade provenance
uses explicit ImportBindingId/ExportBindingId identities rather than replacing
the target SymbolId.

## Structured diagnostics

Each diagnostic includes:

- stable sidecar diagnostic ID and compiler diagnostic code;
- severity/category;
- primary FileId/span;
- ordered safe related locations/identities;
- stable message-template ID and rendered fallback text;
- ordered remedy IDs and optional bounded edits;
- affected node/reference IDs; and
- truncation/budget metadata when applicable.

Diagnostics are sorted by `(primary.file_id, primary.span.start,
primary.span.end, severity-rank, code, id)`. Related data and affected-ID sets
are canonical and duplicate-free. `affected_ids` are lexicographically sorted;
related records are sorted by `(relation, location, identity)`; and remedies
are sorted by `(id, span, replacement)`. Presentation locale is not an
identity or ordering input.

An error diagnostic makes the document partial/failed unless it represents a
separate non-blocking analysis explicitly classified by a future schema.

## Consumer field mapping

All tooling consumers use the same validated document and preserve fact
status; they do not reinterpret fallback text or mint replacement identities.

| Consumer | Fields | Required behavior |
| --- | --- | --- |
| Hover | `nodes[].type/effect/ownership/origin` | show `validated` normally, visibly mark `provisional`, and omit unavailable display data |
| Definition | `references[].status/target` | navigate only a `validated` + `resolved` target; hidden/provisional/unavailable never fabricates a location |
| Diagnostics/code actions | `diagnostics[].primary/related/remedies/affected_ids` | use structured spans and IDs; fallback text is presentation only |
| Documentation | stable identities plus a future visibility-checked attachment field | never infer or embed private documentation from a hidden target |
| Ownership views | `nodes[].ownership/origin` | preserve their nested fact status and the node dependency closure |

The v1 schema deliberately has no documentation-body field. A future
attachment-ID field can extend this mapping only with visibility and privacy
rules; tools cannot overload `fallback_text`, `display`, or logical paths to
carry documentation.

## Partial emission

A failed or cancelled check may emit a partial document only after:

1. source bytes, FileId, content digest, and token/span basis validate;
2. every included fact receives an explicit status;
3. validated dependency closure is checked;
4. dangling/unsafe relations are removed or marked unavailable;
5. diagnostics and safe disclosure finish;
6. ordering, counts, bytes, and depth validate;
7. canonical JSON bytes validate against the schema and semantic rules; and
8. stale-replacement checks pass before atomic rename.

If the producer cannot trust source identity or byte spans, it emits no
sidecar. A partial sidecar does not cause a KIF/cache success and cannot be
used to continue compiler resolution as though the failed facts existed.

Facts validated independently before a later error may remain validated. A
malformed header that prevents committing the module declaration table makes
dependent top-level references provisional/unavailable; it does not erase
unrelated lexical/token facts whose dependency closure remains valid.

## Limits

The required `default-v1` profile fixes:

- 16 MiB canonical JSON bytes;
- maximum structural JSON depth 128;
- 65,536 nodes;
- 131,072 references;
- 65,536 diagnostics;
- 262,144 total stable-identity records;
- 262,144 dependency/affected-ID edges;
- 1 MiB rendered fallback/attached text total;
- 4,096 edits and 1 MiB replacement text total; and
- source byte length at most 4 GiB minus one for u32 span encoding.

Counts and byte arithmetic are checked before allocation. Exact boundaries
succeed where practical and one-over rejects. A producer with a lower profile
records a different named profile and its exact values; it may omit work as
unavailable but cannot truncate a value while claiming `default-v1`.

Unknown profiles are rejected by cacheable readers and may be inspected only
in explicit best-effort diagnostic mode.

## Reader and writer boundary

The implementation exposes dedicated APIs, conceptually:

~~~text
TypedSidecarReadResult  read_typed_sidecar(bytes, limits)
TypedSidecarWriteResult write_typed_sidecar(document, destination)
ReplacementDecision    can_replace_sidecar(old, new, current_source_digest)
~~~

The reader validates duplicate keys, UTF-8/NFC, schema, canonical bytes,
limits, identities, spans, ordering, relations, status dependencies,
disclosure, and completeness before publishing an immutable tooling document.

The writer builds temporary bytes, self-validates them, and atomically replaces
the destination only after the replacement decision. Failure removes the
temporary artifact and leaves the prior valid sidecar intact.

No API returns a KIF interface, semantic cache hit, linker input, or compiler
symbol table from a sidecar.

## Compatibility and privacy

Unknown schema major/version rejects. Compatible optional fields require a
new schema that defines how old readers preserve the status lattice; readers
never guess that an unknown fact is validated.

The existing `kofun.typed-sidecar/v2` schema is one instance of that route. It
adds capture data at the root while reusing ten definitions from the frozen v1
schema, including `nodes`. Reusing a frozen definition preserves that
definition; it does not create an extension point inside it. A successor that
changes an inherited object must own the changed definition instead of
referencing the frozen object under a new root version.

Use this routing rule before changing a producer or schema:

| Requested change | Route |
| --- | --- |
| a new value already admitted by an existing free-form field and by its producer contract | use the existing schema and prove the value through its normal gates |
| a new emitted fact kind, public reason, or node kind declared by a frozen semantic-event or v1 file | leave v1 unchanged and define the successor event/schema route |
| a new root or object shape | define a successor version that owns every changed definition rather than inheriting that definition from frozen v1 |
| a change to accepted semantics or to a v1 compatibility claim | record a separate amendment to DD-028 with compatibility evidence |

The digest failure in the scoped-capture gate points here. Passing that gate by
regenerating its v1 digest is not a versioning route: the manifest is the
tripwire that prevents an unrelated child from silently amending v1.

Logical path remapping is mandatory for reproducible/shared artifacts. Source
snippets and documentation bodies are omitted by default and require an
explicit future privacy field/limit. Another package's private sidecar is not
distributed as a dependency interface.

Adding optional provisional/tooling data is compatible only under a schema
version that old readers can ignore safely. Changing status meaning, NodeId
input, canonicalization, disclosure, or replacement rules requires a new
schema/media version.

## Implementation status and non-goals

`spec/typed-sidecar/check.sh` validates the checked-in JSON Schema, canonical
complete/partial/cancelled examples, invalid trust/status/relation/order/
limit cases, path-remap projection, and stale replacement model. The explicit
single-file `kofun check --emit-typed-sidecar ... --generation ...` path now
projects committed Stage 2 semantic events and atomically emits this document.
The compiler, KIF, package, linker, build cache, and LSP do not consume it.
The exact executable mapping is
`tooling/typed-sidecar/stage2-projection-v1.md`.

This v1 design does not define KIF, compiler cache authority, macro expansion
details, embedded source snippets, a binary transport, remote distribution,
or a second hand-written interface source. No design question remains open.
