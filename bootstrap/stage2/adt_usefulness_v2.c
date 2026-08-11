/*
 * Bounded recursive pattern-matrix usefulness oracle.
 *
 * This is independent analysis evidence, not production typing or lowering. It
 * reads one canonical, already-resolved model — nominal ADTs, ordered
 * constructors with typed fields, and resolved pattern trees — and answers the
 * two questions a match raises: is any alternative unreachable, and is the
 * match exhaustive.
 *
 * It replaces a one-level model that could see a scrutinee column and at most
 * one payload column. Everything here is recursive, and for one reason: a
 * nested column is the same kind of column as the outer one. Specialization
 * pushes a constructor's fields onto the front of the row, so a product of
 * fields and a single scrutinee are the same shape of problem, and depth is
 * just how many times that has happened.
 *
 * The relation is Maranget's, computed over the resolved matrix rather than
 * over source syntax. `U(P, q)` asks whether some value matches the row `q`
 * and no row of `P`:
 *
 *   no columns left            U(P, q) = P has no rows
 *   q's head is `c`            U(P, q) = U(S(c, P), S(c, q))
 *   q's head is a wildcard,
 *     P's head column names
 *     every constructor        U(P, q) = some c: U(S(c, P), S(c, q))
 *   q's head is a wildcard,
 *     P's head column does not  U(P, q) = U(D(P), tail(q))
 *
 * Redundancy is `U` against what precedes an alternative. Exhaustiveness is `U`
 * of a bare wildcard against everything that can fire, and the constructors
 * that answer chose along the way spell the missing value.
 *
 * Two things are deliberate and load-bearing.
 *
 * Identity is resolved identity. A constructor is the 64-hex id it declares;
 * `name` is display metadata and never decides an answer. Two constructors of
 * different ADTs may share a display name, and a model where they do is why
 * this is written down rather than assumed.
 *
 * Every quantity that can grow with the model is bounded, and every bound is
 * checked before the step that would cross it. A model at a bound succeeds; a
 * model one past it is refused with nothing published.
 */

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define ID_LENGTH 64u
#define NAME_LIMIT 64u
#define LINE_LIMIT 4096u
#define INPUT_LIMIT (UINT64_C(1024) * UINT64_C(1024))
#define ADT_LIMIT 16u
#define CONSTRUCTOR_LIMIT 64u
#define FIELD_LIMIT 4u
#define TYPE_DEPTH_LIMIT 8u
#define ARM_LIMIT 64u
#define ALTERNATIVE_LIMIT 8u
#define ROW_LIMIT 128u
#define COLUMN_LIMIT 32u
#define NODE_LIMIT 1024u
#define ROLE_LIMIT 32u
#define RECURSION_LIMIT 40u
#define ARENA_ROWS ((size_t)(RECURSION_LIMIT + 2u) * (size_t)(ROW_LIMIT + 1u))
#define PATH_LIMIT 64u
#define WITNESS_TEXT_LIMIT 512u
#define OPERATION_LIMIT UINT64_C(65536)

/*
 * The three diagnostics this oracle produces, and no others. E2S110 covers
 * every way a model can be inadmissible — malformed input, a broken identity
 * link, a bound crossed. E2S25 and E2S26 are the two answers it exists to give.
 */
#define CODE_MODEL "E2S110"
#define CODE_NON_EXHAUSTIVE "E2S25"
#define CODE_REDUNDANT "E2S26"

typedef struct {
    char id[ID_LENGTH + 1u];
    char name[NAME_LIMIT + 1u];
} Adt;

typedef struct {
    char id[ID_LENGTH + 1u];
    char owner[ID_LENGTH + 1u];
    char name[NAME_LIMIT + 1u];
    size_t ordinal;
    size_t field_count;
    char fields[FIELD_LIMIT][ID_LENGTH + 1u];
    size_t field_adt[FIELD_LIMIT];
} Constructor;

typedef enum {
    PATTERN_WILDCARD,
    PATTERN_BINDING,
    PATTERN_CONSTRUCTOR
} PatternKind;

typedef struct {
    PatternKind kind;
    size_t constructor;
    size_t role;
    size_t field_count;
    size_t fields[FIELD_LIMIT];
} PatternNode;

typedef struct {
    size_t arm;
    size_t index;
    size_t root;
    /* The roles this alternative binds, kept sorted by resolved role id. Or
     * alternatives of one arm must agree on this list exactly: they feed one
     * body, and a body cannot read a name only some of its alternatives bind. */
    size_t roles[ROLE_LIMIT];
    size_t role_count;
} Alternative;

typedef struct {
    size_t index;
    size_t start;
    size_t end;
    bool guarded;
    size_t first_alternative;
    size_t alternative_count;
} Arm;

/* One row of a working matrix: a left-to-right vector of pattern positions. */
typedef struct {
    size_t columns[COLUMN_LIMIT];
    size_t width;
} MatrixRow;

typedef struct {
    MatrixRow *rows;
    size_t count;
} Matrix;

/* The ADT of each column. Every row of a well-formed matrix agrees on it by
 * construction, because the columns descend from one signature. */
typedef struct {
    size_t adts[COLUMN_LIMIT];
    size_t width;
} ColumnTypes;

/*
 * The choices a useful wildcard made, in the order the witness reads them.
 *
 * `closed` is the difference between the two ways a constructor can appear. A
 * split records the constructor and then goes on to record what happened inside
 * its fields, so the entries that follow belong to those fields. A default
 * branch instead names a constructor the column never mentioned: nothing was
 * examined inside it, every field is any value, and the entries that follow
 * belong to the *next* column. Without that distinction the renderer would read
 * a sibling's choice as a field's.
 */
typedef struct {
    int64_t constructor;
    bool closed;
} WitnessStep;

typedef struct {
    WitnessStep step[PATH_LIMIT];
    size_t length;
    bool overflowed;
} WitnessPath;

typedef struct {
    Adt adts[ADT_LIMIT];
    size_t adt_count;
    Constructor constructors[CONSTRUCTOR_LIMIT];
    size_t constructor_count;
    PatternNode nodes[NODE_LIMIT];
    size_t node_count;
    char roles[ROLE_LIMIT][NAME_LIMIT + 1u];
    size_t role_count;
    Arm arms[ARM_LIMIT];
    size_t arm_count;
    Alternative alternatives[ROW_LIMIT];
    size_t alternative_count;
    char target[ID_LENGTH + 1u];
    bool has_target;
    size_t target_adt;
    size_t target_depth;
    size_t wildcard_node;
    size_t widest_column;

    MatrixRow arena[ARENA_ROWS];
    size_t arena_used;
    uint64_t operations;

    char code[16];
    char message[2048];
} Program;

static bool fail(Program *program, const char *code, const char *message) {
    if (program->code[0] == '\0') {
        (void)snprintf(program->code, sizeof(program->code), "%s", code);
        (void)snprintf(program->message, sizeof(program->message), "%s", message);
    }
    return false;
}

static bool fail_line(
    Program *program,
    const char *code,
    const char *subject,
    size_t line
) {
    char message[256];
    (void)snprintf(message, sizeof(message), "%s at line %zu", subject, line);
    return fail(program, code, message);
}

