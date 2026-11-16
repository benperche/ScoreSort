//
//  SavedFileNoticeBanner.swift
//  ScoreSort
//
//  Tells the user, once, when one of their saved files (presets, stamps, instrument order)
//  couldn't be read and was set aside, or when saving failed. The stores publish
//  `SavedFileNotice`s (Logic/SavedListFile.swift); this shows them as a strip above the tabs
//  rather than an alert, so nothing has to be dismissed before getting on with work.
//

import SwiftUI
import AppKit

/// One notice: what happened, where the kept copy is, and a way to get rid of the strip.
struct SavedFileNoticeRow: View {
    let notice: SavedFileNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let url = notice.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Dismiss", action: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Puts the notices from both stores, and the instrument-order file's, above the content.
struct SavedFileNoticeBar: ViewModifier {
    @EnvironmentObject private var presetStore: EnsemblePresetStore
    @EnvironmentObject private var stampStore: StampStore
    /// `InstrumentOrders` is static, not observable: this mirrors its launch notice.
    @State private var orderNotice = InstrumentOrders.launchNotice

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            ForEach(presetStore.notices) { notice in
                SavedFileNoticeRow(notice: notice) {
                    presetStore.notices.removeAll { $0.id == notice.id }
                }
            }
            ForEach(stampStore.notices) { notice in
                SavedFileNoticeRow(notice: notice) {
                    stampStore.notices.removeAll { $0.id == notice.id }
                }
            }
            if let notice = orderNotice {
                SavedFileNoticeRow(notice: notice) {
                    InstrumentOrders.launchNotice = nil
                    orderNotice = nil
                }
            }
            content
        }
        // `InstrumentOrders.setup()` runs from the app delegate, which may be after this
        // view was first built.
        .onReceive(NotificationCenter.default.publisher(for: InstrumentOrders.launchNoticeChanged)) { _ in
            orderNotice = InstrumentOrders.launchNotice
        }
    }
}

extension View {
    /// Shows saved-file notices above this view. Needs the preset and stamp stores in the
    /// environment, as `ContentView` has.
    func savedFileNotices() -> some View { modifier(SavedFileNoticeBar()) }
}
