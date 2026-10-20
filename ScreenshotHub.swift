// ScreenshotHub.swift
//
// Shoot first, store later. Screenshots komen eerst in het geheugen (via de knop in
// de app of via het klembord, bijvoorbeeld ⌃⌘⇧4) en worden pas een bestand als je ze
// opslaat. Sleep een screenshot op een Hot Space en hij wordt in de gekoppelde map
// opgeslagen, verplaatst of gekopieerd.
//
// Bouwen: bash build.sh  (de Command Line Tools zijn genoeg: xcode-select --install)
// Minimaal macOS 13.

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

/// Een screenshot die alleen in het geheugen staat en nog geen bestand is.
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
    /// Bookmark naar de map, zodat de Hot Space blijft werken als de map wordt hernoemd of verplaatst.
    var bookmark: Data?
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var canUndo = false
}

/// De laatste actie die ongedaan gemaakt kan worden.
struct UndoAction {
    var files: [(from: URL, to: URL)] = []
    var moved = true
    var stored: [(shot: MemoryShot, file: URL)] = []
    var discarded: [MemoryShot] = []
    var targetName = ""
    var isEmpty: Bool { files.isEmpty && stored.isEmpty && discarded.isEmpty }
}

extension UTType {
    /// Sleepsoort voor screenshots uit het geheugen; gedeclareerd in Info.plist door build.sh.
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

    enum Tab: Hashable { case memory, stored, space(UUID) }
    /// Start altijd op het geheugen. Wisselen wist de selectie, zodat ⌘1 t/m ⌘9
    /// nooit iets stuurt dat je niet ziet.
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
    /// De inhoud van de Hot Space die als tab openstaat.
    @Published var spaceShots: [Shot] = []
    var viewedSpace: HotSpace? {
        guard case .space(let id) = tab else { return nil }
        return hotSpaces.first { $0.id == id }
    }
    private var lastUndo: UndoAction?

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
    /// In de sandbox mag de app alleen bij mappen die je zelf kiest. Zolang er geen
    /// screenshotmap gekozen is, is sourceFolder alleen een gok voor de kiezer.
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
    /// Mappen waartoe de app toegang heeft geopend, per sleutel ("source" of het id van een Hot Space).
    private var scopedURLs: [String: URL] = [:]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    private static let sourceKey = "source"