/*
 * One checked visit. Every loop and every recursion that can grow with the
 * model calls this before doing its work, so the budget bounds the analysis
 * rather than describing it.
 *
 * The budget is headroom, not a working limit. The largest model the other
 * bounds admit — 128 alternatives over a three-column product, every column
 * complete, which is the shape that makes the search branch at every level —
 * costs about 29 000 visits, and the gate pins that number. 65536 is set above
 * it so this stops a pathology rather than an ordinary model, which is also why
 * the gate proves the check by rebuilding with a smaller budget instead of by
 * finding a model that crosses this one.
 *
 * The limit is named in the message rather than written into it, so lowering
 * the constant is the whole mutation.
 */
static bool step(Program *program) {
    char message[128];
    program->operations += UINT64_C(1);
    if (program->operations <= OPERATION_LIMIT) return true;
    (void)snprintf(
        message,
        sizeof(message),
        "usefulness analysis exceeds %" PRIu64 " operations",
        OPERATION_LIMIT
    );
    return fail(program, CODE_MODEL, message);
}

/* ------------------------------------------------------------------------ */
/* Lexical helpers                                                           */
/* ------------------------------------------------------------------------ */

static bool valid_id(const char *value) {
    size_t index;
    if (strlen(value) != ID_LENGTH) return false;
    for (index = 0u; index < ID_LENGTH; index += 1u) {
        char byte = value[index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
            return false;
        }
    }
    return true;
}

static bool valid_name(const char *value) {
    size_t index;
    size_t length = strlen(value);
    if (length == 0u || length > NAME_LIMIT ||
        !((value[0] >= 'A' && value[0] <= 'Z') ||
          (value[0] >= 'a' && value[0] <= 'z') || value[0] == '_')) {
        return false;
    }
    for (index = 1u; index < length; index += 1u) {
        char byte = value[index];
        if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
              (byte >= '0' && byte <= '9') || byte == '_')) {
            return false;
        }
    }
    return true;
}

static bool parse_size(const char *value, size_t *result) {
    char *end = NULL;
    uintmax_t parsed;
    if (value[0] == '\0' || value[0] == '-') return false;
    errno = 0;
    parsed = strtoumax(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > SIZE_MAX) {
        return false;
    }
    *result = (size_t)parsed;
    return true;
}

static bool parse_span(const char *value, size_t *start, size_t *end) {
    const char *separator = strstr(value, "..");
    char left[32];
    size_t length;
    if (separator == NULL || strstr(separator + 2, "..") != NULL) return false;
    length = (size_t)(separator - value);
    if (length == 0u || length >= sizeof(left)) return false;
    memcpy(left, value, length);
    left[length] = '\0';
    if (!parse_size(left, start) || !parse_size(separator + 2, end)) {
        return false;
    }
    return *start < *end;
}

static size_t split_fields(char *line, char *fields[], size_t capacity) {
    size_t count = 1u;
    char *cursor;
    fields[0] = line;
    for (cursor = line; *cursor != '\0'; cursor += 1) {
        if (*cursor != '|') continue;
        *cursor = '\0';
        if (count >= capacity) return capacity + 1u;
        fields[count++] = cursor + 1;
    }
    return count;
}

static const char *ordered_value(const char *field, const char *key) {
    size_t length = strlen(key);
    if (strncmp(field, key, length) != 0 || field[length] != '=') return NULL;
    return field + length + 1u;
}

static int64_t adt_index(const Program *program, const char *id) {
    size_t index;
    for (index = 0u; index < program->adt_count; index += 1u) {
        if (strcmp(program->adts[index].id, id) == 0) return (int64_t)index;
    }
    return -1;
}

static int64_t constructor_index(const Program *program, const char *id) {
    size_t index;
    for (index = 0u; index < program->constructor_count; index += 1u) {
        if (strcmp(program->constructors[index].id, id) == 0) {
            return (int64_t)index;
        }
    }
    return -1;
}

static size_t owner_constructor_count(const Program *program, size_t adt) {
    size_t index;
    size_t count = 0u;
    for (index = 0u; index < program->constructor_count; index += 1u) {
        if (strcmp(program->constructors[index].owner,
                   program->adts[adt].id) == 0) {
            count += 1u;
        }
    }
    return count;
}

static int64_t constructor_at_ordinal(
    const Program *program,
    size_t adt,
    size_t ordinal
) {
    size_t index;
    for (index = 0u; index < program->constructor_count; index += 1u) {
        const Constructor *constructor = &program->constructors[index];
        if (strcmp(constructor->owner, program->adts[adt].id) == 0 &&
            constructor->ordinal == ordinal) {
            return (int64_t)index;
        }
    }
    return -1;
}

static bool intern_role(Program *program, const char *name, size_t *role) {
    size_t index;
    for (index = 0u; index < program->role_count; index += 1u) {
        if (strcmp(program->roles[index], name) == 0) {
            *role = index;
            return true;
        }
    }
    if (program->role_count >= ROLE_LIMIT) {
        return fail(
            program, CODE_MODEL, "usefulness input exceeds 32 binding roles");
    }
    (void)snprintf(
        program->roles[program->role_count], NAME_LIMIT + 1u, "%s", name);
    *role = program->role_count++;
    return true;
}

/* ------------------------------------------------------------------------ */
/* Reading the model                                                         */
/* ------------------------------------------------------------------------ */

static bool parse_adt(
    Program *program,
    char *fields[],
    size_t count,
    size_t line
) {
    const char *id;
    const char *name;
    Adt *adt;
    if (count != 3u || (id = ordered_value(fields[1], "id")) == NULL ||
        (name = ordered_value(fields[2], "name")) == NULL) {
        return fail_line(program, CODE_MODEL, "malformed ADT record", line);
    }
    if (program->adt_count >= ADT_LIMIT) {
        return fail(program, CODE_MODEL, "usefulness input exceeds 16 ADTs");
    }
    if (!valid_id(id) || !valid_name(name)) {
        return fail_line(program, CODE_MODEL, "malformed ADT record", line);
    }
    adt = &program->adts[program->adt_count];
    memset(adt, 0, sizeof(*adt));
    memcpy(adt->id, id, ID_LENGTH + 1u);
    (void)snprintf(adt->name, sizeof(adt->name), "%s", name);
    program->adt_count += 1u;
    return true;
}

static bool parse_constructor_fields(
    Program *program,
    Constructor *constructor,
    const char *value,
    size_t line
) {
    const char *cursor = value;
    if (strcmp(value, "-") == 0) return true;
    for (;;) {
        char item[ID_LENGTH + 1u];
        const char *comma = strchr(cursor, ',');
        size_t length =
            comma == NULL ? strlen(cursor) : (size_t)(comma - cursor);
        if (length != ID_LENGTH) {
            return fail_line(
                program, CODE_MODEL, "malformed constructor field list", line);
        }
        if (constructor->field_count >= FIELD_LIMIT) {
            return fail(
                program, CODE_MODEL, "usefulness constructor exceeds 4 fields");
        }
        memcpy(item, cursor, ID_LENGTH);
        item[ID_LENGTH] = '\0';
        if (!valid_id(item)) {
            return fail_line(
                program, CODE_MODEL, "malformed constructor field list", line);
        }
        /* Resolved here rather than in validation, because the patterns read
         * later are typed against these columns. A field naming an ADT this
         * record does not yet know is a broken link, not a forward reference:
         * the format declares every ADT before the constructors that use it. */
        {
            int64_t owner = adt_index(program, item);
            if (owner < 0) {
                return fail_line(
                    program,
                    CODE_MODEL,
                    "constructor field identity is absent",
                    line
                );
            }
            constructor->field_adt[constructor->field_count] = (size_t)owner;
        }
        memcpy(
            constructor->fields[constructor->field_count],
            item,
            ID_LENGTH + 1u
        );
        constructor->field_count += 1u;
        if (comma == NULL) break;
        cursor = comma + 1;
    }
    return true;
}

