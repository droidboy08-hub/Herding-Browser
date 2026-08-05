// no-setInterval-if (aliases: nosiif, setInterval-defuser) — drop matching
// repeating timers.
//
// The `setInterval` counterpart of `no-setTimeout-if`, and the more important of
// the two for anti-adblock code: a check that runs every 500ms is what keeps
// putting an overlay back after it's hidden.
function mbNoSetIntervalIf(pattern, delay) {
  var realSetInterval = window.setInterval;
  window.setInterval = function (callback, timeout) {
    if (mbTimerMatch(callback, timeout, pattern, delay)) {
      return realSetInterval(function () {}, 3600000);
    }
    return realSetInterval.apply(this, arguments);
  };
}
