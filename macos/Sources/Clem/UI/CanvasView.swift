import AppKit
import SwiftUI

enum CanvasTool: String, CaseIterable {
    case select, pen, text, note, connect, erase
    var icon: String {
        switch self {
        case .select: return "arrow.up.left"
        case .pen: return "pencil.tip"
        case .text: return "character.cursor.ibeam"
        case .note: return "note.text"
        case .connect: return "point.topleft.down.to.point.bottomright.curvepath"
        case .erase: return "eraser"
        }
    }
    var tip: String {
        switch self {
        case .select: return "Select & move — drag cards, or drag empty space to pan"
        case .pen: return "Pen — draw freehand"
        case .text: return "Text — click anywhere to type"
        case .note: return "Note — click to drop a note card"
        case .connect: return "Connect — tap two cards to link them"
        case .erase: return "Eraser — tap a card or drawing to delete it"
        }
    }
}

@MainActor
final class CanvasVM: ObservableObject {
    @Published var doc = CanvasDoc()
    @Published var boards: [CanvasDoc] = []
    @Published var tool: CanvasTool = .select
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    @Published var selectedID: UUID?
    @Published var currentStroke: [CGPoint] = []
    @Published var connectFrom: UUID?
    @Published var showImport = false
    @Published var editRequestID: UUID?
    @Published var savedFlash = false
    private var history: [CanvasDoc] = []
    private var placeSeq = 0

    /// Grid placement so newly-added cards fan out instead of stacking.
    func nextPlacement() -> CGPoint {
        let i = placeSeq; placeSeq += 1
        let col = i % 4, row = (i / 4) % 4
        return CGPoint(x: Double(col) * 290 - 435, y: Double(row) * 210 - 200)
    }

    // warm accent palette (orange / amber) — matches the app theme
    let amber = "#F96F1D", green = "#FDA81D", rose = "#F96F1D", blue = "#FDA81D"

    func loadBoards() {
        boards = CanvasStore.list()
        if let first = boards.first {
            doc = first
        } else {
            doc = CanvasDoc(name: "My first canvas")
            persist()
            boards = [doc]
        }
    }

    func newBoard() {
        snapshot()
        doc = CanvasDoc(name: "Canvas \(boards.count + 1)")
        persist()
        boards = CanvasStore.list()
    }

    func switchTo(_ id: UUID) {
        if let b = boards.first(where: { $0.id == id }) {
            doc = b
            selectedID = nil
            connectFrom = nil
        }
    }

