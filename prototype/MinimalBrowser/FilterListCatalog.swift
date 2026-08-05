import Foundation

/// One list in the catalogue the user can switch on: a name, what it is, and
/// where to fetch it.
struct CatalogFilterList: Codable, Identifiable, Equatable {
    let id: String
    /// What the list is for, in the app's words — "Cookie notice blocker".
    let title: String
    /// The list's own name, shown underneath — "EasyList Cookie".
    let desc: String
    let url: URL
    /// On for a new install. True for the two least intrusive lists.
    let defaultEnabled: Bool
    /// Language codes the list is for, empty for the global ones. Used to float
    /// the lists matching the device's languages to the top of the section.
    let langs: [String]
}

/// The catalogue of optional filter lists, from `filter-list-catalog.json`.
///
/// The catalogue is trimmed to what a row needs. Bundling the catalogue while
/// fetching the lists themselves on demand is the arrangement
/// that makes ~50 lists possible at all: the rules are tens of megabytes, and
/// nobody wants the Vietnamese, Polish and Hebrew lists parsed on their phone
/// unless they asked for them.
///
/// The catalogue is data, so it can be refreshed over the network like the lists
/// are; the bundled copy is the floor, not the ceiling.
enum FilterListCatalog {

    /// Every switchable list, device languages first.
    static let entries: [CatalogFilterList] = {
        guard let url = Bundle.main.url(forResource: "filter-list-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CatalogFilterList].self, from: data) else {
            print("[FilterListCatalog] filter-list-catalog.json missing or malformed")
            return []
        }
        return sortedForDevice(decoded)
    }()

    static func entry(id: String) -> CatalogFilterList? {
        entries.first { $0.id == id }
    }

    /// Global lists first, then the ones for languages this device is set up
    /// for, then the rest alphabetically. A German speaker shouldn't have to
    /// scroll past forty other languages to find the German list.
    private static func sortedForDevice(_ lists: [CatalogFilterList]) -> [CatalogFilterList] {
        let deviceLanguages = Set(Locale.preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        })
        func rank(_ list: CatalogFilterList) -> Int {
            if list.langs.isEmpty { return 0 }                                  // global
            if !deviceLanguages.isDisjoint(with: Set(list.langs)) { return 1 }  // yours
            return 2
        }
        return lists.sorted {
            rank($0) == rank($1) ? $0.title < $1.title : rank($0) < rank($1)
        }
    }
}
