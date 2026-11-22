'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const sharp=require('sharp');
const trial=require('../scene_trial');
const scene=require('../scene_description');
const env={SCENE_TRIAL_ID:'room-20261108-v1',SCENE_TRIAL_UID:'uid',SCENE_TRIAL_MAX_REQUESTS:'20',SCENE_TRIAL_BUDGET_MICRO_USD:'10000',QWEN_INPUT_USD_PER_MILLION:'0.2',QWEN_OUTPUT_USD_PER_MILLION:'1.6'};
const cfg=()=>trial.configure(env), id=i=>i.toString(16).padStart(32,'0');
function database() {
 const docs=new Map([['users/uid',{status:'active'}]]);let serial=Promise.resolve();
 return {docs,doc:p=>p,runTransaction(fn){const op=serial.then(async()=>{const writes=[];const value=await fn({get:async p=>({exists:docs.has(p),data:()=>docs.get(p)}),set:(p,v,o)=>writes.push([p,v,o])});for(const [p,v,o] of writes)docs.set(p,o?.merge?{...docs.get(p),...v}:v);return value;});serial=op.catch(()=>{});return op;}};
}
const ledger=db=>db.docs.get('scene_description_trials/room-20261108-v1');
const result=(p=100,c=20)=>({status:'complete',metrics:{usage:{prompt_tokens:p,completion_tokens:c,total_tokens:p+c},estimate:scene.estimate({prompt_tokens:p,completion_tokens:c},{input:0.2,output:1.6})}});
test('trial configuration fixes allowance, account and rates; missing/oversized inputs fail closed',()=>{
 const c=cfg();assert.equal(c.maxRequests,20);assert.equal(c.budgetMicroUsd,10000);assert.equal(c.reserveMicroUsd,2458);
 for(const override of [{SCENE_TRIAL_UID:''},{SCENE_TRIAL_MAX_REQUESTS:'101'},{SCENE_TRIAL_BUDGET_MICRO_USD:'500001'},{QWEN_OUTPUT_USD_PER_MILLION:'0'},{SCENE_TRIAL_ID:'../x'}])assert.throws(()=>trial.configure({...env,...override}),{code:'failed-precondition'});
});
test('one transaction reserves both trial and daily limits; concurrent paid attempts cannot both win',async()=>{
 const db=database(), c=cfg(), now=Date.UTC(2026,10,8);
 const values=await Promise.allSettled([scene.reserve(db,'uid',id(1),now,c),scene.reserve(db,'uid',id(2),now,c)]);
 assert.equal(values.filter(v=>v.status==='fulfilled').length,1);assert.equal(ledger(db).count,1);
 assert.equal(db.docs.get('users/uid/private/sceneDescriptionLimit').count,1);
});
test('twenty-attempt allowance persists across dates and does not reset when daily limit resets',async()=>{
 const db=database(),c=cfg(),now=Date.UTC(2026,10,8);
 for(let i=1;i<=20;i++){await scene.reserve(db,'uid',id(i),now+i*86400000,c);await trial.settle(db,c,id(i),result());}
 assert.equal(ledger(db).count,20);assert.equal(ledger(db).spentMicroUsd,1040);
 await assert.rejects(scene.reserve(db,'uid',id(21),now+30*86400000,c),{code:'resource-exhausted'});
});
test('reserve includes next potential cost, known usage reconciles upward-rounded micro-USD',async()=>{
 const db=database(),c=cfg(),now=Date.UTC(2026,10,8);
 for(let i=1;i<=3;i++){await scene.reserve(db,'uid',id(i),now+i*46000,c);await trial.settle(db,c,id(i),result(8192,512));}
 assert.equal(ledger(db).spentMicroUsd,7374);
 await scene.reserve(db,'uid',id(4),now+4*46000,c);await trial.settle(db,c,id(4),result(8192,512));
 assert.equal(ledger(db).spentMicroUsd,9832);
 await assert.rejects(scene.reserve(db,'uid',id(5),now+5*46000,c),{code:'resource-exhausted'});
});
test('missing usage, timeout or out-of-profile usage halts all remaining attempts',async()=>{
 for(const answer of [null,{status:'rejected',metrics:{usage:null,estimate:null}},result(9000,20)]){
  const db=database(),c=cfg();await scene.reserve(db,'uid',id(1),0,c);await trial.settle(db,c,id(1),answer);
  assert.equal(ledger(db).halted,true);assert.equal(ledger(db).count,1);
  await assert.rejects(scene.reserve(db,'uid',id(2),86400000,c),{code:'resource-exhausted'});
 }
});
test('crash leaves reservation locked; changed allowance fingerprint or repeated ID cannot reopen it',async()=>{
 const db=database(),c=cfg();await scene.reserve(db,'uid',id(1),0,c);
 await assert.rejects(scene.reserve(db,'uid',id(2),86400000,c),{code:'resource-exhausted'});
 await assert.rejects(scene.reserve(db,'uid',id(2),86400000,{...c,fingerprint:'different'}),{code:'failed-precondition'});
 await trial.settle(db,c,id(1),result());
 await assert.rejects(scene.reserve(db,'uid',id(1),86400000,c),{code:'resource-exhausted'});
});
test('wrong Google account is denied before image processing or upstream fetch',async()=>{
 await assert.rejects(scene.handle({app:{appId:'test'},auth:{uid:'other',token:{firebase:{sign_in_provider:'google.com'}}},data:{expectedUid:'other'}},{db:database(),enabled:true,trial:cfg(),key:()=>assert.fail('key accessed'),fetcher:()=>assert.fail('paid request')}),{code:'permission-denied'});
});
test('trial handler counts rejected/failed attempts and halts on indeterminate paid failure',async()=>{
 const jpeg=await sharp({create:{width:32,height:32,channels:3,background:'white'}}).jpeg().toBuffer();
 const db=database(),c=cfg();const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:{schemaVersion:1,requestId:id(1),expectedUid:'uid',mimeType:'image/jpeg',jpegBase64:jpeg.toString('base64')}};
 let calls=0;await assert.rejects(scene.handle(request,{db,enabled:true,trial:c,key:()=> 'mock',rates:{input:0.2,output:1.6},fetcher:async()=>{calls++;throw Error('network error');}}),{code:'unavailable'});
 assert.equal(calls,1);assert.equal(ledger(db).count,1);assert.equal(ledger(db).halted,true);
});
test('scene-only discovery exports no unrelated service and needs only the Qwen secret',()=>{
 const {spawnSync}=require('node:child_process');
 const result=spawnSync(process.execPath,['-e',"const f=require('./'); const e=f.describeScene.__endpoint; console.log(JSON.stringify({names:Object.keys(f),secrets:e.secretEnvironmentVariables?.map(v=>v.key)}));"],{cwd:require('node:path').join(__dirname,'..'),env:{...process.env,SCENE_DESCRIPTION_DEPLOY_ONLY:'true',FIREBASE_CONFIG:JSON.stringify({projectId:'demo-pathguide-scene',storageBucket:'demo-pathguide-scene.appspot.com'})},encoding:'utf8'});
 assert.equal(result.status,0,result.stderr);
 const value=JSON.parse(result.stdout.trim());assert.deepEqual(value.names,['describeScene']);assert.deepEqual(value.secrets,['DASHSCOPE_API_KEY']);
});

