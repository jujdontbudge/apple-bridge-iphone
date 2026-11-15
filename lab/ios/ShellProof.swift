import Foundation

@main
struct ShellProof {
    @MainActor
    static func main() async throws {
        var checks: [String: Bool] = [:]
        checks["tab_structure"] = ShellModel.tabs.map(\.rawValue) == ["settings", "bogo", "diagnostics"] && ShellModel.tabs.map(\.title) == ["Settings", "BOGO", "Diagnostics"] && Set(ShellModel.tabs.map(\.symbol)).count == 3
        var online = true
        var failPair = false
        var requests = 0
        var pairing: PairingState!
        pairing = PairingState(paired: false, pair: { code in
            guard code == "[ab-test] code", !failPair else { throw URLError(.badServerResponse) }
        }, check: {
            requests += 1
            checks["connecting_state"] = pairing.connection == .checking && pairing.busy && pairing.status == "Connecting…"
            await pairing.check()
            guard online else { throw URLError(.notConnectedToInternet) }
        })
        checks["unpaired_status"] = pairing.status == "Not paired" && !pairing.busy
        await pairing.check()
        checks["unpaired_no_request"] = requests == 0 && pairing.connection == .unpaired
        await pairing.pair("invalid")
        checks["pair_failure"] = pairing.connection == .unpaired && !pairing.busy && pairing.status == "Pairing failed. Check the code and try again."
        await pairing.pair("[ab-test] code")
        checks["paired_status"] = pairing.status == "Paired" && !pairing.busy
        await pairing.check()
        checks["connected_status"] = pairing.status == "Paired · Connected" && !pairing.busy && requests == 1
        online = false
        await pairing.check()
        checks["offline_status"] = pairing.connection == .offline && pairing.status == "Offline. Check your connection and try again." && !pairing.busy
        online = true
        await pairing.check()
        checks["reconnect_status"] = pairing.connection == .connected && pairing.status == "Paired · Connected" && requests == 3 && !pairing.busy
        failPair = true
        await pairing.pair("[ab-test] code")
        checks["failed_repair_keeps_identity"] = pairing.connection == .connected && !pairing.busy
        await pairing.check()
        checks["status_recovers_after_error"] = pairing.status == "Paired · Connected"
        let restored = PairingState(paired: true, pair: { _ in }, check: {})
        checks["existing_pair_status"] = restored.status == "Paired"
        print(String(decoding: try JSONEncoder().encode(checks), as: UTF8.self))
        if checks.values.contains(false) { exit(1) }
    }
}
