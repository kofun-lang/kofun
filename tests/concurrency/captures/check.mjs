import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadCompiler,bytes,text,HostOperationError} from '../../../bootstrap/stage2/host-driver.mjs';
import {buildScopeHir,canonicalJson,validateScopeHir} from '../../../spec/concurrency/scoped-captures-v1/model.mjs';
import {sourceExpected} from '../captures-direct/oracle.mjs';
const root=fileURLToPath(new URL('../../../',import.meta.url));
const self=fileURLToPath(import.meta.url),fixtures=JSON.parse(fs.readFileSync(new URL('./cases.json',import.meta.url),'utf8'));
const entry='--emit-complete-capture-hir-v2',api='emit_complete_capture_hir_v2_file';
function run(command,args,options={}){
    const result=spawnSync(command,args,{cwd:root,encoding:'utf8',timeout:120000,maxBuffer:32*1024*1024,...options});
    if(result.error)throw result.error;
    return result;
}
function interpreter(driver,unicode,source){
    let printed='';
    const compiler=loadCompiler({...(source===undefined?{}:{source}),print:v=>{printed+=text(v)+'\n';},validate(value){
        fs.writeFileSync(unicode,Buffer.from(value,'latin1'));
        const result=run(driver,['--validate',unicode]);assert.equal(result.status,0,result.stderr);assert.equal(result.stderr,'');
        return bytes(result.stdout.trimEnd());
    }});
    assert.equal(typeof compiler[api],'function');
    return (input,output,logical)=>{
        printed='';
        try{return {status:compiler[api](bytes(input),bytes(output),bytes(logical))?0:1,stdout:printed,stderr:''};}
        catch(error){if(!(error instanceof HostOperationError))throw error;return {status:2,stdout:printed+error.message+'\n',stderr:''};}
    };
}
// Every canonical invocation, including cyclic sources, has an independent
// wall-time bound. A timeout is failure, never a semantic limit/refusal.
if(process.argv[2]==='--canonical-child'){
    assert.equal(process.argv.length,7);
    const [input,output,logical,driver]=process.argv.slice(3);
    const result=interpreter(driver,output+'.unicode')(input,output,logical);
    process.stdout.write(result.stdout);process.exit(result.status);
}
assert(process.argv.slice(2).every(x=>x==='--oracle-only'),'unknown gate argument');
assert.equal(fixtures.schema,'kofun.complete-capture-source-fixtures/v1');
const expected=new Map();
for(const test of fixtures.positive){
    const {document,modelInput}=sourceExpected(test,fixtures.logical_path);
    assert.deepEqual(document,buildScopeHir(modelInput),`${test.name}: independent framing/normalization vs accepted model`);
    assert.equal(validateScopeHir(document),true);expected.set(test.name,canonicalJson(document));
}
const records=(name,kind)=>JSON.parse(expected.get(name)).records.filter(r=>r.record===kind);
assert.equal(records('complete-observations-256','capture')[0].origins.length,256);
assert.equal(records('complete-captures-64','capture').length,64);
assert.equal(records('scc-permuted-formals-two-field-effects','place').filter(p=>p.projections.length).length,2);
assert.equal(records('identical-dynamic-call-text-distinct-bound-occurrences','place').filter(p=>p.projections.length).length,2);
assert.equal(records('diamond-unavailable-sites-rewitness-at-each-outer-call','unknown').length,2);
for(const capture of records('diamond-unavailable-sites-rewitness-at-each-outer-call','capture').filter(c=>c.target_kind==='unknown')){
    assert.equal(capture.mode,'take');assert.equal(capture.origins.length,1);
}
assert.equal(records('composed-projection-depth-9','unknown')[0].reason,'projection-depth-exceeded');
assert.equal(records('aliased-formals-one-call-target','capture').find(c=>c.origins.length===1).mode,'read');
console.log(`PASS: ${fixtures.positive.length} independently authored whole expectations match the accepted capture model`);
if(process.argv.includes('--oracle-only')){
    console.log('Oracle preparation only; production complete-capture output was not tested.');process.exit(0);
}
const parent=path.join(root,'build',process.env.KOFUN_GATE_WORK_NAMESPACE??'','concurrency-captures');fs.mkdirSync(parent,{recursive:true});
const work=fs.mkdtempSync(path.join(parent,'run-'));
function compile(name,flags,cc=process.env.CC||'cc',source){
    const output=path.join(work,name),args=['-std=c11',...flags,'-Wall','-Wextra','-Werror','-pedantic'];
    if(source===undefined)args.push('tests/concurrency/captures/driver.c');
    else{
        const input=path.join(work,name+'.c');fs.writeFileSync(input,source);args.push('-Ibootstrap/stage2',input);
    }
    const result=run(cc,[...args,'-o',output]);assert.equal(result.status,0,result.stderr);return output;
}
const native=compile('O0',['-O0']),optimized=compile('O2',['-O2']);
const sanitized=compile('sanitized',['-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'],process.env.SANITIZER_CC||'clang');
const binaries=[...new Set([native,optimized,sanitized,process.env.KOFUN_STAGE2_COMPILER||native])];
let serial=0;
function canonical(input,output,logical){return run(process.execPath,[self,'--canonical-child',input,output,logical,native]);}
function outputEquals(output,wanted,label){
    const actual=fs.readFileSync(output,'utf8');assert.equal(actual,wanted,label);
    const document=JSON.parse(actual);assert.equal(validateScopeHir(document),true);assert.equal(canonicalJson(document),actual);
}
function positive(test,logical=fixtures.logical_path){
    const input=path.join(work,`${serial++}-${test.name}.kofun`);fs.writeFileSync(input,test.source);
    const wanted=logical===fixtures.logical_path?expected.get(test.name):canonicalJson(sourceExpected(test,logical).document);
    for(const binary of binaries)for(let repeat=0;repeat<2;repeat++){
        const output=input+'.'+path.basename(binary)+'.json',result=run(binary,[entry,input,output,logical]);
        assert.equal(result.status,0,`${test.name}: ${result.stdout}${result.stderr}`);assert.equal(result.stdout,'');assert.equal(result.stderr,'');
        outputEquals(output,wanted,`${test.name}: native repeat ${repeat}`);
    }
    for(let repeat=0;repeat<2;repeat++){
        const output=input+'.canonical.json',result=canonical(input,output,logical);
        assert.equal(result.status,0,`${test.name}: ${result.stdout}${result.stderr}`);assert.equal(result.stdout,'');assert.equal(result.stderr,'');
        outputEquals(output,wanted,`${test.name}: canonical repeat ${repeat}`);
    }
}
for(const test of fixtures.positive)positive(test);
console.log('PASS: complete native O0/O2/ASan/UBSan and canonical Kofun repeated whole documents');
const sentinel='prior complete capture artifact\n';
function negative(test,logical=fixtures.logical_path){
    const input=path.join(work,`${serial++}-${test.name}.kofun`);fs.writeFileSync(input,test.source);let message;
    const invoke=[...binaries.map(binary=>(input,output,logical)=>run(binary,[entry,input,output,logical])),canonical];
    for(const existing of [false,true])for(const [index,emit] of invoke.entries()){
        const output=input+`.${index}.${existing}.json`;if(existing)fs.writeFileSync(output,sentinel);
        const result=emit(input,output,logical);assert.equal(result.signal??null,null,result.stderr);assert.notEqual(result.status,0,`${test.name}: ${test.reason}`);assert.equal(result.stderr,'');
        assert.match(result.stdout,/^error\[(?:E2S[0-9]+\]:|EUNICODE[0-9]+\] at line [0-9]+, column [0-9]+ \(byte [0-9]+\):)/);
        if(test.diagnostic_code)assert.match(result.stdout,new RegExp(`^error\\[${test.diagnostic_code}\\]:`));
        message??=result.stdout;assert.equal(result.stdout,message,`${test.name}: deterministic pair refusal`);
        if(existing)assert.equal(fs.readFileSync(output,'utf8'),sentinel);else assert(!fs.existsSync(output));
    }
}
for(const test of fixtures.negative)negative(test);
const sample=fixtures.positive.find(t=>t.name==='same-unit-field-effect');
negative({name:'nul',source:sample.source+'\0',reason:'Unicode before summary publication'});
negative({name:'non-nfc',source:sample.source.replaceAll('outer','cafe\u0301'),reason:'source Unicode'});
negative({name:'malformed',source:sample.source.slice(0,-4),reason:'source parse refusal'});
for(const logical of ['', '../capture.kofun','https:captures.kofun','src/e\u0301.kofun'])negative({name:'path',source:sample.source,reason:'logical path'},logical);
positive(sample,'src/capture:日本.kofun');
console.log(`PASS: ${fixtures.negative.length} checked summary/source limits and inherited input refusals preserve absent/sentinel outputs`);

