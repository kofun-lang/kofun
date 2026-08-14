#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
#define KOFUN_MODULE_SYMBOLS_NO_MAIN
#include "module_symbols.c"
#include "visibility_access.h"
#include "kif_v1.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#define MODULE_PATH_LIMIT 4096u
#define MODULE_PATH_COMPONENT_LIMIT 64u
#define IMPORTS_PER_MODULE_LIMIT 256u
#define IMPORT_EDGE_LIMIT 65536u
#define QUALIFIED_USE_LIMIT 65536u
#define IMPORT_GRAPH_WORK_LIMIT UINT64_C(20000000)
#define CYCLE_DIAGNOSTIC_LIMIT (2u * 1024u * 1024u)

enum {
    IMPORT_FORM_QUALIFIED = 1u,
    IMPORT_FORM_SELECTIVE = 2u
};

typedef struct {
    size_t start;
    size_t end;
} ComponentSpan;

typedef struct {
    uint8_t module_id[32];
    char declared_path[MODULE_PATH_LIMIT + 1u];
} InputPath;

typedef struct {
    char declared_path[MODULE_PATH_LIMIT + 1u];
    size_t first_import;
    size_t import_count;
    /* #1215. The class as it survives `kofun_kif_write` and `kofun_kif_read`,
     * which is the one the admission rules are allowed to consult. */
    KofunKifModuleTrust serialized_trust;
} ImportModule;

typedef struct {
    size_t importer_index;
    size_t target_index;
    uint8_t form_tag;
    bool graph_duplicate;
    bool has_alias;
    /*
     * #1215. Whether the importer wrote `trusted import`, and where. The span
     * is the `trusted` token itself, because a refusal for a decorative
     * marker has to point at the marker rather than at the path that follows
     * it.
     */
    bool trusted;
    size_t trusted_start;
    size_t trusted_end;
    /*
     * #1216. Set by the re-export layer on a binding it created for a `pub
     * import` / `pub from` form. Such a binding is not an ordinary import and
     * the import-admission rules do not decide it: re-exporting a raw-foreign
     * declaration is refused on its own terms, and telling the author to write
     * `trusted import` would be advice that leads to a second refusal.
     */
    bool re_export;
    char *path;
    char qualifier[IDENTIFIER_LIMIT + 1u];
    ComponentSpan *components;
    size_t component_count;
    size_t start;
    size_t end;
    size_t alias_start;
    size_t alias_end;
    uint8_t binding_id[32];
    uint8_t alias_binding_id[32];
} ImportBinding;

typedef struct {
    size_t caller_index;
    size_t binding_index;
    size_t target_index;
    size_t qualifier_start;
    size_t qualifier_end;
    size_t member_start;
    size_t member_end;
    size_t expression_start;
    size_t expression_end;
    size_t arity;
    KofunAccessResult access;
} QualifiedUse;

typedef struct {
    size_t from;
    size_t to;
    size_t binding_index;
} ImportEdge;

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} TextBuffer;

typedef struct {
    Program program;
    InputPath input_paths[MODULE_LIMIT];
    size_t input_path_count;
    ImportModule modules[MODULE_LIMIT];
    ImportBinding *imports;
    size_t import_count;
    size_t import_capacity;
    QualifiedUse *uses;
    size_t use_count;
    size_t use_capacity;
    char *expanded_error;
    void *extension_context;
    size_t (*find_unqualified_target)(void *context, size_t caller_index, size_t expression_start);
} ImportResolver;

static ImportResolver *comparison_resolver;

#if defined(KOFUN_TEST_DIAGNOSTIC_FAULTS)
static bool diagnostic_fault_requested(const char *name) {
    const char *requested = getenv("KOFUN_DIAGNOSTIC_FAULT");
    return requested != NULL && strcmp(requested, name) == 0;
}
#endif

static bool append_text(ImportResolver *resolver, TextBuffer *buffer, const char *format, ...) {
    Program *program = &resolver->program;
    va_list arguments;
    va_list measured_arguments;
    int measured;
    size_t required;
    if (program->failed) return false;
    va_start(arguments, format);
    va_copy(measured_arguments, arguments);
    measured = vsnprintf(NULL, 0u, format, measured_arguments);
    va_end(measured_arguments);
    if (measured < 0) {
        va_end(arguments);
        set_error(program, "E2S68", "cycle diagnostic formatting failed");
        return false;
    }
    required = (size_t)measured;
    if (required > CYCLE_DIAGNOSTIC_LIMIT - buffer->length - 1u) {
        va_end(arguments);
        set_error(program, "E2S68", "cycle diagnostic exceeds %u bytes",
            CYCLE_DIAGNOSTIC_LIMIT);
        return false;
    }
    if (buffer->length + required + 1u > buffer->capacity) {
        size_t capacity = buffer->capacity == 0u ? 256u : buffer->capacity;
        char *resized;
        while (capacity < buffer->length + required + 1u) {
            if (capacity > CYCLE_DIAGNOSTIC_LIMIT / 2u) {
                capacity = CYCLE_DIAGNOSTIC_LIMIT;
                break;
            }
            capacity *= 2u;
        }
        resized = realloc(buffer->bytes, capacity);
        if (resized == NULL) {
            va_end(arguments);
            set_error(program, "E2S68", "cycle diagnostic allocation failed");
            return false;
        }
        buffer->bytes = resized;
        buffer->capacity = capacity;
    }
    if (vsnprintf(buffer->bytes + buffer->length,
            buffer->capacity - buffer->length, format, arguments) != measured) {
        va_end(arguments);
        set_error(program, "E2S68", "cycle diagnostic formatting changed during emission");
        return false;
    }
    va_end(arguments);
    buffer->length += required;
    return true;
}

static size_t split_inventory_line_six(char *line, char *fields[6]) {
    size_t count = 1u;
    char *cursor = line;
    fields[0] = line;
    while (*cursor != '\0') {
        if (*cursor == '|') {
            if (count >= 6u) return 7u;
            *cursor = '\0';
            fields[count++] = cursor + 1u;
        }
        cursor += 1u;
    }
    return count;
}

static bool module_path_is_valid(const char *path) {
    size_t length = strlen(path);
    size_t component_length = 0u;
    size_t components = 1u;
    size_t index;
    if (length == 0u || length > MODULE_PATH_LIMIT) return false;
    for (index = 0u; index < length; index += 1u) {
        unsigned char byte = (unsigned char)path[index];
        bool ascii_alpha = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
        bool ascii_digit = byte >= '0' && byte <= '9';
        if (byte >= 0x80u) return false;
        if (byte == '.') {
            if (component_length == 0u) return false;
            component_length = 0u;
            components += 1u;
            if (components > MODULE_PATH_COMPONENT_LIMIT) return false;
            continue;
        }
        if (component_length == 0u) {
            if (!ascii_alpha && byte != '_') return false;
        } else if (!ascii_alpha && !ascii_digit && byte != '_') {
            return false;
        }
        component_length += 1u;
        if (component_length > IDENTIFIER_LIMIT) return false;
    }
    return component_length != 0u;
}

static bool load_qualified_inventory(ImportResolver *resolver, const char *path) {
    Program *program = &resolver->program;
    FILE *input = fopen(path, "rb");
    char line[8192];
    size_t line_number = 0u;
    bool have_package = false;
    uint8_t package_id[32];
    if (input == NULL) {
        set_error(program, "E2S48", "cannot open inventory");
        return false;
    }
    while (fgets(line, sizeof(line), input) != NULL) {
        char *fields[6];
        size_t count;
        size_t length;
        Module *module;
        InputPath *input_path;
        line_number += 1u;
        length = strlen(line);
        if (length == sizeof(line) - 1u && line[length - 1u] != '\n' && !feof(input)) {
            set_error(program, "E2S48", "inventory line %zu exceeds the adapter limit", line_number);
            break;
        }
        if (length > 0u && line[length - 1u] == '\n') line[--length] = '\0';
        if (length > 0u && line[length - 1u] == '\r') line[--length] = '\0';
        if (length == 0u || line[0] == '#') continue;
        if (program->module_count >= MODULE_LIMIT) {
            set_error(program, "E2S67", "inventory exceeds %u modules at line %zu", MODULE_LIMIT, line_number);
            break;
        }
        count = split_inventory_line_six(line, fields);
        if (count != 6u) {
            set_error(program, "E2S48",
                "inventory line %zu must contain PackageId|ModuleId|FileId|module-path|logical-path|source",
                line_number);
            break;
        }
        module = &program->modules[program->module_count];
        input_path = &resolver->input_paths[resolver->input_path_count];
        memset(module, 0, sizeof(*module));
        memset(input_path, 0, sizeof(*input_path));
        if (!parse_identity(fields[0], module->package_id) ||
            !parse_identity(fields[1], module->module_id) ||
            !parse_identity(fields[2], module->file_id)) {
            set_error(program, "E2S48", "inventory line %zu contains a non-canonical 32-byte identity", line_number);
            break;
        }
        if (!module_path_is_valid(fields[3])) {
            set_error(program, "E2S59", "inventory line %zu has malformed declared module path", line_number);
            break;
        }
        if (!logical_path_is_valid(fields[4])) {
            set_error(program, "E2S48", "inventory line %zu has invalid logical path", line_number);
            break;
        }
        if (strlen(fields[5]) == 0u || strlen(fields[5]) > HOST_PATH_LIMIT) {
            set_error(program, "E2S48", "inventory line %zu has invalid source operand", line_number);
            break;
        }
        memcpy(module->logical_path, fields[4], strlen(fields[4]) + 1u);
        memcpy(module->host_path, fields[5], strlen(fields[5]) + 1u);
        memcpy(input_path->module_id, module->module_id, 32u);
        memcpy(input_path->declared_path, fields[3], strlen(fields[3]) + 1u);
        if (!have_package) {
            memcpy(package_id, module->package_id, 32u);
            have_package = true;
        } else if (memcmp(package_id, module->package_id, 32u) != 0) {
            set_error(program, "E2S48", "inventory line %zu belongs to a different PackageId", line_number);
            break;
        }
        if (!read_source(program, module)) break;
        program->module_count += 1u;
        resolver->input_path_count += 1u;
    }
    if (!program->failed && ferror(input)) set_error(program, "E2S48", "inventory read failed");
    fclose(input);
    if (!program->failed && program->module_count == 0u) set_error(program, "E2S48", "inventory contains no modules");
    return !program->failed;
}

