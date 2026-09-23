#define _POSIX_C_SOURCE 200809L

#include "semantic_events.h"
#include "sha256.h"
#include "../../vendor/utf8proc/utf8proc.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

enum {
    KSE_EVENT_SOURCE = 1,
    KSE_EVENT_NODE = 2,
    KSE_EVENT_IDENTITY = 3,
    KSE_EVENT_REFERENCE = 4,
    KSE_EVENT_FACT = 5,
    KSE_EVENT_DIAGNOSTIC = 6,
    KSE_EVENT_END = 7
};

enum {
    KSE_WIRE_BYTES = 1,
    KSE_WIRE_UTF8 = 2,
    KSE_WIRE_ID = 3,
    KSE_WIRE_U8 = 4,
    KSE_WIRE_U32 = 5,
    KSE_WIRE_U64 = 6,
    KSE_WIRE_SPAN = 7,
    KSE_WIRE_ID_LIST = 8,
    KSE_WIRE_U32_LIST = 9
};

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} ByteBuffer;

typedef struct {
    uint8_t kind;
    uint8_t subtype;
    KofunSemanticStatus status;
    KofunSemanticId id;
    KofunSemanticId owner;
    uint32_t relation_offset;
    uint16_t dependency_count;
    uint16_t diagnostic_count;
    bool has_reason;
} RecordMeta;

struct KofunSemanticStream {
    ByteBuffer events;
    ByteBuffer final;
    RecordMeta *records;
    size_t record_count;
    size_t record_capacity;
    KofunSemanticId *relations;
    size_t relation_count;
    size_t relation_capacity;
    uint64_t source_bytes;
    KofunSemanticId source_file_id;
    uint8_t compiler_exit_class;
    uint8_t phase;
    uint8_t last_fact_kind;
    bool began;
    bool ended;
    bool ready;
    bool cancellation_observed;
    bool failed;
    bool has_error_diagnostic;
    KofunSemanticError error;
};

static uint16_t load_u16be(const uint8_t *bytes) {
    return (uint16_t)(((uint16_t)bytes[0] << 8u) | bytes[1]);
}

static uint32_t load_u32be(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24u) |
        ((uint32_t)bytes[1] << 16u) |
        ((uint32_t)bytes[2] << 8u) |
        (uint32_t)bytes[3];
}

static uint64_t load_u64be(const uint8_t *bytes) {
    uint64_t value = 0;
    size_t index;
    for (index = 0; index < 8u; index += 1u) {
        value = (value << 8u) | bytes[index];
    }
    return value;
}

static void store_u16be(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)(value >> 8u);
    bytes[1] = (uint8_t)value;
}

static void store_u32be(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24u);
    bytes[1] = (uint8_t)(value >> 16u);
    bytes[2] = (uint8_t)(value >> 8u);
    bytes[3] = (uint8_t)value;
}

static void store_u64be(uint8_t *bytes, uint64_t value) {
    size_t index;
    for (index = 0; index < 8u; index += 1u) {
        bytes[7u - index] = (uint8_t)(value >> (index * 8u));
    }
}

static bool buffer_reserve(ByteBuffer *buffer, size_t extra) {
    size_t needed;
    size_t capacity;
    uint8_t *bytes;
    if (extra > SIZE_MAX - buffer->length) return false;
    needed = buffer->length + extra;
    if (needed > KOFUN_SEMANTIC_MAX_EVENT_BYTES + 48u) return false;
    if (needed <= buffer->capacity) return true;
    capacity = buffer->capacity == 0u ? 256u : buffer->capacity;
    while (capacity < needed) {
        if (capacity > (KOFUN_SEMANTIC_MAX_EVENT_BYTES + 48u) / 2u) {
            capacity = KOFUN_SEMANTIC_MAX_EVENT_BYTES + 48u;
            break;
        }
        capacity *= 2u;
    }
    bytes = (uint8_t *)realloc(buffer->bytes, capacity);
    if (bytes == NULL) return false;
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return true;
}

static bool buffer_append(
    ByteBuffer *buffer,
    const void *bytes,
    size_t length
) {
    if (!buffer_reserve(buffer, length)) return false;
    if (length != 0u) {
        memcpy(buffer->bytes + buffer->length, bytes, length);
    }
    buffer->length += length;
    return true;
}

static bool id_is_zero(const KofunSemanticId *id) {
    uint8_t value = 0;
    size_t index;
    for (index = 0; index < KOFUN_SEMANTIC_ID_BYTES; index += 1u) {
        value |= id->bytes[index];
    }
    return value == 0u;
}

static bool id_equal(
    const KofunSemanticId *left,
    const KofunSemanticId *right
) {
    return memcmp(
        left->bytes,
        right->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    ) == 0;
}

bool kofun_semantic_validate_text(KofunSemanticBytes text) {
    utf8proc_uint8_t *normalized = NULL;
    utf8proc_ssize_t result;
    bool same;
    uint32_t index;
    if (text.length > KOFUN_SEMANTIC_MAX_TEXT_BYTES) return false;
    if (text.length != 0u && text.bytes == NULL) return false;
    for (index = 0; index < text.length; index += 1u) {
        if (text.bytes[index] == 0u) return false;
    }
    result = utf8proc_map(
        text.bytes,
        (utf8proc_ssize_t)text.length,
        &normalized,
        UTF8PROC_STABLE | UTF8PROC_COMPOSE
    );
    if (result < 0) {
        free(normalized);
        return false;
    }
    same = (uint64_t)result == text.length &&
        (text.length == 0u ||
         memcmp(normalized, text.bytes, text.length) == 0);
    free(normalized);
    return same;
}

static bool semantic_bytes_equal_cstr(
    KofunSemanticBytes value,
    const char *expected
) {
    size_t expected_length = strlen(expected);
    return value.length == expected_length &&
        (expected_length == 0u ||
         memcmp(value.bytes, expected, expected_length) == 0);
}

static bool valid_public_reason(KofunSemanticBytes reason) {
    return semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_UNRESOLVED_STAGE2_REFERENCE
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_TYPE_UNAVAILABLE
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_MOVE_AFTER_BORROW
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_VISIBILITY_RESTRICTED
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_UNSUPPORTED_STAGE2_FEATURE
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_CANCELLED_BEFORE_ANALYSIS
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_EFFECT_IO_CALLEE
        ) ||
        semantic_bytes_equal_cstr(
            reason,
            KOFUN_SEMANTIC_REASON_EFFECT_IO_ROOT_PRINT
        );
}

bool kofun_semantic_validate_logical_path(KofunSemanticBytes path) {
    uint32_t index;
    uint32_t component_start = 0u;
    size_t cursor = 0u;
    if (path.length == 0u || !kofun_semantic_validate_text(path)) {
        return false;
    }
    if (path.bytes[0] == '/' || path.bytes[0] == '\\') return false;
    /* A leading URI scheme is [A-Za-z][A-Za-z0-9+.-]*:. This also
     * rejects drive prefixes, without rejecting relative names like 1:x. */
    if ((path.bytes[0] >= 'A' && path.bytes[0] <= 'Z') ||
        (path.bytes[0] >= 'a' && path.bytes[0] <= 'z')) {
        for (index = 1u; index < path.length; index += 1u) {
            uint8_t value = path.bytes[index];
            if (value == ':') return false;
            if (!((value >= 'A' && value <= 'Z') ||
                  (value >= 'a' && value <= 'z') ||
                  (value >= '0' && value <= '9') ||
                  value == '+' || value == '.' || value == '-')) {
                break;
            }
        }
    }
    while (cursor < path.length) {
        utf8proc_int32_t codepoint = 0;
        utf8proc_ssize_t width = utf8proc_iterate(
            path.bytes + cursor,
            (utf8proc_ssize_t)(path.length - cursor),
            &codepoint
        );
        utf8proc_category_t category;
        if (width <= 0) return false;
        category = utf8proc_category(codepoint);
        if (category == UTF8PROC_CATEGORY_CC ||
            category == UTF8PROC_CATEGORY_CF ||
            category == UTF8PROC_CATEGORY_ZL ||
            category == UTF8PROC_CATEGORY_ZP) {
            return false;
        }
        cursor += (size_t)width;
    }
    for (index = 0u; index <= path.length; index += 1u) {
        if (index < path.length && path.bytes[index] == '\\') return false;
        if (index == path.length || path.bytes[index] == '/') {
            uint32_t component_length = index - component_start;
            if (component_length == 0u ||
                (component_length == 1u &&
                 path.bytes[component_start] == '.') ||
                (component_length == 2u &&
                 path.bytes[component_start] == '.' &&
                 path.bytes[component_start + 1u] == '.')) {
                return false;
            }
            component_start = index + 1u;
        }
    }
    return true;
}

static bool valid_status(KofunSemanticStatus status) {
    return status >= KOFUN_SEMANTIC_VALIDATED &&
        status <= KOFUN_SEMANTIC_UNAVAILABLE;
}

static bool reference_kind_matches_namespace(
    KofunSemanticNamespace name_space,
    KofunSemanticIdentityKind target_kind
) {
    if (name_space == KOFUN_SEMANTIC_NAMESPACE_VALUE) {
        return target_kind == KOFUN_SEMANTIC_ID_BINDING ||
            target_kind == KOFUN_SEMANTIC_ID_SYMBOL;
    }
    if (name_space == KOFUN_SEMANTIC_NAMESPACE_TYPE) {
        return target_kind == KOFUN_SEMANTIC_ID_TYPE;
    }
    if (name_space == KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR) {
        return target_kind == KOFUN_SEMANTIC_ID_CONSTRUCTOR;
    }
    return false;
}

static bool valid_span(
    const KofunSemanticStream *stream,
    KofunSemanticSpan span
) {
    return span.start <= span.end && span.end <= stream->source_bytes;
}

static bool set_error(
    KofunSemanticStream *stream,
    const char *code,
    uint8_t kind,
    const char *detail
) {
    if (!stream->failed) {
        size_t length;
        stream->failed = true;
        memset(&stream->error, 0, sizeof(stream->error));
        (void)snprintf(stream->error.code, sizeof(stream->error.code), "%s", code);
        stream->error.record_index = (uint32_t)stream->record_count;
        stream->error.event_kind = kind;
        length = strlen(detail);
        if (length >= sizeof(stream->error.detail)) {
            length = sizeof(stream->error.detail) - 1u;
        }
        memcpy(stream->error.detail, detail, length);
        stream->error.detail[length] = '\0';
    }
    stream->ready = false;
    return false;
}

static bool ensure_event(
    KofunSemanticStream *stream,
    uint8_t kind,
    uint8_t minimum_phase
) {
    if (stream == NULL || stream->failed || stream->ended) return false;
    if (!stream->began && kind != KSE_EVENT_SOURCE) {
        return set_error(stream, "ETS03", kind, "event before begin");
    }
    if (kind != KSE_EVENT_END &&
        stream->record_count >= KOFUN_SEMANTIC_MAX_EVENTS - 2u) {
        return set_error(stream, "ETS04", kind, "event count limit exceeded");
    }
    if (stream->phase > minimum_phase) {
        return set_error(stream, "ETS03", kind, "event phase moved backwards");
    }
    if (stream->phase < minimum_phase) stream->phase = minimum_phase;
    return true;
}

