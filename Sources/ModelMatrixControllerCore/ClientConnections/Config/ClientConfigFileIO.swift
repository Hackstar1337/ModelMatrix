import Foundation
import CryptoKit
import Darwin

// Normalize only the two macOS system aliases. Never resolve user symlinks (including
// symlinks hidden by a subsequent '..'). All other components are inspected explicitly.
internal func canonicalURL(_ url: URL) -> URL {
  let path = url.path
  for (alias, destination) in [("/tmp", "/private/tmp"), ("/var", "/private/var")] {
    if path == alias || path.hasPrefix(alias + "/") {
      var info = Darwin.stat()
      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias)
      if lstat(alias, &info) == 0, info.st_mode & S_IFMT == S_IFLNK, info.st_uid == 0,
         target == destination || target == String(destination.dropFirst()) {
        return URL(fileURLWithPath: destination + path.dropFirst(alias.count))
      }
    }
  }
  return URL(fileURLWithPath: path)
}

internal func configError(_ code: String, _ message: String, status: Int = 409) -> ClientConfigError {
  ClientConfigError(status: status, code: code, message: message)
}
internal func configHash(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
internal struct ConfigFileIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
  init(_ info: Darwin.stat) { device = UInt64(info.st_dev); inode = UInt64(info.st_ino) }
}
internal struct ConfigFileSnapshot: Equatable {
  let bytes: Data
  let identity: ConfigFileIdentity
  let mode: UInt16
}

internal enum ConfigFileIO {
  static let maximumBytes = 5_000_000

  static func components(_ url: URL) throws -> [String] {
    let path = url.path
    let parts = path.split(separator: "/").map(String.init)
    guard url.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
          !parts.contains("."), !parts.contains(".."), !parts.isEmpty else {
      throw configError("unsafe_path", "configuration path must be an absolute, non-traversing file path")
    }
    return parts
  }

