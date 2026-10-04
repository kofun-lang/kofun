#ifndef KOFUN_STAGE2_SCOPED_PARALLEL_V1_H
#define KOFUN_STAGE2_SCOPED_PARALLEL_V1_H

/*
 * Scoped parallelism runtime, RFC-0003 implementation step 5 (#1164): the
 * bounded scheduler and the scope-exit drain for the C11 Stage 2 host target.
 *
 * This file is the runtime only. `par` is still refused with E2S154, and
 * #1166 owns the lowering that emits these calls. A lowered
 * `par |scope| { ... }` is expected to read:
 *
 *     KofunParScope scope;
 *     kofun_par_scope_enter(&scope, workers, spawn_sites, trace, context);
 *     kofun_par_spawn(&scope, body, env, discard, &left);   // scope.spawn
 *     kofun_par_join(&scope, left, &outcome);               // left.join()
 *     kofun_par_scope_exit(&scope, &report);                // the barrier
 *
 * The contract is RFC-0003 "Join, panic, and cancellation" and
 * `spec/concurrency/scoped-parallelism-v1.md` section 7:
 *
 *   - An explicit join waits for its task and yields the task's outcome. A
 *     successful result lives in the task's own `env`, which the join makes
 *     visible to the parent.
 *   - Scope exit joins every handle that is still unjoined, in spawn order. It
 *     discards each unconsumed successful result through the task's `discard`
 *     callback, and it returns only after the join barrier completes.
 *   - A task panic requests cancellation of every unfinished sibling. The
 *     scope still joins every handle, and then reports a panic. The primary
 *     panic is the lexically earliest spawned panicking task. The runtime
 *     selects it after the barrier, so completion order cannot choose it.
 *   - Parent cancellation requests cancellation of every unfinished task. The
 *     scope still joins every handle, and then reports cancellation. A task
 *     panic has precedence over cancellation.
 *   - Cancellation is a request. A task body may observe it with
 *     `kofun_par_cancel_requested` and return normally. V1 promises the
 *     barrier, not interruption: every spawned body runs exactly once.
 *
 * Bounds. A scope owns a fixed set of worker threads and a fixed array of task
 * slots. Both are sized at `kofun_par_scope_enter`, and the runtime never
 * allocates. V1 accepts only a finite lexical set of spawn sites (no loop or
 * recursive spawning), so the lowering knows the slot count. A spawn beyond
 * it fails with KOFUN_PAR_CAPACITY and starts nothing. The limit of 64 tasks
 * is the bounded model's own task limit.
 *
 * Trace. The runtime emits exactly the five logical anchors of RFC-0003
 * "Trace boundary" and nothing else. Only the parent thread emits them, at
 * lexical ownership transitions. So the anchor sequence for one program and
 * one set of task outcomes is the same under every schedule. Task start,
 * worker choice, and completion order are not trace facts; #736 owns them.
 *
 * Panics are status values, not process exits. The C11 Stage 2 runtime
 * already reports failure by status (`kofun_error` sets a flag). A lowered
 * task body reports its panic with `kofun_par_task_panic` and returns. Making
 * that failure flag per task is part of the lowering (#1166).
 *
 * The including translation unit must define `_POSIX_C_SOURCE` as 200809L or
 * later before its first system header, because this header needs
 * <pthread.h>. Link with `-pthread`.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

/* The bounded model's task limit; RFC-0003 "Validation". */
#define KOFUN_PAR_MAX_TASKS 64u
/* Worker threads per scope. A scope never starts more workers than tasks. */
#define KOFUN_PAR_MAX_WORKERS 16u
/* The `task` value of the two scope anchors and of a report with no panic. */
#define KOFUN_PAR_NO_TASK UINT32_MAX

typedef enum {
    KOFUN_PAR_OK = 0,
    /* A null pointer, a zero worker count, or a capacity above the limit. */
    KOFUN_PAR_ARGUMENT = 1,
    /* No worker thread could be started. Nothing was entered. */
    KOFUN_PAR_THREAD = 2,
    /* A spawn beyond the slot count fixed at scope entry. */
    KOFUN_PAR_CAPACITY = 3,
    /* A join of a handle this scope never issued, or of one already joined. */
    KOFUN_PAR_HANDLE = 4,
    /* A call on a scope that is not open. */
    KOFUN_PAR_STATE = 5
} KofunParStatus;

/* A task outcome, and also a scope outcome. */
typedef enum {
    KOFUN_PAR_SUCCESS = 0,
    KOFUN_PAR_PANIC = 1,
    KOFUN_PAR_CANCELLED = 2
} KofunParOutcome;

/* The five logical anchors, RFC-0003 "Trace boundary". There is no sixth. */
typedef enum {
    KOFUN_PAR_SCOPE_ENTER = 0,
    KOFUN_PAR_TASK_SPAWN = 1,
    KOFUN_PAR_TASK_JOIN_EXPLICIT = 2,
    KOFUN_PAR_TASK_JOIN_SCOPE_EXIT = 3,
    KOFUN_PAR_SCOPE_EXIT = 4
} KofunParAnchor;

