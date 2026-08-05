// replace-node-text (alias: rpnt) — rewrite text inside matching nodes.
//
// The sibling of `remove-node-text`, for the cases where the text has to stay
// but say something else — a script tag whose inline source names a detector,
// or a paywall notice built from a template.
//
// `rpnt, script, adblock, ''` blanks the word in any inline script that has it.
function mbReplaceNodeText(rawSelector, rawPattern, rawReplacement) {
  var selector = String(rawSelector || '*');
  var pattern = String(rawPattern === undefined ? '' : rawPattern);
  var replacement = String(rawReplacement === undefined ? '' : rawReplacement);
  var re = /^\/(.+)\/([a-z]*)$/.exec(pattern);
  var search = re ? new RegExp(re[1], re[2].indexOf('g') === -1 ? re[2] + 'g' : re[2])
                  : null;

  mbWatch(function () {
    var nodes = document.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var text = node.textContent;
      if (typeof text !== 'string' || text === '') { continue; }
      var updated = search ? text.replace(search, replacement)
                           : text.split(pattern).join(replacement);
      if (updated !== text) { node.textContent = updated; }
    }
  });
}