static bool append_relation_list(
    KofunSemanticStream *stream,
    const KofunSemanticId *ids,
    uint16_t count
) {
    size_t needed;
    size_t capacity;
    KofunSemanticId *relations;
    uint16_t index;
    if (count > KOFUN_SEMANTIC_MAX_RELATIONS) {
        return set_error(
            stream,
            "ETS04",
            0,
            "relation count limit exceeded"
        );
    }
    if (count != 0u && ids == NULL) {
        return set_error(stream, "ETS03", 0, "missing relation array");
    }
    for (index = 0; index < count; index += 1u) {
        if (id_is_zero(&ids[index])) {
            return set_error(stream, "ETS03", 0, "zero relation identity");
        }
    }
    if ((size_t)count > SIZE_MAX - stream->relation_count) {
        return set_error(stream, "ETS04", 0, "relation size overflow");
    }
    needed = stream->relation_count + count;
    if (needed > stream->relation_capacity) {
        capacity = stream->relation_capacity == 0u ?
            128u : stream->relation_capacity;
        while (capacity < needed) {
            if (capacity > KOFUN_SEMANTIC_MAX_EVENTS *
                    KOFUN_SEMANTIC_MAX_RELATIONS / 2u) {
                capacity = KOFUN_SEMANTIC_MAX_EVENTS *
                    KOFUN_SEMANTIC_MAX_RELATIONS;
                break;
            }
            capacity *= 2u;
        }
        relations = (KofunSemanticId *)realloc(
            stream->relations,
            capacity * sizeof(*relations)
        );
        if (relations == NULL) {
            return set_error(stream, "ETS04", 0, "relation allocation failed");
        }
        stream->relations = relations;
        stream->relation_capacity = capacity;
    }
    if (count != 0u) {
        memcpy(
            stream->relations + stream->relation_count,
            ids,
            (size_t)count * sizeof(*ids)
        );
    }
    stream->relation_count = needed;
    return true;
}

static bool append_record(
    KofunSemanticStream *stream,
    const RecordMeta *record
) {
    size_t capacity;
    RecordMeta *records;
    if (stream->record_count == stream->record_capacity) {
        capacity = stream->record_capacity == 0u ?
            64u : stream->record_capacity * 2u;
        if (capacity > KOFUN_SEMANTIC_MAX_EVENTS) {
            capacity = KOFUN_SEMANTIC_MAX_EVENTS;
        }
        records = (RecordMeta *)realloc(
            stream->records,
            capacity * sizeof(*records)
        );
        if (records == NULL) {
            return set_error(stream, "ETS04", record->kind, "record allocation failed");
        }
        stream->records = records;
        stream->record_capacity = capacity;
    }
    stream->records[stream->record_count] = *record;
    stream->record_count += 1u;
    return true;
}

static bool append_field(
    ByteBuffer *payload,
    uint8_t tag,
    uint8_t wire,
    const void *bytes,
    uint32_t length
) {
    uint8_t header[8];
    header[0] = tag;
    header[1] = wire;
    header[2] = 0u;
    header[3] = 0u;
    store_u32be(header + 4u, length);
    return buffer_append(payload, header, sizeof(header)) &&
        buffer_append(payload, bytes, length);
}

static bool field_u8(
    ByteBuffer *payload,
    uint8_t tag,
    uint8_t value
) {
    return append_field(payload, tag, KSE_WIRE_U8, &value, 1u);
}

static bool field_u64(
    ByteBuffer *payload,
    uint8_t tag,
    uint64_t value
) {
    uint8_t bytes[8];
    store_u64be(bytes, value);
    return append_field(payload, tag, KSE_WIRE_U64, bytes, sizeof(bytes));
}

static bool field_span(
    ByteBuffer *payload,
    uint8_t tag,
    KofunSemanticSpan span
) {
    uint8_t bytes[8];
    store_u32be(bytes, span.start);
    store_u32be(bytes + 4u, span.end);
    return append_field(payload, tag, KSE_WIRE_SPAN, bytes, sizeof(bytes));
}

static bool field_id(
    ByteBuffer *payload,
    uint8_t tag,
    const KofunSemanticId *id
) {
    return append_field(
        payload,
        tag,
        KSE_WIRE_ID,
        id->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
}

static bool field_text(
    ByteBuffer *payload,
    uint8_t tag,
    KofunSemanticBytes text
) {
    return append_field(payload, tag, KSE_WIRE_UTF8, text.bytes, text.length);
}

static bool field_id_list(
    ByteBuffer *payload,
    uint8_t tag,
    const KofunSemanticId *ids,
    uint16_t count
) {
    return append_field(
        payload,
        tag,
        KSE_WIRE_ID_LIST,
        ids,
        (uint32_t)count * KOFUN_SEMANTIC_ID_BYTES
    );
}

static bool field_u32_list(
    ByteBuffer *payload,
    uint8_t tag,
    const uint32_t *values,
    uint16_t count
) {
    uint8_t encoded[KOFUN_SEMANTIC_MAX_RELATIONS * 4u];
    uint16_t index;
    for (index = 0; index < count; index += 1u) {
        store_u32be(encoded + (size_t)index * 4u, values[index]);
    }
    return append_field(
        payload,
        tag,
        KSE_WIRE_U32_LIST,
        encoded,
        (uint32_t)count * 4u
    );
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

static bool preflight_nested_item(
    size_t *length,
    size_t fixed_bytes,
    uint32_t text_bytes
) {
    size_t remaining;
    if (*length > KOFUN_SEMANTIC_MAX_TEXT_BYTES) return false;
    remaining = KOFUN_SEMANTIC_MAX_TEXT_BYTES - *length;
    if (fixed_bytes > remaining) return false;
    remaining -= fixed_bytes;
    if ((size_t)text_bytes > remaining) return false;
    *length += fixed_bytes + (size_t)text_bytes;
    return true;
}

static bool field_related_list(
    ByteBuffer *payload,
    uint8_t tag,
    const KofunSemanticRelated *related,
    uint16_t count
) {
    ByteBuffer encoded = {0};
    size_t encoded_length = 2u;
    uint16_t index;
    bool ok;
    for (index = 0u; index < count; index += 1u) {
        if (!preflight_nested_item(
                &encoded_length,
                KOFUN_SEMANTIC_ID_BYTES + 4u + 4u + 2u,
                related[index].label.length)) {
            return false;
        }
    }
    if (!buffer_reserve(&encoded, encoded_length)) return false;
    ok = buffer_u16(&encoded, count);
    for (index = 0u; ok && index < count; index += 1u) {
        ok = buffer_append(
                &encoded,
                related[index].file_id.bytes,
                KOFUN_SEMANTIC_ID_BYTES
            ) &&
            buffer_u32(&encoded, related[index].span.start) &&
            buffer_u32(&encoded, related[index].span.end) &&
            buffer_u16(&encoded, (uint16_t)related[index].label.length) &&
            buffer_append(
                &encoded,
                related[index].label.bytes,
                related[index].label.length
            );
    }
    if (ok && encoded.length == encoded_length) {
        ok = append_field(
            payload,
            tag,
            KSE_WIRE_BYTES,
            encoded.bytes,
            (uint32_t)encoded.length
        );
    } else {
        ok = false;
    }
    free(encoded.bytes);
    return ok;
}

static bool field_edit_list(
    ByteBuffer *payload,
    uint8_t tag,
    const KofunSemanticEdit *edits,
    uint16_t count
) {
    ByteBuffer encoded = {0};
    size_t encoded_length = 2u;
    uint16_t index;
    bool ok;
    for (index = 0u; index < count; index += 1u) {
        if (!preflight_nested_item(
                &encoded_length,
                4u + KOFUN_SEMANTIC_ID_BYTES + 4u + 4u + 2u,
                edits[index].replacement.length)) {
            return false;
        }
    }
    if (!buffer_reserve(&encoded, encoded_length)) return false;
    ok = buffer_u16(&encoded, count);
    for (index = 0u; ok && index < count; index += 1u) {
        ok = buffer_u32(&encoded, edits[index].remedy_id) &&
            buffer_append(
                &encoded,
                edits[index].file_id.bytes,
                KOFUN_SEMANTIC_ID_BYTES
            ) &&
            buffer_u32(&encoded, edits[index].span.start) &&
            buffer_u32(&encoded, edits[index].span.end) &&
            buffer_u16(
                &encoded,
                (uint16_t)edits[index].replacement.length
            ) &&
            buffer_append(
                &encoded,
                edits[index].replacement.bytes,
                edits[index].replacement.length
            );
    }
    if (ok && encoded.length == encoded_length) {
        ok = append_field(
            payload,
            tag,
            KSE_WIRE_BYTES,
            encoded.bytes,
            (uint32_t)encoded.length
        );
    } else {
        ok = false;
    }
    free(encoded.bytes);
    return ok;
}

static bool finish_event(
    KofunSemanticStream *stream,
    uint8_t kind,
    uint16_t field_count,
    ByteBuffer *payload
) {
    uint8_t header[8];
    bool ok;
    header[0] = kind;
    header[1] = 0u;
    store_u16be(header + 2u, field_count);
    store_u32be(header + 4u, (uint32_t)payload->length);
    ok = buffer_append(&stream->events, header, sizeof(header)) &&
        buffer_append(&stream->events, payload->bytes, payload->length);
    free(payload->bytes);
    payload->bytes = NULL;
    payload->length = 0u;
    payload->capacity = 0u;
    if (!ok) {
        return set_error(stream, "ETS04", kind, "event byte limit exceeded");
    }
    return true;
}

static bool duplicate_record_id(
    const KofunSemanticStream *stream,
    uint8_t kind,
    const KofunSemanticId *id
) {
    size_t index;
    for (index = 0; index < stream->record_count; index += 1u) {
        if (stream->records[index].kind == kind &&
            id_equal(&stream->records[index].id, id)) {
            return true;
        }
    }
    return false;
}

static const RecordMeta *find_record(
    const KofunSemanticStream *stream,
    uint8_t kind,
    const KofunSemanticId *id
) {
    size_t index;
    for (index = 0; index < stream->record_count; index += 1u) {
        if (stream->records[index].kind == kind &&
            id_equal(&stream->records[index].id, id)) {
            return &stream->records[index];
        }
    }
    return NULL;
}

static const RecordMeta *find_identity_record(
    const KofunSemanticStream *stream,
    KofunSemanticIdentityKind kind,
    const KofunSemanticId *value
) {
    size_t index;
    for (index = 0u; index < stream->record_count; index += 1u) {
        const RecordMeta *record = &stream->records[index];
        if (record->kind == KSE_EVENT_IDENTITY &&
            record->subtype == (uint8_t)kind &&
            id_equal(&record->id, value)) {
            return record;
        }
    }
    return NULL;
}

static bool valid_relations(
    KofunSemanticStream *stream,
    uint8_t kind,
    KofunSemanticStatus status,
    const KofunSemanticId *dependencies,
    uint16_t dependency_count,
    const KofunSemanticId *diagnostic_ids,
    uint16_t diagnostic_count
) {
    uint16_t index;
    if (!valid_status(status)) {
        return set_error(stream, "ETS03", kind, "unknown semantic status");
    }
    if (stream->cancellation_observed &&
        status == KOFUN_SEMANTIC_VALIDATED) {
        return set_error(
            stream,
            "ETS03",
            kind,
            "validated fact after cancellation observation"
        );
    }
    if (status == KOFUN_SEMANTIC_ERROR && diagnostic_count == 0u) {
        return set_error(
            stream,
            "ETS03",
            kind,
            "error record has no diagnostic identity"
        );
    }
    if (status == KOFUN_SEMANTIC_PROVISIONAL && dependency_count == 0u) {
        return set_error(
            stream,
            "ETS03",
            kind,
            "provisional record has no dependency"
        );
    }
    if (dependency_count > KOFUN_SEMANTIC_MAX_RELATIONS ||
        diagnostic_count > KOFUN_SEMANTIC_MAX_RELATIONS) {
        return set_error(stream, "ETS04", kind, "relation count limit exceeded");
    }
    if ((dependency_count != 0u && dependencies == NULL) ||
        (diagnostic_count != 0u && diagnostic_ids == NULL)) {
        return set_error(stream, "ETS03", kind, "missing relation values");
    }
    for (index = 1u; index < dependency_count; index += 1u) {
        if (memcmp(
                dependencies[index - 1u].bytes,
                dependencies[index].bytes,
                KOFUN_SEMANTIC_ID_BYTES) >= 0) {
            return set_error(
                stream,
                "ETS03",
                kind,
                "dependencies are not unique canonical order"
            );
        }
    }
    for (index = 1u; index < diagnostic_count; index += 1u) {
        if (memcmp(
                diagnostic_ids[index - 1u].bytes,
                diagnostic_ids[index].bytes,
                KOFUN_SEMANTIC_ID_BYTES) >= 0) {
            return set_error(
                stream,
                "ETS03",
                kind,
                "diagnostic identities are not unique canonical order"
            );
        }
    }
    return true;
}

static bool stream_begin_callback(
    void *context,
    const KofunSemanticSource *source
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    if (stream == NULL || source == NULL) return false;
    if (stream->began || stream->ended || stream->failed) {
        return set_error(stream, "ETS03", KSE_EVENT_SOURCE, "duplicate begin");
    }
    if (stream->cancellation_observed) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_SOURCE,
            "cancelled before source/token commitment"
        );
    }
    if (!kofun_semantic_validate_text(source->logical_path) ||
        !kofun_semantic_validate_text(source->edition) ||
        !kofun_semantic_validate_text(source->semantic_compatibility)) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_SOURCE,
            "source text encoding is invalid or over limit"
        );
    }
    if (id_is_zero(&source->package_id) ||
        id_is_zero(&source->module_id) ||
        id_is_zero(&source->file_id) ||
        !kofun_semantic_validate_logical_path(source->logical_path) ||
        source->edition.length == 0u ||
        source->semantic_compatibility.length == 0u ||
        source->compiler_exit_class > 3u) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_SOURCE,
            "invalid committed source identity"
        );
    }
    if (source->source_bytes > UINT32_MAX) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_SOURCE,
            "source byte span exceeds v1"
        );
    }
    stream->source_bytes = source->source_bytes;
    stream->source_file_id = source->file_id;
    stream->compiler_exit_class = source->compiler_exit_class;
    stream->phase = 1u;
    stream->began = true;
    memset(&record, 0, sizeof(record));
    if (!field_id(&payload, 1u, &source->package_id) ||
        !field_id(&payload, 2u, &source->module_id) ||
        !field_id(&payload, 3u, &source->file_id) ||
        !field_text(&payload, 4u, source->logical_path) ||
        !field_u64(&payload, 5u, source->source_bytes) ||
        !append_field(
            &payload,
            6u,
            KSE_WIRE_ID,
            source->source_sha256,
            KOFUN_SEMANTIC_ID_BYTES
        ) ||
        !field_text(&payload, 7u, source->edition) ||
        !field_text(&payload, 8u, source->semantic_compatibility) ||
        !field_u64(&payload, 9u, source->caller_generation) ||
        !field_u8(&payload, 10u, source->compiler_exit_class)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_SOURCE,
            "source event allocation failed"
        );
    }
    return finish_event(stream, KSE_EVENT_SOURCE, 10u, &payload);
}

