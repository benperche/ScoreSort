# Sheet Music PDF Renamer

A modern GUI application that automatically renames and reorganizes sheet music PDF files by instrument order for band, orchestra, and jazz ensemble arrangements.

## Features

- **Automatic Instrument Detection**: Intelligently recognizes instrument types from filenames
- **Two Ensemble Modes**: Separate optimized instrument ordering for Band/Orchestra and Jazz Ensemble
- **Sequential Numbering**: Automatically assigns numbers (01, 02, 03, etc.) based on instrument priority
- **Customizable Instrument Orders**: Edit and save your preferred instrument ordering for each ensemble type
- **Manual Override**: Assign positions manually for files with undetectable instrument names
- **Compact Numbering**: Optional auto-renumbering to fill gaps after selective renaming
- **Undo Functionality**: Undo the last batch of renames
- **Drag & Drop Support**: Drop folders directly into the application (when tkinterdnd2 is installed)
- **Live Preview**: See exactly how files will be renamed before executing
- **Error Checking**: Verify there are no numbering conflicts or issues

## Installation

### Requirements
- Python 3.7 or higher
- tkinter (usually included with Python)
- Optional: `tkinterdnd2` for drag & drop functionality

### Setup

1. Clone or download this repository
2. Install dependencies:
   ```bash
   pip install tkinterdnd2  # Optional, for drag & drop support
   ```
3. Run the application:
   ```bash
   python sheet_music_renamer_gui.py
   ```

## How to Use

### Basic Workflow

1. **Select a Folder**
   - Click "Browse..." to select a folder containing your PDF files
   - Or drag and drop a folder into the application

2. **Choose Your Ensemble Mode**
   - Select "Band/Orchestra" for traditional band arrangements
   - Select "Jazz Ensemble" for jazz arrangements
   - The mode affects the default instrument ordering

3. **Scan the Folder**
   - Click "Scan Folder" to analyze all PDF files in the selected directory
   - The application will attempt to detect instruments from the filenames
   - A preview table shows the original filenames and proposed new names

4. **Review the Preview**
   - Check the preview table for any errors or unexpected assignments
   - The "Status" column explains how each file was classified:
     - Green checkmark: Instrument detected successfully
     - Yellow warning: Undetected or manual assignment
     - Red X: Conflict or error

5. **Make Adjustments (Optional)**
   - Double-click any file in the preview to manually assign it to a different position
   - Use the "Check for Errors" button to verify there are no numbering conflicts

6. **Execute the Rename**
   - Click "Execute Rename" to apply all changes
   - Files are renamed in place with sequential numbers

7. **Undo if Needed**
   - Click "Undo Rename" to revert the last batch of renames

### Understanding the Preview Table

- **Original Filename**: The current name of the file
- **New Filename**: What the file will be renamed to (shows numbering and order)
- **Status**: 
  - ✓ Detected instrument
  - ⚠ Manual override or uncertain detection
  - ✗ Error (duplicate numbering, etc.)

### Customizing Instrument Orders

1. Go to **File → Preferences** (or use the menu)
2. Two tabs are available:
   - **Band/Orchestra**: For traditional band and orchestra arrangements
   - **Jazz Ensemble**: For jazz ensemble arrangements
3. Edit the list of instruments (one per line)
   - **Order matters**: Instruments higher in the list get lower numbers
   - **Case-insensitive**: "Flute", "FLUTE", and "flute" are all recognized
4. Click "Save" to apply your preferences
5. Use "Reset Current Tab to Default" to restore original instrument ordering

### Compact Numbering

When the "Auto-renumber (compact)" checkbox is enabled:
- The application fills gaps in numbering
- If you have files numbered 01, 02, 05, 07, they become 01, 02, 03, 04
- Useful after manually excluding certain files from renaming

## Instrument Detection

The application uses intelligent pattern matching to detect instruments:

- **Exact phrase matching**: Files like `Flute_Part1.pdf` are recognized
- **Flexible word matching**: `02 - alto saxophone part.pdf` matches "alto saxophone"
- **Part number extraction**: Automatically detects part numbers (1st, 2nd, 3rd, 4th, or 1, 2, 3, 4)
- **Reversible patterns**: "Guitar Chords" and "Chords Guitar" are both recognized

### Examples

| Original Filename | Detected As | New Filename |
|---|---|---|
| `Flute_Part.pdf` | Flute | `03 - flute.pdf` |
| `02 - Alto Sax.pdf` | Alto Saxophone | `07 - alto saxophone.pdf` |
| `Clarinet 1st.pdf` | Clarinet (Part 1) | `05 - clarinet 1st.pdf` |
| `Unknown_Score.pdf` | Not detected | `Unknown_Score.pdf` (unchanged) |

## Default Instrument Orders

### Band/Orchestra Mode

Score, Piccolo, Flute, Oboe, Cor Anglais, Bassoon, Eb Clarinet, Clarinet, Alto Clarinet, Bass Clarinet, Soprano Saxophone, Alto Saxophone, Tenor Saxophone, Baritone Saxophone, Cornet, Trumpet, Horn, Trombone, Bass Trombone, Euphonium, Tuba, Guitar, Keyboard, Violin, Viola, Cello, Double Bass, Timpani, Percussion

### Jazz Mode

Score, Vocals, Solo Alto Sax, Solo Tenor Sax, Solo Bari Sax, Solo Trumpet, Solo Trombone, Alto Saxophone, Tenor Saxophone, Baritone Saxophone, Trumpet, Trombone, Guitar, Guitar Chords, Piano, Bass, Drums, Auxiliary Percussion

## Advanced Features

### Check for Errors

Click "Check for Errors" to verify:
- No duplicate numbering
- All files can be properly detected or assigned
- No conflicts in the proposed renaming
- The Rescan mode shows any issues found

### Manual File Assignment

For files that don't match any instrument pattern:
1. Double-click the file in the preview table
2. A dialog will appear with available positions
3. Select the correct instrument/position
4. Click "Assign" to update the preview

### Saving Your Preferences

Your instrument orders and ensemble mode preference are automatically saved to:
- **macOS**: `~/.sheet_music_renamer_config.json`
- **Linux**: `~/.sheet_music_renamer_config.json`
- **Windows**: `C:\Users\[YourUsername]\.sheet_music_renamer_config.json`

## Tips & Tricks

- **Before renaming**: Always review the preview table carefully
- **Consistent naming**: Files with clear instrument names (e.g., "Flute", "Trumpet 1") are detected most reliably
- **Parts and sections**: The app detects part numbers (1st, 2nd, etc.) and includes them in the new filename
- **Score files**: Add "score" to your instrument order to number conductor/full scores
- **Undo changes**: Use the "Undo Rename" button if you need to restore original filenames

## Troubleshooting

### Some files aren't being detected
- Check the filename for clear instrument names
- Use "Preferences" to verify the instrument is in your current instrument order
- Manually assign positions using double-click

### "Auto-renumber (compact)" isn't working
- Make sure the checkbox is **enabled**
- Scan the folder again after enabling it

### I want to restore the original instrument order
- Go to **File → Preferences**
- Click "Reset Current Tab to Default"

### Changes aren't being saved
- Check that you have write permissions in the application's config directory
- Check the console for error messages

## System Requirements

- **OS**: macOS, Linux, or Windows
- **Python**: 3.7+
- **Disk Space**: Minimal (no files are copied, only renamed)

## License

Open source - feel free to modify and distribute as needed.

## Support

For issues or feature requests, please check the project repository or contact the maintainer.

---

**Happy organizing!** 🎵
