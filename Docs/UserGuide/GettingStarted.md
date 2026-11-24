# Getting started

## Make a Reel

1. **New Project** (⌘N). Vertical 9:16 at 30 fps is already selected. Projects are saved in `~/Movies/Kirie` unless you choose another folder.
2. **Import** (⌘I), or drag files from Finder onto the timeline. Video and pictures join the main track; audio gets its own track.
3. **Edit.** Click a clip to select it. Drag its edges to trim, drag it to move it, press ⌘B to split at the playhead. The main track is magnetic: clips close up when you delete or shorten one.
4. **Add text** from the Text tab on the left, then drag it in the preview. **Captions** can be imported (SRT, VTT, LRC) or transcribed on your Mac from the Audio section of the inspector.
5. **Cut to the beat.** Right-click the song and choose Detect Beats, then use **Cut to beat** above the timeline.
6. **Export** (⌘E). Pick a preset and press Export. Kirie re-opens the finished file and checks it before telling you it is done.

Kirie saves after every change. The toolbar shows the state; there is no Save command. **File › Save Snapshot** (⌘S) keeps a named point you can restore from the Project inspector.

## Keyboard

| Keys | Action |
|---|---|
| Space | Play or pause |
| J, K, L | Reverse, stop, forward (L again for double speed) |
| ← → | One frame back or forward (with Shift: one second) |
| ⌘B or B | Split at the playhead |
| ⌫, ⇧⌫ | Delete, ripple delete |
| ⌘D | Duplicate |
| M | Add a marker |
| N | Snapping on or off |
| ⌘= ⌘− | Zoom the timeline (or pinch) |
| ⌘Z ⇧⌘Z | Undo, redo |

Hold ⌘ while dragging a clip to switch snapping off for that drag.

## Comic Studio

Open **Comic Studio** in the sidebar. The rail on the left is the order of work.

1. **Strip & Panels:** import a strip. Kirie measures the panels from the picture. Drag a panel to move it, drag its corner to resize it, and use the arrows to change the reading order. Each panel shows whether its framing passes: Kirie will not crop what is drawn in it.
2. **Reel Builder:** choose seconds per panel, the push-in and the transition, then **Build Reel**. The result is a normal timeline.
3. **QA Gate:** write what a stranger sees in each panel, answer the checklist, and approve. Approval records the SHA-256 of the image. If the image or the review changes afterwards, export locks again until you re-approve.
4. **Export:** video, carousel slides, contact sheets, and the song note and posting drafts.

**Lyric Studio** makes lyric edits: one picture per line, with `*word*` for a big word and `/` for a new row. Choose the song, switch **Tap with T** to Lines, press play, and tap T as each line starts.

**Montage** places stills on a time grid. Set times by hand, spread them evenly, snap them to the song's beats, or import a `times.json`.

## Songs you do not own

Mark a commercial song as **Commercial (add in the app)** in the inspector or the Media Library. It still plays in the preview so you can time your cuts, but it is left out of the export. Kirie writes a song note next to the video so you know which track and section to add when you post.

## If something goes wrong

- **Media offline:** the file was moved. Use **Relink…**; Kirie suggests the moved file by its content.
- **The project will not open:** Kirie falls back to the newest snapshot inside the project automatically and tells you.
- **Export failed or was cancelled:** no file is left behind and the project is unchanged.
