import SwiftUI

@MainActor
final class CharacterVM: ObservableObject {
    @Published var char: MythChar?
    @Published var reason: String = ""
    @Published var loading = false

    init() {
        if let c = CharacterService.cached { char = c.char; reason = c.reason }
    }

    func loadIfStale(engine: Engine) {
        let stale = CharacterService.generatedAt.map { !Calendar.current.isDateInToday($0) || Date().timeIntervalSince($0) > 3 * 3600 } ?? true
        if char == nil || stale { refresh(engine: engine) }
    }

    func refresh(engine: Engine) {
        guard !loading else { return }
        loading = true
        let settings = engine.settings
        let times = engine.appTimes
        Task {
            if let r = await CharacterService.classifyToday(settings: settings, appTimes: times) {
                self.char = r.char; self.reason = r.reason
            }
            self.loading = false
        }
    }
}

/// "Today you are …" — casts the user's consumption into a mythological
/// archetype, shown as a small card in the sidebar below the tabs.
struct CharacterWidget: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var vm = CharacterVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TODAY YOU ARE").font(Theme.ui(9, .semibold)).kerning(1.4).foregroundStyle(Theme.ink(0.35))
                Spacer()
                if vm.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { vm.refresh(engine: engine) } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                    }.buttonStyle(.plain).foregroundStyle(Theme.ink(0.35)).help("Re-read today")
                }
            }
            .padding(.bottom, 10)

            if let c = vm.char {
                if let img = c.image() {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                Text(c.name).font(Theme.display(20)).foregroundStyle(Theme.ink).padding(.top, 8)
                Text(c.represents).font(Theme.ui(11)).foregroundStyle(Theme.accent).padding(.top, 1)
                if !vm.reason.isEmpty {
                    // Description stays to a single line (truncates), with the
                    // full text on hover.
                    Text(vm.reason).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.6))
                        .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
                        .help(vm.reason)
                }
            } else {
                Text(vm.loading ? "Reading your day…" : "Consume something today and Clem will name your archetype.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.4)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .grain(cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .onAppear { vm.loadIfStale(engine: engine) }
    }
}
