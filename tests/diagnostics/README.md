# Stable diagnostic registry

`registry.tsv` is the canonical, bytewise-sorted declaration of active stable
diagnostic identities. Each row records:

1. code, family, and phase;
2. active emitter or adapter;
3. public channel and exact exit status;
4. primary and secondary span policy;
5. output-artifact policy;
6. one executable fixture owner, fixture, and exact or inline golden; and
7. the comma-separated adapters that report observations.

A code with more than one active producer lists them `;`-separated, most
reachable first — the form eighteen rows already used before it was written
down here. `E2S122` and `E2S123` are emitted both by the compiler a user runs
and by the standalone record frontend, and naming only one of the two would
send a reader to the file that did not print the message they are holding.
Fixture ownership stays singular: one adapter owns the evidence for a code
however many producers agree on it.
Observation ownership may be plural. Every listed adapter must publish the
same routing, exit, span, and artifact policy, while duplicate `(code,
adapter)` observations are refused. The canonical fixture owner must be one of
the listed observers; it does not become the owner of every observation.

Span policy is `required`, `not-applicable`, or a named `debt(...)`. The three
pre-existing Stage 2 omissions remain
`debt(stage2-no-source-position)` and therefore cannot be counted as precise.
`file:` evidence names a checked-in fixture or golden. `inline:` evidence
means the named runner constructs or asserts it deterministically.

Run the cheap declaration/report consistency gate and its negative self-tests:

```sh
sh tests/diagnostics/check.sh
sh tests/diagnostics/self-test.sh
```

Run every registered executable owner, then validate the observations:

```sh
sh tests/diagnostics/run.sh
```

The dispatcher appends an adapter report only after that adapter succeeds.
Family runners remain responsible for exact public messages, status, channel,
span, and artifact checks appropriate to their execution model.

## Internal-path evidence

Every active stable identity has executable adapter evidence. Ordinary
frontend, budget, and host-I/O failures use real inputs and filesystem
conditions. The qualified- and selective-import runners compile their focused
tools with `KOFUN_TEST_DIAGNOSTIC_FAULTS` and set `KOFUN_DIAGNOSTIC_FAULT` only
for internal invariants that valid source cannot reach. Production builds do
not compile those fault branches.

## Deterministic bless workflow

Regenerate or verify all registered golden owners with:

```sh
sh tests/diagnostics/bless.sh
```

File-backed owners invoke their bless script. Inline owners rerun their exact
assertions and write nothing. The dispatcher validates registry/report
consistency before and after the operation, uses `LC_ALL=C`, and ends by
requesting review of the resulting diff. A clean second run must produce no
diff.

## Negative contract

`self-test.sh` creates temporary mutations and proves deterministic rejection
of a duplicate code, a duplicate `(code, adapter)` observation, an unknown or
unregistered observation, a missing declared observation, a missing active
fixture, a public routing mismatch, and a forbidden partial artifact. It never
edits the checked-in registry or goldens.
