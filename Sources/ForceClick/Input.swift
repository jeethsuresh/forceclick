import AppKit
import ApplicationServices
import Carbon

struct AXProbeResult: Sendable {
    var text: String?
    var secure = false
    var details: [String] = []
}

// Injected in regression tests so the complete capture path can run without TCC.
@MainActor struct SelectionEnvironment {
    var trusted: () -> Bool
    var frontmostPID: () -> pid_t?
    var appName: (pid_t) -> String
    var probe: (pid_t) async -> AXProbeResult
    var copy: (pid_t) async throws -> String?
    var record: (String) -> Void
    static var live: Self {
        Self(trusted: { AXIsProcessTrusted() },
             frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             appName: { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "Unknown" },
             probe: { pid in await Task.detached(priority: .userInitiated) { AXSelectionProbe(processID: pid).read() }.value },
             copy: { try await CopySelectionFallback().read(from: $0) },
             record: { CaptureDiagnostics.shared.record($0) })
    }
}

@MainActor struct SelectionReader {
    var environment = SelectionEnvironment.live
    func capture(from processID: pid_t?) async throws -> SelectionContext {
        guard environment.trusted() else { throw AppError.message("macOS reports that this running copy of ForceClick has no Accessibility access.") }
        guard let processID, processID != ProcessInfo.processInfo.processIdentifier else {
            throw AppError.message("No source app is active. Highlight text in another app, then use ⌃⌥Space.")
        }
        let probe = await environment.probe(processID)
        try Task.checkCancellation()
        probe.details.forEach(environment.record)
        guard !probe.secure else { throw AppError.message("Secure text fields are not captured.") }
        if let text = probe.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment.record("Captured through Accessibility: \(text.count) characters")
            return context(text, from: processID)
        }
        guard environment.frontmostPID() == processID else {
            throw AppError.message("The source app lost focus before its selection could be copied. Highlight the text again and retry.")
        }
        if let text = try await environment.copy(processID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            environment.record("Captured through Copy: \(text.count) characters")
            return context(text, from: processID)
        }
        throw AppError.message("\(environment.appName(processID)) did not provide highlighted text through Accessibility or Copy. The capture report has the API results.")
    }
    private func context(_ text: String, from processID: pid_t) -> SelectionContext {
        SelectionContext(text: String(text.prefix(24_000)), application: environment.appName(processID))
    }
}

// All AX messaging runs off the UI thread, with time and node bounds. Never use
// another app's system-wide focused element as the source selection.
struct AXSelectionProbe {
    let processID: pid_t
    func read() -> AXProbeResult {
        var result = AXProbeResult()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.12)
        // Electron documents this switch for third-party assistive software.
        // Other applications reject it harmlessly. Do not use AXEnhancedUserInterface.
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        result.details.append("AXManualAccessibility: \(manual.rawValue)")
        var value: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        result.details.append("Source AXFocusedUIElement: \(focusError.rawValue)")
        var roots: [AXUIElement] = []
        if let focused = element(value) { roots.append(focused) }
        // Some apps expose focus only through the system-wide element. Accept it
        // only if its owning PID is the source captured at trigger time.
        if roots.isEmpty {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.12)
            let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
            if let focused = element(value) {
                var owner: pid_t = 0
                AXUIElementGetPid(focused, &owner)
                result.details.append("System focus: \(error.rawValue), owner pid \(owner)")
                if owner == processID { roots.append(focused) }
            }
        }
        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue)
        result.details.append("Source AXFocusedWindow: \(windowError.rawValue)")
        let window = element(windowValue)
        var visited: [AXUIElement] = []
        // Read focus and its ancestors first. A web selection is commonly on an
        // enclosing AXWebArea, while focus is on a link or static-text node.
        if var current = roots.first {
            for _ in 0..<10 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if inspect(current, result: &result, visited: &visited) { return result }
                guard let parent = element(attribute(current, kAXParentAttribute as CFString)) else { break }
                current = parent
            }
        }
        if let window { roots.append(window) }
        var queue = roots.map { ($0, 0) }
        var index = 0
        while index < queue.count, visited.count < 90, ProcessInfo.processInfo.systemUptime < deadline {
            let (current, depth) = queue[index]; index += 1
            if inspect(current, result: &result, visited: &visited) { return result }
            guard depth < 7 else { continue }
            // Use standard AX child attributes; never capture an entire value as
            // a substitute for a selection.
            let children = (attribute(current, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            queue.append(contentsOf: children.prefix(50).map { ($0, depth + 1) })
        }
        result.details.append("Selection search finished: \(visited.count) elements, no text")
        return result
    }
    private func inspect(_ element: AXUIElement, result: inout AXProbeResult, visited: inout [AXUIElement]) -> Bool {
        guard !visited.contains(where: { CFEqual($0, element) }) else { return false }
        visited.append(element)
        AXUIElementSetMessagingTimeout(element, 0.08)
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? "unknown"
        let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String
        if subrole == "AXSecureTextField" {
            // A secure field on the focused path blocks clipboard fallback. An
            // unrelated password field elsewhere in the window is just skipped.
            if visited.count == 1 { result.secure = true; return true }
            return false
        }
        var selected: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        if visited.count <= 10 || role == "AXWebArea" {
            result.details.append("\(role) AXSelectedText: \(error.rawValue), length \((selected as? String)?.count ?? 0)")
        }
        if let text = selected as? String, !text.isEmpty { result.text = text; return true }
        if let rangeValue = attribute(element, kAXSelectedTextRangeAttribute as CFString), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 {
                var textValue: CFTypeRef?
                let rangeError = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &textValue)
                result.details.append("\(role) AXStringForRange: \(rangeError.rawValue), selection length \(range.length)")
                if let text = textValue as? String, !text.isEmpty { result.text = text; return true }
                if let value = attribute(element, kAXValueAttribute as CFString) as? String,
                   let text = Self.substring(value, range: range) { result.text = text; return true }
            }
        }
        // The web text-marker attributes are declared in Apple's macOS 27 SDK
        // and also supported by earlier WebKit/Chromium accessibility providers.
        if let marker = attribute(element, "AXSelectedTextMarkerRange" as CFString) {
            var textValue: CFTypeRef?
            let markerError = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, marker, &textValue)
            result.details.append("\(role) AXStringForTextMarkerRange: \(markerError.rawValue)")
            if let text = textValue as? String, !text.isEmpty { result.text = text; return true }
        }
        return false
    }
    static func substring(_ value: String, range: CFRange) -> String? {
        let string = value as NSString
        guard range.location >= 0, range.length > 0, range.location <= string.length,
              range.length <= string.length - range.location else { return nil }
        return string.substring(with: NSRange(location: range.location, length: range.length))
    }
    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

