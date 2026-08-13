#define _POSIX_C_SOURCE 200809L

#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
#define KOFUN_IMPORTS_SELECTIVE_NO_MAIN
#include "imports_selective.c"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#include "kif_v1.h"

#define RE_EXPORT_DECLARATIONS_PER_MODULE_LIMIT 256u
#define RE_EXPORT_BINDINGS_PER_MODULE_LIMIT 1024u
#define RE_EXPORT_BINDING_LIMIT 65536u
#define RE_EXPORT_CHAIN_LIMIT 64u
#define RE_EXPORT_LOOKUP_CAPACITY 131072u
#ifndef RE_EXPORT_GRAPH_WORK_LIMIT
#define RE_EXPORT_GRAPH_WORK_LIMIT UINT64_C(20000000)
#endif

typedef enum {
    RE_EXPORT_QUALIFIED,
    RE_EXPORT_SELECTIVE
} ReExportForm;

typedef struct {
    ReExportForm form;
    size_t exporter_index;
    size_t dependency_index;
    size_t selective_index;
    size_t pub_start;
    size_t pub_end;
    size_t whole_start;
    size_t whole_end;
} ReExportDeclaration;

typedef struct {
    size_t declaration_index;
    size_t selective_name_index;
    uint8_t resolved_namespaces;
    bool has_forwarded_export;
    bool resolved;
} ReExportRequest;

typedef struct {
    size_t declaration_index;
    size_t target_module_index;
    size_t target_declaration_index;
    unsigned namespace_tag;
    KofunKifExportTargetKind target_kind;
    char name[IDENTIFIER_LIMIT + 1u];
    uint8_t source_import_binding_id[32];
    uint8_t export_binding_id[32];
    uint8_t target_symbol_id[32];
    uint8_t chain_ids[RE_EXPORT_CHAIN_LIMIT][32];
    size_t chain_count;
    uint16_t parameter_count;
    KofunKifParameterLabel *parameter_labels;
    uint8_t constructor_payload_count;
    uint8_t target_owner_symbol_id[32];
    uint32_t target_constructor_ordinal;
    uint32_t access_proof;
    size_t import_span_start;
    size_t import_span_end;
    size_t name_span_start;
    size_t name_span_end;
} ResolvedExport;

typedef struct {
    bool occupied;
    size_t exporter_index;
    unsigned namespace_tag;
    size_t export_index;
} ReExportLookupEntry;

typedef struct {
    SelectiveResolver imports;
    ReExportDeclaration *declarations;
    size_t declaration_count;
    size_t declaration_capacity;
    size_t module_declaration_counts[MODULE_LIMIT];
    ReExportRequest *requests;
    size_t request_count;
    size_t request_capacity;
    ResolvedExport *exports;
    size_t export_count;
    size_t export_capacity;
    size_t module_export_counts[MODULE_LIMIT];
    ReExportLookupEntry *export_lookup;
    uint64_t graph_work;
} ReExportResolver;

static ReExportResolver *re_export_comparison_resolver;

static bool re_export_step(
    ReExportResolver *resolver,
    size_t span_start,
    size_t span_end
) {
    resolver->graph_work += 1u;
    if (resolver->graph_work <= RE_EXPORT_GRAPH_WORK_LIMIT) return true;
    set_error(&resolver->imports.qualified.program, "E2S90",
        "re-export graph exceeds %llu operations at bytes %zu..%zu; hint: split the package or shorten facade chains",
        (unsigned long long)RE_EXPORT_GRAPH_WORK_LIMIT,
        span_start, span_end);
    return false;
}

static void replace_error_code(Program *program, const char *from, const char *to) {
    char *where;
    if (!program->failed || strlen(from) != strlen(to)) return;
    where = strstr(program->error, from);
    if (where != NULL) memcpy(where, to, strlen(to));
}

static void remap_public_import_error(Program *program) {
    replace_error_code(program, "E2S59", "E2S85");
    replace_error_code(program, "E2S60", "E2S86");
    replace_error_code(program, "E2S61", "E2S89");
    replace_error_code(program, "E2S62", "E2S88");
    replace_error_code(program, "E2S63", "E2S88");
    replace_error_code(program, "E2S69", "E2S85");
    replace_error_code(program, "E2S70", "E2S88");
    replace_error_code(program, "E2S71", "E2S86");
    replace_error_code(program, "E2S72", "E2S87");
    replace_error_code(program, "E2S73", "E2S88");
    replace_error_code(program, "E2S74", "E2S86");
    replace_error_code(program, "E2S77", "E2S92");
    replace_error_code(program, "E2S78", "E2S94");
}

static bool reserve_re_export_declaration(
    ReExportResolver *resolver,
    size_t module_index,
    size_t span_start,
    size_t span_end
) {
    ReExportDeclaration *resized;
    Program *program = &resolver->imports.qualified.program;
    if (resolver->module_declaration_counts[module_index] >=
            RE_EXPORT_DECLARATIONS_PER_MODULE_LIMIT) {
        set_error(program, "E2S90",
            "module `%s` exceeds %u re-export declarations at bytes %zu..%zu; hint: split the facade",
            program->modules[module_index].logical_path,
            RE_EXPORT_DECLARATIONS_PER_MODULE_LIMIT,
            span_start, span_end);
        return false;
    }
    if (resolver->declaration_count < resolver->declaration_capacity) return true;
    {
        size_t capacity = resolver->declaration_capacity == 0u
            ? 64u : resolver->declaration_capacity * 2u;
        if (capacity > RE_EXPORT_BINDING_LIMIT) capacity = RE_EXPORT_BINDING_LIMIT;
        resized = realloc(resolver->declarations, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S94", "re-export declaration allocation failed");
            return false;
        }
        resolver->declarations = resized;
        resolver->declaration_capacity = capacity;
    }
    return true;
}

static bool reserve_re_export_request(
    ReExportResolver *resolver,
    size_t span_start,
    size_t span_end
) {
    ReExportRequest *resized;
    Program *program = &resolver->imports.qualified.program;
    if (resolver->request_count >= RE_EXPORT_BINDING_LIMIT) {
        set_error(program, "E2S90",
            "package exceeds %u re-export requests at bytes %zu..%zu; hint: split the package",
            RE_EXPORT_BINDING_LIMIT, span_start, span_end);
        return false;
    }
    if (resolver->request_count < resolver->request_capacity) return true;
    {
        size_t capacity = resolver->request_capacity == 0u
            ? 128u : resolver->request_capacity * 2u;
        if (capacity > RE_EXPORT_BINDING_LIMIT) capacity = RE_EXPORT_BINDING_LIMIT;
        resized = realloc(resolver->requests, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S94", "re-export request allocation failed");
            return false;
        }
        resolver->requests = resized;
        resolver->request_capacity = capacity;
    }
    return true;
}

static bool reserve_resolved_export(
    ReExportResolver *resolver,
    size_t module_index,
    size_t span_start,
    size_t span_end
) {
    ResolvedExport *resized;
    Program *program = &resolver->imports.qualified.program;
    if (resolver->export_count >= RE_EXPORT_BINDING_LIMIT) {
        set_error(program, "E2S90",
            "package exceeds %u expanded re-export bindings at bytes %zu..%zu; hint: split the package",
            RE_EXPORT_BINDING_LIMIT, span_start, span_end);
        return false;
    }
    if (resolver->module_export_counts[module_index] >=
            RE_EXPORT_BINDINGS_PER_MODULE_LIMIT) {
        set_error(program, "E2S90",
            "module `%s` exceeds %u expanded re-export bindings at bytes %zu..%zu; hint: export fewer names",
            program->modules[module_index].logical_path,
            RE_EXPORT_BINDINGS_PER_MODULE_LIMIT,
            span_start, span_end);
        return false;
    }
    if (resolver->export_count < resolver->export_capacity) return true;
    {
        size_t capacity = resolver->export_capacity == 0u
            ? 128u : resolver->export_capacity * 2u;
        if (capacity > RE_EXPORT_BINDING_LIMIT) capacity = RE_EXPORT_BINDING_LIMIT;
        resized = realloc(resolver->exports, capacity * sizeof(*resized));
        if (resized == NULL) {
            set_error(program, "E2S94", "resolved export allocation failed");
            return false;
        }
        resolver->exports = resized;
        resolver->export_capacity = capacity;
    }
    return true;
}

static bool parse_public_import(
    ReExportResolver *resolver,
    size_t module_index,
    size_t *cursor
) {
    SelectiveResolver *imports = &resolver->imports;
    ImportResolver *qualified = &imports->qualified;
    Program *program = &qualified->program;
    Module *module = &program->modules[module_index];
    ReExportDeclaration *declaration;
    size_t declaration_index;
    size_t dependency_index;
    size_t selective_index = SIZE_MAX;
    size_t pub_start = module->tokens[*cursor].start;
    size_t pub_end = module->tokens[*cursor].end;
    size_t current = *cursor + 1u;
    if (current >= module->token_count ||
        module->tokens[current].line_break_before) {
        set_error(program, "E2S85",
            "misplaced `pub` in `%s` at bytes %zu..%zu; hint: place `pub` immediately before `import` or `from`",
            module->logical_path, pub_start, pub_end);
        return false;
    }
    if (!token_equals(module, &module->tokens[current], "import") &&
        !token_equals(module, &module->tokens[current], "from")) {
        set_error(program, "E2S85",
            "unsupported re-export modifier in `%s` at bytes %zu..%zu; hint: use `pub import a.b` or `pub from a.b import Name`",
            module->logical_path, pub_start, module->tokens[current].end);
        return false;
    }
    if (!reserve_re_export_declaration(resolver, module_index,
            pub_start, pub_end)) return false;
    declaration_index = resolver->declaration_count++;
    declaration = &resolver->declarations[declaration_index];
    memset(declaration, 0, sizeof(*declaration));
    declaration->exporter_index = module_index;
    declaration->pub_start = pub_start;
    declaration->pub_end = pub_end;
    declaration->whole_start = pub_start;
    if (token_equals(module, &module->tokens[current], "import")) {
        declaration->form = RE_EXPORT_QUALIFIED;
        dependency_index = qualified->import_count;
        if (!parse_import(qualified, module_index, &current)) {
            remap_public_import_error(program);
            return false;
        }
        if (qualified->imports[dependency_index].has_alias) {
            set_error(program, "E2S85",
                "public module aliases are unsupported in `%s` at bytes %zu..%zu; hint: use `pub import a.b` without `as`",
                module->logical_path,
                qualified->imports[dependency_index].alias_start,
                qualified->imports[dependency_index].alias_end);
            return false;
        }
        declaration->whole_end = qualified->imports[dependency_index].end;
    } else {
        declaration->form = RE_EXPORT_SELECTIVE;
        selective_index = imports->selective_count;
        if (!parse_selective_import(imports, module_index, &current)) {
            remap_public_import_error(program);
            return false;
        }
        imports->selectives[selective_index].is_re_export = true;
        dependency_index = imports->selectives[selective_index].dependency_index;
        declaration->whole_end = imports->selectives[selective_index].whole_end;
        declaration->selective_index = selective_index;
    }
    declaration->dependency_index = dependency_index;
    resolver->module_declaration_counts[module_index] += 1u;
    *cursor = current;
    return true;
}

