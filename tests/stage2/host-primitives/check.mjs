import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { loadCompiler, bytes, text, scalarAt, sameFile, HostOperationError } from '../../../bootstrap/stage2/host-driver.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));
fs.mkdirSync(path.join(root, 'build'), {recursive:true});
const work = fs.mkdtempSync(path.join(root, 'build/host-primitives-'));
const pairPath = path.join(root, 'bootstrap/stage2/compiler.kofun');
const cPath = path.join(root, 'bootstrap/stage2/compiler.c');
const pairSource = fs.readFileSync(pairPath,'utf8');
const cSource = fs.readFileSync(cPath,'utf8');
const fixture = JSON.parse(fs.readFileSync(new URL('./cases.json', import.meta.url),'utf8'));
assert.equal(fixture.schema, 'kofun.stage2-host-operation-fixture/v1');
const covered = new Set(fixture.cases.flatMap(test=>test.covers));
for (const funnel of ['function-prototype','function-body','function-reference','direct-call','parameter','local-binding','constant-declaration','constant-reference','constant-argument','function-value-argument','fixed-slot-call','labelled-parameter','record-type','record-field','record-field-reference','record-parameter','record-return','two-byte-scalar','three-byte-scalar','four-byte-scalar','mixed-ascii-name','combining-continue','ordinary-shadowing','const-record-specialization']) assert(covered.has(funnel), `missing funnel: ${funnel}`);
function run(command,args,options={}) {
  const result = spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:16*1024*1024,...options});
  if (result.error) throw result.error;
  return result;
}
function buildNative(name, source) {
  const binary = path.join(work,name);
  const args=['-std=c11','-O0','-Wall','-Wextra','-Werror','-pedantic','-I',path.join(root,'bootstrap/stage2')];
  if (source !== undefined) {
    const input=path.join(work,`${name}.c`);fs.writeFileSync(input,source);
    args.push(`-DKOFUN_PAIR_COMPILER=${JSON.stringify(input)}`);
  }
  const result=run(process.env.CC || 'cc',[...args,'tests/stage2/host-primitives/driver.c','-o',binary]);
  assert.equal(result.status,0,`native fixture must build: ${result.stderr}`);
  return binary;
}
const native = buildNative('native');
const compiler = loadCompiler();
// The driver must preserve the compiler's Int/list semantics too. Exercise
// the canonical SHA-256 functions against the maintained C vectors.
let shaOutput='';
const shaCompiler=loadCompiler({print:value=>{shaOutput+=text(value)+'\n';}});
assert.equal(shaCompiler.sha256_selftest(),0n);
const shaReference=run(native,['--sha256-selftest']);
assert.equal(shaReference.status,0);assert.equal(shaOutput,shaReference.stdout);
function nativeLower(binary,test) {
  const input=path.join(work,`${test.name}.kofun`);fs.writeFileSync(input,test.source);
  const result=run(binary,['--pair-lower',input]);
  assert.equal(result.status,0,result.stderr);
  return result.stdout;
}
function kofunLower(side,test) {
  const source=bytes(test.source), hir=side.build_scope_hir(source);
  return text(hir).startsWith('error[') ? text(hir) : text(side.lower_c(source,hir));
}
const expected = new Map();
for(const test of fixture.cases) {
  const output=nativeLower(native,test);
  assert(!output.startsWith('error['),`${test.name}: ${output}`);
  assert.equal(kofunLower(compiler,test),output,`complete C output: ${test.name}`);
  expected.set(test.name,output);
  const input=path.join(work,`${test.name}.kofun`);
  const validation=run(native,['--pair-validate',input]);
  assert.equal(validation.status,0);assert.equal(validation.stdout,'',`valid Unicode fixture: ${test.name}`);
  const emitted=path.join(work,`${test.name}.c`), binary=path.join(work,test.name);
  fs.writeFileSync(emitted,output);
  const build=run(process.env.CC || 'cc',['-std=c11','-Wall','-Wextra','-Werror','-pedantic',emitted,'-o',binary]);
  assert.equal(build.status,0,`${test.name}: ${build.stderr}`);
  const execution=run(binary,[]);assert.equal(execution.status,0);assert.equal(execution.stdout,test.output);
}
console.log(`PASS: ${covered.size} identifier funnels, byte-identical C and strict C11 execution in both halves`);

