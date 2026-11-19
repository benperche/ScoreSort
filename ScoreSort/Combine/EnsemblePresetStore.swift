//
//  EnsemblePresetStore.swift
//  ScoreSort
//
//  Ensemble presets: the PresetPart / EnsemblePreset model and EnsemblePresetStore, which
//  keeps them in ensemble-presets.json through SavedListFile, plus the built-in templates.
//  Used by the Combine tab's sidebar and the Combiner preferences pane. Moved out of
//  CombineTab.swift.
//

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Ensemble Preset Model

struct PresetPart: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var copies: Int
}

struct EnsemblePreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var parts: [PresetPart]
    /// A saved stamp this ensemble belongs to — a school or organisation's mark. Applying
    /// the preset arms that stamp for the output. Optional, and an optional property decodes
    /// as nil when absent, so presets saved before this keep working.
    var stampId: UUID?
}

class EnsemblePresetStore: ObservableObject {
    @Published var presets: [EnsemblePreset] = []
    @Published var selectedPresetId: UUID?

    var selectedPreset: EnsemblePreset? {
        presets.first { $0.id == selectedPresetId }
    }

    /// Anything the user should be told about the presets file — it couldn't be read and was
    /// set aside, or a save failed. Shown by `SavedFileNoticeBanner`; never an alert from here.
    @Published var notices: [SavedFileNotice] = []

    /// `ensemble-presets.json` in the app's Application Support folder.
    static var defaultFileURL: URL? { scoreSortSupportFile("ensemble-presets.json") }

    /// Loading and saving go through `SavedListFile` (Logic/SavedListFile.swift), which sets
    /// an unreadable file aside before anything can save over it.
    private var file: SavedListFile<EnsemblePreset>

    /// `fileURL` is injectable so tests use a temporary folder; `nil` keeps presets in memory only.
    init(fileURL: URL? = EnsemblePresetStore.defaultFileURL) {
        file = SavedListFile(url: fileURL, kind: .presets)
        let loaded = file.load()
        presets = loaded.entries
        notices = loaded.notices
        selectedPresetId = presets.first?.id
    }

    func save() {
        if let failure = file.save(presets) { notices.append(failure) }
    }

    func addPreset(name: String, parts: [PresetPart]) {
        let p = EnsemblePreset(name: name, parts: parts)
        presets.append(p)
        selectedPresetId = p.id
        save()
    }

    func updatePreset(_ preset: EnsemblePreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetId == id {
            selectedPresetId = presets.first?.id
        }
        save()
    }

    func movePresets(from: IndexSet, to: Int) {
        presets.move(fromOffsets: from, toOffset: to)
        save()
    }

    func duplicatePreset(_ id: UUID) {
        guard let original = presets.first(where: { $0.id == id }) else { return }
        let copy = EnsemblePreset(
            id: UUID(),
            name: "Copy of \(original.name)",
            parts: original.parts.map { PresetPart(id: UUID(), name: $0.name, copies: $0.copies) }
        )
        if let idx = presets.firstIndex(where: { $0.id == id }) {
            presets.insert(copy, at: idx + 1)
        } else {
            presets.append(copy)
        }
        selectedPresetId = copy.id
        save()
    }

    func exportCSV() -> String {
        var lines = ["Preset Name,Part Name,Copies"]
        for preset in presets {
            for part in preset.parts {
                func escape(_ s: String) -> String {
                    s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
                }
                lines.append("\(escape(preset.name)),\(escape(part.name)),\(part.copies)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func importCSV(_ string: String) {
        var partsByPreset: [String: [PresetPart]] = [:]
        var order: [String] = []
        let lines = string.components(separatedBy: .newlines).dropFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = Self.parseCSVLine(trimmed)
            guard fields.count >= 2 else { continue }
            let presetName = fields[0]
            let partName   = fields[1]
            let copies     = fields.count >= 3 ? (Int(fields[2]) ?? 1) : 1
            if partsByPreset[presetName] == nil {
                partsByPreset[presetName] = []
                order.append(presetName)
            }
            partsByPreset[presetName]?.append(PresetPart(name: partName, copies: copies))
        }
        for name in order {
            if let parts = partsByPreset[name], !parts.isEmpty {
                addPreset(name: name, parts: parts)
            }
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    // MARK: - Built-in templates

    static let windBandTemplate: [PresetPart] = [
        "Score",
        "Piccolo", "Flute 1", "Flute 2",
        "Oboe", "Bassoon",
        "Clarinet 1", "Clarinet 2", "Clarinet 3",
        "Bass Clarinet",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone", "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3",
        "Horn 1", "Horn 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Euphonium BC", "Tuba",
        "Timpani",
        "Percussion 1", "Percussion 2", "Percussion 3",
    ].map { PresetPart(name: $0, copies: 1) }

    static let jazzTemplate: [PresetPart] = [
        "Score",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone 1", "Tenor Saxophone 2",
        "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3", "Trumpet 4",
        "Trombone 1", "Trombone 2", "Trombone 3", "Bass Trombone",
        "Guitar", "Piano", "Bass", "Drums",
    ].map { PresetPart(name: $0, copies: 1) }

    static let orchestraTemplate: [PresetPart] = [
        "Score",
        "Flute 1", "Flute 2", "Piccolo",
        "Oboe 1", "Oboe 2",
        "Clarinet 1", "Clarinet 2",
        "Bassoon 1", "Bassoon 2",
        "Horn 1", "Horn 2", "Horn 3", "Horn 4",
        "Trumpet 1", "Trumpet 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Tuba",
        "Timpani", "Percussion",
        "Harp",
        "Violin I", "Violin II",
        "Viola", "Cello", "Double Bass",
    ].map { PresetPart(name: $0, copies: 1) }
}
