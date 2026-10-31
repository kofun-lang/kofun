#ifndef KOFUN_STAGE2_SEMANTIC_EVENTS_H
#define KOFUN_STAGE2_SEMANTIC_EVENTS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KOFUN_SEMANTIC_ID_BYTES 32u
#define KOFUN_SEMANTIC_ERROR_DETAIL_BYTES 160u
#define KOFUN_SEMANTIC_MAX_EVENTS 4096u
#define KOFUN_SEMANTIC_MAX_EVENT_BYTES (4u * 1024u * 1024u)
#define KOFUN_SEMANTIC_MAX_TEXT_BYTES 4096u
#define KOFUN_SEMANTIC_MAX_RELATIONS 64u

#define KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE \
    "unresolved-current-stage2-reference"
#define KOFUN_SEMANTIC_REASON_TYPE_UNAVAILABLE \
    "type-not-available-in-current-subset"
#define KOFUN_SEMANTIC_REASON_MOVE_AFTER_BORROW "move-after-borrow"
#define KOFUN_SEMANTIC_REASON_VISIBILITY_RESTRICTED "visibility-restricted"
#define KOFUN_SEMANTIC_REASON_UNSUPPORTED_STAGE2_FEATURE \
    "unsupported-current-stage2-feature"
#define KOFUN_SEMANTIC_REASON_CANCELLED_BEFORE_ANALYSIS \
    "cancelled-before-analysis"
#define KOFUN_SEMANTIC_REASON_EFFECT_IO_CALLEE "effect-io-callee"
#define KOFUN_SEMANTIC_REASON_EFFECT_IO_ROOT_PRINT "effect-io-root-print"

typedef struct {
    const uint8_t *bytes;
    uint32_t length;
} KofunSemanticBytes;

typedef struct {
    uint8_t bytes[KOFUN_SEMANTIC_ID_BYTES];
} KofunSemanticId;

typedef struct {
    uint32_t start;
    uint32_t end;
} KofunSemanticSpan;

typedef enum {
    KOFUN_SEMANTIC_VALIDATED = 1,
    KOFUN_SEMANTIC_PROVISIONAL = 2,
    KOFUN_SEMANTIC_ERROR = 3,
    KOFUN_SEMANTIC_UNAVAILABLE = 4
} KofunSemanticStatus;

typedef enum {
    KOFUN_SOURCE_CHECKED = 1,
    KOFUN_SOURCE_FAILED = 2,
    KOFUN_SOURCE_CANCELLED = 3
} KofunSourceStatus;

typedef enum {
    KOFUN_SEMANTIC_COMPLETE = 1,
    KOFUN_SEMANTIC_PARTIAL = 2
} KofunCompleteness;

typedef enum {
    KOFUN_SEMANTIC_NODE_MODULE = 1,
    KOFUN_SEMANTIC_NODE_FUNCTION = 2,
    KOFUN_SEMANTIC_NODE_PARAMETER = 3,
    KOFUN_SEMANTIC_NODE_SCOPE = 4,
    KOFUN_SEMANTIC_NODE_LOCAL = 5,
    KOFUN_SEMANTIC_NODE_ADT = 6,
    KOFUN_SEMANTIC_NODE_CONSTRUCTOR = 7,
    KOFUN_SEMANTIC_NODE_CALL = 8,
    KOFUN_SEMANTIC_NODE_REFERENCE = 9,
    KOFUN_SEMANTIC_NODE_IF = 10,
    KOFUN_SEMANTIC_NODE_MATCH = 11,
    KOFUN_SEMANTIC_NODE_ERROR_PATTERN = 12
} KofunSemanticNodeKind;

