//
//  AIConnection.swift
//  ScoreSort
//
//  Connecting ScoreSort to AI assistants: adding its MCP server to the Claude desktop app's
//  settings file, and installing the `scoresort` command for terminal-based AI tools. The
//  JSON and script handling here is pure and unit-tested; the AI Assistants preference pane
//  does the quitting, writing and relaunching.
//
//  Claude keeps its settings in memory while it runs and writes them back, so the file is
//  only ever changed while Claude is quit — a change made underneath a running Claude is
//  overwritten within a minute.
//

import Foundation

enum AIConnection {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// ScoreSort's key under `mcpServers`.
    static let serverName = "scoresort"
    static let commandLinePath = "/usr/local/bin/scoresort"

    /// Folders the person has shared with AI assistants (Settings ▸ AI Assistants): the only
    /// places `find` looks by name. Kept in ScoreSort's own preferences, which the command
    /// line and MCP server read too — they're the same app.
    static let sharedFoldersKey = "aiSharedFolders"

    static var sharedFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: sharedFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setSharedFolders(_ folders: [URL]) {
        var seen = Set<String>()
        let paths = folders.map(\.standardizedFileURL.path).filter { seen.insert($0).inserted }
        UserDefaults.standard.set(paths, forKey: sharedFoldersKey)
    }

    static var claudeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// The MCP server entry for the copy of ScoreSort at `executable`.
    static func serverEntry(executable: String, debugBuild: Bool) -> [String: Any] {
        var entry: [String: Any] = ["command": executable, "args": ["mcp"]]
        // A debug build is coverage-instrumented and would leave profile files about.
        if debugBuild { entry["env"] = ["LLVM_PROFILE_FILE": "/dev/null"] }
        return entry
    }

    /// The settings as a dictionary; an absent or empty file is an empty one. A file that
    /// isn't a JSON object is an error — it must never be overwritten.
    static func settings(from data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw CommandError("Claude's settings file isn't in a form ScoreSort can read, so it was left alone.")
        }
        return dict
    }

    private static func encode(_ dict: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// The settings with ScoreSort's server added (or updated); everything else kept.
    static func settingsAdding(_ entry: [String: Any], to data: Data?) throws -> Data {
        var dict = try settings(from: data)
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = entry
        dict["mcpServers"] = servers
        return try encode(dict)
    }

    /// The settings without ScoreSort's server; everything else kept.
    static func settingsRemoving(from data: Data?) throws -> Data {
        var dict = try settings(from: data)
        if var servers = dict["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: serverName)
            dict["mcpServers"] = servers
        }
        return try encode(dict)
    }

    /// The ScoreSort executable the settings point at, if any.
    static func configuredExecutable(in data: Data?) -> String? {
        guard let dict = try? settings(from: data),
              let servers = dict["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// The `scoresort` command: a two-line script that runs this copy of ScoreSort. A script
    /// rather than a symlink, so the app bundle's frameworks still load.
    static func wrapperScript(executable: String) -> String {
        "#!/bin/sh\n# ScoreSort's command line — installed from ScoreSort's AI Assistants settings.\nexec \(shellQuoted(executable)) \"$@\"\n"
    }

    /// The executable an installed `scoresort` script runs, if it's one of ours.
    static func wrapperExecutable(_ script: String) -> String? {
        guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("exec ") }) else { return nil }
        var rest = line.dropFirst(5)
        guard rest.hasPrefix("'"), let end = rest.range(of: "' \"$@\"", options: .backwards) else { return nil }
        rest = rest[rest.index(after: rest.startIndex)..<end.lowerBound]
        return rest.replacingOccurrences(of: "'\\''", with: "'")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when macOS is running the app from a temporary, randomised location (an app
    /// opened straight from Downloads without moving it). That path changes every launch, so
    /// nothing should be pointed at it.
    static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// The setup snippet for other AI apps that take MCP servers.
    static func setupSnippet(executable: String, debugBuild: Bool) -> String {
        let dict: [String: Any] = ["mcpServers": [serverName: serverEntry(executable: executable, debugBuild: debugBuild)]]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
