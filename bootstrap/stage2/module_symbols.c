#include "sha256.h"

/* Keep the bootstrap resolver on the same pinned Unicode implementation as
 * the Stage 2 compiler without adding a host-library dependency. */
#include "../../unicode/kofun_unicode.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MODULE_LIMIT 256u
#define SOURCE_LIMIT (1024u * 1024u)
#define TOKEN_LIMIT 262144u
#define IDENTIFIER_LIMIT 256u
#define LOGICAL_PATH_LIMIT 512u
#define HOST_PATH_LIMIT 1024u
#define TOP_LEVEL_LIMIT 4096u
#define CONSTRUCTOR_LIMIT 8192u
#define PARAMETER_LIMIT 256u
#define DELIMITER_DEPTH_LIMIT 256u
#define DECLARATION_TOTAL_LIMIT 65536u
#define CALL_LIMIT 65536u
#define LOOKUP_OPERATION_LIMIT UINT64_C(10000000)

typedef enum {
    TOKEN_IDENTIFIER,
    TOKEN_INTEGER,
    TOKEN_STRING,
    TOKEN_PUNCTUATION,
    TOKEN_ARROW
} TokenKind;

typedef enum {
    DECLARATION_FUNCTION,
    DECLARATION_ADT,
    DECLARATION_CONSTRUCTOR
} DeclarationKind;

typedef enum {
    VISIBILITY_IMPLICIT_PRIVATE,
    VISIBILITY_PRIVATE,
    VISIBILITY_INTERNAL,
    VISIBILITY_PUBLIC
} Visibility;

typedef struct {
    TokenKind kind;
    size_t start;
    size_t end;
    bool line_break_before;
} Token;

typedef struct {
    uint8_t package_id[32];
    uint8_t module_id[32];
    uint8_t file_id[32];
    char logical_path[LOGICAL_PATH_LIMIT + 1u];
    char host_path[HOST_PATH_LIMIT + 1u];
    char *source;
    size_t source_length;
    Token *tokens;
    size_t token_count;
    size_t token_capacity;
    size_t top_level_count;
    size_t constructor_count;
    /* RFC-0012 step 1. Two states and no more: a module is ordinary unless its
     * header carries `trust raw-foreign`. `raw-foreign` is the only value the
     * source can spell, and an unknown one is a syntax error rather than a
     * forward-compatible unknown — a trust class this compiler does not
     * understand must not be read as absent, because absent is the permissive
     * reading and the whole point is that it cannot be reached by accident. */
    bool trust_raw_foreign;
} Module;

typedef struct {
    DeclarationKind kind;
    Visibility visibility;
    size_t module_index;
    char name[IDENTIFIER_LIMIT + 1u];
    unsigned namespace_tag;
    uint8_t namespace_id[32];
    uint8_t symbol_id[32];
    size_t start;
    size_t end;
    size_t name_start;
    size_t name_end;
    size_t signature_start;
    size_t signature_end;
    bool has_owner;
    size_t owner_index;
    size_t constructor_index;
    size_t body_token_start;
    size_t body_token_end;
    /* #1422. `extern "C" fn` declares a signature whose body is in a linked C
     * library. It stays DECLARATION_FUNCTION — it is callable and it has a
     * signature — and this flag is what the reference emitter reads to write a
     * prototype with the source name instead of a definition with the hashed
     * one. `body_token_start == body_token_end` for such a declaration. */
    bool is_external;
} Declaration;

typedef struct {
    size_t caller_index;
    size_t callee_index;
    size_t start;
    size_t end;
} Call;

typedef struct {
    Module modules[MODULE_LIMIT];
    size_t module_count;
    Declaration *declarations;
    size_t declaration_count;
    size_t declaration_capacity;
    Call *calls;
    size_t call_count;
    size_t call_capacity;
    uint8_t namespace_ids[4][32];
    uint64_t lookup_operations;
    char error[2048];
    bool failed;
} Program;

static Program *comparison_program;

static void set_error(Program *program, const char *code, const char *format, ...) {
    char detail[1792];
    va_list arguments;
    if (program->failed) return;
    va_start(arguments, format);
    if (vsnprintf(detail, sizeof(detail), format, arguments) < 0) {
        detail[0] = '\0';
    }
    va_end(arguments);
    snprintf(program->error, sizeof(program->error), "error[%s]: %s", code, detail);
    program->failed = true;
}

static void bytes_to_hex(const uint8_t *bytes, size_t length, char *output) {
    static const char digits[] = "0123456789abcdef";
    size_t index;
    for (index = 0; index < length; index += 1) {
        output[index * 2u] = digits[bytes[index] >> 4u];
        output[index * 2u + 1u] = digits[bytes[index] & UINT8_C(0x0f)];
    }
    output[length * 2u] = '\0';
}

static int hex_digit(unsigned char byte) {
    if (byte >= '0' && byte <= '9') return (int)(byte - '0');
    if (byte >= 'a' && byte <= 'f') return (int)(byte - 'a') + 10;
    return -1;
}

static bool parse_identity(const char *text, uint8_t output[32]) {
    size_t index;
    if (strlen(text) != 64u) return false;
    for (index = 0; index < 32u; index += 1) {
        int high = hex_digit((unsigned char)text[index * 2u]);
        int low = hex_digit((unsigned char)text[index * 2u + 1u]);
        if (high < 0 || low < 0) return false;
        output[index] = (uint8_t)((unsigned)high * 16u + (unsigned)low);
    }
    return true;
}

static bool logical_path_is_valid(const char *path) {
    const char *cursor = path;
    const char *component = path;
    size_t length = strlen(path);
    if (length == 0 || length > LOGICAL_PATH_LIMIT || path[0] == '/' ||
        strchr(path, '\\') != NULL || strchr(path, '|') != NULL) return false;
    while (*cursor != '\0') {
        unsigned char byte = (unsigned char)*cursor;
        if (byte < 0x20u || byte == 0x7fu) return false;
        if (*cursor == '/') {
            size_t component_length = (size_t)(cursor - component);
            if (component_length == 0 ||
                (component_length == 1 && component[0] == '.') ||
                (component_length == 2 && component[0] == '.' && component[1] == '.')) {
                return false;
            }
            component = cursor + 1;
        }
        cursor += 1;
    }
    return cursor != component && strcmp(component, ".") != 0 && strcmp(component, "..") != 0;
}

