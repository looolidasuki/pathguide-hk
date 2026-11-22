'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const sharp=require('sharp');
const scene=require('../scene_description');
const trial=require('../scene_trial');
const {mergeSet}=require('./firestore_merge_fake.cjs');
const fixtures=require('../../../app/test/fixtures/scene_validation.json');
const id=n=>n.toString(16).padStart(32,'0');
const env={SCENE_TRIAL_ID:'room-test',SCENE_TRIAL_UID:'uid',SCENE_TRIAL_MAX_REQUESTS:'50',SCENE_TRIAL_BUDGET_MICRO_USD:'10000',QWEN_INPUT_USD_PER_MILLION:'0.2',QWEN_OUTPUT_USD_PER_MILLION:'1.6'};
const observation={category:'table',position:'left',detail:'木枱'};
const usage={prompt_tokens:367,completion_tokens:61,total_tokens:428};
const reply={status:'complete',metrics:{usage,estimate:scene.estimate(usage,{input:0.2,output:1.6})}};
async function data(mode='update') {
  const bytes=await sharp({create:{width:8,height:4,channels:3,background:'white'}}).jpeg().toBuffer();
  return {schemaVersion:2,requestId:id(30),expectedUid:'uid',mode,mimeType:'image/jpeg',jpegBase64:bytes.toString('base64')};
}
function response(sentences,observations=[observation]) {
  return new Response(JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify({sentences,observations})}}],usage}),{headers:{'content-type':'application/json'}});
}
function database(state) {
  const docs=new Map([['users/uid',{status:'active'}],['scene_description_trials/room-test',state]]);
  let serial=Promise.resolve();
  return {docs,doc:p=>p,runTransaction(fn){const op=serial.then(async()=>{
    const writes=[];
    const value=await fn({get:async p=>({exists:docs.has(p),data:()=>docs.get(p)}),set:(p,v,o)=>writes.push([p,v,o])});
    for(const [p,v,o] of writes)docs.set(p,mergeSet(docs.get(p),v,o));
    return value;
  });serial=op.catch(()=>{});return op;}};
}
function stopped(config,now=1000) {
  return {fingerprint:config.fingerprint,count:7,spentMicroUsd:3483,ids:Array.from({length:7},(_,i)=>id(i)),inFlight:null,halted:true,lastStatus:'complete',
    recovery:{status:'consumed'},window:{id:'bounded-mode-test',status:'ready',baseCount:7,maxCount:10,expiresAtMs:now+60000}};
}
test('v2 selects server-owned overview/update contracts and sends only the current photograph',async()=>{
  for(const mode of ['overview','update']) {
    let calls=0;
    const sentences=mode==='overview'?['左邊有木枱。','右邊見到門。']:['左邊見到木枱。'];
    const result=await scene.describe(await data(mode),{key:'fake',rates:{input:0.2,output:1.6},fetcher:async(_,options)=>{
      calls++;
      const body=JSON.parse(options.body);
      assert.deepEqual(body.response_format,{type:'json_object'});
      assert.equal(body.messages.length,2);
      assert.equal(body.messages[1].content.filter(c=>c.type==='image_url').length,1);
      assert.match(body.messages[0].content,mode==='update'?/只寫一句/:/寫兩至三句/);
      return response(sentences);
    }});
    assert.equal(calls,1);
    assert.equal(result.mode,mode);
    assert.equal(result.text,sentences.join(''));
    assert.deepEqual(result.observations,[observation]);
    assert.deepEqual(result.metrics.usage,usage);
  }
});
test('v2 refuses unsafe facts, extra fields, wrong sentence count and malformed modes without repair calls',async()=>{
  for(const [sentences,observations] of [
    [['枱。','門。'],[observation]],
    [['左邊有枱。'],[{...observation,detail:'可以安全通行'}]],
    [['左邊有枱。'],[{...observation,category:'url'}]],
    [['左邊有枱。'],[observation,observation]],
    [['左邊有枱。'],[{...observation,extra:'private'}]],
  ]) {
    let calls=0;
    const result=await scene.describe(await data(),{key:'fake',fetcher:async()=>{calls++;return response(sentences,observations);}});
    assert.equal(calls,1);assert.equal(result.status,'rejected');
    assert.ok(!('text' in result));assert.ok(!('observations' in result));
    assert.deepEqual(result.metrics.usage,usage);
  }
  await assert.rejects(scene.describe({...await data(),mode:'caller-prompt'},{key:'fake',fetcher:()=>assert.fail('network')}),{code:'invalid-argument'});
});
test('bounded window keeps old count/cost/IDs, wins once concurrently, and stops at its ceiling',async()=>{
  const config=trial.configure(env),initial=stopped(config),db=database(initial);
  const attempts=await Promise.allSettled([scene.reserve(db,'uid',id(10),1000,config,3000),scene.reserve(db,'uid',id(11),1000,config,3000)]);
  assert.equal(attempts.filter(r=>r.status==='fulfilled').length,1);
  let ledger=db.docs.get('scene_description_trials/room-test');
  await trial.settle(db,config,ledger.inFlight,reply);
  for(let n=12;n<14;n++) {
    await scene.reserve(db,'uid',id(n),1000+(n-10)*3100,config,3000);
    await trial.settle(db,config,id(n),reply);
  }
  ledger=db.docs.get('scene_description_trials/room-test');
  assert.equal(ledger.count,10);assert.equal(ledger.spentMicroUsd,3483+3*171);
  assert.deepEqual(ledger.ids.slice(0,7),initial.ids);
  assert.equal(ledger.halted,true);assert.equal(ledger.window.status,'consumed');
  await assert.rejects(scene.reserve(db,'uid',id(20),20000,config,3000),{code:'resource-exhausted'});
});
test('window cannot bypass expiry, configuration ceiling, budget or unknown settlement',async()=>{
  const config=trial.configure(env);
  assert.equal(config.maxRequests,50);
  assert.throws(()=>trial.configure({...env,SCENE_TRIAL_MAX_REQUESTS:'101'}),{code:'failed-precondition'});
  for(const change of [
    {window:{...stopped(config).window,expiresAtMs:999}},
    {window:{...stopped(config).window,maxCount:51}},
    {spentMicroUsd:8000}, {lastStatus:'usage-unknown'},
  ]) assert.throws(()=>trial.allocate({...stopped(config),...change},id(30),config,1000),{code:'resource-exhausted'});
  const db=database(stopped(config));
  await scene.reserve(db,'uid',id(30),1000,config,3000);
  await trial.settle(db,config,id(30),null);
  const ledger=db.docs.get('scene_description_trials/room-test');
  assert.equal(ledger.window.status,'halted');assert.equal(ledger.spentMicroUsd,3483+2458);
  await assert.rejects(scene.reserve(db,'uid',id(31),5000,config,3000),{code:'resource-exhausted'});
});
test('pre-provider quota errors are explicitly identifiable without secrets or inference',async()=>{
  Object.assign(process.env,env,{SCENE_DESCRIPTION_ENABLED:'true'});
  const config=trial.configure(env),state=stopped(config);
  state.window.status='consumed';
  const callable=require('../scene_function').createSceneFunction(database(state),{});
  await assert.rejects(callable.run({app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:await data()}),e=>{
    assert.equal(e.code,'resource-exhausted');assert.equal(e.details.beforeProvider,true);assert.equal(e.details.stopReason,'window-expired');assert.equal(e.details.limits.count,7);return true;
  });
});
test('successful mode response returns numerical quota and never stores scene content',async()=>{
  const config=trial.configure(env),db=database(stopped(config,Date.now()));
  const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:await data()};
  const result=await scene.handle(request,{db,enabled:true,trial:config,key:()=> 'fake',rates:{input:0.2,output:1.6},fetcher:async()=>response(['左邊見到木枱。'])});
  assert.equal(result.limits.count,8);assert.equal(result.limits.maxRequests,50);
  assert.equal(result.limits.windowRemaining,2);assert.equal(result.limits.spentMicroUsd,3483+171);
  assert.ok(!JSON.stringify([...db.docs.values()]).includes('木枱'));
  assert.ok(!JSON.stringify([...db.docs.values()]).includes('observations'));
});
test('post-provider settlement failure is never labelled safe to resend',async()=>{
  const config=trial.configure(env),db=database(stopped(config,Date.now()));
  const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:await data()};
  let calls=0;
  await assert.rejects(scene.handle(request,{db,enabled:true,trial:config,key:()=> 'fake',rates:{input:0.2,output:1.6},fetcher:async()=>{
    calls++;db.docs.get('scene_description_trials/room-test').fingerprint='changed';
    return response(['左邊見到木枱。']);
  }}),error=>{assert.equal(error.code,'failed-precondition');assert.notEqual(error.beforeProvider,true);return true;});
  assert.equal(calls,1);assert.equal(db.docs.get('scene_description_trials/room-test').inFlight,id(30));
});

