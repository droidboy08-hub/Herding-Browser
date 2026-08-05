#!/usr/bin/env python3
"""Builds the scriptlet resources bundle from the JavaScript in tools/scriptlets.

The engine resolves a `+js(name, arg…)` filter rule by looking up `name`, so
these have to be delivered as a resources array rather than as loose files.

Two details of the engine's contract drive the output:

* A resource whose content begins with `function name(` is treated as
  function-style: the body is emitted once and the rule's arguments are passed
  as a normal call with JSON-encoded strings. That is much safer than the
  alternative, which splices arguments into the source as text. The name is
  matched by a regex anchored at the very start of the content, so the leading
  documentation comment in each source file is stripped here — the file in
  tools/scriptlets stays the readable original.
* Shared helpers are pulled in through `dependencies`, so `mb-helpers.js` is
  emitted once ahead of whichever scriptlets a page actually needs.

Usage:  python3 tools/build-scriptlets.py
"""

import base64
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SOURCE_DIR = ROOT / "scriptlets"
OUTPUT = ROOT.parent / "prototype" / "MinimalBrowser" / "FilterLists" / "scriptlets.json"

HELPERS = "mb-helpers.js"

# Filter lists refer to most of these by a short alias. Both spellings must
# resolve, and the engine canonicalises by appending `.js`, so aliases carry it.
ALIASES = {
    # uBO treats abort-current-script and abort-current-inline-script as one
    # resource; lists use all four spellings interchangeably.
    "abort-current-script.js": ["acs.js", "abort-current-inline-script.js", "acis.js"],
    "abort-on-stack-trace.js": ["aost.js"],
    "abort-on-property-read.js": ["aopr.js"],
    "abort-on-property-write.js": ["aopw.js"],
    "remove-node-text.js": ["rmnt.js"],
    "remove-class.js": ["rc.js"],
    "remove-attr.js": ["ra.js"],
    "cookie-remover.js": ["remove-cookie.js"],
    "no-fetch-if.js": ["prevent-fetch.js"],
    "no-xhr-if.js": ["prevent-xhr.js"],
    "no-setTimeout-if.js": ["nostif.js", "setTimeout-defuser.js",
                            "prevent-setTimeout.js"],
    "no-setInterval-if.js": ["nosiif.js", "setInterval-defuser.js",
                             "prevent-setInterval.js"],
    "nano-setTimeout-booster.js": ["nano-stb.js"],
    "nano-setInterval-booster.js": ["nano-sib.js"],
    "addEventListener-defuser.js": ["aeld.js", "prevent-addEventListener.js"],
    "no-window-open-if.js": ["nowoif.js", "window.open-defuser.js",
                             "prevent-window-open.js"],
    "json-prune.js": ["jsonprune.js"],
    "replace-node-text.js": ["rpnt.js", "trusted-replace-node-text.js",
                             "trusted-rpnt.js"],
    "set-session-storage-item.js": ["trusted-set-session-storage-item.js"],
    "set-local-storage-item.js": ["trusted-set-local-storage-item.js"],
    "set-cookie.js": ["trusted-set-cookie.js"],
    "set-constant.js": ["set.js", "trusted-set-constant.js", "trusted-set.js"],
}

LEADING_COMMENT = re.compile(r"\A(?:\s*//[^\n]*\n)+")
FUNCTION_NAME = re.compile(r"\Afunction\s+([^()\{\}\s]+)\s*\(")


def build() -> int:
    resources = []
    failures = []

    for path in sorted(SOURCE_DIR.glob("*.js")):
        source = path.read_text(encoding="utf-8")
        body = LEADING_COMMENT.sub("", source).strip()

        entry = {
            "name": path.name,
            "aliases": ALIASES.get(path.name, []),
            # A `trusted-…` scriptlet can rewrite any response body or press any
            # button on any site. Marking the resource as requiring a permission
            # means the engine only injects it for filter lists parsed as
            # trusted — the ones this app ships or the user chose — and drops it
            # for anything else. Without the marker the name is just a name and
            # the gate is open.
            **({"permission": 1} if path.name.startswith("trusted-") else {}),
            "kind": {"mime": "application/javascript"},
            "content": base64.b64encode(body.encode("utf-8")).decode("ascii"),
        }

        if path.name != HELPERS:
            match = FUNCTION_NAME.match(body)
            if not match:
                failures.append(
                    f"{path.name}: content must begin with `function name(` after the "
                    f"header comment, or the engine cannot invoke it"
                )
                continue
            entry["dependencies"] = [HELPERS]

        resources.append(entry)

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    OUTPUT.write_text(json.dumps(resources, indent=1), encoding="utf-8")

    scriptlets = [r for r in resources if r["name"] != HELPERS]
    print(f"wrote {OUTPUT.relative_to(ROOT.parent)}")
    print(f"  {len(scriptlets)} scriptlets + helpers, {OUTPUT.stat().st_size // 1024} KB")
    for resource in scriptlets:
        names = ", ".join([resource["name"]] + resource["aliases"])
        print(f"  · {names}")
    return 0


if __name__ == "__main__":
    raise SystemExit(build())
