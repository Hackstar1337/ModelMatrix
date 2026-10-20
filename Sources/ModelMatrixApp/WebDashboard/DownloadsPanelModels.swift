import Foundation

/// Download rows already carry the profile key and host that the controller
/// uses for connection details. Keep this mapping in a small model file so the
/// view never manufactures API identifiers or treats a display name as a key.
extension DownloadsPanelView {
    func connectTarget(for model: JSONRow) -> ConnectAppsTarget {
        let profile = model.string("profile")
        let host = model.string("host_name")
        let modelID = model.string("ready_model") ?? model.string("model_id") ?? model.string("id")
        let label = model.string("display_name") ?? model.string("repo") ?? modelID ?? "Downloaded model"
        return ConnectAppsTarget(profileKey: profile, host: host, modelID: modelID, label: label)
    }
}
