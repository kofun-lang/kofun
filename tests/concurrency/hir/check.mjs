import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler, bytes, text, HostOperationError} from '../../../bootstrap/stage2/host-driver.mjs';
import {LIMITS, validateScopeHir, canonicalJson} from '../../../spec/concurrency/scoped-captures-v1/model.mjs';

const root=fileURLToPath(new URL('../../../',import.meta.url));
const parent=path.join(root,'build',process.env.KOFUN_GATE_WORK_NAMESPACE ?? '', 'concurrency-hir');
fs.mkdirSync(parent,{recursive:true});
const work=fs.mkdtempSync(path.join(parent,'run-'));
const fixture=JSON.parse(fs.readFileSync(new URL('./cases.json',import.meta.url),'utf8'));
assert.equal(fixture.schema,'kofun.scoped-hir-identity-fixtures/v1');
function run(command,args,options={}) {
  const result=spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:32*1024*1024,...options});
  if(result.error) throw result.error;
  return result;
}
function compile(name,flags,cc=process.env.CC || 'cc') {
  const binary=path.join(work,name);
  const result=run(cc,['-std=c11',...flags,'-Wall','-Wextra','-Werror','-pedantic','tests/concurrency/hir/driver.c','-o',binary]);
  assert.equal(result.status,0,result.stderr);
  return binary;
}
assert.equal(run('node',['bootstrap/stage2/generate-scoped-unicode.mjs','--check']).status,0,'pinned Unicode projection');
const native=compile('O0',['-O0']);
const optimized=compile('O2',['-O2']);
const sanitized=compile('sanitized',['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'],process.env.SANITIZER_CC || 'clang');
const production=process.env.KOFUN_STAGE2_COMPILER || native;
const compiler=loadCompiler();
const u32=value=>{const b=Buffer.alloc(4);b.writeUInt32BE(value);return b;};
const raw=hex=>Buffer.from(hex,'hex');
// Independently assemble the binary preimage. No production framing helper or
// production-produced identity is an input to this oracle.
function frame(domain,...parts) {
  const d=Buffer.from(domain),payload=Buffer.concat(parts),width=Buffer.alloc(2);
  width.writeUInt16BE(d.length);
  return crypto.createHash('sha256').update(Buffer.concat([Buffer.from('KOFUN\0'),width,d,u32(payload.length),payload])).digest('hex');
}
function fileId(logical) {
  const pkg=`kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=${logical}\n`;
  return frame('kofun.id.file/v1',Buffer.from(`kofun.file-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nlogical-path=${logical}\nsource-role=authored\nprovenance=explicit-source\n`));
}
const named=(file,kind,n)=>frame(`kofun.stage2.${kind}/v1`,raw(file),Buffer.from(`hir-${kind}:${n}`));
const node=(file,kind,start,end)=>frame('kofun.sidecar.node/v1',raw(file),Buffer.from([kind]),u32(start),u32(end),u32(0));
function expected(test,logical=fixture.logical_path) {
  const source=Buffer.from(test.source),file=fileId(logical),rootScope=named(file,'scope',0);
  function display(at) {
    if(at<0)return {disclosure:'hidden',text:null};
    const name=source.subarray(at).toString('utf8').match(/^[_\p{XID_Start}][_\p{XID_Continue}]*/u)?.[0];
    assert(name,`identifier at ${at}`);
    return Buffer.byteLength(name)>128 ? {disclosure:'hidden',text:null} : {disclosure:'visible',text:name};
  }
  const spans=[...test.pars.map(row=>[4,row[1],row[2]]),...test.tasks.flatMap(row=>[[8,row[2],row[3]],[2,row[4],row[5]]]),...test.joins.map(row=>[8,row[1],row[2]])];
  assert.equal(new Set(spans.map(parts=>parts.join(':'))).size,spans.length,`${test.name}: unique node kind/span; occurrence zero`);
  const pars=test.pars.map(([index,start,end,scope,token,at])=>{
    assert.equal(source.subarray(start,start+3).toString(),'par');
    assert.equal(source[end-1],125);
    const scopeId=named(file,'scope',scope),nodeId=node(file,4,start,end);
    return {record:'par',id:frame('kofun.scope-hir.par/v2',raw(file),raw(scopeId),raw(nodeId)),node_id:nodeId,scope_id:scopeId,parent_scope_id:rootScope,scope_token_binding_id:named(file,'binding',token),lexical_index:index,display:display(at)};
  });
  const tasks=test.tasks.map(([par,index,start,end,lambdaStart,lambdaEnd,binding,at])=>{
    assert.equal(source[end-1],41);
    assert.equal(source.subarray(lambdaStart,lambdaStart+2).toString(),'fn');
    const spawn=node(file,8,start,end),lambda=node(file,2,lambdaStart,lambdaEnd),handle=named(file,'binding',binding);
    return {record:'task',id:frame('kofun.scope-hir.task/v2',raw(pars[par].id),u32(index),raw(spawn),raw(lambda),raw(handle)),par_id:pars[par].id,spawn_node_id:spawn,lambda_node_id:lambda,handle_binding_id:handle,lexical_index:index,display:display(at)};
  });
  const joins=tasks.map((task,index)=>{
    const explicit=test.joins.find(([binding])=>binding===test.tasks[index][6]);
    const nodeId=explicit ? node(file,8,explicit[1],explicit[2]):null;
    return {record:'join',id:frame('kofun.scope-hir.join/v2',raw(task.id),Buffer.from([explicit?1:2]),...(explicit?[raw(nodeId)]:[])),task_id:task.id,join_kind:explicit?'explicit':'scope-exit',node_id:nodeId};
  });
  return canonicalJson({schema:'kofun-scope-hir/v2',profile:'kofun.stage2-analysis/scoped-captures/v1',file_id:file,root_scope_id:rootScope,limits:LIMITS,records:[...pars,...tasks,...joins]});
}
let serial=0;
function kofunEmit(input,output,logical) {
  let printed='';
  const side=loadCompiler({print:value=>{printed+=text(value)+'\n';},validate(value){
    const file=path.join(work,'unicode-input.kofun');fs.writeFileSync(file,Buffer.from(value,'latin1'));
    const result=run(native,['--validate',file]);assert.equal(result.status,0,result.stderr);
    return bytes(result.stdout.trimEnd());
  }});
  try {return {status:side.emit_scope_hir_v2_file(bytes(input),bytes(output),bytes(logical))?0:1,stdout:printed};}
  catch(error) {if(!(error instanceof HostOperationError)) throw error;return {status:2,stdout:printed+error.message+'\n'};}
}
function positive(test,logical=fixture.logical_path,{all=true}={}) {
  const base=path.join(work,`${serial++}-${test.name}`),input=`${base}.kofun`;
  fs.writeFileSync(input,test.source);
  const want=expected(test,logical);
  const hir=compiler.build_scope_hir_analysis_mode(bytes(test.source),true,true);
  assert(!text(hir).startsWith('error['),`${test.name}: ${text(hir)}`);
  const facts=compiler.scoped_hir_observations(bytes(test.source),hir);
  assert(!text(facts).startsWith('error['),`${test.name}: ${text(facts)}`);
  assert.equal(text(compiler.scoped_hir_render(bytes(test.source),facts,bytes(logical))),want,`${test.name}: Kofun complete renderer`);
  const resolved=run(native,['--resolved',input]);
  assert.equal(resolved.status,0);assert.equal(resolved.stdout,text(hir),`${test.name}: complete lexical resolver pair`);
  for(const binary of all ? [...new Set([native,optimized,sanitized,production])] : [production]) {
    const output=`${base}-${path.basename(binary)}.json`;
    for(let repeat=0;repeat<2;repeat++) {
      const result=run(binary,['--emit-scope-hir-v2',input,output,logical]);
      assert.equal(result.status,0,`${test.name}: ${result.stdout}${result.stderr}`);
      assert.equal(result.stdout,'');assert.equal(result.stderr,'');
      const actual=fs.readFileSync(output,'utf8');
      assert.equal(actual,want,`${test.name}: ${binary}`);
      validateScopeHir(JSON.parse(actual));assert.equal(canonicalJson(JSON.parse(actual)),actual);
    }
  }
  const output=`${base}-kofun.json`,k=kofunEmit(input,output,logical);
  assert.equal(k.status,0,k.stdout);assert.equal(k.stdout,'');assert.equal(fs.readFileSync(output,'utf8'),want);
  return {input,want};
}
// Full recursive decomposition cases and Hangul, every composition pair,
// canonical blocking witnesses and seeded mixed sequences come from pinned C.
const unicode=run(native,['--unicode-vectors']);
assert.equal(unicode.status,0,unicode.stderr);
const unicodeCases=unicode.stdout.trim().split('\n');
for(const row of unicodeCases) {
  const [hex,want]=row.split(' ');
  const value=String.fromCodePoint(...hex.match(/.{6}/g).map(cp=>parseInt(cp,16)));
  assert.equal(compiler.scoped_unicode_is_nfc(bytes(value)),want==='1',`NFC ${hex}`);
}
console.log(`PASS: ${unicodeCases.length} pinned Unicode NFC differential vectors, complete canonical mappings/Hangul and composition blocking`);
for(const test of fixture.cases) positive(test);
console.log('PASS: frozen source spans, resolver keys and all upstream/derived IDs; O0/O2/repeat/ASan/UBSan and complete Kofun/C output');

