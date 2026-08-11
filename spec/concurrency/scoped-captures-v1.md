# Scoped-capture analysis contract v1

Status: normative implementation input for issues #1220–#1225. The accepted
language semantics remain those of `scoped-parallelism-v1.md`; this document
freezes analysis and tooling representation only.

Issue: [#1219](https://github.com/kofun-lang/kofun/issues/1219)

## 1. Boundary

The analysis schema is `kofun-scope-hir/v2` under the one closed profile
`kofun.stage2-analysis/scoped-captures/v1`. It represents scoped-parallel
identities, checked places, explicit unknowns, and derived task captures.

This is **not** `kofun.selfhost-hir/v2`. It neither revises the frozen
`kofun.selfhost-hir/v1` profile nor claims that the self-host frontend or C11
backend consumes these records. It does not parse or accept `par`, derive a
capture from production source, decide capture conflicts, start a task, lower a
backend operation, or publish a release capability. Ordinary compilation must
continue to refuse scoped parallelism with `E2S154` until the later integration
children explicitly change that boundary.

The executable model takes already resolved synthetic observations. It is a
pure reference for identity, normalization, merging, ordering, KSE2 capture
frames, and typed-sidecar projection. Its success is not evidence that a
production compiler or codec implements the contract.

## 2. Canonical scope-HIR document

A document is canonical UTF-8 JSON with no BOM. Object keys use ascending byte
order, arrays use the semantic order below, there is no insignificant
whitespace, and the document ends in one newline. The schema file is
`scoped-captures-v1/kofun.scope-hir.v2.schema.json`.

The root has exactly these fields:

| Field | Meaning |
| --- | --- |
| `schema` | exactly `kofun-scope-hir/v2` |
| `profile` | exactly `kofun.stage2-analysis/scoped-captures/v1` |
| `file_id` | the resolved 32-byte FileId, rendered as 64 lowercase hex digits |
| `root_scope_id` | the resolved enclosing ScopeId; this is the one permitted parent link not represented by a `par` record |
| `limits` | every fixed integer in §9, with no extra or omitted field |
| `records` | the closed record sequence in §3 |

Every identity is a nonzero 32-byte value rendered as 64 lowercase hex digits.
Every integer other than a constant slice bound is a JSON integer. A
`lexical_index`, field `ordinal`, and span endpoint is in `0..4294967295`.
A span is `{ "start": u32, "end": u32 }` and is non-empty and half-open:
`start < end`.

Display metadata has exactly this shape:

```json
{"disclosure":"visible","text":"items"}
```

or:

```json
{"disclosure":"hidden","text":null}
```

Visible text is non-empty NFC UTF-8, contains no C0/DEL control character, and
is at most 128 UTF-8 bytes. A name that is not accessible to the observer must
use the hidden form; retaining its text beside `hidden` is invalid. Display
metadata is never an identity, equality, merge, or ordering input and is not
carried by the KSE2 or typed-sidecar capture projection.

## 3. Records and link closure

Every record has exactly the fields in this table. `id` is derived by §4 and
is never supplied by spelling or allocation address.

| Record | Exact fields | Meaning and links |
| --- | --- | --- |
| `par` | `record`, `id`, `node_id`, `scope_id`, `parent_scope_id`, `scope_token_binding_id`, `lexical_index`, `display` | One lexical `par`. `parent_scope_id` is `root_scope_id` or an earlier `par.scope_id`. The token is a resolved BindingId. |
| `task` | `record`, `id`, `par_id`, `spawn_node_id`, `lambda_node_id`, `handle_binding_id`, `lexical_index`, `display` | One direct lexical spawn. `par_id` names a record in this document. The handle is a resolved BindingId. |
| `join` | `record`, `id`, `task_id`, `join_kind`, `node_id` | Exactly one per task. `join_kind` is `explicit` with a resolved NodeId, or `scope-exit` with JSON `null`. |
| `place` | `record`, `id`, `base_binding_id`, `projections`, `canonical_bytes`, `display` | One unique known place. The base is a resolved BindingId. Projection fields are below; `canonical_bytes` is lowercase hex for §5. |
| `unknown` | `record`, `id`, `task_id`, `witness_node_id`, `reason`, `canonical_bytes` | One explicit unavailable place. Both links are resolved and the task is in this document. |
| `capture` | `record`, `id`, `task_id`, `target_kind`, `target_id`, `mode`, `origins` | One normalized task/target pair. The target names a matching `place` or same-task `unknown`. `origins` are unique source-ordered `{node_id, span}` records. |

The field `record` is exactly the row name. Record IDs are globally unique.
Par ScopeIds are unique and none equals `root_scope_id`. Each task has exactly
one join. A capture cannot name a record of the wrong kind, an absent record,
or an unknown owned by another task. The base BindingId, owner TypeId, bound
NodeId, lifecycle NodeIds, and origin NodeIds are upstream resolved identities;
zero or display spelling is not a substitute.

The known projection vocabulary is closed:

```json
{"kind":"field","owner_type_id":"HEX64","ordinal":0,
 "display":{"disclosure":"visible","text":"field"}}
```

```json
{"kind":"slice","lower":BOUND,"upper":BOUND}
```

A field's semantic identity is its resolved owner TypeId plus declaration
ordinal. Renaming the type, field, base binding, scope token, or task handle
does not alter place equality. A slice bound is exactly one of:

```json
{"kind":"constant","value":"-12"}
{"kind":"node","node_id":"HEX64"}
```

Constant i64 values use canonical decimal text so all signed 64-bit values are
representable without depending on a JSON number implementation. `0` is the
only zero form; a leading zero or `+` is invalid; the inclusive range is
`-9223372036854775808..9223372036854775807`. A dynamic bound uses the resolved
expression NodeId, never its source spelling. When both bounds are constants,
`lower > upper` is malformed and must be refused. `lower == upper` is the valid
empty half-open slice required by the accepted scoped-parallelism semantics.

## 4. Stable identity preimages

Every new ID uses SHA-256 over the #303 frame:

```text
"KOFUN\0" || domain_length:u16be || domain:utf8 ||
payload_length:u32be || payload
```

IDs inside payloads are the 32 raw bytes, not their hex rendering. Integers are
unsigned big-endian. Tags are one byte. The preimages are:

| ID | Domain | Payload |
| --- | --- | --- |
| ParId | `kofun.scope-hir.par/v2` | `FileId || ScopeId || par NodeId` |
| TaskId | `kofun.scope-hir.task/v2` | `ParId || lexical_index:u32be || spawn NodeId || lambda NodeId || handle BindingId` |
| JoinId | `kofun.scope-hir.join/v2` | `TaskId || join-kind:u8 || explicit NodeId?`; join kind is 1 explicit, 2 scope-exit, and the NodeId is present only for explicit |
| PlaceId | `kofun.scope-hir.place/v2` | the complete canonical place bytes in §5 |
| UnknownId | `kofun.scope-hir.unknown/v2` | `TaskId || reason:u8 || witness NodeId` |
| CaptureId | `kofun.scope-hir.capture/v2` | `TaskId || target-kind:u8 || target ID`; target kind is 1 place, 2 unknown |

Capture mode and origins are deliberately absent from CaptureId: a later
checked use may strengthen `read` to `edit` or `take` without inventing a
second semantic capture. Displays are absent from every preimage.

The reference fixture freezes exact golden IDs for all six domains. The gate
mutates every produced ID and requires the validator to reject the mismatched
preimage.

## 5. Place and unknown bytes

A known place has this exact byte string:

```text
0x4b 0x50 0x4c 0x00 0x02        # "KPL\0", format 2
base BindingId:32
projection_count:u8
projection*

field projection := 0x01 || owner TypeId:32 || declaration_ordinal:u32be
slice projection := 0x02 || lower-bound || upper-bound
constant bound   := 0x01 || signed_i64_twos_complement_be
node bound       := 0x02 || NodeId:32
```

The projection count is `0..8`. The base and ordered projection bytes are the
entire equality key. Field display text and source spelling never enter it.

An explicit unknown has:

```text
0x4b 0x55 0x4e 0x00 0x02        # "KUN\0", format 2
TaskId:32 || reason:u8 || witness NodeId:32
```

The reason vocabulary and tags are closed:

| Tag | JSON reason | Meaning |
| ---: | --- | --- |
| 1 | `unresolved-call` | the checked call target or summary is unavailable |
| 2 | `projection-depth-exceeded` | a candidate place has more than eight projections |
| 3 | `unnameable-place` | the checked expression cannot be represented as a base plus projections |

Depth nine is never truncated to depth eight. The observation model converts
depth `9..64` into reason 2 using the originating NodeId. A serialized `place`
with nine projections is invalid. Candidate depth above 64 is a bounded-input
failure, not another unknown.

## 6. Merge and canonical record order

Modes form the finite order:

```text
read < edit < take
```

Within one TaskId, observations with the same target identity produce one
CaptureId. Their mode is the maximum above and their origins have unique
NodeIds and are ordered by `(span.start, span.end, NodeId raw bytes)`. Repeating
one NodeId with another span is invalid because a resolved NodeId commits one
source span. Unknowns have an occurrence identity, so only the same reason at
the same witness NodeId is an exact duplicate. Displays do not participate.
When several displays describe one PlaceId, the display attached to the
earliest origin is retained only for the internal HIR record. If the earliest
origin ties exactly, its display metadata must also be identical; conflicting
metadata is invalid rather than resolved by input array order.

An unknown is one unavailable source occurrence: its capture has exactly one
origin and that origin's NodeId is the unknown's `witness_node_id`. A different
origin or a second origin is invalid rather than a merge. Known-place captures
may retain up to the general origin limit below.

The record phases and order are exact:

1. `par`, by dense global `lexical_index` starting at zero;
2. `task`, by parent par order then a dense per-par `lexical_index`;
3. `join`, exactly the corresponding task order;
4. `place`, by unsigned lexicographic canonical-place bytes;
5. `unknown`, by unsigned lexicographic canonical-unknown bytes;
6. `capture`, by task order, then unsigned target canonical bytes, then mode
   order `read`, `edit`, `take`.

An input observation container may arrive in another array order. The pure
model normalizes it. A serialized scope-HIR, KSE2 section, or typed-sidecar
capture array in another order is invalid rather than silently resorted by a
consumer.

## 7. KSE2 capture section

KSE2 has media identity `kofun-stage2-semantic-events/v2`. It retains the KSE
frame grammar, wire-type numbers, digest construction, and v1 event definitions
in `bootstrap/stage2/semantic-events-v1.md`; the header is `KSE\0`, major 2,
minor 0. It has its own larger, fixed bounds below. This does not alter or make
a v1 reader accept v2.

In a complete v2 transaction the capture section occurs after source, node,
and identity events, and before reference, fact, diagnostic, and end events.
Within the section the six record phases above are preserved. The contract
schema models this section as structured JSON and freezes the concatenated
event frames in `capture_frames_hex`; it does not pretend the section alone is
a complete KSE transaction. #1224 owns the full encoder, decoder, digest,
replay, cancellation, and atomic-publication implementation.

Each frame still is:

```text
kind:u8 flags:0 field_count:u16be payload_bytes:u32be
field := tag:u8 wire:u8 reserved:0:u16be length:u32be payload
```

Fields occur once in ascending tag order. The new field table is:

| Logical event | Kind | Tag | Field | Wire |
| --- | ---: | ---: | --- | --- |
| par | 8 | 1 | ParId | id |
|  |  | 2 | par NodeId | id |
|  |  | 3 | ScopeId | id |
|  |  | 4 | parent ScopeId | id |
|  |  | 5 | scope-token BindingId | id |
|  |  | 6 | lexical index | u32 |
| task | 9 | 1 | TaskId | id |
|  |  | 2 | ParId | id |
|  |  | 3 | spawn NodeId | id |
|  |  | 4 | lambda NodeId | id |
|  |  | 5 | handle BindingId | id |
|  |  | 6 | lexical index | u32 |
| join | 10 | 1 | JoinId | id |
|  |  | 2 | TaskId | id |
|  |  | 3 | join kind: 1 explicit, 2 scope-exit | u8 |
|  |  | 4 | explicit join NodeId; absent at scope exit | id |
| place | 11 | 1 | PlaceId | id |
|  |  | 2 | base BindingId | id |
|  |  | 3 | §5 canonical place bytes | bytes |
| unknown | 12 | 1 | UnknownId | id |
|  |  | 2 | TaskId | id |
|  |  | 3 | witness NodeId | id |
|  |  | 4 | closed reason tag | u8 |
|  |  | 5 | §5 canonical unknown bytes | bytes |
| capture | 13 | 1 | CaptureId | id |
|  |  | 2 | TaskId | id |
|  |  | 3 | target kind: 1 place, 2 unknown | u8 |
|  |  | 4 | target ID | id |
|  |  | 5 | mode: 1 read, 2 edit, 3 take | u8 |
|  |  | 6 | origin NodeIds in source order | id-list |

The logical place event exposes decoded projections matching tag 3; a decoder
must reject a mismatch rather than trust one view. Displays never enter a
frame. Origin spans are obtained by joining the NodeIds to the already
committed node phase rather than duplicating presentation text.

The pure projection validator is invoked as
`validateKse2CaptureSection(section, matchingScopeHir)`. The matching scope-HIR
argument is mandatory: it closes every ID preimage, link, projection, unknown
witness, phase, and canonical-order relationship. Schema-only validation is
structural evidence, not semantic KSE2 validation. #1224's full-stream decoder
must establish the same relationships from decoded transaction state rather
than invoking this analysis-only helper without a scope-HIR document.

## 8. Typed-sidecar v2 projection

`spec/typed-sidecar/kofun.typed-sidecar.v2.schema.json` defines
`kofun.typed-sidecar/v2`. All common root properties reference their frozen v1
schema definitions. V2 changes exactly these root facts:

- `schema` is `kofun.typed-sidecar/v2`;
- `limits.profile` is `default-v2`;
- `capture_profile` is the analysis profile named above; and
- required `captures[]` contains at most 4,096 structured capture records.

A capture has exactly `id`, `task_id`, `mode`, `origin_node_ids`, and `target`.
The IDs and mode match the scope-HIR/KSE2 records. Origins are unique and keep
source order. In a complete projected transaction each origin must name an
already committed node; #1224's full validator must close that relationship
before publication. The sidecar root `file.file_id` must equal the scope-HIR
`file_id`; a projector must reject captures from another file. Every identity
introduced below `captures[]` is nonzero; the frozen v1 zero sentinel is not a
valid capture, task, target, owner, bound, witness, or origin identity.

A known target is:

```json
{
  "kind": "place",
  "place": {
    "id": "PLACE_ID",
    "base_binding_id": "BINDING_ID",
    "projections": [
      {"kind":"field","owner_type_id":"TYPE_ID","ordinal":1},
      {"kind":"slice","lower":{"kind":"constant","value":"0"},
       "upper":{"kind":"node","node_id":"NODE_ID"}}
    ],
    "canonical_bytes": "..."
  }
}
```

An unavailable target is:

```json
{
  "kind": "unknown",
  "unknown": {
    "id": "UNKNOWN_ID",
    "reason": "unresolved-call",
    "witness_node_id": "NODE_ID",
    "canonical_bytes": "..."
  }
}
```

There is no display/name/label/text field anywhere below `captures[]`.
Inaccessible names therefore cannot be repaired by redaction after encoding;
the schema and model refuse their presence at the boundary. The whole sidecar
remains `authoritative: false` and cannot be compiler, KIF, cache, package, or
linker input.

## 9. Fixed profile limits

| Limit field | Value | Applies to |
| --- | ---: | --- |
| `document_bytes` | 16,777,216 | canonical scope-HIR bytes and model input bytes |
| `pars` | 64 | par records per document |
| `tasks` | 64 | total task records per document |
| `capture_observations_per_task` | 256 | pre-merge synthetic observations |
| `captures_per_task` | 64 | normalized captures |
| `origins_per_capture` | 256 | merged source origins |
| `projection_depth` | 8 | known place projections |
| `candidate_projection_depth` | 64 | bounded over-depth observation before refusal |
| `records` | 8,384 | all scope-HIR records |
| `display_bytes` | 128 | one visible display string |

KSE2 fixes a distinct profile so the required 64 tasks times 64 captures fit
without weakening or truncation:

| KSE2 limit field | Value |
| --- | ---: |
| `events` | 16,384 total transaction events |
| `capture_events` | 8,384 events in this section |
| `event_bytes` | 16,777,216 framed payload bytes |
| `field_bytes` | 16,384 bytes in one field |
| `relations` | 256 IDs in one capture origin list |

The 8,384 record/event bound is derived from 64 pars, 64 tasks, 64 joins,
4,096 distinct targets, and 4,096 captures. Thus the full 64-by-64 capture
cardinality fits without relying on target sharing. The 16 MiB HIR byte bound
also admits that full-cardinality normalized unknown-target document.

The KSE1 limits remain 4,096 events, 4 MiB, 4,096 bytes, and 64 relations;
none is widened in place. A full KSE2 transaction that exceeds its own limits
is a bounded tooling failure and may not truncate captures or weaken compiler
analysis. The typed-sidecar v2 storage bound is 16 MiB, depth 128, and 4,096
capture records.

## 10. Executable gate and frozen v1 boundary

Run:

```sh
task concurrency-capture-contract
```

The gate validates canonical and mutated instances against all three schemas,
recomputes the canonical fixture twice,
checks hard-coded ID/place/KSE byte goldens, exercises strongest-mode merging,
and applies mutations to every record field plus IDs, links, phases, order,
integer/text bounds, privacy, reasons, and limits. It also checks
`v1.sha256`, which freezes the existing selfhost-HIR v1 contract and 46-row
profile, KSE v1 contract/header, typed-sidecar v1 schema, and its canonical
examples. The profile has exactly 46 data rows (47 lines with its header).

The compatibility gates remain independent and must also pass:

```sh
task scoped-parallelism
sh bootstrap/selfhost/check-profile.sh
sh spec/typed-sidecar/check.sh
```

No v1 file is extended in place. A v1 reader refuses the new schema names, and
the new contract does not change the bytes emitted for any v1 input.
