/*
 * Bounded production adapter from the executable Stage 2 semantic passes to
 * immutable semantic events. This file deliberately reuses the audited Stage
 * 2 lexer/parser/scope/ownership implementation in the same translation unit;
 * it does not scrape command output or expose compiler-private records.
 */
#include "semantic_producer.h"
#include "sha256.h"
#include "effect_inference.h"

#define main kofun_stage2_embedded_seed_main
#define KOFUN_STAGE2_AUTHORITY_API 1
#include "compiler.c"
#undef KOFUN_STAGE2_AUTHORITY_API
#undef main

#include <errno.h>

enum {
    PRODUCER_MAX_NODES = 512,
    PRODUCER_MAX_IDENTITIES = 512,
    PRODUCER_MAX_REFERENCES = 1024,
    PRODUCER_MAX_FACTS = 1024,
    PRODUCER_MAX_DIAGNOSTICS = 128,
    PRODUCER_MAX_FUNCTIONS = 64,
    PRODUCER_MAX_TYPES = 48,
    PRODUCER_MAX_CONSTRUCTORS = 128,
    PRODUCER_MAX_BINDINGS = 256,
    PRODUCER_IDENTIFIER_CAPACITY = 257
};

enum {
    PRODUCER_EVENT_NONE = 0,
    PRODUCER_EVENT_SOURCE = 1,
    PRODUCER_EVENT_NODE = 2,
    PRODUCER_EVENT_IDENTITY = 3,
    PRODUCER_EVENT_REFERENCE = 4,
    PRODUCER_EVENT_FACT = 5,
    PRODUCER_EVENT_DIAGNOSTIC = 6,
    PRODUCER_EVENT_END = 7
};

typedef struct {
    KofunSemanticNode value;
    KofunSemanticId dependencies[KOFUN_SEMANTIC_MAX_RELATIONS];
    KofunSemanticId diagnostic;
    KofunSemanticId discovery_type_identity;
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    char type[PRODUCER_IDENTIFIER_CAPACITY];
    bool is_declaration;
    bool has_discovery_type_identity;
} ProducerNode;

typedef struct {
    KofunSemanticIdentity value;
} ProducerIdentity;

typedef struct {
    KofunSemanticReference value;
    KofunSemanticId diagnostic;
} ProducerReference;

typedef struct {
    KofunSemanticFact value;
    char display[160];
    char reason[160];
    KofunSemanticId dependencies[KOFUN_SEMANTIC_MAX_RELATIONS];
    KofunSemanticId diagnostic;
} ProducerFact;

typedef struct {
    KofunSemanticDiagnostic value;
    char code[16];
    char category[32];
    char template_id[64];
    char fallback[160];
    KofunSemanticId affected[4];
    uint32_t remedies[4];
    KofunSemanticRelated related[4];
    char related_labels[4][64];
    KofunSemanticEdit edits[4];
    char replacements[4][64];
} ProducerDiagnostic;

typedef struct {
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    char return_type[PRODUCER_IDENTIFIER_CAPACITY];
    KofunSemanticId node;
    KofunSemanticId symbol;
    int64_t start;
    int64_t body_open;
    int64_t end;
    KofunStage2InterfaceVisibility visibility;
    uint16_t parameter_count;
    bool duplicate;
} ProducerFunction;

typedef struct {
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    KofunSemanticId node;
    KofunSemanticId symbol;
    int64_t start;
    int64_t end;
    KofunStage2InterfaceVisibility visibility;
    KofunStage2InterfaceFactKind kind;
} ProducerType;

typedef struct {
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    char result_type[PRODUCER_IDENTIFIER_CAPACITY];
    char payload_type[PRODUCER_IDENTIFIER_CAPACITY];
    KofunSemanticId node;
    KofunSemanticId symbol;
    KofunSemanticId owner_symbol;
    int64_t start;
    int64_t end;
    KofunStage2InterfaceVisibility visibility;
    uint8_t payload_count;
    uint32_t ordinal;
} ProducerConstructor;

typedef struct {
    char hir_id[24];
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    char type[PRODUCER_IDENTIFIER_CAPACITY];
    char ownership[32];
    KofunSemanticId node;
    KofunSemanticId binding;
    KofunSemanticId type_identity;
    int64_t function_start;
    int64_t declaration_start;
    bool has_type_identity;
} ProducerBinding;

typedef struct {
    const KofunStage2SemanticInput *input;
    const char *source;
    const char *scope_hir;
    const char *declaration_observations;
    const char *semantic_observations;
    KofunSemanticSource source_record;
    KofunSemanticId value_namespace_id;
    KofunSemanticId type_namespace_id;
    ProducerNode nodes[PRODUCER_MAX_NODES];
    size_t node_count;
    ProducerIdentity identities[PRODUCER_MAX_IDENTITIES];
    size_t identity_count;
    ProducerReference references[PRODUCER_MAX_REFERENCES];
    size_t reference_count;
    ProducerFact facts[PRODUCER_MAX_FACTS];
    size_t fact_count;
    ProducerDiagnostic diagnostics[PRODUCER_MAX_DIAGNOSTICS];
    size_t diagnostic_count;
    ProducerFunction functions[PRODUCER_MAX_FUNCTIONS];
    size_t function_count;
    ProducerType types[PRODUCER_MAX_TYPES];
    size_t type_count;
    ProducerConstructor constructors[PRODUCER_MAX_CONSTRUCTORS];
    size_t constructor_count;
    ProducerBinding bindings[PRODUCER_MAX_BINDINGS];
    size_t binding_count;
    bool language_failed;
    bool resource_failed;
    uint8_t compiler_exit_class;
    uint32_t reference_limit;
} Producer;

static void producer_set_tooling_error(
    KofunStage2SemanticResult *result,
    const char *code,
    uint32_t record_index,
    uint8_t event_kind,
    const char *detail
) {
    if (result == NULL) return;
    result->tooling_emission_failed = true;
    memset(&result->tooling_error, 0, sizeof(result->tooling_error));
    (void)snprintf(
        result->tooling_error.code,
        sizeof(result->tooling_error.code),
        "%s",
        code
    );
    result->tooling_error.record_index = record_index;
    result->tooling_error.event_kind = event_kind;
    (void)snprintf(
        result->tooling_error.detail,
        sizeof(result->tooling_error.detail),
        "%s",
        detail
    );
}

static KofunSemanticBytes producer_text(const char *value) {
    KofunSemanticBytes text_value;
    text_value.bytes = (const uint8_t *)value;
    text_value.length = (uint32_t)strlen(value);
    return text_value;
}

static bool producer_interface_visibility(
    const char *text,
    KofunStage2InterfaceVisibility *visibility
) {
    if (strcmp(text, "public") == 0) {
        *visibility = KOFUN_STAGE2_INTERFACE_PUBLIC;
        return true;
    }
    if (strcmp(text, "internal") == 0) {
        *visibility = KOFUN_STAGE2_INTERFACE_INTERNAL;
        return true;
    }
    if (strcmp(text, "private") == 0) {
        *visibility = KOFUN_STAGE2_INTERFACE_PRIVATE;
        return true;
    }
    return false;
}

static bool producer_copy_authority_diagnostic(
    const Stage2AuthorityContext *context,
    size_t source_length,
    KofunStage2SemanticResult *result
) {
    const Stage2StructuredDiagnostic *diagnostic = &context->diagnostic;
    if (!diagnostic->present ||
        diagnostic->code[0] == '\0' ||
        diagnostic->category[0] == '\0' ||
        diagnostic->template_id[0] == '\0' ||
        diagnostic->fallback[0] == '\0' ||
        (diagnostic->has_byte_span &&
         (diagnostic->start < 0 ||
          diagnostic->end < diagnostic->start ||
          (uint64_t)diagnostic->end > source_length))) {
        return false;
    }
    result->has_source_diagnostic = true;
    result->diagnostic_has_byte_span = diagnostic->has_byte_span;
    result->diagnostic_truncated = diagnostic->truncated;
    (void)snprintf(
        result->diagnostic_code,
        sizeof(result->diagnostic_code),
        "%s",
        diagnostic->code
    );
    (void)snprintf(
        result->diagnostic_category,
        sizeof(result->diagnostic_category),
        "%s",
        diagnostic->category
    );
    (void)snprintf(
        result->diagnostic_template_id,
        sizeof(result->diagnostic_template_id),
        "%s",
        diagnostic->template_id
    );
    (void)snprintf(
        result->diagnostic_fallback,
        sizeof(result->diagnostic_fallback),
        "%s",
        diagnostic->fallback
    );
    result->diagnostic_span.start = diagnostic->has_byte_span ?
        (uint32_t)diagnostic->start : 0u;
    result->diagnostic_span.end = diagnostic->has_byte_span ?
        (uint32_t)diagnostic->end : 0u;
    return true;
}

static void producer_hash(
    const char *domain,
    const uint8_t *bytes,
    size_t length,
    KofunSemanticId *result
) {
    KofunSha256 sha;
    uint8_t u16[2];
    uint8_t u32[4];
    static const uint8_t prefix[6] = {'K', 'O', 'F', 'U', 'N', 0u};
    size_t domain_length = strlen(domain);
    if (domain_length > UINT16_MAX || length > UINT32_MAX) {
        memset(result, 0, sizeof(*result));
        return;
    }
    u16[0] = (uint8_t)(domain_length >> 8u);
    u16[1] = (uint8_t)domain_length;
    u32[0] = (uint8_t)(length >> 24u);
    u32[1] = (uint8_t)(length >> 16u);
    u32[2] = (uint8_t)(length >> 8u);
    u32[3] = (uint8_t)length;
    kofun_sha256_init(&sha);
    kofun_sha256_update(&sha, prefix, sizeof(prefix));
    kofun_sha256_update(&sha, u16, sizeof(u16));
    kofun_sha256_update(
        &sha,
        (const uint8_t *)domain,
        domain_length
    );
    kofun_sha256_update(&sha, u32, sizeof(u32));
    kofun_sha256_update(&sha, bytes, length);
    kofun_sha256_finish(&sha, result->bytes);
}

