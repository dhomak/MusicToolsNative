import SwiftUI

struct ContentView: View {
    @State private var selection: Tool? = .flac

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
        } detail: {
            switch selection ?? .flac {
            case .flac:      FlacPanel()
            case .cueSplit:  CueSplitPanel()
            case .lyrics:    LyricsPanel()
            case .encoding:  EncodingPanel()
            }
        }
        .navigationTitle("Music Tools")
    }
}
