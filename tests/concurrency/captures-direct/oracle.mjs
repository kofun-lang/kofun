// Independent source-fixture oracle for authored checked facts and ordinals.
// No compiler implementation or normative model is imported here.
import { createHash } from 'node:crypto'

export const LIMITS={document_bytes:16777216,pars:64,tasks:64,capture_observations_per_task:256,captures_per_task:64,origins_per_capture:256,projection_depth:8,candidate_projection_depth:64,records:8384,display_bytes:128}
export const display=text=>text!==null&&Buffer.byteLength(text)<=128?{disclosure:'visible',text}:{disclosure:'hidden',text:null}

export class OracleRefusal extends Error {
    constructor(code) { super(code); this.code=code }
}
const refuse=code=>{throw new OracleRefusal(code)}
const rank={read:0,edit:1,take:2}
const reasonTag={'unresolved-call':1,'projection-depth-exceeded':2,'unnameable-place':3}
export const raw=id=>Buffer.from(id,'hex')
export function uint(value,width){
    let n=BigInt(value);const b=Buffer.alloc(width)
    for(let index=width-1;index>=0;index--){b[index]=Number(n&255n);n>>=8n}
    return b
}
export function framedHash(domain,payload){
    const d=Buffer.from(domain,'utf8')
    return createHash('sha256').update(Buffer.concat([Buffer.from([75,79,70,85,78,0]),uint(d.length,2),d,uint(payload.length,4),payload])).digest('hex')
}
const validId=id=>typeof id==='string'&&/^[0-9a-f]{64}$/.test(id)&&!/^0+$/.test(id)
const checkedId=id=>validId(id)?raw(id):refuse('invalid-id')
function boundBytes(bound){
    if(bound.kind==='node')return Buffer.concat([Buffer.from([2]),checkedId(bound.node_id)])
    if(bound.kind!=='constant'||typeof bound.value!=='string'||!/^(-?[1-9][0-9]*|0)$/.test(bound.value))refuse('invalid-bound')
    const value=BigInt(bound.value)
    if(value<-(1n<<63n)||value>=(1n<<63n))refuse('invalid-bound')
    return Buffer.concat([Buffer.from([1]),uint(value,8)])
}
export function canonicalPlace(place){
    if(place.projections.length>8)refuse('known-depth')
    const projections=place.projections.map(p=>{
        if(p.kind==='field'){
            if(!Number.isInteger(p.ordinal)||p.ordinal<0||p.ordinal>0xffffffff)refuse('field-ordinal')
            return Buffer.concat([Buffer.from([1]),checkedId(p.owner_type_id),uint(p.ordinal,4)])
        }
        if(p.kind!=='slice')refuse('projection-kind')
        if(p.lower.kind==='constant'&&p.upper.kind==='constant'&&BigInt(p.lower.value)>BigInt(p.upper.value))refuse('inverted-slice')
        return Buffer.concat([Buffer.from([2]),boundBytes(p.lower),boundBytes(p.upper)])
    })
    return Buffer.concat([Buffer.from([75,80,76,0,2]),checkedId(place.base_binding_id),uint(projections.length,1),...projections])
}
export const originOrder=(a,b)=>a.span.start-b.span.start||a.span.end-b.span.end||Buffer.compare(raw(a.node_id),raw(b.node_id))
function checkedOrigin(origin){
    checkedId(origin.node_id)
    if(!Number.isInteger(origin.span.start)||!Number.isInteger(origin.span.end)||origin.span.start<0||origin.span.start>=origin.span.end||origin.span.end>0xffffffff)refuse('origin-span')
}
function targetFor(taskId,observation){
    const target=observation.target
    if(target.kind==='place'&&target.projections.length<=8){
        const bytes=canonicalPlace(target)
        return {kind:'place',id:framedHash('kofun.scope-hir.place/v2',bytes),canonical_bytes:bytes.toString('hex'),base_binding_id:target.base_binding_id,projections:structuredClone(target.projections),display:structuredClone(target.display)}
    }
    if(target.kind==='place'&&target.projections.length>64)refuse('candidate-depth')
    const reason=target.kind==='place'?'projection-depth-exceeded':target.reason
    if(!reasonTag[reason])refuse('unknown-reason')
    const payload=Buffer.concat([checkedId(taskId),uint(reasonTag[reason],1),checkedId(observation.origin.node_id)])
    return {kind:'unknown',id:framedHash('kofun.scope-hir.unknown/v2',payload),task_id:taskId,reason,witness_node_id:observation.origin.node_id,canonical_bytes:Buffer.concat([Buffer.from([75,85,78,0,2]),payload]).toString('hex')}
}
export const captureId=(taskId,kind,targetId)=>framedHash('kofun.scope-hir.capture/v2',Buffer.concat([checkedId(taskId),uint(kind==='place'?1:2,1),checkedId(targetId)]))

