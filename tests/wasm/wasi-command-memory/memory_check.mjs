#!/usr/bin/env node

// Drive #1297's command-memory runtime under a real engine.
//
//     node memory_check.mjs PROBE.wasm LAYOUT.txt PAGES
//
// Every property below executes the emitted functions against canary-filled
// memory and reads the bytes back; none of them inspects a constant the
// emitter wrote. Each property has one name, printed as `PASS: name` or thrown
// as `FAIL: name: reason`, and the gate runs mutated builds of the runtime to
// show that each removed check is caught by exactly the property that guards
// it — a property that also failed for some other reason would not be able to
// name what it found.
//
// The layout numbers are computed three ways: here from first principles, by
// the C probe from the header the emitter compiles against, and by the running
// module (allocation deltas, header bytes, element addresses). All three must
// agree.

import { readFileSync } from 'node:fs'

const [probePath, layoutPath, pagesText] = process.argv.slice(2)
if (!probePath || !layoutPath || !pagesText) {
    throw new Error('usage: memory_check.mjs PROBE.wasm LAYOUT.txt PAGES')
}
const PAGES = Number(pagesText)
const PAGE = 65536

// First principles, independent of both the header and the module.
const L = {
    arena_base: 1024,
    header_bytes: 8,
    object_align: 8,
    max_align: 8,
    pointer_stride: 4,
    iovec_stride: 8,
    iovec_buf_offset: 0,
    iovec_len_offset: 4,
    max_usable_pages: 65535,
}
const bytesSize = (n) => 8n + BigInt(n)
const vectorSize = (n) => 8n + 4n * BigInt(n)
const iovecsSize = (n) => 8n + 8n * BigInt(n)
const ceiling = (pages) => BigInt(Math.min(pages, 65535)) * 65536n

const bytes = readFileSync(probePath)
const compiled = new WebAssembly.Module(bytes)

const EXPORTS = [
    ['memory', 'memory'],
    ['kofun_wasi_command_version', 'global'],
    ['_start', 'function'],
    ['kofun_wasi_alloc', 'function'],
    ['kofun_wasi_scope_enter', 'function'],
    ['kofun_wasi_scope_leave', 'function'],
    ['kofun_wasi_range_check', 'function'],
    ['kofun_wasi_bytes_alloc', 'function'],
    ['kofun_wasi_vector_alloc', 'function'],
    ['kofun_wasi_vector_set', 'function'],
    ['kofun_wasi_vector_get', 'function'],
    ['kofun_wasi_iovecs_alloc', 'function'],
    ['kofun_wasi_iovec_set', 'function'],
    ['kofun_wasi_utf8_check', 'function'],
    ['kofun_wasi_text_from_bytes', 'function'],
]

function fail(name, reason) {
    throw new Error(`FAIL: ${name}: ${reason}`)
}

function fresh() {
    const instance = new WebAssembly.Instance(compiled, {})
    return instance.exports
}

function view(x) {
    return new Uint8Array(x.memory.buffer)
}

function u64(x, address) {
    return new DataView(x.memory.buffer).getBigUint64(address, true)
}

function u32(x, address) {
    return new DataView(x.memory.buffer).getUint32(address, true)
}

function cursor(x) {
    return x.kofun_wasi_scope_enter()
}

function traps(fn) {
    try {
        fn()
    } catch (error) {
        if (error instanceof WebAssembly.RuntimeError) return true
        throw error
    }
    return false
}

// A canary band above the cursor. The runtime's own invariant is that this
// region is zero; the gate breaks the invariant on purpose so that a write
// the runtime makes — or fails to make — shows up as a changed byte.
function canary(x, from, length, value = 0xa5) {
    view(x).fill(value, from, from + length)
    return Buffer.from(view(x).slice(from, from + length))
}

function same(x, from, expected) {
    return Buffer.from(view(x).slice(from, from + expected.length)).equals(expected)
}

const results = []
function property(name, body) {
    body()
    results.push(name)
    process.stdout.write(`PASS: ${name}\n`)
}

