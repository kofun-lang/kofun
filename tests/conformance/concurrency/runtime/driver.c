/*
 * Driver for the scoped parallelism runtime (#1164).
 *
 * Each fixture below is a `par` program written as the calls its lowering
 * will make (#1166 owns that lowering). A fixture runs many times, on 1, 2
 * and 4 workers, and every run must print the same observation. The
 * observation is the outcome, the primary panic, the discards, and the anchor
 * sequence. A schedule may differ between runs; what the contract promises
 * may not.
 *
 * Every fixture also prints a `model` line. `run.sh` feeds the matching input
 * to the accepted bounded model (`spec/concurrency/scoped-parallelism-v1/`)
 * and compares the two lines. The runtime therefore answers the same scope
 * outcome, primary failure, and per-task joins as the contract on every
 * fixture, not only on the five the spec ships.
 *
 * Tasks that must finish in a given order wait for a flag or for the
 * cancellation token. Each wait is bounded, so a broken barrier fails with a
 * message instead of hanging the gate.
 *
 * A failed check prints its section and line and exits 1. On success the
 * driver prints one deterministic line per section, which the gate compares
 * with expected.stdout.
 */

#define _POSIX_C_SOURCE 200809L

#include "scoped_parallel_v1.h"

#include <inttypes.h>
#include <sched.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_FIXTURE_TASKS 4u
#define WAIT_LIMIT_SECONDS 30

static const char *section = "setup";

static void fail(int line, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    fprintf(stderr, "FAIL [%s] driver.c:%d: ", section, line);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    exit(1);
}

#define CHECK(condition, ...)                                                  \
    do {                                                                       \
        if (!(condition)) fail(__LINE__, __VA_ARGS__);                         \
    } while (0)

/* Waits on another thread's progress, but never forever. */
static double elapsed_since(const struct timespec *start) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)(now.tv_sec - start->tv_sec) +
           (double)(now.tv_nsec - start->tv_nsec) / 1e9;
}

static void await_flag(const atomic_bool *flag, const char *what) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!atomic_load_explicit(flag, memory_order_acquire)) {
        if (elapsed_since(&start) > WAIT_LIMIT_SECONDS) {
            fail(__LINE__, "timed out waiting for %s", what);
        }
        sched_yield();
    }
}

static void await_cancel(const KofunParTask *self, const char *what) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!kofun_par_cancel_requested(self)) {
        if (elapsed_since(&start) > WAIT_LIMIT_SECONDS) {
            fail(__LINE__, "timed out waiting for cancellation in %s", what);
        }
        sched_yield();
    }
}

/* ------------------------------------------------------------------------ */
/* Observation                                                              */
/* ------------------------------------------------------------------------ */

typedef struct Observation Observation;

struct Observation {
    const char *fixture;
    uint32_t count;
    const char *names[MAX_FIXTURE_TASKS];
    /* What each body returned, written by the body before it returns. */
    KofunParOutcome returned[MAX_FIXTURE_TASKS];
    bool explicit_join[MAX_FIXTURE_TASKS];
    char result[MAX_FIXTURE_TASKS][24];
    unsigned discards;
    unsigned anchor_kinds;
    char trace[512];
    size_t trace_length;
    /* Runs on the parent at `scope.exit`: what must already be true. */
    void (*at_exit)(Observation *);
    /* Fixture state the bodies share with the parent. */
    atomic_bool parent_at_exit;
    int64_t effect[MAX_FIXTURE_TASKS];
    KofunParReport report;
};

/* What a task body gets: its own slot in the observation. */
typedef struct {
    Observation *observation;
    uint32_t ordinal;
    const int64_t *items;
    size_t from;
    size_t to;
    int64_t value;
} TaskEnv;

static const char *anchor_name(KofunParAnchor anchor) {
    switch (anchor) {
    case KOFUN_PAR_SCOPE_ENTER:
        return "scope.enter";
    case KOFUN_PAR_TASK_SPAWN:
        return "task.spawn";
    case KOFUN_PAR_TASK_JOIN_EXPLICIT:
        return "task.join.explicit";
    case KOFUN_PAR_TASK_JOIN_SCOPE_EXIT:
        return "task.join.scope-exit";
    case KOFUN_PAR_SCOPE_EXIT:
        return "scope.exit";
    }
    return NULL;
}

static void append(Observation *observation, const char *text) {
    size_t length = strlen(text);
    CHECK(observation->trace_length + length < sizeof observation->trace,
          "trace buffer overflow");
    memcpy(observation->trace + observation->trace_length, text, length + 1);
    observation->trace_length += length;
}

