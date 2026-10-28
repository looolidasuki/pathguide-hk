const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {onSchedule} = require('firebase-functions/v2/scheduler');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue, Timestamp} = require('firebase-admin/firestore');
const {getStorage} = require('firebase-admin/storage');
const {createHash} = require('node:crypto');
const sharp = require('sharp');
const policy = require('./photo_policy');
initializeApp();
const db = getFirestore();
const options = {region:'asia-east2', enforceAppCheck:true, maxInstances:2, concurrency:4, memory:'512MiB', timeoutSeconds:60};
// Guest navigation validates app attestation, independently of Google account/photo consent.
const {defineSecret} = require('firebase-functions/params');
const routesKey = defineSecret('GOOGLE_ROUTES_API_KEY');
const navigationRoutes = require('./navigation_routes');
exports.computeWalkingRoute = onCall({...options, timeoutSeconds:20, secrets:[routesKey]}, async request => {
  try { navigationRoutes.requireAppCheck(request); return await navigationRoutes.computeWalkingRoute(request.data, {key:routesKey.value()}); }
  catch (e) { throw new HttpsError(e instanceof navigationRoutes.RouteFailure ? e.code : 'unavailable', e instanceof navigationRoutes.RouteFailure ? e.message : '路線服務暫時不可用。'); }
});
const user = uid=>db.doc(`users/${uid}`);
const consent = uid=>db.doc(`users/${uid}/private/photoConsent`);
const guard = uid=>db.doc(`account_deletions/${uid}`);
const photoRef = (uid,id)=>db.doc(`users/${uid}/photos/${id}`);
const path = (uid,id)=>`unconfirmed_photos/${uid}/${id}.jpg`;
function fail(error) {
  if (error instanceof HttpsError) throw error;
  const code = ['unauthenticated','permission-denied','invalid-argument','resource-exhausted'].includes(error.message)?error.message:
    error.message==='recent-login-required'?'failed-precondition':error.message?.startsWith('invalid-')?'invalid-argument':'failed-precondition';
  throw new HttpsError(code,'照片請求未完成；請核對同意、帳號狀態、配額及影像後重試。');
}
async function state(tx,uid,requireConsent=false,epoch=null) {
  const [u,g,c] = await Promise.all([tx.get(user(uid)),tx.get(guard(uid)),tx.get(consent(uid))]);
  if (g.exists || u.data()?.status!=='active') throw new Error('account-unavailable');
  if (requireConsent && (!c.data()?.enabled || c.data()?.noticeVersion!==policy.NOTICE || c.data()?.epoch!==epoch)) throw new Error('consent-required');
  return c.data();
}
exports.getPhotoConsent = onCall(options, async r=> {
  try {
    const uid = policy.requireGoogle(r);
    const c = await db.runTransaction(tx=>state(tx,uid));
    return {enabled:c?.enabled===true&&c.noticeVersion===policy.NOTICE,epoch:c?.epoch||0};
  } catch(e) { fail(e); }
});
exports.setPhotoConsent = onCall(options, async r=> {
  try {
    const uid = policy.requireGoogle(r);
    if (typeof r.data?.enabled!=='boolean' || r.data.noticeVersion!==policy.NOTICE) throw new Error('invalid-argument');
    return await db.runTransaction(async tx=> {
      const old = await state(tx,uid);
      const epoch = (old?.epoch||0)+1;
      tx.set(consent(uid),{schemaVersion:1,ownerUid:uid,purpose:'personal_model_photos',noticeVersion:policy.NOTICE,
        enabled:r.data.enabled,epoch,updatedAt:FieldValue.serverTimestamp(),
        ...(r.data.enabled?{consentedAt:FieldValue.serverTimestamp()}:{revokedAt:FieldValue.serverTimestamp()})});
      return {enabled:r.data.enabled,epoch};
    });
  } catch(e) { fail(e); }
});
exports.submitPhoto = onCall(options, async r=> {
  let uid,id,file;
  try {
    uid=policy.requireGoogle(r); id=r.data?.photoId;
    const {jpeg,metadata} = policy.validateCandidate(r.data);
    // Decode with pixel limits and re-encode: no EXIF, GPS, XMP or UI overlays are added.
    const image = sharp(jpeg,{limitInputPixels:4000000,failOn:'warning'});
    const info = await image.metadata();
    if(info.format!=='jpeg' || info.width!==metadata.width || info.height!==metadata.height || (info.orientation&&info.orientation!==1)) throw new Error('invalid-image');
    const clean = await image.jpeg({quality:85}).toBuffer();
    if(clean.length>policy.MAX_BYTES) throw new Error('invalid-image');
    const sourceSha256=metadata.sha256, sha256=createHash('sha256').update(clean).digest('hex');
    const ref=photoRef(uid,id), epoch=r.data.consentEpoch;
    const existing = await db.runTransaction(async tx=> {
      await state(tx,uid,true,epoch);
      const old=await tx.get(ref);
      if(old.exists) {
        if(old.data().sourceSha256!==sourceSha256||old.data().consentEpoch!==epoch||old.data().uploadStatus==='expired') throw new Error('candidate-conflict');
        return old.data();
      }
      const day=new Date().toISOString().slice(0,10), q=db.doc(`users/${uid}/photoQuotas/${day}`);
      const counts=await tx.get(q), values=counts.data()||{}, next=policy.quota(values,metadata.trigger);
      const now=Date.now();
      if(metadata.trigger!=='manual_report'&&values.lastAutoAt&&now-values.lastAutoAt.toMillis()<30000) throw new Error('resource-exhausted');
      if(metadata.trigger==='scene_sample'&&values.lastSceneAt&&now-values.lastSceneAt.toMillis()<60000) throw new Error('resource-exhausted');
      tx.set(q,{...values,...next,updatedAt:FieldValue.serverTimestamp(),
        ...(metadata.trigger!=='manual_report'?{lastAutoAt:FieldValue.serverTimestamp()}:{}),
        ...(metadata.trigger==='scene_sample'?{lastSceneAt:FieldValue.serverTimestamp()}:{})});
      tx.create(ref,{schemaVersion:1,ownerUid:uid,photoId:id,clientCandidateId:id,consentEpoch:epoch,
        ...metadata,sourceSha256,sha256,storagePath:path(uid,id),uploadStatus:'allocated',reviewStatus:'unavailable',
        createdAt:FieldValue.serverTimestamp(),updatedAt:FieldValue.serverTimestamp(),
        expiresAt:Timestamp.fromMillis(Date.now()+30*86400000)});
      return null;
    });
    if(existing?.uploadStatus==='validated') return {photoId:id,uploadStatus:'validated'};
    file=getStorage().bucket().file(path(uid,id));
    try {
      await file.save(clean,{resumable:false,contentType:'image/jpeg',preconditionOpts:{ifGenerationMatch:0},
        metadata:{metadata:{ownerUid:uid,photoId:id,sourceSha256,sha256,consentEpoch:String(epoch)}}});
    } catch(e) {
      if(Number(e.code)!==412) throw e;
      const [m]=await file.getMetadata();
      if(m.metadata?.sourceSha256!==sourceSha256||m.metadata?.consentEpoch!==String(epoch)) throw new Error('candidate-conflict');
    }
    const [object]=await file.getMetadata();
    try {
      await db.runTransaction(async tx=> {
        await state(tx,uid,true,epoch);
        const old=await tx.get(ref);
        if(!old.exists || old.data().sourceSha256!==sourceSha256 || old.data().consentEpoch!==epoch) throw new Error('candidate-conflict');
        tx.update(ref,{uploadStatus:'validated',reviewStatus:'pending',objectGeneration:object.generation,
          sha256:object.metadata.sha256,bytes:Number(object.size),updatedAt:FieldValue.serverTimestamp()});
      });
    } catch(e) { await file.delete({ifGenerationMatch:object.generation,ignoreNotFound:true}); throw e; }
    return {photoId:id,uploadStatus:'validated'};
  } catch(e) { fail(e); }
});

