import Foundation

struct Insight: Codable, Identifiable {
    var id = UUID()
    var title: String
    var body: String
    var kind: String // pattern | connection | blindspot | habit | suggestion

    var icon: String {
        switch kind {
        case "connection": return "link"
        case "blindspot": return "eye.trianglebadge.exclamationmark"
        case "habit": return "repeat"
        case "suggestion": return "sparkles"
        default: return "chart.line.uptrend.xyaxis" // pattern
        }
    }
}

/// Generates non-obvious insights from the user's recent memories + screen
/// time via the configured LLM. Results are cached (JSON + timestamp) so the
/// tab is instant and we don't re-spend tokens on every open.
enum InsightsService {
    private static let cacheKey = "clemInsights"
    private static let stampKey = "clemInsightsAt"

    static var cached: [Insight] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let list = try? JSONDecoder().decode([Insight].self, from: data) else { return [] }
        return list
    }
    static var generatedAt: Date? { UserDefaults.standard.object(forKey: stampKey) as? Date }

    private static func store(_ insights: [Insight]) {
        if let data = try? JSONEncoder().encode(insights) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: stampKey)
        }
    }

    struct Wrap: Decodable { let insights: [Gen] }
    struct Gen: Decodable { let title: String; let body: String; let kind: String }

    static func generate(settings: Settings, appTimes: [AppSpan]) async -> [Insight] {
        let llm = settings.llm
        guard await llm.isUp() else { return cached }

        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let recents = await sm.recentDocuments(
            containerTags: settings.allMemoryTags(), limit: 50
        )
        guard !recents.isEmpty || !appTimes.isEmpty else { return [] }

        let df = DateFormatter(); df.dateFormat = "EEEE d MMM, HH:mm"
        var ctx = "Today is \(df.string(from: Date())).\n\n"
        if !appTimes.isEmpty {
            let mins = appTimes.prefix(10).map { "\($0.app): \(Int($0.seconds / 60))m" }.joined(separator: ", ")
            ctx += "Screen time today — \(mins)\n\n"
        }
        ctx += "Recent memories (newest first):\n"
        for r in recents.prefix(40) {
            let when = r.when.prefix(16).replacingOccurrences(of: "T", with: " ")
            let text = (r.summary.isEmpty ? r.title : r.summary).prefix(160)
            let tags = r.tags.isEmpty ? "" : " #\(r.tags.replacingOccurrences(of: ",", with: " #"))"
            ctx += "- (\(when) · \(r.source)) \(text)\(tags)\n"
        }

        let system = """
        You are Clem's insight engine. From the user's recent saved memories and screen time, surface 4-6 NON-OBVIOUS insights they would find genuinely valuable — things they likely haven't noticed themselves.
        Respond ONLY with JSON: {"insights":[{"title": "punchy phrase, ≤ 8 words", "body": "1-2 sentences citing specifics from the data", "kind": one of "pattern"|"connection"|"blindspot"|"habit"|"suggestion"}]}
        Rules:
        - NEVER state the obvious ("you used Chrome", "you saved some articles"). Every insight must reveal a pattern, a connection between different saved items, a recurring theme building over time, a blind spot (saved but never returned to), a shift in what they're focused on, or one concrete, specific suggestion based on the data.
        - Be specific: name the actual topics/people/sources from the memories.
        - Warm, sharp, concise. No filler, no preamble.
        - If the data is too thin for real insight, return fewer items rather than padding.
        """
        guard let data = try? await llm.completeJSON(system: system, user: ctx, timeout: 90),
              let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { return cached }
        let insights = wrap.insights.map { Insight(title: $0.title, body: $0.body, kind: $0.kind) }
        if !insights.isEmpty { store(insights) }
        return insights
    }
}
