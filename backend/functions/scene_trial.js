'use strict';
const {createHash} = require('node:crypto');
// An immutable, operator-configured allowance; never reset at midnight/login.
// Micro-USD arithmetic avoids floating point overspend in the local estimate.
const INPUT_BOUND = 8192, OUTPUT_BOUND = 512;
class TrialFailure extends Error {
  constructor(code, stopReason, limits) { super(code); this.code=code; if(stopReason) this.stopReason=stopReason; if(limits) this.limits=limits; }
}
const fail=code=>{throw new TrialFailure(code);};
function configure(env) {
  const id=env.SCENE_TRIAL_ID, uid=env.SCENE_TRIAL_UID;
  const maxRequests=Number(env.SCENE_TRIAL_MAX_REQUESTS), budgetMicroUsd=Number(env.SCENE_TRIAL_BUDGET_MICRO_USD);
  if (!/^[a-z0-9-]{1,80}$/.test(id||'') || typeof uid!=='string' || !uid || uid.length>128 || uid.includes('/') ||
      !Number.isInteger(maxRequests) || maxRequests<1 || maxRequests>100 ||
      !Number.isInteger(budgetMicroUsd) || budgetMicroUsd<1 || budgetMicroUsd>500000 ||
      Number(env.QWEN_INPUT_USD_PER_MILLION)!==0.2 || Number(env.QWEN_OUTPUT_USD_PER_MILLION)!==1.6) fail('failed-precondition');
  const config={id,uid,maxRequests,budgetMicroUsd,reserveMicroUsd:Math.ceil((INPUT_BOUND*2+OUTPUT_BOUND*16)/10)};
  return {...config,fingerprint:createHash('sha256').update(JSON.stringify(config)).digest('hex')};
}
function assess(old, requestId, config, now=Date.now()) {
  if (old && old.fingerprint!==config.fingerprint) throw new TrialFailure('failed-precondition','configuration-mismatch');
  const state=old||{fingerprint:config.fingerprint,count:0,spentMicroUsd:0,ids:[],inFlight:null,halted:false};
  if (!Number.isInteger(state.count) || state.count<0 || !Number.isInteger(state.spentMicroUsd) || state.spentMicroUsd<0 || !Array.isArray(state.ids) || state.ids.length!==state.count || new Set(state.ids).size!==state.ids.length) fail('failed-precondition');
  const recovery=state.recovery;
  // An administrator may grant one expiring attempt against this exact stopped
  // balance. Keep the unknown charge and halt; consume the grant atomically.
  const recover=state.halted===true && recovery?.status==='ready' &&
    /^[a-z0-9-]{1,80}$/.test(recovery.id||'') &&
    recovery.baselineCount===state.count && recovery.baselineSpentMicroUsd===state.spentMicroUsd &&
    recovery.baselineLastStatus===state.lastStatus &&
    Number.isSafeInteger(recovery.expiresAtMs) && recovery.expiresAtMs>now &&
    recovery.expiresAtMs<=now+86400000;
  const window=state.window;
  const windowAllowed=state.halted===true && window?.status==='ready' &&
    /^[a-z0-9-]{1,80}$/.test(window.id||'') && Number.isInteger(window.baseCount) &&
    window.baseCount>=0 && window.baseCount<=state.count && Number.isInteger(window.maxCount) &&
    window.maxCount>window.baseCount && window.maxCount<=config.maxRequests && state.count<window.maxCount &&
    Number.isSafeInteger(window.expiresAtMs) && window.expiresAtMs>now && window.expiresAtMs<=now+5*86400000 &&
    state.lastStatus!=='usage-unknown';
  const block=reason=>{throw new TrialFailure('resource-exhausted',reason,publicLimits(state,config));};
  if(state.inFlight) block('in-flight');
  if(state.count>=config.maxRequests) block('trial-count');
  if(requestId && state.ids.includes(requestId)) block('duplicate-request');
  if(state.halted && !recover && !windowAllowed) {
    if(state.lastStatus==='usage-unknown') block('usage-unknown');
    if(window && Number.isSafeInteger(window.expiresAtMs) && window.expiresAtMs<=now) block('window-expired');
    block('allowance-stopped');
  }
  if(state.spentMicroUsd+config.reserveMicroUsd>config.budgetMicroUsd) block('budget-reserve');
  return {state,recover,windowAllowed};
}
function publicLimits(state,config) {
  return {count:state.count,maxRequests:config.maxRequests,spentMicroUsd:state.spentMicroUsd,budgetMicroUsd:config.budgetMicroUsd,
    windowRemaining:state.window?.status==='ready'?Math.max(0,state.window.maxCount-state.count):state.recovery?.status==='ready'?1:state.halted?0:Math.max(0,config.maxRequests-state.count),
    expiresAtMs:state.window?.expiresAtMs||state.recovery?.expiresAtMs||0};
}
function inspect(old,config,now=Date.now()) {
  try {const {state}=assess(old,null,config,now);return {limits:publicLimits(state,config),stopReason:null};}
  catch(error) {if(!(error instanceof TrialFailure)) throw error;return {stopReason:error.stopReason||'configuration-mismatch',...(error.limits?{limits:error.limits}:{})};}
}
function allocate(old, requestId, config, now=Date.now()) {
  const {state,recover,windowAllowed}=assess(old,requestId,config,now);
  const recovery=state.recovery,window=state.window;
  return {...state,...(recover?{recovery:{...recovery,status:'consumed',requestId,consumedAtMs:now}}:{}),
    ...(windowAllowed?{window:{...window,lastRequestId:requestId}}:{}),
    count:state.count+1,ids:[...state.ids,requestId],inFlight:requestId,
    reservedMicroUsd:config.reserveMicroUsd,maxRequests:config.maxRequests,budgetMicroUsd:config.budgetMicroUsd};
}
async function settle(db, config, requestId, result) {
  const ref=db.doc(`scene_description_trials/${config.id}`);
  await db.runTransaction(async tx=>{
    const old=(await tx.get(ref)).data();
    if (!old || old.fingerprint!==config.fingerprint || old.inFlight!==requestId) fail('failed-precondition');
    const usage=result?.metrics?.usage, estimate=result?.metrics?.estimate;
    const known=usage && ['prompt_tokens','completion_tokens','total_tokens'].every(k=>Number.isSafeInteger(usage[k])&&usage[k]>=0) && usage.total_tokens===usage.prompt_tokens+usage.completion_tokens && estimate && Number.isFinite(estimate.usd) && estimate.usd>=0 &&
      estimate.inputUsdPerMillion===0.2 && estimate.outputUsdPerMillion===1.6 &&
      usage.prompt_tokens<=INPUT_BOUND && usage.completion_tokens<=OUTPUT_BOUND;
    const charged=known?Math.ceil((usage.prompt_tokens*2+usage.completion_tokens*16)/10):config.reserveMicroUsd;
    tx.set(ref,{...old,inFlight:null,reservedMicroUsd:0,
      spentMicroUsd:old.spentMicroUsd+charged,
      halted:!!old.window || old.recovery?.status==='consumed' || !known || charged>config.reserveMicroUsd,
      ...(old.window?{window:{...old.window,status:!known?'halted':old.count>=old.window.maxCount?'consumed':old.window.status}}:{}),
      lastStatus:known?result.status:'usage-unknown',notBillingCap:true});
  });
}
module.exports={TrialFailure,configure,allocate,settle,inspect,publicLimits,INPUT_BOUND,OUTPUT_BOUND};
