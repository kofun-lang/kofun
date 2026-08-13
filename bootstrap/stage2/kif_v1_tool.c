#define _POSIX_C_SOURCE 200809L

#include "kif_v1.h"

#define KOFUN_MODULE_SYMBOLS_NO_MAIN
#include "module_symbols.c"
#include "confusable_visible_set.c"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

static const char *kif_fact_kind_name(KofunKifFactKind kind) {
    switch (kind) {
        case KOFUN_KIF_FACT_FUNCTION: return "function";
        case KOFUN_KIF_FACT_ADT: return "adt";
        case KOFUN_KIF_FACT_CONSTRUCTOR: return "constructor";
        case KOFUN_KIF_FACT_EXPORT: return "export";
    }
    return "invalid";
}

static const char *kif_visibility_name(KofunKifVisibility visibility) {
    switch (visibility) {
        case KOFUN_KIF_VISIBILITY_INTERNAL: return "internal";
        case KOFUN_KIF_VISIBILITY_PUBLIC: return "pub";
    }
    return "invalid";
}

static bool type_reference_is_nominal(
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    uint8_t combined = 0u;
    size_t index;
    for (index = 0u; index < KOFUN_KIF_ID_BYTES; index += 1u) {
        combined |= symbol_id[index];
    }
    return combined != 0u;
}

static void emit_type_reference(
    FILE *output,
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    char symbol_hex[65];
    if (!type_reference_is_nominal(symbol_id)) {
        fputs("\"Int\"", output);
        return;
    }
    bytes_to_hex(symbol_id, KOFUN_KIF_ID_BYTES, symbol_hex);
    fprintf(output, "\"nominal:%s\"", symbol_hex);
}

static KofunKifFactKind map_kind(DeclarationKind kind) {
    switch (kind) {
        case DECLARATION_FUNCTION: return KOFUN_KIF_FACT_FUNCTION;
        case DECLARATION_ADT: return KOFUN_KIF_FACT_ADT;
        case DECLARATION_CONSTRUCTOR: return KOFUN_KIF_FACT_CONSTRUCTOR;
    }
    return 0;
}

static bool declaration_is_interface_fact(const Declaration *declaration) {
    return declaration->visibility == VISIBILITY_PUBLIC ||
        declaration->visibility == VISIBILITY_INTERNAL;
}

static bool find_name_token(
    Program *program,
    const Declaration *declaration,
    size_t *token_index
) {
    Module *module = &program->modules[declaration->module_index];
    size_t index;
    for (index = 0u; index < module->token_count; index += 1u) {
        if (module->tokens[index].start == declaration->name_start &&
            module->tokens[index].end == declaration->name_end) {
            *token_index = index;
            return true;
        }
    }
    set_error(program, "E2S70", "cannot recover signature tokens for `%s`", declaration->name);
    return false;
}

static bool project_signature(
    Program *program,
    const Declaration *declaration,
    KofunKifFact *fact
) {
    Module *module = &program->modules[declaration->module_index];
    size_t name;
    if (!find_name_token(program, declaration, &name)) return false;
    if (declaration->kind == DECLARATION_FUNCTION) {
        size_t open = name + 1u;
        size_t close;
        size_t cursor;
        uint16_t parameter_count = 0u;
        if (open >= module->token_count ||
            !punctuation_equals(module, &module->tokens[open], '(') ||
            !find_closing(program, module, open, '(', ')', &close)) return false;
        cursor = open + 1u;
        while (cursor < close) {
            size_t internal = cursor;
            size_t type = cursor + 2u;
            bool labelled = cursor + 3u < close &&
                module->tokens[cursor].kind == TOKEN_IDENTIFIER &&
                module->tokens[cursor + 1u].kind == TOKEN_IDENTIFIER &&
                punctuation_equals(module, &module->tokens[cursor + 2u], ':');
            if (labelled) {
                internal = cursor + 1u;
                type = cursor + 3u;
            }
            if (type >= close ||
                module->tokens[internal].kind != TOKEN_IDENTIFIER ||
                !punctuation_equals(
                    module,
                    &module->tokens[internal + 1u],
                    ':'
                ) ||
                !token_equals(module, &module->tokens[type], "Int")) {
                set_error(program, "E2S70",
                    "KIF v2 function `%s` requires only Int parameter types", declaration->name);
                return false;
            }
            if (parameter_count >= 256u) {
                set_error(program, "E2S70",
                    "KIF v2 function `%s` has too many parameters", declaration->name);
                return false;
            }
            {
                KofunKifParameterLabel *labels = realloc(
                    fact->parameter_labels,
                    ((size_t)parameter_count + 1u) *
                        sizeof(*fact->parameter_labels)
                );
                if (labels == NULL) {
                    set_error(program, "E2S71", "KIF parameter-label allocation failed");
                    return false;
                }
                fact->parameter_labels = labels;
                memset(&fact->parameter_labels[parameter_count], 0,
                    sizeof(*fact->parameter_labels));
                if (labelled) {
                    const Token *external = &module->tokens[cursor];
                    fact->parameter_labels[parameter_count].bytes =
                        module->source + external->start;
                    fact->parameter_labels[parameter_count].length =
                        (uint16_t)(external->end - external->start);
                }
            }
            parameter_count += 1u;
            cursor = type + 1u;
            if (cursor < close) {
                if (!punctuation_equals(module, &module->tokens[cursor], ',')) {
                    set_error(program, "E2S70",
                        "KIF v2 function `%s` has a malformed parameter list", declaration->name);
                    return false;
                }
                cursor += 1u;
            }
        }
        if (close + 2u >= module->token_count ||
            module->tokens[close + 1u].kind != TOKEN_ARROW ||
            !token_equals(module, &module->tokens[close + 2u], "Int")) {
            set_error(program, "E2S70",
                "KIF v2 function `%s` requires an Int result type", declaration->name);
            return false;
        }
        fact->parameter_count = parameter_count;
        fact->result_type = KOFUN_KIF_TYPE_INT;
    } else if (declaration->kind == DECLARATION_CONSTRUCTOR) {
        size_t next = name + 1u;
        if (next < module->token_count && punctuation_equals(module, &module->tokens[next], '(')) {
            size_t close;
            if (!find_closing(program, module, next, '(', ')', &close)) return false;
            if (close != next + 4u ||
                module->tokens[next + 1u].kind != TOKEN_IDENTIFIER ||
                !punctuation_equals(module, &module->tokens[next + 2u], ':') ||
                !token_equals(module, &module->tokens[next + 3u], "Int")) {
                set_error(program, "E2S70",
                    "KIF v2 constructor `%s` requires zero or one Int payload",
                    declaration->name);
                return false;
            }
            fact->constructor_payload_count = 1u;
        }
    }
    return true;
}

