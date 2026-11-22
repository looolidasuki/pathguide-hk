'use strict';
// Explicit operator-only, non-inference preflight. No image, prompt, generation,
// raw response, key, token or model output is logged or persisted.
const {BASE}=require('./scene_description');
async function probeProvider(key,fetcher=fetch) {
  try {
    const r=await fetcher(`${BASE}/models`,{method:'GET',redirect:'error',
      headers:{Authorization:`Bearer ${key}`},signal:AbortSignal.timeout(10000)});
    // Status is sufficient for authentication/route diagnosis. Never read body.
    await r.body?.cancel();
    return {event:'scene-provider-preflight',operation:'GET models (no inference)',httpStatus:r.status};
  } catch(e) {
    const raw=e?.cause?.code;
    const transport=['ENOTFOUND','EAI_AGAIN','ECONNREFUSED','ECONNRESET','ETIMEDOUT','UND_ERR_CONNECT_TIMEOUT'].includes(raw)?raw:'unknown';
    return {event:'scene-provider-preflight',operation:'GET models (no inference)',transport,
      timeout:e?.name==='TimeoutError'};
  }
}
module.exports={probeProvider};