static bool parse_constructor(
    Program *program,
    char *fields[],
    size_t count,
    size_t line
) {
    const char *id;
    const char *owner;
    const char *ordinal;
    const char *name;
    const char *field_list;
    Constructor *constructor;
    if (count != 6u || (id = ordered_value(fields[1], "id")) == NULL ||
        (owner = ordered_value(fields[2], "owner")) == NULL ||
        (ordinal = ordered_value(fields[3], "ordinal")) == NULL ||
        (name = ordered_value(fields[4], "name")) == NULL ||
        (field_list = ordered_value(fields[5], "fields")) == NULL) {
        return fail_line(
            program, CODE_MODEL, "malformed constructor record", line);
    }
    if (program->constructor_count >= CONSTRUCTOR_LIMIT) {
        return fail(
            program, CODE_MODEL, "usefulness input exceeds 64 constructors");
    }
    constructor = &program->constructors[program->constructor_count];
    memset(constructor, 0, sizeof(*constructor));
    if (!valid_id(id) || !valid_id(owner) || !valid_name(name) ||
        !parse_size(ordinal, &constructor->ordinal)) {
        return fail_line(
            program, CODE_MODEL, "malformed constructor record", line);
    }
    memcpy(constructor->id, id, ID_LENGTH + 1u);
    memcpy(constructor->owner, owner, ID_LENGTH + 1u);
    (void)snprintf(constructor->name, sizeof(constructor->name), "%s", name);
    if (!parse_constructor_fields(program, constructor, field_list, line)) {
        return false;
    }
    program->constructor_count += 1u;
    return true;
}

static bool parse_target(
    Program *program,
    char *fields[],
    size_t count,
    size_t line
) {
    const char *adt;
    int64_t resolved;
    if (count != 2u || (adt = ordered_value(fields[1], "adt")) == NULL ||
        !valid_id(adt)) {
        return fail_line(program, CODE_MODEL, "malformed target record", line);
    }
    if (program->has_target) {
        return fail(
            program, CODE_MODEL, "usefulness input declares two targets");
    }
    /* Resolved here rather than in validation, because every pattern parsed
     * afterwards is typed against it. */
    resolved = adt_index(program, adt);
    if (resolved < 0) {
        return fail(program, CODE_MODEL, "target ADT identity is absent");
    }
    memcpy(program->target, adt, ID_LENGTH + 1u);
    program->target_adt = (size_t)resolved;
    program->has_target = true;
    return true;
}

static bool parse_arm(
    Program *program,
    char *fields[],
    size_t count,
    size_t line
) {
    const char *index;
    const char *span;
    const char *guard;
    Arm *arm;
    size_t declared;
    if (count != 4u || (index = ordered_value(fields[1], "index")) == NULL ||
        (span = ordered_value(fields[2], "span")) == NULL ||
        (guard = ordered_value(fields[3], "guard")) == NULL) {
        return fail_line(program, CODE_MODEL, "malformed arm record", line);
    }
    if (program->arm_count >= ARM_LIMIT) {
        return fail(program, CODE_MODEL, "usefulness input exceeds 64 arms");
    }
    if (!parse_size(index, &declared)) {
        return fail_line(program, CODE_MODEL, "malformed arm record", line);
    }
    if (declared != program->arm_count) {
        return fail_line(
            program,
            CODE_MODEL,
            "arm indices are not consecutive from zero",
            line
        );
    }
    arm = &program->arms[program->arm_count];
    memset(arm, 0, sizeof(*arm));
    arm->index = declared;
    if (!parse_span(span, &arm->start, &arm->end)) {
        return fail_line(program, CODE_MODEL, "malformed arm record", line);
    }
    if (strcmp(guard, "yes") == 0) {
        arm->guarded = true;
    } else if (strcmp(guard, "no") != 0) {
        return fail_line(program, CODE_MODEL, "malformed arm record", line);
    }
    arm->first_alternative = program->alternative_count;
    program->arm_count += 1u;
    return true;
}

static bool take_node(Program *program, size_t *node) {
    if (program->node_count >= NODE_LIMIT) {
        return fail(
            program, CODE_MODEL, "usefulness input exceeds 1024 pattern nodes");
    }
    *node = program->node_count;
    memset(&program->nodes[*node], 0, sizeof(program->nodes[*node]));
    program->node_count += 1u;
    return true;
}

static bool add_role(
    Program *program,
    Alternative *alternative,
    size_t role,
    size_t line
) {
    size_t index;
    for (index = 0u; index < alternative->role_count; index += 1u) {
        if (alternative->roles[index] == role) {
            return fail_line(
                program, CODE_MODEL, "alternative binds one role twice", line);
        }
    }
    if (alternative->role_count >= ROLE_LIMIT) {
        return fail(
            program,
            CODE_MODEL,
            "usefulness alternative exceeds 32 bound roles"
        );
    }
    index = alternative->role_count;
    while (index > 0u && alternative->roles[index - 1u] > role) {
        alternative->roles[index] = alternative->roles[index - 1u];
        index -= 1u;
    }
    alternative->roles[index] = role;
    alternative->role_count += 1u;
    return true;
}

/*
 * A resolved pattern tree, in the one spelling this format admits:
 *
 *   `_`                   a wildcard
 *   `$name`               a binding: matches like a wildcard, and carries a
 *                         role the arm's body can read
 *   `<id>`                a constructor with no fields
 *   `<id>(p,p,...)`       a constructor with exactly its declared fields
 *
 * Owners and field counts are checked against the resolved signature here, so
 * a tree that disagrees with what it names never reaches the matrix.
 */
