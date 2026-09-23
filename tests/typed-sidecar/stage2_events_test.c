#define _POSIX_C_SOURCE 200809L

#include "../../bootstrap/stage2/semantic_events.h"
#include "../../bootstrap/stage2/sha256.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            exit(1); \
        } \
    } while (0)

typedef struct {
    uint8_t *source;
    size_t source_length;
    KofunSemanticSource semantic_source;
    KofunSemanticId file_id;
} Fixture;

static KofunSemanticBytes text(const char *value) {
    KofunSemanticBytes result;
    result.bytes = (const uint8_t *)value;
    result.length = (uint32_t)strlen(value);
    return result;
}

static void id_from_text(const char *value, KofunSemanticId *id) {
    kofun_sha256(
        (const uint8_t *)value,
        strlen(value),
        id->bytes
    );
}

static int compare_ids(const void *left, const void *right) {
    return memcmp(
        ((const KofunSemanticId *)left)->bytes,
        ((const KofunSemanticId *)right)->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
}

static uint8_t *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *bytes;
    CHECK(file != NULL);
    CHECK(fseek(file, 0, SEEK_END) == 0);
    size = ftell(file);
    CHECK(size >= 0);
    CHECK(fseek(file, 0, SEEK_SET) == 0);
    bytes = (uint8_t *)malloc((size_t)size + 1u);
    CHECK(bytes != NULL);
    CHECK(fread(bytes, 1u, (size_t)size, file) == (size_t)size);
    CHECK(fclose(file) == 0);
    bytes[size] = 0u;
    *length = (size_t)size;
    return bytes;
}

static void fixture_init(Fixture *fixture, const char *source_path) {
    memset(fixture, 0, sizeof(*fixture));
    fixture->source = read_file(source_path, &fixture->source_length);
    id_from_text("package:anonymous", &fixture->semantic_source.package_id);
    id_from_text("module:anonymous-main", &fixture->semantic_source.module_id);
    id_from_text("file:src/main.kofun", &fixture->file_id);
    fixture->semantic_source.file_id = fixture->file_id;
    fixture->semantic_source.logical_path = text("src/main.kofun");
    fixture->semantic_source.source_bytes = fixture->source_length;
    kofun_sha256(
        fixture->source,
        fixture->source_length,
        fixture->semantic_source.source_sha256
    );
    fixture->semantic_source.edition = text("2026");
    fixture->semantic_source.semantic_compatibility = text("stage2-v1");
    fixture->semantic_source.caller_generation = UINT64_C(42);
}

static void fixture_destroy(Fixture *fixture) {
    free(fixture->source);
    memset(fixture, 0, sizeof(*fixture));
}

static KofunSemanticSpan token_span(
    const Fixture *fixture,
    const char *needle,
    size_t occurrence
) {
    const char *cursor = (const char *)fixture->source;
    const char *found = NULL;
    size_t index;
    for (index = 0u; index <= occurrence; index += 1u) {
        found = strstr(cursor, needle);
        CHECK(found != NULL);
        cursor = found + strlen(needle);
    }
    {
        KofunSemanticSpan span;
        span.start = (uint32_t)(found - (const char *)fixture->source);
        span.end = span.start + (uint32_t)strlen(needle);
        return span;
    }
}

static KofunSemanticId node_id(
    const Fixture *fixture,
    KofunSemanticNodeKind kind,
    KofunSemanticSpan span,
    uint32_t occurrence
) {
    KofunSemanticId result;
    kofun_semantic_derive_id(
        "kofun.sidecar.node/v1",
        &fixture->file_id,
        kind,
        span,
        occurrence,
        &result
    );
    return result;
}

static void test_node_identity_frame(const Fixture *fixture) {
    static const uint8_t expected[KOFUN_SEMANTIC_ID_BYTES] = {
        0x92u, 0xf0u, 0x1fu, 0x7cu, 0xdbu, 0xa8u, 0xa5u, 0x98u,
        0x0fu, 0x1fu, 0xafu, 0x91u, 0x27u, 0xcfu, 0xd8u, 0x71u,
        0x54u, 0x90u, 0x94u, 0x1du, 0x00u, 0x15u, 0x51u, 0x75u,
        0x22u, 0x7bu, 0xfcu, 0x02u, 0xf5u, 0xb1u, 0xf0u, 0x9eu
    };
    KofunSemanticSpan span = {
        0u, (uint32_t)fixture->source_length
    };
    KofunSemanticId actual = node_id(
        fixture,
        KOFUN_SEMANTIC_NODE_MODULE,
        span,
        0u
    );
    CHECK(memcmp(actual.bytes, expected, sizeof(expected)) == 0);
}

static bool emit_node(
    KofunSemanticSink *sink,
    KofunSemanticId id,
    KofunSemanticNodeKind kind,
    KofunSemanticSpan span,
    KofunSemanticStatus status,
    const KofunSemanticId *dependencies,
    uint16_t dependency_count,
    const KofunSemanticId *diagnostics,
    uint16_t diagnostic_count
) {
    KofunSemanticNode node;
    memset(&node, 0, sizeof(node));
    node.node_id = id;
    node.kind = kind;
    node.span = span;
    node.status = status;
    node.dependencies = dependencies;
    node.dependency_count = dependency_count;
    node.diagnostic_ids = diagnostics;
    node.diagnostic_count = diagnostic_count;
    return kofun_semantic_node(sink, &node);
}

static bool emit_identity(
    KofunSemanticSink *sink,
    KofunSemanticId owner,
    KofunSemanticIdentityKind kind,
    const char *label,
    KofunSemanticId *value
) {
    KofunSemanticIdentity identity;
    memset(&identity, 0, sizeof(identity));
    identity.owner_node_id = owner;
    identity.kind = kind;
    id_from_text(label, &identity.value);
    identity.status = KOFUN_SEMANTIC_VALIDATED;
    if (value != NULL) *value = identity.value;
    return kofun_semantic_identity(sink, &identity);
}

static bool emit_fact(
    KofunSemanticSink *sink,
    KofunSemanticId owner,
    KofunSemanticFactKind kind,
    KofunSemanticStatus status,
    const char *display,
    const char *reason,
    const KofunSemanticId *diagnostics,
    uint16_t diagnostic_count
) {
    KofunSemanticFact fact;
    memset(&fact, 0, sizeof(fact));
    fact.owner_node_id = owner;
    fact.kind = kind;
    fact.status = status;
    fact.display = text(display);
    fact.reason = text(reason);
    fact.diagnostic_ids = diagnostics;
    fact.diagnostic_count = diagnostic_count;
    return kofun_semantic_fact(sink, &fact);
}

