import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler,bytes,text} from '../../../bootstrap/stage2/host-driver.mjs';
import {LIMITS,canonicalJson,validateScopeHir} from '../../../spec/concurrency/scoped-captures-v1/model.mjs';
const root=fileURLToPath(new URL('../../../',import.meta.url));
const parent=path.join(root,'build',process.env.KOFUN_GATE_WORK_NAMESPACE??'','concurrency-places');
fs.mkdirSync(parent,{recursive:true});
const work=fs.mkdtempSync(path.join(parent,'run-'));
function run(command,args,options={}) {
 const r=spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:32*1024*1024,...options});
 if(r.error)throw r.error;return r;
}
function compile(name,flags,cc=process.env.CC||'cc') {
 const out=path.join(work,name),r=run(cc,['-std=c11',...flags,'-Wall','-Wextra','-Werror','-pedantic','tests/concurrency/places/driver.c','-o',out]);
 assert.equal(r.status,0,r.stderr);return out;
}
const native=compile('O0',['-O0']);
const optimized=compile('O2',['-O2']);
const sanitized=compile('sanitized',['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'],process.env.SANITIZER_CC||'clang');
const production=process.env.KOFUN_STAGE2_COMPILER||native;
const compiler=loadCompiler();
const raw=x=>Buffer.from(x,'hex');
const u32=x=>{const b=Buffer.alloc(4);b.writeUInt32BE(x);return b;};
const u16=x=>{const b=Buffer.alloc(2);b.writeUInt16BE(x);return b;};
function frame(domain,...parts){const d=Buffer.from(domain),p=Buffer.concat(parts);return crypto.createHash('sha256').update(Buffer.concat([Buffer.from('KOFUN\0'),u16(d.length),d,u32(p.length),p])).digest('hex');}
const logical='src/checked-places.kofun';
const pkg=`kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=${logical}\n`;
const file=frame('kofun.id.file/v1',Buffer.from(`kofun.file-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nlogical-path=${logical}\nsource-role=authored\nprovenance=explicit-source\n`));
const moduleId=frame('kofun.id.module/v1',Buffer.from(`kofun.module-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nkind=synthetic-root\n`));
const namespace=frame('kofun.id.namespace/v1',Buffer.from('kofun.namespace-id/v1\ntag=1\nname=type\n'));
const tlv=(tag,value)=>Buffer.concat([u16(tag),u32(value.length),value]);
const typeId=name=>frame('kofun.id.symbol/v1',tlv(0x8001,raw(moduleId)),tlv(0x8002,raw(namespace)),tlv(0x8003,Buffer.from('record')),tlv(0x8004,Buffer.from(name)));
const named=(kind,index)=>frame(`kofun.stage2.${kind}/v1`,raw(file),Buffer.from(`hir-${kind}:${index}`));
const node=(kind,start,end)=>frame('kofun.sidecar.node/v1',raw(file),Buffer.from([kind]),u32(start),u32(end),u32(0));
const expression=(start,end)=>frame('kofun.stage2.analysis-expression/v1',raw(file),u32(start),u32(end));
const display=s=>Buffer.byteLength(s)<=128?{disclosure:'visible',text:s}:{disclosure:'hidden',text:null};
const field=(owner,ordinal,name)=>({kind:'field',owner_type_id:typeId(owner),ordinal,display:display(name)});
const constant=value=>({kind:'constant',value:String(BigInt(value))});
const slice=(lower,upper)=>({kind:'slice',lower,upper});
function program(expr,{shadow=false,rename=false,types='type R = { a: Int, inner: R, items: List[Int] }\n',params='x: R, lo: Int, hi: Int',locals=''}={}) {
 const source=types+`fn f(${params}) {\n${locals} par |scope| {\n${shadow?'  {\n   let x = x\n':''}  let h = scope.spawn(fn() { ${expr} })\n${shadow?'  }\n':''} }\n}\nfn bound(n: Int) -> Int { return n }\n`;
 const b=Buffer.from(source),at=(s,from=0)=>b.indexOf(Buffer.from(s),from);
 const par=at('par |'),parEnd=at('\n }\n',par)+3,spawn=at('scope.spawn'),spawnEnd=at(')\n',spawn)+1;
 const lambda=at('fn()',spawn),lambdaEnd=spawnEnd-1,start=at(expr,lambda),end=start+Buffer.byteLength(expr);
 return {source,expr,start,end,par,parEnd,spawn,spawnEnd,lambda,lambdaEnd,shadow,rename,localCount:(locals.match(/let /g)||[]).length};
}
function boundNode(test,spelling,offset=0){const at=test.start+Buffer.from(test.expr).indexOf(Buffer.from(spelling),offset);return {kind:'node',node_id:expression(at,at+Buffer.byteLength(spelling))};}
function expected(test,projections,reason=null) {
 const parNode=node(4,test.par,test.parEnd),scope=named('scope',3),parId=frame('kofun.scope-hir.par/v2',raw(file),raw(scope),raw(parNode));
 const spawnNode=node(8,test.spawn,test.spawnEnd),lambdaNode=node(2,test.lambda,test.lambdaEnd),handle=named('binding',(test.shadow?5:4)+test.localCount);
 const taskId=frame('kofun.scope-hir.task/v2',raw(parId),u32(0),raw(spawnNode),raw(lambdaNode),raw(handle));
 const records=[{record:'par',id:parId,node_id:parNode,scope_id:scope,parent_scope_id:named('scope',0),scope_token_binding_id:named('binding',3),lexical_index:0,display:display('scope')},
 {record:'task',id:taskId,par_id:parId,spawn_node_id:spawnNode,lambda_node_id:lambdaNode,handle_binding_id:handle,lexical_index:0,display:display('h')},
 {record:'join',id:frame('kofun.scope-hir.join/v2',raw(taskId),Buffer.from([2])),task_id:taskId,join_kind:'scope-exit',node_id:null}];
 if(reason){const tag=reason==='projection-depth-exceeded'?2:3,witness=expression(test.start,test.end);const payload=Buffer.concat([raw(taskId),Buffer.from([tag]),raw(witness)]);records.push({record:'unknown',id:frame('kofun.scope-hir.unknown/v2',payload),task_id:taskId,witness_node_id:witness,reason,canonical_bytes:Buffer.concat([Buffer.from([75,85,78,0,2]),payload]).toString('hex')});}
 else {
  const base=named('binding',test.baseBinding??(test.shadow?4:0));
  const encodeBound=b=>{if(b.kind==='node')return Buffer.concat([Buffer.from([2]),raw(b.node_id)]);const v=Buffer.alloc(8);v.writeBigInt64BE(BigInt(b.value));return Buffer.concat([Buffer.from([1]),v]);};
  const payload=Buffer.concat([Buffer.from([75,80,76,0,2]),raw(base),Buffer.from([projections.length]),...projections.map(p=>p.kind==='field'?Buffer.concat([Buffer.from([1]),raw(p.owner_type_id),u32(p.ordinal)]):Buffer.concat([Buffer.from([2]),encodeBound(p.lower),encodeBound(p.upper)]))]);
  records.push({record:'place',id:frame('kofun.scope-hir.place/v2',payload),base_binding_id:base,projections,canonical_bytes:payload.toString('hex'),display:display(test.baseName??'x')});
 }
 return canonicalJson({schema:'kofun-scope-hir/v2',profile:'kofun.stage2-analysis/scoped-captures/v1',file_id:file,root_scope_id:named('scope',0),limits:LIMITS,records});
}
function kofunEmit(input,output,logicalPath,task,start,end) {
 let printed='';
 const side=loadCompiler({print:value=>{printed+=text(value)+'\n';},validate(value){
  const file=path.join(work,'unicode-input.kofun');fs.writeFileSync(file,Buffer.from(value,'latin1'));
  const r=run(native,['--validate',file]);assert.equal(r.status,0,r.stderr);return bytes(r.stdout.trimEnd());
 }});
 return {status:side.emit_place_hir_v2_file(bytes(input),bytes(output),bytes(logicalPath),bytes(task),bytes(String(start)),bytes(String(end)))?0:1,stdout:printed};
}
let serial=0;
function direct(test) {
 const source=bytes(test.source),hir=compiler.build_scope_hir_analysis_mode(source,true,true);
 assert(!text(hir).startsWith('error['),text(hir));
 const facts=compiler.scoped_hir_observations(source,hir);assert(!text(facts).startsWith('error['),text(facts));
 return text(compiler.checked_place_render(source,hir,facts,bytes(logical),0n,BigInt(test.start),BigInt(test.end)));
}
function check(test,projections,reason=null) {
 const want=expected(test,projections,reason);assert.equal(direct(test),want,`${test.expr}: independent Kofun oracle`);
 validateScopeHir(JSON.parse(want));
 const input=path.join(work,`${serial++}.kofun`);fs.writeFileSync(input,test.source);
 for(const binary of new Set([native,optimized,sanitized,production]))for(let repeat=0;repeat<2;repeat++){
  const output=`${input}.${path.basename(binary)}.json`,r=run(binary,['--emit-place-hir-v2',input,output,logical,'0',String(test.start),String(test.end)]);
  assert.equal(r.status,0,`${test.expr}: ${r.stdout}${r.stderr}`);assert.equal(r.stdout,'');assert.equal(r.stderr,'');assert.equal(fs.readFileSync(output,'utf8'),want,`${test.expr}: ${binary}`);
 }
 const output=`${input}.kofun.json`,k=kofunEmit(input,output,logical,'0',test.start,test.end);
 assert.equal(k.status,0,k.stdout);assert.equal(k.stdout,'');assert.equal(fs.readFileSync(output,'utf8'),want);
 return JSON.parse(want).records.at(-1);
}
const base=check(program('x'),[]);
// Grouping preserves the resolved base, projection bytes and base display;
// only occurrence spans (and dynamic-bound occurrence IDs) include grouping.
for(const expr of ['(x)','((x))'])assert.equal(check(program(expr),[]).id,base.id);
for(const expr of ['(x).a','(x.a)','((x)).a'])check(program(expr),[field('R',0,'a')]);
check(program('((x).inner).a'),[field('R',1,'inner'),field('R',0,'a')]);
for(const expr of ['(x.items)[lo .. hi]','((x.items[lo .. hi]))']) {
 const t=program(expr);check(t,[field('R',2,'items'),slice(boundNode(t,'lo'),boundNode(t,'hi'))]);
}
for(const expr of ['(lo + 1)','(bound(lo))','((x.items[lo]))'])check(program(expr),null,'unnameable-place');
check(program('(x'+'.inner'.repeat(9)+')'),null,'projection-depth-exceeded');
const callable=program('(x)',{params:'x: Int -> Int, lo: Int, hi: Int'});
check(callable,[]);
check(program('bound(lo,)'),null,'unnameable-place');
const trailingBound=program('x.items[bound(lo,) .. hi]');
check(trailingBound,[field('R',2,'items'),slice(boundNode(trailingBound,'bound(lo,)'),boundNode(trailingBound,'hi',trailingBound.expr.indexOf('..')+2))]);
check(program('x.a'),[field('R',0,'a')]);
check(program('x.inner.a'),[field('R',1,'inner'),field('R',0,'a')]);
check(program('x.inner.items[-9223372036854775808 .. 9223372036854775807]'),[field('R',1,'inner'),field('R',2,'items'),slice(constant('-9223372036854775808'),constant('9223372036854775807'))]);
for(const [low,high] of [['-0','+0'],['0002','2'],['-9','-2'],['8','8']])check(program(`x.items[${low} .. ${high}]`),[field('R',2,'items'),slice(constant(low),constant(high))]);
for(const [low,high,wantLow,wantHigh] of [
 ['-9_223_372_036_854_775_808','9_223_372_036_854_775_807','-9223372036854775808','9223372036854775807'],
 ['0_0','1_024','0','1024'],['-0_0','+0_0','0','0'],['000_001','0_002','1','2'],
])check(program(`x.items[${low} .. ${high}]`),[field('R',2,'items'),slice(constant(wantLow),constant(wantHigh))]);
for(const [low,high] of [['lo','hi'],['lo + 1','hi - 1'],['bound(lo)','bound(hi)'],['(lo + 1)','hi']]) {
 const t=program(`x.items[${low} .. ${high}]`);check(t,[field('R',2,'items'),slice(boundNode(t,low),boundNode(t,high,t.expr.indexOf('..')+2))]);
}
const indexBound=program('x.items[x.items[lo] .. hi]');
check(indexBound,[field('R',2,'items'),slice(boundNode(indexBound,'x.items[lo]'),boundNode(indexBound,'hi',indexBound.expr.indexOf('..')+2))]);
check(program('x.値',{types:'type 型 = { 値: Int }\n',params:'x: 型, lo: Int, hi: Int'}),[field('型',0,'値')]);
for(const type of ['Float','Decimal','Text','Bool','Bytes'])check(program('x',{params:`x: ${type}, lo: Int, hi: Int`}),[]);
const textList=program('x[lo .. hi]',{params:'x: List[Text], lo: Int, hi: Int'});
check(textList,[slice(boundNode(textList,'lo'),boundNode(textList,'hi'))]);
check(program('x[lo]',{params:'x: List[Text], lo: Int, hi: Int'}),null,'unnameable-place');
const textField=program('x.items[lo .. hi]',{types:'type R = { items: List[Text] }\n'});
check(textField,[field('R',0,'items'),slice(boundNode(textField,'lo'),boundNode(textField,'hi'))]);
const textCall=program('x.items[count_text(lo) .. hi]',{params:'x: R, lo: List[Text], hi: Int'});
textCall.source+='fn count_text(items: List[Text]) -> Int { return 0 }\n';
check(textCall,[field('R',2,'items'),slice(boundNode(textCall,'count_text(lo)'),boundNode(textCall,'hi'))]);
const maxSlices=program('x'+'[lo .. hi]'.repeat(8),{params:'x: List[Int], lo: Int, hi: Int'});
const maxProjections=Array.from({length:8},(_,i)=>slice(boundNode(maxSlices,'lo',1+i*10),boundNode(maxSlices,'hi',1+i*10)));
const maxRecord=check(maxSlices,maxProjections);assert.equal(raw(maxRecord.canonical_bytes).length,574);
const same=program('x.items[lo .. lo]');const sameRecord=check(same,[field('R',2,'items'),slice(boundNode(same,'lo'),boundNode(same,'lo',same.expr.indexOf('..')+2))]);
assert.notEqual(sameRecord.projections[1].lower.node_id,sameRecord.projections[1].upper.node_id);
check(program('x.items[0 .. 1][1 .. 2]'),[field('R',2,'items'),slice(constant(0),constant(1)),slice(constant(1),constant(2))]);
check(program('x'+'.inner'.repeat(8)),Array.from({length:8},()=>field('R',1,'inner')));
for(const n of [9,64])check(program('x'+'.inner'.repeat(n)),null,'projection-depth-exceeded');
for(const expr of ['lo + 1','bound(lo)','x.items[lo]'])check(program(expr),null,'unnameable-place');
const shadow=check(program('x',{shadow:true}),[]);assert.notEqual(shadow.base_binding_id,base.base_binding_id);
const original=check(program('x.a'),[field('R',0,'a')]);
const rename=program('x.b',{types:'type R = { b: Int, inner: R, items: List[Int] }\n'});
const renamed=check(rename,[field('R',0,'b')]);assert.equal(renamed.id,original.id);assert.equal(renamed.canonical_bytes,original.canonical_bytes);
check(program('x.inner.leaf',{types:'type R = { a: Int, inner: S, items: List[Int] }\ntype S = { leaf: Int }\n'}),[field('R',1,'inner'),field('S',0,'leaf')]);