static bool collect_re_export_module(
    ReExportResolver *resolver,
    size_t module_index
) {
    SelectiveResolver *imports = &resolver->imports;
    ImportResolver *qualified = &imports->qualified;
    Program *program = &qualified->program;
    Module *module = &program->modules[module_index];
    size_t cursor;
    qualified->modules[module_index].first_import = qualified->import_count;
    if (!tokenize(program, module) ||
        !parse_and_check_header(qualified, module_index, &cursor)) return false;
    while (cursor < module->token_count) {
        if (token_equals(module, &module->tokens[cursor], "pub")) {
            size_t next = cursor + 1u;
            if (next < module->token_count &&
                !module->tokens[next].line_break_before &&
                (token_equals(module, &module->tokens[next], "import") ||
                 token_equals(module, &module->tokens[next], "from"))) {
                if (!parse_public_import(resolver, module_index, &cursor)) return false;
                continue;
            }
            break;
        }
        if (token_equals(module, &module->tokens[cursor], "import")) {
            if (qualified->modules[module_index].import_count >=
                    IMPORTS_PER_MODULE_LIMIT) {
                set_error(program, "E2S90",
                    "module `%s` exceeds %u import/re-export declarations at bytes %zu..%zu; hint: combine or remove imports",
                    module->logical_path, IMPORTS_PER_MODULE_LIMIT,
                    module->tokens[cursor].start,
                    module->tokens[cursor].end);
                return false;
            }
            if (!parse_import(qualified, module_index, &cursor)) return false;
            continue;
        }
        if (token_equals(module, &module->tokens[cursor], "from")) {
            if (!parse_selective_import(imports, module_index, &cursor)) return false;
            continue;
        }
        break;
    }
    while (cursor < module->token_count) {
        size_t declaration_start = module->tokens[cursor].start;
        Visibility visibility = VISIBILITY_IMPLICIT_PRIVATE;
        if (token_equals(module, &module->tokens[cursor], "import") ||
            token_equals(module, &module->tokens[cursor], "from") ||
            (token_equals(module, &module->tokens[cursor], "pub") &&
             cursor + 1u < module->token_count &&
             (token_equals(module, &module->tokens[cursor + 1u], "import") ||
              token_equals(module, &module->tokens[cursor + 1u], "from")))) {
            set_error(program, "E2S85",
                "re-exports/imports must precede declarations in `%s` at bytes %zu..%zu; hint: move the declaration into the header region",
                module->logical_path, module->tokens[cursor].start,
                module->tokens[cursor].end);
            return false;
        }
        if (token_equals(module, &module->tokens[cursor], "internal") ||
            token_equals(module, &module->tokens[cursor], "private")) {
            size_t modifier_start = module->tokens[cursor].start;
            size_t next = cursor + 1u;
            if (next < module->token_count &&
                (token_equals(module, &module->tokens[next], "import") ||
                 token_equals(module, &module->tokens[next], "from"))) {
                set_error(program, "E2S85",
                    "only public re-exports are supported in `%s` at bytes %zu..%zu; hint: use an ordinary import or `pub import`",
                    module->logical_path, modifier_start,
                    module->tokens[next].end);
                return false;
            }
        }
        if (token_equals(module, &module->tokens[cursor], "export")) {
            set_error(program, "E2S85",
                "`export` re-exports are unsupported in `%s` at bytes %zu..%zu; hint: use `pub import` or `pub from`",
                module->logical_path, module->tokens[cursor].start,
                module->tokens[cursor].end);
            return false;
        }
        if (token_equals(module, &module->tokens[cursor], "pub") ||
            token_equals(module, &module->tokens[cursor], "internal") ||
            token_equals(module, &module->tokens[cursor], "private")) {
            if (token_equals(module, &module->tokens[cursor], "pub")) {
                visibility = VISIBILITY_PUBLIC;
            } else if (token_equals(module, &module->tokens[cursor], "internal")) {
                visibility = VISIBILITY_INTERNAL;
            } else {
                visibility = VISIBILITY_PRIVATE;
            }
            cursor += 1u;
            if (cursor >= module->token_count) {
                set_error(program, "E2S50",
                    "visibility modifier without declaration in `%s`",
                    module->logical_path);
                return false;
            }
        }
        if (token_equals(module, &module->tokens[cursor], "fn")) {
            if (!parse_function(program, module_index, declaration_start,
                    visibility, &cursor)) return false;
        } else if (token_equals(module, &module->tokens[cursor], "type")) {
            if (!parse_adt(program, module_index, declaration_start,
                    visibility, &cursor)) return false;
        } else {
            set_error(program, "E2S85",
                "unsupported re-export/declaration form in `%s` at bytes %zu..%zu; hint: use the bounded header and declaration forms",
                module->logical_path, module->tokens[cursor].start,
                module->tokens[cursor].end);
            return false;
        }
    }
    return true;
}

static bool build_re_export_requests(ReExportResolver *resolver) {
    size_t declaration_index;
    for (declaration_index = 0u;
         declaration_index < resolver->declaration_count;
         declaration_index += 1u) {
        ReExportDeclaration *declaration =
            &resolver->declarations[declaration_index];
        if (declaration->form == RE_EXPORT_QUALIFIED) {
            if (!reserve_re_export_request(resolver,
                    declaration->whole_start,
                    declaration->whole_end)) return false;
            resolver->requests[resolver->request_count++] =
                (ReExportRequest){ .declaration_index = declaration_index };
        } else {
            SelectiveDeclaration *selective =
                &resolver->imports.selectives[declaration->selective_index];
            size_t name_index;
            for (name_index = 0u; name_index < selective->name_count;
                 name_index += 1u) {
                SelectiveName *name = &selective->names[name_index];
                if (!reserve_re_export_request(resolver,
                        name->start, name->end)) return false;
                resolver->requests[resolver->request_count++] =
                    (ReExportRequest){
                        .declaration_index = declaration_index,
                        .selective_name_index = name_index
                    };
            }
        }
    }
    return true;
}

static bool validate_ordinary_import_cycles(ReExportResolver *resolver) {
    ImportResolver *qualified = &resolver->imports.qualified;
    bool *original_duplicates = NULL;
    size_t import_index;
    size_t declaration_index;
    bool valid;
    if (qualified->import_count != 0u) {
        original_duplicates = malloc(
            qualified->import_count * sizeof(*original_duplicates));
        if (original_duplicates == NULL) {
            set_error(&qualified->program, "E2S94",
                "ordinary import-cycle filter allocation failed");
            return false;
        }
    }
    for (import_index = 0u; import_index < qualified->import_count;
         import_index += 1u) {
        original_duplicates[import_index] =
            qualified->imports[import_index].graph_duplicate;
    }
    for (declaration_index = 0u;
         declaration_index < resolver->declaration_count;
         declaration_index += 1u) {
        size_t dependency_index =
            resolver->declarations[declaration_index].dependency_index;
        if (dependency_index < qualified->import_count) {
            qualified->imports[dependency_index].graph_duplicate = true;
        }
    }
    valid = validate_import_cycles(qualified);
    for (import_index = 0u; import_index < qualified->import_count;
         import_index += 1u) {
        qualified->imports[import_index].graph_duplicate =
            original_duplicates[import_index];
    }
    free(original_duplicates);
    return valid;
}

static void add_self_re_export_secondary_span(ReExportResolver *resolver) {
    Program *program = &resolver->imports.qualified.program;
    size_t declaration_index;
    size_t length;
    if (strstr(program->error, "E2S61") == NULL) return;
    for (declaration_index = 0u;
         declaration_index < resolver->declaration_count;
         declaration_index += 1u) {
        ReExportDeclaration *declaration =
            &resolver->declarations[declaration_index];
        ImportBinding *dependency =
            &resolver->imports.qualified.imports[
                declaration->dependency_index];
        if (declaration->exporter_index != dependency->target_index) continue;
        length = strlen(program->error);
        if (length < sizeof(program->error)) {
            (void)snprintf(program->error + length,
                sizeof(program->error) - length,
                "; target module header bytes 0..0");
        }
        return;
    }
}

static void compute_selected_import_binding_id(
    const Program *program,
    size_t importer_index,
    const char *name,
    const uint8_t namespace_id[32],
    const uint8_t target_symbol_id[32],
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.import-binding/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    static const uint8_t form = IMPORT_FORM_SELECTIVE;
    const Module *importer = &program->modules[importer_index];
    size_t name_length = strlen(name);
    size_t payload_length = 36u + 32u + 32u + 32u + name_length + 32u + 1u;
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)(sizeof(domain) - 1u));
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain,
        sizeof(domain) - 1u);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), importer->module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), importer->file_id, 32u);
    hash_field(&context, UINT16_C(0x8003), namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name, name_length);
    hash_field(&context, UINT16_C(0x8005), target_symbol_id, 32u);
    hash_field(&context, UINT16_C(0x8006), &form, 1u);
    kofun_sha256_finish(&context, digest);
}

static void compute_export_binding_id_for_resolver(
    const Program *program,
    size_t exporter_index,
    const char *name,
    const uint8_t namespace_id[32],
    const uint8_t target_symbol_id[32],
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.export-binding/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    static const uint8_t visibility = 3u;
    const Module *exporter = &program->modules[exporter_index];
    size_t name_length = strlen(name);
    size_t payload_length = 30u + 32u + 32u + name_length + 32u + 1u;
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)(sizeof(domain) - 1u));
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain,
        sizeof(domain) - 1u);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), exporter->module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)name, name_length);
    hash_field(&context, UINT16_C(0x8004), target_symbol_id, 32u);
    hash_field(&context, UINT16_C(0x8005), &visibility, 1u);
    kofun_sha256_finish(&context, digest);
}

static KofunKifExportTargetKind export_target_kind(DeclarationKind kind) {
    switch (kind) {
        case DECLARATION_FUNCTION: return KOFUN_KIF_EXPORT_TARGET_FUNCTION;
        case DECLARATION_ADT: return KOFUN_KIF_EXPORT_TARGET_ADT;
        case DECLARATION_CONSTRUCTOR: return KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR;
    }
    return 0;
}

