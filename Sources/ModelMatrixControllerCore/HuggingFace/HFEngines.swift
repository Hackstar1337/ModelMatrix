import Darwin
import Foundation

public enum HFEngineID: String, Sendable, Encodable, CaseIterable {
  case llamaCpp = "llama.cpp"
  case mlxLM = "mlx-lm"
  case ollama

  public var displayName: String {
    switch self {
    case .llamaCpp: return "llama.cpp"
    case .mlxLM: return "MLX (mlx-lm)"
    case .ollama: return "Ollama"
    }
  }

  /// The program ModelMatrix starts for this engine.
  var executable: String {
    switch self {
    case .llamaCpp: return "llama-server"
    case .mlxLM: return "mlx_lm.server"
    case .ollama: return "ollama"
    }
  }
}

/// How an engine could be installed on this machine. Shown to the user;
/// ModelMatrix only ever installs after the user approves.
public struct HFInstallOption: Sendable, Encodable, Equatable {
  /// "homebrew" or "official".
  public var method: String
  public var summary: String
  /// Terminal command for Homebrew installs.
  public var command: String?
  /// Official download page.
  public var source: String?
  public var location: String
  public var removal: String
}

public struct HFEngineStatus: Sendable, Encodable, Equatable {
  public var id: HFEngineID
  public var name: String
  /// Whether this engine can run on this machine at all.
  public var applicable: Bool
  public var installed: Bool
  public var path: String?
  public var version: String?
  /// "Homebrew", "ModelMatrix", "Ollama app", "pipx or uv", "conda",
  /// "MacPorts" or "manual".
  public var installedBy: String?
  /// Ollama only: whether its background service answers.
  public var running: Bool?
  public var note: String?
  public var install: HFInstallOption?
  /// ModelMatrix installed it, so it can update or uninstall it.
  public var managed: Bool?
  /// What ModelMatrix can do with it now (install, update, uninstall).
  public var actions: [String]?
}

/// Where to look and how to run probes; replaceable in tests.
public struct HFEngineEnvironment: Sendable {
  public var home: String
  public var searchDirectories: @Sendable () -> [String]
  public var isExecutable: @Sendable (String) -> Bool
  public var resolve: @Sendable (String) -> String
  public var run: @Sendable (String, [String]) -> String?
  public var ollamaServerVersion: @Sendable () -> String?
  /// Where ModelMatrix installs engines.
  public var enginesRoot: String
  /// Act as if Homebrew weren't installed (tests of the official route).
  public var ignoreHomebrew: Bool

  public init(
    home: String, searchDirectories: @escaping @Sendable () -> [String],
    isExecutable: @escaping @Sendable (String) -> Bool, resolve: @escaping @Sendable (String) -> String,
    run: @escaping @Sendable (String, [String]) -> String?,
    ollamaServerVersion: @escaping @Sendable () -> String?,
    enginesRoot: String? = nil, ignoreHomebrew: Bool = false
  ) {
    self.home = home
    self.searchDirectories = searchDirectories
    self.isExecutable = isExecutable
    self.resolve = resolve
    self.run = run
    self.ollamaServerVersion = ollamaServerVersion
    self.enginesRoot = enginesRoot ?? "\(home)/ModelMatrix/Engines"
    self.ignoreHomebrew = ignoreHomebrew
  }

  public static func live() -> HFEngineEnvironment {
    let home = NSHomeDirectory()
    let root = HFEngineFolders.root(home: home)
    let ignoreHomebrew = HFEngineFolders.ignoreHomebrew
    return HFEngineEnvironment(
      home: home,
      searchDirectories: { HFEngineSearchPath.directories(home: home, enginesRoot: root, ignoreHomebrew: ignoreHomebrew) },
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      run: { HFProbeProcess.run($0, $1, timeout: 8) },
      ollamaServerVersion: {
        let url = URL(string: "http://127.0.0.1:11434/api/version")!
        return UsageService.fetchJSON(url, timeout: 1)?["version"] as? String
      },
      enginesRoot: root, ignoreHomebrew: ignoreHomebrew)
  }
}