static bool read_source(Program *program, Module *module) {
    FILE *input = fopen(module->host_path, "rb");
    long measured;
    size_t read_count;
    int close_status;
    if (input == NULL) {
        set_error(program, "E2S48", "cannot read logical source `%s`", module->logical_path);
        return false;
    }
    if (fseek(input, 0, SEEK_END) != 0 || (measured = ftell(input)) < 0 ||
        fseek(input, 0, SEEK_SET) != 0) {
        fclose(input);
        set_error(program, "E2S48", "cannot measure logical source `%s`", module->logical_path);
        return false;
    }
    if ((unsigned long)measured > SOURCE_LIMIT) {
        fclose(input);
        set_error(program, "E2S55", "source `%s` exceeds %u bytes", module->logical_path, SOURCE_LIMIT);
        return false;
    }
    module->source_length = (size_t)measured;
    module->source = malloc(module->source_length + 1u);
    if (module->source == NULL) {
        fclose(input);
        set_error(program, "E2S56", "allocation failed while reading `%s`", module->logical_path);
        return false;
    }
    read_count = fread(module->source, 1, module->source_length, input);
    close_status = fclose(input);
    if (read_count != module->source_length || close_status != 0) {
        free(module->source);
        module->source = NULL;
        module->source_length = 0;
        set_error(program, "E2S48", "cannot read complete logical source `%s`", module->logical_path);
        return false;
    }
    module->source[module->source_length] = '\0';
    return true;
}

static size_t split_inventory_line(char *line, char *fields[5]) {
    size_t count = 1;
    char *cursor = line;
    fields[0] = line;
    while (*cursor != '\0') {
        if (*cursor == '|') {
            if (count >= 5u) return 6u;
            *cursor = '\0';
            fields[count] = cursor + 1;
            count += 1;
        }
        cursor += 1;
    }
    return count;
}

static bool load_inventory(Program *program, const char *path) {
    FILE *input = fopen(path, "rb");
    char line[4096];
    size_t line_number = 0;
    bool have_package = false;
    uint8_t package_id[32];
    if (input == NULL) {
        set_error(program, "E2S48", "cannot open inventory");
        return false;
    }
    while (fgets(line, sizeof(line), input) != NULL) {
        char *fields[5];
        size_t count;
        size_t length;
        Module *module;
        line_number += 1;
        length = strlen(line);
        if (length > 0 && line[length - 1u] == '\n') line[--length] = '\0';
        if (length > 0 && line[length - 1u] == '\r') line[--length] = '\0';
        if (length == 0 || line[0] == '#') continue;
        if (program->module_count >= MODULE_LIMIT) {
            set_error(program, "E2S55", "inventory exceeds %u modules at line %zu", MODULE_LIMIT, line_number);
            break;
        }
        count = split_inventory_line(line, fields);
        if (count != 5u) {
            set_error(program, "E2S48", "inventory line %zu must contain five pipe-delimited fields", line_number);
            break;
        }
        module = &program->modules[program->module_count];
        memset(module, 0, sizeof(*module));
        if (!parse_identity(fields[0], module->package_id) ||
            !parse_identity(fields[1], module->module_id) ||
            !parse_identity(fields[2], module->file_id)) {
            set_error(program, "E2S48", "inventory line %zu contains a non-canonical 32-byte identity", line_number);
            break;
        }
        if (!logical_path_is_valid(fields[3])) {
            set_error(program, "E2S48", "inventory line %zu has invalid logical path", line_number);
            break;
        }
        if (strlen(fields[4]) == 0 || strlen(fields[4]) > HOST_PATH_LIMIT) {
            set_error(program, "E2S48", "inventory line %zu has invalid source operand", line_number);
            break;
        }
        memcpy(module->logical_path, fields[3], strlen(fields[3]) + 1u);
        memcpy(module->host_path, fields[4], strlen(fields[4]) + 1u);
        if (!have_package) {
            memcpy(package_id, module->package_id, sizeof(package_id));
            have_package = true;
        } else if (memcmp(package_id, module->package_id, sizeof(package_id)) != 0) {
            set_error(program, "E2S48", "inventory line %zu belongs to a different PackageId", line_number);
            break;
        }
        if (!read_source(program, module)) break;
        program->module_count += 1;
    }
    if (!program->failed && ferror(input)) {
        set_error(program, "E2S48", "inventory read failed");
    }
    fclose(input);
    if (!program->failed && program->module_count == 0) {
        set_error(program, "E2S48", "inventory contains no modules");
    }
    return !program->failed;
}

static int compare_modules(const void *left, const void *right) {
    const Module *a = left;
    const Module *b = right;
    int result = memcmp(a->module_id, b->module_id, 32u);
    if (result != 0) return result;
    result = memcmp(a->file_id, b->file_id, 32u);
    if (result != 0) return result;
    return strcmp(a->logical_path, b->logical_path);
}

static bool order_and_validate_inventory(Program *program) {
    size_t index;
    qsort(program->modules, program->module_count, sizeof(program->modules[0]), compare_modules);
    for (index = 1; index < program->module_count; index += 1) {
        if (memcmp(program->modules[index - 1u].module_id,
                program->modules[index].module_id, 32u) == 0) {
            char module_hex[65];
            bytes_to_hex(program->modules[index].module_id, 32u, module_hex);
            set_error(
                program,
                "E2S49",
                "duplicate ModuleId %s for `%s` and `%s`; V1 permits exactly one source per module",
                module_hex,
                program->modules[index - 1u].logical_path,
                program->modules[index].logical_path
            );
            return false;
        }
    }
    return true;
}

static bool add_token(
    Program *program,
    Module *module,
    TokenKind kind,
    size_t start,
    size_t end,
    bool line_break_before
) {
    Token *resized;
    if (module->token_count >= TOKEN_LIMIT) {
        set_error(program, "E2S55", "token count in `%s` exceeds %u at bytes %zu..%zu",
            module->logical_path, TOKEN_LIMIT, start, end);
        return false;
    }
    if (module->token_count == module->token_capacity) {
        size_t capacity = module->token_capacity == 0 ? 256u : module->token_capacity * 2u;
        if (capacity > TOKEN_LIMIT) capacity = TOKEN_LIMIT;
        resized = realloc(module->tokens, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S56", "token allocation failed for `%s`", module->logical_path);
            return false;
        }
        module->tokens = resized;
        module->token_capacity = capacity;
    }
    module->tokens[module->token_count] = (Token){
        .kind = kind,
        .start = start,
        .end = end,
        .line_break_before = line_break_before
    };
    module->token_count += 1;
    return true;
}

static bool identifier_start_at(
    const Module *module,
    size_t offset,
    size_t *width
) {
    unsigned char byte = (unsigned char)module->source[offset];
    uint32_t codepoint;
    if (byte < 0x80u) {
        *width = 1u;
        return isalpha(byte) || byte == '_';
    }
    return kofun_unicode_decode((const uint8_t *)module->source,
        module->source_length, offset, &codepoint, width) &&
        kofun_unicode_is_xid_start(codepoint);
}

static bool identifier_continue_at(
    const Module *module,
    size_t offset,
    size_t *width
) {
    unsigned char byte = (unsigned char)module->source[offset];
    uint32_t codepoint;
    if (byte < 0x80u) {
        *width = 1u;
        return isalnum(byte) || byte == '_';
    }
    return kofun_unicode_decode((const uint8_t *)module->source,
        module->source_length, offset, &codepoint, width) &&
        kofun_unicode_is_xid_continue(codepoint);
}

