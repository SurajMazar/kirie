# Feature matrix

Status of every feature in the Kirie feature map, as of version 0.1.0.

- **Done**: usable in the app (or CLI where noted) and covered by automated tests or verified by running it.
- **Partial**: part of it works; what is missing is stated.
- **Deferred**: designed, not built. No control for it exists, or it is labelled as planned.
- **Blocked**: needs something outside this repository.

A feature is never marked Done because a screen for it exists.

## Phase 1: Core

### Projects and media library

| Feature | Status | Notes |
|---|---|---|
| Project hub | Done | Grid and list, search, recents, archive, poster frames. Folders are not built. |
| Canvas presets at creation | Done | 9:16, 4:5, 1:1, 16:9, 21:9, custom; frame rate and colour space. |
| Drag-and-drop import | Done | Finder to library or timeline, file picker, whole folders. Failures are reported per file. |
| Autosave and version history | Done | Atomic save after every change; named and automatic snapshots; restore. No visual compare. |
| Relink missing media | Done | Suggestions by name, size and content fingerprint; length is checked before accepting. |

### Timeline and core editing

| Feature | Status | Notes |
|---|---|---|
| Magnetic main track | Done | |
| Multi-lane timeline | Done | Overlay, audio, text, caption tracks with filmstrips and waveforms. No adjustment tracks. |
| Split, trim, delete, duplicate | Done | Replace-in-place is not built. |
| Storyboard view | Done | Reorder by drag or buttons; keyboard and VoiceOver friendly. |
| Frame-accurate scrubbing | Done | Arrow keys, J/K/L, timecode entry. Reverse shuttle depends on the media supporting reverse playback. |
| Speed: constant | Done | 0.1× to 100×, pitch preserved. Speed curves are Deferred. |
| Rotate, flip, crop | Done | Reverse and freeze frame are Deferred. |
| Snapping | Done | Playhead, clip edges, markers, beats, timeline ends; ⌘ disables while dragging. |
| Markers | Done | Standard, beat and bar markers, drawn with different shapes. |
| Undo with history | Partial | Unlimited undo and redo up to 300 steps; no history panel. |
| Clip transform | Done | Inspector and direct manipulation in the viewer (move, scale). |
| Canvas background | Done | Canvas colour, blurred fill or flat colour behind a clip. Gradient and image backgrounds are not built. |
| Detach and link audio | Done | |
| Close all gaps | Done | Per track, from the timeline's context menu. |

### Keyframes and animation

| Feature | Status | Notes |
|---|---|---|
| Keyframe properties | Partial | Position, scale, rotation, opacity, volume, with easing. Effect and mask parameters are not keyframable. |
| In, out and combo animations | Partial | Text animations and clip entrances exist; no out or combo presets. |
| Ken Burns | Done | Start and end framing through keyframes; used by the Comic Studio builders. |

### Text, titles and captions

| Feature | Status | Notes |
|---|---|---|
| Auto captions | Partial | Implemented with Apple Speech, forced on-device, with word timing. Not covered by automated tests because it needs a permission prompt; verify by hand. |
| Animated caption styles | Done | Karaoke highlight, pop, bounce, typewriter, fade. |
| Caption editor | Partial | Edit text in a list, retime on the timeline. No split or merge. |
| Text styling | Partial | Font, size, colour, outline, shadow, background box, alignment, caps. No gradient fill or curved text. |
| Font import | Partial | TTF and OTF copied into the project and registered; shows the font's licence text. Not covered by automated tests. |
| Title templates | Partial | Five presets. |
| Platform safe zones | Done | Reels, TikTok, Shorts overlays. The zones are approximations. |
| SRT, VTT and LRC | Done | Import and export, including word timing. |

### Audio and music

| Feature | Status | Notes |
|---|---|---|
| Music and SFX library | Deferred | No bundled library. |
| Beat detection | Done | Tempo, beats and bar starts, on-device. |
| Cut to beat | Done | Every 1, 2, 4 or 8 beats; undoable. |
| Volume, fades, audio keyframes | Done | Per clip and per track; up to 400%. |
| Noise reduction | Deferred | |
| Waveforms | Done | |
| Voiceover recording | Deferred | |

### Effects, filters and transitions

| Feature | Status | Notes |
|---|---|---|
| Filter library | Partial | Twelve looks with intensity. No before/after split view. |
| Video effects | Partial | Blur, pixellate, bloom, halftone, ink outline, posterize, VHS, paper grain. No fisheye, bounce, blackout or shake. |
| Effects search | Deferred | |
| Transitions | Done | Dissolve, dip, flash, push, slide, wipe, zoom, iris, whip, spin, glitch. |
| Comic transitions | Done | Page fold, polaroid drop, ink splash, panel slide. |
| Stickers, GIFs, emoji, shapes | Partial | Your own PNGs as overlays; emoji in text. No library, shapes, or animated GIF playback (first frame only). |

### Colour and compositing

