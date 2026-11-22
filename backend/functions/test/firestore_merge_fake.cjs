// Firestore set({merge:true}) recursively merges nonempty maps; a top-level
// mergeFields mask replaces the named map. Arrays and null replace atomically.
'use strict';
function mergeSet(previous, value, options) {
  if (options?.mergeFields) {
    const result={...previous};
    for (const field of options.mergeFields) {
      if (field.includes('.') || !Object.hasOwn(value,field)) throw Error('unsupported fake mask');
      result[field]=structuredClone(value[field]);
    }
    return result;
  }
  if (!options?.merge) return structuredClone(value);
  const result={...previous};
  for (const [key,next] of Object.entries(value)) {
    result[key]=next && typeof next==='object' && !Array.isArray(next) && Object.keys(next).length
      ? mergeSet(result[key],next,{merge:true}) : structuredClone(next);
  }
  return result;
}
module.exports={mergeSet};
