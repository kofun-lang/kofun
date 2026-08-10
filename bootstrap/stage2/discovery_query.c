#include "discovery_query.h"

#include "sha256.h"

#include <stdlib.h>
#include <string.h>

static bool query_bytes(
    const char *text,
    size_t capacity,
    KofunSemanticBytes *out
) {
    const char *terminator;
    if (text == NULL || out == NULL) return false;
    terminator = memchr(text, '\0', capacity);
    if (terminator == NULL) return false;
    out->bytes = (const uint8_t *)text;
    out->length = (uint32_t)(terminator - text);
    return true;
}

static bool query_snapshot_strings_are_bounded(
    const KofunStage2DiscoverySnapshot *snapshot
) {
    KofunSemanticBytes ignored;
    size_t index;
    if (!query_bytes(
            snapshot->semantic_compatibility,
            sizeof(snapshot->semantic_compatibility),
            &ignored)) {
        return false;
    }
    for (index = 0u; index < snapshot->expression_count; index += 1u) {
        const KofunStage2DiscoveryExpression *expression =
            &snapshot->expressions[index];
        if (!query_bytes(
                expression->type_display,
                sizeof(expression->type_display),
                &ignored) ||
            !query_bytes(
                expression->type_reason,
                sizeof(expression->type_reason),
                &ignored)) {
            return false;
        }
    }
    for (index = 0u; index < snapshot->candidate_count; index += 1u) {
        const KofunStage2DiscoveryCandidate *candidate =
            &snapshot->candidates[index];
        if (!query_bytes(
                candidate->display_name,
                sizeof(candidate->display_name),
                &ignored) ||
            !query_bytes(
                candidate->qualified_name,
                sizeof(candidate->qualified_name),
                &ignored) ||
            !query_bytes(
                candidate->module_name,
                sizeof(candidate->module_name),
                &ignored) ||
            !query_bytes(
                candidate->signature,
                sizeof(candidate->signature),
                &ignored) ||
            !query_bytes(
                candidate->effect,
                sizeof(candidate->effect),
                &ignored)) {
            return false;
        }
    }
    return true;
}

static KofunDiscoveryVisibility query_visibility(
    KofunStage2InterfaceVisibility visibility
) {
    switch (visibility) {
    case KOFUN_STAGE2_INTERFACE_PRIVATE:
        return KOFUN_DISCOVERY_VISIBILITY_PRIVATE;
    case KOFUN_STAGE2_INTERFACE_INTERNAL:
        return KOFUN_DISCOVERY_VISIBILITY_INTERNAL;
    case KOFUN_STAGE2_INTERFACE_PUBLIC:
        return KOFUN_DISCOVERY_VISIBILITY_PUB;
    default:
        return KOFUN_DISCOVERY_VISIBILITY_PRIVATE;
    }
}

/*
 * Every enum in this caller-owned snapshot must be one this build defines.
 * An unrecognized one is a record the provider cannot read, not a record
 * that says something.
 */
static bool query_readable_candidate(
    const KofunStage2DiscoveryCandidate *candidate
) {
    bool valid_kind = candidate->kind == KOFUN_STAGE2_DISCOVERY_FUNCTION ||
        candidate->kind == KOFUN_STAGE2_DISCOVERY_CONSTRUCTOR;
    bool valid_status = candidate->status == KOFUN_SEMANTIC_VALIDATED ||
        candidate->status == KOFUN_SEMANTIC_PROVISIONAL ||
        candidate->status == KOFUN_SEMANTIC_ERROR ||
        candidate->status == KOFUN_SEMANTIC_UNAVAILABLE;
    bool valid_visibility =
        candidate->visibility == KOFUN_STAGE2_INTERFACE_PRIVATE ||
        candidate->visibility == KOFUN_STAGE2_INTERFACE_INTERNAL ||
        candidate->visibility == KOFUN_STAGE2_INTERFACE_PUBLIC;
    return valid_kind && valid_status && valid_visibility;
}

