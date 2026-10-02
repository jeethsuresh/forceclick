import Foundation

struct SelectionContext: Codable, Sendable {
    var text: String
    var application: String
    var capturedAt = Date()
}
struct Note: Codable, Identifiable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}
struct Todo: Codable, Identifiable {
    var id = UUID()
    var title: String
    var details: String
    var due: String?
    var isEvent = false
    var completed = false
}
struct Automation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case executable, shortcut, appleScript }
    var id = UUID()
    var name = "New automation"
    var kind = Kind.executable
    var target = ""
    var arguments: [String] = []
}
struct Settings: Codable {
    var endpoint = "http://127.0.0.1:11434/v1"
    var model = "qwen3:8b"
    var forceTouchEnabled = true
    var automations: [Automation] = []
}
struct SavedData: Codable {
    var settings = Settings()
    var notes: [Note] = []
    var todos: [Todo] = []
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

@MainActor final class Store: ObservableObject {
    @Published var data: SavedData
    @Published var persistenceError: String?
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ForceClick/data.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                data = try JSONDecoder().decode(SavedData.self, from: Data(contentsOf: self.url))
            } else { data = SavedData() }
        } catch {
            data = SavedData()
            persistenceError = "Could not load saved data: \(error.localizedDescription). Original file preserved; restart after repairing it."
        }
    }
    func save() throws {
        guard persistenceError == nil else { throw AppError.message(persistenceError!) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: url, options: .atomic)
    }
    func persist() {
        do { try save() } catch { persistenceError = error.localizedDescription }
    }
}

struct ToolCall: Decodable {
    var id: String?
    var function: Function
    struct Function: Decodable { var name: String; var arguments: String }
}
struct ToolArguments: Codable {
    var text: String?
    var title: String?
    var details: String?
    var due: String?
    var automation_id: String?
}
struct ValidatedCall {
    var name: String
    var arguments: ToolArguments
}
struct ToolRegistry {
    static let names = ["create_sticky_note", "create_todo", "create_calendar_event", "define", "share", "copy_to_clipboard", "run_automation"]
    static var schemas: [[String: Any]] {
        let descriptions = ["Save a sticky note", "Save an internal todo", "Save an internal calendar placeholder (does not sync to Calendar)", "Look up a word in macOS dictionaries", "Open the native share picker", "Copy text to the clipboard", "Run a configured automation by ID, with user confirmation"]
        return zip(names, descriptions).map { name, description in
            let fields: [String]
            switch name {
            case "create_todo", "create_calendar_event": fields = ["title", "details", "due"]
            case "run_automation": fields = ["automation_id", "text"]
            default: fields = ["text"]
            }
            return ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"]) }), "required": [fields[0]], "additionalProperties": false]]]
        }
    }
    static func validate(_ call: ToolCall, automations: [Automation]) throws -> ValidatedCall {
        guard names.contains(call.function.name) else { throw AppError.message("Unknown tool: \(call.function.name)") }
        guard let raw = call.function.arguments.data(using: .utf8), raw.count <= 64_000,
              let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw AppError.message("Invalid tool arguments") }
        let name = call.function.name
        let allowed: Set<String> = name == "run_automation" ? ["automation_id", "text"] : (["create_todo", "create_calendar_event"].contains(name) ? ["title", "details", "due"] : ["text"])
        guard Set(object.keys).isSubset(of: allowed), object.values.allSatisfy({ $0 is String }) else { throw AppError.message("Unexpected tool argument") }
        let args = try JSONDecoder().decode(ToolArguments.self, from: raw)
        let required = name == "run_automation" ? args.automation_id : (["create_todo", "create_calendar_event"].contains(name) ? args.title : args.text)
        guard let required, !required.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Tool is missing required text or ID") }
        if name == "run_automation", !automations.contains(where: { $0.id.uuidString == required }) { throw AppError.message("Automation is not configured") }
        if let due = args.due, !due.isEmpty, ISO8601DateFormatter().date(from: due) == nil { throw AppError.message("Due date must be an ISO-8601 date with time zone") }
        return ValidatedCall(name: name, arguments: args)
    }
}
struct PressureGate {
    static let minimumHold: TimeInterval = 0.5
    private var sawFirstStage = false
    private var triggered = false
    private var lastTimestamp = -Double.infinity
    private(set) var deepPressStartedAt: TimeInterval?
    var deadline: TimeInterval? {
        guard !triggered, let deepPressStartedAt else { return nil }
        return deepPressStartedAt + Self.minimumHold
    }
    // A later mouse-down begins a new gesture. Ignore a delayed mouse-down
    // already preceded by pressure samples from that same gesture.
    @discardableResult mutating func mouseDown(at timestamp: TimeInterval) -> Bool {
        guard timestamp > lastTimestamp else { return false }
        return update(stage: 0, at: timestamp)
    }
    @discardableResult mutating func update(stage: Int, at timestamp: TimeInterval) -> Bool {
        guard timestamp >= lastTimestamp else { return false }
        lastTimestamp = timestamp
        switch stage {
        case 0:
            sawFirstStage = false
            triggered = false
            deepPressStartedAt = nil
        case 1:
            sawFirstStage = true
            deepPressStartedAt = nil
        case 2:
            if sawFirstStage, !triggered, deepPressStartedAt == nil {
                deepPressStartedAt = timestamp
            }
        default:
            deepPressStartedAt = nil
        }
        return true
    }
    mutating func fireIfReady(at timestamp: TimeInterval, mouseIsDown: Bool) -> Bool {
        guard mouseIsDown else { update(stage: 0, at: timestamp); return false }
        guard let deadline, timestamp > deadline else { return false }
        triggered = true
        return true
    }
}
