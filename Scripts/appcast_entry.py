#!/usr/bin/env python3
"""Appcast entries for a ScoreSort release (#11).

Turns RELEASE_NOTES_NEXT.md into the HTML release notes Sparkle shows, builds the new
<item> for docs/appcast.xml, and inserts it as the newest item — moving the
<link>/<sparkle:informationalUpdate> block (for the stranded 1.5/1.5.1 installs, see
CodeRef/releasing.md) onto it, so it's always on the newest item and never duplicated.

Used by Scripts/release.sh; tested by Scripts/test_appcast_entry.py. Standard library only.

    python3 Scripts/appcast_entry.py item --version 1.12.0 --build 17 --summary "..." \\
        --url https://.../ScoreSort.dmg --signature SIG --length 123 [--write]
    python3 Scripts/appcast_entry.py reset-notes --after 1.12.0 [--write]
    python3 Scripts/appcast_entry.py github-notes --summary "..."
    python3 Scripts/appcast_entry.py newest-build
"""

import argparse
import html
import re
import sys
from datetime import datetime
from email.utils import format_datetime
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent
APPCAST = ROOT / "docs" / "appcast.xml"
NOTES = ROOT / "RELEASE_NOTES_NEXT.md"

DOWNLOAD_PAGE = "https://github.com/benperche/ScoreSort/releases/latest"
INFORMATIONAL_BELOW = 9  # builds 7 and 8 (1.5, 1.5.1) were sandboxed and can't install

# The sections of RELEASE_NOTES_NEXT.md, in order. A reset draft has each one, empty.
SECTIONS = ["✨ General Improvements", "🏷️ Rename Files", "🔗 Combine PDFs",
            "✂️ Split PDF", "🔄 Rotate Pages", "🔖 Stamp", "🐞 Fixed"]

INFORMATIONAL_BLOCK = f"""            <!-- 1.5 and 1.5.1 (builds 7 and 8) were sandboxed and can't launch Sparkle's installer.
                 Below build 9 this item is informational: they're offered a link to the download
                 page instead of an install that fails. Keep this block on the newest item. -->
            <link>{DOWNLOAD_PAGE}</link>
            <sparkle:informationalUpdate>
                <sparkle:belowVersion>{INFORMATIONAL_BELOW}</sparkle:belowVersion>
            </sparkle:informationalUpdate>
"""

# The block as it appears in the file (comment optional, whitespace free), for removal.
_INFORMATIONAL_RE = re.compile(
    r"[ \t]*(?:<!--(?:(?!-->).)*?Keep this block on the newest item\.\s*-->\s*\n)?"
    r"[ \t]*<link>[^<]*</link>\s*\n"
    r"[ \t]*<sparkle:informationalUpdate>.*?</sparkle:informationalUpdate>[ \t]*\n",
    re.S)

# Real items only: skip anything inside comments (the template at the end of the file).
_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)


class ReleaseError(Exception):
    """A problem that stops a release, with a message that says what to fix."""


# ---------------------------------------------------------------------------- notes → HTML

def _inline(text: str) -> str:
    """Markdown emphasis to HTML, everything else escaped: **b**, *i* / _i_, `code`."""
    out = html.escape(text, quote=False)
    out = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", out)
    out = re.sub(r"(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])", r"<i>\1</i>", out)
    out = re.sub(r"`([^`]+)`", r"\1", out)
    return out


def parse_notes(markdown: str) -> list:
    """[(section title, [bullet text…])] in order, sections with no bullets left out.
    A bullet continues over following indented lines."""
    sections, current = [], None
    for raw in markdown.splitlines():
        line = raw.rstrip()
        if line.startswith("## "):
            current = (line[3:].strip(), [])
            sections.append(current)
        elif current is not None and line.startswith("- "):
            current[1].append(line[2:].strip())
        elif current is not None and current[1] and line.startswith(("  ", "\t")) and line.strip():
            current[1][-1] += " " + line.strip()
    return [(title, bullets) for title, bullets in sections if bullets]


def notes_to_html(markdown: str, version: str, summary: str, indent: str = "                ") -> str:
    """The <description> body: a heading, the summary, then each section as a bold line and a list."""
    sections = parse_notes(markdown)
    if not sections:
        raise ReleaseError("RELEASE_NOTES_NEXT.md has no notes: every section is empty.")
    lines = [f"<h2>ScoreSort {html.escape(version)}</h2>"]
    if summary.strip():
        lines.append(f"<p>{_inline(summary.strip())}</p>")
    for title, bullets in sections:
        lines.append(f"<p><b>{html.escape(title)}</b></p>")
        lines.append("<ul>")
        lines += [f"    <li>{_inline(b)}</li>" for b in bullets]
        lines.append("</ul>")
    return "\n".join(indent + line for line in lines)


# ---------------------------------------------------------------------------- the item

def make_item(version: str, build: int, pub_date: datetime, summary: str, notes_markdown: str,
              url: str, signature: str, length: int, minimum_system: str = "14.0") -> str:
    """The new <item>, indented as the file's items are, with the informational block on it."""
    description = notes_to_html(notes_markdown, version, summary)
    return (
        f"""        <item>
            <title>Version {version}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{minimum_system}</sparkle:minimumSystemVersion>
{INFORMATIONAL_BLOCK}            <pubDate>{format_datetime(pub_date)}</pubDate>
            <description><![CDATA[
{description}
            ]]></description>
            <enclosure
                url="{html.escape(url)}"
                sparkle:edSignature="{signature}"
                length="{length}"
                type="application/octet-stream"/>
        </item>
""")


