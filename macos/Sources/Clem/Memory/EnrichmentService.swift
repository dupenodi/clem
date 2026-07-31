import Foundation

struct Enrichment: Decodable {
    var summary: String
    var category: String
    var tags: [String]
    var facts: [String]?
}

/// Turns raw OCR into a compact, memory-agent-friendly document.
/// Learned the hard way: supermemory's local memory agent extracts nothing
/// from raw UI text (doc → 0 memories → marked failed → invisible to
/// search), so what we ingest is a summary + facts, not the OCR dump.
/// Enrichment must never block or lose data — on any failure we fall back
/// to a deterministic summary built from window context.
struct EnrichmentService {
    let llm: LLMClient
    static let categories = [
        "code", "terminal", "error", "article", "documentation",
        "chat/message", "email", "receipt/invoice", "design",
        "dashboard/metrics", "video", "other",
    ]

    func enrich(ocrText: String, context header: String) async -> Enrichment? {
        let system = """
        You describe one screen capture as the user's memory. Respond ONLY with JSON:
        {"summary": "1 sentence, first person (I was...), concrete and specific",
         "category": one of \(Self.categories),
         "tags": [3-8 lowercase keywords],
         "facts": [2-6 standalone factual sentences about what the screen showed — names, titles, numbers, errors. Only details literally present in the text; never invent.]}
        """
        let user = "\(header)\n\nOn-screen text:\n\(String(ocrText.prefix(3500)))"
        guard let data = try? await llm.completeJSON(system: system, user: user, timeout: 45) else { return nil }
        guard var e = try? JSONDecoder().decode(Enrichment.self, from: data) else { return nil }
        if !Self.categories.contains(e.category) { e.category = "other" }
        e.tags = Array(e.tags.prefix(8))
        return e
    }

    /// Session variant: a whole app-session's deduped screen text → one
    /// insightful memory. Facts must be CONTENT (who said what, topics,
    /// code, errors, numbers), never URL/title/timestamp trivia.
    func enrichSession(digest: String) async -> Enrichment? {
        let system = """
        You turn a session of the user's screen time into an insightful memory. You get the app, duration, window titles, URLs, and the deduplicated text that appeared on screen across the session (chronological).
        Respond ONLY with JSON:
        {"summary": "1-2 first-person sentences: what the user was actually DOING and about WHAT — the story of the session",
         "category": one of \(Self.categories),
         "tags": [3-8 lowercase keywords about the CONTENT],
         "facts": [3-8 standalone sentences capturing real substance: messages and who wrote them, topics read or discussed, names of people/projects, code/files/errors worked on, numbers, decisions, things watched or listened to.]}
        HARD RULES for facts:
        - FORBIDDEN: facts that merely restate a URL, window title, app name, or timestamp ("user accessed X", "the URL was Y", "time shown was Z") — that metadata is already stored separately.
        - Every fact must contain information a person would actually want to recall later.
        - Only details literally present in the text; never invent. If the screen text is too sparse for real insight, return fewer facts or an empty list.
        """
        guard let data = try? await llm.completeJSON(system: system, user: digest, timeout: 90) else { return nil }
        guard var e = try? JSONDecoder().decode(Enrichment.self, from: data) else { return nil }
        if !Self.categories.contains(e.category) { e.category = "other" }
        e.tags = Array(e.tags.prefix(8))
        return e
    }

    /// No-LLM fallback so ingestion continues when the model is unreachable.
    static func fallback(frame: FrameRecord) -> Enrichment {
        var summary = "I was using \(frame.appName)"
        if !frame.windowTitle.isEmpty { summary += " — \(frame.windowTitle)" }
        if let url = frame.url { summary += " (\(url))" }
        return Enrichment(summary: summary, category: "other", tags: [frame.appName.lowercased()], facts: nil)
    }
}
