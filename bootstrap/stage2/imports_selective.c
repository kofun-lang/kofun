#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
#define KOFUN_IMPORTS_QUALIFIED_NO_MAIN
#include "imports_qualified.c"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "confusable_visible_set.c"

#define SELECTIVE_DECLARATIONS_PER_MODULE_LIMIT 256u
#define SELECTIVE_NAMES_PER_DECLARATION_LIMIT 256u
#define SELECTIVE_REQUEST_LIMIT 65536u
#define SELECTIVE_BINDINGS_PER_MODULE_LIMIT 1024u
#define SELECTIVE_BINDING_LIMIT 65536u
#define SELECTIVE_USE_LIMIT 65536u
#define SELECTIVE_LOOKUP_WORK_LIMIT UINT64_C(10000000)

typedef struct {
    char spelling[IDENTIFIER_LIMIT + 1u];
    size_t start;
    size_t end;
    bool has_comma;
    size_t comma_start;
    size_t comma_end;
} SelectiveName;

typedef struct {
    size_t importer_index;
    size_t dependency_index;
    size_t from_start;
    size_t from_end;
    size_t path_start;
    size_t path_end;
    size_t import_start;
    size_t import_end;
    size_t whole_start;
    size_t whole_end;
    SelectiveName *names;
    size_t name_count;
    size_t name_capacity;
    bool is_re_export;
} SelectiveDeclaration;

typedef struct {
    size_t declaration_index;
    size_t name_index;
    size_t target_index;
    unsigned namespace_tag;
    uint8_t binding_id[32];
    KofunAccessResult access;
    bool referenced;
    bool interface_reference;
} SelectiveBinding;

typedef struct {
    size_t caller_index;
    size_t binding_index;
    size_t target_index;
    size_t name_start;
    size_t name_end;
    size_t expression_start;
    size_t expression_end;
    size_t arity;
} SelectiveUse;

typedef enum {
    TYPE_REFERENCE_PARAMETER,
    TYPE_REFERENCE_RETURN
} TypeReferenceRole;

typedef struct {
    size_t owner_index;
    size_t binding_index;
    size_t target_index;
    size_t start;
    size_t end;
    TypeReferenceRole role;
} SelectiveTypeUse;

typedef struct {
    ImportResolver qualified;
    SelectiveDeclaration *selectives;
    size_t selective_count;
    size_t selective_capacity;
    size_t request_count;
    size_t module_selective_counts[MODULE_LIMIT];
    SelectiveBinding *bindings;
    size_t binding_count;
    size_t binding_capacity;
    size_t module_binding_counts[MODULE_LIMIT];
    SelectiveUse *uses;
    size_t use_count;
    size_t use_capacity;
    SelectiveTypeUse *type_uses;
    size_t type_use_count;
    size_t type_use_capacity;
    uint8_t visible_confusable_cache_keys[MODULE_LIMIT][32];
    bool visible_confusables_checked;
    uint64_t lookup_work;
} SelectiveResolver;

static SelectiveResolver *selective_comparison_resolver;

typedef struct {
    const char *final_path;
    char *temporary_path;
    char *backup_path;
    bool had_original;
    bool installed;
} OutputArtifact;

static bool selective_lookup_step(SelectiveResolver *resolver) {
    resolver->lookup_work += 1u;
    if (resolver->lookup_work <= SELECTIVE_LOOKUP_WORK_LIMIT) return true;
    set_error(&resolver->qualified.program, "E2S75",
        "selective-import lookup exceeds %llu operations; hint: split the package or shorten import lists",
        (unsigned long long)SELECTIVE_LOOKUP_WORK_LIMIT);
    return false;
}

static bool reserve_selective_declaration(SelectiveResolver *resolver) {
    SelectiveDeclaration *resized;
    if (resolver->selective_count < resolver->selective_capacity) return true;
    {
        size_t capacity = resolver->selective_capacity == 0u ? 64u : resolver->selective_capacity * 2u;
        if (capacity > IMPORT_EDGE_LIMIT) capacity = IMPORT_EDGE_LIMIT;
        resized = realloc(resolver->selectives, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->qualified.program, "E2S78", "selective declaration allocation failed");
            return false;
        }
        resolver->selectives = resized;
        resolver->selective_capacity = capacity;
    }
    return true;
}

static bool reserve_selective_name(
    SelectiveResolver *resolver,
    SelectiveDeclaration *declaration
) {
    SelectiveName *resized;
    if (declaration->name_count >= SELECTIVE_NAMES_PER_DECLARATION_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "selective import exceeds %u requested names at bytes %zu..%zu; hint: split the declaration",
            SELECTIVE_NAMES_PER_DECLARATION_LIMIT,
            declaration->whole_start, declaration->whole_end);
        return false;
    }
    if (resolver->request_count >= SELECTIVE_REQUEST_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "package exceeds %u selective name requests; hint: split the package",
            SELECTIVE_REQUEST_LIMIT);
        return false;
    }
    if (declaration->name_count < declaration->name_capacity) return true;
    {
        size_t capacity = declaration->name_capacity == 0u ? 8u : declaration->name_capacity * 2u;
        if (capacity > SELECTIVE_NAMES_PER_DECLARATION_LIMIT) {
            capacity = SELECTIVE_NAMES_PER_DECLARATION_LIMIT;
        }
        resized = realloc(declaration->names, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->qualified.program, "E2S78", "selective name allocation failed");
            return false;
        }
        declaration->names = resized;
        declaration->name_capacity = capacity;
    }
    return true;
}

static bool reserve_selective_binding(SelectiveResolver *resolver, size_t importer_index) {
    SelectiveBinding *resized;
    if (resolver->binding_count >= SELECTIVE_BINDING_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "package exceeds %u expanded selective bindings; hint: split the package",
            SELECTIVE_BINDING_LIMIT);
        return false;
    }
    if (resolver->module_binding_counts[importer_index] >= SELECTIVE_BINDINGS_PER_MODULE_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "module `%s` exceeds %u expanded selective bindings; hint: import fewer names",
            resolver->qualified.program.modules[importer_index].logical_path,
            SELECTIVE_BINDINGS_PER_MODULE_LIMIT);
        return false;
    }
    if (resolver->binding_count < resolver->binding_capacity) return true;
    {
        size_t capacity = resolver->binding_capacity == 0u ? 128u : resolver->binding_capacity * 2u;
        if (capacity > SELECTIVE_BINDING_LIMIT) capacity = SELECTIVE_BINDING_LIMIT;
        resized = realloc(resolver->bindings, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->qualified.program, "E2S78", "selective binding allocation failed");
            return false;
        }
        resolver->bindings = resized;
        resolver->binding_capacity = capacity;
    }
    return true;
}

static bool reserve_selective_use(SelectiveResolver *resolver) {
    SelectiveUse *resized;
    if (resolver->use_count >= SELECTIVE_USE_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "selective value uses exceed %u; hint: split the package", SELECTIVE_USE_LIMIT);
        return false;
    }
    if (resolver->use_count < resolver->use_capacity) return true;
    {
        size_t capacity = resolver->use_capacity == 0u ? 128u : resolver->use_capacity * 2u;
        if (capacity > SELECTIVE_USE_LIMIT) capacity = SELECTIVE_USE_LIMIT;
        resized = realloc(resolver->uses, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->qualified.program, "E2S78", "selective value-use allocation failed");
            return false;
        }
        resolver->uses = resized;
        resolver->use_capacity = capacity;
    }
    return true;
}

static bool reserve_type_use(SelectiveResolver *resolver) {
    SelectiveTypeUse *resized;
    if (resolver->type_use_count >= SELECTIVE_USE_LIMIT) {
        set_error(&resolver->qualified.program, "E2S75",
            "selective type uses exceed %u; hint: split the package", SELECTIVE_USE_LIMIT);
        return false;
    }
    if (resolver->type_use_count < resolver->type_use_capacity) return true;
    {
        size_t capacity = resolver->type_use_capacity == 0u ? 128u : resolver->type_use_capacity * 2u;
        if (capacity > SELECTIVE_USE_LIMIT) capacity = SELECTIVE_USE_LIMIT;
        resized = realloc(resolver->type_uses, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(&resolver->qualified.program, "E2S78", "selective type-use allocation failed");
            return false;
        }
        resolver->type_uses = resized;
        resolver->type_use_capacity = capacity;
    }
    return true;
}

