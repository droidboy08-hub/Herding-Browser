//! Checks that the rules a video site needs actually reach the page.
//!
//! Ads on those sites are described inside the site's own player response, so
//! nothing blocks them at the network layer — the payload has to be rewritten
//! before the player reads it, and the rules that do it are `trusted-…` ones.
//! Those are dropped at parse time unless the list is parsed as trusted, and
//! dropped silently, which is why this is worth asserting rather than assuming.
use adblock::engine::Engine;
use adblock::lists::{FilterSet, ParseOptions};
use adblock::resources::{PermissionMask, Resource};

fn engine(rules: &str, trusted: bool) -> Engine {
    let mut options = ParseOptions::default();
    if trusted {
        options.permissions = PermissionMask::from_bits(0xFF);
    }
    let mut set = FilterSet::new(false);
    set.add_filter_list(rules.to_owned(), options);
    let mut engine = Engine::new_with_filter_set(set);
    let json = std::fs::read_to_string(
        "../prototype/MinimalBrowser/FilterLists/scriptlets.json").unwrap();
    let resources: Vec<Resource> = serde_json::from_str(&json).unwrap();
    engine.use_resources(resources);
    engine
}

fn main() {
    let rule = concat!(
        "www.youtube.com##+js(trusted-replace-fetch-response, '\"adPlacements\"', ",
        "'\"no_ads\"', player?)\n"
    );

    // Untrusted: the rule is dropped, and nothing says so.
    let script = engine(rule, false)
        .url_cosmetic_resources("https://www.youtube.com/watch?v=x")
        .injected_script;
    assert!(script.is_empty(),
            "expected an untrusted parse to drop the rule, got:\n{script}");
    println!("untrusted parse drops trusted-… rules: confirmed");

    // Trusted: the scriptlet body and the call both arrive.
    let script = engine(rule, true)
        .url_cosmetic_resources("https://www.youtube.com/watch?v=x")
        .injected_script;
    assert!(script.contains("function mbTrustedReplaceFetchResponse"),
            "scriptlet body missing:\n{script}");
    assert!(script.contains("mbBodyRewriter"), "helper not pulled in");
    assert!(script.contains("mbTrustedReplaceFetchResponse("),
            "invocation missing:\n{script}");
    println!("trusted parse injects the rewriter: OK");

    // Now the real list, as the app fetches it.
    let base = "../prototype/MinimalBrowser/FilterLists";
    let mut text = std::fs::read_to_string(format!("{base}/app-extras.txt")).unwrap();
    if let Ok(live) = std::fs::read_to_string("/tmp/uassets-filters.txt") {
        text.push('\n');
        text.push_str(&live);
    }
    let engine = engine(&text, true);
    let mut covered = 0;
    for url in ["https://www.youtube.com/watch?v=x",
                "https://m.youtube.com/watch?v=x"] {
        let script = engine.url_cosmetic_resources(url).injected_script;
        let hits = script.matches("mbTrustedReplace").count();
        println!("{url}: {hits} response-rewriting call(s), {} bytes of scriptlet",
                 script.len());
        if hits > 0 { covered += 1; }
    }
    assert!(covered > 0, "the shipped list produced no rewriting calls for YouTube");
}