@MainActor struct CopySelectionFallback {
    func read(from processID: pid_t) async throws -> String? {
        let log = CaptureDiagnostics.shared
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
        // Find the menu command by its standard Command-C equivalent, rather
        // than an English title. AXPress is unaffected by physical hotkey keys.
        let copyItem = await Task.detached(priority: .userInitiated) { CopyMenuCommand.find(in: processID) }.value
        try Task.checkCancellation()
        if copyItem == nil {
            guard CGPreflightPostEventAccess() else {
                log.record("Copy fallback: keyboard-event posting denied")
                return nil
            }
            // Carbon's hotkey callback arrives on key-down. Never post Cmd-C
            // while Ctrl/Option/Space from the invocation are still held.
            for _ in 0..<60 {
                try Task.checkCancellation()
                if !Self.triggerKeysHeld { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Self.triggerKeysHeld else {
                log.record("Copy fallback: trigger keys were not released")
                return nil
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
        let pasteboard = NSPasteboard.general
        guard let original = PasteboardSnapshot.capture(pasteboard) else {
            log.record("Copy fallback: clipboard could not be safely saved")
            return nil
        }
        let marker = "ForceClick-\(UUID().uuidString)"
        pasteboard.clearContents()
        guard pasteboard.setString(marker, forType: .string) else {
            original.restore(to: pasteboard)
            log.record("Copy fallback: clipboard write failed")
            return nil
        }
        let markerChange = pasteboard.changeCount
        var ownedChange = markerChange
        defer {
            // A different clipboard operation may have occurred during an await.
            // Do not overwrite that newer content on cancellation or timeout.
            if pasteboard.changeCount == ownedChange { original.restore(to: pasteboard) }
        }
        var usedMenu = false
        if let copyItem {
            let error = await Task.detached(priority: .userInitiated) { AXUIElementPerformAction(copyItem.element, kAXPressAction as CFString) }.value
            log.record("Copy menu AXPress: \(error.rawValue)")
            usedMenu = error == .success
        }
        if !usedMenu {
            guard CGPreflightPostEventAccess(), !Self.triggerKeysHeld,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return nil }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(processID); up.postToPid(processID)
            log.record("Posted Command-C to source pid \(processID)")
        }
        for _ in 0..<28 {
            try await Task.sleep(nanoseconds: 25_000_000)
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }
            if pasteboard.changeCount != markerChange {
                ownedChange = pasteboard.changeCount
                guard let copied = pasteboard.string(forType: .string), copied != marker,
                      !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return copied
            }
        }
        log.record("Copy fallback: no clipboard response within 700 ms")
        return nil
    }
    private static var triggerKeysHeld: Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty
            || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Space))
    }
}

