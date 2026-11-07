import Foundation
import UIKit

/// A Mac made on the Mac (HengeVM or Henge) and brought over: its boot ROM,
/// disk and auxiliary storage, and the identity it was installed with.
struct VirtualMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ecid: UInt64
    var seed: UInt64
    var ramMB: Int
    var diskBytes: Int64
    var added = Date()
    var osName: String?
    var lastUsed: Date?
    /// The size macOS is told its screen is. Macs made before this was a choice have none: 16:9.
    var screenWidth: Int?
    var screenHeight: Int?
    /// How many CPUs this Mac starts with. Macs made before it was a per-Mac setting have none: 4.
    var cpus: Int?
    /// True when this Mac's files live on the outside drive (ExternalStorage);
    /// nil or false when they live on this device.
    var external: Bool?
    var screen: (width: Int, height: Int) { (screenWidth ?? 1920, screenHeight ?? 1080) }
    var aspect: CGFloat { CGFloat(screen.width) / CGFloat(screen.height) }

    var directory: URL {
        if external == true, let drive = ExternalStorage.shared.machineDirectory(id) { return drive }
        return Machines.directory(for: id)
    }
    /// Why this Mac cannot be used right now: the drive it lives on is away, or the one
    /// that is in is a different drive. nil when it can be used.
    var unavailableReason: String? {
        guard external == true else { return nil }
        guard let drive = ExternalStorage.shared.folder else { return ExternalStorage.shared.awayText() }
        guard FileManager.default.fileExists(atPath: drive.appendingPathComponent("Machines/\(id.uuidString)").path) else {
            return "This Mac lives on another drive; plug that one in."
        }
        return nil
    }
    var rom: URL { directory.appendingPathComponent("AVPBooter.vmapple2.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("auxiliary.bin") }
}

/// How much RAM a Mac gets. The engine first asks the kernel to leave it out of Henge's footprint,
/// which is allowed once a debugger has attached (how JIT is turned on). If that is refused it uses
/// a file beside the disk: iOS's memory limit does not count a mapped file's pages either.
enum GuestMemory {
    /// Points the engine at the file (it is unlinked as soon as it is open) and returns the size that fits.
    static func prepare(_ mac: VirtualMac) -> UInt64 {
        // The RAM file stays on this device even for Macs on an outside drive:
        // the kernel writes it out as it pleases, and no drive is fast enough
        // to serve guest RAM.
        let file = Machines.root.appendingPathComponent("ram-\(mac.id.uuidString).tmp")
        setenv("HV_RAM_FILE", file.path, 1)
        let free = (try? Machines.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let room = free > 0 ? UInt64(max(free - (2 << 30), 0)) >> 20 : UInt64.max
        let reach = henge_largest_mapping_mb()
        let ram = min(UInt64(mac.ramMB), room, reach > 512 ? reach - 512 : 0) / 512 * 512
        HengeLog.log("session", "guest RAM \(ram) MB (asked \(mac.ramMB), disk room \(room), largest mapping \(reach))")
        return ram
    }
}

/// machine.json in an exported folder (tools/export_ios.sh writes it).
private struct MachineFile: Codable {
    var name: String?
    var ecid: UInt64
    var seed: UInt64?
    var ramMB: Int?
    var cpus: Int?
}

/// Whether a machine has already run in this process. The engine keeps one
/// (henge-vm.c's `state`): after any Mac has started or installed, another start
/// fails with an engine message, so the app must say so before it happens.
enum Launch {
    static var used: Bool { henge_vm_state() != 0 }
    static let explanation = "Henge runs one Mac per launch. Quit Henge (swipe it away) and open it again to start another."
}

/// Which Mac the engine is running right now. A drive holding that Mac's disk must not be
/// let go of while it runs, so this is what Safely Disconnect checks before it agrees.
enum MacRun {
    static var current: UUID?
}

@MainActor
final class Machines: ObservableObject {
    static let shared = Machines()

    @Published private(set) var all: [VirtualMac] = []
    @Published private(set) var importing: String?
    @Published var lastError: String?

    /// The files an exported machine folder holds; its disk is disk.img, or disk.img.hvsparse (tools/export_ios.sh packs it).
    static let required = ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json"]
    static let packedDisk = "disk.img.hvsparse"

    nonisolated static func hasDisk(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(packedDisk).path)
    }

    @Published private(set) var unpacked: Double = 0
    /// While a Mac is being exported: its name and how far along.
    @Published private(set) var exporting: String?
    @Published private(set) var exported: Double = 0
    /// The last finished export, ready to be moved out of Henge.
    @Published var lastExport: URL?
    /// While a Mac is being moved between this device and the outside drive: its name, and how far along.
    @Published private(set) var moving: String?
    @Published private(set) var relocated: Double = 0

    /// Whether machines.json itself could be read. Without it, folders are not evidence of orphans.
    private var listRead = false

    private init() {
        listRead = load()
        // Only tidy up after the list itself was read: if machines.json cannot be
        // decoded, every folder would look unreferenced — and those are Macs.
        if listRead { removeLeftovers() }
    }

    /// Machine folders nothing refers to (an install cut short by a crash or by quitting): their disks take real space.
    private func removeLeftovers() { tidy(Self.root) }

    /// The same tidying for the outside drive, done before an install there and when the drive
    /// comes back. A restore that died leaves a disk image behind; the next install must not
    /// count it as free space, and nothing else would ever remove it.
    /// Skipped while something is being moved or brought in: their folders exist before their
    /// entries do.
    func tidy(_ root: URL) {
        guard listRead, importing == nil, moving == nil, !Installer.shared.busy else { return }
        let known = Set(all.map(\.id))
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            // Guest RAM files are unlinked as soon as the engine opens them, so at launch —
            // with nothing running — any that are left are from a crash during a boot.
            if item.lastPathComponent.hasPrefix("ram-"), item.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            guard let id = UUID(uuidString: item.lastPathComponent), !known.contains(id) else { continue }
            HengeLog.log("machines", "removing the unfinished machine \(id)")
            try? FileManager.default.removeItem(at: item)
        }
    }

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Machines", isDirectory: true)
    }
    nonisolated static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Where Finder file sharing puts what the user drops on Henge.
    nonisolated static var inbox: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Folders dropped into Henge's Documents over Finder (or the Files app) that look like
    /// an exported machine are moved in. A move, not a copy: a disk image is tens of gigabytes.
    func collectImports() {
        Task { await collect() }
    }

    private func collect() async {
        guard importing == nil, let items = try? FileManager.default.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil) else { return }
        for folder in items where Self.hasDisk(folder) && Self.required.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            await adopt(folder, move: true)
        }
    }

    /// A folder chosen in the Files picker: copied (it may be on another volume).
    func importFolder(_ folder: URL) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adopt(folder, move: false)
        }
    }

    private func adopt(_ folder: URL, move: Bool) async {
        var dest: URL?
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("machine.json"))
            let info = try JSONDecoder().decode(MachineFile.self, from: data)
            let missing = Self.required.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            guard missing.isEmpty, Self.hasDisk(folder) else { throw message("The folder is missing \((missing + (Self.hasDisk(folder) ? [] : ["disk.img"])).joined(separator: ", ")).") }
            var mac = VirtualMac(name: info.name ?? folder.lastPathComponent, ecid: info.ecid, seed: info.seed ?? 0,
                                 ramMB: info.ramMB ?? 2048, diskBytes: 0)
            mac.cpus = info.cpus
            importing = mac.name
            unpacked = 0
            // With a drive on, brought-in Macs are placed there too.
            if ExternalStorage.shared.folder != nil { mac.external = true }
            dest = mac.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest!, withIntermediateDirectories: true)
            excludeFromBackup()
            for name in ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json", "disk.img"] {
                let from = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if move { try fm.moveItem(at: from, to: dest!.appendingPathComponent(name)) }
                else { try fm.copyItem(at: from, to: dest!.appendingPathComponent(name)) }
            }
            let packed = folder.appendingPathComponent(Self.packedDisk)
            if fm.fileExists(atPath: packed.path) {
                // Off the main thread: unpacking tens of gigabytes takes minutes.
                let target = mac.disk.path, source = packed.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else { try? fm.removeItem(at: dest); throw message("The packed disk could not be unpacked (not enough space?).") }
                if move { try? fm.removeItem(at: packed) }
            }
            if move { try? fm.removeItem(at: folder) }
            mac.diskBytes = (try? fm.attributesOfItem(atPath: mac.disk.path)[.size] as? Int64) ?? 0
            all.append(mac)
            save()
            HengeLog.log("machines", "imported \(mac.name) (ECID \(mac.ecid), \(mac.diskBytes >> 30) GB disk)")
        } catch {
            // A copy that was cut short leaves a half-made machine behind; a move does not,
            // for the source may already be half-consumed and must be left as it is.
            if !move, let dest { try? FileManager.default.removeItem(at: dest) }
            lastError = error.localizedDescription
            HengeLog.log("machines", "import of \(folder.lastPathComponent) failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    /// Makes a folder "Bring in a Mac" can read back (the same files tools/export_ios.sh writes),
    /// in Documents/Exports, which the Files app can reach. Deleting Henge deletes that folder too,
    /// so it has to be moved out of Henge before a reinstall that replaces the app's data.
    func export(_ mac: VirtualMac) {
        guard exporting == nil, importing == nil else { return }
        // A running Mac's disk changes under the copy; what came out would not boot.
        guard MacRun.current != mac.id else {
            lastError = "Shut down \(mac.name) before exporting it."
            return
        }
        exporting = mac.name
        exported = 0
        lastExport = nil
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true // a locked screen would suspend the app mid-way
        Task {
            defer {
                exporting = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { lastExport = try await writeExport(mac) } catch {
                lastError = error.localizedDescription
                HengeLog.log("machines", "export of \(mac.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ mac: VirtualMac) async throws -> URL {
        let fm = FileManager.default
        let exports = Self.inbox.appendingPathComponent("Exports", isDirectory: true)
        let safeName = mac.name.replacingOccurrences(of: "/", with: "-")
        let final = exports.appendingPathComponent(safeName, isDirectory: true)
        // Not under its final name until it is whole, so a cut-short export can't be mistaken for a Mac.
        let partial = exports.appendingPathComponent(safeName + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: final)
        let used = (try? mac.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
        let free = (try? Self.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Int64(used) + (256 << 20)
        if free > 0 && free < needed {
            throw message("Exporting \(mac.name) needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(free))). Deleting a downloaded macOS installer (Install macOS, swipe it) frees about 16 GB.")
        }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: mac.rom, to: partial.appendingPathComponent("AVPBooter.vmapple2.bin"))
            try fm.copyItem(at: mac.aux, to: partial.appendingPathComponent("auxiliary.bin"))
            let info: [String: Any] = ["name": mac.name, "ecid": mac.ecid, "seed": mac.seed, "ramMB": mac.ramMB,
                                       "cpus": mac.cpus ?? 4]
            try JSONSerialization.data(withJSONObject: info).write(to: partial.appendingPathComponent("machine.json"))
            let source = mac.disk.path, target = partial.appendingPathComponent(Self.packedDisk).path
            let ok = await Task.detached { () -> Bool in
                hv_sparse_pack_progress(source, target, { done, total, _ in
                    let fraction = Double(done) / Double(max(total, 1))
                    Task { @MainActor in Machines.shared.exported = fraction }
                }, nil) == 0
            }.value
            guard ok else { throw message("The disk could not be written (not enough space?).") }
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        HengeLog.log("machines", "exported \(mac.name) to \(final.path)")
        return final
    }

    /// Moves a Mac onto the outside drive, or back onto this device. Between
    /// volumes a move is a copy of tens of gigabytes, so it takes about as
    /// long as one; the name and the progress are shown while it goes.
    func relocate(_ mac: VirtualMac, toDrive: Bool) async {
        guard mac.external != toDrive, moving == nil else { return }
        // A running Mac is writing to its disk: moving its folder would yank the disk
        // out from under the engine, on the drive or off it.
        guard MacRun.current != mac.id else {
            lastError = "Shut down \(mac.name) before moving it."
            return
        }
        // Moving off a drive that is not in would "move" a folder that does not exist.
        if mac.external == true, ExternalStorage.shared.folder == nil {
            lastError = "Plug in the drive before moving \(mac.name) off it."
            return
        }
        guard let target = toDrive ? ExternalStorage.shared.machineDirectory(mac.id) : Self.directory(for: mac.id) else {
            lastError = "Plug the drive in first."
            return
        }
        let source = mac.directory // resolved now, while the drive is in
        let fm = FileManager.default
        // What the move carries: the logical size, since a copy may expand a sparse disk.
        let carried = Self.folderBytes(source)
        let free = (try? target.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if carried > 0, free > 0, free < carried + (1 << 30) {
            lastError = "There is only \(ByteText.string(UInt64(free))) free where \(mac.name) would go; it needs about \(ByteText.string(UInt64(carried)))."
            return
        }
        moving = mac.name
        relocated = 0
        defer { moving = nil; relocated = 0 }
        // Watches the destination grow, since FileManager reports nothing about a move.
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let done = Self.folderBytes(target)
                self.relocated = carried > 0 ? min(Double(done) / Double(carried), 1) : 0
            }
        }
        defer { monitor.cancel() }
        do {
            try await Task.detached(priority: .utility) { () -> Void in
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: source, to: target)
            }.value
            var moved = mac
            moved.external = toDrive ? true : nil
            update(moved)
            HengeLog.log("machines", "\(mac.name) now lives \(toDrive ? "on the drive" : "on this device")")
        } catch {
            // A cross-volume move that failed midway can leave a partial copy behind.
            try? fm.removeItem(at: target)
            lastError = "\(mac.name) could not be moved (\((error as NSError).localizedDescription))."
        }
    }

    /// The logical size of everything in a machine folder.
    nonisolated private static func folderBytes(_ folder: URL) -> Int64 {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for item in items {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// A machine made here (the installer), already in its directory.
    func add(_ mac: VirtualMac) {
        all.removeAll { $0.id == mac.id }
        all.append(mac)
        save()
    }

    /// Dismisses the page's notice. A message from a move that failed an hour ago
    /// should not sit at the top of the page as if it had just happened.
    func clearError() { lastError = nil }

    func update(_ mac: VirtualMac) {
        guard let i = all.firstIndex(where: { $0.id == mac.id }) else { return }
        all[i] = mac
        save()
    }

    func delete(_ id: UUID) {
        if let mac = all.first(where: { $0.id == id }) {
            // A running Mac is writing to its disk right now: removing it would unlink a
            // file the engine still holds, and the guest's next write lands in nothing.
            guard MacRun.current != id else {
                lastError = "Shut down \(mac.name) before deleting it."
                return
            }
            // Its disk is on a drive that is away: deleting the entry would leave the
            // disk behind with nothing pointing at it.
            guard mac.external != true || ExternalStorage.shared.folder != nil else {
                lastError = "Plug in the drive before deleting \(mac.name)."
                return
            }
            try? FileManager.default.removeItem(at: mac.directory)
            try? FileManager.default.removeItem(at: Self.directory(for: id)) // files it may still hold on this device
        }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("ram-\(id.uuidString).tmp"))
        all.removeAll { $0.id == id }
        save()
    }

    private var listURL: URL { Self.root.appendingPathComponent("machines.json") }

    /// Disk images are tens of gigabytes: keep them out of iCloud and computer backups.
    private func excludeFromBackup() { Self.excludeFromBackup(Self.root) }

    nonisolated static func excludeFromBackup(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Reads the list. False when there is none, or when it cannot be decoded: then
    /// nothing may be deleted on the strength of it.
    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: listURL), let list = try? JSONDecoder().decode([VirtualMac].self, from: data) else { return false }
        // Macs on the outside drive are kept even while it is unplugged: they come back with it.
        all = list.filter { $0.external == true || FileManager.default.fileExists(atPath: $0.disk.path) }
        return true
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        excludeFromBackup()
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: listURL, options: .atomic) }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
