import SwiftUI

/// Connectors — pull bookmarks & libraries from other services into your
/// memory. Imports are idempotent: run any connector again anytime and only
/// new items are added.
struct ConnectorsView: View {
    @EnvironmentObject var engine: Engine
    @StateObject private var center = ConnectorCenter()
    @State private var helpFor: ConnectorKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connectors").font(Theme.display(30, .medium)).foregroundStyle(Theme.ink)
                    Text("Pull your bookmarks and libraries into your memory — deduped, so you can re-run anytime and only new items are added.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.ink(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)
                .padding(.bottom, 8)

                ForEach(ConnectorKind.allCases) { kind in
                    connectorCard(kind)
                }

                HStack(spacing: 7) {
                    Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Theme.accent)
                    Text("Everything lands in chat (⌥Space), the graph and resurfacing — ask \u{201C}what was that article I bookmarked about pricing?\u{201D}")
                        .font(Theme.ui(11)).foregroundStyle(Theme.ink(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func connectorCard(_ kind: ConnectorKind) -> some View {
        let st = center.status[kind]
        return HStack(spacing: 14) {
            Image(systemName: kind.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.2)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.ink)
                    if let howTo = kind.howTo {
                        Button {
                            helpFor = kind
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("How to get this")
                        .popover(
                            isPresented: Binding(
                                get: { helpFor == kind },
                                set: { if !$0 { helpFor = nil } }
                            ),
                            arrowEdge: .bottom
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(kind.needsFile ? "How to get the file" : "How this works")
                                    .font(Theme.ui(12, .semibold))
                                Text(howTo)
                                    .font(Theme.ui(12))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .frame(width: 360)
                        }
                    }
                }
                Text(kind.blurb)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.ink(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let st {
                    if st.running {
                        Text(st.phase)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.accent.opacity(0.9))
                    } else if let summary = st.summary {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color(hex: "5Fb37e"))
                            Text(summary).font(Theme.ui(11)).foregroundStyle(Theme.ink(0.6))
                        }
                    } else if let error = st.error {
                        Text(error)
                            .font(Theme.ui(11))
                            .foregroundStyle(Color(hex: "E5533D"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            if st?.running == true {
                ProgressView().controlSize(.small)
            } else {
                Button(st?.summary != nil ? "Re-import" : kind.buttonLabel) {
                    center.run(kind, settings: engine.settings)
                }
                .buttonStyle(PillButton(bg: Theme.accent, fg: .black))
            }
        }
        .tablet(padding: 14)
    }
}