// AXUIElement is an immutable cross-process reference; use only on detached AX
// workers, never concurrently mutate it. Wrapping avoids sending arbitrary CF data.
private struct CopyMenuCommand: @unchecked Sendable {
    let element: AXUIElement
    static func find(in pid: pid_t) -> Self? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var queue = [(value as! AXUIElement, 0)]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var index = 0
        while index < queue.count, index < 160, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(element, 0.06)
            var character: CFTypeRef?, modifiers: CFTypeRef?, enabled: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &character) == .success,
               (character as? String)?.lowercased() == "c",
               AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers) == .success,
               (modifiers as? NSNumber)?.intValue == 0,
               AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
               (enabled as? NSNumber)?.boolValue == true { return Self(element: element) }
            guard depth < 4 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] { queue.append(contentsOf: children.prefix(70).map { ($0, depth + 1) }) }
        }
        return nil
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    static func capture(_ pasteboard: NSPasteboard) -> Self? {
        var copied: [[NSPasteboard.PasteboardType: Data]] = []
        var totalBytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= 8_000_000 else { return nil }
                values[type] = data
            }
            copied.append(values)
        }
        return Self(items: copied)
    }
    func restore(to pasteboard: NSPasteboard) {
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

// Public AppKit monitors cannot consume another application's pressure events.
// A future experimentally verified suppressor can be injected without changing the pipeline.
protocol LookUpSuppression { var status: String { get }; func start(); func stop() }
struct PassiveLookUpSuppression: LookUpSuppression {
    let status = "Native Look Up is not suppressed. Global pressure delivery varies by app/macOS."
    func start() {}
    func stop() {}
}

// AppKit's global monitor does not promise delivery of pressure/gesture
// events. Observe the session stream directly and let public NSEvent
// conversion identify pressure; do not guess private CGEvent type/field IDs.
@MainActor final class PressureEventTap {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onEvent: (NSEvent) -> Void = { _ in }
    var onInterruption: () -> Void = {}
    var isActive: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    static var eventMask: CGEventMask {
        // Include gesture carriers without assuming their Quartz type equals
        // the NSEvent type. Never subscribe to keyboard/modifier events.
        let excluded: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel]
        return excluded.reduce(CGEventMask.max) { $0 & ~(CGEventMask(1) << $1.rawValue) }
    }
    func start() {
        stop()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: Self.eventMask,
                                          callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            // The source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<PressureEventTap>.fromOpaque(userInfo).takeUnretainedValue().receive(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: pointer) else {
            PressureDiagnostics.shared.setTapStatus("Session event tap could not be installed; check macOS input access")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            PressureDiagnostics.shared.setTapStatus("Could not create the event-tap run-loop source")
            return
        }
        self.port = port; runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        PressureDiagnostics.shared.setTapStatus(isActive ? "Session listen-only tap installed and enabled" : "Session tap installed but disabled")
    }
    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onInterruption() // Missing pressure samples cannot qualify as a continuous hold.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            PressureDiagnostics.shared.setTapStatus("Session tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "system disable")")
            return
        }
        let converted = NSEvent(cgEvent: event)
        PressureDiagnostics.shared.quartzEvent(type: type, converted: converted)
        if let converted { onEvent(converted) }
    }
    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        port = nil; runLoopSource = nil
    }
}