// Independent source expectations must reject a producer that drops a formal
// effect, binds every actual to slot zero, omits unavailable calls or reuses a
// different bound occurrence. Lowered private work/sweep guards separately
// prove that exhaustion refuses before touching a prior destination.
const kSource=fs.readFileSync(path.join(root,'bootstrap/stage2/compiler.kofun'),'utf8');
const cSource=fs.readFileSync(path.join(root,'bootstrap/stage2/compiler.c'),'utf8');
function changeFunction(source,name,before,after,language){
    const pattern=language==='K'?new RegExp(`^fn ${name}\\([^]*?^\\}`,'m'):new RegExp(`^static [^\\n]* ${name}\\([^\\n]*\\) \\{\\n[^]*?^\\}`,'m');
    const match=source.match(pattern);assert(match,`${name}: function anchor`);
    assert.equal(match[0].split(before).length-1,1,`${name}: unique mutation anchor`);
    return source.slice(0,match.index)+match[0].replace(before,after)+source.slice(match.index+match[0].length);
}
const controls=[
    ['missing-formal-effect','summary_callable_seeds','let slot = summary_parameter_slot(parameters, open, binding)','let slot = -1',
        'int64_t v_slot = summary_parameter_slot(a, v_parameters, v_open, v_binding);','int64_t v_slot = -1;','same-unit-field-effect'],
    ['wrong-actual-slot','summary_instance','summary_argument(facts, call_start, slot)','summary_argument(facts, call_start, 0)',
        'summary_argument(a, v_facts, v_call_start, v_slot)','summary_argument(a, v_facts, v_call_start, 0)','labelled-formal-field-substitution'],
    ['missing-unavailable-call','summary_call_instances','"instance||unavailable|take|0|||\\n"','""',
        '"instance||unavailable|take|0|||\\n"','""','typed-unavailable-call'],
    ['wrong-bound-occurrence','summary_bound','checked_place_expression_id(scoped_hir_file_id(path), first, last)','checked_place_expression_id(scoped_hir_file_id(path), first + 1, last)',
        'cp_expression_id(a, cp_keep(a, scoped_hir_file_id(v_path)), v_first, v_last)','cp_expression_id(a, cp_keep(a, scoped_hir_file_id(v_path)), v_first + 1, v_last)','formal-bounds-substitute-occurrences'],
    ['substitution-work-exhausted','summary_solve','work > 1048576','work > 0','v_work > 1048576','v_work > 0','same-unit-field-effect',true],
    ['fixed-point-sweep-exhausted','summary_solve','sweep < 256','sweep < 1','v_sweep < 256','v_sweep < 1','three-function-field-chain',true],
];
for(const [name,fn,kBefore,kAfter,cBefore,cAfter,testName,refusal] of controls){
    const test=fixtures.positive.find(t=>t.name===testName);assert(test);
    const input=path.join(work,`control-${name}.kofun`);fs.writeFileSync(input,test.source);
    const k=changeFunction(kSource,fn,kBefore,kAfter,'K'),c=changeFunction(cSource,fn,cBefore,cAfter,'C');
    const binary=compile(`control-${name}`,['-O0'],process.env.CC||'cc',c);
    const emitK=interpreter(native,input+'.unicode',k);
    let message;
    for(const [label,emit] of [['C',(input,output,logical)=>run(binary,[entry,input,output,logical])],['K',emitK]]){
        const output=input+'.'+label+'.json';fs.writeFileSync(output,sentinel);
        const result=emit(input,output,fixtures.logical_path);assert.equal(result.stderr,'');
        if(refusal){
            assert.equal(result.status,1);assert.match(result.stdout,/^error\[E2S154\]: checked capture: call summary:/);message??=result.stdout;assert.equal(result.stdout,message);
            assert.equal(fs.readFileSync(output,'utf8'),sentinel,`${name}: fail closed`);
        }else{
            assert.equal(result.status,0,result.stdout);assert.equal(result.stdout,'');
            assert.notEqual(fs.readFileSync(output,'utf8'),expected.get(testName),`${name}: independent oracle must catch the defect`);
        }
    }
}
console.log('PASS: four semantic mutations caught in both producers; work/sweep exhaustion refuses transactionally');
