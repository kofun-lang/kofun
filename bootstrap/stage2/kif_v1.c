#define _POSIX_C_SOURCE 200809L

#include "kif_v1.h"
#include "sha256.h"
#include "../../unicode/kofun_unicode.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define KIF_MAJOR 2u
#define KIF_MINOR 0u
#define KIF_HEADER_BYTES 12u
#define KIF_SCHEMA "kofun.interface/v2"
#define KIF_COMPATIBILITY "semantic-compatibility-2"

enum {
    TAG_SCHEMA = 0x8001u,
    TAG_EDITION = 0x8002u,
    TAG_COMPATIBILITY = 0x8003u,
    TAG_PACKAGE_ID = 0x8004u,
    TAG_MODULE_ID = 0x8005u,
    TAG_PUBLIC_FACTS = 0x8006u,
    TAG_INTERNAL_FACTS = 0x8007u,
    TAG_PUBLIC_DIGEST = 0x8008u,
    TAG_INTERNAL_DIGEST = 0x8009u,
    /* RFC-0012. Distinct from FACT_TAG_TARGET_MODULE below, which is the same
     * number in the nested fact-record namespace. Not a collision: these two
     * enums index different records and are never scanned together. */
    TAG_MODULE_TRUST = 0x800au
};

#define ENVELOPE_TAG_COUNT ((size_t)(TAG_MODULE_TRUST - TAG_SCHEMA + 1u))

#define TRUST_ORDINARY_BYTES "ordinary"
#define TRUST_RAW_FOREIGN_BYTES "raw-foreign"

enum {
    FACT_TAG_NAMESPACE_ID = 0x8001u,
    FACT_TAG_SYMBOL_ID = 0x8002u,
    FACT_TAG_KIND = 0x8003u,
    FACT_TAG_NAME = 0x8004u,
    FACT_TAG_VISIBILITY = 0x8005u,
    FACT_TAG_SIGNATURE = 0x8006u,
    FACT_TAG_OWNER = 0x8007u,
    FACT_TAG_ORDINAL = 0x8008u,
    FACT_TAG_SOURCE_IMPORT = 0x8009u,
    FACT_TAG_TARGET_MODULE = 0x800au,
    FACT_TAG_TARGET_SYMBOL = 0x800bu,
    FACT_TAG_EXPORT_CHAIN = 0x800cu,
    FACT_TAG_EXPORT_TARGET_KIND = 0x800du,
    FACT_TAG_EXPORT_TARGET_OWNER = 0x800eu,
    FACT_TAG_EXPORT_TARGET_ORDINAL = 0x800fu,
    FACT_TAG_EXPORT_TARGET_MODULE_PATH = 0x8010u
};

enum {
    SIGNATURE_FUNCTION = 1u,
    SIGNATURE_ADT = 2u,
    SIGNATURE_CONSTRUCTOR = 3u,
    SIGNATURE_EXPORT = 4u
};

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
    KofunKifStatus status;
} ByteBuffer;

typedef struct {
    const uint8_t *bytes;
    size_t length;
} ByteView;

typedef struct {
    uint16_t tag;
    ByteView value;
} ParsedField;

typedef struct {
    ByteBuffer record;
    const KofunKifFact *fact;
} EncodedFact;

typedef struct {
    const KofunKifFact *fact;
} FactReference;

static void store_u16be(uint8_t output[2], uint16_t value) {
    output[0] = (uint8_t)(value >> 8u);
    output[1] = (uint8_t)value;
}

static void store_u32be(uint8_t output[4], uint32_t value) {
    output[0] = (uint8_t)(value >> 24u);
    output[1] = (uint8_t)(value >> 16u);
    output[2] = (uint8_t)(value >> 8u);
    output[3] = (uint8_t)value;
}

static uint16_t load_u16be(const uint8_t bytes[2]) {
    return (uint16_t)(((uint16_t)bytes[0] << 8u) | bytes[1]);
}

static uint32_t load_u32be(const uint8_t bytes[4]) {
    return ((uint32_t)bytes[0] << 24u) |
        ((uint32_t)bytes[1] << 16u) |
        ((uint32_t)bytes[2] << 8u) |
        (uint32_t)bytes[3];
}

static bool checked_add(size_t left, size_t right, size_t *result) {
    if (right > SIZE_MAX - left) return false;
    *result = left + right;
    return true;
}

static bool buffer_reserve(ByteBuffer *buffer, size_t additional) {
    size_t required;
    size_t capacity;
    uint8_t *resized;
    if (buffer->status != KOFUN_KIF_OK) return false;
    if (!checked_add(buffer->length, additional, &required) ||
        required > KOFUN_KIF_MAX_ENVELOPE) {
        buffer->status = KOFUN_KIF_LIMIT_EXHAUSTED;
        return false;
    }
    if (required <= buffer->capacity) return true;
    capacity = buffer->capacity == 0u ? 256u : buffer->capacity;
    while (capacity < required) {
        if (capacity > KOFUN_KIF_MAX_ENVELOPE / 2u) {
            capacity = KOFUN_KIF_MAX_ENVELOPE;
            break;
        }
        capacity *= 2u;
    }
    resized = realloc(buffer->bytes, capacity);
    if (resized == NULL) {
        buffer->status = KOFUN_KIF_INTERNAL_INVARIANT;
        return false;
    }
    buffer->bytes = resized;
    buffer->capacity = capacity;
    return true;
}

static bool buffer_append(ByteBuffer *buffer, const void *bytes, size_t length) {
    if (!buffer_reserve(buffer, length)) return false;
    if (length != 0u) memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return true;
}

static bool buffer_u16(ByteBuffer *buffer, uint16_t value) {
    uint8_t bytes[2];
    store_u16be(bytes, value);
    return buffer_append(buffer, bytes, sizeof(bytes));
}

static bool buffer_u32(ByteBuffer *buffer, uint32_t value) {
    uint8_t bytes[4];
    store_u32be(bytes, value);
    return buffer_append(buffer, bytes, sizeof(bytes));
}

static bool buffer_field(
    ByteBuffer *buffer,
    uint16_t tag,
    const void *bytes,
    size_t length
) {
    if (length > UINT32_MAX) {
        buffer->status = KOFUN_KIF_LIMIT_EXHAUSTED;
        return false;
    }
    return buffer_u16(buffer, tag) && buffer_u32(buffer, (uint32_t)length) &&
        buffer_append(buffer, bytes, length);
}

static void buffer_destroy(ByteBuffer *buffer) {
    free(buffer->bytes);
    memset(buffer, 0, sizeof(*buffer));
}

static void hash_field(
    KofunSha256 *context,
    uint16_t tag,
    const uint8_t *value,
    size_t length
) {
    uint8_t u16[2];
    uint8_t u32[4];
    store_u16be(u16, tag);
    store_u32be(u32, (uint32_t)length);
    kofun_sha256_update(context, u16, sizeof(u16));
    kofun_sha256_update(context, u32, sizeof(u32));
    kofun_sha256_update(context, value, length);
}

static void framed_hash(
    const char *domain,
    const uint8_t *payload,
    size_t payload_length,
    uint8_t digest[KOFUN_KIF_ID_BYTES]
) {
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    uint8_t u16[2];
    uint8_t u32[4];
    size_t domain_length = strlen(domain);
    KofunSha256 context;
    store_u16be(u16, (uint16_t)domain_length);
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, domain_length);
    kofun_sha256_update(&context, u32, sizeof(u32));
    kofun_sha256_update(&context, payload, payload_length);
    kofun_sha256_finish(&context, digest);
}

static bool constant_time_equal(const uint8_t *left, const uint8_t *right, size_t length) {
    uint8_t difference = 0u;
    size_t index;
    for (index = 0u; index < length; index += 1u) difference |= left[index] ^ right[index];
    return difference == 0u;
}

static bool id_is_nonzero(const uint8_t id[KOFUN_KIF_ID_BYTES]) {
    uint8_t combined = 0u;
    size_t index;
    for (index = 0u; index < KOFUN_KIF_ID_BYTES; index += 1u) combined |= id[index];
    return combined != 0u;
}

static const uint8_t *parameter_type_symbol_id(
    const KofunKifFact *fact,
    size_t index
) {
    static const uint8_t builtin_int[KOFUN_KIF_ID_BYTES] = { 0 };
    if (fact->parameter_type_symbol_ids == NULL) return builtin_int;
    return fact->parameter_type_symbol_ids + index * KOFUN_KIF_ID_BYTES;
}

static const KofunKifParameterLabel *parameter_label(
    const KofunKifFact *fact,
    size_t index
) {
    static const KofunKifParameterLabel unlabelled = { NULL, 0u };
    if (fact->parameter_labels == NULL) return &unlabelled;
    return &fact->parameter_labels[index];
}

static KofunKifTypeTag type_tag_for_symbol_id(
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    return id_is_nonzero(symbol_id) ?
        KOFUN_KIF_TYPE_NOMINAL : KOFUN_KIF_TYPE_INT;
}

static bool ascii_identifier(const char *text, size_t length) {
    size_t index;
    if (text == NULL || length == 0u || length > KOFUN_KIF_MAX_NAME_BYTES) return false;
    for (index = 0u; index < length; index += 1u) {
        unsigned char byte = (unsigned char)text[index];
        bool letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
        bool digit = byte >= '0' && byte <= '9';
        if (index == 0u ? (!letter && byte != '_') : (!letter && !digit && byte != '_')) return false;
    }
    return true;
}

static bool canonical_identifier(const char *text, size_t length) {
    return text != NULL && length != 0u &&
        length <= KOFUN_KIF_MAX_NAME_BYTES &&
        kofun_unicode_identifier_is_canonical(
            (const uint8_t *)text,
            length
        );
}

static bool ascii_module_path(const char *text, size_t length) {
    size_t component_start = 0u;
    size_t index;
    if (text == NULL || length == 0u ||
        length > KOFUN_KIF_MAX_MODULE_PATH_BYTES ||
        text[length] != '\0' || strlen(text) != length) {
        return false;
    }
    for (index = 0u; index <= length; index += 1u) {
        if (index != length && text[index] != '.') continue;
        if (!ascii_identifier(text + component_start,
                index - component_start)) {
            return false;
        }
        component_start = index + 1u;
    }
    return true;
}