static bool attach_declared_paths(ImportResolver *resolver) {
    Program *program = &resolver->program;
    size_t module_index;
#if defined(KOFUN_TEST_DIAGNOSTIC_FAULTS)
    if (diagnostic_fault_requested("qualified-declared-path-attachment")) {
        set_error(program, "E2S68", "declared-path attachment invariant failed");
        return false;
    }
#endif
    for (module_index = 0u; module_index < program->module_count; module_index += 1u) {
        size_t input_index;
        for (input_index = 0u; input_index < resolver->input_path_count; input_index += 1u) {
            if (memcmp(program->modules[module_index].module_id,
                    resolver->input_paths[input_index].module_id, 32u) == 0) {
                memcpy(resolver->modules[module_index].declared_path,
                    resolver->input_paths[input_index].declared_path,
                    strlen(resolver->input_paths[input_index].declared_path) + 1u);
                break;
            }
        }
        if (input_index == resolver->input_path_count) {
            set_error(program, "E2S68", "declared-path attachment invariant failed");
            return false;
        }
    }
    for (module_index = 0u; module_index < program->module_count; module_index += 1u) {
        size_t other;
        for (other = module_index + 1u; other < program->module_count; other += 1u) {
            if (strcmp(resolver->modules[module_index].declared_path,
                    resolver->modules[other].declared_path) == 0) {
                set_error(program, "E2S59", "duplicate declared module path `%s`",
                    resolver->modules[module_index].declared_path);
                return false;
            }
        }
    }
    return true;
}

static bool reserve_import(ImportResolver *resolver) {
    ImportBinding *resized;
    Program *program = &resolver->program;
    if (resolver->import_count >= IMPORT_EDGE_LIMIT) {
        set_error(program, "E2S67", "import graph exceeds %u edges", IMPORT_EDGE_LIMIT);
        return false;
    }
    if (resolver->import_count < resolver->import_capacity) return true;
    {
        size_t capacity = resolver->import_capacity == 0u ? 128u : resolver->import_capacity * 2u;
        if (capacity > IMPORT_EDGE_LIMIT) capacity = IMPORT_EDGE_LIMIT;
        resized = realloc(resolver->imports, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S68", "import allocation failed");
            return false;
        }
        resolver->imports = resized;
        resolver->import_capacity = capacity;
    }
    return true;
}

static bool parse_source_path(
    ImportResolver *resolver,
    Module *module,
    size_t *cursor,
    const char *same_line_terminator,
    char **path_output,
    ComponentSpan **components_output,
    size_t *component_count_output,
    size_t *end_output
) {
    Program *program = &resolver->program;
    size_t current = *cursor;
    size_t component_count = 0u;
    size_t path_length = 0u;
    bool expect_identifier = true;
    char path[MODULE_PATH_LIMIT + 1u];
    ComponentSpan spans[MODULE_PATH_COMPONENT_LIMIT];
    while (current < module->token_count &&
        (current == *cursor || !module->tokens[current].line_break_before)) {
        Token *token = &module->tokens[current];
        if (expect_identifier) {
            size_t length;
            if (token->kind != TOKEN_IDENTIFIER || component_count >= MODULE_PATH_COMPONENT_LIMIT) break;
            length = token->end - token->start;
            if (path_length != 0u) path[path_length++] = '.';
            if (path_length + length > MODULE_PATH_LIMIT) break;
            memcpy(path + path_length, module->source + token->start, length);
            path_length += length;
            spans[component_count++] = (ComponentSpan){ token->start, token->end };
        } else if (!punctuation_equals(module, token, '.')) {
            break;
        }
        expect_identifier = !expect_identifier;
        current += 1u;
    }
    if (component_count == 0u || expect_identifier ||
        (current < module->token_count && !module->tokens[current].line_break_before &&
         (same_line_terminator == NULL ||
          !token_equals(module, &module->tokens[current], same_line_terminator)))) {
        size_t start = *cursor < module->token_count ? module->tokens[*cursor].start : module->source_length;
        size_t end = current < module->token_count ? module->tokens[current].end : module->source_length;
        set_error(program, "E2S59", "malformed module path in `%s` at bytes %zu..%zu",
            module->logical_path, start, end);
        return false;
    }
    path[path_length] = '\0';
    *path_output = malloc(path_length + 1u);
    *components_output = malloc(component_count * sizeof(**components_output));
    if (*path_output == NULL || *components_output == NULL) {
        free(*path_output);
        free(*components_output);
        *path_output = NULL;
        *components_output = NULL;
        set_error(program, "E2S68", "module-path allocation failed");
        return false;
    }
    memcpy(*path_output, path, path_length + 1u);
    memcpy(*components_output, spans, component_count * sizeof(spans[0]));
    *component_count_output = component_count;
    *end_output = module->tokens[current - 1u].end;
    *cursor = current;
    return true;
}

/* #1215. The refusals name the ModuleId, so the identity needs a text form.
 * `parse_identity` already exists for the inventory; this is its inverse and
 * the same lowercase hex the inventory is written in. */
static void format_identity(const uint8_t identity[32], char text[65]) {
    static const char digits[] = "0123456789abcdef";
    size_t index;
    for (index = 0u; index < 32u; index += 1u) {
        text[index * 2u] = digits[(identity[index] >> 4) & 0x0fu];
        text[index * 2u + 1u] = digits[identity[index] & 0x0fu];
    }
    text[64] = '\0';
}

static bool parse_and_check_header(ImportResolver *resolver, size_t module_index, size_t *cursor) {
    Program *program = &resolver->program;
    Module *module = &program->modules[module_index];
    char *path = NULL;
    ComponentSpan *components = NULL;
    size_t count = 0u;
    size_t end = 0u;
    size_t current = 1u;
    if (module->token_count == 0u || !token_equals(module, &module->tokens[0], "module")) {
        *cursor = 0u;
        return true;
    }
    if (!parse_source_path(resolver, module, &current, NULL,
            &path, &components, &count, &end)) return false;
    (void)count;
    (void)end;
    if (strcmp(path, resolver->modules[module_index].declared_path) != 0) {
        set_error(program, "E2S59", "module header `%s` does not match inventory path `%s` in `%s`",
            path, resolver->modules[module_index].declared_path, module->logical_path);
        free(path);
        free(components);
        return false;
    }
    free(path);
    free(components);
    *cursor = current;
    /*
     * #1215. The trust line is parsed by the same function the module-symbol
     * collector uses, from the translation unit this file includes, rather
     * than by a second implementation here. A contextual keyword with two
     * parsers is a keyword two readers can disagree about, and the refusals
     * for a detached or misspelled `trust` are already written once.
     *
     * Before this, the resolver did not consume the line at all: it fell
     * through to the declaration loop and a raw-foreign module was refused
     * with `unsupported top-level declaration`, pointing at the `trust` token
     * inside the *imported* file. That refusal was correct by accident and
     * named neither the crossing nor the importer.
     */
    return parse_trust_line(program, module, cursor);
}

/*
 * `trusted` is contextual in exactly one position: immediately before
 * `import`. Everywhere else it is an ordinary identifier, and this function is
 * what keeps that true — it looks without consuming, so a function named
 * `trusted` or a local called `trusted` reaches the ordinary parsers unchanged.
 */
static bool peek_trusted_import(const Module *module, size_t cursor) {
    return cursor + 1u < module->token_count &&
        token_equals(module, &module->tokens[cursor], "trusted") &&
        !module->tokens[cursor + 1u].line_break_before &&
        token_equals(module, &module->tokens[cursor + 1u], "import");
}

