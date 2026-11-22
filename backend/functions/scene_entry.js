'use strict';
const {initializeApp}=require('firebase-admin/app');
const {getFirestore}=require('firebase-admin/firestore');
initializeApp();
exports.describeScene=require('./scene_function').createSceneFunction(getFirestore(),{
  region:'asia-east2',enforceAppCheck:true,maxInstances:2,concurrency:4,
  memory:'512MiB',timeoutSeconds:40,
});
