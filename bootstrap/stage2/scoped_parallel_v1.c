#define _POSIX_C_SOURCE 200809L

#include "scoped_parallel_v1.h"

#include <stddef.h>
#include <unistd.h>

/*
 * Scoped parallelism runtime (#1164). `scoped_parallel_v1.h` states the
 * contract; this file states how the scheduler keeps it.
 *
 * One mutex guards the queue and every task's state and outcome. Two
 * conditions hang off it: `work_ready` wakes idle workers, and `task_done`
 * wakes the parent waiting in a join. The parent is the only writer of
 * `spawned` and of each `joined` flag, and the only thread that emits an
 * anchor or calls a `discard`. A join reads a task's outcome under the lock
 * after the worker wrote it under the lock, so everything the body wrote
 * before it returned is visible to the parent after the join.
 *
 * The queue cannot grow. Tasks are claimed from the slot array in spawn order
 * through `next_pending`, and a slot is never reused within a scope.
 *
 * The scheduler cannot deadlock on its own tasks. A handle cannot be
 * captured, so no task waits for a sibling, and every body runs to completion
 * on whichever worker claimed it. Only the parent waits, and only for tasks.
 */

enum {
    TASK_PENDING = 0,
    TASK_RUNNING = 1,
    TASK_DONE = 2
};

const char *kofun_par_status_message(KofunParStatus status) {
    switch (status) {
    case KOFUN_PAR_OK:
        return "";
    case KOFUN_PAR_ARGUMENT:
        return "scoped parallelism: invalid argument";
    case KOFUN_PAR_THREAD:
        return "scoped parallelism: no worker thread could start";
    case KOFUN_PAR_CAPACITY:
        return "scoped parallelism: spawn beyond the scope's task capacity";
    case KOFUN_PAR_HANDLE:
        return "scoped parallelism: handle is unknown or already joined";
    case KOFUN_PAR_STATE:
        return "scoped parallelism: scope is not open";
    }
    return "scoped parallelism: unknown status";
}

uint32_t kofun_par_default_workers(void) {
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    if (online < 1) return 1;
    if ((unsigned long)online > KOFUN_PAR_MAX_WORKERS) {
        return KOFUN_PAR_MAX_WORKERS;
    }
    return (uint32_t)online;
}

static void emit(const KofunParScope *scope, KofunParAnchor anchor,
                 uint32_t task) {
    if (scope->trace != NULL) scope->trace(scope->trace_context, anchor, task);
}

static void *worker_main(void *argument) {
    KofunParScope *scope = argument;
    pthread_mutex_lock(&scope->lock);
    for (;;) {
        while (scope->next_pending == scope->spawned && !scope->shutting_down) {
            pthread_cond_wait(&scope->work_ready, &scope->lock);
        }
        /* Shutdown is requested only after the barrier, so nothing is left
         * pending once it is set; the check keeps that an invariant here. */
        if (scope->next_pending == scope->spawned) break;
        KofunParTask *task = &scope->tasks[scope->next_pending];
        ++scope->next_pending;
        task->state = TASK_RUNNING;
        pthread_mutex_unlock(&scope->lock);

        KofunParOutcome outcome = task->body(task, task->env);
        if (outcome != KOFUN_PAR_SUCCESS && outcome != KOFUN_PAR_PANIC &&
            outcome != KOFUN_PAR_CANCELLED) {
            outcome = kofun_par_task_panic(
                task, "scoped parallelism: task returned no valid outcome");
        }

        pthread_mutex_lock(&scope->lock);
        task->outcome = outcome;
        task->state = TASK_DONE;
        if (outcome == KOFUN_PAR_PANIC) {
            /* A task panic requests cancellation of its unfinished siblings. */
            atomic_store_explicit(&scope->cancel_requested, true,
                                  memory_order_release);
        }
        pthread_cond_broadcast(&scope->task_done);
    }
    pthread_mutex_unlock(&scope->lock);
    return NULL;
}

