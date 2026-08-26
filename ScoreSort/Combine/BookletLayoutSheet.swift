//
//  BookletLayoutSheet.swift
//  ScoreSort
//
//  Reviewing where each part's page turns fall, with the music in front of you.
//
//  Publishers design page turns, so whether a part should fold or sit flat is a judgement about
//  the music — is there a rest at the bottom of the page you'd be turning? That can't be worked
//  out from page counts, so this shows the pages themselves, one part at a time and large enough
//  to actually read, rather than sending the user out to Preview and back.
//

import SwiftUI
import PDFKit

struct BookletLayoutReviewView: View {
    let files: [CombineFile]
    let onSet: (UUID, BookletPartLayout) -> Void
    let onApplyToAll: (BookletPartLayout) -> Void
    let onClose: () -> Void

    /// One part at a time, like Step 1 of the Split tab — the previous grid of every part at once
    /// left the pages far too small to see a rest at the foot of a page.
    @State private var index = 0

    private var current: CombineFile? {
        files.indices.contains(index) ? files[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let file = current {
                BookletLayoutPartView(file: file, onSet: { onSet(file.id, $0) })
                    .id(file.id)
                Divider()
                footer(file)
            } else {
                Spacer()
                Text("No parts to lay out.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(width: 940, height: 700)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 30)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Page Turns")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
                if !files.isEmpty {
                    Text("Part \(index + 1) of \(files.count)")
                        .foregroundColor(.secondary)
                }
            }
            Text("""
                 Choose where this part's page turns fall. Look for a rest at the bottom of the \
                 page you'd be turning — that's the one the player has to get through.
                 """)
                .foregroundColor(.secondary)
        }
        .padding(24)
    }

    private func footer(_ file: CombineFile) -> some View {
        HStack(spacing: 12) {
            Button {
                index = max(0, index - 1)
            } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(index == 0)

            Button {
                index = min(files.count - 1, index + 1)
            } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(index >= files.count - 1)

            Spacer()

            Button("Apply to All Parts") { onApplyToAll(file.effectiveBookletLayout) }
                .help("Give every part the layout shown here")
                .disabled(files.count < 2)

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }
}

// MARK: - One part

private struct BookletLayoutPartView: View {
    let file: CombineFile
    let onSet: (BookletPartLayout) -> Void

    @State private var pages: [NSImage] = []
    @State private var loaded = false

    private var layout: BookletPartLayout { file.effectiveBookletLayout }

    /// The spreads, clipped to pages that actually exist — a blank final side is real paper but
    /// there's nothing to show of it.
    private var visibleSpreads: [[Int]] {
        bookletSpreads(pageCount: file.pageCount, layout: layout)
            .map { $0.filter { $0 <= file.pageCount } }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(file.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(file.pageCount == 1 ? "1 page" : "\(file.pageCount) pages")
                    .foregroundColor(.secondary)
            }

            Picker("", selection: Binding(get: { layout }, set: { onSet($0) })) {
                ForEach(BookletPartLayout.allCases) { option in
                    Text("\(option.label) — opens to \(option.spreadDescription(pageCount: file.pageCount))")
                        .tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if loaded {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(visibleSpreads.enumerated()), id: \.offset) { position, spread in
                            spreadView(spread)
                            // A turn happens between one spread and the next, never after the last.
                            if position < visibleSpreads.count - 1 { turnMarker }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .frame(height: 300)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: file.id) { await load() }
    }

    /// Pages that face each other, boxed together so it's obvious they're seen at once.
    private func spreadView(_ spread: [Int]) -> some View {
        HStack(spacing: 6) {
            ForEach(spread, id: \.self) { pageNumber in
                VStack(spacing: 4) {
                    if let image = pages.indices.contains(pageNumber - 1) ? pages[pageNumber - 1] : nil {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 190, height: 269)
                            .border(Color.secondary.opacity(0.35))
                    }
                    Text("\(pageNumber)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    /// Where the player turns. Deliberately the loudest thing on screen — it's the whole decision.
    private var turnMarker: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 15, weight: .semibold))
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            Text("turn")
                .font(.caption2)
        }
        .foregroundColor(.orange)
        .frame(width: 44)
        .padding(.vertical, 8)
    }

    private func load() async {
        loaded = false
        let url = file.url
        let count = file.pageCount
        let images: [NSImage] = await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else { return [] }
            return (0..<min(count, doc.pageCount)).compactMap {
                stampPagePreviewImage(page: doc.page(at: $0), maxDimension: 700)
            }
        }.value
        pages = images
        loaded = true
    }
}
