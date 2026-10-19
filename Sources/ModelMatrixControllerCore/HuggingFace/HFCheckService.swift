import Foundation

/// Checks a Hugging Face model before anything is downloaded: format,
/// versions, sizes, memory fit on this machine, and the engine it needs.
/// Read-only: no downloads, installs, profile changes or model starts.
public final class HFCheckService: @unchecked Sendable {
  public let client: HFClient
  let engines: HFEngineProbe
  let machineProbe: @Sendable () -> HFMachine
  static let headerReads = [512 * 1024, 4 * 1024 * 1024]
  public static let contextRange = 512...1_048_576

  public init(
    client: HFClient = HFClient(), engines: HFEngineProbe = HFEngineProbe(),
    machine: @escaping @Sendable () -> HFMachine = { HFMachine.current() }
  ) {
    self.client = client
    self.engines = engines
    self.machineProbe = machine
  }

  /// `input` is what the user typed; `context` overrides the context length.
  public func check(_ input: String, context: Int? = nil) throws -> HFCheckReport {
    if let context, !Self.contextRange.contains(context) {
      throw HFError.invalidName("Context must be between 512 and 1048576 tokens.")
    }
    let machine = machineProbe()
    switch try HFQuery.parse(input, extraHost: client.mirrorHost) {
    case .search(let text):
      return try searchReport(input: input, text: text, machine: machine)
    case .repo(let reference):
      let infoJSON: [String: Any]
      do {
        infoJSON = try client.modelInfo(reference)
      } catch HFError.notFound(let repo) {
        var report = searchReportShell(input: input, machine: machine)
        report.verdict = HFVerdict(
          code: "not_found", title: "Model not found",
          detail: HFError.notFound(repo).description, runnable: false)
        report.searchResults = (try? search(reference.name, machine: machine, limit: 6)) ?? []
        return report
      }
      return try modelReport(input: input, reference: reference, infoJSON: infoJSON, machine: machine, context: context)
    }
  }

  /// Search by free text, ready-to-run formats first.
  public func search(_ text: String, machine: HFMachine, limit: Int = 10) throws -> [HFAlternative] {
    var results = try client.models(search: text, filters: ["gguf"], limit: limit).map { Self.alternative($0, format: "gguf") }
    if machine.appleSilicon {
      results += ((try? client.models(search: text, filters: ["mlx"], limit: limit)) ?? []).map {
        Self.alternative($0, format: "mlx")
      }
    }
    var seen = Set<String>()
    return results.filter { seen.insert($0.repo.lowercased()).inserted }
      .sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
      .prefix(limit).map { $0 }
  }

  // MARK: Reports

  func searchReportShell(input: String, machine: HFMachine) -> HFCheckReport {
    HFCheckReport(
      input: input, kind: "search",
      verdict: HFVerdict(code: "choose_model", title: "", detail: "", runnable: false),
      machine: machine, checkedAt: Self.timestamp())
  }

  func searchReport(input: String, text: String, machine: HFMachine) throws -> HFCheckReport {
    var report = searchReportShell(input: input, machine: machine)
    report.searchResults = try search(text, machine: machine)
    report.verdict = HFVerdict(
      code: "choose_model", title: "Pick a model",
      detail: report.searchResults.isEmpty
        ? "Nothing ready to run matched \"\(text)\". Try other words or the full owner/name."
        : "These ready-to-run models match \"\(text)\". Check one by its full owner/name.",
      runnable: false)
    return report
  }