static bool normalized_edition(const char *edition) {
    size_t length;
    size_t index;
    if (edition == NULL) return false;
    length = strlen(edition);
    if (length == 0u || length > KOFUN_KIF_MAX_EDITION_BYTES) return false;
    for (index = 0u; index < length; index += 1u) {
        unsigned char byte = (unsigned char)edition[index];
        if (!((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
              byte == '.' || byte == '_' || byte == '-')) return false;
    }
    return true;
}

static const char *fact_kind_schema_name(KofunKifFactKind kind) {
    switch (kind) {
        case KOFUN_KIF_FACT_FUNCTION: return "function";
        case KOFUN_KIF_FACT_ADT: return "adt";
        case KOFUN_KIF_FACT_CONSTRUCTOR: return "constructor";
        case KOFUN_KIF_FACT_EXPORT: return "export";
    }
    return NULL;
}

static const char *export_target_kind_schema_name(KofunKifExportTargetKind kind) {
    switch (kind) {
        case KOFUN_KIF_EXPORT_TARGET_FUNCTION: return "function";
        case KOFUN_KIF_EXPORT_TARGET_ADT: return "adt";
        case KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR: return "constructor";
        case KOFUN_KIF_EXPORT_TARGET_MODULE: return "module";
    }
    return NULL;
}

static void compute_namespace_id(unsigned tag, const char *name, uint8_t digest[32]) {
    char payload[96];
    int length = snprintf(payload, sizeof(payload),
        "kofun.namespace-id/v1\ntag=%u\nname=%s\n", tag, name);
    if (length < 0 || (size_t)length >= sizeof(payload)) {
        memset(digest, 0, 32u);
        return;
    }
    framed_hash("kofun.id.namespace/v1", (const uint8_t *)payload, (size_t)length, digest);
}

static void compute_symbol_id_for_kind(
    const uint8_t module_id[32],
    const uint8_t namespace_id[32],
    const char *kind_name,
    const char *name,
    size_t name_length,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.symbol/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    size_t kind_length = kind_name == NULL ? 0u : strlen(kind_name);
    size_t payload_length = 88u + kind_length + name_length;
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)(sizeof(domain) - 1u));
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, sizeof(domain) - 1u);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)kind_name, kind_length);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name, name_length);
    kofun_sha256_finish(&context, digest);
}

static void compute_symbol_id(
    const uint8_t module_id[32],
    const uint8_t namespace_id[32],
    KofunKifFactKind kind,
    const char *name,
    size_t name_length,
    uint8_t digest[32]
) {
    compute_symbol_id_for_kind(module_id, namespace_id,
        fact_kind_schema_name(kind), name, name_length, digest);
}

static void compute_module_self_symbol_id(
    const uint8_t module_id[32],
    const uint8_t namespace_id[32],
    const char *declared_path,
    size_t declared_path_length,
    uint8_t digest[32]
) {
    compute_symbol_id_for_kind(module_id, namespace_id, "module",
        declared_path, declared_path_length, digest);
}

static void compute_export_binding_id(
    const KofunKifInterface *interface,
    const KofunKifFact *fact,
    uint8_t digest[32]
) {
    static const char domain[] = "kofun.id.export-binding/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    static const uint8_t visibility = 3u;
    size_t name_length = fact->name_length;
    size_t payload_length = 30u + 32u + 32u + name_length + 32u + 1u;
    uint8_t u16[2];
    uint8_t u32[4];
    KofunSha256 context;
    store_u16be(u16, (uint16_t)(sizeof(domain) - 1u));
    store_u32be(u32, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, u16, sizeof(u16));
    kofun_sha256_update(&context, (const uint8_t *)domain, sizeof(domain) - 1u);
    kofun_sha256_update(&context, u32, sizeof(u32));
    hash_field(&context, UINT16_C(0x8001), interface->module_id, 32u);
    hash_field(&context, UINT16_C(0x8002), fact->namespace_id, 32u);
    hash_field(&context, UINT16_C(0x8003),
        (const uint8_t *)fact->name, fact->name_length);
    hash_field(&context, UINT16_C(0x8004), fact->target_symbol_id, 32u);
    hash_field(&context, UINT16_C(0x8005), &visibility, 1u);
    kofun_sha256_finish(&context, digest);
}

KofunKifLimits kofun_kif_default_limits(void) {
    return (KofunKifLimits){
        .max_envelope_bytes = KOFUN_KIF_MAX_ENVELOPE,
        .max_record_fields = KOFUN_KIF_MAX_RECORD_FIELDS,
        .max_facts = KOFUN_KIF_MAX_FACTS,
        .max_depth = KOFUN_KIF_MAX_DEPTH,
        .max_field_bytes = KOFUN_KIF_MAX_FIELD_BYTES
    };
}

const char *kofun_kif_status_name(KofunKifStatus status) {
    switch (status) {
        case KOFUN_KIF_OK: return "ok";
        case KOFUN_KIF_UNSUPPORTED_SCHEMA: return "unsupported-schema";
        case KOFUN_KIF_CORRUPT: return "corrupt";
        case KOFUN_KIF_NONCANONICAL: return "noncanonical";
        case KOFUN_KIF_LIMIT_EXHAUSTED: return "limit-exhausted";
        case KOFUN_KIF_DIGEST_MISMATCH: return "digest-mismatch";
        case KOFUN_KIF_IO_FAILURE: return "io-commit-failure";
        case KOFUN_KIF_INTERNAL_INVARIANT: return "internal-invariant";
        case KOFUN_KIF_VISIBILITY_LEAK: return "visibility-leak";
    }
    return "internal-invariant";
}

static const char *status_message(KofunKifStatus status) {
    switch (status) {
        case KOFUN_KIF_OK: return "validated KIF v2";
        case KOFUN_KIF_UNSUPPORTED_SCHEMA: return "unsupported KIF schema; rebuild from source";
        case KOFUN_KIF_CORRUPT: return "corrupt KIF envelope; rebuild from source";
        case KOFUN_KIF_NONCANONICAL: return "noncanonical KIF facts; rebuild from source";
        case KOFUN_KIF_LIMIT_EXHAUSTED: return "KIF resource limit exhausted; rebuild with bounded input";
        case KOFUN_KIF_DIGEST_MISMATCH: return "KIF semantic digest mismatch; rebuild from source";
        case KOFUN_KIF_IO_FAILURE: return "KIF atomic commit failed";
        case KOFUN_KIF_INTERNAL_INVARIANT: return "KIF internal invariant failed";
        case KOFUN_KIF_VISIBILITY_LEAK: return "public KIF fact exposes a hidden semantic dependency";
    }
    return "KIF internal invariant failed";
}

static bool parameter_labels_are_canonical(const KofunKifFact *fact) {
    size_t index;
    for (index = 0u; index < fact->parameter_count; index += 1u) {
        const KofunKifParameterLabel *label = parameter_label(fact, index);
        if (label->bytes == NULL) {
            if (label->length != 0u) return false;
        } else if (!canonical_identifier(label->bytes, label->length)) {
            return false;
        }
    }
    return true;
}

