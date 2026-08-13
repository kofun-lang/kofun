#include "kif_v1.h"
#include "sha256.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

enum {
    HEADER_BYTES = 12,
    TAG_PUBLIC_FACTS = 0x8006,
    TAG_INTERNAL_FACTS = 0x8007,
    TAG_PUBLIC_DIGEST = 0x8008,
    TAG_INTERNAL_DIGEST = 0x8009,
    TAG_MODULE_TRUST = 0x800a,
    FACT_TAG_NAMESPACE = 0x8001,
    FACT_TAG_SYMBOL = 0x8002,
    FACT_TAG_KIND = 0x8003,
    FACT_TAG_NAME = 0x8004,
    FACT_TAG_SIGNATURE = 0x8006,
    FACT_TAG_EXPORT_CHAIN = 0x800c,
    FACT_TAG_EXPORT_TARGET_KIND = 0x800d,
    FACT_TAG_EXPORT_TARGET_MODULE_PATH = 0x8010
};

typedef struct {
    size_t header;
    size_t value;
    size_t length;
} FieldPosition;

static void fail(const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

static uint16_t load_u16(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8u) | bytes[1]);
}

static uint32_t load_u32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24u) |
        ((uint32_t)bytes[1] << 16u) |
        ((uint32_t)bytes[2] << 8u) |
        (uint32_t)bytes[3];
}

static void store_u16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)(value >> 8u);
    bytes[1] = (uint8_t)value;
}

static void store_u32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24u);
    bytes[1] = (uint8_t)(value >> 16u);
    bytes[2] = (uint8_t)(value >> 8u);
    bytes[3] = (uint8_t)value;
}

static void hash_field(
    KofunSha256 *context,
    uint16_t tag,
    const uint8_t *value,
    size_t length
) {
    uint8_t tag_bytes[2];
    uint8_t length_bytes[4];
    store_u16(tag_bytes, tag);
    store_u32(length_bytes, (uint32_t)length);
    kofun_sha256_update(context, tag_bytes, sizeof(tag_bytes));
    kofun_sha256_update(context, length_bytes, sizeof(length_bytes));
    kofun_sha256_update(context, value, length);
}

static void framed_hash(
    const char *domain,
    const uint8_t *payload,
    size_t payload_length,
    uint8_t digest[KOFUN_KIF_ID_BYTES]
) {
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    uint8_t domain_length[2];
    uint8_t framed_length[4];
    KofunSha256 context;
    store_u16(domain_length, (uint16_t)strlen(domain));
    store_u32(framed_length, (uint32_t)payload_length);
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, domain_length, sizeof(domain_length));
    kofun_sha256_update(&context, (const uint8_t *)domain, strlen(domain));
    kofun_sha256_update(&context, framed_length, sizeof(framed_length));
    kofun_sha256_update(&context, payload, payload_length);
    kofun_sha256_finish(&context, digest);
}

static void compute_namespace_id(
    unsigned tag,
    const char *name,
    uint8_t digest[KOFUN_KIF_ID_BYTES]
) {
    char payload[96];
    int length = snprintf(payload, sizeof(payload),
        "kofun.namespace-id/v1\ntag=%u\nname=%s\n", tag, name);
    if (length < 0 || (size_t)length >= sizeof(payload)) {
        fail("namespace identity fixture overflow");
    }
    framed_hash("kofun.id.namespace/v1", (const uint8_t *)payload,
        (size_t)length, digest);
}

static void compute_symbol_id(
    const uint8_t module_id[KOFUN_KIF_ID_BYTES],
    const uint8_t namespace_id[KOFUN_KIF_ID_BYTES],
    const char *kind,
    const char *name,
    uint8_t digest[KOFUN_KIF_ID_BYTES]
) {
    static const char domain[] = "kofun.id.symbol/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    uint8_t domain_length[2];
    uint8_t payload_length[4];
    size_t kind_length = strlen(kind);
    size_t name_length = strlen(name);
    KofunSha256 context;
    store_u16(domain_length, (uint16_t)(sizeof(domain) - 1u));
    store_u32(payload_length,
        (uint32_t)(88u + kind_length + name_length));
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, domain_length, sizeof(domain_length));
    kofun_sha256_update(&context, (const uint8_t *)domain,
        sizeof(domain) - 1u);
    kofun_sha256_update(&context, payload_length, sizeof(payload_length));
    hash_field(&context, UINT16_C(0x8001), module_id,
        KOFUN_KIF_ID_BYTES);
    hash_field(&context, UINT16_C(0x8002), namespace_id,
        KOFUN_KIF_ID_BYTES);
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)kind,
        kind_length);
    hash_field(&context, UINT16_C(0x8004), (const uint8_t *)name,
        name_length);
    kofun_sha256_finish(&context, digest);
}

