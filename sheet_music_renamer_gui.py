#!/usr/bin/env python3
"""
Sheet Music PDF Renamer - Modern GUI Version
Automatically adds sequential prefixes to wind band/jazz band PDF files
"""

import os
import re
import json
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
from pathlib import Path

try:
    import tkinterdnd2 as tkdnd
    DND_AVAILABLE = True
except ImportError:
    DND_AVAILABLE = False

# Default instrument order for Band/Orchestra mode
DEFAULT_BAND_ORDER = [
    'score',
    'instrumentation',
    'piccolo',
    'flute',
    'oboe',
    'cor anglais',
    'english horn',
    'bassoon',
    'contrabassoon',
    'eb clarinet',
    'eflat clarinet',
    'clarinet',
    'alto clarinet',
    'bass clarinet',
    'contrabass clarinet',
    'soprano sax',
    'sop sax',
    'sop saxophone',
    'soprano saxophone',
    'alto saxophone',
    'alto sax',
    'sax alto',
    'tenor sax',
    'tenor saxophone',
    'sax tenor',
    'bari sax',
    'baritone sax',
    'bari saxophone',
    'sax bari',
    'saxophone bari',
    'sax baritone',
    'bass sax',
    'bass saxophone',
    'cornet',
    'trumpet',
    'horn',
    'trombone',
    'bass trombone',
    'trombone bass',
    'euphonium',
    'eupho',
    'baritone',
    'tuba',
    'guitar',
    'keyboard',
    'piano',
    'string bass',
    'bass',
    'timpani',
    'mallet',
    'mallet percussion',
    'bells',
    'chimes',
    'glockenspiel',
    'xylophone',
    'vibraphone',
    'marimba',
    'drums',
    'drum set',
    'percussion',
    'violin',
    'viola',
    'cello',
    'double bass',
]

# Default instrument order for Jazz Ensemble mode
DEFAULT_JAZZ_ORDER = [
    'score',
    # Voice/Vocal
    'voice',
    'vocal',
    'vocals',
    # Solo parts - will be further sorted by instrument type
    'solo alto sax',
    'solo alto saxophone',
    'solo eb',
    'solo eflat',
    'solo e flat',
    'solo tenor sax',
    'solo tenor saxophone',
    'solo bari sax',
    'solo baritone sax',
    'solo trumpet',
    'solo trombone',
    'solo',
    'soli',
    # Alto Saxes
    'alto saxophone',
    'alto sax',
    'sax alto',
    # Tenor Saxes
    'tenor sax',
    'tenor saxophone',
    'sax tenor',
    # Bari Sax
    'bari sax',
    'baritone sax',
    'bari saxophone',
    'sax bari',
    'saxophone bari',
    'sax baritone',
    # Trumpets
    'trumpet',
    # Trombones
    'trombone',
    'bass trombone',
    'trombone bass',
    # Guitar
    'guitar',
    # Guitar Chords
    'guitar chords',
    'guitar chord',
    'chords',
    # Piano
    'piano',
    'keyboard',
    # Bass
    'bass',
    'string bass',
    'double bass',
    # Drums
    'drums',
    'drum set',
    # Auxiliary Percussion
    'aux percussion',
    'auxiliary percussion',
    'percussion',
    # Additional instruments
    'vibraphone',
    'vibes',
    'flute',
    'clarinet',
    'horn',
    'baritone horn',
    'baritone',
    'eupho',
    'euphonium',
    'tuba',
]

