/* Execute the maintained C half, including faulted lookups at the real guard.
 * Injection belongs only to this fixture, never to the compiler's host policy. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
static int pair_stat(const char *path, struct stat *result) {
    const char *fault = getenv("KOFUN_PAIR_STAT_FAULT");
    if (fault != NULL && strcmp(path, fault) == 0) {
        const char *code = getenv("KOFUN_PAIR_STAT_ERRNO");
        errno = EACCES;
        if (code != NULL) {
            if (strcmp(code, "EIO") == 0) errno = EIO;
            if (strcmp(code, "EOVERFLOW") == 0) errno = EOVERFLOW;
            if (strcmp(code, "EPERM") == 0) errno = EPERM;
            if (strcmp(code, "ENOTDIR") == 0) errno = ENOTDIR;
            if (strcmp(code, "ELOOP") == 0) errno = ELOOP;
        }
        return -1;
    }
    return stat(path, result);
}
#define stat(path, result) pair_stat(path, result)
#define main stage2_seed_main
#ifndef KOFUN_PAIR_COMPILER
#define KOFUN_PAIR_COMPILER "../../../bootstrap/stage2/compiler.c"
#endif
#include KOFUN_PAIR_COMPILER
#undef main
#undef stat

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--pair-scalar") == 0) {
        size_t length = strlen(argv[2]) / 2;
        char *value = allocate(length + 1);
        for (size_t i = 0; i < length; ++i) {
            unsigned byte = 0;
            if (sscanf(argv[2] + i * 2, "%2x", &byte) != 1) return 2;
            value[i] = (char)byte;
        }
        value[length] = '\0';
        Stage2Scalar scalar = stage2_unicode_scalar_at(value, length, strtoll(argv[3], NULL, 10));
        printf("%d|%" PRIu32 "\n", scalar.status, scalar.value);
        free(value);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--pair-name") == 0) {
        char *name = c_identifier_name(argv[2]);
        puts(name);
        free(name);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--pair-identity") == 0) {
        printf("%d\n", stage2_same_file(argv[2], argv[3]));
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--pair-validate") == 0) {
        char *source = read_file(argv[2]);
        KofunUnicodeError error;
        if (!kofun_unicode_validate_source((const uint8_t *)source, strlen(source), &error)) {
            char message[1024];
            kofun_unicode_format_error(&error, "en", message, sizeof(message));
            puts(message);
        }
        free(source);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--pair-lower") == 0) {
        char *source = read_file(argv[2]);
        char *hir = build_scope_hir(source);
        char *output = strncmp(hir, "error[", 6) == 0 ? owned_text(hir) : lower_c(source, hir);
        fputs(output, stdout);
        free(output);
        free(hir);
        free(source);
        return 0;
    }
    return stage2_seed_main(argc, argv);
}
