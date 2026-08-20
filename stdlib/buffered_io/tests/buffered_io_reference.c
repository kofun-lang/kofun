/*
 * #1510. Independent C11 oracle for stdlib/buffered_io.
 *
 * A test oracle only. The standard-library implementation is Kofun; this file
 * exists so that a wrong state machine has to be written twice, in two
 * languages, before it can pass. It is written from the adapter's rules --
 * scan for a line feed, return the line, compact and refill when there is
 * none, retry EINTR with the offset unchanged, refuse when the buffer is full
 * without one, return the final line that has no terminator, and answer a read
 * past the end from state -- not translated from the projection.
 *
 * It opens no file. `file_read` is the same script the projection uses,
 * because what is under test is the state machine.
 */
#include <stdio.h>

enum { LINE_FEED = 10 };
enum { OUTCOME_END = 0, OUTCOME_TOO_LONG = 1, OUTCOME_SYSTEM = 2 };

struct source {
    const int *bytes;
    int length;
    int capacity;
};

static struct source script_source(int script)
{
    static const int two_lines[] = { 97, 98, 10, 99, 100, 10 };
    static const int unterminated[] = { 97, 98, 99 };
    static const int empty[] = { 0 };
    static const int just_a_line_feed[] = { 10 };
    static const int too_long_for_four[] = { 97, 98, 99, 100, 101, 102, 10 };
    static const int exactly_capacity[] = { 49, 50, 51, 52, 53, 54, 55, 10 };
    static const int one_over_capacity[] = { 49, 50, 51, 52, 53, 54, 55, 56, 10 };
    static const int interrupted[] = { 97, 98, 10 };
    static const int spans_two_refills[] = { 97, 98, 99, 100, 101, 102, 103, 10 };
    static const int holds_a_nul[] = { 1, 0, 2, 10 };

    switch (script) {
    case 1:  return (struct source){ two_lines, 6, 8 };
    case 2:  return (struct source){ unterminated, 3, 8 };
    case 3:  return (struct source){ empty, 0, 8 };
    case 4:  return (struct source){ just_a_line_feed, 1, 8 };
    case 5:  return (struct source){ too_long_for_four, 7, 4 };
    case 6:  return (struct source){ exactly_capacity, 8, 8 };
    case 7:  return (struct source){ one_over_capacity, 9, 8 };
    case 8:  return (struct source){ two_lines, 6, 8 };
    case 9:  return (struct source){ interrupted, 3, 8 };
    case 10: return (struct source){ spans_two_refills, 8, 8 };
    case 11: return (struct source){ holds_a_nul, 4, 8 };
    default: return (struct source){ interrupted, 3, 8 };
    }
}

/* How many bytes this read may deliver. Negative is -errno; -4 is EINTR. */
static int read_limit(int script, int step)
{
    if (script == 8) {
        return 1;
    }
    if (script == 9) {
        return step == 0 ? -4 : 8;
    }
    if (script == 10) {
        return 4;
    }
    if (script == 12) {
        return step == 1 ? -5 : 8;
    }
    return 8;
}

static int smaller(int left, int right)
{
    return left < right ? left : right;
}

int main(void)
{
    for (int script = 1; script <= 12; script += 1) {
        struct source source = script_source(script);
        int buffer[8] = { 0 };
        int lengths[8] = { 0 };
        int filled = 0, cursor = 0, ended = 0, consumed = 0;
        int step = 0, calls = 0, lines = 0;
        int outcome = OUTCOME_END, running = 1;

        while (running) {
            int end = -1;
            for (int probe = cursor; probe < filled; probe += 1) {
                if (end < 0 && buffer[probe] == LINE_FEED) {
                    end = probe;
                }
            }

            if (end >= 0) {
                lengths[lines] = end - cursor;
                lines += 1;
                cursor = end + 1;
                continue;
            }

            if (ended) {
                if (filled - cursor > 0) {
                    lengths[lines] = filled - cursor;
                    lines += 1;
                    cursor = filled;
                }
                if (filled - cursor == 0) {
                    outcome = OUTCOME_END;
                    running = 0;
                }
                continue;
            }

            if (cursor > 0) {
                int pending = filled - cursor;
                for (int moved = 0; moved < pending; moved += 1) {
                    buffer[moved] = buffer[cursor + moved];
                }
                filled = pending;
                cursor = 0;
            }
            if (filled >= source.capacity) {
                outcome = OUTCOME_TOO_LONG;
                running = 0;
                continue;
            }

            int limit = read_limit(script, step);
            step += 1;
            calls += 1;
            if (limit < 0) {
                if (-limit != 4) { /* EINTR is retried, not surfaced. */
                    outcome = OUTCOME_SYSTEM;
                    running = 0;
                }
                continue;
            }
            int available = smaller(smaller(source.capacity - filled, limit),
                                    source.length - consumed);
            if (available == 0) {
                ended = 1;
            }
            for (int taken = 0; taken < available; taken += 1) {
                buffer[filled + taken] = source.bytes[consumed + taken];
            }
            filled += available;
            consumed += available;
        }

        int again = outcome == OUTCOME_END && ended && filled - cursor == 0;
        printf("%d\n%d\n%d\n%d\n%d\n", script, outcome, lines, calls, again);
        for (int index = 0; index < lines; index += 1) {
            printf("%d\n", lengths[index]);
        }
    }
    return 0;
}
