// no-fetch-if (alias: prevent-fetch) — neutralise matching fetch() calls.
//
// `no-fetch-if, stella` stops any request whose URL mentions "stella".
//
// The request is answered with an empty 200 rather than rejected. A rejection
// surfaces as an unhandled error and often takes visible page features down with
// it; an empty success is the quieter lie, and the caller simply finds nothing
// there.
function mbNoFetchIf(propsToMatch) {
  var matches = mbRequestMatcher(propsToMatch);
  var realFetch = window.fetch;
  if (typeof realFetch !== 'function') { return; }

  window.fetch = function (resource, init) {
    var details;
    try {
      var url = typeof resource === 'string' ? resource
              : (resource && typeof resource.url === 'string' ? resource.url : '');
      details = {
        url: new URL(url, location.href).href,
        method: ((init && init.method) ||
                 (resource && resource.method) || 'GET').toUpperCase(),
        body: (init && typeof init.body === 'string') ? init.body : ''
      };
    } catch (e) {
      return realFetch.apply(this, arguments);
    }

    if (!matches(details)) { return realFetch.apply(this, arguments); }
    return Promise.resolve(new Response('', {
      status: 200,
      statusText: 'OK',
      headers: { 'Content-Type': 'text/plain' }
    }));
  };
}
