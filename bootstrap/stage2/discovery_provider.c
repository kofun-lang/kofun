#include "discovery_provider.h"

#include <string.h>

static void hex_encode(const uint8_t *bytes, size_t byte_count, char *out) {
    static const char digits[] = "0123456789abcdef";
    size_t index;
    for (index = 0; index < byte_count; index++) {
        out[index * 2u] = digits[(bytes[index] >> 4) & 0x0fu];
        out[(index * 2u) + 1u] = digits[bytes[index] & 0x0fu];
    }
    out[byte_count * 2u] = '\0';
}

/* Copy a bounded semantic string, refusing anything that would not fit rather
 * than silently truncating an identity-bearing value. */
static bool copy_bytes(const KofunSemanticBytes *source, char *out,
                       size_t capacity) {
    if (source == NULL || source->bytes == NULL) {
        out[0] = '\0';
        return true;
    }
    if ((size_t)source->length >= capacity) {
        return false;
    }
    memcpy(out, source->bytes, source->length);
    out[source->length] = '\0';
    return true;
}

static bool is_hex_id(const char *text) {
    size_t index;
    if (text == NULL) {
        return false;
    }
    for (index = 0; index < KOFUN_DISCOVERY_ID_CHARS; index++) {
        char c = text[index];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return false;
        }
    }
    return text[KOFUN_DISCOVERY_ID_CHARS] == '\0';
}

bool kofun_discovery_analysis_key_from_source(
    const KofunSemanticSource *source, const char *interface_set_sha256_hex,
    KofunDiscoveryAnalysisKey *out) {
    if (source == NULL || out == NULL) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    hex_encode(source->file_id.bytes, KOFUN_SEMANTIC_ID_BYTES, out->file_id);
    hex_encode(source->source_sha256, KOFUN_SEMANTIC_ID_BYTES,
               out->source_sha256);

    if (interface_set_sha256_hex == NULL) {
        /* Fails closed: an all-zero digest matches no real request, so a
         * caller that forgot to supply one gets `stale-interface-set` instead
         * of an accidental match. */
        memset(out->interface_set_sha256, '0', KOFUN_DISCOVERY_ID_CHARS);
        out->interface_set_sha256[KOFUN_DISCOVERY_ID_CHARS] = '\0';
    } else {
        if (!is_hex_id(interface_set_sha256_hex)) {
            return false;
        }
        memcpy(out->interface_set_sha256, interface_set_sha256_hex,
               KOFUN_DISCOVERY_ID_CHARS + 1u);
    }

    if (!copy_bytes(&source->semantic_compatibility,
                    out->semantic_compatibility,
                    sizeof(out->semantic_compatibility))) {
        return false;
    }
    if (source->caller_generation > (uint64_t)KOFUN_DISCOVERY_U53_MAX) {
        return false;
    }
    out->generation = (int64_t)source->caller_generation;
    return true;
}

bool kofun_discovery_is_current(const KofunDiscoveryRequest *request,
                                const KofunDiscoveryAnalysisKey *live,
                                KofunDiscoveryReason *reason) {
    if (request == NULL || live == NULL || reason == NULL) {
        return false;
    }
    *reason = KOFUN_DISCOVERY_REASON_NONE;

    /* FileId first: a request aimed at another file is never answered with
     * this file's facts, whatever else happens to agree. */
    if (strcmp(request->analysis.file_id, live->file_id) != 0) {
        *reason = KOFUN_DISCOVERY_REASON_WRONG_FILE;
        return false;
    }
    if (strcmp(request->analysis.semantic_compatibility,
               live->semantic_compatibility) != 0) {
        *reason = KOFUN_DISCOVERY_REASON_STALE_SEMANTIC_COMPATIBILITY;
        return false;
    }
    if (strcmp(request->analysis.source_sha256, live->source_sha256) != 0) {
        *reason = KOFUN_DISCOVERY_REASON_STALE_SOURCE;
        return false;
    }
    if (strcmp(request->analysis.interface_set_sha256,
               live->interface_set_sha256) != 0) {
        *reason = KOFUN_DISCOVERY_REASON_STALE_INTERFACE_SET;
        return false;
    }
    if (request->analysis.generation != live->generation) {
        *reason = KOFUN_DISCOVERY_REASON_STALE_GENERATION;
        return false;
    }
    return true;
}

/* Which node kinds can be the expression a position names. Declarations and
 * scopes contain the offset too, so without this filter the "narrowest"
 * search would happily return a parameter or a scope. */
