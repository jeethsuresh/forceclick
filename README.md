# ForceClick

A native macOS menu-bar selection assistant built with Swift, AppKit and SwiftUI. No third-party packages. macOS 13 or newer; Swift 5.9 or newer. Open `Package.swift` in Xcode, or use Command Line Tools.

## Run

```sh
cd ~/swift/forceclick
./scripts/run.sh
```

The local app is `build/ForceClick.app`. It has a menu-bar icon rather than a Dock icon. `run.sh` opens a new process and the new app closes any older ForceClick process, so a rebuilt binary actually runs.

The default build creates a persistent, project-local code-signing certificate and private keychain in `.signing/`. Its designated requirement is tied to that certificate and the app identifier, rather than a changing executable hash. Keep `.signing/` between builds and exclude it from source control; the directory is private to your user. The signing script restores the original keychain search list and does not add any system certificate trust. Your own Apple signing identity can be selected with `FORCECLICK_SIGNING_IDENTITY`. The local certificate is for development on this Mac, not distribution or notarization.

If you previously enabled an ad-hoc build, remove its stale ForceClick permission entry and add the exact `build/ForceClick.app` once for the new certificate-signed app. Toggling the old entry may not refresh its signing requirement. The old switch can remain on while `AXIsProcessTrusted()` reports false for a different signature. The capture report shows the running executable, build, signing requirement and actual trust result. On macOS 27, the permission page is called **Device Control and Data Access**; earlier macOS versions call it **Accessibility**.
1. Open the app and select text elsewhere, then use Force Click or **Control–Option–Space**. If macOS has not granted access, ForceClick shows a permission screen and requests the native Accessibility prompt. Choose **Open Accessibility Settings**, enable **ForceClick** in Privacy & Security → Accessibility, then use **Check Again**. If a prior build is listed but the current build remains untrusted, remove the old entry and add `build/ForceClick.app` again. macOS requires you to grant this yourself.
2. Highlight text in TextEdit or another app, then press **Control–Option–Space**. Capture happens before the command panel opens. Unsupported applications can use manual paste in the panel once Accessibility access is granted.
3. Choose Note, Todo, Event, Define, Share, or Copy directly; these do not need a model. Escape or a click outside the panel closes it.
4. For natural-language commands, run a local server with OpenAI-compatible tool calling. Set its base URL and exact installed model name in Settings, save, and use **Test connection**. The defaults are `http://127.0.0.1:11434/v1` and `qwen3:8b`; no model/server is installed by this app. LM Studio commonly uses `http://127.0.0.1:1234/v1`. Only loopback URLs are accepted and redirects are rejected.
5. Try “make a sticky note”, “create a todo titled Review this”, or “explain this in simple terms”. A model without tool support may answer in text; use quick actions in that case.

Notes and todos are available in **Notes & todos**. Sticky notes can be edited and reopened. Events are internal todo-style records with optional dates, not real Calendar appointments. Share opens the macOS picker; you choose the destination and recipient.

## Force Touch and native Look Up

`TriggerCoordinator` observes pressure in other apps. `PressureGate` requires stage 1 followed by a continuous stage-2 deep press held for **more than 0.5 seconds**. Ordinary clicks, long ordinary holds, and shorter deep presses do nothing. Releasing the click or relaxing back to stage 1 cancels the pending hold; pressing deeply again starts a fresh 0.5-second wait. A timer fires even when steady pressure produces no further samples, checks the physical left-button state and source-app focus, and opens the panel only once per held click. Settings shows the pressure-event count and current hold status.

Global pressure delivery is **experimental and not guaranteed by AppKit across apps/macOS releases**. Test on a Force Touch trackpad in the source app. If capture fails after an accepted hold, the panel shows the actual error and a link to the capture report.

The keyboard fallback is Control–Option–Space, registered through Carbon's public hot-key API. Registration failure appears in Settings; the menu item remains available. Both the shortcut and a detected deep press read the highlighted text from the originating app and place it in the panel's selected-text box. Triggering again after selecting different text refreshes that box, even while the panel is already visible. Accessibility permission is required for cross-app capture. Input monitors refresh automatically when the grant changes. Reopening the app from Finder shows Settings; its Open command panel button captures from the last active external app.

`LookUpSuppression` is a separate replaceable interface. Its shipped `PassiveLookUpSuppression` implementation is intentionally a no-op: public global monitors cannot cancel other apps' events, and there is no verified cross-app pressure suppression mechanism here. Native Look Up may appear too. No private event constants, SIP changes, injection, or system preference changes are used. This limitation does not block the rest of the app.

