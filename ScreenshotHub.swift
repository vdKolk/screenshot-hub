// ScreenshotHub.swift
//
// Shoot first, store later. Screenshots land in memory first (via the button in the
// app or via the clipboard, for example ⌃⌘⇧4) and only become a file once you save
// them. Drop a screenshot on a Hot Space and it is saved, moved or copied into the
// linked folder.
//
// Build: bash build.sh  (the Command Line Tools are enough: xcode-select --install)
// Requires macOS 13 or later.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import Security

// MARK: - Model

struct Shot: Identifiable, Hashable {
    let url: URL
    let date: Date
    let modified: Date
    var id: URL { url }
}

/// A screenshot that only exists in memory and is not a file yet.
struct MemoryShot: Identifiable, Equatable {
    let id = UUID()
    let png: Data
    let date: Date
    let thumbnail: NSImage
    let pixelWidth: Int
    let pixelHeight: Int

    init?(png: Data, date: Date = Date()) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let thumb = makeThumbnail(source) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        self.png = png
        self.date = date
        self.thumbnail = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
        self.pixelWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? thumb.width
        self.pixelHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? thumb.height
    }

    static func == (a: MemoryShot, b: MemoryShot) -> Bool { a.id == b.id }
}

struct HotSpace: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var colorIndex: Int
    /// Bookmark to the folder, so the Hot Space keeps working when the folder is renamed or moved.
    var bookmark: Data?
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var canUndo = false
}

/// The last action that can be undone.
struct UndoAction {
    var files: [(from: URL, to: URL)] = []
    var moved = true
    var stored: [(shot: MemoryShot, file: URL)] = []
    var discarded: [MemoryShot] = []
    /// Marked-up screenshots: the version from before the markup and the id of the new one.
    var replaced: [(old: MemoryShot, new: UUID)] = []
    var targetName = ""
    var isEmpty: Bool { files.isEmpty && stored.isEmpty && discarded.isEmpty && replaced.isEmpty }
}

extension UTType {
    /// Drag type for screenshots in memory; declared in Info.plist by build.sh.
    static let memoryShot = UTType(exportedAs: "local.screenshothub.memory-shot")
}

let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .yellow, .indigo]

// MARK: - Store

final class Store: ObservableObject {
    static let shared = Store()

    @Published var shots: [Shot] = []
    @Published var selection: Set<URL> = []
    @Published var memoryShots: [MemoryShot] = []
    @Published var memorySelection: Set<UUID> = []
    @Published var isCapturing = false
    @Published var toast: Toast?
    /// The screenshot being marked up; the markup screen then fills the window.
    @Published var markup: MarkupSession?
    var isMarkingUp: Bool { markup != nil }

    enum Tab: Hashable { case memory, stored, space(UUID) }
    /// Always starts on memory. Switching clears the selection, so ⌘1–⌘9 never
    /// send something you cannot see.
    @Published var tab: Tab = .memory {
        didSet {
            guard tab != oldValue else { return }
            selection = []
            memorySelection = []
            spaceWatcher?.cancel()
            spaceWatcher = viewedSpace.flatMap { watch($0.url) }
            reload()
        }
    }
    /// The contents of the Hot Space that is open as a tab.
    @Published var spaceShots: [Shot] = []
    var viewedSpace: HotSpace? {
        guard case .space(let id) = tab else { return nil }
        return hotSpaces.first { $0.id == id }
    }
    private var lastUndo: UndoAction?
    /// The toast that shows the Undo button; when it disappears, lastUndo expires.
    private var undoToastID: UUID?