| Feature | Status | Notes |
|---|---|---|
| Basic adjustments | Done | Exposure, contrast, highlights, shadows, saturation, warmth, tint, vignette, sharpen. |
| Chroma key | Done | Hue key with tolerance and softness. No spill suppression. |
| Remove background | Deferred | |
| Overlays and picture-in-picture | Done | |
| Masks | Partial | Rectangle, ellipse, linear, mirror, with feather. No heart, star or pen masks. |
| Blend modes | Done | Eleven modes. |
| Split-screen layouts | Deferred | Possible by hand with crop and position. |

### Comic Studio

| Feature | Status | Notes |
|---|---|---|
| Numbered comic projects and synopsis | Done | `NNN_name` convention. |
| Strip import with panel detection | Done | Measured from the image; manual correction and reading order; right-to-left option. |
| Panel-by-panel strip reel | Done | Default 3.6 s per panel, gentle push-in, full strip at the end. |
| Never cut off a character | Done | Content bounds, margin check, automatic fallback, manual focal point, PASS/FAIL per panel. |
| Layout wireframes | Done | 2 to 5 panels, image plus text description. |
| Music video / photo montage | Done | Time grid, section presets, snap to beats, `times.json` import. |
| Per-cut transition picker | Done | |
| Lyric edit mode | Done | |
| Lyric styles | Done | Verse, stack, chorus, block. Uses fonts that ship with macOS. |
| Lyric markup | Done | `*word*`, `/`, shrink-to-fit, shared baseline. |
| Word timing | Done | Even spread, 0.25–0.6 s hold, per-word overrides. |
| Shots inside a line | Done | New picture or close-up; ghost, hard, flash, shake, whoosh. |
| Lettering polish | Partial | Jitter on text only, stripe, chorus flash, punch-in. Emoji render through the system font but are not specifically tested. |
| Tap-to-time | Done | T key for lines or for the words of one line; LRC import. |
| Cover or contain fit | Done | |
| Signature end card | Done | |
| Contact sheet QA | Done | Strip contact sheet in the QA gate; reel contact sheet from the Export page. |
| Silent export with a song note | Done | |
| Carousel export | Done | 1080×1350 slides. |

### Publishing, export and platform

| Feature | Status | Notes |
|---|---|---|
| No watermark | Done | |
| Cover designer | Partial | Save any frame as a PNG. No title overlay or grid-crop preview. |
| Safe-zone preview | Done | |
| Up to 4K | Partial | Presets to 3840×2160; frame rates to 60. SDR only: HDR sources are converted. |
| Codecs | Partial | H.264, HEVC, ProRes 422. No ProRes 4444 or alpha. |
| Platform presets | Done | Reels, TikTok, Shorts, feed 4:5, square, YouTube 1080p and 4K, ProRes master. |
| Export a range or frame | Partial | Range and still PNG in the app; audio-only WAV from the CLI. No selected-clips or image-sequence export. |
| Hardware encoding | Done | VideoToolbox through AVAssetWriter. |
| Native Apple Silicon app | Done | |
| Custom shortcuts | Deferred | Shortcuts are fixed. |
| Trackpad gestures | Partial | Pinch to zoom, scroll. No two-finger scrub. |
| Light and dark mode | Done | |
| Signed and notarised | Blocked | Ad-hoc signed. Developer ID signing and notarisation need the owner's Apple Developer credentials. |
| Real-time preview | Partial | GPU compositor with a quality setting. No render cache. |
| GPU effect graph | Done | Core Image on Metal. |
| Crash recovery | Done | Tested with real `kill -9` during saves. |
| On-device ML | Partial | Speech captions run on-device. Framing uses content bounds; a Vision saliency helper exists but is not wired into the app. Beat and panel detection are signal processing, not ML. |
| Copyright guard | Done | |
| Local-first | Done | No network code; guarded by a test. |
| Open JSON project format | Done | |

## Phase 2: Creator

| Feature | Status | Notes |
|---|---|---|
| QA gate | Done | Per-panel notes and status, configurable checklist, soft-pass word lint. |
| Export lock | Done | Hash of the image and of the review; stale approvals never authorise export. |
| Rejects and attempt limit | Done | |
| Continuity checker | Partial | Rendering is built and tested; there is no screen for marking regions yet. |
| Caption, pinned comment and song shortlist | Done | Stored as drafts. Kirie does not post. |
| MCP server | Done | Read-only inspection, typed edits, undo, strip reel, export. |
| Command-line renderer | Done | |
| Comic texture presets | Partial | Halftone and paper grain effects. No ink boil. |
| Everything else in Phase 2 | Deferred | Speed curves, optical-flow slow motion, compound clips, pro trim tools, adjustment layers, attribute paste, multiple-timeline tools, auto reframe, motion tracking, proxies, smart bins, screen and camera recording, teleprompter, text-based editing, filler-word removal, translation, text to speech, ducking, voice tools, EQ and loudness, stabilisation, LUTs, HSL and curves, templates, brand kit, publishing, export queue batching, character sheets, style lock, balloons, text eraser, webtoon scroll, VoiceOver for the timeline canvas, licence tracker. |

## Phase 3: AI and Phase 4: Moonshot

All Deferred. No AI provider, generation or copilot code exists, and the app shows no control for them. The architecture reserves the boundary (typed command proposals, approval before applying, secrets in the Keychain); see the architecture decision record.

Instagram publishing and insights are additionally **Blocked** on access to the platform's API.
