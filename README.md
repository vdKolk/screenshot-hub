# Screenshot Hub

**Shoot first, store later.** A small macOS app where screenshots land in memory first. They only become files when you save them: in your screenshot folder, or straight into the right folder through a Hot Space.

![Screenshot Hub](docs/screenshot.png)

## What it does

- **In Memory**: screenshots that have not been saved yet.
  - Take one with the **Take Screenshot** button (⌘N): select an area, or press Space for a window.
  - Or turn on **Clipboard Capture** (off by default) and take one to the clipboard with ⌃⌘⇧4. Images an app marks as confidential or transient, such as from a password manager, are skipped.
  - Save per card, with ⌘S for the selection, or with **Save All** (⌘⇧S).
- **Saved**: what is in your screenshot folder. You choose that folder yourself, for example the one macOS uses (see ⌘⇧5 › Options).
- **Hot Spaces**: folders in the sidebar you send screenshots to.
  - Drag a screenshot onto a Hot Space, click it with a selection, or press ⌘1 to ⌘9.
  - Screenshots from memory are saved there. Saved screenshots are moved or copied, your choice.
  - Click a Hot Space without a selection, or click its eye, to see what is in it.
  - If you rename or move the folder in Finder, the Hot Space keeps working.
- **Mark Up**: double-click a screenshot in memory, or choose **Mark Up…** (⌘E), and draw on it with a pen, highlighter, arrow, rectangle or oval, in seven colors and three thicknesses.
  - **Done** (↩) puts the marks into the screenshot; Undo in the notice brings back the original. **Cancel** (Esc) leaves it as it was.
  - A saved screenshot is never changed: the marked-up version goes into memory as a copy.
  - Shortcuts in the markup screen: P, H, A, R and O pick the tool; ⌘Z and ⌘⇧Z undo and redo.
- **Undo**: after saving, moving, copying or discarding, the notice at the bottom has an Undo button.
- **Update notice**: once a day the app checks GitHub for a newer version and shows a notice at the top of the window with a button to the release. Check manually via **Screenshot Hub › Check for Updates…**.
- **Safe quit**: if screenshots are still in memory, the app asks whether to save them when you quit.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| ⌘N | New screenshot in memory |
| ⌘S | Save selected screenshots to the screenshot folder |
| ⌘⇧S | Save everything in memory |
| ⌘E | Mark up the selected screenshot |
| ⌘1 to ⌘9 | Send selection to Hot Space 1 to 9 |
| Esc | Clear selection |
| Click, ⌘-click, ⇧-click | Select, add or remove, select a range |
| Double-click | Mark up a screenshot in memory, open a saved screenshot |

## Building

Requires macOS 13 or later and the Command Line Tools. Xcode is not needed.

```sh
xcode-select --install   # once, if you do not have the Command Line Tools yet
bash build.sh
open "Screenshot Hub.app"
```

`build.sh` compiles the app, draws the icon and signs the app with App Sandbox and Hardened Runtime. Then drag `Screenshot Hub.app` to Applications.

`bash build.sh` creates a **local build**: ad hoc signed, for your own Mac only. Gatekeeper rejects it on other Macs.

**Build everything you share with `--release`.** That signs with a Developer ID, has Apple notarize the app, and refuses to build when the source files differ from the commit. That way a shared app always belongs to a known commit.

```sh
# once: store the notarization credentials in the keychain
xcrun notarytool store-credentials screenshothub --apple-id <email> --team-id <TEAMID>

SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=screenshothub bash build.sh --release
```

## Sharing as a DMG

A DMG is a disk image with the app and a shortcut to Applications. Whoever opens it drags the app to Applications and can start it. The app runs on Macs with Apple silicon and macOS 13 or later.

