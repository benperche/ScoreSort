//
//  MCPServer.swift
//  ScoreSort
//
//  `ScoreSort mcp` — ScoreSort's commands as MCP tools, so AI chat apps without a terminal
//  (Claude's desktop app, and others that support MCP) can split, name, rename, combine and
//  stamp parts. Claude Desktop config:
//
//    { "mcpServers": { "scoresort": {
//        "command": "/Applications/ScoreSort.app/Contents/MacOS/ScoreSort", "args": ["mcp"] } } }
//
//  The Model Context Protocol over stdio: JSON-RPC 2.0, one message per line. Hand-rolled
//  (initialize, ping, tools/list, tools/call) rather than an SDK — it's small, and keeps the
//  app free of another dependency.
//
//  Each tool turns its JSON arguments into the command line's own arguments and runs the
//  same command, so validation, safety rules and results are identical to the CLI.
//

import Foundation

enum ScoreSortMCPServer {

    // MARK: - Tools

    enum ParamKind {
        case string
        case number
        case boolean
        /// Several values: a repeated option, or several positionals.
        case strings
        /// An array of objects with two fields, passed as a repeated `--option "KEY=VALUE"`.
        case pairs(key: String, value: String, valueIsNumber: Bool)
    }

    struct Param {
        let key: String
        /// The command-line option; nil for a positional argument.
        let option: String?
        let kind: ParamKind
        let description: String
        var required = false
        var choices: [String]? = nil
        /// Used when the client leaves it out (only where the MCP default should differ from
        /// the command line's, e.g. previews as compact contact sheets).
        var defaultValue: Any? = nil
    }

    struct Tool {
        let name: String
        let command: String
        let description: String
        let params: [Param]
        /// Arguments to add when absent (e.g. a temporary folder for previews).
        var fillDefaults: ((inout [String: Any]) -> Void)? = nil
    }

    static let outputHint = "Absolute paths. Nothing is overwritten unless overwrite is true; use dryRun first to check what will be written."