/* Stops and reaps every worker. Called with nothing pending. */
static void stop_workers(KofunParScope *scope) {
    pthread_mutex_lock(&scope->lock);
    scope->shutting_down = true;
    pthread_cond_broadcast(&scope->work_ready);
    pthread_mutex_unlock(&scope->lock);
    for (uint32_t index = 0; index < scope->worker_count; ++index) {
        pthread_join(scope->workers[index], NULL);
    }
    scope->worker_count = 0;
}

static void destroy_primitives(KofunParScope *scope) {
    pthread_cond_destroy(&scope->task_done);
    pthread_cond_destroy(&scope->work_ready);
    pthread_mutex_destroy(&scope->lock);
}

KofunParStatus kofun_par_scope_enter(KofunParScope *scope, uint32_t workers,
                                     uint32_t capacity, KofunParTrace trace,
                                     void *trace_context) {
    if (scope == NULL) return KOFUN_PAR_ARGUMENT;
    /* Closed until entry succeeds, so a failed entry refuses every later call. */
    scope->open = false;
    if (workers == 0 || workers > KOFUN_PAR_MAX_WORKERS ||
        capacity > KOFUN_PAR_MAX_TASKS) {
        return KOFUN_PAR_ARGUMENT;
    }
    if (pthread_mutex_init(&scope->lock, NULL) != 0) return KOFUN_PAR_THREAD;
    if (pthread_cond_init(&scope->work_ready, NULL) != 0) {
        pthread_mutex_destroy(&scope->lock);
        return KOFUN_PAR_THREAD;
    }
    if (pthread_cond_init(&scope->task_done, NULL) != 0) {
        pthread_cond_destroy(&scope->work_ready);
        pthread_mutex_destroy(&scope->lock);
        return KOFUN_PAR_THREAD;
    }
    scope->worker_count = 0;
    scope->capacity = capacity;
    scope->spawned = 0;
    scope->next_pending = 0;
    scope->shutting_down = false;
    scope->parent_cancelled = false;
    atomic_init(&scope->cancel_requested, false);
    scope->trace = trace;
    scope->trace_context = trace_context;

    uint32_t wanted = workers < capacity ? workers : capacity;
    for (uint32_t index = 0; index < wanted; ++index) {
        if (pthread_create(&scope->workers[index], NULL, worker_main, scope) !=
            0) {
            break;
        }
        ++scope->worker_count;
    }
    if (wanted > 0 && scope->worker_count == 0) {
        destroy_primitives(scope);
        return KOFUN_PAR_THREAD;
    }
    scope->open = true;
    emit(scope, KOFUN_PAR_SCOPE_ENTER, KOFUN_PAR_NO_TASK);
    return KOFUN_PAR_OK;
}

KofunParStatus kofun_par_spawn(KofunParScope *scope, KofunParBody body,
                               void *env, KofunParDiscard discard,
                               KofunParHandle *handle) {
    if (scope == NULL || body == NULL || handle == NULL) {
        return KOFUN_PAR_ARGUMENT;
    }
    if (!scope->open) return KOFUN_PAR_STATE;
    if (scope->spawned == scope->capacity) return KOFUN_PAR_CAPACITY;

    uint32_t ordinal = scope->spawned;
    KofunParTask *task = &scope->tasks[ordinal];
    pthread_mutex_lock(&scope->lock);
    task->scope = scope;
    task->body = body;
    task->env = env;
    task->discard = discard;
    task->panic_message = NULL;
    task->outcome = KOFUN_PAR_SUCCESS;
    task->state = TASK_PENDING;
    task->joined = false;
    scope->spawned = ordinal + 1;
    pthread_cond_signal(&scope->work_ready);
    pthread_mutex_unlock(&scope->lock);

    handle->task = ordinal;
    emit(scope, KOFUN_PAR_TASK_SPAWN, ordinal);
    return KOFUN_PAR_OK;
}