property('export-surface', () => {
    if (WebAssembly.Module.imports(compiled).length !== 0) {
        fail('export-surface', 'the probe imports something')
    }
    const actual = WebAssembly.Module.exports(compiled).map(({ name, kind }) => [name, kind])
    if (JSON.stringify(actual) !== JSON.stringify(EXPORTS)) {
        fail('export-surface', `exports are ${JSON.stringify(actual)}`)
    }
    const x = fresh()
    if (x.kofun_wasi_command_version.value !== 1) fail('export-surface', 'wrong profile version')
    if (x.memory.buffer.byteLength !== PAGE) fail('export-surface', 'initial memory is not one page')
    if (cursor(x) !== L.arena_base) fail('export-surface', `cursor starts at ${cursor(x)}`)
})

property('layout-agreement', () => {
    // The C probe's account of the header it was compiled against.
    const probe = new Map()
    const sizes = { bytes_size: new Map(), vector_size: new Map(), iovecs_size: new Map() }
    for (const line of readFileSync(layoutPath, 'utf8').trim().split('\n')) {
        const parts = line.split(' ')
        if (parts.length === 2) probe.set(parts[0], Number(parts[1]))
        else if (parts[0] === 'ceiling') probe.set('ceiling', [Number(parts[1]), BigInt(parts[2])])
        else sizes[parts[0]].set(parts[1], BigInt(parts[2]))
    }
    for (const [key, value] of Object.entries(L)) {
        if (probe.get(key) !== value) fail('layout-agreement', `${key}: probe ${probe.get(key)}, expected ${value}`)
    }
    const [probePages, probeCeiling] = probe.get('ceiling')
    if (probePages !== PAGES || probeCeiling !== ceiling(PAGES)) {
        fail('layout-agreement', `ceiling: probe ${probeCeiling} for ${probePages} pages, expected ${ceiling(PAGES)}`)
    }
    for (const [count, size] of sizes.bytes_size) {
        if (size !== bytesSize(count)) fail('layout-agreement', `bytes_size(${count}): probe ${size}`)
    }
    for (const [count, size] of sizes.vector_size) {
        if (size !== vectorSize(count)) fail('layout-agreement', `vector_size(${count}): probe ${size}`)
    }
    for (const [count, size] of sizes.iovecs_size) {
        if (size !== iovecsSize(count)) fail('layout-agreement', `iovecs_size(${count}): probe ${size}`)
    }

    // The running module's account: allocation deltas and header bytes.
    const x = fresh()
    for (const count of [0, 1, 7, 255, 4096]) {
        for (const [kind, alloc, size, stride] of [
            ['bytes', x.kofun_wasi_bytes_alloc, bytesSize, 1],
            ['vector', x.kofun_wasi_vector_alloc, vectorSize, L.pointer_stride],
            ['iovecs', x.kofun_wasi_iovecs_alloc, iovecsSize, L.iovec_stride],
        ]) {
            const before = cursor(x)
            const ref = alloc(count)
            if (ref === 0) fail('layout-agreement', `${kind}(${count}) exhausted at ${before}`)
            if (ref % L.object_align !== 0) fail('layout-agreement', `${kind}(${count}) at ${ref} is not 8-aligned`)
            if (ref < before) fail('layout-agreement', `${kind}(${count}) at ${ref} is below the cursor ${before}`)
            if (ref - before >= L.object_align) fail('layout-agreement', `${kind}(${count}) skipped ${ref - before} bytes`)
            if (BigInt(cursor(x) - ref) !== size(count)) {
                fail('layout-agreement', `${kind}(${count}) advanced ${cursor(x) - ref}, expected ${size(count)}`)
            }
            if (u64(x, ref) !== BigInt(count)) fail('layout-agreement', `${kind}(${count}) header reads ${u64(x, ref)}`)
            // Element addresses, read back through the runtime where it has a getter.
            if (kind === 'vector' && count > 0) {
                x.kofun_wasi_vector_set(ref, count - 1, 0x1234)
                if (u32(x, ref + L.header_bytes + stride * (count - 1)) !== 0x1234) {
                    fail('layout-agreement', `vector element ${count - 1} is not at header + ${stride} * index`)
                }
                if (x.kofun_wasi_vector_get(ref, count - 1) !== 0x1234) fail('layout-agreement', 'vector_get disagrees with the stored word')
            }
            if (kind === 'iovecs' && count > 0) {
                const buffer = x.kofun_wasi_bytes_alloc(3)
                x.kofun_wasi_iovec_set(ref, count - 1, buffer + 8, 3)
                const at = ref + L.header_bytes + stride * (count - 1)
                if (u32(x, at + L.iovec_buf_offset) !== buffer + 8 || u32(x, at + L.iovec_len_offset) !== 3) {
                    fail('layout-agreement', `iovec ${count - 1} is not {buf, len} at header + ${stride} * index`)
                }
            }
        }
    }
})