static bool validate_export_function_signature(
    ReExportResolver *resolver,
    const Declaration *target,
    size_t request_start,
    size_t request_end,
    uint16_t *parameter_count,
    KofunKifParameterLabel **parameter_labels
) {
    Program *program = &resolver->imports.qualified.program;
    const Module *module = &program->modules[target->module_index];
    size_t name = SIZE_MAX;
    size_t cursor;
    size_t close;
    uint16_t count = 0u;
    for (cursor = 0u; cursor < module->token_count; cursor += 1u) {
        if (module->tokens[cursor].start == target->name_start &&
            module->tokens[cursor].end == target->name_end) {
            name = cursor;
            break;
        }
    }
    if (name == SIZE_MAX || name + 1u >= module->token_count ||
        !punctuation_equals(module, &module->tokens[name + 1u], '(') ||
        !find_closing(program, module, name + 1u, '(', ')', &close)) {
        set_error(program, "E2S94",
            "re-export signature token invariant failed");
        return false;
    }
    cursor = name + 2u;
    while (cursor < close) {
        Token *type;
        size_t internal = cursor;
        size_t type_index = cursor + 2u;
        bool labelled = cursor + 3u < close &&
            module->tokens[cursor].kind == TOKEN_IDENTIFIER &&
            module->tokens[cursor + 1u].kind == TOKEN_IDENTIFIER &&
            punctuation_equals(module, &module->tokens[cursor + 2u], ':');
        if (labelled) {
            internal = cursor + 1u;
            type_index = cursor + 3u;
        }
        if (type_index >= close ||
            !punctuation_equals(module, &module->tokens[internal + 1u], ':')) {
            set_error(program, "E2S94",
                "re-export parameter token invariant failed");
            return false;
        }
        type = &module->tokens[type_index];
        if (!token_equals(module, type, "Int")) {
            set_error(program, "E2S87",
                "public re-export `%s` in `%s` at bytes %zu..%zu exposes hidden/incompatible parameter type at target bytes %zu..%zu; requested=pub effective=private; hint: expose a public supported signature",
                target->name, module->logical_path,
                request_start, request_end, type->start, type->end);
            return false;
        }
        {
            KofunKifParameterLabel *labels = realloc(
                *parameter_labels,
                ((size_t)count + 1u) * sizeof(**parameter_labels)
            );
            if (labels == NULL) {
                set_error(program, "E2S94",
                    "re-export parameter-label allocation failed");
                return false;
            }
            *parameter_labels = labels;
            memset(&labels[count], 0, sizeof(labels[count]));
            if (labelled) {
                const Token *external = &module->tokens[cursor];
                labels[count].bytes = module->source + external->start;
                labels[count].length =
                    (uint16_t)(external->end - external->start);
            }
        }
        count += 1u;
        cursor = type_index + 1u;
        if (cursor < close) cursor += 1u;
    }
    if (close + 2u >= module->token_count ||
        !token_equals(module, &module->tokens[close + 2u], "Int")) {
        Token *type = close + 2u < module->token_count
            ? &module->tokens[close + 2u] : &module->tokens[close];
        set_error(program, "E2S87",
            "public re-export `%s` in `%s` at bytes %zu..%zu exposes hidden/incompatible result type at target bytes %zu..%zu; requested=pub effective=private; hint: expose a public supported signature",
            target->name, module->logical_path,
            request_start, request_end, type->start, type->end);
        return false;
    }
    *parameter_count = count;
    return true;
}

static size_t export_lookup_slot(
    size_t exporter_index,
    unsigned namespace_tag,
    const char *name
) {
    uint64_t hash = UINT64_C(1469598103934665603);
    const unsigned char *cursor = (const unsigned char *)name;
    hash ^= (uint64_t)exporter_index;
    hash *= UINT64_C(1099511628211);
    hash ^= (uint64_t)namespace_tag;
    hash *= UINT64_C(1099511628211);
    while (*cursor != '\0') {
        hash ^= (uint64_t)*cursor++;
        hash *= UINT64_C(1099511628211);
    }
    return (size_t)(hash & (RE_EXPORT_LOOKUP_CAPACITY - 1u));
}

static bool ensure_export_lookup(ReExportResolver *resolver) {
    if (resolver->export_lookup != NULL) return true;
    resolver->export_lookup = calloc(RE_EXPORT_LOOKUP_CAPACITY,
        sizeof(*resolver->export_lookup));
    if (resolver->export_lookup == NULL) {
        set_error(&resolver->imports.qualified.program, "E2S94",
            "re-export collision index allocation failed");
        return false;
    }
    return true;
}

static ResolvedExport *find_indexed_export(
    ReExportResolver *resolver,
    size_t exporter_index,
    unsigned namespace_tag,
    const char *name
) {
    size_t slot;
    size_t probes;
    if (resolver->export_lookup == NULL) return NULL;
    slot = export_lookup_slot(exporter_index, namespace_tag, name);
    for (probes = 0u; probes < RE_EXPORT_LOOKUP_CAPACITY; probes += 1u) {
        ReExportLookupEntry *entry = &resolver->export_lookup[slot];
        ResolvedExport *candidate;
        if (!entry->occupied) return NULL;
        candidate = &resolver->exports[entry->export_index];
        if (entry->exporter_index == exporter_index &&
            entry->namespace_tag == namespace_tag &&
            strcmp(candidate->name, name) == 0) {
            return candidate;
        }
        slot = (slot + 1u) & (RE_EXPORT_LOOKUP_CAPACITY - 1u);
    }
    return NULL;
}

static bool index_export(
    ReExportResolver *resolver,
    size_t exporter_index,
    unsigned namespace_tag,
    const char *name,
    size_t export_index
) {
    size_t slot = export_lookup_slot(exporter_index, namespace_tag, name);
    size_t probes;
    for (probes = 0u; probes < RE_EXPORT_LOOKUP_CAPACITY; probes += 1u) {
        ReExportLookupEntry *entry = &resolver->export_lookup[slot];
        if (!entry->occupied) {
            *entry = (ReExportLookupEntry){
                .occupied = true,
                .exporter_index = exporter_index,
                .namespace_tag = namespace_tag,
                .export_index = export_index
            };
            return true;
        }
        slot = (slot + 1u) & (RE_EXPORT_LOOKUP_CAPACITY - 1u);
    }
    set_error(&resolver->imports.qualified.program, "E2S94",
        "re-export collision index exhausted");
    return false;
}

static bool export_collides(
    ReExportResolver *resolver,
    size_t declaration_index,
    const char *name,
    unsigned namespace_tag,
    size_t name_start,
    size_t name_end
) {
    Program *program = &resolver->imports.qualified.program;
    ReExportDeclaration *source = &resolver->declarations[declaration_index];
    size_t index;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *local = &program->declarations[index];
        if (local->module_index == source->exporter_index &&
            local->namespace_tag == namespace_tag &&
            strcmp(local->name, name) == 0) {
            set_error(program, "E2S88",
                "public %s export `%s` at `%s` bytes %zu..%zu collides with local declaration bytes %zu..%zu; hint: rename or remove one facade binding",
                namespace_name(namespace_tag), name,
                program->modules[source->exporter_index].logical_path,
                name_start, name_end, local->name_start, local->name_end);
            return true;
        }
    }
    for (index = 0u; index < resolver->imports.binding_count; index += 1u) {
        SelectiveBinding *binding = &resolver->imports.bindings[index];
        SelectiveDeclaration *selective =
            &resolver->imports.selectives[binding->declaration_index];
        SelectiveName *imported = &selective->names[binding->name_index];
        if (!selective->is_re_export &&
            selective->importer_index == source->exporter_index &&
            binding->namespace_tag == namespace_tag &&
            strcmp(imported->spelling, name) == 0) {
            set_error(program, "E2S88",
                "public %s export `%s` at `%s` bytes %zu..%zu collides with ordinary selective import bytes %zu..%zu; hint: remove one binding",
                namespace_name(namespace_tag), name,
                program->modules[source->exporter_index].logical_path,
                name_start, name_end, imported->start, imported->end);
            return true;
        }
    }
    if (namespace_tag == 2u) {
        ImportResolver *qualified = &resolver->imports.qualified;
        for (index = qualified->modules[source->exporter_index].first_import;
             index < qualified->import_count; index += 1u) {
            ImportBinding *binding = &qualified->imports[index];
            if (binding->importer_index != source->exporter_index) break;
            if (index != source->dependency_index &&
                binding->form_tag == IMPORT_FORM_QUALIFIED &&
                strcmp(binding->qualifier, name) == 0) {
                set_error(program, "E2S88",
                    "public module export `%s` at `%s` bytes %zu..%zu collides with ordinary import bytes %zu..%zu; hint: remove one binding",
                    name, program->modules[source->exporter_index].logical_path,
                    name_start, name_end, binding->start, binding->end);
                return true;
            }
        }
    }
    {
        ResolvedExport *other = find_indexed_export(resolver,
            source->exporter_index, namespace_tag, name);
        if (other != NULL) {
            set_error(program, "E2S88",
                "duplicate/colliding public %s export `%s` in `%s`; binding spans=%zu..%zu,%zu..%zu; hint: keep exactly one facade edge",
                namespace_name(namespace_tag), name,
                program->modules[source->exporter_index].logical_path,
                other->name_span_start, other->name_span_end,
                name_start, name_end);
            return true;
        }
    }
    return false;
}

static bool append_export(
    ReExportResolver *resolver,
    size_t declaration_index,
    const char *name,
    size_t name_start,
    size_t name_end,
    unsigned namespace_tag,
    KofunKifExportTargetKind target_kind,
    size_t target_module_index,
    size_t target_declaration_index,
    const uint8_t target_symbol_id[32],
    uint16_t parameter_count,
    const KofunKifParameterLabel *parameter_labels,
    uint8_t constructor_payload_count,
    const uint8_t target_owner_symbol_id[32],
    uint32_t target_constructor_ordinal,
    uint32_t access_proof,
    const ResolvedExport *forwarded
) {
    Program *program = &resolver->imports.qualified.program;
    ReExportDeclaration *source = &resolver->declarations[declaration_index];
    ImportBinding *dependency =
        &resolver->imports.qualified.imports[source->dependency_index];
    ResolvedExport *result;
    if (forwarded != NULL &&
        forwarded->chain_count >= RE_EXPORT_CHAIN_LIMIT) {
        set_error(program, "E2S90",
            "public re-export `%s` in `%s` would create a 65-edge chain at bytes %zu..%zu; hint: shorten the facade chain to at most 64 edges",
            name, program->modules[source->exporter_index].logical_path,
            name_start, name_end);
        return false;
    }
    if (export_collides(resolver, declaration_index, name, namespace_tag,
            name_start, name_end)) return false;
    if (!reserve_resolved_export(resolver, source->exporter_index,
            name_start, name_end) ||
        !ensure_export_lookup(resolver)) return false;
    result = &resolver->exports[resolver->export_count++];
    memset(result, 0, sizeof(*result));
    result->declaration_index = declaration_index;
    result->target_module_index = target_module_index;
    result->target_declaration_index = target_declaration_index;
    result->namespace_tag = namespace_tag;
    result->target_kind = target_kind;
    result->parameter_count = parameter_count;
    if (parameter_count != 0u) {
        result->parameter_labels = calloc(
            parameter_count,
            sizeof(*result->parameter_labels)
        );
        if (result->parameter_labels == NULL) {
            set_error(program, "E2S94",
                "re-export parameter-label projection failed");
            return false;
        }
        if (parameter_labels != NULL) {
            memcpy(
                result->parameter_labels,
                parameter_labels,
                (size_t)parameter_count * sizeof(*result->parameter_labels)
            );
        }
    }
    result->constructor_payload_count = constructor_payload_count;
    if (target_owner_symbol_id != NULL) {
        memcpy(result->target_owner_symbol_id, target_owner_symbol_id, 32u);
    }
    result->target_constructor_ordinal = target_constructor_ordinal;
    result->access_proof = access_proof;
    memcpy(result->name, name, strlen(name) + 1u);
    memcpy(result->target_symbol_id, target_symbol_id, 32u);
    result->import_span_start = source->whole_start;
    result->import_span_end = source->whole_end;
    result->name_span_start = name_start;
    result->name_span_end = name_end;
    compute_export_binding_id_for_resolver(program, source->exporter_index,
        name, program->namespace_ids[namespace_tag], target_symbol_id,
        result->export_binding_id);
    if (source->form == RE_EXPORT_QUALIFIED) {
        memcpy(result->source_import_binding_id, dependency->binding_id, 32u);
    } else {
        compute_selected_import_binding_id(program, source->exporter_index,
            name, program->namespace_ids[namespace_tag], target_symbol_id,
            result->source_import_binding_id);
    }
    memcpy(result->chain_ids[0], result->export_binding_id, 32u);
    result->chain_count = 1u;
    if (forwarded != NULL) {
        memcpy(result->chain_ids + 1u, forwarded->chain_ids,
            forwarded->chain_count * sizeof(forwarded->chain_ids[0]));
        result->chain_count += forwarded->chain_count;
    }
    if (!index_export(resolver, source->exporter_index, namespace_tag,
            name, resolver->export_count - 1u)) return false;
    resolver->module_export_counts[source->exporter_index] += 1u;
    return true;
}

