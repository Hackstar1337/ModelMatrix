import Foundation

/// The layout facts that decide how much memory the chat history (the
/// "KV cache") takes per token of context.
public struct HFArchitecture: Sendable, Encodable, Equatable {
  public var name: String?
  public var layers: Int
  /// Key/value heads per layer (0 for layers without attention).
  public var kvHeads: [Int]
  public var keyLength: Int
  public var valueLength: Int
  /// Compressed attention (DeepSeek MLA): rank plus rotary dimensions.
  public var kvLoraRank: Int?
  public var ropeDimensions: Int?
  /// Sliding-window layers only keep the last `slidingWindow` tokens.
  public var slidingWindow: Int?
  /// Number of sliding-window layers (the rest keep the full context).
  public var slidingLayers: Int
  public var maxContext: Int?
  /// "gguf_header", "config_json" or "rough".
  public var source: String
  /// Rough bytes per token when the layout is unknown.
  public var roughBytesPerToken: Int64?

  static let bytesPerValue: Int64 = 2  // f16 cache, the engines' default

  /// Every Nth layer uses full attention, the rest a sliding window.
  static let slidingPatterns: [String: Int] = [
    "gemma3": 6, "gemma3n": 5, "gemma2": 2, "cohere2": 4, "gpt-oss": 2, "gpt_oss": 2,
    "gemma3_text": 6,
  ]

  /// Memory for `context` tokens of chat history.
  public func cacheBytes(context: Int) -> Int64 {
    let tokens = Int64(max(context, 0))
    if let rough = roughBytesPerToken { return rough * tokens }
    if let rank = kvLoraRank, rank > 0 {
      return Int64(layers) * Int64(rank + (ropeDimensions ?? 0)) * Self.bytesPerValue * tokens
    }
    let perHead = Int64(keyLength + valueLength) * Self.bytesPerValue
    var total: Int64 = 0
    for (index, heads) in kvHeads.enumerated() {
      let sliding = slidingWindow != nil && isSlidingLayer(index)
      let kept = sliding ? min(tokens, Int64(slidingWindow ?? 0)) : tokens
      total += Int64(heads) * perHead * kept
    }
    return total
  }

  /// Full-context layers are spread evenly among the others (with a
  /// pattern of 6, every 6th layer keeps the full context).
  func isSlidingLayer(_ index: Int) -> Bool {
    guard slidingLayers > 0, layers > 0 else { return false }
    let full = layers - slidingLayers
    return (index + 1) * full / layers == index * full / layers
  }

  // MARK: Builders

  static func fromGGUF(_ meta: GGUFMetadata) -> HFArchitecture? {
    guard let layersValue = meta.archNumber("block_count"), layersValue > 0, layersValue < 10_000 else {
      return nil
    }
    let layers = Int(layersValue)
    let heads = Int(meta.archNumber("attention.head_count") ?? meta.archArray("attention.head_count")?.max() ?? 0)
    let embedding = Int(meta.archNumber("embedding_length") ?? 0)
    var kvHeads: [Int]
    if let array = meta.archArray("attention.head_count_kv"), array.count == layers {
      kvHeads = array.map { Int($0) }
    } else {
      kvHeads = Array(repeating: Int(meta.archNumber("attention.head_count_kv") ?? Double(heads)), count: layers)
    }
    let headDim = heads > 0 ? embedding / heads : 0
    let key = Int(meta.archNumber("attention.key_length") ?? Double(headDim))
    let value = Int(meta.archNumber("attention.value_length") ?? Double(headDim))
    guard key > 0 || meta.archNumber("attention.kv_lora_rank") != nil else { return nil }
    let window = meta.archNumber("attention.sliding_window").map { Int($0) }
    var sliding = 0
    if let window, window > 0, let pattern = slidingPatterns[meta.architecture ?? ""] {
      sliding = layers - layers / pattern
    }
    return HFArchitecture(
      name: meta.architecture, layers: layers, kvHeads: kvHeads, keyLength: key, valueLength: value,
      kvLoraRank: meta.archNumber("attention.kv_lora_rank").map { Int($0) },
      ropeDimensions: meta.archNumber("rope.dimension_count").map { Int($0) },
      slidingWindow: sliding > 0 ? window : nil, slidingLayers: sliding,
      maxContext: meta.archNumber("context_length").map { Int($0) }, source: "gguf_header")
  }