static void record_anchor(void *context, KofunParAnchor anchor,
                          uint32_t task) {
    Observation *observation = context;
    const char *name = anchor_name(anchor);
    CHECK(name != NULL, "anchor %d is outside the five RFC-0003 anchors",
          (int)anchor);
    bool scoped = anchor == KOFUN_PAR_SCOPE_ENTER ||
                  anchor == KOFUN_PAR_SCOPE_EXIT;
    CHECK(scoped == (task == KOFUN_PAR_NO_TASK),
          "%s carries task %" PRIu32, name, task);
    CHECK(scoped || task < observation->count, "%s names task %" PRIu32,
          name, task);
    observation->anchor_kinds |= 1u << (unsigned)anchor;
    if (observation->trace_length != 0) append(observation, ",");
    append(observation, name);
    if (!scoped) {
        append(observation, ":");
        append(observation, observation->names[task]);
    }
    if (anchor == KOFUN_PAR_TASK_JOIN_EXPLICIT) {
        observation->explicit_join[task] = true;
    }
    if (anchor == KOFUN_PAR_SCOPE_EXIT && observation->at_exit != NULL) {
        observation->at_exit(observation);
    }
}

static void count_discard(void *env) {
    TaskEnv *task = env;
    ++task->observation->discards;
}

static KofunParOutcome finish(TaskEnv *env, KofunParOutcome outcome) {
    env->observation->returned[env->ordinal] = outcome;
    return outcome;
}

static const char *outcome_name(KofunParOutcome outcome) {
    switch (outcome) {
    case KOFUN_PAR_SUCCESS:
        return "success";
    case KOFUN_PAR_PANIC:
        return "panic";
    case KOFUN_PAR_CANCELLED:
        return "cancelled";
    }
    return "invalid";
}

/* The model's scope outcome spelling differs from a task outcome's. */
static const char *scope_outcome_name(KofunParOutcome outcome) {
    switch (outcome) {
    case KOFUN_PAR_SUCCESS:
        return "success";
    case KOFUN_PAR_PANIC:
        return "panicked";
    case KOFUN_PAR_CANCELLED:
        return "cancelled";
    }
    return "invalid";
}

static void begin(Observation *observation, const char *fixture,
                  uint32_t count, const char *const *names) {
    memset(observation, 0, sizeof *observation);
    observation->fixture = fixture;
    observation->count = count;
    for (uint32_t index = 0; index < count; ++index) {
        observation->names[index] = names[index];
        observation->result[index][0] = '\0';
    }
    atomic_init(&observation->parent_at_exit, false);
}

static void init_env(TaskEnv *env, Observation *observation,
                     uint32_t ordinal) {
    memset(env, 0, sizeof *env);
    env->observation = observation;
    env->ordinal = ordinal;
}

static KofunParHandle spawn(KofunParScope *scope, KofunParBody body,
                            TaskEnv *env) {
    KofunParHandle handle;
    KofunParStatus status =
        kofun_par_spawn(scope, body, env, count_discard, &handle);
    CHECK(status == KOFUN_PAR_OK, "spawn: %s",
          kofun_par_status_message(status));
    CHECK(handle.task == env->ordinal, "spawn ordinal %" PRIu32
          " for task %" PRIu32, handle.task, env->ordinal);
    return handle;
}

static void enter(KofunParScope *scope, Observation *observation,
                  uint32_t workers) {
    KofunParStatus status = kofun_par_scope_enter(
        scope, workers, observation->count, record_anchor, observation);
    CHECK(status == KOFUN_PAR_OK, "enter: %s",
          kofun_par_status_message(status));
}

static KofunParOutcome join(KofunParScope *scope, KofunParHandle handle) {
    KofunParOutcome outcome;
    KofunParStatus status = kofun_par_join(scope, handle, &outcome);
    CHECK(status == KOFUN_PAR_OK, "join: %s",
          kofun_par_status_message(status));
    return outcome;
}

static void leave(KofunParScope *scope, Observation *observation) {
    atomic_store_explicit(&observation->parent_at_exit, true,
                          memory_order_release);
    KofunParStatus status = kofun_par_scope_exit(scope, &observation->report);
    CHECK(status == KOFUN_PAR_OK, "exit: %s",
          kofun_par_status_message(status));
}

