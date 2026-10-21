# Screenshot Hub — working agreements

Read this before changing anything in this repository. It records the agreements made with the owner (Ruben).

## Language

- Talk to Ruben in **Dutch**.
- Everything in the repository is **English**: UI text, code, comments, identifiers, README, CHANGELOG, workflow, release notes, commit messages, PR titles and descriptions. Commits before 1.4.0 are Dutch; do not rewrite history.

## Commits and pull requests

- **No AI attribution anywhere**: no `Co-Authored-By` trailer, no "Generated with …" line, no mention of Claude or AI in commit messages, PR titles or PR descriptions.
- Only commit, push, open a PR or merge when Ruben asks for it ("maak een PR", "merge").
- Flow: branch from `origin/main` → one focused commit → push → `gh pr create` → wait until the **Build** check passes → `gh pr merge --merge` (merge commit) → check the release the workflow creates → `git checkout main && git pull`.
- Verify CI and PR state with `gh pr checks` / `gh run view` before merging. Do not rely on watcher notifications alone; they have been wrong before.
- PR descriptions list what was tested and, explicitly, what was not.

## Build and tooling

- **Command Line Tools only.** No Xcode, no package managers, no extra tooling, no third-party dependencies. Everything needed lives in this repository.
- The app is one SwiftUI file, `ScreenshotHub.swift`; macOS 13+, Apple silicon only (the toolchain lacks an x86_64 Swift compatibility library).
- **Never use `@State`**: in the macOS 27 SDK it is a macro whose plugin only ships with Xcode. Use `@LocalState` (defined in `ScreenshotHub.swift`) instead.
- Typecheck: `swiftc -parse-as-library -typecheck -target "$(uname -m)-apple-macos13.0" ScreenshotHub.swift` — must be free of errors and warnings.
- Build: `bash build.sh` (local, ad hoc), `bash build.sh --dmg` (plus DMG), `bash build.sh --release` (Developer ID + notarization, clean tree required).

## Versioning and releases

- User-visible change → bump `VERSION` and add a `## <version>` section to `CHANGELOG.md`. The release notes are taken from that section.
- Merging to `main` makes `.github/workflows/release.yml` create release `v<VERSION>` (if new) and replace the `latest-build` pre-release.
- The in-app update check only considers tags like `v1.2.3`.
- There is no Developer ID yet, so releases are non-notarized pre-releases. Signing secrets for the workflow are listed in the README.
- GitHub Actions are pinned to a commit SHA; when updating one, check its release notes for breaking changes.

## Security baseline

The app passed a security intake review (OWASP ASVS based). Keep it that way:

- App Sandbox and Hardened Runtime stay on. Entitlements are exactly: `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client` (only for the daily update check to `api.github.com`).
- **Any new entitlement or network feature needs a new security review: ask Ruben first.**
- Folder access only through security-scoped bookmarks the user created by choosing a folder.
- Write files only through `SafeFile` (temporary file in the same folder, `renamex_np` with `RENAME_EXCL`, permissions 0600).
- Clipboard capture stays off by default and skips `org.nspasteboard` concealed, transient and auto-generated content.
- No secrets in code. No logging of image data, file names or paths. User-facing error messages contain no paths.

## Testing

- There is no test target. To test logic, copy `ScreenshotHub.swift` into a scratch directory with `@main` removed (`sed 's/^@main$//'`) and compile it together with a small test file that has its own `@main`. Never put test scaffolding in the repository.
- Sandboxed behaviour: build a throwaway `.app` with the same entitlements, ad hoc signed, and run it. Its container under `~/Library/Containers` cannot be deleted afterwards; that is harmless.
- UI: the terminal has no screen recording permission, so render `ContentView` offscreen into a PNG (`NSHostingView` + `cacheDisplay`) and look at it.
- Always report what was tested and what was not (for example Take Screenshot, drag and drop, notarization).

## Other

- The repository is public: `github.com/vdKolk/screenshot-hub`.
- `docs/screenshot.png` is an offscreen render with demo content; re-render it when the UI changes visibly.
