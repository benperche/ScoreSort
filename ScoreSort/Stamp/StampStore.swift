//
//  StampStore.swift
//  ScoreSort
//
//  Persistence for saved stamp designs — `stamps.json` in Application Support, the third
//  independent store alongside `ensemble-presets.json` (Combine presets) and
//  `instrument-orders.json` (Renamer order). Same shape as `EnsemblePresetStore`; both read
//  and write through `SavedListFile` (Logic/SavedListFile.swift).
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

    /// Anything the user should be told about the stamps file — it couldn't be read and was
    /// set aside, or a save failed. Shown by `SavedFileNoticeBanner`; never an alert from here.
    @Published var notices: [SavedFileNotice] = []

    /// `stamps.json` in the app's Application Support folder.
    static var defaultFileURL: URL? { scoreSortSupportFile("stamps.json") }

    /// Loading and saving go through `SavedListFile` (Logic/SavedListFile.swift), which sets
    /// an unreadable file aside before anything can save over it.
    private var file: SavedListFile<Stamp>

    /// `fileURL` is injectable so tests use a temporary folder; `nil` keeps stamps in memory only.
    init(fileURL: URL? = StampStore.defaultFileURL) {
        file = SavedListFile(url: fileURL, kind: .stamps)
        let loaded = file.load()
        stamps = loaded.entries
        notices = loaded.notices
        // Seed a starter design so the picker and preview are never empty on first use.
        if stamps.isEmpty {
            stamps = [Stamp(name: "Ensemble Name", text: "Example School Band")]
        }
        selectedStampId = stamps.first?.id
    }

    // MARK: - Persistence

    /// Pending debounced write, if any.
    private var pendingSave: DispatchWorkItem?

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    /// Coalesces the writes that come from typing. Encoding the whole store and writing it
    /// atomically on **every keystroke** was a large part of why the text fields felt laggy;
    /// the in-memory model still updates immediately, so nothing on screen waits for this.
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.writeToDisk()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes any pending change out now — called when leaving the tab, so a stamp edited
    /// and immediately abandoned still lands on disk.
    func flushPendingSave() {
        guard pendingSave != nil else { return }
        save()
    }

    private func writeToDisk() {
        if let failure = file.save(stamps) { notices.append(failure) }
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
        scheduleSave()
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
