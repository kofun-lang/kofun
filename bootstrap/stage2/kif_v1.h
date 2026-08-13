#ifndef KOFUN_STAGE2_KIF_V1_H
#define KOFUN_STAGE2_KIF_V1_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KOFUN_KIF_ID_BYTES 32u
#define KOFUN_KIF_MAX_ENVELOPE (16u * 1024u * 1024u)
#define KOFUN_KIF_MAX_RECORD_FIELDS 256u
#define KOFUN_KIF_MAX_FACTS 65536u
#define KOFUN_KIF_MAX_DEPTH 128u
#define KOFUN_KIF_MAX_FIELD_BYTES (1024u * 1024u)
#define KOFUN_KIF_MAX_NAME_BYTES 256u
#define KOFUN_KIF_MAX_EDITION_BYTES 64u
#define KOFUN_KIF_MAX_EXPORT_CHAIN 64u
#define KOFUN_KIF_MAX_MODULE_PATH_BYTES 4096u

typedef enum {
    KOFUN_KIF_OK = 0,
    KOFUN_KIF_UNSUPPORTED_SCHEMA = 1,
    KOFUN_KIF_CORRUPT = 2,
    KOFUN_KIF_NONCANONICAL = 3,
    KOFUN_KIF_LIMIT_EXHAUSTED = 4,
    KOFUN_KIF_DIGEST_MISMATCH = 5,
    KOFUN_KIF_IO_FAILURE = 6,
    KOFUN_KIF_INTERNAL_INVARIANT = 7,
    KOFUN_KIF_VISIBILITY_LEAK = 8
} KofunKifStatus;

typedef enum {
    KOFUN_KIF_FACT_FUNCTION = 1,
    KOFUN_KIF_FACT_ADT = 2,
    KOFUN_KIF_FACT_CONSTRUCTOR = 3,
    KOFUN_KIF_FACT_EXPORT = 4
} KofunKifFactKind;

typedef enum {
    KOFUN_KIF_EXPORT_TARGET_FUNCTION = 1,
    KOFUN_KIF_EXPORT_TARGET_ADT = 2,
    KOFUN_KIF_EXPORT_TARGET_CONSTRUCTOR = 3,
    KOFUN_KIF_EXPORT_TARGET_MODULE = 4
} KofunKifExportTargetKind;

typedef enum {
    KOFUN_KIF_VISIBILITY_INTERNAL = 1,
    KOFUN_KIF_VISIBILITY_PUBLIC = 2
} KofunKifVisibility;

typedef enum {
    KOFUN_KIF_TYPE_INT = 1,
    KOFUN_KIF_TYPE_NOMINAL = 2
} KofunKifTypeTag;

/* RFC-0012 envelope tag 0x800A. The source grammar spells a `trust` line only
 * for `raw-foreign`; the implicit ordinary source state is serialized as the
 * explicit bytes `ordinary` (RFC-0012/A01, option A). Absence is never
 * grandfathered — it is the one downgrade the field exists to prevent — so
 * there is no "unset" member here. */
typedef enum {
    KOFUN_KIF_TRUST_ORDINARY = 1,
    KOFUN_KIF_TRUST_RAW_FOREIGN = 2
} KofunKifModuleTrust;

typedef struct {
    /* NULL plus zero length is the explicit canonical `unlabelled` marker. */
    char *bytes;
    uint16_t length;
} KofunKifParameterLabel;

