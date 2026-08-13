#define _POSIX_C_SOURCE 200809L

#include "stage2_kif_producer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static KofunKifVisibility kif_visibility(
    KofunStage2InterfaceVisibility visibility
) {
    return visibility == KOFUN_STAGE2_INTERFACE_PUBLIC ?
        KOFUN_KIF_VISIBILITY_PUBLIC : KOFUN_KIF_VISIBILITY_INTERNAL;
}

static KofunKifFactKind kif_kind(KofunStage2InterfaceFactKind kind) {
    switch (kind) {
        case KOFUN_STAGE2_INTERFACE_FUNCTION:
            return KOFUN_KIF_FACT_FUNCTION;
        case KOFUN_STAGE2_INTERFACE_ADT:
            return KOFUN_KIF_FACT_ADT;
        case KOFUN_STAGE2_INTERFACE_CONSTRUCTOR:
            return KOFUN_KIF_FACT_CONSTRUCTOR;
        case KOFUN_STAGE2_INTERFACE_RECORD:
            return 0;
    }
    return 0;
}

static bool semantic_id_is_nonzero(const KofunSemanticId *id) {
    uint8_t combined = 0u;
    size_t index;
    for (index = 0u; index < KOFUN_SEMANTIC_ID_BYTES; index += 1u) {
        combined |= id->bytes[index];
    }
    return combined != 0u;
}

static void project_fact(
    const KofunStage2InterfaceSnapshot *snapshot,
    const KofunStage2InterfaceFact *source,
    KofunKifFact *destination,
    KofunKifParameterLabel *parameter_labels
) {
    memset(destination, 0, sizeof(*destination));
    memcpy(destination->namespace_id, source->namespace_id.bytes,
        KOFUN_KIF_ID_BYTES);
    memcpy(destination->symbol_id, source->symbol_id.bytes,
        KOFUN_KIF_ID_BYTES);
    destination->kind = kif_kind(source->kind);
    destination->visibility = kif_visibility(source->visibility);
    destination->name = (char *)source->name;
    destination->name_length = strlen(source->name);
    destination->parameter_count = source->parameter_count;
    if (source->kind == KOFUN_STAGE2_INTERFACE_FUNCTION) {
        if (source->parameter_count != 0u) {
            destination->parameter_type_symbol_ids =
                (uint8_t *)snapshot->type_reference_symbol_ids[
                    source->parameter_type_start].bytes;
            destination->parameter_labels = parameter_labels +
                source->parameter_label_start;
            for (size_t index = 0u;
                 index < source->parameter_count;
                 index += 1u) {
                size_t label_index = source->parameter_label_start + index;
                if (snapshot->parameter_label_lengths[label_index] != 0u) {
                    destination->parameter_labels[index].bytes =
                        (char *)snapshot->parameter_labels[label_index];
                    destination->parameter_labels[index].length =
                        snapshot->parameter_label_lengths[label_index];
                }
            }
        }
        memcpy(
            destination->result_type_symbol_id,
            source->result_type_symbol_id.bytes,
            KOFUN_KIF_ID_BYTES
        );
        destination->result_type = semantic_id_is_nonzero(
            &source->result_type_symbol_id) ?
                KOFUN_KIF_TYPE_NOMINAL : KOFUN_KIF_TYPE_INT;
    }
    if (source->kind == KOFUN_STAGE2_INTERFACE_CONSTRUCTOR) {
        destination->constructor_payload_count =
            source->constructor_payload_count;
        memcpy(
            destination->constructor_payload_type_symbol_id,
            source->constructor_payload_type_symbol_id.bytes,
            KOFUN_KIF_ID_BYTES
        );
        memcpy(destination->owner_symbol_id, source->owner_symbol_id.bytes,
            KOFUN_KIF_ID_BYTES);
        destination->constructor_ordinal = source->constructor_ordinal;
    }
}

