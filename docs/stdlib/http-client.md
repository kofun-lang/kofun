# HTTP client contract

## Status

This document is the accepted contract for GitHub issue
[#638](https://github.com/kofun-lang/kofun/issues/638). No client is implemented:
acceptance settles what the first portable, first-party HTTP client must be,
not that anything ships. The first bounded implementation slice is #644 — the
HTTP/1.1 core over the deterministic scripted transport — and live DNS,
socket, and TLS adapters remain separate children.

Issue #1577 records the first live-adapter decision in
[`live-https-get-adapter-v1`](../../spec/live-https-get-adapter-v1/PROFILE.md):
explicit `Network` authority plus a pinned `TlsProvider` on a bounded
`linux-x86_64` checkpoint. The profile is not implementation evidence and does
not change this document's status.

Under the standard-library charter the client is an **independently
versioned official module**: its TLS policy and root-store handling must be
updateable without a compiler release. Closed #24 is evidence of a bounded
HTTP/1.1 *server*, not of any client API.

The words **must**, **must not**, and **may** are normative.

## Decision summary

Kofun's first HTTP client is HTTP/1.1-only, capability-explicit, and bounded
everywhere: every read has a caller-visible limit, every connection is an
affine resource, and nothing consults ambient authority (environment proxies,
system credentials, the filesystem, the clock, entropy) without a capability
argument in the signature.

```kofun
fn fetch_user(take net: Network, read base: Url) -> Result[User, HttpError] {
    let client = http.client(net, http.ClientConfig.default())
    let response = client.get(base.join("/user")?)
        |> http.send()?
    let body = response.body.read_all(limit: 1_000_000)?
    return json.decode[User](body)
}
```

## Accepted decisions

### Types and ownership

- `Client` owns the connection pool; it is an affine resource released
  deterministically (`take`) which drains or closes every pooled connection.
- `Request` is a value; `Response` owns its body stream. The body is a
  `take`-consumed stream: reading it to completion returns the connection to
  the pool; dropping it early closes the connection rather than silently
  draining unbounded data.
- Bodies use the stream protocol of `docs/stdlib/stream-protocol.md`, so
  demand, cancellation, and buffer bounds are the stream contract's, not
  bespoke.

### URL

- URL parsing/normalization (percent-encoding, IDNA non-goal in v1) is a
  portable `url` module dependency, specified with this contract; the client never
  accepts raw strings for structured parts.

### Scope

- HTTP/1.1 with keep-alive and chunked transfer. HTTP/2 is deferred until
  the HTTP/1.1 core has conformance evidence; the API must not preclude it
  (no exposed framing details). HTTP/3/QUIC and WebSocket are out of scope.

### Redirects

- Redirects are followed only when enabled: `RedirectPolicy.none` is the
  default; `RedirectPolicy.limited(n)` follows at most `n` hops.
- 303 rewrites to GET and drops the body; 307/308 preserve method and body,
  and a non-replayable streamed body makes the redirect a typed error.
- Cross-origin redirects drop authorization headers. A redirect loop or
  limit overflow is `HttpError.RedirectLimit`.

### Proxy

- No environment lookup by default. A proxy is used only when set in
  `ClientConfig`; an optional explicit constructor
  `ClientConfig.from_env(env)` requires the environment capability, so the
  authority stays visible in the signature.

### DNS and sockets

- Name resolution and connection go through the `Network` capability
  (#232); the client never opens sockets ambiently. The deterministic test
  transport substitutes at this boundary.

### TLS

- TLS is a separate independently versioned adapter behind a `TlsProvider`
  interface: the client
  is specified against the interface, not a vendor.
- Secure by default: hostname verification and SNI on, minimum TLS 1.2,
  certificate verification cannot be disabled through `ClientConfig` — an
  explicitly named `DangerousTlsConfig` exists only behind the provider,
  so a grep finds every use.
- Root trust comes from the platform store by default with a pinned-bundle
  option; root-store and TLS-policy updates ship on the module's own
  channel, never waiting for a compiler release.

### Limits

Every limit is explicit in `ClientConfig`, with bounded defaults:
max header bytes (64 KiB), max redirect hops (0; 5 when enabled), connect /
read / total deadlines (required — no infinite default), max in-flight body
buffering per the stream demand contract, and decompression bounded by both
output bytes and expansion ratio. `read_all` requires a caller-supplied
limit. Automatic decompression covers `gzip` only in v1 and may be disabled.

### Errors

One typed taxonomy, each variant naming whether a retry may be safe:
`Url`, `Dns`, `Connect`, `Tls`, `Protocol` (malformed/smuggling-shaped
responses are refused, never repaired), `Timeout`, `Cancelled`,
`LimitExceeded`, `RedirectLimit`, `BodyTruncated`. Idempotent-request retry
is caller policy; the client never retries automatically.

### Targets and cost

- **The client exists only where a `Network` capability does.** It is specified
  against that capability (#232) and never opens sockets ambiently, so a target
  with no `Network` adapter does not get a degraded client — it does not get the
  module at all, and asking for it is a compile-time error naming the target
  rather than a runtime failure. **wasm32 is such a target today**: its Core is
  bounded arithmetic with a browser host, and a browser `fetch` is a different
  contract (no connection ownership, no framing, its own redirect and CORS
  rules) that must not be presented as this API.
- Dependencies are two, both named: the portable `url` module, specified with
  this contract, and a `TlsProvider` adapter for `https`. **Plain `http` does not
  pull TLS in** — a program that never constructs an `https` URL does not carry
  the provider or a root store.
- The provider is where the artifact cost lives. A native TLS backend is a
  pinned dependency with its own update channel, and the charter's rule 2 is
  what permits it; a Kofun implementation is out of scope for v1 (see
  Alternatives). Either way the cost is the adapter's and is not paid by the
  HTTP/1.1 core, which is why they are separate children.
- The scripted transport (#644) substitutes at the `Network` boundary, so the
  core's own conformance evidence costs no adapter at all.

### Testing

- The conformance corpus runs only against local deterministic transports:
  a scripted in-memory transport (#644) and a loopback server. Fixtures
  must include fragmentation, pipelined garbage, smuggling-shaped framing,
  oversized headers, decompression bombs, redirect loops, and truncated
  bodies. No test consults the real network.

## Alternatives considered

**Wrap libcurl.** Merits: instant protocol breadth (HTTP/2/3, proxies,
auth), battle-tested. Demerits: a large ambient-authority C surface
(environment proxies, credential files) contradicts the capability rule;
limits and error taxonomy would be translations rather than contracts; the
trusted native surface would dwarf the rest of the toolchain. Rejected —
though rule 2 of the charter would allow a pinned native TLS backend behind
`TlsProvider`.

**Implement TLS in Kofun now.** Merits: no native dependency, full audit in
one language. Demerits: implementing TLS from scratch is a multi-year
security liability and is explicitly out of scope in #638. Rejected for v1;
the provider interface keeps the option open.

**HTTP/2 first.** Merits: modern default, multiplexing. Demerits: much
larger state machine before any conformance evidence exists; HTTP/1.1
covers the JSON/API calls the charter's coverage goal names. Rejected —
deferred, not precluded.

**Automatic env-proxy and unlimited redirects (curl-like ergonomics).**
Merits: things "just work" behind corporate proxies. Demerits: ambient
authority invisible in signatures, and redirect-following that silently
re-sends bodies is a data-exfiltration hazard. Rejected — explicit config
only.

## Non-goals

HTTP server behavior, WebSocket, HTTP/3/QUIC, browser-fetch compatibility,
automatic retries, ambient credentials/proxies, cookie jars (v1), caching
(v1), and any implementation before this contract's children are accepted.

## Validation

| Check | Artifact | Expected result |
|---|---|---|
| Contract review | this document | decisions, limits, threats, ownership complete |
| Fixture design | local scripted/loopback corpus (#644) | positive and adversarial cases reproducible |
| Charter matrix | `sh stdlib/check-capabilities.sh` | `http-client` row cites this contract |