    func persist() {
        CanvasStore.save(doc)
        savedFlash = true
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); self.savedFlash = false }
    }

    func renameCurrent(_ name: String) {
        doc.name = name.isEmpty ? "Untitled" : name
        persist()
    }

    func snapshot() {
        history.append(doc)
        if history.count > 40 { history.removeFirst() }
    }

    func undo() {
        guard let prev = history.popLast() else { return }
        doc = prev
        persist()
    }

    // world/screen transform
    func worldToScreen(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + p.x * scale,
                y: size.height / 2 + offset.height + p.y * scale)
    }

    func screenToWorld(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - offset.width) / scale,
                y: (p.y - size.height / 2 - offset.height) / scale)
    }

    func addNote(at world: CGPoint) {
        snapshot()
        doc.items.append(CanvasItem(kind: .note, x: world.x, y: world.y, text: "New note", colorHex: amber))
        selectedID = doc.items.last?.id
        tool = .select
        persist()
    }

    func addText(at world: CGPoint) {
        snapshot()
        let item = CanvasItem(kind: .text, x: world.x, y: world.y, width: 220, height: 44, colorHex: amber)
        doc.items.append(item)
        selectedID = item.id
        editRequestID = item.id // open the editor so the user can type at once
        tool = .select
        persist()
    }

    /// Erase the stroke whose nearest point is within `tol` of a world point.
    func eraseStroke(near world: CGPoint, tol: Double = 14) {
        let t = tol / scale
        if let idx = doc.strokes.firstIndex(where: { s in
            s.points.contains { hypot($0.x - world.x, $0.y - world.y) < t }
        }) {
            snapshot()
            doc.strokes.remove(at: idx)
            persist()
        }
    }

    func addMemory(_ node: GraphNode) {
        snapshot()
        let label = SourceInfo.meta(for: node).label
        let accent: String
        switch node.kind {
        case "clem": accent = blue
        default: accent = [amber, green, rose].randomElement() ?? amber
        }
        let at = nextPlacement()
        doc.items.append(CanvasItem(
            kind: .memory, x: at.x, y: at.y, width: 260, height: 180,
            text: node.summary.isEmpty ? node.title : node.summary,
            title: label, memoryDocID: node.id, source: label,
            thumb: node.thumb, url: node.url, colorHex: accent
        ))
        selectedID = doc.items.last?.id
        persist()
    }

    /// Absolute placement — the view tracks the drag's origin and passes the
    /// resolved world position (no cumulative-translation drift).
    func setPosition(_ id: UUID, world: CGPoint) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        doc.items[i].x = world.x
        doc.items[i].y = world.y
    }

    func commitStroke() {
        guard currentStroke.count > 1 else { currentStroke = []; return }
        snapshot()
        doc.strokes.append(InkStroke(points: currentStroke, colorHex: amber, width: 2.5))
        currentStroke = []
        persist()
    }

    func tapItem(_ id: UUID, size: CGSize) {
        switch tool {
        case .erase:
            snapshot()
            doc.items.removeAll { $0.id == id }
            doc.connections.removeAll { $0.from == id || $0.to == id }
            persist()
        case .connect:
            if let from = connectFrom, from != id {
                snapshot()
                doc.connections.append(CanvasConnection(from: from, to: id))
                connectFrom = nil
                persist()
            } else {
                connectFrom = id
            }
        default:
            selectedID = id
        }
    }

    func binding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.doc.items.first(where: { $0.id == id })?.text ?? "" },
            set: { new in
                if let i = self.doc.items.firstIndex(where: { $0.id == id }) { self.doc.items[i].text = new }
            }
        )
    }
}

