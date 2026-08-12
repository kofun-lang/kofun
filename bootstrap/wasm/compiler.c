#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "object_arena.h"

enum {
    MAX_SOURCE_BYTES = 1024 * 1024,
    MAX_BINDINGS = 128,
    MAX_NODES = 1024,
    MAX_STATEMENTS = 256,
    MAX_EXPRESSION_NESTING = 256,
    MAX_FUNCTIONS = 64,
    MAX_PARAMETERS = 6,
    MAX_ARGUMENTS = 512,
    MAX_CONDITIONS = 128,
    MAX_BLOCK_NESTING = 64,
    NAME_CAPACITY = 64
};

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
} Buffer;

typedef enum {
    TOKEN_EOF,
    TOKEN_IDENTIFIER,
    TOKEN_INTEGER,
    TOKEN_LEFT_PAREN,
    TOKEN_RIGHT_PAREN,
    TOKEN_LEFT_BRACE,
    TOKEN_RIGHT_BRACE,
    TOKEN_COLON,
    TOKEN_EQUAL,
    TOKEN_ARROW,
    TOKEN_PLUS,
    TOKEN_MINUS,
    TOKEN_STAR,
    TOKEN_SLASH,
    TOKEN_FLOOR_DIV,
    TOKEN_PERCENT,
    TOKEN_COMMA,
    TOKEN_EQUAL_EQUAL,
    TOKEN_BANG_EQUAL,
    TOKEN_LESS,
    TOKEN_LESS_EQUAL,
    TOKEN_GREATER,
    TOKEN_GREATER_EQUAL
} TokenKind;

typedef struct {
    TokenKind kind;
    const char *start;
    size_t length;
    uint64_t magnitude;
    size_t line;
} Token;

typedef enum {
    NODE_LITERAL,
    NODE_VARIABLE,
    NODE_NEGATE,
    NODE_ADD,
    NODE_SUBTRACT,
    NODE_MULTIPLY,
    NODE_FLOOR_DIVIDE,
    NODE_FLOOR_MODULO,
    NODE_CALL
} NodeKind;

typedef struct {
    NodeKind kind;
    int left;
    int right;
    int binding;
    int64_t value;
    int callee;
    int argument_start;
    int argument_count;
} Node;

typedef struct {
    char name[NAME_CAPACITY];
    size_t length;
} Binding;

/* A Kofun Bool never becomes a value in this slice: a comparison exists only
 * as the i32 branch condition of one `if`, which is what the encoding contract
 * pins. Keeping conditions out of the Node arena keeps every node local i64. */
typedef struct {
    TokenKind comparison;
    int left;
    int right;
} Condition;

typedef enum {
    STATEMENT_BIND,
    STATEMENT_PRINT,
    STATEMENT_RETURN,
    STATEMENT_IF
} StatementKind;

typedef struct {
    StatementKind kind;
    int expression;
    int binding;
    int condition;
    int body;
    int next;
} Statement;

typedef struct {
    char name[NAME_CAPACITY];
    size_t name_length;
    int parameter_count;
    /*
     * The declaration-site external label of each parameter, empty when there
     * is none. Only call sites read these: the body binds the *internal* name,
     * because a label is call-site vocabulary and must not become a lexical
     * binding (call-arguments v1, rule 4).
     */
    char parameter_labels[MAX_PARAMETERS][NAME_CAPACITY];
    size_t parameter_label_lengths[MAX_PARAMETERS];
    bool returns_int;
    size_t line;
    /* Parameters and `let` bindings share one ascending run of i64 locals;
     * `local_slots` is the deepest that run ever gets, because sibling blocks
     * reuse the slots a finished block released. */
    int local_slots;
    int node_base;
    int node_span;
    int body;
} Function;

typedef struct {
    const char *source;
    size_t length;
    size_t cursor;
    size_t line;
    Token token;
    const char *error;
    size_t error_line;
    Node nodes[MAX_NODES];
    size_t node_count;
    Binding bindings[MAX_BINDINGS];
    size_t binding_count;
    Statement statements[MAX_STATEMENTS];
    size_t statement_count;
    Function functions[MAX_FUNCTIONS];
    size_t function_count;
    int arguments[MAX_ARGUMENTS];
    /*
     * `arguments` is indexed by *declaration slot*, so the push loop fills the
     * wasm operand stack in declaration order simply by walking it.
     * `argument_order` records which slot each *written* position filled, so
     * the evaluation loop walks source order instead. A labelled call written
     * out of order therefore evaluates as written and is passed as declared,
     * and neither loop has to know about labels.
     */
    int argument_order[MAX_ARGUMENTS];
    size_t argument_count;
    Condition conditions[MAX_CONDITIONS];
    size_t condition_count;
    int current;
    int main_index;
    size_t block_nesting;
    size_t print_count;
    size_t expression_nesting;
} Parser;

static void fatal(const char *message) {
    fprintf(stderr, "kofun wasm32: %s\n", message);
    exit(1);
}

static void *allocate(size_t size) {
    void *result = malloc(size == 0 ? 1 : size);
    if (result == NULL) fatal("out of memory");
    return result;
}

static void buffer_reserve(Buffer *buffer, size_t extra) {
    if (extra > SIZE_MAX - buffer->length) fatal("module is too large");
    size_t wanted = buffer->length + extra;
    if (wanted <= buffer->capacity) return;
    size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
    while (capacity < wanted) {
        if (capacity > SIZE_MAX / 2) fatal("module is too large");
        capacity *= 2;
    }
    uint8_t *grown = realloc(buffer->data, capacity);
    if (grown == NULL) fatal("out of memory");
    buffer->data = grown;
    buffer->capacity = capacity;
}

static void byte(Buffer *buffer, uint8_t value) {
    buffer_reserve(buffer, 1);
    buffer->data[buffer->length++] = value;
}

static void bytes(Buffer *buffer, const void *data, size_t length) {
    buffer_reserve(buffer, length);
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
}

static void uleb(Buffer *buffer, uint64_t value) {
    do {
        uint8_t part = (uint8_t)(value & UINT64_C(0x7f));
        value >>= 7;
        if (value != 0) part |= UINT8_C(0x80);
        byte(buffer, part);
    } while (value != 0);
}

static void sleb(Buffer *buffer, int64_t value) {
    for (;;) {
        uint8_t part = (uint8_t)((uint64_t)value & UINT64_C(0x7f));
        bool sign = (part & UINT8_C(0x40)) != 0;
        int64_t next;
        if (value >= 0) {
            next = value / 128;
        } else {
            next = -1 - ((-1 - value) / 128);
        }
        bool done =
            (next == 0 && !sign) ||
            (next == -1 && sign);
        if (!done) part |= UINT8_C(0x80);
        byte(buffer, part);
        if (done) return;
        value = next;
    }
}

static void wasm_string(Buffer *buffer, const char *value) {
    size_t length = strlen(value);
    uleb(buffer, length);
    bytes(buffer, value, length);
}

static void section(Buffer *module, uint8_t identifier, const Buffer *payload) {
    byte(module, identifier);
    uleb(module, payload->length);
    bytes(module, payload->data, payload->length);
}

static char *read_source(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        fprintf(stderr, "kofun wasm32: cannot open %s: %s\n",
                path, strerror(errno));
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        fatal("cannot seek input");
    }
    long end = ftell(file);
    if (end < 0 || (uint64_t)end > MAX_SOURCE_BYTES) {
        fclose(file);
        fatal("source exceeds 1 MiB wasm32 Core limit");
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        fatal("cannot rewind input");
    }
    size_t size = (size_t)end;
    char *source = allocate(size + 1);
    if (size != 0 && fread(source, 1, size, file) != size) {
        fclose(file);
        free(source);
        fatal("cannot read input");
    }
    if (fclose(file) != 0) {
        free(source);
        fatal("cannot close input");
    }
    source[size] = '\0';
    *length = size;
    return source;
}

static void parse_error_at(Parser *parser, const char *message, size_t line) {
    if (parser->error != NULL) return;
    parser->error = message;
    parser->error_line = line == 0 ? parser->line : line;
}

static void parse_error(Parser *parser, const char *message) {
    parse_error_at(parser, message, parser->token.line);
}

static bool identifier_start(char value) {
    return isalpha((unsigned char)value) || value == '_';
}

static bool identifier_continue(char value) {
    return isalnum((unsigned char)value) || value == '_';
}

static bool peek_is(const Parser *parser, char value) {
    return parser->cursor < parser->length &&
           parser->source[parser->cursor] == value;
}