static bool parse_pattern(
    Program *program,
    const char **cursor,
    size_t expected_adt,
    size_t depth,
    Alternative *alternative,
    size_t line,
    size_t *node_out
) {
    const char *text = *cursor;
    size_t node = 0u;
    if (!step(program)) return false;
    if (depth > TYPE_DEPTH_LIMIT) {
        return fail(program, CODE_MODEL, "usefulness pattern exceeds depth 8");
    }
    if (!take_node(program, &node)) return false;
    *node_out = node;

    if (text[0] == '_') {
        program->nodes[node].kind = PATTERN_WILDCARD;
        *cursor = text + 1;
        return true;
    }
    if (text[0] == '$') {
        char name[NAME_LIMIT + 2u];
        size_t length = 0u;
        size_t role = 0u;
        text += 1;
        while (length <= NAME_LIMIT &&
               ((text[length] >= 'A' && text[length] <= 'Z') ||
                (text[length] >= 'a' && text[length] <= 'z') ||
                (text[length] >= '0' && text[length] <= '9') ||
                text[length] == '_')) {
            name[length] = text[length];
            length += 1u;
        }
        name[length] = '\0';
        if (!valid_name(name)) {
            return fail_line(program, CODE_MODEL, "malformed binding", line);
        }
        if (!intern_role(program, name, &role)) return false;
        if (!add_role(program, alternative, role, line)) return false;
        program->nodes[node].kind = PATTERN_BINDING;
        program->nodes[node].role = role;
        *cursor = text + length;
        return true;
    }
    {
        char id[ID_LENGTH + 1u];
        int64_t resolved;
        const Constructor *constructor;
        size_t field;
        if (strlen(text) < ID_LENGTH) {
            return fail_line(
                program, CODE_MODEL, "malformed constructor pattern", line);
        }
        memcpy(id, text, ID_LENGTH);
        id[ID_LENGTH] = '\0';
        if (!valid_id(id)) {
            return fail_line(
                program, CODE_MODEL, "malformed constructor pattern", line);
        }
        resolved = constructor_index(program, id);
        if (resolved < 0) {
            return fail_line(
                program, CODE_MODEL, "pattern names an absent constructor", line);
        }
        constructor = &program->constructors[(size_t)resolved];
        if (strcmp(constructor->owner, program->adts[expected_adt].id) != 0) {
            return fail_line(
                program,
                CODE_MODEL,
                "pattern constructor is not owned by the column's ADT",
                line
            );
        }
        program->nodes[node].kind = PATTERN_CONSTRUCTOR;
        program->nodes[node].constructor = (size_t)resolved;
        program->nodes[node].field_count = constructor->field_count;
        text += ID_LENGTH;
        if (constructor->field_count == 0u) {
            if (text[0] == '(') {
                return fail_line(
                    program,
                    CODE_MODEL,
                    "constructor pattern has too many fields",
                    line
                );
            }
            *cursor = text;
            return true;
        }
        if (text[0] != '(') {
            return fail_line(
                program,
                CODE_MODEL,
                "constructor pattern omits its declared fields",
                line
            );
        }
        text += 1;
        for (field = 0u; field < constructor->field_count; field += 1u) {
            size_t child = 0u;
            const char *inner = text;
            if (!parse_pattern(
                    program,
                    &inner,
                    constructor->field_adt[field],
                    depth + 1u,
                    alternative,
                    line,
                    &child)) {
                return false;
            }
            program->nodes[node].fields[field] = child;
            text = inner;
            if (field + 1u < constructor->field_count) {
                if (text[0] != ',') {
                    return fail_line(
                        program,
                        CODE_MODEL,
                        "constructor pattern has too few fields",
                        line
                    );
                }
                text += 1;
            }
        }
        if (text[0] != ')') {
            return fail_line(
                program,
                CODE_MODEL,
                "constructor pattern has too many fields",
                line
            );
        }
        *cursor = text + 1;
        return true;
    }
}

static bool parse_alternative(
    Program *program,
    char *fields[],
    size_t count,
    size_t line
) {
    const char *arm_field;
    const char *index_field;
    const char *pattern_field;
    const char *cursor;
    Alternative *alternative;
    Arm *arm;
    size_t arm_index = 0u;
    size_t declared = 0u;
    size_t root = 0u;
    if (count != 4u || (arm_field = ordered_value(fields[1], "arm")) == NULL ||
        (index_field = ordered_value(fields[2], "index")) == NULL ||
        (pattern_field = ordered_value(fields[3], "pattern")) == NULL) {
        return fail_line(
            program, CODE_MODEL, "malformed alternative record", line);
    }
    if (!parse_size(arm_field, &arm_index) ||
        !parse_size(index_field, &declared)) {
        return fail_line(
            program, CODE_MODEL, "malformed alternative record", line);
    }
    if (!program->has_target) {
        return fail_line(
            program, CODE_MODEL, "alternative precedes the target record", line);
    }
    if (program->arm_count == 0u || arm_index != program->arm_count - 1u) {
        return fail_line(
            program, CODE_MODEL, "alternative does not follow its own arm", line);
    }
    arm = &program->arms[arm_index];
    if (declared != arm->alternative_count) {
        return fail_line(
            program,
            CODE_MODEL,
            "alternative indices are not consecutive from zero",
            line
        );
    }
    if (arm->alternative_count >= ALTERNATIVE_LIMIT) {
        return fail(
            program, CODE_MODEL, "usefulness arm exceeds 8 alternatives");
    }
    if (program->alternative_count >= ROW_LIMIT) {
        return fail(
            program, CODE_MODEL, "usefulness input exceeds 128 alternatives");
    }
    alternative = &program->alternatives[program->alternative_count];
    memset(alternative, 0, sizeof(*alternative));
    alternative->arm = arm_index;
    alternative->index = declared;
    cursor = pattern_field;
    if (!parse_pattern(
            program, &cursor, program->target_adt, 0u, alternative, line, &root)) {
        return false;
    }
    if (*cursor != '\0') {
        return fail_line(
            program, CODE_MODEL, "trailing text after the pattern", line);
    }
    alternative->root = root;
    program->alternative_count += 1u;
    arm->alternative_count += 1u;
    return true;
}

static bool read_input(Program *program, const char *path) {
    FILE *input = fopen(path, "rb");
    char line[LINE_LIMIT + 2u];
    size_t line_number = 0u;
    uint64_t consumed = 0u;
    bool saw_header = false;
    if (input == NULL) {
        return fail(program, CODE_MODEL, "cannot open the usefulness model");
    }
    while (fgets(line, (int)sizeof(line), input) != NULL) {
        char *fields[8];
        size_t count;
        size_t length = strlen(line);
        line_number += 1u;
        consumed += (uint64_t)length;
        if (consumed > INPUT_LIMIT) {
            (void)fclose(input);
            return fail(program, CODE_MODEL, "usefulness input exceeds 1 MiB");
        }
        if (length > 0u && line[length - 1u] == '\n') {
            line[--length] = '\0';
        } else if (length >= LINE_LIMIT) {
            (void)fclose(input);
            return fail_line(
                program, CODE_MODEL, "line exceeds 4096 bytes", line_number);
        }
        if (length == 0u) continue;
        if (!saw_header) {
            if (strcmp(line, "kofun-adt-usefulness/v2") != 0) {
                (void)fclose(input);
                return fail(
                    program, CODE_MODEL, "usefulness input has no v2 header");
            }
            saw_header = true;
            continue;
        }
        count = split_fields(line, fields, 8u);
        if (count > 8u) {
            (void)fclose(input);
            return fail_line(
                program, CODE_MODEL, "record has too many fields", line_number);
        }
        if (strcmp(fields[0], "adt") == 0) {
            if (!parse_adt(program, fields, count, line_number)) break;
        } else if (strcmp(fields[0], "constructor") == 0) {
            if (!parse_constructor(program, fields, count, line_number)) break;
        } else if (strcmp(fields[0], "target") == 0) {
            if (!parse_target(program, fields, count, line_number)) break;
        } else if (strcmp(fields[0], "arm") == 0) {
            if (!parse_arm(program, fields, count, line_number)) break;
        } else if (strcmp(fields[0], "alternative") == 0) {
            if (!parse_alternative(program, fields, count, line_number)) break;
        } else {
            (void)fail_line(
                program, CODE_MODEL, "unknown record kind", line_number);
            break;
        }
    }
    if (ferror(input)) {
        (void)fclose(input);
        return fail(program, CODE_MODEL, "cannot read the usefulness model");
    }
    (void)fclose(input);
    if (program->code[0] != '\0') return false;
    if (!saw_header) {
        return fail(program, CODE_MODEL, "usefulness input has no v2 header");
    }
    return true;
}

