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
import CoreImage
import AVFoundation
import ScreenCaptureKit
import Security

// MARK: - Model

struct Shot: Identifiable, Hashable {
    let url: URL
    let date: Date
    let modified: Date
    var id: URL { url }
    var isVideo: Bool { Store.videoExtensions.contains(url.pathExtension.lowercased()) }
}

/// A screenshot or screen recording that only exists in memory and is not a file yet.
struct MemoryShot: Identifiable, Equatable {
    enum Kind { case image, video }

    let id = UUID()
    let kind: Kind
    /// PNG for an image, a QuickTime movie for a recording.
    let data: Data
    let date: Date
    let thumbnail: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    /// Length of a recording in seconds; zero for an image.
    let duration: TimeInterval

    var isVideo: Bool { kind == .video }
    var fileName: String { Store.fileName(for: date, video: isVideo) }
    var type: UTType { isVideo ? .quickTimeMovie : .png }

    init?(png: Data, date: Date = Date()) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let thumb = makeThumbnail(source) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        self.kind = .image
        self.data = png
        self.date = date
        self.thumbnail = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
        self.pixelWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? thumb.width
        self.pixelHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? thumb.height
        self.duration = 0
    }

    init(video: Data, info: VideoInfo, date: Date = Date()) {
        self.kind = .video
        self.data = video
        self.date = date
        self.thumbnail = NSImage(cgImage: info.thumbnail,
                                 size: NSSize(width: info.thumbnail.width, height: info.thumbnail.height))
        self.pixelWidth = Int(info.size.width)
        self.pixelHeight = Int(info.size.height)
        self.duration = info.duration
    }

    /// Reads what screencapture wrote: an image, or a recording. Nil if it is neither.
    static func load(from url: URL) async -> MemoryShot? {
        if Store.isImageFile(url) {
            return (try? Data(contentsOf: url)).flatMap { MemoryShot(png: $0) }
        }
        guard Store.isVideoFile(url), let info = await VideoInfo.load(url),
              let data = try? Data(contentsOf: url) else { return nil }
        return MemoryShot(video: data, info: info)
    }

    static func == (a: MemoryShot, b: MemoryShot) -> Bool { a.id == b.id }
}

/// Thumbnail, size and length of a recording.
struct VideoInfo {
    let thumbnail: CGImage
    let size: CGSize
    let duration: TimeInterval

