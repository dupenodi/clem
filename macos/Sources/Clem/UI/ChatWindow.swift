import AppKit
import SwiftUI

/// Minimal quick-ask widget summoned with the global hotkey — Spotlight-like,
/// from anywhere. The full experience lives in the main app window.
@MainActor
final class ChatPanelController: NSObject, NSWindowDelegate {
    static let shared = ChatPanelController()
    private var panel: NSPanel?

    func toggle(engine: Engine) {
        if let p = panel {
            if p.isVisible {
                p.orderOut(nil)
                return
            }
            p.contentView = NSHostingView(
                rootView: QuickAskView(close: { [weak self] in self?.panel?.orderOut(nil) })
                    .environmentObject(engine)
            )
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(Theme.bg)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: QuickAskView(close: { [weak self] in self?.panel?.orderOut(nil) })
                .environmentObject(engine)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// Compact ask bar: question in, streamed answer out, "Open Clem" for more.
struct QuickAskView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool
    let close: () -> Void

    // Synced to the app's design language (Theme) — no bespoke palette here.
    private let bg = Theme.bg
    private let card = Theme.surface
    private let amber = Theme.gold
    private let cream = Theme.ink

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle").foregroundStyle(amber)
                TextField("Ask me anything…", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(17))
                    .foregroundStyle(cream)
                    .tint(Theme.accent)
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
                Menu {
                    Picker("Scope", selection: $vm.scope) {
                        Text("Saved").tag(GraphService.Scope.saved)
                        Text("Screen").tag(GraphService.Scope.screen)
                        Text("All").tag(GraphService.Scope.all)
                    }
                } label: {
                    Text(vm.scope.rawValue).font(.caption2).foregroundStyle(cream.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 58)
            }
            .padding(13)
            .background(card, in: RoundedRectangle(cornerRadius: 12))
            .grain(cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let turn = vm.turns.last {
                if vm.busy, turn.answer.isEmpty {
                    GraphLoader()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !turn.answer.isEmpty {
                            Text(turn.answer)
                                .foregroundStyle(cream.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    if !turn.citations.isEmpty {
                        Text("\(turn.citations.count) memories used").font(.caption2).foregroundStyle(cream.opacity(0.4))
                    }
                    Spacer()
                    Button("Open Clem ↗") {
                        close()
                        MainWindowController.shared.show(engine: engine)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundStyle(amber)
                }
            } else {
                Spacer()
                Text("Enter to ask · Esc to dismiss")
                    .font(.caption2).foregroundStyle(cream.opacity(0.3))
            }
        }
        .padding(14)
        .frame(width: 620, height: 380)
        .background(bg)
        .grain()
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }
}

struct Citation: Identifiable {
    let id: String
    let index: Int
    let text: String
    let app: String?
    let when: String?
    let url: String?
}

struct ChatTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: String = ""
    var citations: [Citation] = []
}

struct Resurfaced {
    let source: String // "a tweet from X" style label
    let sourceLabel: String
    let domain: String?
    let bundleID: String?
    let when: String // relative ("last month")
    let text: String
    let url: String?
    var title: String? // page/video title when we have one — the card headline
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var question = ""
    @Published var turns: [ChatTurn] = []
    @Published var busy = false
    @Published var error: String?
    @Published var scope: GraphService.Scope = .all
    @Published var resurfaced: Resurfaced?
    @Published var upNext: Resurfaced? // the card visibly waiting underneath
    @Published var resurfaceExhausted = false
    @Published var resurfaceNumber = 0 // 1-based position in the deck
    @Published var resurfaceTotal = 0
    private var resurfacePool: [SupermemoryClient.DocLite] = []
    private var resurfaceIndex = 0

    func loadResurface(engine: Engine) {
        let sm = SupermemoryClient(baseURL: engine.settings.supermemoryURLValue, apiKey: engine.settings.supermemoryKey)
        Task {
            if resurfacePool.isEmpty {
                resurfacePool = await sm.listDocsLite(containerTags: [Settings.savedTag, ConnectorImport.tag]).shuffled()
                resurfaceIndex = 0
            }
            guard !resurfacePool.isEmpty else { return }
            resurfaceTotal = resurfacePool.count
            // No looping: once every saved memory has resurfaced, say so and close.
            if resurfaceIndex >= resurfacePool.count {
                self.resurfaced = nil
                self.resurfaceExhausted = true
                self.resurfacePool = []
                self.resurfaceIndex = 0
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    self.resurfaceExhausted = false
                }
                return
            }
            let item = resurfacePool[resurfaceIndex]
            resurfaceIndex += 1
            resurfaceNumber = resurfaceIndex

            // Full content when the engine serves it; the list row is the
            // fallback (GET /v3/documents/{id} 500s on engine 0.0.5).
            var meta = item.meta
            var body: String
            if let (content, fullMeta) = await sm.documentInfo(id: item.id) {
                meta = fullMeta
                body = content.components(separatedBy: "\n\n(Saved from").first ?? content
            } else {
                body = item.summary.isEmpty ? item.title : item.summary
            }
            self.resurfaced = Self.makeResurfaced(body: body, meta: meta)
            // Peek the card underneath, so the deck never shows a blank face.
            self.upNext = peekNext()
        }
    }

    /// The next card's face, built cheaply from the list row (no extra fetch).
    private func peekNext() -> Resurfaced? {
        guard resurfaceIndex < resurfacePool.count else { return nil }
        let item = resurfacePool[resurfaceIndex]
        let body = item.summary.isEmpty ? item.title : item.summary
        return Self.makeResurfaced(body: body, meta: item.meta)
    }

    private static func makeResurfaced(body: String, meta: [String: String]) -> Resurfaced {
        var domain: String?
        var label = meta["app_name"] ?? "somewhere"
        if let url = meta["url"], let host = URL(string: url)?.host?.lowercased() {
            domain = host.replacingOccurrences(of: "www.", with: "")
            if domain!.contains("x.com") || domain!.contains("twitter") { label = "X" }
            else if let d = domain { label = d.components(separatedBy: ".").dropLast().last?.capitalized ?? d }
        }
        let kind = meta["kind"] == "region-ocr" ? "a snippet" : (domain != nil ? "this" : "a note")

        var when = ""
        if let iso = meta["captured_at"], let date = ISO8601DateFormatter().date(from: iso) {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            when = f.localizedString(for: date, relativeTo: Date())
        }
        return Resurfaced(
            source: "You saved \(kind) from \(label) \(when)",
            sourceLabel: label,
            domain: domain,
            bundleID: meta["app"],
            when: when,
            text: String(body.prefix(400)),
            url: meta["url"],
            title: meta["page_title"]
        )
    }

    func ask(engine: Engine) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true
        error = nil
        question = ""
        turns.append(ChatTurn(question: q))
        let turnIndex = turns.count - 1

        let settings = engine.settings
        let sm = SupermemoryClient(baseURL: settings.supermemoryURLValue, apiKey: settings.supermemoryKey)
        let llm = settings.llm
        let tags = scope.tags(containerTag: settings.containerTag)
        Task {
            do {
                var hits = try await sm.searchAll(q, containerTags: tags, limit: 14, threshold: 0.2)
                if let timeScope = TimeScope.parse(q) {
                    let scoped = hits.filter { timeScope.contains(iso: $0.metadata?["captured_at"]?.stringValue) }
                    if !scoped.isEmpty { hits = scoped }
                }
                var unique: [SupermemoryClient.SearchHit] = []
                for h in hits {
                    let text = h.memory ?? ""
                    if !unique.contains(where: { TextSimilarity.jaccard($0.memory ?? "", text) > 0.8 }) {
                        unique.append(h)
                    }
                }
                let top = Array(unique.prefix(8))
                let citations = top.enumerated().map { i, h in
                    Citation(
                        id: h.id,
                        index: i + 1,
                        text: h.memory ?? "",
                        app: h.metadata?["app_name"]?.stringValue,
                        when: h.metadata?["captured_at"]?.stringValue,
                        url: h.metadata?["url"]?.stringValue
                    )
                }
                self.turns[turnIndex].citations = citations
                guard !top.isEmpty else {
                    self.turns[turnIndex].answer = "I haven't seen anything related to that on your screen yet."
                    self.busy = false
                    return
                }

                let df = DateFormatter()
                df.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
                var context = citations
                    .map { c in
                        let when = (c.when ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
                        return "[\(c.index)] \(when) · \(c.app ?? "") — \(c.text)"
                    }
                    .joined(separator: "\n")

                // Resolve the top hits to their parent documents and include
                // the FULL saved content — facts alone can't answer "show me
                // what I saved".
                let refMap = await sm.refToDocID(containerTags: tags)
                var seenRefs = Set<String>()
                var fullDocs: [String] = []
                for h in top {
                    guard fullDocs.count < 3,
                          let ref = h.metadata?["ref"]?.stringValue,
                          !seenRefs.contains(ref),
                          let docID = refMap[ref] else { continue }
                    seenRefs.insert(ref)
                    if let content = await sm.documentContent(id: docID) {
                        let title = h.metadata?["page_title"]?.stringValue
                            ?? h.metadata?["window_title"]?.stringValue
                            ?? h.metadata?["app_name"]?.stringValue ?? "saved item"
                        let when = (h.metadata?["captured_at"]?.stringValue ?? "").prefix(10)
                        fullDocs.append("=== Saved item: \(title) (\(when)) ===\n\(String(content.prefix(2500)))")
                    }
                }
                if !fullDocs.isEmpty {
                    let docsBlock: String = fullDocs.joined(separator: "\n\n")
                    context = "FULL SAVED DOCUMENTS:\n\n\(docsBlock)\n\nRelated memory facts:\n\(context)"
                }

                var messages: [[String: String]] = [
                    ["role": "system", "content": """
                    You are Clem — the cofounder of the user's life: a sharp, loyal partner with perfect memory of everything they've seen and saved, invested in helping them win. Right now it is \(df.string(from: Date())). The retrieved memories below (each tagged [n] with time + app) are your CONTEXT, not your answer.
                    How to respond:
                    - Lead with the insight, not the inventory. The user can already see their memories in the app — never narrate "you saved X, you saved Y" or "these are your memories." Instead, answer what they actually asked and add something they'd value: connect the dots across memories, surface a pattern or tension, draw the implication, or give a genuinely useful take.
                    - Write like a smart friend who remembers everything: natural, specific, confident. No preamble, no "based on your memories", no bullet-point dumps unless asked.
                    - Ground every claim in the memories and cite inline like [2]; turn timestamps into human phrasing ("this morning", "a couple weeks back"). Never invent facts not present.
                    - Only when the user explicitly says show/read/what-did-I-save should you reproduce saved text verbatim from FULL SAVED DOCUMENTS (as a quote). Otherwise, synthesize.
                    - If the memories don't actually answer it, say so in one honest sentence and suggest what might.
                    - Keep it tight: 2-5 sentences unless depth is requested.
                    """],
                ]
                // Short conversation history keeps follow-ups coherent.
                for t in turns.suffix(4).dropLast() {
                    messages.append(["role": "user", "content": t.question])
                    messages.append(["role": "assistant", "content": t.answer])
                }
                messages.append(["role": "user", "content": "Retrieved memories:\n\(context)\n\nQuestion: \(q)"])

                for try await token in llm.streamChat(messages: messages) {
                    self.turns[turnIndex].answer += token
                }
            } catch {
                self.error = "Memory engine unavailable: \(error.localizedDescription)"
                if self.turns[turnIndex].answer.isEmpty {
                    self.turns[turnIndex].answer = "I couldn't reach the memory engine. Check Settings → Services."
                }
            }
            self.busy = false
        }
    }
}

enum ClemArt {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clem", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static let deck: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clem-nobg", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct ChatView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = ChatViewModel()
    @FocusState private var focused: Bool
    @State private var bgImage: NSImage? = HomeBackground.image
    @State private var timeExpanded = false
    @State private var insights: [Insight] = InsightsService.cached
    @State private var insightIdx = 0
    @ObservedObject private var iconStore = IconStore.shared
    // Resurface-deck swipe state: the card tracks the drag, then flies off.
    @State private var cardDrag: CGSize = .zero
    @State private var cardFlying = false

    private let card = Theme.surface
    private let amber = Theme.gold
    private let cream = Theme.ink

    /// Starter prompts so a new user sees what Clem can actually do — the text
    /// shown is exactly the question it fires.
    private let suggestions = [
        "Help me find something I saw today.",
        "What should I consume next?",
        "Summarize everything I learned today.",
    ]

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 5..<12: return "Good morning"; case 12..<17: return "Good afternoon"; case 17..<22: return "Good evening"; default: return "Still up" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if vm.turns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(greeting.uppercased()), \(firstName.uppercased())")
                        .font(Theme.ui(11, .medium))
                        .kerning(1.5)
                        .foregroundStyle(Theme.ink(0.4))
                    (
                        Text("Everything you've seen, remembered. ").foregroundColor(cream)
                            + Text("Ask me anything.").foregroundColor(Theme.accent)
                    )
                    .font(Theme.display(26, .medium))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 48)
                .padding(.bottom, 8)
            }

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.ink(0.45))
                TextField("Ask me anything you've seen…", text: $vm.question)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(16))
                    .foregroundStyle(cream)
                    .tint(Theme.accent) // caret + selection in the app's accent, not system blue
                    .focused($focused)
                    .onSubmit { vm.ask(engine: engine) }
                if vm.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 15)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.ink(0.28) : Theme.line))

            if vm.turns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TRY ASKING").font(Theme.ui(9, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.35))
                    HStack(spacing: 8) {
                        ForEach(suggestions.indices, id: \.self) { i in
                            suggestionPill(suggestions[i])
                        }
                    }
                }
                .padding(.top, 2)
            }

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(vm.turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(turn.question)
                                    .font(Theme.ui(15, .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(Theme.gold.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                                if !turn.answer.isEmpty {
                                    Text(turn.answer).textSelection(.enabled)
                                        .font(Theme.ui(15))
                                        .foregroundStyle(Theme.ink(0.92))
                                        .lineSpacing(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if vm.busy, turn.answer.isEmpty, turn.id == vm.turns.last?.id {
                                    GraphLoader()
                                }
                                if !turn.citations.isEmpty {
                                    DisclosureGroup("\(turn.citations.count) memories used") {
                                        ForEach(turn.citations) { c in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("[\(c.index)]").font(.caption.monospaced()).foregroundStyle(.purple)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(c.text).font(.caption)
                                                    HStack(spacing: 6) {
                                                        if let app = c.app { Text(app) }
                                                        if let when = c.when {
                                                            Text(when.prefix(16).replacingOccurrences(of: "T", with: " "))
                                                        }
                                                    }
                                                    .font(.caption2).foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                if let url = c.url, let u = URL(string: url) {
                                                    Button { NSWorkspace.shared.open(u) } label: {
                                                        Image(systemName: "arrow.up.right.square")
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.turns.last?.answer) {
                    if let last = vm.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 8)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            timeWidget.padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            if vm.turns.isEmpty {
                resurfaceCard
                    .padding(30)
            }
        }
        .background(homeBackdrop)
        .onReceive(NotificationCenter.default.publisher(for: .clemHomeBGChanged)) { _ in
            bgImage = HomeBackground.image
        }
        .onAppear {
            focused = true
            bgImage = HomeBackground.image
            vm.loadResurface(engine: engine)
        }
    }

    /// "CLEM NOTICED" — one distilled, non-obvious observation about the user's
    /// own memories, cyclable. The Insights engine condensed into a single card.
    private func loadInsights() {
        let stale = InsightsService.generatedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if insights.isEmpty || stale {
            let settings = engine.settings
            let times = engine.appTimes
            Task {
                let r = await InsightsService.generate(settings: settings, appTimes: times)
                await MainActor.run { if !r.isEmpty { insights = r; insightIdx = 0 } }
            }
        }
    }

    private var noticedCard: some View {
        let ins = insights[insightIdx % insights.count]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ins.icon).font(.system(size: 10)).foregroundStyle(Theme.accent)
                Text("CLEM NOTICED").font(Theme.ui(10, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.4))
                Spacer()
                if insights.count > 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { insightIdx += 1 }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink(0.4)).help("Another")
                }
            }
            Text(ins.title).font(Theme.display(18)).foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text(ins.body).font(Theme.ui(12)).foregroundStyle(Theme.ink(0.7)).lineSpacing(2).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 300, height: 140, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .grain(cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .transition(.opacity)
    }

    /// Optional user background image — anchored right, dimmed, with a scrim
    /// on the left so the hero text stays readable (CLEM-style).
    @ViewBuilder
    private var homeBackdrop: some View {
        if let img = bgImage {
            GeometryReader { g in
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(g.size.width * 0.38, 460))
                    // Fade up from the bottom so it emerges from the black,
                    // flush to the bottom edge with no gap.
                    .mask(LinearGradient(colors: [.clear, .black, .black],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    private func fmt(_ s: Double) -> String {
        let m = Int(s) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    // Compact card top-right: total + top-3 apps/sites. Click to expand the
    // full breakdown. Fixed width so it doesn't jump around.
    private var timeWidget: some View {
        let total = engine.screenTimeSeconds
        return VStack(alignment: .trailing, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.18)) { timeExpanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text("Screen time").font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink(0.85))
                    Text(total > 0 ? fmt(total) : "—").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    Image(systemName: timeExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Theme.ink(0.45))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
            .buttonStyle(.plain)

            if timeExpanded { timeBreakdown.frame(width: 300) }
        }
        .onAppear { engine.refreshStats() }
    }


    private var timeBreakdown: some View {
        let spans = Array(engine.appTimes.prefix(7))
        let maxS = spans.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where your time went today").font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink(0.85))
                Spacer()
                Image(systemName: engine.usingSystemTime ? "applelogo" : "clock")
                    .font(.system(size: 9)).foregroundStyle(Theme.ink(0.4))
            }
            if spans.isEmpty {
                Text("No activity recorded yet today.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.45))
            } else {
                ForEach(spans) { span in
                    HStack(spacing: 10) {
                        Text(span.app).font(Theme.ui(12)).foregroundStyle(Theme.ink(0.85))
                            .frame(width: 96, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(Theme.gold.opacity(0.75))
                                .frame(width: max(5, g.size.width * (span.seconds / maxS)))
                        }
                        .frame(height: 7)
                        Text(fmt(span.seconds)).font(Theme.ui(11).monospacedDigit())
                            .foregroundStyle(Theme.ink(0.6)).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Text(engine.usingSystemTime
                 ? "From macOS Screen Time — your real activity today."
                 : "Clem's own tracking. Grant Full Disk Access for system-wide time.")
                .font(Theme.ui(10)).foregroundStyle(Theme.ink(0.4))
                .padding(.top, 2)
            if !engine.usingSystemTime {
                Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(.plain).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.gold)
            }
        }
        .tablet(padding: 14)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// A clickable starter prompt: fills the question and asks immediately.
    /// The pill's text is the exact question sent.
    private func suggestionPill(_ prompt: String) -> some View {
        Button {
            vm.question = prompt
            vm.ask(engine: engine)
        } label: {
            Text(prompt).font(Theme.ui(12)).foregroundStyle(cream.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Theme.accent.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

        /// filled and clipped, under a dark scrim so the light image reads on the
    /// dark UI and text stays legible.
    private var resurfaceCardBG: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.surface)
            .overlay {
                if let img = ClemArt.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                LinearGradient(
                    colors: [Theme.bg.opacity(0.62), Theme.bg.opacity(0.88)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The reference card: warm angular-gradient frame, source icon,
    /// "You saved … last month", body text, centered "Check next".
    /// Type on the dark card — white, softened via opacity where needed.
    private var cardInk: Color { .white }
    /// The card's dark fill, a touch deeper than the app surface.
    private var cardFill: Color { Color(hex: "#1C1B19") }

    /// The deck's shared artwork — the Creation-of-Adam hands (recall2),
    /// washed lightly so dark serif type reads like print on the fresco.
    private var resurfaceCard: some View {
        ZStack {
            // The deepest card — a plain dark back peeking out.
            deckBack(rotation: 4, offset: CGSize(width: 10, height: 9))

            // The card underneath is a REAL card: the next memory, waiting.
            if let next = vm.upNext {
                cardFace(next, number: vm.resurfaceNumber + 1)
                    .rotationEffect(.degrees(-2.5))
                    .offset(x: -7, y: 9)
                    .scaleEffect(0.985)
                    .allowsHitTesting(false)
            } else {
                deckBack(rotation: -3, offset: CGSize(width: -9, height: 11))
            }

            if vm.resurfaceExhausted {
                cardFrame {
                    VStack(spacing: 8) {
                        Text("\u{2726}").font(.title2).foregroundStyle(Theme.accent)
                        Text("You've drawn the whole deck.")
                            .font(.system(size: 15, design: .serif).weight(.medium))
                            .foregroundStyle(cardInk)
                        Text("New memories will resurface here.")
                            .font(Theme.ui(11)).foregroundStyle(cardInk.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            } else if let r = vm.resurfaced {
                frontCard(r)
                    .id(vm.resurfaceNumber)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .opacity // the swipe already carried it off-screen
                    ))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: vm.resurfaceNumber)
    }

    /// A face-down card at the bottom of the stack — dark, quiet.
    private func deckBack(rotation: Double, offset: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(cardFill)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.09)))
            .frame(width: 316, height: 178)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
    }

    /// Card chrome: a dark iOS-cornered rectangle with the cut-out hands
    /// floating on it at half opacity; the memory reads in white on top.
    private func cardFrame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 316, height: 178, alignment: .topLeading)
            .background {
                ZStack {
                    cardFill
                    if let img = ClemArt.deck {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.5)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    /// The card's face — meta row, headline, body, whispered affordances.
    private func cardFace(_ r: Resurfaced, number: Int) -> some View {
        cardFrame {
            VStack(alignment: .leading, spacing: 0) {
                // Meta row: source left, age right — serif italics, like the deck.
                HStack(spacing: 6) {
                    Group {
                        if let icon = IconStore.shared.icon(label: r.sourceLabel, domain: r.domain, bundleID: r.bundleID) {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.black
                                Text(String(r.sourceLabel.prefix(1))).font(Theme.ui(9, .bold)).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(r.sourceLabel)
                        .font(.system(size: 11, design: .serif).italic().weight(.semibold))
                        .foregroundStyle(cardInk)
                    Spacer()
                    Text(r.when.isEmpty ? "a while ago" : r.when)
                        .font(.system(size: 11, design: .serif).italic())
                        .foregroundStyle(cardInk.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Headline + body — dark serif printed on the fresco.
                VStack(alignment: .leading, spacing: 5) {
                    Text(r.title ?? r.source)
                        .font(.system(size: 17, design: .serif).weight(.medium))
                        .foregroundStyle(cardInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.text)
                        .font(Theme.ui(11))
                        .foregroundStyle(cardInk.opacity(0.75))
                        .lineSpacing(2)
                        .lineLimit(r.title == nil ? 5 : 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 9)

                Spacer(minLength: 0)

                // Footer: no buttons — just the affordances, whispered.
                HStack {
                    Text(r.url != nil ? "tap to revisit" : "a note to yourself")
                        .font(.system(size: 10, design: .serif).italic())
                        .foregroundStyle(cardInk.opacity(0.55))
                    Spacer()
                    Text("swipe \u{00B7} \(number) of \(vm.resurfaceTotal)")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(cardInk.opacity(0.55))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func frontCard(_ r: Resurfaced) -> some View {
        // Each draw lands with its own slight tilt — hand-dealt, not printed.
        let tilt = Double((vm.resurfaceNumber * 37) % 5 - 2) * 0.5
        return cardFace(r, number: vm.resurfaceNumber)
            .rotationEffect(.degrees(tilt + Double(cardDrag.width) / 18))
            .offset(cardDrag)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if !cardFlying { cardDrag = v.translation }
                    }
                    .onEnded { v in
                        let dx = v.translation.width
                        guard abs(dx) > 70 else {
                            // Not a committed swipe — snap back onto the deck.
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { cardDrag = .zero }
                            return
                        }
                        // Fly off in the direction of the swipe, then draw the next.
                        cardFlying = true
                        withAnimation(.easeIn(duration: 0.22)) {
                            cardDrag = CGSize(width: dx < 0 ? -560 : 560, height: v.translation.height - 70)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                            vm.loadResurface(engine: engine)
                            cardDrag = .zero
                            cardFlying = false
                        }
                    }
            )
            .onTapGesture {
                if let url = r.url, let u = URL(string: url) {
                    NSWorkspace.shared.open(u)
                }
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}


/// Clem loader — a procedurally generated memory graph that grows
/// while Clem searches: nodes surface one by one, link into the network, and
/// a gold retrieval pulse sweeps across whatever has appeared. Each cycle
/// lays out a brand-new clem (seeded by the cycle index), so it
/// reads as live retrieval over real nodes, never a canned spinner.
struct GraphLoader: View {
    var label = "searching your memories…"

    private static let cycle = 5.2 // seconds per clem
    private static let fade = 0.45 // fade-out at the end of a cycle

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let idx = UInt64(t / Self.cycle)
                    let ct = t - Double(idx) * Self.cycle
                    let graph = MiniGraph.generate(seed: idx)
                    let pts = graph.nodes.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

                    // Whole clem eases in, then dissolves before the next one.
                    let alpha = min(min(1, ct / 0.3), min(1, (Self.cycle - ct) / Self.fade))

                    func appear(_ i: Int) -> Double {
                        let start = 0.1 + Double(i) * 0.26
                        return max(0, min(1, (ct - start) / 0.25))
                    }
                    let visible = pts.indices.reduce(0) { appear($1) > 0 ? $0 + 1 : $0 }

                    // Retrieval pulse sweeps only the surfaced nodes.
                    let sweep = visible > 0 ? (ct * 2.2).truncatingRemainder(dividingBy: Double(visible)) : 0
                    func glow(_ i: Int) -> Double {
                        guard i < visible else { return 0 }
                        var d = abs(Double(i) - sweep)
                        d = min(d, Double(visible) - d)
                        return max(0, 1 - d / 2.0)
                    }

                    for e in graph.edges {
                        let progress = min(appear(e.a), appear(e.b))
                        guard progress > 0 else { continue }
                        var p = Path()
                        p.move(to: pts[e.a])
                        p.addLine(to: pts[e.b])
                        let drawn = p.trimmedPath(from: 0, to: progress) // links draw in
                        ctx.stroke(drawn, with: .color(Theme.ink(0.15 * alpha)), lineWidth: 1)
                        let hot = max(glow(e.a), glow(e.b))
                        if hot > 0.05 {
                            ctx.stroke(drawn, with: .color(Theme.gold.opacity(0.55 * hot * alpha)), lineWidth: 1)
                        }
                    }
                    for (i, pt) in pts.enumerated() {
                        let a = appear(i)
                        guard a > 0 else { continue }
                        let hot = glow(i)
                        let r = (1.4 + 1.4 * a + 2.2 * hot) * (0.6 + 0.4 * a)
                        if hot > 0.55 { // soft halo on the node being "read"
                            let hr = r + 4
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: pt.x - hr, y: pt.y - hr, width: hr * 2, height: hr * 2)),
                                with: .color(Theme.gold.opacity(0.2 * hot * alpha))
                            )
                        }
                        let color = hot > 0.35
                            ? Theme.gold.opacity((0.35 + 0.65 * hot) * alpha)
                            : Theme.ink(0.32 * a * alpha)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(width: 170, height: 52)

            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.ink(0.45))
        }
        .padding(.vertical, 2)
        .transition(.opacity)
    }
}

/// A small random clem: spaced-out nodes joined into a spanning tree
/// plus a couple of cross-links. Deterministic per seed, so every loader
/// cycle grows a different graph without any view state.
private struct MiniGraph {
    struct Edge { let a: Int; let b: Int }
    var nodes: [CGPoint]
    var edges: [Edge]

    // The canvas is ~3× wider than tall — weigh y less when measuring spacing.
    private static func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat {
        hypot(p.x - q.x, (p.y - q.y) * 0.35)
    }

    static func generate(seed: UInt64) -> MiniGraph {
        var rng = SplitMix64(state: seed &+ 0x5DEECE66D)
        let count = Int.random(in: 9...12, using: &rng)

        var pts: [CGPoint] = []
        var attempts = 0
        while pts.count < count, attempts < 400 {
            attempts += 1
            let p = CGPoint(
                x: CGFloat.random(in: 0.04...0.96, using: &rng),
                y: CGFloat.random(in: 0.14...0.86, using: &rng)
            )
            if pts.allSatisfy({ dist($0, p) > 0.09 }) { pts.append(p) }
        }

        // Spanning tree: each new node links to its nearest earlier node.
        var edges: [Edge] = []
        for i in 1..<pts.count {
            var best = 0
            var bestD = CGFloat.infinity
            for j in 0..<i where dist(pts[j], pts[i]) < bestD {
                bestD = dist(pts[j], pts[i])
                best = j
            }
            edges.append(Edge(a: best, b: i))
        }
        // A couple of short cross-links so it reads as a graph, not a chain.
        for _ in 0..<2 where pts.count > 4 {
            let a = Int.random(in: 0..<pts.count, using: &rng)
            let b = Int.random(in: 0..<pts.count, using: &rng)
            guard a != b, dist(pts[a], pts[b]) < 0.3,
                  !edges.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) })
            else { continue }
            edges.append(Edge(a: a, b: b))
        }
        return MiniGraph(nodes: pts, edges: edges)
    }
}

/// Tiny deterministic RNG (SplitMix64) so each loader cycle derives its
/// clem purely from the cycle index — no stored state to manage.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D4A9C596A25F31
        return z ^ (z >> 31)
    }
}
