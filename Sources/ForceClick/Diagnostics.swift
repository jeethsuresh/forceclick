import AppKit
import ApplicationServices
import Security

// Contains app identity, API results and character counts, never selected text.
@MainActor final class CaptureDiagnostics: ObservableObject {
    static let shared = CaptureDiagnostics()
    @Published private(set) var report = "No capture attempted in this session."
    private var lines: [String] = []
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ForceClick/capture-diagnostics.txt")

    func begin(sourcePID: pid_t?, trigger: String) {
        let source = sourcePID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let build = Bundle.main.object(forInfoDictionaryKey: "ForceClickBuild") as? String ?? "development"
        lines = [
            "ForceClick build: \(build)",
            "Executable: \(Bundle.main.executablePath ?? CommandLine.arguments[0])",
            "Process: \(ProcessInfo.processInfo.processIdentifier)",
            "Attempt: \(ISO8601DateFormatter().string(from: Date())) · \(trigger)",
            "Accessibility trusted: \(AXIsProcessTrusted())",
            "Can post keyboard events: \(CGPreflightPostEventAccess())",
            "Signing requirement: \(signingRequirement())",
            "Source: \(source?.localizedName ?? "unknown") · \(source?.bundleIdentifier ?? "unknown") · pid \(sourcePID ?? 0)"
        ]
        publish()
    }
    private func signingRequirement() -> String {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, description: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &description) == errSecSuccess, let description else { return "Unavailable" }
        return description as String
    }
    func record(_ line: String) {
        lines.append(line)
        publish()
    }
    private func publish() {
        report = lines.joined(separator: "\n")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}

// Input diagnostics contain event types/stages and counts, never key codes,
// pointer positions, selected text, or document contents. Disk writes are
// debounced so the event-tap callback never performs file I/O.
@MainActor final class PressureDiagnostics: ObservableObject {
    static let shared = PressureDiagnostics()
    @Published private(set) var report = "Input monitoring has not started."
    private var counts: [String: Int] = [:]
    private var lines: [String] = []
    private var lastStages: [String: Int] = [:]
    private var publishTask: Task<Void, Never>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var tapStatus = "Not installed"
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ForceClick/pressure-diagnostics.txt")

    func reset() {
        publishTask?.cancel(); publishTask = nil
        counts = [:]; lines = []; lastStages = [:]
        startedAt = ProcessInfo.processInfo.systemUptime
        note("Input monitors starting")
    }
    func setTapStatus(_ status: String) {
        tapStatus = status
        note(status)
    }
    func note(_ line: String) {
        lines.append(String(format: "%.3fs · %@", ProcessInfo.processInfo.systemUptime - startedAt, line))
        lines = Array(lines.suffix(60))
        schedulePublish()
    }
    func event(_ event: NSEvent, source: String) {
        counts["\(source) NSEvent \(event.type.rawValue)", default: 0] += 1
        if event.type == .pressure, lastStages[source] != event.stage {
            lastStages[source] = event.stage
            note("\(source): stage \(event.stage), pressure \(String(format: "%.3f", event.pressure)), behavior \(event.pressureBehavior.rawValue)")
        }
        schedulePublish()
    }
    func quartzEvent(type: CGEventType, converted: NSEvent?) {
        counts["Quartz raw type \(type.rawValue)", default: 0] += 1
        if let converted { event(converted, source: "Quartz") }
        else { counts["Quartz conversion unavailable", default: 0] += 1; schedulePublish() }
    }
    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self else { return }
            self.publishTask = nil
            let build = Bundle.main.object(forInfoDictionaryKey: "ForceClickBuild") as? String ?? "development"
            let header = ["ForceClick build: \(build)", "Process: \(ProcessInfo.processInfo.processIdentifier)",
                          "Accessibility trusted: \(AXIsProcessTrusted())", "Listen access: \(CGPreflightListenEventAccess())",
                          "Tap: \(self.tapStatus)", "Pressure NSEvent type: \(NSEvent.EventType.pressure.rawValue)"]
            self.report = (header + self.counts.keys.sorted().map { "\($0): \(self.counts[$0]!)" } + ["", "Recent input transitions:"] + self.lines).joined(separator: "\n")
            let report = self.report, url = self.url
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? report.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
