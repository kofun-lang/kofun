import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler,bytes,text,HostOperationError} from '../../../bootstrap/stage2/host-driver.mjs';
import {buildScopeHir,canonicalJson,validateScopeHir} from '../../../spec/concurrency/scoped-captures-v1/model.mjs';
import {sourceExpected,identities,normalizeCaptures,raw,uint,framedHash,maximumRecordsFixture} from './oracle.mjs';

const root=fileURLToPath(new URL('../../../',import.meta.url));
const fixtures=JSON.parse(fs.readFileSync(new URL('./cases.json',import.meta.url),'utf8'));
assert.equal(fixtures.schema,'kofun.direct-capture-source-fixtures/v1');
// The ordinary corpus shares one interpreter. Only the full-cardinality
// call needs a child process because synchronous Kofun cannot self-timeout.
if(process.argv[2]==='--full-canonical-child'){
    assert.equal(process.argv.length,7);
    const [input,output,logical,driver]=process.argv.slice(3);
    let printed='';
    const side=loadCompiler({print(value){printed+=text(value)+'\n';},validate(value){
        const unicode=`${output}.unicode-input.kofun`;
        fs.writeFileSync(unicode,Buffer.from(value,'latin1'));
        const result=spawnSync(driver,['--validate',unicode],{cwd:root,encoding:'utf8',timeout:10000,maxBuffer:1024*1024});
        if(result.error)throw result.error;
        assert.equal(result.status,0,result.stderr);assert.equal(result.stderr,'');
        return bytes(result.stdout.trimEnd());
    }});
    assert.equal(typeof side.emit_capture_hir_v2_file,'function');
    const ok=side.emit_capture_hir_v2_file(bytes(input),bytes(output),bytes(logical));
    process.stdout.write(printed);process.exit(ok?0:1);
}
assert(process.argv.slice(2).every(arg=>arg==='--oracle-only'),'unknown gate argument');
const oracleOnly=process.argv.includes('--oracle-only');
for(const [name,code] of [['take-partial-field','E2S122'],['use-after-take','E2S123'],['nested-duplicate-parameters','E2S47'],['call-unknown-label','E2S162'],['call-duplicate-label','E2S163'],['call-missing-argument','E2S164']])assert.equal(fixtures.negative.find(test=>test.name===name)?.diagnostic_code,code,`${name}: frozen diagnostic obligation`);
for(const name of ['lambda-after-take','task-local-lambda-after-take','spawn-after-parent-take'])assert.equal(fixtures.negative.find(test=>test.name===name)?.diagnostic_code,'E2S123',`${name}: inherited moved state must refuse`);
const expected=new Map();
for(const test of fixtures.positive){
    const {document,modelInput}=sourceExpected(test,fixtures.logical_path);
    assert.deepEqual(document,buildScopeHir(modelInput),`${test.name}: independent normalization vs accepted model`);
    assert.equal(validateScopeHir(document),true);
    expected.set(test.name,canonicalJson(document));
}
const maximum=maximumRecordsFixture(fixtures.full_boundary);
const maxExpected=sourceExpected(maximum,fixtures.logical_path);
assert.deepEqual(maxExpected.document,buildScopeHir(maxExpected.modelInput));
assert.equal(validateScopeHir(maxExpected.document),true);
for(const [kind,count] of [['par',64],['task',64],['join',64],['place',0],['unknown',4096],['capture',4096]])assert.equal(maxExpected.document.records.filter(r=>r.record===kind).length,count,`full boundary: ${kind}`);
assert.equal(maxExpected.document.records.length,8384);
assert.equal(new Set(maxExpected.document.records.map(r=>r.id)).size,8384);
expected.set(maximum.name,canonicalJson(maxExpected.document));
const records=(name,kind)=>JSON.parse(expected.get(name)).records.filter(r=>r.record===kind);
assert.equal(records('read-edit-join','capture').find(r=>r.mode==='edit').origins.length,2);
assert.equal(records('nominal-whole-read-take','capture')[0].mode,'take');
assert.equal(records('whole-versus-field','capture').length,2);
assert.equal(records('local-depth-nine-filtered','unknown').length,0);
assert.equal(records('all-local-no-captures','capture').length,0);
assert.deepEqual(JSON.parse(expected.get('lambda-before-take')).records,[]);
assert.deepEqual(JSON.parse(expected.get('task-local-lambda-before-take')).records.map(record=>record.record),['par','task','join']);
assert.equal(records('32-sequential-branch-joins','capture')[0].origins.length,64);
assert.equal(records('300-local-reads-zero-observations','capture').length,0);
assert.equal(records('local-receivers-external-bounds-256','unknown').length,0);
assert.equal(records('local-receivers-external-bounds-256','capture').length,1);
assert.equal(records('local-receivers-external-bounds-256','capture')[0].origins.length,256);
assert.equal(records('captures-64','capture').length,64);
assert.equal(records('observations-256','capture')[0].origins.length,256);
assert.equal(records('tasks-64-across-two-pars','task').length,64);
assert.equal(Math.max(...records('eight-dynamic-slices-574-bytes','place').map(p=>raw(p.canonical_bytes).length)),574);
// Separately isolate the serialized-origin bound, which a source observation
// limit normally rejects before the serializer ever sees 257 distinct origins.
const origins257=JSON.parse(expected.get('observations-256'));
const capture=origins257.records.find(r=>r.record==='capture');
capture.origins.push({node_id:framedHash('independent-origin-limit-control',uint(257,4)),span:{start:100000,end:100001}});
assert.throws(()=>validateScopeHir(origins257),/origin|array|limit/);
const sample=fixtures.positive.find(t=>t.name==='repeated-read');
const ids=identities(fixtures.logical_path),sampleTask=records(sample.name,'task')[0];
const repeated={mode:'read',target:{kind:'place',base_binding_id:ids.named('binding',1),projections:[],display:{disclosure:'visible',text:'outer'}},origin:{node_id:ids.expression([66,71]),span:{start:66,end:71}}};
assert.throws(()=>normalizeCaptures([{id:sampleTask.id,observations:Array(257).fill(repeated)}]),e=>e.code==='observation-limit');
console.log(`PASS: ${fixtures.positive.length} authored source expectations and full8384 boundary match the independent byte/merge oracle and accepted model`);
if(oracleOnly){
    console.log('Oracle-only preparation: production capture output was not tested.');
    process.exit(0);
}

