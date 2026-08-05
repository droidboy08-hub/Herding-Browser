// json-prune-fetch-response — prune the JSON body of matching fetch responses.
//
// Same job as `json-prune`, one layer lower: the response is read, pruned and
// handed back as a fresh `Response`, so a caller that never touches
// `JSON.parse` — because it uses `response.json()` on a clone, or streams the
// body — still gets the cleaned payload.
//
// `json-prune-fetch-response, adPlacements, /youtubei\/v1\/player/` prunes only
// the player endpoint and leaves every other request alone.
function mbJSONPruneFetchResponse(rawPaths, rawNeedle, propsToMatch) {
  var prune = mbPruner(rawPaths, rawNeedle);
  var matches = mbRequestMatcher(propsToMatch);
  var realFetch = window.fetch;
  if (typeof realFetch !== 'function') { return; }

  window.fetch = function (resource, init) {
    var self = this, args = arguments, details;
    try {
      var url = typeof resource === 'string' ? resource
              : (resource && typeof resource.url === 'string' ? resource.url : '');
      details = {
        url: new URL(url, location.href).href,
        method: ((init && init.method) || (resource && resource.method) || 'GET').toUpperCase(),
        body: (init && typeof init.body === 'string') ? init.body : ''
      };
    } catch (e) {
      return realFetch.apply(self, args);
    }
    if (!matches(details)) { return realFetch.apply(self, args); }

    return realFetch.apply(self, args).then(function (response) {
      // Read from a clone: the original body can still be consumed by the page
      // if anything here fails.
      return response.clone().text().then(function (text) {
        var pruned;
        try {
          pruned = JSON.stringify(prune(JSON.parse(text)));
        } catch (e) {
          return response;
        }
        var copy = new Response(pruned, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers
        });
        // A page that checks where the response came from must still see the
        // real URL; `Response` won't take it in the initialiser.
        try {
          Object.defineProperty(copy, 'url', { value: response.url });
          Object.defineProperty(copy, 'type', { value: response.type });
        } catch (e) {}
        return copy;
      }).catch(function () { return response; });
    });
  };
}
