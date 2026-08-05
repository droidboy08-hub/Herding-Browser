// no-xhr-if (alias: prevent-xhr) — neutralise matching XMLHttpRequests.
//
// The XHR equivalent of no-fetch-if, and messier, because an XHR reports its
// result through properties on the object rather than a return value. Those
// properties are inherited accessors, so a completed-and-empty response is
// staged by shadowing them on the instance itself, then firing the events a real
// completion would fire.
//
// Events are dispatched asynchronously. Real requests never complete before
// send() returns, and code that attaches handlers immediately after send() would
// miss a synchronous completion entirely.
function mbNoXhrIf(propsToMatch) {
  var matches = mbRequestMatcher(propsToMatch);
  var realOpen = XMLHttpRequest.prototype.open;
  var realSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function (method, url) {
    try {
      this.__mbDetails = {
        url: new URL(url, location.href).href,
        method: String(method || 'GET').toUpperCase(),
        body: ''
      };
    } catch (e) {
      this.__mbDetails = null;
    }
    return realOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function (body) {
    var details = this.__mbDetails;
    if (!details) { return realSend.apply(this, arguments); }
    details.body = typeof body === 'string' ? body : '';
    if (!matches(details)) { return realSend.apply(this, arguments); }

    var xhr = this;
    var empty = xhr.responseType === 'json' ? null
              : (xhr.responseType === 'arraybuffer' ? new ArrayBuffer(0) : '');
    try {
      Object.defineProperties(xhr, {
        readyState:   { value: 4, configurable: true },
        status:       { value: 200, configurable: true },
        statusText:   { value: 'OK', configurable: true },
        responseURL:  { value: details.url, configurable: true },
        response:     { value: empty, configurable: true },
        responseText: { value: '', configurable: true }
      });
    } catch (e) {
      return realSend.apply(this, arguments);
    }

    setTimeout(function () {
      ['readystatechange', 'load', 'loadend'].forEach(function (type) {
        try { xhr.dispatchEvent(new Event(type)); } catch (e) {}
      });
    }, 0);
  };
}
