//
//  MCPServerTests.swift
//  ScoreSortTests
//
//  `ScoreSort mcp`: the protocol handshake, the tool list and each tool's annotations
//  (read-only or file-changing), tool arguments becoming the command line's own, and —
//  by running the real executable — that stdout carries nothing but protocol messages.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// A tool as the MCP schema's `Tool` and `ToolAnnotations` define it — the fields ScoreSort
/// sends. Decoding is strict, so a missing field, or a hint sent as 1 instead of true, fails.
private struct ListedTool: Decodable {
    struct Annotations: Decodable {
        let title: String
        let readOnlyHint: Bool
        let destructiveHint: Bool
        let idempotentHint: Bool
        let openWorldHint: Bool
    }
    let name: String
    let title: String
    let description: String
    let annotations: Annotations
}

@Suite("MCP server")
@MainActor
struct MCPServerTests {

    @Test("initialize answers with the client's protocol version and the tools capability")
    func initialize() throws {
        let response = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]]))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test("Notifications get no reply; unknown methods get an error")
    func notificationsAndErrors() throws {
        #expect(ScoreSortMCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let response = try #require(ScoreSortMCPServer.handle(["jsonrpc": "2.0", "id": 9, "method": "nope"]))
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("Every tool's options exist on its command, and every schema is valid JSON")
    func toolsMatchCommands() throws {
        for tool in ScoreSortMCPServer.tools where tool.command != "help" {
            let spec = try #require(ScoreSortCLI.command(named: tool.command), "\(tool.name) has no command")
            for p in tool.params {
                guard let option = p.option else { continue }
                #expect(spec.valueOptions.contains(option) || spec.flagOptions.contains(option),
                        "\(tool.name).\(p.key) → --\(option) isn't an option of \(tool.command)")
            }
            #expect(JSONSerialization.isValidJSONObject(ScoreSortMCPServer.schema(for: tool)))
        }
    }

    // MARK: Annotations

    /// `tools/list` as a client receives it: serialised, then decoded strictly.
    private func listedTools() throws -> (decoded: [ListedTool], raw: [[String: Any]]) {
        let response = try #require(ScoreSortMCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let raw = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let data = try JSONSerialization.data(withJSONObject: raw)
        return (try JSONDecoder().decode([ListedTool].self, from: data), raw)
    }

    private func hint(_ name: String, of tool: ScoreSortMCPServer.Tool) -> Bool? {
        ScoreSortMCPServer.annotations(for: tool)[name] as? Bool
    }

    @Test("tools/list gives every tool a title and annotations, in the shape the MCP schema defines")
    func toolAnnotationsShape() throws {
        let (listed, raw) = try listedTools()
        #expect(listed.map(\.name) == ScoreSortMCPServer.tools.map(\.name))
        for tool in listed {
            #expect(!tool.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(tool.name) has no title")
            #expect(tool.title != tool.name, "\(tool.name)'s title should be for a person")
            // 2025-03-26 clients know only annotations.title; later ones read title first.
            #expect(tool.annotations.title == tool.title)
            // Everything is on this Mac.
            #expect(tool.annotations.openWorldHint == false, "\(tool.name)")
            // Read-only and destructive contradict each other.
            #expect(!(tool.annotations.readOnlyHint && tool.annotations.destructiveHint), "\(tool.name)")
        }
        #expect(Set(listed.map(\.title)).count == listed.count, "Two tools share a title")
        // Only fields the schema's Tool and ToolAnnotations define.
        for tool in raw {
            #expect(Set(tool.keys) == ["name", "title", "description", "inputSchema", "annotations"])
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(Set(annotations.keys) == ["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"])
        }
    }

    @Test("The read-only tools can't write: their commands have no --out, --apply or --overwrite")
    func readOnlyToolsCannotWrite() throws {
        let readOnly = ScoreSortMCPServer.tools.filter { hint("readOnlyHint", of: $0) == true }
        #expect(Set(readOnly.map(\.name)) == ["scoresort_guide", "scoresort_find", "scoresort_info",
                                              "scoresort_presets", "scoresort_stamps", "scoresort_allocate"])
        for tool in ScoreSortMCPServer.tools {
            // The guide isn't a command: it returns fixed text and takes no arguments.
            var options: Set<String> = []
            if tool.command == "help" {
                #expect(tool.params.isEmpty)
            } else {
                let spec = try #require(ScoreSortCLI.command(named: tool.command), "\(tool.name) has no command")
                options = spec.valueOptions.union(spec.flagOptions)
            }
            if hint("readOnlyHint", of: tool) == true {
                let writing = options.intersection(["out", "apply", "overwrite"])
                #expect(writing.isEmpty, "\(tool.name) is marked read-only, but \(tool.command) takes --\(writing.sorted().joined(separator: ", --"))")
            }
            // A command that can replace or rename what's already there is destructive,
            // even though it only does so when asked: the hint is per tool, not per call.
            if !options.isDisjoint(with: ["apply", "overwrite"]) {
                #expect(hint("destructiveHint", of: tool) == true, "\(tool.name) can change existing files")
                #expect(hint("idempotentHint", of: tool) == false, "\(tool.name)")
            }
        }
    }

    @Test("scoresort_rename, which moves and renames files, is not read-only")
    func renameIsNotReadOnly() throws {
        let rename = try #require(try listedTools().decoded.first { $0.name == "scoresort_rename" })
        #expect(rename.annotations.readOnlyHint == false)
        #expect(rename.annotations.destructiveHint == true)
    }

    @Test("A protocol revision that defines tool annotations and titles is supported, and is the fallback")
    func annotationsRevisionIsSupported() throws {
        // Annotations: 2025-03-26 on. A tool's top-level title: 2025-06-18 on.
        #expect(ScoreSortMCPServer.supportedVersions.contains("2025-06-18"))
        let response = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
        let answered = try #require((response["result"] as? [String: Any])?["protocolVersion"] as? String)
        #expect(answered == ScoreSortMCPServer.supportedVersions[0])
        #expect(answered >= "2025-06-18")
    }

    @Test("Tool arguments become the command line's arguments")
    func argumentsToArgv() throws {
        let tool = try #require(ScoreSortMCPServer.tools.first { $0.name == "scoresort_split" })
        let argv = try ScoreSortMCPServer.argv(for: tool, arguments: [
            "file": "/x/Band.pdf", "out": "/x/parts",
            "parts": [["pages": "1-2", "name": "Flute 1"], ["pages": "3", "name": "Oboe"]],
            "scoreOrder": "band", "dryRun": true, "overwrite": false])
        #expect(argv == ["--out", "/x/parts", "--part", "1-2=Flute 1", "--part", "3=Oboe",
                         "--score-order", "band", "--dry-run", "--", "/x/Band.pdf"])
        #expect(throws: CommandError.self) { try ScoreSortMCPServer.argv(for: tool, arguments: ["file": "/x/Band.pdf"]) }
    }

    @Test("A tool call runs the command; a bad one comes back as an error result")
    func toolCall() throws {
        let folder = temporaryFolder("mcp")
        let file = folder.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 4, to: file)
        let shared = AIFileAccess(sharedFolders: [folder], allowsGivenPaths: false)
        let ok = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "scoresort_split",
                        "arguments": ["file": file.path, "out": folder.appendingPathComponent("parts").path,
                                      "parts": [["pages": "1-2", "name": "Flute"], ["pages": "3-4", "name": "Oboe"]]]]],
            access: shared))
        let result = try #require(ok["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("parts/Oboe.pdf").path))

        let bad = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "scoresort_info", "arguments": ["file": "/no/such.pdf"]]], access: shared))
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test("preview returns the pages as images")
    func previewImages() throws {
        let folder = temporaryFolder("mcp")
        let file = folder.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 3, to: file)
        let response = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": ["name": "scoresort_preview", "arguments": ["file": file.path]]],
            access: AIFileAccess(sharedFolders: [folder], allowsGivenPaths: false)))
        let content = try #require((response["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "image" }
        #expect(images.count == 1)   // one contact sheet
        #expect(images.first?["mimeType"] as? String == "image/jpeg")
    }

    @Test("The real executable speaks only protocol on stdout")
    func stdoutIsProtocolOnly() throws {
        let executable = try #require(Bundle.main.executableURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp"]
        // Not the test host's environment: that would keep the executable out of command mode.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("DYLD") && !$0.key.hasPrefix("XCInject")
        }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scoresort_info","arguments":{"file":"/no/such.pdf"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["jsonrpc"] as? String == "2.0")
        }
        #expect(process.terminationStatus == 0)
    }
}