static void compute_export_binding_id(
    const uint8_t module_id[KOFUN_KIF_ID_BYTES],
    const uint8_t namespace_id[KOFUN_KIF_ID_BYTES],
    const char *name,
    const uint8_t target_symbol_id[KOFUN_KIF_ID_BYTES],
    uint8_t digest[KOFUN_KIF_ID_BYTES]
) {
    static const char domain[] = "kofun.id.export-binding/v1";
    static const uint8_t prefix[6] = { 'K', 'O', 'F', 'U', 'N', 0 };
    static const uint8_t visibility = 3u;
    uint8_t domain_length[2];
    uint8_t payload_length[4];
    size_t name_length = strlen(name);
    KofunSha256 context;
    store_u16(domain_length, (uint16_t)(sizeof(domain) - 1u));
    store_u32(payload_length,
        (uint32_t)(30u + 32u + 32u + name_length + 32u + 1u));
    kofun_sha256_init(&context);
    kofun_sha256_update(&context, prefix, sizeof(prefix));
    kofun_sha256_update(&context, domain_length, sizeof(domain_length));
    kofun_sha256_update(&context, (const uint8_t *)domain,
        sizeof(domain) - 1u);
    kofun_sha256_update(&context, payload_length, sizeof(payload_length));
    hash_field(&context, UINT16_C(0x8001), module_id,
        KOFUN_KIF_ID_BYTES);
    hash_field(&context, UINT16_C(0x8002), namespace_id,
        KOFUN_KIF_ID_BYTES);
    hash_field(&context, UINT16_C(0x8003), (const uint8_t *)name,
        name_length);
    hash_field(&context, UINT16_C(0x8004), target_symbol_id,
        KOFUN_KIF_ID_BYTES);
    hash_field(&context, UINT16_C(0x8005), &visibility,
        sizeof(visibility));
    kofun_sha256_finish(&context, digest);
}

static uint8_t *read_file(const char *path, size_t *length_out) {
    FILE *input = fopen(path, "rb");
    long measured;
    uint8_t *bytes;
    size_t length;
    if (input == NULL || fseek(input, 0, SEEK_END) != 0 ||
        (measured = ftell(input)) < 0 || fseek(input, 0, SEEK_SET) != 0) {
        fail("cannot open codec fixture");
    }
    length = (size_t)measured;
    bytes = malloc(length == 0u ? 1u : length);
    if (bytes == NULL || fread(bytes, 1u, length, input) != length || fclose(input) != 0) {
        fail("cannot read codec fixture");
    }
    *length_out = length;
    return bytes;
}

static uint8_t *duplicate_bytes(const uint8_t *bytes, size_t length) {
    uint8_t *copy = malloc(length == 0u ? 1u : length);
    if (copy == NULL) fail("mutation allocation failed");
    memcpy(copy, bytes, length);
    return copy;
}

static bool find_field(
    const uint8_t *bytes,
    size_t start,
    size_t length,
    uint16_t wanted,
    FieldPosition *position
) {
    size_t cursor = start;
    size_t end = start + length;
    while (cursor < end) {
        uint16_t tag;
        uint32_t field_length;
        if (end - cursor < 6u) return false;
        tag = load_u16(bytes + cursor);
        field_length = load_u32(bytes + cursor + 2u);
        if ((size_t)field_length > end - cursor - 6u) return false;
        if (tag == wanted) {
            *position = (FieldPosition){ cursor, cursor + 6u, field_length };
            return true;
        }
        cursor += 6u + field_length;
    }
    return false;
}

static void expect_status_with_limits(
    const uint8_t *bytes,
    size_t length,
    KofunKifLimits limits,
    KofunKifStatus expected,
    const char *label
) {
    KifReadResult result = kofun_kif_read(bytes, length, limits);
    if (result.status != expected) {
        fprintf(stderr, "FAIL: %s returned %s, expected %s\n", label,
            kofun_kif_status_name(result.status), kofun_kif_status_name(expected));
        exit(1);
    }
    if (expected == KOFUN_KIF_OK) {
        if (result.interface == NULL || result.rebuild_required) fail(label);
        kofun_kif_destroy(result.interface);
    } else if (result.interface != NULL || !result.rebuild_required) {
        fail("failed read published a partial interface");
    }
}

static void expect_status(
    const uint8_t *bytes,
    size_t length,
    KofunKifStatus expected,
    const char *label
) {
    expect_status_with_limits(bytes, length, kofun_kif_default_limits(), expected, label);
}

static uint8_t *insert_field(
    const uint8_t *bytes,
    size_t length,
    size_t offset,
    uint16_t tag,
    const uint8_t *value,
    size_t value_length,
    size_t *new_length
) {
    size_t added = 6u + value_length;
    uint8_t *copy = malloc(length + added);
    if (copy == NULL) fail("field insertion allocation failed");
    memcpy(copy, bytes, offset);
    store_u16(copy + offset, tag);
    store_u32(copy + offset + 2u, (uint32_t)value_length);
    memcpy(copy + offset + 6u, value, value_length);
    memcpy(copy + offset + added, bytes + offset, length - offset);
    store_u32(copy + 8u, (uint32_t)(length + added - HEADER_BYTES));
    *new_length = length + added;
    return copy;
}

static FieldPosition first_record(const uint8_t *bytes, FieldPosition vector) {
    FieldPosition record;
    uint32_t length;
    if (vector.length < 8u || load_u32(bytes + vector.value) < 1u) {
        fail("public vector has no record");
    }
    length = load_u32(bytes + vector.value + 4u);
    if ((size_t)length > vector.length - 8u) fail("public record is truncated");
    record.header = vector.value + 4u;
    record.value = vector.value + 8u;
    record.length = length;
    return record;
}

