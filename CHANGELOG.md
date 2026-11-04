# Changelog

The version number is in `VERSION`. The build number is the number of commits; together with the commit and the build date you can see it in **Screenshot Hub › About Screenshot Hub**.

## 1.6.0

- **Screen recordings**: **Record** (⌘⇧N) dims the screen: drag an area, or click to record the whole screen. A small bar next to the area shows the time and **Stop** (also ⌘⇧N); it stays visible when you click other apps and is kept out of the recording. While recording, the app steps aside like during a screenshot; click it in the Dock to get the window back, where **Record** has become a red **Stop** with the time. Screenshots can still be taken during a recording. Recording happens in the app with ScreenCaptureKit and AVFoundation (H.264 `.mov`), because `screencapture -v` doesn't work from a sandboxed app; it needs the Screen Recording permission (screenshots don't): the first time macOS asks, after that the app explains where to turn it on. Recordings have no sound and land in memory as a card with a play symbol and their length; they are saved as `Screen Recording … .mov`. Saved recordings show up in the folders too, and can be moved and copied to Hot Spaces. They cannot be marked up.
- **Straight into the open folder**: with **Saved**, a Hot Space or a subfolder open, a new screenshot or recording is saved there right away, with Undo (which puts it back in memory). On **In Memory** nothing changes. The status bar says "New screenshots go here".
- **Marking up a saved screenshot overwrites it**, in its own format (a JPEG stays a JPEG), keeping its permissions, creation date and screenshot marker. The file is replaced in one step (`renamex_np` with `RENAME_SWAP`). **Undo** in the notice brings back the original, which is kept in memory until the notice expires.
- Take Screenshot and Record are in the top bar on every tab. In a narrow window the buttons show only their symbol, and then the In Memory and Saved tabs too.
- **Blur**: a new markup tool that makes an area unreadable. Drag a rectangle over it; the area is pixelated in blocks about the height of a line of text and then blurred, so text underneath cannot be read back. Shortcut B.
- **Zoom** in the markup screen: zoom controls at the bottom, ⌘+, ⌘− and ⌘0 (fit), and pinch on the trackpad. 100% is the size the screenshot had on screen.
- **Subfolders in Hot Spaces**: a Hot Space with folders inside shows an arrow to expand them. Every subfolder is a target for dropping, clicking and the context menus, and can be opened as a tab. Right-click a subfolder to add it as a Hot Space of its own.
- **Mark Up button** in the top bar for the selected screenshot, next to double-click, the context menu and ⌘E.
- **New look**: one bar at the top with the tabs and actions, a translucent sidebar, a status bar at the bottom, and quieter cards with an **Unsaved** label and quick actions (mark up, save, discard, show in Finder) when you hover. The markup screen uses the same bars and button groups, with the colors and line thicknesses right in the bar. Clipboard Capture and the screenshot filter are buttons in the top bar.

## 1.5.0

- **Mark Up**: draw on a screenshot with a pen, highlighter, arrow, rectangle or oval, in seven colors and three thicknesses. Open it by double-clicking a screenshot in memory, with **Mark Up…** in the context menu, or with ⌘E.
- Marks on a screenshot in memory can be taken back with **Undo** in the notice. A saved screenshot is never changed; the marked-up version goes into memory as a copy.
- Marking up happens entirely in memory, without temporary files. The resolution of the original (for example 144 dpi on Retina) is kept.

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
