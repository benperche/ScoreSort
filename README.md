# Music PDF Manager

A powerful macOS application for managing music PDFs with three essential tools for musicians and music librarians: automatic file renaming based on instrument detection, PDF splitting, and page rotation.

## Features

### 📎 PDF Combiner
Combine multiple PDF files into a single document with flexible copying and page management.

- **Drag-and-drop or browse** to add multiple PDF files
- **Specify copies** for each file (great for printing multiple parts)
- **Reorder files** with Move Up/Down buttons or by dragging
- **Smart blank pages** - automatically add blank sheets after odd-page files for double-sided printing
- **Open in Preview** - opens combined PDF in Preview for quick printing (⌘P)
- **Or save to file** - create a permanent combined PDF document
- **Selection tools** - Select All, Select None, Remove selected files
- **Live preview** - see total file and page counts as you build

### 📁 Sheet Music Renamer
Automatically organize your sheet music files by adding sequential prefixes based on detected instrument names.

- **Automatic instrument detection** from filenames
- **Sequential numbering** (Score = 00, instruments start at 01)
- **Three ensemble presets**: Wind Band, Jazz Band, and Orchestra
- **Customisable instrument order** - edit, reorder, add, or remove instruments
- **Manual override** for files that can't be auto-detected
- **Error checking** - rescan already-numbered files to find and fix mistakes
- **Smart detection** - handles "bass clarinet" vs "clarinet" correctly
- **Drag-and-drop folders** for quick importing
- **Sortable columns** - click headers to sort by original name, new name, or status
- **Live preview** - see all changes before executing

### ✂️ PDF Splitter
Split large PDF files into multiple documents with precision control.

- **Visual page preview** with keyboard navigation (including first/last page jumps)
- **Click-to-toggle split points** directly on the page strip
- **Auto-split by stride** — split every N pages with a single click
- **Two-step workflow** — Step 1: mark split points; Step 2: name each output file
- **Smart naming stage** — zoomed-in crop of each file's first page shows the instrument name corner so you can type it immediately
- **Instrument name autocomplete** — suggestions drawn from all ensemble presets, ordered by what's most likely to come next
- **Arrow-key dropdown navigation** — ↓/↑ moves through suggestions without leaving the keyboard; Return accepts, Escape dismisses
- **Numbered instrument suggestion** — after typing "Flute 1", the next field immediately suggests "Flute 2"
- **Filename validation** — illegal characters (/ : \\) flagged inline before saving
- **Base filename** shared across all output files; per-file suffix appended automatically

### 🔄 Page Rotator
Rotate PDF pages with flexible options for odd/even page handling.

- **Base rotation** for all pages (90°, 180°, 270°)
- **Additional rotation** for odd or even pages only
- **Before/after preview** for each page
- **Perfect for fixing scanned documents** with alternating orientations

## Screenshots

![Rotate Pages](screenshots/rotator.png)
*Rotate pages with before/after preview*

![Split PDFs](screenshots/splitter.png)
*Split PDFs with visual preview and custom naming*

![Rename Files](screenshots/renamer.png)
*Automatic sheet music file renaming with instrument detection*

![Combine PDFs](screenshots/combiner.png)
*Quickly create arbitrary copies of a number of files ready for printing*

