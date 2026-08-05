// abort-on-property-write (alias: aopw) — throw when a property is assigned.
//
// The write-side counterpart of `abort-on-property-read`, for the script that
// installs its detector rather than reading one: the assignment itself is what
// gets aborted, so the detector is never in place.
function mbAbortOnPropertyWrite(path) {
  mbDefinePath(window, path, function (owner, name) {
    var descriptor = Object.getOwnPropertyDescriptor(owner, name);
    if (descriptor && descriptor.configurable === false) { return; }
    var stored = descriptor ? descriptor.value : undefined;
    try {
      Object.defineProperty(owner, name, {
        configurable: false,
        get: function () { return stored; },
        set: function () { throw new ReferenceError(name); }
      });
    } catch (e) {}
  });
}