static bool is_expression_kind(KofunSemanticNodeKind kind) {
    switch (kind) {
    case KOFUN_SEMANTIC_NODE_CALL:
    case KOFUN_SEMANTIC_NODE_REFERENCE:
    case KOFUN_SEMANTIC_NODE_IF:
    case KOFUN_SEMANTIC_NODE_MATCH:
        return true;
    default:
        return false;
    }
}

bool kofun_discovery_select_expression(const KofunSemanticNode *nodes,
                                       size_t node_count,
                                       const KofunDiscoveryRequest *request,
                                       size_t *out_index,
                                       KofunDiscoveryReason *reason) {
    size_t index;
    size_t best = 0;
    bool found = false;
    uint32_t best_width = 0;

    if (request == NULL || out_index == NULL || reason == NULL ||
        (node_count > 0 && nodes == NULL)) {
        return false;
    }
    *reason = KOFUN_DISCOVERY_REASON_INVALID_POSITION;

    for (index = 0; index < node_count; index++) {
        const KofunSemanticNode *node = &nodes[index];
        uint32_t width;

        if (!is_expression_kind(node->kind)) {
            continue;
        }
        if (node->span.start > node->span.end) {
            continue; /* a malformed record is not a candidate */
        }
        if (request->byte_offset < node->span.start ||
            request->byte_offset > node->span.end) {
            continue;
        }
        width = node->span.end - node->span.start;
        /*
         * Strictly narrower wins. On a tie the first record is kept, so the
         * choice does not depend on emission order — two distinct nodes with
         * identical spans would otherwise make the answer depend on how the
         * producer happened to schedule them, and the contract requires
         * byte-identical results across repeated and parallel runs.
         */
        if (!found || width < best_width) {
            found = true;
            best = index;
            best_width = width;
        }
    }

    if (!found) {
        return false;
    }
    /*
     * The client's span must be the one actually parsed here. A span computed
     * against edited source can still contain the offset while naming a
     * different expression, and answering that with these facts would be
     * confidently wrong.
     */
    if (nodes[best].span.start != request->expression_start ||
        nodes[best].span.end != request->expression_end) {
        return false;
    }

    *out_index = best;
    *reason = KOFUN_DISCOVERY_REASON_NONE;
    return true;
}

static bool same_id(const KofunSemanticId *left, const KofunSemanticId *right) {
    return memcmp(left->bytes, right->bytes, KOFUN_SEMANTIC_ID_BYTES) == 0;
}

static KofunDiscoveryFactStatus map_status(KofunSemanticStatus status) {
    switch (status) {
    case KOFUN_SEMANTIC_VALIDATED:
        return KOFUN_DISCOVERY_FACT_VALIDATED;
    case KOFUN_SEMANTIC_PROVISIONAL:
        return KOFUN_DISCOVERY_FACT_PROVISIONAL;
    case KOFUN_SEMANTIC_ERROR:
        return KOFUN_DISCOVERY_FACT_ERROR;
    default:
        return KOFUN_DISCOVERY_FACT_UNAVAILABLE;
    }
}

/* The producer spells its reasons as bytes; the contract has a closed enum.
 * An unrecognized spelling maps to `incomplete-analysis` rather than being
 * dropped, because a fact with no reason at all would violate the shape rule
 * for every non-validated status. */
static KofunDiscoveryFactReason map_reason(const KofunSemanticBytes *reason) {
    static const struct {
        const char *spelling;
        KofunDiscoveryFactReason reason;
    } table[] = {
        {KOFUN_SEMANTIC_REASON_CANCELLED_BEFORE_ANALYSIS,
         KOFUN_DISCOVERY_FACT_REASON_CANCELLED_BEFORE_ANALYSIS},
        {KOFUN_SEMANTIC_REASON_UNSUPPORTED_STAGE2_FEATURE,
         KOFUN_DISCOVERY_FACT_REASON_UNSUPPORTED_CURRENT_STAGE2_FEATURE},
    };
    size_t index;

    if (reason == NULL || reason->bytes == NULL || reason->length == 0) {
        return KOFUN_DISCOVERY_FACT_REASON_INCOMPLETE_ANALYSIS;
    }
    for (index = 0; index < sizeof(table) / sizeof(table[0]); index++) {
        size_t span = strlen(table[index].spelling);
        if ((size_t)reason->length == span &&
            memcmp(reason->bytes, table[index].spelling, span) == 0) {
            return table[index].reason;
        }
    }
    return KOFUN_DISCOVERY_FACT_REASON_INCOMPLETE_ANALYSIS;
}