// Same-width renames preserve every identity, including nested handle shadows.
const shadow=fixture.cases.find(test=>test.name==='shadow');
const renamed={...shadow,name:'renamed',source:shadow.source.replaceAll('scope','realm').replaceAll('work','task').replaceAll('other','space').replaceAll('last','tail')};
const renameResult=positive(renamed);
const withoutDisplays=value=>JSON.parse(JSON.stringify(value,(key,item)=>key==='display'?undefined:item));
assert.deepEqual(withoutDisplays(JSON.parse(expected(shadow))),withoutDisplays(JSON.parse(renameResult.want)));
// UTF-8 byte spans and hidden long displays. Build independent expected spans
// by applying the explicit known replacement widths, not reading compiler HIR.
function renameScope(name) {
  const original=fixture.cases.find(test=>test.name==='implicit');
  const d=Buffer.byteLength(name)-5;
  return {name:`scope-${Buffer.byteLength(name)}`,source:original.source.replaceAll('scope',name),pars:[[0,13,64+2*d,3,0,18]],tasks:[[0,0,39+d,61+2*d,51+2*d,60+2*d,1,32+d]],joins:[]};
}
positive(renameScope('領域'));
positive(renameScope('s'.repeat(128)));
positive(renameScope('s'.repeat(129)));
const base=fixture.cases[1];
const relocated=positive({...base,name:'relocated'});
assert.equal(relocated.want,expected(base));
const changed=positive({...base,name:'logical-change'},'other/scoped.kofun');
assert.notEqual(JSON.parse(changed.want).file_id,JSON.parse(relocated.want).file_id);
for(const logical of ['data/file:part.kofun','1:main.kofun','src/é_日本.kofun','src/😀.kofun','src/q\u0301.kofun','src/각.kofun']) {
  positive({...base,name:'path-unicode'},logical);
}
positive({...base,name:'path-4096'},'界'.repeat(1363)+'abc.txt',{all:false});
console.log('PASS: equal-width display rename, Unicode/128/129-byte displays, physical relocation and explicit logical provenance through a 4096-byte path');

