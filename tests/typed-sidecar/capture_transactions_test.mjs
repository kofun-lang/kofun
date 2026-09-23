// Complete synthetic KSE2 transactions. The wire fixture encoder below is
// independent of production; the capture payload joins the frozen #1219 oracle.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  buildScopeHir, projectKse2CaptureSection, projectTypedSidecarV2,
} from "../../spec/concurrency/scoped-captures-v1/model.mjs";
import {
  encodeStage2SemanticEventsV2, readStage2SemanticEventsV2,
  projectStage2SemanticEventsV2, emitStage2TypedSidecarV2,
  readStage2SemanticEvents, projectStage2SemanticEvents, replayStage2SemanticEventsV2,
} from "../../tooling/typed-sidecar/from-stage2.mjs";
import { readTypedSidecar } from "../../tooling/typed-sidecar/codec.mjs";

const sha = (value) => crypto.createHash("sha256").update(value).digest("hex");
const id = (value) => sha(`kse2-test:${value}`);
const clone = structuredClone;
const sourceBytes = Buffer.alloc(65536, 120);
const input = JSON.parse(fs.readFileSync(new URL(
  "../../spec/concurrency/scoped-captures-v1/fixtures/canonical.json", import.meta.url)));
let assertions = 0;
function equal(actual, expected, label) { assertions++; assert.deepEqual(actual, expected, label); }
function succeeds(result, label) { equal(result.ok, true, `${label}: ${JSON.stringify(result.error)}`); return result; }
function refuses(result, code, message, label) {
  equal(result.ok, false, label);
  equal(result.error.code, code, label);
  if (message) { assertions++; assert.match(result.error.message, message, label); }
  equal(Object.hasOwn(result, "events"), false, `${label}: no partial records escape`);
}

