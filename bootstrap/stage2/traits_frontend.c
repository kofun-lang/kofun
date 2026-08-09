/*
 * Bounded trait declaration and implementation frontend (#332).
 *
 * This slice is frontend-only. It parses traits with one type parameter and
 * any number of members, concrete implementations supplying them, and generic
 * functions carrying exactly one explicit bound; it assigns stable
 * TraitId/MethodId/ImplementationId identities and emits typed IR.
 *
 * #923 adds dictionary elaboration to that typed IR: a descriptor per trait, a
 * dictionary value per admissible implementation, a dictionary parameter per
 * declared bound, and an explicit dictionary argument at every bounded call.
 * Elaboration is still frontend-only. It runs after every check has passed, so
 * a refused program never reaches it, and it emits no backend artifact: nothing
 * is monomorphised, no vtable is laid out, and no runtime search is emitted or
 * implied. Executing an elaborated dictionary is a separate follow-up.
 *
 * The orphan rule is the one #403 accepted and `docs/TYPE_SYSTEM.md` records:
 * an implementation is admissible when the trait is local *or* the outer
 * nominal self-type is local. `foreign` marks a declaration as belonging to
 * another package; it is the synthetic stand-in for cross-package loading,
 * which stays out of scope. A `type A = B` alias resolves to B's package, so an
 * alias never confers ownership.
 *
 * Resolution produces exactly zero or one applicable implementation. Overlap is
 * refused where implementations are declared, not where they are used, so no
 * candidate set is ever ordered and neither import nor source order can select
 * between candidates.
 */
#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SOURCE_LIMIT (1024u * 1024u)
#define TOKEN_LIMIT 8192u
#define TEXT_LIMIT 128u
#define TRAIT_LIMIT 64u
#define METHOD_LIMIT 128u
#define NOMINAL_LIMIT 64u
#define IMPLEMENTATION_LIMIT 128u
#define FUNCTION_LIMIT 128u
#define TYPE_PARAMETER_LIMIT 256u
#define PARAMETER_LIMIT 512u
#define BOUND_LIMIT 256u
#define CALL_LIMIT 512u
#define METHOD_CALL_LIMIT 512u
#define TYPE_ARGUMENT_LIMIT 4u
#define IDENTITY_LIMIT 512u
/* Components an identity is assembled from, kept well below IDENTITY_LIMIT so
 * the assembled form cannot be truncated. */
#define COMPONENT_LIMIT 96u
/* An ImplementationId assembles several components, so it gets its own room. */
#define IMPLEMENTATION_IDENTITY_LIMIT 1024u
/* A DictionaryId is an ImplementationId with one component removed and a
 * longer tag, so it gets the same room plus that tag's growth. */
#define DICTIONARY_IDENTITY_LIMIT (IMPLEMENTATION_IDENTITY_LIMIT + 16u)

/* The ABI schema version the ImplementationId carries. */
#define IMPLEMENTATION_ABI "abi1"
/* The ImplementationId tag a DictionaryId is derived from, and the declaration
 * ordinal that derivation drops. */
#define IMPLEMENTATION_TAG "impl:"
#define IMPLEMENTATION_DECLARATION "/decl="

typedef enum {
    TOKEN_IDENTIFIER,
    TOKEN_INTEGER,
    TOKEN_TEXT,
    TOKEN_PUNCTUATION,
    TOKEN_ARROW
} TokenKind;

typedef enum {
    TYPE_INT,
    TYPE_BOOL,
    TYPE_TEXT,
    TYPE_VOID,
    TYPE_NOMINAL,
    TYPE_PARAMETER
} TypeKind;

typedef enum {
    OWNER_TRAIT_METHOD,
    OWNER_IMPLEMENTATION_METHOD,
    OWNER_FUNCTION
} OwnerKind;

typedef struct {
    TokenKind kind;
    char text[TEXT_LIMIT];
    size_t start;
    size_t end;
} Token;

typedef struct {
    TypeKind kind;
    size_t index;  /* nominal index, or type-parameter index */
    size_t start;
    size_t end;
} TypeRef;

typedef struct {
    char name[TEXT_LIMIT];
    bool local;
    bool is_alias;
    TypeRef alias_target;
    size_t start;
    size_t end;
} Nominal;

typedef struct {
    char name[TEXT_LIMIT];
    OwnerKind owner_kind;
    size_t owner_index;
    size_t ordinal;
    size_t start;
    size_t end;
} TypeParameter;

typedef struct {
    char name[TEXT_LIMIT];
    OwnerKind owner_kind;
    size_t owner_index;
    TypeRef type;
    size_t start;
    size_t end;
} Parameter;

typedef struct {
    char name[TEXT_LIMIT];
    size_t owner_trait;
    size_t slot;
    size_t parameter_start;
    size_t parameter_count;
    TypeRef result;
    size_t start;
    size_t end;
} Method;

typedef struct {
    char name[TEXT_LIMIT];
    bool local;
    size_t type_parameter_start;
    size_t type_parameter_count;
    size_t method_start;
    size_t method_count;
    size_t start;
    size_t end;
} Trait;

/* One method written inside an `impl` block. This mirrors `Method` on the
 * trait side: an implementation holds a range into a shared array rather
 * than one inline method, so a trait with several members can be
 * implemented without the two shapes disagreeing about how many there are. */
typedef struct {
    char name[TEXT_LIMIT];
    size_t parameter_start;
    size_t parameter_count;
    TypeRef result;
    size_t start;
    size_t end;
} ImplementationMethod;

typedef struct {
    size_t trait_index;
    TypeRef type_arguments[TYPE_ARGUMENT_LIMIT];
    size_t type_argument_count;
    TypeRef self_type;
    size_t ordinal;
    size_t method_start;
    size_t method_count;
    size_t start;
    size_t end;
} Implementation;

typedef struct {
    size_t owner_function;
    size_t type_parameter;
    size_t trait_index;
    TypeRef type_arguments[TYPE_ARGUMENT_LIMIT];
    size_t type_argument_count;
    size_t start;
    size_t end;
} Bound;

typedef struct {
    char name[TEXT_LIMIT];
    size_t type_parameter_start;
    size_t type_parameter_count;
    size_t parameter_start;
    size_t parameter_count;
    TypeRef result;
    ptrdiff_t bound;
    size_t body_start;
    size_t body_end;
    size_t start;
    size_t end;
} Function;

typedef struct {
    size_t caller;
    size_t callee;
    TypeRef type_arguments[TYPE_ARGUMENT_LIMIT];
    size_t type_argument_count;
    TypeRef argument_types[TYPE_ARGUMENT_LIMIT];
    size_t argument_count;
    TypeRef result;
    ptrdiff_t selected_implementation;
    /* The dictionary the selected implementation produces, and the callee
     * parameter it fills. Both are -1 for an unbounded callee. */
    ptrdiff_t dictionary_argument;
    ptrdiff_t dictionary_parameter;
    size_t start;
    size_t end;
} Call;

typedef struct {
    size_t caller;
    size_t trait_index;
    size_t method_slot;
    size_t via_type_parameter;
    /* The caller's dictionary parameter the method is looked up in. A method
     * call without one is refused before elaboration, so this is never -1 in
     * a program that reaches the IR. */
    ptrdiff_t dictionary_parameter;
    size_t argument_count;
    TypeRef result;
    size_t start;
    size_t end;
} MethodCall;

/*
 * The dictionary shape #923 elaborates.
 *
 * A descriptor is a trait's static dictionary layout: the ABI schema version,
 * the TraitId, and one MethodId per slot in declaration order. Every dictionary
 * for that trait has exactly this shape.
 */
typedef struct {
    size_t trait_index;
    size_t method_start;
    size_t slot_count;
} DictionaryDescriptor;

/* A dictionary value: what one admissible implementation produces. Its
 * DictionaryId is derived from the ImplementationId. */
typedef struct {
    size_t implementation;
    size_t descriptor;
} Dictionary;

/* A dictionary parameter: one per bound a generic function declares, in
 * declaration order, recorded with the bound it discharges. */
typedef struct {
    size_t owner_function;
    size_t bound;
    size_t descriptor;
    size_t ordinal;
} DictionaryParameter;

typedef struct {
    Token tokens[TOKEN_LIMIT];
    size_t token_count;
    Nominal nominals[NOMINAL_LIMIT];
    size_t nominal_count;
    Trait traits[TRAIT_LIMIT];
    size_t trait_count;
    Method methods[METHOD_LIMIT];
    size_t method_count;
    Implementation implementations[IMPLEMENTATION_LIMIT];
    size_t implementation_count;
    ImplementationMethod implementation_methods[METHOD_LIMIT];
    size_t implementation_method_count;
    Function functions[FUNCTION_LIMIT];
    size_t function_count;
    TypeParameter type_parameters[TYPE_PARAMETER_LIMIT];
    size_t type_parameter_count;
    Parameter parameters[PARAMETER_LIMIT];
    size_t parameter_count;
    Bound bounds[BOUND_LIMIT];
    size_t bound_count;
    Call calls[CALL_LIMIT];
    size_t call_count;
    MethodCall method_calls[METHOD_CALL_LIMIT];
    size_t method_call_count;
    /* Elaborated dictionary shape. Each array is filled one entry per already
     * bounded declaration — a trait, an admissible implementation, a declared
     * bound — so the counts cannot exceed limits their sources already hold. */
    DictionaryDescriptor descriptors[TRAIT_LIMIT];
    size_t descriptor_count;
    Dictionary dictionaries[IMPLEMENTATION_LIMIT];
    size_t dictionary_count;
    DictionaryParameter dictionary_parameters[BOUND_LIMIT];
    size_t dictionary_parameter_count;
    char error[1536];
    bool failed;
} Frontend;

static void set_error(
    Frontend *frontend,
    const char *code,
    size_t start,
    size_t end,
    const char *format,
    ...
) {
    char detail[1200];
    va_list arguments;

    if (frontend->failed) return;
    va_start(arguments, format);
    if (vsnprintf(detail, sizeof(detail), format, arguments) < 0) {
        detail[0] = '\0';
    }
    va_end(arguments);
    snprintf(
        frontend->error,
        sizeof(frontend->error),
        "error[%s]: %s at bytes %zu..%zu",
        code,
        detail,
        start,
        end
    );
    frontend->failed = true;
}

static size_t token_start(const Frontend *frontend, size_t index) {
    if (index < frontend->token_count) return frontend->tokens[index].start;
    if (frontend->token_count == 0) return 0;
    return frontend->tokens[frontend->token_count - 1].end;
}

static size_t token_end(const Frontend *frontend, size_t index) {
    if (index < frontend->token_count) return frontend->tokens[index].end;
    return token_start(frontend, index);
}

static bool copy_text(
    Frontend *frontend,
    char *output,
    const char *source,
    size_t start,
    size_t end
) {
    size_t length = end - start;
    if (length == 0 || length >= TEXT_LIMIT) {
        set_error(
            frontend,
            "E2S133",
            start,
            end,
            "identifier or literal exceeds the trait frontend text limit"
        );
        return false;
    }
    memcpy(output, source + start, length);
    output[length] = '\0';
    return true;
}

static bool add_token(
    Frontend *frontend,
    TokenKind kind,
    const char *source,
    size_t start,
    size_t end
) {
    Token *token;
    if (frontend->token_count >= TOKEN_LIMIT) {
        set_error(frontend, "E2S133", start, end, "token count exceeds %u",
            TOKEN_LIMIT);
        return false;
    }
    token = &frontend->tokens[frontend->token_count];
    token->kind = kind;
    token->start = start;
    token->end = end;
    if (!copy_text(frontend, token->text, source, start, end)) return false;
    frontend->token_count += 1;
    return true;
}