static bool append_projected_fact(
    Program *program,
    Declaration *declaration,
    KofunKifFact *facts,
    size_t *count
) {
    KofunKifFact *fact = &facts[*count];
    memset(fact, 0, sizeof(*fact));
    memcpy(fact->namespace_id, declaration->namespace_id, KOFUN_KIF_ID_BYTES);
    memcpy(fact->symbol_id, declaration->symbol_id, KOFUN_KIF_ID_BYTES);
    fact->kind = map_kind(declaration->kind);
    fact->visibility = declaration->visibility == VISIBILITY_PUBLIC
        ? KOFUN_KIF_VISIBILITY_PUBLIC : KOFUN_KIF_VISIBILITY_INTERNAL;
    fact->name = declaration->name;
    fact->name_length = strlen(declaration->name);
    if (declaration->kind == DECLARATION_CONSTRUCTOR) {
        const Declaration *owner;
        if (!declaration->has_owner || declaration->owner_index >= program->declaration_count) {
            set_error(program, "E2S70", "constructor `%s` has no canonical owner", declaration->name);
            return false;
        }
        owner = &program->declarations[declaration->owner_index];
        memcpy(fact->owner_symbol_id, owner->symbol_id, KOFUN_KIF_ID_BYTES);
        if (declaration->constructor_index > UINT32_MAX) {
            set_error(program, "E2S70", "constructor ordinal exceeds KIF v2");
            return false;
        }
        fact->constructor_ordinal = (uint32_t)declaration->constructor_index;
    }
    if (!project_signature(program, declaration, fact)) {
        free(fact->parameter_labels);
        fact->parameter_labels = NULL;
        return false;
    }
    *count += 1u;
    return true;
}

static bool build_interface(
    Program *program,
    const uint8_t module_id[KOFUN_KIF_ID_BYTES],
    const char *edition,
    KofunKifInterface *interface
) {
    size_t module_index = SIZE_MAX;
    size_t public_count = 0u;
    size_t internal_count = 0u;
    size_t index;
    memset(interface, 0, sizeof(*interface));
    for (index = 0u; index < program->module_count; index += 1u) {
        if (memcmp(program->modules[index].module_id, module_id, KOFUN_KIF_ID_BYTES) == 0) {
            module_index = index;
            break;
        }
    }
    if (module_index == SIZE_MAX) {
        set_error(program, "E2S69", "requested ModuleId is absent from the inventory");
        return false;
    }
    if (strlen(edition) == 0u || strlen(edition) > KOFUN_KIF_MAX_EDITION_BYTES) {
        set_error(program, "E2S69", "edition is outside the KIF v2 bound");
        return false;
    }
    /* RFC-0012 0x800A, taken from the parsed inventory rather than defaulted.
     * This path does see raw-foreign modules, so the class is read from the
     * same `Module` record that `module_symbols.c` set when it parsed the
     * header — not from the rendered `trust=` column, which would be
     * reconstructing authority from text. */
    interface->module_trust = program->modules[module_index].trust_raw_foreign
        ? KOFUN_KIF_TRUST_RAW_FOREIGN
        : KOFUN_KIF_TRUST_ORDINARY;
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->module_index != module_index || !declaration_is_interface_fact(declaration)) {
            continue;
        }
        if (declaration->visibility == VISIBILITY_PUBLIC) public_count += 1u;
        else internal_count += 1u;
    }
    if (public_count != 0u) {
        interface->public_facts = calloc(public_count, sizeof(*interface->public_facts));
    }
    if (internal_count != 0u) {
        interface->internal_facts = calloc(internal_count, sizeof(*interface->internal_facts));
    }
    if ((public_count != 0u && interface->public_facts == NULL) ||
        (internal_count != 0u && interface->internal_facts == NULL)) {
        set_error(program, "E2S71", "KIF fact allocation failed");
        return false;
    }
    memcpy(interface->package_id, program->modules[module_index].package_id, KOFUN_KIF_ID_BYTES);
    memcpy(interface->module_id, module_id, KOFUN_KIF_ID_BYTES);
    memcpy(interface->edition, edition, strlen(edition) + 1u);
    for (index = 0u; index < program->declaration_count; index += 1u) {
        Declaration *declaration = &program->declarations[index];
        if (declaration->module_index != module_index || !declaration_is_interface_fact(declaration)) {
            continue;
        }
        if (declaration->visibility == VISIBILITY_PUBLIC) {
            if (!append_projected_fact(program, declaration,
                    interface->public_facts, &interface->public_fact_count)) return false;
        } else if (!append_projected_fact(program, declaration,
                interface->internal_facts, &interface->internal_fact_count)) return false;
    }
    return true;
}

static void destroy_writer_interface(KofunKifInterface *interface) {
    size_t index;
    for (index = 0u; index < interface->public_fact_count; index += 1u) {
        free(interface->public_facts[index].parameter_labels);
    }
    for (index = 0u; index < interface->internal_fact_count; index += 1u) {
        free(interface->internal_facts[index].parameter_labels);
    }
    free(interface->public_facts);
    free(interface->internal_facts);
    memset(interface, 0, sizeof(*interface));
}

static bool read_kif_file(const char *path, uint8_t **bytes_out, size_t *length_out) {
    FILE *input = fopen(path, "rb");
    long measured;
    uint8_t *bytes;
    size_t length;
    if (input == NULL) return false;
    if (fseek(input, 0, SEEK_END) != 0 || (measured = ftell(input)) < 0 ||
        fseek(input, 0, SEEK_SET) != 0 ||
        (unsigned long)measured > KOFUN_KIF_MAX_ENVELOPE) {
        fclose(input);
        return false;
    }
    length = (size_t)measured;
    bytes = malloc(length == 0u ? 1u : length);
    if (bytes == NULL) {
        fclose(input);
        return false;
    }
    {
        size_t read_count = fread(bytes, 1u, length, input);
        int close_status = fclose(input);
        if (read_count != length || close_status != 0) {
            free(bytes);
            return false;
        }
    }
    *bytes_out = bytes;
    *length_out = length;
    return true;
}