static bool emit_clean_records(
    KofunSemanticSink *sink,
    const Fixture *fixture
) {
    KofunSemanticSpan spans[12];
    KofunSemanticId nodes[12];
    KofunSemanticId later_symbol;
    KofunSemanticId constructor_symbol;
    KofunSemanticReference reference;
    size_t index;
    spans[0].start = 0u;
    spans[0].end = (uint32_t)fixture->source_length;
    spans[1] = token_span(fixture, "MaybeInt", 0u);
    spans[2] = token_span(fixture, "Present", 0u);
    spans[3] = token_span(fixture, "later", 0u);
    spans[4] = token_span(fixture, "value", 0u);
    spans[5] = token_span(fixture, "copied", 0u);
    spans[6] = token_span(fixture, "main", 0u);
    spans[7] = token_span(fixture, "current", 0u);
    spans[8] = token_span(fixture, "later", 1u);
    spans[9] = token_span(fixture, "Present", 1u);
    spans[10] = token_span(fixture, "if", 0u);
    spans[11] = token_span(fixture, "match", 0u);
    nodes[0] = node_id(fixture, KOFUN_SEMANTIC_NODE_MODULE, spans[0], 0u);
    nodes[1] = node_id(fixture, KOFUN_SEMANTIC_NODE_ADT, spans[1], 0u);
    nodes[2] = node_id(
        fixture,
        KOFUN_SEMANTIC_NODE_CONSTRUCTOR,
        spans[2],
        0u
    );
    nodes[3] = node_id(
        fixture,
        KOFUN_SEMANTIC_NODE_FUNCTION,
        spans[3],
        0u
    );
    nodes[4] = node_id(
        fixture,
        KOFUN_SEMANTIC_NODE_PARAMETER,
        spans[4],
        0u
    );
    nodes[5] = node_id(fixture, KOFUN_SEMANTIC_NODE_LOCAL, spans[5], 0u);
    nodes[6] = node_id(
        fixture,
        KOFUN_SEMANTIC_NODE_FUNCTION,
        spans[6],
        1u
    );
    nodes[7] = node_id(fixture, KOFUN_SEMANTIC_NODE_LOCAL, spans[7], 1u);
    nodes[8] = node_id(fixture, KOFUN_SEMANTIC_NODE_CALL, spans[8], 0u);
    nodes[9] = node_id(fixture, KOFUN_SEMANTIC_NODE_CALL, spans[9], 1u);
    nodes[10] = node_id(fixture, KOFUN_SEMANTIC_NODE_IF, spans[10], 0u);
    nodes[11] = node_id(fixture, KOFUN_SEMANTIC_NODE_MATCH, spans[11], 0u);

    if (!kofun_semantic_begin(sink, &fixture->semantic_source)) return false;
    for (index = 0u; index < 12u; index += 1u) {
        KofunSemanticNodeKind kind = index == 0u ?
            KOFUN_SEMANTIC_NODE_MODULE :
            (index == 1u ? KOFUN_SEMANTIC_NODE_ADT :
             (index == 2u ? KOFUN_SEMANTIC_NODE_CONSTRUCTOR :
              (index == 3u || index == 6u ?
               KOFUN_SEMANTIC_NODE_FUNCTION :
               (index == 4u ? KOFUN_SEMANTIC_NODE_PARAMETER :
                (index == 5u || index == 7u ?
                 KOFUN_SEMANTIC_NODE_LOCAL :
                 (index == 8u || index == 9u ?
                  KOFUN_SEMANTIC_NODE_CALL :
                  (index == 10u ?
                   KOFUN_SEMANTIC_NODE_IF :
                   KOFUN_SEMANTIC_NODE_MATCH)))))));
        if (!emit_node(
                sink,
                nodes[index],
                kind,
                spans[index],
                KOFUN_SEMANTIC_VALIDATED,
                NULL,
                0u,
                NULL,
                0u)) {
            return false;
        }
    }
    if (!emit_identity(
            sink,
            nodes[1],
            KOFUN_SEMANTIC_ID_TYPE,
            "type:MaybeInt",
            NULL) ||
        !emit_identity(
            sink,
            nodes[2],
            KOFUN_SEMANTIC_ID_CONSTRUCTOR,
            "constructor:MaybeInt.Present",
            &constructor_symbol) ||
        !emit_identity(
            sink,
            nodes[3],
            KOFUN_SEMANTIC_ID_SYMBOL,
            "function:later",
            &later_symbol) ||
        !emit_identity(
            sink,
            nodes[4],
            KOFUN_SEMANTIC_ID_BINDING,
            "binding:later.value",
            NULL) ||
        !emit_identity(
            sink,
            nodes[5],
            KOFUN_SEMANTIC_ID_BINDING,
            "binding:later.copied",
            NULL) ||
        !emit_identity(
            sink,
            nodes[6],
            KOFUN_SEMANTIC_ID_SYMBOL,
            "function:main",
            NULL) ||
        !emit_identity(
            sink,
            nodes[7],
            KOFUN_SEMANTIC_ID_BINDING,
            "binding:main.current",
            NULL)) {
        return false;
    }
    memset(&reference, 0, sizeof(reference));
    id_from_text("reference:main.later", &reference.reference_id);
    reference.source_node_id = nodes[8];
    reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
    reference.span = spans[8];
    reference.status = KOFUN_SEMANTIC_VALIDATED;
    reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
    reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
    reference.target_value = later_symbol;
    if (!kofun_semantic_reference(sink, &reference)) return false;
    id_from_text("reference:main.Present", &reference.reference_id);
    reference.source_node_id = nodes[9];
    reference.span = spans[9];
    reference.name_space = KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR;
    reference.target_kind = KOFUN_SEMANTIC_ID_CONSTRUCTOR;
    reference.target_value = constructor_symbol;
    if (!kofun_semantic_reference(sink, &reference)) return false;

    if (!emit_fact(
            sink, nodes[4], KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "Int", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[5], KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "Int", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[7], KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "Int", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[8], KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "Int", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[9], KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "MaybeInt", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[5], KOFUN_SEMANTIC_FACT_OWNERSHIP,
            KOFUN_SEMANTIC_VALIDATED, "copy", "", NULL, 0u) ||
        !emit_fact(
            sink, nodes[7], KOFUN_SEMANTIC_FACT_OWNERSHIP,
            KOFUN_SEMANTIC_VALIDATED, "mutable-local", "", NULL, 0u)) {
        return false;
    }
    return kofun_semantic_end(
        sink,
        KOFUN_SOURCE_CHECKED,
        KOFUN_SEMANTIC_COMPLETE
    );
}

static bool emit_partial_records(
    KofunSemanticSink *sink,
    const Fixture *fixture
) {
    KofunSemanticSource source = fixture->semantic_source;
    KofunSemanticSpan module_span = {
        0u, (uint32_t)fixture->source_length
    };
    KofunSemanticSpan function_span = token_span(fixture, "later", 0u);
    KofunSemanticSpan local_span = token_span(fixture, "copied", 0u);
    KofunSemanticSpan call_span = token_span(fixture, "later", 1u);
    KofunSemanticSpan recovery_span = token_span(fixture, "match", 0u);
    KofunSemanticId module = node_id(
        fixture, KOFUN_SEMANTIC_NODE_MODULE, module_span, 0u
    );
    KofunSemanticId function = node_id(
        fixture, KOFUN_SEMANTIC_NODE_FUNCTION, function_span, 0u
    );
    KofunSemanticId local = node_id(
        fixture, KOFUN_SEMANTIC_NODE_LOCAL, local_span, 0u
    );
    KofunSemanticId call = node_id(
        fixture, KOFUN_SEMANTIC_NODE_CALL, call_span, 0u
    );
    KofunSemanticId recovery = node_id(
        fixture, KOFUN_SEMANTIC_NODE_ERROR_PATTERN, recovery_span, 0u
    );
    KofunSemanticId diagnostic_id;
    KofunSemanticReference reference;
    KofunSemanticDiagnostic diagnostic;
    KofunSemanticRelated related;
    KofunSemanticEdit edit;
    uint32_t remedy = 7u;
    source.compiler_exit_class = 1u;
    id_from_text("diagnostic:E2S16:unknown-call", &diagnostic_id);
    if (!kofun_semantic_begin(sink, &source) ||
        !emit_node(
            sink, module, KOFUN_SEMANTIC_NODE_MODULE, module_span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u) ||
        !emit_node(
            sink, function, KOFUN_SEMANTIC_NODE_FUNCTION, function_span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u) ||
        !emit_node(
            sink, local, KOFUN_SEMANTIC_NODE_LOCAL, local_span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u) ||
        !emit_node(
            sink, call, KOFUN_SEMANTIC_NODE_CALL, call_span,
            KOFUN_SEMANTIC_ERROR, NULL, 0u, &diagnostic_id, 1u) ||
        !emit_node(
            sink, recovery, KOFUN_SEMANTIC_NODE_ERROR_PATTERN, recovery_span,
            KOFUN_SEMANTIC_ERROR, NULL, 0u, &diagnostic_id, 1u) ||
        !emit_identity(
            sink, function, KOFUN_SEMANTIC_ID_SYMBOL,
            "function:later", NULL) ||
        !emit_identity(
            sink, local, KOFUN_SEMANTIC_ID_BINDING,
            "binding:later.copied", NULL)) {
        return false;
    }
    memset(&reference, 0, sizeof(reference));
    id_from_text("reference:unknown-call", &reference.reference_id);
    reference.source_node_id = call;
    reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
    reference.span = call_span;
    reference.status = KOFUN_SEMANTIC_ERROR;
    reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
    reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
    reference.hidden_reason = text(
        KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE
    );
    reference.diagnostic_ids = &diagnostic_id;
    reference.diagnostic_count = 1u;
    if (!kofun_semantic_reference(sink, &reference) ||
        !emit_fact(
            sink, function, KOFUN_SEMANTIC_FACT_TYPE,
            KOFUN_SEMANTIC_VALIDATED, "Int -> Int", "", NULL, 0u) ||
        !emit_fact(
            sink, local, KOFUN_SEMANTIC_FACT_OWNERSHIP,
            KOFUN_SEMANTIC_ERROR, "",
            KOFUN_SEMANTIC_REASON_MOVE_AFTER_BORROW,
            &diagnostic_id, 1u)) {
        return false;
    }
    memset(&diagnostic, 0, sizeof(diagnostic));
    diagnostic.diagnostic_id = diagnostic_id;
    diagnostic.code = text("E2S16");
    diagnostic.category = text("name-resolution");
    diagnostic.severity = KOFUN_SEMANTIC_DIAGNOSTIC_ERROR;
    diagnostic.template_id = text("unknown-function");
    diagnostic.primary_file_id = fixture->file_id;
    diagnostic.primary_span = call_span;
    diagnostic.fallback_text = text("unknown function");
    diagnostic.affected_ids = &call;
    diagnostic.affected_count = 1u;
    diagnostic.remedy_ids = &remedy;
    diagnostic.remedy_count = 1u;
    memset(&related, 0, sizeof(related));
    related.file_id = fixture->file_id;
    related.span = function_span;
    related.label = text("validated declaration retained before failure");
    diagnostic.related = &related;
    diagnostic.related_count = 1u;
    memset(&edit, 0, sizeof(edit));
    edit.remedy_id = remedy;
    edit.file_id = fixture->file_id;
    edit.span = call_span;
    edit.replacement = text("later");
    diagnostic.edits = &edit;
    diagnostic.edit_count = 1u;
    if (!kofun_semantic_diagnostic(sink, &diagnostic)) return false;
    return kofun_semantic_end(
        sink,
        KOFUN_SOURCE_FAILED,
        KOFUN_SEMANTIC_PARTIAL
    );
}