static bool tokenize(Frontend *frontend, const char *source, size_t length) {
    size_t cursor = 0;
    while (cursor < length) {
        size_t start;
        unsigned char byte = (unsigned char)source[cursor];
        if (isspace(byte)) {
            cursor += 1;
            continue;
        }
        if (source[cursor] == '#') {
            while (cursor < length && source[cursor] != '\n') cursor += 1;
            continue;
        }
        start = cursor;
        if (isalpha(byte) || source[cursor] == '_') {
            cursor += 1;
            while (cursor < length) {
                byte = (unsigned char)source[cursor];
                if (!isalnum(byte) && source[cursor] != '_') break;
                cursor += 1;
            }
            if (!add_token(frontend, TOKEN_IDENTIFIER, source, start, cursor)) {
                return false;
            }
            continue;
        }
        if (isdigit(byte)) {
            cursor += 1;
            while (cursor < length &&
                isdigit((unsigned char)source[cursor])) cursor += 1;
            if (!add_token(frontend, TOKEN_INTEGER, source, start, cursor)) {
                return false;
            }
            continue;
        }
        if (source[cursor] == '"') {
            bool escaped = false;
            cursor += 1;
            while (cursor < length) {
                char current = source[cursor];
                cursor += 1;
                if (escaped) {
                    escaped = false;
                } else if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    break;
                } else if (current == '\n') {
                    set_error(frontend, "E2S133", start, cursor,
                        "unterminated text literal");
                    return false;
                }
            }
            if (cursor > length || source[cursor - 1] != '"') {
                set_error(frontend, "E2S133", start, length,
                    "unterminated text literal");
                return false;
            }
            if (!add_token(frontend, TOKEN_TEXT, source, start, cursor)) {
                return false;
            }
            continue;
        }
        if (source[cursor] == '-' && cursor + 1 < length &&
            source[cursor + 1] == '>') {
            cursor += 2;
            if (!add_token(frontend, TOKEN_ARROW, source, start, cursor)) {
                return false;
            }
            continue;
        }
        if (strchr("[](),:{}=.<+", source[cursor]) != NULL) {
            cursor += 1;
            if (!add_token(
                    frontend, TOKEN_PUNCTUATION, source, start, cursor)) {
                return false;
            }
            continue;
        }
        set_error(frontend, "E2S133", cursor, cursor + 1,
            "unsupported byte 0x%02x in bounded trait syntax", byte);
        return false;
    }
    return true;
}

static bool token_is(const Frontend *frontend, size_t index, const char *text) {
    return index < frontend->token_count &&
        strcmp(frontend->tokens[index].text, text) == 0;
}

static bool token_has_kind(
    const Frontend *frontend,
    size_t index,
    TokenKind kind
) {
    return index < frontend->token_count &&
        frontend->tokens[index].kind == kind;
}

static bool expect_token(
    Frontend *frontend,
    size_t *cursor,
    const char *text
) {
    if (!token_is(frontend, *cursor, text)) {
        set_error(
            frontend,
            "E2S127",
            token_start(frontend, *cursor),
            token_end(frontend, *cursor),
            "expected '%s'",
            text
        );
        return false;
    }
    *cursor += 1;
    return true;
}

static bool expect_identifier(
    Frontend *frontend,
    size_t *cursor,
    char *output
) {
    if (!token_has_kind(frontend, *cursor, TOKEN_IDENTIFIER)) {
        set_error(
            frontend,
            "E2S127",
            token_start(frontend, *cursor),
            token_end(frontend, *cursor),
            "expected an identifier"
        );
        return false;
    }
    memcpy(output, frontend->tokens[*cursor].text, TEXT_LIMIT);
    *cursor += 1;
    return true;
}

static ptrdiff_t find_nominal(const Frontend *frontend, const char *name) {
    for (size_t index = 0; index < frontend->nominal_count; ++index) {
        if (strcmp(frontend->nominals[index].name, name) == 0) {
            return (ptrdiff_t)index;
        }
    }
    return -1;
}

static ptrdiff_t find_trait(const Frontend *frontend, const char *name) {
    for (size_t index = 0; index < frontend->trait_count; ++index) {
        if (strcmp(frontend->traits[index].name, name) == 0) {
            return (ptrdiff_t)index;
        }
    }
    return -1;
}

static ptrdiff_t find_function(const Frontend *frontend, const char *name) {
    for (size_t index = 0; index < frontend->function_count; ++index) {
        if (strcmp(frontend->functions[index].name, name) == 0) {
            return (ptrdiff_t)index;
        }
    }
    return -1;
}

static ptrdiff_t find_type_parameter(
    const Frontend *frontend,
    OwnerKind owner_kind,
    size_t owner_index,
    const char *name
) {
    for (size_t index = 0; index < frontend->type_parameter_count; ++index) {
        const TypeParameter *candidate = &frontend->type_parameters[index];
        if (candidate->owner_kind != owner_kind) continue;
        if (candidate->owner_index != owner_index) continue;
        if (strcmp(candidate->name, name) == 0) return (ptrdiff_t)index;
    }
    return -1;
}

/*
 * A nominal type's package is the package of the declaration it ultimately
 * names. An alias is transparent for typing and for ownership alike, so
 * `type Local = Foreign` yields a foreign type and cannot make an
 * implementation admissible.
 */
static bool nominal_is_local(const Frontend *frontend, size_t index) {
    size_t guard = 0;
    while (guard < NOMINAL_LIMIT) {
        const Nominal *nominal = &frontend->nominals[index];
        if (!nominal->is_alias) return nominal->local;
        if (nominal->alias_target.kind != TYPE_NOMINAL) return false;
        index = nominal->alias_target.index;
        guard += 1;
    }
    return false;
}

static TypeRef resolve_alias(const Frontend *frontend, TypeRef type) {
    size_t guard = 0;
    while (type.kind == TYPE_NOMINAL && guard < NOMINAL_LIMIT) {
        const Nominal *nominal = &frontend->nominals[type.index];
        if (!nominal->is_alias) return type;
        {
            TypeRef target = nominal->alias_target;
            target.start = type.start;
            target.end = type.end;
            type = target;
        }
        guard += 1;
    }
    return type;
}

static bool parse_type_ref(
    Frontend *frontend,
    size_t *cursor,
    OwnerKind owner_kind,
    size_t owner_index,
    TypeRef *output
) {
    char name[TEXT_LIMIT];
    size_t start = token_start(frontend, *cursor);
    size_t end;
    ptrdiff_t found;

    if (!expect_identifier(frontend, cursor, name)) return false;
    end = token_end(frontend, *cursor - 1);
    output->start = start;
    output->end = end;
    output->index = 0;

    if (strcmp(name, "Int") == 0) {
        output->kind = TYPE_INT;
        return true;
    }
    if (strcmp(name, "Bool") == 0) {
        output->kind = TYPE_BOOL;
        return true;
    }
    if (strcmp(name, "Text") == 0) {
        output->kind = TYPE_TEXT;
        return true;
    }
    found = find_type_parameter(frontend, owner_kind, owner_index, name);
    if (found >= 0) {
        output->kind = TYPE_PARAMETER;
        output->index = (size_t)found;
        return true;
    }
    found = find_nominal(frontend, name);
    if (found >= 0) {
        output->kind = TYPE_NOMINAL;
        output->index = (size_t)found;
        return true;
    }
    set_error(frontend, "E2S127", start, end, "unknown type '%s'", name);
    return false;
}

static bool add_type_parameter(
    Frontend *frontend,
    const char *name,
    OwnerKind owner_kind,
    size_t owner_index,
    size_t ordinal,
    size_t start,
    size_t end
) {
    TypeParameter *parameter;
    if (find_type_parameter(frontend, owner_kind, owner_index, name) >= 0) {
        set_error(frontend, "E2S127", start, end,
            "type parameter '%s' is declared twice", name);
        return false;
    }
    if (frontend->type_parameter_count >= TYPE_PARAMETER_LIMIT) {
        set_error(frontend, "E2S133", start, end,
            "type parameter count exceeds %u", TYPE_PARAMETER_LIMIT);
        return false;
    }
    parameter = &frontend->type_parameters[frontend->type_parameter_count];
    memcpy(parameter->name, name, TEXT_LIMIT);
    parameter->owner_kind = owner_kind;
    parameter->owner_index = owner_index;
    parameter->ordinal = ordinal;
    parameter->start = start;
    parameter->end = end;
    frontend->type_parameter_count += 1;
    return true;
}

static bool add_parameter(
    Frontend *frontend,
    const char *name,
    OwnerKind owner_kind,
    size_t owner_index,
    TypeRef type,
    size_t start,
    size_t end
) {
    Parameter *parameter;
    if (frontend->parameter_count >= PARAMETER_LIMIT) {
        set_error(frontend, "E2S133", start, end,
            "parameter count exceeds %u", PARAMETER_LIMIT);
        return false;
    }
    for (size_t index = 0; index < frontend->parameter_count; ++index) {
        const Parameter *existing = &frontend->parameters[index];
        if (existing->owner_kind != owner_kind) continue;
        if (existing->owner_index != owner_index) continue;
        if (strcmp(existing->name, name) != 0) continue;
        set_error(frontend, "E2S127", start, end,
            "parameter '%s' is declared twice", name);
        return false;
    }
    parameter = &frontend->parameters[frontend->parameter_count];
    memcpy(parameter->name, name, TEXT_LIMIT);
    parameter->owner_kind = owner_kind;
    parameter->owner_index = owner_index;
    parameter->type = type;
    parameter->start = start;
    parameter->end = end;
    frontend->parameter_count += 1;
    return true;
}

/* Parses `(name: Type, ...)` and returns the parameter range. */
/*
 * `owner_index` resolves type names -- a trait method's `T` belongs to the
 * trait, so every method of one trait shares that index. `scope_index`
 * scopes the value parameters, and is per method: sharing the type index
 * for both made two methods that each take `left` collide as a duplicate
 * parameter, which is why a trait could only ever hold one method.
 */
static bool parse_parameter_list(
    Frontend *frontend,
    size_t *cursor,
    OwnerKind owner_kind,
    size_t owner_index,
    size_t scope_index,
    size_t *parameter_start,
    size_t *parameter_count
) {
    *parameter_start = frontend->parameter_count;
    *parameter_count = 0;
    if (!expect_token(frontend, cursor, "(")) return false;
    if (token_is(frontend, *cursor, ")")) {
        *cursor += 1;
        return true;
    }
    for (;;) {
        char name[TEXT_LIMIT];
        TypeRef type;
        size_t start = token_start(frontend, *cursor);
        size_t end;
        if (!expect_identifier(frontend, cursor, name)) return false;
        if (!expect_token(frontend, cursor, ":")) return false;
        if (!parse_type_ref(frontend, cursor, owner_kind, owner_index, &type)) {
            return false;
        }
        end = token_end(frontend, *cursor - 1);
        if (!add_parameter(
                frontend, name, owner_kind, scope_index, type, start, end)) {
            return false;
        }
        *parameter_count += 1;
        if (token_is(frontend, *cursor, ",")) {
            *cursor += 1;
            continue;
        }
        break;
    }
    return expect_token(frontend, cursor, ")");
}

static bool reject_advanced_form(
    Frontend *frontend,
    size_t cursor,
    const char *what
) {
    set_error(
        frontend,
        "E2S132",
        token_start(frontend, cursor),
        token_end(frontend, cursor),
        "%s is unsupported in this trait frontend slice; "
        "this slice is bounded to traits with one type parameter, concrete "
        "implementations, and one explicit non-recursive bound",
        what
    );
    return false;
}