    @Published var hotSpaces: [HotSpace] = [] {
        didSet { saveHotSpaces() }
    }
    @Published var sourceFolder: URL {
        didSet {
            selection = []
            startWatching()
            reload()
        }
    }
    /// In the sandbox the app can only access folders you choose yourself. Until a
    /// screenshot folder has been chosen, sourceFolder is only a guess for the picker.
    @Published private(set) var hasSourceAccess = false
    @Published var onlyScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(onlyScreenshots, forKey: "onlyScreenshots")
            reload()
        }
    }
    @Published var moveFiles: Bool {
        didSet { UserDefaults.standard.set(moveFiles, forKey: "moveFiles") }
    }
    @Published var watchClipboard: Bool {
        didSet { UserDefaults.standard.set(watchClipboard, forKey: "watchClipboard") }
    }

    var hasSelection: Bool { !selection.isEmpty || !memorySelection.isEmpty }

    private var watcher: DispatchSourceFileSystemObject?
    private var spaceWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var clipboardTimer: Timer?
    private var clipboardCount = NSPasteboard.general.changeCount
    /// Folders the app has opened access to, per key ("source" or the id of a Hot Space).
    private var scopedURLs: [String: URL] = [:]
    /// Hot Spaces whose bookmark no longer works or no longer grants access.
    private var inaccessibleSpaces: Set<UUID> = []
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    private static let sourceKey = "source"

    init() {
        // Everything this app (and screencapture, which it launches) creates is owner-only.
        umask(0o077)
        Store.removeLeftoverCaptures()
        let defaults = UserDefaults.standard
        var resolvedSource: URL?
        if let data = defaults.data(forKey: "sourceBookmark"), let resolved = Store.resolveBookmark(data) {
            resolvedSource = resolved.url
            if resolved.stale, let fresh = Store.makeBookmark(resolved.url) {
                defaults.set(fresh, forKey: "sourceBookmark")
            }
        }
        sourceFolder = resolvedSource ?? Store.systemScreenshotFolder()
        onlyScreenshots = defaults.object(forKey: "onlyScreenshots") as? Bool ?? true
        moveFiles = defaults.object(forKey: "moveFiles") as? Bool ?? true
        // Off by default: the clipboard can contain sensitive images.
        watchClipboard = defaults.object(forKey: "watchClipboard") as? Bool ?? false
        if let data = defaults.data(forKey: "hotSpaces"),
           let list = try? JSONDecoder().decode([HotSpace].self, from: data) {
            hotSpaces = list
        }
        if let resolvedSource {
            hasSourceAccess = beginAccess(resolvedSource, key: Store.sourceKey)
        }
        for space in hotSpaces { refreshLocation(of: space) }
        saveHotSpaces()
        startWatching()
        reload()

        // Escape clears the selection, unless you are typing in a text field or a dialog is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.hasSelection,
                  NSApp.modalWindow == nil, !self.isMarkingUp,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.selection = []
            self.memorySelection = []
            return nil
        }
        // Renaming a folder in Finder shows the new name when you come back to the app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for space in self.hotSpaces { self.refreshLocation(of: space) }
        }
        // The clipboard has no notifications, so we check twice a second whether it changed.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkClipboard() }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private static let capturePrefix = "ScreenshotHub-capture-"

    /// A temporary capture file is only left behind if the app quit while capturing.
    private static func removeLeftoverCaptures() {
        let temp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(capturePrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        // The contents must be an image too; ImageIO only reads the file header for this.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    /// The real home folder. In the sandbox, NSHomeDirectory and FileManager point to the container.
    static let realHome: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Best guess for the folder where macOS saves screenshots (⌘⇧5 › Options), otherwise the Desktop.
    /// In the sandbox the macOS setting cannot be read; then this only serves as the starting point
    /// for the picker, because the app only gets access once you choose the folder yourself.
    static func systemScreenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = location.hasPrefix("~/")
                ? realHome.appendingPathComponent(String(location.dropFirst(2)), isDirectory: true)
                : URL(fileURLWithPath: location, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.standardizedFileURL
            }
        }
        return realHome.appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: Folder access (sandbox)

    /// Bookmark that restores access to a folder you chose yourself after a restart.
    static func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Opens access to a folder and keeps it open until endAccess. Returns false if not allowed.
    @discardableResult
    private func beginAccess(_ url: URL, key: String) -> Bool {
        if let open = scopedURLs[key] {
            if open == url { return true }
            open.stopAccessingSecurityScopedResource()
            scopedURLs[key] = nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            // Without the sandbox (for example while testing) there is nothing to restrict.
            return !Store.isSandboxed
        }
        scopedURLs[key] = url
        return true
    }

    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private func endAccess(key: String) {
        scopedURLs.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
    }

    private static let screenshotAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// macOS marks screenshots with an extended attribute; the file name is the fallback
    /// (including the Dutch, German and French names macOS uses).
    static func isScreenshot(_ url: URL) -> Bool {
        let size = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, screenshotAttribute, nil, 0, 0, 0)
        }
        if size >= 0 { return true }
        let name = url.lastPathComponent.lowercased()
        return ["screenshot", "schermafbeelding", "bildschirmfoto", "capture d"].contains { name.hasPrefix($0) }
    }

    /// Sets the same marker as macOS, so a saved screenshot also shows under "Only screenshots".
    static func markAsScreenshot(_ url: URL) {
        guard let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            value.withUnsafeBytes { bytes in
                _ = setxattr(path, screenshotAttribute, bytes.baseAddress, value.count, 0, 0)
            }
        }
    }

    /// The same name macOS uses: "Screenshot 2026-10-16 at 15.41.22.png".
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }

    // MARK: Reading and watching

    func reload() {
        shots = Store.listShots(in: sourceFolder, onlyScreenshots: onlyScreenshots)
        // A Hot Space holds whatever you put there yourself, so no screenshot filter there.
        spaceShots = viewedSpace.map { Store.listShots(in: $0.url, onlyScreenshots: false) } ?? []
        let visible = tab == .stored ? shots : spaceShots
        selection = selection.intersection(visible.map(\.url))
    }

    private static func listShots(in folder: URL, onlyScreenshots: Bool) -> [Shot] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        return items.compactMap { url -> Shot? in
            guard imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            if onlyScreenshots && !isScreenshot(url) { return nil }
            let created = values.creationDate ?? .distantPast
            return Shot(url: url, date: created, modified: values.contentModificationDate ?? created)
        }
        .sorted { $0.date > $1.date }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = item
        // Wait a moment so macOS has finished writing the file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = watch(sourceFolder)
    }

    private func watch(_ folder: URL) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    /// Opens the Hot Space as a tab, so you can see what is in it.
    func openSpace(_ space: HotSpace) {
        let space = refreshLocation(of: space)
        if let reason = unavailableReason(space) {
            showToast(reason)
            return
        }
        tab = .space(space.id)
    }

    // MARK: Memory

    /// Lets you pick an area or window (like ⌘⇧4) and keeps the result in memory only.
    func captureToMemory() {
        guard !isCapturing else { return }
        isCapturing = true
        // screencapture cannot write straight into this app's memory. The temporary file
        // lives in the sandbox container's temporary folder, is readable by the owner only
        // (umask) and is read and deleted right away.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Store.capturePrefix)\(UUID().uuidString).png")
        NSApp.hide(nil)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", temp.path]
            var started = true
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                started = false
            }
            let data = try? Data(contentsOf: temp)
            try? FileManager.default.removeItem(at: temp)
            let shot = data.flatMap { MemoryShot(png: $0) }
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                guard let self else { return }
                self.isCapturing = false
                if let shot {
                    self.addToMemory(shot)
                } else if !started {
                    self.showToast("Couldn’t take screenshot: macOS couldn’t start the screen capture")
                } else if data != nil {
                    self.showToast("Couldn’t take screenshot: the capture was not a readable image")
                }
                // No file but it did start: the user cancelled with Escape.
            }
        }
    }

    private func addToMemory(_ shot: MemoryShot) {
        memoryShots.insert(shot, at: 0)
        // Show it and select it right away, so ⌘1–⌘9 or ⌘S save it immediately.
        tab = .memory
        memorySelection = [shot.id]
    }

    /// Markers (nspasteboard.org) that password managers and other apps use to flag clipboard
    /// contents as concealed, transient or auto-generated. We never pick those up.
    static let privateClipboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Picks up an image from the clipboard, such as a screenshot taken with ⌃⌘⇧4.
    /// Only when turned on; the contents are only read once the type checks out.
    func checkClipboard(_ pasteboard: NSPasteboard = .general) {
        guard pasteboard.changeCount != clipboardCount else { return }
        clipboardCount = pasteboard.changeCount
        guard watchClipboard, let types = pasteboard.types else { return }
        guard !types.contains(where: Store.privateClipboardTypes.contains) else { return }
        // Only a plain image counts. Copied files, text with images or web content
        // are left alone.
        let ignored: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .rtf, .rtfd, .html]
        guard !types.contains(where: ignored.contains) else { return }
        let png = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        guard let png, memoryShots.first?.png != png, let shot = MemoryShot(png: png) else { return }
        addToMemory(shot)
    }

    func saveMemory(_ ids: [UUID]) {
        guard ensureSourceAccess() else { return }
        deliver(files: [], memory: ids, into: sourceFolder, name: sourceFolder.lastPathComponent)
    }

    /// Saves everything in memory to the screenshot folder. Returns false if anything failed.
    func saveAllMemory() -> Bool {
        guard ensureSourceAccess() else { return false }
        return deliver(files: [], memory: memoryShots.map(\.id), into: sourceFolder,
                       name: sourceFolder.lastPathComponent)
    }

    /// Asks for the screenshot folder first if the app has no access to it yet.
    private func ensureSourceAccess() -> Bool {
        if !hasSourceAccess { chooseSourceFolder() }
        return hasSourceAccess
    }

    func discardMemory(_ ids: [UUID]) {
        let wanted = Set(ids)
        let discarded = memoryShots.filter { wanted.contains($0.id) }
        guard !discarded.isEmpty else { return }
        memoryShots.removeAll { wanted.contains($0.id) }
        memorySelection.subtract(wanted)
        lastUndo = UndoAction(discarded: discarded)
        showToast(discarded.count == 1 ? "Screenshot discarded" : "\(discarded.count) screenshots discarded",
                  canUndo: true)
    }

    func copyToClipboard(_ shot: MemoryShot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(shot.png, forType: .png)
        clipboardCount = pasteboard.changeCount
        showToast("Image copied")
    }

    // MARK: Markup

    /// Opens a screenshot from memory in the markup screen.
    func markUp(memory id: UUID) {
        guard let shot = memoryShots.first(where: { $0.id == id }),
              let source = CGImageSourceCreateWithData(shot.png as CFData, nil),
              let session = MarkupSession(source: .memory(id), image: source) else {
            showToast("Couldn’t mark up: the image is not readable")
            return
        }
        markup = session
    }

    /// Opens a saved screenshot. The result goes into memory as a copy; the file stays as it is.
    func markUp(file url: URL) {
        guard Store.isImageFile(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let session = MarkupSession(source: .file(url), image: source) else {
            showToast("Couldn’t mark up: the file is not a readable image")
            return
        }
        markup = session
    }

    var canMarkUpSelection: Bool { !isMarkingUp && memorySelection.count + selection.count == 1 }

    func markUpSelection() {
        guard canMarkUpSelection else { return }
        if let id = memorySelection.first {
            markUp(memory: id)
        } else if let url = selection.first {
            markUp(file: url)
        }
    }

    /// Draws the marks into the image. A screenshot from memory is replaced (with Undo),
    /// a saved file gets a copy in memory.
    func finishMarkup(_ session: MarkupSession, marks: [Mark]) {
        guard let png = renderMarkup(session, marks: marks) else {
            showToast("Couldn’t mark up: the image could not be created")
            return
        }
        if case .memory(let id) = session.source,
           let index = memoryShots.firstIndex(where: { $0.id == id }) {
            let old = memoryShots[index]
            guard let new = MemoryShot(png: png, date: old.date) else { return }
            memoryShots[index] = new
            if memorySelection.remove(id) != nil { memorySelection.insert(new.id) }
            lastUndo = UndoAction(replaced: [(old: old, new: new.id)])
            showToast("Markup added", canUndo: true)
        } else {
            // A saved file, or a screenshot that has left memory in the meantime.
            guard let new = MemoryShot(png: png) else { return }
            addToMemory(new)
            showToast("Marked-up copy is in memory")
        }
        markup = nil
    }

    func cancelMarkup() {
        markup = nil
    }

    // MARK: Delivering to Hot Spaces

    func dropped(_ urls: [URL], memory ids: [UUID], on space: HotSpace) {
        // Dragging one screenshot out of a multiple selection takes the whole selection along.
        var files = urls
        var memory = ids
        if files.count == 1, selection.contains(files[0]), selection.count > 1 {
            files = Array(selection)
        }
        if memory.count == 1, memorySelection.contains(memory[0]), memorySelection.count > 1 {
            memory = Array(memorySelection)
        }
        deliver(files, memory: memory, to: space)
    }

    func deliverSelection(to space: HotSpace) {
        guard hasSelection else { return }
        deliver(Array(selection), memory: Array(memorySelection), to: space)
    }

    func deliver(_ urls: [URL], memory ids: [UUID] = [], to space: HotSpace) {
        let space = refreshLocation(of: space)
        if let reason = unavailableReason(space) {
            showToast(reason)
            return
        }
        deliver(files: urls, memory: ids, into: space.url, name: space.name)
    }

    /// Saves screenshots from memory to the folder and moves or copies files into it.
    @discardableResult
    private func deliver(files urls: [URL], memory ids: [UUID], into folder: URL, name: String) -> Bool {
        let fm = FileManager.default
        // Images only; folders and other files dragged in from Finder are left alone.
        let images = urls.filter(Store.isImageFile)
        let skipped = urls.count - images.count
        let wanted = Set(ids)
        let memory = memoryShots.filter { wanted.contains($0.id) }
        guard !images.isEmpty || !memory.isEmpty else {
            if skipped > 0 { showToast("Only images can go to a Hot Space") }
            return skipped == 0
        }

        var undo = UndoAction(moved: moveFiles, targetName: name)
        var failed = 0
        var failure: String?

        for shot in memory {
            let dest = uniqueDestination(for: Store.fileName(for: shot.date), in: folder)
            do {
                try SafeFile.write(shot.png, to: dest) { temp in
                    // The date of capturing, not of saving, so the order is right.
                    try? fm.setAttributes([.creationDate: shot.date, .modificationDate: shot.date],
                                          ofItemAtPath: temp.path)
                    Store.markAsScreenshot(temp)
                }
                undo.stored.append((shot: shot, file: dest))
            } catch {
                failed += 1
                failure = failure ?? SafeFile.describe(error)
            }
        }
        let storedIDs = Set(undo.stored.map(\.shot.id))
        memoryShots.removeAll { storedIDs.contains($0.id) }
        memorySelection.subtract(storedIDs)

        for src in images {
            let sameFolder = src.deletingLastPathComponent().standardizedFileURL.path
                == folder.standardizedFileURL.path
            if sameFolder { continue }
            let dest = uniqueDestination(for: SafeFile.safeName(src.lastPathComponent), in: folder)
            do {
                if moveFiles {
                    try SafeFile.move(src, to: dest)
                } else {
                    try SafeFile.copy(src, to: dest)
                }
                undo.files.append((from: src, to: dest))
            } catch {
                failed += 1
                failure = failure ?? SafeFile.describe(error)
            }
        }

        var parts: [String] = []
        if !undo.stored.isEmpty {
            let what = undo.stored.count == 1 ? "Screenshot" : "\(undo.stored.count) screenshots"
            parts.append("\(what) saved to \(name)")
        }
        if !undo.files.isEmpty {
            let what = undo.files.count == 1 ? "Screenshot" : "\(undo.files.count) screenshots"
            parts.append("\(what) \(moveFiles ? "moved" : "copied") to \(name)")
        }
        if let failure {
            parts.append(undo.isEmpty ? "Failed: \(failure)" : "\(failed) failed: \(failure)")
        }
        if skipped > 0 {
            parts.append(skipped == 1 ? "1 file skipped (not an image)"
                                      : "\(skipped) files skipped (not images)")
        }

        if !undo.isEmpty { lastUndo = undo }
        if !parts.isEmpty {
            showToast(parts.joined(separator: " · "), canUndo: !undo.isEmpty)
        }
        reload()
        return failed == 0
    }

    /// Moves moved screenshots back, puts created copies and files in the Trash, and
    /// puts saved or discarded screenshots back in memory.
    func undoLast() {
        guard let last = lastUndo else { return }
        lastUndo = nil
        let fm = FileManager.default
        var failed = 0
        var failure: String?
        for item in last.files {
            do {
                if last.moved {
                    let folder = item.from.deletingLastPathComponent()
                    let back = fm.fileExists(atPath: item.from.path)
                        ? uniqueDestination(for: item.from.lastPathComponent, in: folder)
                        : item.from
                    try SafeFile.move(item.to, to: back)
                } else {
                    try fm.trashItem(at: item.to, resultingItemURL: nil)
                }
            } catch {
                failed += 1
                failure = failure ?? SafeFile.describe(error)
            }
        }
        var restored = last.discarded
        for item in last.stored {
            do {
                try fm.trashItem(at: item.file, resultingItemURL: nil)
                restored.append(item.shot)
            } catch {
                failed += 1
                failure = failure ?? SafeFile.describe(error)
            }
        }
        if !restored.isEmpty {
            memoryShots = (memoryShots + restored).sorted { $0.date > $1.date }
        }
        for item in last.replaced {
            guard let index = memoryShots.firstIndex(where: { $0.id == item.new }) else { continue }
            memoryShots[index] = item.old
            if memorySelection.remove(item.new) != nil { memorySelection.insert(item.old.id) }
        }

        let total = last.files.count + last.stored.count + last.discarded.count
        if failed > 0, let failure {
            showToast("Couldn’t undo \(failed) of \(total) screenshots: \(failure)")
        } else if !last.discarded.isEmpty || !last.stored.isEmpty {
            showToast("Back in memory")
        } else if !last.replaced.isEmpty {
            showToast("Markup removed")
        } else {
            showToast(last.moved ? "Moved back from \(last.targetName)" : "Copy removed from \(last.targetName)")
        }
        reload()
    }

    /// Looks up a Hot Space's folder via its bookmark, opens access to it, and updates the path
    /// and name when it has been renamed or moved.
    @discardableResult
    private func refreshLocation(of space: HotSpace) -> HotSpace {
        guard let index = hotSpaces.firstIndex(where: { $0.id == space.id }) else { return space }
        let current = hotSpaces[index]
        var updated = current
        let key = current.id.uuidString
        if let data = current.bookmark, let resolved = Store.resolveBookmark(data) {
            if beginAccess(resolved.url, key: key) {
                inaccessibleSpaces.remove(current.id)
            } else {
                inaccessibleSpaces.insert(current.id)
            }
            if resolved.url.path != current.path || resolved.stale {
                // If the Hot Space was named after the folder, the name follows.
                if current.name == current.url.lastPathComponent {
                    updated.name = resolved.url.lastPathComponent
                }
                updated.path = resolved.url.path
                updated.bookmark = Store.makeBookmark(resolved.url) ?? data
            }
        } else if current.bookmark == nil, beginAccess(current.url, key: key) {
            // Hot Space from a version without the sandbox: can only be restored outside the sandbox.
            updated.bookmark = Store.makeBookmark(current.url)
        } else if current.bookmark != nil {
            // The bookmark can no longer be used, for example because the folder was deleted.
            inaccessibleSpaces.insert(current.id)
        }
        if updated != current { hotSpaces[index] = updated }
        return updated
    }

    private func isInTrash(_ url: URL) -> Bool {
        let trash = Store.realHome.appendingPathComponent(".Trash")
        return url.standardizedFileURL.path.hasPrefix(trash.standardizedFileURL.path + "/")
    }

    private func uniqueDestination(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: Other actions

    func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.showToast(error == nil ? "Moved to Trash" : "Couldn’t move to Trash")
                self?.reload()
            }
        }
    }

    func copyToClipboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            showToast("Couldn’t copy: the file is no longer readable")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        // Don't pick this up as a new screenshot in memory.
        clipboardCount = pasteboard.changeCount
        showToast("Image copied")
    }

    func addHotSpace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add as Hot Space"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !hotSpaces.contains(where: { $0.path == url.path }) {
            let space = HotSpace(name: url.lastPathComponent,
                                 path: url.path,
                                 colorIndex: hotSpaces.count % palette.count,
                                 bookmark: Store.makeBookmark(url))
            beginAccess(url, key: space.id.uuidString)
            hotSpaces.append(space)
        }
    }

    func removeHotSpace(_ space: HotSpace) {
        if viewedSpace?.id == space.id { tab = .stored }
        hotSpaces.removeAll { $0.id == space.id }
        inaccessibleSpaces.remove(space.id)
        endAccess(key: space.id.uuidString)
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = sourceFolder
        panel.message = "Choose the folder that holds your screenshots. You can see which folder macOS uses under ⌘⇧5 › Options."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(Store.makeBookmark(url), forKey: "sourceBookmark")
        hasSourceAccess = beginAccess(url, key: Store.sourceKey)
        sourceFolder = url
    }

    /// Why a Hot Space cannot be used right now, or nil if it can.
    private func unavailableReason(_ space: HotSpace) -> String? {
        if space.bookmark == nil || inaccessibleSpaces.contains(space.id) {
            return "No access to \(space.name) (anymore). Remove the Hot Space and add it again."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: space.path, isDirectory: &isDir), isDir.boolValue,
              !isInTrash(space.url) else {
            return "The folder of \(space.name) no longer exists. Remove the Hot Space or put the folder back."
        }
        return nil
    }

    private func saveHotSpaces() {
        if let data = try? JSONEncoder().encode(hotSpaces) {
            UserDefaults.standard.set(data, forKey: "hotSpaces")
        }
    }

    func showToast(_ text: String, canUndo: Bool = false) {
        let new = Toast(text: text, canUndo: canUndo)
        toast = new
        if canUndo { undoToastID = new.id }
        // With a button in it, the toast stays longer so you have time to click.
        DispatchQueue.main.asyncAfter(deadline: .now() + (canUndo ? 6 : 2.5)) { [weak self] in
            guard let self else { return }
            if self.toast?.id == new.id { self.toast = nil }
            // After that it can no longer be undone: release the screenshots kept for it
            // (discarded or saved), so they leave memory.
            if self.undoToastID == new.id {
                self.undoToastID = nil
                self.lastUndo = nil
            }
        }
    }
}

