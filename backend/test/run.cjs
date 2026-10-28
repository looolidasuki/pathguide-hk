const {spawnSync}=require('node:child_process');
for(const file of ['functions/test/photo_policy.test.cjs','test/firestore.test.cjs','test/photo_functions.test.cjs']) {
  const result=spawnSync(process.execPath,['--test',file],{stdio:'inherit',env:process.env});
  if(result.status!==0) process.exit(result.status||1);
}
