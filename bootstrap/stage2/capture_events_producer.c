/*
 * Compiler capture transaction producer (#1225).
 *
 * This analysis-only adapter runs the complete checked-capture pipeline of
 * `spec/concurrency/scoped-captures-v1.md` §14 and publishes its facts as one
 * complete KSE2 transaction: source, node, identity, capture section,
 * diagnostic and end events. Like `semantic_producer.c`, it is compiled in the
 * same translation unit as the maintained C half of the canonical pair and
 * calls its passes directly. It edits nothing in that pair and scrapes no
 * command output; `compiler.kofun` has no counterpart.
 *
 * The capture section is the compiler's in-memory checked record set, the
 * text `--emit-complete-capture-hir-v2` would publish, in its own canonical
 * order. Node spans come from the lifecycle facts and scope-HIR rows that
 * derived those records, and every derived NodeId must equal the one the
 * record commits. A slice bound retains no row, so its committed identity is
 * matched against token-bounded spans inside an origin of the same place.
 * Nothing is re-parsed and no fact is read back from a diagnostic.
 * Contract: §15 of the same specification.
 */
#include "sha256.h"

#define main kofun_stage2_capture_seed_main
#include "compiler.c"
#undef main

enum {
    CE_ID_BYTES = 32,
    CE_MAX_EVENTS = 16384,
    CE_MAX_CAPTURE_EVENTS = 8384,
    CE_MAX_PAYLOAD = 16 * 1024 * 1024,
    CE_MAX_FIELD = 16 * 1024,
    CE_MAX_ORIGINS = 256,
    CE_MAX_FALLBACK = 1024,
    CE_JSON_DEPTH = 32
};

/* KSE2 adds kind 13 for the §12 analysis-expression NodeId domain. Kinds
 * 1..12 keep their KSE1 meaning and `kofun.sidecar.node/v1` preimage. */
enum {
    CE_NODE_MODULE = 1,
    CE_NODE_FUNCTION = 2,
    CE_NODE_PARAMETER = 3,
    CE_NODE_SCOPE = 4,
    CE_NODE_LOCAL = 5,
    CE_NODE_ADT = 6,
    CE_NODE_CALL = 8,
    CE_NODE_ANALYSIS_EXPRESSION = 13
};

enum {
    CE_IDENTITY_PACKAGE = 1,
    CE_IDENTITY_MODULE = 2,
    CE_IDENTITY_FILE = 3,
    CE_IDENTITY_SCOPE = 4,
    CE_IDENTITY_BINDING = 5,
    CE_IDENTITY_TYPE = 8
};

enum {
    CE_WIRE_BYTES = 1,
    CE_WIRE_UTF8 = 2,
    CE_WIRE_ID = 3,
    CE_WIRE_U8 = 4,
    CE_WIRE_U32 = 5,
    CE_WIRE_U64 = 6,
    CE_WIRE_SPAN = 7,
    CE_WIRE_IDS = 8,
    CE_WIRE_U32S = 9
};

typedef enum {
    CE_CANCEL_NONE,
    CE_CANCEL_SOURCE,
    CE_CANCEL_LIFECYCLE,
    CE_CANCEL_CAPTURES
} CeCancel;

typedef struct { uint8_t bytes[CE_ID_BYTES]; } CeId;

typedef struct {
    CeId id;
    uint8_t kind;
    uint32_t start;
    uint32_t end;
} CeNode;

typedef struct {
    CeId owner;
    uint8_t kind;
    CeId value;
} CeIdentity;

typedef struct {
    CeId id;
    int64_t start;
    int64_t end;
} CeType;

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
} CeBytes;

/* One JSON value's exact text within the compiler's canonical document. */
typedef struct {
    const char *at;
    const char *end;
} CeJson;

typedef struct {
    const char *source;
    size_t source_length;
    const char *path;
    char *file_hex;
    CeId file_id;
    CeId package_id;
    CeId module_id;
    CeId module_node;
    CeNode *nodes;
    size_t node_count;
    size_t node_capacity;
    CeIdentity *identities;
    size_t identity_count;
    size_t identity_capacity;
    CeType *types;
    size_t type_count;
    bool types_ready;
    CeBytes section;
    size_t section_events;
    char failure_code[8];
    char failure[160];
} CeTransaction;

/* ------------------------------------------------------------ failures */

static bool ce_fail(CeTransaction *tx, const char *code, const char *message) {
    if (tx->failure_code[0] == '\0') {
        (void)snprintf(tx->failure_code, sizeof(tx->failure_code), "%s", code);
        (void)snprintf(tx->failure, sizeof(tx->failure), "%s", message);
    }
    return false;
}

/* ------------------------------------------------------------ bytes */

static bool ce_reserve(CeBytes *bytes, size_t extra) {
    size_t capacity;
    uint8_t *grown;
    if (extra > SIZE_MAX - bytes->length) return false;
    if (bytes->length + extra <= bytes->capacity) return true;
    capacity = bytes->capacity == 0u ? 256u : bytes->capacity;
    while (capacity < bytes->length + extra) {
        if (capacity > SIZE_MAX / 2u) return false;
        capacity *= 2u;
    }
    grown = realloc(bytes->data, capacity);
    if (grown == NULL) return false;
    bytes->data = grown;
    bytes->capacity = capacity;
    return true;
}

static bool ce_append(CeBytes *bytes, const void *data, size_t length) {
    if (!ce_reserve(bytes, length)) return false;
    if (length != 0u) memcpy(bytes->data + bytes->length, data, length);
    bytes->length += length;
    return true;
}

static void ce_put_uint(uint8_t *out, uint64_t value, size_t width) {
    size_t index;
    for (index = 0u; index < width; index += 1u) {
        out[width - 1u - index] = (uint8_t)(value >> (8u * index));
    }
}

static bool ce_append_uint(CeBytes *bytes, uint64_t value, size_t width) {
    uint8_t encoded[8];
    ce_put_uint(encoded, value, width);
    return ce_append(bytes, encoded, width);
}

static void ce_bytes_free(CeBytes *bytes) {
    free(bytes->data);
    bytes->data = NULL;
    bytes->length = 0u;
    bytes->capacity = 0u;
}

/* ------------------------------------------------------------ identities */

static int ce_hex_digit(char symbol) {
    if (symbol >= '0' && symbol <= '9') return symbol - '0';
    if (symbol >= 'a' && symbol <= 'f') return symbol - 'a' + 10;
    return -1;
}

static bool ce_hex_decode(const char *hex, size_t length, CeBytes *out) {
    size_t index;
    if (length % 2u != 0u || !ce_reserve(out, length / 2u)) return false;
    for (index = 0u; index < length; index += 2u) {
        int high = ce_hex_digit(hex[index]);
        int low = ce_hex_digit(hex[index + 1u]);
        if (high < 0 || low < 0) return false;
        out->data[out->length++] = (uint8_t)(high * 16 + low);
    }
    return true;
}

static bool ce_id_nonzero(const CeId *id) {
    size_t index;
    for (index = 0u; index < CE_ID_BYTES; index += 1u) {
        if (id->bytes[index] != 0u) return true;
    }
    return false;
}

static bool ce_id_from_hex(const char *hex, size_t length, CeId *id) {
    size_t index;
    if (length != 2u * CE_ID_BYTES) return false;
    for (index = 0u; index < CE_ID_BYTES; index += 1u) {
        int high = ce_hex_digit(hex[2u * index]);
        int low = ce_hex_digit(hex[2u * index + 1u]);
        if (high < 0 || low < 0) return false;
        id->bytes[index] = (uint8_t)(high * 16 + low);
    }
    return ce_id_nonzero(id);
}

/* The compiler's identity helpers return owned hexadecimal text. */
static bool ce_id_owned(char *hex, CeId *id) {
    bool valid = ce_id_from_hex(hex, strlen(hex), id);
    free(hex);
    return valid;
}

static bool ce_id_equal(const CeId *left, const CeId *right) {
    return memcmp(left->bytes, right->bytes, CE_ID_BYTES) == 0;
}

/* The #303 frame over the shared streaming SHA-256. */
static void ce_frame_hash(const char *domain, const uint8_t *payload,
                          size_t length, CeId *result) {
    static const uint8_t prefix[6] = {'K', 'O', 'F', 'U', 'N', 0u};
    KofunSha256 sha;
    uint8_t width[4];
    size_t domain_length = strlen(domain);
    kofun_sha256_init(&sha);
    kofun_sha256_update(&sha, prefix, sizeof(prefix));
    ce_put_uint(width, domain_length, 2u);
    kofun_sha256_update(&sha, width, 2u);
    kofun_sha256_update(&sha, (const uint8_t *)domain, domain_length);
    ce_put_uint(width, length, 4u);
    kofun_sha256_update(&sha, width, 4u);
    kofun_sha256_update(&sha, payload, length);
    kofun_sha256_finish(&sha, result->bytes);
}

