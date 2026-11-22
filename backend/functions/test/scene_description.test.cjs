'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const sharp = require('sharp');
const {mergeSet}=require('./firestore_merge_fake.cjs');
const {describe,cleanImage,validateText,renderAnswer,usageOf,estimate,reserve,handle,BASE} = require('../scene_description');
const good = '畫面左邊有張木枱。中間見到一道門，右邊有張凳。';
const id = 'a'.repeat(32);
const usage = {prompt_tokens:110,completion_tokens:30,total_tokens:140};
async function request() {
  const jpeg = await sharp({create:{width:8,height:4,channels:3,background:'#bada55'}}).jpeg().toBuffer();
  return {schemaVersion:1,requestId:id,mimeType:'image/jpeg',jpegBase64:jpeg.toString('base64')};
}
const response = (payload, status=200) => new Response(JSON.stringify(payload),{status,headers:{'content-type':'application/json'}});
const payload = (text=good, reason='stop') => ({choices:[{finish_reason:reason,message:{content:JSON.stringify({sentences:text.split(/(?<=[。！？])/u).filter(Boolean)})}}],usage});
function fakeDb() {
  let state;
  let active = true, deleted = false;
  let serial = Promise.resolve();
  return {doc:p=>p, deactivate(){active=false;deleted=true;}, get value(){return state;}, runTransaction(fn) {
    const op=serial.then(()=>fn({get:async path=>path === 'users/uid' ? {data:()=>({status:active?'active':'deleting'})} : path === 'account_deletions/uid' ? {exists:deleted} : {data:()=>state},set:(_,value,opts)=>{state=mergeSet(state,value,opts);}}));
    serial=op.catch(()=>{}); return op;
  }};
}
test('structured fields render two or three complete sentences despite JSON whitespace or omitted terminal punctuation',()=>{
  assert.equal(renderAnswer(JSON.stringify({sentences:['畫面左邊有張木枱','中間見到一道門，右邊有張凳。']},null,2)),good);
  assert.equal(renderAnswer(JSON.stringify({sentences:[' 左邊有枱。 ','中間有門','右邊有凳！']})),'左邊有枱。中間有門。右邊有凳！');
});
test('structured output cannot hide unsafe content, extra sentences, unknown fields or malformed partial JSON',()=>{
  for (const content of [
    null, ['{"sentences":["枱。","門。"]}'],
    good, '{"sentences":["枱。","門。"', '```json\n{"sentences":["枱。","門。"]}\n```',
    JSON.stringify({sentences:['枱。','門。'],extra:'向左行'}),
    ...[null,[],{},['枱。'],['枱。','門。','凳。','櫃。'],['枱。門。','凳。'],['枱。',42],
      ['枱。',''],['枱。','\n門。'],['枱。','請向左行。'],['枱。','右邊可以安全通行。'],
      ['枱。','距離三米。'],['枱。','右邊有门。']].map(sentences=>JSON.stringify({sentences})),
  ]) assert.throws(()=>renderAnswer(content),{code:'data-loss'});
});
test('one bounded, non-thinking, non-streaming POST; metadata-only measurement',async()=>{
  let calls=0;
  const result=await describe(await request(),{key:'fake-test-key',base:BASE,rates:{input:1,output:2},fetcher:async(url,opts)=>{
    calls++; assert.equal(url,'https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1/chat/completions');
    assert.equal(opts.redirect,'error'); assert.ok(opts.signal);
    const body=JSON.parse(opts.body);
    assert.equal(body.model,'qwen3-vl-plus'); assert.equal(body.enable_thinking,false);
    assert.equal(body.stream,false); assert.deepEqual(body.response_format,{type:'json_object'}); assert.match(body.messages[0].content,/JSON/u); assert.equal(body.max_tokens,512);
    assert.equal(body.vl_high_resolution_images,false); assert.equal(body.messages[1].content[0].max_pixels,262144);
    assert.match(body.messages[1].content[0].image_url.url,/^data:image\/jpeg;base64,/);
    return response(payload());
  }});
  assert.equal(calls,1); assert.equal(result.text,good); assert.equal(result.status,'complete');
  assert.deepEqual(result.metrics.usage,usage); assert.equal(result.metrics.estimate.notBillingCap,true);
  assert.ok(!JSON.stringify(result.metrics).includes(good));
});
test('truncated/filter/empty/unsafe/malformed results never expose partial text; usage retained',async()=>{
  for(const p of [payload(good,'length'),payload(good,'content_filter'),payload(''),payload('前方可以安全通行。請向左行。'),null,payload('左邊有一張枱。'),payload('畫面有張枱。前方有門。第三句。第四句。'),{}, {error:{message:'sensitive'}}]) {
    const result=await describe(await request(),{key:'fake',fetcher:async()=>response(p)});
    assert.equal(result.status,'rejected'); assert.ok(!Object.hasOwn(result,'text'));
    if(p?.usage) assert.deepEqual(result.metrics.usage,usage);
  }
});
test('missing or invalid usage cannot invent tokens or a zero-dollar estimate',async()=>{
  const p=payload(); delete p.usage;
  const result=await describe(await request(),{key:'fake',rates:{input:1,output:2},fetcher:async()=>response(p)});
  assert.equal(result.status,'complete'); assert.equal(result.metrics.usage,null); assert.equal(result.metrics.estimate,null);
  assert.equal(usageOf({...usage,total_tokens:0}),null);
  assert.equal(usageOf({...usage,prompt_tokens:-1}),null);
  assert.equal(estimate(usage,{input:null,output:null}),null);
});
test('rejections expose only a fixed reason, retain usage, and never retry or return content',async()=>{
  const cases = [
    [payload(`${good}\n凳。`),'answer-format'],
    [payload('枱。'),'sentence-count'],
    [payload('枱。門。凳。櫃。'),'sentence-count'],
    [payload('枱'.repeat(241)+'。門。'),'answer-length'],
    [payload('前方可以安全通行。請向左行。'),'disallowed-content'],
    [payload('前方有门。左邊有枱。'),'disallowed-content'],
    [payload(good,'length'),'incomplete-answer'],
    [payload(good,'content_filter'),'provider-refusal'],
    [{...payload(),choices:[{finish_reason:'stop',message:{refusal:'private content'}}]},'provider-refusal'],
    [{error:{message:'private content'}},'provider-response'],
  ];
  for (const [p, reason] of cases) {
    let calls=0;
    const result=await describe(await request(),{key:'fake',fetcher:async()=>{calls++;return response(p);}});
    assert.equal(calls,1);
    assert.equal(result.status,'rejected');
    assert.equal(result.rejectionReason,reason);
    assert.deepEqual(Object.keys(result).sort(),['metrics',...(result.rejectionDetail?['rejectionDetail']:[]),'rejectionReason','requestId','status']);
    if(result.rejectionDetail) assert.ok(['text-safety','text-simplified','text-content','text-length','sentence-count','provider-truncated'].includes(result.rejectionDetail));
    if (p.usage) assert.deepEqual(result.metrics.usage,usage);
    assert.ok(!JSON.stringify(result).includes('private content'));
  }
});
test('JPEG only, byte/pixel/base64 limits; strip image metadata',async()=>{
  const data=await request(); assert.ok((await cleanImage(data)).length);
  for(const d of [{...data,mimeType:'image/png'},{...data,jpegBase64:'a'.repeat(800000)},
    {...data,jpegBase64:Buffer.from('not-jpeg').toString('base64')},{...data,requestId:'bad'},
    {...data,jpegBase64:`${data.jpegBase64}\n`}]) await assert.rejects(cleanImage(d),{code:'invalid-argument'});
  const large=await sharp({create:{width:1281,height:1,channels:3,background:'white'}}).jpeg().toBuffer();
  await assert.rejects(cleanImage({...data,jpegBase64:large.toString('base64')}),{code:'invalid-argument'});
  const oriented=await sharp(Buffer.from(data.jpegBase64,'base64')).withMetadata({orientation:6}).jpeg().toBuffer();
  const cleaned=await cleanImage({...data,jpegBase64:oriented.toString('base64')});
  const info=await sharp(cleaned).metadata(); assert.equal(info.orientation,undefined); assert.equal(info.exif,undefined);
});
test('server reduces a full-size accepted JPEG to a bounded 512px cloud image',async()=>{
  const jpeg=await sharp({create:{width:1280,height:960,channels:3,background:'white'}}).jpeg().toBuffer();
  const clean=await cleanImage({...await request(),jpegBase64:jpeg.toString('base64')});
  const info=await sharp(clean).metadata();assert.equal(info.width,512);assert.equal(info.height,384);
});
test('transport errors/429/malformed or overlong upstream body are sanitized, never retried',async()=>{
  for(const [fetcher,code] of [
    [async()=>{throw Error('secret upstream content');},'unavailable'],
    [async()=>response({error:'secret'},429),'resource-exhausted'],
    [async()=>new Response('bad',{headers:{'content-type':'application/json'}}),'data-loss'],
    [async()=>new Response('x'.repeat(32769),{headers:{'content-type':'application/json'}}),'data-loss'],
  ]) {
    let calls=0;
    await assert.rejects(describe(await request(),{key:'fake',fetcher:async(...args)=>{calls++;return fetcher(...args);}}),{code});
    assert.equal(calls,1);
  }
});
test('abort and deadline terminate the entire response read; no content leaks or retry',async()=>{
  const abort=new AbortController();
  const op=describe(await request(),{key:'fake',signal:abort.signal,fetcher:async(_,opts)=>{
    abort.abort(); throw opts.signal.reason;
  }});
  await assert.rejects(op,{code:'cancelled'});
  const alreadyCancelled=new AbortController(); alreadyCancelled.abort();
  await assert.rejects(describe(await request(),{key:'fake',signal:alreadyCancelled.signal,fetcher:()=>assert.fail('cancelled before send')}),{code:'cancelled'});
  await assert.rejects(describe(await request(),{key:'fake',timeoutMs:5,fetcher:async(_,opts)=>
    new Promise((_,reject)=>opts.signal.addEventListener('abort',()=>reject(opts.signal.reason),{once:true}))}),{code:'deadline-exceeded'});
});
test('unapproved base/key never sends a request',async()=>{
  for(const config of [{key:''},{key:'sk-sp-token'},{key:'fake',base:'https://evil.invalid'},{key:'fake',base:'https://cn-hongkong.maas.qwencloudapi.com/compatible-mode/v1'}]) {
    await assert.rejects(describe(await request(),{...config,fetcher:()=>assert.fail('network')}),{code:'failed-precondition'});
  }
});
test('account limiter reserves across concurrency, retains failed IDs, enforces daily cap',async()=>{
  const db=fakeDb(), now=Date.UTC(2026,10,7);
  const outcomes=await Promise.allSettled([reserve(db,'uid',id,now),reserve(db,'uid','b'.repeat(32),now)]);
  assert.equal(outcomes.filter(r=>r.status==='fulfilled').length,1);
  await assert.rejects(reserve(db,'uid',id,now+46000),{code:'resource-exhausted'});
  for(let i=1;i<20;i++) await reserve(db,'uid',i.toString(16).padStart(32,'0'),now+i*46000);
  await assert.rejects(reserve(db,'uid','f'.repeat(32),now+20*46000),{code:'resource-exhausted'});
  assert.equal(db.value.count,20);
  assert.deepEqual(Object.keys(db.value).sort(),['blockedUntil','count','day','ids']);
  await reserve(db,'uid','f'.repeat(32),now+86400000);
  assert.equal(db.value.count,1);
});
test('description grammar rejects instructions, distance and floor guesses',()=>{
  assert.equal(validateText(good),good); assert.equal(validateText('前方見到樓梯。左邊有扶手。'),'前方見到樓梯。左邊有扶手。');
  for(const text of ['左邊有張枱。右邊有門，距離三米。','這是一个门。你可以走過去。','畫面係三樓。向右行。','<script>。門。','前方有門。靠左行啦。','前方有門。你可行入去。','枱。門。\n再講。']) assert.throws(()=>validateText(text));
});

