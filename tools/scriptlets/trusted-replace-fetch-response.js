// trusted-replace-fetch-response — rewrite the body of matching fetch responses.
//
// The blunt instrument the video sites need. Their player payload arrives inside
// the same response as the video description, so nothing can be blocked at the
// network layer; the ad has to be edited out of the JSON text before the
// player's own code reads it. `"adPlacements"` renamed to `"no_ads"` is enough —
// the player looks the key up, doesn't find it, and schedules nothing.
//
// `trusted-replace-fetch-response, pattern, replacement, urlPattern`. A `/…/`
// pattern is a regular expression, and `$1` in the replacement refers to a
// capture group. With no arguments the body is emptied.
//
// "Trusted" because this can rewrite any response on any site, which is why the
// engine drops these rules unless the list carrying them was parsed as trusted.
function mbTrustedReplaceFetchResponse(rawPattern, rawReplacement, propsToMatch) {
  var replace = mbBodyRewriter(rawPattern, rawReplacement);
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
      return response.clone().text().then(function (text) {
        var updated = replace(text);
        if (updated === text) { return response; }
        var copy = new Response(updated, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers
        });
        try {
          Object.defineProperty(copy, 'url', { value: response.url });
          Object.defineProperty(copy, 'type', { value: response.type });
        } catch (e) {}
        return copy;
      }).catch(function () { return response; });
    });
  };
}