struct KofunParScope;
typedef struct KofunParTask KofunParTask;

/*
 * A task body runs on a worker thread with its own `env`. It returns its
 * outcome. On success, its result is whatever it wrote into `env`.
 */
typedef KofunParOutcome (*KofunParBody)(KofunParTask *self, void *env);
/* Releases an unconsumed successful result at scope exit. May be null. */
typedef void (*KofunParDiscard)(void *env);
/* Receives each anchor on the parent thread. `task` is a spawn ordinal. */
typedef void (*KofunParTrace)(void *context, KofunParAnchor anchor,
                              uint32_t task);

/* A second-class affine handle: the task's spawn ordinal in its scope. */
typedef struct {
    uint32_t task;
} KofunParHandle;

/* One task slot. Fields are runtime-private; use the functions below. */
struct KofunParTask {
    struct KofunParScope *scope;
    KofunParBody body;
    void *env;
    KofunParDiscard discard;
    const char *panic_message;
    KofunParOutcome outcome;
    uint8_t state;
    bool joined;
};

/* One `par` scope. Embed it (for example on the parent's stack); it is not
 * copyable and lives from `kofun_par_scope_enter` to `kofun_par_scope_exit`. */
typedef struct KofunParScope {
    pthread_mutex_t lock;
    pthread_cond_t work_ready;
    pthread_cond_t task_done;
    pthread_t workers[KOFUN_PAR_MAX_WORKERS];
    uint32_t worker_count;
    uint32_t capacity;
    uint32_t spawned;
    uint32_t next_pending;
    bool shutting_down;
    bool open;
    bool parent_cancelled;
    atomic_bool cancel_requested;
    KofunParTrace trace;
    void *trace_context;
    KofunParTask tasks[KOFUN_PAR_MAX_TASKS];
} KofunParScope;

/* What a scope propagates once its barrier completes. */
typedef struct {
    KofunParOutcome outcome;
    /* The lexically earliest spawned panicking task, or KOFUN_PAR_NO_TASK. */
    uint32_t primary;
    const char *primary_message;
    /* Every other panicking task, in spawn order: related diagnostics. */
    uint32_t related_count;
    uint32_t related[KOFUN_PAR_MAX_TASKS];
} KofunParReport;

/* A stable one-line message for a status, or "" for KOFUN_PAR_OK. */
const char *kofun_par_status_message(KofunParStatus status);

/* The host's online processor count, clamped to 1..KOFUN_PAR_MAX_WORKERS. */
uint32_t kofun_par_default_workers(void);

/*
 * Opens a scope with at most `workers` worker threads and exactly `capacity`
 * task slots, and emits `scope.enter`. It starts min(workers, capacity)
 * threads. If some but not all of them fail to start, the scope runs on the
 * ones that did; the bound only shrinks. `trace` may be null.
 */
KofunParStatus kofun_par_scope_enter(KofunParScope *scope, uint32_t workers,
                                     uint32_t capacity, KofunParTrace trace,
                                     void *trace_context);

/*
 * `scope.spawn(body)`: queues one task and emits `task.spawn`. The task may
 * start at once. Spawn ordinals count up from zero, in call order. V1 has no
 * loop spawning, so call order is lexical order.
 */
KofunParStatus kofun_par_spawn(KofunParScope *scope, KofunParBody body,
                               void *env, KofunParDiscard discard,
                               KofunParHandle *handle);

/*
 * `handle.join()`: waits for the task, consumes the handle, emits
 * `task.join.explicit`, and stores the task's outcome. When the outcome is
 * not KOFUN_PAR_SUCCESS the parent must unwind to `kofun_par_scope_exit`.
 */
KofunParStatus kofun_par_join(KofunParScope *scope, KofunParHandle handle,
                              KofunParOutcome *outcome);

/* Parent cancellation: requests cancellation of every unfinished task. */
KofunParStatus kofun_par_scope_cancel(KofunParScope *scope);

/*
 * The join barrier. Joins each unjoined handle in spawn order (emitting
 * `task.join.scope-exit` and discarding a successful result), stops the
 * workers, applies panic-over-cancellation precedence, fills `report`, and
 * emits `scope.exit`. The scope is closed afterwards.
 */
KofunParStatus kofun_par_scope_exit(KofunParScope *scope,
                                    KofunParReport *report);

/* A task body's cancellation token. */
bool kofun_par_cancel_requested(const KofunParTask *self);

/* Records a task panic and returns KOFUN_PAR_PANIC, for `return` in a body.
 * `message` must stay valid until the scope exits. */
KofunParOutcome kofun_par_task_panic(KofunParTask *self, const char *message);

#endif