static KofunKifStatus validate_fact(
    const KofunKifInterface *interface,
    const KofunKifFact *fact,
    KofunKifVisibility expected_visibility
) {
    uint8_t expected_namespace[32];
    uint8_t expected_symbol[32];
    uint8_t expected_target_symbol[32];
    unsigned namespace_tag;
    const char *namespace_name;
    if (fact == NULL || fact->visibility != expected_visibility ||
        !canonical_identifier(fact->name, fact->name_length) ||
        fact->name[fact->name_length] != '\0' ||
        strlen(fact->name) != fact->name_length ||
        fact_kind_schema_name(fact->kind) == NULL) return KOFUN_KIF_NONCANONICAL;
    if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        if (expected_visibility != KOFUN_KIF_VISIBILITY_PUBLIC ||
            export_target_kind_schema_name(fact->export_target_kind) == NULL ||
            !id_is_nonzero(fact->source_import_binding_id) ||
            !id_is_nonzero(fact->target_module_id) ||
            !id_is_nonzero(fact->target_symbol_id) ||
            fact->export_chain_count == 0u ||
            fact->export_chain_count > KOFUN_KIF_MAX_EXPORT_CHAIN ||
            fact->export_chain_ids == NULL) return KOFUN_KIF_NONCANONICAL;
        if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_ADT) {
            namespace_tag = 1u;
            namespace_name = "type";
        } else if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_MODULE) {
            namespace_tag = 2u;
            namespace_name = "module";
        } else {
            namespace_tag = 0u;
            namespace_name = "value";
        }
    } else if (fact->kind == KOFUN_KIF_FACT_ADT) {
        namespace_tag = 1u;
        namespace_name = "type";
    } else {
        namespace_tag = 0u;
        namespace_name = "value";
    }
    compute_namespace_id(namespace_tag, namespace_name, expected_namespace);
    if (!constant_time_equal(fact->namespace_id, expected_namespace, 32u)) {
        return KOFUN_KIF_NONCANONICAL;
    }
    if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        compute_export_binding_id(interface, fact, expected_symbol);
    } else {
        compute_symbol_id(interface->module_id, fact->namespace_id, fact->kind,
            fact->name, fact->name_length, expected_symbol);
    }
    if (!constant_time_equal(fact->symbol_id, expected_symbol, 32u)) {
        return KOFUN_KIF_NONCANONICAL;
    }
    if (fact->kind == KOFUN_KIF_FACT_EXPORT &&
        fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_MODULE) {
        if (!ascii_module_path(fact->export_target_module_path,
                fact->export_target_module_path_length)) {
            return KOFUN_KIF_NONCANONICAL;
        }
        compute_module_self_symbol_id(fact->target_module_id,
            fact->namespace_id, fact->export_target_module_path,
            fact->export_target_module_path_length, expected_target_symbol);
        if (!constant_time_equal(fact->target_symbol_id,
                expected_target_symbol, 32u)) {
            return KOFUN_KIF_NONCANONICAL;
        }
    } else if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        KofunKifFactKind target_kind =
            fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION
                ? KOFUN_KIF_FACT_FUNCTION
                : fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_ADT
                    ? KOFUN_KIF_FACT_ADT
                    : KOFUN_KIF_FACT_CONSTRUCTOR;
        if (fact->export_target_module_path != NULL ||
            fact->export_target_module_path_length != 0u) {
            return KOFUN_KIF_NONCANONICAL;
        }
        compute_symbol_id(fact->target_module_id, fact->namespace_id,
            target_kind, fact->name, fact->name_length,
            expected_target_symbol);
        if (!constant_time_equal(fact->target_symbol_id,
                expected_target_symbol, 32u)) {
            return KOFUN_KIF_NONCANONICAL;
        }
    }
    switch (fact->kind) {
        case KOFUN_KIF_FACT_FUNCTION:
            if (fact->parameter_count > 256u ||
                !parameter_labels_are_canonical(fact) ||
                (fact->result_type != KOFUN_KIF_TYPE_INT &&
                 fact->result_type != KOFUN_KIF_TYPE_NOMINAL) ||
                (fact->result_type == KOFUN_KIF_TYPE_INT ?
                    id_is_nonzero(fact->result_type_symbol_id) :
                    !id_is_nonzero(fact->result_type_symbol_id)) ||
                fact->constructor_payload_count != 0u ||
                id_is_nonzero(fact->constructor_payload_type_symbol_id)) {
                return KOFUN_KIF_NONCANONICAL;
            }
            break;
        case KOFUN_KIF_FACT_ADT:
            if (fact->parameter_count != 0u || fact->constructor_payload_count != 0u ||
                fact->result_type != 0 ||
                fact->parameter_type_symbol_ids != NULL ||
                fact->parameter_labels != NULL ||
                id_is_nonzero(fact->result_type_symbol_id) ||
                id_is_nonzero(fact->constructor_payload_type_symbol_id)) {
                return KOFUN_KIF_NONCANONICAL;
            }
            break;
        case KOFUN_KIF_FACT_CONSTRUCTOR:
            if (fact->parameter_count != 0u || fact->result_type != 0 ||
                fact->parameter_type_symbol_ids != NULL ||
                fact->parameter_labels != NULL ||
                id_is_nonzero(fact->result_type_symbol_id) ||
                fact->constructor_payload_count > 1u ||
                (fact->constructor_payload_count == 0u &&
                 id_is_nonzero(fact->constructor_payload_type_symbol_id)) ||
                !id_is_nonzero(fact->owner_symbol_id)) {
                return KOFUN_KIF_NONCANONICAL;
            }
            break;
        case KOFUN_KIF_FACT_EXPORT:
            if (!constant_time_equal(fact->export_chain_ids, fact->symbol_id, 32u) ||
                (fact->export_target_kind != KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR &&
                 fact->constructor_payload_count != 0u)) {
                return KOFUN_KIF_NONCANONICAL;
            }
            if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION) {
                if (fact->parameter_count > 256u ||
                    !parameter_labels_are_canonical(fact) ||
                    fact->result_type != KOFUN_KIF_TYPE_INT ||
                    id_is_nonzero(fact->result_type_symbol_id)) {
                    return KOFUN_KIF_NONCANONICAL;
                }
                {
                    size_t parameter_index;
                    for (parameter_index = 0u;
                         parameter_index < fact->parameter_count;
                         parameter_index += 1u) {
                        if (id_is_nonzero(parameter_type_symbol_id(
                                fact, parameter_index))) {
                            return KOFUN_KIF_NONCANONICAL;
                        }
                    }
                }
            } else if (fact->parameter_count != 0u || fact->result_type != 0 ||
                       fact->parameter_labels != NULL) {
                return KOFUN_KIF_NONCANONICAL;
            }
            if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
                if (fact->constructor_payload_count > 1u ||
                    id_is_nonzero(fact->constructor_payload_type_symbol_id) ||
                    !id_is_nonzero(fact->export_target_owner_symbol_id)) {
                    return KOFUN_KIF_NONCANONICAL;
                }
            } else if (id_is_nonzero(fact->constructor_payload_type_symbol_id) ||
                id_is_nonzero(fact->export_target_owner_symbol_id) ||
                fact->export_target_constructor_ordinal != 0u) {
                return KOFUN_KIF_NONCANONICAL;
            }
            {
                size_t chain_index;
                for (chain_index = 0u;
                     chain_index < fact->export_chain_count;
                     chain_index += 1u) {
                    size_t earlier;
                    if (!id_is_nonzero(fact->export_chain_ids +
                            chain_index * 32u)) {
                        return KOFUN_KIF_NONCANONICAL;
                    }
                    for (earlier = 0u; earlier < chain_index;
                         earlier += 1u) {
                        if (constant_time_equal(
                                fact->export_chain_ids +
                                    earlier * KOFUN_KIF_ID_BYTES,
                                fact->export_chain_ids +
                                    chain_index * KOFUN_KIF_ID_BYTES,
                                KOFUN_KIF_ID_BYTES)) {
                            return KOFUN_KIF_NONCANONICAL;
                        }
                    }
                }
            }
            break;
    }
    return KOFUN_KIF_OK;
}

static int compare_fact_symbol(const void *left, const void *right) {
    const FactReference *a = left;
    const FactReference *b = right;
    return memcmp(a->fact->symbol_id, b->fact->symbol_id, KOFUN_KIF_ID_BYTES);
}

static int compare_fact_namespace_name(const void *left, const void *right) {
    const FactReference *a = left;
    const FactReference *b = right;
    size_t common;
    int result = memcmp(a->fact->namespace_id, b->fact->namespace_id,
        KOFUN_KIF_ID_BYTES);
    if (result != 0) return result;
    common = a->fact->name_length < b->fact->name_length
        ? a->fact->name_length : b->fact->name_length;
    result = memcmp(a->fact->name, b->fact->name, common);
    if (result != 0) return result;
    if (a->fact->name_length != b->fact->name_length) {
        return a->fact->name_length < b->fact->name_length ? -1 : 1;
    }
    return memcmp(a->fact->symbol_id, b->fact->symbol_id,
        KOFUN_KIF_ID_BYTES);
}

static int compare_constructor_owner_ordinal(const void *left, const void *right) {
    const FactReference *a = left;
    const FactReference *b = right;
    int result = memcmp(a->fact->owner_symbol_id, b->fact->owner_symbol_id,
        KOFUN_KIF_ID_BYTES);
    if (result != 0) return result;
    if (a->fact->constructor_ordinal != b->fact->constructor_ordinal) {
        return a->fact->constructor_ordinal < b->fact->constructor_ordinal ? -1 : 1;
    }
    return memcmp(a->fact->symbol_id, b->fact->symbol_id, KOFUN_KIF_ID_BYTES);
}

static const KofunKifFact *find_sorted_fact(
    const FactReference *facts,
    size_t count,
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    size_t low = 0u;
    size_t high = count;
    while (low < high) {
        size_t middle = low + (high - low) / 2u;
        int comparison = memcmp(facts[middle].fact->symbol_id, symbol_id,
            KOFUN_KIF_ID_BYTES);
        if (comparison < 0) low = middle + 1u;
        else high = middle;
    }
    if (low == count || memcmp(facts[low].fact->symbol_id, symbol_id,
            KOFUN_KIF_ID_BYTES) != 0) return NULL;
    return facts[low].fact;
}

static bool type_reference_is_visible(
    const FactReference *facts,
    size_t count,
    const KofunKifFact *consumer,
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    const KofunKifFact *type;
    if (!id_is_nonzero(symbol_id)) return true;
    type = find_sorted_fact(facts, count, symbol_id);
    if (type == NULL || type->kind != KOFUN_KIF_FACT_ADT) return false;
    return consumer->visibility == KOFUN_KIF_VISIBILITY_INTERNAL ||
        type->visibility == KOFUN_KIF_VISIBILITY_PUBLIC;
}

static bool fact_type_references_are_visible(
    const FactReference *facts,
    size_t count,
    const KofunKifFact *fact
) {
    size_t index;
    if (fact->kind == KOFUN_KIF_FACT_FUNCTION) {
        for (index = 0u; index < fact->parameter_count; index += 1u) {
            if (!type_reference_is_visible(
                    facts, count, fact,
                    parameter_type_symbol_id(fact, index))) {
                return false;
            }
        }
        return type_reference_is_visible(
            facts, count, fact, fact->result_type_symbol_id);
    }
    if (fact->kind == KOFUN_KIF_FACT_CONSTRUCTOR &&
        fact->constructor_payload_count == 1u) {
        return type_reference_is_visible(
            facts, count, fact,
            fact->constructor_payload_type_symbol_id);
    }
    return true;
}

/* The closed v1 value set. Returns NULL for anything else, including a zeroed
 * struct field, so an unset trust class cannot be written. */
static const char *trust_bytes(KofunKifModuleTrust trust, size_t *length) {
    if (trust == KOFUN_KIF_TRUST_ORDINARY) {
        *length = sizeof(TRUST_ORDINARY_BYTES) - 1u;
        return TRUST_ORDINARY_BYTES;
    }
    if (trust == KOFUN_KIF_TRUST_RAW_FOREIGN) {
        *length = sizeof(TRUST_RAW_FOREIGN_BYTES) - 1u;
        return TRUST_RAW_FOREIGN_BYTES;
    }
    *length = 0u;
    return NULL;
}

/* Exact-bytes match against the closed set. A zero-length payload is rejected
 * here rather than mapped to `ordinary`: RFC-0012/A01 rejected option B
 * precisely because empty and absent are too easy to conflate. */
static bool trust_from_bytes(ByteView value, KofunKifModuleTrust *trust) {
    if (value.length == sizeof(TRUST_ORDINARY_BYTES) - 1u &&
        memcmp(value.bytes, TRUST_ORDINARY_BYTES, value.length) == 0) {
        *trust = KOFUN_KIF_TRUST_ORDINARY;
        return true;
    }
    if (value.length == sizeof(TRUST_RAW_FOREIGN_BYTES) - 1u &&
        memcmp(value.bytes, TRUST_RAW_FOREIGN_BYTES, value.length) == 0) {
        *trust = KOFUN_KIF_TRUST_RAW_FOREIGN;
        return true;
    }
    return false;
}