static bool parse_import(ImportResolver *resolver, size_t module_index, size_t *cursor) {
    Program *program = &resolver->program;
    Module *module = &program->modules[module_index];
    ImportModule *import_module = &resolver->modules[module_index];
    ImportBinding *binding;
    bool trusted = peek_trusted_import(module, *cursor);
    size_t import_token = trusted ? *cursor + 1u : *cursor;
    size_t current = import_token + 1u;
    size_t end;
    size_t qualifier_length;
    if (import_module->import_count >= IMPORTS_PER_MODULE_LIMIT) {
        set_error(program, "E2S67", "module `%s` exceeds %u imports",
            module->logical_path, IMPORTS_PER_MODULE_LIMIT);
        return false;
    }
    if (!reserve_import(resolver)) return false;
    binding = &resolver->imports[resolver->import_count];
    memset(binding, 0, sizeof(*binding));
    binding->importer_index = module_index;
    binding->form_tag = IMPORT_FORM_QUALIFIED;
    binding->trusted = trusted;
    if (trusted) {
        binding->trusted_start = module->tokens[*cursor].start;
        binding->trusted_end = module->tokens[*cursor].end;
    }
    /* The binding's own span still starts at `import`, so every existing
     * diagnostic that quotes it is byte-for-byte unchanged for an ordinary
     * import. The marker carries its own span above. */
    binding->start = module->tokens[import_token].start;
    if (!parse_source_path(resolver, module, &current, "as", &binding->path,
            &binding->components, &binding->component_count, &end)) return false;
    resolver->import_count += 1u;
    if (current < module->token_count && !module->tokens[current].line_break_before) {
        Token *alias;
        static const char *hard_keywords[] = {
            "fn", "let", "mut", "own", "read", "edit", "take", "return",
            "if", "else", "for", "in", "while", "break", "continue", "match",
            "true", "false", "null", "law", "monad", "meta", "type"
        };
        size_t keyword_index;
        if (!token_equals(module, &module->tokens[current], "as")) {
            set_error(program, "E2S59",
                "malformed module alias in `%s` at bytes %zu..%zu; hint: use `import a.b as name`",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
        current += 1u;
        if (current >= module->token_count || module->tokens[current].line_break_before) {
            set_error(program, "E2S59",
                "module alias is missing after `as` in `%s` at bytes %zu..%zu; hint: add one identifier",
                module->logical_path, module->tokens[current - 1u].start,
                module->tokens[current - 1u].end);
            return false;
        }
        alias = &module->tokens[current];
        if (alias->kind != TOKEN_IDENTIFIER ||
            token_equals(module, alias, "_")) {
            set_error(program, "E2S59",
                "module alias must be one identifier in `%s` at bytes %zu..%zu; hint: use `import a.b as name`",
                module->logical_path, alias->start, alias->end);
            return false;
        }
        for (keyword_index = 0u;
            keyword_index < sizeof(hard_keywords) / sizeof(hard_keywords[0]);
            keyword_index += 1u) {
            if (token_equals(module, alias, hard_keywords[keyword_index])) break;
        }
        if (keyword_index != sizeof(hard_keywords) / sizeof(hard_keywords[0]) ||
            token_equals(module, alias, "as")) {
            set_error(program, "E2S59",
                "module alias `%.*s` is a keyword in `%s` at bytes %zu..%zu; hint: choose a non-keyword identifier",
                (int)(alias->end - alias->start), module->source + alias->start,
                module->logical_path, alias->start, alias->end);
            return false;
        }
        qualifier_length = alias->end - alias->start;
        memcpy(binding->qualifier, module->source + alias->start, qualifier_length);
        binding->qualifier[qualifier_length] = '\0';
        binding->has_alias = true;
        binding->alias_start = alias->start;
        binding->alias_end = alias->end;
        binding->end = alias->end;
        current += 1u;
        if (current < module->token_count && !module->tokens[current].line_break_before) {
            set_error(program, "E2S59",
                "module alias must end after one identifier in `%s` at bytes %zu..%zu; hint: use `import a.b as name`",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
    } else {
        binding->end = end;
        qualifier_length = binding->components[binding->component_count - 1u].end -
            binding->components[binding->component_count - 1u].start;
        memcpy(binding->qualifier,
            module->source + binding->components[binding->component_count - 1u].start,
            qualifier_length);
    }
    binding->qualifier[qualifier_length] = '\0';
    import_module->import_count += 1u;
    *cursor = current;
    return true;
}

static bool collect_module_with_imports(ImportResolver *resolver, size_t module_index) {
    Program *program = &resolver->program;
    Module *module = &program->modules[module_index];
    size_t cursor;
    resolver->modules[module_index].first_import = resolver->import_count;
    if (!tokenize(program, module) || !parse_and_check_header(resolver, module_index, &cursor)) return false;
    while (cursor < module->token_count &&
        (token_equals(module, &module->tokens[cursor], "import") ||
         peek_trusted_import(module, cursor))) {
        if (!parse_import(resolver, module_index, &cursor)) return false;
    }
    while (cursor < module->token_count) {
        size_t declaration_start = module->tokens[cursor].start;
        Visibility visibility = VISIBILITY_IMPLICIT_PRIVATE;
        if (token_equals(module, &module->tokens[cursor], "import") ||
            peek_trusted_import(module, cursor)) {
            /* A `trusted import` after declarations is the same ordering
             * mistake as an ordinary one, and reporting it as an unsupported
             * declaration would send the reader to the wrong rule. */
            set_error(program, "E2S59", "imports must precede declarations in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start, module->tokens[cursor].end);
            return false;
        }
        if (token_equals(module, &module->tokens[cursor], "pub") ||
            token_equals(module, &module->tokens[cursor], "internal") ||
            token_equals(module, &module->tokens[cursor], "private")) {
            if (token_equals(module, &module->tokens[cursor], "pub")) visibility = VISIBILITY_PUBLIC;
            else if (token_equals(module, &module->tokens[cursor], "internal")) visibility = VISIBILITY_INTERNAL;
            else visibility = VISIBILITY_PRIVATE;
            cursor += 1u;
            if (cursor >= module->token_count) {
                set_error(program, "E2S50", "visibility modifier without declaration in `%s`", module->logical_path);
                return false;
            }
            if (token_equals(module, &module->tokens[cursor], "import") ||
                token_equals(module, &module->tokens[cursor], "from")) {
                set_error(program, "E2S59",
                    "modified import/re-export syntax is outside the ordinary qualified-import slice in `%s` at bytes %zu..%zu; hint: remove the visibility modifier; ordinary aliases remain local",
                    module->logical_path, declaration_start, module->tokens[cursor].end);
                return false;
            }
        }
        if (token_equals(module, &module->tokens[cursor], "extern")) {
            /* #1422. `extern "C" fn` — the ABI string is required and only "C"
             * is admitted, so a future ABI is a refusal here rather than
             * something that silently lowers as C. */
            if (cursor + 2u >= module->token_count ||
                module->tokens[cursor + 1u].kind != TOKEN_STRING ||
                !token_equals(module, &module->tokens[cursor + 1u], "\"C\"")) {
                set_error(program, "E2S50",
                    "`extern` requires the ABI string \"C\" in `%s` at bytes %zu..%zu",
                    module->logical_path, module->tokens[cursor].start,
                    module->tokens[cursor].end);
                return false;
            }
            if (!token_equals(module, &module->tokens[cursor + 2u], "fn")) {
                set_error(program, "E2S50",
                    "`extern \"C\"` introduces a function in `%s` at bytes %zu..%zu",
                    module->logical_path, module->tokens[cursor + 2u].start,
                    module->tokens[cursor + 2u].end);
                return false;
            }
            /* #1422. A module that declares a C entry point *is* raw-foreign,
             * and it has to say so. Inferring the class from the presence of
             * `extern "C"` would make the trust boundary a consequence of a
             * declaration rather than a statement an author is accountable for,
             * and an author who removes the last `extern "C"` would silently
             * change their module's class. Measured before this guard existed:
             * an ordinary `import` of such a module was admitted, which is the
             * whole boundary RFC-0012 exists to hold. */
            if (!module->trust_raw_foreign) {
                set_error(program, "E2S174",
                    "`extern \"C\" fn` requires `trust raw-foreign` in `%s` at bytes %zu..%zu; hint: declare the class the module is asking its importers to accept",
                    module->logical_path, module->tokens[cursor].start,
                    module->tokens[cursor + 2u].end);
                return false;
            }
            cursor += 2u;
            if (!parse_function_form(program, module_index, declaration_start,
                    visibility, true, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "fn")) {
            if (!parse_function(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "type")) {
            if (!parse_adt(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "from") ||
            token_equals(module, &module->tokens[cursor], "export")) {
            set_error(program, "E2S59",
                "selective/re-export syntax is outside the ordinary qualified-import slice in `%s` at bytes %zu..%zu; use `import a.b`",
                module->logical_path, module->tokens[cursor].start, module->tokens[cursor].end);
            return false;
        } else {
            set_error(program, "E2S50", "unsupported top-level declaration in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start, module->tokens[cursor].end);
            return false;
        }
    }
    return true;
}

static void compute_import_binding_id(
    const Program *program,
    const ImportBinding *binding,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.import-binding/v1";
    uint8_t form_tag = (uint8_t)binding->form_tag;
    const Module *importer = &program->modules[binding->importer_index];
    const Module *target = &program->modules[binding->target_index];
    size_t domain_length = strlen(domain);
    size_t qualifier_length = strlen(binding->qualifier);
    size_t payload_length = 36u + 32u + 32u + 32u + qualifier_length + 32u + 1u;
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
    hash_field(&context, UINT16_C(0x8001), importer->module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), importer->file_id, 32u);
    hash_field(&context, UINT16_C(0x8003), program->namespace_ids[2], 32u);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)binding->qualifier, qualifier_length);
    hash_field(&context, UINT16_C(0x8005), target->module_id, 32u);
    hash_field(&context, UINT16_C(0x8006), &form_tag, 1u);
    kofun_sha256_finish(&context, digest);
}

static void store_u64be(uint8_t output[8], uint64_t value) {
    output[0] = (uint8_t)(value >> 56u);
    output[1] = (uint8_t)(value >> 48u);
    output[2] = (uint8_t)(value >> 40u);
    output[3] = (uint8_t)(value >> 32u);
    output[4] = (uint8_t)(value >> 24u);
    output[5] = (uint8_t)(value >> 16u);
    output[6] = (uint8_t)(value >> 8u);
    output[7] = (uint8_t)value;
}

static void compute_alias_binding_id(
    const Program *program,
    const ImportBinding *binding,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.alias-binding/v1";
    const Module *importer = &program->modules[binding->importer_index];
    const Module *target = &program->modules[binding->target_index];
    size_t domain_length = strlen(domain);
    size_t qualifier_length = strlen(binding->qualifier);
    size_t payload_length = 36u + 32u + 32u + 8u + 8u + qualifier_length + 32u;
    uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    uint8_t u16[2];
    uint8_t u32[4];
    uint8_t alias_start[8];
    uint8_t alias_end[8];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)domain_length);
    store_u32be(u32, (uint32_t)payload_length);
    store_u64be(alias_start, (uint64_t)binding->alias_start);
    store_u64be(alias_end, (uint64_t)binding->alias_end);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, domain_length);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), importer->module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), importer->file_id, 32u);
    hash_field(&context, UINT16_C(0x8003), alias_start, sizeof(alias_start));
    hash_field(&context, UINT16_C(0x8004), alias_end, sizeof(alias_end));
    hash_field(&context, UINT16_C(0x8005),
        (const uint8_t *)binding->qualifier, qualifier_length);
    hash_field(&context, UINT16_C(0x8006), target->module_id, 32u);
    kofun_sha256_finish(&context, digest);
}

/*
 * #1215. The admission decision reads the trust class **out of the serialized
 * form**, not out of the parse.
 *
 * The criterion is that "ModuleId and serialized trust fact are
 * authoritative", and the failure mode it exists to prevent is subtle: the
 * source fact and the artifact's class agree in every fixture anyone has
 * written, so a decision taken from `module->trust_raw_foreign` passes every
 * test while proving nothing about serialization. It would diverge exactly
 * when the writer is wrong, which is the case the check is for.
 *
 * So each module's class is round-tripped through `kofun_kif_write` and
 * `kofun_kif_read` once, and `kofun_kif_trust_agrees` is asked whether the two
 * sides agree — RFC-0012's third refusal, where neither side wins.
 */