static bool parse_trait(Frontend *frontend, size_t *cursor, bool local) {
    Trait *trait;
    char name[TEXT_LIMIT];
    size_t trait_index = frontend->trait_count;
    size_t start = token_start(frontend, *cursor);
    size_t ordinal = 0;

    if (frontend->trait_count >= TRAIT_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "trait count exceeds %u", TRAIT_LIMIT);
        return false;
    }
    if (!expect_token(frontend, cursor, "trait")) return false;
    if (!expect_identifier(frontend, cursor, name)) return false;
    if (find_trait(frontend, name) >= 0) {
        set_error(frontend, "E2S127", start, token_end(frontend, *cursor - 1),
            "trait '%s' is declared twice", name);
        return false;
    }
    trait = &frontend->traits[trait_index];
    memset(trait, 0, sizeof(*trait));
    memcpy(trait->name, name, TEXT_LIMIT);
    trait->local = local;
    trait->start = start;
    trait->type_parameter_start = frontend->type_parameter_count;
    trait->method_start = frontend->method_count;
    /* The trait is visible to its own signatures, so publish it before the
     * body is parsed. */
    frontend->trait_count += 1;

    if (!expect_token(frontend, cursor, "[")) return false;
    for (;;) {
        char parameter_name[TEXT_LIMIT];
        size_t parameter_start = token_start(frontend, *cursor);
        if (!expect_identifier(frontend, cursor, parameter_name)) return false;
        if (!add_type_parameter(
                frontend,
                parameter_name,
                OWNER_TRAIT_METHOD,
                trait_index,
                ordinal,
                parameter_start,
                token_end(frontend, *cursor - 1))) {
            return false;
        }
        trait->type_parameter_count += 1;
        ordinal += 1;
        if (token_is(frontend, *cursor, ",")) {
            *cursor += 1;
            continue;
        }
        break;
    }
    if (!expect_token(frontend, cursor, "]")) return false;
    if (trait->type_parameter_count != 1) {
        set_error(frontend, "E2S132", start,
            token_end(frontend, *cursor - 1),
            "a trait with %zu type parameters is unsupported in this slice; "
            "exactly one is accepted",
            trait->type_parameter_count);
        return false;
    }
    if (!expect_token(frontend, cursor, "{")) return false;

    while (!token_is(frontend, *cursor, "}")) {
        Method *method;
        char method_name[TEXT_LIMIT];
        size_t method_start = token_start(frontend, *cursor);
        if (*cursor >= frontend->token_count) {
            set_error(frontend, "E2S127", method_start, method_start,
                "trait '%s' is not closed", trait->name);
            return false;
        }
        if (frontend->method_count >= METHOD_LIMIT) {
            set_error(frontend, "E2S133", method_start, method_start,
                "method count exceeds %u", METHOD_LIMIT);
            return false;
        }
        if (!expect_token(frontend, cursor, "fn")) return false;
        if (!expect_identifier(frontend, cursor, method_name)) return false;
        method = &frontend->methods[frontend->method_count];
        memset(method, 0, sizeof(*method));
        memcpy(method->name, method_name, TEXT_LIMIT);
        method->owner_trait = trait_index;
        method->slot = trait->method_count;
        method->start = method_start;
        /* Value parameters stay keyed by the trait, not by the member. Two
         * members of one trait therefore cannot share a parameter spelling
         * yet, and a duplicate member still surfaces as that parameter
         * collision. Re-keying it is the member-scope seam #942 owns, and
         * doing it here would decide the shape of that diagnostic. */
        if (!parse_parameter_list(
                frontend,
                cursor,
                OWNER_TRAIT_METHOD,
                trait_index,
                trait_index,
                &method->parameter_start,
                &method->parameter_count)) {
            return false;
        }
        if (!expect_token(frontend, cursor, "->")) return false;
        if (!parse_type_ref(
                frontend,
                cursor,
                OWNER_TRAIT_METHOD,
                trait_index,
                &method->result)) {
            return false;
        }
        method->end = token_end(frontend, *cursor - 1);
        if (token_is(frontend, *cursor, "{")) {
            return reject_advanced_form(frontend, *cursor, "a default method");
        }
        frontend->method_count += 1;
        trait->method_count += 1;
    }
    if (!expect_token(frontend, cursor, "}")) return false;
    trait->end = token_end(frontend, *cursor - 1);
    if (trait->method_count < 1) {
        set_error(frontend, "E2S132", trait->start, trait->end,
            "a trait declares no method; at least one is required");
        return false;
    }
    return true;
}

static bool parse_nominal(Frontend *frontend, size_t *cursor, bool local) {
    Nominal *nominal;
    char name[TEXT_LIMIT];
    size_t start = token_start(frontend, *cursor);

    if (frontend->nominal_count >= NOMINAL_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "type count exceeds %u", NOMINAL_LIMIT);
        return false;
    }
    if (!expect_token(frontend, cursor, "type")) return false;
    if (!expect_identifier(frontend, cursor, name)) return false;
    if (find_nominal(frontend, name) >= 0) {
        set_error(frontend, "E2S127", start, token_end(frontend, *cursor - 1),
            "type '%s' is declared twice", name);
        return false;
    }
    nominal = &frontend->nominals[frontend->nominal_count];
    memset(nominal, 0, sizeof(*nominal));
    memcpy(nominal->name, name, TEXT_LIMIT);
    nominal->local = local;
    nominal->start = start;
    nominal->end = token_end(frontend, *cursor - 1);
    frontend->nominal_count += 1;

    if (token_is(frontend, *cursor, "=")) {
        TypeRef target;
        *cursor += 1;
        if (!parse_type_ref(
                frontend, cursor, OWNER_FUNCTION, FUNCTION_LIMIT, &target)) {
            return false;
        }
        nominal->is_alias = true;
        nominal->alias_target = target;
        nominal->end = token_end(frontend, *cursor - 1);
    }
    return true;
}

static bool type_equal(
    const Frontend *frontend,
    TypeRef left,
    TypeRef right
) {
    TypeRef a = resolve_alias(frontend, left);
    TypeRef b = resolve_alias(frontend, right);
    if (a.kind != b.kind) return false;
    if (a.kind == TYPE_NOMINAL || a.kind == TYPE_PARAMETER) {
        return a.index == b.index;
    }
    return true;
}

static void type_id(
    const Frontend *frontend,
    TypeRef type,
    char *output,
    size_t size
) {
    TypeRef resolved = resolve_alias(frontend, type);
    switch (resolved.kind) {
        case TYPE_INT: snprintf(output, size, "builtin:Int"); return;
        case TYPE_BOOL: snprintf(output, size, "builtin:Bool"); return;
        case TYPE_TEXT: snprintf(output, size, "builtin:Text"); return;
        case TYPE_VOID: snprintf(output, size, "builtin:Void"); return;
        case TYPE_NOMINAL: {
            const Nominal *nominal = &frontend->nominals[resolved.index];
            snprintf(
                output,
                size,
                "nominal:%s:%s",
                nominal_is_local(frontend, resolved.index)
                    ? "local" : "foreign",
                nominal->name
            );
            return;
        }
        case TYPE_PARAMETER: {
            const TypeParameter *parameter =
                &frontend->type_parameters[resolved.index];
            if (parameter->owner_kind == OWNER_FUNCTION) {
                snprintf(
                    output,
                    size,
                    "type-parameter:function:%s:%zu",
                    frontend->functions[parameter->owner_index].name,
                    parameter->ordinal
                );
            } else {
                const Trait *trait = &frontend->traits[parameter->owner_index];
                snprintf(
                    output,
                    size,
                    "type-parameter:trait:%s:%s:%zu",
                    trait->local ? "local" : "foreign",
                    trait->name,
                    parameter->ordinal
                );
            }
            return;
        }
    }
    snprintf(output, size, "builtin:Void");
}

static void trait_id(
    const Frontend *frontend,
    size_t index,
    char *output,
    size_t size
) {
    const Trait *trait = &frontend->traits[index];
    snprintf(
        output,
        size,
        "trait:%s:%s",
        trait->local ? "local" : "foreign",
        trait->name
    );
}

static void method_id(
    const Frontend *frontend,
    size_t trait_index,
    size_t slot,
    char *output,
    size_t size
) {
    char owner[COMPONENT_LIMIT];
    trait_id(frontend, trait_index, owner, sizeof(owner));
    snprintf(output, size, "method:%s:%zu", owner, slot);
}

/*
 * The ImplementationId carries every component the identity contract names:
 * the ABI schema version, the owning package, the TraitId, the normalized
 * concrete type arguments, the outer nominal self-type identity, and the
 * implementation declaration itself.
 */
static void implementation_id(
    const Frontend *frontend,
    size_t index,
    char *output,
    size_t size
) {
    const Implementation *implementation = &frontend->implementations[index];
    char owner[COMPONENT_LIMIT];
    char arguments[COMPONENT_LIMIT];
    char self[COMPONENT_LIMIT];
    size_t written = 0;

    trait_id(frontend, implementation->trait_index, owner, sizeof(owner));
    arguments[0] = '\0';
    for (size_t slot = 0; slot < implementation->type_argument_count; ++slot) {
        char argument[IDENTITY_LIMIT];
        int printed;
        type_id(
            frontend,
            implementation->type_arguments[slot],
            argument,
            sizeof(argument)
        );
        printed = snprintf(
            arguments + written,
            sizeof(arguments) - written,
            "%s%s",
            slot == 0 ? "" : ",",
            argument
        );
        if (printed < 0) break;
        written += (size_t)printed;
        if (written >= sizeof(arguments)) break;
    }
    type_id(frontend, implementation->self_type, self, sizeof(self));
    /* An implementation is always declared by the package being compiled, so
     * the package component is the local package by construction; the trait
     * and the self-type carry their own provenance. */
    snprintf(
        output,
        size,
        "impl:%s/package:local/%s/args=%s/self=%s/decl=%zu",
        IMPLEMENTATION_ABI,
        owner,
        arguments,
        self,
        implementation->ordinal
    );
}

/* A dictionary descriptor is keyed by the ABI schema version and the TraitId:
 * every dictionary for one trait shares one layout. */
static void dictionary_descriptor_id(
    const Frontend *frontend,
    size_t trait_index,
    char *output,
    size_t size
) {
    char owner[COMPONENT_LIMIT];
    trait_id(frontend, trait_index, owner, sizeof(owner));
    snprintf(
        output,
        size,
        "dictionary-descriptor:%s/%s",
        IMPLEMENTATION_ABI,
        owner
    );
}

/*
 * The DictionaryId is derived from the ImplementationId by two mechanical
 * edits: the `impl:` tag becomes `dictionary:`, and the trailing `/decl=N`
 * declaration ordinal is dropped.
 *
 * Dropping the ordinal is what makes the identity independent of declaration
 * order, which is the property the dictionary needs: overlap is already refused
 * where implementations are declared, so the surviving components — the ABI
 * schema version, the package, the TraitId, the normalized type arguments, and
 * the self-type — are exactly the coherence key and are unique per admissible
 * implementation. Reordering the declarations moves the ImplementationId's
 * ordinal and leaves every DictionaryId untouched.
 */
