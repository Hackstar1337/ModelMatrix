import Foundation

/// Model settings read from the start of a GGUF file. Only the key/value
/// header is parsed; tensor data is never touched.
public struct GGUFMetadata: Sendable, Equatable {
  public var version: Int = 0
  public var architecture: String?
  public var name: String?
  public var numbers: [String: Double] = [:]
  public var numberArrays: [String: [Double]] = [:]

  func number(_ key: String) -> Double? { numbers[key] }
  func archNumber(_ suffix: String) -> Double? {
    guard let architecture else { return nil }
    return numbers["\(architecture).\(suffix)"]
  }
  func archArray(_ suffix: String) -> [Double]? {
    guard let architecture else { return nil }
    return numberArrays["\(architecture).\(suffix)"]
  }
}

public enum GGUFHeaderError: Error, Equatable, Sendable {
  /// Not a GGUF file, or a version this reader does not know.
  case notGGUF
  /// The bytes ran out before the settings were complete. Read more.
  case truncated
  /// A length or count is implausible: the file is damaged or hostile.
  case malformed(String)
}

/// Parses GGUF v2/v3 headers from a prefix of the file.
public enum GGUFHeaderParser {
  static let maxKeyBytes = 65_536
  static let maxStringBytes = 64 * 1024 * 1024
  static let maxArrayCount: UInt64 = 50_000_000
  static let maxKeyValues: UInt64 = 1_000_000
  static let maxKeptArray = 4096

  public static func parse(_ data: Data) throws -> GGUFMetadata {
    var reader = Reader(bytes: [UInt8](data))
    guard reader.remaining >= 4 else { throw GGUFHeaderError.truncated }
    guard try reader.bytes(4) == Array("GGUF".utf8) else { throw GGUFHeaderError.notGGUF }
    let version = try reader.u32()
    guard version == 2 || version == 3 else { throw GGUFHeaderError.notGGUF }
    _ = try reader.u64()  // tensor count
    let count = try reader.u64()
    guard count <= maxKeyValues else { throw GGUFHeaderError.malformed("too many settings") }
    var meta = GGUFMetadata()
    meta.version = Int(version)
    for _ in 0..<count {
      let key = try reader.string(limit: maxKeyBytes)
      let type = try reader.u32()
      // Everything the memory estimate needs comes before the tokenizer.
      if key.hasPrefix("tokenizer."), meta.architecture != nil,
        meta.archNumber("block_count") != nil
      {
        return meta
      }
      if type == 8 {
        let value = try reader.string(limit: maxStringBytes)
        if key == "general.architecture" { meta.architecture = value }
        if key == "general.name" { meta.name = String(value.prefix(200)) }
      } else if type == 9 {
        let elementType = try reader.u32()
        let elements = try reader.u64()
        guard elements <= maxArrayCount else { throw GGUFHeaderError.malformed("array too long") }
        if elementType != 8, elementType != 9, elements <= UInt64(maxKeptArray) {
          var values: [Double] = []
          values.reserveCapacity(Int(elements))
          for _ in 0..<elements { values.append(try reader.number(type: elementType)) }
          meta.numberArrays[key] = values
        } else {
          try reader.skipArray(elementType: elementType, count: elements)
        }
      } else {
        meta.numbers[key] = try reader.number(type: type)
      }
    }
    return meta
  }

  struct Reader {
    let bytes: [UInt8]
    var offset = 0
    var remaining: Int { bytes.count - offset }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
      guard count >= 0, remaining >= count else { throw GGUFHeaderError.truncated }
      defer { offset += count }
      return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: UInt64) throws {
      guard count <= UInt64(remaining) else { throw GGUFHeaderError.truncated }
      offset += Int(count)
    }

    mutating func little<T: FixedWidthInteger>(_: T.Type) throws -> T {
      let size = MemoryLayout<T>.size
      guard remaining >= size else { throw GGUFHeaderError.truncated }
      var value: T = 0
      for index in 0..<size { value |= T(bytes[offset + index]) << (8 * index) }
      offset += size
      return value
    }

    mutating func u32() throws -> UInt32 { try little(UInt32.self) }
    mutating func u64() throws -> UInt64 { try little(UInt64.self) }

    mutating func string(limit: Int) throws -> String {
      let length = try u64()
      guard length <= UInt64(limit) else { throw GGUFHeaderError.malformed("text too long") }
      return String(decoding: try bytes(Int(length)), as: UTF8.self)
    }

    static func width(of type: UInt32) -> Int? {
      switch type {
      case 0, 1, 7: return 1
      case 2, 3: return 2
      case 4, 5, 6: return 4
      case 10, 11, 12: return 8
      default: return nil
      }
    }

    mutating func number(type: UInt32) throws -> Double {
      switch type {
      case 0: return Double(try little(UInt8.self))
      case 1: return Double(Int8(bitPattern: try little(UInt8.self)))
      case 2: return Double(try little(UInt16.self))
      case 3: return Double(Int16(bitPattern: try little(UInt16.self)))
      case 4: return Double(try u32())
      case 5: return Double(Int32(bitPattern: try u32()))
      case 6: return Double(Float(bitPattern: try u32()))
      case 7: return try little(UInt8.self) == 0 ? 0 : 1
      case 10: return Double(try u64())
      case 11: return Double(Int64(bitPattern: try u64()))
      case 12: return Double(bitPattern: try u64())
      default: throw GGUFHeaderError.malformed("unknown value type \(type)")
      }
    }

    mutating func skipArray(elementType: UInt32, count: UInt64) throws {
      if let width = Self.width(of: elementType) {
        let (total, overflow) = count.multipliedReportingOverflow(by: UInt64(width))
        guard !overflow else { throw GGUFHeaderError.malformed("array too large") }
        try skip(total)
        return
      }
      guard elementType == 8 else { throw GGUFHeaderError.malformed("nested arrays are not supported") }
      for _ in 0..<count {
        let length = try u64()
        guard length <= UInt64(GGUFHeaderParser.maxStringBytes) else {
          throw GGUFHeaderError.malformed("text too long")
        }
        try skip(length)
      }
    }
  }
}
