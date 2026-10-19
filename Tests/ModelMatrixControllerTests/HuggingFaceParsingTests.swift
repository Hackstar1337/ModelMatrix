import Foundation
import Testing
@testable import ModelMatrixControllerCore

// MARK: Names and links

@Test func hfParsesNamesLinksAndVersionLabels() throws {
  #expect(try HFQuery.parse("bartowski/Qwen2.5-7B-Instruct-GGUF") == .repo(.init(owner: "bartowski", name: "Qwen2.5-7B-Instruct-GGUF")))
  #expect(
    try HFQuery.parse("  hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M ")
      == .repo(.init(owner: "bartowski", name: "Qwen2.5-7B-Instruct-GGUF", variant: "Q4_K_M")))
  #expect(
    try HFQuery.parse("https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/blob/main/gemma-3-4b-it-Q4_K_M.gguf")
      == .repo(.init(owner: "ggml-org", name: "gemma-3-4b-it-GGUF", revision: "main", file: "gemma-3-4b-it-Q4_K_M.gguf")))
  #expect(
    try HFQuery.parse("https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/tree/v1.0")
      == .repo(.init(owner: "Qwen", name: "Qwen2.5-7B-Instruct", revision: "v1.0")))
  #expect(try HFQuery.parse("https://huggingface.co/models/Qwen/Qwen2.5-7B-Instruct") == .repo(.init(owner: "Qwen", name: "Qwen2.5-7B-Instruct")))
  #expect(try HFQuery.parse("qwen2.5 coder 7b") == .search("qwen2.5 coder 7b"))
  #expect(try HFQuery.parse("https://hf-mirror.com/a/b", extraHost: "hf-mirror.com") == .repo(.init(owner: "a", name: "b")))
}

@Test func hfRejectsUnsafeOrWrongInput() {
  let bad = [
    "", "   ", "../../etc/passwd", "owner/..", "owner/name/../../x", "https://evil.example.com/a/b",
    "file:///etc/passwd", "datasets/foo/bar", "https://huggingface.co/spaces/a/b", "owner/na me",
    "owner/name\u{0}", "owner/name\nnext", "-owner/name", "owner/name:Q4 K", "owner/name:../x",
    "https://huggingface.co/a/b/blob/main/../../secret", "https://huggingface.co/a/b/blob/main",
    "https://huggingface.co/a/b/edit/main", String(repeating: "a", count: 301), "owner/" + String(repeating: "n", count: 97),
    "search;rm -rf", "https://hf-mirror.com/a/b",
  ]
  for input in bad {
    #expect(throws: HFError.self, "\(input.debugDescription) should be rejected") { try HFQuery.parse(input) }
  }
}

@Test func hfBuildsSafelyEncodedAddresses() {
  let client = HFClient(endpoint: HFClient.defaultEndpoint, transport: FakeHFTransport())
  let reference = HFRepoReference(owner: "a", name: "b")
  #expect(client.resolvePath(reference, revision: "main", file: "dir/x y#1.gguf") == "/a/b/resolve/main/dir/x%20y%231.gguf")
  let url = client.url(path: "/api/models", query: [("search", "qwen 7b&x=1"), ("filter", "base_model:quantized:Q/R")])
  #expect(url?.absoluteString == "https://huggingface.co/api/models?search=qwen%207b%26x%3D1&filter=base_model:quantized:Q%2FR")
  #expect(ControllerRouter.formQuery("/api/hf/check?name=qwen+coder&context=32k&x") == ["name": "qwen coder", "context": "32k", "x": ""])
  #expect(ControllerRouter.formQuery("/api/hf/check?name=a%2Bb") == ["name": "a+b"])
  #expect(ControllerRouter.contextValue("32k") == 32768)
  #expect(ControllerRouter.contextValue("8192") == 8192)
  #expect(ControllerRouter.contextValue("lots") == nil)
}