static KofunKifStatus validate_interface(const KofunKifInterface *interface) {
    size_t total;
    size_t index;
    size_t constructor_count = 0u;
    FactReference *facts = NULL;
    FactReference *constructors = NULL;
    KofunKifStatus status = KOFUN_KIF_OK;
    size_t trust_length;
    if (interface == NULL || !id_is_nonzero(interface->package_id) ||
        !id_is_nonzero(interface->module_id) || !normalized_edition(interface->edition) ||
        trust_bytes(interface->module_trust, &trust_length) == NULL ||
        !checked_add(interface->public_fact_count, interface->internal_fact_count, &total) ||
        (interface->public_fact_count != 0u && interface->public_facts == NULL) ||
        (interface->internal_fact_count != 0u && interface->internal_facts == NULL)) {
        return KOFUN_KIF_NONCANONICAL;
    }
    if (total > KOFUN_KIF_MAX_FACTS) return KOFUN_KIF_LIMIT_EXHAUSTED;
    if (total == 0u) return KOFUN_KIF_OK;
    facts = calloc(total, sizeof(*facts));
    constructors = calloc(total, sizeof(*constructors));
    if (facts == NULL || constructors == NULL) {
        status = KOFUN_KIF_INTERNAL_INVARIANT;
        goto done;
    }
    for (index = 0u; index < interface->public_fact_count; index += 1u) {
        status = validate_fact(interface, &interface->public_facts[index],
            KOFUN_KIF_VISIBILITY_PUBLIC);
        if (status != KOFUN_KIF_OK) goto done;
        facts[index].fact = &interface->public_facts[index];
    }
    for (index = 0u; index < interface->internal_fact_count; index += 1u) {
        status = validate_fact(interface, &interface->internal_facts[index],
            KOFUN_KIF_VISIBILITY_INTERNAL);
        if (status != KOFUN_KIF_OK) goto done;
        facts[interface->public_fact_count + index].fact = &interface->internal_facts[index];
    }
    if (total > 1u) qsort(facts, total, sizeof(*facts), compare_fact_symbol);
    for (index = 0u; index < total; index += 1u) {
        const KofunKifFact *constructor = facts[index].fact;
        const KofunKifFact *owner;
        if (index != 0u && memcmp(facts[index - 1u].fact->symbol_id,
                constructor->symbol_id, KOFUN_KIF_ID_BYTES) == 0) {
            status = KOFUN_KIF_NONCANONICAL;
            goto done;
        }
        if (!fact_type_references_are_visible(
                facts, total, constructor)) {
            status = KOFUN_KIF_VISIBILITY_LEAK;
            goto done;
        }
        if (constructor->kind != KOFUN_KIF_FACT_CONSTRUCTOR) continue;
        owner = find_sorted_fact(facts, total, constructor->owner_symbol_id);
        if (owner == NULL || owner->kind != KOFUN_KIF_FACT_ADT ||
            owner->visibility != constructor->visibility) {
            status = KOFUN_KIF_VISIBILITY_LEAK;
            goto done;
        }
        constructors[constructor_count++].fact = constructor;
    }
    if (constructor_count > 1u) {
        qsort(constructors, constructor_count, sizeof(*constructors),
            compare_constructor_owner_ordinal);
    }
    for (index = 0u; index < constructor_count; index += 1u) {
        uint32_t expected = 0u;
        if (index != 0u && memcmp(constructors[index - 1u].fact->owner_symbol_id,
                constructors[index].fact->owner_symbol_id, KOFUN_KIF_ID_BYTES) == 0) {
            expected = constructors[index - 1u].fact->constructor_ordinal + 1u;
        }
        if (constructors[index].fact->constructor_ordinal != expected) {
            status = KOFUN_KIF_NONCANONICAL;
            goto done;
        }
    }
    if (total > 1u) {
        qsort(facts, total, sizeof(*facts), compare_fact_namespace_name);
    }
    for (index = 1u; index < total; index += 1u) {
        if (memcmp(facts[index - 1u].fact->namespace_id,
                facts[index].fact->namespace_id,
                KOFUN_KIF_ID_BYTES) == 0 &&
            facts[index - 1u].fact->name_length ==
                facts[index].fact->name_length &&
            memcmp(facts[index - 1u].fact->name,
                facts[index].fact->name,
                facts[index].fact->name_length) == 0) {
            status = KOFUN_KIF_NONCANONICAL;
            goto done;
        }
    }
done:
    free(facts);
    free(constructors);
    return status;
}

static bool encode_type_reference(
    ByteBuffer *signature,
    const uint8_t symbol_id[KOFUN_KIF_ID_BYTES]
) {
    uint8_t tag = (uint8_t)type_tag_for_symbol_id(symbol_id);
    if (!buffer_append(signature, &tag, 1u)) return false;
    return tag != KOFUN_KIF_TYPE_NOMINAL ||
        buffer_append(signature, symbol_id, KOFUN_KIF_ID_BYTES);
}

static bool encode_parameter_label(
    ByteBuffer *signature,
    const KofunKifParameterLabel *label
) {
    uint8_t marker = label->bytes == NULL ? 0u : 1u;
    if (!buffer_append(signature, &marker, 1u)) return false;
    return marker == 0u ||
        (buffer_u16(signature, label->length) &&
         buffer_append(signature, label->bytes, label->length));
}

static bool encode_signature(const KofunKifFact *fact, ByteBuffer *signature) {
    uint8_t tag;
    size_t index;
    switch (fact->kind) {
        case KOFUN_KIF_FACT_FUNCTION:
            tag = SIGNATURE_FUNCTION;
            if (!buffer_append(signature, &tag, 1u) ||
                !buffer_u16(signature, fact->parameter_count)) return false;
            for (index = 0u; index < fact->parameter_count; index += 1u) {
                if (!encode_type_reference(
                        signature,
                        parameter_type_symbol_id(fact, index)) ||
                    !encode_parameter_label(
                        signature,
                        parameter_label(fact, index))) {
                    return false;
                }
            }
            return encode_type_reference(
                signature, fact->result_type_symbol_id);
        case KOFUN_KIF_FACT_ADT:
            tag = SIGNATURE_ADT;
            return buffer_append(signature, &tag, 1u) && buffer_u16(signature, 0u);
        case KOFUN_KIF_FACT_CONSTRUCTOR:
            tag = SIGNATURE_CONSTRUCTOR;
            if (!buffer_append(signature, &tag, 1u) ||
                !buffer_append(signature, &fact->constructor_payload_count, 1u)) return false;
            if (fact->constructor_payload_count == 1u) {
                return encode_type_reference(
                    signature,
                    fact->constructor_payload_type_symbol_id);
            }
            return true;
        case KOFUN_KIF_FACT_EXPORT:
            tag = SIGNATURE_EXPORT;
            if (!buffer_append(signature, &tag, 1u)) return false;
            tag = (uint8_t)fact->export_target_kind;
            if (!buffer_append(signature, &tag, 1u)) return false;
            if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION) {
                if (!buffer_u16(signature, fact->parameter_count)) return false;
                tag = KOFUN_KIF_TYPE_INT;
                for (index = 0u; index < fact->parameter_count; index += 1u) {
                    if (!buffer_append(signature, &tag, 1u) ||
                        !encode_parameter_label(
                            signature,
                            parameter_label(fact, index))) return false;
                }
                return buffer_append(signature, &tag, 1u);
            }
            if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
                if (!buffer_append(signature,
                        &fact->constructor_payload_count, 1u)) return false;
                if (fact->constructor_payload_count == 1u) {
                    tag = KOFUN_KIF_TYPE_INT;
                    return buffer_append(signature, &tag, 1u);
                }
            }
            return true;
    }
    signature->status = KOFUN_KIF_INTERNAL_INVARIANT;
    return false;
}

static KofunKifStatus encode_fact(const KofunKifFact *fact, ByteBuffer *record) {
    ByteBuffer signature = { 0 };
    uint8_t kind = (uint8_t)fact->kind;
    uint8_t visibility = (uint8_t)fact->visibility;
    uint8_t ordinal[4];
    if (!encode_signature(fact, &signature) ||
        !buffer_field(record, FACT_TAG_NAMESPACE_ID, fact->namespace_id, 32u) ||
        !buffer_field(record, FACT_TAG_SYMBOL_ID, fact->symbol_id, 32u) ||
        !buffer_field(record, FACT_TAG_KIND, &kind, 1u) ||
        !buffer_field(record, FACT_TAG_NAME, fact->name, fact->name_length) ||
        !buffer_field(record, FACT_TAG_VISIBILITY, &visibility, 1u) ||
        !buffer_field(record, FACT_TAG_SIGNATURE, signature.bytes, signature.length)) {
        KofunKifStatus status = signature.status != KOFUN_KIF_OK
            ? signature.status : record->status;
        buffer_destroy(&signature);
        return status;
    }
    if (fact->kind == KOFUN_KIF_FACT_CONSTRUCTOR) {
        store_u32be(ordinal, fact->constructor_ordinal);
        if (!buffer_field(record, FACT_TAG_OWNER, fact->owner_symbol_id, 32u) ||
            !buffer_field(record, FACT_TAG_ORDINAL, ordinal, sizeof(ordinal))) {
            KofunKifStatus status = record->status;
            buffer_destroy(&signature);
            return status;
        }
    } else if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        ByteBuffer chain = { 0 };
        uint8_t target_kind = (uint8_t)fact->export_target_kind;
        size_t chain_bytes;
        if (fact->export_chain_count > (SIZE_MAX - 4u) / 32u) {
            buffer_destroy(&signature);
            return KOFUN_KIF_LIMIT_EXHAUSTED;
        }
        chain_bytes = fact->export_chain_count * 32u;
        if (!buffer_u32(&chain, (uint32_t)fact->export_chain_count) ||
            !buffer_append(&chain, fact->export_chain_ids, chain_bytes) ||
            !buffer_field(record, FACT_TAG_SOURCE_IMPORT,
                fact->source_import_binding_id, 32u) ||
            !buffer_field(record, FACT_TAG_TARGET_MODULE,
                fact->target_module_id, 32u) ||
            !buffer_field(record, FACT_TAG_TARGET_SYMBOL,
                fact->target_symbol_id, 32u) ||
            !buffer_field(record, FACT_TAG_EXPORT_CHAIN,
                chain.bytes, chain.length) ||
            !buffer_field(record, FACT_TAG_EXPORT_TARGET_KIND,
                &target_kind, 1u)) {
            KofunKifStatus status = chain.status != KOFUN_KIF_OK
                ? chain.status : record->status;
            buffer_destroy(&chain);
            buffer_destroy(&signature);
            return status;
        }
        if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
            uint8_t target_ordinal[4];
            store_u32be(target_ordinal,
                fact->export_target_constructor_ordinal);
            if (!buffer_field(record, FACT_TAG_EXPORT_TARGET_OWNER,
                    fact->export_target_owner_symbol_id, 32u) ||
                !buffer_field(record, FACT_TAG_EXPORT_TARGET_ORDINAL,
                    target_ordinal, sizeof(target_ordinal))) {
                KofunKifStatus status = record->status;
                buffer_destroy(&chain);
                buffer_destroy(&signature);
                return status;
            }
        } else if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_MODULE &&
            !buffer_field(record, FACT_TAG_EXPORT_TARGET_MODULE_PATH,
                fact->export_target_module_path,
                fact->export_target_module_path_length)) {
            KofunKifStatus status = record->status;
            buffer_destroy(&chain);
            buffer_destroy(&signature);
            return status;
        }
        buffer_destroy(&chain);
    }
    buffer_destroy(&signature);
    return KOFUN_KIF_OK;
}

