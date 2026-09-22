// Bounded execution of the trusted Stage 2 compiler, pending its native
// self-compilation (#1483). Program text is data passed to compiler functions;
// it is never loaded as driver code. Only this driver binds private operations.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
export const bytes = text => Buffer.from(text, 'utf8').toString('latin1');
export const text = value => Buffer.from(value, 'latin1').toString('utf8');
export class HostOperationError extends Error {
  constructor(operation, kind) {
    super(`error[E2S35]: ${operation}: ${kind === 'lookup' ? 'file lookup failed before output open' : kind}`);
    this.operation = operation;
    this.kind = kind;
  }
}
export function scalarAt(value, offset) {
  const refuse = kind => { throw new HostOperationError('stage2_unicode_scalar_at', kind); };
  if (offset < 0n || offset > BigInt(value.length)) refuse('index');
  if (offset === BigInt(value.length)) refuse('end');
  const at = Number(offset), first = value.charCodeAt(at);
  if (first < 0x80) return BigInt(first);
  if (first < 0xc0) refuse('continuation');
  if (first < 0xc2) refuse('overlong');
  if (first >= 0xf5 && first <= 0xf7) refuse('range');
  if (first > 0xf7) refuse('malformed');
  const width = first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
  if (at + width > value.length) refuse('malformed');
  let scalar = first & (width === 2 ? 0x1f : width === 3 ? 0x0f : 7);
  for (let i = 1; i < width; i++) {
    const next = value.charCodeAt(at + i);
    if ((next & 0xc0) !== 0x80) refuse('malformed');
    scalar = (scalar << 6) | (next & 0x3f);
  }
  if (scalar < (width === 2 ? 0x80 : width === 3 ? 0x800 : 0x10000)) refuse('overlong');
  if (scalar >= 0xd800 && scalar <= 0xdfff) refuse('surrogate');
  if (scalar > 0x10ffff) refuse('range');
  return BigInt(scalar);
}
export function sameFile(left, right, stat = path => fs.statSync(text(path), { bigint: true })) {
  if (left === right) return 1n;
  let a, b;
  try { a = stat(left); }
  catch { throw new HostOperationError('stage2_same_file', 'lookup'); }
  try { b = stat(right); }
  catch (error) {
    if (error.code === 'ENOENT') return 0n;
    throw new HostOperationError('stage2_same_file', 'lookup');
  }
  return a.dev === b.dev && a.ino === b.ino ? 1n : 0n;
}

