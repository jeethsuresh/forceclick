import AppKit
import SwiftUI

@main struct ForceClickApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let triggers = TriggerCoordinator()
    lazy var executor = ToolExecutor(store: store)
    lazy var session = PanelSession(store: store, executor: executor)
    var statusItem: NSStatusItem!
    var panel: CommandPanel?
    var settingsWindow: NSWindow?
    var libraryWindow: NSWindow?
    var diagnosticsWindow: NSWindow?
    var inputDiagnosticsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var promptedForAccessibility = false
    private var activationObserver: NSObjectProtocol?
    private var lastExternalPID: pid_t?
    private var captureStartedAt: TimeInterval?
    private var panelShownAt: TimeInterval?
    private var accessibilityWasGranted = AXIsProcessTrusted()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // run.sh opens a fresh process after a rebuild; replace any older copy
        // instead of leaving the previous executable resident in memory.
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == Bundle.main.bundleIdentifier && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.terminate()
        }
        rememberSource(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.rememberSource(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                self?.refreshAccessibility()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "ForceClick")
        let menu = NSMenu()
        menu.addItem(item("Open command panel    ⌃⌥Space", #selector(openCommand)))
        menu.addItem(item("Notes & todos…", #selector(openLibrary)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Capture diagnostics…", #selector(openDiagnostics)))
        menu.addItem(item("Input diagnostics & trackpad test…", #selector(openInputDiagnostics)))
        menu.addItem(.separator()); menu.addItem(item("Quit ForceClick", #selector(quit)))
        statusItem.menu = menu
        session.openAccessibilitySettings = { [weak self] in self?.openAccessibilityPermissionSettings() }
        session.checkAccessibility = { [weak self] in self?.recheckAccessibility() }
        session.didClose = { [weak self] in self?.cancelCapture() }
        session.openDiagnostics = { [weak self] in self?.openDiagnostics() }
        triggers.enabled = { [weak self] in self?.store.data.settings.forceTouchEnabled ?? false }
        triggers.trigger = { [weak self] pressure, processID, timestamp in self?.captureAndShow(pressureOnly: pressure, sourcePID: processID, timestamp: timestamp) }
        triggers.start()
        CaptureDiagnostics.shared.begin(sourcePID: nil, trigger: "Application startup")
        CaptureDiagnostics.shared.record(triggers.shortcutStatus)
        let mouseButtons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseButtons) { [weak self] event in
            self?.dismissForExternalClick(timestamp: event.timestamp)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseButtons) { [weak self] event in
            if let self, event.windowNumber != self.panel?.windowNumber {
                self.dismissForExternalClick(timestamp: event.timestamp)
            }
            return event
        }
        if CommandLine.arguments.contains("--smoke-test") {
            show(context: .init(text: "ForceClick is ready. Select text in another app and press Control–Option–Space.", application: "Smoke test"), message: "Quick actions work without a local model.")
        } else if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched"); openSettings()
        }
    }
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; return i
    }
    private func rememberSource(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalPID = app.processIdentifier }
    }
    @objc func openCommand() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        captureAndShow(pressureOnly: false, sourcePID: frontmost == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : frontmost)
    }
    private func openAccessibilityPermissionSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    private func recheckAccessibility() {
        refreshAccessibility()
        if AXIsProcessTrusted() {
            session.needsAccessibility = false
            session.result = "Access granted. Highlight text again, then use Force Click or ⌃⌥Space."
        } else {
            session.result = "ForceClick is still waiting for Accessibility access. Turn it on in System Settings, then check again."
        }
    }
    private func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityWasGranted {
            accessibilityWasGranted = granted
            // Global monitors established before access was granted may not
            // deliver events. Reinstall them when macOS changes the grant.
            triggers.stop(); triggers.start()
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.dismissForExternalClick(timestamp: event.timestamp)
            }
            CaptureDiagnostics.shared.record("Accessibility changed: \(granted); input monitors refreshed")
        }
    }
    private func showAccessibilityRequest() {
        captureTask?.cancel()
        captureID = UUID()
        show(context: .init(text: "", application: "Permission needed"), message: "", needsAccessibility: true)
        if !promptedForAccessibility {
            promptedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
    private func cancelCapture() {
        captureID = UUID()
        captureTask?.cancel()
        captureTask = nil
        captureStartedAt = nil
    }
    private func dismissForExternalClick(timestamp: TimeInterval) {
        // Global monitor callbacks are asynchronous. The mouse-down belonging
        // to the initiating Force Click must not cancel that capture or close
        // its freshly shown panel when delivered late.
        guard timestamp > (captureStartedAt ?? panelShownAt ?? 0) else { return }
        if captureTask != nil { CaptureDiagnostics.shared.record("Capture cancelled by a later outside click") }
        cancelCapture()
        if panel?.isVisible == true { session.close() }
    }
    func captureAndShow(pressureOnly: Bool, sourcePID: pid_t?, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        CaptureDiagnostics.shared.begin(sourcePID: sourcePID, trigger: pressureOnly ? "Force Click" : "Shortcut/menu")
        refreshAccessibility()
        if !AXIsProcessTrusted() {
            showAccessibilityRequest()
            return
        }
        if sourcePID == ProcessInfo.processInfo.processIdentifier, panel?.isVisible == true {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        captureTask?.cancel()
        panel?.orderOut(nil)
        let requestID = UUID()
        captureID = requestID
        captureStartedAt = timestamp
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.captureID == requestID { self.captureTask = nil; self.captureStartedAt = nil } }
            do {
                let context = try await SelectionReader().capture(from: sourcePID)
                guard !Task.isCancelled, self.captureID == requestID else { return }
                self.show(context: context, message: "")
                CaptureDiagnostics.shared.record("Panel shown with \(context.text.count) characters")
            } catch {
                guard !Task.isCancelled, self.captureID == requestID else { return }
                CaptureDiagnostics.shared.record("Capture failed: \(error.localizedDescription)")
                self.show(context: .init(text: "", application: sourcePID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Manual input"), message: error.localizedDescription)
            }
        }
    }
    func show(context: SelectionContext, message: String, needsAccessibility: Bool = false) {
        panel?.orderOut(nil)
        session.cancel(); session.context = context; session.instruction = ""; session.result = message
        session.needsAccessibility = needsAccessibility
        let panel = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: 664, height: 330), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ForceClick Command"
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: CommandView(session: session)); hosting.wantsLayer = true; hosting.layer?.cornerRadius = 16; hosting.layer?.masksToBounds = true
        panel.contentView = hosting; panel.setContentSize(hosting.fittingSize)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 120)) }
        self.panel = panel; session.panel = panel; panel.makeKeyAndOrderFront(nil)
        panelShownAt = ProcessInfo.processInfo.systemUptime
    }
    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = window(title: "ForceClick Settings", view: SettingsView(store: store, triggers: triggers, openCommand: { [weak self] in self?.openCommand() }, openInputDiagnostics: { [weak self] in self?.openInputDiagnostics() })) }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }
    @objc func openLibrary() {
        if libraryWindow == nil { libraryWindow = window(title: "ForceClick Library", view: LibraryView(store: store, executor: executor)) }
        NSApp.activate(ignoringOtherApps: true); libraryWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openDiagnostics() {
        if diagnosticsWindow == nil { diagnosticsWindow = window(title: "ForceClick Capture Diagnostics", view: CaptureDiagnosticsView(diagnostics: .shared)) }
        NSApp.activate(ignoringOtherApps: true); diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openInputDiagnostics() {
        if inputDiagnosticsWindow == nil {
            inputDiagnosticsWindow = window(title: "ForceClick Input Diagnostics", view: PressureDiagnosticsView(diagnostics: .shared, restart: { [weak self] in
                self?.triggers.stop(); self?.triggers.start()
            }))
        }
        NSApp.activate(ignoringOtherApps: true); inputDiagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
    func window<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view); window.contentView = hosting; window.setContentSize(hosting.fittingSize)
        window.title = title; window.isReleasedWhenClosed = false; window.center(); return window
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        captureTask?.cancel()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        triggers.stop(); session.cancel(); store.persist()
    }
}
