# Verification — 2026-10-02

The current running build is `9c6cd271e419` at `~/swift/forceclick/build/ForceClick.app`. It includes the timed Force Click trigger below. The user previously confirmed selection capture works in build `ebe7fccc1659`; the new hardware hold behavior still requires a physical trackpad test.

## Timed Force Click trigger

- Only a stage-1-to-stage-2 transition followed by a continuous deep press of more than 0.5 seconds can open the panel. Neither an ordinary click nor a long ordinary hold qualifies.
- A timer supports steady holds that generate no additional pressure samples. Repeated samples do not restart it.
- Relaxing pressure, releasing early, or a later mouse-down cancels the pending hold. Stale events are ignored. Physical left-button state is checked before activation, including when a release callback was missed.
- Activation requires the original app to remain frontmost and Force Touch detection to remain enabled. A held click opens once, until the gesture ends.
- Settings displays the hold rule and current pressure status.
- Real timer tests passed for steady holds and cancellation. The desktop testing tool cannot synthesize physical Force Touch, so cross-app pressure delivery and the physical hold have not been verified here.

## Permission and signing diagnosis

Before the fix, System Settings showed ForceClick enabled, while the same running build reported `AXIsProcessTrusted() == false` and keyboard-event posting denied. The old ad-hoc designated requirement was tied to a changing code hash. Merely toggling the stale entry off and on did not repair the denial.

The build now uses a persistent certificate and isolated keychain in the project's private `.signing/` directory. Its designated requirement is bound to the app identifier and signing certificate. The signing setup restores the original keychain search list and does not install a system trust anchor. After the user authorized refreshing the grant, the stale ForceClick entry was removed and the exact current bundle added again. ForceClick's own Settings then reported Accessibility granted.

A subsequent changed build and restart retained the grant: the running app's startup report showed Accessibility trusted, keyboard-event posting allowed, the same certificate-bound signing requirement, and the Control–Option–Space shortcut registered. This verifies actual permission continuity across the additional build, beyond merely checking signature strings.

## Capture and dismissal changes

- AX queries run off the UI thread with bounded messaging and traversal.
- Capture reads only the source app's selection, including focused-window descendants, web text-marker ranges, and UTF-16 text ranges.
- Electron's documented AXManualAccessibility switch is requested when supported.
- Copy fallback first tries the enabled Command-C menu action. Synthetic Copy waits for invocation keys to be released and targets the original app.
- Delayed mouse-down callbacks from the initiating Force Click cannot cancel their own capture. Later outside clicks dismiss the panel and cancel capture; Escape/close also cancels pending capture.
- Permission transitions reinstall the global input monitors. The run script starts a fresh app process, which replaces older copies.
- Capture reports identify the running build, source app and API failures without recording selected-text contents.

## Checks completed

- Release build completed; normal macOS signature validation reported valid on disk and satisfying its designated requirement.
- All 20 core regression tests passed, including granted-access capture, Copy fallback, secure-field/focus rejection, cancellation, UTF-16 selection slicing, timed pressure gating, tools, persistence, local LLM formats and automation execution.
- After restarting this build, its startup report showed Accessibility trusted, keyboard-event posting allowed, the existing certificate-bound signing requirement, and the shortcut registered.
- The pasteboard integration test skips in the restricted command runner, which denies private pasteboard access.
- Signing regression check passed: two different compiled binaries had different code hashes and the same certificate-bound signing requirement.
- An unchanged rebuild preserved the existing app signature.
- The user confirmed the prior live selection-capture flow works. The desktop testing tool's synthesized shortcut did not invoke the global hotkey, so its injected key event is not counted as an end-to-end shortcut or hardware Force Touch test.

Native Look Up suppression remains the documented modular no-op. Global pressure delivery remains dependent on the app and macOS; no ordinary-click trigger or unverified suppression mechanism was introduced.