/* ------------------------------------------------------------------------ */
/* Validating the model                                                      */
/* ------------------------------------------------------------------------ */

/*
 * The depth of a type is one more than the deepest field it reaches. A cycle
 * has no depth, and a model containing one names an infinite domain: the matrix
 * would specialize forever. It is refused here rather than discovered later as
 * an exhausted budget, which would report the wrong thing about a model whose
 * defect is structural.
 */
static bool type_depth(
    Program *program,
    size_t adt,
    bool visiting[ADT_LIMIT],
    size_t known[ADT_LIMIT],
    bool computed[ADT_LIMIT],
    size_t *depth
) {
    size_t constructor;
    size_t deepest = 1u;
    if (!step(program)) return false;
    if (computed[adt]) {
        *depth = known[adt];
        return true;
    }
    if (visiting[adt]) {
        return fail(
            program,
            CODE_MODEL,
            "usefulness ADT signatures form a cycle, so the domain is infinite"
        );
    }
    visiting[adt] = true;
    for (constructor = 0u;
         constructor < program->constructor_count;
         constructor += 1u) {
        const Constructor *item = &program->constructors[constructor];
        size_t field;
        if (strcmp(item->owner, program->adts[adt].id) != 0) continue;
        for (field = 0u; field < item->field_count; field += 1u) {
            size_t child = 0u;
            if (!type_depth(
                    program,
                    item->field_adt[field],
                    visiting,
                    known,
                    computed,
                    &child)) {
                return false;
            }
            if (child + 1u > deepest) deepest = child + 1u;
        }
    }
    visiting[adt] = false;
    known[adt] = deepest;
    computed[adt] = true;
    *depth = deepest;
    return true;
}

static bool validate_model(Program *program) {
    size_t index;
    bool visiting[ADT_LIMIT];
    size_t known[ADT_LIMIT];
    bool computed[ADT_LIMIT];

    memset(visiting, 0, sizeof(visiting));
    memset(known, 0, sizeof(known));
    memset(computed, 0, sizeof(computed));

    if (program->adt_count == 0u) {
        return fail(program, CODE_MODEL, "usefulness input declares no ADT");
    }
    for (index = 0u; index < program->adt_count; index += 1u) {
        size_t other;
        for (other = 0u; other < index; other += 1u) {
            if (strcmp(program->adts[index].id, program->adts[other].id) == 0) {
                return fail(program, CODE_MODEL, "duplicate ADT identity");
            }
        }
    }
    for (index = 0u; index < program->constructor_count; index += 1u) {
        const Constructor *constructor = &program->constructors[index];
        size_t other;
        if (adt_index(program, constructor->owner) < 0) {
            return fail(
                program, CODE_MODEL, "constructor owner identity is absent");
        }
        for (other = 0u; other < index; other += 1u) {
            const Constructor *previous = &program->constructors[other];
            if (strcmp(constructor->id, previous->id) == 0) {
                return fail(
                    program, CODE_MODEL, "duplicate constructor identity");
            }
            if (strcmp(constructor->owner, previous->owner) == 0 &&
                constructor->ordinal == previous->ordinal) {
                return fail(
                    program, CODE_MODEL, "duplicate constructor ordinal");
            }
        }
    }
    for (index = 0u; index < program->adt_count; index += 1u) {
        size_t ordinal;
        size_t count = owner_constructor_count(program, index);
        if (count < 1u) {
            return fail(
                program,
                CODE_MODEL,
                "each ADT requires at least one constructor"
            );
        }
        for (ordinal = 0u; ordinal < count; ordinal += 1u) {
            if (constructor_at_ordinal(program, index, ordinal) < 0) {
                return fail(
                    program,
                    CODE_MODEL,
                    "constructor ordinals are not contiguous"
                );
            }
        }
    }
    if (!program->has_target) {
        return fail(program, CODE_MODEL, "usefulness input declares no target");
    }
    if (!type_depth(
            program,
            program->target_adt,
            visiting,
            known,
            computed,
            &program->target_depth)) {
        return false;
    }
    if (program->target_depth > TYPE_DEPTH_LIMIT) {
        return fail(program, CODE_MODEL, "target ADT signature exceeds depth 8");
    }
    if (program->arm_count == 0u) {
        return fail(program, CODE_MODEL, "usefulness input declares no arm");
    }
    for (index = 0u; index < program->arm_count; index += 1u) {
        const Arm *arm = &program->arms[index];
        const Alternative *first;
        size_t other;
        if (arm->alternative_count == 0u) {
            return fail(program, CODE_MODEL, "arm declares no alternative");
        }
        first = &program->alternatives[arm->first_alternative];
        for (other = 1u; other < arm->alternative_count; other += 1u) {
            const Alternative *item =
                &program->alternatives[arm->first_alternative + other];
            size_t role;
            bool same = item->role_count == first->role_count;
            for (role = 0u; same && role < first->role_count; role += 1u) {
                if (item->roles[role] != first->roles[role]) same = false;
            }
            if (!same) {
                char message[512];
                (void)snprintf(
                    message,
                    sizeof(message),
                    "or alternatives of the arm at bytes %zu..%zu bind different roles; hint: every alternative must bind the same names",
                    arm->start,
                    arm->end
                );
                return fail(program, CODE_MODEL, message);
            }
        }
    }
    return true;
}

/* ------------------------------------------------------------------------ */
/* The usefulness relation                                                   */
/* ------------------------------------------------------------------------ */

static bool arena_take(Program *program, size_t count, MatrixRow **rows) {
    if (count > ARENA_ROWS - program->arena_used) {
        return fail(
            program, CODE_MODEL, "usefulness working set exceeds its arena");
    }
    *rows = &program->arena[program->arena_used];
    program->arena_used += count;
    return true;
}

static bool record_width(Program *program, size_t width) {
    if (width > COLUMN_LIMIT) {
        return fail(program, CODE_MODEL, "usefulness matrix exceeds 32 columns");
    }
    if (width > program->widest_column) program->widest_column = width;
    return true;
}

/*
 * S(c, P): keep the rows whose head admits `c`, and replace that head with the
 * constructor's fields — the row's own fields when it names `c`, wildcards when
 * it is a wildcard or a binding.
 */
