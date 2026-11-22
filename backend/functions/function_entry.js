'use strict';
// Firebase validates secrets during discovery even when --only filters a
// function. This opt-in entry keeps unrelated Routes credentials out of a
// scene-only deployment, while the normal backend entry remains available.
module.exports = process.env.SCENE_DESCRIPTION_DEPLOY_ONLY === 'true'
  ? require('./scene_entry') : require('./index');