static void next_token(Parser *parser) {
    while (parser->cursor < parser->length) {
        char value = parser->source[parser->cursor];
        if (value == '#') {
            while (parser->cursor < parser->length &&
                   parser->source[parser->cursor] != '\n') {
                ++parser->cursor;
            }
            continue;
        }
        if (!isspace((unsigned char)value)) break;
        if (value == '\n') ++parser->line;
        ++parser->cursor;
    }

    parser->token.start = parser->source + parser->cursor;
    parser->token.length = 0;
    parser->token.magnitude = 0;
    parser->token.line = parser->line;
    if (parser->cursor == parser->length) {
        parser->token.kind = TOKEN_EOF;
        return;
    }

    char value = parser->source[parser->cursor++];
    if (identifier_start(value)) {
        while (parser->cursor < parser->length &&
               identifier_continue(parser->source[parser->cursor])) {
            ++parser->cursor;
        }
        parser->token.kind = TOKEN_IDENTIFIER;
        parser->token.length =
            (size_t)((parser->source + parser->cursor) - parser->token.start);
        return;
    }
    if (isdigit((unsigned char)value)) {
        uint64_t magnitude = (uint64_t)(value - '0');
        while (parser->cursor < parser->length &&
               isdigit((unsigned char)parser->source[parser->cursor])) {
            uint64_t digit =
                (uint64_t)(parser->source[parser->cursor++] - '0');
            if (magnitude > (UINT64_C(9223372036854775808) - digit) / 10) {
                parser->token.kind = TOKEN_INTEGER;
                parser->token.length = (size_t)(
                    (parser->source + parser->cursor) - parser->token.start
                );
                parse_error(parser, "integer literal exceeds Int64");
                return;
            }
            magnitude = magnitude * 10 + digit;
        }
        parser->token.kind = TOKEN_INTEGER;
        parser->token.length =
            (size_t)((parser->source + parser->cursor) - parser->token.start);
        parser->token.magnitude = magnitude;
        return;
    }

    parser->token.length = 1;
    switch (value) {
        case '(':
            parser->token.kind = TOKEN_LEFT_PAREN;
            return;
        case ')':
            parser->token.kind = TOKEN_RIGHT_PAREN;
            return;
        case '{':
            parser->token.kind = TOKEN_LEFT_BRACE;
            return;
        case '}':
            parser->token.kind = TOKEN_RIGHT_BRACE;
            return;
        case ':':
            parser->token.kind = TOKEN_COLON;
            return;
        case '=':
            if (peek_is(parser, '=')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_EQUAL_EQUAL;
                parser->token.length = 2;
            } else {
                parser->token.kind = TOKEN_EQUAL;
            }
            return;
        case '!':
            if (peek_is(parser, '=')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_BANG_EQUAL;
                parser->token.length = 2;
                return;
            }
            parser->token.kind = TOKEN_EOF;
            parse_error(parser, "unsupported token in wasm32 arithmetic Core");
            return;
        case '<':
            if (peek_is(parser, '=')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_LESS_EQUAL;
                parser->token.length = 2;
            } else {
                parser->token.kind = TOKEN_LESS;
            }
            return;
        case '>':
            if (peek_is(parser, '=')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_GREATER_EQUAL;
                parser->token.length = 2;
            } else {
                parser->token.kind = TOKEN_GREATER;
            }
            return;
        case '+':
            parser->token.kind = TOKEN_PLUS;
            return;
        case '-':
            if (peek_is(parser, '>')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_ARROW;
                parser->token.length = 2;
            } else {
                parser->token.kind = TOKEN_MINUS;
            }
            return;
        case '*':
            parser->token.kind = TOKEN_STAR;
            return;
        case '%':
            parser->token.kind = TOKEN_PERCENT;
            return;
        case ',':
            parser->token.kind = TOKEN_COMMA;
            return;
        case '/':
            if (peek_is(parser, '/')) {
                ++parser->cursor;
                parser->token.kind = TOKEN_FLOOR_DIV;
                parser->token.length = 2;
            } else {
                parser->token.kind = TOKEN_SLASH;
            }
            return;
        case '|':
            /*
             * `|` reaches the lexer only as the head of `|>`; wasm32 Core has
             * no bitwise or alternation operator. Naming the pipeline here is
             * what stops the generic unknown-token wording from describing a
             * pipe the author wrote deliberately and correctly.
             */
            if (peek_is(parser, '>')) {
                ++parser->cursor;
                parser->token.length = 2;
                parser->token.kind = TOKEN_EOF;
                parse_error(
                    parser,
                    "a pipeline is specified by call-arguments v1 but not "
                    "recognized by wasm32 Core"
                );
                return;
            }
            parser->token.kind = TOKEN_EOF;
            parse_error(parser, "unsupported token in wasm32 arithmetic Core");
            return;
        case '?':
            /* `Int?` and `??` are the Optional surface. */
            parser->token.kind = TOKEN_EOF;
            parse_error(
                parser,
                "an Optional type is specified by call-arguments v1 but "
                "wasm32 Core has only Int"
            );
            return;
        default:
            parser->token.kind = TOKEN_EOF;
            parse_error(parser, "unsupported token in wasm32 arithmetic Core");
            return;
    }
}

static void reset_lexer(Parser *parser) {
    parser->cursor = 0;
    parser->line = 1;
    parser->expression_nesting = 0;
    parser->block_nesting = 0;
    next_token(parser);
}

static bool token_is(const Parser *parser, const char *value) {
    size_t length = strlen(value);
    return parser->token.kind == TOKEN_IDENTIFIER &&
           parser->token.length == length &&
           memcmp(parser->token.start, value, length) == 0;
}

static bool consume(Parser *parser, TokenKind kind) {
    if (parser->token.kind != kind) return false;
    next_token(parser);
    return true;
}

static bool consume_word(Parser *parser, const char *value) {
    if (!token_is(parser, value)) return false;
    next_token(parser);
    return true;
}

static bool expect(Parser *parser, TokenKind kind, const char *message) {
    if (!consume(parser, kind)) {
        parse_error(parser, message);
        return false;
    }
    return true;
}

static bool expect_word(Parser *parser, const char *value, const char *message) {
    if (!consume_word(parser, value)) {
        parse_error(parser, message);
        return false;
    }
    return true;
}

static int allocate_node(Parser *parser, Node node) {
    if (parser->node_count == MAX_NODES) {
        parse_error(parser, "too many expressions in wasm32 Core");
        return -1;
    }
    int index = (int)parser->node_count++;
    parser->nodes[index] = node;
    return index;
}

static int add_node(
    Parser *parser,
    NodeKind kind,
    int left,
    int right,
    int binding,
    int64_t value
) {
    return allocate_node(parser, (Node){
        .kind = kind,
        .left = left,
        .right = right,
        .binding = binding,
        .value = value,
        .callee = -1,
        .argument_start = 0,
        .argument_count = 0
    });
}

/* Bindings are function-scoped: `binding_count` is reset for each body, so a
 * binding's index is directly its i64 local index. */
static int find_binding(
    const Parser *parser,
    const char *name,
    size_t length
) {
    for (size_t index = parser->binding_count; index > 0; --index) {
        const Binding *binding = &parser->bindings[index - 1];
        if (binding->length == length &&
            memcmp(binding->name, name, length) == 0) {
            return (int)(index - 1);
        }
    }
    return -1;
}

static bool check_new_binding(
    Parser *parser,
    const char *name,
    size_t length,
    const char *duplicate_message
) {
    if (length >= NAME_CAPACITY) {
        parse_error(parser, "binding name is too long");
        return false;
    }
    if (parser->binding_count == MAX_BINDINGS) {
        parse_error(parser, "too many bindings in wasm32 Core");
        return false;
    }
    if (find_binding(parser, name, length) >= 0) {
        parse_error(parser, duplicate_message);
        return false;
    }
    return true;
}

static int commit_binding(Parser *parser, const char *name, size_t length) {
    int slot = (int)parser->binding_count++;
    Binding *target = &parser->bindings[slot];
    memcpy(target->name, name, length);
    target->name[length] = '\0';
    target->length = length;
    Function *function = &parser->functions[parser->current];
    if ((int)parser->binding_count > function->local_slots) {
        function->local_slots = (int)parser->binding_count;
    }
    return slot;
}

static int find_function(
    const Parser *parser,
    const char *name,
    size_t length
) {
    for (size_t index = 0; index < parser->function_count; ++index) {
        const Function *function = &parser->functions[index];
        if (function->name_length == length &&
            memcmp(function->name, name, length) == 0) {
            return (int)index;
        }
    }
    return -1;
}

static int parse_expression(Parser *parser);

