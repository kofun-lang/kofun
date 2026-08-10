#include "discovery_v1.h"

#include <string.h>

/*
 * Canonical bytes are parsed by expecting them literally.
 *
 * The contract does not merely say a request is JSON that happens to be
 * canonical; it says the canonical bytes *are* the encoding, down to key order,
 * two-space indentation, and the single space after `:`. Matching that layout
 * position by position is therefore both the simplest parser and the strictest
 * one: unknown fields, duplicate keys, reordered keys, reindented output, and
 * trailing data cannot survive it, so none of them needs a separate check that
 * could drift from the emitter. A tolerant parser plus a canonicality audit
 * would be two descriptions of one format, and the pair would eventually
 * disagree.
 */

typedef struct {
    const char *bytes;
    size_t length;
    size_t offset;
    bool failed;
} Cursor;

static void expect_literal(Cursor *cursor, const char *text) {
    size_t span;
    if (cursor->failed) {
        return;
    }
    span = strlen(text);
    if (cursor->length - cursor->offset < span ||
        memcmp(cursor->bytes + cursor->offset, text, span) != 0) {
        cursor->failed = true;
        return;
    }
    cursor->offset += span;
}

static bool is_lower_hex(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

/* `Id`: exactly 64 lowercase hex characters between quotes. */
static void expect_id(Cursor *cursor, char *out) {
    size_t index;
    expect_literal(cursor, "\"");
    if (cursor->failed) {
        return;
    }
    if (cursor->length - cursor->offset < KOFUN_DISCOVERY_ID_CHARS) {
        cursor->failed = true;
        return;
    }
    for (index = 0; index < KOFUN_DISCOVERY_ID_CHARS; index++) {
        char c = cursor->bytes[cursor->offset + index];
        if (!is_lower_hex(c)) {
            cursor->failed = true;
            return;
        }
        out[index] = c;
    }
    out[KOFUN_DISCOVERY_ID_CHARS] = '\0';
    cursor->offset += KOFUN_DISCOVERY_ID_CHARS;
    expect_literal(cursor, "\"");
}

/*
 * Base ten, no sign, and no leading zero except the single digit `0`. The
 * bound is passed in so one routine serves both U32 and U53 without letting a
 * U53 value reach a U32 field.
 */
static int64_t expect_integer(Cursor *cursor, int64_t maximum) {
    int64_t value = 0;
    size_t digits = 0;
    if (cursor->failed) {
        return 0;
    }
    while (cursor->offset + digits < cursor->length) {
        char c = cursor->bytes[cursor->offset + digits];
        if (c < '0' || c > '9') {
            break;
        }
        /* Reject before the multiply so an overflow cannot be observed. */
        if (value > (maximum - (c - '0')) / 10) {
            cursor->failed = true;
            return 0;
        }
        value = (value * 10) + (c - '0');
        digits++;
    }
    if (digits == 0) {
        cursor->failed = true;
        return 0;
    }
    if (digits > 1 && cursor->bytes[cursor->offset] == '0') {
        cursor->failed = true;
        return 0;
    }
    cursor->offset += digits;
    return value;
}

static bool expect_bool(Cursor *cursor) {
    if (cursor->failed) {
        return false;
    }
    if (cursor->length - cursor->offset >= 4u &&
        memcmp(cursor->bytes + cursor->offset, "true", 4u) == 0) {
        cursor->offset += 4u;
        return true;
    }
    expect_literal(cursor, "false");
    return false;
}

/*
 * A bounded text scalar. Control characters are rejected outright and the
 * bytes must be well-formed UTF-8; only `\"` and `\\` are accepted as escapes,
 * because the contract emits every other permitted code point literally.
 *
 * NFC is *not* verified here. Doing so needs the normalization tables under
 * `unicode/`, which this module does not link, so a caller holding those tables
 * remains responsible for that half of the `Name`/`Spelling` rule. Rejecting
 * the easy half silently and calling the scalar validated would be worse than
 * saying which half is checked.
 */
static void expect_text(Cursor *cursor, char *out, size_t maximum) {
    size_t written = 0;
    expect_literal(cursor, "\"");
    while (!cursor->failed && cursor->offset < cursor->length) {
        unsigned char c = (unsigned char)cursor->bytes[cursor->offset];
        size_t sequence;
        if (c == '"') {
            cursor->offset++;
            out[written] = '\0';
            return;
        }
        if (c < 0x20u || c == 0x7fu) {
            cursor->failed = true;
            return;
        }
        if (c == '\\') {
            char next;
            if (cursor->offset + 1u >= cursor->length) {
                cursor->failed = true;
                return;
            }
            next = cursor->bytes[cursor->offset + 1u];
            if (next != '"' && next != '\\') {
                cursor->failed = true;
                return;
            }
            if (written + 1u > maximum) {
                cursor->failed = true;
                return;
            }
            out[written++] = next;
            cursor->offset += 2u;
            continue;
        }
        /* UTF-8 well-formedness, including the surrogate and overlong bans. */
        if (c < 0x80u) {
            sequence = 1u;
        } else if ((c & 0xe0u) == 0xc0u && c >= 0xc2u) {
            sequence = 2u;
        } else if ((c & 0xf0u) == 0xe0u) {
            sequence = 3u;
        } else if ((c & 0xf8u) == 0xf0u && c <= 0xf4u) {
            sequence = 4u;
        } else {
            cursor->failed = true;
            return;
        }
        if (cursor->offset + sequence > cursor->length ||
            written + sequence > maximum) {
            cursor->failed = true;
            return;
        }
        {
            size_t index;
            for (index = 1u; index < sequence; index++) {
                unsigned char cont =
                    (unsigned char)cursor->bytes[cursor->offset + index];
                if ((cont & 0xc0u) != 0x80u) {
                    cursor->failed = true;
                    return;
                }
            }
            if (sequence == 3u) {
                unsigned char second =
                    (unsigned char)cursor->bytes[cursor->offset + 1u];
                if (c == 0xe0u && second < 0xa0u) {
                    cursor->failed = true; /* overlong */
                    return;
                }
                if (c == 0xedu && second >= 0xa0u) {
                    cursor->failed = true; /* surrogate */
                    return;
                }
            }
            if (sequence == 4u) {
                unsigned char second =
                    (unsigned char)cursor->bytes[cursor->offset + 1u];
                if (c == 0xf0u && second < 0x90u) {
                    cursor->failed = true; /* overlong */
                    return;
                }
                if (c == 0xf4u && second >= 0x90u) {
                    cursor->failed = true; /* above U+10FFFF */
                    return;
                }
            }
            memcpy(out + written, cursor->bytes + cursor->offset, sequence);
            written += sequence;
            cursor->offset += sequence;
        }
    }
    cursor->failed = true;
}

static KofunDiscoveryQueryKind parse_query_kind(Cursor *cursor) {
    static const struct {
        const char *spelling;
        KofunDiscoveryQueryKind kind;
    } kinds[] = {
        {"\"explain-operation\"", KOFUN_DISCOVERY_QUERY_EXPLAIN_OPERATION},
        {"\"operations\"", KOFUN_DISCOVERY_QUERY_OPERATIONS},
        {"\"type-and-operations\"", KOFUN_DISCOVERY_QUERY_TYPE_AND_OPERATIONS},
        {"\"type\"", KOFUN_DISCOVERY_QUERY_TYPE},
    };
    size_t index;
    if (cursor->failed) {
        return KOFUN_DISCOVERY_QUERY_TYPE;
    }
    for (index = 0; index < sizeof(kinds) / sizeof(kinds[0]); index++) {
        size_t span = strlen(kinds[index].spelling);
        if (cursor->length - cursor->offset >= span &&
            memcmp(cursor->bytes + cursor->offset, kinds[index].spelling,
                   span) == 0) {
            cursor->offset += span;
            return kinds[index].kind;
        }
    }
    cursor->failed = true;
    return KOFUN_DISCOVERY_QUERY_TYPE;
}

bool kofun_discovery_request_parse(const char *bytes, size_t length,
                                   KofunDiscoveryRequest *out,
                                   KofunDiscoveryReason *reason) {
    Cursor cursor;
    int64_t generation;
    int64_t byte_offset;
    int64_t expression_end;
    int64_t expression_start;

    if (out == NULL || reason == NULL) {
        return false;
    }
    *reason = KOFUN_DISCOVERY_REASON_INVALID_REQUEST;
    if (bytes == NULL) {
        return false;
    }
    /* Checked before anything is read, as the limit rule requires. */
    if (length > KOFUN_DISCOVERY_MAX_REQUEST_BYTES) {
        return false;
    }
    memset(out, 0, sizeof(*out));

    cursor.bytes = bytes;
    cursor.length = length;
    cursor.offset = 0;
    cursor.failed = false;

    expect_literal(&cursor, "{\n  \"analysis\": {\n    \"file_id\": ");
    expect_id(&cursor, out->analysis.file_id);
    expect_literal(&cursor, ",\n    \"generation\": ");
    generation = expect_integer(&cursor, KOFUN_DISCOVERY_U53_MAX);
    expect_literal(&cursor, ",\n    \"interface_set_sha256\": ");
    expect_id(&cursor, out->analysis.interface_set_sha256);
    expect_literal(&cursor, ",\n    \"semantic_compatibility\": ");
    expect_text(&cursor, out->analysis.semantic_compatibility,
                KOFUN_DISCOVERY_MAX_COMPATIBILITY_BYTES);
    expect_literal(&cursor, ",\n    \"source_sha256\": ");
    expect_id(&cursor, out->analysis.source_sha256);
    expect_literal(&cursor, "\n  },\n  \"position\": {\n    \"byte_offset\": ");
    byte_offset = expect_integer(&cursor, KOFUN_DISCOVERY_U32_MAX);
    expect_literal(&cursor, ",\n    \"expression\": {\n      \"end\": ");
    expression_end = expect_integer(&cursor, KOFUN_DISCOVERY_U32_MAX);
    expect_literal(&cursor, ",\n      \"start\": ");
    expression_start = expect_integer(&cursor, KOFUN_DISCOVERY_U32_MAX);
    expect_literal(&cursor,
                   "\n    }\n  },\n  \"query\": {\n    "
                   "\"include_unavailable\": ");
    out->include_unavailable = expect_bool(&cursor);
    expect_literal(&cursor, ",\n    \"kind\": ");
    out->kind = parse_query_kind(&cursor);
    expect_literal(&cursor, ",\n    \"spelling\": ");
    if (!cursor.failed && cursor.length - cursor.offset >= 4u &&
        memcmp(cursor.bytes + cursor.offset, "null", 4u) == 0) {
        cursor.offset += 4u;
        out->has_spelling = false;
    } else {
        expect_text(&cursor, out->spelling, KOFUN_DISCOVERY_MAX_SPELLING_BYTES);
        out->has_spelling = true;
        /* `Spelling` is 1-1024 bytes: empty is not a spelling. */
        if (!cursor.failed && out->spelling[0] == '\0') {
            cursor.failed = true;
        }
    }
    expect_literal(&cursor, "\n  },\n  \"schema\": \"");
    expect_literal(&cursor, KOFUN_DISCOVERY_REQUEST_SCHEMA);
    expect_literal(&cursor, "\"\n}\n");

    if (cursor.failed || cursor.offset != length) {
        return false;
    }
    if (out->analysis.semantic_compatibility[0] == '\0') {
        return false;
    }

    /*
     * `spelling` is required non-null only for `explain-operation`, and
     * required null otherwise — a rule in both directions, so echoing a
     * spelling into another query kind is a rejection rather than a value that
     * is quietly ignored.
     */
    if ((out->kind == KOFUN_DISCOVERY_QUERY_EXPLAIN_OPERATION) !=
        out->has_spelling) {
        return false;
    }

    out->analysis.generation = generation;
    out->byte_offset = (uint32_t)byte_offset;
    out->expression_start = (uint32_t)expression_start;
    out->expression_end = (uint32_t)expression_end;

    /*
     * Structurally sound but inconsistent offsets are `invalid-position`, not
     * `invalid-request`; the contract separates them and a client can act on
     * the difference.
     */
    if (expression_start > expression_end || byte_offset < expression_start ||
        byte_offset > expression_end) {
        *reason = KOFUN_DISCOVERY_REASON_INVALID_POSITION;
        return false;
    }

    *reason = KOFUN_DISCOVERY_REASON_NONE;
    return true;
}

static bool is_utf8_boundary(const char *source, size_t source_length,
                             uint32_t offset) {
    if (offset > source_length) {
        return false;
    }
    if (offset == source_length) {
        return true;
    }
    /* A continuation byte is the one position that is not a boundary. */
    return ((unsigned char)source[offset] & 0xc0u) != 0x80u;
}

bool kofun_discovery_offsets_are_boundaries(const KofunDiscoveryRequest *request,
                                            const char *source,
                                            size_t source_length) {
    if (request == NULL || source == NULL) {
        return false;
    }
    if (request->expression_end > source_length) {
        return false;
    }
    return is_utf8_boundary(source, source_length, request->expression_start) &&
           is_utf8_boundary(source, source_length, request->byte_offset) &&
           is_utf8_boundary(source, source_length, request->expression_end);
}

const char *kofun_discovery_status_name(KofunDiscoveryStatus status) {
    switch (status) {
    case KOFUN_DISCOVERY_STATUS_COMPLETE:
        return "complete";
    case KOFUN_DISCOVERY_STATUS_PARTIAL:
        return "partial";
    case KOFUN_DISCOVERY_STATUS_STALE:
        return "stale";
    case KOFUN_DISCOVERY_STATUS_UNAVAILABLE:
        return "unavailable";
    case KOFUN_DISCOVERY_STATUS_INVALID:
        return "invalid";
    default:
        return NULL;
    }
}

const char *kofun_discovery_reason_name(KofunDiscoveryReason reason) {
    switch (reason) {
    case KOFUN_DISCOVERY_REASON_NONE:
        return NULL;
    case KOFUN_DISCOVERY_REASON_CANCELLED_BEFORE_ANALYSIS:
        return "cancelled-before-analysis";
    case KOFUN_DISCOVERY_REASON_INCOMPLETE_CURRENT_FILE_FACTS:
        return "incomplete-current-file-facts";
    case KOFUN_DISCOVERY_REASON_INVALID_POSITION:
        return "invalid-position";
    case KOFUN_DISCOVERY_REASON_INVALID_REQUEST:
        return "invalid-request";
    case KOFUN_DISCOVERY_REASON_LIMIT_EXHAUSTED:
        return "limit-exhausted";
    case KOFUN_DISCOVERY_REASON_STALE_GENERATION:
        return "stale-generation";
    case KOFUN_DISCOVERY_REASON_STALE_INTERFACE_SET:
        return "stale-interface-set";
    case KOFUN_DISCOVERY_REASON_STALE_SEMANTIC_COMPATIBILITY:
        return "stale-semantic-compatibility";
    case KOFUN_DISCOVERY_REASON_STALE_SOURCE:
        return "stale-source";
    case KOFUN_DISCOVERY_REASON_UNSUPPORTED_IN_PROFILE:
        return "unsupported-in-profile";
    case KOFUN_DISCOVERY_REASON_WRONG_FILE:
        return "wrong-file";
    default:
        return NULL;
    }
}

/* A bounded appender: every write is capacity-checked, so truncation is a
 * failure to emit rather than a short result that looks complete. */
typedef struct {
    char *buffer;
    size_t capacity;
    size_t written;
    bool overflowed;
} Sink;

static void put(Sink *sink, const char *text) {
    size_t span;
    if (sink->overflowed) {
        return;
    }
    span = strlen(text);
    if (sink->written + span > sink->capacity) {
        sink->overflowed = true;
        return;
    }
    memcpy(sink->buffer + sink->written, text, span);
    sink->written += span;
}

static void put_u53(Sink *sink, int64_t value) {
    char digits[21];
    size_t index = sizeof(digits);
    if (value == 0) {
        put(sink, "0");
        return;
    }
    digits[--index] = '\0';
    while (value > 0 && index > 0) {
        digits[--index] = (char)('0' + (value % 10));
        value /= 10;
    }
    put(sink, digits + index);
}

/*
 * Which statuses may carry an echoed analysis key, and which must carry a
 * reason. Encoding the table once keeps the emitter from being able to produce
 * a shape the contract forbids.
 */
static bool shape_is_permitted(KofunDiscoveryStatus status,
                               KofunDiscoveryReason reason,
                               const KofunDiscoveryAnalysisKey *analysis) {
    if (kofun_discovery_status_name(status) == NULL) {
        return false;
    }
    switch (status) {
    case KOFUN_DISCOVERY_STATUS_INVALID:
        /* `analysis` and `type` are null; a reason explains the failure. */
        return analysis == NULL && reason != KOFUN_DISCOVERY_REASON_NONE;
    case KOFUN_DISCOVERY_STATUS_STALE:
        return analysis != NULL &&
               (reason == KOFUN_DISCOVERY_REASON_WRONG_FILE ||
                reason == KOFUN_DISCOVERY_REASON_STALE_GENERATION ||
                reason == KOFUN_DISCOVERY_REASON_STALE_INTERFACE_SET ||
                reason ==
                    KOFUN_DISCOVERY_REASON_STALE_SEMANTIC_COMPATIBILITY ||
                reason == KOFUN_DISCOVERY_REASON_STALE_SOURCE);
    case KOFUN_DISCOVERY_STATUS_UNAVAILABLE:
        return analysis != NULL && reason != KOFUN_DISCOVERY_REASON_NONE;
    default:
        /* `complete` and `partial` carry facts and are not emitted here. */
        return false;
    }
}

size_t kofun_discovery_result_emit_factless(
    KofunDiscoveryStatus status, KofunDiscoveryReason reason,
    const KofunDiscoveryAnalysisKey *analysis, char *buffer, size_t capacity) {
    Sink sink;
    const char *reason_name;

    if (buffer == NULL || !shape_is_permitted(status, reason, analysis)) {
        return 0;
    }
    if (capacity > KOFUN_DISCOVERY_MAX_RESULT_BYTES) {
        capacity = KOFUN_DISCOVERY_MAX_RESULT_BYTES;
    }
    reason_name = kofun_discovery_reason_name(reason);

    sink.buffer = buffer;
    sink.capacity = capacity;
    sink.written = 0;
    sink.overflowed = false;

    /* Keys in ASCII lexicographic order, two-space indentation, one per line. */
    put(&sink, "{\n  \"analysis\": ");
    if (analysis == NULL) {
        put(&sink, "null");
    } else {
        put(&sink, "{\n    \"file_id\": \"");
        put(&sink, analysis->file_id);
        put(&sink, "\",\n    \"generation\": ");
        put_u53(&sink, analysis->generation);
        put(&sink, ",\n    \"interface_set_sha256\": \"");
        put(&sink, analysis->interface_set_sha256);
        put(&sink, "\",\n    \"semantic_compatibility\": \"");
        put(&sink, analysis->semantic_compatibility);
        put(&sink, "\",\n    \"source_sha256\": \"");
        put(&sink, analysis->source_sha256);
        put(&sink, "\"\n  }");
    }
    put(&sink, ",\n  \"authoritative\": false,\n  \"diagnostics\": [],\n  "
               "\"limit_profile\": \"" KOFUN_DISCOVERY_LIMIT_PROFILE
               "\",\n  \"omissions\": [],\n  \"operations\": [],\n  "
               "\"reason\": ");
    if (reason_name == NULL) {
        put(&sink, "null");
    } else {
        put(&sink, "\"");
        put(&sink, reason_name);
        put(&sink, "\"");
    }
    put(&sink, ",\n  \"schema\": \"" KOFUN_DISCOVERY_RESULT_SCHEMA
               "\",\n  \"status\": \"");
    put(&sink, kofun_discovery_status_name(status));
    put(&sink, "\",\n  \"truncated\": false,\n  \"type\": null\n}\n");

    if (sink.overflowed) {
        return 0;
    }
    return sink.written;
}

/* ---------------------------------------------------------------------- */
/* Facts                                                                   */
/* ---------------------------------------------------------------------- */

static const char *fact_status_name(KofunDiscoveryFactStatus status) {
    switch (status) {
    case KOFUN_DISCOVERY_FACT_VALIDATED:
        return "validated";
    case KOFUN_DISCOVERY_FACT_PROVISIONAL:
        return "provisional";
    case KOFUN_DISCOVERY_FACT_ERROR:
        return "error";
    case KOFUN_DISCOVERY_FACT_UNAVAILABLE:
        return "unavailable";
    default:
        return NULL;
    }
}

static const char *identity_kind_name(KofunDiscoveryIdentityKind kind) {
    switch (kind) {
    case KOFUN_DISCOVERY_IDENTITY_MODULE_ID:
        return "ModuleId";
    case KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID:
        return "SymbolId";
    case KOFUN_DISCOVERY_IDENTITY_TYPE_ID:
        return "TypeId";
    case KOFUN_DISCOVERY_IDENTITY_FILE_ID:
        return "FileId";
    default:
        return NULL;
    }
}

static const char *fact_reason_name(KofunDiscoveryFactReason reason) {
    switch (reason) {
    case KOFUN_DISCOVERY_FACT_REASON_NONE:
        return NULL;
    case KOFUN_DISCOVERY_FACT_REASON_CANCELLED_BEFORE_ANALYSIS:
        return "cancelled-before-analysis";
    case KOFUN_DISCOVERY_FACT_REASON_INCOMPLETE_ANALYSIS:
        return "incomplete-analysis";
    case KOFUN_DISCOVERY_FACT_REASON_LIMIT_EXHAUSTED:
        return "limit-exhausted";
    case KOFUN_DISCOVERY_FACT_REASON_REJECTED_BY_DIAGNOSTIC:
        return "rejected-by-diagnostic";
    case KOFUN_DISCOVERY_FACT_REASON_TYPE_NOT_AVAILABLE_IN_CURRENT_SUBSET:
        return "type-not-available-in-current-subset";
    case KOFUN_DISCOVERY_FACT_REASON_UNSUPPORTED_CURRENT_STAGE2_FEATURE:
        return "unsupported-current-stage2-feature";
    default:
        return NULL;
    }
}

/* Spellings are already in ASCII order, so the enum doubles as the sort key. */
static const char *rejection_reason_name(KofunDiscoveryRejectionReason reason) {
    switch (reason) {
    case KOFUN_DISCOVERY_REJECT_AMBIGUOUS:
        return "ambiguous";
    case KOFUN_DISCOVERY_REJECT_INCOMPLETE_ANALYSIS:
        return "incomplete-analysis";
    case KOFUN_DISCOVERY_REJECT_LIMIT_EXHAUSTED:
        return "limit-exhausted";
    case KOFUN_DISCOVERY_REJECT_MISSING_EFFECT:
        return "missing-effect";
    case KOFUN_DISCOVERY_REJECT_REQUIRES_EDIT:
        return "requires-edit";
    case KOFUN_DISCOVERY_REJECT_REQUIRES_READ:
        return "requires-read";
    case KOFUN_DISCOVERY_REJECT_REQUIRES_TAKE:
        return "requires-take";
    case KOFUN_DISCOVERY_REJECT_TYPE_MISMATCH:
        return "type-mismatch";
    case KOFUN_DISCOVERY_REJECT_UNSATISFIED_BOUND:
        return "unsatisfied-bound";
    case KOFUN_DISCOVERY_REJECT_UNSUPPORTED_IN_PROFILE:
        return "unsupported-in-profile";
    default:
        return NULL;
    }
}

static const char *receiver_mode_name(KofunDiscoveryReceiverMode mode) {
    switch (mode) {
    case KOFUN_DISCOVERY_RECEIVER_NULL:
        return NULL;
    case KOFUN_DISCOVERY_RECEIVER_READ:
        return "read";
    case KOFUN_DISCOVERY_RECEIVER_EDIT:
        return "edit";
    case KOFUN_DISCOVERY_RECEIVER_TAKE:
        return "take";
    case KOFUN_DISCOVERY_RECEIVER_NONE:
        return "none";
    default:
        return NULL;
    }
}

static const char *visibility_name(KofunDiscoveryVisibility visibility) {
    switch (visibility) {
    case KOFUN_DISCOVERY_VISIBILITY_PRIVATE:
        return "private";
    case KOFUN_DISCOVERY_VISIBILITY_INTERNAL:
        return "internal";
    case KOFUN_DISCOVERY_VISIBILITY_PUB:
        return "pub";
    case KOFUN_DISCOVERY_VISIBILITY_RESTRICTED:
        return "restricted";
    default:
        return NULL;
    }
}

static const char *omission_reason_name(KofunDiscoveryOmissionReason reason) {
    switch (reason) {
    case KOFUN_DISCOVERY_OMISSION_HIDDEN_BY_VISIBILITY:
        return "hidden-by-visibility";
    case KOFUN_DISCOVERY_OMISSION_NOT_IMPORTED:
        return "not-imported";
    case KOFUN_DISCOVERY_OMISSION_UNSUPPORTED_IN_PROFILE:
        return "unsupported-in-profile";
    case KOFUN_DISCOVERY_OMISSION_INCOMPLETE_ANALYSIS:
        return "incomplete-analysis";
    case KOFUN_DISCOVERY_OMISSION_LIMIT_EXHAUSTED:
        return "limit-exhausted";
    default:
        return NULL;
    }
}

static bool add_rejection(KofunDiscoveryOperationFact *operation,
                          KofunDiscoveryRejectionReason reason) {
    size_t index;
    for (index = 0; index < operation->rejection_reason_count; index++) {
        if (operation->rejection_reasons[index] == reason) {
            return true; /* already present; the set stays duplicate-free */
        }
    }
    if (operation->rejection_reason_count >=
        KOFUN_DISCOVERY_MAX_REJECTION_REASONS) {
        return false;
    }
    operation->rejection_reasons[operation->rejection_reason_count++] = reason;
    return true;
}

size_t kofun_discovery_apply_receiver_rule(
    KofunDiscoveryOperationFact *operations, size_t count,
    KofunDiscoveryReceiverMode expression_mode, bool include_unavailable) {
    size_t read = 0;
    size_t written = 0;

    if (operations == NULL) {
        return 0;
    }
    /*
     * Only a `read` expression narrows the set. An `edit` receiver may still
     * call `read` operations, and `take` consumes the value outright, so
     * neither is filtered here.
     */
    if (expression_mode != KOFUN_DISCOVERY_RECEIVER_READ) {
        return count;
    }

    for (read = 0; read < count; read++) {
        KofunDiscoveryOperationFact *operation = &operations[read];
        KofunDiscoveryRejectionReason reason;

        if (operation->receiver_mode == KOFUN_DISCOVERY_RECEIVER_EDIT) {
            reason = KOFUN_DISCOVERY_REJECT_REQUIRES_EDIT;
        } else if (operation->receiver_mode == KOFUN_DISCOVERY_RECEIVER_TAKE) {
            reason = KOFUN_DISCOVERY_REJECT_REQUIRES_TAKE;
        } else {
            operations[written++] = *operation;
            continue;
        }

        /* Dropped entirely unless the client asked to be told why. */
        if (!include_unavailable) {
            continue;
        }
        operation->callable = false;
        if (!add_rejection(operation, reason)) {
            continue;
        }
        operations[written++] = *operation;
    }
    return written;
}

/* Raw identity bytes order before any display text, so a plain byte compare
 * over the hex value is the documented key. */
static int compare_operations(const KofunDiscoveryOperationFact *left,
                              const KofunDiscoveryOperationFact *right) {
    int order = strcmp(left->identity.value, right->identity.value);
    if (order != 0) {
        return order;
    }
    order = strcmp(left->qualified_name, right->qualified_name);
    if (order != 0) {
        return order;
    }
    return strcmp(left->signature, right->signature);
}

static void sort_operations(KofunDiscoveryOperationFact *operations,
                            size_t count) {
    size_t index;
    /* Insertion sort: n is bounded by the 4,096-row limit and the arrays are
     * near-sorted in practice, so this keeps the ordering rule readable
     * without pulling in a comparator indirection. */
    for (index = 1; index < count; index++) {
        KofunDiscoveryOperationFact pivot = operations[index];
        size_t scan = index;
        while (scan > 0 && compare_operations(&operations[scan - 1], &pivot) > 0) {
            operations[scan] = operations[scan - 1];
            scan--;
        }
        operations[scan] = pivot;
    }
}

static void sort_rejections(KofunDiscoveryRejectionReason *reasons,
                            size_t count) {
    size_t index;
    for (index = 1; index < count; index++) {
        KofunDiscoveryRejectionReason pivot = reasons[index];
        size_t scan = index;
        while (scan > 0 && reasons[scan - 1] > pivot) {
            reasons[scan] = reasons[scan - 1];
            scan--;
        }
        reasons[scan] = pivot;
    }
}

static void sort_omissions(KofunDiscoveryOmission *omissions, size_t count) {
    size_t index;
    for (index = 1; index < count; index++) {
        KofunDiscoveryOmission pivot = omissions[index];
        size_t scan = index;
        while (scan > 0 &&
               (omissions[scan - 1].reason > pivot.reason ||
                (omissions[scan - 1].reason == pivot.reason &&
                 strcmp(omissions[scan - 1].requested_spelling,
                        pivot.requested_spelling) > 0))) {
            omissions[scan] = omissions[scan - 1];
            scan--;
        }
        omissions[scan] = pivot;
    }
}

/* Effects sort with non-null compiler identity `(kind, value)` first, then
 * null identities by display bytes. The enum doubles as the kind key only
 * because an effect identity is restricted to `SymbolId` and `TypeId`, whose
 * enum order happens to match their ASCII order; that is not true of the
 * identity-kind enum in general, so admitting a third kind here means
 * choosing the key deliberately rather than inheriting this one. */
static int compare_effects(const KofunDiscoveryEffectRequirement *left,
                           const KofunDiscoveryEffectRequirement *right) {
    bool left_identified = left->identity.kind != KOFUN_DISCOVERY_IDENTITY_NONE;
    bool right_identified =
        right->identity.kind != KOFUN_DISCOVERY_IDENTITY_NONE;
    int order;
    if (left_identified != right_identified) {
        return left_identified ? -1 : 1;
    }
    if (left_identified) {
        if (left->identity.kind != right->identity.kind) {
            return left->identity.kind < right->identity.kind ? -1 : 1;
        }
        order = strcmp(left->identity.value, right->identity.value);
        if (order != 0) {
            return order;
        }
    }
    return strcmp(left->display, right->display);
}

static void sort_effects(KofunDiscoveryEffectRequirement *effects,
                         size_t count) {
    size_t index;
    for (index = 1; index < count; index++) {
        KofunDiscoveryEffectRequirement pivot = effects[index];
        size_t scan = index;
        while (scan > 0 && compare_effects(&effects[scan - 1], &pivot) > 0) {
            effects[scan] = effects[scan - 1];
            scan--;
        }
        effects[scan] = pivot;
    }
}

/*
 * The invariants that make a fact-bearing result well formed. Checking them
 * here rather than trusting each caller is the point: a provider that gets one
 * wrong gets no output, instead of output that a client would believe.
 */
static bool facts_are_permitted(KofunDiscoveryStatus status,
                                KofunDiscoveryReason reason,
                                const KofunDiscoveryAnalysisKey *analysis,
                                const KofunDiscoveryTypeFact *type,
                                const KofunDiscoveryOperationFact *operations,
                                size_t operation_count, size_t omission_count,
                                bool truncated) {
    size_t index;

    if (analysis == NULL) {
        return false;
    }
    if (operation_count > KOFUN_DISCOVERY_MAX_OPERATIONS ||
        omission_count > KOFUN_DISCOVERY_MAX_OMISSIONS) {
        return false;
    }
    if (status != KOFUN_DISCOVERY_STATUS_COMPLETE &&
        status != KOFUN_DISCOVERY_STATUS_PARTIAL) {
        return false;
    }
    if (status == KOFUN_DISCOVERY_STATUS_COMPLETE) {
        /* `complete` fixes reason to null and truncated to false. */
        if (reason != KOFUN_DISCOVERY_REASON_NONE || truncated) {
            return false;
        }
    } else if (operation_count == 0 && omission_count == 0 && type == NULL) {
        /* `partial` must still carry at least one useful fact. */
        return false;
    }

    if (type != NULL) {
        bool validated = type->status == KOFUN_DISCOVERY_FACT_VALIDATED;
        if (fact_status_name(type->status) == NULL) {
            return false;
        }
        if (validated) {
            /* Validated: TypeId identity, non-null display, null reason. */
            if (type->identity.kind != KOFUN_DISCOVERY_IDENTITY_TYPE_ID ||
                !type->has_display ||
                type->reason != KOFUN_DISCOVERY_FACT_REASON_NONE) {
                return false;
            }
        } else {
            /* Everything else: no identity, and a reason that explains it. */
            if (type->identity.kind != KOFUN_DISCOVERY_IDENTITY_NONE ||
                type->reason == KOFUN_DISCOVERY_FACT_REASON_NONE) {
                return false;
            }
            if (type->status == KOFUN_DISCOVERY_FACT_UNAVAILABLE &&
                type->has_display) {
                return false;
            }
        }
        if (status == KOFUN_DISCOVERY_STATUS_COMPLETE && !validated) {
            return false;
        }
    }

    for (index = 0; index < operation_count; index++) {
        const KofunDiscoveryOperationFact *operation = &operations[index];
        bool validated = operation->status == KOFUN_DISCOVERY_FACT_VALIDATED;
        size_t effect_index;

        if (fact_status_name(operation->status) == NULL ||
            identity_kind_name(operation->identity.kind) == NULL ||
            visibility_name(operation->visibility) == NULL ||
            operation->identity.kind != KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID) {
            return false;
        }
        if (operation->display_name[0] == '\0' ||
            operation->qualified_name[0] == '\0') {
            return false;
        }
        if (operation->origin.kind != KOFUN_DISCOVERY_ORIGIN_FUNCTION &&
            operation->origin.kind != KOFUN_DISCOVERY_ORIGIN_MEMBER) {
            return false;
        }
        if (operation->origin.module_identity.kind !=
            KOFUN_DISCOVERY_IDENTITY_MODULE_ID) {
            return false;
        }
        /* Effects: a required display, a closed status vocabulary, an
         * identity that is absent or compiler-issued, a duplicate-free
         * sorted set, and — on a callable row — nothing short of
         * validated. */
        if (operation->effect_count > KOFUN_DISCOVERY_MAX_OPERATION_EFFECTS) {
            return false;
        }
        for (effect_index = 0; effect_index < operation->effect_count;
             effect_index++) {
            const KofunDiscoveryEffectRequirement *effect =
                &operation->effects[effect_index];
            if (fact_status_name(effect->status) == NULL ||
                effect->display[0] == '\0') {
                return false;
            }
            if (effect->identity.kind != KOFUN_DISCOVERY_IDENTITY_NONE &&
                effect->identity.kind != KOFUN_DISCOVERY_IDENTITY_SYMBOL_ID &&
                effect->identity.kind != KOFUN_DISCOVERY_IDENTITY_TYPE_ID) {
                return false;
            }
            /*
             * Sorted, and unique — but unique *by identity* when one is
             * present, which is stricter than the sort key. Two requirements
             * sharing a compiler identity are the same requirement however
             * differently they render, so comparing the whole key would let
             * `SymbolId eee…/"io.read"` and `SymbolId eee…/"io.write"` sit
             * adjacent, compare unequal, and both be emitted.
             */
            if (effect_index > 0) {
                const KofunDiscoveryEffectRequirement *previous =
                    &operation->effects[effect_index - 1];
                if (compare_effects(previous, effect) >= 0) {
                    return false;
                }
                if (effect->identity.kind != KOFUN_DISCOVERY_IDENTITY_NONE &&
                    previous->identity.kind == effect->identity.kind &&
                    strcmp(previous->identity.value,
                           effect->identity.value) == 0) {
                    return false;
                }
            }
            if (operation->callable &&
                effect->status != KOFUN_DISCOVERY_FACT_VALIDATED) {
                return false;
            }
        }
        /* A callable row needs a validated origin, a signature, a receiver
         * mode, and no rejections. */
        if (operation->callable) {
            if (!validated ||
                operation->origin.status != KOFUN_DISCOVERY_FACT_VALIDATED ||
                !operation->has_signature ||
                operation->receiver_mode == KOFUN_DISCOVERY_RECEIVER_NULL ||
                operation->rejection_reason_count != 0) {
                return false;
            }
        } else if (operation->rejection_reason_count == 0) {
            /* Every unavailable row explains itself. */
            return false;
        }
        /* Non-validated rows cannot claim to be callable. */
        if (!validated && operation->callable) {
            return false;
        }
        if (status == KOFUN_DISCOVERY_STATUS_COMPLETE &&
            (!validated || !operation->callable)) {
            return false;
        }
        if (operation->rejection_reason_count >
            KOFUN_DISCOVERY_MAX_REJECTION_REASONS) {
            return false;
        }
        /* Rows are unique by SymbolId; this slice has no implementation
         * identity to break ties with. */
        if (index > 0 && strcmp(operations[index - 1].identity.value,
                                operation->identity.value) == 0) {
            return false;
        }
    }
    return true;
}

static void put_identity(Sink *sink, const char *indent,
                         const KofunDiscoveryIdentity *identity) {
    put(sink, "{\n");
    put(sink, indent);
    put(sink, "  \"kind\": \"");
    put(sink, identity_kind_name(identity->kind));
    put(sink, "\",\n");
    put(sink, indent);
    put(sink, "  \"value\": \"");
    put(sink, identity->value);
    put(sink, "\"\n");
    put(sink, indent);
    put(sink, "}");
}

static void put_analysis(Sink *sink, const KofunDiscoveryAnalysisKey *analysis) {
    put(sink, "{\n    \"file_id\": \"");
    put(sink, analysis->file_id);
    put(sink, "\",\n    \"generation\": ");
    put_u53(sink, analysis->generation);
    put(sink, ",\n    \"interface_set_sha256\": \"");
    put(sink, analysis->interface_set_sha256);
    put(sink, "\",\n    \"semantic_compatibility\": \"");
    put(sink, analysis->semantic_compatibility);
    put(sink, "\",\n    \"source_sha256\": \"");
    put(sink, analysis->source_sha256);
    put(sink, "\"\n  }");
}

static void put_operation(Sink *sink,
                          const KofunDiscoveryOperationFact *operation) {
    size_t index;
    const char *receiver = receiver_mode_name(operation->receiver_mode);

    /* Keys in ASCII lexicographic order. */
    put(sink, "{\n      \"availability\": \"");
    put(sink, operation->callable ? "callable" : "unavailable");
    put(sink, "\",\n      \"dependencies\": [],\n      \"diagnostic_ids\": "
              "[],\n      \"display_name\": \"");
    put(sink, operation->display_name);
    put(sink, "\",\n      \"documentation\": null,\n      \"effects\": ");
    if (operation->effect_count == 0) {
        put(sink, "[]");
    } else {
        put(sink, "[\n");
        for (index = 0; index < operation->effect_count; index++) {
            const KofunDiscoveryEffectRequirement *effect =
                &operation->effects[index];
            put(sink, "        {\n          \"display\": \"");
            put(sink, effect->display);
            put(sink, "\",\n          \"identity\": ");
            if (effect->identity.kind == KOFUN_DISCOVERY_IDENTITY_NONE) {
                put(sink, "null");
            } else {
                put_identity(sink, "          ", &effect->identity);
            }
            put(sink, ",\n          \"status\": \"");
            put(sink, fact_status_name(effect->status));
            put(sink, "\"\n        }");
            put(sink, index + 1u < operation->effect_count ? ",\n" : "\n");
        }
        put(sink, "      ]");
    }
    put(sink, ",\n      \"generic_requirements\": [],\n      "
              "\"identity\": ");
    put_identity(sink, "      ", &operation->identity);
    put(sink, ",\n      \"origin\": {\n        \"implementation_identity\": "
              "null,\n        \"kind\": \"");
    put(sink, operation->origin.kind == KOFUN_DISCOVERY_ORIGIN_FUNCTION
                  ? "function"
                  : "member");
    put(sink, "\",\n        \"module\": \"");
    put(sink, operation->origin.module);
    put(sink, "\",\n        \"module_identity\": ");
    put_identity(sink, "        ", &operation->origin.module_identity);
    put(sink, ",\n        \"status\": \"");
    put(sink, fact_status_name(operation->origin.status));
    put(sink, "\",\n        \"trait\": null,\n        \"trait_identity\": "
              "null\n      },\n      \"qualified_name\": \"");
    put(sink, operation->qualified_name);
    put(sink, "\",\n      \"receiver_mode\": ");
    if (receiver == NULL) {
        put(sink, "null");
    } else {
        put(sink, "\"");
        put(sink, receiver);
        put(sink, "\"");
    }
    put(sink, ",\n      \"rejection_reasons\": ");
    if (operation->rejection_reason_count == 0) {
        put(sink, "[]");
    } else {
        put(sink, "[\n");
        for (index = 0; index < operation->rejection_reason_count; index++) {
            put(sink, "        \"");
            put(sink, rejection_reason_name(operation->rejection_reasons[index]));
            put(sink, index + 1u < operation->rejection_reason_count ? "\",\n"
                                                                    : "\"\n");
        }
        put(sink, "      ]");
    }
    put(sink, ",\n      \"signature\": ");
    if (operation->has_signature) {
        put(sink, "\"");
        put(sink, operation->signature);
        put(sink, "\"");
    } else {
        put(sink, "null");
    }
    put(sink, ",\n      \"source\": null,\n      \"status\": \"");
    put(sink, fact_status_name(operation->status));
    put(sink, "\",\n      \"visibility\": \"");
    put(sink, visibility_name(operation->visibility));
    put(sink, "\"\n    }");
}

size_t kofun_discovery_result_emit(
    KofunDiscoveryStatus status, KofunDiscoveryReason reason,
    const KofunDiscoveryAnalysisKey *analysis,
    const KofunDiscoveryTypeFact *type, KofunDiscoveryOperationFact *operations,
    size_t operation_count, KofunDiscoveryOmission *omissions,
    size_t omission_count, bool truncated, char *buffer, size_t capacity) {
    Sink sink;
    size_t index;
    const char *reason_name;

    if (buffer == NULL || (operation_count > 0 && operations == NULL) ||
        (omission_count > 0 && omissions == NULL)) {
        return 0;
    }

    /* Ordering first: uniqueness is checked against sorted neighbours. */
    for (index = 0; index < operation_count; index++) {
        sort_rejections(operations[index].rejection_reasons,
                        operations[index].rejection_reason_count);
        if (operations[index].effect_count <=
            KOFUN_DISCOVERY_MAX_OPERATION_EFFECTS) {
            sort_effects(operations[index].effects,
                         operations[index].effect_count);
        }
    }
    sort_operations(operations, operation_count);
    sort_omissions(omissions, omission_count);

    if (!facts_are_permitted(status, reason, analysis, type, operations,
                             operation_count, omission_count, truncated)) {
        return 0;
    }
    if (capacity > KOFUN_DISCOVERY_MAX_RESULT_BYTES) {
        capacity = KOFUN_DISCOVERY_MAX_RESULT_BYTES;
    }
    reason_name = kofun_discovery_reason_name(reason);

    sink.buffer = buffer;
    sink.capacity = capacity;
    sink.written = 0;
    sink.overflowed = false;

    put(&sink, "{\n  \"analysis\": ");
    put_analysis(&sink, analysis);
    put(&sink, ",\n  \"authoritative\": false,\n  \"diagnostics\": [],\n  "
               "\"limit_profile\": \"" KOFUN_DISCOVERY_LIMIT_PROFILE
               "\",\n  \"omissions\": ");
    if (omission_count == 0) {
        put(&sink, "[]");
    } else {
        put(&sink, "[\n");
        for (index = 0; index < omission_count; index++) {
            put(&sink, "    {\n      \"reason\": \"");
            put(&sink, omission_reason_name(omissions[index].reason));
            put(&sink, "\",\n      \"requested_spelling\": ");
            if (omissions[index].has_requested_spelling) {
                put(&sink, "\"");
                put(&sink, omissions[index].requested_spelling);
                put(&sink, "\"");
            } else {
                put(&sink, "null");
            }
            put(&sink, "\n    }");
            put(&sink, index + 1u < omission_count ? ",\n" : "\n");
        }
        put(&sink, "  ]");
    }
    put(&sink, ",\n  \"operations\": ");
    if (operation_count == 0) {
        put(&sink, "[]");
    } else {
        put(&sink, "[\n");
        for (index = 0; index < operation_count; index++) {
            put(&sink, "    ");
            put_operation(&sink, &operations[index]);
            put(&sink, index + 1u < operation_count ? ",\n" : "\n");
        }
        put(&sink, "  ]");
    }
    put(&sink, ",\n  \"reason\": ");
    if (reason_name == NULL) {
        put(&sink, "null");
    } else {
        put(&sink, "\"");
        put(&sink, reason_name);
        put(&sink, "\"");
    }
    put(&sink, ",\n  \"schema\": \"" KOFUN_DISCOVERY_RESULT_SCHEMA
               "\",\n  \"status\": \"");
    put(&sink, kofun_discovery_status_name(status));
    put(&sink, "\",\n  \"truncated\": ");
    put(&sink, truncated ? "true" : "false");
    put(&sink, ",\n  \"type\": ");
    if (type == NULL) {
        put(&sink, "null");
    } else {
        const char *type_reason = fact_reason_name(type->reason);
        put(&sink, "{\n    \"dependencies\": [],\n    \"diagnostic_ids\": "
                   "[],\n    \"display\": ");
        if (type->has_display) {
            put(&sink, "\"");
            put(&sink, type->display);
            put(&sink, "\"");
        } else {
            put(&sink, "null");
        }
        put(&sink, ",\n    \"identity\": ");
        if (type->identity.kind == KOFUN_DISCOVERY_IDENTITY_NONE) {
            put(&sink, "null");
        } else {
            put_identity(&sink, "    ", &type->identity);
        }
        put(&sink, ",\n    \"reason\": ");
        if (type_reason == NULL) {
            put(&sink, "null");
        } else {
            put(&sink, "\"");
            put(&sink, type_reason);
            put(&sink, "\"");
        }
        put(&sink, ",\n    \"status\": \"");
        put(&sink, fact_status_name(type->status));
        put(&sink, "\"\n  }");
    }
    put(&sink, "\n}\n");

    if (sink.overflowed) {
        return 0;
    }
    return sink.written;
}
