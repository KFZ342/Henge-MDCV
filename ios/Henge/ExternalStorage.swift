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

    private let lock = NSLock()
    private var bookmark: Data?
    private var scopedFolder: URL?
    /// The drive's name as last seen, so it can be asked for by name while it is away.
    private var knownVolume: String?
    private let defaultsKey = "henge.external.folder"
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
        knownVolume = UserDefaults.standard.string(forKey: volumeKey)
        enabled = bookmark != nil
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
        UserDefaults.standard.removeObject(forKey: defaultsKey)
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
        guard let data = bookmark else { return }
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
