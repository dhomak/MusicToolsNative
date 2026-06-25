# Music Tools — native (pure Swift)

A SwiftUI macOS app with four native tools — no Node, no Express, no WKWebView.
The app *is* the UI; each tool runs its logic directly in Swift.

## Tools

| Panel            | Implementation               |
|------------------|------------------------------|
| FLAC Downsampler | FlacDownsampler.swift        |
| CUE Splitter     | CueSplitter.swift            |
| Lyrics Fetcher   | LyricsFetcher.swift          |
| Encoding Fixer   | EncodingFixer.swift          |

## Build

```sh
# Beta (this machine)
./scripts/build_app.sh

# Distributable arm64 (bundles ffmpeg; perl stays system)
./scripts/build_dist.sh
```

## Dev loop (no rebuild)

```sh
swift run
```

ffmpeg resolves from Homebrew. Edit a panel's controls in Swift, re-run.

## Bundle layout (distributable)

```
MusicTools.app/Contents/Resources/
  vendor/bin/arm64/ffmpeg, ffprobe  static arm64
```

## Notes / what's left

- **Perl** still comes from `/usr/bin/perl` (present on macOS, Apple-deprecated).
  To be fully self-contained, bundle perl via PAR::Packer later.
- **Theming** approximates the old cyberpunk look with dark mode + a cyan accent
  and monospaced console. To match it fully (Orbitron/Share Tech Mono, chamfered
  panels), add the font files to the bundle and a custom panel style.
- Signing / notarization / DMG: set `DEV_ID` on `build_dist.sh`, then notarize +
  staple and package with `hdiutil`/`create-dmg`.