static bool parse_selective_path(
    SelectiveResolver *resolver,
    Module *module,
    size_t *cursor,
    ImportBinding *dependency,
    SelectiveDeclaration *declaration
) {
    Program *program = &resolver->qualified.program;
    char path[MODULE_PATH_LIMIT + 1u];
    ComponentSpan components[MODULE_PATH_COMPONENT_LIMIT];
    size_t path_length = 0u;
    size_t component_count = 0u;
    size_t current = *cursor;
    bool expect_identifier = true;
    bool found_import = false;
    while (current < module->token_count && !module->tokens[current].line_break_before) {
        Token *token = &module->tokens[current];
        if (!expect_identifier && token_equals(module, token, "import")) {
            declaration->import_start = token->start;
            declaration->import_end = token->end;
            found_import = true;
            current += 1u;
            break;
        }
        if (expect_identifier) {
            size_t length;
            if (token->kind != TOKEN_IDENTIFIER ||
                component_count >= MODULE_PATH_COMPONENT_LIMIT) {
                break;
            }
            length = token->end - token->start;
            if (path_length != 0u) path[path_length++] = '.';
            if (path_length + length > MODULE_PATH_LIMIT) break;
            memcpy(path + path_length, module->source + token->start, length);
            path_length += length;
            components[component_count++] = (ComponentSpan){ token->start, token->end };
        } else if (!punctuation_equals(module, token, '.')) {
            if (punctuation_equals(module, token, ':')) {
                set_error(program, "E2S69",
                    "external/package-qualified selective imports are unsupported in `%s` at bytes %zu..%zu; hint: import a module from the current package",
                    module->logical_path, declaration->whole_start, token->end);
                return false;
            }
            break;
        }
        expect_identifier = !expect_identifier;
        current += 1u;
    }
    if (!found_import || expect_identifier || component_count == 0u) {
        size_t end = current < module->token_count ? module->tokens[current].end : module->source_length;
        set_error(program, "E2S69",
            "malformed selective module path in `%s` at bytes %zu..%zu; hint: use `from a.b import Name`",
            module->logical_path, declaration->whole_start, end);
        return false;
    }
    path[path_length] = '\0';
    dependency->path = malloc(path_length + 1u);
    dependency->components = malloc(component_count * sizeof(*dependency->components));
    if (dependency->path == NULL || dependency->components == NULL) {
        set_error(program, "E2S78", "selective module-path allocation failed");
        return false;
    }
    memcpy(dependency->path, path, path_length + 1u);
    memcpy(dependency->components, components, component_count * sizeof(components[0]));
    dependency->component_count = component_count;
    declaration->path_start = components[0].start;
    declaration->path_end = components[component_count - 1u].end;
    *cursor = current;
    return true;
}

static void compute_selective_request_key(
    const Program *program,
    size_t importer_index,
    const char *target_path,
    const char *name,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.diagnostic.selective-request/v1";
    const Module *importer = &program->modules[importer_index];
    size_t domain_length = strlen(domain);
    size_t path_length = strlen(target_path);
    size_t name_length = strlen(name);
    size_t payload_length = 24u + 32u + 32u + path_length + name_length;
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
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)target_path, path_length);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name, name_length);
    kofun_sha256_finish(&context, digest);
}

