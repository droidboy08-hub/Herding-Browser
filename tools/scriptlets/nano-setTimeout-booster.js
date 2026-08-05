// nano-setTimeout-booster (alias: nano-stb) — shorten matching timers.
//
// For the countdown, rather than the ad: "your download starts in 30 seconds"
// is a `setTimeout`, and dividing its delay by a large number makes the wait
// end immediately without removing the callback that does the work.
//
// `nano-stb, timer, 30, 0.02` matches timers whose source mentions "timer" and
// whose delay is 30, and multiplies the delay by 0.02. The default multiplier
// is 0.02 too, which is what most rules assume.
function mbNanoSetTimeoutBooster(pattern, delay, rawBoost) {
  var boost = Number(rawBoost);
  if (!isFinite(boost) || boost <= 0) { boost = 0.02; }
  var realSetTimeout = window.setTimeout;
  window.setTimeout = function (callback, timeout) {
    if (mbTimerMatch(callback, timeout, pattern, delay)) {
      arguments[1] = Number(timeout || 0) * boost;
    }
    return realSetTimeout.apply(this, arguments);
  };
}
