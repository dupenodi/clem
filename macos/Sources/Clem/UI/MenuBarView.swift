import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clem").font(.headline)
                Spacer()
                Circle()
                    .fill(!engine.hasScreenPermission ? .red : engine.isMonitoring ? (engine.isPaused ? .orange : .green) : .gray)
                    .frame(width: 9, height: 9)
                Text(!engine.hasScreenPermission ? "no permission" : engine.isMonitoring ? (engine.isPaused ? "paused" : "watching") : "idle — save with ⌥S")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !engine.hasScreenPermission || !engine.hasAXPermission {
                Button("Finish setup…") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.borderedProminent)
            }

            statsGrid

            HStack(spacing: 10) {
                serviceDot("supermemory", up: engine.supermemoryUp)
                serviceDot(engine.settings.llmProviderValue == .ollama ? "ollama" : "model", up: engine.llmUp)
                if engine.pendingCount > 0 {
                    Text("\(engine.pendingCount) queued").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button("Open Clem") { MainWindowController.shared.show(engine: engine) }
            Button("Quick ask…   \(engine.chatHotkeyLabel)") { ChatPanelController.shared.toggle(engine: engine) }
            Button("Memory Graph…") { MainWindowController.shared.show(engine: engine, tab: .graph) }
            Button("Canvas…") { MainWindowController.shared.show(engine: engine, tab: .canvas) }

            if let last = engine.lastKept {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last memory").font(.caption2).foregroundStyle(.secondary)
                    Text("\(last.appName)\(last.windowTitle.isEmpty ? "" : " — \(last.windowTitle)")")
                        .font(.caption).lineLimit(1)
                }
            }

            Divider()

            Button("Save a memory…   \(engine.saveHotkeyLabel)") { SavePanelController.shared.trigger(engine: engine) }

            Divider()

            Button(engine.isMonitoring ? "⏸ Stop screen monitoring" : "▶︎ Start screen monitoring") {
                engine.toggleMonitoring()
            }

            if engine.isMonitoring {
                if engine.isPaused {
                    Button("Resume capture") { engine.resume() }
                } else {
                    Menu("Pause capture") {
                        Button("For 15 minutes") { engine.pause(for: 15 * 60) }
                        Button("For 1 hour") { engine.pause(for: 60 * 60) }
                        Button("Until I resume") { engine.pause(for: nil) }
                    }
                }
            }

            Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }

            Divider()
            Button("Quit Clem") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                stat("Captured", engine.stats.captured)
                stat("Kept", engine.stats.kept)
            }
            GridRow {
                stat("Deduped", engine.stats.deduped)
                stat("Blocked", engine.stats.blocked)
            }
            GridRow {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dedupe rate").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(engine.stats.dedupeRate * 100))%").font(.title3.monospacedDigit()).bold()
                }
                .gridCellColumns(2)
            }
        }
    }

    private func serviceDot(_ name: String, up: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(up ? .green : .red).frame(width: 7, height: 7)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.monospacedDigit()).bold()
        }
    }
}
