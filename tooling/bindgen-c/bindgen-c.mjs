#!/usr/bin/env node
// kofun bindgen-c — stage 1 of #574.
//
// Generates, from one C header parsed by clang:
//
//   <path>/<name>.raw.kofun a module declaring its own path and
//                           `trust raw-foreign`, holding `pub extern "C"`
//                           declarations. The trust class is in the source
//                           because that is where an importer reads it: the
//                           `.raw.` filename segment is a convention and a
//                           rename does not change what the module is (#1217,
//                           RFC-0012);
//   <module>.bindgen.json   a machine-readable audit report: the complete
//                           interpretation context, per-declaration layout
//                           facts, and every skipped or review-required
//                           declaration with its reason.
//
// Guarantees this tool makes:
//   - clang is invoked through a structured argv (execFileSync, no shell);
//   - every clang subprocess carries an explicit deterministic wall-clock
//     timeout and a bounded captured stdout/stderr, so a header that makes
//     the preprocessor diverge or emit unbounded output is refused with a
//     stable nonzero diagnostic instead of hanging or exhausting memory;
//   - headers and the clang AST are treated as untrusted input: parsing is
//     bounded, nothing is eval'd, nothing from the header reaches a shell;
//   - the same inputs produce byte-identical outputs: declarations are
//     sorted, no timestamps are recorded, and paths under the working
//     directory are recorded relative to it;
//   - unsupported constructs never silently disappear — each lands in the
//     audit report with a reason;
//   - changing the interpretation context (target triple, standard, defines,
//     include paths, sysroot, header bytes) changes both output files, so a
//     stale artifact cannot be mistaken for a regenerated one.
//
// Guarantees this tool deliberately does NOT make: generated bindings are
// raw and trusted, not safe. Pointer ownership, thread affinity, callback
// duration, and error conventions are review items recorded as such.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const SCHEMA = 'kofun.bindgen-c.report/v1';

/*
 * Two names for one fact, and they are deliberately different (#1217).
 *
 * `TRUST_CLASS` is the value the *language* reads: it is the closed-set class
 * in `spec/modules/source-file-mapping.md`, written on the `trust` line of the
 * generated module, and it is what makes an ordinary import of this module a
 * refusal. `TRUST_MARKING` is the banner and report wording, which says what
 * the class means to a human reading the file.
 *
 * Before this the marking was the only one that existed, in a comment and a
 * JSON field — neither of which any compiler reads. RFC-0012's whole point is
 * that a class a rename can change is not a class.
 */
const TRUST_CLASS = 'raw-foreign';
const TRUST_MARKING = 'raw-trusted-foreign';

// Bounds. The c_abi profile caps come from bootstrap/c_abi/compiler.c and
// keep the generated module inside what the checked profile accepts.
//
// The clang bounds are the ones a hostile header can attack: expansion that
// does not terminate, expansion whose output does not fit in memory, and
// diagnostics that are themselves unbounded. Each is a fixed number, not a
// function of the input, so the same header always meets the same bound.
const MAX_AST_BYTES = 128 * 1024 * 1024;
const MAX_PREPROCESSED_BYTES = 64 * 1024 * 1024;
const CLANG_TIMEOUT_MS = 20000;
const MAX_DIAGNOSTIC_BYTES = 4096;
const MAX_TYPEDEF_DEPTH = 32;
const MAX_DECLS = 4096;
const MAX_IDENTIFIER = 128;
const CABI_MAX_STRUCTS = 16;
const CABI_MAX_FIELDS = 16;
const CABI_MAX_FUNCTIONS = 64;
const CABI_MAX_PARAMS = 16;

const SIMPLE_FUNCTION_ATTRIBUTE =
  /__attribute__\(\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\)/g;

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

/*
 * Where a declared module lives inside a package root: `a.b` at `a/b.kofun`,
 * plus the `.raw.` segment the generated file keeps. The segment is a
 * convention and carries no authority — the `trust` line does — which is
 * exactly why a renamed copy has to stay refused, and why that is a fixture
 * rather than a comment (#1217).
 */
function moduleFileName(options) {
  return `${options.moduleSegments.join('/')}.raw.kofun`;
}
const KOFUN_PRIMITIVES = new Set([
  'Unit', 'Bool', 'I8', 'I16', 'I32', 'I64', 'U8', 'U16', 'U32', 'U64',
  'F32', 'F64', 'CInt', 'CUInt', 'CLong', 'CULong', 'CSize', 'CStr', 'CBytes',
]);
const KOFUN_RESERVED = new Set([
  'fn', 'main', 'let', 'print', 'return', 'extern', 'repr', 'struct', 'type',
]);

// x86_64-linux LP64 scalar model, identical to bootstrap/c_abi/compiler.c
// type_size_alignment(). The ABI probe in the gate compares these numbers
// against the host C compiler's sizeof/alignof/offsetof.
const KOFUN_SCALARS = {
  Bool: { size: 1, alignment: 1 },
  I8: { size: 1, alignment: 1 },
  U8: { size: 1, alignment: 1 },
  I16: { size: 2, alignment: 2 },
  U16: { size: 2, alignment: 2 },
  I32: { size: 4, alignment: 4 },
  U32: { size: 4, alignment: 4 },
  F32: { size: 4, alignment: 4 },
  CInt: { size: 4, alignment: 4 },
  CUInt: { size: 4, alignment: 4 },
  I64: { size: 8, alignment: 8 },
  U64: { size: 8, alignment: 8 },
  F64: { size: 8, alignment: 8 },
  CLong: { size: 8, alignment: 8 },
  CULong: { size: 8, alignment: 8 },
  CSize: { size: 8, alignment: 8 },
  CStr: { size: 8, alignment: 8 },
  CBytes: { size: 8, alignment: 8 },
};