static bool serialize_module_trust(ImportResolver *resolver, const char *scratch) {
    Program *program = &resolver->program;
    size_t index;
    for (index = 0u; index < program->module_count; index += 1u) {
        KofunKifInterface written;
        KifWriteResult write_result;
        KifReadResult read_result;
        FILE *handle;
        long length;
        uint8_t *bytes;
        size_t read_bytes;
        bool source_raw = program->modules[index].trust_raw_foreign;

        memset(&written, 0, sizeof written);
        memcpy(written.package_id, program->modules[index].package_id, 32u);
        memcpy(written.module_id, program->modules[index].module_id, 32u);
        snprintf(written.edition, sizeof written.edition, "%s", "2026");
        written.module_trust = source_raw
            ? KOFUN_KIF_TRUST_RAW_FOREIGN
            : KOFUN_KIF_TRUST_ORDINARY;

        write_result = kofun_kif_write(&written, scratch);
        if (write_result.status != KOFUN_KIF_OK) {
            remove(scratch);
            /*
             * A class that cannot be serialized cannot be claimed.
             *
             * The codec refuses an identity it considers degenerate — an
             * all-zero ModuleId among them — and this resolver's own
             * scale fixtures number their synthetic modules from zero, so
             * `m.m0` legitimately has one. Such a module may still be
             * *ordinary*, because ordinary asserts nothing: there is no fact
             * for the artifact to be authoritative about. It may not be
             * raw-foreign, because that is an assertion, and an assertion
             * whose serialized form does not exist cannot be the thing the
             * admission rule consults.
             *
             * This is the one place the source fact is read for a decision,
             * and it is read only to refuse.
             */
            if (source_raw) {
                set_error(program, "E2S171",
                    "module `%s` declares `trust raw-foreign` but its trust class cannot be serialized (%s); a class that cannot be serialized cannot be claimed",
                    resolver->modules[index].declared_path,
                    write_result.message ? write_result.message : "unknown");
                return false;
            }
            resolver->modules[index].serialized_trust = KOFUN_KIF_TRUST_ORDINARY;
            continue;
        }
        handle = fopen(scratch, "rb");
        if (handle == NULL) {
            set_error(program, "E2S171",
                "module `%s` wrote no readable trust artifact",
                resolver->modules[index].declared_path);
            remove(scratch);
            return false;
        }
        if (fseek(handle, 0, SEEK_END) != 0 ||
            (length = ftell(handle)) < 0 ||
            fseek(handle, 0, SEEK_SET) != 0) {
            fclose(handle);
            remove(scratch);
            set_error(program, "E2S171",
                "module `%s` trust artifact is not seekable",
                resolver->modules[index].declared_path);
            return false;
        }
        bytes = malloc((size_t)length > 0u ? (size_t)length : 1u);
        if (bytes == NULL) {
            fclose(handle);
            remove(scratch);
            set_error(program, "E2S171", "out of memory reading a trust artifact");
            return false;
        }
        read_bytes = fread(bytes, 1u, (size_t)length, handle);
        fclose(handle);
        remove(scratch);
        read_result = kofun_kif_read(bytes, read_bytes, kofun_kif_default_limits());
        free(bytes);
        if (read_result.status != KOFUN_KIF_OK || read_result.interface == NULL) {
            set_error(program, "E2S171",
                "module `%s` trust artifact does not read back: %s",
                resolver->modules[index].declared_path,
                read_result.message ? read_result.message : "unknown");
            if (read_result.interface != NULL) kofun_kif_destroy(read_result.interface);
            return false;
        }
        if (!kofun_kif_trust_agrees(read_result.interface, source_raw)) {
            set_error(program, "E2S171",
                "module `%s` source trust class contradicts its serialized trust class; neither side wins, rebuild required",
                resolver->modules[index].declared_path);
            kofun_kif_destroy(read_result.interface);
            return false;
        }
        resolver->modules[index].serialized_trust = read_result.interface->module_trust;
        kofun_kif_destroy(read_result.interface);
    }
    return true;
}

static bool resolve_imports(ImportResolver *resolver) {
    Program *program = &resolver->program;
    size_t index;
    for (index = 0u; index < resolver->import_count; index += 1u) {
        ImportBinding *binding = &resolver->imports[index];
        ImportModule *module = &resolver->modules[binding->importer_index];
        size_t target;
        size_t prior;
        for (target = 0u; target < program->module_count; target += 1u) {
            if (strcmp(binding->path, resolver->modules[target].declared_path) == 0) break;
        }
        if (target == program->module_count) {
            set_error(program, "E2S60",
                "import `%s` has no module in the current package at `%s` bytes %zu..%zu; add it to the package module index",
                binding->path, program->modules[binding->importer_index].logical_path,
                binding->start, binding->end);
            return false;
        }
        if (target == binding->importer_index) {
            set_error(program, "E2S61",
                "module `%s` cannot import itself at `%s` bytes %zu..%zu; remove the import",
                resolver->modules[target].declared_path,
                program->modules[binding->importer_index].logical_path,
                binding->start, binding->end);
            return false;
        }
        binding->target_index = target;
        /*
         * #1215. Admission, taken from the serialized class and the resolved
         * ModuleId. Both refusals name the ModuleId, the display path, the
         * form that was attempted, and the exact remedy, because a reader who
         * is told only that a crossing is forbidden cannot tell which of the
         * two rules they hit.
         */
        if (resolver->modules[target].serialized_trust == KOFUN_KIF_TRUST_RAW_FOREIGN &&
            !binding->trusted && !binding->re_export) {
            char module_id_text[65];
            format_identity(program->modules[target].module_id, module_id_text);
            set_error(program, "E2S171",
                "ordinary import of raw-foreign module `%s` (ModuleId %s) in `%s` at bytes %zu..%zu; write `trusted import %s` to record the crossing",
                resolver->modules[target].declared_path, module_id_text,
                program->modules[binding->importer_index].logical_path,
                binding->start, binding->end,
                resolver->modules[target].declared_path);
            return false;
        }
        if (resolver->modules[target].serialized_trust != KOFUN_KIF_TRUST_RAW_FOREIGN &&
            binding->trusted) {
            char module_id_text[65];
            format_identity(program->modules[target].module_id, module_id_text);
            set_error(program, "E2S172",
                "`trusted import` of ordinary module `%s` (ModuleId %s) in `%s` at bytes %zu..%zu; remove `trusted`, the marker is only for a module whose header says `trust raw-foreign`",
                resolver->modules[target].declared_path, module_id_text,
                program->modules[binding->importer_index].logical_path,
                binding->trusted_start, binding->trusted_end);
            return false;
        }
        for (prior = module->first_import; prior < index; prior += 1u) {
            ImportBinding *other = &resolver->imports[prior];
            if (other->form_tag == IMPORT_FORM_QUALIFIED &&
                binding->form_tag == IMPORT_FORM_QUALIFIED &&
                strcmp(other->path, binding->path) == 0) {
                set_error(program, "E2S62",
                    "duplicate import `%s` in `%s` at bytes %zu..%zu; first import is bytes %zu..%zu; remove one import",
                    binding->path, program->modules[binding->importer_index].logical_path,
                    binding->start, binding->end, other->start, other->end);
                return false;
            }
            if (other->form_tag == IMPORT_FORM_QUALIFIED &&
                binding->form_tag == IMPORT_FORM_QUALIFIED &&
                strcmp(other->qualifier, binding->qualifier) == 0) {
                set_error(program, "E2S63",
                    "module qualifier `%s` collides between `%s` bytes %zu..%zu and `%s` bytes %zu..%zu in `%s`; hint: choose distinct local qualifiers",
                    binding->qualifier, other->path, other->start, other->end,
                    binding->path, binding->start, binding->end,
                    program->modules[binding->importer_index].logical_path);
                return false;
            }
        }
        compute_import_binding_id(program, binding, binding->binding_id);
        if (binding->has_alias) {
            compute_alias_binding_id(program, binding, binding->alias_binding_id);
        }
    }
    return true;
}

static int compare_graph_edges(const void *left, const void *right) {
    const ImportEdge *a = left;
    const ImportEdge *b = right;
    const Program *program = &comparison_resolver->program;
    int result;
    if (a->from != b->from) return a->from < b->from ? -1 : 1;
    result = memcmp(program->modules[a->to].module_id, program->modules[b->to].module_id, 32u);
    if (result != 0) return result;
    result = memcmp(comparison_resolver->imports[a->binding_index].binding_id,
        comparison_resolver->imports[b->binding_index].binding_id, 32u);
    if (result != 0) return result;
    return a->binding_index < b->binding_index ? -1 : a->binding_index != b->binding_index;
}

static bool cycle_is_less(const size_t *left, const size_t *right, size_t length) {
    size_t index;
    for (index = 0u; index < length; index += 1u) {
        if (left[index] != right[index]) return left[index] < right[index];
    }
    return false;
}

static void canonicalize_cycle(size_t *cycle, size_t length) {
    size_t rotated[MODULE_LIMIT];
    size_t minimum = 0u;
    size_t index;
    for (index = 1u; index < length; index += 1u) {
        if (cycle[index] < cycle[minimum]) minimum = index;
    }
    for (index = 0u; index < length; index += 1u) {
        rotated[index] = cycle[(minimum + index) % length];
    }
    memcpy(cycle, rotated, length * sizeof(cycle[0]));
}