// Test-only wire construction follows the frozen tag table, with no production
// frame encoder. It intentionally permits semantically corrupt signed fixtures.
const uint = (n, width) => {
  const b = Buffer.alloc(width);
  if (width === 8) b.writeBigUInt64BE(BigInt(n)); else b.writeUIntBE(n, 0, width);
  return b;
};
const packedId = (value) => Buffer.from(value, "hex");
const packedSpan = (span) => Buffer.concat([uint(span.start, 4), uint(span.end, 4)]);
const nested = (items, edit) => Buffer.concat([uint(items.length, 2), ...items.map((item) => {
  const text = Buffer.from(edit ? item.replacement : item.label);
  return Buffer.concat([...(edit ? [uint(item.remedy_id, 4)] : []), packedId(item.file_id),
    packedSpan(item.span), uint(text.length, 2), text]);
})]);
function field(tag, wire, value) {
  const bytes = wire === 1 ? value : wire === 2 ? Buffer.from(value) : wire === 3 ? packedId(value) :
    wire === 4 ? uint(value, 1) : wire === 5 ? uint(value, 4) : wire === 6 ? uint(value, 8) :
    wire === 7 ? packedSpan(value) : wire === 8 ? Buffer.concat(value.map(packedId)) :
      Buffer.concat(value.map((n) => uint(n, 4)));
  return Buffer.concat([Buffer.from([tag, wire, 0, 0]), uint(bytes.length, 4), bytes]);
}
function frame(event) {
  const f = (tag, wire, key) => [tag, wire, event[key]];
  let kind = event.kind;
  let fields;
  switch (event.event ?? event.kind) {
    case "source": kind = 1; fields = [f(1,3,"package_id"),f(2,3,"module_id"),f(3,3,"file_id"),f(4,2,"logical_path"),f(5,6,"source_bytes"),f(6,3,"source_sha256"),f(7,2,"edition"),f(8,2,"semantic_compatibility"),f(9,6,"generation"),f(10,4,"compiler_exit_class")]; break;
    case "node": kind = 2; fields = [f(1,3,"id"),f(2,4,"node_kind"),f(3,7,"span"),f(4,4,"status"),f(5,8,"dependencies"),f(6,8,"diagnostic_ids")]; break;
    case "identity": kind = 3; fields = [f(1,3,"owner_node_id"),f(2,4,"identity_kind"),f(3,3,"value"),f(4,4,"status")]; break;
    case "reference": kind = 4; fields = [f(1,3,"id"),f(2,3,"source_node_id"),f(3,4,"namespace"),f(4,7,"span"),f(5,4,"status"),f(6,4,"target_shape"),f(7,4,"target_kind"),event.target_shape === 1 ? f(8,3,"target_value") : f(9,2,"reason"),f(10,8,"diagnostic_ids")]; break;
    case "fact": kind = 5; fields = [f(1,3,"owner_node_id"),f(2,4,"fact_kind"),f(3,4,"status"),f(4,2,"display"),f(5,2,"reason"),f(6,8,"dependencies"),f(7,8,"diagnostic_ids")]; break;
    case "diagnostic": kind = 6; fields = [f(1,3,"id"),f(2,2,"code"),f(3,2,"category"),f(4,4,"severity"),f(5,2,"template_id"),f(6,3,"primary_file_id"),f(7,7,"primary_span"),f(8,2,"fallback_text"),f(9,8,"affected_ids"),f(10,9,"remedy_ids"),f(11,4,"truncated"),[12,1,nested(event.related,false)],[13,1,nested(event.edits,true)]]; break;
    case "end": kind = 7; fields = [f(1,4,"source_status"),f(2,4,"completeness")]; break;
    case "par": fields = [f(1,3,"par_id"),f(2,3,"node_id"),f(3,3,"scope_id"),f(4,3,"parent_scope_id"),f(5,3,"scope_token_binding_id"),f(6,5,"lexical_index")]; break;
    case "task": fields = [f(1,3,"task_id"),f(2,3,"par_id"),f(3,3,"spawn_node_id"),f(4,3,"lambda_node_id"),f(5,3,"handle_binding_id"),f(6,5,"lexical_index")]; break;
    case "join": fields = [f(1,3,"join_id"),f(2,3,"task_id"),[3,4,event.join_kind === "explicit" ? 1 : 2],...(event.join_kind === "explicit" ? [f(4,3,"node_id")] : [])]; break;
    case "place": fields = [f(1,3,"place_id"),f(2,3,"base_binding_id"),[3,1,Buffer.from(event.canonical_bytes,"hex")]]; break;
    case "unknown": fields = [f(1,3,"unknown_id"),f(2,3,"task_id"),f(3,3,"witness_node_id"),[4,4,["unresolved-call","projection-depth-exceeded","unnameable-place"].indexOf(event.reason)+1],[5,1,Buffer.from(event.canonical_bytes,"hex")]]; break;
    case "capture": fields = [f(1,3,"capture_id"),f(2,3,"task_id"),[3,4,event.target_kind === "place" ? 1 : 2],f(4,3,"target_id"),[5,4,["read","edit","take"].indexOf(event.mode)+1],f(6,8,"origin_node_ids")]; break;
    default: throw new Error("unknown test event");
  }
  const payload = Buffer.concat(fields.map(([tag,wire,value]) => field(tag,wire,value)));
  return Buffer.concat([Buffer.from([kind,0]),uint(fields.length,2),uint(payload.length,4),payload]);
}
function envelope(frames, version = 2) {
  const payload = Buffer.concat(frames);
  const unsigned = Buffer.concat([Buffer.from("KSE\0"),uint(version,2),uint(0,2),uint(frames.length,4),uint(payload.length,4),payload]);
  return Buffer.concat([unsigned,Buffer.from(sha(unsigned),"hex")]);
}
const raw = (events, version = 2) => envelope(events.map(frame),version);