const parent=path.join(root,'build',process.env.KOFUN_GATE_WORK_NAMESPACE??'','concurrency-captures-direct');
fs.mkdirSync(parent,{recursive:true});
const work=fs.mkdtempSync(path.join(parent,'run-'));
function run(command,args,options={}){
    const result=spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:32*1024*1024,...options});
    if(result.error)throw result.error;
    return result;
}
function compile(name,flags,cc=process.env.CC||'cc'){
    const output=path.join(work,name);
    const result=run(cc,['-std=c11',...flags,'-Wall','-Wextra','-Werror','-pedantic','tests/concurrency/captures-direct/driver.c','-o',output]);
    assert.equal(result.status,0,result.stderr);
    return output;
}
let printed='';
let native;
const compiler=loadCompiler({
    print(value){printed+=text(value)+'\n';},
    validate(value){
        const input=path.join(work,'unicode-input.kofun');
        fs.writeFileSync(input,Buffer.from(value,'latin1'));
        const result=run(native,['--validate',input]);
        assert.equal(result.status,0,result.stderr);
        assert.equal(result.stderr,'');
        return bytes(result.stdout.trimEnd());
    },
});
assert.equal(typeof compiler.emit_capture_hir_v2_file,'function','committed canonical capture file API must exist');
native=compile('O0',['-O0']);
const optimized=compile('O2',['-O2']);
const sanitized=compile('sanitized',['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'],process.env.SANITIZER_CC||'clang');
const binaries=[...new Set([native,optimized,sanitized,process.env.KOFUN_STAGE2_COMPILER||native])];
function kofunEmit(input,output,logical){
    printed='';
    try{return{status:compiler.emit_capture_hir_v2_file(bytes(input),bytes(output),bytes(logical))?0:1,stdout:printed};}
    catch(error){if(!(error instanceof HostOperationError))throw error;return{status:2,stdout:printed+error.message+'\n'};}
}
let serial=0;
function checkOutput(output,want,label){
    const actual=fs.readFileSync(output,'utf8');
    assert.equal(actual,want,label);
    const document=JSON.parse(actual);
    assert.equal(validateScopeHir(document),true);
    assert.equal(canonicalJson(document),actual,`${label}: canonical whole document`);
}
function positive(test,logical=fixtures.logical_path,{full=false}={}){
    const input=path.join(work,`${serial++}-${test.name}.kofun`);
    fs.writeFileSync(input,test.source);
    const want=logical===fixtures.logical_path?expected.get(test.name):canonicalJson(sourceExpected(test,logical).document);
    for(const binary of full?[native]:binaries){
        const output=`${input}.${path.basename(binary)}.json`;
        for(let repeat=0;repeat<(full?1:2);repeat++){
            const result=run(binary,['--emit-capture-hir-v2',input,output,logical]);
            assert.equal(result.status,0,`${test.name}: ${result.stdout}${result.stderr}`);
            assert.equal(result.stdout,'');assert.equal(result.stderr,'');
            checkOutput(output,want,`${test.name}: ${path.basename(binary)} repeat${repeat}`);
        }
    }
    const output=`${input}.kofun.json`;
    if(full){
        // This bounds the host-driver workload, not the language profile.
        // The native command keeps its independent120-second deadline.
        const result=run(process.execPath,[fileURLToPath(import.meta.url),'--full-canonical-child',input,output,logical,native],{timeout:600000});
        assert.equal(result.status,0,`${test.name}: bounded canonical child: ${result.stdout}${result.stderr}`);
        assert.equal(result.stdout,'');assert.equal(result.stderr,'');
        checkOutput(output,want,`${test.name}: bounded canonical file entry`);
        return;
    }
    for(let repeat=0;repeat<(full?1:2);repeat++){
        const result=kofunEmit(input,output,logical);
        assert.equal(result.status,0,`${test.name}: ${result.stdout}`);
        assert.equal(result.stdout,'');
        checkOutput(output,want,`${test.name}: canonical Kofun file entry repeat${repeat}`);
    }
}
for(const test of fixtures.positive)positive(test);
console.log('PASS: complete C O0/O2/ASan/UBSan and canonical Kofun file output, repeated and independently framed');