## Installation

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later (for building from source)

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/yourusername/music-pdf-manager.git
cd music-pdf-manager
```

2. Open in Xcode:
```bash
open MusicPDFManager.swift
```

3. Build and run:
   - Select your target device (Mac)
   - Press ⌘R or click the Run button

### Installing the App

Option 1: Build and copy to Applications folder
```bash
# After building in Xcode
cp -r ~/Library/Developer/Xcode/DerivedData/MusicPDFManager-*/Build/Products/Release/MusicPDFManager.app /Applications/
```

Option 2: Create an archive for distribution
- In Xcode: Product → Archive
- Follow the distribution wizard

## Usage

### PDF Combiner

1. **Add PDF files**
   - Drag and drop PDFs onto the window
   - Or click "Add Files" to browse
   
2. **Set copy counts** for each file
   - Use + / - buttons to adjust how many copies of each file
   
3. **Reorder files** (optional)
   - Select a file and use "Move Up" / "Move Down" buttons
   - Files will be combined in the order shown
   
4. **Configure double-sided printing** (optional)
   - Check "Add blank sheet to the end of files with an odd number of pages"
   - Ensures each new file starts on the front of a sheet when printing double-sided
   
5. **Output your combined PDF**
   - Click "Open in Preview" to create a temporary PDF and open it in Preview (press ⌘P to print)
   - Or click "Create PDF" to save as a permanent file

### Sheet Music Renamer

1. **Select a folder** containing your PDF sheet music files
   - Click "Choose Folder" or drag a folder onto the window
   
2. **Choose your ensemble type** (Band, Jazz, or Orchestra)
   - Each preset has a different instrument order
   
3. **Review the preview**
   - Green items will be renamed
   - Orange items need correction (rescan mode)
   - Blue items were manually assigned
   - Gray items will be skipped or are already correct
   
4. **Handle undetected files** (optional)
   - Double-click any file to manually assign a number
   - This overrides automatic detection and shifts other files if needed
   
5. **Customise preferences** (optional)
   - Press ⌘, or click the Preferences button
   - Edit instrument order, add new instruments, or reorder existing ones
   
6. **Click "Rename Files"** to execute
   - No confirmation needed - you've already seen the preview!

#### Keyboard Shortcuts (Renamer)
- `⌘,` - Open Preferences
- Click column headers to sort (click again to reverse)

#### Example Workflow

Before:
```
Flute.pdf
Bb Clarinet 1.pdf
Alto Sax.pdf
Trumpet 1.pdf
Score.pdf
```

After:
```
00 - Score.pdf
01 - Flute.pdf
02 - Bb Clarinet 1.pdf
03 - Alto Sax.pdf
04 - Trumpet 1.pdf
```

### PDF Splitter

#### Step 1 — Mark split points

1. **Load a PDF** (drag & drop or click "Choose PDF")
2. **Navigate pages** using the arrow buttons or click the page strip
   - `←` / `→` — previous/next page
   - `⌘←` / `⌘→` — jump to first/last page
3. **Add split points**:
   - Click any page in the strip to toggle a split at that page
   - Press `Space` to toggle a split on the current page
   - Or use **Auto-Split** in the right panel — choose a stride (every N pages) and click "Apply"
4. **Review the output file cards** in the right panel (each shows its page range)
5. **Set base filename** in the right panel
6. **Click "Name Files →"** to proceed to Step 2

#### Step 2 — Name each output file

1. Each file gets its own row with a **zoomed-in crop** of the first page's top-left corner (where instrument names typically appear)
2. **Type a suffix** for each file — e.g. base name "As Winds Dance -" + suffix "Flute" → `As Winds Dance - Flute.pdf`
   - Leave blank for automatic numbering (`basename_1.pdf`, `basename_2.pdf`, …)
3. **Use autocomplete** to fill in instrument names quickly:
   - Suggestions appear as you type, ordered by what's likely to come next in the ensemble
   - If the previous file was "Flute 1", the current field immediately suggests "Flute 2"
   - Press `↓` / `↑` to navigate the dropdown with arrow keys; `Return` to accept; `Escape` to dismiss
   - Or press `Tab` to advance through fields in order
4. **Click "Split and Save"** and choose an output folder

#### Keyboard Shortcuts (Splitter — Step 1)
- `Space` — Toggle split point on current page
- `←` / `→` — Navigate between pages
- `⌘←` / `⌘→` — Jump to first / last page
- **Tip**: Click on the preview area to ensure keyboard shortcuts are active

### Page Rotator

1. **Load a PDF** (drag & drop or click "Choose PDF")
2. **Set base rotation** (applied to all pages)
3. **Set additional rotation** (optional, for odd or even pages)
4. **Preview the result** using page navigation
   - `←` / `→` — previous/next page
   - `⌘←` / `⌘→` — jump to first/last page
5. **Click "Save Rotated PDF"** and choose where to save

## Technical Details

### Built With
- **SwiftUI** - Modern declarative UI framework
- **PDFKit** - Native PDF handling
- **AppKit** - macOS-specific functionality

### Architecture
- **MVVM pattern** with ObservableObject view models
- **Type-safe enums** for rotation angles and operation types
- **Reactive updates** using Combine framework

### Instrument Detection Algorithm
1. Sorts instruments by length (longest first) to match specific names before generic ones
   - Example: "bass clarinet" matches before "clarinet"
2. Performs case-insensitive substring matching
3. Returns the first match found, preserving original position in instrument order

### Default Instrument Orders

The app includes three carefully curated preset orders:

**Wind Band**: Score, Woodwinds (Piccolo → Saxophones), Brass (Cornet → Tuba), Rhythm Section, Percussion, Strings

**Jazz Band**: Score, Vocals, Solos, Saxophones, Brass, Rhythm Section, Auxiliary Percussion

**Orchestra**: Score, Woodwinds, Brass, Timpani/Percussion, Keyboard/Harp, Strings

All orders are fully customisable in Preferences.

## Known Issues & Limitations

- **File naming**: Uses simple substring matching - very similar instrument names may need manual override
- **PDF rotation**: Mutates original page objects - always creates a new file
- **Drag & drop**: Currently only supports single folder/file drops

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development Setup

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Code Style
- Follow Swift API Design Guidelines
- Use meaningful variable names
- Comment complex logic
- Keep functions focused and small

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Originally inspired by a Python-based sheet music renamer
- Built for musicians, by musicians
- Thanks to the macOS developer community for excellent SwiftUI resources

## Support

If you encounter any issues or have suggestions:
- Open an issue on GitHub
- Check existing issues for solutions
- Provide detailed steps to reproduce any bugs

## Author

Your Name - Ben Perche, with all code written by Claude
Additional contributions from Lachlan Hamilton

Project Link: [https://github.com/benperche/music-pdf-manager](https://github.com/benperche/music-pdf-manager)

---

**Made with ♪ for musicians**