  func modelReport(
    input: String, reference: HFRepoReference, infoJSON: [String: Any], machine: HFMachine, context requested: Int?
  ) throws -> HFCheckReport {
    let info = HFModelInfo(json: infoJSON)
    let revision = reference.revision ?? info.sha ?? "main"
    let files = HFFile.list(from: try client.tree(reference, revision: revision))
    let format = HFFormat.detect(info: info, files: files)
    let task = HFTask.detect(info: info, files: files, format: format)
    let login = info.gated != nil
    let repoID = info.id.isEmpty ? reference.id : info.id
    var report = HFCheckReport(
      input: input, kind: "model",
      repo: HFRepoSummary(
        id: repoID, url: "\(client.endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(repoID)",
        revision: reference.revision ?? "main", sha: info.sha, license: info.license, gated: login,
        loginRequired: login, downloads: info.downloads, likes: info.likes, library: info.libraryName,
        pipelineTag: info.pipelineTag, baseModel: info.baseModels.first, baseRelation: info.baseRelation,
        lastModified: info.lastModified),
      format: HFFormatSummary(id: format, name: format.displayName, summary: format.summary), task: task,
      verdict: HFVerdict(code: "not_supported", title: "", detail: "", runnable: false), machine: machine,
      checkedAt: Self.timestamp())
    let statuses = engines.detect(machine: machine)
    let needed: HFEngineID? = (format == .mlx && !machine.appleSilicon) ? nil : format.engine
    let neededStatus = statuses.first { $0.id == needed }
    report.engine = HFEngineSummary(
      needed: needed, neededName: needed?.displayName, ready: neededStatus?.installed ?? false,
      backup: format == .gguf ? .ollama : nil, engines: statuses)
    if machine.rosetta {
      report.notes.append("ModelMatrix is running through Rosetta, so this Mac is treated as an Intel Mac. Install the Apple Silicon version for faster models and MLX.")
    }

    // Not a chat model: say what it is and stop.
    guard task.chat || task.kind == "unknown" else {
      report.verdict = HFVerdict(
        code: "not_supported", title: "Not a chat model",
        detail: "\(repoID) is \(task.description). ModelMatrix runs chat models (text, or text with images).",
        runnable: false)
      return report
    }
    if task.kind == "unknown" {
      report.notes.append("The repository does not say what kind of model this is; it is treated as a chat model.")
    }

    // Formats that do not run here: point at ready-made versions.
    if format.offersAlternatives || (format == .mlx && !machine.appleSilicon) {
      report.alternatives = alternatives(info: info, machine: machine)
      let why = format == .mlx
        ? "MLX runs only on Apple Silicon Macs, and this Mac has an Intel processor."
        : format == .original
          ? "ModelMatrix can't run original full-size weights directly."
          : "ModelMatrix can't run \(format.displayName) files directly."
      let kinds = machine.appleSilicon ? "GGUF or MLX" : "GGUF"
      report.verdict = report.alternatives.isEmpty
        ? HFVerdict(
          code: "not_supported", title: "\(format.displayName) can't run in ModelMatrix",
          detail: why + " No ready-to-run \(kinds) version was found on Hugging Face.",
          runnable: false)
        : HFVerdict(
          code: "use_alternative", title: "Use a ready-to-run version instead",
          detail: why + " Check one of the ready-to-run \(kinds) versions listed below.",
          runnable: false)
      return report
    }

    // GGUF or MLX: list versions and work out the fit.
    var variants: [HFVariant]
    var projector: HFFile?
    var arch: HFArchitecture?
    if format == .gguf {
      let grouped = HFVariantBuilder.gguf(files: files, parameters: info.ggufParameters)
      variants = grouped.variants
      projector = task.vision ? grouped.projector : nil
      if let file = reference.file {
        variants = variants.filter { $0.files.contains { $0.path == file } }
        if variants.isEmpty { throw HFError.invalidName("\(file) is not a model file in \(repoID).") }
      }
      if !login, let sample = variants.filter(\.supported).first?.files.first {
        arch = readGGUFLayout(reference, revision: revision, path: sample.path)
      }
      if variants.contains(where: { HFVariantBuilder.retiredLabels.contains($0.label.uppercased()) }) {
        report.notes.append("Q4_0_4_4, Q4_0_4_8 and Q4_0_8_8 are old Arm-only types that current llama.cpp no longer loads; they are listed but can't be chosen.")
      }
    } else {
      let config = login || !files.contains(where: { $0.path == "config.json" })
        ? nil : try? client.fileJSON(reference, revision: revision, path: "config.json")
      variants = [HFVariantBuilder.mlx(repoName: reference.name, files: files, parameters: info.safetensorsParameters, config: config)]
      arch = config.flatMap(HFArchitecture.fromConfig)
      if info.hasTag("custom_code") {
        report.notes.append("This repository includes its own Python code. ModelMatrix never runs code from downloads, so it may not load in mlx-lm.")
      }
      report.alternatives = mlxSiblings(reference: reference, machine: machine)
    }
    let layout = arch ?? HFArchitecture.rough(parameters: info.parameters, maxContext: info.ggufContextLength)
    if layout.source == "rough" {
      report.notes.append(
        login
          ? "The model's layout can't be read without a Hugging Face login, so the chat-memory part of each estimate is rough."
          : "The model's layout could not be read, so the chat-memory part of each estimate is rough.")
    }
    let maxContext = layout.maxContext ?? info.ggufContextLength
    let defaultContext = HFMemoryPlanner.defaultContext(maxContext: maxContext)
    var context = requested ?? defaultContext
    if let maxContext, maxContext > 0, context > maxContext {
      report.notes.append("\(repoID) supports at most \(maxContext) tokens of context; using that.")
      context = maxContext
    }
    report.model = HFModelSummary(
      name: nil, architecture: layout.name ?? info.ggufArchitecture ?? info.modelType, parameters: info.parameters,
      maxContext: maxContext, defaultContext: defaultContext, context: context, layoutSource: layout.source,
      cacheBytesAtContext: layout.cacheBytes(context: context))
    report.projector = projector
    let extra = projector?.size ?? 0
    let budget = machine.budgetBytes
    report.variants = variants.map { variant in
      let fit = variant.supported
        ? HFMemoryPlanner.fit(weights: variant.totalBytes, projector: extra, arch: layout, context: context, budget: budget)
        : nil
      return HFVariantReport(
        label: variant.label, files: variant.files, totalBytes: variant.totalBytes,
        downloadBytes: variant.totalBytes + extra, bitsPerWeight: variant.bitsPerWeight, quality: variant.quality,
        fullPrecision: variant.fullPrecision, supported: variant.supported, unsupportedReason: variant.unsupportedReason,
        fit: fit,
        longestGoodContext: variant.supported
          ? HFMemoryPlanner.longestGoodContext(weights: variant.totalBytes, projector: extra, arch: layout, budget: budget)
          : nil,
        fitsOnDisk: machine.freeDiskBytes.map { variant.totalBytes + extra <= $0 })
    }
    if let projector {
      report.notes.append("Vision: \(projector.path) (\(Self.gb(projector.size))) is included with every version; it lets the model read images.")
    }
    if variants.contains(where: \.fullPrecision) {
      report.notes.append("F16/BF16 versions keep the original size; they are listed but not recommended for chatting.")
    }
    if !machine.appleSilicon {
      report.notes.append("Intel Macs run models on the processor, which is much slower than Apple Silicon. Smaller versions respond faster.")
    }
    report.notes.append("Memory numbers are estimates: model files + chat memory for the context length + 1 GB working space, compared with the \(Self.mem(budget)) this machine can give a model.")

    // Recommendation: the one the user asked for, or the best fit.
    let pick: (index: Int, fit: HFFit, reason: String)?
    if let wanted = reference.variant {
      let index = variants.firstIndex { $0.label.caseInsensitiveCompare(wanted) == .orderedSame }
        ?? variants.firstIndex { $0.label.uppercased().replacingOccurrences(of: "UD-", with: "") == wanted.uppercased() }
      if let index, variants[index].supported {
        let fit = HFMemoryPlanner.bestFit(
          weights: variants[index].totalBytes, projector: extra, arch: layout, defaultContext: context,
          budget: budget, fixedContext: requested == nil ? nil : context)
        pick = (index, fit, "The version you asked for.")
      } else {
        report.notes.append("\(repoID) has no usable version named \(wanted); showing the best fit instead.")
        pick = HFMemoryPlanner.recommend(variants: variants, projector: extra, arch: layout, defaultContext: defaultContext, budget: budget, fixedContext: requested == nil ? nil : context)
      }
    } else {
      pick = HFMemoryPlanner.recommend(variants: variants, projector: extra, arch: layout, defaultContext: defaultContext, budget: budget, fixedContext: requested == nil ? nil : context)
    }
    if let pick {
      report.variants[pick.index].recommended = true
      report.recommendation = HFRecommendation(
        label: variants[pick.index].label, context: pick.fit.context, needBytes: pick.fit.needBytes,
        downloadBytes: variants[pick.index].totalBytes + extra, level: pick.fit.level, reason: pick.reason)
    }
    let smallFits = pick == nil
      && HFMemoryPlanner.anythingFits(variants: variants, projector: extra, arch: layout, budget: budget)
    report.verdict = verdict(
      report: report, repoID: repoID, login: login, machine: machine, picked: pick?.fit, onlyLowQualityFits: smallFits)
    if report.verdict.runnable { report.downloadFolder = Self.downloadFolder(for: repoID) }
    return report
  }