property('alloc-never-writes', () => {
    const x = fresh()
    const band = canary(x, cursor(x), 512)
    const start = cursor(x)
    for (const [size, align] of [[1, 1], [7, 2], [16, 4], [0, 8], [100, 8]]) {
        const ref = x.kofun_wasi_alloc(size, align)
        if (ref === 0) fail('alloc-never-writes', `alloc(${size}, ${align}) exhausted`)
    }
    if (!same(x, start, band)) fail('alloc-never-writes', 'alloc wrote into the canary band')
    // Object constructors write the header and nothing else.
    const beforeHeader = cursor(x)
    const ref = x.kofun_wasi_bytes_alloc(64)
    const expected = Buffer.from(band)
    // The band was written at `start`; compute what it should look like now:
    // unchanged except the 8 header bytes at `ref`.
    const now = Buffer.from(view(x).slice(start, start + 512))
    for (let i = 0; i < 512; i += 1) {
        const address = start + i
        const inHeader = address >= ref && address < ref + 8
        if (inHeader) continue
        if (now[i] !== expected[i]) fail('alloc-never-writes', `bytes_alloc wrote byte ${address} outside its header`)
    }
    if (u64(x, ref) !== 64n) fail('alloc-never-writes', 'bytes_alloc header is wrong')
    if (ref < beforeHeader) fail('alloc-never-writes', 'object below cursor')
})

property('alloc-alignment', () => {
    const x = fresh()
    x.kofun_wasi_alloc(1, 1)
    for (const align of [1, 2, 4, 8]) {
        const ref = x.kofun_wasi_alloc(3, align)
        if (ref % align !== 0) fail('alloc-alignment', `alloc(3, ${align}) returned ${ref}`)
    }
    // Alignment is rounding, not padding to a multiple: two 1-byte, 1-aligned
    // allocations are adjacent.
    const a = x.kofun_wasi_alloc(1, 1)
    const b = x.kofun_wasi_alloc(1, 1)
    if (b !== a + 1) fail('alloc-alignment', `1-aligned allocations are ${b - a} apart`)
    // Contract violations trap before any mutation.
    for (const align of [0, 3, 5, 6, 7, 16, 4096, -8]) {
        const before = cursor(x)
        const band = canary(x, before, 64)
        if (!traps(() => x.kofun_wasi_alloc(8, align))) fail('alloc-alignment', `alloc(8, ${align}) did not trap`)
        if (cursor(x) !== before) fail('alloc-alignment', `a trapped alloc moved the cursor`)
        if (!same(x, before, band)) fail('alloc-alignment', 'a trapped alloc wrote memory')
    }
})

