// remove-node-text (alias: rmnt) — drop nodes whose text matches.
//
// `rmnt, script, admiral` removes any inline script mentioning "admiral".
//
// The interesting part is the timing. An inline <script> runs the instant it is
// inserted, so a MutationObserver — which is notified afterwards — is far too
// late to prevent execution. The insertion methods are wrapped instead, and a
// matching node is dropped on the way in. The observer stays as a fallback for
// nodes that arrive another way (parser-inserted markup, innerHTML), where
// removing them at least strips them from the DOM.
function mbRemoveNodeText(nodeName, pattern) {
  var match = mbMatcher(pattern);
  var wanted = String(nodeName).toLowerCase();

  function matches(node) {
    return node && node.nodeType === 1 &&
           node.nodeName.toLowerCase() === wanted &&
           match.test(node.textContent || '');
  }

  ['appendChild', 'insertBefore', 'replaceChild'].forEach(function (method) {
    var original = Node.prototype[method];
    if (typeof original !== 'function') { return; }
    Node.prototype[method] = function (node) {
      // Report success by returning the node the caller handed over — code that
      // chains off the return value keeps working.
      if (matches(node)) { return node; }
      return original.apply(this, arguments);
    };
  });

  mbWatch(function () {
    var nodes = document.querySelectorAll(wanted);
    for (var i = 0; i < nodes.length; i++) {
      if (matches(nodes[i]) && nodes[i].parentNode) {
        nodes[i].parentNode.removeChild(nodes[i]);
      }
    }
  });
}