@Test func hfOnlyFollowsPaginationOnTheSameHost() {
  let endpoint = HFClient.defaultEndpoint
  let next = HFClient.nextLink("<https://huggingface.co/api/models/a/b/tree/main?cursor=x>; rel=\"next\"", sameHostAs: endpoint)
  #expect(next?.absoluteString == "https://huggingface.co/api/models/a/b/tree/main?cursor=x")
  #expect(HFClient.nextLink("<https://evil.example.com/x>; rel=\"next\"", sameHostAs: endpoint) == nil)
  #expect(HFClient.nextLink("<http://huggingface.co/x>; rel=\"next\"", sameHostAs: endpoint) == nil)
  #expect(HFClient.retryAfter(["retry-after": "30"]) == 30)
  #expect(HFClient.retryAfter(["ratelimit": "\"api\";r=0;t=55"]) == 55)
}

// MARK: GGUF header

@Test func ggufHeaderReadsModelSettingsOnly() throws {
  let meta = try GGUFHeaderParser.parse(GGUFBuilder.qwen7B)
  #expect(meta.version == 3)
  #expect(meta.architecture == "qwen2")
  #expect(meta.archNumber("block_count") == 28)
  #expect(meta.archNumber("attention.head_count_kv") == 4)
  let arch = try #require(HFArchitecture.fromGGUF(meta))
  #expect(arch.layers == 28 && arch.keyLength == 128 && arch.maxContext == 32768)
  // 28 layers x 4 heads x (128 + 128) x 2 bytes = 57,344 bytes per token.
  #expect(arch.cacheBytes(context: 32768) == 57_344 * 32768)
}

@Test func ggufHeaderRejectsDamagedOrHostileFiles() {
  #expect(throws: GGUFHeaderError.notGGUF) { try GGUFHeaderParser.parse(Data("PK\u{3}\u{4}zipfile".utf8)) }
  #expect(throws: GGUFHeaderError.notGGUF) { try GGUFHeaderParser.parse(GGUFBuilder.header([], version: 9)) }
  #expect(throws: GGUFHeaderError.truncated) { try GGUFHeaderParser.parse(GGUFBuilder.qwen7B.prefix(60)) }
  #expect(throws: GGUFHeaderError.truncated) { try GGUFHeaderParser.parse(Data("GG".utf8)) }
  // A string claiming to be 1 TB long, and an absurd number of settings.
  var huge = Data("GGUF".utf8)
  GGUFBuilder.append(&huge, UInt32(3))
  GGUFBuilder.append(&huge, UInt64(1))
  GGUFBuilder.append(&huge, UInt64(1))
  GGUFBuilder.append(&huge, UInt64(1) << 40)
  #expect(throws: GGUFHeaderError.self) { try GGUFHeaderParser.parse(huge + Data(repeating: 65, count: 64)) }
  var many = Data("GGUF".utf8)
  GGUFBuilder.append(&many, UInt32(3))
  GGUFBuilder.append(&many, UInt64(1))
  GGUFBuilder.append(&many, UInt64.max)
  #expect(throws: GGUFHeaderError.malformed("too many settings")) { try GGUFHeaderParser.parse(many) }
}

// MARK: Memory

@Test func hfCountsSlidingWindowLayersAsShortMemory() throws {
  let arch = try #require(HFArchitecture.fromGGUF(try GGUFHeaderParser.parse(GGUFBuilder.gemma3)))
  #expect(arch.slidingLayers == 29 && arch.slidingWindow == 1024)
  // 5 full layers keep all 32K tokens; 29 sliding layers keep 1,024.
  let perLayerToken: Int64 = 4 * (256 + 256) * 2
  #expect(arch.cacheBytes(context: 32768) == perLayerToken * (5 * 32768 + 29 * 1024))
  #expect((0..<34).filter { !arch.isSlidingLayer($0) }.count == 5)
}

