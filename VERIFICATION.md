# Verification — 2026-10-02

The current running build is `9277394c63a0` at `~/swift/forceclick/build/ForceClick.app`. Git was initialized in the project root, with the previous app committed as `b3eee1f` (`first commit`). That commit preserves the baseline before the pressure-capture fix.

## Missing pressure-event diagnosis and fix

The old AppKit global monitor received ordinary clicks but zero pressure events during the same physical trackpad sequence that the new session tap captured. The tap's raw Quartz type was 29, while public `NSEvent(cgEvent:)` conversion identified pressure type 34 and stages 1 and 2. Merely adding `.pressure` to an AppKit global mask did not deliver those events on this Mac.

The app now uses a listen-only Core Graphics session tap, converts events with AppKit, and acts only on actual pressure stages. It includes gesture carriers without guessing private type/field constants, excludes keyboard/modifier input, returns events unchanged, and re-enables disabled taps. A tap interruption cancels any pending hold. The previous monitor remains for comparison and fallback; local pressure events are recorded separately.

In build `51db2eb2f421`, the live trace showed a stage-2 transition followed by activation after 0.507 seconds. Later attempts showed ordinary holds and short deep presses ending without activation. A successful Force Click capture read 208 highlighted characters through Accessibility. The user explicitly confirmed: only the long deep press opens the panel, with highlighted text. The final build adds cancellation on a system tap interruption to the same event source and trigger.

Input diagnostics are exposed in the menu bar and Settings, with a local deep-click test area and a bounded report at `~/Library/Application Support/ForceClick/pressure-diagnostics.txt`. Event-tap callbacks perform no file I/O. Reports contain event counts/stages and monitor/permission state, never key codes, positions or selected text.

## Timed Force Click trigger

- Only a stage-1-to-stage-2 transition followed by a continuous deep press of more than 0.5 seconds can open the panel. Neither an ordinary click nor a long ordinary hold qualifies.
- A timer supports steady holds that generate no additional pressure samples. Repeated samples do not restart it.
- Relaxing pressure, releasing early, or a later mouse-down cancels the pending hold. Stale events are ignored. Physical left-button state is checked before activation, including when a release callback was missed.
- Activation requires the original app to remain frontmost and Force Touch detection to remain enabled. A held click opens once, until the gesture ends.
- Settings displays the hold rule and current pressure status.
- Real timer tests passed for steady holds and cancellation. Physical Force Touch was exercised by the user while the live report recorded the event sequence and resulting capture.

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
- All 22 core regression tests passed, including granted-access capture, Copy fallback, secure-field/focus rejection, cancellation, UTF-16 selection slicing, timed pressure gating, tools, persistence, local LLM formats and automation execution. New checks verify the tap excludes keyboard events and normal Quartz clicks with numeric pressure 1.0 remain ordinary clicks.
- After restarting this build, its startup report showed Accessibility trusted, keyboard-event posting allowed, the existing certificate-bound signing requirement, and the shortcut registered.
- The pasteboard integration test skips in the restricted command runner, which denies private pasteboard access.
- Signing regression check passed: two different compiled binaries had different code hashes and the same certificate-bound signing requirement.
- An unchanged rebuild preserved the existing app signature.
- The user confirmed regular/short clicks do not trigger, and a long physical deep press opens the panel with highlighted text. The desktop testing tool's synthesized shortcut did not invoke the global hotkey, so its injected key event is not counted as an end-to-end shortcut test.

Native Look Up suppression remains the documented modular no-op. Global pressure delivery remains dependent on the app and macOS; no ordinary-click trigger or unverified suppression mechanism was introduced.
