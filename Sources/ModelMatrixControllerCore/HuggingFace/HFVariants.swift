import Foundation

/// One downloadable version of a model: a quantization level (GGUF), or the
/// whole repository (MLX).
public struct HFVariant: Sendable, Encodable {
  public var label: String
  public var files: [HFFile]
  public var totalBytes: Int64
  /// Average bits per weight. Higher means closer to the original quality.
  public var bitsPerWeight: Double?
  /// F16/BF16/F32: original quality, but large and slow.
  public var fullPrecision: Bool
  public var supported: Bool
  public var unsupportedReason: String?
  public var quality: String
}

enum HFVariantBuilder {
  /// Quantization labels found in GGUF file names, matched per name token.
  static let labelPattern =
    #"^(I?Q[1-8](_[0-9A-Z]{1,4}){0,3}|TQ[12]_0|MXFP4(_MOE)?|B?F16|F32|FP16|FP32|BF16)$"#
  static let splitPattern = #"^(.*)-(\d{5})-of-(\d{5})\.gguf$"#
  /// Arm-only repacked types that current llama.cpp no longer loads.
  static let retiredLabels: Set<String> = ["Q4_0_4_4", "Q4_0_4_8", "Q4_0_8_8"]

  /// Typical bits per weight, used when the parameter count is unknown.
  static let typicalBits: [String: Double] = [
    "IQ1_S": 1.56, "IQ1_M": 1.75, "TQ1_0": 1.69, "TQ2_0": 2.06, "IQ2_XXS": 2.06, "IQ2_XS": 2.31,
    "IQ2_S": 2.5, "IQ2_M": 2.7, "Q2_K": 2.96, "Q2_K_S": 2.9, "Q2_K_L": 3.3, "IQ3_XXS": 3.06,
    "IQ3_XS": 3.3, "IQ3_S": 3.44, "IQ3_M": 3.66, "Q3_K_S": 3.5, "Q3_K_M": 3.91, "Q3_K_L": 4.27,
    "Q3_K_XL": 4.5, "IQ4_XS": 4.25, "IQ4_NL": 4.5, "Q4_0": 4.55, "Q4_1": 5.0, "Q4_K_S": 4.58,
    "Q4_K_M": 4.85, "Q4_K_L": 5.3, "Q4_K_XL": 4.9, "MXFP4": 4.25, "MXFP4_MOE": 4.25,
    "Q5_0": 5.5, "Q5_1": 6.0, "Q5_K_S": 5.54, "Q5_K_M": 5.69, "Q5_K_L": 6.0, "Q5_K_XL": 5.9,
    "Q6_K": 6.56, "Q6_K_L": 6.8, "Q6_K_XL": 7.0, "Q8_0": 8.5, "Q8_K_XL": 9.5,
    "F16": 16, "BF16": 16, "FP16": 16, "F32": 32, "FP32": 32,
  ]

  // MARK: GGUF

  /// Groups GGUF files into versions (joining split parts) and returns the
  /// image adapter ("mmproj") separately.
  static func gguf(files: [HFFile], parameters: Int64?) -> (variants: [HFVariant], projector: HFFile?) {
    var groups: [String: [HFFile]] = [:]
    var expectedParts: [String: Int] = [:]
    var projectors: [HFFile] = []
    for file in files where file.lowerName.hasSuffix(".gguf") {
      if file.lowerName.contains("mmproj") {
        projectors.append(file)
        continue
      }
      let directory = (file.path as NSString).deletingLastPathComponent
      if let match = splitMatch(file.fileName) {
        let key = (directory.isEmpty ? "" : directory + "/") + match.stem
        groups[key, default: []].append(file)
        expectedParts[key] = match.total
      } else {
        groups[file.path, default: []].append(file)
      }
    }
    var variants: [HFVariant] = []
    for (key, members) in groups {
      let parts = members.sorted { $0.path < $1.path }
      let total = parts.reduce(Int64(0)) { $0 + $1.size }
      let label = label(forGroupKey: key)
      let upper = label.uppercased()
      let normalized = upper.hasPrefix("UD-") ? String(upper.dropFirst(3)) : upper
      var bits: Double?
      if let parameters, parameters > 0 { bits = Double(total) * 8 / Double(parameters) }
      bits = bits ?? typicalBits[normalized]
      let full = ["F16", "BF16", "FP16", "F32", "FP32"].contains(normalized)
      var supported = true
      var reason: String?
      if let expected = expectedParts[key], expected != parts.count {
        supported = false
        reason = "Only \(parts.count) of its \(expected) parts are in the repository."
      } else if retiredLabels.contains(normalized) {
        supported = false
        reason = "An old Arm-only type that current llama.cpp no longer loads. Use Q4_0 or Q4_K_M instead."
      }
      variants.append(
        HFVariant(
          label: label, files: parts, totalBytes: total, bitsPerWeight: bits.map(round2),
          fullPrecision: full, supported: supported, unsupportedReason: reason,
          quality: quality(bits: bits, full: full)))
    }
    variants.sort { ($0.totalBytes, $0.label) < ($1.totalBytes, $1.label) }
    return (dedupeLabels(variants), preferredProjector(projectors))
  }