function negative(name,source,pattern,{logical=fixture.logical_path,existing=false}={}) {
  const input=path.join(work,`${serial++}-${name}.kofun`);fs.writeFileSync(input,source);
  let nativeMessage;
  for(const binary of [...new Set([native,optimized,production])]) {
    const output=`${input}.${path.basename(binary)}.json`;
    if(existing) fs.writeFileSync(output,'prior complete artifact\n');
    const result=run(binary,['--emit-scope-hir-v2',input,output,logical]);
    assert.notEqual(result.status,0,`${name}: unexpectedly accepted`);
    assert.equal(result.stderr,'');assert.match(result.stdout,pattern,`${name}: ${result.stdout}`);
    if(existing) assert.equal(fs.readFileSync(output,'utf8'),'prior complete artifact\n');
    else assert(!fs.existsSync(output),`${name}: partial artifact`);
    nativeMessage ??= result.stdout;assert.equal(result.stdout,nativeMessage);
  }
  const output=`${input}.kofun.json`;
  if(existing) fs.writeFileSync(output,'prior complete artifact\n');
  const result=kofunEmit(input,output,logical);
  assert.notEqual(result.status,0,`${name}: Kofun accepted`);assert.equal(result.stdout,nativeMessage,`${name}: pair refusal`);
  if(existing) assert.equal(fs.readFileSync(output,'utf8'),'prior complete artifact\n');
  else assert(!fs.existsSync(output));
}
const refused=[
['shadow-token','fn main() {\n par |scope| {\n {\n let scope = 1\n let work = scope.spawn(fn() => 1)\n }\n }\n}\n',/resolved par token at byte 57/],
['shadow-handle','fn main() {\n par |scope| {\n let work = scope.spawn(fn() => 1)\n {\n let work = 1\n work.join()\n }\n }\n}\n',/this par's resolved handle at byte 80/],
['double-join','fn main() {\n par |scope| {\n let work = scope.spawn(fn() => 1)\n work.join()\n work.join()\n }\n}\n',/at most once at byte 76/],
['chained-twice',base.source.replace('=> 1)','=> 1).join().join()'),/final member call/],
['chained-argument',base.source.replace('=> 1)','=> 1).join(3)'),/join takes no arguments/],
['unnamed-arithmetic',base.source.replace('let left = ','').replace('=> 1)','=> 1) + 2'),/initializer must be exactly its spawn/],
['spawn-arithmetic',base.source.replace('=> 1)','=> 1) + 2'),/initializer must be exactly its spawn/],
['join-argument',base.source.replace('\n }','\n left.join(1)\n }'),/join takes no arguments/],
['non-lambda',base.source.replace('fn() => 1','1'),/requires one fn lambda/],
];
for(const [name,source,pattern] of refused) negative(name,source,pattern,{existing:true});
negative('unclosed-function','fn main() { par |scope| {',/E2S03.*malformed function/,{existing:true});
negative('source-nul',base.source+'\0fn hidden() {}',/EUNICODE002/,{existing:true});
negative('non-nfc',base.source.replaceAll('scope','cafe\u0301'),/EUNICODE005/,{existing:true});

for(const basename of ['e2s154_par_dynamic_scope_token','e2s154_join_alias','e2s154_par_nested_scope','e2s154_par_spawn_in_loop','e2s154_par_missing_scope_token','e2s154_par_missing_block']) {
  const file=path.join(root,'tests/diagnostics/stage2',`${basename}.kofun`);
  const source=fs.readFileSync(file,'utf8');
  const span=source.match(/# expect-span: byte (\d+)/)?.[1];assert(span,basename);
  negative(basename,source,new RegExp(`error\\[E2S154\\].* at byte ${span}\\n$`));
}
for(const logical of ['', '/root/file', './file', '../file','a//b','a/./b','a/../b','a/','C:/file','a\\b','a\nfile','a\x7ffile','a\u0085file','a\u00adfile','a\u200bfile','a\u2028file','a\u2029file','src/e\u0301.kofun','src/Ê\u0323\u065f.kofun','https:remote.kofun','mailto:src.kofun','git+ssh:src.kofun','file://src/main.kofun','界'.repeat(1365)+'aa','x'.repeat(4097)]) {
  for(const existing of [false,true]) negative('path',base.source,/canonical relative UTF-8/, {logical,existing});
}
for(const [label,value,valid] of [
  ['nul',Buffer.from('src/\0hidden'),false],
  ['bad-leading',Buffer.from([0xff]),false],
  ['surrogate',Buffer.from([0xed,0xa0,0x80]),false],
  ['overlong',Buffer.from([0xc0,0xaf]),false],
  ['truncated',Buffer.from([0xf0,0x9f]),false],
  ['unicode',Buffer.from('src/é.kofun'),true],
]) {
  const input=path.join(work,`path-bytes-${label}`);fs.writeFileSync(input,value);
  const result=run(native,['--path-bytes',input]);
  assert.equal(result.status,0);assert.equal(result.stdout,`${Number(valid)}\n`);
  try {assert.equal(compiler.scoped_hir_logical_path(value.toString('latin1')),valid,label);}
  catch(error) {assert(!valid && error instanceof HostOperationError,label);}
}

console.log('PASS: exact existing E2S154 spans, shadow/alias/dynamic/duplicate-join and path refusals preserve prior artifacts');

function manyPars(count) {
  let source='fn main() {\n';const pars=[];
  for(let index=0;index<count;index++) {
    const start=source.length;source+='par |scope| {}\n';
    pars.push([index,start,source.length-1,3+index,index,start+5]);
  }
  source+='}\n';return {name:`pars-${count}`,source,pars,tasks:[],joins:[]};
}
function manyTasks(count) {
  let source='fn main() {\npar |scope| {\n';const start=12,tasks=[];
  for(let index=0;index<count;index++) {
    const name=`h${index}`,at=source.length+4;
    source+=`let ${name} = `;const spawn=source.length;
    source+='scope.spawn(';const lambda=source.length;
    source+='fn() => 1';const lambdaEnd=source.length;
    source+=')';const end=source.length;source+='\n';
    tasks.push([0,index,spawn,end,lambda,lambdaEnd,index+1,at]);
  }
  source+='}';const end=source.length;source+='\n}\n';
  return {name:`tasks-${count}`,source,pars:[[0,start,end,3,0,start+5]],tasks,joins:[]};
}
function acrossPars(counts) {
  let source='fn main() {\n';const pars=[],tasks=[];
  let scope=3,binding=2;
  for(const [par,count] of counts.entries()) {
    const start=source.length;source+='par |scope| {\n';
    for(let index=0;index<count;index++) {
      const name=`h${index}`,at=source.length+4;
      source+=`let ${name} = `;const spawn=source.length;
      source+='scope.spawn(';const lambda=source.length;
      source+='fn() => 1';const lambdaEnd=source.length;
      source+=')';const end=source.length;source+='\n';
      tasks.push([par,index,spawn,end,lambda,lambdaEnd,binding++,at]);
    }
    source+='}';const end=source.length;source+='\n';
    pars.push([par,start,end,scope,par,start+5]);scope+=1+count;
  }
  source+='}\n';return {name:`tasks-${counts.join('-')}`,source,pars,tasks,joins:[]};
}
positive({name:'empty-file',source:'',pars:[],tasks:[],joins:[]});
positive(manyPars(1));positive(acrossPars([32,32]));
negative('tasks-33-32',acrossPars([33,32]).source,/task limit is 64/,{existing:true});
positive(manyPars(64));positive(manyTasks(64));
negative('pars-65',manyPars(65).source,/par limit is 64/,{existing:true});
negative('tasks-65',manyTasks(65).source,/task limit is 64/,{existing:true});
console.log('PASS: 64 pars and 64 tasks succeed; 65 refuses without truncation or partial publication');

const frameDomains=['kofun.id.file/v1','kofun.stage2.scope/v1','kofun.stage2.binding/v1','kofun.sidecar.node/v1','kofun.scope-hir.par/v2','kofun.scope-hir.task/v2','kofun.scope-hir.join/v2'];
let frameCount=0;
for(const [di,domain] of frameDomains.entries()) for(const length of [...new Set([0,1,31,32,55,64,132,508,...[55,56,63,64,119,120].map(total=>total-12-Buffer.byteLength(domain))])]) {
  const payload=Buffer.from(Array.from({length},(_,i)=>(i*37+di*53)&255)),hex=payload.toString('hex');
  const parts=[0,254,508,762].map(at=>hex.slice(at,at+254));
  const want=frame(domain,payload);
  assert.equal(text(compiler.scoped_hir_hash_frame(bytes(domain),...parts.map(bytes))),want);
  const result=run(native,['--frame',domain,...parts]);assert.equal(result.status,0);assert.equal(result.stdout,want+'\n');
  frameCount++;
}
console.log(`PASS: ${frameCount} independent raw-byte domain frames, including NUL and nine-block SHA messages`);

// Every public legacy entry still has its original refusal/output. Analysis
// does not enable the normal compiler or alter the v1 private HIR bytes.
for(const test of fixture.cases) {
  const input=path.join(work,`legacy-${test.name}.kofun`);fs.writeFileSync(input,test.source);
  const output=`${input}.hir`,result=run(production,['--emit-scope-hir',input,output]);
  const want=text(compiler.build_scope_hir_mode(bytes(test.source),true));
  if(test.pars.length) {
    assert.notEqual(result.status,0);assert.equal(result.stdout,want+'\n');assert(!fs.existsSync(output));
    const lowered=run(production,['--compile-outcome',input,`${input}.c`,`${input}.ir`,`${input}.tokens`]);
    assert.notEqual(lowered.status,0);assert.match(lowered.stdout,new RegExp(test.normal_error_code));assert(!fs.existsSync(`${input}.c`));
  } else {assert.equal(result.status,0);assert.equal(fs.readFileSync(output,'utf8'),want);}
}
const input=path.join(work,'same.kofun');fs.writeFileSync(input,base.source);
const hard=`${input}.hard`,link=`${input}.link`;fs.linkSync(input,hard);fs.symlinkSync(input,link);
fs.mkdirSync(path.join(work,'alias-dir'));
for(const output of [input,hard,link,`${work}/./same.kofun`,`${work}/alias-dir/../same.kofun`,path.relative(root,input)]) {
  const result=run(production,['--emit-scope-hir-v2',input,output,'../invalid.kofun']);
  assert.notEqual(result.status,0);assert.match(result.stdout,/input and output must be distinct/);
  const k=kofunEmit(input,output,'../invalid.kofun');assert.notEqual(k.status,0);assert.equal(k.stdout,result.stdout);
  assert.equal(fs.readFileSync(input,'utf8'),base.source);
}
for(const args of [['--emit-scope-hir-v2'],['--emit-scope-hir-v2',input,'out'],['--emit-scope-hir-v2',input,'out',fixture.logical_path,'extra']]) {
  const result=run(production,args);assert.equal(result.status,2);assert.match(result.stdout+result.stderr,/usage:/);
}
console.log('PASS: legacy scope-HIR and normal compiler remain unchanged; same-file aliases and CLI arity fail before output');
