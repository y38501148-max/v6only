const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const release={available:true,current_version:'2.1.11',latest_version:'2.1.12',download_url:'https://github.com/y38501148-max/v6only/releases/download/v2.1.12/V6Only-2.1.12-Windows-x64.msi',release_url:'https://github.com/y38501148-max/v6only/releases/tag/v2.1.12'};
async function app(initial=release){
 const nodes=new Map(),calls=[],events={},store=new Map();let result=initial,now=10000000,tick;
 const element=id=>{if(!nodes.has(id))nodes.set(id,{hidden:true,disabled:false,textContent:''});return nodes.get(id)};
 const context=vm.createContext({
  document:{getElementById:element,hidden:false,addEventListener:(name,fn)=>{events[name]=fn}},
  window:{__TAURI__:{core:{invoke:async(command,args)=>{calls.push([command,args]);if(command==='check_update'){if(result instanceof Error)throw result;return result}}}},addEventListener:(name,fn)=>{events[name]=fn}},
  Date:{now:()=>now},localStorage:{getItem:k=>store.get(k),setItem:(k,v)=>store.set(k,v)},setInterval:fn=>{tick=fn},
 });
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../ui/update.js'),'utf8'),context);
 const flush=()=>new Promise(setImmediate);await flush();
 return {element,calls,store,events,context,flush,manual:()=>element('check-update').onclick(),tick:()=>tick(),advance:ms=>{now+=ms},setResult:r=>{result=r}};
}
test('Release notice works independently of missing background service',async()=>{
 const a=await app();assert.equal(a.element('update-banner').hidden,false);assert.match(a.element('update-title').textContent,/2.1.12/);
 await a.element('download-update').onclick();assert.equal(a.calls.at(-1)[0],'open_update');assert.equal(a.calls.at(-1)[1].url,release.download_url);
 await a.element('release-notes').onclick();assert.equal(a.calls.at(-1)[0],'open_update');assert.equal(a.calls.at(-1)[1].url,release.release_url);
 assert.ok(!a.calls.some(([command])=>command==='service'||command==='install_service'));
});
test('Dismissed version stays quiet and manual check restores notice',async()=>{
 const a=await app();a.element('dismiss-update').onclick();assert.equal(a.element('update-banner').hidden,true);
 a.advance(6*3600000);a.tick();await a.flush();assert.equal(a.element('update-banner').hidden,true);
 await a.manual();assert.equal(a.element('update-banner').hidden,false);
});
test('Periodic checks are bounded and hidden windows do not poll',async()=>{
 const a=await app();a.tick();await a.flush();assert.equal(a.calls.length,1);
 a.advance(6*3600000);a.context.document.hidden=true;a.tick();await a.flush();assert.equal(a.calls.length,1);
 a.context.document.hidden=false;a.events.visibilitychange();await a.flush();assert.equal(a.calls.length,2);
});
test('Missing installer is not reported as latest and failures preserve notice',async()=>{
 const a=await app({available:false,latest_version:'2.1.12',release_url:release.release_url});assert.match(a.element('update-status').textContent,/暂未提供/);assert.equal(a.element('update-banner').hidden,true);
 a.setResult(release);await a.manual();a.setResult(new Error('offline'));await a.manual();assert.equal(a.element('update-banner').hidden,false);assert.match(a.element('update-status').textContent,/检查失败/);assert.equal(a.element('check-update').disabled,false);
});
