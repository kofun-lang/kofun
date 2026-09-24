# Fuzz findings

`docs/ROADMAP.md` lists "sustained fuzzing without unresolved critical
findings" as a 1.0 exit criterion, and records its second half as
**unmeasurable** rather than unmet: no register existed, so nothing recorded
what was found or what happened to it. A criterion phrased "without unresolved
findings" cannot be checked against a repository that does not say what its
findings are.

This file is that register. It is the only place a fuzz finding is considered
recorded.

## What a row owes

| Field | Meaning |
| --- | --- |
| Date | UTC date the run failed |
| Generator | the script that failed, e.g. `tests/fuzz/enum_match.sh` |
| Base seed | the `fuzz lane: base seed N` the run printed — this alone reproduces the whole run |
| Generator seed | the `seed=N` that generator printed, enough to re-run it alone |
| Summary | what went wrong, in one line, in terms of the program's behaviour |
| Resolution | `fixed in <PR>`, `not a defect: <why>`, or `open` |

A row whose Resolution is `open` is an unresolved finding, and the exit
criterion is not met while one exists. That is the point of writing it down: an
unrecorded finding does not make the criterion pass, it makes it unmeasurable.

`not a defect` needs a reason. "Could not reproduce" is not one on its own —
the seed is recorded precisely so that reproduction is mechanical, and a
finding that will not reproduce from its own seed is itself a defect, in the
generator's determinism.

## What does not belong here

A failure of `task fuzz` inside `task verify` is a **regression**, not a
finding: those generators run from the committed default seeds, so a red pull
request means the change under review broke something already covered. Fix it
in the pull request.

Only the scheduled lane in `.github/workflows/fuzz.yml`, which rotates the
seed, can surface an input the corpus had never explored. Those are findings.

## Findings

| Date | Generator | Base seed | Generator seed | Summary | Resolution |
| --- | --- | --- | --- | --- | --- |
| 2026-09-24 | `tests/fuzz/semantic_differential.sh` | 44 | 1310084867 | `adapter timed out: c11-stage1` on case 0: from an empty `build/`, `bin/kofun build --backend c` built the Stage 2 compiler inside the runner's 10s adapter timeout, and 38,037 lines of `compiler.c` no longer compile inside it on a hosted runner. All 48 programs agree once the compiler exists ([#1656](https://github.com/kofun-lang/kofun/issues/1656)) | fixed in [#1657](https://github.com/kofun-lang/kofun/pull/1657) |

The first row is a harness defect rather than a miscompile, and it is recorded
here anyway: the lane exists to report what it finds, and a finding filed only
where it was fixed would leave this register saying the lane had never failed.
