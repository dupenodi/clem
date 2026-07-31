import CoreGraphics
import Foundation

/// A freehand pen stroke, stored in canvas (world) coordinates.
struct InkStroke: Codable, Identifiable {
    var id = UUID()
    var points: [CGPoint]
    var colorHex: String
    var width: Double
}

/// A card on the canvas — either an imported memory or a free note.
struct CanvasItem: Codable, Identifiable {
    enum Kind: String, Codable { case memory, note, text }
    var id = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double = 240
    var height: Double = 150
    var text: String = ""
    var title: String = ""
    var memoryDocID: String?
    var source: String?
    var thumb: String?
    var url: String?
    var colorHex: String = "#D9A83E"
}

struct CanvasConnection: Codable, Identifiable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

/// One board.
struct CanvasDoc: Codable, Identifiable {
    var id = UUID()
    var name: String = "Untitled"
    var items: [CanvasItem] = []
    var strokes: [InkStroke] = []
    var connections: [CanvasConnection] = []
    var updatedAt = Date(timeIntervalSince1970: 0)
}

/// JSON-file store: one file per board under Application Support/Clem/canvases.
enum CanvasStore {
    static var dir: URL {
        let d = Store.dataDir.appendingPathComponent("canvases", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func list() -> [CanvasDoc] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(CanvasDoc.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ doc: CanvasDoc) {
        var d = doc
        d.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(d) else { return }
        try? data.write(to: dir.appendingPathComponent("\(d.id.uuidString).json"))
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
    }
}
