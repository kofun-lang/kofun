# The closed HttpError ADT (v1)

`HttpError` for the scripted HTTP/1.1 core (RFC-0016, #1258), delivered by
[#1697](https://github.com/kofun-lang/kofun/issues/1697) on C11 Stage 2. The
decision is
[RFC-0016/A01](../rfcs/0016-http-c11-carrier-profile.md); the machine-readable
form is `spec/native-toolchain-v1/contract.json` `http_carrier.error`, which
`task http-carrier-profile` validates and `task http-client-errors` renders into
Kofun and compiles. Where this prose and the contract disagree, the contract
wins and the gate fails.

## The closed set

v1 is the four kinds the #1257 oracle (`tests/http/client-model`) can produce,
in this order, which is also the constructor tag order:

| Kind (oracle) | Constructor | Payload record | Fields |
|---|---|---|---|
| `protocol` | `Protocol` | `ProtocolDetail` | `phase: Int`, `retry_safe: Bool`, `offset: Int` |
| `limit-exceeded` | `LimitExceeded` | `LimitDetail` | `phase`, `retry_safe`, `dimension: Int`, `limit: Int`, `observed_at_most: Int` |
| `body-truncated` | `BodyTruncated` | `TruncatedDetail` | `phase`, `retry_safe`, `offset` |
| `transport` | `Transport` | `TransportDetail` | `phase`, `retry_safe`, `cause: Int`, `offset` |

```kofun
type HttpError =
    | Protocol(detail: ProtocolDetail)
    | LimitExceeded(detail: LimitDetail)
    | BodyTruncated(detail: TruncatedDetail)
    | Transport(detail: TransportDetail)
```

Every kind carries a phase and a `retry_safe` fact, and they stay separate
fields: nothing is collapsed to one `Int` code, which is what RFC-0016 forbids.
A payload is one **flat record** because that is what the compiler can carry
([`spec/adt-record-payload-v1.md`](adt-record-payload-v1.md)): `Int` and `Bool`
fields only, so phase, cause, and dimension are `Int` codes with a registry
rather than enums (an enum-typed record field is `E2S32`).

## The registry

Codes are positive and **no registry assigns 0**: a zero-initialized record
would otherwise read as a real phase, cause, or dimension.

| Registry | Codes |
|---|---|
| `phase` (the oracle's `PHASES`, in order) | `write` 1, `head` 2, `body` 3, `drain` 4 |
| `cause` (a transport error's) | `failed` 1, `cancelled` 2, `deadline` 3 |
| `dimension` (the 15 core `http_carrier.limits` rows, in contract order) | `request_bytes` 1, `header_count` 2, `header_name_bytes` 3, `header_value_bytes` 4, `header_total_bytes` 5, `status_line_bytes` 6, `chunk_line_bytes` 7, `chunk_count` 8, `chunk_bytes` 9, `trailer_count` 10, `trailer_total_bytes` 11, `buffered_body_bytes` 12, `read_all_hard_bytes` 13, `early_drain_bytes` 14, `script_operations` 15 |

`host_bytes` and `target_bytes` are not dimensions: they refuse an origin
construction (`R039`, `R040`), not a response.

The oracle's four caller limits map onto the ceilings #1258 Q2(e) chose, so a
`LimitExceeded` from an oracle script has `dimension` 5 for `max_header_bytes`, 2
for `max_headers`, 9 for `max_chunk_bytes`, and 13 for `max_body_bytes`.

## The other families

RFC-0016 names more families than the oracle can reach. v1 defines the four and
projects the rest, so the RFC stays the contract:

| RFC-0016 family | Becomes |
|---|---|
| URL | `Protocol` for a malformed URL value; `Transport` (cause `failed`) for a name that does not resolve |
| connect, write, read | `Transport`, cause `failed`, the phase saying where |
| protocol / framing | `Protocol` |
| timeout | `Transport`, cause `deadline`, with its phase (RFC-0016's `Deadline(phase)`) |
| cancelled | `Transport`, cause `cancelled` |
| limit | `LimitExceeded` |
| truncated body | `BodyTruncated` |
| invalid reuse | `Protocol` |

`docs/stdlib/http-client.md` also names `Dns`, `Tls`, and `RedirectLimit`. They
are not RFC-0016 families and nothing at the scripted boundary can produce them,
so this table does not place them; whoever adds a boundary that can produce one
decides its kind then, as an amendment.

`Deadline` is an injected event, never a clock read. The #1257 oracle gained a
`deadline` operation (`at` a phase, like `fail` and `cancel`); the model answers
it as kind `transport`, detail `the deadline elapsed`, with the same
`retry_safe` rule as a transport failure. Five committed scripts cover it.

## `retry_safe`

`retry_safe` is the oracle result's own field, carried per error: a transport
failure or deadline before any response byte on an idempotent request is `true`;
every other error, and every error after a response byte, is `false`. Retry is
the caller's policy; the client never retries.

## What the oracle does and does not say

The gate projects every error the committed oracle corpus produces (44 results:
21 protocol, 5 limit, 5 truncation, 13 transport) onto an `HttpError`, compiles
the program through Stage 2, and compares its output with what the oracle's
results and this registry say. The oracle records:

- `kind`, `retry_safe`, and `at` (the stream offset the model had reached), which
  become the constructor, `retry_safe`, and `offset`;
- the injected `fail`, `cancel`, or `deadline` and its phase, in the trace, which
  become a transport error's `cause` and `phase`;
- for `limit-exceeded`, a detail that begins with the caller limit's name, and
  the script's limit, which become `dimension` and `limit`.

It does **not** record a phase for an error the model raised itself, or any
observed size. So the gate assigns `head` before the framing decision and `body`
after it (the only two places the model raises those errors), and does not
project `observed_at_most` at all. A producer (#1261, #1262) fills what the
oracle cannot say; if one needs the oracle to say it, the oracle gains the field
in that child, with the corpus regenerated, rather than here.

## What v1 does not check

The codes are `Int`, as #1258 Q1(b) chose, so the compiler does not refuse a
`phase` of 99 or a `dimension` of 0. The registry is held by the contract, the
gate, and the projection; a checked construction in the style of
`stage2_http_origin` would be a separate decision.