static bool enter_expression_nesting(Parser *parser) {
    if (parser->expression_nesting >= MAX_EXPRESSION_NESTING) {
        parse_error(
            parser,
            "expression nesting exceeds wasm32 limit of 256"
        );
        return false;
    }
    ++parser->expression_nesting;
    return true;
}

static void leave_expression_nesting(Parser *parser) {
    if (parser->expression_nesting == 0) {
        fatal("internal expression nesting underflow");
    }
    --parser->expression_nesting;
}

/* The callee is resolved against the whole declaration table, which the
 * signature scan filled before any body was parsed, so a forward call reads
 * exactly like a backward one. The current token is the `(`. */
/* Whether the token after the current one is `:`, without consuming either. A
 * labelled argument is only distinguishable from an ordinary expression by what
 * follows its first name, so the decision precedes any consumption. */
static bool peek_is_colon(const Parser *parser) {
    Parser probe = *parser;
    next_token(&probe);
    return probe.token.kind == TOKEN_COLON;
}

/* The declaration slot carrying `label`, or -1. Internal names are deliberately
 * not accepted: a call may not spell a binding the callee owns. */
static int wasm_label_slot(
    const Function *function,
    const char *label,
    size_t label_length
) {
    for (int slot = 0; slot < function->parameter_count; ++slot) {
        if (function->parameter_label_lengths[slot] == label_length &&
            memcmp(function->parameter_labels[slot], label, label_length) == 0) {
            return slot;
        }
    }
    return -1;
}

static int parse_call(
    Parser *parser,
    const char *name,
    size_t length,
    size_t line
) {
    int callee = find_function(parser, name, length);
    if (callee < 0) {
        if (find_binding(parser, name, length) >= 0) {
            parse_error_at(
                parser,
                "wasm32 Core does not support calling a binding; only direct calls to declared functions",
                line
            );
        } else {
            parse_error_at(
                parser,
                "call to a function the wasm32 Core program does not declare",
                line
            );
        }
        return -1;
    }
    if (!expect(parser, TOKEN_LEFT_PAREN,
                "expected `(` in wasm32 Core call")) {
        return -1;
    }
    if (!enter_expression_nesting(parser)) return -1;
    /* Arguments are collected on the C stack first. An argument may itself be
     * a call, and that inner call claims its own slice of `arguments` while
     * this one is still being read, so this call cannot reserve a slice until
     * every nested call has finished taking theirs. */
    int scratch[MAX_PARAMETERS];
    int order[MAX_PARAMETERS];
    for (int slot = 0; slot < MAX_PARAMETERS; ++slot) scratch[slot] = -1;
    int count = 0;
    if (parser->token.kind != TOKEN_RIGHT_PAREN) {
        for (;;) {
            /*
             * `label: value` binds the slot the declaration gave that label.
             * The label is looked up in the already-resolved callee — labels
             * never choose the callee, they only validate the call.
             */
            int slot = count;
            if (parser->token.kind == TOKEN_IDENTIFIER &&
                peek_is_colon(parser)) {
                const char *label = parser->token.start;
                size_t label_length = parser->token.length;
                int labelled_slot = wasm_label_slot(
                    &parser->functions[callee],
                    label,
                    label_length
                );
                next_token(parser);
                next_token(parser);
                if (labelled_slot < 0) {
                    parse_error_at(
                        parser,
                        "call uses a label the wasm32 Core declaration does not declare",
                        line
                    );
                    leave_expression_nesting(parser);
                    return -1;
                }
                if (scratch[labelled_slot] >= 0) {
                    parse_error_at(
                        parser,
                        "call repeats a wasm32 Core argument label",
                        line
                    );
                    leave_expression_nesting(parser);
                    return -1;
                }
                slot = labelled_slot;
            } else {
                while (slot < MAX_PARAMETERS && scratch[slot] >= 0) ++slot;
                if (slot < parser->functions[callee].parameter_count &&
                    parser->functions[callee]
                        .parameter_label_lengths[slot] != 0) {
                    parse_error_at(
                        parser,
                        "call omits the label the wasm32 Core declaration requires",
                        line
                    );
                    leave_expression_nesting(parser);
                    return -1;
                }
            }
            int argument = parse_expression(parser);
            if (argument < 0) {
                leave_expression_nesting(parser);
                return -1;
            }
            if (slot >= MAX_PARAMETERS || count == MAX_PARAMETERS) {
                /* No declaration can accept more than six, so an argument past
                 * the sixth is already an arity mismatch. */
                parse_error_at(
                    parser,
                    "call passes a different number of arguments than the declaration accepts",
                    line
                );
                leave_expression_nesting(parser);
                return -1;
            }
            scratch[slot] = argument;
            order[count++] = slot;
            if (!consume(parser, TOKEN_COMMA)) break;
        }
    }
    leave_expression_nesting(parser);
    if (!expect(parser, TOKEN_RIGHT_PAREN,
                "expected `)` after the wasm32 Core argument list")) {
        return -1;
    }
    if (count != parser->functions[callee].parameter_count) {
        parse_error_at(
            parser,
            "call passes a different number of arguments than the declaration accepts",
            line
        );
        return -1;
    }
    if (parser->argument_count + (size_t)count > MAX_ARGUMENTS) {
        parse_error(parser, "too many call arguments in wasm32 Core");
        return -1;
    }
    int start = (int)parser->argument_count;
    for (int argument = 0; argument < count; ++argument) {
        parser->argument_order[parser->argument_count] = order[argument];
        parser->arguments[parser->argument_count++] = scratch[argument];
    }
    return allocate_node(parser, (Node){
        .kind = NODE_CALL,
        .left = -1,
        .right = -1,
        .binding = -1,
        .value = 0,
        .callee = callee,
        .argument_start = start,
        .argument_count = count
    });
}

static int parse_primary(Parser *parser) {
    if (consume(parser, TOKEN_LEFT_PAREN)) {
        if (!enter_expression_nesting(parser)) return -1;
        int expression = parse_expression(parser);
        leave_expression_nesting(parser);
        if (expression < 0) return -1;
        if (!expect(parser, TOKEN_RIGHT_PAREN,
                    "expected `)` in wasm32 Core expression")) {
            return -1;
        }
        return expression;
    }
    if (parser->token.kind == TOKEN_INTEGER) {
        uint64_t magnitude = parser->token.magnitude;
        if (magnitude > INT64_MAX) {
            parse_error(parser, "positive integer literal exceeds Int64");
            return -1;
        }
        next_token(parser);
        return add_node(parser, NODE_LITERAL, -1, -1, -1,
                        (int64_t)magnitude);
    }
    if (parser->token.kind == TOKEN_IDENTIFIER) {
        const char *name = parser->token.start;
        size_t length = parser->token.length;
        size_t line = parser->token.line;
        next_token(parser);
        if (parser->token.kind == TOKEN_LEFT_PAREN) {
            return parse_call(parser, name, length, line);
        }
        int binding = find_binding(parser, name, length);
        if (binding < 0) {
            if (find_function(parser, name, length) >= 0) {
                parse_error_at(
                    parser,
                    "wasm32 Core has no function values; write a direct call instead",
                    line
                );
            } else {
                parse_error_at(
                    parser,
                    "unknown binding in wasm32 Core expression",
                    line
                );
            }
            return -1;
        }
        return add_node(parser, NODE_VARIABLE, -1, -1, binding, 0);
    }
    parse_error(parser, "expected Int expression in wasm32 Core");
    return -1;
}

static int parse_unary(Parser *parser) {
    bool negate;
    if (consume(parser, TOKEN_PLUS)) {
        negate = false;
    } else if (consume(parser, TOKEN_MINUS)) {
        negate = true;
    } else {
        return parse_primary(parser);
    }

    if (!enter_expression_nesting(parser)) return -1;
    int result;
    if (negate && parser->token.kind == TOKEN_INTEGER) {
        uint64_t magnitude = parser->token.magnitude;
        next_token(parser);
        int64_t value =
            magnitude == UINT64_C(9223372036854775808)
                ? INT64_MIN
                : -(int64_t)magnitude;
        result = add_node(parser, NODE_LITERAL, -1, -1, -1, value);
    } else {
        int operand = parse_unary(parser);
        if (operand < 0 || !negate) {
            result = operand;
        } else {
            result = add_node(parser, NODE_NEGATE, operand, -1, -1, 0);
        }
    }
    leave_expression_nesting(parser);
    return result;
}

