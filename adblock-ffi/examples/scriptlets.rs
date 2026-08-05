//! Checks the scriptlet bundle against the real filter lists: every `+js(...)`
//! rule the app ships should resolve to an actual invocation. A rule naming a
//! scriptlet we don't have resolves to nothing, silently, so this is the only
//! way to know the coverage is real.
use adblock::engine::Engine;
use adblock::lists::{FilterSet, ParseOptions};
use adblock::resources::Resource;

fn engine_with_resources(rules: &str) -> Engine {
    let mut set = FilterSet::new(false);
    set.add_filter_list(rules.to_owned(), ParseOptions::default());
    let mut engine = Engine::new_with_filter_set(set);
    let json = std::fs::read_to_string(
        "../prototype/MinimalBrowser/FilterLists/scriptlets.json").unwrap();
    let resources: Vec<Resource> = serde_json::from_str(&json).unwrap();
    engine.use_resources(resources);
    engine
}

fn main() {
    // 1. Does a rule produce a real call, with the arguments intact?
    let engine = engine_with_resources("example.org##+js(set, admiral, noopFunc)\n");
    let script = engine.url_cosmetic_resources("https://example.org/").injected_script;
    assert!(script.contains("function mbSetConstant"), "helper body missing");
    assert!(script.contains("function mbDefinePath"), "dependency not pulled in");
    assert!(script.contains(r#"mbSetConstant("admiral", "noopFunc")"#),
            "invocation missing or mis-encoded:\n{}",
            &script[script.len().saturating_sub(300)..]);
    println!("invocation + dependency wiring: OK");

    // 2. Every distinct rule in the shipped lists.
    let base = "../prototype/MinimalBrowser/FilterLists";
    let mut rules = vec![];
    for name in ["easylist.txt", "easyprivacy.txt"] {
        let text = std::fs::read_to_string(format!("{base}/{name}")).unwrap();
        for line in text.lines() {
            if let Some(at) = line.find("##+js(") {
                rules.push(line[at + 2..].to_owned());
            }
        }
    }
    rules.sort();
    rules.dedup();

    let mut resolved = 0;
    let mut unresolved = vec![];
    for rule in &rules {
        let engine = engine_with_resources(&format!("scriptlettest.example##{rule}\n"));
        let script = engine
            .url_cosmetic_resources("https://scriptlettest.example/")
            .injected_script;
        if script.trim().is_empty() {
            unresolved.push(rule.clone());
        } else {
            resolved += 1;
        }
    }

    println!("\n{resolved}/{} distinct +js rules resolve", rules.len());
    for rule in &unresolved {
        println!("  UNRESOLVED  {rule}");
    }
    assert!(unresolved.is_empty(), "{} rules have no scriptlet", unresolved.len());
    println!("\nall shipped +js rules resolve to a scriptlet");
}
