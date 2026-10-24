//
//  CLI.swift
//  ScoreSort
//
//  ScoreSort's command line: `ScoreSort <verb> [options]`, run from the app's own
//  executable (/Applications/ScoreSort.app/Contents/MacOS/ScoreSort). Built so an AI
//  assistant with a terminal can do what the app does — inspect a PDF, look at its pages,
//  split and name parts, number them in score order, stamp, combine — through the same
//  code, with the same results.
//
//  Rules every command follows: `--json` for structured output; nothing is overwritten
//  without `--overwrite`; writing commands take `--dry-run`; errors say why.
//

import Foundation

/// One command: its name, help, the options it accepts, and what it does.
struct CommandSpec {
    let name: String
    /// One line, for the command list.
    let summary: String
    /// Full help: usage, options, examples.
    let help: String
    let valueOptions: Set<String>
    let flagOptions: Set<String>
    let run: (CommandArguments) throws -> CommandResult
}

enum ScoreSortCLI {

    /// Every command, in the order `help` lists them.
    static var commands: [CommandSpec] {
        [findCommand, infoCommand, previewCommand, splitScansCommand, splitCommand, renameCommand, allocateCommand, combineCommand, presetsCommand, stampCommand, stampsCommand]
    }

    static func command(named name: String) -> CommandSpec? {
        commands.first { $0.name == name }
    }

    /// Words that switch the executable into command-line mode. Only explicit verbs:
    /// Xcode and Launch Services pass their own `-NS…` arguments on a normal launch.
    static func isCommandLineInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return command(named: first) != nil || ["help", "--help", "version", "--version", "mcp"].contains(first)
    }

    /// Runs one command line (without the executable path) and returns the exit code.
    static func main(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { print(generalHelp); return 0 }
        let rest = Array(arguments.dropFirst())

        switch verb {
        case "help", "--help":
            if let topic = rest.first {
                if topic == "ai" { print(aiGuide); return 0 }
                guard let spec = command(named: topic) else {
                    printError("No command called “\(topic)”. Run `ScoreSort help` for the list.")
                    return 2
                }
                print(spec.help)
            } else {
                print(generalHelp)
            }
            return 0
        case "version", "--version":
            print("ScoreSort \(appVersion)")
            return 0
        case "mcp":
            return ScoreSortMCPServer.run()
        default:
            break
        }

        guard let spec = command(named: verb) else {
            printError("No command called “\(verb)”. Run `ScoreSort help` for the list.")
            return 2
        }
        let wantsJSON = rest.contains("--json")
        do {
            let args = try CommandArguments.parse(rest,
                                                  valueOptions: spec.valueOptions,
                                                  flagOptions: spec.flagOptions.union(["json"]))
            let result = try spec.run(args)
            print(wantsJSON ? jsonText(result.json) : result.text)
            return result.exitCode
        } catch {
            let message = (error as? CommandError)?.message ?? error.localizedDescription
            if wantsJSON {
                print(jsonText(["ok": false, "error": message]))
            } else {
                printError(message + "\nRun `ScoreSort help \(verb)` for usage.")
            }
            return 1
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data(("ScoreSort: " + message + "\n").utf8))
    }

    static var generalHelp: String {
        let width = commands.map(\.name.count).max() ?? 8
        let list = commands.map { "  " + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
        return """
        ScoreSort \(appVersion) — manage music PDFs from the command line.

        Usage: ScoreSort <command> [options]      (add --json to any command for JSON output)

        Commands:
        \(list.joined(separator: "\n"))

          help <command>   Full help for one command
          help ai          A guide for AI assistants: the recipes for common jobs
          mcp              Run as an MCP server (for AI chat apps), over stdin/stdout
          version          Print the version

        Nothing is overwritten unless you add --overwrite, and every command that writes
        files accepts --dry-run to show what it would do first.
        """
    }

    /// Filled in fully once every command exists; see `help ai`.
    static var aiGuide: String { aiGuideText }
}