test('callable guard uses Google identity, App Check, expected UID and enable gate before any paid call',async()=>{
  const data={...await request(),expectedUid:'uid'};
  const auth={uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}};
  const app={appId:'attested'};
  const opts={db:fakeDb(),enabled:true,key:()=> 'fake',fetcher:()=>assert.fail('network')};
  for(const [r,code] of [[{data,auth},'unauthenticated'],[{data,app},'unauthenticated'],
    [{data,app,auth:{uid:'uid',token:{}}},'unauthenticated'],
    [{data:{...data,expectedUid:'other'},app,auth},'permission-denied']]) {
    await assert.rejects(handle(r,opts),{code});
  }
  await assert.rejects(handle({data,app,auth},{...opts,enabled:false}),{code:'failed-precondition'});
  opts.db.deactivate();
  await assert.rejects(handle({data,app,auth},opts),{code:'permission-denied'});
});
test('callable stores only latest safe metrics and cannot resurrect a deleted account',async()=>{
  const data={...await request(),expectedUid:'uid'};
  const r={data,app:{appId:'attested'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}}};
  const db=fakeDb();
  const result=await handle(r,{db,enabled:true,key:()=> 'fake',fetcher:async()=>response(payload())});
  assert.equal(result.text,good);
  const {receivedAtMs,...safe}=db.value.lastResult;assert.ok(Number.isSafeInteger(receivedAtMs));assert.deepEqual(safe,{requestId:id,status:'complete',metrics:result.metrics});
  assert.ok(!JSON.stringify(db.value).includes(good)); assert.ok(!JSON.stringify(db.value).includes('base64'));
  const db2=fakeDb();
  await handle(r,{db:db2,enabled:true,key:()=> 'fake',fetcher:async()=>{db2.deactivate();return response(payload());}});
  assert.equal(db2.value.lastResult,undefined);
});
test('callable retains a rejection category with numerical usage, never the rejected answer',async()=>{
  const data={...await request(),expectedUid:'uid'};
  const r={data,app:{appId:'attested'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}}};
  const db=fakeDb();
  const privateAnswer='前方可以安全通行。請向左行。';
  const result=await handle(r,{db,enabled:true,key:()=> 'fake',fetcher:async()=>response(payload(privateAnswer))});
  assert.equal(result.rejectionReason,'disallowed-content');
  const {receivedAtMs,...safe}=db.value.lastResult;assert.ok(Number.isSafeInteger(receivedAtMs));assert.deepEqual(safe,{requestId:id,status:'rejected',metrics:result.metrics,rejectionReason:'disallowed-content',rejectionDetail:'text-safety'});
  assert.ok(!JSON.stringify(db.value).includes(privateAnswer));
  assert.ok(!JSON.stringify(db.value).includes('base64'));
});
test('exported Firebase callable remains closed by default, before secret/Firestore access',async()=>{
  const previous=process.env.SCENE_DESCRIPTION_ENABLED;
  delete process.env.SCENE_DESCRIPTION_ENABLED;
  try {
    process.env.FIREBASE_CONFIG=JSON.stringify({projectId:'demo-pathguide-scene',storageBucket:'demo-pathguide-scene.appspot.com'});
    const callable=require('../index').describeScene;
    const r={data:{...await request(),expectedUid:'uid'},app:{appId:'attested'},auth:{uid:'uid',token:{firebase:{sign_in_provider:'google.com'}}}};
    await assert.rejects(callable.run(r),{code:'failed-precondition'});
    await assert.rejects(callable.run({...r,app:undefined}),{code:'unauthenticated'});
  } finally {
    if(previous === undefined) delete process.env.SCENE_DESCRIPTION_ENABLED;
    else process.env.SCENE_DESCRIPTION_ENABLED=previous;
  }
});

test('HTTP failure diagnostics retain only numeric status and never upstream content',async()=>{
 for(const status of [400,401,403,404,429,500]) {
  await assert.rejects(describe(await request(),{key:'private-key',fetcher:async()=>response({error:'private-key and private content'},status)}),e=>{
   assert.deepEqual(e.diagnostic,{stage:'upstream-http',httpStatus:status});
   assert.ok(!JSON.stringify(e).includes('private-key'));return true;
  });
 }
});