// MARK: - Helpers

/// Places files without ever overwriting anything and without half-written results.
/// Everything first goes to a hidden temporary file in the same folder (so on the same
/// volume) and is then renamed in one step. If the name already exists, that fails.
enum SafeFile {
    /// New files are readable by the owner only (0600): screenshots can contain anything.
    static let permissions = 0o600

    static func write(_ data: Data, to dest: URL, prepare: (URL) -> Void = { _ in }) throws {
        try place(at: dest, permissions: permissions) { temp in
            try data.write(to: temp, options: .withoutOverwriting)
            prepare(temp)
        }
    }

    static func copy(_ src: URL, to dest: URL, permissions: Int = SafeFile.permissions) throws {
        try place(at: dest, permissions: permissions) { temp in
            try FileManager.default.copyItem(at: src, to: temp)
        }
    }

    /// On the same volume a rename; to another volume first a full copy, and only then
    /// the original is removed. A moved file keeps its own permissions.
    static func move(_ src: URL, to dest: URL) throws {
        do {
            try renameExclusive(src, to: dest)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) {
            let original = (try? FileManager.default.attributesOfItem(atPath: src.path)[.posixPermissions]
                as? Int) ?? SafeFile.permissions
            try copy(src, to: dest, permissions: original)
            try FileManager.default.removeItem(at: src)
        }
    }

