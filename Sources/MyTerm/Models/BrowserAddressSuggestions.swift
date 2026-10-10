import Foundation
import MyTermCore

struct BrowserAddressSuggestions {
    struct OpenTab: Equatable {
        let title: String
        let url: URL
        let tabID: TabID
    }

    enum Action: Equatable {
        case navigate(String)
        case switchTab(TabID)
    }

    struct Suggestion: Equatable {
        let title: String
        let detail: String
        let action: Action
    }

    static func suggestions(text: String, openTabs: [OpenTab], currentTabID: TabID) -> [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Suggestion] = query.isEmpty ? [] : [
            Suggestion(title: "Go to \(query)", detail: "Opens in this tab", action: .navigate(query))
        ]
        var seen = Set<TabID>()
        for tab in openTabs where tab.tabID != currentTabID {
            guard seen.insert(tab.tabID).inserted,
                  query.isEmpty || tab.title.localizedCaseInsensitiveContains(query)
                    || tab.url.absoluteString.localizedCaseInsensitiveContains(query) else { continue }
            result.append(Suggestion(title: tab.title, detail: tab.url.absoluteString, action: .switchTab(tab.tabID)))
            if result.count == 5 { break }
        }
        return result
    }
}