typedef struct {
    int reject;
    unsigned calls[7];
} RejectingSink;

static bool reject_call(RejectingSink *sink, int kind) {
    sink->calls[kind - 1] += 1u;
    return sink->reject != kind;
}

static bool reject_begin(void *context, const KofunSemanticSource *source) {
    (void)source;
    return reject_call((RejectingSink *)context, 1);
}

static bool reject_node(void *context, const KofunSemanticNode *node) {
    (void)node;
    return reject_call((RejectingSink *)context, 2);
}

static bool reject_identity(
    void *context,
    const KofunSemanticIdentity *identity
) {
    (void)identity;
    return reject_call((RejectingSink *)context, 3);
}

static bool reject_fact(void *context, const KofunSemanticFact *fact) {
    (void)fact;
    return reject_call((RejectingSink *)context, 4);
}

static bool reject_reference(
    void *context,
    const KofunSemanticReference *reference
) {
    (void)reference;
    return reject_call((RejectingSink *)context, 5);
}

static bool reject_diagnostic(
    void *context,
    const KofunSemanticDiagnostic *diagnostic
) {
    (void)diagnostic;
    return reject_call((RejectingSink *)context, 6);
}

static bool reject_end(
    void *context,
    KofunSourceStatus status,
    KofunCompleteness completeness
) {
    (void)status;
    (void)completeness;
    return reject_call((RejectingSink *)context, 7);
}

static KofunSemanticSink rejecting_sink(RejectingSink *context) {
    KofunSemanticSink sink;
    sink.context = context;
    sink.begin = reject_begin;
    sink.node = reject_node;
    sink.identity = reject_identity;
    sink.fact = reject_fact;
    sink.reference = reject_reference;
    sink.diagnostic = reject_diagnostic;
    sink.cancellation_observed = NULL;
    sink.end = reject_end;
    return sink;
}

static void test_sink_rejection(const Fixture *fixture) {
    int reject;
    KofunSemanticNode node;
    KofunSemanticIdentity identity;
    KofunSemanticFact fact;
    KofunSemanticReference reference;
    KofunSemanticDiagnostic diagnostic;
    memset(&node, 0, sizeof(node));
    memset(&identity, 0, sizeof(identity));
    memset(&fact, 0, sizeof(fact));
    memset(&reference, 0, sizeof(reference));
    memset(&diagnostic, 0, sizeof(diagnostic));
    for (reject = 1; reject <= 7; reject += 1) {
        RejectingSink context;
        KofunSemanticSink sink;
        bool accepted;
        memset(&context, 0, sizeof(context));
        context.reject = reject;
        sink = rejecting_sink(&context);
        switch (reject) {
            case 1:
                accepted = kofun_semantic_begin(
                    &sink, &fixture->semantic_source
                );
                break;
            case 2:
                accepted = kofun_semantic_node(&sink, &node);
                break;
            case 3:
                accepted = kofun_semantic_identity(&sink, &identity);
                break;
            case 4:
                accepted = kofun_semantic_fact(&sink, &fact);
                break;
            case 5:
                accepted = kofun_semantic_reference(&sink, &reference);
                break;
            case 6:
                accepted = kofun_semantic_diagnostic(&sink, &diagnostic);
                break;
            default:
                accepted = kofun_semantic_end(
                    &sink,
                    KOFUN_SOURCE_CHECKED,
                    KOFUN_SEMANTIC_COMPLETE
                );
                break;
        }
        CHECK(!accepted);
        CHECK(context.calls[reject - 1] == 1u);
    }
}

