import Foundation

struct HealthOptions: Sendable {
    var recursive = true
    var checkHiRes = true
    var checkLyrics = true
    var checkCues = true
    var checkTags = true
}

enum HealthCategory: String, Sendable, CaseIterable, Identifiable {
    case hiRes    = "Hi-res"
    case noLyrics = "No lyrics"
    case badCue   = "Bad cue"
    case noTags   = "No tags"
    var id: String { rawValue }
    /// Which tool fixes this category (nil = no automated fix yet).
    var fixTool: Tool? {
        switch self {
        case .hiRes:    return .flac
        case .noLyrics: return .lyrics
        case .badCue:   return .encoding
        case .noTags:   return nil
        }
    }
}

struct HealthIssue: Identifiable, Sendable {
    let id = UUID()
    let category: HealthCategory
    let path: String      // absolute — for reveal / open
    let relPath: String   // relative to scanned root — for display
    let detail: String    // rate/bits, detected encoding, missing fields
}

struct HealthResult: Sendable {
    var issues: [HealthIssue] = []
    var audio = 0
    var cues = 0
    var reportPath: String?
    var error: String?     // set when the folder couldn't be scanned at all
}

/// Read-only audit. Returns structured rows (for a sortable/filterable table)
/// and also writes a full text report next to the scanned folder.
enum LibraryHealth {

    private static let audioExts: Set<String> = ["flac", "mp3", "m4a", "mp4"]

    static func run(directory: String,
                    options: HealthOptions,
                    progress: @escaping @Sendable (Double) -> Void,
                    report: @escaping @Sendable (HealthResult) -> Void) async -> Int32 {

        let fm = FileManager.default
        let root: URL
        switch DirCheck.resolve(directory) {
        case .ok(let url): root = url
        case .bad(let reason): report(HealthResult(error: reason)); return 1
        }

        let ffprobe = options.checkHiRes ? Paths.shared.tool("ffprobe") : nil
        let env = Paths.shared.environment()
        let (audio, cues) = scan(root, recursive: options.recursive)

        var issues: [HealthIssue] = []
        let totalUnits = max(1, cues.count + audio.count)
        var done = 0

        for cue in cues {
            if Task.isCancelled { report(HealthResult(issues: issues, audio: audio.count, cues: cues.count, reportPath: nil)); return 130 }
            defer { done += 1; progress(Double(done) / Double(totalUnits)) }
            guard options.checkCues, let data = try? Data(contentsOf: cue) else { continue }
            let result = Mojibake.best(from: data)
            let asUTF8 = String(data: data, encoding: .utf8)
            if asUTF8 == nil || asUTF8! != result.text {
                issues.append(.init(category: .badCue, path: cue.path, relPath: rel(cue, root), detail: result.source))
            }
        }

        for file in audio {
            if Task.isCancelled { report(HealthResult(issues: issues, audio: audio.count, cues: cues.count, reportPath: nil)); return 130 }
            defer { done += 1; progress(Double(done) / Double(totalUnits)) }
            let ext = file.pathExtension.lowercased()

            if options.checkLyrics {
                let base = file.deletingPathExtension()
                let has = fm.fileExists(atPath: base.appendingPathExtension("lrc").path)
                       || fm.fileExists(atPath: base.appendingPathExtension("txt").path)
                if !has { issues.append(.init(category: .noLyrics, path: file.path, relPath: rel(file, root), detail: "")) }
            }

            if options.checkTags {
                let tags = await TagReader.read(file)
                if tags.artist == nil || tags.title == nil {
                    let missing = [tags.artist == nil ? "artist" : nil, tags.title == nil ? "title" : nil]
                        .compactMap { $0 }.joined(separator: "+")
                    issues.append(.init(category: .noTags, path: file.path, relPath: rel(file, root), detail: "no \(missing)"))
                }
            }

            if options.checkHiRes, ext == "flac", let ffprobe {
                if let (rate, bits) = await probeRateBits(ffprobe, file, env: env), rate > 44100 || bits > 16 {
                    issues.append(.init(category: .hiRes, path: file.path, relPath: rel(file, root), detail: "\(rate)Hz/\(bits)bit"))
                }
            }
        }

        let reportPath = issues.isEmpty ? nil
            : writeReport(root: root, audio: audio.count, cues: cues.count, issues: issues)
        report(HealthResult(issues: issues, audio: audio.count, cues: cues.count, reportPath: reportPath))
        return 0
    }

    // MARK: - report file

    private static func writeReport(root: URL, audio: Int, cues: Int, issues: [HealthIssue]) -> String? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var text = "Library Health Report\n"
        text += "Directory: \(root.path)\n"
        text += "Generated: \(df.string(from: Date()))\n"
        text += "Scanned:   \(audio) audio file(s), \(cues) cue sheet(s)\n"
        for cat in HealthCategory.allCases {
            let items = issues.filter { $0.category == cat }
            text += "\n========== \(cat.rawValue): \(items.count) ==========\n"
            for i in items { text += i.relPath + (i.detail.isEmpty ? "" : "  (\(i.detail))") + "\n" }
        }
        let name = "library-health-report.txt"
        for url in [root.appendingPathComponent(name),
                    FileManager.default.temporaryDirectory.appendingPathComponent(name)] {
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { return url.path }
        }
        return nil
    }

    // MARK: - scan helpers

    private static func rel(_ url: URL, _ root: URL) -> String {
        let p = url.path
        if p.hasPrefix(root.path) {
            let r = String(p.dropFirst(root.path.count))
            return r.hasPrefix("/") ? String(r.dropFirst()) : r
        }
        return url.lastPathComponent
    }

    private static func scan(_ root: URL, recursive: Bool) -> (audio: [URL], cues: [URL]) {
        var audio: [URL] = [], cues: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: opts) {
            for case let u as URL in en {
                let ext = u.pathExtension.lowercased()
                if ext == "cue" { cues.append(u) }
                else if audioExts.contains(ext) { audio.append(u) }
            }
        }
        return (audio.sorted { $0.path < $1.path }, cues.sorted { $0.path < $1.path })
    }

    private static func probeRateBits(_ ffprobe: URL, _ file: URL, env: [String: String]) async -> (Int, Int)? {
        let args = ["-v", "error", "-select_streams", "a:0",
                    "-show_entries", "stream=sample_rate,bits_per_raw_sample,bits_per_sample",
                    "-of", "default=noprint_wrappers=1", file.path]
        let (_, out) = await Subprocess.run(ffprobe, args, env: env)
        var rate: Int?, rawBits: Int?, sampBits: Int?
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "sample_rate":         rate = Int(kv[1].trimmingCharacters(in: .whitespaces))
            case "bits_per_raw_sample": rawBits = Int(kv[1].trimmingCharacters(in: .whitespaces))
            case "bits_per_sample":     sampBits = Int(kv[1].trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        guard let r = rate else { return nil }
        let bits = (rawBits ?? 0) > 0 ? rawBits! : ((sampBits ?? 0) > 0 ? sampBits! : 16)
        return (r, bits)
    }
}