// Builtin C scalar spellings, LP64. `char` is signed on the pinned target.
const C_SCALARS = new Map([
  ['void', 'Unit'],
  ['_Bool', 'Bool'],
  ['bool', 'Bool'],
  ['char', 'I8'],
  ['signed char', 'I8'],
  ['unsigned char', 'U8'],
  ['short', 'I16'],
  ['short int', 'I16'],
  ['signed short', 'I16'],
  ['signed short int', 'I16'],
  ['unsigned short', 'U16'],
  ['unsigned short int', 'U16'],
  ['int', 'CInt'],
  ['signed int', 'CInt'],
  ['unsigned int', 'CUInt'],
  ['long', 'CLong'],
  ['long int', 'CLong'],
  ['signed long', 'CLong'],
  ['signed long int', 'CLong'],
  ['unsigned long', 'CULong'],
  ['unsigned long int', 'CULong'],
  ['long long', 'I64'],
  ['long long int', 'I64'],
  ['signed long long', 'I64'],
  ['signed long long int', 'I64'],
  ['unsigned long long', 'U64'],
  ['unsigned long long int', 'U64'],
  ['float', 'F32'],
  ['double', 'F64'],
]);

function fail(message) {
  process.stderr.write(`kofun bindgen-c: error: ${message}\n`);
  process.exit(2);
}

function usage() {
  process.stderr.write(
    'usage: kofun bindgen-c HEADER.h --out-dir DIR [--module NAME]\n' +
    '           [-D NAME[=VALUE]]... [-I DIR]... [--std STD]\n' +
    '           [--target TRIPLE] [--sysroot DIR] [--clang PATH]\n');
  process.exit(2);
}

function parseArguments(argv) {
  const options = {
    header: null,
    outDir: null,
    module: null,
    defines: [],
    includes: [],
    std: 'c11',
    target: null,
    sysroot: null,
    clang: 'clang',
  };
  let index = 0;
  const value = (flag) => {
    index += 1;
    if (index >= argv.length) fail(`${flag} needs a value`);
    return argv[index];
  };
  while (index < argv.length) {
    const argument = argv[index];
    if (argument === '--out-dir') options.outDir = value(argument);
    else if (argument === '--module') options.module = value(argument);
    else if (argument === '-D') options.defines.push(value(argument));
    else if (argument === '-I') options.includes.push(value(argument));
    else if (argument === '--std') options.std = value(argument);
    else if (argument === '--target') options.target = value(argument);
    else if (argument === '--sysroot') options.sysroot = value(argument);
    else if (argument === '--clang') options.clang = value(argument);
    else if (argument === '-h' || argument === '--help') usage();
    else if (argument.startsWith('-')) fail(`unknown option: ${argument}`);
    else if (options.header === null) options.header = argument;
    else fail(`exactly one header is expected, got also: ${argument}`);
    index += 1;
  }
  if (options.header === null) usage();
  if (options.outDir === null) fail('--out-dir is required');
  if (!options.header.endsWith('.h')) fail('the input must be a .h header');
  try {
    if (!statSync(options.header).isFile()) fail(`not a regular file: ${options.header}`);
  } catch {
    fail(`header not found: ${options.header}`);
  }
  for (const define of options.defines) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*(=[^\s]*)?$/.test(define)) {
      fail(`malformed -D define: ${define}`);
    }
  }
  if (!/^[a-z0-9+:]+$/.test(options.std)) fail(`malformed --std value: ${options.std}`);
  if (options.module === null) {
    const stem = path.basename(options.header, '.h').replace(/[^A-Za-z0-9_]/g, '_');
    options.module = IDENTIFIER.test(stem) ? stem : `m_${stem}`;
  }
  /*
   * A dotted module path, because the generated module now declares itself and
   * a declared module has a place in a package (#1217). Each segment is
   * validated separately rather than the whole string against one pattern: a
   * pattern permitting dots also permits `..`, `a..b` and a leading dot, and
   * every one of those becomes a directory traversal when the path is joined
   * to the output directory below.
   */
  options.moduleSegments = options.module.split('.');
  if (options.moduleSegments.some((segment) => !IDENTIFIER.test(segment))) {
    fail(
      'module path must be one or more identifiers separated by `.`: ' +
      options.module,
    );
  }
  return options;
}

// Record a path relative to the working directory when it is under it, so the
// outputs never embed one machine's directory layout. Paths outside the
// working directory are explicit user input and recorded as given.
function recordedPath(candidate) {
  const relative = path.relative(process.cwd(), path.resolve(candidate));
  if (relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative)) {
    return relative;
  }
  return candidate;
}

