import AppKit
import SwiftUI

/// Floating "Save memory" panel: shows what was extracted, lets the user
/// edit it and add a note before it becomes a memory.
@MainActor
final class SavePanelController: NSObject, NSWindowDelegate {
    static let shared = SavePanelController()
    private var panel: NSPanel?

    func trigger(engine: Engine) {
        Task {
            guard let draft = await SaveService.capture() else {
                NSSound.beep()
                return
            }
            show(draft: draft, engine: engine)
        }
    }

    private func show(draft: SavedDraft, engine: Engine) {
        if let existing = panel {
            existing.contentView = NSHostingView(rootView: SavePanelView(draft: draft, engine: engine) { [weak self] in
                self?.panel?.orderOut(nil)
            })
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: SavePanelView(draft: draft, engine: engine) { [weak self] in
            self?.panel?.orderOut(nil)
        })
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

struct SavePanelView: View {
    @State var draft: SavedDraft
    let engine: Engine
    let dismiss: () -> Void
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bookmark.fill").foregroundStyle(.purple)
                Text("Save memory").font(.headline)
                Spacer()
                Text(sourceLabel).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(draft.app)\(draft.windowTitle.isEmpty ? "" : " — \(draft.windowTitle)")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let title = draft.pageTitle {
                    Text(title).font(.caption.bold()).lineLimit(1)
                }
                if let url = draft.url {
                    Text(url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            if let thumb = draft.thumbPath,
               let img = NSImage(contentsOf: Thumbnailer.thumbsDir.appendingPathComponent(thumb)) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: draft.thumbPath == nil ? 120 : 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            TextField("Add a note (why this matters)…", text: $draft.note)
                .textFieldStyle(.roundedBorder)

            if let error { Text(error).font(.caption).foregroundStyle(.orange) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save memory") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || (draft.text.isEmpty && draft.url == nil && draft.thumbPath == nil))
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var sourceLabel: String {
        switch draft.source {
        case "selection": return "from selection"
        case "region-ocr": return "from screenshot"
        default: return "from page"
        }
    }

    private func save() {
        // Close instantly; tagging + ingest happen in the background.
        let draft = self.draft
        let settings = engine.settings
        dismiss()
        Task.detached {
            try? await SaveService.ingest(draft, settings: settings)
        }
    }
}