static bool specialize(
    Program *program,
    const Matrix *input,
    size_t constructor,
    Matrix *output
) {
    const Constructor *item = &program->constructors[constructor];
    size_t index;
    size_t kept = 0u;
    MatrixRow *rows = NULL;
    if (!arena_take(program, input->count, &rows)) return false;
    for (index = 0u; index < input->count; index += 1u) {
        const MatrixRow *row = &input->rows[index];
        const PatternNode *head;
        MatrixRow *target;
        size_t field;
        size_t width;
        if (!step(program)) return false;
        head = &program->nodes[row->columns[0]];
        if (head->kind == PATTERN_CONSTRUCTOR &&
            head->constructor != constructor) {
            continue;
        }
        width = row->width - 1u + item->field_count;
        if (!record_width(program, width)) return false;
        target = &rows[kept++];
        target->width = width;
        for (field = 0u; field < item->field_count; field += 1u) {
            target->columns[field] = head->kind == PATTERN_CONSTRUCTOR
                ? head->fields[field]
                : program->wildcard_node;
        }
        for (field = 1u; field < row->width; field += 1u) {
            target->columns[item->field_count + field - 1u] =
                row->columns[field];
        }
    }
    output->rows = rows;
    output->count = kept;
    return true;
}

/* D(P): the rows whose head admits every constructor, with that head dropped. */
static bool defaulted(Program *program, const Matrix *input, Matrix *output) {
    size_t index;
    size_t kept = 0u;
    MatrixRow *rows = NULL;
    if (!arena_take(program, input->count, &rows)) return false;
    for (index = 0u; index < input->count; index += 1u) {
        const MatrixRow *row = &input->rows[index];
        const PatternNode *head;
        MatrixRow *target;
        size_t field;
        if (!step(program)) return false;
        head = &program->nodes[row->columns[0]];
        if (head->kind == PATTERN_CONSTRUCTOR) continue;
        target = &rows[kept++];
        target->width = row->width - 1u;
        for (field = 1u; field < row->width; field += 1u) {
            target->columns[field - 1u] = row->columns[field];
        }
    }
    output->rows = rows;
    output->count = kept;
    return true;
}

static bool column_types_specialize(
    Program *program,
    const ColumnTypes *input,
    size_t constructor,
    ColumnTypes *output
) {
    const Constructor *item = &program->constructors[constructor];
    size_t field;
    size_t width = input->width - 1u + item->field_count;
    if (!record_width(program, width)) return false;
    for (field = 0u; field < item->field_count; field += 1u) {
        output->adts[field] = item->field_adt[field];
    }
    for (field = 1u; field < input->width; field += 1u) {
        output->adts[item->field_count + field - 1u] = input->adts[field];
    }
    output->width = width;
    return true;
}

static void column_types_default(
    const ColumnTypes *input,
    ColumnTypes *output
) {
    size_t field;
    for (field = 1u; field < input->width; field += 1u) {
        output->adts[field - 1u] = input->adts[field];
    }
    output->width = input->width - 1u;
}

/*
 * Whether the matrix's head column names every constructor of its ADT. A
 * complete column has no leftover: every value is admitted by some constructor
 * there, so the wildcard question splits into one question per constructor
 * instead of one about what remains.
 */
static bool column_complete(
    Program *program,
    const Matrix *matrix,
    size_t adt,
    bool *complete
) {
    bool seen[CONSTRUCTOR_LIMIT];
    size_t total = owner_constructor_count(program, adt);
    size_t distinct = 0u;
    size_t index;
    memset(seen, 0, sizeof(seen));
    for (index = 0u; index < matrix->count; index += 1u) {
        const PatternNode *head;
        if (!step(program)) return false;
        head = &program->nodes[matrix->rows[index].columns[0]];
        if (head->kind != PATTERN_CONSTRUCTOR) continue;
        if (seen[head->constructor]) continue;
        seen[head->constructor] = true;
        distinct += 1u;
    }
    *complete = distinct >= total;
    return true;
}

static void path_push(WitnessPath *path, int64_t constructor, bool closed) {
    if (path->length >= PATH_LIMIT) {
        path->overflowed = true;
        return;
    }
    path->step[path->length].constructor = constructor;
    path->step[path->length].closed = closed;
    path->length += 1u;
}

/*
 * The ordinal-least constructor of `adt` that the matrix's head column never
 * names. The default branch is reached only when one exists, and taking the
 * least is what makes a reported witness canonical rather than incidental.
 */
static bool first_absent_constructor(
    Program *program,
    const Matrix *matrix,
    size_t adt,
    int64_t *absent
) {
    size_t total = owner_constructor_count(program, adt);
    size_t ordinal;
    for (ordinal = 0u; ordinal < total; ordinal += 1u) {
        int64_t constructor = constructor_at_ordinal(program, adt, ordinal);
        size_t index;
        bool named = false;
        if (constructor < 0) {
            return fail(program, CODE_MODEL, "constructor ordinal is absent");
        }
        for (index = 0u; index < matrix->count && !named; index += 1u) {
            const PatternNode *head;
            if (!step(program)) return false;
            head = &program->nodes[matrix->rows[index].columns[0]];
            if (head->kind == PATTERN_CONSTRUCTOR &&
                head->constructor == (size_t)constructor) {
                named = true;
            }
        }
        if (!named) {
            *absent = constructor;
            return true;
        }
    }
    *absent = -1;
    return true;
}

/*
 * U(P, q). `q` is one row; `types` names the ADT of each of its columns.
 *
 * The constructors chosen on the successful path are recorded in `path`, in the
 * order the witness reads. A failed branch rewinds it, so what remains at the
 * end is the path of the answer and not of the search.
 */
