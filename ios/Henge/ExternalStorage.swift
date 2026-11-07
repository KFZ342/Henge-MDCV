import Foundation
import SwiftUI

/// A folder on an outside volume — a USB drive, an SD card — used as Henge's
/// own space: restore images are downloaded there, new Macs are made there,
/// and they run straight off it. Nothing about a Mac on the drive is copied
/// onto this device; the engine reads and writes its disk image where it lies.
///
/// The folder is picked once in Settings and kept as a bookmark, so the access
/// the Files picker granted survives relaunches without asking again. With the
/// drive unplugged, Macs on it simply wait (their RAM file still sits on this
/// device while they run: the kernel writes it out as it pleases, and no drive
/// is fast enough to serve guest RAM).
final class ExternalStorage: ObservableObject {
    static let shared = ExternalStorage()

    /// A drive that has been used before. Its bookmark is kept, so switching between
    /// two drives — one at home, one in a bag — is a tap rather than a trip to the picker.
    struct KnownDrive: Identifiable, Codable, Hashable {
        var id: UUID
        var name: String
        var bookmark: Data
        var lastUsed: Date
    }

    /// A folder has been picked, whether or not its drive is connected.
    @Published private(set) var enabled = false
    /// The drive's name, when it is connected.
    @Published private(set) var volumeName: String?
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var lastError: String?
    /// Up to four drives used before, most recent first.
    @Published private(set) var known: [KnownDrive] = []
    /// Disconnected on purpose: the bookmark is kept, and the drive is not picked up again
    /// until Reconnect (or a new choice). This is what makes unplugging safe to do.
    @Published private(set) var paused = false
    /// A drive that cannot keep holes pays for the whole 64 GB disk image: worth saying.
    @Published private(set) var supportsSparse = true
    /// Drives found plugged in, when there is more than one to ask about.
    @Published private(set) var detected: [VolumeCandidate] = []
    /// A dialog is up asking which of them to use.
    @Published var askingForVolume = false

    /// A drive found without the Files picker: its volume root, and what it has room for.
    struct VolumeCandidate: Identifiable, Hashable {
        let url: URL
        let name: String
        let free: Int64?
        var id: String { url.path }
    }

    private let lock = NSLock()
    private var bookmark: Data?
    private var plainPath: String?
    private var scopedFolder: URL?
    /// The drive's name as last seen, so it can be asked for by name while it is away.
    private var knownVolume: String?
    private let defaultsKey = "henge.external.folder"
    /// A drive used without a bookmark: its path, found by looking at what is mounted.
    private let pathKey = "henge.external.path"
    private let volumeKey = "henge.external.volume"
    private let knownKey = "henge.external.known"

    // MARK: State

    /// The picked folder, from any thread; nil while its drive is away (or none was picked).
    var folder: URL? { lock.lock(); defer { lock.unlock() }; return scopedFolder }
    var available: Bool { folder != nil }
    /// The bookmark in use, so a remembered drive can be told apart from it.
    var currentBookmark: Data? { bookmark }

    /// The Mac running from the drive right now, if one is: no drive change may strand it.
    @MainActor private var runningOnDrive: VirtualMac? {
        guard let id = MacRun.current,
              let mac = Machines.shared.all.first(where: { $0.id == id }),
              mac.external == true else { return nil }
        return mac
    }

    /// Where Macs on the drive live, and where restore images are downloaded to.
    var machinesRoot: URL? { folder?.appendingPathComponent("Machines", isDirectory: true) }
    var imageDirectory: URL? { folder?.appendingPathComponent("Restore images", isDirectory: true) }
    func machineDirectory(_ id: UUID) -> URL? { machinesRoot?.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Why Macs on the drive cannot be used right now; nil when they can.
    func awayText() -> String {
        if paused { return "Henge disconnected the drive on purpose. Reconnect it in Settings." }
        guard enabled else { return "External storage is turned off in Settings, and this Mac lives on the drive." }
        return knownVolume.map { "Plug in \($0) to use this Mac." } ?? "Plug in the drive this Mac lives on."
    }

    private init() {
        bookmark = UserDefaults.standard.data(forKey: defaultsKey)
        plainPath = UserDefaults.standard.string(forKey: pathKey)
        knownVolume = UserDefaults.standard.string(forKey: volumeKey)
        enabled = bookmark != nil || plainPath != nil
        known = Self.readKnown()
        resolve()
        watch()
    }

    private static func readKnown() -> [KnownDrive] {
        guard let data = UserDefaults.standard.data(forKey: "henge.external.known"),
              let drives = try? JSONDecoder().decode([KnownDrive].self, from: data) else { return [] }
        return Array(drives.prefix(4))
    }

    private func saveKnown() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        UserDefaults.standard.set(data, forKey: knownKey)
    }

    // MARK: Choosing