static bool stream_node_callback(
    void *context,
    const KofunSemanticNode *node
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    if (stream == NULL || node == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_NODE, 2u)) return false;
    if (node->kind < KOFUN_SEMANTIC_NODE_MODULE ||
        node->kind > KOFUN_SEMANTIC_NODE_ERROR_PATTERN ||
        id_is_zero(&node->node_id) ||
        duplicate_record_id(stream, KSE_EVENT_NODE, &node->node_id) ||
        !valid_span(stream, node->span)) {
        return set_error(stream, "ETS03", KSE_EVENT_NODE, "invalid node record");
    }
    if (!valid_relations(
            stream,
            KSE_EVENT_NODE,
            node->status,
            node->dependencies,
            node->dependency_count,
            node->diagnostic_ids,
            node->diagnostic_count)) {
        return false;
    }
    memset(&record, 0, sizeof(record));
    record.kind = KSE_EVENT_NODE;
    record.status = node->status;
    record.id = node->node_id;
    record.relation_offset = (uint32_t)stream->relation_count;
    record.dependency_count = node->dependency_count;
    record.diagnostic_count = node->diagnostic_count;
    if (!append_relation_list(
            stream,
            node->dependencies,
            node->dependency_count) ||
        !append_relation_list(
            stream,
            node->diagnostic_ids,
            node->diagnostic_count) ||
        !field_id(&payload, 1u, &node->node_id) ||
        !field_u8(&payload, 2u, (uint8_t)node->kind) ||
        !field_span(&payload, 3u, node->span) ||
        !field_u8(&payload, 4u, (uint8_t)node->status) ||
        !field_id_list(
            &payload,
            5u,
            node->dependencies,
            node->dependency_count) ||
        !field_id_list(
            &payload,
            6u,
            node->diagnostic_ids,
            node->diagnostic_count)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_NODE,
            "node event allocation failed"
        );
    }
    if (!append_record(stream, &record)) {
        free(payload.bytes);
        return false;
    }
    return finish_event(stream, KSE_EVENT_NODE, 6u, &payload);
}

static bool stream_identity_callback(
    void *context,
    const KofunSemanticIdentity *identity
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    size_t index;
    if (stream == NULL || identity == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_IDENTITY, 3u)) return false;
    if (identity->kind < KOFUN_SEMANTIC_ID_PACKAGE ||
        identity->kind > KOFUN_SEMANTIC_ID_CONSTRUCTOR ||
        !valid_status(identity->status) ||
        identity->status == KOFUN_SEMANTIC_ERROR ||
        id_is_zero(&identity->owner_node_id) ||
        id_is_zero(&identity->value) ||
        find_record(
            stream,
            KSE_EVENT_NODE,
            &identity->owner_node_id) == NULL) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_IDENTITY,
            "invalid semantic identity"
        );
    }
    if (stream->cancellation_observed &&
        identity->status == KOFUN_SEMANTIC_VALIDATED) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_IDENTITY,
            "validated identity after cancellation observation"
        );
    }
    for (index = 0; index < stream->record_count; index += 1u) {
        const RecordMeta *existing = &stream->records[index];
        if (existing->kind == KSE_EVENT_IDENTITY &&
            existing->subtype == (uint8_t)identity->kind) {
            if (id_equal(
                    &existing->owner,
                    &identity->owner_node_id)) {
                return set_error(
                    stream,
                    "ETS03",
                    KSE_EVENT_IDENTITY,
                    "duplicate identity kind for node"
                );
            }
            if (id_equal(&existing->id, &identity->value)) {
                return set_error(
                    stream,
                    "ETS03",
                    KSE_EVENT_IDENTITY,
                    "identity kind and value name multiple owners"
                );
            }
        }
    }
    memset(&record, 0, sizeof(record));
    record.kind = KSE_EVENT_IDENTITY;
    record.subtype = (uint8_t)identity->kind;
    record.status = identity->status;
    record.id = identity->value;
    record.owner = identity->owner_node_id;
    if (!field_id(&payload, 1u, &identity->owner_node_id) ||
        !field_u8(&payload, 2u, (uint8_t)identity->kind) ||
        !field_id(&payload, 3u, &identity->value) ||
        !field_u8(&payload, 4u, (uint8_t)identity->status)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_IDENTITY,
            "identity event allocation failed"
        );
    }
    if (!append_record(stream, &record)) {
        free(payload.bytes);
        return false;
    }
    return finish_event(stream, KSE_EVENT_IDENTITY, 4u, &payload);
}

