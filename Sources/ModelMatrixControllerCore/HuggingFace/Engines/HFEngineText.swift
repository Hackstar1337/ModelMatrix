import Foundation

/// Plain-text views of engines, plans and install jobs (CLI).
enum HFEngineText {
  static func render(_ engines: [HFEngineStatus], machine: HFMachine, jobs: [HFEngineJob]) -> String {
    let host = HFCheckText.hostFlag(machine)
    let place = machine.hostName ?? "this machine"
    var lines = ["Engines on \(place) (\(machine.chip), \(machine.architecture))", ""]
    for engine in engines {
      let name = engine.name.padding(toLength: 14, withPad: " ", startingAt: 0)
      if !engine.applicable {
        lines.append("  \(name)not available here: \(engine.note ?? "not supported")")
        continue
      }
      if engine.installed {
        var state = "installed"
        if let version = engine.version { state += " \(version)" }
        if let path = engine.path { state += " at \(path)" }
        lines.append("  \(name)\(state)")
        var details: [String] = []
        if let by = engine.installedBy {
          let through = engine.managed == true && by != "ModelMatrix" ? " (through ModelMatrix)" : ""
          details.append("installed by \(HFCheckText.installer(by))\(through)")
        }
        if engine.running == true {
          details.append("running")
        } else if engine.running == false {
          details.append(machine.hostName == nil ? "not running (open Ollama to start it)" : "not running (start it with: ollama serve)")
        }
        if !details.isEmpty { lines.append("  " + String(repeating: " ", count: 14) + details.joined(separator: ", ")) }
        let actions = (engine.actions ?? []).filter { $0 != "install" }
        if !actions.isEmpty {
          lines.append("  " + String(repeating: " ", count: 14) + actions.map { "\($0.capitalized): modelmatrixctl engine \($0) \(engine.id.rawValue)\(host)" }.joined(separator: "   "))
        }
      } else {
        lines.append("  \(name)not installed")
        if let install = engine.install, install.method == "manual" {
          let pad = "  " + String(repeating: " ", count: 14)
          lines.append(pad + "Install it yourself: \(install.command ?? install.source ?? "see the official site")")
          lines.append(pad + install.summary)
        } else if let install = engine.install {
          let how = install.command.map { "with \"\($0)\"" } ?? "from the official build"
          lines.append("  " + String(repeating: " ", count: 14) + "Install \(how): modelmatrixctl engine install \(engine.id.rawValue)\(host)")
        }
      }
    }
    if let job = jobs.first {
      lines += ["", "Last engine job: \(job.title): \(job.state.rawValue)\(job.error.map { " (\($0))" } ?? "")"]
    }
    lines += ["", "Installs always show a plan first and run only after you confirm."]
    return lines.joined(separator: "\n") + "\n"
  }

  /// Short "how" for a plan: Homebrew, or what ModelMatrix itself does.
  static func methodLabel(_ plan: HFEnginePlan) -> String {
    if plan.method == .homebrew { return "Homebrew" }
    if plan.action == .uninstall { return "remove the copy ModelMatrix installed" }
    switch plan.engine {
    case .llamaCpp: return "official build"
    case .mlxLM: return "private Python made by uv"
    case .ollama: return "official app"
    }
  }
  static func render(_ plan: HFEnginePlan) -> String {
    var lines = [plan.title, ""]
    func row(_ label: String, _ value: String) {
      lines.append("  " + (label + ":").padding(toLength: 16, withPad: " ", startingAt: 0) + value)
    }
    var engine = plan.engineName
    if let version = plan.version { engine += " \(plan.action == .uninstall ? "" : "version ")\(version)" }
    if let installed = plan.installedVersion, plan.action != .install { engine += " (installed now: \(installed))" }
    row("Engine", engine)
    row("Method", methodLabel(plan))
    for command in plan.commands { row("Runs", command) }
    for download in plan.downloads {
      row("Downloads", "\(download.name) (\(HFEngineInstaller.size(download.size)))")
      row("From", download.url)
      row("SHA-256", download.sha256)
    }
    row("Download size", plan.downloadSize)
    row(plan.action == .uninstall ? "Removes" : "Installs to", plan.location)
    row("Admin password", plan.needsAdmin ? "needed" : "not needed")
    if let removal = plan.removal { row("To remove", removal) }
    for note in plan.notes { lines.append("  - \(note)") }
    lines += ["", "Plan ID: \(plan.id) (valid until \(clock(plan.expiresAt)), usable once)"]
    return lines.joined(separator: "\n") + "\n"
  }

  static func render(_ job: HFEngineJob) -> String {
    var lines = ["\(job.title): \(job.state.rawValue)"]
    if let version = job.version, let path = job.path { lines.append("  \(job.engine.displayName) \(version) at \(path)") }
    if let error = job.error { lines.append("  Problem: \(error)") }
    if let manual = job.manualCommand, job.state == .failed { lines.append("  To do it yourself: \(manual)") }
    if !job.log.isEmpty { lines += ["", "Last log lines:"] + job.log.suffix(12).map { "  \($0)" } }
    return lines.joined(separator: "\n") + "\n"
  }

  /// "2026-10-19T17:30:00Z" -> local "23:00".
  static func clock(_ timestamp: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}