static int parse_term(Parser *parser) {
    int left = parse_unary(parser);
    while (parser->error == NULL) {
        NodeKind kind;
        if (consume(parser, TOKEN_STAR)) {
            kind = NODE_MULTIPLY;
        } else if (consume(parser, TOKEN_FLOOR_DIV)) {
            kind = NODE_FLOOR_DIVIDE;
        } else if (consume(parser, TOKEN_PERCENT)) {
            kind = NODE_FLOOR_MODULO;
        } else if (parser->token.kind == TOKEN_SLASH) {
            /* Kofun has no implicit numeric promotion, so `/` cannot produce a
             * fractional value from two Int operands and has nothing to mean on
             * Int. The integer quotient is `//`, which floors. */
            parse_error(
                parser,
                "`/` is not defined on Int; use `//` for the integer quotient"
            );
            break;
        } else {
            break;
        }
        int right = parse_unary(parser);
        left = add_node(parser, kind, left, right, -1, 0);
    }
    return left;
}

static int parse_expression(Parser *parser) {
    int left = parse_term(parser);
    while (parser->error == NULL) {
        NodeKind kind;
        if (consume(parser, TOKEN_PLUS)) {
            kind = NODE_ADD;
        } else if (consume(parser, TOKEN_MINUS)) {
            kind = NODE_SUBTRACT;
        } else {
            break;
        }
        int right = parse_term(parser);
        left = add_node(parser, kind, left, right, -1, 0);
    }
    return left;
}

static int add_statement(Parser *parser, Statement statement) {
    if (parser->statement_count == MAX_STATEMENTS) {
        parse_error(parser, "too many statements in wasm32 Core");
        return -1;
    }
    int index = (int)parser->statement_count++;
    parser->statements[index] = statement;
    return index;
}

static int parse_binding_statement(Parser *parser) {
    if (parser->token.kind != TOKEN_IDENTIFIER) {
        parse_error(parser, "expected binding name after `let`");
        return -1;
    }
    const char *name = parser->token.start;
    size_t length = parser->token.length;
    if (!check_new_binding(parser, name, length,
                           "duplicate binding in wasm32 Core")) {
        return -1;
    }
    next_token(parser);
    if (consume(parser, TOKEN_COLON)) {
        if (!expect_word(parser, "Int",
                         "wasm32 arithmetic Core supports only Int bindings")) {
            return -1;
        }
    }
    if (!expect(parser, TOKEN_EQUAL, "expected `=` in wasm32 Core binding")) {
        return -1;
    }
    int expression = parse_expression(parser);
    if (expression < 0) return -1;
    int slot = commit_binding(parser, name, length);
    return add_statement(parser, (Statement){
        .kind = STATEMENT_BIND,
        .expression = expression,
        .binding = slot,
        .condition = -1,
        .body = -1,
        .next = -1
    });
}

static int parse_print_statement(Parser *parser) {
    if (!expect(parser, TOKEN_LEFT_PAREN,
                "expected `(` after print in wasm32 Core")) {
        return -1;
    }
    int expression = parse_expression(parser);
    if (expression < 0) return -1;
    if (!expect(parser, TOKEN_RIGHT_PAREN,
                "expected `)` after print expression")) {
        return -1;
    }
    ++parser->print_count;
    return add_statement(parser, (Statement){
        .kind = STATEMENT_PRINT,
        .expression = expression,
        .binding = -1,
        .condition = -1,
        .body = -1,
        .next = -1
    });
}

static int parse_return_statement(Parser *parser) {
    const Function *function = &parser->functions[parser->current];
    if (parser->token.kind == TOKEN_RIGHT_BRACE) {
        if (function->returns_int) {
            parse_error(
                parser,
                "`return` must carry an Int value in a wasm32 Core function declaring `-> Int`"
            );
            return -1;
        }
        return add_statement(parser, (Statement){
            .kind = STATEMENT_RETURN,
            .expression = -1,
            .binding = -1,
            .condition = -1,
            .body = -1,
            .next = -1
        });
    }
    if (!function->returns_int) {
        parse_error(
            parser,
            "`return` carries a value but the wasm32 Core function declares no `-> Int` result"
        );
        return -1;
    }
    int expression = parse_expression(parser);
    if (expression < 0) return -1;
    return add_statement(parser, (Statement){
        .kind = STATEMENT_RETURN,
        .expression = expression,
        .binding = -1,
        .condition = -1,
        .body = -1,
        .next = -1
    });
}

static bool parse_block(Parser *parser, int *first);

static int parse_if_statement(Parser *parser) {
    if (parser->condition_count == MAX_CONDITIONS) {
        parse_error(parser, "too many `if` conditions in wasm32 Core");
        return -1;
    }
    int left = parse_expression(parser);
    if (left < 0) return -1;
    TokenKind comparison = parser->token.kind;
    switch (comparison) {
        case TOKEN_EQUAL_EQUAL:
        case TOKEN_BANG_EQUAL:
        case TOKEN_LESS:
        case TOKEN_LESS_EQUAL:
        case TOKEN_GREATER:
        case TOKEN_GREATER_EQUAL:
            break;
        default:
            parse_error(
                parser,
                "an `if` condition in wasm32 Core must compare two Int expressions"
            );
            return -1;
    }
    next_token(parser);
    int right = parse_expression(parser);
    if (right < 0) return -1;

    int condition = (int)parser->condition_count++;
    parser->conditions[condition] = (Condition){
        .comparison = comparison,
        .left = left,
        .right = right
    };

    int body = -1;
    if (!parse_block(parser, &body)) return -1;
    if (token_is(parser, "else")) {
        parse_error(parser, "wasm32 Core does not support `else`");
        return -1;
    }
    return add_statement(parser, (Statement){
        .kind = STATEMENT_IF,
        .expression = -1,
        .binding = -1,
        .condition = condition,
        .body = body,
        .next = -1
    });
}

static int parse_statement(Parser *parser) {
    if (consume_word(parser, "let")) return parse_binding_statement(parser);
    if (consume_word(parser, "print")) return parse_print_statement(parser);
    if (consume_word(parser, "return")) return parse_return_statement(parser);
    if (consume_word(parser, "if")) return parse_if_statement(parser);
    parse_error(
        parser,
        "wasm32 Core supports only `let`, `print`, `return`, and `if` statements"
    );
    return -1;
}

static bool parse_block(Parser *parser, int *first) {
    *first = -1;
    if (!expect(parser, TOKEN_LEFT_BRACE,
                "expected `{` before a wasm32 Core block")) {
        return false;
    }
    if (parser->block_nesting >= MAX_BLOCK_NESTING) {
        parse_error(parser, "block nesting exceeds the wasm32 limit of 64");
        return false;
    }
    ++parser->block_nesting;
    size_t scope = parser->binding_count;
    int last = -1;
    while (parser->error == NULL &&
           parser->token.kind != TOKEN_RIGHT_BRACE &&
           parser->token.kind != TOKEN_EOF) {
        int statement = parse_statement(parser);
        if (statement < 0) break;
        if (last < 0) {
            *first = statement;
        } else {
            parser->statements[last].next = statement;
        }
        last = statement;
    }
    /* A binding leaves scope with its block; the released slots are reused by
     * the next sibling block, and `local_slots` keeps the deepest frame. */
    parser->binding_count = scope;
    --parser->block_nesting;
    if (parser->error != NULL) return false;
    return expect(parser, TOKEN_RIGHT_BRACE,
                  "expected `}` after a wasm32 Core block");
}

/* Reads `fn name(...) -> Int` and stops on the opening `{`. The scan pass runs
 * it with `declare` false to fill the declaration table; the body pass runs it
 * again with `declare` true so each parameter becomes a local in source order
 * and a repeated name is caught. */
