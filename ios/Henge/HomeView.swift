import SwiftUI
import UniformTypeIdentifiers

/// Your Mac as you left it, and one big button.
struct HomeView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var external = ExternalStorage.shared
    @Binding var running: VirtualMac?
    @Binding var tab: RootView.Tab
    @State private var picking = false
    @State private var pickingDrive = false
    @State private var jitReady = JITBootstrap.ready
    @State private var launchUsed = Launch.used
    @State private var chosen: UUID?
    /// The drive already tidied this launch, so a failed restore's leftovers go once.
    @State private var tidiedDrive: String?

    /// The Mac on show: the one picked, or the one used last.
    private var mac: VirtualMac? {
        if let chosen, let mac = machines.all.first(where: { $0.id == chosen }) { return mac }
        return machines.all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if external.enabled { driveCard }
                    notices
                    if let mac {
                        MacHero(mac: mac, jitReady: jitReady, start: {
                            if let reason = mac.unavailableReason { machines.lastError = reason } else { running = mac }
                        }, turnOnJIT: { jit.enable() },
                                jitNote: jitReady ? nil : (JITBootstrap.lastFailure ?? jit.automaticDescription),
                                blocked: launchUsed ? Launch.explanation : nil)
                        HStack(spacing: 10) {
                            FactTile(title: "Disk", value: ByteText.string(UInt64(max(mac.bytesUsed, 0))))
                            FactTile(title: "Last used", value: mac.lastUsedText)
                        }
                        others(besides: mac)
                    } else {
                        firstMac
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle("Henge")
            .navigationDestination(for: VirtualMac.self) { MacSettingsView(mac: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Install macOS…") { tab = .install }
                        Button("Bring in a Mac from a computer…") { picking = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a Mac")
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { machines.importFolder(url) }
            }
            .fileImporter(isPresented: $pickingDrive, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { external.choose(url) }
            }
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    // The engine takes one Mac per launch: once one has run, say so here
                    // rather than let Start fail with the engine's own message.
                    let used = Launch.used
                    if launchUsed != used { launchUsed = used }
                    // Once per drive: a restore cut short leaves a machine folder nothing
                    // refers to, and it is not space the next install can use.
                    if let volume = external.volumeName, tidiedDrive != volume,
                       let root = external.machinesRoot,
                       !installer.busy, machines.moving == nil, machines.importing == nil {
                        tidiedDrive = volume
                        machines.tidy(root)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if Device.chipTooOld {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: Device.chipTooOldText, tint: Desk.bad)
        }
        if installer.busy {
            Button { tab = .install } label: {
                NoticeRow(symbol: "arrow.down.circle.fill", text: "Installing \(installer.machineName)…", trailing: "See")
            }
        }
        if let name = machines.importing {
            NoticeRow(symbol: "square.and.arrow.down.fill",
                      text: machines.unpacked > 0 ? String(format: "Unpacking %@'s disk… %.0f%%", name, machines.unpacked * 100) : "Bringing in \(name)…")
        }
        if let name = machines.moving {
            NoticeRow(symbol: "externaldrive.fill", text: "Moving \(name)… keep Henge open")
        }
        if external.enabled, external.volumeName == nil {
            DriveAwayRow(paused: external.paused, waiting: waiting, choose: { pickingDrive = true }, again: { external.reconnect() })
        }
        if let error = machines.lastError {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, tint: Desk.bad,
                      dismiss: { machines.clearError() })
        }
    }

    /// The drive at a glance: what is on it, how much room is left, and the way to Settings.
    @ViewBuilder private var driveCard: some View {
        if let name = external.volumeName {
            Button { tab = .settings } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(Desk.accentLight)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Desk.text).lineLimit(1)
                            Text(driveSummary).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        }
                        Spacer(minLength: 6)
                        if let free = external.freeBytes {
                            Text(ByteText.string(UInt64(max(free, 0))))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.text)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    if !external.supportsSparse {
                        Text("This drive can't keep a disk image sparse, so each Mac on it takes the full 64 GB.")
                            .font(.system(size: 12)).foregroundStyle(Desk.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .deskCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Settings, where the drive can be disconnected.")
        }
    }

    /// What is on the drive, in one line.
    private var driveSummary: String {
        let macs = machines.all.filter { $0.external == true }
        let used = macs.reduce(Int64(0)) { $0 + $1.bytesUsed }
        var parts = ["\(macs.count) Mac\(macs.count == 1 ? "" : "s")"]
        if used > 0 { parts.append("\(ByteText.string(UInt64(used))) used") }
        return parts.joined(separator: " · ")
    }

    /// Macs whose drive is not in: the ones the away card counts.
    private var waiting: Int {
        machines.all.filter { $0.external == true && $0.unavailableReason != nil }.count
    }

    private var firstMac: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Desk.accentLight)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Desk.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("No Mac yet").font(.system(size: 24, weight: .bold))
            Text("Install macOS on this \(external.folder != nil ? "drive, plugged into this \(Device.name)" : Device.name), or bring in a Mac made on a computer.")
                .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            Button("Install macOS") { tab = .install }.buttonStyle(DeskButtonStyle())
            Button("Bring in a Mac") { picking = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMac) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading("Other Macs")
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                if let reason = other.unavailableReason {
                                    Text(reason).font(.system(size: 13)).foregroundStyle(Desk.warn)
                                } else {
                                    Text(other.summary).font(.system(size: 13)).foregroundStyle(Desk.dim)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    if other.id != rest.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }
    }
}

