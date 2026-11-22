'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {probeProvider}=require('../scene_provider_probe');
test('preflight never invokes inference, reads body, exposes credential or retries',async()=>{
 for(const status of [200,401,403,404,429,500]) {
  let calls=0,cancelled=false;
  const result=await probeProvider('private-key',async(url,opts)=>{
   calls++;assert.equal(url,'https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1/models');
   assert.equal(opts.method,'GET');assert.equal(opts.body,undefined);assert.equal(opts.redirect,'error');
   return {status,body:{cancel:async()=>{cancelled=true;}},json:()=>assert.fail('no body access')};
  });assert.equal(calls,1);assert.equal(cancelled,true);assert.equal(result.httpStatus,status);
  assert.ok(!JSON.stringify(result).includes('private-key'));
 }
});
test('transport diagnostics are allowlisted; arbitrary error messages never escape',async()=>{
 for(const code of ['ENOTFOUND','secret-content']) {
  const result=await probeProvider('private-key',async()=>{throw Object.assign(Error('private-key'),{cause:{code}});});
  assert.equal(result.transport,code==='ENOTFOUND'?code:'unknown');
  assert.ok(!JSON.stringify(result).includes('private-key'));assert.ok(!JSON.stringify(result).includes('secret-content'));
 }
});
