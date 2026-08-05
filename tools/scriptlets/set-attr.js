// set-attr — set an attribute on matching elements.
//
// `set-attr, span[class] img.lazyload[width], src, [data-src]` fixes images that
// a lazy-loader never got around to loading: the real URL is already sitting in
// data-src, so it is copied into src.
//
// A value wrapped in square brackets names another attribute to copy from;
// anything else is used literally. Writes are skipped when the value is already
// correct, or the mutation observer would retrigger itself forever.
function mbSetAttr(selector, attribute, rawValue) {
  function resolve(element) {
    var copyFrom = /^\[(.+)\]$/.exec(rawValue);
    if (copyFrom) { return element.getAttribute(copyFrom[1]); }
    if (rawValue === '$now$') { return String(Date.now()); }
    return rawValue;
  }

  mbWatch(function () {
    var elements = document.querySelectorAll(selector);
    for (var i = 0; i < elements.length; i++) {
      var value = resolve(elements[i]);
      if (value === null || value === undefined) { continue; }
      if (elements[i].getAttribute(attribute) === value) { continue; }
      elements[i].setAttribute(attribute, value);
    }
  });
}
