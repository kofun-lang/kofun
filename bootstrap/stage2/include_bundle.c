#define _POSIX_C_SOURCE 200809L

#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

#define MAX_NAME_LENGTH 64u
#define MAX_PATH_LENGTH 4095u
#define MAX_ROWS 64u
#define MAX_TARGET_BYTES 65536u
#define MAX_TOTAL_BYTES (4u * 1024u * 1024u)

#define MANIFEST_PATH "bootstrap/stage2/includes-v1.tsv"
#define INVENTORY_PATH "bootstrap/stage2/includes-v1.files"
#define MANIFEST_LINE_BYTES \
    (MAX_NAME_LENGTH + 1u + MAX_PATH_LENGTH + 1u + 64u + 1u)

typedef struct {
    char name[MAX_NAME_LENGTH + 1u];
    char path[MAX_PATH_LENGTH + 1u];
    uint8_t expected[32];
    uint8_t *bytes;
    size_t length;
} IncludeRow;


static void report(const char *code, const char *format, va_list arguments) {
    printf("error[%s]: ", code);
    vprintf(format, arguments);
    putchar('\n');
}

static bool refuse_path(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    report("E2S226", format, arguments);
    va_end(arguments);
    return false;
}

static bool refuse_digest(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    report("E2S225", format, arguments);
    va_end(arguments);
    return false;
}

