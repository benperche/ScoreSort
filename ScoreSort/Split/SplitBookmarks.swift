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

/// Lists each bookmark beside the file it would produce, so it's clear whether the
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

    var body: some View {
        let names = names
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

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(offer.sections.enumerated()), id: \.offset) { index, section in
                        GridRow {
                            Text(pageRange(section))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            if section.title.isEmpty {
                                Text("No bookmark")
                                    .italic()
                                    .foregroundColor(.secondary)
                            } else {
                                Text(section.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(splitOutputFileName(base: names.baseName,
                                                     separator: filenameSeparator,
                                                     suffix: names.suffixes[index],
                                                     fileIndex: index))
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
        .frame(width: 640)
    }
}