static bool parse_signature(Parser *parser, Function *function, bool declare) {
    if (!expect_word(parser, "fn",
                     "wasm32 Core supports only top-level `fn` declarations")) {
        return false;
    }
    if (parser->token.kind != TOKEN_IDENTIFIER) {
        parse_error(parser, "expected a function name after `fn`");
        return false;
    }
    const char *name = parser->token.start;
    size_t length = parser->token.length;
    if (length >= NAME_CAPACITY) {
        parse_error(parser, "function name is too long");
        return false;
    }
    if (length == 5 && memcmp(name, "print", 5) == 0) {
        parse_error(
            parser,
            "wasm32 Core reserves `print` and cannot declare it as a function"
        );
        return false;
    }
    memcpy(function->name, name, length);
    function->name[length] = '\0';
    function->name_length = length;
    function->line = parser->token.line;
    next_token(parser);

    if (!expect(parser, TOKEN_LEFT_PAREN,
                "expected `(` after the function name")) {
        return false;
    }
    function->parameter_count = 0;
    if (parser->token.kind != TOKEN_RIGHT_PAREN) {
        for (;;) {
            if (parser->token.kind != TOKEN_IDENTIFIER) {
                parse_error(parser, "expected a parameter name");
                return false;
            }
            if (function->parameter_count == MAX_PARAMETERS) {
                parse_error(
                    parser,
                    "wasm32 Core accepts at most six Int parameters"
                );
                return false;
            }
            const char *parameter = parser->token.start;
            size_t parameter_length = parser->token.length;
            next_token(parser);
            /*
             * `external internal: Int` — two names before the colon. The first
             * is the call-site label and the second is what the body binds, so
             * on seeing a second name the first is discarded here and the
             * binding is made from the internal one. A label is call-site
             * vocabulary only and must never become a lexical binding
             * (call-arguments v1, rule 4).
             *
             * The label itself is recorded by the caller's declaration pass;
             * this loop only has to stop treating the pair as a syntax error.
             */
            function->parameter_label_lengths[function->parameter_count] = 0;
            function->parameter_labels[function->parameter_count][0] = '\0';
            if (parser->token.kind == TOKEN_IDENTIFIER) {
                if (parameter_length >= NAME_CAPACITY) {
                    parse_error(parser, "wasm32 Core parameter label is too long");
                    return false;
                }
                memcpy(
                    function->parameter_labels[function->parameter_count],
                    parameter,
                    parameter_length
                );
                function->parameter_labels[
                    function->parameter_count
                ][parameter_length] = '\0';
                function->parameter_label_lengths[
                    function->parameter_count
                ] = parameter_length;
                parameter = parser->token.start;
                parameter_length = parser->token.length;
                next_token(parser);
            }
            if (declare &&
                !check_new_binding(parser, parameter, parameter_length,
                                   "duplicate parameter in wasm32 Core")) {
                return false;
            }
            if (!expect(parser, TOKEN_COLON,
                        "expected `:` after the parameter name")) {
                return false;
            }
            if (!expect_word(parser, "Int",
                             "wasm32 Core accepts only Int parameters")) {
                return false;
            }
            /*
             * An arrow directly after a parameter's type makes it a function
             * type — the shape a trailing lambda binds. The parameter list is
             * written correctly, so reporting the missing `)` here named the
             * one token that was not wrong.
             */
            if (parser->token.kind == TOKEN_ARROW) {
                parse_error(
                    parser,
                    "a function-typed parameter, which is what a trailing "
                    "lambda binds, is specified by call-arguments v1 but not "
                    "implemented by wasm32 Core"
                );
                return false;
            }
            if (declare) commit_binding(parser, parameter, parameter_length);
            ++function->parameter_count;
            if (!consume(parser, TOKEN_COMMA)) break;
        }
    }
    if (!expect(parser, TOKEN_RIGHT_PAREN,
                "expected `)` after the parameter list")) {
        return false;
    }
    if (consume(parser, TOKEN_ARROW)) {
        if (!expect_word(parser, "Int",
                         "wasm32 Core accepts only an Int function result")) {
            return false;
        }
        function->returns_int = true;
    }
    return true;
}

static bool skip_block(Parser *parser) {
    size_t depth = 1;
    while (depth > 0) {
        if (parser->error != NULL) return false;
        if (parser->token.kind == TOKEN_EOF) {
            parse_error(parser, "unterminated function body in wasm32 Core");
            return false;
        }
        if (parser->token.kind == TOKEN_LEFT_BRACE) {
            ++depth;
        } else if (parser->token.kind == TOKEN_RIGHT_BRACE) {
            --depth;
        }
        next_token(parser);
    }
    return true;
}

static bool scan_declarations(Parser *parser) {
    reset_lexer(parser);
    while (parser->error == NULL && parser->token.kind != TOKEN_EOF) {
        if (parser->function_count == MAX_FUNCTIONS) {
            parse_error(parser, "too many functions in wasm32 Core");
            return false;
        }
        Function function = {0};
        function.body = -1;
        if (!parse_signature(parser, &function, false)) return false;
        if (find_function(parser, function.name, function.name_length) >= 0) {
            parse_error_at(
                parser,
                "duplicate function declaration in wasm32 Core",
                function.line
            );
            return false;
        }
        parser->functions[parser->function_count++] = function;
        if (!expect(parser, TOKEN_LEFT_BRACE,
                    "expected `{` before the function body")) {
            return false;
        }
        if (!skip_block(parser)) return false;
    }
    if (parser->error != NULL) return false;

    parser->main_index = find_function(parser, "main", 4);
    if (parser->main_index < 0) {
        parse_error_at(parser, "wasm32 Core requires `fn main`", 1);
        return false;
    }
    const Function *entry = &parser->functions[parser->main_index];
    if (entry->parameter_count != 0) {
        parse_error_at(
            parser,
            "wasm32 Core requires `fn main` to declare no parameters",
            entry->line
        );
        return false;
    }
    for (size_t index = 0; index < parser->function_count; ++index) {
        const Function *function = &parser->functions[index];
        if (function->returns_int || (int)index == parser->main_index) continue;
        parse_error_at(
            parser,
            "wasm32 Core requires an `-> Int` result on every function other than `main`",
            function->line
        );
        return false;
    }
    return true;
}

static bool block_ends_with_return(const Parser *parser, int first) {
    int last = -1;
    for (int index = first; index >= 0;
         index = parser->statements[index].next) {
        last = index;
    }
    return last >= 0 && parser->statements[last].kind == STATEMENT_RETURN;
}

static bool parse_bodies(Parser *parser) {
    reset_lexer(parser);
    for (size_t index = 0; index < parser->function_count; ++index) {
        Function *function = &parser->functions[index];
        parser->current = (int)index;
        parser->binding_count = 0;
        function->local_slots = 0;

        Function header = {0};
        header.body = -1;
        if (!parse_signature(parser, &header, true)) return false;

        function->node_base = (int)parser->node_count;
        if (!parse_block(parser, &function->body)) return false;
        function->node_span = (int)parser->node_count - function->node_base;

        if (function->returns_int &&
            !block_ends_with_return(parser, function->body)) {
            parse_error_at(
                parser,
                "a wasm32 Core function declaring `-> Int` must end with `return`",
                function->line
            );
            return false;
        }
    }
    if (parser->token.kind != TOKEN_EOF) {
        parse_error(parser, "unexpected source after the last `fn` declaration");
        return false;
    }
    return parser->error == NULL;
}

static bool parse_program(Parser *parser, bool require_print) {
    parser->main_index = -1;
    parser->current = -1;
    if (!scan_declarations(parser)) return false;
    if (!parse_bodies(parser)) return false;
    if (require_print && parser->print_count == 0) {
        parse_error_at(
            parser,
            "wasm32 Core program must print at least one Int",
            parser->functions[parser->main_index].line
        );
        return false;
    }
    return parser->error == NULL;
}

enum {
    OP_UNREACHABLE = 0x00,
    OP_IF = 0x04,
    OP_END = 0x0b,
    OP_RETURN = 0x0f,
    OP_CALL = 0x10,
    OP_DROP = 0x1a,
    OP_LOCAL_GET = 0x20,
    OP_LOCAL_SET = 0x21,
    OP_GLOBAL_GET = 0x23,
    OP_GLOBAL_SET = 0x24,
    OP_I32_CONST = 0x41,
    OP_I64_CONST = 0x42,
    OP_I32_EQZ = 0x45,
    OP_I32_GT_U = 0x4b,
    OP_I32_LE_S = 0x4c,
    OP_I32_NE = 0x47,
    OP_I64_EQZ = 0x50,
    OP_I64_EQ = 0x51,
    OP_I64_NE = 0x52,
    OP_I64_LT_S = 0x53,
    OP_I64_GT_S = 0x55,
    OP_I64_LE_S = 0x57,
    OP_I64_GE_S = 0x59,
    OP_I32_AND = 0x71,
    OP_I32_OR = 0x72,
    OP_I32_ADD = 0x6a,
    OP_I32_SUB = 0x6b,
    OP_I64_ADD = 0x7c,
    OP_I64_SUB = 0x7d,
    OP_I64_MUL = 0x7e,
    OP_I64_DIV_S = 0x7f,
    OP_I64_REM_S = 0x81,
    OP_I64_AND = 0x83,
    OP_I64_XOR = 0x85
};

enum {
    ERROR_ADD_OVERFLOW = 1,
    ERROR_SUBTRACT_OVERFLOW = 2,
    ERROR_MULTIPLY_OVERFLOW = 3,
    ERROR_NEGATE_OVERFLOW = 4,
    ERROR_FLOOR_DIVIDE_ZERO = 5,
    ERROR_FLOOR_DIVIDE_OVERFLOW = 6,
    ERROR_MODULO_ZERO = 7
};

/* Module function indices start after the two host imports; the declaration
 * order in the table is the module order, so a call resolves the same whether
 * the callee is declared before or after the caller. */
