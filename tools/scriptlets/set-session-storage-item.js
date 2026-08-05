// set-session-storage-item — pin a sessionStorage key to a value.
//
// The session-scoped twin of `set-local-storage-item`. Pages keep "you have
// dismissed this" and "you have seen the ad" flags in both, and a rule usually
// needs whichever one that site chose.
function mbSetSessionStorageItem(key, rawValue) {
  var value = mbValue(rawValue);
  var text = typeof value === 'string' ? value : JSON.stringify(value);
  try {
    sessionStorage.setItem(String(key), text === undefined ? '' : text);
  } catch (e) { /* storage disabled or full; nothing to do */ }
}