@MainActor final class TriggerCoordinator: ObservableObject {
    @Published var pressureEvents = 0
    @Published var shortcutStatus = "Starting…"
    @Published var pressureStatus = "Waiting for Force Click"
    private var global: Any?
    private var localRelease: Any?
    private let pressureTap = PressureEventTap()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var gate = PressureGate()
    private var holdTask: Task<Void, Never>?
    private var holdID = UUID()
    private var armedDeadline: TimeInterval?
    private var gesturePID: pid_t?
    // Injection points allow the actual timed trigger to be regression-tested
    // without synthesizing hardware events or requesting additional access.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var mouseIsDown: () -> Bool = { CGEventSource.buttonState(.hidSystemState, button: .left) }
    var enabled: () -> Bool = { true }
    var trigger: (Bool, pid_t?, TimeInterval) -> Void = { _, _, _ in }
    let suppression: LookUpSuppression = PassiveLookUpSuppression()
    func start() {
        PressureDiagnostics.shared.reset()
        suppression.start()
        pressureTap.onEvent = { [weak self] event in self?.input(event) }
        pressureTap.onInterruption = { [weak self] in
            guard let self else { return }
            self.releasePressure(at: self.clock())
        }
        pressureTap.start()
        let inputMask: NSEvent.EventTypeMask = [.pressure, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        global = NSEvent.addGlobalMonitorForEvents(matching: inputMask) { [weak self] event in
            PressureDiagnostics.shared.event(event, source: "AppKit global")
            if self?.pressureTap.isActive == false { self?.input(event) }
        }
        localRelease = NSEvent.addLocalMonitorForEvents(matching: inputMask) { [weak self] event in
            PressureDiagnostics.shared.event(event, source: "AppKit local")
            if event.type == .leftMouseUp || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self?.releasePressure(at: event.timestamp)
            }
            return event
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let user else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let coordinator = Unmanaged<TriggerCoordinator>.fromOpaque(user).takeUnretainedValue()
                coordinator.trigger(false, NSWorkspace.shared.frontmostApplication?.processIdentifier, event.map(GetEventTime) ?? ProcessInfo.processInfo.systemUptime)
            }
            return noErr
        }, 1, &spec, pointer, &handler)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x46434C4B, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        shortcutStatus = status == noErr ? "⌃⌥Space registered" : "Shortcut unavailable (\(status)); use menu bar"
    }
    private func input(_ event: NSEvent) {
        switch event.type {
        case .pressure:
            pressureEvents += 1
            guard frontmostPID() != ProcessInfo.processInfo.processIdentifier else { return }
            receivePressure(stage: event.stage, at: event.timestamp, sourcePID: frontmostPID())
        case .leftMouseDown:
            if gate.mouseDown(at: event.timestamp) {
                cancelHold(); gesturePID = nil
                pressureStatus = "Ordinary click; waiting for a deep press"
            }
        case .leftMouseUp, .rightMouseDown, .otherMouseDown:
            releasePressure(at: event.timestamp)
        default: break
        }
    }
    func receivePressure(stage: Int, at timestamp: TimeInterval, sourcePID: pid_t?) {
        guard gate.update(stage: stage, at: timestamp) else { return }
        if stage == 0 {
            cancelHold(); gesturePID = nil; pressureStatus = "Released"
            return
        }
        if stage == 1 {
            if gesturePID == nil { gesturePID = sourcePID }
            pressureStatus = "Ordinary pressure; waiting for a deep press"
        }
        guard let deadline = gate.deadline, enabled(), let processID = gesturePID,
              processID != ProcessInfo.processInfo.processIdentifier else {
            cancelHold()
            return
        }
        pressureStatus = "Deep press: hold for more than 0.5 seconds"
        // Repeated stage-2 samples must not restart the hold timer. Steady
        // pressure may stop generating samples, so firing is timer-driven.
        guard armedDeadline != deadline else { return }
        PressureDiagnostics.shared.note("Deep hold armed; waiting >0.5 seconds")
        scheduleHold(until: deadline)
    }
    func releasePressure(at timestamp: TimeInterval) {
        guard gate.update(stage: 0, at: timestamp) else { return }
        cancelHold(); gesturePID = nil; pressureStatus = "Released"
    }
    private func scheduleHold(until deadline: TimeInterval) {
        cancelHold()
        armedDeadline = deadline
        let requestID = UUID(); holdID = requestID
        // Small margin implements strictly MORE than 0.5 seconds. Recheck the
        // clock after waking rather than assuming a timer fired on schedule.
        let delay = max(0.001, deadline - clock() + 0.001)
        holdTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.completeHold(requestID)
        }
    }
    private func completeHold(_ requestID: UUID) {
        guard holdID == requestID else { return }
        holdTask = nil; armedDeadline = nil
        let now = clock()
        guard enabled(), let processID = gesturePID, frontmostPID() == processID else {
            PressureDiagnostics.shared.note("Deep hold cancelled: detection disabled or source app lost focus")
            releasePressure(at: now)
            return
        }
        let began = gate.deepPressStartedAt
        if gate.fireIfReady(at: now, mouseIsDown: mouseIsDown()), let began {
            pressureStatus = "Opened once for this Force Click hold"
            PressureDiagnostics.shared.note("Deep hold accepted; opening command panel")
            trigger(true, processID, began)
        } else if let deadline = gate.deadline {
            scheduleHold(until: deadline)
        }
    }
    private func cancelHold() {
        holdID = UUID(); holdTask?.cancel(); holdTask = nil; armedDeadline = nil
    }
    func stop() {
        cancelHold(); gesturePID = nil
        pressureTap.stop()
        if let global { NSEvent.removeMonitor(global) }
        if let localRelease { NSEvent.removeMonitor(localRelease) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        global = nil; localRelease = nil; hotKey = nil; handler = nil; gate = PressureGate()
        suppression.stop()
    }
}
