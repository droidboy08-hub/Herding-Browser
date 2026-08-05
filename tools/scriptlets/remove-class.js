// remove-class (alias: rc) — strip class names from matching elements.
//
// Pages that detect a blocker often mark the body — `body.has-adblock` — and
// style the real content away from there. Removing the class is what puts the
// page back, and it has to keep happening: the script that added it usually
// adds it again.
//
// `rc, has-adblock, body` removes one class from one selector. With no selector
// the class is removed everywhere it appears.
function mbRemoveClass(rawClasses, rawSelector) {
  var classes = String(rawClasses || '').split(/[\s|]+/).filter(Boolean);
  if (!classes.length) { return; }
  var selector = String(rawSelector || '').trim();

  mbWatch(function () {
    var scope = selector === ''
      ? document.querySelectorAll('[class]')
      : document.querySelectorAll(selector);
    for (var i = 0; i < scope.length; i++) {
      for (var c = 0; c < classes.length; c++) {
        if (scope[i].classList.contains(classes[c])) {
          scope[i].classList.remove(classes[c]);
        }
      }
    }
  });
}
