#include "sha256.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    SHA256_DIGEST_BYTES = 32,
    SHA256_HEX_BYTES = 64,
    READ_BUFFER_BYTES = 65536
};

static const char *program_name = "kofun-sha256";

static void print_usage(FILE *stream) {
    fprintf(stream,
        "usage: %s [--] [FILE...]\n"
        "       %s -c CHECKSUMS\n",
        program_name, program_name);
}

static void print_digest(const uint8_t digest[SHA256_DIGEST_BYTES]) {
    static const char hex[] = "0123456789abcdef";
    size_t index;

    for (index = 0; index < SHA256_DIGEST_BYTES; index += 1) {
        putchar(hex[digest[index] >> 4u]);
        putchar(hex[digest[index] & 0x0fu]);
    }
}

static int digest_stream(
    FILE *stream,
    const char *name,
    uint8_t digest[SHA256_DIGEST_BYTES]
) {
    uint8_t buffer[READ_BUFFER_BYTES];
    KofunSha256 context;
    size_t length;

    kofun_sha256_init(&context);
    while ((length = fread(buffer, 1, sizeof(buffer), stream)) != 0u) {
        kofun_sha256_update(&context, buffer, length);
    }
    if (ferror(stream)) {
        fprintf(stderr, "%s: %s: read failed: %s\n",
            program_name, name, strerror(errno));
        return 0;
    }
    kofun_sha256_finish(&context, digest);
    return 1;
}

static int digest_file(
    const char *path,
    uint8_t digest[SHA256_DIGEST_BYTES]
) {
    FILE *stream;
    int ok;

    if (strcmp(path, "-") == 0) {
        return digest_stream(stdin, "standard input", digest);
    }

    stream = fopen(path, "rb");
    if (stream == NULL) {
        fprintf(stderr, "%s: %s: %s\n",
            program_name, path, strerror(errno));
        return 0;
    }
    ok = digest_stream(stream, path, digest);
    if (fclose(stream) != 0) {
        fprintf(stderr, "%s: %s: close failed: %s\n",
            program_name, path, strerror(errno));
        ok = 0;
    }
    return ok;
}

static int hash_paths(int count, char **paths) {
    uint8_t digest[SHA256_DIGEST_BYTES];
    int status = 0;
    int index;

    if (count == 0) {
        if (!digest_file("-", digest)) {
            return 1;
        }
        print_digest(digest);
        puts("  -");
        return 0;
    }

    for (index = 0; index < count; index += 1) {
        if (!digest_file(paths[index], digest)) {
            status = 1;
            continue;
        }
        print_digest(digest);
        printf("  %s\n", paths[index]);
    }
    return status;
}

static int hex_value(unsigned char byte) {
    if (byte >= (unsigned char)'0' && byte <= (unsigned char)'9') {
        return (int)(byte - (unsigned char)'0');
    }
    if (byte >= (unsigned char)'a' && byte <= (unsigned char)'f') {
        return (int)(byte - (unsigned char)'a') + 10;
    }
    if (byte >= (unsigned char)'A' && byte <= (unsigned char)'F') {
        return (int)(byte - (unsigned char)'A') + 10;
    }
    return -1;
}

static int parse_checksum_line(
    char *line,
    size_t length,
    uint8_t expected[SHA256_DIGEST_BYTES],
    const char **path
) {
    size_t index;

    if (length < SHA256_HEX_BYTES + 3u ||
        line[SHA256_HEX_BYTES] != ' ' ||
        (line[SHA256_HEX_BYTES + 1u] != ' ' &&
            line[SHA256_HEX_BYTES + 1u] != '*')) {
        return 0;
    }
    for (index = 0; index < SHA256_DIGEST_BYTES; index += 1) {
        int high = hex_value((unsigned char)line[index * 2u]);
        int low = hex_value((unsigned char)line[index * 2u + 1u]);
        if (high < 0 || low < 0) {
            return 0;
        }
        expected[index] = (uint8_t)((unsigned)high << 4u | (unsigned)low);
    }
    *path = line + SHA256_HEX_BYTES + 2u;
    return **path != '\0';
}

