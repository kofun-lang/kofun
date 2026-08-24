# Live HTTPS GET adapter profile v1

Normative schema: `kofun.live-https-get-adapter-v1/v1`.
Decision owner: Issue #1577. Selected: **Option A**, compose explicit `Network`
authority with a pinned `TlsProvider`. This is a decision checkpoint, not live
network capability evidence.

## One bounded adapter

The first operation is HTTPS `GET` only on `linux-x86_64` through the
`c11-stage2` backend. It composes the accepted HTTP/1.1 core, one affine
`Network` authority, one explicit DNS policy, a pinned independently versioned
`TlsProvider`, a digested root bundle authority, deadline authority, and
cancellation authority. Other targets refuse before artifact publication.

It does not wrap libcurl. That would import ambient proxy, credential, cookie,
netrc, client-certificate, and root-store behavior behind a surface too broad
to audit. It also does not implement TLS in Kofun. The provider boundary is
small, versioned, digest-bound, and secure-only: SNI, hostname verification,
chain verification, and TLS 1.2 minimum cannot be disabled through this API.

## Request and redirects

The input is a parsed `https` URL plus an exact caller origin allowlist. Raw
strings, plaintext HTTP, request bodies, automatic retries, cookies, auth,
compression, proxies, and client certificates are absent. A successful 301,
302, 303, 307, or 308 remains GET. At most five hops execute. Every hop is
parsed, normalized, checked against the allowlist, and reauthorized before DNS.
Loops and a sixth hop are `RedirectLimit` without returning body bytes.
Only status 200 is a terminal success; every other non-redirect status is a
typed status outcome with no successful body stream.

DNS yields at most 16 addresses; the adapter makes at most four connection
attempts in the deterministic policy order. The caller's peer policy checks
each DNS answer and the actual connected peer. A rebinding or disallowed peer
closes the connection before TLS/application bytes. Loopback is admitted only
by the explicit deterministic-test authority, never by production default.

## Limits, streaming, and terminal state

Headers are at most 65,536 bytes. A body is at most 67,108,864 bytes and is
delivered as owned `Bytes` chunks of at most 65,536 bytes. No complete body is
silently accumulated. Response metadata is complete before the first chunk;
partial headers or chunks cannot become success. A response body owner must be
drained, cancelled, or closed exactly once, returning or revoking every affine
authority on all outcomes.

The caller supplies deadlines no larger than 300 seconds total and 30 seconds
idle. No infinite default exists. Cancellation is checked during DNS, each
connect attempt, TLS, headers, and every body read. Cancellation closes the
active socket/provider state and returns no partial successful body.

The error set distinguishes URL, DNS, peer-policy, connect, TLS, protocol,
status, timeout, cancellation, header/body/redirect limits, truncation,
allocation, and cleanup. Retry safety is data on the outcome; the adapter does
not retry by itself.

## Truth and prerequisites

This profile adds no `Network` carrier, TLS artifact, entitlement, HTTP core,
byte-reader, capability row, or release claim. Implementation stays blocked on
#1258, #1264, #1499, #1536, and #1196. The future release checkpoint must name
only `linux-x86_64`, bind the provider/root artifacts by digest, and execute a
local deterministic TLS/redirect/SSRF/cancellation corpus. Real internet access
is never a test prerequisite.

`task live-https-get-adapter-decision` independently mutates target, method,
scheme, redirect policy, composition, exact bounds, peer checks, cancellation,
output carrier, ambient-authority refusal, and the no-claim boundary.