static void dictionary_id(
    const Frontend *frontend,
    size_t implementation_index,
    char *output,
    size_t size
) {
    char implementation[IMPLEMENTATION_IDENTITY_LIMIT];
    char *ordinal;

    implementation_id(
        frontend, implementation_index, implementation, sizeof(implementation));
    ordinal = strstr(implementation, IMPLEMENTATION_DECLARATION);
    if (ordinal != NULL) *ordinal = '\0';
    snprintf(
        output,
        size,
        "dictionary:%s",
        implementation + (sizeof(IMPLEMENTATION_TAG) - 1u)
    );
}

/* A dictionary parameter is keyed by its owning function and its declaration
 * order within that function, exactly like a type parameter. */
static void dictionary_parameter_id(
    const Frontend *frontend,
    size_t parameter_index,
    char *output,
    size_t size
) {
    const DictionaryParameter *parameter =
        &frontend->dictionary_parameters[parameter_index];
    snprintf(
        output,
        size,
        "dictionary-parameter:function:%s:%zu",
        frontend->functions[parameter->owner_function].name,
        parameter->ordinal
    );
}

/* An implementation is admissible when the trait is local, or when the outer
 * nominal self-type is local. #403 accepted exactly this rule. */
static bool implementation_is_admissible(
    const Frontend *frontend,
    const Implementation *implementation
) {
    TypeRef self = resolve_alias(frontend, implementation->self_type);
    if (frontend->traits[implementation->trait_index].local) return true;
    if (self.kind != TYPE_NOMINAL) return false;
    return nominal_is_local(frontend, self.index);
}

static bool parse_implementation(Frontend *frontend, size_t *cursor) {
    Implementation *implementation;
    char trait_name[TEXT_LIMIT];
    char method_name[TEXT_LIMIT];
    size_t index = frontend->implementation_count;
    size_t start = token_start(frontend, *cursor);
    ptrdiff_t found;

    if (frontend->implementation_count >= IMPLEMENTATION_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "implementation count exceeds %u", IMPLEMENTATION_LIMIT);
        return false;
    }
    if (!expect_token(frontend, cursor, "impl")) return false;
    if (token_is(frontend, *cursor, "[")) {
        return reject_advanced_form(
            frontend, *cursor, "a generic or blanket implementation");
    }
    if (!expect_identifier(frontend, cursor, trait_name)) return false;
    found = find_trait(frontend, trait_name);
    if (found < 0) {
        set_error(frontend, "E2S127", start, token_end(frontend, *cursor - 1),
            "unknown trait '%s'", trait_name);
        return false;
    }
    implementation = &frontend->implementations[index];
    memset(implementation, 0, sizeof(*implementation));
    implementation->trait_index = (size_t)found;
    implementation->ordinal = index;
    implementation->start = start;

    if (!expect_token(frontend, cursor, "[")) return false;
    for (;;) {
        TypeRef argument;
        if (implementation->type_argument_count >= TYPE_ARGUMENT_LIMIT) {
            set_error(frontend, "E2S133",
                token_start(frontend, *cursor),
                token_end(frontend, *cursor),
                "type argument count exceeds %u", TYPE_ARGUMENT_LIMIT);
            return false;
        }
        if (!parse_type_ref(
                frontend, cursor, OWNER_FUNCTION, FUNCTION_LIMIT, &argument)) {
            return false;
        }
        if (argument.kind == TYPE_PARAMETER) {
            return reject_advanced_form(
                frontend, *cursor - 1, "a generic implementation argument");
        }
        implementation->type_arguments[implementation->type_argument_count] =
            argument;
        implementation->type_argument_count += 1;
        if (token_is(frontend, *cursor, ",")) {
            *cursor += 1;
            continue;
        }
        break;
    }
    if (!expect_token(frontend, cursor, "]")) return false;
    {
        const Trait *trait = &frontend->traits[implementation->trait_index];
        if (implementation->type_argument_count != trait->type_parameter_count)
        {
            set_error(frontend, "E2S127", start,
                token_end(frontend, *cursor - 1),
                "trait '%s' takes %zu type argument(s) but %zu were written",
                trait->name,
                trait->type_parameter_count,
                implementation->type_argument_count);
            return false;
        }
    }
    if (!expect_token(frontend, cursor, "for")) return false;
    if (!parse_type_ref(
            frontend,
            cursor,
            OWNER_FUNCTION,
            FUNCTION_LIMIT,
            &implementation->self_type)) {
        return false;
    }
    if (!expect_token(frontend, cursor, "{")) return false;
    implementation->method_start = frontend->implementation_method_count;
    implementation->method_count = 0;
    while (!token_is(frontend, *cursor, "}")) {
        ImplementationMethod *method;
        size_t method_index = frontend->implementation_method_count;
        size_t method_head;

        if (frontend->implementation_method_count >= METHOD_LIMIT) {
            set_error(frontend, "E2S133", start, start,
                "method count exceeds %u", METHOD_LIMIT);
            return false;
        }
        if (!expect_token(frontend, cursor, "fn")) return false;
        if (!expect_identifier(frontend, cursor, method_name)) return false;
        method_head = token_start(frontend, *cursor - 1);
        for (size_t seen = 0; seen < implementation->method_count; ++seen) {
            const ImplementationMethod *existing =
                &frontend->implementation_methods[
                    implementation->method_start + seen];
            if (strcmp(existing->name, method_name) != 0) continue;
            set_error(frontend, "E2S127", method_head,
                token_end(frontend, *cursor - 1),
                "method '%s' is implemented twice", method_name);
            return false;
        }
        method = &frontend->implementation_methods[method_index];
        memset(method, 0, sizeof(*method));
        memcpy(method->name, method_name, TEXT_LIMIT);
        method->start = method_head;
        if (!parse_parameter_list(
                frontend,
                cursor,
                OWNER_IMPLEMENTATION_METHOD,
                index,
                method_index,
                &method->parameter_start,
                &method->parameter_count)) {
            return false;
        }
        if (!expect_token(frontend, cursor, "->")) return false;
        if (!parse_type_ref(
                frontend,
                cursor,
                OWNER_IMPLEMENTATION_METHOD,
                index,
                &method->result)) {
            return false;
        }
        method->end = token_end(frontend, *cursor - 1);
        /* The body is not typed by this slice; it is scanned to its matching
         * brace so the declaration boundary stays exact. */
        if (!expect_token(frontend, cursor, "{")) return false;
        {
            size_t depth = 1;
            while (depth > 0) {
                if (*cursor >= frontend->token_count) {
                    set_error(frontend, "E2S127", start, start,
                        "implementation body is not closed");
                    return false;
                }
                if (token_is(frontend, *cursor, "{")) depth += 1;
                if (token_is(frontend, *cursor, "}")) depth -= 1;
                *cursor += 1;
            }
        }
        frontend->implementation_method_count += 1;
        implementation->method_count += 1;
    }
    if (!expect_token(frontend, cursor, "}")) return false;
    implementation->end = token_end(frontend, *cursor - 1);
    frontend->implementation_count += 1;
    return true;
}

static bool parse_function_header(Frontend *frontend, size_t *cursor) {
    Function *function;
    char name[TEXT_LIMIT];
    size_t index = frontend->function_count;
    size_t start = token_start(frontend, *cursor);
    size_t ordinal = 0;

    if (frontend->function_count >= FUNCTION_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "function count exceeds %u", FUNCTION_LIMIT);
        return false;
    }
    if (!expect_token(frontend, cursor, "fn")) return false;
    if (!expect_identifier(frontend, cursor, name)) return false;
    if (find_function(frontend, name) >= 0) {
        set_error(frontend, "E2S127", start, token_end(frontend, *cursor - 1),
            "function '%s' is declared twice", name);
        return false;
    }
    function = &frontend->functions[index];
    memset(function, 0, sizeof(*function));
    memcpy(function->name, name, TEXT_LIMIT);
    function->bound = -1;
    function->start = start;
    function->type_parameter_start = frontend->type_parameter_count;
    frontend->function_count += 1;

    if (token_is(frontend, *cursor, "[")) {
        *cursor += 1;
        for (;;) {
            char parameter_name[TEXT_LIMIT];
            size_t parameter_start = token_start(frontend, *cursor);
            size_t parameter_index = frontend->type_parameter_count;
            if (!expect_identifier(frontend, cursor, parameter_name)) {
                return false;
            }
            if (!add_type_parameter(
                    frontend,
                    parameter_name,
                    OWNER_FUNCTION,
                    index,
                    ordinal,
                    parameter_start,
                    token_end(frontend, *cursor - 1))) {
                return false;
            }
            function->type_parameter_count += 1;
            ordinal += 1;
            if (token_is(frontend, *cursor, ":")) {
                Bound *bound;
                char bound_trait[TEXT_LIMIT];
                ptrdiff_t found;
                size_t bound_start = token_start(frontend, *cursor);
                *cursor += 1;
                if (function->bound >= 0) {
                    return reject_advanced_form(
                        frontend, *cursor - 1, "a second bound");
                }
                if (frontend->bound_count >= BOUND_LIMIT) {
                    set_error(frontend, "E2S133", bound_start, bound_start,
                        "bound count exceeds %u", BOUND_LIMIT);
                    return false;
                }
                if (!expect_identifier(frontend, cursor, bound_trait)) {
                    return false;
                }
                found = find_trait(frontend, bound_trait);
                if (found < 0) {
                    set_error(frontend, "E2S127", bound_start,
                        token_end(frontend, *cursor - 1),
                        "unknown trait '%s' in bound", bound_trait);
                    return false;
                }
                bound = &frontend->bounds[frontend->bound_count];
                memset(bound, 0, sizeof(*bound));
                bound->owner_function = index;
                bound->type_parameter = parameter_index;
                bound->trait_index = (size_t)found;
                bound->start = bound_start;
                if (!expect_token(frontend, cursor, "[")) return false;
                for (;;) {
                    TypeRef argument;
                    if (bound->type_argument_count >= TYPE_ARGUMENT_LIMIT) {
                        set_error(frontend, "E2S133",
                            token_start(frontend, *cursor),
                            token_end(frontend, *cursor),
                            "type argument count exceeds %u",
                            TYPE_ARGUMENT_LIMIT);
                        return false;
                    }
                    if (!parse_type_ref(
                            frontend, cursor, OWNER_FUNCTION, index,
                            &argument)) {
                        return false;
                    }
                    bound->type_arguments[bound->type_argument_count] =
                        argument;
                    bound->type_argument_count += 1;
                    if (token_is(frontend, *cursor, ",")) {
                        *cursor += 1;
                        continue;
                    }
                    break;
                }
                if (!expect_token(frontend, cursor, "]")) return false;
                bound->end = token_end(frontend, *cursor - 1);
                {
                    const Trait *trait = &frontend->traits[bound->trait_index];
                    if (bound->type_argument_count !=
                        trait->type_parameter_count) {
                        set_error(frontend, "E2S127", bound->start, bound->end,
                            "trait '%s' takes %zu type argument(s) but %zu "
                            "were written",
                            trait->name,
                            trait->type_parameter_count,
                            bound->type_argument_count);
                        return false;
                    }
                }
                /* A bound whose argument is not the bounded parameter itself
                 * would make resolution recursive; this slice refuses it. */
                if (bound->type_argument_count != 1 ||
                    bound->type_arguments[0].kind != TYPE_PARAMETER ||
                    bound->type_arguments[0].index != parameter_index) {
                    set_error(frontend, "E2S132", bound->start, bound->end,
                        "a bound whose type argument is not the bounded "
                        "parameter is unsupported in this slice");
                    return false;
                }
                function->bound = (ptrdiff_t)frontend->bound_count;
                frontend->bound_count += 1;
            }
            if (token_is(frontend, *cursor, ",")) {
                *cursor += 1;
                continue;
            }
            break;
        }
        if (!expect_token(frontend, cursor, "]")) return false;
        if (function->type_parameter_count != 1) {
            set_error(frontend, "E2S132", start,
                token_end(frontend, *cursor - 1),
                "a generic function with %zu type parameters is unsupported "
                "in this slice; exactly one is accepted",
                function->type_parameter_count);
            return false;
        }
    }

    if (!parse_parameter_list(
            frontend,
            cursor,
            OWNER_FUNCTION,
            index,
            index,
            &function->parameter_start,
            &function->parameter_count)) {
        return false;
    }
    if (token_is(frontend, *cursor, "->")) {
        *cursor += 1;
        if (!parse_type_ref(
                frontend, cursor, OWNER_FUNCTION, index, &function->result)) {
            return false;
        }
    } else {
        function->result.kind = TYPE_VOID;
        function->result.index = 0;
        function->result.start = token_start(frontend, *cursor);
        function->result.end = function->result.start;
    }
    if (!token_is(frontend, *cursor, "{")) {
        set_error(frontend, "E2S127",
            token_start(frontend, *cursor),
            token_end(frontend, *cursor),
            "expected a function body");
        return false;
    }
    function->body_start = *cursor;
    {
        size_t depth = 0;
        do {
            if (*cursor >= frontend->token_count) {
                set_error(frontend, "E2S127", start, start,
                    "function '%s' body is not closed", function->name);
                return false;
            }
            if (token_is(frontend, *cursor, "{")) depth += 1;
            if (token_is(frontend, *cursor, "}")) depth -= 1;
            *cursor += 1;
        } while (depth > 0);
    }
    function->body_end = *cursor;
    function->end = token_end(frontend, *cursor - 1);
    return true;
}

