import Foundation

struct LyricsOptions: Sendable {
    var workers = 6
    var delay = 0.3
    var overwrite = false
    var preferTxt = false
    var recursive = true
}

/// Pure-Swift replacement for audio_lyrics_fetcher.py.
/// Walks a directory, reads tags natively, fetches lyrics from LRCLIB ->
/// ChartLyrics -> lyrics.ovh, and writes .lrc (synced) / .txt (plain) sidecars.
enum LyricsFetcher {

    private static let audioExts: Set<String> = ["flac", "mp3", "m4a", "mp4"]
    private static let userAgent = "music-tools-native/1.0"

    private enum Outcome: Sendable { case found, skipped, noMeta, notFound, error }

    static func run(directory: String,
                    options: LyricsOptions,
                    emit: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async -> Int32 {

        guard let root = DirCheck.resolveOrEmit(directory, emit: emit) else { return 1 }

        emit("🎼 Lyrics Fetcher (native)\n")
        let files = findAudio(root, recursive: options.recursive)
        if files.isEmpty { emit("❌ No audio files found"); return 0 }
        emit("📁 Found \(files.count) audio files")
        emit("⚙️  \(options.workers) workers · \(options.delay)s pacing\n")
        let total = files.count

        var found = 0, skipped = 0, noMeta = 0, notFound = 0, errors = 0

        await withTaskGroup(of: Outcome.self) { group in
            var it = files.makeIterator()
            let limit = max(1, options.workers)
            var inFlight = 0

            func addNext() -> Bool {
                guard !Task.isCancelled, let f = it.next() else { return false }
                group.addTask { await process(f, options, emit) }
                return true
            }

            while inFlight < limit, addNext() { inFlight += 1 }

            var done = 0
            while inFlight > 0 {
                guard let outcome = await group.next() else { break }
                inFlight -= 1
                done += 1
                switch outcome {
                case .found:    found += 1
                case .skipped:  skipped += 1
                case .noMeta:   noMeta += 1
                case .notFound: notFound += 1
                case .error:    errors += 1
                }
                progress(Double(done) / Double(total))
                if addNext() { inFlight += 1 }
            }
        }

        emit("\n" + String(repeating: "=", count: 50))
        emit("📊 found \(found) · skipped \(skipped) · no-meta \(noMeta) · not-found \(notFound) · errors \(errors)")
        return Task.isCancelled ? 130 : 0
    }

    // MARK: - per file

    private static func process(_ file: URL,
                                _ opt: LyricsOptions,
                                _ emit: @escaping @Sendable (String) -> Void) async -> Outcome {
        if Task.isCancelled { return .error }
        let base = file.deletingPathExtension()
        let lrc = base.appendingPathExtension("lrc")
        let txt = base.appendingPathExtension("txt")
        let fm = FileManager.default

        if !opt.overwrite, fm.fileExists(atPath: lrc.path) || fm.fileExists(atPath: txt.path) {
            emit("⏭️  \(file.lastPathComponent) — sidecar exists")
            return .skipped
        }

        let tags = await TagReader.read(file)
        guard let artist = tags.artist, let title = tags.title else {
            emit("⚠️  \(file.lastPathComponent) — missing artist/title")
            return .noMeta
        }

        emit("🔍 \(artist) — \(title)")
        if opt.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(opt.delay * 1_000_000_000))
        }

        guard let result = await fetch(artist: artist, title: title, preferTxt: opt.preferTxt) else {
            emit("   ❌ no lyrics found")
            return .notFound
        }

        let dest = result.synced ? lrc : txt
        do {
            try result.text.write(to: dest, atomically: true, encoding: .utf8)
            emit("   ✅ \(dest.lastPathComponent)")
            return .found
        } catch {
            emit("   ⚠️ save error: \(error.localizedDescription)")
            return .error
        }
    }

    private static func findAudio(_ root: URL, recursive: Bool) -> [URL] {
        var out: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: opts) {
            for case let u as URL in en where audioExts.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - sources

    private struct Lyrics: Sendable { let synced: Bool; let text: String }

    private static func fetch(artist: String, title: String, preferTxt: Bool) async -> Lyrics? {
        if let l = await lrclib(artist, title, preferTxt) { return l }
        if let l = await chartlyrics(artist, title) { return l }
        if let l = await ovh(artist, title) { return l }
        return nil
    }

    private struct LrclibItem: Decodable { let syncedLyrics: String?; let plainLyrics: String? }

    private static func lrclib(_ artist: String, _ title: String, _ preferTxt: Bool) async -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [.init(name: "artist_name", value: artist), .init(name: "track_name", value: title)]
        guard let url = c.url, let data = await get(url) else { return nil }
        guard let items = try? JSONDecoder().decode([LrclibItem].self, from: data),
              let first = items.first else { return nil }
        let synced = (first.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = (first.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !synced.isEmpty, !preferTxt { return Lyrics(synced: true, text: synced) }
        if !plain.isEmpty { return Lyrics(synced: false, text: plain) }
        if !synced.isEmpty { return Lyrics(synced: true, text: synced) }
        return nil
    }

    private static func chartlyrics(_ artist: String, _ title: String) async -> Lyrics? {
        var c = URLComponents(string: "http://api.chartlyrics.com/apiv1.asmx/SearchLyricDirect")!
        c.queryItems = [.init(name: "artist", value: artist), .init(name: "song", value: title)]
        guard let url = c.url, let data = await get(url),
              let lyric = LyricXMLParser.lyric(from: data), !lyric.isEmpty else { return nil }
        return Lyrics(synced: false, text: lyric)
    }

    private struct OvhResp: Decodable { let lyrics: String? }

    private static func ovh(_ artist: String, _ title: String) async -> Lyrics? {
        let a = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
        let t = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)"), let data = await get(url) else { return nil }
        guard let r = try? JSONDecoder().decode(OvhResp.self, from: data),
              let lyr = r.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyr.isEmpty else { return nil }
        return Lyrics(synced: false, text: lyr)
    }

    // MARK: - HTTP with retry/backoff

    private static func get(_ url: URL, retries: Int = 3) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        var attempt = 0
        while attempt <= retries {
            if Task.isCancelled { return nil }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return data }
                if code == 429 || (500...599).contains(code) {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 0.3 * 1_000_000_000))
                    continue
                }
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                attempt += 1
                if attempt > retries { return nil }
                try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
            }
        }
        return nil
    }
}

/// Extracts the <Lyric> element text from a ChartLyrics XML response.
private final class LyricXMLParser: NSObject, XMLParserDelegate {
    private var inLyric = false
    private var buf = ""

    static func lyric(from data: Data) -> String? {
        let d = LyricXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        let t = d.buf.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if el == "Lyric" { inLyric = true; buf = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) {
        if inLyric { buf += s }
    }
    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        if el == "Lyric" { inLyric = false }
    }
}
