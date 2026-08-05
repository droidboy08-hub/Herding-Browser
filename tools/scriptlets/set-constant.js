// set-constant (alias: set) — pin a property to a fixed value.
//
// Filters use this to neutralise a detection flag: `set, admiral, noopFunc`
// gives the page a harmless stand-in for a script that was blocked, so the page
// doesn't error out on its absence.
//
// The setter deliberately swallows writes. A page that assigns over the value is
// exactly what the rule exists to defeat.
function mbSetConstant(path, rawValue) {
  var value = mbValue(rawValue);
  mbDefinePath(window, path, function (owner, name) {
    var descriptor = Object.getOwnPropertyDescriptor(owner, name);
    if (descriptor && descriptor.configurable === false) { return; }
    Object.defineProperty(owner, name, {
      configurable: false,
      enumerable: descriptor ? descriptor.enumerable : true,
      get: function () { return value; },
      set: function () {}
    });
  });
}
