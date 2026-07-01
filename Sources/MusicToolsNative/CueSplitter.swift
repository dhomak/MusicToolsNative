import Foundation

struct CueOptions: Sendable {
    var toRoot = true        // place final tracks in the album dir (vs ./split/)
    var deleteOrig = false   // delete source .flac + .cue after full success
    var overwrite = false    // overwrite existing finals instead of uniquifying
    var dryRun = false       // preview moves/deletes, do nothing destructive
    var recursive = true     // descend into subfolders
}

/// Pure-Swift replacement for split-cue-unicode.pl.
/// Walks a tree for .cue files and splits each CUE+FLAC album into per-track
/// FLACs (re-encoded, compression 8), driving the bundled ffmpeg/ffprobe.
enum CueSplitter {

    private struct Track { var num: Int; var title: String?; var performer: String?; var startTime: String? }
    private struct Sheet {
        var performer: String?, title: String?, file: String?, date: String?, genre: String?
        var tracks: [Track] = []
    }

    static func run(directory: String,
                    options: CueOptions,
                    emit: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async -> Int32 {

        guard let ffmpeg = Paths.shared.tool("ffmpeg") else {
            emit("❌ ffmpeg not found. Looked in: bundled vendor/bin, /opt/homebrew/bin, /usr/local/bin, /usr/bin")
            emit("   Fix: brew install ffmpeg   (or build the dist app, which bundles it)")
            return 1
        }
        guard let ffprobe = Paths.shared.tool("ffprobe") else {
            emit("❌ ffprobe not found (ships with ffmpeg — brew install ffmpeg)")
            return 1
        }
        let env = Paths.shared.environment()

        guard let root = DirCheck.resolveOrEmit(directory, emit: emit) else { return 1 }

        let cues = findCues(root, recursive: options.recursive)
        if cues.isEmpty { emit("❌ No .cue files found"); return 0 }
        emit("🎼 CUE Splitter (native)")
        emit("📁 \(cues.count) cue sheet(s)" + (options.dryRun ? "  ·  DRY RUN" : "") + "\n")

        var ok = 0, failed = 0
        for (i, cue) in cues.enumerated() {
            if Task.isCancelled { emit("\n⏹️  cancelled"); return 130 }
            emit("── \(cue.lastPathComponent) ──")
            let result = await splitAlbum(cue: cue, opt: options, ffmpeg: ffmpeg, ffprobe: ffprobe, env: env,
                                          emit: emit,
                                          albumProgress: { frac in
                                              progress((Double(i) + frac) / Double(cues.count))
                                          })
            if result { ok += 1 } else { failed += 1 }
            progress(Double(i + 1) / Double(cues.count))
            emit("")
        }

        emit(String(repeating: "=", count: 50))
        emit("📊 albums ok \(ok) · failed \(failed)")
        return failed == 0 ? 0 : 1
    }

    // MARK: - album

    private static func splitAlbum(cue: URL, opt: CueOptions,
                                   ffmpeg: URL, ffprobe: URL, env: [String: String],
                                   emit: @escaping @Sendable (String) -> Void,
                                   albumProgress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let dir = cue.deletingLastPathComponent()

        guard let data = try? Data(contentsOf: cue), let text = decodeCue(data) else {
            emit("  [ERR] cannot read/decode cue"); return false
        }
        let sheet = parseCue(text)
        guard let fileName = sheet.file else { emit("  [ERR] no FILE in cue"); return false }
        guard fileName.lowercased().hasSuffix(".flac") else {
            emit("  [SKIP] FILE is not .flac (\(fileName))"); return false
        }
        guard !sheet.tracks.isEmpty else { emit("  [ERR] no TRACK entries"); return false }

        let audio = resolveAudio(dir: dir, name: fileName)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            emit("  [ERR] audio not found: \(fileName)"); return false
        }

        // total duration via ffprobe
        let (pcode, pout) = await Subprocess.run(ffprobe,
            ["-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", audio.path], env: env)
        guard pcode == 0, let duration = Double(pout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            emit("  [ERR] ffprobe failed for \(audio.lastPathComponent)"); return false
        }

        // staging dir
        let fm = FileManager.default
        let stageDir: URL
        if opt.toRoot {
            stageDir = dir.appendingPathComponent(".split.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        } else {
            stageDir = dir.appendingPathComponent("split")
        }
        if !opt.dryRun {
            try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        }

        let albumArtist = sheet.performer ?? ""
        let albumTitle  = sheet.title ?? ""
        let date = sheet.date ?? ""
        let genre = sheet.genre ?? ""

        var staged: [URL] = []
        var allOK = true
        let n = sheet.tracks.count

        for (idx, tr) in sheet.tracks.enumerated() {
            if Task.isCancelled { allOK = false; break }
            guard let startStr = tr.startTime, let start = cueTimeToSeconds(startStr) else {
                emit("  [ERR] track \(tr.num): no start index"); allOK = false; break
            }
            // end = next track start, or album duration
            var end = duration
            if idx + 1 < sheet.tracks.count, let ns = sheet.tracks[idx + 1].startTime,
               let nsec = cueTimeToSeconds(ns) { end = nsec }
            let segdur = max(0, end - start)

            let nn = String(format: "%02d", tr.num)
            let title = tr.title ?? "Track \(nn)"
            let outName = sanitize("\(nn) - \(title).flac")
            let outURL = stageDir.appendingPathComponent(outName)

            emit("  [CUT] \(outName)  (\(fmtTime(start))–\(fmtTime(end)))")
            if opt.dryRun { staged.append(outURL); albumProgress(Double(idx + 1) / Double(n)); continue }

            var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                        "-ss", String(format: "%.3f", start),
                        "-i", audio.path,
                        "-t", String(format: "%.3f", segdur),
                        "-map_metadata", "-1",
                        "-metadata", "TITLE=\(title)",
                        "-metadata", "TRACK=\(nn)"]
            if let a = tr.performer, !a.isEmpty { args += ["-metadata", "ARTIST=\(a)"] }
            else if !albumArtist.isEmpty { args += ["-metadata", "ARTIST=\(albumArtist)"] }
            if !albumTitle.isEmpty  { args += ["-metadata", "ALBUM=\(albumTitle)"] }
            if !albumArtist.isEmpty { args += ["-metadata", "ALBUM_ARTIST=\(albumArtist)"] }
            if !date.isEmpty  { args += ["-metadata", "DATE=\(date)"] }
            if !genre.isEmpty { args += ["-metadata", "GENRE=\(genre)"] }
            args += ["-avoid_negative_ts", "make_zero",
                     "-c:a", "flac", "-compression_level", "8", outURL.path]

            let (code, out) = await Subprocess.run(ffmpeg, args, env: env,
                                                   onLine: { emit("      " + $0) })
            if Task.isCancelled { allOK = false; break }
            let size = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            if code != 0 || size <= 0 {
                emit("  [ERR] ffmpeg failed on track \(nn)" + (out.isEmpty ? "" : ": \(out.prefix(200))"))
                allOK = false; break
            }
            staged.append(outURL)
            albumProgress(Double(idx + 1) / Double(n))
        }

        if !allOK {
            if !opt.dryRun, opt.toRoot { try? fm.removeItem(at: stageDir) }   // clean partial staging
            emit("  ✗ incomplete — left no partial output")
            return false
        }

        // finalize
        if opt.toRoot {
            if opt.dryRun {
                for s in staged { emit("  [DRY] would place \(s.lastPathComponent) in album dir") }
            } else {
                for s in staged {
                    let dest = uniquePath(dir: dir, name: s.lastPathComponent, overwrite: opt.overwrite)
                    if opt.overwrite, fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    do { try fm.moveItem(at: s, to: dest); emit("  [MOVE] \(dest.lastPathComponent)") }
                    catch { emit("  [ERR] move \(s.lastPathComponent): \(error.localizedDescription)"); allOK = false }
                }
                try? fm.removeItem(at: stageDir)
            }
        } else {
            emit("  → \(staged.count) tracks in \(stageDir.lastPathComponent)/")
        }

        // delete originals on full success
        if allOK, opt.deleteOrig {
            for victim in [audio, cue] {
                if opt.dryRun { emit("  [DRY] would delete \(victim.lastPathComponent)") }
                else {
                    do { try fm.removeItem(at: victim); emit("  [DEL] \(victim.lastPathComponent)") }
                    catch { emit("  [ERR] delete \(victim.lastPathComponent): \(error.localizedDescription)") }
                }
            }
        }
        return allOK
    }