static bool parse_selective_import(
    SelectiveResolver *resolver,
    size_t module_index,
    size_t *cursor
) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    Module *module = &program->modules[module_index];
    ImportModule *import_module = &qualified->modules[module_index];
    SelectiveDeclaration *declaration;
    ImportBinding *dependency;
    size_t current;
    if (resolver->module_selective_counts[module_index] >=
            SELECTIVE_DECLARATIONS_PER_MODULE_LIMIT) {
        set_error(program, "E2S75", "module `%s` exceeds %u selective declarations; hint: combine import lists",
            module->logical_path, SELECTIVE_DECLARATIONS_PER_MODULE_LIMIT);
        return false;
    }
    if (import_module->import_count >= IMPORTS_PER_MODULE_LIMIT) {
        set_error(program, "E2S75",
            "module `%s` exceeds %u combined qualified/selective imports; hint: combine or remove imports",
            module->logical_path, IMPORTS_PER_MODULE_LIMIT);
        return false;
    }
    if (!reserve_selective_declaration(resolver) || !reserve_import(qualified)) return false;
    declaration = &resolver->selectives[resolver->selective_count++];
    dependency = &qualified->imports[qualified->import_count++];
    memset(declaration, 0, sizeof(*declaration));
    memset(dependency, 0, sizeof(*dependency));
    declaration->importer_index = module_index;
    declaration->dependency_index = qualified->import_count - 1u;
    declaration->from_start = module->tokens[*cursor].start;
    declaration->from_end = module->tokens[*cursor].end;
    declaration->whole_start = declaration->from_start;
    declaration->whole_end = declaration->from_end;
    dependency->importer_index = module_index;
    dependency->form_tag = IMPORT_FORM_SELECTIVE;
    dependency->start = declaration->whole_start;
    import_module->import_count += 1u;
    resolver->module_selective_counts[module_index] += 1u;
    current = *cursor + 1u;
    if (!parse_selective_path(resolver, module, &current, dependency, declaration)) return false;
    if (current >= module->token_count || module->tokens[current].line_break_before) {
        set_error(program, "E2S69",
            "selective import list is empty in `%s` at bytes %zu..%zu; hint: list at least one name",
            module->logical_path, declaration->import_start, declaration->import_end);
        return false;
    }
    while (current < module->token_count && !module->tokens[current].line_break_before) {
        Token *token = &module->tokens[current];
        SelectiveName *name;
        size_t prior;
        if (punctuation_equals(module, token, '*')) {
            set_error(program, "E2S69",
                "wildcard selective imports are unsupported in `%s` at bytes %zu..%zu; hint: list each required name explicitly",
                module->logical_path, token->start, token->end);
            return false;
        }
        if (token->kind != TOKEN_IDENTIFIER || token_equals(module, token, "as")) {
            set_error(program, "E2S69",
                "malformed selective name list in `%s` at bytes %zu..%zu; hint: use comma-separated identifiers",
                module->logical_path, token->start, token->end);
            return false;
        }
        if (!reserve_selective_name(resolver, declaration)) return false;
        name = &declaration->names[declaration->name_count];
        memset(name, 0, sizeof(*name));
        memcpy(name->spelling, module->source + token->start, token->end - token->start);
        name->spelling[token->end - token->start] = '\0';
        name->start = token->start;
        name->end = token->end;
        for (prior = 0u; prior < declaration->name_count; prior += 1u) {
            SelectiveName *first = &declaration->names[prior];
            if (strcmp(first->spelling, name->spelling) == 0) {
                uint8_t request_key[32];
                char request_hex[65];
                compute_selective_request_key(program, module_index,
                    dependency->path, name->spelling, request_key);
                bytes_to_hex(request_key, 32u, request_hex);
                set_error(program, "E2S70",
                    "duplicate requested name `%s` in `%s`; request-key=%s; canonical-spans=%zu..%zu,%zu..%zu; hint: remove one name",
                    name->spelling, module->logical_path, request_hex,
                    first->start < name->start ? first->start : name->start,
                    first->start < name->start ? first->end : name->end,
                    first->start < name->start ? name->start : first->start,
                    first->start < name->start ? name->end : first->end);
                return false;
            }
        }
        declaration->name_count += 1u;
        resolver->request_count += 1u;
        declaration->whole_end = name->end;
        current += 1u;
        if (current >= module->token_count || module->tokens[current].line_break_before) break;
        if (token_equals(module, &module->tokens[current], "as")) {
            set_error(program, "E2S69",
                "per-name aliases are unsupported in `%s` at bytes %zu..%zu; hint: import the original name",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
        if (!punctuation_equals(module, &module->tokens[current], ',')) {
            set_error(program, "E2S69",
                "selective names require commas in `%s` at bytes %zu..%zu; hint: insert `,` between names",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
        name->has_comma = true;
        name->comma_start = module->tokens[current].start;
        name->comma_end = module->tokens[current].end;
        declaration->whole_end = name->comma_end;
        current += 1u;
        if (current >= module->token_count || module->tokens[current].line_break_before) break;
        if (punctuation_equals(module, &module->tokens[current], ',')) {
            set_error(program, "E2S69",
                "selective import has an empty name in `%s` at bytes %zu..%zu; hint: remove the extra comma",
                module->logical_path, module->tokens[current].start, module->tokens[current].end);
            return false;
        }
    }
    dependency->end = declaration->whole_end;
    *cursor = current;
    return true;
}

static bool collect_module_with_selective_imports(
    SelectiveResolver *resolver,
    size_t module_index
) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    Module *module = &program->modules[module_index];
    size_t cursor;
    qualified->modules[module_index].first_import = qualified->import_count;
    if (!tokenize(program, module) || !parse_and_check_header(qualified, module_index, &cursor)) return false;
    while (cursor < module->token_count &&
        (token_equals(module, &module->tokens[cursor], "import") ||
         token_equals(module, &module->tokens[cursor], "from"))) {
        if (qualified->modules[module_index].import_count >= IMPORTS_PER_MODULE_LIMIT) {
            set_error(program, "E2S75",
                "module `%s` exceeds %u combined qualified/selective imports; hint: combine or remove imports",
                module->logical_path, IMPORTS_PER_MODULE_LIMIT);
            return false;
        }
        if (token_equals(module, &module->tokens[cursor], "import")) {
            if (!parse_import(qualified, module_index, &cursor)) return false;
        } else if (!parse_selective_import(resolver, module_index, &cursor)) {
            return false;
        }
    }
    while (cursor < module->token_count) {
        size_t declaration_start = module->tokens[cursor].start;
        Visibility visibility = VISIBILITY_IMPLICIT_PRIVATE;
        if (token_equals(module, &module->tokens[cursor], "import") ||
            token_equals(module, &module->tokens[cursor], "from")) {
            set_error(program, "E2S69",
                "imports must precede declarations in `%s` at bytes %zu..%zu; hint: move the import above declarations",
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
                set_error(program, "E2S69",
                    "modified/re-export selective imports are unsupported in `%s` at bytes %zu..%zu; hint: remove the visibility modifier",
                    module->logical_path, declaration_start, module->tokens[cursor].end);
                return false;
            }
        }
        if (token_equals(module, &module->tokens[cursor], "fn")) {
            if (!parse_function(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "type")) {
            if (!parse_adt(program, module_index, declaration_start, visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "export")) {
            set_error(program, "E2S69",
                "re-exports are unsupported in `%s` at bytes %zu..%zu; hint: use an ordinary selective import",
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

static KofunAccessResult selective_access(
    const SelectiveResolver *resolver,
    size_t importer_index,
    const Declaration *target,
    size_t use_start,
    size_t use_end
) {
    const Program *program = &resolver->qualified.program;
    const Module *importer = &program->modules[importer_index];
    const Module *target_module = &program->modules[target->module_index];
    KofunAccessContext context;
    KofunDeclarationAccess declaration;
    memset(&context, 0, sizeof(context));
    memset(&declaration, 0, sizeof(declaration));
    context.caller_package = access_identity(KOFUN_ID_PACKAGE, importer->package_id);
    context.caller_module = access_identity(KOFUN_ID_MODULE, importer->module_id);
    context.caller_file = access_identity(KOFUN_ID_FILE, importer->file_id);
    context.use_span = (KofunSpan){ (uint32_t)use_start, (uint32_t)use_end };
    declaration.declared_visibility = access_visibility(target->visibility);
    declaration.defining_package = access_identity(KOFUN_ID_PACKAGE, target_module->package_id);
    declaration.defining_module = access_identity(KOFUN_ID_MODULE, target_module->module_id);
    declaration.defining_file = access_identity(KOFUN_ID_FILE, target_module->file_id);
    declaration.declaration_span = (KofunSpan){ (uint32_t)target->start, (uint32_t)target->end };
    return kofun_decide_access(&context, &declaration);
}

static void compute_selective_binding_id(
    const SelectiveResolver *resolver,
    const SelectiveDeclaration *selective,
    const SelectiveName *name,
    const Declaration *target,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.import-binding/v1";
    static const uint8_t form_tag = IMPORT_FORM_SELECTIVE;
    const Program *program = &resolver->qualified.program;
    const Module *importer = &program->modules[selective->importer_index];
    size_t domain_length = strlen(domain);
    size_t name_length = strlen(name->spelling);
    size_t payload_length = 36u + 32u + 32u + 32u + name_length + 32u + 1u;
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
    hash_field(&context, UINT16_C(0x8003), target->namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name->spelling, name_length);
    hash_field(&context, UINT16_C(0x8005), target->symbol_id, 32u);
    hash_field(&context, UINT16_C(0x8006), &form_tag, 1u);
    kofun_sha256_finish(&context, digest);
}

static bool selective_binding_collision(
    SelectiveResolver *resolver,
    size_t importer_index,
    const SelectiveName *name,
    const Declaration *target,
    const uint8_t candidate_binding_id[32]
) {
    Program *program = &resolver->qualified.program;
    unsigned namespace_tag = target->namespace_tag;
    size_t index;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *local = &program->declarations[index];
        if (!selective_lookup_step(resolver)) return true;
        if (local->module_index == importer_index && local->namespace_tag == namespace_tag &&
            strcmp(local->name, name->spelling) == 0) {
            const Declaration *first = memcmp(local->symbol_id, target->symbol_id, 32u) <= 0 ? local : target;
            const Declaration *second = first == local ? target : local;
            size_t first_start = first == local ? local->name_start : name->start;
            size_t first_end = first == local ? local->name_end : name->end;
            size_t second_start = second == local ? local->name_start : name->start;
            size_t second_end = second == local ? local->name_end : name->end;
            char first_hex[65];
            char second_hex[65];
            char binding_hex[65];
            bytes_to_hex(first->symbol_id, 32u, first_hex);
            bytes_to_hex(second->symbol_id, 32u, second_hex);
            bytes_to_hex(candidate_binding_id, 32u, binding_hex);
            set_error(program, "E2S73",
                "selective %s binding `%s` collides with a local declaration in `%s`; canonical-pair=%s@%zu..%zu,%s@%zu..%zu; import-binding=%s; hint: remove the import or rename the local declaration",
                namespace_name(namespace_tag), name->spelling,
                program->modules[importer_index].logical_path,
                first_hex, first_start, first_end, second_hex, second_start, second_end,
                binding_hex);
            return true;
        }
    }
    for (index = 0u; index < resolver->binding_count; index += 1u) {
        SelectiveBinding *other = &resolver->bindings[index];
        SelectiveDeclaration *other_declaration = &resolver->selectives[other->declaration_index];
        SelectiveName *other_name = &other_declaration->names[other->name_index];
        if (!selective_lookup_step(resolver)) return true;
        if (other_declaration->importer_index == importer_index &&
            other->namespace_tag == namespace_tag &&
            strcmp(other_name->spelling, name->spelling) == 0) {
            const Declaration *other_target = &program->declarations[other->target_index];
            bool current_first = memcmp(target->symbol_id, other_target->symbol_id, 32u) < 0 ||
                (memcmp(target->symbol_id, other_target->symbol_id, 32u) == 0 &&
                 memcmp(candidate_binding_id, other->binding_id, 32u) <= 0);
            const uint8_t *first_symbol = current_first ? target->symbol_id : other_target->symbol_id;
            const uint8_t *second_symbol = current_first ? other_target->symbol_id : target->symbol_id;
            const uint8_t *first_binding = current_first ? candidate_binding_id : other->binding_id;
            const uint8_t *second_binding = current_first ? other->binding_id : candidate_binding_id;
            const SelectiveName *first_name = current_first ? name : other_name;
            const SelectiveName *second_name = current_first ? other_name : name;
            char first_symbol_hex[65];
            char second_symbol_hex[65];
            char first_binding_hex[65];
            char second_binding_hex[65];
            bytes_to_hex(first_symbol, 32u, first_symbol_hex);
            bytes_to_hex(second_symbol, 32u, second_symbol_hex);
            bytes_to_hex(first_binding, 32u, first_binding_hex);
            bytes_to_hex(second_binding, 32u, second_binding_hex);
            set_error(program, "E2S73",
                "selective %s binding `%s` collides in `%s`; canonical-pair=%s/%s@%zu..%zu,%s/%s@%zu..%zu; hint: keep exactly one import for this namespace/name",
                namespace_name(namespace_tag), name->spelling,
                program->modules[importer_index].logical_path,
                first_symbol_hex, first_binding_hex, first_name->start, first_name->end,
                second_symbol_hex, second_binding_hex, second_name->start, second_name->end);
            return true;
        }
    }
    return false;
}

static bool resolve_selective_bindings(SelectiveResolver *resolver) {
    Program *program = &resolver->qualified.program;
    size_t selective_index;
    for (selective_index = 0u; selective_index < resolver->selective_count; selective_index += 1u) {
        SelectiveDeclaration *selective = &resolver->selectives[selective_index];
        ImportBinding *dependency = &resolver->qualified.imports[selective->dependency_index];
        size_t name_index;
        if (selective->is_re_export) continue;
        for (name_index = 0u; name_index < selective->name_count; name_index += 1u) {
            SelectiveName *name = &selective->names[name_index];
            bool found_candidate = false;
            bool found_accessible = false;
            KofunAccessResult denied;
            size_t denied_target = SIZE_MAX;
            size_t target_index;
            memset(&denied, 0, sizeof(denied));
            for (target_index = 0u; target_index < program->declaration_count; target_index += 1u) {
                Declaration *target = &program->declarations[target_index];
                KofunAccessResult access;
                SelectiveBinding *binding;
                uint8_t candidate_binding_id[32];
                if (!selective_lookup_step(resolver)) return false;
                if (target->module_index != dependency->target_index ||
                    (target->kind != DECLARATION_FUNCTION && target->kind != DECLARATION_ADT) ||
                    strcmp(target->name, name->spelling) != 0) continue;
                found_candidate = true;
                access = selective_access(resolver, selective->importer_index, target,
                    name->start, name->end);
                if (access.kind != KOFUN_ACCESS_ALLOWED || !access.usable_reference) {
                    if (denied_target == SIZE_MAX || memcmp(target->symbol_id,
                            program->declarations[denied_target].symbol_id, 32u) < 0) {
                        denied = access;
                        denied_target = target_index;
                    }
                    continue;
                }
                found_accessible = true;
                compute_selective_binding_id(resolver, selective, name, target,
                    candidate_binding_id);
                if (selective_binding_collision(resolver, selective->importer_index,
                        name, target, candidate_binding_id)) return false;
                if (!reserve_selective_binding(resolver, selective->importer_index)) return false;
                binding = &resolver->bindings[resolver->binding_count++];
                memset(binding, 0, sizeof(*binding));
                binding->declaration_index = selective_index;
                binding->name_index = name_index;
                binding->target_index = target_index;
                binding->namespace_tag = target->namespace_tag;
                binding->access = access;
                memcpy(binding->binding_id, candidate_binding_id, 32u);
                resolver->module_binding_counts[selective->importer_index] += 1u;
            }
            if (!found_accessible) {
                if (found_candidate) {
                    set_error(program, "E2S72",
                        "requested name `%s` from module `%s` is inaccessible at `%s` bytes %zu..%zu: %s; hint: expose an internal or public declaration, or keep the use in its defining file",
                        name->spelling, dependency->path,
                        program->modules[selective->importer_index].logical_path,
                        name->start, name->end, kofun_access_reason_name(denied.reason));
                } else {
                    set_error(program, "E2S71",
                        "module `%s` has no importable function or nominal type `%s` requested at `%s` bytes %zu..%zu; hint: fix the spelling or export a supported declaration",
                        dependency->path, name->spelling,
                        program->modules[selective->importer_index].logical_path,
                        name->start, name->end);
                }
                return false;
            }
        }
    }
    return true;
}

static bool graph_edge_is_less(const ImportBinding *left, const ImportBinding *right) {
    int result;
    if (left->start != right->start) return left->start < right->start;
    if (left->end != right->end) return left->end < right->end;
    if (left->form_tag != right->form_tag) return left->form_tag < right->form_tag;
    result = memcmp(left->binding_id, right->binding_id, 32u);
    return result < 0;
}

static void canonicalize_import_graph_edges(SelectiveResolver *resolver) {
    size_t index;
    for (index = 0u; index < resolver->qualified.import_count; index += 1u) {
        ImportBinding *current_edge = &resolver->qualified.imports[index];
        size_t prior;
        for (prior = 0u; prior < index; prior += 1u) {
            ImportBinding *other_edge = &resolver->qualified.imports[prior];
            if (current_edge->importer_index != other_edge->importer_index ||
                current_edge->target_index != other_edge->target_index ||
                other_edge->graph_duplicate) continue;
            if (graph_edge_is_less(current_edge, other_edge)) {
                other_edge->graph_duplicate = true;
            } else {
                current_edge->graph_duplicate = true;
            }
            break;
        }
    }
}

static size_t find_selective_binding(
    const SelectiveResolver *resolver,
    size_t importer_index,
    const Module *use_module,
    const Token *name,
    unsigned namespace_tag
) {
    size_t index;
    for (index = 0u; index < resolver->binding_count; index += 1u) {
        const SelectiveBinding *binding = &resolver->bindings[index];
        const SelectiveDeclaration *declaration = &resolver->selectives[binding->declaration_index];
        const SelectiveName *requested = &declaration->names[binding->name_index];
        if (declaration->importer_index == importer_index &&
            binding->namespace_tag == namespace_tag &&
            token_matches_text(use_module, name, requested->spelling)) return index;
    }
    return SIZE_MAX;
}

static bool module_has_accessible_target(
    const SelectiveResolver *resolver,
    size_t importer_index,
    size_t target_module_index,
    const Module *use_module,
    const Token *name,
    unsigned namespace_tag
) {
    const Program *program = &resolver->qualified.program;
    size_t index;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        const Declaration *target = &program->declarations[index];
        KofunAccessResult access;
        if (target->module_index != target_module_index || target->namespace_tag != namespace_tag ||
            !token_matches_text(use_module, name, target->name)) continue;
        access = selective_access(resolver, importer_index, target, name->start, name->end);
        if (access.kind == KOFUN_ACCESS_ALLOWED && access.usable_reference) return true;
    }
    return false;
}

static bool direct_selective_module_has_accessible_target(
    const SelectiveResolver *resolver,
    size_t importer_index,
    const Module *use_module,
    const Token *name,
    unsigned namespace_tag
) {
    size_t index;
    for (index = 0u; index < resolver->selective_count; index += 1u) {
        const SelectiveDeclaration *selective = &resolver->selectives[index];
        const ImportBinding *dependency = &resolver->qualified.imports[selective->dependency_index];
        if (selective->importer_index == importer_index &&
            module_has_accessible_target(resolver, importer_index, dependency->target_index,
                use_module, name, namespace_tag)) return true;
    }
    return false;
}

static bool direct_qualified_module_has_accessible_function(
    const SelectiveResolver *resolver,
    size_t importer_index,
    const Module *use_module,
    const Token *name
) {
    const ImportModule *imports = &resolver->qualified.modules[importer_index];
    size_t index;
    for (index = imports->first_import; index < imports->first_import + imports->import_count; index += 1u) {
        const ImportBinding *dependency = &resolver->qualified.imports[index];
        if (dependency->form_tag == IMPORT_FORM_QUALIFIED &&
            module_has_accessible_target(resolver, importer_index, dependency->target_index,
                use_module, name, 0u)) return true;
    }
    return false;
}

static bool resolve_qualified_calls_for_selective(SelectiveResolver *resolver) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    size_t caller_index;
    for (caller_index = 0u; caller_index < program->declaration_count; caller_index += 1u) {
        Declaration *caller = &program->declarations[caller_index];
        Module *module;
        ImportModule *imports;
        size_t cursor;
        if (caller->kind != DECLARATION_FUNCTION) continue;
        module = &program->modules[caller->module_index];
        imports = &qualified->modules[caller->module_index];
        for (cursor = caller->body_token_start; cursor < caller->body_token_end; cursor += 1u) {
            Token *qualifier = &module->tokens[cursor];
            size_t dependency_index = SIZE_MAX;
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
                if (qualified->imports[import_index].form_tag == IMPORT_FORM_QUALIFIED &&
                    token_matches_text(module, qualifier, qualified->imports[import_index].qualifier)) {
                    dependency_index = import_index;
                    break;
                }
            }
            if (dependency_index == SIZE_MAX) {
                set_error(program, "E2S74",
                    "unknown module qualifier `%.*s` in `%s` at bytes %zu..%zu; hint: add `import module.path` or use an unqualified selective binding",
                    (int)(qualifier->end - qualifier->start), module->source + qualifier->start,
                    module->logical_path, qualifier->start, qualifier->end);
                return false;
            }
            for (declaration_index = 0u; declaration_index < program->declaration_count; declaration_index += 1u) {
                Declaration *target = &program->declarations[declaration_index];
                if (target->module_index == qualified->imports[dependency_index].target_index &&
                    target->kind == DECLARATION_FUNCTION &&
                    token_matches_text(module, &module->tokens[cursor + 2u], target->name)) {
                    target_index = declaration_index;
                    break;
                }
            }
            if (target_index == SIZE_MAX) {
                set_error(program, "E2S74",
                    "module `%s` has no function `%.*s` used in `%s` at bytes %zu..%zu; hint: fix the member spelling",
                    qualified->imports[dependency_index].path,
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
                set_error(program, "E2S72",
                    "qualified use in `%s` at bytes %zu..%zu is inaccessible: %s; hint: expose an internal or public target, or keep the call in the defining file",
                    module->logical_path, qualifier->start, module->tokens[close].end,
                    kofun_access_reason_name(access.reason));
                return false;
            }
            if (!validate_int_function_signature(program, &program->declarations[target_index])) return false;
            expected = function_arity(program, &program->declarations[target_index]);
            if (expected == SIZE_MAX) {
                set_error(program, "E2S78", "qualified function signature invariant failed");
                return false;
            }
            if (arity != expected) {
                set_error(program, "E2S76",
                    "qualified call `%s.%s` expects %zu arguments but got %zu in `%s`; hint: pass exactly %zu arguments",
                    qualified->imports[dependency_index].qualifier,
                    program->declarations[target_index].name, expected, arity,
                    module->logical_path, expected);
                return false;
            }
            if (!reserve_use(qualified)) return false;
            qualified->uses[qualified->use_count++] = (QualifiedUse){
                .caller_index = caller_index,
                .binding_index = dependency_index,
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
        }
    }
    return true;
}

static bool resolve_selective_value_uses(SelectiveResolver *resolver) {
    Program *program = &resolver->qualified.program;
    size_t caller_index;
    for (caller_index = 0u; caller_index < program->declaration_count; caller_index += 1u) {
        Declaration *caller = &program->declarations[caller_index];
        Module *module;
        size_t cursor;
        if (caller->kind != DECLARATION_FUNCTION) continue;
        module = &program->modules[caller->module_index];
        for (cursor = caller->body_token_start; cursor < caller->body_token_end; cursor += 1u) {
            Token *name = &module->tokens[cursor];
            size_t local;
            size_t binding_index;
            size_t type_binding;
            size_t arity;
            size_t close;
            size_t expected;
            SelectiveBinding *binding;
            Declaration *target;
            if (name->kind != TOKEN_IDENTIFIER || cursor + 1u >= caller->body_token_end ||
                !punctuation_equals(module, &module->tokens[cursor + 1u], '(') ||
                keyword_call(module, name) ||
                (cursor > caller->body_token_start &&
                    punctuation_equals(module, &module->tokens[cursor - 1u], '.'))) continue;
            local = find_local_function(program, caller->module_index, module, name);
            if (local != SIZE_MAX) continue;
            binding_index = find_selective_binding(resolver, caller->module_index, module, name, 0u);
            if (binding_index == SIZE_MAX) {
                type_binding = find_selective_binding(resolver, caller->module_index, module, name, 1u);
                if (type_binding != SIZE_MAX) {
                    set_error(program, "E2S74",
                        "selective type `%.*s` is not callable in `%s` at bytes %zu..%zu; hint: import a value/function with this spelling",
                        (int)(name->end - name->start), module->source + name->start,
                        module->logical_path, name->start, name->end);
                } else if (direct_selective_module_has_accessible_target(
                        resolver, caller->module_index, module, name, 0u)) {
                    set_error(program, "E2S74",
                        "function `%.*s` is not listed by a direct selective import in `%s` at bytes %zu..%zu; hint: add it to the explicit name list",
                        (int)(name->end - name->start), module->source + name->start,
                        module->logical_path, name->start, name->end);
                } else if (direct_qualified_module_has_accessible_function(
                        resolver, caller->module_index, module, name)) {
                    set_error(program, "E2S74",
                        "qualified imported function `%.*s` requires its module qualifier in `%s` at bytes %zu..%zu; hint: use `module.%.*s(...)`",
                        (int)(name->end - name->start), module->source + name->start,
                        module->logical_path, name->start, name->end,
                        (int)(name->end - name->start), module->source + name->start);
                } else {
                    set_error(program, "E2S74",
                        "unbound value `%.*s` in `%s` at bytes %zu..%zu; hint: declare it locally or list it in a direct selective import",
                        (int)(name->end - name->start), module->source + name->start,
                        module->logical_path, name->start, name->end);
                }
                return false;
            }
            binding = &resolver->bindings[binding_index];
            target = &program->declarations[binding->target_index];
            if (!call_arity(program, module, cursor + 1u, caller->body_token_end, &arity, &close)) return false;
            if (!validate_int_function_signature(program, target)) {
                if (program->failed && strstr(program->error, "error[E2S65]") == program->error) {
                    char detail[sizeof(program->error)];
                    memcpy(detail, program->error, sizeof(detail));
                    program->failed = false;
                    set_error(program, "E2S76", "%s", detail + strlen("error[E2S65]: "));
                }
                return false;
            }
            expected = function_arity(program, target);
            if (expected == SIZE_MAX) {
                set_error(program, "E2S78", "selective function signature invariant failed");
                return false;
            }
            if (arity != expected) {
                set_error(program, "E2S76",
                    "selective call `%s` expects %zu arguments but got %zu in `%s`; hint: pass exactly %zu arguments",
                    target->name, expected, arity, module->logical_path, expected);
                return false;
            }
            if (!reserve_selective_use(resolver)) return false;
            resolver->uses[resolver->use_count++] = (SelectiveUse){
                .caller_index = caller_index,
                .binding_index = binding_index,
                .target_index = binding->target_index,
                .name_start = name->start,
                .name_end = name->end,
                .expression_start = name->start,
                .expression_end = module->tokens[close].end,
                .arity = arity
            };
            binding->referenced = true;
        }
    }
    return true;
}

static bool builtin_type_token(const Module *module, const Token *token) {
    return token_equals(module, token, "Int") || token_equals(module, token, "Bool") ||
        token_equals(module, token, "Text");
}

static bool local_type_token(
    const Program *program,
    size_t module_index,
    const Module *module,
    const Token *token
) {
    size_t index;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        const Declaration *declaration = &program->declarations[index];
        if (declaration->module_index == module_index && declaration->kind == DECLARATION_ADT &&
            token_matches_text(module, token, declaration->name)) return true;
    }
    return false;
}

static bool resolve_one_type_reference(
    SelectiveResolver *resolver,
    size_t owner_index,
    const Token *token,
    TypeReferenceRole role
) {
    Program *program = &resolver->qualified.program;
    Declaration *owner = &program->declarations[owner_index];
    Module *module = &program->modules[owner->module_index];
    size_t binding_index;
    SelectiveBinding *binding;
    if (builtin_type_token(module, token) ||
        local_type_token(program, owner->module_index, module, token)) return true;
    binding_index = find_selective_binding(resolver, owner->module_index, module, token, 1u);
    if (binding_index == SIZE_MAX) {
        if (find_selective_binding(resolver, owner->module_index, module, token, 0u) != SIZE_MAX) {
            set_error(program, "E2S74",
                "selective value `%.*s` is not a type in `%s` at bytes %zu..%zu; hint: import a nominal type with this spelling",
                (int)(token->end - token->start), module->source + token->start,
                module->logical_path, token->start, token->end);
        } else if (direct_selective_module_has_accessible_target(
                resolver, owner->module_index, module, token, 1u)) {
            set_error(program, "E2S74",
                "nominal type `%.*s` is not listed by a direct selective import in `%s` at bytes %zu..%zu; hint: add it to the explicit name list",
                (int)(token->end - token->start), module->source + token->start,
                module->logical_path, token->start, token->end);
        } else {
            set_error(program, "E2S74",
                "unbound type `%.*s` in `%s` at bytes %zu..%zu; hint: declare it locally or list it in a direct selective import",
                (int)(token->end - token->start), module->source + token->start,
                module->logical_path, token->start, token->end);
        }
        return false;
    }
    if (!reserve_type_use(resolver)) return false;
    binding = &resolver->bindings[binding_index];
    resolver->type_uses[resolver->type_use_count++] = (SelectiveTypeUse){
        .owner_index = owner_index,
        .binding_index = binding_index,
        .target_index = binding->target_index,
        .start = token->start,
        .end = token->end,
        .role = role
    };
    binding->referenced = true;
    if (owner->visibility == VISIBILITY_PUBLIC) binding->interface_reference = true;
    return true;
}

static bool resolve_selective_type_uses(SelectiveResolver *resolver) {
    Program *program = &resolver->qualified.program;
    size_t owner_index;
#if defined(KOFUN_TEST_DIAGNOSTIC_FAULTS)
    if (diagnostic_fault_requested("selective-type-resolution-token")) {
        set_error(program, "E2S78", "type-resolution signature token invariant failed");
        return false;
    }
#endif
    for (owner_index = 0u; owner_index < program->declaration_count; owner_index += 1u) {
        Declaration *owner = &program->declarations[owner_index];
        Module *module;
        size_t name;
        size_t open;
        size_t close;
        size_t cursor;
        if (owner->kind != DECLARATION_FUNCTION) continue;
        module = &program->modules[owner->module_index];
        name = function_name_token_index(program, owner);
        if (name == SIZE_MAX || name + 1u >= module->token_count) {
            set_error(program, "E2S78", "type-resolution signature token invariant failed");
            return false;
        }
        open = name + 1u;
        for (close = open + 1u; close < module->token_count; close += 1u) {
            if (punctuation_equals(module, &module->tokens[close], ')')) break;
        }
        if (close >= module->token_count || close + 2u >= module->token_count) {
            set_error(program, "E2S78", "type-resolution signature delimiter invariant failed");
            return false;
        }
        cursor = open + 1u;
        while (cursor < close) {
            if (cursor + 2u >= close || !resolve_one_type_reference(
                    resolver, owner_index, &module->tokens[cursor + 2u],
                    TYPE_REFERENCE_PARAMETER)) return false;
            cursor += 3u;
            if (cursor < close) cursor += 1u;
        }
        if (!resolve_one_type_reference(resolver, owner_index,
                &module->tokens[close + 2u], TYPE_REFERENCE_RETURN)) return false;
    }
    return true;
}

static void initialize_visible_binding(
    KofunVisibleBinding *output,
    const Module *resolving_module,
    const uint8_t namespace_id[32],
    const uint8_t binding_id[32],
    const uint8_t target_symbol_id[32],
    const char *spelling,
    KofunVisibleSiteKind site_kind,
    size_t start,
    size_t end
) {
    memset(output, 0, sizeof(*output));
    memcpy(output->resolving_module_id, resolving_module->module_id, 32u);
    memcpy(output->namespace_id, namespace_id, 32u);
    memcpy(output->binding_id, binding_id, 32u);
    memcpy(output->target_symbol_id, target_symbol_id, 32u);
    output->effective_spelling = (const uint8_t *)spelling;
    output->effective_spelling_length = strlen(spelling);
    output->site_kind = site_kind;
    output->canonical_provenance = resolving_module->logical_path;
    output->span_start = (uint32_t)start;
    output->span_end = (uint32_t)end;
    output->disclose_location = true;
}

static bool collect_selective_visible_bindings(
    SelectiveResolver *resolver,
    size_t module_index,
    KofunVisibleBinding *visible,
    size_t capacity,
    size_t *count
) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    const Module *module = &program->modules[module_index];
    size_t index;
    *count = 0u;
    if (visible == NULL && capacity != 0u) return false;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->module_index != module_index) continue;
        if (visible == NULL || *count >= capacity) return false;
        initialize_visible_binding(&visible[(*count)++], module,
            declaration->namespace_id, declaration->symbol_id,
            declaration->symbol_id, declaration->name,
            KOFUN_VISIBLE_SITE_LOCAL, declaration->name_start,
            declaration->name_end);
    }
    for (index = 0u; index < qualified->import_count; index += 1u) {
        ImportBinding *binding = &qualified->imports[index];
        uint8_t target_symbol[32];
        const uint8_t *effective_binding;
        size_t start;
        size_t end;
        if (binding->importer_index != module_index ||
            binding->form_tag != IMPORT_FORM_QUALIFIED) continue;
        if (visible == NULL || *count >= capacity) return false;
        compute_symbol_hash(
            program->modules[binding->target_index].module_id,
            program->namespace_ids[2], "module",
            qualified->modules[binding->target_index].declared_path,
            target_symbol);
        effective_binding = binding->has_alias
            ? binding->alias_binding_id : binding->binding_id;
        start = binding->has_alias ? binding->alias_start
            : binding->components[binding->component_count - 1u].start;
        end = binding->has_alias ? binding->alias_end
            : binding->components[binding->component_count - 1u].end;
        initialize_visible_binding(&visible[(*count)++], module,
            program->namespace_ids[2], effective_binding, target_symbol,
            binding->qualifier, KOFUN_VISIBLE_SITE_IMPORT, start, end);
    }
    for (index = 0u; index < resolver->binding_count; index += 1u) {
        SelectiveBinding *binding = &resolver->bindings[index];
        SelectiveDeclaration *selective =
            &resolver->selectives[binding->declaration_index];
        SelectiveName *name = &selective->names[binding->name_index];
        Declaration *target = &program->declarations[binding->target_index];
        if (selective->is_re_export ||
            selective->importer_index != module_index) continue;
        if (visible == NULL || *count >= capacity) return false;
        initialize_visible_binding(&visible[(*count)++], module,
            target->namespace_id, binding->binding_id, target->symbol_id,
            name->spelling, KOFUN_VISIBLE_SITE_IMPORT,
            name->start, name->end);
    }
    return true;
}

static bool check_visible_binding_vector(
    SelectiveResolver *resolver,
    size_t module_index,
    KofunVisibleBinding *visible,
    size_t visible_count
) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    KofunVisibleConfusableDiagnostic *diagnostics = NULL;
    KofunVisibleConfusableResult result;
    size_t diagnostic_index;
    if (visible_count != 0u) {
        diagnostics = calloc(visible_count, sizeof(*diagnostics));
        if (diagnostics == NULL) {
            set_error(program, "EUNICODE007",
                "visible-set diagnostic allocation failed in `%s`",
                program->modules[module_index].logical_path);
            return false;
        }
    }
    result = kofun_check_visible_confusables(visible, visible_count,
        diagnostics, visible_count);
    memcpy(resolver->visible_confusable_cache_keys[module_index],
        result.cache_key, 32u);
    if (result.status == KOFUN_VISIBLE_CONFUSABLE_OK) {
        free(diagnostics);
        return true;
    }
    if (visible_count == 0u) {
        free(diagnostics);
        set_error(program, "E2S75",
            "empty visible-set confusable check failed in `%s`: %s",
            program->modules[module_index].logical_path,
            kofun_visible_confusable_status_name(result.status));
        return false;
    }
    if (result.status != KOFUN_VISIBLE_CONFUSABLE_COLLISION) {
        free(diagnostics);
        set_error(program,
            result.status == KOFUN_VISIBLE_CONFUSABLE_RESOURCE_FAILURE
                ? "EUNICODE007" : "E2S75",
            "visible-set confusable check failed in `%s`: %s",
            program->modules[module_index].logical_path,
            kofun_visible_confusable_status_name(result.status));
        return false;
    }
    {
        TextBuffer text = {NULL, 0u, 0u};
        for (diagnostic_index = 0u;
             diagnostic_index < result.diagnostic_count;
             diagnostic_index += 1u) {
            KofunVisibleConfusableDiagnostic *diagnostic =
                &diagnostics[diagnostic_index];
            KofunVisibleBinding *primary =
                &visible[diagnostic->primary_binding];
            size_t related_index;
            if (diagnostic_index != 0u) {
                append_text(qualified, &text, "\n");
            }
            append_text(qualified, &text,
                "error[EUNICODE008]: effective spelling `%.*s` in `%s` at bytes %u..%u is confusable in one visible namespace",
                (int)primary->effective_spelling_length,
                (const char *)primary->effective_spelling,
                primary->canonical_provenance,
                primary->span_start, primary->span_end);
            for (related_index = 0u;
                 related_index < diagnostic->related_count;
                 related_index += 1u) {
                KofunVisibleBinding *related =
                    &visible[diagnostic->related_bindings[related_index]];
                if (related->disclose_location) {
                    append_text(qualified, &text,
                        "; related `%.*s` at `%s` bytes %u..%u",
                        (int)related->effective_spelling_length,
                        (const char *)related->effective_spelling,
                        related->canonical_provenance,
                        related->span_start, related->span_end);
                } else {
                    append_text(qualified, &text,
                        "; related `%.*s` has a disclosure-safe export identity; location withheld",
                        (int)related->effective_spelling_length,
                        (const char *)related->effective_spelling);
                }
            }
            if (diagnostic->related_omitted != 0u) {
                append_text(qualified, &text, "; %zu additional spellings omitted",
                    diagnostic->related_omitted);
            }
        }
        free(diagnostics);
        if (program->failed) {
            free(text.bytes);
            return false;
        }
        set_error(program, "EUNICODE008", "visible-set collision");
        free(qualified->expanded_error);
        qualified->expanded_error = text.bytes;
    }
    return false;
}

static bool check_selective_visible_confusables(SelectiveResolver *resolver) {
    Program *program = &resolver->qualified.program;
    size_t capacity = program->declaration_count +
        resolver->qualified.import_count + resolver->binding_count;
    KofunVisibleBinding *visible = NULL;
    size_t module_index;
    if (capacity != 0u) {
        visible = calloc(capacity, sizeof(*visible));
        if (visible == NULL) {
            set_error(program, "EUNICODE007",
                "visible-binding vector allocation failed");
            return false;
        }
    }
    for (module_index = 0u; module_index < program->module_count;
         module_index += 1u) {
        size_t count = 0u;
        if (!collect_selective_visible_bindings(resolver, module_index,
                visible, capacity, &count) ||
            !check_visible_binding_vector(resolver, module_index,
                visible, count)) {
            free(visible);
            return false;
        }
    }
    resolver->visible_confusables_checked = true;
    free(visible);
    return true;
}

static size_t selective_backend_target(
    void *context,
    size_t caller_index,
    size_t expression_start
) {
    SelectiveResolver *resolver = context;
    size_t index;
    for (index = 0u; index < resolver->use_count; index += 1u) {
        if (resolver->uses[index].caller_index == caller_index &&
            resolver->uses[index].expression_start == expression_start) {
            return resolver->uses[index].target_index;
        }
    }
    return SIZE_MAX;
}

static int compare_selective_declaration_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    const SelectiveDeclaration *da = &selective_comparison_resolver->selectives[a];
    const SelectiveDeclaration *db = &selective_comparison_resolver->selectives[b];
    const Program *program = &selective_comparison_resolver->qualified.program;
    int result = memcmp(program->modules[da->importer_index].module_id,
        program->modules[db->importer_index].module_id, 32u);
    if (result != 0) return result;
    if (da->whole_start != db->whole_start) return da->whole_start < db->whole_start ? -1 : 1;
    return a < b ? -1 : a != b;
}

