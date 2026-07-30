//
//  StampStore.swift
//  ScoreSort
//
//  Persistence for saved stamp designs — `stamps.json` in Application Support, the third
//  independent store alongside `ensemble-presets.json` (Combine presets) and
//  `instrument-orders.json` (Renamer order). Same shape as `EnsemblePresetStore`.
//

import Foundation
import Combine
import SwiftUI

final class StampStore: ObservableObject {
    @Published var stamps: [Stamp] = []
    @Published var selectedStampId: UUID?

    var selectedStamp: Stamp? {
        stamps.first { $0.id == selectedStampId } ?? stamps.first
    }

    private var storeURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = dir.appendingPathComponent("ScoreSort", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("stamps.json")
    }

    init() {
        load()
        // Seed a starter design so the picker and preview are never empty on first use.
        if stamps.isEmpty {
            stamps = [Stamp(name: "Ensemble Name", text: "Example School Band")]
        }
        if selectedStampId == nil { selectedStampId = stamps.first?.id }
    }

    // MARK: - Persistence

    func save() {
        guard let url = storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(stamps) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Stamp].self, from: data)
        else { return }
        stamps = decoded
        selectedStampId = stamps.first?.id
    }

    // MARK: - Editing

    @discardableResult
    func addStamp(name: String = "New Stamp", text: String = "") -> Stamp {
        let stamp = Stamp(name: name, text: text)
        stamps.append(stamp)
        selectedStampId = stamp.id
        save()
        return stamp
    }

    func updateStamp(_ stamp: Stamp) {
        guard let idx = stamps.firstIndex(where: { $0.id == stamp.id }) else { return }
        guard stamps[idx] != stamp else { return }   // avoid pointless writes while typing
        stamps[idx] = stamp
        save()
    }

    func deleteStamp(_ id: UUID) {
        stamps.removeAll { $0.id == id }
        if selectedStampId == id { selectedStampId = stamps.first?.id }
        save()
    }

    func duplicateStamp(_ id: UUID) {
        guard let original = stamps.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = "Copy of \(original.name)"
        if let idx = stamps.firstIndex(where: { $0.id == id }) {
            stamps.insert(copy, at: idx + 1)
        } else {
            stamps.append(copy)
        }
        selectedStampId = copy.id
        save()
    }

    func moveStamps(from: IndexSet, to: Int) {
        stamps.move(fromOffsets: from, toOffset: to)
        save()
    }
}
