//! Diagnoses how faithfully the declarative conversion preserves the source list —
//! in particular whether exception rules survive, since a dropped exception turns
//! into over-blocking with no way for the user to tell why.
use std::collections::BTreeMap;

fn main() {
    let base = "../prototype/MinimalBrowser/FilterLists";
    for name in ["easylist.txt", "easyprivacy.txt"] {
        let text = std::fs::read_to_string(format!("{base}/{name}")).unwrap();

        let source_exceptions = text.lines().filter(|l| l.starts_with("@@")).count();

        let mut network_only = adblock::lists::ParseOptions::default();
        network_only.rule_types = adblock::lists::RuleTypes::NetworkOnly;
        let mut set = adblock::lists::FilterSet::new(true);
        set.add_filter_list(text, network_only);
        let (rules, unsupported) = set.into_content_blocking().unwrap();

        let mut actions: BTreeMap<String, usize> = BTreeMap::new();
        for rule in &rules {
            *actions.entry(format!("{:?}", rule.action.typ)).or_default() += 1;
        }
        let dropped_exceptions = unsupported.iter().filter(|l| l.starts_with("@@")).count();

        println!("\n{name}");
        println!("  converted rules      : {}", rules.len());
        println!("  unsupported (dropped): {}", unsupported.len());
        println!("  source @@ exceptions : {source_exceptions}");
        println!("  @@ exceptions dropped: {dropped_exceptions}  ({:.0}% of them)",
                 100.0 * dropped_exceptions as f64 / source_exceptions.max(1) as f64);
        println!("  action breakdown     : {actions:?}");
    }
}
