import Foundation

/// Builds the profile for a downloaded model. Pure functions, so every rule
/// is covered by tests.
public enum HFProfileMaker {
  /// Model servers get ports from here upward.
  public static let firstPort = 8081
  static let lastPort = 8999
  /// Ports ModelMatrix and Ollama use themselves.
  static let reservedPorts: Set<Int> = [7700, 7701, 11434]

  /// Name suffixes that describe the packaging rather than the model.
  static let packagingWords: Set<String> = [
    "gguf", "ggml", "mlx", "imatrix", "i1", "awq", "gptq",
    "2bit", "3bit", "4bit", "5bit", "6bit", "8bit", "bf16", "fp16", "f16", "fp32", "f32",
    "dwq", "mxfp4", "nvfp4", "quantized", "q4", "q8",
  ]

  /// "bartowski/Qwen2.5-7B-Instruct-GGUF" -> "qwen2.5-7b-instruct".
  public static func baseModelName(repo: String) -> String {
    let last = repo.split(separator: "/").last.map(String.init) ?? repo
    var words = last.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
    while let tail = words.last, words.count > 1, packagingWords.contains(tail) {
      words.removeLast()
    }
    return slug(words.joined(separator: "-"), fallback: "model", limit: 48)
  }

  /// "Qwen2.5-7B-Instruct-GGUF" + "Q8_0" -> "Qwen2.5 7B Instruct · Q8_0".
  public static func displayName(repo: String, label: String) -> String {
    let last = repo.split(separator: "/").last.map(String.init) ?? repo
    var words = last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    while let tail = words.last, words.count > 1, packagingWords.contains(tail.lowercased()) {
      words.removeLast()
    }
    return "\(words.joined(separator: " ")) · \(label)"
  }