static bool tokenize(Program *program, Module *module) {
    size_t cursor = 0;
    bool line_break = false;
    while (cursor < module->source_length) {
        size_t start;
        unsigned char byte = (unsigned char)module->source[cursor];
        if (isspace(byte)) {
            if (byte == '\n') line_break = true;
            cursor += 1;
            continue;
        }
        if (module->source[cursor] == '#') {
            while (cursor < module->source_length && module->source[cursor] != '\n') cursor += 1;
            continue;
        }
        start = cursor;
        {
            size_t width = 0u;
            if (identifier_start_at(module, cursor, &width)) {
            cursor += width;
            while (cursor < module->source_length) {
                if (!identifier_continue_at(module, cursor, &width)) break;
                cursor += width;
            }
            if (cursor - start > IDENTIFIER_LIMIT) {
                set_error(program, "E2S55", "identifier in `%s` exceeds %u bytes at bytes %zu..%zu",
                    module->logical_path, IDENTIFIER_LIMIT, start, cursor);
                return false;
            }
            if (!add_token(program, module, TOKEN_IDENTIFIER, start, cursor, line_break)) return false;
            line_break = false;
            continue;
            }
        }
        if (byte >= 0x80u) {
            uint32_t codepoint = 0u;
            size_t width = 0u;
            (void)kofun_unicode_decode((const uint8_t *)module->source,
                module->source_length, cursor, &codepoint, &width);
            set_error(program, "E2S50",
                "invalid Unicode identifier scalar U+%04X in `%s` at bytes %zu..%zu",
                (unsigned)codepoint, module->logical_path, start,
                start + (width == 0u ? 1u : width));
            return false;
        }
        if (isdigit(byte)) {
            cursor += 1;
            while (cursor < module->source_length && isdigit((unsigned char)module->source[cursor])) cursor += 1;
            if (!add_token(program, module, TOKEN_INTEGER, start, cursor, line_break)) return false;
            line_break = false;
            continue;
        }
        if (byte == '"') {
            bool escaped = false;
            cursor += 1;
            while (cursor < module->source_length) {
                char current = module->source[cursor];
                if (!escaped && current == '"') {
                    cursor += 1;
                    break;
                }
                if (!escaped && current == '\n') break;
                if (!escaped && current == '\\') escaped = true;
                else escaped = false;
                cursor += 1;
            }
            if (cursor > module->source_length || cursor == 0 || module->source[cursor - 1u] != '"') {
                set_error(program, "E2S50", "unterminated text literal in `%s` at bytes %zu..%zu",
                    module->logical_path, start, cursor);
                return false;
            }
            if (!add_token(program, module, TOKEN_STRING, start, cursor, line_break)) return false;
            line_break = false;
            continue;
        }
        if (byte == '-' && cursor + 1u < module->source_length && module->source[cursor + 1u] == '>') {
            cursor += 2u;
            if (!add_token(program, module, TOKEN_ARROW, start, cursor, line_break)) return false;
            line_break = false;
            continue;
        }
        if (strchr("(){}[],:.=|+-*/<>!", (int)byte) != NULL) {
            cursor += 1;
            if (!add_token(program, module, TOKEN_PUNCTUATION, start, cursor, line_break)) return false;
            line_break = false;
            continue;
        }
        set_error(program, "E2S50", "unsupported byte in `%s` at bytes %zu..%zu",
            module->logical_path, start, start + 1u);
        return false;
    }
    return true;
}

static bool token_equals(const Module *module, const Token *token, const char *text) {
    size_t length = strlen(text);
    return token->end - token->start == length &&
        memcmp(module->source + token->start, text, length) == 0;
}

static bool punctuation_equals(const Module *module, const Token *token, char punctuation) {
    return token->kind == TOKEN_PUNCTUATION && token->end == token->start + 1u &&
        module->source[token->start] == punctuation;
}

static bool copy_identifier(
    Program *program,
    const Module *module,
    const Token *token,
    char output[IDENTIFIER_LIMIT + 1u]
) {
    size_t length;
    if (token->kind != TOKEN_IDENTIFIER) {
        set_error(program, "E2S50", "expected identifier in `%s` at bytes %zu..%zu",
            module->logical_path, token->start, token->end);
        return false;
    }
    length = token->end - token->start;
    if (length == 0 || length > IDENTIFIER_LIMIT) {
        set_error(program, "E2S55", "identifier in `%s` exceeds the bootstrap limit at bytes %zu..%zu",
            module->logical_path, token->start, token->end);
        return false;
    }
    memcpy(output, module->source + token->start, length);
    output[length] = '\0';
    return true;
}

static bool reserve_declaration(Program *program) {
    Declaration *resized;
    if (program->declaration_count >= DECLARATION_TOTAL_LIMIT) {
        set_error(program, "E2S55", "inventory exceeds %u declarations", DECLARATION_TOTAL_LIMIT);
        return false;
    }
    if (program->declaration_count < program->declaration_capacity) return true;
    {
        size_t capacity = program->declaration_capacity == 0 ? 256u : program->declaration_capacity * 2u;
        if (capacity > DECLARATION_TOTAL_LIMIT) capacity = DECLARATION_TOTAL_LIMIT;
        resized = realloc(program->declarations, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S56", "declaration allocation failed");
            return false;
        }
        program->declarations = resized;
        program->declaration_capacity = capacity;
    }
    return true;
}

static bool add_declaration(
    Program *program,
    size_t module_index,
    DeclarationKind kind,
    Visibility visibility,
    const Token *name_token,
    size_t start,
    size_t end,
    size_t signature_start,
    size_t signature_end,
    size_t *output_index
) {
    Module *module = &program->modules[module_index];
    Declaration *declaration;
    if (kind == DECLARATION_CONSTRUCTOR) {
        if (module->constructor_count >= CONSTRUCTOR_LIMIT) {
            set_error(program, "E2S55", "module `%s` exceeds %u constructors",
                module->logical_path, CONSTRUCTOR_LIMIT);
            return false;
        }
        module->constructor_count += 1;
    } else {
        if (module->top_level_count >= TOP_LEVEL_LIMIT) {
            set_error(program, "E2S55", "module `%s` exceeds %u top-level declarations",
                module->logical_path, TOP_LEVEL_LIMIT);
            return false;
        }
        module->top_level_count += 1;
    }
    if (!reserve_declaration(program)) return false;
    declaration = &program->declarations[program->declaration_count];
    memset(declaration, 0, sizeof(*declaration));
    declaration->kind = kind;
    declaration->visibility = visibility;
    declaration->module_index = module_index;
    declaration->namespace_tag = kind == DECLARATION_ADT ? 1u : 0u;
    declaration->start = start;
    declaration->end = end;
    declaration->name_start = name_token->start;
    declaration->name_end = name_token->end;
    declaration->signature_start = signature_start;
    declaration->signature_end = signature_end;
    if (!copy_identifier(program, module, name_token, declaration->name)) return false;
    *output_index = program->declaration_count;
    program->declaration_count += 1;
    return true;
}

