// trusted-replace-xhr-response — rewrite the body of matching XHR responses.
//
// The `XMLHttpRequest` half of `trusted-replace-fetch-response`. Video players
// fetch their payload both ways depending on the page, so a rule that only
// covered one would work on the desktop site and not the mobile one.
function mbTrustedReplaceXHRResponse(rawPattern, rawReplacement, propsToMatch) {
  var replace = mbBodyRewriter(rawPattern, rawReplacement);
  var matches = mbRequestMatcher(propsToMatch);
  var realOpen = XMLHttpRequest.prototype.open;
  var realSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function (method, url) {
    this.__mbReplaceDetails = {
      method: String(method || 'GET').toUpperCase(),
      url: String(url || '')
    };
    return realOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function (body) {
    var details = this.__mbReplaceDetails;
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
        if (xhr.responseType !== '' && xhr.responseType !== 'text') { return; }
        raw = xhr.responseText;
      } catch (e) { return; }
      if (typeof raw !== 'string') { return; }
      var updated = replace(raw);
      if (updated === raw) { return; }
      // `response` and `responseText` are read-only, so the rewritten body is
      // planted over them on this instance.
      try {
        Object.defineProperty(xhr, 'response', { value: updated, writable: false });
        Object.defineProperty(xhr, 'responseText', { value: updated, writable: false });
      } catch (e) {}
    });
    return realSend.apply(this, arguments);
  };
}