static int compare_encoded_facts(const void *left, const void *right) {
    const EncodedFact *a = left;
    const EncodedFact *b = right;
    int result = memcmp(a->fact->symbol_id, b->fact->symbol_id, 32u);
    size_t common;
    if (result != 0) return result;
    common = a->record.length < b->record.length ? a->record.length : b->record.length;
    result = memcmp(a->record.bytes, b->record.bytes, common);
    if (result != 0) return result;
    if (a->record.length != b->record.length) return a->record.length < b->record.length ? -1 : 1;
    return 0;
}

static KofunKifStatus encode_vector(
    const KofunKifFact *facts,
    size_t count,
    ByteBuffer *vector
) {
    EncodedFact *encoded = NULL;
    size_t index;
    KofunKifStatus status = KOFUN_KIF_OK;
    if (count > UINT32_MAX) return KOFUN_KIF_LIMIT_EXHAUSTED;
    if (count != 0u) {
        encoded = calloc(count, sizeof(*encoded));
        if (encoded == NULL) return KOFUN_KIF_INTERNAL_INVARIANT;
    }
    for (index = 0u; index < count; index += 1u) {
        encoded[index].fact = &facts[index];
        status = encode_fact(&facts[index], &encoded[index].record);
        if (status != KOFUN_KIF_OK) goto done;
    }
    if (count > 1u) qsort(encoded, count, sizeof(*encoded), compare_encoded_facts);
    if (!buffer_u32(vector, (uint32_t)count)) {
        status = vector->status;
        goto done;
    }
    for (index = 0u; index < count; index += 1u) {
        if (encoded[index].record.length > UINT32_MAX ||
            !buffer_u32(vector, (uint32_t)encoded[index].record.length) ||
            !buffer_append(vector, encoded[index].record.bytes, encoded[index].record.length)) {
            status = vector->status;
            goto done;
        }
    }
done:
    for (index = 0u; index < count; index += 1u) buffer_destroy(&encoded[index].record);
    free(encoded);
    return status;
}

/* `base_view` is the 0x8001-0x8006 prefix the envelope payload also starts
 * with. The two digest views are built from it rather than from each other,
 * because the trust field has to land last in both — the payload writes it
 * after the digests, where strictly-increasing tags require it, so a view that
 * simply prefixed the payload could not contain it. */
static KofunKifStatus build_digest_views(
    const KofunKifInterface *interface,
    const ByteBuffer *public_vector,
    const ByteBuffer *internal_vector,
    ByteBuffer *base_view,
    ByteBuffer *public_view,
    ByteBuffer *internal_view
) {
    const char *edition = interface->edition;
    size_t trust_length = 0u;
    const char *trust = trust_bytes(interface->module_trust, &trust_length);
    if (trust == NULL) return KOFUN_KIF_NONCANONICAL;
    if (!buffer_field(base_view, TAG_SCHEMA, KIF_SCHEMA, sizeof(KIF_SCHEMA) - 1u) ||
        !buffer_field(base_view, TAG_EDITION, edition, strlen(edition)) ||
        !buffer_field(base_view, TAG_COMPATIBILITY, KIF_COMPATIBILITY,
            sizeof(KIF_COMPATIBILITY) - 1u) ||
        !buffer_field(base_view, TAG_PACKAGE_ID, interface->package_id, 32u) ||
        !buffer_field(base_view, TAG_MODULE_ID, interface->module_id, 32u) ||
        !buffer_field(base_view, TAG_PUBLIC_FACTS, public_vector->bytes, public_vector->length)) {
        return base_view->status;
    }
    if (!buffer_append(public_view, base_view->bytes, base_view->length) ||
        !buffer_field(public_view, TAG_MODULE_TRUST, trust, trust_length)) {
        return public_view->status;
    }
    if (!buffer_append(internal_view, base_view->bytes, base_view->length) ||
        !buffer_field(internal_view, TAG_INTERNAL_FACTS,
            internal_vector->bytes, internal_vector->length) ||
        !buffer_field(internal_view, TAG_MODULE_TRUST, trust, trust_length)) {
        return internal_view->status;
    }
    return KOFUN_KIF_OK;
}

static KofunKifStatus encode_interface(
    const KofunKifInterface *interface,
    ByteBuffer *envelope,
    uint8_t public_digest[32],
    uint8_t internal_digest[32]
) {
    ByteBuffer public_vector = { 0 };
    ByteBuffer internal_vector = { 0 };
    ByteBuffer base_view = { 0 };
    ByteBuffer public_view = { 0 };
    ByteBuffer internal_view = { 0 };
    ByteBuffer payload = { 0 };
    KofunKifStatus status = validate_interface(interface);
    uint8_t version[4];
    uint8_t payload_length[4];
    size_t trust_length = 0u;
    const char *trust = NULL;
    static const uint8_t magic[4] = { 'K', 'I', 'F', 0 };
    if (status != KOFUN_KIF_OK) return status;
    trust = trust_bytes(interface->module_trust, &trust_length);
    if (trust == NULL) return KOFUN_KIF_NONCANONICAL;
    status = encode_vector(interface->public_facts, interface->public_fact_count, &public_vector);
    if (status != KOFUN_KIF_OK) goto done;
    status = encode_vector(interface->internal_facts, interface->internal_fact_count, &internal_vector);
    if (status != KOFUN_KIF_OK) goto done;
    status = build_digest_views(interface, &public_vector, &internal_vector,
        &base_view, &public_view, &internal_view);
    if (status != KOFUN_KIF_OK) goto done;
    framed_hash("kofun.digest.public-semantic/v2", public_view.bytes,
        public_view.length, public_digest);
    framed_hash("kofun.digest.package-internal/v2", internal_view.bytes,
        internal_view.length, internal_digest);
    if (!buffer_append(&payload, base_view.bytes, base_view.length) ||
        !buffer_field(&payload, TAG_INTERNAL_FACTS, internal_vector.bytes, internal_vector.length) ||
        !buffer_field(&payload, TAG_PUBLIC_DIGEST, public_digest, 32u) ||
        !buffer_field(&payload, TAG_INTERNAL_DIGEST, internal_digest, 32u) ||
        !buffer_field(&payload, TAG_MODULE_TRUST, trust, trust_length)) {
        status = payload.status;
        goto done;
    }
    if (payload.length > UINT32_MAX || payload.length + KIF_HEADER_BYTES > KOFUN_KIF_MAX_ENVELOPE) {
        status = KOFUN_KIF_LIMIT_EXHAUSTED;
        goto done;
    }
    store_u16be(version, KIF_MAJOR);
    store_u16be(version + 2u, KIF_MINOR);
    store_u32be(payload_length, (uint32_t)payload.length);
    if (!buffer_append(envelope, magic, sizeof(magic)) ||
        !buffer_append(envelope, version, sizeof(version)) ||
        !buffer_append(envelope, payload_length, sizeof(payload_length)) ||
        !buffer_append(envelope, payload.bytes, payload.length)) status = envelope->status;
done:
    buffer_destroy(&public_vector);
    buffer_destroy(&internal_vector);
    buffer_destroy(&base_view);
    buffer_destroy(&public_view);
    buffer_destroy(&internal_view);
    buffer_destroy(&payload);
    return status;
}

static KifReadResult read_result(KofunKifStatus status, KofunKifInterface *interface) {
    return (KifReadResult){
        .status = status,
        .message = status_message(status),
        .rebuild_required = status != KOFUN_KIF_OK,
        .interface = status == KOFUN_KIF_OK ? interface : NULL
    };
}

static bool limits_are_valid(KofunKifLimits limits) {
    return limits.max_envelope_bytes >= KIF_HEADER_BYTES &&
        limits.max_envelope_bytes <= KOFUN_KIF_MAX_ENVELOPE &&
        limits.max_record_fields > 0u &&
        limits.max_record_fields <= KOFUN_KIF_MAX_RECORD_FIELDS &&
        limits.max_facts <= KOFUN_KIF_MAX_FACTS &&
        limits.max_depth >= 2u && limits.max_depth <= KOFUN_KIF_MAX_DEPTH &&
        limits.max_field_bytes > 0u && limits.max_field_bytes <= KOFUN_KIF_MAX_FIELD_BYTES;
}

static KofunKifStatus scan_fields(
    const uint8_t *bytes,
    size_t length,
    KofunKifLimits limits,
    uint16_t first_known_tag,
    size_t known_tag_count,
    bool bound_known_fields,
    ParsedField *fields
) {
    size_t cursor = 0u;
    size_t field_count = 0u;
    uint16_t previous = 0u;
    bool have_previous = false;
    memset(fields, 0, known_tag_count * sizeof(fields[0]));
    while (cursor < length) {
        uint16_t tag;
        uint32_t field_length;
        bool known;
        if (length - cursor < 6u) return KOFUN_KIF_CORRUPT;
        tag = load_u16be(bytes + cursor);
        field_length = load_u32be(bytes + cursor + 2u);
        cursor += 6u;
        if (have_previous && tag <= previous) return KOFUN_KIF_NONCANONICAL;
        previous = tag;
        have_previous = true;
        field_count += 1u;
        if (field_count > limits.max_record_fields) return KOFUN_KIF_LIMIT_EXHAUSTED;
        if ((size_t)field_length > length - cursor) return KOFUN_KIF_CORRUPT;
        known = tag >= first_known_tag &&
            (size_t)(tag - first_known_tag) < known_tag_count;
        if ((bound_known_fields || !known) &&
            (size_t)field_length > limits.max_field_bytes) {
            return KOFUN_KIF_LIMIT_EXHAUSTED;
        }
        if (!known) {
            if ((tag & UINT16_C(0x8000)) != 0u) return KOFUN_KIF_UNSUPPORTED_SCHEMA;
        } else {
            fields[tag - first_known_tag] = (ParsedField){
                .tag = tag,
                .value = { .bytes = bytes + cursor, .length = field_length }
            };
        }
        cursor += field_length;
    }
    if (cursor != length) return KOFUN_KIF_CORRUPT;
    return KOFUN_KIF_OK;
}

