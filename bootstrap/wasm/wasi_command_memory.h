#ifndef KOFUN_WASM_WASI_COMMAND_MEMORY_H
#define KOFUN_WASM_WASI_COMMAND_MEMORY_H

/* wasm32-wasi-command1 command memory (#1297).
 *
 * The adapter-private storage the later WASI operations (#1298-#1301) hand to
 * `wasi_snapshot_preview1`: byte sequences, pointer vectors, iovec vectors, a
 * checked UTF-8 conversion, and the command-lifetime allocator they all come
 * from. None of it is the public Kofun `Bytes` identity and none of it is a
 * capability: a program still cannot reach a host operation in this slice, so
 * the production command module does not carry these functions. They are
 * emitted into the `--wasi-command1-memory-probe` module, where the gate
 * drives them under a real engine with canaries, and the operation slices
 * will emit the same bodies into a command module once a checked operation is
 * reachable. Emitting them unreferenced into every command today would make
 * the module's declared surface wider than its behaviour, which is exactly
 * what #1293's contract refuses.
 *
 * Layout. Every object reuses the AggregateLayout v1 header the hostabi1
 * profile already pins — one little-endian u64 at object offset zero, 8-byte
 * alignment — because the ownership contract matches: arena-owned, never
 * freed individually, never retained by the host. The difference from
 * hostabi1 Text is that a byte sequence's payload is arbitrary bytes, and the
 * two vector shapes are new:
 *
 *   bytes   { u64 length; u8 payload[length] }         size 8 + length
 *   vector  { u64 count;  u32 pointer[count] }         size 8 + 4 * count
 *   iovecs  { u64 count;  { u32 buf; u32 len }[count] } size 8 + 8 * count
 *
 * A Preview 1 call receives `object + 8` as its `argv`/`iovs` pointer and the
 * header value as its count, so nothing is copied to cross the boundary.
 *
 * Lifetime. One bump cursor, starting at the same 1 KiB reserve hostabi1
 * keeps, growing the single exported memory on demand up to the manifest's
 * page ceiling and never past it. `scope_enter`/`scope_leave` bracket one host
 * call: leaving zero-fills everything allocated inside the scope and moves the
 * cursor back, so a guest pointer retained past the call reads zeros rather
 * than the bytes it once pointed at, and the invariant "memory at or above the
 * cursor is zero" holds on every path — which is why a fresh object's payload
 * needs no fill. `alloc` itself never writes memory.
 *
 * Failure. Two kinds, kept apart on purpose. Running out of the ceiling is a
 * *resource* outcome: the function returns zero and nothing — cursor, memory
 * size, bytes — has changed. Violating the adapter contract (an alignment
 * that is not 1/2/4/8, an index past a vector's count, a reference that is
 * not an object, a scope mark outside the arena, a buffer outside the arena)
 * is a *trap*, per #1293 §6: adapter-contract violations trap and are never
 * dressed as diagnostics. Every trap fires before any mutation.
 *
 * The u32 arithmetic is done in i64. The page ceiling can be 65536 pages,
 * whose byte count does not fit an i32, and the top page is never handed out
 * so that no object's end can reach 2^32 and wrap to null.
 */

enum {
    WCM_ARENA_BASE = KOFUN_WASM_ARENA_BASE,
    WCM_HEADER_BYTES = KOFUN_WASM_OBJECT_HEADER_BYTES,
    WCM_OBJECT_ALIGN = 8,
    WCM_MAX_ALIGN = 8,
    WCM_POINTER_STRIDE = 4,
    WCM_IOVEC_STRIDE = 8,
    WCM_IOVEC_BUF_OFFSET = 0,
    WCM_IOVEC_LEN_OFFSET = 4,
    /* One page below the wasm32 maximum, so the ceiling in bytes and every
     * object end stay below 2^32. */
    WCM_MAX_USABLE_PAGES = 65535
};

/* The layout arithmetic the gate's C probe and the emitter share. It is the
 * *only* copy in C; the gate recomputes each value independently in
 * JavaScript and compares all three (probe, JavaScript, running module). */
static inline uint64_t wcm_bytes_size(uint64_t length) {
    return (uint64_t)WCM_HEADER_BYTES + length;
}

static inline uint64_t wcm_vector_size(uint64_t count) {
    return (uint64_t)WCM_HEADER_BYTES + (uint64_t)WCM_POINTER_STRIDE * count;
}

static inline uint64_t wcm_iovecs_size(uint64_t count) {
    return (uint64_t)WCM_HEADER_BYTES + (uint64_t)WCM_IOVEC_STRIDE * count;
}

static inline uint64_t wcm_ceiling_bytes(uint32_t pages) {
    uint64_t usable = pages > WCM_MAX_USABLE_PAGES ? WCM_MAX_USABLE_PAGES : pages;
    return usable * (uint64_t)KOFUN_WASM_PAGE_BYTES;
}

#ifdef KOFUN_WASM_WASI_COMMAND_MEMORY_EMITTER