static void ce_expression_id(const CeTransaction *tx, uint32_t start,
                             uint32_t end, CeId *result) {
    uint8_t payload[CE_ID_BYTES + 8u];
    memcpy(payload, tx->file_id.bytes, CE_ID_BYTES);
    ce_put_uint(payload + CE_ID_BYTES, start, 4u);
    ce_put_uint(payload + CE_ID_BYTES + 4u, end, 4u);
    ce_frame_hash("kofun.stage2.analysis-expression/v1", payload,
                  sizeof(payload), result);
}

static void ce_syntax_node_id(const CeTransaction *tx, uint8_t kind,
                              uint32_t start, uint32_t end, CeId *result) {
    uint8_t payload[CE_ID_BYTES + 13u];
    memcpy(payload, tx->file_id.bytes, CE_ID_BYTES);
    payload[CE_ID_BYTES] = kind;
    ce_put_uint(payload + CE_ID_BYTES + 1u, start, 4u);
    ce_put_uint(payload + CE_ID_BYTES + 5u, end, 4u);
    ce_put_uint(payload + CE_ID_BYTES + 9u, 0u, 4u);
    ce_frame_hash("kofun.sidecar.node/v1", payload, sizeof(payload), result);
}

static void ce_named_id(const CeTransaction *tx, const char *domain,
                        const char *name, CeId *result) {
    size_t length = strlen(name);
    uint8_t *payload = allocate(CE_ID_BYTES + length);
    memcpy(payload, tx->file_id.bytes, CE_ID_BYTES);
    memcpy(payload + CE_ID_BYTES, name, length);
    ce_frame_hash(domain, payload, CE_ID_BYTES + length, result);
    free(payload);
}

/* ------------------------------------------------------------ nodes */

static bool ce_node_find(const CeTransaction *tx, const CeId *id, size_t *at) {
    size_t index;
    for (index = 0u; index < tx->node_count; index += 1u) {
        if (ce_id_equal(&tx->nodes[index].id, id)) {
            if (at != NULL) *at = index;
            return true;
        }
    }
    return false;
}

/* Commit one node derived from compiler facts. When the record names the
 * node, the derivation must reproduce exactly that NodeId. */
static bool ce_node(CeTransaction *tx, uint8_t kind, int64_t start, int64_t end,
                    const CeId *expected, CeId *out) {
    CeId id;
    size_t at;
    if (start < 0 || end < start || (uint64_t)end > tx->source_length ||
        (kind == CE_NODE_ANALYSIS_EXPRESSION && start == end)) {
        return ce_fail(tx, "ETS03", "a compiler node span is outside the committed source");
    }
    if (kind == CE_NODE_ANALYSIS_EXPRESSION) {
        ce_expression_id(tx, (uint32_t)start, (uint32_t)end, &id);
    } else {
        ce_syntax_node_id(tx, kind, (uint32_t)start, (uint32_t)end, &id);
    }
    if (expected != NULL && !ce_id_equal(&id, expected)) {
        return ce_fail(tx, "ETS03", "a checked record names a node its source facts do not derive");
    }
    if (out != NULL) *out = id;
    if (ce_node_find(tx, &id, &at)) {
        const CeNode *node = &tx->nodes[at];
        if (node->kind != kind || node->start != (uint32_t)start ||
            node->end != (uint32_t)end) {
            return ce_fail(tx, "ETS03", "one NodeId names two committed spans");
        }
        return true;
    }
    if (tx->node_count == tx->node_capacity) {
        size_t capacity = tx->node_capacity == 0u ? 64u : tx->node_capacity * 2u;
        CeNode *grown = realloc(tx->nodes, capacity * sizeof(*grown));
        if (grown == NULL) return ce_fail(tx, "ETS04", "node allocation failed");
        tx->nodes = grown;
        tx->node_capacity = capacity;
    }
    tx->nodes[tx->node_count].id = id;
    tx->nodes[tx->node_count].kind = kind;
    tx->nodes[tx->node_count].start = (uint32_t)start;
    tx->nodes[tx->node_count].end = (uint32_t)end;
    tx->node_count += 1u;
    return true;
}

static bool ce_identity(CeTransaction *tx, const CeId *owner, uint8_t kind,
                        const CeId *value) {
    size_t index;
    for (index = 0u; index < tx->identity_count; index += 1u) {
        const CeIdentity *identity = &tx->identities[index];
        bool same_value = identity->kind == kind &&
            ce_id_equal(&identity->value, value);
        bool same_owner = identity->kind == kind &&
            ce_id_equal(&identity->owner, owner);
        if (same_value && same_owner) return true;
        if (same_value || same_owner) {
            return ce_fail(tx, "ETS03", "a committed identity needs exactly one owner node");
        }
    }
    if (tx->identity_count == tx->identity_capacity) {
        size_t capacity = tx->identity_capacity == 0u ? 64u : tx->identity_capacity * 2u;
        CeIdentity *grown = realloc(tx->identities, capacity * sizeof(*grown));
        if (grown == NULL) return ce_fail(tx, "ETS04", "identity allocation failed");
        tx->identities = grown;
        tx->identity_capacity = capacity;
    }
    tx->identities[tx->identity_count].owner = *owner;
    tx->identities[tx->identity_count].kind = kind;
    tx->identities[tx->identity_count].value = *value;
    tx->identity_count += 1u;
    return true;
}

/* The anonymous-single-file identities of `semantic_producer.c`. The module
 * root spans the whole committed source and owns them. */
static bool ce_module(CeTransaction *tx) {
    Buffer package;
    Buffer file;
    Buffer module;
    buffer_init(&package);
    buffer_init(&file);
    buffer_init(&module);
    buffer_format(&package,
        "kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=%s\n",
        tx->path);
    buffer_format(&file,
        "kofun.file-id-input/v1\npackage-payload-begin\n%spackage-payload-end\n"
        "logical-path=%s\nsource-role=authored\nprovenance=explicit-source\n",
        package.data, tx->path);
    buffer_format(&module,
        "kofun.module-id-input/v1\npackage-payload-begin\n%spackage-payload-end\n"
        "kind=synthetic-root\n", package.data);
    ce_frame_hash("kofun.id.package/v1", (const uint8_t *)package.data,
                  package.length, &tx->package_id);
    ce_frame_hash("kofun.id.file/v1", (const uint8_t *)file.data, file.length,
                  &tx->file_id);
    ce_frame_hash("kofun.id.module/v1", (const uint8_t *)module.data,
                  module.length, &tx->module_id);
    free(package.data);
    free(file.data);
    free(module.data);
    tx->file_hex = scoped_hir_file_id(tx->path);
    {
        CeId compiler_file;
        char *copy = owned_text(tx->file_hex);
        if (!ce_id_owned(copy, &compiler_file) ||
            !ce_id_equal(&compiler_file, &tx->file_id)) {
            return ce_fail(tx, "ETS03", "the compiler FileId disagrees with the source FileId");
        }
    }
    return ce_node(tx, CE_NODE_MODULE, 0, (int64_t)tx->source_length, NULL,
                   &tx->module_node) &&
        ce_identity(tx, &tx->module_node, CE_IDENTITY_PACKAGE, &tx->package_id) &&
        ce_identity(tx, &tx->module_node, CE_IDENTITY_MODULE, &tx->module_id) &&
        ce_identity(tx, &tx->module_node, CE_IDENTITY_FILE, &tx->file_id);
}

/* A scope-HIR row, located by its decimal resolver number. */
static int64_t ce_hir_row(const char *hir, const char *kind, const char *number) {
    int64_t row = hir_record_start(hir, kind, 0);
    while (row >= 0) {
        char *found = hir_field(hir, row, 1);
        bool match = strcmp(found, number) == 0;
        free(found);
        if (match) return row;
        row = hir_record_start(hir, kind, row + 1);
    }
    return -1;
}

static int64_t ce_integer(const char *text, int64_t row, int field) {
    char *value = hir_field(text, row, field);
    int64_t result = value[0] == '\0' ? -1 : decimal_value(value);
    free(value);
    return result;
}

/* Scope nodes follow `semantic_producer.c`: kind Scope over the row's
 * open/close span, owning `kofun.stage2.scope/v1` over `hir-scope:N`. */
static bool ce_scope(CeTransaction *tx, const char *hir, const char *number,
                     const CeId *expected) {
    int64_t row = ce_hir_row(hir, "scope", number);
    CeId node;
    CeId value;
    if (row < 0) return ce_fail(tx, "ETS03", "a committed ScopeId has no scope-HIR row");
    if (!ce_id_owned(scoped_hir_named_id(tx->file_hex, "scope", number), &value) ||
        (expected != NULL && !ce_id_equal(&value, expected))) {
        return ce_fail(tx, "ETS03", "a checked record names a scope the resolver did not commit");
    }
    return ce_node(tx, CE_NODE_SCOPE, ce_integer(hir, row, 4),
                   ce_integer(hir, row, 5), NULL, &node) &&
        ce_identity(tx, &node, CE_IDENTITY_SCOPE, &value);
}

