const {test,before,beforeEach,after}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
if(!process.env.FIRESTORE_EMULATOR_HOST||!process.env.FIREBASE_STORAGE_EMULATOR_HOST) throw new Error('Emulators required; will not access production');
const f=require('../functions');
const {createRequire}=require('node:module');
const functionRequire=createRequire(require.resolve('../functions'));
const {getFirestore}=functionRequire('firebase-admin/firestore');
const {getStorage}=functionRequire('firebase-admin/storage');
const sharp=functionRequire('sharp');
const {initializeTestEnvironment,assertFails}=require('@firebase/rules-unit-testing');
const {ref,getBytes,uploadBytes}=require('firebase/storage');
const {readFileSync}=require('node:fs');
const db=getFirestore(),bucket=getStorage().bucket();
let rules;
const uid='photo-alice';
const request=(data={},who=uid,age=0)=>({auth:{uid:who,token:{firebase:{sign_in_provider:'google.com'},auth_time:Math.floor(Date.now()/1000)-age}},data:{...data,expectedUid:who}});
let image;
before(async()=> {
  image=await sharp({create:{width:64,height:96,channels:3,background:{r:40,g:90,b:160}}}).jpeg().toBuffer();
  rules=await initializeTestEnvironment({projectId:'demo-pathguide-phase3',storage:{host:'127.0.0.1',port:9199,rules:readFileSync('storage.rules','utf8')}});
});
after(async()=>rules.cleanup());
beforeEach(async()=> {
  await db.recursiveDelete(db.doc(`users/${uid}`));await db.doc(`account_deletions/${uid}`).delete();
  await bucket.deleteFiles({prefix:`unconfirmed_photos/${uid}/`});
  await db.doc(`users/${uid}`).set({status:'active',schemaVersion:1});
});
function candidate(id='a'.repeat(32),epoch=1) {
  return {photoId:id,consentEpoch:epoch,jpegBase64:image.toString('base64'),metadata:{sha256:createHash('sha256').update(image).digest('hex'),
    trigger:'manual_report',width:64,height:96,modelVersion:'test.1',classMapVersion:'map.1',sessionId:'scene.1',capturedAtClient:new Date().toISOString(),predictions:[]}};
}
const enable=()=>f.setPhotoConsent.run(request({enabled:true,noticeVersion:'2026-10-23.personal-photos.v1'}));
test('server denies upload before consent; validates JPEG; retry creates one object and record',async()=> {
  await assert.rejects(()=>f.submitPhoto.run(request(candidate())));
  await enable();
  assert.equal((await f.submitPhoto.run(request(candidate()))).uploadStatus,'validated');
  await f.submitPhoto.run(request(candidate()));
  const docs=await db.collection(`users/${uid}/photos`).get();assert.equal(docs.size,1);
  const p=docs.docs[0].data();assert.equal(p.ownerUid,uid);assert.equal(p.reviewStatus,'pending');assert.ok(p.objectGeneration);
  const [objects]=await bucket.getFiles({prefix:`unconfirmed_photos/${uid}/`});assert.equal(objects.length,1);
  const [bytes]=await objects[0].download();const metadata=await sharp(bytes).metadata();assert.equal(metadata.exif,undefined);
  assert.equal((await db.doc(`users/${uid}/photoQuotas/${new Date().toISOString().slice(0,10)}`).get()).data().total,1);
});
test('withdrawal invalidates old epoch; late finalized objects are removed',async()=> {
  await enable();await f.setPhotoConsent.run(request({enabled:false,noticeVersion:'2026-10-23.personal-photos.v1'}));
  await assert.rejects(()=>f.submitPhoto.run(request(candidate())));
  const file=bucket.file(`unconfirmed_photos/${uid}/${'a'.repeat(32)}.jpg`);
  await file.save(image,{metadata:{metadata:{consentEpoch:'1',sourceSha256:'old'}}});
  const [m]=await file.getMetadata();
  await f.removeLatePhotoObjects.run({data:{...m,name:file.name,bucket:bucket.name}});
  assert.equal((await file.exists())[0],false);
});
test('backend rejects corrupt JPEG even when its hash matches',async()=> {
  await enable();const c=candidate();const bad=Buffer.from([255,216,1,2,255,217]);c.jpegBase64=bad.toString('base64');c.metadata.sha256=createHash('sha256').update(bad).digest('hex');
  await assert.rejects(()=>f.submitPhoto.run(request(c)));
  assert.equal((await db.collection(`users/${uid}/photos`).get()).size,0);
});
test('deletion needs recent auth, cleans photos and private data, denies resurrection',async()=> {
  await enable();await f.submitPhoto.run(request(candidate()));
  await db.doc(`users/${uid}/private/emergencyContact`).set({name:'test contact'});
  await assert.rejects(()=>f.deletePhotoAccountData.run(request({},uid,600)));
  await f.deletePhotoAccountData.run(request());
  assert.equal((await db.doc(`users/${uid}`).get()).exists,false);
  assert.equal((await db.doc(`users/${uid}/private/emergencyContact`).get()).exists,false);
  assert.equal((await bucket.getFiles({prefix:`unconfirmed_photos/${uid}/`}))[0].length,0);
  assert.equal((await db.doc(`account_deletions/${uid}`).get()).exists,true);
  await assert.rejects(()=>f.setPhotoConsent.run(request({enabled:true,noticeVersion:'2026-10-23.personal-photos.v1'})));
  await f.deletePhotoAccountData.run(request());
});
test('no client can directly read or write private Storage objects',async()=> {
  const store=rules.authenticatedContext(uid).storage();
  const object=ref(store,`unconfirmed_photos/${uid}/${'b'.repeat(32)}.jpg`);
  await assertFails(uploadBytes(object,image));await assertFails(getBytes(object));
});
test('server quota blocks new IDs; same ID with different content cannot overwrite',async()=> {
  await enable();await f.submitPhoto.run(request(candidate()));
  const changed=candidate();changed.metadata.trigger='scene_sample';
  const different=await sharp(image).modulate({brightness:0.5}).jpeg().toBuffer();
  changed.jpegBase64=different.toString('base64');changed.metadata.sha256=createHash('sha256').update(different).digest('hex');
  await assert.rejects(()=>f.submitPhoto.run(request(changed)));
  const day=new Date().toISOString().slice(0,10);
  await db.doc(`users/${uid}/photoQuotas/${day}`).set({total:100});
  await assert.rejects(()=>f.submitPhoto.run(request(candidate('b'.repeat(32)))));
  assert.equal((await db.collection(`users/${uid}/photos`).get()).size,1);
});
test('progress contains only owner records; expired unreviewed object and record are removed',async()=> {
  await enable();await f.submitPhoto.run(request(candidate()));
  const progress=await f.listPhotoProgress.run(request());assert.equal(progress.photos.length,1);assert.equal(progress.photos[0].reviewStatus,'pending');
  await assert.rejects(()=>f.listPhotoProgress.run(request({},'other-photo-user')));
  await db.doc(`users/${uid}/photos/${'a'.repeat(32)}`).update({expiresAt:new Date(0)});
  await f.expirePhotoCandidates.run({});
  assert.equal((await db.collection(`users/${uid}/photos`).get()).size,0);
  assert.equal((await bucket.getFiles({prefix:`unconfirmed_photos/${uid}/`}))[0].length,0);
});