static bool resolve_qualified_request(
    ReExportResolver *resolver,
    ReExportRequest *request
) {
    Program *program = &resolver->imports.qualified.program;
    ReExportDeclaration *source =
        &resolver->declarations[request->declaration_index];
    ImportBinding *dependency =
        &resolver->imports.qualified.imports[source->dependency_index];
    const char *declared_path =
        resolver->imports.qualified.modules[dependency->target_index].declared_path;
    const Module *exporter_module =
        &program->modules[source->exporter_index];
    const Module *target_module =
        &program->modules[dependency->target_index];
    KofunAccessContext context;
    KofunDeclarationAccess declaration;
    KofunAccessResult access;
    uint8_t target_symbol[32];
    ComponentSpan name_span =
        dependency->components[dependency->component_count - 1u];
    memset(&context, 0, sizeof(context));
    memset(&declaration, 0, sizeof(declaration));
    context.caller_package =
        access_identity(KOFUN_ID_PACKAGE, exporter_module->package_id);
    context.caller_module =
        access_identity(KOFUN_ID_MODULE, exporter_module->module_id);
    context.caller_file =
        access_identity(KOFUN_ID_FILE, exporter_module->file_id);
    context.use_span =
        (KofunSpan){ (uint32_t)name_span.start, (uint32_t)name_span.end };
    declaration.declared_visibility = KOFUN_VISIBILITY_PUBLIC;
    declaration.defining_package =
        access_identity(KOFUN_ID_PACKAGE, target_module->package_id);
    declaration.defining_module =
        access_identity(KOFUN_ID_MODULE, target_module->module_id);
    declaration.defining_file =
        access_identity(KOFUN_ID_FILE, target_module->file_id);
    declaration.declaration_span = (KofunSpan){ 0u, 0u };
    access = kofun_decide_access(&context, &declaration);
    if (access.kind != KOFUN_ACCESS_ALLOWED ||
        !access.usable_reference ||
        (access.proof & KOFUN_ACCESS_PROOF_SAME_PACKAGE) == 0u) {
        set_error(program, "E2S87",
            "public module re-export `%s` in `%s` at bytes %zu..%zu cannot publish target module header bytes 0..0 outside its same-package access boundary; requested=pub effective=private; hint: keep v1 re-exports inside one package",
            dependency->qualifier, exporter_module->logical_path,
            name_span.start, name_span.end);
        return false;
    }
    compute_symbol_hash(program->modules[dependency->target_index].module_id,
        program->namespace_ids[2], "module", declared_path, target_symbol);
    if (!append_export(resolver, request->declaration_index,
            dependency->qualifier, name_span.start, name_span.end, 2u,
            KOFUN_KIF_EXPORT_TARGET_MODULE, dependency->target_index,
            SIZE_MAX, target_symbol, 0u, NULL, 0u, NULL, 0u,
            access.proof, NULL)) return false;
    request->resolved_namespaces = (uint8_t)(1u << 2u);
    request->resolved = true;
    return true;
}

static bool append_direct_declaration_exports(
    ReExportResolver *resolver,
    ReExportRequest *request,
    bool *found
) {
    Program *program = &resolver->imports.qualified.program;
    ReExportDeclaration *source =
        &resolver->declarations[request->declaration_index];
    SelectiveDeclaration *selective =
        &resolver->imports.selectives[source->selective_index];
    SelectiveName *name =
        &selective->names[request->selective_name_index];
    ImportBinding *dependency =
        &resolver->imports.qualified.imports[source->dependency_index];
    size_t target_index;
    *found = false;
    for (target_index = 0u; target_index < program->declaration_count;
         target_index += 1u) {
        Declaration *target = &program->declarations[target_index];
        uint16_t parameter_count = 0u;
        KofunKifParameterLabel *parameter_labels = NULL;
        KofunAccessResult access;
        if (target->module_index != dependency->target_index ||
            (target->kind != DECLARATION_FUNCTION &&
             target->kind != DECLARATION_ADT &&
             target->kind != DECLARATION_CONSTRUCTOR) ||
            strcmp(target->name, name->spelling) != 0) continue;
        *found = true;
        access = selective_access(&resolver->imports,
            source->exporter_index, target, name->start, name->end);
        if (access.kind != KOFUN_ACCESS_ALLOWED ||
            !access.usable_reference) {
            set_error(program, "E2S87",
                "public re-export `%s` at `%s` bytes %zu..%zu cannot access target declaration bytes %zu..%zu: %s; requested=pub effective=private; hint: expose a reachable public target",
                name->spelling,
                program->modules[source->exporter_index].logical_path,
                name->start, name->end,
                target->name_start, target->name_end,
                kofun_access_reason_name(access.reason));
            return false;
        }
        if (target->visibility != VISIBILITY_PUBLIC) {
            set_error(program, "E2S87",
                "public re-export `%s` at `%s` bytes %zu..%zu would widen target declaration bytes %zu..%zu visibility; requested=pub effective=%s; hint: make the complete target API public or keep this an ordinary import",
                name->spelling,
                program->modules[source->exporter_index].logical_path,
                name->start, name->end,
                target->name_start, target->name_end,
                visibility_name(target->visibility));
            return false;
        }
        if (target->kind == DECLARATION_FUNCTION &&
            !validate_export_function_signature(resolver, target,
                name->start, name->end, &parameter_count,
                &parameter_labels)) {
            free(parameter_labels);
            return false;
        }
        {
            uint8_t payload_count = 0u;
            const uint8_t *owner_symbol = NULL;
            uint32_t constructor_ordinal = 0u;
            if (target->kind == DECLARATION_CONSTRUCTOR) {
                const Module *target_module =
                    &program->modules[target->module_index];
                size_t token_index;
                for (token_index = 0u;
                     token_index < target_module->token_count;
                     token_index += 1u) {
                    if (target_module->tokens[token_index].start ==
                            target->name_start &&
                        target_module->tokens[token_index].end ==
                            target->name_end) break;
                }
                if (token_index == target_module->token_count ||
                    !target->has_owner ||
                    target->owner_index >= program->declaration_count ||
                    target->constructor_index > UINT32_MAX) {
                    set_error(program, "E2S94",
                        "constructor export identity invariant failed");
                    return false;
                }
                if (token_index + 1u < target_module->token_count &&
                    punctuation_equals(target_module,
                        &target_module->tokens[token_index + 1u], '(')) {
                    payload_count = 1u;
                }
                owner_symbol =
                    program->declarations[target->owner_index].symbol_id;
                constructor_ordinal =
                    (uint32_t)target->constructor_index;
            }
            if (!append_export(resolver, request->declaration_index,
                name->spelling, name->start, name->end,
                target->namespace_tag, export_target_kind(target->kind),
                target->module_index, target_index, target->symbol_id,
                parameter_count, parameter_labels, payload_count, owner_symbol,
                constructor_ordinal, access.proof, NULL)) {
                free(parameter_labels);
                return false;
            }
            free(parameter_labels);
            request->resolved_namespaces |=
                (uint8_t)(1u << target->namespace_tag);
        }
    }
    return true;
}

static bool append_forwarded_exports(
    ReExportResolver *resolver,
    ReExportRequest *request,
    bool *found
) {
    ReExportDeclaration *source =
        &resolver->declarations[request->declaration_index];
    SelectiveDeclaration *selective =
        &resolver->imports.selectives[source->selective_index];
    SelectiveName *name =
        &selective->names[request->selective_name_index];
    ImportBinding *dependency =
        &resolver->imports.qualified.imports[source->dependency_index];
    uint8_t namespaces_before = request->resolved_namespaces;
    unsigned namespace_tag;
    *found = false;
    for (namespace_tag = 0u; namespace_tag < 4u; namespace_tag += 1u) {
        ResolvedExport target_copy;
        ResolvedExport *indexed;
        ResolvedExport *target;
        if (!re_export_step(resolver, name->start, name->end)) return false;
        if ((namespaces_before & (uint8_t)(1u << namespace_tag)) != 0u) {
            continue;
        }
        indexed = find_indexed_export(resolver, dependency->target_index,
            namespace_tag, name->spelling);
        if (indexed == NULL) continue;
        target_copy = *indexed;
        target = &target_copy;
        *found = true;
        if (!append_export(resolver, request->declaration_index,
                name->spelling, name->start, name->end,
                target->namespace_tag, target->target_kind,
                target->target_module_index,
                target->target_declaration_index,
                target->target_symbol_id, target->parameter_count,
                target->parameter_labels, target->constructor_payload_count,
                target->target_owner_symbol_id,
                target->target_constructor_ordinal,
                target->access_proof, target)) return false;
        request->resolved_namespaces |=
            (uint8_t)(1u << target->namespace_tag);
        request->has_forwarded_export = true;
    }
    return true;
}

static const char *request_name(
    ReExportResolver *resolver,
    const ReExportRequest *request
) {
    ReExportDeclaration *source =
        &resolver->declarations[request->declaration_index];
    if (source->form == RE_EXPORT_QUALIFIED) {
        return resolver->imports.qualified.imports[
            source->dependency_index].qualifier;
    }
    return resolver->imports.selectives[source->selective_index]
        .names[request->selective_name_index].spelling;
}