  /// From a Transformers-style config.json (MLX repos ship one).
  static func fromConfig(_ root: [String: Any]) -> HFArchitecture? {
    let config = (root["text_config"] as? [String: Any]).map { root.merging($0) { $1 } } ?? root
    guard let layers = int(config["num_hidden_layers"] ?? config["n_layer"] ?? config["num_layers"]),
      layers > 0, layers < 10_000
    else { return nil }
    let heads = int(config["num_attention_heads"] ?? config["n_head"]) ?? 0
    let kv = int(config["num_key_value_heads"] ?? config["n_head_kv"]) ?? heads
    let hidden = int(config["hidden_size"] ?? config["n_embd"]) ?? 0
    let headDim = int(config["head_dim"]) ?? (heads > 0 ? hidden / heads : 0)
    let rank = int(config["kv_lora_rank"])
    guard headDim > 0 || rank != nil else { return nil }
    var kvHeads = Array(repeating: kv, count: layers)
    var slidingLayers = 0
    var window = int(config["sliding_window"])
    if let types = config["layer_types"] as? [String], types.count == layers {
      for (index, type) in types.enumerated() {
        if type.contains("linear") || type.contains("mamba") || type.contains("conv") { kvHeads[index] = 0 }
        if type.contains("sliding") || type.contains("chunked") { slidingLayers += 1 }
      }
    } else if let window, window > 0, let pattern = slidingPatterns[(config["model_type"] as? String) ?? ""] {
      slidingLayers = layers - layers / pattern
    }
    if slidingLayers == 0 { window = nil }
    return HFArchitecture(
      name: config["model_type"] as? String, layers: layers, kvHeads: kvHeads, keyLength: headDim,
      valueLength: int(config["v_head_dim"]) ?? headDim, kvLoraRank: rank,
      ropeDimensions: int(config["qk_rope_head_dim"]), slidingWindow: window, slidingLayers: slidingLayers,
      maxContext: int(config["max_position_embeddings"]), source: "config_json")
  }

  /// When the files can't be read (login needed): about 16 KB per token per
  /// billion parameters, on the safe side for most modern models.
  static func rough(parameters: Int64?, maxContext: Int?) -> HFArchitecture {
    let billions = Double(parameters ?? 8_000_000_000) / 1e9
    return HFArchitecture(
      name: nil, layers: 0, kvHeads: [], keyLength: 0, valueLength: 0, kvLoraRank: nil, ropeDimensions: nil,
      slidingWindow: nil, slidingLayers: 0, maxContext: maxContext, source: "rough",
      roughBytesPerToken: Int64(max(billions, 0.5) * 16_000))
  }
}

/// How well a version fits the machine at a given context length.
public struct HFFit: Sendable, Encodable, Equatable {
  public let context: Int
  public let needBytes: Int64
  public let cacheBytes: Int64
  /// "good" (uses at most two thirds of the budget), "tight" (fits only
  /// with little to spare), or "too_big".
  public let level: String
}

public enum HFMemoryPlanner {
  public static let overheadBytes: Int64 = 1 << 30
  public static let defaultContextCap = 32_768
  static let fallbackContext = 8_192

  public static func defaultContext(maxContext: Int?) -> Int {
    guard let maxContext, maxContext > 0 else { return fallbackContext }
    return min(maxContext, defaultContextCap)
  }

  public static func fit(weights: Int64, projector: Int64, arch: HFArchitecture, context: Int, budget: Int64)
    -> HFFit
  {
    let cache = arch.cacheBytes(context: context)
    let need = weights + projector + cache + overheadBytes
    let level: String
    if need * 3 <= budget * 2 {
      level = "good"
    } else if need <= budget {
      level = "tight"
    } else {
      level = "too_big"
    }
    return HFFit(context: context, needBytes: need, cacheBytes: cache, level: level)
  }

  /// Longest standard context (4K, 8K, 16K ...) that still fits well.
  public static func longestGoodContext(weights: Int64, projector: Int64, arch: HFArchitecture, budget: Int64)
    -> Int?
  {
    let limit = arch.maxContext ?? fallbackContext
    var steps = [4096, 8192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576].filter { $0 <= limit }
    if limit > 0, !steps.contains(limit), limit < 1_048_576 * 2 { steps.append(limit) }
    return steps.sorted().last {
      fit(weights: weights, projector: projector, arch: arch, context: $0, budget: budget).level == "good"
    }
  }