/* The line the golden pins: everything the contract fixes about one run. */
static void describe(const Observation *observation, char *out, size_t size) {
    const KofunParReport *report = &observation->report;
    char related[128] = "-";
    size_t used = 0;
    for (uint32_t index = 0; index < report->related_count; ++index) {
        int written = snprintf(related + used, sizeof related - used, "%s%s",
                               index == 0 ? "" : ",",
                               observation->names[report->related[index]]);
        CHECK(written > 0 && (size_t)written < sizeof related - used,
              "related list overflow");
        used += (size_t)written;
    }
    int written = snprintf(
        out, size,
        "outcome=%s primary=%s message=%s related=%s discards=%u trace=%s",
        scope_outcome_name(report->outcome),
        report->primary == KOFUN_PAR_NO_TASK
            ? "-"
            : observation->names[report->primary],
        report->primary_message == NULL ? "-" : report->primary_message,
        related, observation->discards, observation->trace);
    CHECK(written > 0 && (size_t)written < size, "description overflow");
}

/* The line `run.sh` compares with the model's answer for the same input. */
static int compare_text(const void *left, const void *right) {
    return strcmp(*(const char *const *)left, *(const char *const *)right);
}

static void print_model_line(const Observation *observation) {
    const KofunParReport *report = &observation->report;
    char joins[MAX_FIXTURE_TASKS][96];
    const char *sorted[MAX_FIXTURE_TASKS];
    for (uint32_t index = 0; index < observation->count; ++index) {
        bool explicit_join = observation->explicit_join[index];
        KofunParOutcome outcome = observation->returned[index];
        const char *result = explicit_join && outcome == KOFUN_PAR_SUCCESS
                                 ? observation->result[index]
                                 : "-";
        int written = snprintf(
            joins[index], sizeof joins[index], "%s:%s:%s:%s:%s",
            observation->names[index],
            explicit_join ? "explicit" : "scope-exit", outcome_name(outcome),
            result, explicit_join ? "kept" : "discarded");
        CHECK(written > 0 && (size_t)written < sizeof joins[index],
              "join text overflow");
        sorted[index] = joins[index];
    }
    qsort(sorted, observation->count, sizeof sorted[0], compare_text);

    char primary[64] = "-";
    if (report->outcome == KOFUN_PAR_PANIC) {
        snprintf(primary, sizeof primary, "panic:%s",
                 observation->names[report->primary]);
    } else if (report->outcome == KOFUN_PAR_CANCELLED) {
        snprintf(primary, sizeof primary, "cancellation");
    }
    printf("model %s outcome=%s primary=%s joins=", observation->fixture,
           scope_outcome_name(report->outcome), primary);
    for (uint32_t index = 0; index < observation->count; ++index) {
        printf("%s%s", index == 0 ? "" : ",", sorted[index]);
    }
    printf("\n");
}

/* The checks every run of every fixture must pass. */
static void check_common(const Observation *observation) {
    const KofunParReport *report = &observation->report;
    unsigned discardable = 0;
    for (uint32_t index = 0; index < observation->count; ++index) {
        if (!observation->explicit_join[index] &&
            observation->returned[index] == KOFUN_PAR_SUCCESS) {
            ++discardable;
        }
    }
    CHECK(observation->discards == discardable,
          "%u discards for %u unconsumed successful results",
          observation->discards, discardable);
    if (report->outcome == KOFUN_PAR_PANIC) {
        CHECK(report->primary < observation->count, "panic with no primary");
        CHECK(observation->returned[report->primary] == KOFUN_PAR_PANIC,
              "primary %s did not panic",
              observation->names[report->primary]);
        for (uint32_t index = 0; index < report->primary; ++index) {
            CHECK(observation->returned[index] != KOFUN_PAR_PANIC,
                  "primary %s is not the earliest panic; %s panicked first "
                  "in spawn order",
                  observation->names[report->primary],
                  observation->names[index]);
        }
    } else {
        CHECK(report->primary == KOFUN_PAR_NO_TASK,
              "a primary without a panic");
        CHECK(report->related_count == 0, "related panics without a panic");
    }
}

typedef void (*FixtureRun)(Observation *, uint32_t workers);

/*
 * Runs one fixture `runs` times per worker count and requires every run to
 * describe itself identically. Prints the golden line and the model line.
 */