static FieldPosition second_record(const uint8_t *bytes, FieldPosition vector) {
    FieldPosition first = first_record(bytes, vector);
    FieldPosition second;
    uint32_t length;
    second.header = first.value + first.length;
    if (second.header + 4u > vector.value + vector.length) fail("public vector has one record");
    length = load_u32(bytes + second.header);
    second.value = second.header + 4u;
    second.length = length;
    if (second.value + second.length > vector.value + vector.length) {
        fail("second public record is truncated");
    }
    return second;
}

static bool find_export_record(
    const uint8_t *bytes,
    FieldPosition vector,
    KofunKifExportTargetKind target_kind,
    FieldPosition *record_out
) {
    uint32_t count;
    size_t cursor;
    size_t index;
    if (vector.length < 4u) return false;
    count = load_u32(bytes + vector.value);
    cursor = vector.value + 4u;
    for (index = 0u; index < count; index += 1u) {
        FieldPosition record;
        FieldPosition kind;
        FieldPosition export_target_kind;
        uint32_t record_length;
        if (vector.value + vector.length - cursor < 4u) return false;
        record_length = load_u32(bytes + cursor);
        record.header = cursor;
        record.value = cursor + 4u;
        record.length = record_length;
        if ((size_t)record_length >
                vector.value + vector.length - record.value) {
            return false;
        }
        if (find_field(bytes, record.value, record.length,
                FACT_TAG_KIND, &kind) &&
            kind.length == 1u && bytes[kind.value] == KOFUN_KIF_FACT_EXPORT &&
            find_field(bytes, record.value, record.length,
                FACT_TAG_EXPORT_TARGET_KIND, &export_target_kind) &&
            export_target_kind.length == 1u &&
            bytes[export_target_kind.value] == (uint8_t)target_kind) {
            *record_out = record;
            return true;
        }
        cursor = record.value + record.length;
    }
    return false;
}

static bool find_fact_record(
    const uint8_t *bytes,
    FieldPosition vector,
    KofunKifFactKind wanted_kind,
    FieldPosition *record_out
) {
    uint32_t count;
    size_t cursor;
    size_t index;
    if (vector.length < 4u) return false;
    count = load_u32(bytes + vector.value);
    cursor = vector.value + 4u;
    for (index = 0u; index < count; index += 1u) {
        FieldPosition record;
        FieldPosition kind;
        uint32_t record_length;
        if (vector.value + vector.length - cursor < 4u) return false;
        record_length = load_u32(bytes + cursor);
        record.header = cursor;
        record.value = cursor + 4u;
        record.length = record_length;
        if ((size_t)record_length >
                vector.value + vector.length - record.value) {
            return false;
        }
        if (find_field(bytes, record.value, record.length,
                FACT_TAG_KIND, &kind) &&
            kind.length == 1u && bytes[kind.value] == (uint8_t)wanted_kind) {
            *record_out = record;
            return true;
        }
        cursor = record.value + record.length;
    }
    return false;
}

static void recompute_semantic_digests(uint8_t *bytes, size_t length) {
    FieldPosition public_vector;
    FieldPosition internal_vector;
    FieldPosition public_digest;
    FieldPosition internal_digest;
    size_t public_view_length;
    size_t internal_view_length;
    if (!find_field(bytes, HEADER_BYTES, length - HEADER_BYTES,
            TAG_PUBLIC_FACTS, &public_vector) ||
        !find_field(bytes, HEADER_BYTES, length - HEADER_BYTES,
            TAG_INTERNAL_FACTS, &internal_vector) ||
        !find_field(bytes, HEADER_BYTES, length - HEADER_BYTES,
            TAG_PUBLIC_DIGEST, &public_digest) ||
        !find_field(bytes, HEADER_BYTES, length - HEADER_BYTES,
            TAG_INTERNAL_DIGEST, &internal_digest) ||
        public_digest.length != KOFUN_KIF_ID_BYTES ||
        internal_digest.length != KOFUN_KIF_ID_BYTES) {
        fail("cannot locate semantic digest fields");
    }
    public_view_length =
        public_vector.value + public_vector.length - HEADER_BYTES;
    internal_view_length =
        internal_vector.value + internal_vector.length - HEADER_BYTES;
    framed_hash("kofun.digest.public-semantic/v2",
        bytes + HEADER_BYTES, public_view_length,
        bytes + public_digest.value);
    framed_hash("kofun.digest.package-internal/v2",
        bytes + HEADER_BYTES, internal_view_length,
        bytes + internal_digest.value);
}

