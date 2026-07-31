import AppKit
import SwiftUI

/// Locally tracked consumption events — which saved memories you opened, and
/// when. The "when" powers the For You ranking (recent interests weigh more).
enum DiscoverProgress {
    private static let key = "discoverConsumedEvents"
    private static let legacyKey = "discoverConsumed"

    static func load() -> [String: Double] {
        if let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double], !d.isEmpty {
            return d
        }
        // Migrate the old timestamp-less set.
        let legacy = UserDefaults.standard.stringArray(forKey: legacyKey) ?? []
        guard !legacy.isEmpty else { return [:] }
        let now = Date().timeIntervalSince1970
        let d = Dictionary(uniqueKeysWithValues: legacy.map { ($0, now) })
        UserDefaults.standard.set(d, forKey: key)
        return d
    }

    static func save(_ events: [String: Double]) {
        UserDefaults.standard.set(events, forKey: key)
    }
}

/// Discover — a real feed over everything you saved and imported.
/// **For You** (primary): ranked by your recent consumption — open a few AI
/// things and AI floats up. **Timeline**: the day-grouped archive with
/// source filters and sorting as the secondary way in.
struct DiscoverView: View {
    @EnvironmentObject var engine: Engine
    // Observed so cards re-render as favicons / link thumbnails arrive.
    @ObservedObject private var iconStore = IconStore.shared
    @ObservedObject private var linkThumbs = LinkThumbs.shared

    enum FeedMode: String, CaseIterable {
        case forYou = "For You"
        case timeline = "Timeline"
    }

