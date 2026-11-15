import Foundation

enum ShellTab: String, CaseIterable, Identifiable {
    case settings, bogo, diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .settings: return "Settings"
        case .bogo: return "BOGO"
        case .diagnostics: return "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .bogo: return "checkmark.shield"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

enum ShellModel {
    static let tabs = ShellTab.allCases
}