static int compare_selective_binding_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    int result = memcmp(selective_comparison_resolver->bindings[a].binding_id,
        selective_comparison_resolver->bindings[b].binding_id, 32u);
    if (result != 0) return result;
    return a < b ? -1 : a != b;
}

static int compare_selective_use_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    const SelectiveUse *ua = &selective_comparison_resolver->uses[a];
    const SelectiveUse *ub = &selective_comparison_resolver->uses[b];
    const Program *program = &selective_comparison_resolver->qualified.program;
    int result = memcmp(program->declarations[ua->caller_index].symbol_id,
        program->declarations[ub->caller_index].symbol_id, 32u);
    if (result != 0) return result;
    if (ua->expression_start != ub->expression_start) {
        return ua->expression_start < ub->expression_start ? -1 : 1;
    }
    return a < b ? -1 : a != b;
}

static int compare_type_use_output(const void *left, const void *right) {
    size_t a = *(const size_t *)left;
    size_t b = *(const size_t *)right;
    const SelectiveTypeUse *ua = &selective_comparison_resolver->type_uses[a];
    const SelectiveTypeUse *ub = &selective_comparison_resolver->type_uses[b];
    const Program *program = &selective_comparison_resolver->qualified.program;
    int result = memcmp(program->declarations[ua->owner_index].symbol_id,
        program->declarations[ub->owner_index].symbol_id, 32u);
    if (result != 0) return result;
    if (ua->start != ub->start) return ua->start < ub->start ? -1 : 1;
    return a < b ? -1 : a != b;
}