    private static func place(at dest: URL, permissions: Int, fill: (URL) throws -> Void) throws {
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".ScreenshotHub-\(UUID().uuidString).tmp")
        do {
            try fill(temp)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            try renameExclusive(temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// rename(2) silently overwrites; with RENAME_EXCL it fails when dest already exists.
    private static func renameExclusive(_ src: URL, to dest: URL) throws {
        let result = src.withUnsafeFileSystemRepresentation { from in
            dest.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Makes a file name from outside (a dragged file) safe: no path or control
    /// characters, not hidden, and short enough for the file system.
    static func safeName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        base = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        base = String(base.drop { $0 == "." || $0 == " " })
        if base.isEmpty { base = "Image" }
        // 255 bytes is the maximum; leave room for " 99" and the extension.
        while base.utf8.count > 200 { base.removeLast() }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// An understandable reason without file names or paths.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        let posix = error.domain == NSPOSIXErrorDomain ? Int32(error.code)
            : (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
                $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
            }
        switch (error.domain, error.code, posix) {
        case (_, _, ENOSPC?), (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError, _):
            return "there isn’t enough space"
        case (_, _, EACCES?), (_, _, EPERM?),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError, _),
             (NSCocoaErrorDomain, NSFileReadNoPermissionError, _):
            return "the app has no access to that folder"
        case (_, _, EROFS?), (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError, _):
            return "that disk is read-only"
        case (_, _, EEXIST?), (NSCocoaErrorDomain, NSFileWriteFileExistsError, _):
            return "a file with that name already exists"
        case (_, _, ENOENT?), (NSCocoaErrorDomain, NSFileNoSuchFileError, _),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError, _):
            return "the file no longer exists"
        default:
            return "something went wrong with the file"
        }
    }
}

/// Path with ~ for the real home folder. In the sandbox NSString doesn't abbreviate it,
/// because the home folder there is the container.
func displayPath(_ path: String) -> String {
    let home = Store.realHome.path
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Reads what was dropped on a Hot Space: files from Finder or the app, and screenshots from memory.
func loadDrop(from providers: [NSItemProvider], completion: @escaping ([URL], [UUID]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    var ids: [UUID] = []
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.memoryShot.identifier) {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.memoryShot.identifier) { data, _ in
                if let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
                    lock.lock(); ids.append(id); lock.unlock()
                }
                group.leave()
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    let resolved = (url as NSURL).filePathURL ?? url
                    lock.lock(); urls.append(resolved); lock.unlock()
                }
                group.leave()
            }
        }
    }
    group.notify(queue: .main) { completion(urls, ids) }
}

