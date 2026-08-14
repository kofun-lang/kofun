# The B6 reproduction packet

Two commands and one report format. They are the interface an independent
builder is handed and the one a reviewer runs on what comes back.

```sh
KOFUN_B6_BUILDER_IDENTITY='who you are' \
KOFUN_B6_BUILDER_BASIS='why you are independent of the Kofun project' \
    sh bootstrap/selfhost/reproduce.sh OUTPUT REPORT

sh bootstrap/selfhost/check-reproduction-report.sh REPORT
sh bootstrap/selfhost/check-reproduction-report.sh REPORT --against-checkout

task selfhost-b6-report
task selfhost-b6-policy
```

`POLICY.md` beside this file answers the question this packet deliberately does
not: what makes a builder independent, and what closes B6. `selfhost-b6-policy`
is its mechanical half — it refuses reports that do not qualify as
attestations, including the `report.tsv` in this directory, which is a valid
report produced by the repository checking itself.

## What is new here, and what is not

Nothing reproduces anything new. `reproduce.sh` runs four gates that already
existed, in order, in their own normalized environment:

| step | what it settles |
|---|---|
| `declare-inputs.sh` | what must be obtained, with digests |
| `check-declared-inputs.sh` | the manifest describes this tree |
| `check-inputs-sufficient.sh` | the declared set *alone* rebuilds the chain |
| `check-fixed-point.sh` | C2 == C3 and A2 == A3 |

What is new is the sequencing, the report, and the validator. The runner holds
no generation, digest-set, or fixed-point logic of its own, and the gate reads
that off the file rather than trusting this paragraph — the moment a second
implementation exists, a builder can reproduce one and not the other, and
nobody finds out which.

## The four sections, and why they are four

**`result|`** is what two builders must agree on: generated-C and corpus
digests, counts, schemas, the criterion. `result_sha256` is a digest over
exactly those rows, so two reports agree when that one value agrees.

**`provenance|`** is what a builder cannot be expected to match: host compiler,
operating system, kernel, architecture, libc, and the executable digests those
produce. `declare-inputs.sh` states the policy — the generated C is
deterministic and expected to reproduce under any conforming C11 compiler, the
executables are not, and a difference there is a toolchain difference rather
than a defect. Recording these is how a reviewer tells the two apart. Comparing
them is not what makes a reproduction, which is why they are outside the
identity.

**`builder|`** is supplied by whoever ran the command, and is required: the
runner refuses to write a report without an identity and a basis. It is also
not self-authenticating, and the row `builder|independence` says so in the
report itself.

**`audit|`** is time and path. It is excluded from `result_sha256` by
construction, so a report that moved between machines keeps the identity it was
published with. The gate proves that by rewriting the audit section and
requiring the identity to be unchanged.

## What the validator will not say

It will not say the builder was independent. Nothing in a file can authenticate
its own author, and a validator that stayed silent on the point would leave
"the validator passed" to be quoted as though it had settled one. So the
success output states, every time, that the claim cannot be authenticated and
that B6 is not closed by the command passing. The gate asserts both sentences
are there.

A report that rewrites `builder|independence` into something stronger — say
`verified independent` — is refused. The validator can only carry the statement
it can support.

Deciding whether a stated basis constitutes independence is a person's
judgement, recorded elsewhere. That decision is #1290, and binding an
attestation into manifest and release truth is #1292.

## The retained report

`report.tsv` is a real report, kept for the situation a reviewer is usually in:
a report about a commit they do not have. It is validated structurally and
never with `--against-checkout`, because its subject moves every time the
compiler does. Its `audit|` paths are placeholders — audit metadata cannot
affect identity, which is exactly what makes them safe to replace.

## Refusals

The gate damages a real report sixteen ways and requires each to be refused for
its own reason: an unknown field, a missing one, a surplus one, a duplicated
row, a truncated file, an empty value, a short digest, a zero count, a path in
the semantic section, a report whose own C2 and C3 differ, one whose A2 and A3
differ, a stale identity, a foreign schema, a foreign command, a softened
independence row, and a digest of an empty input.

That last one is not hypothetical. A set digest over files that were never read
returns
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` and exits
successfully; it is stable run to run, so it compares equal to itself and reads
as evidence. The first version of this runner produced exactly that for the
corpus observations, because it passed directories where files were wanted.
`tree_digest` in `generations-lib.sh` now refuses a non-file argument, and the
validator refuses that digest wherever it appears.