static bool emit_dump(const KofunKifInterface *interface, const char *path) {
    FILE *output = path == NULL ? stdout : fopen(path, "wb");
    char package_hex[65];
    char module_hex[65];
    char public_hex[65];
    char internal_hex[65];
    size_t index;
    if (output == NULL) return false;
    bytes_to_hex(interface->package_id, 32u, package_hex);
    bytes_to_hex(interface->module_id, 32u, module_hex);
    bytes_to_hex(interface->public_semantic_digest, 32u, public_hex);
    bytes_to_hex(interface->package_internal_semantic_digest, 32u, internal_hex);
    fprintf(output,
        "{\n  \"schema\": \"kofun.interface-dump/v1\",\n"
        "  \"authoritative\": false,\n"
        "  \"edition\": \"%s\",\n"
        "  \"module_trust\": \"%s\",\n"
        "  \"package_id\": \"%s\",\n"
        "  \"module_id\": \"%s\",\n"
        "  \"public_semantic_digest\": \"%s\",\n"
        "  \"package_internal_semantic_digest\": \"%s\",\n"
        "  \"facts\": [\n",
        interface->edition,
        interface->module_trust == KOFUN_KIF_TRUST_RAW_FOREIGN
            ? "raw-foreign" : "ordinary",
        package_hex, module_hex, public_hex, internal_hex);
    for (index = 0u; index < interface->public_fact_count + interface->internal_fact_count; index += 1u) {
        const KofunKifFact *fact = index < interface->public_fact_count
            ? &interface->public_facts[index]
            : &interface->internal_facts[index - interface->public_fact_count];
        char namespace_hex[65];
        char symbol_hex[65];
        bytes_to_hex(fact->namespace_id, 32u, namespace_hex);
        bytes_to_hex(fact->symbol_id, 32u, symbol_hex);
        fprintf(output,
            "    {\"namespace_id\": \"%s\", \"symbol_id\": \"%s\", "
            "\"kind\": \"%s\", \"name\": \"%s\", \"visibility\": \"%s\"",
            namespace_hex, symbol_hex, kif_fact_kind_name(fact->kind), fact->name,
            kif_visibility_name(fact->visibility));
        if (fact->kind == KOFUN_KIF_FACT_FUNCTION) {
            size_t parameter_index;
            fprintf(output, ", \"parameter_count\": %u, \"parameter_types\": [",
                (unsigned)fact->parameter_count);
            for (parameter_index = 0u;
                 parameter_index < fact->parameter_count;
                 parameter_index += 1u) {
                const uint8_t *type_id = fact->parameter_type_symbol_ids == NULL ?
                    (const uint8_t[KOFUN_KIF_ID_BYTES]){0} :
                    fact->parameter_type_symbol_ids +
                        parameter_index * KOFUN_KIF_ID_BYTES;
                if (parameter_index != 0u) fputs(", ", output);
                emit_type_reference(output, type_id);
            }
            fputs("], \"parameter_labels\": [", output);
            for (parameter_index = 0u;
                 parameter_index < fact->parameter_count;
                 parameter_index += 1u) {
                const KofunKifParameterLabel *label = fact->parameter_labels == NULL
                    ? NULL : &fact->parameter_labels[parameter_index];
                if (parameter_index != 0u) fputs(", ", output);
                if (label == NULL || label->bytes == NULL) {
                    fputs("\"unlabelled\"", output);
                } else {
                    fprintf(output, "\"%.*s\"", (int)label->length, label->bytes);
                }
            }
            fputs("], \"result\": ", output);
            emit_type_reference(output, fact->result_type_symbol_id);
        } else if (fact->kind == KOFUN_KIF_FACT_CONSTRUCTOR) {
            char owner_hex[65];
            bytes_to_hex(fact->owner_symbol_id, 32u, owner_hex);
            fprintf(output, ", \"payload_count\": %u, \"owner_symbol_id\": \"%s\", "
                "\"ordinal\": %u",
                (unsigned)fact->constructor_payload_count, owner_hex,
                (unsigned)fact->constructor_ordinal);
            if (fact->constructor_payload_count == 1u) {
                fputs(", \"payload_type\": ", output);
                emit_type_reference(
                    output, fact->constructor_payload_type_symbol_id);
            }
        } else if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
            char source_import_hex[65];
            char target_module_hex[65];
            char target_symbol_hex[65];
            char chain_first_hex[65];
            size_t chain_index;
            bytes_to_hex(fact->source_import_binding_id, 32u, source_import_hex);
            bytes_to_hex(fact->target_module_id, 32u, target_module_hex);
            bytes_to_hex(fact->target_symbol_id, 32u, target_symbol_hex);
            bytes_to_hex(fact->export_chain_ids, 32u, chain_first_hex);
            fprintf(output,
                ", \"source_import_binding_id\": \"%s\", "
                "\"target_module_id\": \"%s\", \"target_symbol_id\": \"%s\", "
                "\"target_kind\": \"%s\", \"chain_count\": %zu, "
                "\"chain_first\": \"%s\"",
                source_import_hex, target_module_hex, target_symbol_hex,
                fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION
                    ? "function"
                    : fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_ADT
                        ? "adt"
                        : fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR
                            ? "constructor" : "module",
                fact->export_chain_count, chain_first_hex);
            fprintf(output, ", \"chain_ids\": [");
            for (chain_index = 0u;
                 chain_index < fact->export_chain_count;
                 chain_index += 1u) {
                char chain_hex[65];
                bytes_to_hex(fact->export_chain_ids +
                    chain_index * KOFUN_KIF_ID_BYTES,
                    KOFUN_KIF_ID_BYTES, chain_hex);
                fprintf(output, "%s\"%s\"",
                    chain_index == 0u ? "" : ", ", chain_hex);
            }
            fprintf(output, "]");
            if (fact->export_target_kind ==
                    KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
                char owner_hex[65];
                bytes_to_hex(fact->export_target_owner_symbol_id, 32u,
                    owner_hex);
                fprintf(output,
                    ", \"payload_count\": %u, "
                    "\"target_owner_symbol_id\": \"%s\", "
                    "\"target_constructor_ordinal\": %u",
                    (unsigned)fact->constructor_payload_count, owner_hex,
                    (unsigned)fact->export_target_constructor_ordinal);
            } else if (fact->export_target_kind ==
                    KOFUN_KIF_EXPORT_TARGET_MODULE) {
                fprintf(output, ", \"target_module_path\": \"%s\"",
                    fact->export_target_module_path);
            }
        }
        fprintf(output, "}%s\n",
            index + 1u == interface->public_fact_count + interface->internal_fact_count ? "" : ",");
    }
    fprintf(output, "  ]\n}\n");
    if (ferror(output) != 0) {
        if (path != NULL) {
            (void)fclose(output);
            remove(path);
        }
        return false;
    }
    if (path != NULL && fclose(output) != 0) {
        remove(path);
        return false;
    }
    return true;
}

static int read_mode(const char *input_path, const char *dump_path) {
    uint8_t *bytes = NULL;
    size_t length = 0u;
    KifReadResult result;
    int status = 1;
    if (dump_path != NULL) remove(dump_path);
    if (!read_kif_file(input_path, &bytes, &length)) {
        printf("error[KIF-IO]: cannot read bounded KIF input\n");
        return 1;
    }
    result = kofun_kif_read(bytes, length, kofun_kif_default_limits());
    free(bytes);
    if (result.status != KOFUN_KIF_OK) {
        printf("error[KIF-%s]: %s\n", kofun_kif_status_name(result.status), result.message);
        return 1;
    }
    if (!emit_dump(result.interface, dump_path)) {
        printf("error[KIF-IO]: cannot write diagnostic dump\n");
    } else {
        status = 0;
    }
    kofun_kif_destroy(result.interface);
    return status;
}

