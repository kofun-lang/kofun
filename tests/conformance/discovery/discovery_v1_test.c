#include "discovery_v1.h"

#include <stdio.h>
#include <string.h>

/*
 * Observation harness for the discovery v1 contract layer (#637).
 *
 * Each mode prints what the module decided, so the golden files record
 * behavior rather than restating the implementation.
 */

static const char *const CANONICAL_REQUEST =
    "{\n"
    "  \"analysis\": {\n"
    "    \"file_id\": "
    "\"1111111111111111111111111111111111111111111111111111111111111111\",\n"
    "    \"generation\": 17,\n"
    "    \"interface_set_sha256\": "
    "\"3333333333333333333333333333333333333333333333333333333333333333\",\n"
    "    \"semantic_compatibility\": \"stage2-v1\",\n"
    "    \"source_sha256\": "
    "\"2222222222222222222222222222222222222222222222222222222222222222\"\n"
    "  },\n"
    "  \"position\": {\n"
    "    \"byte_offset\": 84,\n"
    "    \"expression\": {\n"
    "      \"end\": 84,\n"
    "      \"start\": 75\n"
    "    }\n"
    "  },\n"
    "  \"query\": {\n"
    "    \"include_unavailable\": false,\n"
    "    \"kind\": \"type-and-operations\",\n"
    "    \"spelling\": null\n"
    "  },\n"
    "  \"schema\": \"kofun.discovery.request/v1\"\n"
    "}\n";

/* Replace the first occurrence of `from` with `to`, for mutation cases. */
static int mutate(char *out, size_t capacity, const char *from,
                  const char *to) {
    const char *found = strstr(CANONICAL_REQUEST, from);
    size_t prefix;
    size_t total;
    if (found == NULL) {
        return 0;
    }
    prefix = (size_t)(found - CANONICAL_REQUEST);
    total = prefix + strlen(to) + strlen(found + strlen(from));
    if (total + 1u > capacity) {
        return 0;
    }
    memcpy(out, CANONICAL_REQUEST, prefix);
    memcpy(out + prefix, to, strlen(to));
    strcpy(out + prefix + strlen(to), found + strlen(from));
    return 1;
}

static void report_parse(const char *label, const char *bytes) {
    KofunDiscoveryRequest request;
    KofunDiscoveryReason reason;
    const char *name;
    if (kofun_discovery_request_parse(bytes, strlen(bytes), &request,
                                      &reason)) {
        printf("%s: accepted generation=%lld offset=%u span=%u..%u kind=%d "
               "include_unavailable=%s spelling=%s\n",
               label, (long long)request.analysis.generation,
               request.byte_offset, request.expression_start,
               request.expression_end, (int)request.kind,
               request.include_unavailable ? "true" : "false",
               request.has_spelling ? request.spelling : "(null)");
        return;
    }
    name = kofun_discovery_reason_name(reason);
    printf("%s: rejected %s\n", label, name == NULL ? "(none)" : name);
}

static void report_mutation(const char *label, const char *from,
                            const char *to) {
    char buffer[4096];
    if (!mutate(buffer, sizeof(buffer), from, to)) {
        printf("%s: harness could not build the case\n", label);
        return;
    }
    report_parse(label, buffer);
}

static void report_emit(const char *label, KofunDiscoveryStatus status,
                        KofunDiscoveryReason reason, int with_analysis) {
    KofunDiscoveryAnalysisKey analysis;
    char buffer[4096];
    size_t written;
    memset(&analysis, 0, sizeof(analysis));
    memset(analysis.file_id, '1', KOFUN_DISCOVERY_ID_CHARS);
    memset(analysis.source_sha256, '2', KOFUN_DISCOVERY_ID_CHARS);
    memset(analysis.interface_set_sha256, '3', KOFUN_DISCOVERY_ID_CHARS);
    strcpy(analysis.semantic_compatibility, "stage2-v1");
    analysis.generation = 17;

    written = kofun_discovery_result_emit_factless(
        status, reason, with_analysis ? &analysis : NULL, buffer,
        sizeof(buffer));
    if (written == 0) {
        printf("%s: refused\n", label);
        return;
    }
    printf("%s: %zu bytes\n", label, written);
    fwrite(buffer, 1u, written, stdout);
}

