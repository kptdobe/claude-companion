import Foundation

/// Savings reported by headroom.ai (https://github.com/headroomlabs-ai/headroom),
/// a local context-compression layer. Cost is the dollar value headroom
/// estimates it saved by shrinking prompts before they reach the model.
struct HeadroomSavings: Equatable {
    var tokensSavedToday = 0
    var costSavedToday = 0.0
    var tokensSaved30d = 0
    var costSaved30d = 0.0
    var lifetimeTokensSaved = 0
    var lifetimeCostSaved = 0.0
}

/// Detects the `headroom` CLI and reads its savings ledger via
/// `headroom savings --json`. GUI apps get a minimal PATH, so we probe the
/// known install locations directly rather than relying on `which`.
enum HeadroomStore {
    /// The install command shown in the first-run prompt (uv is headroom's
    /// recommended, isolated install path).
    static let installCommand = #"uv tool install --python 3.13 "headroom-ai[all]""#

    private static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/headroom",
            "/opt/homebrew/bin/headroom",
            "/usr/local/bin/headroom",
            "/usr/bin/headroom",
        ]
    }()

    /// Absolute path to the `headroom` binary, or nil if not installed.
    static func locate() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var isInstalled: Bool { locate() != nil }

    /// Run `headroom savings --json` and parse the today / last-30-day windows.
    /// Returns nil if headroom is missing or the call fails. Blocks — call it
    /// off the main thread.
    static func fetchSavings() -> HeadroomSavings? {
        guard let bin = locate() else { return nil }

        let process = Process()
        process.executableURL = bin
        process.arguments = ["savings", "--json", "--days", "30"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            return nil
        }
        return HeadroomSavings(
            tokensSavedToday: report.windows.today.tokens_saved,
            costSavedToday: report.windows.today.cost_usd,
            tokensSaved30d: report.windows.last_30_days.tokens_saved,
            costSaved30d: report.windows.last_30_days.cost_usd,
            lifetimeTokensSaved: report.lifetime.tokens_saved,
            lifetimeCostSaved: report.lifetime.cost_usd)
    }

    // MARK: - `headroom savings --json` shape (only the fields we use)

    private struct Report: Decodable {
        let lifetime: Window
        let windows: Windows
        struct Windows: Decodable {
            let today: Window
            let last_30_days: Window
        }
        struct Window: Decodable {
            let tokens_saved: Int
            let cost_usd: Double
        }
    }
}
