/*
 * Bounded C11 consumer for the one-method Equal[Int] dictionary profile.
 *
 * The general trait frontend remains a typed-IR producer.  This consumer
 * validates one deliberately closed kofun-traits-ir/v2 shape and then
 * executes the already-elaborated dictionary argument/parameter/slot wiring.
 * It does not lower arbitrary method bodies, generic layouts, vtables, or
 * runtime instance search.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE_LIMIT 2048u
#define RECORD_LIMIT 64u
#define PROFILE_FIELD_LIMIT 16u
#define ARRAY_COUNT(values) (sizeof(values) / sizeof((values)[0]))

static const char *const TRAIT_ID = "trait:local:Equal";
static const char *const METHOD_ID = "method:trait:local:Equal:0";
static const char *const DESCRIPTOR_ID =
    "dictionary-descriptor:abi1/trait:local:Equal";
static const char *const IMPLEMENTATION_ID =
    "impl:abi1/package:local/trait:local:Equal/args=builtin:Int/"
    "self=builtin:Int/decl=0";
static const char *const DICTIONARY_ID =
    "dictionary:abi1/package:local/trait:local:Equal/args=builtin:Int/"
    "self=builtin:Int";
static const char *const TYPE_PARAMETER_ID =
    "type-parameter:function:same:0";
static const char *const DICTIONARY_PARAMETER_ID =
    "dictionary-parameter:function:same:0";

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

typedef struct {
    size_t records;
    size_t traits;
    size_t type_parameters;
    size_t methods;
    size_t descriptors;
    size_t implementations;
    size_t dictionaries;
    size_t entries;
    size_t functions;
    size_t bounds;
    size_t dictionary_parameters;
    size_t method_calls;
    size_t calls;
    bool trait_type_parameter;
    bool function_type_parameter;
    bool same_function;
    bool use_int_function;
    char implementation_id[512];
    char dictionary_id[512];
} Profile;

typedef bool (*EqualIntMethod)(int64_t left, int64_t right);

typedef struct {
    const char *identity;
    EqualIntMethod slot0;
} EqualIntDictionary;

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
            "field '%s' is '%s', expected '%s'", key, value, expected);
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

static bool validate_trait(Profile *profile, const char *line, size_t number) {
    profile->traits += 1u;
    return require_field(line, number, "trait-id", TRAIT_ID) &&
        require_field(line, number, "name", "Equal") &&
        require_field(line, number, "package", "local") &&
        require_field(line, number, "type-parameters", "1") &&
        require_field(line, number, "methods", "1") &&
        require_field(line, number, "span", "0..58");
}

static bool validate_type_parameter(
    Profile *profile,
    const char *line,
    size_t number
) {
    char identity[256];
    profile->type_parameters += 1u;
    if (!copy_field(line, number, "type-parameter-id", identity,
            sizeof(identity))) {
        return false;
    }
    if (strcmp(identity, "type-parameter:trait:local:Equal:0") == 0) {
        if (profile->trait_type_parameter) {
            return reject(number, "duplicate Equal type parameter");
        }
        profile->trait_type_parameter = true;
        return require_field(line, number, "owner", TRAIT_ID) &&
            require_field(line, number, "name", "T") &&
            require_field(line, number, "index", "0") &&
            require_field(line, number, "span", "12..13");
    }
    if (strcmp(identity, TYPE_PARAMETER_ID) == 0) {
        if (profile->function_type_parameter) {
            return reject(number, "duplicate same type parameter");
        }
        profile->function_type_parameter = true;
        return require_field(line, number, "owner", "function:same") &&
            require_field(line, number, "name", "T") &&
            require_field(line, number, "index", "0") &&
            require_field(line, number, "span", "169..170");
    }
    return reject(number, "profile contains an unexpected type parameter");
}

static bool validate_method(Profile *profile, const char *line, size_t number) {
    profile->methods += 1u;
    return require_field(line, number, "method-id", METHOD_ID) &&
        require_field(line, number, "owner", TRAIT_ID) &&
        require_field(line, number, "name", "equal") &&
        require_field(line, number, "slot", "0") &&
        require_field(line, number, "parameters", "2") &&
        require_field(line, number, "result", "builtin:Bool") &&
        require_field(line, number, "span", "21..56");
}

static bool validate_descriptor(
    Profile *profile,
    const char *line,
    size_t number
) {
    profile->descriptors += 1u;
    return require_field(line, number, "descriptor-id", DESCRIPTOR_ID) &&
        require_field(line, number, "trait", TRAIT_ID) &&
        require_field(line, number, "abi", "abi1") &&
        require_field(line, number, "slots", "1") &&
        require_field(line, number, "slot-methods", METHOD_ID) &&
        require_field(line, number, "span", "0..58");
}

static bool validate_implementation(
    Profile *profile,
    const char *line,
    size_t number
) {
    profile->implementations += 1u;
    return copy_field(line, number, "implementation-id",
            profile->implementation_id,
            sizeof(profile->implementation_id)) &&
        require_field(line, number, "implementation-id", IMPLEMENTATION_ID) &&
        require_field(line, number, "trait", TRAIT_ID) &&
        require_field(line, number, "type-arguments", "builtin:Int") &&
        require_field(line, number, "self-type", "builtin:Int") &&
        require_field(line, number, "method", "equal") &&
        require_field(line, number, "span", "60..159");
}

static bool validate_dictionary(
    Profile *profile,
    const char *line,
    size_t number
) {
    profile->dictionaries += 1u;
    return copy_field(line, number, "dictionary-id", profile->dictionary_id,
            sizeof(profile->dictionary_id)) &&
        require_field(line, number, "dictionary-id", DICTIONARY_ID) &&
        require_field(line, number, "descriptor", DESCRIPTOR_ID) &&
        require_field(line, number, "implementation", IMPLEMENTATION_ID) &&
        require_field(line, number, "trait", TRAIT_ID) &&
        require_field(line, number, "self-type", "builtin:Int") &&
        require_field(line, number, "slots", "1") &&
        require_field(line, number, "span", "60..159");
}

static bool validate_entry(Profile *profile, const char *line, size_t number) {
    profile->entries += 1u;
    return require_field(line, number, "dictionary", DICTIONARY_ID) &&
        require_field(line, number, "slot", "0") &&
        require_field(line, number, "method", METHOD_ID) &&
        require_field(line, number, "implementation-method", "equal") &&
        require_field(line, number, "span", "93..129");
}

static bool validate_function(Profile *profile, const char *line, size_t number) {
    char name[64];
    profile->functions += 1u;
    if (!copy_field(line, number, "name", name, sizeof(name))) return false;
    if (strcmp(name, "same") == 0) {
        if (profile->same_function) {
            return reject(number, "duplicate same function");
        }
        profile->same_function = true;
        return require_field(line, number, "function-id", "function:same") &&
            require_field(line, number, "type-parameters", "1") &&
            require_field(line, number, "parameters", "2") &&
            require_field(line, number, "result", "builtin:Bool") &&
            require_field(line, number, "span", "161..248");
    }
    if (strcmp(name, "use_int") == 0) {
        if (profile->use_int_function) {
            return reject(number, "duplicate use_int function");
        }
        profile->use_int_function = true;
        return require_field(line, number, "function-id", "function:use_int") &&
            require_field(line, number, "type-parameters", "0") &&
            require_field(line, number, "parameters", "2") &&
            require_field(line, number, "result", "builtin:Bool") &&
            require_field(line, number, "span", "250..329");
    }
    return reject(number, "profile contains a function other than same/use_int");
}

static bool validate_bound(Profile *profile, const char *line, size_t number) {
    profile->bounds += 1u;
    return require_field(line, number, "owner", "function:same") &&
        require_field(line, number, "type-parameter", TYPE_PARAMETER_ID) &&
        require_field(line, number, "trait", TRAIT_ID) &&
        require_field(line, number, "type-arguments", TYPE_PARAMETER_ID) &&
        require_field(line, number, "span", "170..180");
}

static bool validate_dictionary_parameter(
    Profile *profile,
    const char *line,
    size_t number
) {
    profile->dictionary_parameters += 1u;
    return require_field(line, number, "dictionary-parameter-id",
            DICTIONARY_PARAMETER_ID) &&
        require_field(line, number, "owner", "function:same") &&
        require_field(line, number, "index", "0") &&
        require_field(line, number, "descriptor", DESCRIPTOR_ID) &&
        require_field(line, number, "discharges-bound", TYPE_PARAMETER_ID) &&
        require_field(line, number, "trait", TRAIT_ID) &&
        require_field(line, number, "span", "170..180");
}

static bool validate_method_call(
    Profile *profile,
    const char *line,
    size_t number
) {
    profile->method_calls += 1u;
    return require_field(line, number, "caller", "function:same") &&
        require_field(line, number, "method", METHOD_ID) &&
        require_field(line, number, "via-bound", TYPE_PARAMETER_ID) &&
        require_field(line, number, "dictionary-parameter",
            DICTIONARY_PARAMETER_ID) &&
        require_field(line, number, "method-slot", "0") &&
        require_field(line, number, "value-arguments", "2") &&
        require_field(line, number, "result", "builtin:Bool") &&
        require_field(line, number, "use-span", "222..246");
}

static bool validate_call(Profile *profile, const char *line, size_t number) {
    profile->calls += 1u;
    return require_field(line, number, "caller", "function:use_int") &&
        require_field(line, number, "callee", "function:same") &&
        require_field(line, number, "type-arguments", "builtin:Int") &&
        require_field(line, number, "value-arguments", "2") &&
        require_field(line, number, "result", "builtin:Bool") &&
        require_field(line, number, "selected-implementation",
            IMPLEMENTATION_ID) &&
        require_field(line, number, "dictionary-arguments", DICTIONARY_ID) &&
        require_field(line, number, "dictionary-parameter",
            DICTIONARY_PARAMETER_ID) &&
        require_field(line, number, "use-span", "305..327") &&
        require_field(line, number, "declaration-span", "161..248");
}

static bool validate_record(
    Profile *profile,
    const char *line,
    size_t number
) {
    char kind[64];
    if (!record_kind(line, kind, sizeof(kind))) {
        return reject(number, "missing or oversized record kind");
    }
    profile->records += 1u;
    if (profile->records > RECORD_LIMIT) {
        return reject(number, "profile exceeds 64 records");
    }
    if (strcmp(kind, "trait") == 0) {
        if (!validate_fields(line, number, kind, TRAIT_FIELDS,
                ARRAY_COUNT(TRAIT_FIELDS))) return false;
        return validate_trait(profile, line, number);
    }
    if (strcmp(kind, "type-parameter") == 0) {
        if (!validate_fields(line, number, kind, TYPE_PARAMETER_FIELDS,
                ARRAY_COUNT(TYPE_PARAMETER_FIELDS))) return false;
        return validate_type_parameter(profile, line, number);
    }
    if (strcmp(kind, "method") == 0) {
        if (!validate_fields(line, number, kind, METHOD_FIELDS,
                ARRAY_COUNT(METHOD_FIELDS))) return false;
        return validate_method(profile, line, number);
    }
    if (strcmp(kind, "dictionary-descriptor") == 0) {
        if (!validate_fields(line, number, kind, DESCRIPTOR_FIELDS,
                ARRAY_COUNT(DESCRIPTOR_FIELDS))) return false;
        return validate_descriptor(profile, line, number);
    }
    if (strcmp(kind, "implementation") == 0) {
        if (!validate_fields(line, number, kind, IMPLEMENTATION_FIELDS,
                ARRAY_COUNT(IMPLEMENTATION_FIELDS))) return false;
        return validate_implementation(profile, line, number);
    }
    if (strcmp(kind, "dictionary") == 0) {
        if (!validate_fields(line, number, kind, DICTIONARY_FIELDS,
                ARRAY_COUNT(DICTIONARY_FIELDS))) return false;
        return validate_dictionary(profile, line, number);
    }
    if (strcmp(kind, "dictionary-entry") == 0) {
        if (!validate_fields(line, number, kind, ENTRY_FIELDS,
                ARRAY_COUNT(ENTRY_FIELDS))) return false;
        return validate_entry(profile, line, number);
    }
    if (strcmp(kind, "function") == 0) {
        if (!validate_fields(line, number, kind, FUNCTION_FIELDS,
                ARRAY_COUNT(FUNCTION_FIELDS))) return false;
        return validate_function(profile, line, number);
    }
    if (strcmp(kind, "bound") == 0) {
        if (!validate_fields(line, number, kind, BOUND_FIELDS,
                ARRAY_COUNT(BOUND_FIELDS))) return false;
        return validate_bound(profile, line, number);
    }
    if (strcmp(kind, "dictionary-parameter") == 0) {
        if (!validate_fields(line, number, kind, DICTIONARY_PARAMETER_FIELDS,
                ARRAY_COUNT(DICTIONARY_PARAMETER_FIELDS))) return false;
        return validate_dictionary_parameter(profile, line, number);
    }
    if (strcmp(kind, "method-call") == 0) {
        if (!validate_fields(line, number, kind, METHOD_CALL_FIELDS,
                ARRAY_COUNT(METHOD_CALL_FIELDS))) return false;
        return validate_method_call(profile, line, number);
    }
    if (strcmp(kind, "call") == 0) {
        if (!validate_fields(line, number, kind, CALL_FIELDS,
                ARRAY_COUNT(CALL_FIELDS))) return false;
        return validate_call(profile, line, number);
    }
    return reject(number, "record kind is outside the Equal[Int] profile");
}

static bool validate_counts(const Profile *profile) {
    if (profile->records != 14u || profile->traits != 1u ||
        profile->type_parameters != 2u ||
        profile->methods != 1u || profile->descriptors != 1u ||
        profile->implementations != 1u || profile->dictionaries != 1u ||
        profile->entries != 1u || profile->functions != 2u ||
        profile->bounds != 1u ||
        profile->dictionary_parameters != 1u ||
        profile->method_calls != 1u || profile->calls != 1u ||
        !profile->trait_type_parameter ||
        !profile->function_type_parameter || !profile->same_function ||
        !profile->use_int_function) {
        return reject(0u,
            "profile must contain exactly one trait/method/dictionary/bound/"
            "dispatch, two type parameters/functions, and 14 records");
    }
    return true;
}

static bool validate_profile(const char *path, Profile *profile) {
    FILE *input = fopen(path, "rb");
    char line[LINE_LIMIT];
    size_t line_number = 0u;
    bool header = false;
    if (input == NULL) return reject(0u, "cannot open input IR");

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

static bool same_int(
    const EqualIntDictionary *dictionary,
    int64_t left,
    int64_t right
) {
    return dictionary->slot0(left, right);
}

int main(int argc, char **argv) {
    Profile profile = {0};
    EqualIntDictionary dictionary;
    bool result;
    if (argc != 2) {
        fprintf(stderr, "usage: traits_dictionary_c11 INPUT.ir\n");
        return 2;
    }
    if (!validate_profile(argv[1], &profile)) return 1;

    dictionary.identity = profile.dictionary_id;
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
