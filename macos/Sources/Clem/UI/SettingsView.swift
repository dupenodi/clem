import SwiftUI

/// Settings styled to match the rest of Clem — warm charcoal cards,
/// amber accents, cream text — instead of the default grey system Form.
struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var blockedAppsText = ""
    @State private var blockedDomainsText = ""
    @State private var blockDirty = false
    @State private var dbSize: Int64 = 0
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var forgetFrom = Calendar.current.date(byAdding: .hour, value: -1, to: Date())!
    @State private var forgetTo = Date()
    @State private var forgetResult: String?

    private let bg = Theme.bg
    private let card = Theme.surface
    private let amber = Theme.accent
    private let cream = Theme.ink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(Theme.display(30))
                    .foregroundStyle(cream)
                    .padding(.top, 34)
                    .padding(.bottom, 2)

                captureCard
                privacyCard
                servicesCard
                generalCard
                forgetCard
                statsCard
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.bottom, 40)
        }
        .background(bg)
        .preferredColorScheme(.dark)
        .tint(amber)
        .onAppear {
            blockedAppsText = engine.settings.blockedApps.joined(separator: "\n")
            blockedDomainsText = engine.settings.blockedDomains.joined(separator: "\n")
            Task { dbSize = await Store.shared.databaseSizeBytes() }
        }
    }

    // MARK: cards

    private var captureCard: some View {
        card("Capture", "camera.viewfinder") {
            row("Interval", subtitle: "How often the screen is sampled while monitoring") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { engine.settings.captureInterval },
                        set: { engine.settings.captureInterval = $0; engine.restartTimer() }
                    ), in: 2...30, step: 1).frame(width: 160)
                    Text("\(Int(engine.settings.captureInterval))s").font(.callout.monospacedDigit()).foregroundStyle(cream)
                }
            }
            divider
            toggleRow("Keep thumbnails", "Small previews for the graph & canvas", get: { engine.settings.keepThumbnails }, set: { engine.settings.keepThumbnails = $0 })
            divider
            toggleRow("Pause on low battery", "Stops monitoring below 20%", get: { engine.settings.pauseOnLowBattery }, set: { engine.settings.pauseOnLowBattery = $0 })
        }
    }

    private var privacyCard: some View {
        card("Privacy — never captured", "hand.raised") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Blocked apps / window titles").font(.caption).foregroundStyle(cream.opacity(0.55))
                editor($blockedAppsText)
                Text("Blocked URL domains  (use * wildcards)").font(.caption).foregroundStyle(cream.opacity(0.55)).padding(.top, 4)
                editor($blockedDomainsText)
                HStack {
                    Text("Matches are discarded before OCR — never stored.").font(.caption2).foregroundStyle(cream.opacity(0.4))
                    Spacer()
                    Button("Save") {
                        engine.settings.blockedApps = blockedAppsText.split(separator: "\n").map(String.init)
                        engine.settings.blockedDomains = blockedDomainsText.split(separator: "\n").map(String.init)
                        blockDirty = false
                    }
                    .buttonStyle(PillButton(bg: amber, fg: .black))
                    .disabled(!blockDirty)
                    .opacity(blockDirty ? 1 : 0.5)
                }
            }
        }
    }

    private var servicesCard: some View {
        card("Services", "server.rack") {
            fieldRow("supermemory URL", get: { engine.settings.supermemoryURL }, set: { engine.settings.supermemoryURL = $0 })
            divider
            toggleRow("Start engine automatically", "Launch supermemory local at startup when it isn't already running", get: { engine.settings.engineAutoStart }, set: { engine.settings.engineAutoStart = $0 })
            if engine.settings.engineAutoStart {
                divider
                fieldRow("Engine binary", get: { engine.settings.engineBinary }, set: { engine.settings.engineBinary = $0 })
                divider
                row("Engine folder", subtitle: "Must be the folder holding .supermemory — data lives there") {
                    TextField("", text: Binding(
                        get: { engine.settings.engineWorkdir },
                        set: { engine.settings.engineWorkdir = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospaced())
                    .foregroundStyle(cream.opacity(0.8))
                    .frame(width: 260)
                }
            }
            divider
            row("Model provider", subtitle: "Runs enrichment, tagging & chat — locally or via your own API key") {
                Picker("", selection: Binding(
                    get: { engine.settings.llmProviderValue },
                    set: { switchProvider(to: $0) }
                )) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            divider
            if engine.settings.llmProviderValue == .ollama {
                fieldRow("Ollama URL", get: { engine.settings.ollamaURL }, set: { engine.settings.ollamaURL = $0 })
                divider
                fieldRow("Ollama model", get: { engine.settings.ollamaModel }, set: { engine.settings.ollamaModel = $0 })
            } else {
                secureFieldRow("API key", get: { engine.settings.cloudAPIKey }, set: { engine.settings.cloudAPIKey = $0 })
                divider
                fieldRow("Model", get: { engine.settings.cloudModel }, set: { engine.settings.cloudModel = $0 })
                if engine.settings.llmProviderValue == .custom {
                    divider
                    fieldRow("Base URL", get: { engine.settings.cloudBaseURL }, set: { engine.settings.cloudBaseURL = $0 })
                }
            }
            divider
            HStack(spacing: 16) {
                statusDot("supermemory", engine.supermemoryUp)
                statusDot(engine.settings.llmProviderValue == .ollama ? "ollama" : "model", engine.llmUp)
                Spacer()
                if engine.pendingCount > 0 {
                    Text("\(engine.pendingCount) queued").font(.caption2).foregroundStyle(cream.opacity(0.5))
                }
            }
        }
    }

    /// Prefill the model field with the provider's preset, but never clobber
    /// a model name the user typed themselves.
    private func switchProvider(to provider: LLMProvider) {
        engine.settings.llmProvider = provider.rawValue
        if let preset = provider.defaultModel {
            let presets = LLMProvider.allCases.compactMap(\.defaultModel)
            if engine.settings.cloudModel.isEmpty || presets.contains(engine.settings.cloudModel) {
                engine.settings.cloudModel = preset
            }
        }
    }

    private var generalCard: some View {
        card("General", "gearshape") {
            toggleRow("Launch at login", "Start Clem automatically", get: { launchAtLogin }, set: { launchAtLogin = $0; LoginItem.set($0) })
            divider
            row("Keep thumbnails", subtitle: "Older previews are pruned; text is kept forever") {
                Stepper("\(engine.settings.thumbnailRetentionDays) days", value: Binding(
                    get: { engine.settings.thumbnailRetentionDays },
                    set: { engine.settings.thumbnailRetentionDays = $0 }
                ), in: 1...365).fixedSize()
            }
            divider
            row("Export", subtitle: "All memories as a JSONL file") {
                Button("Export…") { exportAll() }.buttonStyle(PillButton(bg: card.opacity(0), fg: amber, border: amber))
            }
            divider
            row("Home background", subtitle: "An image behind the Home screen") {
                HStack(spacing: 8) {
                    Button("Choose…") { chooseHomeBackground() }
                        .buttonStyle(PillButton(bg: amber, fg: .black))
                    Button("Remove") { HomeBackground.clear() }
                        .buttonStyle(PillButton(bg: card.opacity(0), fg: cream.opacity(0.7), border: cream.opacity(0.3)))
                }
            }
        }
    }

    private func chooseHomeBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        HomeBackground.set(from: url)
    }

    private var forgetCard: some View {
        card("Forget a time range", "trash") {
            HStack {
                DatePicker("From", selection: $forgetFrom).labelsHidden()
                Text("→").foregroundStyle(cream.opacity(0.4))
                DatePicker("To", selection: $forgetTo).labelsHidden()
                Spacer()
                Button("Forget") { forgetRange() }.buttonStyle(PillButton(bg: Color(red: 0.6, green: 0.25, blue: 0.25), fg: cream))
            }
            if let msg = forgetResult {
                Text(msg).font(.caption).foregroundStyle(cream.opacity(0.6)).padding(.top, 4)
            }
        }
    }

    private var statsCard: some View {
        card("Today", "chart.bar") {
            statRow("Frames captured", "\(engine.stats.captured)")
            divider
            statRow("Deduplicated", "\(engine.stats.deduped)  ·  \(Int(engine.stats.dedupeRate * 100))%")
            divider
            statRow("Memories kept", "\(engine.stats.kept)")
            divider
            statRow("Privacy-blocked", "\(engine.stats.blocked)")
            divider
            statRow("Database size", ByteCountFormatter.string(fromByteCount: dbSize, countStyle: .file))
        }
    }

    // MARK: building blocks

    private func card<Content: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(amber)
                Text(title).font(Theme.ui(10, .semibold)).foregroundStyle(cream.opacity(0.45)).textCase(.uppercase).kerning(1.2)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func row<Trailing: View>(_ label: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout).foregroundStyle(cream)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(cream.opacity(0.45)) }
            }
            Spacer()
            trailing()
        }
    }

    private func toggleRow(_ label: String, _ subtitle: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        row(label, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: get, set: set)).toggleStyle(.switch).labelsHidden()
        }
    }

    private func fieldRow(_ label: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        row(label) {
            TextField("", text: Binding(get: get, set: set))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospaced())
                .foregroundStyle(cream.opacity(0.8))
                .frame(width: 260)
        }
    }

    private func secureFieldRow(_ label: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        row(label) {
            SecureField("", text: Binding(get: get, set: set))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospaced())
                .foregroundStyle(cream.opacity(0.8))
                .frame(width: 260)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(cream.opacity(0.7))
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(cream)
        }
    }

    private func statusDot(_ name: String, _ up: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(up ? .green : .red).frame(width: 8, height: 8)
            Text(name).font(.caption).foregroundStyle(cream.opacity(0.7))
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(cream.opacity(0.85))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 64)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: text.wrappedValue) { blockDirty = true }
    }

    // MARK: actions

    private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clem-export.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await Store.shared.exportJSONL(to: url) }
    }

    private func forgetRange() {
        let from = forgetFrom, to = forgetTo
        let settings = engine.settings
        Task {
            let docIDs = await Store.shared.forgetFrames(from: from, to: to)
            for id in docIDs {
                var req = URLRequest(url: settings.supermemoryURLValue.appendingPathComponent("v3/documents/\(id)"))
                req.httpMethod = "DELETE"
                _ = try? await URLSession.shared.data(for: req)
            }
            await MainActor.run {
                forgetResult = "Forgot \(docIDs.count) memories in that range."
                engine.refreshStats()
            }
        }
    }
}

/// Pill-shaped button matching the app aesthetic.
struct PillButton: ButtonStyle {
    var bg: Color
    var fg: Color
    var border: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(border ?? .clear, lineWidth: 1))
            .foregroundStyle(fg)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