static bool collect_declarations(Frontend *frontend) {
    size_t cursor = 0;
    while (cursor < frontend->token_count) {
        bool local = true;
        if (token_is(frontend, cursor, "foreign")) {
            local = false;
            cursor += 1;
        }
        if (token_is(frontend, cursor, "trait")) {
            if (!parse_trait(frontend, &cursor, local)) return false;
            continue;
        }
        if (token_is(frontend, cursor, "type")) {
            if (!parse_nominal(frontend, &cursor, local)) return false;
            continue;
        }
        if (!local) {
            set_error(frontend, "E2S127",
                token_start(frontend, cursor),
                token_end(frontend, cursor),
                "'foreign' applies to a trait or a type declaration");
            return false;
        }
        if (token_is(frontend, cursor, "impl")) {
            if (!parse_implementation(frontend, &cursor)) return false;
            continue;
        }
        if (token_is(frontend, cursor, "fn")) {
            if (!parse_function_header(frontend, &cursor)) return false;
            continue;
        }
        set_error(frontend, "E2S127",
            token_start(frontend, cursor),
            token_end(frontend, cursor),
            "expected 'trait', 'type', 'impl', 'fn', or 'foreign'");
        return false;
    }
    return true;
}

/* Substitutes a trait's type parameters with an implementation's concrete
 * type arguments. */
static TypeRef substitute_for_implementation(
    const Frontend *frontend,
    TypeRef type,
    const Implementation *implementation
) {
    const Trait *trait;
    if (type.kind != TYPE_PARAMETER) return type;
    trait = &frontend->traits[implementation->trait_index];
    for (size_t slot = 0; slot < trait->type_parameter_count; ++slot) {
        size_t parameter = trait->type_parameter_start + slot;
        if (parameter != type.index) continue;
        if (slot >= implementation->type_argument_count) break;
        {
            TypeRef substituted = implementation->type_arguments[slot];
            substituted.start = type.start;
            substituted.end = type.end;
            return substituted;
        }
    }
    return type;
}

static bool check_implementations(Frontend *frontend) {
    for (size_t index = 0; index < frontend->implementation_count; ++index) {
        Implementation *implementation = &frontend->implementations[index];
        const Trait *trait = &frontend->traits[implementation->trait_index];

        if (!implementation_is_admissible(frontend, implementation)) {
            char owner[IDENTITY_LIMIT];
            char self[IDENTITY_LIMIT];
            trait_id(frontend, implementation->trait_index, owner,
                sizeof(owner));
            type_id(frontend, implementation->self_type, self, sizeof(self));
            set_error(frontend, "E2S131",
                implementation->start,
                implementation->end,
                "orphan rule: %s implements foreign trait %s for foreign type "
                "%s; an implementation requires a local trait or a local "
                "outer nominal self-type",
                "this package",
                owner,
                self);
            return false;
        }
        /* Every declared slot is matched by name against the implementation's
         * own methods, so the members are checked pairwise rather than by
         * position: an implementation may write them in any order, and a
         * missing or unknown member is named rather than mistaken for a
         * signature mismatch on whichever member happened to be first. */
        for (size_t slot = 0; slot < trait->method_count; ++slot) {
            const Method *declared_method =
                &frontend->methods[trait->method_start + slot];
            const ImplementationMethod *written_method = NULL;

            for (size_t seen = 0; seen < implementation->method_count; ++seen) {
                const ImplementationMethod *candidate =
                    &frontend->implementation_methods[
                        implementation->method_start + seen];
                if (strcmp(candidate->name, declared_method->name) != 0) {
                    continue;
                }
                written_method = candidate;
                break;
            }
            if (written_method == NULL) {
                /* When exactly one written member is unmatched, the two
                 * facts are one misspelling, so name it and point at it
                 * rather than making the reader find it. */
                const ImplementationMethod *stray = NULL;
                size_t stray_count = 0;
                for (size_t seen = 0;
                        seen < implementation->method_count; ++seen) {
                    const ImplementationMethod *candidate =
                        &frontend->implementation_methods[
                            implementation->method_start + seen];
                    bool matched = false;
                    for (size_t at = 0; at < trait->method_count; ++at) {
                        if (strcmp(
                                frontend->methods[trait->method_start + at].name,
                                candidate->name) != 0) {
                            continue;
                        }
                        matched = true;
                        break;
                    }
                    if (matched) continue;
                    stray = candidate;
                    stray_count += 1;
                }
                if (stray_count == 1) {
                    set_error(frontend, "E2S127",
                        stray->start,
                        stray->end,
                        "trait '%s' declares method '%s' but the "
                        "implementation declares '%s'",
                        trait->name,
                        declared_method->name,
                        stray->name);
                    return false;
                }
                set_error(frontend, "E2S127",
                    implementation->start,
                    implementation->end,
                    "trait '%s' declares method '%s' but the implementation "
                    "does not",
                    trait->name,
                    declared_method->name);
                return false;
            }
            if (written_method->parameter_count !=
                declared_method->parameter_count) {
                set_error(frontend, "E2S128",
                    written_method->start,
                    written_method->end,
                    "method '%s' takes %zu parameter(s) but the implementation "
                    "declares %zu",
                    declared_method->name,
                    declared_method->parameter_count,
                    written_method->parameter_count);
                return false;
            }
            for (size_t at = 0; at < declared_method->parameter_count; ++at) {
                const Parameter *declared =
                    &frontend->parameters[
                        declared_method->parameter_start + at];
                const Parameter *written =
                    &frontend->parameters[
                        written_method->parameter_start + at];
                TypeRef expected = substitute_for_implementation(
                    frontend, declared->type, implementation);
                if (type_equal(frontend, expected, written->type)) continue;
                {
                    char wanted[IDENTITY_LIMIT];
                    char actual[IDENTITY_LIMIT];
                    type_id(frontend, expected, wanted, sizeof(wanted));
                    type_id(frontend, written->type, actual, sizeof(actual));
                    set_error(frontend, "E2S128",
                        written->start,
                        written->end,
                        "parameter '%s' of method '%s' is %s after "
                        "substitution but the implementation declares %s",
                        declared->name,
                        declared_method->name,
                        wanted,
                        actual);
                    return false;
                }
            }
            {
                TypeRef expected = substitute_for_implementation(
                    frontend, declared_method->result, implementation);
                if (!type_equal(frontend, expected, written_method->result)) {
                    char wanted[IDENTITY_LIMIT];
                    char actual[IDENTITY_LIMIT];
                    type_id(frontend, expected, wanted, sizeof(wanted));
                    type_id(frontend, written_method->result, actual,
                        sizeof(actual));
                    set_error(frontend, "E2S128",
                        written_method->result.start,
                        written_method->result.end,
                        "method '%s' returns %s after substitution but the "
                        "implementation declares %s",
                        declared_method->name,
                        wanted,
                        actual);
                    return false;
                }
            }
        }
        /* An implementation method the trait never declared is refused here
         * rather than ignored, so a typo does not become dead code that
         * looks implemented. */
        for (size_t seen = 0; seen < implementation->method_count; ++seen) {
            const ImplementationMethod *written_method =
                &frontend->implementation_methods[
                    implementation->method_start + seen];
            bool declared = false;
            for (size_t slot = 0; slot < trait->method_count; ++slot) {
                if (strcmp(frontend->methods[trait->method_start + slot].name,
                        written_method->name) != 0) {
                    continue;
                }
                declared = true;
                break;
            }
            if (declared) continue;
            set_error(frontend, "E2S127",
                written_method->start,
                written_method->end,
                "trait '%s' declares no method '%s'",
                trait->name,
                written_method->name);
            return false;
        }
        /* Overlap is refused where implementations are declared, so no
         * candidate set is ever ordered at a use site. */
        for (size_t other = 0; other < index; ++other) {
            const Implementation *previous = &frontend->implementations[other];
            bool same = previous->trait_index == implementation->trait_index &&
                previous->type_argument_count ==
                    implementation->type_argument_count &&
                type_equal(frontend, previous->self_type,
                    implementation->self_type);
            if (!same) continue;
            for (size_t slot = 0;
                slot < implementation->type_argument_count;
                ++slot) {
                if (!type_equal(frontend, previous->type_arguments[slot],
                        implementation->type_arguments[slot])) {
                    same = false;
                    break;
                }
            }
            if (!same) continue;
            {
                char identity[IMPLEMENTATION_IDENTITY_LIMIT];
                implementation_id(frontend, other, identity, sizeof(identity));
                set_error(frontend, "E2S130",
                    implementation->start,
                    implementation->end,
                    "implementation overlaps %s declared earlier; resolution "
                    "admits exactly one candidate",
                    identity);
                return false;
            }
        }
    }
    return true;
}

static ptrdiff_t find_implementation(
    const Frontend *frontend,
    size_t trait_index,
    TypeRef self_type
) {
    for (size_t index = 0; index < frontend->implementation_count; ++index) {
        const Implementation *implementation = &frontend->implementations[index];
        if (implementation->trait_index != trait_index) continue;
        if (!type_equal(frontend, implementation->self_type, self_type)) {
            continue;
        }
        return (ptrdiff_t)index;
    }
    return -1;
}

static ptrdiff_t find_function_parameter(
    const Frontend *frontend,
    size_t function_index,
    const char *name
) {
    const Function *function = &frontend->functions[function_index];
    for (size_t slot = 0; slot < function->parameter_count; ++slot) {
        size_t index = function->parameter_start + slot;
        if (strcmp(frontend->parameters[index].name, name) == 0) {
            return (ptrdiff_t)index;
        }
    }
    return -1;
}

static bool parse_body_expression(
    Frontend *frontend,
    size_t function_index,
    size_t *cursor,
    TypeRef *output
);