    static func load(_ url: URL, maxPixel: CGFloat = 480) async -> VideoInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return VideoInfo(thumbnail: image, size: size, duration: duration.seconds)
    }

    /// "0:07", "1:23".
    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
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
    /// Files overwritten by marking up, with their contents from before.
    var overwritten: [(file: URL, original: Data)] = []
    var targetName = ""
    var isEmpty: Bool {
        files.isEmpty && stored.isEmpty && discarded.isEmpty && replaced.isEmpty && overwritten.isEmpty
    }
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
    /// A screenshot is being taken.
    @Published var isCapturing = false
    /// A recording is being set up or running. Screenshots stay possible in the meantime.
    @Published var isRecording = false
    /// When the running recording started, for the Stop button and its timer.
    @Published var recordingSince: Date?
    @Published var toast: Toast?
    /// The screenshot being marked up; the markup screen then fills the window.
    @Published var markup: MarkupSession?
    var isMarkingUp: Bool { markup != nil }

    /// A Hot Space opens as its own tab, at its folder or at one of its subfolders.
    enum Tab: Hashable { case memory, stored, space(UUID, subfolder: URL?) }
    /// Always starts on memory. Switching clears the selection, so ⌘1–⌘9 never
    /// send something you cannot see.
    @Published var tab: Tab = .memory {
        didSet {
            guard tab != oldValue else { return }
            selection = []
            memorySelection = []
            spaceWatcher?.cancel()
            spaceWatcher = viewedFolder.flatMap { watch($0) }
            reload()
        }
    }
    /// The contents of the Hot Space that is open as a tab.
    @Published var spaceShots: [Shot] = []
    var viewedSpace: HotSpace? {
        guard case .space(let id, _) = tab else { return nil }
        return hotSpaces.first { $0.id == id }
    }
    /// The folder of the open Hot Space tab: the Hot Space itself or one of its subfolders.
    var viewedFolder: URL? {
        guard case .space(_, let subfolder) = tab, let space = viewedSpace else { return nil }
        return subfolder ?? space.url
    }
    var viewedName: String? {
        guard case .space(_, let subfolder) = tab else { return nil }
        return subfolder?.lastPathComponent ?? viewedSpace?.name
    }
    /// Folders expanded in the sidebar, by path.
    @Published var expandedFolders: Set<String> = []
    /// Subfolders per folder path. Emptied on reload and when the app becomes active,
    /// so folders made in Finder show up when you come back.
    private var subfolderCache: [String: [URL]] = [:]
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
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
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
            self.subfolderCache = [:]
            self.objectWillChange.send()
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

    /// A QuickTime or MPEG-4 movie: the right extension, and a known box ("ftyp", "moov", …)
    /// at the start of the file.
    static func isVideoFile(_ url: URL) -> Bool {
        guard videoExtensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        guard head.count == 8 else { return false }
        let box = String(decoding: head.suffix(4), as: UTF8.self)
        return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(box)
    }

    static func isMediaFile(_ url: URL) -> Bool { isImageFile(url) || isVideoFile(url) }

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
        return ["screenshot", "schermafbeelding", "bildschirmfoto", "capture d",
                "screen recording", "schermopname", "bildschirmaufnahme", "enregistrement de l"]
            .contains { name.hasPrefix($0) }
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

    /// The same names macOS uses: "Screenshot 2026-10-16 at 15.41.22.png" and
    /// "Screen Recording 2026-10-16 at 15.41.22.mov".
    static func fileName(for date: Date, video: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        return video ? "Screen Recording \(stamp).mov" : "Screenshot \(stamp).png"
    }

    // MARK: Reading and watching

    func reload() {
        shots = Store.listShots(in: sourceFolder, onlyScreenshots: onlyScreenshots)
        // A Hot Space holds whatever you put there yourself, so no screenshot filter there.
        spaceShots = viewedFolder.map { Store.listShots(in: $0, onlyScreenshots: false) } ?? []
        subfolderCache = [:]
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
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) || videoExtensions.contains(ext),
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

    /// Opens the Hot Space, or one of its subfolders, as a tab, so you can see what is in it.
    func openSpace(_ space: HotSpace, subfolder: URL? = nil) {
        let space = refreshLocation(of: space)
        if let reason = unavailableReason(space, subfolder: subfolder) {
            showToast(reason)
            return
        }
        tab = .space(space.id, subfolder: subfolder)
    }

    /// Folders directly inside a folder, sorted like Finder. Hidden folders and packages,
    /// such as apps, are left out.
    func subfolders(of folder: URL) -> [URL] {
        if let cached = subfolderCache[folder.path] { return cached }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let folders = items
            .filter { url in
                let values = try? url.resourceValues(forKeys: keys)
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        subfolderCache[folder.path] = folders
        return folders
    }

    /// Whether this folder is the one open as a tab.
    func isViewed(_ folder: URL) -> Bool {
        viewedFolder?.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    func toggleExpanded(_ folder: URL) {
        if expandedFolders.remove(folder.path) == nil { expandedFolders.insert(folder.path) }
    }

    // MARK: Memory

    /// Where a new screenshot or recording goes: memory, or straight into the folder that is open.
    private enum CaptureTarget { case memory, screenshotFolder, space(HotSpace, subfolder: URL?) }

    private var captureTarget: CaptureTarget {
        switch tab {
        case .memory: return .memory
        case .stored: return hasSourceAccess ? .screenshotFolder : .memory
        case .space(_, let subfolder): return viewedSpace.map { .space($0, subfolder: subfolder) } ?? .memory
        }
    }

    /// The folder a new capture goes straight into, or nil when it goes into memory.
    var captureFolderName: String? {
        switch captureTarget {
        case .memory: return nil
        case .screenshotFolder: return sourceFolder.lastPathComponent
        case .space(let space, let subfolder): return subfolder?.lastPathComponent ?? space.name
        }
    }

    /// Lets you pick an area or window (like ⌘⇧4), or records the screen or an area until you
    /// click Stop (without sound). The result goes into memory, or straight into the folder that
    /// is open.
    func capture(video: Bool = false) {
        if video {
            toggleRecording()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        let target = captureTarget
        // screencapture cannot write straight into this app's memory. The temporary file
        // lives in the sandbox container's temporary folder, is readable by the owner only
        // (umask) and is read and deleted right away.
        let temp = captureFile(extension: "png")
        NSApp.hide(nil)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", temp.path]
            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                failure = "macOS couldn’t start the screen capture"
            }
            self?.finishCapture(temp, target: target, failure: failure, screenshot: true)
        }
    }

    /// Starts a recording, or stops the one that is running.
    func toggleRecording() {
        if isRecording {
            ScreenRecorder.shared.stop()
            return
        }
        guard ScreenRecorder.hasPermission else {
            ScreenRecorder.askForPermission()
            return
        }
        isRecording = true
        let target = captureTarget
        let temp = captureFile(extension: "mov")
        ScreenRecorder.shared.record(to: temp, started: { [weak self] in
            self?.recordingSince = Date()
        }, completion: { [weak self] failure in
            self?.isRecording = false
            self?.recordingSince = nil
            self?.finishCapture(temp, target: target, failure: failure, screenshot: false)
        })
    }

    private func captureFile(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Store.capturePrefix)\(UUID().uuidString).\(ext)")
    }

    /// Reads what was captured, deletes the temporary file and puts the result in memory or in
    /// the folder. No file and no failure means the user cancelled.
    private func finishCapture(_ temp: URL, target: CaptureTarget, failure: String?, screenshot: Bool) {
        let written = FileManager.default.fileExists(atPath: temp.path)
        Task { @MainActor [weak self] in
            let shot = await MemoryShot.load(from: temp)
            try? FileManager.default.removeItem(at: temp)
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard let self else { return }
            if screenshot { self.isCapturing = false }
            if let shot {
                self.place(shot, in: target)
            } else if let failure {
                self.showToast("Couldn’t capture: \(failure)")
            } else if written {
                self.showToast("Couldn’t capture: the result was not a readable image or recording")
            }
        }
    }

    private func place(_ shot: MemoryShot, in target: CaptureTarget) {
        switch target {
        case .memory:
            addToMemory(shot)
            return
        case .screenshotFolder:
            memoryShots.insert(shot, at: 0)
            saveMemory([shot.id])
        case .space(let space, let subfolder):
            memoryShots.insert(shot, at: 0)
            deliver([], memory: [shot.id], to: space, subfolder: subfolder)
        }
        // Saving failed (the toast says why): show it in memory, so nothing gets lost unseen.
        if memoryShots.contains(where: { $0.id == shot.id }) {
            tab = .memory
            memorySelection = [shot.id]
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
        guard let png, memoryShots.first?.data != png, let shot = MemoryShot(png: png) else { return }
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
        pasteboard.setData(shot.data, forType: .png)
        clipboardCount = pasteboard.changeCount
        showToast("Image copied")
    }

    // MARK: Markup

    /// Opens a screenshot from memory in the markup screen.
    func markUp(memory id: UUID) {
        guard let shot = memoryShots.first(where: { $0.id == id }), !shot.isVideo,
              let source = CGImageSourceCreateWithData(shot.data as CFData, nil),
              let session = MarkupSession(source: .memory(id), image: source) else {
            showToast("Couldn’t mark up: the image is not readable")
            return
        }
        markup = session
    }

    /// Opens a saved screenshot. Done overwrites the file; Undo brings back the original.
    func markUp(file url: URL) {
        guard Store.isImageFile(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let session = MarkupSession(source: .file(url), image: source) else {
            showToast("Couldn’t mark up: the file is not a readable image")
            return
        }
        markup = session
    }

    /// Exactly one image is selected; recordings cannot be marked up.
    var canMarkUpSelection: Bool {
        guard !isMarkingUp, memorySelection.count + selection.count == 1 else { return false }
        if let id = memorySelection.first {
            return memoryShots.first { $0.id == id }?.isVideo == false
        }
        return selection.first.map { !Store.videoExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    func markUpSelection() {
        guard canMarkUpSelection else { return }
        if let id = memorySelection.first {
            markUp(memory: id)
        } else if let url = selection.first {
            markUp(file: url)
        }
    }

    /// Draws the marks into the image. A screenshot from memory is replaced; a saved file is
    /// overwritten in its own format. Both with Undo, which keeps the original until it expires.
    func finishMarkup(_ session: MarkupSession, marks: [Mark]) {
        guard let rendered = renderMarkup(session, marks: marks) else {
            showToast("Couldn’t mark up: the image could not be created")
            return
        }
        if case .file(let url) = session.source {
            do {
                let original = try Data(contentsOf: url)
                try SafeFile.replace(url, with: rendered)
                lastUndo = UndoAction(overwritten: [(file: url, original: original)])
                showToast("Markup saved", canUndo: true)
            } catch {
                // The markup screen stays open, so the marks are not lost.
                showToast("Couldn’t save the markup: \(SafeFile.describe(error))")
                return
            }
            markup = nil
            reload()
            return
        }
        let png = rendered
        if case .memory(let id) = session.source,
           let index = memoryShots.firstIndex(where: { $0.id == id }) {
            let old = memoryShots[index]
            guard let new = MemoryShot(png: png, date: old.date) else { return }
            memoryShots[index] = new
            if memorySelection.remove(id) != nil { memorySelection.insert(new.id) }
            lastUndo = UndoAction(replaced: [(old: old, new: new.id)])
            showToast("Markup added", canUndo: true)
        } else {
            // A screenshot that has left memory in the meantime.
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

    func dropped(_ urls: [URL], memory ids: [UUID], on space: HotSpace, subfolder: URL? = nil) {
        // Dragging one screenshot out of a multiple selection takes the whole selection along.
        var files = urls
        var memory = ids
        if files.count == 1, selection.contains(files[0]), selection.count > 1 {
            files = Array(selection)
        }
        if memory.count == 1, memorySelection.contains(memory[0]), memorySelection.count > 1 {
            memory = Array(memorySelection)
        }
        deliver(files, memory: memory, to: space, subfolder: subfolder)
    }

    func deliverSelection(to space: HotSpace, subfolder: URL? = nil) {
        guard hasSelection else { return }
        deliver(Array(selection), memory: Array(memorySelection), to: space, subfolder: subfolder)
    }

    func deliver(_ urls: [URL], memory ids: [UUID] = [], to space: HotSpace, subfolder: URL? = nil) {
        let space = refreshLocation(of: space)
        if let reason = unavailableReason(space, subfolder: subfolder) {
            showToast(reason)
            return
        }
        deliver(files: urls, memory: ids, into: subfolder ?? space.url,
                name: subfolder?.lastPathComponent ?? space.name)
    }

    /// Saves screenshots from memory to the folder and moves or copies files into it.
    @discardableResult
    private func deliver(files urls: [URL], memory ids: [UUID], into folder: URL, name: String) -> Bool {
        let fm = FileManager.default
        // Images and recordings only; folders and other files dragged in from Finder are left alone.
        let images = urls.filter(Store.isMediaFile)
        let skipped = urls.count - images.count
        let wanted = Set(ids)
        let memory = memoryShots.filter { wanted.contains($0.id) }
        guard !images.isEmpty || !memory.isEmpty else {
            if skipped > 0 { showToast("Only images and recordings can go to a Hot Space") }
            return skipped == 0
        }

        var undo = UndoAction(moved: moveFiles, targetName: name)
        var failed = 0
        var failure: String?

        for shot in memory {
            let dest = uniqueDestination(for: shot.fileName, in: folder)
            do {
                try SafeFile.write(shot.data, to: dest) { temp in
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
            let what = undo.stored.count > 1 ? "\(undo.stored.count) screenshots"
                : undo.stored[0].shot.isVideo ? "Recording" : "Screenshot"
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
            parts.append(skipped == 1 ? "1 file skipped (not an image or recording)"
                                      : "\(skipped) files skipped (not images or recordings)")
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
        for item in last.overwritten {
            do {
                try SafeFile.replace(item.file, with: item.original)
            } catch {
                failed += 1
                failure = failure ?? SafeFile.describe(error)
            }
        }

        let total = last.files.count + last.stored.count + last.discarded.count + last.overwritten.count
        if failed > 0, let failure {
            showToast("Couldn’t undo \(failed) of \(total) screenshots: \(failure)")
        } else if !last.discarded.isEmpty || !last.stored.isEmpty {
            showToast("Back in memory")
        } else if !last.replaced.isEmpty || !last.overwritten.isEmpty {
            showToast(last.overwritten.isEmpty ? "Markup removed" : "Original restored")
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
        for url in panel.urls { addHotSpace(url) }
    }

    /// Adds a folder as a Hot Space, unless it already is one. A subfolder of a Hot Space can
    /// be added too: the app already has access to it through the Hot Space.
    func addHotSpace(_ url: URL) {
        guard !hotSpaces.contains(where: { $0.path == url.path }) else { return }
        let space = HotSpace(name: url.lastPathComponent,
                             path: url.path,
                             colorIndex: hotSpaces.count % palette.count,
                             bookmark: Store.makeBookmark(url))
        beginAccess(url, key: space.id.uuidString)
        hotSpaces.append(space)
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

    /// Why a Hot Space, or a subfolder of it, cannot be used right now, or nil if it can.
    private func unavailableReason(_ space: HotSpace, subfolder: URL? = nil) -> String? {
        if space.bookmark == nil || inaccessibleSpaces.contains(space.id) {
            return "No access to \(space.name) (anymore). Remove the Hot Space and add it again."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: space.path, isDirectory: &isDir), isDir.boolValue,
              !isInTrash(space.url) else {
            return "The folder of \(space.name) no longer exists. Remove the Hot Space or put the folder back."
        }
        if let subfolder {
            // Only folders inside the Hot Space: that is where the app has access.
            let inside = subfolder.standardizedFileURL.path.hasPrefix(space.url.standardizedFileURL.path + "/")
            guard inside, FileManager.default.fileExists(atPath: subfolder.path, isDirectory: &isDir),
                  isDir.boolValue else {
                return "The folder \(subfolder.lastPathComponent) no longer exists."
            }
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

    /// Overwrites a file in one step, for marking up a saved screenshot (the only place the app
    /// replaces a file). The new contents go to a temporary file in the same folder, which then
    /// swaps places with the original (renamex_np with RENAME_SWAP); the old contents are removed
    /// afterwards. The file keeps its permissions, creation date and screenshot marker.
    static func replace(_ dest: URL, with data: Data) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: dest.path)
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".ScreenshotHub-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            var keep: [FileAttributeKey: Any] = [.posixPermissions: attributes[.posixPermissions] ?? permissions]
            keep[.creationDate] = attributes[.creationDate]
            try fm.setAttributes(keep, ofItemAtPath: temp.path)
            if Store.isScreenshot(dest) { Store.markAsScreenshot(temp) }
            let result = temp.withUnsafeFileSystemRepresentation { from in
                dest.withUnsafeFileSystemRepresentation { to in
                    renamex_np(from!, to!, UInt32(RENAME_SWAP))
                }
            }
            if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        // After the swap, the temporary file holds the old contents.
        try? fm.removeItem(at: temp)
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
    provider.suggestedName = shot.fileName
    let id = Data(shot.id.uuidString.utf8)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.memoryShot.identifier, visibility: .all) { done in
        done(id, nil)
        return nil
    }
    let data = shot.data
    provider.registerDataRepresentation(forTypeIdentifier: shot.type.identifier, visibility: .all) { done in
        done(data, nil)
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
        case pen, highlighter, arrow, rectangle, ellipse, blur

        var name: String {
            switch self {
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Oval"
            case .blur: return "Blur"
            }
        }

        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .blur: return "eye.slash"
            }
        }

        /// Blur covers an area; color and thickness do not apply to it.
        var usesColor: Bool { self != .blur }

        /// Shortcut without ⌘ in the markup screen.
        var key: Character {
            switch self {
            case .pen: return "p"
            case .highlighter: return "h"
            case .arrow: return "a"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .blur: return "b"
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
        case .rectangle, .blur:
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
    /// What the blur tool shows: the whole image, pixelated and blurred. Nil if Core Image failed;
    /// blurred areas are then filled with gray.
    let obscured: CGImage?
    /// Resolution of the original (144 on Retina), so the result opens at the same size.
    let dpi: (width: Double, height: Double)?
    /// The original's format (a UTType identifier), so an overwritten JPEG stays a JPEG.
    let type: String

    init?(source: Source, image imageSource: CGImageSource) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              // Full size, rotated upright according to the metadata.
              let image = makeThumbnail(imageSource, maxPixel: max(width, height)) else { return nil }
        self.source = source
        self.image = image
        type = CGImageSourceGetType(imageSource) as String? ?? UTType.png.identifier
        obscured = MarkupSession.obscure(image)
        if let x = props[kCGImagePropertyDPIWidth] as? Double, let y = props[kCGImagePropertyDPIHeight] as? Double {
            dpi = (x, y)
        } else {
            dpi = nil
        }
    }

    /// Pixelates in blocks about the height of a line of text and then blurs, so text underneath
    /// cannot be read back. A plain blur can sometimes be reversed; this cannot.
    static func obscure(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let block = max(16, CGFloat(max(image.width, image.height)) / 60)
        guard let pixelated = CIFilter(name: "CIPixellate", parameters: [
                  kCIInputImageKey: input.clampedToExtent(),
                  kCIInputScaleKey: block,
                  kCIInputCenterKey: CIVector(x: 0, y: 0),
              ])?.outputImage,
              let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                  kCIInputImageKey: pixelated,
                  kCIInputRadiusKey: block / 2,
              ])?.outputImage else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext().createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space)
    }
}

/// Draws the marks into the image and returns it in the original's format (PNG if that format
/// cannot be written). Everything happens in memory.
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
        if mark.tool == .blur {
            context.saveGState()
            context.addPath(mark.path.cgPath)
            context.clip()
            if let obscured = session.obscured {
                // Back to Core Graphics coordinates, otherwise the image is drawn upside down.
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(obscured, in: bounds)
            } else {
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(bounds)
            }
            context.restoreGState()
            continue
        }
        context.addPath(mark.path.cgPath)
        context.setStrokeColor(mark.strokeColor.cgColor)
        context.setLineWidth(mark.lineWidth)
        context.strokePath()
    }
    guard let result = context.makeImage() else { return nil }
    let data = NSMutableData()
    let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    let type = writable.contains(session.type) ? session.type : UTType.png.identifier
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
    else { return nil }
    // Only applies to lossy formats such as JPEG and HEIC.
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
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

// MARK: - Screen recording

/// Records the screen or an area with ScreenCaptureKit, in the app itself. `screencapture -v`
/// doesn't work from a sandboxed app (it needs to write to a folder of its own first), and the
/// macOS recording bar (⌘⇧5) cannot be started with a file to record to. So the area selection,
/// the Stop button and the recording are the app's own. Recording needs the Screen Recording
/// permission; a screenshot by selection (`screencapture -i`) does not.
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    private var overlay: NSWindow?
    private var controls: NSPanel?
    private var recorder: MovieRecorder?
    private var hidden: [NSWindow] = []
    private var started: (() -> Void)?
    private var completion: ((String?) -> Void)?
    private var stopping = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The first time, macOS asks itself. After that, it no longer asks: explain where to turn it on.
    static func askForPermission() {
        let key = "screenRecordingRequested"
        guard UserDefaults.standard.bool(forKey: key) else {
            UserDefaults.standard.set(true, forKey: key)
            CGRequestScreenCaptureAccess()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow Screenshot Hub to record the screen"
        alert.informativeText = "Recording needs the Screen Recording permission. Turn on Screenshot Hub under "
            + "System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen "
            + "Screenshot Hub. Taking screenshots doesn’t need this permission."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(url)
    }

    /// Lets you drag an area (or click for the whole screen), records it into `file` until Stop,
    /// and then calls back with a failure message, or nil when it is done or cancelled.
    func record(to file: URL, started: @escaping () -> Void, completion: @escaping (String?) -> Void) {
        self.started = started
        self.completion = completion
        // The app's own windows step aside, so they are neither in the way nor in the recording.
        hidden = NSApp.windows.filter(\.isVisible)
        hidden.forEach { $0.orderOut(nil) }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SelectionOverlay(
            done: { [weak self] area in self?.start(area, on: screen, file: file) },
            cancel: { [weak self] in self?.finish(nil) }))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlay = window
    }

    /// A borderless window that can still take Escape.
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// The selection in the screen's own coordinates (from its top left), or nil for the whole screen.
    private func start(_ area: CGRect?, on screen: NSScreen, file: URL) {
        overlay?.orderOut(nil)
        overlay = nil
        let local = area ?? CGRect(origin: .zero, size: screen.frame.size)
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == number }) else {
                    finish("the screen could not be found")
                    return
                }
                // The app's own windows, such as the Stop bar, stay out of the recording.
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                // In pixels; the video encoder wants even sizes.
                let scale = screen.backingScaleFactor
                let width = max(2, Int(local.width * scale) / 2 * 2)
                let height = max(2, Int(local.height * scale) / 2 * 2)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = local
                configuration.width = width
                configuration.height = height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.queueDepth = 6
                let recorder = try MovieRecorder(file: file, width: width, height: height)
                // The recorder is let go when it stops, which ends this reference too.
                recorder.failed = { self.stop(failure: "the recording stopped unexpectedly") }
                try await recorder.start(filter: filter, configuration: configuration)
                self.recorder = recorder
                showControls(around: local, on: screen)
                // Out of the way like during a screenshot; the Stop bar stays. Clicking the app in
                // the Dock brings the window back, with Stop in it too.
                hidden.forEach { $0.orderFront(nil) }
                hidden = []
                NSApp.hide(nil)
                started?()
            } catch {
                finish(ScreenRecorder.describe(error))
            }
        }
    }

    /// Stops recording and finishes the movie. A recording that stopped by itself is kept too.
    func stop(failure: String? = nil) {
        guard let recorder, !stopping else { return }
        stopping = true
        controls?.orderOut(nil)
        controls = nil
        Task { @MainActor in
            let written = await recorder.stop()
            self.recorder = nil
            stopping = false
            finish(written ? nil : failure ?? "nothing was recorded")
        }
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue {
            return "the Screen Recording permission is off. Turn it on under Privacy & Security in System Settings"
        }
        return "macOS couldn’t start the recording"
    }

    private func finish(_ failure: String?) {
        overlay?.orderOut(nil)
        overlay = nil
        hidden.forEach { $0.orderFront(nil) }
        hidden = []
        let completion = self.completion
        self.completion = nil
        started = nil
        completion?(failure)
    }

    /// Below the area if there is room, otherwise above it, otherwise inside at the top.
    private func showControls(around area: CGRect, on screen: NSScreen) {
        let size = CGSize(width: 200, height: 44)
        let frame = screen.frame
        let visible = screen.visibleFrame
        let bottom = frame.maxY - area.maxY
        let top = frame.maxY - area.minY
        var origin = CGPoint(x: frame.minX + area.midX - size.width / 2, y: bottom - size.height - 12)
        if origin.y < visible.minY { origin.y = top + 12 }
        if origin.y + size.height > visible.maxY { origin.y = min(top, visible.maxY) - size.height - 12 }
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        // A panel normally hides when you click another app, and with the app; this one must stay.
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // Keep the controls out of the recording, also when they sit inside the area.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingControls(started: Date()) { [weak self] in self?.stop() })
        panel.orderFrontRegardless()
        controls = panel
    }
}

/// Writes the frames of a ScreenCaptureKit stream to a QuickTime movie (H.264, no sound).
final class MovieRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main queue when the stream stops by itself, for example when the screen goes away.
    var failed: (() -> Void)?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?
    /// Frames arrive and are written on this queue.
    private let queue = DispatchQueue(label: "local.screenshothub.recording")
    private var sessionStarted = false

    init(file: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only frames with new content; the stream also reports idle and blank frames.
        guard type == .screen,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete else { return }
        append(sampleBuffer)
    }

    /// Adds one frame; the first one starts the movie's timeline. Runs on `queue`.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.failed?() }
    }

    /// Stops capturing and finishes the file. Returns whether a movie was written.
    func stop() async -> Bool {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await finish()
    }

    /// Finishes the file after the last frame on `queue`. Separate from stop, for tests without a stream.
    func finish() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        guard sessionStarted, writer.status == .writing else {
            writer.cancelWriting()
            return false
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}