static KofunKifStatus parse_envelope_fields(
    const uint8_t *bytes,
    size_t length,
    KofunKifLimits limits,
    ParsedField fields[ENVELOPE_TAG_COUNT]
) {
    size_t cursor;
    KofunKifStatus status = scan_fields(bytes, length, limits, TAG_SCHEMA,
        ENVELOPE_TAG_COUNT, false, fields);
    if (status != KOFUN_KIF_OK) return status;
    /* Every envelope tag is required, so a zero tag here is the absent-field
     * refusal — including an artifact written before 0x800A existed. RFC-0012
     * is explicit that absence is not grandfathered. */
    for (cursor = 0u; cursor < ENVELOPE_TAG_COUNT; cursor += 1u) {
        if (fields[cursor].tag == 0u) return KOFUN_KIF_CORRUPT;
    }
    return KOFUN_KIF_OK;
}

static KofunKifStatus parse_type_reference(
    ByteView signature,
    size_t *cursor,
    uint8_t symbol_id[KOFUN_KIF_ID_BYTES],
    KofunKifTypeTag *type
) {
    uint8_t tag;
    if (*cursor >= signature.length) return KOFUN_KIF_CORRUPT;
    tag = signature.bytes[(*cursor)++];
    memset(symbol_id, 0, KOFUN_KIF_ID_BYTES);
    if (tag == KOFUN_KIF_TYPE_INT) {
        *type = KOFUN_KIF_TYPE_INT;
        return KOFUN_KIF_OK;
    }
    if (tag != KOFUN_KIF_TYPE_NOMINAL ||
        signature.length - *cursor < KOFUN_KIF_ID_BYTES) {
        return KOFUN_KIF_NONCANONICAL;
    }
    memcpy(symbol_id, signature.bytes + *cursor, KOFUN_KIF_ID_BYTES);
    *cursor += KOFUN_KIF_ID_BYTES;
    if (!id_is_nonzero(symbol_id)) return KOFUN_KIF_NONCANONICAL;
    *type = KOFUN_KIF_TYPE_NOMINAL;
    return KOFUN_KIF_OK;
}

static KofunKifStatus parse_parameter_label(
    ByteView signature,
    size_t *cursor,
    KofunKifParameterLabel *label
) {
    uint8_t marker;
    uint16_t length;
    if (*cursor >= signature.length) return KOFUN_KIF_CORRUPT;
    marker = signature.bytes[(*cursor)++];
    if (marker == 0u) return KOFUN_KIF_OK;
    if (marker != 1u || signature.length - *cursor < 2u) {
        return KOFUN_KIF_NONCANONICAL;
    }
    length = load_u16be(signature.bytes + *cursor);
    *cursor += 2u;
    if (length == 0u || length > KOFUN_KIF_MAX_NAME_BYTES ||
        signature.length - *cursor < length ||
        !canonical_identifier(
            (const char *)signature.bytes + *cursor,
            length)) {
        return KOFUN_KIF_NONCANONICAL;
    }
    label->bytes = malloc((size_t)length + 1u);
    if (label->bytes == NULL) return KOFUN_KIF_INTERNAL_INVARIANT;
    memcpy(label->bytes, signature.bytes + *cursor, length);
    label->bytes[length] = '\0';
    label->length = length;
    *cursor += length;
    return KOFUN_KIF_OK;
}

static KofunKifStatus parse_signature(ByteView signature, KofunKifFact *fact) {
    size_t cursor = 0u;
    size_t index;
    uint8_t kind;
    if (signature.length < 1u) return KOFUN_KIF_CORRUPT;
    kind = signature.bytes[cursor++];
    if (fact->kind == KOFUN_KIF_FACT_FUNCTION) {
        uint16_t count;
        KofunKifStatus status;
        if (kind != SIGNATURE_FUNCTION || signature.length < 4u) {
            return KOFUN_KIF_NONCANONICAL;
        }
        count = load_u16be(signature.bytes + cursor);
        cursor += 2u;
        if (count > 256u) return KOFUN_KIF_NONCANONICAL;
        if (count != 0u) {
            fact->parameter_type_symbol_ids = calloc(
                count, KOFUN_KIF_ID_BYTES);
            fact->parameter_labels = calloc(
                count, sizeof(*fact->parameter_labels));
            if (fact->parameter_type_symbol_ids == NULL ||
                fact->parameter_labels == NULL) {
                return KOFUN_KIF_INTERNAL_INVARIANT;
            }
        }
        for (index = 0u; index < count; index += 1u) {
            KofunKifTypeTag parameter_type;
            status = parse_type_reference(
                signature, &cursor,
                fact->parameter_type_symbol_ids +
                    index * KOFUN_KIF_ID_BYTES,
                &parameter_type);
            if (status != KOFUN_KIF_OK) return status;
            status = parse_parameter_label(
                signature,
                &cursor,
                &fact->parameter_labels[index]
            );
            if (status != KOFUN_KIF_OK) return status;
        }
        status = parse_type_reference(
            signature, &cursor, fact->result_type_symbol_id,
            &fact->result_type);
        if (status != KOFUN_KIF_OK) return status;
        fact->parameter_count = count;
    } else if (fact->kind == KOFUN_KIF_FACT_ADT) {
        if (kind != SIGNATURE_ADT || signature.length != 3u ||
            load_u16be(signature.bytes + cursor) != 0u) return KOFUN_KIF_NONCANONICAL;
        cursor += 2u;
    } else if (fact->kind == KOFUN_KIF_FACT_CONSTRUCTOR) {
        uint8_t count;
        KofunKifStatus status;
        KofunKifTypeTag payload_type;
        if (kind != SIGNATURE_CONSTRUCTOR || signature.length < 2u) {
            return KOFUN_KIF_NONCANONICAL;
        }
        count = signature.bytes[cursor++];
        if (count > 1u) return KOFUN_KIF_NONCANONICAL;
        if (count == 1u) {
            status = parse_type_reference(
                signature, &cursor,
                fact->constructor_payload_type_symbol_id,
                &payload_type);
            if (status != KOFUN_KIF_OK) return status;
        }
        fact->constructor_payload_count = count;
    } else if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        uint8_t target_kind;
        if (kind != SIGNATURE_EXPORT || signature.length < 2u) {
            return KOFUN_KIF_NONCANONICAL;
        }
        target_kind = signature.bytes[cursor++];
        fact->export_target_kind = (KofunKifExportTargetKind)target_kind;
        if (export_target_kind_schema_name(fact->export_target_kind) == NULL) {
            return KOFUN_KIF_NONCANONICAL;
        }
        if (fact->export_target_kind == KOFUN_KIF_EXPORT_TARGET_FUNCTION) {
            uint16_t count;
            if (signature.length < 5u) return KOFUN_KIF_NONCANONICAL;
            count = load_u16be(signature.bytes + cursor);
            cursor += 2u;
            if (count > 256u) {
                return KOFUN_KIF_NONCANONICAL;
            }
            if (count != 0u) {
                fact->parameter_labels = calloc(
                    count, sizeof(*fact->parameter_labels));
                if (fact->parameter_labels == NULL) {
                    return KOFUN_KIF_INTERNAL_INVARIANT;
                }
            }
            for (index = 0u; index < count; index += 1u) {
                if (cursor >= signature.length ||
                    signature.bytes[cursor++] != KOFUN_KIF_TYPE_INT) {
                    return KOFUN_KIF_NONCANONICAL;
                }
                {
                    KofunKifStatus status = parse_parameter_label(
                        signature,
                        &cursor,
                        &fact->parameter_labels[index]
                    );
                    if (status != KOFUN_KIF_OK) return status;
                }
            }
            if (cursor >= signature.length ||
                signature.bytes[cursor++] != KOFUN_KIF_TYPE_INT) {
                return KOFUN_KIF_NONCANONICAL;
            }
            fact->parameter_count = count;
            fact->result_type = KOFUN_KIF_TYPE_INT;
        } else if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
            uint8_t count;
            if (signature.length < 3u) return KOFUN_KIF_NONCANONICAL;
            count = signature.bytes[cursor++];
            if (count > 1u || signature.length != 3u + count) {
                return KOFUN_KIF_NONCANONICAL;
            }
            if (count == 1u &&
                signature.bytes[cursor++] != KOFUN_KIF_TYPE_INT) {
                return KOFUN_KIF_NONCANONICAL;
            }
            fact->constructor_payload_count = count;
        } else if (signature.length != 2u) {
            return KOFUN_KIF_NONCANONICAL;
        }
    } else {
        return KOFUN_KIF_NONCANONICAL;
    }
    return cursor == signature.length ? KOFUN_KIF_OK : KOFUN_KIF_NONCANONICAL;
}

