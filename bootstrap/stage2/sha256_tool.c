/*
 * The digest tool this repository uses instead of GNU `sha256sum` (#1213).
 *
 * Every digest that anchors the bootstrap -- `bootstrap/stage2/SHA256SUMS`,
 * `bootstrap/manifest.json`, the release evidence pack, the release assets --
 * was computed by a tool the project neither ships nor tests, and which is not
 * present outside a GNU userland. This one is built from
 * `bootstrap/stage2/sha256.c`, which is already in the tree and already
 * compiled into several gates, so the digests depend on nothing the repository
 * does not own.
 *
 * The output format is GNU `sha256sum`'s, deliberately: `<hex><SP><SP><path>`
 * for digests, `<path>: OK` or `<path>: FAILED` for a check. That is what the
 * committed `SHA256SUMS` files already contain and what the call sites already
 * parse, so adopting this tool moves no bytes.
 *
 *     sha256-tool FILE...      digest each file
 *     sha256-tool              digest standard input, reported as `-`
 *     sha256-tool -            the same, written explicitly
 *     sha256-tool -c SUMS      verify every line of a SHA256SUMS file
 *
 * Exit status is 0 when everything asked for succeeded and 1 otherwise, which
 * is the contract `sha256sum -c` callers already rely on.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sha256.h"

static const char *program = "sha256-tool";

static void fail(const char *message, const char *subject) {
    if (subject != NULL) {
        fprintf(stderr, "%s: %s: %s\n", program, message, subject);
    } else {
        fprintf(stderr, "%s: %s\n", program, message);
    }
}

/* Stream rather than slurp: the seed C is a megabyte today and the generation
 * chain digests executables, so reading whole files into memory would put an
 * arbitrary ceiling on what can be verified. */
static int digest_stream(FILE *input, uint8_t digest[32]) {
    KofunSha256 context;
    uint8_t buffer[65536];
    size_t got;

    kofun_sha256_init(&context);
    while ((got = fread(buffer, 1, sizeof buffer, input)) > 0) {
        kofun_sha256_update(&context, buffer, got);
    }
    if (ferror(input)) {
        return 0;
    }
    kofun_sha256_finish(&context, digest);
    return 1;
}

static int digest_path(const char *path, uint8_t digest[32]) {
    FILE *input;
    int ok;

    if (strcmp(path, "-") == 0) {
        return digest_stream(stdin, digest);
    }
    input = fopen(path, "rb");
    if (input == NULL) {
        return 0;
    }
    ok = digest_stream(input, digest);
    fclose(input);
    return ok;
}

static void format_hex(const uint8_t digest[32], char out[65]) {
    static const char hex[] = "0123456789abcdef";
    int index;

    for (index = 0; index < 32; ++index) {
        out[index * 2] = hex[(digest[index] >> 4) & 0x0f];
        out[index * 2 + 1] = hex[digest[index] & 0x0f];
    }
    out[64] = '\0';
}

static int mode_digest(int count, char **paths) {
    uint8_t digest[32];
    char hex[65];
    int index;
    int failures = 0;

    if (count == 0) {
        if (!digest_stream(stdin, digest)) {
            fail("cannot read standard input", NULL);
            return 1;
        }
        format_hex(digest, hex);
        printf("%s  -\n", hex);
        return 0;
    }
    for (index = 0; index < count; ++index) {
        if (!digest_path(paths[index], digest)) {
            fail("cannot read", paths[index]);
            failures = 1;
            continue;
        }
        format_hex(digest, hex);
        printf("%s  %s\n", hex, paths[index]);
    }
    return failures;
}

/*
 * A SHA256SUMS line is 64 hex digits, whitespace, then the path. GNU writes two
 * spaces for text mode and a space plus `*` for binary mode; both are accepted
 * here so a file written by either tool verifies, which is what makes the
 * switch-over safe rather than a flag day.
 */
static int check_line(char *line, int *malformed) {
    uint8_t digest[32];
    char expected[65];
    char actual[65];
    char *path;
    size_t index;

    *malformed = 0;
    for (index = 0; index < 64; ++index) {
        char c = line[index];
        int is_hex = (c >= '0' && c <= '9') ||
            (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!is_hex) {
            *malformed = 1;
            return 0;
        }
        expected[index] = (c >= 'A' && c <= 'F') ? (char)(c - 'A' + 'a') : c;
    }
    expected[64] = '\0';

    path = line + 64;
    while (*path == ' ' || *path == '\t') {
        ++path;
    }
    if (*path == '*') {
        ++path;
    }
    if (*path == '\0') {
        *malformed = 1;
        return 0;
    }

    if (!digest_path(path, digest)) {
        printf("%s: FAILED open or read\n", path);
        return 0;
    }
    format_hex(digest, actual);
    if (strcmp(expected, actual) != 0) {
        printf("%s: FAILED\n", path);
        return 0;
    }
    printf("%s: OK\n", path);
    return 1;
}

static int mode_check(const char *sums) {
    FILE *input;
    char line[8192];
    int failures = 0;
    int malformed_lines = 0;
    int checked = 0;

    input = (strcmp(sums, "-") == 0) ? stdin : fopen(sums, "rb");
    if (input == NULL) {
        fail("cannot read", sums);
        return 1;
    }
    while (fgets(line, (int)sizeof line, input) != NULL) {
        size_t length = strlen(line);
        int malformed;

        while (length > 0 &&
               (line[length - 1] == '\n' || line[length - 1] == '\r')) {
            line[--length] = '\0';
        }
        if (length == 0) {
            continue;
        }
        if (length < 66) {
            ++malformed_lines;
            continue;
        }
        ++checked;
        if (!check_line(line, &malformed)) {
            if (malformed) {
                --checked;
                ++malformed_lines;
            } else {
                ++failures;
            }
        }
    }
    if (input != stdin) {
        fclose(input);
    }

    if (malformed_lines > 0) {
        fprintf(
            stderr,
            "%s: WARNING: %d line(s) are improperly formatted\n",
            program,
            malformed_lines
        );
    }
    if (failures > 0) {
        fprintf(
            stderr,
            "%s: WARNING: %d computed checksum(s) did NOT match\n",
            program,
            failures
        );
        return 1;
    }
    /* An empty or entirely malformed list is a failure, not a pass. A check
     * that verified nothing must not report success: that is how a truncated
     * SHA256SUMS would silently stop protecting the seed. */
    if (checked == 0) {
        fail("no properly formatted checksum lines found", sums);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0') {
        program = argv[0];
    }
    if (argc >= 2 &&
        (strcmp(argv[1], "-c") == 0 || strcmp(argv[1], "--check") == 0)) {
        if (argc != 3) {
            fail("usage: sha256-tool -c SHA256SUMS", NULL);
            return 1;
        }
        return mode_check(argv[2]);
    }
    return mode_digest(argc - 1, argv + 1);
}
