//
//  StampTextEditor.swift
//  ScoreSort
//
//  The stamp's text field, as a real rich-text editor. Bold, italic, font, size and colour
//  apply to the *selection*, so one stamp can mix styles — "Property of **Hornsby North**"
//  — the way any Mac text editor works.
//
//  SwiftUI's TextEditor can't carry attributes on macOS 14, so this wraps an `NSTextView`
//  in `isRichText` mode and stores the result as RTF on the stamp. `StampTextFormatter` is
//  the bridge the SwiftUI controls and the Format menu (⌘B / ⌘I) act through.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Formatter bridge

/// Applies formatting to whatever the stamp editor currently has selected, and publishes the
/// selection's state so the toolbar buttons can light up. Held app-level (on `AppState`) so
/// the Format menu can reach it; a no-op whenever no stamp editor is focused.
final class StampTextFormatter: ObservableObject {
    /// The live editor, set while a stamp text view exists. Weak: the view outlives nothing.
    weak var textView: NSTextView?
    /// Called after any change so the owning view can write the text back to the stamp.
    var onChange: (() -> Void)?

    @Published var isBold = false
    @Published var isItalic = false
    /// False when there's no editor to format — the Format menu items disable themselves.
    @Published var isAvailable = false

    // MARK: Trait toggles

    func toggleBold()   { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    /// Adds the trait if the current state says it's off, removes it if on — so the lit
    /// button always predicts what clicking it will do.
    private func toggleTrait(_ trait: NSFontTraitMask) {
        let turnOn = !hasTrait(trait)
        transformFonts { font in
            let manager = NSFontManager.shared
            return turnOn ? manager.convert(font, toHaveTrait: trait)
                          : manager.convert(font, toNotHaveTrait: trait)
        }
    }

    /// The state the buttons show, and what a toggle acts on.
    ///
    /// With text selected: true only when *every* font in it carries the trait, so a mixed
    /// selection goes bold rather than clearing. With just a caret: the trait of the text
    /// about to be typed there — which is how every Mac text editor behaves, and what makes
    /// the buttons track the cursor as it moves between a bold run and a plain one.
    ///
    /// Note this is deliberately *not* `effectiveRange`: that widens an empty selection to
    /// the whole string (right for applying a change, wrong for reporting state — it made
    /// the buttons describe the document rather than the cursor).
    private func hasTrait(_ trait: NSFontTraitMask) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()

        guard selection.length > 0 else {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 11)
            return NSFontManager.shared.traits(of: font).contains(trait)
        }

        var allHave = true
        storage.enumerateAttribute(.font, in: selection) { value, _, stop in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 11)
            if !NSFontManager.shared.traits(of: font).contains(trait) {
                allHave = false
                stop.pointee = true
            }
        }
        return allHave
    }

    // MARK: Font, size, colour

    func apply(fontFamily: String) {
        transformFonts { font in
            NSFontManager.shared.convert(font, toFamily: fontFamily)
        }
    }

    func apply(fontSize: Double) {
        transformFonts { font in
            NSFontManager.shared.convert(font, toSize: CGFloat(fontSize))
        }
    }

    func apply(colour: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveRange(in: textView)
        if range.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: colour, range: range)
            storage.endEditing()
        }
        var typing = textView.typingAttributes
        typing[.foregroundColor] = colour
        textView.typingAttributes = typing
        finishEditing()
    }

    /// Rewrites the font of every run in the working range through `transform`.
    private func transformFonts(_ transform: (NSFont) -> NSFont) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = effectiveRange(in: textView)

        if range.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 11)
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
            storage.endEditing()
        }

        // Keep typing attributes in step so the change also affects what's typed next.
        var typing = textView.typingAttributes
        let current = (typing[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 11)
        typing[.font] = transform(current)
        textView.typingAttributes = typing

        finishEditing()
    }

    /// The range to format: the selection, or the whole text when nothing is selected —
    /// which is what a formatting control is expected to do.
    private func effectiveRange(in textView: NSTextView) -> NSRange {
        let selection = textView.selectedRange()
        if selection.length > 0 { return selection }
        return NSRange(location: 0, length: textView.textStorage?.length ?? 0)
    }

    private func finishEditing() {
        textView?.didChangeText()
        onChange?()
        refreshState()
    }

    /// Recomputes the button states from the current selection.
    ///
    /// Every assignment is guarded: writing the *same* value to an `@Published` property
    /// still fires `objectWillChange`, which is both a wasted re-render and — when this runs
    /// while SwiftUI is updating views — the "Publishing changes from within view updates"
    /// warning. Callers inside a view update must use `refreshStateSoon()`.
    func refreshState() {
        let available = textView != nil
        if isAvailable != available { isAvailable = available }

        let bold = available && hasTrait(.boldFontMask)
        let italic = available && hasTrait(.italicFontMask)
        if isBold != bold { isBold = bold }
        if isItalic != italic { isItalic = italic }
    }

    /// `refreshState()` deferred to the next run loop — for calls made from `makeNSView` /
    /// `updateNSView`, which run *during* a SwiftUI view update where publishing is illegal.
    func refreshStateSoon() {
        DispatchQueue.main.async { [weak self] in self?.refreshState() }
    }
}

