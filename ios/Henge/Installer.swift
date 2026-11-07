import Foundation
import UIKit

/// A macOS restore image Apple publishes for virtual Macs (VirtualMac2,1).
struct MacOSRelease: Identifiable, Hashable {
    let id: String        // build
    let name: String
    let url: URL
    let bytes: Int64
    let note: String

    /// The builds offered, newest last. Apple's catalog (mesu.apple.com) only lists the newest;
    /// these are the same images from Apple's CDN, and Apple still signs them for virtual Macs.
    static let all: [MacOSRelease] = [
        MacOSRelease(id: "24G90", name: "macOS Sequoia 15.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
                     bytes: 16_035 << 20, note: "Recommended: the version Henge is tested with."),
        MacOSRelease(id: "25G83", name: "macOS Tahoe 26.6.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
                     bytes: 18_856 << 20, note: "Not tested with Henge yet."),
        MacOSRelease(id: "26B123", name: "macOS 27.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw")!,
                     bytes: 24_409 << 20, note: "The newest. Not tested with Henge yet."),
    ]
}

/// Downloads a restore image and installs it on a new virtual Mac, on the
/// iPhone: the machine boots its ROM in DFU mode and the restore runs over its
/// USB port, as Virtualization.framework's installer does on a Mac.
@MainActor
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    enum Phase: Equatable {
        case idle
        case downloading
        case preparing
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var step: Int = 0
    @Published private(set) var stepProgress: Double = 0
    @Published private(set) var machineName = ""

    private var session: URLSession?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    // The streaming download's state, touched only from its session's delegate queue.
    nonisolated(unsafe) private var partURL: URL?
    nonisolated(unsafe) private var partHandle: FileHandle?
    nonisolated(unsafe) private var partStart: Int64 = 0
    nonisolated(unsafe) private var partTotal: Int64 = 0
    nonisolated(unsafe) private var partAt: Int64 = 0
    nonisolated(unsafe) private var partProgressAt: Double = 0

    var busy: Bool {
        switch phase {
        case .downloading, .preparing, .installing: return true
        default: return false
        }
    }

    nonisolated static var imageDirectory: URL {
        // With a drive on, images are downloaded there; the download itself is
        // streamed (below) so nothing of it ever sits on this device.
        ExternalStorage.shared.imageDirectory ?? Machines.root.appendingPathComponent("Restore images", isDirectory: true)
    }
    nonisolated static func imagePath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw") }

    /// The size of the image on this iPhone, if a whole one is there (the listed sizes are rounded).
    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func deleteImage(_ r: MacOSRelease) {
        // The half of an interrupted download too, so deleting really frees the space.
        try? FileManager.default.removeItem(at: imagePath(r))
        try? FileManager.default.removeItem(at: imagePath(r).appendingPathExtension("part"))
    }

    /// Free space an install takes: the new Mac's disk, and the download if it is not here yet.
    static func spaceNeeded(_ r: MacOSRelease) -> Int64 { (haveImage(r) ? 0 : r.bytes) + newMacBytes }
    private static let newMacBytes: Int64 = 24 << 30

    func reset() { if !busy { phase = .idle } }

    func start(_ release: MacOSRelease, name: String, ramMB: Int, cpus: Int, keepImage: Bool) {
        guard !busy else { return }
        // The engine takes one Mac per launch. Saying so here keeps a race with the
        // buttons from spending a 16 GB download before the engine refuses it.
        guard !Launch.used else {
            phase = .failed("Henge runs one Mac per launch, and one has already run. Quit Henge (swipe it away), open it again, then install.")
            return
        }
        machineName = name
        UIApplication.shared.isIdleTimerDisabled = true // the screen locking would suspend the download and the restore
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            var made: VirtualMac?
            do {
                // What an earlier restore that died left on the drive is not free space.
                if let drive = ExternalStorage.shared.machinesRoot { Machines.shared.tidy(drive) }
                try checkSpace(release, ramMB: ramMB)
                let rom = try await BootROM.file() // before the long download, so a problem shows up at once
                HengeLog.log("install", "boot ROM ready")
                let ipsw = try await download(release)
                phase = .preparing
                var mac = try prepare(name: name, ramMB: ramMB, rom: rom, cpus: cpus)
                mac.osName = release.name
                made = mac
                phase = .installing
                try await install(mac, ipsw: ipsw, cpus: cpus)
                Machines.shared.add(mac)
                if !keepImage { try? FileManager.default.removeItem(at: ipsw) }
                HengeLog.log("install", "\(name): installed \(release.name)")
                phase = .done("\(release.name) is installed on \(name)\(mac.external == true ? ", on the drive" : ""). Quit Henge (swipe it away) and open it again, then tap Start. Keep the drive connected whenever it runs.")
            } catch {
                HengeLog.log("install", "failed: \(error.localizedDescription)")
                // A half-installed Mac is no use, and its disk can be many gigabytes. The download stays.
                if let made, henge_vm_state() != 1 {
                    do { try FileManager.default.removeItem(at: made.directory) }
                    catch { HengeLog.log("install", "could not remove \(made.directory.path): \(error.localizedDescription)") }
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func checkSpace(_ r: MacOSRelease, ramMB: Int) throws {
        // The Mac's memory file stays on this device even when its disk is on the drive;
        // at boot GuestMemory asks for `free - 2 GB`, so a 2 GB check here was short by the
        // whole memory size and the install failed after the download, not before it.
        let memory = Int64(ramMB) << 20
        // GuestMemory keeps 2 GB back from what it finds free, so ask for that much more.
        let headroom: Int64 = 2 << 30
        // A drive that is picked but not plugged in: say so, rather than counting space
        // on this device that will not be used.
        if ExternalStorage.shared.enabled, ExternalStorage.shared.folder == nil {
            throw message("Plug in the drive before installing on it (or turn external storage off in Settings).")
        }
        let here = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if let drive = ExternalStorage.shared.folder {
            // The image, the new Mac's disk and the restore's scratch all go on
            // the drive; this device only holds the Mac's RAM while it installs.
            let values = try? drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeSupportsSparseFilesKey, .volumeLocalizedFormatDescriptionKey])
            let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
            // A Mac's disk is one 64 GB file. FAT32 stops at 4 GB, so the restore would
            // fail hours in with a message about space; say what is actually wrong.
            let format = (values?.volumeLocalizedFormatDescription ?? "").uppercased()
            if format.contains("FAT32") || format.contains("MS-DOS") {
                throw message("This drive is formatted FAT32, and a Mac's 64 GB disk cannot live on it (that format stops at 4 GB a file). Reformat the drive as exFAT or APFS in Files or on a Mac, then try again.")
            }
            // A drive that cannot keep holes pays for the whole 64 GB disk up front.
            let disk = Self.newMacBytes + ((values?.volumeSupportsSparseFiles ?? false) ? 0 : 40 << 30)
            let needed = (Self.haveImage(r) ? 0 : r.bytes) + disk
            if free > 0 && free < needed {
                throw message("The drive needs about \(ByteText.string(UInt64(needed))) free for this install; it has \(ByteText.string(UInt64(free))).")
            }
            if here > 0 && here < memory + headroom {
                throw message("The Mac's memory stays on this \(Device.name) while it installs: about \(ByteText.string(UInt64(memory))) is needed and \(ByteText.string(UInt64(here))) is free. Choose less Memory, or free some space.")
            }
        } else {
            let needed = Self.spaceNeeded(r) + memory + headroom
            if here > 0 && here < needed {
                throw message("This install needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(here))).")
            }
        }
    }

    // MARK: Download

    /// Streams the image to wherever it belongs, chunk by chunk. URLSession's
    /// own downloads land whole in its cache, on this device's storage, first:
    /// that is what a drive is there to avoid, and with little free space it
    /// would not fit anyway.
    private func download(_ r: MacOSRelease) async throws -> URL {
        defer { discardSession() }
        // Resolve the folder once: reading it twice with the drive coming or going in between
        // could stream the part file to one volume and look for it on the other.
        let dir = Self.imageDirectory
        let dest = dir.appendingPathComponent("\(r.id).ipsw")
        let onDrive = ExternalStorage.shared.folder != nil
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Machines.excludeFromBackup(dir)
        if Self.haveImage(r) {
            HengeLog.log("install", "using the downloaded \(r.name)")
            return dest
        }
        if onDrive {
            // A copy already on this device (from before the drive was picked) saves
            // the download: moving 16 GB across the volumes beats fetching it again.
            let inside = Machines.root.appendingPathComponent("Restore images", isDirectory: true).appendingPathComponent("\(r.id).ipsw")
            let size = (try? FileManager.default.attributesOfItem(atPath: inside.path)[.size] as? Int64) ?? 0
            if size > r.bytes / 2 {
                HengeLog.log("install", "moving the downloaded \(r.name) onto the drive")
                try? FileManager.default.moveItem(at: inside, to: dest)
                if Self.haveImage(r) { return dest }
            }
        }
        phase = .downloading
        received = 0
        expected = r.bytes
        HengeLog.log("install", "downloading \(r.url.absoluteString)")
        for attempt in 1...40 {
            do {
                try await stream(r.url, to: dest.appendingPathExtension("part"))
                return dest
            } catch {
                discardSession()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if onDrive, !ExternalStorage.shared.enabled { throw message("External storage was turned off during the download.") }
                let away = onDrive && ExternalStorage.shared.folder == nil
                // The network's own hiccups, and a download that ended early (code 4: the
                // server closed without an error), clear up with another attempt; write
                // errors from a drive that has been pulled out clear up when it is back;
                // anything else (Apple's server answering oddly) will not improve.
                let ns = error as NSError
                let retryable = error is URLError || (ns.domain == "Henge" && ns.code == 4)
                if !away, !retryable { throw error }
                if attempt >= 40 { throw message("The download kept failing.") }
                HengeLog.log("install", "download interrupted (\(error.localizedDescription)); resuming")
                // While the drive is away, wait for it (plugging it back in resumes
                // where the download stopped, from the part file on it).
                try await Task.sleep(nanoseconds: away ? 8_000_000_000 : 3_000_000_000)
            }
        }
        throw message("The download kept failing.")
    }

    /// Streams from `url` into a part file beside the image, resuming at
    /// whatever of it is already there (Apple's CDN honors ranges).
    private func stream(_ url: URL, to part: URL) async throws {
        var start: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: part.path),
           let size = attrs[.size] as? NSNumber { start = size.int64Value }
        var request = URLRequest(url: url)
        if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
        partURL = part
        partStart = start
        partAt = start
        partTotal = 0     // the size of a different image must not leak into this one
        partProgressAt = 0
        discardSession() // an earlier attempt's session, its task long finished
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 48 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            downloadContinuation = c
            s.dataTask(with: request).resume()
        }
    }

    /// Lets go of the session of the last attempt, so twenty retries do not leave
    /// twenty of them (each holds its delegate and its queues) behind.
    private func discardSession() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

    /// Ends the download with the finished image, or with the error it stopped at.
    private nonisolated func succeed(_ url: URL, _ bytes: Int64) {
        Task { @MainActor in
            self.received = bytes
            guard let c = self.downloadContinuation else { return }
            self.downloadContinuation = nil
            c.resume(returning: url)
        }
    }

    private nonisolated func fail(_ error: Error) {
        Task { @MainActor in
            guard let c = self.downloadContinuation else { return }
            self.downloadContinuation = nil
            c.resume(throwing: error)
        }
    }

    // MARK: The new machine

    private func prepare(name: String, ramMB: Int, rom: URL, cpus: Int) throws -> VirtualMac {
        // A new machine identity, as VZMacMachineIdentifier makes one: a random ECID.
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        var mac = VirtualMac(name: name, ecid: ecid, seed: 0, ramMB: ramMB, diskBytes: 64 << 30)
        (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
        mac.cpus = cpus
        // With a drive on, the machine is made there: its disk, auxiliary
        // storage and ROM live on it, and it runs from it.
        if ExternalStorage.shared.folder != nil { mac.external = true }
        let fm = FileManager.default
        let place = mac.external == true ? "on the drive" : "here"
        do { try fm.createDirectory(at: mac.directory, withIntermediateDirectories: true) }
        catch { throw message("Cannot make the Mac's folder \(place): \(error.localizedDescription).") }
        Machines.excludeFromBackup(Machines.root)
        try? fm.removeItem(at: mac.rom)
        try fm.copyItem(at: rom, to: mac.rom)
        guard fm.createFile(atPath: mac.disk.path, contents: nil) else {
            throw message("Cannot create the 64 GB disk \(place): there may not be enough room.")
        }
        let h = try FileHandle(forWritingTo: mac.disk)
        try h.truncate(atOffset: UInt64(64) << 30) // sparse: blocks are only used as macOS writes them
        try h.close()
        guard henge_make_aux(mac.aux.path) == 0 else { throw message("Cannot create the auxiliary storage.") }
        let info: [String: Any] = ["name": name, "ecid": ecid, "seed": 0, "ramMB": ramMB, "cpus": cpus]
        try JSONSerialization.data(withJSONObject: info).write(to: mac.directory.appendingPathComponent("machine.json"))
        mac.diskBytes = 64 << 30
        HengeLog.log("install", "new machine \(name): ECID \(ecid), 64 GB disk")
        return mac
    }

    // MARK: The restore

    private func install(_ mac: VirtualMac, ipsw: URL, cpus: Int) async throws {
        guard JITBootstrap.ready else { throw message("Turn on JIT first: the installer runs the Mac's own restore system, which needs it.") }
        let ram = GuestMemory.prepare(mac)
        guard ram >= 2048 else { throw message("Installing needs a few more GB of free storage for the Mac's memory.") }
        let work = mac.directory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, ipsw.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            // A Mac on the drive cannot be restored with the drive gone. Stop it here, where
            // the reason can be said plainly, rather than let the engine write into nothing.
            if mac.external == true, ExternalStorage.shared.folder == nil {
                if henge_vm_state() == 1 { henge_vm_stop() }
                throw message("The drive was disconnected while macOS was being written to it. Plug it back in and install again: the download is kept.")
            }
            // The last seconds of a restore need somewhere to write; a drive with no room
            // fails deep in the engine, with its own words rather than the plain one.
            if mac.external == true, let free = ExternalStorage.shared.freeBytes, free > 0, free < (1 << 30) {
                if henge_vm_state() == 1 { henge_vm_stop() }
                throw message("The drive has only \(ByteText.string(UInt64(free))) left and the restore cannot finish. Make room on the drive, then install again.")
            }
            step = Int(henge_install_step())
            stepProgress = henge_install_progress()
            if step == 100 { break }
            if step == 101 { throw message("The restore failed. The log (Settings, or Documents/henge.log) says why.") }
            if henge_vm_state() == 2 && step < 100 {
                // The restore ends with the machine restarting, and idevicerestore finishes a
                // little after; a stop with no result after that is a failure.
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("The machine stopped during the restore (\(String(cString: henge_vm_exit_reason()))).")
            }
        }
        if henge_vm_state() == 1 { henge_vm_stop() }
        try? FileManager.default.removeItem(at: work)
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "Finding the Mac"
        case 1: return "Starting the installer"
        case 2: return "Writing macOS"
        case 3: return "Checking macOS"
        case 4: return "Installing firmware"
        case 6, 7: return "Installing system files"
        default: return "Installing"
        }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension Installer: URLSessionDataDelegate {
    /* These callbacks arrive on the session's serial delegate queue, so the
       download's own state (partURL and friends) is safe to touch here. */
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A redirect hop: the session follows it on its own; just keep going, and
        // write nothing until the real answer arrives.
        if (300..<400).contains(status) {
            completionHandler(.allow)
            return
        }
        // 416 with a range means the part file is already whole (a crash between
        // the end and the move): call it done.
        if status == 416, partStart > 0, let part = partURL {
            try? partHandle?.close()
            partHandle = nil
            let dest = part.deletingPathExtension()
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                succeed(dest, partStart)
                completionHandler(.cancel)
                return
            } catch { fail(error); completionHandler(.cancel); return }
        }
        guard status == 200 || status == 206 else {
            fail(NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple's server answered \(status)."]))
            completionHandler(.cancel)
            return
        }
        // A server that ignored the range sends the whole image again: start over.
        if partStart > 0 && status == 200 {
            partStart = 0
            partAt = 0
            if let part = partURL { try? FileManager.default.removeItem(at: part) }
        }
        if partHandle == nil, let part = partURL {
            do {
                FileManager.default.createFile(atPath: part.path, contents: nil)
                let handle = try FileHandle(forWritingTo: part)
                try handle.seekToEnd() // past whatever the last attempt wrote
                partHandle = handle
            } catch { fail(error); completionHandler(.cancel); return }
        }
        if response.expectedContentLength > 0 { partTotal = partAt + response.expectedContentLength }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle = partHandle else { return }
        do {
            try handle.write(contentsOf: data)
            partAt += Int64(data.count)
        } catch {
            // Stop the task too, or it keeps receiving with nowhere to put what arrives.
            try? handle.close()
            partHandle = nil
            fail(error)
            dataTask.cancel()
            return
        }
        // Progress a few times a second at most: chunks are small and many.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - partProgressAt > 0.25 else { return }
        partProgressAt = now
        let done = partAt, total = partTotal
        Task { @MainActor in
            self.received = done
            if total > 0 { self.expected = total }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil else { try? partHandle?.close(); partHandle = nil; fail(error!); return }
        let handle = partHandle
        let part = partURL
        let at = partAt
        let total = partTotal
        partHandle = nil
        partURL = nil
        guard let handle, let part, at > 0, total <= 0 || at == total else {
            try? handle?.close()
            fail(NSError(domain: "Henge", code: 4, userInfo: [NSLocalizedDescriptionKey: "The download ended early."]))
            return
        }
        do {
            try handle.close()
            let dest = part.deletingPathExtension()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            succeed(dest, at)
        } catch { fail(error) }
    }
}