const localBound=program('x.items[low .. hi]',{locals:' let low = bound(lo)\n'});
check(localBound,[field('R',2,'items'),slice(boundNode(localBound,'low'),boundNode(localBound,'hi',localBound.expr.indexOf('..')+2))]);
for(const [init,projection] of [['R(1, x, [1, 2])',[field('R',0,'a')]],['R(1, x, [])',[field('R',0,'a')]]]) {
 const local=program('value.a',{locals:` let value = ${init}\n`});local.baseBinding=4;local.baseName='value';check(local,projection);
}
for(const init of ['[1,2]','[]']) {
 const local=program('items[0 .. 1]',{locals:` let items = ${init}\n`});local.baseBinding=4;local.baseName='items';check(local,[slice(constant(0),constant(1))]);
}
const trailingList=program('items[0 .. 1]',{locals:' let items = [1,2,]\n'});
trailingList.baseBinding=4;trailingList.baseName='items';check(trailingList,[slice(constant(0),constant(1))]);
console.log('PASS: independent complete lifecycle/place/unknown identity and byte oracle; nested owner transitions, shadows, displays, dynamic occurrences, all i64 bytes and depth 8/9/64');
function negative(test,pattern,{start=test.start,end=test.end,task='0',logicalPath=logical}={}) {
 const input=path.join(work,`${serial++}-refusal.kofun`);fs.writeFileSync(input,test.source);
 let message;
 for(const binary of new Set([native,optimized,sanitized,production])){
  const output=`${input}.${path.basename(binary)}.json`;fs.writeFileSync(output,'prior complete artifact\n');
  const r=run(binary,['--emit-place-hir-v2',input,output,logicalPath,task,String(start),String(end)]);
  assert.notEqual(r.status,0,`${test.expr}: accepted`);assert.equal(r.stderr,'');assert.match(r.stdout,pattern);message??=r.stdout;assert.equal(r.stdout,message);assert.equal(fs.readFileSync(output,'utf8'),'prior complete artifact\n');
 }
 const output=`${input}.kofun.json`;fs.writeFileSync(output,'prior complete artifact\n');
 const k=kofunEmit(input,output,logicalPath,task,start,end);assert.notEqual(k.status,0);assert.equal(k.stdout,message);assert.equal(fs.readFileSync(output,'utf8'),'prior complete artifact\n');
 if(task==='0'&&logicalPath===logical&&start===test.start&&end===test.end)assert.equal(direct(test)+'\n',message);
}
for(const expr of ['x + 1','x.missing','x.a.inner','x.items[true .. hi]','x.items[bound(true) .. hi]','x.items[lo / hi .. hi]','x.items[true]','x.items[1.0 .. hi]','x.items["bad"]'])negative(program(expr),/checked place:/);
for(const expr of ['bound(,lo)','bound(lo,,)','bound(lo, # keep the comma visible\n ,)','bound(bound(lo,,))','x.items[bound(lo,,) .. hi]'])negative(program(expr),/error\[E2S182\]: argument list has an empty argument/);
for(const init of ['bound(lo,,)','bound(,lo)'])negative(program('low',{locals:` let low = ${init}\n`}),/error\[E2S182\]: argument list has an empty argument/);
for(const init of ['[,1]','[1,,]'])negative(program('items[0 .. 1]',{locals:` let items = ${init}\n`}),/error\[E2S182\]: List\[Int\] literal has an empty element/);
for(const expr of ['fn() => bound(true)','fn() => lo','(fn() => bound(true))'])negative(program(expr),/lambda literals require checked-body analysis/);
for(const init of ['bound(true)','true','bound(lo) + true'])negative(program('x.items[low .. hi]',{locals:` let low = ${init}\n`}),/checked place:/);
negative(program('x'+'.inner'.repeat(65)),/candidate projection limit is 64/);
negative(program('x.items[2 .. 1]'),/constant lower bound exceeds upper bound/);
negative(program('x.items[-1 .. -2]'),/constant lower bound exceeds upper bound/);
negative(program('x.items[9223372036854775808 .. hi]'),/integer bound exceeds signed i64/);
negative(program('x.items[-9223372036854775809 .. hi]'),/integer bound exceeds signed i64/);
negative(program('x.items[9_223_372_036_854_775_808 .. hi]'),/integer bound exceeds signed i64/);
negative(program('x.items[ .. hi]'),/empty slice bound/);
negative(program('x.items[lo .. ]'),/empty slice bound/);
for(const expr of ['x +','x.items[lo .. hi .. hi]','x.items[lo + .. hi]','x inner'])negative(program(expr),/malformed expression|multiple slice separators|complete expression/);
negative(program('x.missing'+'.inner'.repeat(64)),/candidate projection limit is 64/);
negative(program('x.a',{types:'type R = { a: List[Missing] }\n'}),/unresolved field type/);
negative(program('x.a',{types:'type R = { a: Int, a: Int }\n'}),/duplicate field/);
const t=program('x.inner.a');
negative(t,/task index is outside/,{task:'1'});
negative(t,/canonical unsigned u32/,{task:'-1'});
negative(t,/canonical unsigned u32/,{task:'00'});
negative(t,/canonical unsigned u32/,{start:'4294967296'});
negative(t,/outside the task body/,{start:0});
negative(t,/complete token boundaries/,{start:t.start+3});
negative(t,/complete token boundaries/,{end:t.end-3});
negative(t,/logical path must/,{logicalPath:'../bad.kofun'});
console.log('PASS: strict O0/O2/repeat/ASan/UBSan, complete C/Kofun output, deterministic invalid ranges/types/bounds and prior-artifact preservation');
console.log(`concurrency-places work: ${work}`);
