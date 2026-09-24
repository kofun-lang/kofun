// Production scoped-parallel ownership (#1162) against the accepted model.
//
// Each case is a Kofun source with an authored expectation of what the
// production checker must derive: task step order, capture multisets, parent
// and after-scope actions, handle escapes, and the decision. The gate then
// requires, for every native build and the canonical Kofun half:
//
//   1. identical bytes across O0/O2/ASan+UBSan, repeats and the Kofun half;
//   2. the derived model input equals the authored expectation (up to opaque
//      identities, which are read through the document's own name table);
//   3. the production decision equals `analyzeScopedParallelism` over that
//      same derived input, diagnostic for diagnostic;
//   4. for the eighteen source-expressible model fixtures, the fixture's own
//      step order, captures and decision class.
//
// The model decides; this file restates none of its rules.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler,bytes,text,HostOperationError} from '../../../../bootstrap/stage2/host-driver.mjs';
import {MODEL_SCHEMA,analyzeScopedParallelism} from '../../../../spec/concurrency/scoped-parallelism-v1/model.mjs';
import {view,expectedView} from './normalize.mjs';

const root=fileURLToPath(new URL('../../../../',import.meta.url));
const self=fileURLToPath(import.meta.url);
const corpus=JSON.parse(fs.readFileSync(new URL('./cases.json',import.meta.url),'utf8'));
const entry='--check-scoped-ownership',api='check_scoped_ownership_file';
const fixtureRoot=path.join(root,'spec/concurrency/scoped-parallelism-v1/fixtures');

function run(command,args,options={}){
    const result=spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:600000,maxBuffer:64*1024*1024,...options});
    if(result.error)throw result.error;
    return result;
}

// The canonical Kofun half runs in its own process so one case cannot leak
// interpreter state into the next.
if(process.argv[2]==='--canonical-child'){
    assert.equal(process.argv.length,7);
    const [input,output,logical,driver]=process.argv.slice(3);
    let printed='';
    const compiler=loadCompiler({print:v=>{printed+=text(v)+'\n';},validate(value){
        fs.writeFileSync(output+'.unicode',Buffer.from(value,'latin1'));
        const result=run(driver,['--validate',output+'.unicode']);assert.equal(result.status,0,result.stderr);
        return bytes(result.stdout.trimEnd());
    }});
    assert.equal(typeof compiler[api],'function');
    let status;
    try{status=Number(compiler[api](bytes(input),bytes(output),bytes(logical)));}
    catch(error){if(!(error instanceof HostOperationError))throw error;printed+=error.message+'\n';status=2;}
    process.stdout.write(printed);process.exit(status);
}
assert.equal(process.argv.length,2,'usage: node tests/conformance/concurrency/ownership/check.mjs');
assert.equal(corpus.schema,'kofun.scoped-ownership-cases/v1');

// Every accepted-model fixture is either mirrored by a source case or cannot
// be written as source at all. The two exceptions place a join or a parent
// access at the scope-exit step itself; source has no statement there.
const inexpressible=new Map([
    ['negative/join-at-scope-exit.json','an explicit join is a statement before the closing brace'],
    ['negative/parent-at-scope-exit.json','a parent access is a statement before the closing brace'],
]);
const fixtures=['positive','negative'].flatMap(kind=>fs.readdirSync(path.join(fixtureRoot,kind)).filter(f=>f.endsWith('.json')).map(f=>`${kind}/${f}`)).sort();
const mirrored=new Set(corpus.cases.filter(c=>c.fixture).map(c=>c.fixture));
for(const fixture of fixtures){
    assert(mirrored.has(fixture)!==inexpressible.has(fixture),`${fixture}: mirrored by exactly one source case or listed as inexpressible`);
}
for(const [fixture] of inexpressible){
    const result=analyzeScopedParallelism(JSON.parse(fs.readFileSync(path.join(fixtureRoot,fixture),'utf8')));
    assert.deepEqual(result.diagnostics.map(d=>d.code),['SPV1-INVALID-MODEL'],`${fixture}: model refuses the unwritable input`);
}
console.log(`PASS: ${mirrored.size} model fixtures mirrored by source, ${inexpressible.size} inexpressible as source`);

