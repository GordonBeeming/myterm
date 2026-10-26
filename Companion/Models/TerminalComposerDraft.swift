import Foundation
import Observation
import MyTermCore
import MyTermRemote

@MainActor
@Observable
final class TerminalComposerDraft {
    nonisolated static let maximumUTF8Bytes = 64 * 1_024
    var text: String { didSet { persist() } }
    var isSending = false
    var errorMessage: String?
    var persistenceErrorMessage: String?
    var insertionOutcome: TerminalInsertionOutcome? { didSet { persist() } }
    @ObservationIgnored var onChange: ((String, TerminalInsertionOutcome?) -> Void)?

    init(text: String = "", insertionOutcome: TerminalInsertionOutcome? = nil) {
        self.text = text
        self.insertionOutcome = insertionOutcome == .sending ? .unconfirmed : insertionOutcome
    }

    private func persist() { onChange?(text, insertionOutcome) }

    func beginInsertion() {
        isSending = true
        errorMessage = nil
        insertionOutcome = .sending
    }

    func finishInsertion(error: Error?) {
        isSending = false
        if let error {
            errorMessage = error.localizedDescription
            insertionOutcome = error is TerminalComposerError ? .notInserted : .unconfirmed
        } else {
            insertionOutcome = .transportSent
        }
    }

    static func pasteBytes(_ text: String, bracketed: Bool, appendReturn: Bool) throws -> Data {
        guard !text.isEmpty else { throw TerminalComposerError.empty }
        guard text.utf8.count <= maximumUTF8Bytes else { throw TerminalComposerError.tooLong }
        guard text.unicodeScalars.allSatisfy({
            (32...126).contains($0.value) || $0.value >= 160 || [9, 10, 13].contains($0.value)
        }) else { throw TerminalComposerError.controlCharacters }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard bracketed || !normalized.contains("\n") else { throw TerminalComposerError.multilineRequiresBracketedPaste }
        var paste = bracketed ? "\u{1b}[200~" + normalized + "\u{1b}[201~" : normalized
        if appendReturn { paste += "\r" }
        return Data(paste.utf8)
    }
}

enum TerminalComposerError: LocalizedError {
    case empty, tooLong, controlCharacters, requiresControl, multilineRequiresBracketedPaste

    var errorDescription: String? {
        switch self {
        case .empty: "Write something before inserting it."
        case .tooLong: "This draft is too long. Split it into smaller messages."
        case .controlCharacters: "The draft contains terminal control characters. Remove them before inserting it."
        case .requiresControl: "Take control of this terminal before inserting your draft."
        case .multilineRequiresBracketedPaste:
            "This terminal does not support safe multiline paste. Insert one line at a time, or enable bracketed paste in the terminal application."
        }
    }
}

/// Terminal input has no execution acknowledgement. A transport write must never be labelled
/// as an agent accepting or running the text, and uncertain writes are never replayed.
enum TerminalInsertionOutcome: String, Codable {
    case sending, transportSent, unconfirmed, notInserted

    var message: String {
        switch self {
        case .sending: "Sending to the terminal…"
        case .transportSent: "Sent over the connection. Check the terminal to confirm it arrived; execution is not acknowledged."
        case .unconfirmed: "Insertion is unconfirmed. Check the terminal before inserting again to avoid duplicates. Your draft was kept."
        case .notInserted: "Draft was not inserted. Your draft was kept."
        }
    }
}

@MainActor
final class TerminalDraftStore {
    static let shared = TerminalDraftStore()
    nonisolated static let maximumEntries = 128
    private let defaults: UserDefaults
    private static let legacyStorageKey = "companionTerminalDrafts.v1"
    private static let indexKey = "companionTerminalDrafts.v2.index"
    private static let entryPrefix = "companionTerminalDrafts.v2.entry."
    private var drafts: [String: TerminalComposerDraft] = [:]
    private var stored: [String: Entry] = [:]
    private struct Entry: Codable, Equatable {
        var text: String
        var outcome: TerminalInsertionOutcome?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for key in defaults.stringArray(forKey: Self.indexKey) ?? [] {
            guard let data = defaults.data(forKey: Self.entryPrefix + key),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            stored[key] = entry
        }
        migrateLegacyEntries()
    }

    private func key(for route: TerminalRoute) -> String {
        "\(route.connectionID.storageKey)|\(route.workspaceID)|\(route.sessionID)"
    }

