const {test} = require('node:test');
const assert = require('node:assert/strict');
const {requireAppCheck, validateRequest, decodePolyline, normalizeRoute, computeWalkingRoute} = require('../navigation_routes');
const data = {schemaVersion:1,requestId:'route-1',origin:{latitude:22.3,longitude:114.2},destinationPlaceId:'ChIJ_test'};
const line = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
test('requires verified app context but does not require a guest Auth account',()=>{
  for (const request of [{}, {auth:{uid:'a'}}, {app:{}}]) assert.throws(()=>requireAppCheck(request),{code:'unauthenticated'});
  assert.doesNotThrow(()=>requireAppCheck({app:{appId:'verified-android-app'}}));
});
const payload = {routes:[{distanceMeters:100,duration:'90s',polyline:{encodedPolyline:line},legs:[{steps:[{polyline:{encodedPolyline:line},navigationInstruction:{instructions:'Turn left',maneuver:'TURN_LEFT'}}]}]}]};
test('validates finite coordinates and bounded IDs without accepting a relay URL',()=>{
  assert.equal(validateRequest({...data,url:'https://evil.test'}).url,undefined);
  for (const invalid of [{...data,schemaVersion:2},{...data,origin:{latitude:NaN,longitude:0}},{...data,origin:{latitude:91,longitude:0}},{...data,destinationPlaceId:'../../secret'},{...data,requestId:'x'.repeat(101)}]) assert.throws(()=>validateRequest(invalid),{code:'invalid-argument'});
});
test('decodes route geometry and rejects truncated or oversized encodings',()=>{
  assert.deepEqual(decodePolyline(line)[0],{latitude:38.5,longitude:-120.2});
  assert.equal(decodePolyline(line).length,3);
  for (const invalid of ['_', '!!!!!!!!', 'x'.repeat(200001)]) assert.throws(()=>decodePolyline(invalid));
});
test('normalizes Google geometry, instructions and mandatory walking notice',()=>{
  const route=normalizeRoute(payload,'r'); assert.equal(route.provider,'google'); assert.equal(route.steps[0].maneuver,'TURN_LEFT'); assert.equal(route.duration,90); assert.equal(route.notices.length,1);
  assert.throws(()=>normalizeRoute({routes:[]},'r'),{code:'not-found'});
  assert.throws(()=>normalizeRoute({routes:[{...payload.routes[0],duration:'bad'}]},'r'),{code:'unavailable'});
});
test('only sends a fixed walking request; server secret never enters response',async()=>{
  let sent;
  const route=await computeWalkingRoute(data,{key:'secret',fetcher:async(url,options)=>{sent={url,options};return {ok:true,json:async()=>payload};}});
  assert.equal(sent.url,'https://routes.googleapis.com/directions/v2:computeRoutes');
  assert.equal(JSON.parse(sent.options.body).travelMode,'WALK'); assert.equal(JSON.parse(sent.options.body).languageCode,'zh-TW'); assert.equal(JSON.stringify(route).includes('secret'),false);
});
test('maps quota, timeout, malformed response and missing configuration',async()=>{
  await assert.rejects(computeWalkingRoute(data,{key:''}),{code:'failed-precondition'});
  await assert.rejects(computeWalkingRoute(data,{key:'k',fetcher:async()=>({status:429,ok:false})}),{code:'resource-exhausted'});
  await assert.rejects(computeWalkingRoute(data,{key:'k',fetcher:async()=>{throw Error('network');}}),{code:'deadline-exceeded'});
  await assert.rejects(computeWalkingRoute(data,{key:'k',fetcher:async()=>({ok:true,json:async()=>{throw Error('json');}})}),{code:'unavailable'});
});
