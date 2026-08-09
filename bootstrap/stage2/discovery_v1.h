#ifndef KOFUN_STAGE2_DISCOVERY_V1_H
#define KOFUN_STAGE2_DISCOVERY_V1_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * `kofun.discovery.request/v1` and `kofun.discovery.result/v1` (#637), as
 * defined by docs/DEVELOPER_DISCOVERY.md.
 *
 * This is the contract layer: it decides whether a request is admissible and
 * emits results whose bytes are canonical. It deliberately holds no compiler
 * state. The projection of types and callable operations plugs in behind
 * `kofun_discovery_result_emit`, so the query semantics stay identical whether
 * the facts arrive from the live in-process analysis or, later, from a
 * validated sidecar (#609).
 *
 * Two rules from the contract shape every signature here:
 *
 *   - `authoritative` is always JSON `false`. A discovery result reports what
 *     the compiler already validated; it never becomes a source of truth, so
 *     there is no way to ask for it to be one.
 *   - The byte caps measure the canonical JSON encoding even when a transport
 *     carries the record some other way, so length checks belong to this module
 *     rather than to a transport.
 */

#define KOFUN_DISCOVERY_REQUEST_SCHEMA "kofun.discovery.request/v1"
#define KOFUN_DISCOVERY_RESULT_SCHEMA "kofun.discovery.result/v1"
#define KOFUN_DISCOVERY_LIMIT_PROFILE "kofun.discovery/default-v1"

/* Exactly 64 lowercase hex characters, per the `Id` scalar. */
#define KOFUN_DISCOVERY_ID_CHARS 64u

#define KOFUN_DISCOVERY_MAX_REQUEST_BYTES (64u * 1024u)
#define KOFUN_DISCOVERY_MAX_RESULT_BYTES (4u * 1024u * 1024u)
#define KOFUN_DISCOVERY_MAX_REQUEST_DEPTH 16u
#define KOFUN_DISCOVERY_MAX_RESULT_DEPTH 64u
#define KOFUN_DISCOVERY_MAX_OPERATIONS 4096u
#define KOFUN_DISCOVERY_MAX_DIAGNOSTICS 256u
#define KOFUN_DISCOVERY_MAX_OMISSIONS 64u
#define KOFUN_DISCOVERY_MAX_SPELLING_BYTES 1024u
#define KOFUN_DISCOVERY_MAX_COMPATIBILITY_BYTES 64u

/* U32 and U53 upper bounds, named so the checks read as the contract does. */
#define KOFUN_DISCOVERY_U32_MAX UINT32_C(4294967295)
#define KOFUN_DISCOVERY_U53_MAX INT64_C(9007199254740991)

typedef enum {
    KOFUN_DISCOVERY_STATUS_COMPLETE = 1,
    KOFUN_DISCOVERY_STATUS_PARTIAL = 2,
    KOFUN_DISCOVERY_STATUS_STALE = 3,
    KOFUN_DISCOVERY_STATUS_UNAVAILABLE = 4,
    KOFUN_DISCOVERY_STATUS_INVALID = 5
} KofunDiscoveryStatus;

/*
 * `ResultReason`, in the contract's order. `KOFUN_DISCOVERY_REASON_NONE`
 * encodes JSON `null`, which `complete` requires and the other statuses forbid.
 */
typedef enum {
    KOFUN_DISCOVERY_REASON_NONE = 0,
    KOFUN_DISCOVERY_REASON_CANCELLED_BEFORE_ANALYSIS = 1,
    KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS = 2,
    KOFUN_DISCOVERY_REASON_INVALID_POSITION = 3,
    KOFUN_DISCOVERY_REASON_INVALID_REQUEST = 4,
    KOFUN_DISCOVERY_REASON_LIMIT_EXHAUSTED = 5,
    KOFUN_DISCOVERY_REASON_STALE_GENERATION = 6,
    KOFUN_DISCOVERY_REASON_STALE_INTERFACE_SET = 7,
    KOFUN_DISCOVERY_REASON_STALE_SEMANTIC_COMPATIBILITY = 8,
    KOFUN_DISCOVERY_REASON_STALE_SOURCE = 9,
    KOFUN_DISCOVERY_REASON_UNSUPPORTED_IN_PROFILE = 10,
    KOFUN_DISCOVERY_REASON_WRONG_FILE = 11
} KofunDiscoveryReason;

typedef enum {
    KOFUN_DISCOVERY_QUERY_TYPE = 1,
    KOFUN_DISCOVERY_QUERY_OPERATIONS = 2,
    KOFUN_DISCOVERY_QUERY_TYPE_AND_OPERATIONS = 3,
    KOFUN_DISCOVERY_QUERY_EXPLAIN_OPERATION = 4
} KofunDiscoveryQueryKind;

typedef struct {
    char file_id[KOFUN_DISCOVERY_ID_CHARS + 1u];
    char source_sha256[KOFUN_DISCOVERY_ID_CHARS + 1u];
    char interface_set_sha256[KOFUN_DISCOVERY_ID_CHARS + 1u];
    char semantic_compatibility[KOFUN_DISCOVERY_MAX_COMPATIBILITY_BYTES + 1u];
    /* U53: the contract permits generations past U32. */
    int64_t generation;
} KofunDiscoveryAnalysisKey;

typedef struct {
    KofunDiscoveryAnalysisKey analysis;
    uint32_t byte_offset;
    uint32_t expression_start;
    uint32_t expression_end;
    KofunDiscoveryQueryKind kind;
    bool include_unavailable;
    /* Empty exactly when the request carried JSON `null`. */
    char spelling[KOFUN_DISCOVERY_MAX_SPELLING_BYTES + 1u];
    bool has_spelling;
} KofunDiscoveryRequest;

/*
 * Parse and validate canonical request bytes.
 *
 * Returns true only for a request that is admissible on every axis the schema
 * fixes: exact schema string, every required field present exactly once, no
 * unknown field, ASCII-lexicographic key order, no floating point, no
 * duplicate key, depth and byte caps, scalar ranges, and
 * `expression.start <= byte_offset <= expression.end`.
 *
 * On failure `*reason` is set to the reason the contract names for that
 * rejection — `invalid-position` when the offsets are individually well formed
 * but inconsistent, and `invalid-request` for every structural failure — so a
 * caller can emit the required `invalid` result without re-deriving why.
 *
 * Whether the offsets fall on UTF-8 code-point boundaries *of the analyzed
 * source* is deliberately not decided here: this module never sees the source.
 * `kofun_discovery_offsets_are_boundaries` is provided for the caller that
 * does.
 */
bool kofun_discovery_request_parse(const char *bytes, size_t length,
                                   KofunDiscoveryRequest *out,
                                   KofunDiscoveryReason *reason);

/*
 * True when all three request offsets land on UTF-8 code-point boundaries
 * within `source`, and the expression span lies inside it. The caller supplies
 * the exact source named by the analysis key.
 */
bool kofun_discovery_offsets_are_boundaries(const KofunDiscoveryRequest *request,
                                            const char *source,
                                            size_t source_length);

/*
 * Emit a canonical `kofun.discovery.result/v1` object followed by one LF.
 *
 * `analysis` is echoed when the status permits it and must be NULL when the
 * status is `invalid`. This entry point covers every status whose shape carries
 * no facts — `stale`, `unavailable`, and `invalid` — which the contract defines
 * as having a null type and empty operations, omissions, and diagnostics.
 * Fact-bearing statuses arrive with the projection.
 *
 * Returns the number of bytes written, or 0 if the buffer is too small or the
 * (status, reason, analysis) triple is not one the contract permits.
 */
size_t kofun_discovery_result_emit_factless(KofunDiscoveryStatus status,
                                            KofunDiscoveryReason reason,
                                            const KofunDiscoveryAnalysisKey *analysis,
                                            char *buffer, size_t capacity);

/* Stable spellings, for diagnostics and tests. */
const char *kofun_discovery_status_name(KofunDiscoveryStatus status);
const char *kofun_discovery_reason_name(KofunDiscoveryReason reason);

/* ---------------------------------------------------------------------- */
/* Facts                                                                   */
/* ---------------------------------------------------------------------- */

/*
 * The current-core slice deliberately covers direct functions and members
 * only. Imports, extensions, traits, and macros are excluded by the issue's
 * own scope, which is why `generic_requirements` and `dependencies` are
 * emitted as empty arrays here rather than modelled: an empty array is what
 * the contract requires for a row that genuinely has none, and inventing a
 * representation for rows this slice cannot produce would be guessing at
 * #293/#316's semantics ahead of them.  `effects` carries the effect
 * requirements the compiler committed for a row — currently the direct `io`
 * fact — and stays empty for a pure row.
 */

#define KOFUN_DISCOVERY_MAX_REJECTION_REASONS 10u
#define KOFUN_DISCOVERY_MAX_NAME_BYTES 256u
#define KOFUN_DISCOVERY_MAX_QUALIFIED_NAME_BYTES 4096u
#define KOFUN_DISCOVERY_MAX_SIGNATURE_BYTES 16384u
#define KOFUN_DISCOVERY_MAX_DISPLAY_BYTES 4096u
#define KOFUN_DISCOVERY_MAX_OPERATION_EFFECTS 8u
#define KOFUN_DISCOVERY_MAX_EFFECT_DISPLAY_BYTES 256u

typedef enum {
    KOFUN_DISCOVERY_FACT_VALIDATED = 1,
    KOFUN_DISCOVERY_FACT_PROVISIONAL = 2,
    KOFUN_DISCOVERY_FACT_ERROR = 3,
    KOFUN_DISCOVERY_FACT_UNAVAILABLE = 4
} KofunDiscoveryFactStatus;

typedef enum {
    KOFUN_DISCOVERY_IDENTITY_NONE = 0,
    KOFUN_DISCOVERY_IDENTITY_MODULE_ID = 1,
    KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID = 2,
    KOFUN_DISCOVERY_IDENTITY_TYPE_ID = 3,
    KOFUN_DISCOVERY_IDENTITY_FILE_ID = 4
} KofunDiscoveryIdentityKind;

typedef struct {
    KofunDiscoveryIdentityKind kind;
    char value[KOFUN_DISCOVERY_ID_CHARS + 1u];
} KofunDiscoveryIdentity;

typedef enum {
    KOFUN_DISCOVERY_FACT_REASON_NONE = 0,
    KOFUN_DISCOVERY_FACT_REASON_CANCELLED_BEFORE_ANALYSIS = 1,
    KOFUN_DISCOVERY_FACT_REASON_INCOMPLETE_ANALYSIS = 2,
    KOFUN_DISCOVERY_FACT_REASON_LIMIT_EXHAUSTED = 3,
    KOFUN_DISCOVERY_FACT_REASON_REJECTED_BY_DIAGNOSTIC = 4,
    KOFUN_DISCOVERY_FACT_REASON_TYPE_NOT_AVAILABLE_IN_CURRENT_SUBSET = 5,
    KOFUN_DISCOVERY_FACT_REASON_UNSUPPORTED_CURRENT_STAGE2_FEATURE = 6
} KofunDiscoveryFactReason;

typedef struct {
    KofunDiscoveryFactStatus status;
    /* Identity is absent unless the type is validated, per the contract. */
    KofunDiscoveryIdentity identity;
    char display[KOFUN_DISCOVERY_MAX_DISPLAY_BYTES + 1u];
    bool has_display;
    KofunDiscoveryFactReason reason;
} KofunDiscoveryTypeFact;

typedef enum {
    KOFUN_DISCOVERY_RECEIVER_NULL = 0,
    KOFUN_DISCOVERY_RECEIVER_READ = 1,
    KOFUN_DISCOVERY_RECEIVER_EDIT = 2,
    KOFUN_DISCOVERY_RECEIVER_TAKE = 3,
    KOFUN_DISCOVERY_RECEIVER_NONE = 4
} KofunDiscoveryReceiverMode;

typedef enum {
    KOFUN_DISCOVERY_ORIGIN_FUNCTION = 1,
    KOFUN_DISCOVERY_ORIGIN_MEMBER = 2
} KofunDiscoveryOriginKind;

typedef enum {
    KOFUN_DISCOVERY_VISIBILITY_PRIVATE = 1,
    KOFUN_DISCOVERY_VISIBILITY_INTERNAL = 2,
    KOFUN_DISCOVERY_VISIBILITY_PUB = 3,
    KOFUN_DISCOVERY_VISIBILITY_RESTRICTED = 4
} KofunDiscoveryVisibility;

/* Sorted ASCII-lexicographically by the emitter, so callers may set them in
 * any order; duplicates are rejected rather than deduplicated silently. */
typedef enum {
    KOFUN_DISCOVERY_REJECT_AMBIGUOUS = 1,
    KOFUN_DISCOVERY_REJECT_INCOMPLETE_ANALYSIS = 2,
    KOFUN_DISCOVERY_REJECT_LIMIT_EXHAUSTED = 3,
    KOFUN_DISCOVERY_REJECT_MISSING_EFFECT = 4,
    KOFUN_DISCOVERY_REJECT_REQUIRES_EDIT = 5,
    KOFUN_DISCOVERY_REJECT_REQUIRES_READ = 6,
    KOFUN_DISCOVERY_REJECT_REQUIRES_TAKE = 7,
    KOFUN_DISCOVERY_REJECT_TYPE_MISMATCH = 8,
    KOFUN_DISCOVERY_REJECT_UNSATISFIED_BOUND = 9,
    KOFUN_DISCOVERY_REJECT_UNSUPPORTED_IN_PROFILE = 10
} KofunDiscoveryRejectionReason;

typedef struct {
    KofunDiscoveryFactStatus status;
    KofunDiscoveryOriginKind kind;
    char module[KOFUN_DISCOVERY_MAX_QUALIFIED_NAME_BYTES + 1u];
    KofunDiscoveryIdentity module_identity;
} KofunDiscoveryOrigin;

/*
 * One `EffectRequirement`. The contract requires `identity`, `display`, and
 * `status`; the identity, when present, is a compiler-issued `SymbolId` or
 * `TypeId`, and `kind = KOFUN_DISCOVERY_IDENTITY_NONE` encodes JSON `null`
 * for a requirement the compiler committed without a symbol of its own —
 * the current direct `io` fact.  Discovery never performs the effect.
 */
typedef struct {
    KofunDiscoveryIdentity identity;
    char display[KOFUN_DISCOVERY_MAX_EFFECT_DISPLAY_BYTES + 1u];
    KofunDiscoveryFactStatus status;
} KofunDiscoveryEffectRequirement;

typedef struct {
    KofunDiscoveryFactStatus status;
    KofunDiscoveryIdentity identity; /* SymbolId */
    char display_name[KOFUN_DISCOVERY_MAX_NAME_BYTES + 1u];
    char qualified_name[KOFUN_DISCOVERY_MAX_QUALIFIED_NAME_BYTES + 1u];
    char signature[KOFUN_DISCOVERY_MAX_SIGNATURE_BYTES + 1u];
    bool has_signature;
    KofunDiscoveryReceiverMode receiver_mode;
    KofunDiscoveryEffectRequirement
        effects[KOFUN_DISCOVERY_MAX_OPERATION_EFFECTS];
    size_t effect_count;
    KofunDiscoveryOrigin origin;
    KofunDiscoveryVisibility visibility;
    bool callable;
    KofunDiscoveryRejectionReason
        rejection_reasons[KOFUN_DISCOVERY_MAX_REJECTION_REASONS];
    size_t rejection_reason_count;
} KofunDiscoveryOperationFact;

typedef enum {
    KOFUN_DISCOVERY_OMISSION_HIDDEN_BY_VISIBILITY = 1,
    KOFUN_DISCOVERY_OMISSION_NOT_IMPORTED = 2,
    KOFUN_DISCOVERY_OMISSION_UNSUPPORTED_IN_PROFILE = 3,
    KOFUN_DISCOVERY_OMISSION_INCOMPLETE_ANALYSIS = 4,
    KOFUN_DISCOVERY_OMISSION_LIMIT_EXHAUSTED = 5
} KofunDiscoveryOmissionReason;

typedef struct {
    KofunDiscoveryOmissionReason reason;
    /* Only `explain-operation` may echo a spelling; a general query uses
     * null. An omission carries nothing else — no count, identity, name,
     * signature, origin, path, span, or documentation. */
    char requested_spelling[KOFUN_DISCOVERY_MAX_SPELLING_BYTES + 1u];
    bool has_requested_spelling;
} KofunDiscoveryOmission;

/*
 * Apply the receiver-mode disclosure rule to a candidate set.
 *
 * A `read` receiver excludes `edit` and `take` operations by default. With
 * `include_unavailable`, those candidates stay as visible rejected rows
 * carrying `requires-edit`/`requires-take` and `availability = unavailable`,
 * which is what "explain them when requested" means: the row is still refused,
 * it just says why instead of vanishing.
 *
 * Rewrites `operations` in place and returns the surviving count.
 */
size_t kofun_discovery_apply_receiver_rule(
    KofunDiscoveryOperationFact *operations, size_t count,
    KofunDiscoveryReceiverMode expression_mode, bool include_unavailable);

/*
 * Emit a canonical fact-bearing result.
 *
 * Enforces the contract's shape invariants and refuses rather than emitting a
 * result that violates one: `complete` requires every fact validated, an empty
 * rejection list on every row, and `truncated = false`; any row that is not
 * callable carries at least one rejection reason; a `type`-kind query emits no
 * operations; and operations are sorted into compiler-key order with duplicate
 * `(SymbolId, implementation)` tuples rejected.
 *
 * Returns bytes written, or 0 on refusal or insufficient capacity.
 */
size_t kofun_discovery_result_emit(
    KofunDiscoveryStatus status, KofunDiscoveryReason reason,
    const KofunDiscoveryAnalysisKey *analysis,
    const KofunDiscoveryTypeFact *type, KofunDiscoveryOperationFact *operations,
    size_t operation_count, KofunDiscoveryOmission *omissions,
    size_t omission_count, bool truncated, char *buffer, size_t capacity);

#endif /* KOFUN_STAGE2_DISCOVERY_V1_H */