    init() {
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
        // Standaard uit: het klembord kan gevoelige afbeeldingen bevatten.
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

        // Escape wist de selectie, behalve als je in een tekstveld typt of een dialoog open is.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.hasSelection,
                  NSApp.modalWindow == nil,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.selection = []
            self.memorySelection = []
            return nil
        }
        // Wie in Finder een map hernoemt, ziet de nieuwe naam als hij terugkomt in de app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for space in self.hotSpaces { self.refreshLocation(of: space) }
        }
        // Het klembord heeft geen meldingen, dus we kijken twee keer per seconde of het veranderd is.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkClipboard() }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// De echte thuismap. In de sandbox wijzen NSHomeDirectory en FileManager naar de container.
    static let realHome: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Beste gok voor de map waar macOS screenshots opslaat (⌘⇧5 › Opties), anders het bureaublad.
    /// In de sandbox is de instelling van macOS niet leesbaar; dan dient dit alleen als startpunt
    /// voor de kiezer, want toegang krijgt de app pas als je de map zelf kiest.
    static func systemScreenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = location.hasPrefix("~")
                ? realHome.path + location.dropFirst()
                : location
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return realHome.appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: Toegang tot mappen (sandbox)

    /// Bookmark die na een herstart weer toegang geeft tot een map die je zelf hebt gekozen.
    static func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Opent de toegang tot een map en houdt die open tot endAccess. Geeft false als het niet mag.
    @discardableResult
    private func beginAccess(_ url: URL, key: String) -> Bool {
        if let open = scopedURLs[key] {
            if open == url { return true }
            open.stopAccessingSecurityScopedResource()
            scopedURLs[key] = nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            // Zonder sandbox (bijvoorbeeld bij testen) is er niets af te schermen.
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

    /// macOS markeert screenshots met een extended attribute; bestandsnaam is de terugvaloptie.
    static func isScreenshot(_ url: URL) -> Bool {
        let size = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, screenshotAttribute, nil, 0, 0, 0)
        }
        if size >= 0 { return true }
        let name = url.lastPathComponent.lowercased()
        return ["screenshot", "schermafbeelding", "bildschirmfoto", "capture d"].contains { name.hasPrefix($0) }
    }

    /// Zet dezelfde markering als macOS, zodat een opgeslagen screenshot ook onder "Alleen screenshots" valt.
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

    /// Dezelfde naam als macOS geeft: "Schermafbeelding 2026-10-16 om 15.41.22.png".
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.dateFormat = "yyyy-MM-dd 'om' HH.mm.ss"
        return "Schermafbeelding \(formatter.string(from: date)).png"
    }

    // MARK: Lezen en bewaken

    func reload() {
        shots = Store.listShots(in: sourceFolder, onlyScreenshots: onlyScreenshots)
        // In een Hot Space staat alles wat je er zelf in hebt gezet, dus daar geen screenshotfilter.
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
        // Even wachten zodat macOS het bestand volledig heeft weggeschreven.
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

    /// Opent de Hot Space als tab, zodat je ziet wat erin staat.
    func openSpace(_ space: HotSpace) {
        let space = refreshLocation(of: space)
        if let reason = unavailableReason(space) {
            showToast(reason)
            return
        }
        tab = .space(space.id)
    }

    // MARK: Geheugen

    /// Laat je een gebied of venster kiezen (zoals ⌘⇧4) en zet het resultaat alleen in het geheugen.
    func captureToMemory() {
        guard !isCapturing else { return }
        isCapturing = true
        // screencapture kan niet direct naar het geheugen van deze app schrijven; het tijdelijke
        // bestand wordt meteen ingelezen en weer verwijderd.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotHub-\(UUID().uuidString).png")
        NSApp.hide(nil)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", temp.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
            let data = try? Data(contentsOf: temp)
            try? FileManager.default.removeItem(at: temp)
            let shot = data.flatMap { MemoryShot(png: $0) }
            DispatchQueue.main.async {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                guard let self else { return }
                self.isCapturing = false
                // Geen bestand betekent dat de gebruiker met Escape heeft geannuleerd.
                if let shot { self.addToMemory(shot) }
            }
        }
    }

    private func addToMemory(_ shot: MemoryShot) {
        memoryShots.insert(shot, at: 0)
        // Laten zien en meteen selecteren, zodat ⌘1 t/m ⌘9 of ⌘S hem direct opslaat.
        tab = .memory
        memorySelection = [shot.id]
    }

    /// Markeringen (nspasteboard.org) waarmee wachtwoordmanagers en andere apps aangeven dat
    /// klembordinhoud vertrouwelijk, tijdelijk of automatisch gemaakt is. Die halen we nooit op.
    static let privateClipboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Haalt een afbeelding van het klembord op, zoals een screenshot met ⌃⌘⇧4.
    /// Alleen als je dat aanzet; de inhoud wordt pas gelezen als de soort klopt.
    func checkClipboard(_ pasteboard: NSPasteboard = .general) {
        guard pasteboard.changeCount != clipboardCount else { return }
        clipboardCount = pasteboard.changeCount
        guard watchClipboard, let types = pasteboard.types else { return }
        guard !types.contains(where: Store.privateClipboardTypes.contains) else { return }
        // Alleen een kale afbeelding telt. Gekopieerde bestanden, tekst met plaatjes
        // of webinhoud laten we liggen.
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

    /// Slaat alles uit het geheugen op in de screenshotmap. Geeft false als iets niet lukte.
    func saveAllMemory() -> Bool {
        guard ensureSourceAccess() else { return false }
        return deliver(files: [], memory: memoryShots.map(\.id), into: sourceFolder,
                       name: sourceFolder.lastPathComponent)
    }

    /// Vraagt eerst om de screenshotmap als de app daar nog geen toegang toe heeft.
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
        showToast(discarded.count == 1 ? "Screenshot weggegooid" : "\(discarded.count) screenshots weggegooid",
                  canUndo: true)
    }

    func copyToClipboard(_ shot: MemoryShot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(shot.png, forType: .png)
        clipboardCount = pasteboard.changeCount
        showToast("Afbeelding gekopieerd")
    }

    // MARK: Afleveren in Hot Spaces

    func dropped(_ urls: [URL], memory ids: [UUID], on space: HotSpace) {
        // Sleep je één screenshot uit een meervoudige selectie, dan gaat de hele selectie mee.
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

    /// Slaat screenshots uit het geheugen op in de map en verplaatst of kopieert bestanden ernaartoe.
    @discardableResult
    private func deliver(files urls: [URL], memory ids: [UUID], into folder: URL, name: String) -> Bool {
        let fm = FileManager.default
        // Alleen afbeeldingen; mappen en andere bestanden die uit Finder worden gesleept blijven staan.
        let images = urls.filter(Store.isImageFile)
        let skipped = urls.count - images.count
        let wanted = Set(ids)
        let memory = memoryShots.filter { wanted.contains($0.id) }
        guard !images.isEmpty || !memory.isEmpty else {
            if skipped > 0 { showToast("Alleen afbeeldingen kunnen naar een Hot Space") }
            return skipped == 0
        }

        var undo = UndoAction(moved: moveFiles, targetName: name)
        var failed = 0
        var failure: String?

        for shot in memory {
            let dest = uniqueDestination(for: Store.fileName(for: shot.date), in: folder)
            do {
                try shot.png.write(to: dest, options: .withoutOverwriting)
                // Datum van het moment van vastleggen, niet van opslaan, zodat de volgorde klopt.
                try? fm.setAttributes([.creationDate: shot.date, .modificationDate: shot.date],
                                      ofItemAtPath: dest.path)
                Store.markAsScreenshot(dest)
                undo.stored.append((shot: shot, file: dest))
            } catch {
                failed += 1
                failure = failure ?? error.localizedDescription
            }
        }
        let storedIDs = Set(undo.stored.map(\.shot.id))
        memoryShots.removeAll { storedIDs.contains($0.id) }
        memorySelection.subtract(storedIDs)

        for src in images {
            let sameFolder = src.deletingLastPathComponent().standardizedFileURL.path
                == folder.standardizedFileURL.path
            if sameFolder { continue }
            let dest = uniqueDestination(for: src.lastPathComponent, in: folder)
            do {
                if moveFiles {
                    try fm.moveItem(at: src, to: dest)
                } else {
                    try fm.copyItem(at: src, to: dest)
                }
                undo.files.append((from: src, to: dest))
            } catch {
                failed += 1
                failure = failure ?? error.localizedDescription
            }
        }

        var parts: [String] = []
        if !undo.stored.isEmpty {
            let what = undo.stored.count == 1 ? "Screenshot" : "\(undo.stored.count) screenshots"
            parts.append("\(what) opgeslagen in \(name)")
        }
        if !undo.files.isEmpty {
            let what = undo.files.count == 1 ? "Screenshot" : "\(undo.files.count) screenshots"
            parts.append("\(what) \(moveFiles ? "verplaatst" : "gekopieerd") naar \(name)")
        }
        if let failure {
            parts.append(undo.isEmpty ? "Niet gelukt: \(failure)" : "\(failed) niet gelukt: \(failure)")
        }
        if skipped > 0 {
            parts.append(skipped == 1 ? "1 bestand overgeslagen (geen afbeelding)"
                                      : "\(skipped) bestanden overgeslagen (geen afbeelding)")
        }

        if !undo.isEmpty { lastUndo = undo }
        if !parts.isEmpty {
            showToast(parts.joined(separator: " · "), canUndo: !undo.isEmpty)
        }
        reload()
        return failed == 0
    }

    /// Zet verplaatste screenshots terug, gooit gemaakte kopieën en bestanden in de prullenmand
    /// en zet opgeslagen of weggegooide screenshots terug in het geheugen.
    func undoLast() {
        guard let last = lastUndo else { return }
        lastUndo = nil
        let fm = FileManager.default
        var failed = 0
        for item in last.files {
            do {
                if last.moved {
                    let folder = item.from.deletingLastPathComponent()
                    let back = fm.fileExists(atPath: item.from.path)
                        ? uniqueDestination(for: item.from.lastPathComponent, in: folder)
                        : item.from
                    try fm.moveItem(at: item.to, to: back)
                } else {
                    try fm.trashItem(at: item.to, resultingItemURL: nil)
                }
            } catch {
                failed += 1
            }
        }
        var restored = last.discarded
        for item in last.stored {
            do {
                try fm.trashItem(at: item.file, resultingItemURL: nil)
                restored.append(item.shot)
            } catch {
                failed += 1
            }
        }
        if !restored.isEmpty {
            memoryShots = (memoryShots + restored).sorted { $0.date > $1.date }
        }

        let total = last.files.count + last.stored.count + last.discarded.count
        if failed > 0 {
            showToast("Ongedaan maken lukte niet voor \(failed) van \(total) screenshots")
        } else if !last.discarded.isEmpty || !last.stored.isEmpty {
            showToast("Terug in het geheugen")
        } else {
            showToast(last.moved ? "Teruggezet uit \(last.targetName)" : "Kopie uit \(last.targetName) verwijderd")
        }
        reload()
    }

    /// Zoekt de map van een Hot Space op via de bookmark, opent de toegang ertoe en werkt pad
    /// en naam bij als hij is hernoemd of verplaatst.
    @discardableResult
    private func refreshLocation(of space: HotSpace) -> HotSpace {
        guard let index = hotSpaces.firstIndex(where: { $0.id == space.id }) else { return space }
        let current = hotSpaces[index]
        var updated = current
        let key = current.id.uuidString
        if let data = current.bookmark, let resolved = Store.resolveBookmark(data) {
            beginAccess(resolved.url, key: key)
            if resolved.url.path != current.path || resolved.stale {
                // Heette de Hot Space naar de map, dan verhuist de naam mee.
                if current.name == current.url.lastPathComponent {
                    updated.name = resolved.url.lastPathComponent
                }
                updated.path = resolved.url.path
                updated.bookmark = Store.makeBookmark(resolved.url) ?? data
            }
        } else if current.bookmark == nil, beginAccess(current.url, key: key) {
            // Hot Space uit een versie zonder sandbox: alleen buiten de sandbox te herstellen.
            updated.bookmark = Store.makeBookmark(current.url)
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

    // MARK: Overige acties

    func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.showToast(error == nil ? "Naar prullenmand verplaatst" : "Naar prullenmand verplaatsen is niet gelukt")
                self?.reload()
            }
        }
    }

    func copyToClipboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        // Niet als nieuwe screenshot in het geheugen zetten.
        clipboardCount = pasteboard.changeCount
        showToast("Afbeelding gekopieerd")
    }

    func addHotSpace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Toevoegen als Hot Space"
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
        endAccess(key: space.id.uuidString)
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = sourceFolder
        panel.message = "Kies de map waar je screenshots staan. Welke map macOS gebruikt, zie je bij ⌘⇧5 › Opties."
        panel.prompt = "Gebruik deze map"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(Store.makeBookmark(url), forKey: "sourceBookmark")
        hasSourceAccess = beginAccess(url, key: Store.sourceKey)
        sourceFolder = url
    }

    /// Waarom een Hot Space nu niet bruikbaar is, of nil als hij dat wel is.
    private func unavailableReason(_ space: HotSpace) -> String? {
        if space.bookmark == nil {
            return "Geen toegang tot \(space.name). Verwijder de Hot Space en voeg hem opnieuw toe."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: space.path, isDirectory: &isDir), isDir.boolValue,
              !isInTrash(space.url) else {
            return "De map van \(space.name) bestaat niet meer. Verwijder de Hot Space of zet de map terug."
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
        // Met een knop erin blijft de melding langer staan, zodat je tijd hebt om te klikken.
        DispatchQueue.main.asyncAfter(deadline: .now() + (canUndo ? 6 : 2.5)) { [weak self] in
            if self?.toast?.id == new.id { self?.toast = nil }
        }
    }
}