/// Dims the screen; drag to choose an area, click to record the whole screen, Escape to cancel.
struct SelectionOverlay: View {
    let done: (CGRect?) -> Void
    let cancel: () -> Void
    @LocalState private var start: CGPoint?
    @LocalState private var current: CGPoint?

    private var area: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                var dim = Path(CGRect(origin: .zero, size: size))
                if let area { dim.addRect(area) }
                context.fill(dim, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                if let area {
                    context.stroke(Path(area), with: .color(.white), lineWidth: 1.5)
                }
            }
            if let area, area.width > 60, area.height > 24 {
                Text(verbatim: "\(Int(area.width)) × \(Int(area.height))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .position(x: area.maxX - 40, y: area.maxY + 16)
            }
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                Text("Drag to select an area, or click to record the whole screen")
                    .font(.system(size: 13, weight: .medium))
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.top, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if start == nil { start = value.startLocation }
                current = value.location
            }
            .onEnded { _ in
                let chosen = area
                start = nil
                current = nil
                // A click (or a tiny drag) records the whole screen.
                done(chosen.flatMap { $0.width >= 8 && $0.height >= 8 ? $0 : nil })
            })
        .onAppear { NSCursor.crosshair.push() }
        .onDisappear { NSCursor.pop() }
    }
}

