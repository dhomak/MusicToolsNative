import Foundation

struct HealthOptions: Sendable {
    var recursive = true
    var checkHiRes = true   // ffprobe each FLAC for >44.1k/16-bit (slower)
    var checkLyrics = true  // audio files with no .lrc/.txt sidecar
    var checkCues = true    // .cue files not in clean UTF-8
    var checkTags = true    // audio missing artist/title
    var maxSamples = 12     // example files listed per category
}

/// Read-only audit of a music library. Writes nothing; surfaces what the other
/// tools could fix: hi-res FLACs to downsample, tracks missing lyrics,
/// mis-encoded cue sheets, and files with missing tags.
enum LibraryHealth {

    private static let audioExts: Set<String> = ["flac", "mp3", "m4a", "mp4"]

    static func run(directory: String,
                    options: HealthOptions,
                    emit: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async -> Int32 {

        let fm = FileManager.default
        let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            emit("❌ Directory not found: \(root.path)"); return 1
        }

        let ffprobe = options.checkHiRes ? Paths.shared.tool("ffprobe") : nil
        let env = Paths.shared.environment()
        if options.checkHiRes && ffprobe == nil {
            emit("⚠️  ffprobe not found — skipping the hi-res check (brew install ffmpeg)")
        }

        emit("🩺 Library Health Report")
        let (audio, cues) = scan(root, recursive: options.recursive)
        emit("📁 \(audio.count) audio file(s), \(cues.count) cue sheet(s)\n")
        if audio.isEmpty && cues.isEmpty { emit("Nothing to scan here."); return 0 }

        var hiRes: [String] = []
        var noLyrics: [String] = []
        var badCue: [String] = []
        var noTags: [String] = []
        var hiResCount = 0, noLyricsCount = 0, badCueCount = 0, noTagsCount = 0

        let totalUnits = max(1, cues.count + audio.count)
        var done = 0

        // cue sheets
        for cue in cues {
            if Task.isCancelled { emit("\n⏹️  cancelled"); return 130 }
            defer { done += 1; progress(Double(done) / Double(totalUnits)) }
            guard options.checkCues, let data = try? Data(contentsOf: cue) else { continue }
            let result = Mojibake.best(from: data)
            let asUTF8 = String(data: data, encoding: .utf8)
            if asUTF8 == nil || asUTF8! != result.text {
                badCueCount += 1
                if badCue.count < options.maxSamples {
                    badCue.append("\(rel(cue, root))  [\(result.source)]")
                }
            }
        }

        // audio files
        for file in audio {
            if Task.isCancelled { emit("\n⏹️  cancelled"); return 130 }
            defer { done += 1; progress(Double(done) / Double(totalUnits)) }
            let ext = file.pathExtension.lowercased()

            if options.checkLyrics {
                let base = file.deletingPathExtension()
                let hasLrc = fm.fileExists(atPath: base.appendingPathExtension("lrc").path)
                let hasTxt = fm.fileExists(atPath: base.appendingPathExtension("txt").path)
                if !hasLrc && !hasTxt {
                    noLyricsCount += 1
                    if noLyrics.count < options.maxSamples { noLyrics.append(rel(file, root)) }
                }
            }

            if options.checkTags {
                let tags = await TagReader.read(file)
                if tags.artist == nil || tags.title == nil {
                    noTagsCount += 1
                    if noTags.count < options.maxSamples {
                        let missing = [tags.artist == nil ? "artist" : nil, tags.title == nil ? "title" : nil]
                            .compactMap { $0 }.joined(separator: "+")
                        noTags.append("\(rel(file, root))  (no \(missing))")
                    }
                }
            }

            if options.checkHiRes, ext == "flac", let ffprobe {
                if let (rate, bits) = await probeRateBits(ffprobe, file, env: env),
                   rate > 44100 || bits > 16 {
                    hiResCount += 1
                    if hiRes.count < options.maxSamples {
                        hiRes.append("\(rel(file, root))  (\(rate)Hz/\(bits)bit)")
                    }
                }
            }
        }

        // report
        emit(String(repeating: "=", count: 50))
        section(emit, "⬆️  Hi-res FLACs (downsample candidates)", hiResCount, hiRes, options)
        section(emit, "📝 Missing lyrics", noLyricsCount, noLyrics, options)
        section(emit, "🔤 Mis-encoded cue sheets", badCueCount, badCue, options)
        section(emit, "🏷️  Missing tags", noTagsCount, noTags, options)

        emit(String(repeating: "=", count: 50))
        if hiResCount + noLyricsCount + badCueCount + noTagsCount == 0 {
            emit("✅ Everything looks healthy.")
        } else {
            emit("📊 hi-res \(hiResCount) · no-lyrics \(noLyricsCount) · bad-cue \(badCueCount) · no-tags \(noTagsCount)")
            var tips: [String] = []
            if hiResCount > 0    { tips.append("FLAC Downsampler") }
            if noLyricsCount > 0 { tips.append("Lyrics Fetcher") }
            if badCueCount > 0   { tips.append("Encoding Fixer") }
            if !tips.isEmpty { emit("💡 Run: " + tips.joined(separator: " · ")) }
        }
        return 0
    }

    // MARK: - helpers

    private static func section(_ emit: @escaping @Sendable (String) -> Void,
                                _ title: String, _ count: Int, _ samples: [String],
                                _ options: HealthOptions) {
        guard count > 0 else { emit("\(title): 0"); return }
        emit("\(title): \(count)")
        for s in samples { emit("     • \(s)") }
        if count > samples.count { emit("     … and \(count - samples.count) more") }
    }

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
