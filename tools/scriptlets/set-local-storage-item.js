// set-local-storage-item — write or delete a localStorage entry.
//
// `set-local-storage-item, plausible_ignore, true` opts the visitor out of an
// analytics package that checks this key before reporting.
// `set-local-storage-item, browser-ids, $remove$` clears a stored identifier.
//
// Deletion matches the key exactly unless the argument is a regular expression.
// A substring match would be wrong here: removing `browser-ids` must not also
// take `browser-ids-consent` with it.
function mbSetLocalStorageItem(key, rawValue) {
  var store;
  try { store = window.localStorage; } catch (e) { return; }
  if (!store) { return; }

  if (rawValue === '$remove$') {
    var isPattern = /^\/.*\/[a-z]*$/.test(key);
    var match = isPattern ? mbMatcher(key) : { test: function (k) { return k === key; } };
    Object.keys(store).forEach(function (existing) {
      if (match.test(existing)) { store.removeItem(existing); }
    });
    return;
  }

  var value = mbValue(rawValue);
  if (value === undefined || value === null) { store.removeItem(key); return; }
  if (typeof value === 'object') { return; }   // not representable as storage text
  store.setItem(key, String(value));
}
