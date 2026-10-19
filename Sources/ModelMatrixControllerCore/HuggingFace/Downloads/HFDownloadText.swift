import Foundation

/// Plain-English download list for `modelmatrixctl downloads`.
public enum HFDownloadText {
  public static func render(_ jobs: [HFDownloadJob]) -> String {
    guard !jobs.isEmpty else {
      return "No downloads yet. Start one with: modelmatrixctl download <owner/name>\n"
    }
    return jobs.map(render).joined(separator: "\n")
  }

  public static func render(_ job: HFDownloadJob) -> String {
    var lines: [String] = []
    var head = "\(job.id)  \(stateName(job))"
    if job.bytesTotal > 0 {
      let percent = Int((Double(job.bytesDone) / Double(job.bytesTotal) * 100).rounded(.down))
      head += "  \(percent)%  \(HFCheckService.gb(job.bytesDone)) of \(HFCheckService.gb(job.bytesTotal))"
    }
    if job.state == .downloading, job.speedBytesPerSecond > 0 {
      head += "  \(speed(job.speedBytesPerSecond))"
      if let eta = job.etaSeconds { head += ", \(duration(eta)) left" }
    }
    lines.append(head)
    var model = "  \(job.repo)  \(job.label)  (\(engineName(job.engine)))"
    if job.kind == "ollama", let name = job.ollamaModel {
      model += "  as Ollama model \(name)"
    } else if !job.folder.isEmpty {
      model += "  ->  \((job.folder as NSString).abbreviatingWithTildeInPath)"
    }
    if let host = job.hostName ?? job.host { model += "  on \(host)" }
    lines.append(model)
    if let message = job.message, !message.isEmpty, job.error == nil { lines.append("  \(message)") }
    if let error = job.error { lines.append("  Problem: \(error)") }
    for warning in job.warnings where job.state != .completed { lines.append("  Note: \(warning)") }
    if job.profile != nil || job.profileState != nil {
      let owner = job.profile ?? (job.kind == "ollama" ? "Ollama" : "not created yet")
      var text = "  Profile: \(owner)"
      if let state = job.profileState { text += " (\(profileStateName(state)))" }
      if let message = job.profileMessage { text += ". \(message)" }
      lines.append(text)
    }
    if job.profileState == .startFailed, let log = job.profileLog, !log.isEmpty {
      lines.append("  Last lines of the server log:")
      for line in log.suffix(8) { lines.append("    \(line)") }
    }
    if let url = job.readyUrl {
      lines.append("  Ready at \(url)\(job.readyModel.map { " as model \"\($0)\"" } ?? "")")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func stateName(_ job: HFDownloadJob) -> String {
    switch job.state {
    case .queued: return "Queued"
    case .downloading: return "Downloading"
    case .waiting:
      switch job.waitingFor {
      case "network": return "Waiting for network"
      case "disk": return "Waiting for disk space"
      case "rate_limit": return "Waiting (Hugging Face rate limit)"
      default: return "Retrying"
      }
    case .verifying: return "Checking"
    case .paused: return "Paused"
    case .completed: return "Done"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  static func profileStateName(_ state: HFProfileState) -> String {
    switch state {
    case .creating: return "creating"
    case .created: return "created"
    case .needsEngine: return "waiting for the engine"
    case .needsMemory: return "waiting for free memory"
    case .starting: return "starting"
    case .ready: return "ready"
    case .startFailed: return "didn't start"
    }
  }

  static func engineName(_ raw: String) -> String {
    HFEngineID(rawValue: raw)?.displayName ?? raw
  }

  static func speed(_ bytesPerSecond: Int64) -> String {
    let value = Double(bytesPerSecond) / 1_000_000
    return value >= 10 ? String(format: "%.0f MB/s", value) : String(format: "%.1f MB/s", value)
  }

  static func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "under a minute" }
    if seconds < 3600 { return "about \(seconds / 60) min" }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return minutes == 0 ? "about \(hours) h" : "about \(hours) h \(minutes) min"
  }
}
