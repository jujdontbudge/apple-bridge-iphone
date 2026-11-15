import BogoModel
import BogoRelay
import SwiftUI

struct BogoTab: View {
    @Bindable var section: BogoSection
    @Environment(\.scenePhase) private var scenePhase
    @State private var addingMac = false

    var body: some View {
        NavigationStack {
            Group {
                switch section.page {
                case .inbox: InboxScreen(section: section, addMac: { addingMac = true })
                case .history: HistoryScreen(approver: section.approver)
                case .macs: MacsScreen(approver: section.approver, addMac: { addingMac = true })
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section.page) {
                        ForEach(BogoPage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $section.reviewing) { id in
                ReviewScreen(approver: section.approver, id: id)
            }
        }
        .sheet(isPresented: $addingMac) {
            AddMacScreen(approver: section.approver)
        }
        .task { await section.sceneBecameActive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await section.sceneBecameActive() } }
        }
    }
}

struct InboxScreen: View {
    @Bindable var section: BogoSection
    let addMac: () -> Void

    var body: some View {
        let approver = section.approver
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = UInt64(context.date.timeIntervalSince1970 * 1000)
            let entries = Inbox.entries(approver.shown, now: now)
            let live = entries.filter(\.live)
            let ended = entries.filter { !$0.live }
            let stale = approver.macs.filter { $0.state == .needsReRegistration }
            List {
                ForEach(stale) { mac in
                    Section {
                        Button(action: addMac) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add \(mac.name) again")
                                    Text("Face ID changed, so approvals from this iPhone stopped working.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "faceid").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if !live.isEmpty {
                    Section {
                        ForEach(live) { entry in
                            Button { section.reviewing = entry.primary.id } label: {
                                InboxRow(entry: entry, approver: approver, now: now)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !ended.isEmpty {
                    Section("Ended") {
                        ForEach(ended) { entry in
                            Button { section.reviewing = entry.primary.id } label: {
                                InboxRow(entry: entry, approver: approver, now: now)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if entries.isEmpty && stale.isEmpty {
                    if approver.macs.contains(where: { $0.state == .active }) {
                        ContentUnavailableView("No Requests", systemImage: "checkmark.shield",
                                               description: Text("When an agent wants to run a protected tool, it waits here for you."))
                    } else {
                        ContentUnavailableView {
                            Label("Add a Mac", systemImage: "macbook")
                        } description: {
                            Text("Connect the Mac that runs BOGO. Its agents ask you here before a protected tool runs.")
                        } actions: {
                            Button("Add Mac", action: addMac).buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .refreshable { await section.sceneBecameActive() }
    }
}

struct InboxRow: View {
    let entry: InboxEntry
    let approver: PhoneApprover
    let now: UInt64

    var body: some View {
        let record = entry.primary
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let request = record.request {
                    let review = Review(request)
                    Text(Formatting.headline(review) ?? request.tool)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detail(request, review: review))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Label("Unreadable request", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(approver.mac(record.bogoID)?.name ?? "Unknown Mac")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !entry.live, let status = Formatting.status(record, now: now) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Formatting.when(Date(timeIntervalSince1970: TimeInterval(entry.records.map(\.receivedMs).max() ?? 0) / 1000)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if entry.count > 1 {
                    Text("\(entry.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel("\(entry.count) identical requests")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(entry.live ? 1 : 0.45)
    }

    private func detail(_ request: ApprovalRequest, review: Review) -> String {
        let tool = Formatting.headline(review) == nil ? request.upstream : request.tool
        return tool + " · " + request.agentName
    }
}