static bool query_visible_candidate(
    const KofunStage2DiscoveryCandidate *candidate
) {
    bool visible = candidate->visibility ==
            KOFUN_STAGE2_INTERFACE_INTERNAL ||
        candidate->visibility == KOFUN_STAGE2_INTERFACE_PUBLIC;
    return query_readable_candidate(candidate) && visible;
}

static bool query_source(
    const KofunStage2DiscoverySnapshot *snapshot,
    KofunSemanticSource *source
) {
    memset(source, 0, sizeof(*source));
    source->package_id = snapshot->package_id;
    source->module_id = snapshot->module_id;
    source->file_id = snapshot->file_id;
    source->source_bytes = snapshot->source_bytes;
    memcpy(
        source->source_sha256,
        snapshot->source_sha256,
        sizeof(source->source_sha256)
    );
    if (!query_bytes(
            snapshot->semantic_compatibility,
            sizeof(snapshot->semantic_compatibility),
            &source->semantic_compatibility)) {
        return false;
    }
    source->caller_generation = snapshot->caller_generation;
    return true;
}

bool kofun_stage2_discovery_analyze(
    const KofunStage2SemanticInput *input,
    const char *interface_set_sha256_hex,
    KofunStage2DiscoveryAnalysis *analysis,
    KofunStage2SemanticResult *result
) {
    KofunSemanticSource source;
    if (analysis == NULL || result == NULL) return false;
    memset(analysis, 0, sizeof(*analysis));
    if (!kofun_stage2_analyze_discovery(input, &analysis->semantic, result) ||
        !analysis->semantic.committed) {
        return false;
    }
    if (!query_source(&analysis->semantic, &source)) return false;
    return kofun_discovery_analysis_key_from_source(
        &source,
        interface_set_sha256_hex,
        &analysis->analysis_key
    );
}

static bool query_exact_source(
    const KofunStage2DiscoverySnapshot *snapshot,
    const uint8_t *source,
    size_t source_length
) {
    uint8_t digest[KOFUN_SEMANTIC_ID_BYTES];
    if (source == NULL || source_length != snapshot->source_bytes) {
        return false;
    }
    kofun_sha256(source, source_length, digest);
    return memcmp(
        digest,
        snapshot->source_sha256,
        sizeof(digest)
    ) == 0;
}

static bool query_type(
    const KofunStage2DiscoveryExpression *expression,
    KofunDiscoveryTypeFact *out
) {
    KofunSemanticIdentity identity;
    KofunSemanticFact fact;
    const KofunSemanticIdentity *identities = NULL;
    const KofunSemanticFact *facts = NULL;
    size_t identity_count = 0u;
    size_t fact_count = 0u;
    memset(&identity, 0, sizeof(identity));
    memset(&fact, 0, sizeof(fact));
    if (expression->has_type_identity) {
        identity = expression->type_identity;
        identities = &identity;
        identity_count = 1u;
    }
    if (expression->has_type_fact) {
        fact.owner_node_id = expression->node.node_id;
        fact.kind = KOFUN_SEMANTIC_FACT_TYPE;
        fact.status = expression->type_status;
        if (!query_bytes(
                expression->type_display,
                sizeof(expression->type_display),
                &fact.display) ||
            !query_bytes(
                expression->type_reason,
                sizeof(expression->type_reason),
                &fact.reason)) {
            return false;
        }
        facts = &fact;
        fact_count = 1u;
    }
    return kofun_discovery_type_from_records(
        &expression->node.node_id,
        identities,
        identity_count,
        facts,
        fact_count,
        out
    );
}

