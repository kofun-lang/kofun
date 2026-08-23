# Refuse a shell that would let docs/RELEASING.md's checks fail quietly (#1603).
#
# Source this, do not run it: `. ./release/fail-closed.sh`. It has to inspect
# and exit the shell the release procedure is actually running in, and a child
# process can do neither.
#
# WHAT IT IS FOR. Cutting v0.11.0-seed, step 7's block printed
#
#     PASS: remote tag v0.11.0-seed = 41251110cffb36abed1c61a13a31ddae798de441
#
# while no such tag existed on the remote. The block had been pasted into a
# shell where `set -eu` was not in effect, so every `test` in it was advisory
# and the summary line ran regardless. The procedure says to start the shell
# with `set -eu`; the penalty for not doing so was a convincing PASS.
#
# WHAT THE SHELL ACTUALLY DID. The issue records the block reaching
# `echo` after a failed `test` with `set -eu` on the same line. That does not
# reproduce: sh, bash and zsh all exit at the failure, non-interactively,
# interactively, through `eval`, and through `-c`. What it leaves is a wrapper
# that starts a fresh shell per command, so the `set -eu` typed at the top of
# the procedure was never in the shell where the check ran. That is the shape
# this file is built to catch, and it is why the guard belongs at the top of
# every block rather than once at the top of the procedure.
#
# WHY THE OPTION LETTERS AND NOT A BEHAVIOUR PROBE. The obvious probe --
# running `( set -e; false; true )` and looking at its status -- cannot work,
# and measurably does not: POSIX has the shell ignore `-e` inside a compound
# command whose status is being consumed by `||`, `&&`, or `if`, which is the
# only way to consume it without the failure taking the shell down. Measured in
# sh, bash and zsh, with errexit both on and off, that probe returns 0 in all
# six cases. `$-` is the shell's own answer about its own state, and it is
# right in all six.
#
# `fail` is here for the same reason the guard is: a block whose assertions each
# carry their own failure action does not depend on errexit at all, so the two
# halves cover each other.

case $- in
    (*e*) ;;
    (*)
        printf 'FAIL: this shell is not fail-closed: `set -eu` is not in %s\n' \
            'effect, so a failed check below would print no error' >&2
        printf 'FAIL: start the procedure again with `set -eu`, %s\n' \
            'in one shell, per docs/RELEASING.md' >&2
        exit 1
        ;;
esac

case $- in
    (*u*) ;;
    (*)
        printf 'FAIL: this shell is not fail-closed: `set -u` is not in %s\n' \
            'effect, so an unset variable below would expand to nothing' >&2
        exit 1
        ;;
esac

# Every assertion in the procedure ends `|| fail '<what was being proved>'`, so
# a check that fails says which one and stops, whatever the shell's options are.
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
