//
//  CommandSupport.swift
//  ScoreSort
//
//  The plumbing shared by ScoreSort's command line and its MCP server: what a command
//  returns, how arguments are read, page ranges, and JSON output.
//
//  Commands are written once (CLI/Commands*.swift) and reached two ways — as
//  `ScoreSort <verb> …` in a terminal, and as `scoresort_<verb>` tools over MCP — so an
//  AI assistant can use the same ScoreSort logic as the app, with the same results.
//

import Foundation
import PDFKit

/// What a command produced: text for a person, JSON for a program, and any images
/// (preview PNGs) an MCP client should be shown.
struct CommandResult {
    var text: String
    var json: [String: Any]
    var exitCode: Int32 = 0
    /// PNG files to hand back as images over MCP.
    var images: [URL] = []

    var isError: Bool { exitCode != 0 }
}

/// A failure with a message meant for the person (or AI) running the command.
struct CommandError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Arguments

/// Command-line arguments split into positionals, valued options (repeatable) and flags.
/// Shared by the CLI and, after converting a tool call's JSON, by MCP.
struct CommandArguments {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let v = value(name), !v.isEmpty else { throw CommandError("Missing --\(name).") }
        return v
    }

    func int(_ name: String) throws -> Int? {
        guard let v = value(name) else { return nil }
        guard let n = Int(v) else { throw CommandError("--\(name) needs a whole number, not “\(v)”.") }
        return n
    }

    func double(_ name: String) throws -> Double? {
        guard let v = value(name) else { return nil }
        guard let n = Double(v) else { throw CommandError("--\(name) needs a number, not “\(v)”.") }
        return n
    }

    /// Parses `argv` (without the verb) against a command's options. `--name value`,
    /// `--name=value` and bare `--flag` are accepted; anything unknown is an error so a
    /// typo never silently changes what gets written.
    static func parse(_ argv: [String], valueOptions: Set<String>, flagOptions: Set<String>) throws -> CommandArguments {
        var result = CommandArguments()
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                result.positionals.append(contentsOf: argv[(i + 1)...])
                break
            }
            if arg.hasPrefix("--") && arg.count > 2 {
                var name = String(arg.dropFirst(2))
                var inline: String? = nil
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if valueOptions.contains(name) {
                    let value: String
                    if let inline {
                        value = inline
                    } else {
                        guard i + 1 < argv.count else { throw CommandError("--\(name) needs a value.") }
                        value = argv[i + 1]
                        i += 1
                    }
                    result.values[name, default: []].append(value)
                } else if flagOptions.contains(name) {
                    guard inline == nil else { throw CommandError("--\(name) doesn't take a value.") }
                    result.flags.insert(name)
                } else {
                    throw CommandError("Unknown option --\(name).")
                }
            } else {
                result.positionals.append(arg)
            }
            i += 1
        }
        return result
    }
}

// MARK: - Page ranges

/// Parses a 1-based page list like `1-3,5,8-` or `all` into 0-based indices, in the
/// order given, without duplicates. Every page must exist.
func parsePageList(_ text: String, pageCount: Int) throws -> [Int] {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty || trimmed == "all" { return Array(0..<pageCount) }
    var result: [Int] = []
    var seen = Set<Int>()
    for rawPart in trimmed.split(separator: ",") {
        let part = rawPart.trimmingCharacters(in: .whitespaces)
        let bounds: (Int, Int)
        if let dash = part.firstIndex(of: "-") {
            let lo = part[..<dash].trimmingCharacters(in: .whitespaces)
            let hi = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            guard let first = lo.isEmpty ? 1 : Int(lo),
                  let last = hi.isEmpty ? pageCount : Int(hi) else {
                throw CommandError("“\(part)” isn't a page range (try 1-3, 5 or 8-).")
            }
            bounds = (first, last)
        } else {
            guard let page = Int(part) else { throw CommandError("“\(part)” isn't a page number.") }
            bounds = (page, page)
        }
        guard bounds.0 >= 1, bounds.1 <= pageCount, bounds.0 <= bounds.1 else {
            throw CommandError("Pages \(part) are outside 1–\(pageCount).")
        }
        for p in bounds.0...bounds.1 where seen.insert(p - 1).inserted { result.append(p - 1) }
    }
    return result
}

/// 0-based page indices as a compact 1-based list: `[0,1,2,4]` → `1-3, 5`.
func describePages(_ pages: [Int]) -> String {
    pageRangeText(pages.sorted().map { $0 + 1 })
}

private func pageRangeText(_ oneBased: [Int]) -> String {
    var parts: [String] = []
    var i = 0
    while i < oneBased.count {
        var j = i
        while j + 1 < oneBased.count && oneBased[j + 1] == oneBased[j] + 1 { j += 1 }
        parts.append(i == j ? "\(oneBased[i])" : "\(oneBased[i])-\(oneBased[j])")
        i = j + 1
    }
    return parts.joined(separator: ", ")
}

// MARK: - Files

/// An existing file, resolved (with `~` expanded) to an absolute URL.
func existingFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw CommandError("No file at \(url.path).")
    }
    guard !isDir.boolValue else { throw CommandError("\(url.path) is a folder, not a file.") }
    return url
}

/// A folder to write into, created if it doesn't exist yet.
func outputFolder(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        guard isDir.boolValue else { throw CommandError("\(url.path) is a file, not a folder.") }
    } else {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CommandError("Couldn't create the folder \(url.path): \(error.localizedDescription)")
        }
    }
    return url
}

/// Opens a PDF, or says why it can't be.
func openPDFDocument(_ url: URL) throws -> PDFDocument {
    guard let doc = PDFDocument(url: url) else {
        throw CommandError("\(url.lastPathComponent) couldn't be opened as a PDF.")
    }
    if doc.isLocked { throw CommandError("\(url.lastPathComponent) is password-protected.") }
    return doc
}

// MARK: - JSON

func jsonText(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

/// Rounds for JSON so sizes read as 841.9, not 841.8897637795275.
func rounded(_ value: Double, places: Int = 1) -> Double {
    let f = pow(10, Double(places))
    return (value * f).rounded() / f
}
