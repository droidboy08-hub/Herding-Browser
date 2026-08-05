// trusted-click-element — click a matching element once it appears.
//
// For the dialog that has to be answered rather than hidden: a consent banner
// whose "Accept" is the only way past it, or a paywall's dismiss button. Hiding
// those leaves the page scroll-locked behind an invisible overlay, so the rule
// presses the button instead.
//
// `trusted-click-element, selector, , 1500` clicks after 1.5 seconds, which is
// what the lists use — the button usually isn't in the document yet at document
// start. The second argument (extra matching conditions) is accepted and
// ignored; the lists that use it leave it empty.
function mbTrustedClickElement(rawSelectors, unusedExtra, rawDelay) {
  var selectors = String(rawSelectors || '').split(/\s*,\s*(?![^(\[]*[)\]])/).filter(Boolean);
  if (!selectors.length) { return; }
  var delay = Number(rawDelay);
  if (!isFinite(delay) || delay < 0) { delay = 0; }
  // Give up rather than watching forever: a selector that never matches would
  // otherwise keep an observer alive for the life of the page.
  var deadline = Date.now() + delay + 10000;

  setTimeout(function () {
    var stop = mbWatch(function () {
      if (Date.now() > deadline) { if (stop) { stop(); } return; }
      for (var i = 0; i < selectors.length; i++) {
        var element;
        try { element = document.querySelector(selectors[i]); } catch (e) { continue; }
        if (!element) { continue; }
        // Only click what a person could: an element hidden by our own cosmetic
        // rules isn't the button the list meant.
        var box = element.getBoundingClientRect();
        if (box.width === 0 && box.height === 0) { continue; }
        try { element.click(); } catch (e) {}
        if (stop) { stop(); }
        return;
      }
    });
  }, delay);
}