    static var tools: [Tool] {
        [
            Tool(name: "scoresort_guide", command: "help",
                 description: "How to use ScoreSort's tools for common jobs (split and name parts, scans of double pages, score-order renaming, combining with presets). Read this first.",
                 params: []),
            Tool(name: "scoresort_info", command: "info",
                 description: "Describe a PDF: page count, page sizes, bookmarks (with the part names ScoreSort would suggest), and whether it's a scan of double pages that needs scoresort_split_scans first.",
                 params: [Param(key: "file", option: nil, kind: .string, description: "Absolute path to the PDF.", required: true)]),
            Tool(name: "scoresort_preview", command: "preview",
                 description: "Look at a PDF's pages, returned as images. ScoreSort can't read text, so this is how to find which part each page belongs to: the top of each page (default) shows the instrument name and title. By default pages come back side by side in labelled contact sheets (p1, p2, …), so a whole PDF is one or two images.",
                 params: [Param(key: "file", option: nil, kind: .string, description: "Absolute path to the PDF.", required: true),
                          Param(key: "pages", option: "pages", kind: .string, description: "Pages to show, 1-based, e.g. \"1-3,7\" or \"5-\". Default: all."),
                          Param(key: "top", option: "top", kind: .boolean, description: "Only the top third of each page (default true). Set false to see whole pages.", defaultValue: true),
                          Param(key: "sheet", option: "sheet", kind: .boolean, description: "Contact sheets (default true). False returns one image per page — use with a few pages only.", defaultValue: true),
                          Param(key: "width", option: "width", kind: .number, description: "Pixel width of each page image (default 450 in sheets, 900 otherwise)."),
                          Param(key: "out", option: "out", kind: .string, description: "Folder to also keep the images in (default: a temporary folder).")],
                 fillDefaults: { args in
                     if args["out"] == nil {
                         args["out"] = FileManager.default.temporaryDirectory
                             .appendingPathComponent("ScoreSort previews/\(UUID().uuidString)").path
                     }
                     if args["width"] == nil, (args["sheet"] as? Bool ?? true) { args["width"] = 450 }
                 }),
            Tool(name: "scoresort_split_scans", command: "split-scans",
                 description: "Cut scans of double pages (A3 sheets, or a book scanner's two-page spreads) into single pages, saved as a new PDF. Each scan is cut at the gap between its pages (or where black scanner background starts); identical sheets are all cut down the middle. Reports which new pages are black or empty (suggestedSkip, for scoresort_split's skip) and lists every scan's pages.",
                 params: [Param(key: "file", option: nil, kind: .string, description: "Absolute path to the scanned PDF.", required: true),
                          Param(key: "out", option: "out", kind: .string, description: "Absolute path for the new PDF.", required: true),
                          Param(key: "sameCut", option: "same-cut", kind: .boolean, description: "Cut every scan down the middle."),
                          Param(key: "cut", option: "cut", kind: .number, description: "Cut every scan at this fraction of its width (0.5 = middle)."),
                          Param(key: "perScan", option: "per-scan", kind: .boolean, description: "Find each scan's own cut even for identical sheets."),
                          Param(key: "first", option: "first", kind: .string, description: "Which side comes first (default left).", choices: ["left", "right"]),
                          Param(key: "dropBlanks", option: "drop-blanks", kind: .boolean, description: "Leave out black or empty pieces instead of reporting them."),
                          Param(key: "dryRun", option: "dry-run", kind: .boolean, description: "Report only; write nothing."),
                          Param(key: "overwrite", option: "overwrite", kind: .boolean, description: "Replace out if it exists.")]),
            Tool(name: "scoresort_split", command: "split",
                 description: "Split a PDF into one file per part, named \"<base><separator><part name>.pdf\", optionally numbered in score order (00 - Score, 01 - Flute …) and stamped — the Split tab's Steps 1–3. Give the parts (pages + name) after looking at them with scoresort_preview, or use the PDF's bookmarks. " + outputHint,
                 params: [Param(key: "file", option: nil, kind: .string, description: "Absolute path to the PDF.", required: true),
                          Param(key: "out", option: "out", kind: .string, description: "Absolute path of the folder for the part files (created if needed).", required: true),
                          Param(key: "parts", option: "part", kind: .pairs(key: "pages", value: "name", valueIsNumber: false),
                                description: "The parts, in order: [{\"pages\": \"1-4\", \"name\": \"Score\"}, {\"pages\": \"5-6\", \"name\": \"Flute 1\"}]. Pages are 1-based; non-adjacent pages like \"3,5\" are fine. Use instrument names (\"Clarinet 1\", \"Trumpet 2\") so score order recognises them."),
                          Param(key: "bookmarks", option: "bookmarks", kind: .boolean, description: "Use the PDF's bookmarks as the parts instead of parts."),
                          Param(key: "base", option: "base", kind: .string, description: "Start of every file name, usually \"Composer - Piece\". Leave out to name files by part alone."),
                          Param(key: "separator", option: "separator", kind: .string, description: "Between base and part name (default: the app's setting, \" - \")."),
                          Param(key: "skip", option: "skip", kind: .string, description: "Pages to leave out, e.g. \"8-9,17\" (black or empty pages)."),
                          Param(key: "scoreOrder", option: "score-order", kind: .string, description: "Number the files in this ensemble's score order.", choices: ["band", "jazz", "orchestra"]),
                          Param(key: "stamp", option: "stamp", kind: .string, description: "A saved stamp design to stamp onto each part (see scoresort_stamps)."),
                          Param(key: "stampScope", option: "stamp-scope", kind: .string, description: "first (default) or every page.", choices: ["first", "every"]),
                          Param(key: "dryRun", option: "dry-run", kind: .boolean, description: "Show the files that would be written; write nothing."),
                          Param(key: "overwrite", option: "overwrite", kind: .boolean, description: "Replace files that already exist.")]),
            Tool(name: "scoresort_rename", command: "rename",
                 description: "Number a folder of part files in score order (\"00 - Score.pdf\", \"01 - Flute 1.pdf\" …) by the instrument in each name — the Rename tab. Plans only unless apply is true: check the plan, then call again with apply.",
                 params: [Param(key: "paths", option: nil, kind: .strings, description: "Absolute path of the folder (or several files).", required: true),
                          Param(key: "ensemble", option: "ensemble", kind: .string, description: "Whose instrument order to use.", required: true, choices: ["band", "jazz", "orchestra"]),
                          Param(key: "numbers", option: "number", kind: .pairs(key: "file", value: "number", valueIsNumber: true),
                                description: "Numbers you choose, for parts with no recognisable instrument: [{\"file\": \"Bass Guitar.pdf\", \"number\": 14}]."),
                          Param(key: "exclude", option: "exclude", kind: .strings, description: "File names to leave alone."),
                          Param(key: "recursive", option: "recursive", kind: .boolean, description: "Include subfolders."),
                          Param(key: "rescan", option: "rescan", kind: .boolean, description: "Re-number files that already have numbers."),
                          Param(key: "apply", option: "apply", kind: .boolean, description: "Rename the files (otherwise only plan).")]),
            Tool(name: "scoresort_combine", command: "combine",
                 description: "Combine parts into one PDF to print, each part repeated for its number of players, with a bookmark per copy — the Combine tab. Copies come from a saved ensemble preset (scoresort_presets) and/or per file. Optional booklets and stamp. " + outputHint,
                 params: [Param(key: "paths", option: nil, kind: .strings, description: "Absolute paths of the part files, in order, or one folder (combined in name order).", required: true),
                          Param(key: "out", option: "out", kind: .string, description: "Absolute path of the PDF to write.", required: true),
                          Param(key: "preset", option: "preset", kind: .string, description: "A saved ensemble preset's name, to set each part's copies."),
                          Param(key: "copies", option: "copies", kind: .pairs(key: "file", value: "copies", valueIsNumber: true),
                                description: "Copies for particular files (after the preset): [{\"file\": \"Flute 1\", \"copies\": 3}] — file is the name or a unique part of it."),
                          Param(key: "booklet", option: "booklet", kind: .boolean, description: "Impose each part as a fold-and-staple booklet."),
                          Param(key: "sheet", option: "sheet", kind: .string, description: "Booklet paper: double (A4 pages on A3) or fit-a4 (A5 booklet).", choices: ["double", "fit-a4"]),
                          Param(key: "blankPages", option: "blank-pages", kind: .boolean, description: "Booklets: start every part on a fresh sheet."),
                          Param(key: "stamp", option: "stamp", kind: .string, description: "A saved stamp design."),
                          Param(key: "stampScope", option: "stamp-scope", kind: .string, description: "first (default) or every page.", choices: ["first", "every"]),
                          Param(key: "dryRun", option: "dry-run", kind: .boolean, description: "Show parts, copies and page total; write nothing."),
                          Param(key: "overwrite", option: "overwrite", kind: .boolean, description: "Replace out if it exists.")]),
            Tool(name: "scoresort_presets", command: "presets",
                 description: "List the ensemble presets saved in ScoreSort: each ensemble's parts and copies per part.",
                 params: []),
            Tool(name: "scoresort_stamps", command: "stamps",
                 description: "List the stamp designs saved in ScoreSort (school or ensemble names and the like).",
                 params: []),
            Tool(name: "scoresort_stamp", command: "stamp",
                 description: "Stamp a saved design onto PDFs or images, saving stamped copies in another folder (originals are never changed). " + outputHint,
                 params: [Param(key: "files", option: nil, kind: .strings, description: "Absolute paths of the files.", required: true),
                          Param(key: "stamp", option: "stamp", kind: .string, description: "The saved stamp's name.", required: true),
                          Param(key: "out", option: "out", kind: .string, description: "Absolute path of the folder for the stamped copies.", required: true),
                          Param(key: "scope", option: "scope", kind: .string, description: "every (default) or first page only.", choices: ["first", "every"]),
                          Param(key: "dryRun", option: "dry-run", kind: .boolean, description: "Write nothing."),
                          Param(key: "overwrite", option: "overwrite", kind: .boolean, description: "Replace stamped copies that already exist.")]),
        ]
    }

