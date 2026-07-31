import Foundation

/// Drains the pending_memories queue into supermemory. Crash-safe: rows are
/// only deleted after a successful ingest; failures back off exponentially.
actor IngestWorker {
    private var running = false
    private var loopTask: Task<Void, Never>?
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    private var supermemory: SupermemoryClient {
        SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
    }

    private var llm: LLMClient {
        settings.llm
    }

    func start() {
        guard !running else { return }
        running = true
        loopTask = Task { await loop() }
    }

    /// One rich memory per app-session. The digest carries only NOVEL lines
    /// across the session's frames — content, not repeated UI chrome.
    private func ingestSession(_ s: Store.PendingSession) async {
        let frames = await Store.shared.frames(ids: s.frameIDs)
        guard let first = frames.first, let last = frames.last else {
            await Store.shared.deleteSession(id: s.id)
            return
        }

        var seenLines = Set<String>()
        var novel: [String] = []
        for frame in frames {
            for line in frame.ocrText.split(separator: "\n") {
                let norm = line.trimmingCharacters(in: .whitespaces).lowercased()
                guard norm.count > 3, !seenLines.contains(norm) else { continue }
                seenLines.insert(norm)
                novel.append(String(line))
            }
        }

        let minutes = max(1, Int(last.lastSeenAt.timeIntervalSince(first.capturedAt) / 60))
        let titles = Array(Set(frames.map(\.windowTitle).filter { !$0.isEmpty })).prefix(5)
        let urls = Array(Set(frames.compactMap(\.url))).prefix(5)
        let iso = ISO8601DateFormatter()

        var digest = "Session: \(first.appName) — ~\(minutes) min (\(iso.string(from: first.capturedAt)) → \(iso.string(from: last.lastSeenAt)))"
        if !titles.isEmpty { digest += "\nWindows: \(titles.joined(separator: " · "))" }
        if !urls.isEmpty { digest += "\nURLs: \(urls.joined(separator: " · "))" }
        digest += "\n\nOn-screen text (deduplicated, chronological):\n" + novel.joined(separator: "\n").prefix(6000)

        let enrichment: Enrichment
        if await llm.isUp(), !novel.isEmpty,
           let e = await EnrichmentService(llm: llm).enrichSession(digest: digest) {
            enrichment = e
        } else {
            enrichment = EnrichmentService.fallback(frame: first)
        }

        var content = enrichment.summary
        if let facts = enrichment.facts, !facts.isEmpty {
            content += "\n\n" + facts.joined(separator: "\n")
        }
        content += "\n\nApp: \(first.appName) · ~\(minutes) min session · \(iso.string(from: first.capturedAt))"
        if let url = urls.first { content += "\n\(url)" }

        var metadata: [String: Any] = [
            "source": "screen-capture",
            "ref": "clem-session-\(first.id ?? 0)",
            "app": first.appBundleID,
            "app_name": first.appName,
            "category": enrichment.category,
            "tags": enrichment.tags.joined(separator: ","),
            "captured_at": iso.string(from: first.capturedAt),
            "day": String(iso.string(from: first.capturedAt).prefix(10)),
            "duration_min": minutes,
            "frame_count": frames.count,
        ]
        if !first.windowTitle.isEmpty { metadata["window_title"] = String(first.windowTitle.prefix(200)) }
        if let url = urls.first { metadata["url"] = String(url.prefix(500)) }
        if let thumb = frames.first(where: { $0.thumbPath != nil })?.thumbPath { metadata["thumb"] = thumb }

        do {
            let docID = try await supermemory.addDocument(
                content: content,
                containerTag: settings.containerTag,
                metadata: metadata
            )
            for frame in frames {
                if let id = frame.id { await Store.shared.markIngested(frameID: id, docID: docID) }
            }
            await Store.shared.deleteSession(id: s.id)
        } catch {
            await Store.shared.bumpSessionAttempts(id: s.id)
        }
    }

    func stopWorker() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    private func loop() async {
        while running, !Task.isCancelled {
            let drained = await drainOnce()
            do {
                try await Task.sleep(nanoseconds: UInt64((drained ? 2 : 20) * 1_000_000_000))
            } catch {
                break
            }
        }
        running = false
    }

    /// Returns true if it processed something.
    private func drainOnce() async -> Bool {
        guard await supermemory.isUp() else { return false }
        let sessions = await Store.shared.dueSessions(limit: 2)
        for s in sessions {
            await ingestSession(s)
        }
        let batch = await Store.shared.duePending(limit: 3)
        guard !batch.isEmpty else { return !sessions.isEmpty }

        let llmUp = await llm.isUp()
        let enricher = EnrichmentService(llm: llm)

        for item in batch {
            guard let frame = await Store.shared.frame(id: item.frameID) else {
                await Store.shared.deletePending(id: item.id)
                continue
            }
            var header = "App: \(frame.appName)"
            if !frame.windowTitle.isEmpty { header += "\nWindow: \(frame.windowTitle)" }
            if let url = frame.url { header += "\nURL: \(url)" }
            header += "\nCaptured: \(ISO8601DateFormatter().string(from: frame.capturedAt))"

            let enrichment: Enrichment
            if llmUp, !frame.ocrText.isEmpty,
               let e = await enricher.enrich(ocrText: frame.ocrText, context: header) {
                enrichment = e
            } else {
                enrichment = EnrichmentService.fallback(frame: frame)
            }

            var content = enrichment.summary
            if let facts = enrichment.facts, !facts.isEmpty {
                content += "\n\n" + facts.joined(separator: "\n")
            }
            content += "\n\n" + header

            // Metadata values must be scalars (strings/numbers/bools).
            var metadata: [String: Any] = [
                "source": "screen-capture",
                "ref": "clem-frame-\(frame.id ?? 0)",
                "app": frame.appBundleID,
                "app_name": frame.appName,
                "category": enrichment.category,
                "tags": enrichment.tags.joined(separator: ","),
                "captured_at": ISO8601DateFormatter().string(from: frame.capturedAt),
                "day": String(ISO8601DateFormatter().string(from: frame.capturedAt).prefix(10)),
                "frame_id": frame.id ?? 0,
            ]
            if !frame.windowTitle.isEmpty { metadata["window_title"] = String(frame.windowTitle.prefix(200)) }
            if let url = frame.url { metadata["url"] = String(url.prefix(500)) }
            if let thumb = frame.thumbPath { metadata["thumb"] = thumb }

            do {
                let docID = try await supermemory.addDocument(
                    content: content,
                    containerTag: settings.containerTag,
                    metadata: metadata
                )
                if let frameID = frame.id {
                    await Store.shared.markIngested(frameID: frameID, docID: docID)
                }
                await Store.shared.deletePending(id: item.id)
            } catch {
                await Store.shared.bumpAttempts(pendingID: item.id)
            }
        }
        return true
    }
}