static void compute_cycle_edge_key(
    ReExportResolver *resolver,
    const ReExportRequest *request,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.diagnostic.re-export-cycle-edge/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    ReExportDeclaration *source =
        &resolver->declarations[request->declaration_index];
    ImportBinding *dependency =
        &resolver->imports.qualified.imports[source->dependency_index];
    Program *program = &resolver->imports.qualified.program;
    const char *name = request_name(resolver, request);
    size_t name_length = strlen(name);
    size_t payload_length = 18u + 32u + 32u + name_length;
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)(sizeof(domain) - 1u));
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain,
        sizeof(domain) - 1u);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001),
        program->modules[source->exporter_index].module_id, 32u);
    hash_field(&context, UINT16_C(0x8002),
        program->modules[dependency->target_index].module_id, 32u);
    hash_field(&context, UINT16_C(0x8003),
        (const uint8_t *)name, name_length);
    kofun_sha256_finish(&context, digest);
}

static int compare_request_edges(const void *left, const void *right) {
    size_t left_index = *(const size_t *)left;
    size_t right_index = *(const size_t *)right;
    ReExportRequest *left_request =
        &re_export_comparison_resolver->requests[left_index];
    ReExportRequest *right_request =
        &re_export_comparison_resolver->requests[right_index];
    ReExportDeclaration *left_source =
        &re_export_comparison_resolver->declarations[
            left_request->declaration_index];
    ReExportDeclaration *right_source =
        &re_export_comparison_resolver->declarations[
            right_request->declaration_index];
    ImportBinding *left_dependency =
        &re_export_comparison_resolver->imports.qualified.imports[
            left_source->dependency_index];
    ImportBinding *right_dependency =
        &re_export_comparison_resolver->imports.qualified.imports[
            right_source->dependency_index];
    Program *program =
        &re_export_comparison_resolver->imports.qualified.program;
    uint8_t left_key[32];
    uint8_t right_key[32];
    int result = memcmp(program->modules[left_source->exporter_index].module_id,
        program->modules[right_source->exporter_index].module_id, 32u);
    if (result != 0) return result;
    result = memcmp(program->modules[left_dependency->target_index].module_id,
        program->modules[right_dependency->target_index].module_id, 32u);
    if (result != 0) return result;
    result = strcmp(request_name(re_export_comparison_resolver, left_request),
        request_name(re_export_comparison_resolver, right_request));
    if (result != 0) return result;
    compute_cycle_edge_key(re_export_comparison_resolver, left_request, left_key);
    compute_cycle_edge_key(re_export_comparison_resolver, right_request, right_key);
    result = memcmp(left_key, right_key, 32u);
    if (result != 0) return result;
    return left_index < right_index ? -1 : left_index != right_index;
}

static void canonicalize_re_export_cycle(
    ReExportResolver *resolver,
    size_t *cycle,
    size_t length
) {
    Program *program = &resolver->imports.qualified.program;
    size_t best = 0u;
    size_t index;
    for (index = 1u; index < length; index += 1u) {
        ReExportDeclaration *candidate =
            &resolver->declarations[resolver->requests[cycle[index]]
                .declaration_index];
        ReExportDeclaration *current =
            &resolver->declarations[resolver->requests[cycle[best]]
                .declaration_index];
        int result = memcmp(program->modules[candidate->exporter_index].module_id,
            program->modules[current->exporter_index].module_id, 32u);
        if (result < 0) best = index;
        else if (result == 0) {
            uint8_t candidate_key[32];
            uint8_t current_key[32];
            compute_cycle_edge_key(resolver, &resolver->requests[cycle[index]],
                candidate_key);
            compute_cycle_edge_key(resolver, &resolver->requests[cycle[best]],
                current_key);
            if (memcmp(candidate_key, current_key, 32u) < 0) best = index;
        }
    }
    if (best != 0u) {
        size_t rotated[MODULE_LIMIT + 1u];
        for (index = 0u; index < length; index += 1u) {
            rotated[index] = cycle[(best + index) % length];
        }
        memcpy(cycle, rotated, length * sizeof(cycle[0]));
    }
}

static bool cycle_is_lexicographically_less(
    ReExportResolver *resolver,
    const size_t *left,
    const size_t *right,
    size_t length
) {
    Program *program = &resolver->imports.qualified.program;
    size_t index;
    for (index = 0u; index < length; index += 1u) {
        ReExportDeclaration *left_source =
            &resolver->declarations[resolver->requests[left[index]]
                .declaration_index];
        ReExportDeclaration *right_source =
            &resolver->declarations[resolver->requests[right[index]]
                .declaration_index];
        uint8_t left_key[32];
        uint8_t right_key[32];
        int result = memcmp(program->modules[left_source->exporter_index].module_id,
            program->modules[right_source->exporter_index].module_id, 32u);
        if (result != 0) return result < 0;
        compute_cycle_edge_key(resolver, &resolver->requests[left[index]], left_key);
        compute_cycle_edge_key(resolver, &resolver->requests[right[index]], right_key);
        result = memcmp(left_key, right_key, 32u);
        if (result != 0) return result < 0;
    }
    return false;
}

static bool diagnose_re_export_cycle(ReExportResolver *resolver) {
    Program *program = &resolver->imports.qualified.program;
    size_t *edges = NULL;
    size_t edge_count = 0u;
    size_t best[MODULE_LIMIT + 1u];
    size_t best_length = SIZE_MAX;
    size_t request_index;
    size_t start_edge;
    edges = malloc(resolver->request_count * sizeof(*edges));
    if (edges == NULL && resolver->request_count != 0u) {
        set_error(program, "E2S94", "cycle edge allocation failed");
        return false;
    }
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        ReExportRequest *request = &resolver->requests[request_index];
        ReExportDeclaration *source =
            &resolver->declarations[request->declaration_index];
        if (source->form == RE_EXPORT_QUALIFIED ||
            request->has_forwarded_export ||
            (!request->resolved && source->form == RE_EXPORT_SELECTIVE)) {
            edges[edge_count++] = request_index;
        }
    }
    re_export_comparison_resolver = resolver;
    if (edge_count > 1u) {
        qsort(edges, edge_count, sizeof(edges[0]), compare_request_edges);
    }
    for (start_edge = 0u; start_edge < edge_count; start_edge += 1u) {
        ReExportRequest *start_request =
            &resolver->requests[edges[start_edge]];
        ReExportDeclaration *start_source =
            &resolver->declarations[start_request->declaration_index];
        bool concrete_graph =
            start_source->form == RE_EXPORT_QUALIFIED ||
            start_request->has_forwarded_export;
        const char *cycle_name = concrete_graph
            ? NULL : request_name(resolver, start_request);
        size_t start = start_source->exporter_index;
        size_t queue[MODULE_LIMIT];
        bool visited[MODULE_LIMIT] = { false };
        size_t predecessor_module[MODULE_LIMIT];
        size_t predecessor_edge[MODULE_LIMIT];
        size_t head = 0u;
        size_t tail = 0u;
        size_t node;
        queue[tail++] = start;
        visited[start] = true;
        while (head < tail) {
            size_t edge_index;
            node = queue[head++];
            for (edge_index = 0u; edge_index < edge_count; edge_index += 1u) {
                ReExportRequest *request = &resolver->requests[edges[edge_index]];
                ReExportDeclaration *source =
                    &resolver->declarations[request->declaration_index];
                ImportBinding *dependency =
                    &resolver->imports.qualified.imports[
                        source->dependency_index];
                size_t target;
                if (!re_export_step(resolver,
                        source->whole_start, source->whole_end)) {
                    free(edges);
                    return false;
                }
                bool request_is_concrete =
                    source->form == RE_EXPORT_QUALIFIED ||
                    request->has_forwarded_export;
                if (source->exporter_index != node ||
                    request_is_concrete != concrete_graph ||
                    (cycle_name != NULL &&
                     strcmp(request_name(resolver, request),
                        cycle_name) != 0)) {
                    continue;
                }
                target = dependency->target_index;
                if (target == start) {
                    size_t candidate[MODULE_LIMIT + 1u];
                    size_t reversed[MODULE_LIMIT];
                    size_t reversed_count = 0u;
                    size_t candidate_length;
                    size_t walk = node;
                    while (walk != start) {
                        if (reversed_count >= MODULE_LIMIT) {
                            free(edges);
                            set_error(program, "E2S94",
                                "cycle reconstruction invariant failed");
                            return false;
                        }
                        reversed[reversed_count++] = predecessor_edge[walk];
                        walk = predecessor_module[walk];
                    }
                    candidate_length = reversed_count + 1u;
                    for (walk = 0u; walk < reversed_count; walk += 1u) {
                        candidate[walk] =
                            reversed[reversed_count - walk - 1u];
                    }
                    candidate[candidate_length - 1u] = edges[edge_index];
                    canonicalize_re_export_cycle(resolver, candidate,
                        candidate_length);
                    if (candidate_length < best_length ||
                        (candidate_length == best_length &&
                         cycle_is_lexicographically_less(resolver, candidate,
                            best, candidate_length))) {
                        memcpy(best, candidate,
                            candidate_length * sizeof(candidate[0]));
                        best_length = candidate_length;
                    }
                    continue;
                }
                if (!visited[target]) {
                    visited[target] = true;
                    predecessor_module[target] = node;
                    predecessor_edge[target] = edges[edge_index];
                    queue[tail++] = target;
                }
            }
        }
    }
    free(edges);
    if (best_length != SIZE_MAX) {
        TextBuffer diagnostic = { 0 };
        size_t index;
        if (!append_text(&resolver->imports.qualified, &diagnostic,
                "error[E2S89]: canonical re-export cycle: ")) {
            free(diagnostic.bytes);
            return false;
        }
        for (index = 0u; index < best_length; index += 1u) {
            ReExportRequest *request = &resolver->requests[best[index]];
            ReExportDeclaration *source =
                &resolver->declarations[request->declaration_index];
            ImportBinding *dependency =
                &resolver->imports.qualified.imports[
                    source->dependency_index];
            if (!append_text(&resolver->imports.qualified, &diagnostic,
                    "%s --%s:%zu..%zu--> ",
                    resolver->imports.qualified.modules[
                        source->exporter_index].declared_path,
                    program->modules[source->exporter_index].logical_path,
                    source->whole_start, source->whole_end)) {
                free(diagnostic.bytes);
                return false;
            }
            if (index + 1u == best_length &&
                !append_text(&resolver->imports.qualified, &diagnostic,
                    "%s (closing target module header bytes 0..0); hint: remove one public forwarding edge",
                    resolver->imports.qualified.modules[
                        dependency->target_index].declared_path)) {
                free(diagnostic.bytes);
                return false;
            }
        }
        resolver->imports.qualified.expanded_error = diagnostic.bytes;
        program->failed = true;
        return false;
    }
    return true;
}

