#!/bin/bash
#
# release.sh — build, notarise and sign a ScoreSort release, and write its appcast entry (#11).
#
#   Scripts/release.sh 1.12.0 --summary "One or two sentences for the top of the notes."
#   Scripts/release.sh 1.12.0 --summary "…" --dry-run      # checks + a sample appcast entry only
#   Scripts/release.sh 1.12.0 --summary "…" --publish      # …and publish: GitHub release, push appcast
#
# Without --publish it stops before anything public: the DMG is built, notarised and signed in
# release/<version>/, docs/appcast.xml has the new entry and RELEASE_NOTES_NEXT.md is reset,
# all uncommitted — and it prints the commands that publish them. Review, then run those (or
# re-run with --publish, which skips the build if the signed DMG is already there).
#
# Before anything else it checks: a clean `main` up to date with GitHub; MARKETING_VERSION is
# <version>; CURRENT_PROJECT_VERSION is higher than every published build (Sparkle only offers
# higher builds); the release notes aren't empty; the tests pass (--skip-tests to skip).
#
# Needs: Xcode with the Developer ID certificate, the notarytool keychain profile
# "ScoreSort-notary", `brew install create-dmg`, Sparkle's sign_update (in the resolved package),
# and `gh` signed in. The EdDSA private key stays in the login Keychain: this script never
# prints, exports or copies it.

set -euo pipefail

TEAM_ID="33H8SWK5BX"
NOTARY_PROFILE="ScoreSort-notary"
REPO="benperche/ScoreSort"

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
# A failed check: fatal in a real run; a dry run lists every one and carries on.
PROBLEMS=()
check_failed() { if [ "${DRY_RUN:-0}" -eq 1 ]; then PROBLEMS+=("$*"); echo "  ✗ $*"; else die "$*"; fi; }
step() { echo; echo "▸ $*"; }

VERSION=""; SUMMARY=""; DRY_RUN=0; PUBLISH=0; SKIP_TESTS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --summary) SUMMARY="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --publish) PUBLISH=1; shift ;;
        --skip-tests) SKIP_TESTS=1; shift ;;
        -h|--help) usage ;;
        -*) die "unknown option $1" ;;
        *) [ -z "$VERSION" ] || die "one version only"; VERSION="$1"; shift ;;
    esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "version should look like 1.12.0, not $VERSION"
[ -n "$SUMMARY" ] || die "--summary is required: one or two sentences for the top of the release notes"
[ $DRY_RUN -eq 0 ] || [ $PUBLISH -eq 0 ] || die "--dry-run and --publish together make no sense"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/release/$VERSION"
PY="python3 -I"

# ---------------------------------------------------------------- preflight
step "Checking"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || check_failed "not on main"

SETTINGS="$(xcodebuild -project ScoreSort.xcodeproj -target ScoreSort -configuration Release -showBuildSettings 2>/dev/null)"
MARKETING="$(echo "$SETTINGS" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')"
BUILD="$(echo "$SETTINGS" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}')"
[ "$MARKETING" = "$VERSION" ] || check_failed "MARKETING_VERSION is $MARKETING, not $VERSION: bump it in the project first"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION isn't a number: $BUILD"

# Resuming: an earlier run (without --publish) already built and signed this version and wrote
# its appcast entry and reset the notes, uncommitted. Those two files may differ; nothing else.
RESUMING=0
if [ $DRY_RUN -eq 0 ] && [ -f "$OUT/signature" ] && [ -f "$OUT/notes.md" ] \
   && grep -q "<sparkle:version>$BUILD</sparkle:version>" docs/appcast.xml; then
    RESUMING=1
fi
DIRTY="$(git status --porcelain --untracked-files=no)"
[ $RESUMING -eq 0 ] || DIRTY="$(echo "$DIRTY" | grep -v -e ' docs/appcast.xml$' -e ' RELEASE_NOTES_NEXT.md$' || true)"
[ -z "$DIRTY" ] || check_failed "uncommitted changes: commit or stash them first: $(echo $DIRTY)"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || check_failed "main isn't the same as GitHub's main: pull or push first"

