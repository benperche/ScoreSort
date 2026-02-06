#!/usr/bin/env python3
"""
Sheet Music PDF Renamer
Automatically adds score order prefixes to wind band/jazz band PDF files
"""

import os
import re
import sys
from pathlib import Path

# Score order mapping with prefixes
SCORE_ORDER = {
    'score': '00',
    'piccolo': '01',
    'flute': '02',
    'oboe': '03',
    'bassoon': '04',
    'clarinet': '05',
    'alto clarinet':'06',
    'bass clarinet': '07',
    'alto sax': '08',
    'tenor sax': '09',
    'bari sax': '10',
    'baritone sax': '10',
    'cornet': '11',
    'trumpet': '12',
    'horn': '13',
    'trombone': '14',
    'euphonium': '15',
    'baritone': '15',
    'tuba': '16',
    'guitar': '17',
    'keyboard': '18',
    'piano': '19',
    'string bass': '20',
    'bass': '20',
    'timpani': '21',
    'mallet percussion':'22',
    'percussion': '23',
    'drums': '23',
}

def get_instrument_prefix(filename):
    """
    Detect instrument from filename and return appropriate prefix.
    Returns None if no instrument is detected.
    """
    filename_lower = filename.lower()

    # Check for each instrument (longer names first to catch "bass clarinet" before "clarinet")
    for instrument in sorted(SCORE_ORDER.keys(), key=len, reverse=True):
        if instrument in filename_lower:
            return SCORE_ORDER[instrument]

    return None

def rename_pdfs(folder_path, dry_run=True):
    """
    Rename PDFs in the specified folder with score order prefixes.

    Args:
        folder_path: Path to folder containing PDFs
        dry_run: If True, only shows what would be renamed without actually renaming
    """
    folder = Path(folder_path)

    if not folder.exists():
        print(f"Error: Folder '{folder_path}' does not exist")
        return

    if not folder.is_dir():
        print(f"Error: '{folder_path}' is not a directory")
        return

    # Get all PDF files
    pdf_files = list(folder.glob('*.pdf'))

    if not pdf_files:
        print(f"No PDF files found in '{folder_path}'")
        return

    print(f"Found {len(pdf_files)} PDF files\n")

    renamed_count = 0
    skipped_count = 0

    for pdf_file in sorted(pdf_files):
        filename = pdf_file.name

        # Skip if already has a numeric prefix
        if re.match(r'^\d{2}[-_\s]', filename):
            print(f"SKIP (already prefixed): {filename}")
            skipped_count += 1
            continue

        # Detect instrument and get prefix
        prefix = get_instrument_prefix(filename)

        if prefix is None:
            print(f"SKIP (no instrument found): {filename}")
            skipped_count += 1
            continue

        # Create new filename with prefix
        new_filename = f"{prefix} - {filename}"
        new_path = folder / new_filename

        # Check if new filename already exists
        if new_path.exists():
            print(f"SKIP (target exists): {filename} -> {new_filename}")
            skipped_count += 1
            continue

        if dry_run:
            print(f"WOULD RENAME: {filename}\n          -> {new_filename}")
        else:
            pdf_file.rename(new_path)
            print(f"RENAMED: {filename}\n      -> {new_filename}")

        renamed_count += 1

    print(f"\n{'DRY RUN ' if dry_run else ''}Summary:")
    print(f"  Would be renamed: {renamed_count}" if dry_run else f"  Renamed: {renamed_count}")
    print(f"  Skipped: {skipped_count}")

def main():
    """Main function to handle command line arguments."""
    if len(sys.argv) < 2:
        print("Usage: python sheet_music_renamer.py <folder_path> [--execute]")
        print("\nBy default, runs in DRY RUN mode (shows what would happen)")
        print("Add --execute flag to actually rename files")
        print("\nExample:")
        print("  python sheet_music_renamer.py ~/Music/Band-Charts")
        print("  python sheet_music_renamer.py ~/Music/Band-Charts --execute")
        sys.exit(1)

    folder_path = sys.argv[1]
    dry_run = '--execute' not in sys.argv

    if dry_run:
        print("=== DRY RUN MODE ===")
        print("No files will be renamed. Add --execute to actually rename files.\n")
    else:
        print("=== EXECUTE MODE ===")
        print("Files WILL be renamed!\n")

    rename_pdfs(folder_path, dry_run=dry_run)

if __name__ == '__main__':
    main()
