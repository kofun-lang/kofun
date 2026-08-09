# Stage 2 semantic events v1

`semantic_events.h` is the bounded value-record boundary between the Stage 2
semantic layer and non-authoritative tooling. A producer calls exactly one
`kofun_semantic_begin`, zero or more record callbacks in phase order, and
exactly one committed `kofun_semantic_end`. Callbacks receive immutable values;
a sink must copy every byte view it retains before returning.
`kofun_semantic_cancellation_observed` freezes the validated prefix before a
cancelled end; it is an observation marker and emits no KSE record.
`kofun_semantic_replay_stream` first performs the complete KSE digest, schema,
semantic-closure, and byte-for-byte canonical validation without calling the
destination. Only after that succeeds does it decode the immutable logical
records into an independent sink. Destination rejection returns `ETS03` as a
tooling failure; it cannot turn into a source-language diagnostic.

The API does not expose parser, HIR, resolver, or ownership-checker pointers.
It does not emit the public typed-sidecar JSON, and neither the API nor its
internal stream is accepted by the compiler, KIF, build, linker, package, or
cache authority paths. Sink rejection is a tooling failure (`ETS03` or
`ETS04`), not a source-language error.

`kofun_semantic_validate_text` is the shared bounded UTF-8/NFC policy.
`kofun_semantic_validate_logical_path` additionally rejects absolute, drive,
URI-like, backslash, empty, `.`/`..`, and Unicode-control path forms. Producers
must apply this public validator before invoking compiler authority or any sink
callback; the reference sink applies the same validator again at begin.

`semantic_producer.c` is the production source adapter. It invokes the
Stage 2 lexer, parser, scope-HIR builder, and ownership checker directly in the
compiler translation unit, buffers only the bounded values defined in
`semantic_events.h`, and then emits them in phase order. It does not parse
rendered command output. Nullable parser, scope-HIR, and lowering observation
hooks exist only in the C seed when the internal adapter is compiled;
ordinary seed execution leaves them null. They neither alter compiler output
nor claim a corresponding sink surface in canonical `compiler.kofun`.
The adapter covers the current single-file subset:
module root, functions, parameters, lexical scopes, immutable/mutable locals,
flat ADTs and constructors, function/constructor calls, local references,
value `if`/`match`, `Int`/`Bool`/`Text` facts, and the current borrowed
collection ownership failure. Successful units additionally carry the bounded
`pure < io` function summary defined in `../../spec/effects/pure-io-v1.md`;
failed or cancelled units do not fabricate it. Later import, generic, trait,
macro, general effect-row, and recursive-ADT facts are not fabricated.

Identity inputs reuse the accepted repository contracts rather than C layout:

- anonymous PackageId, FileId, and synthetic-root ModuleId hash the exact
  canonical text payloads in `spec/modules/package-roots.md` and
  `spec/modules/source-file-mapping.md` with the #303 framed SHA-256 domains;
- value/type NamespaceIds and function/ADT/constructor SymbolIds use the
  canonical namespace text and SymbolId KIF records from
  `spec/modules/module-identity.md`;
- NodeId uses domain `kofun.sidecar.node/v1` over
  `FileId || syntax-kind:u8 || start:u32be || end:u32be ||
  occurrence:u32be`; and
- the current numeric scope-HIR ScopeId/BindingId is preserved through the
  internal framed domains `kofun.stage2.scope/v1` and
  `kofun.stage2.binding/v1`, over `FileId` followed by the exact committed HIR
  key `hir-scope:<decimal-id>` or `hir-binding:<decimal-id>`. These are not
  #303 declaration identities.