static bool stream_reference_callback(
    void *context,
    const KofunSemanticReference *reference
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    if (stream == NULL || reference == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_REFERENCE, 4u)) return false;
    if (id_is_zero(&reference->reference_id) ||
        id_is_zero(&reference->source_node_id) ||
        duplicate_record_id(
            stream,
            KSE_EVENT_REFERENCE,
            &reference->reference_id) ||
        find_record(
            stream,
            KSE_EVENT_NODE,
            &reference->source_node_id) == NULL ||
        reference->name_space < KOFUN_SEMANTIC_NAMESPACE_VALUE ||
        reference->name_space > KOFUN_SEMANTIC_NAMESPACE_CONSTRUCTOR ||
        !valid_span(stream, reference->span) ||
        reference->target_shape < KOFUN_SEMANTIC_TARGET_VISIBLE ||
        reference->target_shape > KOFUN_SEMANTIC_TARGET_UNAVAILABLE) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_REFERENCE,
            "invalid reference record"
        );
    }
    if (!valid_relations(
            stream,
            KSE_EVENT_REFERENCE,
            reference->status,
            NULL,
            0u,
            reference->diagnostic_ids,
            reference->diagnostic_count)) {
        return false;
    }
    if (!kofun_semantic_validate_text(reference->hidden_reason)) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_REFERENCE,
            "reference reason encoding is invalid or over limit"
        );
    }
    if (reference->target_shape == KOFUN_SEMANTIC_TARGET_VISIBLE) {
        const RecordMeta *target;
        if (reference->target_kind < KOFUN_SEMANTIC_ID_PACKAGE ||
            reference->target_kind > KOFUN_SEMANTIC_ID_CONSTRUCTOR ||
            !reference_kind_matches_namespace(
                reference->name_space,
                reference->target_kind) ||
            id_is_zero(&reference->target_value) ||
            reference->hidden_reason.length != 0u) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_REFERENCE,
                "visible target shape is incomplete"
            );
        }
        target = find_identity_record(
            stream,
            reference->target_kind,
            &reference->target_value
        );
        if (target == NULL ||
            (reference->status == KOFUN_SEMANTIC_VALIDATED &&
             target->status != KOFUN_SEMANTIC_VALIDATED)) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_REFERENCE,
                "visible target identity is absent or has unsafe status"
            );
        }
    } else {
        if ((reference->target_kind != 0 &&
             (reference->target_kind < KOFUN_SEMANTIC_ID_PACKAGE ||
              reference->target_kind > KOFUN_SEMANTIC_ID_CONSTRUCTOR ||
              !reference_kind_matches_namespace(
                  reference->name_space,
                  reference->target_kind))) ||
            id_is_zero(&reference->target_value) == false ||
            reference->hidden_reason.length == 0u ||
            reference->status == KOFUN_SEMANTIC_VALIDATED ||
            !valid_public_reason(reference->hidden_reason)) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_REFERENCE,
                "non-visible target has unsafe status, value, or reason"
            );
        }
    }
    memset(&record, 0, sizeof(record));
    record.kind = KSE_EVENT_REFERENCE;
    record.status = reference->status;
    record.id = reference->reference_id;
    record.owner = reference->source_node_id;
    record.relation_offset = (uint32_t)stream->relation_count;
    record.diagnostic_count = reference->diagnostic_count;
    record.has_reason = reference->hidden_reason.length != 0u;
    if (!append_relation_list(
            stream,
            reference->diagnostic_ids,
            reference->diagnostic_count) ||
        !field_id(&payload, 1u, &reference->reference_id) ||
        !field_id(&payload, 2u, &reference->source_node_id) ||
        !field_u8(&payload, 3u, (uint8_t)reference->name_space) ||
        !field_span(&payload, 4u, reference->span) ||
        !field_u8(&payload, 5u, (uint8_t)reference->status) ||
        !field_u8(&payload, 6u, (uint8_t)reference->target_shape) ||
        !field_u8(&payload, 7u, (uint8_t)reference->target_kind)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_REFERENCE,
            "reference event allocation failed"
        );
    }
    if (reference->target_shape == KOFUN_SEMANTIC_TARGET_VISIBLE) {
        if (!field_id(&payload, 8u, &reference->target_value) ||
            !field_id_list(
                &payload,
                10u,
                reference->diagnostic_ids,
                reference->diagnostic_count)) {
            free(payload.bytes);
            return set_error(
                stream,
                "ETS04",
                KSE_EVENT_REFERENCE,
                "reference event allocation failed"
            );
        }
    } else {
        if (!field_text(&payload, 9u, reference->hidden_reason) ||
            !field_id_list(
                &payload,
                10u,
                reference->diagnostic_ids,
                reference->diagnostic_count)) {
            free(payload.bytes);
            return set_error(
                stream,
                "ETS04",
                KSE_EVENT_REFERENCE,
                "reference event allocation failed"
            );
        }
    }
    if (!append_record(stream, &record)) {
        free(payload.bytes);
        return false;
    }
    return finish_event(stream, KSE_EVENT_REFERENCE, 9u, &payload);
}

static bool stream_fact_callback(
    void *context,
    const KofunSemanticFact *fact
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    size_t index;
    if (stream == NULL || fact == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_FACT, 5u)) return false;
    if (!kofun_semantic_validate_text(fact->display) ||
        !kofun_semantic_validate_text(fact->reason)) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_FACT,
            "fact text encoding is invalid or over limit"
        );
    }
    if (fact->reason.length != 0u &&
        !valid_public_reason(fact->reason)) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_FACT,
            "fact reason is not a public discriminator"
        );
    }
    if (fact->kind < KOFUN_SEMANTIC_FACT_TYPE ||
        fact->kind > KOFUN_SEMANTIC_FACT_ORIGIN ||
        fact->kind < stream->last_fact_kind ||
        id_is_zero(&fact->owner_node_id) ||
        find_record(
            stream,
            KSE_EVENT_NODE,
            &fact->owner_node_id) == NULL) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_FACT,
            "invalid semantic fact"
        );
    }
    if (!valid_relations(
            stream,
            KSE_EVENT_FACT,
            fact->status,
            fact->dependencies,
            fact->dependency_count,
            fact->diagnostic_ids,
            fact->diagnostic_count)) {
        return false;
    }
    if (fact->status == KOFUN_SEMANTIC_UNAVAILABLE &&
        (fact->reason.length == 0u || fact->display.length != 0u)) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_FACT,
            "unavailable fact has a display or no bounded reason"
        );
    }
    if (fact->status == KOFUN_SEMANTIC_VALIDATED &&
        fact->display.length == 0u) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_FACT,
            "validated fact has no display"
        );
    }
    for (index = 0; index < stream->record_count; index += 1u) {
        const RecordMeta *existing = &stream->records[index];
        if (existing->kind == KSE_EVENT_FACT &&
            existing->subtype == (uint8_t)fact->kind &&
            id_equal(&existing->owner, &fact->owner_node_id)) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_FACT,
                "duplicate fact kind for node"
            );
        }
    }
    stream->last_fact_kind = (uint8_t)fact->kind;
    memset(&record, 0, sizeof(record));
    record.kind = KSE_EVENT_FACT;
    record.subtype = (uint8_t)fact->kind;
    record.status = fact->status;
    record.id = fact->owner_node_id;
    record.owner = fact->owner_node_id;
    record.relation_offset = (uint32_t)stream->relation_count;
    record.dependency_count = fact->dependency_count;
    record.diagnostic_count = fact->diagnostic_count;
    record.has_reason = fact->reason.length != 0u;
    if (!append_relation_list(
            stream,
            fact->dependencies,
            fact->dependency_count) ||
        !append_relation_list(
            stream,
            fact->diagnostic_ids,
            fact->diagnostic_count) ||
        !field_id(&payload, 1u, &fact->owner_node_id) ||
        !field_u8(&payload, 2u, (uint8_t)fact->kind) ||
        !field_u8(&payload, 3u, (uint8_t)fact->status) ||
        !field_text(&payload, 4u, fact->display) ||
        !field_text(&payload, 5u, fact->reason) ||
        !field_id_list(
            &payload,
            6u,
            fact->dependencies,
            fact->dependency_count) ||
        !field_id_list(
            &payload,
            7u,
            fact->diagnostic_ids,
            fact->diagnostic_count)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_FACT,
            "fact event allocation failed"
        );
    }
    if (!append_record(stream, &record)) {
        free(payload.bytes);
        return false;
    }
    return finish_event(stream, KSE_EVENT_FACT, 7u, &payload);
}

static int compare_semantic_bytes(
    KofunSemanticBytes left,
    KofunSemanticBytes right
) {
    uint32_t common = left.length < right.length ? left.length : right.length;
    int order = common == 0u ? 0 : memcmp(left.bytes, right.bytes, common);
    if (order != 0) return order;
    if (left.length == right.length) return 0;
    return left.length < right.length ? -1 : 1;
}

static int compare_related(
    const KofunSemanticRelated *left,
    const KofunSemanticRelated *right
) {
    int order = memcmp(
        left->file_id.bytes,
        right->file_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    if (order != 0) return order;
    if (left->span.start != right->span.start) {
        return left->span.start < right->span.start ? -1 : 1;
    }
    if (left->span.end != right->span.end) {
        return left->span.end < right->span.end ? -1 : 1;
    }
    return compare_semantic_bytes(left->label, right->label);
}

static int compare_edits(
    const KofunSemanticEdit *left,
    const KofunSemanticEdit *right
) {
    int order;
    if (left->remedy_id != right->remedy_id) {
        return left->remedy_id < right->remedy_id ? -1 : 1;
    }
    order = memcmp(
        left->file_id.bytes,
        right->file_id.bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    if (order != 0) return order;
    if (left->span.start != right->span.start) {
        return left->span.start < right->span.start ? -1 : 1;
    }
    if (left->span.end != right->span.end) {
        return left->span.end < right->span.end ? -1 : 1;
    }
    return compare_semantic_bytes(left->replacement, right->replacement);
}

static bool remedy_exists(
    const KofunSemanticDiagnostic *diagnostic,
    uint32_t remedy_id
) {
    uint16_t index;
    for (index = 0u; index < diagnostic->remedy_count; index += 1u) {
        if (diagnostic->remedy_ids[index] == remedy_id) return true;
    }
    return false;
}

static bool stream_diagnostic_callback(
    void *context,
    const KofunSemanticDiagnostic *diagnostic
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    RecordMeta record;
    uint16_t index;
    if (stream == NULL || diagnostic == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_DIAGNOSTIC, 6u)) return false;
    if (!kofun_semantic_validate_text(diagnostic->code) ||
        !kofun_semantic_validate_text(diagnostic->category) ||
        !kofun_semantic_validate_text(diagnostic->template_id) ||
        !kofun_semantic_validate_text(diagnostic->fallback_text)) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_DIAGNOSTIC,
            "diagnostic text encoding is invalid or over limit"
        );
    }
    if (id_is_zero(&diagnostic->diagnostic_id) ||
        duplicate_record_id(
            stream,
            KSE_EVENT_DIAGNOSTIC,
            &diagnostic->diagnostic_id) ||
        diagnostic->severity < KOFUN_SEMANTIC_DIAGNOSTIC_ERROR ||
        diagnostic->severity > KOFUN_SEMANTIC_DIAGNOSTIC_NOTE ||
        id_is_zero(&diagnostic->primary_file_id) ||
        !valid_span(stream, diagnostic->primary_span) ||
        diagnostic->code.length == 0u ||
        diagnostic->category.length == 0u ||
        diagnostic->template_id.length == 0u ||
        diagnostic->affected_count > KOFUN_SEMANTIC_MAX_RELATIONS ||
        diagnostic->remedy_count > KOFUN_SEMANTIC_MAX_RELATIONS ||
        diagnostic->related_count > KOFUN_SEMANTIC_MAX_RELATIONS ||
        diagnostic->edit_count > KOFUN_SEMANTIC_MAX_RELATIONS ||
        (diagnostic->affected_count != 0u &&
         diagnostic->affected_ids == NULL) ||
        (diagnostic->remedy_count != 0u &&
         diagnostic->remedy_ids == NULL) ||
        (diagnostic->related_count != 0u &&
         diagnostic->related == NULL) ||
        (diagnostic->edit_count != 0u &&
         diagnostic->edits == NULL) ||
        !id_equal(
            &diagnostic->primary_file_id,
            &stream->source_file_id)) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_DIAGNOSTIC,
            "invalid structured diagnostic"
        );
    }
    for (index = 0; index < diagnostic->affected_count; index += 1u) {
        if (id_is_zero(&diagnostic->affected_ids[index]) ||
            (find_record(
                stream,
                KSE_EVENT_NODE,
                &diagnostic->affected_ids[index]) == NULL &&
             find_record(
                stream,
                KSE_EVENT_REFERENCE,
                &diagnostic->affected_ids[index]) == NULL)) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "affected identity is zero or dangling"
            );
        }
        if (index != 0u &&
            memcmp(
                diagnostic->affected_ids[index - 1u].bytes,
                diagnostic->affected_ids[index].bytes,
                KOFUN_SEMANTIC_ID_BYTES) >= 0) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "affected identities are not unique canonical order"
            );
        }
    }
    for (index = 1u; index < diagnostic->remedy_count; index += 1u) {
        if (diagnostic->remedy_ids[index - 1u] >=
            diagnostic->remedy_ids[index]) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "remedy identities are not unique canonical order"
            );
        }
    }
    for (index = 0u; index < diagnostic->related_count; index += 1u) {
        const KofunSemanticRelated *related = &diagnostic->related[index];
        if (!id_equal(&related->file_id, &stream->source_file_id) ||
            !valid_span(stream, related->span) ||
            related->label.length == 0u) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "invalid related diagnostic location"
            );
        }
        if (!kofun_semantic_validate_text(related->label)) {
            return set_error(
                stream,
                "ETS04",
                KSE_EVENT_DIAGNOSTIC,
                "related diagnostic text is invalid or over limit"
            );
        }
        if (index != 0u &&
            compare_related(
                &diagnostic->related[index - 1u],
                related
            ) >= 0) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "related locations are not unique canonical order"
            );
        }
    }
    for (index = 0u; index < diagnostic->edit_count; index += 1u) {
        const KofunSemanticEdit *edit = &diagnostic->edits[index];
        if (!remedy_exists(diagnostic, edit->remedy_id) ||
            !id_equal(&edit->file_id, &stream->source_file_id) ||
            !valid_span(stream, edit->span)) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "invalid diagnostic edit"
            );
        }
        if (!kofun_semantic_validate_text(edit->replacement)) {
            return set_error(
                stream,
                "ETS04",
                KSE_EVENT_DIAGNOSTIC,
                "diagnostic edit text is invalid or over limit"
            );
        }
        if (index != 0u &&
            compare_edits(&diagnostic->edits[index - 1u], edit) >= 0) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_DIAGNOSTIC,
                "diagnostic edits are not unique canonical order"
            );
        }
    }
    memset(&record, 0, sizeof(record));
    record.kind = KSE_EVENT_DIAGNOSTIC;
    record.subtype = (uint8_t)diagnostic->severity;
    record.id = diagnostic->diagnostic_id;
    record.relation_offset = (uint32_t)stream->relation_count;
    record.dependency_count = diagnostic->affected_count;
    if (!append_relation_list(
            stream,
            diagnostic->affected_ids,
            diagnostic->affected_count) ||
        !field_id(&payload, 1u, &diagnostic->diagnostic_id) ||
        !field_text(&payload, 2u, diagnostic->code) ||
        !field_text(&payload, 3u, diagnostic->category) ||
        !field_u8(&payload, 4u, (uint8_t)diagnostic->severity) ||
        !field_text(&payload, 5u, diagnostic->template_id) ||
        !field_id(&payload, 6u, &diagnostic->primary_file_id) ||
        !field_span(&payload, 7u, diagnostic->primary_span) ||
        !field_text(&payload, 8u, diagnostic->fallback_text) ||
        !field_id_list(
            &payload,
            9u,
            diagnostic->affected_ids,
            diagnostic->affected_count) ||
        !field_u32_list(
            &payload,
            10u,
            diagnostic->remedy_ids,
            diagnostic->remedy_count) ||
        !field_u8(&payload, 11u, diagnostic->truncated ? 1u : 0u) ||
        !field_related_list(
            &payload,
            12u,
            diagnostic->related,
            diagnostic->related_count) ||
        !field_edit_list(
            &payload,
            13u,
            diagnostic->edits,
            diagnostic->edit_count)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_DIAGNOSTIC,
            "diagnostic event allocation failed"
        );
    }
    if (!append_record(stream, &record)) {
        free(payload.bytes);
        return false;
    }
    if (diagnostic->severity == KOFUN_SEMANTIC_DIAGNOSTIC_ERROR) {
        stream->has_error_diagnostic = true;
    }
    return finish_event(stream, KSE_EVENT_DIAGNOSTIC, 13u, &payload);
}

