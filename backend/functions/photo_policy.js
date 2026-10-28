const {createHash} = require('node:crypto');
const NOTICE = '2026-10-23.personal-photos.v1';
const MAX_BYTES = 2 * 1024 * 1024;
function requireGoogle(request, recent = false) {
  const auth = request.auth;
  if (!auth || auth.token?.firebase?.sign_in_provider !== 'google.com') throw new Error('unauthenticated');
  if (request.data?.expectedUid !== auth.uid) throw new Error('permission-denied');
  if (recent && (!Number.isInteger(auth.token.auth_time) || Date.now()/1000-auth.token.auth_time>=300 || auth.token.auth_time>Date.now()/1000)) throw new Error('recent-login-required');
  return auth.uid;
}
function validateCandidate(data) {
  if (!data || !/^[a-f0-9]{32}$/.test(data.photoId) || !Number.isInteger(data.consentEpoch) || data.consentEpoch < 1) throw new Error('invalid-argument');
  if (typeof data.jpegBase64 !== 'string' || data.jpegBase64.length > Math.ceil(MAX_BYTES/3)*4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data.jpegBase64)) throw new Error('invalid-image');
  const jpeg = Buffer.from(data.jpegBase64, 'base64');
  if (!jpeg.length || jpeg.length>MAX_BYTES || jpeg[0]!==255 || jpeg[1]!==216) throw new Error('invalid-image');
  const m = data.metadata;
  if (!m || !['manual_report','low_confidence','scene_sample'].includes(m.trigger) || !/^[a-f0-9]{64}$/.test(m.sha256) || createHash('sha256').update(jpeg).digest('hex') !== m.sha256) throw new Error('invalid-metadata');
  for (const key of ['modelVersion','classMapVersion','sessionId']) {
    if (typeof m[key] !== 'string' || !m[key].length || m[key].length > 128) throw new Error('invalid-metadata');
  }
  if (!Number.isFinite(Date.parse(m.capturedAtClient)) || !Number.isInteger(m.width) || !Number.isInteger(m.height) || m.width<32 || m.height<32 || m.width*m.height>4000000) throw new Error('invalid-metadata');
  if (!Array.isArray(m.predictions) || m.predictions.length>100) throw new Error('invalid-predictions');
  const predictions = m.predictions.map(p=> {
    if (!Number.isInteger(p.projectClassId) || p.projectClassId<0 || !['score','cx','cy','w','h'].every(k=>Number.isFinite(p[k])&&p[k]>=0&&p[k]<=1) || p.w<=0 || p.h<=0 || p.cx-p.w/2 < -0.0001 || p.cy-p.h/2 < -0.0001 || p.cx+p.w/2>1.0001 || p.cy+p.h/2>1.0001) throw new Error('invalid-predictions');
    return Object.fromEntries(['projectClassId','score','cx','cy','w','h'].map(k=>[k,p[k]]));
  });
  return {jpeg, metadata: Object.fromEntries(['trigger','sha256','width','height','modelVersion','classMapVersion','sessionId','capturedAtClient'].map(k=>[k,m[k]]).concat([['predictions',predictions]]))};
}
function quota(counts, trigger) {
  const total = counts.total || 0, automatic = counts.automatic || 0, scene = counts.scene || 0;
  if (total>=100 || (trigger!=='manual_report'&&automatic>=50) || (trigger==='scene_sample'&&scene>=10)) throw new Error('resource-exhausted');
  return {total:total+1,automatic:automatic+(trigger==='manual_report'?0:1),scene:scene+(trigger==='scene_sample'?1:0)};
}
module.exports = {NOTICE, MAX_BYTES, requireGoogle, validateCandidate, quota};
