// no-window-open-if (aliases: nowoif, window.open-defuser) — refuse matching
// popups.
//
// The web view already refuses windows a page opens on its own, so this covers
// the other half: `window.open` called from a click handler the user did
// trigger, where the URL is an ad interstitial rather than what they clicked.
//
// Returns a stand-in object rather than null. Popup code routinely calls
// `.focus()` or `.close()` on the result, and null there throws in the middle
// of the page's own click handler.
function mbNoWindowOpenIf(rawPattern) {
  var pattern = String(rawPattern === undefined ? '' : rawPattern);
  var negate = pattern.charAt(0) === '!';
  if (negate) { pattern = pattern.slice(1); }
  var matches = mbMatcher(pattern);
  var realOpen = window.open;

  window.open = function (url) {
    var hit = matches.test(String(url === undefined ? '' : url));
    if (negate) { hit = !hit; }
    if (!hit) { return realOpen.apply(this, arguments); }
    return {
      closed: true,
      focus: function () {}, blur: function () {}, close: function () {},
      postMessage: function () {},
      document: { write: function () {}, close: function () {} }
    };
  };
}
