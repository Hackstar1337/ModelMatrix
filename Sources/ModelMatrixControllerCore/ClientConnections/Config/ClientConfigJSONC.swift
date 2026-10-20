import Foundation

internal enum ConfigTarget: String {
  case kilo, opencode
  var displayName: String { self == .kilo ? "Kilo Code" : "OpenCode" }
  var requiredVersion: String { self == .kilo ? "7.8.12" : "1.16.2" }
  var defaultFile: String { self == .kilo ? "kilo.jsonc" : "opencode.json" }
  var candidates: [String] {
    self == .kilo ? ["config.json", "kilo.json", "kilo.jsonc", "opencode.json", "opencode.jsonc"] : ["opencode.json", "opencode.jsonc"]
  }
}

internal func configJSONString(_ value: String) -> String {
  // Preserve plain forward slashes: native clients expand {file:...} on raw JSONC before parsing.
  // Quotes, backslashes, tabs and control characters still receive full JSON escaping.
  let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
  return String(decoding: bytes, as: UTF8.self)
}

internal enum ConfigFormat {
  // Both exact Stage 1 versions qualify models.<local-key>.id -> the wire identifier.
  // Output is an APPLICATION POLICY budget, not a claimed verified model maximum.
  static let generationOutputBudget = 8192
  static func outputBudget(context: Int) -> Int { min(context, generationOutputBudget) }
  static func modelJSON(modelID: String, context: Int?) -> String {
    var text = "{\"id\":\(configJSONString(modelID))"
    if let context {
      text += ",\"limit\":{\"context\":\(context),\"output\":\(outputBudget(context: context))}"
    }
    return text + "}"
  }
  static func providerJSON(modelKey: String, modelID: String, baseURL: String, keyFile: String, context: Int?) -> String {
    "{\"npm\":\"@ai-sdk/openai-compatible\",\"options\":{\"baseURL\":\(configJSONString(baseURL)),\"apiKey\":\(configJSONString("{file:\(keyFile)}"))},\"models\":{\(configJSONString(modelKey)):\(modelJSON(modelID: modelID, context: context))}}"
  }
}

internal struct ConfigJSONPatch {
  var patches: [Range<Int>: Data] = [:]
  let replacement: Data?
  init(replacement: Data? = nil) { self.replacement = replacement }
  mutating func set(_ range: Range<Int>, _ text: String) { patches[range] = Data(text.utf8) }
  func apply(to data: Data) throws -> Data {
    if let replacement { return replacement }
    let ascending = patches.keys.sorted { $0.lowerBound < $1.lowerBound }
    var lastEnd = 0
    for range in ascending {
      guard range.lowerBound >= lastEnd, range.upperBound <= data.count else {
        throw configError("write_failed", "invalid overlapping configuration patch", status: 500)
      }
      lastEnd = range.upperBound
    }
    var bytes = Array(data)
    for range in ascending.reversed() { bytes.replaceSubrange(range, with: patches[range]!) }
    return Data(bytes)
  }
}

internal struct ConfigJSONDocument {
  let data: Data
  let root: ConfigJSONNode
  init(data: Data) throws {
    guard data.count <= ConfigFileIO.maximumBytes, String(data: data, encoding: .utf8) != nil else {
      throw configError("invalid_configuration", "configuration is oversized or not valid UTF-8")
    }
    var parser = ConfigJSONParser(data: data)
    let parsed = try parser.parse()
    guard parsed.kind == .object else { throw configError("invalid_configuration", "configuration root must be an object") }
    self.data = data; self.root = parsed
  }
  var rootDefault: String? { root.member("model")?.value.stringValue(data) }

  func providerContainer() throws -> ConfigJSONNode? {
    let provider = root.member("provider")?.value
    if let provider, provider.kind != .object { throw configError("ownership_conflict", "provider root is not an object") }
    return provider
  }

  func providerFilterMembership(providerID: String) throws -> (enabled: Bool?, disabled: Bool?) {
    let enabled = try stringArray(named: "enabled_providers")
    let disabled = try stringArray(named: "disabled_providers")
    if disabled?.contains(providerID) == true {
      throw configError("provider_disabled", "disabled_providers explicitly disables \(providerID); remove that user setting before automatic setup")
    }
    return (enabled?.contains(providerID), disabled?.contains(providerID))
  }