// MARK: - Hulpfuncties

/// Pad met ~ voor de echte thuismap. In de sandbox kort NSString dat niet in,
/// omdat de thuismap daar de container is.
func displayPath(_ path: String) -> String {
    let home = Store.realHome.path
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Leest wat er op een Hot Space is neergezet: bestanden uit Finder of de app, en screenshots uit het geheugen.
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

/// Sleepbaar binnen de app (naar een Hot Space) en als PNG naar andere apps.
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

/// Sleutel is pad plus wijzigingsdatum, zodat een nieuw bestand met dezelfde naam een nieuwe thumbnail krijgt.
enum ThumbCache {
    static let shared = NSCache<NSString, NSImage>()
    static func key(_ url: URL, _ modified: Date) -> NSString {
        "\(url.path)|\(modified.timeIntervalSinceReferenceDate)" as NSString
    }
}

/// Klik selecteert, Cmd-klik voegt toe of haalt weg, Shift-klik selecteert een reeks.
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

/// Vervanger voor @State: in de macOS 27 SDK is @State een macro waarvan de plugin
/// alleen met Xcode wordt meegeleverd, niet met de Command Line Tools.
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

// MARK: - App

/// Waarschuwt bij stoppen, want screenshots in het geheugen zijn dan weg.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Store.shared
        let count = store.memoryShots.count
        guard count > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = count == 1
            ? "1 screenshot is nog niet opgeslagen"
            : "\(count) screenshots zijn nog niet opgeslagen"
        alert.informativeText = "Screenshots in het geheugen zijn weg als je stopt. "
            + "Opslaan zet ze in \(store.sourceFolder.lastPathComponent)."
        alert.addButton(withTitle: "Alles opslaan en stoppen")
        alert.addButton(withTitle: "Annuleer").keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Stop zonder opslaan")
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

/// Versie- en beveiligingsinformatie voor het Over-venster. Versie, build, commit en
/// builddatum zet build.sh in Info.plist; de handtekening leest de app uit zichzelf.
enum AppInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var version: String { info["CFBundleShortVersionString"] as? String ?? "onbekend" }
    static var build: String { info["CFBundleVersion"] as? String ?? "onbekend" }
    static var commit: String { info["ScreenshotHubCommit"] as? String ?? "onbekend" }
    static var buildDate: Date? {
        (info["ScreenshotHubBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    struct Signature {
        var hardenedRuntime = false
        var adHoc = false
        var teamID: String?
        var signer: String?
    }

    /// Leest de eigen handtekening, zodat het Over-venster toont wat er echt is ondertekend.
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

    /// Alle informatie als platte tekst, voor het Over-venster en om te kopiëren.
    static var summary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon (arm64)"
        #else
        let arch = "Intel (x86_64)"
        #endif
        let dutch = Date.FormatStyle(date: .long, time: .shortened, locale: Locale(identifier: "nl_NL"))
        let built = buildDate.map { $0.formatted(dutch) } ?? "onbekend"
        let dirty = commit.hasSuffix("-dirty")
        let commitText = dirty
            ? "\(commit.dropLast("-dirty".count)), met niet-gecommitte wijzigingen"
            : commit

        let signing: String
        let runtime: String
        if let signature {
            if signature.adHoc {
                signing = "lokaal (ad-hoc), niet genotariseerd"
            } else {
                signing = [signature.signer, signature.teamID.map { "team \($0)" }]
                    .compactMap { $0 }.joined(separator: ", ")
            }
            runtime = signature.hardenedRuntime ? "aan" : "uit"
        } else {
            signing = "niet ondertekend"
            runtime = "uit"
        }

        return """
        Shoot first, store later.

        Versie \(version), build \(build)
        Gebouwd: \(built)
        Commit: \(commitText)

        macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) op \(arch), vereist 13.0 of nieuwer
        App Sandbox: \(Store.isSandboxed ? "aan" : "uit")
        Hardened Runtime: \(runtime)
        Handtekening: \(signing)
        Klembord ophalen: \(Store.shared.watchClipboard ? "aan" : "uit")

        Broncode: github.com/vdKolk/screenshot-hub
        """
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString(string: summary, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        let link = "github.com/vdKolk/screenshot-hub"
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

@main
struct ScreenshotHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup("Screenshot Hub") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Over Screenshot Hub") { AppInfo.showAboutPanel() }
                Button("Kopieer versie-informatie") { AppInfo.copySummary() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nieuwe screenshot") { store.captureToMemory() }
                    .keyboardShortcut("n")
                    .disabled(store.isCapturing)
                Button("Selectie opslaan") { store.saveMemory(Array(store.memorySelection)) }
                    .keyboardShortcut("s")
                    .disabled(store.memorySelection.isEmpty)
                Button("Alles uit geheugen opslaan") { store.saveMemory(store.memoryShots.map(\.id)) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.memoryShots.isEmpty)
            }
            CommandMenu("Hot Spaces") {
                ForEach(Array(store.hotSpaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button("Naar \(space.name)") { store.deliverSelection(to: space) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .disabled(!store.hasSelection)
                }
                Divider()
                Button("Hot Space toevoegen…") { store.addHotSpace() }
                // Geen sneltoets hier: Escape wordt in Store afgehandeld, zodat het zoekveld hem houdt.
                Button("Selectie wissen (Esc)") {
                    store.selection = []
                    store.memorySelection = []
                }
                .disabled(!store.hasSelection)
            }
        }
    }
}

// MARK: - Hoofdvenster

struct ContentView: View {
    @EnvironmentObject var store: Store
    @LocalState private var search = ""
    @LocalState private var anchor: URL?
    @LocalState private var memoryAnchor: UUID?

    private var filtered: [Shot] {
        guard !search.isEmpty else { return currentFiles }
        return currentFiles.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    /// De bestanden van de tab die openstaat: de screenshotmap of een Hot Space.
    private var currentFiles: [Shot] {
        store.tab == .stored ? store.shots : store.spaceShots
    }

    var body: some View {
        HStack(spacing: 0) {
            HotSpacesPanel()
                .frame(width: 270)
            Divider()
            VStack(spacing: 0) {
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
        .overlay(alignment: .bottom) { toastView }
        .animation(.spring(response: 0.3), value: store.toast)
    }

    private var tabBar: some View {
        Picker("Weergave", selection: $store.tab) {
            Text(store.memoryShots.isEmpty ? "In geheugen" : "In geheugen (\(store.memoryShots.count))")
                .tag(Store.Tab.memory)
            Text("Opgeslagen (\(store.shots.count))")
                .tag(Store.Tab.stored)
            // Een geopende Hot Space krijgt een eigen tab, die weer verdwijnt als je terugwisselt.
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

    // MARK: In geheugen

    private var memorySummary: String {
        let count = store.memoryShots.count
        guard count > 0 else { return "Niet opgeslagen" }
        let bytes = store.memoryShots.reduce(0) { $0 + $1.png.count }
        return "Niet opgeslagen · "
            + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private var memoryHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip").foregroundStyle(.orange)
            Text(memorySummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Toggle("Klembord ophalen", isOn: $store.watchClipboard)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Afbeeldingen die op het klembord komen, zoals een screenshot met ⌃⌘⇧4, verschijnen hier. "
                      + "Inhoud die een app als vertrouwelijk of tijdelijk markeert, zoals uit een wachtwoordmanager, wordt overgeslagen.")
            Button("Alles opslaan") { store.saveMemory(store.memoryShots.map(\.id)) }
                .disabled(store.memoryShots.isEmpty)
                .help("Alles opslaan in \(store.sourceFolder.lastPathComponent) (⌘⇧S)")
            Button { store.captureToMemory() } label: {
                Label("Screenshot maken", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isCapturing)
            .help("Kies een gebied, of druk op spatie voor een venster. Hij komt alleen in het geheugen (⌘N)")
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
                        .onTapGesture { handleMemoryTap(shot) }
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
                    Text("Nog niets in het geheugen")
                        .font(.headline)
                    Text(store.watchClipboard
                         ? "Klik op Screenshot maken (⌘N) of maak er een met ⌃⌘⇧4. Hij komt hier en is nog niet opgeslagen."
                         : "Klik op Screenshot maken (⌘N). Zet Klembord ophalen aan om ook screenshots met ⌃⌘⇧4 hier te krijgen.")
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
        Button("Opslaan in \(store.sourceFolder.lastPathComponent)") { store.saveMemory(targets) }
        if !store.hotSpaces.isEmpty {
            Menu("Opslaan in Hot Space") {
                ForEach(store.hotSpaces) { space in
                    Button(space.name) { store.deliver([], memory: targets, to: space) }
                }
            }
        }
        Button("Kopieer afbeelding") { store.copyToClipboard(shot) }
        Divider()
        Button("Weggooien") { store.discardMemory(targets) }
    }

    private func handleMemoryTap(_ shot: MemoryShot) {
        applyClick(on: shot.id, order: store.memoryShots.map(\.id),
                   selection: &store.memorySelection, anchor: &memoryAnchor)
    }

    // MARK: Opgeslagen

    private var storedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if store.hasSourceAccess {
                Text(displayPath(store.sourceFolder.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Wijzig…") { store.chooseSourceFolder() }
                    .buttonStyle(.link)
            } else {
                Text("Nog geen screenshotmap gekozen")
                    .foregroundStyle(.secondary)
                Button("Kies map…") { store.chooseSourceFolder() }
                    .buttonStyle(.link)
            }
            Spacer()
            TextField("Zoek op naam", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Toggle("Alleen screenshots", isOn: $store.onlyScreenshots)
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
            Button("Toon in Finder") { NSWorkspace.shared.open(space.url) }
                .buttonStyle(.link)
            Spacer()
            TextField("Zoek op naam", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Text("\(filtered.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { store.tab = .stored } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Sluit \(space.name)")
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
                        // Eén tapgebaar, zodat een gewone klik niet wacht op een mogelijke dubbelklik.
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
                    Text("Kies eerst je screenshotmap")
                        .font(.headline)
                    Text("Screenshot Hub mag alleen bij mappen die je zelf kiest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Kies map…") { store.chooseSourceFolder() }
                        .padding(.top, 4)
                }
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "Nog geen screenshots in deze map" : "Geen screenshots met deze naam")
                        .font(.headline)
                    Text(!search.isEmpty ? "Pas je zoekterm aan."
                         : store.tab == .stored ? "Maak er een met ⌘⇧4 of ⌘⇧5, of sla er een op vanuit In geheugen."
                         : "Sleep screenshots op deze Hot Space om ze hier op te slaan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func shotMenu(_ shot: Shot) -> some View {
        let targets = store.selection.contains(shot.url) ? Array(store.selection) : [shot.url]
        Button("Openen") { NSWorkspace.shared.open(shot.url) }
        Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button("Kopieer afbeelding") { store.copyToClipboard(shot.url) }
        if !store.hotSpaces.isEmpty {
            Menu("Naar Hot Space") {
                // De Hot Space waar de screenshot al in staat, heeft geen zin als doel.
                ForEach(store.hotSpaces.filter { $0.id != store.viewedSpace?.id }) { space in
                    Button(space.name) { store.deliver(targets, to: space) }
                }
            }
        }
        Divider()
        Button("Naar prullenmand") { store.trash(targets) }
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
                    Button("Ongedaan maken") { store.undoLast() }
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

// MARK: - Screenshotkaarten

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
                    Text("Niet opgeslagen")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    // verbatim: anders maakt SwiftUI van 1600 "1.600".
                    Text(verbatim: "\(shot.date.formatted(date: .omitted, time: .standard)) · \(shot.pixelWidth)×\(shot.pixelHeight)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button("Opslaan") { store.saveMemory([shot.id]) }
                    .controlSize(.small)
                    .help("Opslaan in \(store.sourceFolder.lastPathComponent)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        // Gestippelde oranje rand: dit bestaat nog alleen in het geheugen.
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : Color.orange.opacity(0.5),
                          style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 3])))
        .contentShape(Rectangle())
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

// MARK: - Hot Spaces

struct HotSpacesPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hot Spaces").font(.title3.weight(.semibold))
                Spacer()
                Button { store.addHotSpace() } label: { Image(systemName: "plus") }
                    .help("Map toevoegen als Hot Space")
            }

            if store.hotSpaces.isEmpty {
                Text("Voeg een map toe met +. Sleep daarna een screenshot op een Hot Space om hem daar op te slaan.")
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
                Text("Opgeslagen screenshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Opgeslagen screenshots", selection: $store.moveFiles) {
                    Text("Verplaatsen").tag(true)
                    Text("Kopiëren").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Selecteer screenshots en druk ⌘1 t/m ⌘9, of klik op een Hot Space. Screenshots uit het geheugen worden daar opgeslagen.")
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
        // Tegel en oog zijn twee knoppen naast elkaar, niet in elkaar: zo kan de tegel
        // de klik op het oog nooit afvangen en de selectie hierheen sturen.
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
                  ? "Klik om de selectie naar \(space.name) te sturen"
                  : "Klik om te bekijken wat er in \(space.name) staat, of sleep screenshots hierheen")

            Button { store.openSpace(space) } label: {
                Image(systemName: viewed ? "eye.fill" : "eye")
                    .foregroundStyle(viewed ? color : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bekijk wat er in \(space.name) staat")
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
            Button("Bekijken") { store.openSpace(space) }
            Button("Toon in Finder") { NSWorkspace.shared.open(space.url) }
            Button("Verwijder Hot Space") { store.removeHotSpace(space) }
        }
    }

    /// Met een selectie stuurt een klik die hierheen; zonder selectie open je de Hot Space.
    private func tileClicked() {
        if store.hasSelection {
            store.deliverSelection(to: space)
        } else {
            store.openSpace(space)
        }
    }
}