static void test_structural_mutations(const uint8_t *good, size_t length) {
    uint8_t *copy;
    FieldPosition public_vector;
    FieldPosition digest;
    FieldPosition first;
    FieldPosition second;
    FieldPosition field;
    FieldPosition function;
    FieldPosition signature;
    size_t inserted_length;
    static const uint8_t optional_value[3] = { 'o', 'p', 't' };

    expect_status(good, length, KOFUN_KIF_OK, "valid artifact");
    expect_status(good, 3u, KOFUN_KIF_CORRUPT, "truncated magic");
    expect_status(good, HEADER_BYTES - 1u, KOFUN_KIF_CORRUPT, "truncated header");
    expect_status(good, length - 1u, KOFUN_KIF_CORRUPT, "truncated payload");

    copy = duplicate_bytes(good, length);
    copy[0] = 'B';
    expect_status(copy, length, KOFUN_KIF_CORRUPT, "bad magic");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u16(copy + 4u, 3u);
    expect_status(copy, length, KOFUN_KIF_UNSUPPORTED_SCHEMA, "unsupported major");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u32(copy + 8u, UINT32_MAX);
    expect_status(copy, length, KOFUN_KIF_CORRUPT, "payload length overflow");
    free(copy);

    copy = insert_field(good, length, HEADER_BYTES, 1u, optional_value,
        sizeof(optional_value), &inserted_length);
    store_u16(copy + 6u, 1u);
    expect_status(copy, inserted_length, KOFUN_KIF_OK, "optional minor field");
    free(copy);

    /* 0x800b, the first tag above the active envelope. This assertion used
     * 0x800a until RFC-0012 made it the module-trust field; appending a tag
     * the reader now understands would test duplicate-field handling while
     * still reading as an unknown-required-tag test. The next required tag
     * added has to move this number again, deliberately. */
    copy = insert_field(good, length, length, UINT16_C(0x800b), optional_value,
        sizeof(optional_value), &inserted_length);
    expect_status(copy, inserted_length, KOFUN_KIF_UNSUPPORTED_SCHEMA,
        "unknown required field");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u16(copy + HEADER_BYTES + 6u + load_u32(copy + HEADER_BYTES + 2u),
        UINT16_C(0x8001));
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL, "duplicate envelope field");
    free(copy);

    if (!find_field(good, HEADER_BYTES, length - HEADER_BYTES,
            TAG_PUBLIC_FACTS, &public_vector) ||
        !find_field(good, HEADER_BYTES, length - HEADER_BYTES,
            TAG_PUBLIC_DIGEST, &digest)) fail("required field lookup failed");

    if (!find_fact_record(good, public_vector, KOFUN_KIF_FACT_FUNCTION,
            &function) ||
        !find_field(good, function.value, function.length,
            FACT_TAG_SIGNATURE, &signature) ||
        signature.length < 6u || good[signature.value] != 1u ||
        load_u16(good + signature.value + 1u) == 0u ||
        good[signature.value + 4u] != 0u) {
        fail("cannot locate canonical unlabelled parameter marker");
    }
    copy = duplicate_bytes(good, length);
    copy[signature.value + 4u] = UINT8_C(2);
    recompute_semantic_digests(copy, length);
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL,
        "unknown parameter label marker");
    free(copy);

    copy = duplicate_bytes(good, length);
    copy[signature.value + 4u] = UINT8_C(1);
    recompute_semantic_digests(copy, length);
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL,
        "truncated parameter label payload");
    free(copy);

    copy = duplicate_bytes(good, length);
    copy[digest.value] ^= UINT8_C(1);
    expect_status(copy, length, KOFUN_KIF_DIGEST_MISMATCH, "public digest mismatch");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u32(copy + public_vector.value, KOFUN_KIF_MAX_FACTS + 1u);
    expect_status(copy, length, KOFUN_KIF_LIMIT_EXHAUSTED, "fact count over limit");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u32(copy + public_vector.value, KOFUN_KIF_MAX_FACTS);
    expect_status(copy, length, KOFUN_KIF_CORRUPT, "fact count boundary fit check");
    free(copy);

    copy = duplicate_bytes(good, length);
    store_u32(copy + public_vector.header + 2u, UINT32_MAX);
    expect_status(copy, length, KOFUN_KIF_CORRUPT, "vector length overflow");
    free(copy);

    first = first_record(good, public_vector);
    second = second_record(good, public_vector);
    copy = duplicate_bytes(good, length);
    {
        size_t first_block = 4u + first.length;
        size_t second_block = 4u + second.length;
        uint8_t *blocks = malloc(first_block + second_block);
        if (blocks == NULL) fail("record swap allocation failed");
        memcpy(blocks, good + second.header, second_block);
        memcpy(blocks + second_block, good + first.header, first_block);
        memcpy(copy + first.header, blocks, first_block + second_block);
        free(blocks);
    }
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL, "unsorted facts");
    free(copy);

    if (!find_field(good, first.value, first.length, FACT_TAG_SYMBOL, &field)) {
        fail("first symbol field missing");
    }
    copy = duplicate_bytes(good, length);
    {
        FieldPosition second_symbol;
        if (!find_field(good, second.value, second.length, FACT_TAG_SYMBOL,
                &second_symbol)) fail("second symbol field missing");
        memcpy(copy + second_symbol.value, good + field.value, KOFUN_KIF_ID_BYTES);
    }
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL, "duplicate fact identity");
    free(copy);

    if (!find_field(good, first.value, first.length, FACT_TAG_NAME, &field)) {
        fail("first name field missing");
    }
    copy = duplicate_bytes(good, length);
    copy[field.value] = UINT8_C(0xff);
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL, "invalid UTF-8 name");
    free(copy);

    if (!find_field(good, first.value, first.length, FACT_TAG_NAMESPACE, &field)) {
        fail("first namespace field missing");
    }
    copy = duplicate_bytes(good, length);
    store_u32(copy + field.header + 2u, 31u);
    {
        KifReadResult malformed = kofun_kif_read(copy, length, kofun_kif_default_limits());
        if (malformed.status == KOFUN_KIF_OK || malformed.interface != NULL) {
            fail("malformed ID width was accepted");
        }
    }
    free(copy);
}

