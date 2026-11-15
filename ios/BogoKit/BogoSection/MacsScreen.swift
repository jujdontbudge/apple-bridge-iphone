import BogoModel
import BogoRelay
import SwiftUI

struct MacsScreen: View {
    let approver: PhoneApprover
    let addMac: () -> Void

    var body: some View {
        List {
            if !approver.macs.isEmpty {
                Section {
                    ForEach(approver.macs) { mac in
                        NavigationLink {
                            MacDetail(approver: approver, id: mac.bogoID)
                        } label: {
                            MacRow(mac: mac)
                        }
                    }
                } footer: {
                    Text("Agents on these Macs ask this iPhone before a protected tool runs.")
                }
                Section {
                    Button("Add Mac", systemImage: "plus", action: addMac)
                }
            }
        }
        .overlay {
            if approver.macs.isEmpty {
                ContentUnavailableView {
                    Label("No Macs", systemImage: "macbook")
                } description: {
                    Text("On your Mac, run `bogo approver add`, then add it here.")
                } actions: {
                    Button("Add Mac", action: addMac).buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct MacRow: View {
    let mac: MacRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                Text(MacRow.status(mac))
                    .font(.subheadline)
                    .foregroundStyle(mac.state == .needsReRegistration ? .orange : .secondary)
            }
        } icon: {
            Image(systemName: "macbook")
                .foregroundStyle(mac.state == .active ? Color.primary : .secondary)
        }
        .padding(.vertical, 2)
    }

    static func status(_ mac: MacRecord) -> String {
        switch mac.state {
        case .active: return "Connected"
        case .waiting: return "Waiting for the Mac to confirm"
        case .needsReRegistration: return "Face ID changed · add again"
        case .removed: return "Removing · waiting for the Mac"
        }
    }
}

struct MacDetail: View {
    let approver: PhoneApprover
    let id: Data
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false

    var body: some View {
        if let mac = approver.mac(id) {
            List {
                Section {
                    LabeledContent("Status", value: MacRow.status(mac))
                    LabeledContent("Added", value: Date(timeIntervalSince1970: TimeInterval(mac.addedMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Requests", value: "\(approver.records.filter { $0.bogoID == mac.bogoID && $0.receivedMs > 0 }.count)")
                }
                if mac.state != .removed {
                    Section {
                        Button("Remove Mac", role: .destructive) { removing = true }
                    } footer: {
                        Text("This iPhone stops approving requests from \(mac.name). You can add it again later.")
                    }
                }
            }
            .navigationTitle(mac.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .confirmationDialog("Remove \(mac.name)?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove Mac", role: .destructive) {
                    approver.remove(mac)
                    dismiss()
                }
            }
        }
    }
}