static void run_fixture(const char *name, FixtureRun run,
                        const uint32_t *workers, size_t worker_counts,
                        unsigned runs) {
    section = name;
    static Observation observation;
    char first[1024] = "";
    char current[1024];
    unsigned total = 0;
    for (size_t choice = 0; choice < worker_counts; ++choice) {
        for (unsigned repeat = 0; repeat < runs; ++repeat) {
            run(&observation, workers[choice]);
            check_common(&observation);
            describe(&observation, current, sizeof current);
            if (total == 0) {
                memcpy(first, current, sizeof first);
            } else {
                CHECK(strcmp(first, current) == 0,
                      "run %u on %" PRIu32 " workers differs:\n  first: %s\n"
                      "  now:   %s",
                      total, workers[choice], first, current);
            }
            ++total;
        }
    }
    printf("%s: runs=%u workers=", name, total);
    for (size_t choice = 0; choice < worker_counts; ++choice) {
        printf("%s%" PRIu32, choice == 0 ? "" : ",", workers[choice]);
    }
    printf(" %s\n", first);
    print_model_line(&observation);
}

/* ------------------------------------------------------------------------ */
/* Fixtures                                                                 */
/* ------------------------------------------------------------------------ */

enum { ITEM_COUNT = 1000, SPLIT = 500 };
static int64_t items[ITEM_COUNT];

/* RFC-0003's own example:
 *
 *     par |scope| {
 *         let left = scope.spawn(fn() => total(read items, 0, split))
 *         let right = scope.spawn(fn() => total(read items, split, len(items)))
 *         left.join() + right.join()
 *     }
 *
 * Both tasks read `items` at once (the read/read exception). */
static KofunParOutcome total_body(KofunParTask *self, void *raw) {
    (void)self;
    TaskEnv *env = raw;
    int64_t sum = 0;
    for (size_t index = env->from; index < env->to; ++index) {
        sum += env->items[index];
    }
    env->value = sum;
    snprintf(env->observation->result[env->ordinal],
             sizeof env->observation->result[env->ordinal], "%" PRId64, sum);
    return finish(env, KOFUN_PAR_SUCCESS);
}

static void two_spawns_two_joins(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"left", "right"};
    begin(observation, "two-spawns-two-joins", 2, names);
    TaskEnv left_env, right_env;
    init_env(&left_env, observation, 0);
    init_env(&right_env, observation, 1);
    left_env.items = right_env.items = items;
    left_env.from = 0;
    left_env.to = right_env.from = SPLIT;
    right_env.to = ITEM_COUNT;

    KofunParScope scope;
    enter(&scope, observation, workers);
    KofunParHandle left = spawn(&scope, total_body, &left_env);
    KofunParHandle right = spawn(&scope, total_body, &right_env);
    CHECK(join(&scope, left) == KOFUN_PAR_SUCCESS, "left did not succeed");
    CHECK(join(&scope, right) == KOFUN_PAR_SUCCESS, "right did not succeed");
    int64_t value = left_env.value + right_env.value;
    leave(&scope, observation);
    CHECK(value == INT64_C(500500), "left.join() + right.join() = %" PRId64,
          value);
}

/* spec fixture result-join: `compute` edits `state`, is joined, and only then
 * does the parent edit `state`. */
static KofunParOutcome compute_body(KofunParTask *self, void *raw) {
    (void)self;
    TaskEnv *env = raw;
    env->observation->effect[0] = 40;
    env->observation->effect[0] += 2;
    env->value = env->observation->effect[0];
    snprintf(env->observation->result[env->ordinal],
             sizeof env->observation->result[env->ordinal], "%" PRId64,
             env->value);
    return finish(env, KOFUN_PAR_SUCCESS);
}

static void result_join(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"compute"};
    begin(observation, "result-join", 1, names);
    TaskEnv env;
    init_env(&env, observation, 0);
    KofunParScope scope;
    enter(&scope, observation, workers);
    KofunParHandle compute = spawn(&scope, compute_body, &env);
    CHECK(join(&scope, compute) == KOFUN_PAR_SUCCESS, "compute failed");
    observation->effect[0] += 1; /* the parent's edit after the join */
    leave(&scope, observation);
    CHECK(env.value == 42 && observation->effect[0] == 43,
          "result %" PRId64 ", state %" PRId64, env.value,
          observation->effect[0]);
}

/* spec fixture scope-exit-unused: the handle is never joined. The task's side
 * effect happens only after the parent has reached scope exit, so a barrier
 * that did not wait would produce the scope's result without it. */
static KofunParOutcome unused_body(KofunParTask *self, void *raw) {
    (void)self;
    TaskEnv *env = raw;
    await_flag(&env->observation->parent_at_exit, "the parent at scope exit");
    env->observation->effect[0] = 1;
    return finish(env, KOFUN_PAR_SUCCESS);
}