function transaction(observations = input, outcome = "complete") {
  const hir = buildScopeHir(observations);
  const section = projectKse2CaptureSection(hir);
  const captures = section.events.map(({wire_hex, ...event}) => event);
  const nodes = new Map();
  const identities = new Map();
  function node(value, span) {
    if (!nodes.has(value)) nodes.set(value, {kind:"node",id:value,node_kind:9,
      span:{start:1,end:2},status:1,dependencies:[],diagnostic_ids:[]});
    if (span) nodes.get(value).span = clone(span);
  }
  function identity(kind,value) {
    const key = `${kind}:${value}`;
    if (identities.has(key)) return;
    const owner = id(`owner:${key}`); node(owner);
    identities.set(key,{kind:"identity",identity_kind:kind,value,owner_node_id:owner,status:1});
  }
  for (const record of hir.records) if (record.record === "capture") {
    for (const origin of record.origins) node(origin.node_id,origin.span);
  }
  for (const event of captures) {
    for (const key of ["node_id","spawn_node_id","lambda_node_id","witness_node_id"]) if (event[key]) node(event[key]);
    for (const key of ["scope_id","parent_scope_id"]) if (event[key]) identity(4,event[key]);
    for (const key of ["scope_token_binding_id","handle_binding_id","base_binding_id"]) if (event[key]) identity(5,event[key]);
    for (const projection of event.projections ?? []) {
      if (projection.kind === "field") identity(8,projection.owner_type_id);
      else for (const bound of [projection.lower,projection.upper]) if (bound.kind === "node") node(bound.node_id);
    }
  }
  const source = {kind:"source",package_id:id("package"),module_id:id("module"),file_id:hir.file_id,
    logical_path:"src/captures.kofun",source_bytes:sourceBytes.length,source_sha256:sha(sourceBytes),
    edition:"2026",semantic_compatibility:"bootstrap-0.3",generation:10,compiler_exit_class:outcome === "failed" ? 1 : 0};
  const owner = id("common-owner"); node(owner);
  const binding = id("common-binding"); identity(5,binding);
  const reference = {kind:"reference",id:id("reference"),source_node_id:owner,namespace:1,
    span:{start:1,end:2},status:1,target_shape:1,target_kind:5,target_value:binding,reason:"",diagnostic_ids:[]};
  const fact = {kind:"fact",owner_node_id:owner,fact_kind:1,status:1,display:"Int",reason:"",dependencies:[],diagnostic_ids:[]};
  const diagnostic = {kind:"diagnostic",id:id("diagnostic"),code:"E2S154",category:"unsupported",severity:outcome === "failed" ? 1 : 2,
    template_id:"unsupported-feature",primary_file_id:source.file_id,primary_span:{start:1,end:2},fallback_text:"synthetic diagnostic",
    affected_ids:[owner],remedy_ids:[1],truncated:0,related:[{file_id:source.file_id,span:{start:2,end:3},label:"related"}],
    edits:[{remedy_id:1,file_id:source.file_id,span:{start:1,end:2},replacement:"y"}]};
  const end = {kind:"end",source_status:outcome === "complete" ? 1 : outcome === "failed" ? 2 : 3,completeness:outcome === "complete" ? 1 : 2};
  return {hir,section,events:[source,...nodes.values(),...identities.values(),...captures,reference,fact,diagnostic,end]};
}

const fixture = transaction();
const valid = fixture.events;
for (const event of fixture.section.events) equal(frame(event).toString("hex"),event.wire_hex,"independent capture wire matches frozen oracle");
for (const outcome of ["complete","failed","cancelled"]) {
  const {events,hir} = transaction(input,outcome);
  const bytes = raw(events);
  equal(succeeds(encodeStage2SemanticEventsV2(events),outcome).bytes,bytes,`${outcome}: entire canonical envelope`);
  equal(succeeds(encodeStage2SemanticEventsV2(events),outcome).bytes,bytes,`${outcome}: repeat bytes`);
  const read = succeeds(readStage2SemanticEventsV2(bytes),outcome);
  equal(read.events,events,`${outcome}: complete logical round trip`);
  equal(Object.isFrozen(read.events[1].span),true,"decoded nested records frozen");
  const common = events.filter(event => typeof event.kind === "string");
  const base = succeeds(projectStage2SemanticEvents(common),"common v1 projection").document;
  const result = succeeds(projectStage2SemanticEventsV2(events),outcome);
  equal(JSON.parse(JSON.stringify(result.document)),JSON.parse(JSON.stringify(projectTypedSidecarV2(base,hir))),`${outcome}: independent frozen capture projection`);
  equal(result.compiler_exit_class,events[0].compiler_exit_class,"exact compiler outcome retained");
  equal(Object.isFrozen(result.document.captures[0].target),true,"v2 nested document frozen");
  refuses(readStage2SemanticEvents(bytes),"ETS03",/version/,"v1 still refuses v2");
  equal(succeeds(readStage2SemanticEvents(raw(common,1)),"v1 common wire").events,common,"v1 bytes and APIs stay compatible");
}
equal([...new Set(valid.filter(e=>e.event === "unknown").map(e=>e.reason))].sort(),
  ["projection-depth-exceeded","unnameable-place","unresolved-call"],"all three unknown reasons represented");
const empty = transaction({...input,pars:[]});
succeeds(readStage2SemanticEventsV2(raw(empty.events)),"empty capture section");