/* Binding nodes follow `semantic_producer.c`: a binding of a `parameters`
 * scope is a parameter, every other binding a local, over the row's
 * declaration span. Compiler-owned spawn handles keep their spawn span. */
static bool ce_binding(CeTransaction *tx, const char *hir, const char *number,
                       const CeId *expected) {
    int64_t row = ce_hir_row(hir, "binding", number);
    CeId node;
    CeId value;
    char *scope;
    char *scope_kind;
    int64_t scope_row;
    uint8_t kind;
    if (row < 0) return ce_fail(tx, "ETS03", "a committed BindingId has no scope-HIR row");
    if (!ce_id_owned(scoped_hir_named_id(tx->file_hex, "binding", number), &value) ||
        (expected != NULL && !ce_id_equal(&value, expected))) {
        return ce_fail(tx, "ETS03", "a checked record names a binding the resolver did not commit");
    }
    scope = hir_field(hir, row, 2);
    scope_row = ce_hir_row(hir, "scope", scope);
    free(scope);
    if (scope_row < 0) return ce_fail(tx, "ETS03", "a committed binding has no scope");
    scope_kind = hir_field(hir, scope_row, 3);
    kind = strcmp(scope_kind, "parameters") == 0 ? CE_NODE_PARAMETER : CE_NODE_LOCAL;
    free(scope_kind);
    return ce_node(tx, kind, ce_integer(hir, row, 8), ce_integer(hir, row, 9),
                   NULL, &node) &&
        ce_identity(tx, &node, CE_IDENTITY_BINDING, &value);
}

static bool ce_binding_by_id(CeTransaction *tx, const char *hir, const CeId *id) {
    int64_t row = hir_record_start(hir, "binding", 0);
    while (row >= 0) {
        char *number = hir_field(hir, row, 1);
        CeId value;
        bool match = ce_id_owned(scoped_hir_named_id(tx->file_hex, "binding", number), &value) &&
            ce_id_equal(&value, id);
        bool committed = match && ce_binding(tx, hir, number, id);
        free(number);
        if (match) return committed;
        row = hir_record_start(hir, "binding", row + 1);
    }
    return ce_fail(tx, "ETS03", "a place names a BindingId the resolver did not commit");
}

/* Nominal owner TypeIds are the §12 record identities. The declaration walk
 * is the one `capture_catalog` already validated for this source. */
static bool ce_type(CeTransaction *tx, CheckedPlaceArena *arena, const CeId *id) {
    size_t index;
    if (!tx->types_ready) {
        int64_t length = (int64_t)strlen(tx->source);
        int64_t at = after_optional_module_header(tx->source, 0);
        size_t capacity = 0u;
        while (at < length) {
            int64_t declaration = type_declaration_start(tx->source, at);
            int64_t end = top_level_end(tx->source, at);
            if (end <= at) return ce_fail(tx, "ETS03", "a checked source declaration has no end");
            if (declaration >= 0 && record_declaration_at(tx->source, declaration)) {
                char *name = type_name(tx->source, declaration);
                CeId type;
                bool valid = ce_id_from_hex(cp_type_id(arena, tx->path, name),
                                            2u * CE_ID_BYTES, &type);
                free(name);
                if (!valid) return ce_fail(tx, "ETS03", "record TypeId is not derivable");
                if (tx->type_count == capacity) {
                    CeType *grown;
                    capacity = capacity == 0u ? 16u : capacity * 2u;
                    grown = realloc(tx->types, capacity * sizeof(*grown));
                    if (grown == NULL) return ce_fail(tx, "ETS04", "type allocation failed");
                    tx->types = grown;
                }
                tx->types[tx->type_count].id = type;
                tx->types[tx->type_count].start = at;
                tx->types[tx->type_count].end = end;
                tx->type_count += 1u;
            }
            at = skip_trivia(tx->source, end);
        }
        tx->types_ready = true;
    }
    for (index = 0u; index < tx->type_count; index += 1u) {
        CeId node;
        if (!ce_id_equal(&tx->types[index].id, id)) continue;
        return ce_node(tx, CE_NODE_ADT, tx->types[index].start,
                       tx->types[index].end, NULL, &node) &&
            ce_identity(tx, &node, CE_IDENTITY_TYPE, id);
    }
    return ce_fail(tx, "ETS03", "a field names a TypeId no record declaration commits");
}

/* ------------------------------------------------------------ JSON */

/* The records are the compiler's closed canonical scope-HIR v2 document,
 * so this reader accepts exactly that shape and refuses anything else. */
static const char *ce_json_skip(const char *at, const char *end, int depth) {
    if (at >= end || depth > CE_JSON_DEPTH) return NULL;
    if (*at == '"') {
        for (++at; at < end; ++at) {
            if (*at == '\\') {
                if (++at >= end) return NULL;
            } else if (*at == '"') {
                return at + 1;
            }
        }
        return NULL;
    }
    if (*at == '{' || *at == '[') {
        char close = *at == '{' ? '}' : ']';
        bool object = *at == '{';
        ++at;
        if (at < end && *at == close) return at + 1;
        while (at < end) {
            if (object) {
                if (*at != '"') return NULL;
                at = ce_json_skip(at, end, depth + 1);
                if (at == NULL || at >= end || *at != ':') return NULL;
                ++at;
            }
            at = ce_json_skip(at, end, depth + 1);
            if (at == NULL || at >= end) return NULL;
            if (*at == close) return at + 1;
            if (*at != ',') return NULL;
            ++at;
        }
        return NULL;
    }
    if (*at == '-' || (*at >= '0' && *at <= '9')) {
        ++at;
        while (at < end && *at >= '0' && *at <= '9') ++at;
        return at;
    }
    if ((size_t)(end - at) >= 4u && memcmp(at, "null", 4u) == 0) return at + 4;
    return NULL;
}

static bool ce_json_value(const char *at, const char *end, CeJson *value) {
    const char *after = ce_json_skip(at, end, 0);
    if (after == NULL) return false;
    value->at = at;
    value->end = after;
    return true;
}

static bool ce_json_member(CeJson object, const char *key, CeJson *value) {
    const char *at = object.at;
    size_t key_length = strlen(key);
    if (at >= object.end || *at != '{') return false;
    ++at;
    while (at < object.end && *at == '"') {
        const char *name = at + 1;
        const char *name_end = ce_json_skip(at, object.end, 1);
        CeJson member;
        if (name_end == NULL || name_end >= object.end || *name_end != ':' ||
            !ce_json_value(name_end + 1, object.end, &member)) {
            return false;
        }
        if ((size_t)(name_end - 1 - name) == key_length &&
            memcmp(name, key, key_length) == 0) {
            *value = member;
            return true;
        }
        at = member.end;
        if (at < object.end && *at == ',') ++at;
    }
    return false;
}

/* Iterate an array; `cursor` starts NULL. */
static bool ce_json_next(CeJson array, const char **cursor, CeJson *item) {
    const char *at = *cursor == NULL ? array.at + 1 : *cursor;
    if (array.at >= array.end || *array.at != '[') return false;
    if (*cursor != NULL) {
        if (at >= array.end || *at != ',') return false;
        ++at;
    }
    if (at >= array.end || *at == ']') return false;
    if (!ce_json_value(at, array.end, item)) return false;
    *cursor = item->end;
    return true;
}

static bool ce_json_text(CeJson value, const char **text, size_t *length) {
    const char *at;
    if (value.end - value.at < 2 || *value.at != '"' || value.end[-1] != '"') {
        return false;
    }
    for (at = value.at + 1; at < value.end - 1; ++at) {
        if (*at == '\\') return false;
    }
    *text = value.at + 1;
    *length = (size_t)(value.end - value.at - 2);
    return true;
}

static bool ce_json_is(CeJson value, const char *text) {
    const char *found;
    size_t length;
    return ce_json_text(value, &found, &length) && length == strlen(text) &&
        memcmp(found, text, length) == 0;
}

static bool ce_json_field_is(CeJson object, const char *key, const char *text) {
    CeJson value;
    return ce_json_member(object, key, &value) && ce_json_is(value, text);
}

static bool ce_json_id(CeJson object, const char *key, CeId *id) {
    CeJson value;
    const char *text;
    size_t length;
    return ce_json_member(object, key, &value) &&
        ce_json_text(value, &text, &length) && ce_id_from_hex(text, length, id);
}

