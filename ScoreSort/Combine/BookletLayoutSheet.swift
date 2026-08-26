//
//  BookletLayoutSheet.swift
//  ScoreSort
//
//  Reviewing where each part's page turns fall, with the music in front of you.
//
//  Publishers design page turns, so whether a part should fold or sit flat is a judgement about
//  the music — is there a rest at the bottom of the page you'd be turning? That can't be worked
//  out from page counts, so this shows the pages themselves next to the choice, rather than
//  sending the user out to Preview and back.
//

import SwiftUI
import PDFKit

struct BookletLayoutReviewView: View {
    let files: [CombineFile]
    let onSet: (UUID, BookletPartLayout) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Booklet Layout")
                    .font(.title2).fontWeight(.semibold)
                Text("""
                     Choose where each part's page turns fall. Look for a rest at the bottom of the \
                     page you'd be turning — that's the one the player has to get through.
                     """)
                    .foregroundColor(.secondary)
            }
            .padding(24)

            Divider()

            if files.isEmpty {
                Spacer()
                Text("No parts to lay out.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            BookletLayoutPartRow(file: file) { onSet(file.id, $0) }
                            Divider()
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 720, height: 620)
    }
}

/// One part: its opening pages, and the two places its turns could fall.
private struct BookletLayoutPartRow: View {
    let file: CombineFile
    let onSet: (BookletPartLayout) -> Void

    /// Only the opening pages are rendered. The decision is about the first turn, and rendering
    /// every page of every part in a band folder would cost far more than it tells anyone.
    @State private var thumbnails: [NSImage] = []
    @State private var loaded = false

    private var pagesToShow: Int { min(file.pageCount, 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(file.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(file.pageCount == 1 ? "1 page" : "\(file.pageCount) pages")
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                    VStack(spacing: 4) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 104, height: 147)
                            .border(Color.secondary.opacity(0.3))
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if !loaded {
                    ProgressView().controlSize(.small).frame(height: 147)
                }

                Picker("", selection: Binding(
                    get: { file.effectiveBookletLayout },
                    set: { onSet($0) }
                )) {
                    ForEach(BookletPartLayout.allCases) { option in
                        Text("\(option.label) — opens to \(option.spreadDescription(pageCount: file.pageCount))")
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.leading, 8)

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .task(id: file.id) { await loadThumbnails() }
    }

    private func loadThumbnails() async {
        guard !loaded, !file.isBlankPage else { return }
        let url = file.url
        let count = pagesToShow
        let images: [NSImage] = await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else { return [] }
            return (0..<min(count, doc.pageCount)).compactMap {
                stampPagePreviewImage(page: doc.page(at: $0), maxDimension: 320)
            }
        }.value
        thumbnails = images
        loaded = true
    }
}