    /// A folder picked in the Files picker: bookmarked, and used from now on.
    @MainActor func choose(_ url: URL) {
        // The picker's grant covers this call, so the checks can be made against the folder itself.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if Installer.shared.busy {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Wait for the install to finish before changing drives."])
            }
            if let mac = runningOnDrive {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Shut down \(mac.name) before changing the drive: its disk is on it and still being written."])
            }
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            if values.isUbiquitousItem == true {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "That folder is in iCloud Drive. Pick one on a drive plugged into this \(Device.name)."])
            }
            // Some drives mount read-only, or the cable is bad: better to find out now
            // than halfway through a 16 GB download.
            let probe = url.appendingPathComponent(".henge-write-test")
            try Data("x".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            let data = try url.bookmarkData() // iOS keeps the picker's grant to it in the bookmark
            UserDefaults.standard.set(data, forKey: defaultsKey)
            UserDefaults.standard.removeObject(forKey: pathKey)
            plainPath = nil
            bookmark = data
            enabled = true
            paused = false
            lastError = nil
            resolve()
            remember(url, bookmark: data)
            HengeLog.log("external", "using \(url.path)")
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }

    // MARK: Finding a drive without the Files picker

    /// Looks at what is mounted and uses the only drive there, or asks which one when
    /// several are plugged in. iPadOS does not let a picker select the root of a volume,
    /// which is what makes this the way a drive gets chosen when it is the only one in.
    @MainActor func pickDrive() {
        guard !Installer.shared.busy else {
            lastError = "Wait for the install to finish before changing drives."
            return
        }
        if let mac = runningOnDrive {
            lastError = "Shut down \(mac.name) before changing the drive: its disk is on it and still being written."
            return
        }
        detected = Self.scanVolumes()
        if detected.isEmpty {
            lastError = "No drive is plugged in. Plug it in, wait for the Files app to show it, then try again."
            return
        }
        if detected.count == 1 { use(detected[0]) } else { askingForVolume = true }
    }

    /// Uses a drive found by scanning. Writing is probed first: a volume the app cannot
    /// write to would otherwise fail hours into an install.
    @MainActor func use(_ volume: VolumeCandidate) {
        let url = volume.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let probe = url.appendingPathComponent(".henge-write-test")
            try Data("x".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            lastError = "iPadOS will not let Henge write to \(volume.name). Open it once in the Files app, then try again."
            return
        }
        UserDefaults.standard.set(url.path, forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        bookmark = nil
        plainPath = url.path
        enabled = true
        paused = false
        lastError = nil
        resolve()
        HengeLog.log("external", "using the drive found at \(url.path)")
    }

    /// The volumes that could be a drive: not this device's own storage, not the system's.
    static func scanVolumes() -> [VolumeCandidate] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        var urls: [URL] = []
        if let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            urls += mounted
        }
        // Volumes the system does not list there still have their folders here.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            urls += names.map { URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent($0) }
        }
        var seen = Set<String>()
        var found: [VolumeCandidate] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, path != "/", !path.hasPrefix("/private/var") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsInternal == true, values?.volumeIsRemovable != true { continue }
            var free: Int64?
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { free = Int64(important) }
            else if let plain = values?.volumeAvailableCapacity, plain > 0 { free = Int64(plain) }
            found.append(VolumeCandidate(url: url, name: values?.volumeName ?? url.lastPathComponent, free: free))
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Stops using the drive. Macs on it stay there, waiting for it to be picked again.
    @MainActor func turnOff() {
        guard !Installer.shared.busy else {
            lastError = "Wait for the install to finish before changing drives."
            return
        }
        if let mac = runningOnDrive {
            lastError = "Shut down \(mac.name) before turning the drive off."
            return
        }
        bookmark = nil
        plainPath = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
        release()
        enabled = false
        paused = false
        volumeName = nil
        freeBytes = nil
        lastError = nil
        HengeLog.log("external", "turned off")
    }

    /// Switches to a drive used before. One that is away is simply waited for, the same as a
    /// drive picked fresh: its Macs come back when it does.
    @MainActor func select(_ drive: KnownDrive) {
        guard !Installer.shared.busy else {
            lastError = "Wait for the install to finish before changing drives."
            return
        }
        if let mac = runningOnDrive {
            lastError = "Shut down \(mac.name) before changing the drive."
            return
        }
        UserDefaults.standard.set(drive.bookmark, forKey: defaultsKey)
        bookmark = drive.bookmark
        enabled = true
        paused = false
        lastError = nil
        resolve()
        if folder == nil {
            lastError = "Plug in \(drive.name) to use it."
        } else {
            touch(drive.id, name: drive.name)
        }
    }

    /// Takes a drive off the short list. The one in use stays: change drives first.
    @MainActor func forget(_ drive: KnownDrive) {
        guard drive.bookmark != bookmark else {
            lastError = "Pick another drive before forgetting \(drive.name)."
            return
        }
        known.removeAll { $0.id == drive.id }
        saveKnown()
    }

    /// Stops holding the drive without forgetting it: unplugging is then a safe thing to do.
    /// Refused while a Mac on that drive is running — its disk is still open.
    @MainActor func eject() {
        guard !Installer.shared.busy else {
            lastError = "Wait for the install to finish before disconnecting the drive."
            return
        }
        if let mac = runningOnDrive {
            lastError = "Shut down \(mac.name) first: its disk is on the drive and still being written."
            return
        }
        paused = true
        release()
        volumeName = nil
        freeBytes = nil
        lastError = nil
        HengeLog.log("external", "disconnected, bookmark kept")
    }

    /// Back to the same drive after an eject. If it is still plugged in, it is used at once.
    @MainActor func reconnect() {
        paused = false
        resolve()
        if folder == nil { lastError = "The drive is not connected yet." }
    }

    /// Keeps this drive in the short list, so going back to it is a tap rather than the picker.
    private func remember(_ url: URL, bookmark data: Data) {
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        if let at = known.firstIndex(where: { $0.bookmark == data || $0.name == name }) {
            known[at].name = name
            known[at].bookmark = data
            known[at].lastUsed = Date()
            let entry = known.remove(at: at)
            known.insert(entry, at: 0)
        } else {
            known.insert(KnownDrive(id: UUID(), name: name, bookmark: data, lastUsed: Date()), at: 0)
        }
        if known.count > 4 { known.removeLast(known.count - 4) }
        saveKnown()
    }

    private func touch(_ id: UUID, name: String) {
        guard let at = known.firstIndex(where: { $0.id == id }) else { return }
        known[at].lastUsed = Date()
        known[at].name = name
        let entry = known.remove(at: at)
        known.insert(entry, at: 0)
        saveKnown()
    }

    /// Put away a message that has been read.
    @MainActor func clearError() { lastError = nil }

    // MARK: The drive coming and going

    /// Brings the bookmark back to a folder that can be used, or notes the drive is away.
    func resolve() {
        guard !paused else { return } // disconnected on purpose, until Reconnect
        guard let data = bookmark else {
            // A drive found by looking at what is mounted has no bookmark: its path is
            // the grant the volume gives the app when it is plugged in.
            guard let path = UserDefaults.standard.string(forKey: pathKey) else { return }
            let url = URL(fileURLWithPath: path)
            release()
            guard FileManager.default.fileExists(atPath: url.path) else {
                volumeName = nil
                freeBytes = nil
                return
            }
            adopt(url)
            return
        }
        release() // the previous folder, whatever happens next
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // A bookmark for a drive that is away often does not resolve at all:
            // that is the drive being away, not the bookmark being broken.
            volumeName = nil
            freeBytes = nil
            return
        }
        if stale, let fresh = try? url.bookmarkData() {
            // Keep the short list pointing at the same drive rather than at a stale bookmark.
            if let old = bookmark, let at = known.firstIndex(where: { $0.bookmark == old }) {
                known[at].bookmark = fresh
                saveKnown()
            }
            bookmark = fresh
            UserDefaults.standard.set(fresh, forKey: defaultsKey)
        }
        // A bookmark resolves even while its volume is away; the folder itself does not.
        guard FileManager.default.fileExists(atPath: url.path) else {
            release()
            volumeName = nil
            freeBytes = nil
            return
        }
        adopt(url)
    }

    /// Holds the folder, and publishes what the volume is.
    private func adopt(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource() // held until the drive is changed or turned off
        lock.lock()
        scopedFolder = url
        lock.unlock()
        refreshVolume()
        HengeLog.log("external", "drive on: \(url.path)")
    }

    /// Stops holding the picked folder, and forgets it as the current one.
    private func release() {
        lock.lock()
        let url = scopedFolder
        scopedFolder = nil
        lock.unlock()
        url?.stopAccessingSecurityScopedResource()
    }

    private func refreshVolume() {
        guard let current = folder else { return }
        let values = try? current.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeSupportsSparseFilesKey])
        volumeName = values?.volumeName
        freeBytes = values?.volumeAvailableCapacityForImportantUsage
        supportsSparse = values?.volumeSupportsSparseFiles ?? true
        if let name = values?.volumeName, name != knownVolume {
            knownVolume = name // remembered, so the drive can be asked for by name while it is away
            UserDefaults.standard.set(name, forKey: volumeKey)
        }
    }

    /// Notices the drive being plugged in and unplugged, and keeps its figures current.
    private func watch() {
        Task { @MainActor in
            while true {
                // Resolving a bookmark for a drive that is away can take a moment,
                // so its checks come less often than the cheap ones while it is in.
                try? await Task.sleep(nanoseconds: self.folder == nil ? 6_000_000_000 : 2_000_000_000)
                guard self.enabled, !self.paused else { continue }
                if let current = self.folder {
                    if !FileManager.default.fileExists(atPath: current.path) { self.resolve() } // pulled out
                    else { self.refreshVolume() }
                } else {
                    self.resolve() // plugged back in
                }
            }
        }
    }
}