static bool resolve_re_exports(ReExportResolver *resolver) {
    Program *program = &resolver->imports.qualified.program;
    size_t request_index;
    bool progress;
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        ReExportRequest *request = &resolver->requests[request_index];
        ReExportDeclaration *source =
            &resolver->declarations[request->declaration_index];
        if (source->form == RE_EXPORT_QUALIFIED &&
            !resolve_qualified_request(resolver, request)) return false;
    }
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        ReExportRequest *request = &resolver->requests[request_index];
        ReExportDeclaration *source =
            &resolver->declarations[request->declaration_index];
        bool direct_found;
        if (source->form != RE_EXPORT_SELECTIVE) continue;
        if (!append_direct_declaration_exports(resolver, request,
                &direct_found)) return false;
    }
    do {
        progress = false;
        for (request_index = 0u; request_index < resolver->request_count;
             request_index += 1u) {
            ReExportRequest *request = &resolver->requests[request_index];
            ReExportDeclaration *source =
                &resolver->declarations[request->declaration_index];
            bool forwarded_found;
            uint8_t namespaces_before;
            if (source->form != RE_EXPORT_SELECTIVE) continue;
            namespaces_before = request->resolved_namespaces;
            if (!append_forwarded_exports(resolver, request,
                    &forwarded_found)) return false;
            if (forwarded_found &&
                request->resolved_namespaces != namespaces_before) {
                progress = true;
            }
        }
    } while (progress);
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        ReExportRequest *request = &resolver->requests[request_index];
        ReExportDeclaration *source =
            &resolver->declarations[request->declaration_index];
        if (source->form == RE_EXPORT_SELECTIVE) {
            request->resolved = request->resolved_namespaces != 0u;
        }
    }
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        if (!resolver->requests[request_index].resolved) break;
    }
    if (!diagnose_re_export_cycle(resolver)) return false;
    if (request_index == resolver->request_count) return true;
    for (request_index = 0u; request_index < resolver->request_count;
         request_index += 1u) {
        ReExportRequest *request = &resolver->requests[request_index];
        ReExportDeclaration *source;
        ImportBinding *dependency;
        SelectiveName *name;
        if (request->resolved) continue;
        source = &resolver->declarations[request->declaration_index];
        dependency = &resolver->imports.qualified.imports[
            source->dependency_index];
        name = &resolver->imports.selectives[source->selective_index]
            .names[request->selective_name_index];
        set_error(program, "E2S86",
            "module `%s` has no public compatible target `%s` requested by facade `%s` at bytes %zu..%zu; hint: fix the spelling or publish a bounded function/type",
            dependency->path, name->spelling,
            program->modules[source->exporter_index].logical_path,
            name->start, name->end);
        return false;
    }
    return true;
}

static bool check_re_export_visible_confusables(ReExportResolver *resolver) {
    SelectiveResolver *selective = &resolver->imports;
    Program *program = &selective->qualified.program;
    size_t capacity = program->declaration_count;
    KofunVisibleBinding *visible = NULL;
    size_t module_index;
    if (selective->qualified.import_count > SIZE_MAX - capacity) {
        set_error(program, "E2S90",
            "re-export visible-binding vector bound overflowed");
        return false;
    }
    capacity += selective->qualified.import_count;
    if (selective->binding_count > SIZE_MAX - capacity) {
        set_error(program, "E2S90",
            "re-export visible-binding vector bound overflowed");
        return false;
    }
    capacity += selective->binding_count;
    if (resolver->export_count > SIZE_MAX - capacity) {
        set_error(program, "E2S90",
            "re-export visible-binding vector bound overflowed");
        return false;
    }
    capacity += resolver->export_count;
    if (capacity != 0u) {
        visible = calloc(capacity, sizeof(*visible));
        if (visible == NULL) {
            set_error(program, "EUNICODE007",
                "re-export visible-binding vector allocation failed");
            return false;
        }
    }
    for (module_index = 0u; module_index < program->module_count;
         module_index += 1u) {
        size_t count = 0u;
        size_t export_index;
        if (!collect_selective_visible_bindings(selective, module_index,
                visible, capacity, &count)) {
            free(visible);
            set_error(program, "E2S90",
                "re-export visible-binding vector exceeds its exact bound");
            return false;
        }
        for (export_index = 0u; export_index < resolver->export_count;
             export_index += 1u) {
            ResolvedExport *export = &resolver->exports[export_index];
            ReExportDeclaration *source =
                &resolver->declarations[export->declaration_index];
            if (source->exporter_index != module_index) continue;
            if (visible == NULL || count >= capacity) {
                free(visible);
                set_error(program, "E2S90",
                    "re-export visible-binding vector exceeds its exact bound");
                return false;
            }
            initialize_visible_binding(&visible[count++],
                &program->modules[module_index],
                program->namespace_ids[export->namespace_tag],
                export->export_binding_id, export->target_symbol_id,
                export->name, KOFUN_VISIBLE_SITE_RE_EXPORT,
                export->name_span_start, export->name_span_end);
        }
        if (!check_visible_binding_vector(selective, module_index,
                visible, count)) {
            free(visible);
            return false;
        }
    }
    selective->visible_confusables_checked = true;
    free(visible);
    return true;
}

static int compare_resolved_exports(const void *left, const void *right) {
    size_t left_index = *(const size_t *)left;
    size_t right_index = *(const size_t *)right;
    ResolvedExport *a =
        &re_export_comparison_resolver->exports[left_index];
    ResolvedExport *b =
        &re_export_comparison_resolver->exports[right_index];
    ReExportDeclaration *a_source =
        &re_export_comparison_resolver->declarations[a->declaration_index];
    ReExportDeclaration *b_source =
        &re_export_comparison_resolver->declarations[b->declaration_index];
    Program *program =
        &re_export_comparison_resolver->imports.qualified.program;
    int result = memcmp(program->modules[a_source->exporter_index].module_id,
        program->modules[b_source->exporter_index].module_id, 32u);
    if (result != 0) return result;
    if (a->namespace_tag != b->namespace_tag) {
        return a->namespace_tag < b->namespace_tag ? -1 : 1;
    }
    result = strcmp(a->name, b->name);
    if (result != 0) return result;
    result = memcmp(a->export_binding_id, b->export_binding_id, 32u);
    if (result != 0) return result;
    return left_index < right_index ? -1 : left_index != right_index;
}

static bool emit_re_export_hir(
    ReExportResolver *resolver,
    const char *path
) {
    Program *program = &resolver->imports.qualified.program;
    FILE *output = fopen(path, "wb");
    size_t *indices;
    size_t index;
    if (output == NULL) {
        set_error(program, "E2S92", "cannot create re-export HIR artifact");
        return false;
    }
    indices = malloc(resolver->export_count * sizeof(*indices));
    if (indices == NULL && resolver->export_count != 0u) {
        fclose(output);
        remove(path);
        set_error(program, "E2S94", "re-export HIR index allocation failed");
        return false;
    }
    for (index = 0u; index < resolver->export_count; index += 1u) {
        indices[index] = index;
    }
    re_export_comparison_resolver = resolver;
    if (resolver->export_count > 1u) {
        qsort(indices, resolver->export_count, sizeof(indices[0]),
            compare_resolved_exports);
    }
    fprintf(output, "kofun-re-exports/v1\n");
    for (index = 0u; index < resolver->export_count; index += 1u) {
        ResolvedExport *export = &resolver->exports[indices[index]];
        ReExportDeclaration *source =
            &resolver->declarations[export->declaration_index];
        char source_import_hex[65];
        char export_hex[65];
        char namespace_hex[65];
        char target_module_hex[65];
        char target_symbol_hex[65];
        size_t chain_index;
        bytes_to_hex(export->source_import_binding_id, 32u,
            source_import_hex);
        bytes_to_hex(export->export_binding_id, 32u, export_hex);
        bytes_to_hex(program->namespace_ids[export->namespace_tag], 32u,
            namespace_hex);
        bytes_to_hex(program->modules[export->target_module_index].module_id,
            32u, target_module_hex);
        bytes_to_hex(export->target_symbol_id, 32u, target_symbol_hex);
        fprintf(output,
            "export|module=%s|source-import=%s|ns=%u:%s:%s|name=%s|binding=%s|target-module=%s|target-symbol=%s|visibility=pub|import-span=%zu..%zu|name-span=%zu..%zu|chain=",
            resolver->imports.qualified.modules[
                source->exporter_index].declared_path,
            source_import_hex, export->namespace_tag,
            namespace_name(export->namespace_tag), namespace_hex,
            export->name, export_hex, target_module_hex,
            target_symbol_hex, export->import_span_start,
            export->import_span_end, export->name_span_start,
            export->name_span_end);
        for (chain_index = 0u; chain_index < export->chain_count;
             chain_index += 1u) {
            char chain_hex[65];
            bytes_to_hex(export->chain_ids[chain_index], 32u, chain_hex);
            fprintf(output, "%s%s", chain_index == 0u ? "" : ",", chain_hex);
        }
        fprintf(output,
            "|access-proof=%u|proof=non-widening-public-v1\n",
            export->access_proof);
    }
    free(indices);
    if (ferror(output) != 0 || fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S92", "cannot commit re-export HIR artifact");
        return false;
    }
    return true;
}

static bool emit_tooling_projection(
    ReExportResolver *resolver,
    const char *path
) {
    Program *program = &resolver->imports.qualified.program;
    FILE *output = fopen(path, "wb");
    size_t *indices;
    size_t index;
    if (output == NULL) {
        set_error(program, "E2S92", "cannot create re-export tooling projection");
        return false;
    }
    indices = malloc(resolver->export_count * sizeof(*indices));
    if (indices == NULL && resolver->export_count != 0u) {
        fclose(output);
        remove(path);
        set_error(program, "E2S94",
            "tooling projection index allocation failed");
        return false;
    }
    for (index = 0u; index < resolver->export_count; index += 1u) {
        indices[index] = index;
    }
    re_export_comparison_resolver = resolver;
    if (resolver->export_count > 1u) {
        qsort(indices, resolver->export_count, sizeof(indices[0]),
            compare_resolved_exports);
    }
    fprintf(output, "kofun-re-export-tooling/v1\n");
    for (index = 0u; index < resolver->export_count; index += 1u) {
        ResolvedExport *export = &resolver->exports[indices[index]];
        ReExportDeclaration *source =
            &resolver->declarations[export->declaration_index];
        const char *facade_module =
            resolver->imports.qualified.modules[
                source->exporter_index].declared_path;
        const char *target_module =
            resolver->imports.qualified.modules[
                export->target_module_index].declared_path;
        char target_symbol_hex[65];
        size_t chain_index;
        bytes_to_hex(export->target_symbol_id, 32u, target_symbol_hex);
        fprintf(output,
            "doc|facade=%s.%s|canonical=%s%s%s|namespace=%s|target-symbol=%s|chain=%zu|chain-ids=",
            facade_module, export->name, target_module,
            export->target_kind == KOFUN_KIF_EXPORT_TARGET_MODULE ? "" : ".",
            export->target_kind == KOFUN_KIF_EXPORT_TARGET_MODULE
                ? "" : export->name,
            namespace_name(export->namespace_tag), target_symbol_hex,
            export->chain_count);
        for (chain_index = 0u; chain_index < export->chain_count;
             chain_index += 1u) {
            char chain_hex[65];
            bytes_to_hex(export->chain_ids[chain_index], 32u, chain_hex);
            fprintf(output, "%s%s",
                chain_index == 0u ? "" : ",", chain_hex);
        }
        fprintf(output,
            "|linker-forwarding=false|runtime-forwarding=false\n");
    }
    free(indices);
    if (ferror(output) != 0 || fclose(output) != 0) {
        remove(path);
        set_error(program, "E2S92",
            "cannot commit re-export tooling projection");
        return false;
    }
    return true;
}