/// Draggable within the app (to a Hot Space) and as PNG to other apps.
func memoryItemProvider(for shot: MemoryShot) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = Store.fileName(for: shot.date)
    let id = Data(shot.id.uuidString.utf8)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.memoryShot.identifier, visibility: .all) { done in
        done(id, nil)
        return nil
    }
    let png = shot.png
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
        done(png, nil)
        return nil
    }
    return provider
}

func makeThumbnail(_ url: URL, maxPixel: Int = 480) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return makeThumbnail(source, maxPixel: maxPixel)
}

func makeThumbnail(_ source: CGImageSource, maxPixel: Int = 480) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// The key is path plus modification date, so a new file with the same name gets a new thumbnail.
enum ThumbCache {
    static let shared = NSCache<NSString, NSImage>()
    static func key(_ url: URL, _ modified: Date) -> NSString {
        "\(url.path)|\(modified.timeIntervalSinceReferenceDate)" as NSString
    }
}

/// Click selects, Command-click adds or removes, Shift-click selects a range.
func applyClick<ID: Hashable>(on id: ID, order: [ID], selection: inout Set<ID>, anchor: inout ID?) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        anchor = id
    } else if flags.contains(.shift),
              let anchorID = anchor,
              let a = order.firstIndex(of: anchorID),
              let b = order.firstIndex(of: id) {
        selection.formUnion(order[min(a, b)...max(a, b)])
    } else {
        selection = [id]
        anchor = id
    }
}

/// Replacement for @State: in the macOS 27 SDK @State is a macro whose plugin only
/// ships with Xcode, not with the Command Line Tools.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}

// MARK: - Marks

/// A mark on a screenshot. Points are in image pixels, from the top left.
struct Mark {
    enum Tool: CaseIterable {
        case pen, highlighter, arrow, rectangle, ellipse

        var name: String {
            switch self {
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Oval"
            }
        }

        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            }
        }

        /// Shortcut without ⌘ in the markup screen.
        var key: Character {
            switch self {
            case .pen: return "p"
            case .highlighter: return "h"
            case .arrow: return "a"
            case .rectangle: return "r"
            case .ellipse: return "o"
            }
        }
    }

    var tool: Tool
    /// Pen and highlighter: every point. The shapes only use the first and the last.
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat

    /// The highlighter is wider and translucent, so what is underneath stays readable.
    var lineWidth: CGFloat { tool == .highlighter ? width * 3 : width }
    var strokeColor: NSColor { tool == .highlighter ? color.withAlphaComponent(0.4) : color }

    var path: Path {
        var path = Path()
        guard let start = points.first, let end = points.last else { return path }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .pen, .highlighter:
            // Smooth: through the midpoints between points, with the points themselves as control points.
            path.move(to: start)
            for (a, b) in zip(points, points.dropFirst()) {
                path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            path.addLine(to: end)
        case .arrow:
            path.move(to: start)
            path.addLine(to: end)
            guard start != end else { break }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = lineWidth * 4
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + side * .pi / 6
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x + head * cos(wing), y: end.y + head * sin(wing)))
            }
        case .rectangle:
            path.addRect(rect)
        case .ellipse:
            path.addEllipse(in: rect)
        }
        return path
    }
}

/// Fixed sRGB colors: system colors differ between light and dark mode, an image does not.
let markColors: [(name: String, color: NSColor)] = [
    ("Red", NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)),
    ("Orange", NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)),
    ("Yellow", NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 1)),
    ("Green", NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
    ("Blue", NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)),
    ("Black", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
    ("White", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
]

/// A screenshot in the markup screen: from memory, or a saved file.
struct MarkupSession {
    enum Source { case memory(UUID), file(URL) }

    let source: Source
    let image: CGImage
    /// Resolution of the original (144 on Retina), so the result opens at the same size.
    let dpi: (width: Double, height: Double)?

    init?(source: Source, image imageSource: CGImageSource) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              // Full size, rotated upright according to the metadata.
              let image = makeThumbnail(imageSource, maxPixel: max(width, height)) else { return nil }
        self.source = source
        self.image = image
        if let x = props[kCGImagePropertyDPIWidth] as? Double, let y = props[kCGImagePropertyDPIHeight] as? Double {
            dpi = (x, y)
        } else {
            dpi = nil
        }
    }
}

