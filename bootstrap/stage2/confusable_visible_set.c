#include "confusable_visible_set.h"

#include "sha256.h"
#include "../../unicode/kofun_unicode.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t input_index;
    uint8_t *skeleton;
    size_t skeleton_length;
} VisibleWorkBinding;

static const KofunVisibleBinding *visible_comparison_bindings;
static const VisibleWorkBinding *visible_comparison_work;

static int compare_bytes(
    const uint8_t *left,
    size_t left_length,
    const uint8_t *right,
    size_t right_length
) {
    size_t common = left_length < right_length ? left_length : right_length;
    int result = common == 0u ? 0 : memcmp(left, right, common);
    if (result != 0) return result;
    if (left_length == right_length) return 0;
    return left_length < right_length ? -1 : 1;
}

static int compare_work_bindings(const void *left, const void *right) {
    const VisibleWorkBinding *a = left;
    const VisibleWorkBinding *b = right;
    const KofunVisibleBinding *a_binding =
        &visible_comparison_bindings[a->input_index];
    const KofunVisibleBinding *b_binding =
        &visible_comparison_bindings[b->input_index];
    int result = memcmp(a_binding->resolving_module_id,
        b_binding->resolving_module_id, KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = memcmp(a_binding->namespace_id, b_binding->namespace_id,
        KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = compare_bytes(a->skeleton, a->skeleton_length,
        b->skeleton, b->skeleton_length);
    if (result != 0) return result;
    result = compare_bytes(a_binding->effective_spelling,
        a_binding->effective_spelling_length,
        b_binding->effective_spelling,
        b_binding->effective_spelling_length);
    if (result != 0) return result;
    result = memcmp(a_binding->binding_id, b_binding->binding_id,
        KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = memcmp(a_binding->target_symbol_id, b_binding->target_symbol_id,
        KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = strcmp(a_binding->canonical_provenance,
        b_binding->canonical_provenance);
    if (result != 0) return result;
    if (a_binding->span_start != b_binding->span_start) {
        return a_binding->span_start < b_binding->span_start ? -1 : 1;
    }
    if (a_binding->span_end != b_binding->span_end) {
        return a_binding->span_end < b_binding->span_end ? -1 : 1;
    }
    return 0;
}

static bool same_collision_key(
    const VisibleWorkBinding *left,
    const VisibleWorkBinding *right
) {
    const KofunVisibleBinding *a =
        &visible_comparison_bindings[left->input_index];
    const KofunVisibleBinding *b =
        &visible_comparison_bindings[right->input_index];
    return memcmp(a->resolving_module_id, b->resolving_module_id,
               KOFUN_VISIBLE_ID_BYTES) == 0 &&
        memcmp(a->namespace_id, b->namespace_id,
               KOFUN_VISIBLE_ID_BYTES) == 0 &&
        compare_bytes(left->skeleton, left->skeleton_length,
            right->skeleton, right->skeleton_length) == 0;
}

static bool same_spelling(
    const KofunVisibleBinding *left,
    const KofunVisibleBinding *right
) {
    return compare_bytes(left->effective_spelling,
        left->effective_spelling_length, right->effective_spelling,
        right->effective_spelling_length) == 0;
}

static void visible_hash_framed(
    KofunSha256 *context,
    const uint8_t *bytes,
    size_t length
) {
    uint8_t header[8];
    size_t index;
    for (index = 0u; index < sizeof(header); index += 1u) {
        header[index] = (uint8_t)((uint64_t)length >> (56u - index * 8u));
    }
    kofun_sha256_update(context, header, sizeof(header));
    kofun_sha256_update(context, bytes, length);
}

static void compute_cache_key(
    const VisibleWorkBinding *work,
    size_t count,
    uint8_t output[KOFUN_VISIBLE_ID_BYTES]
) {
    static const uint8_t domain[] = "kofun.cache.visible-confusables/v1";
    const char *unicode_digest = kofun_unicode_data_digest();
    KofunSha256 context;
    size_t index;
    kofun_sha256_init(&context);
    visible_hash_framed(&context, domain, sizeof(domain) - 1u);
    visible_hash_framed(&context, (const uint8_t *)unicode_digest,
        strlen(unicode_digest));
    for (index = 0u; index < count; index += 1u) {
        const KofunVisibleBinding *binding =
            &visible_comparison_bindings[work[index].input_index];
        visible_hash_framed(&context, binding->resolving_module_id,
            KOFUN_VISIBLE_ID_BYTES);
        visible_hash_framed(&context, binding->namespace_id, KOFUN_VISIBLE_ID_BYTES);
        visible_hash_framed(&context, binding->effective_spelling,
            binding->effective_spelling_length);
        visible_hash_framed(&context, binding->binding_id, KOFUN_VISIBLE_ID_BYTES);
        visible_hash_framed(&context, binding->target_symbol_id,
            KOFUN_VISIBLE_ID_BYTES);
    }
    kofun_sha256_finish(&context, output);
}

static bool binding_is_primary(
    const KofunVisibleBinding *candidate,
    const KofunVisibleBinding *current
) {
    int identity_order;
    identity_order = memcmp(candidate->binding_id, current->binding_id,
        KOFUN_VISIBLE_ID_BYTES);
    if (identity_order != 0) return identity_order > 0;
    if (candidate->site_kind != current->site_kind) {
        return candidate->site_kind > current->site_kind;
    }
    return strcmp(candidate->canonical_provenance,
        current->canonical_provenance) > 0;
}

static int compare_representatives(const void *left, const void *right) {
    size_t a_index = *(const size_t *)left;
    size_t b_index = *(const size_t *)right;
    const KofunVisibleBinding *a = &visible_comparison_bindings[
        visible_comparison_work[a_index].input_index];
    const KofunVisibleBinding *b = &visible_comparison_bindings[
        visible_comparison_work[b_index].input_index];
    int result = memcmp(a->namespace_id, b->namespace_id,
        KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = memcmp(a->binding_id, b->binding_id, KOFUN_VISIBLE_ID_BYTES);
    if (result != 0) return result;
    result = strcmp(a->canonical_provenance, b->canonical_provenance);
    if (result != 0) return result;
    return compare_bytes(a->effective_spelling, a->effective_spelling_length,
        b->effective_spelling, b->effective_spelling_length);
}

static bool valid_binding(const KofunVisibleBinding *binding) {
    return binding->effective_spelling != NULL &&
        binding->effective_spelling_length > 0u &&
        binding->effective_spelling_length <= 256u &&
        binding->canonical_provenance != NULL &&
        binding->canonical_provenance[0] != '\0' &&
        binding->span_start <= binding->span_end &&
        binding->site_kind >= KOFUN_VISIBLE_SITE_LOCAL &&
        binding->site_kind <= KOFUN_VISIBLE_SITE_RE_EXPORT;
}

KofunVisibleConfusableResult kofun_check_visible_confusables(
    const KofunVisibleBinding *bindings,
    size_t binding_count,
    KofunVisibleConfusableDiagnostic *diagnostics,
    size_t diagnostic_capacity
) {
    KofunVisibleConfusableResult result;
    VisibleWorkBinding *work = NULL;
    size_t *representatives = NULL;
    size_t index;
    memset(&result, 0, sizeof(result));
    result.status = KOFUN_VISIBLE_CONFUSABLE_OK;
    if (binding_count > KOFUN_VISIBLE_BINDING_LIMIT) {
        result.status = KOFUN_VISIBLE_CONFUSABLE_LIMIT_EXHAUSTED;
        return result;
    }
    if ((binding_count != 0u && bindings == NULL) ||
        (diagnostic_capacity != 0u && diagnostics == NULL)) {
        result.status = KOFUN_VISIBLE_CONFUSABLE_INVALID_INPUT;
        return result;
    }
    if (binding_count != 0u) {
        work = calloc(binding_count, sizeof(*work));
        representatives = malloc(binding_count * sizeof(*representatives));
        if (work == NULL || representatives == NULL) {
            result.status = KOFUN_VISIBLE_CONFUSABLE_RESOURCE_FAILURE;
            goto done;
        }
    }
    for (index = 0u; index < binding_count; index += 1u) {
        if (!valid_binding(&bindings[index])) {
            result.status = KOFUN_VISIBLE_CONFUSABLE_INVALID_INPUT;
            goto done;
        }
        work[index].input_index = index;
        if (!kofun_unicode_confusable_skeleton(
                bindings[index].effective_spelling,
                bindings[index].effective_spelling_length,
                &work[index].skeleton,
                &work[index].skeleton_length)) {
            result.status = KOFUN_VISIBLE_CONFUSABLE_RESOURCE_FAILURE;
            goto done;
        }
        result.work += 1u;
    }
    visible_comparison_bindings = bindings;
    visible_comparison_work = work;
    if (binding_count > 1u) {
        qsort(work, binding_count, sizeof(*work), compare_work_bindings);
    }
    compute_cache_key(work, binding_count, result.cache_key);
    index = 0u;
    while (index < binding_count) {
        size_t group_end = index + 1u;
        size_t unique_count = 1u;
        size_t cursor;
        size_t primary = index;
        size_t representative_count = 0u;
        while (group_end < binding_count &&
               same_collision_key(&work[index], &work[group_end])) {
            if (!same_spelling(
                    &bindings[work[group_end - 1u].input_index],
                    &bindings[work[group_end].input_index])) {
                unique_count += 1u;
            }
            group_end += 1u;
            result.work += 1u;
        }
        if (unique_count < 2u) {
            index = group_end;
            continue;
        }
        for (cursor = index + 1u; cursor < group_end; cursor += 1u) {
            if (binding_is_primary(
                    &bindings[work[cursor].input_index],
                    &bindings[work[primary].input_index])) {
                primary = cursor;
            }
        }
        for (cursor = index; cursor < group_end; cursor += 1u) {
            if (cursor != index && same_spelling(
                    &bindings[work[cursor - 1u].input_index],
                    &bindings[work[cursor].input_index])) {
                continue;
            }
            if (!same_spelling(&bindings[work[cursor].input_index],
                    &bindings[work[primary].input_index])) {
                representatives[representative_count++] = cursor;
            }
        }
        qsort(representatives, representative_count,
            sizeof(*representatives), compare_representatives);
        if (result.diagnostic_count < diagnostic_capacity) {
            KofunVisibleConfusableDiagnostic *diagnostic =
                &diagnostics[result.diagnostic_count];
            size_t emitted = representative_count < KOFUN_VISIBLE_RELATED_LIMIT
                ? representative_count : KOFUN_VISIBLE_RELATED_LIMIT;
            memset(diagnostic, 0, sizeof(*diagnostic));
            diagnostic->primary_binding = work[primary].input_index;
            for (cursor = 0u; cursor < emitted; cursor += 1u) {
                diagnostic->related_bindings[cursor] =
                    work[representatives[cursor]].input_index;
            }
            diagnostic->related_count = emitted;
            diagnostic->related_omitted = representative_count - emitted;
        }
        result.diagnostic_count += 1u;
        index = group_end;
    }
    if (result.diagnostic_count == 0u) {
        result.status = KOFUN_VISIBLE_CONFUSABLE_OK;
    } else if (result.diagnostic_count > diagnostic_capacity) {
        result.status = KOFUN_VISIBLE_CONFUSABLE_OUTPUT_TOO_SMALL;
    } else {
        result.status = KOFUN_VISIBLE_CONFUSABLE_COLLISION;
    }
done:
    if (work != NULL) {
        for (index = 0u; index < binding_count; index += 1u) {
            free(work[index].skeleton);
        }
    }
    free(representatives);
    free(work);
    visible_comparison_bindings = NULL;
    visible_comparison_work = NULL;
    return result;
}

const char *kofun_visible_confusable_status_name(
    KofunVisibleConfusableStatus status
) {
    switch (status) {
        case KOFUN_VISIBLE_CONFUSABLE_OK: return "ok";
        case KOFUN_VISIBLE_CONFUSABLE_COLLISION: return "EUNICODE008";
        case KOFUN_VISIBLE_CONFUSABLE_INVALID_INPUT: return "invalid-input";
        case KOFUN_VISIBLE_CONFUSABLE_LIMIT_EXHAUSTED: return "limit-exhausted";
        case KOFUN_VISIBLE_CONFUSABLE_RESOURCE_FAILURE: return "resource-failure";
        case KOFUN_VISIBLE_CONFUSABLE_OUTPUT_TOO_SMALL: return "output-too-small";
    }
    return "unknown";
}