test('budget reserve stop is distinguishable from expiry/count/in-flight with no state reset',()=>{
  const config=trial.configure(env),base={...stopped(config),count:16,ids:Array.from({length:16},(_,i)=>id(i)),spentMicroUsd:7861,window:{...stopped(config).window,maxCount:50}};
  const original=structuredClone(base);
  const status=trial.inspect(base,config,1000);
  assert.equal(status.stopReason,'budget-reserve');assert.equal(status.limits.count,16);assert.equal(status.limits.spentMicroUsd,7861);assert.equal(status.limits.windowRemaining,34);
  assert.deepEqual(base,original);
  for(const [changes,reason] of [[{window:{...base.window,expiresAtMs:999}},'window-expired'],[{inFlight:id(99)},'in-flight'],[{lastStatus:'usage-unknown'},'usage-unknown'],[{count:50,ids:Array.from({length:50},(_,i)=>id(i))},'trial-count']]) {
    assert.equal(trial.inspect({...base,...changes},config,1000).stopReason,reason);
  }
});
test('read-only status survives restart with account checks and never reserves, captures or reads provider key',async()=>{
  const config=trial.configure(env),base={...stopped(config,Date.now()),spentMicroUsd:7861},db=database(base);
  db.docs.set('users/uid/private/sceneDescriptionLimit',{lastResult:{requestId:id(29),status:'rejected',metrics:reply.metrics,rejectionReason:'answer-format',rejectionDetail:'observation-category',text:'private discarded text',observations:[observation]}});
  const before=structuredClone([...db.docs]);
  const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:{operation:'status',expectedUid:'uid'}};
  const options={db,trial:config,enabled:true,key:()=>assert.fail('provider key read'),fetcher:()=>assert.fail('paid request')};
  const result=await scene.handle(request,options);
  assert.equal(result.stopReason,'budget-reserve');assert.equal(result.recentResults[0].rejectionDetail,'observation-category');
  assert.ok(!JSON.stringify(result).includes('private'));assert.ok(!JSON.stringify(result).includes('observations'));
  assert.deepEqual([...db.docs],before);
  await assert.rejects(scene.handle({...request,auth:{uid:'other',token:{firebase:{sign_in_provider:'google.com'}}},data:{operation:'status',expectedUid:'other'}},options),{code:'permission-denied'});
  db.docs.set('account_deletions/uid',{status:'pending'});
  await assert.rejects(scene.handle(request,options),{code:'permission-denied'});
});
test('recent numeric results survive subsequent reservation and retain at most three, without photo/text',async()=>{
  const config=trial.configure(env),base=stopped(config,Date.now());base.window.maxCount=50;
  const db=database(base);
  for(let i=0;i<4;i++) {
    const current=await data();current.requestId=id(40+i);
    const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:current};
    // Advance only mock rate guard; real trial totals/costs remain monotonic.
    const counter=db.docs.get('users/uid/private/sceneDescriptionLimit');if(counter)counter.blockedUntil=0;
    await scene.handle(request,{db,enabled:true,trial:config,key:()=> 'mock',rates:{input:0.2,output:1.6},fetcher:async()=>i===0?response(['右邊見到門。'],[{...observation,category:'cupboard'}]):response(['左邊見到木枱。'])});
    const written=db.docs.get('users/uid/private/sceneDescriptionLimit');
    assert.deepEqual(written.lastResult,written.recentResults.at(-1));
    assert.equal(written.count,i+1);
    assert.deepEqual(written.ids,Array.from({length:i+1},(_,n)=>id(40+n)));
    assert.ok(written.blockedUntil>Date.now());
  }
  const counter=db.docs.get('users/uid/private/sceneDescriptionLimit');
  assert.equal(counter.recentResults.length,3);assert.deepEqual(counter.recentResults.map(v=>v.requestId),[id(41),id(42),id(43)]);
  assert.equal(db.docs.get('scene_description_trials/room-test').count,11);
  assert.ok(!JSON.stringify([...db.docs]).includes('木枱'));assert.ok(!JSON.stringify(counter).includes('base64'));
});
test('format failures expose only allowlisted structural reason and examples remain server-owned',async()=>{
  const cases=[
    [[{...observation,category:'cupboard'}],'observation-category'],
    [[{...observation,position:'front'}],'observation-position'],
    [[{...observation,detail:'木枱。'}],'observation-detail'],
    [[observation,observation],'observation-duplicate'],
    [[{...observation,detail:'可以安全通行'}],'observation-safety'],
  ];
  for(const [observations,detail] of cases) {
    const result=await scene.describe(await data(),{key:'fake',fetcher:async(_,options)=>{
      const body=JSON.parse(options.body);assert.match(body.messages[0].content,/格式例子/);assert.match(body.messages[0].content,/最多三項/);
      return response(['左邊見到木枱。'],observations);
    }});
    assert.equal(result.status,'rejected');assert.equal(result.rejectionDetail,detail);assert.ok(!('text' in result));assert.ok(!('observations' in result));
  }
});
test('higher supported budget does not amend a live allowance or bypass its fingerprint',()=>{
  const oldConfig=trial.configure(env),higher=trial.configure({...env,SCENE_TRIAL_BUDGET_MICRO_USD:'500000'}),old=stopped(oldConfig);
  assert.equal(oldConfig.budgetMicroUsd,10000);assert.equal(higher.budgetMicroUsd,500000);
  assert.notEqual(higher.fingerprint,oldConfig.fingerprint);
  assert.throws(()=>trial.allocate(old,id(40),higher,1000),{code:'failed-precondition'});
  assert.equal(old.fingerprint,oldConfig.fingerprint);assert.equal(old.spentMicroUsd,3483);
});

