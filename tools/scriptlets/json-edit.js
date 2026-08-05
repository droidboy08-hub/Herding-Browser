// json-edit — remove nodes from JSON responses.
//
// `json-edit, ..props.children.*[?.key=="admiral-script"]` strips an injected
// script descriptor out of a server-rendered component tree, so the framework
// never mounts it. That kind of payload is invisible to network blocking — the
// response is legitimate application data with one hostile node inside it.
//
// Supported query syntax, which is the subset the filter lists here use:
//   ..name              recursive descent to every value under `name`
//   .name               a named child
//   .*                  every child of an object or array
//   [?.key=="value"]    keep only nodes whose `key` equals `value`
// Anything else is rejected rather than half-applied — a query that silently
// matches the wrong nodes would corrupt page data.
function mbJsonEdit(query) {
  var steps = mbJsonEditParse(query);
  if (!steps) { return; }

  function edit(text) {
    var parsed;
    try { parsed = JSON.parse(text); } catch (e) { return null; }
    // Candidates are tracked with their parent so a match can be unlinked.
    var found = [{ parent: null, key: null, value: parsed }];
    for (var i = 0; i < steps.length && found.length; i++) {
      found = steps[i](found);
    }
    if (!found.length) { return null; }
    // Deepest-first, so removing an array element can't shift the index of one
    // still to be removed.
    found.sort(function (a, b) { return b.index - a.index; });
    var removed = 0;
    found.forEach(function (hit) {
      if (!hit.parent) { return; }
      if (Array.isArray(hit.parent)) {
        var at = hit.parent.indexOf(hit.value);
        if (at !== -1) { hit.parent.splice(at, 1); removed++; }
      } else {
        delete hit.parent[hit.key];
        removed++;
      }
    });
    if (!removed) { return null; }
    try { return JSON.stringify(parsed); } catch (e) { return null; }
  }

  var realFetch = window.fetch;
  if (typeof realFetch !== 'function') { return; }
  window.fetch = function () {
    return realFetch.apply(this, arguments).then(function (response) {
      var type = response.headers && response.headers.get('content-type');
      if (!type || type.indexOf('json') === -1) { return response; }
      // The body can only be read once, so work on a clone and hand back the
      // original untouched whenever the edit doesn't apply.
      return response.clone().text().then(function (text) {
        var edited = edit(text);
        if (edited === null) { return response; }
        return new Response(edited, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers
        });
      }, function () { return response; });
    });
  };
}

// Compiles the query into a list of steps. Each step maps the current set of
// {parent, key, value, index} hits to the next set. Returns null if the query
// uses anything outside the supported subset.
function mbJsonEditParse(query) {
  var text = String(query || '').trim();
  var steps = [];
  var depth = 0;

  function hit(parent, key, value) {
    return { parent: parent, key: key, value: value, index: depth };
  }
  function childrenOf(value, visit) {
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) { visit(value, i, value[i]); }
    } else if (value !== null && typeof value === 'object') {
      Object.keys(value).forEach(function (key) { visit(value, key, value[key]); });
    }
  }

  while (text.length) {
    var recursive = /^\.\.([A-Za-z_$][\w$]*)/.exec(text);
    if (recursive) {
      (function (name, level) {
        steps.push(function (found) {
          var next = [];
          found.forEach(function (current) {
            (function descend(value) {
              childrenOf(value, function (parent, key, child) {
                if (key === name) { next.push({ parent: parent, key: key, value: child, index: level }); }
                descend(child);
              });
            })(current.value);
          });
          return next;
        });
      })(recursive[1], depth++);
      text = text.slice(recursive[0].length);
      continue;
    }
    var anyChild = /^\.\*/.exec(text);
    if (anyChild) {
      (function (level) {
        steps.push(function (found) {
          var next = [];
          found.forEach(function (current) {
            childrenOf(current.value, function (parent, key, child) {
              next.push({ parent: parent, key: key, value: child, index: level });
            });
          });
          return next;
        });
      })(depth++);
      text = text.slice(anyChild[0].length);
      continue;
    }
    var named = /^\.([A-Za-z_$][\w$]*)/.exec(text);
    if (named) {
      (function (name, level) {
        steps.push(function (found) {
          var next = [];
          found.forEach(function (current) {
            var value = current.value;
            if (value !== null && typeof value === 'object' && name in value) {
              next.push({ parent: value, key: name, value: value[name], index: level });
            }
          });
          return next;
        });
      })(named[1], depth++);
      text = text.slice(named[0].length);
      continue;
    }
    var filter = /^\[\?\.([A-Za-z_$][\w$]*)\s*==\s*"([^"]*)"\]/.exec(text);
    if (filter) {
      (function (key, expected) {
        steps.push(function (found) {
          return found.filter(function (current) {
            var value = current.value;
            return value !== null && typeof value === 'object' &&
                   String(value[key]) === expected;
          });
        });
      })(filter[1], filter[2]);
      text = text.slice(filter[0].length);
      continue;
    }
    return null;     // unsupported syntax — refuse rather than guess
  }
  return steps.length ? steps : null;
}