/// Folders where engines are commonly installed, plus the user's login
/// shell PATH (so custom installs are found too).
enum HFEngineSearchPath {
  nonisolated(unsafe) private static var cachedShellPath: (Date, [String])?
  private static let lock = NSLock()

  static func directories(home: String, enginesRoot: String, ignoreHomebrew: Bool = false) -> [String] {
    var list = [HFEngineFolders.llamaBin(enginesRoot), HFEngineFolders.mlxBin(enginesRoot)]
    list += loginShellPath()
    list += [
      "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin", "\(home)/bin",
      "\(enginesRoot)/bin", "\(home)/ModelMatrix/Engines/llama.cpp/bin", "\(home)/ModelMatrix/Engines/mlx-lm/venv/bin",
      "\(home)/miniforge3/bin", "\(home)/mambaforge/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin",
      "/opt/homebrew/Caskroom/miniforge/base/bin", "/opt/miniconda3/bin", "\(home)/.pyenv/shims",
      "/Applications/Ollama.app/Contents/Resources", "\(home)/Applications/Ollama.app/Contents/Resources",
    ]
    for base in ["\(home)/miniforge3/envs", "\(home)/mambaforge/envs", "\(home)/miniconda3/envs", "\(home)/anaconda3/envs"] {
      let envs = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
      list += envs.sorted().prefix(20).map { "\(base)/\($0)/bin" }
    }
    if ignoreHomebrew {
      list.removeAll { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/usr/local/") }
    }
    var seen = Set<String>()
    return list.filter { !$0.isEmpty && $0.hasPrefix("/") && seen.insert($0).inserted }
  }

  /// PATH from the user's login shell (Homebrew and other installers add to
  /// it there). Cached for ten minutes; empty if the shell is unusual or slow.
  static func loginShellPath() -> [String] {
    lock.lock()
    if let (date, value) = cachedShellPath, Date().timeIntervalSince(date) < 600 {
      lock.unlock()
      return value
    }
    lock.unlock()
    var shell = "/bin/zsh"
    if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
      let candidate = String(cString: raw)
      if ["/bin/zsh", "/bin/bash", "/usr/local/bin/bash", "/opt/homebrew/bin/bash"].contains(candidate) {
        shell = candidate
      }
    }
    let output = HFProbeProcess.run(shell, ["-l", "-c", "printf '\\n__MMX__%s' \"$PATH\""], timeout: 4) ?? ""
    var value: [String] = []
    if let marker = output.range(of: "__MMX__", options: .backwards) {
      value = output[marker.upperBound...].split(separator: ":").map(String.init)
        .filter { $0.hasPrefix("/") && $0 != "/usr/bin" && $0 != "/bin" && $0 != "/usr/sbin" && $0 != "/sbin" }
    }
    lock.lock()
    cachedShellPath = (Date(), value)
    lock.unlock()
    return value
  }
}

/// Finds installed engines, reads their versions and prepares install
/// advice. Read-only: it never installs, updates or starts anything.
public final class HFEngineProbe: @unchecked Sendable {
  let environment: HFEngineEnvironment
  private let lock = NSLock()
  private var cache: (Date, String, [HFEngineStatus])?
  private var configured: [String: String] = [:]
  static let cacheSeconds: TimeInterval = 30

  /// Engine locations set in Settings; they win over the search.
  public func setConfiguredPaths(_ paths: [String: String]) {
    lock.lock()
    if paths != configured {
      configured = paths
      cache = nil
    }
    lock.unlock()
  }

