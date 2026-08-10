#include "discovery_query.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *const EMPTY_INTERFACE_SET =
    "80d1c79a9cc431fc7b585d15fcf9a21b31e2daa8002300b1b95cda519d163804";

static uint8_t *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long size;
    uint8_t *bytes;
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) return NULL;
    size = ftell(file);
    if (size < 0 || fseek(file, 0, SEEK_SET) != 0) {
        (void)fclose(file);
        return NULL;
    }
    bytes = malloc((size_t)size + 1u);
    if (bytes == NULL ||
        fread(bytes, 1u, (size_t)size, file) != (size_t)size) {
        free(bytes);
        (void)fclose(file);
        return NULL;
    }
    (void)fclose(file);
    bytes[size] = 0u;
    *length = (size_t)size;
    return bytes;
}

static void fail(const char *detail) {
    fprintf(stderr, "live-query: %s\n", detail);
    exit(1);
}

static size_t expression_start(const uint8_t *source) {
    const char *match = strstr((const char *)source, "in values");
    if (match == NULL) fail("fixture has no List[Text] loop reference");
    return (size_t)(match - (const char *)source) + 3u;
}

static void print_id(const char *label, const uint8_t *bytes) {
    static const char digits[] = "0123456789abcdef";
    size_t index;
    printf("%s=", label);
    for (index = 0u; index < KOFUN_SEMANTIC_ID_BYTES; index += 1u) {
        putchar(digits[(bytes[index] >> 4u) & 0x0fu]);
        putchar(digits[bytes[index] & 0x0fu]);
    }
    putchar('\n');
}

static size_t build_request(
    char *request,
    size_t capacity,
    const KofunStage2DiscoveryAnalysis *analysis,
    const char *source_sha256,
    size_t offset,
    size_t start,
    size_t end
) {
    int written = snprintf(
        request,
        capacity,
        "{\n"
        "  \"analysis\": {\n"
        "    \"file_id\": \"%s\",\n"
        "    \"generation\": %lld,\n"
        "    \"interface_set_sha256\": \"%s\",\n"
        "    \"semantic_compatibility\": \"%s\",\n"
        "    \"source_sha256\": \"%s\"\n"
        "  },\n"
        "  \"position\": {\n"
        "    \"byte_offset\": %zu,\n"
        "    \"expression\": {\n"
        "      \"end\": %zu,\n"
        "      \"start\": %zu\n"
        "    }\n"
        "  },\n"
        "  \"query\": {\n"
        "    \"include_unavailable\": true,\n"
        "    \"kind\": \"type-and-operations\",\n"
        "    \"spelling\": null\n"
        "  },\n"
        "  \"schema\": \"kofun.discovery.request/v1\"\n"
        "}\n",
        analysis->analysis_key.file_id,
        (long long)analysis->analysis_key.generation,
        analysis->analysis_key.interface_set_sha256,
        analysis->analysis_key.semantic_compatibility,
        source_sha256,
        offset,
        end,
        start
    );
    if (written < 0 || (size_t)written >= capacity) {
        fail("request buffer exhausted");
    }
    return (size_t)written;
}

static bool contains_bytes(
    const char *bytes,
    size_t length,
    const char *needle
) {
    size_t needle_length = strlen(needle);
    size_t index;
    if (needle_length > length) return false;
    for (index = 0u; index + needle_length <= length; index += 1u) {
        if (memcmp(bytes + index, needle, needle_length) == 0) return true;
    }
    return false;
}

static KofunStage2DiscoveryCandidate *candidate_named(
    KofunStage2DiscoveryAnalysis *analysis,
    const char *name
) {
    size_t index;
    for (index = 0u; index < analysis->semantic.candidate_count; index += 1u) {
        KofunStage2DiscoveryCandidate *candidate =
            &analysis->semantic.candidates[index];
        if (strcmp(candidate->display_name, name) == 0) return candidate;
    }
    return NULL;
}

