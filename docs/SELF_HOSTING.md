# Self-hosting and bootstrap

The canonical current self-host profile, evidence inventory, runnable first
compiler generation, and fixed-point boundary live in
[`bootstrap/selfhost/README.md`](../bootstrap/selfhost/README.md). That document
is also the source rendered by the official self-hosting documentation page.

For the adjacent bounded compiler checkpoints, see
[`bootstrap/stage1/README.md`](../bootstrap/stage1/README.md) and
[`bootstrap/stage2/README.md`](../bootstrap/stage2/README.md).

The current repository has a Kofun-written seed, a runnable compiler-produced
compiler, and the three-generation semantic fixed point for the frozen
profile: `C2 == C3` and `A2 == A3` byte for byte under
`task selfhost-fixed-point`, with independent reproduction (B6) and diverse
double compilation (B7) still open. This file intentionally remains a short
pointer so that bootstrap status has one authority.
