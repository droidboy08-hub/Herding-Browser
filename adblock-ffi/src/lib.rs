//! A thin C ABI over the `adblock` crate, so Swift can drive Brave's filter
//! engine without a C++ layer in between.
//!
//! Design rules, all of them load-bearing:
//!
//! * Swift only ever sees opaque pointers and primitives. Every string and byte
//!   buffer that crosses the boundary is allocated here and freed here, through
//!   [`adblock_string_free`] / [`adblock_bytes_free`]. Rust's allocator is not
//!   Swift's; freeing on the wrong side corrupts the heap.
//! * No entry point may unwind into C. Each one wraps its body in
//!   `catch_unwind` and returns a null pointer or `false` instead, so a
//!   malformed filter list is a missing ruleset rather than a crash.
//! * Nothing here is thread-safe by itself. The Swift side confines an engine to
//!   one actor; `default-features = false` (no `single-thread`) keeps the
//!   underlying types `Send`, so actor hops between executor threads are sound.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use adblock::engine::Engine;
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;

/// Opaque handle. Swift holds `OpaquePointer`; the layout is never exposed.
pub struct AdblockEngine {
    engine: Engine,
}

// MARK: - Boundary helpers

/// Borrow a C string as `&str`. Returns `None` for null or non-UTF-8 input
/// rather than trusting the caller.
unsafe fn str_from(ptr: *const c_char) -> Option<&'static str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

/// Hand a Rust `String` to C. The caller must return it via
/// [`adblock_string_free`].
fn string_out(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(c) => c.into_raw(),
        // An interior NUL can only come from filter text we generated, but
        // returning null is still better than panicking across the boundary.
        Err(_) => ptr::null_mut(),
    }
}

/// Run `body`, turning a panic into `fallback` instead of unwinding into C.
fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

// MARK: - Engine lifecycle

/// Build an engine from filter-list text (one or more lists concatenated).
///
/// Returns null if `rules` is null, not UTF-8, or the parse panics. The engine
/// is built without debug info: rule provenance costs memory and only the
/// converter below needs it.
///
/// # Safety
/// `rules` must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_create(rules: *const c_char) -> *mut AdblockEngine {
    adblock_engine_create_with_trust(rules, false)
}

/// Build an engine, optionally parsing the rules as a *trusted* list.
///
/// Scriptlet rules whose name begins with `trusted-` are dropped at parse time
/// unless the list carries the permission for them, and `ParseOptions::default()`
/// carries none. That is not a detail: the rules that strip ads out of a video
/// site's own player response are `trusted-replace-fetch-response` and
/// `trusted-replace-xhr-response`, so a list parsed without the permission
/// silently loses exactly the rules that do the work — no error, no log, just
/// ads.
///
/// The permission exists because these scriptlets can rewrite any response body
/// on any site, which is a capability you extend to a list you chose, not to
/// every list on the internet. So it is a parameter rather than a default: the
/// caller decides which lists it trusts.
///
/// # Safety
/// `rules` must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_create_with_trust(
    rules: *const c_char,
    trusted: bool,
) -> *mut AdblockEngine {
    guarded(ptr::null_mut(), || {
        let Some(text) = str_from(rules) else {
            return ptr::null_mut();
        };
        let mut options = ParseOptions::default();
        if trusted {
            options.permissions = adblock::resources::PermissionMask::from_bits(0xFF);
        }
        let mut set = FilterSet::new(false);
        set.add_filter_list(text.to_owned(), options);
        let engine = Engine::new_with_filter_set(set);
        Box::into_raw(Box::new(AdblockEngine { engine }))
    })
}

/// Rebuild an engine from the bytes produced by [`adblock_engine_serialize`].
///
/// Parsing EasyList takes seconds; reloading a serialized engine takes
/// milliseconds, which is the difference between blocking working on the first
/// page load after launch and working a few seconds later.
///
/// # Safety
/// `data` must point to at least `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_create_from_serialized(
    data: *const u8,
    len: usize,
) -> *mut AdblockEngine {
    guarded(ptr::null_mut(), || {
        if data.is_null() || len == 0 {
            return ptr::null_mut();
        }
        let bytes = std::slice::from_raw_parts(data, len);
        let mut engine = Engine::new_with_filter_set(FilterSet::new(false));
        match engine.deserialize(bytes) {
            Ok(()) => Box::into_raw(Box::new(AdblockEngine { engine })),
            Err(_) => ptr::null_mut(),
        }
    })
}