  func verdict(
    report: HFCheckReport, repoID: String, login: Bool, machine: HFMachine, picked: HFFit?,
    onlyLowQualityFits: Bool = false
  ) -> HFVerdict {
    let engineName = report.engine?.neededName ?? "the engine"
    guard report.variants.contains(where: \.supported) else {
      return HFVerdict(code: "not_supported", title: "No usable version", detail: "None of the files in \(repoID) can be run by current engines.", runnable: false)
    }
    guard let picked else {
      if onlyLowQualityFits {
        return HFVerdict(
          code: "too_big", title: "Too big for this machine",
          detail: "Only versions under 3.5 bits would fit in the \(Self.mem(machine.budgetBytes)) this machine can give a model, and they lose too much quality to recommend. Try a smaller model, or name a version to try it anyway (\(repoID):LABEL).",
          runnable: false)
      }
      return HFVerdict(
        code: "too_big", title: "Too big for this machine",
        detail: "Even the smallest version needs more than the \(Self.mem(machine.budgetBytes)) this machine can give a model. Try a smaller model (fewer parameters).",
        runnable: false)
    }
    if picked.level == "too_big" {
      return HFVerdict(
        code: "too_big", title: "That version is too big",
        detail: "It needs about \(Self.mem(picked.needBytes)), more than the \(Self.mem(machine.budgetBytes)) available. Choose a smaller version.",
        runnable: false)
    }
    if login {
      return HFVerdict(
        code: "login_required", title: "Runs here, but needs a Hugging Face login",
        detail: "Accept the model's license on huggingface.co while logged in; ModelMatrix can't download login-only models yet.",
        runnable: true)
    }
    if report.engine?.ready != true {
      return HFVerdict(
        code: "needs_engine", title: "Runs here once \(engineName) is installed",
        detail: "This model needs \(engineName), which isn't installed on this machine yet.", runnable: true)
    }
    return HFVerdict(code: "ready", title: "Ready to run on this machine", detail: "\(engineName) is installed and the recommended version fits.", runnable: true)
  }

