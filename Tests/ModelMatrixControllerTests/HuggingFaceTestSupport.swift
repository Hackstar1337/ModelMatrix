import Foundation
@testable import ModelMatrixControllerCore

/// Serves recorded Hugging Face answers from Fixtures/HuggingFace and logs
/// every request, so tests can prove the check never downloads a model.
final class FakeHFTransport: HFTransport, @unchecked Sendable {
  struct Call {
    let url: URL
    let headers: [String: String]
    let maxBytes: Int
  }

  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/HuggingFace", isDirectory: true)

  private let lock = NSLock()
  private var log: [Call] = []
  /// Path prefix -> fixed answer (errors, rate limits).
  var overrides: [String: HFHTTPResponse] = [:]
  /// Repo id -> GGUF header bytes served for ranged reads of .gguf files.
  var ggufHeaders: [String: Data] = [:]
  var gated: Set<String> = ["meta-llama/Llama-3.1-8B-Instruct"]

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func get(_ url: URL, headers: [String: String], maxBytes: Int, timeout: TimeInterval) throws -> HFHTTPResponse {
    lock.lock()
    log.append(Call(url: url, headers: headers, maxBytes: maxBytes))
    lock.unlock()
    let path = url.path
    for (prefix, response) in overrides where path.hasPrefix(prefix) { return response }
    if path == "/api/models" { return listing(url) }
    if path.hasPrefix("/api/models/") {
      let rest = String(path.dropFirst("/api/models/".count))
      if let range = rest.range(of: "/tree/") {
        return fixture("tree__" + Self.slug(String(rest[..<range.lowerBound])))
      }
      if let range = rest.range(of: "/revision/") {
        return fixture("info__" + Self.slug(String(rest[..<range.lowerBound])))
      }
      return fixture("info__" + Self.slug(rest))
    }
    // /owner/name/resolve/revision/file
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 5, parts[2] == "resolve" else { return HFHTTPResponse(status: 404) }
    let repo = parts[0] + "/" + parts[1]
    let file = parts[4...].joined(separator: "/")
    if gated.contains(repo) { return HFHTTPResponse(status: 401, headers: ["x-error-code": "GatedRepo"]) }
    if file.hasSuffix(".gguf") {
      guard let range = headers["Range"], let header = ggufHeaders[repo] ?? ggufHeaders["*"] else {
        return HFHTTPResponse(status: 500)
      }
      let end = Int(range.split(separator: "-").last ?? "") ?? 0
      return HFHTTPResponse(status: 206, body: header.prefix(min(end + 1, maxBytes)))
    }
    if file == "config.json" { return fixture("config__" + Self.slug(repo)) }
    return HFHTTPResponse(status: 404, headers: ["x-error-code": "EntryNotFound"])
  }

  func listing(_ url: URL) -> HFHTTPResponse {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let filters = items.filter { $0.name == "filter" }.compactMap(\.value)
    let format = filters.first { $0 == "gguf" || $0 == "mlx" } ?? "any"
    if let base = filters.first(where: { $0.hasPrefix("base_model:quantized:") }) {
      return fixture("children__" + Self.slug(String(base.dropFirst("base_model:quantized:".count))) + "__" + format, empty: "[]")
    }
    let search = items.first { $0.name == "search" }?.value ?? ""
    let author = items.first { $0.name == "author" }?.value.map { $0 + "__" } ?? ""
    return fixture("search__" + author + search.replacingOccurrences(of: " ", with: "_") + "__" + format, empty: "[]")
  }

  func fixture(_ name: String, empty: String? = nil) -> HFHTTPResponse {
    let file = Self.fixtures.appendingPathComponent(name + ".json")
    if let data = try? Data(contentsOf: file) { return HFHTTPResponse(status: 200, body: data) }
    if let empty { return HFHTTPResponse(status: 200, body: Data(empty.utf8)) }
    // Unknown and private repositories answer 401 without an error code.
    return HFHTTPResponse(status: 401)
  }

  static func slug(_ text: String) -> String {
    text.replacingOccurrences(of: "/", with: "__").replacingOccurrences(of: ":", with: "_")
  }
}

/// Builds GGUF v3 headers (settings only, no tensor data).
enum GGUFBuilder {
  enum Value {
    case u32(UInt32)
    case f32(Float)
    case string(String)
    case u32Array([UInt32])
    case u8Array(count: Int)
  }

  static func header(_ entries: [(String, Value)], tensors: UInt64 = 0, version: UInt32 = 3) -> Data {
    var data = Data("GGUF".utf8)
    append(&data, version)
    append(&data, tensors)
    append(&data, UInt64(entries.count))
    for (key, value) in entries {
      appendString(&data, key)
      switch value {
      case .u32(let number):
        append(&data, UInt32(4))
        append(&data, number)
      case .f32(let number):
        append(&data, UInt32(6))
        append(&data, number.bitPattern)
      case .string(let text):
        append(&data, UInt32(8))
        appendString(&data, text)
      case .u32Array(let numbers):
        append(&data, UInt32(9))
        append(&data, UInt32(4))
        append(&data, UInt64(numbers.count))
        for number in numbers { append(&data, number) }
      case .u8Array(let count):
        append(&data, UInt32(9))
        append(&data, UInt32(0))
        append(&data, UInt64(count))
        data.append(Data(repeating: 7, count: count))
      }
    }
    return data
  }

