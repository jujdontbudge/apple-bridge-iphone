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
                    let review = Review(request)
                    Text(Formatting.row(review).headline)
                        .font(.headline)
                        .lineLimit(1)
                    Text((Formatting.headline(review) == nil ? Formatting.visible(request.agentName) : Formatting.row(review).detail) + AttributedString(" · " + status))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Unreadable request").font(.headline)
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(Formatting.when(Date(timeIntervalSince1970: TimeInterval(record.changedMs) / 1000)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var status: String { Formatting.history(record).text }

    private var symbol: String {
        switch Formatting.history(record).mark {
        case .approved: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .ended: return "minus.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch Formatting.history(record).mark {
        case .approved: return .green
        case .denied: return .red
        case .ended, .paused: return .secondary
        }
    }
}
