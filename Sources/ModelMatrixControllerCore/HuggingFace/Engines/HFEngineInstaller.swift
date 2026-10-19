import Foundation

/// Installs, updates and removes engines, only through approved plans.
///
/// Two steps: `plan` describes exactly what would happen and returns a
/// one-time ID; `run` carries out that plan once, within 10 minutes. The
/// installer only runs its own fixed methods (never anything taken from a
/// model repository) and never touches engines you installed yourself.
public final class HFEngineInstaller: @unchecked Sendable {
  let probe: HFEngineProbe
  let machine: @Sendable () -> HFMachine
  let registry: HFEngineRegistry
  let releases: HFReleaseLookup
  let fetcher: HFEngineFetcher
  let runner: HFCommandRunning
  let now: @Sendable () -> Date
  /// Called after a job finishes (refresh checks, start waiting profiles).
  public var onFinished: (@Sendable (HFEngineJob) -> Void)?

  static let planLifetime: TimeInterval = 600
  let lock = NSLock()
  var plans: [String: HFEnginePlan] = [:]
  var jobs: [String: HFEngineJob] = [:]
  var jobOrder: [String] = []
  var stopFlags: [String: HFFlag] = [:]

  var root: String { probe.environment.enginesRoot }
  var home: String { probe.environment.home }

  init(
    probe: HFEngineProbe, machine: @escaping @Sendable () -> HFMachine, registryFile: URL,
    transport: HFTransport = URLSessionHFTransport(), streamer: HFByteStreamer = URLSessionByteStreamer(),
    runner: HFCommandRunning = HFProcessRunner(), now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.probe = probe
    self.machine = machine
    registry = HFEngineRegistry(file: registryFile)
    releases = HFReleaseLookup(transport: transport)
    fetcher = HFEngineFetcher(streamer: streamer)
    self.runner = runner
    self.now = now
    // Leftovers of an install that was interrupted.
    for engine in ["llama.cpp", "mlx-lm", "ollama"] {
      let folder = "\(root)/\(engine)"
      for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix(".incoming-") {
        try? FileManager.default.removeItem(atPath: "\(folder)/\(name)")
      }
    }
  }

  // MARK: Engines list

  /// Every engine on this machine with what ModelMatrix can do with it.
  public func engines(refresh: Bool = false) -> [HFEngineStatus] {
    if refresh { probe.refresh() }
    let machine = machine()
    return probe.detect(machine: machine).map { status in
      var status = status
      let record = registry.record(status.id)
      // Managed: the program found is the one ModelMatrix installed.
      let managed = record != nil && status.installed
        && (status.path == record?.path || (status.installedBy == "ModelMatrix" && record?.method == .official))
      status.managed = managed
      if managed, record?.method == .official { status.installedBy = "ModelMatrix" }
      var actions: [String] = []
      if status.applicable && !status.installed { actions.append(HFEngineAction.install.rawValue) }
      if managed {
        if !(status.id == .ollama && record?.method == .official) { actions.append(HFEngineAction.update.rawValue) }
        actions.append(HFEngineAction.uninstall.rawValue)
      }
      status.actions = actions
      return status
    }
  }

  var homebrew: String? {
    let directories = probe.environment.searchDirectories()
    return probe.homebrew(directories: directories, machine: machine())
  }

  // MARK: Plans

  /// Describes an install, update or uninstall and returns it with a
  /// one-time ID. Nothing is changed.
  public func plan(_ engine: HFEngineID, action: HFEngineAction, method requested: HFEngineMethod? = nil) throws -> HFEnginePlan {
    let machine = machine()
    probe.refresh()
    guard let status = probe.detect(machine: machine).first(where: { $0.id == engine }) else {
      throw HFError.unknownItem("Unknown engine \(engine.rawValue).")
    }
    guard status.applicable else { throw HFError.refused(status.note ?? "\(engine.displayName) can't run on this machine.") }
    var plan: HFEnginePlan
    switch action {
    case .install:
      if status.installed {
        let place = status.path.map { " at \($0)" } ?? ""
        throw HFError.conflict("\(engine.displayName) is already installed\(place)\(status.version.map { " (version \($0))" } ?? "").")
      }
      let brew = homebrew
      let method = requested ?? (brew != nil ? .homebrew : .official)
      if method == .homebrew {
        guard let brew else {
          throw HFError.refused("Homebrew isn't installed on this Mac. Use the official build instead (--method official).")
        }
        plan = homebrewPlan(engine, action: .install, brew: brew, installedVersion: nil)
      } else {
        plan = try officialInstallPlan(engine, machine: machine)
      }
    case .update, .uninstall:
      guard let record = registry.record(engine), status.installed else {
        if status.installed {
          throw HFError.refused(
            "\(engine.displayName) was installed by \(status.installedBy ?? "you"), not by ModelMatrix, so ModelMatrix leaves it alone. Update or remove it the way it was installed.")
        }
        throw HFError.conflict("\(engine.displayName) isn't installed.")
      }
      if record.method == .homebrew {
        guard let brew = homebrew else { throw HFError.refused("Homebrew is no longer available on this Mac.") }
        plan = homebrewPlan(engine, action: action, brew: brew, installedVersion: status.version)
      } else if action == .update {
        plan = try officialUpdatePlan(engine, machine: machine, record: record, installedVersion: status.version)
      } else {
        plan = officialUninstallPlan(engine, record: record, installedVersion: status.version)
      }
    }
    lock.lock()
    let cutoff = now()
    plans = plans.filter { $0.value.expires > cutoff }
    if plans.count >= 20, let oldest = plans.values.min(by: { $0.expires < $1.expires }) { plans[oldest.id] = nil }
    plans[plan.id] = plan
    lock.unlock()
    return plan
  }

