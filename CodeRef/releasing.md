# Releasing and Sparkle updates

ScoreSort ships by **direct distribution**: a Developer ID–signed, notarised and stapled `ScoreSort.dmg` attached to a GitHub Release, with **Sparkle 2** auto-updates. Not the App Store or TestFlight, and there are no plans for either — so the AI access (which reads files wherever the user keeps them) needn't survive sandboxing.

The step-by-step commands (create-dmg, notarytool, `sign_update`) are in the README's **"Releasing Updates (maintainer)"** section; this file explains how the pieces fit and what not to break. Don't nudge Ben to cut a release: he decides when.

## How Sparkle is wired

- **Package.** `XCRemoteSwiftPackageReference` to `sparkle-project/Sparkle` (up to next major); **the exact version is pinned in `Package.resolved`**, which is tracked (`ScoreSort.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) — CI builds exactly that version (`-onlyUsePackageVersionsFromResolvedFile`) and keys its package cache on it. The `Sparkle` product is linked to the ScoreSort target (`packageProductDependencies` plus a `PBXBuildFile` in the app's Frameworks phase); if a build fails with "no such module Sparkle", that link is what's missing.
- **Code** (main file): `import Sparkle`; `UpdaterViewModel` wraps `SPUStandardUpdaterController` and is a `@StateObject` on `ScoreSortApp` (not injected into the environment); **Check for Updates…** sits in `CommandGroup(after: .appInfo)`, disabled until `canCheckForUpdates`. An App Store or TestFlight build would have to take these out: Sparkle must not ship in Mac App Store builds.
- **No permission prompt on the first launch.** The controller is created with `startingUpdater: false`; `appLaunchCount` (`UserDefaults`, incremented in `init`) must reach 2 before `startUpdaterIfNeeded()` runs, so Sparkle's "check for updates automatically?" prompt appears on the second launch rather than greeting a brand-new user. A manual Check for Updates… starts the updater on demand, so it works on the first launch too.
- **Launch-quit guard.** `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns the static `mainWindowHasAppeared` (set in `ContentView.onAppear`), **not** `true`. At launch Sparkle's dialog can appear before the asynchronously created `WindowGroup` window, and dismissing it would read as "last window closed" and quit the app. Don't revert it to `return true`.
- **Info.plist:** `SUFeedURL = https://benperche.github.io/ScoreSort/appcast.xml`, `SUPublicEDKey = 6Dj8WlfDC/fWZMetFfw7XObJTa9fOsyXGuHDpxjYFYY=`.
- **Signing key:** the EdDSA private key is in the login Keychain, paired with `SUPublicEDKey`. `generate_keys -p` prints the public key, which must equal `SUPublicEDKey`. Sparkle's tools (`sign_update`, `generate_keys`, `generate_appcast`) are in the resolved package artifacts: `~/Library/Developer/Xcode/DerivedData/ScoreSort-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
- The app isn't sandboxed (`ENABLE_APP_SANDBOX = NO`) — required for Sparkle's installer, see below.

## Versions

Sparkle compares each appcast item's `sparkle:version` with the running app's **`CFBundleVersion`** (`CURRENT_PROJECT_VERSION`, the build number). **The build number must strictly increase every release** or no update is offered. `MARKETING_VERSION` is the visible "1.x" (`sparkle:shortVersionString`), and the app reads its own version from `Bundle.main` `CFBundleShortVersionString` (About panel, `ScoreSort version`) — never a hard-coded constant. Both settings live in the Debug and Release configurations of the app target.

## The appcast

`docs/appcast.xml`, newest item first, served by **GitHub Pages**. Downloads are **GitHub Release assets**; keep the asset name `ScoreSort.dmg`, so `https://github.com/benperche/ScoreSort/releases/latest/download/ScoreSort.dmg` (the website's download button) always resolves to the newest release.

Each `<item>` has `title`, `sparkle:version`, `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` (14.0), `pubDate`, the release notes, and an `enclosure` (`url` = the release asset, `sparkle:edSignature` and `length` from `sign_update`, `type`). Recent items carry their notes inline as `<description><![CDATA[…]]>` HTML; the commented-out template at the bottom of the file (and the README) still shows `sparkle:releaseNotesLink` to the release page instead. A wrong `length` or `edSignature` makes Sparkle reject the update; an update that isn't notarised still installs but brings back Gatekeeper's warning each time.

**Deployment.** `.github/workflows/pages.yml` ("Deploy appcast"; Pages source = GitHub Actions since 17 Nov 2026) publishes `docs/` **only when `docs/**` changes on `main`**, or when run by hand (`gh workflow run pages.yml`). One deploy at a time, never cancelled once started; its last step fetches the live appcast (cache-busted, up to six tries) and **fails unless it matches `docs/appcast.xml` byte for byte**. Ordinary pushes start no Pages deployment, so pushes no longer need batching. (Before this, a legacy branch build ran on every push, and bursts of pushes wedged it; older notes that say to batch pushes are about that.) If the deploy fails, read the failed step's log (`gh run list --workflow pages.yml --limit 3`); if the final check fails, the live feed differs from the repo — find out why before pushing again, because that file is what offers updates to every installed copy. The DMG and the Release are unaffected; only the feed is delayed.

## Stranded 1.5 / 1.5.1 installs

1.5 and 1.5.1 (builds 7 and 8) were sandboxed, which stops Sparkle launching its installer ("An error occurred while launching the installer"; the log says *Failed to submit installer job … If your application is sandboxed…*). 1.5.2 (build 9) turned the sandbox off, but the old builds can't install that fix themselves.

So **the newest appcast item always carries** `<link>https://github.com/benperche/ScoreSort/releases/latest</link>` and `<sparkle:informationalUpdate><sparkle:belowVersion>9</sparkle:belowVersion></sparkle:informationalUpdate>` (with a comment saying why): below build 9, Sparkle shows the update as a link to the download page instead of an install that fails. `belowVersion` compares against **`CFBundleVersion`** (the same comparator as `sparkle:version`), not the marketing version — verified by running the edited feed through Sparkle's own `SUAppcast` parser (2.9.1 at the time) for builds 7, 8, 9, 14 and 15. It's honoured only while the feed is **unsigned** (signature status *Skipped*) or validly signed: a feed that fails signature validation drops informational flags and links. Carry the block over to each new item.

## Release checklist

The README has the commands; in outline:

1. Raise **Marketing Version** and **Current Project Version** (build number — must increase) in both configurations.
2. Product ▸ Archive ▸ Distribute App ▸ **Direct Distribution** (Developer ID signing, notarisation, stapling) ▸ Export Notarized App.
3. Build `ScoreSort.dmg` (`create-dmg`), then notarise and `xcrun stapler staple` the DMG.
4. `sign_update ScoreSort.dmg` → `sparkle:edSignature` and `length`.
5. Add the new `<item>` at the top of `docs/appcast.xml`, moving the `<link>` + `informationalUpdate` block onto it.
6. Create the GitHub Release `vX.Y.Z` with `ScoreSort.dmg` attached (the name must match the enclosure URL) and the release notes, taken from `RELEASE_NOTES_NEXT.md`.
7. Check the AI connection with the released build (it's the only build that runs exactly as users' will): install from the DMG, Settings ▸ AI Assistants ▸ Connect to Claude, share a folder with a PDF in it, and ask Claude in a new chat to find the most recent PDF with ScoreSort.
8. Commit and push `docs/appcast.xml`; the Deploy appcast workflow publishes and verifies it (`gh run list --workflow pages.yml --limit 1`). Existing users are then offered the update.
9. Reset `RELEASE_NOTES_NEXT.md` to an empty draft. Every user-visible change adds a line to it in the same commit, written for a musician — so the notes never have to be reconstructed from the log at release time (after 1.8.0, three changes shipped unmentioned that way).