static void test_strict_invariant_rejection(const Fixture *fixture) {
    KofunSemanticSpan span = {
        0u, (uint32_t)fixture->source_length
    };
    KofunSemanticId module = node_id(
        fixture, KOFUN_SEMANTIC_NODE_MODULE, span, 0u
    );
    KofunSemanticStream *stream;
    KofunSemanticSink sink;

    {
        KofunSemanticId second_owner = node_id(
            fixture, KOFUN_SEMANTIC_NODE_MODULE, span, 1u
        );
        KofunSemanticId shared_identity;
        KofunSemanticIdentity identity;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(emit_node(
            &sink, second_owner, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(emit_identity(
            &sink,
            module,
            KOFUN_SEMANTIC_ID_SYMBOL,
            "identity:shared-owner-pair",
            &shared_identity
        ));
        memset(&identity, 0, sizeof(identity));
        identity.owner_node_id = second_owner;
        identity.kind = KOFUN_SEMANTIC_ID_SYMBOL;
        identity.value = shared_identity;
        identity.status = KOFUN_SEMANTIC_VALIDATED;
        CHECK(!kofun_semantic_identity(&sink, &identity));
        CHECK(strcmp(
            kofun_semantic_stream_error(stream)->code,
            "ETS03"
        ) == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticSource source = fixture->semantic_source;
        source.compiler_exit_class = 4u;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(!kofun_semantic_begin(&sink, &source));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(emit_node(
        &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    CHECK(!kofun_semantic_end(
        &sink, (KofunSourceStatus)255, KOFUN_SEMANTIC_PARTIAL
    ));
    CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
    kofun_semantic_stream_destroy(stream);

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(emit_node(
        &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    CHECK(!kofun_semantic_end(
        &sink, KOFUN_SOURCE_FAILED, (KofunCompleteness)255
    ));
    CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
    kofun_semantic_stream_destroy(stream);

    {
        KofunSemanticReference reference;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text("reference:invalid-target-kind", &reference.reference_id);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_UNAVAILABLE;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
        reference.target_kind = (KofunSemanticIdentityKind)255;
        reference.hidden_reason = text("not-resolved");
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId arbitrary_target;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text("reference:arbitrary-target", &reference.reference_id);
        id_from_text("identity:not-emitted", &arbitrary_target);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_VALIDATED;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.target_value = arbitrary_target;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId arbitrary_target;
        KofunSemanticId diagnostic_id;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text(
            "reference:error-arbitrary-target",
            &reference.reference_id
        );
        id_from_text("identity:not-emitted", &arbitrary_target);
        id_from_text("diagnostic:future", &diagnostic_id);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_ERROR;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.target_value = arbitrary_target;
        reference.diagnostic_ids = &diagnostic_id;
        reference.diagnostic_count = 1u;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticIdentity identity;
        KofunSemanticReference reference;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&identity, 0, sizeof(identity));
        identity.owner_node_id = module;
        identity.kind = KOFUN_SEMANTIC_ID_SYMBOL;
        identity.status = KOFUN_SEMANTIC_UNAVAILABLE;
        id_from_text("identity:unavailable", &identity.value);
        CHECK(kofun_semantic_identity(&sink, &identity));
        memset(&reference, 0, sizeof(reference));
        id_from_text(
            "reference:validated-unavailable-target",
            &reference.reference_id
        );
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_VALIDATED;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.target_value = identity.value;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId symbol;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(emit_identity(
            &sink, module, KOFUN_SEMANTIC_ID_SYMBOL,
            "identity:known-symbol", &symbol
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text("reference:wrong-target-kind", &reference.reference_id);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_TYPE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_VALIDATED;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_TYPE;
        reference.target_value = symbol;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId symbol;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(emit_identity(
            &sink, module, KOFUN_SEMANTIC_ID_SYMBOL,
            "identity:known-incompatible-symbol", &symbol
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text(
            "reference:incompatible-emitted-target",
            &reference.reference_id
        );
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_TYPE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_VALIDATED;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_VISIBLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.target_value = symbol;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(
            kofun_semantic_stream_error(stream)->code,
            "ETS03"
        ) == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId symbol;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(emit_identity(
            &sink, module, KOFUN_SEMANTIC_ID_SYMBOL,
            "identity:known-incompatible-safe-kind", &symbol
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text(
            "reference:incompatible-safe-kind",
            &reference.reference_id
        );
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_TYPE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_UNAVAILABLE;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.hidden_reason = text(
            KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE
        );
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(
            kofun_semantic_stream_error(stream)->code,
            "ETS03"
        ) == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text(
            "reference:validated-non-visible",
            &reference.reference_id
        );
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_VALIDATED;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.hidden_reason = text(
            KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE
        );
        CHECK(!kofun_semantic_reference(&sink, &reference));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId diagnostic_id;
        const KofunSemanticError *error;
        const char *private_reason = "secret/path/private-name";
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text("reference:unsafe-reason", &reference.reference_id);
        id_from_text("diagnostic:future", &diagnostic_id);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_ERROR;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.hidden_reason = text(private_reason);
        reference.diagnostic_ids = &diagnostic_id;
        reference.diagnostic_count = 1u;
        CHECK(!kofun_semantic_reference(&sink, &reference));
        error = kofun_semantic_stream_error(stream);
        CHECK(error != NULL);
        CHECK(strcmp(error->code, "ETS03") == 0);
        CHECK(strstr(error->detail, private_reason) == NULL);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticReference reference;
        KofunSemanticId diagnostic_id;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&reference, 0, sizeof(reference));
        id_from_text("reference:safe-reason", &reference.reference_id);
        id_from_text("diagnostic:future", &diagnostic_id);
        reference.source_node_id = module;
        reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
        reference.span = span;
        reference.status = KOFUN_SEMANTIC_ERROR;
        reference.target_shape = KOFUN_SEMANTIC_TARGET_UNAVAILABLE;
        reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
        reference.hidden_reason = text(
            KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE
        );
        reference.diagnostic_ids = &diagnostic_id;
        reference.diagnostic_count = 1u;
        CHECK(kofun_semantic_reference(&sink, &reference));
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticFact fact;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&fact, 0, sizeof(fact));
        fact.owner_node_id = module;
        fact.kind = KOFUN_SEMANTIC_FACT_TYPE;
        fact.status = KOFUN_SEMANTIC_UNAVAILABLE;
        fact.display = text("fabricated-type");
        fact.reason = text("not-proven");
        CHECK(!kofun_semantic_fact(&sink, &fact));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticFact fact;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&fact, 0, sizeof(fact));
        fact.owner_node_id = module;
        fact.kind = KOFUN_SEMANTIC_FACT_TYPE;
        fact.status = KOFUN_SEMANTIC_UNAVAILABLE;
        fact.reason = text(KOFUN_SEMANTIC_REASON_TYPE_UNAVAILABLE);
        CHECK(kofun_semantic_fact(&sink, &fact));
        kofun_semantic_stream_destroy(stream);
    }

    {
        KofunSemanticDiagnostic diagnostic;
        KofunSemanticId dangling;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
        CHECK(emit_node(
            &sink, module, KOFUN_SEMANTIC_NODE_MODULE, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        memset(&diagnostic, 0, sizeof(diagnostic));
        id_from_text("diagnostic:dangling-affected", &diagnostic.diagnostic_id);
        id_from_text("node:not-emitted", &dangling);
        diagnostic.code = text("E2S99");
        diagnostic.category = text("test");
        diagnostic.severity = KOFUN_SEMANTIC_DIAGNOSTIC_ERROR;
        diagnostic.template_id = text("dangling-affected");
        diagnostic.primary_file_id = fixture->file_id;
        diagnostic.primary_span = span;
        diagnostic.fallback_text = text("dangling affected identity");
        diagnostic.affected_ids = &dangling;
        diagnostic.affected_count = 1u;
        CHECK(!kofun_semantic_diagnostic(&sink, &diagnostic));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
        kofun_semantic_stream_destroy(stream);
    }
}

static void test_early_and_cancellation(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    KofunSemanticSpan span = {0u, 0u};
    KofunSemanticId id = node_id(
        fixture, KOFUN_SEMANTIC_NODE_MODULE, span, 0u
    );
    const uint8_t *bytes;
    size_t length;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(!emit_node(
        &sink, id, KOFUN_SEMANTIC_NODE_MODULE, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    CHECK(!kofun_semantic_stream_bytes(stream, &bytes, &length));
    CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS03") == 0);
    kofun_semantic_stream_destroy(stream);

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    kofun_semantic_stream_observe_cancellation(stream);
    CHECK(!kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(!kofun_semantic_stream_bytes(stream, &bytes, &length));
    kofun_semantic_stream_destroy(stream);

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(emit_node(
        &sink, id, KOFUN_SEMANTIC_NODE_MODULE, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    kofun_semantic_stream_observe_cancellation(stream);
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CANCELLED, KOFUN_SEMANTIC_PARTIAL
    ));
    CHECK(kofun_semantic_stream_bytes(stream, &bytes, &length));
    CHECK(kofun_semantic_validate_stream(bytes, length, NULL));
    kofun_semantic_stream_destroy(stream);

    {
        KofunSemanticSource nonzero = fixture->semantic_source;
        nonzero.compiler_exit_class = 1u;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(kofun_semantic_begin(&sink, &nonzero));
        kofun_semantic_stream_observe_cancellation(stream);
        CHECK(!kofun_semantic_end(
            &sink, KOFUN_SOURCE_CANCELLED, KOFUN_SEMANTIC_PARTIAL
        ));
        CHECK(strcmp(
            kofun_semantic_stream_error(stream)->code,
            "ETS03"
        ) == 0);
        kofun_semantic_stream_destroy(stream);
    }
}

static void test_relation_limits(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    KofunSemanticId dependencies[KOFUN_SEMANTIC_MAX_RELATIONS + 1u];
    KofunSemanticId owner;
    KofunSemanticSpan span = {0u, 0u};
    size_t index;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    for (index = 0u; index < KOFUN_SEMANTIC_MAX_RELATIONS; index += 1u) {
        char label[32];
        (void)snprintf(label, sizeof(label), "dependency:%zu", index);
        id_from_text(label, &dependencies[index]);
    }
    qsort(
        dependencies,
        KOFUN_SEMANTIC_MAX_RELATIONS,
        sizeof(dependencies[0]),
        compare_ids
    );
    for (index = 0u; index < KOFUN_SEMANTIC_MAX_RELATIONS; index += 1u) {
        CHECK(emit_node(
            &sink,
            dependencies[index],
            KOFUN_SEMANTIC_NODE_LOCAL,
            span,
            KOFUN_SEMANTIC_VALIDATED,
            NULL,
            0u,
            NULL,
            0u
        ));
    }
    id_from_text("dependency-owner", &owner);
    CHECK(emit_node(
        &sink,
        owner,
        KOFUN_SEMANTIC_NODE_FUNCTION,
        span,
        KOFUN_SEMANTIC_VALIDATED,
        dependencies,
        KOFUN_SEMANTIC_MAX_RELATIONS,
        NULL,
        0u
    ));
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
    ));
    kofun_semantic_stream_destroy(stream);

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    for (index = 0u; index < KOFUN_SEMANTIC_MAX_RELATIONS + 1u; index += 1u) {
        char label[32];
        (void)snprintf(label, sizeof(label), "over-dependency:%zu", index);
        id_from_text(label, &dependencies[index]);
    }
    qsort(
        dependencies,
        KOFUN_SEMANTIC_MAX_RELATIONS + 1u,
        sizeof(dependencies[0]),
        compare_ids
    );
    id_from_text("over-dependency-owner", &owner);
    CHECK(!emit_node(
        &sink,
        owner,
        KOFUN_SEMANTIC_NODE_FUNCTION,
        span,
        KOFUN_SEMANTIC_VALIDATED,
        dependencies,
        KOFUN_SEMANTIC_MAX_RELATIONS + 1u,
        NULL,
        0u
    ));
    CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS04") == 0);
    kofun_semantic_stream_destroy(stream);
}

static void initialize_limit_diagnostic(
    const Fixture *fixture,
    const char *identity,
    KofunSemanticDiagnostic *diagnostic
) {
    KofunSemanticSpan span = {0u, 0u};
    memset(diagnostic, 0, sizeof(*diagnostic));
    id_from_text(identity, &diagnostic->diagnostic_id);
    diagnostic->code = text("W2S01");
    diagnostic->category = text("test");
    diagnostic->severity = KOFUN_SEMANTIC_DIAGNOSTIC_WARNING;
    diagnostic->template_id = text("nested-list-limit");
    diagnostic->primary_file_id = fixture->file_id;
    diagnostic->primary_span = span;
    diagnostic->fallback_text = text("nested list limit");
}

static void expect_uncommitted_limit_failure(
    KofunSemanticStream *stream,
    const char *destination
) {
    const uint8_t *bytes;
    size_t length;
    struct stat status;
    CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS04") == 0);
    CHECK(!kofun_semantic_stream_bytes(stream, &bytes, &length));
    CHECK(!kofun_semantic_stream_commit(stream, destination));
    CHECK(lstat(destination, &status) != 0);
    CHECK(errno == ENOENT);
}

static void test_nested_diagnostic_list_limits(
    const Fixture *fixture,
    const char *work
) {
    const uint32_t related_exact =
        KOFUN_SEMANTIC_MAX_TEXT_BYTES -
        (2u + KOFUN_SEMANTIC_ID_BYTES + 4u + 4u + 2u);
    const uint32_t edit_exact =
        KOFUN_SEMANTIC_MAX_TEXT_BYTES -
        (2u + 4u + KOFUN_SEMANTIC_ID_BYTES + 4u + 4u + 2u);
    uint8_t *related_text = (uint8_t *)malloc(related_exact + 1u);
    uint8_t *edit_text = (uint8_t *)malloc(edit_exact + 1u);
    KofunSemanticStream *stream;
    KofunSemanticSink sink;
    KofunSemanticDiagnostic diagnostic;
    KofunSemanticRelated related;
    KofunSemanticEdit edit;
    uint32_t remedy = 1u;
    const uint8_t *bytes;
    size_t length;
    char destination[1024];
    CHECK(related_exact == 4052u);
    CHECK(edit_exact == 4048u);
    CHECK(related_text != NULL);
    CHECK(edit_text != NULL);
    memset(related_text, 'r', related_exact + 1u);
    memset(edit_text, 'e', edit_exact + 1u);

    memset(&related, 0, sizeof(related));
    related.file_id = fixture->file_id;
    related.label.bytes = related_text;
    related.label.length = related_exact;
    initialize_limit_diagnostic(
        fixture, "diagnostic:related-exact", &diagnostic
    );
    diagnostic.related = &related;
    diagnostic.related_count = 1u;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(kofun_semantic_diagnostic(&sink, &diagnostic));
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
    ));
    CHECK(kofun_semantic_stream_bytes(stream, &bytes, &length));
    CHECK(kofun_semantic_validate_stream(bytes, length, NULL));
    kofun_semantic_stream_destroy(stream);

    related.label.length = related_exact + 1u;
    initialize_limit_diagnostic(
        fixture, "diagnostic:related-over", &diagnostic
    );
    diagnostic.related = &related;
    diagnostic.related_count = 1u;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(!kofun_semantic_diagnostic(&sink, &diagnostic));
    (void)snprintf(
        destination, sizeof(destination), "%s/related-over.kse", work
    );
    expect_uncommitted_limit_failure(stream, destination);
    kofun_semantic_stream_destroy(stream);

    memset(&edit, 0, sizeof(edit));
    edit.remedy_id = remedy;
    edit.file_id = fixture->file_id;
    edit.replacement.bytes = edit_text;
    edit.replacement.length = edit_exact;
    initialize_limit_diagnostic(
        fixture, "diagnostic:edit-exact", &diagnostic
    );
    diagnostic.remedy_ids = &remedy;
    diagnostic.remedy_count = 1u;
    diagnostic.edits = &edit;
    diagnostic.edit_count = 1u;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(kofun_semantic_diagnostic(&sink, &diagnostic));
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
    ));
    CHECK(kofun_semantic_stream_bytes(stream, &bytes, &length));
    CHECK(kofun_semantic_validate_stream(bytes, length, NULL));
    kofun_semantic_stream_destroy(stream);

    edit.replacement.length = edit_exact + 1u;
    initialize_limit_diagnostic(
        fixture, "diagnostic:edit-over", &diagnostic
    );
    diagnostic.remedy_ids = &remedy;
    diagnostic.remedy_count = 1u;
    diagnostic.edits = &edit;
    diagnostic.edit_count = 1u;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(!kofun_semantic_diagnostic(&sink, &diagnostic));
    (void)snprintf(
        destination, sizeof(destination), "%s/edit-over.kse", work
    );
    expect_uncommitted_limit_failure(stream, destination);
    kofun_semantic_stream_destroy(stream);

    free(edit_text);
    free(related_text);
}

static void test_text_limits(const Fixture *fixture) {
    static const char *valid_paths[] = {
        "src/main.kofun",
        "src/name:value.kofun",
        "1abc:main.kofun",
        "1:main.kofun",
        "-abc:main.kofun",
        "-:main.kofun",
        ":main.kofun",
        "_abc:main.kofun",
        "a_b:main.kofun",
        "src/a+b:main.kofun",
        "src/a:main.kofun",
        "a/b:main.kofun",
        "a",
        "\xc3\xa9:main.kofun",
        "a\xc3\xa9:main.kofun"
    };
    static const char *invalid_paths[] = {
        "",
        "/src/main.kofun",
        "C:/src/main.kofun",
        "src//main.kofun",
        "src/./main.kofun",
        "src/../main.kofun",
        "../src/main.kofun",
        "src/main.kofun/",
        "src\\main.kofun",
        "file://main.kofun",
        "https:remote.kofun",
        "mailto:src.kofun",
        "abc:main.kofun",
        "git+ssh:main.kofun",
        "a.b-c:main.kofun",
        "a0:main.kofun",
        "a:main.kofun",
        "Z:main.kofun",
        "A0+.-:main.kofun",
        "a:",
        "1://main.kofun",
        "src/\nmain.kofun"
    };
    static const uint8_t decomposed_path[] = {
        's', 'r', 'c', '/', 'e', 0xcc, 0x81,
        '.', 'k', 'o', 'f', 'u', 'n'
    };
    KofunSemanticStream *stream;
    KofunSemanticSink sink;
    KofunSemanticSource source = fixture->semantic_source;
    uint8_t *path = (uint8_t *)malloc(KOFUN_SEMANTIC_MAX_TEXT_BYTES + 1u);
    CHECK(path != NULL);
    memset(path, 'a', KOFUN_SEMANTIC_MAX_TEXT_BYTES + 1u);
    source.logical_path.bytes = path;
    source.logical_path.length = KOFUN_SEMANTIC_MAX_TEXT_BYTES;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &source));
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
    ));
    kofun_semantic_stream_destroy(stream);

    source.logical_path.length = KOFUN_SEMANTIC_MAX_TEXT_BYTES + 1u;
    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(!kofun_semantic_begin(&sink, &source));
    kofun_semantic_stream_destroy(stream);
    {
        size_t index;
        for (index = 0u;
             index < sizeof(valid_paths) / sizeof(valid_paths[0]);
             index += 1u) {
            const uint8_t *bytes;
            size_t length;
            source.logical_path = text(valid_paths[index]);
            CHECK(kofun_semantic_validate_logical_path(source.logical_path));
            stream = kofun_semantic_stream_create();
            CHECK(stream != NULL);
            sink = kofun_semantic_stream_sink(stream);
            CHECK(kofun_semantic_begin(&sink, &source));
            CHECK(kofun_semantic_end(
                &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
            ));
            CHECK(kofun_semantic_stream_bytes(stream, &bytes, &length));
            CHECK(kofun_semantic_validate_stream(bytes, length, NULL));
            kofun_semantic_stream_destroy(stream);
        }
        for (index = 0u;
             index < sizeof(invalid_paths) / sizeof(invalid_paths[0]);
             index += 1u) {
            const uint8_t *bytes = NULL;
            size_t length = 0u;
            source.logical_path = text(invalid_paths[index]);
            CHECK(!kofun_semantic_validate_logical_path(source.logical_path));
            stream = kofun_semantic_stream_create();
            CHECK(stream != NULL);
            sink = kofun_semantic_stream_sink(stream);
            CHECK(!kofun_semantic_begin(&sink, &source));
            CHECK(strcmp(
                kofun_semantic_stream_error(stream)->code,
                "ETS03"
            ) == 0);
            CHECK(!kofun_semantic_stream_bytes(stream, &bytes, &length));
            CHECK(bytes == NULL && length == 0u);
            kofun_semantic_stream_destroy(stream);
        }
    }
    {
        KofunSemanticBytes invalid;
        invalid.bytes = decomposed_path;
        invalid.length = sizeof(decomposed_path);
        CHECK(!kofun_semantic_validate_text(invalid));
        CHECK(!kofun_semantic_validate_logical_path(invalid));
        source.logical_path = invalid;
        stream = kofun_semantic_stream_create();
        CHECK(stream != NULL);
        sink = kofun_semantic_stream_sink(stream);
        CHECK(!kofun_semantic_begin(&sink, &source));
        CHECK(strcmp(
            kofun_semantic_stream_error(stream)->code,
            "ETS04"
        ) == 0);
        kofun_semantic_stream_destroy(stream);
    }
    free(path);
}

static void test_event_count_limits(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    KofunSemanticSpan span = {0u, 0u};
    uint32_t index;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    for (index = 0u; index < KOFUN_SEMANTIC_MAX_EVENTS - 2u; index += 1u) {
        char label[40];
        KofunSemanticId id;
        (void)snprintf(label, sizeof(label), "limit-node:%u", index);
        id_from_text(label, &id);
        CHECK(emit_node(
            &sink, id, KOFUN_SEMANTIC_NODE_LOCAL, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
    }
    CHECK(kofun_semantic_end(
        &sink, KOFUN_SOURCE_CHECKED, KOFUN_SEMANTIC_COMPLETE
    ));
    kofun_semantic_stream_destroy(stream);

    stream = kofun_semantic_stream_create();
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    for (index = 0u; index < KOFUN_SEMANTIC_MAX_EVENTS - 2u; index += 1u) {
        char label[40];
        KofunSemanticId id;
        (void)snprintf(label, sizeof(label), "over-node:%u", index);
        id_from_text(label, &id);
        CHECK(emit_node(
            &sink, id, KOFUN_SEMANTIC_NODE_LOCAL, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
    }
    {
        KofunSemanticId over;
        id_from_text("over-node:final", &over);
        CHECK(!emit_node(
            &sink, over, KOFUN_SEMANTIC_NODE_LOCAL, span,
            KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
        ));
        CHECK(strcmp(kofun_semantic_stream_error(stream)->code, "ETS04") == 0);
    }
    kofun_semantic_stream_destroy(stream);
}

static uint8_t *copy_stream(
    KofunSemanticStream *stream,
    size_t *length
) {
    const uint8_t *bytes;
    uint8_t *copy;
    CHECK(kofun_semantic_stream_bytes(stream, &bytes, length));
    copy = (uint8_t *)malloc(*length);
    CHECK(copy != NULL);
    memcpy(copy, bytes, *length);
    return copy;
}

static bool contains_bytes(
    const uint8_t *haystack,
    size_t haystack_length,
    const char *needle
) {
    size_t needle_length = strlen(needle);
    size_t index;
    if (needle_length > haystack_length) return false;
    for (index = 0u; index + needle_length <= haystack_length; index += 1u) {
        if (memcmp(haystack + index, needle, needle_length) == 0) return true;
    }
    return false;
}

static KofunSemanticStream *make_clean_stream(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(emit_clean_records(&sink, fixture));
    return stream;
}

static KofunSemanticStream *make_partial_stream(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(emit_partial_records(&sink, fixture));
    return stream;
}

static void test_complete_partial(
    const Fixture *fixture,
    const char *work
) {
    KofunSemanticStream *first = make_clean_stream(fixture);
    KofunSemanticStream *second = make_clean_stream(fixture);
    KofunSemanticStream *partial = make_partial_stream(fixture);
    uint8_t *first_bytes;
    uint8_t *second_bytes;
    uint8_t *partial_bytes;
    size_t first_length;
    size_t second_length;
    size_t partial_length;
    char destination[1024];
    first_bytes = copy_stream(first, &first_length);
    second_bytes = copy_stream(second, &second_length);
    partial_bytes = copy_stream(partial, &partial_length);
    CHECK(first_length == second_length);
    CHECK(memcmp(first_bytes, second_bytes, first_length) == 0);
    CHECK(kofun_semantic_validate_stream(
        first_bytes, first_length, NULL
    ));
    CHECK(kofun_semantic_validate_stream(
        partial_bytes, partial_length, NULL
    ));
    CHECK(!contains_bytes(
        partial_bytes, partial_length, "PrivateSecret"
    ));
    (void)snprintf(destination, sizeof(destination), "%s/complete.kse", work);
    CHECK(kofun_semantic_stream_commit(first, destination));
    (void)snprintf(destination, sizeof(destination), "%s/partial.kse", work);
    CHECK(kofun_semantic_stream_commit(partial, destination));
    free(first_bytes);
    free(second_bytes);
    free(partial_bytes);
    kofun_semantic_stream_destroy(first);
    kofun_semantic_stream_destroy(second);
    kofun_semantic_stream_destroy(partial);
}

static uint32_t test_load_u32be(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24u) |
        ((uint32_t)bytes[1] << 16u) |
        ((uint32_t)bytes[2] << 8u) |
        bytes[3];
}

static uint16_t test_load_u16be(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8u) | bytes[1]);
}

static void test_store_u32be(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24u);
    bytes[1] = (uint8_t)(value >> 16u);
    bytes[2] = (uint8_t)(value >> 8u);
    bytes[3] = (uint8_t)value;
}

static void resign(uint8_t *bytes, size_t length) {
    uint32_t payload = test_load_u32be(bytes + 12u);
    uint8_t digest[32];
    CHECK((uint64_t)payload + 48u == length);
    kofun_sha256(bytes, 16u + payload, digest);
    memcpy(bytes + 16u + payload, digest, sizeof(digest));
}

static uint8_t *fresh_copy(
    const uint8_t *bytes,
    size_t length
) {
    uint8_t *copy = (uint8_t *)malloc(length);
    CHECK(copy != NULL);
    memcpy(copy, bytes, length);
    return copy;
}

static size_t find_bytes(
    const uint8_t *bytes,
    size_t length,
    const char *wanted
) {
    size_t wanted_length = strlen(wanted);
    size_t index;
    for (index = 0u; index + wanted_length <= length; index += 1u) {
        if (memcmp(bytes + index, wanted, wanted_length) == 0) return index;
    }
    CHECK(false);
    return 0u;
}

static size_t field_payload_at(
    const uint8_t *bytes,
    size_t length,
    uint8_t wanted_kind,
    uint32_t wanted_occurrence,
    uint8_t wanted_tag,
    uint32_t *field_length
) {
    uint32_t event_count;
    uint32_t event_index;
    uint32_t occurrence = 0u;
    size_t cursor = 16u;
    size_t payload_end;
    CHECK(bytes != NULL);
    CHECK(length >= 48u);
    event_count = test_load_u32be(bytes + 8u);
    payload_end = 16u + test_load_u32be(bytes + 12u);
    CHECK(payload_end + 32u == length);
    for (event_index = 0u; event_index < event_count; event_index += 1u) {
        uint8_t kind;
        uint16_t field_count;
        uint16_t field_index;
        size_t frame_end;
        bool selected;
        CHECK(payload_end - cursor >= 8u);
        kind = bytes[cursor];
        field_count = test_load_u16be(bytes + cursor + 2u);
        frame_end = cursor + 8u + test_load_u32be(bytes + cursor + 4u);
        CHECK(frame_end <= payload_end);
        cursor += 8u;
        selected = kind == wanted_kind &&
            occurrence == wanted_occurrence;
        for (field_index = 0u;
             field_index < field_count;
             field_index += 1u) {
            uint8_t tag;
            uint32_t current_length;
            CHECK(frame_end - cursor >= 8u);
            tag = bytes[cursor];
            current_length = test_load_u32be(bytes + cursor + 4u);
            cursor += 8u;
            CHECK(current_length <= frame_end - cursor);
            if (selected && tag == wanted_tag) {
                if (field_length != NULL) *field_length = current_length;
                return cursor;
            }
            cursor += current_length;
        }
        CHECK(cursor == frame_end);
        if (kind == wanted_kind) occurrence += 1u;
    }
    CHECK(false);
    return 0u;
}

static void expect_invalid(
    uint8_t *bytes,
    size_t length,
    const char *code
) {
    KofunSemanticError error;
    CHECK(!kofun_semantic_validate_stream(bytes, length, &error));
    CHECK(strcmp(error.code, code) == 0);
    free(bytes);
}

static void test_corruption(const Fixture *fixture) {
    KofunSemanticStream *stream = make_clean_stream(fixture);
    KofunSemanticStream *partial_stream = make_partial_stream(fixture);
    uint8_t *canonical;
    uint8_t *partial;
    uint8_t *copy;
    size_t length;
    size_t partial_length;
    size_t path_at;
    size_t field_at;
    uint32_t field_length;
    size_t index;
    struct FixedU8Case {
        const uint8_t *bytes;
        size_t length;
        uint8_t event_kind;
        uint8_t field_tag;
    };
    struct FixedU8Case fixed_u8_cases[14];
    canonical = copy_stream(stream, &length);
    partial = copy_stream(partial_stream, &partial_length);
    CHECK(kofun_semantic_validate_stream(canonical, length, NULL));
    CHECK(kofun_semantic_validate_stream(partial, partial_length, NULL));

    {
        RejectingSink capture;
        KofunSemanticSink replay_sink;
        KofunSemanticError error;
        size_t namespace_at;
        size_t target_kind_at;
        uint32_t namespace_length;
        uint32_t target_kind_length;
        copy = fresh_copy(canonical, length);
        namespace_at = field_payload_at(
            copy, length, 4u, 0u, 3u, &namespace_length
        );
        target_kind_at = field_payload_at(
            copy, length, 4u, 0u, 7u, &target_kind_length
        );
        CHECK(namespace_length == 1u);
        CHECK(target_kind_length == 1u);
        CHECK(copy[namespace_at] == KOFUN_SEMANTIC_NAMESPACE_VALUE);
        CHECK(copy[target_kind_at] == KOFUN_SEMANTIC_ID_SYMBOL);
        copy[namespace_at] = KOFUN_SEMANTIC_NAMESPACE_TYPE;
        resign(copy, length);
        CHECK(!kofun_semantic_validate_stream(copy, length, &error));
        CHECK(strcmp(error.code, "ETS03") == 0);
        CHECK(error.event_kind == 4u);
        memset(&capture, 0, sizeof(capture));
        replay_sink = rejecting_sink(&capture);
        CHECK(!kofun_semantic_replay_stream(
            copy, length, &replay_sink, &error
        ));
        CHECK(strcmp(error.code, "ETS03") == 0);
        CHECK(error.event_kind == 4u);
        for (index = 0u;
             index < sizeof(capture.calls) / sizeof(capture.calls[0]);
             index += 1u) {
            CHECK(capture.calls[index] == 0u);
        }
        free(copy);
    }

    {
        RejectingSink capture;
        KofunSemanticSink replay_sink;
        KofunSemanticError error;
        size_t first_identity;
        size_t second_identity;
        size_t first_owner;
        size_t second_owner;
        uint32_t first_length;
        uint32_t second_length;
        uint32_t first_owner_length;
        uint32_t second_owner_length;
        copy = fresh_copy(canonical, length);
        first_owner = field_payload_at(
            canonical, length, 3u, 2u, 1u, &first_owner_length
        );
        second_owner = field_payload_at(
            canonical, length, 3u, 5u, 1u, &second_owner_length
        );
        first_identity = field_payload_at(
            canonical, length, 3u, 2u, 3u, &first_length
        );
        second_identity = field_payload_at(
            copy, length, 3u, 5u, 3u, &second_length
        );
        CHECK(first_owner_length == KOFUN_SEMANTIC_ID_BYTES);
        CHECK(second_owner_length == KOFUN_SEMANTIC_ID_BYTES);
        CHECK(memcmp(
            canonical + first_owner,
            canonical + second_owner,
            KOFUN_SEMANTIC_ID_BYTES
        ) != 0);
        CHECK(first_length == KOFUN_SEMANTIC_ID_BYTES);
        CHECK(second_length == KOFUN_SEMANTIC_ID_BYTES);
        memcpy(
            copy + second_identity,
            canonical + first_identity,
            KOFUN_SEMANTIC_ID_BYTES
        );
        resign(copy, length);
        CHECK(!kofun_semantic_validate_stream(copy, length, &error));
        CHECK(strcmp(error.code, "ETS03") == 0);
        CHECK(error.event_kind == 3u);
        memset(&capture, 0, sizeof(capture));
        replay_sink = rejecting_sink(&capture);
        CHECK(!kofun_semantic_replay_stream(
            copy, length, &replay_sink, &error
        ));
        CHECK(strcmp(error.code, "ETS03") == 0);
        CHECK(error.event_kind == 3u);
        for (index = 0u;
             index < sizeof(capture.calls) / sizeof(capture.calls[0]);
             index += 1u) {
            CHECK(capture.calls[index] == 0u);
        }
        free(copy);
    }

    copy = fresh_copy(canonical, length);
    copy[20] ^= 1u;
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    copy[17] = 1u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    copy[16] = 99u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    copy[24] = 99u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    copy[25] = 99u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    copy[26] = 1u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    test_store_u32be(copy + 28u, 31u);
    resign(copy, length);
    expect_invalid(copy, length, "ETS04");

    copy = fresh_copy(canonical, length);
    test_store_u32be(
        copy + 8u,
        test_load_u32be(copy + 8u) + 1u
    );
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    path_at = find_bytes(canonical, length, "src/main.kofun");
    copy = fresh_copy(canonical, length);
    copy[path_at] = UINT8_C(0xff);
    resign(copy, length);
    expect_invalid(copy, length, "ETS04");

    copy = fresh_copy(canonical, length);
    expect_invalid(copy, length - 1u, "ETS04");

    fixed_u8_cases[0] = (struct FixedU8Case){
        canonical, length, 1u, 10u
    };
    fixed_u8_cases[1] = (struct FixedU8Case){
        canonical, length, 2u, 2u
    };
    fixed_u8_cases[2] = (struct FixedU8Case){
        canonical, length, 2u, 4u
    };
    fixed_u8_cases[3] = (struct FixedU8Case){
        canonical, length, 3u, 2u
    };
    fixed_u8_cases[4] = (struct FixedU8Case){
        canonical, length, 3u, 4u
    };
    fixed_u8_cases[5] = (struct FixedU8Case){
        canonical, length, 4u, 3u
    };
    fixed_u8_cases[6] = (struct FixedU8Case){
        canonical, length, 4u, 5u
    };
    fixed_u8_cases[7] = (struct FixedU8Case){
        canonical, length, 4u, 6u
    };
    fixed_u8_cases[8] = (struct FixedU8Case){
        canonical, length, 4u, 7u
    };
    fixed_u8_cases[9] = (struct FixedU8Case){
        canonical, length, 5u, 2u
    };
    fixed_u8_cases[10] = (struct FixedU8Case){
        canonical, length, 5u, 3u
    };
    fixed_u8_cases[11] = (struct FixedU8Case){
        partial, partial_length, 6u, 4u
    };
    fixed_u8_cases[12] = (struct FixedU8Case){
        partial, partial_length, 6u, 11u
    };
    fixed_u8_cases[13] = (struct FixedU8Case){
        canonical, length, 7u, 1u
    };
    for (index = 0u;
         index < sizeof(fixed_u8_cases) / sizeof(fixed_u8_cases[0]);
         index += 1u) {
        const struct FixedU8Case *test = &fixed_u8_cases[index];
        copy = fresh_copy(test->bytes, test->length);
        field_at = field_payload_at(
            copy,
            test->length,
            test->event_kind,
            0u,
            test->field_tag,
            &field_length
        );
        CHECK(field_length == 1u);
        copy[field_at] = UINT8_C(255);
        resign(copy, test->length);
        expect_invalid(copy, test->length, "ETS03");
    }
    copy = fresh_copy(canonical, length);
    field_at = field_payload_at(copy, length, 7u, 0u, 2u, &field_length);
    CHECK(field_length == 1u);
    copy[field_at] = UINT8_C(255);
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    field_at = field_payload_at(copy, length, 1u, 0u, 10u, &field_length);
    CHECK(field_length == 1u);
    copy[field_at] = 1u;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 1u, 0u, 10u, &field_length
    );
    CHECK(field_length == 1u);
    copy[field_at] = 0u;
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS03");

    copy = fresh_copy(canonical, length);
    field_at = field_payload_at(copy, length, 4u, 0u, 8u, &field_length);
    CHECK(field_length == KOFUN_SEMANTIC_ID_BYTES);
    copy[field_at] ^= UINT8_C(1);
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    field_at = field_payload_at(copy, length, 4u, 0u, 7u, &field_length);
    CHECK(field_length == 1u);
    copy[field_at] = (uint8_t)KOFUN_SEMANTIC_ID_TYPE;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(canonical, length);
    field_at = field_payload_at(copy, length, 3u, 2u, 4u, &field_length);
    CHECK(field_length == 1u);
    copy[field_at] = (uint8_t)KOFUN_SEMANTIC_UNAVAILABLE;
    resign(copy, length);
    expect_invalid(copy, length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 4u, 0u, 5u, &field_length
    );
    CHECK(field_length == 1u);
    copy[field_at] = (uint8_t)KOFUN_SEMANTIC_VALIDATED;
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 6u, 0u, 12u, &field_length
    );
    CHECK(field_length >= 2u);
    copy[field_at] = 0u;
    copy[field_at + 1u] = 2u;
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 6u, 0u, 12u, &field_length
    );
    CHECK(field_length > 44u);
    CHECK(test_load_u16be(copy + field_at) == 1u);
    copy[field_at + 44u] = UINT8_C(0xff);
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS04");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 6u, 0u, 13u, &field_length
    );
    CHECK(field_length >= 2u);
    copy[field_at] = 0u;
    copy[field_at + 1u] = 2u;
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 6u, 0u, 13u, &field_length
    );
    CHECK(field_length > 48u);
    CHECK(test_load_u16be(copy + field_at) == 1u);
    test_store_u32be(copy + field_at + 2u, 8u);
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS03");

    copy = fresh_copy(partial, partial_length);
    field_at = field_payload_at(
        copy, partial_length, 6u, 0u, 13u, &field_length
    );
    CHECK(field_length > 48u);
    copy[field_at + 48u] = UINT8_C(0xff);
    resign(copy, partial_length);
    expect_invalid(copy, partial_length, "ETS04");

    free(canonical);
    free(partial);
    kofun_semantic_stream_destroy(stream);
    kofun_semantic_stream_destroy(partial_stream);
}

