import Foundation

/// One actionable thing Clem noticed you left open today.
struct LooseEnd: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var kind: String // commitment | question | todo

    var icon: String {
        switch kind {
        case "commitment": return "hand.raised"
        case "question": return "questionmark.bubble"
        default: return "checkmark.circle" // todo
        }
    }
    var label: String {
        switch kind {
        case "commitment": return "You said you'd"
        case "question": return "Waiting on you"
        default: return "To-do"
        }
    }
    /// Stable key so a dismissal survives regeneration (ids are fresh each run).
    var key: String { kind + "|" + text.lowercased().trimmingCharacters(in: .whitespaces) }
}

/// The auto-written recap of the user's day + the loose ends they left behind.
struct Briefing: Codable {
    var digest: String
    var highlights: [String]
    var looseEnds: [LooseEnd]
    var day: String
}

/// Turns today's captured/saved memories into a daily briefing: a short recap,
/// a few highlights, and the follow-ups the user left open. One LLM call,
/// cached per day so opening the tab is instant.
enum BriefingService {
    private static let cacheKey = "clemBriefing"
    private static let dismissedKey = "clemBriefingDismissed"

    static var cached: Briefing? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let b = try? JSONDecoder().decode(Briefing.self, from: data) else { return nil }
        return b
    }
    static var generatedAt: Date? { UserDefaults.standard.object(forKey: cacheKey + "At") as? Date }

    private static func store(_ b: Briefing) {
        if let data = try? JSONEncoder().encode(b) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheKey + "At")
        }
    }

    // Dismissed loose ends (by stable key), so completed follow-ups stay gone.
    static var dismissed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }
    static func dismiss(_ end: LooseEnd) {
        var d = dismissed; d.insert(end.key)
        UserDefaults.standard.set(Array(d), forKey: dismissedKey)
    }

    private static func today() -> String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

    struct Wrap: Decodable {
        let digest: String
        let highlights: [String]
        let looseEnds: [End]
        struct End: Decodable { let text: String; let kind: String }
    }

    static func generate(settings: Settings, appTimes: [AppSpan]) async -> Briefing? {
        let llm = settings.llm
        guard await llm.isUp() else { return cached }

        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        // Exclude bulk connector imports — this is about what you *did* today.
        let recents = await sm.recentDocuments(
            containerTags: settings.allMemoryTags(), limit: 80
        )
        let day = today()
        var todays = recents.filter { $0.when.prefix(10) == day.prefix(10) }
        // If today is quiet (early morning, a fresh day, monitoring just on),
        // brief the most recent day that actually has activity so the tab is
        // never uselessly empty when there's clearly something to recap.
        if todays.count < 3 {
            let days = recents.map { String($0.when.prefix(10)) }.filter { !$0.isEmpty }
            if let latest = days.max() {
                let fallback = recents.filter { $0.when.prefix(10) == latest }
                if fallback.count > todays.count { todays = fallback }
            }
        }
        guard !todays.isEmpty else { return cached }

        var ctx = ""
        if !appTimes.isEmpty {
            let mins = appTimes.prefix(10).map { "\($0.app): \(Int($0.seconds / 60))m" }.joined(separator: ", ")
            ctx += "Time on screen today — \(mins)\n\n"
        }
        ctx += "What appeared / was saved today (chronological, newest first):\n"
        for r in todays.prefix(60) {
            let when = r.when.prefix(16).replacingOccurrences(of: "T", with: " ").suffix(5)
            let text = (r.summary.isEmpty ? r.title : r.summary).prefix(200)
            ctx += "- (\(when) · \(r.source)) \(text)\n"
        }

        let system = """
        You are Clem — the cofounder of the user's life — writing their end-of-day briefing from what actually appeared on their screen and what they saved today. Speak to them directly as "you": warm, sharp and invested, like a partner who has their back.
        Respond ONLY with JSON:
        {"digest": "2-4 warm, specific sentences recapping what the user actually worked on and cared about today — the story of their day, naming real projects/topics/people from the data",
         "highlights": ["3-5 short bullet phrases of the most notable things (a decision, something learned, a task progressed) — concrete, not generic"],
         "looseEnds": [{"text": "the follow-up in second person, naming the real person/app/topic it refers to", "kind": "commitment"|"question"|"todo"}]}
        Rules for looseEnds — extract ONLY things genuinely left open, quoting the actual evidence:
        - "commitment": something the user themselves said they would do (look for phrasing like "I'll send", "let me get back to you", "I'll fix").
        - "question": a question directed AT the user (in chat/email) that looks unanswered.
        - "todo": an explicit task/TODO visible on screen, or an obvious next step they were mid-way through.
        HARD RULES:
        - Ground EVERY loose end in the data above — reference the specific person, app, file or topic that actually appears. If you can't point to real evidence for it, DO NOT include it.
        - Do NOT copy any wording from this prompt. The formats above are structural only — never output placeholder names or example sentences.
        - If nothing is genuinely open, return an empty looseEnds array. No filler, no preamble, no invented people.
        """
        guard let data = try? await llm.completeJSON(system: system, user: ctx, timeout: 90),
              let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { return cached }

        let ends = wrap.looseEnds
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { LooseEnd(text: $0.text, kind: $0.kind) }
        let briefing = Briefing(
            digest: wrap.digest,
            highlights: wrap.highlights.filter { !$0.isEmpty },
            looseEnds: ends,
            day: day
        )
        store(briefing)
        return briefing
    }
}
