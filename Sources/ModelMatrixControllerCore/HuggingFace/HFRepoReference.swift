import Foundation

/// A Hugging Face model repository picked out of whatever the user typed:
/// `owner/name`, `owner/name:Q4_K_M`, `hf.co/owner/name:Q4_K_M`, or a
/// huggingface.co link (optionally pointing at a branch or a single file).
public struct HFRepoReference: Sendable, Equatable {
  public let owner: String
  public let name: String
  /// Branch, tag or commit from a `/tree/<rev>` or `/blob/<rev>/...` link.
  public var revision: String?
  /// Version label after a colon, such as `Q4_K_M`.
  public var variant: String?
  /// A single file from a `/blob/` or `/resolve/` link.
  public var file: String?

  public var id: String { "\(owner)/\(name)" }

  public init(
    owner: String, name: String, revision: String? = nil, variant: String? = nil,
    file: String? = nil
  ) {
    self.owner = owner
    self.name = name
    self.revision = revision
    self.variant = variant
    self.file = file
  }
}

/// What the user typed: a repository, or free text to search for.
public enum HFQuery: Sendable, Equatable {
  case repo(HFRepoReference)
  case search(String)
}

extension HFQuery {
  static let maximumInputLength = 300
  static let defaultHosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

  /// Parses user input. Rejects anything that is not clearly a model name,
  /// a model link or a short search text. `extraHost` is a configured mirror.
  public static func parse(_ raw: String, extraHost: String? = nil) throws -> HFQuery {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw HFError.invalidName("Enter a Hugging Face model name, for example bartowski/Qwen2.5-7B-Instruct-GGUF.") }
    guard text.count <= maximumInputLength else { throw HFError.invalidName("That name is too long.") }
    guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw HFError.invalidName("The name contains control characters.")
    }
    var hosts = defaultHosts
    if let extraHost = extraHost?.lowercased(), !extraHost.isEmpty { hosts.insert(extraHost) }

    if text.contains("://") {
      guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http", let host = url.host?.lowercased(),
        hosts.contains(host)
      else {
        throw HFError.invalidName("Only huggingface.co model links are accepted.")
      }
      return .repo(try fromPath(url.path))
    }
    let lowered = text.lowercased()
    for host in hosts where lowered.hasPrefix(host + "/") {
      return .repo(try fromPath(String(text.dropFirst(host.count + 1))))
    }
    if !text.contains("/") {
      guard text.count <= 100, text.unicodeScalars.allSatisfy(isSearchCharacter) else {
        throw HFError.invalidName("Search text may only use letters, digits, spaces and . _ - +")
      }
      return .search(text)
    }
    guard !text.contains(" ") else {
      throw HFError.invalidName("A model name looks like owner/name and has no spaces.")
    }
    return .repo(try fromPath(text))
  }

  private static func isSearchCharacter(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || " ._-+".unicodeScalars.contains(scalar)
  }

  /// `owner/name[:variant]` optionally followed by `/tree/<rev>`,
  /// `/blob/<rev>/<file>` or `/resolve/<rev>/<file>`.
  static func fromPath(_ path: String) throws -> HFRepoReference {
    var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if let first = parts.first?.lowercased(), ["datasets", "spaces"].contains(first) {
      throw HFError.invalidName("That link is a Hugging Face \(first == "datasets" ? "dataset" : "Space"), not a model.")
    }
    if parts.first?.lowercased() == "models" { parts.removeFirst() }
    guard parts.count >= 2 else {
      throw HFError.invalidName("A model name looks like owner/name.")
    }
    let owner = parts[0]
    var name = parts[1]
    var variant: String?
    if let colon = name.firstIndex(of: ":") {
      variant = String(name[name.index(after: colon)...])
      name = String(name[..<colon])
    }
    if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    try validateComponent(owner, what: "owner")
    try validateComponent(name, what: "model name")
    if let label = variant {
      guard label.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
        throw HFError.invalidName("The version after ':' may only use letters, digits and . _ -")
      }
    }
    var reference = HFRepoReference(owner: owner, name: name, variant: variant)
    let rest = Array(parts.dropFirst(2))
    if let kind = rest.first {
      guard ["tree", "blob", "resolve"].contains(kind), rest.count >= 2 else {
        throw HFError.invalidName("That link does not point at a model.")
      }
      let revision = rest[1].removingPercentEncoding ?? rest[1]
      try validateRevision(revision)
      reference.revision = revision
      if kind != "tree" {
        guard rest.count >= 3 else { throw HFError.invalidName("That link does not name a file.") }
        let file = rest.dropFirst(2).map { $0.removingPercentEncoding ?? $0 }.joined(separator: "/")
        try validateFilePath(file)
        reference.file = file
      }
    }
    return reference
  }

  static func validateComponent(_ value: String, what: String) throws {
    let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil, !value.contains(".."),
      !value.hasSuffix(".")
    else {
      throw HFError.invalidName("The \(what) '\(value)' is not a valid Hugging Face name.")
    }
  }

  static func validateRevision(_ value: String) throws {
    guard value.range(of: #"^[A-Za-z0-9._/-]{1,128}$"#, options: .regularExpression) != nil,
      !value.contains(".."), !value.hasPrefix("/"), !value.hasSuffix("/")
    else {
      throw HFError.invalidName("The branch or commit '\(value)' is not valid.")
    }
  }

  static func validateFilePath(_ value: String) throws {
    let segments = value.split(separator: "/", omittingEmptySubsequences: false)
    guard value.count <= 512, !segments.isEmpty,
      segments.allSatisfy({ segment in
        !segment.isEmpty && segment != "." && segment != ".."
          && segment.range(of: #"^[A-Za-z0-9._+=@ ()\[\]-]+$"#, options: .regularExpression) != nil
      })
    else {
      throw HFError.invalidName("The file path in that link is not valid.")
    }
  }
}