    static func schema(for tool: Tool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for p in tool.params {
            var prop: [String: Any] = ["description": p.description]
            switch p.kind {
            case .string: prop["type"] = "string"
            case .number: prop["type"] = "number"
            case .boolean: prop["type"] = "boolean"
            case .strings: prop["type"] = "array"; prop["items"] = ["type": "string"]
            case .pairs(let key, let value, let isNumber):
                prop["type"] = "array"
                prop["items"] = ["type": "object",
                                 "properties": [key: ["type": "string"], value: ["type": isNumber ? "integer" : "string"]],
                                 "required": [key, value]]
            }
            if let choices = p.choices { prop["enum"] = choices }
            if let d = p.defaultValue { prop["default"] = d }
            properties[p.key] = prop
        }
        return ["type": "object", "properties": properties,
                "required": tool.params.filter(\.required).map(\.key)]
    }

    /// The command line a tool call stands for.
    static func argv(for tool: Tool, arguments input: [String: Any]) throws -> [String] {
        var arguments = input
        tool.fillDefaults?(&arguments)
        var positionals: [String] = []
        var options: [String] = []
        for p in tool.params {
            guard let raw = arguments[p.key] ?? p.defaultValue, !(raw is NSNull) else {
                if p.required { throw CommandError("Missing “\(p.key)”.") }
                continue
            }
            var values: [String] = []
            switch p.kind {
            case .string:
                guard let s = raw as? String else { throw CommandError("“\(p.key)” should be text.") }
                values = [s]
            case .number:
                if let n = raw as? NSNumber { values = [n.stringValue] }
                else if let s = raw as? String, Double(s) != nil { values = [s] }
                else { throw CommandError("“\(p.key)” should be a number.") }
            case .boolean:
                let on = (raw as? Bool) ?? ((raw as? NSNumber)?.boolValue ?? false)
                if on, let option = p.option { options.append("--" + option) }
                continue
            case .strings:
                if let list = raw as? [Any] { values = list.compactMap { $0 as? String } }
                else if let s = raw as? String { values = [s] }
                else { throw CommandError("“\(p.key)” should be a list of text.") }
            case .pairs(let key, let value, _):
                guard let list = raw as? [[String: Any]] else {
                    throw CommandError("“\(p.key)” should be a list of {\"\(key)\": …, \"\(value)\": …}.")
                }
                values = try list.map { item in
                    guard let k = item[key].map({ "\($0)" }), let v = item[value].map({ "\($0)" }) else {
                        throw CommandError("Each of “\(p.key)” needs \"\(key)\" and \"\(value)\".")
                    }
                    return "\(k)=\(v)"
                }
            }
            if let option = p.option {
                for v in values { options += ["--" + option, v] }
            } else {
                positionals += values
            }
        }
        // `--` keeps a positional that starts with "--" from being read as an option.
        return options + ["--"] + positionals
    }