enum {
    PRINT_INDEX = 0,
    PANIC_INDEX = 1,
    FUNCTION_INDEX_BASE = 2,
    TYPE_PRINT = 0,
    TYPE_PANIC = 1,
    TYPE_VOID = 2,
    TYPE_FIXED_COUNT = 3
};

typedef struct {
    /* Int-result arity -> type index, or -1 when this program has no function
     * of that arity. Only the used ones are emitted, so a program that is one
     * `fn main()` still emits exactly the three original types. */
    int int_result_type[MAX_PARAMETERS + 1];
    int type_count;
    bool needs_wrapper;
    uint32_t export_index;
} Layout;

typedef struct {
    const Parser *parser;
    const Function *function;
} Emitter;

static uint32_t node_local(const Emitter *emitter, int node) {
    return (uint32_t)(emitter->function->local_slots +
                      (node - emitter->function->node_base) * 3);
}

static uint32_t node_aux(const Emitter *emitter, int node, uint32_t offset) {
    return node_local(emitter, node) + offset;
}

static void instruction_index(Buffer *body, uint8_t opcode, uint32_t index) {
    byte(body, opcode);
    uleb(body, index);
}

static void i64_const(Buffer *body, int64_t value) {
    byte(body, OP_I64_CONST);
    sleb(body, value);
}

static void panic_with(Buffer *body, int code) {
    byte(body, OP_I32_CONST);
    sleb(body, code);
    instruction_index(body, OP_CALL, PANIC_INDEX);
    byte(body, OP_UNREACHABLE);
}

static void begin_if(Buffer *body) {
    byte(body, OP_IF);
    byte(body, 0x40);
}

static uint8_t comparison_opcode(TokenKind comparison) {
    switch (comparison) {
        case TOKEN_EQUAL_EQUAL:
            return OP_I64_EQ;
        case TOKEN_BANG_EQUAL:
            return OP_I64_NE;
        case TOKEN_LESS:
            return OP_I64_LT_S;
        case TOKEN_LESS_EQUAL:
            return OP_I64_LE_S;
        case TOKEN_GREATER:
            return OP_I64_GT_S;
        case TOKEN_GREATER_EQUAL:
            return OP_I64_GE_S;
        default:
            fatal("internal unsupported wasm32 comparison");
    }
    return OP_I64_EQ;
}

static void check_division_pair(
    Buffer *body,
    uint32_t left,
    uint32_t right,
    int zero_code,
    int overflow_code
) {
    instruction_index(body, OP_LOCAL_GET, right);
    byte(body, OP_I64_EQZ);
    begin_if(body);
    panic_with(body, zero_code);
    byte(body, OP_END);

    instruction_index(body, OP_LOCAL_GET, left);
    i64_const(body, INT64_MIN);
    byte(body, OP_I64_EQ);
    instruction_index(body, OP_LOCAL_GET, right);
    i64_const(body, -1);
    byte(body, OP_I64_EQ);
    byte(body, OP_I32_AND);
    begin_if(body);
    panic_with(body, overflow_code);
    byte(body, OP_END);
}

static void emit_expression(const Emitter *emitter, int index, Buffer *body) {
    const Parser *parser = emitter->parser;
    const Node *node = &parser->nodes[index];
    uint32_t target = node_local(emitter, index);
    if (node->kind == NODE_LITERAL) {
        i64_const(body, node->value);
        instruction_index(body, OP_LOCAL_SET, target);
        return;
    }
    if (node->kind == NODE_VARIABLE) {
        instruction_index(body, OP_LOCAL_GET, (uint32_t)node->binding);
        instruction_index(body, OP_LOCAL_SET, target);
        return;
    }
    if (node->kind == NODE_CALL) {
        /* Arguments are evaluated left to right and exactly once: each one
         * lands in its own local before any of them is pushed. */
        for (int written = 0; written < node->argument_count; ++written) {
            emit_expression(
                emitter,
                parser->arguments[
                    node->argument_start +
                    parser->argument_order[node->argument_start + written]
                ],
                body
            );
        }
        for (int argument = 0; argument < node->argument_count; ++argument) {
            instruction_index(
                body,
                OP_LOCAL_GET,
                node_local(
                    emitter,
                    parser->arguments[node->argument_start + argument]
                )
            );
        }
        instruction_index(
            body, OP_CALL,
            (uint32_t)(FUNCTION_INDEX_BASE + node->callee)
        );
        instruction_index(body, OP_LOCAL_SET, target);
        return;
    }

    emit_expression(emitter, node->left, body);
    uint32_t left = node_local(emitter, node->left);
    if (node->kind == NODE_NEGATE) {
        instruction_index(body, OP_LOCAL_GET, left);
        i64_const(body, INT64_MIN);
        byte(body, OP_I64_EQ);
        begin_if(body);
        panic_with(body, ERROR_NEGATE_OVERFLOW);
        byte(body, OP_END);
        i64_const(body, 0);
        instruction_index(body, OP_LOCAL_GET, left);
        byte(body, OP_I64_SUB);
        instruction_index(body, OP_LOCAL_SET, target);
        return;
    }

    emit_expression(emitter, node->right, body);
    uint32_t right = node_local(emitter, node->right);
    instruction_index(body, OP_LOCAL_GET, left);
    instruction_index(body, OP_LOCAL_GET, right);

    if (node->kind == NODE_ADD) {
        byte(body, OP_I64_ADD);
        instruction_index(body, OP_LOCAL_SET, target);
        instruction_index(body, OP_LOCAL_GET, left);
        instruction_index(body, OP_LOCAL_GET, target);
        byte(body, OP_I64_XOR);
        instruction_index(body, OP_LOCAL_GET, right);
        instruction_index(body, OP_LOCAL_GET, target);
        byte(body, OP_I64_XOR);
        byte(body, OP_I64_AND);
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        begin_if(body);
        panic_with(body, ERROR_ADD_OVERFLOW);
        byte(body, OP_END);
        return;
    }
    if (node->kind == NODE_SUBTRACT) {
        byte(body, OP_I64_SUB);
        instruction_index(body, OP_LOCAL_SET, target);
        instruction_index(body, OP_LOCAL_GET, left);
        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_XOR);
        instruction_index(body, OP_LOCAL_GET, left);
        instruction_index(body, OP_LOCAL_GET, target);
        byte(body, OP_I64_XOR);
        byte(body, OP_I64_AND);
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        begin_if(body);
        panic_with(body, ERROR_SUBTRACT_OVERFLOW);
        byte(body, OP_END);
        return;
    }
    if (node->kind == NODE_MULTIPLY) {
        byte(body, OP_I64_MUL);
        instruction_index(body, OP_LOCAL_SET, target);

        instruction_index(body, OP_LOCAL_GET, left);
        i64_const(body, -1);
        byte(body, OP_I64_EQ);
        instruction_index(body, OP_LOCAL_GET, right);
        i64_const(body, INT64_MIN);
        byte(body, OP_I64_EQ);
        byte(body, OP_I32_AND);
        instruction_index(body, OP_LOCAL_GET, right);
        i64_const(body, -1);
        byte(body, OP_I64_EQ);
        instruction_index(body, OP_LOCAL_GET, left);
        i64_const(body, INT64_MIN);
        byte(body, OP_I64_EQ);
        byte(body, OP_I32_AND);
        byte(body, OP_I32_OR);
        begin_if(body);
        panic_with(body, ERROR_MULTIPLY_OVERFLOW);
        byte(body, OP_END);

        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_EQZ);
        byte(body, OP_I32_EQZ);
        begin_if(body);
        instruction_index(body, OP_LOCAL_GET, target);
        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_DIV_S);
        instruction_index(body, OP_LOCAL_GET, left);
        byte(body, OP_I64_NE);
        begin_if(body);
        panic_with(body, ERROR_MULTIPLY_OVERFLOW);
        byte(body, OP_END);
        byte(body, OP_END);
        return;
    }
    if (node->kind == NODE_FLOOR_DIVIDE) {
        check_division_pair(
            body, left, right,
            ERROR_FLOOR_DIVIDE_ZERO,
            ERROR_FLOOR_DIVIDE_OVERFLOW
        );
        byte(body, OP_I64_DIV_S);
        instruction_index(body, OP_LOCAL_SET, target);
        instruction_index(body, OP_LOCAL_GET, left);
        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_REM_S);
        instruction_index(body, OP_LOCAL_SET, node_aux(emitter, index, 1));

        instruction_index(body, OP_LOCAL_GET, node_aux(emitter, index, 1));
        i64_const(body, 0);
        byte(body, OP_I64_NE);
        instruction_index(body, OP_LOCAL_GET, node_aux(emitter, index, 1));
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        instruction_index(body, OP_LOCAL_GET, right);
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        byte(body, OP_I32_NE);
        byte(body, OP_I32_AND);
        begin_if(body);
        instruction_index(body, OP_LOCAL_GET, target);
        i64_const(body, 1);
        byte(body, OP_I64_SUB);
        instruction_index(body, OP_LOCAL_SET, target);
        byte(body, OP_END);
        return;
    }
    if (node->kind == NODE_FLOOR_MODULO) {
        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_EQZ);
        begin_if(body);
        panic_with(body, ERROR_MODULO_ZERO);
        byte(body, OP_END);
        byte(body, OP_I64_REM_S);
        instruction_index(body, OP_LOCAL_SET, target);

        instruction_index(body, OP_LOCAL_GET, target);
        i64_const(body, 0);
        byte(body, OP_I64_NE);
        instruction_index(body, OP_LOCAL_GET, target);
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        instruction_index(body, OP_LOCAL_GET, right);
        i64_const(body, 0);
        byte(body, OP_I64_LT_S);
        byte(body, OP_I32_NE);
        byte(body, OP_I32_AND);
        begin_if(body);
        instruction_index(body, OP_LOCAL_GET, target);
        instruction_index(body, OP_LOCAL_GET, right);
        byte(body, OP_I64_ADD);
        instruction_index(body, OP_LOCAL_SET, target);
        byte(body, OP_END);
        return;
    }
    fatal("internal unsupported wasm32 expression");
}