static void test_hidden_disclosure(const Fixture *fixture) {
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    KofunSemanticSpan span = token_span(fixture, "later", 1u);
    KofunSemanticId node = node_id(
        fixture, KOFUN_SEMANTIC_NODE_CALL, span, 0u
    );
    KofunSemanticReference reference;
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(emit_node(
        &sink, node, KOFUN_SEMANTIC_NODE_CALL, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    memset(&reference, 0, sizeof(reference));
    id_from_text("hidden-reference", &reference.reference_id);
    reference.source_node_id = node;
    reference.name_space = KOFUN_SEMANTIC_NAMESPACE_VALUE;
    reference.span = span;
    reference.status = KOFUN_SEMANTIC_UNAVAILABLE;
    reference.target_shape = KOFUN_SEMANTIC_TARGET_HIDDEN;
    reference.target_kind = KOFUN_SEMANTIC_ID_SYMBOL;
    id_from_text("PrivateSecret", &reference.target_value);
    reference.hidden_reason = text("inaccessible");
    CHECK(!kofun_semantic_reference(&sink, &reference));
    {
        const uint8_t *bytes;
        size_t length;
        CHECK(!kofun_semantic_stream_bytes(stream, &bytes, &length));
    }
    kofun_semantic_stream_destroy(stream);
}

static void test_nfc_rejection(const Fixture *fixture) {
    static const uint8_t decomposed[] = {'e', 0xcc, 0x81};
    KofunSemanticStream *stream = kofun_semantic_stream_create();
    KofunSemanticSink sink;
    KofunSemanticSpan span = {0u, 0u};
    KofunSemanticId node;
    KofunSemanticFact fact;
    id_from_text("nfc-node", &node);
    CHECK(stream != NULL);
    sink = kofun_semantic_stream_sink(stream);
    CHECK(kofun_semantic_begin(&sink, &fixture->semantic_source));
    CHECK(emit_node(
        &sink, node, KOFUN_SEMANTIC_NODE_LOCAL, span,
        KOFUN_SEMANTIC_VALIDATED, NULL, 0u, NULL, 0u
    ));
    memset(&fact, 0, sizeof(fact));
    fact.owner_node_id = node;
    fact.kind = KOFUN_SEMANTIC_FACT_TYPE;
    fact.status = KOFUN_SEMANTIC_VALIDATED;
    fact.display.bytes = decomposed;
    fact.display.length = sizeof(decomposed);
    fact.reason = text("");
    CHECK(!kofun_semantic_fact(&sink, &fact));
    CHECK(strcmp(
        kofun_semantic_stream_error(stream)->code,
        "ETS04"
    ) == 0);
    kofun_semantic_stream_destroy(stream);
}

static void test_independent_sink(const Fixture *fixture) {
    RejectingSink capture;
    KofunSemanticSink sink;
    memset(&capture, 0, sizeof(capture));
    sink = rejecting_sink(&capture);
    CHECK(emit_clean_records(&sink, fixture));
    CHECK(capture.calls[0] == 1u);
    CHECK(capture.calls[1] == 12u);
    CHECK(capture.calls[2] == 7u);
    CHECK(capture.calls[3] == 7u);
    CHECK(capture.calls[4] == 2u);
    CHECK(capture.calls[5] == 0u);
    CHECK(capture.calls[6] == 1u);
}

static void test_atomic_failure_preserves(
    const Fixture *fixture,
    const char *work
) {
    KofunSemanticStream *stream = make_clean_stream(fixture);
    KofunSemanticStream *collision_stream = make_clean_stream(fixture);
    KofunSemanticStream *replacement_stream = make_clean_stream(fixture);
    char directory[1024];
    char sentinel[1024];
    char temporary[1100];
    static const char sentinel_bytes[] = "prior-sentinel";
    struct stat status;
    FILE *file;
    char observed[sizeof(sentinel_bytes)];
    uint8_t *committed;
    size_t committed_length;
    unsigned attempt;
    (void)snprintf(directory, sizeof(directory), "%s/not-a-file", work);
    if (mkdir(directory, 0700) != 0) CHECK(errno == EEXIST);
    CHECK(!kofun_semantic_stream_commit(stream, directory));
    CHECK(stat(directory, &status) == 0);
    CHECK(S_ISDIR(status.st_mode));

    (void)snprintf(sentinel, sizeof(sentinel), "%s/sentinel.kse", work);
    file = fopen(sentinel, "wb");
    CHECK(file != NULL);
    CHECK(fwrite(
        sentinel_bytes, 1u, sizeof(sentinel_bytes), file
    ) == sizeof(sentinel_bytes));
    CHECK(fclose(file) == 0);
    for (attempt = 0u; attempt < 100u; attempt += 1u) {
        (void)snprintf(
            temporary,
            sizeof(temporary),
            "%s.kofun-kse-tmp.%ld.%u",
            sentinel,
            (long)getpid(),
            attempt
        );
        file = fopen(temporary, "wbx");
        CHECK(file != NULL);
        CHECK(fclose(file) == 0);
    }
    CHECK(!kofun_semantic_stream_commit(collision_stream, sentinel));
    file = fopen(sentinel, "rb");
    CHECK(file != NULL);
    CHECK(fread(observed, 1u, sizeof(observed), file) == sizeof(observed));
    CHECK(fclose(file) == 0);
    CHECK(memcmp(observed, sentinel_bytes, sizeof(observed)) == 0);
    for (attempt = 0u; attempt < 100u; attempt += 1u) {
        (void)snprintf(
            temporary,
            sizeof(temporary),
            "%s.kofun-kse-tmp.%ld.%u",
            sentinel,
            (long)getpid(),
            attempt
        );
        CHECK(lstat(temporary, &status) == 0);
        CHECK(S_ISREG(status.st_mode));
        CHECK(unlink(temporary) == 0);
    }
    (void)snprintf(
        temporary,
        sizeof(temporary),
        "%s.kofun-kse-tmp.%ld.%u",
        sentinel,
        (long)getpid(),
        100u
    );
    CHECK(lstat(temporary, &status) != 0);
    CHECK(errno == ENOENT);

    CHECK(kofun_semantic_stream_commit(replacement_stream, sentinel));
    committed = read_file(sentinel, &committed_length);
    CHECK(kofun_semantic_validate_stream(
        committed, committed_length, NULL
    ));
    free(committed);
    for (attempt = 0u; attempt < 100u; attempt += 1u) {
        (void)snprintf(
            temporary,
            sizeof(temporary),
            "%s.kofun-kse-tmp.%ld.%u",
            sentinel,
            (long)getpid(),
            attempt
        );
        CHECK(lstat(temporary, &status) != 0);
        CHECK(errno == ENOENT);
    }
    CHECK(unlink(sentinel) == 0);
    kofun_semantic_stream_destroy(replacement_stream);
    kofun_semantic_stream_destroy(collision_stream);
    kofun_semantic_stream_destroy(stream);
}

int main(int argc, char **argv) {
    Fixture fixture;
    CHECK(argc == 4);
    if (mkdir(argv[2], 0700) != 0) CHECK(errno == EEXIST);
    fixture_init(&fixture, argv[3]);
    test_node_identity_frame(&fixture);
    if (strcmp(argv[1], "events") == 0) {
        test_complete_partial(&fixture, argv[2]);
        test_sink_rejection(&fixture);
        test_strict_invariant_rejection(&fixture);
        test_early_and_cancellation(&fixture);
        test_hidden_disclosure(&fixture);
        test_nfc_rejection(&fixture);
        test_independent_sink(&fixture);
        test_relation_limits(&fixture);
        test_nested_diagnostic_list_limits(&fixture, argv[2]);
        test_text_limits(&fixture);
        test_event_count_limits(&fixture);
        puts("PASS: Stage 2 semantic complete/partial/cancelled event transactions");
    } else if (strcmp(argv[1], "stream") == 0) {
        test_corruption(&fixture);
        test_atomic_failure_preserves(&fixture, argv[2]);
        puts("PASS: Stage 2 KSE v1 framing, corruption, limits, and atomic commit");
    } else {
        CHECK(false);
    }
    fixture_destroy(&fixture);
    return 0;
}