/* Opcodes the profiles above did not need. */
enum {
    WCM_OP_BLOCK = 0x02,
    WCM_OP_LOOP = 0x03,
    WCM_OP_BR = 0x0c,
    WCM_OP_BR_IF = 0x0d,
    WCM_OP_LOCAL_TEE = 0x22,
    WCM_OP_I32_LOAD = 0x28,
    WCM_OP_I64_LOAD = 0x29,
    WCM_OP_I32_LOAD8_U = 0x2d,
    WCM_OP_I32_STORE = 0x36,
    WCM_OP_I64_STORE = 0x37,
    WCM_OP_I32_STORE8 = 0x3a,
    WCM_OP_MEMORY_SIZE = 0x3f,
    WCM_OP_MEMORY_GROW = 0x40,
    WCM_OP_I32_EQ = 0x46,
    WCM_OP_I32_LT_U = 0x49,
    WCM_OP_I32_GE_U = 0x4f,
    WCM_OP_I64_GT_U = 0x56,
    WCM_OP_I64_LE_U = 0x58,
    WCM_OP_I64_GE_U = 0x5a,
    WCM_OP_I32_MUL = 0x6c,
    WCM_OP_I64_SHR_U = 0x88,
    WCM_OP_I32_WRAP_I64 = 0xa7,
    WCM_OP_I64_EXTEND_I32_U = 0xad
};

/* Module-relative indices. The probe module declares exactly these, in this
 * order, and the export table below is derived from the same list so the two
 * cannot disagree. */
enum {
    WCM_GLOBAL_VERSION = 0,
    WCM_GLOBAL_CURSOR = 1,

    WCM_TYPE_VOID = 0,          /* () -> ()              */
    WCM_TYPE_I32_I32_I32 = 1,   /* (i32, i32) -> i32     */
    WCM_TYPE_I32_I32 = 2,       /* (i32) -> i32          */
    WCM_TYPE_VOID_I32 = 3,      /* () -> i32             */
    WCM_TYPE_I32_VOID = 4,      /* (i32) -> ()           */
    WCM_TYPE_I32X3_VOID = 5,    /* (i32, i32, i32) -> () */
    WCM_TYPE_I32X4_VOID = 6,    /* (i32 x4) -> ()        */
    WCM_TYPE_COUNT = 7,

    WCM_FUNC_START = 0,
    WCM_FUNC_ALLOC = 1,
    WCM_FUNC_SCOPE_ENTER = 2,
    WCM_FUNC_SCOPE_LEAVE = 3,
    WCM_FUNC_RANGE_CHECK = 4,
    WCM_FUNC_BYTES_ALLOC = 5,
    WCM_FUNC_VECTOR_ALLOC = 6,
    WCM_FUNC_VECTOR_SET = 7,
    WCM_FUNC_VECTOR_GET = 8,
    WCM_FUNC_IOVECS_ALLOC = 9,
    WCM_FUNC_IOVEC_SET = 10,
    WCM_FUNC_UTF8_CHECK = 11,
    WCM_FUNC_TEXT_FROM_BYTES = 12,
    WCM_FUNC_COUNT = 13
};

typedef struct {
    const char *name;
    int type;
} WcmFunction;

static const WcmFunction WCM_FUNCTIONS[WCM_FUNC_COUNT] = {
    { "_start", WCM_TYPE_VOID },
    { "kofun_wasi_alloc", WCM_TYPE_I32_I32_I32 },
    { "kofun_wasi_scope_enter", WCM_TYPE_VOID_I32 },
    { "kofun_wasi_scope_leave", WCM_TYPE_I32_VOID },
    { "kofun_wasi_range_check", WCM_TYPE_I32_I32_I32 },
    { "kofun_wasi_bytes_alloc", WCM_TYPE_I32_I32 },
    { "kofun_wasi_vector_alloc", WCM_TYPE_I32_I32 },
    { "kofun_wasi_vector_set", WCM_TYPE_I32X3_VOID },
    { "kofun_wasi_vector_get", WCM_TYPE_I32_I32_I32 },
    { "kofun_wasi_iovecs_alloc", WCM_TYPE_I32_I32 },
    { "kofun_wasi_iovec_set", WCM_TYPE_I32X4_VOID },
    { "kofun_wasi_utf8_check", WCM_TYPE_I32_I32_I32 },
    { "kofun_wasi_text_from_bytes", WCM_TYPE_I32_I32 }
};

/* Announced mutation seams, in the shape #1296's `write` seam established:
 * each one removes exactly one check, says so on stderr every time it is
 * used, and exists so the gate can show that the assertion guarding that
 * check fails for its own reason and no other. Never set outside the gate. */
typedef enum {
    WCM_FAULT_NONE,
    WCM_FAULT_ALIGN,        /* alloc accepts any alignment                 */
    WCM_FAULT_SCOPE_ZERO,   /* scope_leave moves the cursor without zeroing */
    WCM_FAULT_IOVEC_RANGE,  /* iovec_set forgets to range-check the buffer */
    WCM_FAULT_UTF8_OVERLONG /* utf8_check accepts 0xC0/0xC1 lead bytes     */
} WcmFault;

