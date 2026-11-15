import BogoModel
import BogoRelay
import SwiftUI

struct HistoryScreen: View {
    let approver: PhoneApprover

    var body: some View {
        let records = Inbox.history(approver.shown)
        List {
            ForEach(records) { record in
                NavigationLink(value: record.id) {
                    HistoryRow(record: record, approver: approver)
                }
            }
        }
        .navigationDestination(for: String.self) { id in
            ReviewScreen(approver: approver, id: id)
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Requests you approve or deny are kept here."))
            }
        }
    }
}

struct HistoryRow: View {
    let record: RequestRecord
    let approver: PhoneApprover

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                if let request = record.request {
                    Text(Formatting.headline(Review(request)) ?? request.tool)
                        .font(.headline)
                        .lineLimit(1)
                    Text(request.tool + " · " + request.agentName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Unreadable request").font(.headline)
                }
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Formatting.when(Date(timeIntervalSince1970: TimeInterval(record.changedMs) / 1000)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        var text = Formatting.status(record, now: approver.nowMs) ?? ""
        if case .denied(let note?) = record.phase.decision { text += " · “\(note)”" }
        return text
    }

    private var symbol: String {
        switch record.phase.decision {
        case .approved?: return "checkmark.circle.fill"
        case .denied?: return "xmark.circle.fill"
        case nil: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch record.phase.decision {
        case .approved?: return .green
        case .denied?: return .red
        case nil: return .secondary
        }
    }
}
