//
//  MCPServerTests.swift
//  ScoreSortTests
//
//  `ScoreSort mcp`: the protocol handshake, the tool list, tool arguments becoming the
//  command line's own, and — by running the real executable — that stdout carries
//  nothing but protocol messages.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

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
        let ok = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "scoresort_split",
                        "arguments": ["file": file.path, "out": folder.appendingPathComponent("parts").path,
                                      "parts": [["pages": "1-2", "name": "Flute"], ["pages": "3-4", "name": "Oboe"]]]]]))
        let result = try #require(ok["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("parts/Oboe.pdf").path))

        let bad = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "scoresort_info", "arguments": ["file": "/no/such.pdf"]]]))
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test("preview returns the pages as images")
    func previewImages() throws {
        let folder = temporaryFolder("mcp")
        let file = folder.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 3, to: file)
        let response = try #require(ScoreSortMCPServer.handle(
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": ["name": "scoresort_preview", "arguments": ["file": file.path]]]))
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