test('shared synthetic kitchen/bathroom fixtures retain complete overview/update validation',async()=>{
  for (const fixture of fixtures.accepted) {
    for (const mode of ['overview','update']) {
      const sentences=mode==='overview'?fixture.sentences:fixture.sentences.slice(0,1);
      let calls=0;
      const result=await scene.describe(await data(mode),{key:'fake',fetcher:async()=>{calls++;return response(sentences,fixture.observations);}});
      assert.equal(calls,1);assert.equal(result.status,'complete');
      assert.equal(result.text,sentences.join(''));assert.deepEqual(result.observations,fixture.observations);
    }
  }
});
test('shared noun exceptions cannot hide distance, floor, safety or navigation restrictions',()=>{
  for (const text of fixtures.rejectedText) {
    assert.throws(()=>scene.validateText(text,{min:1,max:1}),{code:'data-loss'},text);
    assert.throws(()=>scene.validateObservations([{category:'other',position:'left',detail:text.replace(/[。！？]$/u,'')}]),{code:'data-loss'},text);
  }
});
test('synthetic malformed observations retain precise rejection details and return no partial content',async()=>{
  for (const fixture of fixtures.rejectedObservations) {
    const result=await scene.describe(await data(),{key:'fake',fetcher:async()=>response(['右邊有洗衣機。'],fixture.items)});
    assert.equal(result.status,'rejected');assert.equal(result.rejectionDetail,fixture.detail==='observation-content'?(fixture.items[0].detail.includes('安全')?'observation-safety':'observation-distance'):fixture.detail);
    assert.ok(!('text' in result));assert.ok(!('observations' in result));assert.deepEqual(result.metrics.usage,usage);
  }
});