@Test func hfReadsLayoutFromConfigJSON() throws {
  let config: [String: Any] = [
    "model_type": "qwen2", "num_hidden_layers": 28, "num_attention_heads": 28, "num_key_value_heads": 4,
    "hidden_size": 3584, "max_position_embeddings": 32768,
  ]
  let arch = try #require(HFArchitecture.fromConfig(config))
  #expect(arch.cacheBytes(context: 1000) == 57_344 * 1000)
  let hybrid: [String: Any] = [
    "text_config": [
      "num_hidden_layers": 4, "num_attention_heads": 8, "num_key_value_heads": 2, "head_dim": 64,
      "layer_types": ["linear_attention", "full_attention", "sliding_attention", "full_attention"],
      "sliding_window": 128,
    ]
  ]
  let mixed = try #require(HFArchitecture.fromConfig(hybrid))
  #expect(mixed.kvHeads == [0, 2, 2, 2])
  #expect(mixed.slidingLayers == 1)
  #expect(HFArchitecture.fromConfig(["num_hidden_layers": 0]) == nil)
}

@Test func hfFitLevelsAndDefaults() {
  let arch = HFArchitecture.rough(parameters: 7_000_000_000, maxContext: 32768)
  let budget: Int64 = 30 << 30
  #expect(HFMemoryPlanner.fit(weights: 4 << 30, projector: 0, arch: arch, context: 8192, budget: budget).level == "good")
  #expect(HFMemoryPlanner.fit(weights: 25 << 30, projector: 0, arch: arch, context: 8192, budget: budget).level == "tight")
  #expect(HFMemoryPlanner.fit(weights: 40 << 30, projector: 0, arch: arch, context: 8192, budget: budget).level == "too_big")
  #expect(HFMemoryPlanner.defaultContext(maxContext: 131072) == 32768)
  #expect(HFMemoryPlanner.defaultContext(maxContext: 4096) == 4096)
  #expect(HFMemoryPlanner.defaultContext(maxContext: nil) == 8192)
  #expect(HFMachine.estimatedBudget(memoryBytes: 8 << 30, appleSilicon: true) == (8 << 30) * 2 / 3)
  #expect(HFMachine.estimatedBudget(memoryBytes: 64 << 30, appleSilicon: true) == 48 << 30)
  #expect(HFMachine.estimatedBudget(memoryBytes: 16 << 30, appleSilicon: false) == (16 << 30) * 3 / 5)
}

// MARK: Versions

func fixtureFiles(_ repo: String) throws -> [HFFile] {
  let url = FakeHFTransport.fixtures.appendingPathComponent("tree__\(FakeHFTransport.slug(repo)).json")
  let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] ?? []
  return HFFile.list(from: entries)
}

@Test func hfGroupsSplitFilesAndMarksRetiredTypes() throws {
  let small = HFVariantBuilder.gguf(files: try fixtureFiles("bartowski/Qwen2.5-7B-Instruct-GGUF"), parameters: 7_615_616_512)
  let labels = small.variants.map(\.label)
  #expect(labels.contains("Q4_K_M") && labels.contains("Q8_0") && labels.contains("F16"))
  #expect(small.variants.first { $0.label == "Q4_0_4_4" }?.supported == false)
  #expect(small.variants.first { $0.label == "F16" }?.fullPrecision == true)
  #expect(small.variants.allSatisfy { $0.files.allSatisfy { $0.sha256?.count == 64 } })
  #expect(small.projector == nil)

  let large = HFVariantBuilder.gguf(files: try fixtureFiles("bartowski/Qwen2.5-72B-Instruct-GGUF"), parameters: nil)
  let q8 = try #require(large.variants.first { $0.label == "Q8_0" })
  #expect(q8.files.count > 1)
  #expect(q8.totalBytes == q8.files.reduce(0) { $0 + $1.size })
  #expect(q8.files.allSatisfy { $0.path.contains("-of-") })
  #expect(Set(large.variants.map(\.label)).count == large.variants.count)

  let vision = HFVariantBuilder.gguf(files: try fixtureFiles("ggml-org/gemma-3-4b-it-GGUF"), parameters: nil)
  #expect(vision.projector?.path == "mmproj-model-f16.gguf")
  #expect(!vision.variants.contains { $0.files.contains { $0.path.contains("mmproj") } })
}