const parent=path.join(root,'build',process.env.KOFUN_GATE_WORK_NAMESPACE??'','concurrency-ownership');
fs.mkdirSync(parent,{recursive:true});
const work=fs.mkdtempSync(path.join(parent,'run-'));
function compile(name,flags,cc=process.env.CC||'cc'){
    const output=path.join(work,name);
    const result=run(cc,['-std=c11',...flags,'-Wall','-Wextra','-Werror','-pedantic','tests/conformance/concurrency/ownership/driver.c','-o',output]);
    assert.equal(result.status,0,result.stderr);return output;
}
const native=compile('O0',['-O0']),optimized=compile('O2',['-O2']);
const sanitized=compile('sanitized',['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'],process.env.SANITIZER_CC||'clang');
const binaries=[...new Set([native,optimized,sanitized,process.env.KOFUN_STAGE2_COMPILER||native])];

let serial=0;
function invoke(source,logical=corpus.logical_path,{canonical=true,only}={}){
    const input=path.join(work,`${serial++}.kofun`);fs.writeFileSync(input,source);
    const runs=[];
    for(const binary of only??binaries)for(let repeat=0;repeat<2;repeat++){
        const output=`${input}.${runs.length}.json`;
        const result=run(binary,[entry,input,output,logical]);
        runs.push({label:`${path.basename(binary)} repeat ${repeat}`,status:result.status,stdout:result.stdout,stderr:result.stderr,
            document:fs.existsSync(output)?fs.readFileSync(output,'utf8'):null});
    }
    if(canonical){
        const output=`${input}.canonical.json`;
        const result=run(process.execPath,[self,'--canonical-child',input,output,logical,native]);
        runs.push({label:'canonical Kofun',status:result.status,stdout:result.stdout,stderr:result.stderr,
            document:fs.existsSync(output)?fs.readFileSync(output,'utf8'):null});
    }
    const [first]=runs;
    for(const other of runs){
        assert.equal(other.stderr,'',`${other.label}: stderr`);
        assert.deepEqual({status:other.status,stdout:other.stdout,document:other.document},
            {status:first.status,stdout:first.stdout,document:first.document},`${other.label}: byte identity`);
    }
    return {input,...first};
}

// After-scope actions are later parent accesses to a place a task took. The
// model's parent actions end at scope exit, so the gate extends the input:
// implicit joins become explicit at the old exit, in task order, and the
// after-scope actions follow them before a new exit.
function extended(scope,after){
    if(after.length===0)return {schema:MODEL_SCHEMA,scope};
    let step=scope.exit_step;
    const tasks=[...scope.tasks].sort((a,b)=>a.spawn_step-b.spawn_step)
        .map(task=>task.join_step===undefined?{...task,join_step:step++}:task);
    const parent_actions=[...scope.parent_actions,...after.map(action=>({...action,step:step++}))];
    return {schema:MODEL_SCHEMA,scope:{...scope,exit_step:step,tasks,parent_actions}};
}
const codeAt=list=>list.map(d=>`${d.code}@${d.at}`).sort();

