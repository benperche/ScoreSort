//
//  AIAssistantsPreferences.swift
//  ScoreSort
//
//  Settings ▸ AI Assistants: connecting ScoreSort to the Claude desktop app (its MCP server)
//  and installing the `scoresort` command for terminal-based AI tools, in a click each.
//  The settings-file and script handling is in Logic/AIConnection.swift.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class AIAssistantsModel: ObservableObject {
    enum ClaudeState: Equatable {
        case notInstalled
        case notConnected
        case connected
        /// Connected, but to another copy of ScoreSort (moved, or a different build).
        case connectedElsewhere(String)
    }
    enum CommandState: Equatable {
        case notInstalled
        case installed
        case installedElsewhere(String)
        /// Something called `scoresort` that ScoreSort didn't put there.
        case occupied
    }

    @Published private(set) var claude: ClaudeState = .notInstalled
    @Published private(set) var command: CommandState = .notInstalled
    @Published private(set) var busy = false
    /// Folders the assistant may look in by name (`find`).
    @Published private(set) var sharedFolders: [URL] = AIConnection.sharedFolders
    @Published var message: (text: String, isError: Bool)?

    #if DEBUG
    let debugBuild = true
    #else
    let debugBuild = false
    #endif

    /// This copy of ScoreSort's executable — what Claude and the command will run.
    var executable: String { Bundle.main.executablePath ?? "" }
    var isTranslocated: Bool { AIConnection.isTranslocated(executable) }
    var isInApplications: Bool { executable.hasPrefix("/Applications/") }

    var claudeAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: AIConnection.claudeBundleID) }
    var claudeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AIConnection.claudeBundleID).isEmpty
    }

    // MARK: Shared folders

    /// Adds folders through the standard folder picker — choosing them is the consent.
    func addSharedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Share"
        panel.message = "Choose folders your AI assistant may look in for parts and scans."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            AIConnection.setSharedFolders(self.sharedFolders + panel.urls)
            self.sharedFolders = AIConnection.sharedFolders
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func removeSharedFolder(_ folder: URL) {
        AIConnection.setSharedFolders(sharedFolders.filter { $0 != folder })
        sharedFolders = AIConnection.sharedFolders
    }

    func refresh() {
        sharedFolders = AIConnection.sharedFolders
        if claudeAppURL == nil {
            claude = .notInstalled
        } else {
            let configured = AIConnection.configuredExecutable(in: try? Data(contentsOf: AIConnection.claudeConfigURL))
            switch configured {
            case nil: claude = .notConnected
            case executable?: claude = .connected
            case let other?: claude = .connectedElsewhere(other)
            }
        }
        if let script = try? String(contentsOfFile: AIConnection.commandLinePath, encoding: .utf8) {
            switch AIConnection.wrapperExecutable(script) {
            case nil: command = .occupied
            case executable?: command = .installed
            case let other?: command = .installedElsewhere(other)
            }
        } else {
            command = FileManager.default.fileExists(atPath: AIConnection.commandLinePath) ? .occupied : .notInstalled
        }
    }

    // MARK: Claude

    /// Adds (or removes) ScoreSort in Claude's settings. Claude is quit first if it's running
    /// — it would otherwise write its own copy of the settings back over the change — and
    /// reopened afterwards.
    func setClaudeConnection(_ connect: Bool) async {
        guard !busy else { return }
        if connect && isTranslocated {
            message = ("Move ScoreSort into your Applications folder first, then open it from there and connect. macOS is running it from a temporary place that changes every time.", true)
            return
        }
        busy = true
        defer { busy = false; refresh() }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AIConnection.claudeBundleID)
        let wasRunning = !running.isEmpty
        if wasRunning {
            running.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline && running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if running.contains(where: { !$0.isTerminated }) {
                message = ("Claude didn't quit. Quit it yourself (⌘Q), then try again.", true)
                return
            }
            // Give it a moment to finish writing its settings on the way out.
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        do {
            let url = AIConnection.claudeConfigURL
            let existing = try? Data(contentsOf: url)
            let updated = connect
                ? try AIConnection.settingsAdding(AIConnection.serverEntry(executable: executable, debugBuild: debugBuild), to: existing)
                : try AIConnection.settingsRemoving(from: existing)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if connect {
                message = wasRunning
                    ? ("Connected. Claude is reopening — ScoreSort's tools will be in its tools menu in a new chat.", false)
                    : ("Connected. Open Claude, and ScoreSort's tools will be in its tools menu in a new chat.", false)
            } else {
                message = ("Disconnected from Claude.", false)
            }
        } catch {
            message = ((error as? CommandError)?.message ?? "Couldn't change Claude's settings: \(error.localizedDescription)", true)
        }

        if wasRunning, let appURL = claudeAppURL {
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Command line

    func setCommandInstalled(_ install: Bool) {
        guard !busy else { return }
        if install && isTranslocated {
            message = ("Move ScoreSort into your Applications folder first, then open it from there and install the command.", true)
            return
        }
        busy = true
        defer { busy = false; refresh() }
        let path = AIConnection.commandLinePath
        do {
            if install {
                let script = AIConnection.wrapperScript(executable: executable)
                do {
                    try FileManager.default.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
                    try script.write(toFile: path, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                } catch {
                    // /usr/local/bin often belongs to the system: ask for a password.
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scoresort-\(UUID().uuidString)")
                    try script.write(to: temp, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try runAsAdministrator("mkdir -p /usr/local/bin && cp \(AIConnection.shellQuoted(temp.path)) \(path) && chmod 755 \(path)")
                }
                message = ("Installed. In Terminal (or an AI tool with a terminal), “scoresort help” lists the commands and “scoresort help ai” is the guide for AI assistants.", false)
            } else {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    try runAsAdministrator("rm -f \(path)")
                }
                message = ("Removed the scoresort command.", false)
            }
        } catch {
            message = ((error as? CommandError)?.message ?? error.localizedDescription, true)
        }
    }

    /// Runs a shell command with the standard macOS administrator password prompt.
    private func runAsAdministrator(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            throw CommandError(number == -128 ? "Cancelled." : "Couldn't change /usr/local/bin: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error").")
        }
    }

    func copySetupSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AIConnection.setupSnippet(executable: executable, debugBuild: debugBuild), forType: .string)
        message = ("Copied. Paste it into the other app's MCP server settings.", false)
    }
}