static int read_line(
    FILE *stream,
    char **line,
    size_t *capacity,
    size_t *length
) {
    int byte;

    if (*capacity == 0u) {
        *line = (char *)malloc(256u);
        if (*line == NULL) {
            return -1;
        }
        *capacity = 256u;
    }
    *length = 0;
    for (;;) {
        byte = fgetc(stream);
        if (byte == EOF || byte == '\n') {
            break;
        }
        if (*length + 1u >= *capacity) {
            size_t next_capacity = *capacity == 0u ? 256u : *capacity * 2u;
            char *next_line;
            if (next_capacity <= *capacity) {
                errno = ENOMEM;
                return -1;
            }
            next_line = (char *)realloc(*line, next_capacity);
            if (next_line == NULL) {
                return -1;
            }
            *line = next_line;
            *capacity = next_capacity;
        }
        (*line)[*length] = (char)byte;
        *length += 1u;
    }
    if (byte == EOF && ferror(stream)) {
        return -1;
    }
    if (byte == EOF && *length == 0u) {
        return 0;
    }
    if (*length > 0u && (*line)[*length - 1u] == '\r') {
        *length -= 1u;
    }
    (*line)[*length] = '\0';
    return 1;
}

static int digests_equal(
    const uint8_t left[SHA256_DIGEST_BYTES],
    const uint8_t right[SHA256_DIGEST_BYTES]
) {
    unsigned difference = 0;
    size_t index;

    for (index = 0; index < SHA256_DIGEST_BYTES; index += 1) {
        difference |= (unsigned)(left[index] ^ right[index]);
    }
    return difference == 0u;
}

static int check_manifest(const char *manifest_path) {
    FILE *manifest;
    char *line = NULL;
    size_t capacity = 0;
    size_t length = 0;
    size_t line_number = 0;
    size_t checked = 0;
    int status = 0;
    int read_status;

    if (strcmp(manifest_path, "-") == 0) {
        manifest = stdin;
    } else {
        manifest = fopen(manifest_path, "rb");
        if (manifest == NULL) {
            fprintf(stderr, "%s: %s: %s\n",
                program_name, manifest_path, strerror(errno));
            return 1;
        }
    }

    while ((read_status = read_line(
        manifest, &line, &capacity, &length)) > 0) {
        uint8_t expected[SHA256_DIGEST_BYTES];
        uint8_t actual[SHA256_DIGEST_BYTES];
        const char *path;
        line_number += 1u;
        if (!parse_checksum_line(line, length, expected, &path)) {
            fprintf(stderr,
                "%s: %s:%lu: improperly formatted checksum line\n",
                program_name, manifest_path, (unsigned long)line_number);
            status = 1;
            continue;
        }
        checked += 1u;
        if (!digest_file(path, actual)) {
            printf("%s: FAILED\n", path);
            status = 1;
            continue;
        }
        if (!digests_equal(expected, actual)) {
            printf("%s: FAILED\n", path);
            status = 1;
            continue;
        }
        printf("%s: OK\n", path);
    }

    if (read_status < 0) {
        fprintf(stderr, "%s: %s: read failed: %s\n",
            program_name, manifest_path, strerror(errno));
        status = 1;
    }
    if (checked == 0u) {
        fprintf(stderr, "%s: %s: no properly formatted checksum lines found\n",
            program_name, manifest_path);
        status = 1;
    }
    free(line);
    if (manifest != stdin && fclose(manifest) != 0) {
        fprintf(stderr, "%s: %s: close failed: %s\n",
            program_name, manifest_path, strerror(errno));
        status = 1;
    }
    return status;
}

int main(int argc, char **argv) {
    int first_path = 1;

    if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0') {
        program_name = argv[0];
    }
    if (argc >= 2 &&
        (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        print_usage(stdout);
        return 0;
    }
    if (argc >= 2 &&
        (strcmp(argv[1], "-c") == 0 || strcmp(argv[1], "--check") == 0)) {
        if (argc != 3) {
            print_usage(stderr);
            return 2;
        }
        return check_manifest(argv[2]);
    }
    if (argc >= 2 && strcmp(argv[1], "--") == 0) {
        first_path = 2;
    } else if (argc >= 2 && argv[1][0] == '-' && strcmp(argv[1], "-") != 0) {
        fprintf(stderr, "%s: unsupported option: %s\n", program_name, argv[1]);
        print_usage(stderr);
        return 2;
    }
    return hash_paths(argc - first_path, argv + first_path);
}
