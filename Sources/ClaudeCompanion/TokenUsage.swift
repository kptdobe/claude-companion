import Foundation

/// A running tally of billed tokens and their dollar cost, summed across one or
/// more assistant messages.
struct UsageTotals: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var cost = 0.0

    /// All billed tokens — what the UI shows as "N tokens".
    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var isEmpty: Bool { totalTokens == 0 && cost == 0 }

    static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
            cost: a.cost + b.cost)
    }

    static func += (a: inout UsageTotals, b: UsageTotals) { a = a + b }
}

/// Per-model list price in USD per 1M tokens. Cache writes are priced by TTL:
/// the 5-minute tier is 1.25× base input, the 1-hour tier is 2× base input.
///
/// These are approximate published Anthropic rates and are only used for a
/// local, informational cost estimate — Claude Code itself is the source of
/// truth for billing. Unknown *paid* models fall back to Sonnet; Claude Code's
/// internal `<synthetic>` turns are free.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    static let opus = ModelPricing(
        input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5)
    static let sonnet = ModelPricing(
        input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)
    static let haiku = ModelPricing(
        input: 0.80, output: 4, cacheWrite5m: 1.00, cacheWrite1h: 1.60, cacheRead: 0.08)
    static let zero = ModelPricing(
        input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)

    static func forModel(_ model: String?) -> ModelPricing {
        guard let m = model?.lowercased(), !m.isEmpty else { return sonnet }
        if m.contains("synthetic") { return zero }
        if m.contains("opus") { return opus }
        if m.contains("haiku") { return haiku }
        if m.contains("sonnet") { return sonnet }
        // Fable and any future/unknown paid model: mid-tier estimate.
        return sonnet
    }
}

/// Parses per-message token usage out of a Claude Code JSONL transcript.
///
/// Each assistant line looks like:
///   {"type":"assistant","timestamp":"…","message":{"id":"…","model":"…",
///    "usage":{"input_tokens":…,"output_tokens":…,"cache_read_input_tokens":…,
///             "cache_creation":{"ephemeral_5m_input_tokens":…,
///                               "ephemeral_1h_input_tokens":…}}}}
enum UsageParser {
    /// One assistant message's contribution, with cost already priced in.
    struct ParsedUsage: Equatable {
        /// `message.id` — used to dedupe streamed/retried duplicates.
        let id: String?
        let timestamp: Date?
        let totals: UsageTotals
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a single transcript line. Returns nil for lines with no usage.
    static func parseLine<S: StringProtocol>(_ line: S) -> ParsedUsage? {
        // Cheap prefilter: skip the vast majority of lines (users, tool results).
        guard line.contains("\"usage\"") else { return nil }
        guard let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = message["model"] as? String
        let price = ModelPricing.forModel(model)

        let input = intVal(usage["input_tokens"])
        let output = intVal(usage["output_tokens"])
        let cacheRead = intVal(usage["cache_read_input_tokens"])

        // Cache writes: prefer the per-TTL breakdown; fall back to the flat
        // count priced at the 5-minute tier.
        var write5m = 0, write1h = 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            write5m = intVal(cc["ephemeral_5m_input_tokens"])
            write1h = intVal(cc["ephemeral_1h_input_tokens"])
        } else {
            write5m = intVal(usage["cache_creation_input_tokens"])
        }
        let cacheWrite = write5m + write1h

        let cost = Double(input) / 1_000_000 * price.input
            + Double(output) / 1_000_000 * price.output
            + Double(cacheRead) / 1_000_000 * price.cacheRead
            + Double(write5m) / 1_000_000 * price.cacheWrite5m
            + Double(write1h) / 1_000_000 * price.cacheWrite1h

        let totals = UsageTotals(
            inputTokens: input, outputTokens: output,
            cacheWriteTokens: cacheWrite, cacheReadTokens: cacheRead, cost: cost)

        let ts = (obj["timestamp"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFraction.date(from: $0)
        }
        return ParsedUsage(id: message["id"] as? String, timestamp: ts, totals: totals)
    }

    /// JSON numbers may decode as Int, Double, or NSNumber — normalize to Int.
    private static func intVal(_ any: Any?) -> Int {
        switch any {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }
}

/// Human-friendly formatting for tokens and dollars.
enum UsageFormat {
    /// 42 → "42", 15_234 → "15K", 1_240_000 → "1.2M", 218_000_000 → "218M".
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<1_000_000:
            return scaled(v / 1_000, suffix: "K")
        case ..<1_000_000_000:
            return scaled(v / 1_000_000, suffix: "M")
        default:
            return scaled(v / 1_000_000_000, suffix: "B")
        }
    }

    /// One decimal below 10 (1.2M), whole numbers above (218M).
    private static func scaled(_ v: Double, suffix: String) -> String {
        v < 10
            ? String(format: "%.1f%@", v, suffix)
            : String(format: "%.0f%@", v, suffix)
    }

    /// Dollars with two decimals: 0.0384 → "$0.04", 254.238 → "$254.24".
    static func cost(_ c: Double) -> String {
        String(format: "$%.2f", c)
    }

    /// "$0.12 · 340K tokens" — the compact one-liner used throughout the menu.
    static func costAndTokens(_ u: UsageTotals) -> String {
        "\(cost(u.cost)) · \(tokens(u.totalTokens)) tokens"
    }
}