static bool ce_json_u32(CeJson object, const char *key, uint32_t *out) {
    CeJson value;
    const char *at;
    uint64_t result = 0u;
    if (!ce_json_member(object, key, &value) || value.at == value.end ||
        (value.end - value.at > 1 && *value.at == '0')) {
        return false;
    }
    for (at = value.at; at < value.end; ++at) {
        if (*at < '0' || *at > '9') return false;
        result = result * 10u + (uint64_t)(*at - '0');
        if (result > UINT32_MAX) return false;
    }
    *out = (uint32_t)result;
    return true;
}

static bool ce_json_hex(CeJson object, const char *key, CeBytes *out) {
    CeJson value;
    const char *text;
    size_t length;
    return ce_json_member(object, key, &value) &&
        ce_json_text(value, &text, &length) && ce_hex_decode(text, length, out);
}

/* ------------------------------------------------------------ frames */

typedef struct {
    CeBytes payload;
    uint16_t fields;
} CeFrame;

static bool ce_field(CeFrame *frame, uint8_t tag, uint8_t wire,
                     const void *data, size_t length) {
    uint8_t header[8];
    if (length > CE_MAX_FIELD) return false;
    header[0] = tag;
    header[1] = wire;
    header[2] = 0u;
    header[3] = 0u;
    ce_put_uint(header + 4, length, 4u);
    frame->fields += 1u;
    return ce_append(&frame->payload, header, sizeof(header)) &&
        ce_append(&frame->payload, data, length);
}

static bool ce_field_id(CeFrame *frame, uint8_t tag, const CeId *id) {
    return ce_field(frame, tag, CE_WIRE_ID, id->bytes, CE_ID_BYTES);
}

static bool ce_field_uint(CeFrame *frame, uint8_t tag, uint8_t wire,
                          uint64_t value) {
    uint8_t encoded[8];
    size_t width = wire == CE_WIRE_U8 ? 1u : wire == CE_WIRE_U32 ? 4u : 8u;
    ce_put_uint(encoded, value, width);
    return ce_field(frame, tag, wire, encoded, width);
}

static bool ce_field_span(CeFrame *frame, uint8_t tag, uint32_t start,
                          uint32_t end) {
    uint8_t encoded[8];
    ce_put_uint(encoded, start, 4u);
    ce_put_uint(encoded + 4, end, 4u);
    return ce_field(frame, tag, CE_WIRE_SPAN, encoded, sizeof(encoded));
}

static bool ce_field_text(CeFrame *frame, uint8_t tag, const char *text) {
    return ce_field(frame, tag, CE_WIRE_UTF8, text, strlen(text));
}

static bool ce_frame_commit(CeBytes *out, uint8_t kind, CeFrame *frame) {
    uint8_t header[8];
    bool ok;
    header[0] = kind;
    header[1] = 0u;
    ce_put_uint(header + 2, frame->fields, 2u);
    ce_put_uint(header + 4, frame->payload.length, 4u);
    ok = ce_append(out, header, sizeof(header)) &&
        ce_append(out, frame->payload.data, frame->payload.length);
    ce_bytes_free(&frame->payload);
    frame->fields = 0u;
    return ok;
}

/* ------------------------------------------------------------ section */

static bool ce_section_frame(CeTransaction *tx, uint8_t kind, CeFrame *frame) {
    if (tx->section_events >= CE_MAX_CAPTURE_EVENTS) {
        ce_bytes_free(&frame->payload);
        return ce_fail(tx, "ETS04", "capture event count exceeds the v2 limit");
    }
    tx->section_events += 1u;
    if (!ce_frame_commit(&tx->section, kind, frame)) {
        return ce_fail(tx, "ETS04", "capture frame allocation failed");
    }
    return true;
}

static int64_t ce_fact_row(const char *facts, const char *kind, int field,
                           const char *value) {
    int64_t row = hir_record_start(facts, kind, 0);
    while (row >= 0) {
        char *found = hir_field(facts, row, field);
        bool match = strcmp(found, value) == 0;
        free(found);
        if (match) return row;
        row = hir_record_start(facts, kind, row + 1);
    }
    return -1;
}

/* §11 lifecycle records, zipped with the lifecycle fact rows that derived
 * them. Records arrive in their canonical par/task/join order. */
static bool ce_lifecycle_record(CeTransaction *tx, const char *hir,
                                const char *facts, CeJson record,
                                int64_t *task_row) {
    CeFrame frame = {{0}, 0u};
    CeId id;
    CeId node;
    CeId first;
    CeId second;
    CeId third;
    uint32_t index;
    if (ce_json_field_is(record, "record", "par")) {
        char number[24];
        int64_t row;
        char *scope;
        char *token;
        bool ok;
        CeId root;
        if (!ce_json_u32(record, "lexical_index", &index) ||
            !ce_json_id(record, "id", &id) ||
            !ce_json_id(record, "node_id", &node) ||
            !ce_json_id(record, "scope_id", &first) ||
            !ce_json_id(record, "parent_scope_id", &root) ||
            !ce_json_id(record, "scope_token_binding_id", &second)) {
            return ce_fail(tx, "ETS03", "a par record is not the closed v2 shape");
        }
        (void)snprintf(number, sizeof(number), "%" PRIu32, index);
        row = ce_fact_row(facts, "par", 1, number);
        if (row < 0) return ce_fail(tx, "ETS03", "a par record has no lifecycle fact");
        scope = hir_field(facts, row, 4);
        token = hir_field(facts, row, 5);
        ok = ce_node(tx, CE_NODE_SCOPE, ce_integer(facts, row, 2),
                     ce_integer(facts, row, 3), &node, NULL) &&
            ce_scope(tx, hir, "0", &root) &&
            ce_scope(tx, hir, scope, &first) &&
            ce_binding(tx, hir, token, &second);
        free(scope);
        free(token);
        return ok &&
            ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &node) &&
            ce_field_id(&frame, 3u, &first) && ce_field_id(&frame, 4u, &root) &&
            ce_field_id(&frame, 5u, &second) &&
            ce_field_uint(&frame, 6u, CE_WIRE_U32, index) &&
            ce_section_frame(tx, 8u, &frame);
    }
    if (ce_json_field_is(record, "record", "task")) {
        char *handle;
        bool ok;
        *task_row = hir_record_start(facts, "task", *task_row < 0 ? 0 : *task_row + 1);
        if (*task_row < 0 ||
            !ce_json_u32(record, "lexical_index", &index) ||
            !ce_json_id(record, "id", &id) ||
            !ce_json_id(record, "par_id", &node) ||
            !ce_json_id(record, "spawn_node_id", &first) ||
            !ce_json_id(record, "lambda_node_id", &second) ||
            !ce_json_id(record, "handle_binding_id", &third)) {
            return ce_fail(tx, "ETS03", "a task record has no lifecycle fact or closed shape");
        }
        handle = hir_field(facts, *task_row, 7);
        ok = ce_node(tx, CE_NODE_CALL, ce_integer(facts, *task_row, 3),
                     ce_integer(facts, *task_row, 4), &first, NULL) &&
            ce_node(tx, CE_NODE_FUNCTION, ce_integer(facts, *task_row, 5),
                    ce_integer(facts, *task_row, 6), &second, NULL) &&
            ce_binding(tx, hir, handle, &third);
        free(handle);
        return ok &&
            ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &node) &&
            ce_field_id(&frame, 3u, &first) && ce_field_id(&frame, 4u, &second) &&
            ce_field_id(&frame, 5u, &third) &&
            ce_field_uint(&frame, 6u, CE_WIRE_U32, index) &&
            ce_section_frame(tx, 9u, &frame);
    }
    if (ce_json_field_is(record, "record", "join")) {
        CeJson node_value;
        char *handle;
        int64_t join;
        bool explicit_join = ce_json_field_is(record, "join_kind", "explicit");
        *task_row = hir_record_start(facts, "task", *task_row < 0 ? 0 : *task_row + 1);
        if (*task_row < 0 || !ce_json_id(record, "id", &id) ||
            !ce_json_id(record, "task_id", &first) ||
            !ce_json_member(record, "node_id", &node_value) ||
            (!explicit_join && !ce_json_field_is(record, "join_kind", "scope-exit"))) {
            return ce_fail(tx, "ETS03", "a join record has no lifecycle fact or closed shape");
        }
        handle = hir_field(facts, *task_row, 7);
        join = ce_fact_row(facts, "join", 1, handle);
        free(handle);
        if ((join >= 0) != explicit_join) {
            return ce_fail(tx, "ETS03", "a join record disagrees with its lifecycle fact");
        }
        if (explicit_join) {
            if (!ce_json_id(record, "node_id", &node) ||
                !ce_node(tx, CE_NODE_CALL, ce_integer(facts, join, 2),
                         ce_integer(facts, join, 3), &node, NULL)) {
                return ce_fail(tx, "ETS03", "an explicit join names no committed call");
            }
        } else if (node_value.end - node_value.at != 4 ||
                   memcmp(node_value.at, "null", 4u) != 0) {
            return ce_fail(tx, "ETS03", "a scope-exit join names a node");
        }
        return ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &first) &&
            ce_field_uint(&frame, 3u, CE_WIRE_U8, explicit_join ? 1u : 2u) &&
            (!explicit_join || ce_field_id(&frame, 4u, &node)) &&
            ce_section_frame(tx, 10u, &frame);
    }
    return ce_fail(tx, "ETS03", "a lifecycle record is out of phase order");
}

