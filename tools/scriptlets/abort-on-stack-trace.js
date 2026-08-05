// abort-on-stack-trace (alias: aost) — stop a call that arrives by a particular
// route.
//
// Where abort-current-script identifies the caller by its source text, this one
// identifies it by the call stack. That covers code with no identifiable script
// element — bundled chunks, inline handlers, anything already running.
//
// `aost, HTMLElement.prototype.insertBefore, /[A-Z] .+chunks\/\d{4}\./` blocks
// insertBefore only when the stack shows it came from a numbered bundle chunk.
function mbAbortOnStackTrace(path, needle) {
  var match = mbMatcher(needle);
  mbDefinePath(window, path, function (owner, name) {
    var descriptor = Object.getOwnPropertyDescriptor(owner, name);
    if (descriptor && descriptor.configurable === false) { return; }
    var current = owner[name];
    Object.defineProperty(owner, name, {
      configurable: false,
      enumerable: descriptor ? descriptor.enumerable : true,
      get: function () {
        var stack = '';
        try { stack = new Error().stack || ''; } catch (e) {}
        // Drop the first line: it names this getter, not the caller, and would
        // otherwise let the property's own name satisfy the pattern.
        var caller = stack.split('\n').slice(1).join('\n');
        if (caller && match.test(caller)) {
          throw new ReferenceError(name + ' is not defined');
        }
        return current;
      },
      set: function (value) { current = value; }
    });
  });
}