// Scalars are checked at UTF-8 boundaries, including values that identifiers
// cannot contain. Each typed failure has its own observable status.
const kinds=['ok','index','end','continuation','malformed','overlong','surrogate','range'];
const scalarCases=[['',0,'end'],['61',-1,'index'],['61',2,'index'],['61',1,'end'],['80',0,'continuation'],['e697a5',1,'continuation'],['c0af',0,'overlong'],['c1bf',0,'overlong'],['e08080',0,'overlong'],['f0808080',0,'overlong'],['eda080',0,'surrogate'],['edbfbf',0,'surrogate'],['f4908080',0,'range'],['f5808080',0,'range'],['ff',0,'malformed'],['e697',0,'malformed'],['e641a5',0,'malformed']];
for(const value of [0,0x7f,0x80,0x7ff,0x800,0xd7ff,0xe000,0xffff,0x10000,0x10ffff]) scalarCases.push([Buffer.from(String.fromCodePoint(value)).toString('hex'),0,value]);
for(const [hex,offset,wanted] of scalarCases) {
  const result=run(native,['--pair-scalar',hex,String(offset)]);assert.equal(result.status,0);
  const [status,value]=result.stdout.trim().split('|').map(Number);
  const input=Buffer.from(hex,'hex').toString('latin1');
  if(typeof wanted==='number') { assert.equal(status,0);assert.equal(value,wanted);assert.equal(scalarAt(input,BigInt(offset)),BigInt(wanted)); }
  else { assert.equal(kinds[status],wanted);assert.throws(()=>scalarAt(input,BigInt(offset)),error=>error instanceof HostOperationError && error.kind===wanted); }
}
// The classifier consumes pinned Unicode 17 tables; test all range edges and
// the adjacent holes instead of relying on the host's Unicode version.
const tables=fs.readFileSync(path.join(root,'unicode/kofun_unicode_tables.inc'),'utf8');
for(const kind of ['start','continue']) {
  const body=tables.match(new RegExp(`kofun_xid_${kind}_ranges\\[\\] = \\{([\\s\\S]*?)\\n\\};`))[1];
  const ranges=[...body.matchAll(/0x([0-9A-F]+)\), UINT32_C\(0x([0-9A-F]+)/g)].map(m=>[parseInt(m[1],16),parseInt(m[2],16)]);
  const points=new Set(ranges.flatMap(([a,b])=>[a-1,a,b,b+1]));
  for(const point of points) if(point>=0 && point<=0x10ffff && !(point>=0xd800 && point<=0xdfff)) {
    const wanted=point===95 || ranges.some(([a,b])=>point>=a && point<=b);
    assert.equal(compiler[`identifier_${kind}_at`](bytes(String.fromCodePoint(point)),0n),wanted,`${kind} U+${point.toString(16)}`);
  }
}
console.log('PASS: scalar boundaries and distinct typed failures; pinned XID range boundaries and holes');

for(const operation of ['stage2_unicode_scalar_at','stage2_same_file']) {
  assert.equal(compiler.builtin_arity(operation),-1n);
  assert.equal(compiler.selfhost_builtin_slot(operation),-1n);
  assert.equal(compiler.selfhost_c11_builtin_helper(operation),'');
  const test={name:`private-${operation}`,source:`fn main() -> Int { return ${operation}("a", "b") }\n`};
  for(const refusal of [nativeLower(native,test),kofunLower(compiler,test)]) assert.match(refusal,/error\[E2S16\]: unknown Core function/);
}
console.log('PASS: private operations do not resolve as source builtins; same-spelling declarations remain ordinary');