static void emit_statements(const Emitter *emitter, int first, Buffer *body) {
    const Parser *parser = emitter->parser;
    for (int index = first; index >= 0;
         index = parser->statements[index].next) {
        const Statement *statement = &parser->statements[index];
        if (statement->kind == STATEMENT_IF) {
            const Condition *condition =
                &parser->conditions[statement->condition];
            emit_expression(emitter, condition->left, body);
            emit_expression(emitter, condition->right, body);
            instruction_index(
                body, OP_LOCAL_GET, node_local(emitter, condition->left)
            );
            instruction_index(
                body, OP_LOCAL_GET, node_local(emitter, condition->right)
            );
            byte(body, comparison_opcode(condition->comparison));
            begin_if(body);
            emit_statements(emitter, statement->body, body);
            byte(body, OP_END);
            continue;
        }
        if (statement->kind == STATEMENT_RETURN) {
            if (statement->expression >= 0) {
                emit_expression(emitter, statement->expression, body);
                instruction_index(
                    body, OP_LOCAL_GET,
                    node_local(emitter, statement->expression)
                );
            }
            byte(body, OP_RETURN);
            continue;
        }
        emit_expression(emitter, statement->expression, body);
        instruction_index(
            body, OP_LOCAL_GET, node_local(emitter, statement->expression)
        );
        if (statement->kind == STATEMENT_BIND) {
            instruction_index(
                body, OP_LOCAL_SET, (uint32_t)statement->binding
            );
        } else {
            instruction_index(body, OP_CALL, PRINT_INDEX);
        }
    }
}

static void plan_layout(const Parser *parser, Layout *layout) {
    for (int arity = 0; arity <= MAX_PARAMETERS; ++arity) {
        layout->int_result_type[arity] = -1;
    }
    layout->type_count = TYPE_FIXED_COUNT;
    for (size_t index = 0; index < parser->function_count; ++index) {
        const Function *function = &parser->functions[index];
        if (!function->returns_int) continue;
        layout->int_result_type[function->parameter_count] = 0;
    }
    for (int arity = 0; arity <= MAX_PARAMETERS; ++arity) {
        if (layout->int_result_type[arity] < 0) continue;
        layout->int_result_type[arity] = layout->type_count++;
    }
    /* A `main` that declares `-> Int` cannot be the export directly, because
     * the host ABI is `main(): void`. Only then is a wrapper emitted, so an
     * arithmetic-Core program keeps exporting its own single function. */
    layout->needs_wrapper = parser->functions[parser->main_index].returns_int;
    layout->export_index = (uint32_t)(
        FUNCTION_INDEX_BASE +
        (layout->needs_wrapper
             ? (int)parser->function_count
             : parser->main_index)
    );
}

static uint32_t function_type_index(
    const Layout *layout,
    const Function *function
) {
    if (!function->returns_int) return TYPE_VOID;
    return (uint32_t)layout->int_result_type[function->parameter_count];
}

static Buffer emit_function_body(
    const Parser *parser,
    const Function *function
) {
    Buffer body = {0};
    Emitter emitter = { .parser = parser, .function = function };
    uint64_t declared =
        (uint64_t)(function->local_slots - function->parameter_count) +
        (uint64_t)function->node_span * 3;
    if (declared == 0) {
        uleb(&body, 0);
    } else {
        uleb(&body, 1);
        uleb(&body, declared);
        byte(&body, 0x7e);
    }
    emit_statements(&emitter, function->body, &body);
    byte(&body, OP_END);
    return body;
}

static Buffer emit_module(const Parser *parser) {
    Layout layout;
    plan_layout(parser, &layout);

    Buffer module = {0};
    static const uint8_t header[] = {
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00
    };
    bytes(&module, header, sizeof(header));

    Buffer types = {0};
    uleb(&types, (uint64_t)layout.type_count);
    byte(&types, 0x60);
    uleb(&types, 1);
    byte(&types, 0x7e);
    uleb(&types, 0);
    byte(&types, 0x60);
    uleb(&types, 1);
    byte(&types, 0x7f);
    uleb(&types, 0);
    byte(&types, 0x60);
    uleb(&types, 0);
    uleb(&types, 0);
    for (int arity = 0; arity <= MAX_PARAMETERS; ++arity) {
        if (layout.int_result_type[arity] < 0) continue;
        byte(&types, 0x60);
        uleb(&types, (uint64_t)arity);
        for (int parameter = 0; parameter < arity; ++parameter) {
            byte(&types, 0x7e);
        }
        uleb(&types, 1);
        byte(&types, 0x7e);
    }
    section(&module, 1, &types);

    Buffer imports = {0};
    uleb(&imports, 2);
    wasm_string(&imports, "kofun");
    wasm_string(&imports, "print_i64");
    byte(&imports, 0x00);
    uleb(&imports, TYPE_PRINT);
    wasm_string(&imports, "kofun");
    wasm_string(&imports, "panic");
    byte(&imports, 0x00);
    uleb(&imports, TYPE_PANIC);
    section(&module, 2, &imports);

    uint64_t module_functions =
        parser->function_count + (layout.needs_wrapper ? 1 : 0);
    Buffer functions = {0};
    uleb(&functions, module_functions);
    for (size_t index = 0; index < parser->function_count; ++index) {
        uleb(&functions,
             function_type_index(&layout, &parser->functions[index]));
    }
    if (layout.needs_wrapper) uleb(&functions, TYPE_VOID);
    section(&module, 3, &functions);

    Buffer exports = {0};
    uleb(&exports, 1);
    wasm_string(&exports, "main");
    byte(&exports, 0x00);
    uleb(&exports, layout.export_index);
    section(&module, 7, &exports);

    Buffer code = {0};
    uleb(&code, module_functions);
    for (size_t index = 0; index < parser->function_count; ++index) {
        Buffer body = emit_function_body(parser, &parser->functions[index]);
        uleb(&code, body.length);
        bytes(&code, body.data, body.length);
        free(body.data);
    }
    if (layout.needs_wrapper) {
        Buffer wrapper = {0};
        uleb(&wrapper, 0);
        instruction_index(
            &wrapper, OP_CALL,
            (uint32_t)(FUNCTION_INDEX_BASE + parser->main_index)
        );
        byte(&wrapper, OP_DROP);
        byte(&wrapper, OP_END);
        uleb(&code, wrapper.length);
        bytes(&code, wrapper.data, wrapper.length);
        free(wrapper.data);
    }
    section(&module, 10, &code);

    free(types.data);
    free(imports.data);
    free(functions.data);
    free(exports.data);
    free(code.data);
    return module;
}

static void allocator_failure(Buffer *body) {
    byte(body, OP_I32_CONST);
    sleb(body, 0);
    byte(body, OP_RETURN);
}

static void reject_when(Buffer *body, uint8_t comparison) {
    byte(body, comparison);
    begin_if(body);
    allocator_failure(body);
    byte(body, OP_END);
}

/* Fixed, checked bump allocation:
 *
 *   aligned = (cursor + align - 1) & -align
 *   end     = aligned + size
 *
 * Inputs are bounded before either addition, so i32 wraparound cannot become
 * an apparently in-range address.  The cursor is published only after every
 * check succeeds; every refusal returns the ABI's null result without
 * changing memory or allocator state. */