extension VirtualMac {
    var bytesUsed: Int64 {
        Int64((try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }

    var lastUsedText: String {
        guard let lastUsed else { return "Never" }
        if Calendar.current.isDateInToday(lastUsed) { return "Today" }
        if Calendar.current.isDateInYesterday(lastUsed) { return "Yesterday" }
        return lastUsed.formatted(.dateTime.month(.abbreviated).day())
    }

    var summary: String {
        var parts: [String] = []
        if let osName { parts.append(osName) }
        parts.append("\(ramMB / 1024) GB")
        return parts.joined(separator: " · ")
    }
}

/// The picture of the Mac, its name, and Start.
private struct MacHero: View {
    let mac: VirtualMac
    let jitReady: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let jitNote: String?
    /// Why Start must not run now (the engine already ran a Mac this launch).
    var blocked: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: mac) {
                VStack(spacing: 0) {
                    preview
                    HStack {
                        Text(mac.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1)
                        Spacer()
                        Text(jitReady ? "JIT on" : "JIT off")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(jitReady ? Desk.good : Desk.warn)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background((jitReady ? Desk.good : Desk.warn).opacity(0.13), in: Capsule())
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 5)
                    Text("\(mac.summary) · \(mac.cpus ?? 4) CPUs")
                        .font(.system(size: 15))
                        .foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 3)
                }
            }
            .buttonStyle(.plain)
            if let blocked {
                Text(blocked)
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if jitReady {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(DeskButtonStyle(enabled: blocked == nil))
                .disabled(blocked != nil)
                .padding(.top, 15)
            } else {
                if let jitNote {
                    Text(jitNote).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                }
                Button("Turn On JIT", action: turnOnJIT)
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
            }
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            Desk.raised.opacity(0.5)
            if let image = UIImage(contentsOfFile: MacPreview.file(for: mac).path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Desk.faint)
            }
        }
        .aspectRatio(mac.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct FactTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .deskCard()
    }
}

/// The drive is not in — or was disconnected on purpose — and Macs live on it.
/// Saying so here, with the two ways forward, keeps Settings out of the way.
private struct DriveAwayRow: View {
    let paused: Bool
    let waiting: Int
    let choose: () -> Void
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: paused ? "externaldrive.badge.xmark" : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(paused ? Desk.dim : Desk.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(paused ? "Drive disconnected" : "Waiting for the drive")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Desk.text)
                    Text(paused
                         ? "Henge let go of it so it can be unplugged. Reconnect when it is plugged back in."
                         : "\(waiting) Mac\(waiting == 1 ? "" : "s") on it will start as soon as it is plugged in.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                Button(paused ? "Reconnect" : "Choose Another Drive…", action: paused ? again : choose)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Desk.accentLight)
                if !paused {
                    Button("Check Again", action: again)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .deskCard()
    }
}

struct NoticeRow: View {
    let symbol: String
    let text: String
    var trailing: String?
    var tint: Color = Desk.accentLight
    /// Given, the row can be put away: a message that has been read should not stay for good.
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.text).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight) }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Desk.faint)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .deskCard()
    }
}