static int write_mode(
    const char *inventory,
    const char *module_text,
    const char *edition,
    const char *output,
    const char *dump_path
) {
    Program program;
    KofunKifInterface interface;
    uint8_t module_id[32];
    KifWriteResult result;
    size_t index;
    int status = 1;
    memset(&program, 0, sizeof(program));
    memset(&interface, 0, sizeof(interface));
    if (dump_path != NULL) remove(dump_path);
    if (!parse_identity(module_text, module_id)) {
        set_error(&program, "E2S69", "ModuleId must be 64 lowercase hexadecimal digits");
        goto done;
    }
    if (!load_inventory(&program, inventory) || !order_and_validate_inventory(&program)) goto done;
    for (index = 0u; index < program.module_count; index += 1u) {
        if (!collect_module(&program, index)) goto done;
    }
    compute_identities(&program);
    if (!validate_duplicates(&program) || !resolve_bodies(&program) ||
        !build_interface(&program, module_id, edition, &interface)) goto done;
    result = kofun_kif_write(&interface, output);
    if (result.status != KOFUN_KIF_OK) {
        printf("error[KIF-%s]: %s\n", kofun_kif_status_name(result.status), result.message);
        goto done;
    }
    /* RFC-0012's third refusal, checked against the bytes that actually
     * reached the filesystem rather than against the interface we just built
     * from the same record — comparing the in-memory struct to its own source
     * would agree by construction and prove nothing. Re-reading catches a
     * writer, codec, or commit that lost the class between the inventory and
     * the artifact. Neither side wins: the artifact is refused, not rewritten. */
    {
        uint8_t *published = NULL;
        size_t published_length = 0u;
        KifReadResult check;
        size_t module_index;
        bool source_raw_foreign = false;
        for (module_index = 0u; module_index < program.module_count; module_index += 1u) {
            if (memcmp(program.modules[module_index].module_id, module_id,
                    KOFUN_KIF_ID_BYTES) == 0) {
                source_raw_foreign = program.modules[module_index].trust_raw_foreign;
                break;
            }
        }
        if (!read_kif_file(output, &published, &published_length)) {
            set_error(&program, "E2S69", "published artifact could not be re-read");
            goto done;
        }
        check = kofun_kif_read(published, published_length, kofun_kif_default_limits());
        if (check.status != KOFUN_KIF_OK) {
            free(published);
            set_error(&program, "E2S69", "published artifact did not read back");
            goto done;
        }
        if (!kofun_kif_trust_agrees(check.interface, source_raw_foreign)) {
            kofun_kif_destroy(check.interface);
            free(published);
            set_error(&program, "E2S69",
                "published trust class contradicts the source `trust` fact; the artifact must be rebuilt");
            goto done;
        }
        kofun_kif_destroy(check.interface);
        free(published);
    }
    if (dump_path != NULL && read_mode(output, dump_path) != 0) goto done;
    status = 0;
done:
    if (program.failed) printf("%s\n", program.error);
    if (status != 0 && dump_path != NULL) remove(dump_path);
    destroy_writer_interface(&interface);
    destroy_program(&program);
    return status;
}

typedef struct {
    const KofunKifFact *fact;
    size_t arity;
    size_t start;
    size_t end;
} KifQualifiedCall;

static bool token_text_equals(
    const Module *module,
    const Token *token,
    const char *text
) {
    size_t length = token->end - token->start;
    return strlen(text) == length &&
        memcmp(module->source + token->start, text, length) == 0;
}

static bool parse_dependency_import(
    Program *program,
    Module *module,
    const char *dependency_path,
    char qualifier[IDENTIFIER_LIMIT + 1u]
) {
    size_t cursor;
    bool found = false;
    for (cursor = 0u; cursor < module->token_count; cursor += 1u) {
        char path[HOST_PATH_LIMIT + 1u];
        size_t path_length = 0u;
        size_t component_start = 0u;
        size_t current;
        bool expect_identifier = true;
        if (!token_equals(module, &module->tokens[cursor], "import")) continue;
        current = cursor + 1u;
        while (current < module->token_count &&
            !module->tokens[current].line_break_before) {
            Token *token = &module->tokens[current];
            if (expect_identifier) {
                size_t length;
                if (token->kind != TOKEN_IDENTIFIER) break;
                length = token->end - token->start;
                if (path_length != 0u) path[path_length++] = '.';
                if (path_length + length > HOST_PATH_LIMIT) break;
                component_start = path_length;
                memcpy(path + path_length, module->source + token->start, length);
                path_length += length;
            } else if (!punctuation_equals(module, token, '.')) {
                break;
            }
            expect_identifier = !expect_identifier;
            current += 1u;
        }
        if (path_length == 0u || expect_identifier ||
            (current < module->token_count && !module->tokens[current].line_break_before)) {
            set_error(program, "E2S59", "malformed qualified import in KIF consumer");
            return false;
        }
        path[path_length] = '\0';
        if (strcmp(path, dependency_path) != 0) {
            set_error(program, "E2S60",
                "KIF consumer import `%s` has no supplied compiled interface", path);
            return false;
        }
        if (found) {
            set_error(program, "E2S61", "duplicate KIF dependency import `%s`", path);
            return false;
        }
        memcpy(qualifier, path + component_start, path_length - component_start);
        qualifier[path_length - component_start] = '\0';
        found = true;
        cursor = current - 1u;
    }
    if (!found) set_error(program, "E2S60", "consumer does not import `%s`", dependency_path);
    return found;
}

static bool kif_fact_is_callable_function(const KofunKifFact *fact) {
    return fact->kind == KOFUN_KIF_FACT_FUNCTION ||
        (fact->kind == KOFUN_KIF_FACT_EXPORT &&
         fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION);
}

static bool find_kif_function(
    Program *program,
    const KofunKifInterface *interface,
    bool package_internal,
    const Module *module,
    const Token *name,
    const KofunKifFact **fact_out
) {
    const KofunKifFact *found = NULL;
    size_t index;
    for (index = 0u; index < interface->public_fact_count; index += 1u) {
        const KofunKifFact *fact = &interface->public_facts[index];
        if (!kif_fact_is_callable_function(fact) ||
            !token_text_equals(module, name, fact->name)) continue;
        if (found != NULL) {
            set_error(program, "E2S65",
                "compiled interface has duplicate callable `%.*s`",
                (int)(name->end - name->start),
                module->source + name->start);
            return false;
        }
        found = fact;
    }
    if (package_internal) {
        for (index = 0u; index < interface->internal_fact_count;
             index += 1u) {
            const KofunKifFact *fact = &interface->internal_facts[index];
            if (fact->kind != KOFUN_KIF_FACT_FUNCTION ||
                !token_text_equals(module, name, fact->name)) continue;
            if (found != NULL) {
                set_error(program, "E2S65",
                    "compiled interface has duplicate callable `%.*s`",
                    (int)(name->end - name->start),
                    module->source + name->start);
                return false;
            }
            found = fact;
        }
    }
    *fact_out = found;
    return true;
}

static bool measure_call(
    Program *program,
    Module *module,
    size_t open,
    size_t *arity_out,
    size_t *close_out
) {
    size_t cursor;
    size_t depth = 0u;
    size_t commas = 0u;
    for (cursor = open; cursor < module->token_count; cursor += 1u) {
        Token *token = &module->tokens[cursor];
        if (punctuation_equals(module, token, '(')) {
            depth += 1u;
        } else if (punctuation_equals(module, token, ')')) {
            if (depth == 0u) break;
            depth -= 1u;
            if (depth == 0u) {
                if (cursor > open + 1u &&
                    punctuation_equals(module, &module->tokens[cursor - 1u], ',')) break;
                *arity_out = cursor == open + 1u ? 0u : commas + 1u;
                *close_out = cursor;
                return true;
            }
        } else if (depth == 1u && punctuation_equals(module, token, ',')) {
            if (cursor == open + 1u ||
                punctuation_equals(module, &module->tokens[cursor - 1u], ',')) break;
            commas += 1u;
        }
    }
    set_error(program, "E2S65", "malformed qualified call in KIF consumer");
    return false;
}