static bool find_closing(
    Program *program,
    const Module *module,
    size_t opening,
    char open,
    char close,
    size_t *closing
) {
    size_t cursor;
    size_t depth = 0;
    for (cursor = opening; cursor < module->token_count; cursor += 1) {
        if (punctuation_equals(module, &module->tokens[cursor], open)) {
            depth += 1;
            if (depth > DELIMITER_DEPTH_LIMIT) {
                set_error(program, "E2S55", "delimiter depth in `%s` exceeds %u at bytes %zu..%zu",
                    module->logical_path, DELIMITER_DEPTH_LIMIT,
                    module->tokens[cursor].start, module->tokens[cursor].end);
                return false;
            }
        } else if (punctuation_equals(module, &module->tokens[cursor], close)) {
            if (depth == 0) break;
            depth -= 1;
            if (depth == 0) {
                *closing = cursor;
                return true;
            }
        }
    }
    set_error(program, "E2S50", "unclosed `%c` in `%s` at bytes %zu..%zu",
        open, module->logical_path, module->tokens[opening].start, module->tokens[opening].end);
    return false;
}

/*
 * `trust` is a contextual keyword. It is a keyword on exactly one line — the
 * one immediately after a module header — and an ordinary identifier
 * everywhere else, including as a function or field name.
 *
 * Every refusal below is a syntax error at its own span, and none of them is
 * repaired from the filesystem path. That is DD-025's rule for the `module`
 * header itself, and trust joins the same authority under the same refusals:
 * a class that could be inferred from a path is a class a rename can change.
 */
static bool parse_trust_line(Program *program, Module *module, size_t *cursor) {
    size_t current = *cursor;
    size_t newlines = 0;
    size_t index;
    size_t value;

    if (current >= module->token_count ||
        !token_equals(module, &module->tokens[current], "trust")) {
        return true;
    }

    /* Exactly one newline since the header's last token. Two means a blank line
     * came between, and a `trust` line that floats free is refused rather than
     * reattached to the header above it. */
    for (index = module->tokens[current - 1u].end;
         index < module->tokens[current].start;
         index += 1) {
        if (module->source[index] == '\n') newlines += 1;
    }
    if (newlines != 1u) {
        set_error(program, "E2S57",
            "`trust` is not on the line after the module header in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[current].start,
            module->tokens[current].end);
        return false;
    }

    /* `raw-foreign`, spelled as three adjacent tokens with nothing between
     * them. Allowing space around the hyphen would make `raw - foreign` a
     * second spelling of one class, and a class with two spellings is a class
     * two readers can disagree about. */
    value = current + 1u;
    if (value + 2u >= module->token_count ||
        module->tokens[value].line_break_before ||
        module->tokens[value].kind != TOKEN_IDENTIFIER ||
        module->tokens[value + 1u].start != module->tokens[value].end ||
        module->tokens[value + 2u].start != module->tokens[value + 1u].end ||
        !token_equals(module, &module->tokens[value], "raw") ||
        !punctuation_equals(module, &module->tokens[value + 1u], '-') ||
        !token_equals(module, &module->tokens[value + 2u], "foreign")) {
        size_t end = value < module->token_count
            ? module->tokens[value].end
            : module->tokens[current].end;
        set_error(program, "E2S57",
            "unknown trust class in `%s` at bytes %zu..%zu; v1 defines only `raw-foreign`",
            module->logical_path, module->tokens[current].start, end);
        return false;
    }

    /* Nothing else on the line. A trailing token is a second thing being said
     * on a line that says one thing. */
    if (value + 3u < module->token_count &&
        !module->tokens[value + 3u].line_break_before) {
        set_error(program, "E2S57",
            "trailing text after the trust class in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[value + 3u].start,
            module->tokens[value + 3u].end);
        return false;
    }

    module->trust_raw_foreign = true;
    *cursor = value + 3u;

    if (*cursor < module->token_count &&
        token_equals(module, &module->tokens[*cursor], "trust")) {
        set_error(program, "E2S57",
            "duplicate `trust` line in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[*cursor].start,
            module->tokens[*cursor].end);
        return false;
    }
    return true;
}