function invalid(name, mutate, message, code = "ETS03") {
  const events = clone(valid); mutate(events);
  refuses(readStage2SemanticEventsV2(raw(events)),code,message,name);
  refuses(encodeStage2SemanticEventsV2(events),code,message,`${name}: encoder`);
  refuses(projectStage2SemanticEventsV2(events),code,message,`${name}: logical projector`);
}
// These corrupt the committed snapshot without changing capture IDs. Every
// capture preimage remains coherent, so refusal must reach transaction closure.
const origin = valid.find(e=>e.event === "capture").origin_node_ids[0];
const bound = valid.flatMap(e=>e.projections ?? []).flatMap(p=>[p.lower,p.upper]).find(b=>b?.kind === "node").node_id;
for (const [name,key,eventType] of [["par node","node_id","par"],["spawn node","spawn_node_id","task"],
  ["lambda node","lambda_node_id","task"],["join node","node_id","join"],["unknown witness","witness_node_id","unknown"]]) {
  const value = valid.find(e=>e.event === eventType && e[key])?.[key];
  invalid(name,events=>events.splice(events.findIndex(e=>e.kind === "node" && e.id === value),1),/outside the committed node phase/);
}
for (const [name,value] of [["origin",origin],["dynamic bound",bound]]) {
  invalid(name,events=>events.splice(events.findIndex(e=>e.kind === "node" && e.id === value),1),/outside the committed node phase/);
}
for (const [name,value,kind] of [["root scope",input.root_scope_id,4],["par scope",input.pars[0].scope_id,4],
  ["scope token",input.pars[0].scope_token_binding_id,5],["task handle",input.pars[0].tasks[0].handle_binding_id,5],
  ["base binding",valid.find(e=>e.event === "place").base_binding_id,5],
  ["field owner",valid.flatMap(e=>e.projections ?? []).find(p=>p.kind === "field").owner_type_id,8]]) {
  invalid(name,events=>events.splice(events.findIndex(e=>e.kind === "identity" && e.value === value && e.identity_kind === kind),1),/committed identity namespace/);
  invalid(`${name} wrong namespace`,events=>{events.find(e=>e.kind === "identity" && e.value === value && e.identity_kind === kind).identity_kind=kind === 4 ? 5 : 4},/committed identity namespace/);
}
invalid("dangling identity owner",events=>{events.find(e=>e.kind === "identity").owner_node_id=id("absent")},/identity/);
invalid("origin outside source",events=>{events.find(e=>e.id === origin).span.end=sourceBytes.length+1},/span/);
invalid("empty origin span",events=>{const e=events.find(e=>e.id === origin);e.span.end=e.span.start},/nonempty/);
invalid("source-span order",events=>{
  const capture=events.find(e=>e.event === "capture" && e.origin_node_ids.length>1);
  const a=events.find(e=>e.id === capture.origin_node_ids[0]);
  const b=events.find(e=>e.id === capture.origin_node_ids[1]);
  [a.span,b.span]=[b.span,a.span];
},/source-span order/);
invalid("different source FileId",events=>{events[0].file_id=id("other-file");const d=events.find(e=>e.kind === "diagnostic");d.primary_file_id=events[0].file_id;d.related[0].file_id=events[0].file_id;d.edits[0].file_id=events[0].file_id},/projection failed/);
invalid("capture section after references",events=>{const i=events.findIndex(e=>e.kind === "reference");const r=events.splice(i,1)[0];events.splice(events.findIndex(e=>e.event === "par"),0,r)},/phase order/);
invalid("end missing",events=>events.pop(),/phase order/);
invalid("end duplicated",events=>events.push(clone(events.at(-1))),/phase order/);
invalid("source duplicated",events=>events.splice(1,0,clone(events[0])),/phase order/);
invalid("checked exit mismatch",events=>{events[0].compiler_exit_class=1},/disagree/);
invalid("failed without error diagnostic",events=>{events[0].compiler_exit_class=1;events.at(-1).source_status=2;events.at(-1).completeness=2},/disagree/);
invalid("cancelled complete",events=>{events.at(-1).source_status=3},/disagree/);
invalid("cancelled unclosed task section",events=>{events.splice(events.findIndex(e=>e.event === "join"),1);events.at(-1).source_status=3;events.at(-1).completeness=2},/projection failed/);

