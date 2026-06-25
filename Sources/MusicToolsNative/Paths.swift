import Foundation

/// Resolves where the FLAC script and bundled ffmpeg live, and builds the
/// command + environment. Only one script remains (flac_downsampler.sh); the
/// other tools are native Swift. ffmpeg/ffprobe are the only bundled binaries.
///
/// Bundle layout (Contents/Resources):
///   scripts/flac_downsampler.sh
///   vendor/bin/arm64/{ffmpeg,ffprobe}
///
/// Dev override: MUSIC_TOOLS_DEV_REPO=/path/to/music-tools  (script at its root)
struct Cmd {
    let exe: URL
    let args: [String]
    let env: [String: String]
    let cwd: URL?
}

final class Paths {
    static let shared = Paths()

    let scriptsDir: URL
    let vendorDir: URL

    private init() {
        let env = ProcessInfo.processInfo.environment
        if let repo = env["MUSIC_TOOLS_DEV_REPO"] {
            let r = URL(fileURLWithPath: repo, isDirectory: true)
            scriptsDir = r
            vendorDir  = r.appendingPathComponent("vendor")
        } else {
            let res = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            scriptsDir = res.appendingPathComponent("scripts")
            vendorDir  = res.appendingPathComponent("vendor")
        }
    }

    private var binDir: URL { vendorDir.appendingPathComponent("bin/arm64") }

    /// Base environment: minimal-PATH-safe (a Finder-launched app gets a sparse
    /// PATH), so prepend the bundled ffmpeg dir + Homebrew + system locations.
    private func baseEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let parts = [binDir.path, "/opt/homebrew/bin", "/opt/homebrew/sbin",
                     "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     env["PATH"] ?? ""]
        env["PATH"] = parts.filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    func bash(script: String, args: [String]) -> Cmd {
        let p = scriptsDir.appendingPathComponent(script).path
        return Cmd(exe: URL(fileURLWithPath: "/bin/bash"), args: [p] + args,
                   env: baseEnv(), cwd: scriptsDir)
    }

    /// Resolve a tool binary (ffmpeg/ffprobe): bundled arm64 first, then
    /// Homebrew, then system. Returns nil if not found anywhere.
    func tool(_ name: String) -> URL? {
        let candidates = [
            binDir.appendingPathComponent(name),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Environment for native subprocess calls (same PATH treatment as scripts).
    func environment() -> [String: String] { baseEnv() }
}
