// no-setTimeout-if (aliases: nostif, setTimeout-defuser) — drop matching timers.
//
// Ad code leans on delayed callbacks: check for a blocker in two seconds, put
// the overlay back in five. `no-setTimeout-if, adBlock` stops any timer whose
// callback source mentions "adBlock"; a second argument pins the delay, and a
// leading `!` on either inverts the test.
//
// The timer id returned is a real one from a no-op timer, so page code that
// stores and later clears it still works.
function mbNoSetTimeoutIf(pattern, delay) {
  var realSetTimeout = window.setTimeout;
  window.setTimeout = function (callback, timeout) {
    if (mbTimerMatch(callback, timeout, pattern, delay)) {
      return realSetTimeout(function () {}, 0);
    }
    return realSetTimeout.apply(this, arguments);
  };
}
