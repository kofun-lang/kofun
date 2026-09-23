/* Invoke the maintained public file entry; no private capture implementation. */
#define main stage2_seed_main
#include "../../../bootstrap/stage2/compiler.c"
#undef main
int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--validate") == 0) {
        size_t length = 0;
        char *source = read_file_with_length(argv[2], &length);
        KofunUnicodeError error;
        if (!kofun_unicode_validate_source((const uint8_t *)source, length, &error)) {
            char message[1024];
            kofun_unicode_format_error(&error, "en", message, sizeof(message));
            puts(message);
        }
        free(source);
        return 0;
    }
    return stage2_seed_main(argc, argv);
}