// MARK: - View

struct AIAssistantsPreferencesView: View {
    @StateObject private var model = AIAssistantsModel()
    @State private var confirmingClaudeRestart: Bool? = nil   // the connect/disconnect waiting on a yes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("AI Assistants")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Let an AI assistant use ScoreSort for you. Ask it to split a scan into parts and name them, number parts in score order, or combine a folder of parts for one of your ensembles — it uses ScoreSort's own tools, so the files come out just as they would from the app, and it checks with you before deciding anything you'd want a say in.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isTranslocated {
                    notice("Move ScoreSort into your Applications folder and open it from there before connecting: macOS is running it from a temporary place that changes every launch.",
                           systemImage: "exclamationmark.triangle.fill", color: .orange)
                }

                claudeSection
                foldersSection
                commandSection
                examplesSection
                otherAppsSection

                if let message = model.message {
                    notice(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                           color: message.isError ? .orange : .green)
                }
            }
            .padding(24)
        }
        .onAppear { model.refresh() }
        .alert("Restart Claude?", isPresented: Binding(get: { confirmingClaudeRestart != nil },
                                                      set: { if !$0 { confirmingClaudeRestart = nil } })) {
            Button(confirmingClaudeRestart == true ? "Quit, Connect & Reopen" : "Quit, Disconnect & Reopen") {
                let connect = confirmingClaudeRestart == true
                confirmingClaudeRestart = nil
                Task { await model.setClaudeConnection(connect) }
            }
            Button("Cancel", role: .cancel) { confirmingClaudeRestart = nil }
        } message: {
            Text("Claude needs to quit while ScoreSort changes its settings, then it reopens. Your chats are kept.")
        }
    }

    private func claudeAction(connect: Bool) {
        if model.claudeIsRunning {
            confirmingClaudeRestart = connect
        } else {
            Task { await model.setClaudeConnection(connect) }
        }
    }

    // MARK: Sections

    private var claudeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                switch model.claude {
                case .notInstalled:
                    status("Claude isn't installed on this Mac.", ok: false)
                    HStack {
                        Text("Install the Claude desktop app, then come back here to connect it.")
                            .foregroundColor(.secondary)
                        Spacer()
                        Link("Get Claude", destination: URL(string: "https://claude.ai/download")!)
                    }
                case .notConnected:
                    status("Not connected.", ok: false)
                    HStack {
                        Text("Adds ScoreSort's tools to Claude. If Claude is open, it restarts.")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Connect to Claude") { claudeAction(connect: true) }
                            .buttonStyle(.borderedProminent)
                    }
                case .connected:
                    status("Connected — ask Claude in a new chat.", ok: true)
                    HStack {
                        Spacer()
                        Button("Disconnect") { claudeAction(connect: false) }
                    }
                case .connectedElsewhere(let path):
                    status("Connected to a different copy of ScoreSort.", ok: false)
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Text("Probably an older copy, or ScoreSort was moved. Connect this one instead.")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Connect This Copy") { claudeAction(connect: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(6)
            .disabled(model.busy)
        } label: {
            Label("Claude desktop app", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
        }
    }

    private var foldersSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your assistant can find files by name — “the Holst scan” — only in folders you share here, such as the folder you keep band parts or scans in. It can't see anything else on your Mac.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.sharedFolders.isEmpty {
                    Text("No folders shared.")
                        .italic()
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.sharedFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: urlIsDirectory(folder) ? "folder.fill" : "questionmark.folder")
                                    .foregroundColor(urlIsDirectory(folder) ? .accentColor : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.lastPathComponent)
                                    Text(urlIsDirectory(folder) ? folder.deletingLastPathComponent().path
                                                                : "Not found — moved or renamed?")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    model.removeSharedFolder(folder)
                                } label: {
                                    Image(systemName: "minus.circle").accessibilityLabel("Stop sharing \(folder.lastPathComponent)")
                                }
                                .buttonStyle(.borderless)
                                .help("Stop sharing this folder")
                            }
                            .padding(.vertical, 5)
                            if folder != model.sharedFolders.last { Divider() }
                        }
                    }
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                }
                HStack(alignment: .top) {
                    Text("Anything else: select it in Finder, press ⌥⌘C (Copy as Pathname) and paste it into the chat. Dragging a file into the chat doesn't work — that sends Claude a copy, not the file on your Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Folder\u{2026}") { model.addSharedFolders() }
                }
            }
            .padding(6)
        } label: {
            Label("Folders your assistant can look in", systemImage: "folder.badge.person.crop")
                .font(.headline)
        }
    }

    private var commandSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("For AI tools that work in a terminal — Claude Code, Codex and the like — and for scripts: a “scoresort” command.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch model.command {
                case .notInstalled:
                    HStack {
                        status("Not installed.", ok: false)
                        Spacer()
                        Button("Install Command") { model.setCommandInstalled(true) }
                    }
                case .installed:
                    HStack {
                        status("Installed — try “scoresort help ai” in Terminal.", ok: true)
                        Spacer()
                        Button("Remove") { model.setCommandInstalled(false) }
                    }
                case .installedElsewhere(let path):
                    status("Installed for a different copy of ScoreSort:", ok: false)
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Use This Copy") { model.setCommandInstalled(true) }
                    }
                case .occupied:
                    status("Something else is already installed as “scoresort” (\(AIConnection.commandLinePath)), so ScoreSort has left it alone.", ok: false)
                }
                Text("You may be asked for your password: the command goes in /usr/local/bin.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
            .disabled(model.busy)
        } label: {
            Label("Command line", systemImage: "terminal")
                .font(.headline)
        }
    }

    private var examplesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([
                    "“Split the Holst scan in my Scans folder into parts, named and numbered in band score order.”",
                    "“That scan has two pages on each sheet — cut them into single pages first.”",
                    "“Combine the parts in my Holst folder for the Junior Band preset. The bass guitars can read the tuba part.”",
                    "“Number the parts in this folder in orchestra order.”",
                    "“Stamp the school name on every part in that folder.”",
                ], id: \.self) { example in
                    Text(example)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Files in your shared folders can be named the way you would to a person; anything else, paste its path (⌥⌘C in Finder). If a shared folder is inside Documents, Desktop or Downloads, macOS asks once whether to allow it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Label("Things to ask", systemImage: "text.bubble")
                .font(.headline)
        }
    }

    private var otherAppsSection: some View {
        GroupBox {
            HStack(alignment: .top) {
                Text("Other AI apps that support MCP servers can use ScoreSort too: copy the setup and paste it into that app's MCP settings.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy Setup") { model.copySetupSnippet() }
            }
            .padding(6)
        } label: {
            Label("Other AI apps", systemImage: "puzzlepiece.extension")
                .font(.headline)
        }
    }

    // MARK: Pieces

    private func status(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
        }
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundColor(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

/// Help ▸ Use ScoreSort with an AI Assistant… — opens Settings on the AI Assistants pane.
struct OpenAIAssistantsSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Use ScoreSort with an AI Assistant\u{2026}") {
            UserDefaults.standard.set("ai", forKey: "preferredPrefsTab")
            openSettings()
        }
    }
}
