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

## Release

```sh
./scripts/build_dist.sh
hdiutil create -volname "MusicTools" -srcfolder build/MusicTools.app -ov -format UDZO build/MusicTools.dmg
gh release create v1.x.0 build/MusicTools.dmg --title "v1.x.0"
```
