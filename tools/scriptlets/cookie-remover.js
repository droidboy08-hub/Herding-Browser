// cookie-remover — delete cookies by name.
//
// A cookie can only be deleted by overwriting it with an expiry in the past, and
// only from a path and domain that match how it was set. The name alone doesn't
// say which those were, so every plausible combination is tried: the current
// path and its ancestors, against the current host and each of its parent
// domains.
function mbCookieRemover(namePattern) {
  var isPattern = /^\/.*\/[a-z]*$/.test(namePattern);
  var match = isPattern ? mbMatcher(namePattern)
                        : { test: function (n) { return n === namePattern; } };

  var paths = ['/'];
  location.pathname.split('/').forEach(function (segment) {
    if (!segment) { return; }
    paths.push(paths[paths.length - 1].replace(/\/$/, '') + '/' + segment);
  });

  var domains = [''];        // no domain attribute — a host-only cookie
  var labels = location.hostname.split('.');
  for (var i = 0; i < labels.length - 1; i++) {
    domains.push(labels.slice(i).join('.'));
  }

  function sweep() {
    document.cookie.split(';').forEach(function (pair) {
      var name = pair.split('=')[0].trim();
      if (!name || !match.test(name)) { return; }
      paths.forEach(function (path) {
        domains.forEach(function (domain) {
          var expired = encodeURIComponent(name) +
                        '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=' + path +
                        (domain ? '; domain=' + domain : '');
          try { document.cookie = expired; } catch (e) {}
        });
      });
    });
  }

  sweep();
  // Whatever set the cookie usually runs after this, so sweep again once the
  // page's own scripts have had their turn.
  document.addEventListener('DOMContentLoaded', sweep, { once: true });
  window.addEventListener('load', sweep, { once: true });
}
