// remove-attr (alias: ra) — strip attributes from matching elements.
//
// The attribute counterpart of `remove-class`: `ra, onclick, a[href]` drops
// inline click handlers that hijack a link, and `ra, style, .content` undoes
// the inline `display:none` a detector wrote over real content.
function mbRemoveAttr(rawAttributes, rawSelector) {
  var attributes = String(rawAttributes || '').split(/[\s|]+/).filter(Boolean);
  if (!attributes.length) { return; }
  var selector = String(rawSelector || '').trim();

  mbWatch(function () {
    var scope = selector === ''
      ? document.querySelectorAll('*')
      : document.querySelectorAll(selector);
    for (var i = 0; i < scope.length; i++) {
      for (var a = 0; a < attributes.length; a++) {
        if (scope[i].hasAttribute(attributes[a])) {
          scope[i].removeAttribute(attributes[a]);
        }
      }
    }
  });
}