static void unused_effect_visible(Observation *observation) {
    CHECK(observation->effect[0] == 1,
          "scope.exit before the unjoined task's side effect");
    CHECK(observation->discards == 1,
          "scope.exit before the unconsumed result was discarded");
}

static void scope_exit_unused(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"unused"};
    begin(observation, "scope-exit-unused", 1, names);
    observation->at_exit = unused_effect_visible;
    TaskEnv env;
    init_env(&env, observation, 0);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, unused_body, &env);
    leave(&scope, observation);
}

/* spec fixture panic-drain: `first` panics; `sibling` sees the cancellation
 * request, finishes its side effect, and returns normally. The panic must
 * propagate only after `sibling` is joined. */
static KofunParOutcome first_panics_body(KofunParTask *self, void *raw) {
    TaskEnv *env = raw;
    finish(env, KOFUN_PAR_PANIC);
    return kofun_par_task_panic(self, "first failed");
}

static KofunParOutcome sibling_body(KofunParTask *self, void *raw) {
    TaskEnv *env = raw;
    await_cancel(self, "sibling");
    env->observation->effect[env->ordinal] = 1;
    return finish(env, KOFUN_PAR_SUCCESS);
}

static void sibling_joined(Observation *observation) {
    CHECK(observation->effect[1] == 1,
          "the panic propagated before the sibling finished");
}

static void panic_drain(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"first", "sibling"};
    begin(observation, "panic-drain", 2, names);
    observation->at_exit = sibling_joined;
    TaskEnv first_env, sibling_env;
    init_env(&first_env, observation, 0);
    init_env(&sibling_env, observation, 1);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, first_panics_body, &first_env);
    (void)spawn(&scope, sibling_body, &sibling_env);
    leave(&scope, observation);
}

/* The lowering's unwind path: the parent joins the panicking task, sees the
 * panic, and goes straight to the barrier. */
static void panic_explicit_join(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"first", "sibling"};
    begin(observation, "panic-explicit-join", 2, names);
    observation->at_exit = sibling_joined;
    TaskEnv first_env, sibling_env;
    init_env(&first_env, observation, 0);
    init_env(&sibling_env, observation, 1);
    KofunParScope scope;
    enter(&scope, observation, workers);
    KofunParHandle first = spawn(&scope, first_panics_body, &first_env);
    (void)spawn(&scope, sibling_body, &sibling_env);
    CHECK(join(&scope, first) == KOFUN_PAR_PANIC,
          "joining the panicking task did not report its panic");
    leave(&scope, observation);
}

/* spec fixture cancellation-drain: the parent cancels; `observed` sees it and
 * returns cancelled; `finished` had nothing to observe. */
static KofunParOutcome observed_body(KofunParTask *self, void *raw) {
    TaskEnv *env = raw;
    await_cancel(self, "observed");
    return finish(env, KOFUN_PAR_CANCELLED);
}

static KofunParOutcome finished_body(KofunParTask *self, void *raw) {
    (void)self;
    return finish(raw, KOFUN_PAR_SUCCESS);
}

static void cancellation_drain(Observation *observation, uint32_t workers) {
    static const char *const names[] = {"observed", "finished"};
    begin(observation, "cancellation-drain", 2, names);
    TaskEnv observed_env, finished_env;
    init_env(&observed_env, observation, 0);
    init_env(&finished_env, observation, 1);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, observed_body, &observed_env);
    (void)spawn(&scope, finished_body, &finished_env);
    CHECK(kofun_par_scope_cancel(&scope) == KOFUN_PAR_OK, "cancel refused");
    leave(&scope, observation);
}

/* Criterion 5: a task observes cancellation and returns normally. The scope
 * still exits through the barrier, after the task's side effect. */
static KofunParOutcome normal_return_body(KofunParTask *self, void *raw) {
    TaskEnv *env = raw;
    await_cancel(self, "normal");
    env->observation->effect[0] = 1;
    return finish(env, KOFUN_PAR_SUCCESS);
}

static void normal_return_visible(Observation *observation) {
    CHECK(observation->effect[0] == 1,
          "scope.exit before the cancelled task returned");
}

static void cancel_return_normally(Observation *observation,
                                   uint32_t workers) {
    static const char *const names[] = {"normal"};
    begin(observation, "cancel-return-normally", 1, names);
    observation->at_exit = normal_return_visible;
    TaskEnv env;
    init_env(&env, observation, 0);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, normal_return_body, &env);
    CHECK(kofun_par_scope_cancel(&scope) == KOFUN_PAR_OK, "cancel refused");
    leave(&scope, observation);
}