bool kofun_discovery_type_from_records(
    const KofunSemanticId *node_id, const KofunSemanticIdentity *identities,
    size_t identity_count, const KofunSemanticFact *facts, size_t fact_count,
    KofunDiscoveryTypeFact *out) {
    const KofunSemanticIdentity *type_identity = NULL;
    const KofunSemanticFact *type_fact = NULL;
    size_t index;

    if (node_id == NULL || out == NULL ||
        (identity_count > 0 && identities == NULL) ||
        (fact_count > 0 && facts == NULL)) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    for (index = 0; index < identity_count; index++) {
        if (identities[index].kind == KOFUN_SEMANTIC_ID_TYPE &&
            same_id(&identities[index].owner_node_id, node_id)) {
            type_identity = &identities[index];
            break;
        }
    }
    for (index = 0; index < fact_count; index++) {
        if (facts[index].kind == KOFUN_SEMANTIC_FACT_TYPE &&
            same_id(&facts[index].owner_node_id, node_id)) {
            type_fact = &facts[index];
            break;
        }
    }

    if (type_fact == NULL) {
        /*
         * No type fact at all. The service never invents `Any`, so this is an
         * unavailable type — which also carries no display, per the contract.
         */
        out->status = KOFUN_DISCOVERY_FACT_UNAVAILABLE;
        out->identity.kind = KOFUN_DISCOVERY_IDENTITY_NONE;
        out->has_display = false;
        out->reason = KOFUN_DISCOVERY_FACT_REASON_TYPE_NOT_AVAILABLE_IN_CURRENT_SUBSET;
        return true;
    }

    out->status = map_status(type_fact->status);
    if (!copy_bytes(&type_fact->display, out->display, sizeof(out->display))) {
        return false;
    }
    out->has_display = out->display[0] != '\0';

    /*
     * A validated type needs a validated TypeId as well as a validated fact.
     * Either half missing downgrades the result rather than producing a
     * validated type with nothing to identify it.
     */
    if (out->status == KOFUN_DISCOVERY_FACT_VALIDATED && type_identity != NULL &&
        type_identity->status == KOFUN_SEMANTIC_VALIDATED && out->has_display) {
        out->identity.kind = KOFUN_DISCOVERY_IDENTITY_TYPE_ID;
        hex_encode(type_identity->value.bytes, KOFUN_SEMANTIC_ID_BYTES,
                   out->identity.value);
        out->reason = KOFUN_DISCOVERY_FACT_REASON_NONE;
        return true;
    }

    if (out->status == KOFUN_DISCOVERY_FACT_VALIDATED) {
        /* Validated by the producer, but not disclosable as validated here. */
        out->status = KOFUN_DISCOVERY_FACT_PROVISIONAL;
    }
    out->identity.kind = KOFUN_DISCOVERY_IDENTITY_NONE;
    if (out->status == KOFUN_DISCOVERY_FACT_UNAVAILABLE) {
        out->has_display = false;
        out->display[0] = '\0';
    }
    out->reason = map_reason(&type_fact->reason);
    return true;
}

/* Record an omission, keeping the set unique. An omission says only that
 * something was left out and why — never how much, or what. */
static void note_omission(KofunDiscoveryOmission *omissions, size_t capacity,
                          size_t *count, KofunDiscoveryOmissionReason reason) {
    size_t index;
    if (omissions == NULL || count == NULL) {
        return;
    }
    for (index = 0; index < *count; index++) {
        if (omissions[index].reason == reason) {
            return;
        }
    }
    if (*count >= capacity) {
        return;
    }
    memset(&omissions[*count], 0, sizeof(omissions[*count]));
    omissions[*count].reason = reason;
    omissions[*count].has_requested_spelling = false;
    (*count)++;
}

static bool reject(KofunDiscoveryOperationFact *operation,
                   KofunDiscoveryRejectionReason reason) {
    size_t index;
    for (index = 0; index < operation->rejection_reason_count; index++) {
        if (operation->rejection_reasons[index] == reason) {
            return true;
        }
    }
    if (operation->rejection_reason_count >=
        KOFUN_DISCOVERY_MAX_REJECTION_REASONS) {
        return false;
    }
    operation->rejection_reasons[operation->rejection_reason_count++] = reason;
    return true;
}