/* RFC-0012 tag 0x800A. Each refusal below mutates exactly one thing about an
 * otherwise byte-valid artifact, so a rejection cannot come from some other
 * damage introduced along the way. */
static void test_module_trust(const uint8_t *good, size_t length, const char *work) {
    KifReadResult result = kofun_kif_read(good, length, kofun_kif_default_limits());
    FieldPosition field;
    uint8_t *copy;
    size_t shrunk;
    uint8_t public_before[32];
    uint8_t internal_before[32];

    /* The positive direction first. Option B was rejected because an empty
     * payload conflates with absence, so assert the literal bytes rather than
     * only that the artifact reads. */
    if (result.status != KOFUN_KIF_OK) fail("cannot inspect valid trust fixture");
    if (result.interface->module_trust != KOFUN_KIF_TRUST_ORDINARY) {
        fail("fixture module is not ordinary");
    }
    memcpy(public_before, result.interface->public_semantic_digest, 32u);
    memcpy(internal_before, result.interface->package_internal_semantic_digest, 32u);
    kofun_kif_destroy(result.interface);

    if (!find_field(good, HEADER_BYTES, length - HEADER_BYTES,
            TAG_MODULE_TRUST, &field)) {
        fail("envelope carries no module-trust field");
    }
    if (field.length != sizeof("ordinary") - 1u ||
        memcmp(good + field.value, "ordinary", field.length) != 0) {
        fail("ordinary module did not serialize the exact bytes `ordinary`");
    }

    /* Unknown value, same length so nothing else shifts. `ordinarZ` is
     * well-formed UTF-8 and outside the closed set, which is the case a reader
     * that skipped unknown values would accept. */
    copy = duplicate_bytes(good, length);
    copy[field.value + field.length - 1u] = (uint8_t)'Z';
    expect_status(copy, length, KOFUN_KIF_NONCANONICAL, "unknown trust class");
    free(copy);

    /* Absent. Removing the whole field keeps every remaining tag strictly
     * increasing, so this is the pure absence case and not a framing error.
     * RFC-0012 is explicit that absence is never grandfathered. */
    copy = malloc(length);
    if (copy == NULL) fail("allocation failed");
    memcpy(copy, good, field.header - 6u);
    memcpy(copy + field.header - 6u, good + field.value + field.length,
        length - field.value - field.length);
    shrunk = length - field.length - 6u;
    store_u32(copy + 8u, (uint32_t)(shrunk - HEADER_BYTES));
    expect_status(copy, shrunk, KOFUN_KIF_CORRUPT, "absent trust field");
    free(copy);

    /* Participation in both digests. The same interface written twice,
     * differing in nothing but the trust class, must produce two different
     * public digests and two different internal ones. This is what separates
     * "the field is written" from "the field is part of the identity" — a
     * field emitted outside both digest views would pass every assertion
     * above and fail only this one. */
    {
        KifReadResult again = kofun_kif_read(good, length, kofun_kif_default_limits());
        KifWriteResult ordinary;
        KifWriteResult raw;
        char path[1024];
        if (again.status != KOFUN_KIF_OK) fail("digest fixture did not re-read");
        snprintf(path, sizeof(path), "%s/trust-ordinary.kif", work);
        again.interface->module_trust = KOFUN_KIF_TRUST_ORDINARY;
        ordinary = kofun_kif_write(again.interface, path);
        if (ordinary.status != KOFUN_KIF_OK) fail("ordinary rewrite failed");
        snprintf(path, sizeof(path), "%s/trust-raw.kif", work);
        again.interface->module_trust = KOFUN_KIF_TRUST_RAW_FOREIGN;
        raw = kofun_kif_write(again.interface, path);
        if (raw.status != KOFUN_KIF_OK) fail("raw-foreign rewrite failed");
        if (memcmp(ordinary.public_semantic_digest,
                raw.public_semantic_digest, 32u) == 0) {
            fail("trust class does not participate in the public semantic digest");
        }
        if (memcmp(ordinary.package_internal_semantic_digest,
                raw.package_internal_semantic_digest, 32u) == 0) {
            fail("trust class does not participate in the internal semantic digest");
        }
        kofun_kif_destroy(again.interface);
    }
    /* Guards the two assertions above: if the writer ever produced one digest
     * for both views, each comparison would still pass while proving half of
     * what it claims. */
    if (memcmp(public_before, internal_before, 32u) == 0) {
        fail("the two semantic digests are identical, so neither distinguishes anything");
    }
}