property('growth-and-ceiling', () => {
    const x = fresh()
    if (PAGES < 3) fail('growth-and-ceiling', 'this property needs at least 3 pages')
    // Growth on demand, exactly as many pages as the end needs, zero-filled.
    const two = x.kofun_wasi_alloc(2 * PAGE, 8)
    if (two === 0) fail('growth-and-ceiling', 'a two-page allocation was refused')
    if (x.memory.buffer.byteLength !== 3 * PAGE) {
        fail('growth-and-ceiling', `memory is ${x.memory.buffer.byteLength / PAGE} pages after a two-page allocation from page one`)
    }
    if (view(x).subarray(two, two + 2 * PAGE).some((byte) => byte !== 0)) fail('growth-and-ceiling', 'grown memory is not zero')
    // Fill to the ceiling exactly, then one more byte is refused with nothing
    // changed: cursor, memory size, and the bytes below the cursor.
    const remaining = Number(ceiling(PAGES)) - cursor(x)
    const rest = x.kofun_wasi_alloc(remaining, 1)
    if (rest === 0) fail('growth-and-ceiling', `allocating the remaining ${remaining} bytes was refused`)
    if (cursor(x) !== Number(ceiling(PAGES))) fail('growth-and-ceiling', `cursor is ${cursor(x)} at the ceiling`)
    if (x.memory.buffer.byteLength !== PAGES * PAGE) fail('growth-and-ceiling', 'memory did not reach the ceiling')
    const pages = x.memory.buffer.byteLength
    const stamp = canary(x, 2048, 256, 0x5a)
    for (const [size, align] of [[1, 1], [8, 8], [PAGE, 1], [0xffffffff, 1], [-1, 8], [0x7fffffff, 4]]) {
        if (x.kofun_wasi_alloc(size, align) !== 0) fail('growth-and-ceiling', `alloc(${size}, ${align}) past the ceiling did not return 0`)
        if (cursor(x) !== Number(ceiling(PAGES))) fail('growth-and-ceiling', 'a refused alloc moved the cursor')
        if (x.memory.buffer.byteLength !== pages) fail('growth-and-ceiling', 'a refused alloc grew memory')
        if (!same(x, 2048, stamp)) fail('growth-and-ceiling', 'a refused alloc wrote memory')
        if (x.kofun_wasi_bytes_alloc(size) !== 0) fail('growth-and-ceiling', `bytes_alloc(${size}) past the ceiling did not return 0`)
    }
    // A zero-length allocation at the ceiling is inside it.
    if (x.kofun_wasi_alloc(0, 8) === 0) fail('growth-and-ceiling', 'a zero-length allocation at the ceiling was refused')
    // Sizes whose object would not fit a u32 are refused before allocation.
    const y = fresh()
    for (const count of [0xffffffff, 0xfffffff9, -1]) {
        for (const alloc of [y.kofun_wasi_bytes_alloc, y.kofun_wasi_vector_alloc, y.kofun_wasi_iovecs_alloc]) {
            if (alloc(count) !== 0) fail('growth-and-ceiling', `an object of count ${count} was allocated`)
            if (cursor(y) !== L.arena_base) fail('growth-and-ceiling', 'a refused object moved the cursor')
        }
    }
})

