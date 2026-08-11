# Numeric backend conformance corpus

This directory is the shared numeric corpus for every Kofun backend. Backends
must use these same files rather than creating backend-specific copies.

Each corpus file carries its expected stdout, stderr, and exit status in
`# expect-*` headers. `expectations.kofun` lists the exact case filenames and
pins a path-independent SHA-256 of those byte observations for future
Kofun-native tooling. The executable validator rejects name, count, or
observation drift. Backend support is declared only in
`tests/conformance/capabilities.tsv`; neither an adapter nor an expectations
file carries a second backend list. `./bin/kofun test
tests/conformance/numeric` dispatches the common runner across every adapter in
`tests/conformance/backends/`.

A file may instead declare `# expect-reject:`, for a construct the
specification refuses outright and that therefore has nothing to run.
Three of the twelve cases are of that kind: `reject_slash_operator.kofun`,
because `/` is not defined on `Int` (#687), and
`reject_inexact_numeric_conversion.kofun` and
`reject_numeric_annotation_mismatch.kofun`. What every backend must agree on
there is the refusal, not a value. The observation is that the backend compiles
nothing, leaves no artifact, and writes a diagnostic. The diagnostic's bytes stay pinned in each backend's own
gate, because the specification lets a backend word its own refusal; what this
corpus pins is that none of them produce a runnable artifact. The recorded
reason is covered by the observation digest. See
`spec/backend-differential-contract.md`.

The capability manifest records one of two states for every backend/corpus
pair:

- `supported`: the adapter must execute at least one case, and every case must
  compare stdout, stderr, and exit status byte for byte;
- `unsupported`: the manifest carries a stable reason and the adapter is not
  invoked for that corpus.

An executor can be unavailable on the current host without changing target
capability. In particular, AArch64 support stays fixed while the adapter
separately reports whether `qemu-aarch64` exists. The runner still
cross-compiles every case before reporting the executor unavailable. A
supported adapter returning the conformance skip status is a failure. Missing
results, zero executed cases on an available executor, crashes, signals, and
timeouts are also failures. The summary reports `executed/total` coverage for
each supported backend.

`tests/conformance/capabilities_test.sh` rejects incomplete matrices,
duplicate, unknown, contradictory, or reasonless rows, disappearing adapters,
attempts to restore an independent adapter or expectations-file policy,
partially skipped supported corpora, unregistered same-name corpus
substitution, unavailable-executor compile bypass, unsafe evidence paths, and
drift between each expectations manifest and the files or observations the
runner discovers. `task verify` runs that gate and this corpus. Runtime
failures are captured as ordinary stdout/stderr/exit observations rather than
treated as harness failures.
