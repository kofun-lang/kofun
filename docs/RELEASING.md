# Releasing

A Kofun release is a tag, a set of published notes, and the evidence pack that
was true at that commit. This document is the procedure; `VERSION` is the
authority for the number.

## What a version number promises

Kofun is a research compiler, and the version number says so. `README.md`
states the project status; this section says what the digits mean.

`MAJOR.MINOR.PATCH-seed` while the leading digit is `0`:

- **`-seed`** marks every release cut before the compiler is a general parser
  and type checker. It is not decoration: `release/claims.json` records 34 of
  47 capabilities as bounded checkpoints, and a `-seed` release promises
  exactly the bounded slices that manifest evidences, and nothing wider.
- **MINOR** rises when a published claim's state rises, when a claim is added,
  or when a bounded slice widens.
- **PATCH** rises for everything else, including fixes and internal work.
- **No compatibility promise exists at `0.x`.** An accepted RFC does not
  create one; only a claim in `release/claims.json` whose state is
  `implemented` describes something a user may depend on, and even then the
  claim's own `compatibility` field is the promise, not the version number.

The `-seed` suffix is dropped, and a compatibility policy replaces this
section, when the milestones in `docs/ROADMAP.md` say it may — not before.
`docs/ROADMAP.md` §M4 lists what 1.0 requires; none of it is a version-number
decision.

## The number lives in one place

`VERSION` is the single authority. `bin/kofun --version` reads it, `tests/cli.sh`
asserts what it reads, and `task repository-check` refuses a second copy of the
number written anywhere under `bin/` or in `tests/cli.sh`.

This gate exists because the number had drifted: `bin/kofun` printed a literal
`0.3.38-seed` while the repository was eleven tags further on, and the test
asserted the stale string rather than catching it. Two copies of one fact with
nothing binding them is the drift this repository gates against everywhere
else.

## Procedure

Run from a clean checkout of `main`, with the working tree clean.

1. **Prove the tree.** `task verify` must exit 0. Check the exit status, not
   the tail of the output — a pipeline ending in `tail` reports `tail`'s
   status and a failing run reads as green.

2. **Refresh the evidence pack.** `task release-evidence`, then
   `task release-claims`. The pack under `artifacts/release-evidence/` is a
   deterministic projection of `release/claims.json`; CI regenerates it and
   requires a byte-identical result, so a stale pack fails the release rather
   than shipping.

3. **Set the number.** Edit `VERSION` to the version being released, following
   the rules above. Commit it alone, so the version bump is one reviewable
   change:

   ```sh
   printf '%s\n' 0.3.50-seed >VERSION
   git commit -m "release: 0.3.50-seed" VERSION
   ```

4. **Confirm the tree agrees.** `task repository-check` must pass; it compares
   `bin/kofun --version` against `VERSION` and refuses a literal written
   elsewhere.

5. **Push and let CI prove it.** Push `main` and wait for the Kofun
   verification, Backlog issue state, and Release evidence pack jobs to pass
   at that exact commit. A release is cut from a commit CI has proven, never
   from a local run alone.

6. **Tag it.** The tag is `v` followed by `VERSION`, exactly:

   ```sh
   git tag "v$(cat VERSION)"
   git push origin "v$(cat VERSION)"
   ```

   Pushing that tag runs `.github/workflows/release.yml`, which **refuses a
   tag that disagrees with `VERSION`**, runs `task verify` at the tagged
   commit rather than trusting the branch run, builds a reproducible source
   archive with `git archive`, and attaches it with its SHA-256 to the
   release. A `-seed` version is published as a pre-release, because the
   suffix and the flag say the same thing and must not disagree.

7. **Write the notes.** The workflow generates notes from the commit range;
   replace them with what changed in terms of claims — which capability rose,
   which bounded slice widened, which refusals moved.
   `artifacts/release-evidence/CLAIMS.md` is the source for that wording, so
   the release notes and the claims manifest do not describe one capability
   two different ways.

## What a release includes, and what it does not

**It includes** a source archive and its SHA-256. That is the acquisition
artifact an independent builder starts from, and the digest is what makes
"the right bytes" checkable — the same question
`bootstrap/selfhost/declare-inputs.sh` answers file by file.

**It does not include binaries for any platform.** A user builds from source.
An install path is an M4 deliverable (`docs/ROADMAP.md` §M4, "multi-platform
release"); the compiler is Linux x86-64 only today, AArch64 evidence is
qemu-gated, and there is no macOS or Windows support to ship. Saying so is
deliberate: pretending an install path exists would be the same defect this
document was written to close.
