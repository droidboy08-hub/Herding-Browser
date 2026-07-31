import Foundation

/// Search engines the user can pick in Settings.
enum SearchEngine: String, CaseIterable, Codable {
    case duckDuckGo, google, bing, brave, startpage

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google:     return "Google"
        case .bing:       return "Bing"
        case .brave:      return "Brave"
        case .startpage:  return "Startpage"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .google:     base = "https://www.google.com/search"
        case .bing:       base = "https://www.bing.com/search"
        case .brave:      base = "https://search.brave.com/search"
        case .startpage:  base = "https://www.startpage.com/sp/search"
        }
        var comps = URLComponents(string: base)
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps?.url
    }
}

/// Small persisted app settings (UserDefaults).
enum Settings {
    private static let engineKey = "settings.searchEngine.v1"

    static var searchEngine: SearchEngine {
        get {
            UserDefaults.standard.string(forKey: engineKey)
                .flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }
}