  var configuredPaths: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return configured
  }

  public init(environment: HFEngineEnvironment = .live()) {
    self.environment = environment
  }

  public func detect(machine: HFMachine) -> [HFEngineStatus] {
    lock.lock()
    if let (date, key, value) = cache, key == machine.architecture,
      Date().timeIntervalSince(date) < Self.cacheSeconds
    {
      lock.unlock()
      return value
    }
    lock.unlock()
    let directories = environment.searchDirectories()
    let brew = homebrew(directories: directories, machine: machine)
    let value = HFEngineID.allCases.map { status($0, directories: directories, brew: brew, machine: machine) }
    lock.lock()
    cache = (Date(), machine.architecture, value)
    lock.unlock()
    return value
  }

  /// Forget cached results ("Check again").
  public func refresh() {
    lock.lock()
    cache = nil
    lock.unlock()
  }

  /// Ollama's app bundle carries private helper programs (including its own
  /// llama-server); only `ollama` itself is taken from there.
  func find(_ executable: String, in directories: [String]) -> String? {
    for directory in directories where executable == "ollama" || !directory.contains("Ollama.app/") {
      let path = (directory as NSString).appendingPathComponent(executable)
      if environment.isExecutable(path) { return path }
    }
    return nil
  }

  func homebrew(directories: [String], machine: HFMachine) -> String? {
    if environment.ignoreHomebrew { return nil }
    let preferred = machine.architecture == "arm64" ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
    if environment.isExecutable(preferred) { return preferred }
    return find("brew", in: directories)
  }

  func status(_ id: HFEngineID, directories: [String], brew: String?, machine: HFMachine) -> HFEngineStatus {
    var result = HFEngineStatus(
      id: id, name: id.displayName, applicable: true, installed: false, path: nil, version: nil,
      installedBy: nil, running: nil, note: nil, install: nil)
    if id == .mlxLM, !machine.appleSilicon {
      result.applicable = false
      result.note = machine.rosetta
        ? "MLX needs the Apple Silicon version of ModelMatrix (this copy runs through Rosetta)."
        : "MLX runs only on Apple Silicon Macs."
      return result
    }
    let chosen = configuredPaths[id.rawValue].flatMap { environment.isExecutable($0) ? $0 : nil }
    if let path = chosen ?? find(id.executable, in: directories) {
      let resolved = environment.resolve(path)
      result.installed = true
      result.path = path
      result.installedBy =
        chosen != nil
        ? "you (set in Settings)"
        : Self.installedBy(path: path, resolved: resolved, home: environment.home, enginesRoot: environment.enginesRoot)
      result.version = version(id, path: path, resolved: resolved)
    }
    if id == .ollama {
      if let serverVersion = environment.ollamaServerVersion() {
        result.running = true
        result.installed = true
        result.version = result.version ?? serverVersion
      } else if result.installed {
        result.running = false
      }
    }
    if !result.installed {
      result.install = Self.installOption(id, brew: brew, machine: machine, home: environment.home, enginesRoot: environment.enginesRoot)
    }
    return result
  }

  func version(_ id: HFEngineID, path: String, resolved: String) -> String? {
    if let cellar = Self.cellarVersion(resolved), id != .llamaCpp { return cellar }
    switch id {
    case .llamaCpp:
      // "version: 7034 (a1b2c3d)" (build number), "version: 0.7.0 (a1b2c3d)",
      // or "version: 0.7.0-dev (build 11738, commit f174553e1)".
      guard let output = environment.run(path, ["--version"]) else { return Self.cellarVersion(resolved) }
      if let match = output.range(of: #"\(build [0-9]+"#, options: .regularExpression) {
        return "b" + output[match].dropFirst(7)
      }
      if let match = output.range(of: #"version: [0-9][0-9.]* \([0-9a-f]+\)"#, options: .regularExpression) {
        let text = String(output[match].dropFirst(9))
        return text.first(where: { $0 == "." || $0 == " " }) == " " ? "b" + text : text
      }
      return Self.cellarVersion(resolved)
    case .mlxLM:
      guard let python = Self.interpreter(ofScript: resolved), python != "/usr/bin/python3" else { return nil }
      let output = environment.run(
        python, ["-c", "import importlib.metadata as m; print(m.version('mlx-lm'))"])
      return output.flatMap(Self.firstVersion)
    case .ollama:
      return environment.run(path, ["--version"]).flatMap(Self.firstVersion)
    }
  }

  /// ".../Cellar/mlx-lm/0.32.2/bin/mlx_lm.server" -> "0.32.2".
  static func cellarVersion(_ path: String) -> String? {
    let parts = path.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "Cellar"), parts.count > index + 2 else { return nil }
    return parts[index + 2]
  }

  static func firstVersion(_ text: String) -> String? {
    guard let match = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
    return String(text[match])
  }

  /// The Python interpreter from a script's first line (`#!/path/python3.12`).
  static func interpreter(ofScript path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 512)) ?? Data()
    let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
    guard line.hasPrefix("#!/") else { return nil }
    let command = line.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
    return command.contains("python") ? command : nil
  }

  static func installedBy(path: String, resolved: String, home: String, enginesRoot: String? = nil) -> String {
    let both = path + "\n" + resolved
    if both.contains("/ModelMatrix/Engines/") { return "ModelMatrix" }
    if let enginesRoot, path.hasPrefix(enginesRoot + "/") || resolved.hasPrefix(enginesRoot + "/") { return "ModelMatrix" }
    if both.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") { return "Homebrew" }
    if both.contains("Ollama.app") { return "Ollama app" }
    if both.contains("/.local/") { return "pipx or uv" }
    if both.contains("conda") || both.contains("miniforge") || both.contains("mambaforge") { return "conda" }
    if path.hasPrefix("/opt/local/") { return "MacPorts" }
    if path.hasPrefix("/usr/local/") { return "Homebrew or manual" }
    return "manual"
  }

  static func installOption(
    _ id: HFEngineID, brew: String?, machine: HFMachine, home: String, enginesRoot: String? = nil
  ) -> HFInstallOption {
    let root = enginesRoot ?? "\(home)/ModelMatrix/Engines"
    let prefix = brew.map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }
    let platform = machine.architecture == "arm64" ? "macos-arm64" : "macos-x64"
    switch id {
    case .llamaCpp:
      if let prefix {
        return HFInstallOption(
          method: "homebrew", summary: "Install llama.cpp with Homebrew (about 30 MB).",
          command: "brew install llama.cpp", source: "https://formulae.brew.sh/formula/llama.cpp",
          location: "\(prefix)/bin/llama-server", removal: "brew uninstall llama.cpp")
      }
      return HFInstallOption(
        method: "official",
        summary: "Download the official llama.cpp build for this Mac (llama-<build>-bin-\(platform).tar.gz, about 12 MB, checked against its SHA-256).",
        command: nil, source: "https://github.com/ggml-org/llama.cpp/releases",
        location: "\(root)/llama.cpp", removal: "modelmatrixctl engine uninstall llama.cpp")
    case .mlxLM:
      if let prefix {
        return HFInstallOption(
          method: "homebrew", summary: "Install mlx-lm with Homebrew (it brings its own Python).",
          command: "brew install mlx-lm", source: "https://formulae.brew.sh/formula/mlx-lm",
          location: "\(prefix)/bin/mlx_lm.server", removal: "brew uninstall mlx-lm")
      }
      return HFInstallOption(
        method: "official",
        summary: "Install mlx-lm into a private Python made by uv, the official Python tool from Astral (about 400 MB).",
        command: nil, source: "https://docs.astral.sh/uv/",
        location: "\(root)/mlx-lm", removal: "modelmatrixctl engine uninstall mlx-lm")
    case .ollama:
      if prefix != nil {
        return HFInstallOption(
          method: "homebrew", summary: "Install the Ollama app with Homebrew.",
          command: "brew install --cask ollama-app", source: "https://formulae.brew.sh/cask/ollama-app",
          location: "/Applications/Ollama.app", removal: "brew uninstall --cask ollama-app")
      }
      return HFInstallOption(
        method: "official", summary: "Download the official Ollama app for macOS.", command: nil,
        source: "https://github.com/ollama/ollama/releases", location: "\(home)/Applications/Ollama.app",
        removal: "modelmatrixctl engine uninstall ollama")
    }
  }
}
