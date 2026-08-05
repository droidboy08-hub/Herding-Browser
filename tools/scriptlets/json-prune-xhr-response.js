// json-prune-xhr-response — prune the JSON body of matching XHR responses.
//
// The `XMLHttpRequest` counterpart of `json-prune-fetch-response`. Plenty of
// player and ad code still uses XHR, and `responseText` never passes through
// `JSON.parse` on the way to the page.
function mbJSONPruneXHRResponse(rawPaths, rawNeedle, propsToMatch) {
  var prune = mbPruner(rawPaths, rawNeedle);
  var matches = mbRequestMatcher(propsToMatch);
  var realOpen = XMLHttpRequest.prototype.open;
  var realSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function (method, url) {
    this.__mbPruneDetails = { method: String(method || 'GET').toUpperCase(), url: String(url || '') };
    return realOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function (body) {
    var details = this.__mbPruneDetails;
    if (!details) { return realSend.apply(this, arguments); }
    try {
      details.url = new URL(details.url, location.href).href;
      details.body = typeof body === 'string' ? body : '';
    } catch (e) {}
    if (!matches(details)) { return realSend.apply(this, arguments); }

    var xhr = this;
    xhr.addEventListener('readystatechange', function () {
      if (xhr.readyState !== 4) { return; }
      var raw;
      try {
        raw = xhr.responseType === '' || xhr.responseType === 'text'
            ? xhr.responseText : xhr.response;
      } catch (e) { return; }
      var pruned;
      try {
        pruned = typeof raw === 'string' ? JSON.stringify(prune(JSON.parse(raw)))
                                         : prune(raw);
      } catch (e) { return; }
      // `response`/`responseText` are read-only, so the pruned body is planted
      // over them for this instance only.
      try {
        Object.defineProperty(xhr, 'response', { value: pruned, writable: false });
        if (typeof pruned === 'string') {
          Object.defineProperty(xhr, 'responseText', { value: pruned, writable: false });
        }
      } catch (e) {}
    });
    return realSend.apply(this, arguments);
  };
}