typedef enum {
    KOFUN_SEMANTIC_ID_PACKAGE = 1,
    KOFUN_SEMANTIC_ID_MODULE = 2,
    KOFUN_SEMANTIC_ID_FILE = 3,
    KOFUN_SEMANTIC_ID_SCOPE = 4,
    KOFUN_SEMANTIC_ID_BINDING = 5,
    KOFUN_SEMANTIC_ID_NAMESPACE = 6,
    KOFUN_SEMANTIC_ID_SYMBOL = 7,
    KOFUN_SEMANTIC_ID_TYPE = 8,
    KOFUN_SEMANTIC_ID_CONSTRUCTOR = 9
} KofunSemanticIdentityKind;

typedef enum {
    KOFUN_SEMANTIC_FACT_TYPE = 1,
    KOFUN_SEMANTIC_FACT_EFFECT = 2,
    KOFUN_SEMANTIC_FACT_OWNERSHIP = 3,
    KOFUN_SEMANTIC_FACT_ORIGIN = 4
} KofunSemanticFactKind;

typedef enum {
    KOFUN_SEMANTIC_NAMESPACE_VALUE = 1,
    KOFUN_SEMANTIC_NAMESPACE_TYPE = 2,
    KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR = 3
} KofunSemanticNamespace;

typedef enum {
    KOFUN_SEMANTIC_TARGET_VISIBLE = 1,
    KOFUN_SEMANTIC_TARGET_HIDDEN = 2,
    KOFUN_SEMANTIC_TARGET_UNAVAILABLE = 3
} KofunSemanticTargetShape;

typedef enum {
    KOFUN_SEMANTIC_DIAGNOSTIC_ERROR = 1,
    KOFUN_SEMANTIC_DIAGNOSTIC_WARNING = 2,
    KOFUN_SEMANTIC_DIAGNOSTIC_NOTE = 3
} KofunSemanticSeverity;

typedef struct {
    KofunSemanticId package_id;
    KofunSemanticId module_id;
    KofunSemanticId file_id;
    KofunSemanticBytes logical_path;
    uint64_t source_bytes;
    uint8_t source_sha256[KOFUN_SEMANTIC_ID_BYTES];
    KofunSemanticBytes edition;
    KofunSemanticBytes semantic_compatibility;
    uint64_t caller_generation;
    uint8_t compiler_exit_class;
} KofunSemanticSource;

typedef struct {
    KofunSemanticId node_id;
    KofunSemanticNodeKind kind;
    KofunSemanticSpan span;
    KofunSemanticStatus status;
    const KofunSemanticId *dependencies;
    uint16_t dependency_count;
    const KofunSemanticId *diagnostic_ids;
    uint16_t diagnostic_count;
} KofunSemanticNode;

typedef struct {
    KofunSemanticId owner_node_id;
    KofunSemanticIdentityKind kind;
    KofunSemanticId value;
    KofunSemanticStatus status;
} KofunSemanticIdentity;

typedef struct {
    KofunSemanticId owner_node_id;
    KofunSemanticFactKind kind;
    KofunSemanticStatus status;
    KofunSemanticBytes display;
    KofunSemanticBytes reason;
    const KofunSemanticId *dependencies;
    uint16_t dependency_count;
    const KofunSemanticId *diagnostic_ids;
    uint16_t diagnostic_count;
} KofunSemanticFact;

typedef struct {
    KofunSemanticId reference_id;
    KofunSemanticId source_node_id;
    KofunSemanticNamespace name_space;
    KofunSemanticSpan span;
    KofunSemanticStatus status;
    KofunSemanticTargetShape target_shape;
    KofunSemanticIdentityKind target_kind;
    KofunSemanticId target_value;
    KofunSemanticBytes hidden_reason;
    const KofunSemanticId *diagnostic_ids;
    uint16_t diagnostic_count;
} KofunSemanticReference;

typedef struct {
    KofunSemanticId file_id;
    KofunSemanticSpan span;
    KofunSemanticBytes label;
} KofunSemanticRelated;

typedef struct {
    uint32_t remedy_id;
    KofunSemanticId file_id;
    KofunSemanticSpan span;
    KofunSemanticBytes replacement;
} KofunSemanticEdit;

