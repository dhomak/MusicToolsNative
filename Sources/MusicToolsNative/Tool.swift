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
}