  // MARK: Helpers

  /// Reads the start of a GGUF file (at most 4 MB, never the whole model).
  func readGGUFLayout(_ reference: HFRepoReference, revision: String, path: String) -> HFArchitecture? {
    for length in Self.headerReads {
      guard let data = try? client.fileHead(reference, revision: revision, path: path, length: length) else { return nil }
      do {
        return HFArchitecture.fromGGUF(try GGUFHeaderParser.parse(data))
      } catch GGUFHeaderError.truncated {
        if data.count < length { return nil }
        continue
      } catch {
        return nil
      }
    }
    return nil
  }

  /// GGUF (and, on Apple Silicon, MLX) versions made from the same base model.
  /// Plain conversions of the model come first; modified versions (fine-tunes
  /// that Hugging Face also lists) after, marked as such.
  func alternatives(info: HFModelInfo, machine: HFMachine) -> [HFAlternative] {
    let base = info.baseRelation == "quantized" ? (info.baseModels.first ?? info.id) : info.id
    let baseParts = base.split(separator: "/").map(String.init)
    let baseName = baseParts.last ?? base
    let baseOwner = baseParts.count == 2 ? baseParts[0] : ""
    var list: [HFAlternative] = []
    for (format, keep) in [("gguf", 6), ("mlx", machine.appleSilicon ? 4 : 0)] where keep > 0 {
      let found = ((try? client.models(filters: ["base_model:quantized:\(base)", format], limit: 20)) ?? [])
        .map { item -> HFAlternative in
          var alternative = Self.alternative(item, format: format)
          alternative.sameModel = Self.isConversion(alternative.repo, of: baseName, owner: baseOwner)
          return alternative
        }
        .filter { $0.repo.caseInsensitiveCompare(info.id) != .orderedSame }
      let ordered = found.filter { $0.sameModel == true } + found.filter { $0.sameModel != true }
      if ordered.isEmpty {
        list += nameMatches(Self.modelStem(info.id), format: format, excluding: info.id).prefix(keep)
      } else {
        list += ordered.prefix(keep)
      }
    }
    return list
  }