static void producer_named_id(
    const Producer *producer,
    const char *domain,
    const char *name,
    KofunSemanticId *result
) {
    uint8_t payload[KOFUN_SEMANTIC_ID_BYTES + 160u];
    size_t name_length = strlen(name);
    if (name_length > 160u) name_length = 160u;
    memcpy(
        payload,
        producer->source_record.file_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    memcpy(payload + KOFUN_SEMANTIC_ID_BYTES, name, name_length);
    producer_hash(
        domain,
        payload,
        KOFUN_SEMANTIC_ID_BYTES + name_length,
        result
    );
}

static void producer_write_field(
    uint8_t **cursor,
    uint16_t tag,
    const uint8_t *value,
    size_t length
) {
    uint8_t *at = *cursor;
    at[0] = (uint8_t)(tag >> 8u);
    at[1] = (uint8_t)tag;
    at[2] = (uint8_t)(length >> 24u);
    at[3] = (uint8_t)(length >> 16u);
    at[4] = (uint8_t)(length >> 8u);
    at[5] = (uint8_t)length;
    if (length != 0u) memcpy(at + 6u, value, length);
    *cursor = at + 6u + length;
}

static void producer_namespace_id(
    unsigned tag,
    const char *name,
    KofunSemanticId *result
) {
    char payload[96];
    int length = snprintf(
        payload,
        sizeof(payload),
        "kofun.namespace-id/v1\ntag=%u\nname=%s\n",
        tag,
        name
    );
    if (length < 0 || (size_t)length >= sizeof(payload)) {
        memset(result, 0, sizeof(*result));
        return;
    }
    producer_hash(
        "kofun.id.namespace/v1",
        (const uint8_t *)payload,
        (size_t)length,
        result
    );
}

static bool producer_symbol_id(
    const Producer *producer,
    const KofunSemanticId *namespace_id,
    const char *declaration_kind,
    const char *name,
    KofunSemanticId *result
) {
    size_t kind_length = strlen(declaration_kind);
    size_t name_length = strlen(name);
    size_t payload_length;
    uint8_t *payload;
    uint8_t *cursor;
    if (kind_length > UINT32_MAX || name_length > UINT32_MAX ||
        kind_length > SIZE_MAX - name_length - 88u) {
        return false;
    }
    payload_length = 88u + kind_length + name_length;
    payload = (uint8_t *)malloc(payload_length);
    if (payload == NULL) return false;
    cursor = payload;
    producer_write_field(
        &cursor,
        UINT16_C(0x8001),
        producer->source_record.module_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    producer_write_field(
        &cursor,
        UINT16_C(0x8002),
        namespace_id->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    producer_write_field(
        &cursor,
        UINT16_C(0x8003),
        (const uint8_t *)declaration_kind,
        kind_length
    );
    producer_write_field(
        &cursor,
        UINT16_C(0x8004),
        (const uint8_t *)name,
        name_length
    );
    if ((size_t)(cursor - payload) != payload_length) {
        free(payload);
        return false;
    }
    producer_hash(
        "kofun.id.symbol/v1",
        payload,
        payload_length,
        result
    );
    free(payload);
    return true;
}

static void copy_token_text(
    const char *source,
    int64_t start,
    char *output,
    size_t output_size
) {
    int64_t end = token_end(source, start);
    size_t length = end > start ? (size_t)(end - start) : 0u;
    if (length >= output_size) length = output_size - 1u;
    if (length != 0u) memcpy(output, source + start, length);
    output[length] = '\0';
}

/*
 * The declaration profile, and what it reports when a source is outside it.
 *
 * `ETS04: semantic producer declaration limit exceeded` named neither which of
 * the two limits was reached, nor the bound, nor where. A reader could not
 * tell whether to split the program, shorten a function, or stop trying, and
 * the first thing anyone did with the message was re-derive it by bisecting
 * the source -- which is the work the diagnostic exists to save.
 *
 * The counts are lexical tokens rather than declarations: a `fn` inside a
 * lambda counts, and so does a `let` in any scope. That is a deliberately
 * conservative proxy for the fixed arrays downstream, so the message says
 * `fn tokens` rather than `functions` -- naming what was counted keeps a
 * reader from splitting a file by top-level declarations and finding the
 * limit unmoved.
 */
static bool producer_source_within_declaration_profile(
    const char *source,
    const char **limit_name,
    size_t *limit_bound,
    size_t *limit_count,
    int64_t *limit_offset
) {
    int64_t length = (int64_t)strlen(source);
    int64_t cursor = skip_trivia(source, 0);
    size_t functions = 0u;
    size_t bindings = 0u;
    while (cursor < length) {
        int64_t end = token_end(source, cursor);
        if (end <= cursor) return true;
        if (token_equal(source, cursor, "fn")) {
            functions += 1u;
            if (functions > PRODUCER_MAX_FUNCTIONS) {
                *limit_name = "fn tokens";
                *limit_bound = PRODUCER_MAX_FUNCTIONS;
                *limit_count = functions;
                *limit_offset = cursor;
                return false;
            }
        }
        if (token_equal(source, cursor, "let") ||
            token_equal(source, cursor, "for")) {
            bindings += 1u;
            if (bindings > PRODUCER_MAX_BINDINGS) {
                *limit_name = "let/for tokens";
                *limit_bound = PRODUCER_MAX_BINDINGS;
                *limit_count = bindings;
                *limit_offset = cursor;
                return false;
            }
        }
        cursor = skip_trivia(source, end);
    }
    return true;
}

static bool producer_publication_surface_supported(
    const char *source,
    KofunStage2SemanticResult *result
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        int64_t declaration;
        int64_t name;
        int64_t after_name;
        int64_t parameters_end;
        int64_t part;
        if (!token_equal(source, cursor, "pub") &&
            !token_equal(source, cursor, "internal")) {
            cursor = skip_trivia(source, token_end(source, cursor));
            continue;
        }
        declaration = skip_trivia(source, token_end(source, cursor));
        if (token_equal(source, declaration, "async") ||
            token_equal(source, declaration, "effect") ||
            token_equal(source, declaration, "throws")) {
            producer_set_tooling_error(
                result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                "KIF v2 does not support effect components in published signatures"
            );
            return false;
        }
        if (!token_equal(source, declaration, "fn")) {
            cursor = declaration;
            continue;
        }
        name = skip_trivia(source, token_end(source, declaration));
        after_name = skip_trivia(source, token_end(source, name));
        if (token_equal(source, after_name, "[")) {
            producer_set_tooling_error(
                result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                "KIF v2 does not support generic components in published signatures"
            );
            return false;
        }
        if (!token_equal(source, after_name, "(")) {
            cursor = after_name;
            continue;
        }
        parameters_end = balanced_end(source, after_name, "(", ")");
        if (parameters_end < 0) {
            cursor = after_name;
            continue;
        }
        part = skip_trivia(source, token_end(source, after_name));
        while (part < parameters_end) {
            if (token_equal(source, part, "read") ||
                token_equal(source, part, "edit") ||
                token_equal(source, part, "take")) {
                producer_set_tooling_error(
                    result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                    "KIF v2 does not support ownership modes in published signatures"
                );
                return false;
            }
            part = skip_trivia(source, token_end(source, part));
        }
        cursor = parameters_end;
    }
    return true;
}

static KofunSemanticSpan producer_span(int64_t start, int64_t end) {
    KofunSemanticSpan span;
    span.start = start < 0 ? 0u : (uint32_t)start;
    span.end = end < start ? span.start : (uint32_t)end;
    return span;
}

static ProducerNode *producer_add_node(
    Producer *producer,
    KofunSemanticNodeKind kind,
    int64_t start,
    int64_t end,
    const char *name,
    bool declaration
) {
    ProducerNode *node;
    uint32_t occurrence = 0u;
    size_t index;
    if (producer->node_count >= PRODUCER_MAX_NODES) {
        producer->resource_failed = true;
        return NULL;
    }
    for (index = 0u; index < producer->node_count; index += 1u) {
        const ProducerNode *candidate = &producer->nodes[index];
        if (candidate->value.kind == kind &&
            candidate->value.span.start == producer_span(start, end).start &&
            candidate->value.span.end == producer_span(start, end).end) {
            occurrence += 1u;
        }
    }
    node = &producer->nodes[producer->node_count];
    memset(node, 0, sizeof(*node));
    node->value.kind = kind;
    node->value.span = producer_span(start, end);
    node->value.status = KOFUN_SEMANTIC_VALIDATED;
    kofun_semantic_derive_id(
        "kofun.sidecar.node/v1",
        &producer->source_record.file_id,
        kind,
        node->value.span,
        occurrence,
        &node->value.node_id
    );
    if (name != NULL) {
        (void)snprintf(node->name, sizeof(node->name), "%s", name);
    }
    node->is_declaration = declaration;
    producer->node_count += 1u;
    return node;
}

static bool producer_add_stable_identity(
    Producer *producer,
    KofunSemanticId owner,
    KofunSemanticIdentityKind kind,
    const KofunSemanticId *value
) {
    ProducerIdentity *identity;
    if (producer->identity_count >= PRODUCER_MAX_IDENTITIES) {
        producer->resource_failed = true;
        return false;
    }
    identity = &producer->identities[producer->identity_count++];
    memset(identity, 0, sizeof(*identity));
    identity->value.owner_node_id = owner;
    identity->value.kind = kind;
    identity->value.status = KOFUN_SEMANTIC_VALIDATED;
    identity->value.value = *value;
    return true;
}

static bool producer_add_identity(
    Producer *producer,
    KofunSemanticId owner,
    KofunSemanticIdentityKind kind,
    const char *domain,
    const char *name,
    KofunSemanticId *result
) {
    KofunSemanticId value;
    producer_named_id(
        producer,
        domain,
        name,
        &value
    );
    if (result != NULL) *result = value;
    return producer_add_stable_identity(producer, owner, kind, &value);
}

static ProducerFact *producer_add_fact(
    Producer *producer,
    KofunSemanticId owner,
    KofunSemanticFactKind kind,
    KofunSemanticStatus status,
    const char *display,
    const char *reason
) {
    ProducerFact *fact;
    if (producer->fact_count >= PRODUCER_MAX_FACTS) {
        producer->resource_failed = true;
        return NULL;
    }
    fact = &producer->facts[producer->fact_count++];
    memset(fact, 0, sizeof(*fact));
    fact->value.owner_node_id = owner;
    fact->value.kind = kind;
    fact->value.status = status;
    (void)snprintf(fact->display, sizeof(fact->display), "%s", display);
    (void)snprintf(fact->reason, sizeof(fact->reason), "%s", reason);
    fact->value.display = producer_text(fact->display);
    fact->value.reason = producer_text(fact->reason);
    return fact;
}

static ProducerNode *producer_find_node_by_id(
    Producer *producer,
    const KofunSemanticId *node_id
) {
    size_t index;
    for (index = 0u; index < producer->node_count; index += 1u) {
        if (memcmp(
                producer->nodes[index].value.node_id.bytes,
                node_id->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return &producer->nodes[index];
        }
    }
    return NULL;
}

static ProducerNode *producer_find_dependency_node(
    Producer *producer,
    int64_t start,
    int64_t end
) {
    size_t index;
    for (index = 0u; index < producer->node_count; index += 1u) {
        ProducerNode *node = &producer->nodes[index];
        if ((node->value.kind == KOFUN_SEMANTIC_NODE_REFERENCE ||
             node->value.kind == KOFUN_SEMANTIC_NODE_CALL) &&
            node->value.span.start == (uint32_t)start &&
            node->value.span.end == (uint32_t)end) {
            return node;
        }
    }
    return NULL;
}

static int producer_id_compare(const void *left, const void *right) {
    return memcmp(
        ((const KofunSemanticId *)left)->bytes,
        ((const KofunSemanticId *)right)->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
}

static bool producer_node_add_dependency(
    ProducerNode *node,
    const KofunSemanticId *dependency
) {
    uint16_t index;
    for (index = 0u; index < node->value.dependency_count; index += 1u) {
        if (memcmp(
                node->dependencies[index].bytes,
                dependency->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return true;
        }
    }
    if (node->value.dependency_count >=
        KOFUN_SEMANTIC_MAX_RELATIONS) {
        return false;
    }
    node->dependencies[node->value.dependency_count++] = *dependency;
    qsort(
        node->dependencies,
        node->value.dependency_count,
        sizeof(node->dependencies[0]),
        producer_id_compare
    );
    node->value.dependencies = node->dependencies;
    return true;
}

static bool producer_fact_add_dependency(
    ProducerFact *fact,
    const KofunSemanticId *dependency
) {
    uint16_t index;
    for (index = 0u; index < fact->value.dependency_count; index += 1u) {
        if (memcmp(
                fact->dependencies[index].bytes,
                dependency->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return true;
        }
    }
    if (fact->value.dependency_count >=
        KOFUN_SEMANTIC_MAX_RELATIONS) {
        return false;
    }
    fact->dependencies[fact->value.dependency_count++] = *dependency;
    qsort(
        fact->dependencies,
        fact->value.dependency_count,
        sizeof(fact->dependencies[0]),
        producer_id_compare
    );
    fact->value.dependencies = fact->dependencies;
    return true;
}

static ProducerFact *producer_find_fact(
    Producer *producer,
    const KofunSemanticId *owner,
    KofunSemanticFactKind kind
) {
    size_t index;
    for (index = 0u; index < producer->fact_count; index += 1u) {
        ProducerFact *fact = &producer->facts[index];
        if (fact->value.kind == kind &&
            memcmp(
                fact->value.owner_node_id.bytes,
                owner->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return fact;
        }
    }
    return NULL;
}

static ProducerDiagnostic *producer_add_diagnostic(
    Producer *producer,
    const char *code,
    const char *category,
    const char *template_id,
    const char *fallback,
    KofunSemanticSpan span,
    KofunSemanticId affected
) {
    ProducerDiagnostic *diagnostic;
    char key[256];
    if (producer->diagnostic_count >= PRODUCER_MAX_DIAGNOSTICS) {
        producer->resource_failed = true;
        return NULL;
    }
    diagnostic = &producer->diagnostics[producer->diagnostic_count++];
    memset(diagnostic, 0, sizeof(*diagnostic));
    (void)snprintf(diagnostic->code, sizeof(diagnostic->code), "%s", code);
    (void)snprintf(
        diagnostic->category,
        sizeof(diagnostic->category),
        "%s",
        category
    );
    (void)snprintf(
        diagnostic->template_id,
        sizeof(diagnostic->template_id),
        "%s",
        template_id
    );
    if (snprintf(
        diagnostic->fallback,
        sizeof(diagnostic->fallback),
        "%s",
        fallback
    ) >= (int)sizeof(diagnostic->fallback)) {
        diagnostic->value.truncated = true;
    }
    (void)snprintf(
        key,
        sizeof(key),
        "%s:%" PRIu32 ":%" PRIu32,
        code,
        span.start,
        span.end
    );
    producer_named_id(
        producer,
        "kofun.semantic.diagnostic/v1",
        key,
        &diagnostic->value.diagnostic_id
    );
    diagnostic->value.code = producer_text(diagnostic->code);
    diagnostic->value.category = producer_text(diagnostic->category);
    diagnostic->value.severity = KOFUN_SEMANTIC_DIAGNOSTIC_ERROR;
    diagnostic->value.template_id = producer_text(diagnostic->template_id);
    diagnostic->value.primary_file_id = producer->source_record.file_id;
    diagnostic->value.primary_span = span;
    diagnostic->value.fallback_text = producer_text(diagnostic->fallback);
    diagnostic->affected[0] = affected;
    diagnostic->value.affected_ids = diagnostic->affected;
    diagnostic->value.affected_count = 1u;
    producer->language_failed = true;
    return diagnostic;
}

static ProducerFunction *producer_find_function(
    Producer *producer,
    const char *name
) {
    size_t index;
    for (index = 0u; index < producer->function_count; index += 1u) {
        if (strcmp(producer->functions[index].name, name) == 0) {
            return &producer->functions[index];
        }
    }
    return NULL;
}

static ProducerConstructor *producer_find_constructor(
    Producer *producer,
    const char *name
) {
    size_t index;
    for (index = 0u; index < producer->constructor_count; index += 1u) {
        if (strcmp(producer->constructors[index].name, name) == 0) {
            return &producer->constructors[index];
        }
    }
    return NULL;
}

static ProducerBinding *producer_find_binding_by_hir_id(
    Producer *producer,
    const char *hir_id
) {
    size_t index;
    for (index = 0u; index < producer->binding_count; index += 1u) {
        ProducerBinding *binding = &producer->bindings[index];
        if (strcmp(binding->hir_id, hir_id) == 0) return binding;
    }
    return NULL;
}

static ProducerBinding *producer_add_hir_binding(
    Producer *producer,
    ProducerFunction *function,
    const char *hir_id,
    const char *name,
    const char *type_name,
    const char *ownership,
    int64_t start,
    int64_t end,
    KofunSemanticNodeKind node_kind
) {
    ProducerBinding *binding;
    ProducerNode *node;
    char key[160];
    if (producer->binding_count >= PRODUCER_MAX_BINDINGS) {
        producer->resource_failed = true;
        return NULL;
    }
    node = producer_add_node(
        producer,
        node_kind,
        start,
        end,
        name,
        true
    );
    if (node == NULL) return NULL;
    binding = &producer->bindings[producer->binding_count++];
    memset(binding, 0, sizeof(*binding));
    (void)snprintf(
        binding->hir_id,
        sizeof(binding->hir_id),
        "%s",
        hir_id
    );
    (void)snprintf(binding->name, sizeof(binding->name), "%s", name);
    (void)snprintf(binding->type, sizeof(binding->type), "%s", type_name);
    (void)snprintf(
        binding->ownership,
        sizeof(binding->ownership),
        "%s",
        ownership
    );
    binding->node = node->value.node_id;
    binding->function_start = function->start;
    binding->declaration_start = start;
    (void)snprintf(
        key,
        sizeof(key),
        "hir-binding:%s",
        hir_id
    );
    if (!producer_add_identity(
            producer,
            binding->node,
            KOFUN_SEMANTIC_ID_BINDING,
            "kofun.stage2.binding/v1",
            key,
            &binding->binding)) {
        return NULL;
    }
    if (producer_add_fact(
            producer,
            binding->node,
            KOFUN_SEMANTIC_FACT_TYPE,
            strcmp(type_name, "unavailable") == 0 ?
                KOFUN_SEMANTIC_UNAVAILABLE :
                KOFUN_SEMANTIC_VALIDATED,
            strcmp(type_name, "unavailable") == 0 ? "" : type_name,
            strcmp(type_name, "unavailable") == 0 ?
                "type-not-available-in-current-subset" : "") == NULL ||
        producer_add_fact(
            producer,
            binding->node,
            KOFUN_SEMANTIC_FACT_OWNERSHIP,
            KOFUN_SEMANTIC_VALIDATED,
            ownership,
            "") == NULL) {
        return NULL;
    }
    return binding;
}

static bool producer_collect_type_records(
    Producer *producer,
    const char *program_ir,
    const char *record_kind,
    const char *declaration_kind
) {
    int64_t line = hir_record_start(program_ir, record_kind, 0);
    int64_t source_length = (int64_t)producer->input->source_length;
    while (line >= 0) {
        char *name = hir_field(program_ir, line, 1);
        char *start_text = hir_field(program_ir, line, 3);
        char *end_text = hir_field(program_ir, line, 4);
        char *visibility_text = hir_field(program_ir, line, 5);
        int64_t start = decimal_value(start_text);
        int64_t end = decimal_value(end_text);
        ProducerNode *type_node;
        ProducerType *type;
        KofunSemanticId type_symbol;
        KofunStage2InterfaceVisibility visibility;
        bool valid = name[0] != '\0' &&
            strlen(name) < PRODUCER_IDENTIFIER_CAPACITY &&
            start >= 0 && end > start && end <= source_length &&
            producer_interface_visibility(visibility_text, &visibility) &&
            producer->type_count < PRODUCER_MAX_TYPES;
        if (!valid) {
            free(name);
            free(start_text);
            free(end_text);
            free(visibility_text);
            producer->resource_failed =
                producer->type_count >= PRODUCER_MAX_TYPES;
            return false;
        }
        type_node = producer_add_node(
            producer,
            KOFUN_SEMANTIC_NODE_ADT,
            start,
            end,
            name,
            true
        );
        if (type_node == NULL ||
            !producer_symbol_id(
                producer,
                &producer->type_namespace_id,
                declaration_kind,
                name,
                &type_symbol) ||
            !producer_add_stable_identity(
                producer,
                type_node->value.node_id,
                KOFUN_SEMANTIC_ID_TYPE,
                &type_symbol)) {
            free(name);
            free(start_text);
            free(end_text);
            free(visibility_text);
            return false;
        }
        type = &producer->types[producer->type_count++];
        memset(type, 0, sizeof(*type));
        (void)snprintf(type->name, sizeof(type->name), "%s", name);
        type->node = type_node->value.node_id;
        type->symbol = type_symbol;
        type->start = start;
        type->end = end;
        type->visibility = visibility;
        type->kind = strcmp(record_kind, "record") == 0 ?
            KOFUN_STAGE2_INTERFACE_RECORD : KOFUN_STAGE2_INTERFACE_ADT;
        free(name);
        free(start_text);
        free(end_text);
        free(visibility_text);
        line = hir_record_start(program_ir, record_kind, line + 1);
    }
    return true;
}

static ProducerType *producer_find_type(Producer *producer, const char *name) {
    size_t index;
    for (index = 0u; index < producer->type_count; index += 1u) {
        if (strcmp(producer->types[index].name, name) == 0) {
            return &producer->types[index];
        }
    }
    return NULL;
}

/*
 * Bounded compiler identity owner for builtin and constructed type
 * references (#637).
 *
 * The catalog is closed: the scalar builtins `Int` and `Text`, and the
 * builtin generic head `List` applied to exactly one scalar builtin
 * argument.  Identity bytes derive from the language-owned catalog entry
 * and, for a constructed reference, from the component TypeIds — never from
 * the file, the module, or the source spelling — so `List[Text]` names one
 * TypeId in every module, and a rendered display can never be promoted into
 * an identity this owner did not issue.  This owner is deliberately separate
 * from the declaration-owned nominal propagation above it in
 * `producer_collect_scopes_and_bindings`: a current-file ADT keeps the
 * symbol its declaration committed, and neither mechanism widens the other.
 */
static bool producer_builtin_type_id(
    const char *name,
    KofunSemanticId *out
) {
    if (strcmp(name, "Int") != 0 && strcmp(name, "Text") != 0 &&
        strcmp(name, "List") != 0) {
        return false;
    }
    producer_hash(
        "kofun.stage2.builtin-type/v1",
        (const uint8_t *)name,
        strlen(name),
        out
    );
    return true;
}

static void producer_constructed_type_id(
    const KofunSemanticId *head,
    const KofunSemanticId *argument,
    KofunSemanticId *out
) {
    uint8_t payload[12u + 2u * KOFUN_SEMANTIC_ID_BYTES];
    uint8_t *cursor = payload;
    producer_write_field(
        &cursor,
        UINT16_C(0x8001),
        head->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    producer_write_field(
        &cursor,
        UINT16_C(0x8002),
        argument->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    producer_hash(
        "kofun.stage2.constructed-type/v1",
        payload,
        (size_t)(cursor - payload),
        out
    );
}

static bool producer_bounded_type_reference_id(
    Producer *producer,
    const char *type_name,
    KofunSemanticId *out
) {
    const char *open = strchr(type_name, '[');
    const char *argument;
    size_t argument_length;
    char argument_name[PRODUCER_IDENTIFIER_CAPACITY];
    KofunSemanticId head_id;
    KofunSemanticId argument_id;
    if (open == NULL) {
        /* A bare generic head is not a complete type reference. */
        return strcmp(type_name, "List") != 0 &&
            producer_find_type(producer, type_name) == NULL &&
            producer_builtin_type_id(type_name, out);
    }
    argument = open + 1u;
    argument_length = strlen(argument);
    if (argument_length < 2u ||
        argument[argument_length - 1u] != ']' ||
        argument_length - 1u >= sizeof(argument_name)) {
        return false;
    }
    argument_length -= 1u;
    if (memchr(argument, '[', argument_length) != NULL ||
        memchr(argument, ']', argument_length) != NULL ||
        memchr(argument, ',', argument_length) != NULL) {
        return false;
    }
    memcpy(argument_name, argument, argument_length);
    argument_name[argument_length] = '\0';
    /*
     * A current-file declaration of either component always shadows the
     * builtin catalog: the declaration owns that identity, and this owner
     * must not answer for a name it does not define.
     */
    if ((size_t)(open - type_name) != strlen("List") ||
        strncmp(type_name, "List", strlen("List")) != 0 ||
        strcmp(argument_name, "List") == 0 ||
        producer_find_type(producer, "List") != NULL ||
        producer_find_type(producer, argument_name) != NULL ||
        !producer_builtin_type_id("List", &head_id) ||
        !producer_builtin_type_id(argument_name, &argument_id)) {
        return false;
    }
    producer_constructed_type_id(&head_id, &argument_id, out);
    return true;
}

static bool producer_collect_types(
    Producer *producer,
    const char *program_ir
) {
    int64_t line;
    int64_t source_length = (int64_t)producer->input->source_length;
    if (!producer_collect_type_records(
            producer, program_ir, "type", "adt") ||
        !producer_collect_type_records(
            producer, program_ir, "record", "record")) {
        return false;
    }
    line = hir_record_start(program_ir, "constructor", 0);
    while (line >= 0) {
        char *name = hir_field(program_ir, line, 1);
        char *owner = hir_field(program_ir, line, 2);
        char *start_text = hir_field(program_ir, line, 4);
        char *end_text = hir_field(program_ir, line, 5);
        char *ordinal_text = hir_field(program_ir, line, 3);
        char *payload_count_text = hir_field(program_ir, line, 6);
        char *payload_type = hir_field(program_ir, line, 7);
        int64_t start = decimal_value(start_text);
        int64_t end = decimal_value(end_text);
        int64_t ordinal = decimal_value(ordinal_text);
        int64_t payload_count = decimal_value(payload_count_text);
        ProducerNode *node;
        ProducerConstructor *constructor;
        ProducerType *owner_type = producer_find_type(producer, owner);
        KofunSemanticId symbol;
        bool valid = name[0] != '\0' && owner[0] != '\0' &&
            strlen(name) < PRODUCER_IDENTIFIER_CAPACITY &&
            strlen(owner) < PRODUCER_IDENTIFIER_CAPACITY &&
            start >= 0 && end > start && end <= source_length &&
            owner_type != NULL && ordinal >= 0 && ordinal <= UINT32_MAX &&
            (payload_count == 0 ||
             (payload_count == 1 && payload_type[0] != '\0' &&
              strlen(payload_type) < PRODUCER_IDENTIFIER_CAPACITY)) &&
            producer->constructor_count < PRODUCER_MAX_CONSTRUCTORS;
        if (!valid) {
            free(name);
            free(owner);
            free(start_text);
            free(end_text);
            free(ordinal_text);
            free(payload_count_text);
            free(payload_type);
            producer->resource_failed =
                producer->constructor_count >= PRODUCER_MAX_CONSTRUCTORS;
            return false;
        }
        node = producer_add_node(
            producer,
            KOFUN_SEMANTIC_NODE_CONSTRUCTOR,
            start,
            end,
            name,
            true
        );
        constructor =
            &producer->constructors[producer->constructor_count++];
        memset(constructor, 0, sizeof(*constructor));
        (void)snprintf(
            constructor->name,
            sizeof(constructor->name),
            "%s",
            name
        );
        (void)snprintf(
            constructor->result_type,
            sizeof(constructor->result_type),
            "%s",
            owner
        );
        (void)snprintf(
            constructor->payload_type,
            sizeof(constructor->payload_type),
            "%s",
            payload_count == 0 ? "" : payload_type
        );
        if (node == NULL ||
            !producer_symbol_id(
                producer,
                &producer->value_namespace_id,
                "constructor",
                name,
                &symbol) ||
            !producer_add_stable_identity(
                producer,
                node->value.node_id,
                KOFUN_SEMANTIC_ID_CONSTRUCTOR,
                &symbol)) {
            free(name);
            free(owner);
            free(start_text);
            free(end_text);
            free(ordinal_text);
            free(payload_count_text);
            free(payload_type);
            return false;
        }
        constructor->node = node->value.node_id;
        constructor->symbol = symbol;
        constructor->owner_symbol = owner_type->symbol;
        constructor->start = start;
        constructor->end = end;
        constructor->visibility = owner_type->visibility;
        constructor->payload_count = (uint8_t)payload_count;
        constructor->ordinal = (uint32_t)ordinal;
        free(name);
        free(owner);
        free(start_text);
        free(end_text);
        free(ordinal_text);
        free(payload_count_text);
        free(payload_type);
        line = hir_record_start(program_ir, "constructor", line + 1);
    }
    return true;
}

static int64_t producer_hir_function_body_open(
    const Producer *producer,
    int64_t function_start
) {
    int64_t line;
    if (producer->scope_hir == NULL) return -1;
    line = hir_record_start(producer->scope_hir, "hir-function", 0);
    while (line >= 0) {
        char *start_text = hir_field(producer->scope_hir, line, 1);
        bool found = decimal_value(start_text) == function_start;
        free(start_text);
        if (found) {
            char *body_scope = hir_field(producer->scope_hir, line, 3);
            char *open_text = hir_scope_field(
                producer->scope_hir,
                body_scope,
                4
            );
            int64_t open = decimal_value(open_text);
            free(body_scope);
            free(open_text);
            return open;
        }
        line = hir_record_start(
            producer->scope_hir,
            "hir-function",
            line + 1
        );
    }
    return -1;
}

static char *producer_function_return_type(
    const Producer *producer,
    int64_t function_start
) {
    int64_t line = hir_record_start(
        producer->declaration_observations,
        "function",
        0
    );
    while (line >= 0) {
        char *start_text = hir_field(
            producer->declaration_observations,
            line,
            2
        );
        bool found = decimal_value(start_text) == function_start;
        free(start_text);
        if (found) {
            return hir_field(
                producer->declaration_observations,
                line,
                4
            );
        }
        line = hir_record_start(
            producer->declaration_observations,
            "function",
            line + 1
        );
    }
    return owned_text("");
}

static bool producer_collect_functions(
    Producer *producer,
    const char *program_ir
) {
    int64_t line = hir_record_start(program_ir, "function", 0);
    int64_t source_length = (int64_t)producer->input->source_length;
    while (line >= 0) {
        char *name = hir_field(program_ir, line, 1);
        char *start_text = hir_field(program_ir, line, 3);
        char *end_text = hir_field(program_ir, line, 4);
        char *visibility_text = hir_field(program_ir, line, 5);
        int64_t start = decimal_value(start_text);
        int64_t end = decimal_value(end_text);
        char *return_type = producer_function_return_type(
            producer,
            start
        );
        bool duplicate =
            producer_find_function(producer, name) != NULL;
        int64_t body_open = producer_hir_function_body_open(producer, start);
        ProducerNode *node;
        ProducerFunction *function;
        KofunStage2InterfaceVisibility visibility;
        bool body_available =
            body_open >= start && body_open < end;
        bool scope_suffix_unavailable =
            producer->compiler_exit_class != 0u &&
            body_open < 0 &&
            (uint64_t)start >= producer->reference_limit;
        bool valid = name[0] != '\0' && return_type[0] != '\0' &&
            strlen(name) < PRODUCER_IDENTIFIER_CAPACITY &&
            strlen(return_type) < PRODUCER_IDENTIFIER_CAPACITY &&
            producer_interface_visibility(visibility_text, &visibility) &&
            start >= 0 && end > start && end <= source_length &&
            (producer->scope_hir == NULL ||
             body_available || scope_suffix_unavailable) &&
            producer->function_count < PRODUCER_MAX_FUNCTIONS;
        if (!valid) {
            free(name);
            free(start_text);
            free(end_text);
            free(return_type);
            free(visibility_text);
            producer->resource_failed =
                producer->function_count >= PRODUCER_MAX_FUNCTIONS;
            return false;
        }
        node = producer_add_node(
            producer,
            KOFUN_SEMANTIC_NODE_FUNCTION,
            start,
            end,
            name,
            true
        );
        function = &producer->functions[producer->function_count++];
        memset(function, 0, sizeof(*function));
        (void)snprintf(
            function->name,
            sizeof(function->name),
            "%s",
            name
        );
        (void)snprintf(
            function->return_type,
            sizeof(function->return_type),
            "%s",
            return_type
        );
        function->node = node == NULL ?
            (KofunSemanticId){{0}} : node->value.node_id;
        function->start = start;
        function->body_open = body_open;
        function->end = end;
        function->visibility = visibility;
        function->duplicate = duplicate;
        if (node == NULL ||
            !producer_symbol_id(
                producer,
                &producer->value_namespace_id,
                "function",
                function->name,
                &function->symbol) ||
            (!duplicate &&
             !producer_add_stable_identity(
                 producer,
                 function->node,
                 KOFUN_SEMANTIC_ID_SYMBOL,
                 &function->symbol))) {
            free(name);
            free(start_text);
            free(end_text);
            free(return_type);
            free(visibility_text);
            return false;
        }
        free(name);
        free(start_text);
        free(end_text);
        free(return_type);
        free(visibility_text);
        line = hir_record_start(program_ir, "function", line + 1);
    }
    return true;
}

static ProducerReference *producer_add_reference(
    Producer *producer,
    ProducerNode *source_node,
    KofunSemanticNamespace name_space,
    KofunSemanticSpan span,
    KofunSemanticIdentityKind target_kind,
    const KofunSemanticId *target
);

static bool producer_add_failed_reference_prefix(
    Producer *producer,
    const KofunStage2SemanticResult *result
) {
    char name[PRODUCER_IDENTIFIER_CAPACITY];
    ProducerNode *call;
    if (strcmp(result->diagnostic_code, "E2S16") != 0 ||
        !result->diagnostic_has_byte_span ||
        result->diagnostic_span.start >= producer->input->source_length) {
        return true;
    }
    copy_token_text(
        producer->source,
        (int64_t)result->diagnostic_span.start,
        name,
        sizeof(name)
    );
    call = producer_add_node(
        producer,
        KOFUN_SEMANTIC_NODE_CALL,
        (int64_t)result->diagnostic_span.start,
        (int64_t)result->diagnostic_span.end,
        name,
        false
    );
    return call != NULL &&
        producer_add_reference(
            producer,
            call,
            KOFUN_SEMANTIC_NAMESPACE_VALUE,
            call->value.span,
            KOFUN_SEMANTIC_ID_SYMBOL,
            NULL
        ) != NULL;
}

static bool producer_add_authority_diagnostic(
    Producer *producer,
    const KofunStage2SemanticResult *result,
    const Stage2AuthorityContext *context
) {
    ProducerNode *owner = NULL;
    ProducerDiagnostic *diagnostic;
    size_t index;
    const Stage2StructuredDiagnostic *structured =
        &context->diagnostic;
    const Stage2DiagnosticAffected *affected =
        structured->affected_count == 0u ?
            NULL : &structured->affected[0];
    KofunSemanticNodeKind selected_kind =
        KOFUN_SEMANTIC_NODE_ERROR_PATTERN;
    if (affected != NULL &&
        affected->kind == STAGE2_DIAGNOSTIC_AFFECTED_MODULE) {
        selected_kind = KOFUN_SEMANTIC_NODE_MODULE;
    } else if (affected != NULL &&
               affected->kind == STAGE2_DIAGNOSTIC_AFFECTED_CALL) {
        selected_kind = KOFUN_SEMANTIC_NODE_CALL;
    } else if (affected != NULL &&
               affected->kind == STAGE2_DIAGNOSTIC_AFFECTED_BINDING) {
        selected_kind = KOFUN_SEMANTIC_NODE_LOCAL;
    }
    if (affected != NULL) {
        for (index = 0u; index < producer->node_count; index += 1u) {
            ProducerNode *candidate = &producer->nodes[index];
            bool binding_kind =
                selected_kind == KOFUN_SEMANTIC_NODE_LOCAL &&
                (candidate->value.kind == KOFUN_SEMANTIC_NODE_LOCAL ||
                 candidate->value.kind == KOFUN_SEMANTIC_NODE_PARAMETER);
            if ((candidate->value.kind == selected_kind || binding_kind) &&
                candidate->value.span.start ==
                    (uint32_t)affected->start &&
                candidate->value.span.end ==
                    (uint32_t)affected->end) {
                owner = candidate;
                break;
            }
        }
    }
    if (owner == NULL && affected != NULL &&
        affected->kind != STAGE2_DIAGNOSTIC_AFFECTED_MODULE) {
        owner = producer_add_node(
            producer,
            selected_kind,
            affected->start,
            affected->end,
            result->diagnostic_code,
            false
        );
    }
    if (owner == NULL && producer->node_count != 0u) {
        owner = &producer->nodes[0];
    }
    if (owner == NULL || !result->has_source_diagnostic ||
        result->diagnostic_code[0] == '\0') {
        return false;
    }
    diagnostic = producer_add_diagnostic(
        producer,
        result->diagnostic_code,
        result->diagnostic_category,
        result->diagnostic_template_id,
        result->diagnostic_fallback,
        result->diagnostic_span,
        owner->value.node_id
    );
    if (diagnostic != NULL && result->diagnostic_truncated) {
        diagnostic->value.truncated = true;
    }
    if (diagnostic != NULL) {
        for (index = 0u;
             index < structured->related_count &&
                 index < sizeof(diagnostic->related) /
                     sizeof(diagnostic->related[0]);
             index += 1u) {
            diagnostic->related[index].file_id =
                producer->source_record.file_id;
            diagnostic->related[index].span = producer_span(
                structured->related[index].start,
                structured->related[index].end
            );
            (void)snprintf(
                diagnostic->related_labels[index],
                sizeof(diagnostic->related_labels[index]),
                "%s",
                structured->related[index].label
            );
            diagnostic->related[index].label = producer_text(
                diagnostic->related_labels[index]
            );
        }
        diagnostic->value.related = diagnostic->related;
        diagnostic->value.related_count = structured->related_count;
        for (index = 0u;
             index < structured->remedy_count &&
                 index < sizeof(diagnostic->remedies) /
                     sizeof(diagnostic->remedies[0]);
             index += 1u) {
            diagnostic->remedies[index] = structured->remedies[index];
        }
        diagnostic->value.remedy_ids = diagnostic->remedies;
        diagnostic->value.remedy_count = structured->remedy_count;
        for (index = 0u;
             index < structured->edit_count &&
                 index < sizeof(diagnostic->edits) /
                     sizeof(diagnostic->edits[0]);
             index += 1u) {
            diagnostic->edits[index].remedy_id =
                structured->edits[index].remedy_id;
            diagnostic->edits[index].file_id =
                producer->source_record.file_id;
            diagnostic->edits[index].span = producer_span(
                structured->edits[index].start,
                structured->edits[index].end
            );
            (void)snprintf(
                diagnostic->replacements[index],
                sizeof(diagnostic->replacements[index]),
                "%s",
                structured->edits[index].replacement
            );
            diagnostic->edits[index].replacement = producer_text(
                diagnostic->replacements[index]
            );
        }
        diagnostic->value.edits = diagnostic->edits;
        diagnostic->value.edit_count = structured->edit_count;
        owner->value.status = KOFUN_SEMANTIC_ERROR;
        owner->diagnostic = diagnostic->value.diagnostic_id;
        owner->value.diagnostic_ids = &owner->diagnostic;
        owner->value.diagnostic_count = 1u;
        if (strcmp(result->diagnostic_code, "E2S16") == 0) {
            for (index = 0u;
                 index < producer->function_count;
                 index += 1u) {
                ProducerFunction *function =
                    &producer->functions[index];
                ProducerNode *duplicate_node;
                if (!function->duplicate) continue;
                duplicate_node = producer_find_node_by_id(
                    producer,
                    &function->node
                );
                if (duplicate_node == NULL) return false;
                duplicate_node->value.status =
                    KOFUN_SEMANTIC_ERROR;
                duplicate_node->diagnostic =
                    diagnostic->value.diagnostic_id;
                duplicate_node->value.diagnostic_ids =
                    &duplicate_node->diagnostic;
                duplicate_node->value.diagnostic_count = 1u;
                if (diagnostic->value.affected_count <
                    sizeof(diagnostic->affected) /
                        sizeof(diagnostic->affected[0])) {
                    diagnostic->affected[
                        diagnostic->value.affected_count++
                    ] = duplicate_node->value.node_id;
                    qsort(
                        diagnostic->affected,
                        diagnostic->value.affected_count,
                        sizeof(diagnostic->affected[0]),
                        producer_id_compare
                    );
                }
            }
        }
        for (index = 0u; index < producer->reference_count; index += 1u) {
            ProducerReference *reference = &producer->references[index];
            if (memcmp(
                    reference->value.source_node_id.bytes,
                    owner->value.node_id.bytes,
                    KOFUN_SEMANTIC_ID_BYTES) == 0) {
                reference->diagnostic = diagnostic->value.diagnostic_id;
                reference->value.diagnostic_ids = &reference->diagnostic;
                reference->value.diagnostic_count = 1u;
            }
        }
    }
    return diagnostic != NULL;
}

static ProducerFunction *producer_function_for_offset(
    Producer *producer,
    int64_t offset
) {
    size_t index;
    for (index = 0u; index < producer->function_count; index += 1u) {
        ProducerFunction *function = &producer->functions[index];
        if (function->start <= offset && offset < function->end) {
            return function;
        }
    }
    return NULL;
}

static ProducerFunction *producer_function_for_node(
    Producer *producer,
    const KofunSemanticId *node_id
) {
    size_t index;
    for (index = 0u; index < producer->function_count; index += 1u) {
        ProducerFunction *function = &producer->functions[index];
        if (memcmp(
                function->node.bytes,
                node_id->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return function;
        }
    }
    return NULL;
}

static bool producer_function_has_print(
    const Producer *producer,
    const ProducerFunction *function
) {
    int64_t cursor = skip_trivia(producer->source, function->body_open);
    while (cursor >= 0 && cursor < function->end) {
        int64_t next = token_end(producer->source, cursor);
        if (token_equal(producer->source, cursor, "print")) {
            int64_t open = skip_trivia(producer->source, next);
            if (open < function->end &&
                token_equal(producer->source, open, "(")) {
                return true;
            }
        }
        if (next <= cursor) return false;
        cursor = skip_trivia(producer->source, next);
    }
    return false;
}

static bool producer_add_effect_facts(Producer *producer) {
    KofunEffectGraph graph;
    KofunEffectResult result;
    size_t function_index;
    size_t node_index;
    memset(&graph, 0, sizeof(graph));
    graph.function_count = producer->function_count;
    if (graph.function_count == 0u ||
        graph.function_count > KOFUN_EFFECT_MAX_FUNCTIONS) {
        return false;
    }
    for (function_index = 0u;
         function_index < graph.function_count;
         function_index += 1u) {
        ProducerFunction *function = &producer->functions[function_index];
        graph.names[function_index] = function->name;
        graph.direct_io[function_index] =
            producer_function_has_print(producer, function);
    }
    for (node_index = 0u;
         node_index < producer->node_count;
         node_index += 1u) {
        ProducerNode *call = &producer->nodes[node_index];
        ProducerFunction *caller;
        uint16_t dependency_index;
        if (call->value.kind != KOFUN_SEMANTIC_NODE_CALL) continue;
        caller = producer_function_for_offset(
            producer,
            (int64_t)call->value.span.start
        );
        if (caller == NULL) return false;
        for (dependency_index = 0u;
             dependency_index < call->value.dependency_count;
             dependency_index += 1u) {
            ProducerFunction *callee = producer_function_for_node(
                producer,
                &call->dependencies[dependency_index]
            );
            if (callee != NULL) {
                size_t caller_index = (size_t)(caller - producer->functions);
                size_t callee_index = (size_t)(callee - producer->functions);
                graph.calls[caller_index][callee_index] = true;
            }
        }
    }
    if (!kofun_effect_infer(&graph, &result)) return false;
    for (function_index = 0u;
         function_index < graph.function_count;
         function_index += 1u) {
        ProducerFunction *function = &producer->functions[function_index];
        bool direct = graph.direct_io[function_index];
        size_t callee_index = result.forcing_callee[function_index];
        ProducerFact *fact = producer_add_fact(
            producer,
            function->node,
            KOFUN_SEMANTIC_FACT_EFFECT,
            KOFUN_SEMANTIC_VALIDATED,
            result.effects[function_index] == KOFUN_EFFECT_IO ? "io" : "pure",
            result.effects[function_index] == KOFUN_EFFECT_PURE ? "" :
                (direct ? KOFUN_SEMANTIC_REASON_EFFECT_IO_ROOT_PRINT :
                    KOFUN_SEMANTIC_REASON_EFFECT_IO_CALLEE)
        );
        if (fact == NULL) return false;
        if (!direct && result.effects[function_index] == KOFUN_EFFECT_IO) {
            if (callee_index >= graph.function_count ||
                !producer_fact_add_dependency(
                    fact,
                    &producer->functions[callee_index].node)) {
                return false;
            }
        }
    }
    return true;
}

static bool producer_collect_scopes_and_bindings(Producer *producer) {
    int64_t line = hir_record_start(producer->scope_hir, "scope", 0);
    int64_t source_length = (int64_t)producer->input->source_length;
    while (line >= 0) {
        char *scope_id = hir_field(producer->scope_hir, line, 1);
        char *scope_kind = hir_field(producer->scope_hir, line, 3);
        char *open_text = hir_field(producer->scope_hir, line, 4);
        char *close_text = hir_field(producer->scope_hir, line, 5);
        int64_t open = decimal_value(open_text);
        int64_t close = decimal_value(close_text);
        ProducerNode *scope_node;
        char key[96];
        bool valid = scope_id[0] != '\0' &&
            scope_kind[0] != '\0' &&
            open >= 0 && close >= open && close <= source_length &&
            strlen(scope_id) < 24u &&
            strlen(scope_kind) < 64u;
        if (!valid) {
            free(scope_id);
            free(scope_kind);
            free(open_text);
            free(close_text);
            return false;
        }
        scope_node = producer_add_node(
            producer,
            KOFUN_SEMANTIC_NODE_SCOPE,
            open,
            close,
            scope_kind,
            true
        );
        (void)snprintf(key, sizeof(key), "hir-scope:%s", scope_id);
        if (scope_node == NULL ||
            !producer_add_identity(
                producer,
                scope_node->value.node_id,
                KOFUN_SEMANTIC_ID_SCOPE,
                "kofun.stage2.scope/v1",
                key,
                NULL)) {
            free(scope_id);
            free(scope_kind);
            free(open_text);
            free(close_text);
            return false;
        }
        free(scope_id);
        free(scope_kind);
        free(open_text);
        free(close_text);
        line = hir_record_start(producer->scope_hir, "scope", line + 1);
    }

    line = hir_record_start(producer->scope_hir, "binding", 0);
    while (line >= 0) {
        char *binding_id = hir_field(producer->scope_hir, line, 1);
        char *scope_id = hir_field(producer->scope_hir, line, 2);
        char *name = hir_field(producer->scope_hir, line, 3);
        char *type_name = hir_field(producer->scope_hir, line, 5);
        char *ownership = hir_field(producer->scope_hir, line, 6);
        char *start_text = hir_field(producer->scope_hir, line, 8);
        char *end_text = hir_field(producer->scope_hir, line, 9);
        char *scope_kind = hir_scope_field(
            producer->scope_hir,
            scope_id,
            3
        );
        int64_t start = decimal_value(start_text);
        int64_t end = decimal_value(end_text);
        ProducerFunction *function = producer_function_for_offset(
            producer,
            start
        );
        ProducerBinding *binding = NULL;
        ProducerType *nominal_type = NULL;
        KofunSemanticNodeKind node_kind =
            strcmp(scope_kind, "parameters") == 0 ?
                KOFUN_SEMANTIC_NODE_PARAMETER :
                KOFUN_SEMANTIC_NODE_LOCAL;
        bool valid = binding_id[0] != '\0' &&
            scope_id[0] != '\0' &&
            name[0] != '\0' &&
            type_name[0] != '\0' &&
            ownership[0] != '\0' &&
            start >= 0 && end >= start && end <= source_length &&
            function != NULL &&
            strlen(binding_id) < 24u &&
            strlen(name) < PRODUCER_IDENTIFIER_CAPACITY &&
            strlen(type_name) < PRODUCER_IDENTIFIER_CAPACITY &&
            strlen(ownership) < 32u;
        if (valid) {
            binding = producer_add_hir_binding(
                producer,
                function,
                binding_id,
                name,
                type_name,
                ownership,
                start,
                end,
                node_kind
            );
        }
        if (!valid || binding == NULL) {
            free(binding_id);
            free(scope_id);
            free(name);
            free(type_name);
            free(ownership);
            free(start_text);
            free(end_text);
            free(scope_kind);
            return false;
        }
        nominal_type = producer_find_type(producer, type_name);
        {
            KofunSemanticId reference_id;
            bool has_reference_id = false;
            if (nominal_type != NULL) {
                if (nominal_type->kind == KOFUN_STAGE2_INTERFACE_ADT) {
                    /*
                     * The semantic identity record stays uniquely owned by
                     * the type declaration. Discovery copies that
                     * compiler-issued value into its caller-owned snapshot;
                     * emitting a second identity record for the binding
                     * would give one stable identity two owners.
                     */
                    reference_id = nominal_type->symbol;
                    has_reference_id = true;
                }
            } else if (producer_bounded_type_reference_id(
                           producer, type_name, &reference_id)) {
                /*
                 * Builtin/constructed references have no declaration in this
                 * file; their identity comes from the bounded catalog owner,
                 * which a current-file declaration of the same name always
                 * shadows above.
                 */
                has_reference_id = true;
            }
            if (has_reference_id) {
                ProducerNode *binding_node = producer_find_node_by_id(
                    producer,
                    &binding->node
                );
                if (binding_node == NULL) {
                    free(binding_id);
                    free(scope_id);
                    free(name);
                    free(type_name);
                    free(ownership);
                    free(start_text);
                    free(end_text);
                    free(scope_kind);
                    return false;
                }
                binding->has_type_identity = true;
                binding->type_identity = reference_id;
                binding_node->has_discovery_type_identity = true;
                binding_node->discovery_type_identity = reference_id;
            }
        }
        free(binding_id);
        free(scope_id);
        free(name);
        free(type_name);
        free(ownership);
        free(start_text);
        free(end_text);
        free(scope_kind);
        line = hir_record_start(producer->scope_hir, "binding", line + 1);
    }
    return true;
}

static bool producer_finalize_function_types(Producer *producer) {
    size_t function_index;
    for (function_index = 0u;
         function_index < producer->function_count;
         function_index += 1u) {
        ProducerFunction *function = &producer->functions[function_index];
        const ProducerBinding *parameters[PRODUCER_MAX_BINDINGS];
        size_t parameter_count = 0u;
        size_t binding_index;
        char signature[160];
        size_t used = 0u;
        ProducerFact *fact;
        for (binding_index = 0u;
             binding_index < producer->binding_count;
             binding_index += 1u) {
            const ProducerBinding *binding =
                &producer->bindings[binding_index];
            ProducerNode *node = producer_find_node_by_id(
                producer,
                &binding->node
            );
            if (binding->function_start == function->start &&
                node != NULL &&
                node->value.kind == KOFUN_SEMANTIC_NODE_PARAMETER) {
                parameters[parameter_count++] = binding;
            }
        }
        if (parameter_count == 0u) {
            int written = snprintf(
                signature,
                sizeof(signature),
                "() -> %s",
                function->return_type
            );
            if (written < 0 || (size_t)written >= sizeof(signature)) {
                return false;
            }
        } else if (parameter_count == 1u) {
            int written = snprintf(
                signature,
                sizeof(signature),
                "%s -> %s",
                parameters[0]->type,
                function->return_type
            );
            if (written < 0 || (size_t)written >= sizeof(signature)) {
                return false;
            }
        } else {
            signature[used++] = '(';
            signature[used] = '\0';
            for (binding_index = 0u;
                 binding_index < parameter_count;
                 binding_index += 1u) {
                int written = snprintf(
                    signature + used,
                    sizeof(signature) - used,
                    "%s%s",
                    binding_index == 0u ? "" : ", ",
                    parameters[binding_index]->type
                );
                if (written < 0 ||
                    (size_t)written >= sizeof(signature) - used) {
                    return false;
                }
                used += (size_t)written;
            }
            {
                int written = snprintf(
                    signature + used,
                    sizeof(signature) - used,
                    ") -> %s",
                    function->return_type
                );
                if (written < 0 ||
                    (size_t)written >= sizeof(signature) - used) {
                    return false;
                }
            }
        }
        if (parameter_count > UINT16_MAX) return false;
        function->parameter_count = (uint16_t)parameter_count;
        fact = producer_add_fact(
            producer,
            function->node,
            KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED,
            signature,
            ""
        );
        if (fact == NULL) return false;
        if (parameter_count != 0u) {
            ProducerNode *function_node = producer_find_node_by_id(
                producer,
                &function->node
            );
            if (function_node == NULL ||
                parameter_count > KOFUN_SEMANTIC_MAX_RELATIONS) {
                return false;
            }
            for (binding_index = 0u;
                 binding_index < parameter_count;
                 binding_index += 1u) {
                if (!producer_node_add_dependency(
                        function_node,
                        &parameters[binding_index]->node) ||
                    !producer_fact_add_dependency(
                        fact,
                        &parameters[binding_index]->node)) {
                    return false;
                }
            }
        }
    }
    return true;
}

static ProducerReference *producer_add_reference(
    Producer *producer,
    ProducerNode *source_node,
    KofunSemanticNamespace name_space,
    KofunSemanticSpan span,
    KofunSemanticIdentityKind target_kind,
    const KofunSemanticId *target
) {
    ProducerReference *reference;
    char key[96];
    if (producer->reference_count >= PRODUCER_MAX_REFERENCES) {
        producer->resource_failed = true;
        return NULL;
    }
    reference = &producer->references[producer->reference_count++];
    memset(reference, 0, sizeof(*reference));
    (void)snprintf(
        key,
        sizeof(key),
        "%" PRIu32 ":%" PRIu32 ":%u",
        span.start,
        span.end,
        (unsigned)producer->reference_count
    );
    producer_named_id(
        producer,
        "kofun.semantic.reference/v1",
        key,
        &reference->value.reference_id
    );
    reference->value.source_node_id = source_node->value.node_id;
    reference->value.name_space = name_space;
    reference->value.span = span;
    reference->value.status = target == NULL ?
        KOFUN_SEMANTIC_ERROR : KOFUN_SEMANTIC_VALIDATED;
    reference->value.target_shape = target == NULL ?
        KOFUN_SEMANTIC_TARGET_UNAVAILABLE :
        KOFUN_SEMANTIC_TARGET_VISIBLE;
    reference->value.target_kind = target_kind;
    if (target == NULL) {
        reference->value.hidden_reason =
            producer_text("unresolved-current-stage2-reference");
    } else {
        reference->value.target_value = *target;
    }
    return reference;
}

static bool producer_collect_references(Producer *producer) {
    int64_t use_line = hir_record_start(producer->scope_hir, "use", 0);
    int64_t source_length = (int64_t)producer->input->source_length;
    while (use_line >= 0) {
        char *start_text = hir_field(producer->scope_hir, use_line, 1);
        char *end_text = hir_field(producer->scope_hir, use_line, 2);
        char *binding_id = hir_field(producer->scope_hir, use_line, 4);
        int64_t start = decimal_value(start_text);
        int64_t end = decimal_value(end_text);
        ProducerBinding *binding;
        ProducerNode *use;
        ProducerFact *type_fact;
        bool valid = start >= 0 && end > start && end <= source_length;
        if (!valid) {
            free(start_text);
            free(end_text);
            free(binding_id);
            return false;
        }
        if ((uint64_t)start >= producer->reference_limit) {
            free(start_text);
            free(end_text);
            free(binding_id);
            use_line = hir_record_start(
                producer->scope_hir,
                "use",
                use_line + 1
            );
            continue;
        }
        binding = producer_find_binding_by_hir_id(producer, binding_id);
        if (binding == NULL) {
            free(start_text);
            free(end_text);
            free(binding_id);
            return false;
        }
        use = producer_add_node(
            producer,
            KOFUN_SEMANTIC_NODE_REFERENCE,
            start,
            end,
            binding->name,
            false
        );
        if (use == NULL ||
            producer_add_reference(
                producer,
                use,
                KOFUN_SEMANTIC_NAMESPACE_VALUE,
                use->value.span,
                KOFUN_SEMANTIC_ID_BINDING,
                &binding->binding) == NULL) {
            free(start_text);
            free(end_text);
            free(binding_id);
            return false;
        }
        type_fact = producer_add_fact(
            producer,
            use->value.node_id,
            KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED,
            binding->type,
            ""
        );
        if (type_fact == NULL) {
            free(start_text);
            free(end_text);
            free(binding_id);
            return false;
        }
        if (binding->has_type_identity) {
            use->has_discovery_type_identity = true;
            use->discovery_type_identity = binding->type_identity;
        }
        if (!producer_node_add_dependency(use, &binding->node) ||
            !producer_fact_add_dependency(type_fact, &binding->node)) {
            free(start_text);
            free(end_text);
            free(binding_id);
            return false;
        }
        free(start_text);
        free(end_text);
        free(binding_id);
        use_line = hir_record_start(
            producer->scope_hir,
            "use",
            use_line + 1
        );
    }
    {
        int64_t candidate_line = hir_record_start(
            producer->scope_hir,
            "candidate-use",
            0
        );
        while (candidate_line >= 0) {
            char *start_text = hir_field(
                producer->scope_hir,
                candidate_line,
                1
            );
            char *end_text = hir_field(
                producer->scope_hir,
                candidate_line,
                2
            );
            char *name = hir_field(
                producer->scope_hir,
                candidate_line,
                4
            );
            int64_t start = decimal_value(start_text);
            int64_t end = decimal_value(end_text);
            /*
             * Candidate uses are recovery-only observations.  On a successful
             * ownership authority run they are not rejected source facts and
             * cannot be emitted as unavailable into a complete transaction.
             */
            if (producer->compiler_exit_class != 0u &&
                start >= 0 && end > start &&
                end <= source_length &&
                (uint64_t)start < producer->reference_limit) {
                ProducerNode *use = producer_add_node(
                    producer,
                    KOFUN_SEMANTIC_NODE_REFERENCE,
                    start,
                    end,
                    name,
                    false
                );
                if (use == NULL ||
                    producer_add_fact(
                        producer,
                        use->value.node_id,
                        KOFUN_SEMANTIC_FACT_TYPE,
                        KOFUN_SEMANTIC_UNAVAILABLE,
                        "",
                        "type-not-available-in-current-subset"
                    ) == NULL) {
                    free(start_text);
                    free(end_text);
                    free(name);
                    return false;
                }
            }
            free(start_text);
            free(end_text);
            free(name);
            candidate_line = hir_record_start(
                producer->scope_hir,
                "candidate-use",
                candidate_line + 1
            );
        }
    }

    if (producer->semantic_observations == NULL) return true;

    {
        int64_t line = hir_record_start(
            producer->semantic_observations,
            "call",
            0
        );
        while (line >= 0) {
            char *target_kind = hir_field(
                producer->semantic_observations,
                line,
                1
            );
            char *name = hir_field(
                producer->semantic_observations,
                line,
                2
            );
            char *start_text = hir_field(
                producer->semantic_observations,
                line,
                3
            );
            char *end_text = hir_field(
                producer->semantic_observations,
                line,
                4
            );
            char *result_type = hir_field(
                producer->semantic_observations,
                line,
                5
            );
            int64_t start = decimal_value(start_text);
            int64_t end = decimal_value(end_text);
            ProducerFunction *function =
                strcmp(target_kind, "function") == 0 ?
                    producer_find_function(producer, name) : NULL;
            ProducerConstructor *constructor =
                strcmp(target_kind, "constructor") == 0 ?
                    producer_find_constructor(producer, name) : NULL;
            const KofunSemanticId *target = function != NULL ?
                &function->symbol :
                (constructor != NULL ? &constructor->symbol : NULL);
            const KofunSemanticId *target_node = function != NULL ?
                &function->node :
                (constructor != NULL ? &constructor->node : NULL);
            bool in_prefix = start >= 0 && end > start &&
                end <= source_length &&
                (uint64_t)start < producer->reference_limit;
            if (in_prefix && target != NULL && target_node != NULL) {
                ProducerNode *call = producer_add_node(
                    producer,
                    KOFUN_SEMANTIC_NODE_CALL,
                    start,
                    end,
                    name,
                    false
                );
                ProducerFact *type_fact;
                if (call == NULL ||
                    producer_add_reference(
                        producer,
                        call,
                        constructor == NULL ?
                            KOFUN_SEMANTIC_NAMESPACE_VALUE :
                            KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR,
                        call->value.span,
                        constructor == NULL ?
                            KOFUN_SEMANTIC_ID_SYMBOL :
                            KOFUN_SEMANTIC_ID_CONSTRUCTOR,
                        target
                    ) == NULL) {
                    free(target_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
                type_fact = producer_add_fact(
                    producer,
                    call->value.node_id,
                    KOFUN_SEMANTIC_FACT_TYPE,
                    KOFUN_SEMANTIC_VALIDATED,
                    result_type,
                    ""
                );
                if (type_fact == NULL) {
                    free(target_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
                if (!producer_node_add_dependency(call, target_node) ||
                    !producer_fact_add_dependency(
                        type_fact,
                        target_node)) {
                    free(target_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
            }
            free(target_kind);
            free(name);
            free(start_text);
            free(end_text);
            free(result_type);
            line = hir_record_start(
                producer->semantic_observations,
                "call",
                line + 1
            );
        }
    }
    {
        int64_t line = hir_record_start(
            producer->semantic_observations,
            "call-argument",
            0
        );
        while (line >= 0) {
            char *callee = hir_field(
                producer->semantic_observations, line, 1);
            char *slot_text = hir_field(
                producer->semantic_observations, line, 2);
            char *source_index_text = hir_field(
                producer->semantic_observations, line, 3);
            char *argument_text = hir_field(
                producer->semantic_observations, line, 4);
            char *value_text = hir_field(
                producer->semantic_observations, line, 5);
            char *external = hir_field(
                producer->semantic_observations, line, 6);
            char *internal = hir_field(
                producer->semantic_observations, line, 7);
            char *type = hir_field(
                producer->semantic_observations, line, 8);
            char *mode = hir_field(
                producer->semantic_observations, line, 9);
            int64_t slot = decimal_value(slot_text);
            int64_t source_index = decimal_value(source_index_text);
            int64_t argument = decimal_value(argument_text);
            int64_t value = decimal_value(value_text);
            int64_t end = argument >= 0
                ? argument_end(producer->source, argument) : -1;
            bool valid = slot >= 0 && slot < 8 && source_index >= 0 &&
                argument >= 0 && value >= argument && end > value &&
                end <= source_length && callee[0] != '\0' &&
                external[0] != '\0' && internal[0] != '\0' &&
                type[0] != '\0' && mode[0] != '\0' &&
                ((uint64_t)value < producer->reference_limit ||
                 producer->compiler_exit_class == 3u);
            if (valid) {
                char node_name[PRODUCER_IDENTIFIER_CAPACITY];
                int written = snprintf(
                    node_name,
                    sizeof(node_name),
                    "call-argument:%s:slot=%" PRId64 ":source=%" PRId64
                    ":label=%s:internal=%s",
                    callee,
                    slot,
                    source_index,
                    external,
                    internal
                );
                ProducerNode *node = written < 0 ||
                    (size_t)written >= sizeof(node_name) ? NULL :
                    producer_add_node(
                        producer,
                        KOFUN_SEMANTIC_NODE_REFERENCE,
                        value,
                        end,
                        node_name,
                        false
                    );
                if (node == NULL ||
                    producer_add_fact(
                        producer,
                        node->value.node_id,
                        KOFUN_SEMANTIC_FACT_TYPE,
                        KOFUN_SEMANTIC_VALIDATED,
                        type,
                        ""
                    ) == NULL ||
                    producer_add_fact(
                        producer,
                        node->value.node_id,
                        KOFUN_SEMANTIC_FACT_OWNERSHIP,
                        KOFUN_SEMANTIC_VALIDATED,
                        mode,
                        ""
                    ) == NULL ||
                    producer_add_fact(
                        producer,
                        node->value.node_id,
                        KOFUN_SEMANTIC_FACT_ORIGIN,
                        KOFUN_SEMANTIC_VALIDATED,
                        node_name,
                        ""
                    ) == NULL) {
                    free(callee);
                    free(slot_text);
                    free(source_index_text);
                    free(argument_text);
                    free(value_text);
                    free(external);
                    free(internal);
                    free(type);
                    free(mode);
                    return false;
                }
            }
            free(callee);
            free(slot_text);
            free(source_index_text);
            free(argument_text);
            free(value_text);
            free(external);
            free(internal);
            free(type);
            free(mode);
            line = hir_record_start(
                producer->semantic_observations,
                "call-argument",
                line + 1
            );
        }
    }
    {
        int64_t line = hir_record_start(
            producer->semantic_observations,
            "control",
            0
        );
        while (line >= 0) {
            char *kind = hir_field(
                producer->semantic_observations,
                line,
                1
            );
            char *start_text = hir_field(
                producer->semantic_observations,
                line,
                2
            );
            char *end_text = hir_field(
                producer->semantic_observations,
                line,
                3
            );
            char *result_type = hir_field(
                producer->semantic_observations,
                line,
                4
            );
            char *dependency_start_text = hir_field(
                producer->semantic_observations,
                line,
                5
            );
            char *dependency_end_text = hir_field(
                producer->semantic_observations,
                line,
                6
            );
            int64_t start = decimal_value(start_text);
            int64_t end = decimal_value(end_text);
            int64_t dependency_start =
                decimal_value(dependency_start_text);
            int64_t dependency_end =
                decimal_value(dependency_end_text);
            bool in_prefix = start >= 0 && end > start &&
                end <= source_length &&
                (uint64_t)start < producer->reference_limit;
            if (in_prefix) {
                ProducerNode *dependency;
                ProducerNode *control = producer_add_node(
                    producer,
                    strcmp(kind, "if") == 0 ?
                        KOFUN_SEMANTIC_NODE_IF :
                        KOFUN_SEMANTIC_NODE_MATCH,
                    start,
                    end,
                    kind,
                    false
                );
                ProducerFact *type_fact = control == NULL ? NULL :
                    producer_add_fact(
                    producer,
                    control->value.node_id,
                    KOFUN_SEMANTIC_FACT_TYPE,
                    KOFUN_SEMANTIC_VALIDATED,
                    result_type,
                    ""
                );
                bool dependency_span_valid =
                    dependency_start >= start &&
                    dependency_end > dependency_start &&
                    dependency_end <= end;
                dependency = dependency_span_valid ?
                    producer_find_dependency_node(
                        producer,
                        dependency_start,
                        dependency_end
                    ) : NULL;
                if (control == NULL || type_fact == NULL ||
                    !dependency_span_valid ||
                    (dependency != NULL &&
                     (!producer_node_add_dependency(
                          control,
                          &dependency->value.node_id) ||
                      !producer_fact_add_dependency(
                          type_fact,
                          &dependency->value.node_id)))) {
                    free(kind);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    free(dependency_start_text);
                    free(dependency_end_text);
                    return false;
                }
            }
            free(kind);
            free(start_text);
            free(end_text);
            free(result_type);
            free(dependency_start_text);
            free(dependency_end_text);
            line = hir_record_start(
                producer->semantic_observations,
                "control",
                line + 1
            );
        }
    }
    {
        int64_t line = hir_record_start(
            producer->semantic_observations,
            "pattern",
            0
        );
        while (line >= 0) {
            char *pattern_kind = hir_field(
                producer->semantic_observations,
                line,
                1
            );
            char *name = hir_field(
                producer->semantic_observations,
                line,
                2
            );
            char *start_text = hir_field(
                producer->semantic_observations,
                line,
                3
            );
            char *end_text = hir_field(
                producer->semantic_observations,
                line,
                4
            );
            char *result_type = hir_field(
                producer->semantic_observations,
                line,
                5
            );
            int64_t start = decimal_value(start_text);
            int64_t end = decimal_value(end_text);
            ProducerConstructor *constructor =
                strcmp(pattern_kind, "constructor") == 0 ?
                    producer_find_constructor(producer, name) : NULL;
            bool in_prefix = start >= 0 && end > start &&
                end <= source_length &&
                (uint64_t)start < producer->reference_limit;
            if (in_prefix && constructor != NULL) {
                ProducerNode *pattern = producer_add_node(
                    producer,
                    KOFUN_SEMANTIC_NODE_REFERENCE,
                    start,
                    end,
                    name,
                    false
                );
                ProducerFact *type_fact;
                if (pattern == NULL ||
                    producer_add_reference(
                        producer,
                        pattern,
                        KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR,
                        pattern->value.span,
                        KOFUN_SEMANTIC_ID_CONSTRUCTOR,
                        &constructor->symbol
                    ) == NULL) {
                    free(pattern_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
                type_fact = producer_add_fact(
                    producer,
                    pattern->value.node_id,
                    KOFUN_SEMANTIC_FACT_TYPE,
                    KOFUN_SEMANTIC_VALIDATED,
                    result_type,
                    ""
                );
                if (type_fact == NULL) {
                    free(pattern_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
                if (!producer_node_add_dependency(
                        pattern,
                        &constructor->node) ||
                    !producer_fact_add_dependency(
                        type_fact,
                        &constructor->node)) {
                    free(pattern_kind);
                    free(name);
                    free(start_text);
                    free(end_text);
                    free(result_type);
                    return false;
                }
            }
            free(pattern_kind);
            free(name);
            free(start_text);
            free(end_text);
            free(result_type);
            line = hir_record_start(
                producer->semantic_observations,
                "pattern",
                line + 1
            );
        }
    }
    return true;
}

static bool producer_finalize_control_dependencies(Producer *producer) {
    size_t control_index;
    for (control_index = 0u;
         control_index < producer->node_count;
         control_index += 1u) {
        ProducerNode *control = &producer->nodes[control_index];
        uint16_t dependency_index;
        if (control->value.kind != KOFUN_SEMANTIC_NODE_IF &&
            control->value.kind != KOFUN_SEMANTIC_NODE_MATCH) {
            continue;
        }
        if (control->value.dependency_count != 0u) {
            ProducerFact *type_fact = producer_find_fact(
                producer,
                &control->value.node_id,
                KOFUN_SEMANTIC_FACT_TYPE
            );
            if (type_fact == NULL) return false;
            for (dependency_index = 0u;
                 dependency_index < control->value.dependency_count;
                 dependency_index += 1u) {
                if (!producer_fact_add_dependency(
                        type_fact,
                        &control->dependencies[dependency_index])) {
                    return false;
                }
            }
        }
    }
    return true;
}

static bool producer_add_origin_facts(Producer *producer) {
    size_t index;
    size_t node_count = producer->node_count;
    for (index = 0u; index < node_count; index += 1u) {
        ProducerNode *node = &producer->nodes[index];
        ProducerFact *origin;
        if (producer_find_fact(
                producer,
                &node->value.node_id,
                KOFUN_SEMANTIC_FACT_ORIGIN) != NULL) {
            continue;
        }
        origin = producer_add_fact(
            producer,
            node->value.node_id,
            KOFUN_SEMANTIC_FACT_ORIGIN,
            node->value.status,
            "authored-source",
            node->value.status == KOFUN_SEMANTIC_VALIDATED ?
                "" : "unsupported-current-stage2-feature"
        );
        if (origin == NULL) return false;
        if (node->value.dependency_count != 0u) {
            uint16_t dependency_index;
            for (dependency_index = 0u;
                 dependency_index < node->value.dependency_count;
                 dependency_index += 1u) {
                if (!producer_fact_add_dependency(
                        origin,
                        &node->dependencies[dependency_index])) {
                    return false;
                }
            }
        }
        if (node->value.diagnostic_count != 0u) {
            origin->diagnostic = node->diagnostic;
            origin->value.diagnostic_ids = &origin->diagnostic;
            origin->value.diagnostic_count = 1u;
        }
    }
    return true;
}

static bool producer_prepare_source(Producer *producer) {
    static const char package_prefix[] =
        "kofun.package-id/v1\n"
        "kind=anonymous-single-file\n"
        "logical-source=";
    static const char file_prefix[] =
        "kofun.file-id-input/v1\n"
        "package-payload-begin\n";
    static const char file_middle[] =
        "package-payload-end\n"
        "logical-path=";
    static const char file_suffix[] =
        "\nsource-role=authored\n"
        "provenance=explicit-source\n";
    static const char module_prefix[] =
        "kofun.module-id-input/v1\n"
        "package-payload-begin\n";
    static const char module_suffix[] =
        "package-payload-end\n"
        "kind=synthetic-root\n";
    ProducerNode *module;
    uint8_t *package_payload;
    uint8_t *file_payload;
    uint8_t *module_payload;
    uint8_t *cursor;
    size_t path_length;
    size_t package_length;
    size_t file_length;
    size_t module_length;
    if (producer->input->source == NULL ||
        producer->input->source_length > UINT32_MAX ||
        producer->input->logical_path.bytes == NULL ||
        producer->input->logical_path.length == 0u) {
        return false;
    }
    path_length = producer->input->logical_path.length;
    if (path_length > SIZE_MAX - sizeof(package_prefix) - 1u) return false;
    package_length = sizeof(package_prefix) - 1u + path_length + 1u;
    if (package_length >
            SIZE_MAX - (sizeof(file_prefix) - 1u) -
                (sizeof(file_middle) - 1u) -
                path_length - (sizeof(file_suffix) - 1u) ||
        package_length >
            SIZE_MAX - (sizeof(module_prefix) - 1u) -
                (sizeof(module_suffix) - 1u)) {
        return false;
    }
    file_length =
        sizeof(file_prefix) - 1u +
        package_length +
        sizeof(file_middle) - 1u +
        path_length +
        sizeof(file_suffix) - 1u;
    module_length =
        sizeof(module_prefix) - 1u +
        package_length +
        sizeof(module_suffix) - 1u;
    if (package_length > UINT32_MAX ||
        file_length > UINT32_MAX ||
        module_length > UINT32_MAX) {
        return false;
    }
    package_payload = (uint8_t *)malloc(package_length);
    file_payload = (uint8_t *)malloc(file_length);
    module_payload = (uint8_t *)malloc(module_length);
    if (package_payload == NULL ||
        file_payload == NULL ||
        module_payload == NULL) {
        free(package_payload);
        free(file_payload);
        free(module_payload);
        return false;
    }
    cursor = package_payload;
    memcpy(cursor, package_prefix, sizeof(package_prefix) - 1u);
    cursor += sizeof(package_prefix) - 1u;
    memcpy(cursor, producer->input->logical_path.bytes, path_length);
    cursor += path_length;
    *cursor++ = '\n';
    if ((size_t)(cursor - package_payload) != package_length) {
        free(package_payload);
        free(file_payload);
        free(module_payload);
        return false;
    }
    producer_hash(
        "kofun.id.package/v1",
        package_payload,
        package_length,
        &producer->source_record.package_id
    );
    cursor = file_payload;
    memcpy(cursor, file_prefix, sizeof(file_prefix) - 1u);
    cursor += sizeof(file_prefix) - 1u;
    memcpy(cursor, package_payload, package_length);
    cursor += package_length;
    memcpy(cursor, file_middle, sizeof(file_middle) - 1u);
    cursor += sizeof(file_middle) - 1u;
    memcpy(cursor, producer->input->logical_path.bytes, path_length);
    cursor += path_length;
    memcpy(cursor, file_suffix, sizeof(file_suffix) - 1u);
    cursor += sizeof(file_suffix) - 1u;
    if ((size_t)(cursor - file_payload) != file_length) {
        free(package_payload);
        free(file_payload);
        free(module_payload);
        return false;
    }
    producer_hash(
        "kofun.id.file/v1",
        file_payload,
        file_length,
        &producer->source_record.file_id
    );
    cursor = module_payload;
    memcpy(cursor, module_prefix, sizeof(module_prefix) - 1u);
    cursor += sizeof(module_prefix) - 1u;
    memcpy(cursor, package_payload, package_length);
    cursor += package_length;
    memcpy(cursor, module_suffix, sizeof(module_suffix) - 1u);
    cursor += sizeof(module_suffix) - 1u;
    free(package_payload);
    free(file_payload);
    if ((size_t)(cursor - module_payload) != module_length) {
        free(module_payload);
        return false;
    }
    producer_hash(
        "kofun.id.module/v1",
        module_payload,
        module_length,
        &producer->source_record.module_id
    );
    free(module_payload);
    producer_namespace_id(
        0u,
        "value",
        &producer->value_namespace_id
    );
    producer_namespace_id(
        1u,
        "type",
        &producer->type_namespace_id
    );
    producer->source_record.logical_path = producer->input->logical_path;
    producer->source_record.source_bytes = producer->input->source_length;
    /* The source field carries the exact content SHA-256, not its identity
     * domain hash. */
    kofun_sha256(
        producer->input->source,
        producer->input->source_length,
        producer->source_record.source_sha256
    );
    producer->source_record.edition = producer_text("2026");
    producer->source_record.semantic_compatibility =
        producer_text("stage2-semantic-v1");
    producer->source_record.caller_generation =
        producer->input->caller_generation;
    producer->source_record.compiler_exit_class =
        producer->compiler_exit_class;
    module = producer_add_node(
        producer,
        KOFUN_SEMANTIC_NODE_MODULE,
        0,
        (int64_t)producer->input->source_length,
        "anonymous-module",
        true
    );
    if (module == NULL) return false;
    return producer_add_stable_identity(
            producer,
            module->value.node_id,
            KOFUN_SEMANTIC_ID_PACKAGE,
            &producer->source_record.package_id) &&
        producer_add_stable_identity(
            producer,
            module->value.node_id,
            KOFUN_SEMANTIC_ID_FILE,
            &producer->source_record.file_id) &&
        producer_add_stable_identity(
            producer,
            module->value.node_id,
            KOFUN_SEMANTIC_ID_MODULE,
            &producer->source_record.module_id);
}

static int producer_node_order(const void *left_value, const void *right_value) {
    const ProducerNode *left = (const ProducerNode *)left_value;
    const ProducerNode *right = (const ProducerNode *)right_value;
    if (left->value.kind == KOFUN_SEMANTIC_NODE_MODULE &&
        right->value.kind != KOFUN_SEMANTIC_NODE_MODULE) {
        return -1;
    }
    if (right->value.kind == KOFUN_SEMANTIC_NODE_MODULE &&
        left->value.kind != KOFUN_SEMANTIC_NODE_MODULE) {
        return 1;
    }
    if (left->value.span.start != right->value.span.start) {
        return left->value.span.start < right->value.span.start ? -1 : 1;
    }
    if (left->value.span.end != right->value.span.end) {
        return left->value.span.end < right->value.span.end ? -1 : 1;
    }
    if (left->value.kind != right->value.kind) {
        return left->value.kind < right->value.kind ? -1 : 1;
    }
    return memcmp(
        left->value.node_id.bytes,
        right->value.node_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
}

static KofunSemanticSpan producer_owner_span(
    Producer *producer,
    const KofunSemanticId *owner
) {
    ProducerNode *node = producer_find_node_by_id(producer, owner);
    return node == NULL ?
        (KofunSemanticSpan){UINT32_MAX, UINT32_MAX} :
        node->value.span;
}

static bool producer_identity_before(
    Producer *producer,
    size_t left_index,
    size_t right_index
) {
    const KofunSemanticIdentity *left =
        &producer->identities[left_index].value;
    const KofunSemanticIdentity *right =
        &producer->identities[right_index].value;
    KofunSemanticSpan left_span = producer_owner_span(
        producer,
        &left->owner_node_id
    );
    KofunSemanticSpan right_span = producer_owner_span(
        producer,
        &right->owner_node_id
    );
    if (left_span.start != right_span.start) {
        return left_span.start < right_span.start;
    }
    if (left_span.end != right_span.end) {
        return left_span.end < right_span.end;
    }
    if (left->kind != right->kind) return left->kind < right->kind;
    return memcmp(
        left->value.bytes,
        right->value.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    ) < 0;
}

static bool producer_reference_before(
    Producer *producer,
    size_t left_index,
    size_t right_index
) {
    const KofunSemanticReference *left =
        &producer->references[left_index].value;
    const KofunSemanticReference *right =
        &producer->references[right_index].value;
    (void)producer;
    if (left->span.start != right->span.start) {
        return left->span.start < right->span.start;
    }
    if (left->span.end != right->span.end) {
        return left->span.end < right->span.end;
    }
    return memcmp(
        left->reference_id.bytes,
        right->reference_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    ) < 0;
}

static bool producer_fact_before(
    Producer *producer,
    size_t left_index,
    size_t right_index
) {
    const KofunSemanticFact *left =
        &producer->facts[left_index].value;
    const KofunSemanticFact *right =
        &producer->facts[right_index].value;
    KofunSemanticSpan left_span = producer_owner_span(
        producer,
        &left->owner_node_id
    );
    KofunSemanticSpan right_span = producer_owner_span(
        producer,
        &right->owner_node_id
    );
    if (left_span.start != right_span.start) {
        return left_span.start < right_span.start;
    }
    if (left_span.end != right_span.end) {
        return left_span.end < right_span.end;
    }
    return memcmp(
        left->owner_node_id.bytes,
        right->owner_node_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    ) < 0;
}

static bool producer_diagnostic_before(
    Producer *producer,
    size_t left_index,
    size_t right_index
) {
    const KofunSemanticDiagnostic *left =
        &producer->diagnostics[left_index].value;
    const KofunSemanticDiagnostic *right =
        &producer->diagnostics[right_index].value;
    (void)producer;
    if (left->primary_span.start != right->primary_span.start) {
        return left->primary_span.start < right->primary_span.start;
    }
    if (left->primary_span.end != right->primary_span.end) {
        return left->primary_span.end < right->primary_span.end;
    }
    return memcmp(
        left->diagnostic_id.bytes,
        right->diagnostic_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    ) < 0;
}

static bool producer_emit(
    Producer *producer,
    KofunSemanticSink *sink,
    bool cancellation_observed_after_commit,
    KofunStage2SemanticResult *result
) {
    size_t index;
    size_t emitted;
    bool identity_emitted[PRODUCER_MAX_IDENTITIES] = {false};
    bool reference_emitted[PRODUCER_MAX_REFERENCES] = {false};
    bool fact_emitted[PRODUCER_MAX_FACTS] = {false};
    bool diagnostic_emitted[PRODUCER_MAX_DIAGNOSTICS] = {false};
    unsigned fact_kind;
    uint32_t record_index = 0u;
    KofunSourceStatus source_status;
    KofunCompleteness completeness;
    qsort(
        producer->nodes,
        producer->node_count,
        sizeof(producer->nodes[0]),
        producer_node_order
    );
    for (index = 0u; index < producer->node_count; index += 1u) {
        if (producer->nodes[index].value.dependency_count != 0u) {
            producer->nodes[index].value.dependencies =
                producer->nodes[index].dependencies;
        }
        if (producer->nodes[index].value.diagnostic_count != 0u) {
            producer->nodes[index].value.diagnostic_ids =
                &producer->nodes[index].diagnostic;
        }
    }
    if (!kofun_semantic_begin(sink, &producer->source_record)) {
        producer_set_tooling_error(
            result, "ETS03", record_index, PRODUCER_EVENT_SOURCE,
            "semantic sink rejected source"
        );
        return false;
    }
    record_index += 1u;
    for (index = 0u; index < producer->node_count; index += 1u) {
        if (!kofun_semantic_node(sink, &producer->nodes[index].value)) {
            producer_set_tooling_error(
                result, "ETS03", record_index, PRODUCER_EVENT_NODE,
                "semantic sink rejected node"
            );
            return false;
        }
        record_index += 1u;
    }
    for (emitted = 0u;
         emitted < producer->identity_count;
         emitted += 1u) {
        size_t best = SIZE_MAX;
        for (index = 0u; index < producer->identity_count; index += 1u) {
            if (!identity_emitted[index] &&
                (best == SIZE_MAX ||
                 producer_identity_before(producer, index, best))) {
                best = index;
            }
        }
        if (best == SIZE_MAX) {
            producer_set_tooling_error(
                result, "ETS04", record_index, PRODUCER_EVENT_IDENTITY,
                "semantic producer identity ordering failed"
            );
            return false;
        }
        identity_emitted[best] = true;
        if (!kofun_semantic_identity(
                sink,
                &producer->identities[best].value)) {
            producer_set_tooling_error(
                result, "ETS03", record_index, PRODUCER_EVENT_IDENTITY,
                "semantic sink rejected identity"
            );
            return false;
        }
        record_index += 1u;
    }
    for (emitted = 0u;
         emitted < producer->reference_count;
         emitted += 1u) {
        size_t best = SIZE_MAX;
        for (index = 0u; index < producer->reference_count; index += 1u) {
            if (!reference_emitted[index] &&
                (best == SIZE_MAX ||
                 producer_reference_before(producer, index, best))) {
                best = index;
            }
        }
        if (best == SIZE_MAX) {
            producer_set_tooling_error(
                result, "ETS04", record_index, PRODUCER_EVENT_REFERENCE,
                "semantic producer reference ordering failed"
            );
            return false;
        }
        reference_emitted[best] = true;
        if (!kofun_semantic_reference(
                sink,
                &producer->references[best].value)) {
            producer_set_tooling_error(
                result, "ETS03", record_index, PRODUCER_EVENT_REFERENCE,
                "semantic sink rejected reference"
            );
            return false;
        }
        record_index += 1u;
    }
    for (fact_kind = KOFUN_SEMANTIC_FACT_TYPE;
         fact_kind <= KOFUN_SEMANTIC_FACT_ORIGIN;
         fact_kind += 1u) {
        size_t kind_count = 0u;
        for (index = 0u; index < producer->fact_count; index += 1u) {
            if ((unsigned)producer->facts[index].value.kind == fact_kind) {
                kind_count += 1u;
            }
        }
        for (emitted = 0u; emitted < kind_count; emitted += 1u) {
            size_t best = SIZE_MAX;
            for (index = 0u; index < producer->fact_count; index += 1u) {
                if (!fact_emitted[index] &&
                    (unsigned)producer->facts[index].value.kind ==
                        fact_kind &&
                    (best == SIZE_MAX ||
                     producer_fact_before(producer, index, best))) {
                    best = index;
                }
            }
            if (best == SIZE_MAX) {
                producer_set_tooling_error(
                    result, "ETS04", record_index, PRODUCER_EVENT_FACT,
                    "semantic producer fact ordering failed"
                );
                return false;
            }
            fact_emitted[best] = true;
            if (!kofun_semantic_fact(sink, &producer->facts[best].value)) {
                producer_set_tooling_error(
                    result, "ETS03", record_index, PRODUCER_EVENT_FACT,
                    "semantic sink rejected fact"
                );
                return false;
            }
            record_index += 1u;
        }
    }
    for (emitted = 0u;
         emitted < producer->diagnostic_count;
         emitted += 1u) {
        size_t best = SIZE_MAX;
        for (index = 0u; index < producer->diagnostic_count; index += 1u) {
            if (!diagnostic_emitted[index] &&
                (best == SIZE_MAX ||
                 producer_diagnostic_before(producer, index, best))) {
                best = index;
            }
        }
        if (best == SIZE_MAX) {
            producer_set_tooling_error(
                result, "ETS04", record_index, PRODUCER_EVENT_DIAGNOSTIC,
                "semantic producer diagnostic ordering failed"
            );
            return false;
        }
        diagnostic_emitted[best] = true;
        if (!kofun_semantic_diagnostic(
                sink,
                &producer->diagnostics[best].value)) {
            producer_set_tooling_error(
                result, "ETS03", record_index, PRODUCER_EVENT_DIAGNOSTIC,
                "semantic sink rejected diagnostic"
            );
            return false;
        }
        record_index += 1u;
    }
    if (cancellation_observed_after_commit && !producer->language_failed) {
        kofun_semantic_cancellation_observed(sink);
        source_status = KOFUN_SOURCE_CANCELLED;
        completeness = KOFUN_SEMANTIC_PARTIAL;
    } else if (producer->language_failed) {
        source_status = KOFUN_SOURCE_FAILED;
        completeness = KOFUN_SEMANTIC_PARTIAL;
    } else {
        source_status = KOFUN_SOURCE_CHECKED;
        completeness = KOFUN_SEMANTIC_COMPLETE;
    }
    if (!kofun_semantic_end(sink, source_status, completeness)) {
        producer_set_tooling_error(
            result, "ETS03", record_index, PRODUCER_EVENT_END,
            "semantic sink rejected end"
        );
        return false;
    }
    result->source_status = source_status;
    result->completeness = completeness;
    return true;
}

static bool producer_snapshot_add(
    KofunStage2InterfaceSnapshot *snapshot,
    KofunStage2InterfaceFactKind kind,
    KofunStage2InterfaceVisibility visibility,
    const KofunSemanticId *namespace_id,
    const KofunSemanticId *symbol_id,
    const KofunSemanticId *owner_symbol_id,
    const char *name,
    uint16_t parameter_count,
    uint8_t payload_count,
    uint32_t ordinal
) {
    KofunStage2InterfaceFact *fact;
    if (snapshot->fact_count >= KOFUN_STAGE2_INTERFACE_MAX_FACTS ||
        strlen(name) >= KOFUN_STAGE2_INTERFACE_NAME_BYTES) {
        return false;
    }
    fact = &snapshot->facts[snapshot->fact_count++];
    memset(fact, 0, sizeof(*fact));
    fact->kind = kind;
    fact->visibility = visibility;
    fact->namespace_id = *namespace_id;
    fact->symbol_id = *symbol_id;
    if (owner_symbol_id != NULL) fact->owner_symbol_id = *owner_symbol_id;
    (void)snprintf(fact->name, sizeof(fact->name), "%s", name);
    fact->parameter_count = parameter_count;
    fact->constructor_payload_count = payload_count;
    fact->constructor_ordinal = ordinal;
    return true;
}

static const char *producer_visibility_name(
    KofunStage2InterfaceVisibility visibility
) {
    switch (visibility) {
        case KOFUN_STAGE2_INTERFACE_PRIVATE: return "private";
        case KOFUN_STAGE2_INTERFACE_INTERNAL: return "internal";
        case KOFUN_STAGE2_INTERFACE_PUBLIC: return "pub";
    }
    return "invalid";
}

static void producer_set_visibility_leak(
    KofunStage2SemanticResult *result,
    KofunSemanticSpan use,
    const ProducerType *type,
    KofunStage2InterfaceVisibility requested
) {
    int written;
    if (result == NULL || type == NULL) return;
    result->has_source_diagnostic = true;
    result->diagnostic_has_byte_span = true;
    result->compiler_exit_class = 1u;
    result->source_status = KOFUN_SOURCE_FAILED;
    result->completeness = KOFUN_SEMANTIC_PARTIAL;
    result->diagnostic_span = use;
    (void)snprintf(
        result->diagnostic_code,
        sizeof(result->diagnostic_code),
        "E2S145"
    );
    (void)snprintf(
        result->diagnostic_category,
        sizeof(result->diagnostic_category),
        "visibility"
    );
    (void)snprintf(
        result->diagnostic_template_id,
        sizeof(result->diagnostic_template_id),
        "visibility-api-leak"
    );
    written = snprintf(
        result->diagnostic_fallback,
        sizeof(result->diagnostic_fallback),
        "error[E2S145]: API type at bytes %" PRIu32 "..%" PRIu32
        " leaks a narrower declaration at bytes %" PRIu32 "..%" PRIu32
        "; requested=%s effective=%s; change API or declaration visibility",
        use.start,
        use.end,
        (uint32_t)type->start,
        (uint32_t)type->end,
        producer_visibility_name(requested),
        producer_visibility_name(type->visibility)
    );
    result->diagnostic_truncated = written < 0 ||
        (size_t)written >= sizeof(result->diagnostic_fallback);
}

static bool producer_parameter_type_span(
    const Producer *producer,
    const ProducerBinding *binding,
    KofunSemanticSpan *span
) {
    int64_t colon = skip_trivia(
        producer->source,
        token_end(producer->source, binding->declaration_start)
    );
    int64_t start;
    int64_t end;
    if (!token_equal(producer->source, colon, ":")) return false;
    start = skip_trivia(producer->source, token_end(producer->source, colon));
    end = token_end(producer->source, start);
    if (end <= start) return false;
    *span = producer_span(start, end);
    return true;
}

static bool producer_parameter_head(
    const Producer *producer,
    const ProducerFunction *function,
    const ProducerBinding *binding,
    int64_t *head,
    int64_t *parameters_end
) {
    int64_t open = parameter_open(producer->source, function->start);
    int64_t cursor;
    if (open < 0) return false;
    *parameters_end = balanced_end(producer->source, open, "(", ")");
    if (*parameters_end < 0) return false;
    cursor = skip_trivia(producer->source, token_end(producer->source, open));
    while (cursor < *parameters_end &&
           !token_equal(producer->source, cursor, ")")) {
        int64_t internal = parameter_internal_start(
            producer->source,
            cursor,
            *parameters_end
        );
        int64_t type = parameter_type_start(
            producer->source,
            cursor,
            *parameters_end
        );
        if (internal == binding->declaration_start) {
            *head = cursor;
            return true;
        }
        if (type < 0) return false;
        int64_t type_end = callable_type_end(producer->source, type);
        if (type_end < 0) {
            type_end = annotation_type_end(producer->source, type);
        }
        int64_t separator = skip_trivia(producer->source, type_end);
        cursor = separator < *parameters_end &&
            token_equal(producer->source, separator, ",")
            ? skip_trivia(
                producer->source,
                token_end(producer->source, separator)
            ) : separator;
    }
    return false;
}

static bool producer_parameter_external_span(
    const Producer *producer,
    const ProducerFunction *function,
    const ProducerBinding *binding,
    KofunSemanticSpan *span
) {
    int64_t head;
    int64_t end;
    int64_t external;
    if (!producer_parameter_head(
            producer, function, binding, &head, &end)) return false;
    external = parameter_external_start(producer->source, head, end);
    if (external < 0) return false;
    *span = producer_span(
        external,
        token_end(producer->source, external)
    );
    return true;
}

static bool producer_parameter_ownership_span(
    const Producer *producer,
    const ProducerFunction *function,
    const ProducerBinding *binding,
    KofunSemanticSpan *span
) {
    int64_t head;
    int64_t end;
    if (!producer_parameter_head(
            producer, function, binding, &head, &end) ||
        !ownership_mode_token(producer->source, head)) return false;
    *span = producer_span(head, token_end(producer->source, head));
    return true;
}

static bool producer_result_type_span(
    const Producer *producer,
    const ProducerFunction *function,
    KofunSemanticSpan *span
) {
    int64_t open = parameter_open(producer->source, function->start);
    int64_t close;
    int64_t arrow;
    int64_t start;
    int64_t end;
    if (open < 0) return false;
    close = balanced_end(producer->source, open, "(", ")");
    if (close < 0) return false;
    arrow = skip_trivia(producer->source, close);
    if (!token_equal(producer->source, arrow, "->")) return false;
    start = skip_trivia(producer->source, token_end(producer->source, arrow));
    end = token_end(producer->source, start);
    if (end <= start) return false;
    *span = producer_span(start, end);
    return true;
}

static bool producer_constructor_payload_type_span(
    const Producer *producer,
    const ProducerConstructor *constructor,
    KofunSemanticSpan *span
) {
    int64_t open = skip_trivia(
        producer->source,
        token_end(producer->source, constructor->start)
    );
    int64_t field;
    int64_t colon;
    int64_t start;
    int64_t end;
    if (!token_equal(producer->source, open, "(")) return false;
    field = skip_trivia(producer->source, token_end(producer->source, open));
    colon = skip_trivia(producer->source, token_end(producer->source, field));
    if (!token_equal(producer->source, colon, ":")) return false;
    start = skip_trivia(producer->source, token_end(producer->source, colon));
    end = token_end(producer->source, start);
    if (end <= start) return false;
    *span = producer_span(start, end);
    return true;
}

static bool producer_resolve_interface_type(
    Producer *producer,
    const char *name,
    KofunSemanticSpan use,
    KofunStage2InterfaceVisibility requested,
    KofunSemanticId *symbol_id,
    KofunStage2SemanticResult *result
) {
    ProducerType *type;
    memset(symbol_id, 0, sizeof(*symbol_id));
    if (strcmp(name, "Int") == 0) return true;
    type = producer_find_type(producer, name);
    if (type == NULL || type->kind != KOFUN_STAGE2_INTERFACE_ADT) {
        producer_set_tooling_error(
            result, "EKI02", 0u, PRODUCER_EVENT_NONE,
            "KIF v2 supports only complete Int or flat nominal function signatures"
        );
        return false;
    }
    if (type->visibility < requested) {
        producer_set_visibility_leak(result, use, type, requested);
        return false;
    }
    *symbol_id = type->symbol;
    return true;
}

static bool producer_build_interface_snapshot(
    Producer *producer,
    KofunSemanticBytes edition,
    KofunStage2InterfaceSnapshot *snapshot,
    KofunStage2SemanticResult *result
) {
    size_t index;
    if (edition.bytes == NULL || edition.length == 0u || edition.length > 64u ||
        memchr(edition.bytes, 0, edition.length) != NULL) {
        producer_set_tooling_error(
            result, "EKI01", 0u, PRODUCER_EVENT_NONE,
            "KIF edition is invalid"
        );
        return false;
    }
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->package_id = producer->source_record.package_id;
    snapshot->module_id = producer->source_record.module_id;
    memcpy(snapshot->edition, edition.bytes, edition.length);
    snapshot->edition[edition.length] = '\0';
    for (index = 0u; index < producer->function_count; index += 1u) {
        ProducerFunction *function = &producer->functions[index];
        KofunSemanticId result_type_symbol_id;
        KofunSemanticSpan result_span;
        size_t parameter_start = snapshot->type_reference_count;
        size_t parameter_count = 0u;
        size_t binding_index;
        KofunStage2InterfaceFact *fact;
        if (function->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE) continue;
        if (!producer_result_type_span(producer, function, &result_span) ||
            !producer_resolve_interface_type(
                producer, function->return_type, result_span,
                function->visibility, &result_type_symbol_id, result)) {
            if (!result->has_source_diagnostic &&
                !result->tooling_emission_failed) {
                producer_set_tooling_error(
                    result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                    "KIF v2 function signature is incomplete"
                );
            }
            return false;
        }
        for (binding_index = 0u;
             binding_index < producer->binding_count;
             binding_index += 1u) {
            const ProducerBinding *binding =
                &producer->bindings[binding_index];
            ProducerNode *node = producer_find_node_by_id(
                producer, &binding->node);
            KofunSemanticSpan use;
            KofunSemanticSpan ownership;
            KofunSemanticSpan external;
            KofunSemanticId type_symbol_id;
            if (binding->function_start != function->start || node == NULL ||
                node->value.kind != KOFUN_SEMANTIC_NODE_PARAMETER) {
                continue;
            }
            if (producer_parameter_ownership_span(
                    producer, function, binding, &ownership)) {
                producer_set_tooling_error(
                    result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                    "KIF v2 does not support ownership modes in published signatures"
                );
                return false;
            }
            if (snapshot->type_reference_count >=
                    KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES) {
                producer_set_tooling_error(
                    result, "EKI03", 0u, PRODUCER_EVENT_NONE,
                    "KIF compiler type-reference limit exceeded"
                );
                return false;
            }
            if (!producer_parameter_type_span(producer, binding, &use) ||
                !producer_resolve_interface_type(
                    producer, binding->type, use, function->visibility,
                    &type_symbol_id, result)) {
                if (!result->has_source_diagnostic &&
                    !result->tooling_emission_failed) {
                    producer_set_tooling_error(
                        result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                        "KIF v2 function parameter signature is incomplete"
                    );
                }
                return false;
            }
            if (producer_parameter_external_span(
                    producer, function, binding, &external)) {
                size_t label_length = (size_t)(external.end - external.start);
                if (label_length == 0u ||
                    label_length >= KOFUN_STAGE2_INTERFACE_NAME_BYTES) {
                    producer_set_tooling_error(
                        result, "EKI03", 0u, PRODUCER_EVENT_NONE,
                        "KIF compiler parameter-label limit exceeded"
                    );
                    return false;
                }
                memcpy(
                    snapshot->parameter_labels[snapshot->type_reference_count],
                    producer->source + external.start,
                    label_length
                );
                snapshot->parameter_labels[snapshot->type_reference_count]
                    [label_length] = '\0';
                snapshot->parameter_label_lengths[
                    snapshot->type_reference_count] = (uint16_t)label_length;
            }
            snapshot->type_reference_symbol_ids[
                snapshot->type_reference_count++] = type_symbol_id;
            parameter_count += 1u;
        }
        if (parameter_count != function->parameter_count ||
            parameter_count > UINT16_MAX) {
            if (!result->has_source_diagnostic &&
                !result->tooling_emission_failed) {
                producer_set_tooling_error(
                    result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                    "KIF v2 function signature is incomplete"
                );
            }
            return false;
        }
        if (!producer_snapshot_add(
                snapshot, KOFUN_STAGE2_INTERFACE_FUNCTION,
                function->visibility, &producer->value_namespace_id,
                &function->symbol, NULL, function->name,
                (uint16_t)parameter_count, 0u, 0u)) {
            producer_set_tooling_error(
                result, "EKI03", 0u, PRODUCER_EVENT_NONE,
                "KIF compiler fact limit exceeded"
            );
            return false;
        }
        fact = &snapshot->facts[snapshot->fact_count - 1u];
        fact->parameter_type_start = (uint16_t)parameter_start;
        fact->parameter_label_start = (uint16_t)parameter_start;
        fact->result_type_symbol_id = result_type_symbol_id;
    }
    for (index = 0u; index < producer->type_count; index += 1u) {
        ProducerType *type = &producer->types[index];
        if (type->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE) continue;
        if (type->kind != KOFUN_STAGE2_INTERFACE_ADT) {
            producer_set_tooling_error(
                result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                "KIF v2 does not support record signature publication"
            );
            return false;
        }
        if (!producer_snapshot_add(
                snapshot, type->kind, type->visibility,
                &producer->type_namespace_id, &type->symbol, NULL,
                type->name, 0u, 0u, 0u)) {
            producer_set_tooling_error(
                result, "EKI03", 0u, PRODUCER_EVENT_NONE,
                "KIF compiler fact limit exceeded"
            );
            return false;
        }
    }
    for (index = 0u; index < producer->constructor_count; index += 1u) {
        ProducerConstructor *constructor = &producer->constructors[index];
        KofunSemanticId payload_type_symbol_id;
        KofunStage2InterfaceFact *fact;
        memset(&payload_type_symbol_id, 0, sizeof(payload_type_symbol_id));
        if (constructor->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE) continue;
        if (constructor->payload_count == 1u) {
            KofunSemanticSpan use;
            if (!producer_constructor_payload_type_span(
                    producer, constructor, &use) ||
                !producer_resolve_interface_type(
                    producer, constructor->payload_type, use,
                    constructor->visibility, &payload_type_symbol_id,
                    result)) {
                if (!result->has_source_diagnostic &&
                    !result->tooling_emission_failed) {
                    producer_set_tooling_error(
                        result, "EKI02", 0u, PRODUCER_EVENT_NONE,
                        "KIF v2 constructor payload signature is incomplete"
                    );
                }
                return false;
            }
        }
        if (!producer_snapshot_add(
                snapshot, KOFUN_STAGE2_INTERFACE_CONSTRUCTOR,
                constructor->visibility, &producer->value_namespace_id,
                &constructor->symbol, &constructor->owner_symbol,
                constructor->name, 0u, constructor->payload_count,
                constructor->ordinal)) {
            producer_set_tooling_error(
                result, "EKI03", 0u, PRODUCER_EVENT_NONE,
                "KIF compiler fact limit exceeded"
            );
            return false;
        }
        fact = &snapshot->facts[snapshot->fact_count - 1u];
        fact->constructor_payload_type_symbol_id =
            payload_type_symbol_id;
    }
    snapshot->committed = true;
    return true;
}

static bool producer_is_discovery_expression(KofunSemanticNodeKind kind) {
    return kind == KOFUN_SEMANTIC_NODE_CALL ||
        kind == KOFUN_SEMANTIC_NODE_REFERENCE ||
        kind == KOFUN_SEMANTIC_NODE_IF ||
        kind == KOFUN_SEMANTIC_NODE_MATCH;
}

static const ProducerIdentity *producer_find_identity(
    const Producer *producer,
    const KofunSemanticId *owner,
    KofunSemanticIdentityKind kind
) {
    size_t index;
    for (index = 0u; index < producer->identity_count; index += 1u) {
        const ProducerIdentity *identity = &producer->identities[index];
        if (identity->value.kind == kind &&
            memcmp(
                identity->value.owner_node_id.bytes,
                owner->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return identity;
        }
    }
    return NULL;
}

static const ProducerBinding *producer_binding_for_node(
    const Producer *producer,
    const KofunSemanticId *node_id
) {
    size_t index;
    for (index = 0u; index < producer->binding_count; index += 1u) {
        if (memcmp(
                producer->bindings[index].node.bytes,
                node_id->bytes,
                KOFUN_SEMANTIC_ID_BYTES) == 0) {
            return &producer->bindings[index];
        }
    }
    return NULL;
}

/*
 * The bounded dependency closure a validated candidate fact needs (#637):
 * every dependency must be a parameter/local binding whose annotated type
 * carries a compiler-issued identity — a current-file nominal symbol or a
 * builtin/constructed TypeId from the bounded owner.  A dependency that is
 * not a binding, or a binding whose type has no committed identity, leaves
 * the closure open and the candidate honestly provisional.
 */
static bool producer_fact_bindings_identity_closed(
    const Producer *producer,
    const ProducerFact *fact
) {
    uint16_t index;
    for (index = 0u; index < fact->value.dependency_count; index += 1u) {
        const ProducerBinding *binding = producer_binding_for_node(
            producer,
            &fact->dependencies[index]
        );
        if (binding == NULL || !binding->has_type_identity) return false;
    }
    return true;
}

/*
 * A type reference some owner in this analysis has issued an identity for:
 * a current-file declaration, or the bounded builtin/constructed catalog.
 *
 * The signature fact's dependencies are its parameter bindings and nothing
 * else, so a function's result type appears in no dependency list and cannot
 * be reached by walking one. Checking it separately is what keeps
 * `fn f(v: Int) -> Undeclared` out of a validated callable row: its rendered
 * signature reads perfectly well, and reading well is exactly what must not
 * be mistaken for a closed closure.
 */
static bool producer_type_reference_is_identified(
    Producer *producer,
    const char *type_name
) {
    KofunSemanticId ignored;
    if (type_name == NULL || type_name[0] == '\0') return false;
    if (producer_find_type(producer, type_name) != NULL) return true;
    return producer_bounded_type_reference_id(producer, type_name, &ignored);
}

static bool producer_add_discovery_candidate(
    const Producer *producer,
    KofunStage2DiscoverySnapshot *snapshot,
    KofunStage2DiscoveryCandidateKind kind,
    const KofunSemanticId *symbol_id,
    const char *name,
    const char *signature,
    const char *effect,
    KofunSemanticStatus status,
    KofunStage2InterfaceVisibility visibility
) {
    KofunStage2DiscoveryCandidate *candidate;
    int written;
    if (snapshot->candidate_count >=
            KOFUN_STAGE2_DISCOVERY_MAX_CANDIDATES ||
        symbol_id == NULL || name == NULL || signature == NULL ||
        effect == NULL || name[0] == '\0') {
        return false;
    }
    candidate = &snapshot->candidates[snapshot->candidate_count++];
    memset(candidate, 0, sizeof(*candidate));
    candidate->kind = kind;
    candidate->symbol_id = *symbol_id;
    candidate->module_id = producer->source_record.module_id;
    candidate->status = status;
    candidate->visibility = visibility;
    written = snprintf(
        candidate->display_name,
        sizeof(candidate->display_name),
        "%s",
        name
    );
    if (written < 0 || (size_t)written >= sizeof(candidate->display_name)) {
        return false;
    }
    written = snprintf(
        candidate->module_name,
        sizeof(candidate->module_name),
        "%s",
        "synthetic-root"
    );
    if (written < 0 || (size_t)written >= sizeof(candidate->module_name)) {
        return false;
    }
    written = snprintf(
        candidate->qualified_name,
        sizeof(candidate->qualified_name),
        "synthetic-root.%s",
        name
    );
    if (written < 0 || (size_t)written >= sizeof(candidate->qualified_name)) {
        return false;
    }
    written = snprintf(
        candidate->signature,
        sizeof(candidate->signature),
        "%s",
        signature
    );
    if (written < 0 || (size_t)written >= sizeof(candidate->signature)) {
        return false;
    }
    written = snprintf(
        candidate->effect,
        sizeof(candidate->effect),
        "%s",
        effect
    );
    if (written < 0 || (size_t)written >= sizeof(candidate->effect)) {
        return false;
    }
    return true;
}

static bool producer_build_discovery_snapshot(
    Producer *producer,
    KofunStage2DiscoverySnapshot *snapshot
) {
    size_t index;
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->package_id = producer->source_record.package_id;
    snapshot->module_id = producer->source_record.module_id;
    snapshot->file_id = producer->source_record.file_id;
    snapshot->source_bytes = producer->source_record.source_bytes;
    memcpy(
        snapshot->source_sha256,
        producer->source_record.source_sha256,
        sizeof(snapshot->source_sha256)
    );
    snapshot->caller_generation = producer->source_record.caller_generation;
    if (producer->source_record.semantic_compatibility.bytes == NULL ||
        producer->source_record.semantic_compatibility.length == 0u ||
        producer->source_record.semantic_compatibility.length >=
            sizeof(snapshot->semantic_compatibility)) {
        return false;
    }
    memcpy(
        snapshot->semantic_compatibility,
        producer->source_record.semantic_compatibility.bytes,
        producer->source_record.semantic_compatibility.length
    );
    snapshot->semantic_compatibility[
        producer->source_record.semantic_compatibility.length] = '\0';

    for (index = 0u; index < producer->node_count; index += 1u) {
        const ProducerNode *node = &producer->nodes[index];
        const ProducerIdentity *type_identity;
        ProducerFact *type_fact;
        KofunStage2DiscoveryExpression *expression;
        int written;
        if (!producer_is_discovery_expression(node->value.kind)) continue;
        if (snapshot->expression_count >=
                KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS) {
            return false;
        }
        expression = &snapshot->expressions[snapshot->expression_count++];
        memset(expression, 0, sizeof(*expression));
        expression->node = node->value;
        expression->node.dependencies = NULL;
        expression->node.dependency_count = 0u;
        expression->node.diagnostic_ids = NULL;
        expression->node.diagnostic_count = 0u;
        if (node->has_discovery_type_identity) {
            expression->has_type_identity = true;
            expression->type_identity.owner_node_id = node->value.node_id;
            expression->type_identity.kind = KOFUN_SEMANTIC_ID_TYPE;
            expression->type_identity.status = KOFUN_SEMANTIC_VALIDATED;
            expression->type_identity.value =
                node->discovery_type_identity;
        } else {
            type_identity = producer_find_identity(
                producer,
                &node->value.node_id,
                KOFUN_SEMANTIC_ID_TYPE
            );
            if (type_identity != NULL) {
                expression->has_type_identity = true;
                expression->type_identity = type_identity->value;
            }
        }
        type_fact = producer_find_fact(
            producer,
            &node->value.node_id,
            KOFUN_SEMANTIC_FACT_TYPE
        );
        if (type_fact == NULL) continue;
        expression->has_type_fact = true;
        expression->type_status = type_fact->value.status;
        written = snprintf(
            expression->type_display,
            sizeof(expression->type_display),
            "%s",
            type_fact->display
        );
        if (written < 0 ||
            (size_t)written >= sizeof(expression->type_display)) {
            return false;
        }
        written = snprintf(
            expression->type_reason,
            sizeof(expression->type_reason),
            "%s",
            type_fact->reason
        );
        if (written < 0 ||
            (size_t)written >= sizeof(expression->type_reason)) {
            return false;
        }
    }

    /*
     * The ownership profile records a syntactically exact use before its
     * current narrow scope builder can bind the full List[Text] parameter.
     * Keep that occurrence selectable, but carry no type fact: discovery may
     * honestly answer it as unavailable while still refusing a client span
     * that does not match what Stage 2 parsed.  No name or rendered type is
     * promoted from this recovery record.
     */
    if (producer->scope_hir != NULL) {
        int64_t line = hir_record_start(
            producer->scope_hir,
            "candidate-use",
            0
        );
        while (line >= 0) {
            char *start_text = hir_field(producer->scope_hir, line, 1);
            char *end_text = hir_field(producer->scope_hir, line, 2);
            int64_t start = decimal_value(start_text);
            int64_t end = decimal_value(end_text);
            bool present = false;
            size_t expression_index;
            for (expression_index = 0u;
                 expression_index < snapshot->expression_count;
                 expression_index += 1u) {
                const KofunSemanticNode *node =
                    &snapshot->expressions[expression_index].node;
                if (node->span.start == (uint32_t)start &&
                    node->span.end == (uint32_t)end) {
                    present = true;
                    break;
                }
            }
            if (!present && start >= 0 && end > start &&
                (uint64_t)end <= producer->input->source_length) {
                KofunStage2DiscoveryExpression *expression;
                if (snapshot->expression_count >=
                        KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS) {
                    free(start_text);
                    free(end_text);
                    return false;
                }
                expression =
                    &snapshot->expressions[snapshot->expression_count++];
                memset(expression, 0, sizeof(*expression));
                expression->node.kind = KOFUN_SEMANTIC_NODE_REFERENCE;
                expression->node.span = producer_span(start, end);
                expression->node.status = KOFUN_SEMANTIC_UNAVAILABLE;
                kofun_semantic_derive_id(
                    "kofun.sidecar.node/v1",
                    &producer->source_record.file_id,
                    expression->node.kind,
                    expression->node.span,
                    0u,
                    &expression->node.node_id
                );
            }
            free(start_text);
            free(end_text);
            line = hir_record_start(
                producer->scope_hir,
                "candidate-use",
                line + 1
            );
        }
    }

    for (index = 0u; index < producer->function_count; index += 1u) {
        const ProducerFunction *function = &producer->functions[index];
        ProducerFact *signature = producer_find_fact(
            producer,
            &function->node,
            KOFUN_SEMANTIC_FACT_TYPE
        );
        ProducerFact *effect = producer_find_fact(
            producer,
            &function->node,
            KOFUN_SEMANTIC_FACT_EFFECT
        );
        KofunSemanticStatus status = KOFUN_SEMANTIC_UNAVAILABLE;
        const char *effect_requirement = "";
        if (function->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE) {
            snapshot->hidden_candidate_present = true;
            continue;
        }
        if (signature != NULL && effect != NULL &&
            signature->value.status == KOFUN_SEMANTIC_VALIDATED &&
            effect->value.status == KOFUN_SEMANTIC_VALIDATED) {
            /*
             * A validated candidate needs its whole committed closure: every
             * type its signature names — each parameter binding *and* the
             * result — must carry a compiler-issued identity, and the effect
             * must be a fact the current inference commits directly:
             * `pure`, or a direct `io` root with no callee dependency.  An io
             * requirement is carried on the candidate rather than blocking
             * validation; anything less than the full closure stays
             * provisional, and no rendered signature is disclosed for it.
             */
            bool pure = strcmp(effect->display, "pure") == 0;
            bool io = strcmp(effect->display, "io") == 0;
            status = (pure || io) &&
                    producer_fact_bindings_identity_closed(
                        producer, signature) &&
                    producer_type_reference_is_identified(
                        producer, function->return_type) &&
                    effect->value.dependency_count == 0u ?
                KOFUN_SEMANTIC_VALIDATED :
                KOFUN_SEMANTIC_PROVISIONAL;
            if (status == KOFUN_SEMANTIC_VALIDATED && io) {
                effect_requirement = effect->display;
            }
        }
        if (signature == NULL || effect == NULL ||
            !producer_add_discovery_candidate(
                producer,
                snapshot,
                KOFUN_STAGE2_DISCOVERY_FUNCTION,
                &function->symbol,
                function->name,
                status == KOFUN_SEMANTIC_VALIDATED ?
                    signature->display : "",
                status == KOFUN_SEMANTIC_VALIDATED ?
                    effect_requirement : "",
                status,
                function->visibility)) {
            return false;
        }
    }

    for (index = 0u; index < producer->constructor_count; index += 1u) {
        const ProducerConstructor *constructor =
            &producer->constructors[index];
        char signature[KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES];
        KofunSemanticStatus status;
        if (constructor->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE) {
            snapshot->hidden_candidate_present = true;
            continue;
        }
        int written = constructor->payload_count == 0u ?
            snprintf(
                signature,
                sizeof(signature),
                "() -> %s",
                constructor->result_type) :
            snprintf(
                signature,
                sizeof(signature),
                "%s -> %s",
                constructor->payload_type,
                constructor->result_type);
        /*
         * The current compiler-owned IR fully fixes a nullary constructor and
         * the one supported builtin payload shape.  Other payload spellings
         * still need an identity-bearing dependency closure, so keep them
         * provisional instead of validating a rendered signature.
         */
        status = constructor->payload_count == 0u ||
                (constructor->payload_count == 1u &&
                 strcmp(constructor->payload_type, "Int") == 0) ?
            KOFUN_SEMANTIC_VALIDATED : KOFUN_SEMANTIC_PROVISIONAL;
        if (written < 0 || (size_t)written >= sizeof(signature) ||
            constructor->payload_count > 1u ||
            !producer_add_discovery_candidate(
                producer,
                snapshot,
                KOFUN_STAGE2_DISCOVERY_CONSTRUCTOR,
                &constructor->symbol,
                constructor->name,
                status == KOFUN_SEMANTIC_VALIDATED ? signature : "",
                "",
                status,
                constructor->visibility)) {
            return false;
        }
    }
    snapshot->source_status = KOFUN_SOURCE_CHECKED;
    snapshot->completeness = KOFUN_SEMANTIC_COMPLETE;
    snapshot->committed = true;
    return true;
}

static bool producer_run(
    const KofunStage2SemanticInput *input,
    KofunSemanticSink *sink,
    bool cancellation_observed_after_commit,
    KofunSemanticBytes edition,
    KofunStage2InterfaceSnapshot *snapshot,
    KofunStage2DiscoverySnapshot *discovery_snapshot,
    KofunStage2SemanticResult *result
) {
    Producer producer;
    Stage2AuthorityContext authority_context;
    Stage2AuthorityResult authority;
    char *owned_source;
    if (result == NULL) return false;
    memset(result, 0, sizeof(*result));
    result->source_status = KOFUN_SOURCE_FAILED;
    result->completeness = KOFUN_SEMANTIC_PARTIAL;
    if (input == NULL ||
        (sink == NULL && snapshot == NULL && discovery_snapshot == NULL) ||
        input->source == NULL ||
        input->source_length > UINT32_MAX ||
        input->source_length > KOFUN_SEMANTIC_MAX_EVENT_BYTES ||
        input->source_length > SIZE_MAX - 1u ||
        input->logical_path.bytes == NULL ||
        input->logical_path.length == 0u ||
        input->logical_path.length > KOFUN_SEMANTIC_MAX_TEXT_BYTES ||
        !kofun_semantic_validate_logical_path(input->logical_path) ||
        (input->authority != KOFUN_STAGE2_SEMANTIC_COMPILE &&
         input->authority != KOFUN_STAGE2_SEMANTIC_OWNERSHIP)) {
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic producer input is invalid"
        );
        return false;
    }
    if (memchr(input->source, 0, input->source_length) != NULL) {
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic producer source encoding is invalid"
        );
        return false;
    }
    owned_source = (char *)malloc(input->source_length + 1u);
    if (owned_source == NULL) {
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic producer source allocation failed"
        );
        return false;
    }
    memcpy(owned_source, input->source, input->source_length);
    owned_source[input->source_length] = '\0';
    if (snapshot != NULL &&
        !producer_publication_surface_supported(owned_source, result)) {
        free(owned_source);
        return false;
    }
    {
        const char *limit_name = "";
        size_t limit_bound = 0u;
        size_t limit_count = 0u;
        int64_t limit_offset = 0;
        if (!producer_source_within_declaration_profile(
                owned_source, &limit_name, &limit_bound,
                &limit_count, &limit_offset)) {
            /* Sized to the destination so the message cannot be truncated
             * into a different claim: a detail cut at 160 bytes could end
             * mid-number and name a limit nobody has. */
            char detail[KOFUN_SEMANTIC_ERROR_DETAIL_BYTES];
            (void)snprintf(
                detail, sizeof(detail),
                "declaration limit exceeded: %s reached %zu at byte %lld; "
                "this producer projects at most %zu",
                limit_name, limit_count, (long long)limit_offset, limit_bound
            );
            free(owned_source);
            producer_set_tooling_error(
                result, "ETS04", 0u, PRODUCER_EVENT_NONE, detail
            );
            return false;
        }
    }
    if (!(input->authority == KOFUN_STAGE2_SEMANTIC_OWNERSHIP ?
          stage2_ownership_outcome(
              owned_source,
              &authority_context,
              &authority
          ) :
          stage2_compile_outcome(
              owned_source,
              &authority_context,
              &authority
          ))) {
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic compiler authority failed"
        );
        return false;
    }
    result->compiler_exit_class = authority.exit_class;
    result->token_span_committed = authority.token_span_committed;
    if (authority.diagnostic != NULL) {
        if (!producer_copy_authority_diagnostic(
                &authority_context,
                input->source_length,
                result)) {
            stage2_authority_result_destroy(&authority);
            free(owned_source);
            producer_set_tooling_error(
                result, "ETS04", 0u, PRODUCER_EVENT_NONE,
                "semantic diagnostic capture failed"
            );
            return false;
        }
    }
    if (!authority.token_span_committed) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        return false;
    }

    memset(&producer, 0, sizeof(producer));
    producer.input = input;
    producer.source = owned_source;
    producer.scope_hir = authority.scope_hir;
    producer.declaration_observations =
        authority.declaration_observations;
    producer.semantic_observations = authority.semantic_observations;
    producer.compiler_exit_class = authority.exit_class;
    producer.reference_limit = result->diagnostic_has_byte_span ?
        result->diagnostic_span.start :
        (uint32_t)input->source_length;
    if (!producer_prepare_source(&producer)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic source identity preparation failed"
        );
        return false;
    }

    if (authority.parse_committed &&
        (!producer_collect_types(&producer, authority.program_ir) ||
         !producer_collect_functions(&producer, authority.program_ir))) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic declaration projection failed"
        );
        return false;
    }
    if (authority.scope_committed &&
        (!producer_collect_scopes_and_bindings(&producer) ||
         !producer_finalize_function_types(&producer) ||
         !producer_collect_references(&producer) ||
         !producer_finalize_control_dependencies(&producer))) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic HIR projection failed"
        );
        return false;
    }
    if (authority.diagnostic != NULL &&
        !producer_add_failed_reference_prefix(&producer, result)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic failed-reference projection failed"
        );
        return false;
    }
    if (authority.diagnostic != NULL &&
        !producer_add_authority_diagnostic(
            &producer,
            result,
            &authority_context
        )) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic diagnostic projection failed"
        );
        return false;
    }
    if (authority.exit_class == 0u &&
        !producer_add_effect_facts(&producer)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "bounded effect inference failed"
        );
        return false;
    }
    if (authority.exit_class != 0u && authority.diagnostic == NULL) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "compiler failure has no source diagnostic"
        );
        return false;
    }
    if (authority.exit_class == 0u && authority.diagnostic != NULL) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "successful compiler result has a source diagnostic"
        );
        return false;
    }
    if (!producer_add_origin_facts(&producer)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic origin projection failed"
        );
        return false;
    }
    if (producer.resource_failed) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "semantic producer resource limit exceeded"
        );
        return false;
    }
    if ((snapshot != NULL || discovery_snapshot != NULL) &&
        (authority.exit_class != 0u || cancellation_observed_after_commit)) {
        if (cancellation_observed_after_commit && authority.exit_class == 0u) {
            result->source_status = KOFUN_SOURCE_CANCELLED;
        }
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        return false;
    }
    if (snapshot != NULL &&
        !producer_build_interface_snapshot(&producer, edition, snapshot, result)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        return false;
    }
    if (discovery_snapshot != NULL &&
        !producer_build_discovery_snapshot(&producer, discovery_snapshot)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        producer_set_tooling_error(
            result, "ETS04", 0u, PRODUCER_EVENT_NONE,
            "discovery snapshot projection failed"
        );
        return false;
    }
    if (sink != NULL && !producer_emit(
            &producer, sink,
            cancellation_observed_after_commit && authority.exit_class == 0u,
            result)) {
        stage2_authority_result_destroy(&authority);
        free(owned_source);
        return false;
    }
    stage2_authority_result_destroy(&authority);
    free(owned_source);
    return true;
}

bool kofun_stage2_produce_semantic_events(
    const KofunStage2SemanticInput *input,
    KofunSemanticSink *sink,
    bool cancellation_observed_after_commit,
    KofunStage2SemanticResult *result
) {
    KofunSemanticBytes no_edition = {NULL, 0u};
    return producer_run(
        input, sink, cancellation_observed_after_commit,
        no_edition, NULL, NULL, result
    );
}

bool kofun_stage2_compile_interface(
    const KofunStage2SemanticInput *input,
    KofunSemanticBytes edition,
    bool cancellation_observed_after_commit,
    KofunStage2InterfaceSnapshot *snapshot,
    KofunStage2SemanticResult *result
) {
    if (snapshot == NULL) return false;
    memset(snapshot, 0, sizeof(*snapshot));
    return producer_run(
        input, NULL, cancellation_observed_after_commit,
        edition, snapshot, NULL, result
    );
}

bool kofun_stage2_analyze_discovery(
    const KofunStage2SemanticInput *input,
    KofunStage2DiscoverySnapshot *snapshot,
    KofunStage2SemanticResult *result
) {
    KofunSemanticBytes no_edition = {NULL, 0u};
    bool succeeded;
    if (snapshot == NULL) return false;
    memset(snapshot, 0, sizeof(*snapshot));
    succeeded = producer_run(
        input, NULL, false, no_edition, NULL, snapshot, result
    );
    if (succeeded) {
        result->source_status = snapshot->source_status;
        result->completeness = snapshot->completeness;
    }
    return succeeded;
}

#ifndef KOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY
static uint8_t *producer_read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *bytes;
    if (file == NULL) return NULL;
    if (fseek(file, 0, SEEK_END) != 0) {
        (void)fclose(file);
        return NULL;
    }
    size = ftell(file);
    if (size < 0 || fseek(file, 0, SEEK_SET) != 0) {
        (void)fclose(file);
        return NULL;
    }
    bytes = (uint8_t *)malloc((size_t)size + 1u);
    if (bytes == NULL) {
        (void)fclose(file);
        return NULL;
    }
    if (fread(bytes, 1u, (size_t)size, file) != (size_t)size) {
        (void)fclose(file);
        free(bytes);
        return NULL;
    }
    if (fclose(file) != 0) {
        free(bytes);
        return NULL;
    }
    bytes[size] = 0u;
    *length = (size_t)size;
    return bytes;
}