  /// Lowercase letters, digits, '.', '_' and '-' only.
  static func slug(_ raw: String, fallback: String, limit: Int) -> String {
    var out = ""
    for character in raw.lowercased() {
      if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
        out.append(character)
      } else if !out.hasSuffix("-") {
        out.append("-")
      }
    }
    while out.hasPrefix("-") || out.hasPrefix(".") || out.hasPrefix("_") { out.removeFirst() }
    if out.count > limit { out = String(out.prefix(limit)) }
    while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
    return out.isEmpty ? fallback : out
  }

  /// The name apps send. The short name if it's free; otherwise the name
  /// with the version added ("qwen2.5-7b-instruct-q4_k_m"), then a number.
  public static func modelName(repo: String, label: String, taken: Set<String>) -> String {
    let base = baseModelName(repo: repo)
    let used = Set(taken.map { $0.lowercased() })
    if !used.contains(base) { return base }
    let versioned = slug("\(base)-\(label)", fallback: base, limit: 60)
    if !used.contains(versioned) { return versioned }
    var number = 2
    while used.contains("\(versioned)-\(number)") { number += 1 }
    return "\(versioned)-\(number)"
  }

  /// The profile's file name: "qwen2.5-7b-instruct-q8_0", unique.
  public static func profileName(repo: String, label: String, existing: Set<String>) -> String {
    let base = slug("\(baseModelName(repo: repo))-\(label)", fallback: "hf-model", limit: 60)
    let used = Set(existing.map { $0.lowercased() })
    if !used.contains(base) { return base }
    var number = 2
    while used.contains("\(base)-\(number)") { number += 1 }
    return "\(base)-\(number)"
  }

  /// Every model name a profile answers to (to keep new names unique).
  static func modelNames(in profiles: [String: [String: String]]) -> Set<String> {
    var names = Set<String>()
    for (name, values) in profiles {
      names.insert(name.lowercased())
      for key in ["REQUEST_MODEL", "SERVER_MODEL_ID", "MODEL_ALIAS"] {
        if let value = values[key], !value.isEmpty { names.insert(value.lowercased()) }
      }
    }
    return names
  }

  /// Ports profiles already use (PORT, or the port in BASE_URL).
  static func usedPorts(in profiles: [String: [String: String]]) -> Set<Int> {
    var ports = Set<Int>()
    for values in profiles.values {
      if let port = values["PORT"].flatMap({ Int($0) }) { ports.insert(port) }
      if let url = values["BASE_URL"].flatMap({ URL(string: $0) }), let port = url.port { ports.insert(port) }
    }
    return ports
  }

  /// The first port from 8081 that no profile uses and nothing listens on.
  public static func pickPort(profiles: [String: [String: String]], isFree: (Int) -> Bool) -> Int? {
    let used = usedPorts(in: profiles)
    for port in firstPort...lastPort where !used.contains(port) && !reservedPorts.contains(port) {
      if isFree(port) { return port }
    }
    return nil
  }

  public struct Inputs: Sendable {
    public var job: HFDownloadJob
    public var profileName: String
    public var modelName: String
    public var port: Int
    /// The engine program (llama-server or mlx_lm.server), if installed.
    public var enginePath: String?
    /// "metal" or "cpu".
    public var accelerator: String
    public var physicalCores: Int
    /// The model folder with symlinks resolved (for MLX's model id).
    public var resolvedFolder: String

    public init(
      job: HFDownloadJob, profileName: String, modelName: String, port: Int, enginePath: String?, accelerator: String,
      physicalCores: Int, resolvedFolder: String
    ) {
      self.job = job
      self.profileName = profileName
      self.modelName = modelName
      self.port = port
      self.enginePath = enginePath
      self.accelerator = accelerator
      self.physicalCores = physicalCores
      self.resolvedFolder = resolvedFolder
    }
  }

  /// The profile settings for a downloaded GGUF or MLX model.
  public static func values(_ inputs: Inputs) -> [String: String] {
    let job = inputs.job
    var values: [String: String] = [
      "DISPLAY_NAME": displayName(repo: job.repo, label: job.label),
      "HOST": "127.0.0.1",
      "PORT": String(inputs.port),
      "BASE_URL": "http://127.0.0.1:\(inputs.port)/v1",
      "REQUEST_MODEL": inputs.modelName,
      "HEALTHCHECK_MODE": "openai-models",
      "CONTEXT_SIZE": String(job.context),
      // The launcher and the controller must agree on the log file.
      "LOG_ALIAS": inputs.profileName,
      "HF_REPO": job.repo,
      "HF_REVISION": job.revision,
      "HF_VERSION": job.label,
      "HF_DOWNLOAD_ID": job.id,
      "HF_FOLDER": job.folder,
    ]
    if let path = inputs.enginePath { values["SERVER_BIN"] = path }
    if job.format == "mlx" {
      values["RUNTIME"] = "mlx"
      values["MODEL_DIR"] = job.folder
      // mlx-lm lists its model under the resolved folder path…
      values["SERVER_MODEL_ID"] = inputs.resolvedFolder
      // …and tries to load any other name it receives, so the relay sends
      // the name mlx-lm reserves for the model it was started with.
      values["UPSTREAM_MODEL"] = "default_model"
    } else {
      values["RUNTIME"] = "llama.cpp"
      let main = job.mainFile ?? job.files.first?.path ?? ""
      values["MODEL_PATH"] = job.folderURL.appendingPathComponent(main).path
      values["MODEL_ALIAS"] = inputs.modelName
      values["SERVER_MODEL_ID"] = inputs.modelName
      values["N_PARALLEL"] = "1"
      if inputs.accelerator == "cpu" {
        // Intel Macs and processor-only hosts: no GPU layers, one thread per core.
        values["GPU_LAYERS"] = "0"
        values["THREADS"] = String(max(1, inputs.physicalCores))
      } else {
        values["GPU_LAYERS"] = "999"
      }
      if let projector = job.projectorFile {
        let path = job.folderURL.appendingPathComponent(projector).path
        if let data = try? JSONSerialization.data(withJSONObject: ["--mmproj", path], options: [.withoutEscapingSlashes]) {
          values["SERVER_ARGS_JSON"] = String(decoding: data, as: UTF8.self)
        }
      }
    }
    return values
  }

  /// The warning a download carries while its engine isn't installed.
  public static func engineMissingWarning(_ engineName: String) -> String {
    "\(engineName) isn't installed yet. The download can run now; the model starts once the engine is installed."
  }

  /// A plain-English fix for a model that didn't start, from its log.
  public static func suggestion(log: [String], engine: String, port: String?) -> String {
    let text = log.joined(separator: "\n").lowercased()
    let engineName = HFEngineID(rawValue: engine)?.displayName ?? engine
    if text.contains("address already in use") || text.contains("couldn't bind") || text.contains("failed to bind") {
      return "Port \(port ?? "") is used by another program. Change PORT in the profile and start it again."
    }
    if text.contains("unknown argument") || text.contains("invalid argument") || text.contains("unrecognized arguments")
      || text.contains("error: invalid") || text.contains("unknown value for") || text.contains("error while handling argument")
      || text.contains("unknown option")
    {
      return "This \(engineName) version doesn't accept one of the profile's settings (see the log). "
        + "Change that setting in the profile, or update the engine: modelmatrixctl engine update \(engine)."
    }
    if text.contains("unknown model architecture") || text.contains("unsupported model") || text.contains("not supported")
      || text.contains("model type") && text.contains("not")
    {
      return "This \(engineName) version can't run this model yet. Update it: modelmatrixctl engine update \(engine)."
    }
    if text.contains("out of memory") || text.contains("failed to allocate") || text.contains("insufficient memory")
      || text.contains("cannot allocate") || text.contains("outofmemory")
    {
      return "Not enough memory. Close other apps or use Optimize, or choose a smaller version or a shorter context."
    }
    if text.contains("no such file") || text.contains("model file not found") || text.contains("failed to open") {
      if text.contains("start-model") {
        return "ModelMatrix's start script is missing. Reinstall ModelMatrix, then start the model again."
      }
      let modelFile = [".gguf", ".safetensors", "model file", "model path", "failed to load model"].contains {
        text.contains($0)
      }
      if modelFile {
        return "A model file is missing. Delete the model and download it again."
      }
      return "A file the server needs is missing (see the log)."
    }
    if text.contains("not found;") || text.contains("command not found") {
      return "\(engineName) wasn't found. Install it: modelmatrixctl engine install \(engine)."
    }
    return "See the server log for details."
  }
}
