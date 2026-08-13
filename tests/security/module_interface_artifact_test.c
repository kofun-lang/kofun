#define _POSIX_C_SOURCE 200809L

#include "kif_v1.c"

static void fail(const char *message) {
    (void)fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

static uint8_t *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long measured;
    uint8_t *bytes;
    if (file == NULL || fseek(file, 0, SEEK_END) != 0 ||
        (measured = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0) {
        if (file != NULL) (void)fclose(file);
        return NULL;
    }
    bytes = malloc((size_t)measured);
    if (bytes == NULL ||
        fread(bytes, 1u, (size_t)measured, file) != (size_t)measured ||
        fclose(file) != 0) {
        free(bytes);
        return NULL;
    }
    *length = (size_t)measured;
    return bytes;
}

static void initialize_fact(
    KofunKifInterface *interface,
    KofunKifFact *fact,
    KofunKifFactKind kind,
    KofunKifVisibility visibility,
    const char *name
) {
    unsigned namespace_tag = kind == KOFUN_KIF_FACT_ADT ? 1u : 0u;
    const char *namespace_name = kind == KOFUN_KIF_FACT_ADT ? "type" : "value";
    memset(fact, 0, sizeof(*fact));
    compute_namespace_id(namespace_tag, namespace_name, fact->namespace_id);
    compute_symbol_id(
        interface->module_id,
        fact->namespace_id,
        kind,
        name,
        strlen(name),
        fact->symbol_id
    );
    fact->kind = kind;
    fact->visibility = visibility;
    fact->name = (char *)name;
    fact->name_length = strlen(name);
}

int main(int argc, char **argv) {
    KofunKifInterface interface;
    KofunKifFact public_facts[3];
    KofunKifFact internal_facts[1];
    uint8_t parameter_type[KOFUN_KIF_ID_BYTES];
    uint8_t absent_type[KOFUN_KIF_ID_BYTES];
    uint8_t *prior;
    uint8_t *after;
    size_t prior_length;
    size_t after_length;
    KifWriteResult result;
    ByteBuffer encoded = { 0 };
    uint8_t encoded_public_digest[KOFUN_KIF_ID_BYTES];
    uint8_t encoded_internal_digest[KOFUN_KIF_ID_BYTES];
    size_t reference_offset = SIZE_MAX;
    KifReadResult read;
    size_t index;
    if (argc != 2) fail("expected destination path");
    memset(&interface, 0, sizeof(interface));
    for (index = 0u; index < KOFUN_KIF_ID_BYTES; index += 1u) {
        interface.package_id[index] = (uint8_t)(index + 1u);
        interface.module_id[index] = (uint8_t)(0x80u + index);
        absent_type[index] = (uint8_t)(0x40u + index);
    }
    memcpy(interface.edition, "2026", 5u);
    interface.module_trust = KOFUN_KIF_TRUST_ORDINARY;
    initialize_fact(
        &interface, &public_facts[0], KOFUN_KIF_FACT_ADT,
        KOFUN_KIF_VISIBILITY_PUBLIC, "PublicValue");
    initialize_fact(
        &interface, &public_facts[1], KOFUN_KIF_FACT_FUNCTION,
        KOFUN_KIF_VISIBILITY_PUBLIC, "expose");
    initialize_fact(
        &interface, &internal_facts[0], KOFUN_KIF_FACT_ADT,
        KOFUN_KIF_VISIBILITY_INTERNAL, "InternalValue");
    public_facts[1].parameter_count = 1u;
    public_facts[1].parameter_type_symbol_ids = parameter_type;
    public_facts[1].result_type = KOFUN_KIF_TYPE_INT;
    interface.public_facts = public_facts;
    interface.public_fact_count = 2u;
    interface.internal_facts = internal_facts;
    interface.internal_fact_count = 1u;

    memcpy(parameter_type, public_facts[0].symbol_id, KOFUN_KIF_ID_BYTES);
    result = kofun_kif_write(&interface, argv[1]);
    if (result.status != KOFUN_KIF_OK) fail("valid nominal interface was refused");
    prior = read_file(argv[1], &prior_length);
    if (prior == NULL || prior_length == 0u) fail("valid interface was not published");

    if (encode_interface(
            &interface,
            &encoded,
            encoded_public_digest,
            encoded_internal_digest) != KOFUN_KIF_OK) {
        fail("valid nominal interface did not encode in memory");
    }
    for (index = 0u;
         index + 1u + KOFUN_KIF_ID_BYTES <= encoded.length;
         index += 1u) {
        if (encoded.bytes[index] == KOFUN_KIF_TYPE_NOMINAL &&
            memcmp(
                encoded.bytes + index + 1u,
                public_facts[0].symbol_id,
                KOFUN_KIF_ID_BYTES) == 0) {
            reference_offset = index;
            break;
        }
    }
    if (reference_offset == SIZE_MAX) {
        fail("nominal signature reference was absent from encoded KIF");
    }
    memcpy(
        encoded.bytes + reference_offset + 1u,
        internal_facts[0].symbol_id,
        KOFUN_KIF_ID_BYTES
    );
    read = kofun_kif_read(
        encoded.bytes, encoded.length, kofun_kif_default_limits());
    if (read.status != KOFUN_KIF_VISIBILITY_LEAK ||
        read.interface != NULL) {
        fail("reader exposed a forged public-to-internal type reference");
    }
    memcpy(
        encoded.bytes + reference_offset + 1u,
        absent_type,
        KOFUN_KIF_ID_BYTES
    );
    read = kofun_kif_read(
        encoded.bytes, encoded.length, kofun_kif_default_limits());
    if (read.status != KOFUN_KIF_VISIBILITY_LEAK ||
        read.interface != NULL) {
        fail("reader exposed an absent nominal type reference");
    }
    encoded.bytes[reference_offset] = UINT8_C(0xff);
    read = kofun_kif_read(
        encoded.bytes, encoded.length, kofun_kif_default_limits());
    if (read.status != KOFUN_KIF_NONCANONICAL || read.interface != NULL) {
        fail("reader accepted an unknown type-reference tag");
    }
    read = kofun_kif_read(
        encoded.bytes, encoded.length - 1u, kofun_kif_default_limits());
    if (read.status != KOFUN_KIF_CORRUPT || read.interface != NULL) {
        fail("reader accepted a truncated nominal interface");
    }
    buffer_destroy(&encoded);

    memcpy(parameter_type, internal_facts[0].symbol_id, KOFUN_KIF_ID_BYTES);
    result = kofun_kif_write(&interface, argv[1]);
    if (result.status != KOFUN_KIF_VISIBILITY_LEAK ||
        strcmp(result.message,
            "public KIF fact exposes a hidden semantic dependency") != 0) {
        fail("public-to-internal parameter reference was not hidden");
    }
    after = read_file(argv[1], &after_length);
    if (after == NULL || after_length != prior_length ||
        memcmp(after, prior, prior_length) != 0) {
        fail("visibility failure replaced the prior artifact");
    }
    free(after);

    memcpy(parameter_type, absent_type, KOFUN_KIF_ID_BYTES);
    result = kofun_kif_write(&interface, argv[1]);
    if (result.status != KOFUN_KIF_VISIBILITY_LEAK) {
        fail("missing nominal identity was not rejected closed");
    }

    memcpy(parameter_type, public_facts[0].symbol_id, KOFUN_KIF_ID_BYTES);
    initialize_fact(
        &interface, &public_facts[2], KOFUN_KIF_FACT_CONSTRUCTOR,
        KOFUN_KIF_VISIBILITY_PUBLIC, "PublicWrap");
    memcpy(public_facts[2].owner_symbol_id, public_facts[0].symbol_id,
        KOFUN_KIF_ID_BYTES);
    public_facts[2].constructor_payload_count = 1u;
    memcpy(public_facts[2].constructor_payload_type_symbol_id,
        internal_facts[0].symbol_id, KOFUN_KIF_ID_BYTES);
    interface.public_fact_count = 3u;
    result = kofun_kif_write(&interface, argv[1]);
    if (result.status != KOFUN_KIF_VISIBILITY_LEAK) {
        fail("public constructor payload exposed an internal identity");
    }

    after = read_file(argv[1], &after_length);
    if (after == NULL || after_length != prior_length ||
        memcmp(after, prior, prior_length) != 0) {
        fail("payload visibility failure replaced the prior artifact");
    }
    free(after);
    free(prior);
    puts("PASS: KIF reader/writer reject hidden, absent, malformed, or truncated nominal identities");
    puts("PASS: visibility failures disclose no names, paths, spans, or SymbolIds");
    puts("PASS: failed writer validation preserves the prior atomic artifact");
    return 0;
}