/// Draws the marks into the image and returns the result as PNG. Everything happens in memory.
func renderMarkup(_ session: MarkupSession, marks: [Mark]) -> Data? {
    let image = session.image
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.draw(image, in: bounds)
    // Marks count from the top left, Core Graphics from the bottom left.
    context.translateBy(x: 0, y: bounds.height)
    context.scaleBy(x: 1, y: -1)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for mark in marks {
        context.addPath(mark.path.cgPath)
        context.setStrokeColor(mark.strokeColor.cgColor)
        context.setLineWidth(mark.lineWidth)
        context.strokePath()
    }
    guard let result = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    var props: [CFString: Any] = [:]
    if let dpi = session.dpi {
        props[kCGImagePropertyDPIWidth] = dpi.width
        props[kCGImagePropertyDPIHeight] = dpi.height
    }
    CGImageDestinationAddImage(destination, result, props as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// The marks in the markup screen. Changes go through the window's UndoManager,
/// so ⌘Z and ⌘⇧Z from the Edit menu work.
final class MarkupModel: ObservableObject {
    @Published private(set) var marks: [Mark] = []
    /// The mark being drawn right now.
    @Published var current: Mark?
    weak var undoManager: UndoManager?

    func set(_ new: [Mark]) {
        let old = marks
        marks = new
        undoManager?.registerUndo(withTarget: self) { $0.set(old) }
    }
}

// MARK: - App

/// Warns on quit, because screenshots in memory are lost then.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Store.shared
        let count = store.memoryShots.count
        guard count > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = count == 1
            ? "1 screenshot hasn’t been saved"
            : "\(count) screenshots haven’t been saved"
        alert.informativeText = "Screenshots in memory are lost when you quit. "
            + "Saving puts them in \(store.sourceFolder.lastPathComponent)."
        alert.addButton(withTitle: "Save All and Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Quit Without Saving")
        discard.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return store.saveAllMemory() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// Version and security information for the About window. build.sh puts the version, build,
/// commit and build date in Info.plist; the app reads the signature from itself.
enum AppInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var version: String { info["CFBundleShortVersionString"] as? String ?? "unknown" }
    static var build: String { info["CFBundleVersion"] as? String ?? "unknown" }
    static var commit: String { info["ScreenshotHubCommit"] as? String ?? "unknown" }
    static var buildDate: Date? {
        (info["ScreenshotHubBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    /// What the app was built with, so a build can be reproduced.
    static var toolchain: String { info["ScreenshotHubToolchain"] as? String ?? "unknown" }
    static var sdk: String { info["ScreenshotHubSDK"] as? String ?? "unknown" }

    struct Signature {
        var hardenedRuntime = false
        var adHoc = false
        var teamID: String?
        var signer: String?
    }

    /// Reads the app's own signature, so the About window shows what was actually signed.
    static var signature: Signature? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        var result = Signature()
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        result.hardenedRuntime = flags & SecCodeSignatureFlags.runtime.rawValue != 0
        result.adHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        result.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            result.signer = SecCertificateCopySubjectSummary(leaf) as String?
        }
        return result
    }

    /// All information as plain text, for the About window and for copying.
    static var summary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon (arm64)"
        #else
        let arch = "Intel (x86_64)"
        #endif
        let english = Date.FormatStyle(date: .long, time: .shortened, locale: Locale(identifier: "en_US"))
        let built = buildDate.map { $0.formatted(english) } ?? "unknown"
        let dirty = commit.hasSuffix("-dirty")
        let commitText = dirty
            ? "\(commit.dropLast("-dirty".count)), with uncommitted changes"
            : commit

        let signing: String
        let runtime: String
        if let signature {
            if signature.adHoc {
                signing = "local (ad hoc), not notarized"
            } else {
                signing = [signature.signer, signature.teamID.map { "team \($0)" }]
                    .compactMap { $0 }.joined(separator: ", ")
            }
            runtime = signature.hardenedRuntime ? "on" : "off"
        } else {
            signing = "not signed"
            runtime = "off"
        }

        return """
        Shoot first, store later.

        Version \(version), build \(build)
        Built: \(built)
        Commit: \(commitText)
        Built with: \(toolchain), macOS SDK \(sdk)

        macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) on \(arch), requires 13.0 or later
        App Sandbox: \(Store.isSandboxed ? "on" : "off")
        Hardened Runtime: \(runtime)
        Signature: \(signing)
        Clipboard capture: \(Store.shared.watchClipboard ? "on" : "off")
        Update check: \(UpdateChecker.shared.enabled ? "daily, github.com only" : "off")

        Source code: github.com/\(UpdateChecker.repository)
        """
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString(string: summary, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        let link = "github.com/\(UpdateChecker.repository)"
        let range = (summary as NSString).range(of: link)
        if range.location != NSNotFound {
            credits.addAttribute(.link, value: "https://\(link)", range: range)
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .version: "build \(build) · \(commit)",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    static func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Screenshot Hub\n" + summary, forType: .string)
    }
}

/// Checks at most once a day whether GitHub has a newer version and then shows a banner
/// with a button to the release page. The app itself downloads or installs nothing.
/// This is the app's only network traffic (entitlement com.apple.security.network.client).
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "vdKolk/screenshot-hub"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    private static let interval: TimeInterval = 24 * 60 * 60
    /// A response with 30 releases is a few hundred kB; anything above this is suspicious.
    private static let maxResponseBytes = 2_000_000

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "checkForUpdates")
            if enabled { checkIfDue() } else { available = nil }
        }
    }
    /// The newer version that was found, such as "1.3.0".
    @Published private(set) var available: String?
    @Published private(set) var isChecking = false
    /// The first time, the app explains that it contacts GitHub.
    @Published var disclosureShown: Bool {
        didSet { UserDefaults.standard.set(disclosureShown, forKey: "updateDisclosureShown") }
    }

    private let session: URLSession
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        disclosureShown = defaults.bool(forKey: "updateDisclosureShown")
        // No cookies, no disk cache: the request leaves nothing behind.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        // Someone who leaves the app open for days gets the banner too.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in self?.checkIfDue() }
    }

    static var releasePageURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// The app builds the link itself; a URL from the server's response is never opened.
    static func releaseURL(for version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    func checkIfDue() {
        guard enabled else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= UpdateChecker.interval { check(manual: false) }
    }

    func checkNow() { check(manual: true) }

    /// "Not Now": no more banner for this version, but again for a later one.
    func dismiss() {
        UserDefaults.standard.set(available, forKey: "dismissedUpdate")
        available = nil
    }

    private func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: UpdateChecker.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent; we don't send the version number.
        request.setValue("ScreenshotHub", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let newest = error == nil && status == 200 ? data.flatMap(UpdateChecker.newestVersion) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                guard let newest else {
                    // An automatic check that fails quietly tries again later.
                    if manual {
                        Store.shared.showToast(error != nil
                            ? "Couldn’t check for updates: no connection to GitHub"
                            : "Couldn’t check for updates: GitHub returned no usable response")
                    }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                self.handle(newest: newest, manual: manual)
            }
        }.resume()
    }

    private func handle(newest: String, manual: Bool) {
        guard UpdateChecker.isNewer(newest, than: AppInfo.version) else {
            available = nil
            if manual { Store.shared.showToast("You’re up to date (\(AppInfo.version))") }
            return
        }
        let dismissed = UserDefaults.standard.string(forKey: "dismissedUpdate")
        if manual || dismissed != newest { available = newest }
    }

    /// The highest version among the releases: only tags like v1.2.3, no drafts and not the
    /// "latest-build" pre-release. Anything that looks different is ignored.
    static func newestVersion(from data: Data) -> String? {
        guard data.count <= maxResponseBytes,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let versions: [String] = releases.compactMap { release in
            guard release["draft"] as? Bool != true,
                  let tag = release["tag_name"] as? String, tag.hasPrefix("v") else { return nil }
            let version = String(tag.dropFirst())
            return parse(version) != nil ? version : nil
        }
        return versions.max { isNewer($1, than: $0) }
    }

    static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return y.lexicographicallyPrecedes(x)
    }
}

