import BogoModel
import BogoRelay
import SwiftUI

struct MacsScreen: View {
    let approver: PhoneApprover
    let addMac: () -> Void
    @State private var removing: MacRecord?

    var body: some View {
        List {
            if !approver.macs.isEmpty {
                Section {
                    ForEach(approver.macs) { mac in
                        MacRow(mac: mac)
                            .swipeActions {
                                if mac.state != .removed {
                                    Button("Remove", role: .destructive) { removing = mac }
                                }
                            }
                            .contextMenu {
                                if mac.state != .removed {
                                    Button("Remove", systemImage: "trash", role: .destructive) { removing = mac }
                                }
                            }
                    }
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
                    Text("On your Mac, run bogo approver add, then add it here.")
                } actions: {
                    Button("Add Mac", action: addMac).buttonStyle(.borderedProminent)
                }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this Mac")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Mac", role: .destructive) {
                if let removing { approver.remove(removing) }
                removing = nil
            }
        } message: {
            Text("This iPhone can no longer approve requests from it. You can add it again later.")
        }
    }
}

struct MacRow: View {
    let mac: MacRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "macbook")
                .font(.title3)
                .foregroundStyle(mac.state == .active ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.name)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(mac.state == .needsReRegistration ? .orange : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        switch mac.state {
        case .active: return "Added " + Formatting.when(Date(timeIntervalSince1970: TimeInterval(mac.addedMs) / 1000)).lowercasedFirst
        case .waiting: return "Waiting for the Mac to confirm"
        case .needsReRegistration: return "Face ID changed. Add this Mac again."
        case .removed: return "Removed here; the Mac hasn’t confirmed yet"
        }
    }
}
