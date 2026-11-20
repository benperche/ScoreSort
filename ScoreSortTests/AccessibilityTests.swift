//
//  AccessibilityTests.swift
//  ScoreSortTests
//
//  #22: what VoiceOver hears. Every icon-only button has a spoken label (checked over the
//  source, so a new one can't slip in), and rows say in words what their colours show.
//

import Testing
import Foundation
@testable import ScoreSort

@Suite("Accessibility")
struct AccessibilityTests {

    /// The app's Swift sources, found from this file's path (ScoreSortTests/ → ScoreSort/).
    private func sourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ScoreSort")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "couldn't find the app's sources at \(root.path)")
        return files
    }

    @Test("every button that shows only an icon has a spoken label")
    func iconButtonsAreLabelled() throws {
        var unlabelled: [String] = []
        for file in try sourceFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("Image(systemName:") {
                // A Button just above, with no text-bearing label in between: an icon-only button.
                guard let b = (max(0, i - 3)...i).last(where: { lines[$0].range(of: #"\bButton\b"#, options: .regularExpression) != nil })
                else { continue }
                let between = lines[b...i].joined(separator: "\n")
                if between.contains("Text(") || between.contains("Label(") || between.contains("Button(\"") { continue }
                let after = lines[i..<min(lines.count, i + 13)].joined(separator: "\n")
                if !after.contains("accessibilityLabel") && !after.contains("accessibilityHidden") {
                    unlabelled.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(unlabelled.isEmpty, "Icon-only buttons with no .accessibilityLabel: \(unlabelled.joined(separator: ", "))")
    }

    @MainActor
    @Test("a Combine row says what its colours mean")
    func combineRowStatus() {
        let file = CombineFile(url: URL(fileURLWithPath: "/tmp/Flute.pdf"), name: "Flute", pageCount: 3, copies: 2)
        func row(unmatched: Bool = false, split: Bool = false, grouped: Bool = false) -> CombineFileRow {
            CombineFileRow(file: file, isSelected: false, isFocused: false, isUnmatched: unmatched,
                           hasSplitCopies: split, isGrouped: grouped,
                           onToggleSelect: {}, onRowTap: {}, onCopiesChanged: { _ in }, onRemove: {})
        }
        #expect(row().accessibilityStatus == "3 pages, 2 copies")
        #expect(row(unmatched: true).accessibilityStatus.contains("not in the preset"))
        #expect(row(split: true).accessibilityStatus.contains("shared out by the preset"))
        #expect(row(grouped: true).accessibilityStatus == "3 pages, in a collate group")
    }
}
