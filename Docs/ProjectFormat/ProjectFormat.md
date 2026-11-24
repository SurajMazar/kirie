# The `.kirie` project format

A project is a folder with the extension `.kirie` (macOS shows it as a single file). Schema version: **1**.

```
Name.kirie/
  manifest.json     summary for listing projects without parsing everything
  project.json      the whole editable document (authoritative)
  Media/            media copied in by "Collect media"
  Fonts/            imported fonts
  Proxies/          reserved
  Thumbnails/       regenerable previews
  Waveforms/        regenerable waveform caches
  Cache/            regenerable render cache
  Snapshots/        restorable copies of project.json
  ComicStudio/      rejected attempts and other comic artefacts
  Exports/          default export location
```

Only `project.json`, `Media/`, `Fonts/`, `Snapshots/` and `ComicStudio/` hold work. Everything else can be deleted and is rebuilt.

## project.json

Pretty-printed UTF-8 JSON with sorted keys, so two saves of the same project are byte-identical and changes diff cleanly. Top-level fields:

| Field | Meaning |
|---|---|
| `schemaVersion` | Format version. A newer version than the app understands is refused, never downgraded. |
| `id`, `name`, `createdAt`, `modifiedAt` | Identity and dates (ISO 8601 with milliseconds, UTC). |
| `canvas` | `width`, `height`, `frameRate` (`numerator`/`denominator`), `colorSpace`, `background`. |
| `assets` | Media references and probed metadata. Source bytes are never stored here. |
| `sequences` | Timelines: tracks (bottom to top), clips, markers. |
| `activeSequenceID` | The timeline shown in the editor. |
| `comic` | Comic Studio state, when used: synopsis, strips and panels, QA answers, approvals, montage, lyric edit. |
| `exportPresetID` | Last export preset. |

### Time

Every time is an exact rational written as a string, `"value/timescale"`, in seconds: `"3/2"` is 1.5 s and `"1001/30000"` is one frame at 29.97 fps. A plain number of seconds is also accepted when reading.

### Media references

```json
"reference": {
  "absolutePath": "/Users/me/Movies/clip.mov",
  "relativePath": "Media/clip.mov",
  "fileSize": 1048576,
  "fingerprint": "sha256 of the size and the first and last megabyte"
}
```

`relativePath` is used first and must stay inside the package. `fingerprint` lets Kirie recognise a file that was moved or renamed.

### Clips

A clip has a `kind` (`video`, `image`, `audio`, `text`, `solid`), `start` and `duration` on the timeline, `sourceStart` and `speed` into its media, a `transform`, optional `keyframes`, an optional `transitionIn`, `audio` settings, `color`, `filters`, `blendMode`, and optional `mask`, `chromaKey` and `text`.

Invariants (checked on every edit and on open):

- The main track is contiguous from zero; a clip overlaps the previous one only by its transition.
- Clips on other tracks do not overlap each other.
- A video or audio clip never reads past the end of its media.
- Identifiers are unique.

### Approvals

A strip's approval stores `imageHash` (SHA-256 of the image file) and `qaHash` (SHA-256 of the panels, notes and checklist answers at approval time). Whether export is allowed is recomputed from these every time; it is not a stored flag.

## Saving

Each file is written to a temporary sibling, flushed to disk, and renamed over the target. A reader sees either the old complete file or the new complete file. Leftover temporary files from a killed process are removed on open.

If `project.json` cannot be read, Kirie opens the newest readable snapshot and says so.

## Migrations

`ProjectMigrator` upgrades raw JSON one version at a time before decoding. Version 0 (pre-release drafts with no version field) migrates to version 1.

## Commands

Edits are expressed as commands, each a JSON object with one key:

```json
{"splitClip": {"clipID": "…", "at": "3/1", "newClipID": "…"}}
```

The same shape is used by `kirie apply`, by the MCP `apply_commands` tool and in memory by the app. New objects carry their identifiers in the command.
