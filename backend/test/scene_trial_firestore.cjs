// Opt-in check using unique synthetic Firestore documents, never a Qwen key/image.
'use strict';
const assert=require('node:assert/strict'),{randomBytes}=require('node:crypto'),{createRequire}=require('node:module');
const auth=require('firebase-tools/lib/auth'),{requireAuth}=require('firebase-tools/lib/requireAuth');
const {OAuth2Client}=createRequire(require.resolve('firebase-tools'))('google-auth-library');
const fr=createRequire(require.resolve('../functions')),{Firestore}=fr('firebase-admin/firestore');
const policy=require('../functions/scene_trial'),{reserve}=require('../functions/scene_description');
async function main(){
 if(process.env.PATHGUIDE_CLOUD_CHECK_PROJECT!=='pathguide-dev')throw Error('Explicit test project acknowledgement required');
 const options={project:'pathguide-dev'},account=auth.getProjectDefaultAccount(process.cwd());
 if(!account)throw Error('Firebase CLI login required');
 auth.setActiveAccount(options,account);await requireAuth(options);
 const access=await auth.getAccessToken(account.tokens.refresh_token,options.authScopes);
 const client=new OAuth2Client();client.setCredentials({access_token:access.access_token,expiry_date:access.expires_at});
 const db=new Firestore({projectId:'pathguide-dev',authClient:client,preferRest:true});
 const unique=randomBytes(8).toString('hex'),uid=`scene-engineering-${unique}`,trialId=`engineering-${unique}`;
 const cfg=policy.configure({SCENE_TRIAL_ID:trialId,SCENE_TRIAL_UID:uid,SCENE_TRIAL_MAX_REQUESTS:'20',SCENE_TRIAL_BUDGET_MICRO_USD:'10000',QWEN_INPUT_USD_PER_MILLION:'0.2',QWEN_OUTPUT_USD_PER_MILLION:'1.6'});
 const ref=db.doc(`scene_description_trials/${trialId}`),user=db.doc(`users/${uid}`),now=Date.now();
 const id=i=>i.toString(16).padStart(32,'0');
 const result={status:'complete',metrics:{usage:{prompt_tokens:100,completion_tokens:20,total_tokens:120},estimate:{usd:0.000052,inputUsdPerMillion:0.2,outputUsdPerMillion:1.6}}};
 try{
  await user.create({status:'active',purpose:'synthetic-scene-engineering-check'});
  const race=await Promise.allSettled([reserve(db,uid,id(1),now,cfg),reserve(db,uid,id(2),now,cfg)]);
  assert.equal(race.filter(r=>r.status==='fulfilled').length,1);
  await policy.settle(db,cfg,id(race[0].status==='fulfilled'?1:2),result);
  for(let i=3;i<=21;i++){await reserve(db,uid,id(i),now+i*86400000,cfg);await policy.settle(db,cfg,id(i),result);}
  const persisted=(await ref.get()).data();
  assert.equal(persisted.count,20);
  assert.throws(()=>policy.allocate(persisted,id(22),cfg),{code:'resource-exhausted'});
  console.log(JSON.stringify({project:'pathguide-dev',liveFirestoreTransactions:'pass',concurrentWinners:1,totalAttempts:20,twentyFirst:'blocked',qwenRequests:0}));
 }finally{await db.recursiveDelete(user);await ref.delete();await db.terminate();}
}
main().catch(error=>{console.error(JSON.stringify({check:'failed',code:error.code||'local-error',message:String(error.message).replace(/Bearer\s+\S+/g,'Bearer [redacted]').slice(0,350)}));process.exitCode=1;});