bool kofun_stage2_publish_kif(
    const KofunStage2SemanticInput *input,
    KofunSemanticBytes edition,
    const char *destination,
    bool cancellation_observed_after_commit,
    KofunStage2KifResult *result
) {
    KofunStage2InterfaceSnapshot snapshot;
    KofunKifInterface interface;
    size_t public_count = 0u;
    size_t internal_count = 0u;
    size_t public_output = 0u;
    size_t internal_output = 0u;
    KofunKifParameterLabel parameter_labels[
        KOFUN_STAGE2_INTERFACE_MAX_TYPE_REFERENCES];
    size_t index;
    if (result == NULL) return false;
    memset(result, 0, sizeof(*result));
    result->write.status = KOFUN_KIF_INTERNAL_INVARIANT;
    result->write.message = "KIF compiler producer did not commit";
    if (destination == NULL || destination[0] == '\0') return false;
    if (!kofun_stage2_compile_interface(
            input, edition, cancellation_observed_after_commit,
            &snapshot, &result->compiler)) {
        return false;
    }
    if (!snapshot.committed) return false;
    for (index = 0u; index < snapshot.fact_count; index += 1u) {
        if (snapshot.facts[index].visibility ==
                KOFUN_STAGE2_INTERFACE_PUBLIC) {
            public_count += 1u;
        } else if (snapshot.facts[index].visibility ==
                       KOFUN_STAGE2_INTERFACE_INTERNAL) {
            internal_count += 1u;
        } else {
            return false;
        }
    }
    memset(&interface, 0, sizeof(interface));
    memset(parameter_labels, 0, sizeof(parameter_labels));
    if (public_count != 0u) {
        interface.public_facts = calloc(
            public_count, sizeof(*interface.public_facts));
    }
    if (internal_count != 0u) {
        interface.internal_facts = calloc(
            internal_count, sizeof(*interface.internal_facts));
    }
    if ((public_count != 0u && interface.public_facts == NULL) ||
        (internal_count != 0u && interface.internal_facts == NULL)) {
        free(interface.public_facts);
        free(interface.internal_facts);
        result->write.message = "KIF compiler fact allocation failed";
        return false;
    }
    memcpy(interface.package_id, snapshot.package_id.bytes, KOFUN_KIF_ID_BYTES);
    memcpy(interface.module_id, snapshot.module_id.bytes, KOFUN_KIF_ID_BYTES);
    memcpy(interface.edition, snapshot.edition, strlen(snapshot.edition) + 1u);
    /* RFC-0012 0x800A. Ordinary here is a consequence of a refusal, not an
     * assumption: `after_optional_module_header` consumes only `module` and a
     * dotted path, so a source carrying a `trust` line reaches the top-level
     * loop and is refused as E2S02. This producer's only fact source is that
     * compiler, so a raw-foreign module cannot arrive here at all.
     *
     * tests/conformance/modules/stage2-kif-producer asserts that refusal
     * directly. If the canonical compiler ever learns the trust grammar, that
     * assertion fails and this line has to be revisited — which is the point of
     * asserting it rather than describing it in this comment. */
    interface.module_trust = KOFUN_KIF_TRUST_ORDINARY;
    for (index = 0u; index < snapshot.fact_count; index += 1u) {
        const KofunStage2InterfaceFact *source = &snapshot.facts[index];
        KofunKifFact *destination_fact;
        if (source->visibility == KOFUN_STAGE2_INTERFACE_PUBLIC) {
            destination_fact = &interface.public_facts[public_output++];
        } else {
            destination_fact = &interface.internal_facts[internal_output++];
        }
        project_fact(
            &snapshot,
            source,
            destination_fact,
            parameter_labels
        );
    }
    interface.public_fact_count = public_output;
    interface.internal_fact_count = internal_output;
    result->write = kofun_kif_write(&interface, destination);
    free(interface.public_facts);
    free(interface.internal_facts);
    result->published = result->write.status == KOFUN_KIF_OK;
    return result->published;
}

#ifndef KOFUN_STAGE2_KIF_PRODUCER_LIBRARY
static uint8_t *read_source(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long measured;
    uint8_t *bytes;
    if (file == NULL || fseek(file, 0, SEEK_END) != 0 ||
        (measured = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0 ||
        (unsigned long)measured > KOFUN_SEMANTIC_MAX_EVENT_BYTES) {
        if (file != NULL) (void)fclose(file);
        return NULL;
    }
    bytes = malloc((size_t)measured + 1u);
    if (bytes == NULL) {
        (void)fclose(file);
        return NULL;
    }
    if (fread(bytes, 1u, (size_t)measured, file) != (size_t)measured) {
        (void)fclose(file);
        free(bytes);
        return NULL;
    }
    if (fclose(file) != 0) {
        free(bytes);
        return NULL;
    }
    bytes[measured] = 0u;
    *length = (size_t)measured;
    return bytes;
}

int main(int argc, char **argv) {
    KofunStage2SemanticInput input;
    KofunStage2KifResult result;
    uint8_t *source;
    size_t source_length;
    bool cancel = false;
    int offset = 1;
    if (argc == 6 && strcmp(argv[1], "--cancel-after-commit") == 0) {
        cancel = true;
        offset = 2;
    } else if (argc != 5) {
        fputs(
            "usage: kofun-stage2-kif [--cancel-after-commit] "
            "INPUT LOGICAL-PATH OUTPUT EDITION\n",
            stderr
        );
        return 2;
    }
    source = read_source(argv[offset], &source_length);
    if (source == NULL) {
        fputs("EKI01: cannot read Stage 2 source\n", stderr);
        return 3;
    }
    memset(&input, 0, sizeof(input));
    input.source = source;
    input.source_length = source_length;
    input.logical_path.bytes = (const uint8_t *)argv[offset + 1];
    input.logical_path.length = (uint32_t)strlen(argv[offset + 1]);
    input.authority = KOFUN_STAGE2_SEMANTIC_COMPILE;
    if (!kofun_stage2_publish_kif(
            &input,
            (KofunSemanticBytes){
                (const uint8_t *)argv[offset + 3],
                (uint32_t)strlen(argv[offset + 3])
            },
            argv[offset + 2], cancel, &result)) {
        if (result.compiler.has_source_diagnostic) {
            puts(result.compiler.diagnostic_fallback);
        }
        if (result.compiler.tooling_emission_failed) {
            (void)fprintf(stderr, "%s: %s\n",
                result.compiler.tooling_error.code,
                result.compiler.tooling_error.detail);
        } else if (
            !result.compiler.has_source_diagnostic &&
            result.compiler.source_status != KOFUN_SOURCE_CANCELLED
        ) {
            (void)fprintf(stderr, "%s: %s\n",
                kofun_kif_status_name(result.write.status),
                result.write.message);
        }
        free(source);
        if (result.compiler.source_status == KOFUN_SOURCE_CANCELLED) return 1;
        if (result.compiler.compiler_exit_class != 0u) {
            return (int)result.compiler.compiler_exit_class;
        }
        return 3;
    }
    (void)printf("ok: %s (authoritative KIF v2)\n", argv[offset]);
    free(source);
    return 0;
}
#endif
