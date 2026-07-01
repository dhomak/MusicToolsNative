import SwiftUI
import AppKit

@MainActor final class HealthModel: ObservableObject {
    @Published var result: HealthResult?
    @Published var filter: HealthCategory? = nil
    @Published var search = ""
    @Published var sortOrder = [KeyPathComparator(\HealthIssue.relPath)]
}

// MARK: - Library Health  (native — LibraryHealth.swift)
struct LibraryHealthPanel: View {
    @ObservedObject var runner: ToolRunner
    @ObservedObject var model: HealthModel
    let navigate: (Tool) -> Void
    @Environment(\.palette) private var palette

    @AppStorage("health.path") private var path = ""
    @AppStorage("health.recursive") private var recursive = true
    @AppStorage("health.hires") private var hiRes = true
    @AppStorage("health.lyrics") private var lyrics = true
    @AppStorage("health.cues") private var cues = true
    @AppStorage("health.tags") private var tags = true

    private var visible: [HealthIssue] {
        var rows = model.result?.issues ?? []
        if let f = model.filter { rows = rows.filter { $0.category == f } }
        if !model.search.isEmpty { rows = rows.filter { $0.relPath.localizedCaseInsensitiveContains(model.search) } }
        return rows.sorted(using: model.sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library Health").font(.title2.bold())
                Text("Read-only audit — finds what the other tools can fix")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                PathField("Directory", text: $path)
                Toggle("Search subfolders", isOn: $recursive)
                Toggle("Hi-res FLACs to downsample (slower — probes each FLAC)", isOn: $hiRes)
                Toggle("Tracks missing lyrics", isOn: $lyrics)
                Toggle("Mis-encoded cue sheets", isOn: $cues)
                Toggle("Files missing tags", isOn: $tags)
            }

            HStack(spacing: 10) {
                Button(action: run) { Label("Scan", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .tint(palette.accent)
                    .disabled(path.isEmpty || runner.isRunning)
                Button(action: runner.cancel) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!runner.isRunning)
                Button(action: clear) { Label("Clear", systemImage: "trash") }
                    .disabled(runner.isRunning || model.result == nil)
                if let rp = model.result?.reportPath, !runner.isRunning {
                    Button { revealFile(rp) } label: { Label("Report", systemImage: "doc.text") }
                }
                Spacer()
                StatusBadge(runner: runner)
            }

            if let p = runner.progress { ProgressView(value: p).tint(palette.accent) }

            resultsArea
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var resultsArea: some View {
        if let result = model.result {
            if let err = result.error {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34)).foregroundStyle(.orange)
                    Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else if result.audio == 0 && result.cues == 0 {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No audio files or cue sheets found in this folder.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else if result.issues.isEmpty {
                Spacer()
                Label("Everything looks healthy.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.title3)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                toolbar(result)
                table
            }
        } else if !runner.isRunning {
            Spacer()
            Text("Scan a folder to see results.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        } else {
            Spacer()
        }
    }

    private func toolbar(_ result: HealthResult) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $model.filter) {
                Text("All (\(result.issues.count))").tag(HealthCategory?.none)
                ForEach(HealthCategory.allCases) { c in
                    let n = result.issues.filter { $0.category == c }.count
                    if n > 0 { Text("\(c.rawValue) (\(n))").tag(HealthCategory?.some(c)) }
                }
            }
            .labelsHidden().fixedSize()
            TextField("Filter by name…", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            if let cat = model.filter, let tool = cat.fixTool {
                Button { fix(tool) } label: {
                    Label("Fix all \(cat.rawValue)", systemImage: "wrench.and.screwdriver")
                }
            }
            Spacer()
            Text("\(visible.count) shown").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tableShape: AnyShape {
        palette.chamfer > 0
            ? AnyShape(ChamferedRectangle(chamfer: palette.chamfer))
            : AnyShape(RoundedRectangle(cornerRadius: 8))
    }

    private var table: some View {
        Table(visible, sortOrder: $model.sortOrder) {
            TableColumn("Category", value: \.category.rawValue) { issue in
                Text(issue.category.rawValue).foregroundStyle(palette.accent)
            }.width(90)
            TableColumn("File", value: \.relPath) { issue in
                Text(issue.relPath).foregroundStyle(palette.consoleText)
                    .lineLimit(1).truncationMode(.middle).help(issue.path)
            }
            TableColumn("Detail", value: \.detail) { issue in
                Text(issue.detail).foregroundStyle(palette.consoleText.opacity(0.6))
            }.width(150)
            TableColumn("Actions") { issue in
                HStack(spacing: 12) {
                    Button { revealFile(issue.path) } label: { Image(systemName: "folder") }
                        .help("Reveal in Finder").foregroundStyle(palette.accent)
                    Button { openFile(issue.path) } label: { Image(systemName: "play.circle") }
                        .help("Open / play").foregroundStyle(palette.accent)
                    if let tool = issue.category.fixTool {
                        Button { fix(tool) } label: { Image(systemName: "wrench.and.screwdriver") }
                            .help("Fix in \(tool.title)").foregroundStyle(palette.pink)
                    }
                }
                .buttonStyle(.borderless)
            }.width(110)
        }
        .scrollContentBackground(.hidden)
        .background(TransparentTableBackground(trigger: visible.count))
        .background(palette.consoleBg)
        .clipShape(tableShape)
        .overlay(
            tableShape.stroke(palette.glow ? palette.accent.opacity(0.55) : Color.primary.opacity(0.12),
                              lineWidth: 1)
        )
        .shadow(color: palette.glow ? palette.accent.opacity(0.4) : .clear, radius: palette.glow ? 6 : 0)
        .frame(minHeight: 260, maxHeight: .infinity)
    }

    // MARK: actions

    private func run() {
        model.result = nil
        model.filter = nil; model.search = ""
        let opt = HealthOptions(recursive: recursive, checkHiRes: hiRes,
                                checkLyrics: lyrics, checkCues: cues, checkTags: tags)
        let dir = path
        let m = model
        runner.runNative { _, progress in
            await LibraryHealth.run(directory: dir, options: opt, progress: progress) { res in
                Task { @MainActor in m.result = res }
            }
        }
    }

    private func revealFile(_ p: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
    private func openFile(_ p: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    private func fix(_ tool: Tool) {
        UserDefaults.standard.set(path, forKey: tool.pathKey)   // pre-fill that tool's folder
        navigate(tool)
    }

    private func clear() {
        model.result = nil
        model.filter = nil
        model.search = ""
        runner.clear()
    }
}

// MARK: - FLAC Downsampler  (native — FlacDownsampler.swift)
struct FlacPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("flac.path") private var path = ""
    @AppStorage("flac.output") private var output = ""
    @AppStorage("flac.recursive") private var recursive = true
    @State private var replace = false   // destructive — never persisted
    @State private var dryRun = false

    var body: some View {
        ToolScaffold(title: "FLAC Downsampler",
                     subtitle: "Convert FLAC to 44.1 kHz / 16-bit",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Search subfolders", isOn: $recursive)
            Toggle("Dry run (preview only)", isOn: $dryRun)
            Toggle("Replace originals (destructive)", isOn: $replace).disabled(dryRun)
            if !replace { PathField("Output directory (optional)", text: $output) }
        }
    }

    private func run() {
        let opt = FlacOptions(replace: replace, outputDir: replace ? "" : output,
                              recursive: recursive, dryRun: dryRun)
        let dir = path
        r.runNative { emit, progress in
            await FlacDownsampler.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
    }
}

// MARK: - CUE Splitter  (native — CueSplitter.swift)
struct CueSplitPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("cue.path") private var path = ""
    @AppStorage("cue.recursive") private var recursive = true
    @State private var toRoot = true
    @State private var deleteOrig = false
    @State private var overwrite = false
    @State private var dryRun = false

    var body: some View {
        ToolScaffold(title: "CUE Splitter",
                     subtitle: "Split CUE + FLAC albums into per-track files",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Search subfolders", isOn: $recursive)
            Toggle("Place tracks in album folder", isOn: $toRoot)
            Toggle("Delete originals after full success", isOn: $deleteOrig)
            Toggle("Overwrite existing files", isOn: $overwrite)
            Toggle("Dry run (preview only)", isOn: $dryRun)
        }
    }

    private func run() {
        let opt = CueOptions(toRoot: toRoot, deleteOrig: deleteOrig,
                             overwrite: overwrite, dryRun: dryRun, recursive: recursive)
        let dir = path
        r.runNative { emit, progress in
            await CueSplitter.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
    }
}

// MARK: - Lyrics Fetcher  (native — LyricsFetcher.swift)
struct LyricsPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("lyrics.path") private var path = ""
    @AppStorage("lyrics.recursive") private var recursive = true
    @State private var workers = 6.0
    @State private var delay = 0.3
    @State private var overwrite = false
    @State private var preferTxt = false

    var body: some View {
        ToolScaffold(title: "Lyrics Fetcher",
                     subtitle: "Fetch .lrc / .txt from LRCLIB, ChartLyrics, lyrics.ovh",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Search subfolders", isOn: $recursive)
            Stepper("Workers: \(Int(workers))", value: $workers, in: 1...16)
            HStack {
                Text("Delay: \(String(format: "%.1f", delay)) s").frame(width: 90, alignment: .leading)
                Slider(value: $delay, in: 0...2)
            }
            Toggle("Overwrite existing lyrics", isOn: $overwrite)
            Toggle("Prefer plain .txt over synced .lrc", isOn: $preferTxt)
        }
    }

    private func run() {
        let opt = LyricsOptions(workers: Int(workers), delay: delay,
                                overwrite: overwrite, preferTxt: preferTxt, recursive: recursive)
        let dir = path
        r.runNative { emit, progress in
            await LyricsFetcher.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
    }
}

// MARK: - Encoding Fixer  (native — EncodingFixer.swift)
struct EncodingPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("encoding.path") private var path = ""
    @AppStorage("encoding.recursive") private var recursive = true
    @State private var apply = false
    @State private var backup = false
    @State private var verbose = false

    var body: some View {
        ToolScaffold(title: "Encoding Fixer",
                     subtitle: "Repair mis-encoded .cue files (Windows-1251 / mojibake → UTF-8)",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Search subfolders", isOn: $recursive)
            Toggle("Apply changes (off = dry-run preview)", isOn: $apply)
            Toggle("Write .bak backups", isOn: $backup).disabled(!apply)
            Toggle("Verbose (log clean files too)", isOn: $verbose)
        }
    }

    private func run() {
        let opt = EncodingOptions(apply: apply, backup: backup, verbose: verbose, recursive: recursive)
        let dir = path
        r.runNative { emit, progress in
            await EncodingFixer.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
    }
}