  func newPlan(
    _ engine: HFEngineID, action: HFEngineAction, method: HFEngineMethod, title: String, programPath: String,
    location: String, steps: [HFEngineStep]
  ) -> HFEnginePlan {
    let created = now()
    let expires = created.addingTimeInterval(Self.planLifetime)
    return HFEnginePlan(
      id: "plan-" + HFEngineInstaller.randomHex(16), engine: engine, engineName: engine.displayName, action: action,
      method: method, version: nil, installedVersion: nil, title: title, commands: [], downloads: [],
      downloadSize: "", location: location, needsAdmin: false, removal: nil, notes: [],
      createdAt: HFFiles.timestamp(created), expiresAt: HFFiles.timestamp(expires), steps: steps, expires: expires,
      programPath: programPath)
  }

  static func randomHex(_ bytes: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }

  // MARK: Homebrew route

  static func homebrewName(_ engine: HFEngineID) -> [String] {
    switch engine {
    case .llamaCpp: return ["llama.cpp"]
    case .mlxLM: return ["mlx-lm"]
    case .ollama: return ["--cask", "ollama-app"]
    }
  }

  func homebrewPlan(_ engine: HFEngineID, action: HFEngineAction, brew: String, installedVersion: String?) -> HFEnginePlan {
    let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let verb = ["install": "install", "update": "upgrade", "uninstall": "uninstall"][action.rawValue] ?? "install"
    let arguments = [verb] + Self.homebrewName(engine)
    let program = engine == .ollama ? "/Applications/Ollama.app/Contents/Resources/ollama" : "\(prefix)/bin/\(engine.executable)"
    let location = engine == .ollama ? "/Applications/Ollama.app" : "\(prefix) (Homebrew)"
    let titles = [
      HFEngineAction.install: "Install \(engine.displayName) with Homebrew",
      .update: "Update \(engine.displayName) with Homebrew",
      .uninstall: "Uninstall \(engine.displayName) with Homebrew",
    ]
    var environment = Self.baseEnvironment(home: home, path: "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
    environment["HOMEBREW_NO_ENV_HINTS"] = "1"
    environment["NONINTERACTIVE"] = "1"
    var plan = newPlan(
      engine, action: action, method: .homebrew, title: titles[action] ?? "", programPath: program, location: location,
      steps: [.run(program: brew, arguments: arguments, environment: environment)])
    plan.commands = ["brew " + arguments.joined(separator: " ")]
    plan.installedVersion = installedVersion
    if action != .uninstall {
      plan.version = homebrewVersion(brew: brew, engine: engine, environment: environment)
      plan.downloadSize =
        "Decided by Homebrew: \(engine.displayName) plus any packages it needs that aren't installed yet. The live log lists each one."
      plan.removal = "brew uninstall " + Self.homebrewName(engine).joined(separator: " ")
      plan.notes = ["Homebrew may also update packages that \(engine.displayName) depends on.", "No administrator password is needed."]
      if engine == .ollama {
        plan.notes.append("Homebrew puts Ollama in /Applications. If macOS would need a password for that, the install stops instead; then choose the official build.")
        plan.notes.append("Open Ollama once afterwards so it runs in the background.")
      }
    } else {
      plan.downloadSize = "Nothing is downloaded."
      plan.notes = ["Models you downloaded stay where they are."]
    }
    return plan
  }

  func homebrewVersion(brew: String, engine: HFEngineID, environment: [String: String]) -> String? {
    let collector = HFLineCollector()
    let arguments = ["info", "--json=v2"] + Self.homebrewName(engine)
    guard (try? runner.run(brew, arguments, environment: environment, output: collector.add, shouldStop: { false })) == 0,
      let object = try? JSONSerialization.jsonObject(with: Data(collector.text.utf8)) as? [String: Any]
    else { return nil }
    if engine == .ollama {
      return ((object["casks"] as? [[String: Any]])?.first?["version"] as? String)
    }
    let versions = (object["formulae"] as? [[String: Any]])?.first?["versions"] as? [String: Any]
    return versions?["stable"] as? String
  }

  static func baseEnvironment(home: String, path: String) -> [String: String] {
    var environment = ["HOME": home, "PATH": path, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    let current = ProcessInfo.processInfo.environment
    for key in ["USER", "LOGNAME", "http_proxy", "https_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "all_proxy"] {
      if let value = current[key] { environment[key] = value }
    }
    if environment["USER"] == nil, let entry = getpwuid(getuid()) { environment["USER"] = String(cString: entry.pointee.pw_name) }
    return environment
  }

  // MARK: Official route

  static func llamaPlatform(_ machine: HFMachine) -> String {
    machine.architecture == "arm64" ? "macos-arm64" : "macos-x64"
  }

  func officialInstallPlan(_ engine: HFEngineID, machine: HFMachine) throws -> HFEnginePlan {
    switch engine {
    case .llamaCpp:
      let platform = Self.llamaPlatform(machine)
      let asset = try releases.llamaCpp(platform: platform)
      var plan = newPlan(
        engine, action: .install, method: .official, title: "Install the official llama.cpp build \(asset.tag) for this Mac",
        programPath: "\(HFEngineFolders.llamaBin(root))/llama-server", location: "\(root)/llama.cpp",
        steps: [.unpack(download: asset.download, into: "\(root)/llama.cpp", keep: "llama-\(asset.tag)", name: asset.tag, linkBin: true)])
      plan.version = asset.tag
      plan.downloads = [asset.download]
      plan.downloadSize = HFEngineInstaller.size(asset.download.size)
      plan.removal = "modelmatrixctl engine uninstall llama.cpp (deletes \(root)/llama.cpp)"
      plan.notes = [
        "Downloaded from the llama.cpp project's GitHub releases and checked against its published SHA-256.",
        "No administrator password is needed.",
      ]
      if !machine.appleSilicon { plan.notes.append("On Intel Macs llama.cpp runs on the processor.") }
      return plan
    case .mlxLM:
      let asset = try releases.latest("astral-sh/uv", asset: "uv-aarch64-apple-darwin.tar.gz")
      let base = "\(root)/mlx-lm"
      let uv = "\(base)/uv/uv"
      let environment = uvEnvironment(base)
      let steps: [HFEngineStep] = [
        .unpack(download: asset.download, into: base, keep: "uv-aarch64-apple-darwin", name: "uv", linkBin: false),
        .run(program: uv, arguments: ["python", "install", "--no-bin", "3.12"], environment: environment),
        .run(program: uv, arguments: ["venv", "--python", "3.12", "\(base)/venv"], environment: environment),
        .run(program: uv, arguments: ["pip", "install", "--python", "\(base)/venv/bin/python", "mlx-lm"], environment: environment),
        .remove(path: "\(base)/cache", toTrash: false),
      ]
      var plan = newPlan(
        engine, action: .install, method: .official, title: "Install mlx-lm into a private Python made by uv",
        programPath: "\(HFEngineFolders.mlxBin(root))/mlx_lm.server", location: base, steps: steps)
      plan.version = releases.pypiVersion("mlx-lm")
      plan.downloads = [asset.download]
      plan.commands = [
        "uv python install --no-bin 3.12", "uv venv --python 3.12 \(base)/venv",
        "uv pip install --python \(base)/venv/bin/python mlx-lm",
      ]
      plan.downloadSize = "\(HFEngineInstaller.size(asset.download.size)) for uv \(asset.tag), then about 300 to 500 MB for Python 3.12 and mlx-lm"
      plan.removal = "modelmatrixctl engine uninstall mlx-lm (deletes \(base))"
      plan.notes = [
        "uv is the official Python tool from Astral, checked against its published SHA-256. It installs a private Python that only ModelMatrix uses.",
        "Python and mlx-lm come from python.org builds and PyPI. Your own Python is not changed.",
        "No administrator password is needed.",
      ]
      return plan
    case .ollama:
      let asset = try releases.latest("ollama/ollama", asset: "Ollama-darwin.zip")
      let destination = "\(home)/Applications/Ollama.app"
      guard !FileManager.default.fileExists(atPath: destination) else {
        throw HFError.conflict("Ollama.app is already on this Mac. Open it once so ModelMatrix can find it.")
      }
      var plan = newPlan(
        engine, action: .install, method: .official, title: "Install the official Ollama app \(asset.tag)",
        programPath: "\(destination)/Contents/Resources/ollama", location: destination,
        steps: [.placeApp(download: asset.download, app: "Ollama.app", destination: destination)])
      plan.version = asset.tag
      plan.downloads = [asset.download]
      plan.downloadSize = HFEngineInstaller.size(asset.download.size)
      plan.removal = "modelmatrixctl engine uninstall ollama (moves Ollama.app to the Trash)"
      plan.notes = [
        "Downloaded from Ollama's GitHub releases and checked against its published SHA-256.",
        "Installed into your own Applications folder, so no administrator password is needed.",
        "Open Ollama once afterwards so it runs in the background; it then updates itself.",
      ]
      return plan
    }
  }

  func uvEnvironment(_ base: String) -> [String: String] {
    var environment = Self.baseEnvironment(home: home, path: "\(base)/uv:/usr/bin:/bin:/usr/sbin:/sbin")
    environment["UV_PYTHON_INSTALL_DIR"] = "\(base)/python"
    // Never put python shortcuts in ~/.local/bin: everything stays in base.
    environment["UV_PYTHON_BIN_DIR"] = "\(base)/python/bin"
    environment["UV_PYTHON_INSTALL_BIN"] = "0"
    environment["UV_CACHE_DIR"] = "\(base)/cache"
    environment["UV_PYTHON_PREFERENCE"] = "only-managed"
    environment["UV_NO_CONFIG"] = "1"
    environment["UV_NO_PROGRESS"] = "1"
    return environment
  }

  func officialUpdatePlan(_ engine: HFEngineID, machine: HFMachine, record: HFEngineRecord, installedVersion: String?) throws -> HFEnginePlan {
    switch engine {
    case .llamaCpp:
      let asset = try releases.llamaCpp(platform: Self.llamaPlatform(machine))
      if let current = record.version, current == asset.tag {
        throw HFError.conflict("llama.cpp \(current) is already the newest official build.")
      }
      var steps: [HFEngineStep] = [
        .unpack(download: asset.download, into: "\(root)/llama.cpp", keep: "llama-\(asset.tag)", name: asset.tag, linkBin: true)
      ]
      if let old = record.version, old != asset.tag, !old.contains("/") { steps.append(.remove(path: "\(root)/llama.cpp/\(old)", toTrash: false)) }
      var plan = newPlan(
        engine, action: .update, method: .official, title: "Update llama.cpp to the official build \(asset.tag)",
        programPath: "\(HFEngineFolders.llamaBin(root))/llama-server", location: "\(root)/llama.cpp", steps: steps)
      plan.version = asset.tag
      plan.installedVersion = record.version ?? installedVersion
      plan.downloads = [asset.download]
      plan.downloadSize = HFEngineInstaller.size(asset.download.size)
      plan.notes = ["The old build is deleted after the new one is in place. Running models keep running until restarted."]
      return plan
    case .mlxLM:
      let base = "\(root)/mlx-lm"
      var plan = newPlan(
        engine, action: .update, method: .official, title: "Update mlx-lm in its private Python",
        programPath: "\(HFEngineFolders.mlxBin(root))/mlx_lm.server", location: base,
        steps: [
          .run(program: "\(base)/uv/uv", arguments: ["pip", "install", "--upgrade", "--python", "\(base)/venv/bin/python", "mlx-lm"], environment: uvEnvironment(base)),
          .remove(path: "\(base)/cache", toTrash: false),
        ])
      plan.version = releases.pypiVersion("mlx-lm")
      plan.installedVersion = installedVersion
      plan.commands = ["uv pip install --upgrade --python \(base)/venv/bin/python mlx-lm"]
      plan.downloadSize = "Only what changed in mlx-lm and its packages (usually under 100 MB)"
      return plan
    case .ollama:
      throw HFError.refused("Ollama updates itself: open Ollama and choose Check for updates in its menu.")
    }
  }

  func officialUninstallPlan(_ engine: HFEngineID, record: HFEngineRecord, installedVersion: String?) -> HFEnginePlan {
    let toTrash = engine == .ollama
    var plan = newPlan(
      engine, action: .uninstall, method: .official, title: "Uninstall \(engine.displayName)", programPath: record.path,
      location: record.location, steps: [.remove(path: record.location, toTrash: toTrash)])
    plan.installedVersion = record.version ?? installedVersion
    plan.downloadSize = "Nothing is downloaded."
    plan.commands = []
    plan.notes = [
      toTrash ? "Ollama.app is moved to the Trash. Models Ollama downloaded stay in ~/.ollama." : "Deletes \(record.location).",
      "Models you downloaded stay where they are.",
    ]
    return plan
  }

  static func size(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000 ? HFCheckService.gb(bytes) : String(format: "%.1f MB", Double(bytes) / 1_000_000)
  }
}

/// Collects command output (for small probes such as `brew info`).
final class HFLineCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func add(_ line: String) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return lines.joined(separator: "\n")
  }
}