static bool parse_method_call(
    Frontend *frontend,
    size_t function_index,
    size_t *cursor,
    size_t trait_index,
    TypeRef *output
) {
    Function *function = &frontend->functions[function_index];
    const Trait *trait = &frontend->traits[trait_index];
    const Method *method = NULL;
    MethodCall *call;
    char method_name[TEXT_LIMIT];
    size_t start = token_start(frontend, *cursor);
    size_t arguments = 0;

    if (function->bound < 0) {
        set_error(frontend, "E2S129", start, token_end(frontend, *cursor),
            "function '%s' calls trait '%s' without declaring a bound that "
            "provides it",
            function->name,
            trait->name);
        return false;
    }
    if (frontend->bounds[function->bound].trait_index != trait_index) {
        set_error(frontend, "E2S129", start, token_end(frontend, *cursor),
            "function '%s' is bounded by trait '%s', not '%s'",
            function->name,
            frontend->traits[
                frontend->bounds[function->bound].trait_index].name,
            trait->name);
        return false;
    }
    if (frontend->method_call_count >= METHOD_CALL_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "method call count exceeds %u", METHOD_CALL_LIMIT);
        return false;
    }
    *cursor += 1;  /* the trait name */
    if (!expect_token(frontend, cursor, ".")) return false;
    if (!expect_identifier(frontend, cursor, method_name)) return false;
    /* The call names its member, so the slot comes from that name rather
     * than from being the only one. */
    for (size_t slot = 0; slot < trait->method_count; ++slot) {
        const Method *candidate = &frontend->methods[trait->method_start + slot];
        if (strcmp(candidate->name, method_name) != 0) continue;
        method = candidate;
        break;
    }
    if (method == NULL) {
        set_error(frontend, "E2S127", start,
            token_end(frontend, *cursor - 1),
            "trait '%s' has no method '%s'", trait->name, method_name);
        return false;
    }
    if (!expect_token(frontend, cursor, "(")) return false;
    if (!token_is(frontend, *cursor, ")")) {
        for (;;) {
            TypeRef argument;
            if (!parse_body_expression(
                    frontend, function_index, cursor, &argument)) {
                return false;
            }
            arguments += 1;
            if (token_is(frontend, *cursor, ",")) {
                *cursor += 1;
                continue;
            }
            break;
        }
    }
    if (!expect_token(frontend, cursor, ")")) return false;
    if (arguments != method->parameter_count) {
        set_error(frontend, "E2S128", start,
            token_end(frontend, *cursor - 1),
            "method '%s' takes %zu argument(s) but %zu were written",
            method->name, method->parameter_count, arguments);
        return false;
    }
    call = &frontend->method_calls[frontend->method_call_count];
    memset(call, 0, sizeof(*call));
    call->caller = function_index;
    call->trait_index = trait_index;
    call->method_slot = method->slot;
    call->via_type_parameter = frontend->bounds[function->bound].type_parameter;
    call->dictionary_parameter = -1;
    call->argument_count = arguments;
    call->result = method->result;
    call->start = start;
    call->end = token_end(frontend, *cursor - 1);
    frontend->method_call_count += 1;
    *output = method->result;
    return true;
}

static bool parse_generic_call(
    Frontend *frontend,
    size_t function_index,
    size_t *cursor,
    size_t callee_index,
    TypeRef *output
) {
    Call *call;
    const Function *callee;
    size_t start = token_start(frontend, *cursor);

    if (frontend->call_count >= CALL_LIMIT) {
        set_error(frontend, "E2S133", start, start,
            "call count exceeds %u", CALL_LIMIT);
        return false;
    }
    call = &frontend->calls[frontend->call_count];
    memset(call, 0, sizeof(*call));
    call->caller = function_index;
    call->callee = callee_index;
    call->selected_implementation = -1;
    call->dictionary_argument = -1;
    call->dictionary_parameter = -1;
    call->start = start;
    *cursor += 1;  /* the callee name */

    callee = &frontend->functions[callee_index];
    if (token_is(frontend, *cursor, "[")) {
        *cursor += 1;
        for (;;) {
            TypeRef argument;
            if (call->type_argument_count >= TYPE_ARGUMENT_LIMIT) {
                set_error(frontend, "E2S133",
                    token_start(frontend, *cursor),
                    token_end(frontend, *cursor),
                    "type argument count exceeds %u", TYPE_ARGUMENT_LIMIT);
                return false;
            }
            if (!parse_type_ref(
                    frontend, cursor, OWNER_FUNCTION, function_index,
                    &argument)) {
                return false;
            }
            call->type_arguments[call->type_argument_count] = argument;
            call->type_argument_count += 1;
            if (token_is(frontend, *cursor, ",")) {
                *cursor += 1;
                continue;
            }
            break;
        }
        if (!expect_token(frontend, cursor, "]")) return false;
    }
    if (call->type_argument_count != callee->type_parameter_count) {
        set_error(frontend, "E2S127", start,
            token_end(frontend, *cursor - 1),
            "function '%s' takes %zu type argument(s) but %zu were written",
            callee->name,
            callee->type_parameter_count,
            call->type_argument_count);
        return false;
    }
    if (!expect_token(frontend, cursor, "(")) return false;
    if (!token_is(frontend, *cursor, ")")) {
        for (;;) {
            TypeRef argument;
            if (call->argument_count >= TYPE_ARGUMENT_LIMIT) {
                set_error(frontend, "E2S133",
                    token_start(frontend, *cursor),
                    token_end(frontend, *cursor),
                    "value argument count exceeds %u", TYPE_ARGUMENT_LIMIT);
                return false;
            }
            if (!parse_body_expression(
                    frontend, function_index, cursor, &argument)) {
                return false;
            }
            call->argument_types[call->argument_count] = argument;
            call->argument_count += 1;
            if (token_is(frontend, *cursor, ",")) {
                *cursor += 1;
                continue;
            }
            break;
        }
    }
    if (!expect_token(frontend, cursor, ")")) return false;
    call->end = token_end(frontend, *cursor - 1);

    if (call->argument_count != callee->parameter_count) {
        set_error(frontend, "E2S128", call->start, call->end,
            "function '%s' takes %zu argument(s) but %zu were written",
            callee->name, callee->parameter_count, call->argument_count);
        return false;
    }
    /* The callee's bound must be discharged by a declared implementation for
     * the written type argument. Exactly one candidate or a diagnostic. */
    if (callee->bound >= 0) {
        const Bound *bound = &frontend->bounds[callee->bound];
        TypeRef self = call->type_arguments[0];
        ptrdiff_t found = find_implementation(
            frontend, bound->trait_index, self);
        if (found < 0) {
            char wanted[IDENTITY_LIMIT];
            char actual[IDENTITY_LIMIT];
            trait_id(frontend, bound->trait_index, wanted, sizeof(wanted));
            type_id(frontend, self, actual, sizeof(actual));
            set_error(frontend, "E2S129", call->start, call->end,
                "no implementation of %s for %s; the bound on '%s' is "
                "unsatisfied and no candidate was found",
                wanted, actual, callee->name);
            return false;
        }
        call->selected_implementation = found;
    }
    for (size_t slot = 0; slot < callee->parameter_count; ++slot) {
        const Parameter *declared =
            &frontend->parameters[callee->parameter_start + slot];
        TypeRef expected = declared->type;
        if (expected.kind == TYPE_PARAMETER &&
            callee->type_parameter_count == 1) {
            expected = call->type_arguments[0];
        }
        if (type_equal(frontend, expected, call->argument_types[slot])) {
            continue;
        }
        {
            char wanted[IDENTITY_LIMIT];
            char actual[IDENTITY_LIMIT];
            type_id(frontend, expected, wanted, sizeof(wanted));
            type_id(frontend, call->argument_types[slot], actual,
                sizeof(actual));
            set_error(frontend, "E2S128", call->start, call->end,
                "argument %zu of '%s' is %s after substitution but %s was "
                "written",
                slot + 1, callee->name, wanted, actual);
            return false;
        }
    }
    call->result = callee->result;
    if (call->result.kind == TYPE_PARAMETER &&
        callee->type_parameter_count == 1) {
        call->result = call->type_arguments[0];
    }
    frontend->call_count += 1;
    *output = call->result;
    return true;
}

static bool parse_body_expression(
    Frontend *frontend,
    size_t function_index,
    size_t *cursor,
    TypeRef *output
) {
    size_t start = token_start(frontend, *cursor);

    if (token_has_kind(frontend, *cursor, TOKEN_INTEGER)) {
        output->kind = TYPE_INT;
        output->index = 0;
        output->start = start;
        output->end = token_end(frontend, *cursor);
        *cursor += 1;
        return true;
    }
    if (token_has_kind(frontend, *cursor, TOKEN_TEXT)) {
        output->kind = TYPE_TEXT;
        output->index = 0;
        output->start = start;
        output->end = token_end(frontend, *cursor);
        *cursor += 1;
        return true;
    }
    if (token_is(frontend, *cursor, "true") ||
        token_is(frontend, *cursor, "false")) {
        output->kind = TYPE_BOOL;
        output->index = 0;
        output->start = start;
        output->end = token_end(frontend, *cursor);
        *cursor += 1;
        return true;
    }
    if (token_has_kind(frontend, *cursor, TOKEN_IDENTIFIER)) {
        const char *name = frontend->tokens[*cursor].text;
        ptrdiff_t found;

        if (token_is(frontend, *cursor + 1, ".")) {
            found = find_trait(frontend, name);
            if (found < 0) {
                set_error(frontend, "E2S127", start,
                    token_end(frontend, *cursor),
                    "unknown trait '%s'", name);
                return false;
            }
            return parse_method_call(
                frontend, function_index, cursor, (size_t)found, output);
        }
        found = find_function(frontend, name);
        if (found >= 0 &&
            (token_is(frontend, *cursor + 1, "[") ||
             token_is(frontend, *cursor + 1, "("))) {
            return parse_generic_call(
                frontend, function_index, cursor, (size_t)found, output);
        }
        found = find_function_parameter(frontend, function_index, name);
        if (found >= 0) {
            TypeRef type = frontend->parameters[(size_t)found].type;
            type.start = start;
            type.end = token_end(frontend, *cursor);
            *output = type;
            *cursor += 1;
            return true;
        }
        set_error(frontend, "E2S127", start, token_end(frontend, *cursor),
            "unknown name '%s'", name);
        return false;
    }
    set_error(frontend, "E2S127", start, token_end(frontend, *cursor),
        "expected an expression");
    return false;
}

static bool type_function_bodies(Frontend *frontend) {
    for (size_t index = 0; index < frontend->function_count; ++index) {
        Function *function = &frontend->functions[index];
        size_t cursor = function->body_start;
        if (cursor >= frontend->token_count) continue;
        if (!expect_token(frontend, &cursor, "{")) return false;
        while (!token_is(frontend, cursor, "}")) {
            TypeRef produced;
            if (cursor >= frontend->token_count) {
                set_error(frontend, "E2S127", function->start, function->end,
                    "function '%s' body is not closed", function->name);
                return false;
            }
            if (!expect_token(frontend, &cursor, "return")) return false;
            if (!parse_body_expression(frontend, index, &cursor, &produced)) {
                return false;
            }
            if (!type_equal(frontend, produced, function->result)) {
                char wanted[IDENTITY_LIMIT];
                char actual[IDENTITY_LIMIT];
                type_id(frontend, function->result, wanted, sizeof(wanted));
                type_id(frontend, produced, actual, sizeof(actual));
                set_error(frontend, "E2S128", produced.start, produced.end,
                    "function '%s' returns %s but the body produces %s",
                    function->name, wanted, actual);
                return false;
            }
        }
        if (!expect_token(frontend, &cursor, "}")) return false;
    }
    return true;
}