static void report_boundaries(const char *label, const char *source,
                              uint32_t start, uint32_t offset, uint32_t end) {
    KofunDiscoveryRequest request;
    memset(&request, 0, sizeof(request));
    request.expression_start = start;
    request.byte_offset = offset;
    request.expression_end = end;
    printf("%s: %s\n", label,
           kofun_discovery_offsets_are_boundaries(&request, source,
                                                  strlen(source))
               ? "boundaries"
               : "rejected");
}


/* ---------------------------------------------------------------------- */
/* Facts                                                                   */
/* ---------------------------------------------------------------------- */

static void fill_id(char *out, char digit) {
    memset(out, digit, KOFUN_DISCOVERY_ID_CHARS);
    out[KOFUN_DISCOVERY_ID_CHARS] = '\0';
}

static KofunDiscoveryAnalysisKey fixture_analysis(void) {
    KofunDiscoveryAnalysisKey analysis;
    memset(&analysis, 0, sizeof(analysis));
    fill_id(analysis.file_id, '1');
    fill_id(analysis.source_sha256, '2');
    fill_id(analysis.interface_set_sha256, '3');
    strcpy(analysis.semantic_compatibility, "stage2-v1");
    analysis.generation = 17;
    return analysis;
}

/* The validated `List[Text]` the first slice is specified against. */
static KofunDiscoveryTypeFact fixture_type(void) {
    KofunDiscoveryTypeFact type;
    memset(&type, 0, sizeof(type));
    type.status = KOFUN_DISCOVERY_FACT_VALIDATED;
    type.identity.kind = KOFUN_DISCOVERY_IDENTITY_TYPE_ID;
    fill_id(type.identity.value, 'a');
    strcpy(type.display, "List[Text]");
    type.has_display = true;
    type.reason = KOFUN_DISCOVERY_FACT_REASON_NONE;
    return type;
}

static KofunDiscoveryOperationFact fixture_operation(
    char symbol_digit, const char *name, const char *signature,
    KofunDiscoveryReceiverMode mode) {
    KofunDiscoveryOperationFact operation;
    memset(&operation, 0, sizeof(operation));
    operation.status = KOFUN_DISCOVERY_FACT_VALIDATED;
    operation.identity.kind = KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID;
    fill_id(operation.identity.value, symbol_digit);
    strcpy(operation.display_name, name);
    strcpy(operation.qualified_name, "core.list.");
    strcat(operation.qualified_name, name);
    strcpy(operation.signature, signature);
    operation.has_signature = true;
    operation.receiver_mode = mode;
    operation.origin.status = KOFUN_DISCOVERY_FACT_VALIDATED;
    operation.origin.kind = KOFUN_DISCOVERY_ORIGIN_MEMBER;
    strcpy(operation.origin.module, "core.list");
    operation.origin.module_identity.kind = KOFUN_DISCOVERY_IDENTITY_MODULE_ID;
    fill_id(operation.origin.module_identity.value, 'b');
    operation.visibility = KOFUN_DISCOVERY_VISIBILITY_PUB;
    operation.callable = true;
    return operation;
}

/* One committed effect requirement, as the live producer reports it: a
 * validated display carrying no symbol of its own. */
static void add_effect(KofunDiscoveryOperationFact *operation,
                       const char *display,
                       KofunDiscoveryFactStatus status) {
    KofunDiscoveryEffectRequirement *effect =
        &operation->effects[operation->effect_count++];
    memset(effect, 0, sizeof(*effect));
    effect->identity.kind = KOFUN_DISCOVERY_IDENTITY_NONE;
    strcpy(effect->display, display);
    effect->status = status;
}

