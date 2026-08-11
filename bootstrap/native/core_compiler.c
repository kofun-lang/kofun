/*
 * Audited bootstrap driver for the Kofun-owned direct native encoder.
 *
 * The target-independent frontend parses deliberately small Kofun Core
 * profiles. The shared scalar/List/Text profile starts with:
 *
 *   fn main() {
 *       print(CONSTANT_EXPRESSION)
 *   }
 *
 * CONSTANT_EXPRESSION supports a narrow integer, List[Int], and Text Core.
 * A second x86-64 Int profile supports multiple functions, arguments, return
 * values, forward calls, recursion, comparison guards, and checked arithmetic.
 * Unsupported target/type combinations fail before an image is written.
 *
 * This C11 seed is temporary bootstrap machinery. Canonical instruction, ELF,
 * and postfix Core encoders live in encoder.kofun; no Python implementation is
 * used by this compiler.
 */

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../unicode/kofun_unicode.c"

enum {
    ELF_HEADER_SIZE = 64,
    PROGRAM_HEADER_SIZE = 56,
    PROGRAM_HEADER_COUNT = 2,
    TEXT_OFFSET = ELF_HEADER_SIZE +
        PROGRAM_HEADER_SIZE * PROGRAM_HEADER_COUNT,
    PAGE_SIZE = 4096,
};

static const uint64_t IMAGE_BASE = UINT64_C(0x400000);
static const uint64_t DATA_ADDRESS = UINT64_C(0x401000);

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
} Bytes;

typedef struct {
    size_t *offsets;
    size_t *lines;
    size_t length;
    size_t capacity;
} LineRows;

static void fatal(const char *message) {
    fprintf(stderr, "kofun native: %s\n", message);
    exit(2);
}

static void *allocate(size_t size) {
    void *value = malloc(size == 0 ? 1 : size);
    if (value == NULL) fatal("out of memory");
    return value;
}

static void bytes_init(Bytes *bytes) {
    bytes->length = 0;
    bytes->capacity = 256;
    bytes->data = allocate(bytes->capacity);
}

static void bytes_reserve(Bytes *bytes, size_t extra) {
    if (extra > SIZE_MAX - bytes->length) fatal("image is too large");
    size_t needed = bytes->length + extra;
    if (needed <= bytes->capacity) return;
    size_t capacity = bytes->capacity;
    while (capacity < needed) {
        if (capacity > SIZE_MAX / 2) fatal("image is too large");
        capacity *= 2;
    }
    uint8_t *data = realloc(bytes->data, capacity);
    if (data == NULL) fatal("out of memory");
    bytes->data = data;
    bytes->capacity = capacity;
}

static void byte(Bytes *bytes, uint8_t value) {
    bytes_reserve(bytes, 1);
    bytes->data[bytes->length++] = value;
}

static void u16_le(Bytes *bytes, uint16_t value) {
    byte(bytes, (uint8_t)value);
    byte(bytes, (uint8_t)(value >> 8));
}

static void u32_le(Bytes *bytes, uint32_t value) {
    byte(bytes, (uint8_t)value);
    byte(bytes, (uint8_t)(value >> 8));
    byte(bytes, (uint8_t)(value >> 16));
    byte(bytes, (uint8_t)(value >> 24));
}

static void u64_le(Bytes *bytes, uint64_t value) {
    u32_le(bytes, (uint32_t)value);
    u32_le(bytes, (uint32_t)(value >> 32));
}

static void bytes_pad_to(Bytes *bytes, size_t length) {
    while (bytes->length < length) byte(bytes, 0);
}

static void line_rows_init(LineRows *rows) {
    rows->length = 0;
    rows->capacity = 16;
    rows->offsets = allocate(rows->capacity * sizeof(*rows->offsets));
    rows->lines = allocate(rows->capacity * sizeof(*rows->lines));
}

static void line_row(LineRows *rows, size_t offset, size_t line) {
    if (line == 0) fatal("source line must be positive");
    if (rows->length > 0 && rows->lines[rows->length - 1] == line) return;
    if (rows->length == rows->capacity) {
        if (rows->capacity > SIZE_MAX / 2) fatal("too many debug line rows");
        rows->capacity *= 2;
        size_t *offsets = realloc(
            rows->offsets,
            rows->capacity * sizeof(*rows->offsets)
        );
        size_t *lines = realloc(
            rows->lines,
            rows->capacity * sizeof(*rows->lines)
        );
        if (offsets == NULL || lines == NULL) fatal("out of memory");
        rows->offsets = offsets;
        rows->lines = lines;
    }
    rows->offsets[rows->length] = offset;
    rows->lines[rows->length] = line;
    ++rows->length;
}

static void line_rows_free(LineRows *rows) {
    free(rows->offsets);
    free(rows->lines);
}

static char *read_source(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        fprintf(stderr, "kofun native: cannot read %s: %s\n",
                path, strerror(errno));
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) fatal("cannot seek source");
    long size = ftell(file);
    if (size < 0) fatal("cannot measure source");
    if (fseek(file, 0, SEEK_SET) != 0) fatal("cannot rewind source");
    char *source = allocate((size_t)size + 1);
    size_t read = fread(source, 1, (size_t)size, file);
    if (read != (size_t)size || ferror(file)) fatal("cannot read source");
    if (fclose(file) != 0) fatal("cannot close source");
    source[read] = '\0';
    return source;
}

typedef enum {
    NODE_LITERAL,
    NODE_TEXT_LITERAL,
    NODE_ADD,
    NODE_TEXT_CONCAT,
    NODE_TEXT_EQUAL,
    NODE_TEXT_NOT_EQUAL,
    NODE_INT_EQUAL,
    NODE_INT_NOT_EQUAL,
    NODE_INT_LESS,
    NODE_INT_LESS_EQUAL,
    NODE_INT_GREATER,
    NODE_INT_GREATER_EQUAL,
    NODE_MULTIPLY,
    NODE_NEGATE,
    NODE_VARIABLE,
    NODE_PARAMETER,
    NODE_LET,
    NODE_LIST,
    NODE_CHARS,
    NODE_CODEPOINTS,
    NODE_BYTES,
    NODE_INDEX,
    NODE_LENGTH,
    NODE_MAP,
    NODE_FILTER,
    NODE_FOLD,
} NodeKind;

typedef enum {
    VALUE_INT,
    VALUE_BOOL,
    VALUE_TEXT,
    VALUE_LIST,
} ValueKind;

typedef struct Node Node;

struct Node {
    NodeKind kind;
    ValueKind value_kind;
    int64_t value;
    bool value_known;
    uint8_t *text_value;
    size_t text_length;
    size_t text_codepoints;
    size_t text_graphemes;
    ValueKind element_kind;
    size_t source_line;
    Node *left;
    Node *right;
    Node *third;
    Node **items;
    size_t item_count;
    const Node *known_collection;
    size_t slot;
};

enum {
    MAX_CORE_BINDINGS = 64,
    MAX_CORE_NAME = 64,
};

typedef struct {
    char name[MAX_CORE_NAME];
    ValueKind value_kind;
    ValueKind element_kind;
    size_t item_count;
    int64_t value;
    bool value_known;
    const Node *known_collection;
    size_t slot;
    bool parameter;
} Binding;

typedef struct {
    const char *source;
    size_t cursor;
    const char *error;
    size_t main_line;
    size_t print_line;
    Binding bindings[MAX_CORE_BINDINGS + 2];
    size_t binding_count;
    size_t local_count;
    size_t max_lambda_parameters;
} Parser;

enum {
    MAX_CORE_FUNCTIONS = 64,
    MAX_CORE_PARAMETERS = 6,
    MAX_CORE_STATEMENTS = 64,
    /*
     * AArch64 frame slots use signed unscaled 9-bit offsets, so slots 0..31
     * cover offsets -8..-256. Keep the accepted program target-independent by
     * rejecting a 33rd parameter/local before either backend is selected.
     */
    MAX_FUNCTION_FRAME_SLOTS = 32,
};

typedef enum {
    FUNCTION_VALUE_INT,
    FUNCTION_VALUE_BOOL,
    FUNCTION_VALUE_TEXT,
} FunctionValueKind;

typedef enum {
    FUNCTION_LITERAL,
    FUNCTION_TEXT_LITERAL,
    FUNCTION_PARAMETER,
    FUNCTION_CALL,
    FUNCTION_SYSCALL,
    FUNCTION_ADD,
    FUNCTION_TEXT_CONCAT,
    FUNCTION_SUBTRACT,
    FUNCTION_MULTIPLY,
    FUNCTION_FLOOR_DIVIDE,
    FUNCTION_FLOOR_MODULO,
    FUNCTION_NEGATE,
    FUNCTION_EQUAL,
    FUNCTION_NOT_EQUAL,
    FUNCTION_LESS,
    FUNCTION_LESS_EQUAL,
    FUNCTION_GREATER,
    FUNCTION_GREATER_EQUAL,
} FunctionExpressionKind;

/*
 * The Linux syscall intrinsics `stdlib/linux_x86_64/abi.kofun` declares.
 *
 * They are recognised by name at the call site instead of being declared in the
 * source under compilation: the native Core has no import path, and that stdlib
 * declaration — fixed arities, `Int` arguments, `Int` result — is the
 * specification these names answer to. The digit names the count of syscall
 * arguments, so `__linux_syscallN` takes `N + 1` values: the syscall number
 * first, then the arguments. That is one more than a native Core function may
 * take, which is why the intrinsic carries its own argument placement rather
 * than reusing the ordinary call boundary.
 */
enum {
    FUNCTION_SYSCALL_MAX_ARITY = 6,
    FUNCTION_SYSCALL_MAX_ARGUMENTS = FUNCTION_SYSCALL_MAX_ARITY + 1,
};

static const char *const
function_syscall_names[FUNCTION_SYSCALL_MAX_ARGUMENTS] = {
    "__linux_syscall0",
    "__linux_syscall1",
    "__linux_syscall2",
    "__linux_syscall3",
    "__linux_syscall4",
    "__linux_syscall5",
    "__linux_syscall6",
};

/* True when `name` is one of the seven intrinsics; `arity` receives its digit. */
static bool function_syscall_arity(const char *name, size_t *arity) {
    for (size_t index = 0;
         index < FUNCTION_SYSCALL_MAX_ARGUMENTS;
         ++index) {
        if (strcmp(name, function_syscall_names[index]) != 0) continue;
        if (arity != NULL) *arity = index;
        return true;
    }
    return false;
}

typedef enum {
    FUNCTION_TRAP_ADD_OVERFLOW,
    FUNCTION_TRAP_SUBTRACT_OVERFLOW,
    FUNCTION_TRAP_MULTIPLY_OVERFLOW,
    FUNCTION_TRAP_NEGATE_OVERFLOW,
    FUNCTION_TRAP_FLOOR_DIVIDE_OVERFLOW,
    FUNCTION_TRAP_FLOOR_DIVIDE_ZERO,
    FUNCTION_TRAP_MODULO_ZERO,
    FUNCTION_TRAP_COUNT,
} FunctionTrapKind;

static const char *function_trap_message(FunctionTrapKind kind) {
    switch (kind) {
        case FUNCTION_TRAP_ADD_OVERFLOW:
            return "error[R010]: integer overflow in operator `+`\n";
        case FUNCTION_TRAP_SUBTRACT_OVERFLOW:
            return "error[R010]: integer overflow in operator `-`\n";
        case FUNCTION_TRAP_MULTIPLY_OVERFLOW:
            return "error[R010]: integer overflow in operator `*`\n";
        case FUNCTION_TRAP_NEGATE_OVERFLOW:
            return "error[R010]: integer overflow in unary operator `-`\n";
        case FUNCTION_TRAP_FLOOR_DIVIDE_OVERFLOW:
            return "error[R010]: integer overflow in operator `//`\n";
        case FUNCTION_TRAP_FLOOR_DIVIDE_ZERO:
            return "error[R010]: operator `//` failed: division by zero\n";
        case FUNCTION_TRAP_MODULO_ZERO:
            return "error[R010]: operator `%` failed: division by zero\n";
        case FUNCTION_TRAP_COUNT:
            break;
    }
    fatal("unknown function trap");
    return NULL;
}

static FunctionTrapKind function_divide_zero_trap(
    FunctionExpressionKind kind
) {
    if (kind == FUNCTION_FLOOR_DIVIDE) {
        return FUNCTION_TRAP_FLOOR_DIVIDE_ZERO;
    }
    if (kind == FUNCTION_FLOOR_MODULO) return FUNCTION_TRAP_MODULO_ZERO;
    fatal("non-dividing expression requested a zero-divisor trap");
    return FUNCTION_TRAP_FLOOR_DIVIDE_ZERO;
}

static FunctionTrapKind function_divide_overflow_trap(
    FunctionExpressionKind kind
) {
    if (kind == FUNCTION_FLOOR_DIVIDE) {
        return FUNCTION_TRAP_FLOOR_DIVIDE_OVERFLOW;
    }
    fatal("non-quotient expression requested a quotient-overflow trap");
    return FUNCTION_TRAP_FLOOR_DIVIDE_OVERFLOW;
}

typedef struct FunctionExpression FunctionExpression;

struct FunctionExpression {
    FunctionExpressionKind kind;
    FunctionValueKind value_kind;
    int64_t value;
    uint8_t *text_value;
    size_t text_length;
    size_t source_line;
    size_t slot;
    size_t function_index;
    FunctionExpression *left;
    FunctionExpression *right;
    FunctionExpression **arguments;
    size_t argument_count;
    /*
     * `arguments` is indexed by *declaration slot*, so the ABI vector is filled
     * in declaration order simply by walking it. `argument_order` records which
     * slot each source position filled, so evaluation walks source order
     * instead. Keeping the two orders in separate arrays is what lets a
     * labelled call evaluate as written and place as declared without either
     * loop knowing about labels.
     *
     * For an unlabelled call the two coincide: slot i is written i-th.
     */
    size_t argument_order[MAX_CORE_PARAMETERS];
};

typedef enum {
    FUNCTION_STATEMENT_IF_RETURN,
    FUNCTION_STATEMENT_RETURN,
    FUNCTION_STATEMENT_PRINT,
    FUNCTION_STATEMENT_LET,
    FUNCTION_STATEMENT_EXPRESSION,
} FunctionStatementKind;

typedef struct {
    FunctionStatementKind kind;
    FunctionExpression *condition;
    FunctionExpression *value;
    size_t slot;
    size_t source_line;
} FunctionStatement;

typedef struct {
    char name[MAX_CORE_NAME];
    char parameters[MAX_CORE_PARAMETERS][MAX_CORE_NAME];
    /*
     * The declaration-site external label of each parameter, empty when the
     * parameter has none. `parameters` stays the *internal* name, because that
     * is what the body binds — a label is call-site vocabulary only, and no
     * lookup inside the function may see it (call-arguments v1, rule 4).
     */
    char parameter_labels[MAX_CORE_PARAMETERS][MAX_CORE_NAME];
    FunctionValueKind parameter_types[MAX_CORE_PARAMETERS];
    size_t parameter_count;
    char locals[MAX_CORE_STATEMENTS][MAX_CORE_NAME];
    FunctionValueKind local_types[MAX_CORE_STATEMENTS];
    size_t local_count;
    FunctionValueKind result_kind;
    bool has_result;
    size_t declaration_line;
    size_t body_start;
    size_t body_end;
    FunctionStatement statements[MAX_CORE_STATEMENTS];
    size_t statement_count;
} FunctionDeclaration;

typedef struct {
    const char *source;
    FunctionDeclaration functions[MAX_CORE_FUNCTIONS];
    size_t function_count;
    size_t main_index;
} FunctionProgram;

typedef struct {
    const char *source;
    size_t cursor;
    size_t limit;
    char error[256];
    const FunctionProgram *program;
    const FunctionDeclaration *function;
} FunctionParser;

static size_t source_line(const char *source, size_t offset) {
    size_t line = 1;
    for (size_t index = 0; index < offset; ++index) {
        if (source[index] == '\n') ++line;
    }
    return line;
}

static void skip_trivia(Parser *parser) {
    for (;;) {
        while (isspace((unsigned char)parser->source[parser->cursor])) {
            ++parser->cursor;
        }
        if (parser->source[parser->cursor] != '#') return;
        while (parser->source[parser->cursor] != '\0' &&
               parser->source[parser->cursor] != '\n') {
            ++parser->cursor;
        }
    }
}

static bool identifier_start_at(
    const char *source,
    size_t length,
    size_t offset,
    size_t *width
) {
    if (offset >= length) return false;
    uint32_t codepoint = 0;
    size_t scalar_width = 0;
    if (!kofun_unicode_decode(
            (const uint8_t *)source,
            length,
            offset,
            &codepoint,
            &scalar_width)) {
        return false;
    }
    if (width != NULL) *width = scalar_width;
    return codepoint == '_' || kofun_unicode_is_xid_start(codepoint);
}

static bool identifier_continue_at(
    const char *source,
    size_t length,
    size_t offset,
    size_t *width
) {
    if (offset >= length) return false;
    uint32_t codepoint = 0;
    size_t scalar_width = 0;
    if (!kofun_unicode_decode(
            (const uint8_t *)source,
            length,
            offset,
            &codepoint,
            &scalar_width)) {
        return false;
    }
    if (width != NULL) *width = scalar_width;
    return codepoint == '_' || kofun_unicode_is_xid_continue(codepoint);
}

static bool consume_word(Parser *parser, const char *word) {
    skip_trivia(parser);
    size_t length = strlen(word);
    if (strncmp(parser->source + parser->cursor, word, length) != 0 ||
        identifier_continue_at(
            parser->source,
            strlen(parser->source),
            parser->cursor + length,
            NULL)) {
        return false;
    }
    parser->cursor += length;
    return true;
}

static bool consume_char(Parser *parser, char wanted) {
    skip_trivia(parser);
    if (parser->source[parser->cursor] != wanted) return false;
    ++parser->cursor;
    return true;
}

static void parse_error(Parser *parser, const char *message) {
    if (parser->error == NULL) parser->error = message;
}

static Node *node(
    NodeKind kind,
    ValueKind value_kind,
    int64_t value,
    bool value_known,
    size_t line,
    Node *left,
    Node *right
) {
    Node *result = allocate(sizeof(*result));
    result->kind = kind;
    result->value_kind = value_kind;
    result->value = value;
    result->value_known = value_known;
    result->text_value = NULL;
    result->text_length = 0;
    result->text_codepoints = 0;
    result->text_graphemes = 0;
    result->element_kind = VALUE_INT;
    result->source_line = line;
    result->left = left;
    result->right = right;
    result->third = NULL;
    result->items = NULL;
    result->item_count = 0;
    result->known_collection = NULL;
    result->slot = 0;
    return result;
}

static Node *parse_expression(Parser *parser);
static void free_node(Node *expression);

static uint8_t *copy_bytes(const uint8_t *bytes, size_t length) {
    uint8_t *copy = allocate(length);
    if (length > 0) memcpy(copy, bytes, length);
    return copy;
}

static Node *text_node(
    NodeKind kind,
    const uint8_t *bytes,
    size_t length,
    size_t codepoints,
    size_t graphemes,
    size_t line,
    Node *left,
    Node *right
) {
    Node *result = node(
        kind,
        VALUE_TEXT,
        0,
        true,
        line,
        left,
        right
    );
    result->text_value = copy_bytes(bytes, length);
    result->text_length = length;
    result->text_codepoints = codepoints;
    result->text_graphemes = graphemes;
    return result;
}

static Node *parse_text_literal(Parser *parser, size_t literal_at) {
    Bytes bytes;
    bytes_init(&bytes);
    while (parser->source[parser->cursor] != '\0' &&
           parser->source[parser->cursor] != '"') {
        unsigned char value =
            (unsigned char)parser->source[parser->cursor++];
        if (value == '\\') {
            char escaped = parser->source[parser->cursor++];
            if (escaped == 'n') value = '\n';
            else if (escaped == 'r') value = '\r';
            else if (escaped == 't') value = '\t';
            else if (escaped == '\\') value = '\\';
            else if (escaped == '"') value = '"';
            else {
                parse_error(parser, "unsupported Text escape");
                free(bytes.data);
                return NULL;
            }
        }
        byte(&bytes, (uint8_t)value);
    }
    if (parser->source[parser->cursor] != '"') {
        parse_error(parser, "unterminated Text literal");
        free(bytes.data);
        return NULL;
    }
    ++parser->cursor;
    size_t codepoints = 0;
    size_t graphemes = 0;
    if (!kofun_unicode_codepoint_count(
            bytes.data, bytes.length, &codepoints) ||
        !kofun_unicode_grapheme_count(
            bytes.data, bytes.length, &graphemes)) {
        parse_error(parser, "Text literal is not valid UTF-8");
        free(bytes.data);
        return NULL;
    }
    Node *result = text_node(
        NODE_TEXT_LITERAL,
        bytes.data,
        bytes.length,
        codepoints,
        graphemes,
        source_line(parser->source, literal_at),
        NULL,
        NULL
    );
    free(bytes.data);
    return result;
}

static bool parse_identifier(
    Parser *parser,
    char name[MAX_CORE_NAME]
) {
    skip_trivia(parser);
    size_t length = strlen(parser->source);
    size_t first_width = 0;
    if (!identifier_start_at(
            parser->source,
            length,
            parser->cursor,
            &first_width)) {
        return false;
    }
    size_t start = parser->cursor;
    parser->cursor += first_width;
    while (identifier_continue_at(
            parser->source,
            length,
            parser->cursor,
            &first_width)) {
        parser->cursor += first_width;
    }
    size_t name_length = parser->cursor - start;
    if (name_length >= MAX_CORE_NAME) {
        parse_error(parser, "native Core identifier is too long");
        return false;
    }
    memcpy(name, parser->source + start, name_length);
    name[name_length] = '\0';
    return true;
}

static const Binding *find_binding(
    const Parser *parser,
    const char *name
) {
    for (size_t index = parser->binding_count; index > 0; --index) {
        const Binding *binding = &parser->bindings[index - 1];
        if (strcmp(binding->name, name) == 0) return binding;
    }
    return NULL;
}

static bool add_binding(
    Parser *parser,
    const char *name,
    ValueKind value_kind,
    ValueKind element_kind,
    size_t item_count,
    int64_t value,
    bool value_known,
    size_t slot,
    bool parameter
) {
    if (parser->binding_count >= MAX_CORE_BINDINGS + 2) {
        parse_error(parser, "native Core has too many bindings");
        return false;
    }
    Binding *binding = &parser->bindings[parser->binding_count++];
    memcpy(binding->name, name, strlen(name) + 1);
    binding->value_kind = value_kind;
    binding->element_kind = element_kind;
    binding->item_count = item_count;
    binding->value = value;
    binding->value_known = value_known;
    binding->known_collection = NULL;
    binding->slot = slot;
    binding->parameter = parameter;
    return true;
}

static Node *parse_lambda(Parser *parser, size_t parameter_count) {
    if (!consume_word(parser, "fn") || !consume_char(parser, '(')) {
        parse_error(parser, "expected native Core `fn(...) =>` lambda");
        return NULL;
    }
    char names[2][MAX_CORE_NAME] = {{0}};
    for (size_t index = 0; index < parameter_count; ++index) {
        if (!parse_identifier(parser, names[index])) {
            parse_error(parser, "expected lambda parameter name");
            return NULL;
        }
        if (consume_char(parser, ':') &&
            !consume_word(parser, "Int")) {
            parse_error(parser, "native Core lambda parameters must be Int");
            return NULL;
        }
        if (index + 1 < parameter_count && !consume_char(parser, ',')) {
            parse_error(parser, "expected `,` between lambda parameters");
            return NULL;
        }
    }
    if (!consume_char(parser, ')')) {
        parse_error(parser, "expected `)` after lambda parameters");
        return NULL;
    }
    skip_trivia(parser);
    if (parser->source[parser->cursor] != '=' ||
        parser->source[parser->cursor + 1] != '>') {
        parse_error(parser, "expected `=>` after lambda parameters");
        return NULL;
    }
    parser->cursor += 2;

    size_t outer_count = parser->binding_count;
    if (parameter_count > parser->max_lambda_parameters) {
        parser->max_lambda_parameters = parameter_count;
    }
    for (size_t index = 0; index < parameter_count; ++index) {
        if (!add_binding(
                parser,
                names[index],
                VALUE_INT,
                VALUE_INT,
                0,
                0,
                false,
                parser->local_count + index,
                true)) {
            parser->binding_count = outer_count;
            return NULL;
        }
    }
    Node *body = parse_expression(parser);
    parser->binding_count = outer_count;
    return body;
}

static bool contains_higher_order(const Node *expression) {
    if (expression == NULL) return false;
    if (expression->kind == NODE_MAP ||
        expression->kind == NODE_FILTER ||
        expression->kind == NODE_FOLD) {
        return true;
    }
    if (contains_higher_order(expression->left) ||
        contains_higher_order(expression->right) ||
        contains_higher_order(expression->third)) {
        return true;
    }
    for (size_t index = 0;
         expression->items != NULL && index < expression->item_count;
         ++index) {
        if (contains_higher_order(expression->items[index])) return true;
    }
    return false;
}

static Node *parse_higher_order(
    Parser *parser,
    NodeKind kind,
    size_t call_at
) {
    if (!consume_char(parser, '(')) {
        parse_error(parser, "expected `(` after List operation");
        return NULL;
    }
    Node *list = parse_expression(parser);
    if (!consume_char(parser, ',')) {
        parse_error(parser, "expected `,` after List argument");
        return list;
    }
    Node *initial = NULL;
    size_t parameters = 1;
    if (kind == NODE_FOLD) {
        initial = parse_expression(parser);
        if (!consume_char(parser, ',')) {
            parse_error(parser, "expected `,` before fold lambda");
            return list;
        }
        parameters = 2;
    }
    Node *lambda = parse_lambda(parser, parameters);
    if (!consume_char(parser, ')')) {
        parse_error(parser, "expected `)` after List operation");
    }
    if (list == NULL ||
        list->value_kind != VALUE_LIST ||
        list->element_kind != VALUE_INT) {
        parse_error(parser, "native Core List operation requires List[Int]");
        return list;
    }
    if (kind == NODE_FOLD &&
        (initial == NULL || initial->value_kind != VALUE_INT)) {
        parse_error(parser, "native Core fold initial value must be Int");
        return list;
    }
    ValueKind expected =
        kind == NODE_FILTER ? VALUE_BOOL : VALUE_INT;
    if (lambda == NULL || lambda->value_kind != expected) {
        parse_error(
            parser,
            kind == NODE_FILTER
                ? "native Core filter lambda must return Bool"
                : "native Core map/fold lambda must return Int"
        );
        return list;
    }
    if (contains_higher_order(lambda)) {
        parse_error(
            parser,
            "native Core List lambdas cannot contain nested List operations"
        );
        return list;
    }

    Node *result = node(
        kind,
        kind == NODE_FOLD ? VALUE_INT : VALUE_LIST,
        0,
        false,
        source_line(parser->source, call_at),
        list,
        kind == NODE_FOLD ? initial : lambda
    );
    result->slot = parser->local_count;
    if (kind == NODE_FOLD) {
        result->third = lambda;
    } else {
        result->element_kind = VALUE_INT;
        result->item_count =
            kind == NODE_MAP ? list->item_count : 0;
    }
    return result;
}

static Node *parse_text_view(
    Parser *parser,
    NodeKind kind,
    size_t call_at
) {
    if (!consume_char(parser, '(')) {
        parse_error(parser, "expected `(` after Text view");
        return NULL;
    }
    Node *value = parse_expression(parser);
    if (!consume_char(parser, ')')) {
        parse_error(parser, "expected `)` after Text view argument");
    }
    if (value == NULL || value->value_kind != VALUE_TEXT) {
        parse_error(parser, "Text view argument must be Text");
        return value;
    }

    Node *list = node(
        kind,
        VALUE_LIST,
        0,
        value->value_known,
        source_line(parser->source, call_at),
        value,
        NULL
    );
    list->element_kind =
        kind == NODE_BYTES ? VALUE_INT : VALUE_TEXT;
    if (kind == NODE_BYTES) {
        list->item_count = value->text_length;
    } else if (kind == NODE_CODEPOINTS) {
        list->item_count = value->text_codepoints;
    } else {
        list->item_count = value->text_graphemes;
    }
    list->items = allocate(
        list->item_count * sizeof(*list->items)
    );

    for (size_t index = 0; index < list->item_count; ++index) {
        if (kind == NODE_BYTES) {
            list->items[index] = node(
                NODE_LITERAL,
                VALUE_INT,
                value->text_value[index],
                true,
                source_line(parser->source, call_at),
                NULL,
                NULL
            );
            continue;
        }

        size_t byte_at = 0;
        size_t width = 0;
        bool found = kind == NODE_CODEPOINTS
            ? kofun_unicode_codepoint_at(
                value->text_value,
                value->text_length,
                index,
                &byte_at,
                &width
            )
            : kofun_unicode_grapheme_at(
                value->text_value,
                value->text_length,
                index,
                &byte_at,
                &width
            );
        if (!found) fatal("validated Text view became invalid");
        size_t codepoints = 0;
        size_t graphemes = 0;
        if (!kofun_unicode_codepoint_count(
                value->text_value + byte_at,
                width,
                &codepoints) ||
            !kofun_unicode_grapheme_count(
                value->text_value + byte_at,
                width,
                &graphemes)) {
            fatal("validated Text view became invalid");
        }
        list->items[index] = text_node(
            NODE_TEXT_LITERAL,
            value->text_value + byte_at,
            width,
            codepoints,
            graphemes,
            source_line(parser->source, call_at),
            NULL,
            NULL
        );
    }
    return list;
}

static Node *parse_atom(Parser *parser) {
    skip_trivia(parser);
    if (consume_char(parser, '(')) {
        Node *inside = parse_expression(parser);
        if (!consume_char(parser, ')')) {
            parse_error(parser, "expected `)` in Core expression");
        }
        return inside;
    }

    skip_trivia(parser);
    size_t literal_at = parser->cursor;
    if (parser->source[parser->cursor] == '"') {
        ++parser->cursor;
        return parse_text_literal(parser, literal_at);
    }

    if (consume_char(parser, '[')) {
        Node **items = NULL;
        size_t length = 0;
        size_t capacity = 0;
        ValueKind element_kind = VALUE_INT;
        skip_trivia(parser);
        if (!consume_char(parser, ']')) {
            for (;;) {
                Node *item = parse_expression(parser);
                if (item == NULL || parser->error != NULL) break;
                if (item->value_kind != VALUE_INT &&
                    item->value_kind != VALUE_TEXT) {
                    parse_error(
                        parser,
                        "native Core lists require Int or Text elements"
                    );
                    break;
                }
                if (length == 0) {
                    element_kind = item->value_kind;
                } else if (item->value_kind != element_kind) {
                    parse_error(
                        parser,
                        "native Core list elements must have one type"
                    );
                    break;
                }
                if (length == capacity) {
                    capacity = capacity == 0 ? 4 : capacity * 2;
                    Node **grown = realloc(items, capacity * sizeof(*items));
                    if (grown == NULL) fatal("out of memory");
                    items = grown;
                }
                items[length++] = item;
                if (consume_char(parser, ']')) break;
                if (!consume_char(parser, ',')) {
                    parse_error(parser, "expected `,` or `]` in List[Int]");
                    break;
                }
                if (consume_char(parser, ']')) break;
            }
        }
        Node *list = node(
            NODE_LIST,
            VALUE_LIST,
            0,
            true,
            source_line(parser->source, literal_at),
            NULL,
            NULL
        );
        list->items = items;
        list->item_count = length;
        list->element_kind = element_kind;
        return list;
    }

    skip_trivia(parser);
    if (consume_word(parser, "map")) {
        return parse_higher_order(
            parser,
            NODE_MAP,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "filter")) {
        return parse_higher_order(
            parser,
            NODE_FILTER,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "fold")) {
        return parse_higher_order(
            parser,
            NODE_FOLD,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "chars")) {
        return parse_text_view(
            parser,
            NODE_CHARS,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "codepoints")) {
        return parse_text_view(
            parser,
            NODE_CODEPOINTS,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "bytes")) {
        return parse_text_view(
            parser,
            NODE_BYTES,
            literal_at
        );
    }

    skip_trivia(parser);
    if (consume_word(parser, "len")) {
        if (!consume_char(parser, '(')) {
            parse_error(parser, "expected `(` after `len`");
            return NULL;
        }
        Node *value = parse_expression(parser);
        if (!consume_char(parser, ')')) {
            parse_error(parser, "expected `)` after `len` argument");
        }
        if (value != NULL &&
            value->value_kind != VALUE_LIST &&
            value->value_kind != VALUE_TEXT) {
            parse_error(
                parser,
                "`len` native Core argument must be List or Text"
            );
        }
        return node(
            NODE_LENGTH,
            VALUE_INT,
            value == NULL
                ? 0
                : (int64_t)(
                    value->value_kind == VALUE_TEXT
                        ? value->text_graphemes
                        : value->item_count
                ),
            value != NULL && value->value_known,
            source_line(parser->source, literal_at),
            value,
            NULL
        );
    }

    skip_trivia(parser);
    if (identifier_start_at(
            parser->source,
            strlen(parser->source),
            parser->cursor,
            NULL)) {
        char name[MAX_CORE_NAME];
        if (!parse_identifier(parser, name)) return NULL;
        const Binding *binding = find_binding(parser, name);
        if (binding == NULL) {
            parse_error(parser, "unknown native Core binding");
            return NULL;
        }
        Node *variable = node(
            binding->parameter ? NODE_PARAMETER : NODE_VARIABLE,
            binding->value_kind,
            binding->value,
            binding->value_known,
            source_line(parser->source, literal_at),
            NULL,
            NULL
        );
        variable->element_kind = binding->element_kind;
        variable->item_count = binding->item_count;
        variable->known_collection = binding->known_collection;
        variable->slot = binding->slot;
        return variable;
    }

    skip_trivia(parser);
    if (!isdigit((unsigned char)parser->source[parser->cursor])) {
        parse_error(
            parser,
            "expected integer, binding, Text, List, or Core call"
        );
        return NULL;
    }

    uint64_t value = 0;
    while (isdigit((unsigned char)parser->source[parser->cursor])) {
        unsigned digit =
            (unsigned)(parser->source[parser->cursor++] - '0');
        if (value > (UINT64_C(65535) - digit) / 10) {
            parse_error(parser, "Core literal exceeds 65535");
            return NULL;
        }
        value = value * 10 + digit;
    }
    return node(
        NODE_LITERAL,
        VALUE_INT,
        (int64_t)value,
        true,
        source_line(parser->source, literal_at),
        NULL,
        NULL
    );
}

static Node *parse_primary(Parser *parser) {
    Node *value = parse_atom(parser);
    while (value != NULL && parser->error == NULL) {
        skip_trivia(parser);
        if (!consume_char(parser, '[')) break;
        size_t index_at = parser->cursor - 1;
        Node *index = parse_expression(parser);
        if (!consume_char(parser, ']')) {
            parse_error(parser, "expected `]` after native Core index");
            return value;
        }
        if ((value->value_kind != VALUE_LIST &&
             value->value_kind != VALUE_TEXT) ||
            index == NULL ||
            index->value_kind != VALUE_INT) {
            parse_error(parser, "native Core indexing requires List or Text");
            return value;
        }

        int64_t resolved = 0;
        uint8_t *resolved_text = NULL;
        size_t resolved_text_length = 0;
        const Node *known_collection =
            value->value_kind == VALUE_LIST
                ? (value->value_known ? value : value->known_collection)
                : NULL;
        size_t target_length =
            value->value_kind == VALUE_TEXT
                ? value->text_graphemes
                : known_collection == NULL
                    ? value->item_count
                    : known_collection->item_count;
        ValueKind result_kind =
            value->value_kind == VALUE_TEXT
                ? VALUE_TEXT
                : value->element_kind;
        bool known =
            index->value_known &&
            (value->value_kind == VALUE_TEXT
                ? value->value_known
                : known_collection != NULL);
        if (known) {
            int64_t wanted = index->value;
            if (wanted < 0) wanted += (int64_t)target_length;
            if (wanted < 0 || (uint64_t)wanted >= target_length) {
                known = false;
            } else if (value->value_kind == VALUE_TEXT) {
                size_t byte_at = 0;
                if (!kofun_unicode_grapheme_at(
                        value->text_value,
                        value->text_length,
                        (size_t)wanted,
                        &byte_at,
                        &resolved_text_length)) {
                    fatal("validated Text became invalid");
                }
                resolved_text = copy_bytes(
                    value->text_value + byte_at,
                    resolved_text_length
                );
            } else {
                Node *item = known_collection->items[(size_t)wanted];
                known = item->value_known;
                if (result_kind == VALUE_TEXT) {
                    resolved_text_length = item->text_length;
                    resolved_text = copy_bytes(
                        item->text_value,
                        item->text_length
                    );
                } else {
                    resolved = item->value;
                }
            }
        }
        Node *indexed = node(
            NODE_INDEX,
            result_kind,
            resolved,
            known,
            source_line(parser->source, index_at),
            value,
            index
        );
        if (known && result_kind == VALUE_TEXT) {
            indexed->text_value = resolved_text;
            indexed->text_length = resolved_text_length;
            if (!kofun_unicode_codepoint_count(
                    resolved_text,
                    resolved_text_length,
                    &indexed->text_codepoints) ||
                !kofun_unicode_grapheme_count(
                    resolved_text,
                    resolved_text_length,
                    &indexed->text_graphemes)) {
                fatal("validated indexed Text became invalid");
            }
        } else {
            free(resolved_text);
        }
        value = indexed;
    }
    return value;
}

static Node *parse_unary(Parser *parser) {
    skip_trivia(parser);
    size_t operator_at = parser->cursor;
    if (consume_char(parser, '-')) {
        Node *operand = parse_unary(parser);
        if (operand == NULL || operand->value_kind != VALUE_INT) {
            parse_error(parser, "native Core unary `-` requires Int");
            return operand;
        }
        return node(
            NODE_NEGATE,
            VALUE_INT,
            operand->value_known ? -operand->value : 0,
            operand->value_known,
            source_line(parser->source, operator_at),
            operand,
            NULL
        );
    }
    return parse_primary(parser);
}

static bool checked_value(
    Parser *parser,
    NodeKind kind,
    int64_t left,
    int64_t right,
    int64_t *result
) {
    if (left < 0 || right < 0) {
        parse_error(parser, "Core arithmetic requires non-negative operands");
        return false;
    }
    if (kind == NODE_ADD) {
        if ((uint64_t)left > UINT64_C(65535) - (uint64_t)right) {
            parse_error(parser, "Core addition exceeds 65535");
            return false;
        }
        *result = left + right;
        return true;
    }
    if (right != 0 &&
        (uint64_t)left > UINT64_C(65535) / (uint64_t)right) {
        parse_error(parser, "Core multiplication exceeds 65535");
        return false;
    }
    *result = left * right;
    return true;
}

static Node *parse_product(Parser *parser) {
    Node *left = parse_unary(parser);
    while (parser->error == NULL) {
        skip_trivia(parser);
        if (parser->source[parser->cursor] != '*') break;
        size_t operator_at = parser->cursor;
        ++parser->cursor;
        Node *right = parse_unary(parser);
        if (right == NULL) return left;
        if (left->value_kind != VALUE_INT ||
            right->value_kind != VALUE_INT) {
            parse_error(parser, "operator `*` requires Int operands");
            return left;
        }
        int64_t value = 0;
        if (!checked_value(
                parser, NODE_MULTIPLY, left->value, right->value, &value)) {
            return left;
        }
        left = node(
            NODE_MULTIPLY,
            VALUE_INT,
            value,
            left->value_known && right->value_known,
            source_line(parser->source, operator_at),
            left,
            right
        );
    }
    return left;
}

static Node *parse_sum(Parser *parser) {
    Node *left = parse_product(parser);
    while (parser->error == NULL) {
        skip_trivia(parser);
        if (parser->source[parser->cursor] != '+') break;
        size_t operator_at = parser->cursor;
        ++parser->cursor;
        Node *right = parse_product(parser);
        if (right == NULL) return left;
        if (left->value_kind == VALUE_TEXT &&
            right->value_kind == VALUE_TEXT) {
            if (left->text_length > SIZE_MAX - right->text_length) {
                fatal("Text concatenation is too large");
            }
            size_t length = left->text_length + right->text_length;
            uint8_t *joined = allocate(length);
            if (left->text_length > 0) {
                memcpy(joined, left->text_value, left->text_length);
            }
            if (right->text_length > 0) {
                memcpy(
                    joined + left->text_length,
                    right->text_value,
                    right->text_length
                );
            }
            Node *combined = text_node(
                NODE_TEXT_CONCAT,
                joined,
                length,
                left->text_codepoints + right->text_codepoints,
                0,
                source_line(parser->source, operator_at),
                left,
                right
            );
            combined->value_known =
                left->value_known && right->value_known;
            if (!kofun_unicode_grapheme_count(
                    joined,
                    length,
                    &combined->text_graphemes)) {
                fatal("validated concatenated Text became invalid");
            }
            free(joined);
            left = combined;
            continue;
        }
        if (left->value_kind != VALUE_INT ||
            right->value_kind != VALUE_INT) {
            parse_error(
                parser,
                "operator `+` requires two Int or two Text operands"
            );
            return left;
        }
        int64_t value = 0;
        if (!checked_value(
                parser, NODE_ADD, left->value, right->value, &value)) {
            return left;
        }
        left = node(
            NODE_ADD,
            VALUE_INT,
            value,
            left->value_known && right->value_known,
            source_line(parser->source, operator_at),
            left,
            right
        );
    }
    return left;
}

static Node *parse_expression(Parser *parser) {
    Node *left = parse_sum(parser);
    while (parser->error == NULL) {
        skip_trivia(parser);
        size_t operator_at = parser->cursor;
        char first = parser->source[parser->cursor];
        char second = parser->source[parser->cursor + 1];
        bool equal = first == '=' && second == '=';
        bool not_equal = first == '!' && second == '=';
        bool less_equal = first == '<' && second == '=';
        bool greater_equal = first == '>' && second == '=';
        bool less = first == '<' && !less_equal;
        bool greater = first == '>' && !greater_equal;
        if (!equal && !not_equal && !less_equal &&
            !greater_equal && !less && !greater) {
            break;
        }
        parser->cursor +=
            equal || not_equal || less_equal || greater_equal ? 2 : 1;
        Node *right = parse_sum(parser);
        if (right == NULL) return left;
        bool known = left->value_known && right->value_known;
        bool result = false;
        NodeKind kind;
        if (left->value_kind == VALUE_TEXT &&
            right->value_kind == VALUE_TEXT &&
            (equal || not_equal)) {
            kind = equal ? NODE_TEXT_EQUAL : NODE_TEXT_NOT_EQUAL;
            if (known) {
                bool same =
                    left->text_length == right->text_length &&
                    memcmp(
                        left->text_value,
                        right->text_value,
                        left->text_length
                    ) == 0;
                result = equal ? same : !same;
            }
        } else if (left->value_kind == VALUE_INT &&
                   right->value_kind == VALUE_INT) {
            if (equal) kind = NODE_INT_EQUAL;
            else if (not_equal) kind = NODE_INT_NOT_EQUAL;
            else if (less) kind = NODE_INT_LESS;
            else if (less_equal) kind = NODE_INT_LESS_EQUAL;
            else if (greater) kind = NODE_INT_GREATER;
            else kind = NODE_INT_GREATER_EQUAL;
            if (known) {
                if (equal) result = left->value == right->value;
                else if (not_equal) result = left->value != right->value;
                else if (less) result = left->value < right->value;
                else if (less_equal) result = left->value <= right->value;
                else if (greater) result = left->value > right->value;
                else result = left->value >= right->value;
            }
        } else {
            parse_error(
                parser,
                "native Core comparison requires matching Int or Text"
            );
            return left;
        }
        left = node(
            kind,
            VALUE_BOOL,
            result,
            known,
            source_line(parser->source, operator_at),
            left,
            right
        );
    }
    return left;
}

static Node *parse_program(Parser *parser) {
    Node *initializers[MAX_CORE_BINDINGS] = {0};
    size_t let_count = 0;
    skip_trivia(parser);
    parser->main_line = source_line(parser->source, parser->cursor);
    if (!consume_word(parser, "fn") ||
        !consume_word(parser, "main") ||
        !consume_char(parser, '(') ||
        !consume_char(parser, ')') ||
        !consume_char(parser, '{')) {
        parse_error(
            parser,
            "native Core requires `fn main() { print(EXPRESSION) }`"
        );
        return NULL;
    }

    while (consume_word(parser, "let")) {
        char name[MAX_CORE_NAME];
        if (!parse_identifier(parser, name)) {
            parse_error(parser, "expected binding name after `let`");
            return NULL;
        }
        if (find_binding(parser, name) != NULL) {
            parse_error(parser, "duplicate native Core binding");
            return NULL;
        }
        if (!consume_char(parser, '=')) {
            parse_error(parser, "expected `=` after binding name");
            return NULL;
        }
        Node *initializer = parse_expression(parser);
        if (initializer == NULL) return NULL;
        if (initializer->value_kind != VALUE_INT &&
            !(initializer->value_kind == VALUE_LIST &&
              initializer->element_kind == VALUE_INT)) {
            parse_error(
                parser,
                "native Core bindings currently require Int or List[Int]"
            );
            return initializer;
        }
        if (let_count >= MAX_CORE_BINDINGS) {
            parse_error(parser, "native Core has too many let bindings");
            return initializer;
        }
        size_t slot = parser->local_count++;
        if (!add_binding(
                parser,
                name,
                initializer->value_kind,
                initializer->element_kind,
                initializer->item_count,
                initializer->value,
                initializer->value_kind == VALUE_INT &&
                    initializer->value_known,
                slot,
                false)) {
            return initializer;
        }
        if (initializer->value_kind == VALUE_LIST) {
            Binding *binding = &parser->bindings[parser->binding_count - 1];
            binding->known_collection =
                initializer->value_known
                    ? initializer
                    : initializer->known_collection;
        }
        initializers[let_count++] = initializer;
    }

    skip_trivia(parser);
    parser->print_line = source_line(parser->source, parser->cursor);
    if (!consume_word(parser, "print") || !consume_char(parser, '(')) {
        parse_error(
            parser,
            "native Core requires `fn main() { print(EXPRESSION) }`"
        );
        for (size_t index = 0; index < let_count; ++index) {
            free_node(initializers[index]);
        }
        return NULL;
    }

    Node *expression = parse_expression(parser);
    if (!consume_char(parser, ')') || !consume_char(parser, '}')) {
        parse_error(
            parser,
            "native Core requires exactly one print expression"
        );
        return expression;
    }
    skip_trivia(parser);
    if (parser->source[parser->cursor] != '\0') {
        parse_error(parser, "unexpected source after native Core main");
    }
    if (expression != NULL &&
        expression->value_kind != VALUE_INT &&
        expression->value_kind != VALUE_BOOL &&
        expression->value_kind != VALUE_TEXT) {
        parse_error(
            parser,
            "native Core print expression must produce Int, Bool, or Text"
        );
    } else if (expression != NULL &&
        expression->value_kind == VALUE_INT &&
        expression->value_known &&
        (expression->value < 10 || expression->value > 99)) {
        parse_error(parser, "native Core print result must be 10..99");
    }
    for (size_t index = let_count; index > 0; --index) {
        Node *body = expression;
        Node *let = node(
            NODE_LET,
            body == NULL ? VALUE_INT : body->value_kind,
            body == NULL ? 0 : body->value,
            body != NULL && body->value_known,
            initializers[index - 1]->source_line,
            initializers[index - 1],
            body
        );
        let->element_kind =
            body == NULL ? VALUE_INT : body->element_kind;
        let->item_count = body == NULL ? 0 : body->item_count;
        let->slot = index - 1;
        expression = let;
    }
    return expression;
}

static void function_skip_trivia(FunctionParser *parser) {
    for (;;) {
        while (parser->cursor < parser->limit &&
               isspace((unsigned char)parser->source[parser->cursor])) {
            ++parser->cursor;
        }
        if (parser->cursor >= parser->limit ||
            parser->source[parser->cursor] != '#') {
            return;
        }
        while (parser->cursor < parser->limit &&
               parser->source[parser->cursor] != '\n') {
            ++parser->cursor;
        }
    }
}

static void function_error(
    FunctionParser *parser,
    const char *format,
    ...
) {
    if (parser->error[0] != '\0') return;
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(
        parser->error,
        sizeof(parser->error),
        format,
        arguments
    );
    va_end(arguments);
}

static bool function_consume_word(
    FunctionParser *parser,
    const char *word
) {
    function_skip_trivia(parser);
    size_t length = strlen(word);
    if (parser->cursor > parser->limit ||
        parser->limit - parser->cursor < length ||
        strncmp(parser->source + parser->cursor, word, length) != 0 ||
        (parser->cursor + length < parser->limit &&
         identifier_continue_at(
             parser->source,
             parser->limit,
             parser->cursor + length,
             NULL))) {
        return false;
    }
    parser->cursor += length;
    return true;
}

static bool function_consume_char(
    FunctionParser *parser,
    char wanted
) {
    function_skip_trivia(parser);
    if (parser->cursor >= parser->limit ||
        parser->source[parser->cursor] != wanted) {
        return false;
    }
    ++parser->cursor;
    return true;
}

/* Look without consuming. A labelled parameter head is only distinguishable
 * from an unlabelled one by what follows the first name, so the decision has to
 * be made before anything is taken. */
static bool function_peek_char(
    FunctionParser *parser,
    char wanted
) {
    function_skip_trivia(parser);
    return parser->cursor < parser->limit &&
        parser->source[parser->cursor] == wanted;
}

static bool function_consume_pair(
    FunctionParser *parser,
    char first,
    char second
) {
    function_skip_trivia(parser);
    if (parser->cursor + 1 >= parser->limit ||
        parser->source[parser->cursor] != first ||
        parser->source[parser->cursor + 1] != second) {
        return false;
    }
    parser->cursor += 2;
    return true;
}

static bool function_identifier(
    FunctionParser *parser,
    char name[MAX_CORE_NAME]
) {
    function_skip_trivia(parser);
    size_t width = 0;
    if (!identifier_start_at(
            parser->source,
            parser->limit,
            parser->cursor,
            &width)) {
        return false;
    }
    size_t start = parser->cursor;
    parser->cursor += width;
    while (identifier_continue_at(
            parser->source,
            parser->limit,
            parser->cursor,
            &width)) {
        parser->cursor += width;
    }
    size_t length = parser->cursor - start;
    if (length >= MAX_CORE_NAME) {
        function_error(parser, "native Core function name is too long");
        return false;
    }
    memcpy(name, parser->source + start, length);
    name[length] = '\0';
    return true;
}

static size_t function_find(
    const FunctionProgram *program,
    const char *name
) {
    for (size_t index = 0; index < program->function_count; ++index) {
        if (strcmp(program->functions[index].name, name) == 0) {
            return index;
        }
    }
    return SIZE_MAX;
}

static size_t function_parameter_find(
    const FunctionDeclaration *function,
    const char *name
) {
    for (size_t index = 0; index < function->parameter_count; ++index) {
        if (strcmp(function->parameters[index], name) == 0) {
            return index;
        }
    }
    return SIZE_MAX;
}

/* The declaration slot carrying `label`, or SIZE_MAX. Separate from
 * `function_parameter_find` on purpose: an internal name is not a label, and
 * accepting one here would let a call spell a binding the callee owns. */
static size_t function_label_find(
    const FunctionDeclaration *function,
    const char *label
) {
    for (size_t index = 0; index < function->parameter_count; ++index) {
        if (function->parameter_labels[index][0] != '\0' &&
            strcmp(function->parameter_labels[index], label) == 0) {
            return index;
        }
    }
    return SIZE_MAX;
}

static size_t function_local_find(
    const FunctionDeclaration *function,
    const char *name
) {
    for (size_t index = function->local_count; index > 0; --index) {
        if (strcmp(function->locals[index - 1], name) == 0) {
            return index - 1;
        }
    }
    return SIZE_MAX;
}

static bool function_binding_find(
    const FunctionDeclaration *function,
    const char *name,
    size_t *slot,
    FunctionValueKind *value_kind
) {
    size_t local = function_local_find(function, name);
    if (local != SIZE_MAX) {
        *slot = function->parameter_count + local;
        *value_kind = function->local_types[local];
        return true;
    }
    size_t parameter = function_parameter_find(function, name);
    if (parameter == SIZE_MAX) return false;
    *slot = parameter;
    *value_kind = function->parameter_types[parameter];
    return true;
}

static const char *function_type_name(FunctionValueKind kind) {
    if (kind == FUNCTION_VALUE_TEXT) return "Text";
    if (kind == FUNCTION_VALUE_BOOL) return "Bool";
    return "Int";
}

static bool function_parse_type(
    FunctionParser *parser,
    FunctionValueKind *kind
) {
    if (function_consume_word(parser, "Int")) {
        *kind = FUNCTION_VALUE_INT;
        return true;
    }
    if (function_consume_word(parser, "Text")) {
        *kind = FUNCTION_VALUE_TEXT;
        return true;
    }
    if (function_consume_word(parser, "List")) {
        function_error(
            parser,
            "native Core function List parameter/result types are unsupported"
        );
        return false;
    }
    return false;
}

static bool function_body_end(
    FunctionParser *parser,
    size_t *body_end
) {
    size_t depth = 1;
    bool in_text = false;
    bool escaped = false;
    while (parser->cursor < parser->limit) {
        char value = parser->source[parser->cursor++];
        if (in_text) {
            if (escaped) {
                escaped = false;
            } else if (value == '\\') {
                escaped = true;
            } else if (value == '"') {
                in_text = false;
            }
            continue;
        }
        if (value == '"') {
            in_text = true;
            continue;
        }
        if (value == '#') {
            while (parser->cursor < parser->limit &&
                   parser->source[parser->cursor] != '\n') {
                ++parser->cursor;
            }
            continue;
        }
        if (value == '{') {
            ++depth;
        } else if (value == '}') {
            --depth;
            if (depth == 0) {
                *body_end = parser->cursor - 1;
                return true;
            }
        }
    }
    function_error(parser, "unterminated native Core function body");
    return false;
}

static void function_expression_free(FunctionExpression *expression) {
    if (expression == NULL) return;
    function_expression_free(expression->left);
    function_expression_free(expression->right);
    for (size_t index = 0; index < expression->argument_count; ++index) {
        function_expression_free(expression->arguments[index]);
    }
    free(expression->arguments);
    free(expression->text_value);
    free(expression);
}

static void function_program_free(FunctionProgram *program) {
    for (size_t function_index = 0;
         function_index < program->function_count;
         ++function_index) {
        FunctionDeclaration *function =
            &program->functions[function_index];
        for (size_t statement_index = 0;
             statement_index < function->statement_count;
             ++statement_index) {
            FunctionStatement *statement =
                &function->statements[statement_index];
            function_expression_free(statement->condition);
            function_expression_free(statement->value);
        }
        function->statement_count = 0;
    }
    program->function_count = 0;
}

static bool function_headers(
    const char *source,
    FunctionProgram *program,
    char error[256],
    size_t *error_at
) {
    memset(program, 0, sizeof(*program));
    program->source = source;
    program->main_index = SIZE_MAX;
    FunctionParser parser = {
        .source = source,
        .cursor = 0,
        .limit = strlen(source),
    };

    while (true) {
        function_skip_trivia(&parser);
        if (parser.cursor >= parser.limit) break;
        if (program->function_count >= MAX_CORE_FUNCTIONS) {
            function_error(
                &parser,
                "native Core has too many functions"
            );
            break;
        }
        size_t declaration_at = parser.cursor;
        if (!function_consume_word(&parser, "fn")) {
            function_error(
                &parser,
                "expected top-level native Core function"
            );
            break;
        }

        FunctionDeclaration *function =
            &program->functions[program->function_count];
        function->declaration_line = source_line(source, declaration_at);
        if (!function_identifier(&parser, function->name)) {
            function_error(&parser, "expected native Core function name");
            break;
        }
        if (function_find(program, function->name) != SIZE_MAX) {
            function_error(
                &parser,
                "duplicate native Core function `%s`",
                function->name
            );
            break;
        }
        /*
         * A call site resolves the intrinsics before it looks for a declared
         * function, so a definition under one of those names would be
         * unreachable and its calls would silently mean the syscall instead.
         * Refuse the definition rather than let the two readings disagree.
         */
        if (function_syscall_arity(function->name, NULL)) {
            function_error(
                &parser,
                "native Core cannot define the intrinsic `%s`",
                function->name
            );
            break;
        }
        if (!function_consume_char(&parser, '(')) {
            function_error(
                &parser,
                "expected `(` after native Core function name"
            );
            break;
        }
        function_skip_trivia(&parser);
        if (!function_consume_char(&parser, ')')) {
            for (;;) {
                if (function->parameter_count >= MAX_CORE_PARAMETERS) {
                    function_error(
                        &parser,
                        "native Core functions support at most six arguments"
                    );
                    break;
                }
                char *parameter =
                    function->parameters[function->parameter_count];
                char *label =
                    function->parameter_labels[function->parameter_count];
                label[0] = '\0';
                if (!function_identifier(&parser, parameter)) {
                    function_error(
                        &parser,
                        "expected native Core parameter name"
                    );
                    break;
                }
                /*
                 * `external internal: Type` — two names before the colon. The
                 * first is the call-site label and the second is what the body
                 * binds, so the label is moved aside and `parameter` keeps the
                 * internal name. One name is the unlabelled form and stays
                 * exactly as it was.
                 */
                function_skip_trivia(&parser);
                if (!function_peek_char(&parser, ':')) {
                    char internal[MAX_CORE_NAME];
                    if (function_identifier(&parser, internal)) {
                        memcpy(label, parameter, MAX_CORE_NAME);
                        memcpy(parameter, internal, MAX_CORE_NAME);
                    }
                }
                if (function_parameter_find(function, parameter) !=
                    SIZE_MAX) {
                    function_error(
                        &parser,
                        "duplicate native Core parameter `%s`",
                        parameter
                    );
                    break;
                }
                if (!function_consume_char(&parser, ':')) {
                    function_error(
                        &parser,
                        "native Core function parameter requires a type"
                    );
                    break;
                }
                FunctionValueKind parameter_type;
                if (!function_parse_type(&parser, &parameter_type)) {
                    if (parser.error[0] == '\0') {
                        function_error(
                            &parser,
                            "native Core function parameters require Int or Text"
                        );
                    }
                    break;
                }
                function->parameter_types[
                    function->parameter_count
                ] = parameter_type;
                ++function->parameter_count;
                if (function_consume_char(&parser, ')')) break;
                if (!function_consume_char(&parser, ',')) {
                    function_error(
                        &parser,
                        "expected `,` between native Core parameters"
                    );
                    break;
                }
            }
        }
        if (parser.error[0] != '\0') break;

        bool is_main = strcmp(function->name, "main") == 0;
        if (function_consume_pair(&parser, '-', '>')) {
            if (!function_parse_type(
                    &parser,
                    &function->result_kind)) {
                if (parser.error[0] != '\0') break;
                function_error(
                    &parser,
                    "native Core functions must return Int or Text"
                );
                break;
            }
            function->has_result = true;
        } else if (!is_main) {
            function_error(
                &parser,
                "native Core helper functions require `-> Int` or `-> Text`"
            );
            break;
        }
        if (!is_main) {
            bool text_profile =
                function->result_kind == FUNCTION_VALUE_TEXT;
            for (size_t index = 0;
                 index < function->parameter_count;
                 ++index) {
                if (function->parameter_types[index] ==
                    FUNCTION_VALUE_TEXT) {
                    text_profile = true;
                }
            }
            if (text_profile) {
                if (!function->has_result ||
                    function->result_kind != FUNCTION_VALUE_TEXT) {
                    function_error(
                        &parser,
                        "native Core Text helpers must return Text"
                    );
                    break;
                }
                if (function->parameter_count > 2) {
                    function_error(
                        &parser,
                        "native Core Text helpers support at most two arguments"
                    );
                    break;
                }
                for (size_t index = 0;
                     index < function->parameter_count;
                     ++index) {
                    if (function->parameter_types[index] !=
                        FUNCTION_VALUE_TEXT) {
                        function_error(
                            &parser,
                            "native Core Text helper parameters must have type Text"
                        );
                        break;
                    }
                }
                if (parser.error[0] != '\0') break;
            }
        }
        if (is_main && function->parameter_count != 0) {
            function_error(
                &parser,
                "native Core main must not accept arguments"
            );
            break;
        }
        if (!function_consume_char(&parser, '{')) {
            function_error(
                &parser,
                "expected `{` to start native Core function body"
            );
            break;
        }
        function->body_start = parser.cursor;
        if (!function_body_end(&parser, &function->body_end)) break;
        if (is_main) program->main_index = program->function_count;
        ++program->function_count;
    }

    if (parser.error[0] == '\0' && program->main_index == SIZE_MAX) {
        function_error(&parser, "native Core program has no main function");
    }
    if (parser.error[0] != '\0') {
        memcpy(error, parser.error, sizeof(parser.error));
        *error_at = parser.cursor;
        return false;
    }
    return true;
}

static FunctionExpression *function_expression(
    FunctionExpressionKind kind,
    FunctionValueKind value_kind,
    size_t line,
    FunctionExpression *left,
    FunctionExpression *right
) {
    FunctionExpression *expression = allocate(sizeof(*expression));
    expression->kind = kind;
    expression->value_kind = value_kind;
    expression->value = 0;
    expression->text_value = NULL;
    expression->text_length = 0;
    expression->source_line = line;
    expression->slot = 0;
    expression->function_index = 0;
    expression->left = left;
    expression->right = right;
    expression->arguments = NULL;
    expression->argument_count = 0;
    /* Every other field here is set explicitly rather than relying on the
     * allocator, and the source order is no exception. */
    for (size_t index = 0; index < MAX_CORE_PARAMETERS; ++index) {
        expression->argument_order[index] = index;
    }
    return expression;
}

static FunctionExpression *function_parse_expression(
    FunctionParser *parser
);

static FunctionExpression *function_parse_text_literal(
    FunctionParser *parser,
    size_t literal_at
) {
    function_skip_trivia(parser);
    if (parser->cursor >= parser->limit ||
        parser->source[parser->cursor] != '"') {
        return NULL;
    }
    ++parser->cursor;
    Bytes value;
    bytes_init(&value);
    bool closed = false;
    while (parser->cursor < parser->limit) {
        unsigned char current =
            (unsigned char)parser->source[parser->cursor++];
        if (current == '"') {
            closed = true;
            break;
        }
        if (current == '\\') {
            if (parser->cursor >= parser->limit) break;
            char escaped = parser->source[parser->cursor++];
            if (escaped == 'n') {
                current = '\n';
            } else if (escaped == 'r') {
                current = '\r';
            } else if (escaped == 't') {
                current = '\t';
            } else if (escaped == '"' || escaped == '\\') {
                current = (unsigned char)escaped;
            } else {
                function_error(
                    parser,
                    "unsupported Text escape in native Core function"
                );
                break;
            }
        }
        byte(&value, current);
    }
    if (!closed && parser->error[0] == '\0') {
        function_error(
            parser,
            "unterminated Text literal in native Core function"
        );
    }
    if (parser->error[0] != '\0') {
        free(value.data);
        return NULL;
    }
    FunctionExpression *literal = function_expression(
        FUNCTION_TEXT_LITERAL,
        FUNCTION_VALUE_TEXT,
        source_line(parser->source, literal_at),
        NULL,
        NULL
    );
    literal->text_value = value.data;
    literal->text_length = value.length;
    return literal;
}

static FunctionExpression *function_parse_atom(FunctionParser *parser) {
    function_skip_trivia(parser);
    size_t atom_at = parser->cursor;
    if (function_consume_char(parser, '(')) {
        FunctionExpression *inside = function_parse_expression(parser);
        if (!function_consume_char(parser, ')')) {
            function_error(
                parser,
                "expected `)` in native Core function expression"
            );
        }
        return inside;
    }

    function_skip_trivia(parser);
    if (parser->cursor < parser->limit &&
        parser->source[parser->cursor] == '"') {
        return function_parse_text_literal(parser, atom_at);
    }
    if (parser->cursor < parser->limit &&
        isdigit((unsigned char)parser->source[parser->cursor])) {
        uint64_t value = 0;
        while (parser->cursor < parser->limit &&
               isdigit((unsigned char)parser->source[parser->cursor])) {
            unsigned digit =
                (unsigned)(parser->source[parser->cursor++] - '0');
            /*
             * A literal is unsigned here: `-9223372036854775808` is a negation
             * applied to `9223372036854775808`, which does not fit, so the
             * bound is INT64_MAX and INT64_MIN is written the way the numeric
             * corpus writes it, `-9223372036854775807 - 1`.
             */
            if (value > ((uint64_t)INT64_MAX - digit) / 10) {
                function_error(
                    parser,
                    "native Core integer literal exceeds 9223372036854775807"
                );
                return NULL;
            }
            value = value * 10 + digit;
        }
        FunctionExpression *literal = function_expression(
            FUNCTION_LITERAL,
            FUNCTION_VALUE_INT,
            source_line(parser->source, atom_at),
            NULL,
            NULL
        );
        literal->value = (int64_t)value;
        return literal;
    }

    char name[MAX_CORE_NAME];
    if (!function_identifier(parser, name)) {
        function_error(
            parser,
            "expected Int expression in native Core function"
        );
        return NULL;
    }
    if (function_consume_char(parser, '(')) {
        size_t syscall_arity = 0;
        if (function_syscall_arity(name, &syscall_arity)) {
            FunctionExpression *intrinsic = function_expression(
                FUNCTION_SYSCALL,
                FUNCTION_VALUE_INT,
                source_line(parser->source, atom_at),
                NULL,
                NULL
            );
            size_t expected = syscall_arity + 1;
            intrinsic->arguments = allocate(
                expected * sizeof(*intrinsic->arguments)
            );
            function_skip_trivia(parser);
            if (!function_consume_char(parser, ')')) {
                for (;;) {
                    if (intrinsic->argument_count >= expected) {
                        function_error(
                            parser,
                            "native Core intrinsic `%s` expects %zu arguments",
                            name,
                            expected
                        );
                        return intrinsic;
                    }
                    FunctionExpression *argument =
                        function_parse_expression(parser);
                    if (argument == NULL) return intrinsic;
                    /* Stored before it is judged, so the refusal path owns it. */
                    intrinsic->arguments[intrinsic->argument_count++] = argument;
                    if (argument->value_kind != FUNCTION_VALUE_INT) {
                        function_error(
                            parser,
                            "native Core intrinsic `%s` argument %zu requires Int",
                            name,
                            intrinsic->argument_count
                        );
                        return intrinsic;
                    }
                    if (function_consume_char(parser, ')')) break;
                    if (!function_consume_char(parser, ',')) {
                        function_error(
                            parser,
                            "expected `,` between native Core arguments"
                        );
                        return intrinsic;
                    }
                }
            }
            if (intrinsic->argument_count != expected) {
                function_error(
                    parser,
                    "native Core intrinsic `%s` expects %zu arguments, got %zu",
                    name,
                    expected,
                    intrinsic->argument_count
                );
            }
            return intrinsic;
        }
        size_t target = function_find(parser->program, name);
        if (target == SIZE_MAX) {
            function_error(
                parser,
                "unknown native Core function `%s`",
                name
            );
            return NULL;
        }
        if (target == parser->program->main_index) {
            function_error(parser, "native Core main cannot be called");
            return NULL;
        }
        FunctionExpression *call = function_expression(
            FUNCTION_CALL,
            parser->program->functions[target].result_kind,
            source_line(parser->source, atom_at),
            NULL,
            NULL
        );
        if (!parser->program->functions[target].has_result) {
            function_error(
                parser,
                "native Core function `%s` has no result",
                name
            );
            return call;
        }
        call->function_index = target;
        size_t expected =
            parser->program->functions[target].parameter_count;
        if (expected > 0) {
            call->arguments = allocate(
                expected * sizeof(*call->arguments)
            );
            /* `allocate` is malloc, not calloc. A labelled call fills slots out
             * of order and asks "is this slot already taken?", so every slot
             * has to start empty — otherwise that question reads uninitialized
             * memory and a duplicate label is detected at random. */
            memset(
                call->arguments,
                0,
                expected * sizeof(*call->arguments)
            );
        }
        function_skip_trivia(parser);
        if (!function_consume_char(parser, ')')) {
            for (;;) {
                if (call->argument_count >= expected) {
                    function_error(
                        parser,
                        "native Core function `%s` expects %zu arguments",
                        name,
                        expected
                    );
                    return call;
                }
                /*
                 * `label: value` binds the slot the declaration gave that
                 * label; anything else takes the next free slot in order. The
                 * label is looked up in the callee's declaration, never used to
                 * choose the callee — labels do not participate in overload
                 * selection (call-arguments v1).
                 */
                size_t slot = call->argument_count;
                char label[MAX_CORE_NAME];
                size_t rewind = parser->cursor;
                if (function_identifier(parser, label) &&
                    function_peek_char(parser, ':')) {
                    (void)function_consume_char(parser, ':');
                    size_t labelled_slot = function_label_find(
                        &parser->program->functions[target],
                        label
                    );
                    if (labelled_slot == SIZE_MAX) {
                        function_error(
                            parser,
                            "native Core function `%s` has no parameter "
                            "labelled `%s`",
                            name,
                            label
                        );
                        return call;
                    }
                    if (call->arguments[labelled_slot] != NULL) {
                        function_error(
                            parser,
                            "duplicate call label `%s` for native Core "
                            "function `%s`",
                            label,
                            name
                        );
                        return call;
                    }
                    slot = labelled_slot;
                } else {
                    parser->cursor = rewind;
                    while (slot < expected &&
                           call->arguments[slot] != NULL) {
                        ++slot;
                    }
                    if (slot < expected &&
                        parser->program->functions[target]
                            .parameter_labels[slot][0] != '\0') {
                        function_error(
                            parser,
                            "native Core function `%s` parameter %zu requires "
                            "its label `%s`",
                            name,
                            slot + 1,
                            parser->program->functions[target]
                                .parameter_labels[slot]
                        );
                        return call;
                    }
                }
                FunctionExpression *argument =
                    function_parse_expression(parser);
                if (argument == NULL) return call;
                FunctionValueKind wanted =
                    parser->program->functions[target].parameter_types[slot];
                if (argument->value_kind != wanted) {
                    function_error(
                        parser,
                        "native Core function `%s` argument %zu requires %s",
                        name,
                        slot + 1,
                        function_type_name(wanted)
                    );
                    return call;
                }
                call->arguments[slot] = argument;
                call->argument_order[call->argument_count++] = slot;
                if (function_consume_char(parser, ')')) break;
                if (!function_consume_char(parser, ',')) {
                    function_error(
                        parser,
                        "expected `,` between native Core arguments"
                    );
                    return call;
                }
            }
        }
        if (call->argument_count != expected) {
            function_error(
                parser,
                "native Core function `%s` expects %zu arguments, got %zu",
                name,
                expected,
                call->argument_count
            );
        }
        return call;
    }

    size_t slot = 0;
    FunctionValueKind value_kind = FUNCTION_VALUE_INT;
    if (!function_binding_find(
            parser->function,
            name,
            &slot,
            &value_kind)) {
        function_error(parser, "unknown native Core binding `%s`", name);
        return NULL;
    }
    FunctionExpression *binding = function_expression(
        FUNCTION_PARAMETER,
        value_kind,
        source_line(parser->source, atom_at),
        NULL,
        NULL
    );
    binding->slot = slot;
    return binding;
}

static FunctionExpression *function_parse_unary(FunctionParser *parser) {
    function_skip_trivia(parser);
    size_t operator_at = parser->cursor;
    if (function_consume_char(parser, '-')) {
        FunctionExpression *value = function_parse_unary(parser);
        if (value != NULL &&
            value->value_kind != FUNCTION_VALUE_INT) {
            function_error(
                parser,
                "native Core unary `-` requires Int"
            );
        }
        return function_expression(
            FUNCTION_NEGATE,
            FUNCTION_VALUE_INT,
            source_line(parser->source, operator_at),
            value,
            NULL
        );
    }
    return function_parse_atom(parser);
}

/*
 * `*`, `//`, `/`, and `%` share one precedence level, in that order of
 * matching: `//` has to be tried before `/` or it lexes as a division followed
 * by a unary parse failure. Comments are `#` to end of line in both front ends,
 * so `//` collides with nothing.
 */
static FunctionExpression *function_parse_product(FunctionParser *parser) {
    FunctionExpression *left = function_parse_unary(parser);
    while (parser->error[0] == '\0') {
        function_skip_trivia(parser);
        if (parser->cursor >= parser->limit) break;
        char head = parser->source[parser->cursor];
        if (head != '*' && head != '/' && head != '%') break;
        FunctionExpressionKind kind;
        const char *name;
        size_t operator_at = parser->cursor;
        size_t width = 1;
        if (head == '*') {
            kind = FUNCTION_MULTIPLY;
            name = "*";
        } else if (head == '%') {
            kind = FUNCTION_FLOOR_MODULO;
            name = "%";
        } else if (parser->cursor + 1 < parser->limit &&
                   parser->source[parser->cursor + 1] == '/') {
            kind = FUNCTION_FLOOR_DIVIDE;
            name = "//";
            width = 2;
        } else {
            /* Kofun has no implicit numeric promotion, so `/` cannot produce a
             * fractional value from two Int operands and has nothing to mean on
             * Int. The integer quotient is `//`, which floors. Refusing here
             * rather than truncating keeps `/` free to be given a meaning once
             * a fractional type exists, with no silent change to any program
             * that compiles today. */
            function_error(
                parser,
                "native Core `/` is not defined on Int; use `//` for the "
                "integer quotient"
            );
            return left;
        }
        parser->cursor += width;
        FunctionExpression *right = function_parse_unary(parser);
        if (left == NULL || right == NULL) return left;
        if (left->value_kind != FUNCTION_VALUE_INT ||
            right->value_kind != FUNCTION_VALUE_INT) {
            function_error(
                parser,
                "native Core `%s` requires Int operands",
                name
            );
            return left;
        }
        left = function_expression(
            kind,
            FUNCTION_VALUE_INT,
            source_line(parser->source, operator_at),
            left,
            right
        );
    }
    return left;
}

static FunctionExpression *function_parse_sum(FunctionParser *parser) {
    FunctionExpression *left = function_parse_product(parser);
    while (parser->error[0] == '\0') {
        function_skip_trivia(parser);
        if (parser->cursor >= parser->limit ||
            (parser->source[parser->cursor] != '+' &&
             parser->source[parser->cursor] != '-')) {
            break;
        }
        char operator = parser->source[parser->cursor];
        size_t operator_at = parser->cursor++;
        FunctionExpression *right = function_parse_product(parser);
        if (left == NULL || right == NULL) return left;
        if (operator == '+' &&
            left->value_kind == FUNCTION_VALUE_TEXT &&
            right->value_kind == FUNCTION_VALUE_TEXT) {
            left = function_expression(
                FUNCTION_TEXT_CONCAT,
                FUNCTION_VALUE_TEXT,
                source_line(parser->source, operator_at),
                left,
                right
            );
            continue;
        }
        if (left->value_kind != FUNCTION_VALUE_INT ||
            right->value_kind != FUNCTION_VALUE_INT) {
            function_error(
                parser,
                "native Core `+` requires two Int or two Text operands; "
                "`-` requires Int operands"
            );
            return left;
        }
        left = function_expression(
            operator == '+' ? FUNCTION_ADD : FUNCTION_SUBTRACT,
            FUNCTION_VALUE_INT,
            source_line(parser->source, operator_at),
            left,
            right
        );
    }
    return left;
}

static FunctionExpression *function_parse_expression(
    FunctionParser *parser
) {
    FunctionExpression *left = function_parse_sum(parser);
    if (left == NULL || parser->error[0] != '\0') return left;
    function_skip_trivia(parser);
    size_t operator_at = parser->cursor;
    FunctionExpressionKind kind;
    bool comparison = true;
    if (function_consume_pair(parser, '=', '=')) {
        kind = FUNCTION_EQUAL;
    } else if (function_consume_pair(parser, '!', '=')) {
        kind = FUNCTION_NOT_EQUAL;
    } else if (function_consume_pair(parser, '<', '=')) {
        kind = FUNCTION_LESS_EQUAL;
    } else if (function_consume_pair(parser, '>', '=')) {
        kind = FUNCTION_GREATER_EQUAL;
    } else if (function_consume_char(parser, '<')) {
        kind = FUNCTION_LESS;
    } else if (function_consume_char(parser, '>')) {
        kind = FUNCTION_GREATER;
    } else {
        comparison = false;
        kind = FUNCTION_EQUAL;
    }
    if (!comparison) return left;

    FunctionExpression *right = function_parse_sum(parser);
    if (right == NULL) return left;
    if (left->value_kind != FUNCTION_VALUE_INT ||
        right->value_kind != FUNCTION_VALUE_INT) {
        function_error(
            parser,
            "native Core comparison requires Int operands"
        );
        return left;
    }
    return function_expression(
        kind,
        FUNCTION_VALUE_BOOL,
        source_line(parser->source, operator_at),
        left,
        right
    );
}

static bool function_statement_add(
    FunctionParser *parser,
    FunctionDeclaration *function,
    FunctionStatement statement
) {
    if (function->statement_count >= MAX_CORE_STATEMENTS) {
        function_error(
            parser,
            "native Core function has too many statements"
        );
        return false;
    }
    function->statements[function->statement_count++] = statement;
    return true;
}

static bool function_bodies(
    FunctionProgram *program,
    char error[256],
    size_t *error_at
) {
    for (size_t function_index = 0;
         function_index < program->function_count;
         ++function_index) {
        FunctionDeclaration *function =
            &program->functions[function_index];
        FunctionParser parser = {
            .source = program->source,
            .cursor = function->body_start,
            .limit = function->body_end,
            .program = program,
            .function = function,
        };
        bool is_main = function_index == program->main_index;
        while (true) {
            function_skip_trivia(&parser);
            if (parser.cursor >= parser.limit) break;
            size_t statement_at = parser.cursor;
            FunctionStatement statement = {
                .source_line = source_line(program->source, statement_at),
            };
            if (function_consume_word(&parser, "if")) {
                statement.kind = FUNCTION_STATEMENT_IF_RETURN;
                statement.condition = function_parse_expression(&parser);
                if (statement.condition == NULL ||
                    statement.condition->value_kind !=
                        FUNCTION_VALUE_BOOL) {
                    function_error(
                        &parser,
                        "native Core if condition must have type Bool"
                    );
                } else if (!function_consume_char(&parser, '{') ||
                           !function_consume_word(&parser, "return")) {
                    function_error(
                        &parser,
                        "native Core if body must be `{ return Int }`"
                    );
                } else {
                    statement.value =
                        function_parse_expression(&parser);
                    if (statement.value == NULL ||
                        statement.value->value_kind !=
                            function->result_kind ||
                        !function_consume_char(&parser, '}')) {
                        function_error(
                            &parser,
                            "native Core if body must return %s",
                            function_type_name(function->result_kind)
                        );
                    }
                }
            } else if (function_consume_word(&parser, "return")) {
                statement.kind = FUNCTION_STATEMENT_RETURN;
                statement.value = function_parse_expression(&parser);
                if (!function->has_result ||
                    statement.value == NULL ||
                    statement.value->value_kind != function->result_kind) {
                    function_error(
                        &parser,
                        "native Core function must return %s",
                        function_type_name(function->result_kind)
                    );
                }
            } else if (function_consume_word(&parser, "print")) {
                statement.kind = FUNCTION_STATEMENT_PRINT;
                if (!is_main) {
                    function_error(
                        &parser,
                        "native Core print is only supported in main"
                    );
                } else if (!function_consume_char(&parser, '(')) {
                    function_error(
                        &parser,
                        "expected `(` after native Core print"
                    );
                } else {
                    statement.value =
                        function_parse_expression(&parser);
                    if (statement.value == NULL ||
                        (statement.value->value_kind !=
                            FUNCTION_VALUE_INT &&
                         statement.value->value_kind !=
                            FUNCTION_VALUE_TEXT) ||
                        !function_consume_char(&parser, ')')) {
                        function_error(
                            &parser,
                            "native Core print requires one Int or Text"
                        );
                    }
                }
            } else if (function_consume_word(&parser, "let")) {
                statement.kind = FUNCTION_STATEMENT_LET;
                if (function_consume_word(&parser, "mut")) {
                    function_error(
                        &parser,
                        "native Core mutable function locals are unsupported"
                    );
                } else if (function->local_count >= MAX_CORE_STATEMENTS ||
                           function->parameter_count +
                                   function->local_count + 1 >
                               MAX_FUNCTION_FRAME_SLOTS) {
                    function_error(
                        &parser,
                        "native Core function has too many locals"
                    );
                } else {
                    char name[MAX_CORE_NAME];
                    FunctionValueKind annotation = FUNCTION_VALUE_INT;
                    bool annotated = false;
                    bool parsing = true;
                    if (!function_identifier(&parser, name)) {
                        function_error(
                            &parser,
                            "expected native Core local name"
                        );
                        parsing = false;
                    } else if (function_parameter_find(function, name) !=
                                   SIZE_MAX ||
                               function_local_find(function, name) !=
                                   SIZE_MAX) {
                        function_error(
                            &parser,
                            "duplicate native Core binding `%s`",
                            name
                        );
                        parsing = false;
                    }
                    /*
                     * The annotation is optional. When it is written the
                     * initializer must agree with it; when it is not, the
                     * initializer's own kind is the local's type. Either way
                     * no binding is introduced whose type nothing decided.
                     */
                    if (parsing && function_consume_char(&parser, ':')) {
                        annotated = true;
                        if (!function_parse_type(&parser, &annotation)) {
                            if (parser.error[0] == '\0') {
                                function_error(
                                    &parser,
                                    "native Core local type must be Int or Text"
                                );
                            }
                            parsing = false;
                        }
                    }
                    if (parsing && !function_consume_char(&parser, '=')) {
                        function_error(
                            &parser,
                            "expected `=` in native Core local"
                        );
                        parsing = false;
                    }
                    if (parsing) {
                        statement.value =
                            function_parse_expression(&parser);
                        if (statement.value == NULL) {
                            if (parser.error[0] == '\0') {
                                function_error(
                                    &parser,
                                    "expected native Core local value"
                                );
                            }
                        } else if (statement.value->value_kind ==
                                   FUNCTION_VALUE_BOOL) {
                            function_error(
                                &parser,
                                "native Core local `%s` must be Int or Text",
                                name
                            );
                        } else if (annotated &&
                                   statement.value->value_kind != annotation) {
                            function_error(
                                &parser,
                                "native Core local `%s` is not %s",
                                name,
                                function_type_name(annotation)
                            );
                        } else {
                            size_t local = function->local_count;
                            memcpy(
                                function->locals[local],
                                name,
                                strlen(name) + 1
                            );
                            function->local_types[local] =
                                statement.value->value_kind;
                            statement.slot =
                                function->parameter_count + local;
                            ++function->local_count;
                        }
                    }
                }
            } else {
                statement.kind = FUNCTION_STATEMENT_EXPRESSION;
                statement.value = function_parse_expression(&parser);
                if (statement.value == NULL) {
                    function_error(
                        &parser,
                        "native Core expression statement requires a value"
                    );
                }
            }
            if (!function_statement_add(&parser, function, statement) ||
                parser.error[0] != '\0') {
                break;
            }
        }
        if (parser.error[0] == '\0' && function->has_result) {
            /*
             * The final expression of a result-carrying function is its
             * result. This is a parse-time rewrite of the last statement, not
             * a lowering change: both targets see an ordinary return, so
             * neither x86-64 nor AArch64 needs to know the rule exists.
             *
             * Only an expression whose value kind already matches the declared
             * result qualifies. A mismatch, or a body ending in anything that
             * is not an expression, keeps the original refusal — a function
             * that falls off its end must still say so rather than return a
             * value nobody wrote.
             */
            if (function->statement_count > 0) {
                FunctionStatement *last = &function->statements[
                    function->statement_count - 1
                ];
                if (last->kind == FUNCTION_STATEMENT_EXPRESSION &&
                    last->value != NULL &&
                    last->value->value_kind == function->result_kind) {
                    last->kind = FUNCTION_STATEMENT_RETURN;
                }
            }
            if (function->statement_count == 0 ||
                function->statements[
                    function->statement_count - 1
                ].kind != FUNCTION_STATEMENT_RETURN) {
                function_error(
                    &parser,
                    "native Core %s function must end with return",
                    function_type_name(function->result_kind)
                );
            }
        }
        if (parser.error[0] != '\0') {
            memcpy(error, parser.error, sizeof(parser.error));
            *error_at = parser.cursor;
            return false;
        }
    }
    return true;
}

static bool function_expression_uses_syscall(
    const FunctionExpression *expression
) {
    if (expression == NULL) return false;
    if (expression->kind == FUNCTION_SYSCALL) return true;
    if (function_expression_uses_syscall(expression->left)) return true;
    if (function_expression_uses_syscall(expression->right)) return true;
    for (size_t index = 0;
         expression->arguments != NULL &&
             index < expression->argument_count;
         ++index) {
        if (function_expression_uses_syscall(expression->arguments[index])) {
            return true;
        }
    }
    return false;
}

/*
 * Whether any body reaches a Linux syscall intrinsic. Asked once, before a
 * target is lowered, so a target that has no syscall boundary can refuse the
 * program with a diagnostic instead of failing inside its emitter.
 */
static bool function_program_uses_syscall(const FunctionProgram *program) {
    for (size_t index = 0; index < program->function_count; ++index) {
        const FunctionDeclaration *function = &program->functions[index];
        for (size_t statement = 0;
             statement < function->statement_count;
             ++statement) {
            const FunctionStatement *item = &function->statements[statement];
            if (function_expression_uses_syscall(item->condition)) return true;
            if (function_expression_uses_syscall(item->value)) return true;
        }
    }
    return false;
}

/*
 * The AArch64 function backend now lowers Text parameters, results, immutable
 * locals, concatenation, literals, and print(Text) directly (issue #623), so
 * there is no longer an AArch64-specific Text refusal before lowering.
 */

static size_t register_depth(const Node *expression) {
    if (expression->kind == NODE_LITERAL ||
        expression->kind == NODE_TEXT_LITERAL ||
        expression->kind == NODE_VARIABLE ||
        expression->kind == NODE_PARAMETER) {
        return 1;
    }
    if (expression->kind == NODE_LET) {
        size_t initializer = register_depth(expression->left);
        size_t body = register_depth(expression->right);
        return initializer > body ? initializer : body;
    }
    if (expression->kind == NODE_NEGATE ||
        expression->kind == NODE_LENGTH) {
        return register_depth(expression->left);
    }
    if (expression->kind == NODE_LIST ||
        expression->kind == NODE_CHARS ||
        expression->kind == NODE_CODEPOINTS ||
        expression->kind == NODE_BYTES) {
        size_t depth = 1;
        if (expression->kind == NODE_CHARS ||
            expression->kind == NODE_CODEPOINTS ||
            expression->kind == NODE_BYTES) {
            depth = register_depth(expression->left);
        }
        for (size_t index = 0; index < expression->item_count; ++index) {
            size_t item = 1 + register_depth(expression->items[index]);
            if (item > depth) depth = item;
        }
        return depth;
    }
    size_t left = register_depth(expression->left);
    size_t right = register_depth(expression->right);
    size_t with_left_live = 1 + right;
    return left > with_left_live ? left : with_left_live;
}

static void free_node(Node *expression) {
    if (expression == NULL) return;
    free_node(expression->left);
    free_node(expression->right);
    free_node(expression->third);
    for (size_t index = 0;
         expression->items != NULL && index < expression->item_count;
         ++index) {
        free_node(expression->items[index]);
    }
    free(expression->text_value);
    free(expression->items);
    free(expression);
}

static bool uses_list(const Node *expression) {
    if (expression == NULL) return false;
    if (expression->kind == NODE_LIST ||
        expression->kind == NODE_CHARS ||
        expression->kind == NODE_CODEPOINTS ||
        expression->kind == NODE_BYTES ||
        expression->kind == NODE_MAP ||
        expression->kind == NODE_FILTER ||
        expression->kind == NODE_FOLD ||
        (expression->kind == NODE_INDEX &&
         expression->left->value_kind == VALUE_LIST) ||
        (expression->kind == NODE_LENGTH &&
         expression->left->value_kind == VALUE_LIST)) {
        return true;
    }
    if (uses_list(expression->left) ||
        uses_list(expression->right) ||
        uses_list(expression->third)) {
        return true;
    }
    for (size_t index = 0;
         expression->items != NULL && index < expression->item_count;
         ++index) {
        if (uses_list(expression->items[index])) return true;
    }
    return false;
}

static bool uses_text(const Node *expression) {
    if (expression == NULL) return false;
    if (expression->value_kind == VALUE_TEXT ||
        expression->element_kind == VALUE_TEXT ||
        expression->kind == NODE_TEXT_EQUAL ||
        expression->kind == NODE_TEXT_NOT_EQUAL ||
        (expression->kind == NODE_LENGTH &&
         expression->left->value_kind == VALUE_TEXT)) {
        return true;
    }
    if (uses_text(expression->left) ||
        uses_text(expression->right) ||
        uses_text(expression->third)) {
        return true;
    }
    for (size_t index = 0;
         expression->items != NULL && index < expression->item_count;
         ++index) {
        if (uses_text(expression->items[index])) return true;
    }
    return false;
}

static bool uses_local_bindings(const Node *expression) {
    if (expression == NULL) return false;
    if (expression->kind == NODE_LET ||
        expression->kind == NODE_VARIABLE ||
        expression->kind == NODE_PARAMETER) {
        return true;
    }
    if (uses_local_bindings(expression->left) ||
        uses_local_bindings(expression->right) ||
        uses_local_bindings(expression->third)) {
        return true;
    }
    for (size_t index = 0;
         expression->items != NULL && index < expression->item_count;
         ++index) {
        if (uses_local_bindings(expression->items[index])) return true;
    }
    return false;
}

static void x64_mov_eax_imm32(Bytes *text, uint32_t value) {
    byte(text, UINT8_C(0xb8));
    u32_le(text, value);
}

typedef struct {
    size_t *fields;
    size_t length;
    size_t capacity;
} Offsets;

typedef struct {
    size_t field;
    const uint8_t *value;
    size_t length;
} TextFixup;

typedef struct {
    TextFixup *items;
    size_t length;
    size_t capacity;
} TextFixups;

typedef struct {
    bool used;
    Offsets alloc_calls;
    Offsets oom_jumps;
    Offsets list_index_jumps;
    Offsets text_index_jumps;
    Offsets text_concat_calls;
    Offsets text_equal_calls;
    Offsets text_length_calls;
    Offsets text_index_calls;
    Offsets text_chars_calls;
    Offsets newline_addresses;
    Offsets bool_true_addresses;
    Offsets bool_false_addresses;
    TextFixups text_literals;
} X64Runtime;

static void offsets_add(Offsets *offsets, size_t field) {
    if (offsets->length == offsets->capacity) {
        size_t capacity =
            offsets->capacity == 0 ? 8 : offsets->capacity * 2;
        size_t *grown = realloc(
            offsets->fields,
            capacity * sizeof(*offsets->fields)
        );
        if (grown == NULL) fatal("out of memory");
        offsets->fields = grown;
        offsets->capacity = capacity;
    }
    offsets->fields[offsets->length++] = field;
}

static void text_fixups_add(
    TextFixups *fixups,
    size_t field,
    const uint8_t *value,
    size_t length
) {
    if (fixups->length == fixups->capacity) {
        size_t capacity =
            fixups->capacity == 0 ? 8 : fixups->capacity * 2;
        TextFixup *grown = realloc(
            fixups->items,
            capacity * sizeof(*fixups->items)
        );
        if (grown == NULL) fatal("out of memory");
        fixups->items = grown;
        fixups->capacity = capacity;
    }
    fixups->items[fixups->length++] = (TextFixup){
        .field = field,
        .value = value,
        .length = length,
    };
}

static void x64_runtime_free(X64Runtime *runtime) {
    free(runtime->alloc_calls.fields);
    free(runtime->oom_jumps.fields);
    free(runtime->list_index_jumps.fields);
    free(runtime->text_index_jumps.fields);
    free(runtime->text_concat_calls.fields);
    free(runtime->text_equal_calls.fields);
    free(runtime->text_length_calls.fields);
    free(runtime->text_index_calls.fields);
    free(runtime->text_chars_calls.fields);
    free(runtime->newline_addresses.fields);
    free(runtime->bool_true_addresses.fields);
    free(runtime->bool_false_addresses.fields);
    free(runtime->text_literals.items);
}

static void x64_patch_rel32(Bytes *text, size_t field, size_t target) {
    int64_t displacement =
        (int64_t)target - (int64_t)(field + sizeof(uint32_t));
    if (displacement < INT32_MIN || displacement > INT32_MAX) {
        fatal("x86-64 native Core rel32 is out of range");
    }
    uint32_t encoded = (uint32_t)(int32_t)displacement;
    if (field > text->length || text->length - field < sizeof(encoded)) {
        fatal("x86-64 native Core rel32 field is outside text");
    }
    for (unsigned index = 0; index < 4; ++index) {
        text->data[field + index] =
            (uint8_t)(encoded >> (index * 8));
    }
}

static void x64_rel32_placeholder(
    Bytes *text,
    uint8_t first,
    uint8_t second,
    Offsets *offsets
) {
    byte(text, first);
    byte(text, second);
    offsets_add(offsets, text->length);
    u32_le(text, 0);
}

static void x64_call_alloc(Bytes *text, X64Runtime *runtime) {
    runtime->used = true;
    byte(text, UINT8_C(0xe8));
    offsets_add(&runtime->alloc_calls, text->length);
    u32_le(text, 0);
}

static void x64_call_runtime(
    Bytes *text,
    X64Runtime *runtime,
    Offsets *calls
) {
    runtime->used = true;
    byte(text, UINT8_C(0xe8));
    offsets_add(calls, text->length);
    u32_le(text, 0);
}

/*
 * x86-64 register numbers exactly as they are encoded in ModRM and REX. The
 * numbers above seven need REX.R or REX.B, which the helpers below add.
 */
enum {
    X64_RAX = 0,
    X64_RCX = 1,
    X64_RDX = 2,
    X64_RBX = 3,
    X64_RSP = 4,
    X64_RBP = 5,
    X64_RSI = 6,
    X64_RDI = 7,
    X64_R8 = 8,
    X64_R9 = 9,
    X64_R10 = 10,
    X64_R11 = 11,
    X64_R12 = 12,
    X64_R13 = 13,
    X64_R14 = 14,
    X64_R15 = 15,
    X64_NO_REGISTER = 16,
};

/*
 * A 64-bit operand that is either a register or the frame slot at
 * `[rbp + displacement]`. Every instruction the function backend emits has at
 * most one such operand, so one descriptor is enough to encode both forms.
 */
typedef struct {
    bool in_register;
    unsigned reg;
    size_t slot;      /* the frame slot, when the value is not in a register */
} Operand;

/*
 * One operand representation for every target.
 *
 * A value is in a register or in a frame slot, and the slot index is the fact
 * both targets already derive their memory operand from: AArch64 stores it and
 * converts at encode time, and x86-64 used to convert eagerly through the one
 * caller `x64_frame_operand` ever had. Carrying the slot rather than a byte
 * displacement is therefore not a compromise between two representations — it
 * is the one both were computed from, and it is what a third target would be
 * handed anyway.
 *
 * Per DD-022 a redundancy is worth keeping only when a gate can turn it into
 * evidence. Two spellings of "this register, or this spill slot" cannot
 * disagree, so the native gate proved nothing by carrying both; the lowerings
 * above this layer stay duplicated, because their agreement is real evidence.
 */
static Operand target_register_operand(unsigned reg) {
    Operand operand = {.in_register = true, .reg = reg, .slot = 0};
    return operand;
}

static Operand target_slot_operand(size_t slot) {
    Operand operand = {.in_register = false, .reg = 0, .slot = slot};
    return operand;
}

static uint32_t x64_local_displacement(size_t slot) {
    if (slot >= (size_t)INT32_MAX / sizeof(uint64_t)) {
        fatal("x86-64 Core local frame is too large");
    }
    int32_t displacement =
        -(int32_t)((slot + 1) * sizeof(uint64_t));
    return (uint32_t)displacement;
}

/* REX.W, plus REX.R for the ModRM `reg` field and REX.B for its r/m field. */
static void x64_rex_w(Bytes *text, unsigned reg, unsigned rm) {
    uint8_t rex = UINT8_C(0x48);
    if (reg >= 8) rex |= UINT8_C(0x04);
    if (rm >= 8) rex |= UINT8_C(0x01);
    byte(text, rex);
}

/*
 * Emits one 64-bit instruction whose ModRM `reg` field is `reg` and whose r/m
 * field addresses `operand`. `reg` is a register number for two-operand forms
 * and the opcode extension for group forms such as `neg`.
 */
static void x64_encode(
    Bytes *text,
    const uint8_t *opcode,
    size_t opcode_length,
    unsigned reg,
    Operand operand
) {
    x64_rex_w(text, reg, operand.in_register ? operand.reg : X64_RBP);
    for (size_t index = 0; index < opcode_length; ++index) {
        byte(text, opcode[index]);
    }
    if (operand.in_register) {
        byte(
            text,
            (uint8_t)(
                UINT8_C(0xc0) | ((reg & 7) << 3) | (operand.reg & 7)
            )
        );
        return;
    }
    /* A frame slot within reach of a signed byte takes the compact form. */
    uint32_t displacement_bits = x64_local_displacement(operand.slot);
    int32_t displacement = (int32_t)displacement_bits;
    if (displacement >= -128 && displacement <= 127) {
        byte(
            text,
            (uint8_t)(UINT8_C(0x40) | ((reg & 7) << 3) | (X64_RBP & 7))
        );
        byte(text, (uint8_t)displacement);
        return;
    }
    byte(
        text,
        (uint8_t)(UINT8_C(0x80) | ((reg & 7) << 3) | (X64_RBP & 7))
    );
    u32_le(text, displacement_bits);
}

static void x64_encode_op(
    Bytes *text,
    uint8_t opcode,
    unsigned reg,
    Operand operand
) {
    x64_encode(text, &opcode, 1, reg, operand);
}

enum {
    X64_MOV_REG_RM = 0x8b,
    X64_MOV_RM_REG = 0x89,
    X64_ADD_REG_RM = 0x03,
    X64_ADD_RM_REG = 0x01,
    X64_SUB_REG_RM = 0x2b,
    X64_SUB_RM_REG = 0x29,
    X64_CMP_REG_RM = 0x3b,
    X64_CMP_RM_REG = 0x39,
    X64_TEST_RM_REG = 0x85,
    X64_GROUP3_RM = 0xf7,
    X64_GROUP3_NEG = 3,
    X64_GROUP3_IDIV = 7,
    X64_XOR_RM_REG = 0x31,
};

static void x64_mov_register_operand(
    Bytes *text,
    unsigned reg,
    Operand from
) {
    x64_encode_op(text, X64_MOV_REG_RM, reg, from);
}

static void x64_mov_operand_register(
    Bytes *text,
    Operand into,
    unsigned reg
) {
    x64_encode_op(text, X64_MOV_RM_REG, reg, into);
}

/*
 * `mov reg32, imm32` zero-extends into the full 64-bit register, which is the
 * literal and Text-address form the backend has always emitted. The field
 * offset is returned so callers can register an address fixup.
 */
static void x64_mov_register_imm32_opcode(Bytes *text, unsigned reg) {
    if (reg >= 8) byte(text, UINT8_C(0x41)); /* REX.B */
    byte(text, (uint8_t)(UINT8_C(0xb8) | (reg & 7)));
}

static size_t x64_mov_register_imm32_field(Bytes *text, unsigned reg) {
    x64_mov_register_imm32_opcode(text, reg);
    size_t field = text->length;
    u32_le(text, 0);
    return field;
}

/*
 * A signed 64-bit literal in the narrowest form that holds it: the existing
 * zero-extending `mov reg32, imm32` when it is non-negative and fits, the
 * sign-extending `REX.W C7 /0 imm32` when it fits in a signed 32-bit field,
 * and `REX.W B8+r imm64` otherwise. Narrower is not only smaller — the bounded
 * static RX page is one page — it also keeps every image whose literals fit in
 * the old range byte-identical.
 */
static void x64_mov_register_imm64(
    Bytes *text,
    unsigned reg,
    int64_t value
) {
    if (value >= 0 && value <= (int64_t)UINT32_MAX) {
        x64_mov_register_imm32_opcode(text, reg);
        u32_le(text, (uint32_t)value);
        return;
    }
    if (value >= INT32_MIN && value <= INT32_MAX) {
        byte(text, (uint8_t)(UINT8_C(0x48) | (reg >= 8 ? 1 : 0)));
        byte(text, UINT8_C(0xc7));
        byte(text, (uint8_t)(UINT8_C(0xc0) | (reg & 7)));
        u32_le(text, (uint32_t)(int32_t)value);
        return;
    }
    byte(text, (uint8_t)(UINT8_C(0x48) | (reg >= 8 ? 1 : 0)));
    byte(text, (uint8_t)(UINT8_C(0xb8) | (reg & 7)));
    u64_le(text, (uint64_t)value);
}


static void x64_load_local(
    Bytes *text,
    size_t slot
) {
    /* mov rax, [rbp + disp32] */
    x64_mov_register_operand(text, X64_RAX, target_slot_operand(slot));
}

static void x64_store_local(
    Bytes *text,
    size_t slot
) {
    /* mov [rbp + disp32], rax */
    x64_mov_operand_register(text, target_slot_operand(slot), X64_RAX);
}

static size_t x64_local_jcc(Bytes *text, uint8_t condition);
static size_t x64_local_jmp(Bytes *text);
static void x64_emit(
    Bytes *text,
    const uint8_t *instructions,
    size_t length
);

static void x64_expression(
    Bytes *text,
    const Node *expression,
    LineRows *rows,
    X64Runtime *runtime
) {
    if (expression->kind == NODE_INDEX &&
        expression->left->value_kind == VALUE_TEXT &&
        expression->left->value_known &&
        expression->right->value_known &&
        !expression->value_known) {
        runtime->used = true;
        byte(text, UINT8_C(0xe9)); /* known grapheme OOB -> Text error */
        offsets_add(&runtime->text_index_jumps, text->length);
        u32_le(text, 0);
        x64_mov_eax_imm32(text, 0);
        byte(text, UINT8_C(0x50)); /* unreachable stack result */
        return;
    }

    if (expression->kind == NODE_LENGTH &&
        expression->value_known) {
        line_row(rows, text->length, expression->source_line);
        x64_mov_eax_imm32(text, (uint32_t)expression->value);
        byte(text, UINT8_C(0x50)); /* push compile-time length */
        return;
    }

    if (expression->value_kind == VALUE_TEXT &&
        expression->value_known &&
        expression->text_value != NULL &&
        expression->kind != NODE_TEXT_LITERAL &&
        expression->kind != NODE_TEXT_CONCAT) {
        runtime->used = true;
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0xb8)); /* mov eax, Text address */
        text_fixups_add(
            &runtime->text_literals,
            text->length,
            expression->text_value,
            expression->text_length
        );
        u32_le(text, 0);
        byte(text, UINT8_C(0x50)); /* push folded Text */
        return;
    }

    if (expression->kind == NODE_LITERAL) {
        line_row(rows, text->length, expression->source_line);
        x64_mov_eax_imm32(text, (uint32_t)expression->value);
        byte(text, UINT8_C(0x50)); /* push rax */
        return;
    }

    if (expression->kind == NODE_VARIABLE ||
        expression->kind == NODE_PARAMETER) {
        line_row(rows, text->length, expression->source_line);
        x64_load_local(text, expression->slot);
        byte(text, UINT8_C(0x50)); /* push local value */
        return;
    }

    if (expression->kind == NODE_LET) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x58)); /* pop initializer */
        x64_store_local(text, expression->slot);
        x64_expression(text, expression->right, rows, runtime);
        return;
    }

    if (expression->kind == NODE_TEXT_LITERAL) {
        runtime->used = true;
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0xb8)); /* mov eax, Text address */
        text_fixups_add(
            &runtime->text_literals,
            text->length,
            expression->text_value,
            expression->text_length
        );
        u32_le(text, 0);
        byte(text, UINT8_C(0x50)); /* push Text */
        return;
    }

    if (expression->kind == NODE_NEGATE) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x58)); /* pop rax */
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0xf7));
        byte(text, UINT8_C(0xd8)); /* neg rax */
        byte(text, UINT8_C(0x50)); /* push result */
        return;
    }

    if (expression->kind == NODE_CHARS &&
        !expression->value_known) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x5f)); /* pop rdi: source Text */
        x64_call_runtime(
            text,
            runtime,
            &runtime->text_chars_calls
        );
        byte(text, UINT8_C(0x50)); /* push List[Text] */
        return;
    }

    if (expression->kind == NODE_LIST ||
        expression->kind == NODE_CHARS ||
        expression->kind == NODE_CODEPOINTS ||
        expression->kind == NODE_BYTES) {
        if (expression->item_count >
            (UINT32_MAX - 8) / sizeof(uint64_t)) {
            fatal("x86-64 Core list is too large");
        }
        runtime->used = true;
        line_row(rows, text->length, expression->source_line);
        uint32_t bytes = (uint32_t)(
            8 + expression->item_count * sizeof(uint64_t)
        );
        byte(text, UINT8_C(0xbf)); /* mov edi, allocation size */
        u32_le(text, bytes);
        x64_call_alloc(text, runtime);
        byte(text, UINT8_C(0x50)); /* keep list pointer on stack */

        byte(text, UINT8_C(0xb9)); /* mov ecx, element count */
        u32_le(text, (uint32_t)expression->item_count);
        const uint8_t list_from_stack[] = {
            UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x14), UINT8_C(0x24),
        };
        for (size_t index = 0; index < sizeof(list_from_stack); ++index) {
            byte(text, list_from_stack[index]); /* mov rdx, [rsp] */
        }
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x89));
        byte(text, UINT8_C(0x0a)); /* mov [rdx], rcx */

        for (size_t index = 0; index < expression->item_count; ++index) {
            x64_expression(text, expression->items[index], rows, runtime);
            byte(text, UINT8_C(0x59)); /* pop rcx */
            for (size_t part = 0; part < sizeof(list_from_stack); ++part) {
                byte(text, list_from_stack[part]); /* mov rdx, [rsp] */
            }
            byte(text, UINT8_C(0x48));
            byte(text, UINT8_C(0x89));
            byte(text, UINT8_C(0x8a)); /* mov [rdx + disp32], rcx */
            u32_le(text, (uint32_t)(8 + index * sizeof(uint64_t)));
        }
        return;
    }

    if (expression->kind == NODE_MAP) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x5b)); /* pop rbx: source list */
        const uint8_t map_allocate[] = {
            UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x33), /* r14 = len */
            UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xf7), /* rdi = len */
            UINT8_C(0x48), UINT8_C(0xc1), UINT8_C(0xe7), UINT8_C(0x03),
            UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
        };
        x64_emit(text, map_allocate, sizeof(map_allocate));
        x64_call_alloc(text, runtime);
        const uint8_t map_open[] = {
            UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xc4), /* r12 = output */
            UINT8_C(0x4d), UINT8_C(0x89), UINT8_C(0x34), UINT8_C(0x24),
            UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xed), /* r13 = 0 */
        };
        x64_emit(text, map_open, sizeof(map_open));
        size_t loop = text->length;
        const uint8_t map_compare[] = {
            UINT8_C(0x4d), UINT8_C(0x39), UINT8_C(0xf5), /* r13 vs r14 */
        };
        x64_emit(text, map_compare, sizeof(map_compare));
        size_t done = x64_local_jcc(text, UINT8_C(0x8d)); /* jge */
        const uint8_t map_load[] = {
            UINT8_C(0x4a), UINT8_C(0x8b), UINT8_C(0x44),
            UINT8_C(0xeb), UINT8_C(0x08),
        };
        x64_emit(text, map_load, sizeof(map_load));
        x64_store_local(text, expression->slot);
        x64_expression(text, expression->right, rows, runtime);
        byte(text, UINT8_C(0x58)); /* pop mapped element */
        const uint8_t map_store_next[] = {
            UINT8_C(0x4b), UINT8_C(0x89), UINT8_C(0x44),
            UINT8_C(0xec), UINT8_C(0x08),
            UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xc5), /* inc r13 */
        };
        x64_emit(text, map_store_next, sizeof(map_store_next));
        size_t back = x64_local_jmp(text);
        size_t done_at = text->length;
        byte(text, UINT8_C(0x41));
        byte(text, UINT8_C(0x54)); /* push r12 */
        x64_patch_rel32(text, done, done_at);
        x64_patch_rel32(text, back, loop);
        return;
    }

    if (expression->kind == NODE_FILTER) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x5b)); /* pop rbx: source list */
        const uint8_t filter_allocate[] = {
            UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x3b), /* r15 = len */
            UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xff), /* rdi = len */
            UINT8_C(0x48), UINT8_C(0xc1), UINT8_C(0xe7), UINT8_C(0x03),
            UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
        };
        x64_emit(text, filter_allocate, sizeof(filter_allocate));
        x64_call_alloc(text, runtime);
        const uint8_t filter_open[] = {
            UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xc4), /* r12 = output */
            UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xed), /* r13 = index */
            UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xf6), /* r14 = count */
        };
        x64_emit(text, filter_open, sizeof(filter_open));
        size_t loop = text->length;
        const uint8_t filter_compare[] = {
            UINT8_C(0x4d), UINT8_C(0x39), UINT8_C(0xfd), /* r13 vs r15 */
        };
        x64_emit(text, filter_compare, sizeof(filter_compare));
        size_t done = x64_local_jcc(text, UINT8_C(0x8d)); /* jge */
        const uint8_t filter_load[] = {
            UINT8_C(0x4a), UINT8_C(0x8b), UINT8_C(0x44),
            UINT8_C(0xeb), UINT8_C(0x08),
        };
        x64_emit(text, filter_load, sizeof(filter_load));
        x64_store_local(text, expression->slot);
        x64_expression(text, expression->right, rows, runtime);
        byte(text, UINT8_C(0x58)); /* pop predicate */
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x85));
        byte(text, UINT8_C(0xc0)); /* test rax, rax */
        size_t skip = x64_local_jcc(text, UINT8_C(0x84)); /* je */
        x64_load_local(text, expression->slot);
        const uint8_t filter_store[] = {
            UINT8_C(0x4b), UINT8_C(0x89), UINT8_C(0x44),
            UINT8_C(0xf4), UINT8_C(0x08),
            UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xc6), /* inc r14 */
        };
        x64_emit(text, filter_store, sizeof(filter_store));
        size_t skip_at = text->length;
        const uint8_t filter_next[] = {
            UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xc5), /* inc r13 */
        };
        x64_emit(text, filter_next, sizeof(filter_next));
        size_t back = x64_local_jmp(text);
        size_t done_at = text->length;
        const uint8_t filter_close[] = {
            UINT8_C(0x4d), UINT8_C(0x89), UINT8_C(0x34), UINT8_C(0x24),
            UINT8_C(0x41), UINT8_C(0x54), /* push r12 */
        };
        x64_emit(text, filter_close, sizeof(filter_close));
        x64_patch_rel32(text, done, done_at);
        x64_patch_rel32(text, skip, skip_at);
        x64_patch_rel32(text, back, loop);
        return;
    }

    if (expression->kind == NODE_FOLD) {
        x64_expression(text, expression->left, rows, runtime);
        x64_expression(text, expression->right, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x41));
        byte(text, UINT8_C(0x5e)); /* pop r14: accumulator */
        byte(text, UINT8_C(0x5b)); /* pop rbx: source list */
        const uint8_t fold_open[] = {
            UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x2b), /* r13 = len */
            UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xe4), /* r12 = index */
        };
        x64_emit(text, fold_open, sizeof(fold_open));
        size_t loop = text->length;
        const uint8_t fold_compare[] = {
            UINT8_C(0x4d), UINT8_C(0x39), UINT8_C(0xec), /* r12 vs r13 */
        };
        x64_emit(text, fold_compare, sizeof(fold_compare));
        size_t done = x64_local_jcc(text, UINT8_C(0x8d)); /* jge */
        byte(text, UINT8_C(0x4c));
        byte(text, UINT8_C(0x89));
        byte(text, UINT8_C(0xf0)); /* mov rax, r14 */
        x64_store_local(text, expression->slot);
        const uint8_t fold_load[] = {
            UINT8_C(0x4a), UINT8_C(0x8b), UINT8_C(0x44),
            UINT8_C(0xe3), UINT8_C(0x08),
        };
        x64_emit(text, fold_load, sizeof(fold_load));
        x64_store_local(text, expression->slot + 1);
        x64_expression(text, expression->third, rows, runtime);
        byte(text, UINT8_C(0x41));
        byte(text, UINT8_C(0x5e)); /* pop r14: next accumulator */
        byte(text, UINT8_C(0x49));
        byte(text, UINT8_C(0xff));
        byte(text, UINT8_C(0xc4)); /* inc r12 */
        size_t back = x64_local_jmp(text);
        size_t done_at = text->length;
        byte(text, UINT8_C(0x41));
        byte(text, UINT8_C(0x56)); /* push r14 */
        x64_patch_rel32(text, done, done_at);
        x64_patch_rel32(text, back, loop);
        return;
    }

    if (expression->kind == NODE_LENGTH) {
        x64_expression(text, expression->left, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x5f)); /* pop rdi */
        if (expression->left->value_kind == VALUE_TEXT) {
            x64_call_runtime(
                text,
                runtime,
                &runtime->text_length_calls
            );
        } else {
            byte(text, UINT8_C(0x48));
            byte(text, UINT8_C(0x8b));
            byte(text, UINT8_C(0x07)); /* mov rax, [rdi] */
        }
        byte(text, UINT8_C(0x50)); /* push length */
        return;
    }

    if (expression->kind == NODE_INDEX) {
        runtime->used = true;
        x64_expression(text, expression->left, rows, runtime);
        x64_expression(text, expression->right, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        if (expression->left->value_kind == VALUE_TEXT) {
            byte(text, UINT8_C(0x5e)); /* pop rsi: codepoint index */
            byte(text, UINT8_C(0x5f)); /* pop rdi: Text */
            x64_call_runtime(
                text,
                runtime,
                &runtime->text_index_calls
            );
            byte(text, UINT8_C(0x50)); /* push one-codepoint Text */
            return;
        }
        byte(text, UINT8_C(0x59)); /* pop rcx: index */
        byte(text, UINT8_C(0x5a)); /* pop rdx: list */
        byte(text, UINT8_C(0x4c));
        byte(text, UINT8_C(0x8b));
        byte(text, UINT8_C(0x02)); /* mov r8, [rdx] */
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x85));
        byte(text, UINT8_C(0xc9)); /* test rcx, rcx */
        byte(text, UINT8_C(0x0f));
        byte(text, UINT8_C(0x89)); /* jns nonnegative */
        size_t nonnegative = text->length;
        u32_le(text, 0);
        byte(text, UINT8_C(0x4c));
        byte(text, UINT8_C(0x01));
        byte(text, UINT8_C(0xc1)); /* add rcx, r8 */
        x64_patch_rel32(text, nonnegative, text->length);

        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x85));
        byte(text, UINT8_C(0xc9)); /* test rcx, rcx */
        x64_rel32_placeholder(
            text,
            UINT8_C(0x0f),
            UINT8_C(0x88),
            &runtime->list_index_jumps
        ); /* js index error */
        byte(text, UINT8_C(0x4c));
        byte(text, UINT8_C(0x39));
        byte(text, UINT8_C(0xc1)); /* cmp rcx, r8 */
        x64_rel32_placeholder(
            text,
            UINT8_C(0x0f),
            UINT8_C(0x8d),
            &runtime->list_index_jumps
        ); /* jge index error */
        const uint8_t load[] = {
            UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x44),
            UINT8_C(0xca), UINT8_C(0x08),
        };
        for (size_t index = 0; index < sizeof(load); ++index) {
            byte(text, load[index]); /* mov rax, [rdx + rcx*8 + 8] */
        }
        byte(text, UINT8_C(0x50)); /* push element */
        return;
    }

    if (expression->kind == NODE_TEXT_CONCAT ||
        expression->kind == NODE_TEXT_EQUAL ||
        expression->kind == NODE_TEXT_NOT_EQUAL) {
        x64_expression(text, expression->left, rows, runtime);
        x64_expression(text, expression->right, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x5e)); /* pop rsi: right Text */
        byte(text, UINT8_C(0x5f)); /* pop rdi: left Text */
        if (expression->kind == NODE_TEXT_CONCAT) {
            x64_call_runtime(
                text,
                runtime,
                &runtime->text_concat_calls
            );
        } else {
            x64_call_runtime(
                text,
                runtime,
                &runtime->text_equal_calls
            );
            if (expression->kind == NODE_TEXT_NOT_EQUAL) {
                byte(text, UINT8_C(0x83));
                byte(text, UINT8_C(0xf0));
                byte(text, UINT8_C(0x01)); /* xor eax, 1 */
            }
        }
        byte(text, UINT8_C(0x50)); /* push result */
        return;
    }

    if (expression->kind == NODE_INT_EQUAL ||
        expression->kind == NODE_INT_NOT_EQUAL ||
        expression->kind == NODE_INT_LESS ||
        expression->kind == NODE_INT_LESS_EQUAL ||
        expression->kind == NODE_INT_GREATER ||
        expression->kind == NODE_INT_GREATER_EQUAL) {
        x64_expression(text, expression->left, rows, runtime);
        x64_expression(text, expression->right, rows, runtime);
        line_row(rows, text->length, expression->source_line);
        byte(text, UINT8_C(0x59)); /* pop rcx: right */
        byte(text, UINT8_C(0x58)); /* pop rax: left */
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x39));
        byte(text, UINT8_C(0xc8)); /* cmp rax, rcx */
        byte(text, UINT8_C(0x0f));
        uint8_t condition = UINT8_C(0x94); /* sete */
        if (expression->kind == NODE_INT_NOT_EQUAL) {
            condition = UINT8_C(0x95);
        } else if (expression->kind == NODE_INT_LESS) {
            condition = UINT8_C(0x9c);
        } else if (expression->kind == NODE_INT_LESS_EQUAL) {
            condition = UINT8_C(0x9e);
        } else if (expression->kind == NODE_INT_GREATER) {
            condition = UINT8_C(0x9f);
        } else if (expression->kind == NODE_INT_GREATER_EQUAL) {
            condition = UINT8_C(0x9d);
        }
        byte(text, condition);
        byte(text, UINT8_C(0xc0)); /* setcc al */
        byte(text, UINT8_C(0x0f));
        byte(text, UINT8_C(0xb6));
        byte(text, UINT8_C(0xc0)); /* movzx eax, al */
        byte(text, UINT8_C(0x50));
        return;
    }

    x64_expression(text, expression->left, rows, runtime);
    x64_expression(text, expression->right, rows, runtime);
    line_row(rows, text->length, expression->source_line);
    byte(text, UINT8_C(0x59)); /* pop rcx */
    byte(text, UINT8_C(0x58)); /* pop rax */
    if (expression->kind == NODE_ADD) {
        byte(text, UINT8_C(0x01));
        byte(text, UINT8_C(0xc8)); /* add eax, ecx */
    } else {
        byte(text, UINT8_C(0x0f));
        byte(text, UINT8_C(0xaf));
        byte(text, UINT8_C(0xc1)); /* imul eax, ecx */
    }
    byte(text, UINT8_C(0x50)); /* push result */
}

static void x64_mov_r32_imm32(Bytes *text, uint8_t opcode, uint32_t value) {
    byte(text, opcode);
    u32_le(text, value);
}

static void x64_syscall(Bytes *text) {
    byte(text, UINT8_C(0x0f));
    byte(text, UINT8_C(0x05));
}

static size_t x64_diagnostic(
    Bytes *text,
    uint32_t length,
    uint32_t status
) {
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 1); /* write */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 2); /* stderr */
    byte(text, UINT8_C(0xbe)); /* mov esi, message address */
    size_t address_field = text->length;
    u32_le(text, 0);
    x64_mov_r32_imm32(text, UINT8_C(0xba), length);
    x64_syscall(text);
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 60); /* exit */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), status);
    x64_syscall(text);
    byte(text, UINT8_C(0x0f));
    byte(text, UINT8_C(0x0b)); /* ud2 */
    return address_field;
}

static void x64_patch_u32(Bytes *text, size_t field, uint32_t value) {
    if (field > text->length || text->length - field < 4) {
        fatal("x86-64 native Core u32 field is outside text");
    }
    for (unsigned index = 0; index < 4; ++index) {
        text->data[field + index] =
            (uint8_t)(value >> (index * 8));
    }
}

static void x64_emit(
    Bytes *text,
    const uint8_t *instructions,
    size_t length
) {
    for (size_t index = 0; index < length; ++index) {
        byte(text, instructions[index]);
    }
}

static size_t x64_local_jcc(
    Bytes *text,
    uint8_t condition
) {
    byte(text, UINT8_C(0x0f));
    byte(text, condition);
    size_t field = text->length;
    u32_le(text, 0);
    return field;
}

static size_t x64_local_jmp(Bytes *text) {
    byte(text, UINT8_C(0xe9));
    size_t field = text->length;
    u32_le(text, 0);
    return field;
}

static void x64_runtime(Bytes *text, X64Runtime *runtime) {
    if (!runtime->used) return;

    size_t allocate_at = text->length;
    byte(text, UINT8_C(0x89));
    byte(text, UINT8_C(0xfe)); /* mov esi, edi */
    byte(text, UINT8_C(0x81));
    byte(text, UINT8_C(0xfe)); /* cmp esi, 1 MiB */
    u32_le(text, UINT32_C(1) << 20);
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x87),
        &runtime->oom_jumps
    ); /* ja oom */
    x64_mov_r32_imm32(
        text,
        UINT8_C(0xbe),
        UINT32_C(1) << 20
    ); /* one fixed-size mmap chunk */
    byte(text, UINT8_C(0x31));
    byte(text, UINT8_C(0xff)); /* xor edi, edi */
    x64_mov_r32_imm32(
        text,
        UINT8_C(0xba),
        UINT32_C(0x3)
    ); /* PROT_READ | PROT_WRITE */
    byte(text, UINT8_C(0x41));
    byte(text, UINT8_C(0xba));
    u32_le(text, UINT32_C(0x22)); /* r10d = MAP_PRIVATE | MAP_ANONYMOUS */
    const uint8_t minus_one[] = {
        UINT8_C(0x49), UINT8_C(0xc7), UINT8_C(0xc0),
        UINT8_C(0xff), UINT8_C(0xff), UINT8_C(0xff), UINT8_C(0xff),
    };
    for (size_t index = 0; index < sizeof(minus_one); ++index) {
        byte(text, minus_one[index]); /* mov r8, -1 */
    }
    byte(text, UINT8_C(0x45));
    byte(text, UINT8_C(0x31));
    byte(text, UINT8_C(0xc9)); /* xor r9d, r9d */
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 9); /* mmap */
    x64_syscall(text);
    byte(text, UINT8_C(0x48));
    byte(text, UINT8_C(0x3d)); /* cmp rax, -4095 */
    u32_le(text, UINT32_C(0xfffff001));
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x83),
        &runtime->oom_jumps
    ); /* jae oom */
    byte(text, UINT8_C(0xc3)); /* ret */

    size_t text_length_at = text->length;
    const uint8_t text_length_open[] = {
        UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x17), /* mov rdx, [rdi] */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
        UINT8_C(0x31), UINT8_C(0xc0), /* xor eax, eax */
    };
    x64_emit(
        text,
        text_length_open,
        sizeof(text_length_open)
    );
    size_t text_length_loop = text->length;
    const uint8_t text_length_test[] = {
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xd2), /* test rdx, rdx */
    };
    x64_emit(text, text_length_test, sizeof(text_length_test));
    size_t text_length_done_jump =
        x64_local_jcc(text, UINT8_C(0x84)); /* je done */
    const uint8_t text_length_byte[] = {
        UINT8_C(0x0f), UINT8_C(0xb6), UINT8_C(0x0f), /* movzx ecx, [rdi] */
        UINT8_C(0x80), UINT8_C(0xe1), UINT8_C(0xc0), /* and cl, 0xc0 */
        UINT8_C(0x80), UINT8_C(0xf9), UINT8_C(0x80), /* cmp cl, 0x80 */
    };
    x64_emit(text, text_length_byte, sizeof(text_length_byte));
    size_t text_length_skip_jump =
        x64_local_jcc(text, UINT8_C(0x84)); /* je skip */
    const uint8_t text_length_increment[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc0), /* inc rax */
    };
    x64_emit(
        text,
        text_length_increment,
        sizeof(text_length_increment)
    );
    size_t text_length_skip = text->length;
    const uint8_t text_length_next[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc7), /* inc rdi */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xca), /* dec rdx */
    };
    x64_emit(text, text_length_next, sizeof(text_length_next));
    size_t text_length_back = x64_local_jmp(text);
    size_t text_length_done = text->length;
    byte(text, UINT8_C(0xc3)); /* ret */
    x64_patch_rel32(text, text_length_done_jump, text_length_done);
    x64_patch_rel32(text, text_length_skip_jump, text_length_skip);
    x64_patch_rel32(text, text_length_back, text_length_loop);

    size_t text_equal_at = text->length;
    const uint8_t text_equal_open[] = {
        UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x17), /* mov rdx, [rdi] */
        UINT8_C(0x48), UINT8_C(0x3b), UINT8_C(0x16), /* cmp rdx, [rsi] */
    };
    x64_emit(text, text_equal_open, sizeof(text_equal_open));
    size_t text_equal_false_length =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne false */
    const uint8_t text_equal_data[] = {
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc6), UINT8_C(0x08),
    };
    x64_emit(text, text_equal_data, sizeof(text_equal_data));
    size_t text_equal_loop = text->length;
    const uint8_t text_equal_test[] = {
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xd2), /* test rdx, rdx */
    };
    x64_emit(text, text_equal_test, sizeof(text_equal_test));
    size_t text_equal_true_jump =
        x64_local_jcc(text, UINT8_C(0x84)); /* je true */
    const uint8_t text_equal_byte[] = {
        UINT8_C(0x8a), UINT8_C(0x07), /* mov al, [rdi] */
        UINT8_C(0x3a), UINT8_C(0x06), /* cmp al, [rsi] */
    };
    x64_emit(text, text_equal_byte, sizeof(text_equal_byte));
    size_t text_equal_false_byte =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne false */
    const uint8_t text_equal_next[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc7), /* inc rdi */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc6), /* inc rsi */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xca), /* dec rdx */
    };
    x64_emit(text, text_equal_next, sizeof(text_equal_next));
    size_t text_equal_back = x64_local_jmp(text);
    size_t text_equal_true = text->length;
    x64_mov_eax_imm32(text, 1);
    byte(text, UINT8_C(0xc3)); /* ret */
    size_t text_equal_false = text->length;
    byte(text, UINT8_C(0x31));
    byte(text, UINT8_C(0xc0)); /* xor eax, eax */
    byte(text, UINT8_C(0xc3)); /* ret */
    x64_patch_rel32(text, text_equal_false_length, text_equal_false);
    x64_patch_rel32(text, text_equal_true_jump, text_equal_true);
    x64_patch_rel32(text, text_equal_false_byte, text_equal_false);
    x64_patch_rel32(text, text_equal_back, text_equal_loop);

    size_t text_concat_at = text->length;
    const uint8_t text_concat_open[] = {
        UINT8_C(0x53),                         /* push rbx */
        UINT8_C(0x41), UINT8_C(0x54),         /* push r12 */
        UINT8_C(0x41), UINT8_C(0x55),         /* push r13 */
        UINT8_C(0x41), UINT8_C(0x56),         /* push r14 */
        UINT8_C(0x41), UINT8_C(0x57),         /* push r15 */
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xfb), /* rbx = rdi */
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xf4), /* r12 = rsi */
        UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x2b), /* r13 = [rbx] */
        UINT8_C(0x4d), UINT8_C(0x8b), UINT8_C(0x34), UINT8_C(0x24),
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xef), /* rdi = r13 */
        UINT8_C(0x4c), UINT8_C(0x01), UINT8_C(0xf7), /* rdi += r14 */
    };
    x64_emit(text, text_concat_open, sizeof(text_concat_open));
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x82),
        &runtime->oom_jumps
    ); /* jc oom on byte-length overflow */
    const uint8_t text_concat_header_size[] = {
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
    };
    x64_emit(
        text,
        text_concat_header_size,
        sizeof(text_concat_header_size)
    );
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x82),
        &runtime->oom_jumps
    ); /* jc oom on object-header overflow */
    x64_call_alloc(text, runtime);
    const uint8_t text_concat_header[] = {
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xc7), /* r15 = rax */
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xe9), /* rcx = r13 */
        UINT8_C(0x4c), UINT8_C(0x01), UINT8_C(0xf1), /* rcx += r14 */
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0x0f), /* [r15] = rcx */
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xff), /* rdi = r15 */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xde), /* rsi = rbx */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc6), UINT8_C(0x08),
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xea), /* rdx = r13 */
    };
    x64_emit(text, text_concat_header, sizeof(text_concat_header));
    size_t concat_left_test = text->length;
    const uint8_t concat_test[] = {
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xd2),
    };
    x64_emit(text, concat_test, sizeof(concat_test));
    size_t concat_left_done =
        x64_local_jcc(text, UINT8_C(0x84)); /* je right */
    const uint8_t concat_copy[] = {
        UINT8_C(0x8a), UINT8_C(0x06), /* mov al, [rsi] */
        UINT8_C(0x88), UINT8_C(0x07), /* mov [rdi], al */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc6),
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc7),
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xca),
    };
    x64_emit(text, concat_copy, sizeof(concat_copy));
    size_t concat_left_back = x64_local_jmp(text);
    size_t concat_right = text->length;
    const uint8_t concat_right_open[] = {
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xe6), /* rsi = r12 */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc6), UINT8_C(0x08),
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xf2), /* rdx = r14 */
    };
    x64_emit(text, concat_right_open, sizeof(concat_right_open));
    size_t concat_right_test = text->length;
    x64_emit(text, concat_test, sizeof(concat_test));
    size_t concat_right_done =
        x64_local_jcc(text, UINT8_C(0x84)); /* je done */
    x64_emit(text, concat_copy, sizeof(concat_copy));
    size_t concat_right_back = x64_local_jmp(text);
    size_t concat_done = text->length;
    const uint8_t text_concat_close[] = {
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xf8), /* rax = r15 */
        UINT8_C(0x41), UINT8_C(0x5f),
        UINT8_C(0x41), UINT8_C(0x5e),
        UINT8_C(0x41), UINT8_C(0x5d),
        UINT8_C(0x41), UINT8_C(0x5c),
        UINT8_C(0x5b),
        UINT8_C(0xc3),
    };
    x64_emit(text, text_concat_close, sizeof(text_concat_close));
    x64_patch_rel32(text, concat_left_done, concat_right);
    x64_patch_rel32(text, concat_left_back, concat_left_test);
    x64_patch_rel32(text, concat_right_done, concat_done);
    x64_patch_rel32(text, concat_right_back, concat_right_test);

    size_t text_index_at = text->length;
    const uint8_t text_index_open[] = {
        UINT8_C(0x53),
        UINT8_C(0x41), UINT8_C(0x54),
        UINT8_C(0x41), UINT8_C(0x55),
        UINT8_C(0x41), UINT8_C(0x56),
        UINT8_C(0x41), UINT8_C(0x57),
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xfb), /* rbx = Text */
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xf4), /* r12 = index */
        UINT8_C(0x4d), UINT8_C(0x85), UINT8_C(0xe4), /* test r12, r12 */
    };
    x64_emit(text, text_index_open, sizeof(text_index_open));
    size_t text_index_nonnegative =
        x64_local_jcc(text, UINT8_C(0x89)); /* jns */
    const uint8_t text_index_length_arg[] = {
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xdf), /* rdi = rbx */
        UINT8_C(0xe8),
    };
    x64_emit(
        text,
        text_index_length_arg,
        sizeof(text_index_length_arg)
    );
    size_t text_index_length_call = text->length;
    u32_le(text, 0);
    x64_patch_rel32(text, text_index_length_call, text_length_at);
    const uint8_t text_index_adjust[] = {
        UINT8_C(0x49), UINT8_C(0x01), UINT8_C(0xc4), /* r12 += rax */
    };
    x64_emit(text, text_index_adjust, sizeof(text_index_adjust));
    size_t text_index_nonnegative_at = text->length;
    x64_patch_rel32(
        text,
        text_index_nonnegative,
        text_index_nonnegative_at
    );
    const uint8_t text_index_negative_test[] = {
        UINT8_C(0x4d), UINT8_C(0x85), UINT8_C(0xe4),
    };
    x64_emit(
        text,
        text_index_negative_test,
        sizeof(text_index_negative_test)
    );
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x88),
        &runtime->text_index_jumps
    ); /* js Text index error */
    const uint8_t text_index_scan_open[] = {
        UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x2b), /* r13 = byte len */
        UINT8_C(0x4c), UINT8_C(0x8d), UINT8_C(0x73), UINT8_C(0x08),
        UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xff), /* r15 = cp index */
    };
    x64_emit(text, text_index_scan_open, sizeof(text_index_scan_open));
    size_t text_index_scan = text->length;
    const uint8_t text_index_remaining_test[] = {
        UINT8_C(0x4d), UINT8_C(0x85), UINT8_C(0xed),
    };
    x64_emit(
        text,
        text_index_remaining_test,
        sizeof(text_index_remaining_test)
    );
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x84),
        &runtime->text_index_jumps
    ); /* je Text index error */
    const uint8_t text_index_compare[] = {
        UINT8_C(0x4d), UINT8_C(0x39), UINT8_C(0xe7), /* cmp r15, r12 */
    };
    x64_emit(text, text_index_compare, sizeof(text_index_compare));
    size_t text_index_found =
        x64_local_jcc(text, UINT8_C(0x84)); /* je found */
    const uint8_t text_index_advance[] = {
        UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xc6), /* inc r14 */
        UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xcd), /* dec r13 */
    };
    x64_emit(text, text_index_advance, sizeof(text_index_advance));
    size_t text_index_continuation = text->length;
    x64_emit(
        text,
        text_index_remaining_test,
        sizeof(text_index_remaining_test)
    );
    size_t text_index_next_cp =
        x64_local_jcc(text, UINT8_C(0x84)); /* je next cp */
    const uint8_t text_index_cont_byte[] = {
        UINT8_C(0x41), UINT8_C(0x0f), UINT8_C(0xb6), UINT8_C(0x06),
        UINT8_C(0x24), UINT8_C(0xc0), /* and al, 0xc0 */
        UINT8_C(0x3c), UINT8_C(0x80), /* cmp al, 0x80 */
    };
    x64_emit(text, text_index_cont_byte, sizeof(text_index_cont_byte));
    size_t text_index_not_cont =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne next cp */
    x64_emit(text, text_index_advance, sizeof(text_index_advance));
    size_t text_index_cont_back = x64_local_jmp(text);
    size_t text_index_next_cp_at = text->length;
    const uint8_t text_index_cp_increment[] = {
        UINT8_C(0x49), UINT8_C(0xff), UINT8_C(0xc7), /* inc r15 */
    };
    x64_emit(
        text,
        text_index_cp_increment,
        sizeof(text_index_cp_increment)
    );
    size_t text_index_scan_back = x64_local_jmp(text);
    size_t text_index_found_at = text->length;
    const uint8_t text_index_width_open[] = {
        UINT8_C(0x41), UINT8_C(0xbf),
        UINT8_C(0x01), UINT8_C(0x00), UINT8_C(0x00), UINT8_C(0x00),
    };
    x64_emit(text, text_index_width_open, sizeof(text_index_width_open));
    size_t text_index_width = text->length;
    const uint8_t text_index_width_compare[] = {
        UINT8_C(0x4d), UINT8_C(0x39), UINT8_C(0xef), /* cmp r15, r13 */
    };
    x64_emit(
        text,
        text_index_width_compare,
        sizeof(text_index_width_compare)
    );
    size_t text_index_width_done =
        x64_local_jcc(text, UINT8_C(0x8d)); /* jge */
    const uint8_t text_index_width_byte[] = {
        UINT8_C(0x43), UINT8_C(0x0f), UINT8_C(0xb6),
        UINT8_C(0x04), UINT8_C(0x3e), /* byte [r14 + r15] */
        UINT8_C(0x24), UINT8_C(0xc0),
        UINT8_C(0x3c), UINT8_C(0x80),
    };
    x64_emit(
        text,
        text_index_width_byte,
        sizeof(text_index_width_byte)
    );
    size_t text_index_width_not_cont =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne done */
    x64_emit(
        text,
        text_index_cp_increment,
        sizeof(text_index_cp_increment)
    );
    size_t text_index_width_back = x64_local_jmp(text);
    size_t text_index_width_done_at = text->length;
    const uint8_t text_index_allocate_size[] = {
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xff), /* rdi = width */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
    };
    x64_emit(
        text,
        text_index_allocate_size,
        sizeof(text_index_allocate_size)
    );
    x64_call_alloc(text, runtime);
    const uint8_t text_index_copy_open[] = {
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0x38), /* [rax] = width */
        UINT8_C(0x48), UINT8_C(0x8d), UINT8_C(0x78), UINT8_C(0x08),
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xf6), /* rsi = start */
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xfa), /* rdx = width */
    };
    x64_emit(
        text,
        text_index_copy_open,
        sizeof(text_index_copy_open)
    );
    size_t text_index_copy = text->length;
    x64_emit(text, concat_test, sizeof(concat_test));
    size_t text_index_copy_done =
        x64_local_jcc(text, UINT8_C(0x84));
    const uint8_t text_index_copy_byte[] = {
        UINT8_C(0x8a), UINT8_C(0x0e), /* mov cl, [rsi] */
        UINT8_C(0x88), UINT8_C(0x0f), /* mov [rdi], cl */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc6),
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc7),
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xca),
    };
    x64_emit(
        text,
        text_index_copy_byte,
        sizeof(text_index_copy_byte)
    );
    size_t text_index_copy_back = x64_local_jmp(text);
    size_t text_index_copy_done_at = text->length;
    const uint8_t text_index_close[] = {
        UINT8_C(0x41), UINT8_C(0x5f),
        UINT8_C(0x41), UINT8_C(0x5e),
        UINT8_C(0x41), UINT8_C(0x5d),
        UINT8_C(0x41), UINT8_C(0x5c),
        UINT8_C(0x5b),
        UINT8_C(0xc3),
    };
    x64_emit(text, text_index_close, sizeof(text_index_close));
    x64_patch_rel32(text, text_index_found, text_index_found_at);
    x64_patch_rel32(text, text_index_next_cp, text_index_next_cp_at);
    x64_patch_rel32(text, text_index_not_cont, text_index_next_cp_at);
    x64_patch_rel32(
        text,
        text_index_cont_back,
        text_index_continuation
    );
    x64_patch_rel32(text, text_index_scan_back, text_index_scan);
    x64_patch_rel32(
        text,
        text_index_width_done,
        text_index_width_done_at
    );
    x64_patch_rel32(
        text,
        text_index_width_not_cont,
        text_index_width_done_at
    );
    x64_patch_rel32(text, text_index_width_back, text_index_width);
    x64_patch_rel32(
        text,
        text_index_copy_done,
        text_index_copy_done_at
    );
    x64_patch_rel32(text, text_index_copy_back, text_index_copy);

    size_t text_chars_at = text->length;
    const uint8_t text_chars_open[] = {
        UINT8_C(0x55),                         /* push rbp */
        UINT8_C(0x53),                         /* push rbx */
        UINT8_C(0x41), UINT8_C(0x54),
        UINT8_C(0x41), UINT8_C(0x55),
        UINT8_C(0x41), UINT8_C(0x56),
        UINT8_C(0x41), UINT8_C(0x57),
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xfb), /* rbx = Text */
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xdf), /* rdi = Text */
        UINT8_C(0xe8),
    };
    x64_emit(text, text_chars_open, sizeof(text_chars_open));
    size_t text_chars_length_call = text->length;
    u32_le(text, 0);
    x64_patch_rel32(text, text_chars_length_call, text_length_at);
    const uint8_t text_chars_allocate_list[] = {
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xc4), /* r12 = count */
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xe7), /* rdi = count */
        UINT8_C(0x48), UINT8_C(0xc1), UINT8_C(0xe7), UINT8_C(0x03),
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
    };
    x64_emit(
        text,
        text_chars_allocate_list,
        sizeof(text_chars_allocate_list)
    );
    x64_call_alloc(text, runtime);
    const uint8_t text_chars_list_header[] = {
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0xc5), /* r13 = list */
        UINT8_C(0x4d), UINT8_C(0x89), UINT8_C(0x65), UINT8_C(0x00),
        UINT8_C(0x4c), UINT8_C(0x8d), UINT8_C(0x73), UINT8_C(0x08),
        UINT8_C(0x4c), UINT8_C(0x8b), UINT8_C(0x3b), /* r15 = bytes */
        UINT8_C(0x31), UINT8_C(0xed), /* ebp = element index */
    };
    x64_emit(
        text,
        text_chars_list_header,
        sizeof(text_chars_list_header)
    );
    size_t text_chars_loop = text->length;
    const uint8_t text_chars_remaining_test[] = {
        UINT8_C(0x4d), UINT8_C(0x85), UINT8_C(0xff), /* test r15, r15 */
    };
    x64_emit(
        text,
        text_chars_remaining_test,
        sizeof(text_chars_remaining_test)
    );
    size_t text_chars_done =
        x64_local_jcc(text, UINT8_C(0x84)); /* je done */
    x64_mov_r32_imm32(text, UINT8_C(0xbb), 1); /* ebx = width */
    size_t text_chars_width = text->length;
    const uint8_t text_chars_width_compare[] = {
        UINT8_C(0x4c), UINT8_C(0x39), UINT8_C(0xfb), /* cmp rbx, r15 */
    };
    x64_emit(
        text,
        text_chars_width_compare,
        sizeof(text_chars_width_compare)
    );
    size_t text_chars_width_done =
        x64_local_jcc(text, UINT8_C(0x8d)); /* jge */
    const uint8_t text_chars_width_byte[] = {
        UINT8_C(0x41), UINT8_C(0x0f), UINT8_C(0xb6),
        UINT8_C(0x04), UINT8_C(0x1e), /* byte [r14 + rbx] */
        UINT8_C(0x24), UINT8_C(0xc0),
        UINT8_C(0x3c), UINT8_C(0x80),
    };
    x64_emit(
        text,
        text_chars_width_byte,
        sizeof(text_chars_width_byte)
    );
    size_t text_chars_not_cont =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne width done */
    const uint8_t text_chars_width_increment[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc3), /* inc rbx */
    };
    x64_emit(
        text,
        text_chars_width_increment,
        sizeof(text_chars_width_increment)
    );
    size_t text_chars_width_back = x64_local_jmp(text);
    size_t text_chars_width_done_at = text->length;
    const uint8_t text_chars_allocate_text[] = {
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xdf), /* rdi = width */
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xc7), UINT8_C(0x08),
    };
    x64_emit(
        text,
        text_chars_allocate_text,
        sizeof(text_chars_allocate_text)
    );
    x64_call_alloc(text, runtime);
    const uint8_t text_chars_store[] = {
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0x18), /* [rax] = width */
        UINT8_C(0x49), UINT8_C(0x89), UINT8_C(0x44),
        UINT8_C(0xed), UINT8_C(0x08), /* list[rbp] = rax */
        UINT8_C(0x48), UINT8_C(0x8d), UINT8_C(0x78), UINT8_C(0x08),
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xf6), /* rsi = cursor */
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xda), /* rdx = width */
    };
    x64_emit(text, text_chars_store, sizeof(text_chars_store));
    size_t text_chars_copy = text->length;
    x64_emit(text, concat_test, sizeof(concat_test));
    size_t text_chars_copy_done =
        x64_local_jcc(text, UINT8_C(0x84));
    x64_emit(
        text,
        text_index_copy_byte,
        sizeof(text_index_copy_byte)
    );
    size_t text_chars_copy_back = x64_local_jmp(text);
    size_t text_chars_copy_done_at = text->length;
    const uint8_t text_chars_next[] = {
        UINT8_C(0x49), UINT8_C(0x01), UINT8_C(0xde), /* r14 += rbx */
        UINT8_C(0x49), UINT8_C(0x29), UINT8_C(0xdf), /* r15 -= rbx */
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xc5), /* inc rbp */
    };
    x64_emit(text, text_chars_next, sizeof(text_chars_next));
    size_t text_chars_back = x64_local_jmp(text);
    size_t text_chars_done_at = text->length;
    const uint8_t text_chars_close[] = {
        UINT8_C(0x4c), UINT8_C(0x89), UINT8_C(0xe8), /* rax = list */
        UINT8_C(0x41), UINT8_C(0x5f),
        UINT8_C(0x41), UINT8_C(0x5e),
        UINT8_C(0x41), UINT8_C(0x5d),
        UINT8_C(0x41), UINT8_C(0x5c),
        UINT8_C(0x5b),
        UINT8_C(0x5d),
        UINT8_C(0xc3),
    };
    x64_emit(text, text_chars_close, sizeof(text_chars_close));
    x64_patch_rel32(text, text_chars_done, text_chars_done_at);
    x64_patch_rel32(
        text,
        text_chars_width_done,
        text_chars_width_done_at
    );
    x64_patch_rel32(
        text,
        text_chars_not_cont,
        text_chars_width_done_at
    );
    x64_patch_rel32(text, text_chars_width_back, text_chars_width);
    x64_patch_rel32(
        text,
        text_chars_copy_done,
        text_chars_copy_done_at
    );
    x64_patch_rel32(text, text_chars_copy_back, text_chars_copy);
    x64_patch_rel32(text, text_chars_back, text_chars_loop);

    size_t oom_at = text->length;
    const char oom_message[] = "kofun: out of memory\n";
    size_t oom_address = x64_diagnostic(
        text,
        (uint32_t)(sizeof(oom_message) - 1),
        70
    );

    size_t list_index_at = text->length;
    const char list_index_message[] =
        "kofun: list index out of range\n";
    size_t list_index_address = x64_diagnostic(
        text,
        (uint32_t)(sizeof(list_index_message) - 1),
        1
    );

    size_t text_index_error_at = text->length;
    const char text_index_message[] =
        "kofun: text index out of range\n";
    size_t text_index_address = x64_diagnostic(
        text,
        (uint32_t)(sizeof(text_index_message) - 1),
        1
    );

    size_t oom_message_at = text->length;
    for (size_t index = 0; index < sizeof(oom_message) - 1; ++index) {
        byte(text, (uint8_t)oom_message[index]);
    }
    size_t list_index_message_at = text->length;
    for (
        size_t index = 0;
        index < sizeof(list_index_message) - 1;
        ++index
    ) {
        byte(text, (uint8_t)list_index_message[index]);
    }
    size_t text_index_message_at = text->length;
    for (
        size_t index = 0;
        index < sizeof(text_index_message) - 1;
        ++index
    ) {
        byte(text, (uint8_t)text_index_message[index]);
    }
    size_t newline_at = text->length;
    byte(text, '\n');
    size_t bool_true_at = text->length;
    const char bool_true[] = "true\n";
    x64_emit(
        text,
        (const uint8_t *)bool_true,
        sizeof(bool_true) - 1
    );
    size_t bool_false_at = text->length;
    const char bool_false[] = "false\n";
    x64_emit(
        text,
        (const uint8_t *)bool_false,
        sizeof(bool_false) - 1
    );

    for (size_t index = 0; index < runtime->alloc_calls.length; ++index) {
        x64_patch_rel32(
            text,
            runtime->alloc_calls.fields[index],
            allocate_at
        );
    }
    for (size_t index = 0; index < runtime->oom_jumps.length; ++index) {
        x64_patch_rel32(
            text,
            runtime->oom_jumps.fields[index],
            oom_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->list_index_jumps.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->list_index_jumps.fields[index],
            list_index_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_index_jumps.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_index_jumps.fields[index],
            text_index_error_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_concat_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_concat_calls.fields[index],
            text_concat_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_equal_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_equal_calls.fields[index],
            text_equal_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_length_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_length_calls.fields[index],
            text_length_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_index_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_index_calls.fields[index],
            text_index_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_chars_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            runtime->text_chars_calls.fields[index],
            text_chars_at
        );
    }
    x64_patch_u32(
        text,
        oom_address,
        (uint32_t)(IMAGE_BASE + TEXT_OFFSET + oom_message_at)
    );
    x64_patch_u32(
        text,
        list_index_address,
        (uint32_t)(
            IMAGE_BASE + TEXT_OFFSET + list_index_message_at
        )
    );
    x64_patch_u32(
        text,
        text_index_address,
        (uint32_t)(
            IMAGE_BASE + TEXT_OFFSET + text_index_message_at
        )
    );
    for (
        size_t index = 0;
        index < runtime->newline_addresses.length;
        ++index
    ) {
        x64_patch_u32(
            text,
            runtime->newline_addresses.fields[index],
            (uint32_t)(IMAGE_BASE + TEXT_OFFSET + newline_at)
        );
    }
    for (
        size_t index = 0;
        index < runtime->bool_true_addresses.length;
        ++index
    ) {
        x64_patch_u32(
            text,
            runtime->bool_true_addresses.fields[index],
            (uint32_t)(IMAGE_BASE + TEXT_OFFSET + bool_true_at)
        );
    }
    for (
        size_t index = 0;
        index < runtime->bool_false_addresses.length;
        ++index
    ) {
        x64_patch_u32(
            text,
            runtime->bool_false_addresses.fields[index],
            (uint32_t)(IMAGE_BASE + TEXT_OFFSET + bool_false_at)
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_literals.length;
        ++index
    ) {
        while (text->length % sizeof(uint64_t) != 0) byte(text, 0);
        size_t literal_at = text->length;
        TextFixup literal = runtime->text_literals.items[index];
        u64_le(text, (uint64_t)literal.length);
        x64_emit(text, literal.value, literal.length);
        x64_patch_u32(
            text,
            runtime->text_literals.items[index].field,
            (uint32_t)(IMAGE_BASE + TEXT_OFFSET + literal_at)
        );
    }
}

static void x64_text(
    Bytes *text,
    const Node *expression,
    LineRows *rows,
    size_t print_line,
    size_t local_count
) {
    X64Runtime runtime = {0};
    if (local_count > 0) {
        if (local_count > UINT32_MAX / sizeof(uint64_t)) {
            fatal("x86-64 Core local frame is too large");
        }
        const uint8_t frame_open[] = {
            UINT8_C(0x55),                         /* push rbp */
            UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xe5),
            UINT8_C(0x48), UINT8_C(0x81), UINT8_C(0xec),
        };
        x64_emit(text, frame_open, sizeof(frame_open));
        u32_le(text, (uint32_t)(local_count * sizeof(uint64_t)));
    }
    x64_expression(text, expression, rows, &runtime);
    line_row(rows, text->length, print_line);
    byte(text, UINT8_C(0x58)); /* pop rax */

    if (expression->value_kind == VALUE_INT) {
        byte(text, UINT8_C(0x31));
        byte(text, UINT8_C(0xd2)); /* xor edx, edx */
        x64_mov_r32_imm32(text, UINT8_C(0xb9), 10); /* mov ecx, 10 */
        byte(text, UINT8_C(0xf7));
        byte(text, UINT8_C(0xf1)); /* div ecx */
        byte(text, UINT8_C(0x04));
        byte(text, UINT8_C(48)); /* add al, '0' */
        byte(text, UINT8_C(0x80));
        byte(text, UINT8_C(0xc2));
        byte(text, UINT8_C(48)); /* add dl, '0' */

        const uint8_t tens[] = {
            UINT8_C(0x88), UINT8_C(0x04), UINT8_C(0x25),
            UINT8_C(0x00), UINT8_C(0x10), UINT8_C(0x40), UINT8_C(0x00),
        };
        const uint8_t ones[] = {
            UINT8_C(0x88), UINT8_C(0x14), UINT8_C(0x25),
            UINT8_C(0x01), UINT8_C(0x10), UINT8_C(0x40), UINT8_C(0x00),
        };
        for (size_t index = 0; index < sizeof(tens); ++index) {
            byte(text, tens[index]);
        }
        for (size_t index = 0; index < sizeof(ones); ++index) {
            byte(text, ones[index]);
        }

        x64_mov_r32_imm32(text, UINT8_C(0xb8), 1); /* write */
        x64_mov_r32_imm32(text, UINT8_C(0xbf), 1); /* stdout */
        x64_mov_r32_imm32(
            text, UINT8_C(0xbe), (uint32_t)DATA_ADDRESS
        );
        x64_mov_r32_imm32(text, UINT8_C(0xba), 3);
        x64_syscall(text);
    } else if (expression->value_kind == VALUE_TEXT) {
        runtime.used = true;
        const uint8_t text_output[] = {
            UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x10),
            UINT8_C(0x48), UINT8_C(0x8d), UINT8_C(0x70), UINT8_C(0x08),
        };
        x64_emit(text, text_output, sizeof(text_output));
        x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
        x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
        x64_syscall(text);
        x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
        x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
        byte(text, UINT8_C(0xbe));
        offsets_add(&runtime.newline_addresses, text->length);
        u32_le(text, 0);
        x64_mov_r32_imm32(text, UINT8_C(0xba), 1);
        x64_syscall(text);
    } else {
        runtime.used = true;
        byte(text, UINT8_C(0x48));
        byte(text, UINT8_C(0x85));
        byte(text, UINT8_C(0xc0)); /* test rax, rax */
        size_t false_jump =
            x64_local_jcc(text, UINT8_C(0x84)); /* je false */
        x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
        x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
        byte(text, UINT8_C(0xbe));
        offsets_add(&runtime.bool_true_addresses, text->length);
        u32_le(text, 0);
        x64_mov_r32_imm32(text, UINT8_C(0xba), 5);
        x64_syscall(text);
        size_t bool_done = x64_local_jmp(text);
        size_t bool_false = text->length;
        x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
        x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
        byte(text, UINT8_C(0xbe));
        offsets_add(&runtime.bool_false_addresses, text->length);
        u32_le(text, 0);
        x64_mov_r32_imm32(text, UINT8_C(0xba), 6);
        x64_syscall(text);
        size_t bool_done_at = text->length;
        x64_patch_rel32(text, false_jump, bool_false);
        x64_patch_rel32(text, bool_done, bool_done_at);
    }
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 60); /* exit */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 0);
    x64_syscall(text);
    x64_runtime(text, &runtime);
    x64_runtime_free(&runtime);
}

typedef struct {
    size_t field;
    size_t function_index;
} FunctionCallFixup;

typedef struct {
    FunctionCallFixup *items;
    size_t length;
    size_t capacity;
} FunctionCallFixups;

typedef struct {
    size_t low_field;
    size_t high_field;
    const uint8_t *value;
    size_t length;
} A64TextFixup;

typedef struct {
    A64TextFixup *items;
    size_t length;
    size_t capacity;
} A64TextFixups;

typedef struct {
    bool used;
    Offsets allocate_calls;
    Offsets oom_jumps;
    Offsets list_index_jumps;
    Offsets text_index_jumps;
    Offsets text_concat_calls;
    Offsets text_equal_calls;
    Offsets text_length_calls;
    Offsets text_index_calls;
    Offsets text_chars_calls;
    A64TextFixups text_literals;
} A64CoreRuntime;

/*
 * The AArch64 Text runtime and its helpers are defined below, alongside the
 * aggregate Core lowerer. The shared function emitter and the AArch64 function
 * lowerer above them reuse that runtime, so forward-declare what they call.
 */
static void a64_text_fixups_add(
    A64TextFixups *fixups,
    size_t low_field,
    size_t high_field,
    const uint8_t *value,
    size_t length
);
static void a64_core_call_runtime(
    Bytes *text,
    A64CoreRuntime *runtime,
    Offsets *calls
);
static void a64_core_runtime(Bytes *text, A64CoreRuntime *runtime);
static void a64_core_runtime_free(A64CoreRuntime *runtime);
static void a64_load_u64(
    Bytes *text,
    unsigned destination,
    unsigned address,
    unsigned offset
);
static void a64_load_address(
    Bytes *text,
    unsigned destination,
    uint64_t address
);

typedef struct {
    FunctionCallFixups calls;
    Offsets print_int_calls;
    Offsets print_text_calls;
    Offsets trap_jumps[FUNCTION_TRAP_COUNT];
    X64Runtime runtime;
    A64CoreRuntime a64_runtime;
} FunctionEmitter;

static void function_call_fixup_add(
    FunctionCallFixups *fixups,
    size_t field,
    size_t function_index
) {
    if (fixups->length == fixups->capacity) {
        size_t capacity =
            fixups->capacity == 0 ? 8 : fixups->capacity * 2;
        FunctionCallFixup *grown = realloc(
            fixups->items,
            capacity * sizeof(*fixups->items)
        );
        if (grown == NULL) fatal("out of memory");
        fixups->items = grown;
        fixups->capacity = capacity;
    }
    fixups->items[fixups->length++] = (FunctionCallFixup){
        .field = field,
        .function_index = function_index,
    };
}

static void function_emitter_free(FunctionEmitter *emitter) {
    free(emitter->calls.items);
    free(emitter->print_int_calls.fields);
    free(emitter->print_text_calls.fields);
    for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
        free(emitter->trap_jumps[kind].fields);
    }
    x64_runtime_free(&emitter->runtime);
    a64_core_runtime_free(&emitter->a64_runtime);
}

/*
 * Tail calls
 * ----------
 *
 * `return f(...)` leaves this frame nothing to do once `f` starts: `f`'s result
 * is this function's result, and every location this body owns is dead at that
 * point. Both backends therefore hand the frame over instead of stacking a
 * second one on top of it.
 *
 *   - a call to the enclosing function reuses the frame as it stands. The
 *     arguments are evaluated first, then assigned to the parameter locations,
 *     then control branches back to the first instruction after the prologue,
 *     so the repetition costs neither a frame nor a saved-register round trip;
 *   - a call to any other function restores what this body claimed and drops
 *     the frame before branching, so the callee runs on the frame this
 *     function was entered with and returns straight to this function's
 *     caller.
 *
 * Recursion written this way runs in constant stack on both targets, whether it
 * is direct or mutual. A call anywhere but a returned position, and a `return`
 * of anything but a direct call, is lowered exactly as before.
 */
static const FunctionExpression *function_tail_call(
    const FunctionStatement *statement
) {
    if (statement->kind != FUNCTION_STATEMENT_RETURN &&
        statement->kind != FUNCTION_STATEMENT_IF_RETURN) {
        return NULL;
    }
    if (statement->value == NULL) return NULL;
    if (statement->value->kind != FUNCTION_CALL) return NULL;
    return statement->value;
}

static void x64_function_call(
    Bytes *text,
    FunctionEmitter *emitter,
    size_t function_index
) {
    byte(text, UINT8_C(0xe8));
    function_call_fixup_add(
        &emitter->calls,
        text->length,
        function_index
    );
    u32_le(text, 0);
}

static void x64_function_overflow_jump(
    Bytes *text,
    FunctionEmitter *emitter,
    FunctionTrapKind kind
) {
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x80),
        &emitter->trap_jumps[kind]
    );
}

static void x64_function_divide_zero_jump(
    Bytes *text,
    FunctionEmitter *emitter,
    FunctionTrapKind kind
) {
    x64_rel32_placeholder(
        text,
        UINT8_C(0x0f),
        UINT8_C(0x84),
        &emitter->trap_jumps[kind]
    );
}

/*
 * The register file every target shares
 * -------------------------------------
 *
 * A target knows three things no target-independent code can derive: which
 * registers its ABI leaves caller-saved and free to use as scratch, which ones
 * the callee must preserve, and the value that means "no register". It declares
 * exactly those as a `TargetRegisterFile`, and the allocation policy below is
 * written once for every target that does.
 *
 * The policy is not new. x86-64 and AArch64 each carried their own copy of
 * these four functions, identical after the `X64_`/`A64_` prefixes were
 * normalised away, so the pair proved nothing: two spellings of one algorithm
 * cannot disagree. Per DD-022 a redundancy is worth keeping only when a gate
 * can turn it into evidence, and this one never could. The lowering pairs are a
 * different matter and stay duplicated; see `docs/NATIVE_BACKEND.md`.
 *
 * `taken` is indexed by architectural register number and is sized for the
 * widest register file any target declares, so one type serves a 16-register
 * and a 32-register target without either one reading the other's bounds.
 */
enum { MAX_TARGET_REGISTERS = 32 };

typedef struct {
    const unsigned *scratch;      /* caller-saved, never an argument register */
    size_t scratch_count;
    const unsigned *call_safe;    /* preserved across a call by the callee */
    size_t call_safe_count;
    unsigned no_register;         /* the target's "nothing was allocated" */
} TargetRegisterFile;

typedef struct {
    const TargetRegisterFile *target;
    bool taken[MAX_TARGET_REGISTERS];
} RegisterFile;

/*
 * The frame layout every target shares
 * ------------------------------------
 *
 * A layout is the allocator's answer for one function: which evaluation depths
 * and which bindings got a register, where the rest spill, and which
 * callee-saved registers the prologue must preserve. None of that is
 * target-specific; the counts are, and they come from the `TargetRegisterFile`
 * the layout was built against.
 *
 * The arrays are sized for the widest target that declares itself, the way
 * `taken[]` is, with a static assertion below so a target that outgrows them
 * fails to compile rather than writing past the end.
 *
 * `slot_register` is sized by `MAX_FUNCTION_FRAME_SLOTS`, which is the bound
 * the parser actually enforces. x86-64 used to size it by
 * `MAX_CORE_PARAMETERS + MAX_CORE_STATEMENTS` — 70 entries where 32 are
 * reachable, with an abort that could never fire. That was drift, not a design
 * choice, and unifying is what surfaced it.
 *
 * `frame_bytes` is per-function data, not per-target; x86-64 leaves it zero.
 */
enum {
    MAX_TARGET_ALLOCATABLE = 12,
    MAX_TARGET_CALL_SAFE = 8,
    MAX_TARGET_VALUE_SLOTS = MAX_FUNCTION_FRAME_SLOTS,
};

typedef struct {
    const TargetRegisterFile *target;
    size_t frame_slots;   /* parameters and locals, at their existing slots */
    size_t spill_slots;   /* evaluation depths that did not get a register */
    size_t eval_depth;    /* evaluation depths this body uses */
    uint32_t frame_bytes; /* the whole frame, rounded to 16 bytes */
    unsigned eval_register[MAX_TARGET_ALLOCATABLE];
    size_t eval_spill[MAX_TARGET_ALLOCATABLE];
    size_t deep_spill_base;
    unsigned slot_register[MAX_TARGET_VALUE_SLOTS];
    unsigned saved[MAX_TARGET_CALL_SAFE];
    size_t saved_count;
} FrameLayout;

static size_t target_allocatable_registers(const TargetRegisterFile *target) {
    return target->scratch_count + target->call_safe_count;
}

/*
 * The two materialisation helpers, written once. Both targets carried an
 * identical copy of each — identical after the prefixes and the abort label
 * were normalised away — so the pair proved nothing a gate could read.
 */
static Operand target_eval_operand(const FrameLayout *layout, size_t depth) {
    size_t allocatable = target_allocatable_registers(layout->target);
    if (depth >= layout->eval_depth) {
        fatal("native Core evaluation exceeds its analyzed depth");
    }
    if (depth < allocatable &&
        layout->eval_register[depth] != layout->target->no_register) {
        return target_register_operand(layout->eval_register[depth]);
    }
    size_t spill = depth < allocatable
        ? layout->eval_spill[depth]
        : layout->deep_spill_base + (depth - allocatable);
    return target_slot_operand(layout->frame_slots + spill);
}

static Operand target_value_operand(const FrameLayout *layout, size_t slot) {
    if (slot >= layout->frame_slots) {
        fatal("native Core binding is outside its frame");
    }
    if (layout->slot_register[slot] != layout->target->no_register) {
        return target_register_operand(layout->slot_register[slot]);
    }
    return target_slot_operand(slot);
}

static unsigned target_take_scratch_register(RegisterFile *file) {
    for (size_t index = 0; index < file->target->scratch_count; ++index) {
        unsigned reg = file->target->scratch[index];
        if (file->taken[reg]) continue;
        file->taken[reg] = true;
        return reg;
    }
    return file->target->no_register;
}

static unsigned target_take_call_safe_register(RegisterFile *file) {
    for (size_t index = 0; index < file->target->call_safe_count; ++index) {
        unsigned reg = file->target->call_safe[index];
        if (file->taken[reg]) continue;
        file->taken[reg] = true;
        return reg;
    }
    return file->target->no_register;
}

/*
 * An intermediate value that must survive a call can only live in the
 * callee-saved class; anything else prefers the scratch class, which needs no
 * save at all, and falls back to callee-saved rather than to memory.
 */
static unsigned target_take_eval_register(
    RegisterFile *file,
    bool across_calls
) {
    if (!across_calls) {
        unsigned scratch = target_take_scratch_register(file);
        if (scratch != file->target->no_register) return scratch;
    }
    return target_take_call_safe_register(file);
}

/*
 * A parameter or local is different: it is written once at entry and read
 * wherever it appears. A scratch register replaces that store and every reload
 * for free, but a callee-saved register also costs one save and one restore per
 * invocation, which only pays for itself once the binding is read more than
 * once. A binding that is never read gets nothing.
 */
static unsigned target_take_value_register(
    RegisterFile *file,
    bool across_calls,
    size_t uses
) {
    if (uses == 0) return file->target->no_register;
    if (!across_calls) {
        unsigned scratch = target_take_scratch_register(file);
        if (scratch != file->target->no_register) return scratch;
    }
    if (uses < 2) return file->target->no_register;
    return target_take_call_safe_register(file);
}

/*
 * Register allocation for the bounded function profile
 * ----------------------------------------------------
 *
 * Expression evaluation used to be a native-stack machine: every operand was
 * pushed and popped, so each intermediate value cost a memory round trip and
 * every parameter read reloaded its frame slot. Each function body now gets a
 * location assignment computed once, before any byte is emitted:
 *
 *   - an evaluation depth whose value is still live when a call runs takes a
 *     callee-saved register, so the callee preserves it and no caller-side
 *     save is needed;
 *   - a depth no call can observe takes a caller-saved register that is never
 *     an argument register, which avoids a save/restore pair entirely;
 *   - parameters and locals take the registers left over. They stay live
 *     across statements, so a body that calls anything needs the callee-saved
 *     class for them, and that class only pays for its save and restore once
 *     a binding is read more than once;
 *   - whatever does not fit spills to a deterministic frame slot below the
 *     locals, at the existing local displacements.
 *
 * `rax` and the six argument registers are never allocated, so they are always
 * free as scratch and as the call boundary. Allocation is driven only by depth
 * and slot index, so repeated builds of one source make identical decisions.
 * No evaluation step moves `rsp`, so a body keeps the 16-byte alignment it was
 * entered with at every SysV call boundary.
 */
enum {
    X64_CALL_SAFE_REGISTERS = 5,
    X64_SCRATCH_REGISTERS = 2,
    X64_ALLOCATABLE_REGISTERS =
        X64_CALL_SAFE_REGISTERS + X64_SCRATCH_REGISTERS,
};

static const unsigned x64_call_safe_registers[X64_CALL_SAFE_REGISTERS] = {
    X64_RBX, X64_R12, X64_R13, X64_R14, X64_R15,
};

static const unsigned x64_scratch_registers[X64_SCRATCH_REGISTERS] = {
    X64_R10, X64_R11,
};

static const unsigned x64_argument_registers[MAX_CORE_PARAMETERS] = {
    X64_RDI, X64_RSI, X64_RDX, X64_RCX, X64_R8, X64_R9,
};

/*
 * The Linux x86-64 kernel entry boundary, in the order `__linux_syscallN`
 * writes its values: the syscall number in `rax`, then the arguments in `rdi`,
 * `rsi`, `rdx`, `r10`, `r8`, `r9`.
 *
 * The fourth argument is `r10` and not the `rcx` the SysV call boundary above
 * uses. `syscall` overwrites `rcx` with the return address and `r11` with the
 * saved flags, so the kernel ABI moves that one argument out of the way. This
 * is the single place the two boundaries disagree.
 */
static const unsigned
x64_syscall_registers[FUNCTION_SYSCALL_MAX_ARGUMENTS] = {
    X64_RAX, X64_RDI, X64_RSI, X64_RDX, X64_R10, X64_R8, X64_R9,
};

/*
 * Which of those is also allocatable, and therefore the one boundary register
 * that can still hold a value the syscall is about to read. Filling it last
 * makes every other read happen first, so no argument is overwritten before it
 * is placed.
 */
enum {
    X64_SYSCALL_ALLOCATABLE_INDEX = 4,
};

static const TargetRegisterFile x64_register_file = {
    x64_scratch_registers,
    X64_SCRATCH_REGISTERS,
    x64_call_safe_registers,
    X64_CALL_SAFE_REGISTERS,
    X64_NO_REGISTER,
};


/*
 * The liveness analysis below is shared by both direct backends: it is
 * expressed over the parsed `FunctionExpression` and never mentions a register
 * or an encoding. Each target reads only the first `*_ALLOCATABLE_REGISTERS`
 * entries of the result, so one tracked width covers the larger register file
 * without changing what the smaller one decides.
 */
enum {
    FUNCTION_MAX_TRACKED_DEPTH = 16,
};

/*
 * True when evaluating this expression emits a call instruction.
 *
 * A syscall counts. `syscall` is not a `call`, but it destroys `rcx` and `r11`
 * exactly as a callee may, and `r11` is one of the two caller-saved registers
 * this allocator hands to evaluation depths. Reporting the intrinsic here is
 * what moves every value live across it into the callee-saved class, which the
 * kernel preserves; nothing else in the backend has to know the instruction
 * clobbers anything.
 */
static bool function_expression_calls(const FunctionExpression *expression) {
    if (expression == NULL) return false;
    if (expression->kind == FUNCTION_CALL) return true;
    if (expression->kind == FUNCTION_SYSCALL) return true;
    if (expression->kind == FUNCTION_TEXT_CONCAT) return true;
    if (function_expression_calls(expression->left)) return true;
    if (function_expression_calls(expression->right)) return true;
    for (size_t index = 0;
         expression->arguments != NULL &&
             index < expression->argument_count;
         ++index) {
        if (function_expression_calls(expression->arguments[index])) return true;
    }
    return false;
}

typedef struct {
    size_t depth;
    bool across_call[FUNCTION_MAX_TRACKED_DEPTH];
} FunctionPressure;

static void function_pressure_mark(
    FunctionPressure *pressure,
    size_t from,
    size_t to
) {
    for (size_t depth = from;
         depth < to && depth < FUNCTION_MAX_TRACKED_DEPTH;
         ++depth) {
        pressure->across_call[depth] = true;
    }
}

/*
 * Records how many evaluation depths a body needs and which of them can still
 * hold a live value when a call runs. A depth stays live exactly while the
 * sibling subtrees at deeper positions are evaluated: an operand is consumed
 * by its parent immediately afterwards, and a call boundary is filled from the
 * argument locations before the call, so nothing of a call's own node is live
 * across it. A depth therefore survives a call precisely when one of those
 * later sibling subtrees performs one.
 */
static void function_expression_pressure(
    const FunctionExpression *expression,
    size_t depth,
    FunctionPressure *pressure
) {
    if (expression == NULL) return;
    if (depth + 1 > pressure->depth) pressure->depth = depth + 1;
    switch (expression->kind) {
        case FUNCTION_LITERAL:
        case FUNCTION_TEXT_LITERAL:
        case FUNCTION_PARAMETER:
            return;
        case FUNCTION_NEGATE:
            function_expression_pressure(expression->left, depth, pressure);
            return;
        case FUNCTION_CALL:
        case FUNCTION_SYSCALL:
            for (size_t index = 0;
                 index < expression->argument_count;
                 ++index) {
                if (index > 0 &&
                    function_expression_calls(expression->arguments[index])) {
                    function_pressure_mark(pressure, depth, depth + index);
                }
                function_expression_pressure(
                    expression->arguments[index],
                    depth + index,
                    pressure
                );
            }
            return;
        default:
            function_expression_pressure(expression->left, depth, pressure);
            if (function_expression_calls(expression->right)) {
                function_pressure_mark(pressure, depth, depth + 1);
            }
            function_expression_pressure(
                expression->right,
                depth + 1,
                pressure
            );
            return;
    }
}

/* How many times this expression reads the given parameter or local. */
static size_t function_expression_slot_uses(
    const FunctionExpression *expression,
    size_t slot
) {
    if (expression == NULL) return 0;
    if (expression->kind == FUNCTION_PARAMETER) {
        return expression->slot == slot ? 1 : 0;
    }
    size_t uses = function_expression_slot_uses(expression->left, slot);
    uses += function_expression_slot_uses(expression->right, slot);
    for (size_t index = 0;
         expression->arguments != NULL &&
             index < expression->argument_count;
         ++index) {
        uses += function_expression_slot_uses(expression->arguments[index], slot);
    }
    return uses;
}

static size_t function_slot_uses(
    const FunctionDeclaration *function,
    size_t slot
) {
    size_t uses = 0;
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        uses += function_expression_slot_uses(statement->condition, slot);
        uses += function_expression_slot_uses(statement->value, slot);
    }
    return uses;
}

/*
 * True when the body reaches any call instruction, including the `print`
 * runtime, which clobbers caller-saved registers like any other callee.
 */
static bool function_body_calls(const FunctionDeclaration *function) {
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        if (statement->kind == FUNCTION_STATEMENT_PRINT) return true;
        if (function_expression_calls(statement->condition)) return true;
        if (function_expression_calls(statement->value)) return true;
    }
    return false;
}

static FrameLayout x64_function_layout(
    const FunctionDeclaration *function
) {
    FrameLayout layout = {0};
    layout.target = &x64_register_file;
    layout.frame_slots =
        function->parameter_count + function->local_count;
    if (layout.frame_slots > MAX_TARGET_VALUE_SLOTS) {
        fatal("x86-64 Core function has too many bindings");
    }
    for (size_t slot = 0; slot < MAX_TARGET_VALUE_SLOTS; ++slot) {
        layout.slot_register[slot] = X64_NO_REGISTER;
    }
    for (size_t depth = 0;
         depth < X64_ALLOCATABLE_REGISTERS;
         ++depth) {
        layout.eval_register[depth] = X64_NO_REGISTER;
    }

    FunctionPressure pressure = {0};
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        function_expression_pressure(statement->condition, 0, &pressure);
        function_expression_pressure(statement->value, 0, &pressure);
    }
    layout.eval_depth = pressure.depth;

    size_t tracked = pressure.depth < X64_ALLOCATABLE_REGISTERS
        ? pressure.depth
        : (size_t)X64_ALLOCATABLE_REGISTERS;
    RegisterFile file = { .target = &x64_register_file };
    /* Call-crossing depths claim the callee-saved class first: no other class
     * can hold them, while any other depth has an alternative. */
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (!pressure.across_call[depth]) continue;
        layout.eval_register[depth] = target_take_eval_register(&file, true);
    }
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (pressure.across_call[depth]) continue;
        layout.eval_register[depth] = target_take_eval_register(&file, false);
    }
    bool calls = function_body_calls(function);
    for (size_t slot = 0; slot < layout.frame_slots; ++slot) {
        layout.slot_register[slot] = target_take_value_register(
            &file,
            calls,
            function_slot_uses(function, slot)
        );
    }
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (layout.eval_register[depth] != X64_NO_REGISTER) continue;
        layout.eval_spill[depth] = layout.spill_slots++;
    }
    layout.deep_spill_base = layout.spill_slots;
    if (pressure.depth > X64_ALLOCATABLE_REGISTERS) {
        layout.spill_slots +=
            pressure.depth - (size_t)X64_ALLOCATABLE_REGISTERS;
    }
    for (size_t index = 0; index < X64_CALL_SAFE_REGISTERS; ++index) {
        unsigned reg = x64_call_safe_registers[index];
        if (!file.taken[reg]) continue;
        layout.saved[layout.saved_count++] = reg;
    }
    return layout;
}

/* Where the value produced at `depth` lives: a register or a spill slot. */

/* Where a parameter or local lives: a register or its existing frame slot. */

static Operand x64_saved_operand(
    const FrameLayout *layout,
    size_t index
) {
    return target_slot_operand(
        layout->frame_slots + layout->spill_slots + index
    );
}

/*
 * Moves one 64-bit value between two locations. `rax` is never allocated, so
 * it is always available when both locations are frame slots.
 */
static void x64_move(Bytes *text, Operand into, Operand from) {
    if (into.in_register && from.in_register &&
        into.reg == from.reg) {
        return;
    }
    if (into.in_register) {
        x64_mov_register_operand(text, into.reg, from);
        return;
    }
    if (from.in_register) {
        x64_mov_operand_register(text, into, from.reg);
        return;
    }
    x64_mov_register_operand(text, X64_RAX, from);
    x64_mov_operand_register(text, into, X64_RAX);
}

/*
 * Compares the values at `depth` and `depth + 1`, left minus right. One of the
 * two is normally a register; when both spilled, `rax` carries the right side.
 */
static void x64_function_compare(
    Bytes *text,
    const FrameLayout *layout,
    size_t depth
) {
    Operand left = target_eval_operand(layout, depth);
    Operand right = target_eval_operand(layout, depth + 1);
    if (left.in_register) {
        x64_encode_op(text, X64_CMP_REG_RM, left.reg, right);
        return;
    }
    if (right.in_register) {
        x64_encode_op(text, X64_CMP_RM_REG, right.reg, left);
        return;
    }
    x64_mov_register_operand(text, X64_RAX, right);
    x64_encode_op(text, X64_CMP_RM_REG, X64_RAX, left);
}

/*
 * The branch that skips a guard body is taken when the comparison is false, so
 * a guard can leave the answer in the flags instead of materializing a Bool
 * and testing it back. Returns false for any other condition expression.
 */
static bool x64_function_guard_inverse(
    FunctionExpressionKind kind,
    uint8_t *inverse
) {
    if (kind == FUNCTION_EQUAL) {
        *inverse = UINT8_C(0x85); /* jne */
    } else if (kind == FUNCTION_NOT_EQUAL) {
        *inverse = UINT8_C(0x84); /* je */
    } else if (kind == FUNCTION_LESS) {
        *inverse = UINT8_C(0x8d); /* jge */
    } else if (kind == FUNCTION_LESS_EQUAL) {
        *inverse = UINT8_C(0x8f); /* jg */
    } else if (kind == FUNCTION_GREATER) {
        *inverse = UINT8_C(0x8e); /* jle */
    } else if (kind == FUNCTION_GREATER_EQUAL) {
        *inverse = UINT8_C(0x8c); /* jl */
    } else {
        return false;
    }
    return true;
}

/*
 * Integer division on x86-64
 * --------------------------
 *
 * `idiv` divides `rdx:rax` and writes the truncating quotient to `rax` and the
 * truncating remainder to `rdx`. Kofun's `//` and `%` floor instead, so a
 * correction step follows: when the remainder is non-zero and its sign differs
 * from the divisor's, the quotient is one too high and the remainder is one
 * divisor short. `/` truncates and needs no correction.
 *
 * `idiv` faults on a zero divisor and on the one quotient that is not
 * representable, and a fault is a signal rather than a diagnostic, so both are
 * checked before it runs. The `-1` divisor is the whole of the second case and
 * is handled without dividing at all: the quotient is `-left`, whose overflow
 * `neg` reports in `OF` exactly when `left` is `INT64_MIN`, and the remainder
 * is zero — which is why `INT64_MIN % -1` is `0` rather than an error.
 *
 * `rax`, `rcx`, and `rdx` are never allocated (`rax` is the move scratch and
 * the other two are argument registers, which only ever hold a value at a call
 * boundary), so materializing the divisor in `rcx` and clobbering `rdx` cannot
 * disturb anything live.
 */
static void x64_function_divide(
    Bytes *text,
    FunctionExpressionKind kind,
    FunctionEmitter *emitter,
    Operand result,
    Operand divisor
) {
    x64_mov_register_operand(text, X64_RCX, divisor);
    x64_mov_register_operand(text, X64_RAX, result);
    /* test rcx, rcx */
    x64_encode_op(
        text,
        X64_TEST_RM_REG,
        X64_RCX,
        target_register_operand(X64_RCX)
    );
    x64_function_divide_zero_jump(
        text,
        emitter,
        function_divide_zero_trap(kind)
    );
    const uint8_t compare_minus_one[] = {
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xf9), UINT8_C(0xff),
    };
    x64_emit(text, compare_minus_one, sizeof(compare_minus_one));
    size_t general = x64_local_jcc(text, UINT8_C(0x85)); /* jne general */
    if (kind == FUNCTION_FLOOR_MODULO) {
        /* Every remainder by -1 is zero, INT64_MIN included. */
        byte(text, UINT8_C(0x31));
        byte(text, UINT8_C(0xc0)); /* xor eax, eax */
    } else {
        x64_encode_op(
            text,
            X64_GROUP3_RM,
            X64_GROUP3_NEG,
            target_register_operand(X64_RAX)
        );
        x64_function_overflow_jump(
            text,
            emitter,
            function_divide_overflow_trap(kind)
        );
    }
    size_t done = x64_local_jmp(text);
    x64_patch_rel32(text, general, text->length);
    byte(text, UINT8_C(0x48));
    byte(text, UINT8_C(0x99)); /* cqo */
    x64_encode_op(
        text,
        X64_GROUP3_RM,
        X64_GROUP3_IDIV,
        target_register_operand(X64_RCX)
    );
    {
        if (kind == FUNCTION_FLOOR_MODULO) {
            x64_mov_register_operand(
                text,
                X64_RAX,
                target_register_operand(X64_RDX)
            );
        }
        /* test rdx, rdx: a zero remainder is already floored. */
        x64_encode_op(
            text,
            X64_TEST_RM_REG,
            X64_RDX,
            target_register_operand(X64_RDX)
        );
        size_t exact = x64_local_jcc(text, UINT8_C(0x84)); /* je done */
        /* xor rdx, rcx: the sign bit is set exactly when the signs differ. */
        x64_encode_op(
            text,
            X64_XOR_RM_REG,
            X64_RCX,
            target_register_operand(X64_RDX)
        );
        size_t same = x64_local_jcc(text, UINT8_C(0x89)); /* jns done */
        if (kind == FUNCTION_FLOOR_MODULO) {
            /* add rax, rcx */
            x64_encode_op(
                text,
                X64_ADD_REG_RM,
                X64_RAX,
                target_register_operand(X64_RCX)
            );
        } else {
            /* dec rax */
            byte(text, UINT8_C(0x48));
            byte(text, UINT8_C(0xff));
            byte(text, UINT8_C(0xc8));
        }
        x64_patch_rel32(text, exact, text->length);
        x64_patch_rel32(text, same, text->length);
    }
    x64_patch_rel32(text, done, text->length);
    x64_move(text, result, target_register_operand(X64_RAX));
}

static void x64_function_expression(
    Bytes *text,
    const FunctionExpression *expression,
    FunctionEmitter *emitter,
    const FrameLayout *layout,
    size_t depth
) {
    Operand result = target_eval_operand(layout, depth);
    if (expression->kind == FUNCTION_LITERAL) {
        unsigned reg = result.in_register ? result.reg : X64_RAX;
        x64_mov_register_imm64(text, reg, expression->value);
        if (!result.in_register) {
            x64_mov_operand_register(text, result, X64_RAX);
        }
        return;
    }
    if (expression->kind == FUNCTION_TEXT_LITERAL) {
        emitter->runtime.used = true;
        unsigned reg = result.in_register ? result.reg : X64_RAX;
        text_fixups_add(
            &emitter->runtime.text_literals,
            x64_mov_register_imm32_field(text, reg),
            expression->text_value,
            expression->text_length
        );
        if (!result.in_register) {
            x64_mov_operand_register(text, result, X64_RAX);
        }
        return;
    }
    if (expression->kind == FUNCTION_PARAMETER) {
        x64_move(text, result, target_value_operand(layout, expression->slot));
        return;
    }
    if (expression->kind == FUNCTION_CALL) {
        for (size_t index = 0; index < expression->argument_count; ++index) {
            x64_function_expression(
                text,
                expression->arguments[index],
                emitter,
                layout,
                depth + index
            );
        }
        for (size_t index = 0; index < expression->argument_count; ++index) {
            if (index >= MAX_CORE_PARAMETERS) {
                fatal("x86-64 Core call has too many arguments");
            }
            /* Argument registers are never allocated, so filling the boundary
             * cannot overwrite an argument that has not been moved yet. */
            x64_mov_register_operand(
                text,
                x64_argument_registers[index],
                target_eval_operand(layout, depth + index)
            );
        }
        x64_function_call(text, emitter, expression->function_index);
        x64_mov_operand_register(text, result, X64_RAX);
        return;
    }
    if (expression->kind == FUNCTION_SYSCALL) {
        size_t count = expression->argument_count;
        if (count == 0 || count > FUNCTION_SYSCALL_MAX_ARGUMENTS) {
            fatal("x86-64 Core syscall has the wrong argument count");
        }
        for (size_t index = 0; index < count; ++index) {
            x64_function_expression(
                text,
                expression->arguments[index],
                emitter,
                layout,
                depth + index
            );
        }
        /*
         * Only `r10` among the boundary registers is ever allocated, so filling
         * it last places every value exactly once. That is a property of the
         * allocator rather than of this code, so prove it here instead of
         * trusting it: an argument sitting in any other boundary register would
         * be destroyed before its own move ran.
         */
        for (size_t index = 0; index < count; ++index) {
            if (index == X64_SYSCALL_ALLOCATABLE_INDEX) continue;
            for (size_t other = 0; other < count; ++other) {
                Operand from = target_eval_operand(layout, depth + other);
                if (from.in_register &&
                    from.reg == x64_syscall_registers[index]) {
                    fatal(
                        "x86-64 Core syscall boundary register holds an argument"
                    );
                }
            }
        }
        for (size_t index = 0; index < count; ++index) {
            if (index == X64_SYSCALL_ALLOCATABLE_INDEX) continue;
            x64_mov_register_operand(
                text,
                x64_syscall_registers[index],
                target_eval_operand(layout, depth + index)
            );
        }
        if (count > X64_SYSCALL_ALLOCATABLE_INDEX) {
            x64_mov_register_operand(
                text,
                x64_syscall_registers[X64_SYSCALL_ALLOCATABLE_INDEX],
                target_eval_operand(
                    layout,
                    depth + X64_SYSCALL_ALLOCATABLE_INDEX
                )
            );
        }
        x64_syscall(text);
        /*
         * Whatever the kernel returned, unchanged. A negative result is an
         * errno the way `syscall_result` in `stdlib/linux_x86_64/abi.kofun`
         * expects to receive it, so the backend classifies nothing.
         */
        x64_mov_operand_register(text, result, X64_RAX);
        return;
    }
    if (expression->kind == FUNCTION_NEGATE) {
        x64_function_expression(
            text,
            expression->left,
            emitter,
            layout,
            depth
        );
        /* neg result */
        x64_encode_op(text, X64_GROUP3_RM, X64_GROUP3_NEG, result);
        x64_function_overflow_jump(
            text,
            emitter,
            FUNCTION_TRAP_NEGATE_OVERFLOW
        );
        return;
    }
    if (expression->kind == FUNCTION_TEXT_CONCAT) {
        x64_function_expression(
            text,
            expression->left,
            emitter,
            layout,
            depth
        );
        x64_function_expression(
            text,
            expression->right,
            emitter,
            layout,
            depth + 1
        );
        x64_mov_register_operand(text, X64_RDI, result);
        x64_mov_register_operand(
            text,
            X64_RSI,
            target_eval_operand(layout, depth + 1)
        );
        x64_call_runtime(
            text,
            &emitter->runtime,
            &emitter->runtime.text_concat_calls
        );
        x64_mov_operand_register(text, result, X64_RAX);
        return;
    }

    x64_function_expression(text, expression->left, emitter, layout, depth);
    x64_function_expression(
        text,
        expression->right,
        emitter,
        layout,
        depth + 1
    );
    Operand right = target_eval_operand(layout, depth + 1);
    if (expression->kind == FUNCTION_ADD ||
        expression->kind == FUNCTION_SUBTRACT) {
        bool add = expression->kind == FUNCTION_ADD;
        if (result.in_register) {
            x64_encode_op(
                text,
                add ? X64_ADD_REG_RM : X64_SUB_REG_RM,
                result.reg,
                right
            );
        } else if (right.in_register) {
            x64_encode_op(
                text,
                add ? X64_ADD_RM_REG : X64_SUB_RM_REG,
                right.reg,
                result
            );
        } else {
            x64_mov_register_operand(text, X64_RAX, right);
            x64_encode_op(
                text,
                add ? X64_ADD_RM_REG : X64_SUB_RM_REG,
                X64_RAX,
                result
            );
        }
        x64_function_overflow_jump(
            text,
            emitter,
            add
                ? FUNCTION_TRAP_ADD_OVERFLOW
                : FUNCTION_TRAP_SUBTRACT_OVERFLOW
        );
        return;
    }
    if (expression->kind == FUNCTION_FLOOR_DIVIDE ||
        expression->kind == FUNCTION_FLOOR_MODULO) {
        x64_function_divide(text, expression->kind, emitter, result, right);
        return;
    }
    if (expression->kind == FUNCTION_MULTIPLY) {
        static const uint8_t imul[] = {UINT8_C(0x0f), UINT8_C(0xaf)};
        if (result.in_register) {
            x64_encode(text, imul, sizeof(imul), result.reg, right);
            x64_function_overflow_jump(
                text,
                emitter,
                FUNCTION_TRAP_MULTIPLY_OVERFLOW
            );
            return;
        }
        /* `imul` only multiplies into a register. */
        x64_mov_register_operand(text, X64_RAX, result);
        x64_encode(text, imul, sizeof(imul), X64_RAX, right);
        x64_function_overflow_jump(
            text,
            emitter,
            FUNCTION_TRAP_MULTIPLY_OVERFLOW
        );
        x64_mov_operand_register(text, result, X64_RAX);
        return;
    }

    /* cmp left, right, then materialize the 0/1 result. */
    x64_function_compare(text, layout, depth);
    byte(text, UINT8_C(0x0f));
    uint8_t condition = UINT8_C(0x94);
    if (expression->kind == FUNCTION_NOT_EQUAL) {
        condition = UINT8_C(0x95);
    } else if (expression->kind == FUNCTION_LESS) {
        condition = UINT8_C(0x9c);
    } else if (expression->kind == FUNCTION_LESS_EQUAL) {
        condition = UINT8_C(0x9e);
    } else if (expression->kind == FUNCTION_GREATER) {
        condition = UINT8_C(0x9f);
    } else if (expression->kind == FUNCTION_GREATER_EQUAL) {
        condition = UINT8_C(0x9d);
    }
    byte(text, condition);
    byte(text, UINT8_C(0xc0)); /* setcc al */
    byte(text, UINT8_C(0x0f));
    byte(text, UINT8_C(0xb6));
    byte(text, UINT8_C(0xc0)); /* movzx eax, al */
    x64_mov_operand_register(text, result, X64_RAX);
}

static void x64_function_epilogue(Bytes *text) {
    byte(text, UINT8_C(0xc9)); /* leave */
    byte(text, UINT8_C(0xc3)); /* ret */
}

/*
 * Restores every callee-saved register the body claimed and returns. Reloading
 * from frame slots leaves the result in `rax` untouched, and `leave` drops the
 * whole frame. One body emits this once and every earlier return jumps to it,
 * so all return paths restore exactly the same set at exactly one place.
 */
static void x64_function_epilogue_block(
    Bytes *text,
    const FrameLayout *layout
) {
    for (size_t index = layout->saved_count; index > 0; --index) {
        x64_mov_register_operand(
            text,
            layout->saved[index - 1],
            x64_saved_operand(layout, index - 1)
        );
    }
    x64_function_epilogue(text);
}

/*
 * Emits a returned call as a branch rather than a call/return pair. The
 * arguments are evaluated into their ordinary depths first, so nothing reads a
 * parameter after the assignment below has started to overwrite one, and no
 * evaluation depth shares a location with a parameter.
 */
static void x64_function_tail_call(
    Bytes *text,
    const FunctionExpression *call,
    FunctionEmitter *emitter,
    const FrameLayout *layout,
    size_t self_index,
    size_t body_start
) {
    /*
     * Evaluate in source order, into the slot each argument was bound to. The
     * ABI vector below then walks slots in declaration order, so a labelled
     * call written out of order still evaluates as written and is placed as
     * declared — the same separation the C11 backend gets from its comma
     * expression over fixed temporaries.
     */
    for (size_t written = 0; written < call->argument_count; ++written) {
        size_t index = call->argument_order[written];
        if (index >= MAX_CORE_PARAMETERS) {
            fatal("x86-64 Core call has too many arguments");
        }
        x64_function_expression(
            text,
            call->arguments[index],
            emitter,
            layout,
            index
        );
    }
    if (call->function_index == self_index) {
        for (size_t index = 0; index < call->argument_count; ++index) {
            x64_move(
                text,
                target_value_operand(layout, index),
                target_eval_operand(layout, index)
            );
        }
        x64_patch_rel32(text, x64_local_jmp(text), body_start);
        return;
    }
    /* Argument registers are never allocated, so filling the boundary cannot
     * overwrite an argument that has not been moved yet. */
    for (size_t index = 0; index < call->argument_count; ++index) {
        x64_mov_register_operand(
            text,
            x64_argument_registers[index],
            target_eval_operand(layout, index)
        );
    }
    /* The saved registers still live in frame slots, so they are reloaded
     * while `rbp` is valid and before `leave` drops the frame. Neither step
     * touches an argument register. */
    for (size_t index = layout->saved_count; index > 0; --index) {
        x64_mov_register_operand(
            text,
            layout->saved[index - 1],
            x64_saved_operand(layout, index - 1)
        );
    }
    byte(text, UINT8_C(0xc9)); /* leave: rsp now points at the return address */
    byte(text, UINT8_C(0xe9)); /* jmp callee (patched) */
    function_call_fixup_add(
        &emitter->calls,
        text->length,
        call->function_index
    );
    u32_le(text, 0);
}

static void x64_function_parameter_store(
    Bytes *text,
    const FrameLayout *layout,
    size_t parameter
) {
    if (parameter >= MAX_CORE_PARAMETERS) {
        fatal("x86-64 Core parameter register is unavailable");
    }
    x64_move(
        text,
        target_value_operand(layout, parameter),
        target_register_operand(x64_argument_registers[parameter])
    );
}

static void x64_function_declaration(
    Bytes *text,
    const FunctionDeclaration *function,
    size_t self_index,
    FunctionEmitter *emitter
) {
    FrameLayout layout = x64_function_layout(function);
    const uint8_t frame_open[] = {
        UINT8_C(0x55),                         /* push rbp */
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xe5),
    };
    x64_emit(text, frame_open, sizeof(frame_open));
    size_t frame_slots =
        layout.frame_slots + layout.spill_slots + layout.saved_count;
    if (frame_slots > 0) {
        size_t frame_bytes = frame_slots * sizeof(uint64_t);
        /* Rounded so the body keeps 16-byte SysV call alignment. */
        frame_bytes = (frame_bytes + 15) & ~(size_t)15;
        byte(text, UINT8_C(0x48));
        if (frame_bytes <= 127) {
            byte(text, UINT8_C(0x83));
            byte(text, UINT8_C(0xec)); /* sub rsp, frame bytes */
            byte(text, (uint8_t)frame_bytes);
        } else {
            byte(text, UINT8_C(0x81));
            byte(text, UINT8_C(0xec));
            u32_le(text, (uint32_t)frame_bytes);
        }
    }
    for (size_t index = 0; index < layout.saved_count; ++index) {
        x64_mov_operand_register(
            text,
            x64_saved_operand(&layout, index),
            layout.saved[index]
        );
    }
    for (size_t index = 0; index < function->parameter_count; ++index) {
        x64_function_parameter_store(text, &layout, index);
    }
    /* A returned call to this same function reassigns the parameters and
     * branches here, so the frame, the saved registers, and the argument
     * hand-off are each paid for exactly once. */
    size_t body_start = text->length;

    /* Every return path reaches the one epilogue emitted after the body. */
    Offsets returns = {0};
    bool returned = false;
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        bool tail = index + 1 == function->statement_count;
        if (statement->kind == FUNCTION_STATEMENT_IF_RETURN) {
            uint8_t inverse = UINT8_C(0x84); /* je after branch */
            size_t skip;
            if (x64_function_guard_inverse(
                    statement->condition->kind,
                    &inverse)) {
                /* Both operands evaluate exactly as they would on their own;
                 * only the Bool between the comparison and the branch is
                 * gone. */
                x64_function_expression(
                    text,
                    statement->condition->left,
                    emitter,
                    &layout,
                    0
                );
                x64_function_expression(
                    text,
                    statement->condition->right,
                    emitter,
                    &layout,
                    1
                );
                x64_function_compare(text, &layout, 0);
                skip = x64_local_jcc(text, inverse);
            } else {
                x64_function_expression(
                    text,
                    statement->condition,
                    emitter,
                    &layout,
                    0
                );
                Operand condition = target_eval_operand(&layout, 0);
                if (condition.in_register) {
                    /* test condition, condition */
                    x64_encode_op(
                        text,
                        X64_TEST_RM_REG,
                        condition.reg,
                        condition
                    );
                } else {
                    x64_mov_register_operand(text, X64_RAX, condition);
                    x64_encode_op(
                        text,
                        X64_TEST_RM_REG,
                        X64_RAX,
                        target_register_operand(X64_RAX)
                    );
                }
                skip = x64_local_jcc(text, inverse);
            }
            const FunctionExpression *tail_call = function_tail_call(statement);
            if (tail_call != NULL) {
                x64_function_tail_call(
                    text,
                    tail_call,
                    emitter,
                    &layout,
                    self_index,
                    body_start
                );
            } else {
                x64_function_expression(
                    text,
                    statement->value,
                    emitter,
                    &layout,
                    0
                );
                x64_move(
                    text,
                    target_register_operand(X64_RAX),
                    target_eval_operand(&layout, 0)
                );
                offsets_add(&returns, x64_local_jmp(text));
            }
            x64_patch_rel32(text, skip, text->length);
        } else if (statement->kind == FUNCTION_STATEMENT_RETURN) {
            const FunctionExpression *tail_call = function_tail_call(statement);
            if (tail_call != NULL) {
                /* The branch itself ends this path; nothing falls through to
                 * the epilogue and nothing jumps to it from here. */
                x64_function_tail_call(
                    text,
                    tail_call,
                    emitter,
                    &layout,
                    self_index,
                    body_start
                );
                returned = true;
                continue;
            }
            x64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            x64_move(
                text,
                target_register_operand(X64_RAX),
                target_eval_operand(&layout, 0)
            );
            /* A closing return falls straight into the epilogue. */
            if (!tail) offsets_add(&returns, x64_local_jmp(text));
            returned = true;
        } else if (statement->kind == FUNCTION_STATEMENT_PRINT) {
            x64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            x64_move(
                text,
                target_register_operand(X64_RDI),
                target_eval_operand(&layout, 0)
            );
            byte(text, UINT8_C(0xe8));
            Offsets *calls =
                statement->value->value_kind == FUNCTION_VALUE_TEXT
                    ? &emitter->print_text_calls
                    : &emitter->print_int_calls;
            offsets_add(calls, text->length);
            u32_le(text, 0);
        } else if (statement->kind == FUNCTION_STATEMENT_LET) {
            x64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            x64_move(
                text,
                target_value_operand(&layout, statement->slot),
                target_eval_operand(&layout, 0)
            );
        } else {
            /* The evaluated result is discarded. */
            x64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
        }
    }
    if (!returned) {
        byte(text, UINT8_C(0x31));
        byte(text, UINT8_C(0xc0)); /* implicit main return 0 */
    }
    size_t epilogue = text->length;
    for (size_t index = 0; index < returns.length; ++index) {
        x64_patch_rel32(text, returns.fields[index], epilogue);
    }
    x64_function_epilogue_block(text, &layout);
    free(returns.fields);
}

static size_t x64_function_print_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    const uint8_t open[] = {
        UINT8_C(0x55),                         /* push rbp */
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xe5),
        UINT8_C(0x48), UINT8_C(0x83), UINT8_C(0xec), UINT8_C(0x20),
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xf8), /* rax = value */
        UINT8_C(0x45), UINT8_C(0x31), UINT8_C(0xd2), /* r10d = 0 */
        UINT8_C(0xc6), UINT8_C(0x45), UINT8_C(0xff), UINT8_C(0x0a),
        UINT8_C(0x48), UINT8_C(0x8d), UINT8_C(0x75), UINT8_C(0xff),
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xc0), /* test rax */
    };
    x64_emit(text, open, sizeof(open));
    size_t nonnegative =
        x64_local_jcc(text, UINT8_C(0x89)); /* jns magnitude */
    const uint8_t negative[] = {
        UINT8_C(0x48), UINT8_C(0xf7), UINT8_C(0xd8), /* neg rax */
        UINT8_C(0x41), UINT8_C(0xba),
        UINT8_C(0x01), UINT8_C(0x00), UINT8_C(0x00), UINT8_C(0x00),
    };
    x64_emit(text, negative, sizeof(negative));
    size_t magnitude = text->length;
    x64_patch_rel32(text, nonnegative, magnitude);
    const uint8_t zero_test[] = {
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xc0),
    };
    x64_emit(text, zero_test, sizeof(zero_test));
    size_t digits = x64_local_jcc(
        text,
        UINT8_C(0x85)
    ); /* jne digit loop */
    const uint8_t zero[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xce), /* dec rsi */
        UINT8_C(0xc6), UINT8_C(0x06), UINT8_C(0x30),
    };
    x64_emit(text, zero, sizeof(zero));
    size_t sign = x64_local_jmp(text);
    size_t digits_at = text->length;
    x64_patch_rel32(text, digits, digits_at);
    x64_mov_r32_imm32(text, UINT8_C(0xb9), 10); /* ecx = 10 */
    size_t digit_loop = text->length;
    const uint8_t digit[] = {
        UINT8_C(0x31), UINT8_C(0xd2),             /* xor edx, edx */
        UINT8_C(0x48), UINT8_C(0xf7), UINT8_C(0xf1), /* div rcx */
        UINT8_C(0x80), UINT8_C(0xc2), UINT8_C(0x30),
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xce),
        UINT8_C(0x88), UINT8_C(0x16),             /* [rsi] = dl */
        UINT8_C(0x48), UINT8_C(0x85), UINT8_C(0xc0),
    };
    x64_emit(text, digit, sizeof(digit));
    size_t digit_back =
        x64_local_jcc(text, UINT8_C(0x85)); /* jne loop */
    x64_patch_rel32(text, digit_back, digit_loop);
    size_t sign_at = text->length;
    x64_patch_rel32(text, sign, sign_at);
    const uint8_t sign_test[] = {
        UINT8_C(0x45), UINT8_C(0x85), UINT8_C(0xd2),
    };
    x64_emit(text, sign_test, sizeof(sign_test));
    size_t write = x64_local_jcc(text, UINT8_C(0x84)); /* je write */
    const uint8_t minus[] = {
        UINT8_C(0x48), UINT8_C(0xff), UINT8_C(0xce),
        UINT8_C(0xc6), UINT8_C(0x06), UINT8_C(0x2d),
    };
    x64_emit(text, minus, sizeof(minus));
    size_t write_at = text->length;
    x64_patch_rel32(text, write, write_at);
    const uint8_t output[] = {
        UINT8_C(0x48), UINT8_C(0x89), UINT8_C(0xea), /* rdx = rbp */
        UINT8_C(0x48), UINT8_C(0x29), UINT8_C(0xf2), /* rdx -= rsi */
    };
    x64_emit(text, output, sizeof(output));
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
    x64_syscall(text);
    x64_function_epilogue(text);
    return runtime_at;
}

static size_t x64_function_print_text_runtime(
    Bytes *text,
    X64Runtime *runtime
) {
    runtime->used = true;
    size_t runtime_at = text->length;
    const uint8_t output[] = {
        UINT8_C(0x48), UINT8_C(0x8b), UINT8_C(0x17),
        UINT8_C(0x48), UINT8_C(0x8d), UINT8_C(0x77), UINT8_C(0x08),
    };
    x64_emit(text, output, sizeof(output)); /* len and bytes from Text */
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 1); /* write */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 1); /* stdout */
    x64_syscall(text);
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);
    byte(text, UINT8_C(0xbe)); /* mov esi, newline */
    offsets_add(&runtime->newline_addresses, text->length);
    u32_le(text, 0);
    x64_mov_r32_imm32(text, UINT8_C(0xba), 1);
    x64_syscall(text);
    byte(text, UINT8_C(0xc3)); /* ret */
    return runtime_at;
}

static uint64_t function_trap_data(
    Bytes *data,
    FunctionTrapKind kind,
    size_t *length
) {
    const char *message = function_trap_message(kind);
    *length = strlen(message);
    if (data->length > PAGE_SIZE - 3 ||
        *length > PAGE_SIZE - 3 - data->length) {
        fatal("native function diagnostics exceed the bounded RW page");
    }
    uint64_t address = DATA_ADDRESS + 3 + (uint64_t)data->length;
    bytes_reserve(data, *length);
    memcpy(data->data + data->length, message, *length);
    data->length += *length;
    return address;
}

/*
 * Every used arithmetic failure has a tiny operator-specific stub. The stubs
 * load one message from the RW data page and share this write/exit sequence,
 * keeping the bounded RX page executable-only and avoiding repeated syscall
 * bodies.
 */
static size_t x64_function_trap_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 1);  /* write */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 2);  /* stderr */
    x64_syscall(text);
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 60); /* exit */
    x64_mov_r32_imm32(text, UINT8_C(0xbf), 1);  /* status 1 */
    x64_syscall(text);
    byte(text, UINT8_C(0x0f));
    byte(text, UINT8_C(0x0b));                  /* ud2 after exit */
    return runtime_at;
}

static size_t x64_function_trap_stub(
    Bytes *text,
    Bytes *data,
    FunctionTrapKind kind,
    size_t runtime_at
) {
    size_t length = 0;
    uint64_t address = function_trap_data(data, kind, &length);
    size_t stub_at = text->length;
    byte(text, UINT8_C(0xbe)); /* mov esi, message */
    u32_le(text, (uint32_t)address);
    byte(text, UINT8_C(0xba)); /* mov edx, length */
    u32_le(text, (uint32_t)length);
    size_t runtime_jump = x64_local_jmp(text);
    x64_patch_rel32(text, runtime_jump, runtime_at);
    return stub_at;
}

static void x64_function_program(
    Bytes *text,
    Bytes *data,
    const FunctionProgram *program
) {
    FunctionEmitter emitter = {0};
    size_t function_addresses[MAX_CORE_FUNCTIONS] = {0};

    x64_function_call(text, &emitter, program->main_index);
    byte(text, UINT8_C(0x89));
    byte(text, UINT8_C(0xc7)); /* mov edi, eax */
    x64_mov_r32_imm32(text, UINT8_C(0xb8), 60);
    x64_syscall(text);
    byte(text, UINT8_C(0x0f));
    byte(text, UINT8_C(0x0b)); /* ud2 after exit */

    for (size_t index = 0; index < program->function_count; ++index) {
        function_addresses[index] = text->length;
        x64_function_declaration(
            text,
            &program->functions[index],
            index,
            &emitter
        );
    }

    size_t print_int_at = x64_function_print_runtime(text);
    size_t print_text_at = 0;
    if (emitter.print_text_calls.length > 0) {
        print_text_at =
            x64_function_print_text_runtime(text, &emitter.runtime);
    }
    size_t trap_at[FUNCTION_TRAP_COUNT] = {0};
    bool has_trap = false;
    for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
        if (emitter.trap_jumps[kind].length > 0) has_trap = true;
    }
    if (has_trap) {
        size_t trap_runtime_at = x64_function_trap_runtime(text);
        for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
            if (emitter.trap_jumps[kind].length == 0) continue;
            trap_at[kind] = x64_function_trap_stub(
                text,
                data,
                (FunctionTrapKind)kind,
                trap_runtime_at
            );
        }
    }

    for (size_t index = 0; index < emitter.calls.length; ++index) {
        FunctionCallFixup fixup = emitter.calls.items[index];
        x64_patch_rel32(
            text,
            fixup.field,
            function_addresses[fixup.function_index]
        );
    }
    for (
        size_t index = 0;
        index < emitter.print_int_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            emitter.print_int_calls.fields[index],
            print_int_at
        );
    }
    for (
        size_t index = 0;
        index < emitter.print_text_calls.length;
        ++index
    ) {
        x64_patch_rel32(
            text,
            emitter.print_text_calls.fields[index],
            print_text_at
        );
    }
    for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
        for (size_t index = 0;
             index < emitter.trap_jumps[kind].length;
             ++index) {
            x64_patch_rel32(
                text,
                emitter.trap_jumps[kind].fields[index],
                trap_at[kind]
            );
        }
    }
    x64_runtime(text, &emitter.runtime);
    function_emitter_free(&emitter);
}

static void a64_word(Bytes *text, uint32_t instruction) {
    u32_le(text, instruction);
}

static void a64_movz(Bytes *text, unsigned reg, unsigned value) {
    a64_word(
        text,
        UINT32_C(0xd2800000) |
            ((uint32_t)value << 5) |
            (uint32_t)reg
    );
}

static void a64_movk_lsl16(Bytes *text, unsigned reg, unsigned value) {
    a64_word(
        text,
        UINT32_C(0xf2a00000) |
            ((uint32_t)value << 5) |
            (uint32_t)reg
    );
}

static void a64_add(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0x8b000000) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

static void a64_multiply(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0x9b007c00) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

/*
 * Records a debug line row at each point the x86-64 lowering records one: the
 * first instruction of a literal, and the operation that follows both operands
 * of a binary node. Both backends lower the same parsed Core, so the two line
 * tables describe the same source lines in the same order at their own
 * instruction addresses.
 */
static void a64_expression(
    Bytes *text,
    const Node *expression,
    LineRows *rows,
    unsigned *depth
) {
    if (expression->kind == NODE_LITERAL) {
        line_row(rows, text->length, expression->source_line);
        a64_movz(text, *depth, (unsigned)expression->value);
        ++*depth;
        return;
    }

    a64_expression(text, expression->left, rows, depth);
    a64_expression(text, expression->right, rows, depth);
    line_row(rows, text->length, expression->source_line);
    unsigned left = *depth - 2;
    unsigned right = *depth - 1;
    if (expression->kind == NODE_ADD) {
        a64_add(text, left, left, right);
    } else {
        a64_multiply(text, left, left, right);
    }
    --*depth;
}

static void a64_add_immediate(
    Bytes *text,
    unsigned destination,
    unsigned source,
    unsigned value
) {
    a64_word(
        text,
        UINT32_C(0x91000000) |
            ((uint32_t)value << 10) |
            ((uint32_t)source << 5) |
            (uint32_t)destination
    );
}

static void a64_udiv(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0x9ac00800) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

static void a64_msub(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right,
    unsigned accumulator
) {
    a64_word(
        text,
        UINT32_C(0x9b008000) |
            ((uint32_t)right << 16) |
            ((uint32_t)accumulator << 10) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

static void a64_strb(
    Bytes *text,
    unsigned source,
    unsigned address,
    unsigned offset
) {
    a64_word(
        text,
        UINT32_C(0x39000000) |
            ((uint32_t)offset << 10) |
            ((uint32_t)address << 5) |
            (uint32_t)source
    );
}

static void a64_svc(Bytes *text) {
    a64_word(text, UINT32_C(0xd4000001));
}

static void a64_text(
    Bytes *text,
    const Node *expression,
    LineRows *rows,
    size_t print_line
) {
    unsigned depth = 0;
    a64_expression(text, expression, rows, &depth);
    if (depth != 1) fatal("invalid AArch64 Core register stack");

    line_row(rows, text->length, print_line);
    a64_movz(text, 3, 10);
    a64_udiv(text, 4, 0, 3);
    a64_msub(text, 5, 4, 3, 0);
    a64_add_immediate(text, 4, 4, 48);
    a64_add_immediate(text, 5, 5, 48);
    a64_movz(text, 1, UINT16_C(0x1000));
    a64_movk_lsl16(text, 1, UINT16_C(0x40));
    a64_strb(text, 4, 1, 0);
    a64_strb(text, 5, 1, 1);

    a64_movz(text, 0, 1);  /* stdout */
    a64_movz(text, 2, 3);  /* length */
    a64_movz(text, 8, 64); /* write */
    a64_svc(text);
    a64_movz(text, 0, 0);
    a64_movz(text, 8, 93); /* exit */
    a64_svc(text);
}

/*
 * AArch64 user-defined Int function Core.
 *
 * This mirrors the x86-64 function profile (x64_function_program) instruction
 * for instruction, using the same target-independent parsed FunctionProgram.
 * It is a straightforward stack machine: every intermediate value lives on the
 * native stack, so no register allocator is required. The stack pointer is
 * kept 16-byte aligned at all times (each push/pop moves it by 16 bytes and
 * every frame is a 16-byte multiple), which Linux requires for `sp`.
 *
 * Every fixed-register instruction word below was cross-checked against
 * `llvm-mc --triple=aarch64 --show-encoding`.
 */

static uint32_t a64_read_word(const Bytes *text, size_t field) {
    if (field > text->length || text->length - field < 4) {
        fatal("aarch64 instruction field is outside text");
    }
    return (uint32_t)text->data[field] |
        ((uint32_t)text->data[field + 1] << 8) |
        ((uint32_t)text->data[field + 2] << 16) |
        ((uint32_t)text->data[field + 3] << 24);
}

static void a64_write_word(Bytes *text, size_t field, uint32_t word) {
    if (field > text->length || text->length - field < 4) {
        fatal("aarch64 instruction field is outside text");
    }
    for (unsigned index = 0; index < 4; ++index) {
        text->data[field + index] = (uint8_t)(word >> (index * 8));
    }
}

/* Patch a 26-bit branch immediate (B/BL), scaled by 4, PC-relative. */
static void a64_patch_imm26(Bytes *text, size_t field, size_t target) {
    int64_t displacement = (int64_t)target - (int64_t)field;
    if (displacement % 4 != 0) {
        fatal("aarch64 branch target is not 4-byte aligned");
    }
    int64_t immediate = displacement / 4;
    if (immediate < -(INT64_C(1) << 25) ||
        immediate >= (INT64_C(1) << 25)) {
        fatal("aarch64 imm26 branch is out of range");
    }
    uint32_t word = a64_read_word(text, field);
    word = (word & ~UINT32_C(0x03ffffff)) |
        ((uint32_t)immediate & UINT32_C(0x03ffffff));
    a64_write_word(text, field, word);
}

/* Patch a 19-bit branch immediate (B.cond/CBZ/CBNZ) at bits [23:5]. */
static void a64_patch_imm19(Bytes *text, size_t field, size_t target) {
    int64_t displacement = (int64_t)target - (int64_t)field;
    if (displacement % 4 != 0) {
        fatal("aarch64 conditional target is not 4-byte aligned");
    }
    int64_t immediate = displacement / 4;
    if (immediate < -(INT64_C(1) << 18) ||
        immediate >= (INT64_C(1) << 18)) {
        fatal("aarch64 imm19 branch is out of range");
    }
    uint32_t word = a64_read_word(text, field);
    word = (word & ~(UINT32_C(0x7ffff) << 5)) |
        (((uint32_t)immediate & UINT32_C(0x7ffff)) << 5);
    a64_write_word(text, field, word);
}

/*
 * Patch a 14-bit test-branch immediate (TBZ/TBNZ) at bits [18:5]. The bit
 * selector lives at [23:19] and above, so this may not go through
 * a64_patch_imm19, which would overwrite it.
 */
static void a64_patch_imm14(Bytes *text, size_t field, size_t target) {
    int64_t displacement = (int64_t)target - (int64_t)field;
    if (displacement % 4 != 0) {
        fatal("aarch64 test branch target is not 4-byte aligned");
    }
    int64_t immediate = displacement / 4;
    if (immediate < -(INT64_C(1) << 13) ||
        immediate >= (INT64_C(1) << 13)) {
        fatal("aarch64 imm14 branch is out of range");
    }
    uint32_t word = a64_read_word(text, field);
    word = (word & ~(UINT32_C(0x3fff) << 5)) |
        (((uint32_t)immediate & UINT32_C(0x3fff)) << 5);
    a64_write_word(text, field, word);
}

/* Patch a 16-bit MOVZ/MOVK immediate at bits [20:5]. */
static void a64_patch_mov_imm16(Bytes *text, size_t field, uint32_t value) {
    uint32_t word = a64_read_word(text, field);
    word = (word & ~(UINT32_C(0xffff) << 5)) |
        ((value & UINT32_C(0xffff)) << 5);
    a64_write_word(text, field, word);
}

/* push xN : str xN, [sp, #-16]! */
static void a64_push(Bytes *text, unsigned reg) {
    a64_word(text, UINT32_C(0xf81f0fe0) | (reg & UINT32_C(0x1f)));
}

/* pop xN : ldr xN, [sp], #16 */
static void a64_pop(Bytes *text, unsigned reg) {
    a64_word(text, UINT32_C(0xf84107e0) | (reg & UINT32_C(0x1f)));
}

/* sub sp, sp, #frame (frame is a 16-byte multiple) */
static void a64_sub_sp(Bytes *text, uint32_t frame) {
    if (frame > 0xfff) fatal("aarch64 Core frame is too large");
    a64_word(text, UINT32_C(0xd10003ff) | ((frame & UINT32_C(0xfff)) << 10));
}

/*
 * Frame slots are addressed from `sp` rather than from `x29`. No function body
 * moves `sp` while a value is live, so the displacement is a constant either
 * way, and the unsigned scaled form reaches the whole frame instead of the 32
 * slots the signed 9-bit form covered — which matters now that spill slots and
 * saved registers share the frame with the parameters and locals.
 */
static uint32_t a64_slot_imm12(size_t slot) {
    if (slot > 0xfff) {
        fatal("aarch64 Core local frame is too large");
    }
    return (uint32_t)slot;
}

/* str xreg, [sp, #slot*8] */
static void a64_store_slot(Bytes *text, unsigned reg, size_t slot) {
    a64_word(
        text,
        UINT32_C(0xf9000000) |
            (a64_slot_imm12(slot) << 10) |
            (UINT32_C(31) << 5) |
            (reg & UINT32_C(0x1f))
    );
}

/* ldr xreg, [sp, #slot*8] */
static void a64_load_slot(Bytes *text, unsigned reg, size_t slot) {
    a64_word(
        text,
        UINT32_C(0xf9400000) |
            (a64_slot_imm12(slot) << 10) |
            (UINT32_C(31) << 5) |
            (reg & UINT32_C(0x1f))
    );
}

/* mov xd, xn : orr xd, xzr, xn */
static void a64_move_register(
    Bytes *text,
    unsigned destination,
    unsigned source
) {
    a64_word(
        text,
        UINT32_C(0xaa0003e0) |
            ((uint32_t)source << 16) |
            (uint32_t)destination
    );
}

/* movz xreg, #imm16, lsl #shift */
static void a64_movz_shifted(
    Bytes *text,
    unsigned reg,
    uint32_t immediate,
    unsigned shift
) {
    a64_word(
        text,
        UINT32_C(0xd2800000) |
            ((uint32_t)(shift / 16) << 21) |
            ((immediate & UINT32_C(0xffff)) << 5) |
            (uint32_t)reg
    );
}

/* movk xreg, #imm16, lsl #shift */
static void a64_movk_shifted(
    Bytes *text,
    unsigned reg,
    uint32_t immediate,
    unsigned shift
) {
    a64_word(
        text,
        UINT32_C(0xf2800000) |
            ((uint32_t)(shift / 16) << 21) |
            ((immediate & UINT32_C(0xffff)) << 5) |
            (uint32_t)reg
    );
}

/*
 * A signed 64-bit immediate as one `movz` plus a `movk` per remaining non-zero
 * halfword. Values that fit in 32 bits keep the existing one- or two-instruction
 * low-halfword-first sequence, so every image whose literals fit the old range
 * stays byte-identical; only wider values grow.
 */
static void a64_load_immediate(Bytes *text, unsigned reg, int64_t value) {
    uint64_t bits = (uint64_t)value;
    if (bits <= UINT32_MAX) {
        a64_movz(text, reg, (unsigned)(bits & UINT64_C(0xffff)));
        if ((bits >> 16) != 0) {
            a64_movk_lsl16(
                text,
                reg,
                (unsigned)((bits >> 16) & UINT64_C(0xffff))
            );
        }
        return;
    }
    bool started = false;
    for (unsigned shift = 0; shift < 64; shift += 16) {
        uint32_t half = (uint32_t)((bits >> shift) & UINT64_C(0xffff));
        if (half == 0 && started) continue;
        if (!started) {
            a64_movz_shifted(text, reg, half, shift);
            started = true;
        } else {
            a64_movk_shifted(text, reg, half, shift);
        }
    }
}

/*
 * Register allocation for the bounded AArch64 function profile
 * ------------------------------------------------------------
 *
 * The same contract x86-64 got in the pass above, over the same
 * target-independent analysis: every value in a function body is given its
 * location before a byte is emitted, so a body evaluates in registers instead
 * of pushing and popping the native stack.
 *
 * Only the classes differ. AAPCS64 makes `x19`-`x28` callee-saved, but the
 * shared Text runtime this backend calls preserves `x19`-`x26` and no emitted
 * code names `x27` or `x28`, so the call-safe class is exactly the set that is
 * demonstrably preserved. `x12`-`x15` are the caller-saved scratch class:
 * `x0`-`x7` are the AAPCS64 boundary, `x8` is the indirect-result register,
 * `x9`-`x11` are the fixed temporaries the checked multiply and the divide
 * sequences need, `x16`-`x18` are reserved by the platform, and `x29`/`x30`
 * are the frame pointer and link register the existing prologue already saves.
 *
 * `x0` and `x1` are never allocated, so they are always free as the move
 * scratch, as the divide operand pair, and as the call boundary. Allocation is
 * driven only by depth and slot index, so repeated builds of one source make
 * identical decisions, and no evaluation step moves `sp`, so a body keeps the
 * 16-byte alignment it was entered with at every AAPCS64 call boundary.
 */
enum {
    A64_CALL_SAFE_REGISTERS = 8,  /* x19-x26 */
    A64_SCRATCH_REGISTERS = 4,    /* x12-x15 */
    A64_ALLOCATABLE_REGISTERS =
        A64_CALL_SAFE_REGISTERS + A64_SCRATCH_REGISTERS,
    A64_NO_REGISTER = 32,
    A64_SCRATCH_A = 0, /* x0: the move scratch and the return register */
    A64_SCRATCH_B = 1, /* x1: the second operand of a spilled pair */
};

static const unsigned a64_call_safe_registers[A64_CALL_SAFE_REGISTERS] = {
    19, 20, 21, 22, 23, 24, 25, 26,
};

static const unsigned a64_scratch_registers[A64_SCRATCH_REGISTERS] = {
    12, 13, 14, 15,
};

static const TargetRegisterFile a64_register_file = {
    a64_scratch_registers,
    A64_SCRATCH_REGISTERS,
    a64_call_safe_registers,
    A64_CALL_SAFE_REGISTERS,
    A64_NO_REGISTER,
};

/*
 * A target that outgrows the shared arrays fails to compile here rather than
 * writing past their end. These are the only places the widths are asserted,
 * so a third target adds its two lines beside these.
 */
_Static_assert(
    (size_t)X64_ALLOCATABLE_REGISTERS <= (size_t)MAX_TARGET_ALLOCATABLE,
    "x86-64 allocatable registers exceed the shared frame layout"
);
_Static_assert(
    (size_t)A64_ALLOCATABLE_REGISTERS <= (size_t)MAX_TARGET_ALLOCATABLE,
    "AArch64 allocatable registers exceed the shared frame layout"
);
_Static_assert(
    (size_t)X64_CALL_SAFE_REGISTERS <= (size_t)MAX_TARGET_CALL_SAFE,
    "x86-64 call-safe registers exceed the shared frame layout"
);
_Static_assert(
    (size_t)A64_CALL_SAFE_REGISTERS <= (size_t)MAX_TARGET_CALL_SAFE,
    "AArch64 call-safe registers exceed the shared frame layout"
);


static FrameLayout a64_function_layout(
    const FunctionDeclaration *function
) {
    FrameLayout layout = {0};
    layout.target = &a64_register_file;
    layout.frame_slots =
        function->parameter_count + function->local_count;
    if (layout.frame_slots > MAX_TARGET_VALUE_SLOTS) {
        fatal("aarch64 Core function has too many bindings");
    }
    for (size_t slot = 0; slot < MAX_TARGET_VALUE_SLOTS; ++slot) {
        layout.slot_register[slot] = A64_NO_REGISTER;
    }
    for (size_t depth = 0; depth < A64_ALLOCATABLE_REGISTERS; ++depth) {
        layout.eval_register[depth] = A64_NO_REGISTER;
    }

    FunctionPressure pressure = {0};
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        function_expression_pressure(statement->condition, 0, &pressure);
        function_expression_pressure(statement->value, 0, &pressure);
    }
    layout.eval_depth = pressure.depth;

    size_t tracked = pressure.depth < A64_ALLOCATABLE_REGISTERS
        ? pressure.depth
        : (size_t)A64_ALLOCATABLE_REGISTERS;
    RegisterFile file = { .target = &a64_register_file };
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (!pressure.across_call[depth]) continue;
        layout.eval_register[depth] = target_take_eval_register(&file, true);
    }
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (pressure.across_call[depth]) continue;
        layout.eval_register[depth] = target_take_eval_register(&file, false);
    }
    bool calls = function_body_calls(function);
    for (size_t slot = 0; slot < layout.frame_slots; ++slot) {
        layout.slot_register[slot] = target_take_value_register(
            &file,
            calls,
            function_slot_uses(function, slot)
        );
    }
    for (size_t depth = 0; depth < tracked; ++depth) {
        if (layout.eval_register[depth] != A64_NO_REGISTER) continue;
        layout.eval_spill[depth] = layout.spill_slots++;
    }
    layout.deep_spill_base = layout.spill_slots;
    if (pressure.depth > A64_ALLOCATABLE_REGISTERS) {
        layout.spill_slots +=
            pressure.depth - (size_t)A64_ALLOCATABLE_REGISTERS;
    }
    for (size_t index = 0; index < A64_CALL_SAFE_REGISTERS; ++index) {
        unsigned reg = a64_call_safe_registers[index];
        if (!file.taken[reg]) continue;
        layout.saved[layout.saved_count++] = reg;
    }
    size_t slots =
        layout.frame_slots + layout.spill_slots + layout.saved_count;
    layout.frame_bytes =
        (uint32_t)(((slots * sizeof(uint64_t)) + 15) / 16 * 16);
    return layout;
}

/*
 * A 64-bit operand that is either a register or the frame slot at
 * `[sp, #slot * 8]`.
 */

/* Where the value produced at `depth` lives: a register or a spill slot. */

/* Where a parameter or local lives: a register or its existing frame slot. */

static size_t a64_saved_slot(const FrameLayout *layout, size_t index) {
    return layout->frame_slots + layout->spill_slots + index;
}

/*
 * Moves one 64-bit value between two locations. `x0` is never allocated, so it
 * is always available when both locations are frame slots.
 */
static void a64_move(Bytes *text, Operand into, Operand from) {
    if (into.in_register && from.in_register) {
        if (into.reg == from.reg) return;
        a64_move_register(text, into.reg, from.reg);
        return;
    }
    if (into.in_register) {
        a64_load_slot(text, into.reg, from.slot);
        return;
    }
    if (from.in_register) {
        a64_store_slot(text, from.reg, into.slot);
        return;
    }
    if (into.slot == from.slot) return;
    a64_load_slot(text, A64_SCRATCH_A, from.slot);
    a64_store_slot(text, A64_SCRATCH_A, into.slot);
}

/* The register holding `operand`, loading a spilled one into `scratch`. */
static unsigned a64_operand_register(
    Bytes *text,
    Operand operand,
    unsigned scratch
) {
    if (operand.in_register) return operand.reg;
    a64_load_slot(text, scratch, operand.slot);
    return scratch;
}

static void a64_function_epilogue(Bytes *text) {
    a64_word(text, UINT32_C(0x910003bf)); /* mov sp, x29 */
    a64_word(text, UINT32_C(0xa8c17bfd)); /* ldp x29, x30, [sp], #16 */
    a64_word(text, UINT32_C(0xd65f03c0)); /* ret */
}

/*
 * Restores every callee-saved register the body claimed and returns. The saved
 * slots are read while `sp` still addresses the frame, and `mov sp, x29` then
 * drops the whole of it. One body emits this once and every earlier return
 * branches to it, so all return paths restore exactly the same set at exactly
 * one place.
 */
static void a64_function_epilogue_block(
    Bytes *text,
    const FrameLayout *layout
) {
    for (size_t index = layout->saved_count; index > 0; --index) {
        a64_load_slot(
            text,
            layout->saved[index - 1],
            a64_saved_slot(layout, index - 1)
        );
    }
    a64_function_epilogue(text);
}

/*
 * Compares the values at `depth` and `depth + 1`, left minus right, leaving the
 * answer in the flags. Either side may be spilled; `x0` and `x1` carry those.
 */
static void a64_function_compare(
    Bytes *text,
    const FrameLayout *layout,
    size_t depth
) {
    unsigned left = a64_operand_register(
        text,
        target_eval_operand(layout, depth),
        A64_SCRATCH_A
    );
    unsigned right = a64_operand_register(
        text,
        target_eval_operand(layout, depth + 1),
        A64_SCRATCH_B
    );
    /* cmp left, right : subs xzr, left, right */
    a64_word(
        text,
        UINT32_C(0xeb00001f) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5)
    );
}

/*
 * The AArch64 counterpart of x64_function_guard_inverse: the branch that skips
 * a guard body is taken when the comparison is false, so a guard leaves its
 * answer in the flags instead of materializing a Bool and testing it back.
 */
static bool a64_function_guard_inverse(
    FunctionExpressionKind kind,
    uint32_t *inverse
) {
    if (kind == FUNCTION_EQUAL) {
        *inverse = UINT32_C(1);  /* b.ne */
    } else if (kind == FUNCTION_NOT_EQUAL) {
        *inverse = UINT32_C(0);  /* b.eq */
    } else if (kind == FUNCTION_LESS) {
        *inverse = UINT32_C(10); /* b.ge */
    } else if (kind == FUNCTION_LESS_EQUAL) {
        *inverse = UINT32_C(12); /* b.gt */
    } else if (kind == FUNCTION_GREATER) {
        *inverse = UINT32_C(13); /* b.le */
    } else if (kind == FUNCTION_GREATER_EQUAL) {
        *inverse = UINT32_C(11); /* b.lt */
    } else {
        return false;
    }
    return true;
}

static void a64_overflow_jump(
    Bytes *text,
    FunctionEmitter *emitter,
    uint32_t conditional,
    FunctionTrapKind kind
) {
    offsets_add(&emitter->trap_jumps[kind], text->length);
    a64_word(text, conditional);
}

/*
 * Integer division on AArch64
 * ---------------------------
 *
 * `sdiv` is the mirror image of x86-64's `idiv`: it never faults. A zero
 * divisor silently yields zero and `INT64_MIN / -1` silently yields
 * `INT64_MIN`, so omitting either guard produces a wrong answer rather than a
 * crash. Both are therefore checked before the divide, exactly as on x86-64,
 * and for the same reasons: the `-1` divisor is the whole of the second case,
 * its quotient is `-left` whose overflow `negs` reports in `V`, and its
 * remainder is always zero.
 *
 * `sdiv` truncates, so `//` and `%` correct toward negative infinity when the
 * remainder is non-zero and its sign differs from the divisor's. `x9`, `x10`,
 * and `x11` are the established expression temporaries here — the checked
 * multiply already uses exactly those three.
 */
static void a64_function_divide(
    Bytes *text,
    FunctionExpressionKind kind,
    FunctionEmitter *emitter,
    Operand result,
    Operand divisor
) {
    /* `x0` and `x1` are never allocated, so the operand pair can always be
     * materialized there without disturbing anything live. */
    a64_move(text, target_register_operand(A64_SCRATCH_A), result);
    a64_move(text, target_register_operand(A64_SCRATCH_B), divisor);
    /* cbz x1, division-by-zero trap */
    offsets_add(
        &emitter->trap_jumps[function_divide_zero_trap(kind)],
        text->length
    );
    a64_word(text, UINT32_C(0xb4000001));
    a64_word(text, UINT32_C(0xb100043f)); /* cmn x1, #1 */
    size_t general = text->length;
    a64_word(text, UINT32_C(0x54000001)); /* b.ne general */
    if (kind == FUNCTION_FLOOR_MODULO) {
        a64_word(text, UINT32_C(0xaa1f03e0)); /* mov x0, xzr */
    } else {
        a64_word(text, UINT32_C(0xeb0003e0)); /* negs x0, x0 */
        a64_overflow_jump(
            text,
            emitter,
            UINT32_C(0x54000006),
            function_divide_overflow_trap(kind)
        ); /* b.vs */
    }
    size_t done = text->length;
    a64_word(text, UINT32_C(0x14000000)); /* b done */
    a64_patch_imm19(text, general, text->length);
    a64_word(text, UINT32_C(0x9ac10c09)); /* sdiv x9, x0, x1 */
    size_t exact;
    if (kind == FUNCTION_FLOOR_MODULO) {
        a64_word(text, UINT32_C(0x9b018120)); /* msub x0, x9, x1, x0 */
        exact = text->length;
        a64_word(text, UINT32_C(0xb4000000)); /* cbz x0, done */
        a64_word(text, UINT32_C(0xca01000b)); /* eor x11, x0, x1 */
    } else {
        a64_word(text, UINT32_C(0x9b01812a)); /* msub x10, x9, x1, x0 */
        a64_word(text, UINT32_C(0xaa0903e0)); /* mov x0, x9 */
        exact = text->length;
        a64_word(text, UINT32_C(0xb400000a)); /* cbz x10, done */
        a64_word(text, UINT32_C(0xca01014b)); /* eor x11, x10, x1 */
    }
    size_t same = text->length;
    a64_word(text, UINT32_C(0xb6f8000b)); /* tbz x11, #63, done */
    if (kind == FUNCTION_FLOOR_MODULO) {
        a64_word(text, UINT32_C(0x8b010000)); /* add x0, x0, x1 */
    } else {
        a64_word(text, UINT32_C(0xd1000400)); /* sub x0, x0, #1 */
    }
    a64_patch_imm19(text, exact, text->length);
    a64_patch_imm14(text, same, text->length);
    a64_patch_imm26(text, done, text->length);
    a64_move(text, result, target_register_operand(A64_SCRATCH_A));
}

static void a64_function_call(
    Bytes *text,
    FunctionEmitter *emitter,
    size_t function_index
) {
    function_call_fixup_add(&emitter->calls, text->length, function_index);
    a64_word(text, UINT32_C(0x94000000)); /* bl (patched) */
}

static void a64_function_expression(
    Bytes *text,
    const FunctionExpression *expression,
    FunctionEmitter *emitter,
    const FrameLayout *layout,
    size_t depth
) {
    Operand result = target_eval_operand(layout, depth);
    if (expression->kind == FUNCTION_LITERAL) {
        unsigned reg = result.in_register ? result.reg : A64_SCRATCH_A;
        a64_load_immediate(text, reg, expression->value);
        if (!result.in_register) a64_store_slot(text, reg, result.slot);
        return;
    }
    if (expression->kind == FUNCTION_PARAMETER) {
        a64_move(text, result, target_value_operand(layout, expression->slot));
        return;
    }
    if (expression->kind == FUNCTION_TEXT_LITERAL) {
        emitter->a64_runtime.used = true;
        unsigned reg = result.in_register ? result.reg : A64_SCRATCH_A;
        size_t low_field = text->length;
        a64_movz(text, reg, 0);            /* Text address low, patched */
        size_t high_field = text->length;
        a64_movk_lsl16(text, reg, 0);      /* Text address high, patched */
        a64_text_fixups_add(
            &emitter->a64_runtime.text_literals,
            low_field,
            high_field,
            expression->text_value,
            expression->text_length
        );
        if (!result.in_register) a64_store_slot(text, reg, result.slot);
        return;
    }
    if (expression->kind == FUNCTION_TEXT_CONCAT) {
        a64_function_expression(
            text,
            expression->left,
            emitter,
            layout,
            depth
        );
        a64_function_expression(
            text,
            expression->right,
            emitter,
            layout,
            depth + 1
        );
        /* Neither boundary register is ever allocated, so filling them cannot
         * overwrite the operand that has not been moved yet. */
        a64_move(text, target_register_operand(0), result);
        a64_move(
            text,
            target_register_operand(1),
            target_eval_operand(layout, depth + 1)
        );
        a64_core_call_runtime(
            text,
            &emitter->a64_runtime,
            &emitter->a64_runtime.text_concat_calls
        );
        a64_move(text, result, target_register_operand(0));
        return;
    }
    if (expression->kind == FUNCTION_CALL) {
        for (size_t index = 0; index < expression->argument_count; ++index) {
            a64_function_expression(
                text,
                expression->arguments[index],
                emitter,
                layout,
                depth + index
            );
        }
        for (size_t index = 0; index < expression->argument_count; ++index) {
            if (index >= MAX_CORE_PARAMETERS) {
                fatal("aarch64 Core call has too many arguments");
            }
            /* Argument registers are never allocated, so filling the boundary
             * cannot overwrite an argument that has not been moved yet. */
            a64_move(
                text,
                target_register_operand((unsigned)index),
                target_eval_operand(layout, depth + index)
            );
        }
        a64_function_call(text, emitter, expression->function_index);
        a64_move(text, result, target_register_operand(0));
        return;
    }
    if (expression->kind == FUNCTION_SYSCALL) {
        /*
         * The AArch64 syscall ABI is a different boundary — `x8` carries the
         * number, `x0`..`x5` the arguments — and is a separate checkpoint.
         * `main` diagnoses this program before lowering starts, so reaching
         * here means that check was lost; refuse rather than emit an image
         * whose intrinsics do nothing.
         */
        fatal("aarch64 Core does not lower the Linux syscall intrinsics");
    }
    if (expression->kind == FUNCTION_NEGATE) {
        a64_function_expression(
            text,
            expression->left,
            emitter,
            layout,
            depth
        );
        unsigned source =
            a64_operand_register(text, result, A64_SCRATCH_A);
        unsigned into = result.in_register ? result.reg : A64_SCRATCH_A;
        /* negs into, xzr, source */
        a64_word(
            text,
            UINT32_C(0xeb0003e0) |
                ((uint32_t)source << 16) |
                (uint32_t)into
        );
        a64_overflow_jump(
            text,
            emitter,
            UINT32_C(0x54000006),
            FUNCTION_TRAP_NEGATE_OVERFLOW
        ); /* b.vs */
        if (!result.in_register) a64_store_slot(text, into, result.slot);
        return;
    }

    a64_function_expression(text, expression->left, emitter, layout, depth);
    a64_function_expression(
        text,
        expression->right,
        emitter,
        layout,
        depth + 1
    );
    Operand right = target_eval_operand(layout, depth + 1);
    if (expression->kind == FUNCTION_FLOOR_DIVIDE ||
        expression->kind == FUNCTION_FLOOR_MODULO) {
        a64_function_divide(text, expression->kind, emitter, result, right);
        return;
    }
    unsigned left_reg = a64_operand_register(text, result, A64_SCRATCH_A);
    unsigned right_reg = a64_operand_register(text, right, A64_SCRATCH_B);
    unsigned into = result.in_register ? result.reg : A64_SCRATCH_A;
    uint32_t operands =
        ((uint32_t)right_reg << 16) | ((uint32_t)left_reg << 5);
    if (expression->kind == FUNCTION_ADD) {
        /* adds into, left, right */
        a64_word(text, UINT32_C(0xab000000) | operands | (uint32_t)into);
        a64_overflow_jump(
            text,
            emitter,
            UINT32_C(0x54000006),
            FUNCTION_TRAP_ADD_OVERFLOW
        ); /* b.vs */
    } else if (expression->kind == FUNCTION_SUBTRACT) {
        /* subs into, left, right */
        a64_word(text, UINT32_C(0xeb000000) | operands | (uint32_t)into);
        a64_overflow_jump(
            text,
            emitter,
            UINT32_C(0x54000006),
            FUNCTION_TRAP_SUBTRACT_OVERFLOW
        ); /* b.vs */
    } else if (expression->kind == FUNCTION_MULTIPLY) {
        /* x9, x10 and x11 are never allocated, so the wide product and the
         * sign it is compared against cannot disturb anything live. */
        a64_word(text, UINT32_C(0x9b007c09) | operands); /* mul   x9  */
        a64_word(text, UINT32_C(0x9b407c0a) | operands); /* smulh x10 */
        a64_word(text, UINT32_C(0x937ffd2b)); /* asr   x11, x9, #63 */
        a64_word(text, UINT32_C(0xeb0b015f)); /* cmp   x10, x11 */
        a64_overflow_jump(
            text,
            emitter,
            UINT32_C(0x54000001),
            FUNCTION_TRAP_MULTIPLY_OVERFLOW
        ); /* b.ne */
        a64_move_register(text, into, 9);
    } else {
        /* cmp left, right */
        a64_word(text, UINT32_C(0xeb00001f) | operands);
        uint32_t set = UINT32_C(0x9a9f17e0); /* cset eq */
        if (expression->kind == FUNCTION_NOT_EQUAL) {
            set = UINT32_C(0x9a9f07e0); /* cset ne */
        } else if (expression->kind == FUNCTION_LESS) {
            set = UINT32_C(0x9a9fa7e0); /* cset lt */
        } else if (expression->kind == FUNCTION_LESS_EQUAL) {
            set = UINT32_C(0x9a9fc7e0); /* cset le */
        } else if (expression->kind == FUNCTION_GREATER) {
            set = UINT32_C(0x9a9fd7e0); /* cset gt */
        } else if (expression->kind == FUNCTION_GREATER_EQUAL) {
            set = UINT32_C(0x9a9fb7e0); /* cset ge */
        }
        a64_word(text, set | (uint32_t)into);
    }
    if (!result.in_register) a64_store_slot(text, into, result.slot);
}

/*
 * The AArch64 counterpart of x64_function_tail_call. The arguments are
 * evaluated into their ordinary depths first, so nothing reads a parameter
 * after the assignment below has started to overwrite one, and no evaluation
 * depth shares a location with a parameter. Only the `bl` at the end is
 * replaced, either by a branch back to the top of this body or by a frame
 * teardown and a branch to the callee.
 */
static void a64_function_tail_call(
    Bytes *text,
    const FunctionExpression *call,
    FunctionEmitter *emitter,
    const FrameLayout *layout,
    size_t self_index,
    size_t body_start
) {
    /* Source order for evaluation, declaration order for the ABI vector below —
     * the same separation the x86-64 emitter makes, so both targets observe the
     * same evaluation order for a labelled call. */
    for (size_t written = 0; written < call->argument_count; ++written) {
        size_t index = call->argument_order[written];
        if (index >= MAX_CORE_PARAMETERS) {
            fatal("aarch64 Core call has too many arguments");
        }
        a64_function_expression(
            text,
            call->arguments[index],
            emitter,
            layout,
            index
        );
    }
    if (call->function_index == self_index) {
        for (size_t index = 0; index < call->argument_count; ++index) {
            a64_move(
                text,
                target_value_operand(layout, index),
                target_eval_operand(layout, index)
            );
        }
        size_t back = text->length;
        a64_word(text, UINT32_C(0x14000000)); /* b body_start */
        a64_patch_imm26(text, back, body_start);
        return;
    }
    /* Argument registers are never allocated, so filling the boundary cannot
     * overwrite an argument that has not been moved yet. */
    for (size_t index = 0; index < call->argument_count; ++index) {
        a64_move(
            text,
            target_register_operand((unsigned)index),
            target_eval_operand(layout, index)
        );
    }
    /* The saved registers still live in frame slots, so they are reloaded
     * while `sp` addresses the frame and before it is dropped. Neither step
     * touches an argument register. */
    for (size_t index = layout->saved_count; index > 0; --index) {
        a64_load_slot(
            text,
            layout->saved[index - 1],
            a64_saved_slot(layout, index - 1)
        );
    }
    a64_word(text, UINT32_C(0x910003bf)); /* mov sp, x29 */
    a64_word(text, UINT32_C(0xa8c17bfd)); /* ldp x29, x30, [sp], #16 */
    function_call_fixup_add(
        &emitter->calls,
        text->length,
        call->function_index
    );
    a64_word(text, UINT32_C(0x14000000)); /* b callee (patched) */
}

static void a64_function_declaration(
    Bytes *text,
    const FunctionDeclaration *function,
    size_t self_index,
    FunctionEmitter *emitter
) {
    FrameLayout layout = a64_function_layout(function);
    a64_word(text, UINT32_C(0xa9bf7bfd)); /* stp x29, x30, [sp, #-16]! */
    a64_word(text, UINT32_C(0x910003fd)); /* mov x29, sp */
    if (layout.frame_bytes > 0) {
        a64_sub_sp(text, layout.frame_bytes);
    }
    for (size_t index = 0; index < layout.saved_count; ++index) {
        a64_store_slot(
            text,
            layout.saved[index],
            a64_saved_slot(&layout, index)
        );
    }
    for (size_t index = 0; index < function->parameter_count; ++index) {
        if (index >= MAX_CORE_PARAMETERS) {
            fatal("aarch64 Core parameter register is unavailable");
        }
        a64_move(
            text,
            target_value_operand(&layout, index),
            target_register_operand((unsigned)index)
        );
    }
    /* A returned call to this same function reassigns the parameters and
     * branches here, so the frame, the saved registers, and the argument
     * hand-off are each paid for exactly once. */
    size_t body_start = text->length;

    /* Every return path reaches the one epilogue emitted after the body. */
    Offsets returns = {0};
    bool returned = false;
    for (size_t index = 0; index < function->statement_count; ++index) {
        const FunctionStatement *statement = &function->statements[index];
        bool tail = index + 1 == function->statement_count;
        if (statement->kind == FUNCTION_STATEMENT_IF_RETURN) {
            uint32_t inverse = 0;
            size_t skip;
            if (a64_function_guard_inverse(
                    statement->condition->kind,
                    &inverse)) {
                /* Both operands evaluate exactly as they would on their own;
                 * only the Bool between the comparison and the branch is
                 * gone. */
                a64_function_expression(
                    text,
                    statement->condition->left,
                    emitter,
                    &layout,
                    0
                );
                a64_function_expression(
                    text,
                    statement->condition->right,
                    emitter,
                    &layout,
                    1
                );
                a64_function_compare(text, &layout, 0);
                skip = text->length;
                a64_word(text, UINT32_C(0x54000000) | inverse);
            } else {
                a64_function_expression(
                    text,
                    statement->condition,
                    emitter,
                    &layout,
                    0
                );
                unsigned condition = a64_operand_register(
                    text,
                    target_eval_operand(&layout, 0),
                    A64_SCRATCH_A
                );
                skip = text->length;
                /* cbz condition, skip */
                a64_word(text, UINT32_C(0xb4000000) | (uint32_t)condition);
            }
            const FunctionExpression *tail_call = function_tail_call(statement);
            if (tail_call != NULL) {
                a64_function_tail_call(
                    text,
                    tail_call,
                    emitter,
                    &layout,
                    self_index,
                    body_start
                );
            } else {
                a64_function_expression(
                    text,
                    statement->value,
                    emitter,
                    &layout,
                    0
                );
                a64_move(
                    text,
                    target_register_operand(0),
                    target_eval_operand(&layout, 0)
                );
                offsets_add(&returns, text->length);
                a64_word(text, UINT32_C(0x14000000)); /* b epilogue */
            }
            a64_patch_imm19(text, skip, text->length);
        } else if (statement->kind == FUNCTION_STATEMENT_RETURN) {
            const FunctionExpression *tail_call = function_tail_call(statement);
            if (tail_call != NULL) {
                /* The branch itself ends this path; nothing falls through to
                 * the epilogue and nothing jumps to it from here. */
                a64_function_tail_call(
                    text,
                    tail_call,
                    emitter,
                    &layout,
                    self_index,
                    body_start
                );
                returned = true;
                continue;
            }
            a64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            a64_move(
                text,
                target_register_operand(0),
                target_eval_operand(&layout, 0)
            );
            /* A closing return falls straight into the epilogue. */
            if (!tail) {
                offsets_add(&returns, text->length);
                a64_word(text, UINT32_C(0x14000000)); /* b epilogue */
            }
            returned = true;
        } else if (statement->kind == FUNCTION_STATEMENT_PRINT) {
            a64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            a64_move(
                text,
                target_register_operand(0),
                target_eval_operand(&layout, 0)
            );
            if (statement->value->value_kind == FUNCTION_VALUE_TEXT) {
                offsets_add(&emitter->print_text_calls, text->length);
            } else {
                offsets_add(&emitter->print_int_calls, text->length);
            }
            a64_word(text, UINT32_C(0x94000000)); /* bl print (patched) */
        } else if (statement->kind == FUNCTION_STATEMENT_LET) {
            a64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
            a64_move(
                text,
                target_value_operand(&layout, statement->slot),
                target_eval_operand(&layout, 0)
            );
        } else {
            /* The evaluated result is discarded. */
            a64_function_expression(
                text,
                statement->value,
                emitter,
                &layout,
                0
            );
        }
    }
    if (!returned) {
        a64_movz(text, 0, 0); /* implicit main return 0 */
    }
    size_t epilogue = text->length;
    for (size_t index = 0; index < returns.length; ++index) {
        a64_patch_imm26(text, returns.fields[index], epilogue);
    }
    a64_function_epilogue_block(text, &layout);
    free(returns.fields);
}

/*
 * Print a signed 64-bit integer in decimal followed by a newline, matching
 * x64_function_print_runtime. The value arrives in x0; digits are written into
 * a stack buffer from the right and the whole run is emitted with one write(2).
 */
static size_t a64_function_print_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    a64_word(text, UINT32_C(0xa9bf7bfd)); /* stp x29, x30, [sp, #-16]! */
    a64_word(text, UINT32_C(0x910003fd)); /* mov x29, sp */
    a64_sub_sp(text, 32);                 /* sub sp, sp, #32 (buffer) */
    a64_word(text, UINT32_C(0xaa0003eb)); /* mov  x11, x0 (value) */
    a64_movz(text, 10, 0);                /* mov  x10, #0 (sign flag) */
    a64_movz(text, 14, 10);               /* mov  x14, #10 ('\n') */
    a64_word(text, UINT32_C(0xd10007a9)); /* sub  x9, x29, #1 */
    a64_word(text, UINT32_C(0x3900012e)); /* strb w14, [x9] */
    a64_word(text, UINT32_C(0xf100017f)); /* cmp  x11, #0 */
    size_t nonnegative = text->length;
    a64_word(text, UINT32_C(0x5400000a)); /* b.ge magnitude */
    a64_word(text, UINT32_C(0xcb0b03eb)); /* neg  x11, x11 */
    a64_movz(text, 10, 1);                /* mov  x10, #1 (negative) */
    size_t magnitude = text->length;
    a64_patch_imm19(text, nonnegative, magnitude);
    size_t to_digits = text->length;
    a64_word(text, UINT32_C(0xb500000b)); /* cbnz x11, digits */
    a64_word(text, UINT32_C(0xd1000529)); /* sub  x9, x9, #1 */
    a64_movz(text, 14, 48);               /* mov  x14, #'0' */
    a64_word(text, UINT32_C(0x3900012e)); /* strb w14, [x9] */
    size_t to_sign = text->length;
    a64_word(text, UINT32_C(0x14000000)); /* b sign */
    size_t digits = text->length;
    a64_patch_imm19(text, to_digits, digits);
    a64_movz(text, 13, 10);               /* mov  x13, #10 */
    size_t digit_loop = text->length;
    a64_word(text, UINT32_C(0x9acd096c)); /* udiv x12, x11, x13 */
    a64_word(text, UINT32_C(0x9b0dad8e)); /* msub x14, x12, x13, x11 */
    a64_word(text, UINT32_C(0x9100c1ce)); /* add  x14, x14, #48 */
    a64_word(text, UINT32_C(0xd1000529)); /* sub  x9, x9, #1 */
    a64_word(text, UINT32_C(0x3900012e)); /* strb w14, [x9] */
    a64_word(text, UINT32_C(0xaa0c03eb)); /* mov  x11, x12 */
    size_t digit_back = text->length;
    a64_word(text, UINT32_C(0xb500000b)); /* cbnz x11, digit_loop */
    a64_patch_imm19(text, digit_back, digit_loop);
    size_t sign = text->length;
    a64_patch_imm26(text, to_sign, sign);
    size_t to_write = text->length;
    a64_word(text, UINT32_C(0xb400000a)); /* cbz x10, write */
    a64_word(text, UINT32_C(0xd1000529)); /* sub  x9, x9, #1 */
    a64_movz(text, 14, 45);               /* mov  x14, #'-' */
    a64_word(text, UINT32_C(0x3900012e)); /* strb w14, [x9] */
    size_t write = text->length;
    a64_patch_imm19(text, to_write, write);
    a64_word(text, UINT32_C(0xcb0903a2)); /* sub  x2, x29, x9 (length) */
    a64_word(text, UINT32_C(0xaa0903e1)); /* mov  x1, x9 (buffer) */
    a64_movz(text, 0, 1);                 /* mov  x0, #1 (stdout) */
    a64_movz(text, 8, 64);                /* mov  x8, #64 (write) */
    a64_svc(text);
    a64_function_epilogue(text);
    return runtime_at;
}

/*
 * Print a Text value followed by a newline. The Text pointer (to
 * [i64 byte-length][UTF-8 bytes]) arrives in x0, mirroring
 * x64_function_print_text_runtime and the aggregate print(Text) path. The fixed
 * DATA_ADDRESS+2 byte supplies the newline, so no fixup is needed. This is a
 * leaf routine: it preserves x30 and returns with ret.
 */
static size_t a64_function_print_text_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    a64_load_u64(text, 2, 0, 0);       /* x2 = UTF-8 byte length from [x0] */
    a64_add_immediate(text, 1, 0, 8);  /* x1 = x0 + 8 (UTF-8 bytes) */
    a64_movz(text, 0, 1);              /* x0 = 1 (stdout) */
    a64_movz(text, 8, 64);             /* x8 = 64 (write) */
    a64_svc(text);
    a64_load_address(text, 1, DATA_ADDRESS + 2); /* newline byte */
    a64_movz(text, 0, 1);              /* stdout */
    a64_movz(text, 2, 1);              /* length 1 */
    a64_movz(text, 8, 64);             /* write */
    a64_svc(text);
    a64_word(text, UINT32_C(0xd65f03c0)); /* ret */
    return runtime_at;
}

static size_t a64_function_trap_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    a64_movz(text, 0, 2);                 /* stderr */
    a64_movz(text, 8, 64);                /* write */
    a64_svc(text);
    a64_movz(text, 0, 1);                 /* status 1 */
    a64_movz(text, 8, 93);                /* exit */
    a64_svc(text);
    a64_word(text, UINT32_C(0xd4200000)); /* brk after exit */
    return runtime_at;
}

static size_t a64_function_trap_stub(
    Bytes *text,
    Bytes *data,
    FunctionTrapKind kind,
    size_t runtime_at
) {
    size_t length = 0;
    uint64_t address = function_trap_data(data, kind, &length);
    size_t stub_at = text->length;
    a64_load_address(text, 1, address);
    a64_movz(text, 2, (unsigned)length);
    size_t runtime_jump = text->length;
    a64_word(text, UINT32_C(0x14000000)); /* b trap runtime */
    a64_patch_imm26(text, runtime_jump, runtime_at);
    return stub_at;
}

static void a64_function_program(
    Bytes *text,
    Bytes *data,
    const FunctionProgram *program
) {
    FunctionEmitter emitter = {0};
    size_t function_addresses[MAX_CORE_FUNCTIONS] = {0};

    size_t entry_call = text->length;
    a64_word(text, UINT32_C(0x94000000)); /* bl main (patched) */
    a64_movz(text, 8, 93);                /* mov x8, #93 (exit) */
    a64_svc(text);
    a64_word(text, UINT32_C(0xd4200000)); /* brk #0 after exit */

    for (size_t index = 0; index < program->function_count; ++index) {
        function_addresses[index] = text->length;
        a64_function_declaration(
            text,
            &program->functions[index],
            index,
            &emitter
        );
    }

    size_t print_at = a64_function_print_runtime(text);
    size_t print_text_at = 0;
    if (emitter.print_text_calls.length > 0) {
        print_text_at = a64_function_print_text_runtime(text);
    }

    size_t trap_at[FUNCTION_TRAP_COUNT] = {0};
    bool has_trap = false;
    for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
        if (emitter.trap_jumps[kind].length > 0) has_trap = true;
    }
    if (has_trap) {
        size_t trap_runtime_at = a64_function_trap_runtime(text);
        for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
            if (emitter.trap_jumps[kind].length == 0) continue;
            trap_at[kind] = a64_function_trap_stub(
                text,
                data,
                (FunctionTrapKind)kind,
                trap_runtime_at
            );
        }
    }

    a64_patch_imm26(
        text,
        entry_call,
        function_addresses[program->main_index]
    );
    for (size_t index = 0; index < emitter.calls.length; ++index) {
        FunctionCallFixup fixup = emitter.calls.items[index];
        a64_patch_imm26(
            text,
            fixup.field,
            function_addresses[fixup.function_index]
        );
    }
    for (
        size_t index = 0;
        index < emitter.print_int_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            emitter.print_int_calls.fields[index],
            print_at
        );
    }
    for (
        size_t index = 0;
        index < emitter.print_text_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            emitter.print_text_calls.fields[index],
            print_text_at
        );
    }
    for (size_t kind = 0; kind < FUNCTION_TRAP_COUNT; ++kind) {
        for (size_t index = 0;
             index < emitter.trap_jumps[kind].length;
             ++index) {
            a64_patch_imm19(
                text,
                emitter.trap_jumps[kind].fields[index],
                trap_at[kind]
            );
        }
    }
    a64_core_runtime(text, &emitter.a64_runtime);
    function_emitter_free(&emitter);
}

/*
 * AArch64 local/List/Text Core.
 *
 * Values use the same stack-machine discipline and aggregate ABIs as x86-64:
 * List is `[length: i64][element: i64] * length`; Text is
 * `[UTF-8 byte length: i64][bytes]`. x19..x26 hold loop state across runtime
 * calls; expression temporaries use x0/x1/x9 and 16-byte stack cells. Every
 * fixed word was checked with
 * `llvm-mc --triple=aarch64 --show-encoding`.
 */

/*
 * A64TextFixup / A64TextFixups / A64CoreRuntime are defined earlier, before
 * FunctionEmitter, so the shared function emitter can embed the AArch64 Text
 * runtime and reuse it for Text parameters, results, concatenation, literals,
 * and print(Text).
 */

static void a64_text_fixups_add(
    A64TextFixups *fixups,
    size_t low_field,
    size_t high_field,
    const uint8_t *value,
    size_t length
) {
    if (fixups->length == fixups->capacity) {
        size_t capacity =
            fixups->capacity == 0 ? 8 : fixups->capacity * 2;
        A64TextFixup *grown = realloc(
            fixups->items,
            capacity * sizeof(*fixups->items)
        );
        if (grown == NULL) fatal("out of memory");
        fixups->items = grown;
        fixups->capacity = capacity;
    }
    fixups->items[fixups->length++] = (A64TextFixup){
        .low_field = low_field,
        .high_field = high_field,
        .value = value,
        .length = length,
    };
}

static void a64_core_runtime_free(A64CoreRuntime *runtime) {
    free(runtime->allocate_calls.fields);
    free(runtime->oom_jumps.fields);
    free(runtime->list_index_jumps.fields);
    free(runtime->text_index_jumps.fields);
    free(runtime->text_concat_calls.fields);
    free(runtime->text_equal_calls.fields);
    free(runtime->text_length_calls.fields);
    free(runtime->text_index_calls.fields);
    free(runtime->text_chars_calls.fields);
    free(runtime->text_literals.items);
}

static void a64_subtract(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0xcb000000) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

static void a64_compare(
    Bytes *text,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0xeb00001f) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5)
    );
}

static void a64_compare_zero(Bytes *text, unsigned source) {
    a64_word(
        text,
        UINT32_C(0xf100001f) | ((uint32_t)source << 5)
    );
}

static void a64_load_u64(
    Bytes *text,
    unsigned destination,
    unsigned address,
    unsigned offset
) {
    if (offset % sizeof(uint64_t) != 0 ||
        offset / sizeof(uint64_t) > UINT32_C(0xfff)) {
        fatal("aarch64 Core load offset is out of range");
    }
    a64_word(
        text,
        UINT32_C(0xf9400000) |
            ((uint32_t)(offset / sizeof(uint64_t)) << 10) |
            ((uint32_t)address << 5) |
            (uint32_t)destination
    );
}

static void a64_store_u64(
    Bytes *text,
    unsigned source,
    unsigned address,
    unsigned offset
) {
    if (offset % sizeof(uint64_t) != 0 ||
        offset / sizeof(uint64_t) > UINT32_C(0xfff)) {
        fatal("aarch64 Core store offset is out of range");
    }
    a64_word(
        text,
        UINT32_C(0xf9000000) |
            ((uint32_t)(offset / sizeof(uint64_t)) << 10) |
            ((uint32_t)address << 5) |
            (uint32_t)source
    );
}

static void a64_load_indexed(
    Bytes *text,
    unsigned destination,
    unsigned address,
    unsigned index
) {
    a64_word(
        text,
        UINT32_C(0xf8607800) |
            ((uint32_t)index << 16) |
            ((uint32_t)address << 5) |
            (uint32_t)destination
    );
}

static void a64_store_indexed(
    Bytes *text,
    unsigned source,
    unsigned address,
    unsigned index
) {
    a64_word(
        text,
        UINT32_C(0xf8207800) |
            ((uint32_t)index << 16) |
            ((uint32_t)address << 5) |
            (uint32_t)source
    );
}

static void a64_load_u8(
    Bytes *text,
    unsigned destination,
    unsigned address
) {
    a64_word(
        text,
        UINT32_C(0x39400000) |
            ((uint32_t)address << 5) |
            (uint32_t)destination
    );
}

static void a64_load_u8_indexed(
    Bytes *text,
    unsigned destination,
    unsigned address,
    unsigned index
) {
    a64_word(
        text,
        UINT32_C(0x38606800) |
            ((uint32_t)index << 16) |
            ((uint32_t)address << 5) |
            (uint32_t)destination
    );
}

static void a64_store_u8_indexed(
    Bytes *text,
    unsigned source,
    unsigned address,
    unsigned index
) {
    a64_word(
        text,
        UINT32_C(0x38206800) |
            ((uint32_t)index << 16) |
            ((uint32_t)address << 5) |
            (uint32_t)source
    );
}

static void a64_and(
    Bytes *text,
    unsigned destination,
    unsigned left,
    unsigned right
) {
    a64_word(
        text,
        UINT32_C(0x8a000000) |
            ((uint32_t)right << 16) |
            ((uint32_t)left << 5) |
            (uint32_t)destination
    );
}

static void a64_shift_left_three(
    Bytes *text,
    unsigned destination,
    unsigned source
) {
    a64_word(
        text,
        UINT32_C(0xd37df000) |
            ((uint32_t)source << 5) |
            (uint32_t)destination
    );
}

static void a64_sub_immediate(
    Bytes *text,
    unsigned destination,
    unsigned source,
    unsigned value
) {
    if (value > UINT32_C(0xfff)) {
        fatal("aarch64 Core immediate subtraction is out of range");
    }
    a64_word(
        text,
        UINT32_C(0xd1000000) |
            ((uint32_t)value << 10) |
            ((uint32_t)source << 5) |
            (uint32_t)destination
    );
}

static void a64_load_address(
    Bytes *text,
    unsigned destination,
    uint64_t address
) {
    if (address > UINT32_MAX) {
        fatal("aarch64 Core address exceeds the small static image");
    }
    a64_movz(text, destination, (unsigned)(address & UINT64_C(0xffff)));
    a64_movk_lsl16(
        text,
        destination,
        (unsigned)((address >> 16) & UINT64_C(0xffff))
    );
}

static void a64_load_core_local(
    Bytes *text,
    unsigned destination,
    size_t slot
) {
    if (slot > (UINT32_C(0xfff) / sizeof(uint64_t)) - 1) {
        fatal("aarch64 Core local frame is too large");
    }
    unsigned offset = (unsigned)((slot + 1) * sizeof(uint64_t));
    a64_sub_immediate(text, 9, 29, offset);
    a64_load_u64(text, destination, 9, 0);
}

static void a64_store_core_local(
    Bytes *text,
    unsigned source,
    size_t slot
) {
    if (slot > (UINT32_C(0xfff) / sizeof(uint64_t)) - 1) {
        fatal("aarch64 Core local frame is too large");
    }
    unsigned offset = (unsigned)((slot + 1) * sizeof(uint64_t));
    a64_sub_immediate(text, 9, 29, offset);
    a64_store_u64(text, source, 9, 0);
}

static size_t a64_core_conditional(
    Bytes *text,
    uint32_t instruction
) {
    size_t field = text->length;
    a64_word(text, instruction);
    return field;
}

static size_t a64_core_branch(Bytes *text) {
    size_t field = text->length;
    a64_word(text, UINT32_C(0x14000000));
    return field;
}

static void a64_core_call_allocate(
    Bytes *text,
    A64CoreRuntime *runtime
) {
    runtime->used = true;
    offsets_add(&runtime->allocate_calls, text->length);
    a64_word(text, UINT32_C(0x94000000)); /* bl allocate */
}

static void a64_core_call_runtime(
    Bytes *text,
    A64CoreRuntime *runtime,
    Offsets *calls
) {
    runtime->used = true;
    offsets_add(calls, text->length);
    a64_word(text, UINT32_C(0x94000000)); /* bl runtime helper */
}

static void a64_core_expression(
    Bytes *text,
    const Node *expression,
    A64CoreRuntime *runtime
) {
    if (expression->kind == NODE_INDEX &&
        expression->left->value_kind == VALUE_TEXT &&
        expression->left->value_known &&
        expression->right->value_known &&
        !expression->value_known) {
        runtime->used = true;
        a64_movz(text, 0, 0);
        a64_compare_zero(text, 0);
        offsets_add(&runtime->text_index_jumps, text->length);
        a64_word(text, UINT32_C(0x54000000)); /* b.eq Text error */
        a64_push(text, 0); /* unreachable stack result */
        return;
    }

    if (expression->kind == NODE_LENGTH &&
        expression->value_known) {
        a64_load_immediate(text, 0, expression->value);
        a64_push(text, 0);
        return;
    }

    if (expression->value_kind == VALUE_TEXT &&
        expression->value_known &&
        expression->text_value != NULL &&
        expression->kind != NODE_TEXT_LITERAL &&
        expression->kind != NODE_TEXT_CONCAT) {
        runtime->used = true;
        size_t low_field = text->length;
        a64_movz(text, 0, 0);              /* folded Text low, patched */
        size_t high_field = text->length;
        a64_movk_lsl16(text, 0, 0);        /* folded Text high, patched */
        a64_text_fixups_add(
            &runtime->text_literals,
            low_field,
            high_field,
            expression->text_value,
            expression->text_length
        );
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_LITERAL) {
        a64_load_immediate(text, 0, expression->value);
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_VARIABLE ||
        expression->kind == NODE_PARAMETER) {
        a64_load_core_local(text, 0, expression->slot);
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_LET) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 0);
        a64_store_core_local(text, 0, expression->slot);
        a64_core_expression(text, expression->right, runtime);
        return;
    }

    if (expression->kind == NODE_TEXT_LITERAL) {
        runtime->used = true;
        size_t low_field = text->length;
        a64_movz(text, 0, 0);              /* Text address low, patched */
        size_t high_field = text->length;
        a64_movk_lsl16(text, 0, 0);        /* Text address high, patched */
        a64_text_fixups_add(
            &runtime->text_literals,
            low_field,
            high_field,
            expression->text_value,
            expression->text_length
        );
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_NEGATE) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 0);
        a64_subtract(text, 0, 31, 0); /* neg x0, x0 */
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_CHARS &&
        !expression->value_known) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 0);                  /* source Text */
        a64_core_call_runtime(
            text,
            runtime,
            &runtime->text_chars_calls
        );
        a64_push(text, 0);                 /* List[Text] */
        return;
    }

    if (expression->kind == NODE_LIST ||
        expression->kind == NODE_CHARS ||
        expression->kind == NODE_CODEPOINTS ||
        expression->kind == NODE_BYTES) {
        if (expression->item_count >
            (UINT32_MAX - sizeof(uint64_t)) / sizeof(uint64_t)) {
            fatal("aarch64 Core list is too large");
        }
        uint32_t bytes = (uint32_t)(
            sizeof(uint64_t) +
            expression->item_count * sizeof(uint64_t)
        );
        a64_load_immediate(text, 0, bytes);
        a64_core_call_allocate(text, runtime);
        a64_load_immediate(text, 1, (int64_t)expression->item_count);
        a64_store_u64(text, 1, 0, 0);
        a64_push(text, 0); /* keep the list pointer below each item */

        for (size_t index = 0; index < expression->item_count; ++index) {
            a64_core_expression(text, expression->items[index], runtime);
            a64_pop(text, 1); /* item */
            a64_pop(text, 0); /* list */
            a64_load_immediate(text, 2, (int64_t)index);
            a64_add_immediate(text, 9, 0, 8);
            a64_store_indexed(text, 1, 9, 2);
            a64_push(text, 0);
        }
        return;
    }

    if (expression->kind == NODE_MAP) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 19);                 /* source */
        a64_load_u64(text, 22, 19, 0);     /* length */
        a64_shift_left_three(text, 0, 22);
        a64_add_immediate(text, 0, 0, 8);
        a64_core_call_allocate(text, runtime);
        a64_move_register(text, 20, 0);    /* output */
        a64_store_u64(text, 22, 20, 0);
        a64_movz(text, 21, 0);             /* index */

        size_t loop = text->length;
        a64_compare(text, 21, 22);
        size_t done =
            a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
        a64_add_immediate(text, 9, 19, 8);
        a64_load_indexed(text, 0, 9, 21);
        a64_store_core_local(text, 0, expression->slot);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 0);
        a64_add_immediate(text, 9, 20, 8);
        a64_store_indexed(text, 0, 9, 21);
        a64_add_immediate(text, 21, 21, 1);
        size_t back = a64_core_branch(text);
        size_t done_at = text->length;
        a64_patch_imm19(text, done, done_at);
        a64_patch_imm26(text, back, loop);
        a64_push(text, 20);
        return;
    }

    if (expression->kind == NODE_FILTER) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 19);                 /* source */
        a64_load_u64(text, 23, 19, 0);     /* source length */
        a64_shift_left_three(text, 0, 23);
        a64_add_immediate(text, 0, 0, 8);
        a64_core_call_allocate(text, runtime);
        a64_move_register(text, 20, 0);    /* output */
        a64_movz(text, 21, 0);             /* source index */
        a64_movz(text, 22, 0);             /* output count */

        size_t loop = text->length;
        a64_compare(text, 21, 23);
        size_t done =
            a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
        a64_add_immediate(text, 9, 19, 8);
        a64_load_indexed(text, 0, 9, 21);
        a64_store_core_local(text, 0, expression->slot);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 0);
        size_t skip =
            a64_core_conditional(text, UINT32_C(0xb4000000)); /* cbz x0 */
        a64_load_core_local(text, 0, expression->slot);
        a64_add_immediate(text, 9, 20, 8);
        a64_store_indexed(text, 0, 9, 22);
        a64_add_immediate(text, 22, 22, 1);
        size_t skip_at = text->length;
        a64_add_immediate(text, 21, 21, 1);
        size_t back = a64_core_branch(text);
        size_t done_at = text->length;
        a64_store_u64(text, 22, 20, 0);
        a64_patch_imm19(text, done, done_at);
        a64_patch_imm19(text, skip, skip_at);
        a64_patch_imm26(text, back, loop);
        a64_push(text, 20);
        return;
    }

    if (expression->kind == NODE_FOLD) {
        a64_core_expression(text, expression->left, runtime);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 22);                 /* accumulator */
        a64_pop(text, 19);                 /* source */
        a64_load_u64(text, 23, 19, 0);     /* length */
        a64_movz(text, 21, 0);             /* index */

        size_t loop = text->length;
        a64_compare(text, 21, 23);
        size_t done =
            a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
        a64_store_core_local(text, 22, expression->slot);
        a64_add_immediate(text, 9, 19, 8);
        a64_load_indexed(text, 0, 9, 21);
        a64_store_core_local(text, 0, expression->slot + 1);
        a64_core_expression(text, expression->third, runtime);
        a64_pop(text, 22);
        a64_add_immediate(text, 21, 21, 1);
        size_t back = a64_core_branch(text);
        size_t done_at = text->length;
        a64_patch_imm19(text, done, done_at);
        a64_patch_imm26(text, back, loop);
        a64_push(text, 22);
        return;
    }

    if (expression->kind == NODE_LENGTH) {
        a64_core_expression(text, expression->left, runtime);
        a64_pop(text, 0);
        if (expression->left->value_kind == VALUE_TEXT) {
            a64_core_call_runtime(
                text,
                runtime,
                &runtime->text_length_calls
            );
        } else {
            a64_load_u64(text, 0, 0, 0);
        }
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_INDEX) {
        runtime->used = true;
        a64_core_expression(text, expression->left, runtime);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 1);                  /* index */
        a64_pop(text, 2);                  /* Text or List */
        if (expression->left->value_kind == VALUE_TEXT) {
            a64_move_register(text, 0, 2);
            a64_core_call_runtime(
                text,
                runtime,
                &runtime->text_index_calls
            );
            a64_push(text, 0);             /* one-codepoint Text */
            return;
        }
        a64_load_u64(text, 3, 2, 0);       /* length */
        a64_compare_zero(text, 1);
        size_t nonnegative =
            a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
        a64_add(text, 1, 1, 3);
        size_t nonnegative_at = text->length;
        a64_patch_imm19(text, nonnegative, nonnegative_at);

        a64_compare_zero(text, 1);
        offsets_add(&runtime->list_index_jumps, text->length);
        a64_word(text, UINT32_C(0x5400000b)); /* b.lt list error */
        a64_compare(text, 1, 3);
        offsets_add(&runtime->list_index_jumps, text->length);
        a64_word(text, UINT32_C(0x5400000a)); /* b.ge list error */
        a64_add_immediate(text, 9, 2, 8);
        a64_load_indexed(text, 0, 9, 1);
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_TEXT_CONCAT ||
        expression->kind == NODE_TEXT_EQUAL ||
        expression->kind == NODE_TEXT_NOT_EQUAL) {
        a64_core_expression(text, expression->left, runtime);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 1);                  /* right Text */
        a64_pop(text, 0);                  /* left Text */
        if (expression->kind == NODE_TEXT_CONCAT) {
            a64_core_call_runtime(
                text,
                runtime,
                &runtime->text_concat_calls
            );
        } else {
            a64_core_call_runtime(
                text,
                runtime,
                &runtime->text_equal_calls
            );
            if (expression->kind == NODE_TEXT_NOT_EQUAL) {
                a64_word(text, UINT32_C(0xd2400000)); /* eor x0, x0, #1 */
            }
        }
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_INT_EQUAL ||
        expression->kind == NODE_INT_NOT_EQUAL ||
        expression->kind == NODE_INT_LESS ||
        expression->kind == NODE_INT_LESS_EQUAL ||
        expression->kind == NODE_INT_GREATER ||
        expression->kind == NODE_INT_GREATER_EQUAL) {
        a64_core_expression(text, expression->left, runtime);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 1);
        a64_pop(text, 0);
        a64_compare(text, 0, 1);
        uint32_t instruction = UINT32_C(0x9a9f17e0); /* cset eq */
        if (expression->kind == NODE_INT_NOT_EQUAL) {
            instruction = UINT32_C(0x9a9f07e0);
        } else if (expression->kind == NODE_INT_LESS) {
            instruction = UINT32_C(0x9a9fa7e0);
        } else if (expression->kind == NODE_INT_LESS_EQUAL) {
            instruction = UINT32_C(0x9a9fc7e0);
        } else if (expression->kind == NODE_INT_GREATER) {
            instruction = UINT32_C(0x9a9fd7e0);
        } else if (expression->kind == NODE_INT_GREATER_EQUAL) {
            instruction = UINT32_C(0x9a9fb7e0);
        }
        a64_word(text, instruction);
        a64_push(text, 0);
        return;
    }

    if (expression->kind == NODE_ADD ||
        expression->kind == NODE_MULTIPLY) {
        a64_core_expression(text, expression->left, runtime);
        a64_core_expression(text, expression->right, runtime);
        a64_pop(text, 1);
        a64_pop(text, 0);
        if (expression->kind == NODE_ADD) {
            a64_add(text, 0, 0, 1);
        } else {
            a64_multiply(text, 0, 0, 1);
        }
        a64_push(text, 0);
        return;
    }

    fatal("unsupported expression reached AArch64 aggregate lowering");
}

static void a64_core_diagnostic(
    Bytes *text,
    uint32_t length,
    uint32_t status,
    size_t *low_field,
    size_t *high_field
) {
    *low_field = text->length;
    a64_movz(text, 1, 0);                  /* message low, patched */
    *high_field = text->length;
    a64_movk_lsl16(text, 1, 0);            /* message high, patched */
    a64_movz(text, 0, 2);                  /* stderr */
    a64_movz(text, 2, length);
    a64_movz(text, 8, 64);                 /* write */
    a64_svc(text);
    a64_movz(text, 0, status);
    a64_movz(text, 8, 93);                 /* exit */
    a64_svc(text);
    a64_word(text, UINT32_C(0xd4200000));  /* brk #0 */
}

static void a64_runtime_save(Bytes *text) {
    a64_word(text, UINT32_C(0xa9bf7bfd)); /* stp x29, x30, [sp, #-16]! */
    a64_word(text, UINT32_C(0xa9bf53f3)); /* stp x19, x20, [sp, #-16]! */
    a64_word(text, UINT32_C(0xa9bf5bf5)); /* stp x21, x22, [sp, #-16]! */
    a64_word(text, UINT32_C(0xa9bf63f7)); /* stp x23, x24, [sp, #-16]! */
    a64_word(text, UINT32_C(0xa9bf6bf9)); /* stp x25, x26, [sp, #-16]! */
}

static void a64_runtime_restore(Bytes *text) {
    a64_word(text, UINT32_C(0xa8c16bf9)); /* ldp x25, x26, [sp], #16 */
    a64_word(text, UINT32_C(0xa8c163f7)); /* ldp x23, x24, [sp], #16 */
    a64_word(text, UINT32_C(0xa8c15bf5)); /* ldp x21, x22, [sp], #16 */
    a64_word(text, UINT32_C(0xa8c153f3)); /* ldp x19, x20, [sp], #16 */
    a64_word(text, UINT32_C(0xa8c17bfd)); /* ldp x29, x30, [sp], #16 */
    a64_word(text, UINT32_C(0xd65f03c0)); /* ret */
}

static size_t a64_text_length_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    a64_load_u64(text, 1, 0, 0);           /* remaining UTF-8 bytes */
    a64_add_immediate(text, 2, 0, 8);      /* byte cursor */
    a64_movz(text, 0, 0);                  /* codepoint count */
    a64_movz(text, 9, UINT16_C(0xc0));     /* continuation mask */
    a64_movz(text, 10, UINT16_C(0x80));    /* continuation tag */

    size_t loop = text->length;
    size_t done =
        a64_core_conditional(text, UINT32_C(0xb4000001)); /* cbz x1 */
    a64_load_u8(text, 3, 2);
    a64_and(text, 3, 3, 9);
    a64_compare(text, 3, 10);
    size_t skip =
        a64_core_conditional(text, UINT32_C(0x54000000)); /* b.eq */
    a64_add_immediate(text, 0, 0, 1);
    size_t skip_at = text->length;
    a64_add_immediate(text, 2, 2, 1);
    a64_sub_immediate(text, 1, 1, 1);
    size_t back = a64_core_branch(text);
    size_t done_at = text->length;
    a64_word(text, UINT32_C(0xd65f03c0));  /* ret */

    a64_patch_imm19(text, done, done_at);
    a64_patch_imm19(text, skip, skip_at);
    a64_patch_imm26(text, back, loop);
    return runtime_at;
}

static size_t a64_text_equal_runtime(Bytes *text) {
    size_t runtime_at = text->length;
    a64_load_u64(text, 2, 0, 0);
    a64_load_u64(text, 3, 1, 0);
    a64_compare(text, 2, 3);
    size_t different_length =
        a64_core_conditional(text, UINT32_C(0x54000001)); /* b.ne */
    a64_add_immediate(text, 0, 0, 8);
    a64_add_immediate(text, 1, 1, 8);

    size_t loop = text->length;
    size_t equal =
        a64_core_conditional(text, UINT32_C(0xb4000002)); /* cbz x2 */
    a64_load_u8(text, 4, 0);
    a64_load_u8(text, 5, 1);
    a64_compare(text, 4, 5);
    size_t different_byte =
        a64_core_conditional(text, UINT32_C(0x54000001)); /* b.ne */
    a64_add_immediate(text, 0, 0, 1);
    a64_add_immediate(text, 1, 1, 1);
    a64_sub_immediate(text, 2, 2, 1);
    size_t back = a64_core_branch(text);

    size_t equal_at = text->length;
    a64_movz(text, 0, 1);
    a64_word(text, UINT32_C(0xd65f03c0));  /* ret */
    size_t different_at = text->length;
    a64_movz(text, 0, 0);
    a64_word(text, UINT32_C(0xd65f03c0));  /* ret */

    a64_patch_imm19(text, different_length, different_at);
    a64_patch_imm19(text, equal, equal_at);
    a64_patch_imm19(text, different_byte, different_at);
    a64_patch_imm26(text, back, loop);
    return runtime_at;
}

static size_t a64_text_concat_runtime(
    Bytes *text,
    A64CoreRuntime *runtime
) {
    size_t runtime_at = text->length;
    a64_runtime_save(text);
    a64_move_register(text, 19, 0);        /* left Text */
    a64_move_register(text, 20, 1);        /* right Text */
    a64_load_u64(text, 21, 19, 0);         /* left byte length */
    a64_load_u64(text, 22, 20, 0);         /* right byte length */
    a64_add(text, 23, 21, 22);             /* total bytes */
    a64_add_immediate(text, 0, 23, 8);
    a64_core_call_allocate(text, runtime);
    a64_move_register(text, 24, 0);        /* result Text */
    a64_store_u64(text, 23, 24, 0);
    a64_add_immediate(text, 4, 24, 8);     /* destination */
    a64_add_immediate(text, 5, 19, 8);     /* left source */
    a64_move_register(text, 6, 21);        /* remaining */

    size_t left_loop = text->length;
    size_t left_done =
        a64_core_conditional(text, UINT32_C(0xb4000006)); /* cbz x6 */
    a64_load_u8(text, 7, 5);
    a64_strb(text, 7, 4, 0);
    a64_add_immediate(text, 5, 5, 1);
    a64_add_immediate(text, 4, 4, 1);
    a64_sub_immediate(text, 6, 6, 1);
    size_t left_back = a64_core_branch(text);

    size_t right_at = text->length;
    a64_add_immediate(text, 5, 20, 8);
    a64_move_register(text, 6, 22);
    size_t right_loop = text->length;
    size_t right_done =
        a64_core_conditional(text, UINT32_C(0xb4000006)); /* cbz x6 */
    a64_load_u8(text, 7, 5);
    a64_strb(text, 7, 4, 0);
    a64_add_immediate(text, 5, 5, 1);
    a64_add_immediate(text, 4, 4, 1);
    a64_sub_immediate(text, 6, 6, 1);
    size_t right_back = a64_core_branch(text);

    size_t done_at = text->length;
    a64_move_register(text, 0, 24);
    a64_runtime_restore(text);

    a64_patch_imm19(text, left_done, right_at);
    a64_patch_imm26(text, left_back, left_loop);
    a64_patch_imm19(text, right_done, done_at);
    a64_patch_imm26(text, right_back, right_loop);
    return runtime_at;
}

static size_t a64_text_index_runtime(
    Bytes *text,
    A64CoreRuntime *runtime,
    size_t text_length_at
) {
    size_t runtime_at = text->length;
    a64_runtime_save(text);
    a64_move_register(text, 19, 0);        /* source Text */
    a64_move_register(text, 20, 1);        /* requested codepoint index */
    a64_compare_zero(text, 20);
    size_t nonnegative =
        a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
    a64_move_register(text, 0, 19);
    size_t length_call = text->length;
    a64_word(text, UINT32_C(0x94000000));  /* bl Text length */
    a64_patch_imm26(text, length_call, text_length_at);
    a64_add(text, 20, 20, 0);
    size_t nonnegative_at = text->length;
    a64_patch_imm19(text, nonnegative, nonnegative_at);
    a64_compare_zero(text, 20);
    offsets_add(&runtime->text_index_jumps, text->length);
    a64_word(text, UINT32_C(0x5400000b));  /* b.lt Text index error */

    a64_load_u64(text, 21, 19, 0);         /* remaining bytes */
    a64_add_immediate(text, 22, 19, 8);    /* codepoint cursor */
    a64_movz(text, 23, 0);                 /* current codepoint index */
    a64_movz(text, 9, UINT16_C(0xc0));     /* continuation mask */
    a64_movz(text, 10, UINT16_C(0x80));    /* continuation tag */

    size_t scan = text->length;
    offsets_add(&runtime->text_index_jumps, text->length);
    a64_word(text, UINT32_C(0xb4000015));  /* cbz x21, Text error */
    a64_compare(text, 23, 20);
    size_t found =
        a64_core_conditional(text, UINT32_C(0x54000000)); /* b.eq */
    a64_add_immediate(text, 22, 22, 1);
    a64_sub_immediate(text, 21, 21, 1);

    size_t continuation = text->length;
    size_t next_if_empty =
        a64_core_conditional(text, UINT32_C(0xb4000015)); /* cbz x21 */
    a64_load_u8(text, 3, 22);
    a64_and(text, 3, 3, 9);
    a64_compare(text, 3, 10);
    size_t next_if_start =
        a64_core_conditional(text, UINT32_C(0x54000001)); /* b.ne */
    a64_add_immediate(text, 22, 22, 1);
    a64_sub_immediate(text, 21, 21, 1);
    size_t continuation_back = a64_core_branch(text);

    size_t next_at = text->length;
    a64_add_immediate(text, 23, 23, 1);
    size_t scan_back = a64_core_branch(text);

    size_t found_at = text->length;
    a64_movz(text, 24, 1);                 /* codepoint byte width */
    size_t width = text->length;
    a64_compare(text, 24, 21);
    size_t width_done =
        a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
    a64_load_u8_indexed(text, 3, 22, 24);
    a64_and(text, 3, 3, 9);
    a64_compare(text, 3, 10);
    size_t width_start =
        a64_core_conditional(text, UINT32_C(0x54000001)); /* b.ne */
    a64_add_immediate(text, 24, 24, 1);
    size_t width_back = a64_core_branch(text);

    size_t width_done_at = text->length;
    a64_add_immediate(text, 0, 24, 8);
    a64_core_call_allocate(text, runtime);
    a64_move_register(text, 25, 0);        /* result Text */
    a64_store_u64(text, 24, 25, 0);
    a64_add_immediate(text, 1, 25, 8);     /* destination bytes */
    a64_movz(text, 26, 0);                 /* copy index */
    size_t copy = text->length;
    a64_compare(text, 26, 24);
    size_t copy_done =
        a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
    a64_load_u8_indexed(text, 3, 22, 26);
    a64_store_u8_indexed(text, 3, 1, 26);
    a64_add_immediate(text, 26, 26, 1);
    size_t copy_back = a64_core_branch(text);

    size_t copy_done_at = text->length;
    a64_move_register(text, 0, 25);
    a64_runtime_restore(text);

    a64_patch_imm19(text, found, found_at);
    a64_patch_imm19(text, next_if_empty, next_at);
    a64_patch_imm19(text, next_if_start, next_at);
    a64_patch_imm26(text, continuation_back, continuation);
    a64_patch_imm26(text, scan_back, scan);
    a64_patch_imm19(text, width_done, width_done_at);
    a64_patch_imm19(text, width_start, width_done_at);
    a64_patch_imm26(text, width_back, width);
    a64_patch_imm19(text, copy_done, copy_done_at);
    a64_patch_imm26(text, copy_back, copy);
    return runtime_at;
}

static size_t a64_text_chars_runtime(
    Bytes *text,
    A64CoreRuntime *runtime,
    size_t text_length_at
) {
    size_t runtime_at = text->length;
    a64_runtime_save(text);
    a64_move_register(text, 19, 0);        /* source Text */
    size_t length_call = text->length;
    a64_word(text, UINT32_C(0x94000000));  /* bl Text length */
    a64_patch_imm26(text, length_call, text_length_at);
    a64_move_register(text, 20, 0);        /* codepoint count */
    a64_shift_left_three(text, 0, 20);
    a64_add_immediate(text, 0, 0, 8);
    a64_core_call_allocate(text, runtime);
    a64_move_register(text, 21, 0);        /* result List */
    a64_store_u64(text, 20, 21, 0);
    a64_add_immediate(text, 22, 19, 8);    /* source cursor */
    a64_load_u64(text, 23, 19, 0);         /* remaining bytes */
    a64_movz(text, 24, 0);                 /* List element index */
    a64_movz(text, 9, UINT16_C(0xc0));     /* continuation mask */
    a64_movz(text, 10, UINT16_C(0x80));    /* continuation tag */

    size_t loop = text->length;
    size_t done =
        a64_core_conditional(text, UINT32_C(0xb4000017)); /* cbz x23 */
    a64_movz(text, 25, 1);                 /* codepoint byte width */
    size_t width = text->length;
    a64_compare(text, 25, 23);
    size_t width_done =
        a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
    a64_load_u8_indexed(text, 3, 22, 25);
    a64_and(text, 3, 3, 9);
    a64_compare(text, 3, 10);
    size_t width_start =
        a64_core_conditional(text, UINT32_C(0x54000001)); /* b.ne */
    a64_add_immediate(text, 25, 25, 1);
    size_t width_back = a64_core_branch(text);

    size_t width_done_at = text->length;
    a64_add_immediate(text, 0, 25, 8);
    a64_core_call_allocate(text, runtime);
    a64_move_register(text, 26, 0);        /* one-codepoint Text */
    a64_store_u64(text, 25, 26, 0);
    a64_add_immediate(text, 1, 21, 8);
    a64_store_indexed(text, 26, 1, 24);
    a64_add_immediate(text, 1, 26, 8);     /* destination bytes */
    a64_movz(text, 0, 0);                  /* copy index */
    size_t copy = text->length;
    a64_compare(text, 0, 25);
    size_t copy_done =
        a64_core_conditional(text, UINT32_C(0x5400000a)); /* b.ge */
    a64_load_u8_indexed(text, 3, 22, 0);
    a64_store_u8_indexed(text, 3, 1, 0);
    a64_add_immediate(text, 0, 0, 1);
    size_t copy_back = a64_core_branch(text);

    size_t copy_done_at = text->length;
    a64_add(text, 22, 22, 25);
    a64_subtract(text, 23, 23, 25);
    a64_add_immediate(text, 24, 24, 1);
    size_t loop_back = a64_core_branch(text);

    size_t done_at = text->length;
    a64_move_register(text, 0, 21);
    a64_runtime_restore(text);

    a64_patch_imm19(text, done, done_at);
    a64_patch_imm19(text, width_done, width_done_at);
    a64_patch_imm19(text, width_start, width_done_at);
    a64_patch_imm26(text, width_back, width);
    a64_patch_imm19(text, copy_done, copy_done_at);
    a64_patch_imm26(text, copy_back, copy);
    a64_patch_imm26(text, loop_back, loop);
    return runtime_at;
}

static void a64_core_runtime(
    Bytes *text,
    A64CoreRuntime *runtime
) {
    if (!runtime->used) return;

    size_t allocate_at = text->length;
    a64_word(text, UINT32_C(0xf144001f)); /* cmp x0, #256, lsl #12 */
    offsets_add(&runtime->oom_jumps, text->length);
    a64_word(text, UINT32_C(0x54000008)); /* b.hi oom */
    a64_movz(text, 0, 0);                 /* address */
    a64_movz(text, 1, 0);
    a64_movk_lsl16(text, 1, 16);          /* length = 1 MiB */
    a64_movz(text, 2, 3);                 /* PROT_READ | PROT_WRITE */
    a64_movz(text, 3, 0x22);              /* PRIVATE | ANONYMOUS */
    a64_word(text, UINT32_C(0x92800004)); /* mov x4, #-1 */
    a64_movz(text, 5, 0);                 /* offset */
    a64_movz(text, 8, 222);               /* mmap */
    a64_svc(text);
    a64_word(text, UINT32_C(0xb13ffc1f)); /* cmn x0, #4095 */
    offsets_add(&runtime->oom_jumps, text->length);
    a64_word(text, UINT32_C(0x54000002)); /* b.hs oom */
    a64_word(text, UINT32_C(0xd65f03c0)); /* ret */

    size_t text_length_at = a64_text_length_runtime(text);
    size_t text_equal_at = a64_text_equal_runtime(text);
    size_t text_concat_at = a64_text_concat_runtime(text, runtime);
    size_t text_index_at =
        a64_text_index_runtime(text, runtime, text_length_at);
    size_t text_chars_at =
        a64_text_chars_runtime(text, runtime, text_length_at);

    size_t oom_at = text->length;
    static const char oom_message[] = "kofun: out of memory\n";
    size_t oom_low = 0;
    size_t oom_high = 0;
    a64_core_diagnostic(
        text,
        (uint32_t)(sizeof(oom_message) - 1),
        70,
        &oom_low,
        &oom_high
    );

    size_t list_index_at = text->length;
    static const char list_index_message[] =
        "kofun: list index out of range\n";
    size_t list_low = 0;
    size_t list_high = 0;
    a64_core_diagnostic(
        text,
        (uint32_t)(sizeof(list_index_message) - 1),
        1,
        &list_low,
        &list_high
    );

    size_t text_index_error_at = text->length;
    static const char text_index_message[] =
        "kofun: text index out of range\n";
    size_t text_index_low = 0;
    size_t text_index_high = 0;
    a64_core_diagnostic(
        text,
        (uint32_t)(sizeof(text_index_message) - 1),
        1,
        &text_index_low,
        &text_index_high
    );

    size_t oom_message_at = text->length;
    for (size_t index = 0; index < sizeof(oom_message) - 1; ++index) {
        byte(text, (uint8_t)oom_message[index]);
    }
    size_t list_message_at = text->length;
    for (
        size_t index = 0;
        index < sizeof(list_index_message) - 1;
        ++index
    ) {
        byte(text, (uint8_t)list_index_message[index]);
    }
    size_t text_index_message_at = text->length;
    for (
        size_t index = 0;
        index < sizeof(text_index_message) - 1;
        ++index
    ) {
        byte(text, (uint8_t)text_index_message[index]);
    }

    uint64_t oom_address =
        IMAGE_BASE + (uint64_t)TEXT_OFFSET + (uint64_t)oom_message_at;
    uint64_t list_address =
        IMAGE_BASE + (uint64_t)TEXT_OFFSET + (uint64_t)list_message_at;
    uint64_t text_index_address =
        IMAGE_BASE +
        (uint64_t)TEXT_OFFSET +
        (uint64_t)text_index_message_at;
    a64_patch_mov_imm16(
        text,
        oom_low,
        (uint32_t)(oom_address & UINT64_C(0xffff))
    );
    a64_patch_mov_imm16(
        text,
        oom_high,
        (uint32_t)((oom_address >> 16) & UINT64_C(0xffff))
    );
    a64_patch_mov_imm16(
        text,
        list_low,
        (uint32_t)(list_address & UINT64_C(0xffff))
    );
    a64_patch_mov_imm16(
        text,
        list_high,
        (uint32_t)((list_address >> 16) & UINT64_C(0xffff))
    );
    a64_patch_mov_imm16(
        text,
        text_index_low,
        (uint32_t)(text_index_address & UINT64_C(0xffff))
    );
    a64_patch_mov_imm16(
        text,
        text_index_high,
        (uint32_t)((text_index_address >> 16) & UINT64_C(0xffff))
    );

    for (size_t index = 0; index < runtime->allocate_calls.length; ++index) {
        a64_patch_imm26(
            text,
            runtime->allocate_calls.fields[index],
            allocate_at
        );
    }
    for (size_t index = 0; index < runtime->oom_jumps.length; ++index) {
        a64_patch_imm19(text, runtime->oom_jumps.fields[index], oom_at);
    }
    for (
        size_t index = 0;
        index < runtime->list_index_jumps.length;
        ++index
    ) {
        a64_patch_imm19(
            text,
            runtime->list_index_jumps.fields[index],
            list_index_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_index_jumps.length;
        ++index
    ) {
        a64_patch_imm19(
            text,
            runtime->text_index_jumps.fields[index],
            text_index_error_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_concat_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            runtime->text_concat_calls.fields[index],
            text_concat_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_equal_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            runtime->text_equal_calls.fields[index],
            text_equal_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_length_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            runtime->text_length_calls.fields[index],
            text_length_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_index_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            runtime->text_index_calls.fields[index],
            text_index_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_chars_calls.length;
        ++index
    ) {
        a64_patch_imm26(
            text,
            runtime->text_chars_calls.fields[index],
            text_chars_at
        );
    }
    for (
        size_t index = 0;
        index < runtime->text_literals.length;
        ++index
    ) {
        while (text->length % sizeof(uint64_t) != 0) byte(text, 0);
        size_t literal_at = text->length;
        const uint8_t *literal_value =
            runtime->text_literals.items[index].value;
        size_t literal_length =
            runtime->text_literals.items[index].length;
        u64_le(text, (uint64_t)literal_length);
        for (size_t byte_index = 0;
             byte_index < literal_length;
             ++byte_index) {
            byte(text, literal_value[byte_index]);
        }
        uint64_t literal_address =
            IMAGE_BASE + (uint64_t)TEXT_OFFSET + (uint64_t)literal_at;
        a64_patch_mov_imm16(
            text,
            runtime->text_literals.items[index].low_field,
            (uint32_t)(literal_address & UINT64_C(0xffff))
        );
        a64_patch_mov_imm16(
            text,
            runtime->text_literals.items[index].high_field,
            (uint32_t)((literal_address >> 16) & UINT64_C(0xffff))
        );
    }
}

static void a64_core_bool_output(Bytes *text) {
    a64_load_address(text, 1, DATA_ADDRESS);
    size_t false_jump =
        a64_core_conditional(text, UINT32_C(0xb4000000)); /* cbz x0 */
    static const char true_text[] = "true\n";
    for (size_t index = 0; index < sizeof(true_text) - 1; ++index) {
        a64_movz(text, 3, (unsigned)(uint8_t)true_text[index]);
        a64_strb(text, 3, 1, (unsigned)index);
    }
    a64_movz(text, 2, (unsigned)(sizeof(true_text) - 1));
    size_t done = a64_core_branch(text);
    size_t false_at = text->length;
    static const char false_text[] = "false\n";
    for (size_t index = 0; index < sizeof(false_text) - 1; ++index) {
        a64_movz(text, 3, (unsigned)(uint8_t)false_text[index]);
        a64_strb(text, 3, 1, (unsigned)index);
    }
    a64_movz(text, 2, (unsigned)(sizeof(false_text) - 1));
    size_t done_at = text->length;
    a64_patch_imm19(text, false_jump, false_at);
    a64_patch_imm26(text, done, done_at);
    a64_movz(text, 0, 1);                  /* stdout */
    a64_movz(text, 8, 64);                 /* write */
    a64_svc(text);
}

static void a64_core_text(
    Bytes *text,
    const Node *expression,
    size_t local_count
) {
    A64CoreRuntime runtime = {0};
    if (local_count > 0) {
        if (local_count > UINT32_C(0xfff) / sizeof(uint64_t)) {
            fatal("aarch64 Core local frame is too large");
        }
        a64_word(text, UINT32_C(0xa9bf7bfd)); /* save fp/lr */
        a64_word(text, UINT32_C(0x910003fd)); /* mov x29, sp */
        uint32_t frame = (uint32_t)(
            ((local_count * sizeof(uint64_t)) + 15) / 16 * 16
        );
        a64_sub_sp(text, frame);
    }

    a64_core_expression(text, expression, &runtime);
    a64_pop(text, 0);
    if (expression->value_kind == VALUE_INT) {
        a64_movz(text, 3, 10);
        a64_udiv(text, 4, 0, 3);
        a64_msub(text, 5, 4, 3, 0);
        a64_add_immediate(text, 4, 4, 48);
        a64_add_immediate(text, 5, 5, 48);
        a64_load_address(text, 1, DATA_ADDRESS);
        a64_strb(text, 4, 1, 0);
        a64_strb(text, 5, 1, 1);
        a64_movz(text, 0, 1);              /* stdout */
        a64_movz(text, 2, 3);              /* includes existing newline */
        a64_movz(text, 8, 64);             /* write */
        a64_svc(text);
    } else if (expression->value_kind == VALUE_BOOL) {
        a64_core_bool_output(text);
    } else if (expression->value_kind == VALUE_TEXT) {
        runtime.used = true;
        a64_load_u64(text, 2, 0, 0);       /* UTF-8 byte length */
        a64_add_immediate(text, 1, 0, 8);  /* UTF-8 bytes */
        a64_movz(text, 0, 1);              /* stdout */
        a64_movz(text, 8, 64);             /* write */
        a64_svc(text);
        a64_load_address(text, 1, DATA_ADDRESS + 2);
        a64_movz(text, 0, 1);              /* stdout */
        a64_movz(text, 2, 1);              /* newline */
        a64_movz(text, 8, 64);             /* write */
        a64_svc(text);
    } else {
        fatal("AArch64 aggregate Core cannot print this value");
    }
    a64_movz(text, 0, 0);
    a64_movz(text, 8, 93);                 /* exit */
    a64_svc(text);
    a64_word(text, UINT32_C(0xd4200000));  /* brk #0 */

    a64_core_runtime(text, &runtime);
    a64_core_runtime_free(&runtime);
}

static void elf_ident(Bytes *image) {
    byte(image, UINT8_C(0x7f));
    byte(image, UINT8_C('E'));
    byte(image, UINT8_C('L'));
    byte(image, UINT8_C('F'));
    byte(image, 2); /* ELFCLASS64 */
    byte(image, 1); /* ELFDATA2LSB */
    byte(image, 1); /* EV_CURRENT */
    byte(image, 0); /* System V */
    for (unsigned index = 0; index < 8; ++index) byte(image, 0);
}

static void elf_header(Bytes *image, uint16_t machine) {
    elf_ident(image);
    u16_le(image, 2); /* ET_EXEC */
    u16_le(image, machine);
    u32_le(image, 1); /* EV_CURRENT */
    u64_le(image, IMAGE_BASE + TEXT_OFFSET);
    u64_le(image, ELF_HEADER_SIZE);
    u64_le(image, 0); /* section headers */
    u32_le(image, 0); /* flags */
    u16_le(image, ELF_HEADER_SIZE);
    u16_le(image, PROGRAM_HEADER_SIZE);
    u16_le(image, PROGRAM_HEADER_COUNT);
    u16_le(image, 0);
    u16_le(image, 0);
    u16_le(image, 0);
}

static void load_segment(
    Bytes *image,
    uint32_t flags,
    uint64_t offset,
    uint64_t address,
    uint64_t file_size,
    uint64_t memory_size
) {
    u32_le(image, 1); /* PT_LOAD */
    u32_le(image, flags);
    u64_le(image, offset);
    u64_le(image, address);
    u64_le(image, address);
    u64_le(image, file_size);
    u64_le(image, memory_size);
    u64_le(image, PAGE_SIZE);
}

static void elf_image(
    Bytes *image,
    uint16_t machine,
    const Bytes *text,
    const Bytes *data
) {
    if (text->length > PAGE_SIZE - TEXT_OFFSET) {
        fatal("native Core text exceeds the bounded static RX page");
    }
    size_t data_length = data == NULL ? 0 : data->length;
    if (data_length > PAGE_SIZE - 3) {
        fatal("native Core data exceeds the bounded static RW page");
    }
    uint64_t rx_size = (uint64_t)TEXT_OFFSET + (uint64_t)text->length;
    elf_header(image, machine);
    load_segment(image, 5, 0, IMAGE_BASE, rx_size, rx_size);
    load_segment(
        image,
        6,
        PAGE_SIZE,
        DATA_ADDRESS,
        (uint64_t)(3 + data_length),
        PAGE_SIZE
    );
    if (image->length != TEXT_OFFSET) {
        fatal("internal ELF header size differs");
    }
    bytes_reserve(image, text->length);
    memcpy(image->data + image->length, text->data, text->length);
    image->length += text->length;
    bytes_pad_to(image, PAGE_SIZE);
    byte(image, 0);
    byte(image, 0);
    byte(image, UINT8_C('\n'));
    if (data != NULL) {
        bytes_reserve(image, data->length);
        memcpy(image->data + image->length, data->data, data->length);
        image->length += data->length;
    }
}

static void bytes_append(Bytes *destination, const Bytes *source) {
    bytes_reserve(destination, source->length);
    memcpy(
        destination->data + destination->length,
        source->data,
        source->length
    );
    destination->length += source->length;
}

static void bytes_text(Bytes *bytes, const char *text) {
    size_t length = strlen(text) + 1;
    bytes_reserve(bytes, length);
    memcpy(bytes->data + bytes->length, text, length);
    bytes->length += length;
}

static void bytes_align(Bytes *bytes, size_t alignment) {
    if (alignment == 0) fatal("zero byte alignment");
    size_t remainder = bytes->length % alignment;
    if (remainder != 0) {
        bytes_pad_to(bytes, bytes->length + alignment - remainder);
    }
}

static void patch_u16_le(Bytes *bytes, size_t offset, uint16_t value) {
    if (offset > bytes->length || bytes->length - offset < 2) {
        fatal("ELF u16 patch is outside the image");
    }
    bytes->data[offset] = (uint8_t)value;
    bytes->data[offset + 1] = (uint8_t)(value >> 8);
}

static void patch_u64_le(Bytes *bytes, size_t offset, uint64_t value) {
    if (offset > bytes->length || bytes->length - offset < 8) {
        fatal("ELF u64 patch is outside the image");
    }
    for (unsigned index = 0; index < 8; ++index) {
        bytes->data[offset + index] =
            (uint8_t)(value >> (index * 8));
    }
}

static void uleb128(Bytes *bytes, uint64_t value) {
    do {
        uint8_t encoded = (uint8_t)(value & UINT64_C(0x7f));
        value >>= 7;
        if (value != 0) encoded |= UINT8_C(0x80);
        byte(bytes, encoded);
    } while (value != 0);
}

static void sleb128(Bytes *bytes, int64_t value) {
    bool more = true;
    while (more) {
        uint8_t encoded = (uint8_t)((uint64_t)value & UINT64_C(0x7f));
        bool sign = (encoded & UINT8_C(0x40)) != 0;
        value >>= 7;
        if ((value == 0 && !sign) || (value == -1 && sign)) {
            more = false;
        } else {
            encoded |= UINT8_C(0x80);
        }
        byte(bytes, encoded);
    }
}

static void dwarf_abbreviations(Bytes *abbreviations) {
    /*
     * The canonical encoder.kofun table:
     *   1: compile unit with child DIEs
     *   2: external subprogram with source declaration and address range
     */
    const uint8_t table[] = {
        1, 17, 1,
        37, 14, 19, 5, 3, 14, 16, 23, 17, 1, 18, 7, 0, 0,
        2, 46, 0,
        3, 14, 58, 11, 59, 11, 17, 1, 18, 7, 63, 25, 0, 0,
        0,
    };
    bytes_reserve(abbreviations, sizeof(table));
    memcpy(
        abbreviations->data + abbreviations->length,
        table,
        sizeof(table)
    );
    abbreviations->length += sizeof(table);
}

static void dwarf_strings(
    Bytes *strings,
    const char *source_path,
    uint32_t *source_offset,
    uint32_t *main_offset
) {
    bytes_text(strings, "Kofun bootstrap native encoder");
    if (strings->length > UINT32_MAX) fatal("DWARF string offset overflow");
    *source_offset = (uint32_t)strings->length;
    bytes_text(strings, source_path);
    if (strings->length > UINT32_MAX) fatal("DWARF string offset overflow");
    *main_offset = (uint32_t)strings->length;
    bytes_text(strings, "main");
}

static void dwarf_information(
    Bytes *information,
    uint32_t source_offset,
    uint32_t main_offset,
    size_t main_line,
    size_t text_size
) {
    if (main_line > UINT8_MAX) {
        fatal("native Core debug declaration line exceeds DWARF v4 data1");
    }

    Bytes body;
    bytes_init(&body);
    u16_le(&body, 4); /* DWARF v4 */
    u32_le(&body, 0); /* abbreviation table offset */
    byte(&body, 8);   /* address size */

    uleb128(&body, 1); /* compile-unit abbreviation */
    u32_le(&body, 0);  /* producer string */
    u16_le(&body, UINT16_C(0x8000)); /* implementation-defined Kofun */
    u32_le(&body, source_offset);
    u32_le(&body, 0); /* .debug_line offset */
    u64_le(&body, IMAGE_BASE + TEXT_OFFSET);
    u64_le(&body, (uint64_t)text_size);

    uleb128(&body, 2); /* subprogram abbreviation */
    u32_le(&body, main_offset);
    byte(&body, 1); /* file table index */
    byte(&body, (uint8_t)main_line);
    u64_le(&body, IMAGE_BASE + TEXT_OFFSET);
    u64_le(&body, (uint64_t)text_size);
    byte(&body, 0); /* end compile-unit children */

    if (body.length > UINT32_MAX) fatal("DWARF information is too large");
    u32_le(information, (uint32_t)body.length);
    bytes_append(information, &body);
    free(body.data);
}

static void dwarf_line_table(
    Bytes *lines,
    const char *source_path,
    const LineRows *rows,
    size_t text_size
) {
    if (rows->length == 0) fatal("native Core has no debug line rows");

    Bytes header;
    bytes_init(&header);
    byte(&header, 1); /* minimum instruction length */
    byte(&header, 1); /* maximum operations per instruction */
    byte(&header, 1); /* default_is_stmt */
    byte(&header, UINT8_C(251)); /* line_base = -5 */
    byte(&header, 14); /* line_range */
    byte(&header, 13); /* opcode_base */
    const uint8_t opcode_lengths[] =
        {0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1};
    bytes_reserve(&header, sizeof(opcode_lengths));
    memcpy(
        header.data + header.length,
        opcode_lengths,
        sizeof(opcode_lengths)
    );
    header.length += sizeof(opcode_lengths);
    byte(&header, 0); /* empty directory table */
    bytes_text(&header, source_path);
    uleb128(&header, 0); /* directory index */
    uleb128(&header, 0); /* modification time */
    uleb128(&header, 0); /* file size */
    byte(&header, 0);    /* end file table */

    Bytes program;
    bytes_init(&program);
    byte(&program, 0);
    uleb128(&program, 9);
    byte(&program, 2); /* DW_LNE_set_address */
    u64_le(&program, IMAGE_BASE + TEXT_OFFSET);

    size_t current_offset = 0;
    int64_t current_line = 1;
    for (size_t index = 0; index < rows->length; ++index) {
        size_t offset = rows->offsets[index];
        size_t line = rows->lines[index];
        if (offset < current_offset || offset > text_size) {
            fatal("native Core debug rows are not ordered");
        }
        if (line > (size_t)INT64_MAX) {
            fatal("native Core source has too many lines");
        }
        if (offset != current_offset) {
            byte(&program, 2); /* DW_LNS_advance_pc */
            uleb128(&program, (uint64_t)(offset - current_offset));
        }
        int64_t wanted_line = (int64_t)line;
        if (wanted_line != current_line) {
            byte(&program, 3); /* DW_LNS_advance_line */
            sleb128(&program, wanted_line - current_line);
        }
        byte(&program, 1); /* DW_LNS_copy */
        current_offset = offset;
        current_line = wanted_line;
    }

    if (text_size != current_offset) {
        byte(&program, 2);
        uleb128(&program, (uint64_t)(text_size - current_offset));
    }
    byte(&program, 0);
    uleb128(&program, 1);
    byte(&program, 1); /* DW_LNE_end_sequence */

    Bytes body;
    bytes_init(&body);
    u16_le(&body, 4);
    if (header.length > UINT32_MAX) fatal("DWARF line header is too large");
    u32_le(&body, (uint32_t)header.length);
    bytes_append(&body, &header);
    bytes_append(&body, &program);

    if (body.length > UINT32_MAX) fatal("DWARF line table is too large");
    u32_le(lines, (uint32_t)body.length);
    bytes_append(lines, &body);

    free(body.data);
    free(program.data);
    free(header.data);
}

static void symbol(Bytes *symbols, uint32_t name, uint64_t value, uint64_t size) {
    u32_le(symbols, name);
    byte(symbols, UINT8_C(0x12)); /* STB_GLOBAL | STT_FUNC */
    byte(symbols, 0);
    u16_le(symbols, 1); /* .text */
    u64_le(symbols, value);
    u64_le(symbols, size);
}

static void section_header(
    Bytes *sections,
    uint32_t name,
    uint32_t type,
    uint64_t flags,
    uint64_t address,
    uint64_t offset,
    uint64_t size,
    uint32_t link,
    uint32_t info,
    uint64_t alignment,
    uint64_t entry_size
) {
    u32_le(sections, name);
    u32_le(sections, type);
    u64_le(sections, flags);
    u64_le(sections, address);
    u64_le(sections, offset);
    u64_le(sections, size);
    u32_le(sections, link);
    u32_le(sections, info);
    u64_le(sections, alignment);
    u64_le(sections, entry_size);
}

static void elf_add_debug(
    Bytes *image,
    const Bytes *text,
    const char *source_path,
    size_t main_line,
    const LineRows *rows
) {
    Bytes abbreviations;
    Bytes information;
    Bytes lines;
    Bytes strings;
    Bytes symbols;
    Bytes symbol_strings;
    Bytes section_strings;
    bytes_init(&abbreviations);
    bytes_init(&information);
    bytes_init(&lines);
    bytes_init(&strings);
    bytes_init(&symbols);
    bytes_init(&symbol_strings);
    bytes_init(&section_strings);

    dwarf_abbreviations(&abbreviations);
    uint32_t source_offset = 0;
    uint32_t main_offset = 0;
    dwarf_strings(
        &strings,
        source_path,
        &source_offset,
        &main_offset
    );
    dwarf_information(
        &information,
        source_offset,
        main_offset,
        main_line,
        text->length
    );
    dwarf_line_table(&lines, source_path, rows, text->length);

    bytes_pad_to(&symbols, 24); /* mandatory null symbol */
    symbol(
        &symbols,
        1,
        IMAGE_BASE + TEXT_OFFSET,
        (uint64_t)text->length
    );
    byte(&symbol_strings, 0);
    bytes_text(&symbol_strings, "main");

    byte(&section_strings, 0);
    bytes_text(&section_strings, ".text");
    bytes_text(&section_strings, ".data");
    bytes_text(&section_strings, ".debug_abbrev");
    bytes_text(&section_strings, ".debug_info");
    bytes_text(&section_strings, ".debug_line");
    bytes_text(&section_strings, ".debug_str");
    bytes_text(&section_strings, ".symtab");
    bytes_text(&section_strings, ".strtab");
    bytes_text(&section_strings, ".shstrtab");

    size_t abbreviations_offset = image->length;
    bytes_append(image, &abbreviations);
    size_t information_offset = image->length;
    bytes_append(image, &information);
    size_t lines_offset = image->length;
    bytes_append(image, &lines);
    size_t strings_offset = image->length;
    bytes_append(image, &strings);
    bytes_align(image, 8);
    size_t symbols_offset = image->length;
    bytes_append(image, &symbols);
    size_t symbol_strings_offset = image->length;
    bytes_append(image, &symbol_strings);
    size_t section_strings_offset = image->length;
    bytes_append(image, &section_strings);
    bytes_align(image, 8);
    size_t section_headers_offset = image->length;

    Bytes sections;
    bytes_init(&sections);
    bytes_pad_to(&sections, 64); /* SHT_NULL */
    section_header(
        &sections,
        1, 1, 6,
        IMAGE_BASE + TEXT_OFFSET,
        TEXT_OFFSET,
        text->length,
        0, 0, 16, 0
    );
    section_header(
        &sections,
        7, 1, 3,
        DATA_ADDRESS,
        PAGE_SIZE,
        3,
        0, 0, 1, 0
    );
    section_header(
        &sections,
        13, 1, 0, 0,
        abbreviations_offset, abbreviations.length,
        0, 0, 1, 0
    );
    section_header(
        &sections,
        27, 1, 0, 0,
        information_offset, information.length,
        0, 0, 1, 0
    );
    section_header(
        &sections,
        39, 1, 0, 0,
        lines_offset, lines.length,
        0, 0, 1, 0
    );
    section_header(
        &sections,
        51, 1, 48, 0,
        strings_offset, strings.length,
        0, 0, 1, 1
    );
    section_header(
        &sections,
        62, 2, 0, 0,
        symbols_offset, symbols.length,
        8, 1, 8, 24
    );
    section_header(
        &sections,
        70, 3, 0, 0,
        symbol_strings_offset, symbol_strings.length,
        0, 0, 1, 0
    );
    section_header(
        &sections,
        78, 3, 0, 0,
        section_strings_offset, section_strings.length,
        0, 0, 1, 0
    );
    bytes_append(image, &sections);

    patch_u64_le(image, 40, (uint64_t)section_headers_offset);
    patch_u16_le(image, 58, 64);
    patch_u16_le(image, 60, 10);
    patch_u16_le(image, 62, 9);

    free(sections.data);
    free(section_strings.data);
    free(symbol_strings.data);
    free(symbols.data);
    free(strings.data);
    free(lines.data);
    free(information.data);
    free(abbreviations.data);
}

static bool write_image(const char *path, const Bytes *image) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        fprintf(stderr, "kofun native: cannot write %s: %s\n",
                path, strerror(errno));
        return false;
    }
    bool ok =
        fwrite(image->data, 1, image->length, file) == image->length;
    if (fclose(file) != 0) ok = false;
    if (!ok) {
        fprintf(stderr, "kofun native: cannot complete %s\n", path);
    }
    return ok;
}

static void usage(void) {
    fputs(
        "usage: kofun-native-core INPUT.kofun "
        "(x86_64-linux|aarch64-linux) [-g] OUTPUT\n",
        stderr
    );
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        usage();
        return 2;
    }
    bool debug = argc == 5 && strcmp(argv[3], "-g") == 0;
    if (argc == 5 && !debug) {
        usage();
        return 2;
    }
    const char *output_path = debug ? argv[4] : argv[3];

    uint16_t machine = 0;
    bool aarch64 = false;
    if (strcmp(argv[2], "x86_64-linux") == 0) {
        machine = 62; /* EM_X86_64 */
    } else if (strcmp(argv[2], "aarch64-linux") == 0) {
        machine = 183; /* EM_AARCH64 */
        aarch64 = true;
    } else {
        fprintf(stderr, "kofun native: unsupported target: %s\n", argv[2]);
        return 2;
    }

    char *source = read_source(argv[1]);
    if (source == NULL) return 1;
    KofunUnicodeError unicode_error;
    if (!kofun_unicode_validate_source(
            (const uint8_t *)source,
            strlen(source),
            &unicode_error)) {
        char message[1024];
        kofun_unicode_format_error(
            &unicode_error,
            getenv("KOFUN_DIAGNOSTIC_LOCALE"),
            message,
            sizeof(message)
        );
        fprintf(stderr, "kofun native: %s\n", message);
        free(source);
        return 1;
    }

    FunctionProgram function_program;
    char function_error_text[256] = {0};
    size_t function_error_at = 0;
    bool function_headers_ok = function_headers(
        source,
        &function_program,
        function_error_text,
        &function_error_at
    );
    if (!function_headers_ok && strstr(source, "->") != NULL) {
        fprintf(
            stderr,
            "kofun native: unsupported function Core at byte %zu: %s\n",
            function_error_at,
            function_error_text
        );
        function_program_free(&function_program);
        free(source);
        return 1;
    }
    bool use_function_core =
        function_headers_ok && function_program.function_count > 1;
    /*
     * Two front ends read this source. The bounded single-`main` Core is tried
     * first and is never disturbed: it keeps its own parser, its own lowering,
     * and every byte of every image it already produces. Only when it refuses
     * does a program that declares exactly `main` fall through to the function
     * profile, which accepts strictly more statement shapes — several `print`
     * statements, inferred Int locals, and the division operators. Because the
     * fallback runs only on rejection, the two accepted sets are disjoint by
     * construction and nothing that compiles today can change.
     */
    Parser parser = {
        .source = source,
        .cursor = 0,
        .error = NULL,
    };
    Node *expression = NULL;
    bool fell_back = false;
    if (!use_function_core) {
        expression = parse_program(&parser);
        /*
         * `-g` documents the single-`main` aggregate Core, so a debug build
         * that Core refuses reports that refusal instead of falling through to
         * a profile whose debug information does not exist.
         */
        if ((parser.error != NULL || expression == NULL) &&
            !debug &&
            function_headers_ok &&
            function_program.function_count == 1) {
            free_node(expression);
            expression = NULL;
            use_function_core = true;
            fell_back = true;
        }
    }
    if (use_function_core) {
        if (debug) {
            fputs(
                "kofun native: -g for user-defined functions is not "
                "implemented yet\n",
                stderr
            );
            function_program_free(&function_program);
            free(source);
            return 1;
        }
        if (!function_bodies(
                &function_program,
                function_error_text,
                &function_error_at)) {
            /*
             * A program that reached here through the fallback was refused by
             * both front ends, and the verdict on it is the Core's, not one
             * profile's. Keeping the `unsupported Core` wording carries the
             * more specific reason without changing what the refusal means to
             * anything reading it.
             */
            fprintf(
                stderr,
                fell_back
                    ? "kofun native: unsupported Core at byte %zu: %s\n"
                    : "kofun native: unsupported function Core at byte %zu: %s\n",
                function_error_at,
                function_error_text
            );
            function_program_free(&function_program);
            free(source);
            return 1;
        }
        /*
         * The syscall intrinsics name the Linux x86-64 boundary. AArch64 uses
         * a different one and is a separate checkpoint, so say so here rather
         * than emit an image in which the calls mean nothing.
         */
        if (aarch64 && function_program_uses_syscall(&function_program)) {
            fputs(
                "kofun native: the Linux syscall intrinsics lower on "
                "x86_64-linux only\n",
                stderr
            );
            function_program_free(&function_program);
            free(source);
            return 1;
        }
        Bytes text;
        bytes_init(&text);
        Bytes data;
        bytes_init(&data);
        if (aarch64) {
            a64_function_program(&text, &data, &function_program);
        } else {
            x64_function_program(&text, &data, &function_program);
        }
        Bytes image;
        bytes_init(&image);
        elf_image(&image, machine, &text, &data);
        bool ok = write_image(output_path, &image);
        free(image.data);
        free(data.data);
        free(text.data);
        function_program_free(&function_program);
        free(source);
        return ok ? 0 : 1;
    }
    function_program_free(&function_program);

    if (parser.error != NULL || expression == NULL) {
        fprintf(
            stderr,
            "kofun native: unsupported Core at byte %zu: %s\n",
            parser.cursor,
            parser.error == NULL ? "invalid expression" : parser.error
        );
        free_node(expression);
        free(source);
        return 1;
    }
    bool aarch64_aggregate_core =
        aarch64 &&
        (
            uses_list(expression) ||
            uses_text(expression) ||
            uses_local_bindings(expression)
        );
    if (aarch64 && !aarch64_aggregate_core &&
        register_depth(expression) > 16) {
        fprintf(stderr, "kofun native: AArch64 Core needs over 16 registers\n");
        free_node(expression);
        free(source);
        return 1;
    }
    /*
     * AArch64 debug metadata covers the same single-`main` scalar Core the
     * x86-64 debug path accepts. The List/Text lowering emits no source-line
     * rows yet, so it is refused here rather than producing a debug image with
     * an empty line table.
     */
    if (debug && aarch64_aggregate_core) {
        fputs(
            "kofun native: -g for the AArch64 List/Text Core is not "
            "implemented yet\n",
            stderr
        );
        free_node(expression);
        free(source);
        return 1;
    }

    Bytes text;
    bytes_init(&text);
    LineRows rows;
    line_rows_init(&rows);
    if (aarch64) {
        if (aarch64_aggregate_core) {
            a64_core_text(
                &text,
                expression,
                parser.local_count + parser.max_lambda_parameters
            );
        } else {
            a64_text(&text, expression, &rows, parser.print_line);
        }
    } else {
        x64_text(
            &text,
            expression,
            &rows,
            parser.print_line,
            parser.local_count + parser.max_lambda_parameters
        );
    }

    Bytes image;
    bytes_init(&image);
    elf_image(&image, machine, &text, NULL);
    if (debug) {
        elf_add_debug(
            &image,
            &text,
            argv[1],
            parser.main_line,
            &rows
        );
    }
    bool ok = write_image(output_path, &image);

    free(image.data);
    line_rows_free(&rows);
    free(text.data);
    free_node(expression);
    free(source);
    return ok ? 0 : 1;
}
