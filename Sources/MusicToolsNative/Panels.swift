import SwiftUI

// MARK: - FLAC Downsampler  (flac_downsampler.sh)
struct FlacPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("flac.path") private var path = ""
    @AppStorage("flac.output") private var output = ""
    @State private var replace = false   // destructive — never persisted

    var body: some View {
        ToolScaffold(title: "FLAC Downsampler",
                     subtitle: "Convert FLAC to 44.1 kHz / 16-bit",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Replace originals (destructive)", isOn: $replace)
            if !replace { PathField("Output directory (optional)", text: $output) }
        }
    }

    private func run() {
        var flags: [String] = []
        if replace { flags += ["--replace", "--yes"] }
        var tail = [path]
        if !replace, !output.isEmpty { tail.append(output) }
        r.run(Paths.shared.bash(script: "flac_downsampler.sh", args: flags + tail))
    }
}

// MARK: - CUE Splitter  (native — CueSplitter.swift)
struct CueSplitPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("cue.path") private var path = ""
    @State private var toRoot = true
    @State private var deleteOrig = false
    @State private var overwrite = false
    @State private var dryRun = false

    var body: some View {
        ToolScaffold(title: "CUE Splitter",
                     subtitle: "Split CUE + FLAC albums into per-track files",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Place tracks in album folder", isOn: $toRoot)
            Toggle("Delete originals after full success", isOn: $deleteOrig)
            Toggle("Overwrite existing files", isOn: $overwrite)
            Toggle("Dry run (preview only)", isOn: $dryRun)
        }
    }

    private func run() {
        let opt = CueOptions(toRoot: toRoot, deleteOrig: deleteOrig,
                             overwrite: overwrite, dryRun: dryRun)
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
    @State private var workers = 6.0
    @State private var delay = 0.3
    @State private var overwrite = false
    @State private var preferTxt = false

    var body: some View {
        ToolScaffold(title: "Lyrics Fetcher",
                     subtitle: "Fetch .lrc / .txt from LRCLIB, ChartLyrics, lyrics.ovh",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
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
                                overwrite: overwrite, preferTxt: preferTxt)
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
    @State private var apply = false
    @State private var backup = false
    @State private var verbose = false

    var body: some View {
        ToolScaffold(title: "Encoding Fixer",
                     subtitle: "Repair mis-encoded .cue files (Windows-1251 / mojibake → UTF-8)",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Apply changes (off = dry-run preview)", isOn: $apply)
            Toggle("Write .bak backups", isOn: $backup).disabled(!apply)
            Toggle("Verbose (log clean files too)", isOn: $verbose)
        }
    }

    private func run() {
        let opt = EncodingOptions(apply: apply, backup: backup, verbose: verbose)
        let dir = path
        r.runNative { emit, progress in
            await EncodingFixer.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
    }
}