static bool useful(
    Program *program,
    const Matrix *matrix,
    const MatrixRow *candidate,
    const ColumnTypes *types,
    size_t depth,
    WitnessPath *path,
    bool *result
) {
    const PatternNode *head;
    size_t adt;
    bool complete = false;

    if (!step(program)) return false;
    if (depth > RECURSION_LIMIT) {
        return fail(
            program,
            CODE_MODEL,
            "usefulness analysis exceeds 40 nested columns"
        );
    }
    if (types->width == 0u) {
        /* Nothing left to distinguish: the candidate is useful exactly when no
         * row above it survived this far. */
        *result = matrix->count == 0u;
        return true;
    }
    adt = types->adts[0];
    head = &program->nodes[candidate->columns[0]];

    if (head->kind == PATTERN_CONSTRUCTOR) {
        Matrix specialized;
        MatrixRow *narrowed_row = NULL;
        ColumnTypes narrowed;
        size_t mark = program->arena_used;
        size_t saved = path->length;
        size_t constructor = head->constructor;
        const Constructor *item = &program->constructors[constructor];
        size_t field;
        bool answer = false;
        if (!specialize(program, matrix, constructor, &specialized) ||
            !column_types_specialize(program, types, constructor, &narrowed) ||
            !arena_take(program, 1u, &narrowed_row)) {
            return false;
        }
        narrowed_row->width = narrowed.width;
        for (field = 0u; field < item->field_count; field += 1u) {
            narrowed_row->columns[field] = head->fields[field];
        }
        for (field = 1u; field < candidate->width; field += 1u) {
            narrowed_row->columns[item->field_count + field - 1u] =
                candidate->columns[field];
        }
        path_push(path, (int64_t)constructor, false);
        if (!useful(
                program,
                &specialized,
                narrowed_row,
                &narrowed,
                depth + 1u,
                path,
                &answer)) {
            return false;
        }
        if (!answer) path->length = saved;
        program->arena_used = mark;
        *result = answer;
        return true;
    }

    if (!column_complete(program, matrix, adt, &complete)) return false;

    if (complete) {
        size_t total = owner_constructor_count(program, adt);
        size_t ordinal;
        /* Ordinal order, and the first constructor that answers wins. That is
         * what makes the reported witness canonical rather than incidental. */
        for (ordinal = 0u; ordinal < total; ordinal += 1u) {
            int64_t constructor = constructor_at_ordinal(program, adt, ordinal);
            Matrix specialized;
            MatrixRow *narrowed_row = NULL;
            ColumnTypes narrowed;
            const Constructor *item;
            size_t mark = program->arena_used;
            size_t saved = path->length;
            size_t field;
            bool answer = false;
            if (constructor < 0) {
                return fail(program, CODE_MODEL, "constructor ordinal is absent");
            }
            item = &program->constructors[(size_t)constructor];
            if (!specialize(
                    program, matrix, (size_t)constructor, &specialized) ||
                !column_types_specialize(
                    program, types, (size_t)constructor, &narrowed) ||
                !arena_take(program, 1u, &narrowed_row)) {
                return false;
            }
            narrowed_row->width = narrowed.width;
            for (field = 0u; field < item->field_count; field += 1u) {
                narrowed_row->columns[field] = program->wildcard_node;
            }
            for (field = 1u; field < candidate->width; field += 1u) {
                narrowed_row->columns[item->field_count + field - 1u] =
                    candidate->columns[field];
            }
            path_push(path, constructor, false);
            if (!useful(
                    program,
                    &specialized,
                    narrowed_row,
                    &narrowed,
                    depth + 1u,
                    path,
                    &answer)) {
                return false;
            }
            program->arena_used = mark;
            if (answer) {
                *result = true;
                return true;
            }
            path->length = saved;
        }
        *result = false;
        return true;
    }

    {
        Matrix reduced;
        MatrixRow *narrowed_row = NULL;
        ColumnTypes narrowed;
        size_t mark = program->arena_used;
        size_t saved = path->length;
        size_t field;
        int64_t absent = -1;
        bool answer = false;
        if (!defaulted(program, matrix, &reduced) ||
            !arena_take(program, 1u, &narrowed_row)) {
            return false;
        }
        column_types_default(types, &narrowed);
        narrowed_row->width = narrowed.width;
        for (field = 1u; field < candidate->width; field += 1u) {
            narrowed_row->columns[field - 1u] = candidate->columns[field];
        }
        /* The column is incomplete, so a constructor it never names exists and
         * is what this position is missing. Recorded closed: nothing was
         * examined inside it, so every field of it is any value. */
        if (!first_absent_constructor(program, matrix, adt, &absent)) {
            return false;
        }
        path_push(path, absent, true);
        if (!useful(
                program,
                &reduced,
                narrowed_row,
                &narrowed,
                depth + 1u,
                path,
                &answer)) {
            return false;
        }
        if (!answer) path->length = saved;
        program->arena_used = mark;
        *result = answer;
        return true;
    }
}

/*
 * Renders the path a useful wildcard took as a value of the target type. A
 * `-1` is a position the analysis never had to split, which is any value of
 * that position's type and is written `_`.
 */
static bool render_witness(
    Program *program,
    const WitnessPath *path,
    size_t *cursor,
    size_t adt,
    char *output,
    size_t capacity,
    size_t *used
) {
    WitnessStep choice;
    const Constructor *constructor;
    size_t field;
    if (!step(program)) return false;
    if (*used + NAME_LIMIT + 8u >= capacity) {
        return fail(
            program, CODE_MODEL, "usefulness witness exceeds its display bound");
    }
    if (*cursor >= path->length) {
        *used += (size_t)snprintf(output + *used, capacity - *used, "_");
        return true;
    }
    choice = path->step[*cursor];
    *cursor += 1u;
    if (choice.constructor < 0) {
        *used += (size_t)snprintf(output + *used, capacity - *used, "_");
        return true;
    }
    constructor = &program->constructors[(size_t)choice.constructor];
    if (strcmp(constructor->owner, program->adts[adt].id) != 0) {
        return fail(program, CODE_MODEL, "witness constructor left its column");
    }
    *used += (size_t)snprintf(
        output + *used, capacity - *used, "%s", constructor->name);
    if (constructor->field_count == 0u) return true;
    *used += (size_t)snprintf(output + *used, capacity - *used, "(");
    for (field = 0u; field < constructor->field_count; field += 1u) {
        if (field > 0u) {
            *used += (size_t)snprintf(output + *used, capacity - *used, ", ");
        }
        if (choice.closed) {
            /* Nothing was examined inside this constructor, so every field is
             * any value and no further entry belongs to it. */
            if (!step(program)) return false;
            *used += (size_t)snprintf(output + *used, capacity - *used, "_");
            continue;
        }
        if (!render_witness(
                program,
                path,
                cursor,
                constructor->field_adt[field],
                output,
                capacity,
                used)) {
            return false;
        }
    }
    *used += (size_t)snprintf(output + *used, capacity - *used, ")");
    return true;
}

/* ------------------------------------------------------------------------ */
/* Analysis                                                                  */
/* ------------------------------------------------------------------------ */

static bool build_matrix(
    Program *program,
    const size_t members[],
    size_t member_count,
    Matrix *matrix
) {
    MatrixRow *rows = NULL;
    size_t index;
    if (!arena_take(program, member_count, &rows)) return false;
    for (index = 0u; index < member_count; index += 1u) {
        rows[index].width = 1u;
        rows[index].columns[0] = program->alternatives[members[index]].root;
    }
    matrix->rows = rows;
    matrix->count = member_count;
    return true;
}