/// The floating bar while recording: elapsed time and Stop.
struct RecordingControls: View {
    let started: Date
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(verbatim: VideoInfo.format(context.date.timeIntervalSince(started).rounded(.down)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording (⌘⇧N)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: 200, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
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
        .windowStyle(.hiddenTitleBar)
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
                Button("New Screenshot") { store.capture() }
                    .keyboardShortcut("n")
                    .disabled(store.isCapturing || store.isMarkingUp)
                Button(store.isRecording ? "Stop Recording" : "New Screen Recording") { store.toggleRecording() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.isMarkingUp && !store.isRecording)
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

// MARK: - Look and feel

/// Shared sizes and colors, so the main window and the markup screen look the same.
enum Theme {
    static let barHeight: CGFloat = 52
    static let footerHeight: CGFloat = 28
    static let sidebarWidth: CGFloat = 250
    static let cardCorner: CGFloat = 12
    static let corner: CGFloat = 7
    /// Room for the window buttons, which sit on top of the content.
    static let windowButtonsWidth: CGFloat = 96
    static let hairline = Color.primary.opacity(0.1)
    static let well = Color.primary.opacity(0.05)
    static let hover = Color.primary.opacity(0.07)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let unsaved = Color.orange
}

/// Native translucent background, such as the sidebar material.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// A transparent title bar with the window buttons centered in the bars at the top. The empty
/// toolbar only makes the title bar as tall as those bars; the bars themselves are SwiftUI, and
/// clicks in them still reach SwiftUI.
struct WindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar == nil { window.toolbar = NSToolbar() }
            window.toolbarStyle = .unified
        }
    }

    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The window has no title bar of its own; the bars at the top move the window like one.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                window?.performDrag(with: event)
                return
            }
            // Double-clicking a title bar does what System Settings › Desktop & Dock says.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The bar at the top of every screen.