static bool validate_import_cycles(ImportResolver *resolver) {
    Program *program = &resolver->program;
    ImportEdge *edges = NULL;
    size_t offsets[MODULE_LIMIT + 1u];
    size_t best[MODULE_LIMIT];
    size_t best_length = SIZE_MAX;
    uint64_t work = 0u;
    size_t edge_index;
    size_t graph_edge_count = 0u;
    size_t start;
    if (resolver->import_count != 0u) {
        edges = malloc(resolver->import_count * sizeof(*edges));
        if (edges == NULL) {
            set_error(program, "E2S68", "import-graph allocation failed");
            return false;
        }
    }
    for (edge_index = 0u; edge_index < resolver->import_count; edge_index += 1u) {
        if (resolver->imports[edge_index].graph_duplicate) continue;
        edges[graph_edge_count++] = (ImportEdge){
            resolver->imports[edge_index].importer_index,
            resolver->imports[edge_index].target_index,
            edge_index
        };
    }
    comparison_resolver = resolver;
    if (graph_edge_count > 1u) {
        qsort(edges, graph_edge_count, sizeof(*edges), compare_graph_edges);
    }
    edge_index = 0u;
    for (start = 0u; start < program->module_count; start += 1u) {
        offsets[start] = edge_index;
        while (edge_index < graph_edge_count && edges[edge_index].from == start) edge_index += 1u;
    }
    offsets[program->module_count] = edge_index;
    for (start = 0u; start < program->module_count; start += 1u) {
        int distance[MODULE_LIMIT];
        size_t predecessor[MODULE_LIMIT];
        size_t queue[MODULE_LIMIT];
        size_t head = 0u;
        size_t tail = 0u;
        size_t index;
        for (index = 0u; index < program->module_count; index += 1u) {
            distance[index] = -1;
            predecessor[index] = SIZE_MAX;
        }
        distance[start] = 0;
        queue[tail++] = start;
        while (head < tail) {
            size_t from = queue[head++];
            for (index = offsets[from]; index < offsets[from + 1u]; index += 1u) {
                size_t to = edges[index].to;
                size_t candidate_length;
                size_t candidate[MODULE_LIMIT];
                size_t reversed[MODULE_LIMIT];
                size_t reversed_count = 0u;
                size_t node;
                work += 1u;
                if (work > IMPORT_GRAPH_WORK_LIMIT) {
                    free(edges);
                    set_error(program, "E2S67", "import-graph traversal exceeds %llu operations",
                        (unsigned long long)IMPORT_GRAPH_WORK_LIMIT);
                    return false;
                }
                if (to != start) {
                    if (distance[to] < 0) {
                        distance[to] = distance[from] + 1;
                        predecessor[to] = from;
                        queue[tail++] = to;
                    }
                    continue;
                }
                candidate_length = (size_t)distance[from] + 1u;
                if (candidate_length < 2u || candidate_length > best_length) continue;
                node = from;
                while (node != start && reversed_count < MODULE_LIMIT) {
                    reversed[reversed_count++] = node;
                    node = predecessor[node];
                }
                if (node != start || reversed_count + 1u != candidate_length) {
                    free(edges);
                    set_error(program, "E2S68", "cycle reconstruction invariant failed");
                    return false;
                }
                candidate[0] = start;
                for (node = 0u; node < reversed_count; node += 1u) {
                    candidate[node + 1u] = reversed[reversed_count - node - 1u];
                }
                canonicalize_cycle(candidate, candidate_length);
                if (candidate_length < best_length || cycle_is_less(candidate, best, candidate_length)) {
                    memcpy(best, candidate, candidate_length * sizeof(best[0]));
                    best_length = candidate_length;
                }
            }
        }
    }
    free(edges);
    if (best_length != SIZE_MAX) {
        TextBuffer diagnostic = {0};
        size_t index;
        if (!append_text(resolver, &diagnostic,
                "error[E2S64]: canonical import cycle: ")) {
            free(diagnostic.bytes);
            return false;
        }
        for (index = 0u; index < best_length; index += 1u) {
            size_t from = best[index];
            size_t to = best[(index + 1u) % best_length];
            size_t binding_index;
            ImportBinding *binding = NULL;
            for (binding_index = 0u; binding_index < resolver->import_count; binding_index += 1u) {
                if (resolver->imports[binding_index].importer_index == from &&
                    resolver->imports[binding_index].target_index == to &&
                    !resolver->imports[binding_index].graph_duplicate) {
                    binding = &resolver->imports[binding_index];
                    break;
                }
            }
            if (binding == NULL) {
                set_error(program, "E2S68", "cycle-edge reconstruction invariant failed");
                free(diagnostic.bytes);
                return false;
            }
            if (!append_text(resolver, &diagnostic, "%s --%s:%zu..%zu--> ",
                    resolver->modules[from].declared_path,
                    program->modules[from].logical_path,
                    binding->start, binding->end)) {
                free(diagnostic.bytes);
                return false;
            }
        }
        if (!append_text(resolver, &diagnostic,
                "%s; hint: remove one import edge from this cycle",
                resolver->modules[best[0]].declared_path)) {
            free(diagnostic.bytes);
            return false;
        }
        resolver->expanded_error = diagnostic.bytes;
        program->failed = true;
        return false;
    }
    return true;
}

static bool reserve_use(ImportResolver *resolver) {
    QualifiedUse *resized;
    if (resolver->use_count >= QUALIFIED_USE_LIMIT) {
        set_error(&resolver->program, "E2S67", "qualified uses exceed %u", QUALIFIED_USE_LIMIT);
        return false;
    }
    if (resolver->use_count < resolver->use_capacity) return true;
    {
        size_t capacity = resolver->use_capacity == 0u ? 128u : resolver->use_capacity * 2u;
        if (capacity > QUALIFIED_USE_LIMIT) capacity = QUALIFIED_USE_LIMIT;
        resized = realloc(resolver->uses, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->program, "E2S68", "qualified-use allocation failed");
            return false;
        }
        resolver->uses = resized;
        resolver->use_capacity = capacity;
    }
    return true;
}

static size_t function_arity(const Program *program, const Declaration *declaration) {
    const Module *module = &program->modules[declaration->module_index];
    size_t cursor;
    for (cursor = 0u; cursor < module->token_count; cursor += 1u) {
        if (module->tokens[cursor].start == declaration->name_start) {
            size_t open = cursor + 1u;
            size_t close;
            if (open >= module->token_count || !punctuation_equals(module, &module->tokens[open], '(')) return SIZE_MAX;
            for (close = open + 1u; close < module->token_count; close += 1u) {
                if (punctuation_equals(module, &module->tokens[close], ')')) break;
            }
            if (close == module->token_count) return SIZE_MAX;
            if (close == open + 1u) return 0u;
            return (close - open) / 4u;
        }
    }
    return SIZE_MAX;
}

static bool validate_int_function_signature(Program *program, const Declaration *declaration) {
    const Module *module = &program->modules[declaration->module_index];
    size_t name = SIZE_MAX;
    size_t open;
    size_t close;
    size_t cursor;
    for (cursor = 0u; cursor < module->token_count; cursor += 1u) {
        if (module->tokens[cursor].start == declaration->name_start &&
            module->tokens[cursor].end == declaration->name_end) {
            name = cursor;
            break;
        }
    }
    if (name == SIZE_MAX || name + 1u >= module->token_count) {
        set_error(program, "E2S68", "function signature token invariant failed");
        return false;
    }
    open = name + 1u;
    for (close = open + 1u; close < module->token_count; close += 1u) {
        if (punctuation_equals(module, &module->tokens[close], ')')) break;
    }
    if (close >= module->token_count || close + 2u >= module->token_count) {
        set_error(program, "E2S68", "function signature delimiter invariant failed");
        return false;
    }
    cursor = open + 1u;
    while (cursor < close) {
        Token *type = &module->tokens[cursor + 2u];
        if (!token_equals(module, type, "Int")) {
            set_error(program, "E2S65",
                "function `%s` in `%s` has unsupported parameter type `%.*s` at bytes %zu..%zu; hint: use `Int` parameters and return type in the qualified-call slice",
                declaration->name, module->logical_path,
                (int)(type->end - type->start), module->source + type->start,
                type->start, type->end);
            return false;
        }
        cursor += 3u;
        if (cursor < close) cursor += 1u;
    }
    if (!token_equals(module, &module->tokens[close + 2u], "Int")) {
        Token *type = &module->tokens[close + 2u];
        set_error(program, "E2S65",
            "function `%s` in `%s` has unsupported return type `%.*s` at bytes %zu..%zu; hint: use `Int` parameters and return type in the qualified-call slice",
            declaration->name, module->logical_path,
            (int)(type->end - type->start), module->source + type->start,
            type->start, type->end);
        return false;
    }
    return true;
}

static bool call_arity(
    Program *program,
    Module *module,
    size_t open,
    size_t limit,
    size_t *arity,
    size_t *close
) {
    size_t cursor;
    size_t depth = 0u;
    size_t commas = 0u;
    for (cursor = open; cursor < limit; cursor += 1u) {
        if (punctuation_equals(module, &module->tokens[cursor], '(')) depth += 1u;
        else if (punctuation_equals(module, &module->tokens[cursor], ')')) {
            if (depth == 0u) break;
            depth -= 1u;
            if (depth == 0u) {
                if (cursor > open + 1u &&
                    punctuation_equals(module, &module->tokens[cursor - 1u], ',')) {
                    set_error(program, "E2S65",
                        "qualified call in `%s` has a trailing argument comma at bytes %zu..%zu",
                        module->logical_path, module->tokens[cursor - 1u].start,
                        module->tokens[cursor - 1u].end);
                    return false;
                }
                *close = cursor;
                *arity = cursor == open + 1u ? 0u : commas + 1u;
                return true;
            }
        } else if (depth == 1u && punctuation_equals(module, &module->tokens[cursor], ',')) {
            if (cursor == open + 1u ||
                punctuation_equals(module, &module->tokens[cursor - 1u], ',')) {
                set_error(program, "E2S65",
                    "qualified call in `%s` has an empty argument at bytes %zu..%zu",
                    module->logical_path, module->tokens[cursor].start,
                    module->tokens[cursor].end);
                return false;
            }
            commas += 1u;
        }
    }
    set_error(program, "E2S65", "unclosed qualified call in `%s` at bytes %zu..%zu",
        module->logical_path, module->tokens[open].start, module->tokens[open].end);
    return false;
}

static bool token_matches_text(const Module *module, const Token *token, const char *text) {
    size_t length = token->end - token->start;
    return strlen(text) == length && memcmp(module->source + token->start, text, length) == 0;
}