/// Release an engine. Null is a no-op; passing the same pointer twice is not.
///
/// # Safety
/// `engine` must have come from one of the create functions and not been freed.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_free(engine: *mut AdblockEngine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(engine))));
}

// MARK: - Matching

/// Should this request be blocked?
///
/// `request_type` is the adblock resource type — `script`, `image`,
/// `xmlhttprequest`, `sub_frame`/`subdocument`, `stylesheet`, `media`,
/// `websocket`, `fetch`, `other`. First/third-party is derived from `url`
/// against `source_url`, so the caller doesn't have to work it out.
///
/// Returns `false` for any malformed input: failing open matches what a browser
/// should do when it can't classify a request.
///
/// # Safety
/// All pointers must be valid NUL-terminated C strings; `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_matches(
    engine: *const AdblockEngine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> bool {
    guarded(false, || {
        if engine.is_null() {
            return false;
        }
        let (Some(url), Some(source), Some(kind)) =
            (str_from(url), str_from(source_url), str_from(request_type))
        else {
            return false;
        };
        let Ok(request) = Request::new(url, source, kind, "get") else {
            return false;
        };
        (*engine).engine.check_network_request(&request).should_block()
    })
}

/// Cosmetic filters for a page, as JSON: `hide_selectors`, `procedural_actions`,
/// `exceptions`, `injected_script`, `generichide`.
///
/// `injected_script` is executable JavaScript assembled from the bundled
/// scriptlet resources. It must only ever come from resources compiled into the
/// app — App Store guideline 2.5.2 does not permit downloading and running code.
///
/// Returns null on failure. Free with [`adblock_string_free`].
///
/// # Safety
/// `engine` must be live and `url` a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_cosmetic_resources(
    engine: *const AdblockEngine,
    url: *const c_char,
) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        if engine.is_null() {
            return ptr::null_mut();
        }
        let Some(url) = str_from(url) else {
            return ptr::null_mut();
        };
        let resources = (*engine).engine.url_cosmetic_resources(url);
        match serde_json::to_string(&resources) {
            Ok(json) => string_out(json),
            Err(_) => ptr::null_mut(),
        }
    })
}

/// Load the scriptlet resources that `+js(...)` filter rules inject.
///
/// `resources_json` is the standard resources array: `name`, `aliases`, `kind`,
/// and base64 `content`. Without this, `injected_script` in the cosmetic
/// resources is always empty, because a `+js(...)` rule names a scriptlet the
/// engine has no body for.
///
/// These resources are executable JavaScript and must be compiled into the app.
/// Fetching them over the network would be downloading code, which App Store
/// guideline 2.5.2 does not permit — unlike the filter lists themselves, which
/// are data and may be updated.
///
/// Returns false if the payload is missing, not UTF-8, or not a resources array.
///
/// # Safety
/// `engine` must be live and `resources_json` a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_use_resources(
    engine: *mut AdblockEngine,
    resources_json: *const c_char,
) -> bool {
    guarded(false, || {
        if engine.is_null() {
            return false;
        }
        let Some(json) = str_from(resources_json) else {
            return false;
        };
        let Ok(resources) = serde_json::from_str::<Vec<adblock::resources::Resource>>(json) else {
            return false;
        };
        (*engine).engine.use_resources(resources);
        true
    })
}