struct TopBar<Content: View>: View {
    /// Extra room on the left, for a bar that sits under the window buttons.
    private let leadingInset: CGFloat
    private let content: Content

    init(leadingInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.leadingInset = leadingInset
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.leading, leadingInset)
            .padding(.horizontal, 14)
            // Never wider than the window: content that doesn't fit is cut off, rather than
            // pushing the whole window aside.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: Theme.barHeight, maxHeight: Theme.barHeight)
            .clipped()
            .background(WindowDragArea())
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            // Scroll views extend into the area under the title bar; the bar must stay on top
            // of them, both drawn and for clicks.
            .zIndex(1)
    }
}

/// The status bar at the bottom of the main window.
struct FooterBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: Theme.footerHeight, maxHeight: Theme.footerHeight)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// A rounded well that groups related buttons, such as the markup tools.
struct ButtonGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: Theme.corner + 3).fill(Theme.well))
    }
}

/// A borderless button with a hover background; the same in every bar.
struct IconButton<Label: View>: View {
    private let help: String
    private let active: Bool
    private let action: () -> Void
    private let label: Label
    @LocalState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(help: String, active: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.help = help
        self.active = active
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(minWidth: 28, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(active ? Color.accentColor.opacity(0.16)
                          : hovering && isEnabled ? Theme.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension IconButton where Label == Image {
    init(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.init(help: help, active: active, action: action) { Image(systemName: symbol) }
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        // Shrinks when the bar is tight, for example with a Hot Space tab open in a narrow window.
        .frame(minWidth: 110, maxWidth: 190, minHeight: 26, maxHeight: 26)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    private let actions: Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.well))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
                .padding(.top, 4)
        }
        .padding(24)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updates: UpdateChecker
    @LocalState private var search = ""
    @LocalState private var anchor: URL?
    @LocalState private var memoryAnchor: UUID?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

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
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    VStack(spacing: 0) {
                        topBar
                        updateBanner
                        Group {
                            switch store.tab {
                            case .memory: memoryGallery
                            case .stored, .space: fileGallery
                            }
                        }
                        .clipped()
                        footer
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.spring(response: 0.3), value: store.toast)
        .background(WindowChrome())
        // The title bar is transparent: the bars start at the top edge.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var topBar: some View {
        TopBar {
            // Everything with labels when there is room; in a narrow window first the actions,
            // then the In Memory and Saved tabs show only their symbol and count.
            ViewThatFits(in: .horizontal) {
                barContent(compactTabs: false, compactActions: false)
                barContent(compactTabs: false, compactActions: true)
                barContent(compactTabs: true, compactActions: true)
            }
        }
    }

    private func barContent(compactTabs: Bool, compactActions: Bool) -> some View {
        HStack(spacing: 10) {
            tabs(compact: compactTabs)
            Spacer(minLength: 12)
            actions(compact: compactActions)
        }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button { store.markUpSelection() } label: {
                ActionLabel(title: "Mark Up", symbol: "pencil.tip.crop.circle", compact: compact)
            }
            .disabled(!store.canMarkUpSelection)
            .help(store.canMarkUpSelection ? "Mark up the selected screenshot (⌘E)"
                                           : "Select one screenshot to mark it up (⌘E)")
            switch store.tab {
            case .memory:
                IconButton("doc.on.clipboard", help: clipboardHelp, active: store.watchClipboard) {
                    store.watchClipboard.toggle()
                }
                Button { store.saveMemory(store.memoryShots.map(\.id)) } label: {
                    ActionLabel(title: "Save All", symbol: "square.and.arrow.down.on.square", compact: compact)
                }
                .disabled(store.memoryShots.isEmpty)
                .help("Save all to \(store.sourceFolder.lastPathComponent) (⌘⇧S)")
            case .stored:
                SearchField(text: $search)
                IconButton("line.3.horizontal.decrease.circle",
                           help: store.onlyScreenshots ? "Showing screenshots only. Click to show all images"
                                                       : "Showing all images. Click to show screenshots only",
                           active: store.onlyScreenshots) {
                    store.onlyScreenshots.toggle()
                }
            case .space:
                SearchField(text: $search)
                if let folder = store.viewedFolder {
                    IconButton("folder", help: "Show in Finder") { NSWorkspace.shared.open(folder) }
                }
            }
            if let since = store.recordingSince {
                Button { store.toggleRecording() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        if !compact {
                            TimelineView(.periodic(from: since, by: 1)) { context in
                                Text(verbatim: "Stop " + VideoInfo.format(context.date.timeIntervalSince(since).rounded(.down)))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Stop recording (⌘⇧N)")
            } else {
                Button { store.toggleRecording() } label: {
                    ActionLabel(title: "Record", symbol: "record.circle", compact: compact)
                }
                .disabled(store.isRecording)
                .help("Record the screen or an area, without sound: drag an area or click for the whole screen, "
                      + "then Stop when you are done. \(destinationHelp) (⌘⇧N)")
            }
            Button { store.capture() } label: {
                ActionLabel(title: "Take Screenshot", symbol: "camera.viewfinder", compact: compact)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isCapturing)
            .help("Choose an area, or press Space for a window. \(destinationHelp) (⌘N)")
        }
    }

    /// Where a new screenshot or recording goes, for the help texts.
    private var destinationHelp: String {
        store.captureFolderName.map { "It is saved straight to \($0)" } ?? "It is kept in memory only"
    }

    private var clipboardHelp: String {
        (store.watchClipboard ? "Clipboard Capture is on. " : "Clipboard Capture is off. ")
            + "When on, images that land on the clipboard, such as a screenshot taken with ⌃⌘⇧4, appear here. "
            + "Content that an app marks as concealed or transient, such as from a password manager, is skipped."
    }

    // MARK: Tabs

    private func tabs(compact: Bool) -> some View {
        HStack(spacing: 2) {
            tab(.memory, symbol: "memorychip", title: "In Memory", count: store.memoryShots.count,
                tint: Theme.unsaved, showTitle: !compact)
            tab(.stored, symbol: "folder", title: "Saved", count: store.shots.count, tint: .secondary,
                showTitle: !compact)
            // An opened Hot Space gets its own tab, which disappears again when you switch back.
            if let space = store.viewedSpace, let name = store.viewedName {
                tab(store.tab, symbol: "folder.fill", title: name, count: store.spaceShots.count,
                    tint: palette[space.colorIndex % palette.count], titleWidth: compact ? 90 : 140, closable: true)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.well))
        .fixedSize()
    }

    private func tab(_ tab: Store.Tab, symbol: String, title: String, count: Int, tint: Color,
                     showTitle: Bool = true, titleWidth: CGFloat = 140, closable: Bool = false) -> some View {
        let selected = store.tab == tab
        return HStack(spacing: 6) {
            Button { store.tab = tab } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    if showTitle {
                        Text(title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // A long folder name doesn't push the actions out of the bar.
                            .frame(maxWidth: titleWidth)
                    }
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            if closable {
                Button { store.tab = .stored } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.hover))
                }
                .buttonStyle(.plain)
                .help("Close \(title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule()
            .fill(selected ? Theme.card : Color.clear)
            .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1.5, y: 0.5))
    }

    // MARK: Update banner

    /// Banner about a new version, or the first-time explanation of the daily check.
    @ViewBuilder
    private var updateBanner: some View {
        if let version = updates.available {
            banner(icon: "arrow.down.circle.fill",
                   text: "Screenshot Hub \(version) is available. You have \(AppInfo.version).") {
                Button("Not Now") { updates.dismiss() }
                Button("View Release") { NSWorkspace.shared.open(UpdateChecker.releaseURL(for: version)) }
                    .buttonStyle(.borderedProminent)
            }
        } else if updates.enabled && !updates.disclosureShown {
            banner(icon: "network",
                   text: "Screenshot Hub checks GitHub once a day for a new version. "
                       + "Only a request goes to GitHub, which sees your IP address.") {
                Button("Turn Off") {
                    updates.enabled = false
                    updates.disclosureShown = true
                }
                Button("OK") { updates.disclosureShown = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func banner<Buttons: View>(icon: String, text: String,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).strokeBorder(Color.accentColor.opacity(0.25)))
        .padding([.horizontal, .top], 16)
    }

    // MARK: In memory

    private var memoryGallery: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.memoryShots) { shot in
                    MemoryCard(shot: shot, selected: store.memorySelection.contains(shot.id))
                        .onDrag { memoryItemProvider(for: shot) }
                        .onTapGesture {
                            if NSApp.currentEvent?.clickCount == 2 {
                                if !shot.isVideo { store.markUp(memory: shot.id) }
                            } else {
                                handleMemoryTap(shot)
                            }
                        }
                        .contextMenu { memoryMenu(shot) }
                }
            }
            .padding(20)
        }
        .overlay {
            if store.memoryShots.isEmpty {
                EmptyState(symbol: "camera.viewfinder", title: "Nothing in memory yet",
                           message: store.watchClipboard
                               ? "Take a screenshot or make a recording, or take one with ⌃⌘⇧4. It appears here and isn’t saved until you say so."
                               : "Take a screenshot or make a recording. It appears here and isn’t saved until you say so. "
                                 + "Turn on Clipboard Capture to also get screenshots taken with ⌃⌘⇧4.") {
                    HStack(spacing: 10) {
                        Button { store.toggleRecording() } label: {
                            Label("Record", systemImage: "record.circle")
                        }
                        .disabled(store.isRecording)
                        Button { store.capture() } label: {
                            Label("Take Screenshot", systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isCapturing)
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder
    private func memoryMenu(_ shot: MemoryShot) -> some View {
        let targets = store.memorySelection.contains(shot.id) ? Array(store.memorySelection) : [shot.id]
        if !shot.isVideo {
            Button("Mark Up…") { store.markUp(memory: shot.id) }
            Divider()
        }
        Button("Save to \(store.sourceFolder.lastPathComponent)") { store.saveMemory(targets) }
        if !store.hotSpaces.isEmpty {
            Menu("Save to Hot Space") {
                hotSpaceItems { space, subfolder in store.deliver([], memory: targets, to: space, subfolder: subfolder) }
            }
        }
        if !shot.isVideo {
            Button("Copy Image") { store.copyToClipboard(shot) }
        }
        Divider()
        Button("Discard") { store.discardMemory(targets) }
    }

    private func handleMemoryTap(_ shot: MemoryShot) {
        applyClick(on: shot.id, order: store.memoryShots.map(\.id),
                   selection: &store.memorySelection, anchor: &memoryAnchor)
    }

    // MARK: Saved

    private var fileGallery: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
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
            .padding(20)
        }
        .overlay {
            if store.tab == .stored && !store.hasSourceAccess {
                EmptyState(symbol: "folder.badge.questionmark", title: "Choose your screenshot folder",
                           message: "Screenshot Hub can only access folders you choose yourself. "
                               + "You can see which folder macOS uses under ⌘⇧5 › Options.") {
                    Button("Choose Folder…") { store.chooseSourceFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if filtered.isEmpty {
                EmptyState(symbol: search.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                           title: search.isEmpty ? "No screenshots here yet" : "No screenshots with this name",
                           message: !search.isEmpty ? "Try a different search."
                               : store.tab == .stored ? "Take one with ⌘⇧4 or ⌘⇧5, or save one from In Memory."
                               : "Drop screenshots on this folder in the sidebar to save them here.")
            }
        }
    }

    @ViewBuilder
    private func shotMenu(_ shot: Shot) -> some View {
        let targets = store.selection.contains(shot.url) ? Array(store.selection) : [shot.url]
        Button("Open") { NSWorkspace.shared.open(shot.url) }
        if !shot.isVideo {
            Button("Mark Up…") { store.markUp(file: shot.url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        if !shot.isVideo {
            Button("Copy Image") { store.copyToClipboard(shot.url) }
        }
        if !store.hotSpaces.isEmpty {
            Menu("Send to Hot Space") {
                hotSpaceItems { space, subfolder in store.deliver(targets, to: space, subfolder: subfolder) }
            }
        }
        Divider()
        Button("Move to Trash") { store.trash(targets) }
    }

    /// Hot Spaces as menu items; one with subfolders becomes a submenu. The folder that is
    /// open makes no sense as a target and is left out.
    @ViewBuilder
    private func hotSpaceItems(_ send: @escaping (HotSpace, URL?) -> Void) -> some View {
        ForEach(store.hotSpaces) { space in
            let subfolders = store.subfolders(of: space.url).filter { !store.isViewed($0) }
            if subfolders.isEmpty {
                if !store.isViewed(space.url) {
                    Button(space.name) { send(space, nil) }
                }
            } else {
                Menu(space.name) {
                    if !store.isViewed(space.url) {
                        Button(space.name) { send(space, nil) }
                        Divider()
                    }
                    ForEach(subfolders, id: \.self) { folder in
                        Button(folder.lastPathComponent) { send(space, folder) }
                    }
                }
            }
        }
    }

    private func handleTap(_ shot: Shot) {
        applyClick(on: shot.url, order: filtered.map(\.url),
                   selection: &store.selection, anchor: &anchor)
    }

    // MARK: Status bar

    private var footer: some View {
        FooterBar {
            switch store.tab {
            case .memory:
                Image(systemName: "memorychip")
                Text(memorySummary)
                Spacer(minLength: 8)
                if !store.memoryShots.isEmpty {
                    Text("Double-click to mark up · ⌘S to save")
                }
            case .stored:
                Image(systemName: "folder")
                if store.hasSourceAccess {
                    Text(displayPath(store.sourceFolder.path))
                        .truncationMode(.head)
                    Button("Change…") { store.chooseSourceFolder() }
                        .buttonStyle(.link)
                } else {
                    Text("No screenshot folder chosen yet")
                    Button("Choose Folder…") { store.chooseSourceFolder() }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 8)
                if store.hasSourceAccess { Text("New screenshots go here ·") }
                Text(count(filtered.count))
            case .space:
                if let folder = store.viewedFolder {
                    Image(systemName: "folder")
                    Text(displayPath(folder.path))
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                Text("New screenshots go here ·")
                Text(count(filtered.count))
            }
        }
    }

    private var memorySummary: String {
        let shots = store.memoryShots
        guard !shots.isEmpty else { return "Nothing in memory" }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(shots.reduce(0) { $0 + $1.data.count }),
                                              countStyle: .memory)
        return "\(count(shots.count)) · \(bytes) · not saved yet"
    }

    private func count(_ n: Int) -> String {
        n == 1 ? "1 screenshot" : "\(n) screenshots"
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            HStack(spacing: 10) {
                Text(toast.text)
                    .font(.system(size: 12, weight: .medium))
                if toast.canUndo {
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 14)
                    Button("Undo") { store.undoLast() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            // Above the status bar, or above the zoom controls while marking up.
            .padding(.bottom, store.isMarkingUp ? 64 : Theme.footerHeight + 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Screenshot cards

/// The look both kinds of cards share: the thumbnail in a well, two lines of text, and quick
/// actions that appear when you hover.
struct CardChrome<Thumbnail: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    var unsaved = false
    var video = false
    private let thumbnail: Thumbnail
    private let actions: Actions
    @LocalState private var hovering = false

    init(title: String, subtitle: String, selected: Bool, unsaved: Bool = false, video: Bool = false,
         @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.unsaved = unsaved
        self.video = video
        self.thumbnail = thumbnail()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .padding(12)
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(Theme.well)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if unsaved {
                        Text("Unsaved")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.unsaved))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        HStack(spacing: 4) { actions }
                            .padding(6)
                            .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner)
            .fill(Theme.card)
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 10 : 3, y: hovering ? 4 : 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner)
            .strokeBorder(selected ? Color.accentColor : Theme.hairline, lineWidth: selected ? 2.5 : 1))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

/// A round quick action on a card.
struct CardAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MemoryCard: View {
    @EnvironmentObject var store: Store
    let shot: MemoryShot
    let selected: Bool

    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(shot.data.count), countStyle: .memory)
        let length = shot.isVideo ? " · \(VideoInfo.format(shot.duration))" : ""
        CardChrome(title: shot.date.formatted(date: .omitted, time: .standard),
                   subtitle: "\(shot.pixelWidth) × \(shot.pixelHeight)\(length) · \(size)",
                   selected: selected, unsaved: true, video: shot.isVideo) {
            Image(nsImage: shot.thumbnail)
                .resizable()
                .scaledToFit()
        } actions: {
            if !shot.isVideo {
                CardAction(symbol: "pencil.tip.crop.circle", help: "Mark Up (⌘E)") { store.markUp(memory: shot.id) }
            }
            CardAction(symbol: "square.and.arrow.down", help: "Save to \(store.sourceFolder.lastPathComponent)") {
                store.saveMemory([shot.id])
            }
            CardAction(symbol: "trash", help: "Discard") { store.discardMemory([shot.id]) }
        }
        .help(shot.isVideo ? "Screen recording. Save it to play it" : "Double-click to mark up")
    }
}

struct ShotCard: View {
    @EnvironmentObject var store: Store
    let shot: Shot
    let selected: Bool

    var body: some View {
        CardChrome(title: shot.url.lastPathComponent,
                   subtitle: shot.date.formatted(date: .abbreviated, time: .shortened),
                   selected: selected, video: shot.isVideo) {
            ThumbnailView(url: shot.url, modified: shot.modified)
        } actions: {
            if !shot.isVideo {
                CardAction(symbol: "pencil.tip.crop.circle",
                           help: "Mark Up: Done overwrites the file, Undo brings back the original") {
                    store.markUp(file: shot.url)
                }
            }
            CardAction(symbol: "folder", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([shot.url])
            }
        }
    }
}

/// A label, or only its symbol when the bar is narrow.
struct ActionLabel: View {
    let title: String
    let symbol: String
    let compact: Bool

    var body: some View {
        if compact {
            Image(systemName: symbol)
        } else {
            Label(title, systemImage: symbol)
        }
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
            let isVideo = Store.videoExtensions.contains(url.pathExtension.lowercased())
            let cg = isVideo
                ? await VideoInfo.load(target)?.thumbnail
                : await Task.detached(priority: .utility) { makeThumbnail(target) }.value
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
    /// Zoom relative to actual size; nil fits the image in the window.
    @LocalState private var zoom: CGFloat?
    @LocalState private var pinchStart: CGFloat?

    private static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]
    private static let thicknesses: [(name: String, value: CGFloat)] = [("Thin", 1), ("Medium", 2), ("Thick", 4)]

    private var imageSize: CGSize { CGSize(width: session.image.width, height: session.image.height) }

    /// Base width in pixels, in proportion to the image: thicker on a large screenshot.
    private var unit: CGFloat { max(2, max(imageSize.width, imageSize.height) / 500) }

    /// Points per image pixel at actual size, so a Retina screenshot shows at the size it had on screen.
    private var actualSize: CGFloat {
        let dpi = session.dpi?.width ?? 72
        return 72 / CGFloat(dpi > 0 ? dpi : 72)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                let fit = fitZoom(in: geo.size)
                let current = zoom ?? fit
                ZStack(alignment: .bottom) {
                    canvas(scale: current * actualSize, current: current, in: geo.size)
                    zoomControls(current: current)
                        .padding(.bottom, 16)
                }
            }
            .background(Theme.canvas, ignoresSafeAreaEdges: [])
            .clipped()
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

    // MARK: Toolbar

    private var toolbar: some View {
        // The window buttons sit at the top left, above this bar.
        TopBar(leadingInset: Theme.windowButtonsWidth - 14) {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 12)
            ButtonGroup {
                ForEach(Mark.Tool.allCases, id: \.self) { item in
                    IconButton(item.symbol, help: toolHelp(item), active: tool == item) { tool = item }
                        .keyboardShortcut(KeyEquivalent(item.key), modifiers: [])
                }
            }
            // Color and thickness sit right in the bar, one click away. They don't apply to blur.
            ButtonGroup {
                ForEach(markColors.indices, id: \.self) { index in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Color(nsColor: markColors[index].color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .frame(width: 15, height: 15)
                            .padding(3)
                            .overlay(Circle().strokeBorder(colorIndex == index && tool.usesColor
                                                           ? Color.accentColor : Color.clear, lineWidth: 2))
                            .frame(width: 24, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(markColors[index].name)
                }
            }
            .disabled(!tool.usesColor)
            .opacity(tool.usesColor ? 1 : 0.35)
            ButtonGroup {
                ForEach(Self.thicknesses, id: \.value) { item in
                    IconButton(help: item.name, active: thickness == item.value && tool.usesColor,
                               action: { thickness = item.value }) {
                        Capsule().frame(width: 14, height: max(1.5, item.value * 1.25))
                    }
                }
            }
            .disabled(!tool.usesColor)
            Spacer(minLength: 12)
            ButtonGroup {
                IconButton("arrow.uturn.backward", help: "Undo (⌘Z)") { undoManager?.undo() }
                    .disabled(!(undoManager?.canUndo ?? false))
                IconButton("arrow.uturn.forward", help: "Redo (⌘⇧Z)") { undoManager?.redo() }
                    .disabled(!(undoManager?.canRedo ?? false))
                IconButton("trash", help: "Clear All") { model.set([]) }
                    .disabled(model.marks.isEmpty)
            }
            Button("Done") { store.finishMarkup(session, marks: model.marks) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.marks.isEmpty)
                .help(doneHelp)
        }
    }

    private func toolHelp(_ item: Mark.Tool) -> String {
        let key = item.key.uppercased()
        return item == .blur ? "Blur (\(key)): drag over an area to make it unreadable" : "\(item.name) (\(key))"
    }

    private var doneHelp: String {
        if case .file = session.source {
            return "Overwrite the file with the marks; Undo in the notice brings back the original (↩)"
        }
        return "Put the marks into the screenshot (↩)"
    }

    // MARK: Canvas

    /// Zoom that fits the whole image, but never larger than actual size.
    private func fitZoom(in size: CGSize) -> CGFloat {
        let width = (size.width - 64) / (imageSize.width * actualSize)
        let height = (size.height - 112) / (imageSize.height * actualSize)
        return max(0.05, min(width, height, 1))
    }

    private func canvas(scale: CGFloat, current: CGFloat, in size: CGSize) -> some View {
        let image = session.image
        let bounds = CGRect(origin: .zero, size: imageSize)
        return ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in
                context.scaleBy(x: scale, y: scale)
                context.draw(Image(decorative: image, scale: 1), in: bounds)
                for mark in model.marks + [model.current].compactMap({ $0 }) {
                    if mark.tool == .blur {
                        context.drawLayer { layer in
                            layer.clip(to: mark.path)
                            if let obscured = session.obscured {
                                layer.draw(Image(decorative: obscured, scale: 1), in: bounds)
                            } else {
                                layer.fill(Path(bounds), with: .color(.gray))
                            }
                        }
                    } else {
                        context.stroke(mark.path, with: .color(Color(nsColor: mark.strokeColor)),
                                       style: StrokeStyle(lineWidth: mark.lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
                // Outline of the area being blurred, while you drag it.
                if let current = model.current, current.tool == .blur {
                    context.stroke(current.path, with: .color(.black.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.5 / scale))
                    context.stroke(current.path, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.5 / scale, dash: [5 / scale, 4 / scale]))
                }
            }
            .frame(width: imageSize.width * scale, height: imageSize.height * scale)
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
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            // Extra room at the bottom, so the zoom controls never cover the image.
            .padding(EdgeInsets(top: 32, leading: 32, bottom: 80, trailing: 32))
            .frame(minWidth: size.width, minHeight: size.height)
        }
        .simultaneousGesture(MagnificationGesture()
            .onChanged { value in
                let start = pinchStart ?? current
                pinchStart = start
                zoom = min(max(start * value, Self.zoomSteps.first!), Self.zoomSteps.last!)
            }
            .onEnded { _ in pinchStart = nil })
    }

    private func zoomControls(current: CGFloat) -> some View {
        HStack(spacing: 2) {
            IconButton("minus", help: "Zoom Out (⌘−)") {
                zoom = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(current <= Self.zoomSteps.first! + 0.001)
            Menu {
                Button("Zoom to Fit") { zoom = nil }
                Divider()
                ForEach([CGFloat(0.5), 1, 2, 4], id: \.self) { step in
                    Button("\(Int(step * 100))%") { zoom = step }
                }
            } label: {
                Text(verbatim: "\(Int((current * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 52)
            .help("Zoom")
            IconButton("plus", help: "Zoom In (⌘+)") {
                zoom = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(current >= Self.zoomSteps.last! - 0.001)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 3)
            IconButton("arrow.up.left.and.arrow.down.right", help: "Zoom to Fit (⌘0)", active: zoom == nil) {
                zoom = nil
            }
            .keyboardShortcut("0", modifiers: .command)
            IconButton("1.magnifyingglass", help: "Actual Size", active: zoom == 1) { zoom = 1 }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func drag(to point: CGPoint) {
        guard var mark = model.current else {
            model.current = Mark(tool: tool, points: [point], color: markColors[colorIndex].color,
                                 width: unit * thickness)
            return
        }
        switch mark.tool {
        case .pen, .highlighter: mark.points.append(point)
        case .arrow, .rectangle, .ellipse, .blur: mark.points = [mark.points[0], point]
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
        VStack(alignment: .leading, spacing: 0) {
            // The window buttons sit at the top left of this bar.
            HStack {
                Spacer()
                IconButton("plus", help: "Add Hot Space…") { store.addHotSpace() }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.barHeight)
            .background(WindowDragArea())

            Text("Hot Spaces")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(store.hotSpaces.enumerated()), id: \.element.id) { index, space in
                        HotSpaceRow(space: space, index: index)
                    }
                    if store.hotSpaces.isEmpty { addPlaceholder }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Saved screenshots")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Saved screenshots", selection: $store.moveFiles) {
                    Text("Move").tag(true)
                    Text("Copy").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .help("Whether saved screenshots you send to a Hot Space are moved or copied. "
                  + "Screenshots from memory are always saved there.")
        }
        .frame(width: Theme.sidebarWidth)
        .background(VisualEffect(material: .sidebar))
    }

    private var addPlaceholder: some View {
        Button { store.addHotSpace() } label: {
            VStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Add a folder")
                    .font(.system(size: 12, weight: .medium))
                Text("Drop screenshots on it to save them there. Folders inside it become targets too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.cardCorner)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A Hot Space, or a folder inside one. Folders with subfolders can be expanded; every row is
/// a target for dropping and clicking.
struct HotSpaceRow: View {
    @EnvironmentObject var store: Store
    let space: HotSpace
    let index: Int
    /// Nil for the Hot Space itself.
    var subfolder: URL?
    var depth = 0
    @LocalState private var targeted = false
    @LocalState private var hovering = false

    private var url: URL { subfolder ?? space.url }
    private var name: String { subfolder?.lastPathComponent ?? space.name }
    private var color: Color { palette[space.colorIndex % palette.count] }

    var body: some View {
        let children = store.subfolders(of: url)
        let expanded = store.expandedFolders.contains(url.path)
        let viewed = store.viewedSpace?.id == space.id && store.isViewed(url)
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Button { withAnimation(.easeOut(duration: 0.15)) { store.toggleExpanded(url) } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(children.isEmpty ? 0 : 1)
                .disabled(children.isEmpty)
                .help(expanded ? "Hide folders inside \(name)" : "Show folders inside \(name)")

                // Row and eye are two buttons side by side, not nested: that way the row can
                // never catch a click on the eye and send the selection here.
                Button(action: clicked) {
                    HStack(spacing: 8) {
                        icon
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name)
                                .font(.system(size: 13, weight: depth == 0 ? .medium : .regular))
                                .lineLimit(1)
                            if depth == 0 {
                                Text(displayPath(space.path))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.hasSelection
                      ? "Click to send the selection to \(name)"
                      : "Click to see what is in \(name), or drop screenshots here")

                if hovering {
                    Button { store.openSpace(space, subfolder: subfolder) } label: {
                        Image(systemName: viewed ? "eye.fill" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(viewed ? color : .secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("See what is in \(name)")
                } else if depth == 0 && index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(height: 22)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .padding(.vertical, depth == 0 ? 5 : 2)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? color.opacity(0.22)
                      : viewed ? Color.accentColor.opacity(0.15)
                      : hovering ? Theme.hover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? color : Color.clear, lineWidth: 1.5))
            .scaleEffect(targeted ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onHover { hovering = $0 }
            .onDrop(of: [UTType.memoryShot, UTType.fileURL], isTargeted: $targeted) { providers in
                loadDrop(from: providers) { urls, ids in
                    store.dropped(urls, memory: ids, on: space, subfolder: subfolder)
                }
                return true
            }
            .contextMenu {
                Button("Show Contents") { store.openSpace(space, subfolder: subfolder) }
                Button("Show in Finder") { NSWorkspace.shared.open(url) }
                Divider()
                if let subfolder {
                    Button("Add as Hot Space") { store.addHotSpace(subfolder) }
                } else {
                    Button("Remove Hot Space") { store.removeHotSpace(space) }
                }
            }

            if expanded {
                ForEach(children, id: \.self) { child in
                    HotSpaceRow(space: space, index: index, subfolder: child, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        let symbol = targeted ? "tray.and.arrow.down.fill" : "folder.fill"
        if depth == 0 {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.gradient))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 24, height: 20)
        }
    }

    /// With a selection, a click sends it here; without one, it opens the folder.
    private func clicked() {
        if store.hasSelection {
            store.deliverSelection(to: space, subfolder: subfolder)
        } else {
            store.openSpace(space, subfolder: subfolder)
        }
    }
}