static bool collect_kif_calls(
    Program *program,
    Module *module,
    const KofunKifInterface *interface,
    bool package_internal,
    const char *qualifier,
    KifQualifiedCall **calls_out,
    size_t *count_out
) {
    KifQualifiedCall *calls = NULL;
    size_t count = 0u;
    size_t capacity = 0u;
    size_t cursor;
    for (cursor = 0u; cursor + 3u < module->token_count; cursor += 1u) {
        const KofunKifFact *fact;
        size_t arity;
        size_t close;
        if (module->tokens[cursor].kind != TOKEN_IDENTIFIER ||
            !token_text_equals(module, &module->tokens[cursor], qualifier) ||
            !punctuation_equals(module, &module->tokens[cursor + 1u], '.') ||
            module->tokens[cursor + 2u].kind != TOKEN_IDENTIFIER ||
            !punctuation_equals(module, &module->tokens[cursor + 3u], '(')) continue;
        if (!find_kif_function(program, interface, package_internal, module,
                &module->tokens[cursor + 2u], &fact)) {
            free(calls);
            return false;
        }
        if (fact == NULL) {
            set_error(program, "E2S65", "compiled interface has no accessible function `%.*s`",
                (int)(module->tokens[cursor + 2u].end - module->tokens[cursor + 2u].start),
                module->source + module->tokens[cursor + 2u].start);
            free(calls);
            return false;
        }
        if (!measure_call(program, module, cursor + 3u, &arity, &close)) {
            free(calls);
            return false;
        }
        if (arity != fact->parameter_count) {
            set_error(program, "E2S65",
                "compiled function `%s` expects %u arguments but got %zu",
                fact->name, (unsigned)fact->parameter_count, arity);
            free(calls);
            return false;
        }
        if (count == capacity) {
            size_t next = capacity == 0u ? 16u : capacity * 2u;
            KifQualifiedCall *resized;
            if (next > CALL_LIMIT) next = CALL_LIMIT;
            if (count == CALL_LIMIT ||
                (resized = realloc(calls, next * sizeof(*resized))) == NULL) {
                free(calls);
                set_error(program, "E2S68", "KIF qualified-call allocation failed");
                return false;
            }
            calls = resized;
            capacity = next;
        }
        calls[count++] = (KifQualifiedCall){
            .fact = fact,
            .arity = arity,
            .start = module->tokens[cursor].start,
            .end = module->tokens[close].end
        };
    }
    if (count == 0u) {
        free(calls);
        set_error(program, "E2S65", "consumer has no qualified call through `%s`", qualifier);
        return false;
    }
    *calls_out = calls;
    *count_out = count;
    return true;
}

static char *resolution_parent_directory(const char *path) {
    const char *slash = strrchr(path, '/');
    char *parent;
    size_t length;
    if (slash == NULL) {
        parent = malloc(2u);
        if (parent != NULL) memcpy(parent, ".", 2u);
        return parent;
    }
    length = slash == path ? 1u : (size_t)(slash - path);
    parent = malloc(length + 1u);
    if (parent == NULL) return NULL;
    memcpy(parent, path, length);
    parent[length] = '\0';
    return parent;
}

static bool function_signature_has_nominal_type(
    const KofunKifFact *fact
) {
    size_t index;
    if (type_reference_is_nominal(fact->result_type_symbol_id)) return true;
    for (index = 0u; index < fact->parameter_count; index += 1u) {
        if (fact->parameter_type_symbol_ids != NULL &&
            type_reference_is_nominal(
                fact->parameter_type_symbol_ids +
                    index * KOFUN_KIF_ID_BYTES)) {
            return true;
        }
    }
    return false;
}

static void emit_resolution_signature(
    FILE *output,
    const KofunKifFact *fact
) {
    static const uint8_t builtin_int[KOFUN_KIF_ID_BYTES] = { 0 };
    size_t index;
    if (!function_signature_has_nominal_type(fact)) {
        fprintf(output, "fn(%u:Int)->Int", (unsigned)fact->parameter_count);
        return;
    }
    fprintf(output, "fn(%u:", (unsigned)fact->parameter_count);
    for (index = 0u; index < fact->parameter_count; index += 1u) {
        const uint8_t *type_id = fact->parameter_type_symbol_ids == NULL ?
            builtin_int : fact->parameter_type_symbol_ids +
                index * KOFUN_KIF_ID_BYTES;
        if (index != 0u) fputc(',', output);
        if (type_reference_is_nominal(type_id)) {
            char type_hex[65];
            bytes_to_hex(type_id, KOFUN_KIF_ID_BYTES, type_hex);
            fprintf(output, "nominal:%s", type_hex);
        } else {
            fputs("Int", output);
        }
    }
    fputs(")->", output);
    if (type_reference_is_nominal(fact->result_type_symbol_id)) {
        char type_hex[65];
        bytes_to_hex(
            fact->result_type_symbol_id,
            KOFUN_KIF_ID_BYTES,
            type_hex
        );
        fprintf(output, "nominal:%s", type_hex);
    } else {
        fputs("Int", output);
    }
}

static void emit_resolution_labels(
    FILE *output,
    const KofunKifFact *fact
) {
    size_t index;
    for (index = 0u; index < fact->parameter_count; index += 1u) {
        const KofunKifParameterLabel *label = fact->parameter_labels == NULL
            ? NULL : &fact->parameter_labels[index];
        if (index != 0u) fputc(',', output);
        if (label == NULL || label->bytes == NULL) {
            fputs("unlabelled", output);
        } else {
            fprintf(output, "%.*s", (int)label->length, label->bytes);
        }
    }
}

