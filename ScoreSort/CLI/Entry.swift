//
//  Entry.swift
//  ScoreSort
//
//  The executable's entry point. A recognised command (`ScoreSort info …`, `ScoreSort mcp`)
//  runs headless and exits; anything else — a normal launch from Finder or Xcode, which
//  passes its own `-NS…` arguments — starts the app.
//
//  Branching here, before the SwiftUI app starts, means a command never touches the app's
//  launch side effects: Sparkle's launch count, the welcome tour, the window, or the
//  instrument-orders file rewrite.
//

import Foundation
import SwiftUI

@main
enum ScoreSortEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Tests run inside the app as their host; never let them take the command path.
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTests && ScoreSortCLI.isCommandLineInvocation(arguments) {
            exit(ScoreSortCLI.main(arguments))
        }
        ScoreSortApp.main()
    }
}