    // MARK: - cue parsing

    private static func findCues(_ root: URL, recursive: Bool) -> [URL] {
        var out: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: opts) {
            for case let u as URL in en where u.pathExtension.lowercased() == "cue" { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Decode CUE bytes, trying UTF-8 -> Windows-1251 -> Latin-1 (matches the Perl).
    private static func decodeCue(_ data: Data) -> String? {
        for enc in [String.Encoding.utf8, .windowsCP1251, .isoLatin1] {
            if let s = String(data: data, encoding: enc), !s.isEmpty { return s }
        }
        return nil
    }

    private static func parseCue(_ text: String) -> Sheet {
        var sheet = Sheet()
        var current: Int? = nil   // index into sheet.tracks
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()

            if upper.hasPrefix("REM ") {
                let rest = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let ru = rest.uppercased()
                if ru.hasPrefix("DATE ")  { sheet.date  = String(rest.dropFirst(5)).trimmingCharacters(in: .whitespaces).strippingQuotes() }
                if ru.hasPrefix("GENRE ") { sheet.genre = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces).strippingQuotes() }
            } else if upper.hasPrefix("PERFORMER ") {
                let v = quoted(line) ?? String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                if let c = current { sheet.tracks[c].performer = v } else { sheet.performer = v }
            } else if upper.hasPrefix("TITLE ") {
                let v = quoted(line) ?? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let c = current { sheet.tracks[c].title = v } else { sheet.title = v }
            } else if upper.hasPrefix("FILE ") {
                sheet.file = quoted(line)
            } else if upper.hasPrefix("TRACK ") {
                let parts = line.split(separator: " ")
                let num = parts.count >= 2 ? Int(parts[1]) ?? (sheet.tracks.count + 1) : sheet.tracks.count + 1
                sheet.tracks.append(Track(num: num, title: nil, performer: nil, startTime: nil))
                current = sheet.tracks.count - 1
            } else if upper.hasPrefix("INDEX ") {
                let parts = line.split(separator: " ")
                // INDEX 01 MM:SS:FF  — prefer 01; fall back to 00 only if 01 absent
                if parts.count >= 3, let c = current {
                    let which = String(parts[1])
                    let t = String(parts[2])
                    if which == "01" { sheet.tracks[c].startTime = t }
                    else if which == "00", sheet.tracks[c].startTime == nil { sheet.tracks[c].startTime = t }
                }
            }
        }
        return sheet
    }