static bool validate_closure(KofunSemanticStream *stream) {
    size_t index;
    for (index = 0; index < stream->record_count; index += 1u) {
        const RecordMeta *record = &stream->records[index];
        size_t relation = record->relation_offset;
        uint16_t dependency_index;
        uint16_t diagnostic_index;
        bool has_nonvalidated = false;
        if (record->kind != KSE_EVENT_NODE &&
            record->kind != KSE_EVENT_REFERENCE &&
            record->kind != KSE_EVENT_FACT) {
            continue;
        }
        for (dependency_index = 0u;
             dependency_index < record->dependency_count;
             dependency_index += 1u) {
            const KofunSemanticId *dependency =
                &stream->relations[relation + dependency_index];
            const RecordMeta *target = find_record(
                stream,
                KSE_EVENT_NODE,
                dependency
            );
            if (target == NULL) {
                return set_error(
                    stream,
                    "ETS03",
                    record->kind,
                    "dependency does not name a node"
                );
            }
            if (target->status != KOFUN_SEMANTIC_VALIDATED) {
                has_nonvalidated = true;
            }
            if (record->status == KOFUN_SEMANTIC_VALIDATED &&
                target->status != KOFUN_SEMANTIC_VALIDATED) {
                return set_error(
                    stream,
                    "ETS03",
                    record->kind,
                    "validated record has non-validated dependency"
                );
            }
        }
        if (record->status == KOFUN_SEMANTIC_PROVISIONAL &&
            !has_nonvalidated) {
            return set_error(
                stream,
                "ETS03",
                record->kind,
                "provisional dependencies are all validated"
            );
        }
        relation += record->dependency_count;
        for (diagnostic_index = 0u;
             diagnostic_index < record->diagnostic_count;
             diagnostic_index += 1u) {
            if (find_record(
                    stream,
                    KSE_EVENT_DIAGNOSTIC,
                    &stream->relations[relation + diagnostic_index]) == NULL) {
                return set_error(
                    stream,
                    "ETS03",
                    record->kind,
                    "record names an unknown diagnostic"
                );
            }
        }
        if (record->status == KOFUN_SEMANTIC_UNAVAILABLE &&
            record->kind != KSE_EVENT_NODE && !record->has_reason) {
            return set_error(
                stream,
                "ETS03",
                record->kind,
                "unavailable record has no reason"
            );
        }
    }
    return true;
}

static bool build_final_stream(KofunSemanticStream *stream) {
    uint8_t header[16] = {
        'K', 'S', 'E', 0u,
        0u, 1u,
        0u, 0u,
        0u, 0u, 0u, 0u,
        0u, 0u, 0u, 0u
    };
    uint8_t digest[32];
    KofunSha256 sha;
    uint32_t event_count;
    if (stream->record_count > KOFUN_SEMANTIC_MAX_EVENTS - 2u ||
        stream->events.length > KOFUN_SEMANTIC_MAX_EVENT_BYTES) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "framed stream limit exceeded"
        );
    }
    event_count = (uint32_t)stream->record_count + 2u;
    store_u32be(header + 8u, event_count);
    store_u32be(header + 12u, (uint32_t)stream->events.length);
    kofun_sha256_init(&sha);
    kofun_sha256_update(&sha, header, sizeof(header));
    kofun_sha256_update(&sha, stream->events.bytes, stream->events.length);
    kofun_sha256_finish(&sha, digest);
    free(stream->final.bytes);
    memset(&stream->final, 0, sizeof(stream->final));
    if (!buffer_append(&stream->final, header, sizeof(header)) ||
        !buffer_append(
            &stream->final,
            stream->events.bytes,
            stream->events.length) ||
        !buffer_append(&stream->final, digest, sizeof(digest))) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "final stream allocation failed"
        );
    }
    stream->ready = true;
    return true;
}

static bool stream_end_callback(
    void *context,
    KofunSourceStatus source_status,
    KofunCompleteness completeness
) {
    KofunSemanticStream *stream = (KofunSemanticStream *)context;
    ByteBuffer payload = {0};
    if (stream == NULL) return false;
    if (!ensure_event(stream, KSE_EVENT_END, 7u)) return false;
    if ((source_status != KOFUN_SOURCE_CHECKED &&
         source_status != KOFUN_SOURCE_FAILED &&
         source_status != KOFUN_SOURCE_CANCELLED) ||
        (completeness != KOFUN_SEMANTIC_COMPLETE &&
         completeness != KOFUN_SEMANTIC_PARTIAL) ||
        (completeness == KOFUN_SEMANTIC_COMPLETE &&
         source_status != KOFUN_SOURCE_CHECKED) ||
        (completeness == KOFUN_SEMANTIC_PARTIAL &&
         source_status != KOFUN_SOURCE_FAILED &&
         source_status != KOFUN_SOURCE_CANCELLED)) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_END,
            "invalid completeness/source-status pairing"
        );
    }
    if (source_status == KOFUN_SOURCE_FAILED &&
        !stream->has_error_diagnostic) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_END,
            "failed source has no error diagnostic"
        );
    }
    if (source_status == KOFUN_SOURCE_CANCELLED &&
        !stream->cancellation_observed) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_END,
            "cancelled source lacks cancellation observation"
        );
    }
    if (((source_status == KOFUN_SOURCE_CHECKED ||
          source_status == KOFUN_SOURCE_CANCELLED) &&
         stream->compiler_exit_class != 0u) ||
        (source_status == KOFUN_SOURCE_FAILED &&
         (stream->compiler_exit_class == 0u ||
          stream->compiler_exit_class > 3u))) {
        return set_error(
            stream,
            "ETS03",
            KSE_EVENT_END,
            "source status disagrees with compiler exit class"
        );
    }
    if (!validate_closure(stream)) return false;
    if (completeness == KOFUN_SEMANTIC_COMPLETE) {
        size_t index;
        if (stream->has_error_diagnostic) {
            return set_error(
                stream,
                "ETS03",
                KSE_EVENT_END,
                "complete stream has an error diagnostic"
            );
        }
        for (index = 0; index < stream->record_count; index += 1u) {
            const RecordMeta *record = &stream->records[index];
            if (record->kind != KSE_EVENT_DIAGNOSTIC &&
                record->status != KOFUN_SEMANTIC_VALIDATED) {
                return set_error(
                    stream,
                    "ETS03",
                    KSE_EVENT_END,
                    "complete stream contains non-validated record"
                );
            }
        }
    }
    if (!field_u8(&payload, 1u, (uint8_t)source_status) ||
        !field_u8(&payload, 2u, (uint8_t)completeness)) {
        free(payload.bytes);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "end event allocation failed"
        );
    }
    if (!finish_event(stream, KSE_EVENT_END, 2u, &payload)) return false;
    stream->ended = true;
    return build_final_stream(stream);
}

bool kofun_semantic_begin(
    KofunSemanticSink *sink,
    const KofunSemanticSource *source
) {
    return sink != NULL && sink->begin != NULL &&
        source != NULL && sink->begin(sink->context, source);
}

bool kofun_semantic_node(
    KofunSemanticSink *sink,
    const KofunSemanticNode *node
) {
    return sink != NULL && sink->node != NULL &&
        node != NULL && sink->node(sink->context, node);
}

bool kofun_semantic_identity(
    KofunSemanticSink *sink,
    const KofunSemanticIdentity *identity
) {
    return sink != NULL && sink->identity != NULL &&
        identity != NULL && sink->identity(sink->context, identity);
}

bool kofun_semantic_fact(
    KofunSemanticSink *sink,
    const KofunSemanticFact *fact
) {
    return sink != NULL && sink->fact != NULL &&
        fact != NULL && sink->fact(sink->context, fact);
}

