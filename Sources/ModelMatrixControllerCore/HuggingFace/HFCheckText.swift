import Foundation

/// Plain-text rendering of a check, for `modelmatrixctl check`.
public enum HFCheckText {
  public static func render(_ report: HFCheckReport) -> String {
    var lines: [String] = []
    if report.kind == "search" {
      renderSearch(report, into: &lines)
      return lines.joined(separator: "\n") + "\n"
    }
    if let repo = report.repo {
      lines.append(repo.id)
      lines.append(repo.url)
    }
    if let format = report.format {
      lines.append(row("Format", "\(format.name). \(format.summary)"))
    }
    if let task = report.task {
      var what = task.description.prefix(1).uppercased() + task.description.dropFirst()
      if let parameters = report.model?.parameters { what += ", \(params(parameters)) parameters" }
      if let max = report.model?.maxContext { what += ", up to \(tokens(max)) context" }
      lines.append(row("Type", what))
    }
    if let repo = report.repo {
      let access = repo.loginRequired ? "needs a Hugging Face login" : "open, no login needed"
      lines.append(row("License", "\(repo.license ?? "not stated") (\(access))"))
    }
    if let name = report.machine.hostName {
      lines.append(row("Host", "\(name): " + machine(report.machine)))
    } else {
      lines.append(row("This Mac", machine(report.machine)))
    }
    if let engine = report.engine, engine.needed != nil || report.verdict.runnable {
      renderEngines(engine, host: hostFlag(report.machine), into: &lines)
    }
    lines.append("")
    lines.append(row("Result", "\(shout(report.verdict.title, keeping: report.machine.hostName)). \(report.verdict.detail)"))
    if let pick = report.recommendation {
      let fitText = ["good": "fits well", "tight": "fits tightly", "too_big": "may not fit in memory"][pick.level] ?? pick.level
      let label = report.variants.contains { $0.label == pick.label && $0.recommended } ? "Recommended" : "Selected"
      lines.append(
        row(label, "\(pick.label): \(gb(pick.downloadBytes)) download, about \(mem(pick.needBytes)) in use at \(tokens(pick.context)) context, \(fitText)."))
      lines.append(row("", pick.reason))
    }
    if let folder = report.downloadFolder {
      let shown = (folder as NSString).abbreviatingWithTildeInPath
      lines.append(row("Saves to", report.downloadAvailable ? shown : "\(shown) (downloading comes in the next update)"))
      if report.downloadAvailable, let repo = report.repo {
        let label = report.recommendation.map { ":" + $0.label } ?? ":LABEL"
        lines.append(row("Download", "modelmatrixctl download \(repo.id)\(label)\(hostFlag(report.machine))"))
      }
    }
    if !report.variants.isEmpty, let model = report.model {
      renderVariants(report, model: model, into: &lines)
    }
    if !report.alternatives.isEmpty {
      lines.append("")
      lines.append(report.verdict.code == "use_alternative" ? "Ready-to-run versions of this model:" : "Other versions:")
      for item in report.alternatives { lines.append("  " + alternative(item)) }
      lines.append("Check one with: modelmatrixctl check <owner/name>\(hostFlag(report.machine))")
    }
    if !report.notes.isEmpty {
      lines.append("")
      lines.append("Notes:")
      for note in report.notes { lines.append("  - " + note) }
    }
    lines.append("")
    lines.append("Nothing was downloaded or installed.")
    return lines.joined(separator: "\n") + "\n"
  }

  static func renderSearch(_ report: HFCheckReport, into lines: inout [String]) {
    lines.append(report.verdict.detail)
    if !report.searchResults.isEmpty {
      lines.append("")
      for item in report.searchResults { lines.append("  " + alternative(item)) }
      lines.append("")
      lines.append("Check one with: modelmatrixctl check <owner/name>\(hostFlag(report.machine))")
    }
  }

  static func renderEngines(_ engine: HFEngineSummary, host: String = "", into lines: inout [String]) {
    for status in engine.engines where status.id == engine.needed || status.id == engine.backup {
      let label = status.id == engine.needed ? "Engine" : "Backup"
      lines.append(row(label, engineLine(status)))
      if !status.installed, let install = status.install {
        let how = install.command ?? "download from \(install.source ?? "the official site")"
        if install.method == "manual" {
          lines.append(row("", "To install: run this yourself: \(how)"))
          lines.append(row("", "            \(install.summary)"))
        } else if engine.installerAvailable {
          lines.append(row("", "To install: modelmatrixctl engine install \(status.id.rawValue)\(host)"))
          lines.append(row("", "            (shows the plan first and installs only after you confirm)"))
          lines.append(row("", "            Method: \(install.command ?? install.summary)"))
        } else {
          lines.append(row("", "To install: \(how)"))
          lines.append(row("", "            \(install.summary)"))
        }
        lines.append(row("", "To remove:  \(install.removal)"))
      }
    }
  }