  /// Ranking key: bits per weight, with older GGUF types (Q4_0, Q4_1,
  /// Q5_0, Q5_1) ranked a little below the newer types of similar size.
  static func score(_ variant: HFVariant) -> Double {
    let base = variant.label.uppercased().replacingOccurrences(of: "UD-", with: "")
    let legacy = ["Q4_0", "Q4_1", "Q5_0", "Q5_1"].contains(base)
    return (variant.bitsPerWeight ?? 0) - (legacy ? 0.4 : 0)
  }

  /// Versions below this lose too much quality to be recommended; they stay
  /// listed and can still be chosen by name (owner/name:LABEL).
  public static let minimumRecommendedBits = 3.5
  static let goodQualityBits = 4.5

  /// Picks a version and context, in this order: good quality (4.5+ bits)
  /// that fits well, acceptable quality (3.5+ bits) that fits well, then the
  /// same two with a tight fit. Within each step the highest quality wins,
  /// at the longest of the default, 16K, 8K and 4K contexts that fits.
  /// With `fixedContext`, only that context length is considered.
  public static func recommend(
    variants: [HFVariant], projector: Int64, arch: HFArchitecture, defaultContext: Int, budget: Int64,
    fixedContext: Int? = nil
  ) -> (index: Int, fit: HFFit, reason: String)? {
    let bits = { (index: Int) in variants[index].bitsPerWeight ?? 8 }
    let candidates = variants.indices.filter {
      let variant = variants[$0]
      return variant.supported && !variant.fullPrecision && bits($0) <= 9.0 && bits($0) >= minimumRecommendedBits
    }.sorted { score(variants[$0]) > score(variants[$1]) }
    // Older types (Q4_0 ...) count as a little lower quality than their size suggests.
    let good = candidates.filter { score(variants[$0]) >= goodQualityBits }
    let acceptable = candidates.filter { score(variants[$0]) < goodQualityBits }
    let contexts = { (list: [Int]) in
      fixedContext.map { [$0] } ?? Array(Set(list.map { min($0, defaultContext) })).sorted(by: >)
    }
    let roomy = contexts([defaultContext, 16_384])
    let short = contexts([defaultContext, 16_384, 8192, 4096])
    let small = contexts([8192, 4096])
    let tight = "Fits only tightly: close other apps before starting it, or choose a smaller model."
    let rounds: [([Int], [Int], String, String)] = [
      (good, roomy, "good", "Best quality that fits comfortably."),
      (good, contexts([8192]), "good", "Best quality that fits comfortably with a shorter context."),
      (acceptable, short, "good", "A smaller version, so it fits comfortably. Quality is a little lower."),
      (good, small, "tight", tight),
      (acceptable, small, "tight", tight),
    ]
    for (pool, contextList, level, reason) in rounds {
      for index in pool {
        let fits = contextList.map {
          fit(weights: variants[index].totalBytes, projector: projector, arch: arch, context: $0, budget: budget)
        }
        if let comfortable = fits.first(where: { $0.level == "good" }) {
          return (index, comfortable, level == "good" ? reason : "Fits comfortably with a short context.")
        }
        if level == "tight", let close = fits.first(where: { $0.level == "tight" }) {
          return (index, close, reason)
        }
      }
    }
    return nil
  }

  /// Best context for a version the user picked: the longest of the default,
  /// 16K, 8K and 4K that fits comfortably, else the longest that fits at all.
  public static func bestFit(
    weights: Int64, projector: Int64, arch: HFArchitecture, defaultContext: Int, budget: Int64, fixedContext: Int?
  ) -> HFFit {
    let list = fixedContext.map { [$0] }
      ?? Array(Set([defaultContext, 16_384, 8192, 4096].map { min($0, defaultContext) })).sorted(by: >)
    let fits = list.map { fit(weights: weights, projector: projector, arch: arch, context: $0, budget: budget) }
    return fits.first { $0.level == "good" } ?? fits.first { $0.level == "tight" } ?? fits[0]
  }

  /// Whether any version fits at all at 4K, even a very small one.
  public static func anythingFits(variants: [HFVariant], projector: Int64, arch: HFArchitecture, budget: Int64) -> Bool {
    variants.contains {
      $0.supported
        && fit(weights: $0.totalBytes, projector: projector, arch: arch, context: 4096, budget: budget).level != "too_big"
    }
  }
}