size_t kofun_discovery_operations_from_symbols(
    const KofunDiscoverySymbolRecord *records, size_t record_count,
    KofunDiscoveryOperationFact *out, size_t out_capacity,
    KofunDiscoveryOmission *omissions, size_t omission_capacity,
    size_t *omission_count, bool *truncated) {
    size_t index;
    size_t written = 0;
    size_t omitted = 0;

    if (omission_count != NULL) {
        *omission_count = 0;
    }
    if (truncated != NULL) {
        *truncated = false;
    }
    if (out == NULL || (record_count > 0 && records == NULL)) {
        return 0;
    }
    if (out_capacity > KOFUN_DISCOVERY_MAX_OPERATIONS) {
        out_capacity = KOFUN_DISCOVERY_MAX_OPERATIONS;
    }

    for (index = 0; index < record_count; index++) {
        const KofunDiscoverySymbolRecord *record = &records[index];
        KofunDiscoveryOperationFact *operation;

        /*
         * Visibility first, and unconditionally. A hidden candidate must not
         * reach any later branch, because every one of them would disclose
         * something about it — even an "unavailable" row names it.
         */
        if (!record->visible_to_query) {
            note_omission(omissions, omission_capacity, &omitted,
                          KOFUN_DISCOVERY_OMISSION_HIDDEN_BY_VISIBILITY);
            continue;
        }
        /* Outside the current file is outside this slice's profile. */
        if (!record->in_current_file) {
            note_omission(omissions, omission_capacity, &omitted,
                          KOFUN_DISCOVERY_OMISSION_NOT_IMPORTED);
            continue;
        }

        if (written >= out_capacity) {
            /* Stop, and say so, rather than returning a short answer that
             * reads as complete. */
            note_omission(omissions, omission_capacity, &omitted,
                          KOFUN_DISCOVERY_OMISSION_LIMIT_EXHAUSTED);
            if (truncated != NULL) {
                *truncated = true;
            }
            break;
        }

        operation = &out[written];
        memset(operation, 0, sizeof(*operation));
        operation->status = map_status(record->status);
        operation->identity.kind = KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID;
        hex_encode(record->symbol_id.bytes, KOFUN_SEMANTIC_ID_BYTES,
                   operation->identity.value);

        if (!copy_bytes(&record->display_name, operation->display_name,
                        sizeof(operation->display_name)) ||
            !copy_bytes(&record->qualified_name, operation->qualified_name,
                        sizeof(operation->qualified_name)) ||
            !copy_bytes(&record->module_name, operation->origin.module,
                        sizeof(operation->origin.module)) ||
            !copy_bytes(&record->signature, operation->signature,
                        sizeof(operation->signature)) ||
            !copy_bytes(&record->effect, operation->effects[0].display,
                        sizeof(operation->effects[0].display))) {
            /* A value too long to represent is not silently clipped: an
             * identity-bearing string that lost bytes is a different name. */
            note_omission(omissions, omission_capacity, &omitted,
                          KOFUN_DISCOVERY_OMISSION_INCOMPLETE_ANALYSIS);
            continue;
        }
        if (operation->display_name[0] == '\0' ||
            operation->qualified_name[0] == '\0') {
            note_omission(omissions, omission_capacity, &omitted,
                          KOFUN_DISCOVERY_OMISSION_INCOMPLETE_ANALYSIS);
            continue;
        }
        if (operation->effects[0].display[0] != '\0') {
            /* The record disclosed a compiler-validated requirement; the
             * projection carries it and never invents an identity for it. */
            operation->effects[0].identity.kind =
                KOFUN_DISCOVERY_IDENTITY_NONE;
            operation->effects[0].status = KOFUN_DISCOVERY_FACT_VALIDATED;
            operation->effect_count = 1u;
        }

        operation->has_signature = operation->signature[0] != '\0';
        operation->receiver_mode = record->receiver_mode;
        operation->visibility = record->visibility;
        operation->origin.kind = record->origin_kind;
        operation->origin.status = operation->status;
        operation->origin.module_identity.kind =
            KOFUN_DISCOVERY_IDENTITY_MODULE_ID;
        hex_encode(record->module_id.bytes, KOFUN_SEMANTIC_ID_BYTES,
                   operation->origin.module_identity.value);

        /*
         * Callable requires the whole closure: a validated fact, a signature,
         * and a receiver mode. Each missing piece is stated as its own
         * rejection rather than collapsed into one vague reason, because the
         * caller's next action differs — re-run analysis versus accept that
         * the operation genuinely does not apply here.
         */
        operation->callable = true;
        if (operation->status != KOFUN_DISCOVERY_FACT_VALIDATED) {
            operation->callable = false;
            reject(operation, KOFUN_DISCOVERY_REJECT_INCOMPLETE_ANALYSIS);
        }
        if (!operation->has_signature) {
            operation->callable = false;
            reject(operation, KOFUN_DISCOVERY_REJECT_INCOMPLETE_ANALYSIS);
        }
        if (operation->receiver_mode == KOFUN_DISCOVERY_RECEIVER_NULL) {
            operation->callable = false;
            reject(operation, KOFUN_DISCOVERY_REJECT_INCOMPLETE_ANALYSIS);
        }
        written++;
    }

    if (omission_count != NULL) {
        *omission_count = omitted;
    }
    return written;
}
