/* Read-only probes for the maintained pair. No analysis is implemented here. */
#define main stage2_seed_main
#include "../../../bootstrap/stage2/compiler.c"
#undef main
/* Independent pinned normalization oracle; the projected Kofun algorithm is
 * exercised against these outputs, never against its own generated tables. */
static void unicode_vector(const utf8proc_int32_t *scalars, int count) {
    unsigned char input[256]; int length = 0;
    for (int i = 0; i < count; ++i) {
        printf("%06x", (unsigned)scalars[i]);
        length += (int)utf8proc_encode_char(scalars[i], input + length);
    }
    unsigned char *normalized = NULL;
    utf8proc_ssize_t size = utf8proc_map(input, length, &normalized, UTF8PROC_STABLE | UTF8PROC_COMPOSE);
    printf(" %d\n", size == length && memcmp(input, normalized, (size_t)length) == 0);
    free(normalized);
}
static void unicode_vectors(void) {
    utf8proc_int32_t interesting[16000]; int count = 0;
    for (int cp = 0; cp < 0x110000; ++cp) {
        if (cp >= 0xd800 && cp <= 0xdfff) continue;
        const utf8proc_property_t *p = utf8proc_get_property(cp);
        utf8proc_int32_t d[32];
        int n = (int)utf8proc_decompose_char(cp, d, 32, UTF8PROC_STABLE | UTF8PROC_DECOMPOSE, NULL);
        if (n < 1 || n > 32) abort();
        if (n != 1 || d[0] != cp || p->combining_class || p->comb_index < 0x3ff ||
            (cp >= 0x1100 && cp <= 0x11ff)) {
            utf8proc_int32_t one = cp; unicode_vector(&one, 1); unicode_vector(d, n);
            if (count >= 16000) abort();
            interesting[count++] = cp;
        }
        if (p->comb_index < 0x3ff) for (int k = 0; k < p->comb_length; ++k) {
            utf8proc_int32_t pair[3] = {cp, utf8proc_combinations_second[p->comb_index + k], 0};
            unicode_vector(pair, 2);
            for (int block = 0; block < 3; ++block) {
                pair[2] = pair[1]; pair[1] = block == 0 ? 0x034f : block == 1 ? 0x0301 : 0x0323;
                unicode_vector(pair, 3); pair[1] = pair[2];
            }
        }
    }
    unsigned state = 0x122017;
    for (int i = 0; i < 12000; ++i) {
        utf8proc_int32_t value[8]; int n = 2 + i % 7;
        for (int j = 0; j < n; ++j) {
            state = state * 1664525u + 1013904223u;
            value[j] = interesting[state % (unsigned)count];
        }
        unicode_vector(value, n);
    }
    const utf8proc_int32_t regression[] = {0x00ca, 0x0323, 0x065f};
    unicode_vector(regression, 3);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--unicode-vectors") == 0) { unicode_vectors(); return 0; }
    if (argc == 3 && strcmp(argv[1], "--path-bytes") == 0) {
        size_t length = 0; char *input = read_file_with_length(argv[2], &length);
        printf("%d\n", scoped_hir_logical_path_bytes(input, length)); free(input); return 0;
    }
    if (argc == 7 && strcmp(argv[1], "--frame") == 0) {
        char *id = scoped_hir_hash_frame(argv[2], argv[3], argv[4], argv[5], argv[6]);
        puts(id); free(id); return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--resolved") == 0) {
        char *source = read_file(argv[2]);
        char *hir = build_scope_hir_analysis_mode(source, true, true);
        fputs(hir, stdout);
        free(hir); free(source); return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--validate") == 0) {
        size_t length = 0;
        char *source = read_file_with_length(argv[2], &length);
        KofunUnicodeError error;
        if (!kofun_unicode_validate_source((const uint8_t *)source, length, &error)) {
            char message[1024];
            kofun_unicode_format_error(&error, "en", message, sizeof(message));
            puts(message);
        }
        free(source); return 0;
    }
    return stage2_seed_main(argc, argv);
}