test('full-map telemetry replacement clears optional rejection keys and stale metrics while preserving counters',async()=>{
  const db=database();
  const path='users/uid/private/sceneDescriptionLimit';
  db.docs.set(path,{unrelated:{preserve:true}});
  for (let i=0;i<3;i++) {
    const current=await data();current.requestId=id(60+i);
    const counter=db.docs.get(path);counter.blockedUntil=0;
    const request={app:{appId:'test'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}},data:current};
    await scene.handle(request,{db,enabled:true,key:()=> 'fake',rates:{input:0.2,output:1.6},fetcher:async()=>{
      const payload={choices:[{finish_reason:i===1?'content_filter':'stop',message:{content:JSON.stringify({sentences:[i===0?'請向左行。':'右邊有洗手盆。'],observations:[]})}}],...(i<2?{usage}:{})};
      return new Response(JSON.stringify(payload),{headers:{'content-type':'application/json'}});
    }});
    const written=db.docs.get(path);
    assert.deepEqual(written.unrelated,{preserve:true});assert.equal(written.count,i+1);
    assert.equal(written.ids.length,i+1);assert.equal(written.lastResult.requestId,current.requestId);
    assert.deepEqual(written.lastResult,written.recentResults.at(-1));
    if(i===1) {assert.equal(written.lastResult.rejectionReason,'provider-refusal');assert.ok(!('rejectionDetail' in written.lastResult));}
    if(i===2) {
      assert.equal(written.lastResult.status,'complete');
      assert.ok(!('rejectionReason' in written.lastResult));assert.ok(!('rejectionDetail' in written.lastResult));
      assert.equal(written.lastResult.metrics.usage,null);assert.equal(written.lastResult.metrics.estimate,null);
    }
  }
  const history=db.docs.get(path).recentResults;
  assert.equal(history.length,3);assert.equal(history[0].rejectionDetail,'text-navigation');
  assert.equal(history[1].rejectionReason,'provider-refusal');
  assert.ok(!JSON.stringify([...db.docs]).includes('洗手盆'));
});