// #1163: one registered compiler code per contract class, read from the
// normative table itself so the spec, registry and producer cannot drift.
const specTable=fs.readFileSync(path.join(root,'spec/concurrency/scoped-parallelism-v1.md'),'utf8');
const compilerCodes=new Map([...specTable.matchAll(/^\| `(SPV1-[A-Z-]+)` \| `(E2S[0-9]+)` \|/gm)].map(m=>[m[1],m[2]]));
assert.equal(compilerCodes.size,6,'the §8 table maps six classes');
assert.equal(new Set(compilerCodes.values()).size,6,'six distinct compiler codes');
const registry=fs.readFileSync(path.join(root,'tests/diagnostics/registry.tsv'),'utf8');
for(const code of compilerCodes.values())assert.match(registry,new RegExp(`^${code}\t`,'m'),`${code} is registered`);
// Every message is one of these shapes: lexical task numbers, modes, and
// disclosure-safe places only -- never an identity, path, time or thread.
const PLACE='(?:an unknown place|(?:[A-Za-z_][A-Za-z0-9_]*|<hidden>)(?:\\.(?:[A-Za-z_][A-Za-z0-9_]*|<hidden>)|\\[(?:-?[0-9]+|_)\\.\\.(?:-?[0-9]+|_)\\])*)';
const MODE='(?:read|edit|take)';
const MESSAGES=[
    `scoped tasks #[0-9]+ and #[0-9]+ conflict: ${MODE} ${PLACE} overlaps ${MODE} ${PLACE}`,
    `scoped tasks #[0-9]+ and #[0-9]+ need disjoint places: ${MODE} ${PLACE}, ${MODE} ${PLACE}`,
    `scoped task #[0-9]+ uses ${PLACE} after task #[0-9]+ took ${PLACE}`,
    `scoped task #[0-9]+ uses ${PLACE}, not provably apart from what task #[0-9]+ took`,
    `${MODE} ${PLACE} after scoped task #[0-9]+ took ${PLACE}`,
    `${MODE} ${PLACE} is not provably apart from what scoped task #[0-9]+ took`,
    `${MODE} ${PLACE} conflicts with live ${MODE} ${PLACE} in scoped task #[0-9]+`,
    `${MODE} ${PLACE} is not provably apart from live ${MODE} ${PLACE} in scoped task #[0-9]+`,
    'scoped task #[0-9]+ handle escapes by (?:return|store|capture|pass)',
    'a par has more than 256 parent actions',
].map(shape=>new RegExp(`^${shape}$`));
function checkMessages(name,document,source){
    for(const scope of document.scopes)for(const d of scope.decision.diagnostics){
        assert.equal(d.compiler_code,compilerCodes.get(d.code),`${name}: ${d.code} reports its registered code`);
        assert(MESSAGES.some(shape=>shape.test(d.message)),`${name}: message shape: ${d.message}`);
        assert(Buffer.byteLength(`error[${d.compiler_code}]: ${d.message} at byte ${d.byte}`)<=160,`${name}: 160-byte detail bound`);
    }
    assert(!JSON.stringify(document).includes(root)&&!JSON.stringify(document).includes(work),`${name}: no checkout path`);
    void source;
}

function fixtureView(fixture,taskNames){
    const scope=JSON.parse(fs.readFileSync(path.join(fixtureRoot,fixture),'utf8')).scope;
    const ordered=[...scope.tasks].sort((a,b)=>a.spawn_step-b.spawn_step);
    const names=new Map(ordered.map((task,index)=>[task.id,taskNames[index]]));
    return view({...scope,parent_actions:scope.parent_actions??[]},{taskNames,rename:name=>names.get(name)??name});
}

function checkScope(name,produced,expected,derivation){
    assert.equal(produced.derivation,derivation,`${name}: derivation`);
    assert.equal(produced.decision.diagnostics_truncated,false,`${name}: diagnostics are complete`);
    const names=new Map(produced.names.map(entry=>{
        assert.equal(entry.display.disclosure,'visible',`${name}: single-file names are visible`);
        return [entry.id,entry.display.text];
    }));
    const rename=id=>{assert(names.has(id),`${name}: ${id} has a name table entry`);return names.get(id);};
    const derived=view(produced.model_input.scope,{rename,taskNames:expected.tasks,after:produced.after_scope_actions});
    const authored=expectedView(expected);
    assert.deepEqual(derived,authored,`${name}: derived model input equals the authored expectation`);
    if(produced.decision.status==='not-decided'){
        // Without capture facts, a scope with no escape of its own decides nothing.
        assert.equal(derivation,'lifecycle-only',`${name}: only a lifecycle-only file leaves a scope undecided`);
        assert.deepEqual(produced.decision.diagnostics,[]);assert.equal(expected.status,'not-decided');
        return derived;
    }
    const model=analyzeScopedParallelism(extended(produced.model_input.scope,produced.after_scope_actions));
    assert.equal(produced.decision.status,model.status,`${name}: production status equals the model's`);
    assert.deepEqual(codeAt(produced.decision.diagnostics),codeAt(model.diagnostics),`${name}: production diagnostics equal the model's`);
    assert.equal(produced.decision.status,expected.status,`${name}: authored status`);
    assert.deepEqual([...new Set(produced.decision.diagnostics.map(d=>d.code))].sort(),expected.codes,`${name}: authored classes`);
    return derived;
}

