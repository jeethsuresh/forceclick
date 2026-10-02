import AppKit
import SwiftUI

final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class PanelSession: ObservableObject {
    @Published var context = SelectionContext(text: "", application: "Manual input")
    @Published var instruction = ""
    @Published var result = ""
    @Published var busy = false
    @Published var needsAccessibility = false
    var openAccessibilitySettings: () -> Void = {}
    var checkAccessibility: () -> Void = {}
    var didClose: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var task: Task<Void, Never>?
    private var generation = UUID()
    let store: Store
    let executor: ToolExecutor
    weak var panel: NSPanel?
    init(store: Store, executor: ToolExecutor) { self.store = store; self.executor = executor }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func close() { cancel(); panel?.orderOut(nil); didClose() }
    func run(tool: String? = nil) {
        guard !busy else { return }
        guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { result = "Select or paste some text first."; return }
        guard tool != nil || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; result = ""
        let context = context, settings = store.data.settings, instruction = instruction
        let runID = UUID(); generation = runID
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == runID { self.busy = false } }
            do {
                let calls: [ToolCall]
                if let tool {
                    let args = ["create_todo", "create_calendar_event"].contains(tool) ? ["title": context.text] : ["text": context.text]
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                    calls = [ToolCall(function: .init(name: tool, arguments: json))]
                } else {
                    let reply = try await LLMClient().send(settings: settings, context: context, instruction: instruction)
                    try Task.checkCancellation()
                    calls = reply.tool_calls ?? []
                    if calls.isEmpty { self.result = reply.content ?? "The model returned no answer or action."; return }
                }
                // Validate the entire batch before any action can produce a side effect.
                let validated = try calls.map { try ToolRegistry.validate($0, automations: settings.automations) }
                for call in validated {
                    try Task.checkCancellation()
                    guard let anchor = self.panel?.contentView else { return }
                    let output = try await self.executor.execute(call, anchor: anchor)
                    guard self.generation == runID else { return }
                    self.result += (self.result.isEmpty ? "" : "\n\n") + output
                }
            } catch is CancellationError { if self.generation == runID { self.result = "Cancelled." } }
            catch { if self.generation == runID { self.result += (self.result.isEmpty ? "" : "\n\n") + error.localizedDescription } }
        }
    }
}
struct CommandView: View {
    @ObservedObject var session: PanelSession
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "cursorarrow.click.2").font(.title2).foregroundStyle(.blue)
                Text("ForceClick").font(.headline)
                Spacer()
                Text(session.context.application).foregroundStyle(.secondary).lineLimit(1)
                Button { session.close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
            }
            if session.needsAccessibility {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Allow selected-text access", systemImage: "hand.raised")
                        .font(.title3.weight(.semibold))
                    Text("macOS has not granted this build of ForceClick Accessibility access. It cannot read highlighted text until you allow it.")
                    HStack {
                        Button("Open Accessibility Settings") { session.openAccessibilitySettings() }
                            .keyboardShortcut(.defaultAction)
                        Button("Check Again") { session.checkAccessibility() }
                    }
                    Text("Turn on ForceClick in Privacy & Security → Accessibility. Then highlight the text again and use Force Click or ⌃⌥Space.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                TextEditor(text: $session.context.text).font(.system(size: 14)).frame(height: 92).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(session.busy).accessibilityLabel("Selected text")
                HStack {
                    TextField("What would you like to do with this?", text: $session.instruction).font(.system(size: 21)).textFieldStyle(.plain).focused($focused).onSubmit { session.run() }.disabled(session.busy)
                    if session.busy { ProgressView().controlSize(.small); Button("Cancel") { session.cancel() } }
                    else { Button { session.run() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.buttonStyle(.plain).help("Ask local AI") }
                }
                HStack {
                    ForEach(Array(zip(["Note", "Todo", "Event", "Define", "Share", "Copy"], ["create_sticky_note", "create_todo", "create_calendar_event", "define", "share", "copy_to_clipboard"])), id: \.0) { label, tool in
                        Button(label) { session.run(tool: tool) }.disabled(session.busy)
                    }
                }
            }
            if !session.result.isEmpty {
                ScrollView { Text(session.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            }
            HStack {
                Text("⌃⌥Space · Esc to close · Quick actions work without AI")
                Spacer()
                Button("Capture report") { session.openDiagnostics() }.buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 620).background(.regularMaterial).onAppear { focused = true }.onExitCommand { session.close() }
    }
}

struct CaptureDiagnosticsView: View {
    @ObservedObject var diagnostics: CaptureDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last selection capture").font(.headline)
            Text("This report includes app identity and API results. It does not include highlighted text.").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(diagnostics.report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Copy report") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics.report, forType: .string) }
        }.padding(20).frame(width: 680, height: 440)
    }
}

@MainActor final class SettingsUI: ObservableObject {
    @Published var selected: UUID?
    @Published var status = ""
    @Published var accessibilityGranted = AXIsProcessTrusted()
}
struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var triggers: TriggerCoordinator
    var openCommand: () -> Void = {}
    @StateObject private var ui = SettingsUI()
    var body: some View {
        TabView {
            Form {
                Section("Local AI") {
                    TextField("Base URL", text: $store.data.settings.endpoint)
                    TextField("Model", text: $store.data.settings.model)
                    Text("OpenAI-compatible /v1 server on this Mac. Example: Ollama at port 11434, or LM Studio at port 1234. Use a model that supports tools.").font(.caption).foregroundStyle(.secondary)
                    Button("Test connection") {
                        ui.status = "Testing…"
                        let settings = store.data.settings
                        Task {
                            do { let reply = try await LLMClient().send(settings: settings, context: .init(text: "Connection test", application: "ForceClick"), instruction: "Reply with OK without using tools."); ui.status = "Connected: \(reply.content ?? "response received")" }
                            catch { ui.status = error.localizedDescription }
                        }
                    }
                    Text(ui.status).font(.caption).textSelection(.enabled)
                }
                Section("Input & permissions") {
                    Toggle("Observe Force Touch pressure (experimental)", isOn: $store.data.settings.forceTouchEnabled)
                    Text(triggers.shortcutStatus)
                    Button("Open command panel") { openCommand() }
                    Text("Pressure events observed: \(triggers.pressureEvents)")
                    Text("Force Click: hold the deeper click for more than 0.5 seconds.")
                    Text(triggers.pressureStatus).font(.caption).foregroundStyle(.secondary)
                    Text(triggers.suppression.status).font(.caption)
                    Text("Accessibility: \(ui.accessibilityGranted ? "Granted" : "Not granted — selected text cannot be read")")
                    Button("Enable Accessibility…") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        ui.accessibilityGranted = AXIsProcessTrusted()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Text("If pressure events never arrive, use ⌃⌥Space. This app does not change Trackpad settings or intercept ordinary clicks.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22).tabItem { Label("General", systemImage: "gear") }
            VStack(alignment: .leading, spacing: 12) {
                Text("Only automations you add here are available to the AI. Each run asks for confirmation.").font(.callout)
                List(selection: $ui.selected) { ForEach(store.data.settings.automations) { a in Text(a.name).tag(a.id) } }.frame(height: 100)
                HStack {
                    Button("Add") { let a = Automation(); store.data.settings.automations.append(a); ui.selected = a.id }
                    Button("Remove") { store.data.settings.automations.removeAll { $0.id == ui.selected }; ui.selected = nil }.disabled(ui.selected == nil)
                }
                if let i = store.data.settings.automations.firstIndex(where: { $0.id == ui.selected }) {
                    TextField("Name", text: $store.data.settings.automations[i].name)
                    Picker("Type", selection: $store.data.settings.automations[i].kind) { ForEach(Automation.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Absolute file path or Shortcut name", text: $store.data.settings.automations[i].target)
                    Text("Arguments (one per line; no shell expansion)").font(.caption)
                    TextEditor(text: Binding(get: { store.data.settings.automations[i].arguments.joined(separator: "\n") }, set: { store.data.settings.automations[i].arguments = $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) })).frame(height: 65)
                    Text("Executables: read FORCECLICK_SELECTION_FILE. Shortcuts: receive text file input. AppleScripts: first argument is the text file path.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22).tabItem { Label("Automations", systemImage: "bolt") }
        }.frame(width: 620, height: 490)
        .onAppear { ui.accessibilityGranted = AXIsProcessTrusted() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            ui.accessibilityGranted = AXIsProcessTrusted()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(store.persistenceError ?? "Settings are saved locally.").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Save settings") { store.persist(); if store.persistenceError == nil { ui.status = "Saved." } }
            }.padding()
        }
    }
}

struct LibraryView: View {
    @ObservedObject var store: Store
    let executor: ToolExecutor
    var body: some View {
        TabView {
            List {
                if store.data.notes.isEmpty { Text("Your sticky notes will appear here.").foregroundStyle(.secondary) }
                ForEach(store.data.notes) { note in
                    HStack {
                        Text(note.text).lineLimit(3); Spacer()
                        Button("Open") { executor.showNote(note) }
                        Button(role: .destructive) { executor.noteWindows[note.id]?.close(); executor.noteWindows[note.id] = nil; store.data.notes.removeAll { $0.id == note.id }; store.persist() } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 5)
                }
            }.tabItem { Label("Notes", systemImage: "note.text") }
            List {
                if store.data.todos.isEmpty { Text("Your todos and internal events will appear here.").foregroundStyle(.secondary) }
                ForEach($store.data.todos) { $todo in
                    HStack {
                        Toggle(isOn: $todo.completed) { VStack(alignment: .leading) {
                            Text(todo.title).strikethrough(todo.completed)
                            if !todo.details.isEmpty { Text(todo.details).font(.caption) }
                            if let due = todo.due { Text(due).font(.caption).foregroundStyle(.secondary) }
                            if todo.isEvent { Text("Internal event · Calendar sync pending").font(.caption).foregroundStyle(.secondary) }
                        } }.onChange(of: todo.completed) { _ in store.persist() }
                        Button(role: .destructive) { store.data.todos.removeAll { $0.id == todo.id }; store.persist() } label: { Image(systemName: "trash") }
                    }
                }
            }.tabItem { Label("Todos & events", systemImage: "checklist") }
        }.padding(15).frame(width: 620, height: 440)
    }
}
