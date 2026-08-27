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

    final class Coordinator { var handedFocus = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Reassigning the same item makes it flicker and reload, so only set it on a change.
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as NSURL
        }
        // Quick Look renders out of process, and the remote view only gets scroll and gesture
        // events once it's first responder — otherwise scrolling does nothing until you click.
        // Once only: re-making it first responder on every update would fight the user.
        guard !context.coordinator.handedFocus else { return }
        context.coordinator.handedFocus = true
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
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

    /// Keys come through a local event monitor rather than SwiftUI's onKeyPress, because the
    /// Quick Look view has to own first responder for scrolling to work. A monitor sees the
    /// event before the responder chain does, so both can coexist — the same approach the tab
    /// already uses for ⌫.
    @State private var keyMonitor: Any?

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
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123, 126: step(-1); return nil        // ← and ↑
            case 124, 125: step(1);  return nil        // → and ↓
            case 49, 53:   onClose(); return nil       // Space closes as well as opens, and Escape
            default:       return event                // everything else reaches Quick Look
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func step(_ delta: Int) {
        index = min(max(0, index + delta), max(0, files.count - 1))
    }
}
