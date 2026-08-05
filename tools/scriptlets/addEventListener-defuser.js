// addEventListener-defuser (alias: aeld) — swallow matching event listeners.
//
// `aeld, load, doSomething` drops any `load` listener whose handler source
// mentions "doSomething". Filter lists use it against the handler that puts an
// overlay up on scroll, or re-checks for a blocker on every click.
//
// The listener is dropped rather than wrapped: `removeEventListener` on a
// handler that was never added is a no-op, so nothing downstream breaks.
function mbAddEventListenerDefuser(rawType, rawPattern) {
  var typeMatches = mbMatcher(rawType);
  var handlerMatches = mbMatcher(rawPattern);
  var realAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function (type, listener) {
    var source = '';
    try { source = String(listener); } catch (e) {}
    if (typeMatches.test(String(type)) && handlerMatches.test(source)) { return; }
    return realAdd.apply(this, arguments);
  };
}
