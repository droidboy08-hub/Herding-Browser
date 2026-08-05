// json-prune — drop properties from every object `JSON.parse` returns.
//
// This is how a site's own API response gets cleaned up before its code ever
// sees it. YouTube is the canonical case: the player payload carries
// `adPlacements`, `playerAds` and `adSlots`, and removing those keys is what
// stops the ads being scheduled at all — nothing was blocked at the network
// level, because the ad description arrives inside the same response as the
// video.
//
// `json-prune, adPlacements playerAds` removes both keys. Paths may be dotted
// (`a.b.c`) and may use `*` for one level. A second argument names properties
// that must be *present* for the prune to happen, so a rule can leave unrelated
// responses alone.
function mbJSONPrune(rawPaths, rawNeedle) {
  var prune = mbPruner(rawPaths, rawNeedle);
  var realParse = JSON.parse;
  JSON.parse = function () {
    var result = realParse.apply(this, arguments);
    try { return prune(result); } catch (e) { return result; }
  };
  // `Response.json()` doesn't go through `JSON.parse`, so it needs its own hook.
  if (window.Response && Response.prototype && Response.prototype.json) {
    var realJSON = Response.prototype.json;
    Response.prototype.json = function () {
      return realJSON.apply(this, arguments).then(function (value) {
        try { return prune(value); } catch (e) { return value; }
      });
    };
  }
}