// The app reauthenticates first. Guard immediately closes all user rules; retry
// continues cleanup after failures, and Auth is removed by the SDK only afterwards.
exports.deletePhotoAccountData = onCall({...options,timeoutSeconds:300},async r=> {
  try {
    const uid=policy.requireGoogle(r,true);
    await db.runTransaction(async tx=> {
      const g=await tx.get(guard(uid));
      if(!g.exists) tx.create(guard(uid),{schemaVersion:1,createdAt:FieldValue.serverTimestamp()});
      tx.set(user(uid),{status:'deleting'},{merge:true});
    });
    await getStorage().bucket().deleteFiles({prefix:`unconfirmed_photos/${uid}/`,force:false});
    await db.recursiveDelete(user(uid));
    return {status:'data_deleted'};
  } catch(e) { fail(e); }
});
// Only bounded unreviewed/allocated candidates exist in Phase 4; review writes
// are reserved to a future trusted review service and are not exposed to clients.
exports.expirePhotoCandidates = onSchedule({region:'asia-east2',schedule:'every 60 minutes',maxInstances:1},async()=> {
  const expired=await db.collectionGroup('photos').where('expiresAt','<=',Timestamp.now()).limit(200).get();
  for(const doc of expired.docs) {
    const p=doc.data();
    if(!['pending','unavailable','rejected'].includes(p.reviewStatus)||!p.ownerUid||!p.photoId) continue;
    const file=getStorage().bucket().file(path(p.ownerUid,p.photoId));
    await file.delete({ignoreNotFound:true});
    await doc.ref.delete();
  }
});

// Late/crashed uploads may finish after revocation or deletion. Generation-scoped
// cleanup is safe when Storage events are retried.
const {onObjectFinalized} = require('firebase-functions/v2/storage');
exports.removeLatePhotoObjects = onObjectFinalized({region:'asia-east2',maxInstances:2},async event=> {
  const object=event.data;
  const match=/^unconfirmed_photos\/([^/]+)\/([a-f0-9]{32})\.jpg$/.exec(object.name||'');
  if(!match) return;
  const [,uid,id]=match;
  const [u,g,c,p]=await Promise.all([user(uid).get(),guard(uid).get(),consent(uid).get(),photoRef(uid,id).get()]);
  const valid=u.data()?.status==='active'&&!g.exists&&c.data()?.enabled&&c.data()?.noticeVersion===policy.NOTICE
    &&String(c.data()?.epoch)===object.metadata?.consentEpoch&&p.data()?.sourceSha256===object.metadata?.sourceSha256;
  if(!valid) await getStorage().bucket(object.bucket).file(object.name).delete({ifGenerationMatch:object.generation,ignoreNotFound:true});
});

exports.listPhotoProgress = onCall(options,async r=> {
  try {
    const uid=policy.requireGoogle(r);
    await db.runTransaction(tx=>state(tx,uid));
    const docs=await db.collection(`users/${uid}/photos`).orderBy('createdAt','desc').limit(20).get();
    return {photos:docs.docs.map(doc=>({photoId:doc.id,uploadStatus:doc.data().uploadStatus,reviewStatus:doc.data().reviewStatus}))};
  } catch(e) { fail(e); }
});