  /// A transformer header like the real files, followed by tokenizer data.
  static func model(
    arch: String, layers: UInt32, heads: UInt32, kvHeads: UInt32, embedding: UInt32, context: UInt32,
    keyLength: UInt32? = nil, slidingWindow: UInt32? = nil, padding: Int = 0
  ) -> Data {
    var entries: [(String, Value)] = [("general.architecture", .string(arch)), ("general.name", .string("Test"))]
    if padding > 0 { entries.append(("general.padding", .u8Array(count: padding))) }
    entries += [
      ("\(arch).block_count", .u32(layers)), ("\(arch).context_length", .u32(context)),
      ("\(arch).embedding_length", .u32(embedding)), ("\(arch).attention.head_count", .u32(heads)),
      ("\(arch).attention.head_count_kv", .u32(kvHeads)),
    ]
    if let keyLength {
      entries += [("\(arch).attention.key_length", .u32(keyLength)), ("\(arch).attention.value_length", .u32(keyLength))]
    }
    if let slidingWindow { entries.append(("\(arch).attention.sliding_window", .u32(slidingWindow))) }
    entries += [("tokenizer.ggml.model", .string("gpt2")), ("tokenizer.ggml.tokens", .u8Array(count: 64))]
    return header(entries, tensors: 300)
  }

  static let qwen7B = model(arch: "qwen2", layers: 28, heads: 28, kvHeads: 4, embedding: 3584, context: 32768)
  static let qwen72B = model(arch: "qwen2", layers: 80, heads: 64, kvHeads: 8, embedding: 8192, context: 32768)
  static let qwen3MoE = model(
    arch: "qwen3moe", layers: 48, heads: 32, kvHeads: 4, embedding: 2048, context: 40960, keyLength: 128)
  static let gemma3 = model(
    arch: "gemma3", layers: 34, heads: 8, kvHeads: 4, embedding: 2560, context: 131072, keyLength: 256,
    slidingWindow: 1024)

  static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  static func appendString(_ data: inout Data, _ text: String) {
    append(&data, UInt64(text.utf8.count))
    data.append(Data(text.utf8))
  }
}

/// Engine environments for tests: nothing really runs.
final class FakeEngineEnvironment: @unchecked Sendable {
  private let lock = NSLock()
  private var runs: [(String, [String])] = []
  let executables: Set<String>
  let links: [String: String]
  let outputs: [String: String]
  let ollamaServer: String?

  init(executables: Set<String> = [], links: [String: String] = [:], outputs: [String: String] = [:], ollamaServer: String? = nil) {
    self.executables = executables
    self.links = links
    self.outputs = outputs
    self.ollamaServer = ollamaServer
  }

  var commands: [(String, [String])] {
    lock.lock()
    defer { lock.unlock() }
    return runs
  }

  var environment: HFEngineEnvironment {
    HFEngineEnvironment(
      home: "/Users/test",
      searchDirectories: {
        ["/opt/homebrew/bin", "/usr/local/bin", "/Users/test/.local/bin", "/Applications/Ollama.app/Contents/Resources"]
      },
      isExecutable: { [executables] in executables.contains($0) },
      resolve: { [links] in links[$0] ?? $0 },
      run: { [self] path, arguments in
        lock.lock()
        runs.append((path, arguments))
        lock.unlock()
        return outputs[path]
      },
      ollamaServerVersion: { [ollamaServer] in ollamaServer })
  }

  static let homebrewOnly = FakeEngineEnvironment(executables: ["/opt/homebrew/bin/brew"])
  static let nothing = FakeEngineEnvironment()
  static let allInstalled = FakeEngineEnvironment(
    executables: [
      "/opt/homebrew/bin/brew", "/opt/homebrew/bin/llama-server", "/opt/homebrew/bin/mlx_lm.server",
      "/opt/homebrew/bin/ollama",
    ],
    links: [
      "/opt/homebrew/bin/llama-server": "/opt/homebrew/Cellar/llama.cpp/7034/bin/llama-server",
      "/opt/homebrew/bin/mlx_lm.server": "/opt/homebrew/Cellar/mlx-lm/0.32.2/bin/mlx_lm.server",
      "/opt/homebrew/bin/ollama": "/opt/homebrew/Cellar/ollama/0.40.6/bin/ollama",
    ],
    outputs: ["/opt/homebrew/bin/llama-server": "ggml_metal_init: found device\nversion: 7034 (a1b2c3d)\nbuilt with clang"],
    ollamaServer: "0.40.6")
}

func makeCheckService(
  transport: FakeHFTransport = FakeHFTransport(), engines: FakeEngineEnvironment = .homebrewOnly,
  machine: HFMachine = .sample(memoryGiB: 48)
) -> HFCheckService {
  if transport.ggufHeaders.isEmpty {
    transport.ggufHeaders = [
      "bartowski/Qwen2.5-7B-Instruct-GGUF": GGUFBuilder.qwen7B,
      "bartowski/Qwen2.5-72B-Instruct-GGUF": GGUFBuilder.qwen72B,
      "unsloth/Qwen3-30B-A3B-GGUF": GGUFBuilder.qwen3MoE,
      "ggml-org/gemma-3-4b-it-GGUF": GGUFBuilder.gemma3,
    ]
  }
  return HFCheckService(
    client: HFClient(endpoint: HFClient.defaultEndpoint, transport: transport),
    engines: HFEngineProbe(environment: engines.environment), machine: { machine })
}