static WcmFault wcm_fault_from_environment(void) {
    const char *fault = getenv("KOFUN_WASM_CORE_FAULT");
    if (fault == NULL) return WCM_FAULT_NONE;
    WcmFault chosen = WCM_FAULT_NONE;
    if (strcmp(fault, "memory-align") == 0) chosen = WCM_FAULT_ALIGN;
    if (strcmp(fault, "memory-scope-zero") == 0) chosen = WCM_FAULT_SCOPE_ZERO;
    if (strcmp(fault, "memory-iovec-range") == 0) chosen = WCM_FAULT_IOVEC_RANGE;
    if (strcmp(fault, "memory-utf8-overlong") == 0) chosen = WCM_FAULT_UTF8_OVERLONG;
    if (chosen != WCM_FAULT_NONE) {
        fprintf(stderr,
                "NOTE: kofun wasm32: KOFUN_WASM_CORE_FAULT=%s is set; "
                "the command-memory runtime is emitted with that check removed\n",
                fault);
    }
    return chosen;
}

/* --- instruction helpers ------------------------------------------------ */

static void wcm_i32(Buffer *b, int64_t value) {
    byte(b, OP_I32_CONST);
    sleb(b, value);
}

static void wcm_i64(Buffer *b, int64_t value) {
    byte(b, OP_I64_CONST);
    sleb(b, value);
}

static void wcm_get(Buffer *b, uint32_t local) {
    instruction_index(b, OP_LOCAL_GET, local);
}

static void wcm_set(Buffer *b, uint32_t local) {
    instruction_index(b, OP_LOCAL_SET, local);
}

static void wcm_tee(Buffer *b, uint32_t local) {
    instruction_index(b, WCM_OP_LOCAL_TEE, local);
}

static void wcm_cursor_get(Buffer *b) {
    instruction_index(b, OP_GLOBAL_GET, WCM_GLOBAL_CURSOR);
}

static void wcm_cursor_set(Buffer *b) {
    instruction_index(b, OP_GLOBAL_SET, WCM_GLOBAL_CURSOR);
}

static void wcm_extend_u(Buffer *b) {
    byte(b, WCM_OP_I64_EXTEND_I32_U);
}

static void wcm_wrap(Buffer *b) {
    byte(b, WCM_OP_I32_WRAP_I64);
}

static void wcm_block(Buffer *b) {
    byte(b, WCM_OP_BLOCK);
    byte(b, 0x40);
}

static void wcm_loop(Buffer *b) {
    byte(b, WCM_OP_LOOP);
    byte(b, 0x40);
}

static void wcm_if(Buffer *b) {
    byte(b, OP_IF);
    byte(b, 0x40);
}

static void wcm_end(Buffer *b) {
    byte(b, OP_END);
}

static void wcm_br(Buffer *b, uint32_t depth) {
    instruction_index(b, WCM_OP_BR, depth);
}

static void wcm_br_if(Buffer *b, uint32_t depth) {
    instruction_index(b, WCM_OP_BR_IF, depth);
}

static void wcm_memory(Buffer *b, uint8_t opcode, uint32_t align_log2, uint32_t offset) {
    byte(b, opcode);
    uleb(b, align_log2);
    uleb(b, offset);
}

/* Consumes an i32 condition; traps when it is nonzero. */
static void wcm_trap_if(Buffer *b) {
    wcm_if(b);
    byte(b, OP_UNREACHABLE);
    wcm_end(b);
}

/* Consumes an i32 condition; returns i32 zero when it is nonzero. */
static void wcm_zero_if(Buffer *b) {
    wcm_if(b);
    wcm_i32(b, 0);
    byte(b, OP_RETURN);
    wcm_end(b);
}

static void wcm_return_local(Buffer *b, uint32_t local) {
    wcm_get(b, local);
    byte(b, OP_RETURN);
}

/* Local declarations: `i32_count` i32 locals followed by `i64_count` i64. */
static void wcm_locals(Buffer *b, uint32_t i32_count, uint32_t i64_count) {
    uint32_t groups = (i32_count != 0) + (i64_count != 0);
    uleb(b, groups);
    if (i32_count != 0) {
        uleb(b, i32_count);
        byte(b, 0x7f);
    }
    if (i64_count != 0) {
        uleb(b, i64_count);
        byte(b, 0x7e);
    }
}

/* Pushes i32 1 when [ptr, ptr + len) lies inside the allocated arena:
 * ptr >= base and, in i64, ptr + len <= cursor. A zero-length range at the
 * cursor is inside. */
static void wcm_push_range_ok(Buffer *b, uint32_t ptr, uint32_t len) {
    wcm_get(b, ptr);
    wcm_i32(b, WCM_ARENA_BASE);
    byte(b, WCM_OP_I32_GE_U);
    wcm_get(b, ptr);
    wcm_extend_u(b);
    wcm_get(b, len);
    wcm_extend_u(b);
    byte(b, OP_I64_ADD);
    wcm_cursor_get(b);
    wcm_extend_u(b);
    byte(b, WCM_OP_I64_LE_U);
    byte(b, OP_I32_AND);
}

