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

/// A window of subscription usage (either the monthly dollar spend limit or a
/// Pro/Max rate-limit window), read from headroom's polled subscription cache.
struct SubscriptionUsage: Equatable {
    /// The monthly overage/spend limit (Enterprise / console "Your usage
    /// limits"), when enabled.
    struct SpendLimit: Equatable {
        var usedUSD: Double
        var limitUSD: Double
        var utilizationPct: Double
        var remainingUSD: Double { max(limitUSD - usedUSD, 0) }
    }
    /// A rate-limit window (Pro/Max): 5-hour session or 7-day weekly.
    struct RateWindow: Equatable {
        var used: Int
        var limit: Int
        var utilizationPct: Double
        var resetsAt: Date?
        var secondsToReset: Int?
    }

    var spendLimit: SpendLimit?
    var fiveHour: RateWindow?
    var sevenDay: RateWindow?
    var polledAt: Date?

    /// True when there's anything worth showing.
    var hasData: Bool {
        spendLimit != nil
            || (fiveHour?.limit ?? 0) > 0
            || (sevenDay?.limit ?? 0) > 0
    }
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

    // MARK: - Subscription usage limits

    private static var subscriptionPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/subscription_state.json")
    }

    /// Read headroom's polled subscription cache (the same figures the console's
    /// "Your usage limits" panel shows). Returns nil if headroom isn't caching
    /// it. Cheap file read — safe to call off the main thread on a poll.
    static func readSubscription() -> SubscriptionUsage? {
        guard let data = try? Data(contentsOf: subscriptionPath) else { return nil }
        return parseSubscription(data)
    }

    /// Pure decode of a `subscription_state.json` payload — unit-testable.
    static func parseSubscription(_ data: Data) -> SubscriptionUsage? {
        guard let file = try? JSONDecoder().decode(SubscriptionFile.self, from: data)
        else { return nil }
        let latest = file.latest

        var spend: SubscriptionUsage.SpendLimit?
        if let e = latest?.extra_usage, e.is_enabled == true,
           let limit = e.monthly_limit_usd, limit > 0 {
            spend = .init(usedUSD: e.used_credits_usd ?? 0,
                          limitUSD: limit,
                          utilizationPct: e.utilization_pct ?? 0)
        }

        let usage = SubscriptionUsage(
            spendLimit: spend,
            fiveHour: latest?.five_hour?.window,
            sevenDay: latest?.seven_day?.window,
            polledAt: latest?.polled_at.flatMap(Self.parseDate))
        return usage.hasData ? usage : nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }()
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

    // MARK: - `~/.headroom/subscription_state.json` shape (fields we use)

    private struct SubscriptionFile: Decodable {
        let latest: Latest?
        struct Latest: Decodable {
            let extra_usage: ExtraUsage?
            let five_hour: Window?
            let seven_day: Window?
            let polled_at: String?
        }
        struct ExtraUsage: Decodable {
            let is_enabled: Bool?
            let monthly_limit_usd: Double?
            let used_credits_usd: Double?
            let utilization_pct: Double?
        }
        struct Window: Decodable {
            let used: Int?
            let limit: Int?
            let utilization_pct: Double?
            let resets_at: String?
            let seconds_to_reset: Int?

            /// Convert to the display model, resolving the ISO reset timestamp.
            var window: SubscriptionUsage.RateWindow {
                .init(used: used ?? 0, limit: limit ?? 0,
                      utilizationPct: utilization_pct ?? 0,
                      resetsAt: resets_at.flatMap(HeadroomStore.parseDate),
                      secondsToReset: seconds_to_reset)
            }
        }
    }
}
