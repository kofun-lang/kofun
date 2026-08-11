#!/bin/sh
set -eu

# `tests/kofun/` was written for an acceptance path that no longer exists --
# `bootstrap/native/README.md` says so in as many words -- and nothing has run
# these eight sources since. Six of them do not compile: they call `assert_eq`,
# `map`, `is_open`, and bind with `let own`, none of which the language has.
#
# They are not stale tests. They are sources describing the language Kofun
# intends to become, and two RFC artifacts cite them as corpus evidence:
# `rfcs/0004-ownership-kind-classification.md` reads `ownership.kofun` as one
# of five tracked sources that bind an owned value, and `rfcs/index.json`
# counts sites in `scientific.kofun`. Rewriting them to compile would delete
# exactly the property those records cite.
#
# So this gate pins what the compiler says about each one today, rather than
# changing any of them:
#
#   - a source that runs must print its `# expect:` line;
#   - a source that does not must produce its recorded `.unsupported`
#     diagnostic on stderr, byte for byte, and write nothing to stdout.
#
# The second half is the load-bearing one. When the language grows to accept a
# source, its recorded refusal stops matching and this gate fails, saying so.
# That is the point: the corpus stops being a directory nobody reads and
# becomes a list of boundaries that announce themselves when they move.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/tests/kofun"
WORK=${KOFUN_TESTS_KOFUN_WORK:-"$ROOT/build/tests-kofun"}

rm -rf "$WORK"
mkdir -p "$WORK"

fail() {
    printf 'FAIL: tests/kofun: %s\n' "$1" >&2
    exit 1
}

executed=0
refused=0

for source in "$CASES"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    expect=$(sed -n 's/^# expect: //p' "$source" | sed -n 1p)
    test -n "$expect" ||
        fail "$stem has no \`# expect:\` line, so nothing states what it should do"

    set +e
    "$ROOT/bin/kofun" run "$source" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    status=$?
    set -e

    golden="$CASES/$stem.unsupported"
    if test -f "$golden"; then
        # A recorded boundary. It must still refuse, with the same words.
        test "$status" -ne 0 || fail \
            "$stem now compiles and runs. That is progress: delete
  $golden, and let the \`# expect: $expect\` line be checked instead."
        cmp "$golden" "$WORK/$stem.stderr" >/dev/null 2>&1 || {
            printf 'FAIL: tests/kofun: %s refuses differently than recorded\n' \
                "$stem" >&2
            printf -- '--- recorded\n'; cat "$golden"
            printf -- '--- actual\n'; cat "$WORK/$stem.stderr"
            exit 1
        }
        test ! -s "$WORK/$stem.stdout" ||
            fail "$stem refused but still wrote to stdout"
        refused=$((refused + 1))
    else
        # An executable source. It must run and print what it says it prints.
        test "$status" -eq 0 || {
            printf 'FAIL: tests/kofun: %s no longer runs\n' "$stem" >&2
            cat "$WORK/$stem.stdout" "$WORK/$stem.stderr" >&2
            exit 1
        }
        printf '%s\n' "$expect" >"$WORK/$stem.expected"
        cmp "$WORK/$stem.expected" "$WORK/$stem.stdout" >/dev/null 2>&1 ||
            fail "$stem printed $(tr '\n' ' ' <"$WORK/$stem.stdout")rather than its declared \`# expect: $expect\`"
        executed=$((executed + 1))
    fi
done

# A count, so the corpus cannot quietly shrink to nothing and still pass. The
# split is expected to move -- toward `executed` -- and moving it is what the
# recorded refusals force someone to do deliberately.
total=$((executed + refused))
test "$total" -eq 8 ||
    fail "expected all 8 corpus sources, saw $total"

printf 'PASS: %s tests/kofun sources run and print what they declare\n' \
    "$executed"
printf 'PASS: %s tests/kofun sources refuse with their recorded diagnostic\n' \
    "$refused"
