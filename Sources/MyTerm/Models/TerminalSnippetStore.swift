import Foundation
import MyTermCore
import Observation

/// The Mac owns this catalog and shares it with paired companions through workspace snapshots.
@MainActor
@Observable
final class DesktopTerminalSnippetStore {
    static let shared = DesktopTerminalSnippetStore()
    private(set) var snippets: [TerminalSnippet]
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "terminalSnippets.v1"
    static let maximumUTF8Bytes = 64 * 1_024

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snippets = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([TerminalSnippet].self, from: $0) } ?? []
    }

    @discardableResult
    func save(_ snippet: TerminalSnippet) -> Bool {
        var snippet = snippet
        snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.title.isEmpty, snippet.title.utf8.count <= 256, !snippet.text.isEmpty,
              snippet.text.utf8.count <= Self.maximumUTF8Bytes else { return false }
        // Bound the entire catalog so a workspace snapshot stays below the encrypted frame limit.
        let others = snippets.filter { $0.id != snippet.id }
        guard others.count < 100,
              let encodedSnippet = try? JSONEncoder().encode(snippet), encodedSnippet.count <= 96 * 1_024,
              let encodedCatalog = try? JSONEncoder().encode(others + [snippet]),
              encodedCatalog.count <= 192 * 1_024 else { return false }
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet }
        else { snippets.append(snippet) }
        persist()
        return true
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: Self.storageKey) }
    }
}
