return [==[<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>KoDrop</title>
<style>
:root{--bg:#fff;--fg:#111;--mut:#666;--line:#e3e3e3;--hi:#eef3ff;--acc:#2563eb;--dan:#c62828;color-scheme:light dark}
@media(prefers-color-scheme:dark){:root{--bg:#121212;--fg:#eee;--mut:#999;--line:#2c2c2c;--hi:#1d2a44;--acc:#6ea0ff;--dan:#ef5350}}
*{box-sizing:border-box}[hidden]{display:none!important}
body{margin:0;font:16px/1.4 system-ui,sans-serif;background:var(--bg);color:var(--fg);padding-bottom:30vh}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:8px;z-index:2}
.bar{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
button{min-height:44px;min-width:44px;padding:0 14px;border:1px solid var(--line);border-radius:8px;background:transparent;color:inherit;font:inherit;cursor:pointer}
button.pri{background:var(--acc);border-color:var(--acc);color:#fff}
button.dan{color:var(--dan)}button.pri.dan{background:var(--dan);border-color:var(--dan);color:#fff}
#crumbs{display:flex;flex-wrap:wrap;margin-top:6px;font-size:15px}
#crumbs a{padding:8px 6px;border-radius:6px;color:var(--acc);text-decoration:none}
#crumbs span{color:var(--mut);padding:8px 0}
ul{list-style:none;margin:0;padding:0}
li.row{display:flex;align-items:center;gap:8px;padding:0 8px;min-height:56px;border-bottom:1px solid var(--line)}
.nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:16px 0;cursor:pointer}
.meta{color:var(--mut);font-size:13px;text-align:right;white-space:nowrap}
.ic{font-size:22px;width:28px;text-align:center}
input[type=checkbox]{width:22px;height:22px;margin:0}
.drop{background:var(--hi);outline:2px dashed var(--acc);outline-offset:-2px}
#empty{padding:40px;text-align:center;color:var(--mut)}
#ups{position:fixed;bottom:0;left:0;right:0;background:var(--bg);max-height:30vh;overflow:auto}
.up{padding:6px 10px;font-size:14px;border-top:1px solid var(--line)}.up progress{width:100%;height:10px}
dialog{border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--fg);width:min(92vw,420px);padding:16px}
dialog::backdrop{background:#0008}
dialog h3{margin:0 0 10px;word-break:break-all}
dialog input{width:100%;font:inherit;padding:10px;min-height:44px;border:1px solid var(--line);border-radius:8px;background:transparent;color:inherit}
.acts{display:flex;gap:8px;justify-content:flex-end;margin-top:12px;flex-wrap:wrap}
.sheet button{display:block;width:100%;text-align:left;margin:6px 0}
.picker{max-height:50vh;overflow:auto;border:1px solid var(--line);border-radius:8px;margin-top:8px}
.picker li{padding:14px 12px;border-bottom:1px solid var(--line);cursor:pointer}
.mut{color:var(--mut);word-break:break-all}
#dz{display:none;position:fixed;inset:0;background:#2563eb22;border:4px dashed var(--acc);z-index:5;pointer-events:none}
body.dragging #dz{display:block}
</style></head><body>
<header><div class="bar">
<button id="back" aria-label="Back">&larr;</button><button id="up" aria-label="Up">&uarr;</button>
<button id="mk">+ Folder</button><button id="ub" class="pri">Upload</button>
<input id="fi" type="file" multiple hidden>
<span id="sel" class="bar" hidden><button id="smv">Move</button><button id="sdel" class="dan">Delete</button></span>
</div><nav id="crumbs"></nav></header>
<main><ul id="list"></ul><div id="empty" hidden>Empty folder. Drop files here or tap Upload.</div></main>
<div id="ups"></div><div id="dz"></div>
<script>
const $=s=>document.querySelector(s), enc=encodeURIComponent;
let cur='/', items=[];
const sel=new Set();
function h(t,p,...c){const e=document.createElement(t);for(const k in p||{}){const v=p[k];if(k.startsWith('on'))e.addEventListener(k.slice(2),v);else if(k in e)e[k]=v;else e.setAttribute(k,v)}e.append(...c);return e}
const join=(d,n)=>(d=='/'?'':d)+'/'+n, parent=p=>p.replace(/\/[^/]*$/,'')||'/', base=p=>p.split('/').pop();
const size=b=>b<1024?b+' B':b<1048576?Math.round(b/1024)+' KB':b<1073741824?(b/1048576).toFixed(1)+' MB':(b/1073741824).toFixed(2)+' GB';
const date=t=>new Date(t*1000).toLocaleString([],{dateStyle:'short',timeStyle:'short'});
const icon=e=>e.dir?'📁':/\.(epub|mobi|azw3?|fb2|kfx|djvu)$/i.test(e.name)?'📖':/\.pdf$/i.test(e.name)?'📕':/\.(cbz|cbr|zip|rar|7z)$/i.test(e.name)?'🗜️':/\.(jpe?g|png|gif|webp|bmp)$/i.test(e.name)?'🖼️':'📄';
const here=()=>decodeURIComponent(location.hash.slice(1))||'/';
const oops=x=>alert(x.message||x);

async function api(path,body){
  const r=await fetch(path,body===undefined?{}:{method:'POST',headers:{'X-KoDrop':'1','Content-Type':'application/json'},body:JSON.stringify(body)});
  let j={};try{j=await r.json()}catch(e){}
  if(r.status==401&&path!='/api/login'){await pin();return api(path,body)}
  if(!r.ok)throw new Error(j.error||r.statusText);
  return j}

// one <dialog> per modal: a reused one gets the previous close event
function modal(build){return new Promise(res=>{const d=h('dialog');document.body.append(d);let v=null;
  const done=x=>{v=x;d.close()};d.addEventListener('close',()=>{d.remove();res(v)});build(d,done);d.showModal()})}
function ask(title,val,secret){return modal((d,done)=>{
  const i=h('input',{type:secret?'password':'text',value:val||''});if(secret)i.inputMode='numeric';
  d.append(h('form',{onsubmit:e=>{e.preventDefault();done(i.value)}},h('h3',{},title),i,
    h('div',{className:'acts'},h('button',{type:'button',onclick:()=>done(null)},'Cancel'),h('button',{className:'pri'},'OK'))));
  setTimeout(()=>{i.focus();i.select()},0)})}
function sure(msg){return modal((d,done)=>d.append(h('h3',{},msg),h('div',{className:'acts'},
  h('button',{onclick:()=>done(false)},'Cancel'),h('button',{className:'pri dan',onclick:()=>done(true)},'Delete'))))}

let pinP=null;
function pin(){return pinP=pinP||(async()=>{
  for(;;){const v=await ask('Enter KoDrop PIN','',true);if(v===null)continue;
    try{await api('/api/login',{pin:v});break}catch(e){oops(e)}}
  pinP=null})()}

function go(p){const hh='#'+enc(p);if(location.hash===hh)load(p);else location.hash=hh}
addEventListener('hashchange',()=>load(here()));
async function load(p){
  try{const d=await api('/api/ls?path='+enc(p));cur=d.path;items=Object.values(d.entries||{});sel.clear();render()}
  catch(e){oops(e);if(p!='/')go('/')}}

function render(){
  const c=$('#crumbs');c.replaceChildren();let acc='';
  const crumb=(label,path)=>{const a=h('a',{href:'#'+enc(path)},label);target(a,path);c.append(a)};
  crumb('Home','/');
  for(const s of cur.split('/').filter(Boolean)){acc+='/'+s;c.append(h('span',{},'/'));crumb(s,acc)}
  const L=$('#list');L.replaceChildren();
  for(const e of items){const p=join(cur,e.name);
    const cb=h('input',{type:'checkbox',checked:sel.has(p),'aria-label':'Select '+e.name,onchange:()=>{cb.checked?sel.add(p):sel.delete(p);selbar()}});
    const li=h('li',{className:'row',draggable:true},cb,h('span',{className:'ic'},icon(e)),
      h('span',{className:'nm',onclick:()=>e.dir?go(p):menu(e,p)},e.name),
      h('span',{className:'meta'},e.dir?'':size(e.size),h('br'),date(e.mtime)),
      h('button',{'aria-label':'Actions for '+e.name,onclick:()=>menu(e,p)},'⋮'));
    li.addEventListener('dragstart',ev=>{ev.dataTransfer.setData('application/x-kodrop',JSON.stringify(sel.has(p)?[...sel]:[p]));ev.dataTransfer.effectAllowed='move'});
    if(e.dir)target(li,p);
    L.append(li)}
  $('#empty').hidden=items.length>0;selbar()}
function selbar(){$('#sel').hidden=!sel.size;$('#smv').textContent='Move ('+sel.size+')';$('#sdel').textContent='Delete ('+sel.size+')'}

let dc=0;
function endDrag(){dc=0;document.body.classList.remove('dragging')}
function target(el,path){
  el.addEventListener('dragover',ev=>{ev.preventDefault();ev.stopPropagation();el.classList.add('drop')});
  el.addEventListener('dragleave',()=>el.classList.remove('drop'));
  el.addEventListener('drop',ev=>{ev.preventDefault();ev.stopPropagation();el.classList.remove('drop');endDrag();
    const m=ev.dataTransfer.getData('application/x-kodrop');
    if(m)move(JSON.parse(m),path);else if(ev.dataTransfer.files.length)upload(ev.dataTransfer.files,path)})}
const hasFiles=e=>[...e.dataTransfer.types].includes('Files');
addEventListener('dragenter',e=>{if(hasFiles(e)){dc++;document.body.classList.add('dragging')}});
addEventListener('dragleave',e=>{if(hasFiles(e)&&--dc<=0)endDrag()});
addEventListener('dragover',e=>e.preventDefault());
addEventListener('drop',e=>{e.preventDefault();endDrag();if(e.dataTransfer.files.length)upload(e.dataTransfer.files,cur)});

const q=[];let busy=false;
function upload(files,dir){
  for(const f of files){const bar=h('progress',{max:1,value:0}),label=h('div',{},f.name+' → '+dir);
    const row=h('div',{className:'up'},label,bar);$('#ups').append(row);q.push({f,dir,bar,row,label})}
  pump()}
function pump(){
  if(busy||!q.length)return;busy=true;const j=q.shift(),x=new XMLHttpRequest();
  x.open('POST','/api/upload?path='+enc(j.dir));x.setRequestHeader('X-KoDrop','1');
  x.upload.onprogress=e=>{if(e.lengthComputable)j.bar.value=e.loaded/e.total};
  x.onloadend=()=>{busy=false;
    if(x.status==200)j.row.remove();
    else{let m='';try{m=JSON.parse(x.responseText).error}catch(e){}
      j.label.textContent+=' — failed: '+(m||'network error')+' (tap to dismiss)';j.bar.remove();j.row.onclick=()=>j.row.remove()}
    if(j.dir==cur&&!q.some(k=>k.dir==cur))load(cur);
    pump()};
  const fd=new FormData();fd.append('file',j.f,j.f.name);x.send(fd)}
$('#ub').onclick=()=>$('#fi').click();
$('#fi').onchange=e=>{upload(e.target.files,cur);e.target.value=''};

const dl=p=>{location.href='/api/dl?path='+enc(p)};
function menu(e,p){modal((d,done)=>{
  const b=(t,f,c)=>h('button',{className:c||'',onclick:()=>{done();f()}},t);
  d.append(h('h3',{},e.name),h('div',{className:'sheet'},
    e.dir?b('Open',()=>go(p)):b('Download',()=>dl(p)),
    b('Rename',()=>rename(e,p)),b('Move',()=>pick([p])),b('Delete',()=>del([p]),'dan'),b('Cancel',()=>{})))})}
async function rename(e,p){const n=await ask('Rename',e.name);if(!n||n==e.name)return;
  try{await api('/api/rename',{path:p,name:n})}catch(x){oops(x)}load(cur)}
async function del(ps){
  if(!await sure('Delete '+(ps.length==1?'"'+base(ps[0])+'"':ps.length+' items')+'? This cannot be undone.'))return;
  try{await api('/api/delete',{paths:ps})}catch(x){oops(x)}load(cur)}
async function move(ps,dest){try{await api('/api/move',{paths:ps,dest})}catch(x){oops(x)}load(cur)}
function pick(ps){let at=cur;modal((d,done)=>{
  const t=h('div',{className:'mut'}),L=h('ul',{className:'picker'});
  const show=async p=>{at=p;t.textContent='Into: '+p;L.replaceChildren();
    if(p!='/')L.append(h('li',{onclick:()=>show(parent(p))},'⬆ ..'));
    try{const r=await api('/api/ls?path='+enc(p));
      for(const e of Object.values(r.entries||{}))if(e.dir){const s=join(p,e.name);if(!ps.includes(s))L.append(h('li',{onclick:()=>show(s)},'📁 '+e.name))}}
    catch(x){oops(x)}};
  d.append(h('h3',{},'Move '+(ps.length==1?base(ps[0]):ps.length+' items')),t,L,h('div',{className:'acts'},
    h('button',{onclick:()=>done()},'Cancel'),h('button',{className:'pri',onclick:()=>{done();move(ps,at)}},'Move here')));
  show(cur)})}

$('#back').onclick=()=>history.back();
$('#up').onclick=()=>go(parent(cur));
$('#mk').onclick=async()=>{const n=await ask('New folder','');if(!n)return;
  try{await api('/api/mkdir',{path:join(cur,n)})}catch(x){oops(x)}load(cur)};
$('#smv').onclick=()=>pick([...sel]);
$('#sdel').onclick=()=>del([...sel]);
load(here());
</script></body></html>]==]
