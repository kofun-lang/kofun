/* Test-only invocation of the actual maintained analysis implementation. */
#define main stage2_seed_main
#include "../../../bootstrap/stage2/compiler.c"
#undef main
int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--validate") == 0) {
        size_t n = 0; char *source = read_file_with_length(argv[2], &n);
        KofunUnicodeError error;
        if (!kofun_unicode_validate_source((const uint8_t *)source, n, &error)) {
            char message[1024]; kofun_unicode_format_error(&error, "en", message, sizeof(message)); puts(message);
        }
        free(source); return 0;
    }
    if (argc == 7 && strcmp(argv[1], "--place-probe") == 0) {
        char *source = read_file(argv[2]);
        char *hir = build_scope_hir_analysis_mode(source, true, true);
        char *facts = scoped_hir_observations(source, hir);
        char *result = checked_place_render(source, hir, facts, argv[3],
            (int64_t)strtoll(argv[4], NULL, 10), (int64_t)strtoll(argv[5], NULL, 10), (int64_t)strtoll(argv[6], NULL, 10));
        fputs(result, stdout); free(result); free(facts); free(hir); free(source); return 0;
    }
    return stage2_seed_main(argc, argv);
}