  private func stringArray(named name: String) throws -> [String]? {
    guard let member = root.member(name) else { return nil }
    guard member.value.kind == .array else {
      throw configError("ownership_conflict", "\(name) must be an array of strings; automatic setup is declined")
    }
    return try member.value.arrayElements.map { element in
      guard let value = element.value.stringValue(data) else {
        throw configError("ownership_conflict", "\(name) must be an array of strings; automatic setup is declined")
      }
      return value
    }
  }

  func matchesOwned(providerID: String, modelKey: String, modelID: String, baseURL: String, keyFile: String, context: Int?) throws -> Bool {
    guard let provider = try providerContainer()?.member(providerID)?.value,
          provider.hasKeys(["npm", "options", "models"]),
          provider.member("npm")?.value.stringValue(data) == "@ai-sdk/openai-compatible",
          let options = provider.member("options")?.value, options.hasKeys(["baseURL", "apiKey"]),
          options.member("baseURL")?.value.stringValue(data) == baseURL,
          options.member("apiKey")?.value.stringValue(data) == "{file:\(keyFile)}",
          let models = provider.member("models")?.value, models.hasKeys([modelKey]),
          let model = models.member(modelKey)?.value,
          model.hasKeys(context == nil ? ["id"] : ["id", "limit"]),
          model.member("id")?.value.stringValue(data) == modelID else { return false }
    if let context {
      guard let limit = model.member("limit")?.value, limit.hasKeys(["context", "output"]),
            limit.member("context")?.value.intValue(data) == context,
            limit.member("output")?.value.intValue(data) == ConfigFormat.outputBudget(context: context) else { return false }
    }
    return true
  }

  func ownedHash(providerID: String, modelKey: String) throws -> String {
    guard let provider = try providerContainer()?.member(providerID)?.value, provider.kind == .object,
          provider.member("models")?.value.member(modelKey) != nil else {
      throw configError("ownership_conflict", "owned provider/model is missing")
    }
    return configHash(data.subdata(in: provider.start..<provider.end))
  }

  func additionPatch(providerID: String, modelKey: String, modelID: String, baseURL: String, keyFile: String, context: Int?, makeDefault: Bool) throws -> ConfigJSONPatch {
    let container = try providerContainer()
    let filters = try providerFilterMembership(providerID: providerID)
    var patch = ConfigJSONPatch()
    var rootAdditions: [String] = []
    if container?.member(providerID) != nil {
      guard try matchesOwned(providerID: providerID, modelKey: modelKey, modelID: modelID, baseURL: baseURL, keyFile: keyFile, context: context) else {
        throw configError("ownership_conflict", "requested namespace already exists and is not the exact approved single-model block")
      }
    } else {
      let entry = "\(configJSONString(providerID)): \(ConfigFormat.providerJSON(modelKey: modelKey, modelID: modelID, baseURL: baseURL, keyFile: keyFile, context: context))"
      if let container { patch.set(container.insertionRange, container.insertionPrefix + entry) }
      else { rootAdditions.append("\"provider\": {\(entry)}") }
    }
    if let enabled = root.member("enabled_providers")?.value, filters.enabled != true {
      appendArrayString(providerID, to: enabled, patch: &patch)
    }
    if makeDefault, rootDefault != "\(providerID)/\(modelKey)" {
      let desired = configJSONString("\(providerID)/\(modelKey)")
      if let model = root.member("model") {
        guard rootDefault != nil else { throw configError("ownership_conflict", "existing root default is not a string and cannot be safely restored") }
        patch.set(model.value.start..<model.value.end, desired)
      } else { rootAdditions.append("\"model\": \(desired)") }
    }
    // Accumulate additions: a single insertion point cannot hold independent provider/model patches.
    if !rootAdditions.isEmpty { patch.set(root.insertionRange, root.insertionPrefix + rootAdditions.joined(separator: ", ")) }
    return patch
  }

