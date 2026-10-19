import Foundation

/// The file format a repository ships its model in.
public enum HFFormat: String, Sendable, Encodable {
  case gguf
  case mlx
  case mlc
  case original
  case awq
  case gptq
  case exl2
  case fp8
  case bitsandbytes
  case onnx
  case openvino
  case coreml
  case unknown

  public var displayName: String {
    switch self {
    case .gguf: return "GGUF"
    case .mlx: return "MLX"
    case .mlc: return "MLC-LLM"
    case .original: return "Original weights (safetensors)"
    case .awq: return "AWQ"
    case .gptq: return "GPTQ"
    case .exl2: return "EXL2"
    case .fp8: return "FP8 / compressed tensors"
    case .bitsandbytes: return "bitsandbytes"
    case .onnx: return "ONNX"
    case .openvino: return "OpenVINO"
    case .coreml: return "Core ML"
    case .unknown: return "Unknown"
    }
  }

  public var summary: String {
    switch self {
    case .gguf:
      return "Ready-to-run files for llama.cpp. Works on Apple Silicon and Intel Macs and on Linux."
    case .mlx: return "Apple's MLX format. Runs only on Apple Silicon Macs."
    case .mlc: return "Compiled for the MLC-LLM engine, which ModelMatrix does not run."
    case .original:
      return "The full-size original model, made for Python training and GPU servers. ModelMatrix runs ready-made GGUF or MLX versions of it instead."
    case .awq, .gptq, .exl2, .fp8, .bitsandbytes:
      return "A compressed version made for NVIDIA GPU servers (vLLM, ExLlama and similar). It does not run on Macs."
    case .onnx: return "Made for the ONNX runtime, which ModelMatrix does not run."
    case .openvino: return "Made for Intel's OpenVINO runtime, which ModelMatrix does not run."
    case .coreml: return "Made for Apple's Core ML, which ModelMatrix does not run."
    case .unknown: return "No model files ModelMatrix recognises were found."
    }
  }

  /// The engine that runs this format, when ModelMatrix supports it.
  public var engine: HFEngineID? {
    switch self {
    case .gguf: return .llamaCpp
    case .mlx: return .mlxLM
    default: return nil
    }
  }

  /// Formats that are not run directly, but usually have GGUF/MLX siblings.
  var offersAlternatives: Bool { engine == nil }

  /// Detects the format from the files first (labels on Hugging Face are
  /// sometimes wrong, for example GGUF repos tagged `transformers`).
  static func detect(info: HFModelInfo, files: [HFFile]) -> HFFormat {
    let names = files.map(\.lowerName)
    let ggufModels = names.filter { $0.hasSuffix(".gguf") && !$0.contains("mmproj") }
    if !ggufModels.isEmpty { return .gguf }
    let hasSafetensors = names.contains { $0.hasSuffix(".safetensors") }
    if info.libraryName == "mlc-llm" || info.hasTag("mlc-llm") || names.contains("mlc-chat-config.json") {
      return .mlc
    }
    if hasSafetensors, info.libraryName == "mlx" || info.hasTag("mlx") { return .mlx }
    switch info.quantMethod {
    case "awq": return .awq
    case "gptq": return .gptq
    case "exl2", "exl3": return .exl2
    case "fp8", "compressed-tensors", "fbgemm_fp8", "modelopt": return .fp8
    case "bitsandbytes": return .bitsandbytes
    default: break
    }
    if info.hasTag("awq") { return .awq }
    if info.hasTag("gptq") { return .gptq }
    if info.hasTag("exl2") || info.hasTag("exl3") { return .exl2 }
    if hasSafetensors || names.contains(where: { $0.hasPrefix("pytorch_model") && $0.hasSuffix(".bin") }) {
      return .original
    }
    if names.contains(where: { $0.hasSuffix(".onnx") || $0.hasSuffix(".onnx_data") }) { return .onnx }
    if names.contains(where: { $0.hasPrefix("openvino_model") && $0.hasSuffix(".xml") }) { return .openvino }
    if files.contains(where: { $0.path.lowercased().contains(".mlpackage/") || $0.path.lowercased().contains(".mlmodelc/") }) {
      return .coreml
    }
    return .unknown
  }
}

/// What kind of model it is. ModelMatrix runs chat (text, and text with
/// images) models.
public struct HFTask: Sendable, Encodable, Equatable {
  public let kind: String
  public let description: String
  public let chat: Bool
  public let vision: Bool

  static let chatPipelines: Set<String> = [
    "text-generation", "text2text-generation", "conversational",
  ]
  static let visionPipelines: Set<String> = [
    "image-text-to-text", "visual-question-answering", "any-to-any", "video-text-to-text",
  ]
  static let otherTasks: [String: String] = [
    "text-to-image": "an image generator",
    "image-to-image": "an image editor",
    "text-to-video": "a video generator",
    "image-to-video": "a video generator",
    "automatic-speech-recognition": "a speech-to-text model",
    "text-to-speech": "a text-to-speech model",
    "text-to-audio": "an audio generator",
    "audio-classification": "an audio classifier",
    "audio-to-audio": "an audio model",
    "feature-extraction": "an embedding model",
    "sentence-similarity": "an embedding model",
    "text-classification": "a text classifier",
    "token-classification": "a text tagger",
    "zero-shot-classification": "a text classifier",
    "fill-mask": "a fill-in-the-blank (BERT-style) model",
    "translation": "a translation model",
    "summarization": "a summarisation model",
    "question-answering": "an extractive question-answering model",
    "image-classification": "an image classifier",
    "object-detection": "an object detector",
    "image-segmentation": "an image segmenter",
    "depth-estimation": "a depth estimator",
    "image-feature-extraction": "an image embedding model",
    "mask-generation": "a mask generator",
    "reinforcement-learning": "a reinforcement learning agent",
    "robotics": "a robotics model",
    "tabular-classification": "a table classifier",
    "time-series-forecasting": "a forecasting model",
  ]

  static func detect(info: HFModelInfo, files: [HFFile], format: HFFormat) -> HFTask {
    let hasProjector = files.contains { $0.lowerName.hasSuffix(".gguf") && $0.lowerName.contains("mmproj") }
    if let pipeline = info.pipelineTag {
      if visionPipelines.contains(pipeline) || (chatPipelines.contains(pipeline) && hasProjector) {
        return HFTask(kind: "vision_chat", description: "a chat model that can also read images", chat: true, vision: true)
      }
      if chatPipelines.contains(pipeline) {
        return HFTask(kind: "chat", description: "a text chat model", chat: true, vision: false)
      }
      if let what = otherTasks[pipeline] {
        return HFTask(kind: pipeline, description: what, chat: false, vision: false)
      }
    }
    if info.libraryName == "diffusers" {
      return HFTask(kind: "text-to-image", description: "an image generator", chat: false, vision: false)
    }
    if ["sentence-transformers"].contains(info.libraryName ?? "") {
      return HFTask(kind: "feature-extraction", description: "an embedding model", chat: false, vision: false)
    }
    if hasProjector {
      return HFTask(kind: "vision_chat", description: "a chat model that can also read images", chat: true, vision: true)
    }
    if [.gguf, .mlx, .mlc].contains(format) || info.hasTag("conversational") {
      return HFTask(kind: "chat", description: "a text model (type not stated; assumed chat)", chat: true, vision: false)
    }
    return HFTask(kind: "unknown", description: "a model of unstated type", chat: false, vision: false)
  }
}