const modes=[
  ['--emit-selfhost-hir','emit_selfhost_hir_file','selfhost-HIR',true],
  ['--lower-selfhost-c11','lower_selfhost_c11_file','selfhost-C11',false],
  ['--selfhost-compile','selfhost_compile_file','selfhost-compile',true],
  ['--emit-scope-hir','emit_scope_hir_file','scope-HIR',false],
  ['--parse-patterns','parse_patterns_file','patterns',false],
];
const digest='0'.repeat(64);
const input=path.join(work,'input.kofun'), output=path.join(work,'output'), hard=path.join(work,'hard'), link=path.join(work,'link');
const source='fn main() -> Int { return 0 }\n';
fs.writeFileSync(input,source);fs.linkSync(input,hard);fs.symlinkSync(input,link);fs.mkdirSync(path.join(work,'dir'));
const aliases=[input,hard,link,`${work}/./input.kofun`,`${work}/dir/../input.kofun`,path.relative(root,input)];
function invokeKofun(pair,mode,left,right,{fault,invalidDigest=false,writeProbe,extra=[]}={}) {
  let printed='';
  const stat=p=> { if(text(p)===fault) { const error=new Error('injected lookup');error.code='EACCES';throw error; } return fs.statSync(text(p),{bigint:true}); };
  const side=loadCompiler({source:pair,stat,print:value=>{printed+=text(value)+'\n';}, validate(value){
    const p=path.join(work,'validate.kofun');fs.writeFileSync(p,Buffer.from(value,'latin1'));
    const result=run(native,['--pair-validate',p]);assert.equal(result.status,0);return bytes(result.stdout.trimEnd());
  },...(writeProbe ? {write:writeProbe}: {})});
  try {
    const args=[bytes(left),bytes(right),...extra.map(bytes)];if(mode[3])args.push(invalidDigest?'bad':digest);
    const result=side[mode[1]](...args);
    return {status:typeof result==='boolean' ? result?0:1 : Number(result),stdout:printed};
  } catch(error) {
    if(!(error instanceof HostOperationError))throw error;
    return {status:2,stdout:printed+error.message+'\n'};
  }
}
function invokeC(binary,mode,left,right,{fault,invalidDigest=false,extra=[]}={}) {
  return run(binary,[mode[0],left,right,...extra,...(mode[3]?[invalidDigest?'bad':digest]:[])],{env:{...process.env,...(fault?{KOFUN_PAIR_STAT_FAULT:fault}:{})}});
}
for(const mode of modes) {
  for(const alias of aliases) {
    const expectedMessage=`error[E2S35]: ${mode[2]} input and output must be distinct\n`;
    for(const side of ['C','Kofun']) {
      fs.writeFileSync(input,source);
      const result=side==='C'?invokeC(native,mode,input,alias,{invalidDigest:true}):invokeKofun(pairSource,mode,input,alias,{invalidDigest:true});
      assert.notEqual(result.status,0,`${side} ${mode[0]} ${alias}`);
      assert.equal(result.stdout,expectedMessage,'identity refusal precedes digest and source processing');
      assert.equal(fs.readFileSync(input,'utf8'),source,'alias refusal preserves source bytes');
    }
  }
  // Both operand lookups have priority over digest validation and source reads.
  for(const fault of [input,output]) for(const side of ['C','Kofun']) {
    fs.writeFileSync(output,'preserve output');
    const options={fault,invalidDigest:true};
    const result=side==='C'?invokeC(native,mode,input,output,options):invokeKofun(pairSource,mode,input,output,options);
    assert.equal(result.status,2);assert.match(result.stdout,/stage2_same_file: file lookup failed before output open/);
    assert.equal(fs.readFileSync(input,'utf8'),source);assert.equal(fs.readFileSync(output,'utf8'),'preserve output');
  }
}
// The ordinary driver has three outputs. Refuse aliases and failed lookups
// at any one of them before publishing even an earlier, safe destination.
const compileMode=['--compile-outcome','compile_file','compiler',false];
const outputs=['compiler-output.c','compiler.ir','compiler.tokens'].map(name=>path.join(work,name));
for(let target=0;target<outputs.length;target++) {
  for(const alias of aliases) for(const side of ['C','Kofun']) {
    fs.writeFileSync(input,source);
    for(const destination of outputs)fs.writeFileSync(destination,'preserve artifact');
    const destinations=outputs.map((destination,index)=>index===target?alias:destination);
    const options={extra:destinations.slice(1)};
    const result=side==='C'?invokeC(native,compileMode,input,destinations[0],options):invokeKofun(pairSource,compileMode,input,destinations[0],options);
    assert.equal(result.status,2);assert.equal(result.stdout,'error[E2S35]: compiler input and output must be distinct\n');
    assert.equal(fs.readFileSync(input,'utf8'),source);
    for(const destination of outputs)assert.equal(fs.readFileSync(destination,'utf8'),'preserve artifact');
  }
  for(const side of ['C','Kofun']) {
    const options={fault:outputs[target],extra:outputs.slice(1)};
    const result=side==='C'?invokeC(native,compileMode,input,outputs[0],options):invokeKofun(pairSource,compileMode,input,outputs[0],options);
    assert.equal(result.status,2);assert.match(result.stdout,/stage2_same_file: file lookup failed before output open/);
    for(const destination of outputs)assert.equal(fs.readFileSync(destination,'utf8'),'preserve artifact');
  }
}
// A missing input must not borrow the missing-output exception, and all other
// output errors (including ENOTDIR) are indeterminate, not Different.
fs.unlinkSync(output);
for(const [left,right,wanted] of [[input,output,0],[input,hard,1],[input,link,1],[input,`${input}/child`,2],[`${work}/missing`,output,2],[output,output,1]]) {
  assert.equal(Number(run(native,['--pair-identity',left,right]).stdout.trim()),wanted);
  if(wanted===2)assert.throws(()=>sameFile(bytes(left),bytes(right)),HostOperationError);
  else assert.equal(sameFile(bytes(left),bytes(right)),BigInt(wanted));
}
// Success goes through the real HIR writer in each half; no write-probe can
// turn a skipped guard into evidence that a safe output was published.
for(const side of ['C','Kofun']) {
  if(fs.existsSync(output))fs.unlinkSync(output);
  const result=side==='C'?invokeC(native,modes[0],input,output):invokeKofun(pairSource,modes[0],input,output);
  assert.equal(result.status,0,result.stdout);assert.match(fs.readFileSync(output,'utf8'),/^schema\|kofun\.selfhost-hir\/v1/);
  assert.equal(fs.readFileSync(input,'utf8'),source);
}
for(const code of ['EACCES','EIO','EOVERFLOW','EPERM','ENOTDIR','ELOOP']) {
  const result=run(native,['--pair-identity',input,output],{env:{...process.env,KOFUN_PAIR_STAT_FAULT:output,KOFUN_PAIR_STAT_ERRNO:code}});
  assert.equal(result.stdout,'2\n');
  assert.throws(()=>sameFile(bytes(input),bytes(output),p=>{
    if(text(p)===output) { const error=new Error('injected lookup');error.code=code;throw error; }
    return fs.statSync(text(p),{bigint:true});
  }),error=>error instanceof HostOperationError && error.kind==='lookup');
}
console.log('PASS: every writer and all three compiler outputs, six aliases, absent output, and lookup-error precedence without writes');

