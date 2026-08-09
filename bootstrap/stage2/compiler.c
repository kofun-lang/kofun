/*
 * Audited executable seed for bootstrap/stage2/compiler.kofun.
 *
 * The Kofun file is canonical.  This C11 transliteration exists only until the
 * active Kofun bootstrap path can lower the complete Stage 2 source.
 */
#include <ctype.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "../../unicode/kofun_unicode.c"
/*
 * Included as source rather than linked, which is the pattern the Unicode
 * module above already sets. `compiler.c` is compiled standalone at thirty
 * call sites across the gates; a link dependency would have to be added to
 * every one of them, while an include leaves all thirty unchanged.
 */
#include "decimal_v1.c"

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} Buffer;

typedef struct {
    uint8_t kind;
    int64_t start;
    int64_t end;
} Stage2DiagnosticAffected;

typedef struct {
    int64_t start;
    int64_t end;
    char label[64];
} Stage2DiagnosticRelated;

typedef struct {
    uint32_t remedy_id;
    int64_t start;
    int64_t end;
    char replacement[64];
} Stage2DiagnosticEdit;

enum {
    STAGE2_DIAGNOSTIC_AFFECTED_MODULE = 1,
    STAGE2_DIAGNOSTIC_AFFECTED_ERROR_SPAN = 2,
    STAGE2_DIAGNOSTIC_AFFECTED_CALL = 3,
    STAGE2_DIAGNOSTIC_AFFECTED_BINDING = 4
};

typedef struct {
    bool present;
    bool has_byte_span;
    bool truncated;
    char code[16];
    char category[32];
    char template_id[64];
    int64_t start;
    int64_t end;
    char fallback[160];
    Stage2DiagnosticAffected affected[4];
    uint16_t affected_count;
    Stage2DiagnosticRelated related[4];
    uint16_t related_count;
    uint32_t remedies[4];
    uint16_t remedy_count;
    Stage2DiagnosticEdit edits[4];
    uint16_t edit_count;
} Stage2StructuredDiagnostic;

typedef struct {
    Stage2StructuredDiagnostic diagnostic;
} Stage2AuthorityContext;

typedef struct {
    char *program_ir;
    char *parse_prefix_ir;
    char *declaration_observations;
    char *scope_hir;
    char *scope_prefix_hir;
    char *semantic_observations;
    char *diagnostic;
    uint8_t exit_class;
    bool token_span_committed;
    bool parse_committed;
    bool scope_committed;
} Stage2AuthorityResult;

/* The lexer asks for the source length on every token query. Recomputing it
 * with strlen made each query linear in the whole file, so a pass that asks
 * once per token was quadratic in file size. The source of a pass is
 * immutable for that pass's lifetime, so one memo entry keyed on its address
 * answers every query; any other pointer falls back to strlen. */
static const char *source_length_text;
static int64_t source_length_value;

static int64_t source_length(const char *source) {
    /* The terminator check rejects a hit whose buffer was reused for longer
     * content at the same address, so a stale entry cannot make a caller scan
     * past the end of the string it was handed. */
    if (source == source_length_text &&
        source[source_length_value] == '\0') {
        return source_length_value;
    }
    source_length_text = source;
    source_length_value = (int64_t)strlen(source);
    return source_length_value;
}

static void *allocate(size_t size);
static void fail(const char *message);

/*
 * The audited seed is deliberately single-threaded.  This pointer is scoped
 * by the compiler-owned authority wrappers below and is never exposed to the
 * semantic sink.  Ordinary compiler commands leave it NULL.
 */
static Stage2AuthorityContext *stage2_active_authority_context;
static char **stage2_active_parse_prefix_output;
static char **stage2_active_scope_prefix_output;
static Buffer *stage2_active_semantic_observer;
static Buffer *stage2_active_declaration_observer;

static void stage2_parse_prefix_observe(const Buffer *ir) {
    char *copy;
    if (stage2_active_parse_prefix_output == NULL || ir == NULL) return;
    copy = allocate(ir->length + 1u);
    memcpy(copy, ir->data, ir->length);
    copy[ir->length] = '\0';
    free(*stage2_active_parse_prefix_output);
    *stage2_active_parse_prefix_output = copy;
}

static void stage2_scope_prefix_observe(const Buffer *hir) {
    char *copy;
    if (stage2_active_scope_prefix_output == NULL || hir == NULL) return;
    copy = allocate(hir->length + 1u);
    memcpy(copy, hir->data, hir->length);
    copy[hir->length] = '\0';
    free(*stage2_active_scope_prefix_output);
    *stage2_active_scope_prefix_output = copy;
}

static void stage2_diagnostic_set(
    const char *code,
    int64_t start,
    int64_t end,
    bool has_byte_span,
    const char *fallback
) {
    Stage2StructuredDiagnostic *diagnostic;
    int template_length;
    int fallback_length;
    if (stage2_active_authority_context == NULL) return;
    diagnostic = &stage2_active_authority_context->diagnostic;
    memset(diagnostic, 0, sizeof(*diagnostic));
    diagnostic->present = true;
    diagnostic->has_byte_span = has_byte_span;
    diagnostic->start = has_byte_span ? start : 0;
    diagnostic->end = has_byte_span ? end : 0;
    (void)snprintf(diagnostic->code, sizeof(diagnostic->code), "%s", code);
    (void)snprintf(
        diagnostic->category,
        sizeof(diagnostic->category),
        "%s",
        "stage2"
    );
    template_length = snprintf(
        diagnostic->template_id,
        sizeof(diagnostic->template_id),
        "stage2/%s",
        code
    );
    fallback_length = snprintf(
        diagnostic->fallback,
        sizeof(diagnostic->fallback),
        "%s",
        fallback
    );
    diagnostic->truncated =
        template_length < 0 ||
        template_length >= (int)sizeof(diagnostic->template_id) ||
        fallback_length < 0 ||
        fallback_length >= (int)sizeof(diagnostic->fallback);
    diagnostic->affected[0].kind = has_byte_span ?
        STAGE2_DIAGNOSTIC_AFFECTED_ERROR_SPAN :
        STAGE2_DIAGNOSTIC_AFFECTED_MODULE;
    diagnostic->affected[0].start = diagnostic->start;
    diagnostic->affected[0].end = diagnostic->end;
    diagnostic->affected_count = 1u;
}

static void stage2_diagnostic_affected(
    uint8_t kind,
    int64_t start,
    int64_t end
) {
    Stage2StructuredDiagnostic *diagnostic;
    if (stage2_active_authority_context == NULL) return;
    diagnostic = &stage2_active_authority_context->diagnostic;
    if (!diagnostic->present) return;
    diagnostic->affected[0].kind = kind;
    diagnostic->affected[0].start = start;
    diagnostic->affected[0].end = end;
    diagnostic->affected_count = 1u;
}

static void stage2_diagnostic_related(
    int64_t start,
    int64_t end,
    const char *label
) {
    Stage2StructuredDiagnostic *diagnostic;
    Stage2DiagnosticRelated *related;
    if (stage2_active_authority_context == NULL) return;
    diagnostic = &stage2_active_authority_context->diagnostic;
    if (!diagnostic->present ||
        diagnostic->related_count >=
            sizeof(diagnostic->related) / sizeof(diagnostic->related[0])) {
        return;
    }
    related = &diagnostic->related[diagnostic->related_count++];
    related->start = start;
    related->end = end;
    (void)snprintf(related->label, sizeof(related->label), "%s", label);
}

static void stage2_diagnostic_remedy(uint32_t remedy_id) {
    Stage2StructuredDiagnostic *diagnostic;
    if (stage2_active_authority_context == NULL) return;
    diagnostic = &stage2_active_authority_context->diagnostic;
    if (!diagnostic->present ||
        diagnostic->remedy_count >=
            sizeof(diagnostic->remedies) /
                sizeof(diagnostic->remedies[0])) {
        return;
    }
    diagnostic->remedies[diagnostic->remedy_count++] = remedy_id;
}

static void fail(const char *message) {
    fputs(message, stderr);
    fputc('\n', stderr);
    exit(2);
}

static void *allocate(size_t size) {
    void *value = malloc(size == 0 ? 1 : size);
    if (value == NULL) fail("stage2 seed: out of memory");
    return value;
}

static void buffer_init(Buffer *buffer) {
    buffer->capacity = 256;
    buffer->length = 0;
    buffer->data = allocate(buffer->capacity);
    buffer->data[0] = '\0';
}

static void buffer_reserve(Buffer *buffer, size_t extra) {
    size_t needed = buffer->length + extra + 1;
    if (needed <= buffer->capacity) return;
    size_t capacity = buffer->capacity;
    while (capacity < needed) capacity *= 2;
    char *data = realloc(buffer->data, capacity);
    if (data == NULL) fail("stage2 seed: out of memory");
    buffer->data = data;
    buffer->capacity = capacity;
}

static void buffer_append(Buffer *buffer, const char *text) {
    size_t length = strlen(text);
    buffer_reserve(buffer, length);
    memcpy(buffer->data + buffer->length, text, length + 1);
    buffer->length += length;
}

static void buffer_format(Buffer *buffer, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    va_list copy;
    va_copy(copy, arguments);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) fail("stage2 seed: formatting failed");
    buffer_reserve(buffer, (size_t)needed);
    (void)vsnprintf(
        buffer->data + buffer->length,
        buffer->capacity - buffer->length,
        format,
        arguments
    );
    va_end(arguments);
    buffer->length += (size_t)needed;
}

static void stage2_semantic_observe(const char *format, ...) {
    Buffer line;
    va_list arguments;
    va_list copy;
    int needed;
    if (stage2_active_semantic_observer == NULL || format == NULL) return;
    buffer_init(&line);
    va_start(arguments, format);
    va_copy(copy, arguments);
    needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(arguments);
        free(line.data);
        return;
    }
    buffer_reserve(&line, (size_t)needed);
    (void)vsnprintf(
        line.data,
        line.capacity,
        format,
        arguments
    );
    va_end(arguments);
    line.length = (size_t)needed;
    if (strstr(stage2_active_semantic_observer->data, line.data) == NULL) {
        buffer_append(stage2_active_semantic_observer, line.data);
    }
    free(line.data);
}

static void stage2_declaration_observe(const char *format, ...) {
    va_list arguments;
    if (stage2_active_declaration_observer == NULL || format == NULL) return;
    va_start(arguments, format);
    {
        va_list copy;
        int needed;
        va_copy(copy, arguments);
        needed = vsnprintf(NULL, 0, format, copy);
        va_end(copy);
        if (needed < 0) fail("stage2 seed: formatting failed");
        buffer_reserve(
            stage2_active_declaration_observer,
            (size_t)needed
        );
        (void)vsnprintf(
            stage2_active_declaration_observer->data +
                stage2_active_declaration_observer->length,
            stage2_active_declaration_observer->capacity -
                stage2_active_declaration_observer->length,
            format,
            arguments
        );
        stage2_active_declaration_observer->length += (size_t)needed;
    }
    va_end(arguments);
}

static char *read_file(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) fail("stage2 seed: cannot open input");
    if (fseek(file, 0, SEEK_END) != 0) fail("stage2 seed: cannot seek input");
    long position = ftell(file);
    if (position < 0) fail("stage2 seed: cannot size input");
    rewind(file);
    size_t size = (size_t)position;
    char *source = allocate(size + 1);
    if (fread(source, 1, size, file) != size) {
        fail("stage2 seed: cannot read input");
    }
    source[size] = '\0';
    if (fclose(file) != 0) fail("stage2 seed: cannot close input");
    return source;
}

static void write_file(const char *path, const char *value) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) fail("stage2 seed: cannot open output");
    size_t length = strlen(value);
    if (fwrite(value, 1, length, file) != length) {
        fail("stage2 seed: cannot write output");
    }
    if (fclose(file) != 0) fail("stage2 seed: cannot close output");
}

static bool same_file(const char *left, const char *right) {
    struct stat left_status;
    struct stat right_status;
    if (strcmp(left, right) == 0) return true;
    if (stat(left, &left_status) != 0 || stat(right, &right_status) != 0) {
        return false;
    }
    return left_status.st_dev == right_status.st_dev &&
           left_status.st_ino == right_status.st_ino;
}

static bool write_file_transactional(const char *path, const char *value) {
    size_t path_length = strlen(path);
    char *temporary = allocate(path_length + 40u);
    FILE *file = NULL;
    unsigned attempt;
    for (attempt = 0u; attempt < 100u; attempt += 1u) {
        (void)snprintf(
            temporary,
            path_length + 40u,
            "%s.kofun-tmp-%u",
            path,
            attempt
        );
        file = fopen(temporary, "wbx");
        if (file != NULL) break;
    }
    if (file == NULL) {
        free(temporary);
        return false;
    }
    size_t length = strlen(value);
    bool write_ok = fwrite(value, 1, length, file) == length;
    bool close_ok = fclose(file) == 0;
    if (!write_ok || !close_ok) {
        (void)remove(temporary);
        free(temporary);
        return false;
    }
    if (rename(temporary, path) != 0) {
        (void)remove(temporary);
        free(temporary);
        return false;
    }
    free(temporary);
    return true;
}

static bool identifier_start_at(
    const char *source,
    size_t length,
    int64_t offset,
    size_t *width
) {
    if (offset < 0 || (uint64_t)offset >= length) return false;
    uint32_t codepoint = 0;
    size_t scalar_width = 0;
    if (!kofun_unicode_decode(
            (const uint8_t *)source,
            length,
            (size_t)offset,
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
    int64_t offset,
    size_t *width
) {
    if (offset < 0 || (uint64_t)offset >= length) return false;
    uint32_t codepoint = 0;
    size_t scalar_width = 0;
    if (!kofun_unicode_decode(
            (const uint8_t *)source,
            length,
            (size_t)offset,
            &codepoint,
            &scalar_width)) {
        return false;
    }
    if (width != NULL) *width = scalar_width;
    return codepoint == '_' || kofun_unicode_is_xid_continue(codepoint);
}

static int64_t skip_trivia(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = start;
    while (cursor < length) {
        unsigned char symbol = (unsigned char)source[cursor];
        if (isspace(symbol)) {
            ++cursor;
        } else if (source[cursor] == '#') {
            while (cursor < length && source[cursor] != '\n') ++cursor;
        } else {
            return cursor;
        }
    }
    return cursor;
}

static int64_t string_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = start + 1;
    bool escaped = false;
    while (cursor < length) {
        char symbol = source[cursor];
        if (escaped) {
            escaped = false;
        } else if (symbol == '\\') {
            escaped = true;
        } else if (symbol == '"') {
            return cursor + 1;
        } else if (symbol == '\n') {
            return -1;
        }
        ++cursor;
    }
    return -1;
}

static bool pair_token(const char *source, int64_t start) {
    static const char *pairs[] = {
        "->", "==", "!=", "<=", ">=", "&&", "||",
        "//", "..", "**", "??", "|>", "=>"
    };
    char pair[3] = {source[start], source[start + 1], '\0'};
    size_t count = sizeof(pairs) / sizeof(pairs[0]);
    for (size_t index = 0; index < count; ++index) {
        if (strcmp(pair, pairs[index]) == 0) return true;
    }
    return false;
}

static int64_t token_end_uncached(const char *source, int64_t start) {
    int64_t length = source_length(source);
    if (start >= length) return start;
    char first = source[start];
    if (first == '"') return string_end(source, start);
    size_t first_width = 0;
    if (identifier_start_at(
            source,
            (size_t)length,
            start,
            &first_width)) {
        int64_t cursor = start + (int64_t)first_width;
        while (cursor < length) {
            size_t width = 0;
            if (!identifier_continue_at(
                    source,
                    (size_t)length,
                    cursor,
                    &width)) {
                break;
            }
            cursor += (int64_t)width;
        }
        return cursor;
    }
    int64_t cursor = start + 1;
    if (first >= '0' && first <= '9') {
        while (
            cursor < length &&
            ((source[cursor] >= '0' && source[cursor] <= '9') ||
             source[cursor] == '_')
        ) {
            ++cursor;
        }
        /* docs/DECIMAL.md: maximal munch with the range exception. A fraction
         * needs a digit after the point, so `1..2` stays Int(1), `..`, Int(2)
         * and `1.` stays Int(1) followed by `.`. */
        if (cursor + 1 < length &&
            source[cursor] == '.' &&
            source[cursor + 1] >= '0' && source[cursor + 1] <= '9') {
            ++cursor;
            while (
                cursor < length &&
                ((source[cursor] >= '0' && source[cursor] <= '9') ||
                 source[cursor] == '_')
            ) {
                ++cursor;
            }
        }
        /* An exponent is only part of the token when digits actually follow,
         * so `1e` remains Int(1) followed by the identifier `e`. */
        if (cursor < length &&
            (source[cursor] == 'e' || source[cursor] == 'E')) {
            int64_t probe = cursor + 1;
            if (probe < length &&
                (source[probe] == '+' || source[probe] == '-')) {
                ++probe;
            }
            if (probe < length &&
                source[probe] >= '0' && source[probe] <= '9') {
                cursor = probe;
                while (
                    cursor < length &&
                    ((source[cursor] >= '0' && source[cursor] <= '9') ||
                     source[cursor] == '_')
                ) {
                    ++cursor;
                }
            }
        }
        /* `f64` is part of the numeric token, not an identifier. */
        if (cursor + 3 <= length &&
            source[cursor] == 'f' &&
            source[cursor + 1] == '6' &&
            source[cursor + 2] == '4') {
            cursor += 3;
        }
        return cursor;
    }
    if (cursor < length && pair_token(source, start)) return cursor + 1;
    return cursor;
}

/* token_end is a pure function of (source, offset) and the scope-HIR walker
 * asks for the same offsets millions of times. One table per source turns the
 * repeat queries into a load. Entries store value + 1 so the zero pages a
 * calloc arrives with mean "unknown", and only queried offsets are ever
 * touched; the table is rebuilt whenever the source or its length changes,
 * and a query outside the table falls back to the scan. */
static const char *token_end_memo_source;
static int64_t token_end_memo_length;
static int64_t *token_end_memo;

static int64_t token_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    if (source != token_end_memo_source || length != token_end_memo_length) {
        free(token_end_memo);
        token_end_memo = calloc((size_t)length + 1, sizeof(int64_t));
        if (token_end_memo == NULL) fail("stage2 seed: out of memory");
        token_end_memo_source = source;
        token_end_memo_length = length;
    }
    if (start < 0 || start > length) return token_end_uncached(source, start);
    if (token_end_memo[start] != 0) return token_end_memo[start] - 1;
    int64_t value = token_end_uncached(source, start);
    token_end_memo[start] = value + 1;
    return value;
}

static bool token_equal(const char *source, int64_t start, const char *expected) {
    int64_t end = token_end(source, start);
    size_t length = strlen(expected);
    return end >= start &&
           (size_t)(end - start) == length &&
           strncmp(source + start, expected, length) == 0;
}

static char *token_copy(const char *source, int64_t start) {
    int64_t end = token_end(source, start);
    if (end < start) {
        char *empty = allocate(1);
        empty[0] = '\0';
        return empty;
    }
    size_t length = (size_t)(end - start);
    char *result = allocate(length + 1);
    memcpy(result, source + start, length);
    result[length] = '\0';
    return result;
}

static bool keyword_token(const char *source, int64_t start) {
    static const char *keywords[] = {
        "fn", "let", "mut", "return", "if", "else", "while", "for",
        "in", "break", "continue", "true", "false", "match", "type",
        "par"
    };
    size_t count = sizeof(keywords) / sizeof(keywords[0]);
    for (size_t index = 0; index < count; ++index) {
        if (token_equal(source, start, keywords[index])) return true;
    }
    return false;
}

static const char *token_kind(const char *source, int64_t start) {
    int64_t end = token_end(source, start);
    if (end <= start) return "invalid";
    char first = source[start];
    if (first == '"') return "string";
    if (identifier_start_at(
            source,
            (size_t)source_length(source),
            start,
            NULL)) {
        return keyword_token(source, start) ? "keyword" : "identifier";
    }
    if (first >= '0' && first <= '9') {
        /* An unsuffixed fractional or scientific literal denotes Decimal; the
         * `f64` suffix selects binary64 Float (docs/DECIMAL.md). Neither has a
         * representation yet — the kinds exist so the token contract can be
         * gated and so a backend refuses them explicitly (#717). */
        if (end - start >= 3 &&
            source[end - 3] == 'f' &&
            source[end - 2] == '6' &&
            source[end - 1] == '4') {
            return "float";
        }
        for (int64_t scan = start; scan < end; ++scan) {
            if (source[scan] == '.' ||
                source[scan] == 'e' ||
                source[scan] == 'E') {
                return "decimal";
            }
        }
        return "integer";
    }
    return "punctuation";
}

static int64_t line_at(const char *source, int64_t target) {
    int64_t line = 1;
    for (int64_t cursor = 0; cursor < target && source[cursor] != '\0'; ++cursor) {
        if (source[cursor] == '\n') ++line;
    }
    return line;
}

/*
 * Why the malformed forms are diagnosed here rather than in `token_end`, and
 * what "malformed" means for each of them.
 *
 * `token_end` is deliberately permissive about `.`: a fraction needs a digit
 * after the point, so `1..2` stays `Int`, `..`, `Int` and `1.` stays `Int`
 * followed by the point. Tightening the scanner instead would have to decide
 * between the range operator and a fraction with one character of lookahead,
 * which is the collision `docs/DECIMAL.md` states the range exception exists
 * to avoid. So the scanner keeps producing tokens and this pass reads the
 * result, where `..` and a lone `.` are already distinct tokens.
 *
 * The rules, all measured against `docs/DECIMAL.md:97-118`:
 *
 * - a numeric token immediately followed by an identifier character is one
 *   malformed literal, not a literal beside a name. This is what makes `1e`,
 *   `1e+`, `1.0e` and `1._0` errors, and it is also why `42f64` is one token
 *   while `42 f64` is two: the suffix joins only without a gap.
 * - a numeric token immediately followed by a lone `.` is `1.`, a fraction
 *   with no digits. A following `..` is the range operator and is left alone.
 * - a lone `.` immediately followed by a digit is `.5`, a fraction with no
 *   integer part.
 * - `_` must sit between two digits, so `1_`, `1.0_` and `1_.0` are errors
 *   while `1_000.000_1` is not.
 *
 * `_1` is absent on purpose. It is a well-formed identifier under the
 * identifier grammar, not a numeric literal, and it already reports as an
 * unknown binding at its own byte. Making it lexical here would ban an
 * identifier spelling on the strength of a rule about numbers.
 */
static bool numeric_digit(char symbol) {
    return symbol >= '0' && symbol <= '9';
}

static bool numeric_underscore_error(
    const char *source,
    int64_t start,
    int64_t end
) {
    for (int64_t cursor = start; cursor < end; ++cursor) {
        if (source[cursor] != '_') continue;
        if (cursor == start || cursor + 1 >= end) return true;
        if (
            !numeric_digit(source[cursor - 1]) ||
            !numeric_digit(source[cursor + 1])
        ) {
            return true;
        }
    }
    return false;
}

static bool malformed_numeric_literal(
    const char *source,
    int64_t start,
    int64_t end
) {
    int64_t length = source_length(source);
    const char *kind = token_kind(source, start);
    if (
        strcmp(kind, "integer") == 0 ||
        strcmp(kind, "decimal") == 0 ||
        strcmp(kind, "float") == 0
    ) {
        if (numeric_underscore_error(source, start, end)) return true;
        if (end < length && identifier_start_at(source, (size_t)length, end, NULL)) {
            return true;
        }
        if (end < length && source[end] == '.') {
            return end + 1 >= length || source[end + 1] != '.';
        }
        return false;
    }
    /* A lone `.` — `..` lexes as one two-character token, so a
     * one-character `.` token here is never the range operator. */
    if (end == start + 1 && source[start] == '.') {
        return end < length && numeric_digit(source[end]);
    }
    return false;
}

static char *lex_source(const char *source) {
    Buffer tape;
    buffer_init(&tape);
    KofunUnicodeError unicode_error;
    if (!kofun_unicode_validate_source(
            (const uint8_t *)source,
            (size_t)source_length(source),
            &unicode_error)) {
        char message[1024];
        kofun_unicode_format_error(
            &unicode_error,
            getenv("KOFUN_DIAGNOSTIC_LOCALE"),
            message,
            sizeof(message)
        );
        buffer_append(&tape, message);
        stage2_diagnostic_set(
            kofun_unicode_error_code(unicode_error.status),
            (int64_t)unicode_error.byte_offset,
            (int64_t)unicode_error.byte_offset,
            unicode_error.status != KOFUN_UNICODE_OUT_OF_MEMORY,
            tape.data
        );
        return tape.data;
    }
    buffer_append(&tape, "kofun-token-tape/v1\n");
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        int64_t end = token_end(source, cursor);
        if (end <= cursor) {
            tape.length = 0;
            tape.data[0] = '\0';
            buffer_format(
                &tape,
                "error[E2S01]: unterminated string at byte %" PRId64,
                cursor
            );
            stage2_diagnostic_set(
                "E2S01",
                cursor,
                length,
                true,
                tape.data
            );
            return tape.data;
        }
        if (malformed_numeric_literal(source, cursor, end)) {
            tape.length = 0;
            tape.data[0] = '\0';
            buffer_format(
                &tape,
                "error[E2S98]: malformed numeric literal at byte %" PRId64
                "; `.` and an exponent need digits, and `_` must sit between "
                "two digits",
                cursor
            );
            stage2_diagnostic_set(
                "E2S98",
                cursor,
                end,
                true,
                tape.data
            );
            return tape.data;
        }
        buffer_format(
            &tape,
            "%s|%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
            token_kind(source, cursor),
            cursor,
            end,
            line_at(source, cursor)
        );
        cursor = skip_trivia(source, end);
    }
    return tape.data;
}

static int64_t balanced_end(
    const char *source,
    int64_t start,
    const char *open,
    const char *close
);
static char *owned_text(const char *text);

/*
 * General patterns are a syntax-only boundary.  The executable Core below
 * still implements only Bool and payload-free enum matching, but both paths
 * classify their arm heads through this parser instead of interpreting the
 * first token themselves.
 *
 * Node records are post-order: child ids are known before their owning node is
 * written.  Delimiter records use the owner's source start, which is unique
 * inside a match, so comma and `|` spans remain available even before the
 * owner id is allocated.
 */
#define PATTERN_DEPTH_LIMIT 32
#define PATTERN_NODE_LIMIT 256

typedef enum {
    PATTERN_WILDCARD,
    PATTERN_LITERAL,
    PATTERN_NAME,
    PATTERN_CONSTRUCTOR,
    PATTERN_OR,
    PATTERN_PARENTHESIZED,
    PATTERN_ERROR
} PatternKind;

typedef struct {
    const char *source;
    int64_t next_node_id;
    int64_t nodes;
    int64_t errors;
    int64_t limit_error_id;
} PatternParser;

typedef struct {
    int64_t end;
    int64_t root;
    PatternKind kind;
    bool fatal;
    Buffer records;
} ParsedPattern;

typedef struct {
    int64_t end;
    PatternKind kind;
} PatternSummary;

static ParsedPattern parse_pattern_or(
    PatternParser *parser,
    int64_t start,
    int64_t depth
);
static PatternSummary pattern_summary(const char *source, int64_t start);
static char *enum_constructor_owner(const char *source, const char *name);
static bool enum_binding_catchall_name(const char *name);

static ParsedPattern parsed_pattern_init(int64_t start) {
    ParsedPattern result;
    result.end = start;
    result.root = -1;
    result.kind = PATTERN_ERROR;
    result.fatal = false;
    buffer_init(&result.records);
    return result;
}

static int64_t pattern_recovery_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    int64_t paren_depth = 0;
    int64_t bracket_depth = 0;
    while (cursor < length) {
        if (token_equal(source, cursor, "=>")) return cursor;
        if (token_equal(source, cursor, "{") && paren_depth == 0 &&
            bracket_depth == 0) {
            return cursor;
        }
        if (token_equal(source, cursor, "}") && paren_depth == 0 &&
            bracket_depth == 0) {
            return cursor;
        }
        if (token_equal(source, cursor, ",") && paren_depth == 0 &&
            bracket_depth == 0) {
            return cursor;
        }
        if (token_equal(source, cursor, "(")) {
            ++paren_depth;
        } else if (token_equal(source, cursor, ")")) {
            if (paren_depth == 0) return cursor;
            --paren_depth;
        } else if (token_equal(source, cursor, "[")) {
            ++bracket_depth;
        } else if (token_equal(source, cursor, "]")) {
            if (bracket_depth == 0) return cursor;
            --bracket_depth;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return cursor;
}

static ParsedPattern pattern_error(
    PatternParser *parser,
    int64_t start,
    int64_t end,
    const char *reason,
    bool fatal
) {
    ParsedPattern result = parsed_pattern_init(end);
    if (end < start) end = start;
    if (parser->nodes >= PATTERN_NODE_LIMIT) {
        result.fatal = true;
        return result;
    }
    int64_t id = parser->next_node_id++;
    ++parser->nodes;
    ++parser->errors;
    result.root = id;
    result.kind = PATTERN_ERROR;
    result.fatal = fatal;
    buffer_format(
        &result.records,
        "node|%" PRId64 "|ErrorPattern|%" PRId64 "|%" PRId64
        "|%s\n"
        "pattern-diagnostic|E2S58|%s|%" PRId64 "|%" PRId64 "\n",
        id,
        start,
        end,
        reason,
        reason,
        start,
        end
    );
    return result;
}

static ParsedPattern pattern_limit_error(
    PatternParser *parser,
    int64_t start
) {
    int64_t end = token_end(parser->source, start);
    if (end < start) end = start;
    ParsedPattern result = parsed_pattern_init(end);
    result.fatal = true;
    if (parser->limit_error_id >= 0) {
        result.root = parser->limit_error_id;
        return result;
    }
    int64_t id = parser->next_node_id++;
    parser->limit_error_id = id;
    ++parser->errors;
    result.root = id;
    buffer_format(
        &result.records,
        "node|%" PRId64 "|ErrorPattern|%" PRId64 "|%" PRId64
        "|node-limit\n"
        "pattern-diagnostic|E2S58|node-limit|%" PRId64 "|%" PRId64
        "\n",
        id,
        start,
        end,
        start,
        end
    );
    return result;
}

static bool pattern_node_available(const PatternParser *parser) {
    return parser->nodes < PATTERN_NODE_LIMIT;
}

static void pattern_append_child(Buffer *children, int64_t child) {
    if (children->length > 0) buffer_append(children, ",");
    buffer_format(children, "%" PRId64, child);
}

static bool pattern_stop_token(const char *source, int64_t start) {
    int64_t length = source_length(source);
    return start >= length || token_equal(source, start, "=>") ||
           token_equal(source, start, ",") ||
           token_equal(source, start, ")") ||
           token_equal(source, start, "}") ||
           token_equal(source, start, "if");
}

static ParsedPattern parse_pattern_atomic(
    PatternParser *parser,
    int64_t start,
    int64_t depth
) {
    const char *source = parser->source;
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    int64_t checkpoint_node_id = parser->next_node_id;
    int64_t checkpoint_nodes = parser->nodes;
    int64_t checkpoint_errors = parser->errors;
    int64_t checkpoint_limit_error_id = parser->limit_error_id;
    if (!pattern_node_available(parser)) {
        return pattern_limit_error(parser, cursor);
    }
    if (depth > PATTERN_DEPTH_LIMIT) {
        int64_t recovered = pattern_recovery_end(source, cursor);
        return pattern_error(
            parser,
            cursor,
            recovered,
            "depth-limit",
            false
        );
    }
    if (cursor >= length || pattern_stop_token(source, cursor) ||
        token_equal(source, cursor, "|")) {
        int64_t end = cursor < length ? token_end(source, cursor) : cursor;
        return pattern_error(
            parser,
            cursor,
            end,
            "missing-pattern",
            false
        );
    }

    int64_t token_finish = token_end(source, cursor);
    if (token_equal(source, cursor, "{")) {
        int64_t close = balanced_end(source, cursor, "{", "}");
        int64_t end = close < 0 ? pattern_recovery_end(source, cursor) : close;
        return pattern_error(
            parser,
            cursor,
            end,
            "unsupported-record-pattern",
            false
        );
    }
    if (token_equal(source, cursor, "[") ||
        token_equal(source, cursor, "..")) {
        int64_t end = pattern_recovery_end(source, token_finish);
        if (end == token_finish) end = token_finish;
        return pattern_error(
            parser,
            cursor,
            end,
            token_equal(source, cursor, "..") ?
                "unsupported-rest-pattern" : "unsupported-pattern-token",
            false
        );
    }

    if (token_equal(source, cursor, "(")) {
        int64_t inner_start = skip_trivia(source, token_finish);
        ParsedPattern inner = parse_pattern_or(
            parser,
            inner_start,
            depth + 1
        );
        if (inner.fatal) return inner;
        int64_t close = skip_trivia(source, inner.end);
        if (close >= length || !token_equal(source, close, ")")) {
            int64_t recovered = pattern_recovery_end(source, close);
            free(inner.records.data);
            parser->next_node_id = checkpoint_node_id;
            parser->nodes = checkpoint_nodes;
            parser->errors = checkpoint_errors;
            parser->limit_error_id = checkpoint_limit_error_id;
            return pattern_error(
                parser,
                cursor,
                recovered,
                "missing-closing-parenthesis",
                false
            );
        }
        if (!pattern_node_available(parser)) {
            free(inner.records.data);
            return pattern_limit_error(parser, cursor);
        }
        ParsedPattern result = parsed_pattern_init(token_end(source, close));
        buffer_append(&result.records, inner.records.data);
        free(inner.records.data);
        int64_t id = parser->next_node_id++;
        ++parser->nodes;
        result.root = id;
        result.kind = PATTERN_PARENTHESIZED;
        buffer_format(
            &result.records,
            "node|%" PRId64 "|ParenthesizedPattern|%" PRId64
            "|%" PRId64 "|%" PRId64 "|%" PRId64 "|%" PRId64
            "|%" PRId64 "|%" PRId64 "\n",
            id,
            cursor,
            result.end,
            cursor,
            token_finish,
            close,
            token_end(source, close),
            inner.root
        );
        return result;
    }

    const char *kind = token_kind(source, cursor);
    bool literal = token_equal(source, cursor, "true") ||
                   token_equal(source, cursor, "false") ||
                   token_equal(source, cursor, "null") ||
                   strcmp(kind, "integer") == 0;
    if (token_equal(source, cursor, "_")) {
        ParsedPattern result = parsed_pattern_init(token_finish);
        int64_t id = parser->next_node_id++;
        ++parser->nodes;
        result.root = id;
        result.kind = PATTERN_WILDCARD;
        buffer_format(
            &result.records,
            "node|%" PRId64 "|WildcardPattern|%" PRId64 "|%" PRId64
            "\n",
            id,
            cursor,
            token_finish
        );
        return result;
    }
    if (literal) {
        ParsedPattern result = parsed_pattern_init(token_finish);
        int64_t id = parser->next_node_id++;
        ++parser->nodes;
        result.root = id;
        result.kind = PATTERN_LITERAL;
        const char *literal_kind = strcmp(kind, "integer") == 0 ?
            "Int" : (token_equal(source, cursor, "null") ? "Null" : "Bool");
        char *literal_token = token_copy(source, cursor);
        buffer_format(
            &result.records,
            "node|%" PRId64 "|LiteralPattern|%" PRId64 "|%" PRId64
            "|%s|%s|%" PRId64 "|%" PRId64 "\n",
            id,
            cursor,
            token_finish,
            literal_kind,
            literal_token,
            cursor,
            token_finish
        );
        free(literal_token);
        return result;
    }
    if (strcmp(kind, "identifier") != 0) {
        int64_t recovered = pattern_recovery_end(source, token_finish);
        if (recovered == token_finish) recovered = token_finish;
        return pattern_error(
            parser,
            cursor,
            recovered,
            "unsupported-pattern-token",
            false
        );
    }

    int64_t after_name = skip_trivia(source, token_finish);
    if (after_name < length && token_equal(source, after_name, "{")) {
        int64_t close = balanced_end(source, after_name, "{", "}");
        int64_t end = close < 0 ? pattern_recovery_end(source, after_name) : close;
        return pattern_error(
            parser,
            cursor,
            end,
            "unsupported-record-pattern",
            false
        );
    }
    if (after_name >= length || !token_equal(source, after_name, "(")) {
        ParsedPattern result = parsed_pattern_init(token_finish);
        int64_t id = parser->next_node_id++;
        ++parser->nodes;
        result.root = id;
        result.kind = PATTERN_NAME;
        char *name = token_copy(source, cursor);
        buffer_format(
            &result.records,
            "node|%" PRId64 "|NamePattern|%" PRId64 "|%" PRId64
            "|%s|%" PRId64 "|%" PRId64 "\n",
            id,
            cursor,
            token_finish,
            name,
            cursor,
            token_finish
        );
        free(name);
        return result;
    }

    Buffer records;
    Buffer children;
    buffer_init(&records);
    buffer_init(&children);
    int64_t open = after_name;
    int64_t payload = skip_trivia(source, token_end(source, open));
    int64_t payload_count = 0;
    int64_t close = -1;
    if (payload < length && token_equal(source, payload, ")")) {
        free(records.data);
        free(children.data);
        return pattern_error(
            parser,
            cursor,
            token_end(source, payload),
            "empty-constructor-payload",
            false
        );
    } else {
        while (payload < length) {
            ParsedPattern child = parse_pattern_or(
                parser,
                payload,
                depth + 1
            );
            if (child.fatal) {
                free(records.data);
                free(children.data);
                return child;
            }
            buffer_append(&records, child.records.data);
            free(child.records.data);
            pattern_append_child(&children, child.root);
            ++payload_count;
            int64_t separator = skip_trivia(source, child.end);
            if (separator < length && token_equal(source, separator, ",")) {
                buffer_format(
                    &records,
                    "delimiter|ConstructorPattern|%" PRId64
                    "|payload-comma|%" PRId64 "|%" PRId64
                    "|%" PRId64 "\n",
                    cursor,
                    payload_count - 1,
                    separator,
                    token_end(source, separator)
                );
                payload = skip_trivia(source, token_end(source, separator));
                if (payload < length && token_equal(source, payload, ")")) {
                    close = payload;
                    break;
                }
                continue;
            }
            if (separator < length && token_equal(source, separator, ")")) {
                close = separator;
                break;
            }
            int64_t recovered = pattern_recovery_end(source, separator);
            if (recovered < length && token_equal(source, recovered, ")")) {
                recovered = token_end(source, recovered);
            }
            free(records.data);
            free(children.data);
            parser->next_node_id = checkpoint_node_id;
            parser->nodes = checkpoint_nodes;
            parser->errors = checkpoint_errors;
            parser->limit_error_id = checkpoint_limit_error_id;
            return pattern_error(
                parser,
                cursor,
                recovered,
                pattern_stop_token(source, separator) ?
                    "missing-closing-parenthesis" : "missing-comma",
                false
            );
        }
    }
    if (close < 0) {
        int64_t recovered = pattern_recovery_end(source, payload);
        free(records.data);
        free(children.data);
        parser->next_node_id = checkpoint_node_id;
        parser->nodes = checkpoint_nodes;
        parser->errors = checkpoint_errors;
        parser->limit_error_id = checkpoint_limit_error_id;
        return pattern_error(
            parser,
            cursor,
            recovered,
            "missing-closing-parenthesis",
            false
        );
    }
    if (!pattern_node_available(parser)) {
        free(records.data);
        free(children.data);
        return pattern_limit_error(parser, cursor);
    }
    ParsedPattern result = parsed_pattern_init(token_end(source, close));
    free(result.records.data);
    result.records = records;
    int64_t id = parser->next_node_id++;
    ++parser->nodes;
    result.root = id;
    result.kind = PATTERN_CONSTRUCTOR;
    char *name = token_copy(source, cursor);
    buffer_format(
        &result.records,
        "node|%" PRId64 "|ConstructorPattern|%" PRId64 "|%" PRId64
        "|%s|%" PRId64 "|%" PRId64 "|%" PRId64 "|%" PRId64
        "|%" PRId64 "|%" PRId64 "|%" PRId64 "|%s\n",
        id,
        cursor,
        result.end,
        name,
        cursor,
        token_finish,
        open,
        token_end(source, open),
        close,
        token_end(source, close),
        payload_count,
        children.data
    );
    free(name);
    free(children.data);
    return result;
}

static ParsedPattern parse_pattern_or(
    PatternParser *parser,
    int64_t start,
    int64_t depth
) {
    const char *source = parser->source;
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    int64_t checkpoint_node_id = parser->next_node_id;
    int64_t checkpoint_nodes = parser->nodes;
    int64_t checkpoint_errors = parser->errors;
    int64_t checkpoint_limit_error_id = parser->limit_error_id;
    if (cursor < length &&
        (token_equal(source, cursor, "|") ||
         token_equal(source, cursor, "||"))) {
        return pattern_error(
            parser,
            cursor,
            token_end(source, cursor),
            token_equal(source, cursor, "||") ? "doubled-or" : "leading-or",
            false
        );
    }

    ParsedPattern first = parse_pattern_atomic(parser, cursor, depth);
    if (first.fatal) return first;
    int64_t separator = skip_trivia(source, first.end);
    if (separator < length && token_equal(source, separator, "||")) {
        free(first.records.data);
        parser->next_node_id = checkpoint_node_id;
        parser->nodes = checkpoint_nodes;
        parser->errors = checkpoint_errors;
        parser->limit_error_id = checkpoint_limit_error_id;
        return pattern_error(
            parser,
            cursor,
            token_end(source, separator),
            "doubled-or",
            false
        );
    }
    if (separator >= length || !token_equal(source, separator, "|")) {
        if (separator < length && token_equal(source, separator, "..")) {
            int64_t recovered = pattern_recovery_end(
                source,
                token_end(source, separator)
            );
            free(first.records.data);
            parser->next_node_id = checkpoint_node_id;
            parser->nodes = checkpoint_nodes;
            parser->errors = checkpoint_errors;
            parser->limit_error_id = checkpoint_limit_error_id;
            return pattern_error(
                parser,
                cursor,
                recovered,
                "unsupported-range-pattern",
                false
            );
        }
        return first;
    }

    Buffer records;
    Buffer children;
    buffer_init(&records);
    buffer_init(&children);
    buffer_append(&records, first.records.data);
    free(first.records.data);
    pattern_append_child(&children, first.root);
    int64_t alternatives = 1;
    int64_t end = first.end;
    while (separator < length && token_equal(source, separator, "|")) {
        buffer_format(
            &records,
            "separator|OrPattern|%" PRId64 "|%" PRId64 "|%" PRId64
            "|%" PRId64 "\n",
            cursor,
            alternatives - 1,
            separator,
            token_end(source, separator)
        );
        int64_t next = skip_trivia(source, token_end(source, separator));
        if (next < length &&
            (token_equal(source, next, "|") ||
             token_equal(source, next, "||"))) {
            free(records.data);
            free(children.data);
            parser->next_node_id = checkpoint_node_id;
            parser->nodes = checkpoint_nodes;
            parser->errors = checkpoint_errors;
            parser->limit_error_id = checkpoint_limit_error_id;
            return pattern_error(
                parser,
                cursor,
                token_end(source, next),
                "doubled-or",
                false
            );
        }
        if (pattern_stop_token(source, next)) {
            free(records.data);
            free(children.data);
            parser->next_node_id = checkpoint_node_id;
            parser->nodes = checkpoint_nodes;
            parser->errors = checkpoint_errors;
            parser->limit_error_id = checkpoint_limit_error_id;
            return pattern_error(
                parser,
                cursor,
                token_end(source, separator),
                "trailing-or",
                false
            );
        }
        ParsedPattern alternative = parse_pattern_atomic(
            parser,
            next,
            depth
        );
        if (alternative.fatal) {
            free(records.data);
            free(children.data);
            return alternative;
        }
        buffer_append(&records, alternative.records.data);
        free(alternative.records.data);
        pattern_append_child(&children, alternative.root);
        ++alternatives;
        end = alternative.end;
        separator = skip_trivia(source, alternative.end);
    }
    if (separator < length &&
        (token_equal(source, separator, "||") ||
         token_equal(source, separator, ".."))) {
        bool doubled = token_equal(source, separator, "||");
        int64_t recovered = doubled ? token_end(source, separator) :
            pattern_recovery_end(source, token_end(source, separator));
        free(records.data);
        free(children.data);
        parser->next_node_id = checkpoint_node_id;
        parser->nodes = checkpoint_nodes;
        parser->errors = checkpoint_errors;
        parser->limit_error_id = checkpoint_limit_error_id;
        return pattern_error(
            parser,
            cursor,
            recovered,
            doubled ? "doubled-or" : "unsupported-range-pattern",
            false
        );
    }
    if (!pattern_node_available(parser)) {
        free(records.data);
        free(children.data);
        return pattern_limit_error(parser, cursor);
    }
    ParsedPattern result = parsed_pattern_init(end);
    free(result.records.data);
    result.records = records;
    int64_t id = parser->next_node_id++;
    ++parser->nodes;
    result.root = id;
    result.kind = PATTERN_OR;
    buffer_format(
        &result.records,
        "node|%" PRId64 "|OrPattern|%" PRId64 "|%" PRId64
        "|%" PRId64 "|%s\n",
        id,
        cursor,
        end,
        alternatives,
        children.data
    );
    free(children.data);
    return result;
}

static int64_t pattern_match_open(const char *source, int64_t match_start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, token_end(source, match_start));
    int64_t parens = 0;
    int64_t brackets = 0;
    while (cursor < length) {
        if (token_equal(source, cursor, "(") ) {
            ++parens;
        } else if (token_equal(source, cursor, ")")) {
            if (parens > 0) --parens;
        } else if (token_equal(source, cursor, "[")) {
            ++brackets;
        } else if (token_equal(source, cursor, "]")) {
            if (brackets > 0) --brackets;
        } else if (token_equal(source, cursor, "{") && parens == 0 &&
                   brackets == 0) {
            return cursor;
        } else if (token_equal(source, cursor, "}") && parens == 0 &&
                   brackets == 0) {
            return -1;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return -1;
}

static int64_t pattern_arm_arrow(
    const char *source,
    int64_t start,
    int64_t match_close
) {
    int64_t cursor = skip_trivia(source, start);
    int64_t parens = 0;
    int64_t brackets = 0;
    while (cursor < match_close) {
        if (token_equal(source, cursor, "=>")) return cursor;
        if (token_equal(source, cursor, ",") && parens == 0 &&
            brackets == 0) {
            return -1;
        }
        if (token_equal(source, cursor, "(") ) {
            ++parens;
        } else if (token_equal(source, cursor, ")")) {
            if (parens > 0) --parens;
        } else if (token_equal(source, cursor, "[")) {
            ++brackets;
        } else if (token_equal(source, cursor, "]")) {
            if (brackets > 0) --brackets;
        } else if (token_equal(source, cursor, "{") && parens == 0 &&
                   brackets == 0) {
            return -1;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return -1;
}

static char *parse_pattern_trees(const char *source) {
    int64_t length = source_length(source);
    Buffer tree;
    buffer_init(&tree);
    buffer_append(
        &tree,
        "kofun-pattern-tree/v1\n"
        "limits|depth|32|nodes-per-compilation|256\n"
    );
    int64_t cursor = skip_trivia(source, 0);
    int64_t match_id = 0;
    PatternParser parser;
    parser.source = source;
    parser.next_node_id = 0;
    parser.nodes = 0;
    parser.errors = 0;
    parser.limit_error_id = -1;
    bool budget_exhausted = false;
    while (cursor < length && !budget_exhausted) {
        if (token_equal(source, cursor, "match")) {
            int64_t open = pattern_match_open(source, cursor);
            int64_t match_end = open < 0 ? -1 :
                balanced_end(source, open, "{", "}");
            if (open >= 0 && match_end >= 0) {
                int64_t close = match_end - 1;
                Buffer arms;
                buffer_init(&arms);
                int64_t arm_cursor = skip_trivia(
                    source,
                    token_end(source, open)
                );
                int64_t arm_id = 0;
                while (arm_cursor < close &&
                       !token_equal(source, arm_cursor, "}")) {
                    int64_t checkpoint_node_id = parser.next_node_id;
                    int64_t checkpoint_nodes = parser.nodes;
                    int64_t checkpoint_errors = parser.errors;
                    int64_t checkpoint_limit_error_id =
                        parser.limit_error_id;
                    ParsedPattern pattern = parse_pattern_or(
                        &parser,
                        arm_cursor,
                        1
                    );
                    int64_t after_pattern = skip_trivia(source, pattern.end);
                    if (!pattern.fatal && pattern.kind != PATTERN_ERROR &&
                        !token_equal(source, after_pattern, "=>") &&
                        !token_equal(source, after_pattern, "if")) {
                        int64_t recovered = pattern_recovery_end(
                            source,
                            after_pattern
                        );
                        free(pattern.records.data);
                        parser.next_node_id = checkpoint_node_id;
                        parser.nodes = checkpoint_nodes;
                        parser.errors = checkpoint_errors;
                        parser.limit_error_id = checkpoint_limit_error_id;
                        pattern = pattern_error(
                            &parser,
                            arm_cursor,
                            recovered,
                            "unexpected-token-after-pattern",
                            false
                        );
                    }
                    buffer_append(&arms, pattern.records.data);
                    free(pattern.records.data);
                    int64_t arrow = pattern_arm_arrow(
                        source,
                        pattern.end,
                        close
                    );
                    buffer_format(
                        &arms,
                        "arm|%" PRId64 "|%" PRId64 "|%" PRId64
                        "|%" PRId64 "|%" PRId64 "|%" PRId64
                        "|%" PRId64 "\n",
                        match_id,
                        arm_id,
                        pattern.root,
                        arm_cursor,
                        pattern.end,
                        arrow,
                        arrow < 0 ? -1 : token_end(source, arrow)
                    );
                    ++arm_id;
                    if (pattern.fatal && parser.limit_error_id >= 0) {
                        budget_exhausted = true;
                        break;
                    }
                    if (arrow < 0) {
                        int64_t recovery = skip_trivia(source, pattern.end);
                        if (recovery < close &&
                            token_equal(source, recovery, ",")) {
                            arm_cursor = skip_trivia(
                                source,
                                token_end(source, recovery)
                            );
                            continue;
                        }
                        break;
                    }
                    int64_t body = skip_trivia(
                        source,
                        token_end(source, arrow)
                    );
                    if (body >= close || !token_equal(source, body, "{")) {
                        arm_cursor = pattern_recovery_end(source, body);
                    } else {
                        int64_t body_end = balanced_end(source, body, "{", "}");
                        if (body_end < 0) break;
                        arm_cursor = skip_trivia(source, body_end);
                    }
                    if (arm_cursor < close &&
                        token_equal(source, arm_cursor, ",")) {
                        arm_cursor = skip_trivia(
                            source,
                            token_end(source, arm_cursor)
                        );
                    }
                }
                buffer_format(
                    &tree,
                    "match|%" PRId64 "|%" PRId64 "|%" PRId64
                    "|%" PRId64 "|%" PRId64 "|%" PRId64
                    "|%" PRId64 "\n",
                    match_id,
                    cursor,
                    open,
                    token_end(source, open),
                    close,
                    token_end(source, close),
                    arm_id
                );
                buffer_append(&tree, arms.data);
                free(arms.data);
                ++match_id;
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    buffer_format(&tree, "match-count|%" PRId64 "\n", match_id);
    return tree.data;
}

/*
 * The executable constructor pattern is exactly `C(name)` or `C(_)`: one
 * parenthesised payload sub-pattern that is a single token.  A nested payload
 * such as `Ok(Present(x))` stays parsed-but-not-executable here, and whether
 * the constructor belongs to the scrutinee's enum with a matching arity is
 * decided later, where the enum type is known and the diagnostic can name it.
 */
static bool executable_constructor_pattern(const char *source, int64_t arm) {
    int64_t length = source_length(source);
    if (arm >= length || strcmp(token_kind(source, arm), "identifier") != 0) {
        return false;
    }
    int64_t open = skip_trivia(source, token_end(source, arm));
    if (open >= length || !token_equal(source, open, "(")) return false;
    int64_t field = skip_trivia(source, token_end(source, open));
    if (
        field >= length ||
        strcmp(token_kind(source, field), "identifier") != 0
    ) {
        return false;
    }
    int64_t close = skip_trivia(source, token_end(source, field));
    return close < length && token_equal(source, close, ")");
}

static char *pattern_record_field(const char *line, int wanted) {
    const char *cursor = line;
    const char *start = line;
    int field = 0;
    while (*cursor != '\0' && *cursor != '\n') {
        if (*cursor == '|') {
            if (field == wanted) break;
            ++field;
            start = cursor + 1;
        }
        ++cursor;
    }
    if (field != wanted) return owned_text("");
    size_t length = (size_t)(cursor - start);
    char *value = allocate(length + 1u);
    memcpy(value, start, length);
    value[length] = '\0';
    return value;
}

/*
 * Same-pattern duplicate checking consumes the lossless Pattern records, not
 * constructor/wildcard token spellings.  Or-pattern binding-set equality and
 * its one-BindingId projection belong to the resolved ADT projector, so an
 * occurrence containing OrPattern is intentionally left to that authority.
 */
static char *pattern_duplicate_binding_error(
    const char *source,
    int64_t start
) {
    PatternParser parser = {
        .source = source,
        .next_node_id = 0,
        .nodes = 0,
        .errors = 0,
        .limit_error_id = -1,
    };
    ParsedPattern parsed = parse_pattern_or(&parser, start, 1);
    if (strstr(parsed.records.data, "|OrPattern|") != NULL) {
        free(parsed.records.data);
        return owned_text("");
    }
    char *names[PATTERN_NODE_LIMIT] = {0};
    int64_t starts[PATTERN_NODE_LIMIT] = {0};
    size_t count = 0u;
    const char *line = parsed.records.data;
    while (*line != '\0') {
        char *record = pattern_record_field(line, 0);
        char *kind = pattern_record_field(line, 2);
        if (strcmp(record, "node") == 0 &&
            strcmp(kind, "NamePattern") == 0) {
            char *name = pattern_record_field(line, 5);
            char *start_text = pattern_record_field(line, 3);
            int64_t declaration = strtoll(start_text, NULL, 10);
            char *owner = enum_constructor_owner(source, name);
            bool binding = owner[0] == '\0' && enum_binding_catchall_name(name);
            free(owner);
            free(start_text);
            if (binding) {
                size_t index = 0u;
                while (index < count && strcmp(names[index], name) != 0) {
                    ++index;
                }
                if (index < count) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S47]: duplicate binding `%s` in pattern at "
                        "byte %" PRId64 "; first declaration at byte %" PRId64,
                        name,
                        declaration,
                        starts[index]
                    );
                    stage2_diagnostic_set(
                        "E2S47",
                        declaration,
                        declaration,
                        true,
                        error.data
                    );
                    free(name);
                    for (size_t held = 0u; held < count; ++held) {
                        free(names[held]);
                    }
                    free(record);
                    free(kind);
                    free(parsed.records.data);
                    return error.data;
                }
                names[count] = name;
                starts[count] = declaration;
                ++count;
            } else {
                free(name);
            }
        }
        free(record);
        free(kind);
        const char *next = strchr(line, '\n');
        if (next == NULL) break;
        line = next + 1;
    }
    for (size_t held = 0u; held < count; ++held) free(names[held]);
    free(parsed.records.data);
    return owned_text("");
}

static char *validate_executable_patterns(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (token_equal(source, cursor, "match")) {
            int64_t open = pattern_match_open(source, cursor);
            int64_t match_end = open < 0 ? -1 :
                balanced_end(source, open, "{", "}");
            if (open >= 0 && match_end >= 0) {
                int64_t close = match_end - 1;
                int64_t arm = skip_trivia(source, token_end(source, open));
                while (arm < close && !token_equal(source, arm, "}")) {
                    char *duplicate = pattern_duplicate_binding_error(
                        source,
                        arm
                    );
                    if (strncmp(duplicate, "error[", 6) == 0) {
                        return duplicate;
                    }
                    free(duplicate);
                    PatternSummary summary = pattern_summary(source, arm);
                    bool executable = summary.kind == PATTERN_WILDCARD ||
                        summary.kind == PATTERN_NAME ||
                        (summary.kind == PATTERN_CONSTRUCTOR &&
                         executable_constructor_pattern(source, arm)) ||
                        (summary.kind == PATTERN_LITERAL &&
                         (token_equal(source, arm, "true") ||
                          token_equal(source, arm, "false")));
                    if (!executable) {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S24]: general pattern syntax is parsed "
                            "but not executable in Stage 2 Core at byte %"
                            PRId64,
                            arm
                        );
                        stage2_diagnostic_set(
                            "E2S24",
                            arm,
                            arm,
                            true,
                            error.data
                        );
                        return error.data;
                    }
                    int64_t arrow = pattern_arm_arrow(
                        source,
                        summary.end,
                        close
                    );
                    if (arrow < 0) break;
                    int64_t body = skip_trivia(
                        source,
                        token_end(source, arrow)
                    );
                    if (body >= close || !token_equal(source, body, "{")) {
                        break;
                    }
                    int64_t body_end = balanced_end(source, body, "{", "}");
                    if (body_end < 0) break;
                    arm = skip_trivia(source, body_end);
                    if (arm < close && token_equal(source, arm, ",")) {
                        arm = skip_trivia(source, token_end(source, arm));
                    }
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

static PatternSummary pattern_summary(const char *source, int64_t start) {
    PatternParser parser;
    parser.source = source;
    parser.next_node_id = 0;
    parser.nodes = 0;
    parser.errors = 0;
    parser.limit_error_id = -1;
    ParsedPattern parsed = parse_pattern_or(&parser, start, 1);
    PatternSummary summary;
    summary.end = parsed.end;
    summary.kind = parsed.kind;
    free(parsed.records.data);
    return summary;
}

static char *pattern_first_error(const char *ir) {
    const char *record = ir;
    char best_reason[64] = "";
    int64_t best_start = -1;
    int64_t best_end = -1;
    while ((record = strstr(record, "pattern-diagnostic|")) != NULL) {
        char code[16];
        char reason[64];
        int64_t start = -1;
        int64_t end = -1;
        if (sscanf(
                record,
                "pattern-diagnostic|%15[^|]|%63[^|]|%" SCNd64
                "|%" SCNd64,
                code,
                reason,
                &start,
                &end
            ) == 4 && (best_start < 0 || start < best_start)) {
            (void)snprintf(best_reason, sizeof(best_reason), "%s", reason);
            best_start = start;
            best_end = end;
        }
        ++record;
    }
    if (best_start < 0) return owned_text("");
    Buffer error;
    buffer_init(&error);
    buffer_format(
        &error,
        "error[E2S58]: invalid pattern (%s) at bytes %" PRId64
        "..%" PRId64,
        best_reason,
        best_start,
        best_end
    );
    stage2_diagnostic_set(
        "E2S58",
        best_start,
        best_end,
        true,
        error.data
    );
    return error.data;
}

static int64_t balanced_end(
    const char *source,
    int64_t start,
    const char *open,
    const char *close
) {
    int64_t length = source_length(source);
    int64_t cursor = start;
    int64_t depth = 0;
    while (cursor < length) {
        cursor = skip_trivia(source, cursor);
        if (cursor >= length) return -1;
        int64_t end = token_end(source, cursor);
        if (end <= cursor) return -1;
        if (token_equal(source, cursor, open)) {
            ++depth;
        } else if (token_equal(source, cursor, close)) {
            --depth;
            if (depth == 0) return end;
        }
        cursor = end;
    }
    return -1;
}

static bool basic_visibility_modifier(const char *source, int64_t start) {
    return token_equal(source, start, "pub") ||
           token_equal(source, start, "internal") ||
           token_equal(source, start, "private");
}

static bool visibility_word(const char *source, int64_t start) {
    return basic_visibility_modifier(source, start) ||
           token_equal(source, start, "public") ||
           token_equal(source, start, "protected");
}

static bool visibility_prefix_candidate(const char *source, int64_t start) {
    if (visibility_word(source, start)) return true;
    if (strcmp(token_kind(source, start), "identifier") != 0) return false;
    int64_t next = skip_trivia(source, token_end(source, start));
    return token_equal(source, next, "fn") ||
           token_equal(source, next, "type");
}

static int64_t function_declaration_start(
    const char *source,
    int64_t start
) {
    int64_t length = source_length(source);
    if (token_equal(source, start, "fn")) return start;
    if (!basic_visibility_modifier(source, start)) return -1;
    int64_t after_modifier = skip_trivia(source, token_end(source, start));
    if (
        after_modifier < length &&
        token_equal(source, after_modifier, "fn")
    ) {
        return after_modifier;
    }
    return -1;
}

static int64_t type_declaration_start(
    const char *source,
    int64_t start
) {
    int64_t length = source_length(source);
    if (token_equal(source, start, "type")) return start;
    if (!basic_visibility_modifier(source, start)) return -1;
    int64_t after_modifier = skip_trivia(source, token_end(source, start));
    if (
        after_modifier < length &&
        token_equal(source, after_modifier, "type")
    ) {
        return after_modifier;
    }
    return -1;
}

static const char *visibility_level(const char *source, int64_t start) {
    if (token_equal(source, start, "pub")) return "public";
    if (token_equal(source, start, "internal")) return "internal";
    return "private";
}

static int64_t parameter_open(const char *source, int64_t start);

static char *visibility_prefix_error(const char *source, int64_t start) {
    int64_t length = source_length(source);
    Buffer error;
    buffer_init(&error);
    if (
        token_equal(source, start, "public") ||
        token_equal(source, start, "protected")
    ) {
        char *alias = token_copy(source, start);
        buffer_format(
            &error,
            "error[E2S34]: unsupported visibility modifier `%s`; "
            "use `pub`, `internal`, or `private` at bytes %" PRId64
            "..%" PRId64,
            alias,
            start,
            token_end(source, start)
        );
        stage2_diagnostic_set(
            "E2S34",
            start,
            token_end(source, start),
            true,
            error.data
        );
        free(alias);
        return error.data;
    }
    if (!basic_visibility_modifier(source, start)) {
        int64_t next = skip_trivia(source, token_end(source, start));
        if (
            strcmp(token_kind(source, start), "identifier") == 0 &&
            next < length &&
            (token_equal(source, next, "fn") ||
             token_equal(source, next, "type"))
        ) {
            char *modifier = token_copy(source, start);
            buffer_format(
                &error,
                "error[E2S33]: unknown visibility modifier `%s`; expected "
                "`pub`, `internal`, or `private` at bytes %" PRId64
                "..%" PRId64,
                modifier,
                start,
                token_end(source, start)
            );
            stage2_diagnostic_set(
                "E2S33",
                start,
                token_end(source, start),
                true,
                error.data
            );
            free(modifier);
        }
        return error.data;
    }

    int64_t next = skip_trivia(source, token_end(source, start));
    if (next < length &&
        (token_equal(source, next, "fn") ||
         token_equal(source, next, "type"))) return error.data;
    if (next < length && basic_visibility_modifier(source, next)) {
        char *first = token_copy(source, start);
        char *second = token_copy(source, next);
        const char *kind = strcmp(first, second) == 0 ? "repeated" : "conflicting";
        buffer_format(
            &error,
            "error[E2S33]: %s visibility modifiers `%s` and `%s` "
            "at bytes %" PRId64 "..%" PRId64,
            kind,
            first,
            second,
            start,
            token_end(source, next)
        );
        stage2_diagnostic_set(
            "E2S33",
            start,
            token_end(source, next),
            true,
            error.data
        );
        free(second);
        free(first);
        return error.data;
    }
    if (token_equal(source, start, "pub") && next < length &&
        token_equal(source, next, "(")) {
        int64_t form_end = balanced_end(source, next, "(", ")");
        if (form_end < 0) form_end = token_end(source, next);
        int64_t form_name = skip_trivia(source, token_end(source, next));
        bool rust_alias = form_name < length &&
                          (token_equal(source, form_name, "crate") ||
                           token_equal(source, form_name, "super") ||
                           token_equal(source, form_name, "in"));
        buffer_format(
            &error,
            "error[E2S34]: %s `pub(...)` visibility is not supported "
            "in this frontend slice at bytes %" PRId64 "..%" PRId64,
            rust_alias ? "Rust-style" : "restricted",
            start,
            form_end
        );
        stage2_diagnostic_set(
            "E2S34",
            start,
            form_end,
            true,
            error.data
        );
        return error.data;
    }

    char *modifier = token_copy(source, start);
    buffer_format(
        &error,
        "error[E2S33]: visibility modifier `%s` must be followed by a "
        "top-level `fn` or `type` declaration at bytes %" PRId64 "..%" PRId64,
        modifier,
        start,
        token_end(source, start)
    );
    stage2_diagnostic_set(
        "E2S33",
        start,
        token_end(source, start),
        true,
        error.data
    );
    free(modifier);
    return error.data;
}

static char *local_visibility_error(
    const char *source,
    int64_t function_start,
    int64_t function_close
) {
    Buffer error;
    buffer_init(&error);
    int64_t open = parameter_open(source, function_start);
    if (open < 0) return error.data;
    int64_t cursor = balanced_end(source, open, "(", ")");
    while (cursor >= 0 && cursor < function_close &&
           !token_equal(source, cursor, "{")) {
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (cursor < 0 || cursor >= function_close) return error.data;
    cursor = skip_trivia(source, token_end(source, cursor));
    while (cursor < function_close) {
        bool basic = basic_visibility_modifier(source, cursor);
        bool alias = token_equal(source, cursor, "public") ||
                     token_equal(source, cursor, "protected");
        if (basic || alias) {
            int64_t next = skip_trivia(source, token_end(source, cursor));
            bool declaration_like =
                next < function_close &&
                (token_equal(source, next, "fn") ||
                 token_equal(source, next, "let") ||
                 token_equal(source, next, "var") ||
                 token_equal(source, next, "type") ||
                 basic_visibility_modifier(source, next));
            if (declaration_like) {
                char *modifier = token_copy(source, cursor);
                buffer_format(
                    &error,
                    "error[%s]: visibility modifier `%s` is not supported "
                    "in local scope at bytes %" PRId64 "..%" PRId64,
                    alias ? "E2S34" : "E2S33",
                    modifier,
                    cursor,
                    token_end(source, cursor)
                );
                stage2_diagnostic_set(
                    alias ? "E2S34" : "E2S33",
                    cursor,
                    token_end(source, cursor),
                    true,
                    error.data
                );
                free(modifier);
                return error.data;
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return error.data;
}

static char *function_name(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t after_fn = skip_trivia(source, token_end(source, start));
    if (
        after_fn >= length ||
        strcmp(token_kind(source, after_fn), "identifier") != 0
    ) {
        char *empty = allocate(1);
        empty[0] = '\0';
        return empty;
    }
    return token_copy(source, after_fn);
}

static int64_t parameter_open(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t after_fn = skip_trivia(source, token_end(source, start));
    int64_t after_name = skip_trivia(source, token_end(source, after_fn));
    if (after_name >= length || !token_equal(source, after_name, "(")) return -1;
    return after_name;
}

static int64_t parameter_count(const char *source, int64_t start) {
    int64_t open = parameter_open(source, start);
    if (open < 0) return -1;
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return -1;
    int64_t cursor = skip_trivia(source, token_end(source, open));
    if (cursor >= close || token_equal(source, cursor, ")")) return 0;

    int64_t count = 1;
    int64_t paren_depth = 0;
    int64_t bracket_depth = 0;
    while (cursor < close) {
        if (token_equal(source, cursor, "(")) {
            ++paren_depth;
        } else if (token_equal(source, cursor, ")")) {
            if (paren_depth == 0) return count;
            --paren_depth;
        } else if (token_equal(source, cursor, "[")) {
            ++bracket_depth;
        } else if (token_equal(source, cursor, "]")) {
            --bracket_depth;
        } else if (
            token_equal(source, cursor, ",") &&
            paren_depth == 0 &&
            bracket_depth == 0
        ) {
            ++count;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return count;
}

static int64_t function_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    char *name = function_name(source, start);
    if (!token_equal(source, start, "fn") || name[0] == '\0') {
        free(name);
        return -1;
    }
    free(name);

    int64_t open = parameter_open(source, start);
    if (open < 0) return -1;
    int64_t parameters_end = balanced_end(source, open, "(", ")");
    if (parameters_end < 0) return -1;
    int64_t cursor = skip_trivia(source, parameters_end);

    if (cursor < length && token_equal(source, cursor, "->")) {
        cursor = skip_trivia(source, token_end(source, cursor));
        int64_t type_tokens = 0;
        while (cursor < length && !token_equal(source, cursor, "{")) {
            if (token_equal(source, cursor, "=")) return -1;
            ++type_tokens;
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        if (type_tokens == 0) return -1;
    }
    if (cursor >= length || !token_equal(source, cursor, "{")) return -1;
    return balanced_end(source, cursor, "{", "}");
}

static char *type_name(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t name = skip_trivia(source, token_end(source, start));
    if (
        name >= length ||
        strcmp(token_kind(source, name), "identifier") != 0
    ) {
        char *empty = allocate(1);
        empty[0] = '\0';
        return empty;
    }
    return token_copy(source, name);
}

static int64_t top_level_end(const char *source, int64_t start);
static int64_t after_optional_module_header(
    const char *source,
    int64_t start
);
static char *owned_text(const char *text);
static bool enum_name_covered(const char *covered, const char *name);
static int64_t function_arity(const char *source, const char *wanted);
static char *const_type_base(const char *annotation);
static char *const_generic_refusal(Buffer *error);

/* The `[` of a `type NAME[...]` parameter list, or -1 when there is none.
 *
 * #916 admits exactly one shape here, `[const NAME: Int]`. An ordinary type
 * parameter needs field substitution and per-instantiation layout, neither of
 * which this slice builds, so it is refused by name rather than half-parsed. */
static int64_t type_parameter_open(const char *source, int64_t start) {
    int64_t length = source_length(source);
    if (!token_equal(source, start, "type")) return -1;
    int64_t name = skip_trivia(source, token_end(source, start));
    if (
        name >= length ||
        strcmp(token_kind(source, name), "identifier") != 0
    ) {
        return -1;
    }
    int64_t bracket = skip_trivia(source, token_end(source, name));
    if (bracket < length && token_equal(source, bracket, "[")) return bracket;
    return -1;
}

/* The `=` of a type declaration, skipping an optional parameter list. `-1`
 * when the parameter brackets do not close. */
static int64_t type_equals_token(const char *source, int64_t start) {
    int64_t name = skip_trivia(source, token_end(source, start));
    int64_t bracket = type_parameter_open(source, start);
    if (bracket < 0) return skip_trivia(source, token_end(source, name));
    int64_t close = balanced_end(source, bracket, "[", "]");
    if (close < 0) return -1;
    return skip_trivia(source, close);
}

/* The declared const parameter of `type NAME[const P: Int]`, or "" when the
 * declaration has no parameter list or the list is not that shape. */
static char *const_parameter_name(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t bracket = type_parameter_open(source, start);
    if (bracket < 0) return owned_text("");
    int64_t keyword = skip_trivia(source, token_end(source, bracket));
    if (keyword >= length || !token_equal(source, keyword, "const")) {
        return owned_text("");
    }
    int64_t parameter = skip_trivia(source, token_end(source, keyword));
    if (
        parameter >= length ||
        strcmp(token_kind(source, parameter), "identifier") != 0
    ) {
        return owned_text("");
    }
    return token_copy(source, parameter);
}

/* The const parameter declared by the type named `wanted`, or "". */
static char *const_parameter_of_type(const char *source, const char *wanted) {
    int64_t length = source_length(source);
    int64_t cursor = after_optional_module_header(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0) {
            char *name = type_name(source, type_start);
            bool matched = strcmp(name, wanted) == 0;
            free(name);
            if (matched) return const_parameter_name(source, type_start);
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return owned_text("");
        cursor = skip_trivia(source, end);
    }
    return owned_text("");
}

static int64_t type_declaration_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    char *name_text = type_name(source, start);
    bool valid_start = token_equal(source, start, "type") &&
                       name_text[0] != '\0';
    free(name_text);
    if (!valid_start) return -1;

    int64_t equals = type_equals_token(source, start);
    if (equals < 0 || equals >= length || !token_equal(source, equals, "=")) {
        return -1;
    }
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    if (pipe < length && token_equal(source, pipe, "{")) {
        int64_t close = balanced_end(source, pipe, "{", "}");
        if (close < 0) return -1;
        int64_t next = skip_trivia(source, close);
        if (
            next < length &&
            !token_equal(source, next, "fn") &&
            !token_equal(source, next, "type") &&
            !token_equal(source, next, "let") &&
            !visibility_prefix_candidate(source, next)
        ) {
            return -1;
        }
        return close;
    }
    int64_t constructors = 0;
    int64_t last_end = -1;
    while (pipe < length && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        if (
            constructor >= length ||
            strcmp(token_kind(source, constructor), "identifier") != 0
        ) {
            return -1;
        }
        ++constructors;
        if (constructors > 64) return -2;
        last_end = token_end(source, constructor);
        pipe = skip_trivia(source, last_end);
        if (pipe < length && token_equal(source, pipe, "(")) {
            int64_t payload_end = balanced_end(source, pipe, "(", ")");
            if (payload_end < 0) return -1;
            last_end = payload_end;
            pipe = skip_trivia(source, payload_end);
        }
    }
    if (constructors == 0) return -1;
    if (
        pipe < length &&
        !token_equal(source, pipe, "fn") &&
        !token_equal(source, pipe, "type") &&
        !token_equal(source, pipe, "let") &&
        !visibility_prefix_candidate(source, pipe)
    ) {
        return -1;
    }
    return last_end;
}

/* A top-level `let NAME = <integer literal>` module constant.  Constants carry
 * no visibility modifier in this slice, so a declaration always starts at the
 * `let` keyword itself and stays internal to its compilation unit. */
static int64_t constant_declaration_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    if (!token_equal(source, start, "let")) return -1;
    int64_t name = skip_trivia(source, token_end(source, start));
    if (
        name >= length ||
        strcmp(token_kind(source, name), "identifier") != 0
    ) {
        return -1;
    }
    int64_t equals = skip_trivia(source, token_end(source, name));
    if (equals >= length || !token_equal(source, equals, "=")) return -1;
    int64_t value = skip_trivia(source, token_end(source, equals));
    if (value < length && token_equal(source, value, "-")) {
        value = skip_trivia(source, token_end(source, value));
    }
    if (
        value >= length ||
        strcmp(token_kind(source, value), "integer") != 0
    ) {
        return -1;
    }
    /* The initializer is the whole declaration. Requiring the next token to
     * open another top-level declaration keeps `let A = 1 + 2` a constant
     * diagnostic instead of an unexpected-token one at the operator. */
    int64_t close = token_end(source, value);
    int64_t next = skip_trivia(source, close);
    if (
        next < length &&
        !token_equal(source, next, "fn") &&
        !token_equal(source, next, "type") &&
        !token_equal(source, next, "let") &&
        !visibility_prefix_candidate(source, next)
    ) {
        return -1;
    }
    return close;
}

static char *constant_name(const char *source, int64_t start) {
    if (constant_declaration_end(source, start) < 0) {
        return owned_text("");
    }
    return token_copy(source, skip_trivia(source, token_end(source, start)));
}

/* The constant's value as C source: the integer literal text with its optional
 * `-` restored. */
static char *constant_value_text(const char *source, int64_t start) {
    if (constant_declaration_end(source, start) < 0) {
        return owned_text("");
    }
    int64_t name = skip_trivia(source, token_end(source, start));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t value = skip_trivia(source, token_end(source, equals));
    bool negative = token_equal(source, value, "-");
    if (negative) {
        value = skip_trivia(source, token_end(source, value));
    }
    char *digits = token_copy(source, value);
    if (!negative) return digits;
    Buffer out;
    buffer_init(&out);
    buffer_append(&out, "-");
    buffer_append(&out, digits);
    free(digits);
    return out.data;
}

/* Walk to the next top-level constant at or after `from`.  Type and function
 * bodies are stepped over, so a `let` statement inside a body is never mistaken
 * for a module constant. */
static int64_t next_constant_start(const char *source, int64_t from) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, from);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0) {
            int64_t type_close = type_declaration_end(source, type_start);
            if (type_close < 0) return length;
            cursor = skip_trivia(source, type_close);
        } else {
            int64_t function_start = function_declaration_start(source, cursor);
            if (function_start >= 0) {
                int64_t function_close = function_end(source, function_start);
                if (function_close < 0) return length;
                cursor = skip_trivia(source, function_close);
            } else if (token_equal(source, cursor, "let")) {
                return cursor;
            } else {
                return length;
            }
        }
    }
    return length;
}

static int64_t constant_declaration_count(
    const char *source,
    const char *wanted
) {
    int64_t length = source_length(source);
    int64_t cursor = next_constant_start(source, 0);
    int64_t found = 0;
    while (cursor < length) {
        char *name = constant_name(source, cursor);
        if (strcmp(name, wanted) == 0) ++found;
        free(name);
        int64_t close = constant_declaration_end(source, cursor);
        if (close < 0) return found;
        cursor = next_constant_start(source, close);
    }
    return found;
}

static bool constant_is_declared(const char *source, const char *wanted) {
    return constant_declaration_count(source, wanted) > 0;
}

/* The C name a module constant lowers to.  Constants share one prefix that no
 * lowered function, record, or local binding uses. */
static char *constant_c_name(const char *name) {
    Buffer out;
    buffer_init(&out);
    buffer_append(&out, "kofun_k_");
    buffer_append(&out, name);
    return out.data;
}

static bool record_declaration_at(const char *source, int64_t start) {
    if (!token_equal(source, start, "type")) return false;
    int64_t equals = type_equals_token(source, start);
    if (equals < 0) return false;
    int64_t open = skip_trivia(source, token_end(source, equals));
    return token_equal(source, equals, "=") &&
           token_equal(source, open, "{");
}

/* The declaration a record type identity names. A const argument selects no
 * separate declaration — it is part of the *type*, never of the *declaration* —
 * so it is dropped here, and this is the single lookup funnel that makes every
 * field, layout, and C-name consumer agree on that without knowing about it. */
static int64_t record_declaration_start(
    const char *source,
    const char *identity
) {
    int64_t length = (int64_t)strlen(source);
    char *wanted = const_type_base(identity);
    int64_t cursor = after_optional_module_header(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (
            type_start >= 0 &&
            record_declaration_at(source, type_start)
        ) {
            char *name = type_name(source, type_start);
            bool found = strcmp(name, wanted) == 0;
            free(name);
            if (found) {
                free(wanted);
                return type_start;
            }
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) {
            free(wanted);
            return -1;
        }
        cursor = skip_trivia(source, end);
    }
    free(wanted);
    return -1;
}

/*
 * Validate and count one bounded record declaration.  `-2` means a field type
 * outside the Stage 2 Int/Bool slice, `-3` malformed or duplicate fields, and
 * `-4` the per-record 128-field ceiling.  AggregateLayout v1 remains the
 * authority for the corresponding declaration-order C layout.
 */
static int64_t record_field_count(
    const char *source,
    const char *record_type
) {
    int64_t declaration = record_declaration_start(source, record_type);
    if (declaration < 0) return -1;
    int64_t equals = type_equals_token(source, declaration);
    if (equals < 0) return -3;
    int64_t open = skip_trivia(source, token_end(source, equals));
    int64_t close = balanced_end(source, open, "{", "}");
    if (close < 0) return -3;
    int64_t cursor = skip_trivia(source, token_end(source, open));
    Buffer covered;
    buffer_init(&covered);
    buffer_append(&covered, "|");
    int64_t count = 0;
    while (cursor < close && !token_equal(source, cursor, "}")) {
        if (strcmp(token_kind(source, cursor), "identifier") != 0) {
            free(covered.data);
            return -3;
        }
        char *field = token_copy(source, cursor);
        if (enum_name_covered(covered.data, field)) {
            free(field);
            free(covered.data);
            return -3;
        }
        buffer_append(&covered, field);
        buffer_append(&covered, "|");
        free(field);
        int64_t colon = skip_trivia(source, token_end(source, cursor));
        int64_t field_type = skip_trivia(source, token_end(source, colon));
        if (
            !token_equal(source, colon, ":") ||
            strcmp(token_kind(source, field_type), "identifier") != 0
        ) {
            free(covered.data);
            return -3;
        }
        if (
            !token_equal(source, field_type, "Int") &&
            !token_equal(source, field_type, "Bool")
        ) {
            free(covered.data);
            return -2;
        }
        ++count;
        if (count > 128) {
            free(covered.data);
            return -4;
        }
        int64_t separator = skip_trivia(
            source,
            token_end(source, field_type)
        );
        if (separator < close && token_equal(source, separator, ",")) {
            cursor = skip_trivia(source, token_end(source, separator));
        } else if (separator == close || token_equal(source, separator, "}")) {
            cursor = separator;
        } else {
            free(covered.data);
            return -3;
        }
    }
    free(covered.data);
    return count == 0 ? -3 : count;
}

static char *record_field_text(
    const char *source,
    const char *record_type,
    int64_t wanted_index,
    bool want_type
) {
    int64_t declaration = record_declaration_start(source, record_type);
    if (declaration < 0) return owned_text("");
    int64_t equals = type_equals_token(source, declaration);
    if (equals < 0) return owned_text("");
    int64_t open = skip_trivia(source, token_end(source, equals));
    int64_t close = balanced_end(source, open, "{", "}");
    int64_t cursor = skip_trivia(source, token_end(source, open));
    int64_t index = 0;
    while (cursor < close && !token_equal(source, cursor, "}")) {
        int64_t colon = skip_trivia(source, token_end(source, cursor));
        int64_t field_type = skip_trivia(source, token_end(source, colon));
        if (index == wanted_index) {
            return token_copy(source, want_type ? field_type : cursor);
        }
        int64_t separator = skip_trivia(
            source,
            token_end(source, field_type)
        );
        cursor = token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator))
            : separator;
        ++index;
    }
    return owned_text("");
}

static int64_t record_field_index(
    const char *source,
    const char *record_type,
    const char *wanted
) {
    int64_t count = record_field_count(source, record_type);
    for (int64_t index = 0; index < count; ++index) {
        char *field = record_field_text(
            source,
            record_type,
            index,
            false
        );
        bool found = strcmp(field, wanted) == 0;
        free(field);
        if (found) return index;
    }
    return -1;
}

static int64_t top_level_end(const char *source, int64_t start) {
    int64_t type_start = type_declaration_start(source, start);
    if (type_start >= 0) {
        return type_declaration_end(source, type_start);
    }
    /* Module constants are top-level declarations too, so every walker that
     * steps over one declaration at a time has to step over them as well. */
    if (token_equal(source, start, "let")) {
        return constant_declaration_end(source, start);
    }
    int64_t function_start = function_declaration_start(source, start);
    if (function_start < 0) return -1;
    return function_end(source, function_start);
}

static int64_t after_optional_module_header(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (!token_equal(source, cursor, "module")) return cursor;
    cursor = skip_trivia(source, token_end(source, cursor));
    if (cursor >= length || strcmp(token_kind(source, cursor), "identifier") != 0) {
        return cursor;
    }
    cursor = token_end(source, cursor);
    while (cursor < length) {
        int64_t dot = skip_trivia(source, cursor);
        if (dot >= length || !token_equal(source, dot, ".")) break;
        int64_t part = skip_trivia(source, token_end(source, dot));
        if (
            part >= length ||
            strcmp(token_kind(source, part), "identifier") != 0
        ) {
            break;
        }
        cursor = token_end(source, part);
    }
    return skip_trivia(source, cursor);
}

static int64_t next_function_start(const char *source, int64_t start) {
    int64_t length = source_length(source);
    /* Callers advance with function_end's result, which is -1 for a position
     * that is not a function declaration. Restarting the walk from before the
     * buffer re-emitted every record with fresh identifiers forever, so a
     * rejected position ends the walk instead. */
    if (start < 0) return length;
    int64_t cursor = after_optional_module_header(source, start);
    /* Types and module constants both precede the functions that read them, so
     * the walk steps over either kind before it looks for `fn`. */
    bool advanced = true;
    while (cursor < length && advanced) {
        advanced = false;
        if (type_declaration_start(source, cursor) >= 0) {
            int64_t type_start = type_declaration_start(source, cursor);
            int64_t end = type_declaration_end(source, type_start);
            if (end <= cursor) return length;
            cursor = skip_trivia(source, end);
            advanced = true;
        } else if (token_equal(source, cursor, "let")) {
            int64_t constant_close = constant_declaration_end(source, cursor);
            if (constant_close <= cursor) return length;
            cursor = skip_trivia(source, constant_close);
            advanced = true;
        }
    }
    int64_t function_start = function_declaration_start(source, cursor);
    return function_start < 0 ? cursor : function_start;
}

static int64_t enum_declaration_start(
    const char *source,
    const char *wanted
) {
    int64_t length = source_length(source);
    int64_t cursor = after_optional_module_header(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0) {
            char *name = type_name(source, type_start);
            bool found =
                strcmp(name, wanted) == 0 &&
                !record_declaration_at(source, type_start);
            free(name);
            if (found) return type_start;
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return -1;
        cursor = skip_trivia(source, end);
    }
    return -1;
}

/*
 * A constructor may carry one parenthesised payload field.  Every walker below
 * steps over that field with this helper: stopping at the `(` instead would
 * truncate the constructor set of any enum whose payload-carrying constructor
 * is not written last, which silently changes coverage rather than failing.
 */
static int64_t enum_constructor_token_end(
    const char *source,
    int64_t constructor
) {
    int64_t length = source_length(source);
    int64_t after = token_end(source, constructor);
    int64_t open = skip_trivia(source, after);
    if (open >= length || !token_equal(source, open, "(")) return after;
    int64_t close = balanced_end(source, open, "(", ")");
    return close < 0 ? after : close;
}

/*
 * The payload field this Core slice lowers is exactly `name: Int`.  The ADT
 * frontend already bounds a constructor to one field with `E2S41`; the extra
 * `Int` requirement here is what lets a constructor value be a tag and one
 * `int64_t`, so a wider field type must fail rather than lower.
 */
static bool enum_payload_field_supported(const char *source, int64_t open) {
    int64_t length = source_length(source);
    int64_t field = skip_trivia(source, token_end(source, open));
    if (
        field >= length ||
        strcmp(token_kind(source, field), "identifier") != 0
    ) {
        return false;
    }
    int64_t colon = skip_trivia(source, token_end(source, field));
    if (colon >= length || !token_equal(source, colon, ":")) return false;
    int64_t type_cursor = skip_trivia(source, token_end(source, colon));
    if (type_cursor >= length || !token_equal(source, type_cursor, "Int")) {
        return false;
    }
    int64_t close = skip_trivia(source, token_end(source, type_cursor));
    return close < length && token_equal(source, close, ")");
}

static int64_t enum_constructor_count(
    const char *source,
    const char *enum_type
) {
    int64_t declaration = enum_declaration_start(source, enum_type);
    if (declaration < 0) return -1;
    int64_t name = skip_trivia(source, token_end(source, declaration));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    int64_t end = type_declaration_end(source, declaration);
    int64_t count = 0;
    while (pipe < end && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        ++count;
        pipe = skip_trivia(
            source,
            enum_constructor_token_end(source, constructor)
        );
    }
    return count;
}

/*
 * Payload arity of one named constructor: `0` payload-free, `1` one supported
 * `Int` field, `-1` when the constructor does not belong to the enum, and `-2`
 * when it declares a payload this slice cannot lower.
 */
static int64_t enum_constructor_payload_arity(
    const char *source,
    const char *enum_type,
    const char *wanted
) {
    int64_t declaration = enum_declaration_start(source, enum_type);
    if (declaration < 0) return -1;
    int64_t name = skip_trivia(source, token_end(source, declaration));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    int64_t end = type_declaration_end(source, declaration);
    while (pipe < end && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        if (token_equal(source, constructor, wanted)) {
            int64_t open = skip_trivia(
                source,
                token_end(source, constructor)
            );
            if (open >= end || !token_equal(source, open, "(")) return 0;
            return enum_payload_field_supported(source, open) ? 1 : -2;
        }
        pipe = skip_trivia(
            source,
            enum_constructor_token_end(source, constructor)
        );
    }
    return -1;
}

static int64_t enum_constructor_index(
    const char *source,
    const char *enum_type,
    const char *wanted
) {
    int64_t declaration = enum_declaration_start(source, enum_type);
    if (declaration < 0) return -1;
    int64_t name = skip_trivia(source, token_end(source, declaration));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    int64_t end = type_declaration_end(source, declaration);
    int64_t tag = 0;
    while (pipe < end && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        if (token_equal(source, constructor, wanted)) return tag;
        ++tag;
        pipe = skip_trivia(
            source,
            enum_constructor_token_end(source, constructor)
        );
    }
    return -1;
}

static bool enum_name_covered(const char *covered, const char *name) {
    Buffer key;
    buffer_init(&key);
    buffer_format(&key, "|%s|", name);
    bool found = strstr(covered, key.data) != NULL;
    free(key.data);
    return found;
}

static bool enum_constructors_covered(
    const char *source,
    const char *enum_type,
    const char *covered
) {
    int64_t declaration = enum_declaration_start(source, enum_type);
    if (declaration < 0) return false;
    int64_t name = skip_trivia(source, token_end(source, declaration));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    int64_t end = type_declaration_end(source, declaration);
    while (pipe < end && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        char *constructor_name = token_copy(source, constructor);
        bool found = enum_name_covered(covered, constructor_name);
        free(constructor_name);
        if (!found) return false;
        pipe = skip_trivia(
            source,
            enum_constructor_token_end(source, constructor)
        );
    }
    return true;
}

static char *enum_missing_constructors(
    const char *source,
    const char *enum_type,
    const char *covered
) {
    int64_t declaration = enum_declaration_start(source, enum_type);
    int64_t name = skip_trivia(source, token_end(source, declaration));
    int64_t equals = skip_trivia(source, token_end(source, name));
    int64_t pipe = skip_trivia(source, token_end(source, equals));
    int64_t end = type_declaration_end(source, declaration);
    Buffer missing;
    buffer_init(&missing);
    while (pipe < end && token_equal(source, pipe, "|")) {
        int64_t constructor = skip_trivia(source, token_end(source, pipe));
        char *constructor_name = token_copy(source, constructor);
        if (!enum_name_covered(covered, constructor_name)) {
            if (missing.length > 0) buffer_append(&missing, ", ");
            buffer_format(&missing, "`%s`", constructor_name);
        }
        free(constructor_name);
        pipe = skip_trivia(
            source,
            enum_constructor_token_end(source, constructor)
        );
    }
    return missing.data;
}

/* "" when a parameterized `type` declares exactly `[const NAME: Int]`, and the
 * diagnostic that refuses it otherwise. Ordinary type parameters on a nominal
 * type are named here rather than reported as a malformed declaration. */
static char *type_parameter_list_error(const char *source, int64_t start) {
    int64_t bracket = type_parameter_open(source, start);
    if (bracket < 0) return owned_text("");
    char *name = type_name(source, start);
    Buffer error;
    buffer_init(&error);
    if (balanced_end(source, bracket, "[", "]") < 0) {
        buffer_format(
            &error,
            "error[E2S148]: type `%s` has an unterminated parameter list "
            "at byte %" PRId64,
            name,
            bracket
        );
        free(name);
        return const_generic_refusal(&error);
    }
    int64_t keyword = skip_trivia(source, token_end(source, bracket));
    if (!token_equal(source, keyword, "const")) {
        buffer_format(
            &error,
            "error[E2S148]: type parameters on a nominal type are "
            "unsupported; `%s` may declare `[const NAME: Int]` only "
            "at byte %" PRId64,
            name,
            keyword
        );
        free(name);
        return const_generic_refusal(&error);
    }
    int64_t parameter = skip_trivia(source, token_end(source, keyword));
    if (strcmp(token_kind(source, parameter), "identifier") != 0) {
        buffer_format(
            &error,
            "error[E2S148]: const parameter of `%s` must be named "
            "at byte %" PRId64,
            name,
            parameter
        );
        free(name);
        return const_generic_refusal(&error);
    }
    char *parameter_name = token_copy(source, parameter);
    int64_t colon = skip_trivia(source, token_end(source, parameter));
    if (!token_equal(source, colon, ":")) {
        buffer_format(
            &error,
            "error[E2S148]: const parameter `%s` of `%s` requires a "
            "`: Int` annotation at byte %" PRId64,
            parameter_name,
            name,
            colon
        );
        free(parameter_name);
        free(name);
        return const_generic_refusal(&error);
    }
    int64_t annotation = skip_trivia(source, token_end(source, colon));
    if (!token_equal(source, annotation, "Int")) {
        char *annotation_text = token_copy(source, annotation);
        buffer_format(
            &error,
            "error[E2S148]: const parameter `%s` of `%s` has type `%s`; "
            "only `Int` const parameters exist at byte %" PRId64,
            parameter_name,
            name,
            annotation_text,
            annotation
        );
        free(annotation_text);
        free(parameter_name);
        free(name);
        return const_generic_refusal(&error);
    }
    int64_t after = skip_trivia(source, token_end(source, annotation));
    if (!token_equal(source, after, "]")) {
        buffer_format(
            &error,
            "error[E2S148]: type `%s` declares more than one parameter; "
            "exactly one const parameter is admissible at byte %" PRId64,
            name,
            after
        );
        free(parameter_name);
        free(name);
        return const_generic_refusal(&error);
    }
    if (!record_declaration_at(source, start)) {
        buffer_format(
            &error,
            "error[E2S148]: const parameters are admissible on a nominal "
            "record only; `%s` is not one at byte %" PRId64,
            name,
            bracket
        );
        free(parameter_name);
        free(name);
        return const_generic_refusal(&error);
    }
    free(parameter_name);
    free(name);
    free(error.data);
    return owned_text("");
}

static bool reserved_type_name(const char *name) {
    return strcmp(name, "Int") == 0 || strcmp(name, "Bool") == 0 ||
           strcmp(name, "Float") == 0 || strcmp(name, "Unit") == 0 ||
           strcmp(name, "Text") == 0 || strcmp(name, "List") == 0 ||
           strcmp(name, "_") == 0;
}

static char *function_return_type(const char *source, const char *wanted);
static char *function_return_type_at(
    const char *source,
    int64_t function_start
);
static char *function_parameter_type(
    const char *source,
    const char *wanted,
    int64_t index
);
static int64_t function_start_named(const char *source, const char *wanted);
static bool source_tokens_equal(
    const char *source,
    int64_t left,
    int64_t right
);
static int64_t lambda_scope_open(
    const char *source,
    int64_t function_open,
    int64_t target
);

static char *validate_const_arguments(const char *source);
static char *validate_const_erasure(const char *source);

/* Ownership mode is the optional first component of a parameter head. */
static bool ownership_mode_token(const char *source, int64_t cursor) {
    return token_equal(source, cursor, "read") ||
           token_equal(source, cursor, "edit") ||
           token_equal(source, cursor, "take");
}

/*
 * A word in a parameter head, which is an identifier *or* a keyword.
 *
 * The keyword half is not a nicety. `token_kind` returns "keyword" for the 16
 * words in `keyword_token`, and `in` is one of them — so counting only
 * identifiers made `fn replace(in text: Text, ...)` read as a single word and
 * no refusal fired. That signature is the contract's headline example, quoted
 * verbatim in `spec/syntax/call-arguments-v1.md`, and it reproduced the exact
 * misparse this check exists to remove:
 *
 *     error[E2S35]: unknown lexical binding `text` at byte 45
 *
 * `spec/modules/visibility.md` describes the same class of token for
 * visibility: these are contextual words, ordinary identifiers outside the
 * position that gives them meaning. A parameter head is such a position, so
 * `in`, `for`, `match` and the rest are legal external labels there — which is
 * also what `spec/syntax/call-arguments/parser.mjs` decides, and the two
 * profiles disagreeing about the spec's own example is the bug.
 *
 * The ownership modes are unaffected: `read`, `edit`, and `take` are not in
 * `keyword_token`, so they were already counted and `ownership_mode_token`
 * compares text rather than kind.
 */
static bool parameter_word_token(const char *source, int64_t cursor) {
    const char *kind = token_kind(source, cursor);
    return strcmp(kind, "identifier") == 0 || strcmp(kind, "keyword") == 0;
}

/* Parse one call-arguments-v1 parameter head without allocating. Every
 * semantic reader uses these offsets so ownership mode, external label, and
 * internal binding cannot drift between HIR, checking, and ABI projection. */
static int64_t parameter_internal_start(
    const char *source,
    int64_t cursor,
    int64_t limit
) {
    int64_t first = cursor;
    if (ownership_mode_token(source, first)) {
        first = skip_trivia(source, token_end(source, first));
    }
    if (first >= limit || !parameter_word_token(source, first)) return -1;
    int64_t after_first = skip_trivia(source, token_end(source, first));
    if (after_first < limit && token_equal(source, after_first, ":")) {
        return first;
    }
    if (after_first >= limit || !parameter_word_token(source, after_first)) {
        return -1;
    }
    int64_t colon = skip_trivia(source, token_end(source, after_first));
    return colon < limit && token_equal(source, colon, ":")
        ? after_first : -1;
}

/* The declared external label, or -1 for an unlabelled parameter. */
static int64_t parameter_external_start(
    const char *source,
    int64_t cursor,
    int64_t limit
) {
    int64_t first = ownership_mode_token(source, cursor)
        ? skip_trivia(source, token_end(source, cursor)) : cursor;
    int64_t internal = parameter_internal_start(source, cursor, limit);
    return internal >= 0 && first != internal ? first : -1;
}

static int64_t parameter_type_start(
    const char *source,
    int64_t cursor,
    int64_t limit
) {
    int64_t internal = parameter_internal_start(source, cursor, limit);
    if (internal < 0) return -1;
    int64_t colon = skip_trivia(source, token_end(source, internal));
    if (colon >= limit || !token_equal(source, colon, ":")) return -1;
    int64_t type = skip_trivia(source, token_end(source, colon));
    return type < limit ? type : -1;
}

/* The ownership slice predates general generic parameters but has a real
 * `List[Text]` parameter surface. Treat that bounded list annotation as one
 * type so a correct parameter-head parser does not stop at its `[` token. */
static int64_t parameter_list_type_end(
    const char *source,
    int64_t type,
    int64_t limit
) {
    if (type < 0 || !token_equal(source, type, "List")) return -1;
    int64_t open = skip_trivia(source, token_end(source, type));
    int64_t element = open < limit
        ? skip_trivia(source, token_end(source, open)) : -1;
    int64_t close = element >= 0 && element < limit
        ? skip_trivia(source, token_end(source, element)) : -1;
    return open < limit && token_equal(source, open, "[") &&
        element >= 0 && element < limit &&
        parameter_word_token(source, element) &&
        close >= 0 && close < limit && token_equal(source, close, "]")
        ? token_end(source, close) : -1;
}

static char *parameter_list_type_text(
    const char *source,
    int64_t type,
    int64_t limit
) {
    if (parameter_list_type_end(source, type, limit) < 0) {
        return owned_text("");
    }
    int64_t open = skip_trivia(source, token_end(source, type));
    int64_t element = skip_trivia(source, token_end(source, open));
    char *element_text = token_copy(source, element);
    Buffer text;
    buffer_init(&text);
    buffer_format(&text, "List[%s]", element_text);
    free(element_text);
    return text.data;
}

/* Preserve any constructed List annotation as one canonical type identity.
 * This is deliberately shape-only: lowering separately decides which element
 * types are supported, while Scope HIR must not split `List[T]` into bindings.
 */
static int64_t constructed_list_type_end(
    const char *source,
    int64_t type,
    int64_t limit
) {
    if (
        type < 0 || type >= limit || !token_equal(source, type, "List")
    ) {
        return -1;
    }
    int64_t open = skip_trivia(source, token_end(source, type));
    if (open >= limit || !token_equal(source, open, "[")) return -1;
    int64_t close = balanced_end(source, open, "[", "]");
    return close >= 0 && close <= limit ? close : -1;
}

static char *constructed_list_type_text(
    const char *source,
    int64_t type,
    int64_t limit
) {
    int64_t finish = constructed_list_type_end(source, type, limit);
    if (finish < 0) return owned_text("");
    Buffer text;
    buffer_init(&text);
    int64_t cursor = type;
    while (cursor < finish) {
        char *token = token_copy(source, cursor);
        buffer_append(&text, token);
        free(token);
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return text.data;
}

static char *trailing_lambda_refusal(const char *source, int64_t cursor) {
    Buffer error;
    buffer_init(&error);
    buffer_format(
        &error,
        "error[E2S158]: a trailing lambda is specified by call-arguments v1 but not "
        "implemented at byte %" PRId64,
        cursor
    );
    stage2_diagnostic_set(
        "E2S158",
        cursor,
        token_end(source, cursor),
        true,
        error.data
    );
    return error.data;
}

static char *validate_trailing_lambda_surface(const char *source) {
    int64_t length = source_length(source);

    /*
     * `) fn(` is the trailing form and nothing else in this profile's grammar.
     * A named declaration is `fn` and an identifier, so requiring `(` after
     * `fn` leaves `call()` followed by `fn next(...)` alone — which is the
     * boundary the contract draws in the same words. Measured on `dddffe0c`,
     * `grep -c ') fn(' bootstrap/stage1/compiler.kofun
     * bootstrap/stage2/compiler.kofun` is 0 in both, so no source this
     * compiler already accepts contains the shape.
     */
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (token_equal(source, cursor, ")")) {
            int64_t keyword = skip_trivia(source, token_end(source, cursor));
            if (keyword < length && token_equal(source, keyword, "fn")) {
                int64_t parameters = skip_trivia(
                    source,
                    token_end(source, keyword)
                );
                if (
                    parameters < length &&
                    token_equal(source, parameters, "(")
                ) {
                    return trailing_lambda_refusal(source, keyword);
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }

    return owned_text("");
}

static char *parse_program(const char *source) {
    /* #882 owns attachment/lowering; refuse before ordinary call analysis can
     * reinterpret the trailing lambda as a separate expression. */
    char *surface_check = validate_trailing_lambda_surface(source);
    if (strncmp(surface_check, "error[", 6) == 0) {
        return surface_check;
    }
    free(surface_check);
    /* Const generic surface (#916). Both checks run before any declaration is
     * recorded, so a refused source never reaches layout, IR, or an
     * artifact. */
    char *const_argument_check = validate_const_arguments(source);
    if (strncmp(const_argument_check, "error[", 6) == 0) {
        return const_argument_check;
    }
    free(const_argument_check);
    char *const_erasure_check = validate_const_erasure(source);
    if (strncmp(const_erasure_check, "error[", 6) == 0) {
        return const_erasure_check;
    }
    free(const_erasure_check);
    Buffer ir;
    Buffer declared_types;
    Buffer declared_constructors;
    buffer_init(&ir);
    buffer_init(&declared_types);
    buffer_init(&declared_constructors);
    buffer_append(&declared_types, "|");
    buffer_append(&declared_constructors, "|");
    int64_t length = source_length(source);
    buffer_format(&ir, "kofun-stage2-ir/v1\nsource-bytes|%" PRId64 "\n", length);
    stage2_parse_prefix_observe(&ir);
    int64_t cursor = skip_trivia(source, 0);
    int64_t functions = 0;
    int64_t types = 0;
    int64_t records = 0;
    int64_t record_fields = 0;
    int64_t constants = 0;
    while (cursor < length) {
        char *visibility_error = visibility_prefix_error(source, cursor);
        if (visibility_error[0] != '\0') {
            free(declared_types.data);
            free(declared_constructors.data);
            free(ir.data);
            return visibility_error;
        }
        free(visibility_error);
        int64_t declaration_start = cursor;
        int64_t type_start = type_declaration_start(source, declaration_start);
        if (type_start >= 0) {
            char *name = type_name(source, type_start);
            int64_t end = type_declaration_end(source, type_start);
            bool explicit_visibility = declaration_start != type_start;
            int64_t modifier_start = explicit_visibility ? declaration_start : -1;
            int64_t modifier_end = explicit_visibility ?
                token_end(source, declaration_start) : -1;
            char *parameter_list_error = type_parameter_list_error(
                source,
                type_start
            );
            if (parameter_list_error[0] != '\0') {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return parameter_list_error;
            }
            free(parameter_list_error);
            if (record_declaration_at(source, type_start)) {
                int64_t fields = record_field_count(source, name);
                Buffer error;
                buffer_init(&error);
                if (name[0] == '\0' || end < 0 || fields == -3) {
                    buffer_format(
                        &error,
                        "error[E2S32]: malformed nominal record declaration "
                        "at byte %" PRId64,
                        type_start
                    );
                } else if (fields == -2) {
                    buffer_format(
                        &error,
                        "error[E2S32]: record `%s` has a field type outside "
                        "the Stage 2 Int/Bool slice at byte %" PRId64,
                        name,
                        type_start
                    );
                } else if (fields == -4) {
                    buffer_format(
                        &error,
                        "error[E2S32]: nominal record field limit is 128 "
                        "per record at byte %" PRId64,
                        type_start
                    );
                } else if (reserved_type_name(name)) {
                    buffer_format(
                        &error,
                        "error[E2S32]: nominal record cannot shadow built-in "
                        "type `%s` at byte %" PRId64,
                        name,
                        type_start
                    );
                } else if (enum_name_covered(declared_types.data, name)) {
                    buffer_format(
                        &error,
                        "error[E2S32]: duplicate nominal aggregate type `%s` "
                        "at byte %" PRId64,
                        name,
                        type_start
                    );
                } else if (
                    enum_name_covered(declared_constructors.data, name)
                ) {
                    buffer_format(
                        &error,
                        "error[E2S32]: nominal record type `%s` conflicts "
                        "with an enum constructor at byte %" PRId64,
                        name,
                        cursor
                    );
                }
                ++records;
                record_fields += fields > 0 ? fields : 0;
                if (error.length == 0 && records > 16) {
                    buffer_format(
                        &error,
                        "error[E2S32]: nominal record limit is 16 types "
                        "at byte %" PRId64,
                        cursor
                    );
                }
                if (error.length == 0 && record_fields > 128) {
                    buffer_format(
                        &error,
                        "error[E2S32]: nominal record field limit is 128 "
                        "per module at byte %" PRId64,
                        cursor
                    );
                }
                if (error.length > 0) {
                    stage2_diagnostic_set(
                        "E2S32",
                        type_start,
                        token_end(source, type_start),
                        true,
                        error.data
                    );
                    free(name);
                    free(declared_types.data);
                    free(declared_constructors.data);
                    free(ir.data);
                    return const_generic_refusal(&error);
                }
                free(error.data);
                buffer_append(&declared_types, name);
                buffer_append(&declared_types, "|");
                buffer_format(
                    &ir,
                    "record|%s|%" PRId64 "|%" PRId64 "|%" PRId64
                    "|%s|%s|%" PRId64 "|%" PRId64 "\n",
                    name,
                    fields,
                    type_start,
                    end,
                    visibility_level(source, declaration_start),
                    explicit_visibility ? "explicit" : "implicit",
                    modifier_start,
                    modifier_end
                );
                for (int64_t index = 0; index < fields; ++index) {
                    char *field = record_field_text(
                        source,
                        name,
                        index,
                        false
                    );
                    char *field_type = record_field_text(
                        source,
                        name,
                        index,
                        true
                    );
                    buffer_format(
                        &ir,
                        "record-field|%s|%s|%s|%" PRId64 "\n",
                        name,
                        field,
                        field_type,
                        index
                    );
                    free(field);
                    free(field_type);
                }
                stage2_parse_prefix_observe(&ir);
                free(name);
                cursor = skip_trivia(source, end);
                continue;
            }
            if (end == -2) {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                ir.length = 0;
                ir.data[0] = '\0';
                buffer_format(
                    &ir,
                    "error[E2S31]: concrete enum constructor limit is 64 "
                    "at byte %" PRId64,
                    type_start
                );
                stage2_diagnostic_set(
                    "E2S31",
                    type_start,
                    token_end(source, type_start),
                    true,
                    ir.data
                );
                return ir.data;
            }
            if (name[0] == '\0' || end < 0) {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                ir.length = 0;
                ir.data[0] = '\0';
                buffer_format(
                    &ir,
                    "error[E2S31]: malformed concrete enum declaration "
                    "at byte %" PRId64,
                    type_start
                );
                stage2_diagnostic_set(
                    "E2S31",
                    type_start,
                    token_end(source, type_start),
                    true,
                    ir.data
                );
                return ir.data;
            }
            if (reserved_type_name(name)) {
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S31]: concrete enum cannot shadow built-in "
                    "type `%s` at byte %" PRId64,
                    name,
                    type_start
                );
                stage2_diagnostic_set(
                    "E2S31",
                    type_start,
                    token_end(source, type_start),
                    true,
                    error.data
                );
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return const_generic_refusal(&error);
            }
            ++types;
            if (types > 32) {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                ir.length = 0;
                ir.data[0] = '\0';
                buffer_format(
                    &ir,
                    "error[E2S31]: concrete enum limit is 32 types "
                    "at byte %" PRId64,
                    type_start
                );
                stage2_diagnostic_set(
                    "E2S31",
                    type_start,
                    token_end(source, type_start),
                    true,
                    ir.data
                );
                return ir.data;
            }
            if (enum_name_covered(declared_types.data, name)) {
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S31]: duplicate concrete enum type `%s` "
                    "at byte %" PRId64,
                    name,
                    cursor
                );
                stage2_diagnostic_set(
                    "E2S31",
                    cursor,
                    token_end(source, cursor),
                    true,
                    error.data
                );
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return const_generic_refusal(&error);
            }
            if (enum_name_covered(declared_constructors.data, name)) {
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S31]: concrete enum type `%s` conflicts "
                    "with a constructor at byte %" PRId64,
                    name,
                    cursor
                );
                stage2_diagnostic_set(
                    "E2S31",
                    cursor,
                    token_end(source, cursor),
                    true,
                    error.data
                );
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return const_generic_refusal(&error);
            }
            buffer_append(&declared_types, name);
            buffer_append(&declared_types, "|");
            int64_t count = enum_constructor_count(source, name);
            if (count < 1 || count > 64) {
                Buffer error;
                buffer_init(&error);
                if (count < 1) {
                    buffer_format(
                        &error,
                        "error[E2S31]: concrete enum must declare a "
                        "constructor at byte %" PRId64,
                        cursor
                    );
                } else {
                    buffer_format(
                        &error,
                        "error[E2S31]: concrete enum constructor limit is "
                        "64 at byte %" PRId64,
                        cursor
                    );
                }
                stage2_diagnostic_set(
                    "E2S31",
                    cursor,
                    token_end(source, cursor),
                    true,
                    error.data
                );
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return const_generic_refusal(&error);
            }
            buffer_format(
                &ir,
                "type|%s|%" PRId64 "|%" PRId64 "|%" PRId64
                "|%s|%s|%" PRId64 "|%" PRId64 "\n",
                name,
                count,
                type_start,
                end,
                visibility_level(source, declaration_start),
                explicit_visibility ? "explicit" : "implicit",
                modifier_start,
                modifier_end
            );
            int64_t name_cursor = skip_trivia(
                source,
                token_end(source, type_start)
            );
            int64_t equals = skip_trivia(
                source,
                token_end(source, name_cursor)
            );
            int64_t pipe = skip_trivia(source, token_end(source, equals));
            int64_t tag = 0;
            while (pipe < end && token_equal(source, pipe, "|")) {
                int64_t constructor = skip_trivia(
                    source,
                    token_end(source, pipe)
                );
                char *constructor_name = token_copy(source, constructor);
                if (strcmp(constructor_name, "_") == 0) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S31]: `_` is reserved for enum catch-all "
                        "patterns at byte %" PRId64,
                        constructor
                    );
                    stage2_diagnostic_set(
                        "E2S31",
                        constructor,
                        token_end(source, constructor),
                        true,
                        error.data
                    );
                    free(constructor_name);
                    free(name);
                    free(declared_types.data);
                    free(declared_constructors.data);
                    free(ir.data);
                    return const_generic_refusal(&error);
                }
                if (
                    enum_name_covered(
                        declared_constructors.data,
                        constructor_name
                    )
                ) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S31]: duplicate concrete enum constructor "
                        "`%s` at byte %" PRId64,
                        constructor_name,
                        constructor
                    );
                    stage2_diagnostic_set(
                        "E2S31",
                        constructor,
                        token_end(source, constructor),
                        true,
                        error.data
                    );
                    free(constructor_name);
                    free(name);
                    free(declared_types.data);
                    free(declared_constructors.data);
                    free(ir.data);
                    return const_generic_refusal(&error);
                }
                if (enum_name_covered(declared_types.data, constructor_name)) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S31]: concrete enum constructor `%s` "
                        "conflicts with an enum type at byte %" PRId64,
                        constructor_name,
                        constructor
                    );
                    stage2_diagnostic_set(
                        "E2S31",
                        constructor,
                        token_end(source, constructor),
                        true,
                        error.data
                    );
                    free(constructor_name);
                    free(name);
                    free(declared_types.data);
                    free(declared_constructors.data);
                    free(ir.data);
                    return const_generic_refusal(&error);
                }
                buffer_append(&declared_constructors, constructor_name);
                buffer_append(&declared_constructors, "|");
                int64_t payload_open = skip_trivia(
                    source,
                    token_end(source, constructor)
                );
                int64_t payload_count =
                    payload_open < end && token_equal(source, payload_open, "(") ?
                        1 : 0;
                char *payload_type = owned_text("");
                if (payload_count != 0) {
                    int64_t payload_name = skip_trivia(
                        source,
                        token_end(source, payload_open)
                    );
                    int64_t payload_colon = skip_trivia(
                        source,
                        token_end(source, payload_name)
                    );
                    int64_t payload_type_start = skip_trivia(
                        source,
                        token_end(source, payload_colon)
                    );
                    if (payload_type_start < end) {
                        free(payload_type);
                        payload_type = token_copy(source, payload_type_start);
                    }
                }
                buffer_format(
                    &ir,
                    "constructor|%s|%s|%" PRId64 "|%" PRId64
                    "|%" PRId64 "|%" PRId64 "|%s\n",
                    constructor_name,
                    name,
                    tag,
                    constructor,
                    token_end(source, constructor),
                    payload_count,
                    payload_type
                );
                free(payload_type);
                free(constructor_name);
                ++tag;
                pipe = skip_trivia(
                    source,
                    enum_constructor_token_end(source, constructor)
                );
            }
            stage2_parse_prefix_observe(&ir);
            free(name);
            cursor = skip_trivia(source, end);
        } else if (token_equal(source, cursor, "let")) {
            int64_t constant_close = constant_declaration_end(source, cursor);
            if (constant_close < 0) {
                int64_t after_let = skip_trivia(source, token_end(source, cursor));
                bool mutable_constant = token_equal(source, after_let, "mut");
                char *mutable_name = mutable_constant
                    ? token_copy(
                          source,
                          skip_trivia(source, token_end(source, after_let))
                      )
                    : owned_text("");
                free(declared_types.data);
                free(declared_constructors.data);
                ir.length = 0;
                ir.data[0] = '\0';
                if (mutable_constant) {
                    buffer_format(
                        &ir,
                        "error[E2S161]: module constant `%s` cannot be `mut`; "
                        "a top-level `let` is immutable at byte %" PRId64,
                        mutable_name,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S161",
                        cursor,
                        token_end(source, cursor),
                        true,
                        ir.data
                    );
                } else {
                    buffer_format(
                        &ir,
                        "error[E2S159]: module constant must be "
                        "`let NAME = <integer literal>` at byte %" PRId64,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S159",
                        cursor,
                        token_end(source, cursor),
                        true,
                        ir.data
                    );
                }
                free(mutable_name);
                return ir.data;
            }
            char *constant = constant_name(source, cursor);
            bool duplicate = constant_declaration_count(source, constant) > 1;
            bool clashes = false;
            if (!duplicate) {
                clashes =
                    enum_name_covered(declared_types.data, constant) ||
                    enum_name_covered(declared_constructors.data, constant) ||
                    function_arity(source, constant) >= 0;
            }
            if (duplicate || clashes) {
                ir.length = 0;
                ir.data[0] = '\0';
                if (duplicate) {
                    buffer_format(
                        &ir,
                        "error[E2S160]: duplicate module constant `%s` "
                        "at byte %" PRId64,
                        constant,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S160",
                        cursor,
                        token_end(source, cursor),
                        true,
                        ir.data
                    );
                } else {
                    buffer_format(
                        &ir,
                        "error[E2S159]: module constant `%s` conflicts with a "
                        "declaration of the same name at byte %" PRId64,
                        constant,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S159",
                        cursor,
                        token_end(source, cursor),
                        true,
                        ir.data
                    );
                }
                free(constant);
                free(declared_types.data);
                free(declared_constructors.data);
                return ir.data;
            }
            char *constant_value = constant_value_text(source, cursor);
            ++constants;
            buffer_format(
                &ir,
                "constant|%s|%s|%" PRId64 "|%" PRId64 "\n",
                constant,
                constant_value,
                cursor,
                constant_close
            );
            stage2_parse_prefix_observe(&ir);
            free(constant_value);
            free(constant);
            cursor = skip_trivia(source, constant_close);
        } else if (function_declaration_start(source, cursor) < 0) {
            free(declared_types.data);
            free(declared_constructors.data);
            ir.length = 0;
            ir.data[0] = '\0';
            buffer_format(
                &ir,
                "error[E2S02]: expected top-level `fn`, `type`, or `let` "
                "at byte %" PRId64,
                cursor
            );
            stage2_diagnostic_set(
                "E2S02",
                cursor,
                token_end(source, cursor),
                true,
                ir.data
            );
            return ir.data;
        } else {
            int64_t declaration_start = cursor;
            int64_t function_start = function_declaration_start(
                source,
                declaration_start
            );
            char *name = function_name(source, function_start);
            int64_t arity = parameter_count(source, function_start);
            int64_t end = function_end(source, function_start);
            if (name[0] == '\0' || arity < 0 || end < 0) {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                ir.length = 0;
                ir.data[0] = '\0';
                buffer_format(
                    &ir,
                    "error[E2S03]: malformed function at byte %" PRId64,
                    function_start
                );
                stage2_diagnostic_set(
                    "E2S03",
                    function_start,
                    function_start,
                    true,
                    ir.data
                );
                return ir.data;
            }
            char *local_error = local_visibility_error(
                source,
                function_start,
                end
            );
            if (local_error[0] != '\0') {
                free(name);
                free(declared_types.data);
                free(declared_constructors.data);
                free(ir.data);
                return local_error;
            }
            free(local_error);
            bool explicit_visibility = declaration_start != function_start;
            int64_t modifier_start = explicit_visibility ? declaration_start : -1;
            int64_t modifier_end = explicit_visibility ?
                token_end(source, declaration_start) : -1;
            buffer_format(
                &ir,
                "function|%s|%" PRId64 "|%" PRId64 "|%" PRId64
                "|%s|%s|%" PRId64 "|%" PRId64 "|%" PRId64
                "|%" PRId64 "|file:0|symbol:%" PRId64 "\n",
                name,
                arity,
                function_start,
                end,
                visibility_level(source, declaration_start),
                explicit_visibility ? "explicit" : "implicit",
                modifier_start,
                modifier_end,
                declaration_start,
                end,
                functions
            );
            if (stage2_active_declaration_observer != NULL) {
                char *return_type = function_return_type_at(
                    source,
                    function_start
                );
                stage2_declaration_observe(
                    "function|%s|%" PRId64 "|%" PRId64 "|%s\n",
                    name,
                    function_start,
                    end,
                    return_type
                );
                free(return_type);
            }
            stage2_parse_prefix_observe(&ir);
            free(name);
            ++functions;
            cursor = skip_trivia(source, end);
        }
    }
    free(declared_types.data);
    free(declared_constructors.data);
    if (functions == 0) {
        ir.length = 0;
        ir.data[0] = '\0';
        buffer_append(&ir, "error[E2S04]: compilation unit has no functions");
        stage2_diagnostic_set("E2S04", 0, 0, false, ir.data);
        return ir.data;
    }
    buffer_format(&ir, "function-count|%" PRId64 "\n", functions);
    buffer_format(&ir, "constant-count|%" PRId64 "\n", constants);
    char *patterns = parse_pattern_trees(source);
    char *pattern_error = pattern_first_error(patterns);
    if (pattern_error[0] != '\0') {
        free(patterns);
        free(ir.data);
        return pattern_error;
    }
    free(pattern_error);
    buffer_append(&ir, patterns);
    free(patterns);
    return ir.data;
}

static char *owned_text(const char *text) {
    size_t length = strlen(text);
    char *copy = allocate(length + 1);
    memcpy(copy, text, length + 1);
    return copy;
}

static char *enum_constructor_owner(
    const char *source,
    const char *wanted
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0) {
            char *enum_type = type_name(source, type_start);
            if (enum_constructor_index(source, enum_type, wanted) >= 0) {
                return enum_type;
            }
            free(enum_type);
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return owned_text("");
        cursor = skip_trivia(source, end);
    }
    return owned_text("");
}

/*
 * A bare constructor-shaped name must keep the historical E2S32 unknown-name
 * diagnostic. General patterns distinguish fresh value bindings from
 * constructor names lexically: an ASCII-uppercase head is constructor-shaped,
 * while a declared lowercase constructor is still recognized by its symbol.
 */
static bool enum_binding_catchall_name(const char *name) {
    return name[0] != '\0' && !(name[0] >= 'A' && name[0] <= 'Z');
}

static char *enum_declaration_names(
    const char *source,
    bool constructors
) {
    int64_t length = source_length(source);
    Buffer names;
    buffer_init(&names);
    buffer_append(&names, "|");
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0) {
            if (constructors) {
                int64_t type_cursor = skip_trivia(
                    source,
                    token_end(source, type_start)
                );
                int64_t equals = skip_trivia(
                    source,
                    token_end(source, type_cursor)
                );
                int64_t pipe = skip_trivia(
                    source,
                    token_end(source, equals)
                );
                int64_t end = type_declaration_end(source, type_start);
                while (pipe < end && token_equal(source, pipe, "|")) {
                    int64_t constructor = skip_trivia(
                        source,
                        token_end(source, pipe)
                    );
                    char *name = token_copy(source, constructor);
                    buffer_append(&names, name);
                    buffer_append(&names, "|");
                    free(name);
                    pipe = skip_trivia(
                        source,
                        enum_constructor_token_end(source, constructor)
                    );
                }
            } else {
                char *name = type_name(source, type_start);
                buffer_append(&names, name);
                buffer_append(&names, "|");
                free(name);
            }
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return names.data;
        cursor = skip_trivia(source, end);
    }
    return names.data;
}

static bool copy_type(const char *type_name) {
    return strcmp(type_name, "Int") == 0 ||
           strcmp(type_name, "Float") == 0 ||
           strcmp(type_name, "Bool") == 0 ||
           strcmp(type_name, "Unit") == 0;
}

static int64_t return_move_at(
    const char *source,
    int64_t body_open,
    int64_t body_end,
    const char *element_name
) {
    int64_t cursor = skip_trivia(source, token_end(source, body_open));
    while (cursor < body_end) {
        if (token_equal(source, cursor, "return")) {
            int64_t return_line = line_at(source, cursor);
            int64_t value_cursor = skip_trivia(
                source,
                token_end(source, cursor)
            );
            while (
                value_cursor < body_end &&
                line_at(source, value_cursor) == return_line
            ) {
                if (token_equal(source, value_cursor, element_name)) {
                    return value_cursor;
                }
                value_cursor = skip_trivia(
                    source,
                    token_end(source, value_cursor)
                );
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return -1;
}

static char *borrowed_collection_check(const char *source) {
    int64_t length = source_length(source);
    int64_t function_cursor = next_function_start(source, 0);
    int64_t recognized_loops = 0;
    while (function_cursor < length) {
        int64_t parameters_open = parameter_open(source, function_cursor);
        if (parameters_open < 0) {
            char *error = owned_text("error[E2S03]: malformed function");
            stage2_diagnostic_set("E2S03", 0, 0, false, error);
            return error;
        }
        int64_t parameters_end = balanced_end(
            source,
            parameters_open,
            "(",
            ")"
        );
        if (parameters_end < 0) {
            char *error = owned_text("error[E2S03]: malformed parameters");
            stage2_diagnostic_set("E2S03", 0, 0, false, error);
            return error;
        }

        char *borrowed_name = owned_text("");
        char *element_type = owned_text("");
        int64_t borrowed_lists = 0;
        int64_t parameter_cursor = skip_trivia(
            source,
            token_end(source, parameters_open)
        );
        while (
            parameter_cursor < parameters_end &&
            !token_equal(source, parameter_cursor, ")")
        ) {
            if (token_equal(source, parameter_cursor, "read")) {
                int64_t name_cursor = parameter_internal_start(
                    source,
                    parameter_cursor,
                    parameters_end
                );
                int64_t list_cursor = parameter_type_start(
                    source,
                    parameter_cursor,
                    parameters_end
                );
                int64_t bracket_cursor = list_cursor < 0 ? -1
                    : skip_trivia(source, token_end(source, list_cursor));
                int64_t element_cursor = bracket_cursor < 0 ? -1
                    : skip_trivia(source, token_end(source, bracket_cursor));
                if (
                    name_cursor >= 0 &&
                    list_cursor >= 0 && bracket_cursor >= 0 &&
                    element_cursor >= 0 &&
                    strcmp(token_kind(source, name_cursor), "identifier") == 0 &&
                    token_equal(source, list_cursor, "List") &&
                    token_equal(source, bracket_cursor, "[") &&
                    strcmp(token_kind(source, element_cursor), "identifier") == 0
                ) {
                    ++borrowed_lists;
                    if (borrowed_lists > 1) {
                        char *error = owned_text(
                            "error[E2S21]: ownership slice supports one "
                            "borrowed List parameter per function"
                        );
                        free(element_type);
                        free(borrowed_name);
                        stage2_diagnostic_set("E2S21", 0, 0, false, error);
                        return error;
                    }
                    free(borrowed_name);
                    free(element_type);
                    borrowed_name = token_copy(source, name_cursor);
                    element_type = token_copy(source, element_cursor);
                }
            }
            parameter_cursor = skip_trivia(
                source,
                token_end(source, parameter_cursor)
            );
        }

        int64_t function_end_cursor = function_end(source, function_cursor);
        if (function_end_cursor < 0) {
            char *error = owned_text(
                "error[E2S03]: malformed function body"
            );
            free(element_type);
            free(borrowed_name);
            stage2_diagnostic_set("E2S03", 0, 0, false, error);
            return error;
        }
        int64_t body_open = skip_trivia(source, parameters_end);
        while (
            body_open < function_end_cursor &&
            !token_equal(source, body_open, "{")
        ) {
            body_open = skip_trivia(source, token_end(source, body_open));
        }
        if (body_open >= function_end_cursor) {
            char *error = owned_text(
                "error[E2S03]: malformed function body"
            );
            free(element_type);
            free(borrowed_name);
            stage2_diagnostic_set("E2S03", 0, 0, false, error);
            return error;
        }

        int64_t cursor = skip_trivia(source, token_end(source, body_open));
        while (cursor < function_end_cursor) {
            if (token_equal(source, cursor, "for")) {
                int64_t element_cursor = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                int64_t in_cursor = skip_trivia(
                    source,
                    token_end(source, element_cursor)
                );
                int64_t collection_cursor = skip_trivia(
                    source,
                    token_end(source, in_cursor)
                );
                int64_t loop_open = skip_trivia(
                    source,
                    token_end(source, collection_cursor)
                );
                if (
                    strcmp(token_kind(source, element_cursor), "identifier") == 0 &&
                    token_equal(source, in_cursor, "in") &&
                    strcmp(token_kind(source, collection_cursor), "identifier") == 0 &&
                    token_equal(source, loop_open, "{")
                ) {
                    int64_t loop_end = balanced_end(
                        source,
                        loop_open,
                        "{",
                        "}"
                    );
                    if (loop_end < 0) {
                        char *error = owned_text(
                            "error[E2S03]: malformed for body"
                        );
                        free(element_type);
                        free(borrowed_name);
                        stage2_diagnostic_set(
                            "E2S03",
                            0,
                            0,
                            false,
                            error
                        );
                        return error;
                    }
                    if (
                        borrowed_name[0] != '\0' &&
                        token_equal(source, collection_cursor, borrowed_name)
                    ) {
                        ++recognized_loops;
                        char *element_name = token_copy(source, element_cursor);
                        int64_t move_at = return_move_at(
                            source,
                            loop_open,
                            loop_end,
                            element_name
                        );
                        if (move_at >= 0 && !copy_type(element_type)) {
                            Buffer error;
                            buffer_init(&error);
                            buffer_format(
                                &error,
                                "error[E007]: cannot move non-Copy element "
                                "`%s: %s` out of borrowed collection `%s` "
                                "at line %" PRId64 "; return a Copy scalar "
                                "or clone the element",
                                element_name,
                                element_type,
                                borrowed_name,
                                line_at(source, move_at)
                            );
                            stage2_diagnostic_set(
                                "E007",
                                move_at,
                                token_end(source, move_at),
                                true,
                                error.data
                            );
                            stage2_diagnostic_remedy(1u);
                            free(element_name);
                            free(element_type);
                            free(borrowed_name);
                            return error.data;
                        }
                        free(element_name);
                    }
                }
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        free(element_type);
        free(borrowed_name);
        function_cursor = next_function_start(source, function_end_cursor);
    }
    if (recognized_loops == 0) {
        char *error = owned_text(
            "error[E2S20]: Stage 2 ownership slice requires "
            "`for element in read_list`"
        );
        stage2_diagnostic_set("E2S20", 0, 0, false, error);
        return error;
    }
    return owned_text("ok");
}

static int64_t expression_end(const char *source, int64_t start);
static int64_t arithmetic_expression_end(
    const char *source,
    int64_t start
);
static int64_t enclosing_function_open(const char *source, int64_t position);
static const char *numeric_primary_type(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t start
);
static bool text_operand(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t start
);
static char *numeric_conversion_at(const char *source, int64_t cursor);
static const char *numeric_conversion_result(const char *conversion);
static int64_t numeric_member_argument(
    const char *source,
    int64_t open,
    int64_t wanted
);
static bool decimal_rounding_mode_name(const char *name);
static const char *decimal_rounding_c_name(const char *name);
static char *emit_arithmetic_expression(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
);
static char *emit_expression(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
);
static char *optional_int_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
);
static char *emit_primary(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
);
static char *emit_list_int_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    bool allow_literal
);
static char *initializer_type(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t initializer
);
static int64_t hir_binding_declaration_start(
    const char *hir,
    const char *binding_id
);
static bool source_has_list_int_local(const char *source);
static char *lower_error(
    const char *code,
    const char *message,
    int64_t cursor
);
/*
 * #924: the Optional(Int) spelling test, plus the two judgements
 * `emit_primary` needs. The section that answers them — and the
 * AggregateLayout v1 descriptor it reads its bytes from — is below
 * `condition_end`.
 */
#define OPTIONAL_INT_C_TYPE "KofunOptionalInt"
#define LIST_INT_CAPACITY 64

/*
 * `Int` followed by exactly one `?`, which is the only optional type this
 * slice lowers. Returns the byte after the `?`, or -1. `Int??` leaves the
 * second `?` where the caller's own grammar reports it, so a second layer is
 * refused rather than silently collapsed.
 */
static int64_t optional_int_type_end(const char *source, int64_t type_start) {
    int64_t length = source_length(source);
    if (type_start >= length) return -1;
    if (!token_equal(source, type_start, "Int")) return -1;
    int64_t suffix = skip_trivia(source, token_end(source, type_start));
    if (suffix >= length || !token_equal(source, suffix, "?")) return -1;
    return token_end(source, suffix);
}

/*
 * Whether any declaration in the program annotates `Int` with a `?` suffix.
 * The layered spelling counts too — `??` is one token, so `Int??` would
 * otherwise look like a program with no optional in it, and the refusal that
 * names it would never be reached.
 */
static bool scan_optional_int_annotation(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (token_equal(source, cursor, "??")) return true;
        if (
            token_equal(source, cursor, ":") ||
            token_equal(source, cursor, "->")
        ) {
            int64_t type_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            if (token_equal(source, type_start, "Int")) {
                int64_t suffix = skip_trivia(
                    source,
                    token_end(source, type_start)
                );
                if (
                    token_equal(source, suffix, "?") ||
                    token_equal(source, suffix, "??")
                ) {
                    return true;
                }
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

/* Memoized on the source address, exactly as `source_length` is: every
 * Optional judgement below starts by asking it, so a program with no `Int?`
 * in it pays one token scan for the whole compilation instead of one per
 * binding read. */
static const char *optional_int_source_text;
static bool optional_int_source_value;
static bool optional_int_source_known;

static bool source_uses_optional_int(const char *source) {
    if (optional_int_source_known && source == optional_int_source_text) {
        return optional_int_source_value;
    }
    optional_int_source_text = source;
    optional_int_source_value = scan_optional_int_annotation(source);
    optional_int_source_known = true;
    return optional_int_source_value;
}

static bool optional_int_binding(
    const char *source,
    int64_t position,
    const char *name
);
static bool optional_int_carrier_position(const char *source, int64_t at);
static char *hir_use_binding_id(const char *hir, int64_t use_start);
static char *hir_definition_id_at(
    const char *hir,
    int64_t declaration_start
);
static int64_t lambda_initializer_open(
    const char *source,
    int64_t value_start
);
static int64_t lambda_binding_open(
    const char *source,
    const char *hir,
    const char *binding_id
);
static char *lambda_captures(
    const char *source,
    const char *hir,
    int64_t lambda_open
);
static void append_captures(
    Buffer *output,
    const char *captures,
    int64_t written,
    const char *declaration
);
static int64_t lambda_call_arity(
    const char *source,
    const char *hir,
    int64_t use_start
);
static char *hir_binding_field(
    const char *hir,
    const char *binding_id,
    int field
);
static int64_t lambda_parameters_end(
    const char *source,
    int64_t previous,
    int64_t open
);
static int64_t callable_parameter_type_start(
    const char *source,
    const char *hir,
    const char *binding_id
);
static int64_t callable_call_arity(
    const char *source,
    const char *hir,
    int64_t use_start
);
static int64_t function_arity(const char *source, const char *wanted);
static char *enum_constructor_owner(const char *source, const char *name);
static char *source_slice(const char *source, int64_t start, int64_t end);

/*
 * The byte after a callable type beginning at `start`, or -1 when the tokens
 * there are not one.
 *
 * #552 settled the notation and this Core implements exactly it: `A -> R` for
 * one argument, `(A, B) -> R` for a fixed arity of two or more, and `() -> R`
 * for none. There is no implicit currying, so `A -> B -> R` is not a two-
 * argument callable; it is a one-argument callable returning another, which
 * this Core has no value to represent and therefore does not accept.
 *
 * `Int` is the only type in every domain and result position, because `Int` is
 * the whole type vocabulary a Core parameter has. A callable naming any other
 * type is not a callable type here, so the caller reports it as an ordinary
 * unsupported parameter type rather than as a malformed callable.
 */
static int64_t callable_type_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length) return -1;
    int64_t after_domain = -1;
    if (token_equal(source, cursor, "(")) {
        int64_t close = balanced_end(source, cursor, "(", ")");
        if (close < 0) return -1;
        int64_t element = skip_trivia(source, token_end(source, cursor));
        while (element < close && !token_equal(source, element, ")")) {
            if (!token_equal(source, element, "Int")) return -1;
            int64_t separator = skip_trivia(source, token_end(source, element));
            if (separator < close && token_equal(source, separator, ",")) {
                element = skip_trivia(source, token_end(source, separator));
            } else {
                element = separator;
            }
        }
        after_domain = close;
    } else if (token_equal(source, cursor, "Int")) {
        after_domain = token_end(source, cursor);
    } else {
        return -1;
    }
    int64_t arrow = skip_trivia(source, after_domain);
    if (arrow >= length || !token_equal(source, arrow, "->")) return -1;
    int64_t result = skip_trivia(source, token_end(source, arrow));
    if (result >= length || !token_equal(source, result, "Int")) return -1;
    return token_end(source, result);
}

/*
 * The argument count of the callable type at `start`, or -1 when there is not
 * one there. The bare domain `A -> R` is one argument by construction; a
 * parenthesised domain counts its elements, so `() -> R` is zero.
 */
static int64_t callable_type_arity(const char *source, int64_t start) {
    if (callable_type_end(source, start) < 0) return -1;
    int64_t cursor = skip_trivia(source, start);
    if (!token_equal(source, cursor, "(")) return 1;
    int64_t close = balanced_end(source, cursor, "(", ")");
    if (close < 0) return -1;
    int64_t count = 0;
    int64_t element = skip_trivia(source, token_end(source, cursor));
    while (element < close && !token_equal(source, element, ")")) {
        ++count;
        int64_t separator = skip_trivia(source, token_end(source, element));
        if (separator < close && token_equal(source, separator, ",")) {
            element = skip_trivia(source, token_end(source, separator));
        } else {
            element = separator;
        }
    }
    return count;
}

/*
 * `int64_t (*NAME)(int64_t, ...)` for the callable type at `start`. Every
 * value this Core lowers is an `int64_t`, so a callable is a plain C function
 * pointer and needs no environment; that is exactly why a capturing lambda
 * cannot be one, and `validate_argument_lambda_captures` refuses those.
 */
static char *callable_c_declarator(
    const char *source,
    int64_t start,
    const char *name
) {
    int64_t arity = callable_type_arity(source, start);
    if (arity < 0) return owned_text("");
    Buffer output;
    buffer_init(&output);
    buffer_format(&output, "int64_t (*%s)(", name);
    if (arity == 0) {
        buffer_append(&output, "void");
    } else {
        for (int64_t written = 0; written < arity; ++written) {
            if (written > 0) buffer_append(&output, ", ");
            buffer_append(&output, "int64_t");
        }
    }
    buffer_append(&output, ")");
    return output.data;
}

/*
 * The arrow spelling of the removed `Fn[...]` notation whose `[` is at
 * `open`, or "" when the brackets do not close.
 *
 * #552 settled one spelling for both positions, and every normative document
 * requires a *targeted* rewrite rather than a bare rejection. The last
 * bracket element is the result and the rest are the domain, so `Fn[R]` is
 * `() -> R`, `Fn[A, R]` is `A -> R`, and a historical multi-argument
 * `Fn[A, B, R]` is `(A, B) -> R`. Nested brackets are skipped whole, which is
 * what keeps `Fn[Int, List[Int]]` from splitting inside `List[Int]`.
 */
static char *removed_callable_rewrite(const char *source, int64_t open) {
    int64_t close = balanced_end(source, open, "[", "]");
    if (close < 0) return owned_text("");
    Buffer domain;
    buffer_init(&domain);
    char *result = owned_text("");
    int64_t count = 0;
    int64_t element = skip_trivia(source, token_end(source, open));
    while (element < close && !token_equal(source, element, "]")) {
        int64_t element_start = element;
        int64_t element_end = element;
        while (
            element < close &&
            !token_equal(source, element, ",") &&
            !token_equal(source, element, "]")
        ) {
            if (token_equal(source, element, "[")) {
                int64_t nested = balanced_end(source, element, "[", "]");
                if (nested < 0) {
                    free(domain.data);
                    free(result);
                    return owned_text("");
                }
                element_end = nested;
            } else {
                element_end = token_end(source, element);
            }
            element = skip_trivia(source, element_end);
        }
        if (count > 0) {
            if (domain.length > 0) buffer_append(&domain, ", ");
            buffer_append(&domain, result);
        }
        free(result);
        result = source_slice(source, element_start, element_end);
        ++count;
        if (element < close && token_equal(source, element, ",")) {
            element = skip_trivia(source, token_end(source, element));
        }
    }
    Buffer output;
    buffer_init(&output);
    if (count == 0) {
        free(domain.data);
        free(result);
        free(output.data);
        return owned_text("");
    }
    if (count == 1) {
        buffer_format(&output, "() -> %s", result);
    } else if (count == 2) {
        buffer_format(&output, "%s -> %s", domain.data, result);
    } else {
        buffer_format(&output, "(%s) -> %s", domain.data, result);
    }
    free(domain.data);
    free(result);
    return output.data;
}

/*
 * `Fn[...]` is the callable notation #552 removed. `Fn` stays an ordinary
 * identifier, so only `Fn` immediately followed by `[` is the removed type.
 */
/* Records the structured form of a const generic refusal before returning it.
 *
 * The semantic producer must agree with the authority on the diagnostic as
 * well as on the exit class; a refusal that skipped this made the producer
 * report a tooling failure instead of the error the compiler printed. Both the
 * code and the byte are read back out of the formatted message, so the
 * structured diagnostic and the printed one cannot disagree. */
static char *const_generic_refusal(Buffer *error) {
    char code[32];
    const char *close;
    const char *marker;
    size_t width;
    int64_t position = -1;
    if (error->data == NULL || strncmp(error->data, "error[", 6) != 0) {
        return error->data;
    }
    close = strchr(error->data, ']');
    if (close == NULL) return error->data;
    width = (size_t)(close - (error->data + 6));
    if (width == 0 || width >= sizeof(code)) return error->data;
    memcpy(code, error->data + 6, width);
    code[width] = '\0';
    marker = strstr(error->data, " at byte ");
    if (marker != NULL) {
        position = (int64_t)strtoll(marker + 9, NULL, 10);
    }
    stage2_diagnostic_set(
        code,
        position,
        position,
        position >= 0,
        error->data
    );
    return error->data;
}

/* The leading-zero-stripped digits of a const argument. Normalization is by
 * value, not by digits, so `Fixed[02]` and `Fixed[2]` are one type. */
static char *const_argument_digits(const char *literal) {
    size_t width = strlen(literal);
    size_t index = 0;
    while (index + 1 < width && literal[index] == '0') ++index;
    return owned_text(literal + index);
}

static bool const_digit_greater(char actual, char allowed) {
    const char *digits = "0123456789";
    const char *found_actual = strchr(digits, actual);
    const char *found_allowed = strchr(digits, allowed);
    if (found_actual == NULL || found_allowed == NULL) return false;
    return found_actual > found_allowed;
}

/* A const parameter is a type-level integer, not a machine integer, so its
 * budget is a declared ceiling rather than a host width. Exceeding it is
 * refused and never wrapped, clamped, or truncated. Comparing equal-width
 * digit strings position by position is exactly numeric comparison, which is
 * why no integer parse is needed here. */
static bool const_argument_over_budget(const char *digits) {
    const char *limit = "65535";
    size_t width = strlen(digits);
    size_t limit_width = strlen(limit);
    if (width > limit_width) return true;
    if (width < limit_width) return false;
    for (size_t index = 0; index < width; ++index) {
        if (digits[index] != limit[index]) {
            return const_digit_greater(digits[index], limit[index]);
        }
    }
    return false;
}

/* The text of a type annotation, carrying its normalized const argument when
 * the head names a const-parameterized type.
 *
 * Returning only the head token here is what would erase `Fixed[2]` into
 * `Fixed`, making every scale one type. This is the single place an
 * instantiation becomes a type identity, so every comparison downstream
 * distinguishes the scales without knowing they exist. */
static char *annotation_type_text(const char *source, int64_t type_start) {
    int64_t length = source_length(source);
    char *head = token_copy(source, type_start);
    char *parameter = const_parameter_of_type(source, head);
    bool parameterized = parameter[0] != '\0';
    free(parameter);
    if (!parameterized) return head;
    int64_t bracket = skip_trivia(source, token_end(source, type_start));
    if (bracket >= length || !token_equal(source, bracket, "[")) return head;
    int64_t argument = skip_trivia(source, token_end(source, bracket));
    if (
        argument >= length ||
        strcmp(token_kind(source, argument), "integer") != 0
    ) {
        return head;
    }
    char *literal = token_copy(source, argument);
    char *digits = const_argument_digits(literal);
    Buffer text;
    buffer_init(&text);
    buffer_format(&text, "%s[%s]", head, digits);
    free(digits);
    free(literal);
    free(head);
    return text.data;
}

/* The end offset of a type annotation, including its const argument. Walking
 * past only the head token here is what would leave `[2]` in the stream for
 * the next parser step to trip over. */
static int64_t annotation_type_end(const char *source, int64_t type_start) {
    int64_t length = source_length(source);
    char *head = token_copy(source, type_start);
    char *parameter = const_parameter_of_type(source, head);
    bool parameterized = parameter[0] != '\0';
    free(parameter);
    free(head);
    if (!parameterized) return token_end(source, type_start);
    int64_t bracket = skip_trivia(source, token_end(source, type_start));
    if (bracket >= length || !token_equal(source, bracket, "[")) {
        return token_end(source, type_start);
    }
    int64_t close = balanced_end(source, bracket, "[", "]");
    if (close < 0) return token_end(source, type_start);
    return close;
}

/* The declaration a type identity names, with any const argument removed. */
static char *const_type_base(const char *annotation) {
    const char *bracket = strchr(annotation, '[');
    if (bracket == NULL) return owned_text(annotation);
    size_t width = (size_t)(bracket - annotation);
    char *base = allocate(width + 1);
    memcpy(base, annotation, width);
    base[width] = '\0';
    return base;
}

/* True at the type name of the declaration itself, which is the one position
 * where a const-parameterized name legitimately carries no argument. */
static bool const_generic_declaration_head(
    const char *source,
    int64_t position
) {
    int64_t length = source_length(source);
    int64_t cursor = after_optional_module_header(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (
            type_start >= 0 &&
            skip_trivia(source, token_end(source, type_start)) == position
        ) {
            return true;
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return false;
        cursor = skip_trivia(source, end);
    }
    return false;
}

/* Every `NAME[...]` whose head is a const-parameterized type must supply one
 * non-negative integer literal inside the declared budget. Const expressions,
 * const inference, and arithmetic on a type-level value are out of scope, so a
 * non-literal argument is refused here rather than partially resolved. */
static char *validate_const_arguments(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            char *head = token_copy(source, cursor);
            char *parameter = const_parameter_of_type(source, head);
            int64_t bracket = skip_trivia(source, token_end(source, cursor));
            Buffer error;
            buffer_init(&error);
            if (
                parameter[0] != '\0' &&
                const_generic_declaration_head(source, cursor)
            ) {
                /* The declaration's own parameter list is a binder, not an
                 * argument; `type_parameter_list_error` owns its shape. */
                free(error.data);
                free(parameter);
                free(head);
                cursor = skip_trivia(source, token_end(source, cursor));
                continue;
            }
            if (
                parameter[0] != '\0' &&
                bracket < length &&
                token_equal(source, bracket, "[")
            ) {
                int64_t close = balanced_end(source, bracket, "[", "]");
                if (close < 0) {
                    buffer_format(
                        &error,
                        "error[E2S150]: unterminated const argument list "
                        "for `%s` at byte %" PRId64,
                        head,
                        bracket
                    );
                    free(parameter);
                    free(head);
                    return const_generic_refusal(&error);
                }
                int64_t argument = skip_trivia(
                    source,
                    token_end(source, bracket)
                );
                if (token_equal(source, argument, "-")) {
                    buffer_format(
                        &error,
                        "error[E2S149]: const argument to `%s` is negative; "
                        "`%s: Int` admits `0`..`65535` only "
                        "at byte %" PRId64,
                        head,
                        parameter,
                        argument
                    );
                    free(parameter);
                    free(head);
                    return const_generic_refusal(&error);
                }
                if (strcmp(token_kind(source, argument), "integer") != 0) {
                    buffer_format(
                        &error,
                        "error[E2S149]: const argument to `%s` is not an "
                        "integer literal; const expressions are out of "
                        "scope at byte %" PRId64,
                        head,
                        argument
                    );
                    free(parameter);
                    free(head);
                    return const_generic_refusal(&error);
                }
                char *literal = token_copy(source, argument);
                char *digits = const_argument_digits(literal);
                bool over = const_argument_over_budget(digits);
                free(digits);
                free(literal);
                if (over) {
                    buffer_format(
                        &error,
                        "error[E2S149]: const argument to `%s` exceeds the budget "
                        "`0`..`65535`; it is refused, not wrapped "
                        "at byte %" PRId64,
                        head,
                        argument
                    );
                    free(parameter);
                    free(head);
                    return const_generic_refusal(&error);
                }
                int64_t after = skip_trivia(
                    source,
                    token_end(source, argument)
                );
                if (!token_equal(source, after, "]")) {
                    buffer_format(
                        &error,
                        "error[E2S150]: `%s` declares one const parameter "
                        "and accepts exactly one argument at byte %" PRId64,
                        head,
                        after
                    );
                    free(parameter);
                    free(head);
                    return const_generic_refusal(&error);
                }
                cursor = skip_trivia(source, close);
                free(error.data);
                free(parameter);
                free(head);
                continue;
            }
            if (
                parameter[0] != '\0' &&
                !const_generic_declaration_head(source, cursor)
            ) {
                buffer_format(
                    &error,
                    "error[E2S150]: `%s` expects one const argument; write "
                    "`%s[...]` at byte %" PRId64,
                    head,
                    head,
                    cursor
                );
                free(parameter);
                free(head);
                return const_generic_refusal(&error);
            }
            free(error.data);
            free(parameter);
            free(head);
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

/* The executable form of the premise that lets every instantiation of one
 * declaration share a single lowering: a const argument contributes no
 * storage, so it must never reach layout or code generation.
 *
 * A record field typed by an instantiation is the route that would break it —
 * the field would put the argument inside a struct, and one shared struct
 * would then be a miscompile across two types the checker has already made
 * distinct. Refusing it here means the premise fails loudly the day it stops
 * holding, instead of a struct being quietly shared. */
static char *validate_const_erasure(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = after_optional_module_header(source, 0);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0 && record_declaration_at(source, type_start)) {
            int64_t equals = type_equals_token(source, type_start);
            int64_t open = skip_trivia(source, token_end(source, equals));
            int64_t close = balanced_end(source, open, "{", "}");
            if (close < 0) return owned_text("ok");
            int64_t field = skip_trivia(source, token_end(source, open));
            while (field < close && !token_equal(source, field, "}")) {
                int64_t colon = skip_trivia(source, token_end(source, field));
                int64_t field_type = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                if (field_type < close) {
                    char *field_type_text = token_copy(source, field_type);
                    char *parameter = const_parameter_of_type(
                        source,
                        field_type_text
                    );
                    bool parameterized = parameter[0] != '\0';
                    free(parameter);
                    free(field_type_text);
                    if (parameterized) {
                        char *field_name = token_copy(source, field);
                        char *owner = type_name(source, type_start);
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S148]: field `%s` of `%s` is a const generic "
                            "instantiation; a const argument must not "
                            "reach layout at byte %" PRId64,
                            field_name,
                            owner,
                            field_type
                        );
                        free(owner);
                        free(field_name);
                        return const_generic_refusal(&error);
                    }
                }
                int64_t separator = skip_trivia(
                    source,
                    token_end(source, field_type)
                );
                if (separator < close && token_equal(source, separator, ",")) {
                    field = skip_trivia(source, token_end(source, separator));
                } else {
                    field = separator;
                }
            }
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) return owned_text("ok");
        cursor = skip_trivia(source, end);
    }
    return owned_text("ok");
}

static char *validate_removed_callable_notation(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (
            token_equal(source, cursor, "Fn") &&
            strcmp(token_kind(source, cursor), "identifier") == 0
        ) {
            int64_t bracket = skip_trivia(source, token_end(source, cursor));
            if (bracket < length && token_equal(source, bracket, "[")) {
                char *rewrite = removed_callable_rewrite(source, bracket);
                if (rewrite[0] != '\0') {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "error[E2S97]: `Fn[...]` is not a callable type "
                        "at byte %" PRId64 "; write `%s`",
                        cursor,
                        rewrite
                    );
                    free(rewrite);
                    stage2_diagnostic_set(
                        "E2S97",
                        cursor,
                        token_end(source, cursor),
                        true,
                        message.data
                    );
                    return message.data;
                }
                free(rewrite);
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

/*
 * Whether `target` is a whole argument of a call.
 *
 * A bare function name is a value only here. Restricting it to argument
 * position is what keeps `double + 1` an ordinary unknown-binding error: a
 * function name that reached the Int expression grammar would lower to a
 * function address inside integer arithmetic and surface as a C type error
 * instead of a Kofun diagnostic.
 *
 * Two conditions, and both are needed. The token before `target` opens or
 * continues an argument list — a `(` that itself follows an identifier, so a
 * parenthesised group does not qualify, or a `,`. And the token after
 * `target` closes or continues it, so `double` in `print(double + 1)` is
 * excluded while `double` in `apply(double, 21)` is not.
 */
static bool call_argument_position(const char *source, int64_t target) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    int64_t previous = -1;
    int64_t before_previous = -1;
    while (cursor < target && cursor < length) {
        before_previous = previous;
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (cursor != target || previous < 0) return false;
    int64_t after = skip_trivia(source, token_end(source, target));
    if (after >= length) return false;
    if (!token_equal(source, after, ",") && !token_equal(source, after, ")")) {
        return false;
    }
    if (token_equal(source, previous, "(")) {
        return before_previous >= 0 &&
               strcmp(token_kind(source, before_previous), "identifier") == 0;
    }
    return token_equal(source, previous, ",");
}

/*
 * The byte after an argument, which is either an ordinary bounded expression
 * or an arrow lambda passed directly.
 *
 * Only argument position needs this. An argument's preceding token is `(` or
 * `,`, never an identifier, so the constructor-pattern ambiguity that
 * `lambda_parameters_end` guards with its `previous` parameter cannot arise
 * here and -1 is the correct `previous` to pass.
 */
static int64_t argument_end(const char *source, int64_t start) {
    int64_t lambda_end = lambda_parameters_end(source, -1, start);
    if (lambda_end >= 0) return lambda_end;
    int64_t label = skip_trivia(source, start);
    if (parameter_word_token(source, label)) {
        int64_t colon = skip_trivia(source, token_end(source, label));
        if (token_equal(source, colon, ":")) {
            int64_t value = skip_trivia(source, token_end(source, colon));
            if (
                token_equal(source, value, "true") ||
                token_equal(source, value, "false")
            ) {
                return token_end(source, value);
            }
            return expression_end(source, value);
        }
    }
    return expression_end(source, start);
}

/* Label binding is complete in checked HIR, but ABI-temporary lowering is the
 * downstream #882 slice. Keep that backend boundary explicit. */
static bool call_has_labelled_argument(const char *source, int64_t open) {
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return false;
    int64_t argument = skip_trivia(source, token_end(source, open));
    while (argument < close && !token_equal(source, argument, ")")) {
        if (parameter_word_token(source, argument)) {
            int64_t colon = skip_trivia(
                source,
                token_end(source, argument)
            );
            if (colon < close && token_equal(source, colon, ":")) return true;
        }
        int64_t end = argument_end(source, argument);
        if (end < 0) return false;
        int64_t separator = skip_trivia(source, end);
        if (separator < close && token_equal(source, separator, ",")) {
            argument = skip_trivia(source, token_end(source, separator));
        } else {
            return false;
        }
    }
    return false;
}

/*
 * Expected type of the call argument beginning exactly at `target`.
 *
 * The older `call_argument_position` predicate is intentionally cheap and
 * handles single-token function values.  Enum constructors are calls
 * themselves (`Ready(8)`), so their first token is not followed by `,` or `)`.
 * This bounded walk finds the enclosing named call and returns its declared
 * parameter type without confusing the constructor's own parentheses for the
 * outer call.
 */
static char *call_argument_expected_type(
    const char *source,
    int64_t target
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < target && cursor < length) {
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            int64_t open = skip_trivia(
                source,
                token_end(source, cursor)
            );
            if (open < target && token_equal(source, open, "(")) {
                int64_t close = balanced_end(source, open, "(", ")");
                if (close > target) {
                    int64_t argument = skip_trivia(
                        source,
                        token_end(source, open)
                    );
                    int64_t positional_index = 0;
                    while (
                        argument < close &&
                        !token_equal(source, argument, ")")
                    ) {
                        int64_t label = -1;
                        int64_t value = argument;
                        if (parameter_word_token(source, argument)) {
                            int64_t colon = skip_trivia(
                                source,
                                token_end(source, argument)
                            );
                            if (colon < close && token_equal(source, colon, ":")) {
                                label = argument;
                                value = skip_trivia(
                                    source,
                                    token_end(source, colon)
                                );
                            }
                        }
                        if (argument == target || value == target) {
                            char *callee = token_copy(source, cursor);
                            int64_t slot = positional_index;
                            if (label >= 0) {
                                int64_t declaration = function_start_named(
                                    source,
                                    callee
                                );
                                int64_t parameters = parameter_open(
                                    source,
                                    declaration
                                );
                                int64_t parameters_end = parameters < 0
                                    ? -1 : balanced_end(
                                        source,
                                        parameters,
                                        "(",
                                        ")"
                                    );
                                int64_t parameter = parameters < 0
                                    ? -1 : skip_trivia(
                                        source,
                                        token_end(source, parameters)
                                    );
                                slot = 0;
                                while (
                                    parameter >= 0 &&
                                    parameter < parameters_end &&
                                    !token_equal(source, parameter, ")")
                                ) {
                                    int64_t external = parameter_external_start(
                                        source,
                                        parameter,
                                        parameters_end
                                    );
                                    if (
                                        external >= 0 &&
                                        source_tokens_equal(
                                            source,
                                            label,
                                            external
                                        )
                                    ) {
                                        break;
                                    }
                                    int64_t type = parameter_type_start(
                                        source,
                                        parameter,
                                        parameters_end
                                    );
                                    int64_t type_end = callable_type_end(
                                        source,
                                        type
                                    );
                                    int64_t optional_end =
                                        optional_int_type_end(source, type);
                                    int64_t list_end = parameter_list_type_end(
                                        source,
                                        type,
                                        parameters_end
                                    );
                                    if (type_end < 0) type_end =
                                        optional_end >= 0 ? optional_end
                                            : (list_end >= 0 ? list_end
                                                : annotation_type_end(
                                                    source,
                                                    type
                                                ));
                                    if (type_end <= parameter) break;
                                    int64_t separator = skip_trivia(
                                        source,
                                        type_end
                                    );
                                    int64_t next = separator < parameters_end &&
                                        token_equal(source, separator, ",")
                                        ? skip_trivia(
                                            source,
                                            token_end(source, separator)
                                        ) : separator;
                                    if (next <= parameter) break;
                                    parameter = next;
                                    ++slot;
                                }
                            }
                            char *type = function_parameter_type(
                                source,
                                callee,
                                slot
                            );
                            free(callee);
                            return type;
                        }
                        int64_t end = argument_end(source, argument);
                        if (end < 0) break;
                        int64_t separator = skip_trivia(source, end);
                        if (
                            separator < close &&
                            token_equal(source, separator, ",")
                        ) {
                            argument = skip_trivia(
                                source,
                                token_end(source, separator)
                            );
                            if (label < 0) ++positional_index;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("");
}

/*
 * The lifted name of an arrow lambda written directly in argument position.
 *
 * A `let`-bound lambda is keyed by its binding id, which an anonymous argument
 * does not have. Its keying token's byte offset is the identity that is
 * already unique and already stable across the two walks that must agree —
 * the one that emits the definition and the one that emits the reference.
 */
static char *argument_lambda_name(int64_t open) {
    Buffer output;
    buffer_init(&output);
    buffer_format(&output, "kofun_lambda_at%" PRId64, open);
    return output.data;
}

static int64_t field_postfix_end(
    const char *source,
    int64_t primary
) {
    int64_t length = (int64_t)strlen(source);
    int64_t dot = skip_trivia(source, primary);
    if (
        dot < length && token_equal(source, dot, "[") &&
        source_has_list_int_local(source)
    ) {
        return balanced_end(source, dot, "[", "]");
    }
    if (dot >= length || !token_equal(source, dot, ".")) return primary;
    int64_t field = skip_trivia(source, token_end(source, dot));
    if (
        field >= length ||
        strcmp(token_kind(source, field), "identifier") != 0
    ) {
        return -1;
    }
    return token_end(source, field);
}

/* `List[Int]` is one binding type, never the three unrelated tokens that the
 * historical single-token reader exposed to lexical resolution. */
static int64_t list_int_type_end(const char *source, int64_t type_start) {
    int64_t length = source_length(source);
    if (type_start >= length || !token_equal(source, type_start, "List")) {
        return -1;
    }
    int64_t open = skip_trivia(source, token_end(source, type_start));
    int64_t element = skip_trivia(source, token_end(source, open));
    int64_t close = skip_trivia(source, token_end(source, element));
    if (
        open >= length || !token_equal(source, open, "[") ||
        element >= length || !token_equal(source, element, "Int") ||
        close >= length || !token_equal(source, close, "]")
    ) {
        return -1;
    }
    return token_end(source, close);
}

static bool source_has_list_int_local(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            int64_t after = skip_trivia(source, token_end(source, name));
            if (after < length && token_equal(source, after, ":")) {
                int64_t type_start = skip_trivia(
                    source,
                    token_end(source, after)
                );
                int64_t type_finish = list_int_type_end(source, type_start);
                if (type_finish >= 0) return true;
                after = skip_trivia(source, token_end(source, type_start));
            }
            if (after < length && token_equal(source, after, "=")) {
                int64_t value = skip_trivia(
                    source,
                    token_end(source, after)
                );
                if (value < length && token_equal(source, value, "[")) {
                    return true;
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

/* Count the elements in one bracketed literal. Each element is one bounded
 * expression; semantic element typing is checked after the scope HIR exists. */
static int64_t list_int_literal_count(
    const char *source,
    int64_t open,
    int64_t *bad
) {
    int64_t length = source_length(source);
    int64_t element = skip_trivia(source, token_end(source, open));
    int64_t count = 0;
    if (bad != NULL) *bad = open;
    if (open >= length || !token_equal(source, open, "[")) return -1;
    if (element < length && token_equal(source, element, "]")) return 0;
    while (element < length) {
        int64_t bound = expression_end(source, element);
        if (bound < 0) {
            if (bad != NULL) *bad = element;
            return -1;
        }
        ++count;
        int64_t separator = skip_trivia(source, bound);
        if (separator >= length) {
            if (bad != NULL) *bad = separator;
            return -1;
        }
        if (token_equal(source, separator, "]")) return count;
        if (!token_equal(source, separator, ",")) {
            if (bad != NULL) *bad = separator;
            return -1;
        }
        element = skip_trivia(source, token_end(source, separator));
    }
    return -1;
}

/* Every identifier inside a constructed local List annotation is declaration
 * syntax, not a lexical read. Keeping this local-only preserves #919's
 * boundary: parameters and results still reach their lowering diagnostics. */
static bool list_int_local_type_token(
    const char *source,
    int64_t target
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor <= target && cursor < length) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            int64_t colon = skip_trivia(source, token_end(source, name));
            if (colon < length && token_equal(source, colon, ":")) {
                int64_t type_start = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                int64_t type_finish = constructed_list_type_end(
                    source,
                    type_start,
                    length
                );
                if (type_finish >= 0) {
                    if (target >= type_start && target < type_finish) {
                        return true;
                    }
                    cursor = skip_trivia(source, type_finish);
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static char *validate_list_int_annotations(const char *source) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = balanced_end(
            source,
            parameters,
            "(",
            ")"
        );
        int64_t parameter = skip_trivia(
            source,
            token_end(source, parameters)
        );
        while (
            parameter < parameters_close &&
            !token_equal(source, parameter, ")")
        ) {
            int64_t type_start = parameter_type_start(
                source,
                parameter,
                parameters_close
            );
            if (type_start < 0) break;
            if (
                ownership_mode_token(source, parameter) &&
                list_int_type_end(source, type_start) >= 0
            ) {
                return lower_error(
                    "E2S157",
                    "List[Int] function parameters support only the immutable "
                    "copy mode",
                    parameter
                );
            }
            if (
                token_equal(source, type_start, "List") &&
                list_int_type_end(source, type_start) < 0
            ) {
                return lower_error(
                    "E2S157",
                    "Stage 2 function list signatures require exactly List[Int]",
                    type_start
                );
            }
            int64_t type_end = parameter_list_type_end(
                source,
                type_start,
                parameters_close
            );
            if (type_end < 0) {
                type_end = annotation_type_end(source, type_start);
            }
            int64_t separator = skip_trivia(source, type_end);
            parameter = separator < parameters_close &&
                token_equal(source, separator, ",")
                ? skip_trivia(source, token_end(source, separator))
                : separator;
        }
        int64_t after = skip_trivia(source, parameters_close);
        if (after < length && token_equal(source, after, "->")) {
            int64_t result = skip_trivia(source, token_end(source, after));
            if (
                token_equal(source, result, "List") &&
                list_int_type_end(source, result) < 0
            ) {
                return lower_error(
                    "E2S157",
                    "Stage 2 function list signatures require exactly List[Int]",
                    result
                );
            }
        }
        function_start = next_function_start(
            source,
            function_end(source, function_start)
        );
    }
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            int64_t colon = skip_trivia(source, token_end(source, name));
            if (colon < length && token_equal(source, colon, ":")) {
                int64_t type_start = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                if (
                    token_equal(source, type_start, "List") &&
                    list_int_type_end(source, type_start) < 0
                ) {
                    return lower_error(
                        "E2S157",
                        "Stage 2 local lists require exactly List[Int]",
                        type_start
                    );
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

static int64_t primary_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length) return -1;
    const char *kind = token_kind(source, cursor);
    /*
     * A bracketed list literal. Spanning it is not the same as supporting it:
     * `List[Int]` is still not a Core binding type, and the type check refuses
     * the value further on. But a span that stops here makes `argument_end`
     * return -1, and a call whose argument cannot be measured is reported as
     * `expects 1 arguments, got -1` — a shape the source never had. Measuring
     * the literal lets the refusal name the real boundary instead.
     */
    if (token_equal(source, cursor, "[")) {
        int64_t element = skip_trivia(source, token_end(source, cursor));
        if (element < length && token_equal(source, element, "]")) {
            return field_postfix_end(source, token_end(source, element));
        }
        while (element < length) {
            int64_t bound = expression_end(source, element);
            int64_t separator;
            if (bound < 0) return -1;
            separator = skip_trivia(source, bound);
            if (separator >= length) return -1;
            if (token_equal(source, separator, "]")) {
                return field_postfix_end(
                    source,
                    token_end(source, separator)
                );
            }
            if (!token_equal(source, separator, ",")) return -1;
            element = skip_trivia(source, token_end(source, separator));
        }
        return -1;
    }
    if (
        strcmp(kind, "integer") == 0 ||
        strcmp(kind, "decimal") == 0 ||
        strcmp(kind, "float") == 0 ||
        strcmp(kind, "string") == 0
    ) {
        return field_postfix_end(source, token_end(source, cursor));
    }
    if (strcmp(kind, "identifier") == 0) {
        char *conversion = numeric_conversion_at(source, cursor);
        if (conversion[0] != '\0') {
            int64_t dot = skip_trivia(source, token_end(source, cursor));
            int64_t member = skip_trivia(source, token_end(source, dot));
            int64_t open = skip_trivia(source, token_end(source, member));
            int64_t argument = skip_trivia(source, token_end(source, open));
            free(conversion);
            if (argument < length && token_equal(source, argument, ")")) {
                return field_postfix_end(
                    source,
                    token_end(source, argument)
                );
            }
            while (argument < length) {
                int64_t bound = argument_end(source, argument);
                int64_t separator;
                if (bound < 0) return -1;
                separator = skip_trivia(source, bound);
                if (
                    separator < length &&
                    token_equal(source, separator, ")")
                ) {
                    return field_postfix_end(
                        source,
                        token_end(source, separator)
                    );
                }
                if (
                    separator >= length ||
                    !token_equal(source, separator, ",")
                ) {
                    return -1;
                }
                argument = skip_trivia(
                    source,
                    token_end(source, separator)
                );
            }
            return -1;
        }
        free(conversion);
        int64_t open = skip_trivia(source, token_end(source, cursor));
        if (open >= length || !token_equal(source, open, "(")) {
            return field_postfix_end(source, token_end(source, cursor));
        }
        int64_t argument = skip_trivia(source, token_end(source, open));
        if (argument < length && token_equal(source, argument, ")")) {
            return field_postfix_end(
                source,
                token_end(source, argument)
            );
        }
        while (argument < length) {
            int64_t bound = argument_end(source, argument);
            if (bound < 0) return -1;
            int64_t separator = skip_trivia(source, bound);
            if (separator < length && token_equal(source, separator, ")")) {
                return field_postfix_end(
                    source,
                    token_end(source, separator)
                );
            }
            if (separator >= length || !token_equal(source, separator, ",")) {
                return -1;
            }
            argument = skip_trivia(source, token_end(source, separator));
        }
        return -1;
    }
    if (token_equal(source, cursor, "(")) {
        int64_t value_start = skip_trivia(source, token_end(source, cursor));
        int64_t value_end = expression_end(source, value_start);
        if (value_end < 0) return -1;
        int64_t close = skip_trivia(source, value_end);
        if (close >= length || !token_equal(source, close, ")")) return -1;
        return field_postfix_end(source, token_end(source, close));
    }
    return -1;
}

static int64_t unary_end(const char *source, int64_t start) {
    int64_t cursor = skip_trivia(source, start);
    if (token_equal(source, cursor, "+") || token_equal(source, cursor, "-")) {
        return unary_end(source, skip_trivia(source, token_end(source, cursor)));
    }
    return primary_end(source, cursor);
}

static int64_t product_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = unary_end(source, start);
    if (cursor < 0) return -1;
    int64_t operator_start = skip_trivia(source, cursor);
    while (
        operator_start < length &&
        (token_equal(source, operator_start, "*") ||
         token_equal(source, operator_start, "/") ||
         token_equal(source, operator_start, "//") ||
         token_equal(source, operator_start, "%"))
    ) {
        int64_t right_start = skip_trivia(
            source,
            token_end(source, operator_start)
        );
        cursor = unary_end(source, right_start);
        if (cursor < 0) return -1;
        operator_start = skip_trivia(source, cursor);
    }
    return cursor;
}

static int64_t arithmetic_expression_end(
    const char *source,
    int64_t start
) {
    int64_t length = source_length(source);
    int64_t cursor = product_end(source, start);
    if (cursor < 0) return -1;
    int64_t operator_start = skip_trivia(source, cursor);
    while (
        operator_start < length &&
        (token_equal(source, operator_start, "+") ||
         token_equal(source, operator_start, "-"))
    ) {
        int64_t right_start = skip_trivia(
            source,
            token_end(source, operator_start)
        );
        cursor = product_end(source, right_start);
        if (cursor < 0) return -1;
        operator_start = skip_trivia(source, cursor);
    }
    return cursor;
}

/* The bounded coalescing operator has lower precedence than arithmetic. The
 * operator byte is also the deterministic identity of its function-local C
 * carrier. */
static int64_t optional_int_coalescing_operator(
    const char *source,
    int64_t start,
    int64_t end
) {
    int64_t left_end = arithmetic_expression_end(source, start);
    if (left_end < 0) return -1;
    int64_t operator_start = skip_trivia(source, left_end);
    return operator_start < end && token_equal(source, operator_start, "??")
        ? operator_start
        : -1;
}

static int64_t expression_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t left_end = arithmetic_expression_end(source, start);
    if (left_end < 0) return -1;
    int64_t operator_start = skip_trivia(source, left_end);
    if (
        operator_start >= length ||
        !token_equal(source, operator_start, "??")
    ) {
        return left_end;
    }
    int64_t right_start = skip_trivia(
        source,
        token_end(source, operator_start)
    );
    return arithmetic_expression_end(source, right_start);
}

/* Strip only parentheses enclosing the complete left expression. Returning
 * either inner bound keeps the accepted shapes exact while making ordinary
 * primary-expression parentheses transparent. */
static int64_t optional_int_coalescing_transparent_bound(
    const char *source,
    int64_t start,
    int64_t end,
    bool want_start
) {
    int64_t cursor = skip_trivia(source, start);
    int64_t bound = end;
    bool scanning = true;
    while (
        scanning && cursor < bound && token_equal(source, cursor, "(")
    ) {
        int64_t inner_start = skip_trivia(
            source,
            token_end(source, cursor)
        );
        int64_t inner_end = expression_end(source, inner_start);
        int64_t close = inner_end < 0 ? -1 : skip_trivia(source, inner_end);
        if (
            inner_end < 0 ||
            close >= bound ||
            !token_equal(source, close, ")") ||
            skip_trivia(source, token_end(source, close)) < bound
        ) {
            scanning = false;
        } else {
            cursor = inner_start;
            bound = inner_end;
        }
    }
    return want_start ? cursor : bound;
}

static char *source_slice(const char *source, int64_t start, int64_t end) {
    if (end < start) end = start;
    size_t length = (size_t)(end - start);
    char *value = allocate(length + 1);
    memcpy(value, source + start, length);
    value[length] = '\0';
    return value;
}

static char *c_identifier_name(const char *identifier) {
    bool ascii = true;
    for (size_t index = 0; identifier[index] != '\0'; ++index) {
        if ((unsigned char)identifier[index] >= UINT8_C(0x80)) {
            ascii = false;
            break;
        }
    }
    if (ascii) return owned_text(identifier);

    Buffer output;
    buffer_init(&output);
    buffer_append(&output, "k");
    size_t length = strlen(identifier);
    size_t cursor = 0;
    while (cursor < length) {
        uint32_t codepoint = 0;
        size_t width = 0;
        if (!kofun_unicode_decode(
                (const uint8_t *)identifier,
                length,
                cursor,
                &codepoint,
                &width)) {
            free(output.data);
            return owned_text("k_invalid");
        }
        buffer_format(&output, "_u%06" PRIX32, codepoint);
        cursor += width;
    }
    return output.data;
}

/* The const argument of a type identity, or "" when it has none. */
static char *const_argument_of(const char *identity) {
    const char *open = strchr(identity, '[');
    size_t width;
    char *argument;
    if (open == NULL) return owned_text("");
    width = strlen(open + 1);
    if (width == 0) return owned_text("");
    argument = allocate(width);
    memcpy(argument, open + 1, width - 1);
    argument[width - 1] = '\0';
    return argument;
}

/* The single funnel from a type identity to a C struct name, and the place
 * per-literal monomorphization actually happens: one emitted struct per
 * distinct literal, so `Fixed[2]` and `Fixed[3]` are two C types.
 *
 * An earlier revision dropped the argument here and justified it in a comment —
 * a const parameter contributes no storage, so one struct was said to be safe.
 * That was a true statement about miscompiles standing in for an untrue one
 * about the backend's capability: it made the C type system stop separating
 * what the Kofun type system had already separated, while
 * `tests/conformance/capabilities.tsv` claimed the backend did not support the
 * construct at all. `validate_struct_identity` now refuses that collapse
 * instead of a comment asserting it is fine. */
static char *record_c_type_name(const char *record_type) {
    char *base = const_type_base(record_type);
    char *argument = const_argument_of(record_type);
    char *name = c_identifier_name(base);
    Buffer output;
    buffer_init(&output);
    if (argument[0] == '\0') {
        buffer_format(&output, "KofunRecord_%s", name);
    } else {
        buffer_format(&output, "KofunRecord_%s__%s", name, argument);
    }
    free(name);
    free(argument);
    free(base);
    return output.data;
}

/* The `index`-th distinct instantiation of `wanted`, in first-use order, or
 * "". This is the monomorphization set the emitter walks. */
static char *const_instantiation_at(
    const char *source,
    const char *wanted,
    int64_t wanted_index
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    int64_t count = 0;
    Buffer seen;
    buffer_init(&seen);
    buffer_append(&seen, "|");
    while (cursor < length) {
        if (
            strcmp(token_kind(source, cursor), "identifier") == 0 &&
            token_equal(source, cursor, wanted) &&
            !const_generic_declaration_head(source, cursor)
        ) {
            char *identity = annotation_type_text(source, cursor);
            if (
                strcmp(identity, wanted) != 0 &&
                !enum_name_covered(seen.data, identity)
            ) {
                if (count == wanted_index) {
                    free(seen.data);
                    return identity;
                }
                buffer_append(&seen, identity);
                buffer_append(&seen, "|");
                ++count;
            }
            free(identity);
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    free(seen.data);
    return owned_text("");
}

static int64_t const_instantiation_count(
    const char *source,
    const char *wanted
) {
    int64_t count = 0;
    for (;;) {
        char *identity = const_instantiation_at(source, wanted, count);
        bool present = identity[0] != '\0';
        free(identity);
        if (!present) return count;
        ++count;
    }
}

static char *record_c_field_name(const char *field) {
    char *name = c_identifier_name(field);
    Buffer output;
    buffer_init(&output);
    buffer_format(&output, "f_%s", name);
    free(name);
    return output.data;
}

static char *record_field_type_named(
    const char *source,
    const char *record_type,
    const char *field
) {
    int64_t index = record_field_index(source, record_type, field);
    if (index < 0) return owned_text("");
    return record_field_text(source, record_type, index, true);
}

static char *format_two(const char *name, const char *left, const char *right) {
    Buffer output;
    buffer_init(&output);
    buffer_format(&output, "%s(%s, %s)", name, left, right);
    return output.data;
}

static char *emit_record_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *record_type
) {
    int64_t cursor = skip_trivia(source, start);
    if (strcmp(token_kind(source, cursor), "identifier") != 0) {
        return lower_error(
            "E2S32",
            "nominal record value must be a binding or function call",
            cursor
        );
    }
    char *name = token_copy(source, cursor);
    int64_t open = skip_trivia(source, token_end(source, cursor));
    /* A bare binding has to be the *whole* value. Accepting a prefix silently
     * dropped the rest: `takes_record(value.field)` lowered to `value`, so an
     * `Int` field read compiled and ran as the record it was read from, with
     * no diagnostic anywhere. Anything left unconsumed that is not a call is
     * not a record value in this slice. */
    if (open < end && !token_equal(source, open, "(")) {
        free(name);
        return lower_error(
            "E2S32",
            "nominal record value must be a whole binding or function call",
            cursor
        );
    }
    if (open >= end) {
        char *binding_id = hir_use_binding_id(hir, cursor);
        char *binding_type = hir_binding_field(hir, binding_id, 5);
        if (
            binding_id[0] == '\0' ||
            strcmp(binding_type, record_type) != 0
        ) {
            /* Two instantiations of one const generic declaration are not a
             * generic record mismatch, they are a mismatch *in the const
             * argument*, so they say which scales disagreed. */
            if (binding_id[0] != '\0') {
                char *actual_base = const_type_base(binding_type);
                char *wanted_base = const_type_base(record_type);
                bool same_declaration =
                    strcmp(actual_base, wanted_base) == 0;
                free(wanted_base);
                free(actual_base);
                if (same_declaration) {
                    Buffer detail;
                    buffer_init(&detail);
                    buffer_format(
                        &detail,
                        "`%s` is not `%s`; instantiations differing only in "
                        "their const argument are different types",
                        binding_type,
                        record_type
                    );
                    free(binding_type);
                    free(binding_id);
                    free(name);
                    char *message = lower_error("E2S151", detail.data, cursor);
                    free(detail.data);
                    return message;
                }
            }
            free(binding_type);
            free(binding_id);
            free(name);
            return lower_error(
                "E2S32",
                "nominal record binding has the wrong type",
                cursor
            );
        }
        Buffer output;
        buffer_init(&output);
        buffer_format(&output, "k_b%s", binding_id);
        free(binding_type);
        free(binding_id);
        free(name);
        return output.data;
    }
    if (record_declaration_start(source, name) >= 0) {
        free(name);
        return lower_error(
            "E2S32",
            "bind record construction before passing or returning it",
            cursor
        );
    }
    char *return_type = function_return_type(source, name);
    if (strcmp(return_type, record_type) == 0) {
        char *output = emit_primary(source, hir, cursor, end);
        free(return_type);
        free(name);
        return output;
    }
    free(return_type);
    free(name);
    return lower_error(
        "E2S32",
        "call does not return the expected nominal record",
        cursor
    );
}

/*
 * Lower one value of the bounded concrete-enum representation.
 *
 * The representation is intentionally uniform for every concrete enum in
 * this slice: declaration-order tag plus one Int payload slot.  Static typing
 * keeps values of different enum declarations from crossing a boundary, while
 * the common internal C shape lets ordinary functions pass and return them
 * without publishing a per-type ABI.
 */
static char *emit_enum_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *enum_type
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (
        cursor >= length ||
        strcmp(token_kind(source, cursor), "identifier") != 0
    ) {
        return lower_error(
            "E2S32",
            "concrete enum value must be a constructor, binding, or call",
            cursor
        );
    }
    char *name = token_copy(source, cursor);
    int64_t open = skip_trivia(source, token_end(source, cursor));
    /* Same whole-value rule as `emit_record_value`: a bare binding may not be
     * a prefix of a larger expression. */
    if (open < end && !token_equal(source, open, "(")) {
        free(name);
        return lower_error(
            "E2S32",
            "concrete enum value must be a whole binding, constructor, or call",
            cursor
        );
    }
    if (open >= end) {
        char *binding_id = hir_use_binding_id(hir, cursor);
        char *binding_type = hir_binding_field(hir, binding_id, 5);
        if (
            binding_id[0] == '\0' ||
            strcmp(binding_type, enum_type) != 0
        ) {
            free(binding_type);
            free(binding_id);
            free(name);
            return lower_error(
                "E2S32",
                "concrete enum binding has the wrong type",
                cursor
            );
        }
        Buffer output;
        buffer_init(&output);
        buffer_format(&output, "k_b%s", binding_id);
        free(binding_type);
        free(binding_id);
        free(name);
        return output.data;
    }

    char *constructor_owner = enum_constructor_owner(source, name);
    if (constructor_owner[0] != '\0') {
        if (strcmp(constructor_owner, enum_type) != 0) {
            free(constructor_owner);
            free(name);
            return lower_error(
                "E2S32",
                "constructor belongs to a different concrete enum",
                cursor
            );
        }
        int64_t tag = enum_constructor_index(source, enum_type, name);
        int64_t arity = enum_constructor_payload_arity(
            source,
            enum_type,
            name
        );
        if (arity < 0) {
            free(constructor_owner);
            free(name);
            return lower_error(
                "E2S32",
                "constructor payload is outside the one-Int slice",
                cursor
            );
        }
        int64_t payload_start = skip_trivia(
            source,
            token_end(source, open)
        );
        bool empty =
            payload_start < length &&
            token_equal(source, payload_start, ")");
        if ((arity == 0) != empty) {
            free(constructor_owner);
            free(name);
            return lower_error(
                "E2S32",
                arity == 1 ?
                    "constructor takes one Int payload" :
                    "constructor takes no payload",
                cursor
            );
        }
        char *payload = owned_text("INT64_C(0)");
        if (arity == 1) {
            int64_t payload_end = expression_end(source, payload_start);
            int64_t close = payload_end < 0 ?
                -1 :
                skip_trivia(source, payload_end);
            if (
                payload_end < 0 ||
                close >= length ||
                !token_equal(source, close, ")")
            ) {
                free(payload);
                free(constructor_owner);
                free(name);
                return lower_error(
                    "E2S32",
                    "concrete enum payload must be one Int expression",
                    payload_start
                );
            }
            free(payload);
            payload = emit_expression(
                source,
                hir,
                payload_start,
                payload_end
            );
        }
        Buffer output;
        buffer_init(&output);
        buffer_format(
            &output,
            "((KofunEnumValue){INT64_C(%" PRId64 "), %s})",
            tag,
            payload
        );
        free(payload);
        free(constructor_owner);
        free(name);
        return output.data;
    }
    free(constructor_owner);

    char *return_type = function_return_type(source, name);
    if (strcmp(return_type, enum_type) == 0) {
        char *output = emit_primary(source, hir, cursor, end);
        free(return_type);
        free(name);
        return output;
    }
    free(return_type);
    free(name);
    return lower_error(
        "E2S32",
        "call does not return the expected concrete enum",
        cursor
    );
}

/*
 * One argument's C expression.
 *
 * The three function-value forms are lowered here rather than in
 * `emit_primary`, because only argument position accepts them and only this
 * caller knows it is in argument position. Everything else lowers through the
 * ordinary expression emitter unchanged.
 */
static char *emit_argument(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *callee,
    int64_t argument_index
) {
    int64_t cursor = skip_trivia(source, start);
    char *expected_type = function_parameter_type(
        source,
        callee,
        argument_index
    );
    if (enum_constructor_count(source, expected_type) >= 0) {
        char *value = emit_enum_value(
            source,
            hir,
            cursor,
            end,
            expected_type
        );
        free(expected_type);
        return value;
    }
    if (record_declaration_start(source, expected_type) >= 0) {
        char *value = emit_record_value(
            source,
            hir,
            cursor,
            end,
            expected_type
        );
        free(expected_type);
        return value;
    }
    char *actual_type = initializer_type(
        source,
        hir,
        enclosing_function_open(source, start),
        start
    );
    if (
        strcmp(actual_type, "List[Int]") == 0 &&
        strcmp(expected_type, "List[Int]") != 0
    ) {
        Buffer message;
        buffer_init(&message);
        buffer_format(
            &message,
            "Core function `%s` expects %s for argument %" PRId64
            ", got List[Int]",
            callee,
            expected_type,
            argument_index + 1
        );
        free(actual_type);
        free(expected_type);
        char *error = lower_error("E2S15", message.data, start);
        free(message.data);
        return error;
    }
    if (strcmp(expected_type, "List[Int]") == 0) {
        if (strcmp(actual_type, "List[Int]") != 0) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "Core function `%s` expects List[Int] for argument %" PRId64
                ", got %s",
                callee,
                argument_index + 1,
                actual_type
            );
            free(actual_type);
            free(expected_type);
            char *error = lower_error("E2S15", message.data, start);
            free(message.data);
            return error;
        }
        free(actual_type);
        free(expected_type);
        return emit_list_int_value(source, hir, start, end, false);
    }
    free(actual_type);
    free(expected_type);
    /* An arrow lambda argument is the address of the function it was lifted
     * to. */
    if (lambda_parameters_end(source, -1, cursor) >= 0) {
        return argument_lambda_name(cursor);
    }
    /* `call_argument_position` scans from the start of the source, so it is
     * tested last in each arm: the cheap HIR lookup rejects the ordinary
     * identifier argument first, and the scan then runs only for the two rare
     * shapes that can actually be function values. */
    if (strcmp(token_kind(source, cursor), "identifier") == 0) {
        char *value_binding = hir_use_binding_id(hir, cursor);
        if (value_binding[0] != '\0') {
            /* A lambda binding used as a value is the address of its lifted
             * function: lifting never declares a C variable for the binding
             * itself, so `k_b<id>` would name nothing. */
            if (
                lambda_binding_open(source, hir, value_binding) >= 0 &&
                call_argument_position(source, cursor)
            ) {
                Buffer output;
                buffer_init(&output);
                buffer_format(&output, "kofun_lambda_%s", value_binding);
                free(value_binding);
                return output.data;
            }
        } else {
            /* A bare name the scope HIR left unresolved that is a declared
             * Core function is that function used as a value. Its lowered
             * form is already an ordinary C function, so its address is the
             * callable. */
            char *name = token_copy(source, cursor);
            char *owner = enum_constructor_owner(source, name);
            bool constructor = owner[0] != '\0';
            free(owner);
            if (
                !constructor &&
                function_arity(source, name) >= 0 &&
                call_argument_position(source, cursor)
            ) {
                char *c_name = c_identifier_name(name);
                Buffer output;
                buffer_init(&output);
                buffer_format(&output, "kofun_fn_%s", c_name);
                free(c_name);
                free(name);
                free(value_binding);
                return output.data;
            }
            /* A module constant lowers to its own file-scope C constant. */
            if (constant_is_declared(source, name)) {
                char *c_name = c_identifier_name(name);
                char *lowered = constant_c_name(c_name);
                free(c_name);
                free(name);
                free(value_binding);
                return lowered;
            }
            free(name);
        }
        free(value_binding);
    }
    return emit_expression(source, hir, start, end);
}

/* Whether a fixed call slot can carry this type. One vocabulary serves the
 * labelled (#1097/#1107) and direct List[Int] (#1103) slot paths, so a
 * widened carrier cannot become executable in one and silently stay unknown
 * in the other. */
static bool call_slot_carried(const char *carrier) {
    return strcmp(carrier, "Int") == 0 ||
        strcmp(carrier, "Text") == 0 ||
        strcmp(carrier, "List[Int]") == 0;
}

/* Everything before the slot's name in its C declaration, so pointer spacing
 * is decided here instead of at each emitter: a pointer carrier already ends
 * in `*`, which is how the rest of the emitted surface spells
 * `const char *name`. */
static const char *call_slot_declaration_prefix(const char *carrier) {
    if (strcmp(carrier, "Text") == 0) return "const char *";
    if (strcmp(carrier, "List[Int]") == 0) return "KofunIntListValue ";
    return "int64_t ";
}

/* The declared zero for that carrier. A slot is assigned before the call in
 * every path that declares it, so this only has to be a valid value of the
 * type, never a null the emitted C could dereference. */
static const char *call_slot_zero(const char *carrier) {
    if (strcmp(carrier, "Text") == 0) return "\"\"";
    if (strcmp(carrier, "List[Int]") == 0) return "KOFUN_LIST_INT_ZERO";
    return "INT64_C(0)";
}

/* #1097 lowered the first executable labelled-call profile — a direct
 * top-level function whose parameters and result are all Int — and #1107
 * widened its carriers to Text and List[Int], the two the positional path
 * already executes. The fixed-slot binding pass has already rejected
 * unknown/duplicate/missing labels; this predicate keeps every wider carrier
 * and backend shape at the explicit E2S158 boundary owned by #882. */
static bool labelled_call_supported(
    const char *source,
    const char *hir,
    int64_t call_start,
    const char *callee,
    int64_t open
) {
    if (!call_has_labelled_argument(source, open)) return false;
    /* A lexical callable may shadow a top-level declaration with the same
     * spelling. Only an unresolved callee name denotes the direct top-level
     * function this bounded ABI slice can lower. */
    char *callee_binding = hir_use_binding_id(hir, call_start);
    bool direct = callee_binding[0] == '\0';
    free(callee_binding);
    if (!direct) return false;
    /* Lifted lambdas are emitted as separate C functions. Their call-site
     * temporaries therefore cannot live in the enclosing source function;
     * keep that independently reviewable lowering at #882's E2S158
     * boundary. */
    int64_t function_open = enclosing_function_open(source, call_start);
    if (
        function_open >= 0 &&
        lambda_scope_open(source, function_open, call_start) >= 0
    ) {
        return false;
    }
    int64_t declaration = function_start_named(source, callee);
    char *result = function_return_type(source, callee);
    bool carries_result = call_slot_carried(result);
    free(result);
    if (declaration < 0 || !carries_result) return false;
    int64_t count = parameter_count(source, declaration);
    if (count < 1 || count > 8) return false;
    for (int64_t index = 0; index < count; ++index) {
        char *type = function_parameter_type(source, callee, index);
        bool carried = call_slot_carried(type);
        free(type);
        if (!carried) return false;
    }
    return true;
}

/* Map a source-order argument back to the declaration/ABI slot that #881
 * validated. Positional arguments form a prefix, so their source index is
 * already their slot; labelled arguments compare against external names. */
static int64_t labelled_argument_slot(
    const char *source,
    const char *callee,
    int64_t argument,
    int64_t source_index
) {
    int64_t colon = skip_trivia(source, token_end(source, argument));
    if (
        !parameter_word_token(source, argument) ||
        !token_equal(source, colon, ":")
    ) {
        return source_index;
    }
    int64_t declaration = function_start_named(source, callee);
    int64_t parameters = parameter_open(source, declaration);
    int64_t close = balanced_end(source, parameters, "(", ")");
    int64_t parameter = skip_trivia(
        source,
        token_end(source, parameters)
    );
    int64_t slot = 0;
    while (parameter < close && !token_equal(source, parameter, ")")) {
        int64_t external = parameter_external_start(
            source,
            parameter,
            close
        );
        if (
            external >= 0 &&
            source_tokens_equal(source, external, argument)
        ) {
            return slot;
        }
        int64_t type_start = parameter_type_start(
            source,
            parameter,
            close
        );
        int64_t type_end = callable_type_end(source, type_start);
        int64_t list_end = parameter_list_type_end(
            source,
            type_start,
            close
        );
        if (type_end < 0) {
            type_end = list_end >= 0
                ? list_end : annotation_type_end(source, type_start);
        }
        int64_t separator = skip_trivia(source, type_end);
        parameter = separator < close && token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator))
            : separator;
        ++slot;
    }
    return -1;
}

static int64_t labelled_argument_value(
    const char *source,
    int64_t argument
) {
    int64_t colon = skip_trivia(source, token_end(source, argument));
    if (
        parameter_word_token(source, argument) &&
        token_equal(source, colon, ":")
    ) {
        return skip_trivia(source, token_end(source, colon));
    }
    return argument;
}

/* C11 leaves ordinary function-argument evaluation order unspecified. A
 * comma expression is sequenced, so assign source-order values first and only
 * then invoke the declaration-order ABI vector. Temporary names contain no
 * source labels and are declared once at the containing function scope. */
static char *emit_labelled_call(
    const char *source,
    const char *hir,
    int64_t call_start,
    int64_t open,
    int64_t end,
    const char *callee
) {
    int64_t declaration = function_start_named(source, callee);
    int64_t parameter_count_value = parameter_count(source, declaration);
    Buffer output;
    buffer_init(&output);
    buffer_append(&output, "(");
    int64_t argument = skip_trivia(source, token_end(source, open));
    int64_t source_index = 0;
    while (argument < end && !token_equal(source, argument, ")")) {
        int64_t bound = argument_end(source, argument);
        int64_t slot = labelled_argument_slot(
            source,
            callee,
            argument,
            source_index
        );
        if (slot < 0 || slot >= parameter_count_value) {
            free(output.data);
            return lower_error(
                "E2S158",
                "labelled-call fixed-slot projection failed",
                argument
            );
        }
        int64_t value_start = labelled_argument_value(source, argument);
        char *value = emit_argument(
            source,
            hir,
            value_start,
            bound,
            callee,
            slot
        );
        if (strncmp(value, "error[", 6) == 0) {
            free(output.data);
            return value;
        }
        buffer_format(
            &output,
            "(kofun_call_arg_%" PRId64 "_%" PRId64 " = %s), ",
            call_start,
            slot,
            value
        );
        free(value);
        ++source_index;
        int64_t separator = skip_trivia(source, bound);
        argument = separator < end && token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator))
            : separator;
    }
    char *c_name = c_identifier_name(callee);
    buffer_format(&output, "kofun_fn_%s(", c_name);
    free(c_name);
    for (int64_t slot = 0; slot < parameter_count_value; ++slot) {
        if (slot > 0) buffer_append(&output, ", ");
        buffer_format(
            &output,
            "kofun_call_arg_%" PRId64 "_%" PRId64,
            call_start,
            slot
        );
    }
    buffer_append(&output, "))");
    return output.data;
}

/* Reserve the fixed carrier slots before any statement in the containing
 * function. The call-start byte makes nested and repeated call sites distinct
 * without carrying an external label into generated artifacts. */
static char *emit_labelled_call_temporaries(
    const char *source,
    const char *hir,
    int64_t function_open
) {
    int64_t close = balanced_end(source, function_open, "{", "}");
    Buffer output;
    buffer_init(&output);
    if (close < 0) return output.data;
    int64_t cursor = skip_trivia(
        source,
        token_end(source, function_open)
    );
    while (cursor < close) {
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            int64_t open = skip_trivia(source, token_end(source, cursor));
            if (open < close && token_equal(source, open, "(")) {
                char *callee = token_copy(source, cursor);
                if (labelled_call_supported(
                    source,
                    hir,
                    cursor,
                    callee,
                    open
                )) {
                    int64_t declaration = function_start_named(
                        source,
                        callee
                    );
                    int64_t count = parameter_count(source, declaration);
                    for (int64_t slot = 0; slot < count; ++slot) {
                        char *carrier = function_parameter_type(
                            source,
                            callee,
                            slot
                        );
                        buffer_format(
                            &output,
                            "    %skofun_call_arg_%" PRId64
                            "_%" PRId64 " = %s;\n",
                            call_slot_declaration_prefix(carrier),
                            cursor,
                            slot,
                            call_slot_zero(carrier)
                        );
                        free(carrier);
                    }
                }
                free(callee);
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return output.data;
}

/* Ordinary C argument evaluation is unsequenced. A direct call that crosses
 * a List[Int] carrier therefore uses fixed source-byte slots for every
 * argument, including its Int companions, before the declaration-order call.
 */
static bool direct_list_int_call_shape(
    const char *source,
    const char *hir,
    int64_t call_start,
    const char *callee,
    int64_t open
) {
    if (call_has_labelled_argument(source, open)) return false;
    char *binding = hir_use_binding_id(hir, call_start);
    bool direct = binding[0] == '\0';
    free(binding);
    if (!direct) return false;
    int64_t declaration = function_start_named(source, callee);
    if (declaration < 0) return false;
    int64_t count = parameter_count(source, declaration);
    if (count < 1 || count > 8) return false;
    bool has_list = false;
    for (int64_t index = 0; index < count; ++index) {
        char *type = function_parameter_type(source, callee, index);
        if (strcmp(type, "List[Int]") == 0) {
            has_list = true;
        } else if (strcmp(type, "Int") != 0) {
            free(type);
            return false;
        }
        free(type);
    }
    return has_list;
}

static bool direct_list_int_call_supported(
    const char *source,
    const char *hir,
    int64_t call_start,
    const char *callee,
    int64_t open
) {
    if (!direct_list_int_call_shape(
        source,
        hir,
        call_start,
        callee,
        open
    )) {
        return false;
    }
    int64_t function_open = enclosing_function_open(source, call_start);
    return function_open < 0 ||
        lambda_scope_open(source, function_open, call_start) < 0;
}

static char *emit_direct_list_int_call(
    const char *source,
    const char *hir,
    int64_t call_start,
    int64_t open,
    int64_t end,
    const char *callee
) {
    int64_t declaration = function_start_named(source, callee);
    int64_t count = parameter_count(source, declaration);
    Buffer output;
    buffer_init(&output);
    buffer_append(&output, "(");
    int64_t argument = skip_trivia(source, token_end(source, open));
    int64_t index = 0;
    while (
        index < count && argument < end &&
        !token_equal(source, argument, ")")
    ) {
        int64_t bound = argument_end(source, argument);
        char *value = emit_argument(
            source,
            hir,
            argument,
            bound,
            callee,
            index
        );
        if (strncmp(value, "error[", 6) == 0) {
            free(output.data);
            return value;
        }
        buffer_format(
            &output,
            "(kofun_list_call_arg_%" PRId64 "_%" PRId64 " = %s), ",
            call_start,
            index,
            value
        );
        free(value);
        int64_t separator = skip_trivia(source, bound);
        argument = separator < end && token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator))
            : separator;
        ++index;
    }
    char *c_name = c_identifier_name(callee);
    buffer_format(&output, "kofun_fn_%s(", c_name);
    free(c_name);
    for (int64_t slot = 0; slot < count; ++slot) {
        if (slot > 0) buffer_append(&output, ", ");
        buffer_format(
            &output,
            "kofun_list_call_arg_%" PRId64 "_%" PRId64,
            call_start,
            slot
        );
    }
    buffer_append(&output, "))");
    return output.data;
}

static char *emit_direct_list_int_call_temporaries(
    const char *source,
    const char *hir,
    int64_t function_open
) {
    int64_t close = balanced_end(source, function_open, "{", "}");
    Buffer output;
    buffer_init(&output);
    if (close < 0) return output.data;
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor < close) {
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            int64_t open = skip_trivia(source, token_end(source, cursor));
            if (open < close && token_equal(source, open, "(")) {
                char *callee = token_copy(source, cursor);
                if (direct_list_int_call_supported(
                    source,
                    hir,
                    cursor,
                    callee,
                    open
                )) {
                    int64_t declaration = function_start_named(source, callee);
                    int64_t count = parameter_count(source, declaration);
                    for (int64_t slot = 0; slot < count; ++slot) {
                        char *carrier = function_parameter_type(
                            source,
                            callee,
                            slot
                        );
                        buffer_format(
                            &output,
                            "    %skofun_list_call_arg_%" PRId64
                            "_%" PRId64 " = %s;\n",
                            call_slot_declaration_prefix(carrier),
                            cursor,
                            slot,
                            call_slot_zero(carrier)
                        );
                        free(carrier);
                    }
                }
                free(callee);
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return output.data;
}

static int64_t list_int_binding_literal_count(
    const char *source,
    const char *hir,
    int64_t use_start
) {
    char *binding_id = hir_use_binding_id(hir, use_start);
    if (binding_id[0] == '\0') {
        free(binding_id);
        return -1;
    }
    int64_t declaration = hir_binding_declaration_start(hir, binding_id);
    free(binding_id);
    if (declaration < 0) return -1;
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(
        source,
        token_end(source, declaration)
    );
    if (cursor < length && token_equal(source, cursor, ":")) {
        int64_t type_start = skip_trivia(
            source,
            token_end(source, cursor)
        );
        int64_t type_finish = list_int_type_end(source, type_start);
        if (type_finish < 0) return -1;
        cursor = skip_trivia(source, type_finish);
    }
    if (cursor >= length || !token_equal(source, cursor, "=")) return -1;
    int64_t literal = skip_trivia(source, token_end(source, cursor));
    return list_int_literal_count(source, literal, NULL);
}

static bool list_int_constant_index(
    const char *source,
    int64_t start,
    int64_t end,
    int64_t *value
) {
    int64_t cursor = skip_trivia(source, start);
    int64_t sign = 1;
    if (
        token_equal(source, cursor, "-") ||
        token_equal(source, cursor, "+")
    ) {
        if (token_equal(source, cursor, "-")) sign = -1;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (
        strcmp(token_kind(source, cursor), "integer") != 0 ||
        token_end(source, cursor) != end
    ) {
        return false;
    }
    char *literal = source_slice(
        source,
        cursor,
        token_end(source, cursor)
    );
    Buffer digits;
    buffer_init(&digits);
    for (size_t index = 0; literal[index] != '\0'; ++index) {
        if (literal[index] != '_') {
            char one[2] = {literal[index], '\0'};
            buffer_append(&digits, one);
        }
    }
    free(literal);
    *value = sign * (int64_t)strtoll(digits.data, NULL, 10);
    free(digits.data);
    return true;
}

static char *emit_list_int_literal(
    const char *source,
    const char *hir,
    int64_t open
) {
    int64_t bad = open;
    int64_t count = list_int_literal_count(source, open, &bad);
    if (count < 0) {
        return lower_error("E2S157", "malformed List[Int] literal", bad);
    }
    if (count > LIST_INT_CAPACITY) {
        return lower_error(
            "E2S157",
            "List[Int] literal capacity is 64 elements",
            open
        );
    }
    Buffer output;
    buffer_init(&output);
    if (count == 0) {
        buffer_append(
            &output,
            "((KofunIntList)(const void *)&(const struct { "
            "uint64_t length; }){UINT64_C(0)})"
        );
        return output.data;
    }
    buffer_format(
        &output,
        "((KofunIntList)(const void *)&(const struct { uint64_t length; "
        "int64_t elements[%" PRId64 "]; }){UINT64_C(%" PRId64 "), {",
        count,
        count
    );
    int64_t element = skip_trivia(source, token_end(source, open));
    for (int64_t index = 0; index < count; ++index) {
        int64_t bound = expression_end(source, element);
        char *actual = initializer_type(
            source,
            hir,
            enclosing_function_open(source, element),
            element
        );
        if (strcmp(actual, "Int") != 0) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "List[Int] element must have type Int, got %s",
                actual
            );
            free(actual);
            free(output.data);
            char *error = lower_error("E2S157", message.data, element);
            free(message.data);
            return error;
        }
        free(actual);
        char *value = emit_expression(source, hir, element, bound);
        if (strncmp(value, "error[", 6) == 0) {
            free(output.data);
            return value;
        }
        if (index > 0) buffer_append(&output, ", ");
        buffer_append(&output, value);
        free(value);
        int64_t separator = skip_trivia(source, bound);
        element = skip_trivia(source, token_end(source, separator));
    }
    buffer_append(&output, "}})");
    return output.data;
}

/* A whole List[Int] value crosses function boundaries in one fixed-capacity
 * by-value carrier. Literals are copied only at immutable local bindings;
 * direct literal arguments and returns stay outside this bounded slice. */
static char *emit_list_int_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    bool allow_literal
) {
    int64_t cursor = skip_trivia(source, start);
    int64_t function_open = enclosing_function_open(source, cursor);
    if (
        function_open >= 0 &&
        lambda_scope_open(source, function_open, cursor) >= 0
    ) {
        return lower_error(
            "E2S157",
            "List[Int] values inside lambdas are outside this lowering slice",
            cursor
        );
    }
    if (token_equal(source, cursor, "[")) {
        if (!allow_literal) {
            return lower_error(
                "E2S157",
                "bind a List[Int] literal before passing or returning it",
                cursor
            );
        }
        char *literal = emit_list_int_literal(source, hir, cursor);
        if (strncmp(literal, "error[", 6) == 0) return literal;
        Buffer output;
        buffer_init(&output);
        buffer_format(&output, "kofun_list_int_value(%s)", literal);
        free(literal);
        return output.data;
    }
    if (strcmp(token_kind(source, cursor), "identifier") != 0) {
        return lower_error(
            "E2S157",
            "List[Int] value must be a whole binding or same-typed direct call",
            cursor
        );
    }
    int64_t after = skip_trivia(source, token_end(source, cursor));
    if (after >= end || !token_equal(source, after, "(")) {
        char *binding_id = hir_use_binding_id(hir, cursor);
        char *binding_type = hir_binding_field(hir, binding_id, 5);
        bool accepted = binding_id[0] != '\0' &&
            strcmp(binding_type, "List[Int]") == 0 && after >= end;
        free(binding_type);
        if (!accepted) {
            free(binding_id);
            return lower_error(
                "E2S157",
                "List[Int] value must be a whole binding or same-typed direct call",
                cursor
            );
        }
        Buffer output;
        buffer_init(&output);
        buffer_format(&output, "k_b%s", binding_id);
        free(binding_id);
        return output.data;
    }
    char *name = token_copy(source, cursor);
    char *result_type = function_return_type(source, name);
    char *binding = hir_use_binding_id(hir, cursor);
    bool accepted = strcmp(result_type, "List[Int]") == 0 &&
        !call_has_labelled_argument(source, after) && binding[0] == '\0';
    free(result_type);
    free(binding);
    free(name);
    if (!accepted) {
        return lower_error(
            "E2S157",
            "List[Int] value must be a whole binding or same-typed direct call",
            cursor
        );
    }
    return emit_primary(source, hir, cursor, end);
}

static char *emit_primary(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t cursor = skip_trivia(source, start);
    const char *kind = token_kind(source, cursor);
    if (token_equal(source, cursor, "[")) {
        return emit_list_int_literal(source, hir, cursor);
    }
    if (strcmp(kind, "decimal") == 0) {
        char *literal = source_slice(source, cursor, token_end(source, cursor));
        Buffer output;
        buffer_init(&output);
        buffer_format(
            &output,
            "kofun_decimal_value_literal(\"%s\", %zu)",
            literal,
            strlen(literal)
        );
        free(literal);
        return output.data;
    }
    if (strcmp(kind, "float") == 0) {
        int64_t literal_end = token_end(source, cursor);
        int64_t number_end = literal_end >= cursor + 3
            ? literal_end - 3
            : cursor;
        char *literal = source_slice(source, cursor, number_end);
        Buffer output;
        buffer_init(&output);
        buffer_format(
            &output,
            "kofun_float_value_literal(\"%s\", %zu)",
            literal,
            strlen(literal)
        );
        free(literal);
        return output.data;
    }
    if (strcmp(kind, "integer") == 0) {
        char *literal = source_slice(source, cursor, end);
        Buffer output;
        buffer_init(&output);
        buffer_append(&output, "INT64_C(");
        for (size_t index = 0; literal[index] != '\0'; ++index) {
            if (literal[index] != '_') {
                char symbol[2] = {literal[index], '\0'};
                buffer_append(&output, symbol);
            }
        }
        buffer_append(&output, ")");
        free(literal);
        return output.data;
    }
    if (strcmp(kind, "string") == 0) {
        return source_slice(source, cursor, token_end(source, cursor));
    }
    if (strcmp(kind, "identifier") == 0) {
        char *conversion = numeric_conversion_at(source, cursor);
        if (conversion[0] != '\0') {
            int64_t dot = skip_trivia(source, token_end(source, cursor));
            int64_t member = skip_trivia(source, token_end(source, dot));
            int64_t open = skip_trivia(source, token_end(source, member));
            int64_t first = numeric_member_argument(source, open, 0);
            int64_t first_end = argument_end(source, first);
            char *first_value = NULL;
            Buffer converted;
            buffer_init(&converted);
            if (strcmp(conversion, "Decimal.parse") == 0) {
                char *text_value = emit_expression(
                    source,
                    hir,
                    first,
                    first_end
                );
                buffer_format(
                    &converted,
                    "kofun_decimal_value_parse(%s, strlen(%s))",
                    text_value,
                    text_value
                );
                free(text_value);
            } else {
                first_value = emit_expression(
                    source,
                    hir,
                    first,
                    first_end
                );
                if (strcmp(conversion, "Decimal.from_int") == 0) {
                    buffer_format(
                        &converted,
                        "kofun_decimal_value_from_int(%s)",
                        first_value
                    );
                } else if (strcmp(conversion, "Decimal.round") == 0) {
                    int64_t scale = numeric_member_argument(source, open, 1);
                    int64_t mode = numeric_member_argument(source, open, 2);
                    char *scale_value = emit_expression(
                        source,
                        hir,
                        scale,
                        argument_end(source, scale)
                    );
                    char *mode_name = token_copy(source, mode);
                    buffer_format(
                        &converted,
                        "kofun_decimal_value_round(%s, %s, %s)",
                        first_value,
                        scale_value,
                        decimal_rounding_c_name(mode_name)
                    );
                    free(mode_name);
                    free(scale_value);
                } else if (strcmp(conversion, "Decimal.divide") == 0) {
                    int64_t right = numeric_member_argument(source, open, 1);
                    int64_t scale = numeric_member_argument(source, open, 2);
                    int64_t mode = numeric_member_argument(source, open, 3);
                    char *right_value = emit_expression(
                        source,
                        hir,
                        right,
                        argument_end(source, right)
                    );
                    char *scale_value = emit_expression(
                        source,
                        hir,
                        scale,
                        argument_end(source, scale)
                    );
                    char *mode_name = token_copy(source, mode);
                    buffer_format(
                        &converted,
                        "kofun_decimal_value_divide_rounded(%s, %s, %s, %s)",
                        first_value,
                        right_value,
                        scale_value,
                        decimal_rounding_c_name(mode_name)
                    );
                    free(mode_name);
                    free(scale_value);
                    free(right_value);
                } else if (strcmp(conversion, "Decimal.format") == 0) {
                    int64_t scale = numeric_member_argument(source, open, 1);
                    char *scale_value = emit_expression(
                        source,
                        hir,
                        scale,
                        argument_end(source, scale)
                    );
                    buffer_format(
                        &converted,
                        "kofun_decimal_value_format(%s, %s)",
                        first_value,
                        scale_value
                    );
                    free(scale_value);
                }
                free(first_value);
            }
            free(conversion);
            return converted.data;
        }
        free(conversion);
        char *name = token_copy(source, cursor);
        int64_t open = skip_trivia(source, token_end(source, cursor));
        if (
            open < end && token_equal(source, open, "(") &&
            strcmp(name, "len") == 0
        ) {
            int64_t value = skip_trivia(source, token_end(source, open));
            int64_t value_end = argument_end(source, value);
            char *emitted = emit_expression(
                source,
                hir,
                value,
                value_end
            );
            char *actual = initializer_type(
                source,
                hir,
                enclosing_function_open(source, value),
                value
            );
            Buffer length;
            buffer_init(&length);
            if (strcmp(actual, "List[Int]") == 0) {
                if (token_equal(source, value, "[")) {
                    buffer_format(
                        &length,
                        "((int64_t)kofun_list_int_length(%s))",
                        emitted
                    );
                } else {
                    free(emitted);
                    emitted = emit_list_int_value(
                        source,
                        hir,
                        value,
                        value_end,
                        false
                    );
                    if (strncmp(emitted, "error[", 6) == 0) {
                        free(actual);
                        free(name);
                        free(length.data);
                        return emitted;
                    }
                    buffer_format(
                        &length,
                        "((int64_t)kofun_list_int_value_length(%s))",
                        emitted
                    );
                }
            } else {
                buffer_format(&length, "((int64_t)strlen(%s))", emitted);
            }
            free(actual);
            free(emitted);
            free(name);
            return length.data;
        }
        if (
            open < end && token_equal(source, open, "(") &&
            strcmp(name, "to_text") == 0
        ) {
            int64_t value = skip_trivia(source, token_end(source, open));
            char *emitted = emit_expression(
                source,
                hir,
                value,
                argument_end(source, value)
            );
            Buffer converted_text;
            buffer_init(&converted_text);
            buffer_format(&converted_text, "kofun_to_text(%s)", emitted);
            free(emitted);
            free(name);
            return converted_text.data;
        }
        if (
            open < end && token_equal(source, open, "(") &&
            strcmp(name, "text_slice") == 0
        ) {
            int64_t value = skip_trivia(source, token_end(source, open));
            int64_t value_end = argument_end(source, value);
            int64_t first_separator = skip_trivia(source, value_end);
            int64_t first = skip_trivia(
                source,
                token_end(source, first_separator)
            );
            int64_t first_end = argument_end(source, first);
            int64_t second_separator = skip_trivia(source, first_end);
            int64_t second = skip_trivia(
                source,
                token_end(source, second_separator)
            );
            char *value_text = emit_expression(source, hir, value, value_end);
            char *first_text = emit_expression(source, hir, first, first_end);
            char *second_text = emit_expression(
                source,
                hir,
                second,
                argument_end(source, second)
            );
            Buffer slice;
            buffer_init(&slice);
            buffer_format(
                &slice,
                "kofun_text_slice(%s, %s, %s)",
                value_text,
                first_text,
                second_text
            );
            free(second_text);
            free(first_text);
            free(value_text);
            free(name);
            return slice.data;
        }
        Buffer output;
        buffer_init(&output);
        if (open >= end || !token_equal(source, open, "(")) {
            char *binding_id = hir_use_binding_id(hir, cursor);
            if (open < end && token_equal(source, open, "[")) {
                char *binding_type = hir_binding_field(
                    hir,
                    binding_id,
                    5
                );
                if (strcmp(binding_type, "List[Int]") != 0) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "indexing requires List[Int], got %s",
                        binding_type
                    );
                    free(binding_type);
                    free(binding_id);
                    free(name);
                    free(output.data);
                    char *error = lower_error(
                        "E2S157",
                        message.data,
                        cursor
                    );
                    free(message.data);
                    return error;
                }
                free(binding_type);
                int64_t index_start = skip_trivia(
                    source,
                    token_end(source, open)
                );
                int64_t index_end = expression_end(source, index_start);
                int64_t close = index_end < 0
                    ? -1
                    : skip_trivia(source, index_end);
                if (
                    index_end < 0 ||
                    close >= source_length(source) ||
                    !token_equal(source, close, "]")
                ) {
                    free(binding_id);
                    free(name);
                    free(output.data);
                    return lower_error(
                        "E2S157",
                        "malformed List[Int] index",
                        open
                    );
                }
                char *index_type = initializer_type(
                    source,
                    hir,
                    enclosing_function_open(source, index_start),
                    index_start
                );
                if (strcmp(index_type, "Int") != 0) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "List[Int] index must have type Int, got %s",
                        index_type
                    );
                    free(index_type);
                    free(binding_id);
                    free(name);
                    free(output.data);
                    char *error = lower_error(
                        "E2S157",
                        message.data,
                        index_start
                    );
                    free(message.data);
                    return error;
                }
                free(index_type);
                int64_t constant = 0;
                int64_t literal_count = list_int_binding_literal_count(
                    source,
                    hir,
                    cursor
                );
                if (
                    literal_count >= 0 &&
                    list_int_constant_index(
                        source,
                        index_start,
                        index_end,
                        &constant
                    ) &&
                    (constant < -literal_count || constant >= literal_count)
                ) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "List[Int] index %" PRId64
                        " is out of range for length %" PRId64,
                        constant,
                        literal_count
                    );
                    free(binding_id);
                    free(name);
                    free(output.data);
                    char *error = lower_error(
                        "E2S157",
                        message.data,
                        index_start
                    );
                    free(message.data);
                    return error;
                }
                char *index_value = emit_expression(
                    source,
                    hir,
                    index_start,
                    index_end
                );
                if (strncmp(index_value, "error[", 6) == 0) {
                    free(binding_id);
                    free(name);
                    free(output.data);
                    return index_value;
                }
                buffer_format(
                    &output,
                    "kofun_list_int_index(kofun_list_int_view(&k_b%s), %s)",
                    binding_id,
                    index_value
                );
                free(index_value);
                free(binding_id);
                free(name);
                return output.data;
            }
            if (open < end && token_equal(source, open, ".")) {
                int64_t field_cursor = skip_trivia(
                    source,
                    token_end(source, open)
                );
                char *binding_type = hir_binding_field(
                    hir,
                    binding_id,
                    5
                );
                char *field = token_copy(source, field_cursor);
                char *field_type = record_field_type_named(
                    source,
                    binding_type,
                    field
                );
                if (
                    binding_id[0] == '\0' ||
                    field_type[0] == '\0'
                ) {
                    free(field_type);
                    free(field);
                    free(binding_type);
                    free(binding_id);
                    free(name);
                    free(output.data);
                    return lower_error(
                        "E2S32",
                        "unknown nominal record field read",
                        field_cursor
                    );
                }
                char *c_field = record_c_field_name(field);
                buffer_format(
                    &output,
                    "k_b%s.%s",
                    binding_id,
                    c_field
                );
                free(c_field);
                free(field_type);
                free(field);
                free(binding_type);
                free(binding_id);
                free(name);
                return output.data;
            }
            /* A module constant has no lexical binding of its own, so it
             * lowers to the file-scope C constant instead of `k_b`. */
            if (binding_id[0] == '\0' && constant_is_declared(source, name)) {
                char *identifier = c_identifier_name(name);
                char *lowered = constant_c_name(identifier);
                free(identifier);
                free(binding_id);
                free(name);
                free(output.data);
                return lowered;
            }
            /* #924: a bare `Optional(Int)` name is its payload wherever it is
             * read as `Int`. `validate_optional_uses` has already proved the
             * tag was tested on a dominating edge, so this is the projection
             * of a checked refinement and not an extraction operator. The
             * whole value travels only where the callee declares `Int?`. */
            if (
                optional_int_binding(source, cursor, name) &&
                !optional_int_carrier_position(source, cursor)
            ) {
                buffer_format(&output, "k_b%s.payload", binding_id);
            } else {
                buffer_format(&output, "k_b%s", binding_id);
            }
            free(binding_id);
            free(name);
            return output.data;
        }
        /* A callee the scope HIR resolved to a binding is either a lifted
         * lambda or a callable-typed parameter; anything else is a top-level
         * function looked up by name. */
        if (
            direct_list_int_call_shape(
                source,
                hir,
                cursor,
                name,
                open
            ) &&
            !direct_list_int_call_supported(
                source,
                hir,
                cursor,
                name,
                open
            )
        ) {
            free(name);
            free(output.data);
            return lower_error(
                "E2S157",
                "List[Int] carrier calls inside lambdas are outside this "
                "lowering slice",
                cursor
            );
        }
        if (direct_list_int_call_supported(
            source,
            hir,
            cursor,
            name,
            open
        )) {
            char *sequenced = emit_direct_list_int_call(
                source,
                hir,
                cursor,
                open,
                end,
                name
            );
            free(name);
            free(output.data);
            return sequenced;
        }
        if (labelled_call_supported(
            source,
            hir,
            cursor,
            name,
            open
        )) {
            char *labelled = emit_labelled_call(
                source,
                hir,
                cursor,
                open,
                end,
                name
            );
            free(name);
            free(output.data);
            return labelled;
        }
        if (call_has_labelled_argument(source, open)) {
            free(name);
            return lower_error(
                "E2S158",
                "labelled-call ABI lowering is owned by #882; fixed-slot "
                "checked HIR is available",
                cursor
            );
        }
        char *callee_binding = hir_use_binding_id(hir, cursor);
        int64_t lambda_open =
            callee_binding[0] == '\0'
                ? -1
                : lambda_binding_open(source, hir, callee_binding);
        bool indirect =
            callee_binding[0] != '\0' &&
            callable_parameter_type_start(source, hir, callee_binding) >= 0;
        if (lambda_open >= 0) {
            buffer_format(&output, "kofun_lambda_%s(", callee_binding);
        } else if (indirect) {
            buffer_format(&output, "k_b%s(", callee_binding);
        } else {
            char *c_name = c_identifier_name(name);
            buffer_format(&output, "kofun_fn_%s(", c_name);
            free(c_name);
        }
        int64_t argument = skip_trivia(source, token_end(source, open));
        int64_t arguments = 0;
        while (argument < end && !token_equal(source, argument, ")")) {
            int64_t bound = argument_end(source, argument);
            char *value = emit_argument(
                source,
                hir,
                argument,
                bound,
                name,
                arguments
            );
            /* Every other lowering site propagates an `error[` result. This
             * one appended it, so a rejected argument became C source: the
             * diagnostic text was emitted inside the call, the compiler still
             * exited 0, and only `cc` reported the failure. */
            if (strncmp(value, "error[", 6) == 0) {
                free(output.data);
                free(callee_binding);
                free(name);
                return value;
            }
            if (arguments > 0) buffer_append(&output, ", ");
            buffer_append(&output, value);
            free(value);
            ++arguments;
            int64_t separator = skip_trivia(source, bound);
            if (separator < end && token_equal(source, separator, ",")) {
                argument = skip_trivia(source, token_end(source, separator));
            } else {
                argument = separator;
            }
        }
        if (lambda_open >= 0) {
            char *captures = lambda_captures(source, hir, lambda_open);
            append_captures(&output, captures, arguments, "");
            free(captures);
        }
        buffer_append(&output, ")");
        free(callee_binding);
        free(name);
        return output.data;
    }
    if (token_equal(source, cursor, "(")) {
        int64_t value_start = skip_trivia(source, token_end(source, cursor));
        int64_t close = skip_trivia(source, expression_end(source, value_start));
        char *value = emit_expression(source, hir, value_start, close);
        Buffer output;
        buffer_init(&output);
        buffer_format(&output, "(%s)", value);
        free(value);
        return output.data;
    }
    char *empty = allocate(1);
    empty[0] = '\0';
    return empty;
}

static char *emit_unary(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t cursor = skip_trivia(source, start);
    if (token_equal(source, cursor, "+")) {
        int64_t value_start = skip_trivia(source, token_end(source, cursor));
        return emit_unary(source, hir, value_start, end);
    }
    if (token_equal(source, cursor, "-")) {
        int64_t value_start = skip_trivia(source, token_end(source, cursor));
        char *value = emit_unary(source, hir, value_start, end);
        Buffer output;
        buffer_init(&output);
        int64_t function_open = enclosing_function_open(source, cursor);
        const char *type = numeric_primary_type(
            source,
            hir,
            function_open,
            value_start
        );
        if (strcmp(type, "Decimal") == 0) {
            buffer_format(&output, "kofun_decimal_value_negate(%s)", value);
        } else if (strcmp(type, "Float") == 0) {
            buffer_format(&output, "(-(%s))", value);
        } else {
            buffer_format(&output, "kofun_neg(%s)", value);
        }
        free(value);
        return output.data;
    }
    return emit_primary(source, hir, cursor, end);
}

static char *emit_product(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t cursor = unary_end(source, start);
    char *emitted = emit_unary(source, hir, start, cursor);
    int64_t function_open = enclosing_function_open(source, start);
    const char *type = numeric_primary_type(
        source,
        hir,
        function_open,
        start
    );
    int64_t operator_start = skip_trivia(source, cursor);
    while (operator_start < end) {
        char *operator_text = token_copy(source, operator_start);
        int64_t right_start = skip_trivia(
            source,
            token_end(source, operator_start)
        );
        int64_t right_end = unary_end(source, right_start);
        char *right = emit_unary(source, hir, right_start, right_end);
        /* Combining a rejected operand hid it: `kofun_add(error[...], x)` no
         * longer starts with `error[`, so every caller above this loop saw a
         * well-formed expression. Refuse before wrapping. */
        if (strncmp(emitted, "error[", 6) == 0) {
            free(right);
            free(operator_text);
            return emitted;
        }
        if (strncmp(right, "error[", 6) == 0) {
            free(emitted);
            free(operator_text);
            return right;
        }
        char *combined = emitted;
        if (strcmp(operator_text, "*") == 0) {
            if (strcmp(type, "Decimal") == 0) {
                combined = format_two(
                    "kofun_decimal_value_multiply",
                    emitted,
                    right
                );
            } else if (strcmp(type, "Float") == 0) {
                combined = format_two("kofun_float_multiply", emitted, right);
            } else {
                combined = format_two("kofun_mul", emitted, right);
            }
        } else if (strcmp(operator_text, "/") == 0) {
            if (strcmp(type, "Decimal") == 0) {
                combined = format_two(
                    "kofun_decimal_value_divide_exact",
                    emitted,
                    right
                );
            } else if (strcmp(type, "Float") == 0) {
                combined = format_two("kofun_float_divide", emitted, right);
            }
        } else if (strcmp(operator_text, "//") == 0) {
            combined = format_two("kofun_floor_div", emitted, right);
        } else if (strcmp(operator_text, "%") == 0) {
            combined = format_two("kofun_floor_mod", emitted, right);
        }
        if (combined != emitted) free(emitted);
        free(right);
        free(operator_text);
        emitted = combined;
        cursor = right_end;
        operator_start = skip_trivia(source, cursor);
    }
    return emitted;
}

static char *emit_arithmetic_expression(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t cursor = product_end(source, start);
    char *emitted = emit_product(source, hir, start, cursor);
    int64_t function_open = enclosing_function_open(source, start);
    const char *type = numeric_primary_type(
        source,
        hir,
        function_open,
        start
    );
    bool left_is_text = text_operand(
        source,
        hir,
        function_open,
        start
    );
    int64_t operator_start = skip_trivia(source, cursor);
    while (operator_start < end) {
        char *operator_text = token_copy(source, operator_start);
        int64_t right_start = skip_trivia(
            source,
            token_end(source, operator_start)
        );
        int64_t right_end = product_end(source, right_start);
        char *right = emit_product(source, hir, right_start, right_end);
        bool right_is_text = text_operand(
            source,
            hir,
            function_open,
            right_start
        );
        /* Same rule as `emit_product`: a rejected operand must not be wrapped
         * into a call that looks like a valid expression. */
        if (strncmp(emitted, "error[", 6) == 0) {
            free(right);
            free(operator_text);
            return emitted;
        }
        if (strncmp(right, "error[", 6) == 0) {
            free(emitted);
            free(operator_text);
            return right;
        }
        char *combined = emitted;
        if (strcmp(operator_text, "+") == 0) {
            if (left_is_text || right_is_text) {
                if (!left_is_text || !right_is_text) {
                    free(emitted);
                    free(right);
                    free(operator_text);
                    return lower_error(
                        "E2S155",
                        "operator `+` requires Text + Text or matching "
                        "numeric operands",
                        operator_start
                    );
                }
                combined = format_two("kofun_text_concat", emitted, right);
            } else if (strcmp(type, "Decimal") == 0) {
                combined = format_two(
                    "kofun_decimal_value_add",
                    emitted,
                    right
                );
            } else if (strcmp(type, "Float") == 0) {
                combined = format_two("kofun_float_add", emitted, right);
            } else {
                combined = format_two("kofun_add", emitted, right);
            }
        } else if (strcmp(operator_text, "-") == 0) {
            if (left_is_text || right_is_text) {
                free(emitted);
                free(right);
                free(operator_text);
                return lower_error(
                    "E2S155",
                    "only operator `+` is defined on Text",
                    operator_start
                );
            } else if (strcmp(type, "Decimal") == 0) {
                combined = format_two(
                    "kofun_decimal_value_subtract",
                    emitted,
                    right
                );
            } else if (strcmp(type, "Float") == 0) {
                combined = format_two("kofun_float_subtract", emitted, right);
            } else {
                combined = format_two("kofun_sub", emitted, right);
            }
        }
        if (combined != emitted) free(emitted);
        free(right);
        free(operator_text);
        emitted = combined;
        left_is_text = left_is_text && right_is_text;
        cursor = right_end;
        operator_start = skip_trivia(source, cursor);
    }
    return emitted;
}

/* One C expression serves let, print, return, and argument position. The
 * function-local carrier stores the left exactly once; C11's conditional
 * operator makes the fallback selected-only. A failed left selects neither
 * payload nor fallback until the surrounding statement observes failure. */
static char *emit_expression(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t operator_start = optional_int_coalescing_operator(
        source,
        start,
        end
    );
    if (operator_start < 0) {
        return emit_arithmetic_expression(source, hir, start, end);
    }
    int64_t right_start = skip_trivia(
        source,
        token_end(source, operator_start)
    );
    char *left = optional_int_value(source, hir, start, operator_start);
    if (strncmp(left, "error[", 6) == 0) return left;
    char *right = emit_arithmetic_expression(
        source,
        hir,
        right_start,
        end
    );
    if (strncmp(right, "error[", 6) == 0) {
        free(left);
        return right;
    }
    Buffer output;
    buffer_init(&output);
    buffer_format(
        &output,
        "((kofun_optional_int_coalesce_%" PRId64 " = %s), "
        "(kofun_failed ? INT64_C(0) : "
        "(kofun_optional_int_coalesce_%" PRId64
        ".tag != KOFUN_OPTIONAL_INT_NONE_TAG ? "
        "kofun_optional_int_coalesce_%" PRId64 ".payload : %s)))",
        operator_start,
        left,
        operator_start,
        operator_start,
        right
    );
    free(left);
    free(right);
    return output.data;
}

static char *lower_error(
    const char *code,
    const char *message,
    int64_t cursor
);

static int64_t function_arity(const char *source, const char *wanted) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    int64_t found = -1;
    while (cursor < length) {
        char *name = function_name(source, cursor);
        if (strcmp(name, wanted) == 0) {
            if (found >= 0) {
                free(name);
                return -2;
            }
            found = parameter_count(source, cursor);
        }
        free(name);
        cursor = next_function_start(source, function_end(source, cursor));
    }
    return found;
}

static int64_t call_arity(const char *source, int64_t open) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, token_end(source, open));
    if (cursor < length && token_equal(source, cursor, ")")) return 0;
    int64_t arity = 0;
    while (cursor < length) {
        int64_t bound = argument_end(source, cursor);
        /* Text-literal arguments are single tokens outside the bounded
         * arithmetic expression grammar. */
        if (bound < 0) bound = token_end(source, cursor);
        ++arity;
        int64_t separator = skip_trivia(source, bound);
        if (separator < length && token_equal(source, separator, ")")) {
            return arity;
        }
        if (separator >= length || !token_equal(source, separator, ",")) {
            return -1;
        }
        cursor = skip_trivia(source, token_end(source, separator));
    }
    return -1;
}

/*
 * The 16 host builtins of the frozen self-host profile (#618/#619), keyed by
 * arity. `print` stays a statement-level special case. `len` is one name here;
 * its Text/List[Text] overload is resolved by type, not arity. Builtin calls
 * are known and arity-checked. The bounded date/time slice lowers `len(Text)`
 * and `text_slice`; the remaining accepted uses classify as unsupported
 * lowering, never as an unknown-function source error.
 */
static int64_t builtin_arity(const char *name) {
    static const struct {
        const char *name;
        int64_t arity;
    } builtins[] = {
        {"args", 0},
        {"chars", 1},
        {"contains", 2},
        {"fail", 0},
        {"find", 2},
        {"is_digit", 1},
        {"is_space", 1},
        {"is_xid_continue", 1},
        {"len", 1},
        {"read_text", 1},
        {"replace", 3},
        {"starts_with", 2},
        {"text_slice", 3},
        {"to_text", 1},
        {"trim", 1},
        {"validate_unicode_source", 1},
        {"write_text", 2},
    };
    size_t count = sizeof(builtins) / sizeof(builtins[0]);
    for (size_t index = 0; index < count; ++index) {
        if (strcmp(name, builtins[index].name) == 0) {
            return builtins[index].arity;
        }
    }
    return -1;
}

static char *initializer_type(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t initializer
);
static bool record_initializer_constructor_token(
    const char *source,
    int64_t function_open,
    int64_t target
);
static bool value_control(const char *source, int64_t cursor);
/* Defined beside the other numeric-type helpers; declared here because the
 * scope walk is the one caller that runs before them. */
static bool numeric_conversion_head(const char *source, int64_t cursor);
/* Defined beside the move-assertion validator; declared here because the
 * scope walk must not resolve the `compiler` head as a lexical binding. */
static bool move_assertion_head(const char *source, int64_t cursor);
static bool move_statement_head(const char *source, int64_t cursor);
static bool newline_between(
    const char *source,
    int64_t start,
    int64_t end
) {
    for (int64_t at = start; at < end; ++at) {
        if (source[at] == '\n') return true;
    }
    return false;
}

/*
 * Parameter types of the profile builtins, `|`-separated in order.
 * `len` accepts either Text or List (its only overload); every other
 * signature is exact.
 */
static const char *builtin_parameter_types(const char *name) {
    static const struct {
        const char *name;
        const char *parameters;
    } builtins[] = {
        {"args", ""},
        {"chars", "Text"},
        {"contains", "Text|Text"},
        {"fail", ""},
        {"find", "Text|Text"},
        {"is_digit", "Text"},
        {"is_space", "Text"},
        {"is_xid_continue", "Text"},
        {"len", "TextOrList"},
        {"read_text", "Text"},
        {"replace", "Text|Text|Text"},
        {"starts_with", "Text|Text"},
        {"text_slice", "Text|Int|Int"},
        {"to_text", "Int"},
        {"trim", "Text"},
        {"validate_unicode_source", "Text"},
        {"write_text", "Text|Text"},
    };
    size_t count = sizeof(builtins) / sizeof(builtins[0]);
    for (size_t index = 0; index < count; ++index) {
        if (strcmp(name, builtins[index].name) == 0) {
            return builtins[index].parameters;
        }
    }
    return NULL;
}

/* Body `{` of the function declaration that contains `position`. */
static int64_t enclosing_function_open(
    const char *source,
    int64_t position
) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        int64_t close = function_end(source, cursor);
        if (cursor <= position && position < close) {
            int64_t parameters = parameter_open(source, cursor);
            if (parameters < 0) return -1;
            int64_t parameters_close = balanced_end(
                source,
                parameters,
                "(",
                ")"
            );
            if (parameters_close < 0) return -1;
            int64_t open = skip_trivia(source, parameters_close);
            while (open < close && !token_equal(source, open, "{")) {
                open = skip_trivia(source, token_end(source, open));
            }
            return open < close ? open : -1;
        }
        cursor = next_function_start(source, close);
    }
    return -1;
}

/*
 * Check one builtin call's argument types against its frozen signature.
 * Arguments whose bounded type cannot be established (value-control
 * initializers) are skipped rather than rejected. Returns an owned
 * error string or empty text.
 */
static char *builtin_argument_check(
    const char *source,
    const char *hir,
    const char *name,
    int64_t call_name,
    int64_t open
) {
    const char *parameters = builtin_parameter_types(name);
    if (parameters == NULL) return owned_text("");
    int64_t function_open = enclosing_function_open(source, call_name);
    if (function_open < 0) return owned_text("");
    int64_t length = source_length(source);
    int64_t argument = skip_trivia(source, token_end(source, open));
    const char *expected = parameters;
    int64_t index = 1;
    while (
        argument < length &&
        !token_equal(source, argument, ")") &&
        expected[0] != '\0'
    ) {
        size_t expected_length = strcspn(expected, "|");
        if (!value_control(source, argument)) {
            char *actual = initializer_type(
                source,
                hir,
                function_open,
                argument
            );
            bool matches;
            if (strncmp(expected, "TextOrList", expected_length) == 0) {
                matches = strcmp(actual, "Text") == 0 ||
                    strcmp(actual, "List") == 0 ||
                    strcmp(actual, "List[Int]") == 0;
            } else {
                matches =
                    strlen(actual) == expected_length &&
                    strncmp(actual, expected, expected_length) == 0;
            }
            if (!matches) {
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S15]: builtin `%s` expects %.*s for "
                    "argument %" PRId64 ", got %s at byte %" PRId64,
                    name,
                    (int)expected_length,
                    expected,
                    index,
                    actual,
                    argument
                );
                stage2_diagnostic_set(
                    "E2S15",
                    argument,
                    token_end(source, argument),
                    true,
                    error.data
                );
                free(actual);
                return const_generic_refusal(&error);
            }
            free(actual);
        }
        int64_t argument_end = expression_end(source, argument);
        /* Text-literal arguments are single tokens outside the bounded
         * arithmetic expression grammar. */
        if (argument_end < 0) argument_end = token_end(source, argument);
        int64_t separator = skip_trivia(source, argument_end);
        if (separator >= length || !token_equal(source, separator, ",")) {
            break;
        }
        argument = skip_trivia(source, token_end(source, separator));
        expected += expected_length;
        if (expected[0] == '|') ++expected;
        ++index;
    }
    return owned_text("");
}

/*
 * Bounded condition and return typing for the whole profile surface,
 * ordered before the unsupported-lowering classification so the frozen
 * self-host source is fully checked. Statement `if`/`while` conditions
 * must not be confidently non-Bool (the E2S23 message shape is reused
 * byte for byte for `if`); value returns must not confidently mismatch
 * the declared result type. Match guards, value-position `if`, and
 * value-control operands are skipped rather than guessed.
 */
static char *validate_core_types(const char *source, const char *hir) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        char *name = function_name(source, function_start);
        char *declared = function_return_type(source, name);
        int64_t function_open = enclosing_function_open(
            source,
            function_start < function_close ?
                function_close - 1 : function_start
        );
        if (function_open < 0) {
            free(name);
            free(declared);
            function_start = next_function_start(source, function_close);
            continue;
        }
        int64_t previous_start = function_open;
        int64_t cursor = skip_trivia(
            source,
            token_end(source, function_open)
        );
        while (cursor < function_close) {
            bool statement_context =
                token_equal(source, previous_start, "{") ||
                token_equal(source, previous_start, "}") ||
                token_equal(source, previous_start, "else") ||
                newline_between(
                    source,
                    token_end(source, previous_start),
                    cursor
                );
            if (
                (token_equal(source, cursor, "if") && statement_context) ||
                (token_equal(source, cursor, "while") && statement_context)
            ) {
                int64_t condition = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                if (condition < function_close) {
                    char *condition_type = initializer_type(
                        source,
                        hir,
                        function_open,
                            condition
                        );
                    bool wrong =
                        strcmp(condition_type, "Int") == 0 ||
                        strcmp(condition_type, "Text") == 0 ||
                        strcmp(condition_type, "List") == 0 ||
                        strcmp(condition_type, "List[Int]") == 0;
                    free(condition_type);
                    if (wrong) {
                        Buffer error;
                        buffer_init(&error);
                        if (token_equal(source, cursor, "if")) {
                            buffer_format(
                                &error,
                                "error[E2S23]: if condition must be Bool "
                                "or an Int comparison at byte %" PRId64,
                                condition
                            );
                        } else {
                            buffer_format(
                                &error,
                                "error[E2S23]: while condition must be "
                                "Bool at byte %" PRId64,
                                condition
                            );
                        }
                        stage2_diagnostic_set(
                            "E2S23",
                            condition,
                            condition,
                            true,
                            error.data
                        );
                        free(name);
                        free(declared);
                        return const_generic_refusal(&error);
                    }
                }
            }
            if (
                token_equal(source, cursor, "return") &&
                statement_context &&
                declared[0] != '\0' &&
                strcmp(declared, "Void") != 0
            ) {
                int64_t value = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                bool bare =
                    value >= function_close ||
                    token_equal(source, value, "}") ||
                    newline_between(
                        source,
                        token_end(source, cursor),
                        value
                    );
                if (!bare && !value_control(source, value)) {
                    char *value_type = initializer_type(
                        source,
                        hir,
                        function_open,
                        value
                    );
                    bool known =
                        strcmp(value_type, "Int") == 0 ||
                        strcmp(value_type, "Bool") == 0 ||
                        strcmp(value_type, "Text") == 0 ||
                        strcmp(value_type, "List") == 0 ||
                        strcmp(value_type, "List[Int]") == 0;
                    if (known && strcmp(value_type, declared) != 0) {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S15]: Core function `%s` returns %s, "
                            "expected %s at byte %" PRId64,
                            name,
                            value_type,
                            declared,
                            value
                        );
                        stage2_diagnostic_set(
                            "E2S15",
                            value,
                            token_end(source, value),
                            true,
                            error.data
                        );
                        free(value_type);
                        free(name);
                        free(declared);
                        return const_generic_refusal(&error);
                    }
                    free(value_type);
                }
            }
            previous_start = cursor;
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        free(name);
        free(declared);
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

static int64_t function_start_named(const char *source, const char *wanted) {
    int64_t cursor = next_function_start(source, 0);
    int64_t length = source_length(source);
    while (cursor < length) {
        char *name = function_name(source, cursor);
        bool match = strcmp(name, wanted) == 0;
        free(name);
        if (match) return cursor;
        cursor = next_function_start(source, function_end(source, cursor));
    }
    return -1;
}

static bool source_tokens_equal(
    const char *source,
    int64_t left,
    int64_t right
) {
    char *left_text = token_copy(source, left);
    char *right_text = token_copy(source, right);
    bool equal = strcmp(left_text, right_text) == 0;
    free(right_text);
    free(left_text);
    return equal;
}

static char *call_binding_failure(
    const char *source,
    const char *code,
    const char *message,
    int64_t primary,
    int64_t related
) {
    Buffer error;
    buffer_init(&error);
    buffer_format(
        &error,
        "error[%s]: %s at byte %" PRId64,
        code,
        message,
        primary
    );
    stage2_diagnostic_set(
        code,
        primary,
        token_end(source, primary),
        true,
        error.data
    );
    if (related >= 0) {
        stage2_diagnostic_related(
            related,
            token_end(source, related),
            "declared parameter"
        );
    }
    stage2_diagnostic_affected(
        STAGE2_DIAGNOSTIC_AFFECTED_CALL,
        primary,
        token_end(source, primary)
    );
    return error.data;
}

/* Bind one already-selected named call to fixed declaration-order slots.
 * Argument expressions stay in source order; only the slot vector changes. */
static char *validate_declared_call_arguments(
    const char *source,
    const char *callee,
    int64_t call_start,
    int64_t open
) {
    int64_t declaration = function_start_named(source, callee);
    if (declaration < 0) return owned_text("");
    int64_t parameters = parameter_open(source, declaration);
    int64_t parameters_end = parameters < 0
        ? -1 : balanced_end(source, parameters, "(", ")");
    int64_t close = balanced_end(source, open, "(", ")");
    if (parameters_end < 0 || close < 0) return owned_text("");

    int64_t parameter_starts[8];
    int64_t parameter_external[8];
    int64_t parameter_internal[8];
    int64_t parameter_types[8];
    int64_t bound_argument[8];
    int64_t parameter_count_value = 0;
    bool has_external_parameter = false;
    int64_t parameter = skip_trivia(source, token_end(source, parameters));
    while (parameter < parameters_end && !token_equal(source, parameter, ")")) {
        if (parameter_count_value >= 8) break;
        int64_t internal = parameter_internal_start(
            source,
            parameter,
            parameters_end
        );
        int64_t type = parameter_type_start(source, parameter, parameters_end);
        if (internal < 0 || type < 0) return owned_text("");
        parameter_starts[parameter_count_value] = parameter;
        parameter_external[parameter_count_value] = parameter_external_start(
            source,
            parameter,
            parameters_end
        );
        parameter_internal[parameter_count_value] = internal;
        has_external_parameter = has_external_parameter ||
            parameter_external[parameter_count_value] >= 0;
        parameter_types[parameter_count_value] = type;
        bound_argument[parameter_count_value] = -1;
        ++parameter_count_value;
        int64_t type_end = callable_type_end(source, type);
        int64_t list_end = parameter_list_type_end(
            source,
            type,
            parameters_end
        );
        if (type_end < 0) type_end = list_end >= 0
            ? list_end : annotation_type_end(source, type);
        int64_t separator = skip_trivia(source, type_end);
        parameter = separator < parameters_end &&
            token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator)) : separator;
    }
    if (!has_external_parameter &&
        !call_has_labelled_argument(source, open)) {
        return owned_text("");
    }

    bool saw_label = false;
    int64_t next_positional = 0;
    int64_t source_index = 0;
    int64_t argument = skip_trivia(source, token_end(source, open));
    while (argument < close && !token_equal(source, argument, ")")) {
        int64_t label = -1;
        int64_t value = argument;
        if (parameter_word_token(source, argument)) {
            int64_t colon = skip_trivia(source, token_end(source, argument));
            if (colon < close && token_equal(source, colon, ":")) {
                label = argument;
                value = skip_trivia(source, token_end(source, colon));
            }
        }
        int64_t slot = -1;
        if (label >= 0) {
            saw_label = true;
            for (int64_t index = 0; index < parameter_count_value; ++index) {
                if (parameter_external[index] >= 0 &&
                    source_tokens_equal(source, label, parameter_external[index])) {
                    slot = index;
                    break;
                }
            }
            if (slot < 0) {
                int64_t related = -1;
                for (int64_t index = 0; index < parameter_count_value; ++index) {
                    if (source_tokens_equal(source, label, parameter_internal[index])) {
                        related = parameter_internal[index];
                        break;
                    }
                }
                char *label_text = token_copy(source, label);
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    related >= 0
                        ? "label `%s` names an internal or unlabelled parameter"
                        : "unknown call label `%s`",
                    label_text
                );
                free(label_text);
                char *error = call_binding_failure(
                    source,
                    related >= 0 ? "E2S166" : "E2S162",
                    message.data,
                    label,
                    related
                );
                free(message.data);
                return error;
            }
            if (bound_argument[slot] >= 0) {
                char *label_text = token_copy(source, label);
                Buffer message;
                buffer_init(&message);
                buffer_format(&message, "duplicate call label `%s`", label_text);
                free(label_text);
                char *error = call_binding_failure(
                    source,
                    "E2S163",
                    message.data,
                    label,
                    parameter_external[slot]
                );
                free(message.data);
                return error;
            }
        } else {
            if (saw_label) {
                return call_binding_failure(
                    source,
                    "E2S165",
                    "positional argument follows a labelled argument",
                    argument,
                    -1
                );
            }
            while (next_positional < parameter_count_value &&
                   bound_argument[next_positional] >= 0) {
                ++next_positional;
            }
            if (next_positional >= parameter_count_value) break;
            slot = next_positional++;
            if (parameter_external[slot] >= 0) {
                return call_binding_failure(
                    source,
                    "E2S164",
                    "labelled parameter requires its external label",
                    argument,
                    parameter_external[slot]
                );
            }
        }
        bound_argument[slot] = argument;
        char *external = parameter_external[slot] >= 0
            ? token_copy(source, parameter_external[slot])
            : owned_text("unlabelled");
        char *internal = token_copy(source, parameter_internal[slot]);
        char *type = parameter_list_type_end(
                source,
                parameter_types[slot],
                parameters_end
            ) >= 0
            ? parameter_list_type_text(
                source,
                parameter_types[slot],
                parameters_end
            )
            : annotation_type_text(source, parameter_types[slot]);
        char *mode = ownership_mode_token(source, parameter_starts[slot])
            ? token_copy(source, parameter_starts[slot])
            : owned_text("copy");
        stage2_semantic_observe(
            "call-argument|%s|%" PRId64 "|%" PRId64
            "|%" PRId64 "|%" PRId64 "|%s|%s|%s|%s\n",
            callee,
            slot,
            source_index,
            argument,
            value,
            external,
            internal,
            type,
            mode
        );
        free(mode);
        free(type);
        free(internal);
        free(external);
        ++source_index;
        int64_t end = argument_end(source, argument);
        if (end < 0) break;
        int64_t separator = skip_trivia(source, end);
        argument = separator < close && token_equal(source, separator, ",")
            ? skip_trivia(source, token_end(source, separator)) : separator;
    }

    for (int64_t slot = 0; slot < parameter_count_value; ++slot) {
        if (bound_argument[slot] < 0) {
            int64_t declared = parameter_external[slot] >= 0
                ? parameter_external[slot] : parameter_internal[slot];
            char *name = token_copy(source, declared);
            Buffer message;
            buffer_init(&message);
            buffer_format(&message, "missing argument `%s`", name);
            free(name);
            char *error = call_binding_failure(
                source,
                "E2S164",
                message.data,
                call_start,
                declared
            );
            free(message.data);
            return error;
        }
    }
    return owned_text("");
}

static char *validate_record_uses(const char *source) {
    int64_t length = (int64_t)strlen(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = balanced_end(
            source,
            parameters,
            "(",
            ")"
        );
        int64_t function_open = skip_trivia(source, parameters_close);
        while (
            function_open < function_close &&
            !token_equal(source, function_open, "{")
        ) {
            function_open = skip_trivia(
                source,
                token_end(source, function_open)
            );
        }
        int64_t cursor = skip_trivia(
            source,
            token_end(source, function_open)
        );
        while (cursor < function_close) {
            if (strcmp(token_kind(source, cursor), "identifier") == 0) {
                char *name = token_copy(source, cursor);
                int64_t open = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                bool construction =
                    open < function_close &&
                    token_equal(source, open, "(") &&
                    record_declaration_start(source, name) >= 0;
                free(name);
                if (
                    construction &&
                    !record_initializer_constructor_token(
                        source,
                        function_open,
                        cursor
                    )
                ) {
                    return lower_error(
                        "E2S32",
                        "bind record construction to an explicitly typed "
                        "immutable record before using it",
                        cursor
                    );
                }
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

static char *validate_core_calls(const char *source, const char *hir) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    char *previous = owned_text("");
    while (cursor < length) {
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            char *name = token_copy(source, cursor);
            int64_t open = skip_trivia(source, token_end(source, cursor));
            /*
             * `C(x)` on a declared enum constructor applies a constructor; it
             * is not a call.  Where such an application may appear is decided
             * by the enum guard in the scope HIR, whose diagnostic names the
             * constructor and its enum, so reporting an unknown callee here
             * would replace that with a misleading one.
             */
            char *constructor_owner = enum_constructor_owner(source, name);
            bool constructor_application =
                (
                    constructor_owner[0] != '\0' ||
                    record_declaration_start(source, name) >= 0
                ) &&
                function_arity(source, name) < 0;
            free(constructor_owner);
            if (
                strcmp(previous, "fn") != 0 &&
                strcmp(previous, ".") != 0 &&
                strcmp(name, "print") != 0 &&
                !constructor_application &&
                open < length &&
                token_equal(source, open, "(")
            ) {
                int64_t expected = function_arity(source, name);
                if (expected >= 0) {
                    char *binding_error = validate_declared_call_arguments(
                        source,
                        name,
                        cursor,
                        open
                    );
                    if (binding_error[0] != '\0') {
                        free(name);
                        free(previous);
                        return binding_error;
                    }
                    free(binding_error);
                }
                if (expected == -2) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S16]: duplicate Core function `%s` "
                        "at byte %" PRId64,
                        name,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S16",
                        cursor,
                        token_end(source, cursor),
                        true,
                        error.data
                    );
                    stage2_diagnostic_affected(
                        STAGE2_DIAGNOSTIC_AFFECTED_CALL,
                        cursor,
                        token_end(source, cursor)
                    );
                    free(name);
                    free(previous);
                    return error.data;
                }
                if (expected < 0) {
                    /* A callee the scope HIR bound to a lambda is lifted to a
                     * top-level function, so it is a known callee even though
                     * it is absent from the source's function table. Feeding
                     * its arity back into `expected` gives a lambda call the
                     * same arity diagnostic a named call already gets. */
                    expected = lambda_call_arity(source, hir, cursor);
                }
                if (expected < 0) {
                    /* A callee bound to a callable-typed parameter is called
                     * through the pointer it holds. Its arity is declared by
                     * the type, so the same arity diagnostic applies. */
                    expected = callable_call_arity(source, hir, cursor);
                }
                if (expected < 0) {
                    int64_t builtin_expected = builtin_arity(name);
                    if (builtin_expected < 0) {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S16]: unknown Core function `%s` "
                            "at byte %" PRId64,
                            name,
                            cursor
                        );
                        stage2_diagnostic_set(
                            "E2S16",
                            cursor,
                            token_end(source, cursor),
                            true,
                            error.data
                        );
                        stage2_diagnostic_affected(
                            STAGE2_DIAGNOSTIC_AFFECTED_CALL,
                            cursor,
                            token_end(source, cursor)
                        );
                        free(name);
                        free(previous);
                        return error.data;
                    }
                    int64_t builtin_actual = call_arity(source, open);
                    if (builtin_actual != builtin_expected) {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S17]: Core function `%s` expects %" PRId64
                            " arguments, got %" PRId64 " at byte %" PRId64,
                            name,
                            builtin_expected,
                            builtin_actual,
                            cursor
                        );
                        stage2_diagnostic_set(
                            "E2S17",
                            cursor,
                            token_end(source, cursor),
                            true,
                            error.data
                        );
                        free(name);
                        free(previous);
                        return error.data;
                    }
                    char *argument_error = builtin_argument_check(
                        source,
                        hir,
                        name,
                        cursor,
                        open
                    );
                    if (argument_error[0] != '\0') {
                        free(name);
                        free(previous);
                        return argument_error;
                    }
                    free(argument_error);
                    if (
                        strcmp(name, "len") == 0 ||
                        strcmp(name, "text_slice") == 0 ||
                        strcmp(name, "to_text") == 0
                    ) {
                        expected = builtin_expected;
                    } else {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S10]: unsupported Core builtin call `%s` "
                            "at byte %" PRId64,
                            name,
                            cursor
                        );
                        stage2_diagnostic_set(
                            "E2S10",
                            cursor,
                            token_end(source, cursor),
                            true,
                            error.data
                        );
                        free(name);
                        free(previous);
                        return error.data;
                    }
                }
                int64_t actual = call_arity(source, open);
                if (actual != expected) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S17]: Core function `%s` expects %" PRId64
                        " arguments, got %" PRId64 " at byte %" PRId64,
                        name,
                        expected,
                        actual,
                        cursor
                    );
                    stage2_diagnostic_set(
                        "E2S17",
                        cursor,
                        token_end(source, cursor),
                        true,
                        error.data
                    );
                    free(name);
                    free(previous);
                    return error.data;
                }
                {
                    int64_t call_end = balanced_end(
                        source,
                        open,
                        "(",
                        ")"
                    );
                    char *return_type = function_return_type(
                        source,
                        name
                    );
                    if (call_end >= 0 && return_type[0] != '\0') {
                        stage2_semantic_observe(
                            "call|function|%s|%" PRId64 "|%" PRId64
                            "|%s\n",
                            name,
                            cursor,
                            call_end,
                            return_type
                        );
                    }
                    free(return_type);
                }
            }
            free(name);
        }
        free(previous);
        previous = token_copy(source, cursor);
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    free(previous);
    return owned_text("ok");
}

static char *malformed_core_parameters_error(void) {
    char *error = owned_text(
        "error[E2S15]: malformed Core parameter list"
    );
    stage2_diagnostic_set("E2S15", 0, 0, false, error);
    return error;
}

static char *core_parameters(
    const char *source,
    const char *hir,
    int64_t function_start
) {
    int64_t parameters = parameter_open(source, function_start);
    if (parameters < 0) {
        return malformed_core_parameters_error();
    }
    int64_t parameters_end = balanced_end(source, parameters, "(", ")");
    if (parameters_end < 0) {
        return malformed_core_parameters_error();
    }
    int64_t cursor = skip_trivia(source, token_end(source, parameters));
    Buffer emitted;
    buffer_init(&emitted);
    int64_t count = 0;
    while (cursor < parameters_end && !token_equal(source, cursor, ")")) {
        int64_t name_at = parameter_internal_start(
            source,
            cursor,
            parameters_end
        );
        int64_t type_cursor = parameter_type_start(
            source,
            cursor,
            parameters_end
        );
        if (name_at < 0 || type_cursor < 0 ||
            strcmp(token_kind(source, name_at), "identifier") != 0) {
            free(emitted.data);
            return lower_error(
                "E2S15",
                "expected Core parameter name",
                cursor
            );
        }
        char *name = token_copy(source, name_at);
        if (type_cursor >= parameters_end) {
            free(name);
            free(emitted.data);
            return lower_error(
                "E2S15",
                "Core parameters must have type Int, Text, a concrete enum, "
                "or a nominal record",
                cursor
            );
        }
        /* A callable parameter type is checked before `Int` because its own
         * domain may be the single token `Int`: `f: Int -> Int` starts exactly
         * like `f: Int` and only the `->` after it tells them apart. */
        int64_t callable_end = callable_type_end(source, type_cursor);
        int64_t type_end = -1;
        char *binding_id = hir_definition_id_at(hir, name_at);
        char *declarator = NULL;
        if (callable_end >= 0 && callable_end <= parameters_end) {
            type_end = callable_end;
            Buffer pointer_name;
            buffer_init(&pointer_name);
            buffer_format(&pointer_name, "k_b%s", binding_id);
            declarator = callable_c_declarator(
                source,
                type_cursor,
                pointer_name.data
            );
            free(pointer_name.data);
        } else if (optional_int_type_end(source, type_cursor) >= 0) {
            /* #924: a same-typed `Int?` argument crosses by value, tag and
             * payload together. */
            type_end = optional_int_type_end(source, type_cursor);
            Buffer optional;
            buffer_init(&optional);
            buffer_format(
                &optional,
                OPTIONAL_INT_C_TYPE " k_b%s",
                binding_id
            );
            declarator = optional.data;
        } else if (token_equal(source, type_cursor, "Int")) {
            type_end = token_end(source, type_cursor);
            Buffer plain;
            buffer_init(&plain);
            buffer_format(&plain, "int64_t k_b%s", binding_id);
            declarator = plain.data;
        } else if (token_equal(source, type_cursor, "Text")) {
            type_end = token_end(source, type_cursor);
            Buffer plain;
            buffer_init(&plain);
            buffer_format(&plain, "const char *k_b%s", binding_id);
            declarator = plain.data;
        } else if (list_int_type_end(source, type_cursor) >= 0) {
            type_end = list_int_type_end(source, type_cursor);
            Buffer list;
            buffer_init(&list);
            buffer_format(&list, "KofunIntListValue k_b%s", binding_id);
            declarator = list.data;
        } else if (
            ownership_mode_token(source, cursor) &&
            parameter_list_type_end(source, type_cursor, parameters_end) >= 0
        ) {
            char *list_type = parameter_list_type_text(
                source,
                type_cursor,
                parameters_end
            );
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "unsupported Core parameter type %s",
                list_type
            );
            char *error = lower_error(
                "E2S10",
                message.data,
                type_cursor
            );
            free(message.data);
            free(list_type);
            free(binding_id);
            free(name);
            free(emitted.data);
            return error;
        } else if (
            strcmp(token_kind(source, type_cursor), "identifier") == 0
        ) {
            char *parameter_type = token_copy(source, type_cursor);
            if (enum_constructor_count(source, parameter_type) >= 0) {
                type_end = token_end(source, type_cursor);
                Buffer aggregate;
                buffer_init(&aggregate);
                buffer_format(
                    &aggregate,
                    "KofunEnumValue k_b%s",
                    binding_id
                );
                declarator = aggregate.data;
            } else if (
                record_declaration_start(source, parameter_type) >= 0
            ) {
                type_end = annotation_type_end(source, type_cursor);
                char *parameter_identity = annotation_type_text(
                    source,
                    type_cursor
                );
                char *c_type = record_c_type_name(parameter_identity);
                free(parameter_identity);
                Buffer aggregate;
                buffer_init(&aggregate);
                buffer_format(
                    &aggregate,
                    "%s k_b%s",
                    c_type,
                    binding_id
                );
                free(c_type);
                declarator = aggregate.data;
            }
            free(parameter_type);
        }
        free(binding_id);
        if (type_end < 0) {
            free(declarator);
            free(name);
            free(emitted.data);
            return lower_error(
                "E2S15",
                "Core parameters must have type Int, Text, a concrete enum, "
                "or a nominal record",
                cursor
            );
        }
        if (count > 0) buffer_append(&emitted, ", ");
        buffer_append(&emitted, declarator);
        free(declarator);
        free(name);
        ++count;
        int64_t separator = skip_trivia(source, type_end);
        if (separator < parameters_end && token_equal(source, separator, ",")) {
            cursor = skip_trivia(source, token_end(source, separator));
        } else {
            cursor = separator;
        }
    }
    return emitted.data;
}

/* `initializer_type` deliberately types an entire condition as Bool. Text
 * comparison lowering needs the type of only its left primary. */
static bool primary_is_text(
    const char *source,
    const char *hir,
    int64_t start
) {
    return text_operand(
        source,
        hir,
        enclosing_function_open(source, start),
        start
    );
}

static bool comparison_operator(const char *source, int64_t cursor) {
    return token_equal(source, cursor, "==") ||
           token_equal(source, cursor, "!=") ||
           token_equal(source, cursor, "<") ||
           token_equal(source, cursor, "<=") ||
           token_equal(source, cursor, ">") ||
           token_equal(source, cursor, ">=");
}

static int64_t condition_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (
        token_equal(source, cursor, "true") ||
        token_equal(source, cursor, "false")
    ) {
        return token_end(source, cursor);
    }
    int64_t left_end = expression_end(source, cursor);
    if (left_end < 0) return -1;
    int64_t operator_start = skip_trivia(source, left_end);
    if (
        operator_start >= length ||
        !comparison_operator(source, operator_start)
    ) {
        int64_t member = skip_trivia(
            source,
            token_end(source, cursor)
        );
        return member < left_end && token_equal(source, member, ".")
            ? left_end
            : -1;
    }
    int64_t right_start = skip_trivia(
        source,
        token_end(source, operator_start)
    );
    return expression_end(source, right_start);
}

/*
 * #924: `Optional(Int)` as an executable value.
 *
 * The bytes are not invented here. `spec/aggregate-layout-v1/examples/
 * core.x86_64-linux.json` carries the accepted `Optional[Int]` descriptor —
 * `kind` optional, `size` 16, `align` 8, `tag_width` 1 at `tag_offset` 0,
 * `payload_offset` 8, `payload_size` 8, constructors `None` at tag 0 with no
 * payload and `Some` at tag 1 carrying the `Int` — and the C struct below is
 * that descriptor written as a type. `spec/aggregate-layout-v1.md` says the
 * tag is explicit and that "no backend may invent its own niche
 * optimization", so the discriminant is a byte of its own rather than a spare
 * bit pattern, and the six generated `_Static_assert`s fail the translation
 * unit if any quantity drifts from the descriptor.
 *
 * What executes: construction from `null` and, under an explicit `Int?`
 * annotation, from an `Int`; a value crossing a same-typed argument and
 * return without losing its tag; and the four recognized narrowing shapes of
 * `docs/TYPE_SYSTEM.md` plus the definitely-returning guard, lowered so the
 * narrowed use runs. Presence is observed by printing the narrowed `Int`.
 *
 * What is deliberately absent: `??`, `?` propagation, safe navigation,
 * Optional `match`, and any extraction or force unwrap. No operation here
 * reads the payload without the tag having been tested on a dominating edge —
 * `validate_optional_uses` refuses every use that is not on one, so the
 * projection in `emit_primary` is a consequence of a proof rather than an
 * assumption.
 *
 * Every `Optional(Int)` binding in this slice is immutable: parameters are
 * by-value and `let mut x: Int?` is refused. The invalidation rules that need
 * mutation — reassignment, an `edit`/`own`/unknown-effect call on a mutable
 * binding, and a loop backedge that is not loop-invariant — therefore cannot
 * arise here, because the declaration that would create one is refused first.
 * `tests/conformance/optional-narrowing/run.sh` continues to pin those rules
 * for the frontend, which does admit a mutable `Int?`.
 */

typedef enum {
    OPTIONAL_CONDITION_NONE,
    OPTIONAL_CONDITION_PRESENT, /* `!=`: refined on the true edge */
    OPTIONAL_CONDITION_ABSENT   /* `==`: refined on the false edge */
} OptionalCondition;

/* The `fn` token of the function containing `position`, or -1. */
static int64_t optional_int_function_start(
    const char *source,
    int64_t position
) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        int64_t end = function_end(source, cursor);
        if (position >= cursor && position < end) return cursor;
        if (end <= cursor) break;
        cursor = next_function_start(source, end);
    }
    return -1;
}

/* Declared result `Int?` of the function starting at `function_start`. */
static bool optional_int_result_at(
    const char *source,
    int64_t function_start
) {
    int64_t length = source_length(source);
    int64_t open = parameter_open(source, function_start);
    if (open < 0) return false;
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return false;
    int64_t arrow = skip_trivia(source, close);
    if (arrow >= length || !token_equal(source, arrow, "->")) return false;
    return optional_int_type_end(
               source,
               skip_trivia(source, token_end(source, arrow))
           ) >= 0;
}

static bool optional_int_result(const char *source, const char *wanted) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        char *name = function_name(source, cursor);
        bool match = strcmp(name, wanted) == 0;
        free(name);
        if (match) return optional_int_result_at(source, cursor);
        int64_t end = function_end(source, cursor);
        if (end <= cursor) break;
        cursor = next_function_start(source, end);
    }
    return false;
}

static bool optional_int_result_containing(
    const char *source,
    int64_t position
) {
    int64_t function_start = optional_int_function_start(source, position);
    return function_start >= 0 &&
           optional_int_result_at(source, function_start);
}

/*
 * An `Optional(Int)` binding of the function containing `position`: a
 * parameter declared `Int?`, or a `let` annotated `Int?`. Nothing else in
 * this slice carries that type, so the judgement is a scan of the declaring
 * text rather than a second type environment.
 */
static bool optional_int_binding(
    const char *source,
    int64_t position,
    const char *name
) {
    if (!source_uses_optional_int(source)) return false;
    int64_t function_start = optional_int_function_start(source, position);
    if (function_start < 0) return false;
    int64_t open = parameter_open(source, function_start);
    if (open < 0) return false;
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return false;
    int64_t parameter = skip_trivia(source, token_end(source, open));
    while (parameter < close && !token_equal(source, parameter, ")")) {
        int64_t colon = skip_trivia(source, token_end(source, parameter));
        if (colon >= close || !token_equal(source, colon, ":")) break;
        int64_t type_start = skip_trivia(source, token_end(source, colon));
        int64_t type_end = optional_int_type_end(source, type_start);
        if (type_end >= 0 && token_equal(source, parameter, name)) return true;
        if (type_end < 0) type_end = token_end(source, type_start);
        int64_t separator = skip_trivia(source, type_end);
        if (separator >= close || !token_equal(source, separator, ",")) break;
        parameter = skip_trivia(source, token_end(source, separator));
    }
    int64_t function_close = function_end(source, function_start);
    int64_t cursor = skip_trivia(source, close);
    while (cursor < function_close) {
        if (token_equal(source, cursor, "let")) {
            int64_t binding = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, binding, "mut")) {
                binding = skip_trivia(source, token_end(source, binding));
            }
            int64_t colon = skip_trivia(source, token_end(source, binding));
            if (
                token_equal(source, colon, ":") &&
                optional_int_type_end(
                    source,
                    skip_trivia(source, token_end(source, colon))
                ) >= 0 &&
                token_equal(source, binding, name)
            ) {
                return true;
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

/*
 * The one position where a bare `Optional(Int)` name lowers to the whole
 * value rather than to its payload: an argument whose declared parameter is
 * `Int?`. `return`, a `let` initializer, and the null comparison of a
 * narrowing condition are each lowered by their own statement path and never
 * reach `emit_primary`, so they need no case here.
 */
static bool optional_int_carrier_position(const char *source, int64_t at) {
    if (!source_uses_optional_int(source)) return false;
    char *expected = call_argument_expected_type(source, at);
    bool carrier = strcmp(expected, "Int?") == 0;
    free(expected);
    return carrier;
}

/*
 * One of the four recognized shapes — `x != null`, `null != x`, `x == null`,
 * `null == x` — over a direct `Optional(Int)` binding, spanning the whole of
 * `[start, end)`. Anything longer is a compound condition: still a legal
 * `Bool`, but it refines nothing.
 */
static OptionalCondition optional_int_condition(
    const char *source,
    int64_t start,
    int64_t end,
    int64_t *binding_at
) {
    int64_t left = skip_trivia(source, start);
    if (left >= end) return OPTIONAL_CONDITION_NONE;
    int64_t operator_start = skip_trivia(source, token_end(source, left));
    if (operator_start >= end) return OPTIONAL_CONDITION_NONE;
    bool present = token_equal(source, operator_start, "!=");
    if (!present && !token_equal(source, operator_start, "==")) {
        return OPTIONAL_CONDITION_NONE;
    }
    int64_t right = skip_trivia(source, token_end(source, operator_start));
    if (right >= end) return OPTIONAL_CONDITION_NONE;
    if (skip_trivia(source, token_end(source, right)) < end) {
        return OPTIONAL_CONDITION_NONE;
    }
    int64_t name_at = -1;
    if (token_equal(source, left, "null")) {
        name_at = right;
    } else if (token_equal(source, right, "null")) {
        name_at = left;
    }
    if (name_at < 0 || token_equal(source, name_at, "null")) {
        return OPTIONAL_CONDITION_NONE;
    }
    if (strcmp(token_kind(source, name_at), "identifier") != 0) {
        return OPTIONAL_CONDITION_NONE;
    }
    char *name = token_copy(source, name_at);
    bool optional = optional_int_binding(source, name_at, name);
    free(name);
    if (!optional) return OPTIONAL_CONDITION_NONE;
    if (binding_at != NULL) *binding_at = name_at;
    return present ? OPTIONAL_CONDITION_PRESENT : OPTIONAL_CONDITION_ABSENT;
}

/*
 * A block that definitely returns. A `return` at the block's own statement
 * level always runs once the block is entered, because `E2S14` already
 * refuses any statement after it.
 */
static bool optional_int_block_returns(
    const char *source,
    int64_t block_open
) {
    int64_t close = balanced_end(source, block_open, "{", "}");
    if (close < 0) return false;
    int64_t depth = 0;
    int64_t cursor = skip_trivia(source, token_end(source, block_open));
    while (cursor < close) {
        if (token_equal(source, cursor, "{")) {
            ++depth;
        } else if (token_equal(source, cursor, "}")) {
            --depth;
        } else if (depth == 0 && token_equal(source, cursor, "return")) {
            return true;
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

/*
 * Whether the use of `name` at byte `at` sits on an edge that proved the tag.
 * `x != null` refines its `if` branch; `x == null` refines its `else`; and an
 * `x == null` guard whose branch definitely returns carries the false edge
 * past the guard to the end of the enclosing function. A nested branch is
 * covered because it lies inside the dominating branch's span, and a sibling
 * branch is not, because it does not.
 */
static bool optional_int_refined(
    const char *source,
    const char *name,
    int64_t at
) {
    int64_t function_start = optional_int_function_start(source, at);
    if (function_start < 0) return false;
    int64_t function_close = function_end(source, function_start);
    int64_t cursor = skip_trivia(source, function_start);
    while (cursor < function_close) {
        if (token_equal(source, cursor, "if")) {
            int64_t condition_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t condition_close = condition_end(source, condition_start);
            int64_t name_at = -1;
            OptionalCondition kind = condition_close < 0
                ? OPTIONAL_CONDITION_NONE
                : optional_int_condition(
                      source,
                      condition_start,
                      condition_close,
                      &name_at
                  );
            if (
                kind != OPTIONAL_CONDITION_NONE &&
                token_equal(source, name_at, name)
            ) {
                int64_t branch_open = skip_trivia(source, condition_close);
                int64_t branch_close =
                    branch_open < function_close &&
                    token_equal(source, branch_open, "{")
                        ? balanced_end(source, branch_open, "{", "}")
                        : -1;
                if (branch_close > 0) {
                    int64_t after = skip_trivia(
                        source,
                        token_end(source, branch_close)
                    );
                    bool has_else = after < function_close &&
                                    token_equal(source, after, "else");
                    int64_t else_open = has_else
                        ? skip_trivia(source, token_end(source, after))
                        : -1;
                    int64_t else_close =
                        else_open >= 0 && else_open < function_close &&
                        token_equal(source, else_open, "{")
                            ? balanced_end(source, else_open, "{", "}")
                            : -1;
                    if (kind == OPTIONAL_CONDITION_PRESENT) {
                        if (at > branch_open && at < branch_close) return true;
                    } else {
                        if (
                            else_close > 0 &&
                            at > else_open && at < else_close
                        ) {
                            return true;
                        }
                        if (
                            !has_else &&
                            optional_int_block_returns(source, branch_open) &&
                            at >= token_end(source, branch_close)
                        ) {
                            return true;
                        }
                    }
                }
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

/*
 * The three positions where `null` is contextually typed as `Optional(Int)`:
 * the whole initializer of a `let ...: Int? =`, an operand of a recognized
 * null comparison, and the whole value of a `return` in a function declared
 * `Int?`. Everywhere else `null` names nothing and stays the unknown lexical
 * binding it was before this slice existed, so no program that compiles today
 * changes its verdict.
 */
static bool optional_int_coalescing_left_site(
    const char *source,
    int64_t at
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor <= at && cursor < length) {
        int64_t left_end = arithmetic_expression_end(source, cursor);
        if (left_end >= 0) {
            int64_t operator_start = skip_trivia(source, left_end);
            if (
                operator_start < length &&
                token_equal(source, operator_start, "??")
            ) {
                int64_t inner_start =
                    optional_int_coalescing_transparent_bound(
                        source,
                        cursor,
                        left_end,
                        true
                    );
                if (inner_start == at) {
                    return true;
                }
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

static bool optional_int_coalescing_null_context(
    const char *source,
    int64_t at
) {
    return token_equal(source, at, "null") &&
        optional_int_coalescing_left_site(source, at);
}

static bool optional_int_null_context(const char *source, int64_t at) {
    if (!token_equal(source, at, "null")) return false;
    if (optional_int_coalescing_null_context(source, at)) {
        return true;
    }
    int64_t function_start = optional_int_function_start(source, at);
    if (function_start < 0) return false;
    int64_t function_close = function_end(source, function_start);
    bool optional_result = optional_int_result_at(source, function_start);
    int64_t cursor = skip_trivia(source, function_start);
    while (cursor < function_close) {
        if (token_equal(source, cursor, "let")) {
            int64_t binding = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, binding, "mut")) {
                binding = skip_trivia(source, token_end(source, binding));
            }
            int64_t colon = skip_trivia(source, token_end(source, binding));
            int64_t annotation_end = token_equal(source, colon, ":")
                ? optional_int_type_end(
                      source,
                      skip_trivia(source, token_end(source, colon))
                  )
                : -1;
            int64_t assign = annotation_end < 0
                ? -1
                : skip_trivia(source, annotation_end);
            if (assign >= 0 && token_equal(source, assign, "=")) {
                int64_t value = skip_trivia(
                    source,
                    token_end(source, assign)
                );
                if (
                    value == at &&
                    skip_trivia(source, token_end(source, at)) >=
                        expression_end(source, value)
                ) {
                    return true;
                }
            }
        } else if (
            token_equal(source, cursor, "if") ||
            token_equal(source, cursor, "while")
        ) {
            int64_t condition_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t condition_close = condition_end(source, condition_start);
            int64_t name_at = -1;
            if (
                condition_close >= 0 &&
                optional_int_condition(
                    source,
                    condition_start,
                    condition_close,
                    &name_at
                ) != OPTIONAL_CONDITION_NONE &&
                at >= condition_start && at < condition_close &&
                at != name_at
            ) {
                return true;
            }
        } else if (optional_result && token_equal(source, cursor, "return")) {
            int64_t value = skip_trivia(source, token_end(source, cursor));
            if (
                value == at &&
                skip_trivia(source, token_end(source, at)) >=
                    expression_end(source, value)
            ) {
                return true;
            }
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return false;
}

/*
 * The `Optional[Int]` descriptor of `spec/aggregate-layout-v1/examples/
 * core.x86_64-linux.json`, emitted as a C type whose every quantity is
 * asserted. The asserts are the drift detector: a tag widened to `int64_t`, a
 * payload moved, or a niche packed into the tag all stop the translation unit
 * instead of quietly meaning different bytes than the descriptor.
 */
static char *emit_optional_int_c_declarations(void) {
    return owned_text(
        "typedef struct {\n"
        "    uint8_t tag;\n"
        "    int64_t payload;\n"
        "} " OPTIONAL_INT_C_TYPE ";\n"
        "_Static_assert(offsetof(" OPTIONAL_INT_C_TYPE ", tag) == 0,\n"
        "    \"AggregateLayout Optional[Int] tag offset\");\n"
        "_Static_assert(sizeof(((" OPTIONAL_INT_C_TYPE " *)0)->tag) == 1,\n"
        "    \"AggregateLayout Optional[Int] tag width\");\n"
        "_Static_assert(offsetof(" OPTIONAL_INT_C_TYPE ", payload) == 8,\n"
        "    \"AggregateLayout Optional[Int] payload offset\");\n"
        "_Static_assert(sizeof(((" OPTIONAL_INT_C_TYPE " *)0)->payload) == 8,\n"
        "    \"AggregateLayout Optional[Int] payload size\");\n"
        "_Static_assert(sizeof(" OPTIONAL_INT_C_TYPE ") == 16,\n"
        "    \"AggregateLayout Optional[Int] size\");\n"
        "_Static_assert(_Alignof(" OPTIONAL_INT_C_TYPE ") == 8,\n"
        "    \"AggregateLayout Optional[Int] alignment\");\n"
        "#define KOFUN_OPTIONAL_INT_NONE_TAG UINT8_C(0)\n"
        "#define KOFUN_OPTIONAL_INT_SOME_TAG UINT8_C(1)\n"
        "#define KOFUN_OPTIONAL_INT_NONE "
        "((" OPTIONAL_INT_C_TYPE "){KOFUN_OPTIONAL_INT_NONE_TAG, INT64_C(0)})\n"
        "#define KOFUN_OPTIONAL_INT_SOME(value) "
        "((" OPTIONAL_INT_C_TYPE "){KOFUN_OPTIONAL_INT_SOME_TAG, (value)})\n\n"
    );
}

/*
 * How many times the function containing `position` declares `name`, as a
 * parameter or as a `let`. `optional_int_binding` reads declaring text rather
 * than a scope environment, so a name declared twice in one function could
 * make it answer for the wrong declaration; two declarations are refused
 * instead.
 */
static int64_t optional_int_declaration_count(
    const char *source,
    int64_t position,
    const char *name
) {
    int64_t function_start = optional_int_function_start(source, position);
    if (function_start < 0) return 0;
    int64_t open = parameter_open(source, function_start);
    if (open < 0) return 0;
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return 0;
    int64_t count = 0;
    int64_t parameter = skip_trivia(source, token_end(source, open));
    while (parameter < close && !token_equal(source, parameter, ")")) {
        if (token_equal(source, parameter, name)) ++count;
        int64_t colon = skip_trivia(source, token_end(source, parameter));
        if (colon >= close || !token_equal(source, colon, ":")) break;
        int64_t type_start = skip_trivia(source, token_end(source, colon));
        int64_t type_end = optional_int_type_end(source, type_start);
        if (type_end < 0) type_end = token_end(source, type_start);
        int64_t separator = skip_trivia(source, type_end);
        if (separator >= close || !token_equal(source, separator, ",")) break;
        parameter = skip_trivia(source, token_end(source, separator));
    }
    int64_t function_close = function_end(source, function_start);
    int64_t cursor = skip_trivia(source, close);
    while (cursor < function_close) {
        if (token_equal(source, cursor, "let")) {
            int64_t binding = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, binding, "mut")) {
                binding = skip_trivia(source, token_end(source, binding));
            }
            if (token_equal(source, binding, name)) ++count;
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return count;
}

/*
 * Every use of an `Optional(Int)` binding must be one the slice can lower:
 * the named operand of a recognized null comparison, an argument declared
 * `Int?`, the whole value of a `return` or `let` that is itself `Int?`, or a
 * use on an edge that already proved the tag. Everything else is refused
 * here, before a single byte of C exists — which is what lets `emit_primary`
 * project the payload without re-deciding the question.
 */
static char *validate_optional_uses(const char *source) {
    int64_t length = source_length(source);
    if (!source_uses_optional_int(source)) return owned_text("ok");
    /*
     * One optional layer, as the source contract fixes it. `Int??` is refused
     * by name here rather than left to desynchronise the type grammar into a
     * diagnostic about the `=` that follows it.
     */
    int64_t scan = skip_trivia(source, 0);
    while (scan < length) {
        if (
            token_equal(source, scan, ":") ||
            token_equal(source, scan, "->")
        ) {
            int64_t type_start = skip_trivia(source, token_end(source, scan));
            int64_t type_end = optional_int_type_end(source, type_start);
            /* `??` is one token, so `Int??` never reaches the single-suffix
             * spelling and has to be recognized by the pair as well. */
            int64_t after_type = type_end >= 0
                ? skip_trivia(source, type_end)
                : (token_equal(source, type_start, "Int")
                       ? skip_trivia(source, token_end(source, type_start))
                       : -1);
            if (
                after_type >= 0 &&
                (token_equal(source, after_type, "?") ||
                 token_equal(source, after_type, "??"))
            ) {
                return lower_error(
                    "E2S147",
                    "one optional layer is supported; `Int??` is not a type "
                    "in this contract",
                    type_start
                );
            }
        }
        int64_t step = token_end(source, scan);
        if (step <= scan) break;
        scan = skip_trivia(source, step);
    }
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = parameters < 0
            ? -1
            : balanced_end(source, parameters, "(", ")");
        if (parameters_close < 0) {
            if (function_close <= function_start) break;
            function_start = next_function_start(source, function_close);
            continue;
        }
        int64_t body_open = skip_trivia(source, parameters_close);
        while (
            body_open < function_close &&
            !token_equal(source, body_open, "{")
        ) {
            int64_t step = token_end(source, body_open);
            if (step <= body_open) break;
            body_open = skip_trivia(source, step);
        }
        /*
         * One pending carrier byte is enough: each statement that names one
         * records it before the walk reaches it, and reaches it before the
         * next statement records another. `null` needs no slot — it is not a
         * binding, and `optional_int_null_context` has already decided its
         * positions in the scope HIR.
         */
        int64_t carrier = -1;
        int64_t cursor = body_open < function_close
            ? skip_trivia(source, token_end(source, body_open))
            : function_close;
        while (cursor < function_close) {
            if (token_equal(source, cursor, "let")) {
                int64_t binding = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                bool mutable = token_equal(source, binding, "mut");
                if (mutable) {
                    binding = skip_trivia(source, token_end(source, binding));
                }
                int64_t colon = skip_trivia(source, token_end(source, binding));
                int64_t annotation = token_equal(source, colon, ":")
                    ? skip_trivia(source, token_end(source, colon))
                    : -1;
                int64_t annotation_end = annotation < 0
                    ? -1
                    : optional_int_type_end(source, annotation);
                if (annotation_end >= 0) {
                    if (mutable) {
                        return lower_error(
                            "E2S147",
                            "mutable `Int?` bindings are outside this "
                            "lowering slice; declare `let` and construct a "
                            "new value instead",
                            binding
                        );
                    }
                    char *declared = token_copy(source, binding);
                    int64_t declarations = optional_int_declaration_count(
                        source,
                        binding,
                        declared
                    );
                    free(declared);
                    if (declarations > 1) {
                        return lower_error(
                            "E2S147",
                            "an `Int?` binding may not be declared twice in "
                            "one function in this lowering slice",
                            binding
                        );
                    }
                    int64_t assign = skip_trivia(source, annotation_end);
                    int64_t value = token_equal(source, assign, "=")
                        ? skip_trivia(source, token_end(source, assign))
                        : -1;
                    if (
                        value >= 0 &&
                        strcmp(token_kind(source, value), "identifier") == 0
                    ) {
                        carrier = value;
                    }
                    cursor = value >= 0 ? value : skip_trivia(source, colon);
                    continue;
                }
            }
            if (
                token_equal(source, cursor, "if") ||
                token_equal(source, cursor, "while")
            ) {
                int64_t condition_start = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                int64_t condition_close = condition_end(
                    source,
                    condition_start
                );
                int64_t name_at = -1;
                if (
                    condition_close >= 0 &&
                    optional_int_condition(
                        source,
                        condition_start,
                        condition_close,
                        &name_at
                    ) != OPTIONAL_CONDITION_NONE
                ) {
                    carrier = name_at;
                }
            } else if (
                token_equal(source, cursor, "return") &&
                optional_int_result_containing(source, function_start)
            ) {
                int64_t value = skip_trivia(source, token_end(source, cursor));
                if (
                    value < function_close &&
                    strcmp(token_kind(source, value), "identifier") == 0
                ) {
                    carrier = value;
                }
            } else if (strcmp(token_kind(source, cursor), "identifier") == 0) {
                char *name = token_copy(source, cursor);
                int64_t after = skip_trivia(source, token_end(source, cursor));
                bool call = after < function_close &&
                            token_equal(source, after, "(");
                bool optional = !call &&
                                optional_int_binding(source, cursor, name);
                char *failure = NULL;
                if (call && optional_int_result(source, name)) {
                    /* An `Int?` result travels whole or not at all: it may
                     * initialize an `Int?` binding or be returned from a
                     * function declared `Int?`, and nothing else. */
                    if (
                        cursor != carrier &&
                        !optional_int_coalescing_left_site(source, cursor)
                    ) {
                        failure = lower_error(
                            "E2S147",
                            "an `Int?` result is used whole; bind it with "
                            "`let ...: Int?` or return it from a function "
                            "declared `Int?`",
                            cursor
                        );
                    }
                } else if (optional) {
                    if (optional_int_declaration_count(source, cursor, name) > 1) {
                        failure = lower_error(
                            "E2S147",
                            "an `Int?` binding may not be declared twice in "
                            "one function in this lowering slice",
                            cursor
                        );
                    } else if (
                        after < function_close &&
                        token_equal(source, after, "=")
                    ) {
                        failure = lower_error(
                            "E2S147",
                            "an `Int?` binding is immutable in this lowering "
                            "slice and cannot be assigned",
                            cursor
                        );
                    } else if (
                        after < function_close &&
                        (token_equal(source, after, ".") ||
                         token_equal(source, after, "["))
                    ) {
                        failure = lower_error(
                            "E2S147",
                            "property and index paths on an `Int?` binding "
                            "are not narrowed; only a direct `null` "
                            "comparison is recognized",
                            cursor
                        );
                    } else if (
                        cursor != carrier &&
                        !optional_int_coalescing_left_site(source, cursor) &&
                        !optional_int_carrier_position(source, cursor) &&
                        !optional_int_refined(source, name, cursor)
                    ) {
                        /* One name, not three: the structured diagnostic
                         * carries a 160-byte fallback, and a message that
                         * grew with the binding name would be truncated
                         * there while the printed one was not. */
                        Buffer message;
                        buffer_init(&message);
                        buffer_format(
                            &message,
                            "`%s` is `Int?`; narrow it with a `null` "
                            "comparison before using it as `Int`",
                            name
                        );
                        failure = lower_error(
                            "E2S147",
                            message.data,
                            cursor
                        );
                        free(message.data);
                    }
                }
                free(name);
                if (failure != NULL) return failure;
            }
            int64_t next = token_end(source, cursor);
            if (next <= cursor) break;
            cursor = skip_trivia(source, next);
        }
        if (function_close <= function_start) break;
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

static char *emit_condition_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result,
    const char *indent
) {
    int64_t cursor = skip_trivia(source, start);
    if (
        token_equal(source, cursor, "true") ||
        token_equal(source, cursor, "false")
    ) {
        char *literal = token_copy(source, cursor);
        Buffer output;
        buffer_init(&output);
        buffer_format(
            &output,
            "%sbool %s = %s;\n",
            indent,
            target,
            literal
        );
        free(literal);
        return output.data;
    }
    {
        /* #924: a recognized null comparison is a tag test, and the tag is
         * the only thing it reads. `null` names no binding, so this has to be
         * decided before the operand grammar sees it. */
        int64_t binding_at = -1;
        OptionalCondition optional = optional_int_condition(
            source,
            cursor,
            end,
            &binding_at
        );
        if (optional != OPTIONAL_CONDITION_NONE) {
            char *binding_id = hir_use_binding_id(hir, binding_at);
            Buffer output;
            buffer_init(&output);
            buffer_format(
                &output,
                "%sbool %s = (k_b%s.tag %s KOFUN_OPTIONAL_INT_NONE_TAG);\n",
                indent,
                target,
                binding_id,
                optional == OPTIONAL_CONDITION_PRESENT ? "!=" : "=="
            );
            free(binding_id);
            return output.data;
        }
    }
    int64_t left_end = expression_end(source, cursor);
    int64_t operator_start = skip_trivia(source, left_end);
    if (
        operator_start >= end ||
        !comparison_operator(source, operator_start)
    ) {
        char *value = emit_expression(source, hir, cursor, left_end);
        /* A rejected bare condition became the condition's C text. */
        if (strncmp(value, "error[", 6) == 0) return value;
        Buffer output;
        buffer_init(&output);
        buffer_format(
            &output,
            "%sbool %s = %s;\n",
            indent,
            target,
            value
        );
        free(value);
        return output.data;
    }
    int64_t right_start = skip_trivia(
        source,
        token_end(source, operator_start)
    );
    char *left = emit_expression(source, hir, cursor, left_end);
    char *operator_text = token_copy(source, operator_start);
    char *right = emit_expression(source, hir, right_start, end);
    /* A rejected comparison operand became the condition's C text. */
    if (strncmp(left, "error[", 6) == 0) {
        free(right);
        free(operator_text);
        return left;
    }
    if (strncmp(right, "error[", 6) == 0) {
        free(left);
        free(operator_text);
        return right;
    }
    Buffer output;
    buffer_init(&output);
    int64_t function_open = enclosing_function_open(source, cursor);
    const char *type = numeric_primary_type(
        source,
        hir,
        function_open,
        cursor
    );
    if (primary_is_text(source, hir, cursor)) {
        const char *comparison = "== 0";
        if (strcmp(operator_text, "!=") == 0) comparison = "!= 0";
        else if (strcmp(operator_text, "<") == 0) comparison = "< 0";
        else if (strcmp(operator_text, "<=") == 0) comparison = "<= 0";
        else if (strcmp(operator_text, ">") == 0) comparison = "> 0";
        else if (strcmp(operator_text, ">=") == 0) comparison = ">= 0";
        buffer_format(
            &output,
            "%sconst char *kofun_condition_left = %s;\n"
            "%sconst char *kofun_condition_right = %s;\n"
            "%sbool %s = strcmp(kofun_condition_left, "
            "kofun_condition_right) %s;\n",
            indent,
            left,
            indent,
            right,
            indent,
            target,
            comparison
        );
    } else if (strcmp(type, "Decimal") == 0) {
        const char *comparison = "== 0";
        if (strcmp(operator_text, "!=") == 0) comparison = "!= 0";
        else if (strcmp(operator_text, "<") == 0) comparison = "< 0";
        else if (strcmp(operator_text, "<=") == 0) comparison = "<= 0";
        else if (strcmp(operator_text, ">") == 0) comparison = "> 0";
        else if (strcmp(operator_text, ">=") == 0) comparison = ">= 0";
        buffer_format(
            &output,
            "%sKofunDecimal *kofun_condition_left = %s;\n"
            "%sKofunDecimal *kofun_condition_right = %s;\n"
            "%sbool %s = kofun_decimal_compare("
            "kofun_condition_left, kofun_condition_right) %s;\n",
            indent,
            left,
            indent,
            right,
            indent,
            target,
            comparison
        );
    } else if (strcmp(type, "Float") == 0) {
        buffer_format(
            &output,
            "%sdouble kofun_condition_left = %s;\n"
            "%sdouble kofun_condition_right = %s;\n"
            "%sbool %s = kofun_condition_left %s kofun_condition_right;\n",
            indent,
            left,
            indent,
            right,
            indent,
            target,
            operator_text
        );
    } else {
        buffer_format(
            &output,
            "%sint64_t kofun_condition_left = %s;\n"
            "%sif (kofun_failed) return %s;\n"
            "%sint64_t kofun_condition_right = %s;\n"
            "%sif (kofun_failed) return %s;\n"
            "%sbool %s = kofun_condition_left %s kofun_condition_right;\n",
            indent,
            left,
            indent,
            failure_result,
            indent,
            right,
            indent,
            failure_result,
            indent,
            target,
            operator_text
        );
    }
    free(left);
    free(operator_text);
    free(right);
    return output.data;
}

/*
 * The byte after the `{ ... }` that follows an `if` condition, or -1 when the
 * shape is not a statement `if` at all. This is the walk the statement
 * lowering performs; it exists separately so the lowering can ask where the
 * construct ends *before* committing to lower it, which is what deciding
 * whether an `if` is a body's last statement requires.
 */
static int64_t if_then_branch_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t condition_start = skip_trivia(source, token_end(source, start));
    int64_t condition_close = condition_end(source, condition_start);
    if (condition_close < 0) return -1;
    int64_t branch_open = skip_trivia(source, condition_close);
    if (branch_open >= length || !token_equal(source, branch_open, "{")) {
        return -1;
    }
    return balanced_end(source, branch_open, "{", "}");
}

/*
 * Whether the `if` at `start` carries an `else` block. An `if` in final
 * position without one cannot be the result: its false path produces nothing.
 */
static bool if_has_else(const char *source, int64_t start) {
    int64_t branch_close = if_then_branch_end(source, start);
    if (branch_close < 0) return false;
    int64_t else_keyword = skip_trivia(source, branch_close);
    return else_keyword < source_length(source) &&
           token_equal(source, else_keyword, "else");
}

/*
 * The byte after a statement-position `if`, counting its `else` block when one
 * follows, or -1 when the shape is not a statement `if` at all.
 */
static int64_t if_statement_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t branch_close = if_then_branch_end(source, start);
    if (branch_close < 0) return -1;
    if (!if_has_else(source, start)) return branch_close;
    int64_t else_keyword = skip_trivia(source, branch_close);
    int64_t else_open = skip_trivia(source, token_end(source, else_keyword));
    if (else_open >= length || !token_equal(source, else_open, "{")) {
        return -1;
    }
    return balanced_end(source, else_open, "{", "}");
}

/*
 * Whether the `if` at `start` is the last statement of a body that owes its
 * caller an Int result — the position where #550 makes it the function's value
 * rather than a discarded statement. `main`, enum-returning, and
 * record-returning functions are excluded: `main` appends its own status
 * return, and an enum or record result needs its own C shape rather than the
 * `int64_t` this position emits. A nested body (`append_default` false) is not
 * a result position either; its own enclosing function decides that.
 */
static bool final_result_if(
    const char *source,
    int64_t start,
    bool is_main,
    bool append_default,
    bool returns_enum,
    bool returns_record
) {
    if (is_main || !append_default || returns_enum || returns_record) {
        return false;
    }
    int64_t close = if_statement_end(source, start);
    if (close < 0) return false;
    int64_t after = skip_trivia(source, close);
    return after < source_length(source) &&
           token_equal(source, after, "}");
}

typedef struct {
    int64_t condition_start;
    int64_t condition_end;
    int64_t then_start;
    int64_t then_end;
    int64_t else_start;
    int64_t else_end;
    int64_t end;
} ValueIfParts;

typedef struct {
    int64_t value_start;
    int64_t value_end;
    int64_t arms_open;
    int64_t end;
} ValueMatchParts;

static char *parse_value_if(
    const char *source,
    const char *hir,
    int64_t start,
    ValueIfParts *parts
);

static char *parse_value_match(
    const char *source,
    const char *hir,
    int64_t start,
    ValueMatchParts *parts
);

static char *value_if_branch_end(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t *end
) {
    int64_t cursor = skip_trivia(source, start);
    if (token_equal(source, cursor, "print")) {
        return lower_error(
            "E2S28",
            "value-position if branch must produce Int, not Void",
            cursor
        );
    }
    if (token_equal(source, cursor, "if")) {
        ValueIfParts nested;
        char *result = parse_value_if(source, hir, cursor, &nested);
        if (strncmp(result, "error[", 6) == 0) return result;
        free(result);
        *end = nested.end;
        return owned_text("ok");
    }
    if (token_equal(source, cursor, "match")) {
        ValueMatchParts nested;
        char *result = parse_value_match(source, hir, cursor, &nested);
        if (strncmp(result, "error[", 6) == 0) return result;
        free(result);
        *end = nested.end;
        return owned_text("ok");
    }
    *end = expression_end(source, cursor);
    if (*end < 0) {
        return lower_error(
            "E2S28",
            "value-position if branch must produce Int",
            cursor
        );
    }
    return owned_text("ok");
}

static char *parse_value_if(
    const char *source,
    const char *hir,
    int64_t start,
    ValueIfParts *parts
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length || !token_equal(source, cursor, "if")) {
        return lower_error(
            "E2S28",
            "expected value-position `if`",
            cursor
        );
    }

    parts->condition_start = skip_trivia(
        source,
        token_end(source, cursor)
    );
    parts->condition_end = condition_end(source, parts->condition_start);
    if (parts->condition_end < 0) {
        return lower_error(
            "E2S23",
            "if condition must be Bool or an Int comparison",
            parts->condition_start
        );
    }

    int64_t then_open = skip_trivia(source, parts->condition_end);
    if (then_open >= length || !token_equal(source, then_open, "{")) {
        return lower_error(
            "E2S18",
            "expected `{` after if condition",
            then_open
        );
    }
    parts->then_start = skip_trivia(
        source,
        token_end(source, then_open)
    );
    char *then_result = value_if_branch_end(
        source,
        hir,
        parts->then_start,
        &parts->then_end
    );
    if (strncmp(then_result, "error[", 6) == 0) return then_result;
    free(then_result);
    int64_t then_close = skip_trivia(source, parts->then_end);
    if (then_close >= length || !token_equal(source, then_close, "}")) {
        return lower_error(
            "E2S28",
            "value-position if branch must contain one final Int expression",
            then_close
        );
    }

    int64_t else_keyword = skip_trivia(
        source,
        token_end(source, then_close)
    );
    if (
        else_keyword >= length ||
        !token_equal(source, else_keyword, "else")
    ) {
        return lower_error(
            "E2S27",
            "value-position if requires `else`",
            else_keyword
        );
    }
    int64_t else_open = skip_trivia(
        source,
        token_end(source, else_keyword)
    );
    if (else_open >= length || !token_equal(source, else_open, "{")) {
        return lower_error(
            "E2S18",
            "expected `{` after `else`",
            else_open
        );
    }
    parts->else_start = skip_trivia(
        source,
        token_end(source, else_open)
    );
    char *else_result = value_if_branch_end(
        source,
        hir,
        parts->else_start,
        &parts->else_end
    );
    if (strncmp(else_result, "error[", 6) == 0) return else_result;
    free(else_result);
    int64_t else_close = skip_trivia(source, parts->else_end);
    if (else_close >= length || !token_equal(source, else_close, "}")) {
        return lower_error(
            "E2S28",
            "value-position if branch must contain one final Int expression",
            else_close
        );
    }
    parts->end = token_end(source, else_close);
    stage2_semantic_observe(
        "control|if|%" PRId64 "|%" PRId64 "|Int|%" PRId64
        "|%" PRId64 "\n",
        cursor,
        parts->end,
        parts->condition_start,
        parts->condition_end
    );
    return owned_text("ok");
}

/*
 * The enum a value-position `match` scrutinises, or "" when it does not
 * scrutinise one; and the value-position enum rules themselves, which live
 * beside `lower_enum_match` because they read the same declared constructor
 * set.
 */
static char *value_match_enum_type(
    const char *source,
    const char *hir,
    int64_t start
);

static char *parse_value_arm(
    const char *source,
    const char *hir,
    int64_t arm_open,
    int64_t *arm_close
);

static char *parse_value_enum_match(
    const char *source,
    const char *hir,
    int64_t start,
    const char *enum_type,
    ValueMatchParts *parts
);

static char *emit_value_enum_match_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result,
    const char *enum_type
);

static char *parse_value_match(
    const char *source,
    const char *hir,
    int64_t start,
    ValueMatchParts *parts
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length || !token_equal(source, cursor, "match")) {
        return lower_error(
            "E2S30",
            "expected value-position `match`",
            cursor
        );
    }

    char *enum_type = value_match_enum_type(source, hir, cursor);
    if (enum_type[0] != '\0') {
        char *result = parse_value_enum_match(
            source,
            hir,
            cursor,
            enum_type,
            parts
        );
        free(enum_type);
        return result;
    }
    free(enum_type);

    parts->value_start = skip_trivia(source, token_end(source, cursor));
    parts->value_end = condition_end(source, parts->value_start);
    if (parts->value_end < 0) {
        return lower_error(
            "E2S24",
            "bounded match scrutinee must be Bool",
            parts->value_start
        );
    }
    parts->arms_open = skip_trivia(source, parts->value_end);
    if (
        parts->arms_open >= length ||
        !token_equal(source, parts->arms_open, "{")
    ) {
        return lower_error(
            "E2S24",
            "expected `{` after match scrutinee",
            parts->arms_open
        );
    }

    int64_t arm_cursor = skip_trivia(
        source,
        token_end(source, parts->arms_open)
    );
    bool covered_true = false;
    bool covered_false = false;
    bool seen_catchall = false;
    while (
        arm_cursor < length &&
        !token_equal(source, arm_cursor, "}")
    ) {
        int64_t pattern_start = arm_cursor;
        PatternSummary pattern = pattern_summary(source, pattern_start);
        bool pattern_true = pattern.kind == PATTERN_LITERAL &&
                            token_equal(source, pattern_start, "true");
        bool pattern_false = pattern.kind == PATTERN_LITERAL &&
                             token_equal(source, pattern_start, "false");
        bool pattern_catchall = pattern.kind == PATTERN_WILDCARD;
        if (seen_catchall) {
            return lower_error(
                "E2S26",
                "pattern after catch-all is unreachable",
                pattern_start
            );
        }
        if (pattern_true && covered_true) {
            return lower_error(
                "E2S26",
                "duplicate `true` pattern is unreachable",
                pattern_start
            );
        }
        if (pattern_false && covered_false) {
            return lower_error(
                "E2S26",
                "duplicate `false` pattern is unreachable",
                pattern_start
            );
        }
        if (pattern_catchall && covered_true && covered_false) {
            return lower_error(
                "E2S26",
                "catch-all pattern is unreachable",
                pattern_start
            );
        }
        if (!pattern_true && !pattern_false && !pattern_catchall) {
            return lower_error(
                "E2S24",
                "bounded Bool pattern must be `true`, `false`, or `_`",
                pattern_start
            );
        }

        int64_t after_pattern = skip_trivia(
            source,
            pattern.end
        );
        bool guarded = false;
        int64_t arrow = after_pattern;
        if (arrow < length && token_equal(source, arrow, "if")) {
            guarded = true;
            int64_t guard_start = skip_trivia(
                source,
                token_end(source, arrow)
            );
            int64_t guard_end = condition_end(source, guard_start);
            if (guard_end < 0) {
                return lower_error(
                    "E2S29",
                    "match guard must be Bool or an Int comparison",
                    guard_start
                );
            }
            arrow = skip_trivia(source, guard_end);
        }
        if (arrow >= length || !token_equal(source, arrow, "=>")) {
            return lower_error(
                "E2S24",
                "expected `=>` after Bool pattern",
                arrow
            );
        }
        int64_t arm_open = skip_trivia(
            source,
            token_end(source, arrow)
        );
        if (arm_open >= length || !token_equal(source, arm_open, "{")) {
            return lower_error(
                "E2S24",
                "bounded Bool match arm must use a block",
                arm_open
            );
        }

        int64_t arm_close = -1;
        char *arm_result = parse_value_arm(
            source,
            hir,
            arm_open,
            &arm_close
        );
        if (strncmp(arm_result, "error[", 6) == 0) return arm_result;
        free(arm_result);

        if (!guarded) {
            if (pattern_true) {
                covered_true = true;
            } else if (pattern_false) {
                covered_false = true;
            } else {
                covered_true = true;
                covered_false = true;
                seen_catchall = true;
            }
        }
        arm_cursor = skip_trivia(source, token_end(source, arm_close));
        if (
            arm_cursor < length &&
            token_equal(source, arm_cursor, ",")
        ) {
            arm_cursor = skip_trivia(
                source,
                token_end(source, arm_cursor)
            );
        } else if (
            arm_cursor >= length ||
            !token_equal(source, arm_cursor, "}")
        ) {
            return lower_error(
                "E2S24",
                "expected `,` between match arms",
                arm_cursor
            );
        }
    }

    if (arm_cursor >= length || !token_equal(source, arm_cursor, "}")) {
        return lower_error(
            "E2S24",
            "missing `}` after match arms",
            parts->arms_open
        );
    }
    if (!covered_true && !covered_false) {
        return lower_error(
            "E2S25",
            "non-exhaustive Bool match; missing patterns `true`, `false`",
            cursor
        );
    }
    if (!covered_true) {
        return lower_error(
            "E2S25",
            "non-exhaustive Bool match; missing pattern `true`",
            cursor
        );
    }
    if (!covered_false) {
        return lower_error(
            "E2S25",
            "non-exhaustive Bool match; missing pattern `false`",
            cursor
        );
    }
    parts->end = token_end(source, arm_cursor);
    stage2_semantic_observe(
        "control|match|%" PRId64 "|%" PRId64 "|Int|%" PRId64
        "|%" PRId64 "\n",
        cursor,
        parts->end,
        parts->value_start,
        parts->value_end
    );
    return owned_text("ok");
}

static bool value_control(const char *source, int64_t cursor) {
    return token_equal(source, cursor, "if") ||
           token_equal(source, cursor, "match");
}

static char *parse_value_control(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t *end
) {
    int64_t cursor = skip_trivia(source, start);
    if (token_equal(source, cursor, "if")) {
        ValueIfParts parts;
        char *result = parse_value_if(source, hir, cursor, &parts);
        if (strncmp(result, "error[", 6) == 0) return result;
        *end = parts.end;
        return result;
    }
    ValueMatchParts parts;
    char *result = parse_value_match(source, hir, cursor, &parts);
    if (strncmp(result, "error[", 6) == 0) return result;
    *end = parts.end;
    return result;
}

static char *emit_value_match_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result
);

static char *emit_value_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result
) {
    int64_t cursor = skip_trivia(source, start);
    if (token_equal(source, cursor, "match")) {
        return emit_value_match_into(
            source,
            hir,
            cursor,
            end,
            target,
            failure_result
        );
    }
    if (!token_equal(source, cursor, "if")) {
        char *value = emit_expression(source, hir, cursor, end);
        Buffer emitted;
        buffer_init(&emitted);
        buffer_format(
            &emitted,
            "    %s = %s;\n"
            "    if (kofun_failed) return %s;\n",
            target,
            value,
            failure_result
        );
        free(value);
        return emitted.data;
    }

    ValueIfParts parts;
    char *result = parse_value_if(source, hir, cursor, &parts);
    if (strncmp(result, "error[", 6) == 0) return result;
    free(result);
    char *condition = emit_condition_into(
        source,
        hir,
        parts.condition_start,
        parts.condition_end,
        "kofun_value_condition",
        failure_result,
        "        "
    );
    char *then_body = emit_value_into(
        source,
        hir,
        parts.then_start,
        parts.then_end,
        target,
        failure_result
    );
    if (strncmp(then_body, "error[", 6) == 0) {
        free(condition);
        return then_body;
    }
    char *else_body = emit_value_into(
        source,
        hir,
        parts.else_start,
        parts.else_end,
        target,
        failure_result
    );
    if (strncmp(else_body, "error[", 6) == 0) {
        free(condition);
        free(then_body);
        return else_body;
    }
    Buffer emitted;
    buffer_init(&emitted);
    buffer_format(
        &emitted,
        "    {\n"
        "%s"
        "        if (kofun_value_condition) {\n"
        "%s"
        "        } else {\n"
        "%s"
        "        }\n"
        "    }\n",
        condition,
        then_body,
        else_body
    );
    free(condition);
    free(then_body);
    free(else_body);
    return emitted.data;
}

static char *emit_value_match_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result
) {
    int64_t match_start = skip_trivia(source, start);
    char *scrutinee_enum = value_match_enum_type(source, hir, match_start);
    if (scrutinee_enum[0] != '\0') {
        char *emitted = emit_value_enum_match_into(
            source,
            hir,
            match_start,
            end,
            target,
            failure_result,
            scrutinee_enum
        );
        free(scrutinee_enum);
        return emitted;
    }
    free(scrutinee_enum);

    ValueMatchParts parts;
    char *result = parse_value_match(source, hir, start, &parts);
    if (strncmp(result, "error[", 6) == 0) return result;
    free(result);

    Buffer dispatch;
    buffer_init(&dispatch);
    int64_t arm_cursor = skip_trivia(
        source,
        token_end(source, parts.arms_open)
    );
    while (arm_cursor < end && !token_equal(source, arm_cursor, "}")) {
        PatternSummary pattern = pattern_summary(source, arm_cursor);
        bool pattern_true = pattern.kind == PATTERN_LITERAL &&
                            token_equal(source, arm_cursor, "true");
        bool pattern_false = pattern.kind == PATTERN_LITERAL &&
                             token_equal(source, arm_cursor, "false");
        int64_t arrow = skip_trivia(
            source,
            pattern.end
        );
        bool guarded = false;
        int64_t guard_start = -1;
        int64_t guard_end = -1;
        if (arrow < end && token_equal(source, arrow, "if")) {
            guarded = true;
            guard_start = skip_trivia(source, token_end(source, arrow));
            guard_end = condition_end(source, guard_start);
            arrow = skip_trivia(source, guard_end);
        }

        int64_t arm_open = skip_trivia(source, token_end(source, arrow));
        int64_t arm_start = skip_trivia(
            source,
            token_end(source, arm_open)
        );
        int64_t arm_end = -1;
        if (value_control(source, arm_start)) {
            char *arm_result = parse_value_control(
                source,
                hir,
                arm_start,
                &arm_end
            );
            if (strncmp(arm_result, "error[", 6) == 0) {
                free(dispatch.data);
                return arm_result;
            }
            free(arm_result);
        } else {
            arm_end = expression_end(source, arm_start);
        }

        char *arm_body = emit_value_into(
            source,
            hir,
            arm_start,
            arm_end,
            target,
            failure_result
        );
        if (strncmp(arm_body, "error[", 6) == 0) {
            free(dispatch.data);
            return arm_body;
        }
        const char *pattern_condition = "true";
        if (pattern_true) {
            pattern_condition = "kofun_match_value";
        } else if (pattern_false) {
            pattern_condition = "!kofun_match_value";
        }

        if (guarded) {
            char *guard = emit_condition_into(
                source,
                hir,
                guard_start,
                guard_end,
                "kofun_match_guard",
                failure_result,
                "            "
            );
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "            if (kofun_match_guard) {\n"
                "%s"
                "                kofun_match_selected = true;\n"
                "            }\n"
                "        }\n",
                pattern_condition,
                guard,
                arm_body
            );
            free(guard);
        } else {
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "            kofun_match_selected = true;\n"
                "        }\n",
                pattern_condition,
                arm_body
            );
        }
        free(arm_body);

        int64_t arm_close = skip_trivia(source, arm_end);
        arm_cursor = skip_trivia(source, token_end(source, arm_close));
        if (arm_cursor < end && token_equal(source, arm_cursor, ",")) {
            arm_cursor = skip_trivia(
                source,
                token_end(source, arm_cursor)
            );
        }
    }

    char *match_value = emit_condition_into(
        source,
        hir,
        parts.value_start,
        parts.value_end,
        "kofun_match_value",
        failure_result,
        "        "
    );
    Buffer emitted;
    buffer_init(&emitted);
    buffer_format(
        &emitted,
        "    {\n"
        "%s"
        "        (void)kofun_match_value;\n"
        "        bool kofun_match_selected = false;\n"
        "%s"
        "    }\n",
        match_value,
        dispatch.data
    );
    free(match_value);
    free(dispatch.data);
    return emitted.data;
}

static int64_t core_body_open(
    const char *source,
    const char *hir,
    int64_t function_start,
    bool is_main
) {
    int64_t length = source_length(source);
    int64_t parameters = parameter_open(source, function_start);
    if (parameters < 0) return -1;
    int64_t parameters_end = balanced_end(source, parameters, "(", ")");
    if (parameters_end < 0) return -1;
    char *parameter_text = core_parameters(source, hir, function_start);
    bool parameters_valid = strncmp(parameter_text, "error[", 6) != 0;
    free(parameter_text);
    if (!parameters_valid) return -1;
    int64_t cursor = skip_trivia(source, parameters_end);
    if (cursor < length && token_equal(source, cursor, "->")) {
        cursor = skip_trivia(source, token_end(source, cursor));
        if (cursor >= length) return -1;
        /* #924: `-> Int?` spans two tokens, so the suffix is consumed here
         * rather than left for the body scan to trip over. */
        int64_t optional_end = optional_int_type_end(source, cursor);
        if (optional_end >= 0) {
            cursor = skip_trivia(source, optional_end);
            return cursor < length && token_equal(source, cursor, "{")
                ? cursor
                : -1;
        }
        int64_t list_end = list_int_type_end(source, cursor);
        if (list_end >= 0) {
            cursor = skip_trivia(source, list_end);
            return cursor < length && token_equal(source, cursor, "{")
                ? cursor
                : -1;
        }
        char *result_type = token_copy(source, cursor);
        bool supported_result =
            strcmp(result_type, "Int") == 0 ||
            strcmp(result_type, "Text") == 0 ||
            enum_constructor_count(source, result_type) >= 0 ||
            record_declaration_start(source, result_type) >= 0;
        free(result_type);
        if (!supported_result) return -1;
        cursor = skip_trivia(source, annotation_type_end(source, cursor));
    } else if (!is_main) {
        return -1;
    }
    if (cursor >= length || !token_equal(source, cursor, "{")) return -1;
    return cursor;
}

static char *lower_error(const char *code, const char *message, int64_t cursor) {
    Buffer error;
    buffer_init(&error);
    if (cursor >= 0) {
        buffer_format(&error, "error[%s]: %s at byte %" PRId64, code, message, cursor);
    } else {
        buffer_format(&error, "error[%s]: %s", code, message);
    }
    stage2_diagnostic_set(
        code,
        cursor,
        cursor,
        cursor >= 0,
        error.data
    );
    return error.data;
}

static int64_t parent_block_open(
    const char *source,
    int64_t function_open,
    int64_t child_open
) {
    int64_t cursor = function_open;
    int64_t parent = -1;
    while (cursor < child_open) {
        if (token_equal(source, cursor, "{")) {
            int64_t candidate_end = balanced_end(source, cursor, "{", "}");
            if (candidate_end > child_open) parent = cursor;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return parent;
}

/*
 * A match arm's guard is written outside the arm body braces but belongs to the
 * arm: `Ready(value) if value == 3` must read the binding the body reads.  This
 * maps a token inside a guard to that arm's body `{`, so a guard use resolves
 * in the scope the payload binding was declared in.  The emitted C agrees: the
 * payload local is declared before the guard, inside the arm's `if`.  Returns
 * -1 for every token that is not inside a guard.
 */
static int64_t match_guard_scope_open(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor <= target) {
        if (token_equal(source, cursor, "match")) {
            int64_t open = pattern_match_open(source, cursor);
            int64_t match_end = open < 0 ?
                -1 :
                balanced_end(source, open, "{", "}");
            if (open >= 0 && match_end >= 0) {
                int64_t close = match_end - 1;
                int64_t arm = skip_trivia(source, token_end(source, open));
                while (arm < close && !token_equal(source, arm, "}")) {
                    PatternSummary summary = pattern_summary(source, arm);
                    int64_t arrow = pattern_arm_arrow(
                        source,
                        summary.end,
                        close
                    );
                    if (arrow < 0) break;
                    int64_t body = skip_trivia(
                        source,
                        token_end(source, arrow)
                    );
                    if (body >= close || !token_equal(source, body, "{")) {
                        break;
                    }
                    int64_t body_end = balanced_end(source, body, "{", "}");
                    if (body_end < 0) break;
                    if (target >= summary.end && target < arrow) {
                        /*
                         * Only the payload name is redirected.  Every other
                         * guard use keeps the scope it already reported, so
                         * this widening cannot move a use that resolves
                         * without it.
                         */
                        int64_t open = skip_trivia(
                            source,
                            token_end(source, arm)
                        );
                        int64_t field = skip_trivia(
                            source,
                            token_end(source, open)
                        );
                        if (
                            summary.kind == PATTERN_CONSTRUCTOR &&
                            field < close &&
                            strcmp(
                                token_kind(source, field),
                                "identifier"
                            ) == 0 &&
                            !token_equal(source, field, "_")
                        ) {
                            char *payload_name = token_copy(source, field);
                            bool same = token_equal(
                                source,
                                target,
                                payload_name
                            );
                            free(payload_name);
                            if (same) return body;
                        }
                        return -1;
                    }
                    arm = skip_trivia(source, body_end);
                    if (arm < close && token_equal(source, arm, ",")) {
                        arm = skip_trivia(source, token_end(source, arm));
                    }
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return -1;
}

/*
 * Brace depth at `target`. `scope_depth_for_open` reports the depth of a `{`
 * token; a lambda scope opens on `(`, so it needs the running depth instead.
 */
static int64_t block_depth_at(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = function_open;
    int64_t depth = 0;
    while (cursor < target) {
        if (token_equal(source, cursor, "{")) {
            ++depth;
        } else if (token_equal(source, cursor, "}")) {
            --depth;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return depth;
}

/*
 * The byte after an arrow lambda's body, or -1 when `open` is not its parameter
 * list. A lambda is keyed by the `(`, not by `fn`, which makes `fn(x) => e` and
 * the parenthesised forms decided in #547 — `(x, y) => e` and `(x: Int) => e` —
 * one code path.
 *
 * Two conditions identify the parameter list, and both are needed:
 *
 *   1. its `)` is immediately followed by `=>`, and
 *   2. its `(` is NOT immediately preceded by an identifier.
 *
 * Condition 2 is not decoration. A constructor pattern ends in `)` and is
 * followed by `=>` — `Ok(value) => value` and `Err(error) => Err(error)` are
 * all over the shipped stdlib — so condition 1 alone matches every one of them.
 * What separates them is what comes before the `(`: a constructor pattern is
 * preceded by its variant name, a lambda's parameter list by `fn`, `=`, `,` or
 * `(`.
 *
 * The bare `x => e` form is deliberately absent. `IDENT => expr` is already
 * enum match-arm syntax — 176 arms in the shipped stdlib, e.g. `Trace => 0` —
 * so one token of lookahead cannot separate the two. See #547.
 *
 * The body is delimited by the same expression grammar the Core lowers, so a
 * body this Core cannot parse yields -1 and the lambda contributes no scope —
 * the identifiers inside it are then reported by whichever pass would have
 * reported them before.
 */
/*
 * Whether `target` begins a match arm's pattern.
 *
 * `IDENT => expr` is both an arm and a bare lambda, and arms are
 * comma-separated, so the token before it cannot separate them: `,` precedes
 * both `Debug => 1,` and the lambda in `map(xs, x => x * 2)`. Neither can one
 * token of lookahead, which is what #547 assumed. What separates them is
 * position — an arm pattern begins directly inside a `match` block's braces at
 * an arm boundary, and everything else is expression position.
 *
 * Walking arms is what makes this exact rather than approximate. A lambda may
 * appear inside an arm body (`Some(v) => map(xs, y => y + v)`), so "inside a
 * match block" would be wrong; only the arm's own first token is a pattern.
 *
 * The walk restarts at every `match` token, so a nested match is reached by its
 * own iteration rather than by recursion here.
 */
static bool match_arm_pattern_start(const char *source, int64_t target) {
    /*
     * The answer depends only on the source, and every identifier resolution
     * asks it, so the arm starts are collected once per source and then looked
     * up. Re-walking the arms per candidate is what makes the compiler
     * quadratic on a real file: `lambda_scope_open` already consults
     * `lambda_parameters_end` for every token of every function.
     */
    static const char *cached_source = NULL;
    static int64_t cached_length = -1;
    static int64_t *starts = NULL;
    static int64_t start_count = 0;
    int64_t length = source_length(source);
    if (source != cached_source || length != cached_length) {
        free(starts);
        starts = NULL;
        start_count = 0;
        int64_t capacity = 0;
        int64_t cursor = 0;
        while (cursor < length) {
            if (token_equal(source, cursor, "match")) {
                int64_t open = pattern_match_open(source, cursor);
                int64_t match_end =
                    open < 0 ? -1 : balanced_end(source, open, "{", "}");
                if (open >= 0 && match_end >= 0) {
                    int64_t close = match_end - 1;
                    int64_t arm = skip_trivia(source, token_end(source, open));
                    while (arm < close && !token_equal(source, arm, "}")) {
                        if (start_count == capacity) {
                            int64_t grown_capacity =
                                capacity == 0 ? 64 : capacity * 2;
                            int64_t *grown = realloc(
                                starts,
                                (size_t)grown_capacity * sizeof(*starts)
                            );
                            if (grown == NULL) break;
                            starts = grown;
                            capacity = grown_capacity;
                        }
                        starts[start_count++] = arm;
                        int64_t arrow = pattern_arm_arrow(source, arm, close);
                        if (arrow < 0) break;
                        int64_t body =
                            skip_trivia(source, token_end(source, arrow));
                        int64_t body_end = expression_end(source, body);
                        if (body_end < 0) break;
                        int64_t next = skip_trivia(source, body_end);
                        if (next < close && token_equal(source, next, ",")) {
                            next = skip_trivia(source, token_end(source, next));
                        }
                        if (next <= arm) break;
                        arm = next;
                    }
                }
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        cached_source = source;
        cached_length = length;
    }
    for (int64_t index = 0; index < start_count; ++index) {
        if (starts[index] == target) return true;
    }
    return false;
}

static int64_t lambda_parameters_end(
    const char *source,
    int64_t previous,
    int64_t open
) {
    int64_t length = source_length(source);
    if (!token_equal(source, open, "(")) {
        /* The bare single-parameter form `x => e` decided in #547. It is a
         * lambda everywhere an arm pattern is not, which is why the arm check
         * carries the whole decision. */
        if (strcmp(token_kind(source, open), "identifier") != 0) return -1;
        if (keyword_token(source, open)) return -1;
        int64_t bare_arrow = skip_trivia(source, token_end(source, open));
        if (bare_arrow >= length ||
            !token_equal(source, bare_arrow, "=>")) {
            return -1;
        }
        if (match_arm_pattern_start(source, open)) return -1;
        return expression_end(
            source,
            skip_trivia(source, token_end(source, bare_arrow))
        );
    }
    if (
        previous >= 0 &&
        strcmp(token_kind(source, previous), "identifier") == 0
    ) {
        return -1;
    }
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return -1;
    int64_t arrow = skip_trivia(source, close);
    if (arrow >= length || !token_equal(source, arrow, "=>")) return -1;
    return expression_end(
        source,
        skip_trivia(source, token_end(source, arrow))
    );
}

/*
 * The innermost arrow lambda whose parameters are in scope at `target`, keyed
 * by its `(` so `hir_scope_id_for_open` finds the scope record. -1 when
 * `target` is not inside one.
 */
static int64_t lambda_scope_open(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = function_open;
    int64_t previous = -1;
    int64_t found = -1;
    while (cursor < target) {
        if (lambda_parameters_end(source, previous, cursor) > target) {
            found = cursor;
        }
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return found;
}

static bool lambda_declaration_syntax_token(
    const char *source,
    int64_t function_open,
    int64_t target
);

/* Lifted lambdas still use the scalar capture ABI. Refuse every List[Int]
 * binding read in a lambda before C publication, including len and indexing. */
static char *validate_list_int_lambda_uses(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    int64_t previous = -1;
    while (cursor < length) {
        int64_t function_open = enclosing_function_open(source, cursor);
        bool inside_lambda = function_open >= 0 &&
            lambda_scope_open(source, function_open, cursor) >= 0;
        bool follows_primary = false;
        if (previous >= 0) {
            const char *previous_kind = token_kind(source, previous);
            follows_primary =
                strcmp(previous_kind, "identifier") == 0 ||
                strcmp(previous_kind, "integer") == 0 ||
                strcmp(previous_kind, "float") == 0 ||
                strcmp(previous_kind, "decimal") == 0 ||
                strcmp(previous_kind, "string") == 0 ||
                token_equal(source, previous, ")") ||
                token_equal(source, previous, "]");
        }
        if (
            inside_lambda && token_equal(source, cursor, "[") &&
            !follows_primary
        ) {
            return lower_error(
                "E2S157",
                "List[Int] literals inside lambdas are outside this lowering "
                "slice",
                cursor
            );
        }
        if (strcmp(token_kind(source, cursor), "identifier") == 0) {
            char *binding_id = hir_use_binding_id(hir, cursor);
            if (
                inside_lambda && token_equal(source, cursor, "List") &&
                previous >= 0 && token_equal(source, previous, ":") &&
                lambda_declaration_syntax_token(
                    source,
                    function_open,
                    cursor
                )
            ) {
                free(binding_id);
                return lower_error(
                    "E2S157",
                    "List annotations inside lambdas are outside this "
                    "lowering slice",
                    cursor
                );
            }
            if (binding_id[0] != '\0') {
                char *binding_type = hir_binding_field(hir, binding_id, 5);
                if (
                    inside_lambda && strcmp(binding_type, "List[Int]") == 0
                ) {
                    free(binding_type);
                    free(binding_id);
                    return lower_error(
                        "E2S157",
                        "List[Int] binding uses inside lambdas are outside "
                        "this lowering slice",
                        cursor
                    );
                }
                free(binding_type);
            }
            int64_t open = skip_trivia(source, token_end(source, cursor));
            if (
                inside_lambda && binding_id[0] == '\0' && open < length &&
                token_equal(source, open, "(")
            ) {
                char *name = token_copy(source, cursor);
                char *result_type = function_return_type(source, name);
                bool list_result = strcmp(result_type, "List[Int]") == 0;
                free(result_type);
                free(name);
                if (list_result) {
                    free(binding_id);
                    return lower_error(
                        "E2S157",
                        "List[Int] direct results inside lambdas are outside "
                        "this lowering slice",
                        cursor
                    );
                }
            }
            free(binding_id);
        }
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

/*
 * `target` is a parameter name or a parameter type inside an arrow lambda's
 * parameter list. The identifier pass must resolve neither: the name is a
 * declaration, and the type names no binding.
 */
static bool lambda_declaration_syntax_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = function_open;
    int64_t previous = -1;
    while (cursor <= target) {
        if (lambda_parameters_end(source, previous, cursor) >= 0) {
            if (!token_equal(source, cursor, "(")) {
                /* The bare form has no parameter list: the keying token is
                 * itself the parameter, so it is the only declaration. */
                if (target == cursor) return true;
            } else if (
                target > cursor &&
                target < balanced_end(source, cursor, "(", ")")
            ) {
                return true;
            }
        }
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

/*
 * `x: Int => e` annotates a lambda parameter without parentheses. #547 rejects
 * it: `:` is the type-annotation position everywhere else, so the bare form
 * reads as a binding whose type is `Int => e`, and accepting it would foreclose
 * writing function types with an arrow before #552 has decided whether to.
 * Detected forward as IDENT `:` TYPE `=>`; every other annotation position is
 * followed by `=`, `)` or `{`, never by `=>`.
 */
static bool lambda_unparenthesised_annotation(
    const char *source,
    int64_t start
) {
    int64_t length = source_length(source);
    if (strcmp(token_kind(source, start), "identifier") != 0) return false;
    int64_t colon = skip_trivia(source, token_end(source, start));
    if (colon >= length || !token_equal(source, colon, ":")) return false;
    int64_t annotation = skip_trivia(source, token_end(source, colon));
    if (annotation >= length) return false;
    int64_t arrow = skip_trivia(source, token_end(source, annotation));
    return arrow < length && token_equal(source, arrow, "=>");
}

static const char *scope_kind_for_open(
    const char *source,
    int64_t function_open,
    int64_t wanted_open
) {
    int64_t cursor = function_open;
    const char *previous = "";
    while (cursor < wanted_open) {
        if (token_equal(source, cursor, "if")) {
            int64_t condition_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t condition_close = condition_end(
                source,
                condition_start
            );
            if (
                condition_close >= 0 &&
                skip_trivia(source, condition_close) == wanted_open
            ) {
                return "if-then";
            }
        }
        if (token_equal(source, cursor, "else")) {
            previous = "else";
        } else if (token_equal(source, cursor, "=>")) {
            previous = "=>";
        } else {
            previous = "";
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (strcmp(previous, "else") == 0) return "if-else";
    if (strcmp(previous, "=>") == 0) return "match-arm";
    return "block";
}

static bool enum_declaration_syntax_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor <= target) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            if (name == target) return true;
            int64_t colon = skip_trivia(source, token_end(source, name));
            if (token_equal(source, colon, ":")) {
                int64_t type_cursor = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                if (type_cursor == target) return true;
                int64_t equals = skip_trivia(
                    source,
                    token_end(source, type_cursor)
                );
                int64_t initializer = skip_trivia(
                    source,
                    token_end(source, equals)
                );
                if (
                    initializer == target &&
                    token_equal(source, equals, "=")
                ) {
                    char *enum_type = token_copy(source, type_cursor);
                    bool valid = enum_constructor_count(source, enum_type) >= 0;
                    free(enum_type);
                    if (valid) return true;
                }
            }
        }
        if (token_equal(source, cursor, "for")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (name == target) return true;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static bool record_syntax_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    int64_t previous = function_open;
    while (cursor <= target) {
        if (cursor == target) {
            if (token_equal(source, previous, ".")) return true;
            int64_t after = skip_trivia(
                source,
                token_end(source, cursor)
            );
            if (token_equal(source, after, ":")) return true;
            if (token_equal(source, after, "(")) {
                char *name = token_copy(source, cursor);
                bool constructor =
                    record_declaration_start(source, name) >= 0;
                free(name);
                if (constructor) return true;
            }
            return false;
        }
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static bool record_initializer_constructor_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor <= target) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            int64_t colon = skip_trivia(source, token_end(source, name));
            if (token_equal(source, colon, ":")) {
                int64_t type_cursor = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                int64_t equals = skip_trivia(
                    source,
                    token_end(source, type_cursor)
                );
                int64_t initializer = skip_trivia(
                    source,
                    token_end(source, equals)
                );
                if (
                    initializer == target &&
                    token_equal(source, equals, "=")
                ) {
                    char *record_type = token_copy(source, type_cursor);
                    char *constructor = token_copy(source, initializer);
                    bool valid =
                        strcmp(record_type, constructor) == 0 &&
                        record_declaration_start(
                            source,
                            record_type
                        ) >= 0;
                    free(record_type);
                    free(constructor);
                    return valid;
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static bool enum_initializer_constructor_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor <= target) {
        if (token_equal(source, cursor, "let")) {
            int64_t name = skip_trivia(source, token_end(source, cursor));
            if (token_equal(source, name, "mut")) {
                name = skip_trivia(source, token_end(source, name));
            }
            int64_t colon = skip_trivia(source, token_end(source, name));
            if (token_equal(source, colon, ":")) {
                int64_t type_cursor = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                int64_t equals = skip_trivia(
                    source,
                    token_end(source, type_cursor)
                );
                int64_t initializer = skip_trivia(
                    source,
                    token_end(source, equals)
                );
                if (
                    initializer == target &&
                    token_equal(source, equals, "=")
                ) {
                    char *enum_type = token_copy(source, type_cursor);
                    char *constructor = token_copy(source, initializer);
                    char *owner = enum_constructor_owner(source, constructor);
                    bool valid =
                        enum_constructor_count(source, enum_type) >= 0 &&
                        owner[0] != '\0';
                    free(enum_type);
                    free(constructor);
                    free(owner);
                    return valid;
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static bool enum_match_pattern_token(
    const char *source,
    int64_t function_open,
    int64_t target
) {
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor < target) {
        if (token_equal(source, cursor, "match")) {
            int64_t arms_open = pattern_match_open(source, cursor);
            if (
                arms_open >= 0 && arms_open < target &&
                token_equal(source, arms_open, "{")
            ) {
                int64_t match_end = balanced_end(
                    source,
                    arms_open,
                    "{",
                    "}"
                );
                int64_t match_close = match_end < 0 ? -1 : match_end - 1;
                int64_t arm_cursor = skip_trivia(
                    source,
                    token_end(source, arms_open)
                );
                while (
                    match_close >= 0 && arm_cursor <= target &&
                    arm_cursor < match_close &&
                    !token_equal(source, arm_cursor, "}")
                ) {
                    PatternSummary pattern = pattern_summary(
                        source,
                        arm_cursor
                    );
                    if (target >= arm_cursor && target < pattern.end) {
                        return true;
                    }
                    int64_t arrow = pattern_arm_arrow(
                        source,
                        pattern.end,
                        match_close
                    );
                    if (
                        arm_cursor <= target &&
                        arrow >= 0 &&
                        token_equal(source, arrow, "=>")
                    ) {
                        int64_t arm_open = skip_trivia(
                            source,
                            token_end(source, arrow)
                        );
                        int64_t arm_end = balanced_end(
                            source,
                            arm_open,
                            "{",
                            "}"
                        );
                        if (arm_end < 0) {
                            arm_cursor = target + 1;
                        } else if (arm_end <= target) {
                            arm_cursor = skip_trivia(source, arm_end);
                            if (token_equal(source, arm_cursor, ",")) {
                                arm_cursor = skip_trivia(
                                    source,
                                    token_end(source, arm_cursor)
                                );
                            }
                        } else {
                            arm_cursor = target + 1;
                        }
                    } else {
                        arm_cursor = target + 1;
                    }
                }
            }
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static int64_t text_find_from(
    const char *value,
    const char *wanted,
    int64_t start
) {
    /* The scope-HIR walker searches the document it is still building, once
     * per record, so this is the pass's inner loop. strstr answers the same
     * question as the per-position strncmp scan it replaces: the first offset
     * at or after `start` where `wanted` occurs, or -1. */
    if (start < 0) return -1;
    if (wanted[0] == '\0') return start;
    const char *hit = strstr(value + start, wanted);
    return hit == NULL ? -1 : (int64_t)(hit - value);
}

static int64_t decimal_value(const char *value) {
    int64_t cursor = 0;
    int64_t sign = 1;
    int64_t length = (int64_t)strlen(value);
    if (length > 0 && value[0] == '-') {
        sign = -1;
        cursor = 1;
    }
    int64_t result = 0;
    while (cursor < length) {
        if (value[cursor] < '0' || value[cursor] > '9') return -1;
        result = result * 10 + (value[cursor] - '0');
        ++cursor;
    }
    return result * sign;
}

static int64_t hir_record_start(
    const char *hir,
    const char *kind,
    int64_t start
) {
    Buffer needle;
    buffer_init(&needle);
    buffer_format(&needle, "\n%s|", kind);
    int64_t found = text_find_from(hir, needle.data, start);
    free(needle.data);
    return found < 0 ? -1 : found + 1;
}

static char *hir_field(
    const char *hir,
    int64_t line_start,
    int wanted
) {
    if (line_start < 0) return owned_text("");
    int64_t cursor = line_start;
    int field = 0;
    int64_t field_start = line_start;
    while (hir[cursor] != '\0') {
        if (hir[cursor] == '|' || hir[cursor] == '\n') {
            if (field == wanted) {
                size_t field_length = (size_t)(cursor - field_start);
                char *result = allocate(field_length + 1);
                memcpy(result, hir + field_start, field_length);
                result[field_length] = '\0';
                return result;
            }
            if (hir[cursor] == '\n') return owned_text("");
            ++field;
            field_start = cursor + 1;
        }
        ++cursor;
    }
    if (field == wanted) {
        size_t field_length = (size_t)(cursor - field_start);
        char *result = allocate(field_length + 1);
        memcpy(result, hir + field_start, field_length);
        result[field_length] = '\0';
        return result;
    }
    return owned_text("");
}


/*
 * Lazy incremental index over scope-HIR "scope", "binding" and "use"
 * records. The builder appends records and immediately consults the
 * document, once per record, so answering each consultation with a whole-
 * document scan made the build quadratic in record count. This index parses
 * each complete record line exactly once and answers by key instead.
 *
 * One slot, keyed on the document pointer. The builder invalidates the slot
 * when it starts a new document; a pointer change (a moved reallocation or a
 * different document) rebuilds from the current bytes, and a grown document
 * re-parses only the lines appended since the previous consultation. Both
 * fall back to a full re-parse, so the index can be dropped without changing
 * a single output byte.
 *
 * Key layout: one tag byte, then unit-separated parts. Values are line
 * offsets in document order, so first-match and last-match callers keep
 * their original selection order.
 */
enum { HIR_INDEX_PARTS = 11 };

typedef struct HirIndexEntry {
    char *key;
    int64_t *lines;
    int64_t count;
    int64_t capacity;
} HirIndexEntry;

static const char *hir_index_doc;
static int64_t hir_index_upto;
static HirIndexEntry *hir_index_entries;
static int64_t hir_index_count;
static int64_t hir_index_capacity;
static Buffer hir_index_key_buffer;

static void hir_index_invalidate(void) {
    for (int64_t at = 0; at < hir_index_capacity; at += 1) {
        free(hir_index_entries[at].key);
        free(hir_index_entries[at].lines);
    }
    free(hir_index_entries);
    hir_index_entries = NULL;
    hir_index_count = 0;
    hir_index_capacity = 0;
    hir_index_doc = NULL;
    hir_index_upto = 0;
    free(hir_index_key_buffer.data);
    hir_index_key_buffer.data = NULL;
    hir_index_key_buffer.length = 0;
    hir_index_key_buffer.capacity = 0;
}

static uint64_t hir_index_hash(const char *key) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const char *at = key; *at != '\0'; at += 1) {
        hash ^= (uint64_t)(unsigned char)*at;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static HirIndexEntry *hir_index_slot(const char *key) {
    uint64_t probe = hir_index_hash(key) & (uint64_t)(hir_index_capacity - 1);
    for (;;) {
        HirIndexEntry *entry = &hir_index_entries[probe];
        if (entry->key == NULL || strcmp(entry->key, key) == 0) return entry;
        probe = (probe + 1) & (uint64_t)(hir_index_capacity - 1);
    }
}

static void hir_index_grow(void) {
    int64_t old_capacity = hir_index_capacity;
    HirIndexEntry *old_entries = hir_index_entries;
    hir_index_capacity = old_capacity == 0 ? 1024 : old_capacity * 2;
    hir_index_entries = calloc(
        (size_t)hir_index_capacity,
        sizeof(HirIndexEntry)
    );
    if (hir_index_entries == NULL) fail("stage2 seed: out of memory");
    for (int64_t at = 0; at < old_capacity; at += 1) {
        if (old_entries[at].key == NULL) continue;
        *hir_index_slot(old_entries[at].key) = old_entries[at];
    }
    free(old_entries);
}

static void hir_index_add(const char *key, int64_t line, bool first_only) {
    if (hir_index_count * 10 >= hir_index_capacity * 7) hir_index_grow();
    HirIndexEntry *entry = hir_index_slot(key);
    if (entry->key == NULL) {
        entry->key = owned_text(key);
        hir_index_count += 1;
    } else if (first_only) {
        return;
    }
    if (entry->count == entry->capacity) {
        entry->capacity = entry->capacity == 0 ? 2 : entry->capacity * 2;
        int64_t *lines = realloc(
            entry->lines,
            (size_t)entry->capacity * sizeof(int64_t)
        );
        if (lines == NULL) fail("stage2 seed: out of memory");
        entry->lines = lines;
    }
    entry->lines[entry->count] = line;
    entry->count += 1;
}

/* The fields of one record line, as offsets of each '|'-separated part.
 * Returns the number of parts found, up to HIR_INDEX_PARTS. */
static int hir_index_split(
    const char *doc,
    int64_t line,
    int64_t newline,
    int64_t *starts,
    int64_t *ends
) {
    int parts = 0;
    int64_t start = line;
    for (int64_t at = line; at <= newline && parts < HIR_INDEX_PARTS; at += 1) {
        if (at == newline || doc[at] == '|') {
            starts[parts] = start;
            ends[parts] = at;
            parts += 1;
            start = at + 1;
        }
    }
    return parts;
}

/* "tag \x1f first [\x1f second]" in the reused key buffer. Both the refresh
 * loop and every lookup build their keys here, so the wire format has one
 * writer; the buffer is grown in place and freed by hir_index_invalidate. */
static const char *hir_index_key(
    char tag,
    const char *first,
    size_t first_length,
    const char *second,
    size_t second_length
) {
    Buffer *key = &hir_index_key_buffer;
    if (key->data == NULL) buffer_init(key);
    key->length = 0;
    buffer_reserve(key, first_length + second_length + 4);
    key->data[key->length] = tag;
    key->length += 1;
    key->data[key->length] = '\x1f';
    key->length += 1;
    memcpy(key->data + key->length, first, first_length);
    key->length += first_length;
    if (second != NULL) {
        key->data[key->length] = '\x1f';
        key->length += 1;
        memcpy(key->data + key->length, second, second_length);
        key->length += second_length;
    }
    key->data[key->length] = '\0';
    return key->data;
}

static void hir_index_refresh(const char *doc) {
    if (doc != hir_index_doc) {
        hir_index_invalidate();
        hir_index_doc = doc;
    }
    if (hir_index_capacity == 0) hir_index_grow();
    int64_t cursor = hir_index_upto;
    for (;;) {
        int64_t newline = cursor;
        while (doc[newline] != '\0' && doc[newline] != '\n') newline += 1;
        if (doc[newline] == '\0') break;
        int64_t starts[HIR_INDEX_PARTS];
        int64_t ends[HIR_INDEX_PARTS];
        int parts = hir_index_split(doc, cursor, newline, starts, ends);
        int64_t width = ends[0] - starts[0];
        if (width == 5 && strncmp(doc + starts[0], "scope", 5) == 0) {
            if (parts > 1) {
                hir_index_add(
                    hir_index_key(
                        'c', doc + starts[1],
                        (size_t)(ends[1] - starts[1]), NULL, 0
                    ),
                    cursor, true
                );
            }
            if (parts > 4) {
                hir_index_add(
                    hir_index_key(
                        'o', doc + starts[4],
                        (size_t)(ends[4] - starts[4]), NULL, 0
                    ),
                    cursor, true
                );
            }
        } else if (
            width == 7 && strncmp(doc + starts[0], "binding", 7) == 0
        ) {
            if (parts > 1) {
                hir_index_add(
                    hir_index_key(
                        'b', doc + starts[1],
                        (size_t)(ends[1] - starts[1]), NULL, 0
                    ),
                    cursor, true
                );
            }
            if (parts > 3) {
                hir_index_add(
                    hir_index_key(
                        'n', doc + starts[2], (size_t)(ends[2] - starts[2]),
                        doc + starts[3], (size_t)(ends[3] - starts[3])
                    ),
                    cursor, false
                );
            }
            if (parts > 8) {
                hir_index_add(
                    hir_index_key(
                        'd', doc + starts[8],
                        (size_t)(ends[8] - starts[8]), NULL, 0
                    ),
                    cursor, true
                );
            }
        } else if (width == 3 && strncmp(doc + starts[0], "use", 3) == 0) {
            if (parts > 1) {
                hir_index_add(
                    hir_index_key(
                        'u', doc + starts[1],
                        (size_t)(ends[1] - starts[1]), NULL, 0
                    ),
                    cursor, true
                );
            }
        }
        cursor = newline + 1;
    }
    hir_index_upto = cursor;
}

/* The record lines a key names, in document order; NULL when none do. The
 * returned entry borrows the index's table and is valid only until the next
 * index call, which may grow the table; consumers must not hold it across
 * another lookup or refresh. */
static const HirIndexEntry *hir_index_list(
    const char *doc,
    char tag,
    const char *first,
    const char *second
) {
    hir_index_refresh(doc);
    const char *key = hir_index_key(
        tag,
        first, strlen(first),
        second, second == NULL ? 0 : strlen(second)
    );
    HirIndexEntry *entry = hir_index_slot(key);
    return entry->key == NULL ? NULL : entry;
}

/* The first record line a key names, or -1. */
static int64_t hir_index_first(
    const char *doc,
    char tag,
    const char *first,
    const char *second
) {
    const HirIndexEntry *entry = hir_index_list(doc, tag, first, second);
    return entry == NULL ? -1 : entry->lines[0];
}

/* One field of the first record a key names, or "" when no record does. */
static char *hir_index_field(
    const char *doc,
    char tag,
    const char *first,
    const char *second,
    int field
) {
    int64_t line = hir_index_first(doc, tag, first, second);
    if (line < 0) return owned_text("");
    return hir_field(doc, line, field);
}

/* hir_index_field for the integer-valued keys. */
static char *hir_index_field_number(
    const char *doc,
    char tag,
    int64_t number,
    int field
) {
    char text[24];
    snprintf(text, sizeof text, "%" PRId64, number);
    return hir_index_field(doc, tag, text, NULL, field);
}

static char *hir_same_scope_declaration(
    const char *hir,
    const char *scope_id,
    const char *name
) {
    return hir_index_field(hir, 'n', scope_id, name, 8);
}

static char *hir_scope_id_for_open(const char *hir, int64_t open) {
    return hir_index_field_number(hir, 'o', open, 1);
}

/* The byte the binding's declaration starts at, or -1 for an unknown id. */
static int64_t hir_binding_declaration_start(
    const char *hir,
    const char *binding_id
) {
    char *start_text = hir_binding_field(hir, binding_id, 8);
    int64_t start = start_text[0] == '\0' ? -1 : decimal_value(start_text);
    free(start_text);
    return start;
}

/*
 * The `(` of the arrow lambda a `let` initializer is, or -1 when the
 * initializer is something else. `value_start` is the first byte after `=`,
 * so what precedes the parameter list is `=` or `fn` — never an identifier,
 * which is why -1 is the right `previous` for `lambda_parameters_end`: the
 * constructor-pattern ambiguity that argument guards against cannot arise
 * here.
 */
static int64_t lambda_initializer_open(
    const char *source,
    int64_t value_start
) {
    int64_t cursor = skip_trivia(source, value_start);
    if (token_equal(source, cursor, "fn")) {
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (lambda_parameters_end(source, -1, cursor) < 0) return -1;
    return cursor;
}

/*
 * The `(` of the lambda a binding holds, or -1 when that binding is not a
 * lambda. This is how a call site reaches the lifted function: the scope HIR
 * has already resolved the callee name to a binding, shadowing included, so
 * the lowering never repeats that resolution by name.
 */
static int64_t lambda_binding_open(
    const char *source,
    const char *hir,
    const char *binding_id
) {
    int64_t declaration_start = hir_binding_declaration_start(hir, binding_id);
    if (declaration_start < 0) return -1;
    int64_t equals = skip_trivia(
        source,
        token_end(source, declaration_start)
    );
    if (!token_equal(source, equals, "=")) return -1;
    return lambda_initializer_open(
        source,
        skip_trivia(source, token_end(source, equals))
    );
}

/*
 * The callable type of the parameter a call site's callee binding declares, as
 * the byte offset of its type, or -1 when the callee is not a callable-typed
 * parameter. This is how an indirect call reaches its arity and its C
 * declarator without repeating name resolution: the scope HIR has already
 * resolved the callee to a binding, shadowing included.
 */
static int64_t callable_parameter_type_start(
    const char *source,
    const char *hir,
    const char *binding_id
) {
    int64_t length = source_length(source);
    int64_t declaration_start = hir_binding_declaration_start(hir, binding_id);
    if (declaration_start < 0) return -1;
    int64_t colon = skip_trivia(source, token_end(source, declaration_start));
    if (colon >= length || !token_equal(source, colon, ":")) return -1;
    int64_t type_cursor = skip_trivia(source, token_end(source, colon));
    if (callable_type_end(source, type_cursor) < 0) return -1;
    return type_cursor;
}

/*
 * The declared arity of the callable-typed parameter a call site resolves to,
 * or -1 when the callee is not one.
 */
static int64_t callable_call_arity(
    const char *source,
    const char *hir,
    int64_t use_start
) {
    char *callee_binding = hir_use_binding_id(hir, use_start);
    if (callee_binding[0] == '\0') {
        free(callee_binding);
        return -1;
    }
    int64_t type_start = callable_parameter_type_start(
        source,
        hir,
        callee_binding
    );
    free(callee_binding);
    if (type_start < 0) return -1;
    return callable_type_arity(source, type_start);
}

/*
 * The binding ids a lambda body reads from outside its own parameter list, in
 * HIR order, separated by `|`, or "" when the lambda captures nothing.
 *
 * A capture is exactly a use inside the lambda whose binding lives in another
 * scope. Lifting passes each one as a trailing parameter, so a lifted lambda
 * stays a plain `int64_t` function and the frozen profile gains no function
 * type. The call site appends the same ids in the same order, and a captured
 * binding is a C local of the enclosing function, so it is in scope wherever
 * the lambda binding itself is.
 */
static char *lambda_captures(
    const char *source,
    const char *hir,
    int64_t lambda_open
) {
    int64_t body_end = lambda_parameters_end(source, -1, lambda_open);
    char *scope_id = hir_scope_id_for_open(hir, lambda_open);
    Buffer captured;
    buffer_init(&captured);
    int64_t line = hir_record_start(hir, "use", 0);
    while (line >= 0) {
        char *start_text = hir_field(hir, line, 1);
        int64_t use_start = decimal_value(start_text);
        free(start_text);
        if (use_start > lambda_open && use_start < body_end) {
            char *binding_id = hir_field(hir, line, 4);
            char *binding_scope = hir_binding_field(hir, binding_id, 2);
            /* A lambda binding in an enclosing scope is not a capture: it has
             * no `int64_t` to pass, and the call reaches its lifted function
             * by name. Counting it would emit a parameter for a C variable
             * that a lambda binding never declares. */
            if (strcmp(binding_scope, scope_id) != 0 &&
                lambda_binding_open(source, hir, binding_id) < 0) {
                /* A body may read the same capture more than once; the
                 * parameter list must name it once. */
                Buffer seen;
                buffer_init(&seen);
                buffer_format(&seen, "|%s|", captured.data);
                Buffer wanted;
                buffer_init(&wanted);
                buffer_format(&wanted, "|%s|", binding_id);
                if (strstr(seen.data, wanted.data) == NULL) {
                    if (captured.length > 0) buffer_append(&captured, "|");
                    buffer_append(&captured, binding_id);
                }
                free(seen.data);
                free(wanted.data);
            }
            free(binding_scope);
            free(binding_id);
        }
        line = hir_record_start(hir, "use", line + 1);
    }
    free(scope_id);
    return captured.data;
}

/* The declared parameter count of the lambda whose parameter list opens at
 * `open`. Captures are invisible to a caller, so they are not counted. */
static int64_t lambda_parameter_count(const char *source, int64_t open) {
    /* The bare form `x => e` is keyed by its single parameter, so it has no
     * list to count and its arity is always one. */
    if (!token_equal(source, open, "(")) return 1;
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) return -1;
    int64_t count = 0;
    int64_t parameter = skip_trivia(source, token_end(source, open));
    while (parameter < close) {
        if (strcmp(token_kind(source, parameter), "identifier") != 0) break;
        ++count;
        int64_t after = skip_trivia(source, token_end(source, parameter));
        if (after < close && token_equal(source, after, ":")) {
            int64_t annotation = skip_trivia(source, token_end(source, after));
            after = skip_trivia(source, token_end(source, annotation));
        }
        if (after < close && token_equal(source, after, ",")) {
            after = skip_trivia(source, token_end(source, after));
        }
        parameter = after;
    }
    return count;
}

/*
 * The declared arity of the lambda a call site resolves to, or -1 when the
 * callee is not a lambda binding.
 */
static int64_t lambda_call_arity(
    const char *source,
    const char *hir,
    int64_t use_start
) {
    char *callee_binding = hir_use_binding_id(hir, use_start);
    if (callee_binding[0] == '\0') {
        free(callee_binding);
        return -1;
    }
    int64_t open = lambda_binding_open(source, hir, callee_binding);
    free(callee_binding);
    if (open < 0) return -1;
    return lambda_parameter_count(source, open);
}

/*
 * Writes one `k_b<id>` per capture into `output`, prefixed by `declaration`
 * for a parameter list and by nothing for an argument list, separating with
 * `, ` when `written` items already precede them. The lifted signature and
 * every call to it go through this one function so their orders cannot drift.
 */
static void append_captures(
    Buffer *output,
    const char *captures,
    int64_t written,
    const char *declaration
) {
    int64_t count = 0;
    size_t cursor = 0;
    while (captures[cursor] != '\0') {
        size_t stop = cursor;
        while (captures[stop] != '\0' && captures[stop] != '|') ++stop;
        if (written > 0 || count > 0) buffer_append(output, ", ");
        buffer_append(output, declaration);
        buffer_append(output, "k_b");
        for (size_t index = cursor; index < stop; ++index) {
            char symbol[2] = {captures[index], '\0'};
            buffer_append(output, symbol);
        }
        ++count;
        cursor = captures[stop] == '\0' ? stop : stop + 1;
    }
}

static char *hir_scope_field(
    const char *hir,
    const char *scope_id,
    int field
) {
    return hir_index_field(hir, 'c', scope_id, NULL, field);
}

static char *hir_binding_field(
    const char *hir,
    const char *binding_id,
    int field
) {
    return hir_index_field(hir, 'b', binding_id, NULL, field);
}

static char *hir_definition_id_at(
    const char *hir,
    int64_t declaration_start
) {
    return hir_index_field_number(hir, 'd', declaration_start, 1);
}

static char *hir_use_binding_id(const char *hir, int64_t use_start) {
    return hir_index_field_number(hir, 'u', use_start, 4);
}

static char *hir_resolve_binding(
    const char *hir,
    const char *current_scope,
    int64_t use_start,
    const char *name
) {
    char *scope_id = owned_text(current_scope);
    while (scope_id[0] != '\0' && strcmp(scope_id, "-1") != 0) {
        const HirIndexEntry *list =
            hir_index_list(hir, 'n', scope_id, name);
        int64_t entries = list == NULL ? 0 : list->count;
        for (int64_t at = entries - 1; at >= 0; at -= 1) {
            int64_t line = list->lines[at];
            char *visible_text = hir_field(hir, line, 10);
            bool visible = decimal_value(visible_text) <= use_start;
            free(visible_text);
            if (visible) {
                free(scope_id);
                return hir_field(hir, line, 1);
            }
        }
        char *parent = hir_scope_field(hir, scope_id, 2);
        free(scope_id);
        scope_id = parent;
    }
    free(scope_id);
    return owned_text("");
}

static char *hir_pending_declaration(
    const char *hir,
    const char *current_scope,
    int64_t use_start,
    const char *name
) {
    char *scope_id = owned_text(current_scope);
    while (scope_id[0] != '\0' && strcmp(scope_id, "-1") != 0) {
        const HirIndexEntry *list =
            hir_index_list(hir, 'n', scope_id, name);
        int64_t entries = list == NULL ? 0 : list->count;
        for (int64_t at = 0; at < entries; at += 1) {
            int64_t line = list->lines[at];
            char *declaration_text = hir_field(hir, line, 8);
            char *visible_text = hir_field(hir, line, 10);
            int64_t declaration = decimal_value(declaration_text);
            int64_t visible = decimal_value(visible_text);
            free(visible_text);
            if (declaration < use_start && use_start < visible) {
                free(scope_id);
                return declaration_text;
            }
            free(declaration_text);
        }
        char *parent = hir_scope_field(hir, scope_id, 2);
        free(scope_id);
        scope_id = parent;
    }
    free(scope_id);
    return owned_text("");
}

static char *hir_scope_root(const char *hir, const char *start_scope) {
    char *scope_id = owned_text(start_scope);
    char *parent = hir_scope_field(hir, scope_id, 2);
    while (parent[0] != '\0' && strcmp(parent, "-1") != 0) {
        free(scope_id);
        scope_id = parent;
        parent = hir_scope_field(hir, scope_id, 2);
    }
    free(parent);
    return scope_id;
}

static char *hir_any_declaration(
    const char *hir,
    const char *current_scope,
    int64_t use_start,
    const char *name
) {
    char *current_root = hir_scope_root(hir, current_scope);
    int64_t line = hir_record_start(hir, "binding", 0);
    while (line >= 0) {
        char *binding_name = hir_field(hir, line, 3);
        char *binding_scope = hir_field(hir, line, 2);
        char *declaration_text = hir_field(hir, line, 8);
        char *binding_root = hir_scope_root(hir, binding_scope);
        bool found =
            strcmp(binding_name, name) == 0 &&
            decimal_value(declaration_text) < use_start &&
            strcmp(binding_root, current_root) == 0;
        free(binding_name);
        free(binding_scope);
        free(binding_root);
        if (found) {
            free(current_root);
            return declaration_text;
        }
        free(declaration_text);
        line = hir_record_start(hir, "binding", line + 1);
    }
    free(current_root);
    return owned_text("");
}

static int64_t scope_depth_for_open(
    const char *source,
    int64_t function_open,
    int64_t wanted_open
) {
    int64_t cursor = function_open;
    int64_t depth = 0;
    while (cursor <= wanted_open) {
        if (token_equal(source, cursor, "{")) {
            ++depth;
            if (cursor == wanted_open) return depth;
        } else if (token_equal(source, cursor, "}")) {
            --depth;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return -1;
}

/*
 * Result types of the 17 profile builtins for `let` initializer typing.
 * The scope-HIR type vocabulary stays the existing single tokens
 * (Int/Bool/Text/List/Void); List[Text] element typing belongs to the
 * selfhost-HIR emitter. Returns NULL for a non-builtin name.
 */
static const char *builtin_return_type(const char *name) {
    static const struct {
        const char *name;
        const char *result;
    } builtins[] = {
        {"args", "List"},
        {"chars", "List"},
        {"contains", "Bool"},
        {"fail", "Void"},
        {"find", "Int"},
        {"is_digit", "Bool"},
        {"is_space", "Bool"},
        {"is_xid_continue", "Bool"},
        {"len", "Int"},
        {"read_text", "Text"},
        {"replace", "Text"},
        {"starts_with", "Bool"},
        {"text_slice", "Text"},
        {"to_text", "Text"},
        {"trim", "Text"},
        {"validate_unicode_source", "Text"},
        {"write_text", "Void"},
    };
    size_t count = sizeof(builtins) / sizeof(builtins[0]);
    for (size_t index = 0; index < count; ++index) {
        if (strcmp(name, builtins[index].name) == 0) {
            return builtins[index].result;
        }
    }
    return NULL;
}

static char *function_return_type_at(
    const char *source,
    int64_t function_start
) {
    int64_t length = source_length(source);
    int64_t parameters = parameter_open(source, function_start);
    int64_t parameters_end;
    int64_t after;
    if (parameters < 0) return owned_text("");
    parameters_end = balanced_end(source, parameters, "(", ")");
    if (parameters_end < 0) return owned_text("");
    after = skip_trivia(source, parameters_end);
    if (after < length && token_equal(source, after, "->")) {
        int64_t type_cursor = skip_trivia(
            source,
            token_end(source, after)
        );
        if (type_cursor < length) {
            if (list_int_type_end(source, type_cursor) >= 0) {
                return owned_text("List[Int]");
            }
            return annotation_type_text(source, type_cursor);
        }
        return owned_text("");
    }
    return owned_text("Void");
}

/* Declared result type of a user function: the token after `->`, `Void`
 * when there is no arrow, empty when the function is not declared. */
static char *function_return_type(const char *source, const char *wanted) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        char *name = function_name(source, cursor);
        bool match = strcmp(name, wanted) == 0;
        free(name);
        if (match) {
            return function_return_type_at(source, cursor);
        }
        cursor = next_function_start(source, function_end(source, cursor));
    }
    return owned_text("");
}

/*
 * Declared type of one named function parameter.  The bounded enum C11 slice
 * needs this at call lowering time because an enum value is a two-word
 * aggregate rather than an Int expression. Full annotation spans are skipped
 * while walking, including callable, optional, and bracketed types.
 */
static char *function_parameter_type_at(
    const char *source,
    int64_t function_start,
    int64_t wanted_index
) {
    int64_t parameters = parameter_open(source, function_start);
    if (parameters < 0) return owned_text("");
    int64_t parameters_end = balanced_end(source, parameters, "(", ")");
    if (parameters_end < 0) return owned_text("");
    int64_t cursor = skip_trivia(source, token_end(source, parameters));
    int64_t index = 0;
    while (
        cursor < parameters_end &&
        !token_equal(source, cursor, ")")
    ) {
        int64_t type_start = parameter_type_start(
            source,
            cursor,
            parameters_end
        );
        if (type_start < 0 || type_start >= parameters_end) {
            return owned_text("");
        }
        int64_t optional_end = optional_int_type_end(source, type_start);
        int64_t list_end = parameter_list_type_end(
            source,
            type_start,
            parameters_end
        );
        if (index == wanted_index) return optional_end >= 0
            ? owned_text("Int?")
            : (list_end >= 0
                ? parameter_list_type_text(
                    source,
                    type_start,
                    parameters_end
                )
                : annotation_type_text(source, type_start));

        int64_t type_end = callable_type_end(source, type_start);
        if (type_end < 0) type_end = optional_end >= 0
            ? optional_end : (list_end >= 0
                ? list_end : annotation_type_end(source, type_start));
        int64_t separator = skip_trivia(source, type_end);
        if (
            separator < parameters_end &&
            token_equal(source, separator, ",")
        ) {
            cursor = skip_trivia(source, token_end(source, separator));
        } else {
            cursor = separator;
        }
        ++index;
    }
    return owned_text("");
}

static char *function_parameter_type(
    const char *source,
    const char *wanted,
    int64_t index
) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        char *name = function_name(source, cursor);
        bool match = strcmp(name, wanted) == 0;
        free(name);
        if (match) {
            return function_parameter_type_at(source, cursor, index);
        }
        cursor = next_function_start(source, function_end(source, cursor));
    }
    return owned_text("");
}

/* Result type of the function whose body contains `position`. */
static char *function_return_type_containing(
    const char *source,
    int64_t position
) {
    int64_t length = source_length(source);
    int64_t cursor = next_function_start(source, 0);
    while (cursor < length) {
        int64_t end = function_end(source, cursor);
        if (position >= cursor && position < end) {
            return function_return_type_at(source, cursor);
        }
        cursor = next_function_start(source, end);
    }
    return owned_text("");
}

static bool function_result_is_enum(
    const char *source,
    const char *name
) {
    char *type = function_return_type(source, name);
    bool result = enum_constructor_count(source, type) >= 0;
    free(type);
    return result;
}

static bool function_result_is_record(
    const char *source,
    const char *name
) {
    char *type = function_return_type(source, name);
    bool result = record_declaration_start(source, type) >= 0;
    free(type);
    return result;
}

/* A declared `-> Text` result.  Text values are borrowed `const char *` in the
 * bounded profile, so this is what selects the C result type and the `return`
 * lowering rather than the Int path. */
static bool function_result_is_text(const char *source, const char *name) {
    char *type = function_return_type(source, name);
    bool result = strcmp(type, "Text") == 0;
    free(type);
    return result;
}

static bool function_result_is_list_int(
    const char *source,
    const char *name
) {
    char *type = function_return_type(source, name);
    bool result = strcmp(type, "List[Int]") == 0;
    free(type);
    return result;
}

/*
 * Bounded initializer typing for unannotated `let` bindings. Top-level
 * comparison and boolean operators make the value Bool; otherwise the
 * profile's operands are homogeneous, so the first primary decides:
 * literals by token kind, calls by declared or builtin result type, names
 * by their resolved binding, bare enum constructors by their owner. The
 * conservative fallback is the historical Int default, never an error.
 */
static char *initializer_type_bounded(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t initializer,
    int64_t bounded_end
);

static char *initializer_type(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t initializer
) {
    return initializer_type_bounded(
        source,
        hir,
        function_open,
        initializer,
        -1
    );
}

/* Bounded classification keeps operators after one subexpression from
 * changing that subexpression's type. */
static char *initializer_type_bounded(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t initializer,
    int64_t bounded_end
) {
    int64_t length = source_length(source);
    int64_t end = expression_end(source, initializer);
    if (bounded_end >= 0) {
        end = bounded_end;
    } else if (end < 0) {
        end = token_end(source, initializer);
    }
    bool optional_coalescing =
        optional_int_coalescing_operator(source, initializer, end) >= 0;
    bool exact_decimal_division = false;
    /* The operator scan covers the whole initializer line: it ends at the
     * first newline outside parentheses, not at the bounded arithmetic
     * expression end, so `1 < 2` and multi-line parenthesized calls are
     * both seen completely. */
    int64_t depth = 0;
    int64_t walk = initializer;
    int64_t previous_end = initializer;
    while (walk < length && (bounded_end < 0 || walk < bounded_end)) {
        bool newline = false;
        for (int64_t at = previous_end; at < walk; ++at) {
            if (source[at] == '\n') {
                newline = true;
                break;
            }
        }
        if (depth == 0 && newline) break;
        if (token_equal(source, walk, "{")) break;
        if (token_equal(source, walk, "(")) {
            ++depth;
        } else if (token_equal(source, walk, ")")) {
            --depth;
        } else if (
            depth == 0 &&
            (token_equal(source, walk, "==") ||
             token_equal(source, walk, "!=") ||
             token_equal(source, walk, "<") ||
             token_equal(source, walk, "<=") ||
             token_equal(source, walk, ">") ||
             token_equal(source, walk, ">=") ||
             token_equal(source, walk, "&&") ||
             token_equal(source, walk, "||") ||
             token_equal(source, walk, "!"))
        ) {
            return owned_text("Bool");
        } else if (depth == 0 && token_equal(source, walk, "/")) {
            exact_decimal_division = true;
        }
        previous_end = token_end(source, walk);
        walk = skip_trivia(source, previous_end);
    }
    if (optional_coalescing) return owned_text("Int");
    int64_t cursor = skip_trivia(source, initializer);
    while (
        cursor < end &&
        (token_equal(source, cursor, "(") ||
         token_equal(source, cursor, "-") ||
         token_equal(source, cursor, "+"))
    ) {
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (cursor >= end) return owned_text("Int");
    if (token_equal(source, cursor, "[")) {
        return owned_text("List[Int]");
    }
    {
        char *conversion = numeric_conversion_at(source, cursor);
        const char *result = numeric_conversion_result(conversion);
        if (result[0] != '\0') {
            char *type = owned_text(
                exact_decimal_division && strcmp(result, "Decimal") == 0
                    ? "DecimalResult"
                    : result
            );
            free(conversion);
            return type;
        }
        free(conversion);
    }
    const char *kind = token_kind(source, cursor);
    if (strcmp(kind, "integer") == 0) return owned_text("Int");
    /* #710 frozen decision 2: an unsuffixed fractional or scientific literal
     * denotes Decimal, and the `f64` suffix selects binary64 Float. Recording
     * them here is what puts the type in the scope HIR, so an unannotated
     * `let x = 1.5` is a Decimal binding rather than the historical Int
     * default. */
    if (strcmp(kind, "decimal") == 0) {
        return owned_text(
            exact_decimal_division ? "DecimalResult" : "Decimal"
        );
    }
    if (strcmp(kind, "float") == 0) return owned_text("Float");
    if (strcmp(kind, "string") == 0) return owned_text("Text");
    if (
        token_equal(source, cursor, "true") ||
        token_equal(source, cursor, "false")
    ) {
        return owned_text("Bool");
    }
    if (strcmp(kind, "identifier") == 0) {
        char *name = token_copy(source, cursor);
        /* Call and index detection must not stop at the bounded
         * expression end: profile initializers may continue across
         * lines, and `[` follows the resolved primary directly. */
        int64_t open = skip_trivia(source, token_end(source, cursor));
        if (open < length && token_equal(source, open, "(")) {
            char *declared = function_return_type(source, name);
            if (declared[0] != '\0') {
                free(name);
                return declared;
            }
            free(declared);
            if (record_declaration_start(source, name) >= 0) {
                return name;
            }
            char *constructor_type = enum_constructor_owner(source, name);
            if (constructor_type[0] != '\0') {
                free(name);
                return constructor_type;
            }
            free(constructor_type);
            const char *builtin = builtin_return_type(name);
            free(name);
            if (builtin != NULL) return owned_text(builtin);
            return owned_text("Int");
        }
        int64_t scope_open = parent_block_open(
            source,
            function_open,
            cursor
        );
        char *scope_id = hir_scope_id_for_open(hir, scope_open);
        char *binding_id = hir_resolve_binding(hir, scope_id, cursor, name);
        free(scope_id);
        if (binding_id[0] != '\0') {
            char *type = hir_binding_field(hir, binding_id, 5);
            free(binding_id);
            free(name);
            if (type[0] != '\0') {
                if (open < length && token_equal(source, open, ".")) {
                    int64_t field_cursor = skip_trivia(
                        source,
                        token_end(source, open)
                    );
                    char *field = token_copy(source, field_cursor);
                    char *field_type = record_field_type_named(
                        source,
                        type,
                        field
                    );
                    free(field);
                    if (field_type[0] != '\0') {
                        free(type);
                        return field_type;
                    }
                    free(field_type);
                }
                bool indexed =
                    open < length && token_equal(source, open, "[");
                if (indexed && strcmp(type, "List[Int]") == 0) {
                    free(type);
                    return owned_text("Int");
                }
                /* Indexing the profile's List[Text] yields its Text
                 * element. */
                if (indexed && strcmp(type, "List") == 0) {
                    free(type);
                    return owned_text("Text");
                }
                if (
                    exact_decimal_division &&
                    strcmp(type, "Decimal") == 0
                ) {
                    free(type);
                    return owned_text("DecimalResult");
                }
                return type;
            }
            free(type);
            return owned_text("Int");
        }
        free(binding_id);
        char *owner = enum_constructor_owner(source, name);
        free(name);
        if (owner[0] != '\0') return owner;
        free(owner);
    }
    return owned_text("Int");
}

/*
 * #924: the C text of an `Int?` value, in every position that constructs or
 * carries one. Four forms and no others: `null` is the absent value; a bare
 * `Int?` binding and a call declared `Int?` carry an existing value whole; and
 * anything typed `Int` becomes `Some`, which is #70's injection rule reaching
 * the backend. Nothing here reads a payload, so no path through this function
 * can turn an absent value into an `Int`.
 */
static char *optional_int_value(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end
) {
    int64_t cursor = optional_int_coalescing_transparent_bound(
        source,
        start,
        end,
        true
    );
    int64_t value_end = optional_int_coalescing_transparent_bound(
        source,
        start,
        end,
        false
    );
    bool single =
        skip_trivia(source, token_end(source, cursor)) >= value_end;
    if (single && token_equal(source, cursor, "null")) {
        return owned_text("KOFUN_OPTIONAL_INT_NONE");
    }
    if (strcmp(token_kind(source, cursor), "identifier") == 0) {
        char *name = token_copy(source, cursor);
        if (single && optional_int_binding(source, cursor, name)) {
            char *binding_id = hir_use_binding_id(hir, cursor);
            Buffer output;
            buffer_init(&output);
            buffer_format(&output, "k_b%s", binding_id);
            free(binding_id);
            free(name);
            return output.data;
        }
        int64_t open = skip_trivia(source, token_end(source, cursor));
        bool optional_call = open < value_end &&
                             token_equal(source, open, "(") &&
                             optional_int_result(source, name);
        free(name);
        if (optional_call) {
            int64_t close = balanced_end(source, open, "(", ")");
            if (close < 0 || skip_trivia(source, close) < value_end) {
                return lower_error(
                    "E2S147",
                    "an `Int?` call result is used whole; it takes part in no "
                    "arithmetic in this lowering slice",
                    cursor
                );
            }
            return emit_expression(source, hir, cursor, value_end);
        }
    }
    int64_t function_open = enclosing_function_open(source, cursor);
    char *value_type = initializer_type(source, hir, function_open, cursor);
    /* A compound expression is `Int` by construction: every `Int?` operand in
     * it has already been proved narrowed, so its recorded declared type says
     * nothing about the value the arithmetic produces. */
    bool present = strcmp(value_type, "Int") == 0 ||
                   (!single && strcmp(value_type, "Int?") == 0);
    free(value_type);
    if (!present) {
        return lower_error(
            "E2S147",
            "an `Int?` value is `null`, an `Int`, another `Int?` binding, or "
            "a call returning `Int?`",
            cursor
        );
    }
    char *inner = emit_expression(source, hir, cursor, value_end);
    if (strncmp(inner, "error[", 6) == 0) return inner;
    Buffer output;
    buffer_init(&output);
    buffer_format(&output, "KOFUN_OPTIONAL_INT_SOME(%s)", inner);
    free(inner);
    return output.data;
}

static bool optional_int_coalescing_left(
    const char *source,
    int64_t start,
    int64_t end
) {
    int64_t cursor = optional_int_coalescing_transparent_bound(
        source,
        start,
        end,
        true
    );
    int64_t value_end = optional_int_coalescing_transparent_bound(
        source,
        start,
        end,
        false
    );
    bool single =
        skip_trivia(source, token_end(source, cursor)) >= value_end;
    if (single && token_equal(source, cursor, "null")) return true;
    if (strcmp(token_kind(source, cursor), "identifier") != 0) return false;
    char *name = token_copy(source, cursor);
    if (single && optional_int_binding(source, cursor, name)) {
        free(name);
        return true;
    }
    int64_t open = skip_trivia(source, token_end(source, cursor));
    bool optional_call = open < value_end &&
                         token_equal(source, open, "(") &&
                         optional_int_result(source, name);
    free(name);
    if (!optional_call) return false;
    int64_t close = balanced_end(source, open, "(", ")");
    return close >= 0 && skip_trivia(source, close) >= value_end;
}

static char *validate_optional_int_coalescing(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t last_operator = -1;
    int64_t cursor = skip_trivia(source, 0);
    int64_t previous = -1;
    while (cursor < length) {
        int64_t left_end = arithmetic_expression_end(source, cursor);
        int64_t operator_start =
            left_end < 0 ? -1 : skip_trivia(source, left_end);
        bool type_position = previous >= 0 &&
            (token_equal(source, previous, ":") ||
             token_equal(source, previous, "->"));
        if (
            !type_position &&
            operator_start >= 0 &&
            operator_start < length &&
            operator_start != last_operator &&
            token_equal(source, operator_start, "??")
        ) {
            last_operator = operator_start;
            if (!optional_int_coalescing_left(source, cursor, left_end)) {
                return lower_error(
                    "E2S147",
                    "left operand of `??` must be `Int?`; this slice accepts "
                    "`null`, a direct `Int?` binding, or a call returning "
                    "`Int?`",
                    cursor
                );
            }
            int64_t right_start = skip_trivia(
                source,
                token_end(source, operator_start)
            );
            int64_t right_end = arithmetic_expression_end(
                source,
                right_start
            );
            if (right_end < 0) {
                return lower_error(
                    "E2S147",
                    "`??` requires one `Int` fallback expression",
                    operator_start
                );
            }
            int64_t after = skip_trivia(source, right_end);
            if (after < length && token_equal(source, after, "??")) {
                return lower_error(
                    "E2S147",
                    "chained `??` is outside the Optional(Int) coalescing "
                    "slice; bind the first result before coalescing again",
                    after
                );
            }
            char *right_type = initializer_type_bounded(
                source,
                hir,
                enclosing_function_open(source, right_start),
                right_start,
                right_end
            );
            if (strcmp(right_type, "Int") != 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "right operand of `??` must be `Int`, got `%s`",
                    right_type
                );
                free(right_type);
                char *error = lower_error(
                    "E2S147",
                    message.data,
                    right_start
                );
                free(message.data);
                return error;
            }
            free(right_type);
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        previous = cursor;
        cursor = skip_trivia(source, next);
    }
    return owned_text("ok");
}

static char *emit_optional_int_coalescing_temporaries(
    const char *source,
    int64_t function_open
) {
    int64_t close = balanced_end(source, function_open, "{", "}");
    Buffer output;
    buffer_init(&output);
    if (close < 0) return output.data;
    int64_t cursor = skip_trivia(
        source,
        token_end(source, function_open)
    );
    while (cursor < close) {
        if (token_equal(source, cursor, "??")) {
            buffer_format(
                &output,
                "    KofunOptionalInt kofun_optional_int_coalesce_%" PRId64 " = KOFUN_OPTIONAL_INT_NONE;\n",
                cursor
            );
        }
        int64_t next = token_end(source, cursor);
        if (next <= cursor) break;
        cursor = skip_trivia(source, next);
    }
    return output.data;
}

static char *scope_hir_error(
    Buffer *hir,
    const char *message,
    int64_t cursor
) {
    free(hir->data);
    return lower_error("E2S35", message, cursor);
}

static char *build_scope_hir_mode(
    const char *source,
    bool preserve_pattern_candidates
) {
    hir_index_invalidate();
    int64_t length = source_length(source);
    /* The removed callable notation is rejected before any binding is
     * collected, so a source written in it gets the migration diagnostic
     * rather than whatever its multi-token type happens to desynchronise. */
    char *notation_check = validate_removed_callable_notation(source);
    if (strncmp(notation_check, "error[", 6) == 0) return notation_check;
    free(notation_check);
    Buffer hir;
    buffer_init(&hir);
    buffer_append(&hir, "kofun-scope-hir/v1\n");
    stage2_scope_prefix_observe(&hir);
    int64_t next_scope_id = 0;
    int64_t next_binding_id = 0;
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = balanced_end(
            source,
            parameters,
            "(",
            ")"
        );
        int64_t function_open = skip_trivia(source, parameters_close);
        while (
            function_open < function_close &&
            !token_equal(source, function_open, "{")
        ) {
            function_open = skip_trivia(
                source,
                token_end(source, function_open)
            );
        }
        int64_t parameter_scope = next_scope_id++;
        int64_t body_scope = next_scope_id++;
        int64_t scope_count = 2;
        buffer_format(
            &hir,
            "hir-function|%" PRId64 "|%" PRId64 "|%" PRId64 "\n"
            "scope|%" PRId64 "|-1|parameters|%" PRId64 "|%" PRId64
            "|0\n"
            "scope|%" PRId64 "|%" PRId64 "|function-body|%" PRId64
            "|%" PRId64 "|1\n",
            function_start,
            parameter_scope,
            body_scope,
            parameter_scope,
            parameters,
            parameters_close,
            body_scope,
            parameter_scope,
            function_open,
            function_close
        );
        stage2_scope_prefix_observe(&hir);

        int64_t cursor = skip_trivia(
            source,
            token_end(source, function_open)
        );
        int64_t previous = -1;
        while (cursor < function_close) {
            if (token_equal(source, cursor, "{")) {
                int64_t depth = scope_depth_for_open(
                    source,
                    function_open,
                    cursor
                );
                if (depth > 32) {
                    return scope_hir_error(
                        &hir,
                        "lexical scope depth limit is 32",
                        cursor
                    );
                }
                ++scope_count;
                if (scope_count > 256) {
                    return scope_hir_error(
                        &hir,
                        "lexical scope limit is 256 per function",
                        cursor
                    );
                }
                int64_t parent_open = parent_block_open(
                    source,
                    function_open,
                    cursor
                );
                char *parent_scope = hir_scope_id_for_open(
                    hir.data,
                    parent_open
                );
                int64_t close = balanced_end(source, cursor, "{", "}");
                const char *scope_kind = scope_kind_for_open(
                    source,
                    function_open,
                    cursor
                );
                buffer_format(
                    &hir,
                    "scope|%" PRId64 "|%s|%s|%" PRId64 "|%" PRId64
                    "|%" PRId64 "\n",
                    next_scope_id++,
                    parent_scope,
                    scope_kind,
                    cursor,
                    close,
                    depth
                );
                stage2_scope_prefix_observe(&hir);
                free(parent_scope);
            } else if (lambda_unparenthesised_annotation(source, cursor)) {
                int64_t colon = skip_trivia(source, token_end(source, cursor));
                int64_t annotation = skip_trivia(
                    source,
                    token_end(source, colon)
                );
                char *parameter_name = token_copy(source, cursor);
                char *annotation_text = token_copy(source, annotation);
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S95]: annotated lambda parameter `%s` needs "
                    "parentheses at byte %" PRId64 "; write `(%s: %s) =>`",
                    parameter_name,
                    cursor,
                    parameter_name,
                    annotation_text
                );
                stage2_diagnostic_set(
                    "E2S95",
                    cursor,
                    token_end(source, cursor),
                    true,
                    error.data
                );
                stage2_diagnostic_affected(
                    STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                    cursor,
                    token_end(source, cursor)
                );
                free(parameter_name);
                free(annotation_text);
                free(hir.data);
                return error.data;
            } else {
                int64_t lambda_close = lambda_parameters_end(
                    source,
                    previous,
                    cursor
                );
                if (lambda_close >= 0) {
                    int64_t lambda_open = cursor;
                    int64_t lambda_depth = block_depth_at(
                        source,
                        function_open,
                        cursor
                    ) + 1;
                    if (lambda_depth > 32) {
                        return scope_hir_error(
                            &hir,
                            "lexical scope depth limit is 32",
                            cursor
                        );
                    }
                    ++scope_count;
                    if (scope_count > 256) {
                        return scope_hir_error(
                            &hir,
                            "lexical scope limit is 256 per function",
                            cursor
                        );
                    }
                    char *lambda_parent = hir_scope_id_for_open(
                        hir.data,
                        parent_block_open(source, function_open, lambda_open)
                    );
                    buffer_format(
                        &hir,
                        "scope|%" PRId64 "|%s|lambda-parameters|%" PRId64
                        "|%" PRId64 "|%" PRId64 "\n",
                        next_scope_id++,
                        lambda_parent,
                        lambda_open,
                        lambda_close,
                        lambda_depth
                    );
                    stage2_scope_prefix_observe(&hir);
                    free(lambda_parent);
                }
            }
            previous = cursor;
            cursor = skip_trivia(source, token_end(source, cursor));
        }

        int64_t binding_count = 0;
        int64_t parameter_cursor = skip_trivia(
            source,
            token_end(source, parameters)
        );
        while (
            parameter_cursor < parameters_close &&
            !token_equal(source, parameter_cursor, ")")
        ) {
            int64_t name = parameter_internal_start(
                source,
                parameter_cursor,
                parameters_close
            );
            int64_t type_cursor = parameter_type_start(
                source,
                parameter_cursor,
                parameters_close
            );
            if (name < 0 || type_cursor < 0) {
                return scope_hir_error(
                    &hir,
                    "malformed parameter head",
                    parameter_cursor
                );
            }
            char *name_text = token_copy(source, name);
            char parameter_scope_text[32];
            snprintf(
                parameter_scope_text,
                sizeof(parameter_scope_text),
                "%" PRId64,
                parameter_scope
            );
            char *first_declaration = hir_same_scope_declaration(
                hir.data,
                parameter_scope_text,
                name_text
            );
            if (first_declaration[0] != '\0') {
                Buffer error;
                buffer_init(&error);
                buffer_format(
                    &error,
                    "error[E2S47]: duplicate binding `%s` in lexical "
                    "scope at byte %" PRId64
                    "; first declaration at byte %s",
                    name_text,
                    name,
                    first_declaration
                );
                stage2_diagnostic_set(
                    "E2S47",
                    name,
                    token_end(source, name),
                    true,
                    error.data
                );
                stage2_diagnostic_affected(
                    STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                    name,
                    token_end(source, name)
                );
                {
                    int64_t first = decimal_value(first_declaration);
                    stage2_diagnostic_related(
                        first,
                        token_end(source, first),
                        "first declaration"
                    );
                }
                stage2_diagnostic_remedy(2u);
                free(name_text);
                free(first_declaration);
                free(hir.data);
                return error.data;
            }
            free(first_declaration);
            ++binding_count;
            if (binding_count > 256) {
                free(name_text);
                return scope_hir_error(
                    &hir,
                    "lexical binding limit is 256 per function",
                    name
                );
            }
            /* A callable type spans several tokens. Stepping over only the
             * first would leave this walk inside the type, so the parameters
             * after it would never be bound and their uses would be reported
             * as unknown lexical bindings. */
            int64_t callable_end = callable_type_end(source, type_cursor);
            /* #924: `Int?` is two tokens and one type. Recording it as `Int?`
             * keeps the declared type optional in the typed IR, so nothing
             * downstream mistakes the parameter for an `Int`. */
            int64_t optional_end = optional_int_type_end(source, type_cursor);
            int64_t list_end = parameter_list_type_end(
                source,
                type_cursor,
                parameters_close
            );
            /* Unsupported nested/general List annotations still need one
             * balanced span so partial scope HIR retains the parameter fact
             * before lowering reports the exact E2S157 boundary. */
            int64_t list_shape_end = -1;
            if (list_end < 0) {
                list_shape_end = constructed_list_type_end(
                    source,
                    type_cursor,
                    parameters_close
                );
            }
            /* #916: a parameter binding records the annotation's full
             * identity, so a const argument reaches the scope HIR instead of
             * being flattened to its head. Recording `Fixed` here would make
             * every scale one binding type and silently accept a scale
             * mismatch. */
            int64_t type_end = callable_end >= 0
                ? callable_end
                : (optional_end >= 0
                       ? optional_end
                       : (list_end >= 0
                            ? list_end
                            : (list_shape_end >= 0
                                ? list_shape_end
                                : annotation_type_end(source, type_cursor))));
            char *type_text = callable_end >= 0
                ? owned_text("Fn")
                : (optional_end >= 0
                       ? owned_text("Int?")
                       : (list_end >= 0
                            ? parameter_list_type_text(
                                source,
                                type_cursor,
                                parameters_close
                            )
                            : (list_shape_end >= 0
                                ? constructed_list_type_text(
                                    source,
                                    type_cursor,
                                    parameters_close
                                )
                                : annotation_type_text(
                                    source,
                                    type_cursor
                                ))));
            char *ownership = ownership_mode_token(source, parameter_cursor)
                ? token_copy(source, parameter_cursor)
                : owned_text("copy");
            buffer_format(
                &hir,
                "binding|%" PRId64 "|%" PRId64 "|%s|immutable|%s|%s|"
                "initialized|%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
                next_binding_id++,
                parameter_scope,
                name_text,
                type_text,
                ownership,
                name,
                token_end(source, name),
                token_end(source, name)
            );
            stage2_scope_prefix_observe(&hir);
            free(ownership);
            free(name_text);
            free(type_text);
            int64_t separator = skip_trivia(source, type_end);
            if (
                separator < parameters_close &&
                token_equal(source, separator, ",")
            ) {
                parameter_cursor = skip_trivia(
                    source,
                    token_end(source, separator)
                );
            } else {
                parameter_cursor = separator;
            }
        }

        cursor = skip_trivia(source, token_end(source, function_open));
        previous = -1;
        while (cursor < function_close) {
            if (lambda_parameters_end(source, previous, cursor) >= 0) {
                int64_t lambda_open = cursor;
                /* The bare form has no parameter list to walk: the parameter
                 * is the keying token itself, so the walk below covers exactly
                 * that one identifier and then stops at the `=>`. */
                bool bare_lambda = !token_equal(source, lambda_open, "(");
                int64_t lambda_close = bare_lambda
                    ? token_end(source, lambda_open)
                    : balanced_end(source, lambda_open, "(", ")");
                char *lambda_scope = hir_scope_id_for_open(
                    hir.data,
                    lambda_open
                );
                int64_t lambda_cursor = bare_lambda
                    ? lambda_open
                    : skip_trivia(source, token_end(source, lambda_open));
                while (
                    lambda_cursor < lambda_close &&
                    !token_equal(source, lambda_cursor, ")")
                ) {
                    int64_t parameter = lambda_cursor;
                    int64_t after = skip_trivia(
                        source,
                        token_end(source, parameter)
                    );
                    char *parameter_type = NULL;
                    if (token_equal(source, after, ":")) {
                        int64_t annotation = skip_trivia(
                            source,
                            token_end(source, after)
                        );
                        int64_t list_finish = constructed_list_type_end(
                            source,
                            annotation,
                            lambda_close
                        );
                        if (list_finish >= 0) {
                            parameter_type = constructed_list_type_text(
                                source,
                                annotation,
                                lambda_close
                            );
                            after = skip_trivia(source, list_finish);
                        } else {
                            parameter_type = annotation_type_text(
                                source,
                                annotation
                            );
                            after = skip_trivia(
                                source,
                                annotation_type_end(source, annotation)
                            );
                        }
                    }
                    char *parameter_name = token_copy(source, parameter);
                    char *first = hir_same_scope_declaration(
                        hir.data,
                        lambda_scope,
                        parameter_name
                    );
                    if (first[0] != '\0') {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S47]: duplicate binding `%s` in lexical "
                            "scope at byte %" PRId64
                            "; first declaration at byte %s",
                            parameter_name,
                            parameter,
                            first
                        );
                        stage2_diagnostic_set(
                            "E2S47",
                            parameter,
                            token_end(source, parameter),
                            true,
                            error.data
                        );
                        stage2_diagnostic_affected(
                            STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                            parameter,
                            token_end(source, parameter)
                        );
                        {
                            int64_t at = decimal_value(first);
                            stage2_diagnostic_related(
                                at,
                                token_end(source, at),
                                "first declaration"
                            );
                        }
                        stage2_diagnostic_remedy(2u);
                        free(parameter_name);
                        free(parameter_type);
                        free(first);
                        free(lambda_scope);
                        free(hir.data);
                        return error.data;
                    }
                    free(first);
                    ++binding_count;
                    if (binding_count > 256) {
                        free(parameter_name);
                        free(parameter_type);
                        free(lambda_scope);
                        return scope_hir_error(
                            &hir,
                            "lexical binding limit is 256 per function",
                            parameter
                        );
                    }
                    buffer_format(
                        &hir,
                        "binding|%" PRId64 "|%s|%s|immutable|%s|copy|"
                        "initialized|%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
                        next_binding_id++,
                        lambda_scope,
                        parameter_name,
                        parameter_type == NULL ? "Int" : parameter_type,
                        parameter,
                        token_end(source, parameter),
                        token_end(source, parameter)
                    );
                    stage2_scope_prefix_observe(&hir);
                    free(parameter_name);
                    free(parameter_type);
                    if (
                        after < lambda_close &&
                        token_equal(source, after, ",")
                    ) {
                        lambda_cursor = skip_trivia(
                            source,
                            token_end(source, after)
                        );
                    } else {
                        lambda_cursor = after;
                    }
                }
                free(lambda_scope);
            }
            previous = cursor;
            cursor = skip_trivia(source, token_end(source, cursor));
        }

        cursor = skip_trivia(source, token_end(source, function_open));
        while (cursor < function_close) {
            if (token_equal(source, cursor, "let")) {
                int64_t name = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                const char *mutability = "immutable";
                if (token_equal(source, name, "mut")) {
                    mutability = "mutable";
                    name = skip_trivia(source, token_end(source, name));
                }
                int64_t after_name = skip_trivia(
                    source,
                    token_end(source, name)
                );
                char *binding_type = owned_text("Int");
                bool annotated = false;
                if (token_equal(source, after_name, ":")) {
                    annotated = true;
                    int64_t type_cursor = skip_trivia(
                        source,
                        token_end(source, after_name)
                    );
                    free(binding_type);
                    /* #924: `Int?` is two tokens and one type; the suffix is
                     * consumed here so the initializer walk starts at `=`. */
                    int64_t optional_end = optional_int_type_end(
                        source,
                        type_cursor
                    );
                    int64_t list_end = optional_end >= 0
                        ? -1
                        : list_int_type_end(source, type_cursor);
                    int64_t list_shape_end = optional_end < 0 && list_end < 0
                        ? constructed_list_type_end(
                            source,
                            type_cursor,
                            length
                        )
                        : -1;
                    /* #916: an annotated local records the annotation's full
                     * identity, so `let kept: Fixed[2]` binds `Fixed[2]` and
                     * not `Fixed`. */
                    binding_type = optional_end >= 0
                        ? owned_text("Int?")
                        : (list_end >= 0
                            ? owned_text("List[Int]")
                            : (list_shape_end >= 0
                                ? constructed_list_type_text(
                                    source,
                                    type_cursor,
                                    length
                                )
                                : annotation_type_text(
                                    source,
                                    type_cursor
                                )));
                    after_name = skip_trivia(
                        source,
                        optional_end >= 0
                            ? optional_end
                            : (list_end >= 0
                                ? list_end
                                : (list_shape_end >= 0
                                    ? list_shape_end
                                    : annotation_type_end(
                                        source,
                                        type_cursor
                                    )))
                    );
                }
                int64_t initializer = skip_trivia(
                    source,
                    token_end(source, after_name)
                );
                int64_t visible_start = -1;
                if (value_control(source, initializer)) {
                    char *value_result = parse_value_control(
                        source,
                        hir.data,
                        initializer,
                        &visible_start
                    );
                    free(value_result);
                } else {
                    visible_start = expression_end(source, initializer);
                    if (!annotated) {
                        free(binding_type);
                        binding_type = initializer_type(
                            source,
                            hir.data,
                            function_open,
                            initializer
                        );
                    }
                }
                if (visible_start < 0) {
                    visible_start = token_end(source, initializer);
                }
                int64_t scope_open = parent_block_open(
                    source,
                    function_open,
                    name
                );
                char *scope_id = hir_scope_id_for_open(hir.data, scope_open);
                char *name_text = token_copy(source, name);
                char *first_declaration = hir_same_scope_declaration(
                    hir.data,
                    scope_id,
                    name_text
                );
                if (first_declaration[0] != '\0') {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S47]: duplicate binding `%s` in lexical "
                        "scope at byte %" PRId64
                        "; first declaration at byte %s",
                        name_text,
                        name,
                        first_declaration
                    );
                    stage2_diagnostic_set(
                        "E2S47",
                        name,
                        token_end(source, name),
                        true,
                        error.data
                    );
                    stage2_diagnostic_affected(
                        STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                        name,
                        token_end(source, name)
                    );
                    {
                        int64_t first = decimal_value(first_declaration);
                        stage2_diagnostic_related(
                            first,
                            token_end(source, first),
                            "first declaration"
                        );
                    }
                    stage2_diagnostic_remedy(2u);
                    free(name_text);
                    free(first_declaration);
                    free(binding_type);
                    free(scope_id);
                    free(hir.data);
                    return error.data;
                }
                free(first_declaration);
                ++binding_count;
                if (binding_count > 256) {
                    free(name_text);
                    free(binding_type);
                    free(scope_id);
                    return scope_hir_error(
                        &hir,
                        "lexical binding limit is 256 per function",
                        name
                    );
                }
                const char *ownership =
                    strcmp(binding_type, "Text") == 0 ||
                    strcmp(binding_type, "List") == 0 ||
                    strncmp(binding_type, "List[", 5) == 0 ? "gc" : "copy";
                buffer_format(
                    &hir,
                    "binding|%" PRId64 "|%s|%s|%s|%s|%s|initialized|"
                    "%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
                    next_binding_id++,
                    scope_id,
                    name_text,
                    mutability,
                    binding_type,
                    ownership,
                    name,
                    token_end(source, name),
                    visible_start
                );
                stage2_scope_prefix_observe(&hir);
                free(name_text);
                free(binding_type);
                free(scope_id);
            }
            if (token_equal(source, cursor, "for")) {
                int64_t name = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                int64_t body_open = name;
                while (
                    body_open < function_close &&
                    !token_equal(source, body_open, "{")
                ) {
                    body_open = skip_trivia(
                        source,
                        token_end(source, body_open)
                    );
                }
                if (
                    name < function_close &&
                    body_open < function_close &&
                    strcmp(token_kind(source, name), "identifier") == 0
                ) {
                    char *scope_id = hir_scope_id_for_open(
                        hir.data,
                        body_open
                    );
                    char *name_text = token_copy(source, name);
                    char *first_declaration = hir_same_scope_declaration(
                        hir.data,
                        scope_id,
                        name_text
                    );
                    if (first_declaration[0] != '\0') {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S47]: duplicate binding `%s` in lexical "
                            "scope at byte %" PRId64
                            "; first declaration at byte %s",
                            name_text,
                            name,
                            first_declaration
                        );
                        stage2_diagnostic_set(
                            "E2S47",
                            name,
                            token_end(source, name),
                            true,
                            error.data
                        );
                        stage2_diagnostic_affected(
                            STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                            name,
                            token_end(source, name)
                        );
                        {
                            int64_t first =
                                decimal_value(first_declaration);
                            stage2_diagnostic_related(
                                first,
                                token_end(source, first),
                                "first declaration"
                            );
                        }
                        stage2_diagnostic_remedy(2u);
                        free(name_text);
                        free(first_declaration);
                        free(scope_id);
                        free(hir.data);
                        return error.data;
                    }
                    free(first_declaration);
                    ++binding_count;
                    if (binding_count > 256) {
                        free(name_text);
                        free(scope_id);
                        return scope_hir_error(
                            &hir,
                            "lexical binding limit is 256 per function",
                            name
                        );
                    }
                    buffer_format(
                        &hir,
                        "binding|%" PRId64 "|%s|%s|immutable|Int|copy|"
                        "initialized|%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
                        next_binding_id++,
                        scope_id,
                        name_text,
                        name,
                        token_end(source, name),
                        token_end(source, name)
                    );
                    stage2_scope_prefix_observe(&hir);
                    free(name_text);
                    free(scope_id);
                }
            }
            /*
             * A constructor pattern that names its payload declares a binding
             * in the arm body's scope, exactly as a `for` name declares one in
             * the loop body.  Arm bodies are skipped whole, so a nested match
             * is reached by its own `match` token and no arm is visited twice.
             *
             * Not in candidate-preserving mode: there the resolved ADT
             * adapter owns pattern bindings and expects the payload name to
             * arrive unresolved as a `candidate-use`.  Declaring it here would
             * resolve the name first and take that input away from it.
             */
            if (
                !preserve_pattern_candidates &&
                token_equal(source, cursor, "match")
            ) {
                int64_t arms_open = pattern_match_open(source, cursor);
                int64_t arms_end = arms_open < 0 ?
                    -1 :
                    balanced_end(source, arms_open, "{", "}");
                int64_t match_close = arms_end < 0 ? -1 : arms_end - 1;
                int64_t arm_cursor = arms_end < 0 ?
                    function_close :
                    skip_trivia(source, token_end(source, arms_open));
                while (
                    arm_cursor < match_close &&
                    arm_cursor < function_close &&
                    !token_equal(source, arm_cursor, "}")
                ) {
                    PatternSummary arm = pattern_summary(source, arm_cursor);
                    int64_t arrow = pattern_arm_arrow(
                        source,
                        arm.end,
                        match_close
                    );
                    if (arrow < 0 || !token_equal(source, arrow, "=>")) break;
                    int64_t body_open = skip_trivia(
                        source,
                        token_end(source, arrow)
                    );
                    int64_t body_end = balanced_end(
                        source,
                        body_open,
                        "{",
                        "}"
                    );
                    if (body_end < 0) break;
                    int64_t open = skip_trivia(
                        source,
                        token_end(source, arm_cursor)
                    );
                    int64_t field = skip_trivia(
                        source,
                        token_end(source, open)
                    );
                    int64_t binding_start = -1;
                    char *pattern_binding_type = owned_text("");
                    if (
                        arm.kind == PATTERN_CONSTRUCTOR &&
                        field < function_close &&
                        strcmp(token_kind(source, field), "identifier") == 0 &&
                        !token_equal(source, field, "_")
                    ) {
                        binding_start = field;
                        free(pattern_binding_type);
                        pattern_binding_type = owned_text("Int");
                    } else if (arm.kind == PATTERN_NAME) {
                        char *pattern_name = token_copy(
                            source,
                            arm_cursor
                        );
                        char *constructor_owner = enum_constructor_owner(
                            source,
                            pattern_name
                        );
                        if (
                            constructor_owner[0] == '\0' &&
                            enum_binding_catchall_name(pattern_name)
                        ) {
                            int64_t scrutinee = skip_trivia(
                                source,
                                token_end(source, cursor)
                            );
                            if (
                                scrutinee < function_close &&
                                strcmp(
                                    token_kind(source, scrutinee),
                                    "identifier"
                                ) == 0
                            ) {
                                char *scrutinee_name = token_copy(
                                    source,
                                    scrutinee
                                );
                                int64_t scrutinee_scope_open =
                                    parent_block_open(
                                        source,
                                        function_open,
                                        scrutinee
                                    );
                                char *scrutinee_scope =
                                    hir_scope_id_for_open(
                                        hir.data,
                                        scrutinee_scope_open
                                    );
                                char *scrutinee_binding =
                                    hir_resolve_binding(
                                        hir.data,
                                        scrutinee_scope,
                                        scrutinee,
                                        scrutinee_name
                                    );
                                char *scrutinee_type = hir_binding_field(
                                    hir.data,
                                    scrutinee_binding,
                                    5
                                );
                                if (
                                    enum_constructor_count(
                                        source,
                                        scrutinee_type
                                    ) >= 0
                                ) {
                                    binding_start = arm_cursor;
                                    free(pattern_binding_type);
                                    pattern_binding_type = owned_text(
                                        scrutinee_type
                                    );
                                }
                                free(scrutinee_type);
                                free(scrutinee_binding);
                                free(scrutinee_scope);
                                free(scrutinee_name);
                            }
                        }
                        free(constructor_owner);
                        free(pattern_name);
                    }
                    if (binding_start >= 0) {
                        char *scope_id = hir_scope_id_for_open(
                            hir.data,
                            body_open
                        );
                        char *name_text = token_copy(
                            source,
                            binding_start
                        );
                        char *first_declaration = hir_same_scope_declaration(
                            hir.data,
                            scope_id,
                            name_text
                        );
                        if (first_declaration[0] != '\0') {
                            Buffer error;
                            buffer_init(&error);
                            buffer_format(
                                &error,
                                "error[E2S47]: duplicate binding `%s` in "
                                "lexical scope at byte %" PRId64
                                "; first declaration at byte %s",
                                name_text,
                                binding_start,
                                first_declaration
                            );
                            stage2_diagnostic_set(
                                "E2S47",
                                binding_start,
                                token_end(source, binding_start),
                                true,
                                error.data
                            );
                            stage2_diagnostic_affected(
                                STAGE2_DIAGNOSTIC_AFFECTED_BINDING,
                                binding_start,
                                token_end(source, binding_start)
                            );
                            {
                                int64_t first =
                                    decimal_value(first_declaration);
                                stage2_diagnostic_related(
                                    first,
                                    token_end(source, first),
                                    "first declaration"
                                );
                            }
                            stage2_diagnostic_remedy(2u);
                            free(name_text);
                            free(first_declaration);
                            free(scope_id);
                            free(pattern_binding_type);
                            free(hir.data);
                            return error.data;
                        }
                        free(first_declaration);
                        ++binding_count;
                        if (binding_count > 256) {
                            free(name_text);
                            free(scope_id);
                            free(pattern_binding_type);
                            return scope_hir_error(
                                &hir,
                                "lexical binding limit is 256 per function",
                                binding_start
                            );
                        }
                        buffer_format(
                            &hir,
                            "binding|%" PRId64 "|%s|%s|immutable|%s|copy|"
                            "initialized|%" PRId64 "|%" PRId64 "|%" PRId64
                            "\n",
                            next_binding_id++,
                            scope_id,
                            name_text,
                            pattern_binding_type,
                            binding_start,
                            token_end(source, binding_start),
                            token_end(source, binding_start)
                        );
                        stage2_scope_prefix_observe(&hir);
                        free(name_text);
                        free(scope_id);
                    }
                    free(pattern_binding_type);
                    arm_cursor = skip_trivia(source, body_end);
                    if (
                        arm_cursor < function_close &&
                        token_equal(source, arm_cursor, ",")
                    ) {
                        arm_cursor = skip_trivia(
                            source,
                            token_end(source, arm_cursor)
                        );
                    }
                }
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }

        int64_t use_count = 0;
        bool unresolved_assignment = false;
        cursor = skip_trivia(source, token_end(source, function_open));
        while (cursor < function_close) {
            /* See sh_parse_primary: stop at `par` so the walk never reaches the
             * scope token between the bars and blames it as an unknown
             * binding. The construct is refused, so its token is never a use. */
            if (token_equal(source, cursor, "par")) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "error[E2S154]: scoped parallelism `par` is specified "
                    "but not implemented at byte %" PRId64,
                    cursor
                );
                stage2_diagnostic_set(
                    "E2S154",
                    cursor,
                    token_end(source, cursor),
                    true,
                    message.data
                );
                free(hir.data);
                return message.data;
            }
            if (strcmp(token_kind(source, cursor), "identifier") == 0) {
                char *name = token_copy(source, cursor);
                bool declaration_token = enum_declaration_syntax_token(
                    source,
                    function_open,
                    cursor
                );
                bool record_token = record_syntax_token(
                    source,
                    function_open,
                    cursor
                );
                bool initializer_token = enum_initializer_constructor_token(
                    source,
                    function_open,
                    cursor
                );
                bool pattern_token = enum_match_pattern_token(
                    source,
                    function_open,
                    cursor
                );
                bool lambda_token = lambda_declaration_syntax_token(
                    source,
                    function_open,
                    cursor
                );
                if (
                    !declaration_token && !record_token &&
                    !initializer_token &&
                    !pattern_token && !lambda_token &&
                    !list_int_local_type_token(source, cursor) &&
                    !numeric_conversion_head(source, cursor) &&
                    !move_assertion_head(source, cursor) &&
                    !move_statement_head(source, cursor) &&
                    !decimal_rounding_mode_name(name) &&
                    /* #924: in an `Int?` context `null` is the absence
                     * literal, not a name, and reporting it as an unknown
                     * binding would make the only spelling of absence an
                     * error. Everywhere else it stays exactly what it was. */
                    !optional_int_null_context(source, cursor) &&
                    !token_equal(source, cursor, "print") &&
                    !token_equal(source, cursor, "_")
                ) {
                    int64_t scope_open = lambda_scope_open(
                        source,
                        function_open,
                        cursor
                    );
                    if (scope_open < 0) {
                        scope_open = match_guard_scope_open(
                            source,
                            function_open,
                            cursor
                        );
                    }
                    if (scope_open < 0) {
                        scope_open = parent_block_open(
                            source,
                            function_open,
                            cursor
                        );
                    }
                    char *scope_id = hir_scope_id_for_open(
                        hir.data,
                        scope_open
                    );
                    char *binding_id = hir_resolve_binding(
                        hir.data,
                        scope_id,
                        cursor,
                        name
                    );
                    /* A const generic construction head is `Name[N](`, so
                     * the token that decides call-versus-use is the one after
                     * the argument list. Stopping at `Name` would resolve the
                     * type as a lexical binding and report it unknown. */
                    int64_t after = skip_trivia(
                        source,
                        annotation_type_end(source, cursor)
                    );
                    const char *role = token_equal(source, after, "=") ?
                        "assign" : "read";
                    if (binding_id[0] != '\0') {
                        ++use_count;
                        if (use_count > 256) {
                            free(name);
                            free(scope_id);
                            free(binding_id);
                            return scope_hir_error(
                                &hir,
                                "lexical use limit is 256 per function",
                                cursor
                            );
                        }
                        buffer_format(
                            &hir,
                            "use|%" PRId64 "|%" PRId64 "|%s|%s|%s\n",
                            cursor,
                            token_end(source, cursor),
                            scope_id,
                            binding_id,
                            role
                        );
                        stage2_scope_prefix_observe(&hir);
                    } else if (strcmp(role, "assign") == 0) {
                        ++use_count;
                        if (use_count > 256) {
                            free(name);
                            free(scope_id);
                            free(binding_id);
                            free(hir.data);
                            return lower_error(
                                "E2S35",
                                "lexical use limit is 256 per function",
                                cursor
                            );
                        }
                        buffer_format(
                            &hir,
                            "use|%" PRId64 "|%" PRId64 "|%s|-1|assign\n",
                            cursor,
                            token_end(source, cursor),
                            scope_id
                        );
                        stage2_scope_prefix_observe(&hir);
                        unresolved_assignment = true;
                    } else if (
                        preserve_pattern_candidates &&
                        !token_equal(source, after, "(")
                    ) {
                        ++use_count;
                        if (use_count > 256) {
                            free(name);
                            free(scope_id);
                            free(binding_id);
                            return scope_hir_error(
                                &hir,
                                "lexical use limit is 256 per function",
                                cursor
                            );
                        }
                        buffer_format(
                            &hir,
                            "candidate-use|%" PRId64 "|%" PRId64
                            "|%s|%s|%s\n",
                            cursor,
                            token_end(source, cursor),
                            scope_id,
                            name,
                            role
                        );
                        stage2_scope_prefix_observe(&hir);
                    } else if (
                        !token_equal(source, after, "(") &&
                        !unresolved_assignment
                    ) {
                        char *owner = enum_constructor_owner(source, name);
                        char *pending = hir_pending_declaration(
                            hir.data,
                            scope_id,
                            cursor,
                            name
                        );
                            if (pending[0] != '\0') {
                                Buffer message;
                                buffer_init(&message);
                                buffer_format(
                                    &message,
                                    "error[E2S35]: binding `%s` is not "
                                    "initialized at byte "
                                    "%" PRId64 "; declaration at byte %s",
                                    name,
                                    cursor,
                                    pending
                                );
                                stage2_diagnostic_set(
                                    "E2S35",
                                    cursor,
                                    token_end(source, cursor),
                                    true,
                                    message.data
                                );
                                {
                                    int64_t declaration =
                                        decimal_value(pending);
                                    stage2_diagnostic_related(
                                        declaration,
                                        token_end(source, declaration),
                                        "declaration"
                                    );
                                }
                                stage2_diagnostic_remedy(3u);
                                free(name);
                                free(scope_id);
                                free(binding_id);
                                free(owner);
                                free(pending);
                                free(hir.data);
                                return message.data;
                            }
                            free(pending);
                            char *escaped = hir_any_declaration(
                                hir.data,
                                scope_id,
                                cursor,
                                name
                            );
                            if (escaped[0] != '\0') {
                                Buffer message;
                                buffer_init(&message);
                                buffer_format(
                                    &message,
                                    "error[E2S35]: binding `%s` is outside its "
                                    "lexical scope at byte %" PRId64
                                    "; declaration at byte %s",
                                    name,
                                    cursor,
                                    escaped
                                );
                                stage2_diagnostic_set(
                                    "E2S35",
                                    cursor,
                                    token_end(source, cursor),
                                    true,
                                    message.data
                                );
                                {
                                    int64_t declaration =
                                        decimal_value(escaped);
                                    stage2_diagnostic_related(
                                        declaration,
                                        token_end(source, declaration),
                                        "declaration"
                                    );
                                }
                                stage2_diagnostic_remedy(3u);
                                free(name);
                                free(scope_id);
                                free(binding_id);
                                free(owner);
                                free(escaped);
                                free(hir.data);
                                return message.data;
                            }
                            free(escaped);
                        /* A declared Core function passed as an argument is
                         * that function used as a value. It is not a lexical
                         * binding, so nothing resolves it here, and reporting
                         * it as unknown would make the only way to pass a
                         * named function an error. Anywhere but argument
                         * position it stays unknown, so a function name in
                         * arithmetic is still this diagnostic. */
                        /* A module constant is not a lexical binding either: it
                         * is declared once at top level and is visible to every
                         * function, so no scope entry resolves it here. */
                        if (
                            owner[0] == '\0' &&
                            !constant_is_declared(source, name) &&
                            !(function_arity(source, name) >= 0 &&
                              call_argument_position(source, cursor))
                        ) {
                            Buffer message;
                            buffer_init(&message);
                            buffer_format(
                                &message,
                                "error[E2S35]: unknown lexical binding `%s` "
                                "at byte %" PRId64,
                                name,
                                cursor
                            );
                            stage2_diagnostic_set(
                                "E2S35",
                                cursor,
                                token_end(source, cursor),
                                true,
                                message.data
                            );
                            free(name);
                            free(scope_id);
                            free(binding_id);
                            free(owner);
                            free(hir.data);
                            return message.data;
                        }
                        free(owner);
                    }
                    free(scope_id);
                    free(binding_id);
                }
                free(name);
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        function_start = next_function_start(source, function_close);
    }
    return hir.data;
}

static char *build_scope_hir(const char *source) {
    return build_scope_hir_mode(source, false);
}

static char *validate_enum_uses(const char *source, const char *hir) {
    int64_t length = source_length(source);
    char *constructor_names = enum_declaration_names(source, true);
    if (strcmp(constructor_names, "|") == 0) {
        free(constructor_names);
        return owned_text("ok");
    }
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = balanced_end(
            source,
            parameters,
            "(",
            ")"
        );
        int64_t function_open = skip_trivia(source, parameters_close);
        while (
            function_open < function_close &&
            !token_equal(source, function_open, "{")
        ) {
            function_open = skip_trivia(
                source,
                token_end(source, function_open)
            );
        }
        int64_t related_identifiers = 0;
        int64_t cursor = skip_trivia(
            source,
            token_end(source, function_open)
        );
        char *previous = owned_text("");
        while (cursor < function_close) {
            if (strcmp(token_kind(source, cursor), "identifier") == 0) {
                char *name = token_copy(source, cursor);
                bool pattern_token = enum_match_pattern_token(
                    source,
                    function_open,
                    cursor
                );
                bool initializer_token =
                    enum_initializer_constructor_token(
                        source,
                        function_open,
                        cursor
                    );
                bool declaration_token = enum_declaration_syntax_token(
                    source,
                    function_open,
                    cursor
                );
                char *binding_id = hir_use_binding_id(hir, cursor);
                char *binding_type = hir_binding_field(
                    hir,
                    binding_id,
                    5
                );
                bool binding_enum =
                    binding_type[0] != '\0' &&
                    enum_constructor_count(source, binding_type) >= 0;
                bool constructor_named = enum_name_covered(
                    constructor_names,
                    name
                );
                bool related =
                    pattern_token || initializer_token || binding_enum ||
                    (
                        constructor_named && binding_id[0] == '\0' &&
                        !declaration_token
                    );
                if (related) {
                    ++related_identifiers;
                    if (related_identifiers > 256) {
                        Buffer error;
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S32]: enum-related identifier use "
                            "limit is 256 per function at byte %" PRId64,
                            cursor
                        );
                        stage2_diagnostic_set(
                            "E2S32",
                            cursor,
                            token_end(source, cursor),
                            true,
                            error.data
                        );
                        free(name);
                        free(binding_id);
                        free(binding_type);
                        free(previous);
                        free(constructor_names);
                        return error.data;
                    }
                    if (
                        !pattern_token && !initializer_token &&
                        !declaration_token
                    ) {
                        if (binding_enum) {
                            int64_t after = skip_trivia(
                                source,
                                token_end(source, cursor)
                            );
                            bool match_scrutinee =
                                strcmp(previous, "match") == 0 &&
                                token_equal(source, after, "{");
                            char *argument_type =
                                call_argument_expected_type(source, cursor);
                            char *return_type =
                                function_return_type_containing(
                                    source,
                                    cursor
                                );
                            bool enum_argument =
                                strcmp(argument_type, binding_type) == 0;
                            bool enum_return =
                                strcmp(previous, "return") == 0 &&
                                strcmp(return_type, binding_type) == 0;
                            free(argument_type);
                            free(return_type);
                            if (
                                !match_scrutinee &&
                                !enum_argument &&
                                !enum_return
                            ) {
                                Buffer error;
                                buffer_init(&error);
                                buffer_format(
                                    &error,
                                    "error[E2S32]: concrete enum binding "
                                    "`%s` is match-only in this Core "
                                    "slice at byte %" PRId64,
                                    name,
                                    cursor
                                );
                                stage2_diagnostic_set(
                                    "E2S32",
                                    cursor,
                                    token_end(source, cursor),
                                    true,
                                    error.data
                                );
                                free(name);
                                free(binding_id);
                                free(binding_type);
                                free(previous);
                                free(constructor_names);
                                return error.data;
                            }
                        } else if (
                            constructor_named && binding_id[0] == '\0'
                        ) {
                            int64_t after = skip_trivia(
                                source,
                                token_end(source, cursor)
                            );
                            bool resolved_function_call =
                                token_equal(source, after, "(") &&
                                function_arity(source, name) >= 0;
                            if (!resolved_function_call) {
                                char *constructor_owner =
                                    enum_constructor_owner(
                                    source,
                                    name
                                );
                                char *argument_type =
                                    call_argument_expected_type(
                                        source,
                                        cursor
                                    );
                                char *return_type =
                                    function_return_type_containing(
                                        source,
                                        cursor
                                    );
                                bool enum_argument =
                                    constructor_owner[0] != '\0' &&
                                    strcmp(
                                        argument_type,
                                        constructor_owner
                                    ) == 0;
                                bool enum_return =
                                    constructor_owner[0] != '\0' &&
                                    strcmp(previous, "return") == 0 &&
                                    strcmp(
                                        return_type,
                                        constructor_owner
                                    ) == 0;
                                free(argument_type);
                                free(return_type);
                                if (
                                    constructor_owner[0] != '\0' &&
                                    !enum_argument &&
                                    !enum_return
                                ) {
                                    Buffer error;
                                    buffer_init(&error);
                                    buffer_format(
                                        &error,
                                        "error[E2S32]: concrete enum "
                                        "constructor `%s` is only valid in an "
                                        "explicitly typed enum initializer or "
                                        "match pattern at byte %" PRId64,
                                        name,
                                        cursor
                                    );
                                    stage2_diagnostic_set(
                                        "E2S32",
                                        cursor,
                                        token_end(source, cursor),
                                        true,
                                        error.data
                                    );
                                    free(name);
                                    free(binding_id);
                                    free(binding_type);
                                    free(constructor_owner);
                                    free(previous);
                                    free(constructor_names);
                                    return error.data;
                                }
                                free(constructor_owner);
                            }
                        }
                    }
                }
                if (constructor_named &&
                    (initializer_token || pattern_token)) {
                    char *constructor_owner = enum_constructor_owner(
                        source,
                        name
                    );
                    if (constructor_owner[0] != '\0') {
                        if (initializer_token) {
                            stage2_semantic_observe(
                                "call|constructor|%s|%" PRId64
                                "|%" PRId64 "|%s\n",
                                name,
                                cursor,
                                token_end(source, cursor),
                                constructor_owner
                            );
                        }
                        if (pattern_token) {
                            PatternSummary summary = pattern_summary(
                                source,
                                cursor
                            );
                            stage2_semantic_observe(
                                "pattern|constructor|%s|%" PRId64
                                "|%" PRId64 "|%s\n",
                                name,
                                cursor,
                                summary.end,
                                constructor_owner
                            );
                        }
                    }
                    free(constructor_owner);
                }
                free(binding_id);
                free(binding_type);
                free(name);
            }
            free(previous);
            previous = token_copy(source, cursor);
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        free(previous);
        function_start = next_function_start(source, function_close);
    }
    free(constructor_names);
    return owned_text("ok");
}

static int64_t enum_match_end(const char *source, int64_t start) {
    int64_t length = source_length(source);
    int64_t value_start = skip_trivia(source, token_end(source, start));
    int64_t arms_open = skip_trivia(source, token_end(source, value_start));
    if (arms_open >= length || !token_equal(source, arms_open, "{")) {
        return -1;
    }
    return balanced_end(source, arms_open, "{", "}");
}

static char *lower_body(
    const char *source,
    const char *hir,
    int64_t open,
    bool is_main,
    bool append_default,
    int64_t function_open
);

static char *lower_enum_match_error(
    Buffer *covered,
    Buffer *dispatch,
    Buffer *dense_dispatch,
    const char *code,
    const char *message,
    int64_t cursor
) {
    free(covered->data);
    free(dispatch->data);
    free(dense_dispatch->data);
    return lower_error(code, message, cursor);
}

static char *lower_enum_match(
    const char *source,
    const char *hir,
    int64_t match_start,
    const char *enum_type,
    bool is_main,
    int64_t function_open
) {
    int64_t length = source_length(source);
    int64_t value_start = skip_trivia(
        source,
        token_end(source, match_start)
    );
    int64_t arms_open = skip_trivia(source, token_end(source, value_start));
    Buffer covered;
    Buffer dispatch;
    Buffer dense_dispatch;
    buffer_init(&covered);
    buffer_init(&dispatch);
    buffer_init(&dense_dispatch);
    buffer_append(&covered, "|");
    if (arms_open >= length || !token_equal(source, arms_open, "{")) {
        return lower_enum_match_error(
            &covered,
            &dispatch,
            &dense_dispatch,
            "E2S24",
            "expected `{` after enum match scrutinee",
            arms_open
        );
    }

    int64_t arm_cursor = skip_trivia(
        source,
        token_end(source, arms_open)
    );
    bool seen_catchall = false;
    bool dense_eligible = true;
    char *match_result_type = function_return_type_containing(
        source,
        function_open
    );
    bool match_returns_enum =
        enum_constructor_count(source, match_result_type) >= 0;
    free(match_result_type);
    const char *failure_result =
        is_main ? "1" :
        (match_returns_enum ? "KOFUN_ENUM_ZERO" : "0");
    while (arm_cursor < length && !token_equal(source, arm_cursor, "}")) {
        int64_t pattern_start = arm_cursor;
        PatternSummary pattern_summary_value = pattern_summary(
            source,
            pattern_start
        );
        char *pattern = token_copy(source, pattern_start);
        int64_t tag =
            pattern_summary_value.kind == PATTERN_NAME ||
            pattern_summary_value.kind == PATTERN_CONSTRUCTOR
                ? enum_constructor_index(source, enum_type, pattern)
                : -1;
        bool binding_catchall =
            pattern_summary_value.kind == PATTERN_NAME &&
            tag < 0 &&
            enum_binding_catchall_name(pattern);
        bool catchall =
            pattern_summary_value.kind == PATTERN_WILDCARD ||
            binding_catchall;
        if (catchall) dense_eligible = false;
        if (seen_catchall) {
            free(pattern);
            return lower_enum_match_error(
                &covered,
                &dispatch,
                &dense_dispatch,
                "E2S26",
                "pattern after catch-all is unreachable",
                pattern_start
            );
        }
        /*
         * `-1` means the arm binds no payload name.  Keeping the decision as a
         * source offset rather than an owned id lets every validation path
         * below return without an extra free.
         */
        int64_t payload_name_start = -1;
        int64_t catchall_name_start =
            binding_catchall ? pattern_start : -1;
        if (catchall) {
            if (enum_constructors_covered(source, enum_type, covered.data)) {
                free(pattern);
                return lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S26",
                    "catch-all pattern is unreachable",
                    pattern_start
                );
            }
        } else {
            if (
                pattern_summary_value.kind != PATTERN_NAME &&
                pattern_summary_value.kind != PATTERN_CONSTRUCTOR
            ) {
                free(pattern);
                return lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    "enum pattern must name a constructor or `_`",
                    pattern_start
                );
            }
            if (tag < 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "constructor `%s` does not belong to enum `%s`",
                    pattern,
                    enum_type
                );
                free(pattern);
                char *error = lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (enum_name_covered(covered.data, pattern)) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "duplicate enum constructor pattern `%s` is unreachable",
                    pattern
                );
                free(pattern);
                char *error = lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S26",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            int64_t arity = enum_constructor_payload_arity(
                source,
                enum_type,
                pattern
            );
            bool applied =
                pattern_summary_value.kind == PATTERN_CONSTRUCTOR;
            if (arity < 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "constructor `%s` of enum `%s` declares a payload outside "
                    "this Core slice; one `Int` field is supported",
                    pattern,
                    enum_type
                );
                free(pattern);
                char *error = lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (arity != 0) dense_eligible = false;
            if (applied != (arity == 1)) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    arity == 1 ?
                        "constructor pattern `%s` must bind its one `Int` "
                        "payload or use `_`" :
                        "constructor pattern `%s` takes no payload",
                    pattern
                );
                free(pattern);
                char *error = lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (applied) {
                int64_t open = skip_trivia(
                    source,
                    token_end(source, pattern_start)
                );
                int64_t field = skip_trivia(
                    source,
                    token_end(source, open)
                );
                int64_t close = field >= length ?
                    length :
                    skip_trivia(source, token_end(source, field));
                bool wildcard = token_equal(source, field, "_");
                bool named =
                    field < length &&
                    strcmp(token_kind(source, field), "identifier") == 0 &&
                    !wildcard;
                if (
                    (!wildcard && !named) ||
                    close >= length ||
                    !token_equal(source, close, ")")
                ) {
                    free(pattern);
                    return lower_enum_match_error(
                        &covered,
                        &dispatch,
                        &dense_dispatch,
                        "E2S32",
                        "constructor payload pattern must be one name or `_`",
                        field
                    );
                }
                if (named) payload_name_start = field;
            }
        }

        int64_t arrow = skip_trivia(
            source,
            pattern_summary_value.end
        );
        bool guarded = false;
        int64_t guard_start = -1;
        int64_t guard_end = -1;
        if (arrow < length && token_equal(source, arrow, "if")) {
            guarded = true;
            dense_eligible = false;
            guard_start = skip_trivia(source, token_end(source, arrow));
            guard_end = condition_end(source, guard_start);
            if (guard_end < 0) {
                free(pattern);
                return lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S29",
                    "match guard must be Bool or an Int comparison",
                    guard_start
                );
            }
            arrow = skip_trivia(source, guard_end);
        }
        if (arrow >= length || !token_equal(source, arrow, "=>")) {
            free(pattern);
            return lower_enum_match_error(
                &covered,
                &dispatch,
                &dense_dispatch,
                "E2S24",
                "expected `=>` after enum pattern",
                arrow
            );
        }
        int64_t arm_open = skip_trivia(source, token_end(source, arrow));
        if (arm_open >= length || !token_equal(source, arm_open, "{")) {
            free(pattern);
            return lower_enum_match_error(
                &covered,
                &dispatch,
                &dense_dispatch,
                "E2S24",
                "bounded enum match arm must use a block",
                arm_open
            );
        }
        int64_t arm_close = balanced_end(source, arm_open, "{", "}");
        if (arm_close < 0) {
            free(pattern);
            return lower_enum_match_error(
                &covered,
                &dispatch,
                &dense_dispatch,
                "E2S24",
                "missing `}` after enum match arm",
                arm_open
            );
        }
        char *arm_body = lower_body(
            source,
            hir,
            arm_open,
            is_main,
            false,
            function_open
        );
        if (strncmp(arm_body, "error[", 6) == 0) {
            free(pattern);
            free(covered.data);
            free(dispatch.data);
            free(dense_dispatch.data);
            return arm_body;
        }
        if (!catchall && !guarded && payload_name_start < 0) {
            buffer_format(
                &dense_dispatch,
                "            case INT64_C(%" PRId64 "): {\n"
                "%s"
                "                break;\n"
                "            }\n",
                tag,
                arm_body
            );
        }

        Buffer pattern_condition;
        buffer_init(&pattern_condition);
        if (catchall) {
            buffer_append(&pattern_condition, "true");
        } else {
            buffer_format(
                &pattern_condition,
                "kofun_match_value.tag == INT64_C(%" PRId64 ")",
                tag
            );
        }
        /*
         * The payload name is declared before the guard, not only before the
         * body, so `Present(value) if value > 5` reads the same local the arm
         * body reads.  The declaration is inside the arm's `if`, so it is only
         * in scope where the constructor actually matched.
         */
        Buffer payload_declaration;
        buffer_init(&payload_declaration);
        if (payload_name_start >= 0) {
            char *payload_id = hir_definition_id_at(hir, payload_name_start);
            if (payload_id[0] == '\0') {
                free(payload_id);
                free(payload_declaration.data);
                free(pattern_condition.data);
                free(arm_body);
                free(pattern);
                return lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    "constructor payload binding is unresolved",
                    payload_name_start
                );
            }
            buffer_format(
                &payload_declaration,
                "            int64_t k_b%s = "
                "kofun_match_value.payload;\n"
                "            (void)k_b%s;\n",
                payload_id,
                payload_id
            );
            free(payload_id);
        } else if (catchall_name_start >= 0) {
            char *catchall_id = hir_definition_id_at(
                hir,
                catchall_name_start
            );
            if (catchall_id[0] == '\0') {
                free(catchall_id);
                free(payload_declaration.data);
                free(pattern_condition.data);
                free(arm_body);
                free(pattern);
                return lower_enum_match_error(
                    &covered,
                    &dispatch,
                    &dense_dispatch,
                    "E2S32",
                    "enum catch-all binding is unresolved",
                    catchall_name_start
                );
            }
            buffer_format(
                &payload_declaration,
                "            KofunEnumValue k_b%s = "
                "kofun_match_value;\n"
                "            (void)k_b%s;\n",
                catchall_id,
                catchall_id
            );
            free(catchall_id);
        }
        if (guarded) {
            char *guard = emit_condition_into(
                source,
                hir,
                guard_start,
                guard_end,
                "kofun_match_guard",
                failure_result,
                "            "
            );
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "%s"
                "            if (kofun_match_guard) {\n"
                "%s"
                "                kofun_match_selected = true;\n"
                "            }\n"
                "        }\n",
                pattern_condition.data,
                payload_declaration.data,
                guard,
                arm_body
            );
            free(guard);
        } else {
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "%s"
                "            kofun_match_selected = true;\n"
                "        }\n",
                pattern_condition.data,
                payload_declaration.data,
                arm_body
            );
            if (catchall) {
                seen_catchall = true;
            } else {
                buffer_append(&covered, pattern);
                buffer_append(&covered, "|");
            }
        }
        free(payload_declaration.data);
        free(pattern_condition.data);
        free(arm_body);
        free(pattern);

        arm_cursor = skip_trivia(source, arm_close);
        if (arm_cursor < length && token_equal(source, arm_cursor, ",")) {
            arm_cursor = skip_trivia(
                source,
                token_end(source, arm_cursor)
            );
        } else if (
            arm_cursor >= length ||
            !token_equal(source, arm_cursor, "}")
        ) {
            return lower_enum_match_error(
                &covered,
                &dispatch,
                &dense_dispatch,
                "E2S24",
                "expected `,` between enum match arms",
                arm_cursor
            );
        }
    }
    if (arm_cursor >= length || !token_equal(source, arm_cursor, "}")) {
        return lower_enum_match_error(
            &covered,
            &dispatch,
            &dense_dispatch,
            "E2S24",
            "missing `}` after enum match arms",
            arms_open
        );
    }
    if (
        !seen_catchall &&
        !enum_constructors_covered(source, enum_type, covered.data)
    ) {
        char *missing = enum_missing_constructors(
            source,
            enum_type,
            covered.data
        );
        Buffer message;
        buffer_init(&message);
        buffer_format(
            &message,
            "non-exhaustive enum `%s` match; missing constructors %s",
            enum_type,
            missing
        );
        free(missing);
        char *error = lower_enum_match_error(
            &covered,
            &dispatch,
            &dense_dispatch,
            "E2S25",
            message.data,
            match_start
        );
        free(message.data);
        return error;
    }

    char *binding_id = hir_use_binding_id(hir, value_start);
    Buffer emitted;
    buffer_init(&emitted);
    if (dense_eligible && !seen_catchall) {
        buffer_format(
            &emitted,
            "    {\n"
            "        KofunEnumValue kofun_match_value = k_b%s;\n"
            "        (void)kofun_match_value;\n"
            "        switch (kofun_match_value.tag) {\n"
            "%s"
            "        }\n"
            "    }\n",
            binding_id,
            dense_dispatch.data
        );
    } else {
        buffer_format(
            &emitted,
            "    {\n"
            "        KofunEnumValue kofun_match_value = k_b%s;\n"
            "        (void)kofun_match_value;\n"
            "        bool kofun_match_selected = false;\n"
            "%s"
            "    }\n",
            binding_id,
            dispatch.data
        );
    }
    free(binding_id);
    free(covered.data);
    free(dispatch.data);
    free(dense_dispatch.data);
    return emitted.data;
}

/*
 * The enum a value-position `match` scrutinises, or "" when it does not
 * scrutinise one.  The shape is the one statement position already recognises
 * — a single identifier directly followed by the arms `{` — and the type comes
 * from resolution rather than spelling, so a Bool or Int binding still falls
 * through to the Bool rules and earns exactly the diagnostic it earned before.
 */
static char *value_match_enum_type(
    const char *source,
    const char *hir,
    int64_t start
) {
    int64_t length = source_length(source);
    int64_t value_start = skip_trivia(source, token_end(source, start));
    if (
        value_start >= length ||
        strcmp(token_kind(source, value_start), "identifier") != 0
    ) {
        return owned_text("");
    }
    int64_t arms_open = skip_trivia(source, token_end(source, value_start));
    if (arms_open >= length || !token_equal(source, arms_open, "{")) {
        return owned_text("");
    }
    char *binding_id = hir_use_binding_id(hir, value_start);
    char *binding_type = hir_binding_field(hir, binding_id, 5);
    free(binding_id);
    if (
        binding_type[0] == '\0' ||
        strcmp(binding_type, "Int") == 0 ||
        enum_constructor_count(source, binding_type) < 0
    ) {
        free(binding_type);
        return owned_text("");
    }
    return binding_type;
}

/*
 * One arm block of a value-position `match` must hold exactly one final Int
 * expression, the same rule a value `if` branch follows.  `E2S30` is the whole
 * vocabulary, so a Bool scrutinee and an enum scrutinee refuse identically.
 * `arm_close` is left on the arm's `}` for the caller's walk.
 */
static char *parse_value_arm(
    const char *source,
    const char *hir,
    int64_t arm_open,
    int64_t *arm_close
) {
    int64_t length = source_length(source);
    int64_t arm_start = skip_trivia(source, token_end(source, arm_open));
    int64_t arm_end = -1;
    if (token_equal(source, arm_start, "if")) {
        ValueIfParts nested;
        char *result = parse_value_if(source, hir, arm_start, &nested);
        if (strncmp(result, "error[", 6) == 0) return result;
        free(result);
        arm_end = nested.end;
    } else if (token_equal(source, arm_start, "match")) {
        ValueMatchParts nested;
        char *result = parse_value_match(source, hir, arm_start, &nested);
        if (strncmp(result, "error[", 6) == 0) return result;
        free(result);
        arm_end = nested.end;
    } else {
        if (token_equal(source, arm_start, "print")) {
            return lower_error(
                "E2S30",
                "value-position match arm must produce Int, not Void",
                arm_start
            );
        }
        arm_end = expression_end(source, arm_start);
        if (arm_end < 0) {
            return lower_error(
                "E2S30",
                "value-position match arm must produce Int",
                arm_start
            );
        }
    }
    *arm_close = skip_trivia(source, arm_end);
    if (*arm_close >= length || !token_equal(source, *arm_close, "}")) {
        return lower_error(
            "E2S30",
            "value-position match arm must contain one final Int expression",
            *arm_close
        );
    }
    return owned_text("ok");
}

static char *parse_value_enum_match_error(
    Buffer *covered,
    const char *code,
    const char *message,
    int64_t cursor
) {
    free(covered->data);
    return lower_error(code, message, cursor);
}

/*
 * Value position for a concrete-enum scrutinee.  The coverage rules are the
 * ones statement position already applies to the same declared constructor set
 * — `E2S25` for a missing constructor, `E2S26` for a duplicate or unreachable
 * arm, `E2S32` for a constructor that is not the scrutinee's, and a guarded arm
 * proving no coverage — and the arm rule is the value rule, `E2S30`.  Nothing
 * here widens payloads or adds a pattern form.
 */
static char *parse_value_enum_match(
    const char *source,
    const char *hir,
    int64_t start,
    const char *enum_type,
    ValueMatchParts *parts
) {
    int64_t length = source_length(source);
    parts->value_start = skip_trivia(source, token_end(source, start));
    parts->value_end = token_end(source, parts->value_start);
    parts->arms_open = skip_trivia(source, parts->value_end);
    Buffer covered;
    buffer_init(&covered);
    buffer_append(&covered, "|");
    if (
        parts->arms_open >= length ||
        !token_equal(source, parts->arms_open, "{")
    ) {
        return parse_value_enum_match_error(
            &covered,
            "E2S24",
            "expected `{` after enum match scrutinee",
            parts->arms_open
        );
    }

    int64_t arm_cursor = skip_trivia(
        source,
        token_end(source, parts->arms_open)
    );
    bool seen_catchall = false;
    while (arm_cursor < length && !token_equal(source, arm_cursor, "}")) {
        int64_t pattern_start = arm_cursor;
        PatternSummary pattern_summary_value = pattern_summary(
            source,
            pattern_start
        );
        char *pattern = token_copy(source, pattern_start);
        int64_t tag =
            pattern_summary_value.kind == PATTERN_NAME ||
            pattern_summary_value.kind == PATTERN_CONSTRUCTOR
                ? enum_constructor_index(source, enum_type, pattern)
                : -1;
        bool binding_catchall =
            pattern_summary_value.kind == PATTERN_NAME &&
            tag < 0 &&
            enum_binding_catchall_name(pattern);
        bool catchall =
            pattern_summary_value.kind == PATTERN_WILDCARD ||
            binding_catchall;
        if (seen_catchall) {
            free(pattern);
            return parse_value_enum_match_error(
                &covered,
                "E2S26",
                "pattern after catch-all is unreachable",
                pattern_start
            );
        }
        if (catchall) {
            if (enum_constructors_covered(source, enum_type, covered.data)) {
                free(pattern);
                return parse_value_enum_match_error(
                    &covered,
                    "E2S26",
                    "catch-all pattern is unreachable",
                    pattern_start
                );
            }
        } else {
            if (
                pattern_summary_value.kind != PATTERN_NAME &&
                pattern_summary_value.kind != PATTERN_CONSTRUCTOR
            ) {
                free(pattern);
                return parse_value_enum_match_error(
                    &covered,
                    "E2S32",
                    "enum pattern must name a constructor or `_`",
                    pattern_start
                );
            }
            if (tag < 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "constructor `%s` does not belong to enum `%s`",
                    pattern,
                    enum_type
                );
                free(pattern);
                char *error = parse_value_enum_match_error(
                    &covered,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (enum_name_covered(covered.data, pattern)) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "duplicate enum constructor pattern `%s` is unreachable",
                    pattern
                );
                free(pattern);
                char *error = parse_value_enum_match_error(
                    &covered,
                    "E2S26",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            int64_t arity = enum_constructor_payload_arity(
                source,
                enum_type,
                pattern
            );
            bool applied =
                pattern_summary_value.kind == PATTERN_CONSTRUCTOR;
            if (arity < 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "constructor `%s` of enum `%s` declares a payload outside "
                    "this Core slice; one `Int` field is supported",
                    pattern,
                    enum_type
                );
                free(pattern);
                char *error = parse_value_enum_match_error(
                    &covered,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (applied != (arity == 1)) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    arity == 1 ?
                        "constructor pattern `%s` must bind its one `Int` "
                        "payload or use `_`" :
                        "constructor pattern `%s` takes no payload",
                    pattern
                );
                free(pattern);
                char *error = parse_value_enum_match_error(
                    &covered,
                    "E2S32",
                    message.data,
                    pattern_start
                );
                free(message.data);
                return error;
            }
            if (applied) {
                int64_t open = skip_trivia(
                    source,
                    token_end(source, pattern_start)
                );
                int64_t field = skip_trivia(
                    source,
                    token_end(source, open)
                );
                int64_t close = field >= length ?
                    length :
                    skip_trivia(source, token_end(source, field));
                bool wildcard = token_equal(source, field, "_");
                bool named =
                    field < length &&
                    strcmp(token_kind(source, field), "identifier") == 0 &&
                    !wildcard;
                if (
                    (!wildcard && !named) ||
                    close >= length ||
                    !token_equal(source, close, ")")
                ) {
                    free(pattern);
                    return parse_value_enum_match_error(
                        &covered,
                        "E2S32",
                        "constructor payload pattern must be one name or `_`",
                        field
                    );
                }
            }
        }

        int64_t arrow = skip_trivia(source, pattern_summary_value.end);
        bool guarded = false;
        if (arrow < length && token_equal(source, arrow, "if")) {
            guarded = true;
            int64_t guard_start = skip_trivia(
                source,
                token_end(source, arrow)
            );
            int64_t guard_end = condition_end(source, guard_start);
            if (guard_end < 0) {
                free(pattern);
                return parse_value_enum_match_error(
                    &covered,
                    "E2S29",
                    "match guard must be Bool or an Int comparison",
                    guard_start
                );
            }
            arrow = skip_trivia(source, guard_end);
        }
        if (arrow >= length || !token_equal(source, arrow, "=>")) {
            free(pattern);
            return parse_value_enum_match_error(
                &covered,
                "E2S24",
                "expected `=>` after enum pattern",
                arrow
            );
        }
        int64_t arm_open = skip_trivia(source, token_end(source, arrow));
        if (arm_open >= length || !token_equal(source, arm_open, "{")) {
            free(pattern);
            return parse_value_enum_match_error(
                &covered,
                "E2S24",
                "bounded enum match arm must use a block",
                arm_open
            );
        }
        int64_t arm_close = -1;
        char *arm_result = parse_value_arm(
            source,
            hir,
            arm_open,
            &arm_close
        );
        if (strncmp(arm_result, "error[", 6) == 0) {
            free(pattern);
            free(covered.data);
            return arm_result;
        }
        free(arm_result);

        if (!guarded) {
            if (catchall) {
                seen_catchall = true;
            } else {
                buffer_append(&covered, pattern);
                buffer_append(&covered, "|");
            }
        }
        free(pattern);

        arm_cursor = skip_trivia(source, token_end(source, arm_close));
        if (arm_cursor < length && token_equal(source, arm_cursor, ",")) {
            arm_cursor = skip_trivia(
                source,
                token_end(source, arm_cursor)
            );
        } else if (
            arm_cursor >= length ||
            !token_equal(source, arm_cursor, "}")
        ) {
            return parse_value_enum_match_error(
                &covered,
                "E2S24",
                "expected `,` between enum match arms",
                arm_cursor
            );
        }
    }
    if (arm_cursor >= length || !token_equal(source, arm_cursor, "}")) {
        return parse_value_enum_match_error(
            &covered,
            "E2S24",
            "missing `}` after enum match arms",
            parts->arms_open
        );
    }
    if (
        !seen_catchall &&
        !enum_constructors_covered(source, enum_type, covered.data)
    ) {
        char *missing = enum_missing_constructors(
            source,
            enum_type,
            covered.data
        );
        Buffer message;
        buffer_init(&message);
        buffer_format(
            &message,
            "non-exhaustive enum `%s` match; missing constructors %s",
            enum_type,
            missing
        );
        free(missing);
        char *error = parse_value_enum_match_error(
            &covered,
            "E2S25",
            message.data,
            start
        );
        free(message.data);
        return error;
    }

    free(covered.data);
    parts->end = token_end(source, arm_cursor);
    stage2_semantic_observe(
        "control|match|%" PRId64 "|%" PRId64 "|Int|%" PRId64
        "|%" PRId64 "\n",
        start,
        parts->end,
        parts->value_start,
        parts->value_end
    );
    return owned_text("ok");
}

/*
 * The dispatch statement position emits for a concrete enum, with the arm
 * bodies replaced by the value each arm produces.  The scrutinee is read once
 * into `kofun_match_value` before any arm is tested, arms are tested in source
 * order, and `kofun_match_selected` stops the walk at the first arm that takes,
 * so only that arm's result expression runs and only it assigns `target`.
 */
static char *emit_value_enum_match_into(
    const char *source,
    const char *hir,
    int64_t start,
    int64_t end,
    const char *target,
    const char *failure_result,
    const char *enum_type
) {
    int64_t value_start = skip_trivia(source, token_end(source, start));
    int64_t arms_open = skip_trivia(source, token_end(source, value_start));
    Buffer dispatch;
    buffer_init(&dispatch);
    int64_t arm_cursor = skip_trivia(source, token_end(source, arms_open));
    while (arm_cursor < end && !token_equal(source, arm_cursor, "}")) {
        int64_t pattern_start = arm_cursor;
        PatternSummary pattern_summary_value = pattern_summary(
            source,
            pattern_start
        );
        char *pattern = token_copy(source, pattern_start);
        int64_t tag =
            pattern_summary_value.kind == PATTERN_NAME ||
            pattern_summary_value.kind == PATTERN_CONSTRUCTOR
                ? enum_constructor_index(source, enum_type, pattern)
                : -1;
        bool binding_catchall =
            pattern_summary_value.kind == PATTERN_NAME &&
            tag < 0 &&
            enum_binding_catchall_name(pattern);
        bool catchall =
            pattern_summary_value.kind == PATTERN_WILDCARD ||
            binding_catchall;
        /* `-1` means the arm binds no payload name. */
        int64_t payload_name_start = -1;
        int64_t catchall_name_start =
            binding_catchall ? pattern_start : -1;
        if (
            !catchall &&
            pattern_summary_value.kind == PATTERN_CONSTRUCTOR
        ) {
            int64_t open = skip_trivia(
                source,
                token_end(source, pattern_start)
            );
            int64_t field = skip_trivia(source, token_end(source, open));
            if (!token_equal(source, field, "_")) payload_name_start = field;
        }
        free(pattern);

        int64_t arrow = skip_trivia(source, pattern_summary_value.end);
        bool guarded = false;
        int64_t guard_start = -1;
        int64_t guard_end = -1;
        if (arrow < end && token_equal(source, arrow, "if")) {
            guarded = true;
            guard_start = skip_trivia(source, token_end(source, arrow));
            guard_end = condition_end(source, guard_start);
            arrow = skip_trivia(source, guard_end);
        }
        int64_t arm_open = skip_trivia(source, token_end(source, arrow));
        int64_t arm_start = skip_trivia(source, token_end(source, arm_open));
        int64_t arm_end = -1;
        if (value_control(source, arm_start)) {
            char *arm_result = parse_value_control(
                source,
                hir,
                arm_start,
                &arm_end
            );
            if (strncmp(arm_result, "error[", 6) == 0) {
                free(dispatch.data);
                return arm_result;
            }
            free(arm_result);
        } else {
            arm_end = expression_end(source, arm_start);
        }
        int64_t arm_close = skip_trivia(source, arm_end);

        Buffer pattern_condition;
        buffer_init(&pattern_condition);
        if (catchall) {
            buffer_append(&pattern_condition, "true");
        } else {
            buffer_format(
                &pattern_condition,
                "kofun_match_value.tag == INT64_C(%" PRId64 ")",
                tag
            );
        }
        /*
         * Declared before the guard, exactly as statement position declares
         * it, so `Ready(value) if value > 5 => { value }` reads one local in
         * the guard and in the result expression.  It is a copy of the matched
         * payload, so producing it duplicates no owned value.
         */
        Buffer payload_declaration;
        buffer_init(&payload_declaration);
        if (payload_name_start >= 0) {
            char *payload_id = hir_definition_id_at(hir, payload_name_start);
            if (payload_id[0] == '\0') {
                free(payload_id);
                free(payload_declaration.data);
                free(pattern_condition.data);
                free(dispatch.data);
                return lower_error(
                    "E2S32",
                    "constructor payload binding is unresolved",
                    payload_name_start
                );
            }
            buffer_format(
                &payload_declaration,
                "            int64_t k_b%s = "
                "kofun_match_value.payload;\n"
                "            (void)k_b%s;\n",
                payload_id,
                payload_id
            );
            free(payload_id);
        } else if (catchall_name_start >= 0) {
            char *catchall_id = hir_definition_id_at(
                hir,
                catchall_name_start
            );
            if (catchall_id[0] == '\0') {
                free(catchall_id);
                free(payload_declaration.data);
                free(pattern_condition.data);
                free(dispatch.data);
                return lower_error(
                    "E2S32",
                    "enum catch-all binding is unresolved",
                    catchall_name_start
                );
            }
            buffer_format(
                &payload_declaration,
                "            KofunEnumValue k_b%s = "
                "kofun_match_value;\n"
                "            (void)k_b%s;\n",
                catchall_id,
                catchall_id
            );
            free(catchall_id);
        }
        char *arm_body = emit_value_into(
            source,
            hir,
            arm_start,
            arm_end,
            target,
            failure_result
        );
        if (strncmp(arm_body, "error[", 6) == 0) {
            free(payload_declaration.data);
            free(pattern_condition.data);
            free(dispatch.data);
            return arm_body;
        }
        if (guarded) {
            char *guard = emit_condition_into(
                source,
                hir,
                guard_start,
                guard_end,
                "kofun_match_guard",
                failure_result,
                "            "
            );
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "%s"
                "            if (kofun_match_guard) {\n"
                "%s"
                "                kofun_match_selected = true;\n"
                "            }\n"
                "        }\n",
                pattern_condition.data,
                payload_declaration.data,
                guard,
                arm_body
            );
            free(guard);
        } else {
            buffer_format(
                &dispatch,
                "        if (!kofun_match_selected && %s) {\n"
                "%s"
                "%s"
                "            kofun_match_selected = true;\n"
                "        }\n",
                pattern_condition.data,
                payload_declaration.data,
                arm_body
            );
        }
        free(arm_body);
        free(payload_declaration.data);
        free(pattern_condition.data);

        arm_cursor = skip_trivia(source, token_end(source, arm_close));
        if (arm_cursor < end && token_equal(source, arm_cursor, ",")) {
            arm_cursor = skip_trivia(
                source,
                token_end(source, arm_cursor)
            );
        }
    }
    char *binding_id = hir_use_binding_id(hir, value_start);
    Buffer emitted;
    buffer_init(&emitted);
    buffer_format(
        &emitted,
        "    {\n"
        "        KofunEnumValue kofun_match_value = k_b%s;\n"
        "        (void)kofun_match_value;\n"
        "        bool kofun_match_selected = false;\n"
        "%s"
        "    }\n",
        binding_id,
        dispatch.data
    );
    free(binding_id);
    free(dispatch.data);
    return emitted.data;
}

static char *assignment_error(
    const char *message,
    const char *name,
    int64_t cursor,
    const char *hint
) {
    Buffer error;
    buffer_init(&error);
    buffer_format(
        &error,
        "error[E2S22]: %s `%s` at byte %" PRId64 "; %s",
        message,
        name,
        cursor,
        hint
    );
    stage2_diagnostic_set(
        "E2S22",
        cursor,
        cursor,
        true,
        error.data
    );
    return error.data;
}

static char *lower_match_error(
    Buffer *emitted,
    Buffer *dispatch,
    const char *code,
    const char *message,
    int64_t cursor
) {
    free(dispatch->data);
    free(emitted->data);
    return lower_error(code, message, cursor);
}

/*
 * Lower one labelled record construction into a zeroed declaration followed
 * by declaration-safe field assignments in the exact written order.  C does
 * not promise a portable evaluation order for compound-literal initializers;
 * spelling the assignments separately preserves the records-v1 contract.
 */
static char *lower_record_binding(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t value_start,
    const char *record_type,
    const char *binding_id,
    int64_t *value_end
) {
    int64_t length = (int64_t)strlen(source);
    if (
        value_start >= length ||
        strcmp(token_kind(source, value_start), "identifier") != 0
    ) {
        return lower_error(
            "E2S32",
            "nominal record initializer must name its record type",
            value_start
        );
    }
    char *constructor = annotation_type_text(source, value_start);
    if (strcmp(constructor, record_type) != 0) {
        Buffer message;
        buffer_init(&message);
        buffer_format(
            &message,
            "record constructor `%s` does not construct `%s`",
            constructor,
            record_type
        );
        free(constructor);
        char *error = lower_error("E2S32", message.data, value_start);
        free(message.data);
        return error;
    }
    free(constructor);
    int64_t open = skip_trivia(
        source,
        annotation_type_end(source, value_start)
    );
    if (open >= length || !token_equal(source, open, "(")) {
        return lower_error(
            "E2S32",
            "nominal record construction requires labelled fields",
            value_start
        );
    }
    int64_t close = balanced_end(source, open, "(", ")");
    if (close < 0) {
        return lower_error(
            "E2S32",
            "unterminated nominal record construction",
            open
        );
    }
    char *c_type = record_c_type_name(record_type);
    Buffer emitted;
    Buffer covered;
    buffer_init(&emitted);
    buffer_init(&covered);
    buffer_append(&covered, "|");
    buffer_format(
        &emitted,
        "    %s k_b%s = {0};\n",
        c_type,
        binding_id
    );
    free(c_type);
    int64_t cursor = skip_trivia(source, token_end(source, open));
    while (cursor < close && !token_equal(source, cursor, ")")) {
        if (strcmp(token_kind(source, cursor), "identifier") != 0) {
            free(covered.data);
            free(emitted.data);
            return lower_error(
                "E2S32",
                "expected nominal record field label",
                cursor
            );
        }
        char *field = token_copy(source, cursor);
        int64_t field_index = record_field_index(
            source,
            record_type,
            field
        );
        if (field_index < 0) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "record `%s` has no field `%s`",
                record_type,
                field
            );
            free(field);
            free(covered.data);
            free(emitted.data);
            char *error = lower_error("E2S32", message.data, cursor);
            free(message.data);
            return error;
        }
        if (enum_name_covered(covered.data, field)) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "record field `%s` is initialized more than once",
                field
            );
            free(field);
            free(covered.data);
            free(emitted.data);
            char *error = lower_error("E2S32", message.data, cursor);
            free(message.data);
            return error;
        }
        buffer_append(&covered, field);
        buffer_append(&covered, "|");
        int64_t colon = skip_trivia(source, token_end(source, cursor));
        if (!token_equal(source, colon, ":")) {
            free(field);
            free(covered.data);
            free(emitted.data);
            return lower_error(
                "E2S32",
                "record construction requires `field: value`",
                cursor
            );
        }
        int64_t value = skip_trivia(source, token_end(source, colon));
        char *expected = record_field_text(
            source,
            record_type,
            field_index,
            true
        );
        int64_t end =
            token_equal(source, value, "true") ||
            token_equal(source, value, "false")
                ? token_end(source, value)
                : expression_end(source, value);
        if (end < 0) {
            free(expected);
            free(field);
            free(covered.data);
            free(emitted.data);
            return lower_error(
                "E2S32",
                "invalid nominal record field value",
                value
            );
        }
        char *actual = initializer_type(
            source,
            hir,
            function_open,
            value
        );
        if (strcmp(actual, expected) != 0) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "record field `%s` expects %s, got %s",
                field,
                expected,
                actual
            );
            free(actual);
            free(expected);
            free(field);
            free(covered.data);
            free(emitted.data);
            char *error = lower_error("E2S32", message.data, value);
            free(message.data);
            return error;
        }
        free(actual);
        char *field_value =
            token_equal(source, value, "true") ||
            token_equal(source, value, "false")
                ? token_copy(source, value)
                : emit_expression(source, hir, value, end);
        char *c_field = record_c_field_name(field);
        buffer_format(
            &emitted,
            "    k_b%s.%s = %s;\n",
            binding_id,
            c_field,
            field_value
        );
        free(c_field);
        free(field_value);
        free(expected);
        free(field);
        int64_t separator = skip_trivia(source, end);
        if (separator < close && token_equal(source, separator, ",")) {
            cursor = skip_trivia(source, token_end(source, separator));
        } else if (separator == close || token_equal(source, separator, ")")) {
            cursor = separator;
        } else {
            free(covered.data);
            free(emitted.data);
            return lower_error(
                "E2S32",
                "expected `,` between nominal record fields",
                separator
            );
        }
    }
    int64_t fields = record_field_count(source, record_type);
    for (int64_t index = 0; index < fields; ++index) {
        char *field = record_field_text(
            source,
            record_type,
            index,
            false
        );
        bool present = enum_name_covered(covered.data, field);
        if (!present) {
            Buffer message;
            buffer_init(&message);
            buffer_format(
                &message,
                "record construction is missing field `%s`",
                field
            );
            free(field);
            free(covered.data);
            free(emitted.data);
            char *error = lower_error("E2S32", message.data, value_start);
            free(message.data);
            return error;
        }
        free(field);
    }
    free(covered.data);
    *value_end = close;
    return emitted.data;
}

static char *lower_body(
    const char *source,
    const char *hir,
    int64_t open,
    bool is_main,
    bool append_default,
    int64_t function_open
) {
    int64_t length = source_length(source);
    Buffer emitted;
    buffer_init(&emitted);
    if (open == function_open) {
        /* Prologue order is part of the emitted bytes and must match the
         * Kofun authority exactly: optional coalescing, then labelled
         * slots, then direct List[Int] slots. A function containing both
         * call shapes would otherwise compile to different C under the two
         * surfaces — a byte-parity failure the fixed-point gate exists to
         * refuse. */
        char *temporaries = emit_optional_int_coalescing_temporaries(
            source,
            function_open
        );
        buffer_append(&emitted, temporaries);
        free(temporaries);
        temporaries = emit_labelled_call_temporaries(
            source,
            hir,
            function_open
        );
        buffer_append(&emitted, temporaries);
        free(temporaries);
        temporaries = emit_direct_list_int_call_temporaries(
            source,
            hir,
            function_open
        );
        buffer_append(&emitted, temporaries);
        free(temporaries);
    }
    int64_t cursor = skip_trivia(source, token_end(source, open));
    bool returned = false;
    char *body_result_type = function_return_type_containing(
        source,
        function_open
    );
    bool returns_enum =
        enum_constructor_count(source, body_result_type) >= 0;
    bool returns_record =
        record_declaration_start(source, body_result_type) >= 0;
    bool returns_optional_int =
        optional_int_result_containing(source, function_open);
    bool returns_text = strcmp(body_result_type, "Text") == 0;
    bool returns_list_int = strcmp(body_result_type, "List[Int]") == 0;
    char failure_record[512] = "";
    if (returns_record) {
        char *c_type = record_c_type_name(body_result_type);
        snprintf(
            failure_record,
            sizeof failure_record,
            "((%s){0})",
            c_type
        );
        free(c_type);
    }
    free(body_result_type);
    const char *failure_result =
        is_main ?
            "1" :
            (
                returns_enum ?
                    "KOFUN_ENUM_ZERO" :
                    (returns_record ?
                         failure_record :
                         (returns_optional_int ?
                              "KOFUN_OPTIONAL_INT_NONE" :
                              /* A failed Text result is the empty string
                               * rather than NULL, so every consumer in the
                               * bounded profile still receives a readable
                               * value. */
                              (returns_text ? "\"\"" :
                               (returns_list_int ?
                                    "KOFUN_LIST_INT_ZERO" : "0"))))
            );
    while (cursor < length && !token_equal(source, cursor, "}")) {
        if (returned) {
            free(emitted.data);
            return lower_error("E2S14", "statement follows `return`", cursor);
        }
        /* See sh_parse_primary: refuse `par` before the dispatch below can
         * read the scope token as an ordinary binding and blame it instead. */
        if (token_equal(source, cursor, "par")) {
            free(emitted.data);
            return lower_error(
                "E2S154",
                "scoped parallelism `par` is specified but not implemented",
                cursor
            );
        }
        if (move_assertion_head(source, cursor)) {
            /*
             * #572: the compile-time move assertion. validate_move_assertions
             * already proved it or failed the compile, so lowering erases the
             * statement entirely — no C is emitted and the argument is never
             * evaluated. Zero runtime footprint is the assertion's contract:
             * removing the line may change diagnostics, never behavior.
             */
            int64_t dot = skip_trivia(source, token_end(source, cursor));
            int64_t member = skip_trivia(source, token_end(source, dot));
            int64_t open_paren = skip_trivia(source, token_end(source, member));
            int64_t close_end = open_paren < length ?
                balanced_end(source, open_paren, "(", ")") : -1;
            if (close_end < 0) {
                free(emitted.data);
                return lower_error(
                    "E2S146",
                    "unstable `compiler.ensure_move` takes exactly one "
                    "local binding or parameter name",
                    cursor
                );
            }
            cursor = skip_trivia(source, close_end);
            continue;
        }
        if (move_statement_head(source, cursor)) {
            /*
             * #946: the whole-binding move statement. `validate_move_uses` has
             * already refused every use that outlives it, so nothing is left
             * to check here and nothing is left to run: this slice's values
             * are Int/Bool nominal records, which have no destructor and no
             * drop, so a move is a fact about names rather than an operation.
             *
             * The binding is still spelled once, as a cast to void. A `let`
             * that is constructed and then only moved would otherwise be set
             * and never read, and the gates build the emitted C with
             * `-Wall -Wextra -Werror`. Without this line the move statement
             * would compile the program that contains it and fail the one
             * beside it, which is not a boundary a user could predict.
             */
            int64_t moved = skip_trivia(source, token_end(source, cursor));
            char *binding_id = hir_use_binding_id(hir, moved);
            if (binding_id[0] != '\0') {
                buffer_format(&emitted, "    (void)k_b%s;\n", binding_id);
            }
            free(binding_id);
            cursor = skip_trivia(source, token_end(source, moved));
            continue;
        }
        if (token_equal(source, cursor, "let")) {
            cursor = skip_trivia(source, token_end(source, cursor));
            bool mutable = false;
            if (cursor < length && token_equal(source, cursor, "mut")) {
                mutable = true;
                cursor = skip_trivia(source, token_end(source, cursor));
            }
            if (
                cursor >= length ||
                strcmp(token_kind(source, cursor), "identifier") != 0
            ) {
                free(emitted.data);
                return lower_error("E2S11", "expected binding name", cursor);
            }
            char *name = token_copy(source, cursor);
            char *binding_id = hir_definition_id_at(hir, cursor);
            char *enum_type = NULL;
            char *record_type = NULL;
            bool optional_int = false;
            bool list_int = false;
            cursor = skip_trivia(source, token_end(source, cursor));
            if (cursor < length && token_equal(source, cursor, ":")) {
                cursor = skip_trivia(source, token_end(source, cursor));
                if (
                    cursor >= length ||
                    strcmp(token_kind(source, cursor), "identifier") != 0
                ) {
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S11",
                        "expected Core binding type",
                        cursor
                    );
                }
                /* #924: `Int?` is checked before the single-token types,
                 * because its first token is exactly `Int`. */
                int64_t optional_end = optional_int_type_end(source, cursor);
                if (optional_end >= 0) {
                    optional_int = true;
                    cursor = skip_trivia(source, optional_end);
                    if (cursor >= length || !token_equal(source, cursor, "=")) {
                        free(binding_id);
                        free(name);
                        free(emitted.data);
                        return lower_error("E2S11", "expected `=`", cursor);
                    }
                }
                /* #916: an annotated local records the annotation's full
                 * identity, so `let kept: Fixed[2]` is not flattened to
                 * `Fixed`. */
                int64_t list_end = optional_int
                    ? -1
                    : list_int_type_end(source, cursor);
                char *declared_type = optional_int
                    ? owned_text("Int")
                    : (list_end >= 0
                        ? owned_text("List[Int]")
                        : annotation_type_text(source, cursor));
                if (
                    !optional_int &&
                    strcmp(declared_type, "List[Int]") == 0
                ) {
                    list_int = true;
                }
                if (
                    !optional_int && !list_int &&
                    strcmp(declared_type, "Int") != 0
                ) {
                    if (
                        strcmp(declared_type, "Text") == 0 ||
                        strcmp(declared_type, "Decimal") == 0 ||
                        strcmp(declared_type, "Float") == 0 ||
                        strcmp(declared_type, "DecimalResult") == 0
                    ) {
                        free(declared_type);
                    } else if (
                        enum_constructor_count(source, declared_type) >= 0
                    ) {
                        enum_type = declared_type;
                    } else if (
                        record_declaration_start(source, declared_type) >= 0
                    ) {
                        record_type = declared_type;
                    } else {
                        Buffer message;
                        buffer_init(&message);
                        buffer_format(
                            &message,
                            "unknown supported aggregate type `%s`",
                            declared_type
                        );
                        free(declared_type);
                        free(binding_id);
                        free(name);
                        free(emitted.data);
                        char *error = lower_error(
                            "E2S32",
                            message.data,
                            cursor
                        );
                        free(message.data);
                        return error;
                    }
                } else {
                    free(declared_type);
                }
                if (!optional_int) {
                    cursor = skip_trivia(
                        source,
                        list_end >= 0
                            ? list_end
                            : annotation_type_end(source, cursor)
                    );
                }
            }
            if (cursor >= length || !token_equal(source, cursor, "=")) {
                free(record_type);
                free(enum_type);
                free(binding_id);
                free(name);
                free(emitted.data);
                return lower_error("E2S11", "expected `=`", cursor);
            }
            int64_t value_start = skip_trivia(source, token_end(source, cursor));
            if (optional_int) {
                /*
                 * #924: the four initializer forms this slice constructs, and
                 * nothing else. `null` is the absent value; an `Int` is the
                 * present one under #70's injection rule; an `Int?` binding
                 * or a call declared `Int?` carries an existing value with
                 * its tag intact. There is no form here that turns an
                 * `Int?` into an `Int`.
                 */
                if (mutable) {
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S147",
                        "mutable `Int?` bindings are outside this lowering "
                        "slice; declare `let` and construct a new value "
                        "instead",
                        value_start
                    );
                }
                int64_t value_end = expression_end(source, value_start);
                if (value_start >= length || value_end < 0) {
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S147",
                        "an `Int?` binding is initialized by `null`, an "
                        "`Int`, another `Int?` binding, or a call returning "
                        "`Int?`",
                        value_start
                    );
                }
                char *value = optional_int_value(
                    source,
                    hir,
                    value_start,
                    value_end
                );
                if (strncmp(value, "error[", 6) == 0) {
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    " OPTIONAL_INT_C_TYPE " k_b%s = %s;\n"
                    "    if (kofun_failed) return %s;\n",
                    binding_id,
                    value,
                    failure_result
                );
                free(value);
                free(binding_id);
                free(name);
                cursor = skip_trivia(source, value_end);
                continue;
            }
            if (record_type != NULL) {
                if (mutable) {
                    free(record_type);
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S32",
                        "nominal record bindings are immutable in this slice",
                        value_start
                    );
                }
                if (
                    value_start < length &&
                    strcmp(token_kind(source, value_start), "identifier") == 0
                ) {
                    char *initializer_name = annotation_type_text(
                        source,
                        value_start
                    );
                    bool construction =
                        strcmp(initializer_name, record_type) == 0;
                    free(initializer_name);
                    if (!construction) {
                        int64_t value_end = expression_end(
                            source,
                            value_start
                        );
                        char *value = emit_record_value(
                            source,
                            hir,
                            value_start,
                            value_end,
                            record_type
                        );
                        if (strncmp(value, "error[", 6) == 0) {
                            free(record_type);
                            free(enum_type);
                            free(binding_id);
                            free(name);
                            free(emitted.data);
                            return value;
                        }
                        char *c_type = record_c_type_name(record_type);
                        buffer_format(
                            &emitted,
                            "    %s k_b%s = %s;\n"
                            "    if (kofun_failed) return %s;\n",
                            c_type,
                            binding_id,
                            value,
                            failure_result
                        );
                        free(c_type);
                        free(value);
                        free(record_type);
                        free(enum_type);
                        free(binding_id);
                        free(name);
                        cursor = skip_trivia(source, value_end);
                        continue;
                    }
                }
                int64_t value_end = -1;
                char *declaration = lower_record_binding(
                    source,
                    hir,
                    function_open,
                    value_start,
                    record_type,
                    binding_id,
                    &value_end
                );
                if (strncmp(declaration, "error[", 6) == 0) {
                    free(record_type);
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return declaration;
                }
                buffer_append(&emitted, declaration);
                free(declaration);
                free(record_type);
                free(enum_type);
                free(binding_id);
                free(name);
                cursor = skip_trivia(source, value_end);
                continue;
            }
            if (enum_type != NULL) {
                if (mutable) {
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S32",
                        "concrete enum bindings are immutable in this Core slice",
                        value_start
                    );
                }
                if (
                    value_start < length &&
                    strcmp(token_kind(source, value_start), "identifier") == 0
                ) {
                    char *initializer_name = token_copy(
                        source,
                        value_start
                    );
                    int64_t initializer_open = skip_trivia(
                        source,
                        token_end(source, value_start)
                    );
                    char *initializer_result = function_return_type(
                        source,
                        initializer_name
                    );
                    bool enum_call =
                        initializer_open < length &&
                        token_equal(source, initializer_open, "(") &&
                        strcmp(initializer_result, enum_type) == 0;
                    free(initializer_result);
                    free(initializer_name);
                    if (enum_call) {
                        int64_t value_end = expression_end(
                            source,
                            value_start
                        );
                        char *value = emit_enum_value(
                            source,
                            hir,
                            value_start,
                            value_end,
                            enum_type
                        );
                        if (strncmp(value, "error[", 6) == 0) {
                            free(enum_type);
                            free(binding_id);
                            free(name);
                            free(emitted.data);
                            return value;
                        }
                        buffer_format(
                            &emitted,
                            "    KofunEnumValue k_b%s = %s;\n"
                            "    if (kofun_failed) return %s;\n",
                            binding_id,
                            value,
                            failure_result
                        );
                        free(value);
                        free(enum_type);
                        free(binding_id);
                        free(name);
                        cursor = skip_trivia(source, value_end);
                        continue;
                    }
                }
                if (
                    value_start >= length ||
                    strcmp(token_kind(source, value_start), "identifier") != 0
                ) {
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S32",
                        "concrete enum initializer must name a constructor",
                        value_start
                    );
                }
                char *constructor = token_copy(source, value_start);
                int64_t tag = enum_constructor_index(
                    source,
                    enum_type,
                    constructor
                );
                if (tag < 0) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "constructor `%s` does not belong to enum `%s`",
                        constructor,
                        enum_type
                    );
                    free(constructor);
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    char *error = lower_error(
                        "E2S32",
                        message.data,
                        value_start
                    );
                    free(message.data);
                    return error;
                }
                int64_t arity = enum_constructor_payload_arity(
                    source,
                    enum_type,
                    constructor
                );
                int64_t after_constructor = skip_trivia(
                    source,
                    token_end(source, value_start)
                );
                bool applied = after_constructor < length &&
                               token_equal(source, after_constructor, "(");
                if (arity < 0) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "constructor `%s` of enum `%s` declares a payload "
                        "outside this Core slice; one `Int` field is "
                        "supported",
                        constructor,
                        enum_type
                    );
                    free(constructor);
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    char *error = lower_error(
                        "E2S32",
                        message.data,
                        value_start
                    );
                    free(message.data);
                    return error;
                }
                if (applied != (arity == 1)) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        arity == 1 ?
                            "constructor `%s` takes one `Int` payload" :
                            "constructor `%s` takes no payload",
                        constructor
                    );
                    free(constructor);
                    free(enum_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    char *error = lower_error(
                        "E2S32",
                        message.data,
                        applied ? after_constructor : value_start
                    );
                    free(message.data);
                    return error;
                }
                /*
                 * Every concrete enum binding holds a tag and one payload
                 * slot, whether or not its constructor carries a field.  A
                 * match arm can then read the payload without first proving
                 * which constructor produced the value, and the two locals
                 * stay in step through every later assignment.
                 */
                int64_t constructor_end = token_end(source, value_start);
                if (arity == 1) {
                    int64_t payload_start = skip_trivia(
                        source,
                        token_end(source, after_constructor)
                    );
                    int64_t payload_end = expression_end(
                        source,
                        payload_start
                    );
                    int64_t close = payload_end < 0 ?
                        -1 :
                        skip_trivia(source, payload_end);
                    if (
                        payload_end < 0 ||
                        close >= length ||
                        !token_equal(source, close, ")")
                    ) {
                        free(constructor);
                        free(enum_type);
                        free(binding_id);
                        free(name);
                        free(emitted.data);
                        return lower_error(
                            "E2S32",
                            "concrete enum payload must be one Int expression",
                            payload_start
                        );
                    }
                    char *payload = emit_expression(
                        source,
                        hir,
                        payload_start,
                        payload_end
                    );
                    buffer_format(
                        &emitted,
                        "    KofunEnumValue k_b%s = "
                        "{INT64_C(%" PRId64 "), %s};\n"
                        "    if (kofun_failed) return %s;\n",
                        binding_id,
                        tag,
                        payload,
                        failure_result
                    );
                    free(payload);
                    constructor_end = token_end(source, close);
                } else {
                    buffer_format(
                        &emitted,
                        "    KofunEnumValue k_b%s = "
                        "{INT64_C(%" PRId64 "), INT64_C(0)};\n",
                        binding_id,
                        tag
                    );
                }
                free(constructor);
                free(enum_type);
                free(name);
                free(binding_id);
                cursor = skip_trivia(source, constructor_end);
                continue;
            }
            /*
             * A lambda binding names a lifted top-level function rather than
             * holding an `int64_t`, so this statement emits nothing. Without
             * this the initializer reaches the Int expression grammar and is
             * rejected as `E2S12`, which is what #703 measured.
             */
            int64_t lambda_open = lambda_initializer_open(source, value_start);
            if (lambda_open >= 0) {
                free(name);
                free(binding_id);
                cursor = skip_trivia(
                    source,
                    lambda_parameters_end(source, -1, lambda_open)
                );
                continue;
            }
            if (value_control(source, value_start)) {
                int64_t value_end = -1;
                char *result = parse_value_control(
                    source,
                    hir,
                    value_start,
                    &value_end
                );
                if (strncmp(result, "error[", 6) == 0) {
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return result;
                }
                free(result);
                Buffer target;
                buffer_init(&target);
                buffer_format(&target, "k_b%s", binding_id);
                char *value_body = emit_value_into(
                    source,
                    hir,
                    value_start,
                    value_end,
                    target.data,
                    failure_result
                );
                if (strncmp(value_body, "error[", 6) == 0) {
                    free(target.data);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return value_body;
                }
                buffer_format(
                    &emitted,
                    "    int64_t k_b%s = INT64_C(0);\n"
                    "%s",
                    binding_id,
                    value_body
                );
                free(value_body);
                free(target.data);
                free(name);
                free(binding_id);
                cursor = skip_trivia(source, value_end);
                continue;
            }
            int64_t value_end = expression_end(source, value_start);
            if (value_end < 0) {
                free(binding_id);
                free(name);
                free(emitted.data);
                return lower_error("E2S12", "invalid Int expression", value_start);
            }
            char *value = emit_expression(source, hir, value_start, value_end);
            /* A rejected initializer became the C initializer text. */
            if (strncmp(value, "error[", 6) == 0) {
                free(binding_id);
                free(name);
                free(emitted.data);
                return value;
            }
            char *binding_type = hir_binding_field(hir, binding_id, 5);
            char *actual_type = initializer_type(
                source,
                hir,
                function_open,
                value_start
            );
            if (strcmp(actual_type, binding_type) != 0) {
                free(actual_type);
                free(binding_type);
                free(value);
                free(binding_id);
                free(name);
                free(emitted.data);
                return lower_error(
                    "E2S15",
                    "initializer type mismatch",
                    value_start
                );
            }
            free(actual_type);
            if (strcmp(binding_type, "List[Int]") == 0) {
                free(value);
                value = emit_list_int_value(
                    source,
                    hir,
                    value_start,
                    value_end,
                    true
                );
                if (strncmp(value, "error[", 6) == 0) {
                    free(binding_type);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return value;
                }
            }
            const char *c_type = "int64_t";
            if (strcmp(binding_type, "Decimal") == 0) {
                c_type = "KofunDecimal *";
            } else if (strcmp(binding_type, "Float") == 0) {
                c_type = "double";
            } else if (strcmp(binding_type, "DecimalResult") == 0) {
                c_type = "KofunDecimalResult *";
            } else if (strcmp(binding_type, "Text") == 0) {
                c_type = "const char *";
            } else if (strcmp(binding_type, "List[Int]") == 0) {
                c_type = "KofunIntListValue";
            }
            if (mutable && strcmp(binding_type, "List[Int]") == 0) {
                free(binding_type);
                free(value);
                free(binding_id);
                free(name);
                free(emitted.data);
                return lower_error(
                    "E2S157",
                    "mutable List[Int] bindings are outside this lowering slice",
                    value_start
                );
            }
            if (mutable && strcmp(binding_type, "Int") != 0) {
                free(binding_type);
                free(value);
                free(binding_id);
                free(name);
                free(emitted.data);
                return lower_error(
                    "E2S144",
                    "mutable Decimal, DecimalResult, Float, and Text bindings are "
                    "outside this lowering slice",
                    value_start
                );
            }
            buffer_format(
                &emitted,
                "    %s k_b%s = %s;\n"
                "    if (kofun_failed) return %s;\n",
                c_type,
                binding_id,
                value,
                failure_result
            );
            free(binding_type);
            free(value);
            free(name);
            free(binding_id);
            cursor = skip_trivia(source, value_end);
        } else if (token_equal(source, cursor, "print")) {
            int64_t call_open = skip_trivia(source, token_end(source, cursor));
            if (call_open >= length || !token_equal(source, call_open, "(")) {
                free(emitted.data);
                return lower_error("E2S13", "expected `print(`", cursor);
            }
            int64_t value_start = skip_trivia(source, token_end(source, call_open));
            if (value_control(source, value_start)) {
                int64_t value_end = -1;
                char *result = parse_value_control(
                    source,
                    hir,
                    value_start,
                    &value_end
                );
                if (strncmp(result, "error[", 6) == 0) {
                    free(emitted.data);
                    return result;
                }
                free(result);
                int64_t call_close = skip_trivia(source, value_end);
                if (
                    call_close >= length ||
                    !token_equal(source, call_close, ")")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S13",
                        "expected `)`",
                        call_close
                    );
                }
                char *value_body = emit_value_into(
                    source,
                    hir,
                    value_start,
                    value_end,
                    "kofun_value",
                    failure_result
                );
                if (strncmp(value_body, "error[", 6) == 0) {
                    free(emitted.data);
                    return value_body;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        int64_t kofun_value = INT64_C(0);\n"
                    "%s"
                    "        printf(\"%%\" PRId64 \"\\n\", kofun_value);\n"
                    "    }\n",
                    value_body
                );
                free(value_body);
                cursor = skip_trivia(
                    source,
                    token_end(source, call_close)
                );
                continue;
            }
            int64_t value_end = expression_end(source, value_start);
            if (value_end < 0) {
                free(emitted.data);
                return lower_error("E2S12", "invalid Int expression", value_start);
            }
            int64_t call_close = skip_trivia(source, value_end);
            if (call_close >= length || !token_equal(source, call_close, ")")) {
                free(emitted.data);
                return lower_error("E2S13", "expected `)`", call_close);
            }
            char *value = emit_expression(source, hir, value_start, value_end);
            /* `print` formatted this straight into the emitted C without the
             * `error[` check every other statement performs, so a rejected
             * argument reached the output instead of the caller. */
            if (strncmp(value, "error[", 6) == 0) {
                free(emitted.data);
                return value;
            }
            char *value_type = initializer_type(
                source,
                hir,
                function_open,
                value_start
            );
            if (strcmp(value_type, "Decimal") == 0) {
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        KofunDecimal *kofun_value = %s;\n"
                    "        char *kofun_text = "
                    "kofun_decimal_to_canonical_text(kofun_value);\n"
                    "        printf(\"%%s\\n\", kofun_text);\n"
                    "        free(kofun_text);\n"
                    "    }\n",
                    value
                );
            } else if (strcmp(value_type, "Float") == 0) {
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        double kofun_value = %s;\n"
                    "        printf(\"%%.17g\\n\", kofun_value);\n"
                    "    }\n",
                    value
                );
            } else if (strcmp(value_type, "DecimalResult") == 0) {
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        KofunDecimalResult *kofun_value = %s;\n"
                    "        printf(\"%%s\\n\", "
                    "kofun_decimal_value_division_name(kofun_value));\n"
                    "    }\n",
                    value
                );
            } else if (strcmp(value_type, "Text") == 0) {
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        const char *kofun_value = %s;\n"
                    "        if (kofun_failed) return %s;\n"
                    "        printf(\"%%s\\n\", kofun_value);\n"
                    "    }\n",
                    value,
                    failure_result
                );
            } else {
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        int64_t kofun_value = %s;\n"
                    "        if (kofun_failed) return %s;\n"
                    "        printf(\"%%\" PRId64 \"\\n\", kofun_value);\n"
                    "    }\n",
                    value,
                    failure_result
                );
            }
            free(value_type);
            free(value);
            cursor = skip_trivia(source, token_end(source, call_close));
        } else if (token_equal(source, cursor, "if") &&
                   final_result_if(
                       source,
                       cursor,
                       is_main,
                       append_default,
                       returns_enum,
                       returns_record
                   )) {
            /*
             * The final `if` of a result-carrying function is its result, and
             * its type is the join of the two branch types (#550). The join and
             * the lowering are the ones `return if ... { } else { }` already
             * uses, so this position gains no rules of its own — it reaches the
             * same validator and the same emitter.
             *
             * Every path has to produce a value, so an `if` without `else` is
             * refused here rather than falling through to the statement form,
             * where it would have become a body that reaches its closing brace.
             */
            if (!if_has_else(source, cursor)) {
                free(emitted.data);
                return lower_error(
                    "E2S27",
                    "a final `if` needs an `else`; "
                    "its false path yields no Int",
                    cursor
                );
            }
            ValueIfParts final_parts;
            char *result = parse_value_if(source, hir, cursor, &final_parts);
            if (strncmp(result, "error[", 6) == 0) {
                free(emitted.data);
                return result;
            }
            free(result);
            int64_t branch_end = final_parts.end;
            char *value_body = emit_value_into(
                source,
                hir,
                cursor,
                branch_end,
                "kofun_result",
                failure_result
            );
            if (strncmp(value_body, "error[", 6) == 0) {
                free(emitted.data);
                return value_body;
            }
            buffer_append(
                &emitted,
                "    {\n"
                "        int64_t kofun_result = INT64_C(0);\n"
            );
            buffer_append(&emitted, value_body);
            buffer_append(
                &emitted,
                "        return kofun_result;\n"
                "    }\n"
            );
            free(value_body);
            returned = true;
            cursor = skip_trivia(source, branch_end);
        } else if (token_equal(source, cursor, "if")) {
            int64_t statement_start = cursor;
            int64_t condition_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t condition_close = condition_end(source, condition_start);
            if (condition_close < 0) {
                free(emitted.data);
                return lower_error(
                    "E2S23",
                    "if condition must be Bool or an Int comparison",
                    condition_start
                );
            }
            int64_t branch_open = skip_trivia(source, condition_close);
            if (
                branch_open >= length ||
                !token_equal(source, branch_open, "{")
            ) {
                free(emitted.data);
                return lower_error(
                    "E2S18",
                    "expected `{` after if condition",
                    branch_open
                );
            }
            int64_t branch_close = balanced_end(
                source,
                branch_open,
                "{",
                "}"
            );
            if (branch_close < 0) {
                free(emitted.data);
                return lower_error(
                    "E2S18",
                    "missing `}` after if branch",
                    branch_open
                );
            }
            char *branch_body = lower_body(
                source,
                hir,
                branch_open,
                is_main,
                false,
                function_open
            );
            if (strncmp(branch_body, "error[", 6) == 0) {
                free(emitted.data);
                return branch_body;
            }
            char *condition = emit_condition_into(
                source,
                hir,
                condition_start,
                condition_close,
                "kofun_condition",
                failure_result,
                "        "
            );
            /* A rejected condition became the statement's C prelude. */
            if (strncmp(condition, "error[", 6) == 0) {
                free(branch_body);
                free(emitted.data);
                return condition;
            }
            buffer_format(
                &emitted,
                "    {\n"
                "%s"
                "        if (kofun_condition) {\n"
                "%s"
                "        }",
                condition,
                branch_body
            );
            free(condition);
            free(branch_body);
            int64_t statement_end = token_end(source, branch_close);
            cursor = skip_trivia(source, branch_close);
            if (cursor < length && token_equal(source, cursor, "else")) {
                int64_t else_open = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                if (
                    else_open >= length ||
                    !token_equal(source, else_open, "{")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S18",
                        "expected `{` after `else`",
                        else_open
                    );
                }
                int64_t else_close = balanced_end(
                    source,
                    else_open,
                    "{",
                    "}"
                );
                if (else_close < 0) {
                    free(emitted.data);
                    return lower_error(
                        "E2S18",
                        "missing `}` after else branch",
                        else_open
                    );
                }
                char *else_body = lower_body(
                    source,
                    hir,
                    else_open,
                    is_main,
                    false,
                    function_open
                );
                if (strncmp(else_body, "error[", 6) == 0) {
                    free(emitted.data);
                    return else_body;
                }
                buffer_format(&emitted, " else {\n%s        }", else_body);
                free(else_body);
                statement_end = token_end(source, else_close);
                cursor = skip_trivia(source, else_close);
            }
            buffer_append(&emitted, "\n    }\n");
            stage2_semantic_observe(
                "control|if|%" PRId64 "|%" PRId64 "|Unit|%" PRId64
                "|%" PRId64 "\n",
                statement_start,
                statement_end,
                condition_start,
                condition_close
            );
        } else if (token_equal(source, cursor, "match")) {
            int64_t match_start = cursor;
            int64_t value_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t direct_end = skip_trivia(
                source,
                token_end(source, value_start)
            );
            if (
                strcmp(token_kind(source, value_start), "identifier") == 0 &&
                direct_end < length &&
                token_equal(source, direct_end, "{")
            ) {
                char *value_name = token_copy(source, value_start);
                char *enum_binding = hir_use_binding_id(hir, value_start);
                char *enum_type = hir_binding_field(
                    hir,
                    enum_binding,
                    5
                );
                if (
                    enum_type[0] == '\0' ||
                    strcmp(enum_type, "Int") == 0 ||
                    enum_constructor_count(source, enum_type) < 0
                ) {
                    Buffer message;
                    buffer_init(&message);
                    buffer_format(
                        &message,
                        "enum match scrutinee `%s` must be a preceding "
                        "explicitly typed enum binding",
                        value_name
                    );
                    free(enum_type);
                    free(enum_binding);
                    free(value_name);
                    free(emitted.data);
                    char *error = lower_error(
                        "E2S32",
                        message.data,
                        value_start
                    );
                    free(message.data);
                    return error;
                }
                char *match_body = lower_enum_match(
                    source,
                    hir,
                    match_start,
                    enum_type,
                    is_main,
                    function_open
                );
                free(enum_type);
                free(enum_binding);
                free(value_name);
                if (strncmp(match_body, "error[", 6) == 0) {
                    free(emitted.data);
                    return match_body;
                }
                buffer_append(&emitted, match_body);
                free(match_body);
                int64_t match_end = enum_match_end(source, match_start);
                stage2_semantic_observe(
                    "control|match|%" PRId64 "|%" PRId64
                    "|Unit|%" PRId64 "|%" PRId64 "\n",
                    match_start,
                    match_end,
                    value_start,
                    token_end(source, value_start)
                );
                cursor = skip_trivia(source, match_end);
            } else {
            int64_t value_end = condition_end(source, value_start);
            Buffer dispatch;
            buffer_init(&dispatch);
            if (value_end < 0) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S24",
                    "bounded match scrutinee must be Bool",
                    value_start
                );
            }
            int64_t arms_open = skip_trivia(source, value_end);
            if (
                arms_open >= length ||
                !token_equal(source, arms_open, "{")
            ) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S24",
                    "expected `{` after match scrutinee",
                    arms_open
                );
            }
            int64_t arm_cursor = skip_trivia(
                source,
                token_end(source, arms_open)
            );
            bool covered_true = false;
            bool covered_false = false;
            bool seen_catchall = false;
            while (
                arm_cursor < length &&
                !token_equal(source, arm_cursor, "}")
            ) {
                int64_t pattern_start = arm_cursor;
                PatternSummary pattern = pattern_summary(
                    source,
                    pattern_start
                );
                bool pattern_true = pattern.kind == PATTERN_LITERAL &&
                                    token_equal(
                                        source,
                                        pattern_start,
                                        "true"
                                    );
                bool pattern_false = pattern.kind == PATTERN_LITERAL &&
                                     token_equal(
                                         source,
                                         pattern_start,
                                         "false"
                                     );
                bool pattern_catchall =
                    pattern.kind == PATTERN_WILDCARD;
                if (seen_catchall) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S26",
                        "pattern after catch-all is unreachable",
                        pattern_start
                    );
                }
                if (pattern_true && covered_true) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S26",
                        "duplicate `true` pattern is unreachable",
                        pattern_start
                    );
                }
                if (pattern_false && covered_false) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S26",
                        "duplicate `false` pattern is unreachable",
                        pattern_start
                    );
                }
                if (
                    pattern_catchall &&
                    covered_true &&
                    covered_false
                ) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S26",
                        "catch-all pattern is unreachable",
                        pattern_start
                    );
                }
                if (
                    !pattern_true &&
                    !pattern_false &&
                    !pattern_catchall
                ) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S24",
                        "bounded Bool pattern must be `true`, `false`, or `_`",
                        pattern_start
                    );
                }
                int64_t after_pattern = skip_trivia(
                    source,
                    pattern.end
                );
                bool guarded = false;
                int64_t guard_start = -1;
                int64_t guard_end = -1;
                if (
                    after_pattern < length &&
                    token_equal(source, after_pattern, "if")
                ) {
                    guarded = true;
                    guard_start = skip_trivia(
                        source,
                        token_end(source, after_pattern)
                    );
                    guard_end = condition_end(source, guard_start);
                    if (guard_end < 0) {
                        return lower_match_error(
                            &emitted,
                            &dispatch,
                            "E2S29",
                            "match guard must be Bool or an Int comparison",
                            guard_start
                        );
                    }
                    after_pattern = skip_trivia(
                        source,
                        guard_end
                    );
                }
                if (
                    after_pattern >= length ||
                    !token_equal(source, after_pattern, "=>")
                ) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S24",
                        "expected `=>` after Bool pattern",
                        after_pattern
                    );
                }
                int64_t arm_open = skip_trivia(
                    source,
                    token_end(source, after_pattern)
                );
                if (
                    arm_open >= length ||
                    !token_equal(source, arm_open, "{")
                ) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S24",
                        "bounded Bool match arm must use a block",
                        arm_open
                    );
                }
                int64_t arm_close = balanced_end(
                    source,
                    arm_open,
                    "{",
                    "}"
                );
                if (arm_close < 0) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S24",
                        "missing `}` after match arm",
                        arm_open
                    );
                }
                char *arm_body = lower_body(
                    source,
                    hir,
                    arm_open,
                    is_main,
                    false,
                    function_open
                );
                if (strncmp(arm_body, "error[", 6) == 0) {
                    free(dispatch.data);
                    free(emitted.data);
                    return arm_body;
                }

                const char *pattern_condition = "true";
                if (pattern_true) {
                    pattern_condition = "kofun_match_value";
                } else if (pattern_false) {
                    pattern_condition = "!kofun_match_value";
                }
                if (guarded) {
                    char *guard = emit_condition_into(
                        source,
                        hir,
                        guard_start,
                        guard_end,
                        "kofun_match_guard",
                        failure_result,
                        "            "
                    );
                    buffer_format(
                        &dispatch,
                        "        if (!kofun_match_selected && %s) {\n"
                        "%s"
                        "            if (kofun_match_guard) {\n"
                        "%s"
                        "                kofun_match_selected = true;\n"
                        "            }\n"
                        "        }\n",
                        pattern_condition,
                        guard,
                        arm_body
                    );
                    free(guard);
                } else {
                    buffer_format(
                        &dispatch,
                        "        if (!kofun_match_selected && %s) {\n"
                        "%s"
                        "            kofun_match_selected = true;\n"
                        "        }\n",
                        pattern_condition,
                        arm_body
                    );
                    if (pattern_true) {
                        covered_true = true;
                    } else if (pattern_false) {
                        covered_false = true;
                    } else {
                        covered_true = true;
                        covered_false = true;
                        seen_catchall = true;
                    }
                }
                free(arm_body);
                arm_cursor = skip_trivia(source, arm_close);
                if (
                    arm_cursor < length &&
                    token_equal(source, arm_cursor, ",")
                ) {
                    arm_cursor = skip_trivia(
                        source,
                        token_end(source, arm_cursor)
                    );
                } else if (
                    arm_cursor >= length ||
                    !token_equal(source, arm_cursor, "}")
                ) {
                    return lower_match_error(
                        &emitted,
                        &dispatch,
                        "E2S24",
                        "expected `,` between match arms",
                        arm_cursor
                    );
                }
            }
            if (
                arm_cursor >= length ||
                !token_equal(source, arm_cursor, "}")
            ) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S24",
                    "missing `}` after match arms",
                    arms_open
                );
            }
            if (!covered_true && !covered_false) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S25",
                    "non-exhaustive Bool match; missing patterns `true`, `false`",
                    match_start
                );
            }
            if (!covered_true) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S25",
                    "non-exhaustive Bool match; missing pattern `true`",
                    match_start
                );
            }
            if (!covered_false) {
                return lower_match_error(
                    &emitted,
                    &dispatch,
                    "E2S25",
                    "non-exhaustive Bool match; missing pattern `false`",
                    match_start
                );
            }
            char *match_value = emit_condition_into(
                source,
                hir,
                value_start,
                value_end,
                "kofun_match_value",
                failure_result,
                "        "
            );
            buffer_format(
                &emitted,
                "    {\n"
                "%s"
                "        (void)kofun_match_value;\n"
                "        bool kofun_match_selected = false;\n"
                "%s"
                "    }\n",
                match_value,
                dispatch.data
            );
            free(match_value);
            free(dispatch.data);
            stage2_semantic_observe(
                "control|match|%" PRId64 "|%" PRId64 "|Unit|%" PRId64
                "|%" PRId64 "\n",
                match_start,
                token_end(source, arm_cursor),
                value_start,
                value_end
            );
            cursor = skip_trivia(source, token_end(source, arm_cursor));
            }
        } else if (token_equal(source, cursor, "return")) {
            int64_t value_start = skip_trivia(source, token_end(source, cursor));
            if (returns_list_int) {
                int64_t value_end = expression_end(source, value_start);
                if (
                    value_end < 0 || value_start >= length ||
                    token_equal(source, value_start, "}")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S157",
                        "List[Int] return requires one whole binding or "
                        "same-typed direct call",
                        value_start
                    );
                }
                char *value = emit_list_int_value(
                    source,
                    hir,
                    value_start,
                    value_end,
                    false
                );
                if (strncmp(value, "error[", 6) == 0) {
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        KofunIntListValue kofun_result = %s;\n"
                    "        if (kofun_failed) return KOFUN_LIST_INT_ZERO;\n"
                    "        return kofun_result;\n"
                    "    }\n",
                    value
                );
                free(value);
                cursor = skip_trivia(source, value_end);
            } else if (returns_optional_int) {
                /* #924: an `Int?` result carries the tag out of the function
                 * exactly as it was constructed. */
                int64_t value_end = expression_end(source, value_start);
                if (
                    value_end < 0 ||
                    value_start >= length ||
                    token_equal(source, value_start, "}")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S147",
                        "an `Int?` result requires one value: `null`, an "
                        "`Int`, an `Int?` binding, or a call returning "
                        "`Int?`",
                        value_start
                    );
                }
                char *value = optional_int_value(
                    source,
                    hir,
                    value_start,
                    value_end
                );
                if (strncmp(value, "error[", 6) == 0) {
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        " OPTIONAL_INT_C_TYPE " kofun_result = %s;\n"
                    "        if (kofun_failed) return "
                    "KOFUN_OPTIONAL_INT_NONE;\n"
                    "        return kofun_result;\n"
                    "    }\n",
                    value
                );
                free(value);
                cursor = skip_trivia(source, value_end);
            } else if (returns_enum) {
                int64_t value_end = expression_end(source, value_start);
                if (
                    value_end < 0 ||
                    value_start >= length ||
                    token_equal(source, value_start, "}")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "concrete enum return requires one value",
                        value_start
                    );
                }
                char *result_type = function_return_type_containing(
                    source,
                    function_open
                );
                char *value = emit_enum_value(
                    source,
                    hir,
                    value_start,
                    value_end,
                    result_type
                );
                free(result_type);
                if (strncmp(value, "error[", 6) == 0) {
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        KofunEnumValue kofun_result = %s;\n"
                    "        if (kofun_failed) return KOFUN_ENUM_ZERO;\n"
                    "        return kofun_result;\n"
                    "    }\n",
                    value
                );
                free(value);
                cursor = skip_trivia(source, value_end);
            } else if (returns_record) {
                int64_t value_end = expression_end(source, value_start);
                if (
                    value_end < 0 ||
                    value_start >= length ||
                    token_equal(source, value_start, "}")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "nominal record return requires one value",
                        value_start
                    );
                }
                char *result_type = function_return_type_containing(
                    source,
                    function_open
                );
                char *value = emit_record_value(
                    source,
                    hir,
                    value_start,
                    value_end,
                    result_type
                );
                char *c_type = record_c_type_name(result_type);
                free(result_type);
                if (strncmp(value, "error[", 6) == 0) {
                    free(c_type);
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        %s kofun_result = %s;\n"
                    "        if (kofun_failed) return %s;\n"
                    "        return kofun_result;\n"
                    "    }\n",
                    c_type,
                    value,
                    failure_result
                );
                free(c_type);
                free(value);
                cursor = skip_trivia(source, value_end);
            } else if (returns_text) {
                int64_t value_end = expression_end(source, value_start);
                if (
                    value_end < 0 ||
                    value_start >= length ||
                    token_equal(source, value_start, "}")
                ) {
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "Text return requires one value",
                        value_start
                    );
                }
                char *value = emit_expression(
                    source,
                    hir,
                    value_start,
                    value_end
                );
                if (strncmp(value, "error[", 6) == 0) {
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        const char *kofun_result = %s;\n"
                    "        if (kofun_failed) return %s;\n"
                    "        return kofun_result;\n"
                    "    }\n",
                    value,
                    failure_result
                );
                free(value);
                cursor = skip_trivia(source, value_end);
            } else if (
                value_start < length &&
                token_equal(source, value_start, "}")
            ) {
                buffer_append(&emitted, "    return 0;\n");
                cursor = value_start;
            } else if (value_control(source, value_start)) {
                int64_t value_end = -1;
                char *result = parse_value_control(
                    source,
                    hir,
                    value_start,
                    &value_end
                );
                if (strncmp(result, "error[", 6) == 0) {
                    free(emitted.data);
                    return result;
                }
                free(result);
                char *value_body = emit_value_into(
                    source,
                    hir,
                    value_start,
                    value_end,
                    "kofun_result",
                    failure_result
                );
                if (strncmp(value_body, "error[", 6) == 0) {
                    free(emitted.data);
                    return value_body;
                }
                buffer_append(
                    &emitted,
                    "    {\n"
                    "        int64_t kofun_result = INT64_C(0);\n"
                );
                buffer_append(&emitted, value_body);
                if (is_main) {
                    buffer_append(
                        &emitted,
                        "        return (int)kofun_result;\n"
                    );
                } else {
                    buffer_append(
                        &emitted,
                        "        return kofun_result;\n"
                    );
                }
                buffer_append(&emitted, "    }\n");
                free(value_body);
                cursor = skip_trivia(source, value_end);
            } else {
                int64_t value_end = expression_end(source, value_start);
                if (value_end < 0) {
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "invalid return expression",
                        value_start
                    );
                }
                char *value = emit_expression(
                    source,
                    hir,
                    value_start,
                    value_end
                );
                /* A rejected return expression became the C return value. */
                if (strncmp(value, "error[", 6) == 0) {
                    free(emitted.data);
                    return value;
                }
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        int64_t kofun_result = %s;\n"
                    "        if (kofun_failed) return %s;\n",
                    value,
                    failure_result
                );
                if (is_main) {
                    buffer_append(
                        &emitted,
                        "        return (int)kofun_result;\n"
                    );
                } else {
                    buffer_append(
                        &emitted,
                        "        return kofun_result;\n"
                    );
                }
                buffer_append(&emitted, "    }\n");
                free(value);
                cursor = skip_trivia(source, value_end);
            }
            returned = true;
        } else if (
            strcmp(token_kind(source, cursor), "identifier") == 0
        ) {
            int64_t assignment_start = cursor;
            char *name = token_copy(source, cursor);
            int64_t equals = skip_trivia(source, token_end(source, cursor));
            if (equals < length && token_equal(source, equals, "=")) {
                char *binding_id = hir_use_binding_id(
                    hir,
                    assignment_start
                );
                if (
                    binding_id[0] == '\0' ||
                    strcmp(binding_id, "-1") == 0
                ) {
                    char *error = assignment_error(
                        "unknown assignment target",
                        name,
                        assignment_start,
                        "declare it before assignment"
                    );
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return error;
                }
                char *mutability = hir_binding_field(hir, binding_id, 4);
                if (strcmp(mutability, "mutable") != 0) {
                    char *error = assignment_error(
                        "cannot assign to immutable binding",
                        name,
                        assignment_start,
                        "declare it with `let mut`"
                    );
                    free(mutability);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return error;
                }
                int64_t value_start = skip_trivia(
                    source,
                    token_end(source, equals)
                );
                if (value_control(source, value_start)) {
                    int64_t value_end = -1;
                    char *result = parse_value_control(
                        source,
                        hir,
                        value_start,
                        &value_end
                    );
                    if (strncmp(result, "error[", 6) == 0) {
                        free(mutability);
                        free(binding_id);
                        free(name);
                        free(emitted.data);
                        return result;
                    }
                    free(result);
                    char *value_body = emit_value_into(
                        source,
                        hir,
                        value_start,
                        value_end,
                        "kofun_replacement",
                        failure_result
                    );
                    if (strncmp(value_body, "error[", 6) == 0) {
                        free(mutability);
                        free(binding_id);
                        free(name);
                        free(emitted.data);
                        return value_body;
                    }
                    buffer_append(
                        &emitted,
                        "    {\n"
                        "        int64_t kofun_replacement = INT64_C(0);\n"
                    );
                    buffer_append(&emitted, value_body);
                    buffer_format(
                        &emitted,
                        "        k_b%s = kofun_replacement;\n"
                        "    }\n",
                        binding_id
                    );
                    free(value_body);
                    free(mutability);
                    free(binding_id);
                    free(name);
                    cursor = skip_trivia(source, value_end);
                    continue;
                }
                int64_t value_end = expression_end(source, value_start);
                if (value_end < 0) {
                    free(mutability);
                    free(binding_id);
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "invalid Int expression",
                        value_start
                    );
                }
                char *value = emit_expression(
                    source,
                    hir,
                    value_start,
                    value_end
                );
                buffer_format(
                    &emitted,
                    "    {\n"
                    "        int64_t kofun_replacement = %s;\n"
                    "        if (kofun_failed) return %s;\n"
                    "        k_b%s = kofun_replacement;\n"
                    "    }\n",
                    value,
                    failure_result,
                    binding_id
                );
                free(value);
                free(mutability);
                free(binding_id);
                cursor = skip_trivia(source, value_end);
            } else {
                int64_t value_end = expression_end(source, cursor);
                if (value_end < 0) {
                    free(name);
                    free(emitted.data);
                    return lower_error(
                        "E2S12",
                        "invalid expression statement",
                        cursor
                    );
                }
                char *value = emit_expression(source, hir, cursor, value_end);
                int64_t after = skip_trivia(source, value_end);
                /*
                 * The final expression of an Int-returning function is its
                 * result. Only the last statement qualifies, and only when the
                 * closing brace follows it, so an expression in the middle of a
                 * body keeps being discarded exactly as before. `main`,
                 * enum-returning, and record-returning functions are
                 * deliberately excluded: `main` already appends its own status
                 * return, and an enum or record result needs its own C shape
                 * rather than the `int64_t` this emits.
                 */
                if (!is_main && append_default && !returns_enum &&
                    !returns_record && !returns_list_int &&
                    after < length && token_equal(source, after, "}")) {
                    buffer_format(
                        &emitted,
                        "    {\n"
                        "        int64_t kofun_result = %s;\n"
                        "        if (kofun_failed) return %s;\n"
                        "        return kofun_result;\n"
                        "    }\n",
                        value,
                        failure_result
                    );
                    returned = true;
                } else {
                    buffer_format(
                        &emitted,
                        "    (void)%s;\n"
                        "    if (kofun_failed) return %s;\n",
                        value,
                        failure_result
                    );
                }
                free(value);
                cursor = skip_trivia(source, value_end);
            }
            free(name);
        } else {
            free(emitted.data);
            return lower_error("E2S10", "unsupported Core statement", cursor);
        }
    }
    if (cursor >= length || !token_equal(source, cursor, "}")) {
        free(emitted.data);
        return lower_error("E2S03", "missing function close", -1);
    }
    if (!returned && append_default && !is_main) {
        free(emitted.data);
        return lower_error(
            "E2S19",
            returns_enum ?
                "Core function may complete without returning its enum" :
                (returns_list_int ?
                    "Core function may complete without returning List[Int]" :
                    "Core function may complete without returning Int"),
            open
        );
    }
    if (!returned && append_default) {
        buffer_append(&emitted, "    return 0;\n");
    }
    return emitted.data;
}

/*
 * Lifts every lambda binding to a top-level `kofun_lambda_<binding>` and
 * appends its prototype and body to the module being built.
 *
 * Lifting rather than a function value is what keeps this inside the frozen
 * profile: Stage 2 lowers every value to `int64_t` and has no function type,
 * no function pointer and no indirect call, so a lambda that stayed a value
 * would need all three. A lifted lambda is an ordinary Core function, and its
 * body lowers through the same expression emitter as any other, because the
 * scope HIR already binds the parameters.
 */
static char *emit_lifted_lambdas(
    const char *source,
    const char *hir,
    Buffer *prototypes,
    Buffer *bodies
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        if (!token_equal(source, cursor, "let")) {
            cursor = skip_trivia(source, token_end(source, cursor));
            continue;
        }
        int64_t name_start = skip_trivia(source, token_end(source, cursor));
        if (token_equal(source, name_start, "mut")) {
            name_start = skip_trivia(source, token_end(source, name_start));
        }
        if (
            name_start >= length ||
            strcmp(token_kind(source, name_start), "identifier") != 0
        ) {
            cursor = skip_trivia(source, token_end(source, cursor));
            continue;
        }
        int64_t equals = skip_trivia(source, token_end(source, name_start));
        if (equals < length && token_equal(source, equals, ":")) {
            int64_t annotation = skip_trivia(
                source,
                token_end(source, equals)
            );
            equals = skip_trivia(source, token_end(source, annotation));
        }
        if (equals >= length || !token_equal(source, equals, "=")) {
            cursor = skip_trivia(source, token_end(source, cursor));
            continue;
        }
        int64_t open = lambda_initializer_open(
            source,
            skip_trivia(source, token_end(source, equals))
        );
        if (open < 0) {
            cursor = skip_trivia(source, token_end(source, cursor));
            continue;
        }

        char *binding_id = hir_definition_id_at(hir, name_start);
        Buffer signature;
        buffer_init(&signature);
        int64_t parameters = 0;
        /* The bare form is keyed by its single parameter and has no list, so
         * its "close" is the end of that identifier — which is also where the
         * `=>` search below starts. Taking `balanced_end` here would yield -1
         * and walk the source from a negative offset. */
        bool bare_lambda = !token_equal(source, open, "(");
        int64_t close = bare_lambda
            ? token_end(source, open)
            : balanced_end(source, open, "(", ")");
        int64_t parameter = bare_lambda
            ? open
            : skip_trivia(source, token_end(source, open));
        while (parameter < close) {
            if (strcmp(token_kind(source, parameter), "identifier") != 0) {
                break;
            }
            char *parameter_id = hir_definition_id_at(hir, parameter);
            if (parameters > 0) buffer_append(&signature, ", ");
            buffer_format(&signature, "int64_t k_b%s", parameter_id);
            free(parameter_id);
            ++parameters;
            int64_t after = skip_trivia(source, token_end(source, parameter));
            if (after < close && token_equal(source, after, ":")) {
                int64_t annotation = skip_trivia(
                    source,
                    token_end(source, after)
                );
                after = skip_trivia(source, token_end(source, annotation));
            }
            if (after < close && token_equal(source, after, ",")) {
                after = skip_trivia(source, token_end(source, after));
            }
            parameter = after;
        }
        char *captures = lambda_captures(source, hir, open);
        append_captures(&signature, captures, parameters, "int64_t ");
        free(captures);
        const char *c_parameters =
            signature.length == 0 ? "void" : signature.data;

        int64_t arrow = skip_trivia(source, close);
        int64_t body_start = skip_trivia(source, token_end(source, arrow));
        int64_t body_end = lambda_parameters_end(source, -1, open);
        char *value = emit_expression(source, hir, body_start, body_end);
        if (strncmp(value, "error[", 6) == 0) {
            free(signature.data);
            free(binding_id);
            return value;
        }
        buffer_format(
            prototypes,
            "static int64_t kofun_lambda_%s(%s);\n",
            binding_id,
            c_parameters
        );
        buffer_format(
            bodies,
            "static int64_t kofun_lambda_%s(%s) {\n"
            "    {\n"
            "        int64_t kofun_result = %s;\n"
            "        if (kofun_failed) return 0;\n"
            "        return kofun_result;\n"
            "    }\n"
            "}\n",
            binding_id,
            c_parameters,
            value
        );
        free(value);
        free(signature.data);
        free(binding_id);
        cursor = skip_trivia(source, body_end);
    }
    return owned_text("ok");
}

/*
 * Whether the arrow lambda keyed at the current token is written directly in
 * argument position rather than as a `let` initializer.
 *
 * `lambda_parameters_end` documents the four tokens that may precede a
 * parameter list: `fn`, `=`, `,` and `(`. `=` is the initializer position and
 * the other two are argument position, so the preceding token decides — after
 * stepping over `fn`, which may sit in front of either.
 */
static bool argument_position_lambda(
    const char *source,
    int64_t previous,
    int64_t before_previous
) {
    int64_t effective = previous;
    if (effective >= 0 && token_equal(source, effective, "fn")) {
        effective = before_previous;
    }
    if (effective < 0) return false;
    return token_equal(source, effective, "(") ||
           token_equal(source, effective, ",");
}

/*
 * Lifts every arrow lambda written in argument position to a top-level
 * `kofun_lambda_at<offset>`.
 *
 * This walk visits every token rather than jumping over a lambda body, so a
 * lambda nested inside another lambda's argument is lifted too. The `let`
 * initializer walk cannot be reused: an anonymous argument has no binding id
 * to key on, and `emit_lifted_lambdas` keys on exactly that.
 */
static char *emit_lifted_argument_lambdas(
    const char *source,
    const char *hir,
    Buffer *prototypes,
    Buffer *bodies
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    int64_t previous = -1;
    int64_t before_previous = -1;
    while (cursor < length) {
        int64_t close = lambda_parameters_end(source, previous, cursor);
        if (
            close >= 0 &&
            argument_position_lambda(source, previous, before_previous)
        ) {
            Buffer signature;
            buffer_init(&signature);
            int64_t parameters = 0;
            bool bare_lambda = !token_equal(source, cursor, "(");
            int64_t parameters_close = bare_lambda
                ? token_end(source, cursor)
                : balanced_end(source, cursor, "(", ")");
            int64_t parameter = bare_lambda
                ? cursor
                : skip_trivia(source, token_end(source, cursor));
            while (parameter < parameters_close) {
                if (strcmp(token_kind(source, parameter), "identifier") != 0) {
                    break;
                }
                char *parameter_id = hir_definition_id_at(hir, parameter);
                if (parameters > 0) buffer_append(&signature, ", ");
                buffer_format(&signature, "int64_t k_b%s", parameter_id);
                free(parameter_id);
                ++parameters;
                int64_t after = skip_trivia(
                    source,
                    token_end(source, parameter)
                );
                if (
                    after < parameters_close && token_equal(source, after, ":")
                ) {
                    int64_t annotation = skip_trivia(
                        source,
                        token_end(source, after)
                    );
                    after = skip_trivia(source, token_end(source, annotation));
                }
                if (
                    after < parameters_close && token_equal(source, after, ",")
                ) {
                    after = skip_trivia(source, token_end(source, after));
                }
                parameter = after;
            }
            const char *c_parameters =
                signature.length == 0 ? "void" : signature.data;
            int64_t arrow = skip_trivia(source, parameters_close);
            int64_t body_start = skip_trivia(source, token_end(source, arrow));
            char *value = emit_expression(source, hir, body_start, close);
            if (strncmp(value, "error[", 6) == 0) {
                free(signature.data);
                return value;
            }
            char *name = argument_lambda_name(cursor);
            buffer_format(
                prototypes,
                "static int64_t %s(%s);\n",
                name,
                c_parameters
            );
            buffer_format(
                bodies,
                "static int64_t %s(%s) {\n"
                "    {\n"
                "        int64_t kofun_result = %s;\n"
                "        if (kofun_failed) return 0;\n"
                "        return kofun_result;\n"
                "    }\n"
                "}\n",
                name,
                c_parameters,
                value
            );
            free(name);
            free(value);
            free(signature.data);
        }
        before_previous = previous;
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

/*
 * A capturing lambda cannot be a function value. Lifting passes each capture
 * as a trailing `int64_t` parameter, so the lifted function's C type is wider
 * than the callable type the parameter declares and its address is not that
 * callable. Closure conversion — an environment travelling with the code — is
 * #116 and #370, and #703 puts it out of scope, so this refuses rather than
 * lowering something whose observations would not match.
 */
static char *validate_argument_lambda_captures(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    int64_t previous = -1;
    int64_t before_previous = -1;
    while (cursor < length) {
        int64_t close = lambda_parameters_end(source, previous, cursor);
        if (
            close >= 0 &&
            argument_position_lambda(source, previous, before_previous)
        ) {
            char *captures = lambda_captures(source, hir, cursor);
            bool captured = captures[0] != '\0';
            free(captures);
            if (captured) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "error[E2S96]: lambda argument at byte %" PRId64
                    " captures an enclosing binding; pass a lambda that reads "
                    "only its parameters",
                    cursor
                );
                stage2_diagnostic_set(
                    "E2S96",
                    cursor,
                    token_end(source, cursor),
                    true,
                    message.data
                );
                return message.data;
            }
        }
        before_previous = previous;
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

static const char *numeric_name(const char *name) {
    if (name == NULL) return "";
    if (strcmp(name, "Int") == 0) return "Int";
    if (strcmp(name, "Decimal") == 0) return "Decimal";
    if (strcmp(name, "Float") == 0) return "Float";
    return "";
}

/*
 * True when `cursor` is the type name heading a `Type.member` path.
 *
 * This is the one place the scope walk must not treat a numeric type name as a
 * binding use. `Decimal` in `Decimal.from_int(3)` names a type, not a value, so
 * resolving it would report `E2S35: unknown lexical binding` — which is what it
 * did before the conversions existed.
 */
static bool numeric_conversion_head(const char *source, int64_t cursor) {
    char *name = token_copy(source, cursor);
    bool numeric = numeric_name(name)[0] != '\0';
    free(name);
    if (!numeric) return false;
    int64_t length = source_length(source);
    int64_t dot = skip_trivia(source, token_end(source, cursor));
    return dot < length && token_equal(source, dot, ".");
}

/*
 * The `Type.member` conversion path beginning at `cursor`, or "" when there is
 * not one. The member must be called: a bare `Decimal.from_int` is a value of a
 * type the language does not have, so only the call form is recognised.
 *
 * The caller owns the result.
 */
static char *numeric_conversion_at(const char *source, int64_t cursor) {
    if (!numeric_conversion_head(source, cursor)) return owned_text("");
    int64_t length = source_length(source);
    int64_t dot = skip_trivia(source, token_end(source, cursor));
    int64_t member = skip_trivia(source, token_end(source, dot));
    if (
        member >= length ||
        strcmp(token_kind(source, member), "identifier") != 0
    ) {
        return owned_text("");
    }
    int64_t open = skip_trivia(source, token_end(source, member));
    if (open >= length || !token_equal(source, open, "(")) {
        return owned_text("");
    }
    char *head = token_copy(source, cursor);
    char *tail = token_copy(source, member);
    Buffer path;
    buffer_init(&path);
    buffer_format(&path, "%s.%s", head, tail);
    free(head);
    free(tail);
    return path.data;
}

/*
 * True when `cursor` heads the unstable compile-time move assertion
 * `compiler.ensure_move(...)` (#572). Like `numeric_conversion_head`, the
 * scope walk must not resolve the head as a binding: `compiler` names the
 * intrinsic namespace here, not a value. Only this exact member is
 * recognised; any other `compiler.` path keeps its existing meaning, so a
 * user binding named `compiler` still resolves everywhere else. While the
 * assertion is unstable, `compiler.ensure_move` is reserved.
 */
static bool move_assertion_head(const char *source, int64_t cursor) {
    if (!token_equal(source, cursor, "compiler")) return false;
    int64_t length = source_length(source);
    int64_t dot = skip_trivia(source, token_end(source, cursor));
    if (dot >= length || !token_equal(source, dot, ".")) return false;
    int64_t member = skip_trivia(source, token_end(source, dot));
    return member < length && token_equal(source, member, "ensure_move");
}

/*
 * `take <binding>`, the whole-binding move statement (#946).
 *
 * `take` is a contextual word: an ownership mode inside a parameter list, a
 * move statement at the head of one. The scope walk did not know that, and
 * reported the statement's own keyword as a name nobody declared. Measured on
 * `origin/main`:
 *
 *     $ ./bin/kofun check uam.kofun
 *     error[E2S35]: unknown lexical binding `take` at byte 70
 *
 * So the production frontend never reached the ownership rule, and E2S122 and
 * E2S123 — which `bootstrap/stage2/record_frontend.c` has implemented all
 * along — could not be produced by the compiler a user runs. That standalone
 * frontend is not linked into this one; see docs/COMPILER_ARCHITECTURE.md.
 *
 * The colon separates the two spellings: `take name: Type` is a parameter,
 * `take name` is a move. `take` remains a legal binding name, so anything else
 * following it is left to the ordinary grammar.
 */
static bool move_statement_head(const char *source, int64_t cursor) {
    if (!token_equal(source, cursor, "take")) return false;
    int64_t length = source_length(source);
    int64_t target = skip_trivia(source, token_end(source, cursor));
    if (target >= length) return false;
    if (strcmp(token_kind(source, target), "identifier") != 0) return false;
    int64_t after = skip_trivia(source, token_end(source, target));
    if (after < length && token_equal(source, after, ":")) return false;
    return true;
}

/* Start of the zero-based argument in a validated numeric member call. */
static int64_t numeric_member_argument(
    const char *source,
    int64_t open,
    int64_t wanted
) {
    int64_t length = source_length(source);
    int64_t argument = skip_trivia(source, token_end(source, open));
    int64_t index = 0;
    while (argument < length && !token_equal(source, argument, ")")) {
        int64_t bound;
        int64_t separator;
        if (index == wanted) return argument;
        bound = argument_end(source, argument);
        if (bound < 0) return -1;
        separator = skip_trivia(source, bound);
        if (!token_equal(source, separator, ",")) return -1;
        argument = skip_trivia(source, token_end(source, separator));
        ++index;
    }
    return -1;
}

static bool decimal_rounding_mode_name(const char *name) {
    return strcmp(name, "HalfUp") == 0 ||
           strcmp(name, "HalfEven") == 0 ||
           strcmp(name, "TowardZero") == 0 ||
           strcmp(name, "Floor") == 0 ||
           strcmp(name, "Ceiling") == 0;
}

static const char *decimal_rounding_c_name(const char *name) {
    if (strcmp(name, "HalfUp") == 0) return "KOFUN_DECIMAL_HALF_UP";
    if (strcmp(name, "HalfEven") == 0) return "KOFUN_DECIMAL_HALF_EVEN";
    if (strcmp(name, "TowardZero") == 0) return "KOFUN_DECIMAL_TOWARD_ZERO";
    if (strcmp(name, "Floor") == 0) return "KOFUN_DECIMAL_FLOOR";
    if (strcmp(name, "Ceiling") == 0) return "KOFUN_DECIMAL_CEILING";
    return "KOFUN_DECIMAL_HALF_EVEN";
}

/*
 * The result type of a named conversion, or "" when the path is not one.
 *
 * `docs/DECIMAL.md` fixes these three names. `Decimal.from_int` is the only one
 * that can be written today; the other two are recognised here so that
 * `validate_numeric_conversions` can reject them for the right reason rather
 * than calling them unknown.
 */
static const char *numeric_conversion_result(const char *conversion) {
    if (
        strcmp(conversion, "Decimal.from_int") == 0 ||
        strcmp(conversion, "Decimal.from_float") == 0 ||
        strcmp(conversion, "Decimal.round") == 0 ||
        strcmp(conversion, "Decimal.divide") == 0 ||
        strcmp(conversion, "Decimal.parse") == 0
    ) {
        return "Decimal";
    }
    if (strcmp(conversion, "Decimal.format") == 0) return "Text";
    if (strcmp(conversion, "Float.from_decimal") == 0) return "Float";
    return "";
}

/*
 * The conversion that brings two mixed operand types together, or "" when the
 * pair has none.
 *
 * The pair is unordered because each name works from either side: `1 + 1.5` and
 * `1.5 + 1` are both fixed by converting the Int with `Decimal.from_int`, and
 * which operand it wraps is visible in the source.
 *
 * `Int` and `Float` return "" because `docs/DECIMAL.md` defines no conversion
 * between them in either direction. That is a real gap in the conversion set,
 * not an oversight here — Int to binary64 is exact only below 2^53 and so needs
 * the same policy argument the other inexact conversions do. Saying so beats
 * naming a function that does not exist.
 */
static const char *numeric_conversion_between(
    const char *left,
    const char *right
) {
    if (
        (strcmp(left, "Int") == 0 && strcmp(right, "Decimal") == 0) ||
        (strcmp(left, "Decimal") == 0 && strcmp(right, "Int") == 0)
    ) {
        return "Decimal.from_int";
    }
    if (
        (strcmp(left, "Decimal") == 0 && strcmp(right, "Float") == 0) ||
        (strcmp(left, "Float") == 0 && strcmp(right, "Decimal") == 0)
    ) {
        return "Float.from_decimal";
    }
    return "";
}

static bool arithmetic_operator_at(const char *source, int64_t cursor) {
    return token_equal(source, cursor, "+") ||
           token_equal(source, cursor, "-") ||
           token_equal(source, cursor, "*") ||
           token_equal(source, cursor, "/") ||
           token_equal(source, cursor, "//") ||
           token_equal(source, cursor, "%") ||
           token_equal(source, cursor, "**");
}

/*
 * The numeric type of the *primary* at `start`, or "" when it is not one of
 * the three numeric types.
 *
 * Slice 3 of #710 needs the type of one operand, which `initializer_type`
 * cannot give: that function scans the whole initializer line and returns
 * `Bool` the moment it sees a comparison, so typing the `1` in `1 + 2 < 3`
 * through it yields `Bool`. This looks at the primary and nothing else.
 *
 * "" rather than a default is deliberate. `Text`, `Bool` and unresolved names
 * are not numeric operands, and the mixed-arithmetic check must skip them
 * instead of inventing an `Int` and reporting a mismatch that is not there.
 *
 * The returned pointer is a static string, never owned.
 */
static const char *numeric_primary_type(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t start
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length) return "";
    /* Unary sign and a parenthesised group both delegate to what follows. */
    if (
        token_equal(source, cursor, "-") ||
        token_equal(source, cursor, "+") ||
        token_equal(source, cursor, "(")
    ) {
        return numeric_primary_type(
            source,
            hir,
            function_open,
            skip_trivia(source, token_end(source, cursor))
        );
    }
    /* A named conversion is typed by its destination, which is what makes
     * `Decimal.from_int(n) + 1.5` a same-type expression rather than a mix. */
    {
        char *conversion = numeric_conversion_at(source, cursor);
        const char *converted = numeric_conversion_result(conversion);
        free(conversion);
        if (converted[0] != '\0') return converted;
    }
    const char *kind = token_kind(source, cursor);
    if (strcmp(kind, "integer") == 0) return "Int";
    if (strcmp(kind, "decimal") == 0) return "Decimal";
    if (strcmp(kind, "float") == 0) return "Float";
    if (strcmp(kind, "identifier") != 0) return "";

    char *name = token_copy(source, cursor);
    int64_t open = skip_trivia(source, token_end(source, cursor));
    const char *result = "";
    if (open < length && token_equal(source, open, "(")) {
        char *declared = function_return_type(source, name);
        if (declared[0] != '\0') {
            result = numeric_name(declared);
        } else {
            result = numeric_name(builtin_return_type(name));
        }
        free(declared);
        free(name);
        return result;
    }
    int64_t scope_open = parent_block_open(source, function_open, cursor);
    char *scope_id = hir_scope_id_for_open(hir, scope_open);
    char *binding_id = hir_resolve_binding(hir, scope_id, cursor, name);
    free(scope_id);
    if (binding_id[0] != '\0') {
        char *binding_type = hir_binding_field(hir, binding_id, 5);
        result = numeric_name(binding_type);
        free(binding_type);
    }
    free(binding_id);
    free(name);
    return result;
}

/*
 * Whether one primary is Text. This stays separate from
 * `numeric_primary_type`: E2S100 consumes that helper and must continue to see
 * Text as outside the numeric lattice.
 */
static bool text_operand(
    const char *source,
    const char *hir,
    int64_t function_open,
    int64_t start
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, start);
    if (cursor >= length) return false;
    while (token_equal(source, cursor, "(")) {
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (strcmp(token_kind(source, cursor), "string") == 0) return true;
    if (strcmp(token_kind(source, cursor), "identifier") != 0) return false;

    char *conversion = numeric_conversion_at(source, cursor);
    bool result = strcmp(conversion, "Decimal.format") == 0;
    free(conversion);
    if (result) return true;

    char *name = token_copy(source, cursor);
    int64_t open = skip_trivia(source, token_end(source, cursor));
    if (open < length && token_equal(source, open, "(")) {
        char *declared = function_return_type(source, name);
        const char *builtin = builtin_return_type(name);
        result = strcmp(declared, "Text") == 0 ||
            (builtin != NULL && strcmp(builtin, "Text") == 0);
        free(declared);
        free(name);
        return result;
    }

    int64_t scope_open = parent_block_open(source, function_open, cursor);
    char *scope_id = hir_scope_id_for_open(hir, scope_open);
    char *binding_id = hir_resolve_binding(hir, scope_id, cursor, name);
    free(scope_id);
    char *binding_type = binding_id[0] == '\0'
        ? owned_text("")
        : hir_binding_field(hir, binding_id, 5);
    result = strcmp(binding_type, "Text") == 0;
    if (!result && token_equal(source, open, ".")) {
        int64_t field_cursor = skip_trivia(source, token_end(source, open));
        char *field = token_copy(source, field_cursor);
        char *field_type = record_field_type_named(
            source,
            binding_type,
            field
        );
        result = strcmp(field_type, "Text") == 0;
        free(field_type);
        free(field);
    }
    free(binding_type);
    free(binding_id);
    free(name);
    return result;
}

/*
 * `Int`, `Decimal` and `Float` never receive implicit promotion (#710 frozen
 * decision 4), so an arithmetic expression mixing two of them is a type error
 * rather than a conversion.
 *
 * Both operand orders are checked by construction: the walk types the primary
 * before each operator and the primary after it, so a rule written for one
 * side only cannot pass. That matters — a promotion bug usually appears on one
 * side.
 */
static char *validate_numeric_operand_types(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t function_open = parameters >= 0
            ? balanced_end(source, parameters, "(", ")")
            : -1;
        if (function_open >= 0) {
            int64_t cursor = skip_trivia(source, function_open);
            int64_t last_primary = -1;
            while (cursor < function_close) {
                /* A conversion is one primary and its argument is not an
                 * operand of the surrounding expression. Without this skip the
                 * walk stops at the inner literal: `Decimal.from_int(1) + 1`
                 * would read as Int + Int and be accepted, and
                 * `Decimal.from_int(1) + 1.5` would read as Int + Decimal and
                 * be rejected. Both are wrong, and in opposite directions. */
                int64_t advance = -1;
                char *primary_conversion = numeric_conversion_at(
                    source,
                    cursor
                );
                bool is_conversion = primary_conversion[0] != '\0';
                free(primary_conversion);
                if (is_conversion) {
                    last_primary = cursor;
                    int64_t dot = skip_trivia(
                        source,
                        token_end(source, cursor)
                    );
                    int64_t member = skip_trivia(
                        source,
                        token_end(source, dot)
                    );
                    int64_t open = skip_trivia(
                        source,
                        token_end(source, member)
                    );
                    int64_t close = balanced_end(source, open, "(", ")");
                    if (close > 0) advance = skip_trivia(source, close);
                } else if (arithmetic_operator_at(source, cursor) &&
                    last_primary >= 0) {
                    int64_t right = skip_trivia(
                        source,
                        token_end(source, cursor)
                    );
                    const char *left_type = numeric_primary_type(
                        source, hir, function_open, last_primary);
                    const char *right_type = numeric_primary_type(
                        source, hir, function_open, right);
                    if (
                        left_type[0] != '\0' && right_type[0] != '\0' &&
                        strcmp(left_type, right_type) != 0
                    ) {
                        char *operator_text = token_copy(source, cursor);
                        const char *remedy = numeric_conversion_between(
                            left_type,
                            right_type
                        );
                        char advice[80];
                        if (remedy[0] != '\0') {
                            snprintf(
                                advice,
                                sizeof advice,
                                "write %s(...)",
                                remedy
                            );
                        } else {
                            snprintf(
                                advice,
                                sizeof advice,
                                "no conversion between them exists"
                            );
                        }
                        Buffer message;
                        buffer_init(&message);
                        buffer_format(
                            &message,
                            "error[E2S100]: operator `%s` mixes %s and %s "
                            "at byte %" PRId64 "; %s",
                            operator_text,
                            left_type,
                            right_type,
                            cursor,
                            advice
                        );
                        free(operator_text);
                        stage2_diagnostic_set(
                            "E2S100",
                            cursor,
                            token_end(source, cursor),
                            true,
                            message.data
                        );
                        return message.data;
                    }
                    last_primary = right;
                } else {
                    const char *kind = token_kind(source, cursor);
                    if (
                        strcmp(kind, "integer") == 0 ||
                        strcmp(kind, "decimal") == 0 ||
                        strcmp(kind, "float") == 0 ||
                        strcmp(kind, "identifier") == 0
                    ) {
                        last_primary = cursor;
                    }
                }
                if (advance >= 0) {
                    cursor = advance;
                } else {
                    cursor = skip_trivia(source, token_end(source, cursor));
                }
            }
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

/*
 * `/` belongs to Decimal (checked exact result) and Float (binary64), never
 * Int.  Conversely `//`, `%`, and `**` remain outside the fractional slice.
 * This is validated before C emission so an unsupported operator cannot leak
 * through as a host-C type error or accidentally settle Decimal remainder
 * semantics.
 */
static char *validate_fractional_operators(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t function_open = parameters >= 0
            ? balanced_end(source, parameters, "(", ")")
            : -1;
        int64_t cursor = function_open >= 0
            ? skip_trivia(source, function_open)
            : function_close;
        int64_t last_primary = -1;
        while (cursor < function_close) {
            bool relevant =
                token_equal(source, cursor, "/") ||
                token_equal(source, cursor, "//") ||
                token_equal(source, cursor, "%") ||
                token_equal(source, cursor, "**");
            if (relevant && last_primary >= 0) {
                int64_t right = skip_trivia(
                    source,
                    token_end(source, cursor)
                );
                const char *left_type = numeric_primary_type(
                    source,
                    hir,
                    function_open,
                    last_primary
                );
                const char *right_type = numeric_primary_type(
                    source,
                    hir,
                    function_open,
                    right
                );
                bool slash_on_int =
                    token_equal(source, cursor, "/") &&
                    strcmp(left_type, "Int") == 0 &&
                    strcmp(right_type, "Int") == 0;
                bool fractional_reserved =
                    !token_equal(source, cursor, "/") &&
                    (
                        strcmp(left_type, "Decimal") == 0 ||
                        strcmp(left_type, "Float") == 0 ||
                        strcmp(right_type, "Decimal") == 0 ||
                        strcmp(right_type, "Float") == 0
                    );
                if (slash_on_int || fractional_reserved) {
                    char *operator_text = token_copy(source, cursor);
                    Buffer message;
                    buffer_init(&message);
                    if (slash_on_int) {
                        buffer_format(
                            &message,
                            "error[E2S144]: `/` is not defined on Int at "
                            "byte %" PRId64 "; use `//` for the integer "
                            "quotient",
                            cursor
                        );
                    } else {
                        buffer_format(
                            &message,
                            "error[E2S144]: operator `%s` is not defined on "
                            "%s at byte %" PRId64,
                            operator_text,
                            left_type[0] == '\0' ? right_type : left_type,
                            cursor
                        );
                    }
                    free(operator_text);
                    stage2_diagnostic_set(
                        "E2S144",
                        cursor,
                        token_end(source, cursor),
                        true,
                        message.data
                    );
                    return message.data;
                }
                last_primary = right;
            } else {
                const char *kind = token_kind(source, cursor);
                if (
                    strcmp(kind, "integer") == 0 ||
                    strcmp(kind, "decimal") == 0 ||
                    strcmp(kind, "float") == 0 ||
                    strcmp(kind, "identifier") == 0
                ) {
                    last_primary = cursor;
                }
            }
            cursor = skip_trivia(source, token_end(source, cursor));
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

/*
 * A numeric annotation and its initializer must name the same type.
 *
 * #710 frozen decision 4 removes implicit promotion *in both directions*, so
 * `let x: Decimal = 1` is exactly as wrong as `let x: Int = 1.5`. A checker
 * that rejected only the narrowing direction would still be promoting, just
 * quietly and one way — which is the failure this decision exists to prevent.
 *
 * The initializer is typed through `numeric_primary_type`, not
 * `initializer_type`. That matters for what is *not* reported: the former
 * answers "" for Text, Bool and unresolved names, while the latter falls back
 * to `Int`, and an `Int` invented there would report a mismatch against every
 * non-numeric annotation in the corpus.
 *
 * Mixed arithmetic is already rejected before this runs, so typing the first
 * primary types the whole initializer: what reaches here is homogeneous.
 */
static char *validate_numeric_annotations(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t function_open = parameters >= 0
            ? balanced_end(source, parameters, "(", ")")
            : -1;
        if (function_open >= 0) {
            int64_t cursor = skip_trivia(source, function_open);
            while (cursor < function_close) {
                if (token_equal(source, cursor, "let")) {
                    int64_t name = skip_trivia(
                        source,
                        token_end(source, cursor)
                    );
                    if (token_equal(source, name, "mut")) {
                        name = skip_trivia(source, token_end(source, name));
                    }
                    int64_t colon = skip_trivia(
                        source,
                        token_end(source, name)
                    );
                    if (token_equal(source, colon, ":")) {
                        int64_t annotation = skip_trivia(
                            source,
                            token_end(source, colon)
                        );
                        char *annotation_text = token_copy(source, annotation);
                        const char *declared = numeric_name(annotation_text);
                        free(annotation_text);
                        int64_t assign = skip_trivia(
                            source,
                            token_end(source, annotation)
                        );
                        if (
                            declared[0] != '\0' &&
                            token_equal(source, assign, "=")
                        ) {
                            int64_t initializer = skip_trivia(
                                source,
                                token_end(source, assign)
                            );
                            const char *actual = "";
                            if (!value_control(source, initializer)) {
                                actual = numeric_primary_type(
                                    source,
                                    hir,
                                    function_open,
                                    initializer
                                );
                            }
                            if (
                                actual[0] != '\0' &&
                                strcmp(actual, declared) != 0
                            ) {
                                char *binding = token_copy(source, name);
                                Buffer message;
                                buffer_init(&message);
                                buffer_format(
                                    &message,
                                    "error[E2S101]: binding `%s` is %s but "
                                    "its value is %s at byte %" PRId64
                                    "; convert explicitly",
                                    binding,
                                    declared,
                                    actual,
                                    initializer
                                );
                                free(binding);
                                stage2_diagnostic_set(
                                    "E2S101",
                                    initializer,
                                    token_end(source, initializer),
                                    true,
                                    message.data
                                );
                                return message.data;
                            }
                        }
                    }
                }
                cursor = skip_trivia(source, token_end(source, cursor));
            }
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

static int64_t numeric_member_expected_arity(const char *member) {
    if (
        strcmp(member, "Decimal.from_int") == 0 ||
        strcmp(member, "Decimal.from_float") == 0 ||
        strcmp(member, "Decimal.parse") == 0
    ) {
        return 1;
    }
    if (
        strcmp(member, "Float.from_decimal") == 0 ||
        strcmp(member, "Decimal.format") == 0
    ) {
        return 2;
    }
    if (strcmp(member, "Decimal.round") == 0) return 3;
    if (strcmp(member, "Decimal.divide") == 0) return 4;
    return -1;
}

static const char *numeric_member_expected_type(
    const char *member,
    int64_t index
) {
    if (strcmp(member, "Decimal.from_int") == 0) return "Int";
    if (strcmp(member, "Decimal.round") == 0) {
        if (index == 0) return "Decimal";
        if (index == 1) return "Int";
        return "";
    }
    if (strcmp(member, "Decimal.divide") == 0) {
        if (index == 0 || index == 1) return "Decimal";
        if (index == 2) return "Int";
        return "";
    }
    if (strcmp(member, "Decimal.format") == 0) {
        return index == 0 ? "Decimal" : "Int";
    }
    if (strcmp(member, "Decimal.parse") == 0) return "Text";
    return "";
}

static int64_t numeric_member_mode_index(const char *member) {
    if (strcmp(member, "Decimal.round") == 0) return 2;
    if (strcmp(member, "Decimal.divide") == 0) return 3;
    return -1;
}

/*
 * The named conversions and Decimal slice-5 operations, and what each costs.
 *
 * Conversions are named and explicit because there is no implicit promotion.
 * But naming a conversion is not enough to make it writable: two of the three
 * cross the decimal/binary boundary and cannot be exact, and `docs/DECIMAL.md`
 * forbids any ambient rounding context that would let the compiler pick a mode
 * on the programmer's behalf.
 *
 * So `Decimal.from_int` is accepted — Int to Decimal is exact for every input,
 * and needs no mode — while `Float.from_decimal` and `Decimal.from_float` are
 * rejected until slice 5 gives them the rounding mode and policy arguments they
 * require. Rejecting them is the honest outcome: accepting either one today
 * would mean choosing a rounding mode silently, which is the single thing the
 * frozen decisions rule out.
 *
 * Validation records a valid exact conversion while continuing to look for a
 * later invalid one; lowering handles `Decimal.from_int` structurally, and the
 * ordinary call validator skips the member token following `.`.
 */
static char *validate_numeric_conversions(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    int64_t valid_conversion = -1;
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t function_open = parameters >= 0
            ? balanced_end(source, parameters, "(", ")")
            : -1;
        if (function_open >= 0) {
            int64_t cursor = skip_trivia(source, function_open);
            while (cursor < function_close) {
                if (numeric_conversion_head(source, cursor)) {
                    char *conversion = numeric_conversion_at(source, cursor);
                    Buffer message;
                    buffer_init(&message);
                    const char *code = NULL;
                    int64_t span = cursor;
                    /* The messages stay short on purpose: the member name is
                     * unbounded and the semantic producer holds a diagnostic
                     * in 160 bytes, so a long name plus a long tail truncates
                     * on one side of the gate only. */
                    if (conversion[0] == '\0') {
                        char *head = token_copy(source, cursor);
                        buffer_format(
                            &message,
                            "error[E2S102]: `%s` has only conversions at byte "
                            "%" PRId64 "; write `Decimal.from_int(value)`",
                            head,
                            cursor
                        );
                        free(head);
                        code = "E2S102";
                    } else if (
                        numeric_conversion_result(conversion)[0] == '\0'
                    ) {
                        buffer_format(
                            &message,
                            "error[E2S102]: unknown conversion `%s` at byte "
                            "%" PRId64 "; known: from_int, round, divide, "
                            "format, parse",
                            conversion,
                            cursor
                        );
                        code = "E2S102";
                    } else if (
                        strcmp(conversion, "Decimal.from_float") == 0 ||
                        strcmp(conversion, "Float.from_decimal") == 0
                    ) {
                        buffer_format(
                            &message,
                            "error[E2S103]: `%s` cannot be exact at byte "
                            "%" PRId64
                            "; its cross-radix policy is not implemented",
                            conversion,
                            cursor
                        );
                        code = "E2S103";
                    } else if (
                        strcmp(conversion, "Decimal.from_int") != 0
                    ) {
                        if (valid_conversion < 0) valid_conversion = cursor;
                    } else {
                        int64_t dot = skip_trivia(
                            source,
                            token_end(source, cursor)
                        );
                        int64_t member = skip_trivia(
                            source,
                            token_end(source, dot)
                        );
                        int64_t open = skip_trivia(
                            source,
                            token_end(source, member)
                        );
                        int64_t actual = call_arity(source, open);
                        if (actual != 1) {
                            buffer_format(
                                &message,
                                "error[E2S17]: Core function `%s` expects 1 "
                                "arguments, got %" PRId64 " at byte %" PRId64,
                                conversion,
                                actual,
                                cursor
                            );
                            code = "E2S17";
                        } else {
                            int64_t argument = skip_trivia(
                                source,
                                token_end(source, open)
                            );
                            const char *argument_type = numeric_primary_type(
                                source,
                                hir,
                                function_open,
                                argument
                            );
                            if (
                                argument_type[0] != '\0' &&
                                strcmp(argument_type, "Int") != 0
                            ) {
                                buffer_format(
                                    &message,
                                    "error[E2S15]: builtin `%s` expects Int "
                                    "for argument 1, got %s at byte %" PRId64,
                                    conversion,
                                    argument_type,
                                    argument
                                );
                                code = "E2S15";
                                span = argument;
                            } else if (valid_conversion < 0) {
                                valid_conversion = cursor;
                            }
                        }
                    }
                    free(conversion);
                    if (code != NULL) {
                        stage2_diagnostic_set(
                            code,
                            span,
                            token_end(source, span),
                            true,
                            message.data
                        );
                        return message.data;
                    }
                    free(message.data);
                }
                cursor = skip_trivia(source, token_end(source, cursor));
            }
        }
        function_start = next_function_start(source, function_close);
    }
    (void)valid_conversion;
    return owned_text("ok");
}

/* Validate the explicit Decimal slice-5 member surface. */
static char *validate_decimal_slice5_members(
    const char *source,
    const char *hir
) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t function_open = parameters >= 0
            ? balanced_end(source, parameters, "(", ")")
            : -1;
        if (function_open >= 0) {
            int64_t cursor = skip_trivia(source, function_open);
            while (cursor < function_close) {
                char *member = numeric_conversion_at(source, cursor);
                bool slice5 =
                    strcmp(member, "Decimal.round") == 0 ||
                    strcmp(member, "Decimal.divide") == 0 ||
                    strcmp(member, "Decimal.format") == 0 ||
                    strcmp(member, "Decimal.parse") == 0;
                if (slice5) {
                    int64_t dot = skip_trivia(
                        source,
                        token_end(source, cursor)
                    );
                    int64_t name = skip_trivia(
                        source,
                        token_end(source, dot)
                    );
                    int64_t open = skip_trivia(
                        source,
                        token_end(source, name)
                    );
                    int64_t expected_arity =
                        numeric_member_expected_arity(member);
                    int64_t actual_arity = call_arity(source, open);
                    if (actual_arity != expected_arity) {
                        Buffer message;
                        buffer_init(&message);
                        buffer_format(
                            &message,
                            "error[E2S17]: Core function `%s` expects "
                            "%" PRId64 " arguments, got %" PRId64
                            " at byte %" PRId64,
                            member,
                            expected_arity,
                            actual_arity,
                            cursor
                        );
                        stage2_diagnostic_set(
                            "E2S17",
                            cursor,
                            token_end(source, cursor),
                            true,
                            message.data
                        );
                        free(member);
                        return message.data;
                    }
                    int64_t mode_index = numeric_member_mode_index(member);
                    for (int64_t index = 0; index < expected_arity; ++index) {
                        int64_t argument = numeric_member_argument(
                            source,
                            open,
                            index
                        );
                        if (index == mode_index) {
                            char *mode = token_copy(source, argument);
                            bool valid =
                                strcmp(
                                    token_kind(source, argument),
                                    "identifier"
                                ) == 0 &&
                                decimal_rounding_mode_name(mode);
                            free(mode);
                            if (!valid) {
                                Buffer message;
                                buffer_init(&message);
                                buffer_format(
                                    &message,
                                    "error[E2S15]: builtin `%s` expects "
                                    "HalfUp, HalfEven, TowardZero, Floor, "
                                    "or Ceiling for argument %" PRId64
                                    " at byte %" PRId64,
                                    member,
                                    index + 1,
                                    argument
                                );
                                stage2_diagnostic_set(
                                    "E2S15",
                                    argument,
                                    token_end(source, argument),
                                    true,
                                    message.data
                                );
                                free(member);
                                return message.data;
                            }
                        } else {
                            const char *expected =
                                numeric_member_expected_type(member, index);
                            char *actual = initializer_type(
                                source,
                                hir,
                                function_open,
                                argument
                            );
                            if (
                                expected[0] != '\0' &&
                                strcmp(actual, expected) != 0
                            ) {
                                Buffer message;
                                buffer_init(&message);
                                buffer_format(
                                    &message,
                                    "error[E2S15]: builtin `%s` expects %s "
                                    "for argument %" PRId64 ", got %s at "
                                    "byte %" PRId64,
                                    member,
                                    expected,
                                    index + 1,
                                    actual,
                                    argument
                                );
                                stage2_diagnostic_set(
                                    "E2S15",
                                    argument,
                                    token_end(source, argument),
                                    true,
                                    message.data
                                );
                                free(actual);
                                free(member);
                                return message.data;
                            }
                            free(actual);
                        }
                    }
                }
                free(member);
                cursor = skip_trivia(source, token_end(source, cursor));
            }
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

/*
 * Validate every fractional literal against the versioned profile before
 * lowering. Runtime construction repeats the same check, but doing it here is
 * what keeps D001/D002 source-located and prevents an output artifact from
 * being written for a statically over-limit program.
 */
static char *validate_numeric_literals(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        const char *kind = token_kind(source, cursor);
        bool decimal = strcmp(kind, "decimal") == 0;
        if (decimal || strcmp(kind, "float") == 0) {
            int64_t end = token_end(source, cursor);
            /*
             * Construct the value here, even though nothing consumes it yet.
             * That is what puts the profile's limits at the literal's own byte
             * instead of leaving them a library concern: #710's frozen decision
             * 8 requires them to be cross-backend *observable*, and a limit
             * nothing reaches is not observable at all.
             */
            size_t literal_length = (size_t)(end - cursor);
            KofunDecimalStatus status;
            if (decimal) {
                KofunDecimal value;
                status = kofun_decimal_from_literal(
                    source + cursor,
                    literal_length,
                    &value
                );
                kofun_decimal_free(&value);
            } else {
                /* The `f64` suffix is part of the token but not of the
                 * number. */
                double ignored = 0.0;
                status = kofun_float_from_literal(
                    source + cursor,
                    literal_length >= 3 ? literal_length - 3 : 0,
                    &ignored
                );
            }

            Buffer message;
            buffer_init(&message);
            if (status != KOFUN_DECIMAL_OK) {
                buffer_format(
                    &message,
                    "%s at byte %" PRId64,
                    kofun_decimal_status_message(status),
                    cursor
                );
                stage2_diagnostic_set(
                    kofun_decimal_status_code(status),
                    cursor,
                    end,
                    true,
                    message.data
                );
                return message.data;
            }
            free(message.data);
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return owned_text("ok");
}

static bool source_uses_fractional_values(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, 0);
    while (cursor < length) {
        const char *kind = token_kind(source, cursor);
        if (
            strcmp(kind, "decimal") == 0 ||
            strcmp(kind, "float") == 0 ||
            numeric_conversion_head(source, cursor)
        ) {
            return true;
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

static int64_t record_align_up(int64_t value, int64_t alignment) {
    int64_t remainder = value % alignment;
    return remainder == 0 ? value : value + alignment - remainder;
}

/* The struct, its field offsets, and its size for one emitted type. The field
 * list comes from the declaration, so every instantiation of one declaration
 * has the same layout — which is exactly why `validate_const_erasure` must
 * keep a const argument out of a field type. */
static char *emit_record_c_declaration(
    const char *source,
    const char *record_type,
    const char *c_type
) {
    Buffer declarations;
    buffer_init(&declarations);
    {
        {
            int64_t fields = record_field_count(source, record_type);
            int64_t extent = 0;
            int64_t record_alignment = 1;
            buffer_append(&declarations, "typedef struct {\n");
            for (int64_t index = 0; index < fields; ++index) {
                char *field = record_field_text(
                    source,
                    record_type,
                    index,
                    false
                );
                char *field_type = record_field_text(
                    source,
                    record_type,
                    index,
                    true
                );
                char *c_field = record_c_field_name(field);
                const char *c_field_type =
                    strcmp(field_type, "Bool") == 0 ? "bool" : "int64_t";
                int64_t field_size =
                    strcmp(field_type, "Bool") == 0 ? 1 : 8;
                int64_t field_alignment = field_size;
                int64_t offset = record_align_up(
                    extent,
                    field_alignment
                );
                if (field_alignment > record_alignment) {
                    record_alignment = field_alignment;
                }
                extent = offset + field_size;
                buffer_format(
                    &declarations,
                    "    %s %s;\n",
                    c_field_type,
                    c_field
                );
                free(c_field);
                free(field_type);
                free(field);
            }
            buffer_format(&declarations, "} %s;\n", c_type);
            extent = record_align_up(extent, record_alignment);
            int64_t running = 0;
            for (int64_t index = 0; index < fields; ++index) {
                char *field = record_field_text(
                    source,
                    record_type,
                    index,
                    false
                );
                char *field_type = record_field_text(
                    source,
                    record_type,
                    index,
                    true
                );
                char *c_field = record_c_field_name(field);
                int64_t field_size =
                    strcmp(field_type, "Bool") == 0 ? 1 : 8;
                int64_t offset = record_align_up(running, field_size);
                buffer_format(
                    &declarations,
                    "_Static_assert(offsetof(%s, %s) == %" PRId64
                    ", \"AggregateLayout field offset\");\n",
                    c_type,
                    c_field,
                    offset
                );
                running = offset + field_size;
                free(c_field);
                free(field_type);
                free(field);
            }
            buffer_format(
                &declarations,
                "_Static_assert(sizeof(%s) == %" PRId64
                ", \"AggregateLayout record size\");\n\n",
                c_type,
                extent
            );
        }
    }
    return declarations.data;
}

/* One struct per emitted type. A const-parameterized declaration produces one
 * per distinct literal, which is the specialization itself; every other record
 * produces exactly one, as before. */
static char *emit_record_c_declarations(const char *source) {
    int64_t length = (int64_t)strlen(source);
    int64_t cursor = after_optional_module_header(source, 0);
    Buffer declarations;
    buffer_init(&declarations);
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (
            type_start >= 0 &&
            record_declaration_at(source, type_start)
        ) {
            char *record_type = type_name(source, type_start);
            char *parameter = const_parameter_name(source, type_start);
            if (parameter[0] != '\0') {
                int64_t total = const_instantiation_count(source, record_type);
                for (int64_t instance = 0; instance < total; ++instance) {
                    char *identity = const_instantiation_at(
                        source,
                        record_type,
                        instance
                    );
                    char *c_type = record_c_type_name(identity);
                    char *emitted = emit_record_c_declaration(
                        source,
                        record_type,
                        c_type
                    );
                    buffer_append(&declarations, emitted);
                    free(emitted);
                    free(c_type);
                    free(identity);
                }
            } else {
                char *c_type = record_c_type_name(record_type);
                char *emitted = emit_record_c_declaration(
                    source,
                    record_type,
                    c_type
                );
                buffer_append(&declarations, emitted);
                free(emitted);
                free(c_type);
            }
            free(parameter);
            free(record_type);
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) break;
        cursor = skip_trivia(source, end);
    }
    return declarations.data;
}

/*
 * #572: `compiler.ensure_move(value)` — the unstable compile-time move
 * assertion. docs/MEMORY_MODEL.md §14 records the distinction it serves:
 * semantic `take` is an observable ownership transfer, while moving a
 * managed value is an optimization the compiler may perform. This assertion
 * turns "may" into a compile-time obligation without adding any runtime
 * behavior — the statement produces no value, is erased before C is
 * emitted, and compilation fails with an explained reason when the proof
 * does not hold.
 *
 * The rule is deliberately the narrowest sound one this slice can decide.
 * The argument must be an immutable local binding of a managed type
 * (`Text` or `List`), asserted in the binding's own scope, with no use at
 * any later byte, no use inside a lambda, and no earlier read that could
 * have created an alias of the storage. Every rejection names its reason in
 * the issue's vocabulary: later use, possible alias, branch mismatch,
 * escaping capture, or backend limitation. `unknown foreign call` is
 * reserved: this slice can express no foreign call to blame.
 */

static char *move_assertion_fail(
    const char *source,
    Buffer *message,
    int64_t primary,
    int64_t related
) {
    stage2_diagnostic_set(
        "E2S146",
        primary,
        token_end(source, primary),
        true,
        message->data
    );
    if (related >= 0) {
        stage2_diagnostic_related(
            related,
            token_end(source, related),
            "conflicting use"
        );
    }
    return message->data;
}

/*
 * Walks the scope parent chain from `from_scope` to `to_scope`, recording
 * which scope kinds the chain crosses before arriving. Returns false when
 * `to_scope` is not an ancestor, leaving the flags valid for the whole
 * chain.
 */
static bool move_assertion_scope_reaches(
    const char *hir,
    const char *from_scope,
    const char *to_scope,
    bool *crosses_lambda,
    bool *crosses_branch,
    bool *crosses_block,
    char **innermost_branch
) {
    char *scope = owned_text(from_scope);
    while (scope[0] != '\0' && strcmp(scope, "-1") != 0) {
        if (strcmp(scope, to_scope) == 0) {
            free(scope);
            return true;
        }
        char *kind = hir_scope_field(hir, scope, 3);
        if (strcmp(kind, "lambda-parameters") == 0) {
            *crosses_lambda = true;
        } else if (
            strcmp(kind, "if-then") == 0 ||
            strcmp(kind, "if-else") == 0 ||
            strcmp(kind, "match-arm") == 0
        ) {
            if (innermost_branch != NULL && *innermost_branch == NULL) {
                *innermost_branch = owned_text(scope);
            }
            *crosses_branch = true;
        } else if (strcmp(kind, "block") == 0) {
            *crosses_block = true;
        }
        free(kind);
        char *parent = hir_scope_field(hir, scope, 2);
        free(scope);
        scope = parent;
    }
    free(scope);
    return false;
}

/*
 * #904: true when every path from `after` to `limit` leaves the function
 * through `return`, so control cannot fall out of the enclosing arm's closing
 * brace and reach a point where the outer binding is still observable.
 *
 * The walk is over statements rather than bytes, because source order alone
 * proves nothing here: a `return` that is merely the textually last thing in
 * the arm is not a terminator when an `if` without a terminal `else` can still
 * reach the brace, and a `return` nested inside such an `if` is not the arm's
 * terminator at all. An `if` terminates only when both of its arms do, which
 * is the same obligation `sl_emit_statement` discharges on the self-host path.
 *
 * Loops are refused outright rather than analysed. A loop can re-enter the arm
 * and read the binding again, and proving a loop-local last use is #915, not
 * this slice. A bare block is refused for the same reason in miniature: this
 * slice can say nothing about what follows it.
 */
static bool move_assertion_arm_terminates(
    const char *source,
    int64_t after,
    int64_t limit
) {
    int64_t length = source_length(source);
    int64_t cursor = skip_trivia(source, after);
    while (cursor < length && cursor < limit) {
        if (token_equal(source, cursor, "}")) return false;
        if (token_equal(source, cursor, "return")) return true;
        if (
            token_equal(source, cursor, "while") ||
            token_equal(source, cursor, "for") ||
            token_equal(source, cursor, "{")
        ) {
            return false;
        }
        if (token_equal(source, cursor, "if")) {
            int64_t then_close = if_then_branch_end(source, cursor);
            int64_t whole = if_statement_end(source, cursor);
            if (
                then_close < 0 ||
                whole < 0 ||
                !if_has_else(source, cursor)
            ) {
                return false;
            }
            int64_t condition_start = skip_trivia(
                source,
                token_end(source, cursor)
            );
            int64_t then_open = skip_trivia(
                source,
                condition_end(source, condition_start)
            );
            int64_t else_keyword = skip_trivia(source, then_close);
            int64_t else_open = skip_trivia(
                source,
                token_end(source, else_keyword)
            );
            return move_assertion_arm_terminates(
                       source,
                       token_end(source, then_open),
                       then_close
                   ) &&
                   move_assertion_arm_terminates(
                       source,
                       token_end(source, else_open),
                       whole
                   );
        }
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    return false;
}

/*
 * True when a call to `name` provably keeps no alias of a managed argument.
 * With no globals and no escaping views in this slice, the only channel out
 * of a call is its result, so a callee whose result is a Copy value or no
 * value cannot extend the argument's storage. Everything unknown says no.
 */
static bool move_assertion_callee_is_alias_free(
    const char *source,
    const char *name
) {
    if (strcmp(name, "print") == 0) return true;
    if (strcmp(name, "ensure_move") == 0) return true;
    const char *builtin = builtin_return_type(name);
    if (builtin != NULL) {
        return strcmp(builtin, "Int") == 0 ||
               strcmp(builtin, "Bool") == 0 ||
               strcmp(builtin, "Void") == 0;
    }
    char *owner = enum_constructor_owner(source, name);
    bool constructor = owner[0] != '\0';
    free(owner);
    if (constructor || record_declaration_start(source, name) >= 0) {
        return false;
    }
    char *result = function_return_type(source, name);
    bool alias_free =
        strcmp(result, "Int") == 0 ||
        strcmp(result, "Bool") == 0 ||
        strcmp(result, "Void") == 0;
    free(result);
    return alias_free;
}

/*
 * True when the read at `use_start` provably creates no alias: it is one
 * operand of an equality comparison, or it sits inside a call whose callee
 * is alias-free per the rule above. A grouping parenthesis inherits the
 * verdict of the call it sits in; at statement depth it stays conservative,
 * because the read could be a whole initializer or return value there.
 */
static bool move_assertion_read_is_alias_free(
    const char *source,
    int64_t function_open,
    int64_t use_start
) {
    int64_t after = skip_trivia(source, token_end(source, use_start));
    if (
        token_equal(source, after, "==") ||
        token_equal(source, after, "!=")
    ) {
        return true;
    }
    bool alias_free_stack[64];
    int64_t depth = 0;
    int64_t previous = function_open;
    int64_t cursor = skip_trivia(source, token_end(source, function_open));
    while (cursor < use_start) {
        if (
            token_equal(source, cursor, "(") ||
            token_equal(source, cursor, "[")
        ) {
            bool alias_free = false;
            if (
                token_equal(source, cursor, "(") &&
                strcmp(token_kind(source, previous), "identifier") == 0
            ) {
                char *name = token_copy(source, previous);
                alias_free =
                    move_assertion_callee_is_alias_free(source, name);
                free(name);
            } else if (depth > 0 && depth <= 64) {
                alias_free = alias_free_stack[depth - 1];
            }
            if (depth < 64) alias_free_stack[depth] = alias_free;
            ++depth;
        } else if (
            token_equal(source, cursor, ")") ||
            token_equal(source, cursor, "]")
        ) {
            if (depth > 0) --depth;
        }
        previous = cursor;
        cursor = skip_trivia(source, token_end(source, cursor));
    }
    if (
        token_equal(source, previous, "==") ||
        token_equal(source, previous, "!=")
    ) {
        return true;
    }
    if (depth <= 0 || depth > 64) return false;
    return alias_free_stack[depth - 1];
}

/* True when the `take` whose target begins at `target` names a field rather
 * than the binding: `take value.field`, the partial move v1 refuses. */
static bool move_statement_partial(const char *source, int64_t target) {
    int64_t after = skip_trivia(source, token_end(source, target));
    return after < source_length(source) && token_equal(source, after, ".");
}

/* End of the `take` statement whose target begins at `target`. The whole
 * statement is what the move diagnostics underline, so a partial move
 * underlines the field access it refuses rather than stopping at the record. */
static int64_t move_statement_end(const char *source, int64_t target) {
    int64_t after;
    int64_t field;
    if (!move_statement_partial(source, target)) {
        return token_end(source, target);
    }
    after = skip_trivia(source, token_end(source, target));
    field = skip_trivia(source, token_end(source, after));
    if (field >= source_length(source)) return token_end(source, after);
    return token_end(source, field);
}

/* True when the identifier at `cursor`, whose preceding token began at
 * `previous`, reads the value a binding holds.
 *
 * Two spellings mention a name without reading it: `. name` is a field of some
 * other value, and `name :` introduces one — either a `let` that declares a
 * fresh binding or a labelled argument that names a field. Neither is a use, so
 * neither may be blamed on a move. */
static bool move_use_position(
    const char *source,
    int64_t previous,
    int64_t cursor
) {
    int64_t next;
    if (strcmp(token_kind(source, cursor), "identifier") != 0) return false;
    if (previous >= 0 && token_equal(source, previous, ".")) return false;
    next = skip_trivia(source, token_end(source, cursor));
    if (next < source_length(source) && token_equal(source, next, ":")) {
        return false;
    }
    return true;
}

/*
 * The earliest ownership finding in one function, in source order.
 *
 * The standalone record frontend refuses the first statement whose check
 * fails. This walk instead visits each `take` and then scans forward for the
 * mention that move invalidates, so its findings do not arrive in source
 * order. Keeping the one with the lowest primary span reorders them back:
 * primary spans of distinct statements cannot overlap, so the lowest is the
 * one the statement walk would have reached first.
 */
typedef struct {
    bool present;
    const char *code;
    int64_t primary_start;
    int64_t primary_end;
    int64_t related_start;
    int64_t related_end;
    const char *related_label;
    char *message;
} MoveFinding;

static void move_finding_keep(MoveFinding *best, MoveFinding candidate) {
    if (best->present && best->primary_start <= candidate.primary_start) {
        free(candidate.message);
        return;
    }
    free(best->message);
    *best = candidate;
}

/*
 * Whole-binding move analysis for the compiler a user actually runs (#946).
 *
 * The bounded slice this issue scopes: `take <binding>`, the move's own span
 * recorded, and any later mention of that binding refused with the use site
 * primary and the move site attached. Loops, branches, and inferred moves stay
 * out — #915 and #922 own those, and a rule that guessed at control flow would
 * refuse programs this one has no business refusing.
 *
 * Conservative in the other direction too: a binding moved on one path and used
 * on another is not proved safe here, it is simply not this slice's subject.
 * `compiler.ensure_move` remains the way to demand the guarantee.
 *
 * Three of the standalone record frontend's four ownership refusals are
 * reproduced here, with its exact wording: partial move, second move, and
 * use-after-move. E2S122 for moving a `read` binding remains outside this
 * bounded source-order validator; ownership-mode parameters themselves now
 * bind through the production HIR and lowering path (#881).
 */
static char *validate_move_uses(const char *source) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        MoveFinding best;
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = parameters < 0 ? -1 :
            balanced_end(source, parameters, "(", ")");
        if (function_close < 0 || parameters_close < 0) break;
        memset(&best, 0, sizeof(best));
        int64_t body = skip_trivia(source, parameters_close);
        while (body < function_close && !token_equal(source, body, "{")) {
            body = skip_trivia(source, token_end(source, body));
        }
        int64_t scan = skip_trivia(source, token_end(source, body));
        while (scan < function_close) {
            if (move_statement_head(source, scan)) {
                int64_t target = skip_trivia(source, token_end(source, scan));
                int64_t move_start = scan;
                int64_t move_end = move_statement_end(source, target);
                char *moved;
                if (move_statement_partial(source, target)) {
                    int64_t dot = skip_trivia(source, token_end(source, target));
                    char *field = token_copy(
                        source, skip_trivia(source, token_end(source, dot))
                    );
                    MoveFinding candidate;
                    Buffer error;
                    memset(&candidate, 0, sizeof(candidate));
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S122]: partial move `take value.%s` is "
                        "rejected in v1; move the whole record instead at "
                        "bytes %" PRId64 "..%" PRId64,
                        field, move_start, move_end
                    );
                    candidate.present = true;
                    candidate.code = "E2S122";
                    candidate.primary_start = move_start;
                    candidate.primary_end = move_end;
                    candidate.message = error.data;
                    move_finding_keep(&best, candidate);
                    free(field);
                    scan = skip_trivia(source, move_end);
                    continue;
                }
                moved = token_copy(source, target);
                int64_t previous = -1;
                int64_t use = skip_trivia(source, move_end);
                while (use < function_close) {
                    if (move_statement_head(source, use)) {
                        int64_t again = skip_trivia(
                            source, token_end(source, use)
                        );
                        /* A partial move is refused for being partial before
                         * anything asks whether its record still holds a
                         * value, so this scan leaves that statement to the
                         * `E2S122` branch above rather than claiming it. */
                        if (move_statement_partial(source, again)) break;
                        if (token_equal(source, again, moved)) {
                            MoveFinding candidate;
                            Buffer error;
                            int64_t again_end =
                                move_statement_end(source, again);
                            memset(&candidate, 0, sizeof(candidate));
                            buffer_init(&error);
                            buffer_format(
                                &error,
                                "error[E2S123]: `%s` was already moved by "
                                "`take` at bytes %" PRId64 "..%" PRId64
                                "; first moved by `take` at bytes %" PRId64
                                "..%" PRId64,
                                moved, use, again_end, move_start, move_end
                            );
                            candidate.present = true;
                            candidate.code = "E2S123";
                            candidate.primary_start = use;
                            candidate.primary_end = again_end;
                            candidate.related_start = move_start;
                            candidate.related_end = move_end;
                            candidate.related_label = "first moved by `take`";
                            candidate.message = error.data;
                            move_finding_keep(&best, candidate);
                            break;
                        }
                        previous = again;
                        use = skip_trivia(source, token_end(source, again));
                        continue;
                    }
                    if (move_use_position(source, previous, use) &&
                        token_equal(source, use, moved)) {
                        MoveFinding candidate;
                        Buffer error;
                        memset(&candidate, 0, sizeof(candidate));
                        buffer_init(&error);
                        buffer_format(
                            &error,
                            "error[E2S123]: `%s` was moved by `take` and "
                            "cannot be used again at bytes %" PRId64
                            "..%" PRId64 "; moved by `take` at bytes %"
                            PRId64 "..%" PRId64,
                            moved, use, token_end(source, use),
                            move_start, move_end
                        );
                        candidate.present = true;
                        candidate.code = "E2S123";
                        candidate.primary_start = use;
                        candidate.primary_end = token_end(source, use);
                        candidate.related_start = move_start;
                        candidate.related_end = move_end;
                        candidate.related_label = "moved by `take`";
                        candidate.message = error.data;
                        move_finding_keep(&best, candidate);
                        break;
                    }
                    previous = use;
                    use = skip_trivia(source, token_end(source, use));
                }
                free(moved);
                scan = skip_trivia(source, move_end);
                continue;
            }
            scan = skip_trivia(source, token_end(source, scan));
        }
        if (best.present) {
            stage2_diagnostic_set(
                best.code, best.primary_start, best.primary_end,
                true, best.message
            );
            /* The move site turns "you cannot use this" into "you cannot use
             * this *because of that line*". The registry records the secondary
             * span as required for E2S123 and not-applicable for E2S122. */
            if (best.related_label != NULL) {
                stage2_diagnostic_related(
                    best.related_start, best.related_end, best.related_label
                );
            }
            return best.message;
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

static char *validate_move_assertions(const char *source, const char *hir) {
    int64_t length = source_length(source);
    int64_t function_start = next_function_start(source, 0);
    while (function_start < length) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = parameters < 0 ?
            -1 : balanced_end(source, parameters, "(", ")");
        if (parameters_close < 0) {
            function_start = next_function_start(source, function_close);
            continue;
        }
        int64_t function_open = skip_trivia(source, parameters_close);
        while (
            function_open < function_close &&
            !token_equal(source, function_open, "{")
        ) {
            function_open = skip_trivia(
                source,
                token_end(source, function_open)
            );
        }
        int64_t previous = function_open;
        int64_t depth = 0;
        int64_t cursor = skip_trivia(
            source,
            token_end(source, function_open)
        );
        while (cursor < function_close) {
            if (!move_assertion_head(source, cursor)) {
                if (
                    token_equal(source, cursor, "(") ||
                    token_equal(source, cursor, "[")
                ) {
                    ++depth;
                } else if (
                    token_equal(source, cursor, ")") ||
                    token_equal(source, cursor, "]")
                ) {
                    if (depth > 0) --depth;
                }
                previous = cursor;
                cursor = skip_trivia(source, token_end(source, cursor));
                continue;
            }
            /*
             * Same statement-position test the condition validator uses: a
             * statement begins after `{`, `}`, `else`, or a newline — and
             * never inside an open parenthesis, which covers a multi-line
             * argument list.
             */
            bool statement_context =
                depth == 0 &&
                (token_equal(source, previous, "{") ||
                 token_equal(source, previous, "}") ||
                 token_equal(source, previous, "else") ||
                 newline_between(
                     source,
                     token_end(source, previous),
                     cursor
                 ));
            if (!statement_context) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move` is "
                    "compile-time only and has no value here at byte "
                    "%" PRId64,
                    cursor
                );
                return move_assertion_fail(source, &message, cursor, -1);
            }
            int64_t dot = skip_trivia(source, token_end(source, cursor));
            int64_t member = skip_trivia(source, token_end(source, dot));
            int64_t open = skip_trivia(source, token_end(source, member));
            int64_t argument = skip_trivia(source, token_end(source, open));
            int64_t close = argument < length ?
                skip_trivia(source, token_end(source, argument)) : length;
            if (
                open >= function_close ||
                !token_equal(source, open, "(") ||
                argument >= function_close ||
                strcmp(token_kind(source, argument), "identifier") != 0 ||
                close >= function_close ||
                !token_equal(source, close, ")")
            ) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move` takes "
                    "exactly one local binding or parameter name at byte "
                    "%" PRId64,
                    cursor
                );
                return move_assertion_fail(source, &message, cursor, -1);
            }
            char *argument_name = token_copy(source, argument);
            char *binding_id = hir_use_binding_id(hir, argument);
            if (binding_id[0] == '\0' || strcmp(binding_id, "-1") == 0) {
                Buffer message;
                buffer_init(&message);
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move`: `%s` "
                    "names no local storage identity (backend limitation) "
                    "at byte %" PRId64,
                    argument_name,
                    argument
                );
                free(binding_id);
                free(argument_name);
                return move_assertion_fail(source, &message, argument, -1);
            }
            char *binding_scope = hir_binding_field(hir, binding_id, 2);
            char *mutability = hir_binding_field(hir, binding_id, 4);
            char *binding_type = hir_binding_field(hir, binding_id, 5);
            char *scope_kind = hir_scope_field(hir, binding_scope, 3);
            char *use_scope = hir_index_field_number(hir, 'u', argument, 3);
            char *failure = NULL;
            Buffer message;
            buffer_init(&message);
            if (
                strcmp(scope_kind, "parameters") == 0 ||
                strcmp(scope_kind, "lambda-parameters") == 0
            ) {
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move`: "
                    "parameter `%s` is borrowed from the caller (possible "
                    "alias) at byte %" PRId64,
                    argument_name,
                    argument
                );
                failure = move_assertion_fail(
                    source,
                    &message,
                    argument,
                    -1
                );
            } else if (strcmp(mutability, "immutable") != 0) {
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move`: `%s` "
                    "is mutable, so its storage can be re-bound (backend "
                    "limitation) at byte %" PRId64,
                    argument_name,
                    argument
                );
                failure = move_assertion_fail(
                    source,
                    &message,
                    argument,
                    -1
                );
            } else if (
                strcmp(binding_type, "Text") != 0 &&
                strcmp(binding_type, "List") != 0
            ) {
                buffer_format(
                    &message,
                    "error[E2S146]: unstable `compiler.ensure_move`: `%s` "
                    "has Copy type `%s`, not managed storage (backend "
                    "limitation) at byte %" PRId64,
                    argument_name,
                    binding_type,
                    argument
                );
                failure = move_assertion_fail(
                    source,
                    &message,
                    argument,
                    -1
                );
            }
            /* Any use inside a lambda — including this one — escapes. */
            int64_t use_line = failure != NULL ?
                -1 : hir_record_start(hir, "use", 0);
            while (use_line >= 0) {
                char *use_binding = hir_field(hir, use_line, 4);
                if (strcmp(use_binding, binding_id) == 0) {
                    char *start_text = hir_field(hir, use_line, 1);
                    char *this_scope = hir_field(hir, use_line, 3);
                    int64_t use_start = decimal_value(start_text);
                    bool lambda = false;
                    bool branch = false;
                    bool block = false;
                    move_assertion_scope_reaches(
                        hir,
                        this_scope,
                        binding_scope,
                        &lambda,
                        &branch,
                        &block,
                        NULL
                    );
                    if (lambda) {
                        buffer_format(
                            &message,
                            "error[E2S146]: unstable "
                            "`compiler.ensure_move`: `%s` is captured by a "
                            "lambda at byte %" PRId64 " (escaping capture) "
                            "at byte %" PRId64,
                            argument_name,
                            use_start,
                            argument
                        );
                        failure = move_assertion_fail(
                            source,
                            &message,
                            argument,
                            use_start
                        );
                    }
                    free(this_scope);
                    free(start_text);
                }
                free(use_binding);
                use_line = failure != NULL ?
                    -1 : hir_record_start(hir, "use", use_line);
            }
            /* The assertion itself must sit in the binding's own scope. */
            if (failure == NULL) {
                bool lambda = false;
                bool branch = false;
                bool block = false;
                char *branch_scope = NULL;
                move_assertion_scope_reaches(
                    hir,
                    use_scope,
                    binding_scope,
                    &lambda,
                    &branch,
                    &block,
                    &branch_scope
                );
                /*
                 * #904: an assertion inside a conditional arm is sound when
                 * that arm is terminal, because control then leaves the
                 * function rather than returning to a point where the outer
                 * binding is still observable. A loop anywhere on the scope
                 * chain still refuses: it can re-enter the arm.
                 */
                if (branch && !block && branch_scope != NULL) {
                    char *arm_close = hir_scope_field(hir, branch_scope, 5);
                    if (
                        move_assertion_arm_terminates(
                            source,
                            token_end(source, close),
                            decimal_value(arm_close)
                        )
                    ) {
                        branch = false;
                    }
                    free(arm_close);
                }
                free(branch_scope);
                if (branch) {
                    buffer_format(
                        &message,
                        "error[E2S146]: unstable `compiler.ensure_move`: "
                        "the assertion is inside a conditional arm that "
                        "`%s` outlives (branch mismatch) at byte %" PRId64,
                        argument_name,
                        argument
                    );
                    failure = move_assertion_fail(
                        source,
                        &message,
                        argument,
                        -1
                    );
                } else if (block) {
                    buffer_format(
                        &message,
                        "error[E2S146]: unstable `compiler.ensure_move`: "
                        "an enclosing loop or block can repeat this read "
                        "of `%s` (later use) at byte %" PRId64,
                        argument_name,
                        argument
                    );
                    failure = move_assertion_fail(
                        source,
                        &message,
                        argument,
                        -1
                    );
                }
            }
            /* No use at any later byte, in any scope. */
            use_line = failure != NULL ?
                -1 : hir_record_start(hir, "use", 0);
            while (use_line >= 0) {
                char *use_binding = hir_field(hir, use_line, 4);
                if (strcmp(use_binding, binding_id) == 0) {
                    char *start_text = hir_field(hir, use_line, 1);
                    int64_t use_start = decimal_value(start_text);
                    if (use_start > argument) {
                        buffer_format(
                            &message,
                            "error[E2S146]: unstable "
                            "`compiler.ensure_move`: `%s` is used again "
                            "at byte %" PRId64 " (later use) at byte "
                            "%" PRId64,
                            argument_name,
                            use_start,
                            argument
                        );
                        failure = move_assertion_fail(
                            source,
                            &message,
                            argument,
                            use_start
                        );
                    }
                    free(start_text);
                }
                free(use_binding);
                use_line = failure != NULL ?
                    -1 : hir_record_start(hir, "use", use_line);
            }
            /* Every earlier read must be provably alias-free. */
            use_line = failure != NULL ?
                -1 : hir_record_start(hir, "use", 0);
            while (use_line >= 0) {
                char *use_binding = hir_field(hir, use_line, 4);
                if (strcmp(use_binding, binding_id) == 0) {
                    char *start_text = hir_field(hir, use_line, 1);
                    int64_t use_start = decimal_value(start_text);
                    if (
                        use_start < argument &&
                        !move_assertion_read_is_alias_free(
                            source,
                            function_open,
                            use_start
                        )
                    ) {
                        buffer_format(
                            &message,
                            "error[E2S146]: unstable "
                            "`compiler.ensure_move`: the read of `%s` at "
                            "byte %" PRId64 " may create an alias "
                            "(possible alias) at byte %" PRId64,
                            argument_name,
                            use_start,
                            argument
                        );
                        failure = move_assertion_fail(
                            source,
                            &message,
                            argument,
                            use_start
                        );
                    }
                    free(start_text);
                }
                free(use_binding);
                use_line = failure != NULL ?
                    -1 : hir_record_start(hir, "use", use_line);
            }
            free(use_scope);
            free(scope_kind);
            free(binding_type);
            free(mutability);
            free(binding_scope);
            free(binding_id);
            free(argument_name);
            if (failure != NULL) return failure;
            free(message.data);
            previous = close;
            cursor = skip_trivia(source, token_end(source, close));
        }
        function_start = next_function_start(source, function_close);
    }
    return owned_text("ok");
}

/* The proposition that failed once, now with a gate instead of a comment.
 *
 * Distinct type identities must reach distinct emitted structs. `Fixed[2]` and
 * `Fixed[3]` are different Kofun types, so if they lowered to one C struct the
 * C type system would stop separating what the Kofun type system had already
 * separated — which is exactly what an earlier revision did, under a comment
 * arguing it was safe because a const parameter carries no storage. That
 * argument was about miscompiles; this is about identity, and only one of the
 * two was ever checked.
 *
 * It also catches the collision from the other direction: a declared record
 * whose own name is the C name some instantiation generates. */
static char *validate_struct_identity(const char *source) {
    int64_t length = source_length(source);
    int64_t cursor = after_optional_module_header(source, 0);
    Buffer names;
    buffer_init(&names);
    buffer_append(&names, "|");
    while (cursor < length) {
        int64_t type_start = type_declaration_start(source, cursor);
        if (type_start >= 0 && record_declaration_at(source, type_start)) {
            char *record_type = type_name(source, type_start);
            char *parameter = const_parameter_name(source, type_start);
            bool parameterized = parameter[0] != '\0';
            int64_t total = parameterized
                ? const_instantiation_count(source, record_type)
                : 1;
            free(parameter);
            for (int64_t instance = 0; instance < total; ++instance) {
                char *identity = parameterized
                    ? const_instantiation_at(source, record_type, instance)
                    : owned_text(record_type);
                char *c_type = record_c_type_name(identity);
                if (enum_name_covered(names.data, c_type)) {
                    Buffer error;
                    buffer_init(&error);
                    buffer_format(
                        &error,
                        "error[E2S153]: `%s` lowers to `%s`, which another "
                        "type already lowers to at byte %" PRId64,
                        identity,
                        c_type,
                        type_start
                    );
                    free(c_type);
                    free(identity);
                    free(record_type);
                    free(names.data);
                    return const_generic_refusal(&error);
                }
                buffer_append(&names, c_type);
                buffer_append(&names, "|");
                free(c_type);
                free(identity);
            }
            free(record_type);
        }
        int64_t end = top_level_end(source, cursor);
        if (end <= cursor) break;
        cursor = skip_trivia(source, end);
    }
    free(names.data);
    return owned_text("");
}

/*
 * Bound the number of syntactic Text-producing sites before writing C. The
 * scan skips emitted C string literals: a Kofun string containing a helper's
 * spelling is data, not a temporary site. Dynamic executions have a separate
 * non-wrapping arena limit in the emitted runtime.
 */
static int64_t count_text_sites(const char *bodies) {
    static const char *calls[] = {
        "kofun_text_slice(",
        "kofun_to_text(",
        "kofun_text_concat(",
    };
    int64_t site_count = 0;
    bool quoted = false;
    bool escaped = false;
    size_t cursor = 0;
    while (bodies[cursor] != '\0') {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (bodies[cursor] == '\\') {
                escaped = true;
            } else if (bodies[cursor] == '"') {
                quoted = false;
            }
            ++cursor;
            continue;
        }
        if (bodies[cursor] == '"') {
            quoted = true;
            ++cursor;
            continue;
        }
        size_t width = 0;
        for (size_t index = 0; index < sizeof calls / sizeof calls[0]; ++index) {
            size_t candidate = strlen(calls[index]);
            if (strncmp(bodies + cursor, calls[index], candidate) == 0) {
                width = candidate;
                break;
            }
        }
        if (width > 0) {
            ++site_count;
            cursor += width;
        } else {
            ++cursor;
        }
    }
    return site_count;
}

static char *lower_c_body(const char *source, const char *hir) {
    int64_t length = source_length(source);
    char *identity_check = validate_struct_identity(source);
    if (identity_check[0] != '\0') return identity_check;
    free(identity_check);
    bool fractional_values = source_uses_fractional_values(source);
    /* #946: the move rule runs before the assertion, so a use-after-move is
     * reported as itself rather than as whatever the erased statement leaves
     * behind. */
    char *move_use_check = validate_move_uses(source);
    if (strncmp(move_use_check, "error[", 6) == 0) return move_use_check;
    free(move_use_check);
    /* Before every remaining validator: a program that asks for the
     * move guarantee must hear the assertion's own verdict, not a
     * diagnostic about tokens the erased statement happens to contain. */
    char *move_check = validate_move_assertions(source, hir);
    if (strncmp(move_check, "error[", 6) == 0) return move_check;
    free(move_check);
    /* A mixed-type expression is reported before operator lowering, so
     * `1 + 1.5` names the missing explicit conversion. */
    char *operand_check = validate_numeric_operand_types(source, hir);
    if (strncmp(operand_check, "error[", 6) == 0) return operand_check;
    free(operand_check);
    char *fractional_operator_check = validate_fractional_operators(
        source,
        hir
    );
    if (strncmp(fractional_operator_check, "error[", 6) == 0) {
        return fractional_operator_check;
    }
    free(fractional_operator_check);
    /* After the operand check, so `let x: Int = 1 + 1.5` reports the mix it
     * contains rather than blaming the annotation for a value that has no
     * single type to compare against. */
    char *annotation_check = validate_numeric_annotations(source, hir);
    if (strncmp(annotation_check, "error[", 6) == 0) return annotation_check;
    free(annotation_check);
    /* After the annotation check, because a conversion is the remedy an
     * annotation mismatch asks for: `let x: Decimal = 1` should say what is
     * wrong with the value, not refuse the conversion the fix would introduce. */
    char *conversion_check = validate_numeric_conversions(source, hir);
    if (strncmp(conversion_check, "error[", 6) == 0) return conversion_check;
    free(conversion_check);
    char *decimal_member_check = validate_decimal_slice5_members(source, hir);
    if (strncmp(decimal_member_check, "error[", 6) == 0) {
        return decimal_member_check;
    }
    free(decimal_member_check);
    char *numeric_kind_check = validate_numeric_literals(source);
    if (strncmp(numeric_kind_check, "error[", 6) == 0) {
        return numeric_kind_check;
    }
    free(numeric_kind_check);
    char *enum_use_check = validate_enum_uses(source, hir);
    if (strncmp(enum_use_check, "error[", 6) == 0) {
        return enum_use_check;
    }
    free(enum_use_check);
    char *record_use_check = validate_record_uses(source);
    if (strncmp(record_use_check, "error[", 6) == 0) {
        return record_use_check;
    }
    free(record_use_check);
    char *optional_coalescing_check = validate_optional_int_coalescing(
        source,
        hir
    );
    if (strncmp(optional_coalescing_check, "error[", 6) == 0) {
        return optional_coalescing_check;
    }
    free(optional_coalescing_check);
    /* #924: before any C exists, so an `Int?` read without a proved tag is a
     * refusal here rather than a payload the backend was free to invent. */
    char *optional_use_check = validate_optional_uses(source);
    if (strncmp(optional_use_check, "error[", 6) == 0) {
        return optional_use_check;
    }
    free(optional_use_check);
    /* Scope HIR is complete before this lowering refusal, preserving partial
     * scope facts for semantic-event consumers while compile still reports
     * the exact unsupported-list E2S157 and publishes no C. */
    char *list_annotation_check = validate_list_int_annotations(source);
    if (strncmp(list_annotation_check, "error[", 6) == 0) {
        return list_annotation_check;
    }
    free(list_annotation_check);
    char *type_check = validate_core_types(source, hir);
    if (strncmp(type_check, "error[", 6) == 0) return type_check;
    free(type_check);
    char *call_check = validate_core_calls(source, hir);
    if (strncmp(call_check, "error[", 6) == 0) return call_check;
    free(call_check);
    char *list_lambda_check = validate_list_int_lambda_uses(source, hir);
    if (strncmp(list_lambda_check, "error[", 6) == 0) {
        return list_lambda_check;
    }
    free(list_lambda_check);
    char *capture_check = validate_argument_lambda_captures(source, hir);
    if (strncmp(capture_check, "error[", 6) == 0) return capture_check;
    free(capture_check);

    Buffer prototypes;
    Buffer bodies;
    buffer_init(&prototypes);
    buffer_init(&bodies);
    /* Module constants come first: every function may read them, and a C file
     * scope constant must be declared before its first use. */
    int64_t constant_cursor = next_constant_start(source, 0);
    while (constant_cursor < length) {
        char *declared = constant_name(source, constant_cursor);
        char *identifier = c_identifier_name(declared);
        char *lowered = constant_c_name(identifier);
        char *value = constant_value_text(source, constant_cursor);
        buffer_format(
            &prototypes,
            "static const int64_t %s = %s;\n",
            lowered,
            value
        );
        free(value);
        free(lowered);
        free(identifier);
        free(declared);
        int64_t constant_close = constant_declaration_end(
            source,
            constant_cursor
        );
        if (constant_close < 0) break;
        constant_cursor = next_constant_start(source, constant_close);
    }
    /* Lifted lambdas come first so a Core function can call one that a later
     * function binds. */
    char *lifted = emit_lifted_lambdas(source, hir, &prototypes, &bodies);
    if (strncmp(lifted, "error[", 6) == 0) {
        free(prototypes.data);
        free(bodies.data);
        return lifted;
    }
    free(lifted);
    char *lifted_arguments = emit_lifted_argument_lambdas(
        source,
        hir,
        &prototypes,
        &bodies
    );
    if (strncmp(lifted_arguments, "error[", 6) == 0) {
        free(prototypes.data);
        free(bodies.data);
        return lifted_arguments;
    }
    free(lifted_arguments);
    int64_t cursor = next_function_start(source, 0);
    int64_t main_count = 0;
    while (cursor < length) {
        char *name = function_name(source, cursor);
        char *c_name = c_identifier_name(name);
        if (function_arity(source, name) == -2) {
            Buffer error;
            buffer_init(&error);
            buffer_format(
                &error,
                "error[E2S16]: duplicate Core function `%s` "
                "at byte %" PRId64,
                name,
                cursor
            );
            stage2_diagnostic_set(
                "E2S16",
                cursor,
                token_end(source, cursor),
                true,
                error.data
            );
            stage2_diagnostic_affected(
                STAGE2_DIAGNOSTIC_AFFECTED_CALL,
                cursor,
                token_end(source, cursor)
            );
            free(name);
            free(c_name);
            free(prototypes.data);
            free(bodies.data);
            return error.data;
        }
        bool is_main = strcmp(name, "main") == 0;
        char c_result_record[512] = "";
        const char *c_result = "int64_t";
        if (optional_int_result(source, name)) {
            c_result = OPTIONAL_INT_C_TYPE;
        } else if (function_result_is_enum(source, name)) {
            c_result = "KofunEnumValue";
        } else if (function_result_is_text(source, name)) {
            c_result = "const char *";
        } else if (function_result_is_list_int(source, name)) {
            c_result = "KofunIntListValue";
        } else if (function_result_is_record(source, name)) {
            char *result_type = function_return_type(source, name);
            char *record_c_type = record_c_type_name(result_type);
            snprintf(
                c_result_record,
                sizeof c_result_record,
                "%s",
                record_c_type
            );
            free(record_c_type);
            free(result_type);
            c_result = c_result_record;
        }
        int64_t arity = parameter_count(source, cursor);
        char *parameters = core_parameters(source, hir, cursor);
        if (strncmp(parameters, "error[", 6) == 0) {
            free(name);
            free(c_name);
            free(prototypes.data);
            free(bodies.data);
            return parameters;
        }
        const char *c_parameters =
            parameters[0] == '\0' ? "void" : parameters;
        if (is_main) {
            ++main_count;
            if (arity != 0) {
                free(parameters);
                free(name);
                free(c_name);
                free(prototypes.data);
                free(bodies.data);
                return lower_error(
                    "E2S15",
                    "Core main must have zero parameters",
                    -1
                );
            }
        } else {
            buffer_format(
                &prototypes,
                "static %s kofun_fn_%s(%s);\n",
                c_result,
                c_name,
                c_parameters
            );
        }
        int64_t open = core_body_open(source, hir, cursor, is_main);
        if (open < 0) {
            Buffer error;
            buffer_init(&error);
            buffer_format(
                &error,
                "error[E2S15]: Core function `%s` requires Int or concrete "
                "enum parameters and return",
                name
            );
            stage2_diagnostic_set(
                "E2S15",
                cursor,
                token_end(source, cursor),
                true,
                error.data
            );
            free(parameters);
            free(name);
            free(c_name);
            free(prototypes.data);
            free(bodies.data);
            return error.data;
        }
        char *body = lower_body(source, hir, open, is_main, true, open);
        if (strncmp(body, "error[", 6) == 0) {
            free(parameters);
            free(name);
            free(c_name);
            free(prototypes.data);
            free(bodies.data);
            return body;
        }
        if (is_main) {
            buffer_append(
                &bodies,
                "int main(void) {\n"
                "    (void)kofun_failed;\n"
                "    (void)kofun_add;\n"
                "    (void)kofun_sub;\n"
                "    (void)kofun_mul;\n"
                "    (void)kofun_neg;\n"
                "    (void)kofun_floor_div;\n"
                "    (void)kofun_floor_mod;\n"
            );
            if (fractional_values) {
                buffer_append(
                    &bodies,
                    "    if (atexit(kofun_decimal_arena_release) != 0) "
                    "return 1;\n"
                );
            }
            buffer_append(&bodies, body);
            buffer_append(&bodies, "}\n");
        } else {
            buffer_format(
                &bodies,
                "static %s kofun_fn_%s(%s) {\n",
                c_result,
                c_name,
                c_parameters
            );
            buffer_append(&bodies, body);
            buffer_append(&bodies, "}\n");
        }
        free(body);
        free(parameters);
        free(name);
        free(c_name);
        cursor = next_function_start(source, function_end(source, cursor));
    }
    if (main_count != 1) {
        free(prototypes.data);
        free(bodies.data);
        return lower_error(
            "E2S15",
            "C11 Core requires exactly one `fn main()`",
            -1
        );
    }
    int64_t text_site_count = count_text_sites(bodies.data);
    if (text_site_count > 256) {
        free(prototypes.data);
        free(bodies.data);
        return lower_error(
            "E2S156",
            "Text temporary site limit is 256",
            -1
        );
    }
    Buffer output;
    buffer_init(&output);
    buffer_append(
        &output,
        "/* Generated by the Kofun-written Stage 2 Core lowerer. */\n"
        "#include <inttypes.h>\n"
        "#include <stdbool.h>\n"
        "#include <stddef.h>\n"
        "#include <stdint.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
    );
    if (fractional_values) {
        buffer_append(&output, "#include \"decimal_v1.c\"\n");
    }
    buffer_append(
        &output,
        "\n"
        "typedef struct {\n"
        "    int64_t tag;\n"
        "    int64_t payload;\n"
        "} KofunEnumValue;\n"
        "#define KOFUN_ENUM_ZERO "
        "((KofunEnumValue){INT64_C(0), INT64_C(0)})\n\n"
        "typedef const unsigned char *KofunIntList;\n"
        "typedef struct { uint64_t length; int64_t elements[64]; } KofunIntListValue;\n"
        "#define KOFUN_LIST_INT_ZERO ((KofunIntListValue){UINT64_C(0), {INT64_C(0)}})\n"
        "_Static_assert(sizeof(KofunIntListValue) == 520, \"bounded List[Int] value size\");\n"
        "_Static_assert(offsetof(KofunIntListValue, length) == 0, \"bounded List[Int] value length offset\");\n"
        "_Static_assert(offsetof(KofunIntListValue, elements) == 8, \"bounded List[Int] value payload offset\");\n"
        "_Static_assert(_Alignof(KofunIntListValue) == 8, \"bounded List[Int] value alignment\");\n"
        "enum {\n"
        "    KOFUN_LIST_INT_LENGTH_OFFSET = 0,\n"
        "    KOFUN_LIST_INT_PAYLOAD_OFFSET = 8,\n"
        "    KOFUN_LIST_INT_ELEMENT_SIZE = 8\n"
        "};\n"
        "typedef struct { uint64_t length; int64_t first_element; } KofunIntListLayoutProbe;\n"
        "_Static_assert(sizeof(KofunIntList) == 8, \"AggregateLayout List[Int] reference size\");\n"
        "_Static_assert(sizeof(uint64_t) == 8, \"AggregateLayout List[Int] header width\");\n"
        "_Static_assert(sizeof(int64_t) == 8, \"AggregateLayout List[Int] element width\");\n\n"
        "_Static_assert(offsetof(KofunIntListLayoutProbe, length) == KOFUN_LIST_INT_LENGTH_OFFSET, \"AggregateLayout List[Int] length offset\");\n"
        "_Static_assert(offsetof(KofunIntListLayoutProbe, first_element) == KOFUN_LIST_INT_PAYLOAD_OFFSET, \"AggregateLayout List[Int] payload offset\");\n"
        "_Static_assert(sizeof(((KofunIntListLayoutProbe *)0)->first_element) == KOFUN_LIST_INT_ELEMENT_SIZE, \"AggregateLayout List[Int] element size\");\n"
        "_Static_assert(_Alignof(KofunIntListLayoutProbe) == 8, \"AggregateLayout List[Int] object alignment\");\n\n"
        "static bool kofun_failed;\n"
        "static inline void kofun_error(const char *message) {\n"
        "    if (!kofun_failed) { fputs(message, stderr); fputc('\\n', stderr); }\n"
        "    kofun_failed = true;\n"
        "}\n"
        "static inline uint64_t kofun_list_int_length(KofunIntList list) {\n"
        "    uint64_t length = UINT64_C(0);\n"
        "    memcpy(&length, list + KOFUN_LIST_INT_LENGTH_OFFSET, sizeof length);\n"
        "    return length;\n"
        "}\n"
        "static inline KofunIntList kofun_list_int_view(const KofunIntListValue *list) {\n"
        "    return (KofunIntList)(const void *)list;\n"
        "}\n"
        "static inline KofunIntListValue kofun_list_int_value(KofunIntList list) {\n"
        "    KofunIntListValue value = KOFUN_LIST_INT_ZERO;\n"
        "    value.length = kofun_list_int_length(list);\n"
        "    if (value.length > UINT64_C(64)) {\n"
        "        kofun_error(\"error[R024]: bounded List[Int] carrier exceeds 64 elements\"); return KOFUN_LIST_INT_ZERO;\n"
        "    }\n"
        "    if (value.length > 0) memcpy(value.elements, list + KOFUN_LIST_INT_PAYLOAD_OFFSET, (size_t)value.length * sizeof value.elements[0]);\n"
        "    return value;\n"
        "}\n"
        "static inline uint64_t kofun_list_int_value_length(KofunIntListValue list) {\n"
        "    return list.length;\n"
        "}\n"
        "static inline int64_t kofun_list_int_index(KofunIntList list, int64_t index) {\n"
        "    uint64_t length = kofun_list_int_length(list);\n"
        "    if (index < 0) index += (int64_t)length;\n"
        "    if (index < 0 || (uint64_t)index >= length) {\n"
        "        kofun_error(\"error[R023]: bounded List[Int] index out of range\"); return 0;\n"
        "    }\n"
        "    int64_t value = INT64_C(0);\n"
        "    size_t offset = KOFUN_LIST_INT_PAYLOAD_OFFSET +\n"
        "        (size_t)index * KOFUN_LIST_INT_ELEMENT_SIZE;\n"
        "    memcpy(&value, list + offset, sizeof value); return value;\n"
        "}\n"
    );
    buffer_append(
        &output,
        "enum { KOFUN_TEXT_TEMPORARY_LIMIT = 4096 };\n"
        "static char kofun_text_slots[KOFUN_TEXT_TEMPORARY_LIMIT][256];\n"
        "static size_t kofun_text_next_slot;\n"
        "static inline char *kofun_text_temporary(void) {\n"
        "    if (kofun_text_next_slot >= KOFUN_TEXT_TEMPORARY_LIMIT) {\n"
        "        kofun_error(\"error[R022]: bounded Text temporary limit is 4096\"); return NULL;\n"
        "    }\n"
        "    return kofun_text_slots[kofun_text_next_slot++];\n"
        "}\n"
        "static inline const char *kofun_text_slice(const char *text, int64_t start, int64_t end) {\n"
        "    size_t length = strlen(text);\n"
        "    if (start < 0 || end < start || (uint64_t)end > length || end - start > 31) {\n"
        "        kofun_error(\"error[R020]: bounded Text slice out of range\"); return \"\";\n"
        "    }\n"
        "    char *slot = kofun_text_temporary(); if (slot == NULL) return \"\";\n"
        "    size_t width = (size_t)(end - start);\n"
        "    memcpy(slot, text + start, width); slot[width] = '\\0'; return slot;\n"
        "}\n"
        "static inline const char *kofun_to_text(int64_t value) {\n"
        "    char *slot = kofun_text_temporary(); if (slot == NULL) return \"\";\n"
        "    snprintf(slot, 256, \"%\" PRId64, value); return slot;\n"
        "}\n"
        "static inline const char *kofun_text_concat(const char *left, const char *right) {\n"
        "    size_t left_width = strlen(left), right_width = strlen(right);\n"
        "    if (left_width + right_width > 255) {\n"
        "        kofun_error(\"error[R021]: bounded Text concatenation exceeds 255 bytes\"); return \"\";\n"
        "    }\n"
        "    char *slot = kofun_text_temporary(); if (slot == NULL) return \"\";\n"
        "    memcpy(slot, left, left_width); memcpy(slot + left_width, right, right_width);\n"
        "    slot[left_width + right_width] = '\\0'; return slot;\n"
        "}\n"
        "static inline int64_t kofun_add(int64_t a, int64_t b) {\n"
        "    int64_t r; if (__builtin_add_overflow(a, b, &r)) {\n"
        "        kofun_error(\"error[R010]: integer overflow in operator `+`\"); return 0;\n"
        "    } return r;\n"
        "}\n"
        "static inline int64_t kofun_sub(int64_t a, int64_t b) {\n"
        "    int64_t r; if (__builtin_sub_overflow(a, b, &r)) {\n"
        "        kofun_error(\"error[R010]: integer overflow in operator `-`\"); return 0;\n"
        "    } return r;\n"
        "}\n"
        "static inline int64_t kofun_mul(int64_t a, int64_t b) {\n"
        "    int64_t r; if (__builtin_mul_overflow(a, b, &r)) {\n"
        "        kofun_error(\"error[R010]: integer overflow in operator `*`\"); return 0;\n"
        "    } return r;\n"
        "}\n"
        "static inline int64_t kofun_neg(int64_t value) {\n"
        "    if (value == INT64_MIN) {\n"
        "        kofun_error(\"error[R010]: integer overflow in unary operator `-`\"); return 0;\n"
        "    } return -value;\n"
        "}\n"
        "static inline int64_t kofun_floor_div(int64_t a, int64_t b) {\n"
        "    if (b == 0) {\n"
        "        kofun_error(\"error[R010]: operator `//` failed: division by zero\"); return 0;\n"
        "    }\n"
        "    if (a == INT64_MIN && b == -1) {\n"
        "        kofun_error(\"error[R010]: integer overflow in operator `//`\"); return 0;\n"
        "    }\n"
        "    int64_t q = a / b; int64_t r = a % b;\n"
        "    if (r != 0 && ((r < 0) != (b < 0))) { --q; }\n"
        "    return q;\n"
        "}\n"
        "static inline int64_t kofun_floor_mod(int64_t a, int64_t b) {\n"
        "    if (b == 0) {\n"
        "        kofun_error(\"error[R010]: operator `%` failed: division by zero\"); return 0;\n"
        "    }\n"
        "    if (a == INT64_MIN && b == -1) return 0;\n"
        "    int64_t r = a % b;\n"
        "    if (r != 0 && ((r < 0) != (b < 0))) { r += b; }\n"
        "    return r;\n"
        "}\n\n"
    );
    if (source_uses_optional_int(source)) {
        char *optional_declarations = emit_optional_int_c_declarations();
        buffer_append(&output, optional_declarations);
        free(optional_declarations);
    }
    char *record_declarations = emit_record_c_declarations(source);
    buffer_append(&output, record_declarations);
    free(record_declarations);
    buffer_append(&output, prototypes.data);
    buffer_append(&output, "\n");
    buffer_append(&output, bodies.data);
    free(prototypes.data);
    free(bodies.data);
    return output.data;
}

static char *lower_c(const char *source, const char *hir) {
    return lower_c_body(source, hir);
}

static bool ends_with(const char *value, const char *suffix) {
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    return value_length >= suffix_length &&
           strcmp(value + value_length - suffix_length, suffix) == 0;
}

static bool unsupported_lowering_error(const char *diagnostic) {
    return strncmp(
               diagnostic,
               "error[E2S10]: unsupported Core statement",
               strlen("error[E2S10]: unsupported Core statement")
           ) == 0 ||
        strncmp(
            diagnostic,
            "error[E2S10]: unsupported Core builtin call ",
            strlen("error[E2S10]: unsupported Core builtin call ")
        ) == 0 ||
        strncmp(
            diagnostic,
            "error[E2S10]: unsupported Core parameter type ",
            strlen("error[E2S10]: unsupported Core parameter type ")
        ) == 0 ||
        strncmp(
            diagnostic,
            "error[E2S24]: general pattern syntax is parsed ",
               strlen("error[E2S24]: general pattern syntax is parsed ")
           ) == 0 ||
           strncmp(
               diagnostic,
               "error[E2S158]: labelled-call ABI lowering is owned by #882",
               strlen(
                   "error[E2S158]: labelled-call ABI lowering is owned by #882"
               )
           ) == 0 ||
           strncmp(
               diagnostic,
               "error[E2S157]: List[Int] function parameters support only "
               "the immutable copy mode",
               strlen(
                   "error[E2S157]: List[Int] function parameters support only "
                   "the immutable copy mode"
               )
           ) == 0;
}

#ifdef KOFUN_STAGE2_AUTHORITY_API
static void stage2_diagnostic_reset(Stage2AuthorityContext *context) {
    if (context != NULL) memset(context, 0, sizeof(*context));
}

static bool stage2_compile_outcome(
    const char *source,
    Stage2AuthorityContext *context,
    Stage2AuthorityResult *result
) {
    Stage2AuthorityContext *previous_context =
        stage2_active_authority_context;
    char **previous_parse_prefix_output =
        stage2_active_parse_prefix_output;
    char **previous_scope_prefix_output =
        stage2_active_scope_prefix_output;
    Buffer *previous_semantic_observer =
        stage2_active_semantic_observer;
    Buffer *previous_declaration_observer =
        stage2_active_declaration_observer;
    char *tokens;
    char *pattern_check;
    char *lowered;
    memset(result, 0, sizeof(*result));
    stage2_diagnostic_reset(context);
    stage2_active_authority_context = context;
    stage2_active_parse_prefix_output = &result->parse_prefix_ir;
    stage2_active_scope_prefix_output = &result->scope_prefix_hir;

    tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        result->diagnostic = tokens;
        result->exit_class = 1u;
        goto done;
    }
    result->token_span_committed = true;
    free(tokens);

    {
        Buffer declarations;
        buffer_init(&declarations);
        buffer_append(
            &declarations,
            "kofun-stage2-declarations/v1\n"
        );
        stage2_active_declaration_observer = &declarations;
        result->program_ir = parse_program(source);
        stage2_active_declaration_observer =
            previous_declaration_observer;
        /*
         * parse_program may grow and reallocate the observer buffer.  Publish
         * only its final allocation: retaining the pre-parse pointer makes
         * result destruction free storage already released by realloc.
         */
        result->declaration_observations = declarations.data;
    }
    if (strncmp(result->program_ir, "error[", 6) == 0) {
        result->diagnostic = result->program_ir;
        result->program_ir = result->parse_prefix_ir;
        result->parse_prefix_ir = NULL;
        result->parse_committed = result->program_ir != NULL;
        result->exit_class = 1u;
        goto done;
    }
    free(result->parse_prefix_ir);
    result->parse_prefix_ir = NULL;
    result->parse_committed = true;

    pattern_check = validate_executable_patterns(source);
    if (strncmp(pattern_check, "error[", 6) == 0) {
        result->diagnostic = pattern_check;
        result->exit_class =
            unsupported_lowering_error(pattern_check) ? 3u : 1u;
        goto done;
    }
    free(pattern_check);

    result->scope_hir = build_scope_hir(source);
    if (strncmp(result->scope_hir, "error[", 6) == 0) {
        char *scope_error = result->scope_hir;
        char *ownership;
        result->scope_hir = result->scope_prefix_hir;
        result->scope_prefix_hir = NULL;
        result->scope_committed = result->scope_hir != NULL;
        /* Match the command adapter: partial scope facts remain committed,
         * while an unsupported List annotation still owns the public
         * diagnostic if scope construction encountered a later error. */
        char *list_fallback = validate_list_int_annotations(source);
        if (strncmp(list_fallback, "error[", 6) == 0) {
            result->diagnostic = list_fallback;
            result->exit_class = 1u;
            free(scope_error);
            goto done;
        }
        free(list_fallback);
        Stage2StructuredDiagnostic saved = context == NULL ?
            (Stage2StructuredDiagnostic){0} : context->diagnostic;
        result->diagnostic = scope_error;
        ownership = borrowed_collection_check(source);
        result->exit_class =
            strncmp(ownership, "error[", 6) == 0 ? 1u : 3u;
        free(ownership);
        if (context != NULL) context->diagnostic = saved;
        goto done;
    }
    free(result->scope_prefix_hir);
    result->scope_prefix_hir = NULL;
    result->scope_committed = true;
    {
        Buffer observations;
        buffer_init(&observations);
        buffer_append(&observations, "kofun-stage2-observations/v1\n");
        stage2_active_semantic_observer = &observations;
        lowered = lower_c(source, result->scope_hir);
        stage2_active_semantic_observer = previous_semantic_observer;
        /* lower_c may reallocate observations; retain the final owner. */
        result->semantic_observations = observations.data;
    }
    if (strncmp(lowered, "error[", 6) == 0) {
        result->diagnostic = lowered;
        result->exit_class =
            unsupported_lowering_error(lowered) ? 3u : 1u;
        goto done;
    }
    free(lowered);
    result->exit_class = 0u;

done:
    stage2_active_declaration_observer =
        previous_declaration_observer;
    stage2_active_semantic_observer = previous_semantic_observer;
    stage2_active_scope_prefix_output = previous_scope_prefix_output;
    stage2_active_parse_prefix_output = previous_parse_prefix_output;
    stage2_active_authority_context = previous_context;
    return true;
}

static bool stage2_ownership_outcome(
    const char *source,
    Stage2AuthorityContext *context,
    Stage2AuthorityResult *result
) {
    Stage2AuthorityContext *previous_context =
        stage2_active_authority_context;
    char **previous_parse_prefix_output =
        stage2_active_parse_prefix_output;
    char **previous_scope_prefix_output =
        stage2_active_scope_prefix_output;
    Buffer *previous_declaration_observer =
        stage2_active_declaration_observer;
    char *tokens;
    char *ownership;
    memset(result, 0, sizeof(*result));
    stage2_diagnostic_reset(context);
    stage2_active_authority_context = context;
    stage2_active_parse_prefix_output = &result->parse_prefix_ir;
    stage2_active_scope_prefix_output = &result->scope_prefix_hir;
    tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        result->diagnostic = tokens;
        result->exit_class = 1u;
        goto done;
    }
    result->token_span_committed = true;
    free(tokens);
    {
        Buffer declarations;
        buffer_init(&declarations);
        buffer_append(
            &declarations,
            "kofun-stage2-declarations/v1\n"
        );
        stage2_active_declaration_observer = &declarations;
        result->program_ir = parse_program(source);
        stage2_active_declaration_observer =
            previous_declaration_observer;
        /* parse_program may reallocate declarations; retain the final owner. */
        result->declaration_observations = declarations.data;
    }
    if (strncmp(result->program_ir, "error[", 6) == 0) {
        result->diagnostic = result->program_ir;
        result->program_ir = result->parse_prefix_ir;
        result->parse_prefix_ir = NULL;
        result->parse_committed = result->program_ir != NULL;
        result->exit_class = 1u;
        goto done;
    }
    free(result->parse_prefix_ir);
    result->parse_prefix_ir = NULL;
    result->parse_committed = true;
    {
        Stage2StructuredDiagnostic saved = context == NULL ?
            (Stage2StructuredDiagnostic){0} : context->diagnostic;
        result->scope_hir = build_scope_hir_mode(source, true);
        if (strncmp(result->scope_hir, "error[", 6) == 0) {
            char *scope_error = result->scope_hir;
            result->scope_hir = result->scope_prefix_hir;
            result->scope_prefix_hir = NULL;
            result->scope_committed = result->scope_hir != NULL;
            free(scope_error);
        } else {
            free(result->scope_prefix_hir);
            result->scope_prefix_hir = NULL;
            result->scope_committed = true;
        }
        if (context != NULL) context->diagnostic = saved;
    }
    ownership = borrowed_collection_check(source);
    if (strncmp(ownership, "error[", 6) == 0) {
        result->diagnostic = ownership;
        result->exit_class = 1u;
        goto done;
    }
    free(ownership);
    result->exit_class = 0u;
done:
    stage2_active_declaration_observer =
        previous_declaration_observer;
    stage2_active_scope_prefix_output = previous_scope_prefix_output;
    stage2_active_parse_prefix_output = previous_parse_prefix_output;
    stage2_active_authority_context = previous_context;
    return true;
}

static void stage2_authority_result_destroy(Stage2AuthorityResult *result) {
    if (result == NULL) return;
    free(result->program_ir);
    free(result->parse_prefix_ir);
    free(result->declaration_observations);
    free(result->scope_hir);
    free(result->scope_prefix_hir);
    free(result->semantic_observations);
    free(result->diagnostic);
    memset(result, 0, sizeof(*result));
}
#endif

static int compile_file(
    const char *input,
    const char *output,
    const char *ir_output,
    const char *tokens_output
) {
    char *source = read_file(input);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    char *ir = parse_program(source);
    if (strncmp(ir, "error[", 6) == 0) {
        puts(ir);
        free(ir);
        free(tokens);
        free(source);
        return 1;
    }
    write_file(ir_output, ir);
    write_file(tokens_output, tokens);
    if (ends_with(output, ".c")) {
        char *pattern_check = validate_executable_patterns(source);
        if (strncmp(pattern_check, "error[", 6) == 0) {
            int status = unsupported_lowering_error(pattern_check) ? 3 : 1;
            puts(pattern_check);
            free(pattern_check);
            free(ir);
            free(tokens);
            free(source);
            return status;
        }
        free(pattern_check);
        char *hir = build_scope_hir(source);
        if (strncmp(hir, "error[", 6) == 0) {
            /* Scope-prefix facts have already been observed. Keep the public
             * unsupported-list diagnostic exact without moving validation
             * back inside scope-HIR construction. */
            char *list_fallback = validate_list_int_annotations(source);
            if (strncmp(list_fallback, "error[", 6) == 0) {
                puts(list_fallback);
                free(list_fallback);
                free(hir);
                free(ir);
                free(tokens);
                free(source);
                return 1;
            }
            free(list_fallback);
            char *ownership = borrowed_collection_check(source);
            int status = strcmp(ownership, "ok") == 0 ? 3 : 1;
            puts(hir);
            free(ownership);
            free(hir);
            free(ir);
            free(tokens);
            free(source);
            return status;
        }
        char *c_source = lower_c(source, hir);
        if (strncmp(c_source, "error[", 6) == 0) {
            int status = unsupported_lowering_error(c_source) ? 3 : 1;
            puts(c_source);
            free(c_source);
            free(hir);
            free(ir);
            free(tokens);
            free(source);
            return status;
        }
        Buffer combined_ir;
        buffer_init(&combined_ir);
        buffer_append(&combined_ir, ir);
        buffer_append(&combined_ir, hir);
        write_file(ir_output, combined_ir.data);
        write_file(output, c_source);
        free(combined_ir.data);
        free(c_source);
        free(hir);
    } else {
        write_file(output, source);
    }
    puts(output);
    free(ir);
    free(tokens);
    free(source);
    return 0;
}

static int check_ownership_file(const char *path) {
    char *source = read_file(path);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    char *ir = parse_program(source);
    if (strncmp(ir, "error[", 6) == 0) {
        puts(ir);
        free(ir);
        free(tokens);
        free(source);
        return 1;
    }
    char *result = borrowed_collection_check(source);
    bool ok = strcmp(result, "ok") == 0;
    if (!ok) puts(result);
    free(result);
    free(ir);
    free(tokens);
    free(source);
    return ok ? 0 : 1;
}

static int parse_patterns_file(const char *input, const char *output) {
    char *source = read_file(input);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    free(tokens);
    char *tree = parse_pattern_trees(source);
    write_file(output, tree);
    char *error = pattern_first_error(tree);
    bool ok = error[0] == '\0';
    if (!ok) puts(error);
    free(error);
    free(tree);
    free(source);
    return ok ? 0 : 1;
}

/*
 * kofun.selfhost-hir/v1 emitter (bootstrap/selfhost/hir-v1.md).
 *
 * One typed pre-order walk over the frozen profile surface produces the
 * complete document: deduplicated type table, scope tree, symbols,
 * bindings, and per-function node records. Any construct outside the
 * profile rejects the whole document with diagnostics plus explicit
 * `unsupported` records; a partial typed document is never written.
 */

enum {
    SH_MAX_TYPES = 64,
    SH_MAX_ENV = 512,
    SH_MAX_DEPTH = 32,
};

typedef struct {
    const char *source;
    int64_t length;
    Buffer types;
    Buffer scopes;
    Buffer symbols;
    Buffer bindings;
    Buffer nodes;
    Buffer diagnostics;
    char type_keys[SH_MAX_TYPES][80];
    int64_t type_count;
    int64_t next_scope;
    int64_t next_symbol;
    int64_t next_binding;
    int64_t next_node;
    struct {
        char name[64];
        char type[16];
        int64_t binding_id;
        bool is_mutable;
    } env[SH_MAX_ENV];
    int64_t env_count;
    int64_t scope_stack[SH_MAX_DEPTH];
    int64_t scope_depth;
    struct {
        char name[64];
        char result[16];
        int64_t symbol_id;
        int64_t arity;
        char parameters[8][16];
    } functions[128];
    int64_t function_count;
    int64_t builtin_symbols[17];
    int64_t len_list_symbol;
    char *error;
    char error_code[8];
    char error_message[128];
    int64_t error_at;
} Sh;

static void sh_fail(Sh *sh, const char *code, const char *message, int64_t at) {
    if (sh->error != NULL) return;
    Buffer error;
    buffer_init(&error);
    if (at >= 0) {
        buffer_format(
            &error,
            "error[%s]: %s at byte %" PRId64,
            code,
            message,
            at
        );
    } else {
        buffer_format(&error, "error[%s]: %s", code, message);
    }
    sh->error = error.data;
    snprintf(sh->error_code, sizeof(sh->error_code), "%s", code);
    snprintf(sh->error_message, sizeof(sh->error_message), "%s", message);
    sh->error_at = at;
}

/* hir-v1 record escaping: `\` -> `\\`, `|` -> `\p`, newline -> `\n`. */
static void sh_escaped(Buffer *out, const char *text) {
    for (size_t index = 0; text[index] != '\0'; ++index) {
        char symbol = text[index];
        if (symbol == '\\') {
            buffer_append(out, "\\\\");
        } else if (symbol == '|') {
            buffer_append(out, "\\p");
        } else if (symbol == '\n') {
            buffer_append(out, "\\n");
        } else {
            char one[2] = {symbol, '\0'};
            buffer_append(out, one);
        }
    }
}

static int64_t sh_type_id_key(Sh *sh, const char *key) {
    for (int64_t index = 0; index < sh->type_count; ++index) {
        if (strcmp(sh->type_keys[index], key) == 0) return index;
    }
    if (sh->type_count >= SH_MAX_TYPES) {
        sh_fail(sh, "E2S35", "selfhost-HIR type limit is 64", -1);
        return 0;
    }
    snprintf(
        sh->type_keys[sh->type_count],
        sizeof(sh->type_keys[0]),
        "%s",
        key
    );
    buffer_format(&sh->types, "type|%" PRId64 "|%s\n", sh->type_count, key);
    return sh->type_count++;
}

/* Surface names Int/Bool/Text/Void/List map onto the closed universe. */
static int64_t sh_scalar_type_id(Sh *sh, const char *surface) {
    if (strcmp(surface, "Int") == 0) return sh_type_id_key(sh, "int");
    if (strcmp(surface, "Bool") == 0) return sh_type_id_key(sh, "bool");
    if (strcmp(surface, "Text") == 0) return sh_type_id_key(sh, "text");
    if (strcmp(surface, "Void") == 0) return sh_type_id_key(sh, "void");
    if (strcmp(surface, "List") == 0) {
        return sh_type_id_key(sh, "list-text");
    }
    sh_fail(sh, "E2S15", "type is outside the frozen profile", -1);
    return 0;
}

static int64_t sh_fn_type_id(
    Sh *sh,
    const char *result,
    char parameters[][16],
    int64_t arity
) {
    char key[80];
    int64_t written = snprintf(
        key,
        sizeof(key),
        "fn|%" PRId64,
        sh_scalar_type_id(sh, result)
    );
    for (int64_t index = 0; index < arity; ++index) {
        written += snprintf(
            key + written,
            sizeof(key) - (size_t)written,
            "|%" PRId64,
            sh_scalar_type_id(sh, parameters[index])
        );
    }
    return sh_type_id_key(sh, key);
}

static void sh_scope_open(
    Sh *sh,
    const char *kind,
    int64_t start,
    int64_t end
) {
    int64_t parent = sh->scope_depth > 0 ?
        sh->scope_stack[sh->scope_depth - 1] : sh->next_scope;
    if (sh->scope_depth >= SH_MAX_DEPTH) {
        sh_fail(sh, "E2S35", "lexical scope depth limit is 32", start);
        return;
    }
    buffer_format(
        &sh->scopes,
        "scope|%" PRId64 "|%" PRId64 "|%s|%" PRId64 "|%" PRId64 "\n",
        sh->next_scope,
        parent,
        kind,
        start,
        end
    );
    sh->scope_stack[sh->scope_depth++] = sh->next_scope++;
}

static void sh_scope_close(Sh *sh, int64_t saved_env) {
    if (sh->scope_depth > 0) --sh->scope_depth;
    sh->env_count = saved_env;
}

static int64_t sh_bind(
    Sh *sh,
    const char *name,
    const char *type,
    bool is_mutable,
    const char *symbol_kind,
    int64_t name_start,
    int64_t name_end
) {
    if (sh->env_count >= SH_MAX_ENV) {
        sh_fail(sh, "E2S35", "lexical binding limit is 512", name_start);
        return -1;
    }
    int64_t scope = sh->scope_stack[sh->scope_depth - 1];
    int64_t symbol_id = sh->next_symbol++;
    buffer_format(
        &sh->symbols,
        "symbol|%" PRId64 "|%s|%s|%" PRId64 "|%" PRId64 "|%" PRId64 "\n",
        symbol_id,
        symbol_kind,
        name,
        sh_scalar_type_id(sh, type),
        name_start,
        name_end
    );
    int64_t binding_id = sh->next_binding++;
    buffer_format(
        &sh->bindings,
        "binding|%" PRId64 "|%" PRId64 "|%" PRId64 "|%s|%s|%" PRId64
        "|%" PRId64 "\n",
        binding_id,
        scope,
        symbol_id,
        name,
        is_mutable ? "mut" : "imm",
        name_start,
        name_end
    );
    snprintf(
        sh->env[sh->env_count].name,
        sizeof(sh->env[0].name),
        "%s",
        name
    );
    snprintf(
        sh->env[sh->env_count].type,
        sizeof(sh->env[0].type),
        "%s",
        type
    );
    sh->env[sh->env_count].binding_id = binding_id;
    sh->env[sh->env_count].is_mutable = is_mutable;
    ++sh->env_count;
    return binding_id;
}

static int64_t sh_resolve(Sh *sh, const char *name) {
    for (int64_t index = sh->env_count - 1; index >= 0; --index) {
        if (strcmp(sh->env[index].name, name) == 0) return index;
    }
    return -1;
}

static const char *sh_ownership(const char *type, bool edit) {
    if (edit) return "edit";
    if (strcmp(type, "Text") == 0 || strcmp(type, "List") == 0) {
        return "read";
    }
    return "copy";
}


typedef struct ShExpr ShExpr;
struct ShExpr {
    char kind[16];
    int64_t start;
    int64_t end;
    char type[16];
    char op[4];
    char *text;
    int64_t symbol_id;
    int64_t binding_id;
    ShExpr *left;
    ShExpr *right;
    ShExpr *arguments[8];
    int64_t argument_count;
};

typedef struct ShStmt ShStmt;
typedef struct ShBlock ShBlock;
struct ShBlock {
    int64_t scope_id;
    ShStmt *statements[64];
    int64_t count;
};
struct ShStmt {
    char kind[12];
    int64_t start;
    int64_t end;
    ShExpr *value;
    int64_t binding_id;
    ShBlock *body;
    char else_kind[8];
    ShStmt *else_if;
    ShBlock *else_block;
};

static void sh_free_expr(ShExpr *expr) {
    if (expr == NULL) return;
    free(expr->text);
    sh_free_expr(expr->left);
    sh_free_expr(expr->right);
    for (int64_t index = 0; index < expr->argument_count; ++index) {
        sh_free_expr(expr->arguments[index]);
    }
    free(expr);
}

static void sh_free_stmt(ShStmt *statement);

static void sh_free_block(ShBlock *block) {
    if (block == NULL) return;
    for (int64_t index = 0; index < block->count; ++index) {
        sh_free_stmt(block->statements[index]);
    }
    free(block);
}

static void sh_free_stmt(ShStmt *statement) {
    if (statement == NULL) return;
    sh_free_expr(statement->value);
    sh_free_block(statement->body);
    sh_free_stmt(statement->else_if);
    sh_free_block(statement->else_block);
    free(statement);
}

static ShExpr *sh_expr_new(const char *kind, int64_t start, int64_t end) {
    ShExpr *expr = allocate(sizeof(*expr));
    memset(expr, 0, sizeof(*expr));
    snprintf(expr->kind, sizeof(expr->kind), "%s", kind);
    expr->start = start;
    expr->end = end;
    return expr;
}

static ShExpr *sh_parse_expr(Sh *sh, int64_t *cursor);

static int64_t sh_function_index(Sh *sh, const char *name) {
    for (int64_t index = 0; index < sh->function_count; ++index) {
        if (strcmp(sh->functions[index].name, name) == 0) return index;
    }
    return -1;
}

static ShExpr *sh_parse_primary(Sh *sh, int64_t *cursor) {
    int64_t at = *cursor;
    if (at >= sh->length) {
        sh_fail(sh, "E2S12", "expected expression", at);
        return NULL;
    }
    const char *kind = token_kind(sh->source, at);
    int64_t end = token_end(sh->source, at);
    /* Scoped parallelism v1 (#555) fixes `par` as target semantics in
     * spec/concurrency/scoped-parallelism-v1.md. The lexer owns the keyword so
     * this refusal names the construct instead of surfacing as an unknown
     * binding, but ownership checking, scheduling, and lowering do not exist:
     * the honest answer here is a refusal, not a partial acceptance. */
    if (token_equal(sh->source, at, "par")) {
        sh_fail(sh, "E2S154",
                "scoped parallelism `par` is specified but not implemented",
                at);
        return NULL;
    }
    if (strcmp(kind, "integer") == 0) {
        ShExpr *expr = sh_expr_new("literal-int", at, end);
        snprintf(expr->type, sizeof(expr->type), "Int");
        expr->text = token_copy(sh->source, at);
        *cursor = skip_trivia(sh->source, end);
        return expr;
    }
    if (strcmp(kind, "string") == 0) {
        ShExpr *expr = sh_expr_new("literal-text", at, end);
        snprintf(expr->type, sizeof(expr->type), "Text");
        expr->text = token_copy(sh->source, at);
        *cursor = skip_trivia(sh->source, end);
        return expr;
    }
    if (
        token_equal(sh->source, at, "true") ||
        token_equal(sh->source, at, "false")
    ) {
        ShExpr *expr = sh_expr_new("literal-bool", at, end);
        snprintf(expr->type, sizeof(expr->type), "Bool");
        expr->text = token_copy(sh->source, at);
        *cursor = skip_trivia(sh->source, end);
        return expr;
    }
    if (token_equal(sh->source, at, "(")) {
        *cursor = skip_trivia(sh->source, end);
        ShExpr *inner = sh_parse_expr(sh, cursor);
        if (inner == NULL) return NULL;
        if (
            *cursor >= sh->length ||
            !token_equal(sh->source, *cursor, ")")
        ) {
            sh_fail(sh, "E2S12", "expected `)`", *cursor);
            sh_free_expr(inner);
            return NULL;
        }
        *cursor = skip_trivia(sh->source, token_end(sh->source, *cursor));
        return inner;
    }
    if (strcmp(kind, "identifier") == 0) {
        char *name = token_copy(sh->source, at);
        int64_t after = skip_trivia(sh->source, end);
        if (after < sh->length && token_equal(sh->source, after, "(")) {
            ShExpr *call = sh_expr_new("call", at, end);
            call->text = name;
            *cursor = skip_trivia(sh->source, token_end(sh->source, after));
            while (
                *cursor < sh->length &&
                !token_equal(sh->source, *cursor, ")")
            ) {
                if (call->argument_count >= 8) {
                    sh_fail(sh, "E2S17", "call has too many arguments", at);
                    sh_free_expr(call);
                    return NULL;
                }
                ShExpr *argument = sh_parse_expr(sh, cursor);
                if (argument == NULL) {
                    sh_free_expr(call);
                    return NULL;
                }
                call->arguments[call->argument_count++] = argument;
                if (
                    *cursor < sh->length &&
                    token_equal(sh->source, *cursor, ",")
                ) {
                    *cursor = skip_trivia(
                        sh->source,
                        token_end(sh->source, *cursor)
                    );
                }
            }
            if (*cursor >= sh->length) {
                sh_fail(sh, "E2S12", "expected `)`", at);
                sh_free_expr(call);
                return NULL;
            }
            call->end = token_end(sh->source, *cursor);
            *cursor = skip_trivia(
                sh->source,
                token_end(sh->source, *cursor)
            );
            /* Resolve to a declared function or profile builtin and type
             * the call; `len` picks its overload from the argument. */
            int64_t declared = sh_function_index(sh, call->text);
            if (declared >= 0) {
                if (
                    call->argument_count !=
                    sh->functions[declared].arity
                ) {
                    sh_fail(sh, "E2S17", "wrong call arity", at);
                    sh_free_expr(call);
                    return NULL;
                }
                for (
                    int64_t index = 0;
                    index < call->argument_count;
                    ++index
                ) {
                    if (
                        strcmp(
                            call->arguments[index]->type,
                            sh->functions[declared].parameters[index]
                        ) != 0
                    ) {
                        sh_fail(
                            sh,
                            "E2S15",
                            "call argument type mismatch",
                            call->arguments[index]->start
                        );
                        sh_free_expr(call);
                        return NULL;
                    }
                }
                call->symbol_id = sh->functions[declared].symbol_id;
                snprintf(
                    call->type,
                    sizeof(call->type),
                    "%s",
                    sh->functions[declared].result
                );
                return call;
            }
            int64_t arity = builtin_arity(call->text);
            if (strcmp(call->text, "print") == 0) arity = 1;
            if (arity < 0) {
                sh_fail(sh, "E2S16", "unknown function", at);
                sh_free_expr(call);
                return NULL;
            }
            if (call->argument_count != arity) {
                sh_fail(sh, "E2S17", "wrong builtin arity", at);
                sh_free_expr(call);
                return NULL;
            }
            const char *result = "Void";
            if (strcmp(call->text, "print") != 0) {
                result = builtin_return_type(call->text);
            }
            if (strcmp(call->text, "len") == 0) {
                const char *argument_type = call->arguments[0]->type;
                if (
                    strcmp(argument_type, "Text") != 0 &&
                    strcmp(argument_type, "List") != 0
                ) {
                    sh_fail(
                        sh,
                        "E2S15",
                        "len expects Text or List[Text]",
                        call->arguments[0]->start
                    );
                    sh_free_expr(call);
                    return NULL;
                }
                call->symbol_id =
                    strcmp(argument_type, "List") == 0 ?
                        sh->len_list_symbol :
                        sh->builtin_symbols[7];
            } else if (strcmp(call->text, "print") == 0) {
                if (strcmp(call->arguments[0]->type, "Text") != 0) {
                    sh_fail(
                        sh,
                        "E2S15",
                        "print expects Text in the profile",
                        call->arguments[0]->start
                    );
                    sh_free_expr(call);
                    return NULL;
                }
                call->symbol_id = sh->builtin_symbols[8];
            } else {
                const char *parameters =
                    builtin_parameter_types(call->text);
                const char *expected = parameters;
                for (
                    int64_t index = 0;
                    index < call->argument_count;
                    ++index
                ) {
                    size_t expected_length = strcspn(expected, "|");
                    bool matches =
                        strlen(call->arguments[index]->type) ==
                            expected_length &&
                        strncmp(
                            call->arguments[index]->type,
                            expected,
                            expected_length
                        ) == 0;
                    if (!matches) {
                        sh_fail(
                            sh,
                            "E2S15",
                            "builtin argument type mismatch",
                            call->arguments[index]->start
                        );
                        sh_free_expr(call);
                        return NULL;
                    }
                    expected += expected_length;
                    if (expected[0] == '|') ++expected;
                }
                int64_t slot = -1;
                /*
                 * Positions index `builtin_symbols`, so this order must
                 * match the order those slots are filled in, not the
                 * alphabetical order of the signature tables. `fail`
                 * occupies the tail slot because its symbol is assigned
                 * last, after the len List[Text] overload.
                 */
                static const char *ordered[] = {
                    "args", "chars", "contains", "find", "is_digit",
                    "is_space", "is_xid_continue", "len", "print",
                    "read_text", "replace", "starts_with", "text_slice",
                    "trim", "validate_unicode_source", "write_text",
                    "fail",
                };
                for (int64_t index = 0; index < 17; ++index) {
                    if (strcmp(ordered[index], call->text) == 0) {
                        slot = index;
                        break;
                    }
                }
                call->symbol_id = sh->builtin_symbols[slot];
            }
            snprintf(call->type, sizeof(call->type), "%s", result);
            return call;
        }
        int64_t resolved = sh_resolve(sh, name);
        if (resolved < 0) {
            sh_fail(sh, "E2S35", "unknown lexical binding", at);
            free(name);
            return NULL;
        }
        ShExpr *reference = sh_expr_new("name", at, end);
        reference->text = name;
        reference->binding_id = sh->env[resolved].binding_id;
        snprintf(
            reference->type,
            sizeof(reference->type),
            "%s",
            sh->env[resolved].type
        );
        *cursor = after;
        return reference;
    }
    sh_fail(sh, "E2S12", "expected expression", at);
    return NULL;
}

static ShExpr *sh_parse_postfix(Sh *sh, int64_t *cursor) {
    ShExpr *base = sh_parse_primary(sh, cursor);
    if (base == NULL) return NULL;
    while (
        *cursor < sh->length &&
        token_equal(sh->source, *cursor, "[")
    ) {
        if (strcmp(base->type, "List") != 0) {
            sh_fail(sh, "E2S15", "only List[Text] can be indexed", *cursor);
            sh_free_expr(base);
            return NULL;
        }
        *cursor = skip_trivia(sh->source, token_end(sh->source, *cursor));
        ShExpr *index_expr = sh_parse_expr(sh, cursor);
        if (index_expr == NULL) {
            sh_free_expr(base);
            return NULL;
        }
        if (strcmp(index_expr->type, "Int") != 0) {
            sh_fail(sh, "E2S15", "index must be Int", index_expr->start);
            sh_free_expr(base);
            sh_free_expr(index_expr);
            return NULL;
        }
        if (
            *cursor >= sh->length ||
            !token_equal(sh->source, *cursor, "]")
        ) {
            sh_fail(sh, "E2S12", "expected `]`", *cursor);
            sh_free_expr(base);
            sh_free_expr(index_expr);
            return NULL;
        }
        int64_t close = token_end(sh->source, *cursor);
        *cursor = skip_trivia(sh->source, close);
        ShExpr *indexed = sh_expr_new("index", base->start, close);
        snprintf(indexed->type, sizeof(indexed->type), "Text");
        indexed->left = base;
        indexed->right = index_expr;
        base = indexed;
    }
    return base;
}

static ShExpr *sh_parse_unary(Sh *sh, int64_t *cursor) {
    int64_t at = *cursor;
    if (at < sh->length && token_equal(sh->source, at, "!")) {
        *cursor = skip_trivia(sh->source, token_end(sh->source, at));
        ShExpr *operand = sh_parse_unary(sh, cursor);
        if (operand == NULL) return NULL;
        if (strcmp(operand->type, "Bool") != 0) {
            sh_fail(sh, "E2S15", "`!` expects Bool", operand->start);
            sh_free_expr(operand);
            return NULL;
        }
        ShExpr *expr = sh_expr_new("unary", at, operand->end);
        snprintf(expr->type, sizeof(expr->type), "Bool");
        snprintf(expr->op, sizeof(expr->op), "!");
        expr->left = operand;
        return expr;
    }
    if (at < sh->length && token_equal(sh->source, at, "-")) {
        *cursor = skip_trivia(sh->source, token_end(sh->source, at));
        ShExpr *operand = sh_parse_unary(sh, cursor);
        if (operand == NULL) return NULL;
        if (strcmp(operand->type, "Int") != 0) {
            sh_fail(sh, "E2S15", "unary `-` expects Int", operand->start);
            sh_free_expr(operand);
            return NULL;
        }
        ShExpr *expr = sh_expr_new("unary", at, operand->end);
        snprintf(expr->type, sizeof(expr->type), "Int");
        snprintf(expr->op, sizeof(expr->op), "-");
        expr->left = operand;
        return expr;
    }
    return sh_parse_postfix(sh, cursor);
}

static bool sh_operator_at(
    Sh *sh,
    int64_t cursor,
    const char *const *operators,
    int64_t count,
    const char **matched
) {
    if (cursor >= sh->length) return false;
    for (int64_t index = 0; index < count; ++index) {
        if (token_equal(sh->source, cursor, operators[index])) {
            *matched = operators[index];
            return true;
        }
    }
    return false;
}

static ShExpr *sh_parse_binary_level(
    Sh *sh,
    int64_t *cursor,
    int64_t level
);

/* Levels: 0 `||`; 1 `&&`; 2 comparisons; 3 `+ -`; 4 `* / // %`. */
static ShExpr *sh_parse_binary_level(
    Sh *sh,
    int64_t *cursor,
    int64_t level
) {
    static const char *const level0[] = {"||"};
    static const char *const level1[] = {"&&"};
    static const char *const level2[] =
        {"==", "!=", "<=", ">=", "<", ">"};
    static const char *const level3[] = {"+", "-"};
    static const char *const level4[] = {"*", "//", "/", "%"};
    static const struct {
        const char *const *operators;
        int64_t count;
    } levels[] = {
        {level0, 1}, {level1, 1}, {level2, 6}, {level3, 2}, {level4, 4},
    };
    if (level > 4) return sh_parse_unary(sh, cursor);
    ShExpr *left = sh_parse_binary_level(sh, cursor, level + 1);
    if (left == NULL) return NULL;
    const char *matched = NULL;
    while (
        sh_operator_at(
            sh,
            *cursor,
            levels[level].operators,
            levels[level].count,
            &matched
        )
    ) {
        int64_t operator_at = *cursor;
        *cursor = skip_trivia(
            sh->source,
            token_end(sh->source, operator_at)
        );
        ShExpr *right = sh_parse_binary_level(sh, cursor, level + 1);
        if (right == NULL) {
            sh_free_expr(left);
            return NULL;
        }
        const char *result = NULL;
        if (level <= 1) {
            if (
                strcmp(left->type, "Bool") != 0 ||
                strcmp(right->type, "Bool") != 0
            ) {
                sh_fail(sh, "E2S15", "logical operands must be Bool",
                        operator_at);
            }
            result = "Bool";
        } else if (level == 2) {
            if (
                strcmp(left->type, right->type) != 0 ||
                strcmp(left->type, "List") == 0 ||
                strcmp(left->type, "Void") == 0
            ) {
                sh_fail(sh, "E2S15",
                        "comparison operands must share a scalar type",
                        operator_at);
            }
            result = "Bool";
        } else if (level == 3 && strcmp(matched, "+") == 0 &&
                   strcmp(left->type, "Text") == 0) {
            if (strcmp(right->type, "Text") != 0) {
                sh_fail(sh, "E2S15", "Text `+` expects Text", operator_at);
            }
            result = "Text";
        } else {
            if (
                strcmp(left->type, "Int") != 0 ||
                strcmp(right->type, "Int") != 0
            ) {
                sh_fail(sh, "E2S15", "arithmetic operands must be Int",
                        operator_at);
            }
            result = "Int";
        }
        if (sh->error != NULL) {
            sh_free_expr(left);
            sh_free_expr(right);
            return NULL;
        }
        ShExpr *parent = sh_expr_new("binary", left->start, right->end);
        snprintf(parent->type, sizeof(parent->type), "%s", result);
        snprintf(parent->op, sizeof(parent->op), "%s", matched);
        parent->left = left;
        parent->right = right;
        left = parent;
    }
    return left;
}

static ShExpr *sh_parse_expr(Sh *sh, int64_t *cursor) {
    return sh_parse_binary_level(sh, cursor, 0);
}

static ShBlock *sh_parse_block(
    Sh *sh,
    int64_t *cursor,
    const char *declared,
    const char *loop_name,
    int64_t loop_name_start,
    int64_t *loop_binding_out
);

static ShStmt *sh_stmt_new(const char *kind, int64_t start) {
    ShStmt *statement = allocate(sizeof(*statement));
    memset(statement, 0, sizeof(*statement));
    snprintf(statement->kind, sizeof(statement->kind), "%s", kind);
    statement->start = start;
    return statement;
}

static ShStmt *sh_parse_stmt(
    Sh *sh,
    int64_t *cursor,
    const char *declared
) {
    int64_t at = *cursor;
    /* See sh_parse_primary: `par` in statement position is refused by name
     * rather than falling through to the generic unsupported-statement code. */
    if (token_equal(sh->source, at, "par")) {
        sh_fail(sh, "E2S154",
                "scoped parallelism `par` is specified but not implemented",
                at);
        return NULL;
    }
    if (token_equal(sh->source, at, "let")) {
        int64_t name = skip_trivia(sh->source, token_end(sh->source, at));
        bool is_mutable = false;
        if (name < sh->length && token_equal(sh->source, name, "mut")) {
            is_mutable = true;
            name = skip_trivia(sh->source, token_end(sh->source, name));
        }
        if (
            name >= sh->length ||
            strcmp(token_kind(sh->source, name), "identifier") != 0
        ) {
            sh_fail(sh, "E2S12", "expected binding name", name);
            return NULL;
        }
        int64_t name_end = token_end(sh->source, name);
        int64_t after = skip_trivia(sh->source, name_end);
        char annotation[16] = "";
        if (after < sh->length && token_equal(sh->source, after, ":")) {
            int64_t type_at = skip_trivia(
                sh->source,
                token_end(sh->source, after)
            );
            char *type_text = token_copy(sh->source, type_at);
            snprintf(annotation, sizeof(annotation), "%s", type_text);
            free(type_text);
            after = skip_trivia(sh->source, token_end(sh->source, type_at));
            if (strcmp(annotation, "List") == 0) {
                /* List [ Text ] */
                after = skip_trivia(sh->source, token_end(sh->source, after));
                after = skip_trivia(sh->source, token_end(sh->source, after));
            }
        }
        if (after >= sh->length || !token_equal(sh->source, after, "=")) {
            sh_fail(sh, "E2S12", "expected `=`", after);
            return NULL;
        }
        *cursor = skip_trivia(sh->source, token_end(sh->source, after));
        ShExpr *value = sh_parse_expr(sh, cursor);
        if (value == NULL) return NULL;
        if (annotation[0] != '\0' &&
            strcmp(annotation, value->type) != 0) {
            sh_fail(sh, "E2S15", "initializer type mismatch", value->start);
            sh_free_expr(value);
            return NULL;
        }
        char *name_text = token_copy(sh->source, name);
        int64_t binding = sh_bind(
            sh,
            name_text,
            value->type,
            is_mutable,
            "local",
            name,
            name_end
        );
        free(name_text);
        if (binding < 0) {
            sh_free_expr(value);
            return NULL;
        }
        ShStmt *statement = sh_stmt_new(
            is_mutable ? "let-mut" : "let",
            at
        );
        statement->end = value->end;
        statement->value = value;
        statement->binding_id = binding;
        return statement;
    }
    if (token_equal(sh->source, at, "if") ||
        token_equal(sh->source, at, "while")) {
        bool is_if = token_equal(sh->source, at, "if");
        *cursor = skip_trivia(sh->source, token_end(sh->source, at));
        ShExpr *condition = sh_parse_expr(sh, cursor);
        if (condition == NULL) return NULL;
        if (strcmp(condition->type, "Bool") != 0) {
            sh_fail(
                sh,
                "E2S23",
                is_if ?
                    "if condition must be Bool or an Int comparison" :
                    "while condition must be Bool",
                condition->start
            );
            sh_free_expr(condition);
            return NULL;
        }
        ShBlock *body = sh_parse_block(sh, cursor, declared, NULL, -1, NULL);
        if (body == NULL) {
            sh_free_expr(condition);
            return NULL;
        }
        ShStmt *statement = sh_stmt_new(is_if ? "if" : "while", at);
        statement->value = condition;
        statement->body = body;
        snprintf(statement->else_kind, sizeof(statement->else_kind), "none");
        if (
            is_if &&
            *cursor < sh->length &&
            token_equal(sh->source, *cursor, "else")
        ) {
            int64_t next = skip_trivia(
                sh->source,
                token_end(sh->source, *cursor)
            );
            if (next < sh->length && token_equal(sh->source, next, "if")) {
                *cursor = next;
                ShStmt *chained = sh_parse_stmt(sh, cursor, declared);
                if (chained == NULL) {
                    sh_free_stmt(statement);
                    return NULL;
                }
                snprintf(
                    statement->else_kind,
                    sizeof(statement->else_kind),
                    "if"
                );
                statement->else_if = chained;
            } else {
                *cursor = next;
                ShBlock *alternative = sh_parse_block(
                    sh,
                    cursor,
                    declared,
                    NULL,
                    -1,
                    NULL
                );
                if (alternative == NULL) {
                    sh_free_stmt(statement);
                    return NULL;
                }
                snprintf(
                    statement->else_kind,
                    sizeof(statement->else_kind),
                    "block"
                );
                statement->else_block = alternative;
            }
        }
        statement->end = *cursor;
        return statement;
    }
    if (token_equal(sh->source, at, "for")) {
        int64_t name = skip_trivia(sh->source, token_end(sh->source, at));
        if (
            name >= sh->length ||
            strcmp(token_kind(sh->source, name), "identifier") != 0
        ) {
            sh_fail(sh, "E2S12", "expected loop variable", name);
            return NULL;
        }
        int64_t in_at = skip_trivia(
            sh->source,
            token_end(sh->source, name)
        );
        if (in_at >= sh->length || !token_equal(sh->source, in_at, "in")) {
            sh_fail(sh, "E2S12", "expected `in`", in_at);
            return NULL;
        }
        *cursor = skip_trivia(sh->source, token_end(sh->source, in_at));
        ShExpr *low = sh_parse_expr(sh, cursor);
        if (low == NULL) return NULL;
        if (
            *cursor >= sh->length ||
            !token_equal(sh->source, *cursor, "..")
        ) {
            sh_fail(sh, "E2S12", "expected `..`", *cursor);
            sh_free_expr(low);
            return NULL;
        }
        *cursor = skip_trivia(sh->source, token_end(sh->source, *cursor));
        ShExpr *high = sh_parse_expr(sh, cursor);
        if (high == NULL) {
            sh_free_expr(low);
            return NULL;
        }
        if (
            strcmp(low->type, "Int") != 0 ||
            strcmp(high->type, "Int") != 0
        ) {
            sh_fail(sh, "E2S15", "range bounds must be Int", low->start);
            sh_free_expr(low);
            sh_free_expr(high);
            return NULL;
        }
        ShExpr *range = sh_expr_new("range", low->start, high->end);
        snprintf(range->type, sizeof(range->type), "Int");
        range->left = low;
        range->right = high;
        char *loop_name = token_copy(sh->source, name);
        int64_t loop_binding = -1;
        ShBlock *body = sh_parse_block(
            sh,
            cursor,
            declared,
            loop_name,
            name,
            &loop_binding
        );
        free(loop_name);
        if (body == NULL) {
            sh_free_expr(range);
            return NULL;
        }
        ShStmt *statement = sh_stmt_new("for-range", at);
        statement->value = range;
        statement->body = body;
        statement->binding_id = loop_binding;
        statement->end = *cursor;
        return statement;
    }
    if (token_equal(sh->source, at, "return")) {
        int64_t value_at = skip_trivia(
            sh->source,
            token_end(sh->source, at)
        );
        bool bare =
            value_at >= sh->length ||
            token_equal(sh->source, value_at, "}") ||
            newline_between(
                sh->source,
                token_end(sh->source, at),
                value_at
            );
        ShStmt *statement = sh_stmt_new("return", at);
        if (bare) {
            if (strcmp(declared, "Void") != 0) {
                sh_fail(sh, "E2S19", "missing return value", at);
                sh_free_stmt(statement);
                return NULL;
            }
            statement->end = token_end(sh->source, at);
            *cursor = value_at;
            return statement;
        }
        *cursor = value_at;
        ShExpr *value = sh_parse_expr(sh, cursor);
        if (value == NULL) {
            sh_free_stmt(statement);
            return NULL;
        }
        if (strcmp(value->type, declared) != 0) {
            sh_fail(sh, "E2S15", "return type mismatch", value->start);
            sh_free_expr(value);
            sh_free_stmt(statement);
            return NULL;
        }
        statement->value = value;
        statement->end = value->end;
        return statement;
    }
    if (strcmp(token_kind(sh->source, at), "identifier") == 0) {
        int64_t after = skip_trivia(sh->source, token_end(sh->source, at));
        if (after < sh->length && token_equal(sh->source, after, "=") &&
            !token_equal(sh->source, after, "==")) {
            int64_t resolved;
            char *name_text = token_copy(sh->source, at);
            resolved = sh_resolve(sh, name_text);
            if (resolved < 0) {
                sh_fail(sh, "E2S35", "unknown lexical binding", at);
                free(name_text);
                return NULL;
            }
            if (!sh->env[resolved].is_mutable) {
                sh_fail(sh, "E2S22", "assignment target is immutable", at);
                free(name_text);
                return NULL;
            }
            free(name_text);
            *cursor = skip_trivia(
                sh->source,
                token_end(sh->source, after)
            );
            ShExpr *value = sh_parse_expr(sh, cursor);
            if (value == NULL) return NULL;
            if (strcmp(value->type, sh->env[resolved].type) != 0) {
                sh_fail(sh, "E2S15", "assignment type mismatch",
                        value->start);
                sh_free_expr(value);
                return NULL;
            }
            ShStmt *statement = sh_stmt_new("assign", at);
            statement->value = value;
            statement->binding_id = sh->env[resolved].binding_id;
            statement->end = value->end;
            return statement;
        }
        ShExpr *value = sh_parse_expr(sh, cursor);
        if (value == NULL) return NULL;
        ShStmt *statement = sh_stmt_new("expr-stmt", at);
        statement->value = value;
        statement->end = value->end;
        return statement;
    }
    sh_fail(sh, "E2S10", "unsupported Core statement", at);
    return NULL;
}

static ShBlock *sh_parse_block(
    Sh *sh,
    int64_t *cursor,
    const char *declared,
    const char *loop_name,
    int64_t loop_name_start,
    int64_t *loop_binding_out
) {
    if (*cursor >= sh->length || !token_equal(sh->source, *cursor, "{")) {
        sh_fail(sh, "E2S18", "expected `{`", *cursor);
        return NULL;
    }
    int64_t open = *cursor;
    int64_t close = balanced_end(sh->source, open, "{", "}");
    if (close < 0) {
        sh_fail(sh, "E2S18", "unbalanced `{`", open);
        return NULL;
    }
    int64_t saved_env = sh->env_count;
    sh_scope_open(sh, "block", open, close);
    if (sh->error != NULL) return NULL;
    ShBlock *block = allocate(sizeof(*block));
    memset(block, 0, sizeof(*block));
    block->scope_id = sh->scope_stack[sh->scope_depth - 1];
    if (loop_name != NULL) {
        int64_t loop_binding = sh_bind(
            sh,
            loop_name,
            "Int",
            false,
            "local",
            loop_name_start,
            token_end(sh->source, loop_name_start)
        );
        if (loop_binding_out != NULL) *loop_binding_out = loop_binding;
    }
    *cursor = skip_trivia(sh->source, token_end(sh->source, open));
    while (
        sh->error == NULL &&
        *cursor < sh->length &&
        !token_equal(sh->source, *cursor, "}")
    ) {
        if (block->count >= 64) {
            sh_fail(sh, "E2S35", "block statement limit is 64", *cursor);
            break;
        }
        ShStmt *statement = sh_parse_stmt(sh, cursor, declared);
        if (statement == NULL) break;
        block->statements[block->count++] = statement;
    }
    if (sh->error == NULL &&
        (*cursor >= sh->length ||
         !token_equal(sh->source, *cursor, "}"))) {
        sh_fail(sh, "E2S18", "expected `}`", *cursor);
    }
    if (sh->error != NULL) {
        sh_scope_close(sh, saved_env);
        sh_free_block(block);
        return NULL;
    }
    *cursor = skip_trivia(sh->source, token_end(sh->source, *cursor));
    sh_scope_close(sh, saved_env);
    return block;
}

/* Decode source string escapes, then re-escape for the record format. */
static void sh_text_literal_field(Buffer *out, const char *token) {
    Buffer decoded;
    buffer_init(&decoded);
    size_t length = strlen(token);
    for (size_t index = 1; index + 1 < length; ++index) {
        char symbol = token[index];
        if (symbol == '\\' && index + 2 < length + 1) {
            char next = token[index + 1];
            char one[2] = {next, '\0'};
            if (next == 'n') one[0] = '\n';
            buffer_append(&decoded, one);
            ++index;
        } else {
            char one[2] = {symbol, '\0'};
            buffer_append(&decoded, one);
        }
    }
    sh_escaped(out, decoded.data);
    free(decoded.data);
}

static int64_t sh_emit_expr(Sh *sh, Buffer *out, ShExpr *expr) {
    int64_t id = sh->next_node++;
    int64_t type_id = sh_scalar_type_id(sh, expr->type);
    const char *ownership = sh_ownership(expr->type, false);
    Buffer children;
    buffer_init(&children);
    Buffer fields;
    buffer_init(&fields);
    if (strcmp(expr->kind, "literal-int") == 0 ||
        strcmp(expr->kind, "literal-bool") == 0) {
        buffer_append(&fields, expr->text);
    } else if (strcmp(expr->kind, "literal-text") == 0) {
        sh_text_literal_field(&fields, expr->text);
    } else if (strcmp(expr->kind, "name") == 0) {
        buffer_format(&fields, "%" PRId64, expr->binding_id);
    } else if (strcmp(expr->kind, "call") == 0) {
        buffer_format(&fields, "%" PRId64, expr->symbol_id);
        for (int64_t index = 0; index < expr->argument_count; ++index) {
            int64_t argument = sh_emit_expr(
                sh,
                &children,
                expr->arguments[index]
            );
            buffer_format(&fields, "|%" PRId64, argument);
        }
    } else if (strcmp(expr->kind, "unary") == 0) {
        int64_t operand = sh_emit_expr(sh, &children, expr->left);
        sh_escaped(&fields, expr->op);
        buffer_format(&fields, "|%" PRId64, operand);
    } else if (strcmp(expr->kind, "binary") == 0) {
        int64_t left = sh_emit_expr(sh, &children, expr->left);
        int64_t right = sh_emit_expr(sh, &children, expr->right);
        sh_escaped(&fields, expr->op);
        buffer_format(&fields, "|%" PRId64 "|%" PRId64, left, right);
    } else if (strcmp(expr->kind, "index") == 0 ||
               strcmp(expr->kind, "range") == 0) {
        int64_t left = sh_emit_expr(sh, &children, expr->left);
        int64_t right = sh_emit_expr(sh, &children, expr->right);
        buffer_format(&fields, "%" PRId64 "|%" PRId64, left, right);
    }
    buffer_format(
        out,
        "node|%" PRId64 "|%s|%" PRId64 "|%" PRId64 "|%" PRId64 "|%s|%s\n",
        id,
        expr->kind,
        expr->start,
        expr->end,
        type_id,
        ownership,
        fields.data
    );
    buffer_append(out, children.data);
    free(children.data);
    free(fields.data);
    return id;
}

static void sh_emit_block(Sh *sh, Buffer *out, ShBlock *block);

static int64_t sh_emit_stmt(Sh *sh, Buffer *out, ShStmt *statement) {
    int64_t id = sh->next_node++;
    int64_t void_id = sh_scalar_type_id(sh, "Void");
    Buffer children;
    buffer_init(&children);
    Buffer fields;
    buffer_init(&fields);
    const char *ownership = "copy";
    if (strcmp(statement->kind, "let") == 0 ||
        strcmp(statement->kind, "let-mut") == 0) {
        int64_t value = sh_emit_expr(sh, &children, statement->value);
        buffer_format(
            &fields,
            "%" PRId64 "|%" PRId64,
            statement->binding_id,
            value
        );
    } else if (strcmp(statement->kind, "assign") == 0) {
        ownership = "edit";
        int64_t value = sh_emit_expr(sh, &children, statement->value);
        buffer_format(
            &fields,
            "%" PRId64 "|%" PRId64,
            statement->binding_id,
            value
        );
    } else if (strcmp(statement->kind, "if") == 0) {
        int64_t condition = sh_emit_expr(sh, &children, statement->value);
        sh_emit_block(sh, &children, statement->body);
        int64_t else_reference = -1;
        if (strcmp(statement->else_kind, "if") == 0) {
            else_reference = sh_emit_stmt(
                sh,
                &children,
                statement->else_if
            );
        } else if (strcmp(statement->else_kind, "block") == 0) {
            else_reference = statement->else_block->scope_id;
            sh_emit_block(sh, &children, statement->else_block);
        }
        buffer_format(
            &fields,
            "%" PRId64 "|%" PRId64 "|%s|%" PRId64,
            condition,
            statement->body->scope_id,
            statement->else_kind,
            else_reference
        );
    } else if (strcmp(statement->kind, "while") == 0) {
        int64_t condition = sh_emit_expr(sh, &children, statement->value);
        sh_emit_block(sh, &children, statement->body);
        buffer_format(
            &fields,
            "%" PRId64 "|%" PRId64,
            condition,
            statement->body->scope_id
        );
    } else if (strcmp(statement->kind, "for-range") == 0) {
        int64_t range = sh_emit_expr(sh, &children, statement->value);
        sh_emit_block(sh, &children, statement->body);
        buffer_format(
            &fields,
            "%" PRId64 "|%" PRId64 "|%" PRId64,
            statement->binding_id,
            range,
            statement->body->scope_id
        );
    } else if (strcmp(statement->kind, "return") == 0) {
        if (statement->value != NULL) {
            int64_t value = sh_emit_expr(sh, &children, statement->value);
            buffer_format(&fields, "%" PRId64, value);
        } else {
            buffer_append(&fields, "none");
        }
    } else if (strcmp(statement->kind, "expr-stmt") == 0) {
        int64_t value = sh_emit_expr(sh, &children, statement->value);
        buffer_format(&fields, "%" PRId64, value);
    }
    buffer_format(
        out,
        "node|%" PRId64 "|%s|%" PRId64 "|%" PRId64 "|%" PRId64 "|%s|%s\n",
        id,
        statement->kind,
        statement->start,
        statement->end,
        void_id,
        ownership,
        fields.data
    );
    buffer_append(out, children.data);
    free(children.data);
    free(fields.data);
    return id;
}

static void sh_emit_block(Sh *sh, Buffer *out, ShBlock *block) {
    for (int64_t index = 0; index < block->count; ++index) {
        sh_emit_stmt(sh, out, block->statements[index]);
    }
}

static bool sh_parse_signature(Sh *sh, int64_t function_start) {
    if (sh->function_count >= 128) {
        sh_fail(sh, "E2S16", "function limit is 128", function_start);
        return false;
    }
    char *name = function_name(sh->source, function_start);
    if (sh_function_index(sh, name) >= 0) {
        sh_fail(sh, "E2S16", "duplicate Core function", function_start);
        free(name);
        return false;
    }
    int64_t slot = sh->function_count;
    snprintf(
        sh->functions[slot].name,
        sizeof(sh->functions[0].name),
        "%s",
        name
    );
    free(name);
    int64_t parameters = parameter_open(sh->source, function_start);
    int64_t parameters_close = parameters >= 0 ?
        balanced_end(sh->source, parameters, "(", ")") : -1;
    if (parameters < 0 || parameters_close < 0) {
        sh_fail(sh, "E2S15", "malformed parameter list", function_start);
        return false;
    }
    int64_t arity = 0;
    int64_t cursor = skip_trivia(
        sh->source,
        token_end(sh->source, parameters)
    );
    while (
        cursor < parameters_close &&
        !token_equal(sh->source, cursor, ")")
    ) {
        if (arity >= 8) {
            sh_fail(sh, "E2S17", "parameter limit is 8", cursor);
            return false;
        }
        int64_t type_at = parameter_type_start(
            sh->source,
            cursor,
            parameters_close
        );
        if (type_at < 0) {
            sh_fail(sh, "E2S15", "parameter needs `: TYPE`", cursor);
            return false;
        }
        /* A callable parameter type spans several tokens and is recorded under
         * one name, so the arity stays right and the head of the type list
         * keeps naming one parameter each. The frozen self-host profile has no
         * callable values, so `Fn` matches no argument type and a call passing
         * one is rejected by the ordinary mismatch rather than being silently
         * accepted as `Int`. */
        int64_t callable_end = callable_type_end(sh->source, type_at);
        char *type_text = callable_end >= 0
            ? owned_text("Fn")
            : token_copy(sh->source, type_at);
        snprintf(
            sh->functions[slot].parameters[arity],
            sizeof(sh->functions[0].parameters[0]),
            "%s",
            type_text
        );
        free(type_text);
        cursor = callable_end >= 0
            ? skip_trivia(sh->source, callable_end)
            : skip_trivia(sh->source, token_end(sh->source, type_at));
        if (strcmp(sh->functions[slot].parameters[arity], "List") == 0) {
            /* consume `[ Text ]` */
            cursor = skip_trivia(sh->source, token_end(sh->source, cursor));
            cursor = skip_trivia(sh->source, token_end(sh->source, cursor));
        }
        ++arity;
        if (
            cursor < parameters_close &&
            token_equal(sh->source, cursor, ",")
        ) {
            cursor = skip_trivia(sh->source, token_end(sh->source, cursor));
        }
    }
    sh->functions[slot].arity = arity;
    int64_t after = skip_trivia(sh->source, parameters_close);
    if (after < sh->length && token_equal(sh->source, after, "->")) {
        int64_t result_at = skip_trivia(
            sh->source,
            token_end(sh->source, after)
        );
        char *result_text = token_copy(sh->source, result_at);
        snprintf(
            sh->functions[slot].result,
            sizeof(sh->functions[0].result),
            "%s",
            result_text
        );
        free(result_text);
    } else {
        snprintf(
            sh->functions[slot].result,
            sizeof(sh->functions[0].result),
            "Void"
        );
    }
    ++sh->function_count;
    return true;
}

static char *emit_selfhost_hir_document(
    const char *source,
    const char *path,
    const char *digest,
    bool *complete_out
) {
    Sh sh;
    memset(&sh, 0, sizeof(sh));
    sh.source = source;
    sh.length = source_length(source);
    buffer_init(&sh.types);
    buffer_init(&sh.scopes);
    buffer_init(&sh.symbols);
    buffer_init(&sh.bindings);
    buffer_init(&sh.nodes);
    buffer_init(&sh.diagnostics);
    sh_scope_open(&sh, "module", 0, sh.length);

    int64_t function_start = next_function_start(source, 0);
    if (function_start >= sh.length) {
        sh_fail(&sh, "E2S04", "source declares no functions", 0);
    }
    while (sh.error == NULL && function_start < sh.length) {
        if (!sh_parse_signature(&sh, function_start)) break;
        /* A declaration whose body never closes ends the walk; its body
         * parse reports the exact brace diagnostic later. */
        int64_t signature_close = function_end(source, function_start);
        if (signature_close < 0) break;
        function_start = next_function_start(source, signature_close);
    }

    /* Function symbols and module bindings, in source order. */
    function_start = next_function_start(source, 0);
    for (
        int64_t index = 0;
        sh.error == NULL && index < sh.function_count;
        ++index
    ) {
        int64_t name_at = skip_trivia(
            source,
            token_end(source, function_start)
        );
        int64_t name_end = token_end(source, name_at);
        int64_t fn_type = sh_fn_type_id(
            &sh,
            sh.functions[index].result,
            sh.functions[index].parameters,
            sh.functions[index].arity
        );
        int64_t symbol_id = sh.next_symbol++;
        sh.functions[index].symbol_id = symbol_id;
        buffer_format(
            &sh.symbols,
            "symbol|%" PRId64 "|function|%s|%" PRId64 "|%" PRId64
            "|%" PRId64 "\n",
            symbol_id,
            sh.functions[index].name,
            fn_type,
            name_at,
            name_end
        );
        buffer_format(
            &sh.bindings,
            "binding|%" PRId64 "|0|%" PRId64 "|%s|imm|%" PRId64
            "|%" PRId64 "\n",
            sh.next_binding++,
            symbol_id,
            sh.functions[index].name,
            name_at,
            name_end
        );
        int64_t symbol_close = function_end(source, function_start);
        if (symbol_close < 0) break;
        function_start = next_function_start(source, symbol_close);
    }

    /* The 17 builtin symbols plus the len List[Text] overload. */
    {
        static const struct {
            const char *name;
            const char *result;
            const char *parameters[3];
            int64_t arity;
        } builtins[] = {
            {"args", "List", {NULL}, 0},
            {"chars", "List", {"Text"}, 1},
            {"contains", "Bool", {"Text", "Text"}, 2},
            {"find", "Int", {"Text", "Text"}, 2},
            {"is_digit", "Bool", {"Text"}, 1},
            {"is_space", "Bool", {"Text"}, 1},
            {"is_xid_continue", "Bool", {"Text"}, 1},
            {"len", "Int", {"Text"}, 1},
            {"print", "Void", {"Text"}, 1},
            {"read_text", "Text", {"Text"}, 1},
            {"replace", "Text", {"Text", "Text", "Text"}, 3},
            {"starts_with", "Bool", {"Text", "Text"}, 2},
            {"text_slice", "Text", {"Text", "Int", "Int"}, 3},
            {"trim", "Text", {"Text"}, 1},
            {"validate_unicode_source", "Text", {"Text"}, 1},
            {"write_text", "Void", {"Text", "Text"}, 2},
        };
        for (int64_t index = 0; sh.error == NULL && index < 16; ++index) {
            char parameters[8][16];
            for (int64_t p = 0; p < builtins[index].arity; ++p) {
                snprintf(
                    parameters[p],
                    sizeof(parameters[0]),
                    "%s",
                    builtins[index].parameters[p]
                );
            }
            int64_t fn_type = sh_fn_type_id(
                &sh,
                builtins[index].result,
                parameters,
                builtins[index].arity
            );
            sh.builtin_symbols[index] = sh.next_symbol++;
            buffer_format(
                &sh.symbols,
                "symbol|%" PRId64 "|builtin|%s|%" PRId64 "|0|0\n",
                sh.builtin_symbols[index],
                builtins[index].name,
                fn_type
            );
        }
        if (sh.error == NULL) {
            char list_parameter[8][16];
            snprintf(list_parameter[0], sizeof(list_parameter[0]), "List");
            int64_t fn_type = sh_fn_type_id(&sh, "Int", list_parameter, 1);
            sh.len_list_symbol = sh.next_symbol++;
            buffer_format(
                &sh.symbols,
                "symbol|%" PRId64 "|builtin|len|%" PRId64 "|0|0\n",
                sh.len_list_symbol,
                fn_type
            );
        }
        /*
         * `fail` is emitted last, after the len List[Text] overload,
         * rather than in its alphabetical place in the table above.
         * Emission order is symbol-id order and those ids are checked-in
         * evidence: alphabetical insertion would renumber thirteen
         * builtins, and appending inside the loop would still push the
         * overload from 17 to 18. Emitting it here leaves every existing
         * id fixed, so the pinned typed-HIR fixtures only gain a line.
         */
        if (sh.error == NULL) {
            char no_parameters[8][16];
            int64_t fn_type = sh_fn_type_id(&sh, "Void", no_parameters, 0);
            sh.builtin_symbols[16] = sh.next_symbol++;
            buffer_format(
                &sh.symbols,
                "symbol|%" PRId64 "|builtin|fail|%" PRId64 "|0|0\n",
                sh.builtin_symbols[16],
                fn_type
            );
        }
    }

    /* Function scopes, parameter bindings, and typed bodies. */
    function_start = next_function_start(source, 0);
    for (
        int64_t index = 0;
        sh.error == NULL && index < sh.function_count;
        ++index
    ) {
        int64_t function_close = function_end(source, function_start);
        int64_t parameters = parameter_open(source, function_start);
        int64_t parameters_close = balanced_end(
            source,
            parameters,
            "(",
            ")"
        );
        int64_t saved_env = sh.env_count;
        sh_scope_open(&sh, "function", parameters, function_close);
        int64_t cursor = skip_trivia(
            source,
            token_end(source, parameters)
        );
        int64_t parameter_index = 0;
        while (
            sh.error == NULL &&
            cursor < parameters_close &&
            !token_equal(source, cursor, ")")
        ) {
            int64_t name_at = parameter_internal_start(
                source,
                cursor,
                parameters_close
            );
            int64_t type_at = parameter_type_start(
                source,
                cursor,
                parameters_close
            );
            if (name_at < 0 || type_at < 0) {
                sh_fail(&sh, "E2S15", "malformed parameter head", cursor);
                break;
            }
            char *name_text = token_copy(source, name_at);
            sh_bind(
                &sh,
                name_text,
                sh.functions[index].parameters[parameter_index],
                false,
                "parameter",
                name_at,
                token_end(source, name_at)
            );
            free(name_text);
            cursor = skip_trivia(source, token_end(source, type_at));
            if (
                strcmp(
                    sh.functions[index].parameters[parameter_index],
                    "List"
                ) == 0
            ) {
                cursor = skip_trivia(source, token_end(source, cursor));
                cursor = skip_trivia(source, token_end(source, cursor));
            }
            ++parameter_index;
            if (
                cursor < parameters_close &&
                token_equal(source, cursor, ",")
            ) {
                cursor = skip_trivia(source, token_end(source, cursor));
            }
        }
        int64_t function_scope = sh.scope_stack[sh.scope_depth - 1];
        int64_t body_at = skip_trivia(source, parameters_close);
        while (
            body_at < function_close &&
            !token_equal(source, body_at, "{")
        ) {
            body_at = skip_trivia(source, token_end(source, body_at));
        }
        int64_t body_cursor = body_at;
        ShBlock *body = sh.error == NULL ?
            sh_parse_block(
                &sh,
                &body_cursor,
                sh.functions[index].result,
                NULL,
                -1,
                NULL
            ) : NULL;
        if (body != NULL) {
            int64_t function_node = sh.next_node++;
            buffer_format(
                &sh.nodes,
                "function|%" PRId64 "|%" PRId64 "|%" PRId64 "|%" PRId64
                "|%" PRId64 "\n",
                function_node,
                sh.functions[index].symbol_id,
                function_scope,
                function_start,
                function_close
            );
            sh_emit_block(&sh, &sh.nodes, body);
            sh_free_block(body);
        }
        sh_scope_close(&sh, saved_env);
        if (function_close < 0) break;
        function_start = next_function_start(source, function_close);
    }

    Buffer document;
    buffer_init(&document);
    buffer_append(&document, "schema|kofun.selfhost-hir/v1\n");
    buffer_format(&document, "source|%s|%s\n", path, digest);
    if (sh.error == NULL) {
        buffer_append(&document, "status|complete\n");
        buffer_append(&document, sh.types.data);
        buffer_append(&document, sh.scopes.data);
        buffer_append(&document, sh.symbols.data);
        buffer_append(&document, sh.bindings.data);
        buffer_append(&document, sh.nodes.data);
        *complete_out = true;
    } else {
        buffer_append(&document, "status|rejected\n");
        int64_t at = sh.error_at >= 0 ? sh.error_at : 0;
        int64_t end = at;
        if (at < sh.length) end = token_end(source, at);
        buffer_format(
            &document,
            "diagnostic|%s|%" PRId64 "|%" PRId64 "|",
            sh.error_code,
            at,
            end
        );
        sh_escaped(&document, sh.error_message);
        buffer_append(&document, "\n");
        /* hir-v1.md requires one `unsupported` record naming the construct
         * family for every construct outside the frozen profile, so `par`
         * carries its own family rather than being filed as a statement. */
        if (strcmp(sh.error_code, "E2S10") == 0 ||
            strcmp(sh.error_code, "E2S154") == 0) {
            buffer_format(
                &document,
                "unsupported|%" PRId64 "|%" PRId64 "|%s\n",
                at,
                end,
                strcmp(sh.error_code, "E2S154") == 0
                    ? "scoped-parallelism"
                    : "statement"
            );
        }
        puts(sh.error);
        *complete_out = false;
    }
    free(sh.error);
    free(sh.types.data);
    free(sh.scopes.data);
    free(sh.symbols.data);
    free(sh.bindings.data);
    free(sh.nodes.data);
    free(sh.diagnostics.data);
    return document.data;
}

static int emit_selfhost_hir_file(
    const char *input,
    const char *output,
    const char *digest
) {
    if (same_file(input, output)) {
        puts("error[E2S35]: selfhost-HIR input and output must be distinct");
        return 2;
    }
    if (strlen(digest) != 64 || strspn(digest, "0123456789abcdef") != 64) {
        puts("error[E2S35]: selfhost-HIR digest must be 64 lowercase hex");
        return 2;
    }
    char *source = read_file(input);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    free(tokens);
    bool complete = false;
    char *document = emit_selfhost_hir_document(
        source,
        input,
        digest,
        &complete
    );
    write_file(output, document);
    free(document);
    free(source);
    return complete ? 0 : 1;
}

/*
 * selfhost-C11 lowering (#620): kofun.selfhost-hir/v1 -> deterministic
 * standalone C11 for the non-looping Text/function profile slice.
 *
 * The document is the only input: node, symbol, binding, scope, and type
 * records drive the lowering; source text is never reparsed. Every
 * expression node lowers post-order to one temporary named after its
 * node id, so argument evaluation is exactly-once and left-to-right, and
 * `&&`/`||` keep short-circuit evaluation through guarded blocks.
 * Constructs outside the slice (mutation, loops, indexing, ranges, and
 * the List/host builtins) classify as unsupported, never as invalid.
 */

enum {
    SL_MAX_RECORDS = 16384,
    SL_MAX_TYPES = 64,
};

typedef struct {
    char *line;
    char *fields[16];
    int64_t field_count;
} SlRecord;

typedef struct {
    char *document;
    SlRecord types[SL_MAX_TYPES];
    char *type_keys[SL_MAX_TYPES];
    int64_t type_count;
    SlRecord scopes[SL_MAX_RECORDS];
    int64_t scope_count;
    SlRecord symbols[SL_MAX_RECORDS];
    int64_t symbol_count;
    SlRecord bindings[SL_MAX_RECORDS];
    int64_t binding_count;
    SlRecord nodes[SL_MAX_RECORDS];
    int64_t node_count;
    char *source_path;
    char *source_digest;
    bool complete;
    char *error;
    int error_exit;
} SlDoc;

static void sl_fail(SlDoc *doc, int exit_code, const char *message) {
    if (doc->error != NULL) return;
    Buffer copy;
    buffer_init(&copy);
    buffer_append(&copy, message);
    doc->error = copy.data;
    doc->error_exit = exit_code;
}

static void sl_fail_name(
    SlDoc *doc,
    int exit_code,
    const char *prefix,
    const char *name
) {
    if (doc->error != NULL) return;
    Buffer copy;
    buffer_init(&copy);
    buffer_format(&copy, "%s`%s`", prefix, name);
    doc->error = copy.data;
    doc->error_exit = exit_code;
}

/* Split one record line in place; fields beyond 16 are an invalid
 * document. Returns false on overflow. */
static bool sl_split(SlRecord *record, char *line) {
    record->line = line;
    record->field_count = 0;
    char *cursor = line;
    while (record->field_count < 16) {
        record->fields[record->field_count++] = cursor;
        char *bar = strchr(cursor, '|');
        if (bar == NULL) return true;
        *bar = '\0';
        cursor = bar + 1;
    }
    return strchr(cursor, '|') == NULL;
}

static const char *sl_field(const SlRecord *record, int64_t index) {
    if (index < 0 || index >= record->field_count) return "";
    return record->fields[index];
}

static int64_t sl_int(const SlRecord *record, int64_t index) {
    return strtoll(sl_field(record, index), NULL, 10);
}

static bool sl_load(SlDoc *doc, const char *text) {
    doc->document = allocate(strlen(text) + 1);
    memcpy(doc->document, text, strlen(text) + 1);
    char *cursor = doc->document;
    int64_t line_index = 0;
    bool schema_seen = false;
    while (*cursor != '\0') {
        char *line = cursor;
        char *newline = strchr(cursor, '\n');
        if (newline == NULL) {
            cursor = line + strlen(line);
        } else {
            *newline = '\0';
            cursor = newline + 1;
        }
        if (line_index == 0) {
            schema_seen = strcmp(line, "schema|kofun.selfhost-hir/v1") == 0;
            if (!schema_seen) {
                sl_fail(doc, 1,
                        "error[E2S35]: selfhost-C11 input is not a "
                        "kofun.selfhost-hir/v1 document");
                return false;
            }
            ++line_index;
            continue;
        }
        (void)schema_seen;
        SlRecord parsed;
        if (!sl_split(&parsed, line)) {
            sl_fail(doc, 1,
                    "error[E2S35]: selfhost-C11 record has too many fields");
            return false;
        }
        const char *tag = sl_field(&parsed, 0);
        SlRecord *slot = NULL;
        if (strcmp(tag, "source") == 0) {
            doc->source_path = allocate(strlen(sl_field(&parsed, 1)) + 1);
            strcpy(doc->source_path, sl_field(&parsed, 1));
            doc->source_digest = allocate(strlen(sl_field(&parsed, 2)) + 1);
            strcpy(doc->source_digest, sl_field(&parsed, 2));
        } else if (strcmp(tag, "status") == 0) {
            doc->complete = strcmp(sl_field(&parsed, 1), "complete") == 0;
        } else if (strcmp(tag, "type") == 0) {
            if (doc->type_count >= SL_MAX_TYPES) {
                sl_fail(doc, 1, "error[E2S35]: selfhost-C11 type limit is 64");
                return false;
            }
            slot = &doc->types[doc->type_count];
            Buffer joined;
            buffer_init(&joined);
            for (int64_t field = 2; field < parsed.field_count; ++field) {
                if (field > 2) buffer_append(&joined, "|");
                buffer_append(&joined, sl_field(&parsed, field));
            }
            doc->type_keys[doc->type_count++] = joined.data;
        } else if (strcmp(tag, "scope") == 0) {
            if (doc->scope_count >= SL_MAX_RECORDS) {
                sl_fail(doc, 1, "error[E2S35]: selfhost-C11 record limit");
                return false;
            }
            slot = &doc->scopes[doc->scope_count++];
        } else if (strcmp(tag, "symbol") == 0) {
            if (doc->symbol_count >= SL_MAX_RECORDS) {
                sl_fail(doc, 1, "error[E2S35]: selfhost-C11 record limit");
                return false;
            }
            slot = &doc->symbols[doc->symbol_count++];
        } else if (strcmp(tag, "binding") == 0) {
            if (doc->binding_count >= SL_MAX_RECORDS) {
                sl_fail(doc, 1, "error[E2S35]: selfhost-C11 record limit");
                return false;
            }
            slot = &doc->bindings[doc->binding_count++];
        } else if (strcmp(tag, "function") == 0 ||
                   strcmp(tag, "node") == 0) {
            if (doc->node_count >= SL_MAX_RECORDS) {
                sl_fail(doc, 1, "error[E2S35]: selfhost-C11 record limit");
                return false;
            }
            slot = &doc->nodes[doc->node_count++];
        }
        if (slot != NULL) {
            *slot = parsed;
        }
        ++line_index;
    }
    if (doc->source_path == NULL) {
        sl_fail(doc, 1,
                "error[E2S35]: selfhost-C11 document has no source record");
        return false;
    }
    if (!doc->complete) {
        sl_fail(doc, 1,
                "error[E2S35]: selfhost-C11 input must be a complete typed "
                "document");
        return false;
    }
    return true;
}

/* The closed type table: id -> key ("int", "bool", "text", "void",
 * "list-text", or "fn|..."). */
static const char *sl_type_key(const SlDoc *doc, int64_t type_id) {
    for (int64_t index = 0; index < doc->type_count; ++index) {
        if (sl_int(&doc->types[index], 1) == type_id) {
            return doc->type_keys[index];
        }
    }
    return "";
}

static const char *sl_c_type(const char *key) {
    if (strcmp(key, "int") == 0) return "int64_t";
    if (strcmp(key, "bool") == 0) return "bool";
    if (strcmp(key, "text") == 0) return "const char *";
    if (strcmp(key, "list-text") == 0) return "kofun_text_list";
    return "";
}

static const SlRecord *sl_symbol(const SlDoc *doc, int64_t symbol_id) {
    for (int64_t index = 0; index < doc->symbol_count; ++index) {
        if (sl_int(&doc->symbols[index], 1) == symbol_id) {
            return &doc->symbols[index];
        }
    }
    return NULL;
}

static const SlRecord *sl_binding(const SlDoc *doc, int64_t binding_id) {
    for (int64_t index = 0; index < doc->binding_count; ++index) {
        if (sl_int(&doc->bindings[index], 1) == binding_id) {
            return &doc->bindings[index];
        }
    }
    return NULL;
}

static const SlRecord *sl_scope(const SlDoc *doc, int64_t scope_id) {
    for (int64_t index = 0; index < doc->scope_count; ++index) {
        if (sl_int(&doc->scopes[index], 1) == scope_id) {
            return &doc->scopes[index];
        }
    }
    return NULL;
}

/* The value type key of a binding: its symbol's recorded type. */
static const char *sl_binding_type(const SlDoc *doc, int64_t binding_id) {
    const SlRecord *binding = sl_binding(doc, binding_id);
    if (binding == NULL) return "";
    const SlRecord *symbol = sl_symbol(doc, sl_int(binding, 3));
    if (symbol == NULL) return "";
    return sl_type_key(doc, sl_int(symbol, 4));
}

/* Result type key of a function-typed symbol: field 1 of its fn key. */
static const char *sl_result_key(const SlDoc *doc, const SlRecord *symbol) {
    const char *key = sl_type_key(doc, sl_int(symbol, 4));
    if (strncmp(key, "fn|", 3) != 0) return "";
    return sl_type_key(doc, strtoll(key + 3, NULL, 10));
}

/* Whether a builtin symbol's single parameter is List[Text] (the len
 * overload outside this slice). */
static bool sl_list_parameter(const SlDoc *doc, const SlRecord *symbol) {
    const char *key = sl_type_key(doc, sl_int(symbol, 4));
    const char *bar = key;
    int64_t seen = 0;
    while (seen < 2 && bar != NULL) {
        bar = strchr(bar, '|');
        if (bar != NULL) ++bar;
        ++seen;
    }
    if (bar == NULL) return false;
    return strcmp(sl_type_key(doc, strtoll(bar, NULL, 10)), "list-text") == 0;
}

/* The audited C runtime shim emitted into every generated program. Text
 * helpers keep the trusted stage-1 seed's observable semantics byte for
 * byte (byte-counted len, byte-offset slicing with clamping, ASCII trim,
 * literal non-overlapping replace); the Unicode builtins consult the same
 * Unicode 17 tables as the Stage 2 lexer via kofun_unicode.c, compiled
 * with the repository's unicode include directory. Allocations use one
 * documented process-lifetime rule: nothing is freed, and allocation
 * failure panics explicitly. */
static const char *sl_prelude =
    "#include <ctype.h>\n"
    "#include <inttypes.h>\n"
    "#include <stdbool.h>\n"
    "#include <stdint.h>\n"
    "#include <stdio.h>\n"
    "#include <stdlib.h>\n"
    "#include <string.h>\n"
    "\n"
    "#include \"kofun_unicode.c\"\n"
    "\n"
    "typedef struct {\n"
    "    int64_t len;\n"
    "    const char **items;\n"
    "} kofun_text_list;\n"
    "\n"
    "int kofun_runtime_argc = 0;\n"
    "char **kofun_runtime_argv = NULL;\n"
    "\n"
    "static bool kofun_failed;\n"
    "\n"
    "static void kofun_error(const char *message) {\n"
    "    if (!kofun_failed) {\n"
    "        fputs(message, stderr);\n"
    "        fputc('\\n', stderr);\n"
    "    }\n"
    "    kofun_failed = true;\n"
    "}\n"
    "\n"
    "static int64_t kofun_add(int64_t left, int64_t right) {\n"
    "    int64_t result;\n"
    "    if (__builtin_add_overflow(left, right, &result)) {\n"
    "        kofun_error(\"error[R010]: integer overflow in operator `+`\");\n"
    "        return 0;\n"
    "    }\n"
    "    return result;\n"
    "}\n"
    "\n"
    "static int64_t kofun_sub(int64_t left, int64_t right) {\n"
    "    int64_t result;\n"
    "    if (__builtin_sub_overflow(left, right, &result)) {\n"
    "        kofun_error(\"error[R010]: integer overflow in operator `-`\");\n"
    "        return 0;\n"
    "    }\n"
    "    return result;\n"
    "}\n"
    "\n"
    "static int64_t kofun_mul(int64_t left, int64_t right) {\n"
    "    int64_t result;\n"
    "    if (__builtin_mul_overflow(left, right, &result)) {\n"
    "        kofun_error(\"error[R010]: integer overflow in operator `*`\");\n"
    "        return 0;\n"
    "    }\n"
    "    return result;\n"
    "}\n"
    "\n"
    "static int64_t kofun_neg(int64_t value) {\n"
    "    if (value == INT64_MIN) {\n"
    "        kofun_error(\n"
    "            \"error[R010]: integer overflow in unary operator `-`\"\n"
    "        );\n"
    "        return 0;\n"
    "    }\n"
    "    return -value;\n"
    "}\n"
    "\n"
    "static int64_t kofun_floor_div(int64_t left, int64_t right) {\n"
    "    if (right == 0) {\n"
    "        kofun_error(\n"
    "            \"error[R010]: operator `//` failed: division by zero\"\n"
    "        );\n"
    "        return 0;\n"
    "    }\n"
    "    if (left == INT64_MIN && right == -1) {\n"
    "        kofun_error(\"error[R010]: integer overflow in operator `//`\");\n"
    "        return 0;\n"
    "    }\n"
    "    int64_t quotient = left / right;\n"
    "    int64_t remainder = left % right;\n"
    "    if (remainder != 0 && ((remainder < 0) != (right < 0))) {\n"
    "        --quotient;\n"
    "    }\n"
    "    return quotient;\n"
    "}\n"
    "\n"
    "static int64_t kofun_floor_mod(int64_t left, int64_t right) {\n"
    "    if (right == 0) {\n"
    "        kofun_error(\n"
    "            \"error[R010]: operator `%` failed: division by zero\"\n"
    "        );\n"
    "        return 0;\n"
    "    }\n"
    "    if (left == INT64_MIN && right == -1) {\n"
    "        return 0;\n"
    "    }\n"
    "    int64_t remainder = left % right;\n"
    "    if (remainder != 0 && ((remainder < 0) != (right < 0))) {\n"
    "        remainder += right;\n"
    "    }\n"
    "    return remainder;\n"
    "}\n"
    "\n"
    "";

/*
 * `kofun_rt_fail` is the whole of the `fail` builtin's host capability:
 * it ends the process with a nonzero status and writes nothing. The
 * program has already printed whatever diagnostic it wants, so adding a
 * message here would change the pinned stdout of every refusing corpus.
 */
static const char *sl_prelude_text =
    "void kofun_rt_panic(const char *message) {\n"
    "    fprintf(stderr, \"Kofun runtime error: %s\\n\", message);\n"
    "    exit(1);\n"
    "}\n"
    "\n"
    "void kofun_rt_fail(void) {\n"
    "    exit(1);\n"
    "}\n"
    "\n"
    "void *kofun_rt_alloc(size_t size) {\n"
    "    void *value = malloc(size == 0 ? 1 : size);\n"
    "    if (value == NULL) {\n"
    "        kofun_rt_panic(\"out of memory\");\n"
    "    }\n"
    "    return value;\n"
    "}\n"
    "\n"
    "char *kofun_rt_copy_n(const char *value, size_t length) {\n"
    "    char *result = (char *)kofun_rt_alloc(length + 1);\n"
    "    if (length > 0) {\n"
    "        memcpy(result, value, length);\n"
    "    }\n"
    "    result[length] = '\\0';\n"
    "    return result;\n"
    "}\n"
    "\n"
    "char *kofun_rt_text_concat(const char *left, const char *right) {\n"
    "    size_t left_len = strlen(left);\n"
    "    size_t right_len = strlen(right);\n"
    "    char *result = (char *)kofun_rt_alloc(left_len + right_len + 1);\n"
    "    memcpy(result, left, left_len);\n"
    "    memcpy(result + left_len, right, right_len + 1);\n"
    "    return result;\n"
    "}\n"
    "\n"
    "bool kofun_rt_text_equal(const char *left, const char *right) {\n"
    "    while (*left != '\\0' && *right != '\\0') {\n"
    "        if (*left != *right) return false;\n"
    "        left += 1;\n"
    "        right += 1;\n"
    "    }\n"
    "    return *left == *right;\n"
    "}\n"
    "\n"
    "int64_t kofun_rt_text_len(const char *value) {\n"
    "    return (int64_t)strlen(value);\n"
    "}\n"
    "\n"
    "int64_t kofun_rt_text_list_len(kofun_text_list values) {\n"
    "    return values.len;\n"
    "}\n"
    "\n"
    "kofun_text_list kofun_rt_args(void) {\n"
    "    kofun_text_list result;\n"
    "    result.len = (int64_t)kofun_runtime_argc;\n"
    "    result.items = (const char **)kofun_runtime_argv;\n"
    "    return result;\n"
    "}\n"
    "\n"
    "kofun_text_list kofun_rt_chars(const char *value) {\n"
    "    size_t length = strlen(value);\n"
    "    if (length > SIZE_MAX / (sizeof(char *) + 2)) {\n"
    "        kofun_rt_panic(\"List[Text] allocation is too large\");\n"
    "    }\n"
    "    size_t pointer_bytes = sizeof(char *) * length;\n"
    "    char *storage = (char *)kofun_rt_alloc(\n"
    "        length == 0 ? 1 : pointer_bytes + 2 * length\n"
    "    );\n"
    "    const char **items = (const char **)storage;\n"
    "    char *characters = storage + pointer_bytes;\n"
    "    for (size_t index = 0; index < length; ++index) {\n"
    "        characters[2 * index] = value[index];\n"
    "        characters[2 * index + 1] = '\\0';\n"
    "        items[index] = characters + 2 * index;\n"
    "    }\n"
    "    kofun_text_list result;\n"
    "    result.len = (int64_t)length;\n"
    "    result.items = items;\n"
    "    return result;\n"
    "}\n"
    "\n"
    "const char *kofun_rt_text_list_get(kofun_text_list values, int64_t index) {\n"
    "    if (index < 0 || index >= values.len) {\n"
    "        kofun_rt_panic(\"List[Text] index out of bounds\");\n"
    "    }\n"
    "    return values.items[index];\n"
    "}\n"
    "\n"
    "bool kofun_rt_text_contains(const char *value, const char *needle) {\n"
    "    return strstr(value, needle) != NULL;\n"
    "}\n"
    "\n"
    "int64_t kofun_rt_find(const char *value, const char *needle) {\n"
    "    const char *found = strstr(value, needle);\n"
    "    return found == NULL ? INT64_C(-1) : (int64_t)(found - value);\n"
    "}\n"
    "\n"
    "char *kofun_rt_text_slice(const char *value, int64_t start, int64_t end) {\n"
    "    int64_t length = (int64_t)strlen(value);\n"
    "    if (start < 0) start = 0;\n"
    "    if (end < start) end = start;\n"
    "    if (start > length) start = length;\n"
    "    if (end > length) end = length;\n"
    "    return kofun_rt_copy_n(value + start, (size_t)(end - start));\n"
    "}\n"
    "\n"
    "char *kofun_rt_trim(const char *value) {\n"
    "    const unsigned char *start = (const unsigned char *)value;\n"
    "    while (*start != '\\0' && isspace(*start)) {\n"
    "        ++start;\n"
    "    }\n"
    "    const unsigned char *end =\n"
    "        (const unsigned char *)value + strlen(value);\n"
    "    while (end > start && isspace(end[-1])) {\n"
    "        --end;\n"
    "    }\n"
    "    return kofun_rt_copy_n((const char *)start, (size_t)(end - start));\n"
    "}\n"
    "\n"
    "";

static const char *sl_prelude_unicode =
    "char *kofun_rt_replace(\n"
    "    const char *value,\n"
    "    const char *old,\n"
    "    const char *replacement\n"
    ") {\n"
    "    size_t old_len = strlen(old);\n"
    "    if (old_len == 0) {\n"
    "        return kofun_rt_copy_n(value, strlen(value));\n"
    "    }\n"
    "    size_t replacement_len = strlen(replacement);\n"
    "    size_t count = 0;\n"
    "    const char *cursor = value;\n"
    "    while ((cursor = strstr(cursor, old)) != NULL) {\n"
    "        ++count;\n"
    "        cursor += old_len;\n"
    "    }\n"
    "    size_t value_len = strlen(value);\n"
    "    size_t result_len;\n"
    "    if (replacement_len >= old_len) {\n"
    "        result_len = value_len + count * (replacement_len - old_len);\n"
    "    } else {\n"
    "        result_len = value_len - count * (old_len - replacement_len);\n"
    "    }\n"
    "    char *result = (char *)kofun_rt_alloc(result_len + 1);\n"
    "    char *out = result;\n"
    "    cursor = value;\n"
    "    const char *match;\n"
    "    while ((match = strstr(cursor, old)) != NULL) {\n"
    "        size_t prefix = (size_t)(match - cursor);\n"
    "        memcpy(out, cursor, prefix);\n"
    "        out += prefix;\n"
    "        memcpy(out, replacement, replacement_len);\n"
    "        out += replacement_len;\n"
    "        cursor = match + old_len;\n"
    "    }\n"
    "    strcpy(out, cursor);\n"
    "    return result;\n"
    "}\n"
    "\n"
    "bool kofun_rt_starts_with(const char *value, const char *prefix) {\n"
    "    size_t prefix_len = strlen(prefix);\n"
    "    return strncmp(value, prefix, prefix_len) == 0;\n"
    "}\n"
    "\n"
    "bool kofun_rt_is_digit(const char *value) {\n"
    "    return value[0] != '\\0' && value[1] == '\\0' &&\n"
    "        isdigit((unsigned char)value[0]) != 0;\n"
    "}\n"
    "\n"
    "bool kofun_rt_is_space(const char *value) {\n"
    "    return value[0] != '\\0' && value[1] == '\\0' &&\n"
    "        isspace((unsigned char)value[0]) != 0;\n"
    "}\n"
    "\n"
    "bool kofun_rt_is_xid_continue(const char *value) {\n"
    "    uint32_t codepoint = 0;\n"
    "    size_t width = 0;\n"
    "    size_t length = strlen(value);\n"
    "    if (!kofun_unicode_decode(\n"
    "            (const uint8_t *)value,\n"
    "            length,\n"
    "            0,\n"
    "            &codepoint,\n"
    "            &width)) {\n"
    "        return false;\n"
    "    }\n"
    "    return kofun_unicode_is_xid_continue(codepoint);\n"
    "}\n"
    "\n"
    "const char *kofun_rt_validate_unicode_source(const char *value) {\n"
    "    KofunUnicodeError unicode_error;\n"
    "    if (kofun_unicode_validate_source(\n"
    "            (const uint8_t *)value,\n"
    "            strlen(value),\n"
    "            &unicode_error)) {\n"
    "        return \"\";\n"
    "    }\n"
    "    char message[1024];\n"
    "    kofun_unicode_format_error(\n"
    "        &unicode_error,\n"
    "        getenv(\"KOFUN_DIAGNOSTIC_LOCALE\"),\n"
    "        message,\n"
    "        sizeof(message)\n"
    "    );\n"
    "    return kofun_rt_copy_n(message, strlen(message));\n"
    "}\n"
    "\n"
    "char *kofun_rt_read_text(const char *path) {\n"
    "    FILE *file = fopen(path, \"rb\");\n"
    "    if (file == NULL) {\n"
    "        kofun_rt_panic(\"cannot open input file\");\n"
    "    }\n"
    "    if (fseek(file, 0, SEEK_END) != 0) {\n"
    "        fclose(file);\n"
    "        kofun_rt_panic(\"cannot seek input file\");\n"
    "    }\n"
    "    long size = ftell(file);\n"
    "    if (size < 0) {\n"
    "        fclose(file);\n"
    "        kofun_rt_panic(\"cannot measure input file\");\n"
    "    }\n"
    "    rewind(file);\n"
    "    char *result = (char *)kofun_rt_alloc((size_t)size + 1);\n"
    "    size_t read = fread(result, 1, (size_t)size, file);\n"
    "    if (read != (size_t)size && ferror(file)) {\n"
    "        fclose(file);\n"
    "        kofun_rt_panic(\"cannot read input file\");\n"
    "    }\n"
    "    result[read] = '\\0';\n"
    "    fclose(file);\n"
    "    return result;\n"
    "}\n"
    "\n"
    "void kofun_rt_write_text(const char *path, const char *value) {\n"
    "    FILE *file = fopen(path, \"wb\");\n"
    "    if (file == NULL) {\n"
    "        kofun_rt_panic(\"cannot open output file\");\n"
    "    }\n"
    "    size_t length = strlen(value);\n"
    "    if (fwrite(value, 1, length, file) != length) {\n"
    "        fclose(file);\n"
    "        kofun_rt_panic(\"cannot write output file\");\n"
    "    }\n"
    "    if (fclose(file) != 0) {\n"
    "        kofun_rt_panic(\"cannot close output file\");\n"
    "    }\n"
    "}\n"
    "\n";

typedef struct {
    const SlDoc *doc;
    int64_t first_node;
    int64_t last_node;
    const char *fail_return;
    const char *function_name;
    int64_t indent;
} SlFn;

static const SlRecord *sl_node(const SlFn *fn, int64_t node_id) {
    for (int64_t index = fn->first_node; index < fn->last_node; ++index) {
        if (sl_int(&fn->doc->nodes[index], 1) == node_id) {
            return &fn->doc->nodes[index];
        }
    }
    return NULL;
}

static void sl_indent(const SlFn *fn, Buffer *out) {
    for (int64_t level = 0; level < fn->indent; ++level) {
        buffer_append(out, "    ");
    }
}

/* Emit the failure check after a temporary that can set kofun_failed. */
static void sl_failed_check(const SlFn *fn, Buffer *out) {
    sl_indent(fn, out);
    if (fn->fail_return[0] == '\0') {
        buffer_append(out, "if (kofun_failed) return;\n");
    } else {
        buffer_format(out, "if (kofun_failed) return %s;\n",
                      fn->fail_return);
    }
}

/* Decode the record escaping of a literal-text field, then re-escape the
 * bytes as one C string literal. */
static void sl_c_string(Buffer *out, const char *field) {
    buffer_append(out, "\"");
    for (size_t index = 0; field[index] != '\0'; ++index) {
        char symbol = field[index];
        if (symbol == '\\' && field[index + 1] != '\0') {
            char next = field[index + 1];
            if (next == '\\') symbol = '\\';
            else if (next == 'p') symbol = '|';
            else if (next == 'n') symbol = '\n';
            ++index;
        }
        if (symbol == '\\') buffer_append(out, "\\\\");
        else if (symbol == '"') buffer_append(out, "\\\"");
        else if (symbol == '\n') buffer_append(out, "\\n");
        else {
            char one[2] = {symbol, '\0'};
            buffer_append(out, one);
        }
    }
    buffer_append(out, "\"");
}

static void sl_emit_expr(SlFn *fn, SlDoc *doc, int64_t node_id, Buffer *out);

/* Positional pre-order size of the expression subtree rooted at `index`;
 * used to find where a statement's trailing records begin. */
static int64_t sl_consume_expr(SlFn *fn, int64_t index) {
    const SlRecord *node = &fn->doc->nodes[index];
    const char *kind = sl_field(node, 2);
    int64_t next = index + 1;
    if (strcmp(kind, "call") == 0) {
        for (int64_t field = 8; field < node->field_count; ++field) {
            next = sl_consume_expr(fn, next);
        }
        return next;
    }
    if (strcmp(kind, "unary") == 0) {
        return sl_consume_expr(fn, next);
    }
    if (strcmp(kind, "binary") == 0 || strcmp(kind, "index") == 0 ||
        strcmp(kind, "range") == 0) {
        next = sl_consume_expr(fn, next);
        return sl_consume_expr(fn, next);
    }
    return next;
}

/* Map a slice builtin to its runtime helper; NULL when the builtin is
 * outside the non-looping Text slice. */
static const char *sl_builtin_helper(const char *name) {
    if (strcmp(name, "args") == 0) return "kofun_rt_args";
    if (strcmp(name, "chars") == 0) return "kofun_rt_chars";
    if (strcmp(name, "contains") == 0) return "kofun_rt_text_contains";
    if (strcmp(name, "fail") == 0) return "kofun_rt_fail";
    if (strcmp(name, "find") == 0) return "kofun_rt_find";
    if (strcmp(name, "is_digit") == 0) return "kofun_rt_is_digit";
    if (strcmp(name, "is_space") == 0) return "kofun_rt_is_space";
    if (strcmp(name, "is_xid_continue") == 0) {
        return "kofun_rt_is_xid_continue";
    }
    if (strcmp(name, "len") == 0) return "kofun_rt_text_len";
    if (strcmp(name, "print") == 0) return "printf";
    if (strcmp(name, "replace") == 0) return "kofun_rt_replace";
    if (strcmp(name, "starts_with") == 0) return "kofun_rt_starts_with";
    if (strcmp(name, "text_slice") == 0) return "kofun_rt_text_slice";
    if (strcmp(name, "read_text") == 0) return "kofun_rt_read_text";
    if (strcmp(name, "trim") == 0) return "kofun_rt_trim";
    if (strcmp(name, "validate_unicode_source") == 0) {
        return "kofun_rt_validate_unicode_source";
    }
    if (strcmp(name, "write_text") == 0) return "kofun_rt_write_text";
    return NULL;
}

static void sl_emit_expr(SlFn *fn, SlDoc *doc, int64_t node_id, Buffer *out) {
    if (doc->error != NULL) return;
    const SlRecord *node = sl_node(fn, node_id);
    if (node == NULL) {
        sl_fail(doc, 1, "error[E2S35]: selfhost-C11 node reference is out "
                        "of range");
        return;
    }
    const char *kind = sl_field(node, 2);
    const char *type_key = sl_type_key(doc, sl_int(node, 5));
    if (strcmp(kind, "literal-int") == 0) {
        sl_indent(fn, out);
        buffer_format(out, "int64_t k_n%" PRId64 " = INT64_C(", node_id);
        const char *digits = sl_field(node, 7);
        for (size_t at = 0; digits[at] != '\0'; ++at) {
            if (digits[at] != '_') {
                char one[2] = {digits[at], '\0'};
                buffer_append(out, one);
            }
        }
        buffer_append(out, ");\n");
        return;
    }
    if (strcmp(kind, "literal-bool") == 0) {
        sl_indent(fn, out);
        buffer_format(out, "bool k_n%" PRId64 " = %s;\n", node_id,
                      sl_field(node, 7));
        return;
    }
    if (strcmp(kind, "literal-text") == 0) {
        sl_indent(fn, out);
        buffer_format(out, "const char *k_n%" PRId64 " = ", node_id);
        sl_c_string(out, sl_field(node, 7));
        buffer_append(out, ";\n");
        return;
    }
    if (strcmp(kind, "name") == 0) {
        if (sl_c_type(type_key)[0] == '\0') {
            sl_fail_name(doc, 3,
                         "error[E2S10]: unsupported selfhost-C11 type ",
                         type_key);
            return;
        }
        sl_indent(fn, out);
        buffer_format(out, "%s k_n%" PRId64 " = k_b%s;\n",
                      sl_c_type(type_key), node_id, sl_field(node, 7));
        return;
    }
    if (strcmp(kind, "call") == 0) {
        const SlRecord *symbol = sl_symbol(doc, sl_int(node, 7));
        if (symbol == NULL) {
            sl_fail(doc, 1, "error[E2S35]: selfhost-C11 call has no symbol");
            return;
        }
        const char *name = sl_field(symbol, 3);
        bool builtin = strcmp(sl_field(symbol, 2), "builtin") == 0;
        const char *helper = NULL;
        if (builtin) {
            helper = sl_builtin_helper(name);
            if (strcmp(name, "len") == 0 &&
                sl_list_parameter(doc, symbol)) {
                helper = "kofun_rt_text_list_len";
            }
            if (helper == NULL) {
                sl_fail_name(doc, 3,
                             "error[E2S10]: unsupported selfhost-C11 "
                             "builtin call ",
                             name);
                return;
            }
        }
        for (int64_t field = 8; field < node->field_count; ++field) {
            sl_emit_expr(fn, doc, sl_int(node, field), out);
            if (doc->error != NULL) return;
        }
        sl_indent(fn, out);
        if (builtin && strcmp(name, "print") == 0) {
            buffer_format(out, "printf(\"%%s\\n\", k_n%s);\n",
                          sl_field(node, 8));
            return;
        }
        if (strcmp(type_key, "void") == 0 && builtin) {
            buffer_format(out, "%s(", helper);
        } else if (strcmp(type_key, "void") == 0) {
            buffer_format(out, "kofun_fn_%s(", name);
        } else if (builtin) {
            buffer_format(out, "%s k_n%" PRId64 " = %s(",
                          sl_c_type(type_key), node_id, helper);
        } else {
            buffer_format(out, "%s k_n%" PRId64 " = kofun_fn_%s(",
                          sl_c_type(type_key), node_id, name);
        }
        for (int64_t field = 8; field < node->field_count; ++field) {
            if (field > 8) buffer_append(out, ", ");
            buffer_format(out, "k_n%s", sl_field(node, field));
        }
        buffer_append(out, ");\n");
        if (!builtin) {
            sl_failed_check(fn, out);
        }
        return;
    }
    if (strcmp(kind, "unary") == 0) {
        const char *op = sl_field(node, 7);
        int64_t operand = sl_int(node, 8);
        sl_emit_expr(fn, doc, operand, out);
        if (doc->error != NULL) return;
        sl_indent(fn, out);
        if (strcmp(op, "!") == 0) {
            buffer_format(out, "bool k_n%" PRId64 " = !k_n%" PRId64 ";\n",
                          node_id, operand);
        } else {
            buffer_format(out,
                          "int64_t k_n%" PRId64 " = kofun_neg(k_n%" PRId64
                          ");\n",
                          node_id, operand);
            sl_failed_check(fn, out);
        }
        return;
    }
    if (strcmp(kind, "binary") == 0) {
        const char *op = sl_field(node, 7);
        int64_t left = sl_int(node, 8);
        int64_t right = sl_int(node, 9);
        const SlRecord *left_node = sl_node(fn, left);
        const char *left_key = left_node == NULL ?
            "" : sl_type_key(doc, sl_int(left_node, 5));
        bool logical = strcmp(op, "&&") == 0 || strcmp(op, "\\p\\p") == 0;
        bool logical_or = strcmp(op, "\\p\\p") == 0;
        if (logical) {
            sl_emit_expr(fn, doc, left, out);
            if (doc->error != NULL) return;
            sl_indent(fn, out);
            buffer_format(out, "bool k_n%" PRId64 " = k_n%" PRId64 ";\n",
                          node_id, left);
            sl_indent(fn, out);
            if (logical_or) {
                buffer_format(out, "if (!k_n%" PRId64 ") {\n", node_id);
            } else {
                buffer_format(out, "if (k_n%" PRId64 ") {\n", node_id);
            }
            fn->indent += 1;
            sl_emit_expr(fn, doc, right, out);
            if (doc->error != NULL) return;
            sl_indent(fn, out);
            buffer_format(out, "k_n%" PRId64 " = k_n%" PRId64 ";\n",
                          node_id, right);
            fn->indent -= 1;
            sl_indent(fn, out);
            buffer_append(out, "}\n");
            return;
        }
        sl_emit_expr(fn, doc, left, out);
        if (doc->error != NULL) return;
        sl_emit_expr(fn, doc, right, out);
        if (doc->error != NULL) return;
        if (strcmp(op, "+") == 0 && strcmp(left_key, "text") == 0) {
            sl_indent(fn, out);
            buffer_format(out,
                          "const char *k_n%" PRId64
                          " = kofun_rt_text_concat(k_n%" PRId64
                          ", k_n%" PRId64 ");\n",
                          node_id, left, right);
            return;
        }
        if (strcmp(op, "==") == 0 || strcmp(op, "!=") == 0) {
            sl_indent(fn, out);
            if (strcmp(left_key, "text") == 0) {
                buffer_format(out,
                              "bool k_n%" PRId64
                              " = %skofun_rt_text_equal(k_n%" PRId64
                              ", k_n%" PRId64 ");\n",
                              node_id,
                              op[0] == '!' ? "!" : "",
                              left, right);
            } else {
                buffer_format(out,
                              "bool k_n%" PRId64 " = k_n%" PRId64
                              " %s k_n%" PRId64 ";\n",
                              node_id, left, op, right);
            }
            return;
        }
        if (strcmp(op, "<") == 0 || strcmp(op, "<=") == 0 ||
            strcmp(op, ">") == 0 || strcmp(op, ">=") == 0) {
            if (strcmp(left_key, "text") == 0) {
                sl_fail_name(doc, 3,
                             "error[E2S10]: unsupported selfhost-C11 "
                             "operator ",
                             op);
                return;
            }
            sl_indent(fn, out);
            buffer_format(out,
                          "bool k_n%" PRId64 " = k_n%" PRId64 " %s k_n%"
                          PRId64 ";\n",
                          node_id, left, op, right);
            return;
        }
        const char *arithmetic = NULL;
        if (strcmp(op, "+") == 0) arithmetic = "kofun_add";
        if (strcmp(op, "-") == 0) arithmetic = "kofun_sub";
        if (strcmp(op, "*") == 0) arithmetic = "kofun_mul";
        if (strcmp(op, "//") == 0) arithmetic = "kofun_floor_div";
        if (strcmp(op, "%") == 0) arithmetic = "kofun_floor_mod";
        if (arithmetic == NULL) {
            sl_fail_name(doc, 3,
                         "error[E2S10]: unsupported selfhost-C11 operator ",
                         op);
            return;
        }
        sl_indent(fn, out);
        buffer_format(out,
                      "int64_t k_n%" PRId64 " = %s(k_n%" PRId64
                      ", k_n%" PRId64 ");\n",
                      node_id, arithmetic, left, right);
        sl_failed_check(fn, out);
        return;
    }
    if (strcmp(kind, "index") == 0) {
        int64_t base = sl_int(node, 7);
        int64_t position = sl_int(node, 8);
        sl_emit_expr(fn, doc, base, out);
        if (doc->error != NULL) return;
        sl_emit_expr(fn, doc, position, out);
        if (doc->error != NULL) return;
        sl_indent(fn, out);
        buffer_format(out,
                      "const char *k_n%" PRId64
                      " = kofun_rt_text_list_get(k_n%" PRId64
                      ", k_n%" PRId64 ");\n",
                      node_id, base, position);
        return;
    }
    sl_fail_name(doc, 3,
                 "error[E2S10]: unsupported selfhost-C11 expression ",
                 kind);
}

/* Emit the statement record at `index`; returns the next record index
 * and reports through `terminal` whether the statement always returns. */
static int64_t sl_emit_statement(
    SlFn *fn,
    SlDoc *doc,
    int64_t index,
    Buffer *out,
    bool *terminal
);

/* Emit the statements whose spans lie inside one block scope. */
static int64_t sl_emit_block(
    SlFn *fn,
    SlDoc *doc,
    int64_t index,
    int64_t scope_id,
    Buffer *out,
    bool *terminal
) {
    const SlRecord *scope = sl_scope(doc, scope_id);
    if (scope == NULL) {
        sl_fail(doc, 1, "error[E2S35]: selfhost-C11 scope reference is out "
                        "of range");
        return index;
    }
    int64_t scope_start = sl_int(scope, 4);
    int64_t scope_end = sl_int(scope, 5);
    *terminal = false;
    while (doc->error == NULL && index < fn->last_node) {
        const SlRecord *node = &fn->doc->nodes[index];
        if (strcmp(sl_field(node, 0), "node") != 0) break;
        int64_t start = sl_int(node, 3);
        if (start < scope_start || start >= scope_end) break;
        index = sl_emit_statement(fn, doc, index, out, terminal);
    }
    return index;
}

static int64_t sl_emit_statement(
    SlFn *fn,
    SlDoc *doc,
    int64_t index,
    Buffer *out,
    bool *terminal
) {
    const SlRecord *node = &fn->doc->nodes[index];
    const char *kind = sl_field(node, 2);
    *terminal = false;
    if (doc->error != NULL) return fn->last_node;
    if (strcmp(kind, "let") == 0 || strcmp(kind, "let-mut") == 0) {
        int64_t value = sl_int(node, 8);
        sl_emit_expr(fn, doc, value, out);
        if (doc->error != NULL) return fn->last_node;
        const char *binding_key = sl_binding_type(doc, sl_int(node, 7));
        if (sl_c_type(binding_key)[0] == '\0') {
            sl_fail_name(doc, 3,
                         "error[E2S10]: unsupported selfhost-C11 type ",
                         binding_key);
            return fn->last_node;
        }
        sl_indent(fn, out);
        buffer_format(out, "%s k_b%s = k_n%" PRId64 ";\n",
                      sl_c_type(binding_key), sl_field(node, 7), value);
        return sl_consume_expr(fn, index + 1);
    }
    if (strcmp(kind, "return") == 0) {
        *terminal = true;
        if (strcmp(sl_field(node, 7), "none") == 0) {
            sl_indent(fn, out);
            if (strcmp(fn->function_name, "main") == 0) {
                buffer_append(out, "return 0;\n");
            } else {
                buffer_append(out, "return;\n");
            }
            return index + 1;
        }
        int64_t value = sl_int(node, 7);
        sl_emit_expr(fn, doc, value, out);
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        if (strcmp(fn->function_name, "main") == 0) {
            buffer_format(out, "return (int)k_n%" PRId64 ";\n", value);
        } else {
            buffer_format(out, "return k_n%" PRId64 ";\n", value);
        }
        return sl_consume_expr(fn, index + 1);
    }
    if (strcmp(kind, "expr-stmt") == 0) {
        int64_t value = sl_int(node, 7);
        sl_emit_expr(fn, doc, value, out);
        if (doc->error != NULL) return fn->last_node;
        const SlRecord *value_node = sl_node(fn, value);
        if (value_node != NULL &&
            strcmp(sl_type_key(doc, sl_int(value_node, 5)), "void") != 0) {
            sl_indent(fn, out);
            buffer_format(out, "(void)k_n%" PRId64 ";\n", value);
        }
        return sl_consume_expr(fn, index + 1);
    }
    if (strcmp(kind, "if") == 0) {
        int64_t condition = sl_int(node, 7);
        int64_t then_scope = sl_int(node, 8);
        const char *else_kind = sl_field(node, 9);
        sl_emit_expr(fn, doc, condition, out);
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_format(out, "if (k_n%" PRId64 ") {\n", condition);
        fn->indent += 1;
        bool then_terminal = false;
        int64_t walk = sl_consume_expr(fn, index + 1);
        walk = sl_emit_block(fn, doc, walk, then_scope, out,
                             &then_terminal);
        fn->indent -= 1;
        if (doc->error != NULL) return fn->last_node;
        if (strcmp(else_kind, "none") == 0) {
            sl_indent(fn, out);
            buffer_append(out, "}\n");
            return walk;
        }
        sl_indent(fn, out);
        buffer_append(out, "} else {\n");
        fn->indent += 1;
        bool else_terminal = false;
        if (strcmp(else_kind, "block") == 0) {
            walk = sl_emit_block(fn, doc, walk, sl_int(node, 10), out,
                                 &else_terminal);
        } else {
            walk = sl_emit_statement(fn, doc, walk, out, &else_terminal);
        }
        fn->indent -= 1;
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_append(out, "}\n");
        *terminal = then_terminal && else_terminal;
        return walk;
    }
    if (strcmp(kind, "assign") == 0) {
        int64_t value = sl_int(node, 8);
        sl_emit_expr(fn, doc, value, out);
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_format(out, "k_b%s = k_n%" PRId64 ";\n",
                      sl_field(node, 7), value);
        return sl_consume_expr(fn, index + 1);
    }
    if (strcmp(kind, "while") == 0) {
        int64_t condition = sl_int(node, 7);
        sl_indent(fn, out);
        buffer_append(out, "for (;;) {\n");
        fn->indent += 1;
        sl_emit_expr(fn, doc, condition, out);
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_format(out, "if (!k_n%" PRId64 ") break;\n", condition);
        bool body_terminal = false;
        int64_t walk = sl_consume_expr(fn, index + 1);
        walk = sl_emit_block(fn, doc, walk, sl_int(node, 8), out,
                             &body_terminal);
        fn->indent -= 1;
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_append(out, "}\n");
        return walk;
    }
    if (strcmp(kind, "for-range") == 0) {
        const SlRecord *range = sl_node(fn, sl_int(node, 8));
        if (range == NULL) {
            sl_fail(doc, 1, "error[E2S35]: selfhost-C11 node reference is "
                            "out of range");
            return fn->last_node;
        }
        int64_t low = sl_int(range, 7);
        int64_t high = sl_int(range, 8);
        sl_emit_expr(fn, doc, low, out);
        if (doc->error != NULL) return fn->last_node;
        sl_emit_expr(fn, doc, high, out);
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_format(out,
                      "for (int64_t k_b%s = k_n%" PRId64 "; k_b%s < k_n%"
                      PRId64 "; ++k_b%s) {\n",
                      sl_field(node, 7), low, sl_field(node, 7), high,
                      sl_field(node, 7));
        fn->indent += 1;
        bool body_terminal = false;
        int64_t walk = sl_consume_expr(fn, index + 1);
        walk = sl_emit_block(fn, doc, walk, sl_int(node, 9), out,
                             &body_terminal);
        fn->indent -= 1;
        if (doc->error != NULL) return fn->last_node;
        sl_indent(fn, out);
        buffer_append(out, "}\n");
        return walk;
    }
    sl_fail_name(doc, 3,
                 "error[E2S10]: unsupported selfhost-C11 statement ", kind);
    return fn->last_node;
}

/* Parameter bindings of one function scope, in binding order. */
static void sl_parameters(
    SlDoc *doc,
    int64_t function_scope,
    Buffer *out,
    int64_t *arity
) {
    *arity = 0;
    for (int64_t index = 0; index < doc->binding_count; ++index) {
        const SlRecord *binding = &doc->bindings[index];
        if (sl_int(binding, 2) != function_scope) continue;
        const SlRecord *symbol = sl_symbol(doc, sl_int(binding, 3));
        if (symbol == NULL ||
            strcmp(sl_field(symbol, 2), "parameter") != 0) {
            continue;
        }
        const char *key = sl_type_key(doc, sl_int(symbol, 4));
        if (sl_c_type(key)[0] == '\0') {
            sl_fail_name(doc, 3,
                         "error[E2S10]: unsupported selfhost-C11 type ",
                         key);
            return;
        }
        if (*arity > 0) buffer_append(out, ", ");
        const char *spelled = "bool ";
        if (strcmp(key, "text") == 0) {
            spelled = "const char *";
        } else if (strcmp(key, "int") == 0) {
            spelled = "int64_t ";
        } else if (strcmp(key, "list-text") == 0) {
            spelled = "kofun_text_list ";
        }
        buffer_format(out, "%sk_b%s", spelled, sl_field(binding, 1));
        *arity += 1;
    }
}

static void sl_emit_function(
    SlDoc *doc,
    int64_t record,
    int64_t first_node,
    int64_t last_node,
    Buffer *prototypes,
    Buffer *bodies,
    Buffer *casts
) {
    const SlRecord *function = &doc->nodes[record];
    const SlRecord *symbol = sl_symbol(doc, sl_int(function, 2));
    if (symbol == NULL) {
        sl_fail(doc, 1,
                "error[E2S35]: selfhost-C11 function has no symbol");
        return;
    }
    const char *name = sl_field(symbol, 3);
    const char *result_key = sl_result_key(doc, symbol);
    bool is_main = strcmp(name, "main") == 0;
    Buffer parameters;
    buffer_init(&parameters);
    int64_t arity = 0;
    sl_parameters(doc, sl_int(function, 3), &parameters, &arity);
    if (doc->error != NULL) {
        free(parameters.data);
        return;
    }
    SlFn fn;
    memset(&fn, 0, sizeof(fn));
    fn.doc = doc;
    fn.first_node = first_node;
    fn.last_node = last_node;
    fn.function_name = name;
    fn.indent = 1;
    if (is_main) {
        fn.fail_return = "1";
    } else if (strcmp(result_key, "int") == 0) {
        fn.fail_return = "INT64_C(0)";
    } else if (strcmp(result_key, "bool") == 0) {
        fn.fail_return = "false";
    } else if (strcmp(result_key, "text") == 0) {
        fn.fail_return = "\"\"";
    } else if (strcmp(result_key, "void") == 0) {
        fn.fail_return = "";
    } else {
        sl_fail_name(doc, 3,
                     "error[E2S10]: unsupported selfhost-C11 type ",
                     result_key);
        free(parameters.data);
        return;
    }
    if (is_main) {
        if (arity != 0) {
            sl_fail(doc, 1,
                    "error[E2S15]: selfhost-C11 `main` takes no parameters");
            free(parameters.data);
            return;
        }
        buffer_append(bodies, "int main(int argc, char **argv) {\n");
        buffer_append(bodies,
                      "    kofun_runtime_argc = argc > 0 ? argc - 1 : 0;\n"
                      "    kofun_runtime_argv = argc > 0 ? argv + 1 : argv;\n");
        buffer_append(bodies, casts->data == NULL ? "" : casts->data);
    } else {
        const char *c_result = strcmp(result_key, "void") == 0 ?
            "void" : sl_c_type(result_key);
        buffer_format(prototypes, "static %s%skofun_fn_%s(%s);\n",
                      c_result,
                      strcmp(result_key, "text") == 0 ? "" : " ",
                      name,
                      arity == 0 ? "void" : parameters.data);
        buffer_format(bodies, "static %s%skofun_fn_%s(%s) {\n",
                      c_result,
                      strcmp(result_key, "text") == 0 ? "" : " ",
                      name,
                      arity == 0 ? "void" : parameters.data);
    }
    bool terminal = false;
    int64_t walk = record + 1;
    while (doc->error == NULL && walk < last_node) {
        walk = sl_emit_statement(&fn, doc, walk, bodies, &terminal);
    }
    free(parameters.data);
    if (doc->error != NULL) return;
    if (!terminal && strcmp(result_key, "void") != 0 && !is_main) {
        sl_fail_name(doc, 1,
                     "error[E2S19]: selfhost-C11 function may complete "
                     "without returning a value: ",
                     name);
        return;
    }
    if (is_main && !terminal) {
        buffer_append(bodies, "    return 0;\n");
    }
    buffer_append(bodies, "}\n\n");
}

static char *sl_lower_document(SlDoc *doc, const char *text) {
    if (!sl_load(doc, text)) return NULL;
    Buffer prototypes;
    buffer_init(&prototypes);
    Buffer bodies;
    buffer_init(&bodies);
    Buffer casts;
    buffer_init(&casts);
    buffer_append(&casts,
                  "    (void)kofun_failed;\n"
                  "    (void)kofun_error;\n"
                  "    (void)kofun_add;\n"
                  "    (void)kofun_sub;\n"
                  "    (void)kofun_mul;\n"
                  "    (void)kofun_neg;\n"
                  "    (void)kofun_floor_div;\n"
                  "    (void)kofun_floor_mod;\n");
    int64_t main_count = 0;
    for (int64_t index = 0; index < doc->node_count; ++index) {
        const SlRecord *node = &doc->nodes[index];
        if (strcmp(sl_field(node, 0), "function") != 0) continue;
        const SlRecord *symbol = sl_symbol(doc, sl_int(node, 2));
        if (symbol == NULL) continue;
        if (strcmp(sl_field(symbol, 3), "main") == 0) {
            ++main_count;
        } else {
            buffer_format(&casts, "    (void)kofun_fn_%s;\n",
                          sl_field(symbol, 3));
        }
    }
    if (main_count != 1) {
        sl_fail(doc, 1,
                "error[E2S16]: selfhost-C11 program needs exactly one "
                "`main`");
    }
    for (int64_t index = 0;
         doc->error == NULL && index < doc->node_count;
         ++index) {
        if (strcmp(sl_field(&doc->nodes[index], 0), "function") != 0) {
            continue;
        }
        int64_t last = index + 1;
        while (last < doc->node_count &&
               strcmp(sl_field(&doc->nodes[last], 0), "function") != 0) {
            ++last;
        }
        sl_emit_function(doc, index, index + 1, last, &prototypes,
                         &bodies, &casts);
    }
    if (doc->error != NULL) {
        free(prototypes.data);
        free(bodies.data);
        free(casts.data);
        return NULL;
    }
    Buffer output;
    buffer_init(&output);
    buffer_append(&output,
                  "/* Generated by kofun-stage2 --lower-selfhost-c11. */\n");
    buffer_format(&output, "/* Source: %s %s */\n\n",
                  doc->source_path, doc->source_digest);
    buffer_append(&output, sl_prelude);
    buffer_append(&output, sl_prelude_text);
    buffer_append(&output, sl_prelude_unicode);
    if (prototypes.data != NULL && prototypes.data[0] != '\0') {
        buffer_append(&output, prototypes.data);
        buffer_append(&output, "\n");
    }
    buffer_append(&output, bodies.data == NULL ? "" : bodies.data);
    free(prototypes.data);
    free(bodies.data);
    free(casts.data);
    return output.data;
}

static void sl_free(SlDoc *doc) {
    for (int64_t index = 0; index < doc->type_count; ++index) {
        free(doc->type_keys[index]);
    }
    free(doc->document);
    free(doc->source_path);
    free(doc->source_digest);
    free(doc->error);
    free(doc);
}

static int lower_selfhost_c11_file(const char *input, const char *output) {
    if (same_file(input, output)) {
        puts("error[E2S35]: selfhost-C11 input and output must be distinct");
        return 2;
    }
    char *text = read_file(input);
    SlDoc *doc = allocate(sizeof(*doc));
    memset(doc, 0, sizeof(*doc));
    char *lowered = sl_lower_document(doc, text);
    if (lowered == NULL) {
        puts(doc->error);
        int exit_code = doc->error_exit;
        sl_free(doc);
        free(text);
        return exit_code;
    }
    write_file(output, lowered);
    free(lowered);
    sl_free(doc);
    free(text);
    return 0;
}

/* The self-host compiler driver: one source-to-C command with no hidden
 * Stage 1/2 fallback. The typed document is produced and lowered in
 * memory; a rejected source prints its stable diagnostic and writes
 * nothing. */
static int selfhost_compile_file(
    const char *input,
    const char *output,
    const char *digest
) {
    if (same_file(input, output)) {
        puts("error[E2S35]: selfhost-compile input and output must be "
             "distinct");
        return 2;
    }
    if (strlen(digest) != 64 || strspn(digest, "0123456789abcdef") != 64) {
        puts("error[E2S35]: selfhost-compile digest must be 64 lowercase "
             "hex");
        return 2;
    }
    char *source = read_file(input);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    free(tokens);
    bool complete = false;
    char *document = emit_selfhost_hir_document(
        source,
        input,
        digest,
        &complete
    );
    free(source);
    if (!complete) {
        free(document);
        return 1;
    }
    SlDoc *doc = allocate(sizeof(*doc));
    memset(doc, 0, sizeof(*doc));
    char *lowered = sl_lower_document(doc, document);
    free(document);
    if (lowered == NULL) {
        puts(doc->error);
        int exit_code = doc->error_exit;
        sl_free(doc);
        return exit_code;
    }
    write_file(output, lowered);
    free(lowered);
    sl_free(doc);
    return 0;
}

static int emit_scope_hir_file(const char *input, const char *output) {
    if (same_file(input, output)) {
        puts(
            "error[E2S35]: scope-HIR input and output must be distinct"
        );
        return 1;
    }
    char *source = read_file(input);
    char *tokens = lex_source(source);
    if (strncmp(tokens, "error[", 6) == 0) {
        puts(tokens);
        free(tokens);
        free(source);
        return 1;
    }
    free(tokens);
    char *tree = parse_pattern_trees(source);
    char *pattern_error = pattern_first_error(tree);
    free(tree);
    if (pattern_error[0] != '\0') {
        puts(pattern_error);
        free(pattern_error);
        free(source);
        return 1;
    }
    free(pattern_error);
    char *hir = build_scope_hir_mode(source, true);
    if (strncmp(hir, "error[", 6) == 0) {
        puts(hir);
        free(hir);
        free(source);
        return 1;
    }
    if (!write_file_transactional(output, hir)) {
        puts("error[E2S35]: cannot commit scope-HIR output");
        free(hir);
        free(source);
        return 1;
    }
    free(hir);
    free(source);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 6 && strcmp(argv[1], "--compile-outcome") == 0) {
        return compile_file(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc == 3 && strcmp(argv[1], "--check-ownership") == 0) {
        return check_ownership_file(argv[2]);
    }
    if (argc == 4 && strcmp(argv[1], "--parse-patterns") == 0) {
        return parse_patterns_file(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "--emit-scope-hir") == 0) {
        return emit_scope_hir_file(argv[2], argv[3]);
    }
    if (argc == 5 && strcmp(argv[1], "--emit-selfhost-hir") == 0) {
        return emit_selfhost_hir_file(argv[2], argv[3], argv[4]);
    }
    if (argc == 4 && strcmp(argv[1], "--lower-selfhost-c11") == 0) {
        return lower_selfhost_c11_file(argv[2], argv[3]);
    }
    if (argc == 5 && strcmp(argv[1], "--selfhost-compile") == 0) {
        return selfhost_compile_file(argv[2], argv[3], argv[4]);
    }
    if (argc != 5) {
        fputs(
            "usage: kofun-stage2 INPUT.kofun OUTPUT.kofun OUTPUT.ir OUTPUT.tokens\n"
            "       kofun-stage2 --compile-outcome INPUT.kofun OUTPUT.c OUTPUT.ir OUTPUT.tokens\n"
            "       kofun-stage2 --check-ownership INPUT.kofun\n"
            "       kofun-stage2 --parse-patterns INPUT.kofun OUTPUT.patterns\n"
            "       kofun-stage2 --emit-scope-hir INPUT.kofun OUTPUT.scope-hir\n"
            "       kofun-stage2 --emit-selfhost-hir INPUT.kofun OUTPUT.hir SOURCE-SHA256\n"
            "       kofun-stage2 --lower-selfhost-c11 INPUT.hir OUTPUT.c\n"
            "       kofun-stage2 --selfhost-compile INPUT.kofun OUTPUT.c SOURCE-SHA256\n",
            stdout
        );
        return 2;
    }
    return compile_file(argv[1], argv[2], argv[3], argv[4]) == 0 ? 0 : 1;
}
