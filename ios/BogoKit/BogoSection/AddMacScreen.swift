import BogoCrypto
import BogoModel
import BogoRelay
import SwiftUI

struct AddMacScreen: View {
    let approver: PhoneApprover
    @Environment(\.dismiss) private var dismiss
    @State private var offers: [RegistrationOffer] = []
    @State private var looking = true
    @State private var step: Step = .choose
    @State private var offerName = ""

    enum Step {
        case choose
        case compare(RegistrationChannel, MacConfirmation?)
        case confirming(RegistrationChannel, MacConfirmation)
        case added(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose: choose
                case .compare(let channel, let confirmation): compare(channel, confirmation, busy: false)
                case .confirming(let channel, let confirmation): compare(channel, confirmation, busy: true)
                case .added(let name): added(name)
                case .failed(let reason): failed(reason)
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .added = step {} else {
                        Button("Cancel", role: .cancel) {
                            if case .compare(let channel, _) = step { channel.abort() }
                            dismiss()
                        }
                    }
                }
            }
        }
        .task { await look() }
    }

    private var choose: some View {
        List {
            Section {
                ForEach(offers) { offer in
                    Button { start(offer) } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(offer.label)
                                    Text("Ready to add")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "macbook")
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .tint(.primary)
                }
            } footer: {
                if !offers.isEmpty {
                    Text("Choose the Mac where you ran `bogo approver add`.")
                }
            }
        }
        .overlay {
            if offers.isEmpty {
                ContentUnavailableView {
                    Label("Looking for Your Mac", systemImage: "macbook")
                } description: {
                    Text("On your Mac, run `bogo approver add`. It appears here while the command runs.")
                } actions: {
                    ProgressView()
                }
            }
        }
    }

    private func compare(_ channel: RegistrationChannel, _ confirmation: MacConfirmation?, busy: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text(confirmation?.macName ?? offerName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(spaced(channel.code))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(channel.code.map(String.init).joined(separator: " "))
                Text(confirmation == nil ? "Check that your Mac shows the same number, then confirm on the Mac." : "Your Mac confirmed. Confirm here to finish.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            Spacer()
            Spacer()
            Group {
                if let confirmation {
                    Button {
                        confirm(channel, confirmation)
                    } label: {
                        Label("Confirm with Face ID", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(busy)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for your Mac").foregroundStyle(.secondary)
                    }
                    .frame(height: 50)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func added(_ name: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("\(name) Added").font(.title2.weight(.semibold))
                Text("Requests from its agents now come to this iPhone.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    private func failed(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Mac Not Added", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Try Again") {
                step = .choose
                Task { await look() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    private func look() async {
        while case .choose = step, !Task.isCancelled {
            offers = await approver.link.offers(excluding: approver.macs)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func start(_ offer: RegistrationOffer) {
        offerName = offer.label
        Task {
            do {
                let channel = try await approver.beginRegistration(offer)
                step = .compare(channel, nil)
                let confirmation = try await channel.macConfirmation()
                if case .compare = step { step = .compare(channel, confirmation) }
            } catch {
                if case .compare = step { step = .failed("The Mac stopped the attempt. Run `bogo approver add` again.") }
            }
        }
    }

    private func confirm(_ channel: RegistrationChannel, _ confirmation: MacConfirmation) {
        step = .confirming(channel, confirmation)
        Task {
            do {
                let mac = try await approver.completeRegistration(channel, confirmation: confirmation)
                step = .added(mac.name)
            } catch ApprovalKeyError.cancelled {
                step = .compare(channel, confirmation)
            } catch ApprovalKeyError.notRecognized {
                step = .failed("Face ID didn’t match, so no key was created.")
            } catch {
                step = .failed("This iPhone couldn’t finish adding the Mac. Nothing was registered.")
            }
        }
    }
}
