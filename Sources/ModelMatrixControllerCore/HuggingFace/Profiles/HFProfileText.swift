import Foundation

struct HFDownloadedModelList: Encodable {
  let models: [HFDownloadedModel]
  let untracked: [HFUntrackedFolder]
  /// With ?host=all: hosts that couldn't be reached.
  var unreachable: [String]?
}

/// Plain-English "Downloaded models" list for `modelmatrixctl models`.
public enum HFProfileText {
  public static func render(_ models: [HFDownloadedModel], untracked: [HFUntrackedFolder]) -> String {
    var lines: [String] = []
    if models.isEmpty {
      lines.append("No downloaded models yet. Check one with: modelmatrixctl check <owner/name>")
    } else {
      let total = models.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
      lines.append("Downloaded models (\(models.count), \(HFCheckService.gb(total)) on disk)")
      for model in models {
        lines.append("")
        lines.append("\(model.id)  \(model.displayName)  \(HFCheckService.gb(model.bytesOnDisk))")
        var where_ = "  \(model.repo)  (\(HFDownloadText.engineName(model.engine)))"
        if model.kind == "ollama" {
          where_ += "  stored by Ollama"
        } else {
          where_ += "  ->  \((model.folder as NSString).abbreviatingWithTildeInPath)"
        }
        if let host = model.hostName { where_ += "  on \(host)" }
        lines.append(where_)
        if model.missingFiles > 0 {
          lines.append("  Problem: \(model.missingFiles) file(s) are missing from the folder.")
        }
        var status = "  Profile: \(model.profile ?? (model.kind == "ollama" ? "Ollama" : "none"))"
        if let raw = model.profileState, let state = HFProfileState(rawValue: raw) {
          status += " (\(HFDownloadText.profileStateName(state)))"
        }
        lines.append(status)
        if let message = model.profileMessage, !message.isEmpty { lines.append("  \(message)") }
      }
      lines.append("")
      lines.append("Delete one with: modelmatrixctl model delete <id> [--files]")
    }
    if !untracked.isEmpty {
      lines.append("")
      lines.append("Other folders in the models folder (not downloaded by ModelMatrix, left untouched):")
      for folder in untracked {
        lines.append("  \((folder.folder as NSString).abbreviatingWithTildeInPath)  \(HFCheckService.gb(folder.bytesOnDisk))")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