function stoppedWithRecovery(now=1000) {
 const c=cfg();
 return {...trial.allocate(null,id(1),c,0),inFlight:null,reservedMicroUsd:0,
  spentMicroUsd:2458,halted:true,lastStatus:'usage-unknown',
  recovery:{id:'singapore-phone-1',status:'ready',baselineCount:1,
   baselineSpentMicroUsd:2458,baselineLastStatus:'usage-unknown',expiresAtMs:now+60000}};
}
test('one recovery preserves unknown cost/history, wins once under concurrency and stops after known success',async()=>{
 const db=database(),c=cfg(),now=1000,original=stoppedWithRecovery(now);
 db.docs.set('scene_description_trials/'+c.id,original);
 const attempts=await Promise.allSettled([scene.reserve(db,'uid',id(2),now,c),scene.reserve(db,'uid',id(3),now,c)]);
 assert.equal(attempts.filter(r=>r.status==='fulfilled').length,1);
 const state=ledger(db);assert.equal(state.count,2);assert.equal(state.spentMicroUsd,2458);
 assert.equal(state.halted,true);assert.equal(state.recovery.status,'consumed');
 assert.equal(state.recovery.baselineLastStatus,'usage-unknown');assert.equal(state.ids[0],id(1));
 await trial.settle(db,c,state.inFlight,result());
 assert.equal(ledger(db).spentMicroUsd,2510);assert.equal(ledger(db).halted,true);
 await assert.rejects(scene.reserve(db,'uid',id(4),now+86400000,c),{code:'resource-exhausted'});
});
test('expired, reused, malformed or stale recovery grants cannot bypass stop or the remaining budget',()=>{
 const c=cfg(),now=1000,old=stoppedWithRecovery(now);
 for(const change of [{status:'consumed'},{id:'../invalid'},{expiresAtMs:now},
  {expiresAtMs:now+86400001},{baselineCount:0},{baselineSpentMicroUsd:0},
  {baselineLastStatus:'complete'}]) {
  assert.throws(()=>trial.allocate({...old,recovery:{...old.recovery,...change}},id(2),c,now),{code:'resource-exhausted'});
 }
 for(const changed of [{inFlight:id(1)},{spentMicroUsd:9000,recovery:{...old.recovery,baselineSpentMicroUsd:9000}}])
  assert.throws(()=>trial.allocate({...old,...changed},id(2),c,now),{code:'resource-exhausted'});
 assert.throws(()=>trial.allocate(old,id(1),c,now),{code:'resource-exhausted'});
});
test('failed recovered inference retains both conservative charges and cannot retry',async()=>{
 const db=database(),c=cfg(),now=1000;
 db.docs.set('scene_description_trials/'+c.id,stoppedWithRecovery(now));
 await scene.reserve(db,'uid',id(2),now,c);await trial.settle(db,c,id(2),null);
 assert.equal(ledger(db).spentMicroUsd,4916);assert.equal(ledger(db).count,2);
 assert.equal(ledger(db).lastStatus,'usage-unknown');assert.equal(ledger(db).halted,true);
 await assert.rejects(scene.reserve(db,'uid',id(3),now+46000,c),{code:'resource-exhausted'});
});
