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
        .toolbar(.hidden, for: .tabBar)
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
                let review = Review(request)
                Summary(review: review, date: date)
                AgentReason(review: review)
                if let entry, entry.count > 1, open {
                    Section {
                        Text("\(entry.count) identical requests are waiting. Approve or Deny decides this one, the oldest.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                WillExecute(review: review)
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
            Text("Its waiting requests end now, and BOGO refuses new ones until you un-pause it on the Mac.")
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .safeAreaBar(edge: .bottom) {
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
        switch Formatting.history(record).mark {
        case .approved: return "checkmark.circle"
        case .denied: return "xmark.circle"
        case .ended, .paused: return "clock.badge.xmark"
        }
    }
}

struct Summary: View {
    let review: Review
    let date: Date

    var body: some View {
        let request = review.request
        let shown = review.highlights.filter { !(review.action != nil && $0.path == [.key("name")]) }
        let prominent = shown.filter(\.prominent)
        let fields = shown.filter(\.field)
        let missing = shown.filter { $0.value == .missing }
        let names = Formatting.fieldNames(fields + missing)
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(Formatting.asks(request.agentName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Formatting.visible(review.action ?? request.tool))
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)
                Text(Formatting.via(review))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            ForEach(prominent) { highlight in
                HighlightRow(highlight: highlight)
            }
            if review.pictures.count == 1, let link = review.pictures.first {
                AgentPicture(link: link).padding(.vertical, 4)
            } else if review.pictures.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(review.pictures, id: \.self) { link in AgentPicture(link: link, side: 120) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Text("Agent’s pictures (unverified)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(fields) { highlight in
                if case .text(let value) = highlight.value {
                    LabeledContent {
                        Text(Formatting.summary(value)).multilineTextAlignment(.trailing)
                    } label: {
                        Text(Formatting.visible(names[highlight.id] ?? highlight.label))
                    }
                }
            }
            if !missing.isEmpty {
                Text(Formatting.visible("Not in this request: " + missing.map { names[$0.id] ?? $0.label }.joined(separator: ", ")))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let expires = request.expires {
                LabeledContent("Expires in") {
                    Text(date < expires ? Formatting.remaining(expires, now: date) : "Expired")
                        .monospacedDigit()
                        .foregroundStyle(date < expires ? Color.primary : Color.red)
                }
            }
        }
    }
}

struct WillExecute: View {
    let review: Review
    @State private var unfolded: Set<Int> = []

    var body: some View {
        let request = review.request
        Section {
            LabeledContent("Upstream") { Text(Formatting.visible(request.upstream)) }
            LabeledContent("Tool") { Text(Formatting.visible(request.tool)).font(.body.monospaced()) }
            LabeledContent("Requested by") { Text(Formatting.visible(request.agentName)) }
            if let rows = review.arguments {
                if rows.isEmpty {
                    Text("Empty arguments { }").foregroundStyle(.secondary)
                }
                ForEach(rows.filter { $0.foldedInto.map(unfolded.contains) ?? true }) { row in
                    if let fold = row.fold {
                        FoldRow(fold: fold, depth: row.depth, open: unfolded.contains(row.id)) {
                            withAnimation(.snappy) {
                                if unfolded.contains(row.id) { unfolded.remove(row.id) } else { unfolded.insert(row.id) }
                            }
                        }
                    } else {
                        ArgumentRowView(row: row)
                    }
                }
            } else {
                Text("No arguments sent").foregroundStyle(.secondary)
            }
        } header: {
            Text("Will execute (exact)")
        }
    }
}

struct FoldRow: View {
    let fold: Review.EmptyFold
    let depth: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fold.labels.count) empty \(fold.items ? "items" : "fields")")
                        .foregroundStyle(.secondary)
                    if !open {
                        Text(Formatting.list(fold.labels))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 16)
        .accessibilityHint(open ? "Hides them" : "Shows them")
    }
}

struct HighlightRow: View {
    let highlight: Review.Highlight

    var body: some View {
        switch highlight.value {
        case .money(let amount, let token):
            VStack(alignment: .leading, spacing: 2) {
                Text(amount.formatted)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("\(Formatting.visible(highlight.label)) \(token)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        case .unformattable(let value, let currency):
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatting.value(value)).font(.title3.monospaced())
                Text("\(Formatting.visible(highlight.label)) can’t be shown as \(currency)")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 4)
        case .text, .missing:
            EmptyView()
        }
    }
}

extension Review.Highlight {
    var prominent: Bool {
        switch value {
        case .money, .unformattable: return true
        case .text, .missing: return false
        }
    }

    var field: Bool {
        if case .text = value { return true }
        return false
    }
}

struct ArgumentRowView: View {
    let row: Review.ArgumentRow

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    label
                    if let picture = row.picture {
                        AgentPicture(link: picture, side: 64).padding(.vertical, 2)
                    }
                    if let leaf = row.leaf {
                        Text(Formatting.value(leaf))
                            .font(multiline ? .callout.monospaced() : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    label
                    Spacer(minLength: 0)
                    if let leaf = row.leaf {
                        Text(Formatting.value(leaf))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } else if let container = row.container {
                        Text(container.description).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
    }

    @ViewBuilder
    private var label: some View {
        if let text = row.label {
            Text(Formatting.visible(text))
                .foregroundStyle(row.highlighted ? .primary : .secondary)
                .fontWeight(row.highlighted ? .semibold : .regular)
        }
    }

    private var multiline: Bool {
        if case .string(let text)? = row.leaf { return text.contains("\n") }
        return false
    }

    private var stacked: Bool {
        if row.picture != nil { return true }
        let room = 34 - (row.label?.count ?? 0) - row.depth * 2
        switch row.leaf {
        case .string(let text)?: return multiline || text.count > min(26, room)
        case .number(let text)?: return text.count > min(20, room)
        default: return false
        }
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
                if justification.isEmpty {
                    Text("Empty reason").foregroundStyle(.secondary)
                } else {
                    Text(Formatting.visible(justification, quoted: true)).textSelection(.enabled)
                }
            } else {
                Text("No reason given").foregroundStyle(.secondary)
            }
            ForEach(review.reasonPictures, id: \.self) { link in
                VStack(alignment: .leading, spacing: 6) {
                    AgentPicture(link: link)
                    Text(Formatting.visible(link, quoted: true))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            ForEach(review.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.weight(.semibold))
            }
            LabeledContent("Client") {
                if let client = request.clientName { Text(Formatting.visible(client)) } else { Text("Not reported").foregroundStyle(.secondary) }
            }
            LabeledContent("Session") { Text(request.sessionTag).font(.body.monospaced()) }
        } header: {
            Text("Agent’s reason (unverified)")
        }
        .listRowBackground(Color.orange.opacity(0.08))
    }
}

struct Unreadable: View {
    let record: RequestRecord
    let macName: String?

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("BOGO couldn’t read what this request would run, so it can’t be approved.")
                    .multilineTextAlignment(.center)
                Text("\(macName ?? "Unknown Mac") · \(record.bytes.count) bytes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}
