import Foundation
import AVFoundation

struct AudioTags: Sendable {
    let artist: String?
    let title: String?
}

/// Reads artist/title without Python or external tools:
///   FLAC  -> parse the VORBIS_COMMENT metadata block directly
///   MP3   -> ID3 via AVFoundation common metadata
///   M4A/MP4 -> iTunes atoms via AVFoundation common metadata
enum TagReader {

    static func read(_ url: URL) async -> AudioTags {
        if url.pathExtension.lowercased() == "flac" { return readFLAC(url) }
        return await readAVAsset(url)
    }

    // MARK: AVFoundation (mp3 / m4a / mp4)

    private static func readAVAsset(_ url: URL) async -> AudioTags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else {
            return AudioTags(artist: nil, title: nil)
        }
        var artist: String?, title: String?
        for item in items {
            guard let key = item.commonKey else { continue }
            if key == .commonKeyArtist {
                artist = (try? await item.load(.stringValue)) ?? artist
            } else if key == .commonKeyTitle {
                title = (try? await item.load(.stringValue)) ?? title
            }
        }
        return AudioTags(artist: clean(artist), title: clean(title))
    }

    // MARK: FLAC Vorbis comments

    private static func readFLAC(_ url: URL) -> AudioTags {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return AudioTags(artist: nil, title: nil)
        }
        defer { try? fh.close() }

        // "fLaC" magic
        guard let magic = try? fh.read(upToCount: 4), Array(magic) == Array("fLaC".utf8) else {
            return AudioTags(artist: nil, title: nil)
        }

        // Walk metadata blocks: header = 1 byte (last-flag<<7 | type) + 3 bytes BE length.
        while true {
            guard let h = try? fh.read(upToCount: 4), h.count == 4 else { break }
            let hb = [UInt8](h)
            let isLast = (hb[0] & 0x80) != 0
            let type = hb[0] & 0x7f
            let len = Int(hb[1]) << 16 | Int(hb[2]) << 8 | Int(hb[3])

            if type == 4 {  // VORBIS_COMMENT
                guard let block = try? fh.read(upToCount: len), block.count == len else { break }
                return parseVorbis([UInt8](block))
            }
            guard let cur = try? fh.offset() else { break }
            try? fh.seek(toOffset: cur + UInt64(len))
            if isLast { break }
        }
        return AudioTags(artist: nil, title: nil)
    }

    /// Vorbis comment block: vendor (u32le len + bytes), then u32le count,
    /// then `count` entries of (u32le len + "KEY=value" UTF-8). Lengths are
    /// little-endian here (unlike the big-endian FLAC block header).
    private static func parseVorbis(_ b: [UInt8]) -> AudioTags {
        var i = 0
        func u32le() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let v = Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24
            i += 4
            return v
        }
        guard let vendorLen = u32le() else { return AudioTags(artist: nil, title: nil) }
        i += vendorLen
        guard let count = u32le() else { return AudioTags(artist: nil, title: nil) }

        var artist: String?, title: String?
        var n = 0
        while n < count {
            n += 1
            guard let clen = u32le(), clen >= 0, i + clen <= b.count else { break }
            let s = String(decoding: b[i..<i+clen], as: UTF8.self)
            i += clen
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let val = String(s[s.index(after: eq)...])
            if key == "ARTIST", artist == nil { artist = val }
            else if key == "TITLE", title == nil { title = val }
        }
        return AudioTags(artist: clean(artist), title: clean(title))
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