/* spec fixture panic-over-cancellation: a panic and a parent cancellation
 * arrive together; the panic wins. */
static KofunParOutcome panicked_body(KofunParTask *self, void *raw) {
    finish(raw, KOFUN_PAR_PANIC);
    return kofun_par_task_panic(self, "panicked failed");
}

static void panic_over_cancellation(Observation *observation,
                                    uint32_t workers) {
    static const char *const names[] = {"earlier", "panicked", "cancelled"};
    begin(observation, "panic-over-cancellation", 3, names);
    TaskEnv earlier_env, panicked_env, cancelled_env;
    init_env(&earlier_env, observation, 0);
    init_env(&panicked_env, observation, 1);
    init_env(&cancelled_env, observation, 2);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, finished_body, &earlier_env);
    (void)spawn(&scope, panicked_body, &panicked_env);
    (void)spawn(&scope, observed_body, &cancelled_env);
    CHECK(kofun_par_scope_cancel(&scope) == KOFUN_PAR_OK, "cancel refused");
    leave(&scope, observation);
}

/* ------------------------------------------------------------------------ */
/* Panic precedence under forced completion orders                          */
/* ------------------------------------------------------------------------ */

/*
 * Both tasks panic. In a "reversed" run `earlier` waits for the cancellation
 * request, which the runtime raises only once it has recorded `later`'s
 * panic. So `later` is complete before `earlier` panics. In a "forward" run
 * the roles swap. A primary chosen by completion order would name `later` in
 * every reversed run; the contract requires `earlier` in every run.
 */
static atomic_uint finish_rank;
static bool reversed_order;

static KofunParOutcome racing_panic_body(KofunParTask *self, void *raw) {
    TaskEnv *env = raw;
    bool waits = reversed_order ? env->ordinal == 0 : env->ordinal == 1;
    if (waits) await_cancel(self, env->observation->names[env->ordinal]);
    env->value = (int64_t)atomic_fetch_add(&finish_rank, 1);
    finish(env, KOFUN_PAR_PANIC);
    return kofun_par_task_panic(self, env->ordinal == 0 ? "earlier failed"
                                                        : "later failed");
}

static void panic_precedence_once(Observation *observation, uint32_t workers,
                                  bool reversed) {
    static const char *const names[] = {"earlier", "later"};
    begin(observation, "panic-precedence", 2, names);
    reversed_order = reversed;
    atomic_store(&finish_rank, 0);
    TaskEnv earlier_env, later_env;
    init_env(&earlier_env, observation, 0);
    init_env(&later_env, observation, 1);
    KofunParScope scope;
    enter(&scope, observation, workers);
    (void)spawn(&scope, racing_panic_body, &earlier_env);
    (void)spawn(&scope, racing_panic_body, &later_env);
    leave(&scope, observation);
    bool later_first = later_env.value < earlier_env.value;
    CHECK(later_first == reversed, "the forced completion order did not hold");
}

static void panic_precedence(void) {
    section = "panic-precedence";
    static Observation observation;
    static const uint32_t workers[] = {2, 4};
    char first[1024] = "";
    char current[1024];
    unsigned runs = 0, later_first = 0, earlier_first = 0;
    for (size_t choice = 0; choice < 2; ++choice) {
        for (unsigned repeat = 0; repeat < 500; ++repeat) {
            bool reversed = repeat % 2 == 0;
            panic_precedence_once(&observation, workers[choice], reversed);
            check_common(&observation);
            const KofunParReport *report = &observation.report;
            CHECK(report->outcome == KOFUN_PAR_PANIC && report->primary == 0,
                  "run %u (%s finished first): primary is %s, not earlier",
                  runs, reversed ? "later" : "earlier",
                  report->primary == KOFUN_PAR_NO_TASK
                      ? "-"
                      : observation.names[report->primary]);
            CHECK(report->related_count == 1 && report->related[0] == 1,
                  "run %u: later is not the one related panic", runs);
            describe(&observation, current, sizeof current);
            if (runs == 0) {
                memcpy(first, current, sizeof first);
            } else {
                CHECK(strcmp(first, current) == 0,
                      "run %u differs:\n  first: %s\n  now:   %s", runs, first,
                      current);
            }
            if (reversed) {
                ++later_first;
            } else {
                ++earlier_first;
            }
            ++runs;
        }
    }
    printf("panic-precedence: runs=%u later-finished-first=%u "
           "earlier-finished-first=%u workers=2,4 %s\n",
           runs, later_first, earlier_first, first);
    print_model_line(&observation);
}

