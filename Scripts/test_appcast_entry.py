"""Tests for Scripts/appcast_entry.py (#11). Run: python3 -m unittest discover -s Scripts -p 'test_*.py'"""

import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import appcast_entry as ae  # noqa: E402

REAL_APPCAST = (ae.ROOT / "docs" / "appcast.xml").read_text(encoding="utf-8")

NOTES = """# Release notes — next release (draft)

_Draft for the next release after 1.11.0._

## ✨ General Improvements

- **Open PDFs straight into ScoreSort from Finder.** Right-click a PDF and choose **Open With ▸ ScoreSort**.

## 🏷️ Rename Files

## 🔗 Combine PDFs

- **Faster & safer.** Uses the *new* engine with `code` and a
  second line.

## 🐞 Fixed

- **Presets survive.** Old <file> kept.
"""

WHEN = datetime(2026, 12, 1, 10, 30, tzinfo=timezone(timedelta(hours=11)))


def new_item(build=17, version="1.12.0"):
    return ae.make_item(version, build, WHEN, "A summary with **bold**.", NOTES,
                        f"https://github.com/benperche/ScoreSort/releases/download/v{version}/ScoreSort.dmg",
                        "SIG==", 12345)


class NotesTests(unittest.TestCase):

    def test_sections_and_bullets(self):
        sections = ae.parse_notes(NOTES)
        self.assertEqual([t for t, _ in sections], ["✨ General Improvements", "🔗 Combine PDFs", "🐞 Fixed"])
        self.assertTrue(sections[1][1][0].endswith("a second line."))

    def test_html_matches_the_published_style(self):
        out = ae.notes_to_html(NOTES, "1.12.0", "A summary.")
        self.assertIn("<h2>ScoreSort 1.12.0</h2>", out)
        self.assertIn("<p>A summary.</p>", out)
        self.assertIn("<p><b>✨ General Improvements</b></p>", out)
        self.assertIn("<li><b>Open PDFs straight into ScoreSort from Finder.</b> Right-click a PDF and choose "
                      "<b>Open With ▸ ScoreSort</b>.</li>", out)
        self.assertIn("<b>Faster &amp; safer.</b> Uses the <i>new</i> engine with code and a second line.", out)
        self.assertIn("Old &lt;file&gt; kept.", out)
        self.assertNotIn("Rename Files", out)  # empty sections are left out

    def test_no_notes_is_an_error(self):
        with self.assertRaises(ae.ReleaseError):
            ae.notes_to_html(ae.reset_notes("1.11.0"), "1.12.0", "x")


class AppcastTests(unittest.TestCase):

    def test_newest_build_ignores_the_template(self):
        self.assertEqual(ae.newest_build(REAL_APPCAST), max(ae.builds(REAL_APPCAST)))
        self.assertNotIn("BUILD_NUMBER", str(ae.builds(REAL_APPCAST)))

    def test_insert_puts_the_item_first_and_moves_the_block(self):
        build = ae.newest_build(REAL_APPCAST) + 1
        updated = ae.insert_item(REAL_APPCAST, new_item(build), build)
        ae.check_well_formed(updated)
        self.assertEqual(ae.builds(updated)[0], build)
        stripped = ae._COMMENT_RE.sub("", updated)
        # The block is on the new item only.
        self.assertEqual(stripped.count("<sparkle:informationalUpdate>"), 1)
        first_item = stripped[stripped.find("<item>"):stripped.find("</item>")]
        self.assertIn("<sparkle:belowVersion>9</sparkle:belowVersion>", first_item)
        self.assertIn(f"<link>{ae.DOWNLOAD_PAGE}</link>", first_item)
        second_start = stripped.find("<item>", stripped.find("</item>"))
        second_item = stripped[second_start:stripped.find("</item>", second_start)]
        self.assertNotIn("informationalUpdate", second_item)
        self.assertNotIn("<link>", second_item)

    def test_earlier_items_are_untouched_apart_from_the_block(self):
        build = ae.newest_build(REAL_APPCAST) + 1
        updated = ae.insert_item(REAL_APPCAST, new_item(build), build)
        # Removing the new item and putting the block back gives the original file.
        start = updated.find("        <item>")
        end = updated.find("</item>", start) + len("</item>\n\n")
        without_new = updated[:start] + updated[end:]
        self.assertEqual(len(without_new.splitlines()) + 7, len(REAL_APPCAST.splitlines()))
        for line in REAL_APPCAST.splitlines():
            if "informationalUpdate" in line or "belowVersion" in line or line.strip().startswith("<link>https://github.com/benperche/ScoreSort/releases/latest"):
                continue
            if "Keep this block on the newest item" in line or "1.5 and 1.5.1 (builds 7 and 8)" in line or "Below build 9" in line:
                continue
            self.assertIn(line, without_new)

    def test_item_fields(self):
        item = new_item(17)
        for expected in ["<title>Version 1.12.0</title>", "<sparkle:version>17</sparkle:version>",
                         "<sparkle:shortVersionString>1.12.0</sparkle:shortVersionString>",
                         "<pubDate>Tue, 01 Dec 2026 10:30:00 +1100</pubDate>",
                         'sparkle:edSignature="SIG=="', 'length="12345"',
                         "releases/download/v1.12.0/ScoreSort.dmg", "<p>A summary with <b>bold</b>.</p>"]:
            self.assertIn(expected, item)

    def test_build_must_increase(self):
        newest = ae.newest_build(REAL_APPCAST)
        with self.assertRaises(ae.ReleaseError):
            ae.insert_item(REAL_APPCAST, new_item(newest), newest)

    def test_twice_still_carries_the_block_once(self):
        b1 = ae.newest_build(REAL_APPCAST) + 1
        once = ae.insert_item(REAL_APPCAST, new_item(b1, "1.12.0"), b1)
        twice = ae.insert_item(once, new_item(b1 + 1, "1.13.0"), b1 + 1)
        ae.check_well_formed(twice)
        self.assertEqual(ae.builds(twice)[:2], [b1 + 1, b1])


class GitHubNotesTests(unittest.TestCase):

    def test_markdown_notes(self):
        text = ae.github_notes(NOTES, "Summary.")
        self.assertTrue(text.startswith("Summary.\n\n### ✨ General Improvements"))
        self.assertIn("- **Faster & safer.** Uses the *new* engine with `code` and a second line.", text)
        self.assertNotIn("Rename Files", text)


class ResetTests(unittest.TestCase):

    def test_reset_has_every_section_and_no_notes(self):
        text = ae.reset_notes("1.12.0")
        self.assertIn("after 1.12.0", text)
        for section in ae.SECTIONS:
            self.assertIn(f"## {section}", text)
        self.assertEqual(ae.parse_notes(text), [])

    def test_reset_matches_the_current_draft_headings(self):
        draft = ae.NOTES.read_text(encoding="utf-8")
        headings = [line[3:].strip() for line in draft.splitlines() if line.startswith("## ")]
        self.assertEqual([h for h in headings if h in ae.SECTIONS], [s for s in ae.SECTIONS if s in headings])
        for heading in headings:
            self.assertIn(heading, ae.SECTIONS, f"RELEASE_NOTES_NEXT.md has a section the reset doesn't: {heading}")


if __name__ == "__main__":
    unittest.main()
