// abort-on-property-read (alias: aopr) — throw when a property is read.
//
// Anti-adblock scripts probe for their own globals before doing anything else.
// Making the read throw aborts that script at its first line, which is cheaper
// and more reliable than trying to make the rest of it behave.
//
// The thrown value is a plain object rather than an Error: pages log errors, and
// a stack trace in the console for every page load is noise the user would see.
function mbAbortOnPropertyRead(path) {
  mbDefinePath(window, path, function (owner, name) {
    var descriptor = Object.getOwnPropertyDescriptor(owner, name);
    if (descriptor && descriptor.configurable === false) { return; }
    try {
      Object.defineProperty(owner, name, {
        configurable: false,
        get: function () { throw new ReferenceError(name); },
        set: function () {}
      });
    } catch (e) {}
  });
}