static bool skip_module_header(Program *program, Module *module, size_t *cursor) {
    size_t current = 0;
    bool expect_identifier = true;
    if (module->token_count == 0 || !token_equals(module, &module->tokens[0], "module")) {
        /* An anonymous source has no module header, so it has nowhere to carry
         * a trust class, and this refuses to infer one from the path. There is
         * therefore no way to compile a raw binding except as a declared
         * manifest source — which is also the only mode anything could import
         * it in. */
        if (module->token_count != 0 &&
            token_equals(module, &module->tokens[0], "trust")) {
            set_error(program, "E2S57",
                "`trust` in a source with no module header in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[0].start,
                module->tokens[0].end);
            return false;
        }
        *cursor = 0;
        return true;
    }
    current = 1;
    while (current < module->token_count && !module->tokens[current].line_break_before) {
        if (expect_identifier) {
            if (module->tokens[current].kind != TOKEN_IDENTIFIER) {
                set_error(program, "E2S50", "malformed module header in `%s` at bytes %zu..%zu",
                    module->logical_path, module->tokens[current].start, module->tokens[current].end);
                return false;
            }
        } else if (!punctuation_equals(module, &module->tokens[current], '.')) {
            set_error(program, "E2S50", "malformed module header in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
        expect_identifier = !expect_identifier;
        current += 1;
    }
    if (current == 1 || expect_identifier) {
        size_t end = current == 0 ? 0 : module->tokens[current - 1u].end;
        set_error(program, "E2S50", "malformed module header in `%s` at bytes 0..%zu",
            module->logical_path, end);
        return false;
    }
    *cursor = current;
    return parse_trust_line(program, module, cursor);
}

static bool parse_function_form(
    Program *program,
    size_t module_index,
    size_t declaration_start,
    Visibility visibility,
    bool external,
    size_t *cursor
) {
    Module *module = &program->modules[module_index];
    size_t current = *cursor + 1u;
    size_t name_index;
    size_t parameters_close;
    size_t body_open;
    size_t body_close;
    size_t parameter_count = 0;
    size_t declaration_index;
    if (current >= module->token_count || module->tokens[current].kind != TOKEN_IDENTIFIER) {
        set_error(program, "E2S52", "function name is missing in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[*cursor].start, module->tokens[*cursor].end);
        return false;
    }
    name_index = current++;
    if (current >= module->token_count || !punctuation_equals(module, &module->tokens[current], '(')) {
        set_error(program, "E2S52", "function `%.*s` is missing `(` in `%s` at bytes %zu..%zu",
            (int)(module->tokens[name_index].end - module->tokens[name_index].start),
            module->source + module->tokens[name_index].start,
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    if (!find_closing(program, module, current, '(', ')', &parameters_close)) return false;
    if (parameters_close > current + 1u) {
        size_t scan = current + 1u;
        while (scan < parameters_close) {
            if (module->tokens[scan].kind != TOKEN_IDENTIFIER ||
                scan + 2u >= parameters_close ||
                !punctuation_equals(module, &module->tokens[scan + 1u], ':') ||
                module->tokens[scan + 2u].kind != TOKEN_IDENTIFIER) {
                set_error(program, "E2S52",
                    "malformed parameter in `%s` at bytes %zu..%zu",
                    module->logical_path, module->tokens[scan].start,
                    module->tokens[scan].end);
                return false;
            }
            parameter_count += 1u;
            if (parameter_count > PARAMETER_LIMIT) {
                set_error(program, "E2S55", "function in `%s` exceeds %u parameters at bytes %zu..%zu",
                    module->logical_path, PARAMETER_LIMIT,
                    module->tokens[current].start, module->tokens[parameters_close].end);
                return false;
            }
            scan += 3u;
            if (scan < parameters_close) {
                if (!punctuation_equals(module, &module->tokens[scan], ',')) {
                    set_error(program, "E2S52",
                        "parameters in `%s` require `,` at bytes %zu..%zu",
                        module->logical_path, module->tokens[scan].start,
                        module->tokens[scan].end);
                    return false;
                }
                scan += 1u;
                if (scan == parameters_close) {
                    set_error(program, "E2S52",
                        "trailing parameter comma is outside #111 in `%s` at bytes %zu..%zu",
                        module->logical_path, module->tokens[scan - 1u].start,
                        module->tokens[scan - 1u].end);
                    return false;
                }
            }
        }
    }
    current = parameters_close + 1u;
    if (current >= module->token_count || module->tokens[current].kind != TOKEN_ARROW) {
        set_error(program, "E2S52", "function signature in `%s` is missing `->` at bytes %zu..%zu",
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    current += 1;
    if (current >= module->token_count || module->tokens[current].kind != TOKEN_IDENTIFIER) {
        set_error(program, "E2S52", "function return type is missing in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    current += 1;
    if (external) {
        /* #1422. The signature ends at the return type: the body is in a C
         * library. A `{` here is the author writing a definition where only a
         * declaration can be honoured, and saying so is more useful than
         * accepting the body and silently ignoring it. */
        if (current < module->token_count &&
            punctuation_equals(module, &module->tokens[current], '{')) {
            set_error(program, "E2S52",
                "`extern \"C\" fn` declares a signature and cannot carry a body in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[current].start,
                module->tokens[current].end);
            return false;
        }
        if (!add_declaration(
                program, module_index, DECLARATION_FUNCTION, visibility,
                &module->tokens[name_index], declaration_start,
                module->tokens[current - 1u].end, declaration_start,
                module->tokens[current - 1u].end, &declaration_index
            )) return false;
        program->declarations[declaration_index].body_token_start = 0u;
        program->declarations[declaration_index].body_token_end = 0u;
        program->declarations[declaration_index].is_external = true;
        *cursor = current;
        return true;
    }
    if (current >= module->token_count || !punctuation_equals(module, &module->tokens[current], '{')) {
        set_error(program, "E2S52", "function body is missing in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    body_open = current;
    if (!find_closing(program, module, body_open, '{', '}', &body_close)) return false;
    if (!add_declaration(
            program, module_index, DECLARATION_FUNCTION, visibility,
            &module->tokens[name_index], declaration_start,
            module->tokens[body_close].end, declaration_start,
            module->tokens[body_open].start, &declaration_index
        )) return false;
    program->declarations[declaration_index].body_token_start = body_open + 1u;
    program->declarations[declaration_index].body_token_end = body_close;
    program->declarations[declaration_index].is_external = false;
    *cursor = body_close + 1u;
    return true;
}

static bool parse_function(
    Program *program,
    size_t module_index,
    size_t declaration_start,
    Visibility visibility,
    size_t *cursor
) {
    return parse_function_form(
        program, module_index, declaration_start, visibility, false, cursor);
}

static bool parse_adt(
    Program *program,
    size_t module_index,
    size_t declaration_start,
    Visibility visibility,
    size_t *cursor
) {
    Module *module = &program->modules[module_index];
    size_t current = *cursor + 1u;
    size_t name_index;
    size_t adt_index;
    size_t local_index = 0;
    size_t last_end;
    if (current >= module->token_count || module->tokens[current].kind != TOKEN_IDENTIFIER) {
        set_error(program, "E2S50", "type name is missing in `%s` at bytes %zu..%zu",
            module->logical_path, module->tokens[*cursor].start, module->tokens[*cursor].end);
        return false;
    }
    name_index = current++;
    if (current >= module->token_count || !punctuation_equals(module, &module->tokens[current], '=')) {
        set_error(program, "E2S50", "type declaration in `%s` is missing `=` at bytes %zu..%zu",
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    current += 1;
    if (current >= module->token_count || !punctuation_equals(module, &module->tokens[current], '|')) {
        set_error(program, "E2S50", "type declaration in `%s` requires a leading `|` at bytes %zu..%zu",
            module->logical_path, module->tokens[name_index].start, module->tokens[name_index].end);
        return false;
    }
    if (!add_declaration(
            program, module_index, DECLARATION_ADT, visibility,
            &module->tokens[name_index], declaration_start,
            module->tokens[name_index].end, declaration_start,
            module->tokens[name_index].end, &adt_index
        )) return false;
    last_end = module->tokens[name_index].end;
    while (current < module->token_count && punctuation_equals(module, &module->tokens[current], '|')) {
        size_t constructor_name;
        size_t constructor_index;
        size_t constructor_end;
        current += 1;
        if (current >= module->token_count || module->tokens[current].kind != TOKEN_IDENTIFIER) {
            set_error(program, "E2S50", "constructor name is missing in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[current - 1u].start, module->tokens[current - 1u].end);
            return false;
        }
        constructor_name = current++;
        constructor_end = module->tokens[constructor_name].end;
        if (current < module->token_count && punctuation_equals(module, &module->tokens[current], '(')) {
            size_t close;
            if (!find_closing(program, module, current, '(', ')', &close)) return false;
            if (close != current + 4u ||
                module->tokens[current + 1u].kind != TOKEN_IDENTIFIER ||
                !punctuation_equals(module, &module->tokens[current + 2u], ':') ||
                !token_equals(module, &module->tokens[current + 3u], "Int")) {
                set_error(program, "E2S50", "constructor payload in `%s` must be exactly `(name: Int)` at bytes %zu..%zu",
                    module->logical_path, module->tokens[current].start, module->tokens[close].end);
                return false;
            }
            constructor_end = module->tokens[close].end;
            current = close + 1u;
        }
        if (!add_declaration(
                program, module_index, DECLARATION_CONSTRUCTOR, visibility,
                &module->tokens[constructor_name], module->tokens[constructor_name].start,
                constructor_end, module->tokens[constructor_name].start,
                constructor_end, &constructor_index
            )) return false;
        program->declarations[constructor_index].has_owner = true;
        program->declarations[constructor_index].owner_index = adt_index;
        program->declarations[constructor_index].constructor_index = local_index;
        local_index += 1u;
        last_end = constructor_end;
    }
    if (local_index < 2u) {
        set_error(program, "E2S50", "type `%s` in `%s` requires at least two constructors at bytes %zu..%zu",
            program->declarations[adt_index].name, module->logical_path,
            module->tokens[name_index].start, last_end);
        return false;
    }
    program->declarations[adt_index].end = last_end;
    program->declarations[adt_index].signature_end = last_end;
    *cursor = current;
    return true;
}

static bool collect_module(Program *program, size_t module_index) {
    Module *module = &program->modules[module_index];
    size_t cursor;
    if (!tokenize(program, module) || !skip_module_header(program, module, &cursor)) return false;
    while (cursor < module->token_count) {
        size_t declaration_start = module->tokens[cursor].start;
        Visibility visibility = VISIBILITY_IMPLICIT_PRIVATE;
        if (token_equals(module, &module->tokens[cursor], "pub") ||
            token_equals(module, &module->tokens[cursor], "internal") ||
            token_equals(module, &module->tokens[cursor], "private")) {
            if (token_equals(module, &module->tokens[cursor], "pub")) visibility = VISIBILITY_PUBLIC;
            else if (token_equals(module, &module->tokens[cursor], "internal")) visibility = VISIBILITY_INTERNAL;
            else visibility = VISIBILITY_PRIVATE;
            cursor += 1;
            if (cursor >= module->token_count) {
                set_error(program, "E2S50", "visibility modifier without declaration in `%s` at bytes %zu..%zu",
                    module->logical_path, declaration_start, module->source_length);
                return false;
            }
            if (punctuation_equals(module, &module->tokens[cursor], '(')) {
                set_error(program, "E2S54", "restricted visibility is outside #111 in `%s` at bytes %zu..%zu",
                    module->logical_path, declaration_start, module->tokens[cursor].end);
                return false;
            }
        }
        if (token_equals(module, &module->tokens[cursor], "fn")) {
            if (!parse_function(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "type")) {
            if (!parse_adt(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "import") ||
            token_equals(module, &module->tokens[cursor], "use")) {
            set_error(program, "E2S54", "imports are deferred to #113 in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start, module->tokens[cursor].end);
            return false;
        } else if (token_equals(module, &module->tokens[cursor], "trust")) {
            /* Named before the general refusal below, so a `trust` line that
             * drifted away from its header says so instead of arriving as an
             * unsupported declaration. The two are the same token and very
             * different mistakes. */
            set_error(program, "E2S57",
                "`trust` is not attached to a module header in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start,
                module->tokens[cursor].end);
            return false;
        } else {
            set_error(program, "E2S50", "unsupported top-level declaration in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start, module->tokens[cursor].end);
            return false;
        }
    }
    return true;
}

static void store_u16be(uint8_t output[2], uint16_t value) {
    output[0] = (uint8_t)(value >> 8u);
    output[1] = (uint8_t)value;
}

static void store_u32be(uint8_t output[4], uint32_t value) {
    output[0] = (uint8_t)(value >> 24u);
    output[1] = (uint8_t)(value >> 16u);
    output[2] = (uint8_t)(value >> 8u);
    output[3] = (uint8_t)value;
}

static void framed_hash(
    const char *domain,
    const uint8_t *payload,
    size_t payload_length,
    uint8_t digest[32]
) {
    KofunSha256 context;
    uint8_t u16[2];
    uint8_t u32[4];
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    size_t domain_length = strlen(domain);
    store_u16be(u16, (uint16_t)domain_length);
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, domain_length);
    kofun_sha256_update(&context, u32, sizeof(u32));
    kofun_sha256_update(&context, payload, payload_length);
    kofun_sha256_finish(&context, digest);
}

static void hash_field(
    KofunSha256 *context,
    uint16_t tag,
    const uint8_t *value,
    size_t length
) {
    uint8_t u16[2];
    uint8_t u32[4];
    store_u16be(u16, tag);
    store_u32be(u32, (uint32_t)length);
    kofun_sha256_update(context, u16, sizeof(u16));
    kofun_sha256_update(context, u32, sizeof(u32));
    kofun_sha256_update(context, value, length);
}

static const char *kind_name(DeclarationKind kind) {
    switch (kind) {
        case DECLARATION_FUNCTION: return "function";
        case DECLARATION_ADT: return "adt";
        case DECLARATION_CONSTRUCTOR: return "constructor";
    }
    return "invalid";
}

static const char *namespace_name(unsigned tag) {
    switch (tag) {
        case 0: return "value";
        case 1: return "type";
        case 2: return "module";
        case 3: return "meta";
    }
    return "invalid";
}

static const char *visibility_name(Visibility visibility) {
    switch (visibility) {
        case VISIBILITY_IMPLICIT_PRIVATE: return "private(implicit)";
        case VISIBILITY_PRIVATE: return "private(explicit)";
        case VISIBILITY_INTERNAL: return "internal";
        case VISIBILITY_PUBLIC: return "pub";
    }
    return "invalid";
}

static void compute_symbol_hash(
    const uint8_t module_id[32],
    const uint8_t namespace_id[32],
    const char *kind,
    const char *name,
    uint8_t digest[32]
) {
    const char *domain = "kofun.id.symbol/v1";
    size_t domain_length = strlen(domain);
    size_t kind_length = strlen(kind);
    size_t name_length = strlen(name);
    size_t payload_length = 88u + kind_length + name_length;
    uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)domain_length);
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, domain_length);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)kind, kind_length);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name, name_length);
    kofun_sha256_finish(&context, digest);
}

static void compute_identities(Program *program) {
    static const char *payloads[4] = {
        "kofun.namespace-id/v1\ntag=0\nname=value\n",
        "kofun.namespace-id/v1\ntag=1\nname=type\n",
        "kofun.namespace-id/v1\ntag=2\nname=module\n",
        "kofun.namespace-id/v1\ntag=3\nname=meta\n"
    };
    size_t index;
    for (index = 0; index < 4u; index += 1) {
        framed_hash("kofun.id.namespace/v1", (const uint8_t *)payloads[index],
            strlen(payloads[index]), program->namespace_ids[index]);
    }
    for (index = 0; index < program->declaration_count; index += 1) {
        Declaration *declaration = &program->declarations[index];
        Module *module = &program->modules[declaration->module_index];
        memcpy(declaration->namespace_id, program->namespace_ids[declaration->namespace_tag], 32u);
        compute_symbol_hash(module->module_id, declaration->namespace_id,
            kind_name(declaration->kind), declaration->name, declaration->symbol_id);
    }
}

static int compare_duplicate_indices(const void *left, const void *right) {
    size_t a_index = *(const size_t *)left;
    size_t b_index = *(const size_t *)right;
    const Declaration *a = &comparison_program->declarations[a_index];
    const Declaration *b = &comparison_program->declarations[b_index];
    const Module *a_module = &comparison_program->modules[a->module_index];
    const Module *b_module = &comparison_program->modules[b->module_index];
    int result = memcmp(a_module->module_id, b_module->module_id, 32u);
    if (result != 0) return result;
    if (a->namespace_tag != b->namespace_tag) return a->namespace_tag < b->namespace_tag ? -1 : 1;
    result = strcmp(a->name, b->name);
    if (result != 0) return result;
    result = memcmp(a->symbol_id, b->symbol_id, 32u);
    if (result != 0) return result;
    result = strcmp(a_module->logical_path, b_module->logical_path);
    if (result != 0) return result;
    if (a->name_start != b->name_start) return a->name_start < b->name_start ? -1 : 1;
    return a_index < b_index ? -1 : a_index != b_index;
}

static bool validate_duplicates(Program *program) {
    size_t *indices;
    size_t index;
    indices = malloc(program->declaration_count * sizeof(*indices));
    if (indices == NULL && program->declaration_count != 0) {
        set_error(program, "E2S56", "duplicate-index allocation failed");
        return false;
    }
    for (index = 0; index < program->declaration_count; index += 1) indices[index] = index;
    comparison_program = program;
    qsort(indices, program->declaration_count, sizeof(*indices), compare_duplicate_indices);
    for (index = 1; index < program->declaration_count; index += 1) {
        Declaration *first = &program->declarations[indices[index - 1u]];
        Declaration *second = &program->declarations[indices[index]];
        Module *first_module = &program->modules[first->module_index];
        Module *second_module = &program->modules[second->module_index];
        if (memcmp(first_module->module_id, second_module->module_id, 32u) == 0 &&
            first->namespace_tag == second->namespace_tag && strcmp(first->name, second->name) == 0) {
            Declaration *left = first;
            Declaration *right = second;
            Module *left_module = first_module;
            Module *right_module = second_module;
            char left_id[65];
            char right_id[65];
            int identity_order = memcmp(left->symbol_id, right->symbol_id, 32u);
            if (identity_order > 0 || (identity_order == 0 &&
                (strcmp(left_module->logical_path, right_module->logical_path) > 0 ||
                (strcmp(left_module->logical_path, right_module->logical_path) == 0 &&
                 left->name_start > right->name_start)))) {
                left = second;
                right = first;
                left_module = second_module;
                right_module = first_module;
            }
            bytes_to_hex(left->symbol_id, 32u, left_id);
            bytes_to_hex(right->symbol_id, 32u, right_id);
            set_error(program, "E2S51",
                "duplicate %s name `%s`: %s `%s` bytes %zu..%zu symbol %s; %s `%s` bytes %zu..%zu symbol %s",
                namespace_name(left->namespace_tag), left->name,
                kind_name(left->kind), left_module->logical_path, left->name_start, left->name_end, left_id,
                kind_name(right->kind), right_module->logical_path, right->name_start, right->name_end, right_id);
            free(indices);
            return false;
        }
    }
    free(indices);
    return true;
}

static bool reserve_call(Program *program) {
    Call *resized;
    if (program->call_count >= CALL_LIMIT) {
        set_error(program, "E2S55", "inventory exceeds %u resolved calls", CALL_LIMIT);
        return false;
    }
    if (program->call_count < program->call_capacity) return true;
    {
        size_t capacity = program->call_capacity == 0 ? 128u : program->call_capacity * 2u;
        if (capacity > CALL_LIMIT) capacity = CALL_LIMIT;
        resized = realloc(program->calls, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S56", "call allocation failed");
            return false;
        }
        program->calls = resized;
        program->call_capacity = capacity;
    }
    return true;
}

static bool declaration_name_equals_token(
    const Declaration *declaration,
    const Module *module,
    const Token *token
) {
    size_t length = token->end - token->start;
    return strlen(declaration->name) == length &&
        memcmp(declaration->name, module->source + token->start, length) == 0;
}

static bool keyword_call(const Module *module, const Token *token) {
    static const char *keywords[] = { "if", "while", "match", "return", "let", "take" };
    size_t index;
    for (index = 0; index < sizeof(keywords) / sizeof(keywords[0]); index += 1) {
        if (token_equals(module, token, keywords[index])) return true;
    }
    return false;
}

static bool resolve_bodies(Program *program) {
    size_t declaration_index;
    for (declaration_index = 0; declaration_index < program->declaration_count; declaration_index += 1) {
        Declaration *caller = &program->declarations[declaration_index];
        Module *module;
        size_t cursor;
        if (caller->kind != DECLARATION_FUNCTION) continue;
        module = &program->modules[caller->module_index];
        for (cursor = caller->body_token_start; cursor < caller->body_token_end; cursor += 1) {
            Token *token = &module->tokens[cursor];
            size_t candidate;
            size_t found = SIZE_MAX;
            bool found_other_module = false;
            if (token_equals(module, token, "fn")) {
                set_error(program, "E2S50", "body-local function is not a top-level declaration in `%s` at bytes %zu..%zu",
                    module->logical_path, token->start, token->end);
                return false;
            }
            if (token->kind != TOKEN_IDENTIFIER || cursor + 1u >= caller->body_token_end ||
                !punctuation_equals(module, &module->tokens[cursor + 1u], '(') || keyword_call(module, token)) {
                continue;
            }
            if (cursor > caller->body_token_start && punctuation_equals(module, &module->tokens[cursor - 1u], '.')) {
                set_error(program, "E2S54", "qualified/cross-module call in `%s` is deferred to #113 at bytes %zu..%zu",
                    module->logical_path, token->start, token->end);
                return false;
            }
            for (candidate = 0; candidate < program->declaration_count; candidate += 1) {
                Declaration *target = &program->declarations[candidate];
                program->lookup_operations += 1u;
                if (program->lookup_operations > LOOKUP_OPERATION_LIMIT) {
                    set_error(program, "E2S55", "body lookup exceeds %llu operations",
                        (unsigned long long)LOOKUP_OPERATION_LIMIT);
                    return false;
                }
                if (target->namespace_tag != 0u || !declaration_name_equals_token(target, module, token)) continue;
                if (target->module_index == caller->module_index) found = candidate;
                else found_other_module = true;
            }
            if (found == SIZE_MAX) {
                set_error(program, found_other_module ? "E2S54" : "E2S53",
                    found_other_module
                        ? "cross-module value `%.*s` in `%s` requires an import (#113) at bytes %zu..%zu"
                        : "unknown same-module value `%.*s` in `%s` at bytes %zu..%zu",
                    (int)(token->end - token->start), module->source + token->start,
                    module->logical_path, token->start, token->end);
                return false;
            }
            if (!reserve_call(program)) return false;
            program->calls[program->call_count] = (Call){
                .caller_index = declaration_index,
                .callee_index = found,
                .start = token->start,
                .end = token->end
            };
            program->call_count += 1;
        }
    }
    return true;
}

static int compare_output_indices(const void *left, const void *right) {
    size_t a_index = *(const size_t *)left;
    size_t b_index = *(const size_t *)right;
    const Declaration *a = &comparison_program->declarations[a_index];
    const Declaration *b = &comparison_program->declarations[b_index];
    const Module *a_module = &comparison_program->modules[a->module_index];
    const Module *b_module = &comparison_program->modules[b->module_index];
    if (a->module_index != b->module_index) return a->module_index < b->module_index ? -1 : 1;
    if (a->namespace_tag != b->namespace_tag) return a->namespace_tag < b->namespace_tag ? -1 : 1;
    {
        int result = memcmp(a->symbol_id, b->symbol_id, 32u);
        if (result != 0) return result;
        result = strcmp(a_module->logical_path, b_module->logical_path);
        if (result != 0) return result;
    }
    if (a->start != b->start) return a->start < b->start ? -1 : 1;
    return a_index < b_index ? -1 : a_index != b_index;
}

static int compare_calls(const void *left, const void *right) {
    const Call *a = left;
    const Call *b = right;
    const Declaration *a_caller = &comparison_program->declarations[a->caller_index];
    const Declaration *b_caller = &comparison_program->declarations[b->caller_index];
    int result = memcmp(a_caller->symbol_id, b_caller->symbol_id, 32u);
    if (result != 0) return result;
    if (a->start != b->start) return a->start < b->start ? -1 : 1;
    return 0;
}

static bool emit_output(Program *program, const char *path) {
    FILE *output;
    size_t *indices;
    size_t index;
    char package_hex[65];
    indices = malloc(program->declaration_count * sizeof(*indices));
    if (indices == NULL && program->declaration_count != 0) {
        set_error(program, "E2S56", "output-index allocation failed");
        return false;
    }
    for (index = 0; index < program->declaration_count; index += 1) indices[index] = index;
    comparison_program = program;
    qsort(indices, program->declaration_count, sizeof(*indices), compare_output_indices);
    qsort(program->calls, program->call_count, sizeof(program->calls[0]), compare_calls);
    output = fopen(path, "wb");
    if (output == NULL) {
        free(indices);
        set_error(program, "E2S56", "cannot create output artifact");
        return false;
    }
    bytes_to_hex(program->modules[0].package_id, 32u, package_hex);
    fprintf(output, "kofun-module-symbols/v1\npackage|id=%s\n", package_hex);
    for (index = 0; index < program->module_count; index += 1) {
        char module_hex[65];
        char file_hex[65];
        bytes_to_hex(program->modules[index].module_id, 32u, module_hex);
        bytes_to_hex(program->modules[index].file_id, 32u, file_hex);
        /* The fact, stated on every module rather than only on the ones that
         * carry it. A field that appears only when set cannot distinguish
         * "ordinary" from "written by a producer that did not know about
         * trust", and that is the downgrade this exists to prevent. */
        fprintf(output, "module|id=%s|file=%s|path=%s|trust=%s\n",
            module_hex, file_hex, program->modules[index].logical_path,
            program->modules[index].trust_raw_foreign ? "raw-foreign" : "ordinary");
    }
    for (index = 0; index < program->declaration_count; index += 1) {
        Declaration *declaration = &program->declarations[indices[index]];
        Module *module = &program->modules[declaration->module_index];
        char symbol_hex[65];
        bytes_to_hex(declaration->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "decl|module=%zu|ns=%u:%s|kind=%s|name=%s|symbol=%s|visibility=%s|path=%s|header=%zu..%zu|name-span=%zu..%zu|signature=%zu..%zu",
            declaration->module_index, declaration->namespace_tag,
            namespace_name(declaration->namespace_tag), kind_name(declaration->kind),
            declaration->name, symbol_hex, visibility_name(declaration->visibility),
            module->logical_path, declaration->start, declaration->end,
            declaration->name_start, declaration->name_end,
            declaration->signature_start, declaration->signature_end);
        if (declaration->has_owner) {
            char owner_hex[65];
            bytes_to_hex(program->declarations[declaration->owner_index].symbol_id, 32u, owner_hex);
            fprintf(output, "|owner=%s|constructor-index=%zu", owner_hex, declaration->constructor_index);
        }
        fputc('\n', output);
    }
    for (index = 0; index < program->call_count; index += 1) {
        Call *call = &program->calls[index];
        Declaration *caller = &program->declarations[call->caller_index];
        Declaration *callee = &program->declarations[call->callee_index];
        char caller_hex[65];
        char callee_hex[65];
        bytes_to_hex(caller->symbol_id, 32u, caller_hex);
        bytes_to_hex(callee->symbol_id, 32u, callee_hex);
        fprintf(output, "call|caller=%s|callee=%s|name=%s|span=%zu..%zu\n",
            caller_hex, callee_hex, callee->name, call->start, call->end);
    }
    free(indices);
    if (fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S56", "cannot commit output artifact");
        return false;
    }
    return true;
}

static void destroy_program(Program *program) {
    size_t index;
    for (index = 0; index < program->module_count; index += 1) {
        free(program->modules[index].source);
        free(program->modules[index].tokens);
    }
    free(program->declarations);
    free(program->calls);
}

#ifndef KOFUN_MODULE_SYMBOLS_NO_MAIN
int main(int argc, char **argv) {
    Program program;
    size_t index;
    int status = 1;
    if (argc != 3) {
        fprintf(stderr, "usage: %s INVENTORY OUTPUT\n", argv[0]);
        return 2;
    }
    memset(&program, 0, sizeof(program));
    remove(argv[2]);
    if (!load_inventory(&program, argv[1]) || !order_and_validate_inventory(&program)) goto done;
    for (index = 0; index < program.module_count; index += 1) {
        if (!collect_module(&program, index)) goto done;
    }
    compute_identities(&program);
    if (!validate_duplicates(&program) || !resolve_bodies(&program) ||
        !emit_output(&program, argv[2])) goto done;
    status = 0;
done:
    if (program.failed) printf("%s\n", program.error);
    if (status != 0) remove(argv[2]);
    destroy_program(&program);
    return status;
}
#endif
