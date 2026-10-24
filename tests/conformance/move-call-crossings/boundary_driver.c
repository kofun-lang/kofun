/* #1540. Component witnesses for exclusions that need not be accepted by the
 * complete backend (for example a lexical Int callable fed a record). HIR is
 * still built by the production scope resolver, never fabricated by the test. */
#define main kofun_compiler_entry
#define KOFUN_STAGE2_AUTHORITY_API 1
#ifndef KOFUN_MOVE_COMPILER
#define KOFUN_MOVE_COMPILER "compiler.c"
#endif
#include KOFUN_MOVE_COMPILER
#undef KOFUN_STAGE2_AUTHORITY_API
#undef main

#define POINT "type Point = { x: Int }\n"
#define CONSUME "fn consume(take p: Point) -> Int { return p.x }\n"
#define LOCAL "let point: Point = Point(x: 1)\n"
/* #1737: a `Bytes`-field record appended to a bounded list. */
#define HEADER "type Header = { name: Bytes, value: Bytes }\n"
#define ITEMS "let items: List[Header] = []\n"
#define ENTRY "let header: Header = Header(name: stage2_bytes_empty(), value: stage2_bytes_empty())\n"
#define APPEND "stage2_list_append(items, "

static void require_boundary(bool condition, const char *label) {
    if (!condition) {
        fprintf(stderr, "FAIL: move-call boundary: %s\n", label);
        exit(1);
    }
}

static void check_move(const char *label, const char *source, bool expected) {
    char *hir = build_scope_hir(source);
    if (strncmp(hir, "error[", 6) == 0) {
        fprintf(stderr, "%s: %s\n", label, hir);
        exit(1);
    }
    const char *call = strstr(source, "consume(point");
    require_boundary(call != NULL, "fixture has no call");
    int64_t argument = (int64_t)(call - source) + 8;
    bool actual = move_call_binding(source, hir, argument);
    require_boundary(actual == expected, label);
    free(hir);
}

/* #1737. The element slot of `stage2_list_append(items, ...)`. `needle` finds
 * the call and `skip` steps from its start to the argument under test. */
static void check_append(
    const char *label,
    const char *source,
    const char *needle,
    size_t skip,
    bool expected
) {
    char *hir = build_scope_hir(source);
    if (strncmp(hir, "error[", 6) == 0) {
        fprintf(stderr, "%s: %s\n", label, hir);
        exit(1);
    }
    const char *call = strstr(source, needle);
    require_boundary(call != NULL, "fixture has no append call");
    bool actual = move_call_binding(source, hir, (int64_t)(call - source) + (int64_t)skip);
    require_boundary(actual == expected, label);
    free(hir);
}