static void test_limits(const uint8_t *good, size_t length) {
    KifReadResult result = kofun_kif_read(good, length, kofun_kif_default_limits());
    KofunKifLimits limits = kofun_kif_default_limits();
    size_t total;
    uint8_t *boundary;
    if (result.status != KOFUN_KIF_OK) fail("cannot inspect valid limits fixture");
    total = result.interface->public_fact_count + result.interface->internal_fact_count;
    limits.max_envelope_bytes = length;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_OK, "exact envelope limit");
    limits.max_envelope_bytes = length - 1u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_LIMIT_EXHAUSTED,
        "envelope one over configured limit");
    limits = kofun_kif_default_limits();
    /* Ten since RFC-0012 added 0x800A. The pair of assertions is the point:
     * the exact count passes and one below it fails, so a field added or
     * dropped without updating this moves one of the two. */
    limits.max_record_fields = 10u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_OK, "exact envelope field count");
    limits.max_record_fields = 9u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_LIMIT_EXHAUSTED,
        "envelope field count over limit");
    limits = kofun_kif_default_limits();
    limits.max_facts = total;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_OK, "exact total fact limit");
    limits.max_facts = total - 1u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_LIMIT_EXHAUSTED,
        "total fact count over limit");
    limits = kofun_kif_default_limits();
    limits.max_depth = 2u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_OK, "exact v1 nesting depth");
    limits.max_depth = 1u;
    expect_status_with_limits(good, length, limits, KOFUN_KIF_LIMIT_EXHAUSTED,
        "nesting depth over limit");
    kofun_kif_destroy(result.interface);

    boundary = calloc(KOFUN_KIF_MAX_ENVELOPE, 1u);
    if (boundary == NULL) fail("16 MiB boundary allocation failed");
    memcpy(boundary, "KIF\0", 4u);
    store_u16(boundary + 4u, 2u);
    store_u32(boundary + 8u, KOFUN_KIF_MAX_ENVELOPE - HEADER_BYTES);
    expect_status(boundary, KOFUN_KIF_MAX_ENVELOPE, KOFUN_KIF_NONCANONICAL,
        "exact 16 MiB envelope admitted to structural validation");
    expect_status(boundary, KOFUN_KIF_MAX_ENVELOPE + 1u, KOFUN_KIF_LIMIT_EXHAUSTED,
        "16 MiB envelope one over limit");
    free(boundary);
}

static void test_writer_failures(const uint8_t *good, size_t length, const char *work) {
    KifReadResult read = kofun_kif_read(good, length, kofun_kif_default_limits());
    KifWriteResult write;
    const KofunKifFact *internal_owner = NULL;
    KofunKifFact *public_constructor = NULL;
    char path[1024];
    size_t index;
    if (read.status != KOFUN_KIF_OK) fail("writer failure fixture did not read");

    snprintf(path, sizeof(path), "%s/missing/output.kif", work);
    write = kofun_kif_write(read.interface, path);
    if (write.status != KOFUN_KIF_IO_FAILURE) fail("missing parent did not fail atomically");

    snprintf(path, sizeof(path), "%s/rename-target", work);
    if (mkdir(path, 0700) != 0 && errno != EEXIST) fail("cannot create rename failure target");
    write = kofun_kif_write(read.interface, path);
    if (write.status != KOFUN_KIF_IO_FAILURE) fail("rename failure did not report I/O");

    for (index = 0u; index < read.interface->internal_fact_count; index += 1u) {
        if (read.interface->internal_facts[index].kind == KOFUN_KIF_FACT_ADT) {
            internal_owner = &read.interface->internal_facts[index];
            break;
        }
    }
    for (index = 0u; index < read.interface->public_fact_count; index += 1u) {
        if (read.interface->public_facts[index].kind == KOFUN_KIF_FACT_CONSTRUCTOR) {
            public_constructor = &read.interface->public_facts[index];
            break;
        }
    }
    if (internal_owner == NULL || public_constructor == NULL) fail("visibility fixture is incomplete");
    memcpy(public_constructor->owner_symbol_id, internal_owner->symbol_id, KOFUN_KIF_ID_BYTES);
    snprintf(path, sizeof(path), "%s/visibility-leak.kif", work);
    remove(path);
    write = kofun_kif_write(read.interface, path);
    if (write.status != KOFUN_KIF_VISIBILITY_LEAK) fail("public hidden owner was accepted");
    {
        FILE *unexpected = fopen(path, "rb");
        if (unexpected != NULL) {
            fclose(unexpected);
            fail("rejected writer published an artifact");
        }
    }
    kofun_kif_destroy(read.interface);
}

static const KofunKifFact *find_public_function(
    const KofunKifInterface *interface,
    const char *name
) {
    size_t index;
    for (index = 0u; index < interface->public_fact_count; index += 1u) {
        const KofunKifFact *fact = &interface->public_facts[index];
        if (fact->kind == KOFUN_KIF_FACT_FUNCTION &&
            strcmp(fact->name, name) == 0) {
            return fact;
        }
    }
    return NULL;
}

