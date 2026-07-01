import Foundation

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case health, flac, cueSplit, lyrics, encoding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .health:    return "Library Health"
        case .flac:      return "FLAC Downsampler"
        case .cueSplit:  return "CUE Splitter"
        case .lyrics:    return "Lyrics Fetcher"
        case .encoding:  return "Encoding Fixer"
        }
    }

    var systemImage: String {
        switch self {
        case .health:    return "stethoscope"
        case .flac:      return "waveform"
        case .cueSplit:  return "scissors"
        case .lyrics:    return "text.quote"
        case .encoding:  return "character.cursor.ibeam"
        }
    }

    /// UserDefaults key for each tool's directory field (matches its @AppStorage).
    var pathKey: String {
        switch self {
        case .health:    return "health.path"
        case .flac:      return "flac.path"
        case .cueSplit:  return "cue.path"
        case .lyrics:    return "lyrics.path"
        case .encoding:  return "encoding.path"
        }
    }

    /// UserDefaults key for each tool's "search subfolders" toggle.
    var recursiveKey: String {
        switch self {
        case .health:    return "health.recursive"
        case .flac:      return "flac.recursive"
        case .cueSplit:  return "cue.recursive"
        case .lyrics:    return "lyrics.recursive"
        case .encoding:  return "encoding.recursive"
        }
    }
}