**To share: `bash build.sh --release`.** With it, `build.sh` signs the app and the DMG with your Developer ID and has Apple notarize both. The result is `dist/ScreenshotHub-<version>.dmg`. Recipients get no warning from macOS. See [Building](#building) for `SIGN_IDENTITY` and `NOTARY_PROFILE`.

**Without a Developer ID: `bash build.sh --dmg`.** That creates the same DMG, but not notarized. macOS then blocks the app on another Mac, saying Apple cannot check it. The recipient can still open it like this:

1. Open the DMG and drag **Screenshot Hub** to **Applications**.
2. Start the app. Click **Done** in the alert.
3. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway** for Screenshot Hub. Confirm with your password.

Only use this for testing with people who know where the app comes from: they turn off a macOS security check for this app. On managed Macs, company policy may block it.

On first use the app asks for the screenshot folder, and for **Take Screenshot** macOS asks for screen recording permission.

## Releases via GitHub Actions

`.github/workflows/release.yml` builds the app and the DMG on a GitHub macOS runner:

- **On a pull request** as a check. The DMG is attached to the run as an artifact for 14 days.
- **On every change to `main`** the **Latest build** pre-release is replaced by the newest build. If the version in `VERSION` has no release yet (tag `v<version>`), the workflow creates it too, with the matching section of `CHANGELOG.md` as notes.

To release a new version: bump `VERSION`, add the changes under a new heading in `CHANGELOG.md`, and merge to `main`.

**Notarizing in the workflow.** Without secrets the workflow creates non-notarized pre-releases with the installation steps in the notes. With these secrets (Settings › Secrets and variables › Actions) it signs and notarizes through `build.sh --release`, and a new version becomes a regular release:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate with key as `.p12`, base64 (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that `.p12` file |
| `NOTARY_API_KEY` | App Store Connect API key: the contents of the `.p8` file |
| `NOTARY_KEY_ID` | Id of that key |
| `NOTARY_ISSUER_ID` | Issuer id of your App Store Connect team |

The secrets are only used on a push to `main`, in a temporary keychain that is deleted after the build. The job that builds the code can only read the repository; only the separate release job may create releases.

**Cost.** GitHub Actions minutes are free for public repositories. On a private repository, macOS runner minutes count ten times as heavily as Linux ones, so a build of a few minutes would cost about 20 to 40 minutes of your allowance.

## Version

The version number is in `VERSION`. `build.sh` adds the build number (number of commits), the commit and the build date. If the build contains uncommitted work, the commit has `-dirty` appended.

You can see everything via **Screenshot Hub › About Screenshot Hub**: version, build, commit, build date, toolchain, macOS version and the status of the sandbox, Hardened Runtime and signature. **Copy Version Information** in the same menu puts that on the clipboard as text, handy for a review or a bug report.

## Security and permissions

- **App Sandbox**: the app can only access folders you choose yourself (the screenshot folder and your Hot Spaces) and files you drag onto the app. That choice is remembered with security-scoped bookmarks. The entitlements are in `ScreenshotHub.entitlements`.
- **Hardened Runtime**: on; the app loads no code from outside its own bundle.
- **Clipboard**: only read when you turn on **Clipboard Capture**. Content marked `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` is never captured.
- **Screen recording**: macOS asks for it the first time you use **Take Screenshot**. With a local signature, macOS may ask again after every new build.
- **Network: only the update check.** At most once a day the app requests this repository's releases from `api.github.com` and compares the highest version with its own. Only that request is sent (with the User-Agent `ScreenshotHub`, no version number or other data); GitHub sees your IP address. The app downloads and installs nothing itself: when a newer version exists, a notice appears with a button to the release page, whose link the app builds itself. The response may be at most 2 MB and only tags like `v1.2.3` count. The network session keeps no cookies and no cache. The entitlement for this is `com.apple.security.network.client`: the sandbox then allows outgoing connections to any server; the restriction to `api.github.com` is in the code. Turn it off via **Screenshot Hub › Check for Updates Daily**; the first time, the app explains this. Any further network features (sharing, uploading) require a new security review.
- **Screenshots as files** get permissions 0600: only you can read them. Saving goes through a temporary file in the same folder and a rename that never overwrites an existing file, so an interrupted save leaves no partial file behind.
- **Screenshots in memory** are written nowhere by the app: not to logs (the app logs nothing), not to a cache on disk and not to Quick Look. They only leave the app when you save, copy or drag them. Discarding removes them from memory once Undo expires (6 seconds). Only **Take Screenshot** briefly uses a temporary file, because `screencapture` cannot write directly into memory. That file lives in the container, is readable only by you and is deleted right after reading; after a crash the next launch cleans it up.
- **Copy Version Information** only puts the version, build, commit, toolchain and security status on the clipboard: no paths, file names or image data.
- **Settings** live in the sandbox container (`~/Library/Containers/local.screenshothub`). Hot Spaces from a version before the sandbox need to be added again.

## Files

| File | Contents |
| --- | --- |
| `ScreenshotHub.swift` | The whole app (SwiftUI) |
| `AppIcon.swift` | Draws the app icon; `build.sh` turns it into an `.icns` |
| `ScreenshotHub.entitlements` | The app's entitlements (App Sandbox) |
| `VERSION` | The version number; see `CHANGELOG.md` for what changed per version |
| `build.sh` | Builds and signs `Screenshot Hub.app`, and optionally notarizes it |
| `.github/workflows/release.yml` | Builds on every pull request and change to `main`, and publishes releases |
| `CLAUDE.md` | Conventions and agreements for working on this repository |
| `docs/screenshot.png` | The image above |
