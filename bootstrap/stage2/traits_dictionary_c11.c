/*
 * Bounded C11 consumer for two deliberately closed Int dictionary profiles.
 *
 * The general trait frontend remains a typed-IR producer. This consumer
 * validates either the one-method Equal[Int] profile or the two-method
 * Ordered[Int] profile, then executes the already-elaborated dictionary
 * parameter and slot wiring. It does not lower arbitrary method bodies,
 * generic layouts, vtables, or runtime instance search.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE_LIMIT 2048u
#define RECORD_LIMIT 64u
#define PROFILE_FIELD_LIMIT 16u
#define EXPECTED_RECORD_LIMIT 24u
#define ARRAY_COUNT(values) (sizeof(values) / sizeof((values)[0]))

static const char *const TRAIT_FIELDS[] = {
    "trait-id", "name", "package", "type-parameters", "methods", "span"
};
static const char *const TYPE_PARAMETER_FIELDS[] = {
    "type-parameter-id", "owner", "name", "index", "span"
};
static const char *const METHOD_FIELDS[] = {
    "method-id", "owner", "name", "slot", "parameters", "result", "span"
};
static const char *const DESCRIPTOR_FIELDS[] = {
    "descriptor-id", "trait", "abi", "slots", "slot-methods", "span"
};
static const char *const IMPLEMENTATION_FIELDS[] = {
    "implementation-id", "trait", "type-arguments", "self-type", "method",
    "span"
};
static const char *const DICTIONARY_FIELDS[] = {
    "dictionary-id", "descriptor", "implementation", "trait", "self-type",
    "slots", "span"
};
static const char *const ENTRY_FIELDS[] = {
    "dictionary", "slot", "method", "implementation-method", "span"
};
static const char *const FUNCTION_FIELDS[] = {
    "function-id", "name", "type-parameters", "parameters", "result", "span"
};
static const char *const BOUND_FIELDS[] = {
    "owner", "type-parameter", "trait", "type-arguments", "span"
};
static const char *const DICTIONARY_PARAMETER_FIELDS[] = {
    "dictionary-parameter-id", "owner", "index", "descriptor",
    "discharges-bound", "trait", "span"
};
static const char *const METHOD_CALL_FIELDS[] = {
    "caller", "method", "via-bound", "dictionary-parameter", "method-slot",
    "value-arguments", "result", "use-span"
};
static const char *const CALL_FIELDS[] = {
    "caller", "callee", "type-arguments", "value-arguments", "result",
    "selected-implementation", "dictionary-arguments", "dictionary-parameter",
    "use-span", "declaration-span"
};

typedef enum {
    FIELD_MISSING,
    FIELD_PRESENT,
    FIELD_INVALID
} FieldStatus;

typedef enum {
    PROFILE_EQUAL_INT,
    PROFILE_ORDERED_INT
} ProfileKind;

typedef struct {
    const char *selector_key;
    const char *selector_value;
    const char *line;
} ExpectedRecord;

typedef struct {
    ProfileKind kind;
    const char *name;
    const char *trait_id;
    const ExpectedRecord *records;
    size_t record_count;
} ProfileSpec;

typedef struct {
    const ProfileSpec *spec;
    size_t records;
    bool seen[EXPECTED_RECORD_LIMIT];
    char implementation_id[512];
    char dictionary_id[512];
} Profile;

#define EXPECTED(key, value, record) {key, value, record}

static const ExpectedRecord EQUAL_INT_RECORDS[] = {
    EXPECTED("trait-id", "trait:local:Equal",
        "trait|trait-id=trait:local:Equal|name=Equal|package=local|"
        "type-parameters=1|methods=1|span=0..58"),
    EXPECTED("type-parameter-id", "type-parameter:trait:local:Equal:0",
        "type-parameter|type-parameter-id=type-parameter:trait:local:Equal:0|"
        "owner=trait:local:Equal|name=T|index=0|span=12..13"),
    EXPECTED("type-parameter-id", "type-parameter:function:same:0",
        "type-parameter|type-parameter-id=type-parameter:function:same:0|"
        "owner=function:same|name=T|index=0|span=169..170"),
    EXPECTED("method-id", "method:trait:local:Equal:0",
        "method|method-id=method:trait:local:Equal:0|owner=trait:local:Equal|"
        "name=equal|slot=0|parameters=2|result=builtin:Bool|span=21..56"),
    EXPECTED("descriptor-id", "dictionary-descriptor:abi1/trait:local:Equal",
        "dictionary-descriptor|descriptor-id=dictionary-descriptor:abi1/"
        "trait:local:Equal|trait=trait:local:Equal|abi=abi1|slots=1|"
        "slot-methods=method:trait:local:Equal:0|span=0..58"),
    EXPECTED("implementation-id",
        "impl:abi1/package:local/trait:local:Equal/args=builtin:Int/"
        "self=builtin:Int/decl=0",
        "implementation|implementation-id=impl:abi1/package:local/"
        "trait:local:Equal/args=builtin:Int/self=builtin:Int/decl=0|"
        "trait=trait:local:Equal|type-arguments=builtin:Int|"
        "self-type=builtin:Int|method=equal|span=60..159"),
    EXPECTED("dictionary-id",
        "dictionary:abi1/package:local/trait:local:Equal/args=builtin:Int/"
        "self=builtin:Int",
        "dictionary|dictionary-id=dictionary:abi1/package:local/"
        "trait:local:Equal/args=builtin:Int/self=builtin:Int|descriptor="
        "dictionary-descriptor:abi1/trait:local:Equal|implementation="
        "impl:abi1/package:local/trait:local:Equal/args=builtin:Int/"
        "self=builtin:Int/decl=0|trait=trait:local:Equal|"
        "self-type=builtin:Int|slots=1|span=60..159"),
    EXPECTED("slot", "0",
        "dictionary-entry|dictionary=dictionary:abi1/package:local/"
        "trait:local:Equal/args=builtin:Int/self=builtin:Int|slot=0|"
        "method=method:trait:local:Equal:0|implementation-method=equal|"
        "span=93..129"),
    EXPECTED("function-id", "function:same",
        "function|function-id=function:same|name=same|type-parameters=1|"
        "parameters=2|result=builtin:Bool|span=161..248"),
    EXPECTED("function-id", "function:use_int",
        "function|function-id=function:use_int|name=use_int|type-parameters=0|"
        "parameters=2|result=builtin:Bool|span=250..329"),
    EXPECTED("owner", "function:same",
        "bound|owner=function:same|type-parameter="
        "type-parameter:function:same:0|trait=trait:local:Equal|"
        "type-arguments=type-parameter:function:same:0|span=170..180"),
    EXPECTED("dictionary-parameter-id", "dictionary-parameter:function:same:0",
        "dictionary-parameter|dictionary-parameter-id="
        "dictionary-parameter:function:same:0|owner=function:same|index=0|"
        "descriptor=dictionary-descriptor:abi1/trait:local:Equal|"
        "discharges-bound=type-parameter:function:same:0|"
        "trait=trait:local:Equal|span=170..180"),
    EXPECTED("caller", "function:same",
        "method-call|caller=function:same|method=method:trait:local:Equal:0|"
        "via-bound=type-parameter:function:same:0|dictionary-parameter="
        "dictionary-parameter:function:same:0|method-slot=0|"
        "value-arguments=2|result=builtin:Bool|use-span=222..246"),
    EXPECTED("caller", "function:use_int",
        "call|caller=function:use_int|callee=function:same|"
        "type-arguments=builtin:Int|value-arguments=2|result=builtin:Bool|"
        "selected-implementation=impl:abi1/package:local/trait:local:Equal/"
        "args=builtin:Int/self=builtin:Int/decl=0|dictionary-arguments="
        "dictionary:abi1/package:local/trait:local:Equal/args=builtin:Int/"
        "self=builtin:Int|dictionary-parameter="
        "dictionary-parameter:function:same:0|use-span=305..327|"
        "declaration-span=161..248")
};

static const ExpectedRecord ORDERED_INT_RECORDS[] = {
    EXPECTED("trait-id", "trait:local:Ordered",
        "trait|trait-id=trait:local:Ordered|name=Ordered|package=local|"
        "type-parameters=1|methods=2|span=0..103"),
    EXPECTED("type-parameter-id", "type-parameter:trait:local:Ordered:0",
        "type-parameter|type-parameter-id=type-parameter:trait:local:Ordered:0|"
        "owner=trait:local:Ordered|name=T|index=0|span=14..15"),
    EXPECTED("type-parameter-id", "type-parameter:function:same:0",
        "type-parameter|type-parameter-id=type-parameter:function:same:0|"
        "owner=function:same|name=T|index=0|span=291..292"),
    EXPECTED("type-parameter-id", "type-parameter:function:earlier:0",
        "type-parameter|type-parameter-id=type-parameter:function:earlier:0|"
        "owner=function:earlier|name=T|index=0|span=387..388"),
    EXPECTED("method-id", "method:trait:local:Ordered:0",
        "method|method-id=method:trait:local:Ordered:0|"
        "owner=trait:local:Ordered|name=equal|slot=0|parameters=2|"
        "result=builtin:Bool|span=23..58"),
    EXPECTED("method-id", "method:trait:local:Ordered:1",
        "method|method-id=method:trait:local:Ordered:1|"
        "owner=trait:local:Ordered|name=before|slot=1|parameters=2|"
        "result=builtin:Bool|span=63..101"),
    EXPECTED("descriptor-id", "dictionary-descriptor:abi1/trait:local:Ordered",
        "dictionary-descriptor|descriptor-id=dictionary-descriptor:abi1/"
        "trait:local:Ordered|trait=trait:local:Ordered|abi=abi1|slots=2|"
        "slot-methods=method:trait:local:Ordered:0,"
        "method:trait:local:Ordered:1|span=0..103"),
    EXPECTED("implementation-id",
        "impl:abi1/package:local/trait:local:Ordered/args=builtin:Int/"
        "self=builtin:Int/decl=0",
        "implementation|implementation-id=impl:abi1/package:local/"
        "trait:local:Ordered/args=builtin:Int/self=builtin:Int/decl=0|"
        "trait=trait:local:Ordered|type-arguments=builtin:Int|"
        "self-type=builtin:Int|method=before,equal|span=105..281"),
    EXPECTED("dictionary-id",
        "dictionary:abi1/package:local/trait:local:Ordered/args=builtin:Int/"
        "self=builtin:Int",
        "dictionary|dictionary-id=dictionary:abi1/package:local/"
        "trait:local:Ordered/args=builtin:Int/self=builtin:Int|descriptor="
        "dictionary-descriptor:abi1/trait:local:Ordered|implementation="
        "impl:abi1/package:local/trait:local:Ordered/args=builtin:Int/"
        "self=builtin:Int/decl=0|trait=trait:local:Ordered|"
        "self-type=builtin:Int|slots=2|span=105..281"),
    EXPECTED("slot", "0",
        "dictionary-entry|dictionary=dictionary:abi1/package:local/"
        "trait:local:Ordered/args=builtin:Int/self=builtin:Int|slot=0|"
        "method=method:trait:local:Ordered:0|implementation-method=equal|"
        "span=215..251"),
    EXPECTED("slot", "1",
        "dictionary-entry|dictionary=dictionary:abi1/package:local/"
        "trait:local:Ordered/args=builtin:Int/self=builtin:Int|slot=1|"
        "method=method:trait:local:Ordered:1|implementation-method=before|"
        "span=140..179"),
    EXPECTED("function-id", "function:same",
        "function|function-id=function:same|name=same|type-parameters=1|"
        "parameters=2|result=builtin:Bool|span=283..374"),
    EXPECTED("function-id", "function:earlier",
        "function|function-id=function:earlier|name=earlier|type-parameters=1|"
        "parameters=2|result=builtin:Bool|span=376..475"),
    EXPECTED("owner", "function:same",
        "bound|owner=function:same|type-parameter="
        "type-parameter:function:same:0|trait=trait:local:Ordered|"
        "type-arguments=type-parameter:function:same:0|span=292..304"),
    EXPECTED("owner", "function:earlier",
        "bound|owner=function:earlier|type-parameter="
        "type-parameter:function:earlier:0|trait=trait:local:Ordered|"
        "type-arguments=type-parameter:function:earlier:0|span=388..400"),
    EXPECTED("dictionary-parameter-id", "dictionary-parameter:function:same:0",
        "dictionary-parameter|dictionary-parameter-id="
        "dictionary-parameter:function:same:0|owner=function:same|index=0|"
        "descriptor=dictionary-descriptor:abi1/trait:local:Ordered|"
        "discharges-bound=type-parameter:function:same:0|"
        "trait=trait:local:Ordered|span=292..304"),
    EXPECTED("dictionary-parameter-id",
        "dictionary-parameter:function:earlier:0",
        "dictionary-parameter|dictionary-parameter-id="
        "dictionary-parameter:function:earlier:0|owner=function:earlier|"
        "index=0|descriptor=dictionary-descriptor:abi1/trait:local:Ordered|"
        "discharges-bound=type-parameter:function:earlier:0|"
        "trait=trait:local:Ordered|span=388..400"),
    EXPECTED("caller", "function:same",
        "method-call|caller=function:same|"
        "method=method:trait:local:Ordered:0|"
        "via-bound=type-parameter:function:same:0|dictionary-parameter="
        "dictionary-parameter:function:same:0|method-slot=0|"
        "value-arguments=2|result=builtin:Bool|use-span=346..372"),
    EXPECTED("caller", "function:earlier",
        "method-call|caller=function:earlier|"
        "method=method:trait:local:Ordered:1|"
        "via-bound=type-parameter:function:earlier:0|dictionary-parameter="
        "dictionary-parameter:function:earlier:0|method-slot=1|"
        "value-arguments=2|result=builtin:Bool|use-span=444..473")
};

static const ProfileSpec PROFILE_SPECS[] = {
    {
        PROFILE_EQUAL_INT,
        "Equal[Int]",
        "trait:local:Equal",
        EQUAL_INT_RECORDS,
        ARRAY_COUNT(EQUAL_INT_RECORDS)
    },
    {
        PROFILE_ORDERED_INT,
        "Ordered[Int]",
        "trait:local:Ordered",
        ORDERED_INT_RECORDS,
        ARRAY_COUNT(ORDERED_INT_RECORDS)
    }
};

typedef bool (*IntMethod)(int64_t left, int64_t right);

typedef struct {
    const char *identity;
    IntMethod slot0;
} EqualIntDictionary;

typedef struct {
    const char *identity;
    IntMethod slot0;
    IntMethod slot1;
} OrderedIntDictionary;

static size_t dispatch_count;

static bool reject(size_t line, const char *message) {
    if (line == 0u) {
        fprintf(stderr, "trait-dictionary-c11: %s\n", message);
    } else {
        fprintf(stderr, "trait-dictionary-c11: line %zu: %s\n", line,
            message);
    }
    return false;
}

static bool record_kind(const char *line, char *output, size_t output_size) {
    const char *end = strchr(line, '|');
    size_t length = end == NULL ? strlen(line) : (size_t)(end - line);
    if (length == 0u || length >= output_size) return false;
    memcpy(output, line, length);
    output[length] = '\0';
    return true;
}

static bool validate_fields(
    const char *line,
    size_t line_number,
    const char *kind,
    const char *const *allowed,
    size_t allowed_count
) {
    bool seen[PROFILE_FIELD_LIMIT] = {false};
    const char *cursor = strchr(line, '|');
    char diagnostic[256];

    if (allowed_count > PROFILE_FIELD_LIMIT) {
        return reject(0u, "internal profile field limit is too small");
    }
    if (cursor == NULL || cursor[1] == '\0') {
        return reject(line_number, "record has no fields");
    }
    cursor += 1;
    while (*cursor != '\0') {
        const char *end = strchr(cursor, '|');
        size_t length = end == NULL ? strlen(cursor) : (size_t)(end - cursor);
        const char *equals;
        size_t name_length;
        size_t index;

        if (length == 0u) {
            return reject(line_number, "record contains an empty field segment");
        }
        equals = memchr(cursor, '=', length);
        if (equals == NULL || equals == cursor ||
            equals == cursor + length - 1u) {
            return reject(line_number,
                "every field must have a non-empty name and value");
        }
        name_length = (size_t)(equals - cursor);
        for (index = 0u; index < allowed_count; ++index) {
            if (strlen(allowed[index]) == name_length &&
                memcmp(cursor, allowed[index], name_length) == 0) {
                break;
            }
        }
        if (index == allowed_count) {
            int precision = name_length > 96u ? 96 : (int)name_length;
            snprintf(diagnostic, sizeof(diagnostic),
                "unknown field '%.*s' for record kind '%s'",
                precision, cursor, kind);
            return reject(line_number, diagnostic);
        }
        if (seen[index]) {
            snprintf(diagnostic, sizeof(diagnostic),
                "duplicate field '%s' for record kind '%s'",
                allowed[index], kind);
            return reject(line_number, diagnostic);
        }
        seen[index] = true;
        if (end == NULL) break;
        if (end[1] == '\0') {
            return reject(line_number, "record contains an empty field segment");
        }
        cursor = end + 1;
    }
    for (size_t index = 0u; index < allowed_count; ++index) {
        if (!seen[index]) {
            snprintf(diagnostic, sizeof(diagnostic),
                "missing field '%s' for record kind '%s'",
                allowed[index], kind);
            return reject(line_number, diagnostic);
        }
    }
    return true;
}

static FieldStatus field_value(
    const char *line,
    const char *key,
    char *output,
    size_t output_size
) {
    const char *cursor = line;
    size_t key_length = strlen(key);
    bool found = false;

    while (*cursor != '\0') {
        const char *end = strchr(cursor, '|');
        size_t length = end == NULL ? strlen(cursor) : (size_t)(end - cursor);
        if (length > key_length + 1u &&
            memcmp(cursor, key, key_length) == 0 &&
            cursor[key_length] == '=') {
            size_t value_length = length - key_length - 1u;
            if (found || value_length == 0u || value_length >= output_size) {
                return FIELD_INVALID;
            }
            memcpy(output, cursor + key_length + 1u, value_length);
            output[value_length] = '\0';
            found = true;
        }
        if (end == NULL) break;
        cursor = end + 1;
    }
    return found ? FIELD_PRESENT : FIELD_MISSING;
}

static bool require_field(
    const char *line,
    size_t line_number,
    const char *key,
    const char *expected
) {
    char value[768];
    FieldStatus status = field_value(line, key, value, sizeof(value));
    char diagnostic[1024];
    if (status == FIELD_MISSING) {
        snprintf(diagnostic, sizeof(diagnostic), "missing field '%s'", key);
        return reject(line_number, diagnostic);
    }
    if (status == FIELD_INVALID) {
        snprintf(diagnostic, sizeof(diagnostic),
            "duplicate, empty, or oversized field '%s'", key);
        return reject(line_number, diagnostic);
    }
    if (strcmp(value, expected) != 0) {
        snprintf(diagnostic, sizeof(diagnostic),
            "field '%.96s' is '%.400s', expected '%.400s'",
            key, value, expected);
        return reject(line_number, diagnostic);
    }
    return true;
}

static bool copy_field(
    const char *line,
    size_t line_number,
    const char *key,
    char *output,
    size_t output_size
) {
    FieldStatus status = field_value(line, key, output, output_size);
    char diagnostic[256];
    if (status == FIELD_PRESENT) return true;
    snprintf(diagnostic, sizeof(diagnostic),
        status == FIELD_MISSING ? "missing field '%s'" :
        "duplicate, empty, or oversized field '%s'", key);
    return reject(line_number, diagnostic);
}

static bool fields_for_kind(
    const char *kind,
    const char *const **fields,
    size_t *field_count
) {
#define SELECT_FIELDS(record_kind_name, values) \
    if (strcmp(kind, record_kind_name) == 0) { \
        *fields = values; \
        *field_count = ARRAY_COUNT(values); \
        return true; \
    }
    SELECT_FIELDS("trait", TRAIT_FIELDS)
    SELECT_FIELDS("type-parameter", TYPE_PARAMETER_FIELDS)
    SELECT_FIELDS("method", METHOD_FIELDS)
    SELECT_FIELDS("dictionary-descriptor", DESCRIPTOR_FIELDS)
    SELECT_FIELDS("implementation", IMPLEMENTATION_FIELDS)
    SELECT_FIELDS("dictionary", DICTIONARY_FIELDS)
    SELECT_FIELDS("dictionary-entry", ENTRY_FIELDS)
    SELECT_FIELDS("function", FUNCTION_FIELDS)
    SELECT_FIELDS("bound", BOUND_FIELDS)
    SELECT_FIELDS("dictionary-parameter", DICTIONARY_PARAMETER_FIELDS)
    SELECT_FIELDS("method-call", METHOD_CALL_FIELDS)
    SELECT_FIELDS("call", CALL_FIELDS)
#undef SELECT_FIELDS
    return false;
}

static bool select_profile(Profile *profile, const char *line, size_t number) {
    char trait_id[256];
    if (!copy_field(line, number, "trait-id", trait_id, sizeof(trait_id))) {
        return false;
    }
    for (size_t index = 0u; index < ARRAY_COUNT(PROFILE_SPECS); ++index) {
        if (strcmp(trait_id, PROFILE_SPECS[index].trait_id) == 0) {
            if (PROFILE_SPECS[index].record_count > EXPECTED_RECORD_LIMIT) {
                return reject(0u, "internal expected record limit is too small");
            }
            profile->spec = &PROFILE_SPECS[index];
            return true;
        }
    }
    return reject(number, "trait is outside the closed C11 profiles");
}

static bool validate_expected_fields(
    const ExpectedRecord *expected,
    const char *line,
    size_t number,
    const char *const *fields,
    size_t field_count
) {
    for (size_t index = 0u; index < field_count; ++index) {
        char value[768];
        if (field_value(expected->line, fields[index], value,
                sizeof(value)) != FIELD_PRESENT) {
            return reject(0u, "internal expected record is malformed");
        }
        if (!require_field(line, number, fields[index], value)) return false;
    }
    return true;
}

static bool validate_record(Profile *profile, const char *line, size_t number) {
    char kind[64];
    const char *const *fields;
    size_t field_count;
    const char *selector_key = NULL;
    char selector_value[768];
    size_t match = 0u;
    bool found = false;
    char diagnostic[1024];

    if (!record_kind(line, kind, sizeof(kind))) {
        return reject(number, "missing or oversized record kind");
    }
    profile->records += 1u;
    if (profile->records > RECORD_LIMIT) {
        return reject(number, "profile exceeds 64 records");
    }
    if (!fields_for_kind(kind, &fields, &field_count)) {
        return reject(number, "record kind is outside the closed C11 profiles");
    }
    if (!validate_fields(line, number, kind, fields, field_count)) return false;
    if (profile->spec == NULL) {
        if (strcmp(kind, "trait") != 0) {
            return reject(number, "the trait record must identify the profile first");
        }
        if (!select_profile(profile, line, number)) return false;
    }

    for (size_t index = 0u; index < profile->spec->record_count; ++index) {
        char expected_kind[64];
        const ExpectedRecord *candidate = &profile->spec->records[index];
        if (!record_kind(candidate->line, expected_kind,
                sizeof(expected_kind))) {
            return reject(0u, "internal expected record kind is malformed");
        }
        if (strcmp(kind, expected_kind) != 0) continue;
        if (selector_key == NULL) {
            selector_key = candidate->selector_key;
            if (!copy_field(line, number, selector_key, selector_value,
                    sizeof(selector_value))) {
                return false;
            }
        }
        if (strcmp(selector_key, candidate->selector_key) != 0) {
            return reject(0u, "internal record selectors are inconsistent");
        }
        if (strcmp(selector_value, candidate->selector_value) == 0) {
            match = index;
            found = true;
            break;
        }
    }
    if (selector_key == NULL) {
        snprintf(diagnostic, sizeof(diagnostic),
            "%s profile does not admit record kind '%s'",
            profile->spec->name, kind);
        return reject(number, diagnostic);
    }
    if (!found) {
        snprintf(diagnostic, sizeof(diagnostic),
            "%s profile has no %s selected by %s='%s'",
            profile->spec->name, kind, selector_key, selector_value);
        return reject(number, diagnostic);
    }
    if (profile->seen[match]) {
        snprintf(diagnostic, sizeof(diagnostic),
            "duplicate %s selected by %s='%s'", kind, selector_key,
            selector_value);
        return reject(number, diagnostic);
    }
    if (!validate_expected_fields(&profile->spec->records[match], line,
            number, fields, field_count)) {
        return false;
    }
    profile->seen[match] = true;
    if (strcmp(kind, "implementation") == 0) {
        return copy_field(line, number, "implementation-id",
            profile->implementation_id, sizeof(profile->implementation_id));
    }
    if (strcmp(kind, "dictionary") == 0) {
        return copy_field(line, number, "dictionary-id",
            profile->dictionary_id, sizeof(profile->dictionary_id));
    }
    return true;
}

static bool derive_dictionary_id(
    const char *implementation,
    char *output,
    size_t output_size
) {
    static const char implementation_prefix[] = "impl:";
    static const char dictionary_prefix[] = "dictionary:";
    const char *declaration;
    size_t middle_length;
    size_t required;

    if (strncmp(implementation, implementation_prefix,
            sizeof(implementation_prefix) - 1u) != 0) {
        return false;
    }
    declaration = strstr(implementation, "/decl=");
    if (declaration == NULL || declaration[6] == '\0' ||
        strstr(declaration + 1, "/decl=") != NULL) {
        return false;
    }
    for (const char *digit = declaration + 6; *digit != '\0'; ++digit) {
        if (*digit < '0' || *digit > '9') return false;
    }
    middle_length = (size_t)(declaration -
        (implementation + sizeof(implementation_prefix) - 1u));
    required = sizeof(dictionary_prefix) - 1u + middle_length + 1u;
    if (required > output_size) return false;
    memcpy(output, dictionary_prefix, sizeof(dictionary_prefix) - 1u);
    memcpy(output + sizeof(dictionary_prefix) - 1u,
        implementation + sizeof(implementation_prefix) - 1u, middle_length);
    output[required - 1u] = '\0';
    return true;
}

static bool validate_counts(const Profile *profile) {
    char diagnostic[1024];
    if (profile->records != profile->spec->record_count) {
        for (size_t index = 0u; index < profile->spec->record_count; ++index) {
            if (!profile->seen[index]) {
                char kind[64];
                const ExpectedRecord *missing = &profile->spec->records[index];
                if (!record_kind(missing->line, kind, sizeof(kind))) {
                    return reject(0u, "internal expected record kind is malformed");
                }
                snprintf(diagnostic, sizeof(diagnostic),
                    "%s profile is missing %s selected by %s='%s'",
                    profile->spec->name, kind, missing->selector_key,
                    missing->selector_value);
                return reject(0u, diagnostic);
            }
        }
        snprintf(diagnostic, sizeof(diagnostic),
            "%s profile has %zu records, expected %zu", profile->spec->name,
            profile->records, profile->spec->record_count);
        return reject(0u, diagnostic);
    }
    for (size_t index = 0u; index < profile->spec->record_count; ++index) {
        if (!profile->seen[index]) {
            return reject(0u, "profile record accounting is inconsistent");
        }
    }
    return true;
}

static bool preflight_record_limit(FILE *input) {
    char line[LINE_LIMIT];
    size_t lines = 0u;
    while (fgets(line, sizeof(line), input) != NULL) {
        lines += 1u;
        if (lines > RECORD_LIMIT + 1u) {
            return reject(0u, "profile exceeds 64 records");
        }
    }
    if (ferror(input) != 0) {
        return reject(0u, "failed while reading input IR");
    }
    if (fseek(input, 0L, SEEK_SET) != 0) {
        return reject(0u, "cannot rewind input IR");
    }
    return true;
}

static bool validate_profile(const char *path, Profile *profile) {
    FILE *input = fopen(path, "rb");
    char line[LINE_LIMIT];
    size_t line_number = 0u;
    bool header = false;
    if (input == NULL) return reject(0u, "cannot open input IR");
    if (!preflight_record_limit(input)) {
        fclose(input);
        return false;
    }

    while (fgets(line, sizeof(line), input) != NULL) {
        size_t length;
        line_number += 1u;
        length = strlen(line);
        if (length == 0u || line[length - 1u] != '\n') {
            fclose(input);
            return reject(line_number,
                "line exceeds 2046 bytes or lacks its terminating newline");
        }
        line[length - 1u] = '\0';
        if (!header) {
            header = true;
            if (strcmp(line, "kofun-traits-ir/v2") != 0) {
                fclose(input);
                return reject(line_number,
                    "expected kofun-traits-ir/v2 header");
            }
            continue;
        }
        if (line[0] == '\0' || !validate_record(profile, line, line_number)) {
            fclose(input);
            return line[0] == '\0' ? reject(line_number,
                "empty records are not permitted") : false;
        }
    }
    if (ferror(input) != 0) {
        fclose(input);
        return reject(0u, "failed while reading input IR");
    }
    if (fclose(input) != 0) return reject(0u, "failed to close input IR");
    if (!header) return reject(0u, "input IR is empty");
    if (profile->spec == NULL) return reject(0u, "profile contains no trait");
    if (!validate_counts(profile)) return false;
    {
        char derived[512];
        if (!derive_dictionary_id(profile->implementation_id, derived,
                sizeof(derived))) {
            return reject(0u, "ImplementationId cannot derive a DictionaryId");
        }
        if (strcmp(derived, profile->dictionary_id) != 0) {
            return reject(0u,
                "DictionaryId is not derived from the selected ImplementationId");
        }
    }
    return true;
}

static bool equal_int_profile(int64_t left, int64_t right) {
    (void)left;
    (void)right;
    dispatch_count += 1u;
    return true;
}

static bool before_int_profile(int64_t left, int64_t right) {
    (void)left;
    (void)right;
    dispatch_count += 1u;
    return true;
}

static bool same_int(
    const EqualIntDictionary *dictionary,
    int64_t left,
    int64_t right
) {
    return dictionary->slot0(left, right);
}

static bool ordered_same_int(
    const OrderedIntDictionary *dictionary,
    int64_t left,
    int64_t right
) {
    return dictionary->slot0(left, right);
}

static bool earlier_int(
    const OrderedIntDictionary *dictionary,
    int64_t left,
    int64_t right
) {
    return dictionary->slot1(left, right);
}

static int execute_equal_int(const Profile *profile) {
    EqualIntDictionary dictionary;
    bool result;
    dictionary.identity = profile->dictionary_id;
    dictionary.slot0 = equal_int_profile;
    result = same_int(&dictionary, 7, 9);
    if (!result || dispatch_count != 1u) {
        reject(0u, "slot-0 dispatch produced an invalid observation");
        return 1;
    }

    printf("profile=trait-dictionary-c11/v1\n");
    printf("dictionary-id=%s\n", dictionary.identity);
    printf("method-slot=0\n");
    printf("same[Int](7,9)=%s\n", result ? "true" : "false");
    printf("dispatch-count=%zu\n", dispatch_count);
    return 0;
}

static int execute_ordered_int(const Profile *profile) {
    OrderedIntDictionary dictionary;
    bool same_result;
    bool earlier_result;
    dictionary.identity = profile->dictionary_id;
    dictionary.slot0 = equal_int_profile;
    dictionary.slot1 = before_int_profile;
    same_result = ordered_same_int(&dictionary, 7, 9);
    earlier_result = earlier_int(&dictionary, 7, 9);
    if (!same_result || !earlier_result || dispatch_count != 2u) {
        reject(0u, "two-slot dispatch produced an invalid observation");
        return 1;
    }

    printf("profile=trait-dictionary-c11/v2\n");
    printf("dictionary-id=%s\n", dictionary.identity);
    printf("same-method-slot=0\n");
    printf("same[Int](7,9)=%s\n", same_result ? "true" : "false");
    printf("earlier-method-slot=1\n");
    printf("earlier[Int](7,9)=%s\n", earlier_result ? "true" : "false");
    printf("dispatch-count=%zu\n", dispatch_count);
    return 0;
}

int main(int argc, char **argv) {
    Profile profile = {0};
    if (argc != 2) {
        fprintf(stderr, "usage: traits_dictionary_c11 INPUT.ir\n");
        return 2;
    }
    if (!validate_profile(argv[1], &profile)) return 1;
    if (profile.spec->kind == PROFILE_EQUAL_INT) {
        return execute_equal_int(&profile);
    }
    return execute_ordered_int(&profile);
}