property('scope-lifetime', () => {
    const x = fresh()
    const outer = x.kofun_wasi_bytes_alloc(4)
    view(x).set([1, 2, 3, 4], outer + 8)
    const mark = x.kofun_wasi_scope_enter()
    if (mark !== cursor(x)) fail('scope-lifetime', 'scope_enter is not the cursor')
    const inner = x.kofun_wasi_bytes_alloc(16)
    const iov = x.kofun_wasi_iovecs_alloc(2)
    view(x).fill(0xee, inner + 8, inner + 24)
    x.kofun_wasi_iovec_set(iov, 0, inner + 8, 16)
    const end = cursor(x)
    const retained = { inner, iov }
    x.kofun_wasi_scope_leave(mark)
    if (cursor(x) !== mark) fail('scope-lifetime', `cursor is ${cursor(x)} after leaving, mark was ${mark}`)
    // A pointer retained past the call reads zeros, not the bytes it had.
    if (view(x).subarray(mark, end).some((byte) => byte !== 0)) {
        fail('scope-lifetime', 'memory allocated inside the scope still holds its bytes after leaving')
    }
    if (u64(x, retained.inner) !== 0n || u64(x, retained.iov) !== 0n) fail('scope-lifetime', 'retained object headers survived the scope')
    // Memory below the mark is untouched.
    if (!same(x, outer + 8, Buffer.from([1, 2, 3, 4]))) fail('scope-lifetime', 'scope_leave touched memory below the mark')
    if (u64(x, outer) !== 4n) fail('scope-lifetime', 'scope_leave touched the outer header')
    // A fresh allocation reuses the released region and sees zeros.
    const again = x.kofun_wasi_bytes_alloc(16)
    if (again !== inner) fail('scope-lifetime', 'the released region was not reused')
    if (view(x).subarray(again + 8, again + 24).some((byte) => byte !== 0)) fail('scope-lifetime', 'a reused region is not zero')
    // Leaving to the same mark twice, and to the cursor, is a no-op.
    x.kofun_wasi_scope_leave(cursor(x))
    if (cursor(x) !== again + 24) fail('scope-lifetime', 'leaving at the cursor moved it')
    // Marks outside [base, cursor] trap and change nothing.
    const before = cursor(x)
    const band = canary(x, before, 64)
    for (const bad of [0, L.arena_base - 1, before + 1, 0xffffffff, -1]) {
        if (!traps(() => x.kofun_wasi_scope_leave(bad))) fail('scope-lifetime', `scope_leave(${bad}) did not trap`)
        if (cursor(x) !== before) fail('scope-lifetime', 'a trapped scope_leave moved the cursor')
        if (!same(x, before, band)) fail('scope-lifetime', 'a trapped scope_leave wrote memory')
    }
    // Nested scopes unwind in order.
    const m1 = x.kofun_wasi_scope_enter()
    x.kofun_wasi_bytes_alloc(1)
    const m2 = x.kofun_wasi_scope_enter()
    x.kofun_wasi_bytes_alloc(1)
    x.kofun_wasi_scope_leave(m2)
    if (cursor(x) !== m2) fail('scope-lifetime', 'inner scope did not unwind to its mark')
    x.kofun_wasi_scope_leave(m1)
    if (cursor(x) !== m1) fail('scope-lifetime', 'outer scope did not unwind to its mark')
})

property('bytes-roundtrip', () => {
    const x = fresh()
    const fixtures = [
        ['empty', Buffer.alloc(0)],
        ['one', Buffer.from([0x00])],
        ['nul-and-ff', Buffer.from([0x00, 0xff, 0x00])],
        ['multibyte', Buffer.from('aé古🌍', 'utf8')],
        ['invalid-utf8', Buffer.from([0xc0, 0x80, 0xff, 0xfe])],
        ['page-minus-header', Buffer.alloc(PAGE - 8, 0x42)],
        ['page-plus-one', Buffer.alloc(PAGE + 1, 0x43)],
    ]
    for (const [name, payload] of fixtures) {
        const ref = x.kofun_wasi_bytes_alloc(payload.length)
        if (ref === 0) fail('bytes-roundtrip', `${name}: exhausted`)
        if (u64(x, ref) !== BigInt(payload.length)) fail('bytes-roundtrip', `${name}: header`)
        if (view(x).subarray(ref + 8, ref + 8 + payload.length).some((byte) => byte !== 0)) fail('bytes-roundtrip', `${name}: payload is not zero on allocation`)
        view(x).set(payload, ref + 8)
        if (!same(x, ref + 8, payload)) fail('bytes-roundtrip', `${name}: payload did not round-trip`)
        if (u64(x, ref) !== BigInt(payload.length)) fail('bytes-roundtrip', `${name}: header changed by the payload write`)
        if (x.kofun_wasi_range_check(ref + 8, payload.length) !== 1) fail('bytes-roundtrip', `${name}: payload range is not inside the arena`)
        // The object is the newest allocation, so one byte past its payload is
        // past the cursor.
        if (cursor(x) !== ref + 8 + payload.length) fail('bytes-roundtrip', `${name}: the cursor is not at the end of the object`)
        if (x.kofun_wasi_range_check(ref + 8, payload.length + 1) !== 0) fail('bytes-roundtrip', `${name}: one byte past the payload is inside the arena`)
    }
})

property('range-check', () => {
    const x = fresh()
    const ref = x.kofun_wasi_bytes_alloc(16)
    const top = cursor(x)
    const cases = [
        [ref + 8, 16, 1],
        [ref, 24, 1],
        [top, 0, 1],
        [L.arena_base, 0, 1],
        [L.arena_base - 1, 1, 0],
        [0, 0, 0],
        [top, 1, 0],
        [top - 1, 2, 0],
        [0xfffffff0, 0x20, 0],
        [ref + 8, 0xffffffff, 0],
        [-1, 1, 0],
    ]
    for (const [ptr, len, expected] of cases) {
        if (x.kofun_wasi_range_check(ptr, len) !== expected) fail('range-check', `range_check(${ptr}, ${len}) is not ${expected}`)
    }
})

