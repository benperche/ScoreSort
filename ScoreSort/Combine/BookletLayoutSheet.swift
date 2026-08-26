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
    let onApplyToAll: (BookletPartLayout, UUID?) -> (applied: Int, kept: Int)
    let onClose: () -> Void

    /// One part at a time, like Step 1 of the Split tab — every part at once left the pages far
    /// too small to see a rest at the foot of a page, which is the whole decision.
    @State private var index = 0
    /// Rendered pages per file. Held here rather than in the row so stepping back and forth
    /// doesn't re-render anything, and so the next part can be fetched while this one is read.
    @State private var cache: [UUID: [NSImage]] = [:]
    @FocusState private var focused: Bool
    /// What the last Apply did, shown briefly so the button doesn't feel inert.
    @State private var applyNotice: String?
    @State private var noticeToken = 0

    private var current: CombineFile? {
        files.indices.contains(index) ? files[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let file = current {
                BookletLayoutPartView(file: file,
                                      pages: cache[file.id],
                                      onSet: { onSet(file.id, $0) })
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
        .animation(.easeInOut(duration: 0.15), value: applyNotice)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 30)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Without focus here the file list behind the overlay keeps handling the arrow keys,
        // which silently moves the selection you can't even see.
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            switch press.key {
            case .leftArrow:  step(-1); return .handled
            case .rightArrow: step(1);  return .handled
            default:          return .ignored
            }
        }
        // Fetch what's on screen first, then the neighbours, so stepping on lands on something
        // already rendered rather than a spinner.
        .task(id: index) {
            for offset in [0, 1, -1, 2] {
                let i = index + offset
                guard files.indices.contains(i) else { continue }
                await load(files[i])
            }
        }
    }

    private func applyToAll(_ file: CombineFile) {
        let result = onApplyToAll(file.effectiveBookletLayout, file.id)
        let parts = result.applied == 1 ? "1 part" : "\(result.applied) parts"
        applyNotice = result.kept == 0
            ? "Applied to \(parts)"
            : "Applied to \(parts) · \(result.kept) kept your setting"

        // Clear it again, unless another Apply has happened in the meantime.
        noticeToken += 1
        let token = noticeToken
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if token == noticeToken { applyNotice = nil }
        }
    }

    private func step(_ delta: Int) {
        index = min(max(0, index + delta), max(0, files.count - 1))
    }

    private func load(_ file: CombineFile) async {
        guard cache[file.id] == nil else { return }
        let url = file.url
        let count = file.pageCount
        let images: [NSImage] = await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url) else { return [] }
            return (0..<min(count, doc.pageCount)).compactMap {
                stampPagePreviewImage(page: doc.page(at: $0), maxDimension: 700)
            }
        }.value
        cache[file.id] = images
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Booklet Page Turns")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
                if !files.isEmpty {
                    Text("Part \(index + 1) of \(files.count)")
                        .foregroundColor(.secondary)
                }
            }
            Text("""
                 Choose where this part's page turns fall. Look for a rest at the bottom of the \
                 page you'd be turning — that's the one the player has to get through. Click \
                 between two pages to move the turn there.
                 """)
                .foregroundColor(.secondary)
        }
        .padding(24)
    }

    private func footer(_ file: CombineFile) -> some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(index == 0)
            Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(index >= files.count - 1)

            if let applyNotice {
                Label(applyNotice, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }

            Spacer()

            Button("Apply to All Parts") { applyToAll(file) }
                .help("Give every part this layout, except any you've already set yourself")
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
    let pages: [NSImage]?
    let onSet: (BookletPartLayout) -> Void

    @State private var hoveredBoundary: Int?

    private var layout: BookletPartLayout { file.effectiveBookletLayout }
    /// With two layouts, moving any turn is the same as switching to the other one.
    private var alternative: BookletPartLayout { layout == .folded ? .flat : .folded }

    /// Already trimmed to pages that actually exist — see `bookletSpreads`.
    private var spreads: [[Int]] {
        bookletSpreads(pageCount: file.pageCount, layout: layout)
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

            if let pages {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(spreads.enumerated()), id: \.offset) { position, spread in
                            spreadView(spread, pages: pages)
                            if position < spreads.count - 1 {
                                boundary(id: position, isTurn: true)
                            }
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
    }

    /// Pages that face each other, boxed together so it's obvious they're seen at once. The gap
    /// *between* them is a boundary too — clicking it puts the turn there instead.
    private func spreadView(_ spread: [Int], pages: [NSImage]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(spread.enumerated()), id: \.element) { offset, pageNumber in
                if offset > 0 { boundary(id: -pageNumber, isTurn: false) }
                VStack(spacing: 4) {
                    if pages.indices.contains(pageNumber - 1) {
                        Image(nsImage: pages[pageNumber - 1])
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    /// Either an existing turn or the gap inside a spread where one could go. Both are clickable,
    /// so the turn can be dragged around by eye rather than by reading the radio labels.
    private func boundary(id: Int, isTurn: Bool) -> some View {
        let hovered = hoveredBoundary == id
        return Button {
            onSet(alternative)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isTurn ? "arrow.turn.down.right" : "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(isTurn || hovered ? 1 : 0)
                Rectangle()
                    .fill(isTurn ? Color.orange : Color.accentColor.opacity(hovered ? 0.9 : 0))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                Text(isTurn ? "turn" : "turn here")
                    .font(.caption2)
                    .opacity(isTurn || hovered ? 1 : 0)
            }
            .foregroundColor(isTurn ? .orange : .accentColor)
            .frame(width: 44)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredBoundary = $0 ? id : nil }
        .help(isTurn ? "Move the page turn away from here" : "Put the page turn here")
    }
}