    // MARK: - helpers

    private static func cueTimeToSeconds(_ t: String) -> Double? {
        let p = t.split(separator: ":")
        guard p.count == 3, let mm = Int(p[0]), let ss = Int(p[1]), let ff = Int(p[2]) else { return nil }
        return Double(mm * 60 + ss) + Double(ff) / 75.0
    }

    private static func quoted(_ line: String) -> String? {
        guard let a = line.firstIndex(of: "\"") else { return nil }
        let after = line.index(after: a)
        guard let b = line[after...].firstIndex(of: "\"") else { return nil }
        return String(line[after..<b])
    }

    /// Find the real file on disk, matching by NFC (macOS stores NFD), case-insensitive fallback.
    private static func resolveAudio(dir: URL, name: String) -> URL {
        let wantNFC = name.precomposedStringWithCanonicalMapping
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            if let exact = entries.first(where: { $0.precomposedStringWithCanonicalMapping == wantNFC }) {
                return dir.appendingPathComponent(exact)
            }
            if let ci = entries.first(where: {
                $0.precomposedStringWithCanonicalMapping.lowercased() == wantNFC.lowercased()
            }) {
                return dir.appendingPathComponent(ci)
            }
        }
        return dir.appendingPathComponent(name)
    }

    private static func sanitize(_ s: String) -> String {
        let bad = Set("/\\:*?\"<>|")
        return String(s.map { bad.contains($0) ? "_" : $0 })
    }

    private static func uniquePath(dir: URL, name: String, overwrite: Bool) -> URL {
        let first = dir.appendingPathComponent(name)
        if overwrite || !FileManager.default.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var i = 1
        while true {
            let candName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let cand = dir.appendingPathComponent(candName)
            if !FileManager.default.fileExists(atPath: cand.path) { return cand }
            i += 1
        }
    }

    private static func fmtTime(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension String {
    func strippingQuotes() -> String {
        if count >= 2, hasPrefix("\""), hasSuffix("\"") { return String(dropFirst().dropLast()) }
        return self
    }
}
