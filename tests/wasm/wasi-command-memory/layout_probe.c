#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* The C side of #1297's three-way layout agreement. It includes the same
 * header the emitter compiles against, WITHOUT the emitter half, and prints
 * every layout constant and the sizes the header's own arithmetic gives for
 * the counts on the command line. The gate's JavaScript recomputes each
 * value from first principles and compares it with this output and with what
 * the running module actually does; a constant that drifted in one place and
 * not another shows up as a three-way disagreement rather than a matching
 * pair of copies. */
#include "../../../bootstrap/wasm/object_arena.h"
#include "../../../bootstrap/wasm/wasi_command_memory.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: layout-probe PAGES [COUNT...]\n");
        return 2;
    }
    char *end = NULL;
    unsigned long pages = strtoul(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || pages == 0 || pages > 65536) {
        fprintf(stderr, "layout-probe: PAGES must be 1..65536\n");
        return 2;
    }
    printf("arena_base %d\n", WCM_ARENA_BASE);
    printf("header_bytes %d\n", WCM_HEADER_BYTES);
    printf("object_align %d\n", WCM_OBJECT_ALIGN);
    printf("max_align %d\n", WCM_MAX_ALIGN);
    printf("pointer_stride %d\n", WCM_POINTER_STRIDE);
    printf("iovec_stride %d\n", WCM_IOVEC_STRIDE);
    printf("iovec_buf_offset %d\n", WCM_IOVEC_BUF_OFFSET);
    printf("iovec_len_offset %d\n", WCM_IOVEC_LEN_OFFSET);
    printf("max_usable_pages %d\n", WCM_MAX_USABLE_PAGES);
    printf("ceiling %lu %" PRIu64 "\n", pages, wcm_ceiling_bytes((uint32_t)pages));
    for (int index = 2; index < argc; ++index) {
        end = NULL;
        unsigned long long count = strtoull(argv[index], &end, 10);
        if (end == argv[index] || *end != '\0') {
            fprintf(stderr, "layout-probe: COUNT must be an unsigned integer\n");
            return 2;
        }
        printf("bytes_size %llu %" PRIu64 "\n", count, wcm_bytes_size(count));
        printf("vector_size %llu %" PRIu64 "\n", count, wcm_vector_size(count));
        printf("iovecs_size %llu %" PRIu64 "\n", count, wcm_iovecs_size(count));
    }
    return 0;
}