bool kofun_semantic_reference(
    KofunSemanticSink *sink,
    const KofunSemanticReference *reference
) {
    return sink != NULL && sink->reference != NULL &&
        reference != NULL && sink->reference(sink->context, reference);
}

bool kofun_semantic_diagnostic(
    KofunSemanticSink *sink,
    const KofunSemanticDiagnostic *diagnostic
) {
    return sink != NULL && sink->diagnostic != NULL &&
        diagnostic != NULL &&
        sink->diagnostic(sink->context, diagnostic);
}

void kofun_semantic_cancellation_observed(KofunSemanticSink *sink) {
    if (sink != NULL && sink->cancellation_observed != NULL) {
        sink->cancellation_observed(sink->context);
    }
}

bool kofun_semantic_end(
    KofunSemanticSink *sink,
    KofunSourceStatus source_status,
    KofunCompleteness completeness
) {
    return sink != NULL && sink->end != NULL &&
        sink->end(sink->context, source_status, completeness);
}

KofunSemanticStream *kofun_semantic_stream_create(void) {
    return (KofunSemanticStream *)calloc(1u, sizeof(KofunSemanticStream));
}

void kofun_semantic_stream_destroy(KofunSemanticStream *stream) {
    if (stream == NULL) return;
    free(stream->events.bytes);
    free(stream->final.bytes);
    free(stream->records);
    free(stream->relations);
    memset(stream, 0, sizeof(*stream));
    free(stream);
}

static void stream_cancellation_callback(void *context) {
    kofun_semantic_stream_observe_cancellation(
        (KofunSemanticStream *)context
    );
}

KofunSemanticSink kofun_semantic_stream_sink(KofunSemanticStream *stream) {
    KofunSemanticSink sink;
    sink.context = stream;
    sink.begin = stream_begin_callback;
    sink.node = stream_node_callback;
    sink.identity = stream_identity_callback;
    sink.fact = stream_fact_callback;
    sink.reference = stream_reference_callback;
    sink.diagnostic = stream_diagnostic_callback;
    sink.cancellation_observed = stream_cancellation_callback;
    sink.end = stream_end_callback;
    return sink;
}

void kofun_semantic_stream_observe_cancellation(KofunSemanticStream *stream) {
    if (stream != NULL && !stream->ended && !stream->failed) {
        stream->cancellation_observed = true;
    }
}

const KofunSemanticError *kofun_semantic_stream_error(
    const KofunSemanticStream *stream
) {
    return stream != NULL && stream->failed ? &stream->error : NULL;
}

bool kofun_semantic_stream_bytes(
    const KofunSemanticStream *stream,
    const uint8_t **bytes,
    size_t *length
) {
    if (stream == NULL || bytes == NULL || length == NULL ||
        !stream->ready || stream->failed) {
        return false;
    }
    *bytes = stream->final.bytes;
    *length = stream->final.length;
    return true;
}

void kofun_semantic_derive_id(
    const char *domain,
    const KofunSemanticId *file_id,
    KofunSemanticNodeKind kind,
    KofunSemanticSpan span,
    uint32_t occurrence,
    KofunSemanticId *result
) {
    KofunSha256 sha;
    static const uint8_t prefix[6] = {'K', 'O', 'F', 'U', 'N', 0u};
    uint8_t domain_length_bytes[2];
    uint8_t payload_length_bytes[4];
    uint8_t kind_byte = (uint8_t)kind;
    uint8_t scalar_bytes[4];
    const uint32_t payload_length =
        KOFUN_SEMANTIC_ID_BYTES + 1u + 4u + 4u + 4u;
    size_t domain_length = domain == NULL ? 0u : strlen(domain);
    if (result == NULL || file_id == NULL ||
        domain == NULL || domain_length > UINT16_MAX) {
        if (result != NULL) memset(result, 0, sizeof(*result));
        return;
    }
    domain_length_bytes[0] = (uint8_t)(domain_length >> 8u);
    domain_length_bytes[1] = (uint8_t)domain_length;
    store_u32be(payload_length_bytes, payload_length);
    kofun_sha256_init(&sha);
    kofun_sha256_update(&sha, prefix, sizeof(prefix));
    kofun_sha256_update(
        &sha,
        domain_length_bytes,
        sizeof(domain_length_bytes)
    );
    kofun_sha256_update(&sha, (const uint8_t *)domain, domain_length);
    kofun_sha256_update(
        &sha,
        payload_length_bytes,
        sizeof(payload_length_bytes)
    );
    kofun_sha256_update(
        &sha,
        file_id->bytes,
        KOFUN_SEMANTIC_ID_BYTES
    );
    kofun_sha256_update(&sha, &kind_byte, sizeof(kind_byte));
    store_u32be(scalar_bytes, span.start);
    kofun_sha256_update(&sha, scalar_bytes, sizeof(scalar_bytes));
    store_u32be(scalar_bytes, span.end);
    kofun_sha256_update(&sha, scalar_bytes, sizeof(scalar_bytes));
    store_u32be(scalar_bytes, occurrence);
    kofun_sha256_update(&sha, scalar_bytes, sizeof(scalar_bytes));
    kofun_sha256_finish(&sha, result->bytes);
}

static void output_error(
    KofunSemanticError *error,
    const char *code,
    uint32_t record_index,
    uint8_t event_kind,
    const char *detail
) {
    if (error == NULL) return;
    memset(error, 0, sizeof(*error));
    (void)snprintf(error->code, sizeof(error->code), "%s", code);
    error->record_index = record_index;
    error->event_kind = event_kind;
    (void)snprintf(error->detail, sizeof(error->detail), "%s", detail);
}

bool kofun_semantic_stream_commit(
    KofunSemanticStream *stream,
    const char *destination
) {
    struct stat status;
    char *temporary;
    size_t path_length;
    unsigned attempt;
    FILE *file = NULL;
    bool write_ok;
    if (stream == NULL || destination == NULL || destination[0] == '\0' ||
        !stream->ready || stream->failed) {
        return false;
    }
    if (!kofun_semantic_validate_stream(
            stream->final.bytes,
            stream->final.length,
            &stream->error)) {
        stream->failed = true;
        stream->ready = false;
        return false;
    }
    if (lstat(destination, &status) == 0) {
        if (!S_ISREG(status.st_mode) || S_ISLNK(status.st_mode)) {
            return set_error(
                stream,
                "ETS04",
                KSE_EVENT_END,
                "destination is not a regular file"
            );
        }
    } else if (errno != ENOENT) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "cannot inspect stream destination"
        );
    }
    path_length = strlen(destination);
    if (path_length > SIZE_MAX - 64u) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "destination path is too long"
        );
    }
    temporary = (char *)malloc(path_length + 64u);
    if (temporary == NULL) {
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "temporary path allocation failed"
        );
    }
    for (attempt = 0u; attempt < 100u; attempt += 1u) {
        (void)snprintf(
            temporary,
            path_length + 64u,
            "%s.kofun-kse-tmp.%ld.%u",
            destination,
            (long)getpid(),
            attempt
        );
        file = fopen(temporary, "wbx");
        if (file != NULL) break;
        if (errno != EEXIST) break;
    }
    if (file == NULL) {
        free(temporary);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "cannot create temporary stream"
        );
    }
    write_ok = fwrite(
        stream->final.bytes,
        1u,
        stream->final.length,
        file
    ) == stream->final.length;
    if (write_ok) write_ok = fflush(file) == 0;
    if (write_ok) write_ok = fsync(fileno(file)) == 0;
    if (fclose(file) != 0) write_ok = false;
    if (!write_ok) {
        (void)unlink(temporary);
        free(temporary);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "cannot write temporary stream"
        );
    }
    if (rename(temporary, destination) != 0) {
        (void)unlink(temporary);
        free(temporary);
        return set_error(
            stream,
            "ETS04",
            KSE_EVENT_END,
            "cannot commit semantic stream"
        );
    }
    free(temporary);
    return true;
}

typedef struct {
    uint8_t tag;
    uint8_t wire;
    uint32_t length;
    const uint8_t *bytes;
} ParsedField;

static uint8_t expected_wire(uint8_t kind, uint8_t tag) {
    static const uint8_t source[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_ID, KSE_WIRE_ID, KSE_WIRE_UTF8,
        KSE_WIRE_U64, KSE_WIRE_ID, KSE_WIRE_UTF8, KSE_WIRE_UTF8,
        KSE_WIRE_U64, KSE_WIRE_U8
    };
    static const uint8_t node[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_U8, KSE_WIRE_SPAN, KSE_WIRE_U8,
        KSE_WIRE_ID_LIST, KSE_WIRE_ID_LIST
    };
    static const uint8_t identity[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_U8, KSE_WIRE_ID, KSE_WIRE_U8
    };
    static const uint8_t reference[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_ID, KSE_WIRE_U8, KSE_WIRE_SPAN,
        KSE_WIRE_U8, KSE_WIRE_U8, KSE_WIRE_U8, KSE_WIRE_ID,
        KSE_WIRE_UTF8, KSE_WIRE_ID_LIST
    };
    static const uint8_t fact[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_U8, KSE_WIRE_U8, KSE_WIRE_UTF8,
        KSE_WIRE_UTF8, KSE_WIRE_ID_LIST, KSE_WIRE_ID_LIST
    };
    static const uint8_t diagnostic[] = {
        0u, KSE_WIRE_ID, KSE_WIRE_UTF8, KSE_WIRE_UTF8, KSE_WIRE_U8,
        KSE_WIRE_UTF8, KSE_WIRE_ID, KSE_WIRE_SPAN, KSE_WIRE_UTF8,
        KSE_WIRE_ID_LIST, KSE_WIRE_U32_LIST, KSE_WIRE_U8,
        KSE_WIRE_BYTES, KSE_WIRE_BYTES
    };
    static const uint8_t end[] = {
        0u, KSE_WIRE_U8, KSE_WIRE_U8
    };
    switch (kind) {
        case KSE_EVENT_SOURCE:
            return tag < sizeof(source) ? source[tag] : 0u;
        case KSE_EVENT_NODE:
            return tag < sizeof(node) ? node[tag] : 0u;
        case KSE_EVENT_IDENTITY:
            return tag < sizeof(identity) ? identity[tag] : 0u;
        case KSE_EVENT_REFERENCE:
            return tag < sizeof(reference) ? reference[tag] : 0u;
        case KSE_EVENT_FACT:
            return tag < sizeof(fact) ? fact[tag] : 0u;
        case KSE_EVENT_DIAGNOSTIC:
            return tag < sizeof(diagnostic) ? diagnostic[tag] : 0u;
        case KSE_EVENT_END:
            return tag < sizeof(end) ? end[tag] : 0u;
        default:
            return 0u;
    }
}