let decided=0,refused=0,fixtureCases=0;
for(const test of corpus.cases){
    if(test.refusal){
        const sentinel='prior scoped ownership artifact\n';
        const result=invoke(test.source);
        assert.equal(result.status,1,`${test.name}: ${test.reason}`);
        assert.match(result.stdout,new RegExp(`^error\\[${test.refusal}\\]: [^\\n]* at byte [0-9]+\\n$`),`${test.name}: ${test.reason}`);
        assert.equal(result.document,null,`${test.name}: no document for a refusal`);
        const kept=path.join(work,`${test.name}.kept.json`);fs.writeFileSync(kept,sentinel);
        const again=run(optimized,[entry,result.input,kept,corpus.logical_path]);
        assert.equal(again.stdout,result.stdout);assert.equal(fs.readFileSync(kept,'utf8'),sentinel,`${test.name}: prior output survives`);
        refused++;continue;
    }
    const result=invoke(test.source);
    assert.notEqual(result.document,null,`${test.name}: ${result.stdout}`);
    assert(!result.document.includes(root)&&!result.document.includes(work),`${test.name}: no checkout path`);
    const document=JSON.parse(result.document);
    assert.equal(`${JSON.stringify(document)}\n`,result.document,`${test.name}: compact document`);
    assert.equal(document.schema,'kofun-scoped-ownership/v1');
    assert.equal(document.profile,'kofun.stage2-analysis/scoped-ownership/v1');
    assert.equal(document.scopes.length,test.scopes.length,`${test.name}: one decision per par`);
    const views=document.scopes.map((scope,index)=>{
        assert.equal(scope.lexical_index,index);
        return checkScope(`${test.name}#${index}`,scope,test.scopes[index],test.derivation??'complete');
    });
    const rejected=document.scopes.find(scope=>scope.decision.status==='rejected');
    assert.equal(document.status,rejected?'rejected':'accepted');
    assert.equal(result.status,rejected?1:0,`${test.name}: exit status`);
    checkMessages(test.name,document,test.source);
    if(rejected){
        const [first]=rejected.decision.diagnostics;
        assert.equal(result.stdout,`error[${first.compiler_code}]: ${first.message} at byte ${first.byte}\n`);
    }else assert.equal(result.stdout,'');
    for(const scope of document.scopes)for(const d of scope.decision.diagnostics){
        assert(d.byte>=0&&d.byte<Buffer.byteLength(test.source),`${test.name}: diagnostic byte inside the source`);
    }
    if(test.fixture){
        const fixture=JSON.parse(fs.readFileSync(path.join(fixtureRoot,test.fixture),'utf8'));
        const model=analyzeScopedParallelism(fixture);
        assert.equal(model.status,test.scopes[0].status,`${test.name}: fixture decision`);
        assert.deepEqual([...new Set(model.diagnostics.map(d=>d.code))].sort(),test.scopes[0].codes,`${test.name}: fixture class`);
        const wanted=fixtureView(test.fixture,test.scopes[0].tasks),got=views[0];
        assert.deepEqual(got.order,wanted.order,`${test.name}: fixture step order`);
        assert.deepEqual(got.escapes,wanted.escapes,`${test.name}: fixture handle uses`);
        for(const [task,captures] of Object.entries(wanted.captures))for(const capture of captures){
            // A slice cannot be taken in source; the unknown a task takes
            // through an unresolved call is the same unprovable relation.
            const target=test.fixture_captures==='unknown-target'&&capture.startsWith('take ')?'take ?':capture;
            assert(got.captures[task].includes(target),`${test.name}: fixture capture ${capture} of ${task}`);
        }
        fixtureCases++;
    }
    // Identity inputs never decide: another logical path renames every
    // FileId-derived identity and must leave the decision and view alone.
    const moved=invoke(test.source,'src/moved/ownership.kofun',{canonical:false,only:[optimized]});
    const other=JSON.parse(moved.document);
    if(/[0-9a-f]{64}/.test(result.document))assert.notEqual(moved.document,result.document,`${test.name}: identities follow the logical path`);
    other.scopes.forEach((scope,index)=>{
        assert.deepEqual(scope.decision,document.scopes[index].decision,`${test.name}: logical path does not decide`);
        const names=new Map(scope.names.map(entry=>[entry.id,entry.display.text]));
        assert.deepEqual(view(scope.model_input.scope,{rename:id=>names.get(id),taskNames:test.scopes[index].tasks,after:scope.after_scope_actions}),views[index]);
    });
    decided++;
}
assert.equal(fixtureCases,mirrored.size);
console.log(`PASS: ${decided} decisions match their authored facts and the model on O0/O2/ASan+UBSan and canonical Kofun, repeated`);
console.log(`PASS: ${refused} refusals leave no document and keep a prior output`);

