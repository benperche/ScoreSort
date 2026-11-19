//
//  BookletSetupViews.swift
//  ScoreSort
//
//  The output controls and the booklet sheets: CombineSheet, BookletIntroView (shown the
//  first time Booklet is chosen), BookletDuplexSetupView (Set Up Two-Sided Printing…),
//  CombineOutputMenuButton and BookletScaleField. Moved out of CombineTab.swift.
//

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Two-Sided Setup Wizard

/// The Combine tab's modal sheets, as one value so a single `.sheet(item:)` drives both.
enum CombineSheet: Identifiable {
    case bookletIntro
    /// `startAtCheck` when the test sheet is already on its way to the printer — the first-run
    /// modal does the explaining, so replaying the wizard's own intro would just repeat it.
    case duplexSetup(startAtCheck: Bool)

    var id: String {
        switch self {
        case .bookletIntro:                  return "bookletIntro"
        case .duplexSetup(let startAtCheck): return "duplexSetup-\(startAtCheck)"
        }
    }
}

/// Shown once, when someone first switches the output menu to Booklet.
///
/// This is where the two-sided printing explanation lives rather than the welcome tour, because
/// the tour is only ever shown once per install and existing users would never see it — and they
/// are exactly the people meeting booklets for the first time.
struct BookletIntroView: View {
    let printerName: String
    let onPrint: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Printing Booklets")
                .font(.title2).fontWeight(.semibold)

            Text("""
                 Each part becomes its own fold-and-staple booklet, two pages to a side, so a \
                 whole folder goes out in one print job.
                 """)

            Label("""
                  macOS doesn't let an app choose your two-sided setting, so set **Double-sided** \
                  to *On* in the print dialog yourself.
                  """,
                  systemImage: "printer")
                .foregroundColor(.secondary)

            Label("""
                  Printers also differ in which edge they turn the paper on, so this prints one \
                  sheet to find out. You only do it once per printer.
                  """,
                  systemImage: "arrow.2.squarepath")
                .foregroundColor(.secondary)

            Label("""
                  The preview may show a side upside down — that's normal. Judge it by what comes \
                  out of the printer.
                  """,
                  systemImage: "info.circle")
                .foregroundColor(.secondary)

