import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var external = ExternalStorage.shared
    @ObservedObject private var machines = Machines.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @State private var pickingDrive = false
    @State private var confirmTurnOff = false

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A Mac's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your Mac first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Changes apply the next time a Mac starts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section {
                    if external.enabled {
                        if let volume = external.volumeName {
                            LabeledContent("Drive", value: volume)
                            if let free = external.freeBytes {
                                LabeledContent("Free space", value: ByteText.string(UInt64(max(free, 0))))
                            }
                            LabeledContent("Macs on it", value: "\(driveMacs.count)")
                            if driveBytesUsed > 0 {
                                LabeledContent("Used by them", value: ByteText.string(UInt64(driveBytesUsed)))
                            }
                            if !external.supportsSparse {
                                Text("This drive can't keep a disk image sparse: each Mac on it takes the full 64 GB.")
                                    .font(.footnote).foregroundStyle(Desk.warn)
                            }
                        } else {
                            LabeledContent("Drive", value: external.paused ? "Disconnected" : "Not connected")
                        }
                        if waiting > 0 {
                            LabeledContent("Macs waiting for it", value: "\(waiting)")
                        }
                    } else {
                        Text("Download, install and run Macs on a drive plugged into this \(Device.name): their disks never take this device's space.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(external.enabled ? "Choose a Different Drive…" : "Use External Storage…") { pickingDrive = true }
                    if external.enabled, external.volumeName != nil {
                        Button("Safely Disconnect") { external.eject() }
                    }
                    if external.paused {
                        Button("Reconnect") { external.reconnect() }
                    }
                    if external.enabled {
                        Button("Stop Using External Storage", role: .destructive) { confirmTurnOff = true }
                    }
                    if let error = external.lastError {
                        HStack(alignment: .top) {
                            Text(error).font(.footnote).foregroundStyle(Desk.bad)
                            Spacer(minLength: 8)
                            Button("Dismiss") { external.clearError() }
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("External Storage")
                } footer: {
                    Text("Pick the drive itself, or any folder on it. Macs that live on the drive stay there: nothing is copied onto this device, and they run from the drive. Keep it connected while such a Mac runs; pulling it out mid-run can corrupt its disk. Safely Disconnect stops Henge's use of it before it is unplugged. A drive formatted APFS keeps its space to what macOS actually uses.")
                }
                .listRowBackground(Desk.card)
                if !external.known.isEmpty {
                    Section("Drives You've Used") {
                        ForEach(external.known) { drive in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(drive.name).font(.system(size: 15, weight: .medium))
                                    Text("Last used \(drive.lastUsed.formatted(.dateTime.month(.abbreviated).day()))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                Button("Use") { external.select(drive) }
                                    .buttonStyle(.borderless)
                                    .disabled(drive.bookmark == external.currentBookmark)
                                Button { external.forget(drive) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(drive.bookmark == external.currentBookmark)
                                .accessibilityLabel("Forget \(drive.name)")
                            }
                        }
                        Text("Switching drives moves nothing: Macs stay where they are, and the ones on the drive you pick come back. Removing one here only forgets the shortcut.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
            .fileImporter(isPresented: $pickingDrive, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { external.choose(url) }
            }
            .confirmationDialog("Stop using external storage?", isPresented: $confirmTurnOff, titleVisibility: .visible) {
                Button("Stop Using It", role: .destructive) { external.turnOff() }
            } message: {
                Text("Macs on the drive stay there and wait: nothing is copied onto this \(Device.name), and picking the drive again brings them back.")
            }
        }
    }

    /// Macs whose drive is not in: the one figure that matters when the drive is away.
    private var waiting: Int {
        machines.all.filter { $0.external == true && $0.unavailableReason != nil }.count
    }

    private var driveMacs: [VirtualMac] { machines.all.filter { $0.external == true } }
    private var driveBytesUsed: Int64 { driveMacs.reduce(Int64(0)) { $0 + $1.bytesUsed } }
}