/* Commit every analysis-expression origin of the capture records. */
static bool ce_origins(CeTransaction *tx, CeJson records, const char *after) {
    const char *cursor = after;
    CeJson record;
    while (ce_json_next(records, &cursor, &record)) {
        CeJson origins;
        CeJson origin;
        const char *at = NULL;
        size_t count = 0u;
        if (!ce_json_field_is(record, "record", "capture")) continue;
        if (!ce_json_member(record, "origins", &origins)) {
            return ce_fail(tx, "ETS03", "a capture record has no origins");
        }
        while (ce_json_next(origins, &at, &origin)) {
            CeJson span;
            CeId node;
            uint32_t start;
            uint32_t end;
            if (!ce_json_id(origin, "node_id", &node) ||
                !ce_json_member(origin, "span", &span) ||
                !ce_json_u32(span, "start", &start) ||
                !ce_json_u32(span, "end", &end) ||
                !ce_node(tx, CE_NODE_ANALYSIS_EXPRESSION, start, end, &node, NULL)) {
                return ce_fail(tx, "ETS03", "a capture origin is not a committed source occurrence");
            }
            count += 1u;
        }
        if (count == 0u || count > CE_MAX_ORIGINS) {
            return ce_fail(tx, "ETS04", "capture origin count is outside the v2 limit");
        }
    }
    return true;
}

/* Find each still-uncommitted slice-bound NodeId among the token-bounded
 * spans of the place's own origins. A bound is an expression occurrence
 * inside the checked place or the outer call that instantiated it. */
static bool ce_bounds(CeTransaction *tx, CeJson records, const char *after,
                      const CeId *place, CeId *bounds, size_t count) {
    const char *cursor = after;
    CeJson record;
    size_t remaining = 0u;
    size_t index;
    for (index = 0u; index < count; index += 1u) {
        if (!ce_node_find(tx, &bounds[index], NULL)) remaining += 1u;
    }
    while (remaining != 0u && ce_json_next(records, &cursor, &record)) {
        CeJson origins;
        CeJson origin;
        CeId target;
        const char *at = NULL;
        if (!ce_json_field_is(record, "record", "capture") ||
            !ce_json_id(record, "target_id", &target) ||
            !ce_id_equal(&target, place) ||
            !ce_json_member(record, "origins", &origins)) {
            continue;
        }
        while (remaining != 0u && ce_json_next(origins, &at, &origin)) {
            CeJson span;
            uint32_t start;
            uint32_t end;
            int64_t token;
            int64_t *starts = NULL;
            int64_t *ends = NULL;
            size_t tokens = 0u;
            size_t capacity = 0u;
            size_t left;
            size_t right;
            if (!ce_json_member(origin, "span", &span) ||
                !ce_json_u32(span, "start", &start) ||
                !ce_json_u32(span, "end", &end)) {
                return ce_fail(tx, "ETS03", "a capture origin has no span");
            }
            token = skip_trivia(tx->source, start);
            while (token < (int64_t)end) {
                int64_t token_stop = token_end(tx->source, token);
                if (token_stop <= token || token_stop > (int64_t)end) break;
                if (tokens == capacity) {
                    int64_t *grown_starts;
                    int64_t *grown_ends;
                    capacity = capacity == 0u ? 32u : capacity * 2u;
                    grown_starts = realloc(starts, capacity * sizeof(*starts));
                    if (grown_starts == NULL) {
                        free(starts);
                        free(ends);
                        return ce_fail(tx, "ETS04", "bound search allocation failed");
                    }
                    starts = grown_starts;
                    grown_ends = realloc(ends, capacity * sizeof(*ends));
                    if (grown_ends == NULL) {
                        free(starts);
                        free(ends);
                        return ce_fail(tx, "ETS04", "bound search allocation failed");
                    }
                    ends = grown_ends;
                }
                starts[tokens] = token;
                ends[tokens] = token_stop;
                tokens += 1u;
                token = skip_trivia(tx->source, token_stop);
            }
            for (left = 0u; left < tokens && remaining != 0u; left += 1u) {
                for (right = left; right < tokens && remaining != 0u; right += 1u) {
                    CeId candidate;
                    ce_expression_id(tx, (uint32_t)starts[left],
                                     (uint32_t)ends[right], &candidate);
                    for (index = 0u; index < count; index += 1u) {
                        if (!ce_id_equal(&candidate, &bounds[index]) ||
                            ce_node_find(tx, &bounds[index], NULL)) {
                            continue;
                        }
                        if (!ce_node(tx, CE_NODE_ANALYSIS_EXPRESSION,
                                     starts[left], ends[right], &bounds[index], NULL)) {
                            free(starts);
                            free(ends);
                            return false;
                        }
                        remaining -= 1u;
                    }
                }
            }
            free(starts);
            free(ends);
        }
    }
    if (remaining != 0u) {
        return ce_fail(tx, "ETS03", "a slice bound names no occurrence inside its place's origins");
    }
    return true;
}

/* A known place: its base binding, field owners and dynamic bounds must all
 * be committed, and its KPL bytes must agree with the record. */
static bool ce_place_record(CeTransaction *tx, const char *hir,
                            CheckedPlaceArena *arena, CeJson records,
                            const char *after, CeJson record) {
    CeFrame frame = {{0}, 0u};
    CeBytes bytes = {0};
    CeId id;
    CeId base;
    CeId bounds[16];
    size_t bound_count = 0u;
    size_t at;
    size_t projection;
    size_t projections;
    bool ok;
    if (!ce_json_id(record, "id", &id) ||
        !ce_json_id(record, "base_binding_id", &base) ||
        !ce_json_hex(record, "canonical_bytes", &bytes) ||
        bytes.length < 38u || memcmp(bytes.data, "KPL\0\2", 5u) != 0 ||
        memcmp(bytes.data + 5, base.bytes, CE_ID_BYTES) != 0) {
        ce_bytes_free(&bytes);
        return ce_fail(tx, "ETS03", "a place record is not the closed v2 shape");
    }
    projections = bytes.data[37];
    at = 38u;
    for (projection = 0u; projection < projections; projection += 1u) {
        CeId value;
        if (at < bytes.length && bytes.data[at] == 1u && bytes.length - at >= 37u) {
            memcpy(value.bytes, bytes.data + at + 1u, CE_ID_BYTES);
            if (!ce_type(tx, arena, &value)) {
                ce_bytes_free(&bytes);
                return false;
            }
            at += 37u;
        } else if (at < bytes.length && bytes.data[at] == 2u) {
            int side;
            at += 1u;
            for (side = 0; side < 2; ++side) {
                if (at < bytes.length && bytes.data[at] == 1u && bytes.length - at >= 9u) {
                    at += 9u;
                } else if (at < bytes.length && bytes.data[at] == 2u &&
                           bytes.length - at >= 33u && bound_count < 16u) {
                    memcpy(bounds[bound_count].bytes, bytes.data + at + 1u, CE_ID_BYTES);
                    bound_count += 1u;
                    at += 33u;
                } else {
                    ce_bytes_free(&bytes);
                    return ce_fail(tx, "ETS03", "a place slice bound is not closed KPL bytes");
                }
            }
        } else {
            ce_bytes_free(&bytes);
            return ce_fail(tx, "ETS03", "a place projection is not closed KPL bytes");
        }
    }
    if (at != bytes.length) {
        ce_bytes_free(&bytes);
        return ce_fail(tx, "ETS03", "a place record has trailing KPL bytes");
    }
    ok = ce_binding_by_id(tx, hir, &base) &&
        ce_bounds(tx, records, after, &id, bounds, bound_count) &&
        ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &base) &&
        ce_field(&frame, 3u, CE_WIRE_BYTES, bytes.data, bytes.length) &&
        ce_section_frame(tx, 11u, &frame);
    ce_bytes_free(&bytes);
    ce_bytes_free(&frame.payload);
    return ok;
}

