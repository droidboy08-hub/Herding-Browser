// Shared helpers for the scriptlets in this directory.
//
// Emitted once, ahead of any scriptlet that lists it as a dependency. Names are
// prefixed so nothing here can collide with a page's own globals.

// Turns a filter argument into a matcher. `/…/flags` is a regular expression;
// anything else is a plain substring, which is how filter lists use it.
function mbMatcher(pattern) {
  var text = pattern === undefined || pattern === null ? '' : String(pattern);
  var re = /^\/(.+)\/([a-z]*)$/.exec(text);
  if (re) {
    try {
      var compiled = new RegExp(re[1], re[2]);
      return { test: function (value) { return compiled.test(String(value)); } };
    } catch (e) { /* fall through to substring */ }
  }
  if (text === '') { return { test: function () { return true; } }; }
  return { test: function (value) { return String(value).indexOf(text) !== -1; } };
}

// Maps the value vocabulary filter lists use onto real JavaScript values.
function mbValue(token) {
  switch (token) {
    case 'undefined':          return undefined;
    case 'null':               return null;
    case 'true':               return true;
    case 'false':              return false;
    case 'noopFunc':           return function () {};
    case 'trueFunc':           return function () { return true; };
    case 'falseFunc':          return function () { return false; };
    case 'noopPromiseResolve': return function () { return Promise.resolve(); };
    case 'emptyArr': case '[]': return [];
    case 'emptyObj': case '{}': return {};
    case '': case "''": case '""': return '';
  }
  if (/^-?\d+(\.\d+)?$/.test(token)) { return Number(token); }
  return token;
}

// Applies `install(owner, propertyName)` to the last segment of a dotted path.
//
// The path often doesn't exist yet — the whole point is to be in place before
// the page builds it. So when a link is missing, an accessor is planted on the
// parent and the walk continues the moment the page assigns it.
function mbDefinePath(root, path, install) {
  var parts = String(path).split('.');
  (function step(owner, index) {
    if (owner === null || owner === undefined) { return; }
    var name = parts[index];
    if (index === parts.length - 1) { install(owner, name); return; }
    var existing = owner[name];
    if (existing !== null && (typeof existing === 'object' || typeof existing === 'function')) {
      step(existing, index + 1);
      return;
    }
    var stored = existing;
    try {
      Object.defineProperty(owner, name, {
        configurable: true,
        get: function () { return stored; },
        set: function (value) {
          stored = value;
          if (value !== null && (typeof value === 'object' || typeof value === 'function')) {
            step(value, index + 1);
          }
        }
      });
    } catch (e) { /* non-configurable link; nothing further to do */ }
  })(root, 0);
}

// Runs `visit` over the document now and again whenever it changes, batched
// through rAF so a busy page doesn't pay for an observer on every mutation.
function mbWatch(visit) {
  var scheduled = false;
  function run() { try { visit(); } catch (e) {} }
  function schedule() {
    if (scheduled) { return; }
    scheduled = true;
    requestAnimationFrame(function () { scheduled = false; run(); });
  }
  run();
  var observer = null;
  if (document.documentElement) {
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement,
      { childList: true, subtree: true, attributes: true });
  }
  document.addEventListener('DOMContentLoaded', run, { once: true });
  // Returned so a caller with a finite job — click this once, then stop — can
  // let go of the document instead of watching it for the life of the page.
  return function () { if (observer) { observer.disconnect(); observer = null; } };
}

// Parses the `key:value key:value` argument shared by the request-blocking
// scriptlets. A bare token with no colon matches the URL, which is the common
// case in filter lists.
function mbRequestMatcher(spec) {
  var text = String(spec === undefined ? '' : spec).trim();
  if (text === '') { return function () { return true; }; }
  // A lone regular expression may itself contain spaces and colons.
  if (/^\/.*\/[a-z]*$/.test(text)) {
    var whole = mbMatcher(text);
    return function (details) { return whole.test(details.url); };
  }
  var conditions = text.split(/\s+/).map(function (token) {
    var split = token.indexOf(':');
    if (split === -1) { return { key: 'url', match: mbMatcher(token) }; }
    return { key: token.slice(0, split), match: mbMatcher(token.slice(split + 1)) };
  });
  return function (details) {
    return conditions.every(function (condition) {
      var value = details[condition.key];
      return value !== undefined && condition.match.test(value);
    });
  };
}