static KofunKifStatus parse_fact_record(
    const uint8_t *bytes,
    size_t length,
    KofunKifVisibility expected_visibility,
    KofunKifLimits limits,
    KofunKifFact *fact
) {
    ParsedField fields[16];
    size_t index;
    KofunKifStatus status;
    memset(fact, 0, sizeof(*fact));
    status = scan_fields(bytes, length, limits, FACT_TAG_NAMESPACE_ID, 16u,
        true, fields);
    if (status != KOFUN_KIF_OK) return status;
    for (index = 0u; index < 6u; index += 1u) {
        if (fields[index].tag == 0u) return KOFUN_KIF_CORRUPT;
    }
    if (fields[0].value.length != 32u || fields[1].value.length != 32u ||
        fields[2].value.length != 1u || fields[4].value.length != 1u) {
        return KOFUN_KIF_CORRUPT;
    }
    memcpy(fact->namespace_id, fields[0].value.bytes, 32u);
    memcpy(fact->symbol_id, fields[1].value.bytes, 32u);
    fact->kind = (KofunKifFactKind)fields[2].value.bytes[0];
    fact->visibility = (KofunKifVisibility)fields[4].value.bytes[0];
    if (fact->visibility != expected_visibility ||
        !canonical_identifier(
            (const char *)fields[3].value.bytes,
            fields[3].value.length)) {
        return KOFUN_KIF_NONCANONICAL;
    }
    fact->name = malloc(fields[3].value.length + 1u);
    if (fact->name == NULL) return KOFUN_KIF_INTERNAL_INVARIANT;
    memcpy(fact->name, fields[3].value.bytes, fields[3].value.length);
    fact->name[fields[3].value.length] = '\0';
    fact->name_length = fields[3].value.length;
    {
        status = parse_signature(fields[5].value, fact);
        if (status != KOFUN_KIF_OK) return status;
    }
    if (fact->kind == KOFUN_KIF_FACT_CONSTRUCTOR) {
        if (fields[6].value.length != 32u || fields[7].value.length != 4u) {
            return KOFUN_KIF_CORRUPT;
        }
        memcpy(fact->owner_symbol_id, fields[6].value.bytes, 32u);
        fact->constructor_ordinal = load_u32be(fields[7].value.bytes);
        for (index = 8u; index < 16u; index += 1u) {
            if (fields[index].tag != 0u) return KOFUN_KIF_NONCANONICAL;
        }
    } else if (fact->kind == KOFUN_KIF_FACT_EXPORT) {
        uint32_t chain_count;
        size_t chain_bytes;
        if (fields[6].tag != 0u || fields[7].tag != 0u) {
            return KOFUN_KIF_NONCANONICAL;
        }
        for (index = 8u; index < 13u; index += 1u) {
            if (fields[index].tag == 0u) return KOFUN_KIF_CORRUPT;
        }
        if (fields[8].value.length != 32u ||
            fields[9].value.length != 32u ||
            fields[10].value.length != 32u ||
            fields[11].value.length < 4u ||
            fields[12].value.length != 1u) return KOFUN_KIF_CORRUPT;
        chain_count = load_u32be(fields[11].value.bytes);
        if (chain_count == 0u || chain_count > KOFUN_KIF_MAX_EXPORT_CHAIN) {
            return KOFUN_KIF_LIMIT_EXHAUSTED;
        }
        chain_bytes = (size_t)chain_count * 32u;
        if (fields[11].value.length != 4u + chain_bytes) {
            return KOFUN_KIF_CORRUPT;
        }
        if (fields[12].value.bytes[0] != (uint8_t)fact->export_target_kind) {
            return KOFUN_KIF_NONCANONICAL;
        }
        memcpy(fact->source_import_binding_id, fields[8].value.bytes, 32u);
        memcpy(fact->target_module_id, fields[9].value.bytes, 32u);
        memcpy(fact->target_symbol_id, fields[10].value.bytes, 32u);
        fact->export_chain_ids = malloc(chain_bytes);
        if (fact->export_chain_ids == NULL) return KOFUN_KIF_INTERNAL_INVARIANT;
        memcpy(fact->export_chain_ids, fields[11].value.bytes + 4u, chain_bytes);
        fact->export_chain_count = chain_count;
        if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR) {
            if (fields[13].value.length != 32u ||
                fields[14].value.length != 4u ||
                fields[15].tag != 0u) {
                return KOFUN_KIF_CORRUPT;
            }
            memcpy(fact->export_target_owner_symbol_id,
                fields[13].value.bytes, 32u);
            fact->export_target_constructor_ordinal =
                load_u32be(fields[14].value.bytes);
        } else if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_MODULE) {
            if (fields[13].tag != 0u || fields[14].tag != 0u ||
                fields[15].tag == 0u ||
                fields[15].value.length == 0u ||
                fields[15].value.length >
                    KOFUN_KIF_MAX_MODULE_PATH_BYTES) {
                return KOFUN_KIF_CORRUPT;
            }
            fact->export_target_module_path =
                malloc(fields[15].value.length + 1u);
            if (fact->export_target_module_path == NULL) {
                return KOFUN_KIF_INTERNAL_INVARIANT;
            }
            memcpy(fact->export_target_module_path,
                fields[15].value.bytes, fields[15].value.length);
            fact->export_target_module_path[
                fields[15].value.length] = '\0';
            fact->export_target_module_path_length =
                fields[15].value.length;
        } else if (fields[13].tag != 0u || fields[14].tag != 0u ||
            fields[15].tag != 0u) {
            return KOFUN_KIF_NONCANONICAL;
        }
    } else {
        for (index = 6u; index < 16u; index += 1u) {
            if (fields[index].tag != 0u) return KOFUN_KIF_NONCANONICAL;
        }
    }
    return KOFUN_KIF_OK;
}

static void destroy_fact_array(KofunKifFact *facts, size_t count) {
    size_t index;
    if (facts == NULL) return;
    for (index = 0u; index < count; index += 1u) {
        size_t parameter_index;
        free(facts[index].name);
        free(facts[index].parameter_type_symbol_ids);
        for (parameter_index = 0u;
             parameter_index < facts[index].parameter_count &&
             facts[index].parameter_labels != NULL;
             parameter_index += 1u) {
            free(facts[index].parameter_labels[parameter_index].bytes);
        }
        free(facts[index].parameter_labels);
        free(facts[index].export_target_module_path);
        free(facts[index].export_chain_ids);
    }
    free(facts);
}

static KofunKifStatus parse_vector(
    ByteView vector,
    KofunKifVisibility visibility,
    KofunKifLimits limits,
    KofunKifFact **facts_out,
    size_t *count_out
) {
    uint32_t count;
    KofunKifFact *facts = NULL;
    size_t cursor = 4u;
    size_t index;
    if (vector.length < 4u) return KOFUN_KIF_CORRUPT;
    count = load_u32be(vector.bytes);
    if (count > limits.max_facts) return KOFUN_KIF_LIMIT_EXHAUSTED;
    if ((size_t)count > (vector.length - 4u) / 4u) return KOFUN_KIF_CORRUPT;
    if (count != 0u) {
        facts = calloc(count, sizeof(*facts));
        if (facts == NULL) return KOFUN_KIF_INTERNAL_INVARIANT;
    }
    for (index = 0u; index < count; index += 1u) {
        uint32_t record_length;
        KofunKifStatus status;
        if (vector.length - cursor < 4u) {
            destroy_fact_array(facts, count);
            return KOFUN_KIF_CORRUPT;
        }
        record_length = load_u32be(vector.bytes + cursor);
        cursor += 4u;
        if ((size_t)record_length > vector.length - cursor) {
            destroy_fact_array(facts, count);
            return KOFUN_KIF_CORRUPT;
        }
        status = parse_fact_record(vector.bytes + cursor, record_length,
            visibility, limits, &facts[index]);
        if (status != KOFUN_KIF_OK) {
            destroy_fact_array(facts, count);
            return status;
        }
        if (index != 0u && memcmp(facts[index - 1u].symbol_id, facts[index].symbol_id, 32u) >= 0) {
            destroy_fact_array(facts, count);
            return KOFUN_KIF_NONCANONICAL;
        }
        cursor += record_length;
    }
    if (cursor != vector.length) {
        destroy_fact_array(facts, count);
        return KOFUN_KIF_CORRUPT;
    }
    *facts_out = facts;
    *count_out = count;
    return KOFUN_KIF_OK;
}

/* Mirrors build_digest_views field for field. The two must agree exactly or
 * every well-formed artifact fails its own digest check, so the trust field is
 * appended last on both sides here as it is there. */
static KofunKifStatus recompute_claimed_digests(
    ParsedField fields[ENVELOPE_TAG_COUNT],
    uint8_t public_digest[32],
    uint8_t internal_digest[32]
) {
    ByteBuffer base_view = { 0 };
    ByteBuffer public_view = { 0 };
    ByteBuffer internal_view = { 0 };
    KofunKifStatus status = KOFUN_KIF_OK;
    const ParsedField *trust = &fields[TAG_MODULE_TRUST - TAG_SCHEMA];
    size_t index;
    for (index = 0u; index <= TAG_PUBLIC_FACTS - TAG_SCHEMA; index += 1u) {
        if (!buffer_field(&base_view, fields[index].tag,
                fields[index].value.bytes, fields[index].value.length)) {
            status = base_view.status;
            goto done;
        }
    }
    if (!buffer_append(&public_view, base_view.bytes, base_view.length) ||
        !buffer_field(&public_view, TAG_MODULE_TRUST,
            trust->value.bytes, trust->value.length)) {
        status = public_view.status;
        goto done;
    }
    if (!buffer_append(&internal_view, base_view.bytes, base_view.length) ||
        !buffer_field(&internal_view, TAG_INTERNAL_FACTS,
            fields[TAG_INTERNAL_FACTS - TAG_SCHEMA].value.bytes,
            fields[TAG_INTERNAL_FACTS - TAG_SCHEMA].value.length) ||
        !buffer_field(&internal_view, TAG_MODULE_TRUST,
            trust->value.bytes, trust->value.length)) {
        status = internal_view.status;
        goto done;
    }
    framed_hash("kofun.digest.public-semantic/v2", public_view.bytes,
        public_view.length, public_digest);
    framed_hash("kofun.digest.package-internal/v2", internal_view.bytes,
        internal_view.length, internal_digest);
done:
    buffer_destroy(&base_view);
    buffer_destroy(&public_view);
    buffer_destroy(&internal_view);
    return status;
}