static bool ce_unknown_record(CeTransaction *tx, CeJson record) {
    static const char *const reasons[] = {
        "unresolved-call", "projection-depth-exceeded", "unnameable-place",
    };
    CeFrame frame = {{0}, 0u};
    CeBytes bytes = {0};
    CeId id;
    CeId task;
    CeId witness;
    size_t reason;
    size_t at;
    bool ok;
    if (!ce_json_id(record, "id", &id) || !ce_json_id(record, "task_id", &task) ||
        !ce_json_id(record, "witness_node_id", &witness) ||
        !ce_json_hex(record, "canonical_bytes", &bytes)) {
        ce_bytes_free(&bytes);
        return ce_fail(tx, "ETS03", "an unknown record is not the closed v2 shape");
    }
    for (reason = 0u; reason < 3u; reason += 1u) {
        if (ce_json_field_is(record, "reason", reasons[reason])) break;
    }
    /* The witness is its capture's sole origin, committed above. */
    if (reason == 3u || !ce_node_find(tx, &witness, &at) ||
        tx->nodes[at].kind != CE_NODE_ANALYSIS_EXPRESSION) {
        ce_bytes_free(&bytes);
        return ce_fail(tx, "ETS03", "an unknown record names no committed witness occurrence");
    }
    ok = ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &task) &&
        ce_field_id(&frame, 3u, &witness) &&
        ce_field_uint(&frame, 4u, CE_WIRE_U8, reason + 1u) &&
        ce_field(&frame, 5u, CE_WIRE_BYTES, bytes.data, bytes.length) &&
        ce_section_frame(tx, 12u, &frame);
    ce_bytes_free(&bytes);
    ce_bytes_free(&frame.payload);
    return ok;
}

static bool ce_capture_record(CeTransaction *tx, CeJson record) {
    static const char *const modes[] = {"read", "edit", "take"};
    CeFrame frame = {{0}, 0u};
    CeBytes origins_bytes = {0};
    CeJson origins;
    CeJson origin;
    const char *at = NULL;
    CeId id;
    CeId task;
    CeId target;
    size_t mode;
    bool place = ce_json_field_is(record, "target_kind", "place");
    bool ok;
    if (!ce_json_id(record, "id", &id) || !ce_json_id(record, "task_id", &task) ||
        !ce_json_id(record, "target_id", &target) ||
        !ce_json_member(record, "origins", &origins) ||
        (!place && !ce_json_field_is(record, "target_kind", "unknown"))) {
        return ce_fail(tx, "ETS03", "a capture record is not the closed v2 shape");
    }
    for (mode = 0u; mode < 3u; mode += 1u) {
        if (ce_json_field_is(record, "mode", modes[mode])) break;
    }
    if (mode == 3u) return ce_fail(tx, "ETS03", "a capture mode is outside the closed vocabulary");
    while (ce_json_next(origins, &at, &origin)) {
        CeId node;
        if (!ce_json_id(origin, "node_id", &node) ||
            !ce_append(&origins_bytes, node.bytes, CE_ID_BYTES)) {
            ce_bytes_free(&origins_bytes);
            return ce_fail(tx, "ETS03", "a capture origin is not a NodeId");
        }
    }
    ok = ce_field_id(&frame, 1u, &id) && ce_field_id(&frame, 2u, &task) &&
        ce_field_uint(&frame, 3u, CE_WIRE_U8, place ? 1u : 2u) &&
        ce_field_id(&frame, 4u, &target) &&
        ce_field_uint(&frame, 5u, CE_WIRE_U8, mode + 1u) &&
        ce_field(&frame, 6u, CE_WIRE_IDS, origins_bytes.data, origins_bytes.length) &&
        ce_section_frame(tx, 13u, &frame);
    ce_bytes_free(&origins_bytes);
    ce_bytes_free(&frame.payload);
    return ok;
}

/* The closed document root: schema, profile, FileId, root scope. */
static bool ce_document(CeTransaction *tx, const char *text, CeJson *records) {
    CeJson document;
    CeId file;
    CeId root;
    CeId expected_root;
    size_t length = strlen(text);
    /* Canonical documents end in exactly one newline (§2). */
    if (length == 0u || text[length - 1u] != '\n' ||
        !ce_json_value(text, text + length - 1u, &document) ||
        document.end != text + length - 1u ||
        !ce_json_field_is(document, "schema", "kofun-scope-hir/v2") ||
        !ce_json_field_is(document, "profile", "kofun.stage2-analysis/scoped-captures/v1") ||
        !ce_json_id(document, "file_id", &file) ||
        !ce_json_id(document, "root_scope_id", &root) ||
        !ce_json_member(document, "records", records) ||
        !ce_id_owned(scoped_hir_named_id(tx->file_hex, "scope", "0"), &expected_root)) {
        return ce_fail(tx, "ETS03", "the compiler record set is not a closed scope-HIR v2 document");
    }
    if (!ce_id_equal(&file, &tx->file_id) || !ce_id_equal(&root, &expected_root)) {
        return ce_fail(tx, "ETS03", "the compiler record set names another file");
    }
    return true;
}

/* Append the lifecycle phases. Every par and task fact must have exactly
 * one record, and the lifecycle document carries nothing else. */
static bool ce_lifecycle(CeTransaction *tx, const char *hir, const char *facts,
                         CeJson records, size_t *count) {
    const char *cursor = NULL;
    CeJson record;
    int64_t par_task = -1;
    int64_t join_task = -1;
    size_t pars = 0u;
    int64_t row;
    *count = 0u;
    while (ce_json_next(records, &cursor, &record)) {
        bool join = ce_json_field_is(record, "record", "join");
        if (ce_json_field_is(record, "record", "par")) pars += 1u;
        if (!ce_lifecycle_record(tx, hir, facts, record, join ? &join_task : &par_task)) {
            return false;
        }
        *count += 1u;
    }
    for (row = hir_record_start(facts, "par", 0); row >= 0;
         row = hir_record_start(facts, "par", row + 1)) {
        if (pars-- == 0u) break;
    }
    if (row >= 0 ||
        hir_record_start(facts, "task", par_task < 0 ? 0 : par_task + 1) >= 0 ||
        hir_record_start(facts, "task", join_task < 0 ? 0 : join_task + 1) >= 0) {
        return ce_fail(tx, "ETS03", "a lifecycle fact has no checked record");
    }
    return true;
}

static bool ce_captures(CeTransaction *tx, const char *hir,
                        CheckedPlaceArena *arena, CeJson records,
                        const char *after) {
    const char *cursor = after;
    CeJson record;
    if (!ce_origins(tx, records, after)) return false;
    while (ce_json_next(records, &cursor, &record)) {
        bool ok;
        if (ce_json_field_is(record, "record", "place")) {
            ok = ce_place_record(tx, hir, arena, records, after, record);
        } else if (ce_json_field_is(record, "record", "unknown")) {
            ok = ce_unknown_record(tx, record);
        } else if (ce_json_field_is(record, "record", "capture")) {
            ok = ce_capture_record(tx, record);
        } else {
            ok = ce_fail(tx, "ETS03", "a capture record is out of phase order");
        }
        if (!ok) return false;
    }
    return true;
}

/* ------------------------------------------------------------ transaction */

static int ce_node_order(const void *left_value, const void *right_value) {
    const CeNode *left = left_value;
    const CeNode *right = right_value;
    if (left->start != right->start) return left->start < right->start ? -1 : 1;
    if (left->end != right->end) return left->end > right->end ? -1 : 1;
    if (left->kind != right->kind) return left->kind < right->kind ? -1 : 1;
    return memcmp(left->id.bytes, right->id.bytes, CE_ID_BYTES);
}

typedef struct {
    size_t owner;
    const CeIdentity *identity;
} CeOrderedIdentity;

static int ce_identity_order(const void *left_value, const void *right_value) {
    const CeOrderedIdentity *left = left_value;
    const CeOrderedIdentity *right = right_value;
    if (left->owner != right->owner) return left->owner < right->owner ? -1 : 1;
    return left->identity->kind < right->identity->kind ? -1 :
        left->identity->kind > right->identity->kind ? 1 : 0;
}

typedef struct {
    bool present;
    char code[17];
    uint32_t start;
    char fallback[CE_MAX_FALLBACK + 1];
    bool truncated;
} CeDiagnostic;

/* The refusal is the compiler's own first error line. Only its stable code
 * and byte offset are structured; no capture fact is derived from it. */
