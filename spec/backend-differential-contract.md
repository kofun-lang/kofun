# Backend differential contract

Status: normative for every registered Kofun backend.

Contract identifier: `kofun.backend-differential/v1`.

## Oracle and observations

The specification and conformance manifest define the expected behavior. Every
case must provide an explicit expectation; there is no host-language oracle.

For each source program, a backend produces one observation:

```text
stdout: exact bytes
stderr: exact bytes
exit:   process exit status
```

The runner compares all three fields. It does not combine output streams,
discard diagnostics, compare only successful programs, or normalize
backend-specific text.

A construct the specification refuses is registered instead as a rejection
case, whose observation is defined under *Refused constructs* below.

## Corpus and backend registration

Each corpus program owns its exact expected stdout, stderr, and exit status in
`# expect-*` headers, or declares itself a rejection case. Backend adapters live in
`tests/conformance/backends/`. Adding a backend means adding one adapter that
defines its name and compile command; the common runner discovers it
automatically. A backend must not copy, filter, or replace the corpus with a
private suite.

`tests/conformance/capabilities.tsv` is the sole backend/corpus capability
authority. It contains exactly one `supported` or `unsupported` row for every
discovered adapter and registered corpus. Supported rows name an evidence
path. Unsupported rows carry a stable reason. The executable validator rejects
missing, duplicate, unknown, contradictory, and reasonless rows. Adapters and
corpus expectation files must not carry independent backend lists.

The numeric Core corpus is `tests/conformance/numeric/`. Its Kofun manifest,
`expectations.kofun`, lists the canonical case filenames and pins a
path-independent SHA-256 of the exact fixture observations for future
Kofun-native tooling. The executable validator compares the name set, count,
and digest against discovered files and their `# expect-*` headers. Every
backend marked supported for numeric consumes that physically registered
directory; a different same-name directory is rejected.

## Refused constructs

A construct the specification leaves undefined has no runtime observation to
compare, and a corpus that could only hold runnable programs would have to stay
silent about it — which is how the same construct comes to mean different
things on different backends. Such a construct is registered as a *rejection
case*: one source declaring

```text
# expect-reject: REASON
```

and none of the execution headers. Declaring both in one file is a corpus
error, not a case failure, because the two contracts contradict each other.

For a rejection case the observation is that the backend declined the source
before execution:

```text
compile: non-zero
artifact: none
diagnostic: non-empty
```

The refusal wording is deliberately not compared across backends. A backend may
reject an undefined construct with its own diagnostic, and each backend pins its
own bytes in its own gate; what this corpus pins is that **no backend produces a
runnable artifact** for the construct. Adapter status 125 and status 1 are the
same observation here — both mean refused before execution — so the rule below
that 125 fails a supported pair does not apply to a rejection case. A backend
that compiles the source, or that refuses it without writing a diagnostic,
fails.

A rejection case is decided at compile time, so an absent executor does not
reduce what it measured. When the executor is available the refusal counts as
executed coverage; when it is not, coverage still reports zero executed and the
refusals are reported on their own line. Whenever any case was refused the
runner adds:

```text
refused: REFUSED/TOTAL cases refused before execution by BACKEND
```

`REASON` is covered by the corpus observation digest, so it cannot drift
without the manifest failing.

## Unsupported cases and coverage

A backend/corpus pair may be `unsupported` only in the canonical manifest,
with a stable reason. Unsupported policy is corpus-level and is not counted as
executed coverage. Once a pair is `supported`, a case-level skip or adapter
status 125 is a failure, as are a missing observation, zero executed cases,
crash, signal termination, timeout, or empty adapter result. A rejection case
is the one exception to the status-125 rule, for the reason given above.

Target capability is independent from executor availability. An adapter may
define an availability check for an external executor such as
`qemu-aarch64`. The runner reports that host condition as `UNAVAILABLE`
without rewriting the target's manifest state, but still cross-compiles every
supported case before reporting that execution is unavailable.

Every run prints:

```text
PASSED passed; FAILED failed; 0 explicitly skipped
coverage: EXECUTED/TOTAL cases executed by BACKEND
```

This makes lost coverage a gate failure when an existing supported backend
regresses or a new backend is registered.

The skip count is a literal `0`, and always will be for this runner. The line
shape is shared with `bin/kofun`, which counts per-case skips and reports a
real number there; the conformance runner has no per-case skip to count,
because an unsupported target is declared per corpus in `capabilities.tsv` and
never reaches a case, and a missing executor is reported as `UNAVAILABLE`
instead. Reading that zero as an observation would be reading a constant as a
measurement, so a reader comparing two backends should use the `coverage:`
line and the `UNAVAILABLE`/`refused:` reports, which do move.

The common runner treats missing executables, crashes, signals, and timeouts as
failures. It compares output files with `cmp` so trailing newlines and empty
streams remain observable. Fixture exit statuses are limited to 0 through 127;
124 is reserved for the timeout harness and cannot be declared as a successful
fixture observation.

## Runtime failures

Expected runtime failures are ordinary observations. In particular, division
by zero and integer overflow must be allowed to run; they pass only when their
stdout, stderr, and exit status exactly match the manifest. A host signal such
as `SIGFPE`, a C undefined-behavior result, or an interpreter traceback is a
contract failure.
