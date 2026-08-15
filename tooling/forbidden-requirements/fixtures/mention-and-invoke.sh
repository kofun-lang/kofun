#!/usr/bin/env sh
# A fixture, not a gate. `tooling/forbidden-requirements/check.mjs` excludes
# this directory from its scan; `self-test.mjs` drives the detectors over it by
# hand and asserts the counts below. Editing it changes what the self-test
# expects, which is the point — every line here is a case that was wrong once.
#
# MENTIONS, which must count as nothing:
#   node tooling/task-help.mjs   <- a comment, not an invocation
#   cc -std=c11 -o out in.c      <- likewise
set -eu

# The near miss that cost the first `import-library` count 82 false hits: `-lt`
# is shell's `less than`, not a link against libt.
if [ "${1:-0}" -lt 3 ] && [ "${1:-0}" -le 9 ]; then
    printf 'small\n'
fi

# The near miss that cost the first `assembler` count four files: `as` is an
# English preposition far more often than it is an assembler.
printf 'treat it as a warning\n'

# The one invocation in this file.
node --version >/dev/null

# A real compile line, opened by an environment assignment and continued —
# the shape that hid five compile lines from the first `cc` count.
KOFUN_FIXTURE_ID=mention-and-invoke \
"$CC" -std=c11 -O2 -o /dev/null - </dev/null

echo "done"   # node is named again here, and again counts for nothing