@Suite("MCP: only the shared folders")
struct MCPFileAccessTests {

    private func call(_ name: String, _ arguments: [String: Any], _ access: AIFileAccess) throws -> (isError: Bool, text: String) {
        let response = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]],
            access: access))
        let result = try #require(response["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    @Test("a file outside the shared folders is refused, saying how to allow it; inside works")
    func insideAndOutside() throws {
        let shared = temporaryFolder("shared"), elsewhere = temporaryFolder("elsewhere")
        let inside = shared.appendingPathComponent("In.pdf"), outside = elsewhere.appendingPathComponent("Out.pdf")
        writeDrawnPDF(pages: 1, to: inside)
        writeDrawnPDF(pages: 1, to: outside)
        let access = AIFileAccess(sharedFolders: [shared], allowsGivenPaths: false)
        #expect(try call("scoresort_info", ["file": inside.path], access).isError == false)
        let refused = try call("scoresort_info", ["file": outside.path], access)
        #expect(refused.isError)
        #expect(refused.text.contains("Settings ▸ AI Assistants"))
    }

    @Test("an output outside the shared folders is refused, and nothing is written")
    func outputOutside() throws {
        let shared = temporaryFolder("shared"), elsewhere = temporaryFolder("elsewhere")
        let file = shared.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 2, to: file)
        let access = AIFileAccess(sharedFolders: [shared], allowsGivenPaths: false)
        let out = elsewhere.appendingPathComponent("parts")
        let result = try call("scoresort_split", ["file": file.path, "out": out.path,
                                                  "parts": [["pages": "1-2", "name": "Flute"]]], access)
        #expect(result.isError)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("..  and symlinks can't reach outside a shared folder")
    func noEscapes() throws {
        let shared = temporaryFolder("shared"), elsewhere = temporaryFolder("elsewhere")
        let secret = elsewhere.appendingPathComponent("Secret.pdf")
        writeDrawnPDF(pages: 1, to: secret)
        let link = shared.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let access = AIFileAccess(sharedFolders: [shared], allowsGivenPaths: false)
        #expect(!access.allows(link.appendingPathComponent("Secret.pdf").path))
        #expect(!access.allows(shared.path + "/../" + elsewhere.lastPathComponent + "/Secret.pdf"))
        // A sibling folder whose name merely starts the same isn't inside.
        #expect(!access.allows(shared.path + "-other/x.pdf"))
        #expect(access.allows(shared.appendingPathComponent("New folder/new.pdf").path))   // not made yet: fine
    }

    @Test("letter case doesn't matter, as on the Mac's disks")
    func caseInsensitive() throws {
        let shared = temporaryFolder("shared")
        let file = shared.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 1, to: file)
        let access = AIFileAccess(sharedFolders: [shared], allowsGivenPaths: false)
        let caseInsensitive = (try? shared.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) == false
        if caseInsensitive { #expect(access.allows(shared.path.uppercased() + "/BAND.PDF")) }
    }

    @Test("with “allow files I give by path” on, any path is used, as before")
    func allowGiven() throws {
        let elsewhere = temporaryFolder("elsewhere")
        let file = elsewhere.appendingPathComponent("Out.pdf")
        writeDrawnPDF(pages: 1, to: file)
        let access = AIFileAccess(sharedFolders: [], allowsGivenPaths: true)
        #expect(try call("scoresort_info", ["file": file.path], access).isError == false)
    }

    @Test("find's search words aren't paths; its folders are checked")
    func findWords() throws {
        let shared = temporaryFolder("shared"), elsewhere = temporaryFolder("elsewhere")
        let access = AIFileAccess(sharedFolders: [shared], allowsGivenPaths: false)
        #expect(try call("scoresort_find", ["words": ["holst"], "folders": [shared.path]], access).isError == false)
        #expect(try call("scoresort_find", ["words": ["holst"], "folders": [elsewhere.path]], access).isError)
    }

    @Test("preview's own image folder is always allowed")
    func previewScratch() {
        let access = AIFileAccess(sharedFolders: [], allowsGivenPaths: false)
        #expect(access.allows(AIFileAccess.previewScratchFolder.appendingPathComponent("abc/x.jpg").path))
    }
}
