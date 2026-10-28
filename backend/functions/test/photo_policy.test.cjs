const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {requireGoogle,validateCandidate,quota}=require('../photo_policy');
function candidate() {
  const jpeg=Buffer.from([255,216,255,217]);
  return {photoId:'a'.repeat(32),consentEpoch:1,jpegBase64:jpeg.toString('base64'),metadata:{
    sha256:createHash('sha256').update(jpeg).digest('hex'),trigger:'manual_report',width:720,height:1280,
    modelVersion:'model.1',classMapVersion:'map.1',sessionId:'session.1',capturedAtClient:new Date().toISOString(),predictions:[]}};
}
test('identity comes from verified Google auth, never body ownerUid',()=> {
  assert.throws(()=>requireGoogle({data:{ownerUid:'victim'}}));
  assert.throws(()=>requireGoogle({auth:{uid:'a',token:{firebase:{sign_in_provider:'password'}}}}));
  assert.equal(requireGoogle({data:{expectedUid:'a'},auth:{uid:'a',token:{firebase:{sign_in_provider:'google.com'}}}}),'a');
  assert.throws(()=>requireGoogle({data:{expectedUid:'a'},auth:{uid:'a',token:{firebase:{sign_in_provider:'google.com'},auth_time:1}}},true));
});
test('zero score and empty predictions are valid; whitelist drops extra personal metadata',()=> {
  const c=candidate();c.metadata.gps='private';c.metadata.predictions=[{projectClassId:0,score:0,cx:0.5,cy:0.5,w:1,h:1}];
  const out=validateCandidate(c);assert.equal(out.metadata.predictions[0].score,0);assert.equal(out.metadata.gps,undefined);
  c.metadata.predictions=[];assert.deepEqual(validateCandidate(c).metadata.predictions,[]);
});
test('reject unsafe identifiers, content mismatch, invalid geometry and infinite scores',()=> {
  let c=candidate();c.photoId='../a';assert.throws(()=>validateCandidate(c));
  c=candidate();c.metadata.sha256='0'.repeat(64);assert.throws(()=>validateCandidate(c));
  for(const patch of [{score:NaN},{w:0},{cx:0.99},{projectClassId:-1}]) {
    c=candidate();c.metadata.predictions=[{projectClassId:6,score:0.5,cx:0.5,cy:0.5,w:1,h:1,...patch}];assert.throws(()=>validateCandidate(c));
  }
});
test('server quotas distinguish manual, automatic, scene and enforce daily limits',()=> {
  assert.deepEqual(quota({},'manual_report'),{total:1,automatic:0,scene:0});
  assert.throws(()=>quota({total:100},'manual_report'));
  assert.throws(()=>quota({automatic:50},'low_confidence'));
  assert.throws(()=>quota({scene:10},'scene_sample'));
  assert.equal(quota({automatic:50},'manual_report').automatic,50);
});

test('late A request attached to B token is rejected',()=> {
 assert.throws(()=>requireGoogle({data:{expectedUid:'alice'},auth:{uid:'bob',token:{firebase:{sign_in_provider:'google.com'}}}}),/permission-denied/);
});