const canonical = raw(valid);
function corrupt(name, change, code="ETS03", message) {
  const bytes=Buffer.from(canonical);change(bytes);
  refuses(readStage2SemanticEventsV2(bytes),code,message,name);
}
corrupt("digest corruption",bytes=>{bytes[bytes.length-1]^=1},"ETS03",/digest/);
corrupt("header count over bound",bytes=>bytes.writeUInt32BE(16385,8),"ETS04",/count/);
corrupt("header payload over bound",bytes=>bytes.writeUInt32BE(16777217,12),"ETS04",/count/);
corrupt("unsupported successor",bytes=>bytes.writeUInt16BE(3,4),"ETS03",/version/);
refuses(readStage2SemanticEventsV2(canonical.subarray(0,-1)),"ETS04",/size/,"truncation is not cancellation");
refuses(readStage2SemanticEventsV2(Buffer.concat([canonical,Buffer.from([0])])),"ETS04",/size/,"trailing byte");
const frames=valid.map(frame);
const captureIndex=valid.findIndex(e=>e.event === "par");
for (const [name,mutate] of [
  ["reserved field byte",b=>{b[10]=1}],
  ["capture wire type",b=>{b[9]=2}],
  ["field tag order",b=>{b[8]=6}],
  ["frame flags",b=>{b[1]=1}],
  ["field count",b=>{b.writeUInt16BE(5,2)}],
]) {
  const changed=frames.map(b=>Buffer.from(b));mutate(changed[captureIndex]);
  refuses(readStage2SemanticEventsV2(envelope(changed)),"ETS03",undefined,name);
}
const extraFrames=frames.map(b=>Buffer.from(b));
const original=extraFrames[captureIndex];
extraFrames[captureIndex]=Buffer.concat([original,field(7,4,1)]);
extraFrames[captureIndex].writeUInt16BE(7,2);
extraFrames[captureIndex].writeUInt32BE(original.readUInt32BE(4)+9,4);
refuses(readStage2SemanticEventsV2(envelope(extraFrames)),"ETS03",/canonical/,"unknown capture field cannot be ignored");
const privateInput=clone(valid);privateInput.find(e=>e.event === "capture").display="private-name";
refuses(encodeStage2SemanticEventsV2(privateInput),"ETS03",/fields/,"extra presentation data cannot encode");
const badText=clone(valid);badText[0].logical_path="src/\ud800.kofun";
refuses(encodeStage2SemanticEventsV2(badText),"ETS04",/surrogate/,"unpaired logical text");

// Independent transaction event cap: exceeding v1's4096 records is valid v2,
// including the exact successor boundary, without weakening common relations.
const minimal=[empty.events[0],empty.events.at(-1)];
const manyNodes=Array.from({length:16382},(_,i)=>({kind:"node",id:id(`limit-node:${i}`),node_kind:9,
  span:{start:0,end:1},status:1,dependencies:[],diagnostic_ids:[]}));
const maximal=[minimal[0],...manyNodes,minimal[1]];
succeeds(readStage2SemanticEventsV2(raw(maximal)),"exact 16384-event boundary");
refuses(encodeStage2SemanticEventsV2([...maximal.slice(0,-1),clone(manyNodes[0]),maximal.at(-1)]),"ETS04",/count/,"16385-event refusal");
const relationLimit=clone(minimal);relationLimit.splice(1,0,...manyNodes.slice(0,66));
relationLimit.at(-2).dependencies=relationLimit.slice(1,65).map(e=>e.id).sort();
succeeds(readStage2SemanticEventsV2(raw(relationLimit)),"common 64-relation boundary");
relationLimit.at(-2).dependencies.push(relationLimit.at(-3).id);relationLimit.at(-2).dependencies.sort();
refuses(readStage2SemanticEventsV2(raw(relationLimit)),"ETS04",/relation/,"common relations remain64");

// The successor field cap applies to common fields without widening v1.
const fieldBoundary=clone(valid);
fieldBoundary.find(e=>e.kind === "diagnostic").fallback_text="x".repeat(16384);
succeeds(readStage2SemanticEventsV2(raw(fieldBoundary)),"exact 16KiB field");
refuses(readStage2SemanticEvents(raw(fieldBoundary.filter(e=>typeof e.kind === "string"),1)),"ETS04",/byte limit/,"v1 retains4KiB field cap");
fieldBoundary.find(e=>e.kind === "diagnostic").fallback_text+="x";
refuses(readStage2SemanticEventsV2(raw(fieldBoundary)),"ETS04",/field/,"16KiB plus one field");
refuses(encodeStage2SemanticEventsV2(fieldBoundary),"ETS04",/text/,"encoder16KiB plus one field");

