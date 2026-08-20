/*
 * #1511. Independent C11 oracle for stdlib/entropy/linux_x86_64.kofun.
 *
 * A test oracle only. The standard-library implementation is Kofun; this file
 * exists so that a wrong loop has to be written twice, in two languages, before
 * it can pass. It is deliberately not a translation of the projection: it is
 * written from the adapter's rules -- retry EINTR, continue from the offset
 * already filled, refuse a count of zero or one past the remaining space, stop
 * on any other error -- and its agreement with the projection is the evidence.
 *
 * It calls no syscall. `getrandom(2)` is replaced by the same script the
 * projection uses, because what is under test is the loop, and a real entropy
 * source would make the output different on every run.
 */
#include <stdio.h>

enum { OUTCOME_FILLED = 0, OUTCOME_IMPOSSIBLE = 1, OUTCOME_SYSTEM = 2 };

static int script_total(int script)
{
    return script == 5 ? 0 : 8;
}

/* What getrandom(2) would have returned at this step. Negative is -errno. */
static int script_return(int script, int step)
{
    switch (script) {
    case 1:
        return 8;
    case 2:
        return step == 0 ? 3 : step == 1 ? 2 : 3;
    case 3:
        return step == 0 ? -4 : 8;
    case 4:
        return step == 0 ? 4 : step == 1 ? -4 : 4;
    case 5:
        return 8;
    case 6:
        return 0;
    case 7:
        return -22;
    case 8:
        return step == 0 ? 3 : 9;
    default:
        return step < 3 ? -4 : 8;
    }
}

struct outcome {
    int kind;
    int detail;
    int calls;
    int offset;
};

static struct outcome fill(int script)
{
    struct outcome result = { OUTCOME_FILLED, 0, 0, 0 };
    int total = script_total(script);
    int step = 0;

    while (result.offset < total) {
        int value = script_return(script, step);
        step += 1;
        result.calls += 1;

        if (value < 0) {
            int error = -value;
            if (error == 4) {
                continue; /* EINTR: the offset is unchanged, ask again. */
            }
            result.kind = OUTCOME_SYSTEM;
            result.detail = error;
            return result;
        }
        if (value == 0 || value > total - result.offset) {
            result.kind = OUTCOME_IMPOSSIBLE;
            result.detail = value;
            return result;
        }
        result.offset += value;
    }
    return result;
}

int main(void)
{
    for (int script = 1; script <= 9; script += 1) {
        struct outcome result = fill(script);
        printf("%d\n%d\n%d\n%d\n%d\n", script, result.kind, result.detail,
               result.calls, result.offset);
    }
    return 0;
}