function changeOnce(source,needle,replacement) {
  assert(source.includes(needle),`mutation anchor missing: ${needle}`);
  return source.replace(needle,replacement);
}
// These mutations remove the production decisions, then run the same behavior
// checks. A syntax error or failed mutant build does not count as detection.
const badScalarC=buildNative('no-c-scalar',changeOnce(cSource,'Stage2Scalar scalar = stage2_unicode_scalar_at(identifier, length, (int64_t)cursor);','Stage2Scalar scalar = {STAGE2_SCALAR_OK, 65, 1};'));
assert.notEqual(nativeLower(badScalarC,fixture.cases[0]),expected.get(fixture.cases[0].name));
const badScalarK=loadCompiler({source:pairSource.replaceAll('stage2_unicode_scalar_at(identifier, cursor)','65')});
assert.notEqual(kofunLower(badScalarK,fixture.cases[0]),expected.get(fixture.cases[0].name));
const badIdentityC=buildNative('no-c-identity',cSource.replaceAll('if (identity == STAGE2_FILE_SAME) {','if (false && identity == STAGE2_FILE_SAME) {'));
const badIdentityK=pairSource.replaceAll('if stage2_same_file(input_path, output_path) == 1 {','if false && stage2_same_file(input_path, output_path) == 1 {');
for(const [side,pair] of [['C',badIdentityC],['Kofun',badIdentityK]]) {
  fs.writeFileSync(input,source);
  const result=side==='C'?invokeC(pair,modes[0],input,hard):invokeKofun(pair,modes[0],input,hard);
  assert.equal(result.status,0,result.stdout);
  assert.notEqual(fs.readFileSync(input,'utf8'),source,`${side}: removing identity guard must overwrite the fixture`);
}
// Every escaping dispatch has an executable fixture, not just a declared
// inventory. Bypass each Kofun call separately while preserving the parser.
const calls=[...pairSource.matchAll(/\bc_identifier_name\(/g)].filter(m=>!pairSource.slice(Math.max(0,m.index-3),m.index).endsWith('fn '));
for(const call of calls) {
  const mutated=pairSource.slice(0,call.index)+'pair_unescaped('+pairSource.slice(call.index+'c_identifier_name('.length)+'\nfn pair_unescaped(value: Text) -> Text { return value }\n';
  const side=loadCompiler({source:mutated});
  assert(fixture.cases.some(test=>kofunLower(side,test)!==expected.get(test.name)),`unexercised escape funnel at byte ${call.index}`);
}
console.log(`PASS: removing either scalar path or identity guard fails; all ${calls.length} Kofun escape dispatch mutations detected`);
// Prove the C dispatch inventory independently too: agreement alone could
// miss a fixture that never passes through one of the maintained C funnels.
const cCalls=[...cSource.matchAll(/\bc_identifier_name\(/g)].filter(m=>!cSource.slice(Math.max(0,m.index-13),m.index).endsWith('static char *'));
for(const [index,call] of cCalls.entries()) {
  const mutated=(cSource.slice(0,call.index)+'pair_unescaped('+cSource.slice(call.index+'c_identifier_name('.length))
    .replace('static char *c_identifier_name(', 'static char *pair_unescaped(const char *identifier) { return owned_text(identifier); }\nstatic char *c_identifier_name(');
  const binary=buildNative(`c-escape-${index}`,mutated);
  assert(fixture.cases.some(test=>nativeLower(binary,test)!==expected.get(test.name)),`unexercised C escape funnel at byte ${call.index}`);
}
console.log(`PASS: all ${cCalls.length} C escape dispatch mutations detected`);
console.log(`PASS: Stage 2 host-primitives pair (${work})`);
fs.rmSync(work,{recursive:true});