struct CanvasBoardView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = CanvasVM()
    @State private var dragStartOffset: CGSize?
    @State private var cardDrag: (id: UUID, origin: CGPoint)?
    @State private var editingID: UUID?

    private let bg = Color(red: 0.10, green: 0.095, blue: 0.088)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                canvasLayer(size: geo.size)
                itemsLayer(size: geo.size)
                toolbar
                topBar
                // Always-visible hint for the active tool.
                Text(vm.tool.tip)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.1)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
            .background(bg)
            .clipped() // keep cards/strokes inside the canvas — never spill into the sidebar
        }
        .preferredColorScheme(.dark)
        .onAppear { vm.loadBoards() }
        .onChange(of: vm.editRequestID) {
            if let id = vm.editRequestID { editingID = id; vm.editRequestID = nil }
        }
        .sheet(isPresented: $vm.showImport) {
            MemoryPickerSheet { node in
                vm.addMemory(node)
            } cancel: { vm.showImport = false }
            .environmentObject(engine)
        }
        .sheet(item: Binding(get: { editingID.map { IDBox(id: $0) } }, set: { editingID = $0?.id })) { box in
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit note").font(.headline)
                TextEditor(text: vm.binding(box.id)).frame(width: 360, height: 180)
                    .font(.body).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Done") { vm.persist(); editingID = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
    }

    struct IDBox: Identifiable { let id: UUID }

    // MARK: strokes + connections (Canvas)

    private func canvasLayer(size: CGSize) -> some View {
        Canvas { ctx, sz in
            // dotted grid
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(bg))
            let step: CGFloat = 40 * vm.scale
            if step > 12 {
                let dot = Color.white.opacity(0.05)
                var y = (vm.offset.height + sz.height / 2).truncatingRemainder(dividingBy: step)
                while y < sz.height {
                    var x = (vm.offset.width + sz.width / 2).truncatingRemainder(dividingBy: step)
                    while x < sz.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(dot))
                        x += step
                    }
                    y += step
                }
            }

            // connections (curved)
            for c in vm.doc.connections {
                guard let a = vm.doc.items.first(where: { $0.id == c.from }),
                      let b = vm.doc.items.first(where: { $0.id == c.to }) else { continue }
                let p1 = vm.worldToScreen(CGPoint(x: a.x, y: a.y), size: sz)
                let p2 = vm.worldToScreen(CGPoint(x: b.x, y: b.y), size: sz)
                var path = Path()
                path.move(to: p1)
                let midX = (p1.x + p2.x) / 2
                path.addCurve(to: p2, control1: CGPoint(x: midX, y: p1.y), control2: CGPoint(x: midX, y: p2.y))
                ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1.4)
            }

            // committed strokes
            for stroke in vm.doc.strokes {
                ctx.stroke(strokePath(stroke.points, size: sz), with: .color(Color(hex: stroke.colorHex)), style: StrokeStyle(lineWidth: stroke.width * vm.scale, lineCap: .round, lineJoin: .round))
            }
            // in-progress stroke
            if vm.currentStroke.count > 1 {
                ctx.stroke(strokePath(vm.currentStroke, size: sz), with: .color(Color(hex: vm.amber)), style: StrokeStyle(lineWidth: 2.5 * vm.scale, lineCap: .round, lineJoin: .round))
            }
        }
        .contentShape(Rectangle())
        .gesture(backgroundDrag(size: size))
        .gesture(MagnifyGesture().onChanged { v in
            vm.scale = min(max(v.magnification * vm.scale, 0.3), 3)
        })
        .onContinuousHover { phase in
            // Cursor reflects the active tool over the canvas.
            switch phase {
            case .active: toolCursor(vm.tool).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private func toolCursor(_ tool: CanvasTool) -> NSCursor {
        switch tool {
        case .select: return .openHand
        case .text: return .iBeam
        case .pen, .note, .connect, .erase: return .crosshair
        }
    }

    private func strokePath(_ pts: [CGPoint], size: CGSize) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: vm.worldToScreen(first, size: size))
        for p in pts.dropFirst() { path.addLine(to: vm.worldToScreen(p, size: size)) }
        return path
    }

    private func backgroundDrag(size: CGSize) -> some Gesture {
        // One gesture handles both drag and tap (a near-zero-move release),
        // so tap-to-place / tap-to-erase never get swallowed by a rival tap gesture.
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let moved = hypot(v.translation.width, v.translation.height)
                switch vm.tool {
                case .pen:
                    vm.currentStroke.append(vm.screenToWorld(v.location, size: size))
                default:
                    guard moved > 3 else { return } // let a tap stay a tap
                    if dragStartOffset == nil { dragStartOffset = vm.offset }
                    vm.offset = CGSize(width: (dragStartOffset?.width ?? 0) + v.translation.width,
                                       height: (dragStartOffset?.height ?? 0) + v.translation.height)
                }
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height)
                if vm.tool == .pen { vm.commitStroke(); dragStartOffset = nil; return }
                if moved < 4 { // a tap on empty canvas
                    let world = vm.screenToWorld(v.location, size: size)
                    switch vm.tool {
                    case .note: vm.addNote(at: world)
                    case .text: vm.addText(at: world)
                    case .erase: vm.eraseStroke(near: world)
                    default: vm.selectedID = nil; vm.connectFrom = nil
                    }
                }
                dragStartOffset = nil
            }
    }

    // MARK: cards

    private func itemsLayer(size: CGSize) -> some View {
        // A transparent, full-size ZStack. Each card is placed with .offset
        // (NOT .position, which makes every card greedily fill the parent and
        // steal all clicks). Empty space falls through to the canvas below.
        ZStack {
            ForEach(vm.doc.items) { item in
                positioned(item, size: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func positioned(_ item: CanvasItem, size: CGSize) -> some View {
        let offsetX = vm.offset.width + item.x * vm.scale
        let offsetY = vm.offset.height + item.y * vm.scale
        Group {
            if item.kind == .text {
                // Auto-height: the card grows to fit the whole text.
                cardView(item).frame(width: item.width, alignment: .topLeading)
            } else {
                cardView(item).frame(width: item.width, height: item.height)
            }
        }
        .scaleEffect(vm.scale)
        .offset(x: offsetX, y: offsetY)
        .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard vm.tool == .select else { return }
                            let moved = hypot(v.translation.width, v.translation.height)
                            guard moved > 3 else { return }
                            if cardDrag?.id != item.id { cardDrag = (item.id, CGPoint(x: item.x, y: item.y)) }
                            let origin = cardDrag?.origin ?? CGPoint(x: item.x, y: item.y)
                            vm.setPosition(item.id, world: CGPoint(
                                x: origin.x + v.translation.width / vm.scale,
                                y: origin.y + v.translation.height / vm.scale
                            ))
                        }
                        .onEnded { v in
                            let moved = hypot(v.translation.width, v.translation.height)
                            if moved < 4 { // tap on the card
                                switch vm.tool {
                                case .erase, .connect:
                                    vm.tapItem(item.id, size: size)
                                case .select:
                                    if item.kind == .text || item.kind == .note { editingID = item.id }
                                    else { vm.selectedID = item.id }
                                default: break
                                }
                            } else if vm.tool == .select, cardDrag != nil {
                                vm.persist()
                            }
                            cardDrag = nil
                        }
                )
        .onContinuousHover { phase in
            if case .active = phase { toolCursor(vm.tool).set() }
        }
        .allowsHitTesting(vm.tool == .select || vm.tool == .connect || vm.tool == .erase)
    }

    private func cardView(_ item: CanvasItem) -> some View {
        let accent = Color(hex: item.colorHex)
        let selected = vm.selectedID == item.id || vm.connectFrom == item.id
        return VStack(alignment: .leading, spacing: 6) {
            if item.kind == .memory {
                HStack(spacing: 6) {
                    if let icon = IconStore.shared.icon(label: item.source ?? "", domain: domain(item.url), bundleID: nil) {
                        Image(nsImage: icon).resizable().frame(width: 15, height: 15).clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(item.title).font(.caption.bold()).foregroundStyle(accent)
                    Spacer()
                }
                if let thumb = item.thumb, let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 70).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(item.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(4)
            } else if item.kind == .text {
                Text(item.text.isEmpty ? "Click to edit" : item.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(item.text.isEmpty ? 0.35 : 0.95))
                    .fixedSize(horizontal: false, vertical: true) // wrap + grow tall
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Text(item.text.isEmpty ? "Note" : item.text)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(item.kind == .text ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: item.kind == .text ? nil : .infinity, alignment: .topLeading)
        .background(
            Group {
                if item.kind == .text {
                    // Plain floating text — no card chrome (faint box only when selected).
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.06 : 0))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.14, green: 0.13, blue: 0.12).opacity(0.96))
                }
            }
        )
        .overlay(
            Group {
                if item.kind == .text {
                    RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(selected ? 0.8 : 0), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(selected ? 1 : 0.55), lineWidth: selected ? 2 : 1.2)
                }
            }
        )
    }

    private func domain(_ url: String?) -> String? {
        guard let url, let h = URL(string: url)?.host?.lowercased() else { return nil }
        return h.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: chrome

    private var toolbar: some View {
        VStack(spacing: 6) {
            ForEach(CanvasTool.allCases, id: \.self) { t in
                toolButton(t.icon, tip: t.tip, active: vm.tool == t) { vm.tool = t; vm.connectFrom = nil }
            }
            Divider().frame(width: 24).padding(.vertical, 3)
            toolButton("plus.rectangle.on.rectangle", tip: "Import a saved memory as a card", active: false) { vm.showImport = true }
            toolButton("arrow.uturn.backward", tip: "Undo", active: false) { vm.undo() }
            toolButton("minus.magnifyingglass", tip: "Zoom out", active: false) { vm.scale = max(0.3, vm.scale - 0.2) }
            toolButton("plus.magnifyingglass", tip: "Zoom in", active: false) { vm.scale = min(3, vm.scale + 0.2) }
        }
        .padding(6)
        .background(Color(red: 0.09, green: 0.085, blue: 0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
        .padding(.leading, 14).padding(.top, 70)
    }

    private func toolButton(_ icon: String, tip: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 34, height: 34)
                .background(active ? Color(hex: vm.amber).opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(active ? Color(hex: vm.amber) : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("CANVAS").font(Theme.ui(10, .semibold)).kerning(1.5).foregroundStyle(Theme.ink(0.4))

            Rectangle().fill(Theme.line).frame(width: 1, height: 16)

            Menu {
                ForEach(vm.boards) { b in Button(b.name) { vm.switchTo(b.id) } }
                Divider()
                Button("New canvas") { vm.newBoard() }
            } label: {
                HStack(spacing: 5) {
                    TextField("Canvas name", text: Binding(
                        get: { vm.doc.name }, set: { vm.renameCurrent($0) }
                    ))
                    .textFieldStyle(.plain).font(Theme.ui(13, .medium)).foregroundStyle(Theme.ink)
                    .fixedSize()
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Theme.ink(0.45))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            Text(vm.savedFlash ? "saving…" : "saved")
                .font(Theme.mono(10)).foregroundStyle(Theme.ink(0.35))

            Spacer()

            if vm.tool == .connect {
                Text(vm.connectFrom == nil ? "tap a card to start a link" : "tap the second card")
                    .font(Theme.ui(11)).foregroundStyle(Theme.accent)
            }
            Text("\(vm.doc.items.count) cards").font(Theme.mono(11)).foregroundStyle(Theme.ink(0.4))
            Button { vm.newBoard() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(Theme.ink(0.6)).help("New canvas")
        }
        .padding(.horizontal, 16).frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - memory picker

struct MemoryPickerSheet: View {
    @EnvironmentObject var engine: Engine
    let pick: (GraphNode) -> Void
    let cancel: () -> Void
    @State private var nodes: [GraphNode] = []
    @State private var loading = true
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Import a memory").font(.headline)
                Spacer()
                Button("Close") { cancel() }
            }
            TextField("Filter…", text: $query).textFieldStyle(.roundedBorder)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { node in
                            Button { pick(node) } label: {
                                HStack(spacing: 8) {
                                    if let thumb = node.thumb, let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 42, height: 42)
                                            .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.summary.isEmpty ? node.title : node.summary).font(.caption).lineLimit(2)
                                        Text(SourceInfo.meta(for: node).label).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 460, height: 400)
            }
        }
        .padding(18)
        .onAppear {
            let snap = GraphService.SettingsSnapshot(
                supermemoryURL: engine.settings.supermemoryURLValue,
                supermemoryKey: engine.settings.supermemoryKey,
                containerTag: engine.settings.containerTag
            )
            Task {
                // Deliberate saves + imports only — passive screen-monitoring
                // memories don't belong on the canvas.
                let mem = await GraphService.shared.nodesOnly(snap, scope: .saved)
                await MainActor.run { nodes = mem; loading = false }
            }
        }
    }

    private var filtered: [GraphNode] {
        guard !query.isEmpty else { return nodes }
        let q = query.lowercased()
        return nodes.filter { ($0.title + $0.summary + $0.app).lowercased().contains(q) }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self = Color(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}