static bool emit_kif_resolution(
    const KofunKifInterface *interface,
    bool package_internal,
    const char *dependency_path,
    const char *qualifier,
    const KifQualifiedCall *calls,
    size_t count,
    const char *output_path
) {
    size_t output_length = strlen(output_path);
    char *temporary = NULL;
    char *parent = NULL;
    FILE *output = NULL;
    int descriptor = -1;
    int directory = -1;
    bool temporary_exists = false;
    bool committed = false;
    char module_hex[65];
    char digest_hex[65];
    int formatted_length;
    size_t index;
    if (output_length > SIZE_MAX - 40u) return false;
    temporary = malloc(output_length + 40u);
    parent = resolution_parent_directory(output_path);
    if (temporary == NULL || parent == NULL) goto done;
    formatted_length = snprintf(temporary, output_length + 40u,
        "%s.kif-resolve-tmp.XXXXXX", output_path);
    if (formatted_length < 0 ||
        (size_t)formatted_length >= output_length + 40u) {
        goto done;
    }
    descriptor = mkstemp(temporary);
    if (descriptor < 0) goto done;
    temporary_exists = true;
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 ||
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        goto done;
    }
    output = fdopen(descriptor, "wb");
    if (output == NULL) goto done;
    descriptor = -1;
    bytes_to_hex(interface->module_id, KOFUN_KIF_ID_BYTES, module_hex);
    bytes_to_hex(package_internal ? interface->package_internal_semantic_digest
            : interface->public_semantic_digest,
        KOFUN_KIF_ID_BYTES, digest_hex);
    fprintf(output,
        "kofun-imports-qualified/v1\n"
        "compiled-interface|path=%s|module=%s|view=%s|digest=%s\n",
        dependency_path, module_hex,
        package_internal ? "package-internal" : "public", digest_hex);
    for (index = 0u; index < count; index += 1u) {
        const KofunKifFact *fact = calls[index].fact;
        char symbol_hex[65];
        if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
            char export_hex[65];
            char target_module_hex[65];
            size_t chain_index;
            bytes_to_hex(fact->symbol_id, KOFUN_KIF_ID_BYTES, export_hex);
            bytes_to_hex(fact->target_module_id, KOFUN_KIF_ID_BYTES,
                target_module_hex);
            bytes_to_hex(fact->target_symbol_id, KOFUN_KIF_ID_BYTES,
                symbol_hex);
            fprintf(output,
                "qualified-call|qualifier=%s|name=%s|binding-module=%s|"
                "export-binding=%s|target-module=%s|target-symbol=%s|"
                "arity=%zu|signature=fn(%u:Int)->Int|labels=",
                qualifier, fact->name, module_hex, export_hex,
                target_module_hex, symbol_hex, calls[index].arity,
                (unsigned)fact->parameter_count);
            emit_resolution_labels(output, fact);
            fprintf(output, "|span=%zu..%zu|chain=%zu|chain-ids=",
                calls[index].start, calls[index].end,
                fact->export_chain_count);
            for (chain_index = 0u;
                 chain_index < fact->export_chain_count;
                 chain_index += 1u) {
                char chain_hex[65];
                bytes_to_hex(fact->export_chain_ids +
                    chain_index * KOFUN_KIF_ID_BYTES,
                    KOFUN_KIF_ID_BYTES, chain_hex);
                fprintf(output, "%s%s",
                    chain_index == 0u ? "" : ",", chain_hex);
            }
            fputc('\n', output);
        } else {
            bytes_to_hex(fact->symbol_id, KOFUN_KIF_ID_BYTES, symbol_hex);
            fprintf(output,
                "qualified-call|qualifier=%s|name=%s|target-module=%s|"
                "target-symbol=%s|arity=%zu|signature=",
                qualifier, fact->name, module_hex, symbol_hex,
                calls[index].arity);
            emit_resolution_signature(output, fact);
            fputs("|labels=", output);
            emit_resolution_labels(output, fact);
            fprintf(output, "|span=%zu..%zu\n",
                calls[index].start, calls[index].end);
        }
    }
    {
        bool write_failed = ferror(output) != 0;
        bool flush_failed = fflush(output) != 0;
        bool sync_failed = !flush_failed && fsync(fileno(output)) != 0;
        int close_status = fclose(output);
        output = NULL;
        if (write_failed || flush_failed || sync_failed ||
            close_status != 0) {
            goto done;
        }
    }
#if defined(KOFUN_TEST_DIAGNOSTIC_FAULTS)
    {
        const char *fault = getenv("KOFUN_KIF_RESOLVE_FAULT");
        if (fault != NULL && strcmp(fault, "before-rename") == 0) {
            goto done;
        }
    }
#endif
    if (rename(temporary, output_path) != 0) goto done;
    temporary_exists = false;
    directory = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) goto done;
    {
        bool sync_failed = fsync(directory) != 0;
        int close_status = close(directory);
        directory = -1;
        if (sync_failed || close_status != 0) goto done;
    }
    committed = true;
done:
    if (output != NULL) (void)fclose(output);
    if (descriptor >= 0) (void)close(descriptor);
    if (directory >= 0) (void)close(directory);
    if (temporary_exists) (void)remove(temporary);
    free(temporary);
    free(parent);
    return committed;
}

static bool reject_resolution_path_alias(
    Program *program,
    const char *input_path,
    const char *output_path
) {
    struct stat input_stat;
    struct stat output_stat;
    int input_status;
    int input_error;
    int output_status;
    int output_error;
    if (strcmp(input_path, output_path) == 0) {
        set_error(program, "E2S68",
            "KIF consumer input and output paths must be distinct");
        return false;
    }
    errno = 0;
    input_status = stat(input_path, &input_stat);
    input_error = errno;
    errno = 0;
    output_status = stat(output_path, &output_stat);
    output_error = errno;
    if ((input_status != 0 && input_error != ENOENT) ||
        (output_status != 0 && output_error != ENOENT)) {
        set_error(program, "E2S68",
            "cannot validate KIF consumer input/output path identities");
        return false;
    }
    if (input_status == 0 && output_status == 0 &&
        input_stat.st_dev == output_stat.st_dev &&
        input_stat.st_ino == output_stat.st_ino) {
        set_error(program, "E2S68",
            "KIF consumer input and output paths must not alias one file");
        return false;
    }
    return true;
}

static int resolve_mode(
    const char *input_path,
    const char *consumer_package_text,
    const char *dependency_path,
    const char *consumer_path,
    const char *output_path
) {
    uint8_t *bytes = NULL;
    size_t length = 0u;
    uint8_t consumer_package[32];
    KifReadResult result;
    Program program;
    Module *module = &program.modules[0];
    char qualifier[IDENTIFIER_LIMIT + 1u];
    KifQualifiedCall *calls = NULL;
    size_t call_count = 0u;
    bool package_internal;
    int status = 1;
    memset(&program, 0, sizeof(program));
    program.module_count = 1u;
    if (!parse_identity(consumer_package_text, consumer_package)) {
        printf("error[KIF-resolve]: consumer PackageId must be 64 lowercase hexadecimal digits\n");
        return 1;
    }
    if (!reject_resolution_path_alias(&program, input_path, output_path) ||
        !reject_resolution_path_alias(&program, consumer_path,
            output_path)) {
        printf("%s\n", program.error);
        destroy_program(&program);
        return 1;
    }
    if (!read_kif_file(input_path, &bytes, &length)) {
        printf("error[KIF-io-commit-failure]: cannot read bounded KIF input\n");
        return 1;
    }
    result = kofun_kif_read(bytes, length, kofun_kif_default_limits());
    free(bytes);
    if (result.status != KOFUN_KIF_OK) {
        printf("error[KIF-%s]: %s\n", kofun_kif_status_name(result.status), result.message);
        return 1;
    }
    package_internal = memcmp(consumer_package, result.interface->package_id,
        KOFUN_KIF_ID_BYTES) == 0;
    memcpy(module->logical_path, "kif-consumer.kofun", sizeof("kif-consumer.kofun"));
    if (strlen(consumer_path) > HOST_PATH_LIMIT) {
        set_error(&program, "E2S48", "KIF consumer path exceeds adapter limit");
        goto done;
    }
    memcpy(module->host_path, consumer_path, strlen(consumer_path) + 1u);
    if (!read_source(&program, module) || !tokenize(&program, module) ||
        !parse_dependency_import(&program, module, dependency_path, qualifier) ||
        !collect_kif_calls(&program, module, result.interface, package_internal,
            qualifier, &calls, &call_count)) goto done;
    if (!emit_kif_resolution(result.interface, package_internal, dependency_path,
            qualifier, calls, call_count, output_path)) {
        set_error(&program, "E2S68", "cannot commit KIF qualified-import HIR");
        goto done;
    }
    status = 0;
done:
    if (program.failed) printf("%s\n", program.error);
    free(calls);
    destroy_program(&program);
    kofun_kif_destroy(result.interface);
    return status;
}

