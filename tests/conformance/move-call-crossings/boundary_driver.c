/* #1540. Component witnesses for exclusions that need not be accepted by the
 * complete backend (for example a lexical Int callable fed a record). HIR is
 * still built by the production scope resolver, never fabricated by the test. */
#define main kofun_compiler_entry
#ifndef KOFUN_MOVE_COMPILER
#define KOFUN_MOVE_COMPILER "compiler.c"
#endif
#include KOFUN_MOVE_COMPILER
#undef main

#define POINT "type Point = { x: Int }\n"
#define CONSUME "fn consume(take p: Point) -> Int { return p.x }\n"
#define LOCAL "let point: Point = Point(x: 1)\n"

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
    puts("PASS: positional mode, direct resolution, bare binding, type/owner bounds, straight-line scope and BindingId exclusions");
    return 0;
}
