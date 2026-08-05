// set-cookie — write a cookie, optionally reloading once afterwards.
//
// `set-cookie, GPC, 1, , reload, 1` records a Global Privacy Control signal and
// reloads so the page reads it on a fresh request. The empty third argument
// means "no explicit path", which defaults to the whole site.
//
// The reload is guarded by a session flag. Setting a cookie and reloading
// unconditionally is an infinite loop, since the reloaded page runs this again.
function mbSetCookie(name, value, path) {
  var options = Array.prototype.slice.call(arguments, 3).map(function (option) {
    return String(option).toLowerCase();
  });

  var cookie = encodeURIComponent(name) + '=' + encodeURIComponent(value);
  cookie += '; path=' + (path ? path : '/');
  // A year is long enough to be durable and short enough that browsers keep it.
  cookie += '; expires=' + new Date(Date.now() + 31536000000).toUTCString();
  if (location.protocol === 'https:') { cookie += '; samesite=lax; secure'; }

  try { document.cookie = cookie; } catch (e) { return; }

  if (options.indexOf('reload') === -1) { return; }
  var flag = 'mb-set-cookie-reloaded:' + name;
  try {
    if (sessionStorage.getItem(flag)) { return; }
    sessionStorage.setItem(flag, '1');
  } catch (e) {
    return;    // without somewhere to record the reload, don't risk the loop
  }
  location.reload();
}