const originInput=clone(input);
originInput.pars=originInput.pars.slice(0,1);
originInput.pars[0].tasks=originInput.pars[0].tasks.slice(0,1);
originInput.pars[0].tasks[0].observations=Array.from({length:256},(_,i)=>({
  mode:"read",origin:{node_id:id(`origin-limit:${i}`),span:{start:500+i*2,end:501+i*2}},
  target:{kind:"place",base_binding_id:id("origin-limit-base"),projections:[],display:{disclosure:"hidden",text:null}},
}));
const origins256=transaction(originInput).events;
const read256=succeeds(readStage2SemanticEventsV2(raw(origins256)),"exact256capture origins");
equal(read256.events.find(e=>e.event === "capture").origin_node_ids.length,256,"capture relation cap is distinct");
const origins257=clone(origins256);
origins257.find(e=>e.event === "capture").origin_node_ids.push(id("origin257"));
refuses(readStage2SemanticEventsV2(raw(origins257)),"ETS04",/origin/,"257capture origins refused");
refuses(encodeStage2SemanticEventsV2(origins257),"ETS04",/origin/,"encoder257capture origins refused");

// All64tasks can retain64different unknown targets:8384section records fit
// together with the upstream nodes/identities in one real v2 transaction.
const cardinalInput=clone(input);
cardinalInput.pars=Array.from({length:64},(_,p)=>({
  ...clone(input.pars[0]),lexical_index:p,node_id:id(`par-node:${p}`),scope_id:id(`par-scope:${p}`),
  scope_token_binding_id:id(`par-token:${p}`),tasks:[{
    ...clone(input.pars[0].tasks[0]),lexical_index:0,spawn_node_id:id(`spawn:${p}`),lambda_node_id:id(`lambda:${p}`),
    handle_binding_id:id(`handle:${p}`),join:{kind:"scope-exit",node_id:null},
    observations:Array.from({length:64},(_,c)=>({mode:"read",
      origin:{node_id:id(`full-origin:${p}:${c}`),span:{start:1000+(p*64+c)*2,end:1001+(p*64+c)*2}},
      target:{kind:"unknown",reason:"unresolved-call"},
    })),
  }],
}));
const cardinal=transaction(cardinalInput);
equal(cardinal.section.events.length,8384,"maximum independent target section cardinality");
const cardinalBytes=raw(cardinal.events);
const cardinalRead=succeeds(readStage2SemanticEventsV2(cardinalBytes),"full64by64transaction");
equal(cardinalRead.events.filter(e=>e.event === "capture").length,4096,"all4096captures survive");
equal(succeeds(encodeStage2SemanticEventsV2(cardinal.events),"full64by64encoder").bytes,cardinalBytes,"maximum envelope matches independent wire");
const tooManyCaptures=clone(cardinal.events);
tooManyCaptures.splice(tooManyCaptures.findIndex(e=>e.kind === "reference"),0,clone(tooManyCaptures.find(e=>e.event === "capture")));
refuses(readStage2SemanticEventsV2(raw(tooManyCaptures)),"ETS04",/capture event count/,"8385section records refused before publication");

// A valid payload larger than KSE1's4MiB proves that v2 does not delegate its
// common records to the old bounded reader after merely removing captures.
const denseNodes=clone(manyNodes.slice(0,2200));
const dependencies=denseNodes.slice(0,64).map(e=>e.id).sort();
for(const node of denseNodes.slice(64)) node.dependencies=[...dependencies];
const largePayload=raw([minimal[0],...denseNodes,minimal[1]]);
assertions++;assert.ok(largePayload.readUInt32BE(12)>4*1024*1024,"large positive payload exceeds v1");
succeeds(readStage2SemanticEventsV2(largePayload),"valid v2 payload beyond4MiB");
refuses(readStage2SemanticEvents(largePayload),"ETS04",/byte cap/,"v1 retains4MiB cap before version dispatch");
refuses(readStage2SemanticEventsV2(Buffer.alloc(16777216+49)),"ETS04",/byte cap/,"v2 outer byte cap");