static KofunKifFactKind visible_target_kind(const KofunKifFact *fact) {
    if (fact->kind != KOFUN_KIF_FACT_EXPORT) return fact->kind;
    switch (fact->export_target_kind) {
        case KOFUN_KIF_EXPORT_TARGET_FUNCTION:
            return KOFUN_KIF_FACT_FUNCTION;
        case KOFUN_KIF_EXPORT_TARGET_ADT:
            return KOFUN_KIF_FACT_ADT;
        case KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR:
            return KOFUN_KIF_FACT_CONSTRUCTOR;
        case KOFUN_KIF_EXPORT_TARGET_MODULE:
            return KOFUN_KIF_FACT_EXPORT;
    }
    return 0;
}

static const uint8_t *visible_target_symbol(const KofunKifFact *fact) {
    return fact->kind == KOFUN_KIF_FACT_EXPORT
        ? fact->target_symbol_id : fact->symbol_id;
}

static bool append_kif_visible_binding(
    Program *program,
    KofunVisibleBinding *visible,
    size_t capacity,
    size_t *count,
    const uint8_t namespace_id[32],
    const uint8_t binding_id[32],
    const uint8_t target_symbol_id[32],
    const Token *name,
    KofunVisibleSiteKind site_kind
) {
    Module *module = &program->modules[0];
    KofunVisibleBinding *binding;
    if (*count >= capacity || name->end - name->start > IDENTIFIER_LIMIT) {
        set_error(program, "E2S68",
            "KIF visible-binding vector exceeds its exact bound");
        return false;
    }
    binding = &visible[(*count)++];
    memset(binding, 0, sizeof(*binding));
    memcpy(binding->resolving_module_id, module->module_id, 32u);
    memcpy(binding->namespace_id, namespace_id, 32u);
    memcpy(binding->binding_id, binding_id, 32u);
    memcpy(binding->target_symbol_id, target_symbol_id, 32u);
    binding->effective_spelling = (const uint8_t *)module->source + name->start;
    binding->effective_spelling_length = name->end - name->start;
    binding->site_kind = site_kind;
    binding->canonical_provenance = module->logical_path;
    binding->span_start = (uint32_t)name->start;
    binding->span_end = (uint32_t)name->end;
    binding->disclose_location = true;
    return true;
}

static bool collect_kif_visible_bindings(
    Program *program,
    const KofunKifInterface *interface,
    bool package_internal,
    const char *dependency_path,
    KofunVisibleBinding *visible,
    size_t capacity,
    size_t *count
) {
    Module *module = &program->modules[0];
    size_t cursor = 0u;
    size_t brace_depth = 0u;
    *count = 0u;
    while (cursor < module->token_count) {
        Token *token = &module->tokens[cursor];
        if (punctuation_equals(module, token, '{')) {
            brace_depth += 1u;
            cursor += 1u;
            continue;
        }
        if (punctuation_equals(module, token, '}')) {
            if (brace_depth != 0u) brace_depth -= 1u;
            cursor += 1u;
            continue;
        }
        if (brace_depth == 0u &&
            (token_equals(module, token, "fn") ||
             token_equals(module, token, "type"))) {
            Token *name;
            unsigned namespace_tag = token_equals(module, token, "type")
                ? 1u : 0u;
            uint8_t symbol_id[32];
            if (cursor + 1u >= module->token_count ||
                module->tokens[cursor + 1u].kind != TOKEN_IDENTIFIER) {
                set_error(program, "E2S50",
                    "KIF consumer has malformed local declaration");
                return false;
            }
            name = &module->tokens[cursor + 1u];
            {
                char spelling[IDENTIFIER_LIMIT + 1u];
                size_t length = name->end - name->start;
                memcpy(spelling, module->source + name->start, length);
                spelling[length] = '\0';
                compute_symbol_hash(module->module_id,
                    program->namespace_ids[namespace_tag],
                    namespace_tag == 0u ? "function" : "adt",
                    spelling, symbol_id);
            }
            if (!append_kif_visible_binding(program, visible, capacity,
                    count, program->namespace_ids[namespace_tag], symbol_id,
                    symbol_id, name, KOFUN_VISIBLE_SITE_LOCAL)) return false;
            cursor += 2u;
            continue;
        }
        if (brace_depth == 0u && token_equals(module, token, "from")) {
            char path[HOST_PATH_LIMIT + 1u];
            size_t path_length = 0u;
            size_t current = cursor + 1u;
            bool expect_identifier = true;
            while (current < module->token_count &&
                   !module->tokens[current].line_break_before) {
                Token *part = &module->tokens[current];
                if (!expect_identifier && token_equals(module, part, "import")) {
                    current += 1u;
                    break;
                }
                if (expect_identifier) {
                    size_t length;
                    if (part->kind != TOKEN_IDENTIFIER) break;
                    length = part->end - part->start;
                    if (path_length != 0u) path[path_length++] = '.';
                    if (path_length + length > HOST_PATH_LIMIT) break;
                    memcpy(path + path_length,
                        module->source + part->start, length);
                    path_length += length;
                } else if (!punctuation_equals(module, part, '.')) {
                    break;
                }
                expect_identifier = !expect_identifier;
                current += 1u;
            }
            path[path_length] = '\0';
            if (path_length == 0u || strcmp(path, dependency_path) != 0) {
                set_error(program, "E2S60",
                    "KIF selective consumer has no supplied interface for `%s`",
                    path);
                return false;
            }
            while (current < module->token_count &&
                   !module->tokens[current].line_break_before) {
                Token *name = &module->tokens[current];
                bool found = false;
                size_t index;
                if (name->kind != TOKEN_IDENTIFIER ||
                    token_equals(module, name, "as")) {
                    set_error(program, "E2S59",
                        "malformed KIF selective import list");
                    return false;
                }
                for (index = 0u; index < interface->public_fact_count +
                        (package_internal ? interface->internal_fact_count : 0u);
                     index += 1u) {
                    const KofunKifFact *fact =
                        index < interface->public_fact_count
                        ? &interface->public_facts[index]
                        : &interface->internal_facts[
                            index - interface->public_fact_count];
                    KofunKifFactKind kind;
                    if (!token_text_equals(module, name, fact->name)) continue;
                    kind = visible_target_kind(fact);
                    if (kind != KOFUN_KIF_FACT_FUNCTION &&
                        kind != KOFUN_KIF_FACT_ADT &&
                        kind != KOFUN_KIF_FACT_CONSTRUCTOR) continue;
                    if (!append_kif_visible_binding(program, visible,
                            capacity, count, fact->namespace_id,
                            fact->symbol_id, visible_target_symbol(fact),
                            name, KOFUN_VISIBLE_SITE_IMPORT)) return false;
                    found = true;
                }
                if (!found) {
                    set_error(program, "E2S65",
                        "compiled interface has no accessible selective binding `%.*s`",
                        (int)(name->end - name->start),
                        module->source + name->start);
                    return false;
                }
                current += 1u;
                if (current >= module->token_count ||
                    module->tokens[current].line_break_before) break;
                if (!punctuation_equals(module,
                        &module->tokens[current], ',')) {
                    set_error(program, "E2S59",
                        "KIF selective names require commas");
                    return false;
                }
                current += 1u;
            }
            cursor = current;
            continue;
        }
        cursor += 1u;
    }
    return true;
}