/* Waits for one task and returns its outcome. Parent thread only. */
static KofunParOutcome wait_for(KofunParScope *scope, KofunParTask *task) {
    pthread_mutex_lock(&scope->lock);
    while (task->state != TASK_DONE) {
        pthread_cond_wait(&scope->task_done, &scope->lock);
    }
    KofunParOutcome outcome = task->outcome;
    pthread_mutex_unlock(&scope->lock);
    return outcome;
}

KofunParStatus kofun_par_join(KofunParScope *scope, KofunParHandle handle,
                              KofunParOutcome *outcome) {
    if (scope == NULL || outcome == NULL) return KOFUN_PAR_ARGUMENT;
    if (!scope->open) return KOFUN_PAR_STATE;
    if (handle.task >= scope->spawned) return KOFUN_PAR_HANDLE;
    KofunParTask *task = &scope->tasks[handle.task];
    if (task->joined) return KOFUN_PAR_HANDLE;

    *outcome = wait_for(scope, task);
    task->joined = true;
    emit(scope, KOFUN_PAR_TASK_JOIN_EXPLICIT, handle.task);
    return KOFUN_PAR_OK;
}

KofunParStatus kofun_par_scope_cancel(KofunParScope *scope) {
    if (scope == NULL) return KOFUN_PAR_ARGUMENT;
    if (!scope->open) return KOFUN_PAR_STATE;
    scope->parent_cancelled = true;
    atomic_store_explicit(&scope->cancel_requested, true, memory_order_release);
    return KOFUN_PAR_OK;
}

KofunParStatus kofun_par_scope_exit(KofunParScope *scope,
                                    KofunParReport *report) {
    if (scope == NULL || report == NULL) return KOFUN_PAR_ARGUMENT;
    if (!scope->open) return KOFUN_PAR_STATE;

    /* The barrier: every remaining handle, in spawn order. */
    for (uint32_t index = 0; index < scope->spawned; ++index) {
        KofunParTask *task = &scope->tasks[index];
        if (task->joined) continue;
        KofunParOutcome outcome = wait_for(scope, task);
        task->joined = true;
        emit(scope, KOFUN_PAR_TASK_JOIN_SCOPE_EXIT, index);
        if (outcome == KOFUN_PAR_SUCCESS && task->discard != NULL) {
            task->discard(task->env);
        }
    }
    stop_workers(scope);

    /* Precedence is decided here, after every task is done, and by spawn
     * ordinal alone. Nothing about completion order survives to this point. */
    report->outcome = KOFUN_PAR_SUCCESS;
    report->primary = KOFUN_PAR_NO_TASK;
    report->primary_message = NULL;
    report->related_count = 0;
    bool cancelled = scope->parent_cancelled;
    for (uint32_t index = 0; index < scope->spawned; ++index) {
        const KofunParTask *task = &scope->tasks[index];
        if (task->outcome == KOFUN_PAR_CANCELLED) cancelled = true;
        if (task->outcome != KOFUN_PAR_PANIC) continue;
        if (report->primary == KOFUN_PAR_NO_TASK) { /* primary: earliest */
            report->primary = index;
            report->primary_message = task->panic_message;
        } else {
            report->related[report->related_count++] = index;
        }
    }
    if (report->primary != KOFUN_PAR_NO_TASK) {
        report->outcome = KOFUN_PAR_PANIC;
    } else if (cancelled) {
        report->outcome = KOFUN_PAR_CANCELLED;
    }

    scope->open = false;
    destroy_primitives(scope);
    emit(scope, KOFUN_PAR_SCOPE_EXIT, KOFUN_PAR_NO_TASK);
    return KOFUN_PAR_OK;
}

bool kofun_par_cancel_requested(const KofunParTask *self) {
    if (self == NULL || self->scope == NULL) return false;
    return atomic_load_explicit(&self->scope->cancel_requested,
                                memory_order_acquire);
}

KofunParOutcome kofun_par_task_panic(KofunParTask *self, const char *message) {
    if (self != NULL) self->panic_message = message;
    return KOFUN_PAR_PANIC;
}