  func removalPatch(providerID: String, modelKey: String, restoreDefault: String?, ownsDefault: Bool, ownsEnabledProviderMembership: Bool?) throws -> ConfigJSONPatch {
    guard let container = try providerContainer(), let provider = container.member(providerID),
          provider.value.kind == .object, provider.value.member("models")?.value.member(modelKey) != nil else {
      throw configError("ownership_conflict", "owned provider/model is missing")
    }
    var patch = ConfigJSONPatch()
    removeMember(provider, from: container, patch: &patch)
    if ownsEnabledProviderMembership == true, let enabled = root.member("enabled_providers")?.value,
       let element = enabled.arrayElements.first(where: { $0.value.stringValue(data) == providerID }) {
      removeArrayElement(element, from: enabled, patch: &patch)
    }
    if ownsDefault, rootDefault == "\(providerID)/\(modelKey)", let model = root.member("model") {
      if let restoreDefault { patch.set(model.value.start..<model.value.end, configJSONString(restoreDefault)) }
      else { removeMember(model, from: root, patch: &patch) }
    }
    return patch
  }

  private func appendArrayString(_ value: String, to array: ConfigJSONNode, patch: inout ConfigJSONPatch) {
    let separator = array.arrayElements.last?.commaAfter == nil && !array.arrayElements.isEmpty ? ", " : " "
    patch.set((array.end - 1)..<(array.end - 1), separator + configJSONString(value))
  }

  private func removeArrayElement(_ element: ConfigJSONArrayElement, from array: ConfigJSONNode, patch: inout ConfigJSONPatch) {
    patch.set(element.value.start..<element.value.end, "")
    if let comma = element.commaAfter { patch.set(comma..<comma + 1, "") }
    else if let index = array.arrayElements.firstIndex(where: { $0 == element }), index > 0,
            let comma = array.arrayElements[index - 1].commaAfter { patch.set(comma..<comma + 1, "") }
  }

  private func removeMember(_ member: ConfigJSONMember, from object: ConfigJSONNode, patch: inout ConfigJSONPatch) {
    patch.set(member.keyStart..<member.value.end, "")
    // Remove only a comma token, never the neighboring member's value or intervening comments.
    if let comma = member.commaAfter { patch.set(comma..<comma + 1, "") }
    else if let index = object.members.firstIndex(where: { $0.key == member.key }), index > 0,
            let comma = object.members[index - 1].commaAfter { patch.set(comma..<comma + 1, "") }
  }
}

internal struct ConfigJSONMember: Hashable {
  let key: String
  let keyStart: Int
  let value: ConfigJSONNode
  let commaAfter: Int?
}
internal struct ConfigJSONArrayElement: Hashable {
  let value: ConfigJSONNode
  let commaAfter: Int?
}
internal enum ConfigJSONKind: Hashable { case object, array, scalar }
internal struct ConfigJSONNode: Hashable {
  let kind: ConfigJSONKind
  let start: Int
  let end: Int
  let members: [ConfigJSONMember]
  let arrayElements: [ConfigJSONArrayElement]
  func member(_ key: String) -> ConfigJSONMember? { members.first { $0.key == key } }
  func hasKeys(_ keys: Set<String>) -> Bool { kind == .object && Set(members.map(\.key)) == keys }
  var insertionRange: Range<Int> { let point = members.last?.value.end ?? (end - 1); return point..<point }
  var insertionPrefix: String { members.isEmpty ? "" : ", " }
  func stringValue(_ data: Data) -> String? {
    guard kind == .scalar else { return nil }
    return (try? JSONSerialization.jsonObject(with: data.subdata(in: start..<end), options: [.fragmentsAllowed])) as? String
  }
  func intValue(_ data: Data) -> Int? {
    guard kind == .scalar else { return nil }
    // Int's strict lexical conversion avoids NSNumber truncation of fractional values and booleans.
    return Int(String(decoding: data.subdata(in: start..<end), as: UTF8.self))
  }
}

