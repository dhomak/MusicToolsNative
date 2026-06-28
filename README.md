# Music Tools — native (pure Swift)

A SwiftUI macOS app that runs the five media scripts directly — no Node, no
Express, no WKWebView, no `server.js`/`index.html`. The app *is* the UI and
spawns each script as a subprocess, streaming its output into a native console.

Layout mirrors the old web UI: a sidebar of tools → a panel with that tool's
options as native controls → a live console.

## Tools → scripts

| Panel            | Script                   | Runtime |
|------------------|--------------------------|---------|
| FLAC Downsampler | native (FlacDownsampler.swift) | Swift |
| CUE Splitter     | native (CueSplitter.swift)   | Swift   |
| Lyrics Fetcher   | native (LyricsFetcher.swift) | Swift   |
| Encoding Fixer   | native (EncodingFixer.swift) | Swift   |

`Paths.swift` builds each command + environment (PATH with bundled ffmpeg,
`PYTHONPATH=pylibs`) — the Swift equivalent of `server.js`'s `SPAWN_ENV`.

## Build

```sh
# Beta (this machine): uses system python3 / ffmpeg / perl
./scripts/build_app.sh /path/to/your/music-tools

# Distributable arm64 (bundles python + ffmpeg; perl stays system)
./scripts/build_dist.sh /path/to/your/music-tools
```

`/path/to/your/music-tools` just needs the 5 scripts (and `pylibs/`).

## Dev loop (no rebuild)

```sh
MUSIC_TOOLS_DEV_REPO=/abs/path/to/your/music-tools swift run
```

Runs against the scripts in that repo directly. Edit a panel's controls in
Swift, re-run.

## Bundle layout (distributable)

```
MusicTools.app/Contents/Resources/
  scripts/   the 5 scripts
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
- Signing / notarization / DMG: same flow as the web-wrapper version — set
  `DEV_ID` on `build_dist.sh`, then notarize + staple (see the wrapper's
  DISTRIBUTION.md), and package with `hdiutil`/`create-dmg`.
