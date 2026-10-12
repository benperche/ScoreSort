//
//  SplitBookmarks.swift
//  ScoreSort
//
//  The sheet shown when a PDF opened in the Split tab already has bookmarks:
//  split at them, name the files from their titles, or ignore them.
//

import SwiftUI

/// A pending "this PDF has bookmarks — use them?" prompt.
struct BookmarkOffer: Identifiable {
    let id = UUID()
    let sections: [BookmarkSection]
    /// The PDF's own name — the piece name when the titles don't carry one.
    let sourceName: String
}

// MARK: - Bookmark Split Choice View

/// Shows the names the bookmarks would give the files, so it's clear whether the
/// titles are worth using before choosing. Nothing here is final: split points and
/// names stay editable in Steps 1 and 2.
struct BookmarkSplitChoiceView: View {
    let offer: BookmarkOffer
    /// Split at the bookmarks and name the files in the given style.
    let onSplitAndName: (BookmarkNameStyle) -> Void
    /// Split at the bookmarks, leaving the names to Step 2.
    let onSplitOnly: () -> Void
    let onIgnore: () -> Void

    /// Sticky, so a run of similar PDFs doesn't need the same choice made each time.
    @AppStorage("splitBookmarkNameStyle") private var nameStyle: BookmarkNameStyle = .pieceAndTitle
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "

    private var names: (baseName: String, suffixes: [String]) {
        bookmarkSplitNames(titles: offer.sections.map { $0.title },
                           fallbackBaseName: offer.sourceName,
                           style: nameStyle)
    }

    private func pageRange(_ section: BookmarkSection) -> String {
        let first = section.startPage + 1
        let last = section.startPage + section.pageCount
        return first == last ? "p. \(first)" : "p. \(first)–\(last)"
    }

    /// Which end to cut when a line is too long. Long titles usually share one end
    /// ("Composer - Piece - …") and differ at the other, so cut the shared end —
    /// cutting the middle hid the instrument, the one part worth reading.
    private func truncation(for texts: [String]) -> Text.TruncationMode {
        let distinct = texts.filter { !$0.isEmpty }
        guard let first = distinct.first, distinct.count > 1 else { return .tail }
        let sharedStart = distinct.reduce(first) { $0.commonPrefix(with: $1) }.count
        let sharedEnd = distinct.map { String($0.reversed()) }
            .reduce(String(first.reversed())) { $0.commonPrefix(with: $1) }.count
        return sharedStart > sharedEnd ? .head : .tail
    }

    /// One complete file name, its base dimmed so the part that changes from file to
    /// file stands out. Shown once: the list below gives only that changing part,
    /// because repeating a long shared piece name on every row buried it.
    private func exampleFileName(_ names: (baseName: String, suffixes: [String])) -> AttributedString {
        let index = names.suffixes.firstIndex { !$0.isEmpty } ?? 0
        let full = splitOutputFileName(base: names.baseName, separator: filenameSeparator,
                                       suffix: names.suffixes[index], fileIndex: index)
        let leadCount = names.baseName.isEmpty ? 0 : (names.baseName + filenameSeparator).count
        var lead = AttributedString(String(full.prefix(leadCount)))
        lead.swiftUI.foregroundColor = .secondary
        var rest = AttributedString(String(full.dropFirst(leadCount)))
        rest.swiftUI.font = .callout.weight(.semibold)
        return lead + rest
    }

    var body: some View {
        let names = names
        let nameTruncation = truncation(for: names.suffixes)
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("This PDF Has Bookmarks")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("ScoreSort can split it into \(offer.sections.count) files at the bookmarks, and name each file from its bookmark's title. You can still change the split points and names afterwards.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Name files by", selection: $nameStyle) {
                Text("Piece + Bookmark Title").tag(BookmarkNameStyle.pieceAndTitle)
                Text("Bookmark Title Only").tag(BookmarkNameStyle.titleOnly)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            VStack(spacing: 2) {
                Text("Files will be named like")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(exampleFileName(names))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(offer.sections.enumerated()), id: \.offset) { index, section in
                        GridRow {
                            Text(pageRange(section))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            if names.suffixes[index].isEmpty {
                                Text("No bookmark — numbered \(index + 1)")
                                    .italic()
                                    .foregroundColor(.secondary)
                            } else {
                                Text(names.suffixes[index])
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .truncationMode(nameTruncation)
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            HStack {
                Button("Ignore Bookmarks") { onIgnore() }
                    .keyboardShortcut(.cancelAction)
                    .help("Open the PDF as one file and place the splits yourself")
                Spacer()
                Button("Split Only") { onSplitOnly() }
                    .help("Split at the bookmarks, and name the files yourself in Step 2")
                Button("Split & Name Files") { onSplitAndName(nameStyle) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 540)
    }
}
