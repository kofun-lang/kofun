#include "discovery_query.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * The two ways a validated callable row can be claimed without the closure
 * that would justify it (#637).
 *
 * Both are failures of the same kind: a well-formed answer that is not the
 * answer the compiler can support. Neither is visible from a result that
 * merely looks well shaped, which is why each is observed here as a status
 * rather than as a rendering.
 *
 * 1. `result-closure` — the signature fact's dependencies are its parameter
 *    bindings and nothing else, so a function's result type is in no
 *    dependency list. A row for `fn f(v: Int) -> Wibble` renders a perfectly
 *    readable `Int -> Wibble` while naming a type no owner ever issued an
 *    identity for.
 *
 * 2. `unreadable-record` — an enum this build does not define is withheld,
 *    which is the right disclosure decision and the wrong completeness one.
 *    The withheld record leaves the same `hidden-by-visibility` omission a
 *    private declaration does, deliberately, so the two stay
 *    indistinguishable from outside; but analysis did not complete, and the
 *    result must not say it did.
 */

static const char *const EMPTY_INTERFACE_SET =
    "80d1c79a9cc431fc7b585d15fcf9a21b31e2daa8002300b1b95cda519d163804";

static void fail(const char *detail) {
    fprintf(stderr, "closure: %s\n", detail);
    exit(1);
}

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

static bool contains(const char *bytes, size_t length, const char *needle) {
    size_t span = strlen(needle);
    size_t index;
    if (span > length) return false;
    for (index = 0u; index + span <= length; index += 1u) {
        if (memcmp(bytes + index, needle, span) == 0) return true;
    }
    return false;
}

static size_t build_request(
    char *request,
    size_t capacity,
    const KofunStage2DiscoveryAnalysis *analysis,
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
        analysis->analysis_key.source_sha256,
        offset,
        end,
        start
    );
    if (written < 0 || (size_t)written >= capacity) {
        fail("request buffer exhausted");
    }
    return (size_t)written;
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
    fail("fixture is missing a required candidate");
    return NULL;
}

/* Report a candidate's disclosed facts without asserting a spelling for
 * them, so the golden records what the producer decided. */
static void report_candidate(
    KofunStage2DiscoveryAnalysis *analysis,
    const char *name
) {
    const KofunStage2DiscoveryCandidate *candidate =
        candidate_named(analysis, name);
    const char *status;
    switch (candidate->status) {
    case KOFUN_SEMANTIC_VALIDATED: status = "validated"; break;
    case KOFUN_SEMANTIC_PROVISIONAL: status = "provisional"; break;
    case KOFUN_SEMANTIC_ERROR: status = "error"; break;
    default: status = "unavailable"; break;
    }
    printf(
        "%s: status=%s signature=%s\n",
        name,
        status,
        candidate->signature[0] == '\0' ? "(none)" : candidate->signature
    );
}

int main(int argc, char **argv) {
    uint8_t *source;
    size_t source_length = 0u;
    size_t start;
    const char *match;
    KofunStage2SemanticInput input;
    KofunStage2SemanticResult result;
    KofunStage2DiscoveryAnalysis analysis;
    KofunStage2DiscoveryCandidate *closed;
    KofunSemanticStatus saved_status;
    char request[4096];
    size_t request_length;
    char *output;
    size_t output_length;
    static const char logical_path[] =
        "tests/conformance/discovery/unidentified_result.kofun";

    if (argc != 2) fail("usage: closure-test FIXTURE");
    source = read_file(argv[1], &source_length);
    if (source == NULL) fail("could not read fixture");
    match = strstr((const char *)source, "in values");
    if (match == NULL) fail("fixture has no List[Text] loop reference");
    start = (size_t)(match - (const char *)source) + 3u;

    memset(&input, 0, sizeof(input));
    memset(&analysis, 0, sizeof(analysis));
    input.source = source;
    input.source_length = source_length;
    input.logical_path.bytes = (const uint8_t *)logical_path;
    input.logical_path.length = (uint32_t)strlen(logical_path);
    input.caller_generation = 41u;
    input.authority = KOFUN_STAGE2_SEMANTIC_OWNERSHIP;
    if (!kofun_stage2_discovery_analyze(
            &input, EMPTY_INTERFACE_SET, &analysis, &result)) {
        fprintf(
            stderr,
            "closure: exit=%u diagnostic=%s fallback=%s tooling=%s\n",
            (unsigned)result.compiler_exit_class,
            result.diagnostic_code,
            result.diagnostic_fallback,
            result.tooling_error.detail
        );
        fail("Stage 2 discovery analysis did not commit");
    }

    output = malloc(KOFUN_DISCOVERY_MAX_RESULT_BYTES);
    if (output == NULL) fail("result allocation failed");
    request_length = build_request(
        request,
        sizeof(request),
        &analysis,
        start,
        start,
        start + strlen("values")
    );

    /*
     * Case 1. Two functions name a result type no owner identifies, one with
     * a parameter and one without, because the parameter-bearing form is
     * reached through a different branch than the nullary one.
     */
    report_candidate(&analysis, "closed");
    report_candidate(&analysis, "nominal_result");
    report_candidate(&analysis, "open_result");
    report_candidate(&analysis, "open_nullary");

    output_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        output,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    if (output_length == 0u) fail("query produced no result");
    printf(
        "result-closure: status=%s open-result-row-callable=%s\n",
        contains(output, output_length, "\"status\": \"complete\"") ?
            "complete" : "partial",
        contains(
            output,
            output_length,
            "\"display_name\": \"open_result\",\n      \"documentation\": null") &&
            contains(output, output_length, "\"availability\": \"callable\"") &&
            contains(output, output_length, "\"signature\": \"Int -> Wibble\"") ?
            "yes" : "no"
    );
    if (contains(output, output_length, "\"signature\": \"Int -> Wibble\"") ||
        contains(output, output_length, "\"signature\": \"() -> Wibble\"")) {
        free(output);
        free(source);
        fail("a signature naming an unidentified result type was disclosed");
    }

    /*
     * Case 2. An enum this build does not define. The name must not appear,
     * and the answer must not claim to be complete.
     */
    closed = candidate_named(&analysis, "closed");
    saved_status = closed->status;
    closed->status = (KofunSemanticStatus)99;
    output_length = kofun_stage2_discovery_query(
        &analysis,
        source,
        source_length,
        request,
        request_length,
        output,
        KOFUN_DISCOVERY_MAX_RESULT_BYTES
    );
    closed->status = saved_status;
    if (output_length == 0u) fail("corrupt-status query produced no result");
    printf(
        "unreadable-record: status=%s name-disclosed=%s omission=%s\n",
        contains(output, output_length, "\"status\": \"complete\"") ?
            "complete" : "partial",
        contains(output, output_length, "closed") ? "yes" : "no",
        contains(output, output_length, "\"reason\": \"hidden-by-visibility\"") ?
            "hidden-by-visibility" : "(none)"
    );
    if (contains(output, output_length, "\"status\": \"complete\"")) {
        free(output);
        free(source);
        fail("an unreadable candidate record was absorbed into `complete`");
    }
    if (contains(output, output_length, "closed")) {
        free(output);
        free(source);
        fail("an unreadable candidate record disclosed its name");
    }

    free(output);
    free(source);
    return 0;
}