static void test_export_facts(
    const uint8_t *good,
    size_t length,
    const char *work
) {
    static char function_name[] = "exported";
    static char module_name[] = "api";
    static char module_path[] = "demo.api";
    KifReadResult dependency =
        kofun_kif_read(good, length, kofun_kif_default_limits());
    const KofunKifFact *target_function;
    KofunKifInterface facade;
    KofunKifFact public_facts[2];
    uint8_t function_chain[2u * KOFUN_KIF_ID_BYTES];
    uint8_t module_chain[KOFUN_KIF_ID_BYTES];
    KifWriteResult write;
    KifReadResult readback;
    char path[1024];
    uint8_t *bytes;
    size_t export_length;
    FieldPosition public_vector;
    FieldPosition function_record;
    FieldPosition module_record;
    FieldPosition chain;
    FieldPosition target_module_path;
    uint8_t *mutated;
    size_t index;
    bool found_module = false;
    bool found_function = false;
    if (dependency.status != KOFUN_KIF_OK) {
        fail("cannot read dependency for export fixture");
    }
    target_function = find_public_function(dependency.interface,
        function_name);
    if (target_function == NULL) fail("export target function is absent");

    memset(&facade, 0, sizeof(facade));
    memset(public_facts, 0, sizeof(public_facts));
    memset(facade.module_id, UINT8_C(0x44), KOFUN_KIF_ID_BYTES);
    memcpy(facade.package_id, dependency.interface->package_id,
        KOFUN_KIF_ID_BYTES);
    memcpy(facade.edition, "edition-1", sizeof("edition-1"));
    facade.module_trust = KOFUN_KIF_TRUST_ORDINARY;
    facade.public_facts = public_facts;
    facade.public_fact_count = 2u;

    public_facts[0].kind = KOFUN_KIF_FACT_EXPORT;
    public_facts[0].visibility = KOFUN_KIF_VISIBILITY_PUBLIC;
    public_facts[0].name = function_name;
    public_facts[0].name_length = strlen(function_name);
    memcpy(public_facts[0].namespace_id, target_function->namespace_id,
        KOFUN_KIF_ID_BYTES);
    memset(public_facts[0].source_import_binding_id, UINT8_C(0x55),
        KOFUN_KIF_ID_BYTES);
    memcpy(public_facts[0].target_module_id,
        dependency.interface->module_id, KOFUN_KIF_ID_BYTES);
    memcpy(public_facts[0].target_symbol_id,
        target_function->symbol_id, KOFUN_KIF_ID_BYTES);
    public_facts[0].export_target_kind =
        KOFUN_KIF_EXPORT_TARGET_FUNCTION;
    public_facts[0].parameter_count = target_function->parameter_count;
    public_facts[0].parameter_labels = target_function->parameter_labels;
    public_facts[0].result_type = target_function->result_type;
    compute_export_binding_id(facade.module_id,
        public_facts[0].namespace_id, function_name,
        public_facts[0].target_symbol_id, public_facts[0].symbol_id);
    memcpy(function_chain, public_facts[0].symbol_id,
        KOFUN_KIF_ID_BYTES);
    memset(function_chain + KOFUN_KIF_ID_BYTES, UINT8_C(0x66),
        KOFUN_KIF_ID_BYTES);
    public_facts[0].export_chain_ids = function_chain;
    public_facts[0].export_chain_count = 2u;

    public_facts[1].kind = KOFUN_KIF_FACT_EXPORT;
    public_facts[1].visibility = KOFUN_KIF_VISIBILITY_PUBLIC;
    public_facts[1].name = module_name;
    public_facts[1].name_length = strlen(module_name);
    compute_namespace_id(2u, "module", public_facts[1].namespace_id);
    memset(public_facts[1].source_import_binding_id, UINT8_C(0x77),
        KOFUN_KIF_ID_BYTES);
    memcpy(public_facts[1].target_module_id,
        dependency.interface->module_id, KOFUN_KIF_ID_BYTES);
    public_facts[1].export_target_kind =
        KOFUN_KIF_EXPORT_TARGET_MODULE;
    public_facts[1].export_target_module_path = module_path;
    public_facts[1].export_target_module_path_length =
        strlen(module_path);
    compute_symbol_id(public_facts[1].target_module_id,
        public_facts[1].namespace_id, "module", module_path,
        public_facts[1].target_symbol_id);
    compute_export_binding_id(facade.module_id,
        public_facts[1].namespace_id, module_name,
        public_facts[1].target_symbol_id, public_facts[1].symbol_id);
    memcpy(module_chain, public_facts[1].symbol_id,
        KOFUN_KIF_ID_BYTES);
    public_facts[1].export_chain_ids = module_chain;
    public_facts[1].export_chain_count = 1u;

    snprintf(path, sizeof(path), "%s/export-interface.kif", work);
    remove(path);
    write = kofun_kif_write(&facade, path);
    if (write.status != KOFUN_KIF_OK) {
        fail("valid export interface did not write");
    }
    bytes = read_file(path, &export_length);
    readback = kofun_kif_read(bytes, export_length,
        kofun_kif_default_limits());
    if (readback.status != KOFUN_KIF_OK ||
        readback.interface->public_fact_count != 2u) {
        fail("valid export interface did not round-trip");
    }
    for (index = 0u; index < readback.interface->public_fact_count;
         index += 1u) {
        const KofunKifFact *fact =
            &readback.interface->public_facts[index];
        if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_MODULE) {
            if (strcmp(fact->export_target_module_path, module_path) != 0 ||
                memcmp(fact->target_symbol_id,
                    public_facts[1].target_symbol_id,
                    KOFUN_KIF_ID_BYTES) != 0) {
                fail("module target identity did not round-trip");
            }
            found_module = true;
        } else if (fact->export_target_kind ==
                KOFUN_KIF_EXPORT_TARGET_FUNCTION) {
            if (fact->parameter_count != target_function->parameter_count ||
                fact->parameter_labels == NULL) {
                fail("function export label shape did not round-trip");
            }
            found_function = true;
        }
    }
    if (!found_module) fail("module export fact is absent");
    if (!found_function) fail("function export fact is absent");
    kofun_kif_destroy(readback.interface);

    memcpy(function_chain + KOFUN_KIF_ID_BYTES, function_chain,
        KOFUN_KIF_ID_BYTES);
    snprintf(path, sizeof(path), "%s/duplicate-chain-writer.kif", work);
    remove(path);
    write = kofun_kif_write(&facade, path);
    if (write.status != KOFUN_KIF_NONCANONICAL) {
        fail("writer accepted duplicate/cyclic export chain IDs");
    }
    memset(function_chain + KOFUN_KIF_ID_BYTES, UINT8_C(0x66),
        KOFUN_KIF_ID_BYTES);

    public_facts[1].target_symbol_id[0] ^= UINT8_C(1);
    compute_export_binding_id(facade.module_id,
        public_facts[1].namespace_id, module_name,
        public_facts[1].target_symbol_id, public_facts[1].symbol_id);
    memcpy(module_chain, public_facts[1].symbol_id,
        KOFUN_KIF_ID_BYTES);
    snprintf(path, sizeof(path), "%s/bad-module-self-symbol.kif", work);
    remove(path);
    write = kofun_kif_write(&facade, path);
    if (write.status != KOFUN_KIF_NONCANONICAL) {
        fail("writer accepted a noncanonical module self-symbol");
    }
    public_facts[1].target_symbol_id[0] ^= UINT8_C(1);
    compute_export_binding_id(facade.module_id,
        public_facts[1].namespace_id, module_name,
        public_facts[1].target_symbol_id, public_facts[1].symbol_id);
    memcpy(module_chain, public_facts[1].symbol_id,
        KOFUN_KIF_ID_BYTES);
    public_facts[1].export_target_module_path = NULL;
    public_facts[1].export_target_module_path_length = 0u;
    write = kofun_kif_write(&facade, path);
    if (write.status != KOFUN_KIF_NONCANONICAL) {
        fail("writer accepted a module target without its canonical path");
    }
    public_facts[1].export_target_module_path = module_path;
    public_facts[1].export_target_module_path_length =
        strlen(module_path);

    if (!find_field(bytes, HEADER_BYTES, export_length - HEADER_BYTES,
            TAG_PUBLIC_FACTS, &public_vector) ||
        !find_export_record(bytes, public_vector,
            KOFUN_KIF_EXPORT_TARGET_FUNCTION, &function_record) ||
        !find_field(bytes, function_record.value, function_record.length,
            FACT_TAG_EXPORT_CHAIN, &chain) ||
        chain.length != 4u + 2u * KOFUN_KIF_ID_BYTES) {
        fail("cannot locate function export chain");
    }
    mutated = duplicate_bytes(bytes, export_length);
    memcpy(mutated + chain.value + 4u + KOFUN_KIF_ID_BYTES,
        mutated + chain.value + 4u, KOFUN_KIF_ID_BYTES);
    recompute_semantic_digests(mutated, export_length);
    expect_status(mutated, export_length, KOFUN_KIF_NONCANONICAL,
        "duplicate/cyclic export chain IDs");
    free(mutated);

    if (!find_export_record(bytes, public_vector,
            KOFUN_KIF_EXPORT_TARGET_MODULE, &module_record) ||
        !find_field(bytes, module_record.value, module_record.length,
            FACT_TAG_EXPORT_TARGET_MODULE_PATH, &target_module_path) ||
        target_module_path.length != strlen(module_path)) {
        fail("cannot locate module target path");
    }
    mutated = duplicate_bytes(bytes, export_length);
    mutated[target_module_path.value + target_module_path.length - 1u] =
        'j';
    recompute_semantic_digests(mutated, export_length);
    expect_status(mutated, export_length, KOFUN_KIF_NONCANONICAL,
        "module self-symbol path mismatch");
    free(mutated);

    free(bytes);
    kofun_kif_destroy(dependency.interface);
}

int main(int argc, char **argv) {
    uint8_t *good;
    size_t length;
    if (argc != 3) {
        fprintf(stderr, "usage: %s VALID_KIF WORK_DIRECTORY\n", argv[0]);
        return 2;
    }
    good = read_file(argv[1], &length);
    test_structural_mutations(good, length);
    test_module_trust(good, length, argv[2]);
    test_limits(good, length);
    test_writer_failures(good, length, argv[2]);
    test_export_facts(good, length, argv[2]);
    free(good);
    puts("PASS: KIF v2 mutation, label, limit, publication, and writer transaction matrix");
    return 0;
}