    enum SortMode: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case shuffle = "Shuffle"
    }

    @State private var nodes: [GraphNode] = []
    @State private var loading = true
    @State private var mode: FeedMode = .forYou
    @State private var filter = "All"
    @State private var sort: SortMode = .newest
    @State private var hideConsumed = false
    @State private var events: [String: Double] = DiscoverProgress.load()
    @State private var rankScores: [String: Double] = [:]
    @State private var topInterests: [String] = []
    @State private var hovered: String?
    @State private var peeking: String?

    private var consumed: Set<String> { Set(events.keys) }

    private let thumbHeight: CGFloat = 128
    private let cardTextHeight: CGFloat = 48
    private let gutter: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let contentWidth = min(geo.size.width - 88, 1020)
            Group {
                if loading {
                    GraphLoader(label: "gathering your saves…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if nodes.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                                .padding(.bottom, 22)

                            if mode == .forYou {
                                forYouFeed(width: contentWidth)
                            } else if sort == .shuffle {
                                sectionLabel("Shuffled — dip in anywhere")
                                    .padding(.bottom, 12)
                                mosaic(visible, width: contentWidth)
                            } else {
                                ForEach(grouped, id: \.day) { group in
                                    timelineHeader(group.day, count: group.items.count)
                                    mosaic(group.items, width: contentWidth)
                                }
                            }
                            Spacer(minLength: 40)
                        }
                        .id("\(mode.rawValue)|\(filter)|\(sort.rawValue)|\(hideConsumed)")
                        .frame(width: contentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 44)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { await load() }
    }

    private func load() async {
        let snapshot = GraphService.SettingsSnapshot(
            supermemoryURL: engine.settings.supermemoryURLValue,
            supermemoryKey: engine.settings.supermemoryKey,
            containerTag: engine.settings.containerTag
        )
        let fetched = await GraphService.shared.nodesOnly(snapshot, scope: .saved)
        nodes = fetched.sorted { $0.createdAt > $1.createdAt }
        retune()
        loading = false
    }

    // MARK: For You ranking

    private static let stopTerms: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "your", "you", "have", "will",
        "https", "http", "wwww", "html", "index", "about", "when", "what", "how", "why",
        "bookmark", "bookmarks", "bookmarked", "tweet", "browser", "folder", "saved",
        "watch", "video", "channel", "youtube", "chrome", "brave", "safari", "history",
        "untitled", "page", "site", "link", "https", "com",
    ]

    /// The terms a memory is "about": its tags plus title/summary words.
    private static func terms(of n: GraphNode) -> Set<String> {
        var out = Set(n.tags.map { $0.lowercased() }.filter { !stopTerms.contains($0) })
        let text = "\(n.title) \(n.summary)".lowercased()
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let s = String(word)
            if s.count >= 4, !stopTerms.contains(s) { out.insert(s) }
        }
        return out
    }

    /// Recency-weighted interest profile from what you've opened: a term you
    /// consumed today counts far more than one from a month ago.
    private static func interestProfile(events: [String: Double], nodes: [GraphNode]) -> [String: Double] {
        let now = Date().timeIntervalSince1970
        var profile: [String: Double] = [:]
        for n in nodes {
            guard let t = events[n.id] else { continue }
            let daysAgo = max(0, (now - t) / 86_400)
            let recency = exp(-daysAgo / 14) // ~2-week memory of your tastes
            for term in terms(of: n) {
                profile[term, default: 0] += recency
            }
        }
        return profile
    }

    /// Score every memory against the profile. Freshly saved items get a
    /// nudge, a stable jitter keeps ties varied, consumed ones sink.
    private func retune() {
        let profile = Self.interestProfile(events: events, nodes: nodes)
        topInterests = profile
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var scores: [String: Double] = [:]
        for n in nodes {
            var s = 0.0
            let ts = Self.terms(of: n)
            if !profile.isEmpty {
                for t in ts { s += profile[t] ?? 0 }
                s /= max(1, Double(ts.count)).squareRoot()
            }
            if let d = df.date(from: String(n.createdAt.prefix(10))) {
                let age = max(0, Date().timeIntervalSince(d) / 86_400)
                s += exp(-age / 60) * 0.6 // fresh saves surface even untuned
            }
            s += Double(shuffleKey(n.id) % 997) / 2500.0 // stable jitter
            if consumed.contains(n.id) { s -= 1_000 } // consumed sink to the end
            scores[n.id] = s
        }
        rankScores = scores
    }

    // MARK: filtering & grouping

    private var sources: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in nodes { counts[n.app, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }

    private func shuffleKey(_ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    private var visible: [GraphNode] {
        let filtered = nodes.filter { n in
            (filter == "All" || n.app == filter) && (!hideConsumed || !consumed.contains(n.id))
        }
        if mode == .forYou {
            return filtered.sorted { (rankScores[$0.id] ?? 0) > (rankScores[$1.id] ?? 0) }
        }
        switch sort {
        case .newest: return filtered
        case .oldest: return filtered.reversed()
        case .shuffle: return filtered.sorted { shuffleKey($0.id) < shuffleKey($1.id) }
        }
    }

    /// Day buckets in feed order — Timeline mode only.
    private var grouped: [(day: String, items: [GraphNode])] {
        var buckets: [String: [GraphNode]] = [:]
        var order: [String] = []
        for n in visible {
            let day = String(n.createdAt.prefix(10))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(n)
        }
        return order.map { ($0, buckets[$0]!) }
    }

    // MARK: feed sections

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(11, .semibold))
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.ink(0.4))
    }

    /// Timeline day header: gold dot, date, count, hairline running out right.
    private func timelineHeader(_ day: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.gold).frame(width: 6, height: 6)
            sectionLabel(dayLabel(day))
            Text("\(count)")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.ink(0.3))
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.bottom, 14)
    }

    /// For You: the ranked mosaic, straight in — no hero, no chrome.
    @ViewBuilder
    private func forYouFeed(width: CGFloat) -> some View {
        mosaic(visible, width: width)
    }

    /// The justified thumbnail grid shared by every section.
    private func mosaic(_ items: [GraphNode], width: CGFloat) -> some View {
        ForEach(Array(pack(items, width: width).enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top, spacing: gutter) {
                ForEach(row, id: \.node.id) { entry in
                    card(entry.node, width: entry.width)
                }
            }
            .padding(.bottom, gutter + 6)
        }
    }

    private func dayLabel(_ iso: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: iso) else { return iso }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let out = DateFormatter()
        out.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "EEEE, d MMMM" : "d MMMM yyyy"
        return out.string(from: date)
    }

    // MARK: justified row packing

    private func weight(_ n: GraphNode) -> CGFloat {
        if n.app == "YouTube" { return 1.85 }
        let options: [CGFloat] = [1.0, 1.15, 1.35, 1.6]
        return options[Int(shuffleKey(n.id) % 4)]
    }

    private func pack(_ items: [GraphNode], width: CGFloat) -> [[(node: GraphNode, width: CGFloat)]] {
        let target: CGFloat = 4.4
        var rows: [[(node: GraphNode, width: CGFloat)]] = []
        var current: [(GraphNode, CGFloat)] = []
        var sum: CGFloat = 0

        func flush(stretch: Bool) {
            guard !current.isEmpty else { return }
            let avail = width - gutter * CGFloat(current.count - 1)
            let denom = stretch ? sum : max(sum, target)
            rows.append(current.map { ($0.0, avail * $0.1 / denom) })
            current = []
            sum = 0
        }

        for n in items {
            current.append((n, weight(n)))
            sum += weight(n)
            if sum >= target { flush(stretch: true) }
        }
        flush(stretch: false)
        return rows
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discover")
                .font(Theme.display(30, .medium))
                .foregroundStyle(Theme.ink)
                .padding(.top, 40)
            Text("A feed of everything you saved — tuned to what you've actually been consuming lately.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.ink(0.45))

            // Primary: the mode. For You is the feed; Timeline is the archive.
            HStack(alignment: .center, spacing: 22) {
                ForEach(FeedMode.allCases, id: \.self) { m in
                    Button {
                        mode = m
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.rawValue)
                                .font(Theme.ui(14, mode == m ? .semibold : .regular))
                                .foregroundStyle(mode == m ? Theme.ink : Theme.ink(0.4))
                            Capsule()
                                .fill(mode == m ? Theme.gold : .clear)
                                .frame(width: 26, height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if mode == .forYou {
                    Button {
                        retune()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            Text("Retune").font(Theme.ui(11, .medium))
                        }
                    }
                    .buttonStyle(PillButton(bg: Theme.surface, fg: Theme.ink(0.7), border: Theme.line))
                    .help("Re-rank the feed from your latest consumption")
                    .padding(.bottom, 6)
                }

                Spacer()

                Button {
                    surpriseMe()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "dice").font(.system(size: 10))
                        Text("Surprise me").font(Theme.ui(11, .medium))
                    }
                }
                .buttonStyle(PillButton(bg: Theme.surface, fg: Theme.gold, border: Theme.gold.opacity(0.5)))
                .help("Open a random one you haven't consumed yet")
                .padding(.bottom, 6)
            }
            .padding(.top, 10)


            // Secondary: source filters (and sorting, in Timeline).
            HStack(spacing: 6) {
                chip("All", count: nodes.count)
                ForEach(sources, id: \.name) { source in
                    chip(source.name, count: source.count)
                }
                Spacer()
                if mode == .timeline {
                    Picker("", selection: $sort) {
                        ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 190)
                }
            }

            let done = nodes.filter { consumed.contains($0.id) }.count
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ink(0.08))
                        Capsule().fill(Theme.gold.opacity(0.75))
                            .frame(width: nodes.isEmpty ? 0 : g.size.width * CGFloat(done) / CGFloat(nodes.count))
                    }
                }
                .frame(height: 4)
                Text("\(done) of \(nodes.count) consumed")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.ink(0.45))
                    .fixedSize()
                Toggle(isOn: $hideConsumed) {
                    Text("hide consumed").font(Theme.ui(10))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .foregroundStyle(Theme.ink(0.5))
            }
            .padding(.top, 4)
        }
    }

    private func chip(_ label: String, count: Int) -> some View {
        let active = filter == label
        return Button {
            filter = label
        } label: {
            HStack(spacing: 4) {
                Text(label).font(Theme.ui(10, active ? .semibold : .regular))
                Text("\(count)").font(Theme.mono(9)).opacity(0.55)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(active ? Theme.gold.opacity(0.18) : Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.gold.opacity(0.5) : Theme.line))
            .foregroundStyle(active ? Theme.gold : Theme.ink(0.55))
        }
        .buttonStyle(.plain)
    }

    // MARK: the card

    private func card(_ node: GraphNode, width: CGFloat) -> some View {
        let isConsumed = consumed.contains(node.id)
        let isHovered = hovered == node.id
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                media(node, width: width)
                    .scaleEffect(isHovered ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.18), value: isHovered)
                    .frame(width: width, height: thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .saturation(isConsumed ? 0.35 : 1)
                    .opacity(isConsumed ? 0.6 : 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(isHovered ? Theme.gold.opacity(0.55) : Theme.line, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 12, y: 5)

                if isConsumed || isHovered {
                    Button {
                        toggleConsumed(node)
                    } label: {
                        Image(systemName: isConsumed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(isConsumed ? Color(hex: "5FB37E") : .white.opacity(0.85))
                            .shadow(color: .black.opacity(0.6), radius: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .help(isConsumed ? "Mark as not consumed" : "Mark as consumed")
                }

                if isHovered, node.url != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(6)
                                .background(Theme.gold, in: Circle())
                                .padding(7)
                        }
                    }
                }
            }
            .frame(width: width, height: thumbHeight)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(isConsumed ? Theme.ink(0.45) : Theme.ink(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if let icon = smallIcon(node) {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    }
                    Text("\(node.app) · \(relative(node.createdAt))")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.ink(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: cardTextHeight, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(node) }
        .onHover { over in
            if over {
                hovered = node.id
            } else if hovered == node.id {
                hovered = nil
            }
        }
        .popover(
            isPresented: Binding(
                get: { peeking == node.id },
                set: { if !$0 { peeking = nil } }
            ),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(node.title).font(Theme.ui(13, .semibold))
                if !node.summary.isEmpty {
                    Text(node.summary).font(Theme.ui(12)).lineSpacing(3)
                }
            }
            .padding(16)
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private func media(_ node: GraphNode, width: CGFloat, height: CGFloat? = nil) -> some View {
        let h = height ?? thumbHeight
        if let thumb = node.thumb, let img = NSImage(contentsOfFile: thumb) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: width, height: h)
        } else if let img = linkThumbs.thumb(for: node.url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: width, height: h)
        } else {
            let domain = node.url.flatMap { URL(string: $0)?.host?.lowercased() }
            ZStack {
                Rectangle().fill(Theme.surface)
                Circle().fill(Theme.gold.opacity(0.08)).frame(width: 84, height: 84).blur(radius: 18)
                if let icon = iconStore.icon(label: node.app, domain: domain, bundleID: node.bundleID) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(String(node.app.prefix(1)))
                        .font(Theme.display(26)).foregroundStyle(Theme.gold)
                }
            }
            .frame(width: width, height: h)
            .grain()
        }
    }

    private func smallIcon(_ node: GraphNode) -> NSImage? {
        let domain = node.url.flatMap { URL(string: $0)?.host?.lowercased() }
        return iconStore.icon(label: node.app, domain: domain, bundleID: node.bundleID)
    }

    private func relative(_ iso: String) -> String {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    // MARK: actions

    private func open(_ node: GraphNode) {
        if let url = node.url.flatMap({ URL(string: $0) }) {
            NSWorkspace.shared.open(url)
            markConsumed(node)
        } else {
            peeking = peeking == node.id ? nil : node.id
            markConsumed(node)
        }
    }

    private func surpriseMe() {
        let pool = visible.filter { !consumed.contains($0.id) && $0.url != nil }
        guard let pick = pool.randomElement() else { return }
        open(pick)
    }

    /// Records the open with a timestamp — the ranking signal. The feed order
    /// stays put until the next Retune/visit, so nothing jumps mid-scroll.
    private func markConsumed(_ node: GraphNode) {
        events[node.id] = Date().timeIntervalSince1970
        DiscoverProgress.save(events)
    }

    private func toggleConsumed(_ node: GraphNode) {
        if events[node.id] != nil {
            events[node.id] = nil
        } else {
            events[node.id] = Date().timeIntervalSince1970
        }
        DiscoverProgress.save(events)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("✦").font(.title).foregroundStyle(Theme.gold)
            Text("Nothing saved yet")
                .font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
            Text("Save with ⌥S, or pull in your bookmarks from Connectors — they'll all line up here.")
                .font(Theme.ui(12)).foregroundStyle(Theme.ink(0.5))
            Button("Open Connectors") {
                NotificationCenter.default.post(name: .clemSwitchTab, object: MainTab.connectors)
            }
            .buttonStyle(PillButton(bg: Theme.gold, fg: .black))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