static bool find_facade_module(
    ReExportResolver *resolver,
    const char *declared_path,
    size_t *module_index
) {
    Program *program = &resolver->imports.qualified.program;
    size_t index;
    for (index = 0u; index < program->module_count; index += 1u) {
        if (strcmp(resolver->imports.qualified.modules[index].declared_path,
                declared_path) == 0) {
            *module_index = index;
            return true;
        }
    }
    set_error(program, "E2S93",
        "requested facade module `%s` is absent; hint: select a declared module from the inventory",
        declared_path);
    return false;
}

static KofunKifFactKind local_kif_kind(DeclarationKind kind) {
    switch (kind) {
        case DECLARATION_FUNCTION: return KOFUN_KIF_FACT_FUNCTION;
        case DECLARATION_ADT: return KOFUN_KIF_FACT_ADT;
        case DECLARATION_CONSTRUCTOR: return KOFUN_KIF_FACT_CONSTRUCTOR;
    }
    return 0;
}

static bool project_local_interface_fact(
    ReExportResolver *resolver,
    const Declaration *declaration,
    KofunKifFact *fact
) {
    Program *program = &resolver->imports.qualified.program;
    const Module *module = &program->modules[declaration->module_index];
    size_t token_index;
    if (fact == NULL) {
        set_error(program, "E2S94", "facade KIF fact invariant failed");
        return false;
    }
    memset(fact, 0, sizeof(*fact));
    memcpy(fact->namespace_id, declaration->namespace_id, 32u);
    memcpy(fact->symbol_id, declaration->symbol_id, 32u);
    fact->kind = local_kif_kind(declaration->kind);
    fact->visibility = declaration->visibility == VISIBILITY_PUBLIC
        ? KOFUN_KIF_VISIBILITY_PUBLIC : KOFUN_KIF_VISIBILITY_INTERNAL;
    fact->name = (char *)declaration->name;
    fact->name_length = strlen(declaration->name);
    if (declaration->kind == DECLARATION_FUNCTION) {
        if (!validate_export_function_signature(resolver, declaration,
                declaration->name_start, declaration->name_end,
                &fact->parameter_count,
                &fact->parameter_labels)) return false;
        fact->result_type = KOFUN_KIF_TYPE_INT;
    } else if (declaration->kind == DECLARATION_CONSTRUCTOR) {
        if (!declaration->has_owner ||
            declaration->owner_index >= program->declaration_count ||
            declaration->constructor_index > UINT32_MAX) {
            set_error(program, "E2S94",
                "local constructor KIF identity invariant failed");
            return false;
        }
        memcpy(fact->owner_symbol_id,
            program->declarations[declaration->owner_index].symbol_id, 32u);
        fact->constructor_ordinal =
            (uint32_t)declaration->constructor_index;
        for (token_index = 0u; token_index < module->token_count;
             token_index += 1u) {
            if (module->tokens[token_index].start == declaration->name_start &&
                module->tokens[token_index].end == declaration->name_end) {
                break;
            }
        }
        if (token_index == module->token_count) {
            set_error(program, "E2S94",
                "local constructor KIF token invariant failed");
            return false;
        }
        if (token_index + 1u < module->token_count &&
            punctuation_equals(module, &module->tokens[token_index + 1u],
                '(')) {
            fact->constructor_payload_count = 1u;
        }
    }
    return true;
}

static bool build_facade_interface(
    ReExportResolver *resolver,
    size_t module_index,
    KofunKifInterface *interface
) {
    Program *program = &resolver->imports.qualified.program;
    size_t public_count = resolver->module_export_counts[module_index];
    size_t internal_count = 0u;
    size_t index;
    size_t public_output = 0u;
    size_t internal_output = 0u;
    memset(interface, 0, sizeof(*interface));
    /* RFC-0012 0x800A. The facade describes one module, so it carries that
     * module's parsed class rather than a default; a facade over a raw-foreign
     * module that serialized `ordinary` would launder the class through the
     * re-export boundary, which is the shape #1216 exists to refuse. */
    interface->module_trust = program->modules[module_index].trust_raw_foreign
        ? KOFUN_KIF_TRUST_RAW_FOREIGN
        : KOFUN_KIF_TRUST_ORDINARY;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->module_index != module_index) continue;
        if (declaration->visibility == VISIBILITY_PUBLIC) {
            public_count += 1u;
        } else if (declaration->visibility == VISIBILITY_INTERNAL) {
            internal_count += 1u;
        }
    }
    if (public_count != 0u) {
        interface->public_facts = calloc(public_count,
            sizeof(*interface->public_facts));
    }
    if (internal_count != 0u) {
        interface->internal_facts = calloc(internal_count,
            sizeof(*interface->internal_facts));
    }
    if ((public_count != 0u && interface->public_facts == NULL) ||
        (internal_count != 0u && interface->internal_facts == NULL)) {
        set_error(program, "E2S94",
            "facade KIF fact allocation failed");
        return false;
    }
    memcpy(interface->package_id, program->modules[module_index].package_id,
        32u);
    memcpy(interface->module_id, program->modules[module_index].module_id,
        32u);
    memcpy(interface->edition, "edition-1", sizeof("edition-1"));
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->module_index != module_index) continue;
        if (declaration->visibility == VISIBILITY_PUBLIC) {
            KofunKifFact *fact;
            if (public_output >= public_count ||
                interface->public_facts == NULL) {
                set_error(program, "E2S94",
                    "facade public KIF fact count invariant failed");
                return false;
            }
            fact = &interface->public_facts[public_output++];
            if (!project_local_interface_fact(resolver, declaration, fact)) {
                return false;
            }
        } else if (declaration->visibility == VISIBILITY_INTERNAL) {
            KofunKifFact *fact;
            if (internal_output >= internal_count ||
                interface->internal_facts == NULL) {
                set_error(program, "E2S94",
                    "facade internal KIF fact count invariant failed");
                return false;
            }
            fact = &interface->internal_facts[internal_output++];
            if (!project_local_interface_fact(resolver, declaration, fact)) {
                return false;
            }
        }
    }
    for (index = 0u; index < resolver->export_count; index += 1u) {
        ResolvedExport *export = &resolver->exports[index];
        ReExportDeclaration *source =
            &resolver->declarations[export->declaration_index];
        KofunKifFact *fact;
        if (source->exporter_index != module_index) continue;
        if (public_output >= public_count ||
            interface->public_facts == NULL) {
            set_error(program, "E2S94",
                "facade export KIF fact count invariant failed");
            return false;
        }
        fact = &interface->public_facts[public_output++];
        memcpy(fact->namespace_id,
            program->namespace_ids[export->namespace_tag], 32u);
        memcpy(fact->symbol_id, export->export_binding_id, 32u);
        fact->kind = KOFUN_KIF_FACT_EXPORT;
        fact->visibility = KOFUN_KIF_VISIBILITY_PUBLIC;
        fact->name = export->name;
        fact->name_length = strlen(export->name);
        memcpy(fact->source_import_binding_id,
            export->source_import_binding_id, 32u);
        memcpy(fact->target_module_id,
            program->modules[export->target_module_index].module_id, 32u);
        memcpy(fact->target_symbol_id, export->target_symbol_id, 32u);
        fact->export_target_kind = export->target_kind;
        if (export->target_kind == KOFUN_KIF_EXPORT_TARGET_MODULE) {
            fact->export_target_module_path =
                resolver->imports.qualified.modules[
                    export->target_module_index].declared_path;
            fact->export_target_module_path_length =
                strlen(fact->export_target_module_path);
        }
        fact->parameter_count = export->parameter_count;
        fact->parameter_labels = export->parameter_labels;
        fact->constructor_payload_count =
            export->constructor_payload_count;
        if (export->target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION) {
            fact->result_type = KOFUN_KIF_TYPE_INT;
        }
        memcpy(fact->export_target_owner_symbol_id,
            export->target_owner_symbol_id, 32u);
        fact->export_target_constructor_ordinal =
            export->target_constructor_ordinal;
        fact->export_chain_ids = &export->chain_ids[0][0];
        fact->export_chain_count = export->chain_count;
    }
    if (public_output != public_count || internal_output != internal_count) {
        set_error(program, "E2S94", "facade KIF fact count invariant failed");
        return false;
    }
    interface->public_fact_count = public_output;
    interface->internal_fact_count = internal_output;
    return true;
}

static void destroy_facade_interface(KofunKifInterface *interface) {
    size_t index;
    for (index = 0u; index < interface->public_fact_count; index += 1u) {
        if (interface->public_facts[index].kind == KOFUN_KIF_FACT_FUNCTION) {
            free(interface->public_facts[index].parameter_labels);
        }
    }
    for (index = 0u; index < interface->internal_fact_count; index += 1u) {
        if (interface->internal_facts[index].kind == KOFUN_KIF_FACT_FUNCTION) {
            free(interface->internal_facts[index].parameter_labels);
        }
    }
    free(interface->public_facts);
    free(interface->internal_facts);
    memset(interface, 0, sizeof(*interface));
}

static void destroy_re_export_resolver(ReExportResolver *resolver) {
    size_t index;
    for (index = 0u; index < resolver->export_count; index += 1u) {
        free(resolver->exports[index].parameter_labels);
    }
    free(resolver->declarations);
    free(resolver->requests);
    free(resolver->exports);
    free(resolver->export_lookup);
    destroy_selective_resolver(&resolver->imports);
}

static bool read_complete_file(
    const char *path,
    uint8_t **bytes_out,
    size_t *length_out
) {
    FILE *input = fopen(path, "rb");
    long measured;
    size_t length;
    uint8_t *bytes;
    if (input == NULL || fseek(input, 0, SEEK_END) != 0 ||
        (measured = ftell(input)) < 0 || fseek(input, 0, SEEK_SET) != 0 ||
        (unsigned long)measured > KOFUN_KIF_MAX_ENVELOPE) {
        if (input != NULL) fclose(input);
        return false;
    }
    length = (size_t)measured;
    bytes = malloc(length == 0u ? 1u : length);
    if (bytes == NULL ||
        fread(bytes, 1u, length, input) != length ||
        fclose(input) != 0) {
        free(bytes);
        return false;
    }
    *bytes_out = bytes;
    *length_out = length;
    return true;
}