static bool valid_wire_length(uint8_t wire, uint32_t length) {
    switch (wire) {
        case KSE_WIRE_UTF8:
        case KSE_WIRE_BYTES:
            return length <= KOFUN_SEMANTIC_MAX_TEXT_BYTES;
        case KSE_WIRE_ID:
            return length == KOFUN_SEMANTIC_ID_BYTES;
        case KSE_WIRE_U8:
            return length == 1u;
        case KSE_WIRE_U32:
            return length == 4u;
        case KSE_WIRE_U64:
        case KSE_WIRE_SPAN:
            return length == 8u;
        case KSE_WIRE_ID_LIST:
            return length % KOFUN_SEMANTIC_ID_BYTES == 0u &&
                length / KOFUN_SEMANTIC_ID_BYTES <=
                    KOFUN_SEMANTIC_MAX_RELATIONS;
        case KSE_WIRE_U32_LIST:
            return length % 4u == 0u &&
                length / 4u <= KOFUN_SEMANTIC_MAX_RELATIONS;
        default:
            return false;
    }
}

static bool exact_field_tags(
    uint8_t kind,
    const ParsedField *fields,
    uint16_t count
) {
    uint16_t index;
    if ((kind == KSE_EVENT_SOURCE && count != 10u) ||
        (kind == KSE_EVENT_NODE && count != 6u) ||
        (kind == KSE_EVENT_IDENTITY && count != 4u) ||
        (kind == KSE_EVENT_REFERENCE && count != 9u) ||
        (kind == KSE_EVENT_FACT && count != 7u) ||
        (kind == KSE_EVENT_DIAGNOSTIC && count != 13u) ||
        (kind == KSE_EVENT_END && count != 2u)) {
        return false;
    }
    for (index = 0u; index < count; index += 1u) {
        uint8_t expected = (uint8_t)(index + 1u);
        if (kind == KSE_EVENT_REFERENCE && index == 8u) {
            if (fields[7].tag == 8u) expected = 10u;
            else if (fields[7].tag == 9u) expected = 10u;
            else return false;
        } else if (kind == KSE_EVENT_REFERENCE && index == 7u) {
            expected = fields[index].tag;
            if (expected != 8u && expected != 9u) return false;
        }
        if (fields[index].tag != expected) return false;
    }
    return true;
}

static KofunSemanticBytes parsed_text(const ParsedField *field) {
    KofunSemanticBytes text;
    if (field == NULL || field->bytes == NULL) {
        text.bytes = NULL;
        text.length = 0u;
        return text;
    }
    text.bytes = field->bytes;
    text.length = field->length;
    return text;
}

static void parsed_id(
    const ParsedField *field,
    KofunSemanticId *id
) {
    if (id == NULL) return;
    if (field == NULL || field->bytes == NULL) {
        memset(id, 0, sizeof(*id));
        return;
    }
    memcpy(id->bytes, field->bytes, KOFUN_SEMANTIC_ID_BYTES);
}

static KofunSemanticSpan parsed_span(const ParsedField *field) {
    KofunSemanticSpan span;
    if (field == NULL || field->bytes == NULL) {
        span.start = 0u;
        span.end = 0u;
        return span;
    }
    span.start = load_u32be(field->bytes);
    span.end = load_u32be(field->bytes + 4u);
    return span;
}

static uint16_t parsed_id_list(
    const ParsedField *field,
    KofunSemanticId ids[KOFUN_SEMANTIC_MAX_RELATIONS]
) {
    if (field == NULL || field->bytes == NULL) return 0u;
    uint16_t count = (uint16_t)(
        field->length / KOFUN_SEMANTIC_ID_BYTES
    );
    if (count != 0u) {
        memcpy(ids, field->bytes, (size_t)count * sizeof(*ids));
    }
    return count;
}

static uint16_t parsed_u32_list(
    const ParsedField *field,
    uint32_t values[KOFUN_SEMANTIC_MAX_RELATIONS]
) {
    if (field == NULL || field->bytes == NULL) return 0u;
    uint16_t count = (uint16_t)(field->length / 4u);
    uint16_t index;
    for (index = 0u; index < count; index += 1u) {
        values[index] = load_u32be(field->bytes + (size_t)index * 4u);
    }
    return count;
}

static bool parsed_related_list(
    const ParsedField *field,
    KofunSemanticRelated related[KOFUN_SEMANTIC_MAX_RELATIONS],
    uint16_t *count
) {
    size_t cursor = 2u;
    uint16_t index;
    if (field == NULL || field->bytes == NULL || field->length < 2u) {
        return false;
    }
    *count = load_u16be(field->bytes);
    if (*count > KOFUN_SEMANTIC_MAX_RELATIONS) return false;
    for (index = 0u; index < *count; index += 1u) {
        uint16_t label_length;
        if ((size_t)field->length - cursor <
            KOFUN_SEMANTIC_ID_BYTES + 8u + 2u) {
            return false;
        }
        memcpy(
            related[index].file_id.bytes,
            field->bytes + cursor,
            KOFUN_SEMANTIC_ID_BYTES
        );
        cursor += KOFUN_SEMANTIC_ID_BYTES;
        related[index].span.start = load_u32be(field->bytes + cursor);
        related[index].span.end = load_u32be(field->bytes + cursor + 4u);
        cursor += 8u;
        label_length = load_u16be(field->bytes + cursor);
        cursor += 2u;
        if (label_length > (size_t)field->length - cursor) return false;
        related[index].label.bytes = field->bytes + cursor;
        related[index].label.length = label_length;
        cursor += label_length;
    }
    return cursor == field->length;
}

static bool parsed_edit_list(
    const ParsedField *field,
    KofunSemanticEdit edits[KOFUN_SEMANTIC_MAX_RELATIONS],
    uint16_t *count
) {
    size_t cursor = 2u;
    uint16_t index;
    if (field == NULL || field->bytes == NULL || field->length < 2u) {
        return false;
    }
    *count = load_u16be(field->bytes);
    if (*count > KOFUN_SEMANTIC_MAX_RELATIONS) return false;
    for (index = 0u; index < *count; index += 1u) {
        uint16_t replacement_length;
        if ((size_t)field->length - cursor <
            4u + KOFUN_SEMANTIC_ID_BYTES + 8u + 2u) {
            return false;
        }
        edits[index].remedy_id = load_u32be(field->bytes + cursor);
        cursor += 4u;
        memcpy(
            edits[index].file_id.bytes,
            field->bytes + cursor,
            KOFUN_SEMANTIC_ID_BYTES
        );
        cursor += KOFUN_SEMANTIC_ID_BYTES;
        edits[index].span.start = load_u32be(field->bytes + cursor);
        edits[index].span.end = load_u32be(field->bytes + cursor + 4u);
        cursor += 8u;
        replacement_length = load_u16be(field->bytes + cursor);
        cursor += 2u;
        if (replacement_length > (size_t)field->length - cursor) {
            return false;
        }
        edits[index].replacement.bytes = field->bytes + cursor;
        edits[index].replacement.length = replacement_length;
        cursor += replacement_length;
    }
    return cursor == field->length;
}

static uint8_t parsed_u8(const ParsedField *field) {
    return field == NULL || field->bytes == NULL ? 0u : field->bytes[0];
}

static uint64_t parsed_u64(const ParsedField *field) {
    return field == NULL || field->bytes == NULL ?
        0u : load_u64be(field->bytes);
}

static bool emit_parsed_event(
    KofunSemanticSink *sink,
    uint8_t kind,
    const ParsedField *fields,
    uint16_t field_count
) {
    KofunSemanticId first[KOFUN_SEMANTIC_MAX_RELATIONS];
    KofunSemanticId second[KOFUN_SEMANTIC_MAX_RELATIONS];
    uint32_t remedies[KOFUN_SEMANTIC_MAX_RELATIONS];
    KofunSemanticRelated related[KOFUN_SEMANTIC_MAX_RELATIONS];
    KofunSemanticEdit edits[KOFUN_SEMANTIC_MAX_RELATIONS];
    memset(first, 0, sizeof(first));
    memset(second, 0, sizeof(second));
    memset(remedies, 0, sizeof(remedies));
    memset(related, 0, sizeof(related));
    memset(edits, 0, sizeof(edits));
    if (!exact_field_tags(kind, fields, field_count)) return false;
    {
        uint16_t index;
        for (index = 0u; index < field_count; index += 1u) {
            if (fields[index].bytes == NULL) return false;
        }
    }
    if (kind == KSE_EVENT_SOURCE) {
        KofunSemanticSource source;
        KofunSemanticId source_digest;
        memset(&source, 0, sizeof(source));
        parsed_id(&fields[0], &source.package_id);
        parsed_id(&fields[1], &source.module_id);
        parsed_id(&fields[2], &source.file_id);
        source.logical_path = parsed_text(&fields[3]);
        source.source_bytes = parsed_u64(&fields[4]);
        parsed_id(&fields[5], &source_digest);
        memcpy(source.source_sha256, source_digest.bytes, sizeof(source_digest.bytes));
        source.edition = parsed_text(&fields[6]);
        source.semantic_compatibility = parsed_text(&fields[7]);
        source.caller_generation = parsed_u64(&fields[8]);
        source.compiler_exit_class = parsed_u8(&fields[9]);
        return kofun_semantic_begin(sink, &source);
    }
    if (kind == KSE_EVENT_NODE) {
        KofunSemanticNode node;
        memset(&node, 0, sizeof(node));
        parsed_id(&fields[0], &node.node_id);
        node.kind = (KofunSemanticNodeKind)parsed_u8(&fields[1]);
        node.span = parsed_span(&fields[2]);
        node.status = (KofunSemanticStatus)parsed_u8(&fields[3]);
        node.dependency_count = parsed_id_list(&fields[4], first);
        node.dependencies = first;
        node.diagnostic_count = parsed_id_list(&fields[5], second);
        node.diagnostic_ids = second;
        return kofun_semantic_node(sink, &node);
    }
    if (kind == KSE_EVENT_IDENTITY) {
        KofunSemanticIdentity identity;
        memset(&identity, 0, sizeof(identity));
        parsed_id(&fields[0], &identity.owner_node_id);
        identity.kind = (KofunSemanticIdentityKind)parsed_u8(&fields[1]);
        parsed_id(&fields[2], &identity.value);
        identity.status = (KofunSemanticStatus)parsed_u8(&fields[3]);
        return kofun_semantic_identity(sink, &identity);
    }
    if (kind == KSE_EVENT_REFERENCE) {
        KofunSemanticReference reference;
        memset(&reference, 0, sizeof(reference));
        parsed_id(&fields[0], &reference.reference_id);
        parsed_id(&fields[1], &reference.source_node_id);
        reference.name_space =
            (KofunSemanticNamespace)parsed_u8(&fields[2]);
        reference.span = parsed_span(&fields[3]);
        reference.status =
            (KofunSemanticStatus)parsed_u8(&fields[4]);
        reference.target_shape =
            (KofunSemanticTargetShape)parsed_u8(&fields[5]);
        reference.target_kind =
            (KofunSemanticIdentityKind)parsed_u8(&fields[6]);
        if (fields[7].tag == 8u) {
            parsed_id(&fields[7], &reference.target_value);
        } else {
            reference.hidden_reason = parsed_text(&fields[7]);
        }
        reference.diagnostic_count = parsed_id_list(&fields[8], first);
        reference.diagnostic_ids = first;
        return kofun_semantic_reference(sink, &reference);
    }
    if (kind == KSE_EVENT_FACT) {
        KofunSemanticFact fact;
        memset(&fact, 0, sizeof(fact));
        parsed_id(&fields[0], &fact.owner_node_id);
        fact.kind = (KofunSemanticFactKind)parsed_u8(&fields[1]);
        fact.status = (KofunSemanticStatus)parsed_u8(&fields[2]);
        fact.display = parsed_text(&fields[3]);
        fact.reason = parsed_text(&fields[4]);
        fact.dependency_count = parsed_id_list(&fields[5], first);
        fact.dependencies = first;
        fact.diagnostic_count = parsed_id_list(&fields[6], second);
        fact.diagnostic_ids = second;
        return kofun_semantic_fact(sink, &fact);
    }
    if (kind == KSE_EVENT_DIAGNOSTIC) {
        KofunSemanticDiagnostic diagnostic;
        memset(&diagnostic, 0, sizeof(diagnostic));
        parsed_id(&fields[0], &diagnostic.diagnostic_id);
        diagnostic.code = parsed_text(&fields[1]);
        diagnostic.category = parsed_text(&fields[2]);
        diagnostic.severity =
            (KofunSemanticSeverity)parsed_u8(&fields[3]);
        diagnostic.template_id = parsed_text(&fields[4]);
        parsed_id(&fields[5], &diagnostic.primary_file_id);
        diagnostic.primary_span = parsed_span(&fields[6]);
        diagnostic.fallback_text = parsed_text(&fields[7]);
        diagnostic.affected_count = parsed_id_list(&fields[8], first);
        diagnostic.affected_ids = first;
        diagnostic.remedy_count = parsed_u32_list(&fields[9], remedies);
        diagnostic.remedy_ids = remedies;
        diagnostic.truncated = parsed_u8(&fields[10]) != 0u;
        if (parsed_u8(&fields[10]) > 1u) return false;
        if (!parsed_related_list(
                &fields[11],
                related,
                &diagnostic.related_count) ||
            !parsed_edit_list(
                &fields[12],
                edits,
                &diagnostic.edit_count)) {
            return false;
        }
        diagnostic.related = related;
        diagnostic.edits = edits;
        return kofun_semantic_diagnostic(sink, &diagnostic);
    }
    if (kind == KSE_EVENT_END) {
        KofunSourceStatus status =
            (KofunSourceStatus)parsed_u8(&fields[0]);
        KofunCompleteness completeness =
            (KofunCompleteness)parsed_u8(&fields[1]);
        if (status == KOFUN_SOURCE_CANCELLED) {
            kofun_semantic_cancellation_observed(sink);
        }
        return kofun_semantic_end(sink, status, completeness);
    }
    return false;
}

