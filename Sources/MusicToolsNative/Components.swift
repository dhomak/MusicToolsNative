import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Native folder picker.
func chooseDirectory(start: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    let expanded = (start as NSString).expandingTildeInPath
    if !start.isEmpty, FileManager.default.fileExists(atPath: expanded) {
        panel.directoryURL = URL(fileURLWithPath: expanded)
    }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

/// Directory field with a Browse button and folder drag-and-drop.
struct PathField: View {
    let label: String
    @Binding var text: String
    init(_ label: String, text: Binding<String>) { self.label = label; self._text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("/path/to/folder  (or drop a folder here)", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    if let p = chooseDirectory(start: text) { text = p }
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var path: String?
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) { path = url.path }
                else if let url = item as? URL { path = url.path }
                if let p = path { DispatchQueue.main.async { text = p } }
            }
            return true
        }
    }
}

struct StatusBadge: View {
    @ObservedObject var runner: ToolRunner
    var body: some View {
        Group {
            if runner.isRunning {
                Label("running", systemImage: "circle.dotted").foregroundStyle(Theme.accent)
            } else if let c = runner.exitCode {
                if c == 0 {
                    Label("done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("exit \(c)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else {
                Text("idle").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

struct ConsoleView: View {
    @ObservedObject var runner: ToolRunner
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(runner.lines.enumerated()), id: \.offset) { idx, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.consoleText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(10)
            }
            .background(Theme.consoleBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: runner.lines.count) { _ in
                if let last = runner.lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 240)
    }
}

/// Shared panel chrome: title + tool controls + (optional) progress + actions + console.
struct ToolScaffold<Controls: View>: View {
    let title: String
    let subtitle: String
    @ObservedObject var runner: ToolRunner
    let canRun: Bool
    let onRun: () -> Void
    var revealPath: String? = nil
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) { controls() }

            HStack(spacing: 10) {
                Button(action: onRun) { Label("Run", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canRun || runner.isRunning)
                Button(action: runner.cancel) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!runner.isRunning)
                Button(action: runner.clear) { Label("Clear", systemImage: "trash") }
                    .disabled(runner.isRunning || runner.lines.isEmpty)
                if let rp = revealPath, !rp.isEmpty, !runner.isRunning,
                   FileManager.default.fileExists(atPath: rp) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rp)])
                    } label: { Label("Reveal", systemImage: "folder") }
                }
                Spacer()
                StatusBadge(runner: runner)
            }

            if let p = runner.progress {
                ProgressView(value: p).tint(Theme.accent)
            }

            ConsoleView(runner: runner)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
