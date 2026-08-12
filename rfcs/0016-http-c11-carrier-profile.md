# RFC-0016: HTTP/1.1 core uses the generic bounded carrier profile

- Shepherd: hjosugi
- Opened: 2026-08-11
- Status: accepted
- Decided: 2026-08-11

This RFC decides [#1256](https://github.com/kofun-lang/kofun/issues/1256)
for the accepted client contract and implementation children #1258-#1264. It
defines a scripted C11 Stage 2 profile and claims no live network or TLS client.

## Summary

The first executable HTTP/1.1 core waits for and uses the ordinary generic
types it is meant to ship: owned `Bytes`, bounded `List[Header]`, closed
`HttpError`, and synchronous finite `Stream[Bytes, HttpError]`. A bespoke
monomorphic body protocol is rejected.

The core consumes a pre-parsed `HttpOrigin`, drives a deterministic affine
scripted transport, uses injected cancellation/deadline events rather than wall
time, and fails before allocation or output at fixed numeric bounds. Other
targets refuse this profile until they execute the same carrier and protocol
evidence.

## Motivation

The accepted HTTP contract requires a 64-KiB header limit, ordered duplicate
headers, byte bodies, typed errors, and affine streaming. The current bounded
`List[Int]` carrier cannot represent those semantics, and replacing them with
raw bytes or Int error codes would create a second public API that later has to
be removed.

## Detailed design

### Value and ABI schema

The profile is `kofun.http1-scripted-c11/v1`.

`Bytes` is an owned `{data, length, capacity}` value. Reads borrow its bytes,
edits require unique ownership, and `take` transfers. There is no implicit Text
conversion. Allocation and slicing retain the authority/allocator provenance
required by RFC-0001.

`Header` is `{name: Bytes, value: Bytes}` after validation. The collection is a
bounded `List[Header]`, preserves wire order and duplicates, and uses
case-insensitive ASCII comparison only where HTTP field-name semantics require
it. Public APIs never substitute unindexed raw header bytes.

`HttpOrigin` contains:

- `secure: Bool` for `http`/`https`;
- normalized ASCII host bytes;
- an optional validated port; and
- an origin-form target beginning with `/`.

User-info, fragments, IDNA, and general URL parsing are outside this profile.
The public client receives a value produced by the future URL module.

`HttpError` is a closed ADT whose families remain distinguishable: URL,
connect/write/read scripted transport, protocol/framing, timeout, cancelled,
limit, truncated body, and invalid reuse. Each variant carries an exact phase
and a `retry_safe` fact; it is never collapsed to one Int code.

The body is the ordinary synchronous finite
`Stream[Bytes, HttpError]` with an affine `Subscription`. The generic Stream
contract, not HTTP, owns demand, terminal state, cancellation, and cleanup.
This selects the generic option and makes #31/#1260 a real dependency.

### Scripted transport

A script is a versioned sequence of bounded operations:

`ExpectWrite(bytes)`, `ProvideRead(bytes)`, `Eof`, `Fail(kind)`,
`Cancel(phase)`, and `Deadline(phase)`.

It has one affine generation identity. Each write/read transition consumes the
current transport and returns its successor. Completion/drain can return a
reusable successor; cancellation, protocol failure, or a failed bounded drain
returns only a terminal summary. The final trace records accepted writes,
delivered reads, terminal reason, bytes consumed, and reuse outcome.

Deadlines and cancellation are injected script events. Tests never read wall
time, sleep, or consult a host network.

### Numeric limits

All limits are checked before the allocation or state transition they bound:

| Dimension | v1 limit |
|---|---:|
| serialized request | 1,048,576 bytes |
| header count | 128 |
| header name | 256 bytes |
| header value | 8,192 bytes |
| header block | 65,536 bytes |
| status line | 8,192 bytes |
| chunk-size line | 8,192 bytes |
| chunk count | 65,536 |
| one delivered chunk | 8,388,608 bytes |
| trailer count | 64 |
| trailer block | 32,768 bytes |
| buffered body | 1,048,576 bytes |
| `read_all` hard profile ceiling | 67,108,864 bytes; caller supplies a lower/equal limit |
| early drain | 1,048,576 bytes |
| script operations | 4,096 |

The accepted 64-KiB response-header cap is therefore representable. Exceeding
any dimension yields `LimitExceeded(dimension, limit, observed_at_most)` with
no partial successful response/body value.

### Request and response rules

Request serialization follows the accepted contract: validated method token,
origin-form target, one normalized Host field, caller header order otherwise
preserved, and no CR/LF in field values. Content length and transfer coding
cannot contradict the body mode.

Response framing precedence is: responses with no body by method/status,
validated Transfer-Encoding with terminal chunked, validated Content-Length,
then connection-close framing. Conflicting lengths, invalid transfer coding,
obs-fold, whitespace-smuggling shapes, premature EOF, and bytes after a terminal
script state fail closed.

Fragmentation may split every token boundary and cannot change the result.
Full completion grants reuse only after the framing terminal is consumed. Early
close attempts the bounded drain; exceeding its limit closes and returns no
successor connection.

## Semantics

Given the same request value, configuration, and script, the serialized bytes,
trace, response values, terminal error, and reuse result are byte-identical
across path, allocation address, fragmentation, and declaration order. The
profile performs no DNS, socket, TLS, environment, filesystem, entropy, or
clock operation.

## Diagnostics

Carrier/type/ownership refusals are compiler diagnostics owned by their
respective generic, collection, and affine profiles. HTTP parse/transport
failures are `HttpError` values. Each error identifies phase and bounded
offset/count without echoing secret header/body bytes.

An unsupported backend rejects `kofun.http1-scripted-c11/v1` before emitting an
artifact and names the missing carrier or stream capability. It may not fall
back to a host HTTP library.

## Ownership and effects

`Request` and validated headers are owned values. `Client`, scripted transport,
`Response`, `BodyStream`, and `Subscription` follow the affine transition table
of RFC-0010. A response owns its body; draining to completion yields reusable
transport, while cancellation or excessive drain yields only a copyable
terminal summary. The scripted profile is deterministic `io` against an
injected capability, not a live network effect.

## Alternatives

A monomorphic `HttpBodyStream` is rejected because it creates a second stream
contract and removes the migration pressure needed for the real generic
carrier. Raw header bytes are rejected because callers need ordered validated
headers. Int error codes are rejected because retry and phase semantics would
be lost. Wall-clock deadlines and live loopback tests are rejected as normative
evidence; they may be extra adapter tests later.

## Drawbacks

The first vertical slice waits on generics and product carriers, so it lands
later than a bespoke C struct. The fixed limits reject otherwise valid large
messages. Preserving header order and duplicates costs more than a simple map.

## Compatibility and migration

Category: `additive`. The HTTP client is specified but unimplemented. Selecting
the generic stream means no temporary monomorphic public API is introduced or
later removed. Existing framework HTTP server checkpoints and live network
claims do not change.

## Implementation plan

1. #1257 finishes the independent pure wire oracle.
2. #1258 supplies executable Bytes, Header, HttpOrigin, and error carriers.
3. #1260 supplies the generic synchronous finite stream.
4. #1261-#1263 implement serialization, parsing, and body/reuse state.
5. #1264 integrates the matrix and capability truth.

No child may substitute a host HTTP parser or library.

## Validation

`task http-carrier-profile` validates every chosen carrier and bound and rejects
an undersized header cap, live-network claim, bespoke stream, or unbounded
dimension. The accepted decision also requires the HTTP/stream/ownership
contract gates, `task rfc-registry capabilities release-claims
repository-check`, and full verify.

## Unresolved questions

Live Network/TLS adapters, generic URL parsing/IDNA, compression, HTTP/2,
asynchronous streams, and larger opt-in limits are separate profiles. The
scripted v1 carrier, state, and bounds are closed.
