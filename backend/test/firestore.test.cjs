const {readFileSync} = require('node:fs');
const {test, before, after, beforeEach} = require('node:test');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp, writeBatch, collection, getDocs} = require('firebase/firestore');
let env;
const uid = 'alice';
const claims = (age = 0) => ({firebase: {sign_in_provider: 'google.com'}, auth_time: Math.floor(Date.now()/1000) - age});
const user = (who = uid, age = 0) => env.authenticatedContext(who, claims(age)).firestore();
const profile = () => ({schemaVersion: 1, status: 'active', termsVersion: '2026-10-23.google.v1', createdAt: serverTimestamp(), updatedAt: serverTimestamp()});
const contact = () => ({schemaVersion: 1, ownerUid: uid, name: '媽媽', phone: '+85291234567', relationship: '家人', updatedAt: serverTimestamp()});
before(async () => { env = await initializeTestEnvironment({projectId: 'demo-pathguide-phase3', firestore: {rules: readFileSync('firestore.rules', 'utf8'), host: '127.0.0.1', port: 8080}}); });
beforeEach(async () => { await env.clearFirestore(); });
after(async () => { await env?.cleanup(); });
async function seed() { const db = user(); await setDoc(doc(db, `users/${uid}`), profile()); return db; }
test('guest cannot read or initialize accounts', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, `users/${uid}`)));
  await assertFails(setDoc(doc(db, `users/${uid}`), profile()));
});
test('owner can initialize once; cannot grant roles or change status', async () => {
  const db = await seed();
  await assertSucceeds(getDoc(doc(db, `users/${uid}`)));
  await assertFails(updateDoc(doc(db, `users/${uid}`), {role: 'admin'}));
  await assertFails(updateDoc(doc(db, `users/${uid}`), {status: 'deleting'}));
});
test('rejects malformed profiles, fabricated timestamps and extra fields', async () => {
  const db = user();
  await assertFails(setDoc(doc(db, `users/${uid}`), {...profile(), ownerUid: 'bob'}));
  await assertFails(setDoc(doc(db, `users/${uid}`), {...profile(), termsVersion: 'old'}));
  await assertFails(setDoc(doc(db, `users/${uid}`), {...profile(), createdAt: new Date(0)}));
});
test('other UID cannot read, write, delete or list private information', async () => {
  const db = await seed(); await setDoc(doc(db, `users/${uid}/private/emergencyContact`), contact());
  const other = user('bob');
  await assertFails(getDoc(doc(other, `users/${uid}`)));
  await assertFails(getDoc(doc(other, `users/${uid}/private/emergencyContact`)));
  await assertFails(setDoc(doc(other, `users/${uid}/private/emergencyContact`), contact()));
  await assertFails(deleteDoc(doc(other, `users/${uid}/private/emergencyContact`)));
  await assertFails(getDocs(collection(other, 'users')));
});
test('contact CRUD for active owner only, with validated shape and phone', async () => {
  const db = await seed(); const ref = doc(db, `users/${uid}/private/emergencyContact`);
  await assertSucceeds(setDoc(ref, contact()));
  await assertSucceeds(updateDoc(ref, {name: '爸爸', updatedAt: serverTimestamp()}));
  await assertSucceeds(getDoc(ref));
  for (const patch of [{ownerUid: 'bob'}, {phone: 'tel:123;456'}, {phone: '+852123'}, {name: ''}, {role: 'admin'}]) {
    await assertFails(setDoc(ref, {...contact(), ...patch}));
  }
  await assertSucceeds(deleteDoc(ref));
});
test('contact cannot be created without an active account', async () => {
  await assertFails(setDoc(doc(user(), `users/${uid}/private/emergencyContact`), contact()));
});
test('deletion requires recent authentication, clears data, blocks resurrection', async () => {
  await seed(); const stale = user(uid, 600);
  await assertFails(setDoc(doc(stale, `account_deletions/${uid}`), {schemaVersion: 1, createdAt: serverTimestamp()}));
  const db = user(); const batch = writeBatch(db);
  batch.set(doc(db, `account_deletions/${uid}`), {schemaVersion: 1, createdAt: serverTimestamp()});
  batch.delete(doc(db, `users/${uid}/private/emergencyContact`));
  batch.delete(doc(db, `users/${uid}`));
  await assertSucceeds(batch.commit());
  await assertFails(setDoc(doc(db, `users/${uid}`), profile()));
  await assertFails(setDoc(doc(db, `users/${uid}/private/emergencyContact`), contact()));
  await assertFails(deleteDoc(doc(db, `account_deletions/${uid}`)));
});
test('deletion guard contains no contact fields and cannot target another UID', async () => {
  const db = user();
  await assertFails(setDoc(doc(db, 'account_deletions/bob'), {schemaVersion: 1, createdAt: serverTimestamp()}));
  await assertFails(setDoc(doc(db, `account_deletions/${uid}`), {schemaVersion: 1, createdAt: serverTimestamp(), phone: '+85291234567'}));
  await assertFails(deleteDoc(doc(db, `users/${uid}`)));
});
test('only current Google provider is enabled; unrelated collections denied', async () => {
  const db = env.authenticatedContext(uid, {firebase: {sign_in_provider: 'anonymous'}}).firestore();
  await assertFails(setDoc(doc(db, `users/${uid}`), profile()));
  await assertFails(setDoc(doc(user(), 'personal_models/alice'), {ownerUid: uid}));
});
test('photo progress is owner-only; clients cannot forge uploads, consent or quota',async()=> {
  const db=await seed();
  await env.withSecurityRulesDisabled(async ctx=> {
    await setDoc(doc(ctx.firestore(),`users/${uid}/photos/photo1`),{ownerUid:uid,uploadStatus:'validated'});
    await setDoc(doc(ctx.firestore(),`users/${uid}/private/photoConsent`),{enabled:true,epoch:1});
  });
  await assertSucceeds(getDocs(collection(db,`users/${uid}/photos`)));
  await assertSucceeds(getDoc(doc(db,`users/${uid}/private/photoConsent`)));
  await assertFails(getDocs(collection(user('bob'),`users/${uid}/photos`)));
  await assertFails(setDoc(doc(db,`users/${uid}/photos/photo2`),{uploadStatus:'validated'}));
  await assertFails(setDoc(doc(db,`users/${uid}/private/photoConsent`),{enabled:true}));
  await assertFails(setDoc(doc(db,`users/${uid}/photoQuotas/today`),{total:0}));
  const batch=writeBatch(db);
  batch.set(doc(db,`account_deletions/${uid}`),{schemaVersion:1,createdAt:serverTimestamp()});
  batch.delete(doc(db,`users/${uid}`));
  await assertFails(batch.commit());
});