static size_t adt_constructor_count(const Program *program, size_t adt_index) {
    size_t index;
    size_t count = 0u;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        const Declaration *declaration = &program->declarations[index];
        if (declaration->kind == DECLARATION_CONSTRUCTOR && declaration->has_owner &&
            declaration->owner_index == adt_index) count += 1u;
    }
    return count;
}

static bool emit_selective_hir(SelectiveResolver *resolver, const char *path) {
    ImportResolver *qualified = &resolver->qualified;
    Program *program = &qualified->program;
    size_t *declaration_order = NULL;
    size_t *binding_order = NULL;
    size_t *use_order = NULL;
    size_t *type_order = NULL;
    size_t *qualified_import_order = NULL;
    size_t qualified_import_count = 0u;
    FILE *output;
    char package_hex[65];
    size_t index;
    if (resolver->selective_count != 0u) declaration_order = malloc(resolver->selective_count * sizeof(*declaration_order));
    if (resolver->binding_count != 0u) binding_order = malloc(resolver->binding_count * sizeof(*binding_order));
    if (resolver->use_count != 0u) use_order = malloc(resolver->use_count * sizeof(*use_order));
    if (resolver->type_use_count != 0u) type_order = malloc(resolver->type_use_count * sizeof(*type_order));
    if (qualified->import_count != 0u) qualified_import_order = malloc(qualified->import_count * sizeof(*qualified_import_order));
    if ((resolver->selective_count != 0u && declaration_order == NULL) ||
        (resolver->binding_count != 0u && binding_order == NULL) ||
        (resolver->use_count != 0u && use_order == NULL) ||
        (resolver->type_use_count != 0u && type_order == NULL) ||
        (qualified->import_count != 0u && qualified_import_order == NULL)) {
        free(declaration_order);
        free(binding_order);
        free(use_order);
        free(type_order);
        free(qualified_import_order);
        set_error(program, "E2S78", "selective HIR ordering allocation failed");
        return false;
    }
    for (index = 0u; index < resolver->selective_count; index += 1u) declaration_order[index] = index;
    for (index = 0u; index < resolver->binding_count; index += 1u) binding_order[index] = index;
    for (index = 0u; index < resolver->use_count; index += 1u) use_order[index] = index;
    for (index = 0u; index < resolver->type_use_count; index += 1u) type_order[index] = index;
    for (index = 0u; index < qualified->import_count; index += 1u) {
        if (qualified->imports[index].form_tag == IMPORT_FORM_QUALIFIED) {
            qualified_import_order[qualified_import_count++] = index;
        }
    }
    selective_comparison_resolver = resolver;
    comparison_resolver = qualified;
    if (resolver->selective_count > 1u) qsort(declaration_order, resolver->selective_count,
        sizeof(*declaration_order), compare_selective_declaration_output);
    if (resolver->binding_count > 1u) qsort(binding_order, resolver->binding_count,
        sizeof(*binding_order), compare_selective_binding_output);
    if (resolver->use_count > 1u) qsort(use_order, resolver->use_count,
        sizeof(*use_order), compare_selective_use_output);
    if (resolver->type_use_count > 1u) qsort(type_order, resolver->type_use_count,
        sizeof(*type_order), compare_type_use_output);
    if (qualified_import_count > 1u) qsort(qualified_import_order, qualified_import_count,
        sizeof(*qualified_import_order), compare_import_output);
    output = fopen(path, "wb");
    if (output == NULL) {
        free(declaration_order);
        free(binding_order);
        free(use_order);
        free(type_order);
        free(qualified_import_order);
        set_error(program, "E2S77", "cannot create selective-import HIR");
        return false;
    }
    bytes_to_hex(program->modules[0].package_id, 32u, package_hex);
    fprintf(output, "kofun-imports-selective/v1\npackage|id=%s\n", package_hex);
    for (index = 0u; index < program->module_count; index += 1u) {
        char module_hex[65];
        char file_hex[65];
        bytes_to_hex(program->modules[index].module_id, 32u, module_hex);
        bytes_to_hex(program->modules[index].file_id, 32u, file_hex);
        fprintf(output, "module|id=%s|file=%s|declared=%s|path=%s\n",
            module_hex, file_hex, qualified->modules[index].declared_path,
            program->modules[index].logical_path);
    }
    for (index = 0u; index < qualified_import_count; index += 1u) {
        ImportBinding *binding = &qualified->imports[qualified_import_order[index]];
        char binding_hex[65];
        char importer_hex[65];
        char target_hex[65];
        size_t component;
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[binding->importer_index].module_id, 32u, importer_hex);
        bytes_to_hex(program->modules[binding->target_index].module_id, 32u, target_hex);
        fprintf(output,
            "qualified-import|binding=%s|importer=%s|local=%s|target=%s|span=%zu..%zu|components=",
            binding_hex, importer_hex, binding->qualifier, target_hex,
            binding->start, binding->end);
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
    for (index = 0u; index < resolver->selective_count; index += 1u) {
        SelectiveDeclaration *selective = &resolver->selectives[declaration_order[index]];
        ImportBinding *dependency = &qualified->imports[selective->dependency_index];
        char importer_hex[65];
        char target_hex[65];
        size_t component;
        size_t name_index;
        bytes_to_hex(program->modules[selective->importer_index].module_id, 32u, importer_hex);
        bytes_to_hex(program->modules[dependency->target_index].module_id, 32u, target_hex);
        fprintf(output,
            "selective-decl|importer=%s|target=%s|module=%s|from-span=%zu..%zu|path-span=%zu..%zu|components=",
            importer_hex, target_hex, dependency->path,
            selective->from_start, selective->from_end,
            selective->path_start, selective->path_end);
        for (component = 0u; component < dependency->component_count; component += 1u) {
            if (component != 0u) fputc(',', output);
            fprintf(output, "%zu..%zu", dependency->components[component].start,
                dependency->components[component].end);
        }
        fprintf(output, "|import-span=%zu..%zu|names=",
            selective->import_start, selective->import_end);
        for (name_index = 0u; name_index < selective->name_count; name_index += 1u) {
            SelectiveName *name = &selective->names[name_index];
            if (name_index != 0u) fputc(';', output);
            fprintf(output, "%s@%zu..%zu#comma=", name->spelling, name->start, name->end);
            if (name->has_comma) fprintf(output, "%zu..%zu", name->comma_start, name->comma_end);
            else fputc('-', output);
        }
        fprintf(output, "|whole-span=%zu..%zu|reexport=false\n",
            selective->whole_start, selective->whole_end);
    }
    for (index = 0u; index < resolver->binding_count; index += 1u) {
        SelectiveBinding *binding = &resolver->bindings[binding_order[index]];
        SelectiveDeclaration *selective = &resolver->selectives[binding->declaration_index];
        SelectiveName *name = &selective->names[binding->name_index];
        Declaration *target = &program->declarations[binding->target_index];
        char binding_hex[65];
        char importer_hex[65];
        char file_hex[65];
        char namespace_hex[65];
        char target_module_hex[65];
        char symbol_hex[65];
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[selective->importer_index].module_id, 32u, importer_hex);
        bytes_to_hex(program->modules[selective->importer_index].file_id, 32u, file_hex);
        bytes_to_hex(target->namespace_id, 32u, namespace_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, target_module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "requested-binding|binding=%s|importer=%s|file=%s|namespace=%s|namespace-name=%s|local=%s|target-module=%s|target-symbol=%s|target-kind=%s|visibility=%s|form=selective-name-v1|name-span=%zu..%zu|whole-span=%zu..%zu|access=%s|reason=%s|proof=%u|reexport=false",
            binding_hex, importer_hex, file_hex, namespace_hex,
            namespace_name(binding->namespace_tag), name->spelling,
            target_module_hex, symbol_hex, kind_name(target->kind),
            visibility_name(target->visibility), name->start, name->end,
            selective->whole_start, selective->whole_end,
            kofun_access_kind_name(binding->access.kind),
            kofun_access_reason_name(binding->access.reason), binding->access.proof);
        if (target->kind == DECLARATION_FUNCTION) {
            fprintf(output, "|shape=fn(%zu)->token-types\n", function_arity(program, target));
        } else {
            fprintf(output, "|shape=nominal-adt(%zu-constructors)\n",
                adt_constructor_count(program, binding->target_index));
        }
    }
    for (index = 0u; index < resolver->use_count; index += 1u) {
        SelectiveUse *use = &resolver->uses[use_order[index]];
        SelectiveBinding *binding = &resolver->bindings[use->binding_index];
        Declaration *caller = &program->declarations[use->caller_index];
        Declaration *target = &program->declarations[use->target_index];
        char caller_hex[65];
        char binding_hex[65];
        char target_module_hex[65];
        char symbol_hex[65];
        bytes_to_hex(caller->symbol_id, 32u, caller_hex);
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, target_module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "selective-call|caller=%s|binding=%s|target-module=%s|target-symbol=%s|name=%s|name-span=%zu..%zu|expression-span=%zu..%zu|signature=fn(%zu:Int)->Int\n",
            caller_hex, binding_hex, target_module_hex, symbol_hex, target->name,
            use->name_start, use->name_end, use->expression_start,
            use->expression_end, use->arity);
    }
    for (index = 0u; index < resolver->type_use_count; index += 1u) {
        SelectiveTypeUse *use = &resolver->type_uses[type_order[index]];
        SelectiveBinding *binding = &resolver->bindings[use->binding_index];
        Declaration *owner = &program->declarations[use->owner_index];
        Declaration *target = &program->declarations[use->target_index];
        char owner_hex[65];
        char binding_hex[65];
        char target_module_hex[65];
        char symbol_hex[65];
        bytes_to_hex(owner->symbol_id, 32u, owner_hex);
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, target_module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "type-reference|owner=%s|binding=%s|target-module=%s|target-symbol=%s|name=%s|role=%s|span=%zu..%zu|shape=nominal\n",
            owner_hex, binding_hex, target_module_hex, symbol_hex, target->name,
            use->role == TYPE_REFERENCE_PARAMETER ? "parameter" : "return",
            use->start, use->end);
    }
    for (index = 0u; index < qualified->use_count; index += 1u) {
        QualifiedUse *use = &qualified->uses[index];
        Declaration *caller = &program->declarations[use->caller_index];
        Declaration *target = &program->declarations[use->target_index];
        char caller_hex[65];
        char binding_hex[65];
        char target_module_hex[65];
        char symbol_hex[65];
        bytes_to_hex(caller->symbol_id, 32u, caller_hex);
        bytes_to_hex(qualified->imports[use->binding_index].binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, target_module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "qualified-call|caller=%s|binding=%s",
            caller_hex, binding_hex);
        if (qualified->imports[use->binding_index].has_alias) {
            char alias_binding_hex[65];
            bytes_to_hex(qualified->imports[use->binding_index].alias_binding_id,
                32u, alias_binding_hex);
            fprintf(output, "|alias-binding=%s", alias_binding_hex);
        }
        fprintf(output,
            "|target-module=%s|target-symbol=%s|name=%s|expression-span=%zu..%zu\n",
            target_module_hex, symbol_hex, target->name,
            use->expression_start, use->expression_end);
    }
    for (index = 0u; index < resolver->binding_count; index += 1u) {
        SelectiveBinding *binding = &resolver->bindings[binding_order[index]];
        SelectiveDeclaration *selective = &resolver->selectives[binding->declaration_index];
        Declaration *target = &program->declarations[binding->target_index];
        char binding_hex[65];
        char importer_hex[65];
        char target_module_hex[65];
        char symbol_hex[65];
        if (!binding->referenced) continue;
        bytes_to_hex(binding->binding_id, 32u, binding_hex);
        bytes_to_hex(program->modules[selective->importer_index].module_id, 32u, importer_hex);
        bytes_to_hex(program->modules[target->module_index].module_id, 32u, target_module_hex);
        bytes_to_hex(target->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "dependency|importer=%s|binding=%s|target-module=%s|target-symbol=%s|namespace=%s|interface=%s|reexport=false\n",
            importer_hex, binding_hex, target_module_hex, symbol_hex,
            namespace_name(binding->namespace_tag),
            binding->interface_reference ? "yes" : "no");
    }
    free(declaration_order);
    free(binding_order);
    free(use_order);
    free(type_order);
    free(qualified_import_order);
    if (ferror(output) || fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S77", "cannot commit selective-import HIR");
        return false;
    }
    return true;
}