/* Traps unless `ref` is an object: at or above the arena base, 8-aligned,
 * with its header inside the allocated arena. */
static void wcm_trap_unless_object(Buffer *b, uint32_t ref) {
    wcm_get(b, ref);
    wcm_i32(b, WCM_ARENA_BASE);
    byte(b, WCM_OP_I32_LT_U);
    wcm_get(b, ref);
    wcm_i32(b, WCM_OBJECT_ALIGN - 1);
    byte(b, OP_I32_AND);
    byte(b, OP_I32_OR);
    wcm_get(b, ref);
    wcm_extend_u(b);
    wcm_i64(b, WCM_HEADER_BYTES);
    byte(b, OP_I64_ADD);
    wcm_cursor_get(b);
    wcm_extend_u(b);
    byte(b, WCM_OP_I64_GT_U);
    byte(b, OP_I32_OR);
    wcm_trap_if(b);
}

/* Traps unless `index` (as u32) is below the u64 count in `ref`'s header. */
static void wcm_trap_unless_index(Buffer *b, uint32_t ref, uint32_t index) {
    wcm_get(b, index);
    wcm_extend_u(b);
    wcm_get(b, ref);
    wcm_memory(b, WCM_OP_I64_LOAD, 3, 0);
    byte(b, WCM_OP_I64_GE_U);
    wcm_trap_if(b);
}

/* Pushes ref + header + stride * index as i32. Inside an object the sum is
 * below the cursor, so i32 arithmetic cannot wrap here. */
static void wcm_push_element_address(Buffer *b, uint32_t ref, uint32_t index, int stride) {
    wcm_get(b, ref);
    wcm_get(b, index);
    wcm_i32(b, stride);
    byte(b, WCM_OP_I32_MUL);
    byte(b, OP_I32_ADD);
    wcm_i32(b, WCM_HEADER_BYTES);
    byte(b, OP_I32_ADD);
}

/* --- function bodies ---------------------------------------------------- */

/* kofun_wasi_alloc(size, align) -> i32
 *
 *   aligned = (cursor + align - 1) & -align      (i64)
 *   end     = aligned + size                     (i64)
 *   end > ceiling                -> 0, nothing changed
 *   pages(end) > memory.size     -> memory.grow, and -1 -> 0, nothing changed
 *   cursor = end; return aligned
 */