            if !printerName.isEmpty {
                Text("This setting is remembered for **\(printerName)**.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Not Now", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Print Test Sheet\u{2026}", action: onPrint)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Walks the user through the one thing about booklets that can't be settled in software:
/// which way their printer turns the paper. Prints a single generated sheet, then asks the only
/// question that matters — did it come out readable — and sets the flip from the answer, so
/// nobody has to translate "upside down" into "long edge" themselves.
struct BookletDuplexSetupView: View {
    @Binding var flip: BookletDuplexFlip
    let printerName: String
    /// True when the caller has already explained things and sent a sheet to the printer.
    var startAtCheck: Bool = false
    let onPrint: () -> Void
    let onClose: () -> Void

    private enum Step { case intro, check, switched }
    @State private var step: Step = .intro

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Two-Sided Printing")
                .font(.title2).fontWeight(.semibold)

            switch step {
            case .intro:    intro
            case .check:    check
            case .switched: switched
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { if startAtCheck { step = .check } }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
                 Printers differ in which edge they turn the paper on, and macOS doesn't let an \
                 app choose it. This prints one sheet so you can find out — you only need to do \
                 it once per printer.
                 """)
            Label("In the print dialog, make sure Double-sided is set to On.",
                  systemImage: "exclamationmark.circle")
                .foregroundColor(.secondary)
            previewNote
            printerLine

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Print Test Sheet\u{2026}") {
                    step = .check
                    // One runloop turn later: presenting the print sheet from inside the
                    // button's own update pass makes AppKit complain about laying out a view
                    // that's already being laid out.
                    DispatchQueue.main.async { onPrint() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var check: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fold the printed sheet in half.")
                .fontWeight(.medium)
            Text("Do the four pages read **1, 2, 3, 4**, all the right way up?")

            previewNote

            HStack {
                Button("Print Again") { DispatchQueue.main.async { onPrint() } }
                Spacer()
                Button("They\u{2019}re upside down") {
                    flip = (flip == .longEdge) ? .shortEdge : .longEdge
                    step = .switched
                }
                Button("Yes \u{2014} all correct") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var switched: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Switched to \u{201C}\(flip.label)\u{201D}.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("""
                 Print another test sheet to confirm. If it's still wrong, the problem is more \
                 likely that Double-sided wasn't set to On in the print dialog.
                 """)
            printerLine

            HStack {
                Spacer()
                Button("Print Test Sheet\u{2026}") {
                    step = .check
                    DispatchQueue.main.async { onPrint() }
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// The dialog's preview shows the second side upside down, because that's exactly what has
    /// to be sent for it to come out right. Saying so up front stops it reading as a fault and
    /// stops anyone "correcting" it before the paper has had its say.
    private var previewNote: some View {
        Label("""
              The preview may show a side upside down — that's normal. Judge it by what comes \
              out of the printer.
              """,
              systemImage: "info.circle")
            .foregroundColor(.secondary)
    }

    /// Named because the setting is remembered per printer — worth showing which one is about
    /// to be calibrated, especially for someone who prints at more than one site.
    @ViewBuilder private var printerLine: some View {
        if !printerName.isEmpty {
            Text("This setting is remembered for **\(printerName)**.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Output Menu Button

/// The single pull-down holding everything about the *shape* of the output, so the bottom
/// bar's three buttons stay purely about where it goes. Modelled on `StampMenuButton`:
/// inline pickers, so every checkmark in the menu means "this is the one in use".
struct CombineOutputMenuButton: View {
    @Binding var layout: CombineLayout
    @Binding var sheetSize: BookletSheetSize
    @Binding var duplexFlip: BookletDuplexFlip
    @Binding var addBlankPages: Bool
    @Binding var singleSided: Bool
    /// True when no part needs the back of its sheet — see `CombineView.canGoSingleSided`.
    let canGoSingleSided: Bool
    let onSetUpTwoSided: () -> Void
    let onReviewLayout: () -> Void
    let hasFiles: Bool

    var body: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                ForEach(CombineLayout.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Sheet size", selection: $sheetSize) {
                ForEach(BookletSheetSize.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(layout != .booklet)      // nothing to lay out two-up on single pages

            Divider()

            Picker("Two-sided flip", selection: $duplexFlip) {
                ForEach(BookletDuplexFlip.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(layout != .booklet)

            Toggle("Single-sided \u{2014} leave out the blank backs", isOn: $singleSided)
                .disabled(layout != .booklet || !canGoSingleSided)
                .help(canGoSingleSided
                      ? "Every part fits on one side of a sheet, so the blank backs can be left out."
                      : "Some parts need both sides of a sheet, so the backs can\u{2019}t be left out.")

            Toggle("Blank page after odd-length parts", isOn: $addBlankPages)
                .disabled(layout == .booklet)  // booklets pad to a whole folded sheet anyway

            Divider()

            // Lives in here rather than on the main screen: it's a one-off setup step, not part
            // of the everyday flow. It needs no files — the test sheet is generated — so a new
            // printer can be calibrated before anything has been assembled.
            Button("Page Turns\u{2026}", action: onReviewLayout)
                .disabled(layout != .booklet || !hasFiles)

            Button("Set Up Two-Sided Printing\u{2026}", action: onSetUpTwoSided)
                .disabled(layout != .booklet)
        } label: {
            Label(title, systemImage: layout == .booklet ? "book.closed" : "doc.on.doc")
                .lineLimit(1)
        }
        // Sized to its own label so the row around it stays put instead of the title wrapping.
        .fixedSize()
        .help(helpText)
    }

    private var title: String {
        layout == .booklet ? "Booklet \u{00B7} \(sheetSize.shortLabel)" : "Single pages"
    }

    private var helpText: String {
        switch layout {
        case .singlePages:
            return "Output layout: one page per sheet side, in reading order."
        case .booklet:
            return """
            Each part is imposed as its own saddle-stitch booklet, padded to a whole folded \
            sheet. Set Double-sided to On in the print dialog, then fold and staple.

            First time on a new printer, use Set Up Two-Sided Printing\u{2026} — it prints one \
            numbered sheet and sets the flip from what you see. Remembered per printer.

            When printing, the dialog's preview may show every second side upside down. That's \
            normal — it's how the sheet has to be sent so it comes out right once the printer \
            turns the paper over.

            The flip is applied only when ScoreSort prints, so Create PDF and Open in Preview \
            stay the right way up on screen — an ordinary booklet file you can print later, \
            on any printer.
            """
        }
    }
}

/// "Scale [103]% ⌃⌄" — how big each page is drawn within its half of the booklet sheet.
///
/// A typed field rather than a menu of presets: published music doesn't match A4, and the
/// useful corrections are things like 103%, which a coarse preset list can't express.
struct BookletScaleField: View {
    @Binding var percent: Int
    let range: ClosedRange<Int>

    /// The field edits its own text so a half-typed value ("1" on the way to "105") doesn't
    /// get clamped out from under the cursor. It commits on Return or on losing focus.
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("Scale")
                .foregroundColor(.secondary)
            TextField("", text: $text)
                .frame(width: 38)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { text = "\(percent)"; focused = false }
            Text("%")
                .foregroundColor(.secondary)
            Stepper("", value: $percent, in: range)
                .labelsHidden()
        }
        .help("""
              How large each page is drawn within its half of the sheet. 100% fits the half \
              exactly; lower leaves more space around the music, higher fills more of it. \
              Applies to Create PDF, Preview and Print alike.
              """)
        .onAppear { text = "\(percent)" }
        .onChange(of: percent) { _, new in if !focused { text = "\(new)" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        // Anything unparseable snaps back to the last good value rather than resetting to 100.
        guard let typed = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = "\(percent)"
            return
        }
        percent = min(max(typed, range.lowerBound), range.upperBound)
        text = "\(percent)"
    }
}