Apple references: [pressure stage](https://developer.apple.com/documentation/appkit/nsevent/stage), [event monitor limitations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html).

## Automations

Settings → Automations → Add. Save settings after editing. The list starts empty.

- **executable**: absolute executable path; arguments are literal, one per line. Read selected text from the file path in `FORCECLICK_SELECTION_FILE`.
- **shortcut**: the exact saved Shortcut name. Runs `/usr/bin/shortcuts run NAME --input-path FILE`.
- **appleScript**: absolute path to an existing script file. Runs `/usr/bin/osascript SCRIPT FILE [configured arguments]`. In an `on run argv` handler, item 1 is the selection file path.

Ask the AI to run an automation by its configured name. Only configured IDs are accepted; the AI cannot supply executable paths or arbitrary shell commands. Each execution shows the configured target and asks for confirmation. Commands run as your user with a 30-second timeout; output shown is limited to 16 KB. Closing the panel stops pending AI/actions but does not undo completed actions; an already launched automation may continue until completion/timeout. Temporary input/output files are removed afterward. macOS may ask for Automation permission if a script controls another app. Only add programs/scripts you trust.

## Data and architecture

Data is atomically saved as JSON in `~/Library/Application Support/ForceClick/data.json`. It includes settings, automation definitions, notes and todos. The app does not save selection/LLM conversation history. A corrupt file is preserved and writes are blocked until repaired. Selection capture uses the source application's focused element and window, walking ancestors and a bounded set of descendants. It reads `AXSelectedText`, `AXSelectedTextRange`/`AXStringForRange`, and web text-marker ranges, and excludes secure text fields. AX messaging runs off the UI thread. For Electron apps it requests the documented `AXManualAccessibility` support. When an app provides no accessible selection, ForceClick tries its enabled Command-C menu item by Accessibility, then a keyboard Copy fallback after the invoking shortcut keys are released. It temporarily copies the selection and restores the previous clipboard, unless another clipboard operation replaced it during capture. It skips that fallback if the clipboard cannot be safely snapshotted (over 8 MB or unavailable data). Captured text is capped at 24,000 characters. Accessibility permission is required, and Settings shows whether it is granted. The app never substitutes a whole document for a selection or copies from a different frontmost app.

- `Input.swift`: Accessibility capture, hotkey, pressure state machine, suppression seam.
- `Diagnostics.swift`: last capture API results, app identity and trust state, with no selected-text contents.
- `Models.swift`: persistence, data models, schemas, tool validation.
- `LLMClient.swift`: bounded local OpenAI-compatible request/response flow, no redirects.
- `Tools.swift`: local action implementations, sticky windows, automation runner.
- `UI.swift`: session, command panel content, settings and library.
- `App.swift`: app lifecycle, menu bar and NSPanel coordination.

Each request supplies the tool schemas, time/timezone and configured automation IDs. Selected content is identified as untrusted data. The complete tool batch is validated before execution (maximum five calls); execution results, rather than model success claims, appear in the panel. Tool failures stop subsequent calls; earlier successful actions remain. This is a one-response dispatcher, not an unrestricted autonomous tool loop.

## Tests

With full Xcode selected:

```sh
./scripts/test.sh
```

For Command Line Tools installations without XCTest:

```sh
./scripts/test-portable.sh
```

The same cases cover granted-access capture, source-app Copy fallback, cancellation and secure-field/focus checks, UTF-16 selection slicing, pressure gesture transitions and real hold timers, malformed/unknown tool calls, local-only URLs, request/response formats, persistence and corrupted-data preservation, automation argument isolation, and actual executable execution. Pressure tests include the strict 0.5-second boundary, a steady hold without further samples, early release, relaxed pressure, stale events, a missed release callback, focus loss, disabled detection, and one activation per held click. The portable runner compiles the production sources directly and uses assertions.

Manual checks requiring your permissions/hardware:

- Grant Accessibility; select text in TextEdit, Safari and your editor; press Control–Option–Space and verify capture/focus/Escape.
- Click each quick action, reopen saved notes/todos, restart and verify persistence.
- Start a real tool-capable local model; test plain answers and tool calls, and stop the server to check errors.
- Verify an ordinary click and a long ordinary hold never open the panel. A short deep press must also do nothing. Hold the deeper Force Click stage for more than 0.5 seconds and verify one panel opens with highlighted text. Relax or release before the deadline and verify cancellation; inspect the pressure count/status in Settings and compare native Look Up behavior.
- Configure one automation of each type, verify input, cancel confirmation, and test a failed/slow command.

For a panel without external selection, run `open build/ForceClick.app --args --smoke-test` after quitting any running copy.

## Capture troubleshooting

Menu bar → **Capture diagnostics…**, or **Capture report** in the command panel, shows the latest attempt. The same report is written to `~/Library/Application Support/ForceClick/capture-diagnostics.txt`. It contains no highlighted text, only app identifiers, process/build identity, API error codes and character counts. A granted permission followed by a failed AX read is reported separately from an untrusted running build.

To verify that a changed binary preserves the signing identity:

```sh
./scripts/test-signing.sh
```

This signs and verifies two different temporary executables and asserts that their code hashes differ while their certificate-bound designated requirements match. It does not change macOS privacy permissions.