static KofunIdentity access_identity(KofunIdentityKind kind, const uint8_t bytes[32]) {
    KofunIdentity identity;
    memset(&identity, 0, sizeof(identity));
    identity.schema = KOFUN_IDENTITY_SCHEMA_V1;
    identity.kind = kind;
    memcpy(identity.bytes, bytes, 32u);
    return identity;
}

static KofunVisibility access_visibility(Visibility visibility) {
    switch (visibility) {
        case VISIBILITY_IMPLICIT_PRIVATE:
        case VISIBILITY_PRIVATE: return KOFUN_VISIBILITY_PRIVATE;
        case VISIBILITY_INTERNAL: return KOFUN_VISIBILITY_INTERNAL;
        case VISIBILITY_PUBLIC: return KOFUN_VISIBILITY_PUBLIC;
    }
    return KOFUN_VISIBILITY_UNKNOWN;
}

static KofunAccessResult qualified_access(
    const Program *program,
    const Declaration *caller,
    const Declaration *target,
    size_t use_start,
    size_t use_end
) {
    const Module *caller_module = &program->modules[caller->module_index];
    const Module *target_module = &program->modules[target->module_index];
    KofunAccessContext context;
    KofunDeclarationAccess declaration;
    memset(&context, 0, sizeof(context));
    memset(&declaration, 0, sizeof(declaration));
    context.caller_package = access_identity(KOFUN_ID_PACKAGE, caller_module->package_id);
    context.caller_module = access_identity(KOFUN_ID_MODULE, caller_module->module_id);
    context.caller_file = access_identity(KOFUN_ID_FILE, caller_module->file_id);
    context.use_span = (KofunSpan){ (uint32_t)use_start, (uint32_t)use_end };
    declaration.declared_visibility = access_visibility(target->visibility);
    declaration.defining_package = access_identity(KOFUN_ID_PACKAGE, target_module->package_id);
    declaration.defining_module = access_identity(KOFUN_ID_MODULE, target_module->module_id);
    declaration.defining_file = access_identity(KOFUN_ID_FILE, target_module->file_id);
    declaration.declaration_span = (KofunSpan){ (uint32_t)target->start, (uint32_t)target->end };
    return kofun_decide_access(&context, &declaration);
}

static bool imported_module_has_function(
    const ImportResolver *resolver,
    const Declaration *caller,
    const ImportModule *imports,
    const Module *use_module,
    const Token *name
) {
    const Program *program = &resolver->program;
    size_t import_index;
    for (import_index = imports->first_import;
        import_index < imports->first_import + imports->import_count; import_index += 1u) {
        size_t declaration_index;
        for (declaration_index = 0u; declaration_index < program->declaration_count; declaration_index += 1u) {
            const Declaration *target = &program->declarations[declaration_index];
            if (target->module_index == resolver->imports[import_index].target_index &&
                target->kind == DECLARATION_FUNCTION &&
                token_matches_text(use_module, name, target->name)) {
                KofunAccessResult access = qualified_access(program, caller, target,
                    name->start, name->end);
                if (access.kind == KOFUN_ACCESS_ALLOWED && access.usable_reference) return true;
            }
        }
    }
    return false;
}

static bool resolve_qualified_bodies(ImportResolver *resolver) {
    Program *program = &resolver->program;
    size_t caller_index;
    for (caller_index = 0u; caller_index < program->declaration_count; caller_index += 1u) {
        Declaration *caller = &program->declarations[caller_index];
        Module *module;
        ImportModule *imports;
        size_t cursor;
        if (caller->kind != DECLARATION_FUNCTION) continue;
        module = &program->modules[caller->module_index];
        imports = &resolver->modules[caller->module_index];
        for (cursor = caller->body_token_start; cursor < caller->body_token_end; cursor += 1u) {
            Token *qualifier = &module->tokens[cursor];
            size_t binding_index = SIZE_MAX;
            size_t target_index = SIZE_MAX;
            size_t import_index;
            size_t declaration_index;
            size_t arity;
            size_t close;
            size_t expected;
            KofunAccessResult access;
            if (qualifier->kind != TOKEN_IDENTIFIER || cursor + 3u >= caller->body_token_end ||
                !punctuation_equals(module, &module->tokens[cursor + 1u], '.') ||
                module->tokens[cursor + 2u].kind != TOKEN_IDENTIFIER ||
                !punctuation_equals(module, &module->tokens[cursor + 3u], '(')) continue;
            for (import_index = imports->first_import;
                import_index < imports->first_import + imports->import_count; import_index += 1u) {
                if (token_matches_text(module, qualifier, resolver->imports[import_index].qualifier)) {
                    binding_index = import_index;
                    break;
                }
            }
            if (binding_index == SIZE_MAX) {
                set_error(program, "E2S65", "unknown import qualifier `%.*s` in `%s` at bytes %zu..%zu",
                    (int)(qualifier->end - qualifier->start), module->source + qualifier->start,
                    module->logical_path, qualifier->start, qualifier->end);
                return false;
            }
            for (declaration_index = 0u; declaration_index < program->declaration_count; declaration_index += 1u) {
                Declaration *target = &program->declarations[declaration_index];
                if (target->module_index == resolver->imports[binding_index].target_index &&
                    target->kind == DECLARATION_FUNCTION &&
                    token_matches_text(module, &module->tokens[cursor + 2u], target->name)) {
                    target_index = declaration_index;
                    break;
                }
            }
            if (target_index == SIZE_MAX) {
                set_error(program, "E2S65", "module `%s` has no function `%.*s` used in `%s` at bytes %zu..%zu",
                    resolver->imports[binding_index].path,
                    (int)(module->tokens[cursor + 2u].end - module->tokens[cursor + 2u].start),
                    module->source + module->tokens[cursor + 2u].start,
                    module->logical_path, module->tokens[cursor + 2u].start,
                    module->tokens[cursor + 2u].end);
                return false;
            }
            if (!call_arity(program, module, cursor + 3u, caller->body_token_end, &arity, &close)) return false;
            access = qualified_access(program, caller, &program->declarations[target_index],
                qualifier->start, module->tokens[close].end);
            if (access.kind != KOFUN_ACCESS_ALLOWED || !access.usable_reference) {
                set_error(program, "E2S66",
                    "qualified use in `%s` at bytes %zu..%zu is inaccessible: %s; hint: expose an internal or public target, or keep the call in the defining file",
                    module->logical_path, qualifier->start, module->tokens[close].end,
                    kofun_access_reason_name(access.reason));
                return false;
            }
            if (!validate_int_function_signature(program,
                    &program->declarations[target_index])) return false;
            expected = function_arity(program, &program->declarations[target_index]);
            if (expected == SIZE_MAX) {
                set_error(program, "E2S68", "function signature invariant failed");
                return false;
            }
            if (arity != expected) {
                set_error(program, "E2S65", "qualified call `%s.%s` expects %zu arguments but got %zu in `%s`",
                    resolver->imports[binding_index].qualifier,
                    program->declarations[target_index].name, expected, arity, module->logical_path);
                return false;
            }
            if (!reserve_use(resolver)) return false;
            resolver->uses[resolver->use_count++] = (QualifiedUse){
                .caller_index = caller_index,
                .binding_index = binding_index,
                .target_index = target_index,
                .qualifier_start = qualifier->start,
                .qualifier_end = qualifier->end,
                .member_start = module->tokens[cursor + 2u].start,
                .member_end = module->tokens[cursor + 2u].end,
                .expression_start = qualifier->start,
                .expression_end = module->tokens[close].end,
                .arity = arity,
                .access = access
            };
            continue;
        }
        for (cursor = caller->body_token_start; cursor < caller->body_token_end; cursor += 1u) {
            Token *name = &module->tokens[cursor];
            size_t declaration_index;
            bool local = false;
            if (name->kind != TOKEN_IDENTIFIER || cursor + 1u >= caller->body_token_end ||
                !punctuation_equals(module, &module->tokens[cursor + 1u], '(') ||
                keyword_call(module, name) ||
                (cursor > caller->body_token_start &&
                    punctuation_equals(module, &module->tokens[cursor - 1u], '.'))) continue;
            for (declaration_index = 0u; declaration_index < program->declaration_count; declaration_index += 1u) {
                Declaration *target = &program->declarations[declaration_index];
                if (target->module_index == caller->module_index && target->kind == DECLARATION_FUNCTION &&
                    token_matches_text(module, name, target->name)) {
                    local = true;
                    break;
                }
            }
            if (local) continue;
            if (imported_module_has_function(resolver, caller, imports, module, name)) {
                set_error(program, "E2S65",
                    "imported function `%.*s` requires its module qualifier in `%s` at bytes %zu..%zu",
                    (int)(name->end - name->start), module->source + name->start,
                    module->logical_path, name->start, name->end);
            } else {
                set_error(program, "E2S53", "unknown same-module value `%.*s` in `%s` at bytes %zu..%zu",
                    (int)(name->end - name->start), module->source + name->start,
                    module->logical_path, name->start, name->end);
            }
            return false;
        }
    }
    return true;
}

static int compare_import_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    int result = memcmp(comparison_resolver->imports[a].binding_id,
        comparison_resolver->imports[b].binding_id, 32u);
    if (result != 0) return result;
    return a < b ? -1 : a != b;
}

static int compare_use_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    const QualifiedUse *use_a = &comparison_resolver->uses[a];
    const QualifiedUse *use_b = &comparison_resolver->uses[b];
    int result = memcmp(comparison_resolver->program.declarations[use_a->caller_index].symbol_id,
        comparison_resolver->program.declarations[use_b->caller_index].symbol_id, 32u);
    if (result != 0) return result;
    if (use_a->expression_start != use_b->expression_start) return use_a->expression_start < use_b->expression_start ? -1 : 1;
    return a < b ? -1 : a != b;
}

static int compare_target_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    const Declaration *target_a = &comparison_resolver->program.declarations[a];
    const Declaration *target_b = &comparison_resolver->program.declarations[b];
    int result = memcmp(target_a->namespace_id, target_b->namespace_id, 32u);
    if (result != 0) return result;
    result = memcmp(target_a->symbol_id, target_b->symbol_id, 32u);
    if (result != 0) return result;
    return a < b ? -1 : a != b;
}