static bool validate_module_artifact_paths(
    Program *program,
    OutputArtifact *artifacts,
    size_t artifact_count
) {
    size_t module_index;
    size_t artifact_index;
    for (module_index = 0u; module_index < program->module_count;
         module_index += 1u) {
        const char *host_path = program->modules[module_index].host_path;
        for (artifact_index = 0u; artifact_index < artifact_count;
             artifact_index += 1u) {
            if (!reject_artifact_alias(program, host_path,
                    artifacts[artifact_index].final_path,
                    "module source and final output") ||
                !reject_artifact_alias(program, host_path,
                    artifacts[artifact_index].temporary_path,
                    "module source and transaction temporary") ||
                !reject_artifact_alias(program, host_path,
                    artifacts[artifact_index].backup_path,
                    "module source and transaction backup")) {
                return false;
            }
        }
    }
    return true;
}

static void compute_re_export_namespace_id(
    unsigned tag,
    const char *name,
    uint8_t digest[32]
) {
    char payload[96];
    int length = snprintf(payload, sizeof(payload),
        "kofun.namespace-id/v1\ntag=%u\nname=%s\n", tag, name);
    if (length < 0 || (size_t)length >= sizeof(payload)) {
        memset(digest, 0, 32u);
        return;
    }
    framed_hash("kofun.id.namespace/v1", (const uint8_t *)payload,
        (size_t)length, digest);
}

static int resolve_kif_mode(
    const char *input_path,
    const char *name,
    const char *namespace_text,
    const char *output_path
) {
    Program program;
    OutputArtifact artifact;
    uint8_t *bytes = NULL;
    size_t length = 0u;
    KifReadResult read;
    unsigned namespace_tag;
    uint8_t namespace_id[32];
    size_t index;
    const KofunKifFact *found = NULL;
    FILE *output = NULL;
    int status = 1;
    memset(&program, 0, sizeof(program));
    memset(&artifact, 0, sizeof(artifact));
    memset(&read, 0, sizeof(read));
    if (!reject_artifact_alias(&program, input_path, output_path,
            "target KIF input and resolved HIR output")) {
        remap_public_import_error(&program);
        goto done;
    }
    if (strcmp(namespace_text, "value") == 0) namespace_tag = 0u;
    else if (strcmp(namespace_text, "type") == 0) namespace_tag = 1u;
    else if (strcmp(namespace_text, "module") == 0) namespace_tag = 2u;
    else {
        printf("error[E2S93]: unknown export namespace `%s`; hint: use value, type, or module\n",
            namespace_text);
        goto done;
    }
    if (!read_complete_file(input_path, &bytes, &length)) {
        printf("error[E2S91]: cannot read bounded target KIF; hint: rebuild the dependency interface\n");
        goto done;
    }
    read = kofun_kif_read(bytes, length, kofun_kif_default_limits());
    free(bytes);
    bytes = NULL;
    if (read.status != KOFUN_KIF_OK) {
        printf("error[E2S91]: target KIF is %s and published no export facts; hint: rebuild it from trusted source\n",
            kofun_kif_status_name(read.status));
        goto done;
    }
    compute_re_export_namespace_id(namespace_tag, namespace_text,
        namespace_id);
    for (index = 0u; index < read.interface->public_fact_count; index += 1u) {
        KofunKifFact *fact = &read.interface->public_facts[index];
        if (fact->kind == KOFUN_KIF_FACT_EXPORT &&
            strcmp(fact->name, name) == 0 &&
            memcmp(fact->namespace_id, namespace_id, 32u) == 0) {
            if (found != NULL) {
                printf("error[E2S93]: target KIF has incompatible duplicate export `%s`; hint: rebuild the facade\n",
                    name);
                goto done;
            }
            found = fact;
        }
    }
    if (found == NULL) {
        printf("error[E2S93]: facade KIF has no public %s export `%s`; hint: import an exported namespace/name\n",
            namespace_text, name);
        goto done;
    }
    if (!prepare_output_artifact(&program, &artifact, output_path) ||
        !validate_transaction_paths(&program, input_path, &artifact, 1u)) {
        remap_public_import_error(&program);
        goto done;
    }
    output = fopen(artifact.temporary_path, "wb");
    if (output == NULL) {
        printf("error[E2S92]: cannot create resolved facade HIR; hint: choose a writable output path\n");
        goto done;
    }
    {
        char export_hex[65];
        char target_module_hex[65];
        char target_symbol_hex[65];
        size_t chain_index;
        bytes_to_hex(found->symbol_id, 32u, export_hex);
        bytes_to_hex(found->target_module_id, 32u, target_module_hex);
        bytes_to_hex(found->target_symbol_id, 32u, target_symbol_hex);
        fprintf(output,
            "kofun-re-export-consumer/v1\nuse|name=%s|namespace=%s|export-binding=%s|target-module=%s|target-symbol=%s|chain=%zu|chain-ids=",
            name, namespace_text, export_hex, target_module_hex,
            target_symbol_hex, found->export_chain_count);
        for (chain_index = 0u; chain_index < found->export_chain_count;
             chain_index += 1u) {
            char chain_hex[65];
            bytes_to_hex(found->export_chain_ids + chain_index * 32u,
                32u, chain_hex);
            fprintf(output, "%s%s",
                chain_index == 0u ? "" : ",", chain_hex);
        }
        fprintf(output, "\n");
    }
    if (ferror(output) != 0 || fclose(output) != 0) {
        output = NULL;
        remove(artifact.temporary_path);
        printf("error[E2S92]: cannot commit resolved facade HIR; hint: choose a writable output path\n");
        goto done;
    }
    output = NULL;
    if (!commit_output_artifacts(&program, &artifact, 1u)) {
        remap_public_import_error(&program);
        goto done;
    }
    status = 0;
done:
    if (output != NULL) fclose(output);
    free(bytes);
    if (read.interface != NULL) kofun_kif_destroy(read.interface);
    if (program.failed) printf("%s\n", program.error);
    release_output_artifact(&artifact);
    return status;
}

#ifndef KOFUN_RE_EXPORTS_NO_MAIN
int main(int argc, char **argv) {
    ReExportResolver resolver;
    ImportResolver *qualified = &resolver.imports.qualified;
    Program *program = &qualified->program;
    OutputArtifact artifacts[3];
    KofunKifInterface interface;
    KifWriteResult kif_result;
    size_t facade_module = SIZE_MAX;
    size_t index;
    int status = 1;
    if (argc == 6 && strcmp(argv[1], "--resolve-kif") == 0) {
        return resolve_kif_mode(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc != 6) {
        fprintf(stderr,
            "usage: %s INVENTORY FACADE_MODULE OUTPUT_HIR OUTPUT_KIF OUTPUT_TOOLING\n"
            "       %s --resolve-kif INPUT_KIF NAME NAMESPACE OUTPUT_HIR\n",
            argv[0], argv[0]);
        return 2;
    }
    memset(&resolver, 0, sizeof(resolver));
    memset(artifacts, 0, sizeof(artifacts));
    memset(&interface, 0, sizeof(interface));
    qualified->extension_context = &resolver.imports;
    if (!reject_artifact_alias(program, argv[1], argv[3],
            "inventory and HIR output") ||
        !reject_artifact_alias(program, argv[1], argv[4],
            "inventory and KIF output") ||
        !reject_artifact_alias(program, argv[1], argv[5],
            "inventory and tooling output") ||
        !reject_artifact_alias(program, argv[3], argv[4],
            "HIR and KIF outputs") ||
        !reject_artifact_alias(program, argv[3], argv[5],
            "HIR and tooling outputs") ||
        !reject_artifact_alias(program, argv[4], argv[5],
            "KIF and tooling outputs")) {
        remap_public_import_error(program);
        goto done;
    }
    if (!load_qualified_inventory(qualified, argv[1]) ||
        !order_and_validate_inventory(program) ||
        !attach_declared_paths(qualified)) goto done;
    if (!prepare_output_artifact(program, &artifacts[0], argv[3]) ||
        !prepare_output_artifact(program, &artifacts[1], argv[4]) ||
        !prepare_output_artifact(program, &artifacts[2], argv[5]) ||
        !validate_transaction_paths(program, argv[1], artifacts, 3u) ||
        !validate_module_artifact_paths(program, artifacts, 3u)) {
        remap_public_import_error(program);
        goto done;
    }
    if (!clear_requested_output(program, argv[3]) ||
        !clear_requested_output(program, argv[4]) ||
        !clear_requested_output(program, argv[5])) {
        remap_public_import_error(program);
        goto done;
    }
    for (index = 0u; index < program->module_count; index += 1u) {
        if (!collect_re_export_module(&resolver, index)) goto done;
    }
    compute_identities(program);
    if (!validate_duplicates(program)) goto done;
    if (!resolve_imports(qualified)) {
        add_self_re_export_secondary_span(&resolver);
        remap_public_import_error(program);
        goto done;
    }
    if (!validate_ordinary_import_cycles(&resolver)) goto done;
    canonicalize_import_graph_edges(&resolver.imports);
    if (!resolve_selective_bindings(&resolver.imports)) goto done;
    if (!build_re_export_requests(&resolver) ||
        !resolve_re_exports(&resolver) ||
        !check_re_export_visible_confusables(&resolver)) goto done;
#if defined(KOFUN_TEST_DIAGNOSTIC_FAULTS)
    if (diagnostic_fault_requested("re-export-chain")) {
        set_error(program, "E2S94",
            "re-export chain invariant failed");
        goto done;
    }
#endif
    if (!find_facade_module(&resolver, argv[2], &facade_module) ||
        !build_facade_interface(&resolver, facade_module, &interface) ||
        !emit_re_export_hir(&resolver, artifacts[0].temporary_path) ||
        !emit_tooling_projection(&resolver, artifacts[2].temporary_path)) {
        goto done;
    }
    kif_result = kofun_kif_write(&interface, artifacts[1].temporary_path);
    if (kif_result.status != KOFUN_KIF_OK) {
        if (kif_result.status == KOFUN_KIF_LIMIT_EXHAUSTED) {
            set_error(program, "E2S90",
                "facade KIF transaction exceeded a bounded interface limit at bytes %zu..%zu: %s; hint: export fewer facade facts",
                program->modules[facade_module].tokens[0].start,
                program->modules[facade_module].tokens[0].end,
                kif_result.message);
        } else {
            set_error(program,
                kif_result.status == KOFUN_KIF_IO_FAILURE
                    ? "E2S92" : "E2S91",
                "facade KIF transaction failed: %s; hint: fix the export facts and rebuild",
                kif_result.message);
        }
        goto done;
    }
    if (!commit_output_artifacts(program, artifacts, 3u)) {
        remap_public_import_error(program);
        goto done;
    }
    status = 0;
done:
    if (program->failed) {
        printf("%s\n", qualified->expanded_error != NULL
            ? qualified->expanded_error : program->error);
    }
    destroy_facade_interface(&interface);
    release_output_artifact(&artifacts[0]);
    release_output_artifact(&artifacts[1]);
    release_output_artifact(&artifacts[2]);
    destroy_re_export_resolver(&resolver);
    return status;
}
#endif
