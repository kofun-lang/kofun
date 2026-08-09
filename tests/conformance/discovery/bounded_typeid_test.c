#include "discovery_query.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * The bounded builtin/constructed type identity owner (#637).
 *
 * What makes this an identity rather than a rendered spelling is observable
 * only across fixtures: the same constructed reference must name the same
 * TypeId from a different file, module, logical path, generation, and byte
 * offsets; different component types must name different TypeIds; a
 * constructed reference must be neither its head nor its argument; and a
 * current-file declaration of a component must shadow the catalog rather than
 * be answered for by it.
 *
 * Each fixture is therefore one process run. Sharing a process would let a
 * later analysis inherit compiler-owned per-pass caches keyed on a reused
 * source address, and an identity that only holds within one process is not
 * the property being claimed here. `run.sh` compares the accumulated
 * observations, so the cross-fixture equalities are pinned by the golden.
 */

static const char *const EMPTY_INTERFACE_SET =
    "80d1c79a9cc431fc7b585d15fcf9a21b31e2daa8002300b1b95cda519d163804";

static void fail(const char *detail) {
    fprintf(stderr, "bounded-typeid: %s\n", detail);
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

/* The parameter occurrence `name` introduced by the declaration text
 * `needle`, as the live snapshot committed it. */
static const KofunStage2DiscoveryExpression *use_of(
    const KofunStage2DiscoveryAnalysis *analysis,
    const uint8_t *source,
    const char *needle,
    const char *name
) {
    const char *match = strstr((const char *)source, needle);
    uint32_t start;
    size_t index;
    if (match == NULL) fail("fixture has no such declaration");
    start = (uint32_t)((size_t)(match - (const char *)source) +
        strlen(needle) - strlen(name));
    for (index = 0u;
         index < analysis->semantic.expression_count;
         index += 1u) {
        const KofunStage2DiscoveryExpression *expression =
            &analysis->semantic.expressions[index];
        if (expression->node.span.start == start &&
            expression->node.span.end == start + (uint32_t)strlen(name)) {
            return expression;
        }
    }
    fail("live snapshot has no expression at the declared parameter");
    return NULL;
}

static void report(
    const char *label,
    const KofunStage2DiscoveryExpression *expression
) {
    static const char digits[] = "0123456789abcdef";
    char hex[KOFUN_SEMANTIC_ID_BYTES * 2u + 1u];
    size_t index;
    if (!expression->has_type_fact) {
        printf("%s: no-type-fact\n", label);
        return;
    }
    if (!expression->has_type_identity) {
        /* Honest refusal: a display-only fact with no identity to promote. */
        printf(
            "%s: identity=null display=%s status=%s\n",
            label,
            expression->type_display,
            expression->type_status == KOFUN_SEMANTIC_VALIDATED ?
                "validated" : "not-validated"
        );
        return;
    }
    if (expression->type_identity.kind != KOFUN_SEMANTIC_ID_TYPE ||
        expression->type_identity.status != KOFUN_SEMANTIC_VALIDATED ||
        expression->type_status != KOFUN_SEMANTIC_VALIDATED) {
        fail("committed identity is not a validated TypeId");
    }
    for (index = 0u; index < KOFUN_SEMANTIC_ID_BYTES; index += 1u) {
        uint8_t byte = expression->type_identity.value.bytes[index];
        hex[index * 2u] = digits[(byte >> 4u) & 0x0fu];
        hex[index * 2u + 1u] = digits[byte & 0x0fu];
    }
    hex[KOFUN_SEMANTIC_ID_BYTES * 2u] = '\0';
    printf(
        "%s: identity=%s display=%s status=validated\n",
        label,
        hex,
        expression->type_display
    );
}

int main(int argc, char **argv) {
    uint8_t *source;
    size_t source_length = 0u;
    KofunStage2SemanticInput input;
    KofunStage2SemanticResult result;
    KofunStage2DiscoveryAnalysis analysis;
    const char *logical_path;
    const char *fixture;
    unsigned long generation;

    if (argc != 4) {
        fail("usage: bounded-typeid-test FIXTURE LOGICAL-PATH GENERATION");
    }
    fixture = argv[1];
    logical_path = argv[2];
    generation = strtoul(argv[3], NULL, 10);
    source = read_file(fixture, &source_length);
    if (source == NULL) fail("could not read fixture");

    memset(&input, 0, sizeof(input));
    memset(&analysis, 0, sizeof(analysis));
    input.source = source;
    input.source_length = source_length;
    input.logical_path.bytes = (const uint8_t *)logical_path;
    input.logical_path.length = (uint32_t)strlen(logical_path);
    input.caller_generation = (uint64_t)generation;
    /*
     * The ownership authority is the one that accepts a constructed
     * `List[Text]` parameter today; the identity must not depend on it, which
     * the `Int`/`Text` rows in the same run already exercise against the same
     * catalog.
     */
    input.authority = KOFUN_STAGE2_SEMANTIC_OWNERSHIP;
    if (!kofun_stage2_discovery_analyze(
            &input, EMPTY_INTERFACE_SET, &analysis, &result)) {
        fprintf(
            stderr,
            "bounded-typeid: exit=%u diagnostic=%s fallback=%s tooling=%s\n",
            (unsigned)result.compiler_exit_class,
            result.diagnostic_code,
            result.diagnostic_fallback,
            result.tooling_error.detail
        );
        fail("Stage 2 discovery analysis did not commit");
    }

    printf("logical-path=%s generation=%lu\n", logical_path, generation);
    if (strstr((const char *)source, "for value in values") != NULL) {
        report(
            strstr((const char *)source, "List[Choice]") != NULL ?
                "List[Choice]" : "List[Text]",
            use_of(&analysis, source, "in values", "values")
        );
    }
    if (strstr((const char *)source, "for count in counts") != NULL) {
        report("List[Int]", use_of(&analysis, source, "in counts", "counts"));
    }
    if (strstr((const char *)source, "return value\n") != NULL) {
        report("Int", use_of(&analysis, source, "return value", "value"));
    }
    if (strstr((const char *)source, "print(word)") != NULL) {
        report("Text", use_of(&analysis, source, "print(word", "word"));
    }
    free(source);
    return 0;
}