internal struct ConfigJSONParser {
  let bytes: [UInt8]
  var index = 0
  static let maximumDepth = 128
  init(data: Data) { bytes = Array(data) }
  mutating func parse() throws -> ConfigJSONNode {
    try skip(); let node = try value(depth: 0); try skip()
    guard index == bytes.count else { throw parseError() }
    return node
  }
  mutating func value(depth: Int) throws -> ConfigJSONNode {
    guard depth <= Self.maximumDepth else { throw configError("invalid_configuration", "configuration nesting is too deep") }
    try skip(); let start = index
    guard index < bytes.count else { throw parseError() }
    switch bytes[index] {
    case 123: return try object(start: start, depth: depth)
    case 91: return try array(start: start, depth: depth)
    case 34: _ = try string()
    case 45, 48...57: try number()
    case 116: try literal("true")
    case 102: try literal("false")
    case 110: try literal("null")
    default: throw parseError()
    }
    return ConfigJSONNode(kind: .scalar, start: start, end: index, members: [], arrayElements: [])
  }
  mutating func object(start: Int, depth: Int) throws -> ConfigJSONNode {
    index += 1; var members: [ConfigJSONMember] = []; var keys = Set<String>(); try skip()
    if consume(125) { return ConfigJSONNode(kind: .object, start: start, end: index, members: members, arrayElements: []) }
    while true {
      try skip(); let keyStart = index
      guard index < bytes.count, bytes[index] == 34 else { throw parseError() }
      let key = try string()
      guard keys.insert(key).inserted else { throw configError("invalid_configuration", "duplicate JSON key") }
      try skip(); guard consume(58) else { throw parseError() }
      let node = try value(depth: depth + 1); try skip()
      if consume(125) {
        members.append(ConfigJSONMember(key: key, keyStart: keyStart, value: node, commaAfter: nil))
        return ConfigJSONNode(kind: .object, start: start, end: index, members: members, arrayElements: [])
      }
      let comma = index
      guard consume(44) else { throw parseError() }
      members.append(ConfigJSONMember(key: key, keyStart: keyStart, value: node, commaAfter: comma))
      try skip()
      if consume(125) { return ConfigJSONNode(kind: .object, start: start, end: index, members: members, arrayElements: []) }
    }
  }
  mutating func array(start: Int, depth: Int) throws -> ConfigJSONNode {
    index += 1; var elements: [ConfigJSONArrayElement] = []; try skip()
    if consume(93) { return ConfigJSONNode(kind: .array, start: start, end: index, members: [], arrayElements: elements) }
    while true {
      let element = try value(depth: depth + 1); try skip()
      if consume(93) {
        elements.append(ConfigJSONArrayElement(value: element, commaAfter: nil))
        return ConfigJSONNode(kind: .array, start: start, end: index, members: [], arrayElements: elements)
      }
      let comma = index
      guard consume(44) else { throw parseError() }
      elements.append(ConfigJSONArrayElement(value: element, commaAfter: comma)); try skip()
      if consume(93) { return ConfigJSONNode(kind: .array, start: start, end: index, members: [], arrayElements: elements) }
    }
  }
  mutating func string() throws -> String {
    let start = index; index += 1; var escaped = false
    while index < bytes.count {
      let byte = bytes[index]; index += 1
      if escaped { escaped = false; continue }
      if byte == 92 { escaped = true; continue }
      if byte == 34 {
        guard let value = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String else { throw parseError() }
        return value
      }
      if byte < 32 { throw parseError() }
    }
    throw parseError()
  }
  mutating func number() throws {
    let start = index
    _ = consume(45)
    guard index < bytes.count else { throw parseError() }
    if consume(48) {
      guard index == bytes.count || !isDigit(bytes[index]) else { throw parseError() }
    } else {
      guard bytes[index] >= 49, bytes[index] <= 57 else { throw parseError() }
      digits()
    }
    if consume(46) { guard index < bytes.count, isDigit(bytes[index]) else { throw parseError() }; digits() }
    if consume(101) || consume(69) {
      if !consume(43) { _ = consume(45) }
      guard index < bytes.count, isDigit(bytes[index]) else { throw parseError() }; digits()
    }
    guard (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) != nil else { throw parseError() }
  }
  mutating func digits() { while index < bytes.count, isDigit(bytes[index]) { index += 1 } }
  func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
  mutating func literal(_ text: String) throws {
    let end = index + text.utf8.count
    guard end <= bytes.count, Array(bytes[index..<end]) == Array(text.utf8) else { throw parseError() }
    index = end
  }
  mutating func skip() throws {
    while index < bytes.count {
      switch bytes[index] {
      case 32, 9, 10, 13: index += 1
      case 47 where index + 1 < bytes.count && bytes[index + 1] == 47:
        index += 2; while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
      case 47 where index + 1 < bytes.count && bytes[index + 1] == 42:
        index += 2
        while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
        guard index + 1 < bytes.count else { throw parseError() }; index += 2
      default: return
      }
    }
  }
  mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
  }
  func parseError() -> ClientConfigError { configError("invalid_configuration", "invalid JSONC configuration syntax") }
}