/// Generic cosmetic selectors matching the classes and ids actually present on a
/// page.
///
/// The great majority of EasyList's cosmetic rules are generic — `##.ad-banner`
/// with no domain — and [`adblock_engine_cosmetic_resources`] deliberately does
/// not return them: there are hundreds of thousands, and only the handful whose
/// class or id appears in the document matter. So the page reports what it
/// contains and gets back the subset that applies.
///
/// `classes_json`, `ids_json` and `exceptions_json` are JSON arrays of strings;
/// `exceptions` is the `exceptions` field from the call above. Returns a JSON
/// array of selectors, or null on failure. Free with [`adblock_string_free`].
///
/// # Safety
/// All pointers must be valid NUL-terminated C strings; `engine` must be live.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_hidden_class_id_selectors(
    engine: *const AdblockEngine,
    classes_json: *const c_char,
    ids_json: *const c_char,
    exceptions_json: *const c_char,
) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        if engine.is_null() {
            return ptr::null_mut();
        }
        let (Some(classes), Some(ids), Some(exceptions)) = (
            str_from(classes_json),
            str_from(ids_json),
            str_from(exceptions_json),
        ) else {
            return ptr::null_mut();
        };

        let (Ok(classes), Ok(ids), Ok(exceptions)) = (
            serde_json::from_str::<Vec<String>>(classes),
            serde_json::from_str::<Vec<String>>(ids),
            serde_json::from_str::<std::collections::HashSet<String>>(exceptions),
        ) else {
            return ptr::null_mut();
        };

        let selectors = (*engine)
            .engine
            .hidden_class_id_selectors(classes, ids, &exceptions);
        match serde_json::to_string(&selectors) {
            Ok(json) => string_out(json),
            Err(_) => ptr::null_mut(),
        }
    })
}

// MARK: - Serialization

/// Serialize an engine so the next launch can skip parsing. Writes the length
/// to `out_len` and returns the buffer, or null on failure.
///
/// Free with [`adblock_bytes_free`], passing back the same length.
///
/// # Safety
/// `engine` must be live; `out_len` must be a valid writable pointer.
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_serialize(
    engine: *const AdblockEngine,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(ptr::null_mut(), || {
        if engine.is_null() || out_len.is_null() {
            return ptr::null_mut();
        }
        let bytes = (*engine).engine.serialize();
        // Into a boxed slice first so capacity == length, which is what
        // `adblock_bytes_free` reconstructs the Vec with.
        let mut boxed = bytes.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        let len = boxed.len();
        std::mem::forget(boxed);
        *out_len = len;
        ptr
    })
}

/// Release a buffer from [`adblock_engine_serialize`].
///
/// # Safety
/// `data`/`len` must be exactly what `adblock_engine_serialize` returned.
#[no_mangle]
pub unsafe extern "C" fn adblock_bytes_free(data: *mut u8, len: usize) {
    if data.is_null() || len == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Vec::from_raw_parts(data, len, len));
    }));
}

// MARK: - Content blocker conversion

/// Convert filter-list text into Apple content-blocker JSON, ready for
/// `WKContentRuleListStore.compileContentRuleList`.
///
/// This is the engine's most important job on iOS: `WKNavigationDelegate` never
/// sees subresource requests, so declarative rules compiled into WebKit are the
/// only way to block images, scripts and frames at all.
///
/// Note the `FilterSet` is built in debug mode — the converter refuses to run
/// without it, because it needs the original rule text to emit triggers.
///
/// Rules WebKit can't express are dropped rather than failing the batch. That
/// loss is not evenly distributed and it matters: most exception (`@@`) rules use
/// options the declarative syntax has no equivalent for, so they disappear while
/// the block rules they were written to override survive. The result is
/// over-blocking. `network_only` exists because of the same problem in cosmetic
/// rules — see below.
///
/// With `network_only` set, cosmetic rules are left out entirely. Converting them
/// produces `css-display-none` entries that apply to every site with no way to
/// honour `#@#` unhide rules or `$generichide` exceptions, which hides legitimate
/// page content. The runtime engine applies the same rules correctly, scoped per
/// URL and with exceptions intact, so the declarative copy is pure downside.
///
/// Returns null only if nothing could be produced. Free with
/// [`adblock_string_free`].
///
/// # Safety
/// `filter_set` must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn adblock_content_blocker_rules(
    filter_set: *const c_char,
    network_only: bool,
) -> *mut c_char {
    guarded(ptr::null_mut(), || {
        let Some(text) = str_from(filter_set) else {
            return ptr::null_mut();
        };
        let mut options = ParseOptions::default();
        if network_only {
            options.rule_types = adblock::lists::RuleTypes::NetworkOnly;
        }
        let mut set = FilterSet::new(true);
        set.add_filter_list(text.to_owned(), options);
        let Ok((rules, _unsupported)) = set.into_content_blocking() else {
            return ptr::null_mut();
        };
        match serde_json::to_string(&rules) {
            Ok(json) => string_out(json),
            Err(_) => ptr::null_mut(),
        }
    })
}