typedef struct {
    uint8_t namespace_id[KOFUN_KIF_ID_BYTES];
    uint8_t symbol_id[KOFUN_KIF_ID_BYTES];
    KofunKifFactKind kind;
    KofunKifVisibility visibility;
    char *name;
    size_t name_length;

    /*
     * Function facts use a zero 32-byte entry for Int and a non-zero ADT
     * SymbolId for one flat nominal reference. A NULL parameter array is the
     * canonical writer shorthand for an all-Int parameter list.
     */
    uint16_t parameter_count;
    uint8_t *parameter_type_symbol_ids;
    KofunKifParameterLabel *parameter_labels;
    KofunKifTypeTag result_type;
    uint8_t result_type_symbol_id[KOFUN_KIF_ID_BYTES];

    /* A zero payload SymbolId means Int; a non-zero value names an ADT fact. */
    uint8_t constructor_payload_count;
    uint8_t constructor_payload_type_symbol_id[KOFUN_KIF_ID_BYTES];
    uint8_t owner_symbol_id[KOFUN_KIF_ID_BYTES];
    uint32_t constructor_ordinal;

    /*
     * Public export facts use symbol_id as the ExportBindingId. The target
     * identity remains separate and canonical; an export never copies a
     * declaration SymbolId.
     */
    uint8_t source_import_binding_id[KOFUN_KIF_ID_BYTES];
    uint8_t target_module_id[KOFUN_KIF_ID_BYTES];
    uint8_t target_symbol_id[KOFUN_KIF_ID_BYTES];
    KofunKifExportTargetKind export_target_kind;
    uint8_t export_target_owner_symbol_id[KOFUN_KIF_ID_BYTES];
    uint32_t export_target_constructor_ordinal;
    /*
     * A module target needs its canonical declared path to validate the
     * ModuleSelfSymbolId. It is absent for non-module targets.
     */
    char *export_target_module_path;
    size_t export_target_module_path_length;
    uint8_t *export_chain_ids;
    size_t export_chain_count;
} KofunKifFact;

typedef struct {
    uint8_t package_id[KOFUN_KIF_ID_BYTES];
    uint8_t module_id[KOFUN_KIF_ID_BYTES];
    char edition[KOFUN_KIF_MAX_EDITION_BYTES + 1u];

    /* Required. A zero value is not "ordinary"; it fails validation, so a
     * caller that forgets to set it is refused rather than silently writing
     * the more permissive class. */
    KofunKifModuleTrust module_trust;

    KofunKifFact *public_facts;
    size_t public_fact_count;
    KofunKifFact *internal_facts;
    size_t internal_fact_count;

    uint8_t public_semantic_digest[KOFUN_KIF_ID_BYTES];
    uint8_t package_internal_semantic_digest[KOFUN_KIF_ID_BYTES];

    /* Set by the reader. Callers constructing writer input leave it false. */
    bool owns_storage;
} KofunKifInterface;

typedef struct {
    size_t max_envelope_bytes;
    size_t max_record_fields;
    size_t max_facts;
    size_t max_depth;
    size_t max_field_bytes;
} KofunKifLimits;

typedef struct {
    KofunKifStatus status;
    const char *message;
    uint8_t public_semantic_digest[KOFUN_KIF_ID_BYTES];
    uint8_t package_internal_semantic_digest[KOFUN_KIF_ID_BYTES];
} KifWriteResult;

typedef struct {
    KofunKifStatus status;
    const char *message;
    bool rebuild_required;
    KofunKifInterface *interface;
} KifReadResult;

KofunKifLimits kofun_kif_default_limits(void);

KifWriteResult kofun_kif_write(
    const KofunKifInterface *interface,
    const char *destination
);

KifReadResult kofun_kif_read(
    const uint8_t *bytes,
    size_t length,
    KofunKifLimits limits
);

/* RFC-0012's third refusal. The codec cannot see the source, so the
 * contradiction check is exported rather than folded into kofun_kif_read:
 * `source_raw_foreign` is the module table's `trust raw-foreign` fact.
 * Returns false when the source and the artifact disagree, which the caller
 * must treat as rebuild-required — neither side wins. */
bool kofun_kif_trust_agrees(
    const KofunKifInterface *interface,
    bool source_raw_foreign
);

void kofun_kif_destroy(KofunKifInterface *interface);

const char *kofun_kif_status_name(KofunKifStatus status);

#endif
