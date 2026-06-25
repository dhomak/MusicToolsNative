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

`Paths.swift` builds each command + environment (PATH with bundled ffmpeg,
`PYTHONPATH=pylibs`).

## Build

```sh
# Beta (this machine): uses system python3 / ffmpeg / perl
./build_app.sh /path/to/your/music-tools

# Distributable arm64 (bundles python + ffmpeg; perl stays system)
./build_dist.sh /path/to/your/music-tools
```

## Dev loop (no rebuild)

```sh
MUSIC_TOOLS_DEV_REPO=/abs/path/to/your/music-tools swift run
```

Runs against the tool sources in that repo directly. Edit a panel's controls in
Swift, re-run.

## Bundle layout (distributable)

```
MusicTools.app/Contents/Resources/
  pylibs/    vendored pure-python deps
  vendor/python/arm64/bin/python3   relocatable Python + mutagen/requests/charset-normalizer
  vendor/bin/arm64/ffmpeg, ffprobe  static arm64
```

## Notes / what's left

- **Perl** still comes from `/usr/bin/perl` (present on macOS, Apple-deprecated).
  Everything else is bundled. To be fully self-contained, bundle perl via
  PAR::Packer later.
- **Theming** approximates the old cyberpunk look with dark mode + a cyan accent
  and monospaced console. To match it fully (Orbitron/Share Tech Mono, chamfered
  panels), add the font files to the bundle and a custom panel style.
- Signing / notarization / DMG: set `DEV_ID` on `build_dist.sh`, then notarize +
  staple and package with `hdiutil`/`create-dmg`.