@main
struct ScreenshotHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared
    @StateObject private var updates = UpdateChecker.shared

    var body: some Scene {
        WindowGroup("Screenshot Hub") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updates)
                .frame(minWidth: 900, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Screenshot Hub") { AppInfo.showAboutPanel() }
                Button("Copy Version Information") { AppInfo.copySummary() }
                Divider()
                Button(updates.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                    updates.checkNow()
                }
                .disabled(updates.isChecking)
                Toggle("Check for Updates Daily", isOn: $updates.enabled)
            }
            CommandGroup(replacing: .newItem) {
                // While marking up, actions that put the screenshot away are off.
                Button("New Screenshot") { store.captureToMemory() }
                    .keyboardShortcut("n")
                    .disabled(store.isCapturing || store.isMarkingUp)
                Button("Save Selection") { store.saveMemory(Array(store.memorySelection)) }
                    .keyboardShortcut("s")
                    .disabled(store.memorySelection.isEmpty || store.isMarkingUp)
                Button("Save All from Memory") { store.saveMemory(store.memoryShots.map(\.id)) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.memoryShots.isEmpty || store.isMarkingUp)
                Divider()
                Button("Mark Up…") { store.markUpSelection() }
                    .keyboardShortcut("e")
                    .disabled(!store.canMarkUpSelection)
            }
            CommandMenu("Hot Spaces") {
                ForEach(Array(store.hotSpaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button("Send to \(space.name)") { store.deliverSelection(to: space) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .disabled(!store.hasSelection || store.isMarkingUp)
                }
                Divider()
                Button("Add Hot Space…") { store.addHotSpace() }
                // No shortcut here: Escape is handled in Store, so the search field keeps it.
                Button("Clear Selection (Esc)") {
                    store.selection = []
                    store.memorySelection = []
                }
                .disabled(!store.hasSelection)
            }
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updates: UpdateChecker
    @LocalState private var search = ""
    @LocalState private var anchor: URL?
    @LocalState private var memoryAnchor: UUID?

    private var filtered: [Shot] {
        guard !search.isEmpty else { return currentFiles }
        return currentFiles.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    /// The files of the open tab: the screenshot folder or a Hot Space.
    private var currentFiles: [Shot] {
        store.tab == .stored ? store.shots : store.spaceShots
    }

    var body: some View {
        Group {
            if let session = store.markup {
                MarkupView(session: session)
            } else {
                HStack(spacing: 0) {
                    HotSpacesPanel()
                        .frame(width: 270)
                    Divider()
                    VStack(spacing: 0) {
                        updateBanner
                        tabBar
                        Divider()
                        switch store.tab {
                        case .memory:
                            memoryHeader
                            Divider()
                            memoryGallery
                        case .stored:
                            storedHeader
                            Divider()
                            fileGallery
                        case .space:
                            if let space = store.viewedSpace {
                                spaceHeader(space)
                                Divider()
                                fileGallery
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.spring(response: 0.3), value: store.toast)
    }

    /// Banner about a new version, or the first-time explanation of the daily check.
    @ViewBuilder
    private var updateBanner: some View {
        if let version = updates.available {
            banner(icon: "arrow.down.circle.fill",
                   text: "Screenshot Hub \(version) is available. You have \(AppInfo.version).") {
                Button("View Release") { NSWorkspace.shared.open(UpdateChecker.releaseURL(for: version)) }
                    .buttonStyle(.borderedProminent)
                Button("Not Now") { updates.dismiss() }
            }
        } else if updates.enabled && !updates.disclosureShown {
            banner(icon: "network",
                   text: "Screenshot Hub checks GitHub once a day for a new version. "
                       + "Only a request goes to GitHub, which sees your IP address.") {
                Button("OK") { updates.disclosureShown = true }
                Button("Turn Off") {
                    updates.enabled = false
                    updates.disclosureShown = true
                }
            }
        }
    }

    private func banner<Buttons: View>(icon: String, text: String,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                buttons()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        }
    }

    private var tabBar: some View {
        Picker("View", selection: $store.tab) {
            Text(store.memoryShots.isEmpty ? "In Memory" : "In Memory (\(store.memoryShots.count))")
                .tag(Store.Tab.memory)
            Text("Saved (\(store.shots.count))")
                .tag(Store.Tab.stored)
            // An opened Hot Space gets its own tab, which disappears again when you switch back.
            if let space = store.viewedSpace {
                Text("\(space.name) (\(store.spaceShots.count))")
                    .tag(Store.Tab.space(space.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: In memory

    private var memorySummary: String {
        let count = store.memoryShots.count
        guard count > 0 else { return "Not saved" }
        let bytes = store.memoryShots.reduce(0) { $0 + $1.png.count }
        return "Not saved · "
            + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private var memoryHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip").foregroundStyle(.orange)
            Text(memorySummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Toggle("Clipboard Capture", isOn: $store.watchClipboard)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Images that land on the clipboard, such as a screenshot taken with ⌃⌘⇧4, appear here. "
                      + "Content that an app marks as concealed or transient, such as from a password manager, is skipped.")
            Button("Save All") { store.saveMemory(store.memoryShots.map(\.id)) }
                .disabled(store.memoryShots.isEmpty)
                .help("Save all to \(store.sourceFolder.lastPathComponent) (⌘⇧S)")
            Button { store.captureToMemory() } label: {
                Label("Take Screenshot", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isCapturing)
            .help("Choose an area, or press Space for a window. It is kept in memory only (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var memoryGallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                ForEach(store.memoryShots) { shot in
                    MemoryCard(shot: shot, selected: store.memorySelection.contains(shot.id))
                        .onDrag { memoryItemProvider(for: shot) }
                        .onTapGesture {
                            if NSApp.currentEvent?.clickCount == 2 {
                                store.markUp(memory: shot.id)
                            } else {
                                handleMemoryTap(shot)
                            }
                        }
                        .contextMenu { memoryMenu(shot) }
                }
            }
            .padding(16)
        }
        .overlay {
            if store.memoryShots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("Nothing in memory yet")
                        .font(.headline)
                    Text(store.watchClipboard
                         ? "Click Take Screenshot (⌘N) or take one with ⌃⌘⇧4. It appears here and isn’t saved yet."
                         : "Click Take Screenshot (⌘N). Turn on Clipboard Capture to also get screenshots taken with ⌃⌘⇧4 here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private func memoryMenu(_ shot: MemoryShot) -> some View {
        let targets = store.memorySelection.contains(shot.id) ? Array(store.memorySelection) : [shot.id]
        Button("Mark Up…") { store.markUp(memory: shot.id) }
        Divider()
        Button("Save to \(store.sourceFolder.lastPathComponent)") { store.saveMemory(targets) }
        if !store.hotSpaces.isEmpty {
            Menu("Save to Hot Space") {
                ForEach(store.hotSpaces) { space in
                    Button(space.name) { store.deliver([], memory: targets, to: space) }
                }
            }
        }
        Button("Copy Image") { store.copyToClipboard(shot) }
        Divider()
        Button("Discard") { store.discardMemory(targets) }
    }

    private func handleMemoryTap(_ shot: MemoryShot) {
        applyClick(on: shot.id, order: store.memoryShots.map(\.id),
                   selection: &store.memorySelection, anchor: &memoryAnchor)
    }

    // MARK: Saved

    private var storedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if store.hasSourceAccess {
                Text(displayPath(store.sourceFolder.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Change…") { store.chooseSourceFolder() }
                    .buttonStyle(.link)
            } else {
                Text("No screenshot folder chosen yet")
                    .foregroundStyle(.secondary)
                Button("Choose Folder…") { store.chooseSourceFolder() }
                    .buttonStyle(.link)
            }
            Spacer()
            TextField("Search by name", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Toggle("Only Screenshots", isOn: $store.onlyScreenshots)
                .toggleStyle(.switch)
                .controlSize(.small)
            Text("\(filtered.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func spaceHeader(_ space: HotSpace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(palette[space.colorIndex % palette.count])
            Text(displayPath(space.path))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("Show in Finder") { NSWorkspace.shared.open(space.url) }
                .buttonStyle(.link)
            Spacer()
            TextField("Search by name", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Text("\(filtered.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { store.tab = .stored } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close \(space.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var fileGallery: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                ForEach(filtered) { shot in
                    ShotCard(shot: shot, selected: store.selection.contains(shot.url))
                        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
                        // One tap gesture, so a single click doesn't wait for a possible double-click.
                        .onTapGesture {
                            if NSApp.currentEvent?.clickCount == 2 {
                                NSWorkspace.shared.open(shot.url)
                            } else {
                                handleTap(shot)
                            }
                        }
                        .contextMenu { shotMenu(shot) }
                }
            }
            .padding(16)
        }
        .overlay {
            if store.tab == .stored && !store.hasSourceAccess {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Choose your screenshot folder first")
                        .font(.headline)
                    Text("Screenshot Hub can only access folders you choose yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose Folder…") { store.chooseSourceFolder() }
                        .padding(.top, 4)
                }
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "No screenshots in this folder yet" : "No screenshots with this name")
                        .font(.headline)
                    Text(!search.isEmpty ? "Try a different search."
                         : store.tab == .stored ? "Take one with ⌘⇧4 or ⌘⇧5, or save one from In Memory."
                         : "Drop screenshots on this Hot Space to save them here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func shotMenu(_ shot: Shot) -> some View {
        let targets = store.selection.contains(shot.url) ? Array(store.selection) : [shot.url]
        Button("Open") { NSWorkspace.shared.open(shot.url) }
        Button("Mark Up…") { store.markUp(file: shot.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button("Copy Image") { store.copyToClipboard(shot.url) }
        if !store.hotSpaces.isEmpty {
            Menu("Send to Hot Space") {
                // The Hot Space the screenshot is already in makes no sense as a target.
                ForEach(store.hotSpaces.filter { $0.id != store.viewedSpace?.id }) { space in
                    Button(space.name) { store.deliver(targets, to: space) }
                }
            }
        }
        Divider()
        Button("Move to Trash") { store.trash(targets) }
    }

    private func handleTap(_ shot: Shot) {
        applyClick(on: shot.url, order: filtered.map(\.url),
                   selection: &store.selection, anchor: &anchor)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            HStack(spacing: 12) {
                Text(toast.text)
                if toast.canUndo {
                    Button("Undo") { store.undoLast() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Screenshot cards

struct MemoryCard: View {
    @EnvironmentObject var store: Store
    let shot: MemoryShot
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: shot.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not saved")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    // verbatim: otherwise SwiftUI may format 1600 as "1.600" in some locales.
                    Text(verbatim: "\(shot.date.formatted(date: .omitted, time: .standard)) · \(shot.pixelWidth)×\(shot.pixelHeight)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button("Save") { store.saveMemory([shot.id]) }
                    .controlSize(.small)
                    .help("Save to \(store.sourceFolder.lastPathComponent)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        // Dashed orange border: this only exists in memory so far.
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : Color.orange.opacity(0.5),
                          style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 3])))
        .contentShape(Rectangle())
        .help("Double-click to mark up")
    }
}

struct ShotCard: View {
    let shot: Shot
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(url: shot.url, modified: shot.modified)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(shot.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(shot.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2),
                          lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct ThumbnailView: View {
    let url: URL
    let modified: Date
    @LocalState private var image: NSImage?

    private var cacheKey: NSString { ThumbCache.key(url, modified) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: cacheKey) {
            let key = cacheKey
            if let cached = ThumbCache.shared.object(forKey: key) {
                image = cached
                return
            }
            let target = url
            let cg = await Task.detached(priority: .utility) { makeThumbnail(target) }.value
            if let cg {
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                ThumbCache.shared.setObject(ns, forKey: key)
                image = ns
            }
        }
    }
}

// MARK: - Markup screen

struct MarkupView: View {
    @EnvironmentObject var store: Store
    @Environment(\.undoManager) private var undoManager
    let session: MarkupSession
    @StateObject private var model = MarkupModel()
    @LocalState private var tool = Mark.Tool.pen
    @LocalState private var colorIndex = 0
    /// Multiple of the base width: thin, medium or thick.
    @LocalState private var thickness: CGFloat = 2
    @LocalState private var crosshair = false

    /// Base width in pixels, in proportion to the image: thicker on a large screenshot.
    private var unit: CGFloat {
        max(2, CGFloat(max(session.image.width, session.image.height)) / 500)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        .onAppear {
            // Undo only the marks, not what happened earlier in the window.
            undoManager?.removeAllActions()
            model.undoManager = undoManager
        }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: model)
            if crosshair { NSCursor.pop() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(Mark.Tool.allCases, id: \.self) { item in
                    Button { tool = item } label: {
                        Image(systemName: item.symbol)
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(tool == item ? Color.accentColor.opacity(0.25) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(item.key), modifiers: [])
                    .help("\(item.name) (\(item.key.uppercased()))")
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 4) {
                ForEach(markColors.indices, id: \.self) { index in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Color(nsColor: markColors[index].color))
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(colorIndex == index ? Color.accentColor : Color.clear,
                                                           lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(markColors[index].name)
                }
            }
            Picker("Thickness", selection: $thickness) {
                Text("Thin").tag(CGFloat(1))
                Text("Medium").tag(CGFloat(2))
                Text("Thick").tag(CGFloat(4))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!(undoManager?.canUndo ?? false))
                .help("Undo (⌘Z)")
            Button("Clear All") { model.set([]) }
                .disabled(model.marks.isEmpty)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Done") { store.finishMarkup(session, marks: model.marks) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.marks.isEmpty)
                .help(doneHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var doneHelp: String {
        if case .file = session.source {
            return "A marked-up copy goes into memory; the file stays as it is (↩)"
        }
        return "Put the marks into the screenshot (↩)"
    }

    private var canvas: some View {
        GeometryReader { geo in
            let image = session.image
            let size = CGSize(width: image.width, height: image.height)
            // Fits the window, but never larger than one point per pixel.
            let scale = min(geo.size.width / size.width, geo.size.height / size.height, 1)
            Canvas { context, _ in
                context.draw(Image(decorative: image, scale: 1),
                             in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                context.scaleBy(x: scale, y: scale)
                for mark in model.marks + [model.current].compactMap({ $0 }) {
                    context.stroke(mark.path, with: .color(Color(nsColor: mark.strokeColor)),
                                   style: StrokeStyle(lineWidth: mark.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width * scale, height: size.height * scale)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    drag(to: CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                }
                .onEnded { _ in
                    guard let mark = model.current else { return }
                    model.current = nil
                    model.set(model.marks + [mark])
                })
            .onHover { inside in
                guard inside != crosshair else { return }
                crosshair = inside
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
    }

    private func drag(to point: CGPoint) {
        guard var mark = model.current else {
            model.current = Mark(tool: tool, points: [point], color: markColors[colorIndex].color,
                                 width: unit * thickness)
            return
        }
        switch mark.tool {
        case .pen, .highlighter: mark.points.append(point)
        case .arrow, .rectangle, .ellipse: mark.points = [mark.points[0], point]
        }
        model.current = mark
    }

    private func cancel() {
        if !model.marks.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard your marks?"
            alert.informativeText = "The screenshot stays as it was."
            alert.addButton(withTitle: "Discard").hasDestructiveAction = true
            alert.addButton(withTitle: "Keep Marking Up").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.cancelMarkup()
    }
}

// MARK: - Hot Spaces

struct HotSpacesPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hot Spaces").font(.title3.weight(.semibold))
                Spacer()
                Button { store.addHotSpace() } label: { Image(systemName: "plus") }
                    .help("Add a folder as Hot Space")
            }

            if store.hotSpaces.isEmpty {
                Text("Add a folder with +. Then drop a screenshot on a Hot Space to save it there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(store.hotSpaces.enumerated()), id: \.element.id) { index, space in
                        HotSpaceTile(space: space, index: index)
                    }
                }
                .padding(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Saved screenshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Saved screenshots", selection: $store.moveFiles) {
                    Text("Move").tag(true)
                    Text("Copy").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Select screenshots and press ⌘1–⌘9, or click a Hot Space. Screenshots in memory are saved there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05))
    }
}

struct HotSpaceTile: View {
    @EnvironmentObject var store: Store
    let space: HotSpace
    let index: Int
    @LocalState private var targeted = false

    var body: some View {
        let color = palette[space.colorIndex % palette.count]
        let viewed = store.viewedSpace?.id == space.id
        // Tile and eye are two buttons side by side, not nested: that way the tile can
        // never catch the click on the eye and send the selection here.
        HStack(spacing: 10) {
            Button(action: tileClicked) {
                HStack(spacing: 10) {
                    Image(systemName: targeted ? "tray.and.arrow.down.fill" : "folder.fill")
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(displayPath(space.path))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.hasSelection
                  ? "Click to send the selection to \(space.name)"
                  : "Click to see what’s in \(space.name), or drop screenshots here")

            Button { store.openSpace(space) } label: {
                Image(systemName: viewed ? "eye.fill" : "eye")
                    .foregroundStyle(viewed ? color : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See what’s in \(space.name)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(color.opacity(targeted ? 0.25 : viewed ? 0.18 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(color.opacity(targeted || viewed ? 1 : 0.35),
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                             dash: targeted || viewed ? [] : [5, 3])))
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: targeted)
        .onDrop(of: [UTType.memoryShot, UTType.fileURL], isTargeted: $targeted) { providers in
            loadDrop(from: providers) { urls, ids in store.dropped(urls, memory: ids, on: space) }
            return true
        }
        .contextMenu {
            Button("View") { store.openSpace(space) }
            Button("Show in Finder") { NSWorkspace.shared.open(space.url) }
            Button("Remove Hot Space") { store.removeHotSpace(space) }
        }
    }

    /// With a selection, a click sends it here; without one, it opens the Hot Space.
    private func tileClicked() {
        if store.hasSelection {
            store.deliverSelection(to: space)
        } else {
            store.openSpace(space)
        }
    }
}