static ptrdiff_t find_dictionary(
    const Frontend *frontend,
    size_t implementation_index
) {
    for (size_t index = 0; index < frontend->dictionary_count; ++index) {
        if (frontend->dictionaries[index].implementation ==
            implementation_index) {
            return (ptrdiff_t)index;
        }
    }
    return -1;
}

static ptrdiff_t find_dictionary_parameter(
    const Frontend *frontend,
    size_t function_index,
    size_t bound_index
) {
    for (size_t index = 0;
        index < frontend->dictionary_parameter_count;
        ++index) {
        const DictionaryParameter *parameter =
            &frontend->dictionary_parameters[index];
        if (parameter->owner_function != function_index) continue;
        if (parameter->bound != bound_index) continue;
        return (ptrdiff_t)index;
    }
    return -1;
}

/*
 * Elaborates the dictionary shape (#923).
 *
 * This runs only after tokenizing, declaration collection, implementation
 * checking, and body typing have all succeeded, so no dictionary is ever
 * constructed for a program that is refused — every unsupported form (a second
 * bound, a blanket implementation, a default method, a recursive bound, a
 * two-parameter trait, an orphan or overlapping implementation, an unsatisfied
 * bound) has already stopped the run with its own diagnostic.
 *
 * Nothing here searches for a candidate. Selection already happened at the call
 * site and produced exactly one ImplementationId; this pass names the
 * dictionary that identity denotes and the parameter it is passed in.
 */
static void elaborate_dictionaries(Frontend *frontend) {
    for (size_t index = 0; index < frontend->trait_count; ++index) {
        const Trait *trait = &frontend->traits[index];
        DictionaryDescriptor *descriptor =
            &frontend->descriptors[frontend->descriptor_count];
        descriptor->trait_index = index;
        descriptor->method_start = trait->method_start;
        descriptor->slot_count = trait->method_count;
        frontend->descriptor_count += 1;
    }
    /* Every implementation that reaches this pass is admissible, and overlap
     * was refused where they were declared, so one dictionary per
     * implementation is also one dictionary per coherence key. */
    for (size_t index = 0; index < frontend->implementation_count; ++index) {
        Dictionary *dictionary =
            &frontend->dictionaries[frontend->dictionary_count];
        dictionary->implementation = index;
        dictionary->descriptor =
            frontend->implementations[index].trait_index;
        frontend->dictionary_count += 1;
    }
    /* One dictionary parameter per declared bound, in declaration order. */
    for (size_t index = 0; index < frontend->bound_count; ++index) {
        const Bound *bound = &frontend->bounds[index];
        size_t slot = frontend->dictionary_parameter_count;
        DictionaryParameter *parameter = &frontend->dictionary_parameters[slot];
        size_t ordinal = 0;
        for (size_t earlier = 0; earlier < index; ++earlier) {
            if (frontend->bounds[earlier].owner_function ==
                bound->owner_function) {
                ordinal += 1;
            }
        }
        parameter->owner_function = bound->owner_function;
        parameter->bound = index;
        parameter->descriptor = bound->trait_index;
        parameter->ordinal = ordinal;
        frontend->dictionary_parameter_count += 1;
    }
    /* A bounded call passes the dictionary its selected implementation
     * produces, into the callee parameter that discharges the bound. */
    for (size_t index = 0; index < frontend->call_count; ++index) {
        Call *call = &frontend->calls[index];
        const Function *callee = &frontend->functions[call->callee];
        if (call->selected_implementation < 0 || callee->bound < 0) continue;
        call->dictionary_argument =
            find_dictionary(frontend, (size_t)call->selected_implementation);
        call->dictionary_parameter = find_dictionary_parameter(
            frontend, call->callee, (size_t)callee->bound);
    }
    /* A trait method call inside a generic body is a lookup in the caller's
     * dictionary parameter at the method's slot. */
    for (size_t index = 0; index < frontend->method_call_count; ++index) {
        MethodCall *call = &frontend->method_calls[index];
        const Function *caller = &frontend->functions[call->caller];
        if (caller->bound < 0) continue;
        call->dictionary_parameter = find_dictionary_parameter(
            frontend, call->caller, (size_t)caller->bound);
    }
}

static char *read_source(const char *path, size_t *length_output) {
    FILE *file = fopen(path, "rb");
    char *buffer;
    size_t length;

    if (file == NULL) return NULL;
    buffer = malloc(SOURCE_LIMIT + 1u);
    if (buffer == NULL) {
        fclose(file);
        return NULL;
    }
    length = fread(buffer, 1, SOURCE_LIMIT, file);
    if (ferror(file) != 0) {
        free(buffer);
        fclose(file);
        return NULL;
    }
    fclose(file);
    buffer[length] = '\0';
    *length_output = length;
    return buffer;
}

static void write_type_list(
    const Frontend *frontend,
    const TypeRef *types,
    size_t count,
    char *output,
    size_t size
) {
    size_t written = 0;
    output[0] = '\0';
    for (size_t slot = 0; slot < count; ++slot) {
        char identity[IDENTITY_LIMIT];
        int printed;
        type_id(frontend, types[slot], identity, sizeof(identity));
        printed = snprintf(
            output + written,
            size - written,
            "%s%s",
            slot == 0 ? "" : ",",
            identity
        );
        if (printed < 0) return;
        written += (size_t)printed;
        if (written >= size) return;
    }
}

/* The descriptor's ordered slot table: one MethodId per slot, in trait
 * declaration order. */
static void write_slot_methods(
    const Frontend *frontend,
    const DictionaryDescriptor *descriptor,
    char *output,
    size_t size
) {
    size_t written = 0;
    output[0] = '\0';
    for (size_t slot = 0; slot < descriptor->slot_count; ++slot) {
        const Method *method =
            &frontend->methods[descriptor->method_start + slot];
        char identity[IDENTITY_LIMIT];
        int printed;
        method_id(
            frontend, method->owner_trait, method->slot, identity,
            sizeof(identity));
        printed = snprintf(
            output + written,
            size - written,
            "%s%s",
            slot == 0 ? "" : ",",
            identity
        );
        if (printed < 0) return;
        written += (size_t)printed;
        if (written >= size) return;
    }
}