size_t kofun_stage2_discovery_query(
    const KofunStage2DiscoveryAnalysis *analysis,
    const uint8_t *source,
    size_t source_length,
    const char *request_bytes,
    size_t request_length,
    char *output,
    size_t output_capacity
) {
    const KofunStage2DiscoverySnapshot *snapshot;
    KofunDiscoveryRequest request;
    KofunDiscoveryReason reason;
    KofunSemanticNode nodes[KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS];
    size_t expression_index = 0u;
    size_t index;
    KofunDiscoveryTypeFact type;
    KofunDiscoverySymbolRecord *records = NULL;
    KofunDiscoveryOperationFact *operations = NULL;
    KofunDiscoveryOmission *omissions = NULL;
    size_t record_count = 0u;
    size_t operation_count = 0u;
    size_t omission_count = 0u;
    bool truncated = false;
    bool complete = true;
    bool unreadable = false;
    size_t written;

    if (analysis == NULL || request_bytes == NULL || output == NULL) return 0u;
    snapshot = &analysis->semantic;
    if (!snapshot->committed ||
        snapshot->source_status != KOFUN_SOURCE_CHECKED ||
        snapshot->completeness != KOFUN_SEMANTIC_COMPLETE ||
        snapshot->expression_count > KOFUN_STAGE2_DISCOVERY_MAX_EXPRESSIONS ||
        snapshot->candidate_count > KOFUN_STAGE2_DISCOVERY_MAX_CANDIDATES ||
        !query_snapshot_strings_are_bounded(snapshot) ||
        !query_exact_source(snapshot, source, source_length)) {
        return 0u;
    }
    memset(&request, 0, sizeof(request));
    reason = KOFUN_DISCOVERY_REASON_INVALID_REQUEST;
    if (!kofun_discovery_request_parse(
            request_bytes, request_length, &request, &reason)) {
        return kofun_discovery_result_emit_factless(
            KOFUN_DISCOVERY_STATUS_INVALID,
            reason,
            NULL,
            output,
            output_capacity
        );
    }
    if (!kofun_discovery_is_current(
            &request, &analysis->analysis_key, &reason)) {
        return kofun_discovery_result_emit_factless(
            KOFUN_DISCOVERY_STATUS_STALE,
            reason,
            &request.analysis,
            output,
            output_capacity
        );
    }
    if (!kofun_discovery_offsets_are_boundaries(
            &request, (const char *)source, source_length)) {
        return kofun_discovery_result_emit_factless(
            KOFUN_DISCOVERY_STATUS_INVALID,
            KOFUN_DISCOVERY_REASON_INVALID_POSITION,
            NULL,
            output,
            output_capacity
        );
    }
    for (index = 0u; index < snapshot->expression_count; index += 1u) {
        nodes[index] = snapshot->expressions[index].node;
    }
    if (!kofun_discovery_select_expression(
            nodes,
            snapshot->expression_count,
            &request,
            &expression_index,
            &reason)) {
        return kofun_discovery_result_emit_factless(
            KOFUN_DISCOVERY_STATUS_INVALID,
            reason,
            NULL,
            output,
            output_capacity
        );
    }
    if (request.kind == KOFUN_DISCOVERY_QUERY_EXPLAIN_OPERATION) {
        return kofun_discovery_result_emit_factless(
            KOFUN_DISCOVERY_STATUS_UNAVAILABLE,
            KOFUN_DISCOVERY_REASON_UNSUPPORTED_IN_PROFILE,
            &analysis->analysis_key,
            output,
            output_capacity
        );
    }
    if (!query_type(&snapshot->expressions[expression_index], &type)) {
        return 0u;
    }

    if (request.kind != KOFUN_DISCOVERY_QUERY_TYPE) {
        size_t capacity = snapshot->candidate_count +
            (snapshot->hidden_candidate_present ? 1u : 0u);
        if (capacity == 0u) capacity = 1u;
        records = calloc(capacity, sizeof(*records));
        operations = calloc(capacity, sizeof(*operations));
        omissions = calloc(
            KOFUN_DISCOVERY_MAX_OMISSIONS,
            sizeof(*omissions)
        );
        if (records == NULL || operations == NULL || omissions == NULL) {
            free(records);
            free(operations);
            free(omissions);
            return 0u;
        }
        for (index = 0u; index < snapshot->candidate_count; index += 1u) {
            const KofunStage2DiscoveryCandidate *candidate =
                &snapshot->candidates[index];
            KofunDiscoverySymbolRecord *record;
            record = &records[record_count++];
            record->symbol_id = candidate->symbol_id;
            record->module_id = candidate->module_id;
            if (!query_bytes(
                    candidate->display_name,
                    sizeof(candidate->display_name),
                    &record->display_name) ||
                !query_bytes(
                    candidate->qualified_name,
                    sizeof(candidate->qualified_name),
                    &record->qualified_name) ||
                !query_bytes(
                    candidate->module_name,
                    sizeof(candidate->module_name),
                    &record->module_name) ||
                !query_bytes(
                    candidate->signature,
                    sizeof(candidate->signature),
                    &record->signature) ||
                !query_bytes(
                    candidate->effect,
                    sizeof(candidate->effect),
                    &record->effect)) {
                free(records);
                free(operations);
                free(omissions);
                return 0u;
            }
            record->status = candidate->status;
            record->receiver_mode = KOFUN_DISCOVERY_RECEIVER_NONE;
            record->visibility = query_visibility(candidate->visibility);
            record->origin_kind = KOFUN_DISCOVERY_ORIGIN_FUNCTION;
            /*
             * This snapshot is caller-owned. Treat every unknown enum as
             * hidden rather than allowing a corrupted value to disclose a
             * name through the public provider record.
             */
            record->visible_to_query = query_visible_candidate(candidate);
            record->in_current_file = true;
            /*
             * Withholding an unreadable record is the right disclosure
             * decision and the wrong completeness one. It leaves the same
             * `hidden-by-visibility` omission a genuinely private
             * declaration does — deliberately, so the two are
             * indistinguishable from outside — but a record this build
             * cannot read is analysis that did not complete, so the answer
             * must not claim it did.
             */
            if (!query_readable_candidate(candidate)) unreadable = true;
        }
        if (snapshot->hidden_candidate_present) {
            KofunDiscoverySymbolRecord *hidden = &records[record_count++];
            memset(hidden, 0, sizeof(*hidden));
            hidden->visible_to_query = false;
            hidden->in_current_file = true;
        }
        operation_count = kofun_discovery_operations_from_symbols(
            records,
            record_count,
            operations,
            capacity,
            omissions,
            KOFUN_DISCOVERY_MAX_OMISSIONS,
            &omission_count,
            &truncated
        );
        operation_count = kofun_discovery_apply_receiver_rule(
            operations,
            operation_count,
            KOFUN_DISCOVERY_RECEIVER_NONE,
            request.include_unavailable
        );
    }

    /*
     * A `hidden-by-visibility` omission is a correct, final answer — the
     * private names were deliberately withheld, not left unanalyzed — so it
     * does not make the disclosed facts incomplete.  Every other omission
     * reason reports something this analysis could not produce.
     */
    for (index = 0u; index < omission_count; index += 1u) {
        if (omissions[index].reason !=
            KOFUN_DISCOVERY_OMISSION_HIDDEN_BY_VISIBILITY) {
            complete = false;
        }
    }
    if (type.status != KOFUN_DISCOVERY_FACT_VALIDATED || truncated ||
        unreadable) {
        complete = false;
    }
    for (index = 0u; index < operation_count; index += 1u) {
        if (operations[index].status != KOFUN_DISCOVERY_FACT_VALIDATED ||
            !operations[index].callable) {
            complete = false;
        }
    }
    written = kofun_discovery_result_emit(
        complete ? KOFUN_DISCOVERY_STATUS_COMPLETE :
            KOFUN_DISCOVERY_STATUS_PARTIAL,
        complete ? KOFUN_DISCOVERY_REASON_NONE :
            KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS,
        &analysis->analysis_key,
        &type,
        operations,
        operation_count,
        omissions,
        omission_count,
        truncated,
        output,
        output_capacity
    );
    free(records);
    free(operations);
    free(omissions);
    return written;
}