    // MARK: - Protocol

    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static var instructions: String {
        """
        ScoreSort manages music parts as PDFs. To split a PDF into named parts: scoresort_info, then \
        scoresort_preview to read the part names off the tops of the pages, then scoresort_split with \
        dryRun, then without. Scans with two pages side by side go through scoresort_split_scans first. \
        scoresort_guide has the full recipes. Use absolute paths.
        """
    }

    /// Handles one JSON-RPC message; returns the response, or nil for a notification.
    static func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        func reply(_ result: [String: Any]) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        }
        func failure(_ code: Int, _ text: String) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let asked = params?["protocolVersion"] as? String
            let version = asked.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
            return reply(["protocolVersion": version,
                          "capabilities": ["tools": ["listChanged": false]],
                          "serverInfo": ["name": "scoresort", "title": "ScoreSort", "version": ScoreSortCLI.appVersion],
                          "instructions": instructions])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": schema(for: $0)] }])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return failure(-32602, "Unknown tool: \(params["name"] ?? "none")")
            }
            return reply(callTool(tool, arguments: params["arguments"] as? [String: Any] ?? [:]))
        case "resources/list":
            return reply(["resources": [Any]()])
        case "prompts/list":
            return reply(["prompts": [Any]()])
        default:
            if method.hasPrefix("notifications/") { return nil }
            return failure(-32601, "Method not found: \(method)")
        }
    }

    static func callTool(_ tool: Tool, arguments: [String: Any]) -> [String: Any] {
        func errorResult(_ text: String) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": true]
        }
        if tool.command == "help" {
            return ["content": [["type": "text", "text": ScoreSortCLI.aiGuide]], "isError": false]
        }
        guard let spec = ScoreSortCLI.command(named: tool.command) else { return errorResult("Unknown command.") }
        do {
            let argv = try argv(for: tool, arguments: arguments)
            let parsed = try CommandArguments.parse(argv, valueOptions: spec.valueOptions, flagOptions: spec.flagOptions)
            let result = try spec.run(parsed)
            var content: [[String: Any]] = [["type": "text", "text": result.text + "\n\n" + jsonText(result.json)]]
            for url in result.images.prefix(12) {
                guard let data = try? Data(contentsOf: url) else { continue }
                let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mime])
            }
            if result.images.count > 12 {
                content.append(["type": "text", "text": "(\(result.images.count - 12) more images not shown — ask for fewer pages, or use sheet.)"])
            }
            return ["content": content, "structuredContent": result.json, "isError": result.isError]
        } catch {
            return errorResult((error as? CommandError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: - Running

    /// Serves MCP on stdin/stdout until stdin closes.
    static func run() -> Int32 {
        // stdout carries only protocol messages. Keep a private copy of it for those, and
        // point file descriptor 1 at stderr so any stray `print` from deep in the app goes to
        // the log rather than corrupting the stream.
        let protocolFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let output = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)

        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
            output.write(data + Data([0x0A]))
        }

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = object as? [[String: Any]] {
                let responses = batch.compactMap { handle($0) }
                if !responses.isEmpty, let data = try? JSONSerialization.data(withJSONObject: responses) {
                    output.write(data + Data([0x0A]))
                }
            } else if let message = object as? [String: Any], let response = handle(message) {
                send(response)
            }
        }
        return 0
    }
}

/// The guide `help ai` prints, and `scoresort_guide` returns.
let aiGuideText = "Run `ScoreSort help` for the commands."
