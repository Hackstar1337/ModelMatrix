import SwiftUI

extension MenuBarContentView {
    enum InspectorPanel: String, Identifiable {
        case settings
        case help
        case benchmarks
        case remoteHosts
        case usage
        case profiles
        case optimize
        case downloads

        var id: String { rawValue }

        var title: String {
            switch self {
            case .settings: "Settings"
            case .help: "Help"
            case .benchmarks: "Benchmarks"
            case .remoteHosts: "Remote Hosts"
            case .usage: "Usage"
            case .profiles: "Profiles"
            case .optimize: "Optimize"
            case .downloads: "Hugging Face Downloads"
            }
        }
    }
}