// A closed parser for the compiler's bootstrap subset. This is not a second
// Kofun frontend: it accepts only trusted function definitions with the
// statement/expression forms used by compiler.kofun, and refuses other syntax.
// Emitting JS closures once keeps the pair gate practical without a native
// self-compile or a handwritten copy of any compiler function under test.
function translate(source) {
  const tokens = [];
  const pattern = /\s+|#[^\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9]*|[0-9][0-9_]*|->|==|!=|<=|>=|&&|\|\||\/\/|\*\*|[{}()[\],:.=+*%<>!\-]/gy;
  let offset = 0;
  while (offset < source.length) {
    pattern.lastIndex = offset;
    const match = pattern.exec(source);
    if (!match) throw new Error(`unsupported trusted compiler syntax at ${offset}`);
    offset = pattern.lastIndex;
    if (!/^\s|^#/.test(match[0])) tokens.push(match[0]);
  }
  let at = 0;
  const peek = () => tokens[at];
  const take = token => {
    if (tokens[at] !== token) throw new Error(`trusted compiler: expected ${token}, got ${tokens[at]} at token ${at}`);
    at++;
  };
  const name = () => {
    const token = tokens[at++];
    if (!/^[A-Za-z_][A-Za-z_0-9]*$/.test(token)) throw new Error(`expected compiler binding, got ${token}`);
    return `$k_${token}`;
  };
  const skipType = stops => {
    let depth = 0;
    while (at < tokens.length && (depth || !stops.includes(peek()))) {
      if (peek() === '[' || peek() === '(') depth++;
      if (peek() === ']' || peek() === ')') depth--;
      at++;
    }
  };
  const precedence = new Map([['||',1],['&&',2],['==',3],['!=',3],['<',4],['<=',4],['>',4],['>=',4],['+',5],['-',5],['*',6],['//',6],['%',6]]);
  function expression(min = 0) {
    let value;
    const token = peek();
    if (token === 'if') {
      at++; const condition = expression().code; const yes = block(true); take('else');
      const no = block(true);
      value = { code: `(()=>{if(${condition})${yes}else${no}})()` };
    } else if (token === '!' || token === '-') {
      at++;
      const inner = expression(7).code;
      value = { code: token === '-' ? `$int(-(${inner}))` : `!(${inner})` };
    } else if (token === '(') {
      at++; value = expression(); take(')'); value = { code: `(${value.code})` };
    } else if (token === '[') {
      at++; const entries = [];
      while (peek() !== ']') { entries.push(expression().code); if (peek() !== ',') break; at++; }
      take(']'); value = { code: `[${entries.join(',')}]` };
    } else if (token?.startsWith('"')) {
      at++; value = { code: JSON.stringify(bytes(JSON.parse(token))) };
    } else if (/^[0-9]/.test(token)) {
      at++; value = { code: `${token.replaceAll('_','')}n` };
    } else if (token === 'true' || token === 'false') {
      at++; value = { code: token };
    } else {
      value = { code: name(), binding: true };
    }
    while (at < tokens.length) {
      if (peek() === '(') {
        at++; const args = [];
        while (peek() !== ')') { args.push(expression().code); if (peek() !== ',') break; at++; }
        take(')'); value = { code: `${value.code}(${args.join(',')})` };
      } else if (peek() === '[') {
        at++; const index = expression().code; take(']');
        value = { code: `$get(${value.code},${index})`, list: value.code, index };
      } else if (peek() === '.') {
        at++; const method = name().slice(3); take('('); const args = [value.code];
        while (peek() !== ')') { args.push(expression().code); if (peek() !== ',') break; at++; }
        take(')'); value = { code: `$bits.${method}(${args.join(',')})` };
      } else break;
    }
    while ((precedence.get(peek()) ?? -1) >= min) {
      const operator = tokens[at++];
      const right = expression(precedence.get(operator) + 1).code;
      const left = value.code;
      const helper = { '+':'$add', '-':'$sub', '*':'$mul', '//':'$div', '%':'$mod' }[operator];
      value = { code: helper ? `${helper}(${left},${right})` : `(${left} ${{'==':'===','!=':'!=='}[operator] ?? operator} ${right})` };
    }
    return value;
  }
  function block(tail = false) {
    take('{'); const statements = [];
    while (peek() !== '}') statements.push(statement());
    take('}');
    if (tail && statements.at(-1)?.expression) statements.at(-1).code = `return ${statements.at(-1).code}`;
    return `{${statements.map(s => s.code).join('\n')}}`;
  }
  function statement() {
    const token = peek();
    if (token === 'let') {
      at++; const mutable = peek() === 'mut'; if (mutable) at++;
      const binding = name(); if (peek() === ':') { at++; skipType(['=']); }
      take('='); return { code: `${mutable ? 'let' : 'const'} ${binding}=${expression().code};` };
    }
    if (token === 'if' || token === 'while') {
      at++; const condition = expression().code;
      let code = `${token}(${condition})${block()}`;
      if (token === 'if' && peek() === 'else') {
        at++; code += `else ${peek() === 'if' ? statement().code : block()}`;
      }
      return { code };
    }
    if (token === 'return') { at++; return { code: `return ${expression().code};` }; }
    if (token === 'break' || token === 'continue') { at++; return { code: `${token};` }; }
    const value = expression();
    if (peek() === '=') {
      at++; const assigned = expression().code;
      if (value.list) return { code: `$set(${value.list},${value.index},${assigned});` };
      if (!value.binding) throw new Error('invalid trusted assignment');
      return { code: `${value.code}=${assigned};` };
    }
    return { code: `${value.code};`, expression: true };
  }
  const functions = [], names = [];
  while (at < tokens.length) {
    take('fn'); const fn = name(); names.push(fn); take('('); const parameters = [];
    while (peek() !== ')') {
      parameters.push(name()); take(':'); skipType([',',')']);
      if (peek() !== ',') break; at++;
    }
    take(')'); if (peek() === '->') { at++; skipType(['{']); }
    functions.push(`function ${fn}(${parameters.join(',')})${block(true)}`);
  }
  return `${functions.join('\n')}\nreturn {${names.map(n => `${n.slice(3)}:${n}`).join(',')}};`;
}

function int(value) {
  if (value < -(1n << 63n) || value >= (1n << 63n)) throw new Error('compiler Int overflow');
  return value;
}
function div(a,b) { if (b === 0n) throw new Error('compiler division by zero'); const q = a/b, r = a%b; return int(r !== 0n && (r < 0n) !== (b < 0n) ? q-1n : q); }
function get(values,index) { if (index < 0n || index >= BigInt(values.length)) throw new Error('compiler index out of bounds'); return values[index]; }
const bitMask = width => { if (width < 1n || width > 64n) throw new Error('compiler bit width'); return (1n << width)-1n; };
const bits = {
  and:(a,b)=>int(a&b), or:(a,b)=>int(a|b), xor:(a,b)=>int(a^b), not:a=>int(~a),
  shl:(a,b)=>int(a<<b), shr:(a,b)=>a>>b,
  rotr:(a,b,w)=> { const x = a&bitMask(w), n = b%w; return ((x>>n)|(x<<(w-n)))&bitMask(w); },
  wrapping_add:(a,b,w)=>(a+b)&bitMask(w),
};

export function loadCompiler({ source = fs.readFileSync(`${root}bootstrap/stage2/compiler.kofun`, 'utf8'), argv = [], print = value => console.log(text(value)), stat, validate = () => { throw new Error('Unicode source validator is required for this driver command'); }, read = path => fs.readFileSync(text(path)).toString('latin1'), write = (path,value) => fs.writeFileSync(text(path), Buffer.from(value,'latin1')) } = {}) {
  const helpers = {
    $int:int, $add:(a,b)=>typeof a === 'string' && typeof b === 'string' ? a+b : int(a+b),
    $sub:(a,b)=>int(a-b), $mul:(a,b)=>int(a*b), $div:div, $mod:(a,b)=>a-div(a,b)*b,
    $get:get, $set:(a,i,v)=>{ get(a,i); a[i]=v; }, $bits:bits,
  };
  let compiler;
  const builtins = {
    len:value=>BigInt(value.length), chars:value=>value,
    text_slice:(value,start,end)=>{ start = start < 0n ? 0n : start; end = end < start ? start : end; return value.slice(Number(start),Number(end)); },
    contains:(value,part)=>value.includes(part), starts_with:(value,part)=>value.startsWith(part),
    find:(value,part)=>BigInt(value.indexOf(part)), replace:(value,old,replacement)=>value.replaceAll(old,replacement),
    trim:value=>value.replace(/^[ \t\r\n\v\f]+|[ \t\r\n\v\f]+$/g,''),
    is_digit:value=>/^[0-9]$/.test(value), is_space:value=>/^[ \t\r\n\v\f]$/.test(value),
    // Existing public byte classifier; scalar XID classification is in the
    // canonical compiler and uses its generated, pinned range tables.
    is_xid_continue:value=>{ try { return compiler.unicode_in_ranges(scalarAt(value,0n), compiler.unicode_xid_continue_ranges()); } catch (error) { if (error instanceof HostOperationError) return false; throw error; } },
    to_text:value=>String(value), print, args:()=>argv.map(bytes),
    read_text:read, write_text:write, validate_unicode_source:validate,
    fail:()=>{ throw new Error('compiler called fail'); },
    stage2_unicode_scalar_at:scalarAt, stage2_same_file:(a,b)=>sameFile(a,b,stat),
  };
  const bindings = { ...helpers, ...Object.fromEntries(Object.entries(builtins).map(([key,value])=>[`$k_${key}`,value])) };
  compiler = new Function(...Object.keys(bindings), `"use strict";\n${translate(source)}`)(...Object.values(bindings));
  return compiler;
}