KifReadResult kofun_kif_read(
    const uint8_t *bytes,
    size_t length,
    KofunKifLimits limits
) {
    static const uint8_t magic[4] = { 'K', 'I', 'F', 0 };
    ParsedField fields[ENVELOPE_TAG_COUNT];
    KofunKifInterface *interface = NULL;
    KofunKifStatus status;
    uint8_t public_digest[32];
    uint8_t internal_digest[32];
    KofunKifModuleTrust module_trust = KOFUN_KIF_TRUST_ORDINARY;
    size_t total;
    if (!limits_are_valid(limits) || length > limits.max_envelope_bytes ||
        length > KOFUN_KIF_MAX_ENVELOPE) return read_result(KOFUN_KIF_LIMIT_EXHAUSTED, NULL);
    if (bytes == NULL || length < KIF_HEADER_BYTES || memcmp(bytes, magic, sizeof(magic)) != 0) {
        return read_result(KOFUN_KIF_CORRUPT, NULL);
    }
    if (load_u16be(bytes + 4u) != KIF_MAJOR) {
        return read_result(KOFUN_KIF_UNSUPPORTED_SCHEMA, NULL);
    }
    if ((size_t)load_u32be(bytes + 8u) != length - KIF_HEADER_BYTES) {
        return read_result(KOFUN_KIF_CORRUPT, NULL);
    }
    status = parse_envelope_fields(bytes + KIF_HEADER_BYTES,
        length - KIF_HEADER_BYTES, limits, fields);
    if (status != KOFUN_KIF_OK) return read_result(status, NULL);
    if (fields[TAG_SCHEMA - TAG_SCHEMA].value.length != sizeof(KIF_SCHEMA) - 1u ||
        memcmp(fields[TAG_SCHEMA - TAG_SCHEMA].value.bytes,
            KIF_SCHEMA, sizeof(KIF_SCHEMA) - 1u) != 0 ||
        fields[TAG_COMPATIBILITY - TAG_SCHEMA].value.length != sizeof(KIF_COMPATIBILITY) - 1u ||
        memcmp(fields[TAG_COMPATIBILITY - TAG_SCHEMA].value.bytes,
            KIF_COMPATIBILITY, sizeof(KIF_COMPATIBILITY) - 1u) != 0) {
        return read_result(KOFUN_KIF_UNSUPPORTED_SCHEMA, NULL);
    }
    /* Unknown value in 0x800A rejects; a reader may not skip it. This runs
     * before the digests are recomputed so a noncanonical trust class is named
     * as such rather than surfacing as a digest mismatch. */
    if (!trust_from_bytes(fields[TAG_MODULE_TRUST - TAG_SCHEMA].value, &module_trust)) {
        return read_result(KOFUN_KIF_NONCANONICAL, NULL);
    }
    if (fields[TAG_PACKAGE_ID - TAG_SCHEMA].value.length != 32u ||
        fields[TAG_MODULE_ID - TAG_SCHEMA].value.length != 32u ||
        fields[TAG_PUBLIC_DIGEST - TAG_SCHEMA].value.length != 32u ||
        fields[TAG_INTERNAL_DIGEST - TAG_SCHEMA].value.length != 32u ||
        fields[TAG_EDITION - TAG_SCHEMA].value.length == 0u ||
        fields[TAG_EDITION - TAG_SCHEMA].value.length > KOFUN_KIF_MAX_EDITION_BYTES) {
        return read_result(KOFUN_KIF_CORRUPT, NULL);
    }
    interface = calloc(1u, sizeof(*interface));
    if (interface == NULL) return read_result(KOFUN_KIF_INTERNAL_INVARIANT, NULL);
    memcpy(interface->package_id, fields[TAG_PACKAGE_ID - TAG_SCHEMA].value.bytes, 32u);
    memcpy(interface->module_id, fields[TAG_MODULE_ID - TAG_SCHEMA].value.bytes, 32u);
    memcpy(interface->edition, fields[TAG_EDITION - TAG_SCHEMA].value.bytes,
        fields[TAG_EDITION - TAG_SCHEMA].value.length);
    interface->edition[fields[TAG_EDITION - TAG_SCHEMA].value.length] = '\0';
    interface->module_trust = module_trust;
    interface->owns_storage = true;
    if (!id_is_nonzero(interface->package_id) || !id_is_nonzero(interface->module_id) ||
        !normalized_edition(interface->edition)) {
        status = KOFUN_KIF_NONCANONICAL;
        goto failed;
    }
    status = parse_vector(fields[TAG_PUBLIC_FACTS - TAG_SCHEMA].value,
        KOFUN_KIF_VISIBILITY_PUBLIC, limits,
        &interface->public_facts, &interface->public_fact_count);
    if (status != KOFUN_KIF_OK) goto failed;
    status = parse_vector(fields[TAG_INTERNAL_FACTS - TAG_SCHEMA].value,
        KOFUN_KIF_VISIBILITY_INTERNAL, limits,
        &interface->internal_facts, &interface->internal_fact_count);
    if (status != KOFUN_KIF_OK) goto failed;
    if (!checked_add(interface->public_fact_count, interface->internal_fact_count, &total) ||
        total > limits.max_facts) {
        status = KOFUN_KIF_LIMIT_EXHAUSTED;
        goto failed;
    }
    status = validate_interface(interface);
    if (status != KOFUN_KIF_OK) goto failed;
    status = recompute_claimed_digests(fields, public_digest, internal_digest);
    if (status != KOFUN_KIF_OK) goto failed;
    if (!constant_time_equal(public_digest,
            fields[TAG_PUBLIC_DIGEST - TAG_SCHEMA].value.bytes, 32u) ||
        !constant_time_equal(internal_digest,
            fields[TAG_INTERNAL_DIGEST - TAG_SCHEMA].value.bytes, 32u)) {
        status = KOFUN_KIF_DIGEST_MISMATCH;
        goto failed;
    }
    memcpy(interface->public_semantic_digest, public_digest, 32u);
    memcpy(interface->package_internal_semantic_digest, internal_digest, 32u);
    return read_result(KOFUN_KIF_OK, interface);
failed:
    kofun_kif_destroy(interface);
    return read_result(status, NULL);
}

bool kofun_kif_trust_agrees(
    const KofunKifInterface *interface,
    bool source_raw_foreign
) {
    KofunKifModuleTrust expected = source_raw_foreign
        ? KOFUN_KIF_TRUST_RAW_FOREIGN
        : KOFUN_KIF_TRUST_ORDINARY;
    if (interface == NULL) return false;
    return interface->module_trust == expected;
}

void kofun_kif_destroy(KofunKifInterface *interface) {
    if (interface == NULL) return;
    if (interface->owns_storage) {
        destroy_fact_array(interface->public_facts, interface->public_fact_count);
        destroy_fact_array(interface->internal_facts, interface->internal_fact_count);
        free(interface);
    }
}

static bool write_all(int descriptor, const uint8_t *bytes, size_t length) {
    size_t written = 0u;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (result == 0) return false;
        written += (size_t)result;
    }
    return true;
}

static char *parent_directory(const char *path) {
    const char *slash = strrchr(path, '/');
    size_t length;
    char *parent;
    if (slash == NULL) {
        parent = malloc(2u);
        if (parent != NULL) memcpy(parent, ".", 2u);
        return parent;
    }
    length = slash == path ? 1u : (size_t)(slash - path);
    parent = malloc(length + 1u);
    if (parent == NULL) return NULL;
    memcpy(parent, path, length);
    parent[length] = '\0';
    return parent;
}

static KofunKifStatus commit_atomic(
    const char *destination,
    const uint8_t *bytes,
    size_t length
) {
    char *temporary;
    char *parent;
    size_t destination_length;
    int descriptor = -1;
    int directory = -1;
    bool renamed = false;
    bool temporary_owned = false;
    KofunKifStatus status = KOFUN_KIF_IO_FAILURE;
    int formatted;
    if (destination == NULL || destination[0] == '\0') return KOFUN_KIF_IO_FAILURE;
    destination_length = strlen(destination);
    if (destination_length > SIZE_MAX - 48u) return KOFUN_KIF_LIMIT_EXHAUSTED;
    temporary = malloc(destination_length + 48u);
    parent = parent_directory(destination);
    if (temporary == NULL || parent == NULL) {
        free(temporary);
        free(parent);
        return KOFUN_KIF_INTERNAL_INVARIANT;
    }
    formatted = snprintf(temporary, destination_length + 48u,
        "%s.tmp.XXXXXX", destination);
    if (formatted < 0 || (size_t)formatted >= destination_length + 48u) {
        status = KOFUN_KIF_INTERNAL_INVARIANT;
        goto done;
    }
    descriptor = mkstemp(temporary);
    if (descriptor < 0) goto done;
    temporary_owned = true;
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 ||
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) goto done;
    {
        bool write_ok = write_all(descriptor, bytes, length);
        bool sync_ok = write_ok && fsync(descriptor) == 0;
        int close_status = close(descriptor);
        descriptor = -1;
        if (!write_ok || !sync_ok || close_status != 0) goto done;
    }
    if (rename(temporary, destination) != 0) goto done;
    renamed = true;
    temporary_owned = false;
    directory = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) goto done;
    {
        bool sync_ok = fsync(directory) == 0;
        int close_status = close(directory);
        directory = -1;
        if (!sync_ok || close_status != 0) goto done;
    }
    status = KOFUN_KIF_OK;
done:
    if (descriptor >= 0) (void)close(descriptor);
    if (directory >= 0) (void)close(directory);
    if (status != KOFUN_KIF_OK) {
        /* After rename the complete, self-read artifact is already authoritative.
         * A directory fsync failure means durability is unknown; deleting the new
         * name would also destroy the caller's last atomic replacement point. */
        if (!renamed && temporary_owned) (void)remove(temporary);
    }
    free(temporary);
    free(parent);
    return status;
}

KifWriteResult kofun_kif_write(
    const KofunKifInterface *interface,
    const char *destination
) {
    ByteBuffer envelope = { 0 };
    KifWriteResult result;
    KifReadResult self_read;
    KofunKifStatus status;
    memset(&result, 0, sizeof(result));
    status = encode_interface(interface, &envelope,
        result.public_semantic_digest,
        result.package_internal_semantic_digest);
    if (status != KOFUN_KIF_OK) goto done;
    self_read = kofun_kif_read(envelope.bytes, envelope.length, kofun_kif_default_limits());
    if (self_read.status != KOFUN_KIF_OK || self_read.interface == NULL ||
        !constant_time_equal(self_read.interface->public_semantic_digest,
            result.public_semantic_digest, 32u) ||
        !constant_time_equal(self_read.interface->package_internal_semantic_digest,
            result.package_internal_semantic_digest, 32u)) {
        if (self_read.interface != NULL) kofun_kif_destroy(self_read.interface);
        status = KOFUN_KIF_INTERNAL_INVARIANT;
        goto done;
    }
    kofun_kif_destroy(self_read.interface);
    status = commit_atomic(destination, envelope.bytes, envelope.length);
done:
    buffer_destroy(&envelope);
    result.status = status;
    result.message = status_message(status);
    if (status != KOFUN_KIF_OK) {
        memset(result.public_semantic_digest, 0, 32u);
        memset(result.package_internal_semantic_digest, 0, 32u);
    }
    return result;
}