// Tasks are in their already-checked lexical order. This function deliberately
// does not parse source, choose operation spans or decide task-local filtering.
export function normalizeCaptures(tasks){
    if(tasks.length>64)refuse('task-limit')
    const spans=new Map(),targets=new Map(),captures=[]
    for(const task of tasks){
        checkedId(task.id)
        if(task.observations.length>256)refuse('observation-limit')
        const groups=new Map()
        for(const observation of task.observations){
            if(!Object.hasOwn(rank,observation.mode))refuse('mode')
            checkedOrigin(observation.origin)
            const previous=spans.get(observation.origin.node_id)
            const committed=`${observation.origin.span.start}:${observation.origin.span.end}`
            if(previous!==undefined&&previous!==committed)refuse('origin-span-conflict')
            spans.set(observation.origin.node_id,committed)
            const target=targetFor(task.id,observation),key=`${target.kind}:${target.id}`
            const earlier=targets.get(key)
            if(earlier&&earlier.canonical_bytes!==target.canonical_bytes)refuse('identity-collision')
            if(!earlier||target.kind==='unknown')targets.set(key,target)
            else {
                const order=originOrder(observation.origin,earlier.first_origin)
                const presentation=t=>JSON.stringify([t.display,t.projections])
                if(order===0&&presentation(earlier)!==presentation(target))refuse('display-conflict')
                if(order<0)targets.set(key,target)
            }
            if(target.kind==='place'&&targets.get(key)===target)target.first_origin=structuredClone(observation.origin)
            if(!groups.has(key))groups.set(key,{record:'capture',id:captureId(task.id,target.kind,target.id),task_id:task.id,target_kind:target.kind,target_id:target.id,mode:observation.mode,origins:new Map(),bytes:target.canonical_bytes})
            const group=groups.get(key)
            if(rank[observation.mode]>rank[group.mode])group.mode=observation.mode
            group.origins.set(observation.origin.node_id,structuredClone(observation.origin))
            if(group.origins.size>256)refuse('origin-limit')
        }
        if(groups.size>64)refuse('capture-limit')
        const ordered=[...groups.values()].sort((a,b)=>Buffer.compare(raw(a.bytes),raw(b.bytes))||rank[a.mode]-rank[b.mode])
        for(const {bytes,origins,...group} of ordered)captures.push({...group,origins:[...origins.values()].sort(originOrder)})
    }
    const list=[...targets.values()].map(({first_origin,...target})=>target)
    const places=list.filter(t=>t.kind==='place').sort((a,b)=>Buffer.compare(raw(a.canonical_bytes),raw(b.canonical_bytes))).map(({kind,...record})=>({...record,record:'place'}))
    const unknowns=list.filter(t=>t.kind==='unknown').sort((a,b)=>Buffer.compare(raw(a.canonical_bytes),raw(b.canonical_bytes))).map(({kind,...record})=>({...record,record:'unknown'}))
    return {places,unknowns,captures}
}