/* ------------------------------------------------------------------------ */
/* Refusals and bounds                                                      */
/* ------------------------------------------------------------------------ */

static unsigned refusal_anchors;

static void count_refusal_anchor(void *context, KofunParAnchor anchor,
                                 uint32_t task) {
    (void)context;
    (void)anchor;
    (void)task;
    ++refusal_anchors;
}

static void refusals(void) {
    section = "refusals";
    KofunParScope scope;
    CHECK(kofun_par_scope_enter(&scope, 0, 1, NULL, NULL) ==
              KOFUN_PAR_ARGUMENT,
          "zero workers accepted");
    CHECK(kofun_par_scope_enter(&scope, KOFUN_PAR_MAX_WORKERS + 1, 1, NULL,
                                NULL) == KOFUN_PAR_ARGUMENT,
          "too many workers accepted");
    CHECK(kofun_par_scope_enter(&scope, 1, KOFUN_PAR_MAX_TASKS + 1, NULL,
                                NULL) == KOFUN_PAR_ARGUMENT,
          "capacity above the model's task limit accepted");
    KofunParHandle handle = {0};
    KofunParOutcome outcome;
    CHECK(kofun_par_join(&scope, handle, &outcome) == KOFUN_PAR_STATE,
          "join on a scope whose entry failed");

    static Observation observation;
    static const char *const names[] = {"only"};
    begin(&observation, "refusals", 1, names);
    TaskEnv env;
    init_env(&env, &observation, 0);
    refusal_anchors = 0;
    CHECK(kofun_par_scope_enter(&scope, KOFUN_PAR_MAX_WORKERS, 1,
                                count_refusal_anchor, NULL) == KOFUN_PAR_OK,
          "enter refused");
    CHECK(scope.worker_count == 1,
          "%" PRIu32 " workers started for one task slot", scope.worker_count);
    CHECK(kofun_par_join(&scope, handle, &outcome) == KOFUN_PAR_HANDLE,
          "join of a handle never issued");
    CHECK(kofun_par_spawn(&scope, finished_body, &env, NULL, &handle) ==
              KOFUN_PAR_OK,
          "first spawn refused");
    KofunParHandle extra;
    CHECK(kofun_par_spawn(&scope, finished_body, &env, NULL, &extra) ==
              KOFUN_PAR_CAPACITY,
          "spawn beyond capacity accepted");
    CHECK(join(&scope, handle) == KOFUN_PAR_SUCCESS, "join failed");
    CHECK(kofun_par_join(&scope, handle, &outcome) == KOFUN_PAR_HANDLE,
          "second join of one handle accepted");
    KofunParReport report;
    CHECK(kofun_par_scope_exit(&scope, &report) == KOFUN_PAR_OK, "exit");
    CHECK(kofun_par_scope_exit(&scope, &report) == KOFUN_PAR_STATE,
          "second exit accepted");
    CHECK(kofun_par_spawn(&scope, finished_body, &env, NULL, &extra) ==
              KOFUN_PAR_STATE,
          "spawn after exit accepted");
    CHECK(kofun_par_scope_cancel(&scope) == KOFUN_PAR_STATE,
          "cancel after exit accepted");
    /* scope.enter, task.spawn, task.join.explicit, scope.exit: the refused
     * calls between them added nothing. */
    CHECK(refusal_anchors == 4, "%u anchors for enter, spawn, join, exit",
          refusal_anchors);

    /* A `par` with no spawn starts no thread and still brackets itself. */
    refusal_anchors = 0;
    CHECK(kofun_par_scope_enter(&scope, 4, 0, count_refusal_anchor, NULL) ==
              KOFUN_PAR_OK,
          "empty scope refused");
    CHECK(scope.worker_count == 0, "an empty scope started workers");
    CHECK(kofun_par_scope_exit(&scope, &report) == KOFUN_PAR_OK &&
              report.outcome == KOFUN_PAR_SUCCESS && refusal_anchors == 2,
          "empty scope did not enter and exit cleanly");

    uint32_t host_workers = kofun_par_default_workers();
    CHECK(host_workers >= 1 && host_workers <= KOFUN_PAR_MAX_WORKERS,
          "default worker count %" PRIu32 " is outside 1..%u", host_workers,
          KOFUN_PAR_MAX_WORKERS);

    printf("refusals: zero-workers too-many-workers over-capacity-scope "
           "unknown-handle over-capacity-spawn double-join double-exit "
           "use-after-exit; refused calls emit no anchor; workers <= tasks; "
           "empty scope starts no thread; default workers within 1..%u\n",
           KOFUN_PAR_MAX_WORKERS);
}