property('vectors', () => {
    const x = fresh()
    const a = x.kofun_wasi_bytes_alloc(1)
    const b = x.kofun_wasi_bytes_alloc(2)
    const vec = x.kofun_wasi_vector_alloc(3)
    x.kofun_wasi_vector_set(vec, 0, a)
    x.kofun_wasi_vector_set(vec, 2, b)
    if (x.kofun_wasi_vector_get(vec, 0) !== a || x.kofun_wasi_vector_get(vec, 1) !== 0 || x.kofun_wasi_vector_get(vec, 2) !== b) {
        fail('vectors', 'vector elements did not round-trip')
    }
    // Read the way a Preview 1 host would read argv: a u32 table at +8.
    const table = new Uint32Array(x.memory.buffer, vec + 8, 3)
    if (table[0] !== a || table[1] !== 0 || table[2] !== b) fail('vectors', 'the u32 table at header + 8 disagrees with the getter')
    // Out-of-range indices trap; nothing changes.
    const snapshot = Buffer.from(view(x).slice(vec, vec + 20))
    const before = cursor(x)
    for (const index of [3, 4, 0xffffffff, -1]) {
        if (!traps(() => x.kofun_wasi_vector_set(vec, index, 7))) fail('vectors', `vector_set index ${index} did not trap`)
        if (!traps(() => x.kofun_wasi_vector_get(vec, index))) fail('vectors', `vector_get index ${index} did not trap`)
    }
    if (!same(x, vec, snapshot) || cursor(x) !== before) fail('vectors', 'a trapped vector access changed memory')
    // A reference that is not an object traps: below the base, misaligned,
    // at the cursor, past the cursor, and null.
    const empty = x.kofun_wasi_vector_alloc(0)
    for (const ref of [0, L.arena_base - 8, vec + 4, cursor(x), cursor(x) + 8, 0xfffffff8]) {
        if (!traps(() => x.kofun_wasi_vector_get(ref, 0))) fail('vectors', `vector_get on non-object ${ref} did not trap`)
    }
    if (!traps(() => x.kofun_wasi_vector_get(empty, 0))) fail('vectors', 'index 0 of an empty vector did not trap')
})

property('iovecs', () => {
    const x = fresh()
    const first = x.kofun_wasi_bytes_alloc(5)
    const second = x.kofun_wasi_bytes_alloc(0)
    const third = x.kofun_wasi_bytes_alloc(PAGE)
    view(x).set(Buffer.from('hello'), first + 8)
    const iov = x.kofun_wasi_iovecs_alloc(3)
    x.kofun_wasi_iovec_set(iov, 0, first + 8, 5)
    x.kofun_wasi_iovec_set(iov, 1, second + 8, 0)
    x.kofun_wasi_iovec_set(iov, 2, third + 8, PAGE)
    // Read the way fd_write would: a ciovec array at +8, count in the header.
    const words = new Uint32Array(x.memory.buffer, iov + 8, 6)
    const expected = [first + 8, 5, second + 8, 0, third + 8, PAGE]
    if (JSON.stringify(Array.from(words)) !== JSON.stringify(expected)) fail('iovecs', `ciovec array is ${Array.from(words)}`)
    if (u64(x, iov) !== 3n) fail('iovecs', 'iovec count header')
    const gathered = Buffer.concat(
        [0, 1, 2].map((i) => Buffer.from(view(x).slice(words[2 * i], words[2 * i] + words[2 * i + 1]))),
    )
    if (gathered.length !== 5 + PAGE || gathered.subarray(0, 5).toString() !== 'hello') fail('iovecs', 'gathering through the iovecs did not reproduce the payloads')
    // A buffer outside the allocated arena, or one whose end overflows, is
    // refused before the slot is written.
    const snapshot = Buffer.from(view(x).slice(iov, iov + 32))
    const top = cursor(x)
    const bad = [
        [top, 1], [top - 4, 8], [L.arena_base - 8, 4], [0, 4], [0xfffffff0, 0x20],
        [first + 8, 0xffffffff], [-1, 1], [first + 8, top],
    ]
    for (const [buf, len] of bad) {
        if (!traps(() => x.kofun_wasi_iovec_set(iov, 1, buf, len))) fail('iovecs', `iovec_set(${buf}, ${len}) outside the arena did not trap`)
    }
    if (!traps(() => x.kofun_wasi_iovec_set(iov, 3, first + 8, 1))) fail('iovecs', 'iovec index past the count did not trap')
    if (!traps(() => x.kofun_wasi_iovec_set(iov + 4, 0, first + 8, 1))) fail('iovecs', 'iovec_set on a misaligned reference did not trap')
    if (!traps(() => x.kofun_wasi_iovec_set(cursor(x), 0, first + 8, 1))) fail('iovecs', 'iovec_set on the cursor did not trap')
    if (!same(x, iov, snapshot) || cursor(x) !== top) fail('iovecs', 'a refused iovec_set changed memory')
    // Zero-length at the cursor is a valid, empty buffer.
    x.kofun_wasi_iovec_set(iov, 1, top, 0)
    if (u32(x, iov + 8 + 8) !== top || u32(x, iov + 8 + 12) !== 0) fail('iovecs', 'a zero-length iovec at the cursor was not stored')
})

