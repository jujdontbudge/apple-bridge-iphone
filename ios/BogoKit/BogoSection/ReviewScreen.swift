import BogoModel
import BogoRelay
import SwiftUI

struct ReviewScreen: View {
    let approver: PhoneApprover
    let id: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var armedAt = Date.distantFuture
    @State private var busy = false
    @State private var denying = false
    @State private var note = ""
    @State private var pausing = false
    @State private var problem: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = UInt64(context.date.timeIntervalSince1970 * 1000)
            if let record = approver.record(id) {
                content(record, now: now, date: context.date)
            } else {
                ContentUnavailableView("Request Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { arm() }
        .onChange(of: id) { arm() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { arm() } }
        .alert("Deny this request?", isPresented: $denying) {
            TextField("Note to the agent (optional)", text: $note)
            Button("Cancel", role: .cancel) { note = "" }
            Button("Deny", role: .destructive) { deny() }
        } message: {
            Text("The agent is told you denied it.")
        }
        .alert("Nothing was approved", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private func content(_ record: RequestRecord, now: UInt64, date: Date) -> some View {
        let open = record.deniable(at: now)
        let entry = Inbox.entries(approver.shown, now: now).first { $0.records.contains { $0.id == record.id } }
        let paused = approver.isPaused(record)
        List {
            if let status = Formatting.status(record, now: now), !record.phase.isPending || !open {
                Section {
                    Label(status, systemImage: statusSymbol(record))
                        .foregroundStyle(.secondary)
                }
            }
            if let request = record.request {
                WillExecute(review: Review(request), date: date)
                AgentReason(review: Review(request))
                if let entry, entry.count > 1, open {
                    Section {
                        Text("\(entry.count) identical requests are waiting. Approve or Deny decides this one, the oldest.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Unreadable(record: record, macName: approver.mac(record.bogoID)?.name)
            }
        }
        .navigationTitle(record.request == nil ? "Unreadable Request" : "Review")
        .toolbar {
            if let request = record.request, open, !paused {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Pause \(request.agentName)", systemImage: "pause.circle", role: .destructive) { pausing = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Pause \(record.request?.agentName ?? "this agent")?", isPresented: $pausing, titleVisibility: .visible) {
            Button("Pause Agent", role: .destructive) {
                approver.pause(record)
                dismiss()
            }
        } message: {
            Text("Its waiting requests are denied, and BOGO refuses new ones until you un-pause it on the Mac.")
        }
        .safeAreaInset(edge: .bottom) {
            if open && !paused {
                actions(record, date: date)
            }
        }
    }

    private func actions(_ record: RequestRecord, date: Date) -> some View {
        HStack(spacing: 12) {
            Button {
                note = ""
                denying = true
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.red)
            if record.request != nil {
                Button {
                    approve(record)
                } label: {
                    Label("Approve", systemImage: "faceid").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(busy || date < armedAt)
            }
        }
        .controlSize(.large)
        .disabled(busy)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func arm() {
        let delay = approver.record(id)?.armDelayMs ?? 2000
        armedAt = Date().addingTimeInterval(TimeInterval(delay) / 1000)
    }

    private func approve(_ record: RequestRecord) {
        busy = true
        Task {
            let result = await approver.approve(record)
            busy = false
            switch result {
            case .decided: dismiss()
            case .nothingSigned(let reason): problem = reason
            }
        }
    }

    private func deny() {
        guard let record = approver.record(id) else { return }
        if case .nothingSigned(let reason) = approver.deny(record, note: note) { problem = reason } else { dismiss() }
        note = ""
    }

    private func statusSymbol(_ record: RequestRecord) -> String {
        switch record.phase.decision {
        case .approved?: return "checkmark.circle"
        case .denied?: return "xmark.circle"
        case nil: return "clock.badge.xmark"
        }
    }
}

struct WillExecute: View {
    let review: Review
    let date: Date

    var body: some View {
        let request = review.request
        Section {
            ForEach(review.highlights) { highlight in
                HighlightRow(highlight: highlight)
            }
            LabeledContent("Upstream") { Text(Formatting.visible(request.upstream)) }
            LabeledContent("Tool") { Text(Formatting.visible(request.tool)).font(.body.monospaced()) }
            LabeledContent("Requested by") { Text(Formatting.visible(request.agentName)) }
            if let expires = request.expires {
                LabeledContent("Expires in") {
                    Text(date < expires ? Formatting.remaining(expires, now: date) : "Expired")
                        .monospacedDigit()
                        .foregroundStyle(date < expires ? Color.primary : Color.red)
                }
            }
        } header: {
            Text("Will execute (exact)")
        }
        Section {
            if let rows = review.arguments {
                if rows.isEmpty {
                    Text("No fields").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    ArgumentRowView(row: row)
                }
            } else {
                Text("No arguments sent").foregroundStyle(.secondary)
            }
        } header: {
            Text("Arguments")
        }
    }
}

struct HighlightRow: View {
    let highlight: Review.Highlight

    var body: some View {
        switch highlight.value {
        case .money(let amount, let token):
            VStack(alignment: .leading, spacing: 4) {
                Text(amount.formatted)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("\(Formatting.visible(highlight.label)) · \(token) \(amount.currency) minor units")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .unformattable(let value, let currency):
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatting.value(value))
                    Text("Can’t format as \(currency)").font(.footnote).foregroundStyle(.orange)
                }
            } label: {
                Text(Formatting.visible(highlight.label))
            }
        case .text(let value):
            LabeledContent {
                Text(Formatting.value(value)).multilineTextAlignment(.trailing)
            } label: {
                Text(Formatting.visible(highlight.label))
            }
        case .missing:
            LabeledContent {
                Text("Not in this request").foregroundStyle(.secondary)
            } label: {
                Text(Formatting.visible(highlight.label))
            }
        }
    }
}

struct ArgumentRowView: View {
    let row: Review.ArgumentRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let label = row.label {
                Text(Formatting.visible(label))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let leaf = row.leaf {
                Text(Formatting.value(leaf))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else if let container = row.container {
                Text(container.description).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
    }
}

extension Review.Container {
    var description: String {
        switch self {
        case .object(let count): return count == 1 ? "1 field" : "\(count) fields"
        case .array(let count): return count == 1 ? "1 item" : "\(count) items"
        }
    }
}

struct AgentReason: View {
    let review: Review

    var body: some View {
        let request = review.request
        Section {
            if let justification = request.justification {
                Text(justification.isEmpty ? AttributedString("Empty reason") : Formatting.visible(justification))
                    .foregroundStyle(justification.isEmpty ? .secondary : .primary)
                    .italic(!justification.isEmpty)
                    .textSelection(.enabled)
            } else {
                Text("No reason given").foregroundStyle(.secondary)
            }
            ForEach(review.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.weight(.medium))
            }
            LabeledContent("Client says it is") {
                if let client = request.clientName { Text(Formatting.visible(client)) } else { Text("Not reported").foregroundStyle(.secondary) }
            }
            LabeledContent("Session") { Text(request.sessionTag).font(.body.monospaced()) }
        } header: {
            Label("Agent’s reason (unverified)", systemImage: "quote.bubble")
        }
        .listRowBackground(Color.orange.opacity(0.07))
    }
}

struct Unreadable: View {
    let record: RequestRecord
    let macName: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Unreadable request", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("BOGO couldn’t read what this request would run, so it can’t be approved. You can deny it.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            LabeledContent("From") { Text(macName ?? "Unknown Mac") }
            LabeledContent("Size") { Text("\(record.bytes.count) bytes") }
        }
    }
}