  /// Repository metadata is sometimes wrong (a conversion labelled as a
  /// fine-tune of another model). Then search by name and keep only exact
  /// conversions of the same model.
  func nameMatches(_ stem: String, format: String, excluding id: String) -> [HFAlternative] {
    guard stem.count >= 3 else { return [] }
    let found = (try? client.models(search: stem, filters: [format], limit: 20)) ?? []
    return found.map { item -> HFAlternative in
      var alternative = Self.alternative(item, format: format)
      alternative.sameModel = true
      return alternative
    }.filter {
      Self.isConversion($0.repo, of: stem) && $0.repo.caseInsensitiveCompare(id) != .orderedSame
    }
  }

  static func downloadFolder(for repoID: String) -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("ModelMatrix/Models", isDirectory: true)
      .appendingPathComponent(repoID, isDirectory: true).path
  }

  /// "Llama-3-8B-Instruct-q4f16_1-MLC" -> "Llama-3-8B-Instruct".
  static func modelStem(_ repo: String) -> String {
    let name = repo.split(separator: "/").last.map(String.init) ?? repo
    let suffix = #"(?i)([-_.](mlx|gguf|awq|gptq|mlc|exl2|fp8|int4|int8|\d{1,2}-?bits?|bf16|fp16|f16|dwq|mxfp4|mxfp8|nvfp4|q\d[a-z0-9_]*|i1))+$"#
    return name.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
  }

  /// "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF" is a conversion of
  /// "Llama-3.1-8B-Instruct"; "...-abliterated-GGUF" is a modified version.
  static func isConversion(_ repo: String, of baseName: String, owner: String = "") -> Bool {
    let name = (repo.split(separator: "/").last.map(String.init) ?? repo).lowercased()
    let stem = baseName.lowercased()
    guard let range = name.range(of: stem) else { return false }
    let before = String(name[..<range.lowerBound])
    let after = String(name[range.upperBound...])
    // Converters sometimes put the maker in front: "Meta-Llama-...",
    // "google_gemma-...". Any other prefix means a different model.
    let maker = owner.lowercased()
    let makerFirst = maker.split(separator: "-").first.map(String.init) ?? maker
    let prefixOK = before.isEmpty
      || (!maker.isEmpty && [maker + "_", maker + "-", makerFirst + "-", makerFirst + "_"].contains(before))
    let token = #"(gguf|mlx|i1|imat|imatrix|\d{1,2}-?bits?|bf16|fp16|f16|q\d(_k)?(_[a-z0-9]+)*|iq\d(_[a-z0-9]+)*|dwq|mxfp4|awq|gptq|quantized|quant)"#
    return prefixOK && after.range(of: "^([-_.]" + token + ")*$", options: .regularExpression) != nil
  }

  /// Other MLX versions of the same model (for example 4-bit and 8-bit).
  func mlxSiblings(reference: HFRepoReference, machine: HFMachine) -> [HFAlternative] {
    guard machine.appleSilicon else { return [] }
    let suffix = #"(?i)(-(mlx|\d{1,2}-?bits?|bf16|fp16|f16|dwq|mxfp4|mxfp8|nvfp4|q\d))+$"#
    let stem = reference.name.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
    guard stem.count >= 3 else { return [] }
    let found = (try? client.models(search: stem, filters: ["mlx"], author: reference.owner, limit: 20)) ?? []
    return found.map { Self.alternative($0, format: "mlx") }.filter {
      let name = $0.repo.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
      // Same model, different bit level: only a size suffix may follow.
      guard name.hasPrefix(stem.lowercased() + "-") else { return false }
      let rest = String(name.dropFirst(stem.count))
      return rest.range(of: "^" + suffix.dropFirst(4), options: [.regularExpression, .caseInsensitive]) != nil
        && $0.repo.caseInsensitiveCompare(reference.id) != .orderedSame
    }.prefix(6).map { $0 }
  }

  static func alternative(_ json: [String: Any], format: String) -> HFAlternative {
    let gated = (json["gated"] as? String) != nil || JSONSupport.boolValue(json["gated"]) == true
    return HFAlternative(
      repo: json["id"] as? String ?? json["modelId"] as? String ?? "", format: format,
      downloads: int(json["downloads"]), likes: int(json["likes"]), gated: gated)
  }

  /// Memory amounts in the units Macs use for memory (48 GB = 48 x 2^30).
  static func mem(_ bytes: Int64) -> String {
    let value = Double(bytes) / Double(1 << 30)
    return value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
  }

  /// File and disk sizes in the units Hugging Face and Finder use.
  static func gb(_ bytes: Int64) -> String {
    let value = Double(bytes) / 1_000_000_000
    return value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
  }

  static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}