static bool ce_refusal(CeTransaction *tx, const char *text, CeDiagnostic *out) {
    const char *line_end = strchr(text, '\n');
    size_t line = line_end == NULL ? strlen(text) : (size_t)(line_end - text);
    size_t code = 0u;
    size_t copy = 0u;
    const char *marker = NULL;
    const char *scan;
    uint64_t byte = 0u;
    memset(out, 0, sizeof(*out));
    if (line < 8u || strncmp(text, "error[", 6u) != 0) {
        return ce_fail(tx, "ETS03", "a compiler refusal is not an error line");
    }
    while (6u + code < line && text[6u + code] != ']' && code < 16u) {
        char symbol = text[6u + code];
        if (!((symbol >= 'A' && symbol <= 'Z') || (code != 0u && symbol >= '0' && symbol <= '9'))) {
            return ce_fail(tx, "ETS03", "a compiler refusal code is outside the stable profile");
        }
        out->code[code] = symbol;
        code += 1u;
    }
    if (code == 0u || 6u + code >= line || text[6u + code] != ']') {
        return ce_fail(tx, "ETS03", "a compiler refusal code is outside the stable profile");
    }
    for (scan = text; scan + 9 <= text + line; ++scan) {
        if (strncmp(scan, " at byte ", 9u) == 0) marker = scan + 9;
        if (strncmp(scan, "(byte ", 6u) == 0) marker = scan + 6;
    }
    if (marker != NULL) {
        for (scan = marker; scan < text + line && *scan >= '0' && *scan <= '9'; ++scan) {
            byte = byte * 10u + (uint64_t)(*scan - '0');
            if (byte > tx->source_length) byte = tx->source_length;
        }
    }
    out->start = (uint32_t)byte;
    /* Fallback presentation is bounded printable ASCII; each other run of
     * bytes becomes one `?`, so no source spelling can make it unencodable. */
    for (scan = text; scan < text + line && copy < CE_MAX_FALLBACK; ++scan) {
        unsigned char symbol = (unsigned char)*scan;
        if (symbol >= 0x20u && symbol < 0x7fu) {
            out->fallback[copy++] = (char)symbol;
        } else if (copy == 0u || out->fallback[copy - 1u] != '?') {
            out->fallback[copy++] = '?';
        }
    }
    out->truncated = scan < text + line;
    out->fallback[copy] = '\0';
    out->present = true;
    return true;
}

static bool ce_encode(CeTransaction *tx, uint64_t generation,
                      uint8_t exit_class, uint8_t source_status,
                      const CeDiagnostic *diagnostic, CeBytes *out) {
    CeBytes frames = {0};
    CeFrame frame = {{0}, 0u};
    CeOrderedIdentity *ordered = NULL;
    uint8_t digest[32];
    CeId diagnostic_id;
    size_t events;
    size_t index;
    bool ok = true;
    uint8_t source_digest[32];
    kofun_sha256((const uint8_t *)tx->source, tx->source_length, source_digest);
    qsort(tx->nodes, tx->node_count, sizeof(*tx->nodes), ce_node_order);
    if (tx->identity_count != 0u) {
        ordered = calloc(tx->identity_count, sizeof(*ordered));
        if (ordered == NULL) return ce_fail(tx, "ETS04", "identity ordering failed");
        for (index = 0u; index < tx->identity_count; index += 1u) {
            size_t owner;
            if (!ce_node_find(tx, &tx->identities[index].owner, &owner)) {
                free(ordered);
                return ce_fail(tx, "ETS03", "an identity owner is not a committed node");
            }
            ordered[index].owner = owner;
            ordered[index].identity = &tx->identities[index];
        }
        qsort(ordered, tx->identity_count, sizeof(*ordered), ce_identity_order);
    }
    events = 2u + tx->node_count + tx->identity_count + tx->section_events +
        (diagnostic->present ? 1u : 0u);
    if (events > CE_MAX_EVENTS) {
        free(ordered);
        return ce_fail(tx, "ETS04", "semantic event count exceeds the v2 limit");
    }

    ok = ce_field_id(&frame, 1u, &tx->package_id) &&
        ce_field_id(&frame, 2u, &tx->module_id) &&
        ce_field_id(&frame, 3u, &tx->file_id) &&
        ce_field_text(&frame, 4u, tx->path) &&
        ce_field_uint(&frame, 5u, CE_WIRE_U64, tx->source_length) &&
        ce_field(&frame, 6u, CE_WIRE_ID, source_digest, sizeof(source_digest)) &&
        ce_field_text(&frame, 7u, "2026") &&
        ce_field_text(&frame, 8u, "stage2-semantic-v1") &&
        ce_field_uint(&frame, 9u, CE_WIRE_U64, generation) &&
        ce_field_uint(&frame, 10u, CE_WIRE_U8, exit_class) &&
        ce_frame_commit(&frames, 1u, &frame);
    for (index = 0u; ok && index < tx->node_count; index += 1u) {
        const CeNode *node = &tx->nodes[index];
        ok = ce_field_id(&frame, 1u, &node->id) &&
            ce_field_uint(&frame, 2u, CE_WIRE_U8, node->kind) &&
            ce_field_span(&frame, 3u, node->start, node->end) &&
            ce_field_uint(&frame, 4u, CE_WIRE_U8, 1u) &&
            ce_field(&frame, 5u, CE_WIRE_IDS, NULL, 0u) &&
            ce_field(&frame, 6u, CE_WIRE_IDS, NULL, 0u) &&
            ce_frame_commit(&frames, 2u, &frame);
    }
    for (index = 0u; ok && index < tx->identity_count; index += 1u) {
        const CeIdentity *identity = ordered[index].identity;
        ok = ce_field_id(&frame, 1u, &identity->owner) &&
            ce_field_uint(&frame, 2u, CE_WIRE_U8, identity->kind) &&
            ce_field_id(&frame, 3u, &identity->value) &&
            ce_field_uint(&frame, 4u, CE_WIRE_U8, 1u) &&
            ce_frame_commit(&frames, 3u, &frame);
    }
    free(ordered);
    ok = ok && ce_append(&frames, tx->section.data, tx->section.length);
    if (ok && diagnostic->present) {
        char key[64];
        char template_id[32];
        static const uint8_t empty_list[2] = {0u, 0u};
        (void)snprintf(key, sizeof(key), "%s:%" PRIu32 ":%" PRIu32,
                       diagnostic->code, diagnostic->start, diagnostic->start);
        (void)snprintf(template_id, sizeof(template_id), "stage2/%s", diagnostic->code);
        ce_named_id(tx, "kofun.semantic.diagnostic/v1", key, &diagnostic_id);
        ok = ce_field_id(&frame, 1u, &diagnostic_id) &&
            ce_field_text(&frame, 2u, diagnostic->code) &&
            ce_field_text(&frame, 3u, "stage2") &&
            ce_field_uint(&frame, 4u, CE_WIRE_U8, 1u) &&
            ce_field_text(&frame, 5u, template_id) &&
            ce_field_id(&frame, 6u, &tx->file_id) &&
            ce_field_span(&frame, 7u, diagnostic->start, diagnostic->start) &&
            ce_field_text(&frame, 8u, diagnostic->fallback) &&
            ce_field(&frame, 9u, CE_WIRE_IDS, tx->module_node.bytes, CE_ID_BYTES) &&
            ce_field(&frame, 10u, CE_WIRE_U32S, NULL, 0u) &&
            ce_field_uint(&frame, 11u, CE_WIRE_U8, diagnostic->truncated ? 1u : 0u) &&
            ce_field(&frame, 12u, CE_WIRE_BYTES, empty_list, sizeof(empty_list)) &&
            ce_field(&frame, 13u, CE_WIRE_BYTES, empty_list, sizeof(empty_list)) &&
            ce_frame_commit(&frames, 6u, &frame);
    }
    ok = ok &&
        ce_field_uint(&frame, 1u, CE_WIRE_U8, source_status) &&
        ce_field_uint(&frame, 2u, CE_WIRE_U8, source_status == 1u ? 1u : 2u) &&
        ce_frame_commit(&frames, 7u, &frame);
    ce_bytes_free(&frame.payload);
    if (!ok) {
        ce_bytes_free(&frames);
        return ce_fail(tx, "ETS04", "semantic event field exceeds the v2 limit");
    }
    if (frames.length > CE_MAX_PAYLOAD) {
        ce_bytes_free(&frames);
        return ce_fail(tx, "ETS04", "semantic event stream exceeds the v2 byte cap");
    }
    ok = ce_append(out, "KSE\0", 4u) && ce_append_uint(out, 2u, 2u) &&
        ce_append_uint(out, 0u, 2u) && ce_append_uint(out, events, 4u) &&
        ce_append_uint(out, frames.length, 4u) &&
        ce_append(out, frames.data, frames.length);
    ce_bytes_free(&frames);
    if (!ok) return ce_fail(tx, "ETS04", "semantic event stream allocation failed");
    kofun_sha256(out->data, out->length, digest);
    if (!ce_append(out, digest, sizeof(digest))) {
        return ce_fail(tx, "ETS04", "semantic event stream allocation failed");
    }
    return true;
}

/* Exclusive temporary, flush, then rename: a failure leaves any prior
 * destination untouched. */