// Builds the prune function the `json-prune*` scriptlets share.
//
// `paths` is a space-separated list of property paths to delete; `needle` is an
// optional space-separated list that must all be present before anything is
// removed, so a rule can target one response shape and leave others intact.
// A `*` matches one path segment, which is how a rule reaches into an array of
// results without knowing its length.
function mbPruner(paths, needle) {
  var wanted = String(paths || '').split(/\s+/).filter(Boolean);
  var required = String(needle || '').split(/\s+/).filter(Boolean);

  function walk(owner, parts, index, action) {
    if (owner === null || typeof owner !== 'object') { return false; }
    var name = parts[index];
    var last = index === parts.length - 1;
    var keys = name === '*' ? Object.keys(owner) : [name];
    var hit = false;
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (!Object.prototype.hasOwnProperty.call(owner, key)) { continue; }
      if (last) {
        if (action === 'delete') { delete owner[key]; }
        hit = true;
      } else if (walk(owner[key], parts, index + 1, action)) {
        hit = true;
      }
    }
    return hit;
  }

  return function (value) {
    if (value === null || typeof value !== 'object') { return value; }
    for (var r = 0; r < required.length; r++) {
      if (!walk(value, required[r].split('.'), 0, 'test')) { return value; }
    }
    for (var w = 0; w < wanted.length; w++) {
      walk(value, wanted[w].split('.'), 0, 'delete');
    }
    return value;
  };
}

// Whether a timer callback's source text and delay match what a rule targets.
// Both arguments are optional: no pattern matches every callback, and no delay
// matches every delay. A leading `!` on either inverts that test, which filter
// lists use to keep one timer while defusing the rest.
function mbTimerMatch(callback, delay, rawPattern, rawDelay) {
  var pattern = String(rawPattern === undefined ? '' : rawPattern);
  var negatePattern = pattern.charAt(0) === '!';
  if (negatePattern) { pattern = pattern.slice(1); }
  var source = '';
  try { source = String(callback); } catch (e) {}
  var textHit = pattern === '' ? true : mbMatcher(pattern).test(source);
  if (negatePattern) { textHit = !textHit; }

  var wanted = String(rawDelay === undefined ? '' : rawDelay);
  var negateDelay = wanted.charAt(0) === '!';
  if (negateDelay) { wanted = wanted.slice(1); }
  var delayHit = wanted === '' || wanted === '*'
    ? true : Number(wanted) === Number(delay || 0);
  if (negateDelay) { delayHit = !delayHit; }

  return textHit && delayHit;
}

// Builds the text rewriter the `trusted-replace-*-response` scriptlets share.
//
// `pattern` is a substring, or `/…/flags` for a regular expression; `$1` and
// friends in the replacement refer to capture groups. With no pattern the body
// is emptied, which is what a rule with no arguments asks for.
function mbBodyRewriter(pattern, replacement) {
  var search = pattern === undefined || pattern === null ? '' : String(pattern);
  var into = replacement === undefined || replacement === null ? '' : String(replacement);
  // Lists quote arguments that contain commas or spaces; the quotes are not
  // part of the pattern.
  function unquote(text) {
    var first = text.charAt(0);
    if ((first === "'" || first === '"') && text.charAt(text.length - 1) === first) {
      return text.slice(1, -1);
    }
    return text;
  }
  search = unquote(search);
  into = unquote(into);
  if (search === '') { return function () { return ''; }; }

  var re = /^\/(.+)\/([a-z]*)$/.exec(search);
  if (re) {
    var flags = re[2].indexOf('g') === -1 ? re[2] + 'g' : re[2];
    var compiled;
    try { compiled = new RegExp(re[1], flags); } catch (e) { return function (text) { return text; }; }
    return function (text) {
      compiled.lastIndex = 0;
      return text.replace(compiled, into);
    };
  }
  return function (text) { return text.split(search).join(into); };
}