property('utf8-conversion', () => {
    const x = fresh()
    const valid = [
        ['empty', []],
        ['ascii', Buffer.from('kofun')],
        ['two-byte', Buffer.from('é')],
        ['three-byte', Buffer.from('古')],
        ['four-byte', Buffer.from('🌍')],
        ['mixed', Buffer.from('aé古🌍 نَمَ')],
        ['boundaries', [0xc2, 0x80, 0xdf, 0xbf, 0xe0, 0xa0, 0x80, 0xed, 0x9f, 0xbf, 0xee, 0x80, 0x80, 0xef, 0xbf, 0xbf, 0xf0, 0x90, 0x80, 0x80, 0xf4, 0x8f, 0xbf, 0xbf]],
        ['nul-is-valid-utf8', [0x00, 0x41, 0x00]],
    ]
    for (const [name, payload] of valid) {
        const bytes = Buffer.from(payload)
        const ref = x.kofun_wasi_bytes_alloc(bytes.length)
        view(x).set(bytes, ref + 8)
        const verdict = x.kofun_wasi_utf8_check(ref + 8, bytes.length)
        if (verdict !== bytes.length) fail('utf8-conversion', `${name}: utf8_check reported ${verdict}, expected ${bytes.length}`)
        if (x.kofun_wasi_text_from_bytes(ref) !== ref) fail('utf8-conversion', `${name}: text_from_bytes refused valid UTF-8`)
    }
    // Ill-formed: the exact offset of the lead byte of the first bad sequence.
    const invalid = [
        ['overlong-2', [0x41, 0xc0, 0x80], 1],
        ['overlong-2b', [0xc1, 0xbf], 0],
        ['overlong-3', [0xe0, 0x80, 0x80], 0],
        ['overlong-3b', [0xe0, 0x9f, 0xbf], 0],
        ['overlong-4', [0xf0, 0x80, 0x80, 0x80], 0],
        ['overlong-4b', [0xf0, 0x8f, 0xbf, 0xbf], 0],
        ['surrogate', [0x41, 0x42, 0xed, 0xa0, 0x80], 2],
        ['surrogate-high', [0xed, 0xbf, 0xbf], 0],
        ['above-max', [0xf4, 0x90, 0x80, 0x80], 0],
        ['f5-lead', [0xf5, 0x80, 0x80, 0x80], 0],
        ['ff-lead', [0x41, 0xff], 1],
        ['stray-continuation', [0x80], 0],
        ['stray-continuation-late', [0x41, 0x42, 0x43, 0xbf], 3],
        ['truncated-2', [0xc3], 0],
        ['truncated-3', [0x41, 0xe2, 0x82], 1],
        ['truncated-4', [0xf0, 0x9f, 0x8c], 0],
        ['bad-continuation-2', [0xc3, 0x41], 0],
        ['bad-continuation-3', [0xe2, 0x82, 0x41], 0],
        ['bad-continuation-4', [0xf0, 0x9f, 0x8c, 0x41], 0],
        ['second-sequence', [0xc3, 0xa9, 0xe2, 0x82], 2],
    ]
    for (const [name, payload, offset] of invalid) {
        const bytes = Buffer.from(payload)
        const ref = x.kofun_wasi_bytes_alloc(bytes.length)
        view(x).set(bytes, ref + 8)
        const before = Buffer.from(view(x).slice(ref, ref + 8 + bytes.length))
        const verdict = x.kofun_wasi_utf8_check(ref + 8, bytes.length)
        if (verdict !== offset) fail('utf8-conversion', `${name}: utf8_check reported ${verdict}, expected ${offset}`)
        if (x.kofun_wasi_text_from_bytes(ref) !== 0) fail('utf8-conversion', `${name}: text_from_bytes accepted ill-formed UTF-8`)
        if (!same(x, ref, before)) fail('utf8-conversion', `${name}: a refused conversion changed the object`)
    }
    // Node's own decoder agrees on every fixture, so the verdicts above are
    // not this file's private opinion of UTF-8.
    const strict = new TextDecoder('utf-8', { fatal: true })
    for (const [name, payload] of valid) {
        try { strict.decode(Buffer.from(payload)) } catch { fail('utf8-conversion', `${name}: the reference decoder refuses a fixture this gate calls valid`) }
    }
    for (const [name, payload] of invalid) {
        let accepted = true
        try { strict.decode(Buffer.from(payload)) } catch { accepted = false }
        if (accepted) fail('utf8-conversion', `${name}: the reference decoder accepts a fixture this gate calls ill-formed`)
    }
    // Ranges outside the arena trap rather than read.
    const top = cursor(x)
    for (const [ptr, len] of [[top, 1], [0, 4], [L.arena_base - 1, 2], [top - 1, 2], [0xfffffff0, 0x20]]) {
        if (!traps(() => x.kofun_wasi_utf8_check(ptr, len))) fail('utf8-conversion', `utf8_check(${ptr}, ${len}) outside the arena did not trap`)
    }
    for (const ref of [0, top, top + 8, L.arena_base + 4]) {
        if (!traps(() => x.kofun_wasi_text_from_bytes(ref))) fail('utf8-conversion', `text_from_bytes(${ref}) on a non-object did not trap`)
    }
})

