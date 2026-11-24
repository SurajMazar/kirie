# Engineering handoff

Version 0.1.0 · November 2026

## What exists

A native macOS app, a CLI and an MCP server built from one Swift package with no third-party dependencies: about 18,000 lines of Swift plus 2,900 lines of tests.

| Module | Lines of Swift (approx.) | Role |
|---|---|---|
| ProjectDomain | 4,600 | Time, schema, commands, undo, validation, subtitles, lyric markup, Comic Studio model, QA rules, builders |
| Persistence | 700 | `.kirie` packages, atomic saves, snapshots, collect, recents index, relink |
| MediaServices | 900 | Probing, thumbnails, waveforms, beat detection, generated sample media |
| RenderEngine | 2,200 | Composition building, GPU compositor, transitions, text and lyric lettering, export, verification |
| ComicStudio | 450 | Panel detection, content bounds, contact sheets, carousel, wireframes |
| KirieServices | 1,100 | Project session, comic services, demo builder, transcription, MCP server |
| kirie | 650 | CLI |
| KirieApp | 7,550 | SwiftUI shell, AppKit timeline, inspector, Comic Studio, export |

## How to verify

```bash
Scripts/test.sh
```

```bash
Scripts/crash-recovery-test.sh 25
```

```bash
Scripts/build-app.sh
```

```bash
open dist/Kirie.app
```

## Test results

119 automated tests in 20 suites pass locally (Apple M4, macOS 26.5, Swift 6.3, Command Line Tools only). Full run: about 13 seconds.

| Layer | What is covered |
|---|---|
| Unit | Rational time and frame maths, every timeline command, command JSON round-trip, undo and redo to exact equality, batch atomicity, coalescing, history bound, validation, project codec and migration, SRT/VTT/LRC, lyric markup and word timing, snapping, panel geometry and framing, QA hash invalidation, export preset validation |
| Integration | Import → timeline → export with pixel checks on the output; subtitle import and export; comic strip → reel; lyric edit → export with timing read back from the exported frames; collect and relink |
| Golden media | Generated clips with a burned-in frame counter and sweep bar prove frame accuracy; a generated click track proves tempo and beat positions at 90, 120, 128 and 150 BPM |
| Fault | Corrupt project JSON, newer schema, missing media, invalid presets, cancelled export, interrupted save, real `kill -9` during saves, path traversal in relative paths and MCP file names, malformed subtitle input |
| Performance | 3,000-clip timeline with bounds on build, edit, save and load |
| Automation | MCP handshake, tool listing, validated edits, confirmation rules, export confinement |

The nine acceptance scenarios from the product brief:

| # | Scenario | Result |
|---|---|---|
| 1 | New Reel: 1080×1920 at 30 fps, three videos and audio, trim, split, title, caption, transition, H.264 export, verify | Pass (automated) |
| 2 | Beat-sync montage | Pass (automated) |
| 3 | Comic strip reel with unequal panels, manual correction, contact sheet, export | Pass (automated) |
| 4 | Lyric edit with markup, tapped word times, holds, export timing | Pass (automated; tap times are supplied as data, the T key itself is not driven) |
| 5 | Export lock: approve, change the image, export blocked until re-review | Pass (automated) |
| 6 | Recovery after force-quit during autosave | Pass (automated, plus `Scripts/crash-recovery-test.sh`) |
| 7 | Portable project: collect, move, reopen | Pass (automated) |
| 8 | AI copilot | Not applicable: Phase 3, not built |
| 9 | Offline privacy | Pass: there is no network code, guarded by a test |

**Not covered by automated tests:** the user interface itself. The app was launched, each workspace was opened and screenshots were inspected, but there is no UI test target (XCUITest needs Xcode, which was not installed on the build machine). Auto captions, font import, drag-and-drop, viewer handles, the panel editor's drag gestures and tap-to-time with the T key have been built but only exercised by hand or not at all. Treat them as needing a manual pass.

