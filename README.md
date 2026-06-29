# Music Tools — native (pure Swift)

A SwiftUI macOS app with six music-library tools, all written in native Swift —
no Node, no Python, no Perl, no WKWebView. The app is the UI; each tool runs
inline or as a subprocess with its output streamed into a native console.

Layout: a sidebar of tools → a panel with that tool's options as native
controls → a live console.

## Tools

| Panel            | What it does |
|------------------|--------------|
| **Library Health** | Read-only audit: surfaces hi-res FLACs, missing lyrics, mis-encoded cue sheets, and files with missing tags — with pointers to the right tool to fix each issue |
| **FLAC Downsampler** | Downsample hi-res FLACs (>44.1 kHz / >16-bit) to CD-quality using bundled ffmpeg |
| **CUE Splitter** | Split a single-file album + CUE sheet into per-track FLACs |
| **Lyrics Fetcher** | Fetch and save synced/unsynced lyrics as `.lrc` sidecars |
| **Encoding Fixer** | Detect and fix mojibake in CUE sheet text (Shift-JIS → UTF-8, etc.) |

![Music Tools screenshot](docs/screenshot.png)

## Build

```sh
# Beta (this machine): uses system ffmpeg
./scripts/build_app.sh

# Distributable arm64 (bundles static ffmpeg + ffprobe; no Python/Perl)
./scripts/build_dist.sh
```

The distributable build fetches a static arm64 ffmpeg/ffprobe via npm
(`ffmpeg-ffprobe-static`) and embeds it inside the `.app`. Set `DEV_ID` to
sign with a Developer ID certificate:

```sh
DEV_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build_dist.sh
```

## Dev loop (no rebuild)

```sh
swift run
```

Edit a panel's controls in Swift and re-run — no full build needed.

## Bundle layout (distributable)

```
MusicTools.app/Contents/
  MacOS/MusicTools          universal binary
  Resources/
    AppIcon.icns
    vendor/bin/arm64/
      ffmpeg
      ffprobe
```

## Release Notes

### v1.4.2
- Version bump and clean rebuild over v1.4.1 (no code changes)

### v1.4.1
- **Library Health** now writes a complete `library-health-report.txt` to the scanned folder (or `/tmp` as fallback) — large libraries no longer get silently truncated in the console

### v1.4.0
- Added **Library Health** tool: read-only audit that surfaces hi-res FLACs, missing lyrics, mis-encoded CUE sheets, and files with missing tags

### v1.3.1
- Refreshed app icon (cleaner design, no outer glow border)

### v1.3.0
- Ported **FLAC Downsampler** to native Swift (removed bash script dependency)

## Release

```sh
./scripts/build_dist.sh
./scripts/package_dmg.sh
gh release create v1.x.0 build/MusicTools.dmg --title "v1.x.0"
```
