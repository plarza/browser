extension ScriptletLibrary {
    /// `json-prune`'s paths: finding what a path names in an object, and
    /// taking it out.
    static let pruning = #"""
// MARK: Pruning (json-prune's paths)

/** Whether `path` is in `root`; with `prune`, removes what it names. */
const find = (root, path, prune = false) => {
  let owner = root, chain = path;
  for (;;) {
    if (typeof owner !== 'object' || owner === null) return false;
    const dot = chain.indexOf('.');
    if (dot === -1) {
      if (!prune) return N.hasOwn(owner, chain);
      let modified = false;
      if (chain === '*') {
        for (const key of N.keys(owner)) { delete owner[key]; modified = true; }
      } else if (N.hasOwn(owner, chain)) {
        delete owner[chain];
        modified = true;
      }
      return modified;
    }
    const prop = chain.slice(0, dot), rest = chain.slice(dot + 1);
    let found = false;
    if (prop === '[-]' && Array.isArray(owner)) {
      for (let i = owner.length - 1; i >= 0; i--) {
        if (!find(owner[i], rest)) continue;
        owner.splice(i, 1);
        found = true;
      }
      return found;
    }
    if (prop === '{-}' && owner instanceof Object) {
      for (const key of N.keys(owner)) {
        if (!find(owner[key], rest)) continue;
        delete owner[key];
        found = true;
      }
      return found;
    }
    if ((prop === '[]' && Array.isArray(owner)) || ((prop === '{}' || prop === '*') && owner instanceof Object)) {
      for (const key of N.keys(owner)) if (find(owner[key], rest, prune)) found = true;
      return found;
    }
    if (!N.hasOwn(owner, prop)) return false;
    owner = owner[prop];
    chain = rest;
  }
};
const pruner = (rawPrune = '', rawNeedles = '') => {
  const paths = rawPrune.split(/\s+/).filter(Boolean);
  const needles = rawNeedles.split(/\s+/).filter(Boolean);
  return obj => {
    if (paths.length === 0 || typeof obj !== 'object' || obj === null) return false;
    if (needles.some(path => !find(obj, path))) return false;
    let modified = false;
    for (const path of paths) if (find(obj, path, true)) modified = true;
    return modified;
  };
};
"""#
}