  static func splitMatch(_ fileName: String) -> (stem: String, part: Int, total: Int)? {
    guard let regex = try? NSRegularExpression(pattern: splitPattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)),
      let stem = Range(match.range(at: 1), in: fileName), let part = Range(match.range(at: 2), in: fileName),
      let total = Range(match.range(at: 3), in: fileName)
    else { return nil }
    return (String(fileName[stem]), Int(fileName[part]) ?? 0, Int(fileName[total]) ?? 0)
  }

  /// "Qwen2.5-7B-Instruct-Q4_K_M.gguf" -> "Q4_K_M";
  /// "Qwen3-30B-A3B-UD-Q4_K_XL" -> "UD-Q4_K_XL"; falls back to the folder
  /// name, then the file name.
  static func label(forGroupKey key: String) -> String {
    let fileName = (key as NSString).lastPathComponent
    let stem = fileName.lowercased().hasSuffix(".gguf") ? String(fileName.dropLast(5)) : fileName
    if let found = quantLabel(in: stem) { return found }
    let folder = (key as NSString).deletingLastPathComponent
    if !folder.isEmpty, let found = quantLabel(in: (folder as NSString).lastPathComponent) { return found }
    return stem
  }

  static func quantLabel(in text: String) -> String? {
    let tokens = text.split(whereSeparator: { $0 == "-" || $0 == "." }).map(String.init)
    for index in tokens.indices.reversed() {
      let token = tokens[index].uppercased()
      guard token.range(of: labelPattern, options: .regularExpression) != nil else { continue }
      if index > 0, tokens[index - 1].uppercased() == "UD" { return "UD-" + token }
      return token
    }
    return nil
  }

  static func dedupeLabels(_ variants: [HFVariant]) -> [HFVariant] {
    var seen: [String: Int] = [:]
    return variants.map { variant in
      var copy = variant
      let count = seen[variant.label, default: 0]
      seen[variant.label] = count + 1
      if count > 0, let first = variant.files.first { copy.label = first.path }
      return copy
    }
  }

  static func preferredProjector(_ files: [HFFile]) -> HFFile? {
    for preference in ["f16", "bf16", "q8", "f32"] {
      if let match = files.first(where: { $0.lowerName.contains(preference) }) { return match }
    }
    return files.min { $0.size < $1.size }
  }

  static func quality(bits: Double?, full: Bool) -> String {
    if full { return "original size" }
    guard let bits else { return "unknown" }
    switch bits {
    case 7.5...: return "near original"
    case 5.5..<7.5: return "excellent"
    case 4.5..<5.5: return "very good"
    case 3.5..<4.5: return "good"
    case 2.5..<3.5: return "fair"
    default: return "low"
    }
  }

  // MARK: MLX

  static let documentationSuffixes = [".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf"]

  /// MLX repositories are one version: every file except documentation.
  static func mlx(repoName: String, files: [HFFile], parameters: Int64?, config: [String: Any]?) -> HFVariant {
    let needed = files.filter { file in
      let name = file.lowerName
      return name != ".gitattributes" && !documentationSuffixes.contains { name.hasSuffix($0) }
        && !file.path.contains("/.")
    }
    let total = needed.reduce(Int64(0)) { $0 + $1.size }
    let quantization = (config?["quantization"] ?? config?["quantization_config"]) as? [String: Any]
    var label: String
    if let bits = int(quantization?["bits"]) {
      label = "\(bits)-bit"
    } else if let found = repoName.range(of: #"(?i)(\d{1,2})-?bit"#, options: .regularExpression) {
      label = String(repoName[found]).lowercased().replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "bit", with: "-bit")
    } else {
      label = repoName.lowercased().contains("bf16") ? "BF16" : "full"
    }
    let weights = needed.filter { $0.lowerName.hasSuffix(".safetensors") }.reduce(Int64(0)) { $0 + $1.size }
    var bits: Double?
    if let parameters, parameters > 0, weights > 0 { bits = Double(weights) * 8 / Double(parameters) }
    let full = (bits ?? 0) >= 15 || label == "BF16" || label == "full"
    return HFVariant(
      label: label, files: needed, totalBytes: total, bitsPerWeight: bits.map(round2), fullPrecision: full,
      supported: true, unsupportedReason: nil, quality: quality(bits: bits, full: full))
  }

  static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
