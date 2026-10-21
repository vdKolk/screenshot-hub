# Changelog

The version number is in `VERSION`. The build number is the number of commits; together with the commit and the build date you can see it in **Screenshot Hub › About Screenshot Hub**.

## 1.4.0

- **English**: the app, the code, the documentation and the release notes are now in English. Saved screenshots are named the way English macOS names them: `Screenshot 2026-10-21 at 09.41.22.png`.
- The rolling pre-release is now called **Latest build** (tag `latest-build`).
- The DMG shortcut to the Applications folder is now called "Applications".

## 1.3.0

- **Update notice**: at most once a day the app checks GitHub for a newer version and then shows a notice at the top with a button to the release. **Not Now** hides the notice until the next version.
- **Screenshot Hub › Check for Updates…** checks right away; **Check for Updates Daily** turns the check on or off (on by default). The first time, the app explains that it contacts GitHub.
- The app downloads or installs nothing itself. Only tags like `v1.2.3` count, the response may be at most 2 MB, and the app builds the link to the release itself.
- New entitlement `com.apple.security.network.client`, only for this check. The About window shows whether the check is on.

## 1.2.0

Data protection:

- Saved screenshots and copies get permissions 0600 (owner only); temporary files are owner-only as well.
- Discarded or saved screenshots leave memory as soon as Undo expires (after 6 seconds), instead of being kept until the next action.
- A temporary capture file left behind after a crash is cleaned up on the next launch.

File handling:

- Saving, copying and moving go through a temporary file in the same folder and a rename that never overwrites (`renamex_np` with `RENAME_EXCL`). An interrupted save leaves no partial file behind.
- Dragged files must really be images (ImageIO checks the contents), not just have the right extension.
- Names of dragged files are sanitized: no path or control characters, not hidden, at most 200 bytes.

Error handling:

- Error messages are understandable and contain no file names or paths.
- Notices for a failed screen capture, an unreadable file and a Hot Space whose access was revoked.
- An Undo that fails now says why.

Build:

- `bash build.sh --release` for builds you share: refuses without a Developer ID, without notarization or with uncommitted changes.
- The dirty marker only looks at the files the app is built from, including files not yet in git.
- Swift toolchain and macOS SDK are recorded in Info.plist and shown in the About window.
- `bash build.sh --dmg` creates a DMG in `dist/` with the app and a shortcut to Applications; `--release` creates that DMG as well, and signs, notarizes and staples it.

Releases:

- GitHub Actions builds the app and the DMG on every pull request and every change to main. The **Latest build** pre-release always holds the newest build of main, and every new version in `VERSION` gets its own release with the DMG.

## 1.1.0

Security:

- App Sandbox on: the app can only access folders you choose yourself and files you drag onto the app. No network access.
- Screenshot folder and Hot Spaces are remembered with security-scoped bookmarks.
- Hardened Runtime on.
- Clipboard capture is off by default and skips confidential, transient and auto-generated clipboard content (`org.nspasteboard.*`).
- `build.sh` can sign with a Developer ID and have the app notarized.

Other:

- About window with version, build, commit, build date, macOS version and the status of the sandbox, Hardened Runtime and signature; **Copy Version Information** in the app menu.
- Dutch as the app's base language (English since 1.4.0).

Note: settings now live in the sandbox container. Choose your screenshot folder again and add your Hot Spaces again.

## 1.0.0

First version.

- **In Memory** and **Saved** tabs; a Hot Space opens as its own tab.
- Take screenshots from the app (⌘N) and capture them from the clipboard.
- Save per card, ⌘S, ⌘⇧S or through Hot Spaces (drag, click, ⌘1 to ⌘9).
- Undo after saving, moving, copying and discarding.
- Hot Spaces follow their folder when it is renamed or moved.
- Warning on quit when screenshots are still in memory.
- Builds with only the Command Line Tools, including the app icon.