test('100 cumulative attempts and five-day window preserve spent history and stop on expiry or unknown usage',()=>{
 const c=trial.configure({...env,SCENE_TRIAL_MAX_REQUESTS:'100',SCENE_TRIAL_BUDGET_MICRO_USD:'500000'}),now=1000;
 const s=stopped(c,now);s.window.maxCount=100;s.window.expiresAtMs=now+5*86400000;
 assert.equal(trial.allocate(s,id(99),c,now).count,8);assert.equal(s.spentMicroUsd,3483);
 assert.equal(trial.inspect(s,c,now+5*86400000).stopReason,'window-expired');
 assert.equal(trial.inspect({...s,lastStatus:'usage-unknown'},c,now).stopReason,'usage-unknown');
 assert.throws(()=>trial.allocate({...s,window:{...s.window,expiresAtMs:s.window.expiresAtMs+1}},id(99),c,now));
});

test('content diagnostics expose fixed classes for text and observations',()=>{
 const cases={number:'有3個櫃',distance:'門距離三米',floor:'位於三樓',destination:'這裡是目的地',safety:'可以安全通行',navigation:'向左行',advice:'建議停低',simplified:'右邊有门'};
 for(const [key,phrase] of Object.entries(cases)) {
  assert.throws(()=>scene.validateText(phrase+'。未能確認。'),e=>e.rejectionReason==='disallowed-content'&&e.rejectionDetail==='text-'+key);
  assert.throws(()=>scene.validateObservations([{category:'other',position:'left',detail:phrase}]),e=>e.rejectionDetail==='observation-'+key);
 }
});