    func draft(for route: TerminalRoute) -> TerminalComposerDraft {
        let key = key(for: route)
        if let draft = drafts[key] { return draft }
        let entry = stored[key]
        let draft = TerminalComposerDraft(text: entry?.text ?? "", insertionOutcome: entry?.outcome)
        draft.onChange = { [weak self, weak draft] text, outcome in
            guard let self, let draft else { return }
            if text.isEmpty && outcome == nil { self.removeStoredEntry(key) }
            else {
                guard text.utf8.count <= TerminalComposerDraft.maximumUTF8Bytes else {
                    draft.persistenceErrorMessage = "Latest changes are only in memory: this draft exceeds 64 KiB. Shorten it to save across app restarts."
                    return
                }
                guard self.stored[key] != nil || self.stored.count < Self.maximumEntries else {
                    draft.persistenceErrorMessage = "This draft is only in memory: 128 drafts are already saved. Clear a saved draft, then edit this one to save it across app restarts."
                    return
                }
                let entry = Entry(text: text, outcome: outcome)
                guard self.stored[key] != entry else { draft.persistenceErrorMessage = nil; return }
                guard let encoded = try? JSONEncoder().encode(entry) else {
                    draft.persistenceErrorMessage = "Latest changes could not be saved and are only in memory."
                    return
                }
                let isNew = self.stored[key] == nil
                self.defaults.set(encoded, forKey: Self.entryPrefix + key)
                self.stored[key] = entry
                if isNew { self.publishIndex() }
            }
            draft.persistenceErrorMessage = nil
        }
        drafts[key] = draft
        return draft
    }

    /// Call only after a complete snapshot from this pairing's current authenticated connection.
    /// Cached/offline projections must never be used to decide that a terminal has disappeared.
    func pruneClosedTerminals(for connectionID: SavedConnectionID, projection: RemoteWorkspaceProjection) {
        let prefix = connectionID.storageKey + "|"
        var active: Set<String> = []
        for workspace in projection.workspaces {
            for group in workspace.groups {
                for tab in group.tabs {
                    if let session = tab.terminalSessionID {
                        active.insert("\(prefix)\(workspace.id.rawValue)|\(session.rawValue)")
                    }
                }
            }
        }
        for key in Set(stored.keys).union(drafts.keys) where key.hasPrefix(prefix) && !active.contains(key) {
            // A full catalog can leave a draft only in memory. Its latest insertion outcome is
            // authoritative even when there is no persisted entry (or it contains older text).
            let outcome = drafts[key]?.insertionOutcome ?? stored[key]?.outcome
            // An interrupted write may have reached the terminal. Retain it for explicit review.
            guard drafts[key]?.isSending != true, outcome != .sending, outcome != .unconfirmed else { continue }
            removeStoredEntry(key)
            if let draft = drafts.removeValue(forKey: key) {
                draft.onChange = nil
                draft.persistenceErrorMessage = "This terminal has closed. The remaining draft is only in memory."
            }
        }
    }

    func forget(_ connectionID: SavedConnectionID) {
        let prefix = connectionID.storageKey + "|"
        for key in drafts.keys.filter({ $0.hasPrefix(prefix) }) {
            let draft = drafts.removeValue(forKey: key)
            draft?.onChange = nil
            draft?.text = ""
            draft?.insertionOutcome = nil
        }
        for key in stored.keys.filter({ $0.hasPrefix(prefix) }) { removeStoredEntry(key) }
    }

    private func removeStoredEntry(_ key: String) {
        guard stored.removeValue(forKey: key) != nil else { return }
        defaults.removeObject(forKey: Self.entryPrefix + key)
        publishIndex()
    }

    private func publishIndex() { defaults.set(stored.keys.sorted(), forKey: Self.indexKey) }

    /// The v1 blob remains recoverable until every v2 entry has been encoded and written.
    /// A partially completed migration can be retried: existing v2 values take precedence.
    private func migrateLegacyEntries() {
        guard let data = defaults.data(forKey: Self.legacyStorageKey),
              let legacy = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        var merged = legacy
        merged.merge(stored) { _, current in current }
        var encoded: [String: Data] = [:]
        for (key, entry) in merged {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            encoded[key] = data
        }
        for (key, data) in encoded { defaults.set(data, forKey: Self.entryPrefix + key) }
        stored = merged
        publishIndex()
        defaults.removeObject(forKey: Self.legacyStorageKey)
    }
}

@MainActor
extension SceneModel {
    func updateSharedSnippet(_ snippet: TerminalSnippet?, deleting id: UUID? = nil,
                             route: TerminalRoute) async throws {
        guard selectedConnectionID == route.connectionID, connectionPhase == .online,
              hasFreshProjection, projection?.terminalSnippets != nil else {
            throw RemoteError.disconnected
        }
        let payload: Data
        let operation: CommandOperation
        if let snippet {
            payload = try JSONEncoder().encode(snippet)
            operation = .snippetUpsert
        } else if let id {
            payload = try JSONEncoder().encode(RemoteIdentifierResult(id: id))
            operation = .snippetDelete
        } else { return }
        let response = try await command(operation, metadata: MessageMetadata(
            hostID: route.hostID, workspaceID: route.workspaceID), payload: payload)
        guard let response, let current = projection,
              selectedConnectionID == route.connectionID else { throw RemoteError.disconnected }
        let snippets = try JSONDecoder().decode([TerminalSnippet].self, from: response)
        projection = RemoteWorkspaceProjection(folders: current.folders, workspaces: current.workspaces,
                                               terminalSnippets: snippets)
    }
}

/// A new entry keeps its identity until the Mac acknowledges it. Acknowledgement starts a new
/// entry; an interrupted request keeps the same identity so an explicit retry is an upsert.
struct TerminalSnippetCreationState {
    private(set) var id = UUID()

    mutating func didConfirmSave(of savedID: UUID) {
        guard savedID == id else { return }
        id = UUID()
    }
}