  static func engineLine(_ status: HFEngineStatus) -> String {
    guard status.applicable else { return "\(status.name): \(status.note ?? "not available here")" }
    guard status.installed else { return "\(status.name): not installed" }
    var text = "\(status.name): installed"
    var details: [String] = []
    if let version = status.version { details.append(version) }
    if let by = status.installedBy { details.append("by \(installer(by))") }
    if let running = status.running { details.append(running ? "running" : "not running") }
    if !details.isEmpty { text += " (" + details.joined(separator: ", ") + ")" }
    if let path = status.path { text += " at \(path)" }
    return text
  }

  static func renderVariants(_ report: HFCheckReport, model: HFModelSummary, into lines: inout [String]) {
    lines.append("")
    lines.append("Versions (memory at \(tokens(model.context)) context; fits well = at most two thirds of \(mem(report.machine.budgetBytes))):")
    let header = [pad("", 2), pad("Version", 14), pad("Download", 10), pad("Quality", 30), pad("Memory", 9), pad("Fit", 12), "Longest good context"]
    lines.append(header.joined())
    for variant in report.variants {
      let mark = variant.recommended ? "* " : (variant.supported ? "  " : "x ")
      let fit: String
      let memory: String
      if let value = variant.fit {
        memory = mem(value.needBytes)
        fit = ["good": "fits well", "tight": "tight", "too_big": "too big"][value.level] ?? value.level
      } else {
        memory = "-"
        fit = "can't use"
      }
      var quality = variant.quality
      if let bits = variant.bitsPerWeight { quality += String(format: ", %.1f bits", bits) }
      let longest = variant.longestGoodContext.map(tokens) ?? "-"
      lines.append(
        [mark, pad(variant.label, 14), pad(gb(variant.downloadBytes), 10), pad(quality, 30), pad(memory, 9), pad(fit, 12), longest]
          .joined())
      if let reason = variant.unsupportedReason { lines.append("    " + reason) }
      if variant.supported, variant.fitsOnDisk == false { lines.append("    Not enough free disk space for this version.") }
    }
    lines.append("* recommended   x can't be used")
  }

  /// " --host NAME" for a remote host's commands (quoted when needed), else "".
  static func hostFlag(_ machine: HFMachine) -> String {
    guard let name = machine.hostName, !name.isEmpty else { return "" }
    let plain = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    return " --host " + (plain ? name : "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'")
  }

  /// Who installed an engine, in plain words ("manual" means the user did).
  static func installer(_ by: String) -> String {
    switch by.lowercased() {
    case "manual", "user", "unknown": return "you"
    case "homebrew", "brew": return "Homebrew"
    default: return by
    }
  }

  static func machine(_ machine: HFMachine) -> String {
    var parts = ["\(machine.chip), \(mem(machine.memoryBytes)) memory"]
    if let gpu = machine.gpu, !gpu.isEmpty { parts.append(gpu) }
    let source = machine.budgetSource == "metal" ? "measured" : (machine.budgetSource == "cpu" ? "processor only" : "estimated")
    parts.append("a model may use \(mem(machine.budgetBytes)) (\(source))")
    if let free = machine.freeDiskBytes { parts.append("\(gb(free)) free disk") }
    return parts.joined(separator: ", ")
  }

  static func alternative(_ item: HFAlternative) -> String {
    var text = pad(item.repo, 52) + pad(item.format.uppercased(), 6)
    if let downloads = item.downloads { text += "\(grouped(downloads)) downloads" }
    if item.gated { text += ", login needed" }
    if item.sameModel == false { text += ", modified version" }
    return text
  }

  static func row(_ label: String, _ value: String) -> String {
    (label.isEmpty ? pad("", 13) : pad(label + ":", 13)) + value
  }

  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
  }

  static func gb(_ bytes: Int64) -> String { HFCheckService.gb(bytes) }
  static func mem(_ bytes: Int64) -> String { HFCheckService.mem(bytes) }

  static func tokens(_ value: Int) -> String {
    value >= 1024 && value % 1024 == 0 ? "\(value / 1024)K" : "\(value)"
  }

  static func params(_ value: Int64) -> String {
    let billions = Double(value) / 1e9
    return billions >= 0.9995 ? String(format: "%.1fB", billions) : String(format: "%.0fM", billions * 1000)
  }

  static func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  /// Upper-cases a verdict title for emphasis but keeps a host's own spelling.
  static func shout(_ title: String, keeping name: String?) -> String {
    let loud = title.uppercased()
    guard let name, !name.isEmpty, let range = loud.range(of: name.uppercased()) else { return loud }
    return loud.replacingCharacters(in: range, with: name)
  }
}