static int resolve_visible_mode(
    const char *input_path,
    const char *consumer_package_text,
    const char *consumer_module_text,
    const char *dependency_path,
    const char *consumer_path,
    const char *output_path
) {
    uint8_t *bytes = NULL;
    size_t length = 0u;
    uint8_t consumer_package[32];
    uint8_t consumer_module[32];
    KifReadResult read;
    Program program;
    Module *module = &program.modules[0];
    KofunVisibleBinding *visible = NULL;
    KofunVisibleConfusableDiagnostic *diagnostics = NULL;
    size_t visible_count = 0u;
    size_t capacity;
    bool package_internal;
    KofunVisibleConfusableResult result;
    int status = 1;
    memset(&program, 0, sizeof(program));
    program.module_count = 1u;
    if (!parse_identity(consumer_package_text, consumer_package) ||
        !parse_identity(consumer_module_text, consumer_module)) {
        printf("error[KIF-resolve-visible]: consumer PackageId and ModuleId must be canonical\n");
        return 1;
    }
    if (!reject_resolution_path_alias(&program, input_path, output_path) ||
        !reject_resolution_path_alias(&program, consumer_path, output_path)) {
        printf("%s\n", program.error);
        destroy_program(&program);
        return 1;
    }
    if (!read_kif_file(input_path, &bytes, &length)) {
        printf("error[KIF-io-commit-failure]: cannot read bounded KIF input\n");
        return 1;
    }
    read = kofun_kif_read(bytes, length, kofun_kif_default_limits());
    free(bytes);
    if (read.status != KOFUN_KIF_OK) {
        printf("error[KIF-%s]: %s\n",
            kofun_kif_status_name(read.status), read.message);
        return 1;
    }
    package_internal = memcmp(consumer_package, read.interface->package_id,
        KOFUN_KIF_ID_BYTES) == 0;
    memcpy(module->package_id, consumer_package, 32u);
    memcpy(module->module_id, consumer_module, 32u);
    memcpy(module->logical_path, "kif-consumer.kofun",
        sizeof("kif-consumer.kofun"));
    if (strlen(consumer_path) > HOST_PATH_LIMIT) {
        set_error(&program, "E2S48", "KIF consumer path exceeds adapter limit");
        goto done;
    }
    memcpy(module->host_path, consumer_path, strlen(consumer_path) + 1u);
    if (!read_source(&program, module) || !tokenize(&program, module)) goto done;
    compute_identities(&program);
    capacity = module->token_count + read.interface->public_fact_count +
        read.interface->internal_fact_count;
    visible = calloc(capacity == 0u ? 1u : capacity, sizeof(*visible));
    diagnostics = calloc(capacity == 0u ? 1u : capacity,
        sizeof(*diagnostics));
    if (visible == NULL || diagnostics == NULL) {
        set_error(&program, "EUNICODE007",
            "KIF visible-set allocation failed");
        goto done;
    }
    if (!collect_kif_visible_bindings(&program, read.interface,
            package_internal, dependency_path, visible, capacity,
            &visible_count)) goto done;
    result = kofun_check_visible_confusables(visible, visible_count,
        diagnostics, capacity);
    if (result.status == KOFUN_VISIBLE_CONFUSABLE_COLLISION) {
        KofunVisibleConfusableDiagnostic *diagnostic = &diagnostics[0];
        KofunVisibleBinding *primary = &visible[diagnostic->primary_binding];
        KofunVisibleBinding *related =
            &visible[diagnostic->related_bindings[0]];
        printf("error[EUNICODE008]: effective spelling `%.*s` in `%s` at bytes %u..%u is confusable in one visible namespace; related `%.*s` at `%s` bytes %u..%u\n",
            (int)primary->effective_spelling_length,
            (const char *)primary->effective_spelling,
            primary->canonical_provenance,
            primary->span_start, primary->span_end,
            (int)related->effective_spelling_length,
            (const char *)related->effective_spelling,
            related->canonical_provenance,
            related->span_start, related->span_end);
        goto done;
    }
    if (result.status != KOFUN_VISIBLE_CONFUSABLE_OK) {
        set_error(&program,
            result.status == KOFUN_VISIBLE_CONFUSABLE_RESOURCE_FAILURE
                ? "EUNICODE007" : "E2S68",
            "KIF visible-set check failed: %s",
            kofun_visible_confusable_status_name(result.status));
        goto done;
    }
    if (!emit_kif_resolution(read.interface, package_internal,
            dependency_path, "selective-visible", NULL, 0u,
            output_path)) {
        set_error(&program, "E2S68",
            "cannot commit KIF selective-visible HIR");
        goto done;
    }
    status = 0;
done:
    if (program.failed) printf("%s\n", program.error);
    free(diagnostics);
    free(visible);
    destroy_program(&program);
    kofun_kif_destroy(read.interface);
    return status;
}

int main(int argc, char **argv) {
    /* Keep the included collector's standalone projection compiled and audited. */
    (void)emit_output;
    if (argc >= 2 && strcmp(argv[1], "write") == 0) {
        if (argc != 6 && argc != 7) {
            fprintf(stderr, "usage: %s write INVENTORY MODULE_ID EDITION OUTPUT [DUMP]\n", argv[0]);
            return 2;
        }
        return write_mode(argv[2], argv[3], argv[4], argv[5], argc == 7 ? argv[6] : NULL);
    }
    if (argc >= 2 && strcmp(argv[1], "read") == 0) {
        if (argc != 3 && argc != 4) {
            fprintf(stderr, "usage: %s read INPUT [DUMP]\n", argv[0]);
            return 2;
        }
        return read_mode(argv[2], argc == 4 ? argv[3] : NULL);
    }
    if (argc >= 2 && strcmp(argv[1], "resolve") == 0) {
        if (argc != 7) {
            fprintf(stderr,
                "usage: %s resolve KIF CONSUMER_PACKAGE_ID DEPENDENCY_PATH CONSUMER OUTPUT_HIR\n",
                argv[0]);
            return 2;
        }
        return resolve_mode(argv[2], argv[3], argv[4], argv[5], argv[6]);
    }
    if (argc >= 2 && strcmp(argv[1], "resolve-visible") == 0) {
        if (argc != 8) {
            fprintf(stderr,
                "usage: %s resolve-visible KIF CONSUMER_PACKAGE_ID CONSUMER_MODULE_ID DEPENDENCY_PATH CONSUMER OUTPUT_HIR\n",
                argv[0]);
            return 2;
        }
        return resolve_visible_mode(argv[2], argv[3], argv[4], argv[5],
            argv[6], argv[7]);
    }
    fprintf(stderr,
        "usage: %s write INVENTORY MODULE_ID EDITION OUTPUT [DUMP]\n"
        "       %s read INPUT [DUMP]\n"
        "       %s resolve KIF CONSUMER_PACKAGE_ID DEPENDENCY_PATH CONSUMER OUTPUT_HIR\n"
        "       %s resolve-visible KIF CONSUMER_PACKAGE_ID CONSUMER_MODULE_ID DEPENDENCY_PATH CONSUMER OUTPUT_HIR\n",
        argv[0], argv[0], argv[0], argv[0]);
    return 2;
}
