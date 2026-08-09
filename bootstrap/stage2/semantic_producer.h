#ifndef KOFUN_STAGE2_SEMANTIC_PRODUCER_H
#define KOFUN_STAGE2_SEMANTIC_PRODUCER_H

#include "semantic_events.h"

typedef enum {
    KOFUN_STAGE2_SEMANTIC_COMPILE = 0,
    KOFUN_STAGE2_SEMANTIC_OWNERSHIP = 1
} KofunStage2SemanticAuthority;

typedef struct {
    const uint8_t *source;
    size_t source_length;
    KofunSemanticBytes logical_path;
    uint64_t caller_generation;
    KofunStage2SemanticAuthority authority;
} KofunStage2SemanticInput;

typedef struct {
    KofunSourceStatus source_status;
    KofunCompleteness completeness;
    bool token_span_committed;
    bool tooling_emission_failed;
    uint8_t compiler_exit_class;
    bool has_source_diagnostic;
    bool diagnostic_has_byte_span;
    bool diagnostic_truncated;
    char diagnostic_code[16];
    char diagnostic_category[32];
    char diagnostic_template_id[64];
    KofunSemanticSpan diagnostic_span;
    char diagnostic_fallback[KOFUN_SEMANTIC_ERROR_DETAIL_BYTES];
    KofunSemanticError tooling_error;
} KofunStage2SemanticResult;

enum {
    KOFUN_STAGE2_INTERFACE_MAX_FACTS = 256,
    KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES = 1024,
    KOFUN_STAGE2_INTERFACE_NAME_BYTES = 257
};

typedef enum {
    KOFUN_STAGE2_INTERFACE_FUNCTION = 1,
    KOFUN_STAGE2_INTERFACE_ADT = 2,
    KOFUN_STAGE2_INTERFACE_CONSTRUCTOR = 3,
    KOFUN_STAGE2_INTERFACE_RECORD = 4
} KofunStage2InterfaceFactKind;

typedef enum {
    KOFUN_STAGE2_INTERFACE_PRIVATE = 1,
    KOFUN_STAGE2_INTERFACE_INTERNAL = 2,
    KOFUN_STAGE2_INTERFACE_PUBLIC = 3
} KofunStage2InterfaceVisibility;

typedef struct {
    KofunStage2InterfaceFactKind kind;
    KofunStage2InterfaceVisibility visibility;
    KofunSemanticId namespace_id;
    KofunSemanticId symbol_id;
    KofunSemanticId owner_symbol_id;
    char name[KOFUN_STAGE2_INTERFACE_NAME_BYTES];
    uint16_t parameter_count;
    uint16_t parameter_type_start;
    uint16_t parameter_label_start;
    KofunSemanticId result_type_symbol_id;
    uint8_t constructor_payload_count;
    KofunSemanticId constructor_payload_type_symbol_id;
    uint32_t constructor_ordinal;
} KofunStage2InterfaceFact;

typedef struct {
    bool committed;
    KofunSemanticId package_id;
    KofunSemanticId module_id;
    char edition[65];
    KofunStage2InterfaceFact facts[KOFUN_STAGE2_INTERFACE_MAX_FACTS];
    size_t fact_count;
    KofunSemanticId type_reference_symbol_ids[
        KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES];
    char parameter_labels[KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES]
        [KOFUN_STAGE2_INTERFACE_NAME_BYTES];
    uint16_t parameter_label_lengths[
        KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES];
    size_t type_reference_count;
} KofunStage2InterfaceSnapshot;

/*
 * Copied, bounded records for the in-process discovery provider (#1080).
 *
 * This is deliberately not the compiler's internal Producer layout.  Every
 * pointer-bearing semantic record is flattened into storage owned by this
 * snapshot before the compiler authority is destroyed, so a discovery client
 * cannot retain an arena pointer or infer a missing fact from rendered output.
 */
enum {
    KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS = 512,
    KOFUN_STAGE2_DISCOVERY_MAX_CANDIDATES = 192,
    KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES = 160,
    KOFUN_STAGE2_DISCOVERY_MODULE_NAME_BYTES = 64,
    KOFUN_STAGE2_DISCOVERY_QUALIFIED_NAME_BYTES = 322
};

typedef struct {
    KofunSemanticNode node;
    bool has_type_identity;
    KofunSemanticIdentity type_identity;
    bool has_type_fact;
    KofunSemanticStatus type_status;
    char type_display[KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES];
    char type_reason[KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES];
} KofunStage2DiscoveryExpression;

typedef enum {
    KOFUN_STAGE2_DISCOVERY_FUNCTION = 1,
    KOFUN_STAGE2_DISCOVERY_CONSTRUCTOR = 2
} KofunStage2DiscoveryCandidateKind;

typedef struct {
    KofunStage2DiscoveryCandidateKind kind;
    KofunSemanticId symbol_id;
    KofunSemanticId module_id;
    KofunSemanticStatus status;
    KofunStage2InterfaceVisibility visibility;
    char display_name[KOFUN_STAGE2_INTERFACE_NAME_BYTES];
    char qualified_name[KOFUN_STAGE2_DISCOVERY_QUALIFIED_NAME_BYTES];
    char module_name[KOFUN_STAGE2_DISCOVERY_MODULE_NAME_BYTES];
    char signature[KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES];
    /* The validated effect requirement the compiler committed for this
     * candidate — currently the direct `io` root fact.  Empty when the
     * candidate is pure or when no requirement was safely disclosable. */
    char effect[KOFUN_STAGE2_DISCOVERY_FACT_TEXT_BYTES];
} KofunStage2DiscoveryCandidate;

typedef struct {
    bool committed;
    KofunSourceStatus source_status;
    KofunCompleteness completeness;
    KofunSemanticId package_id;
    KofunSemanticId module_id;
    KofunSemanticId file_id;
    uint64_t source_bytes;
    uint8_t source_sha256[KOFUN_SEMANTIC_ID_BYTES];
    uint64_t caller_generation;
    char semantic_compatibility[65];
    KofunStage2DiscoveryExpression
        expressions[KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS];
    size_t expression_count;
    KofunStage2DiscoveryCandidate
        candidates[KOFUN_STAGE2_DISCOVERY_MAX_CANDIDATES];
    size_t candidate_count;
    bool hidden_candidate_present;
} KofunStage2DiscoverySnapshot;

bool kofun_stage2_produce_semantic_events(
    const KofunStage2SemanticInput *input,
    KofunSemanticSink *sink,
    bool cancellation_observed_after_commit,
    KofunStage2SemanticResult *result
);

bool kofun_stage2_compile_interface(
    const KofunStage2SemanticInput *input,
    KofunSemanticBytes edition,
    bool cancellation_observed_after_commit,
    KofunStage2InterfaceSnapshot *snapshot,
    KofunStage2SemanticResult *result
);

bool kofun_stage2_analyze_discovery(
    const KofunStage2SemanticInput *input,
    KofunStage2DiscoverySnapshot *snapshot,
    KofunStage2SemanticResult *result
);

#endif