static bool emit_qualified_hir(ImportResolver *resolver, const char *path) {
    Program *program = &resolver->program;
    size_t *import_order = NULL;
    size_t *use_order = NULL;
    size_t *target_order = NULL;
    size_t target_count = 0u;
    FILE *output;
    size_t index;
    char package_hex[65];
    if (resolver->import_count != 0u) import_order = malloc(resolver->import_count * sizeof(*import_order));
    if (resolver->use_count != 0u) use_order = malloc(resolver->use_count * sizeof(*use_order));
    if (resolver->use_count != 0u) target_order = malloc(resolver->use_count * sizeof(*target_order));
    if ((resolver->import_count != 0u && import_order == NULL) ||
        (resolver->use_count != 0u && (use_order == NULL || target_order == NULL))) {
        free(import_order);
        free(use_order);
        free(target_order);
        set_error(program, "E2S68", "HIR ordering allocation failed");
        return false;
    }
    for (index = 0u; index < resolver->import_count; index += 1u) import_order[index] = index;
    for (index = 0u; index < resolver->use_count; index += 1u) {
        size_t prior;
        use_order[index] = index;
        for (prior = 0u; prior < target_count; prior += 1u) {
            if (target_order[prior] == resolver->uses[index].target_index) break;
        }
        if (prior == target_count) target_order[target_count++] = resolver->uses[index].target_index;
    }
    comparison_resolver = resolver;
    if (resolver->import_count > 1u) {
        qsort(import_order, resolver->import_count, sizeof(*import_order), compare_import_output);
    }
    if (resolver->use_count > 1u) {
        qsort(use_order, resolver->use_count, sizeof(*use_order), compare_use_output);
    }
    if (target_count > 1u) qsort(target_order, target_count, sizeof(*target_order), compare_target_output);
    output = fopen(path, "wb");
    if (output == NULL) {
        free(import_order);
        free(use_order);
        free(target_order);
        set_error(program, "E2S68", "cannot create qualified-import HIR");
        return false;
    }
    bytes_to_hex(program->modules[0].package_id, 32u, package_hex);
    fprintf(output, "kofun-imports-qualified/v1\npackage|id=%s\n", package_hex);
    for (index = 0u; index < program->module_count; index += 1u) {
        char module_hex[65];
        char file_hex[65];
        bytes_to_hex(program->modules[index].module_id, 32u, module_hex);
        bytes_to_hex(program->modules[index].file_id, 32u, file_hex);
        fprintf(output, "module|id=%s|file=%s|declared=%s|path=%s\n",
            module_hex, file_hex, resolver->modules[index].declared_path,
            program->modules[index].logical_path);
    }
    for (index = 0u; index < resolver->import_count; index += 1u) {
        ImportBinding *binding = &resolver->imports[import_order[index]];
        char binding_hex[65];
        char importer_hex[65];
        char file_hex[65];
        char namespace_hex[65];
        char target_hex[65];
        size_t component;
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[binding->importer_index].module_id, 32u, importer_hex);
        bytes_to_hex(program->modules[binding->importer_index].file_id, 32u, file_hex);
        bytes_to_hex(program->namespace_ids[2], 32u, namespace_hex);
        bytes_to_hex(program->modules[binding->target_index].module_id, 32u, target_hex);
        fprintf(output,
            "import|binding=%s|importer=%s|file=%s|namespace=%s|local=%s|target=%s|form=qualified-module-v1|span=%zu..%zu|components=",
            binding_hex, importer_hex, file_hex, namespace_hex, binding->qualifier,
            target_hex, binding->start, binding->end);
        for (component = 0u; component < binding->component_count; component += 1u) {
            if (component != 0u) fputc(',', output);
            fprintf(output, "%zu..%zu", binding->components[component].start,
                binding->components[component].end);
        }
        if (binding->has_alias) {
            char alias_binding_hex[65];
            bytes_to_hex(binding->alias_binding_id, 32u, alias_binding_hex);
            fprintf(output, "|alias-binding=%s|alias-span=%zu..%zu|reexport=false",
                alias_binding_hex, binding->alias_start, binding->alias_end);
        }
        fputc('\n', output);
    }
    for (index = 0u; index < target_count; index += 1u) {
        Declaration *target = &program->declarations[target_order[index]];
        char module_hex[65];
        char namespace_hex[65];
        char symbol_hex[65];
        size_t arity = function_arity(program, target);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, module_hex);
        bytes_to_hex(target->namespace_id, 32u, namespace_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        /* #1422. Whether a symbol is defined here or resolved by the linker is
         * a property of the program, so the artifact states it rather than
         * leaving every consumer to infer it from the emitted C. The driver
         * reads this field to refuse an unlinked build by name instead of
         * letting `ld` report a symbol the author never wrote. */
        fprintf(output,
            "target|module=%s|namespace=%s|symbol=%s|kind=function|name=%s|visibility=%s|linkage=%s|signature=fn(%zu:Int)->Int\n",
            module_hex, namespace_hex, symbol_hex, target->name,
            visibility_name(target->visibility),
            target->is_external ? "external" : "defined", arity);
    }
    for (index = 0u; index < resolver->use_count; index += 1u) {
        QualifiedUse *use = &resolver->uses[use_order[index]];
        Declaration *caller = &program->declarations[use->caller_index];
        Declaration *target = &program->declarations[use->target_index];
        char caller_hex[65];
        char binding_hex[65];
        char module_hex[65];
        char symbol_hex[65];
        char namespace_hex[65];
        bytes_to_hex(caller->symbol_id, 32u, caller_hex);
        bytes_to_hex(resolver->imports[use->binding_index].binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        bytes_to_hex(target->namespace_id, 32u, namespace_hex);
        fprintf(output,
            "qualified-call|caller=%s|binding=%s",
            caller_hex, binding_hex);
        if (resolver->imports[use->binding_index].has_alias) {
            char alias_binding_hex[65];
            bytes_to_hex(resolver->imports[use->binding_index].alias_binding_id,
                32u, alias_binding_hex);
            fprintf(output, "|alias-binding=%s", alias_binding_hex);
        }
        fprintf(output,
            "|target-module=%s|target-symbol=%s|target-namespace=%s|name=%s|qualifier-span=%zu..%zu|member-span=%zu..%zu|expression-span=%zu..%zu|access=%s|reason=%s|proof=%u|signature=fn(%zu:Int)->Int\n",
            module_hex, symbol_hex, namespace_hex, target->name,
            use->qualifier_start, use->qualifier_end, use->member_start, use->member_end,
            use->expression_start, use->expression_end,
            kofun_access_kind_name(use->access.kind), kofun_access_reason_name(use->access.reason),
            use->access.proof, use->arity);
    }
    free(import_order);
    free(use_order);
    free(target_order);
    if (fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S68", "cannot commit qualified-import HIR");
        return false;
    }
    return true;
}

static void emit_c_symbol(FILE *output, const Declaration *declaration) {
    char symbol_hex[65];
    /* #1422. An external function is named by the linker, not by us. Emitting
     * the hashed symbol would produce a prototype nothing defines and a call
     * nothing resolves, so the source name is the identity here. */
    if (declaration->is_external) {
        fputs(declaration->name, output);
        return;
    }
    bytes_to_hex(declaration->symbol_id, 32u, symbol_hex);
    fprintf(output, "kofun_s_%s", symbol_hex);
}

static size_t function_name_token_index(const Program *program, const Declaration *declaration) {
    const Module *module = &program->modules[declaration->module_index];
    size_t index;
    for (index = 0u; index < module->token_count; index += 1u) {
        if (module->tokens[index].start == declaration->name_start &&
            module->tokens[index].end == declaration->name_end) return index;
    }
    return SIZE_MAX;
}

static size_t parameter_index(
    const Program *program,
    const Declaration *function,
    const Module *use_module,
    const Token *name
) {
    const Module *module = &program->modules[function->module_index];
    size_t function_name = function_name_token_index(program, function);
    size_t cursor;
    size_t index = 0u;
    if (function_name == SIZE_MAX || function_name + 1u >= module->token_count) return SIZE_MAX;
    cursor = function_name + 2u;
    while (cursor < module->token_count && !punctuation_equals(module, &module->tokens[cursor], ')')) {
        if (name->end - name->start == module->tokens[cursor].end - module->tokens[cursor].start &&
            memcmp(use_module->source + name->start,
                module->source + module->tokens[cursor].start,
                name->end - name->start) == 0) {
            return index;
        }
        cursor += 3u;
        index += 1u;
        if (cursor < module->token_count && punctuation_equals(module, &module->tokens[cursor], ',')) cursor += 1u;
    }
    return SIZE_MAX;
}

static size_t find_local_function(
    const Program *program,
    size_t module_index,
    const Module *use_module,
    const Token *name
) {
    size_t index;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        const Declaration *declaration = &program->declarations[index];
        if (declaration->module_index == module_index && declaration->kind == DECLARATION_FUNCTION &&
            token_matches_text(use_module, name, declaration->name)) return index;
    }
    return SIZE_MAX;
}

static size_t find_qualified_use(
    const ImportResolver *resolver,
    size_t caller_index,
    size_t expression_start
) {
    size_t index;
    for (index = 0u; index < resolver->use_count; index += 1u) {
        if (resolver->uses[index].caller_index == caller_index &&
            resolver->uses[index].expression_start == expression_start) return index;
    }
    return SIZE_MAX;
}

static bool emit_c_expression(
    ImportResolver *resolver,
    FILE *output,
    size_t caller_index,
    size_t *cursor,
    size_t limit
);

static bool emit_c_arguments(
    ImportResolver *resolver,
    FILE *output,
    size_t caller_index,
    size_t *cursor,
    size_t limit
) {
    Module *module = &resolver->program.modules[
        resolver->program.declarations[caller_index].module_index];
    if (*cursor >= limit || !punctuation_equals(module, &module->tokens[*cursor], '(')) {
        set_error(&resolver->program, "E2S68", "reference-lowering call invariant failed");
        return false;
    }
    *cursor += 1u;
    fputc('(', output);
    if (*cursor < limit && punctuation_equals(module, &module->tokens[*cursor], ')')) {
        *cursor += 1u;
        fputc(')', output);
        return true;
    }
    while (*cursor < limit) {
        if (!emit_c_expression(resolver, output, caller_index, cursor, limit)) return false;
        if (*cursor < limit && punctuation_equals(module, &module->tokens[*cursor], ',')) {
            *cursor += 1u;
            fputs(", ", output);
            continue;
        }
        if (*cursor < limit && punctuation_equals(module, &module->tokens[*cursor], ')')) {
            *cursor += 1u;
            fputc(')', output);
            return true;
        }
        break;
    }
    set_error(&resolver->program, "E2S65", "reference lowering requires well-formed call arguments in `%s`",
        module->logical_path);
    return false;
}