static void destroy_selective_resolver(SelectiveResolver *resolver) {
    size_t index;
    for (index = 0u; index < resolver->selective_count; index += 1u) {
        free(resolver->selectives[index].names);
    }
    free(resolver->selectives);
    free(resolver->bindings);
    free(resolver->uses);
    free(resolver->type_uses);
    destroy_resolver(&resolver->qualified);
}

static char *artifact_side_path(
    Program *program,
    const char *path,
    const char *role
) {
    size_t length = strlen(path);
    size_t role_length = strlen(role);
    char pid_text[32];
    int pid_length = snprintf(pid_text, sizeof(pid_text), "%ld", (long)getpid());
    char *result;
    if (pid_length < 0 || (size_t)pid_length >= sizeof(pid_text) ||
        length > SIZE_MAX - role_length - (size_t)pid_length - 4u) {
        set_error(program, "E2S78", "artifact side-path length overflow");
        return NULL;
    }
    result = malloc(length + role_length + (size_t)pid_length + 4u);
    if (result == NULL) {
        set_error(program, "E2S78", "artifact side-path allocation failed");
        return NULL;
    }
    snprintf(result, length + role_length + (size_t)pid_length + 4u,
        "%s.%s.%s", path, role, pid_text);
    return result;
}

static bool prepare_output_artifact(
    Program *program,
    OutputArtifact *artifact,
    const char *path
) {
    int descriptor;
    memset(artifact, 0, sizeof(*artifact));
    artifact->final_path = path;
    artifact->temporary_path = artifact_side_path(program, path, "selective-tmp");
    artifact->backup_path = artifact_side_path(program, path, "selective-backup");
    if (artifact->temporary_path == NULL || artifact->backup_path == NULL) return false;
    descriptor = open(artifact->temporary_path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (descriptor < 0) {
        set_error(program, "E2S77", "cannot reserve artifact transaction temporary path");
        return false;
    }
    if (close(descriptor) != 0) {
        remove(artifact->temporary_path);
        set_error(program, "E2S77", "cannot close artifact transaction temporary reservation");
        return false;
    }
    descriptor = open(artifact->backup_path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (descriptor < 0) {
        remove(artifact->temporary_path);
        set_error(program, "E2S77", "cannot reserve artifact transaction backup path");
        return false;
    }
    if (close(descriptor) != 0) {
        remove(artifact->temporary_path);
        remove(artifact->backup_path);
        set_error(program, "E2S77", "cannot close artifact transaction backup reservation");
        return false;
    }
    return true;
}

static void release_output_artifact(OutputArtifact *artifact) {
    if (artifact->temporary_path != NULL) remove(artifact->temporary_path);
    if (artifact->backup_path != NULL) remove(artifact->backup_path);
    free(artifact->temporary_path);
    free(artifact->backup_path);
    memset(artifact, 0, sizeof(*artifact));
}

static bool reject_artifact_alias(
    Program *program,
    const char *left,
    const char *right,
    const char *description
) {
    struct stat left_stat;
    struct stat right_stat;
    int left_status;
    int left_error;
    int right_status;
    int right_error;
    if (strcmp(left, right) == 0) {
        set_error(program, "E2S77", "%s must use distinct paths", description);
        return false;
    }
    errno = 0;
    left_status = stat(left, &left_stat);
    left_error = errno;
    errno = 0;
    right_status = stat(right, &right_stat);
    right_error = errno;
    if ((left_status != 0 && left_error != ENOENT) ||
        (right_status != 0 && right_error != ENOENT)) {
        set_error(program, "E2S77", "cannot validate %s path identities", description);
        return false;
    }
    if (left_status == 0 && right_status == 0 &&
        left_stat.st_dev == right_stat.st_dev && left_stat.st_ino == right_stat.st_ino) {
        set_error(program, "E2S77", "%s must not alias the same file", description);
        return false;
    }
    return true;
}

static bool clear_requested_output(Program *program, const char *path) {
    errno = 0;
    if (remove(path) == 0 || errno == ENOENT) return true;
    set_error(program, "E2S77", "cannot clear requested output `%s` before the transaction", path);
    return false;
}

static bool validate_transaction_paths(
    Program *program,
    const char *inventory_path,
    OutputArtifact *artifacts,
    size_t count
) {
    const char *paths[10];
    size_t path_count = 1u;
    size_t index;
    size_t other;
    paths[0] = inventory_path;
    if (count > 3u) {
        set_error(program, "E2S77",
            "artifact transaction exceeds three outputs");
        return false;
    }
    for (index = 0u; index < count; index += 1u) {
        paths[path_count++] = artifacts[index].final_path;
        paths[path_count++] = artifacts[index].temporary_path;
        paths[path_count++] = artifacts[index].backup_path;
    }
    for (index = 0u; index < path_count; index += 1u) {
        for (other = index + 1u; other < path_count; other += 1u) {
            if (!reject_artifact_alias(program, paths[index], paths[other],
                    "inventory/final/transaction paths")) return false;
        }
    }
    return true;
}

static bool commit_output_artifacts(
    Program *program,
    OutputArtifact *artifacts,
    size_t count
) {
    size_t index;
    for (index = 0u; index < count; index += 1u) {
        if (access(artifacts[index].final_path, F_OK) == 0) {
            if (remove(artifacts[index].backup_path) != 0) goto failed;
            if (rename(artifacts[index].final_path, artifacts[index].backup_path) != 0) goto failed;
            artifacts[index].had_original = true;
        } else if (errno != ENOENT) {
            goto failed;
        }
    }
    for (index = 0u; index < count; index += 1u) {
        if (rename(artifacts[index].temporary_path, artifacts[index].final_path) != 0) goto failed;
        artifacts[index].installed = true;
    }
    for (index = 0u; index < count; index += 1u) {
        (void)remove(artifacts[index].backup_path);
    }
    return true;
failed:
    for (index = 0u; index < count; index += 1u) {
        if (artifacts[index].installed) remove(artifacts[index].final_path);
    }
    for (index = 0u; index < count; index += 1u) {
        if (artifacts[index].had_original) {
            (void)rename(artifacts[index].backup_path, artifacts[index].final_path);
        }
        remove(artifacts[index].temporary_path);
    }
    set_error(program, "E2S77",
        "cannot atomically commit selective-import artifacts; prior outputs were preserved when recoverable");
    return false;
}

#ifndef KOFUN_IMPORTS_SELECTIVE_NO_MAIN
int main(int argc, char **argv) {
    SelectiveResolver resolver;
    ImportResolver *qualified = &resolver.qualified;
    Program *program = &qualified->program;
    OutputArtifact artifacts[2];
    size_t artifact_count = argc == 4 ? 2u : 1u;
    size_t index;
    int status = 1;
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "usage: %s INVENTORY OUTPUT_HIR [OUTPUT_REFERENCE_C]\n", argv[0]);
        return 2;
    }
    memset(&resolver, 0, sizeof(resolver));
    memset(artifacts, 0, sizeof(artifacts));
    qualified->extension_context = &resolver;
    qualified->find_unqualified_target = selective_backend_target;
    if (!reject_artifact_alias(program, argv[1], argv[2], "inventory and HIR output")) goto done;
    if (argc == 4 &&
        (!reject_artifact_alias(program, argv[1], argv[3], "inventory and reference C output") ||
         !reject_artifact_alias(program, argv[2], argv[3], "HIR and reference C outputs"))) goto done;
    if (!clear_requested_output(program, argv[2]) ||
        (argc == 4 && !clear_requested_output(program, argv[3]))) goto done;
    if (!prepare_output_artifact(program, &artifacts[0], argv[2])) goto done;
    if (argc == 4 && !prepare_output_artifact(program, &artifacts[1], argv[3])) goto done;
    if (!validate_transaction_paths(program, argv[1], artifacts, artifact_count)) goto done;
    if (!load_qualified_inventory(qualified, argv[1]) ||
        !order_and_validate_inventory(program) || !attach_declared_paths(qualified)) goto done;
    for (index = 0u; index < program->module_count; index += 1u) {
        if (!collect_module_with_selective_imports(&resolver, index)) goto done;
    }
    compute_identities(program);
    if (!validate_duplicates(program) || !resolve_imports(qualified)) goto done;
    canonicalize_import_graph_edges(&resolver);
    if (!validate_import_cycles(qualified) || !resolve_selective_bindings(&resolver) ||
        !resolve_qualified_calls_for_selective(&resolver) ||
        !resolve_selective_value_uses(&resolver) ||
        !resolve_selective_type_uses(&resolver) ||
        !check_selective_visible_confusables(&resolver) ||
        (argc == 4 && !emit_reference_c(qualified, artifacts[1].temporary_path)) ||
        !emit_selective_hir(&resolver, artifacts[0].temporary_path) ||
        !commit_output_artifacts(program, artifacts, artifact_count)) goto done;
    status = 0;
done:
    if (program->failed) {
        printf("%s\n", qualified->expanded_error != NULL ? qualified->expanded_error : program->error);
    }
    release_output_artifact(&artifacts[0]);
    release_output_artifact(&artifacts[1]);
    destroy_selective_resolver(&resolver);
    return status;
}
#endif