bool kofun_semantic_validate_stream(
    const uint8_t *bytes,
    size_t length,
    KofunSemanticError *error
) {
    uint32_t event_count;
    uint32_t payload_bytes;
    uint8_t expected_digest[32];
    KofunSha256 sha;
    size_t cursor;
    size_t payload_end;
    uint32_t event_index;
    KofunSemanticStream *decoded = NULL;
    KofunSemanticSink sink;
    const uint8_t *canonical = NULL;
    size_t canonical_length = 0u;
    if (error != NULL) memset(error, 0, sizeof(*error));
    if (bytes == NULL || length < 48u ||
        length > KOFUN_SEMANTIC_MAX_EVENT_BYTES + 48u) {
        output_error(error, "ETS04", 0u, 0u, "stream byte limit or truncation");
        return false;
    }
    if (memcmp(bytes, "KSE\0", 4u) != 0 ||
        load_u16be(bytes + 4u) != 1u ||
        load_u16be(bytes + 6u) != 0u) {
        output_error(error, "ETS03", 0u, 0u, "unknown KSE magic or version");
        return false;
    }
    event_count = load_u32be(bytes + 8u);
    payload_bytes = load_u32be(bytes + 12u);
    if (event_count < 2u || event_count > KOFUN_SEMANTIC_MAX_EVENTS ||
        payload_bytes > KOFUN_SEMANTIC_MAX_EVENT_BYTES ||
        (uint64_t)payload_bytes + 48u != length) {
        output_error(error, "ETS04", 0u, 0u, "invalid stream count or size");
        return false;
    }
    kofun_sha256_init(&sha);
    kofun_sha256_update(&sha, bytes, 16u + payload_bytes);
    kofun_sha256_finish(&sha, expected_digest);
    if (memcmp(
            expected_digest,
            bytes + 16u + payload_bytes,
            sizeof(expected_digest)) != 0) {
        output_error(error, "ETS03", 0u, 0u, "stream digest mismatch");
        return false;
    }
    decoded = kofun_semantic_stream_create();
    if (decoded == NULL) {
        output_error(error, "ETS04", 0u, 0u, "validator allocation failed");
        return false;
    }
    sink = kofun_semantic_stream_sink(decoded);
    cursor = 16u;
    payload_end = 16u + payload_bytes;
    for (event_index = 0u; event_index < event_count; event_index += 1u) {
        uint8_t kind;
        uint16_t field_count;
        uint32_t frame_payload;
        size_t frame_end;
        ParsedField fields[16];
        uint16_t field_index;
        uint8_t previous_tag = 0u;
        if (payload_end - cursor < 8u) {
            output_error(
                error,
                "ETS03",
                event_index,
                0u,
                "truncated event header"
            );
            goto fail;
        }
        kind = bytes[cursor];
        if (bytes[cursor + 1u] != 0u) {
            output_error(
                error,
                "ETS03",
                event_index,
                kind,
                "unknown event flags"
            );
            goto fail;
        }
        field_count = load_u16be(bytes + cursor + 2u);
        frame_payload = load_u32be(bytes + cursor + 4u);
        cursor += 8u;
        if (field_count > 16u || frame_payload > payload_end - cursor) {
            output_error(
                error,
                "ETS04",
                event_index,
                kind,
                "invalid field count or event size"
            );
            goto fail;
        }
        frame_end = cursor + frame_payload;
        memset(fields, 0, sizeof(fields));
        for (field_index = 0u;
             field_index < field_count;
             field_index += 1u) {
            uint8_t wire;
            uint32_t field_length;
            KofunSemanticBytes text;
            if (frame_end - cursor < 8u) {
                output_error(
                    error,
                    "ETS03",
                    event_index,
                    kind,
                    "truncated field header"
                );
                goto fail;
            }
            fields[field_index].tag = bytes[cursor];
            wire = bytes[cursor + 1u];
            fields[field_index].wire = wire;
            if (bytes[cursor + 2u] != 0u ||
                bytes[cursor + 3u] != 0u ||
                fields[field_index].tag <= previous_tag ||
                expected_wire(kind, fields[field_index].tag) != wire) {
                output_error(
                    error,
                    "ETS03",
                    event_index,
                    kind,
                    "unknown, duplicate, or out-of-order field"
                );
                goto fail;
            }
            previous_tag = fields[field_index].tag;
            field_length = load_u32be(bytes + cursor + 4u);
            cursor += 8u;
            if (!valid_wire_length(wire, field_length) ||
                field_length > frame_end - cursor) {
                output_error(
                    error,
                    "ETS04",
                    event_index,
                    kind,
                    "invalid field length"
                );
                goto fail;
            }
            fields[field_index].length = field_length;
            fields[field_index].bytes = bytes + cursor;
            if (wire == KSE_WIRE_UTF8) {
                text = parsed_text(&fields[field_index]);
                if (!kofun_semantic_validate_text(text)) {
                    output_error(
                        error,
                        "ETS04",
                        event_index,
                        kind,
                        "string is not bounded UTF-8 NFC"
                    );
                    goto fail;
                }
            }
            cursor += field_length;
        }
        if (cursor != frame_end ||
            !exact_field_tags(kind, fields, field_count) ||
            !emit_parsed_event(
                &sink,
                kind,
                fields,
                field_count)) {
            const KofunSemanticError *decoded_error =
                kofun_semantic_stream_error(decoded);
            if (decoded_error != NULL) {
                if (error != NULL) *error = *decoded_error;
                if (error != NULL) error->record_index = event_index;
            } else {
                output_error(
                    error,
                    "ETS03",
                    event_index,
                    kind,
                    "invalid event schema or semantic relation"
                );
            }
            goto fail;
        }
    }
    if (cursor != payload_end ||
        !kofun_semantic_stream_bytes(
            decoded,
            &canonical,
            &canonical_length) ||
        canonical_length != length ||
        memcmp(canonical, bytes, length) != 0) {
        output_error(
            error,
            "ETS03",
            event_count,
            0u,
            "trailing, missing, or non-canonical stream data"
        );
        goto fail;
    }
    kofun_semantic_stream_destroy(decoded);
    return true;

fail:
    kofun_semantic_stream_destroy(decoded);
    return false;
}

bool kofun_semantic_replay_stream(
    const uint8_t *bytes,
    size_t length,
    KofunSemanticSink *sink,
    KofunSemanticError *error
) {
    uint32_t event_count;
    uint32_t payload_bytes;
    uint32_t event_index;
    size_t cursor;
    size_t payload_end;
    if (error != NULL) memset(error, 0, sizeof(*error));
    if (!kofun_semantic_validate_stream(bytes, length, error)) {
        return false;
    }
    if (sink == NULL ||
        sink->begin == NULL ||
        sink->node == NULL ||
        sink->identity == NULL ||
        sink->reference == NULL ||
        sink->fact == NULL ||
        sink->diagnostic == NULL ||
        sink->end == NULL) {
        output_error(
            error,
            "ETS03",
            0u,
            0u,
            "replay sink is incomplete"
        );
        return false;
    }

    event_count = load_u32be(bytes + 8u);
    payload_bytes = load_u32be(bytes + 12u);
    cursor = 16u;
    payload_end = cursor + payload_bytes;
    for (event_index = 0u; event_index < event_count; event_index += 1u) {
        uint8_t kind = bytes[cursor];
        uint16_t field_count = load_u16be(bytes + cursor + 2u);
        uint32_t frame_payload = load_u32be(bytes + cursor + 4u);
        size_t frame_end;
        ParsedField fields[16];
        uint16_t field_index;
        cursor += 8u;
        frame_end = cursor + frame_payload;
        memset(fields, 0, sizeof(fields));
        for (field_index = 0u;
             field_index < field_count;
             field_index += 1u) {
            fields[field_index].tag = bytes[cursor];
            fields[field_index].wire = bytes[cursor + 1u];
            fields[field_index].length = load_u32be(bytes + cursor + 4u);
            cursor += 8u;
            fields[field_index].bytes = bytes + cursor;
            cursor += fields[field_index].length;
        }
        if (cursor != frame_end ||
            !emit_parsed_event(sink, kind, fields, field_count)) {
            output_error(
                error,
                "ETS03",
                event_index,
                kind,
                "replay sink rejected validated record"
            );
            return false;
        }
    }
    if (cursor != payload_end) {
        output_error(
            error,
            "ETS03",
            event_count,
            0u,
            "validated replay cursor mismatch"
        );
        return false;
    }
    return true;
}
