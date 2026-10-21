//
//  MCPServer.swift
//  ScoreSort
//
//  `ScoreSort mcp` — ScoreSort's commands as MCP tools. (Being built.)
//

import Foundation

enum ScoreSortMCPServer {
    static func run() -> Int32 {
        ScoreSortCLI.printError("The MCP server isn't finished yet.")
        return 1
    }
}

/// The guide `help ai` prints. (Being written.)
let aiGuideText = "Run `ScoreSort help` for the commands."