static void require_unterminated_refused(
    KofunStage2DiscoveryAnalysis *analysis,
    const uint8_t *source,
    size_t source_length,
    const char *request,
    size_t request_length,
    char *output,
    char *field,
    size_t field_capacity
) {
    char saved[KOFUN_STAGE2_DISCOVERY_QUALIFIED_NAME_BYTES];
    size_t observed;
    if (field_capacity > sizeof(saved)) {
        fail("snapshot text field exceeds mutation buffer");
    }
    memcpy(saved, field, field_capacity);
    memset(field, 'x', field_capacity);
    observed = kofun_stage2_discovery_query(
        analysis,
        source,
        source_length,
        request,
        request_length,
        output,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    memcpy(field, saved, field_capacity);
    if (observed != 0u) {
        fail("unterminated snapshot text was accepted");
    }
}

int main(int argc, char **argv) {
    uint8_t *source;
    size_t source_length = 0u;
    size_t start;
    KofunStage2SemanticInput input;
    KofunStage2SemanticResult semantic_result;
    KofunStage2DiscoveryAnalysis analysis;
    char request[4096];
    char stale_request[4096];
    char stale_sha256[KOFUN_DISCOVERY_ID_CHARS + 1u];
    size_t request_length;
    size_t probe_length;
    char *first;
    char *second;
    size_t first_length;
    size_t second_length;
    KofunStage2DiscoveryCandidate *answer;
    KofunStage2DiscoveryCandidate *count;
    KofunStage2DiscoveryCandidate *scan;
    KofunStage2DiscoveryCandidate *double_value;
    KofunStage2InterfaceVisibility saved_visibility;
    KofunStage2DiscoveryCandidateKind saved_kind;
    KofunSemanticStatus saved_status;
    static const char logical_path[] =
        "tests/conformance/discovery/live_list_text.kofun";

    if (argc != 2) fail("usage: live-query-test FIXTURE");
    source = read_file(argv[1], &source_length);
    if (source == NULL) fail("could not read fixture");
    start = expression_start(source);
    if (start > UINT32_MAX || start + strlen("values") > UINT32_MAX) {
        fail("fixture expression is out of range");
    }
    memset(&input, 0, sizeof(input));
    input.source = source;
    input.source_length = source_length;
    input.logical_path.bytes = (const uint8_t *)logical_path;
    input.logical_path.length = (uint32_t)strlen(logical_path);
    input.caller_generation = 19u;
    input.authority = KOFUN_STAGE2_SEMANTIC_OWNERSHIP;
    if (!kofun_stage2_discovery_analyze(
            &input, EMPTY_INTERFACE_SET, &analysis, &semantic_result)) {
        free(source);
        fail("live Stage 2 analysis did not commit");
    }
    request_length = build_request(
        request,
        sizeof(request),
        &analysis,
        analysis.analysis_key.source_sha256,
        start,
        start,
        start + strlen("values")
    );
    first = malloc(KOFUN_DISCOVERY_MAX_RESULT_BYTES);
    second = malloc(KOFUN_DISCOVERY_MAX_RESULT_BYTES);
    if (first == NULL || second == NULL) {
        free(first);
        free(second);
        free(source);
        fail("result allocation failed");
    }
    first_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        first,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    second_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    if (first_length == 0u || first_length != second_length ||
        memcmp(first, second, first_length) != 0) {
        free(first);
        free(second);
        free(source);
        fail("repeated query bytes differ");
    }
    memcpy(
        stale_sha256,
        analysis.analysis_key.source_sha256,
        sizeof(stale_sha256)
    );
    stale_sha256[0] = stale_sha256[0] == '0' ? '1' : '0';
    probe_length = build_request(
        stale_request,
        sizeof(stale_request),
        &analysis,
        stale_sha256,
        start,
        start,
        start + strlen("values")
    );
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        stale_request,
        probe_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    if (probe_length == 0u ||
        !contains_bytes(second, probe_length, "\"reason\": \"stale-source\"")) {
        free(first);
        free(second);
        free(source);
        fail("source-digest mismatch was not stale");
    }
    probe_length = build_request(
        stale_request,
        sizeof(stale_request),
        &analysis,
        analysis.analysis_key.source_sha256,
        start + 1u,
        start + 1u,
        start + strlen("values")
    );
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        stale_request,
        probe_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    if (probe_length == 0u ||
        !contains_bytes(
            second,
            probe_length,
            "\"reason\": \"invalid-position\"")) {
        free(first);
        free(second);
        free(source);
        fail("non-matching expression span was not invalid");
    }
    source[start] ^= 1u;
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    source[start] ^= 1u;
    if (probe_length != 0u) {
        free(first);
        free(second);
        free(source);
        fail("non-analyzed source buffer was accepted");
    }
    answer = candidate_named(&analysis, "answer");
    count = candidate_named(&analysis, "Count");
    scan = candidate_named(&analysis, "scan");
    double_value = candidate_named(&analysis, "double");
    if (answer == NULL || count == NULL || scan == NULL ||
        double_value == NULL) {
        free(first);
        free(second);
        free(source);
        fail("fixture is missing a required operation candidate");
    }
    if (count->kind != KOFUN_STAGE2_DISCOVERY_CONSTRUCTOR ||
        count->status != KOFUN_SEMANTIC_VALIDATED ||
        strcmp(count->signature, "Int -> LiveChoice") != 0) {
        free(first);
        free(second);
        free(source);
        fail("unary Int constructor is not an exact validated candidate");
    }
    if (scan->status != KOFUN_SEMANTIC_VALIDATED ||
        strcmp(scan->signature, "List[Text] -> Int") != 0 ||
        strcmp(scan->effect, "io") != 0) {
        free(first);
        free(second);
        free(source);
        fail("io List[Text] function is not an exact validated candidate");
    }
    if (double_value->status != KOFUN_SEMANTIC_VALIDATED ||
        strcmp(double_value->signature, "Int -> Int") != 0 ||
        double_value->effect[0] != '\0' ||
        answer->effect[0] != '\0') {
        free(first);
        free(second);
        free(source);
        fail("pure builtin-closed function is not an exact validated candidate");
    }
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        analysis.semantic.semantic_compatibility,
        sizeof(analysis.semantic.semantic_compatibility)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        analysis.semantic.expressions[0].type_display,
        sizeof(analysis.semantic.expressions[0].type_display)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        analysis.semantic.expressions[0].type_reason,
        sizeof(analysis.semantic.expressions[0].type_reason)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        answer->display_name,
        sizeof(answer->display_name)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        answer->qualified_name,
        sizeof(answer->qualified_name)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        answer->module_name,
        sizeof(answer->module_name)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        answer->signature,
        sizeof(answer->signature)
    );
    require_unterminated_refused(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        scan->effect,
        sizeof(scan->effect)
    );
    saved_visibility = answer->visibility;
    answer->visibility = (KofunStage2InterfaceVisibility)99;
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    answer->visibility = saved_visibility;
    if (probe_length == 0u ||
        contains_bytes(second, probe_length, "answer")) {
        free(first);
        free(second);
        free(source);
        fail("invalid visibility disclosed a candidate name");
    }
    saved_kind = answer->kind;
    answer->kind = (KofunStage2DiscoveryCandidateKind)99;
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    answer->kind = saved_kind;
    if (probe_length == 0u ||
        contains_bytes(second, probe_length, "answer")) {
        free(first);
        free(second);
        free(source);
        fail("invalid candidate kind disclosed a candidate name");
    }
    saved_status = answer->status;
    answer->status = (KofunSemanticStatus)99;
    probe_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        second,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    answer->status = saved_status;
    if (probe_length == 0u ||
        contains_bytes(second, probe_length, "answer")) {
        free(first);
        free(second);
        free(source);
        fail("invalid candidate status disclosed a candidate name");
    }
    print_id("file-id", analysis.semantic.file_id.bytes);
    print_id("module-id", analysis.semantic.module_id.bytes);
    printf("source-sha256=%s\n", analysis.analysis_key.source_sha256);
    printf("generation=%lld\n", (long long)analysis.analysis_key.generation);
    printf("expression=%zu..%zu\n", start, start + strlen("values"));
    printf("expressions=%zu candidates=%zu hidden=%s\n",
           analysis.semantic.expression_count,
           analysis.semantic.candidate_count,
           analysis.semantic.hidden_candidate_present ? "yes" : "no");
    printf("result-bytes=%zu repeated=identical\n", first_length);
    printf("stale=stale-source span=invalid-position source-buffer=refused\n");
    printf("invalid-visibility-kind-status=hidden\n");
    printf("unterminated-snapshot-text=refused\n");
    if (fwrite(first, 1u, first_length, stdout) != first_length) {
        free(first);
        free(second);
        free(source);
        fail("could not write observation");
    }
    free(first);
    free(second);
    free(source);
    return 0;
}