def builds(appcast: str) -> list:
    """Every published build number, newest first as they appear (comments ignored)."""
    return [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", _COMMENT_RE.sub("", appcast))]


def newest_build(appcast: str) -> int:
    found = builds(appcast)
    if not found:
        raise ReleaseError("No published builds found in docs/appcast.xml.")
    return max(found)


def insert_item(appcast: str, item: str, build: int) -> str:
    """`appcast` with `item` as its newest item, the informational block moved onto it."""
    newest = newest_build(appcast)
    if build <= newest:
        raise ReleaseError(f"Build {build} isn't newer than the newest published build ({newest}). "
                           "Raise CURRENT_PROJECT_VERSION: Sparkle only offers higher builds.")
    first = appcast.find("<item>")
    if first < 0:
        raise ReleaseError("docs/appcast.xml has no <item> to put the new one before.")
    start = appcast.rfind("\n", 0, first) + 1
    end = appcast.find("</item>", first)
    old_newest = appcast[start:end]
    cleaned = _INFORMATIONAL_RE.sub("", old_newest, count=1)
    return appcast[:start] + item + "\n" + cleaned + appcast[end:]


def check_well_formed(appcast: str) -> None:
    try:
        ElementTree.fromstring(appcast.encode("utf-8"))
    except ElementTree.ParseError as error:
        raise ReleaseError(f"The new appcast isn't well-formed XML: {error}") from error
    items = _COMMENT_RE.sub("", appcast).count("<sparkle:informationalUpdate>")
    if items != 1:
        raise ReleaseError(f"The appcast should carry the informational block exactly once, not {items} times.")


# ---------------------------------------------------------------------------- GitHub release notes

def github_notes(markdown: str, summary: str) -> str:
    """The GitHub release's notes, in Markdown: the summary, then each non-empty section."""
    sections = parse_notes(markdown)
    if not sections:
        raise ReleaseError("RELEASE_NOTES_NEXT.md has no notes: every section is empty.")
    parts = [summary.strip()] if summary.strip() else []
    for title, bullets in sections:
        parts.append(f"### {title}\n\n" + "\n".join(f"- {b}" for b in bullets))
    return "\n\n".join(parts) + "\n"


# ---------------------------------------------------------------------------- reset

def reset_notes(after_version: str) -> str:
    """An empty draft for the release after `after_version`."""
    body = "\n\n".join(f"## {s}" for s in SECTIONS)
    return (f"# Release notes — next release (draft)\n\n"
            f"_Draft for the next release after {after_version}. Keep adding to this as more changes land._\n\n"
            f"{body}\n")


# ---------------------------------------------------------------------------- command line

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    item = sub.add_parser("item", help="add the release's item to the appcast")
    item.add_argument("--version", required=True)
    item.add_argument("--build", type=int, required=True)
    item.add_argument("--summary", required=True, help="one or two sentences above the notes")
    item.add_argument("--url", required=True)
    item.add_argument("--signature", required=True)
    item.add_argument("--length", type=int, required=True)
    item.add_argument("--appcast", default=str(APPCAST))
    item.add_argument("--notes", default=str(NOTES))
    item.add_argument("--write", action="store_true", help="write the file (otherwise print it)")

    reset = sub.add_parser("reset-notes", help="an empty RELEASE_NOTES_NEXT.md draft")
    reset.add_argument("--after", required=True)
    reset.add_argument("--notes", default=str(NOTES))
    reset.add_argument("--write", action="store_true")

    gh = sub.add_parser("github-notes", help="the GitHub release's notes, in Markdown")
    gh.add_argument("--summary", required=True)
    gh.add_argument("--notes", default=str(NOTES))

    newest = sub.add_parser("newest-build", help="print the newest published build number")
    newest.add_argument("--appcast", default=str(APPCAST))

    args = parser.parse_args(argv)
    try:
        if args.command == "item":
            appcast = Path(args.appcast).read_text(encoding="utf-8")
            notes = Path(args.notes).read_text(encoding="utf-8")
            entry = make_item(args.version, args.build, datetime.now().astimezone(), args.summary, notes,
                              args.url, args.signature, args.length)
            updated = insert_item(appcast, entry, args.build)
            check_well_formed(updated)
            if args.write:
                Path(args.appcast).write_text(updated, encoding="utf-8")
                print(f"Added Version {args.version} (build {args.build}) to {args.appcast}")
            else:
                sys.stdout.write(updated)
        elif args.command == "reset-notes":
            text = reset_notes(args.after)
            if args.write:
                Path(args.notes).write_text(text, encoding="utf-8")
                print(f"Reset {args.notes}")
            else:
                sys.stdout.write(text)
        elif args.command == "github-notes":
            sys.stdout.write(github_notes(Path(args.notes).read_text(encoding="utf-8"), args.summary))
        elif args.command == "newest-build":
            print(newest_build(Path(args.appcast).read_text(encoding="utf-8")))
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