static Buffer emit_profile_allocator_body(void) {
    enum { LOCAL_SIZE = 0, LOCAL_ALIGN = 1, LOCAL_ALIGNED = 2, LOCAL_END = 3 };
    Buffer body = {0};

    /* Two i32 locals: aligned and end. */
    uleb(&body, 1);
    uleb(&body, 2);
    byte(&body, 0x7f);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_SIZE);
    byte(&body, OP_I32_CONST);
    sleb(&body, 0);
    reject_when(&body, OP_I32_LE_S);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    byte(&body, OP_I32_CONST);
    sleb(&body, 0);
    reject_when(&body, OP_I32_LE_S);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_SIZE);
    byte(&body, OP_I32_CONST);
    sleb(&body, KOFUN_WASM_PAGE_BYTES);
    reject_when(&body, OP_I32_GT_U);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    byte(&body, OP_I32_CONST);
    sleb(&body, KOFUN_WASM_PAGE_BYTES);
    reject_when(&body, OP_I32_GT_U);

    /* align must be a power of two. */
    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    byte(&body, OP_I32_CONST);
    sleb(&body, 1);
    byte(&body, OP_I32_SUB);
    byte(&body, OP_I32_AND);
    begin_if(&body);
    allocator_failure(&body);
    byte(&body, OP_END);

    instruction_index(&body, OP_GLOBAL_GET, 1);
    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    byte(&body, OP_I32_CONST);
    sleb(&body, 1);
    byte(&body, OP_I32_SUB);
    byte(&body, OP_I32_ADD);
    byte(&body, OP_I32_CONST);
    sleb(&body, 0);
    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGN);
    byte(&body, OP_I32_SUB);
    byte(&body, OP_I32_AND);
    instruction_index(&body, OP_LOCAL_SET, LOCAL_ALIGNED);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGNED);
    instruction_index(&body, OP_LOCAL_GET, LOCAL_SIZE);
    byte(&body, OP_I32_ADD);
    instruction_index(&body, OP_LOCAL_SET, LOCAL_END);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_END);
    byte(&body, OP_I32_CONST);
    sleb(&body, KOFUN_WASM_PAGE_BYTES);
    reject_when(&body, OP_I32_GT_U);

    instruction_index(&body, OP_LOCAL_GET, LOCAL_END);
    instruction_index(&body, OP_GLOBAL_SET, 1);
    instruction_index(&body, OP_LOCAL_GET, LOCAL_ALIGNED);
    byte(&body, OP_END);
    return body;
}

#include "text_profile.h"
#include "list_profile.h"

static Buffer emit_profile_module(void) {
    Buffer module = {0};
    static const uint8_t header[] = {
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00
    };
    bytes(&module, header, sizeof(header));

    /* t0: (i32) -> (), t1: (i32, i32) -> i32. */
    Buffer types = {0};
    uleb(&types, 2);
    byte(&types, 0x60);
    uleb(&types, 1);
    byte(&types, 0x7f);
    uleb(&types, 0);
    byte(&types, 0x60);
    uleb(&types, 2);
    byte(&types, 0x7f);
    byte(&types, 0x7f);
    uleb(&types, 1);
    byte(&types, 0x7f);
    section(&module, 1, &types);

    Buffer functions = {0};
    uleb(&functions, 2);
    uleb(&functions, 0);
    uleb(&functions, 1);
    section(&module, 3, &functions);

    Buffer memory = {0};
    uleb(&memory, 1);
    byte(&memory, 0x01); /* min and max are present: the arena never grows. */
    uleb(&memory, 1);
    uleb(&memory, 1);
    section(&module, 5, &memory);

    Buffer globals = {0};
    uleb(&globals, 2);
    byte(&globals, 0x7f);
    byte(&globals, 0x00);
    byte(&globals, OP_I32_CONST);
    sleb(&globals, KOFUN_WASM_HOST_ABI_REVISION);
    byte(&globals, OP_END);
    byte(&globals, 0x7f);
    byte(&globals, 0x01);
    byte(&globals, OP_I32_CONST);
    sleb(&globals, KOFUN_WASM_ARENA_BASE);
    byte(&globals, OP_END);
    section(&module, 6, &globals);

    Buffer exports = {0};
    uleb(&exports, 4);
    wasm_string(&exports, "memory");
    byte(&exports, 0x02);
    uleb(&exports, 0);
    wasm_string(&exports, "kofun_abi_version");
    byte(&exports, 0x03);
    uleb(&exports, 0);
    wasm_string(&exports, "kofun_start");
    byte(&exports, 0x00);
    uleb(&exports, 0);
    wasm_string(&exports, "kofun_alloc");
    byte(&exports, 0x00);
    uleb(&exports, 1);
    section(&module, 7, &exports);

    Buffer code = {0};
    uleb(&code, 2);
    Buffer start = {0};
    uleb(&start, 0);
    byte(&start, OP_END);
    uleb(&code, start.length);
    bytes(&code, start.data, start.length);
    Buffer allocator = emit_profile_allocator_body();
    uleb(&code, allocator.length);
    bytes(&code, allocator.data, allocator.length);
    section(&module, 10, &code);

    free(types.data);
    free(functions.data);
    free(memory.data);
    free(globals.data);
    free(exports.data);
    free(start.data);
    free(allocator.data);
    free(code.data);
    return module;
}

static bool write_module(const char *path, const Buffer *module) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        fprintf(stderr, "kofun wasm32: cannot open output %s: %s\n",
                path, strerror(errno));
        return false;
    }
    bool okay =
        fwrite(module->data, 1, module->length, file) == module->length;
    if (fclose(file) != 0) okay = false;
    if (!okay) {
        remove(path);
        fprintf(stderr, "kofun wasm32: cannot write output %s\n", path);
    }
    return okay;
}

int main(int argc, char **argv) {
    bool profile = argc == 4 && strcmp(argv[1], "--hostabi1") == 0;
    if ((!profile && argc != 3) || (profile && argc != 4)) {
        fprintf(
            stderr,
            "usage: kofun-wasm-core [--hostabi1] INPUT.kofun OUTPUT.wasm\n"
        );
        return 2;
    }

    const char *input = argv[profile ? 2 : 1];
    const char *output = argv[profile ? 3 : 2];

    size_t length = 0;
    char *source = read_source(input, &length);
    if (source == NULL) return 1;
    if (profile && profile_source_uses_list(source, length)) {
        ListProfileParser *list_parser = allocate(sizeof(*list_parser));
        memset(list_parser, 0, sizeof(*list_parser));
        list_parser->source = source;
        list_parser->length = length;
        if (!list_profile_parse_program(list_parser)) {
            fprintf(stderr, "kofun wasm32: line %zu: %s\n",
                    list_parser->error_line,
                    list_parser->error == NULL
                        ? "invalid wasm32-hostabi1 List source"
                        : list_parser->error);
            free(list_parser);
            free(source);
            return 1;
        }
        Buffer profile_module = emit_profile_list_module(list_parser);
        bool profile_written = write_module(output, &profile_module);
        free(profile_module.data);
        free(list_parser);
        free(source);
        return profile_written ? 0 : 1;
    }
    if (profile) {
        ProfileParser *profile_parser = allocate(sizeof(*profile_parser));
        memset(profile_parser, 0, sizeof(*profile_parser));
        profile_parser->source = source;
        profile_parser->length = length;
        if (!profile_parse_program(profile_parser)) {
            fprintf(stderr, "kofun wasm32: line %zu: %s\n",
                    profile_parser->error_line,
                    profile_parser->error == NULL
                        ? "invalid wasm32-hostabi1 Text source"
                        : profile_parser->error);
            free(profile_parser);
            free(source);
            return 1;
        }
        Buffer profile_module = profile_program_is_empty(profile_parser)
            ? emit_profile_module()
            : emit_profile_text_module(profile_parser);
        bool profile_written = write_module(output, &profile_module);
        free(profile_module.data);
        free(profile_parser);
        free(source);
        return profile_written ? 0 : 1;
    }
    Parser *parser = allocate(sizeof(*parser));
    memset(parser, 0, sizeof(*parser));
    parser->source = source;
    parser->length = length;
    bool parsed = parse_program(parser, true);
    if (!parsed) {
        fprintf(stderr, "kofun wasm32: line %zu: %s\n",
                parser->error_line,
                parser->error == NULL ? "invalid source" : parser->error);
        free(parser);
        free(source);
        return 1;
    }

    Buffer module = emit_module(parser);
    bool written = write_module(output, &module);
    free(module.data);
    free(parser);
    free(source);
    return written ? 0 : 1;
}