property('determinism', () => {
    // Two instances, the same sequence, the same observations and bytes.
    const script = (x) => {
        const out = []
        const a = x.kofun_wasi_bytes_alloc(9)
        view(x).set(Buffer.from('kofun-wasi'), a + 8)
        const v = x.kofun_wasi_vector_alloc(2)
        x.kofun_wasi_vector_set(v, 1, a)
        const mark = x.kofun_wasi_scope_enter()
        const io = x.kofun_wasi_iovecs_alloc(1)
        x.kofun_wasi_iovec_set(io, 0, a + 8, 9)
        out.push(a, v, mark, io, x.kofun_wasi_utf8_check(a + 8, 9), x.kofun_wasi_text_from_bytes(a))
        x.kofun_wasi_scope_leave(mark)
        out.push(cursor(x), x.kofun_wasi_alloc(2 * PAGE, 8), x.memory.buffer.byteLength)
        return [out, Buffer.from(view(x).slice(0, 4096))]
    }
    const [firstOut, firstBytes] = script(fresh())
    const [secondOut, secondBytes] = script(fresh())
    if (JSON.stringify(firstOut) !== JSON.stringify(secondOut)) fail('determinism', `observations differ: ${firstOut} vs ${secondOut}`)
    if (!firstBytes.equals(secondBytes)) fail('determinism', 'memory bytes differ between two identical runs')
})

process.stdout.write(`PASS: ${results.length} command-memory properties hold under the engine\n`)
