# Command line and MCP

The `kirie` tool works on the same projects as the app, through the same edit commands. It is built by `swift build --product kirie` and is also inside the app at `Kirie.app/Contents/Helpers/kirie`.

Output on stdout is JSON: `{"ok": true, "result": …}` or `{"ok": false, "error": {"code", "message"}}`. Progress goes to stderr as `progress <percent>`. Add `--compact` for one-line JSON.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error |
| 2 | Usage |
| 3 | Not found (project, clip, media) |
| 4 | Rejected by validation, or needs `--confirm` |
| 5 | Export locked by the QA gate |
| 6 | Export failed |
| 130 | Cancelled (Ctrl-C). The partial file is removed. |

## Examples

Create a project, import media and export:

```bash
kirie new ~/Movies/Kirie/Trip --preset vertical --fps 30
```

```bash
kirie import ~/Movies/Kirie/Trip.kirie ~/Desktop/footage
```

```bash
kirie export ~/Movies/Kirie/Trip.kirie --preset reels-h264
```

Edit with typed commands (see `kirie timeline` for identifiers):

```bash
kirie apply Trip.kirie --command '{"splitClip": {"clipID": "…", "at": "3/1", "newClipID": "…"}}'
```

`--dry-run` validates without changing anything. Commands that remove content need `--confirm`.

Comic strip to reel:

```bash
kirie comic add-strip Strip.kirie "strip.png" --number 42 --slug "beach day"
```

```bash
kirie comic status Strip.kirie
```

```bash
kirie comic reel Strip.kirie --vary
```

Run `kirie help` for the full list.

## MCP server

```bash
kirie mcp ~/Movies/Kirie/Trip.kirie
```

This serves the Model Context Protocol over stdio for one explicitly chosen project. To use it from Claude Code:

```bash
claude mcp add kirie -- /Applications/Kirie.app/Contents/Helpers/kirie mcp "$HOME/Movies/Kirie/Trip.kirie"
```

Tools:

| Tool | Does |
|---|---|
| `project_info`, `timeline`, `qa_status`, `command_reference` | Read-only inspection |
| `apply_commands` | Validates and applies typed edit commands as one undoable step, then saves. `dry_run` checks first. Removing content needs `confirm_destructive: true`. |
| `undo` | Undoes the last edit made in this server session |
| `build_strip_reel` | Builds the panel-by-panel reel timeline |
| `export` | Renders to the project's `Exports` folder and verifies the file. Needs `confirm: true`. Blocked while the QA export lock is engaged. |

The server has no shell, no arbitrary file access and no way to edit the project file directly. Edits are attributed to the client in the command history.