if [ $RESUMING -eq 1 ]; then
    echo "  ScoreSort $VERSION, build $BUILD: resuming the earlier run in $OUT"
else
    NEWEST="$($PY Scripts/appcast_entry.py newest-build)"
    [ "$BUILD" -gt "$NEWEST" ] || check_failed "CURRENT_PROJECT_VERSION ($BUILD) must be higher than the newest published build ($NEWEST)"
    $PY Scripts/appcast_entry.py github-notes --summary "$SUMMARY" > /dev/null 2>&1 || check_failed "the release notes draft is empty"
    echo "  ScoreSort $VERSION, build $BUILD (newest published: $NEWEST)"
fi

if [ $SKIP_TESTS -eq 0 ]; then
    step "Running the tests"
    TESTS_OK=1
    $PY -m unittest discover -s Scripts -p 'test_*.py' > /dev/null 2>&1 \
        || { TESTS_OK=0; check_failed "the release script's own tests failed: python3 -m unittest discover -s Scripts -p 'test_*.py'"; }
    xcodebuild -project ScoreSort.xcodeproj -scheme ScoreSort -destination platform=macOS \
        CODE_SIGNING_ALLOWED=NO test > "${TMPDIR:-/tmp}/scoresort-release-tests.log" 2>&1 \
        || { TESTS_OK=0; check_failed "the test suite failed: see ${TMPDIR:-/tmp}/scoresort-release-tests.log"; }
    [ $TESTS_OK -eq 0 ] || echo "  passed"
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/ScoreSort.dmg"

