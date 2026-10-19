import Foundation

extension ControllerBundleLayout {
    var hasEmbeddedController: Bool {
        guard let resourceURL else { return false }
        let binary = resourceURL.appendingPathComponent("ModelMatrixController")
        let plist = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(controllerLaunchAgentPlistName)"
        )
        return fileManager.isExecutableFile(atPath: binary.path)
            && fileManager.fileExists(atPath: plist.path)
    }

    var controllerBinaryURL: URL? {
        guard let resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("ModelMatrixController")
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    var controllerSupportURL: URL? {
        guard let resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("ControllerSupport", isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}
