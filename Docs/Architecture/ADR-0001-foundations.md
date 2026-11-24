# ADR 0001: Foundations

Status: accepted · November 2026

## Context

Kirie is a native macOS editor that has to be fast, reliable in long sessions and scriptable. The product brief asks for Swift, SwiftUI and AppKit, AVFoundation, Metal and Core Image, a versioned JSON project document, and one edit engine shared by the UI, undo, the CLI, MCP and (later) AI.

## Decisions

### Platform and toolchain

- **Minimum macOS: 14.0.** The code uses the Observation framework (`@Observable`), `NSHostingView.sceneBridgingOptions`, and the async AVFoundation loading APIs. All are available from macOS 14; nothing newer is required.
- **Apple Silicon first.** The package builds for arm64. A universal build needs Xcode's build system and is not set up.
- **Swift Package Manager, no Xcode project.** The package builds and tests with only the Command Line Tools, which keeps CI simple and means there is no project file to merge. The app bundle is assembled by `Scripts/build-app.sh`. Cost: no asset catalogue and no Xcode previews; the icon is drawn in code.
- **Swift 6 language mode for the domain and persistence modules; Swift 5 mode for the modules that sit on AVFoundation, Core Image and AppKit.** Those frameworks predate strict concurrency and would need unsafe opt-outs throughout. UI state is `@MainActor`; media work runs in detached tasks.
- **No third-party dependencies.** Arguments are parsed by hand and the MCP server is implemented directly, so the build is hermetic.

### Repository layout

The brief suggests `Kirie/App`, `Features/…`, `Core/…`. SwiftPM wants `Sources/<Target>` and `Tests/<Target>`, so the modules keep the brief's names and boundaries under that layout:

| Brief | Here |
|---|---|
| ProjectDomain + CommandSystem | `Sources/ProjectDomain` |
| Persistence | `Sources/Persistence` |
| MediaServices | `Sources/MediaServices` |
| PlaybackEngine + RenderEngine | `Sources/RenderEngine` (composition building serves both) |
| ComicStudio | `Sources/ComicStudio` (image analysis) and `ProjectDomain/Comic` (model, builders, QA rules) |
| Automation | `Sources/KirieServices` (session, MCP) and `Sources/kirie` (CLI) |
| KirieApp, TimelineUI, Features | `Sources/KirieApp` |
| AIOrchestrator | not built (Phase 3) |

### Edit engine

- Every change is an `EditCommand`: a `Codable` enum whose cases carry the identifiers of anything they create, so a command log replays deterministically.
- `CommandEngine` applies commands to a copy of the project, validates the result, and only then commits. A failed command or batch changes nothing.
- Undo and redo store **patches** (`ProjectPatch`): the before and after values of the top-level components that changed, usually one timeline. They are serialisable and never closures. History is capped at 300 entries.
- Time is `RationalTime` (64-bit value over 64-bit timescale, always reduced). Floating-point seconds are never authoritative.

### Project document

A `.kirie` package: `manifest.json`, `project.json`, and folders for media, caches, snapshots and exports. JSON is pretty-printed with sorted keys so it diffs cleanly. Files are written to a temporary sibling, flushed, then renamed over the target, so a save is atomic. SQLite is used only for a rebuildable index of known projects.

### Rendering

- One `AVMutableComposition` per timeline carries video and audio media. A custom `AVVideoCompositing` class receives decoded frames and renders each output frame through `FrameRenderer`.
- `FrameRenderer` builds a Core Image graph for the frame (crop, grade, effects, fit, transform, transitions, text) and Core Image compiles it to Metal. **There are no hand-written Metal shaders yet.** The Command Line Tools do not ship the Metal shader compiler, and Core Image's built-in kernels covered Phase 1.
- Stills, text and solid colours have no composition track; a tiny generated black clip gives every composition a video track spanning its length so the compositor is still called for each frame.
- Preview (`AVPlayer`) and export (`AVAssetReader` → `AVAssetWriter` with VideoToolbox) use the same compositor and the same render model, so they produce the same picture.
- After export the file is re-opened and probed. Only a file that matches the requested duration, size, frame rate, codec and audio presence is moved into place.

### App shell

The main window is created by AppKit and hosts SwiftUI. A SwiftUI `WindowGroup` does not open a window when the app is launched by opening a document, which is the normal way to open a `.kirie` file. The timeline is a custom `NSView`.

### AI boundaries (not built)

No AI provider code exists. When it is added it must go through `EditCommand` proposals that the user approves, with secrets in the Keychain and the provider, model, cost and data sent shown before each request. The MCP server already enforces the same shape: typed commands, no shell, no raw file access, confirmation for destructive actions and exports.

### Packaging

`Scripts/build-app.sh` builds, bundles and ad-hoc signs. Developer ID signing and notarisation are scripted but need the owner's Apple credentials, so they are not run by default. The app is **not sandboxed**: it reads media where it lives and stores absolute paths. `MediaReference.bookmark` exists for a sandboxed build.

## Consequences

- Effects are limited to what Core Image provides until a Metal shader pipeline is added.
- Timeline edits rebuild the AVFoundation composition. This is fast for ordinary projects; a render cache and incremental rebuilds are future work.
- Without sandboxing, Mac App Store distribution needs additional work.