static void emit_facts(const char *label, KofunDiscoveryStatus status,
                       KofunDiscoveryReason reason,
                       const KofunDiscoveryTypeFact *type,
                       KofunDiscoveryOperationFact *operations, size_t count,
                       KofunDiscoveryOmission *omissions, size_t omission_count,
                       int truncated) {
    KofunDiscoveryAnalysisKey analysis = fixture_analysis();
    char buffer[65536];
    size_t written = kofun_discovery_result_emit(
        status, reason, &analysis, type, operations, count, omissions,
        omission_count, truncated ? true : false, buffer, sizeof(buffer));
    if (written == 0) {
        printf("%s: refused\n", label);
        return;
    }
    printf("%s: %zu bytes\n", label, written);
    fwrite(buffer, 1u, written, stdout);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";

    if (strcmp(mode, "parse") == 0) {
        report_parse("canonical", CANONICAL_REQUEST);

        /* Key order, indentation, and unknown fields are all one check. */
        report_mutation("reordered-keys",
                        "\"byte_offset\": 84,\n    \"expression\"",
                        "\"expression\": 0,\n    \"byte_offset\"");
        report_mutation("unknown-field", "  \"schema\":",
                        "  \"extra\": 1,\n  \"schema\":");
        report_mutation("duplicate-key", "  \"schema\":",
                        "  \"query\": {},\n  \"schema\":");
        report_mutation("reindented", "\n  \"position\"", "\n \"position\"");
        report_mutation("trailing-data", "\"kofun.discovery.request/v1\"\n}\n",
                        "\"kofun.discovery.request/v1\"\n}\n{}\n");

        /* Scalars. */
        report_mutation("float-generation", "\"generation\": 17",
                        "\"generation\": 17.0");
        report_mutation("exponent-generation", "\"generation\": 17",
                        "\"generation\": 1e2");
        report_mutation("signed-generation", "\"generation\": 17",
                        "\"generation\": -17");
        report_mutation("leading-zero", "\"generation\": 17",
                        "\"generation\": 017");
        report_mutation("zero-generation", "\"generation\": 17",
                        "\"generation\": 0");
        report_mutation("u53-overflow", "\"generation\": 17",
                        "\"generation\": 9007199254740992");
        report_mutation("u32-overflow", "\"byte_offset\": 84",
                        "\"byte_offset\": 4294967296");
        report_mutation("uppercase-id",
                        "\"1111111111111111111111111111111111111111111111111111"
                        "111111111111\"",
                        "\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                        "AAAAAAAAAAAA\"");
        report_mutation("short-id",
                        "\"1111111111111111111111111111111111111111111111111111"
                        "111111111111\"",
                        "\"1111\"");
        report_mutation("empty-compatibility",
                        "\"semantic_compatibility\": \"stage2-v1\"",
                        "\"semantic_compatibility\": \"\"");

        /* Position consistency is `invalid-position`, not `invalid-request`. */
        report_mutation("offset-before-span", "\"byte_offset\": 84",
                        "\"byte_offset\": 4");
        report_mutation("inverted-span", "\"end\": 84", "\"end\": 4");

        /* `spelling` is required in exactly one direction per query kind. */
        report_mutation("spelling-without-explain", "\"spelling\": null",
                        "\"spelling\": \"map\"");
        report_mutation("explain-without-spelling",
                        "\"kind\": \"type-and-operations\"",
                        "\"kind\": \"explain-operation\"");
        report_mutation("explain-with-spelling",
                        "\"kind\": \"type-and-operations\",\n    "
                        "\"spelling\": null",
                        "\"kind\": \"explain-operation\",\n    "
                        "\"spelling\": \"map\"");
        report_mutation("empty-spelling",
                        "\"kind\": \"type-and-operations\",\n    "
                        "\"spelling\": null",
                        "\"kind\": \"explain-operation\",\n    "
                        "\"spelling\": \"\"");
        report_mutation("unknown-kind", "\"kind\": \"type-and-operations\"",
                        "\"kind\": \"everything\"");
        report_mutation("unknown-schema", "kofun.discovery.request/v1",
                        "kofun.discovery.request/v2");
        report_mutation("control-character",
                        "\"semantic_compatibility\": \"stage2-v1\"",
                        "\"semantic_compatibility\": \"stage2\tv1\"");
        return 0;
    }

    if (strcmp(mode, "emit") == 0) {
        report_emit("invalid", KOFUN_DISCOVERY_STATUS_INVALID,
                    KOFUN_DISCOVERY_REASON_INVALID_REQUEST, 0);
        report_emit("stale-wrong-file", KOFUN_DISCOVERY_STATUS_STALE,
                    KOFUN_DISCOVERY_REASON_WRONG_FILE, 1);
        report_emit("unavailable", KOFUN_DISCOVERY_STATUS_UNAVAILABLE,
                    KOFUN_DISCOVERY_REASON_UNSUPPORTED_IN_PROFILE, 1);

        /* Shapes the contract forbids must be unrepresentable, not merely
         * undocumented. */
        report_emit("invalid-with-analysis", KOFUN_DISCOVERY_STATUS_INVALID,
                    KOFUN_DISCOVERY_REASON_INVALID_REQUEST, 1);
        report_emit("stale-without-analysis", KOFUN_DISCOVERY_STATUS_STALE,
                    KOFUN_DISCOVERY_REASON_WRONG_FILE, 0);
        report_emit("stale-with-wrong-reason", KOFUN_DISCOVERY_STATUS_STALE,
                    KOFUN_DISCOVERY_REASON_LIMIT_EXHAUSTED, 1);
        report_emit("unavailable-without-reason",
                    KOFUN_DISCOVERY_STATUS_UNAVAILABLE,
                    KOFUN_DISCOVERY_REASON_NONE, 1);
        report_emit("complete-is-not-factless", KOFUN_DISCOVERY_STATUS_COMPLETE,
                    KOFUN_DISCOVERY_REASON_NONE, 1);
        return 0;
    }

    if (strcmp(mode, "boundaries") == 0) {
        /* "aé" — the second code point occupies two bytes. */
        report_boundaries("ascii", "let x = 1", 4u, 4u, 5u);
        report_boundaries("end-of-source", "let x", 0u, 5u, 5u);
        report_boundaries("mid-code-point", "a\xc3\xa9z", 0u, 2u, 3u);
        report_boundaries("after-code-point", "a\xc3\xa9z", 0u, 3u, 4u);
        report_boundaries("past-end", "abc", 0u, 2u, 9u);
        return 0;
    }


    if (strcmp(mode, "facts") == 0) {
        KofunDiscoveryTypeFact type = fixture_type();
        KofunDiscoveryOperationFact operations[4];
        KofunDiscoveryOmission omissions[2];

        /* A complete `List[Text]` answer: validated type and callable rows. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[1] = fixture_operation('4', "append", "(edit List[Text], Text) -> Unit",
                                          KOFUN_DISCOVERY_RECEIVER_EDIT);
        emit_facts("complete", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 2u, NULL, 0u,
                   0);

        /*
         * Rows sort by raw SymbolId, not by display text or production order.
         * This case is built so the two orders *disagree*: `append` sorts
         * first alphabetically but carries the higher SymbolId, so canonical
         * order must put `length` first. Without the disagreement the
         * assertion would pass for an implementation that sorted by name.
         */
        operations[0] = fixture_operation('9', "append", "(edit List[Text], Text) -> Unit",
                                          KOFUN_DISCOVERY_RECEIVER_EDIT);
        operations[1] = fixture_operation('2', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        {
            KofunDiscoveryAnalysisKey analysis = fixture_analysis();
            char buffer[65536];
            size_t written = kofun_discovery_result_emit(
                KOFUN_DISCOVERY_STATUS_COMPLETE, KOFUN_DISCOVERY_REASON_NONE,
                &analysis, &type, operations, 2u, NULL, 0u, false, buffer,
                sizeof(buffer));
            printf("key-order-first-row: %s (emitted %s)\n",
                   operations[0].display_name,
                   written > 0 ? "yes" : "no");
        }

        /* A `read` receiver hides `edit`/`take` by default ... */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[1] = fixture_operation('4', "append", "(edit List[Text], Text) -> Unit",
                                          KOFUN_DISCOVERY_RECEIVER_EDIT);
        operations[2] = fixture_operation('5', "consume", "(take List[Text]) -> Text",
                                          KOFUN_DISCOVERY_RECEIVER_TAKE);
        {
            size_t kept = kofun_discovery_apply_receiver_rule(
                operations, 3u, KOFUN_DISCOVERY_RECEIVER_READ, false);
            printf("read-default-kept: %zu\n", kept);
            emit_facts("read-default", KOFUN_DISCOVERY_STATUS_COMPLETE,
                       KOFUN_DISCOVERY_REASON_NONE, &type, operations, kept,
                       NULL, 0u, 0);
        }

        /* ... and explains them when asked, as unavailable rows that say why. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[1] = fixture_operation('4', "append", "(edit List[Text], Text) -> Unit",
                                          KOFUN_DISCOVERY_RECEIVER_EDIT);
        operations[2] = fixture_operation('5', "consume", "(take List[Text]) -> Text",
                                          KOFUN_DISCOVERY_RECEIVER_TAKE);
        {
            size_t kept = kofun_discovery_apply_receiver_rule(
                operations, 3u, KOFUN_DISCOVERY_RECEIVER_READ, true);
            printf("read-explained-kept: %zu\n", kept);
            /* Explained rejections are not `complete`: they are useful facts
             * that are not all callable. */
            emit_facts("read-explained", KOFUN_DISCOVERY_STATUS_PARTIAL,
                       KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS,
                       &type, operations, kept, NULL, 0u, 0);
        }

        /* An `edit` receiver narrows nothing: it may still call `read` rows. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[1] = fixture_operation('4', "append", "(edit List[Text], Text) -> Unit",
                                          KOFUN_DISCOVERY_RECEIVER_EDIT);
        printf("edit-receiver-kept: %zu\n",
               kofun_discovery_apply_receiver_rule(
                   operations, 2u, KOFUN_DISCOVERY_RECEIVER_EDIT, false));

        /* A generic incomplete value is provisional, never `Any`. */
        {
            KofunDiscoveryTypeFact provisional;
            memset(&provisional, 0, sizeof(provisional));
            provisional.status = KOFUN_DISCOVERY_FACT_PROVISIONAL;
            strcpy(provisional.display, "_T1");
            provisional.has_display = true;
            provisional.reason = KOFUN_DISCOVERY_FACT_REASON_INCOMPLETE_ANALYSIS;
            emit_facts("provisional-type", KOFUN_DISCOVERY_STATUS_PARTIAL,
                       KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS,
                       &provisional, NULL, 0u, NULL, 0u, 0);
        }

        /*
         * Effects the compiler committed travel with the row. They sort with
         * identity-bearing requirements first and null identities by display
         * bytes, so this case is built with the display order reversed: an
         * emitter that kept production order would put `io` before `clock`.
         */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        add_effect(&operations[0], "io", KOFUN_DISCOVERY_FACT_VALIDATED);
        add_effect(&operations[0], "clock", KOFUN_DISCOVERY_FACT_VALIDATED);
        emit_facts("validated-effects", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* Extension and trait candidates are omitted without disclosing
         * anything about them. */
        memset(omissions, 0, sizeof(omissions));
        omissions[0].reason = KOFUN_DISCOVERY_OMISSION_UNSUPPORTED_IN_PROFILE;
        omissions[1].reason = KOFUN_DISCOVERY_OMISSION_HIDDEN_BY_VISIBILITY;
        emit_facts("omissions-sorted", KOFUN_DISCOVERY_STATUS_PARTIAL,
                   KOFUN_DISCOVERY_REASON_UNSUPPORTED_IN_PROFILE, &type, NULL,
                   0u, omissions, 2u, 0);
        return 0;
    }

    if (strcmp(mode, "facts-refused") == 0) {
        KofunDiscoveryTypeFact type = fixture_type();
        KofunDiscoveryOperationFact operations[2];

        /* `complete` cannot carry a non-callable row ... */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[0].callable = false;
        operations[0].rejection_reasons[0] = KOFUN_DISCOVERY_REJECT_REQUIRES_EDIT;
        operations[0].rejection_reason_count = 1u;
        emit_facts("complete-with-unavailable-row",
                   KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* ... nor a reason, nor truncation. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        emit_facts("complete-with-reason", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_LIMIT_EXHAUSTED, &type, operations,
                   1u, NULL, 0u, 0);
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        emit_facts("complete-truncated", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   1);

        /* An unavailable row with nothing to say is not emittable. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[0].callable = false;
        emit_facts("unavailable-without-reason", KOFUN_DISCOVERY_STATUS_PARTIAL,
                   KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS, &type,
                   operations, 1u, NULL, 0u, 0);

        /* A callable row needs a signature and a receiver mode. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[0].has_signature = false;
        emit_facts("callable-without-signature", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* A non-validated row cannot claim to be callable. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[0].status = KOFUN_DISCOVERY_FACT_PROVISIONAL;
        emit_facts("provisional-but-callable", KOFUN_DISCOVERY_STATUS_PARTIAL,
                   KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS, &type,
                   operations, 1u, NULL, 0u, 0);

        /* Rows are unique by SymbolId. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        operations[1] = fixture_operation('7', "size", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        emit_facts("duplicate-symbol", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 2u, NULL, 0u,
                   0);

        /* A validated type must carry a TypeId and a display. */
        {
            KofunDiscoveryTypeFact broken = fixture_type();
            broken.identity.kind = KOFUN_DISCOVERY_IDENTITY_NONE;
            operations[0] = fixture_operation('7', "length",
                                              "(read List[Text]) -> Int",
                                              KOFUN_DISCOVERY_RECEIVER_READ);
            emit_facts("validated-type-without-identity",
                       KOFUN_DISCOVERY_STATUS_COMPLETE,
                       KOFUN_DISCOVERY_REASON_NONE, &broken, operations, 1u,
                       NULL, 0u, 0);
        }

        /*
         * A callable row's effect requirements are part of its closure: an
         * unvalidated requirement means the caller cannot know whether the
         * call is permitted, so the row may not be presented as callable.
         */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        add_effect(&operations[0], "io", KOFUN_DISCOVERY_FACT_PROVISIONAL);
        emit_facts("callable-with-provisional-effect",
                   KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* An effect with nothing to display names no requirement at all. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        add_effect(&operations[0], "", KOFUN_DISCOVERY_FACT_VALIDATED);
        emit_facts("effect-without-display", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* Requirements are a set: a repeated one would let a client read a
         * count out of an array that carries none. */
        operations[0] = fixture_operation('7', "length", "(read List[Text]) -> Int",
                                          KOFUN_DISCOVERY_RECEIVER_READ);
        add_effect(&operations[0], "io", KOFUN_DISCOVERY_FACT_VALIDATED);
        add_effect(&operations[0], "io", KOFUN_DISCOVERY_FACT_VALIDATED);
        emit_facts("duplicate-effect", KOFUN_DISCOVERY_STATUS_COMPLETE,
                   KOFUN_DISCOVERY_REASON_NONE, &type, operations, 1u, NULL, 0u,
                   0);

        /* `partial` with no facts at all explains nothing. */
        emit_facts("partial-without-facts", KOFUN_DISCOVERY_STATUS_PARTIAL,
                   KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS, NULL,
                   NULL, 0u, NULL, 0u, 0);

        /* A factless status does not belong on this entry point. */
        emit_facts("stale-is-not-factbearing", KOFUN_DISCOVERY_STATUS_STALE,
                   KOFUN_DISCOVERY_REASON_WRONG_FILE, NULL, NULL, 0u, NULL, 0u,
                   0);
        return 0;
    }

    fprintf(stderr, "usage: discovery-test parse|emit|boundaries|facts|facts-refused\n");
    return 2;
}
