import Foundation

struct EncodingOptions: Sendable {
    var apply = false     // off = dry-run preview
    var backup = false    // write .cue.bak before overwriting
    var verbose = false   // log already-clean files too
}

/// Recovers the correct text from mis-encoded bytes by generating every reading
/// we know how to produce, scoring each for "does this look like real text", and
/// keeping the best. No upfront guess about what went wrong.
enum Mojibake {

    struct Result { let text: String; let source: String; let score: Double }

    static func best(from bytes: Data) -> Result {
        let candidates: [Result] = [
            asUTF8(bytes),
            asCP1251(bytes),
            unDoubleEncode(bytes),
        ].compactMap { $0 }

        // Ties keep the first (UTF-8 is listed first = most innocent reading).
        return candidates.max(by: { $0.score < $1.score })
            ?? Result(text: String(decoding: bytes, as: UTF8.self), source: "utf-8 (lossy)", score: 0)
    }

    private static func asUTF8(_ d: Data) -> Result? {
        guard let s = String(data: d, encoding: .utf8) else { return nil }
        return Result(text: s, source: "utf-8", score: score(s))
    }

    private static func asCP1251(_ d: Data) -> Result? {
        guard let s = String(data: d, encoding: .windowsCP1251) else { return nil }
        return Result(text: s, source: "windows-1251", score: score(s))
    }

    /// Classic double-encode: cp1251 text decoded as Latin-1 then stored as UTF-8.
    /// Reverse it. The `.isoLatin1` re-encode fails when the text holds real
    /// Cyrillic, so this only fires on the genuine mojibake signature.
    private static func unDoubleEncode(_ d: Data) -> Result? {
        guard let utf8 = String(data: d, encoding: .utf8),
              let latin1 = utf8.data(using: .isoLatin1),
              let fixed = String(data: latin1, encoding: .windowsCP1251)
        else { return nil }
        return Result(text: fixed, source: "double-encoded (cp1251→latin1→utf8)", score: score(fixed))
    }

    /// "Does this look like real Russian / Latin text?" — fraction of meaningful
    /// characters vs. decode-junk.
    private static func score(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var good = 0, bad = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0400...0x04FF:                          good += 2   // Cyrillic
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:    good += 1   // ASCII alnum
            case 0x20, 0x09, 0x0A, 0x0D:                   good += 1   // whitespace
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60:    good += 1   // ASCII punct
            case 0xFFFD:                                   bad  += 3   // replacement char
            case 0x80...0x024F:                            bad  += 2   // Latin-1 junk (Â Ã Ð …)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:     bad  += 2   // control chars
            default: break
            }
        }
        let total = good + bad
        return total == 0 ? 0 : Double(good) / Double(total)
    }
}

/// Native replacement for the .cue half of encoding_fixer.py: walk a tree for
/// .cue files, recover any that are mis-encoded, and rewrite them as UTF-8.
enum EncodingFixer {

    static func run(directory: String,
                    options: EncodingOptions,
                    emit: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async -> Int32 {

        let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            emit("❌ Directory not found: \(root.path)"); return 1
        }

        emit("🔤 Encoding Fixer (native, .cue)")
        emit(options.apply ? "✍️  apply mode" + (options.backup ? " · .bak backups" : "")
                           : "👀 dry-run (preview only — nothing written)")
        emit("")

        let cues = findCues(root)
        if cues.isEmpty { emit("❌ No .cue files found"); return 0 }
        let total = cues.count

        var fixed = 0, clean = 0, failed = 0
        for (i, cue) in cues.enumerated() {
            if Task.isCancelled { emit("\n⏹️  cancelled"); return 130 }
            defer { progress(Double(i + 1) / Double(total)) }

            guard let data = try? Data(contentsOf: cue) else {
                emit("⚠️  \(cue.lastPathComponent) — cannot read"); failed += 1; continue
            }
            let result = Mojibake.best(from: data)
            let asIsUTF8 = String(data: data, encoding: .utf8)
            let needsFix = (asIsUTF8 == nil) || (asIsUTF8! != result.text)

            if !needsFix {
                clean += 1
                if options.verbose { emit("✓ \(cue.lastPathComponent) — already UTF-8") }
                continue
            }

            emit("🔧 \(cue.lastPathComponent)  [\(result.source)]")
            for sample in cyrillicSamples(result.text, limit: 2) {
                emit("     \(sample)")
            }

            if !options.apply { fixed += 1; continue }   // dry-run counts it as a would-fix

            if options.backup {
                let bak = cue.appendingPathExtension("bak")
                if !FileManager.default.fileExists(atPath: bak.path) {
                    try? data.write(to: bak)
                }
            }
            do {
                try Data(result.text.utf8).write(to: cue)
                emit("     ✅ rewritten as UTF-8")
                fixed += 1
            } catch {
                emit("     ⚠️ write failed: \(error.localizedDescription)")
                failed += 1
            }
        }

        emit("\n" + String(repeating: "=", count: 50))
        let verb = options.apply ? "fixed" : "would fix"
        emit("📊 \(verb) \(fixed) · clean \(clean) · errors \(failed)")
        return failed == 0 ? 0 : 1
    }

    private static func findCues(_ root: URL) -> [URL] {
        var out: [URL] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension.lowercased() == "cue" { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Pull a couple of recovered lines containing Cyrillic, for the preview.
    private static func cyrillicSamples(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            if line.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                out.append(line.trimmingCharacters(in: .whitespaces))
                if out.count >= limit { break }
            }
        }
        return out
    }
}
