/* Executable host-boundary backstop for RFC-0010 and issue #784. */
#include <stdbool.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    TERMINAL_NONE = 0,
    TERMINAL_CLOSED = 1,
    TERMINAL_CANCELLED = 2
};

typedef struct {
    int64_t identity;
    int64_t live_generation;
    int64_t payload;
    bool unread;
    int terminal;
} ResourceState;

typedef struct {
    int64_t identity;
    int64_t generation;
} AffineTransport;

typedef struct {
    int terminal;
    bool reusable;
    int64_t generation;
} TerminalSummary;

static bool require_live(
    const ResourceState *resource,
    AffineTransport handle
) {
    if (
        resource->terminal != TERMINAL_NONE ||
        handle.identity != resource->identity ||
        handle.generation != resource->live_generation
    ) {
        fputs("EARH01: affine resource handle already consumed\n", stderr);
        return false;
    }
    return true;
}

static ResourceState resource_start(void) {
    ResourceState resource = {
        .identity = INT64_C(17),
        .live_generation = INT64_C(0),
        .payload = INT64_C(10),
        .unread = false,
        .terminal = TERMINAL_NONE
    };
    return resource;
}

static AffineTransport handle_start(const ResourceState *resource) {
    AffineTransport handle = {
        .identity = resource->identity,
        .generation = resource->live_generation
    };
    return handle;
}

static bool transport_read(
    ResourceState *resource,
    AffineTransport handle,
    int64_t *observation
) {
    if (!require_live(resource, handle)) return false;
    *observation = resource->payload;
    return true;
}

static bool transport_write(
    ResourceState *resource,
    AffineTransport handle,
    int64_t amount,
    AffineTransport *successor
) {
    if (!require_live(resource, handle)) return false;
    resource->payload += amount;
    resource->unread = true;
    resource->live_generation += INT64_C(1);
    successor->identity = resource->identity;
    successor->generation = resource->live_generation;
    return true;
}

static bool transport_drain(
    ResourceState *resource,
    AffineTransport handle,
    AffineTransport *successor
) {
    if (!require_live(resource, handle)) return false;
    resource->unread = false;
    resource->live_generation += INT64_C(1);
    successor->identity = resource->identity;
    successor->generation = resource->live_generation;
    return true;
}

static bool transport_close(
    ResourceState *resource,
    AffineTransport handle,
    TerminalSummary *summary
) {
    if (!require_live(resource, handle)) return false;
    resource->terminal = TERMINAL_CLOSED;
    resource->live_generation += INT64_C(1);
    summary->terminal = TERMINAL_CLOSED;
    summary->reusable = false;
    summary->generation = resource->live_generation;
    return true;
}

static bool transport_cancel(
    ResourceState *resource,
    AffineTransport handle,
    TerminalSummary *summary
) {
    if (!require_live(resource, handle)) return false;
    resource->terminal = TERMINAL_CANCELLED;
    resource->live_generation += INT64_C(1);
    summary->terminal = TERMINAL_CANCELLED;
    summary->reusable = false;
    summary->generation = resource->live_generation;
    return true;
}

static int normal(void) {
    ResourceState normal_resource = resource_start();
    AffineTransport initial = handle_start(&normal_resource);
    AffineTransport written;
    AffineTransport drained;
    TerminalSummary closed;
    int64_t observation;

    if (!transport_read(&normal_resource, initial, &observation)) return 1;
    printf("%" PRId64 "\n", observation);
    if (!transport_write(&normal_resource, initial, INT64_C(5), &written)) {
        return 1;
    }
    if (!transport_drain(&normal_resource, written, &drained)) return 1;
    printf("%" PRId64 "\n", drained.generation);
    if (!transport_read(&normal_resource, drained, &observation)) return 1;
    printf("%" PRId64 "\n", observation);
    if (!transport_close(&normal_resource, drained, &closed)) return 1;
    printf("%d\n%d\n", closed.terminal, closed.reusable ? 1 : 0);

    ResourceState cancelled_resource = resource_start();
    AffineTransport cancelled_handle = handle_start(&cancelled_resource);
    TerminalSummary cancelled;
    if (!transport_cancel(
        &cancelled_resource,
        cancelled_handle,
        &cancelled
    )) {
        return 1;
    }
    printf("%d\n%d\n", cancelled.terminal, cancelled.reusable ? 1 : 0);
    return 0;
}

static int dead_generation(void) {
    ResourceState resource = resource_start();
    AffineTransport stale = handle_start(&resource);
    int64_t observation;
    resource.live_generation += INT64_C(1);
    return transport_read(&resource, stale, &observation) ? 0 : 1;
}

static int duplicate_owner(void) {
    ResourceState resource = resource_start();
    AffineTransport first = handle_start(&resource);
    AffineTransport duplicate = first;
    AffineTransport successor;
    int64_t observation;
    if (!transport_write(&resource, first, INT64_C(1), &successor)) return 1;
    return transport_read(&resource, duplicate, &observation) ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "normal") == 0) return normal();
    if (strcmp(argv[1], "dead-generation") == 0) return dead_generation();
    if (strcmp(argv[1], "duplicate-owner") == 0) return duplicate_owner();
    return 2;
}