const sentinel='prior complete capture artifact\n';
function negative(test,logical=fixtures.logical_path){
    const input=path.join(work,`${serial++}-${test.name}.kofun`);
    fs.writeFileSync(input,test.source);
    let message;
    for(const existing of [false,true]){
        for(const binary of binaries){
            const output=`${input}.${path.basename(binary)}.${existing}.json`;
            if(existing)fs.writeFileSync(output,sentinel);
            const result=run(binary,['--emit-capture-hir-v2',input,output,logical]);
            assert.notEqual(result.status,0,`${test.name}: unexpectedly accepted (${test.reason})`);
            assert.equal(result.stderr,'');assert.match(result.stdout,/^error\[(?:E2S[0-9]+\]:|EUNICODE[0-9]+\] at line [0-9]+, column [0-9]+ \(byte [0-9]+\):)/);
            if(test.diagnostic_code){
                assert.match(test.diagnostic_code,/^E2S[0-9]+$/);
                assert.match(result.stdout,new RegExp(`^error\\[${test.diagnostic_code}\\]:`),`${test.name}: established diagnostic class`);
            }
            message??=result.stdout;assert.equal(result.stdout,message,`${test.name}: deterministic native refusal`);
            if(existing)assert.equal(fs.readFileSync(output,'utf8'),sentinel,`${test.name}: prior artifact`);
            else assert(!fs.existsSync(output),`${test.name}: no partial artifact`);
        }
        const output=`${input}.kofun.${existing}.json`;
        if(existing)fs.writeFileSync(output,sentinel);
        const result=kofunEmit(input,output,logical);
        assert.notEqual(result.status,0,`${test.name}: Kofun unexpectedly accepted`);
        assert.equal(result.stdout,message,`${test.name}: exact pair refusal`);
        if(existing)assert.equal(fs.readFileSync(output,'utf8'),sentinel);
        else assert(!fs.existsSync(output),`${test.name}: canonical no partial artifact`);
    }
}
for(const test of fixtures.negative)negative(test);
negative({name:'source-nul',source:sample.source+'\0',reason:'Unicode validation before analysis/publication'});
negative({name:'non-nfc-source',source:sample.source.replaceAll('outer','cafe\u0301'),reason:'Source Unicode remains checked'});
negative({name:'malformed-source',source:sample.source.slice(0,-4),reason:'Truncated source must not produce partial captures'});
for(const logical of ['', '../capture.kofun','https:captures.kofun','src/e\u0301.kofun'])negative({name:'logical-path',source:sample.source,reason:'Inherited logical-path contract'},logical);
positive(sample,'src/capture:日本.kofun');
console.log(`PASS: ${fixtures.negative.length} checked-body/limit refusals and inherited input failures preserve absent/existing destinations`);

// Run the expensive boundary only after the complete smaller semantic corpus.
console.log('Checking the full8384 source boundary once each through C O0 and canonical Kofun.');
const boundaryStarted=Date.now();
positive(maximum,fixtures.logical_path,{full:true});
console.log(`PASS: full64 pars/64 tasks/4096 unknowns/4096 captures in ${Date.now()-boundaryStarted}ms`);
