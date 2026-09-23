# Typed-sidecar tooling codec

`codec.mjs` is the production tooling-only reader, encoder, replacement
decision, and atomic writer for `kofun.typed-sidecar/v1`.
`from-stage2.mjs` independently validates the internal bounded Stage 2 KSE
transaction and projects its compiler-derived facts into that codec. The
complete field mapping and one-way trust boundary are frozen in
`stage2-projection-v1.md`.

It exports:

~~~js
readTypedSidecar(bytes)
encodeTypedSidecar(document)
canReplaceTypedSidecar(oldDocument, newDocument, currentSourceDigest)
writeTypedSidecarAtomic(path, document, {
  currentSourceDigest,
  refreshCurrentSourceDigest?,
  signal
})
~~~

`documentation-index.mjs` joins a validated KIF visibility projection with
the typed sidecar's current validated identities. It emits disclosure-safe
public or exact-package internal documentation indexes without copying
sidecar paths, spans, diagnostic text, or inferred display names. The full
trust model, CLI procedure, limits, and atomic replacement rules are in
[`docs/DOCUMENTATION_INDEX.md`](../../docs/DOCUMENTATION_INDEX.md).

Read and encode return tagged `{ ok: true, ... }` or
`{ ok: false, error }` records. Read documents and result records are
recursively immutable. Replacement decisions are `{ allow, reason }` with
the stable reasons `allow`, `invalid-old`, `invalid-new`, `wrong-file`,
`stale-sequence`, and `source-mismatch`.

The writer validates and encodes before taking a destination lock. A contender
waits with a bounded 10 ms poll / 2 second deadline instead of treating a live
writer as an immediate I/O failure. This lets cross-process contenders observe
the committed generation: the higher generation eventually replaces the
lower, while a lower contender that follows the higher returns stale. While
the lock is held the writer validates the old artifact, writes and flushes a
mode-0600 temporary regular file in the destination directory, optionally
refreshes the current source digest, re-reads the current destination, repeats
the generation/source decision, and atomically renames.
Failure before rename preserves the previous bytes and removes only temporary
files whose device/inode still match those created by this writer.

Errors use bounded codes:

| Code | Class |
| --- | --- |
| `TS001` | invalid UTF-8/BOM/JSON/duplicate key/trailing data |
| `TS002` | schema or canonical form mismatch |
| `TS003` | semantic ID/path/span/order/relation/status violation |
| `TS004` | byte/count/depth/text/edit limit |
| `TS005` | invalid-old or denied replacement |
| `TS006` | cancellation, destination safety, lock, or atomic I/O failure |

This module is non-authoritative by construction. Compiler, KIF, build,
package, and linker paths cannot import it; the focused authority gate checks
that boundary. A typed sidecar can answer tooling queries but can never create
compiler or cache success.

Run the focused gates with:

~~~sh
task typed-sidecar-codec
task typed-sidecar-projector
task documentation-index
~~~

## Synthetic KSE2 transactions

The explicitly versioned successor APIs in `from-stage2.mjs` implement the
synthetic transaction boundary of #1224:

~~~js
encodeStage2SemanticEventsV2(events) // { ok, bytes } or { ok: false, error }
readStage2SemanticEventsV2(bytes)    // { ok, events } or { ok: false, error }
replayStage2SemanticEventsV2(bytes, onEvent) // { ok, event_count, compiler_exit_class }
projectStage2SemanticEventsV2(events) // { ok, document, compiler_exit_class }
emitStage2TypedSidecarV2(bytes, destination, {
  sourcePath, // or currentSourceBytes
  signal
}) // the same tagged write result as emitStage2TypedSidecar
~~~

Common logical records retain their v1 shapes. Capture records use the
`captures.mjs` decoded shape (`event` plus numeric `kind` 8–13); model-only
`wire_hex` and display metadata are not logical transaction fields. Encoding
and projection check the exact logical field sets, serialize the entire
transaction, and independently read and validate the resulting bytes. The
reader returns frozen records only after the header, digest, every frame,
phase order, common semantic closure, and capture relationships all validate.
There is no partial-record return or callback before validation. Replay delivers
frozen records in wire order to a synchronous callback; returning `false` or
throwing refuses delivery and prevents later callbacks. Asynchronous callbacks
are refused. A destination that needs its own atomic commit must buffer until
the validated end and a successful replay result; arbitrary callback side
effects cannot be rolled back. File publication uses the atomic emitter below.

The complete order is source, nodes, identities, pars, tasks, joins, places,
unknowns, captures, references, facts, diagnostics, end. Capture origins join
the committed NodeId/span map and retain `(start, end, NodeId)` source order.
Lifecycle, witness and dynamic-bound nodes must exist; scopes, bindings and
field owner types must name the actual values in the committed identity
namespace with a committed owning node. The source FileId closes ParId
preimages. The first par's external parent must be a committed ScopeId and
other parents follow the section's earlier-scope rule. This closes the
relationships present in the frozen wire; it does not infer missing compiler
scope trees or type field layouts from source text.

KSE2 accepts at most 16,384 events, including 8,384 capture events, 16 MiB of
framed payload, and 16 KiB per field. Capture lists admit 256 origins; common
relation lists retain their 64-entry limit. The public sidecar retains its
own field and storage limits, including 4,096 captures, 16 MiB and depth 128.
All bounds refuse the transaction instead of truncating it. The v1 entrypoints
still refuse major 2 and retain their original 4,096-event/4-MiB profile.

`checked/complete` requires exit class 0 and validated common records without
an error diagnostic. `failed/partial` requires exit class 1–3 and an error
diagnostic. `cancelled/partial` requires exit class 0. A partial outcome can
retain a complete, valid committed capture section, including an empty one.
Every serialized task still requires its join: an interrupted byte stream or
an unfinished task/join section is rejected. Cancellation observation has no
wire event; these APIs consume committed snapshots and do not infer when a
producer observed cancellation. A producer must freeze validated records at
that point and buffer any uncommitted section until it is closed. Compiler
fact production and that production cancellation boundary remain #1225.

Publication uses the existing atomic writer after complete transaction
validation and a current-source byte-length/SHA check, with a refreshed digest
before rename. A cancelled source outcome can publish a valid partial
snapshot; an aborted publication `signal` refuses the write. Corruption,
source changes, replay, wrong FileId, cancellation and I/O refusal preserve the
previous destination. Errors use the same bounded ETS03–ETS06 result family;
incorrect top-level API argument types may throw `TypeError`.

`task typed-sidecar-captures` exercises an independent full-frame encoder,
the frozen capture oracle, complete/failed/cancelled snapshots, upstream
identity and span mutations, successor bounds, and atomic replacement. These
synthetic successes do not claim compiler capture derivation or change the
ordinary compiler's E2S154 refusal.