static bool analyze(Program *program) {
    size_t covering[ROW_LIMIT];
    size_t covering_count = 0u;
    size_t preceding[ROW_LIMIT];
    size_t arm_index;

    if (!take_node(program, &program->wildcard_node)) return false;
    program->nodes[program->wildcard_node].kind = PATTERN_WILDCARD;
    program->widest_column = 1u;

    for (arm_index = 0u; arm_index < program->arm_count; arm_index += 1u) {
        const Arm *arm = &program->arms[arm_index];
        size_t alternative_index;
        size_t redundant = 0u;
        for (alternative_index = 0u;
             alternative_index < arm->alternative_count;
             alternative_index += 1u) {
            size_t member = arm->first_alternative + alternative_index;
            Matrix above;
            MatrixRow *candidate = NULL;
            ColumnTypes types;
            WitnessPath path;
            size_t mark = program->arena_used;
            size_t count = 0u;
            size_t previous;
            bool answer = false;

            /*
             * What an alternative is tested against: every alternative of an
             * earlier unguarded arm, plus this arm's own earlier alternatives.
             *
             * A guarded arm may not fire, so it never hides a later arm — that
             * is the conservative direction, and it is why a guard can only
             * remove a redundancy report, never add one. But an alternative of
             * this same arm is tested before this one whatever the guard does,
             * so it can hide it.
             */
            for (previous = 0u; previous < member; previous += 1u) {
                const Alternative *item = &program->alternatives[previous];
                if (!step(program)) return false;
                if (item->arm != arm_index &&
                    program->arms[item->arm].guarded) {
                    continue;
                }
                preceding[count++] = previous;
            }
            if (!build_matrix(program, preceding, count, &above) ||
                !arena_take(program, 1u, &candidate)) {
                return false;
            }
            candidate->width = 1u;
            candidate->columns[0] = program->alternatives[member].root;
            types.width = 1u;
            types.adts[0] = program->target_adt;
            path.length = 0u;
            path.overflowed = false;
            if (!useful(program, &above, candidate, &types, 0u, &path, &answer)) {
                return false;
            }
            program->arena_used = mark;
            if (answer) continue;

            redundant += 1u;
            if (arm->alternative_count > 1u) {
                char message[512];
                (void)snprintf(
                    message,
                    sizeof(message),
                    "unreachable or alternative %zu of the match arm at bytes %zu..%zu: every value it matches is already matched earlier; hint: remove the alternative",
                    alternative_index,
                    arm->start,
                    arm->end
                );
                return fail(program, CODE_REDUNDANT, message);
            }
        }
        if (redundant == arm->alternative_count) {
            char message[512];
            (void)snprintf(
                message,
                sizeof(message),
                "unreachable match arm at bytes %zu..%zu: every value it matches is already matched by an earlier arm; hint: remove the arm",
                arm->start,
                arm->end
            );
            return fail(program, CODE_REDUNDANT, message);
        }
        if (arm->guarded) continue;
        for (alternative_index = 0u;
             alternative_index < arm->alternative_count;
             alternative_index += 1u) {
            covering[covering_count++] = arm->first_alternative + alternative_index;
        }
    }

    {
        Matrix above;
        MatrixRow *candidate = NULL;
        ColumnTypes types;
        WitnessPath path;
        size_t mark = program->arena_used;
        bool answer = false;
        if (!build_matrix(program, covering, covering_count, &above) ||
            !arena_take(program, 1u, &candidate)) {
            return false;
        }
        candidate->width = 1u;
        candidate->columns[0] = program->wildcard_node;
        types.width = 1u;
        types.adts[0] = program->target_adt;
        path.length = 0u;
        path.overflowed = false;
        if (!useful(program, &above, candidate, &types, 0u, &path, &answer)) {
            return false;
        }
        program->arena_used = mark;
        if (answer) {
            char rendered[WITNESS_TEXT_LIMIT];
            char message[1024];
            size_t cursor = 0u;
            size_t used = 0u;
            if (path.overflowed) {
                return fail(
                    program,
                    CODE_MODEL,
                    "usefulness witness exceeds 64 recorded positions"
                );
            }
            rendered[0] = '\0';
            if (!render_witness(
                    program,
                    &path,
                    &cursor,
                    program->target_adt,
                    rendered,
                    sizeof(rendered),
                    &used)) {
                return false;
            }
            (void)snprintf(
                message,
                sizeof(message),
                "non-exhaustive match on `%s`: no arm matches `%s`; hint: add the missing case or a wildcard arm",
                program->adts[program->target_adt].name,
                rendered
            );
            return fail(program, CODE_NON_EXHAUSTIVE, message);
        }
    }
    return true;
}

/* ------------------------------------------------------------------------ */
/* Publication                                                               */
/* ------------------------------------------------------------------------ */

static bool paths_alias(const char *input, const char *output) {
    struct stat input_stat;
    struct stat output_stat;
    if (strcmp(input, output) == 0) return true;
    if (stat(input, &input_stat) != 0 || stat(output, &output_stat) != 0) {
        return false;
    }
    return input_stat.st_dev == output_stat.st_dev &&
        input_stat.st_ino == output_stat.st_ino;
}

/*
 * The canonical trace. Everything in it is derived from resolved identities and
 * declaration order, so two runs of one model publish the same bytes and a
 * model reached through a different path publishes the same bytes as well.
 */
static bool publish(Program *program, const char *path) {
    char temporary[4096];
    FILE *output;
    size_t index;
    const Adt *target = &program->adts[program->target_adt];
    if (strlen(path) + 5u >= sizeof(temporary)) {
        return fail(program, CODE_MODEL, "usefulness output path is too long");
    }
    (void)snprintf(temporary, sizeof(temporary), "%s.tmp", path);
    (void)remove(temporary);
    output = fopen(temporary, "wb");
    if (output == NULL) {
        return fail(program, CODE_MODEL, "cannot create usefulness transaction");
    }
    fprintf(output, "kofun-adt-usefulness-result/v2\n");
    fprintf(
        output,
        "target|adt=%s|name=%s|constructors=%zu|depth=%zu\n",
        target->id,
        target->name,
        owner_constructor_count(program, program->target_adt),
        program->target_depth
    );
    for (index = 0u; index < program->arm_count; index += 1u) {
        const Arm *arm = &program->arms[index];
        size_t alternative_index;
        fprintf(
            output,
            "arm|index=%zu|span=%zu..%zu|guard=%s|alternatives=%zu|status=useful\n",
            arm->index,
            arm->start,
            arm->end,
            arm->guarded ? "yes" : "no",
            arm->alternative_count
        );
        for (alternative_index = 0u;
             alternative_index < arm->alternative_count;
             alternative_index += 1u) {
            const Alternative *item =
                &program->alternatives[arm->first_alternative + alternative_index];
            size_t role;
            fprintf(
                output,
                "alternative|arm=%zu|index=%zu|status=useful|roles=",
                item->arm,
                item->index
            );
            if (item->role_count == 0u) {
                fprintf(output, "-");
            } else {
                for (role = 0u; role < item->role_count; role += 1u) {
                    fprintf(
                        output,
                        "%s%s",
                        role == 0u ? "" : ",",
                        program->roles[item->roles[role]]
                    );
                }
            }
            fprintf(output, "\n");
        }
    }
    fprintf(
        output,
        "complete|arms=%zu|alternatives=%zu|constructors=%zu|columns=%zu|operations=%" PRIu64 "\n",
        program->arm_count,
        program->alternative_count,
        program->constructor_count,
        program->widest_column,
        program->operations
    );
    if (fclose(output) != 0 || rename(temporary, path) != 0) {
        (void)remove(temporary);
        (void)remove(path);
        return fail(program, CODE_MODEL, "cannot commit usefulness output");
    }
    return true;
}

int main(int argc, char **argv) {
    static Program program;
    char temporary[4096];
    memset(&program, 0, sizeof(program));
    if (argc != 3) {
        fprintf(
            stderr,
            "usage: %s INPUT.matrix OUTPUT.result\n",
            argc > 0 ? argv[0] : "adt-usefulness-v2"
        );
        return 2;
    }
    if (strlen(argv[2]) + 5u >= sizeof(temporary)) {
        fprintf(stderr, "error[%s]: usefulness output path is too long\n", CODE_MODEL);
        return 1;
    }
    (void)snprintf(temporary, sizeof(temporary), "%s.tmp", argv[2]);
    if (paths_alias(argv[1], argv[2]) || paths_alias(argv[1], temporary)) {
        fprintf(
            stderr,
            "error[%s]: input and output paths must differ\n",
            CODE_MODEL
        );
        return 1;
    }
    (void)remove(argv[2]);
    if (!read_input(&program, argv[1]) || !validate_model(&program) ||
        !analyze(&program) || !publish(&program, argv[2])) {
        (void)remove(argv[2]);
        fprintf(stderr, "error[%s]: %s\n", program.code, program.message);
        return 1;
    }
    return 0;
}
