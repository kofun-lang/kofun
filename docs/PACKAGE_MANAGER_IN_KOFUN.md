# What `package/manager.sh` needs before it can be written in Kofun

RFC-0018 is accepted. `spec/native-toolchain-v1/contract.json` lists
`shell-build-driver` among its `forbidden_core_build_requirements`, and two of
its eight `completion_evidence` entries name this component:

- *"toolchain commands implemented in Kofun and exercised without forbidden
  core build requirements"*
- *"source-free dependency build from KIF and package artifacts"*

`package/manager.sh` is 450 lines of shell. This document is the measured list
of what stands between it and its Kofun replacement, produced for
[#1453](https://github.com/kofun-lang/kofun/issues/1453) under the
[#1451](https://github.com/kofun-lang/kofun/issues/1451) umbrella.

Every row was checked against `stdlib/capabilities.tsv`, the normative
capability matrix behind [`STANDARD_LIBRARY_CHARTER.md`](STANDARD_LIBRARY_CHARTER.md),
rather than against the compiler source. Measured on
`origin/main@8639360a82fa2b4d1f9821a180e9d5d04adcf645` unless a row says otherwise.

## 1. The rewrite contains behaviour changes, not only a language gap

`spec/native-toolchain-v1/contract.json`'s `directory-authority` profile (#1234)
is already decided, and it is stricter than a shell script can be. Reading the
profile rather than paraphrasing it, because the exact strings matter here:

| decided | value | what `manager.sh` does today |
| --- | --- | --- |
| `symlinks` | `refuse-before-follow-by-default` | follows them, at 6 `rm -rf` and 5 `cp` sites |
| `ambient_cwd` | `false` | resolves paths against the process working directory |
| `derivation` | `attenuated-open-directory-handle` | passes absolute path strings |
| `relative_components` | `nonempty-bytes-excluding-dot-dotdot-and-nul` | accepts `..` wherever the shell does |
| `dot_entries` | `excluded` | `cp` and `rm -rf` see dotfiles |
| `limits.depth` | `64` | unbounded |

`symlinks` is the one to note: the decision is **refuse before following**, not
silently decline to follow. A faithful transliteration would violate a decided
profile on its first day; a correct one refuses inputs the current script
accepts.

This is the set to settle before anyone starts. A language gap is a schedule
problem — you discover it, you file it, you wait. An undeclared behaviour
change surfaces halfway through a rewrite and gets filed as a bug in the new
code, with the new code being right and the old behaviour being what everyone
remembers.

## 2. Filesystem mutation has no capability row at all

This is the largest gap and the least visible one, because absence does not
appear in a matrix.

`stdlib/capabilities.tsv` has 38 rows. Across all of them, **none covers
directory creation, recursive removal, copy, or rename.** The two rows that
sound as though they might do not:

| row | state | what its own note says it excludes |
| --- | --- | --- |
| `syscall-file-round-trip` | implemented | "Linux x86-64 open/write/lseek/read/close round-trip with errno evidence; **no directory listing**, process spawn, or environment authority" |
| `directory-listing` | planned | "authorized deterministic Linux x86-64 **listing**; file open and stat are not directory-enumeration evidence" |

What `manager.sh` uses, counted:

| shell construct | sites | capability row |
| --- | ---: | --- |
| `rm -rf` | 6 | **none** |
| `cp` | 5 | **none** |
| `mkdir` | 2 | **none** |
| `mv` | 2 | **none** |

A `planned` row is a promise; an absent row is not even a question anyone has
asked. These four need rows before they need issues.

The matrix is not the only witness. `stdlib/linux_x86_64/` exposes 68
functions, and the syscall surface behind them is:

```
raw_accept4 raw_bind raw_clock_gettime raw_close raw_connect
raw_epoll_create1 raw_epoll_ctl raw_epoll_wait raw_exit raw_exit_group
raw_getrandom raw_listen raw_lseek raw_mmap raw_munmap raw_nanosleep
raw_open raw_read raw_setsockopt raw_socket raw_stat raw_write
```

No `mkdir`, `rmdir`, `unlink`, `rename`, or `getdents64`; no `fork`, `execve`,
or `wait`; no environment access. So the four absent rows are absent from the
implementation too, and `process-spawn`, `directory-listing`, and
`environment-authority` are `planned` against a surface that has nothing to
build on yet rather than against a partial one.

## 3. Capabilities that have a row

| `manager.sh` needs | row | state | usable today |
| --- | --- | --- | --- |
| manifest parsing | `toml` | implemented | yes |
| lockfile read/write | `syscall-file-round-trip` | implemented | yes, single file |
| ordered output (9 `sort` sites) | `collections-sequence` | implemented | yes |
| SHA-256 of a file | `hashes-checksums` | deferred | see §4 |
| temporary directories (4 `mktemp` sites) | `temporary-files` | planned | no |
| cleanup on signal (8 `trap` sites) | — | — | see §5 |
| line-wise input (2 `read -r` sites) | `buffered-io` | planned | no |
| artifact download | `http-client` | specified | no |
| URL parsing | `url` | planned | no |
| cache root from the environment | `environment-authority` | planned | no |

## 4. Nine of the twelve forward-looking rows cite closed issues

Of the 12 rows in state `planned` or `deferred`, ten distinct issues are cited
and **six of them are closed**, carrying nine rows. Two of the nine —
`temporary-files` and `buffered-io`, both "planned #231" — are prerequisites
for this rewrite specifically.

`task stdlib` is green on all twelve, because
`stdlib/check-capabilities.sh` validates the shape `#<digits>` and never
liveness. It is hermetic and cannot ask GitHub.

`hashes-checksums` is the sharpest instance. It is `deferred` against closed
#636, while `bin/kofun-digest` exists and #1213 removed GNU `sha256sum`
precisely so digests would depend on nothing the project does not own. The row
describes a state the repository left behind.

Tracked as [#1454](https://github.com/kofun-lang/kofun/issues/1454), with the
fix: the committed `artifacts/backlog/issue-state.json` snapshot is already a
hermetic oracle for issue liveness.

## 5. The cleanup guarantee was decided, and this section was wrong

**Correction.** This section said eight `trap` sites "remove partially written
cache entries", and that "an artifact cache that leaves half-written entries
behind on `SIGINT` is worse than one that has no cache, because the next run
trusts them". Neither is true of the script it describes, and #1463 was filed
against that premise.

Measured: `store_cache_entry` (`package/manager.sh:256-279`) publishes by **hard
link**. It copies into a `mktemp` file in the same directory, `chmod 444`s it,
and then `ln`s it to the final name. `link(2)` fails `EEXIST` rather than
overwriting, so a partial file never occupies the entry name, and the loser of a
race re-verifies rather than clobbering. The read path re-verifies too:
`resolve_packages:359-360` runs `verify_cache_entry` on every use.

The eight `trap` sites do not remove published entries. All eleven `rm` sites in
the script target temporaries or `$work`; none targets a cache entry. Three of
the eight traps remove nothing at all.

So the cache is already atomic and already verifies on read, and #1463's
question — what is guaranteed when the process dies mid-write — has the answer
recorded there. What the interruption actually costs is **a leaked temporary**,
because nothing sweeps `.tmp.*` and there is no `clean` subcommand; and what a
digest mismatch costs is a **wedged cache**, because `verify_cache_entry:253`
is `die` and no command in the tool removes the offending file.

Both belong to whatever replaces the script (#1457), and both are stated in the
`temporary-files` row so the rewrite inherits them rather than rediscovering
them.

## What to file

In dependency order, and none of these is filed yet except #1454:

1. Four `stdlib/capabilities.tsv` rows for directory creation, recursive
   removal, copy, and rename — each note carrying the `directory-authority`
   constraints from §1, so they are recorded where an implementer will read
   them rather than in a contract they may not open.
2. A decision issue for interrupt-safe cache-entry cleanup: what is guaranteed
   when the process dies between download and verify.
3. Re-point or re-state the nine rows in §4 — [#1454](https://github.com/kofun-lang/kofun/issues/1454).

## What this document is not

It is not a plan for the rewrite and it does not estimate one. It also does not
claim the list is complete: it is what 450 lines of one script require, and the
CLI driver, the language server, and the gates are separately much larger. The
`node` surface alone is 70 of 261 tracked shell scripts.
