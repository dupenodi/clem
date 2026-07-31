import Foundation

/// Thin client for supermemory local (http://localhost:6767).
/// Shapes verified against a live v0.0.3 server:
///   POST /v3/documents      {content, containerTag, metadata} → {id, status}
///   POST /v4/search         {q, containerTag, limit, threshold} → {results: [...]}
/// Localhost requests are auto-authenticated; a bearer key is optional.
struct SupermemoryClient {
    var baseURL: URL
    var apiKey: String?

    struct SearchHit: Decodable {
        let id: String
        let memory: String?
        let similarity: Double?
        let metadata: [String: AnyJSON]?
        let updatedAt: String?
    }

    private struct SearchResponse: Decodable {
        let results: [SearchHit]
    }

    private struct AddResponse: Decodable {
        let id: String
        let status: String
    }

    private func request(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "supermemory", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "request failed"])
        }
        return data
    }

    func addDocument(content: String, containerTag: String, metadata: [String: Any]) async throws -> String {
        let data = try await request("v3/documents", body: [
            "content": content,
            "containerTag": containerTag,
            "metadata": metadata,
        ])
        return try JSONDecoder().decode(AddResponse.self, from: data).id
    }

    func search(_ q: String, containerTag: String, limit: Int = 8, threshold: Double = 0.25) async throws -> [SearchHit] {
        let data = try await request("v4/search", body: [
            "q": q,
            "containerTag": containerTag,
            "limit": limit,
            "threshold": threshold,
        ])
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    func searchAll(_ q: String, containerTags: [String], limit: Int = 8, threshold: Double = 0.25) async throws -> [SearchHit] {
        var merged: [SearchHit] = []
        var anySuccess = false
        var lastError: Error?
        for tag in Array(Set(containerTags)) {
            do {
                let hits = try await search(q, containerTag: tag, limit: limit, threshold: threshold)
                anySuccess = true
                merged.append(contentsOf: hits)
            } catch {
                lastError = error
            }
        }
        if !anySuccess, let lastError { throw lastError }
        return merged
            .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    /// Map metadata.ref → document id across containers (search results are
    /// memory-level; this recovers their parent documents).
    func refToDocID(containerTags: [String]) async -> [String: String] {
        var map: [String: String] = [:]
        var page = 1
        while true {
            guard let data = try? await request("v3/documents/list", body: [
                "containerTags": containerTags, "limit": 100, "page": page,
            ]), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for m in (obj["memories"] as? [[String: Any]]) ?? [] {
                if let id = m["id"] as? String,
                   let meta = m["metadata"] as? [String: Any],
                   let ref = meta["ref"] as? String {
                    map[ref] = id
                }
            }
            let pagination = obj["pagination"] as? [String: Any]
            let current = (pagination?["currentPage"] as? Int) ?? page
            let total = (pagination?["totalPages"] as? Int) ?? 1
            if current >= total { break }
            page = current + 1
        }
        return map
    }

    func documentContent(id: String) async -> String? {
        (await documentInfo(id: id))?.content
    }

    /// Everything the list endpoint knows about a doc — enough to render a
    /// card without `GET /v3/documents/{id}` (broken on engine 0.0.5).
    struct DocLite {
        let id: String
        let title: String
        let summary: String
        let meta: [String: String]
    }

    func listDocsLite(containerTags: [String]) async -> [DocLite] {
        var out: [DocLite] = []
        var page = 1
        while true {
            guard let data = try? await request("v3/documents/list", body: [
                "containerTags": containerTags, "limit": 100, "page": page,
            ]), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for m in (obj["memories"] as? [[String: Any]]) ?? [] {
                guard let id = m["id"] as? String, (m["status"] as? String) != "failed" else { continue }
                var meta: [String: String] = [:]
                for (k, v) in (m["metadata"] as? [String: Any]) ?? [:] { meta[k] = "\(v)" }
                out.append(DocLite(
                    id: id,
                    title: (m["title"] as? String) ?? "",
                    summary: (m["summary"] as? String) ?? "",
                    meta: meta
                ))
            }
            let pagination = obj["pagination"] as? [String: Any]
            let current = (pagination?["currentPage"] as? Int) ?? page
            let total = (pagination?["totalPages"] as? Int) ?? 1
            if current >= total { break }
            page = current + 1
        }
        return out
    }

    func documentInfo(id: String) async -> (content: String, meta: [String: String])? {
        var req = URLRequest(url: baseURL.appendingPathComponent("v3/documents/\(id)"))
        req.timeoutInterval = 10
        if let key = apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? String else { return nil }
        var meta: [String: String] = [:]
        for (k, v) in (obj["metadata"] as? [String: Any]) ?? [:] {
            meta[k] = "\(v)"
        }
        return (content, meta)
    }

    struct RecentDoc {
        var title: String
        var summary: String
        var tags: String
        var source: String
        var url: String?
        var when: String
    }

    /// Lightweight recent-memory list (title/summary/tags/source/when) for the
    /// Insights feed — most recent first, across the given containers.
    func recentDocuments(containerTags: [String], limit: Int = 50) async -> [RecentDoc] {
        guard let data = try? await request("v3/documents/list", body: [
            "containerTags": containerTags, "limit": limit, "page": 1,
            "sort": "createdAt", "order": "desc",
        ]), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((obj["memories"] as? [[String: Any]]) ?? []).compactMap { m in
            guard (m["status"] as? String) != "failed" else { return nil }
            let meta = m["metadata"] as? [String: Any] ?? [:]
            return RecentDoc(
                title: (m["title"] as? String) ?? "",
                summary: (m["summary"] as? String) ?? "",
                tags: (meta["tags"] as? String) ?? "",
                source: (meta["app_name"] as? String) ?? (meta["app"] as? String) ?? "note",
                url: meta["url"] as? String,
                when: (meta["captured_at"] as? String) ?? (m["createdAt"] as? String) ?? ""
            )
        }
    }

    func isUp() async -> Bool {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 500
    }
}

/// Minimal JSON value for decoding arbitrary metadata.
enum AnyJSON: Decodable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        self = .null
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
