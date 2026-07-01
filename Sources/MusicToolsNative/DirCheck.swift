import Foundation

/// One source of truth for "is this a usable folder?" so every tool reports the
/// same way — the network-URL hint and the disconnected-disk hint that used to
/// live only in Library Health. Callers route the failure message to wherever
/// they show output (console `emit` or the health error banner).
enum DirCheck {

    /// A validated directory, or a human-readable reason it can't be used.
    /// The reason may contain newlines (a headline + a hint line).
    enum Outcome {
        case ok(URL)
        case bad(String)
    }

    static func resolve(_ directory: String) -> Outcome {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .bad("No folder selected.")
        }
        if trimmed.contains("://") {
            return .bad("“\(trimmed)” is a network URL, not a mounted folder.\nConnect the share in Finder first, then point this at its /Volumes/… path.")
        }
        let root = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return .bad("Folder not found:\n\(root.path)\nIf it’s on a network volume, the disk may be disconnected.")
        }
        guard isDir.boolValue else {
            return .bad("Not a folder:\n\(root.path)")
        }
        return .ok(root)
    }

    /// Convenience for the console tools: validate, or print the reason with a
    /// ❌ headline + indented hint lines and return nil.
    static func resolveOrEmit(_ directory: String, emit: (String) -> Void) -> URL? {
        switch resolve(directory) {
        case .ok(let url):
            return url
        case .bad(let reason):
            for (i, line) in reason.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                emit(i == 0 ? "❌ \(line)" : "   \(line)")
            }
            return nil
        }
    }
}