# ---------------------------------------------------------------- dry run
if [ $DRY_RUN -eq 1 ]; then
    step "Dry run: a sample appcast entry (nothing built, signed or written)"
    SAMPLE="$(mktemp -d)"
    trap 'rm -rf "$SAMPLE"' EXIT
    cp docs/appcast.xml "$SAMPLE/appcast.xml"
    $PY Scripts/appcast_entry.py item --version "$VERSION" --build "$BUILD" --summary "$SUMMARY" \
        --url "$URL" --signature "DRY-RUN-NOT-SIGNED" --length 0 --appcast "$SAMPLE/appcast.xml" --write > /dev/null \
        || check_failed "couldn't make the appcast entry (see the error above)"
    diff -u docs/appcast.xml "$SAMPLE/appcast.xml" | sed -n '1,60p' || true
    echo
    if [ ${#PROBLEMS[@]} -gt 0 ]; then
        echo "Dry run: ${#PROBLEMS[@]} thing(s) to fix before a real release:"
        for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
        echo "Nothing was built, signed, written or published."
        exit 1
    fi
    echo "Dry run passed. Nothing was built, signed, written or published."
    exit 0
fi

# ---------------------------------------------------------------- tools
command -v create-dmg > /dev/null || die "create-dmg isn't installed: brew install create-dmg"
command -v gh > /dev/null || die "gh isn't installed"
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData/ScoreSort-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -name sign_update -not -path '*old_dsa*' 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || die "Sparkle's sign_update wasn't found: build the project in Xcode once so the package is resolved"

DMG="$OUT/ScoreSort.dmg"
mkdir -p "$OUT"

# ---------------------------------------------------------------- build, notarise, sign
if [ -f "$DMG" ] && [ -f "$OUT/signature" ]; then
    step "Using the signed DMG already in $OUT"
else
    step "Archiving"
    rm -rf "$OUT/ScoreSort.xcarchive" "$OUT/export" "$DMG" "$OUT/signature"
    xcodebuild -project ScoreSort.xcodeproj -scheme ScoreSort -configuration Release \
        -archivePath "$OUT/ScoreSort.xcarchive" archive > "$OUT/archive.log" 2>&1 \
        || die "archiving failed: see $OUT/archive.log"

    step "Exporting with Developer ID"
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$OUT/ScoreSort.xcarchive" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" > "$OUT/export.log" 2>&1 \
        || die "exporting failed: see $OUT/export.log"
    APP="$OUT/export/ScoreSort.app"
    [ -d "$APP" ] || die "the export has no ScoreSort.app: see $OUT/export.log"

    step "Notarising the app (this waits for Apple)"
    ditto -c -k --keepParent "$APP" "$OUT/ScoreSort-app.zip"
    xcrun notarytool submit "$OUT/ScoreSort-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
        | tee "$OUT/notarise-app.log" | grep -q "status: Accepted" || die "the app wasn't notarised: see $OUT/notarise-app.log"
    xcrun stapler staple "$APP" > /dev/null

    step "Building the DMG"
    create-dmg --volname "ScoreSort" --window-size 600 400 --icon "ScoreSort.app" 150 200 \
        --app-drop-link 450 200 "$DMG" "$APP" > "$OUT/dmg.log" 2>&1 || die "create-dmg failed: see $OUT/dmg.log"

    step "Notarising the DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
        | tee "$OUT/notarise-dmg.log" | grep -q "status: Accepted" || die "the DMG wasn't notarised: see $OUT/notarise-dmg.log"
    xcrun stapler staple "$DMG" > /dev/null
    spctl -a -t open --context context:primary-signature "$DMG" 2> /dev/null || die "Gatekeeper doesn't accept the DMG"

    step "Signing the update for Sparkle"
    "$SIGN_UPDATE" "$DMG" > "$OUT/signature"
fi

SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/signature")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' "$OUT/signature")"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || die "couldn't read the signature from $OUT/signature"
[ "$LENGTH" = "$(stat -f%z "$DMG")" ] || die "the signed length doesn't match the DMG: sign it again (delete $OUT/signature)"

# ---------------------------------------------------------------- appcast + notes
if grep -q "<sparkle:version>$BUILD</sparkle:version>" docs/appcast.xml; then
    step "The appcast already has build $BUILD"
else
    step "Writing the appcast entry and resetting the release notes"
    $PY Scripts/appcast_entry.py github-notes --summary "$SUMMARY" > "$OUT/notes.md"
    $PY Scripts/appcast_entry.py item --version "$VERSION" --build "$BUILD" --summary "$SUMMARY" \
        --url "$URL" --signature "$SIGNATURE" --length "$LENGTH" --write
    $PY Scripts/appcast_entry.py reset-notes --after "$VERSION" --write
fi

PUBLISH_COMMANDS=(
    "gh release create v$VERSION \"$DMG\" --repo $REPO --title \"ScoreSort $VERSION\" --notes-file \"$OUT/notes.md\""
    "git add docs/appcast.xml RELEASE_NOTES_NEXT.md"
    "git commit -m \"Release $VERSION: appcast entry; reset the release notes draft\""
    "git push origin main"
)

if [ $PUBLISH -eq 0 ]; then
    echo
    echo "Built, notarised and signed: $DMG"
    echo "docs/appcast.xml and RELEASE_NOTES_NEXT.md are updated but not committed: review them (git diff)."
    echo "Nothing is public yet. To publish, run (the release first, so the download exists before the feed points at it):"
    for c in "${PUBLISH_COMMANDS[@]}"; do echo "  $c"; done
    echo "Or re-run this command with --publish."
    exit 0
fi

step "Publishing"
gh release view "v$VERSION" --repo "$REPO" > /dev/null 2>&1 && die "release v$VERSION already exists on GitHub"
eval "${PUBLISH_COMMANDS[0]}"
git add docs/appcast.xml RELEASE_NOTES_NEXT.md
git commit -q -m "Release $VERSION: appcast entry; reset the release notes draft"
git push -q origin main
echo "Published v$VERSION. The appcast deploys from docs/: gh run list --repo $REPO --workflow pages.yml --limit 1"