// Every clang subprocess goes through here, so every one of them is bounded
// the same way: a fixed wall-clock timeout, a fixed captured-output ceiling,
// and a truncated diagnostic. Nothing from the header reaches a shell; the
// argv is structured and stdin is closed.
//
// The three failure shapes are named separately because they are different
// defects: a timeout is expansion that does not terminate, an output-limit
// hit is expansion that does not fit, and a nonzero exit is clang refusing
// the input. All three exit 2 with a diagnostic that names the bound, and
// all three happen before the output directory exists, so a refused run
// leaves no partial artifact behind.
function runClang(clang, args, inputLabel, maxBytes = MAX_AST_BYTES) {
  try {
    return execFileSync(clang, args, {
      encoding: 'utf8',
      maxBuffer: maxBytes,
      timeout: CLANG_TIMEOUT_MS,
      killSignal: 'SIGKILL',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    if (error.code === 'ETIMEDOUT' || error.killed === true) {
      fail(`clang exceeded the ${CLANG_TIMEOUT_MS} ms bound on ${inputLabel}; ` +
        'the input was refused and nothing was generated');
    }
    if (error.code === 'ENOBUFS') {
      fail(`clang output exceeded the ${maxBytes} byte bound on ${inputLabel}; ` +
        'the input was refused and nothing was generated');
    }
    const detail = error.stderr
      ? String(error.stderr).slice(0, MAX_DIAGNOSTIC_BYTES)
      : String(error.message).slice(0, MAX_DIAGNOSTIC_BYTES);
    fail(`clang failed on ${inputLabel}:\n${detail}`);
    return '';
  }
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

// The checked C ABI compiler currently emits the platform-default C calling
// convention. Bindgen therefore accepts a declaration only when clang's
// function type resolves to that convention for the effective target. The
// absence of an attribute is evidence from the AST, not a guessed constant;
// the target mapping supplies the convention that "default" means.
function targetDefaultCallingConvention(targetTriple) {
  const target = targetTriple.toLowerCase();
  if (/^(x86_64|amd64)-/.test(target) && target.includes('-linux-')) {
    return {
      id: 'sysv-x86_64',
      name: 'System V AMD64',
      source: 'target-default',
      target_triple: targetTriple,
      clang_attribute: null,
    };
  }
  return null;
}

function classifyFunctionCallingConvention(prototype, targetDefault) {
  const attributes = [...prototype.matchAll(SIMPLE_FUNCTION_ATTRIBUTE)]
    .map((match) => match[1]);
  const unparsedAttributes = prototype
    .replace(SIMPLE_FUNCTION_ATTRIBUTE, '')
    .includes('__attribute__');
  if (unparsedAttributes) {
    return {
      unsupported: 'function type carries an unparsed clang attribute',
      reasonCode: 'unsupported-function-type-attribute',
      convention: null,
    };
  }

  const conventionAttributes = attributes.filter((attribute) =>
    attribute === 'sysv_abi' || attribute === 'ms_abi');
  const otherAttributes = attributes.filter((attribute) =>
    attribute !== 'sysv_abi' && attribute !== 'ms_abi');
  if (otherAttributes.length > 0) {
    return {
      unsupported: `function type attribute(s) ${otherAttributes.join(', ')} are not modeled`,
      reasonCode: 'unsupported-function-type-attribute',
      convention: null,
    };
  }
  if (conventionAttributes.length > 1) {
    return {
      unsupported: `multiple calling convention attributes are not modeled: ${conventionAttributes.join(', ')}`,
      reasonCode: 'ambiguous-calling-convention',
      convention: null,
    };
  }
  if (conventionAttributes.length === 0) {
    return { unsupported: null, reasonCode: null, convention: { ...targetDefault } };
  }

  const clangAttribute = conventionAttributes[0];
  const id = clangAttribute === 'sysv_abi' ? 'sysv-x86_64' : 'ms-x64';
  const convention = {
    id,
    name: clangAttribute === 'sysv_abi' ? 'System V AMD64' : 'Microsoft x64',
    source: 'clang-attribute',
    target_triple: targetDefault.target_triple,
    clang_attribute: clangAttribute,
  };
  if (id !== targetDefault.id) {
    return {
      unsupported: `calling convention ${id} from clang attribute ${clangAttribute} ` +
        `differs from checked target default ${targetDefault.id}`,
      reasonCode: 'unsupported-calling-convention',
      convention,
    };
  }
  return { unsupported: null, reasonCode: null, convention };
}

// ---------------------------------------------------------------- AST walk

// clang's JSON AST omits `loc.file` when it repeats the previous
// declaration's file, so the walker tracks the current file statefully.
function declarationFile(node, state) {
  const loc = node.loc || {};
  const spelled = loc.expansionLoc && loc.expansionLoc.file
    ? loc.expansionLoc.file
    : loc.file;
  if (typeof spelled === 'string') state.file = spelled;
  return state.file;
}

function qualType(node) {
  return node && node.type && typeof node.type.qualType === 'string'
    ? node.type.qualType
    : '';
}

// Evaluated value of an EnumConstantDecl: clang exposes it on the inner
// ConstantExpr. A missing value is reported, never guessed.
function enumConstantValue(node) {
  for (const inner of node.inner || []) {
    if (inner && inner.kind === 'ConstantExpr' && typeof inner.value === 'string') {
      return inner.value;
    }
  }
  return null;
}

function collectTranslationUnit(ast, mainFile) {
  if (!ast || ast.kind !== 'TranslationUnitDecl' || !Array.isArray(ast.inner)) {
    fail('clang did not produce a TranslationUnitDecl');
  }
  if (ast.inner.length > MAX_DECLS) {
    fail(`too many top-level declarations (limit ${MAX_DECLS})`);
  }
  const state = { file: '<none>' };
  const collected = [];
  for (const node of ast.inner) {
    if (!node || typeof node.kind !== 'string') continue;
    const file = declarationFile(node, state);
    if (node.isImplicit) continue;
    collected.push({ node, file, mainFile: file === mainFile });
  }
  return collected;
}

// ---------------------------------------------------------------- type map

function normalizeCType(spelling) {
  return spelling.replace(/\s+/g, ' ').trim();
}

function stripQualifiers(spelling) {
  let text = ` ${spelling} `;
  for (const qualifier of ['const', 'volatile', 'restrict', '_Atomic']) {
    text = text.split(` ${qualifier} `).join(' ');
  }
  return normalizeCType(text);
}

class TypeUniverse {
  constructor() {
    this.typedefs = new Map();      // name -> underlying qualType
    this.records = new Map();       // tag name -> record info
    this.enums = new Map();         // tag name -> enum info
    this.recordAliases = new Map(); // usable spelling -> tag name
    this.enumAliases = new Map();   // usable spelling -> tag name
  }

  resolveSpelling(spelling) {
    let current = normalizeCType(spelling);
    for (let depth = 0; depth < MAX_TYPEDEF_DEPTH; depth += 1) {
      const stripped = stripQualifiers(current);
      if (this.typedefs.has(stripped)) {
        current = normalizeCType(this.typedefs.get(stripped));
        continue;
      }
      return current;
    }
    return null; // typedef chain too deep — bounded, reported by the caller
  }
}

// Maps one C type spelling to the checked C ABI profile surface.
// Returns { kofun, note } or { unsupported: reason }.
function mapCType(spelling, universe, position) {
  const original = normalizeCType(spelling);
  const resolvedOrNull = universe.resolveSpelling(original);
  if (resolvedOrNull === null) {
    return { unsupported: `typedef chain deeper than ${MAX_TYPEDEF_DEPTH}` };
  }
  const resolved = stripQualifiers(resolvedOrNull);

  if (C_SCALARS.has(resolved)) {
    const kofun = C_SCALARS.get(resolved);
    if (kofun === 'Unit' && position !== 'result') {
      return { unsupported: 'void is only a result type' };
    }
    return { kofun, note: null };
  }
  if (resolved === 'long double') {
    return { unsupported: 'long double has no checked C ABI profile type' };
  }

  // Function pointers before general pointers: `R (*)(...)`.
  if (/\(\s*\*\s*\)/.test(resolved)) {
    return {
      kofun: 'CBytes',
      note: 'callback: function pointer lowered to untyped CBytes; ' +
        'invocation lifetime is a review item',
      review: 'callback-parameter',
    };
  }

  if (resolved.endsWith('*')) {
    const pointee = stripQualifiers(resolved.slice(0, -1));
    const constPointee = normalizeCType(resolvedOrNull.slice(0, resolvedOrNull.length - 1));
    if (resolved === 'const char *' || constPointee === 'const char') {
      return { kofun: 'CStr', note: 'const char *: read-only NUL-terminated view' };
    }
    if (pointee === 'void') {
      return {
        kofun: 'CBytes',
        note: 'void pointer lowered to CBytes',
        review: 'untyped-pointer',
      };
    }
    const resolvedPointee = universe.resolveSpelling(pointee);
    const recordTag = universe.recordAliases.get(
      resolvedPointee === null ? pointee : stripQualifiers(resolvedPointee));
    if (recordTag !== undefined) {
      const record = universe.records.get(recordTag);
      if (record && !record.complete) {
        return {
          kofun: 'CBytes',
          note: `opaque handle: struct ${recordTag} * lowered to untyped CBytes`,
          review: 'opaque-handle-pointer',
        };
      }
      return {
        kofun: 'CBytes',
        note: `pointer to struct ${recordTag} lowered to untyped CBytes`,
        review: 'record-pointer',
      };
    }
    return {
      kofun: 'CBytes',
      note: `pointer (${original}) lowered to untyped CBytes`,
      review: 'untyped-pointer',
    };
  }

  if (/\[\s*\d*\s*\]$/.test(resolved)) {
    return { unsupported: `array type ${original} has no checked C ABI profile type` };
  }

  const enumTag = universe.enumAliases.get(resolved);
  if (enumTag !== undefined) {
    const info = universe.enums.get(enumTag);
    if (info && info.unsupported) return { unsupported: info.unsupported };
    return {
      kofun: 'CInt',
      note: `enum ${enumTag} lowered to CInt; constants are recorded in the report`,
    };
  }

  const recordTag = universe.recordAliases.get(resolved);
  if (recordTag !== undefined) {
    const record = universe.records.get(recordTag);
    if (!record) return { unsupported: `unknown record ${resolved}` };
    if (record.unsupported) return { unsupported: record.unsupported };
    if (!record.complete) {
      return { unsupported: `opaque struct ${recordTag} cannot be passed by value` };
    }
    return { kofun: record.kofunName, record: recordTag, note: null };
  }

  return { unsupported: `no checked C ABI profile mapping for ${original}` };
}

// ---------------------------------------------------------------- main

function main() {
  const options = parseArguments(process.argv.slice(2));
  const headerAsPassed = options.header;
  const headerRecorded = recordedPath(headerAsPassed);

  const commonArgs = [];
  if (options.target !== null) commonArgs.push('--target', options.target);
  if (options.sysroot !== null) commonArgs.push('--sysroot', options.sysroot);
  commonArgs.push(`-std=${options.std}`);
  for (const define of options.defines) commonArgs.push('-D', define);
  for (const include of options.includes) commonArgs.push('-I', include);

  const clangVersion =
    runClang(options.clang, ['--version'], 'version query').split('\n')[0].trim();
  const targetTriple =
    runClang(options.clang, [...commonArgs, '-print-effective-triple'], 'triple query').trim();
  const targetDefaultConvention = targetDefaultCallingConvention(targetTriple);
  if (targetDefaultConvention === null) {
    fail(`effective target ${targetTriple} has no checked default calling convention; ` +
      'bindgen-c currently supports x86_64 Linux only');
  }

  const astText = runClang(
    options.clang,
    ['-Xclang', '-ast-dump=json', '-fsyntax-only', ...commonArgs, headerAsPassed],
    headerRecorded);
  if (astText.length > MAX_AST_BYTES) fail('clang AST output exceeds the size bound');
  let ast;
  try {
    ast = JSON.parse(astText);
  } catch (error) {
    fail(`clang AST is not parseable JSON: ${error.message}`);
  }

  const preprocessed = runClang(
    options.clang,
    ['-E', '-dD', ...commonArgs, headerAsPassed],
    headerRecorded,
    MAX_PREPROCESSED_BYTES);
  if (preprocessed.length > MAX_PREPROCESSED_BYTES) {
    fail('clang preprocessor output exceeds the size bound');
  }

  const declarations = collectTranslationUnit(ast, headerAsPassed);

  // ---------------------------------------------------------- first pass
  // Register every record, enum, and typedef (from any file) so that type
  // spellings resolve; only main-file declarations are emitted or audited.
  const universe = new TypeUniverse();
  const audit = [];
  const auditKeys = new Set();
  const report = (name, kind, category, reason, details = {}) => {
    const key = `${kind} ${name} ${reason}`;
    if (auditKeys.has(key)) return;
    auditKeys.add(key);
    audit.push({ name, kind, category, reason, ...details });
  };

  let anonymousCounter = 0;
  for (const { node, mainFile } of declarations) {
    const { kind } = node;
    if (kind === 'RecordDecl') {
      let tag = node.name;
      if (!tag) {
        anonymousCounter += 1;
        tag = `__kofun_anonymous_${anonymousCounter}`;
      }
      const existing = universe.records.get(tag);
      const complete = node.completeDefinition === true;
      if (existing && existing.complete && !complete) continue;
      const info = {
        tag,
        tagUsed: node.tagUsed || 'struct',
        complete,
        mainFile,
        node,
        kofunName: tag,
        anonymous: !node.name,
        unsupported: null,
      };
      if (info.tagUsed === 'union') {
        info.unsupported = `union ${tag} is not representable in the checked C ABI profile`;
      }
      universe.records.set(tag, info);
      universe.recordAliases.set(`${info.tagUsed} ${tag}`, tag);
      universe.recordAliases.set(tag, tag);
    } else if (kind === 'EnumDecl') {
      let tag = node.name;
      if (!tag) {
        anonymousCounter += 1;
        tag = `__kofun_anonymous_enum_${anonymousCounter}`;
      }
      const constants = [];
      let unsupported = null;
      for (const inner of node.inner || []) {
        if (!inner || inner.kind !== 'EnumConstantDecl') continue;
        const valueText = enumConstantValue(inner);
        if (valueText === null || !/^-?\d+$/.test(valueText)) {
          unsupported = `enum ${tag} constant ${inner.name} has no evaluated integer value`;
          continue;
        }
        const value = BigInt(valueText);
        if (value < -2147483648n || value > 2147483647n) {
          unsupported = `enum ${tag} constant ${inner.name} does not fit in a 32-bit int`;
        }
        constants.push({ name: inner.name, value: Number(value) });
      }
      if (node.fixedUnderlyingType) {
        unsupported = `enum ${tag} has a fixed underlying type, which is not modeled`;
      }
      const info = {
        tag,
        constants,
        mainFile,
        anonymous: !node.name,
        unsupported,
      };
      universe.enums.set(tag, info);
      universe.enumAliases.set(`enum ${tag}`, tag);
      universe.enumAliases.set(tag, tag);
    } else if (kind === 'TypedefDecl' && typeof node.name === 'string') {
      const underlying = qualType(node);
      if (underlying !== '') {
        universe.typedefs.set(node.name, underlying);
        const stripped = stripQualifiers(normalizeCType(underlying));
        const recordTag = universe.recordAliases.get(stripped);
        if (recordTag !== undefined) {
          universe.recordAliases.set(node.name, recordTag);
          const record = universe.records.get(recordTag);
          if (record && mainFile && record.mainFile && record.kofunName === recordTag) {
            record.kofunName = node.name; // prefer the first typedef alias
          }
        }
        const enumTag = universe.enumAliases.get(stripped);
        if (enumTag !== undefined) universe.enumAliases.set(node.name, enumTag);
      }
    }
  }

  // --------------------------------------------------------- second pass
  // Classify main-file declarations into emitted bindings and audit rows.
  const opaqueHandles = [];
  const records = [];
  const enums = [];
  const functions = [];
  const callbackTypedefs = [];

  const usableIdentifier = (name) =>
    typeof name === 'string' &&
    name.length <= MAX_IDENTIFIER &&
    IDENTIFIER.test(name) &&
    !KOFUN_PRIMITIVES.has(name) &&
    !KOFUN_RESERVED.has(name);

  for (const { node, mainFile } of declarations) {
    if (!mainFile) continue;
    const { kind } = node;

    if (kind === 'RecordDecl') {
      const tag = node.name;
      const info = tag ? universe.records.get(tag) : null;
      if (!info) {
        report(node.name || '<anonymous record>', 'record', 'skipped',
          'anonymous record declarations are not bound');
        continue;
      }
      if (info.tagUsed === 'union') {
        report(info.tag, 'union', 'skipped', info.unsupported);
        continue;
      }
      if (!info.complete) {
        // Opaque handle: named, layoutless, always behind a pointer.
        if (!opaqueHandles.some((handle) => handle.tag === info.tag)) {
          opaqueHandles.push(info);
        }
        continue;
      }
      // Field audit for complete structs.
      const fields = [];
      let unsupported = null;
      for (const inner of node.inner || []) {
        if (!inner || typeof inner.kind !== 'string') continue;
        if (inner.kind.endsWith('Attr')) {
          unsupported = `struct ${info.tag} carries an attribute that can change its layout`;
          continue;
        }
        if (inner.kind !== 'FieldDecl') continue;
        const fieldType = qualType(inner);
        if (inner.isBitfield) {
          unsupported = `struct ${info.tag} field ${inner.name} is a bitfield`;
          continue;
        }
        if (/\[\s*\]$/.test(fieldType)) {
          unsupported = `struct ${info.tag} field ${inner.name} is a flexible array member`;
          continue;
        }
        if (!usableIdentifier(inner.name)) {
          unsupported = `struct ${info.tag} field name is not usable in Kofun`;
          continue;
        }
        const mapped = mapCType(fieldType, universe, 'field');
        if (mapped.unsupported) {
          unsupported = `struct ${info.tag} field ${inner.name}: ${mapped.unsupported}`;
          continue;
        }
        if (mapped.review) {
          // Pointer fields would hide ownership inside a record; stage 1
          // refuses them rather than lowering them silently.
          unsupported = `struct ${info.tag} field ${inner.name} is a pointer; ` +
            'pointer-carrying records are a review item, not a binding';
          continue;
        }
        fields.push({ name: inner.name, cType: normalizeCType(fieldType), kofun: mapped.kofun });
      }
      if (unsupported === null && fields.length === 0) {
        unsupported = `struct ${info.tag} has no fields`;
      }
      if (unsupported === null && fields.length > CABI_MAX_FIELDS) {
        unsupported = `struct ${info.tag} exceeds the checked profile field limit (${CABI_MAX_FIELDS})`;
      }
      if (unsupported === null && !usableIdentifier(info.kofunName)) {
        unsupported = `struct ${info.tag} has no usable Kofun name`;
      }
      if (unsupported !== null) {
        info.unsupported = unsupported;
        const reasonKind = /bitfield/.test(unsupported) ? 'bitfield'
          : /flexible array/.test(unsupported) ? 'flexible-array-member'
            : 'record';
        report(info.tag, reasonKind, 'skipped', unsupported);
        continue;
      }
      info.fields = fields;
      if (!records.some((record) => record.tag === info.tag)) records.push(info);
    } else if (kind === 'EnumDecl') {
      const info = universe.enums.get(node.name || '');
      if (!info || info.anonymous) {
        report('<anonymous enum>', 'enum', 'skipped',
          'anonymous enums are recorded only through their constants; none are bound');
        continue;
      }
      if (info.unsupported) {
        report(info.tag, 'enum', 'skipped', info.unsupported);
        continue;
      }
      if (!enums.some((entry) => entry.tag === info.tag)) enums.push(info);
    } else if (kind === 'TypedefDecl') {
      const underlying = normalizeCType(qualType(node));
      if (/\(\s*\*\s*\)/.test(underlying)) {
        report(node.name, 'callback-typedef', 'review',
          `function-pointer typedef ${node.name} = ${underlying}; the callback's ` +
          'invocation lifetime and thread affinity are not machine-checked');
        callbackTypedefs.push({ name: node.name, cType: underlying });
      }
      // Scalar and record typedefs are resolved through the universe and
      // need no row of their own.
    } else if (kind === 'FunctionDecl') {
      const name = node.name;
      const prototype = qualType(node);
      if (!usableIdentifier(name)) {
        report(String(name), 'function', 'skipped',
          'function name collides with the Kofun binding surface');
        continue;
      }
      if (node.storageClass === 'static' || node.inline === true) {
        report(name, 'inline-function', 'skipped',
          'static/inline functions have no external symbol to bind');
        continue;
      }
      if (node.variadic === true) {
        report(name, 'variadic-function', 'skipped',
          'variadic functions are not representable in the checked C ABI profile');
        continue;
      }
      const callingConvention =
        classifyFunctionCallingConvention(prototype, targetDefaultConvention);
      if (callingConvention.unsupported !== null) {
        report(name, 'function', 'skipped', callingConvention.unsupported, {
          reason_code: callingConvention.reasonCode,
          ...(callingConvention.convention === null
            ? {}
            : { calling_convention: callingConvention.convention }),
        });
        continue;
      }
      if (/\(\s*\)\s*$/.test(prototype) && !prototype.endsWith('(void)')) {
        report(name, 'function', 'skipped',
          'function without a prototype has an unchecked parameter list');
        continue;
      }
      if (/^[^(]*\(\s*\*/.test(prototype)) {
        report(name, 'function', 'skipped',
          'nested declarator (function returning a function pointer) is not modeled');
        continue;
      }
      const parameters = [];
      const reviews = [];
      let unsupported = null;
      let parameterIndex = 0;
      for (const inner of node.inner || []) {
        if (!inner || inner.kind !== 'ParmVarDecl') continue;
        const spelledName = typeof inner.name === 'string' && usableIdentifier(inner.name)
          ? inner.name
          : `argument${parameterIndex}`;
        const parameterType = qualType(inner);
        const mapped = mapCType(parameterType, universe, 'parameter');
        if (mapped.unsupported) {
          unsupported = `parameter ${spelledName}: ${mapped.unsupported}`;
          break;
        }
        if (mapped.review) {
          reviews.push({
            reason: mapped.review,
            detail: `parameter ${spelledName} (${normalizeCType(parameterType)}): ${mapped.note}`,
          });
        }
        parameters.push({
          name: spelledName,
          cType: normalizeCType(parameterType),
          kofun: mapped.kofun,
          note: mapped.note,
        });
        parameterIndex += 1;
      }
      const resultSpelling = prototype.split('(')[0].trim();
      const mappedResult = unsupported === null
        ? mapCType(resultSpelling, universe, 'result')
        : null;
      if (unsupported === null && mappedResult.unsupported) {
        unsupported = `result: ${mappedResult.unsupported}`;
      }
      if (unsupported === null && parameters.length > CABI_MAX_PARAMS) {
        unsupported = `exceeds the checked profile parameter limit (${CABI_MAX_PARAMS})`;
      }
      if (unsupported !== null) {
        report(name, 'function', 'skipped', unsupported);
        continue;
      }
      if (mappedResult.review) {
        reviews.push({
          reason: mappedResult.review === 'callback-parameter'
            ? 'callback-result'
            : mappedResult.review,
          detail: `result (${resultSpelling}): ${mappedResult.note}`,
        });
      }
      const pointerResult = mappedResult.kofun === 'CBytes' || mappedResult.kofun === 'CStr';
      if (pointerResult || parameters.some((parameter) => parameter.kofun === 'CBytes')) {
        reviews.push({
          reason: 'ownership-unreviewed',
          detail: 'the header does not encode who allocates, who frees, or ' +
            'how long the pointer stays valid',
        });
      }
      for (const review of reviews) {
        report(name, 'function', 'review', `${review.reason}: ${review.detail}`);
      }
      functions.push({
        name,
        symbol: typeof node.mangledName === 'string' ? node.mangledName : name,
        prototype: normalizeCType(prototype),
        parameters,
        result: { cType: normalizeCType(resultSpelling), kofun: mappedResult.kofun },
        reviews,
        callingConvention: callingConvention.convention,
      });
    } else if (kind === 'VarDecl') {
      report(String(node.name), 'global-variable', 'skipped',
        'global variables are not representable in the checked C ABI profile');
    } else if (kind === 'EmptyDecl' || kind === 'StaticAssertDecl') {
      // Nothing to bind, nothing hidden.
    } else {
      report(String(node.name || kind), 'declaration', 'skipped',
        `unhandled declaration kind ${kind}`);
    }
  }

  // ------------------------------------------------------------- macros
  // Macros never reach the AST; they are collected from `clang -E -dD` and
  // always land in the report, never in the module.
  {
    const macroLines = preprocessed.split('\n');
    if (macroLines.length > 4 * MAX_DECLS * 64) fail('preprocessor output exceeds the line bound');
    let currentFile = '<none>';
    const seen = new Map();
    for (const line of macroLines) {
      const marker = line.match(/^#\s+\d+\s+"((?:[^"\\]|\\.)*)"/);
      if (marker) {
        currentFile = marker[1];
        continue;
      }
      const define = line.match(/^#define\s+([A-Za-z_][A-Za-z0-9_]*)(\(?)/);
      if (define && currentFile === headerAsPassed) {
        seen.set(define[1], define[2] === '(' ? 'function-like' : 'object-like');
      }
    }
    for (const [name, flavor] of [...seen.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
      report(name, 'macro', 'skipped',
        `${flavor} macro; macros carry no ABI and are not bound - re-express ` +
        'needed constants in a reviewed facade');
    }
  }

  // ------------------------------------------------------------- layout
  // Natural LP64 layout, computed exactly as bootstrap/c_abi/compiler.c
  // computes it; the gate's ABI probe compares it with the C compiler.
  const layoutRecords = [];
  const emittedRecords = [];
  {
    // Topological order (fields may name previously declared structs),
    // ties broken by name for determinism.
    const pending = [...records].sort((a, b) => (a.kofunName < b.kofunName ? -1 : 1));
    const placed = new Set();
    let progress = true;
    while (pending.length > 0 && progress) {
      progress = false;
      for (let index = 0; index < pending.length; index += 1) {
        const info = pending[index];
        const blocked = info.fields.some((field) =>
          !(field.kofun in KOFUN_SCALARS) && !placed.has(field.kofun));
        if (blocked) continue;
        pending.splice(index, 1);
        placed.add(info.kofunName);
        emittedRecords.push(info);
        progress = true;
        break;
      }
    }
    for (const info of pending) {
      report(info.tag, 'record', 'skipped',
        `struct ${info.tag} depends on a struct that was not bound`);
    }
  }
  while (emittedRecords.length > CABI_MAX_STRUCTS) {
    const dropped = emittedRecords.pop();
    report(dropped.tag, 'record', 'skipped',
      `exceeds the checked profile struct limit (${CABI_MAX_STRUCTS})`);
  }
  {
    const sizes = new Map();
    for (const info of emittedRecords) {
      let offset = 0;
      let alignment = 1;
      const fieldRows = [];
      for (const field of info.fields) {
        const scalar = KOFUN_SCALARS[field.kofun] || sizes.get(field.kofun);
        offset = Math.ceil(offset / scalar.alignment) * scalar.alignment;
        fieldRows.push({
          name: field.name,
          c_type: field.cType,
          kofun: field.kofun,
          offset,
          size: scalar.size,
          alignment: scalar.alignment,
        });
        offset += scalar.size;
        alignment = Math.max(alignment, scalar.alignment);
      }
      const size = Math.ceil(offset / alignment) * alignment;
      sizes.set(info.kofunName, { size, alignment });
      layoutRecords.push({
        name: info.kofunName,
        c_type: `${info.tagUsed} ${info.tag}`,
        size,
        alignment,
        fields: fieldRows,
      });
    }
  }

  const sortedFunctions = [...functions].sort((a, b) => (a.name < b.name ? -1 : 1));
  while (sortedFunctions.length > CABI_MAX_FUNCTIONS) {
    const dropped = sortedFunctions.pop();
    report(dropped.name, 'function', 'skipped',
      `exceeds the checked profile function limit (${CABI_MAX_FUNCTIONS})`);
  }
  const sortedOpaque = [...opaqueHandles].sort((a, b) => (a.tag < b.tag ? -1 : 1));
  const sortedEnums = [...enums].sort((a, b) => (a.tag < b.tag ? -1 : 1));
  const sortedCallbacks = [...callbackTypedefs].sort((a, b) => (a.name < b.name ? -1 : 1));
  audit.sort((a, b) => {
    if (a.name !== b.name) return a.name < b.name ? -1 : 1;
    if (a.kind !== b.kind) return a.kind < b.kind ? -1 : 1;
    return a.reason < b.reason ? -1 : 1;
  });

  // ------------------------------------------------------------- context
  const headerBytes = readFileSync(headerAsPassed);
  const context = {
    clang_version: clangVersion,
    target_triple: targetTriple,
    language_standard: options.std,
    defines: options.defines,
    include_paths: options.includes.map(recordedPath),
    sysroot: options.sysroot === null ? null : recordedPath(options.sysroot),
    headers: [{ path: headerRecorded, sha256: sha256(headerBytes) }],
  };
  const contextDigest = sha256(JSON.stringify(context));

  // ------------------------------------------------------------- module
  /*
   * `pub`, because a raw module exists to be consumed through a reviewed
   * facade and a declaration that is not `pub` cannot be (#1217). The
   * visibility is not a weakening: reaching this module at all requires
   * `trusted import`, which is the crossing RFC-0012 makes an author write.
   *
   * The report records the signature without it, because the report describes
   * the C binding — `pub` is a Kofun visibility, not part of the ABI, and a
   * consumer diffing signatures against a header should not see it.
   */
  const kofunSignature = (fn) => {
    const params = fn.parameters
      .map((parameter) => `${parameter.name}: ${parameter.kofun}`)
      .join(', ');
    return `extern "C" fn ${fn.name}(${params}) -> ${fn.result.kofun}`;
  };
  const kofunDeclaration = (fn) => `pub ${kofunSignature(fn)}`;

  const lines = [];
  const push = (text) => lines.push(text);
  /*
   * The declaration first, before the banner (#1217). A comment may precede a
   * module header and the compiler accepts either order; putting the header
   * first is what makes the class the first thing both a reader and a diff
   * see, and it is what RFC-0012's acceptance criterion asks for.
   */
  push(`module ${options.module}`);
  push(`trust ${TRUST_CLASS}`);
  push('');
  push(`# ${moduleFileName(options)} - GENERATED by \`kofun bindgen-c\`. DO NOT EDIT.`);
  push('#');
  push('# =====================================================================');
  push('#  RAW TRUSTED FOREIGN BINDINGS - NOT A SAFE INTERFACE');
  push(`#  trust: ${TRUST_MARKING} (module trust class \`${TRUST_CLASS}\`)`);
  push('# =====================================================================');
  push('#');
  push('# Every declaration below crosses the C ABI boundary exactly as clang');
  push('# parsed the header. Nothing here has been reviewed for pointer');
  push('# ownership, lifetime, thread affinity, callback duration, or error');
  push('# conventions; those remain open review items in the audit report.');
  push('# Import this module only behind a hand-reviewed safe facade.');
  push('#');
  push(`# audit report: ${options.moduleSegments[options.moduleSegments.length - 1]}.bindgen.json`);
  push('#');
  push('# interpretation context (changing any line below is a different ABI):');
  push(`#   clang:    ${clangVersion}`);
  push(`#   target:   ${targetTriple}`);
  push(`#   std:      ${options.std}`);
  push(`#   defines:  ${options.defines.length === 0 ? '(none)' : options.defines.join(' ')}`);
  push(`#   includes: ${context.include_paths.length === 0 ? '(none)' : context.include_paths.join(' ')}`);
  push(`#   sysroot:  ${context.sysroot === null ? '(default)' : context.sysroot}`);
  for (const header of context.headers) {
    push(`#   header:   ${header.path} sha256=${header.sha256}`);
  }
  push(`#   context-sha256: ${contextDigest}`);

  if (sortedOpaque.length > 0) {
    push('');
    push('# ---- opaque handles (no layout; always behind an untyped pointer) ----');
    for (const handle of sortedOpaque) {
      push(`# ${handle.tagUsed} ${handle.tag}: opaque; appears below as CBytes. The`);
      push('#   pointer is untyped at this boundary; nothing stops one handle type');
      push('#   being passed where another is expected. Review item.');
    }
  }

  if (sortedEnums.length > 0) {
    push('');
    push('# ---- enums (lowered to CInt; constants recorded, not bound) ----');
    for (const info of sortedEnums) {
      push(`# enum ${info.tag}:`);
      for (const constant of info.constants) {
        push(`#   ${constant.name} = ${constant.value}`);
      }
    }
  }

  if (sortedCallbacks.length > 0) {
    push('');
    push('# ---- callback typedefs (review items; lowered to CBytes at use) ----');
    for (const callback of sortedCallbacks) {
      push(`# ${callback.name} = ${callback.cType}`);
    }
  }

  for (const record of layoutRecords) {
    push('');
    push(`# ${record.c_type}: size ${record.size}, alignment ${record.alignment} (${targetTriple})`);
    push(`repr(C) struct ${record.name} {`);
    for (const field of record.fields) {
      push(`    ${field.name}: ${field.kofun},  # ${field.c_type} at offset ${field.offset}`);
    }
    push('}');
  }

  for (const fn of sortedFunctions) {
    push('');
    push(`# C: ${fn.prototype.replace(/ ?\(/, ` ${fn.name}(`)}`);
    push(`# ABI: ${fn.callingConvention.id} (${fn.callingConvention.source}; ` +
      `clang attribute: ${fn.callingConvention.clang_attribute || 'none'})`);
    for (const review of fn.reviews) {
      push(`# REVIEW ${review.reason}: ${review.detail}`);
    }
    push(kofunDeclaration(fn));
  }
  push('');
  const moduleText = lines.join('\n');

  // ------------------------------------------------------------- report
  const reportObject = {
    schema: SCHEMA,
    context: { ...context, context_sha256: contextDigest },
    module: {
      name: options.module,
      path: options.module,
      file: moduleFileName(options),
      trust: TRUST_MARKING,
      trust_class: TRUST_CLASS,
      language_profile: 'kofun C ABI profile (bootstrap/c_abi)',
      sha256: sha256(Buffer.from(moduleText, 'utf8')),
    },
    layout: {
      data_model: 'LP64',
      pointer: { size: 8, alignment: 8 },
      opaque_handles: sortedOpaque.map((handle) => ({
        name: handle.tag,
        c_type: `${handle.tagUsed} ${handle.tag}`,
        kofun: 'CBytes',
      })),
      enums: sortedEnums.map((info) => ({
        name: info.tag,
        c_type: `enum ${info.tag}`,
        kofun: 'CInt',
        size: 4,
        alignment: 4,
        constants: info.constants.map((constant) => ({
          name: constant.name,
          value: constant.value,
        })),
      })),
      records: layoutRecords,
      callbacks: sortedCallbacks.map((callback) => ({
        name: callback.name,
        c_type: callback.cType,
        kofun: 'CBytes',
      })),
      functions: sortedFunctions.map((fn) => ({
        name: fn.name,
        symbol: fn.symbol,
        calling_convention: fn.callingConvention,
        c_prototype: fn.prototype,
        kofun_signature: kofunSignature(fn),
        parameters: fn.parameters.map((parameter) => ({
          name: parameter.name,
          c_type: parameter.cType,
          kofun: parameter.kofun,
        })),
        result: { c_type: fn.result.cType, kofun: fn.result.kofun },
      })),
    },
    audit,
    counts: {
      bound_functions: sortedFunctions.length,
      bound_records: layoutRecords.length,
      opaque_handles: sortedOpaque.length,
      enums: sortedEnums.length,
      callback_typedefs: sortedCallbacks.length,
      audit_skipped: audit.filter((entry) => entry.category === 'skipped').length,
      audit_review: audit.filter((entry) => entry.category === 'review').length,
    },
  };

  mkdirSync(options.outDir, { recursive: true });
  /* The module path decides the directory, so a dotted path lands where a
   * package root expects to find it without the caller moving it (#1217). */
  const modulePath = path.join(options.outDir, moduleFileName(options));
  const reportPath = path.join(
    options.outDir,
    `${options.moduleSegments[options.moduleSegments.length - 1]}.bindgen.json`,
  );
  mkdirSync(path.dirname(modulePath), { recursive: true });
  writeFileSync(modulePath, moduleText, 'utf8');
  writeFileSync(reportPath, `${JSON.stringify(reportObject, null, 2)}\n`, 'utf8');
  process.stdout.write(`${recordedPath(modulePath)}\n${recordedPath(reportPath)}\n`);
}

main();
