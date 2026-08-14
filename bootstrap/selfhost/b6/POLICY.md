# B6 independence policy

B6 is the bootstrap criterion that fixed-point self-hosting artifacts are
reproduced **by an independent builder**. The packet beside this file
(`README.md`) is the interface such a builder is handed; this file is the
answer to the question that packet deliberately does not answer: *what makes a
builder independent, and what reviewed artifact closes B6?*

`check-reproduction-report.sh` validates that a report is well-formed and, with
`--against-checkout`, that it describes this tree. It says in its own comments
that it cannot authenticate a builder — `builder|identity` and `builder|basis`
are required and are also just text the builder typed. That is correct and is
not a gap this policy closes by pretending otherwise. What this policy does is
say which claims a reviewer must establish by other means, and which of them a
gate can refuse mechanically.

`sh bootstrap/selfhost/check-b6-policy.sh` is that gate.

## The selected option

**An independent external party runs the packet and submits a reviewed
attestation.** Recorded on
[#1290](https://github.com/kofun-lang/kofun/issues/1290) on 2026-08-14 with the
alternatives rejected:

- **A separately administered CI authority is not sufficient.** A different
  runner or image is still one organization and one control plane, and cannot
  demonstrate operational independence to a reader outside it. A distinct-CI
  reproduction may be recorded as supplementary evidence; it never closes B6.
- **Redefining B6 as producer-side clean reproducibility is rejected.** That
  changes published meaning to fit available evidence. If no external builder
  materializes, **B6 stays open** — an honest open criterion is the outcome,
  not a weakened closed one.

## 1. The producer identity boundary

Producer-side is the `hjosugi` account and every identity it operates — agent
sessions included — together with every machine and checkout those sessions
use, and anything executing this repository's CI configuration or holding its
credentials.

Nothing inside that set can be the independent builder, whatever account
string, directory, or hostname it presents. The boundary is data, not prose:
`producer-identities.tsv` lists the identities and identity patterns that are
producer-side, and the gate refuses an attestation claiming any of them.

That file is the reason this policy can be checked rather than only read. It is
also the reason the check is honest about its limit: it refuses **claimed**
producer identities. A producer who types someone else's name is not caught by
a file, and section 3 is what covers that.

## 2. Minimum independence

A natural person or organization outside the producer set, running the packet
on hardware they control.

**Required to differ:** the operator identity and the machine.

**Recorded but not required to differ:** kernel, libc, distribution, CPU model,
and host C compiler. The report already carries all of them under
`provenance|`. Toolchain *diversity* is B7's claim
(`selfhost-diverse-double-compilation`) and does not move here; a B6
attestation that happens to differ in those dimensions is stronger evidence and
is recorded as such, but sameness in them is not a defect.

## 3. Authentication and review

The attestation arrives as an **ordinary pull request authored by the builder's
own GitHub account**, containing the `kofun.selfhost-b6-report/v1` report the
packet produces.

The identity basis is PR authorship plus maintainer review that the account is
not producer-operated. Verified signatures or a protected CI attestation may
strengthen the record and are welcome; neither is required in v1.

**No agent may assert independence on anyone's behalf**, including its own. An
agent may run the packet and may prepare the PR; the claim that the account
behind it is independent is a human review step, and the gate cannot make it.

## 4. Retention and redaction

The canonical report is committed with the attestation PR. Full logs are
attached to the PR or durably linked from it.

The builder may redact host-identifying strings that fall outside the checkout:
usernames, hostnames, and private paths in `audit|working_directory` and
`audit|packet_directory`. Everything the report schema names as a result or a
provenance field — digests, counts, schemas, tool versions, comparison outcomes
— is **not** redactable. A redacted digest is a missing digest.

## 5. Freshness

The freshness key is `result|acquisition_set_sha256`: the digest over the
declared input set the packet acquires, together with the schema versions the
report records.

An attestation is fresh exactly while that key matches the tree it is being
cited for. Wall time is not a freshness input, and neither is the calendar: a
year-old attestation whose key still matches is current, and a same-day one
whose key moved is stale. This is the whole reason the key is a digest.

## 6. Count, conflict, revocation

**One** policy-compliant attestation closes B6.

A **mismatch** — a report whose `result_sha256` disagrees with the producer's
for the same key — is retained as failed evidence, holds B6 open, and opens a
P1 investigation. A later matching attestation under the same key closes B6
only after the mismatch has a recorded explanation. Deleting the mismatching
report is not an explanation.

A builder may **revoke** their own attestation by pull request. Revocation
reopens B6 unless another policy-compliant attestation stands.

## 7. Allowed differences and the equality contract

Allowed to differ: kernel version, libc, distribution, CPU model within the
declared architecture, locale, hostname, and timezone. The packet normalizes
`LC_ALL=C TZ=UTC umask=022` so that the first three cannot leak into the
result.

Equality is whatever the packet declares deterministic — the `result|` rows,
digested into `result_sha256`. Two reports agree when that one value agrees.
This policy deliberately does not restate the comparison contract; restating it
would create a second copy to drift against.

## 8. Reviewer rule

The maintainer reviews and merges the attestation PR. The attestation's author
cannot review it. No producer-side identity, human or agent, may author it.

## 9. Release wording

B6 closes as:

> one policy-compliant independent clean-builder attestation, externally
> produced and maintainer-reviewed

That wording is distinct from B7's toolchain-diversity claim and is **never** a
security or sandbox claim. B4, B5, and B7 truth and existing release claims are
unchanged by anything in this file.

## 10. When there is no builder

B6 stays open, visibly blocked on an external party. The cost of the selected
option is coordination latency. The failure mode is an open milestone, not a
silently weakened one.

Contributing an attestation requires no CLA, license, or terms acceptance by
automation: the builder contributes as an ordinary human contributor under this
repository's existing licenses.

## What the gate checks, and what it cannot

`check-b6-policy.sh` refuses an attestation that:

1. claims an identity listed in `producer-identities.tsv`;
2. carries an empty or self-check `builder|basis`;
3. omits `builder|identity`, `builder|basis`, or `builder|independence`, or
   states an `independence` line other than the one the packet writes;
4. is **stale** — its `result|acquisition_set_sha256` does not match the tree it
   is cited for;
5. omits the `provenance|` dimensions section 2 requires to be recorded;
6. **disagrees** with the producer's own `result_sha256` for the same key,
   which is the mismatch case of section 6 rather than a malformed report.

It cannot check that the person behind an account is independent. That is
section 3, it is a human step, and a gate that claimed to do it would be the
kind of green this repository exists to refuse.

**The committed `report.tsv` is the standing negative.** It is a real,
structurally valid report whose builder is `kofun repository self-check` — so
the gate refuses it as an attestation on every run, and a change that broke the
refusal would be caught by the gate's own fixture rather than discovered when
someone tried to close B6 with it.
