// Deterministic projection of the repository's pinned Unicode authority.
// No network, host ICU, or added compiler-private host operation is involved.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
if(process.argv.length>3 || (process.argv.length===3 && process.argv[2]!=='--check')) throw new Error('usage: generate-scoped-unicode.mjs [--check]');
const work=fs.mkdtempSync(path.join(os.tmpdir(),'kofun-scoped-unicode-'));
function run(command,args) {
  const r=spawnSync(command,args,{encoding:'utf8',maxBuffer:8*1024*1024});
  if(r.error || r.status!==0) throw new Error(`${command}: ${r.error ?? r.stderr}`);
  return r.stdout;
}
let rows;
try {
  const source=path.join(work,'project.c'), binary=path.join(work,'project');
  fs.writeFileSync(source,`#include <stdio.h>
#include ${JSON.stringify(path.join(root,'vendor/utf8proc/utf8proc.c'))}
int main(void) {
  for(int cp=0;cp<0x110000;cp++) {
    if(cp>=0xd800 && cp<=0xdfff)continue;
    const utf8proc_property_t *p=utf8proc_get_property(cp);
    if(p->combining_class)printf("c %06x %02x\\n",cp,p->combining_class);
    if(p->category==UTF8PROC_CATEGORY_CC || p->category==UTF8PROC_CATEGORY_CF || p->category==UTF8PROC_CATEGORY_ZL || p->category==UTF8PROC_CATEGORY_ZP)printf("x %06x\\n",cp);
    if(cp<0xac00 || cp>=0xac00+11172) {
      utf8proc_int32_t d[32];
      utf8proc_ssize_t n=utf8proc_decompose_char(cp,d,32,UTF8PROC_STABLE|UTF8PROC_DECOMPOSE,NULL);
      if(n<1 || n>32)return 1;
      if(n!=1 || d[0]!=cp) {printf("d %06x ",cp);for(int i=0;i<n;i++)printf("%06x",d[i]);putchar('\\n');}
    }
    if(p->comb_index<0x3ff)for(int i=0;i<p->comb_length;i++)printf("p %06x %06x %06x\\n",cp,utf8proc_combinations_second[p->comb_index+i],utf8proc_combinations_combined[p->comb_index+i]);
  }
  return 0;
}
`);
  run(process.env.CC || 'cc',['-std=c11','-O2','-Wall','-Wextra','-Werror','-pedantic',source,'-o',binary]);
  rows=run(binary,[]).trim().split('\n').map(row=>row.split(' '));
} finally {fs.rmSync(work,{recursive:true,force:true});}
const hex=(n,width)=>n.toString(16).padStart(width,'0');
let decomposition='', index='', ccc='', composition='';
const forbidden=[];
for(const [kind,key,value,result] of rows) {
  if(kind==='d') {index+=key+hex(decomposition.length/6,6)+hex(value.length/6,2);decomposition+=value;}
  if(kind==='c') ccc+=key+value;
  if(kind==='p') composition+=key+value+result;
  if(kind==='x') {
    const cp=parseInt(key,16), last=forbidden.at(-1);
    if(last && cp===last[1]+1)last[1]=cp; else forbidden.push([cp,cp]);
  }
}
const tables={decomposition_index:index,decomposition,ccc,composition,forbidden:forbidden.map(([a,b])=>hex(a,6)+hex(b,6)).join('')};
let generated='# BEGIN GENERATED SCOPED UNICODE\n# Pinned utf8proc Unicode 17.0.0; generate-scoped-unicode.mjs.\n';
for(const [name,data] of Object.entries(tables))generated+=`fn scoped_unicode_${name}() -> Text {\n    return "${data}"\n}\n\n`;
generated+='# END GENERATED SCOPED UNICODE';
const file=path.join(root,'bootstrap/stage2/compiler.kofun'), source=fs.readFileSync(file,'utf8');
for(const marker of ['# BEGIN GENERATED SCOPED UNICODE','# END GENERATED SCOPED UNICODE'])if(source.split(marker).length!==2)throw new Error(`expected one ${marker}`);
const updated=source.replace(/# BEGIN GENERATED SCOPED UNICODE[\s\S]*?# END GENERATED SCOPED UNICODE/,generated);
if(process.argv[2]==='--check') {if(source!==updated)throw new Error('scoped Unicode projection differs from pinned utf8proc');}
else fs.writeFileSync(file,updated);
