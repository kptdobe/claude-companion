import Foundation

/// A session the user pinned so it survives closing and can be reopened.
///
/// Only the durable identity is stored: `sessionId` (the transcript filename),
/// `cwd` (needed to resume), and `entrypoint` (how it was opened, for the
/// label). `title` is a display snapshot — the live title is re-derived from
/// the persisted transcript when available.
struct PinnedSession: Codable, Equatable {
    let sessionId: String
    let cwd: String
    let entrypoint: String
    var title: String?
}

/// Persists pinned sessions in `UserDefaults` (JSON under one key), mirroring
/// the app's existing defaults-only convention. Methods take a `UserDefaults`
/// so they're unit-testable against a throwaway suite.
enum PinnedStore {
    static let key = "pinnedSessions"

    static func all(_ defaults: UserDefaults = .standard) -> [PinnedSession] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return decode(data)
    }

    static func isPinned(_ sessionId: String, _ defaults: UserDefaults = .standard) -> Bool {
        all(defaults).contains { $0.sessionId == sessionId }
    }

    /// Append the pin if new; refresh its stored metadata if already pinned.
    /// Order is preserved (pins stay where they were first added).
    static func pin(_ session: PinnedSession, _ defaults: UserDefaults = .standard) {
        var items = all(defaults)
        if let idx = items.firstIndex(where: { $0.sessionId == session.sessionId }) {
            items[idx] = session
        } else {
            items.append(session)
        }
        save(items, defaults)
    }

    static func unpin(_ sessionId: String, _ defaults: UserDefaults = .standard) {
        save(all(defaults).filter { $0.sessionId != sessionId }, defaults)
    }

    // MARK: - Pure coding (testable)

    static func decode(_ data: Data) -> [PinnedSession] {
        (try? JSONDecoder().decode([PinnedSession].self, from: data)) ?? []
    }

    static func encode(_ items: [PinnedSession]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data()
    }

    private static func save(_ items: [PinnedSession], _ defaults: UserDefaults) {
        defaults.set(encode(items), forKey: key)
    }
}