/* ------------------------------------------------------------------------ */
/* The ThreadSanitizer canary                                               */
/* ------------------------------------------------------------------------ */

/*
 * `--race-canary` is the gate's proof that ThreadSanitizer watches this
 * runtime's threads. The parent and a task each write one variable, and
 * nothing orders the two writes. The gate runs it only under
 * -fsanitize=thread and requires a data race report. Without that proof, a
 * clean run could mean only that the sanitizer saw nothing.
 *
 * The handshake uses relaxed atomics, which order the two writes in time but
 * create no happens-before edge. It is needed: if the worker claimed the task
 * only after the parent blocked in the barrier, the mutex the parent released
 * there would order the writes, and there would be no race to report.
 */
static _Alignas(64) int canary_shared;
/* The flags live on their own lines. ThreadSanitizer keeps a few accesses
 * per 8-byte cell; a spin on a flag beside `canary_shared` could evict the
 * parent's write from that history and hide the race the canary exists for. */
static _Alignas(64) atomic_bool canary_started;
static _Alignas(64) atomic_bool canary_parent_wrote;

static void await_relaxed(const atomic_bool *flag, const char *what) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!atomic_load_explicit(flag, memory_order_relaxed)) {
        if (elapsed_since(&start) > WAIT_LIMIT_SECONDS) {
            fail(__LINE__, "timed out waiting for %s", what);
        }
        sched_yield();
    }
}

static KofunParOutcome canary_body(KofunParTask *self, void *raw) {
    (void)self;
    (void)raw;
    atomic_store_explicit(&canary_started, true, memory_order_relaxed);
    await_relaxed(&canary_parent_wrote, "the parent's write");
    canary_shared = 1;
    return KOFUN_PAR_SUCCESS;
}

static int race_canary(void) {
    section = "race-canary";
    KofunParScope scope;
    KofunParHandle handle;
    KofunParReport report;
    atomic_init(&canary_started, false);
    atomic_init(&canary_parent_wrote, false);
    CHECK(kofun_par_scope_enter(&scope, 1, 1, NULL, NULL) == KOFUN_PAR_OK,
          "enter refused");
    CHECK(kofun_par_spawn(&scope, canary_body, NULL, NULL, &handle) ==
              KOFUN_PAR_OK,
          "spawn refused");
    await_relaxed(&canary_started, "the task to start");
    canary_shared = 2;
    atomic_store_explicit(&canary_parent_wrote, true, memory_order_relaxed);
    CHECK(kofun_par_scope_exit(&scope, &report) == KOFUN_PAR_OK,
          "exit refused");
    printf("race-canary: %d\n", canary_shared);
    return 0;
}

/* ------------------------------------------------------------------------ */

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--race-canary") == 0) {
        return race_canary();
    }
    CHECK(argc == 1, "usage: driver [--race-canary]");
    for (int64_t index = 0; index < ITEM_COUNT; ++index) {
        items[index] = index + 1;
    }
    static const uint32_t any_workers[] = {1, 2, 4};
    unsigned seen = 0;

    run_fixture("two-spawns-two-joins", two_spawns_two_joins, any_workers, 3,
                100);
    run_fixture("result-join", result_join, any_workers, 3, 50);
    run_fixture("scope-exit-unused", scope_exit_unused, any_workers, 3, 50);
    run_fixture("panic-drain", panic_drain, any_workers, 3, 50);
    run_fixture("panic-explicit-join", panic_explicit_join, any_workers, 3,
                50);
    run_fixture("cancellation-drain", cancellation_drain, any_workers, 3, 50);
    run_fixture("cancel-return-normally", cancel_return_normally, any_workers,
                3, 50);
    run_fixture("panic-over-cancellation", panic_over_cancellation,
                any_workers, 3, 50);
    panic_precedence();
    refusals();

    /* Every anchor kind each fixture can reach, and nothing else. */
    section = "anchors";
    static Observation probe;
    two_spawns_two_joins(&probe, 2);
    seen |= probe.anchor_kinds;
    scope_exit_unused(&probe, 2);
    seen |= probe.anchor_kinds;
    CHECK(seen == 0x1fu, "anchor kinds seen: %#x", seen);
    printf("anchors: scope.enter task.spawn task.join.explicit "
           "task.join.scope-exit scope.exit\n");
    return 0;
}