// MARK: - Shared frees and version

/// Release a string returned by this library.
///
/// # Safety
/// `value` must have come from this library and not been freed.
#[no_mangle]
pub unsafe extern "C" fn adblock_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(value))));
}

/// Version of the underlying `adblock` crate, for logging and cache
/// invalidation — a serialized engine from a different version won't load.
/// The returned string is static and must not be freed.
#[no_mangle]
pub extern "C" fn adblock_engine_version() -> *const c_char {
    // Built at compile time, NUL included, so no allocation and no free.
    concat!("0.13.2", "\0").as_ptr() as *const c_char
}

// MARK: - Tests
//
// These call the C entry points the way Swift will, on the host toolchain, so a
// broken boundary shows up here rather than as a crash on device.

#[cfg(test)]
mod tests {
    use super::*;

    const RULES: &str = "\
||ads.example.com^
||tracker.test/pixel.gif
example.org##.ad-banner
@@||ads.example.com/allowed^
";

    fn c(value: &str) -> CString {
        CString::new(value).unwrap()
    }

    unsafe fn take_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "expected a string, got null");
        let out = CStr::from_ptr(ptr).to_str().unwrap().to_owned();
        adblock_string_free(ptr);
        out
    }

    #[test]
    fn blocks_and_excepts() {
        unsafe {
            let engine = adblock_engine_create(c(RULES).as_ptr());
            assert!(!engine.is_null());

            let source = c("https://example.org/");
            let kind = c("image");

            let blocked = adblock_engine_matches(
                engine, c("https://ads.example.com/banner.png").as_ptr(),
                source.as_ptr(), kind.as_ptr());
            assert!(blocked, "third-party ad host should be blocked");

            let allowed = adblock_engine_matches(
                engine, c("https://ads.example.com/allowed/banner.png").as_ptr(),
                source.as_ptr(), kind.as_ptr());
            assert!(!allowed, "@@ exception should win");

            let unrelated = adblock_engine_matches(
                engine, c("https://cdn.example.org/logo.png").as_ptr(),
                source.as_ptr(), kind.as_ptr());
            assert!(!unrelated, "unmatched request should pass");

            adblock_engine_free(engine);
        }
    }

    #[test]
    fn converts_to_content_blocker_json() {
        unsafe {
            let json = take_string(adblock_content_blocker_rules(c(RULES).as_ptr(), false));
            let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
            let rules = parsed.as_array().expect("content blocker JSON is an array");
            assert!(!rules.is_empty());
            // Every entry must carry the two keys WKContentRuleListStore requires.
            for rule in rules {
                assert!(rule.get("trigger").is_some(), "missing trigger: {rule}");
                assert!(rule.get("action").is_some(), "missing action: {rule}");
            }
            // The cosmetic rule should have become a css-display-none action.
            assert!(json.contains("css-display-none"), "cosmetic rule was dropped");
        }
    }

    #[test]
    fn cosmetic_resources_are_scoped_to_the_page() {
        unsafe {
            let engine = adblock_engine_create(c(RULES).as_ptr());
            let json = take_string(
                adblock_engine_cosmetic_resources(engine, c("https://example.org/").as_ptr()));
            assert!(json.contains(".ad-banner"), "expected the site's hide selector: {json}");

            let other = take_string(
                adblock_engine_cosmetic_resources(engine, c("https://other.test/").as_ptr()));
            assert!(!other.contains(".ad-banner"), "selector leaked to another site");
            adblock_engine_free(engine);
        }
    }


    #[test]
    fn generic_selectors_need_the_page_to_report_its_classes() {
        unsafe {
            let engine = adblock_engine_create(c("##.generic-ad\n").as_ptr());
            // Nothing URL-specific, so the per-page call returns no selectors.
            let scoped = take_string(
                adblock_engine_cosmetic_resources(engine, c("https://example.org/").as_ptr()));
            assert!(!scoped.contains("generic-ad"), "generic rule leaked into scoped call");

            // Reporting the class present on the page brings it back.
            let hit = take_string(adblock_engine_hidden_class_id_selectors(
                engine, c("[\"generic-ad\"]").as_ptr(), c("[]").as_ptr(), c("[]").as_ptr()));
            assert!(hit.contains("generic-ad"), "expected the generic selector: {hit}");

            let miss = take_string(adblock_engine_hidden_class_id_selectors(
                engine, c("[\"unrelated\"]").as_ptr(), c("[]").as_ptr(), c("[]").as_ptr()));
            assert_eq!(miss, "[]", "unrelated class should match nothing");
            adblock_engine_free(engine);
        }
    }


    #[test]
    fn scriptlet_resources_reach_the_injected_script() {
        unsafe {
            // A `+js(...)` rule resolves to nothing until the named scriptlet is
            // loaded, and it fails silently, so check both sides of that.
            let engine = adblock_engine_create(c("example.org##+js(set, x, false)\n").as_ptr());
            let before = take_string(
                adblock_engine_cosmetic_resources(engine, c("https://example.org/").as_ptr()));
            assert!(before.contains("\"injected_script\":\"\""),
                    "expected no scriptlet before resources are loaded");

            let resources = std::fs::read_to_string(
                "../prototype/MinimalBrowser/FilterLists/scriptlets.json").unwrap();
            assert!(adblock_engine_use_resources(engine, c(&resources).as_ptr()));

            let after = take_string(
                adblock_engine_cosmetic_resources(engine, c("https://example.org/").as_ptr()));
            assert!(after.contains("mbSetConstant"), "scriptlet body missing");
            assert!(after.contains("mbDefinePath"), "declared dependency missing");
            adblock_engine_free(engine);

            // Malformed input must not be mistaken for a resources array.
            let engine = adblock_engine_create(c("").as_ptr());
            assert!(!adblock_engine_use_resources(engine, c("not json").as_ptr()));
            assert!(!adblock_engine_use_resources(engine, ptr::null()));
            adblock_engine_free(engine);
        }
    }

    #[test]
    fn serialize_round_trips() {
        unsafe {
            let engine = adblock_engine_create(c(RULES).as_ptr());
            let mut len: usize = 0;
            let bytes = adblock_engine_serialize(engine, &mut len);
            assert!(!bytes.is_null() && len > 0);

            let restored = adblock_engine_create_from_serialized(bytes, len);
            assert!(!restored.is_null(), "serialized engine failed to reload");
            assert!(adblock_engine_matches(
                restored, c("https://ads.example.com/banner.png").as_ptr(),
                c("https://example.org/").as_ptr(), c("image").as_ptr()));

            adblock_bytes_free(bytes, len);
            adblock_engine_free(restored);
            adblock_engine_free(engine);
        }
    }

    #[test]
    fn null_and_garbage_input_is_survivable() {
        unsafe {
            assert!(adblock_engine_create(ptr::null()).is_null());
            assert!(adblock_engine_create_from_serialized(ptr::null(), 0).is_null());
            assert!(!adblock_engine_matches(
                ptr::null(), ptr::null(), ptr::null(), ptr::null()));
            // Double-free guards: null is always a no-op.
            adblock_engine_free(ptr::null_mut());
            adblock_string_free(ptr::null_mut());
            adblock_bytes_free(ptr::null_mut(), 0);

            // Garbage bytes must not be mistaken for a serialized engine.
            let junk = [0u8, 1, 2, 3, 4, 5, 6, 7];
            assert!(adblock_engine_create_from_serialized(junk.as_ptr(), junk.len()).is_null());
        }
    }
}
