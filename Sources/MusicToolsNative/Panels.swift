import SwiftUI

// MARK: - Library Health  (native — LibraryHealth.swift)
struct LibraryHealthPanel: View {
    @StateObject private var r = ToolRunner()
    @AppStorage("health.path") private var path = ""
    @AppStorage("health.recursive") private var recursive = true
    @AppStorage("health.hires") private var hiRes = true
    @AppStorage("health.lyrics") private var lyrics = true
    @AppStorage("health.cues") private var cues = true
    @AppStorage("health.tags") private var tags = true

    var body: some View {
        ToolScaffold(title: "Library Health",
                     subtitle: "Read-only audit — finds what the other tools can fix",
                     runner: r, canRun: !path.isEmpty, onRun: run, revealPath: path) {
            PathField("Directory", text: $path)
            Toggle("Search subfolders", isOn: $recursive)
            Toggle("Hi-res FLACs to downsample (slower — probes each FLAC)", isOn: $hiRes)
            Toggle("Tracks missing lyrics", isOn: $lyrics)
            Toggle("Mis-encoded cue sheets", isOn: $cues)
            Toggle("Files missing tags", isOn: $tags)
        }
    }

    private func run() {
        let opt = HealthOptions(recursive: recursive, checkHiRes: hiRes,
                                checkLyrics: lyrics, checkCues: cues, checkTags: tags)
        let dir = path
        r.runNative { emit, progress in
            await LibraryHealth.run(directory: dir, options: opt, emit: emit, progress: progress)
        }
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