static bool write_ir(const Frontend *frontend, const char *path) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) return false;
    /* v2 adds the dictionary descriptor, value, entry, and parameter records,
     * the dictionary argument on `call`, and the dictionary parameter and
     * method slot on `method-call` (#923). Every v1 record is unchanged. */
    fprintf(file, "kofun-traits-ir/v2\n");

    for (size_t index = 0; index < frontend->trait_count; ++index) {
        const Trait *trait = &frontend->traits[index];
        char identity[IDENTITY_LIMIT];
        trait_id(frontend, index, identity, sizeof(identity));
        fprintf(
            file,
            "trait|trait-id=%s|name=%s|package=%s|type-parameters=%zu"
            "|methods=%zu|span=%zu..%zu\n",
            identity,
            trait->name,
            trait->local ? "local" : "foreign",
            trait->type_parameter_count,
            trait->method_count,
            trait->start,
            trait->end
        );
    }
    for (size_t index = 0; index < frontend->nominal_count; ++index) {
        const Nominal *nominal = &frontend->nominals[index];
        char target[IDENTITY_LIMIT];
        if (nominal->is_alias) {
            type_id(frontend, nominal->alias_target, target, sizeof(target));
        } else {
            snprintf(target, sizeof(target), "none");
        }
        fprintf(
            file,
            "type|type-id=nominal:%s:%s|name=%s|package=%s|alias=%s"
            "|span=%zu..%zu\n",
            nominal_is_local(frontend, index) ? "local" : "foreign",
            nominal->name,
            nominal->name,
            nominal_is_local(frontend, index) ? "local" : "foreign",
            target,
            nominal->start,
            nominal->end
        );
    }
    for (size_t index = 0; index < frontend->type_parameter_count; ++index) {
        const TypeParameter *parameter = &frontend->type_parameters[index];
        TypeRef reference;
        char identity[IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        reference.kind = TYPE_PARAMETER;
        reference.index = index;
        reference.start = parameter->start;
        reference.end = parameter->end;
        type_id(frontend, reference, identity, sizeof(identity));
        if (parameter->owner_kind == OWNER_FUNCTION) {
            snprintf(owner, sizeof(owner), "function:%s",
                frontend->functions[parameter->owner_index].name);
        } else if (parameter->owner_kind == OWNER_TRAIT_METHOD) {
            trait_id(frontend, parameter->owner_index, owner, sizeof(owner));
        } else {
            snprintf(owner, sizeof(owner), "implementation:%zu",
                parameter->owner_index);
        }
        fprintf(
            file,
            "type-parameter|type-parameter-id=%s|owner=%s|name=%s|index=%zu"
            "|span=%zu..%zu\n",
            identity,
            owner,
            parameter->name,
            parameter->ordinal,
            parameter->start,
            parameter->end
        );
    }
    for (size_t index = 0; index < frontend->method_count; ++index) {
        const Method *method = &frontend->methods[index];
        char identity[IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        char result[IDENTITY_LIMIT];
        method_id(frontend, method->owner_trait, method->slot, identity,
            sizeof(identity));
        trait_id(frontend, method->owner_trait, owner, sizeof(owner));
        type_id(frontend, method->result, result, sizeof(result));
        fprintf(
            file,
            "method|method-id=%s|owner=%s|name=%s|slot=%zu|parameters=%zu"
            "|result=%s|span=%zu..%zu\n",
            identity,
            owner,
            method->name,
            method->slot,
            method->parameter_count,
            result,
            method->start,
            method->end
        );
    }
    for (size_t index = 0; index < frontend->descriptor_count; ++index) {
        const DictionaryDescriptor *descriptor = &frontend->descriptors[index];
        const Trait *trait = &frontend->traits[descriptor->trait_index];
        char identity[IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        char slots[IDENTITY_LIMIT];
        dictionary_descriptor_id(
            frontend, descriptor->trait_index, identity, sizeof(identity));
        trait_id(frontend, descriptor->trait_index, owner, sizeof(owner));
        write_slot_methods(frontend, descriptor, slots, sizeof(slots));
        fprintf(
            file,
            "dictionary-descriptor|descriptor-id=%s|trait=%s|abi=%s"
            "|slots=%zu|slot-methods=%s|span=%zu..%zu\n",
            identity,
            owner,
            IMPLEMENTATION_ABI,
            descriptor->slot_count,
            slots,
            trait->start,
            trait->end
        );
    }
    for (size_t index = 0; index < frontend->implementation_count; ++index) {
        const Implementation *implementation = &frontend->implementations[index];
        char identity[IMPLEMENTATION_IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        char arguments[IDENTITY_LIMIT];
        char self[IDENTITY_LIMIT];
        implementation_id(frontend, index, identity, sizeof(identity));
        trait_id(frontend, implementation->trait_index, owner, sizeof(owner));
        write_type_list(
            frontend,
            implementation->type_arguments,
            implementation->type_argument_count,
            arguments,
            sizeof(arguments)
        );
        type_id(frontend, implementation->self_type, self, sizeof(self));
        {
            /* Members in declared slot order, so the row reads the same way
             * the descriptor's `slot-methods` does. */
            char members[IDENTITY_LIMIT];
            size_t written = 0;
            members[0] = '\0';
            for (size_t seen = 0; seen < implementation->method_count; ++seen) {
                const ImplementationMethod *method =
                    &frontend->implementation_methods[
                        implementation->method_start + seen];
                int printed = snprintf(
                    members + written,
                    sizeof(members) - written,
                    "%s%s",
                    seen == 0 ? "" : ",",
                    method->name
                );
                if (printed < 0) break;
                written += (size_t)printed;
                if (written >= sizeof(members)) break;
            }
            fprintf(
                file,
                "implementation|implementation-id=%s|trait=%s|type-arguments=%s"
                "|self-type=%s|method=%s|span=%zu..%zu\n",
                identity,
                owner,
                arguments,
                self,
                members,
                implementation->start,
                implementation->end
            );
        }
    }
    for (size_t index = 0; index < frontend->dictionary_count; ++index) {
        const Dictionary *dictionary = &frontend->dictionaries[index];
        const DictionaryDescriptor *descriptor =
            &frontend->descriptors[dictionary->descriptor];
        const Implementation *implementation =
            &frontend->implementations[dictionary->implementation];
        char identity[DICTIONARY_IDENTITY_LIMIT];
        char shape[IDENTITY_LIMIT];
        char source[IMPLEMENTATION_IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        char self[IDENTITY_LIMIT];
        dictionary_id(
            frontend, dictionary->implementation, identity, sizeof(identity));
        dictionary_descriptor_id(
            frontend, descriptor->trait_index, shape, sizeof(shape));
        implementation_id(
            frontend, dictionary->implementation, source, sizeof(source));
        trait_id(frontend, implementation->trait_index, owner, sizeof(owner));
        type_id(frontend, implementation->self_type, self, sizeof(self));
        fprintf(
            file,
            "dictionary|dictionary-id=%s|descriptor=%s|implementation=%s"
            "|trait=%s|self-type=%s|slots=%zu|span=%zu..%zu\n",
            identity,
            shape,
            source,
            owner,
            self,
            descriptor->slot_count,
            implementation->start,
            implementation->end
        );
    }
    for (size_t index = 0; index < frontend->dictionary_count; ++index) {
        const Dictionary *dictionary = &frontend->dictionaries[index];
        const DictionaryDescriptor *descriptor =
            &frontend->descriptors[dictionary->descriptor];
        const Implementation *implementation =
            &frontend->implementations[dictionary->implementation];
        char identity[DICTIONARY_IDENTITY_LIMIT];
        dictionary_id(
            frontend, dictionary->implementation, identity, sizeof(identity));
        for (size_t slot = 0; slot < descriptor->slot_count; ++slot) {
            const Method *method =
                &frontend->methods[descriptor->method_start + slot];
            const ImplementationMethod *written = NULL;
            char declared[IDENTITY_LIMIT];
            method_id(
                frontend, method->owner_trait, method->slot, declared,
                sizeof(declared));
            /* The checker has already proved every slot has exactly one
             * implementation method of that name, so this lookup cannot
             * miss; the slot is filled by name, never by position. */
            for (size_t seen = 0; seen < implementation->method_count; ++seen) {
                const ImplementationMethod *candidate =
                    &frontend->implementation_methods[
                        implementation->method_start + seen];
                if (strcmp(candidate->name, method->name) != 0) continue;
                written = candidate;
                break;
            }
            if (written == NULL) continue;
            fprintf(
                file,
                "dictionary-entry|dictionary=%s|slot=%zu|method=%s"
                "|implementation-method=%s|span=%zu..%zu\n",
                identity,
                slot,
                declared,
                written->name,
                written->start,
                written->end
            );
        }
    }
    for (size_t index = 0; index < frontend->function_count; ++index) {
        const Function *function = &frontend->functions[index];
        char result[IDENTITY_LIMIT];
        type_id(frontend, function->result, result, sizeof(result));
        fprintf(
            file,
            "function|function-id=function:%s|name=%s|type-parameters=%zu"
            "|parameters=%zu|result=%s|span=%zu..%zu\n",
            function->name,
            function->name,
            function->type_parameter_count,
            function->parameter_count,
            result,
            function->start,
            function->end
        );
    }
    for (size_t index = 0; index < frontend->bound_count; ++index) {
        const Bound *bound = &frontend->bounds[index];
        TypeRef reference;
        char parameter[IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        char arguments[IDENTITY_LIMIT];
        reference.kind = TYPE_PARAMETER;
        reference.index = bound->type_parameter;
        reference.start = bound->start;
        reference.end = bound->end;
        type_id(frontend, reference, parameter, sizeof(parameter));
        trait_id(frontend, bound->trait_index, owner, sizeof(owner));
        write_type_list(
            frontend,
            bound->type_arguments,
            bound->type_argument_count,
            arguments,
            sizeof(arguments)
        );
        fprintf(
            file,
            "bound|owner=function:%s|type-parameter=%s|trait=%s"
            "|type-arguments=%s|span=%zu..%zu\n",
            frontend->functions[bound->owner_function].name,
            parameter,
            owner,
            arguments,
            bound->start,
            bound->end
        );
    }
    for (size_t index = 0;
        index < frontend->dictionary_parameter_count;
        ++index) {
        const DictionaryParameter *parameter =
            &frontend->dictionary_parameters[index];
        const Bound *bound = &frontend->bounds[parameter->bound];
        TypeRef reference;
        char identity[IDENTITY_LIMIT];
        char shape[IDENTITY_LIMIT];
        char discharged[IDENTITY_LIMIT];
        char owner[IDENTITY_LIMIT];
        dictionary_parameter_id(frontend, index, identity, sizeof(identity));
        dictionary_descriptor_id(
            frontend, parameter->descriptor, shape, sizeof(shape));
        reference.kind = TYPE_PARAMETER;
        reference.index = bound->type_parameter;
        reference.start = bound->start;
        reference.end = bound->end;
        type_id(frontend, reference, discharged, sizeof(discharged));
        trait_id(frontend, bound->trait_index, owner, sizeof(owner));
        fprintf(
            file,
            "dictionary-parameter|dictionary-parameter-id=%s|owner=function:%s"
            "|index=%zu|descriptor=%s|discharges-bound=%s|trait=%s"
            "|span=%zu..%zu\n",
            identity,
            frontend->functions[parameter->owner_function].name,
            parameter->ordinal,
            shape,
            discharged,
            owner,
            bound->start,
            bound->end
        );
    }
    for (size_t index = 0; index < frontend->method_call_count; ++index) {
        const MethodCall *call = &frontend->method_calls[index];
        TypeRef reference;
        char identity[IDENTITY_LIMIT];
        char parameter[IDENTITY_LIMIT];
        char dictionary[IDENTITY_LIMIT];
        char result[IDENTITY_LIMIT];
        method_id(frontend, call->trait_index, call->method_slot, identity,
            sizeof(identity));
        reference.kind = TYPE_PARAMETER;
        reference.index = call->via_type_parameter;
        reference.start = call->start;
        reference.end = call->end;
        type_id(frontend, reference, parameter, sizeof(parameter));
        if (call->dictionary_parameter >= 0) {
            dictionary_parameter_id(
                frontend,
                (size_t)call->dictionary_parameter,
                dictionary,
                sizeof(dictionary)
            );
        } else {
            snprintf(dictionary, sizeof(dictionary), "none");
        }
        type_id(frontend, call->result, result, sizeof(result));
        fprintf(
            file,
            "method-call|caller=function:%s|method=%s|via-bound=%s"
            "|dictionary-parameter=%s|method-slot=%zu"
            "|value-arguments=%zu|result=%s|use-span=%zu..%zu\n",
            frontend->functions[call->caller].name,
            identity,
            parameter,
            dictionary,
            call->method_slot,
            call->argument_count,
            result,
            call->start,
            call->end
        );
    }
    for (size_t index = 0; index < frontend->call_count; ++index) {
        const Call *call = &frontend->calls[index];
        const Function *callee = &frontend->functions[call->callee];
        char arguments[IDENTITY_LIMIT];
        char result[IDENTITY_LIMIT];
        char selected[IMPLEMENTATION_IDENTITY_LIMIT];
        char passed[DICTIONARY_IDENTITY_LIMIT];
        char parameter[IDENTITY_LIMIT];
        write_type_list(
            frontend,
            call->type_arguments,
            call->type_argument_count,
            arguments,
            sizeof(arguments)
        );
        type_id(frontend, call->result, result, sizeof(result));
        if (call->selected_implementation >= 0) {
            implementation_id(
                frontend,
                (size_t)call->selected_implementation,
                selected,
                sizeof(selected)
            );
        } else {
            snprintf(selected, sizeof(selected), "none");
        }
        /* The dictionary argument is the dictionary the selected
         * implementation produces; the two fields are one derivation apart, so
         * a call that passed anything else is visible on this line. */
        if (call->dictionary_argument >= 0) {
            dictionary_id(
                frontend,
                frontend->dictionaries[
                    (size_t)call->dictionary_argument].implementation,
                passed,
                sizeof(passed)
            );
        } else {
            snprintf(passed, sizeof(passed), "none");
        }
        if (call->dictionary_parameter >= 0) {
            dictionary_parameter_id(
                frontend,
                (size_t)call->dictionary_parameter,
                parameter,
                sizeof(parameter)
            );
        } else {
            snprintf(parameter, sizeof(parameter), "none");
        }
        fprintf(
            file,
            "call|caller=function:%s|callee=function:%s|type-arguments=%s"
            "|value-arguments=%zu|result=%s|selected-implementation=%s"
            "|dictionary-arguments=%s|dictionary-parameter=%s"
            "|use-span=%zu..%zu|declaration-span=%zu..%zu\n",
            frontend->functions[call->caller].name,
            callee->name,
            arguments,
            call->argument_count,
            result,
            selected,
            passed,
            parameter,
            call->start,
            call->end,
            callee->start,
            callee->end
        );
    }
    if (fclose(file) != 0) return false;
    return true;
}

static bool write_tokens(const Frontend *frontend, const char *path) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) return false;
    fprintf(file, "kofun-traits-tokens/v1\n");
    for (size_t index = 0; index < frontend->token_count; ++index) {
        const Token *token = &frontend->tokens[index];
        const char *kind = "punctuation";
        switch (token->kind) {
            case TOKEN_IDENTIFIER: kind = "identifier"; break;
            case TOKEN_INTEGER: kind = "integer"; break;
            case TOKEN_TEXT: kind = "text"; break;
            case TOKEN_ARROW: kind = "arrow"; break;
            case TOKEN_PUNCTUATION: kind = "punctuation"; break;
        }
        fprintf(file, "%s|%zu..%zu\n", kind, token->start, token->end);
    }
    if (fclose(file) != 0) return false;
    return true;
}

int main(int argc, char **argv) {
    Frontend *frontend;
    char *source;
    size_t length = 0;
    int status = 0;

    if (argc != 4) {
        fprintf(stderr, "usage: kofun-traits-frontend SOURCE IR TOKENS\n");
        return 2;
    }
    source = read_source(argv[1], &length);
    if (source == NULL) {
        fprintf(stderr, "kofun-traits-frontend: cannot read %s\n", argv[1]);
        return 2;
    }
    frontend = calloc(1, sizeof(*frontend));
    if (frontend == NULL) {
        free(source);
        fprintf(stderr, "kofun-traits-frontend: out of memory\n");
        return 2;
    }

    if (tokenize(frontend, source, length) &&
        collect_declarations(frontend) &&
        check_implementations(frontend) &&
        type_function_bodies(frontend)) {
        /* Last, and only on the accepted path: a refused program never gets a
         * dictionary. */
        elaborate_dictionaries(frontend);
        if (!write_ir(frontend, argv[2]) || !write_tokens(frontend, argv[3])) {
            fprintf(stderr, "kofun-traits-frontend: cannot write output\n");
            status = 2;
        }
    } else {
        printf("%s\n", frontend->error);
        status = 1;
    }

    free(frontend);
    free(source);
    return status;
}