// MARK: - The editor

struct StampTextEditor: NSViewRepresentable {
    @Binding var stamp: Stamp
    @ObservedObject var formatter: StampTextFormatter

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = context.coordinator
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // The stamp is a couple of short lines; wrap rather than scroll sideways.
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        context.coordinator.load(stamp, into: textView)
        formatter.textView = textView
        formatter.refreshStateSoon()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        formatter.textView = textView
        // Reload only when a *different* stamp is being edited. Rewriting the text view from
        // the model on every update would fight the user's typing and lose the selection.
        if context.coordinator.loadedStampId != stamp.id {
            context.coordinator.load(stamp, into: textView)
            formatter.refreshStateSoon()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: StampTextEditor
        private(set) var loadedStampId: UUID?
        /// True while `load` is replacing the contents. Loading happens from `updateNSView`,
        /// i.e. *during* a SwiftUI view update — if a change notification slipped through and
        /// wrote back to the stamp there, it would publish mid-update ("Publishing changes
        /// from within view updates"). Nothing the loader does should count as an edit.
        private var isLoading = false

        init(_ parent: StampTextEditor) {
            self.parent = parent
        }

        /// Puts the stamp's text into the view: its rich text if it has any, otherwise the
        /// plain text in the stamp's base attributes.
        func load(_ stamp: Stamp, into textView: NSTextView) {
            isLoading = true
            defer { isLoading = false }

            loadedStampId = stamp.id
            let content = stampRichText(stamp)
                ?? NSAttributedString(string: stamp.text, attributes: stampBaseAttributes(stamp))
            textView.textStorage?.setAttributedString(content)
            textView.typingAttributes = stampBaseAttributes(stamp)
            // A fresh load isn't an edit, so don't write back — that would stamp RTF onto a
            // stamp the user hasn't touched.
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? NSTextView else { return }
            write(from: textView)
        }

        /// Deferred, always. Replacing the contents in `load()` resets the selection, so this
        /// fires from inside `updateNSView` — i.e. during a SwiftUI view update, where
        /// publishing `isBold`/`isItalic` is illegal. (That was two warnings per stamp
        /// switch: one per property that actually changed.) A run loop's delay in the
        /// button state is imperceptible.
        func textViewDidChangeSelection(_ notification: Notification) {
            parent.formatter.refreshStateSoon()
        }

        /// Mirrors the view's contents onto the stamp: plain text for labels and drawability,
        /// RTF as the source of truth for drawing.
        func write(from textView: NSTextView) {
            let attributed = textView.attributedString()
            parent.stamp.text = attributed.string
            parent.stamp.richTextData = attributed.length > 0 ? stampRTFData(from: attributed) : nil
        }
    }
}