int main(void) {
    require_boundary(!move_trivial_record("type RootAuthority = { x: Int }", "RootAuthority"), "root-authority-exclusion");
    require_boundary(!move_trivial_record("type EnvironmentAuthority = { x: Int }", "EnvironmentAuthority"), "environment-authority-exclusion");
    check_move("direct-owner", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "print(consume(point))\nreturn 0\n}\n", true);
    check_move("mode-check", POINT
        "fn consume(read p: Point) -> Int { return p.x }\n"
        "fn main() -> Int {\n" LOCAL "print(consume(point))\nreturn 0\n}\n", false);
    check_move("direct-resolution", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "let consume = (v) => v\n"
        "print(consume(point))\nreturn 0\n}\n", false);
    check_move("bare-binding", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "print(consume(point.x))\nreturn 0\n}\n", false);
    check_move("type-bound", "type Point = { x: Text }\n"
        "fn consume(take p: Point) -> Int { return 1 }\n"
        "fn main() -> Int {\nlet point: Point = Point(x: \"x\")\n"
        "print(consume(point))\nreturn 0\n}\n", false);
    check_move("borrowed-owner", POINT CONSUME
        "fn relay(read point: Point) -> Int { return consume(point) }\n"
        "fn main() -> Int { return 0 }\n", false);
    check_move("straight-line", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "if true { print(consume(point)) }\nreturn 0\n}\n", false);
    check_move("loop-condition", POINT
        "fn consume(take p: Point) -> Bool { return true }\n"
        "fn main() -> Int {\n" LOCAL "while consume(point) { return 0 }\nreturn 0\n}\n", false);
    check_move("coalescing-operand", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "let fallback: Int? = null\n"
        "print(fallback ?? consume(point))\nreturn 0\n}\n", false);
    check_move("completed-coalescing", POINT CONSUME
        "fn main() -> Int {\n" LOCAL "let fallback: Int? = null\n"
        "print(fallback ?? 0)\nprint(consume(point))\nreturn 0\n}\n", true);
    check_move("completed-coalescing-argument", POINT CONSUME
        "fn select(first: Int, second: Int) -> Int { return first + second }\n"
        "fn main() -> Int {\n" LOCAL "let fallback: Int? = null\n"
        "print(select(fallback ?? 0, consume(point)))\nreturn 0\n}\n", true);

    check_append("append-element", HEADER "fn main() -> Int {\n" ITEMS ENTRY
        APPEND "header)\nreturn 0\n}\n", APPEND, sizeof(APPEND) - 1, true);
    check_append("append-trivial-record", "type Point = { x: Int }\n"
        "fn main() -> Int {\nlet items: List[Point] = []\nlet point: Point = Point(x: 1)\n"
        "stage2_list_append(items, point)\nreturn 0\n}\n",
        APPEND, sizeof(APPEND) - 1, true);
    check_append("append-text-record", "type Point = { x: Text }\n"
        "fn main() -> Int {\nlet items: List[Point] = []\nlet point: Point = Point(x: \"x\")\n"
        "stage2_list_append(items, point)\nreturn 0\n}\n",
        APPEND, sizeof(APPEND) - 1, false);
    check_append("append-callee", HEADER
        "fn peek(read first: Header, read second: Header) -> Int { return 0 }\n"
        "fn main() -> Int {\n" ENTRY "let items: Header = Header(name: stage2_bytes_empty(), value: stage2_bytes_empty())\n"
        "return peek(items, header)\n}\n", "peek(items, ", sizeof("peek(items, ") - 1, false);
    check_append("append-direct-resolution", HEADER "fn main() -> Int {\n" ITEMS ENTRY
        "let stage2_list_append = (first, second) => first\n"
        APPEND "header)\nreturn 0\n}\n", APPEND, sizeof(APPEND) - 1, false);
    check_append("append-slot", HEADER "fn main() -> Int {\n" ENTRY
        "let items: Header = Header(name: stage2_bytes_empty(), value: stage2_bytes_empty())\n"
        APPEND "header)\nreturn 0\n}\n", APPEND, sizeof("stage2_list_append(") - 1, false);
    check_append("append-bare-element", HEADER "fn main() -> Int {\n" ITEMS ENTRY
        APPEND "header.name)\nreturn 0\n}\n", APPEND, sizeof(APPEND) - 1, false);
    check_append("append-straight-line", HEADER "fn main() -> Int {\n" ITEMS ENTRY
        "while true { " APPEND "header) }\nreturn 0\n}\n", APPEND, sizeof(APPEND) - 1, false);

    const char *shadow = POINT CONSUME "fn main() -> Int {\n" LOCAL
        "print(consume(point))\nif true {\n" LOCAL
        "print(point.x)\n}\nreturn 0\n}\n";
    char *hir = build_scope_hir(shadow);
    require_boundary(strncmp(hir, "error[", 6) != 0, "shadow HIR");
    int64_t moved = (int64_t)(strstr(shadow, "consume(point") - shadow) + 8;
    int64_t fresh = (int64_t)(strstr(shadow, "print(point.x)") - shadow) + 6;
    require_boundary(!move_same_binding(hir, moved, fresh), "binding-id");
    require_boundary(move_same_binding(hir, moved, moved), "same-binding-id");
    free(hir);
    /* The separate ownership-only wrapper is not the declaration/ABI pass. */
    (void)stage2_ownership_outcome;
    const char *edit = POINT
        "fn inspect(edit point: Point) -> Int { return point.x }\n"
        "fn main() -> Int {\n" LOCAL "return inspect(point)\n}\n";
    int64_t mode = (int64_t)(strstr(edit, "edit point") - edit);
    Stage2AuthorityContext context;
    Stage2AuthorityResult result;
    require_boundary(stage2_compile_outcome(edit, &context, &result), "record-edit compile outcome");
    require_boundary(result.exit_class == 1u && result.diagnostic != NULL &&
        context.diagnostic.present && context.diagnostic.has_byte_span &&
        !context.diagnostic.truncated && strcmp(context.diagnostic.code, "E2S181") == 0 &&
        context.diagnostic.start == mode && context.diagnostic.end == mode + 4 &&
        context.diagnostic.related_count == 0u && context.diagnostic.affected_count == 1u &&
        context.diagnostic.affected[0].kind == STAGE2_DIAGNOSTIC_AFFECTED_ERROR_SPAN &&
        strcmp(context.diagnostic.fallback, result.diagnostic) == 0, "structured-record-edit");
    stage2_authority_result_destroy(&result);
    puts("PASS: positional mode, direct resolution, bare binding, type/owner bounds, straight-line scope, BindingId exclusions, structured record-edit diagnostic and list-append element slot");
    return 0;
}
