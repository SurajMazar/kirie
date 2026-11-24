# Privacy, security and media rights

## Privacy

- Kirie needs no account and makes **no network connections**. The source contains no networking code; a test in the suite fails if any is added.
- There is no analytics, telemetry or crash upload.
- Captions use Apple's Speech framework with on-device recognition required. If on-device recognition is not available for a language, Kirie reports that instead of sending audio to a server.
- Beat detection, panel detection and framing analysis run on your Mac.
- No cloud AI provider is integrated. When one is added it will be opt-in, with the provider, model, cost and the data being sent shown before each request, and credentials kept in the Keychain.

## Permissions and entitlements

The app is **not sandboxed** and requests no entitlements. It reads media from wherever you import it and stores the path in the project.

| Permission | When | Why |
|---|---|---|
| Speech Recognition | First use of Auto captions | On-device transcription |
| Files and folders | When you import from a protected folder | macOS asks on the app's behalf |

A sandboxed build would need user-selected file access and security-scoped bookmarks. The project format already has a field for bookmarks; the code that creates them is not written.

## Untrusted input

Project files, caption files, timing files and media are treated as untrusted:

- Sizes are bounded (projects 256 MB, caption files 8 MB) and image and video dimensions are limited to 16,384 pixels.
- Parsers are tolerant and return typed errors; malformed input does not crash the app.
- A media path inside a project cannot point outside the project folder.
- A project saved by a newer version is refused, not partially read.

## Automation

The MCP server and CLI expose a fixed set of operations. Edits must decode into Kirie's command types and pass the same validation as edits made in the app. Commands that remove content and exports need an explicit confirmation flag. MCP export output is confined to the project's `Exports` folder. There is no tool for running shell commands or reading arbitrary files.

## Media rights

Each audio item has a rights status: not declared, owned, licensed, or commercial without rights.

- Audio marked **commercial** plays in the preview so you can time cuts to it, but it is never written into an exported file. Kirie exports without it and writes a `…song-note.txt` beside the video naming the song and section to add on the platform.
- Imported fonts show their embedded licence or copyright text. Checking that you may use a font is your responsibility.
- Exports never carry a watermark or Kirie branding.
- Comic Studio's QA approval records the hash of the approved image. If the image changes, the approval stops authorising export.
