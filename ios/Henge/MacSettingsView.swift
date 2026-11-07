import SwiftUI

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var external = ExternalStorage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var confirmDelete = false
    @State private var movingExport = false

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                DeskHeading("Memory")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(mac.ramMB / 1024) GB").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "Outside the app's limit once JIT is on" : "Used from free storage if needed")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim).multilineTextAlignment(.trailing)
                    }
                    Picker("Memory", selection: Binding(get: { mac.ramMB / 1024 }, set: { mac.ramMB = $0 * 1024; save() })) {
                        ForEach([4, 6, 8], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Applies the next time this Mac starts.")
                        .font(.system(size: 13)).foregroundStyle(Desk.faint)
                }
                .padding(17)
                .deskCard()

                DeskHeading("Processors")
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: Binding(get: { mac.cpus ?? 4 }, set: { mac.cpus = $0; save() }), in: 1...6) {
                        HStack {
                            Text("CPUs").font(.system(size: 16))
                            Spacer()
                            Text("\(mac.cpus ?? 4)").font(.system(size: 16, weight: .semibold))
                        }
                    }
                    Text("Each Mac keeps its own count. Applies the next time this Mac starts.")
                        .font(.system(size: 13)).foregroundStyle(Desk.faint)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .deskCard()

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("Screen")
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Screen", selection: Binding(get: { mac.screen.height == 1080 }, set: { wide in
                            (mac.screenWidth, mac.screenHeight) = wide ? (1920, 1080) : Device.fittingScreen
                            save()
                        })) {
                            Text("Fit this \(Device.name)").tag(false)
                            Text("16:9").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Text("\(mac.screen.width) × \(mac.screen.height). Changes apply the next time this Mac starts.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("Storage")
                VStack(spacing: 11) {
                    HStack {
                        Text("\(ByteText.string(UInt64(max(mac.bytesUsed, 0)))) used").font(.system(size: 16))
                        Spacer()
                        Text("of \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                    }
                    DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                    HStack {
                        Text("Lives on").font(.system(size: 15)).foregroundStyle(Desk.dim)
                        Spacer()
                        Text(mac.external == true
                             ? (external.volumeName ?? "the drive (not connected)")
                             : "this \(Device.name)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mac.external == true && external.volumeName == nil ? Desk.warn : Desk.text)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("Manage")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Delete \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(mac.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from where this Mac lives (this \(Device.name), or the drive).")
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let name = machines.moving {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Moving \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.relocated)
                    Text("Between volumes this copies the whole disk, so it takes about as long as copying it.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                .padding(17)
            } else if external.enabled {
                divider
                row(mac.external == true ? "Move to this \(Device.name)" : "Move to the Drive", symbol: "externaldrive",
                     tint: external.available ? Desk.accentLight : Desk.faint, enabled: external.available) {
                    Task {
                        await machines.relocate(mac, toDrive: mac.external != true)
                        if let fresh = machines.all.first(where: { $0.id == mac.id }) { mac = fresh }
                    }
                }
                if !external.available {
                    Text("Plug the drive in to move this Mac. Until then it stays where it is.")
                        .font(.system(size: 13)).foregroundStyle(Desk.warn)
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if mac.external != true {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keeps this Mac's disk off this \(Device.name)'s storage. The drive needs about \(ByteText.string(UInt64(max(mac.diskBytes, 0)))) free, and must stay connected while this Mac runs.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                }
            }
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Exporting \(name)… keep Henge open").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else {
                row("Export", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved in Files, under Henge, Exports, \(folder.lastPathComponent). Deleting Henge deletes it too, so move it somewhere else first.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("Move Out of Henge…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            divider
            row("Delete this Mac", symbol: nil, tint: Desk.bad, enabled: canDelete) { confirmDelete = true }
            if !canDelete {
                Text("Plug the drive in to delete this Mac: its disk is on it, and deleting the entry now would leave that disk behind for good.")
                    .font(.system(size: 13)).foregroundStyle(Desk.warn)
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .deskCard()
    }

    /// A Mac that lives on the drive can only be deleted while the drive is here.
    private var canDelete: Bool { mac.external != true || external.available }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, enabled: Bool = true,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(enabled ? tint : Desk.faint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(enabled ? tint : Desk.faint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    private func save() {
        if mac.name.isEmpty { mac.name = "Mac" }
        machines.update(mac)
    }
}