@Test func hfReadsUnslothDynamicLabels() throws {
  let result = HFVariantBuilder.gguf(files: try fixtureFiles("unsloth/Qwen3-30B-A3B-GGUF"), parameters: 30_532_122_624)
  #expect(result.variants.contains { $0.label.hasPrefix("UD-") })
  #expect(result.variants.allSatisfy { ($0.bitsPerWeight ?? 0) > 1 })
}

@Test func hfRecognisesConversionsOfTheSameModel() {
  #expect(HFCheckService.isConversion("bartowski/Qwen2.5-7B-Instruct-GGUF", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(HFCheckService.isConversion("mradermacher/Qwen2.5-7B-Instruct-i1-GGUF", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(HFCheckService.isConversion("x/Qwen2.5-7B-Instruct-Q4_K_M-GGUF", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(HFCheckService.isConversion("bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", of: "Llama-3.1-8B-Instruct", owner: "meta-llama"))
  #expect(HFCheckService.isConversion("mlx-community/Qwen2.5-7B-Instruct-4bit", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(!HFCheckService.isConversion("x/Qwen2.5-7B-Instruct-abliterated-GGUF", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(!HFCheckService.isConversion("x/theranotes-Llama-3.1-8B-Instruct-4bit", of: "Llama-3.1-8B-Instruct", owner: "meta-llama"))
  #expect(!HFCheckService.isConversion("intrect/VELA", of: "Qwen2.5-7B-Instruct", owner: "Qwen"))
  #expect(HFCheckService.modelStem("mlc-ai/Llama-3-8B-Instruct-q4f16_1-MLC") == "Llama-3-8B-Instruct")
  #expect(HFCheckService.modelStem("mlx-community/Qwen2.5-7B-Instruct-4bit") == "Qwen2.5-7B-Instruct")
  #expect(HFCheckService.modelStem("Qwen/Qwen2.5-7B-Instruct-AWQ") == "Qwen2.5-7B-Instruct")
  #expect(HFCheckService.modelStem("Qwen/Qwen2.5-7B-Instruct") == "Qwen2.5-7B-Instruct")
}

@Test func hfSmallModelBitsAreCappedNearTheTypeValue() {
  // SmolLM2-135M: embeddings dominate the file, so size-based bits overstate quality.
  let files = [
    HFFile(path: "SmolLM2-135M-Instruct-Q2_K.gguf", size: 88_200_000),
    HFFile(path: "SmolLM2-135M-Instruct-Q4_K_M.gguf", size: 105_500_000),
    HFFile(path: "SmolLM2-135M-Instruct-Q8_0.gguf", size: 144_800_000),
  ]
  let variants = HFVariantBuilder.gguf(files: files, parameters: 134_515_008).variants
  let byLabel = Dictionary(uniqueKeysWithValues: variants.map { ($0.label, $0) })
  #expect(byLabel["Q2_K"]?.quality == "fair")
  #expect((byLabel["Q2_K"]?.bitsPerWeight ?? 9) <= 3.36)
  #expect((byLabel["Q2_K"]?.bitsPerWeight ?? 0) < HFMemoryPlanner.minimumRecommendedBits)
  #expect(byLabel["Q8_0"]?.quality == "near original")
  // Normal-sized models keep their measured value.
  let big = HFVariantBuilder.gguf(
    files: [HFFile(path: "Qwen2.5-7B-Instruct-Q4_K_M.gguf", size: 4_683_073_888)], parameters: 7_615_616_512
  ).variants
  #expect(abs((big.first?.bitsPerWeight ?? 0) - 4.92) < 0.02)
}

@Test func hfParameterCountNearOneBillionReadsAsBillions() {
  #expect(HFCheckText.params(999_885_952) == "1.0B")
  #expect(HFCheckText.params(494_032_768) == "494M")
  #expect(HFCheckText.params(7_615_616_512) == "7.6B")
}