// Source fixture rows freeze resolver numbers and source byte ranges; they
// never consume compiler HIR/output. #1220 §11 fixes the allocator order and
// #1221 §12 fixes the analysis-expression/nominal identity encodings.
export function identities(logical){
    const pkg=`kofun.package-id/v1\nkind=anonymous-single-file\nlogical-source=${logical}\n`
    const file=framedHash('kofun.id.file/v1',Buffer.from(`kofun.file-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nlogical-path=${logical}\nsource-role=authored\nprovenance=explicit-source\n`))
    const module=framedHash('kofun.id.module/v1',Buffer.from(`kofun.module-id-input/v1\npackage-payload-begin\n${pkg}package-payload-end\nkind=synthetic-root\n`))
    const namespace=framedHash('kofun.id.namespace/v1',Buffer.from('kofun.namespace-id/v1\ntag=1\nname=type\n'))
    const tlv=(tag,value)=>Buffer.concat([uint(tag,2),uint(value.length,4),value])
    return{file,
        named:(kind,n)=>framedHash(`kofun.stage2.${kind}/v1`,Buffer.concat([raw(file),Buffer.from(`hir-${kind}:${n}`)])),
        node:(kind,[start,end])=>framedHash('kofun.sidecar.node/v1',Buffer.concat([raw(file),uint(kind,1),uint(start,4),uint(end,4),uint(0,4)])),
        expression:([start,end])=>framedHash('kofun.stage2.analysis-expression/v1',Buffer.concat([raw(file),uint(start,4),uint(end,4)])),
        type:name=>framedHash('kofun.id.symbol/v1',Buffer.concat([tlv(0x8001,raw(module)),tlv(0x8002,raw(namespace)),tlv(0x8003,Buffer.from('record')),tlv(0x8004,Buffer.from(name))]))}
}
export function sourceExpected(test,logical){
    const ids=identities(logical),source=Buffer.from(test.source)
    const span=(range,text)=>{
        if(!Array.isArray(range)||range.length!==2||range[0]<0||range[0]>=range[1]||range[1]>source.length)refuse('fixture-span')
        if(text!==undefined&&source.subarray(...range).toString()!==text)refuse('fixture-spelling')
        return range
    }
    const pars=test.pars.map((p,index)=>{
        span(p.span);const scope=ids.named('scope',p.scope),node=ids.node(4,p.span)
        return{record:'par',id:framedHash('kofun.scope-hir.par/v2',Buffer.concat([raw(ids.file),raw(scope),raw(node)])),node_id:node,scope_id:scope,parent_scope_id:ids.named('scope',0),scope_token_binding_id:ids.named('binding',p.token),lexical_index:index,display:display(p.name)}
    })
    const indexes=new Map()
    const tasks=test.tasks.map(t=>{
        span(t.span);span(t.lambda_span)
        const index=indexes.get(t.par)??0;indexes.set(t.par,index+1)
        const par=pars[t.par],spawn=ids.node(8,t.span),lambda=ids.node(2,t.lambda_span),handle=ids.named('binding',t.handle)
        return{record:'task',id:framedHash('kofun.scope-hir.task/v2',Buffer.concat([raw(par.id),uint(index,4),raw(spawn),raw(lambda),raw(handle)])),par_id:par.id,spawn_node_id:spawn,lambda_node_id:lambda,handle_binding_id:handle,lexical_index:index,display:display(t.name??null)}
    })
    const joins=tasks.map((t,index)=>{
        const explicit=test.tasks[index].join_span,node=explicit?ids.node(8,span(explicit)):null
        return{record:'join',id:framedHash('kofun.scope-hir.join/v2',Buffer.concat([raw(t.id),uint(explicit?1:2,1),...(node?[raw(node)]:[])])),task_id:t.id,join_kind:explicit?'explicit':'scope-exit',node_id:node}
    })
    const bound=b=>b.kind==='node'?{kind:'node',node_id:ids.expression(span(b.span,b.text))}:{kind:'constant',value:b.value}
    const observed=test.tasks.map((t,index)=>({id:tasks[index].id,observations:t.observations.map(o=>({mode:o.mode,origin:{node_id:ids.expression(span(o.span,o.text)),span:{start:o.span[0],end:o.span[1]}},target:o.reason?{kind:'unknown',reason:o.reason}:{kind:'place',base_binding_id:ids.named('binding',o.binding),display:display(o.name),projections:(o.projections??[]).map(p=>p.kind==='field'?{kind:'field',owner_type_id:ids.type(p.owner),ordinal:p.ordinal,display:display(p.name)}:{kind:'slice',lower:bound(p.lower),upper:bound(p.upper)})}}))}))
    const normalized=normalizeCaptures(observed)
    const document={schema:'kofun-scope-hir/v2',profile:'kofun.stage2-analysis/scoped-captures/v1',file_id:ids.file,root_scope_id:ids.named('scope',0),limits:LIMITS,records:[...pars,...tasks,...joins,...normalized.places,...normalized.unknowns,...normalized.captures]}
    const modelInput={schema:'kofun.scope-capture-observations/v1',profile:document.profile,file_id:ids.file,root_scope_id:document.root_scope_id,pars:pars.map(p=>({display:p.display,lexical_index:p.lexical_index,node_id:p.node_id,scope_id:p.scope_id,parent_scope_id:p.parent_scope_id,scope_token_binding_id:p.scope_token_binding_id,tasks:tasks.flatMap((t,n)=>t.par_id!==p.id?[]:[{display:t.display,lexical_index:t.lexical_index,spawn_node_id:t.spawn_node_id,lambda_node_id:t.lambda_node_id,handle_binding_id:t.handle_binding_id,join:{kind:joins[n].join_kind,node_id:joins[n].node_id},observations:observed[n].observations}])}))}
    return{document,modelInput}
}

// A source constructor with closed, authored allocator arithmetic, not a
// source resolver. Separate functions keep the same full cardinality while
// reducing the inherited resolver's quadratic work within each function.
export function maximumRecordsFixture(shape){
    if(shape.functions!==64||shape.pars_per_function!==1||shape.tasks_per_par!==1||shape.index_accesses_per_task!==64||shape.expected_records!==8384)refuse('full-boundary-shape')
    let source='';const pars=[],tasks=[]
    for(let fn=0;fn<64;fn++){
        source+=`fn part${fn}(values: List[Int]) {\n`
        for(let p=0;p<1;p++){
            source+=' ';const parStart=source.length;source+='par |scope| {\n  '
            const spawn=source.length;source+='scope.spawn('
            const lambda=source.length;source+='fn() {\n'
            const observations=[]
            for(let use=0;use<64;use++){
                source+='   ';const start=source.length;source+='values[0]'
                observations.push({mode:'read',reason:'unnameable-place',span:[start,source.length],text:'values[0]'})
                source+='\n'
            }
            source+='   0\n  }';const lambdaEnd=source.length;source+=')';const spawnEnd=source.length;source+='\n }';const parEnd=source.length;source+='\n'
            tasks.push({par:pars.length,handle:fn*3+2,span:[spawn,spawnEnd],lambda_span:[lambda,lambdaEnd],observations})
            pars.push({scope:fn*5+3,token:fn*3+1,name:'scope',span:[parStart,parEnd]})
        }
        source+='}\n'
    }
    return{name:'full-8384-record-boundary',source,pars,tasks,allocation_note:'Each function: two initial scopes plus par/lambda-parameters/lambda-body; one parameter plus token/hidden handle. All spans are ASCII byte positions authored while constructing source.'}
}
