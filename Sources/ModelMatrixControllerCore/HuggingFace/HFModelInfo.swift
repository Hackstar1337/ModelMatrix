import Foundation

/// One file in a repository.
public struct HFFile: Sendable, Equatable, Encodable {
  public let path: String
  public let size: Int64
  /// SHA-256 of large (LFS) files, used to verify downloads later.
  public let sha256: String?

  public init(path: String, size: Int64, sha256: String? = nil) {
    self.path = path
    self.size = size
    self.sha256 = sha256
  }

  var fileName: String { (path as NSString).lastPathComponent }
  var lowerName: String { fileName.lowercased() }

  static func list(from entries: [[String: Any]]) -> [HFFile] {
    entries.compactMap { entry in
      guard (entry["type"] as? String) == "file", let path = entry["path"] as? String else { return nil }
      let lfs = entry["lfs"] as? [String: Any]
      let size = int64(lfs?["size"]) ?? int64(entry["size"]) ?? 0
      let oid = lfs?["oid"] as? String
      let sha = oid.flatMap { $0.count == 64 ? $0.lowercased() : nil }
      return HFFile(path: path, size: size, sha256: sha)
    }
    .sorted { $0.path < $1.path }
  }
}

func int64(_ value: Any?) -> Int64? {
  if let number = value as? NSNumber { return number.int64Value }
  if let text = value as? String { return Int64(text) }
  return nil
}

func int(_ value: Any?) -> Int? { int64(value).map { Int(clamping: $0) } }

/// The parts of `GET /api/models/{repo}` the check uses.
public struct HFModelInfo: Sendable {
  public var id: String
  public var sha: String?
  public var libraryName: String?
  public var pipelineTag: String?
  public var tags: [String]
  /// `nil` when open; `"auto"` or `"manual"` when a login and license
  /// acceptance are needed.
  public var gated: String?
  public var isPrivate: Bool
  public var downloads: Int?
  public var likes: Int?
  public var license: String?
  public var lastModified: String?
  public var ggufParameters: Int64?
  public var ggufArchitecture: String?
  public var ggufContextLength: Int?
  public var safetensorsParameters: Int64?
  public var quantMethod: String?
  public var modelType: String?
  public var baseModels: [String]
  public var baseRelation: String?

  public init(json: [String: Any]) {
    id = json["id"] as? String ?? json["modelId"] as? String ?? ""
    sha = json["sha"] as? String
    libraryName = (json["library_name"] as? String)?.lowercased()
    pipelineTag = (json["pipeline_tag"] as? String)?.lowercased()
    tags = (json["tags"] as? [String] ?? []).map { $0.lowercased() }
    if let gate = json["gated"] as? String {
      gated = gate
    } else if JSONSupport.boolValue(json["gated"]) == true {
      gated = "auto"
    } else {
      gated = nil
    }
    isPrivate = JSONSupport.boolValue(json["private"]) ?? false
    downloads = int(json["downloads"])
    likes = int(json["likes"])
    let card = json["cardData"] as? [String: Any]
    if let value = card?["license"] as? String {
      license = value
    } else if let values = card?["license"] as? [String] {
      license = values.joined(separator: ", ")
    } else {
      license = tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }
    }
    if license == "other", let name = card?["license_name"] as? String { license = name }
    lastModified = json["lastModified"] as? String
    let gguf = json["gguf"] as? [String: Any]
    ggufParameters = int64(gguf?["total"])
    ggufArchitecture = gguf?["architecture"] as? String
    ggufContextLength = int(gguf?["context_length"])
    safetensorsParameters = int64((json["safetensors"] as? [String: Any])?["total"])
    let config = json["config"] as? [String: Any]
    quantMethod = ((config?["quantization_config"] as? [String: Any])?["quant_method"] as? String)?.lowercased()
    modelType = (config?["model_type"] as? String)?.lowercased()
    let base = json["baseModels"] as? [String: Any]
    baseRelation = (base?["relation"] as? String)?.lowercased()
    baseModels = (base?["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    if baseModels.isEmpty {
      // Fallback: "base_model:quantized:owner/name" style tags.
      for tag in json["tags"] as? [String] ?? [] where tag.lowercased().hasPrefix("base_model:") {
        let parts = tag.split(separator: ":")
        if parts.count == 3 {
          baseRelation = baseRelation ?? String(parts[1]).lowercased()
          baseModels.append(String(parts[2]))
        }
      }
    }
  }

  public var parameters: Int64? { ggufParameters ?? safetensorsParameters }

  func hasTag(_ tag: String) -> Bool { tags.contains(tag) }
}
