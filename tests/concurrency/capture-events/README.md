# Compiler capture transactions

`task concurrency-capture-events` covers #1225, the step from checked compiler
capture facts to a complete KSE2 transaction and then to a typed-sidecar v2
file. The producer is `bootstrap/stage2/capture_events_producer.c`, compiled
in one translation unit with the maintained C half of the canonical pair. The
sidecar publisher is `tooling/typed-sidecar/emit-stage2-v2.mjs`. The contract
is `spec/concurrency/scoped-captures-v1.md` §15.

Expectations are not taken from the producer. Every §14 positive fixture in
`../captures/cases.json` goes through the independent
`../captures-direct/oracle.mjs` and the accepted capture model. The gate
requires the capture frames to match the model's KSE2 projection of that
oracle byte for byte. Every lifecycle, origin, witness and dynamic-bound node
must carry its authored kind and span, and the NodeId must recompute from that
kind and span. Scope, binding and record-type identities must be owned by the
declarations those authored names and spans identify. The transaction bytes
are required to be identical at O0, O2 and ASan/UBSan and on a repeat, and to
match a re-encode by the separate #1224 encoder. Sidecar captures must equal
the model's projection, and every sidecar string must be an identity, fixed
vocabulary, the logical path or bounded fallback text.

Refusals publish `failed`/`partial` streams whose diagnostic carries the pair's
own refusal: the same line the JSON entry prints. Such a stream keeps exactly
the §11 lifecycle prefix when that prefix was rendered. Cancellation after
`source`, `lifecycle` or `captures` publishes exactly that committed prefix.
Pre-source refusals, usage errors, KSE2 overflow and a stale source preserve
absent and prior destinations. A real 16,385-event source costs minutes of
analysis, so overflow runs against a lowered event bound. The full 8,384-record boundary fits one
transaction. A KSE1 reader still refuses node kind 13. Ordinary compilation of
every fixture still refuses, E2S154 at byte 88 included. Three producer
defects that the #1224 reader accepts are compiled and run, and the authored
oracle must reject each one.
