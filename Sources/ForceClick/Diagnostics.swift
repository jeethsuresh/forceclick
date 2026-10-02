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
