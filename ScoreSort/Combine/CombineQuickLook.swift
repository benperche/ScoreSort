//
//  CombineQuickLook.swift
//  ScoreSort
//
//  Space to look at the part under the cursor, the way Space works in Finder.
//
//  Uses QLPreviewView rather than the system QLPreviewPanel: the panel wants control handed to
//  it through the responder chain (acceptsPreviewPanelControl / beginPreviewPanelControl), which
//  is awkward and brittle from SwiftUI, while the view drops straight into the same overlay the
//  rest of the tab already uses. It also renders images as happily as PDFs, which matters —
//  Combine takes JPEGs and TIFFs as parts, and PDFKit would show nothing for those.
//

import SwiftUI
import QuickLookUI

/// Thin wrapper around AppKit's Quick Look view.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Reassigning the same item makes it flicker and reload, so only set it on a change.
        guard (nsView.previewItem as? URL) != url else { return }
        nsView.previewItem = url as NSURL
    }

    /// Quick Look holds onto resources until told otherwise.
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

struct CombineQuickLookView: View {
    let files: [CombineFile]
    @Binding var index: Int
    let onClose: () -> Void

    @FocusState private var focused: Bool

    private var current: CombineFile? {
        files.indices.contains(index) ? files[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let file = current {
                HStack {
                    Text(file.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(index + 1) of \(files.count)")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()

                QuickLookPreview(url: file.url)
                    .id(file.url)

                Divider()

                HStack(spacing: 12) {
                    Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                        .disabled(index == 0)
                    Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                        .disabled(index >= files.count - 1)
                    Spacer()
                    Text("Space to close")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Done", action: onClose)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
        .frame(width: 900, height: 760)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 30)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Without focus the file list behind keeps the arrow keys, so stepping here would also be
        // moving a selection nobody can see.
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            switch press.key {
            case .leftArrow, .upArrow:    step(-1); return .handled
            case .rightArrow, .downArrow: step(1);  return .handled
            // Space closes as well as opens, as it does in Finder.
            case KeyEquivalent(" "):      onClose(); return .handled
            default:                      return .ignored
            }
        }
    }

    private func step(_ delta: Int) {
        index = min(max(0, index + delta), max(0, files.count - 1))
    }
}