class PreferencesDialog:
    """Modern dialog for editing instrument orders for both modes."""

    def __init__(self, parent, band_order, jazz_order):
        self.result = None
        self.dialog = tk.Toplevel(parent)
        self.dialog.title("Edit Instrument Order Preferences")
        self.dialog.geometry("800x650")
        self.dialog.transient(parent)
        self.dialog.grab_set()

        # Modern styling
        self.dialog.configure(bg='#f5f5f7')

        # Main frame with padding
        main_frame = ttk.Frame(self.dialog, padding="20")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        self.dialog.columnconfigure(0, weight=1)
        self.dialog.rowconfigure(0, weight=1)
        main_frame.columnconfigure(0, weight=1)
        main_frame.columnconfigure(1, weight=1)
        main_frame.rowconfigure(2, weight=1)

        # Modern header
        header = ttk.Label(main_frame,
            text="Instrument Order Preferences",
            font=('Helvetica', 16, 'bold'))
        header.grid(row=0, column=0, columnspan=2, sticky=tk.W, pady=(0, 5))

        # Instructions with modern styling
        instructions = ttk.Label(main_frame,
            text="Edit the instrument orders below. Numbers will be assigned sequentially (01, 02, 03...).\n" +
                 "Instruments higher in the list get lower numbers. One instrument per line.",
            justify=tk.LEFT,
            foreground='#666')
        instructions.grid(row=1, column=0, columnspan=2, sticky=(tk.W, tk.E), pady=(0, 15))

        # Create notebook for tabs
        self.notebook = ttk.Notebook(main_frame)
        self.notebook.grid(row=2, column=0, columnspan=2, sticky=(tk.W, tk.E, tk.N, tk.S))

        # Band/Orchestra tab
        band_frame = ttk.Frame(self.notebook, padding="10")
        self.notebook.add(band_frame, text="Band/Orchestra")
        band_frame.columnconfigure(0, weight=1)
        band_frame.rowconfigure(0, weight=1)

        self.band_text_editor = scrolledtext.ScrolledText(
            band_frame,
            width=70,
            height=25,
            font=('SF Mono', 11),
            relief=tk.FLAT,
            borderwidth=1,
            highlightthickness=1,
            highlightbackground='#d0d0d0',
            highlightcolor='#007AFF'
        )
        self.band_text_editor.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=1, pady=1)
        self.band_text_editor.insert('1.0', '\n'.join(band_order))

        # Jazz Ensemble tab
        jazz_frame = ttk.Frame(self.notebook, padding="10")
        self.notebook.add(jazz_frame, text="Jazz Ensemble")
        jazz_frame.columnconfigure(0, weight=1)
        jazz_frame.rowconfigure(0, weight=1)

        self.jazz_text_editor = scrolledtext.ScrolledText(
            jazz_frame,
            width=70,
            height=25,
            font=('SF Mono', 11),
            relief=tk.FLAT,
            borderwidth=1,
            highlightthickness=1,
            highlightbackground='#d0d0d0',
            highlightcolor='#007AFF'
        )
        self.jazz_text_editor.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=1, pady=1)
        self.jazz_text_editor.insert('1.0', '\n'.join(jazz_order))

        # Button frame with modern styling
        button_frame = ttk.Frame(main_frame)
        button_frame.grid(row=3, column=0, columnspan=2, sticky=tk.E, pady=(20, 0))

        # Styled buttons
        reset_btn = ttk.Button(button_frame, text="Reset Current Tab to Default",
                  command=self.reset_to_default)
        reset_btn.grid(row=0, column=0, padx=(0, 8))

        cancel_btn = ttk.Button(button_frame, text="Cancel",
                  command=self.cancel)
        cancel_btn.grid(row=0, column=1, padx=(0, 8))

        save_btn = ttk.Button(button_frame, text="Save",
                  command=self.save)
        save_btn.grid(row=0, column=2)

        # Center dialog
        self.dialog.update_idletasks()
        x = parent.winfo_x() + (parent.winfo_width() // 2) - (self.dialog.winfo_width() // 2)
        y = parent.winfo_y() + (parent.winfo_height() // 2) - (self.dialog.winfo_height() // 2)
        self.dialog.geometry(f"+{x}+{y}")

    def reset_to_default(self):
        """Reset current tab to default instrument order."""
        current_tab = self.notebook.index(self.notebook.select())
        tab_name = "Band/Orchestra" if current_tab == 0 else "Jazz Ensemble"

        if messagebox.askyesno("Reset to Default",
                              f"Are you sure you want to reset the {tab_name} order to default?",
                              parent=self.dialog):
            if current_tab == 0:
                self.band_text_editor.delete('1.0', tk.END)
                self.band_text_editor.insert('1.0', '\n'.join(DEFAULT_BAND_ORDER))
            else:
                self.jazz_text_editor.delete('1.0', tk.END)
                self.jazz_text_editor.insert('1.0', '\n'.join(DEFAULT_JAZZ_ORDER))

    def save(self):
        """Save and close."""
        band_text = self.band_text_editor.get('1.0', tk.END)
        band_lines = [line.strip().lower() for line in band_text.strip().split('\n') if line.strip()]

        jazz_text = self.jazz_text_editor.get('1.0', tk.END)
        jazz_lines = [line.strip().lower() for line in jazz_text.strip().split('\n') if line.strip()]

        if not band_lines or not jazz_lines:
            messagebox.showerror("Error", "Both modes must have at least one instrument.", parent=self.dialog)
            return

        self.result = (band_lines, jazz_lines)
        self.dialog.destroy()

    def cancel(self):
        """Cancel and close."""
        self.result = None
        self.dialog.destroy()

def get_instrument_info(filename, instrument_order):
    """
    Detect instrument from filename and return (order_index, instrument_name, part_number).
    Returns None if no instrument is detected.
    Part number is extracted from patterns like '1st', '2nd', '3rd', '4th', or just '1', '2', '3', '4'.
    If no part number is found, defaults to 1 (first part).
    """
    filename_lower = filename.lower()
    filename_normalized = re.sub(r'[-_]+', ' ', filename_lower)
    filename_normalized = re.sub(r'\s+', ' ', filename_normalized)

    # Extract part number from filename - look for patterns like '1st', '2nd', '3rd', '4th' or just numbers
    part_number = 1  # Default to first part

    # Pattern for numbered parts: '1st', '2nd', '3rd', '4th', or standalone '1', '2', '3', '4'
    # Look for word boundaries to avoid matching things like '2024'
    part_match = re.search(r'\b(\d+)(?:st|nd|rd|th)?\b', filename_normalized)
    if part_match:
        # Extract the number, but validate it's actually a part number (1-20 range is reasonable)
        potential_part = int(part_match.group(1))
        if 1 <= potential_part <= 20:
            part_number = potential_part

    # Try exact phrase matching (longer phrases first)
    for idx, instrument in enumerate(instrument_order):
        if instrument in filename_lower:
            return (idx, instrument, part_number)

    # Try flexible word matching for multi-word instruments
    # Special handling for reversible instruments (where word order doesn't matter)
    reversible_patterns = {
        'eflat clarinet': ['eflat', 'clarinet'],
        'eb clarinet': ['eb', 'clarinet'],
        'bass clarinet': ['bass', 'clarinet'],
        'alto clarinet': ['alto', 'clarinet'],
        'bass trombone': ['bass', 'trombone'],
        'guitar chords': ['guitar', 'chords'],
        'guitar chord': ['guitar', 'chord'],
    }

    for idx, instrument in enumerate(instrument_order):
        words = instrument.split()
        if len(words) > 1:
            # Check if this is a reversible instrument pattern
            if instrument in reversible_patterns:
                pattern_parts = [r'\b' + re.escape(word) + r'\b' for word in reversible_patterns[instrument]]
                if all(re.search(pattern, filename_normalized) for pattern in pattern_parts):
                    return (idx, instrument, part_number)
            else:
                # For non-reversible instruments, require the exact order
                pattern_parts = [r'\b' + re.escape(word) + r'\b' for word in words]
                if all(re.search(pattern, filename_normalized) for pattern in pattern_parts):
                    return (idx, instrument, part_number)

    return None

class SheetMusicRenamerGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Sheet Music PDF Renamer")
        self.root.geometry("1100x700")

        # Modern color scheme
        self.colors = {
            'bg': '#f5f5f7',
            'card': '#ffffff',
            'primary': '#007AFF',
            'success': '#34C759',
            'warning': '#FF9500',
            'danger': '#FF3B30',
            'text': '#1c1c1e',
            'secondary': '#8e8e93'
        }

        self.root.configure(bg=self.colors['bg'])

        # Load or initialize instrument orders
        self.config_file = Path.home() / '.sheet_music_renamer_config.json'
        self.load_config()

        # State
        self.folder_path = None
        self.rename_operations = []
        self.undo_operations = []  # Track last rename for undo
        self.manual_overrides = {}
        self.sort_column = None
        self.sort_reverse = False
        self.rescan_mode = False

        self.create_widgets()
        self.create_menu()

    def load_config(self):
        """Load saved configuration or use defaults."""
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    config = json.load(f)
                    self.band_order = config.get('band_order', DEFAULT_BAND_ORDER)
                    self.jazz_order = config.get('jazz_order', DEFAULT_JAZZ_ORDER)
                    self.is_jazz_mode = config.get('is_jazz_mode', False)
            except Exception:
                self.band_order = DEFAULT_BAND_ORDER
                self.jazz_order = DEFAULT_JAZZ_ORDER
                self.is_jazz_mode = False
        else:
            self.band_order = DEFAULT_BAND_ORDER
            self.jazz_order = DEFAULT_JAZZ_ORDER
            self.is_jazz_mode = False

        # Set current order based on mode
        self.update_instrument_order()

    def save_config(self):
        """Save current configuration."""
        try:
            config = {
                'band_order': self.band_order,
                'jazz_order': self.jazz_order,
                'is_jazz_mode': self.is_jazz_mode
            }
            with open(self.config_file, 'w') as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            print(f"Could not save config: {e}")

    def update_instrument_order(self):
        """Update the current instrument order based on mode."""
        self.instrument_order = self.jazz_order if self.is_jazz_mode else self.band_order

    def on_mode_change(self):
        """Handle mode change from radio buttons."""
        new_mode = self.mode_var.get()
        self.is_jazz_mode = (new_mode == "jazz")
        self.update_instrument_order()
        self.save_config()

        # Clear manual overrides and rescan if folder is selected
        self.manual_overrides = {}
        if self.folder_path:
            self.scan_folder()

    def on_compact_toggle(self):
        """Handle compact numbering toggle."""
        if self.folder_path:
            self.scan_folder()

    def create_menu(self):
        """Create menu bar."""
        menubar = tk.Menu(self.root)
        self.root.config(menu=menubar)

        # File menu
        file_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=file_menu)
        file_menu.add_command(label="Select Folder...", command=self.browse_folder)
        file_menu.add_separator()
        file_menu.add_command(label="Preferences...", command=self.open_preferences)
        file_menu.add_separator()
        file_menu.add_command(label="Quit", command=self.root.quit)

        # Help menu
        help_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Help", menu=help_menu)
        help_menu.add_command(label="About", command=self.show_about)

    def create_widgets(self):
        """Create main UI."""
        # Main container with padding
        main_container = ttk.Frame(self.root, padding="20")
        main_container.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        main_container.columnconfigure(0, weight=1)
        main_container.rowconfigure(2, weight=1)

        # Title section
        title_frame = ttk.Frame(main_container)
        title_frame.grid(row=0, column=0, sticky=(tk.W, tk.E), pady=(0, 20))
        title_frame.columnconfigure(1, weight=1)

        title_label = ttk.Label(title_frame,
            text="Sheet Music PDF Renamer",
            font=('Helvetica', 24, 'bold'))
        title_label.grid(row=0, column=0, sticky=tk.W)

        # Mode radio buttons
        mode_frame = ttk.Frame(title_frame)
        mode_frame.grid(row=0, column=1, sticky=tk.E)

        ttk.Label(mode_frame,
            text="Mode:",
            font=('Helvetica', 12)).grid(row=0, column=0, padx=(0, 10))

        self.mode_var = tk.StringVar(value="jazz" if self.is_jazz_mode else "band")

        band_radio = ttk.Radiobutton(mode_frame,
            text="Band/Orchestra",
            variable=self.mode_var,
            value="band",
            command=self.on_mode_change)
        band_radio.grid(row=0, column=1, padx=(0, 10))

        jazz_radio = ttk.Radiobutton(mode_frame,
            text="Jazz Ensemble",
            variable=self.mode_var,
            value="jazz",
            command=self.on_mode_change)
        jazz_radio.grid(row=0, column=2)

        subtitle = ttk.Label(title_frame,
            text="Automatically number PDF files by instrument order",
            foreground=self.colors['secondary'])
        subtitle.grid(row=1, column=0, columnspan=2, sticky=tk.W)

        # Folder selection card
        folder_frame = ttk.LabelFrame(main_container, text="Folder Selection", padding="15")
        folder_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 15))
        folder_frame.columnconfigure(1, weight=1)

        # Enable drag and drop for folder selection
        if DND_AVAILABLE:
            folder_frame.drop_target_register(tkdnd.DND_FILES)
            folder_frame.dnd_bind('<<Drop>>', self.on_folder_drop)

        ttk.Label(folder_frame, text="Folder:").grid(row=0, column=0, sticky=tk.W, padx=(0, 10))

        self.folder_label = ttk.Label(folder_frame,
            text="No folder selected",
            foreground=self.colors['secondary'])
        self.folder_label.grid(row=0, column=1, sticky=(tk.W, tk.E))

        browse_btn = ttk.Button(folder_frame, text="Browse...", command=self.browse_folder)
        browse_btn.grid(row=0, column=2, padx=(10, 0))

        # Action buttons
        action_frame = ttk.Frame(folder_frame)
        action_frame.grid(row=1, column=0, columnspan=3, sticky=(tk.W, tk.E), pady=(15, 0))

        self.scan_btn = ttk.Button(action_frame, text="Scan Folder",
                                   command=self.scan_folder_normal,
                                   state=tk.DISABLED)
        self.scan_btn.grid(row=0, column=0, padx=(0, 8))

        self.rescan_check_btn = ttk.Button(action_frame, text="Check for Errors",
                                          command=self.rescan_check_errors,
                                          state=tk.DISABLED)
        self.rescan_check_btn.grid(row=0, column=1, padx=(0, 8))

        # Preview section
        preview_frame = ttk.LabelFrame(main_container, text="Preview", padding="15")
        preview_frame.grid(row=2, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        preview_frame.columnconfigure(0, weight=1)
        preview_frame.rowconfigure(0, weight=1)

        # Treeview with modern styling
        style = ttk.Style()
        style.configure("Treeview",
                       background="white",
                       foreground=self.colors['text'],
                       rowheight=28,
                       fieldbackground="white")
        style.configure("Treeview.Heading",
                       font=('Helvetica', 11, 'bold'))
        style.map('Treeview', background=[('selected', self.colors['primary'])])

        tree_scroll = ttk.Scrollbar(preview_frame)
        tree_scroll.grid(row=0, column=1, sticky=(tk.N, tk.S))

        self.tree = ttk.Treeview(preview_frame,
                                columns=('Original', 'New', 'Status'),
                                show='headings',
                                yscrollcommand=tree_scroll.set,
                                selectmode='browse')
        tree_scroll.config(command=self.tree.yview)

        self.tree.heading('Original', text='Original Filename', command=lambda: self.sort_by_column('Original'))
        self.tree.heading('New', text='New Filename', command=lambda: self.sort_by_column('New'))
        self.tree.heading('Status', text='Status', command=lambda: self.sort_by_column('Status'))

        self.tree.column('Original', width=350)
        self.tree.column('New', width=350)
        self.tree.column('Status', width=250)

        self.tree.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))

        # Bind double-click for manual assignment
        self.tree.bind('<Double-Button-1>', self.on_tree_double_click)

        # Status and action bar
        bottom_frame = ttk.Frame(main_container)
        bottom_frame.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=(15, 0))
        bottom_frame.columnconfigure(0, weight=1)

        self.status_label = ttk.Label(bottom_frame,
            text="Select a folder to begin",
            foreground=self.colors['secondary'])
        self.status_label.grid(row=0, column=0, sticky=tk.W)

        # Compact numbering checkbox
        self.compact_numbering = tk.BooleanVar(value=True)
        compact_check = ttk.Checkbutton(bottom_frame,
            text="Auto-renumber (compact)",
            variable=self.compact_numbering,
            command=self.on_compact_toggle)
        compact_check.grid(row=0, column=1, padx=(0, 8))

        self.undo_btn = ttk.Button(bottom_frame,
            text="Undo Rename",
            command=self.undo_rename,
            state=tk.DISABLED)
        self.undo_btn.grid(row=0, column=2, padx=(0, 8))

        self.rename_btn = ttk.Button(bottom_frame,
            text="Execute Rename",
            command=self.execute_rename,
            state=tk.DISABLED)
        self.rename_btn.grid(row=0, column=3)

    def open_preferences(self):
        """Open preferences dialog."""
        dialog = PreferencesDialog(self.root, self.band_order, self.jazz_order)
        self.root.wait_window(dialog.dialog)

        if dialog.result:
            self.band_order, self.jazz_order = dialog.result
            self.update_instrument_order()
            self.save_config()

            # Clear manual overrides and rescan if folder is selected
            self.manual_overrides = {}
            if self.folder_path:
                self.scan_folder()

    def show_about(self):
        """Show about dialog."""
        dialog = tk.Toplevel(self.root)
        dialog.title("About")
        dialog.geometry("450x250")
        dialog.transient(self.root)
        dialog.grab_set()
        dialog.configure(bg='#f5f5f7')

        frame = ttk.Frame(dialog, padding="30")
        frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        dialog.columnconfigure(0, weight=1)
        dialog.rowconfigure(0, weight=1)

        ttk.Label(frame,
            text="Sheet Music PDF Renamer",
            font=('Helvetica', 18, 'bold')).pack(pady=(0, 10))

        ttk.Label(frame,
            text="Version 2.0",
            foreground='#666').pack()

        ttk.Label(frame,
            text="\nAutomatically numbers PDF sheet music files\n" +
                 "based on instrument order for band, orchestra,\n" +
                 "and jazz ensemble arrangements.\n\n" +
                 "Features:\n" +
                 "• Band/Orchestra and Jazz Ensemble modes\n" +
                 "• Customizable instrument orders\n" +
                 "• Automatic instrument detection\n" +
                 "• Manual override for undetected files",
            justify=tk.CENTER).pack(pady=10)

        ttk.Button(frame, text="Close", command=dialog.destroy).pack(pady=(15, 0))

        # Center dialog
        dialog.update_idletasks()
        x = self.root.winfo_x() + (self.root.winfo_width() // 2) - (dialog.winfo_width() // 2)
        y = self.root.winfo_y() + (self.root.winfo_height() // 2) - (dialog.winfo_height() // 2)
        dialog.geometry(f"+{x}+{y}")

    def on_tree_double_click(self, event):
        """Handle double-click on tree item for manual assignment."""
        item = self.tree.selection()
        if not item:
            return

        values = self.tree.item(item[0], 'values')
        if len(values) < 3:
            return

        original_filename = values[0]
        status = values[2]

        # Only allow manual assignment for undetected files
        if 'No instrument found' not in status and 'manual' not in status:
            return

        # Create dialog for manual assignment
        dialog = tk.Toplevel(self.root)
        dialog.title("Assign Position")
        dialog.geometry("450x200")
        dialog.transient(self.root)
        dialog.grab_set()
        dialog.configure(bg='#f5f5f7')

        frame = ttk.Frame(dialog, padding="20")
        frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        dialog.columnconfigure(0, weight=1)
        dialog.rowconfigure(0, weight=1)

        ttk.Label(frame, text=f"File: {original_filename[:50]}...",
                 wraplength=350).grid(row=0, column=0, columnspan=2, pady=(0, 15))

        # Explain the numbering based on compact mode
        if self.compact_numbering.get():
            help_text = "Enter the final position (00 = Score, 01, 02, 03...)\nOther files will be renumbered around it."
        else:
            help_text = "Enter the position number (allows gaps in numbering)"

        ttk.Label(frame, text=help_text,
                 foreground='#666',
                 font=('Helvetica', 9)).grid(row=1, column=0, columnspan=2, sticky=tk.W, pady=(0, 10))

        ttk.Label(frame, text="Position number:").grid(row=2, column=0, sticky=tk.W)

        position_var = tk.StringVar()
        position_entry = ttk.Entry(frame, textvariable=position_var, width=10)
        position_entry.grid(row=2, column=1, sticky=tk.W, padx=(10, 0))
        position_entry.focus()

        def save_assignment():
            try:
                num = int(position_var.get())
                if num < 0 or num > 99:
                    messagebox.showerror("Error", "Please enter a number between 0 and 99.", parent=dialog)
                    return
                self.manual_overrides[original_filename] = num
                dialog.destroy()
                self.scan_folder()
            except ValueError:
                messagebox.showerror("Error", "Please enter a valid number.", parent=dialog)

        button_frame = ttk.Frame(frame)
        button_frame.grid(row=3, column=0, columnspan=2, pady=(15, 0))

        ttk.Button(button_frame, text="Cancel", command=dialog.destroy).grid(row=0, column=0, padx=(0, 8))
        ttk.Button(button_frame, text="Assign", command=save_assignment).grid(row=0, column=1)

        # Bind Enter key
        position_entry.bind('<Return>', lambda e: save_assignment())

        # Center dialog
        dialog.update_idletasks()
        x = self.root.winfo_x() + (self.root.winfo_width() // 2) - (dialog.winfo_width() // 2)
        y = self.root.winfo_y() + (self.root.winfo_height() // 2) - (dialog.winfo_height() // 2)
        dialog.geometry(f"+{x}+{y}")

    def sort_by_column(self, col):
        """Sort treeview by column."""
        if self.sort_column == col:
            self.sort_reverse = not self.sort_reverse
        else:
            self.sort_reverse = False
            self.sort_column = col

        items = [(self.tree.set(item, col), item) for item in self.tree.get_children('')]

        if col == 'New':
            def sort_key(item):
                value = item[0]
                if not value:
                    return (999999, value)
                match = re.match(r'^(\d+)', value)
                if match:
                    return (int(match.group(1)), value)
                return (999999, value)
            items.sort(key=sort_key, reverse=self.sort_reverse)
        else:
            items.sort(key=lambda x: x[0].lower(), reverse=self.sort_reverse)

        for index, (val, item) in enumerate(items):
            self.tree.move(item, '', index)

        for column in ['Original', 'New', 'Status']:
            header_text = column.replace('Original', 'Original Filename').replace('New', 'New Filename')
            if column == col:
                arrow = ' ▲' if self.sort_reverse else ' ▼'
                self.tree.heading(column, text=header_text + arrow)
            else:
                self.tree.heading(column, text=header_text)

        # Scroll to top after sorting
        if self.tree.get_children():
            self.tree.see(self.tree.get_children()[0])

    def browse_folder(self):
        """Open folder browser."""
        folder = filedialog.askdirectory(title="Select Sheet Music Folder")
        if folder:
            self.folder_path = Path(folder)
            self.folder_label.config(text=str(self.folder_path), foreground=self.colors['text'])
            self.scan_btn.config(state=tk.NORMAL)
            self.rescan_check_btn.config(state=tk.NORMAL)
            self.manual_overrides = {}  # Clear overrides when new folder selected
            self.undo_operations = []  # Clear undo operations
            self.undo_btn.config(state=tk.DISABLED)
            self.sort_column = None  # Reset sort state for new folder
            self.sort_reverse = False
            self.rescan_mode = False
            self.scan_folder_normal()

    def on_folder_drop(self, event):
        """Handle folder drag and drop."""
        # Parse the dropped data - it can come in various formats
        dropped = event.data

        # Handle curly braces format {path} on macOS
        if dropped.startswith('{') and dropped.endswith('}'):
            dropped = dropped[1:-1]

        # Clean up the path
        folder_path = Path(dropped.strip())

        # Check if it's a directory
        if folder_path.is_dir():
            self.folder_path = folder_path
            self.folder_label.config(text=str(self.folder_path), foreground=self.colors['text'])
            self.scan_btn.config(state=tk.NORMAL)
            self.rescan_check_btn.config(state=tk.NORMAL)
            self.manual_overrides = {}
            self.undo_operations = []  # Clear undo operations
            self.undo_btn.config(state=tk.DISABLED)
            self.sort_column = None  # Reset sort state for new folder
            self.sort_reverse = False
            self.rescan_mode = False
            self.scan_folder_normal()
        else:
            messagebox.showerror("Error", "Please drop a folder, not a file.")

        return event.action

    def scan_folder_normal(self):
        """Normal scan mode - ignore already prefixed files."""
        self.rescan_mode = False
        self.scan_folder()

    def rescan_check_errors(self):
        """Rescan mode - check all files including already prefixed ones."""
        if not self.folder_path:
            return

        response = messagebox.askyesno(
            "Check for Errors",
            "This will check all files (including already numbered ones) and suggest corrections.\n\n" +
            "Files will be renumbered sequentially based on instrument detection.\n\n" +
            "Continue?",
            icon='question'
        )

        if response:
            self.rescan_mode = True
            self.manual_overrides = {}  # Clear manual overrides in rescan mode
            self.scan_folder()

    def scan_folder(self):
        """Scan folder and preview renames with sequential numbering."""
        if not self.folder_path:
            return

        for item in self.tree.get_children():
            self.tree.delete(item)
        self.rename_operations = []

        try:
            pdf_files = [
                entry for entry in self.folder_path.iterdir()
                if entry.is_file() and entry.suffix.lower() == '.pdf'
            ]
        except Exception as e:
            messagebox.showerror("Error", f"Could not read folder: {e}")
            return

        if not pdf_files:
            self.status_label.config(text="No PDF files found in selected folder")
            self.rename_btn.config(state=tk.DISABLED)
            return

        # Group files by detected instrument order
        detected_files = []
        undetected_files = []
        manually_assigned = []

        for pdf_file in sorted(pdf_files):
            filename = pdf_file.name

            if re.match(r'^\d{2}[-_\s]', filename):
                self.tree.insert('', tk.END, values=(filename, '', 'Already prefixed'),
                               tags=('skip',))
                continue

            # Check for manual override first
            if filename in self.manual_overrides:
                manually_assigned.append((self.manual_overrides[filename], pdf_file, filename))
                continue

            instrument_info = get_instrument_info(filename, self.instrument_order)

            if instrument_info is None:
                undetected_files.append((pdf_file, filename))
            else:
                # instrument_info now returns (order_index, instrument_name, part_number)
                detected_files.append((instrument_info[0], instrument_info[2], pdf_file, filename, instrument_info[1]))

        # Sort by instrument order first, then by part number within each instrument
        detected_files.sort(key=lambda x: (x[0], x[1]))

        will_rename = 0
        will_skip = 0

        # Combine detected and manual files for numbering
        all_numbered_files = []

        # Add detected files with their auto-assigned positions
        for idx, (order_idx, part_num, pdf_file, filename, instrument) in enumerate(detected_files):
            if instrument == 'score':
                position = 0
            else:
                # Count non-score files processed so far
                non_score_count = sum(1 for i in range(idx) if detected_files[i][4] != 'score')
                position = non_score_count + 1
            all_numbered_files.append((position, pdf_file, filename, 'detected'))

        # Add manually assigned files
        for assigned_num, pdf_file, filename in manually_assigned:
            all_numbered_files.append((assigned_num, pdf_file, filename, 'manual'))

        # Sort all files by position
        all_numbered_files.sort(key=lambda x: x[0])

        # Now assign final numbers based on compact mode
        if self.compact_numbering.get():
            # Compact mode: Manual positions are final, auto-detected files fill in gaps
            final_assignments = []

            # Separate manual and detected files
            manual_files = [(pos, pf, fn, src) for pos, pf, fn, src in all_numbered_files if src == 'manual']
            detected_only = [(pos, pf, fn, src) for pos, pf, fn, src in all_numbered_files if src == 'detected']

            # Track which positions are taken by manual assignments
            taken_positions = set(pos for pos, _, _, _ in manual_files)

            # Assign detected files to available positions
            next_available = 0
            detected_with_final_positions = []
            for _, pdf_file, filename, source in detected_only:
                while next_available in taken_positions:
                    next_available += 1
                detected_with_final_positions.append((next_available, pdf_file, filename, source))
                next_available += 1

            # Combine and sort by final position
            final_assignments = manual_files + detected_with_final_positions
            final_assignments.sort(key=lambda x: x[0])
        else:
            # Non-compact mode: use the assigned positions as-is (gaps allowed)
            final_assignments = all_numbered_files

        # Process final assignments
        for assigned_num, pdf_file, filename, source in final_assignments:
            prefix = f"{assigned_num:02d}"
            new_filename = f"{prefix} - {filename}"
            new_path = self.folder_path / new_filename

            if new_path.exists():
                self.tree.insert('', tk.END, values=(filename, new_filename, 'Target exists'),
                               tags=('skip',))
                will_skip += 1
                continue

            tag = 'manual' if source == 'manual' else 'rename'
            status = 'Will rename (manual)' if source == 'manual' else 'Will rename'
            self.tree.insert('', tk.END, values=(filename, new_filename, status),
                           tags=(tag,))
            self.rename_operations.append((pdf_file, new_path))
            will_rename += 1

        # Add undetected files
        for pdf_file, filename in undetected_files:
            self.tree.insert('', tk.END, values=(filename, '', 'No instrument found (double-click to assign)'),
                           tags=('skip',))
            will_skip += 1

        # Configure colors
        self.tree.tag_configure('rename', foreground=self.colors['success'])
        self.tree.tag_configure('manual', foreground='#007AFF')  # Blue for manual assignments
        self.tree.tag_configure('skip', foreground=self.colors['secondary'])

        # Only sort if we don't have a current sort state (first scan or new folder)
        # This preserves the user's chosen sort when making manual assignments
        if self.sort_column is None:
            # First time - sort by new filename
            self.sort_by_column('New')
        else:
            # Don't auto-sort - preserve current view order
            # User can click column headers to re-sort if desired
            pass

        self.status_label.config(
            text=f"Found {len(pdf_files)} PDFs: {will_rename} will be renamed, {will_skip} will be skipped"
        )

        if will_rename > 0:
            self.rename_btn.config(state=tk.NORMAL)
        else:
            self.rename_btn.config(state=tk.DISABLED)

        # Scroll to top after scanning
        if self.tree.get_children():
            self.tree.see(self.tree.get_children()[0])

    def execute_rename(self):
        """Execute rename operations."""
        if not self.rename_operations:
            return

        # Clear previous undo operations
        self.undo_operations = []

        success_count = 0
        errors = []

        for old_path, new_path in self.rename_operations:
            try:
                old_path.rename(new_path)
                # Track successful renames for undo (store the reverse operation)
                self.undo_operations.append((new_path, old_path))
                success_count += 1
            except Exception as e:
                errors.append(f"{old_path.name}: {e}")

        if errors:
            error_msg = f"Renamed {success_count} file(s), but {len(errors)} failed:\n\n"
            error_msg += "\n".join(errors[:5])
            if len(errors) > 5:
                error_msg += f"\n... and {len(errors) - 5} more"
            messagebox.showwarning("Partial Success", error_msg)

        # Enable undo button if we have successful renames
        if self.undo_operations:
            self.undo_btn.config(state=tk.NORMAL)

        self.scan_folder()

    def undo_rename(self):
        """Undo the last rename operation."""
        if not self.undo_operations:
            return

        success_count = 0
        errors = []

        for new_path, old_path in self.undo_operations:
            try:
                new_path.rename(old_path)
                success_count += 1
            except Exception as e:
                errors.append(f"{new_path.name}: {e}")

        if errors:
            error_msg = f"Undid {success_count} rename(s), but {len(errors)} failed:\n\n"
            error_msg += "\n".join(errors[:5])
            if len(errors) > 5:
                error_msg += f"\n... and {len(errors) - 5} more"
            messagebox.showwarning("Partial Success", error_msg)
        else:
            messagebox.showinfo("Undo Complete", f"Successfully undid {success_count} rename(s).")

        # Clear undo operations and disable button
        self.undo_operations = []
        self.undo_btn.config(state=tk.DISABLED)

        self.scan_folder()

def main():
    """Run the application."""
    if DND_AVAILABLE:
        root = tkdnd.TkinterDnD.Tk()
    else:
        root = tk.Tk()

    app = SheetMusicRenamerGUI(root)
    root.mainloop()

if __name__ == '__main__':
    main()