typedef struct {
    KofunSemanticId diagnostic_id;
    KofunSemanticBytes code;
    KofunSemanticBytes category;
    KofunSemanticSeverity severity;
    KofunSemanticBytes template_id;
    KofunSemanticId primary_file_id;
    KofunSemanticSpan primary_span;
    KofunSemanticBytes fallback_text;
    const KofunSemanticId *affected_ids;
    uint16_t affected_count;
    const uint32_t *remedy_ids;
    uint16_t remedy_count;
    bool truncated;
    const KofunSemanticRelated *related;
    uint16_t related_count;
    const KofunSemanticEdit *edits;
    uint16_t edit_count;
} KofunSemanticDiagnostic;

typedef struct {
    void *context;
    bool (*begin)(void *, const KofunSemanticSource *);
    bool (*node)(void *, const KofunSemanticNode *);
    bool (*identity)(void *, const KofunSemanticIdentity *);
    bool (*fact)(void *, const KofunSemanticFact *);
    bool (*reference)(void *, const KofunSemanticReference *);
    bool (*diagnostic)(void *, const KofunSemanticDiagnostic *);
    void (*cancellation_observed)(void *);
    bool (*end)(void *, KofunSourceStatus, KofunCompleteness);
} KofunSemanticSink;

typedef struct {
    char code[6];
    uint32_t record_index;
    uint8_t event_kind;
    char detail[KOFUN_SEMANTIC_ERROR_DETAIL_BYTES];
} KofunSemanticError;

typedef struct KofunSemanticStream KofunSemanticStream;

bool kofun_semantic_begin(
    KofunSemanticSink *sink,
    const KofunSemanticSource *source
);
bool kofun_semantic_node(
    KofunSemanticSink *sink,
    const KofunSemanticNode *node
);
bool kofun_semantic_identity(
    KofunSemanticSink *sink,
    const KofunSemanticIdentity *identity
);
bool kofun_semantic_fact(
    KofunSemanticSink *sink,
    const KofunSemanticFact *fact
);
bool kofun_semantic_reference(
    KofunSemanticSink *sink,
    const KofunSemanticReference *reference
);
bool kofun_semantic_diagnostic(
    KofunSemanticSink *sink,
    const KofunSemanticDiagnostic *diagnostic
);
void kofun_semantic_cancellation_observed(KofunSemanticSink *sink);
bool kofun_semantic_end(
    KofunSemanticSink *sink,
    KofunSourceStatus source_status,
    KofunCompleteness completeness
);

KofunSemanticStream *kofun_semantic_stream_create(void);
void kofun_semantic_stream_destroy(KofunSemanticStream *stream);
KofunSemanticSink kofun_semantic_stream_sink(KofunSemanticStream *stream);
void kofun_semantic_stream_observe_cancellation(KofunSemanticStream *stream);
const KofunSemanticError *kofun_semantic_stream_error(
    const KofunSemanticStream *stream
);
bool kofun_semantic_stream_bytes(
    const KofunSemanticStream *stream,
    const uint8_t **bytes,
    size_t *length
);
bool kofun_semantic_stream_commit(
    KofunSemanticStream *stream,
    const char *destination
);

bool kofun_semantic_validate_stream(
    const uint8_t *bytes,
    size_t length,
    KofunSemanticError *error
);
bool kofun_semantic_validate_text(KofunSemanticBytes text);
bool kofun_semantic_validate_logical_path(KofunSemanticBytes path);
bool kofun_semantic_replay_stream(
    const uint8_t *bytes,
    size_t length,
    KofunSemanticSink *sink,
    KofunSemanticError *error
);

void kofun_semantic_derive_id(
    const char *domain,
    const KofunSemanticId *file_id,
    KofunSemanticNodeKind kind,
    KofunSemanticSpan span,
    uint32_t occurrence,
    KofunSemanticId *result
);

#endif
