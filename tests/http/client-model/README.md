# HTTP/1.1 reference model

The independent deterministic oracle for #644's children, and the versioned
corpus they must match.

```sh
task http-client-model
```

This is executable specification evidence. It is **not** a client, it opens
nothing, and no capability is claimed by it passing. `docs/stdlib/http-client.md`
is the contract; this is what that contract says, run.

Later slices consume the committed scripts and results. They may not write a
second oracle: two models that disagree about an ambiguous message is the defect
this corpus exists to find, reproduced inside the evidence.

## What it is made of

| file | what it owns |
|---|---|
| `schema.mjs` | the only reader of a script or a result |
| `model.mjs` | the model, and the CLI that runs one script |
| `fragment.mjs` | splitting one script every way, and by seed |
| `build-corpus.mjs` | the committed scripts |
| `fixtures/*.script.json` | one message and one delivery plan each |
| `fixtures/*.result.json` | the model's answer, recorded |
| `vectors/*.request` | request bytes, derived from the contract by hand |

The scripts are generated because they are mechanical, and committed because
they are the specification. The gate regenerates them and requires no change: a
fixture edited by hand and a generator edited without regenerating are the same
defect from either side.

The results are **not** written by the generator. They are the model's own
output, so the corpus cannot state an answer the model does not give.

## Everything is bytes

There is no host HTTP parser here and there must not be. A model that borrowed
one would agree with that parser's reading of an ambiguous message rather than
with the contract's — and ambiguity is most of what this corpus is about.

Nothing consults a clock, a locale, an environment variable, the network, or
randomness outside an explicit seed.

## Failing closed

The contract's word is that malformed and smuggling-shaped responses are refused,
never repaired. That is a rule about what *not* to do, so the model has to be
read for absences. There is no branch that picks a framing when two are
declared, drops a duplicate `Content-Length`, unfolds an obs-fold continuation,
or accepts a chunk size it could not read exactly.

A duplicated `Content-Length` is refused **even when the two values agree**.
Resolving it is choosing which peer to believe, and the corpus keeps both cases
so the rule cannot be softened to "conflicting only".

Framing is the model's on the request side too. A caller-supplied
`Content-Length`, `Transfer-Encoding`, or `Host` is refused rather than merged:
a caller who can set them can put a second message's framing on the wire.

## Fragmentation

Every script is re-run split at every byte boundary, and again under seeded
multi-point plans whose seed is printed and replayable.

This is the property that separates a resumable state machine from a reader that
works only when the peer is generous, and it earned its place while this model
was being written. The first chunked reader took the chunk data and then the
trailing CRLF in one pass; when the data arrived and the CRLF had not, it had
already consumed the data and returned, and the next delivery re-read from the
top and took the body's own bytes as a chunk size. Whole-message runs were
correct throughout. Only the sweep saw it.

The comparison excludes exactly one field, `counters.operations`, which counts
scripted operations and is therefore a property of the delivery plan rather than
of the message. It is the one field a fragmentation test must not pin, and the
easiest one to pin by accident.

## What is whose fault

Three refusals with three different meanings, kept apart on purpose:

- a **schema** refusal is a malformed script — exit non-zero, no result;
- a **script** refusal is a well-formed script that is wrong about its own run,
  such as cancelling at a phase the model never reached — also exit non-zero,
  no result, because recording it as a protocol error would blame the message
  for the corpus;
- a **model failure** is the peer's message being refused — exit zero, with a
  result whose `outcome` is `error` and whose `kind` is one of `protocol`,
  `limit-exceeded`, `body-truncated`, or `transport`.

A request that cannot be serialized never reaches a transport, so it produces no
result at all. A result would say a transport was exercised.

## Limits

Every counter is checked before the bytes it would count are taken, so a refusal
happens at the boundary rather than after the model already holds the excess.
Each limit is exercised at the last message it accepts and the first it refuses,
one counter at a time, so a refusal names the counter that refused.

`limit_body_bytes_over_across_chunks` is the one that is not a pair: every chunk
is within `max_chunk_bytes` and only their sum crosses `max_body_bytes`, so a
model that checked the chunk alone would accept it.

## Refusals, proved by removing them

Ten mutations rebuild the model with one rule changed and require this corpus to
notice: framing precedence, duplicate length, chunk-size grammar, the body and
chunk limit comparisons, reuse, obs-fold, the resumable chunk reader, and two
more.

The last is the one worth reading. `takeExactly` consuming what it has before
reporting that it has too little leaves **every committed result unchanged** —
a whole message never takes the short path. The assertion is therefore in two
halves: the recorded results must still match, *and* the sweep must fail. A
mutation the corpus noticed for the ordinary reason would prove nothing about
the sweep.

## Three corrections this corpus made to itself

Worth recording, because in each case the fixture was wrong and the model was
right:

- `Content-Length: 5 ` was written as a refusal. Optional whitespace around a
  field value is not part of the value, so trimming leaves a valid length. The
  pair is now a positive for the trimming and a negative for whitespace
  *inside* the value, which trimming cannot rescue.
- a caller-supplied framing header was expected to produce an error result. It
  produces no result, for the reason above.
- cancelling at an unreached phase was recorded as a protocol error, which
  attributed a corpus author's mistake to the peer.