// Public replay is full-stream validation, separately from sidecar sequence replay.
const replayed=[];
const replay=succeeds(replayStage2SemanticEventsV2(canonical,event=>{replayed.push(event)}),"full transaction replay");
equal(replayed,valid,"replay delivers exact wire-order records");
equal(replay.event_count,valid.length,"replay count");
equal(Object.isFrozen(replayed[1].span),true,"replay cannot mutate committed spans");
let callbacks=0;
const invalidReplay=clone(valid);invalidReplay.splice(invalidReplay.findIndex(e=>e.kind === "node" && e.id === origin),1);
refuses(replayStage2SemanticEventsV2(raw(invalidReplay),()=>{callbacks++}),"ETS03",/committed node phase/,"semantic validation before replay callbacks");
equal(callbacks,0,"invalid signed transaction delivers no prefix");
refuses(replayStage2SemanticEventsV2(canonical,()=>{callbacks++;return false}),"ETS03",/destination/,"replay destination refusal");
equal(callbacks,1,"no callbacks after destination refusal");
refuses(replayStage2SemanticEventsV2(canonical,()=>{throw new Error("private-target /private/path")}),"ETS03",/^semantic replay destination refused a record$/,"replay exception privacy");
refuses(replayStage2SemanticEventsV2(canonical,async()=>{}),"ETS03",/destination/,"async replay destination refused");

// Publication consumes the fully validated transaction, rechecks source bytes,
// and uses the existing atomic writer for replay, races and cancellation.
const work=fs.mkdtempSync(path.join(os.tmpdir(),"kofun-kse2-transactions-"));
try {
  const destination=path.join(work,"sidecar.json");
  succeeds(await emitStage2TypedSidecarV2(canonical,destination,{currentSourceBytes:sourceBytes}),"publish complete");
  const before=fs.readFileSync(destination);
  equal(readTypedSidecar(before).document.schema,"kofun.typed-sidecar/v2","published schema");
  refuses(await emitStage2TypedSidecarV2(canonical,destination,{currentSourceBytes:sourceBytes}),"ETS05",/stale-sequence/,"replay refusal");
  equal(fs.readFileSync(destination),before,"replay preserves bytes");
  const next=clone(valid);next[0].generation++;
  const abort=new AbortController();abort.abort();
  refuses(await emitStage2TypedSidecarV2(raw(next),destination,{currentSourceBytes:sourceBytes,signal:abort.signal}),"ETS06",/cancelled/,"aborted publication");
  equal(fs.readFileSync(destination),before,"abort preserves bytes");
  refuses(await emitStage2TypedSidecarV2(raw(next),destination,{currentSourceBytes:Buffer.from("changed")}),"ETS05",/source/,"source changed");
  equal(fs.readFileSync(destination),before,"source mismatch preserves bytes");
  let reads=0;
  const changing={get currentSourceBytes(){return reads++ === 0 ? sourceBytes : Buffer.from("changed")}};
  refuses(await emitStage2TypedSidecarV2(raw(next),destination,changing),"ETS05",/source-mismatch/,"source changed before rename");
  equal(fs.readFileSync(destination),before,"late source change preserves bytes");
  const corruptEvents=clone(next);corruptEvents.splice(corruptEvents.findIndex(e=>e.kind === "node" && e.id === origin),1);
  refuses(await emitStage2TypedSidecarV2(raw(corruptEvents),destination,{currentSourceBytes:sourceBytes}),"ETS03",/committed node phase/,"invalid signed transaction never publishes");
  equal(fs.readFileSync(destination),before,"semantic rejection preserves bytes");
  for (const [index,outcome] of ["failed","cancelled"].entries()) {
    const events=transaction(input,outcome).events;events[0].generation=20+index;
    const result=succeeds(await emitStage2TypedSidecarV2(raw(events),destination,{currentSourceBytes:sourceBytes}),`publish ${outcome}`);
    equal(result.source_status,outcome,"committed partial status");
    equal(readTypedSidecar(fs.readFileSync(destination)).document.captures.length,6,"partial retains committed captures");
  }
  equal(fs.readdirSync(work),["sidecar.json"],"no lock or temporary artifacts remain");
} finally { fs.rmSync(work,{recursive:true,force:true}); }
console.log(`PASS: complete KSE2 transactions: ${assertions} assertions (independent wire, closure, bounds, outcomes and atomic publication)`);