static Buffer wcm_alloc_body(uint64_t ceiling, WcmFault fault) {
    enum { SIZE = 0, ALIGN = 1, NEEDED = 2, ALIGNED = 3, END = 4 };
    Buffer b = {0};
    wcm_locals(&b, 1, 2);

    /* align is one of 1, 2, 4, 8: nonzero, a power of two, at most 8. */
    if (fault != WCM_FAULT_ALIGN) {
        wcm_get(&b, ALIGN);
        byte(&b, OP_I32_EQZ);
        wcm_get(&b, ALIGN);
        wcm_get(&b, ALIGN);
        wcm_i32(&b, 1);
        byte(&b, OP_I32_SUB);
        byte(&b, OP_I32_AND);
        byte(&b, OP_I32_OR);
        wcm_get(&b, ALIGN);
        wcm_i32(&b, WCM_MAX_ALIGN);
        byte(&b, OP_I32_GT_U);
        byte(&b, OP_I32_OR);
        wcm_trap_if(&b);
    }

    wcm_cursor_get(&b);
    wcm_extend_u(&b);
    wcm_get(&b, ALIGN);
    wcm_extend_u(&b);
    byte(&b, OP_I64_ADD);
    wcm_i64(&b, 1);
    byte(&b, OP_I64_SUB);
    wcm_i64(&b, 0);
    wcm_get(&b, ALIGN);
    wcm_extend_u(&b);
    byte(&b, OP_I64_SUB);
    byte(&b, OP_I64_AND);
    wcm_set(&b, ALIGNED);

    wcm_get(&b, ALIGNED);
    wcm_get(&b, SIZE);
    wcm_extend_u(&b);
    byte(&b, OP_I64_ADD);
    wcm_set(&b, END);

    /* The engine enforces the module's maximum too; this check is what
     * keeps the top page (65536 pages) out of reach, and what makes the
     * outcome a clean zero rather than a failed grow. */
    wcm_get(&b, END);
    wcm_i64(&b, (int64_t)ceiling);
    byte(&b, WCM_OP_I64_GT_U);
    wcm_zero_if(&b);

    /* needed pages = (end + 65535) >> 16; grow when above the current size. */
    wcm_get(&b, END);
    wcm_i64(&b, KOFUN_WASM_PAGE_BYTES - 1);
    byte(&b, OP_I64_ADD);
    wcm_i64(&b, 16);
    byte(&b, WCM_OP_I64_SHR_U);
    wcm_wrap(&b);
    wcm_set(&b, NEEDED);
    wcm_get(&b, NEEDED);
    byte(&b, WCM_OP_MEMORY_SIZE);
    byte(&b, 0x00);
    byte(&b, OP_I32_GT_U);
    wcm_if(&b);
    wcm_get(&b, NEEDED);
    byte(&b, WCM_OP_MEMORY_SIZE);
    byte(&b, 0x00);
    byte(&b, OP_I32_SUB);
    byte(&b, WCM_OP_MEMORY_GROW);
    byte(&b, 0x00);
    wcm_i32(&b, -1);
    byte(&b, WCM_OP_I32_EQ);
    wcm_zero_if(&b);
    wcm_end(&b);

    wcm_get(&b, END);
    wcm_wrap(&b);
    wcm_cursor_set(&b);
    wcm_get(&b, ALIGNED);
    wcm_wrap(&b);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_scope_enter() -> i32: the cursor, as the mark to leave with. */
static Buffer wcm_scope_enter_body(void) {
    Buffer b = {0};
    wcm_locals(&b, 0, 0);
    wcm_cursor_get(&b);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_scope_leave(mark): trap unless base <= mark <= cursor; zero
 * [mark, cursor); cursor = mark. */
static Buffer wcm_scope_leave_body(WcmFault fault) {
    enum { MARK = 0, AT = 1 };
    Buffer b = {0};
    wcm_locals(&b, 1, 0);

    wcm_get(&b, MARK);
    wcm_i32(&b, WCM_ARENA_BASE);
    byte(&b, WCM_OP_I32_LT_U);
    wcm_get(&b, MARK);
    wcm_cursor_get(&b);
    byte(&b, OP_I32_GT_U);
    byte(&b, OP_I32_OR);
    wcm_trap_if(&b);

    if (fault != WCM_FAULT_SCOPE_ZERO) {
        wcm_get(&b, MARK);
        wcm_set(&b, AT);
        wcm_block(&b);
        wcm_loop(&b);
        wcm_get(&b, AT);
        wcm_cursor_get(&b);
        byte(&b, WCM_OP_I32_GE_U);
        wcm_br_if(&b, 1);
        wcm_get(&b, AT);
        wcm_i32(&b, 0);
        wcm_memory(&b, WCM_OP_I32_STORE8, 0, 0);
        wcm_get(&b, AT);
        wcm_i32(&b, 1);
        byte(&b, OP_I32_ADD);
        wcm_set(&b, AT);
        wcm_br(&b, 0);
        wcm_end(&b);
        wcm_end(&b);
    }

    wcm_get(&b, MARK);
    wcm_cursor_set(&b);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_range_check(ptr, len) -> i32: 1 inside the allocated arena. */
static Buffer wcm_range_check_body(void) {
    Buffer b = {0};
    wcm_locals(&b, 0, 0);
    wcm_push_range_ok(&b, 0, 1);
    wcm_end(&b);
    return b;
}

/* The three object constructors share one shape:
 *   size = header + stride * count   (i64; above u32 -> 0)
 *   ref  = alloc(size, 8)            (0 -> 0)
 *   header(ref) = count; return ref
 * Only the header is written; the payload is zero by the arena invariant. */
static Buffer wcm_object_alloc_body(int stride) {
    enum { COUNT = 0, REF = 1, SIZE = 2 };
    Buffer b = {0};
    wcm_locals(&b, 1, 1);

    wcm_get(&b, COUNT);
    wcm_extend_u(&b);
    wcm_i64(&b, stride);
    byte(&b, OP_I64_MUL);
    wcm_i64(&b, WCM_HEADER_BYTES);
    byte(&b, OP_I64_ADD);
    wcm_set(&b, SIZE);
    wcm_get(&b, SIZE);
    wcm_i64(&b, INT64_C(0xffffffff));
    byte(&b, WCM_OP_I64_GT_U);
    wcm_zero_if(&b);

    wcm_get(&b, SIZE);
    wcm_wrap(&b);
    wcm_i32(&b, WCM_OBJECT_ALIGN);
    instruction_index(&b, OP_CALL, WCM_FUNC_ALLOC);
    wcm_tee(&b, REF);
    byte(&b, OP_I32_EQZ);
    wcm_zero_if(&b);

    wcm_get(&b, REF);
    wcm_get(&b, COUNT);
    wcm_extend_u(&b);
    wcm_memory(&b, WCM_OP_I64_STORE, 3, 0);
    wcm_return_local(&b, REF);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_vector_set(vec, index, pointer) */
static Buffer wcm_vector_set_body(void) {
    enum { VEC = 0, INDEX = 1, POINTER = 2 };
    Buffer b = {0};
    wcm_locals(&b, 0, 0);
    wcm_trap_unless_object(&b, VEC);
    wcm_trap_unless_index(&b, VEC, INDEX);
    wcm_push_element_address(&b, VEC, INDEX, WCM_POINTER_STRIDE);
    wcm_get(&b, POINTER);
    wcm_memory(&b, WCM_OP_I32_STORE, 2, 0);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_vector_get(vec, index) -> i32 */
static Buffer wcm_vector_get_body(void) {
    enum { VEC = 0, INDEX = 1 };
    Buffer b = {0};
    wcm_locals(&b, 0, 0);
    wcm_trap_unless_object(&b, VEC);
    wcm_trap_unless_index(&b, VEC, INDEX);
    wcm_push_element_address(&b, VEC, INDEX, WCM_POINTER_STRIDE);
    wcm_memory(&b, WCM_OP_I32_LOAD, 2, 0);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_iovec_set(vec, index, buf, len): the buffer must lie inside
 * the allocated arena, because it is about to be handed to the host. */
static Buffer wcm_iovec_set_body(WcmFault fault) {
    enum { VEC = 0, INDEX = 1, BUF = 2, LEN = 3, ADDRESS = 4 };
    Buffer b = {0};
    wcm_locals(&b, 1, 0);
    wcm_trap_unless_object(&b, VEC);
    wcm_trap_unless_index(&b, VEC, INDEX);
    if (fault != WCM_FAULT_IOVEC_RANGE) {
        wcm_push_range_ok(&b, BUF, LEN);
        byte(&b, OP_I32_EQZ);
        wcm_trap_if(&b);
    }
    wcm_push_element_address(&b, VEC, INDEX, WCM_IOVEC_STRIDE);
    wcm_set(&b, ADDRESS);
    wcm_get(&b, ADDRESS);
    wcm_get(&b, BUF);
    wcm_memory(&b, WCM_OP_I32_STORE, 2, WCM_IOVEC_BUF_OFFSET);
    wcm_get(&b, ADDRESS);
    wcm_get(&b, LEN);
    wcm_memory(&b, WCM_OP_I32_STORE, 2, WCM_IOVEC_LEN_OFFSET);
    wcm_end(&b);
    return b;
}

/* Pushes 1 when local `value` is in [low, high]. */
static void wcm_push_in_range(Buffer *b, uint32_t value, int low, int high) {
    wcm_get(b, value);
    wcm_i32(b, low);
    byte(b, WCM_OP_I32_GE_U);
    wcm_get(b, value);
    wcm_i32(b, high);
    byte(b, OP_I32_LE_S);
    byte(b, OP_I32_AND);
}

/* kofun_wasi_utf8_check(ptr, len) -> i32
 *
 * Traps unless the range is inside the arena. Returns `len` when every byte
 * is well-formed UTF-8 (RFC 3629: no overlong forms, no surrogates, nothing
 * above U+10FFFF), else the offset of the lead byte of the first ill-formed
 * sequence. Truncation at the end of the range counts as ill-formed at its
 * lead byte. */
static Buffer wcm_utf8_check_body(WcmFault fault) {
    enum { PTR = 0, LEN = 1, I = 2, B = 3, NEED = 4, LOW = 5, HIGH = 6, J = 7, C = 8 };
    Buffer b = {0};
    wcm_locals(&b, 7, 0);

    wcm_push_range_ok(&b, PTR, LEN);
    byte(&b, OP_I32_EQZ);
    wcm_trap_if(&b);

    wcm_i32(&b, 0);
    wcm_set(&b, I);
    wcm_block(&b);   /* depth 1 from inside the loop: done */
    wcm_loop(&b);    /* depth 0: next character */
    wcm_get(&b, I);
    wcm_get(&b, LEN);
    byte(&b, WCM_OP_I32_GE_U);
    wcm_br_if(&b, 1);

    wcm_get(&b, PTR);
    wcm_get(&b, I);
    byte(&b, OP_I32_ADD);
    wcm_memory(&b, WCM_OP_I32_LOAD8_U, 0, 0);
    wcm_set(&b, B);

    /* ASCII: one byte, next character. */
    wcm_get(&b, B);
    wcm_i32(&b, 0x80);
    byte(&b, WCM_OP_I32_LT_U);
    wcm_if(&b);
    wcm_get(&b, I);
    wcm_i32(&b, 1);
    byte(&b, OP_I32_ADD);
    wcm_set(&b, I);
    wcm_br(&b, 1);
    wcm_end(&b);

    /* Lead byte -> continuation count and the second byte's window. */
    wcm_i32(&b, 0x80);
    wcm_set(&b, LOW);
    wcm_i32(&b, 0xbf);
    wcm_set(&b, HIGH);
    wcm_i32(&b, 0);
    wcm_set(&b, NEED);

    int two_byte_low = fault == WCM_FAULT_UTF8_OVERLONG ? 0xc0 : 0xc2;
    wcm_push_in_range(&b, B, two_byte_low, 0xdf);
    wcm_if(&b);
    wcm_i32(&b, 1);
    wcm_set(&b, NEED);
    wcm_end(&b);

    wcm_get(&b, B);
    wcm_i32(&b, 0xe0);
    byte(&b, WCM_OP_I32_EQ);
    wcm_if(&b);
    wcm_i32(&b, 2);
    wcm_set(&b, NEED);
    wcm_i32(&b, 0xa0);
    wcm_set(&b, LOW);
    wcm_end(&b);

    wcm_push_in_range(&b, B, 0xe1, 0xec);
    wcm_push_in_range(&b, B, 0xee, 0xef);
    byte(&b, OP_I32_OR);
    wcm_if(&b);
    wcm_i32(&b, 2);
    wcm_set(&b, NEED);
    wcm_end(&b);

    wcm_get(&b, B);
    wcm_i32(&b, 0xed);
    byte(&b, WCM_OP_I32_EQ);
    wcm_if(&b);
    wcm_i32(&b, 2);
    wcm_set(&b, NEED);
    wcm_i32(&b, 0x9f);
    wcm_set(&b, HIGH);
    wcm_end(&b);

    wcm_get(&b, B);
    wcm_i32(&b, 0xf0);
    byte(&b, WCM_OP_I32_EQ);
    wcm_if(&b);
    wcm_i32(&b, 3);
    wcm_set(&b, NEED);
    wcm_i32(&b, 0x90);
    wcm_set(&b, LOW);
    wcm_end(&b);

    wcm_push_in_range(&b, B, 0xf1, 0xf3);
    wcm_if(&b);
    wcm_i32(&b, 3);
    wcm_set(&b, NEED);
    wcm_end(&b);

    wcm_get(&b, B);
    wcm_i32(&b, 0xf4);
    byte(&b, WCM_OP_I32_EQ);
    wcm_if(&b);
    wcm_i32(&b, 3);
    wcm_set(&b, NEED);
    wcm_i32(&b, 0x8f);
    wcm_set(&b, HIGH);
    wcm_end(&b);

    /* No lead matched: ill-formed here. */
    wcm_get(&b, NEED);
    byte(&b, OP_I32_EQZ);
    wcm_if(&b);
    wcm_return_local(&b, I);
    wcm_end(&b);

    /* Truncated: fewer than `need` bytes follow. len - i >= 1 here. */
    wcm_get(&b, LEN);
    wcm_get(&b, I);
    byte(&b, OP_I32_SUB);
    wcm_i32(&b, 1);
    byte(&b, OP_I32_SUB);
    wcm_get(&b, NEED);
    byte(&b, WCM_OP_I32_LT_U);
    wcm_if(&b);
    wcm_return_local(&b, I);
    wcm_end(&b);

    /* Second byte against its window. */
    wcm_get(&b, PTR);
    wcm_get(&b, I);
    byte(&b, OP_I32_ADD);
    wcm_memory(&b, WCM_OP_I32_LOAD8_U, 0, 1);
    wcm_set(&b, C);
    wcm_get(&b, C);
    wcm_get(&b, LOW);
    byte(&b, WCM_OP_I32_LT_U);
    wcm_get(&b, C);
    wcm_get(&b, HIGH);
    byte(&b, OP_I32_GT_U);
    byte(&b, OP_I32_OR);
    wcm_if(&b);
    wcm_return_local(&b, I);
    wcm_end(&b);

    /* Third and fourth bytes: plain continuations. */
    wcm_i32(&b, 2);
    wcm_set(&b, J);
    wcm_block(&b);
    wcm_loop(&b);
    wcm_get(&b, J);
    wcm_get(&b, NEED);
    byte(&b, OP_I32_GT_U);
    wcm_br_if(&b, 1);
    wcm_get(&b, PTR);
    wcm_get(&b, I);
    byte(&b, OP_I32_ADD);
    wcm_get(&b, J);
    byte(&b, OP_I32_ADD);
    wcm_memory(&b, WCM_OP_I32_LOAD8_U, 0, 0);
    wcm_set(&b, C);
    wcm_push_in_range(&b, C, 0x80, 0xbf);
    byte(&b, OP_I32_EQZ);
    wcm_if(&b);
    wcm_return_local(&b, I);
    wcm_end(&b);
    wcm_get(&b, J);
    wcm_i32(&b, 1);
    byte(&b, OP_I32_ADD);
    wcm_set(&b, J);
    wcm_br(&b, 0);
    wcm_end(&b);
    wcm_end(&b);

    wcm_get(&b, I);
    wcm_get(&b, NEED);
    byte(&b, OP_I32_ADD);
    wcm_i32(&b, 1);
    byte(&b, OP_I32_ADD);
    wcm_set(&b, I);
    wcm_br(&b, 0);
    wcm_end(&b);
    wcm_end(&b);

    wcm_return_local(&b, LEN);
    wcm_end(&b);
    return b;
}

/* kofun_wasi_text_from_bytes(ref) -> i32: the same reference when its
 * payload is well-formed UTF-8, else 0. Validation only; nothing is
 * allocated, copied, or written, so a refusal changes nothing. */
static Buffer wcm_text_from_bytes_body(void) {
    enum { REF = 0, LENGTH = 1 };
    Buffer b = {0};
    wcm_locals(&b, 1, 0);
    wcm_trap_unless_object(&b, REF);
    wcm_get(&b, REF);
    wcm_memory(&b, WCM_OP_I64_LOAD, 3, 0);
    wcm_wrap(&b);
    wcm_set(&b, LENGTH);
    wcm_get(&b, REF);
    wcm_i32(&b, WCM_HEADER_BYTES);
    byte(&b, OP_I32_ADD);
    wcm_get(&b, LENGTH);
    instruction_index(&b, OP_CALL, WCM_FUNC_UTF8_CHECK);
    wcm_get(&b, LENGTH);
    byte(&b, WCM_OP_I32_EQ);
    wcm_if(&b);
    wcm_return_local(&b, REF);
    wcm_end(&b);
    wcm_i32(&b, 0);
    wcm_end(&b);
    return b;
}

/* --- the probe module --------------------------------------------------- */

static void wcm_type(Buffer *types, int params, int results) {
    byte(types, 0x60);
    uleb(types, (uint64_t)params);
    for (int index = 0; index < params; ++index) byte(types, 0x7f);
    uleb(types, (uint64_t)results);
    for (int index = 0; index < results; ++index) byte(types, 0x7f);
}

static void wcm_append_body(Buffer *code, Buffer body) {
    uleb(code, body.length);
    bytes(code, body.data, body.length);
    free(body.data);
}

/* A wasm32-wasi-command1 module in every respect #1098's validator reads —
 * one exported memory, the version global, `_start`, no imports — with the
 * command-memory runtime exported beside them so the gate can drive it. It
 * is produced only by `--wasi-command1-memory-probe`, never by `build`. */
static Buffer emit_wasi_command_memory_probe_module(uint32_t pages) {
    WcmFault fault = wcm_fault_from_environment();
    uint64_t ceiling = wcm_ceiling_bytes(pages);
    Buffer module = {0};
    static const uint8_t header[] = {
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00
    };
    bytes(&module, header, sizeof(header));

    Buffer types = {0};
    uleb(&types, WCM_TYPE_COUNT);
    wcm_type(&types, 0, 0);
    wcm_type(&types, 2, 1);
    wcm_type(&types, 1, 1);
    wcm_type(&types, 0, 1);
    wcm_type(&types, 1, 0);
    wcm_type(&types, 3, 0);
    wcm_type(&types, 4, 0);
    section(&module, 1, &types);

    Buffer functions = {0};
    uleb(&functions, WCM_FUNC_COUNT);
    for (int index = 0; index < WCM_FUNC_COUNT; ++index) {
        uleb(&functions, (uint64_t)WCM_FUNCTIONS[index].type);
    }
    section(&module, 3, &functions);

    Buffer memory = {0};
    uleb(&memory, 1);
    byte(&memory, 0x01);
    uleb(&memory, 1);
    uleb(&memory, pages);
    section(&module, 5, &memory);

    Buffer globals = {0};
    uleb(&globals, 2);
    byte(&globals, 0x7f);
    byte(&globals, 0x00);
    byte(&globals, OP_I32_CONST);
    sleb(&globals, KOFUN_WASI_COMMAND_PROFILE_VERSION);
    byte(&globals, OP_END);
    byte(&globals, 0x7f);
    byte(&globals, 0x01);
    byte(&globals, OP_I32_CONST);
    sleb(&globals, WCM_ARENA_BASE);
    byte(&globals, OP_END);
    section(&module, 6, &globals);

    Buffer exports = {0};
    uleb(&exports, 2 + WCM_FUNC_COUNT);
    wasm_string(&exports, "memory");
    byte(&exports, 0x02);
    uleb(&exports, 0);
    wasm_string(&exports, "kofun_wasi_command_version");
    byte(&exports, 0x03);
    uleb(&exports, WCM_GLOBAL_VERSION);
    for (int index = 0; index < WCM_FUNC_COUNT; ++index) {
        wasm_string(&exports, WCM_FUNCTIONS[index].name);
        byte(&exports, 0x00);
        uleb(&exports, (uint64_t)index);
    }
    section(&module, 7, &exports);

    Buffer code = {0};
    uleb(&code, WCM_FUNC_COUNT);
    Buffer start = {0};
    uleb(&start, 0);
    byte(&start, OP_END);
    wcm_append_body(&code, start);
    wcm_append_body(&code, wcm_alloc_body(ceiling, fault));
    wcm_append_body(&code, wcm_scope_enter_body());
    wcm_append_body(&code, wcm_scope_leave_body(fault));
    wcm_append_body(&code, wcm_range_check_body());
    wcm_append_body(&code, wcm_object_alloc_body(1));
    wcm_append_body(&code, wcm_object_alloc_body(WCM_POINTER_STRIDE));
    wcm_append_body(&code, wcm_vector_set_body());
    wcm_append_body(&code, wcm_vector_get_body());
    wcm_append_body(&code, wcm_object_alloc_body(WCM_IOVEC_STRIDE));
    wcm_append_body(&code, wcm_iovec_set_body(fault));
    wcm_append_body(&code, wcm_utf8_check_body(fault));
    wcm_append_body(&code, wcm_text_from_bytes_body());
    section(&module, 10, &code);

    free(types.data);
    free(functions.data);
    free(memory.data);
    free(globals.data);
    free(exports.data);
    free(code.data);
    return module;
}

#endif /* KOFUN_WASM_WASI_COMMAND_MEMORY_EMITTER */

#endif