// The model bounds a scope at 256 parent actions; production reports the
// same class at 257 rather than truncating.
function bounded(count){
    return `fn main() -> Int {\n let mut value: Int = 0\n par |scope| {\n  scope.spawn(fn() => 1)\n${'  value = 1\n'.repeat(count)} }\n return value\n}\n`;
}
for(const [count,status] of [[256,'accepted'],[257,'rejected']]){
    const result=invoke(bounded(count),corpus.logical_path,{canonical:false,only:[optimized]});
    const [scope]=JSON.parse(result.document).scopes;
    const model=analyzeScopedParallelism(extended(scope.model_input.scope,scope.after_scope_actions));
    assert.equal(scope.decision.status,status,`${count} parent actions`);
    assert.equal(model.status,status);
    assert.deepEqual(codeAt(scope.decision.diagnostics),codeAt(model.diagnostics),`${count} parent actions: production equals model`);
    if(status==='rejected')assert.deepEqual(codeAt(scope.decision.diagnostics),['SPV1-INVALID-MODEL@$input.scope.parent_actions']);
}
console.log('PASS: 256 parent actions decide, 257 refuse as SPV1-INVALID-MODEL in production and the model');

// An inaccessible name never reaches a message: a display over 128 bytes is
// hidden in the name table, and the diagnostic says `<hidden>` instead.
{
    const hidden=`value_${'x'.repeat(130)}`;
    const source=`fn bump(edit value: Int) { value = value + 1 }\nfn main() -> Int {\n let mut ${hidden}: Int = 0\n par |scope| {\n  scope.spawn(fn() => ${hidden})\n  scope.spawn(fn() { bump(${hidden}) })\n }\n return 0\n}\n`;
    const result=invoke(source);
    assert.equal(result.status,1);
    assert.equal(result.stdout.includes(hidden),false,'hidden name stays out of the message');
    assert.equal(result.document.includes(hidden),false,'hidden name stays out of the document');
    const document=JSON.parse(result.document);
    checkMessages('hidden-name',document,source);
    assert.match(result.stdout,/^error\[E2S183\]: scoped tasks #0 and #1 conflict: read <hidden> overlaps edit <hidden> at byte [0-9]+\n$/);
}
console.log('PASS: an inaccessible binding name is reported as <hidden>');

// Entry refusals shared with the other analysis entries.
{
    const input=path.join(work,'entry.kofun');fs.writeFileSync(input,corpus.cases.find(c=>c.name==='panic-drain').source);
    const same=run(optimized,[entry,input,input,corpus.logical_path]);
    assert.equal(same.status,1);assert.match(same.stdout,/^error\[E2S35\]: scoped ownership input and output must be distinct\n$/);
    for(const logical of ['','../escape.kofun','/abs.kofun']){
        const result=run(optimized,[entry,input,path.join(work,'entry.json'),logical]);
        assert.equal(result.status,1);assert.match(result.stdout,/^error\[E2S35\]: scoped ownership logical path/);
        assert(!fs.existsSync(path.join(work,'entry.json')));
    }
    const ordinary=run(optimized,['--compile-outcome',input,path.join(work,'entry.c'),path.join(work,'entry.ir'),path.join(work,'entry.tokens')]);
    assert.notEqual(ordinary.status,0);assert.match(ordinary.stdout,/E2S154/,'ordinary compilation still refuses scoped parallelism');
}
console.log('PASS: entry refusals, and ordinary compilation still refuses par with E2S154');

// `kofun check` reports each registered fixture's class, byte for byte, with
// empty stdout; a par the checker accepts keeps the unimplemented refusal.
for(const code of compilerCodes.values()){
    const row=registry.split('\n').find(line=>line.startsWith(`${code}\t`)).split('\t');
    const fixture=row[10].replace(/^file:/,''),golden=row[11].replace(/^file:/,'');
    const result=run('sh',['bin/kofun','check',fixture]);
    assert.equal(result.status,1,`${code}: kofun check exit`);
    assert.equal(result.stdout,'',`${code}: kofun check stdout`);
    assert.equal(result.stderr,fs.readFileSync(path.join(root,golden),'utf8'),`${code}: kofun check reports the registered golden`);
}
{
    const accepted=run('sh',['bin/kofun','check','tests/diagnostics/stage2/e2s154_scoped_parallelism.kofun']);
    assert.equal(accepted.status,1);assert.match(accepted.stderr,/^error\[E2S154\]/);
}
console.log('PASS: kofun check reports each registered E2S183-E2S188 golden; an accepted par still refuses with E2S154');
fs.rmSync(work,{recursive:true,force:true});
