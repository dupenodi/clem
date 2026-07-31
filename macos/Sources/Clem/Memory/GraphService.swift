import Foundation
import GRDB

/// User-given names for graph nodes (memories whose auto-title is missing or
/// unhelpful). Stored locally, keyed by document id.
enum GraphNames {
    private static let key = "graphNodeNames"
    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    static func name(for id: String) -> String? {
        let n = all[id]
        return (n?.isEmpty ?? true) ? nil : n
    }
    static func set(_ id: String, _ name: String) {
        var d = all
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { d[id] = nil } else { d[id] = trimmed }
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct GraphNode: Identifiable, Hashable {
    let id: String
    let title: String
    let app: String
    let kind: String
    let thumb: String?
    let file: String?
    let url: String?
    let createdAt: String
    var tags: [String] = []
    var summary: String = ""
    var bundleID: String = ""
}

struct GraphEdge: Hashable {
    let a: String
    let b: String
    let weight: Double
}

/// Builds the memory graph: every document (deliberate + passive) is a node;
/// edges come from the engine's own semantic search. Per-doc neighbor lists
/// are cached in SQLite keyed by (docID, updatedAt) so only new or changed
/// documents cost a search.
actor GraphService {
    static let shared = GraphService()

    enum Scope: String, CaseIterable, Sendable {
        case saved = "Saved"
        case screen = "Screen"
        case all = "All"

        func tags(containerTag: String) -> [String] {
            switch self {
            case .saved: return [Settings.savedTag, ConnectorImport.tag]
            case .screen: return [containerTag]
            case .all: return Array(Set([Settings.savedTag, containerTag, ConnectorImport.tag]))
            }
        }
    }

    private var tags = Scope.saved.tags(containerTag: "clem")

    private func client(_ settings: SettingsSnapshot) -> SupermemoryClient {
        SupermemoryClient(baseURL: settings.supermemoryURL, apiKey: settings.supermemoryKey)
    }

    struct SettingsSnapshot: Sendable {
        var supermemoryURL: URL
        var supermemoryKey: String
        var containerTag: String
    }

    func build(_ settings: SettingsSnapshot, scope: Scope = .saved) async -> (nodes: [GraphNode], edges: [GraphEdge]) {
        let nodes = await nodesOnly(settings, scope: scope)
        let edges = await semanticEdges(settings, scope: scope)
        return (nodes, edges)
    }

    func nodesOnly(_ settings: SettingsSnapshot, scope: Scope = .saved) async -> [GraphNode] {
        tags = scope.tags(containerTag: settings.containerTag)
        return await listAllDocuments(settings).map { node(from: $0) }
    }

    func semanticEdges(_ settings: SettingsSnapshot, scope: Scope = .saved) async -> [GraphEdge] {
        tags = scope.tags(containerTag: settings.containerTag)
        let localTags = tags
        let docs = await listAllDocuments(settings)
        var byRef: [String: String] = [:]
        for d in docs { if let ref = d.metadata["ref"] as? String { byRef[ref] = d.id } }
        let jobs = docs.map { d in
            NeighborJob(
                id: d.id, updatedAt: d.updatedAt,
                query: [d.title, d.summary].filter { !$0.isEmpty }.joined(separator: " — ")
            )
        }

        var edgeSet: Set<GraphEdge> = []
        let maxConcurrent = 8
        var next = 0
        await withTaskGroup(of: (String, [Neighbor]).self) { group in
            func schedule(_ job: NeighborJob) {
                group.addTask {
                    let key = "\(job.id):\(job.updatedAt)"
                    if let cached = await Store.shared.cachedNeighbors(key: key) {
                        return (job.id, cached)
                    }
                    let found = await Self.neighbors(job: job, tags: localTags, byRef: byRef, settings: settings)
                    await Store.shared.cacheNeighbors(key: key, neighbors: found)
                    return (job.id, found)
                }
            }
            while next < jobs.count && next < maxConcurrent { schedule(jobs[next]); next += 1 }
            for await (docID, found) in group {
                for n in found where n.id != docID {
                    let (a, b) = docID < n.id ? (docID, n.id) : (n.id, docID)
                    edgeSet.insert(GraphEdge(a: a, b: b, weight: n.score))
                }
                if next < jobs.count { schedule(jobs[next]); next += 1 }
            }
        }
        return Array(edgeSet)
    }

    private func node(from d: Doc) -> GraphNode {
        GraphNode(
            id: d.id,
            title: GraphNames.name(for: d.id) ?? d.title,
            app: (d.metadata["app_name"] as? String) ?? (d.metadata["app"] as? String) ?? "note",
            kind: (d.metadata["source"] as? String) == "screen-capture" ? "clem" : "capture",
            thumb: d.metadata["thumb"] as? String,
            file: d.metadata["file"] as? String,
            url: d.metadata["url"] as? String,
            createdAt: (d.metadata["captured_at"] as? String) ?? d.createdAt,
            tags: ((d.metadata["tags"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            summary: d.summary,
            bundleID: (d.metadata["app"] as? String) ?? ""
        )
    }

    // MARK: internals

    /// Sendable unit of work for concurrent neighbour search (Doc isn't
    /// Sendable because of its [String: Any] metadata).
    struct NeighborJob: Sendable {
        let id: String
        let updatedAt: String
        let query: String
    }

    struct Doc {
        let id: String
        let title: String
        let summary: String
        let updatedAt: String
        let createdAt: String
        let metadata: [String: Any]
    }

    private func listAllDocuments(_ settings: SettingsSnapshot) async -> [Doc] {
        var docs: [Doc] = []
        var page = 1
        while true {
            guard let data = try? await Self.postJSON(
                settings, path: "v3/documents/list",
                body: ["containerTags": tags, "limit": 100, "page": page, "sort": "createdAt", "order": "desc"]
            ), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for m in (obj["memories"] as? [[String: Any]]) ?? [] {
                guard let id = m["id"] as? String, (m["status"] as? String) != "failed" else { continue }
                docs.append(Doc(
                    id: id,
                    title: (m["title"] as? String) ?? "Untitled",
                    summary: (m["summary"] as? String) ?? "",
                    updatedAt: (m["updatedAt"] as? String) ?? "",
                    createdAt: (m["createdAt"] as? String) ?? "",
                    metadata: (m["metadata"] as? [String: Any]) ?? [:]
                ))
            }
            let pagination = obj["pagination"] as? [String: Any]
            let current = (pagination?["currentPage"] as? Int) ?? page
            let total = (pagination?["totalPages"] as? Int) ?? 1
            if current >= total { break }
            page = current + 1
        }
        return docs
    }

    struct Neighbor: Codable {
        let id: String
        let score: Double
    }

    /// Nonisolated so many searches can run concurrently rather than serializing
    /// on the actor.
    nonisolated private static func neighbors(job: NeighborJob, tags: [String], byRef: [String: String], settings: SettingsSnapshot) async -> [Neighbor] {
        let query = job.query
        guard !query.isEmpty else { return [] }
        var found: [Neighbor] = []
        var seen = Set<String>()
        for tag in tags {
            guard let data = try? await postJSON(
                settings, path: "v4/search",
                body: ["q": String(query.prefix(350)), "containerTag": tag, "limit": 6, "threshold": 0.4]
            ), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for r in (obj["results"] as? [[String: Any]]) ?? [] {
                guard let meta = r["metadata"] as? [String: Any],
                      let ref = meta["ref"] as? String,
                      let docID = byRef[ref],
                      docID != job.id,
                      !seen.contains(docID) else { continue }
                seen.insert(docID)
                found.append(Neighbor(id: docID, score: (r["similarity"] as? Double) ?? 0.5))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(4))
    }

    nonisolated private static func postJSON(_ settings: SettingsSnapshot, path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: settings.supermemoryURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.supermemoryKey.isEmpty {
            req.setValue("Bearer \(settings.supermemoryKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