int main(int argc, char **argv) {
    bool cancel = false;
    bool ownership_only = false;
    int offset = 1;
    uint8_t *source;
    size_t source_length;
    char *generation_end = NULL;
    unsigned long long generation;
    KofunStage2SemanticInput input;
    KofunStage2SemanticResult result;
    KofunSemanticStream *stream;
    KofunSemanticSink sink;
    const uint8_t *event_bytes;
    size_t event_length;
    if (argc == 6 && strcmp(argv[1], "--cancel-after-commit") == 0) {
        cancel = true;
        offset = 2;
    } else if (argc == 6 && strcmp(argv[1], "--check-ownership") == 0) {
        ownership_only = true;
        offset = 2;
    } else if (argc != 5) {
        fputs(
            "usage: kofun-stage2-semantic-events "
            "[--cancel-after-commit|--check-ownership] "
            "INPUT LOGICAL-PATH OUTPUT GENERATION\n",
            stderr
        );
        return 2;
    }
    errno = 0;
    generation = strtoull(argv[offset + 3], &generation_end, 10);
    if (errno != 0 || generation_end == argv[offset + 3] ||
        *generation_end != '\0') {
        fputs("semantic events: invalid generation\n", stderr);
        return 2;
    }
    source = producer_read_file(argv[offset], &source_length);
    if (source == NULL) {
        fputs("semantic events: cannot read source\n", stderr);
        return 3;
    }
    memset(&input, 0, sizeof(input));
    input.source = source;
    input.source_length = source_length;
    input.logical_path = producer_text(argv[offset + 1]);
    input.caller_generation = (uint64_t)generation;
    input.authority = ownership_only ?
        KOFUN_STAGE2_SEMANTIC_OWNERSHIP :
        KOFUN_STAGE2_SEMANTIC_COMPILE;
    stream = kofun_semantic_stream_create();
    if (stream == NULL) {
        free(source);
        return 3;
    }
    sink = kofun_semantic_stream_sink(stream);
    if (!kofun_stage2_produce_semantic_events(
            &input,
            &sink,
            cancel,
            &result)) {
        const KofunSemanticError *stream_error =
            kofun_semantic_stream_error(stream);
        if (result.has_source_diagnostic) {
            puts(result.diagnostic_fallback);
        }
        if (result.tooling_emission_failed) {
            (void)fprintf(
                stderr,
                "%s: %s\n",
                stream_error != NULL && stream_error->code[0] != '\0' ?
                    stream_error->code :
                    (result.tooling_error.code[0] == '\0' ?
                        "ETS03" : result.tooling_error.code),
                stream_error != NULL && stream_error->detail[0] != '\0' ?
                    stream_error->detail :
                    (result.tooling_error.detail[0] == '\0' ?
                        "semantic event production failed" :
                        result.tooling_error.detail)
            );
        }
        free(source);
        kofun_semantic_stream_destroy(stream);
        if (result.tooling_emission_failed) return 3;
        return result.compiler_exit_class == 0u ?
            1 : (int)result.compiler_exit_class;
    }
    if (!kofun_semantic_stream_bytes(stream, &event_bytes, &event_length) ||
        event_length == 0u ||
        !kofun_semantic_stream_commit(stream, argv[offset + 2])) {
        free(source);
        kofun_semantic_stream_destroy(stream);
        return 3;
    }
    if (result.has_source_diagnostic) {
        puts(result.diagnostic_fallback);
    }
    free(source);
    kofun_semantic_stream_destroy(stream);
    if (result.source_status == KOFUN_SOURCE_CANCELLED) return 1;
    return (int)result.compiler_exit_class;
}
#endif
