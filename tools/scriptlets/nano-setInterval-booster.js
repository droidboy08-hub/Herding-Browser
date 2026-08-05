// nano-setInterval-booster (alias: nano-sib) — shorten matching repeating timers.
//
// The `setInterval` counterpart of `nano-setTimeout-booster`, for countdowns
// that tick rather than fire once.
function mbNanoSetIntervalBooster(pattern, delay, rawBoost) {
  var boost = Number(rawBoost);
  if (!isFinite(boost) || boost <= 0) { boost = 0.02; }
  var realSetInterval = window.setInterval;
  window.setInterval = function (callback, timeout) {
    if (mbTimerMatch(callback, timeout, pattern, delay)) {
      arguments[1] = Number(timeout || 0) * boost;
    }
    return realSetInterval.apply(this, arguments);
  };
}