  // Every directory is opened relative to its already-pinned parent with O_NOFOLLOW.
  // Root-owned sticky /private/tmp is permitted; user-owned writable-by-others dirs are not.
  static func parent(_ path: URL, create: Bool) throws -> Int32? {
    let parts = try components(path)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw configError("unsafe_path", "cannot inspect configuration ancestors") }
    do {
      for name in parts.dropLast() {
        var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if next < 0, errno == ENOENT, create {
          guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
            throw configError("write_failed", "cannot create private configuration directory", status: 500)
          }
          next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        if next < 0 {
          if errno == ENOENT, !create { close(fd); return nil }
          throw configError("unsafe_path", "symlink or inaccessible configuration ancestor")
        }
        var info = Darwin.stat()
        guard fstat(next, &info) == 0 else { close(next); throw configError("unsafe_path", "cannot inspect configuration directory") }
        let stickySystem = info.st_uid == 0 && info.st_mode & S_ISVTX != 0
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0 || stickySystem else {
          close(next); throw configError("unsafe_path", "configuration ancestor is not safely owned")
        }
        close(fd); fd = next
      }
      return fd
    } catch { close(fd); throw error }
  }

  static func validateFile(_ info: Darwin.stat, privateFile: Bool = true) throws {
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
          info.st_uid == getuid() || (!privateFile && info.st_uid == 0),
          info.st_mode & (privateFile ? 0o077 : 0o022) == 0 else {
      throw configError("unsafe_path", "configuration file must be a safely owned regular, non-linked file with protected permissions")
    }
  }

  static func read(_ path: URL) throws -> ConfigFileSnapshot? {
    guard let fd = try parent(path, create: false) else { return nil }
    defer { close(fd) }
    return try read(path.lastPathComponent, parentFD: fd)
  }

  static func read(_ name: String, parentFD: Int32) throws -> ConfigFileSnapshot? {
    let fd = openat(parentFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw configError("unsafe_path", "cannot safely open configuration file")
    }
    defer { close(fd) }
    var before = Darwin.stat()
    guard fstat(fd, &before) == 0 else { throw configError("unsafe_path", "cannot inspect configuration file") }
    try validateFile(before)
    guard before.st_size >= 0, before.st_size <= maximumBytes else {
      throw configError("invalid_configuration", "configuration file is too large")
    }
    let bytes = try readAll(fd, maximum: maximumBytes)
    var after = Darwin.stat()
    guard fstat(fd, &after) == 0, unchanged(before, after) else {
      throw configError("stale_approval", "configuration changed during disk read")
    }
    // Confirm the bytes and inode came from the named file, not a replaced open descriptor.
    var named = Darwin.stat()
    guard fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0, unchanged(after, named) else {
      throw configError("stale_approval", "configuration identity changed during disk read")
    }
    return ConfigFileSnapshot(bytes: bytes, identity: ConfigFileIdentity(after), mode: UInt16(after.st_mode & 0o777))
  }

  static func unchanged(_ a: Darwin.stat, _ b: Darwin.stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid &&
    a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }

  static func readAll(_ fd: Int32, maximum: Int) throws -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count == 0 { return data }
      if count < 0 {
        if errno == EINTR { continue }
        throw configError("unsafe_path", "cannot read configuration file")
      }
      guard data.count + count <= maximum else { throw configError("invalid_configuration", "configuration file is too large") }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  // Read only non-secret installation metadata. Configuration reads always use read above.
  static func installationMetadata(_ path: URL) throws -> Data? {
    guard let parentFD = try parent(path, create: false) else { return nil }
    defer { close(parentFD) }
    let fd = openat(parentFD, path.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 { if errno == ENOENT { return nil }; throw configError("unsafe_path", "unsafe client installation metadata") }
    defer { close(fd) }
    var info = Darwin.stat()
    guard fstat(fd, &info) == 0 else { throw configError("unsafe_path", "cannot inspect client installation") }
    try validateFile(info, privateFile: false)
    guard info.st_size <= 1_000_000 else { return nil }
    return try readAll(fd, maximum: 1_000_000)
  }

  static func validateExecutable(_ path: URL) throws -> Bool {
    guard let parentFD = try parent(path, create: false) else { return false }
    defer { close(parentFD) }
    var info = Darwin.stat()
    guard fstatat(parentFD, path.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
    try validateFile(info, privateFile: false)
    return info.st_mode & 0o111 != 0
  }

  static func withLock<T>(_ path: URL, body: (Int32) throws -> T) throws -> T {
    guard let parentFD = try parent(path, create: true) else { throw configError("unsafe_path", "configuration parent is missing") }
    defer { close(parentFD) }
    let name = ".modelmatrix-config.lock"
    let fd = openat(parentFD, name, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw configError("busy", "cannot safely open configuration lock", status: 423) }
    defer { close(fd) }
    var info = Darwin.stat()
    guard fstat(fd, &info) == 0 else { throw configError("unsafe_path", "cannot inspect configuration lock") }
    try validateFile(info)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, ProcessInfo.processInfo.systemUptime < deadline else {
        throw configError("busy", "configuration is locked; try again", status: 423)
      }
      usleep(10_000)
    }
    defer { _ = flock(fd, LOCK_UN) }
    var named = Darwin.stat()
    guard fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
          ConfigFileIdentity(named) == ConfigFileIdentity(info) else {
      throw configError("busy", "configuration lock identity changed", status: 423)
    }
    return try body(parentFD)
  }

  static func verifyParent(_ path: URL, pinned: Int32) throws {
    guard let fresh = try parent(path, create: false) else { throw configError("stale_approval", "configuration directory changed") }
    defer { close(fresh) }
    var a = Darwin.stat(), b = Darwin.stat()
    guard fstat(pinned, &a) == 0, fstat(fresh, &b) == 0, ConfigFileIdentity(a) == ConfigFileIdentity(b) else {
      throw configError("stale_approval", "configuration directory identity changed")
    }
  }

  static func writeAll(_ bytes: Data, fd: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw configError("write_failed", "cannot write protected configuration", status: 500) }
        offset += count
      }
    }
  }

  static func replace(_ bytes: Data, path: URL, parentFD: Int32, expected: ConfigFileSnapshot?) throws {
    let temporary = ".modelmatrix-\(UUID().uuidString).tmp"
    let fd = openat(parentFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw configError("write_failed", "cannot create protected temporary configuration", status: 500) }
    defer { close(fd); _ = unlinkat(parentFD, temporary, 0) }
    try writeAll(bytes, fd: fd)
    guard fchmod(fd, mode_t(expected?.mode ?? 0o600)) == 0, fsync(fd) == 0 else {
      throw configError("write_failed", "cannot synchronize configuration", status: 500)
    }
    try verifyParent(path, pinned: parentFD)
    guard try read(path.lastPathComponent, parentFD: parentFD) == expected else {
      throw configError("stale_approval", "configuration changed before atomic replacement")
    }
    guard renameat(parentFD, temporary, parentFD, path.lastPathComponent) == 0, fsync(parentFD) == 0 else {
      throw configError("write_failed", "cannot atomically replace and synchronize configuration", status: 500)
    }
    try verifyParent(path, pinned: parentFD)
  }

  static func backup(_ bytes: Data?, path: URL, directory: URL?, operationID: String) throws -> URL? {
    guard let bytes else { return nil }
    let root = canonicalURL(directory ?? path.deletingLastPathComponent().appendingPathComponent(".modelmatrix-config-backups", isDirectory: true))
    let result = root.appendingPathComponent("\(path.lastPathComponent).\(operationID).\(UUID().uuidString).bak")
    guard let parentFD = try parent(result, create: true) else { throw configError("write_failed", "cannot create backup directory", status: 500) }
    defer { close(parentFD) }
    var info = Darwin.stat()
    guard fstat(parentFD, &info) == 0, info.st_uid == getuid(), fchmod(parentFD, 0o700) == 0 else {
      throw configError("unsafe_path", "backup directory is not privately owned")
    }
    let fd = openat(parentFD, result.lastPathComponent, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw configError("write_failed", "cannot create protected backup", status: 500) }
    defer { close(fd) }
    try writeAll(bytes, fd: fd)
    guard fsync(fd) == 0, fsync(parentFD) == 0 else { throw configError("write_failed", "cannot synchronize backup", status: 500) }
    return result
  }
}
