import SwiftUI

struct ContentView: View {
    @State private var selection: Tool? = .health
    @AppStorage("skin") private var skinRaw = Skin.system.rawValue
    @Environment(\.palette) private var palette

    // Owned here (not in the panel) so a scan's results survive navigating
    // away to a fix-tool and back.
    @StateObject private var healthRunner = ToolRunner()
    @StateObject private var healthModel = HealthModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Tools") {
                    ForEach(Tool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .listTint(palette)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.secondary).font(.caption)
                    Picker("Skin", selection: $skinRaw) {
                        ForEach(Skin.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .surfaceTint(palette)
            }
        } detail: {
            Group {
                switch selection ?? .health {
                case .health:    LibraryHealthPanel(runner: healthRunner, model: healthModel,
                                                     navigate: { selection = $0 })
                case .flac:      FlacPanel()
                case .cueSplit:  CueSplitPanel()
                case .lyrics:    LyricsPanel()
                case .encoding:  EncodingPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .surfaceTint(palette)
        }
        .navigationTitle("Music Tools")
    }
}
