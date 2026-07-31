import AppKit
import Foundation

/// A mythological archetype the user's consumption maps to.
struct MythChar: Identifiable {
    let slug: String
    let name: String
    let mythology: String
    let represents: String
    let consumes: String
    var id: String { slug }

    func image() -> NSImage? {
        for ext in ["jpg", "png"] {
            if let url = Bundle.main.url(forResource: slug, withExtension: ext, subdirectory: "Characters"),
               let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}

enum CharacterService {
    static let all: [MythChar] = [
        .init(slug: "prometheus", name: "Prometheus", mythology: "Greek", represents: "Curiosity, rebellion, knowledge", consumes: "AI papers, philosophy, science, startups"),
        .init(slug: "athena", name: "Athena", mythology: "Greek", represents: "Wisdom, strategy", consumes: "Educational content, books, history"),
        .init(slug: "hermes", name: "Hermes", mythology: "Greek", represents: "Communication, exploration", consumes: "Podcasts, newsletters, Twitter, trends"),
        .init(slug: "apollo", name: "Apollo", mythology: "Greek", represents: "Art + logic", consumes: "Music, poetry, design, mathematics"),
        .init(slug: "dionysus", name: "Dionysus", mythology: "Greek", represents: "Emotion, creativity, chaos", consumes: "Films, music, nightlife, culture"),
        .init(slug: "odysseus", name: "Odysseus", mythology: "Greek", represents: "Problem solving", consumes: "Long-form learning, engineering, strategy"),
        .init(slug: "icarus", name: "Icarus", mythology: "Greek", represents: "Ambition", consumes: "Productivity, startups, hustle culture"),
        .init(slug: "sisyphus", name: "Sisyphus", mythology: "Greek", represents: "Persistence", consumes: "Self-improvement, consistency, discipline"),
        .init(slug: "anubis", name: "Anubis", mythology: "Egyptian", represents: "Reflection", consumes: "Psychology, death, philosophy"),
        .init(slug: "thoth", name: "Thoth", mythology: "Egyptian", represents: "Knowledge keeper", consumes: "Books, research papers, AI"),
        .init(slug: "loki", name: "Loki", mythology: "Norse", represents: "Trickster", consumes: "Memes, internet culture, unconventional thinking"),
        .init(slug: "odin", name: "Odin", mythology: "Norse", represents: "Wisdom through sacrifice", consumes: "Philosophy, leadership, strategy"),
        .init(slug: "thor", name: "Thor", mythology: "Norse", represents: "Action", consumes: "Fitness, sports, adventure"),
        .init(slug: "sunwukong", name: "Sun Wukong", mythology: "Chinese", represents: "Playful genius", consumes: "Hacker culture, experimentation"),
        .init(slug: "arjuna", name: "Arjuna", mythology: "Hindu epic", represents: "Focus", consumes: "Mastery, skill-building, discipline"),
        .init(slug: "krishna", name: "Krishna", mythology: "Hindu epic", represents: "Vision", consumes: "Leadership, philosophy, influence"),
    ]

    static func char(_ slug: String) -> MythChar? { all.first { $0.slug == slug } }

    // MARK: cache (per day)

    private static let charKey = "clemCharSlug"
    private static let reasonKey = "clemCharReason"
    private static let stampKey = "clemCharAt"

    static var cached: (char: MythChar, reason: String)? {
        guard let slug = UserDefaults.standard.string(forKey: charKey),
              let c = char(slug) else { return nil }
        return (c, UserDefaults.standard.string(forKey: reasonKey) ?? "")
    }
    static var generatedAt: Date? { UserDefaults.standard.object(forKey: stampKey) as? Date }

    private static func store(_ slug: String, _ reason: String) {
        UserDefaults.standard.set(slug, forKey: charKey)
        UserDefaults.standard.set(reason, forKey: reasonKey)
        UserDefaults.standard.set(Date(), forKey: stampKey)
    }

    struct Pick: Decodable { let character: String; let reason: String }

    /// Classify what the user is consuming today into one archetype + reason.
    static func classifyToday(settings: Settings, appTimes: [AppSpan]) async -> (char: MythChar, reason: String)? {
        let llm = settings.llm
        guard await llm.isUp() else { return cached }

        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let recents = await sm.recentDocuments(containerTags: settings.allMemoryTags(), limit: 40)

        var ctx = ""
        if !appTimes.isEmpty {
            ctx += "Screen time today: " + appTimes.prefix(10).map { "\($0.app) \(Int($0.seconds / 60))m" }.joined(separator: ", ") + "\n\n"
        }
        if !recents.isEmpty {
            ctx += "Consumed / saved today:\n"
            for r in recents.prefix(30) {
                let t = (r.summary.isEmpty ? r.title : r.summary).prefix(140)
                ctx += "- \(r.source): \(t)\(r.tags.isEmpty ? "" : " [\(r.tags)]")\n"
            }
        }
        guard !ctx.isEmpty else { return cached }

        let roster = all.map { "\($0.slug): \($0.name) (\($0.represents) — \($0.consumes))" }.joined(separator: "\n")
        let system = """
        You read what a person consumed today and cast them as ONE mythological archetype from this fixed roster:
        \(roster)

        Respond ONLY with JSON: {"character": "<slug from the roster>", "reason": "a SHORT phrase, MAX 6 words, naming the dominant thing they consumed today"}
        Examples of good reasons: "Deep in AI papers & code", "A day of films and music", "Chasing startup and productivity content".
        Pick the single best fit based on the DOMINANT theme of today's consumption. The reason must reference the actual content — not generic traits. Keep it to a few words.
        """
        guard let data = try? await llm.completeJSON(system: system, user: ctx, timeout: 60),
              let pick = try? JSONDecoder().decode(Pick.self, from: data),
              let c = char(pick.character.lowercased()) else { return cached }
        store(c.slug, pick.reason)
        return (c, pick.reason)
    }
}