static bool emit_c_expression(
    ImportResolver *resolver,
    FILE *output,
    size_t caller_index,
    size_t *cursor,
    size_t limit
) {
    Program *program = &resolver->program;
    Declaration *caller = &program->declarations[caller_index];
    Module *module = &program->modules[caller->module_index];
    Token *token;
    if (*cursor >= limit) {
        set_error(program, "E2S65", "reference lowering requires a return expression in `%s`",
            module->logical_path);
        return false;
    }
    token = &module->tokens[*cursor];
    if (token->kind == TOKEN_INTEGER) {
        fwrite(module->source + token->start, 1u, token->end - token->start, output);
        *cursor += 1u;
        return true;
    }
    if (token->kind == TOKEN_IDENTIFIER && *cursor + 3u < limit &&
        punctuation_equals(module, &module->tokens[*cursor + 1u], '.') &&
        module->tokens[*cursor + 2u].kind == TOKEN_IDENTIFIER &&
        punctuation_equals(module, &module->tokens[*cursor + 3u], '(')) {
        size_t use_index = find_qualified_use(resolver, caller_index, token->start);
        if (use_index == SIZE_MAX) {
            set_error(program, "E2S68", "qualified HIR lowering invariant failed");
            return false;
        }
        emit_c_symbol(output, &program->declarations[resolver->uses[use_index].target_index]);
        *cursor += 3u;
        return emit_c_arguments(resolver, output, caller_index, cursor, limit);
    }
    if (token->kind == TOKEN_IDENTIFIER && *cursor + 1u < limit &&
        punctuation_equals(module, &module->tokens[*cursor + 1u], '(')) {
        size_t target = find_local_function(program, caller->module_index, module, token);
        if (target == SIZE_MAX && resolver->find_unqualified_target != NULL) {
            target = resolver->find_unqualified_target(
                resolver->extension_context, caller_index, token->start);
        }
        if (target == SIZE_MAX) {
            set_error(program, "E2S68", "local call lowering invariant failed");
            return false;
        }
        emit_c_symbol(output, &program->declarations[target]);
        *cursor += 1u;
        return emit_c_arguments(resolver, output, caller_index, cursor, limit);
    }
    if (token->kind == TOKEN_IDENTIFIER) {
        size_t parameter = parameter_index(program, caller, module, token);
        if (parameter != SIZE_MAX) {
            fprintf(output, "k_p%zu", parameter);
            *cursor += 1u;
            return true;
        }
    }
    set_error(program, "E2S65",
        "reference lowering supports Int literals, parameters, and resolved calls in `%s` at bytes %zu..%zu",
        module->logical_path, token->start, token->end);
    return false;
}

static int compare_function_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    int result = memcmp(comparison_resolver->program.declarations[a].symbol_id,
        comparison_resolver->program.declarations[b].symbol_id, 32u);
    if (result != 0) return result;
    return a < b ? -1 : a != b;
}

static bool emit_c_function_signature(
    ImportResolver *resolver,
    FILE *output,
    size_t declaration_index
) {
    Declaration *declaration = &resolver->program.declarations[declaration_index];
    size_t arity = function_arity(&resolver->program, declaration);
    size_t parameter;
    if (arity == SIZE_MAX) {
        set_error(&resolver->program, "E2S68", "reference-lowering signature invariant failed");
        return false;
    }
    fputs(declaration->is_external ? "int64_t " : "static int64_t ", output);
    emit_c_symbol(output, declaration);
    fputc('(', output);
    if (arity == 0u) fputs("void", output);
    for (parameter = 0u; parameter < arity; parameter += 1u) {
        if (parameter != 0u) fputs(", ", output);
        fprintf(output, "int64_t k_p%zu", parameter);
    }
    fputc(')', output);
    return true;
}

static bool emit_reference_c(ImportResolver *resolver, const char *path) {
    Program *program = &resolver->program;
    size_t *functions = NULL;
    size_t function_count = 0u;
    size_t index;
    size_t entry = SIZE_MAX;
    FILE *output;
    if (program->declaration_count != 0u) {
        functions = malloc(program->declaration_count * sizeof(*functions));
        if (functions == NULL) {
            set_error(program, "E2S68", "reference-lowering order allocation failed");
            return false;
        }
    }
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->kind != DECLARATION_FUNCTION) continue;
        if (!validate_int_function_signature(program, declaration)) {
            free(functions);
            return false;
        }
        functions[function_count++] = index;
        if (strcmp(declaration->name, "main") == 0 && function_arity(program, declaration) == 0u) {
            if (entry != SIZE_MAX) {
                free(functions);
                set_error(program, "E2S65", "reference lowering found multiple zero-argument `main` functions");
                return false;
            }
            entry = index;
        }
    }
    if (entry == SIZE_MAX) {
        free(functions);
        set_error(program, "E2S65", "reference lowering requires exactly one zero-argument `main` function");
        return false;
    }
    comparison_resolver = resolver;
    if (function_count > 1u) qsort(functions, function_count, sizeof(*functions), compare_function_output);
    output = fopen(path, "wb");
    if (output == NULL) {
        free(functions);
        set_error(program, "E2S68", "cannot create reference C artifact");
        return false;
    }
    fputs("#include <stdint.h>\n\n", output);
    for (index = 0u; index < function_count; index += 1u) {
        if (!emit_c_function_signature(resolver, output, functions[index])) goto failed;
        fputs(";\n", output);
    }
    fputc('\n', output);
    for (index = 0u; index < function_count; index += 1u) {
        Declaration *declaration = &program->declarations[functions[index]];
        Module *module = &program->modules[declaration->module_index];
        size_t cursor = declaration->body_token_start;
        /* #1422. The prototype above is the whole of an external declaration;
         * its definition is in the library the caller links. */
        if (declaration->is_external) continue;
        if (!emit_c_function_signature(resolver, output, functions[index])) goto failed;
        fputs(" {\n    return ", output);
        if (cursor >= declaration->body_token_end ||
            !token_equals(module, &module->tokens[cursor], "return")) {
            set_error(program, "E2S65", "reference lowering requires a single return body in `%s`",
                module->logical_path);
            goto failed;
        }
        cursor += 1u;
        if (!emit_c_expression(resolver, output, functions[index], &cursor,
                declaration->body_token_end)) goto failed;
        if (cursor != declaration->body_token_end) {
            set_error(program, "E2S65", "reference lowering found trailing body tokens in `%s` at bytes %zu..%zu",
                module->logical_path, module->tokens[cursor].start,
                module->tokens[declaration->body_token_end - 1u].end);
            goto failed;
        }
        fputs(";\n}\n\n", output);
    }
    fputs("int main(void) {\n", output);
    for (index = 0u; index < function_count; index += 1u) {
        fputs("    (void)", output);
        emit_c_symbol(output, &program->declarations[functions[index]]);
        fputs(";\n", output);
    }
    fputs("    int64_t result = ", output);
    emit_c_symbol(output, &program->declarations[entry]);
    fputs("();\n    return result >= 0 && result <= 255 ? (int)result : 255;\n}\n", output);
    free(functions);
    if (fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S68", "cannot commit reference C artifact");
        return false;
    }
    return true;
failed:
    free(functions);
    fclose(output);
    remove(path);
    return false;
}

static void destroy_resolver(ImportResolver *resolver) {
    size_t index;
    for (index = 0u; index < resolver->import_count; index += 1u) {
        free(resolver->imports[index].path);
        free(resolver->imports[index].components);
    }
    free(resolver->imports);
    free(resolver->uses);
    free(resolver->expanded_error);
    destroy_program(&resolver->program);
}

#ifndef KOFUN_IMPORTS_QUALIFIED_NO_MAIN
int main(int argc, char **argv) {
    ImportResolver resolver;
    Program *program = &resolver.program;
    size_t index;
    int status = 1;
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "usage: %s INVENTORY OUTPUT_HIR [OUTPUT_REFERENCE_C]\n", argv[0]);
        return 2;
    }
    memset(&resolver, 0, sizeof(resolver));
    remove(argv[2]);
    if (argc == 4) remove(argv[3]);
    if (!load_qualified_inventory(&resolver, argv[1]) ||
        !order_and_validate_inventory(program) || !attach_declared_paths(&resolver)) goto done;
    for (index = 0u; index < program->module_count; index += 1u) {
        if (!collect_module_with_imports(&resolver, index)) goto done;
    }
    compute_identities(program);
    /* #1215. The trust classes are serialized before any admission decision
     * reads one, and the scratch artifact is removed as soon as it is read. */
    {
        char scratch[4096];
        int written = snprintf(scratch, sizeof scratch, "%s.trust.kif", argv[2]);
        if (written < 0 || (size_t)written >= sizeof scratch) {
            fprintf(stderr, "output path is too long for a trust artifact\n");
            goto done;
        }
        if (!serialize_module_trust(&resolver, scratch)) goto done;
    }
    if (!validate_duplicates(program) || !resolve_imports(&resolver) ||
        !validate_import_cycles(&resolver) || !resolve_qualified_bodies(&resolver) ||
        (argc == 4 && !emit_reference_c(&resolver, argv[3])) ||
        !emit_qualified_hir(&resolver, argv[2])) goto done;
    status = 0;
done:
    if (program->failed) {
        printf("%s\n", resolver.expanded_error != NULL ? resolver.expanded_error : program->error);
    }
    if (status != 0) remove(argv[2]);
    if (status != 0 && argc == 4) remove(argv[3]);
    destroy_resolver(&resolver);
    return status;
}
#endif
