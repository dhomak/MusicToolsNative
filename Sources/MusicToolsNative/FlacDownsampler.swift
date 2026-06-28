import Foundation

struct FlacOptions: Sendable {
    var replace = false       // overwrite originals (via local staging + copy back)
    var outputDir = ""        // when not replacing; empty = a "downsampled" subfolder
    var recursive = true      // descend into subfolders
    var dryRun = false        // list what would convert, write nothing
}

/// Native replacement for flac_downsampler.sh. Walks for FLACs, skips anything
/// already ≤44.1kHz/16-bit, and re-encodes the rest to 44.1kHz/16-bit FLAC.
/// Every encode writes to a LOCAL temp dir first (so the NAS only sees a single
/// sequential read then a single write, never a simultaneous read+write burst),
/// then the result is copied to its destination.
enum FlacDownsampler {

    static func run(directory: String,
                    options: FlacOptions,
                    emit: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async -> Int32 {

        guard let ffmpeg = Paths.shared.tool("ffmpeg") else {
            emit("❌ ffmpeg not found. brew install ffmpeg (or build the dist app)"); return 1
        }
        guard let ffprobe = Paths.shared.tool("ffprobe") else {
            emit("❌ ffprobe not found (ships with ffmpeg)"); return 1
        }
        let env = Paths.shared.environment()
        let fm = FileManager.default

        let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            emit("❌ Directory not found: \(root.path)"); return 1
        }

        emit("🎚️  FLAC Downsampler (native) → 44.1 kHz / 16-bit")
        if options.dryRun {
            emit("👀 dry-run — listing what would convert, writing nothing")
        } else {
            emit(options.replace ? "♻️  replace originals (staged locally, copied back)"
                                 : "📂 output: " + (options.outputDir.isEmpty ? "<dir>/downsampled" : options.outputDir))
        }
        emit("")

        let files = findFlacs(root, recursive: options.recursive)
        if files.isEmpty { emit("❌ No .flac files found"); return 0 }
        let total = files.count

        // local staging dir (NOT on the source/NAS volume); only needed when writing
        let stage = fm.temporaryDirectory.appendingPathComponent("musictools-flac-\(UUID().uuidString)")
        if !options.dryRun { try? fm.createDirectory(at: stage, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: stage) }

        var done = 0, skipped = 0, converted = 0, failed = 0
        var savedBytes: Int64 = 0, pendingBytes: Int64 = 0
        for (i, file) in files.enumerated() {
            if Task.isCancelled { emit("\n⏹️  cancelled"); return 130 }
            defer { done += 1; progress(Double(done) / Double(total)) }

            let info = await probe(ffprobe, file, env: env)
            if let rate = info.rate, let bits = info.bits, rate <= 44100, bits <= 16 {
                emit("⏭️  \(file.lastPathComponent) — already \(rate)Hz/\(bits)bit")
                skipped += 1
                continue
            }
            let rateStr = info.rate.map { "\($0)Hz" } ?? "?"
            let bitsStr = info.bits.map { "\($0)bit" } ?? "?"
            let origSize = Int64((try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
            emit("🎵 \(file.lastPathComponent) — \(rateStr)/\(bitsStr) → 44100Hz/16bit  (\(human(origSize)))")

            if options.dryRun {
                pendingBytes += origSize
                converted += 1   // "would convert"
                continue
            }

            let tmp = stage.appendingPathComponent("\(UUID().uuidString).flac")
            let dur = info.duration ?? 0
            let base = Double(i)
            let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        "-i", file.path,
                        "-ar", "44100", "-sample_fmt", "s16",
                        "-compression_level", "8",
                        "-progress", "pipe:1", tmp.path]

            let (code, out) = await Subprocess.run(ffmpeg, args, env: env, onLine: { line in
                // ffmpeg -progress emits out_time_us=<microseconds>
                if dur > 0, line.hasPrefix("out_time_us=") {
                    let v = line.dropFirst("out_time_us=".count)
                    if let us = Double(v) {
                        let frac = min(max((us / 1_000_000) / dur, 0), 1)
                        progress((base + frac) / Double(total))
                    }
                }
            })
            if Task.isCancelled { failed += 1; break }
            let newSize = Int64((try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0)
            guard code == 0, newSize > 0 else {
                emit("   ⚠️ ffmpeg failed" + (out.isEmpty ? "" : ": \(out.suffix(160))"))
                try? fm.removeItem(at: tmp)
                failed += 1
                continue
            }

            // place the result
            do {
                if options.replace {
                    try placeReplacing(original: file, staged: tmp, fm: fm)
                    emit("   ✅ replaced  (\(human(origSize)) → \(human(newSize)))")
                } else {
                    let dest = try outputURL(for: file, root: root, options: options, fm: fm)
                    try copyOverwriting(from: tmp, to: dest, fm: fm)
                    emit("   ✅ \(dest.lastPathComponent)  (\(human(origSize)) → \(human(newSize)))")
                }
                savedBytes += max(0, origSize - newSize)
                converted += 1
            } catch {
                emit("   ⚠️ place failed: \(error.localizedDescription)")
                failed += 1
            }
            try? fm.removeItem(at: tmp)
        }

        emit("\n" + String(repeating: "=", count: 50))
        if options.dryRun {
            emit("📊 would convert \(converted) · skipped \(skipped)  ·  \(human(pendingBytes)) to process")
        } else {
            emit("📊 converted \(converted) · skipped \(skipped) · errors \(failed)  ·  saved \(human(savedBytes))")
        }
        return failed == 0 ? 0 : 1
    }

    private static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - placement

    /// Replace the original: copy local temp → a temp name beside the original
    /// (single NAS write), then atomically swap it in.
    private static func placeReplacing(original: URL, staged: URL, fm: FileManager) throws {
        let dir = original.deletingLastPathComponent()
        let nasTmp = dir.appendingPathComponent(".\(original.lastPathComponent).tmp-\(UUID().uuidString)")
        if fm.fileExists(atPath: nasTmp.path) { try? fm.removeItem(at: nasTmp) }
        try fm.copyItem(at: staged, to: nasTmp)
        _ = try fm.replaceItemAt(original, withItemAt: nasTmp)   // atomic on the same volume
    }

    private static func copyOverwriting(from: URL, to: URL, fm: FileManager) throws {
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.copyItem(at: from, to: to)
    }

    private static func outputURL(for file: URL, root: URL, options: FlacOptions, fm: FileManager) throws -> URL {
        if !options.outputDir.isEmpty {
            let outRoot = URL(fileURLWithPath: (options.outputDir as NSString).expandingTildeInPath)
            // preserve subfolder structure relative to the scanned root
            let rel = file.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "")
            let destDir = outRoot.appendingPathComponent(rel)
            return destDir.appendingPathComponent(file.lastPathComponent)
        }
        return file.deletingLastPathComponent()
            .appendingPathComponent("downsampled")
            .appendingPathComponent(file.lastPathComponent)
    }

    // MARK: - probe / walk

    private struct Info { var rate: Int?; var bits: Int?; var duration: Double? }

    private static func probe(_ ffprobe: URL, _ file: URL, env: [String: String]) async -> Info {
        let args = ["-v", "error", "-select_streams", "a:0",
                    "-show_entries", "stream=sample_rate,bits_per_raw_sample,bits_per_sample:format=duration",
                    "-of", "default=noprint_wrappers=1", file.path]
        let (_, out) = await Subprocess.run(ffprobe, args, env: env)
        var rate: Int?, rawBits: Int?, sampBits: Int?, dur: Double?
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let val = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "sample_rate":         rate = Int(val)
            case "bits_per_raw_sample": rawBits = Int(val)
            case "bits_per_sample":     sampBits = Int(val)
            case "duration":            dur = Double(val)
            default: break
            }
        }
        // bits_per_raw_sample is most accurate; fall back to bits_per_sample
        let bits = (rawBits ?? 0) > 0 ? rawBits : ((sampBits ?? 0) > 0 ? sampBits : nil)
        return Info(rate: rate, bits: bits, duration: dur)
    }

    private static func findFlacs(_ root: URL, recursive: Bool) -> [URL] {
        var out: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: opts) {
            for case let u as URL in en where u.pathExtension.lowercased() == "flac" {
                // don't re-process our own output folder
                if u.deletingLastPathComponent().lastPathComponent == "downsampled" { continue }
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}