The #303 frame is `"KOFUN\0" || domain-length:u16be || domain ||
payload-length:u32be || payload`. Absolute checkout paths, host addresses,
compiler-private indices other than the explicitly committed scope-HIR IDs,
and rendered diagnostics never enter these payloads.

## Commit and status rules

The reference sink enforces these phases:

1. validated source bytes, digest, anonymous PackageId/ModuleId/FileId, and
   logical path;
2. nodes after the token/span basis commits;
3. semantic identities;
4. references;
5. type/effect facts followed by ownership/origin facts;
6. structured diagnostics;
7. iterative dependency/status/disclosure closure and the end record.

A later failure cannot mutate an earlier record. An error record names at
least one structured diagnostic. A validated record depends only on validated
nodes. A provisional record names at least one known non-validated dependency.
Unavailable facts and targets carry a bounded reason and no fabricated value.
`complete/checked` contains only validated records and no error diagnostic;
`partial/failed` contains an error diagnostic. After cancellation is observed,
no new validated record is accepted. Cancellation before source/token
commitment produces no stream.

The source's exact compiler exit class is closed against the end record:
`checked/complete` and `cancelled/partial` require exit class `0`;
`failed/partial` requires one of `1`, `2`, or `3`. Re-signing a KSE with a
different but individually valid exit/status value therefore still fails
semantic validation.

Every visible reference contains exactly one identity kind/value target, and
that exact `(kind, value)` must name an identity record already committed in
phase 3; an arbitrary or forward target ID is invalid regardless of reference
status. Each `(kind, value)` pair globally names exactly one owner NodeId, so
two owners cannot publish the same pair. This singular identity closure makes
visible-target lookup unambiguous. A validated visible reference additionally
requires the target identity itself to be validated. Hidden and unavailable
references cannot be validated.
They contain at most a safe identity kind and a public reason discriminator;
their target value is required to be zero and is never serialized. Source
spans are half-open UTF-8 byte offsets bounded by the committed source length.

Reference namespaces close identity kinds as follows. The mapping applies to
visible targets and to every non-zero safe target kind on a hidden or
unavailable reference.

| Reference namespace | Permitted identity kind |
| --- | --- |
| value | binding or symbol |
| type | type |
| constructor | constructor |

Reason fields are not free-form presentation or debug text. Every non-empty
fact reason and every hidden/unavailable reference reason is exactly one of
this fixed v1 public allowlist:

- `unresolved-current-stage2-reference`
- `type-not-available-in-current-subset`
- `move-after-borrow`
- `visibility-restricted`
- `unsupported-current-stage2-feature`
- `cancelled-before-analysis`
- `effect-io-root-print`
- `effect-io-callee` (the fact dependency identifies the resolved callee)

Names, source or checkout paths, inaccessible target values, rendered
diagnostics, and other private text are therefore mechanically rejected at
the sink boundary rather than redacted heuristically.

## Internal KSE frame

The internal media identity is
`kofun-stage2-semantic-events/v1`. It is never installed or distributed.
All integers are unsigned big-endian.

```text
magic:         4 bytes  KSE\0
major:         u16be    1
minor:         u16be    0
event_count:   u32be
payload_bytes: u32be
events:        repeated bounded frames
digest:        32 raw SHA-256 bytes over the 16-byte header and events
```

Each event is:

```text
kind:u8 flags:u8 field_count:u16be payload_bytes:u32be
field := tag:u8 wire_type:u8 reserved:u16be length:u32be payload:length
```

Flags and `reserved` are zero in v1. Fields occur once in strictly ascending
tag order. Unknown event kinds, tags, flags, wire types, enum values, duplicate
fields, non-NFC UTF-8, truncation, trailing bytes, count/length mismatch, and
digest mismatch reject before records are published.

Wire types are fixed:

| Value | Wire type | Payload |
| ---: | --- | --- |
| 1 | bytes | bounded field-specific canonical bytes |
| 2 | utf8 | bounded UTF-8 in NFC |
| 3 | id | exactly 32 raw bytes |
| 4 | u8 | one byte |
| 5 | u32 | four bytes |
| 6 | u64 | eight bytes |
| 7 | span | `start:u32be end:u32be` |
| 8 | id-list | zero or more packed 32-byte IDs |
| 9 | u32-list | zero or more packed `u32be` values |

## Event and field table

This table is the v1 contract. #609 must map it rather than infer fields from
C layout.

| Event | Kind | Tag | Field | Wire |
| --- | ---: | ---: | --- | --- |
| source/begin | 1 | 1 | PackageId | id |
|  |  | 2 | ModuleId | id |
|  |  | 3 | FileId | id |
|  |  | 4 | logical path | utf8 |
|  |  | 5 | source byte length | u64 |
|  |  | 6 | exact source SHA-256 | id |
|  |  | 7 | language edition | utf8 |
|  |  | 8 | semantic compatibility | utf8 |
|  |  | 9 | caller generation | u64 |
|  |  | 10 | exact compiler exit class (`0`, `1`, `2`, or `3`) | u8 |
| node | 2 | 1 | NodeId | id |
|  |  | 2 | node kind | u8 |
|  |  | 3 | half-open source span | span |
|  |  | 4 | fact status | u8 |
|  |  | 5 | sorted dependency NodeIds | id-list |
|  |  | 6 | sorted diagnostic IDs | id-list |
| identity | 3 | 1 | owner NodeId | id |
|  |  | 2 | identity kind | u8 |
|  |  | 3 | identity value | id |
|  |  | 4 | fact status | u8 |
| reference | 4 | 1 | ReferenceId | id |
|  |  | 2 | source NodeId | id |
|  |  | 3 | namespace (closed against target kind above) | u8 |
|  |  | 4 | use span | span |
|  |  | 5 | fact status | u8 |
|  |  | 6 | target shape | u8 |
|  |  | 7 | safe namespace-compatible target identity kind | u8 |
|  |  | 8 | visible target identity value | id |
|  |  | 9 | hidden/unavailable reason | utf8 |
|  |  | 10 | sorted diagnostic IDs | id-list |
| fact | 5 | 1 | owner NodeId | id |
|  |  | 2 | type/effect/ownership/origin kind | u8 |
|  |  | 3 | fact status | u8 |
|  |  | 4 | bounded display | utf8 |
|  |  | 5 | bounded unavailable/error reason | utf8 |
|  |  | 6 | sorted dependency NodeIds | id-list |
|  |  | 7 | sorted diagnostic IDs | id-list |
| diagnostic | 6 | 1 | DiagnosticId | id |
|  |  | 2 | stable language code | utf8 |
|  |  | 3 | category | utf8 |
|  |  | 4 | severity | u8 |
|  |  | 5 | template ID | utf8 |
|  |  | 6 | primary FileId | id |
|  |  | 7 | primary span | span |
|  |  | 8 | bounded fallback presentation | utf8 |
|  |  | 9 | sorted affected IDs | id-list |
|  |  | 10 | sorted remedy IDs | u32-list |
|  |  | 11 | truncation bit | u8 |
|  |  | 12 | sorted related locations | bytes |
|  |  | 13 | sorted remedy edits | bytes |
| end | 7 | 1 | source status | u8 |
|  |  | 2 | completeness | u8 |

Reference tag 8 is present only for a visible target. Tag 9 is present only
for hidden or unavailable targets. Tag 10 is always present.

Diagnostic tag 12 is exactly
`count:u16be || repeated(file-id:32 || start:u32be || end:u32be ||
label-length:u16be || label:label-length)`. Tag 13 is exactly
`count:u16be || repeated(remedy-id:u32be || file-id:32 || start:u32be ||
end:u32be || replacement-length:u16be ||
replacement:replacement-length)`. The nested count and every nested string
length are part of the bytes payload; no padding, terminator, or trailing byte
is permitted. Labels and replacements are UTF-8/NFC even though the enclosing
canonical list uses the `bytes` wire.
Every edit names one of tag 10's remedy IDs. The current single-file profile
requires primary, related, and edit FileIds to equal the committed source
FileId. Related locations and edits are sorted by their complete tuple and
must be unique.

## Bounds and atomicity

The checked v1 profile permits 4,096 total events, 4 MiB of framed event
payload, 4,096 bytes per string or nested diagnostic list, and 64
dependencies, diagnostics, affected IDs, remedies, related locations, or edits
per record. The current Stage 2 adapter additionally caps compiler-derived
function declarations at 64; it token-scans that bound before allocating the
authority observer transaction and returns `ETS04` when exceeded. Counts and
lengths are checked before allocation and writing. IDs and set-valued lists
use canonical byte order.

The reference sink buffers and validates the complete logical transaction,
builds the header and digest, validates the resulting bytes with its canonical
decoder, writes an exclusive temporary file, flushes and synchronizes it, and
renames only the validated file. The public replay API applies that same full
validation before sending any logical record to a separate destination sink.
Every commit failure removes the temporary file and preserves the prior
destination.

`ETS03` reports phase, relation, status, disclosure, or framing invariants.
`ETS04` reports bounded-resource, UTF-8/NFC encoding, allocation, or I/O
failure. Details contain only a record index, event kind, and bounded safe
message; absolute paths and private targets are not included.