## Measurements

Apple M4, release build, 1080×1920 at 30 fps, H.264 at 12 Mbps:

| Operation | Result |
|---|---|
| Export, strip reel (stills, transitions, 19.3 s) | 2.8 s, about 210 frames per second |
| Export, lyric edit (stills, word-by-word lettering, audio, 17.7 s) | 2.6 s, about 204 frames per second |
| Export, three video clips with captions and audio (9 s) | 1.5 s, about 184 frames per second |
| Beat analysis of a 16 s track | 1.1 s including process start (debug build) |
| Panel detection, 1024×1536 strip | 0.14 s including process start (debug build) |
| 3,000-clip timeline: build in one batch | 1.2–2.0 s |
| 3,000-clip timeline: one edit | 10–13 ms |
| 3,000-clip timeline: save / load | about 0.1 s / 0.15 s (4.4 MB of JSON) |

Not measured: memory use over long sessions, 4K or long-GOP source playback, startup time, timeline scrolling frame rate with thousands of visible clips.

## Known limitations

- **No render cache.** Every preview frame is composed live. This is fast for stills and 1080p sources; heavy 4K multi-layer timelines have not been tried.
- **Every edit rebuilds the AVFoundation composition.** Fine at ordinary sizes; there is no incremental update.
- **HDR is not preserved.** Rendering and export are Rec. 709 SDR.
- **Effects are Core Image built-ins.** There are no custom Metal shaders, because the Metal compiler is not part of the Command Line Tools.
- **Moving several selected clips at once** is not supported; a drag moves the clip under the pointer.
- **The timeline canvas is not exposed to VoiceOver** clip by clip. The Storyboard view is the accessible alternative for the main track.
- **Reverse shuttle (J)** depends on the media allowing reverse playback.
- **Animated GIFs** import as their first frame.
- **Safe zones** are approximations of each platform's interface, not official templates.
- **Not sandboxed, ad-hoc signed.** See Docs/UserGuide/Building.md.
- **Arm64 only.**
- **The lyric styles use fonts that ship with macOS.** Import your own fonts for a closer match to a house style.

## Risks

1. **CI runners differ from the build machine.** The code was written against Swift 6.3 and the macOS 26 SDK. The workflow selects the newest Xcode on the runner; an older compiler could reject something that compiled here. Hardware HEVC encoding may be unavailable on virtual machines; that test skips itself when the encoder cannot be created.
2. **AVFoundation custom compositors are sensitive to threading.** Export and preview work in every test, but long sessions with rapid edits during playback have had no soak test.
3. **Panel detection relies on clear gutters.** Art that crosses a gutter, or borderless panels on a page-coloured background, will not split. Manual correction covers this; a learned detector would be the next step.
4. **Beat tracking is tuned on synthetic click tracks.** Real music with tempo changes or weak percussion will be less accurate, and half or double tempo confusion is possible. Markers can be removed and regenerated; a tempo-halving or doubling control would help.
5. **Undo memory.** History keeps up to 300 patches, each roughly the size of the edited timeline. Very large timelines edited heavily could hold a few hundred megabytes.

## Next milestones

1. **Manual UI pass and UI tests.** Install Xcode, add an XCUITest target for the first acceptance scenario, and fix what the pass finds.
2. **Finish the Phase 1 gaps** listed as Partial or Deferred in the feature matrix: voiceover recording, noise reduction, person cut-out with Vision, reverse and freeze frame, speed curves, caption split and merge, effect search, split-screen layouts, custom shortcuts, a history panel.
3. **Render cache and incremental composition updates**, then measure 4K.
4. **Developer ID signing and notarisation**, once credentials are available.
5. **Phase 2 Comic Studio:** character sheets, style lock, continuity-check screen, balloons, text eraser.
6. **Phase 3:** the provider-neutral AI layer on top of the existing command proposals.
