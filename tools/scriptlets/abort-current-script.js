// abort-current-script (alias: acs) — stop one specific script from running.
//
// `acs, document.createElement, admiral` reads as: when a script whose source
// mentions "admiral" reaches for document.createElement, kill that script.
//
// Reading the property throws a ReferenceError, which unwinds only the script
// that made the call. Every other caller gets the real value, so the page is
// otherwise untouched — that precision is the whole reason this exists rather
// than deleting the property outright.
function mbAbortCurrentScript(path, needle) {
  var match = mbMatcher(needle);
  mbDefinePath(window, path, function (owner, name) {
    var descriptor = Object.getOwnPropertyDescriptor(owner, name);
    if (descriptor && descriptor.configurable === false) { return; }
    var current = owner[name];
    Object.defineProperty(owner, name, {
      configurable: false,
      enumerable: descriptor ? descriptor.enumerable : true,
      get: function () {
        var script = document.currentScript;
        if (script) {
          var source = script.src || script.textContent || '';
          if (match.test(source)) {
            throw new ReferenceError(name + ' is not defined');
          }
        }
        return current;
      },
      set: function (value) { current = value; }
    });
  });
}