static bool name_is_valid(const char *name, size_t length) {
    size_t index;
    if (length == 0u || length > MAX_NAME_LENGTH) return false;
    if (name[0] < 'a' || name[0] > 'z') return false;
    for (index = 1u; index < length; index += 1u) {
        char character = name[index];
        if ((character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') ||
            character == '_') {
            continue;
        }
        return false;
    }
    return true;
}

static bool path_is_valid(const char *path, size_t length) {
    size_t cursor = 0u;
    if (length == 0u || length > MAX_PATH_LENGTH) return false;
    if (path[0] == '/' || path[length - 1u] == '/' ||
        memchr(path, '\\', length) != NULL) {
        return false;
    }
    while (cursor < length) {
        size_t start = cursor;
        size_t component_length;
        while (cursor < length && path[cursor] != '/') cursor += 1u;
        component_length = cursor - start;
        if (component_length == 0u) return false;
        if (component_length == 1u && path[start] == '.') return false;
        if (component_length == 2u && path[start] == '.' &&
            path[start + 1u] == '.') {
            return false;
        }
        if (cursor < length) cursor += 1u;
    }
    return true;
}

static bool sha_is_valid(const char *sha, size_t length) {
    size_t index;
    if (length != 64u) return false;
    for (index = 0u; index < length; index += 1u) {
        char character = sha[index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return false;
        }
    }
    return true;
}

static uint8_t hex_value(char character) {
    if (character >= '0' && character <= '9') {
        return (uint8_t)(character - '0');
    }
    return (uint8_t)(character - 'a' + 10);
}

static void parse_sha(const char *sha, uint8_t digest[32]) {
    size_t index;
    for (index = 0u; index < 32u; index += 1u) {
        digest[index] = (uint8_t)((hex_value(sha[index * 2u]) << 4u) |
            hex_value(sha[index * 2u + 1u]));
    }
}

static bool open_component(int directory_fd, const char *component,
    bool directory, int *result_fd) {
    int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    int descriptor;
    struct stat status;
    if (directory) flags |= O_DIRECTORY;
    descriptor = openat(directory_fd, component, flags);
    if (descriptor < 0) return false;
    if (fstat(descriptor, &status) != 0) {
        close(descriptor);
        return false;
    }
    if (directory) {
        if (!S_ISDIR(status.st_mode)) {
            close(descriptor);
            errno = ENOTDIR;
            return false;
        }
    } else if (!S_ISREG(status.st_mode)) {
        close(descriptor);
        errno = EINVAL;
        return false;
    }
    *result_fd = descriptor;
    return true;
}

static int open_under_root(int root_fd, const char *path, bool directory) {
    const char *cursor = path;
    int current = root_fd;
    bool owned = false;
    for (;;) {
        const char *slash = strchr(cursor, '/');
        size_t length = slash == NULL ? strlen(cursor) : (size_t)(slash - cursor);
        char component[MAX_PATH_LENGTH + 1u];
        bool last = slash == NULL;
        int descriptor;
        if (length == 0u || length > MAX_PATH_LENGTH) {
            if (owned) close(current);
            errno = EINVAL;
            return -1;
        }
        memcpy(component, cursor, length);
        component[length] = '\0';
        if (!open_component(current, component, !last || directory,
                &descriptor)) {
            if (owned) close(current);
            return -1;
        }
        if (owned) close(current);
        current = descriptor;
        owned = true;
        if (last) return descriptor;
        cursor = slash + 1u;
    }
}

/* Read the acquisition inventory against the already parsed manifest. All
 * inputs are opened relative to the same root descriptor. */
static bool check_tracked_paths(FILE *input, const IncludeRow *rows, size_t count) {
    bool tracked[MAX_ROWS] = {false};
    char line[MAX_PATH_LENGTH + 2u];
    size_t lines = 0u;
    while (fgets(line, sizeof(line), input) != NULL) {
        size_t length = strlen(line);
        if (++lines > MAX_ROWS || length == 0u || line[length - 1u] != '\n' ||
            !path_is_valid(line, length - 1u)) {
            fclose(input);
            return refuse_path("malformed tracked path inventory");
        }
        line[length - 1u] = '\0';
        bool found = false;
        for (size_t i = 0; i < count; ++i) {
            if (strcmp(rows[i].path, line) != 0) continue;
            if (tracked[i]) {
                fclose(input);
                return refuse_path("duplicate tracked path");
            }
            tracked[i] = true;
            found = true;
        }
        if (!found) {
            fclose(input);
            return refuse_path("unused tracked path");
        }
    }
    bool ok = !ferror(input);
    if (fclose(input) != 0 || !ok) return refuse_path("cannot read tracked path inventory");
    for (size_t i = 0; i < count; ++i) {
        if (!tracked[i]) return refuse_path("target is absent from tracked inventory");
    }
    return true;
}

static bool check_archive_inventory(int root, const IncludeRow *rows, size_t count) {
    int fd = open_under_root(root, INVENTORY_PATH, false);
    if (fd < 0) return refuse_path("cannot open tracked path inventory");
    FILE *input = fdopen(fd, "rb");
    if (input == NULL) {
        close(fd);
        return refuse_path("cannot open tracked path inventory");
    }
    return check_tracked_paths(input, rows, count);
}

static bool parse_manifest_row(const char *line, size_t length,
    IncludeRow *row) {
    const char *first = memchr(line, '\t', length);
    const char *second;
    size_t name_length;
    size_t path_length;
    size_t sha_length;
    if (first == NULL) return false;
    second = memchr(first + 1, '\t', length - (size_t)(first + 1 - line));
    if (second == NULL) return false;
    if (memchr(second + 1, '\t', length - (size_t)(second + 1 - line)) != NULL) {
        return false;
    }
    name_length = (size_t)(first - line);
    path_length = (size_t)(second - first - 1);
    sha_length = length - (size_t)(second + 1 - line);
    if (!name_is_valid(line, name_length) ||
        !path_is_valid(first + 1, path_length) ||
        !sha_is_valid(second + 1, sha_length)) {
        return false;
    }
    memcpy(row->name, line, name_length);
    row->name[name_length] = '\0';
    memcpy(row->path, first + 1, path_length);
    row->path[path_length] = '\0';
    parse_sha(second + 1, row->expected);
    return true;
}

static bool load_manifest(int root_fd, IncludeRow *rows, size_t *row_count) {
    int descriptor = open_under_root(root_fd, MANIFEST_PATH, false);
    FILE *input;
    char line[MANIFEST_LINE_BYTES + 1u];
    size_t count = 0u;
    if (descriptor < 0) return refuse_path("cannot open include manifest");
    input = fdopen(descriptor, "rb");
    if (input == NULL) {
        close(descriptor);
        return refuse_path("cannot open include manifest");
    }
    while (fgets(line, (int)sizeof(line), input) != NULL) {
        size_t length = strlen(line);
        size_t index;
        if (length == 0u || line[length - 1u] != '\n') {
            fclose(input);
            return refuse_path("include manifest row must end with LF");
        }
        line[--length] = '\0';
        if (length == 0u || count >= MAX_ROWS ||
            !parse_manifest_row(line, length, &rows[count])) {
            fclose(input);
            return refuse_path("malformed include manifest row");
        }
        for (index = 0u; index < count; index += 1u) {
            if (strcmp(rows[index].name, rows[count].name) == 0) {
                fclose(input);
                return refuse_path("duplicate include manifest name `%s`",
                    rows[count].name);
            }
        }
        count += 1u;
    }
    if (ferror(input)) {
        fclose(input);
        return refuse_path("cannot read include manifest");
    }
    if (fclose(input) != 0) {
        return refuse_path("cannot close include manifest");
    }
    *row_count = count;
    return true;
}

static bool read_target(int descriptor, uint8_t **bytes_out,
    size_t *length_out) {
    size_t capacity = MAX_TARGET_BYTES + 1u;
    uint8_t *bytes = malloc(capacity);
    size_t total = 0u;
    if (bytes == NULL) return refuse_path("cannot allocate target buffer");
    for (;;) {
        ssize_t got;
        if (total == capacity) {
            free(bytes);
            return refuse_path("target exceeds the 65536-byte bound");
        }
        got = read(descriptor, bytes + total, capacity - total);
        if (got < 0) {
            if (errno == EINTR) continue;
            free(bytes);
            return refuse_path("cannot read include target");
        }
        if (got == 0) break;
        total += (size_t)got;
    }
    if (total > MAX_TARGET_BYTES) {
        free(bytes);
        return refuse_path("target exceeds the 65536-byte bound");
    }
    *bytes_out = bytes;
    *length_out = total;
    return true;
}

static bool write_all(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t written = 0u;
    while (written < length) {
        ssize_t got = write(descriptor, cursor + written, length - written);
        if (got < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (got == 0) return false;
        written += (size_t)got;
    }
    return true;
}

static bool write_bundle(const char *output_path, const IncludeRow *rows,
    size_t row_count) {
    size_t output_length = strlen(output_path);
    char *temporary;
    int descriptor;
    bool ok = true;
    size_t index;
    if (output_length > SIZE_MAX - sizeof(".tmp.XXXXXX")) {
        return refuse_path("output path is too long");
    }
    temporary = malloc(output_length + sizeof(".tmp.XXXXXX"));
    if (temporary == NULL) return refuse_path("cannot allocate output path");
    memcpy(temporary, output_path, output_length);
    memcpy(temporary + output_length, ".tmp.XXXXXX", sizeof(".tmp.XXXXXX"));
    descriptor = mkstemp(temporary);
    if (descriptor < 0) {
        free(temporary);
        return refuse_path("cannot create adjacent output file");
    }
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 ||
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        ok = false;
    }
    if (ok && !write_all(descriptor, "KOFUN-INCLUDES-1\n", 17u)) ok = false;
    for (index = 0u; ok && index < row_count; index += 1u) {
        char metadata[96];
        int metadata_length = snprintf(metadata, sizeof(metadata), "%s\t%zu\n",
            rows[index].name, rows[index].length);
        if (metadata_length < 0 ||
            (size_t)metadata_length >= sizeof(metadata)) {
            ok = false;
            break;
        }
        if (!write_all(descriptor, metadata, (size_t)metadata_length) ||
            !write_all(descriptor, rows[index].bytes, rows[index].length) ||
            !write_all(descriptor, "\n", 1u)) {
            ok = false;
        }
    }
    if (ok && fsync(descriptor) != 0) ok = false;
    if (close(descriptor) != 0) ok = false;
    if (!ok) {
        unlink(temporary);
        free(temporary);
        return refuse_path("cannot write include bundle");
    }
    if (rename(temporary, output_path) != 0) {
        unlink(temporary);
        free(temporary);
        return refuse_path("cannot publish include bundle");
    }
    free(temporary);
    return true;
}

static int run(int argc, char **argv) {
    const char *root_path;
    const char *output_path;
    int root_fd = -1;
    IncludeRow *rows = NULL;
    size_t row_count = 0u;
    size_t total_bytes = 0u;
    size_t index;
    int status = 1;

    bool git_inventory = argc == 4 && strcmp(argv[3], "--tracked-stdin") == 0;
    if (argc != 3 && !git_inventory) {
        fprintf(stderr, "usage: %s ROOT OUTPUT [--tracked-stdin]\n",
            argc > 0 && argv[0] != NULL ? argv[0] : "include-bundle");
        return 2;
    }
    root_path = argv[1];
    output_path = argv[2];

    root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root_fd < 0) {
        refuse_path("cannot open checkout root");
        goto done;
    }
    rows = calloc(MAX_ROWS, sizeof(*rows));
    if (rows == NULL) {
        refuse_path("cannot allocate include rows");
        goto done;
    }
    if (!load_manifest(root_fd, rows, &row_count) ||
        !check_archive_inventory(root_fd, rows, row_count) ||
        (git_inventory && !check_tracked_paths(stdin, rows, row_count))) goto done;
    for (index = 0u; index < row_count; index += 1u) {
        IncludeRow *row = &rows[index];
        int descriptor;
        uint8_t digest[32];
        descriptor = open_under_root(root_fd, row->path, false);
        if (descriptor < 0) {
            refuse_path("cannot open regular include target `%s`", row->path);
            goto done;
        }
        if (!read_target(descriptor, &row->bytes, &row->length)) {
            close(descriptor);
            goto done;
        }
        if (close(descriptor) != 0) {
            refuse_path("cannot close include target `%s`", row->path);
            goto done;
        }
        if (row->length > MAX_TOTAL_BYTES - total_bytes) {
            refuse_path("include catalog exceeds the 4 MiB total bound");
            goto done;
        }
        total_bytes += row->length;
        if (memchr(row->bytes, 0, row->length) != NULL) {
            refuse_path("include target contains a NUL byte");
            goto done;
        }
        kofun_sha256(row->bytes, row->length, digest);
        if (memcmp(digest, row->expected, sizeof(digest)) != 0) {
            refuse_digest("include target `%s` does not match its manifest digest",
                row->path);
            goto done;
        }
    }
    if (!write_bundle(output_path, rows, row_count)) goto done;
    status = 0;

done:
    for (index = 0u; index < row_count; index += 1u) {
        free(rows[index].bytes);
    }
    free(rows);
    if (root_fd >= 0) close(root_fd);
    return status;
}

int main(int argc, char **argv) {
    return run(argc, argv);
}