static bool ce_write(const char *path, const CeBytes *bytes) {
    size_t path_length = strlen(path);
    char *temporary = allocate(path_length + 40u);
    FILE *file = NULL;
    unsigned attempt;
    bool ok;
    for (attempt = 0u; attempt < 100u && file == NULL; attempt += 1u) {
        (void)snprintf(temporary, path_length + 40u, "%s.kofun-tmp-%u", path, attempt);
        file = fopen(temporary, "wbx");
    }
    if (file == NULL) {
        free(temporary);
        return false;
    }
    ok = fwrite(bytes->data, 1u, bytes->length, file) == bytes->length;
    ok = fflush(file) == 0 && ok;
    ok = fclose(file) == 0 && ok;
    if (!ok || rename(temporary, path) != 0) {
        (void)remove(temporary);
        free(temporary);
        return false;
    }
    free(temporary);
    return true;
}

static void ce_transaction_free(CeTransaction *tx) {
    free(tx->nodes);
    free(tx->identities);
    free(tx->types);
    free(tx->file_hex);
    ce_bytes_free(&tx->section);
}

typedef struct {
    char *refusal;
    uint8_t status;
} CeRun;

/* §14's pipeline, stopping at the first refusal or cancellation point. */
static bool ce_analyze(CeTransaction *tx, CeCancel cancel, CeRun *run) {
    char *tokens;
    char *tree;
    char *pattern_error;
    char *hir;
    char *facts;
    char *lifecycle;
    char *document;
    CheckedPlaceArena arena = {0};
    CeJson records;
    size_t lifecycle_count = 0u;
    bool ok;
    run->status = 1u;
    if (!ce_module(tx)) return false;
    if (cancel == CE_CANCEL_SOURCE) {
        run->status = 3u;
        return true;
    }
    /* Text's explicit length reaches the Unicode validator before the C
     * string representation can discard an embedded NUL and its suffix. */
    if (memchr(tx->source, 0, tx->source_length) != NULL) {
        KofunUnicodeError error;
        if (!kofun_unicode_validate_source((const uint8_t *)tx->source,
                                           tx->source_length, &error)) {
            char message[1024];
            kofun_unicode_format_error(&error, getenv("KOFUN_DIAGNOSTIC_LOCALE"),
                                       message, sizeof(message));
            run->refusal = owned_text(message);
            run->status = 2u;
            return true;
        }
    }
    tokens = lex_source(tx->source);
    if (strncmp(tokens, "error[", 6u) == 0) {
        run->refusal = tokens;
        run->status = 2u;
        return true;
    }
    free(tokens);
    tree = parse_pattern_trees(tx->source);
    pattern_error = pattern_first_error(tree);
    free(tree);
    if (pattern_error[0] != '\0') {
        run->refusal = pattern_error;
        run->status = 2u;
        return true;
    }
    free(pattern_error);
    hir = build_scope_hir_analysis_mode(tx->source, false, true);
    if (strncmp(hir, "error[", 6u) == 0) {
        run->refusal = hir;
        run->status = 2u;
        return true;
    }
    facts = scoped_hir_observations(tx->source, hir);
    if (strncmp(facts, "error[", 6u) == 0) {
        run->refusal = facts;
        run->status = 2u;
        free(hir);
        return true;
    }
    lifecycle = scoped_hir_render(tx->source, facts, tx->path);
    if (strncmp(lifecycle, "error[", 6u) == 0) {
        run->refusal = lifecycle;
        run->status = 2u;
        free(facts);
        free(hir);
        return true;
    }
    ok = ce_document(tx, lifecycle, &records) &&
        ce_lifecycle(tx, hir, facts, records, &lifecycle_count);
    if (!ok || cancel == CE_CANCEL_LIFECYCLE) {
        run->status = 3u;
        free(lifecycle);
        free(facts);
        free(hir);
        return ok;
    }
    document = owned_text(summary_render(&arena, tx->source, hir, facts, tx->path));
    if (strncmp(document, "error[", 6u) == 0) {
        run->refusal = document;
        run->status = 2u;
        capture_release(&arena, NULL);
        free(lifecycle);
        free(facts);
        free(hir);
        return true;
    }
    /* The complete document inserts places, unknowns and captures after the
     * identical lifecycle records it already committed. */
    {
        CeJson complete;
        const char *lifecycle_records = strstr(lifecycle, "\"records\":[");
        const char *complete_records = strstr(document, "\"records\":[");
        const char *lifecycle_end = lifecycle_records == NULL ? NULL :
            strstr(lifecycle_records, "],\"root_scope_id\":");
        size_t prefix = lifecycle_end == NULL ? 0u :
            (size_t)(lifecycle_end - lifecycle_records);
        ok = lifecycle_end != NULL && complete_records != NULL &&
            strncmp(lifecycle_records, complete_records, prefix) == 0 &&
            ce_document(tx, document, &complete);
        if (!ok) {
            ok = ce_fail(tx, "ETS03", "the complete record set does not extend the lifecycle records");
        } else {
            const char *cursor = NULL;
            CeJson record;
            size_t skipped = 0u;
            while (skipped < lifecycle_count && ce_json_next(complete, &cursor, &record)) {
                skipped += 1u;
            }
            ok = ce_captures(tx, hir, &arena, complete, cursor);
        }
    }
    capture_release(&arena, NULL);
    free(document);
    free(lifecycle);
    free(facts);
    free(hir);
    run->status = cancel == CE_CANCEL_CAPTURES ? 3u : 1u;
    return ok;
}

int main(int argc, char **argv) {
    CeTransaction tx;
    CeRun run = {NULL, 0u};
    CeDiagnostic diagnostic;
    CeBytes stream = {0};
    CeCancel cancel = CE_CANCEL_NONE;
    const char *input;
    const char *output;
    char *generation_end = NULL;
    unsigned long long generation;
    size_t source_bytes = 0u;
    char *source;
    int offset = 1;
    Stage2FileIdentity identity;
    bool ok;
    if (argc == 7 && strcmp(argv[1], "--cancel-after") == 0) {
        cancel = strcmp(argv[2], "source") == 0 ? CE_CANCEL_SOURCE :
            strcmp(argv[2], "lifecycle") == 0 ? CE_CANCEL_LIFECYCLE :
            strcmp(argv[2], "captures") == 0 ? CE_CANCEL_CAPTURES : CE_CANCEL_NONE;
        offset = 3;
    }
    if (argc != offset + 4 || (offset == 3 && cancel == CE_CANCEL_NONE)) {
        fputs("usage: kofun-stage2-capture-events "
              "[--cancel-after source|lifecycle|captures] "
              "INPUT LOGICAL-PATH OUTPUT GENERATION\n", stderr);
        return 2;
    }
    input = argv[offset];
    output = argv[offset + 2];
    errno = 0;
    generation = strtoull(argv[offset + 3], &generation_end, 10);
    if (errno != 0 || generation_end == argv[offset + 3] || *generation_end != '\0' ||
        argv[offset + 3][0] == '-' || generation > 9007199254740991ull) {
        fputs("capture events: invalid generation\n", stderr);
        return 2;
    }
    identity = stage2_same_file(input, output);
    if (identity == STAGE2_FILE_LOOKUP_ERROR) {
        stage2_host_lookup_error();
        return 2;
    }
    if (identity == STAGE2_FILE_SAME) {
        puts("error[E2S35]: capture event input and output must be distinct");
        return 1;
    }
    if (!scoped_hir_logical_path(argv[offset + 1])) {
        puts("error[E2S35]: capture event logical path must be canonical relative UTF-8 (1..4096 bytes)");
        return 1;
    }
    source = read_file_with_length(input, &source_bytes);
    if (source_bytes > UINT32_MAX) {
        puts("error[E2S35]: capture event source span exceeds u32");
        free(source);
        return 1;
    }
    memset(&tx, 0, sizeof(tx));
    tx.source = source;
    tx.source_length = source_bytes;
    tx.path = argv[offset + 1];
    ok = ce_analyze(&tx, cancel, &run);
    if (ok && run.status == 2u) {
        /* A refusal keeps only the phases committed before it. */
        ok = ce_refusal(&tx, run.refusal, &diagnostic);
    } else {
        memset(&diagnostic, 0, sizeof(diagnostic));
    }
    ok = ok && ce_encode(&tx, (uint64_t)generation, run.status == 2u ? 1u : 0u,
                         run.status, &diagnostic, &stream);
    if (ok && !ce_write(output, &stream)) {
        ok = ce_fail(&tx, "ETS04", "cannot commit the capture event stream");
    }
    if (!ok) {
        fprintf(stderr, "%s: %s\n", tx.failure_code[0] == '\0' ? "ETS03" : tx.failure_code,
                tx.failure[0] == '\0' ? "capture event production failed" : tx.failure);
    } else if (run.status == 2u) {
        puts(run.refusal);
    }
    ce_bytes_free(&stream);
    free(run.refusal);
    ce_transaction_free(&tx);
    free(source);
    if (!ok) return 3;
    return run.status == 1u ? 0 : 1;
}
