import AppKit
import SwiftUI
import CoreServices

struct AutomationCommand {
    let executable: String
    let arguments: [String]
    static func make(_ automation: Automation, inputFile: URL) throws -> AutomationCommand {
        guard !automation.target.isEmpty else { throw AppError.message("Configure the automation target first") }
        switch automation.kind {
        case .executable:
            guard automation.target.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: automation.target) else { throw AppError.message("Choose an absolute executable path") }
            return .init(executable: automation.target, arguments: automation.arguments)
        case .shortcut:
            return .init(executable: "/usr/bin/shortcuts", arguments: ["run", automation.target, "--input-path", inputFile.path])
        case .appleScript:
            guard automation.target.hasPrefix("/"), FileManager.default.fileExists(atPath: automation.target) else { throw AppError.message("Choose an existing AppleScript file") }
            return .init(executable: "/usr/bin/osascript", arguments: [automation.target, inputFile.path] + automation.arguments)
        }
    }
}
// Selection is supplied as data in a file, never interpolated into shell or script source.
struct AutomationRunner {
    static func run(_ automation: Automation, text: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appendingPathComponent("selection.txt")
            try Data(text.utf8).write(to: input)
            let command = try AutomationCommand.make(automation, inputFile: input)
            let output = folder.appendingPathComponent("output.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: command.executable); process.arguments = command.arguments
            var env = ProcessInfo.processInfo.environment; env["FORCECLICK_SELECTION_FILE"] = input.path; process.environment = env
            process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                try await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw AppError.message("Automation exceeded 30 seconds and was stopped")
            }
            process.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
            let result = String(decoding: try reader.read(upToCount: 16_000) ?? Data(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw AppError.message("Automation failed (\(process.terminationStatus)): \(result)") }
            return result.isEmpty ? "Automation completed." : result
        }.value
    }
}

@MainActor final class ToolExecutor {
    let store: Store
    var noteWindows: [UUID: NSWindow] = [:]
    var picker: NSSharingServicePicker?
    init(store: Store) { self.store = store }
    func showNote(_ note: Note) {
        if let window = noteWindows[note.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 250), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sticky note"; window.level = .floating; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StickyView(store: store, id: note.id))
        window.center(); window.makeKeyAndOrderFront(nil); noteWindows[note.id] = window
    }
    func execute(_ call: ValidatedCall, anchor: NSView) async throws -> String {
        let a = call.arguments
        switch call.name {
        case "create_sticky_note":
            let note = Note(text: a.text!); store.data.notes.append(note); try store.save(); showNote(note); return "Sticky note saved."
        case "create_todo", "create_calendar_event":
            store.data.todos.append(Todo(title: a.title!, details: a.details ?? "", due: a.due, isEvent: call.name == "create_calendar_event")); try store.save()
            return call.name == "create_todo" ? "Todo saved to your library." : "Event saved internally. Calendar sync is not connected."
        case "copy_to_clipboard":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.text!, forType: .string); return "Copied to clipboard."
        case "define":
            let text = a.text! as NSString
            guard let definition = DCSCopyTextDefinition(nil, text, CFRange(location: 0, length: text.length))?.takeRetainedValue() else { return "No local dictionary definition found. Try a single word, or ask the local AI to explain it." }
            return definition as String
        case "share":
            picker = NSSharingServicePicker(items: [a.text!]); picker?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY); return "Choose a sharing service and recipient."
        case "run_automation":
            guard let automation = store.data.settings.automations.first(where: { $0.id.uuidString == a.automation_id }) else { throw AppError.message("Automation no longer exists") }
            let alert = NSAlert(); alert.messageText = "Run \(automation.name)?"; alert.informativeText = "\(automation.kind.rawValue): \(automation.target)\nArguments: \(automation.arguments.joined(separator: " "))\n\nThis receives the selected text and runs with your account's permissions."
            alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return "Automation cancelled." }
            return try await AutomationRunner.run(automation, text: a.text ?? "")
        default: throw AppError.message("Unsupported tool")
        }
    }
}
struct StickyView: View {
    @ObservedObject var store: Store
    let id: UUID
    var body: some View {
        TextEditor(text: Binding(get: { store.data.notes.first(where: { $0.id == id })?.text ?? "" }, set: { value in
            if let i = store.data.notes.firstIndex(where: { $0.id == id }) { store.data.notes[i].text = value; store.persist() }
        })).font(.system(size: 16)).padding(12).background(Color.yellow.opacity(0.3))
    }
}
