import Foundation
import Darwin
import Testing
@testable import ModelMatrixControllerCore

private struct ClientConfigFixture {
  let root: URL
  let config: URL
  var keyFile: String { root.appendingPathComponent("fake-key.txt").path }
  init(_ body: String? = nil, target: String = "kilo") throws {
    root = canonicalURL(FileManager.default.temporaryDirectory).appendingPathComponent("modelmatrix-config-tests-\(UUID().uuidString)", isDirectory: true)
    config = root.appendingPathComponent(target == "kilo" ? "kilo.jsonc" : "opencode.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if let body { try write(body) }
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
  func write(_ body: String) throws {
    try body.write(to: config, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
  }
  func manager(target: String = "kilo", version: String? = nil) -> ClientConfigManager {
    ClientConfigManager(home: root, qualifiedOverrides: [target: config],
      versionOverrides: [target: version ?? (target == "kilo" ? "7.8.12" : "1.16.2")])
  }
  func prepare(_ manager: ClientConfigManager, target: String = "kilo", makeDefault: Bool = false, context: Int? = nil) throws -> ClientConfigPreview {
    try manager.prepare(target: target, providerID: "mmx-test", modelKey: "local-alias", modelID: "exact-wire-id",
      baseURL: "http://127.0.0.1:17701/v1", keyFile: keyFile, context: context, makeDefault: makeDefault)
  }
  func bytes() throws -> Data { try Data(contentsOf: config) }
  func document() throws -> ConfigJSONDocument { try ConfigJSONDocument(data: bytes()) }
}

@Test func clientConfigParsesOrdinaryJSONFragmentsAndEscapedKeys() throws {
  let fixture = try ClientConfigFixture("{\"quoted\\\"key\":true,\"array\":[1,2,],\"n\":-1.25e+2,\"model\":\"keep/model\"}")
  defer { fixture.cleanup() }
  let document = try fixture.document()
  #expect(document.root.member("quoted\"key") != nil)
  #expect(document.rootDefault == "keep/model")
  let manager = fixture.manager()
  let receipt = try manager.apply(fixture.prepare(manager), operationID: "fragments")
  #expect(try manager.readBack(receipt))
  #expect(try fixture.document().rootDefault == "keep/model")
}

@Test(arguments: ["{\"n\":1.}", "{\"n\":1e}", "{\"n\":1e+}", "{\"n\":01}", "{\"n\":-}", "{\"n\":.1}", "{} /* unfinished", "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"a\":\"\\x\"}", "[1]", "{\"a\":[1,,2]}"])
func clientConfigRejectsInvalidJSONCWithoutWriting(_ body: String) throws {
  let fixture = try ClientConfigFixture(body)
  defer { fixture.cleanup() }
  let before = try fixture.bytes()
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
  #expect(try fixture.bytes() == before)
}

@Test func clientConfigRejectsDepthAndFileSizeBounds() throws {
  let deep = "{\"a\":" + String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130) + "}"
  let fixture = try ClientConfigFixture(deep)
  defer { fixture.cleanup() }
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
  try fixture.write("{\"padding\":\"" + String(repeating: "a", count: 5_000_000) + "\"}")
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
}

@Test func clientConfigPreservesJSONCAndCreatesProtectedBackup() throws {
  let original = """
  {
    // Keep this comment and unrelated provider byte-for-byte.
    "provider": { "keep": { "npm": "other" }, /* keep provider tail */ },
    "permission": { "shell": "ask" }, // keep root tail
  }
  """
  let fixture = try ClientConfigFixture(original)
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let receipt = try manager.apply(fixture.prepare(manager, makeDefault: true, context: 32768), operationID: "protected-backup")
  let output = String(decoding: try fixture.bytes(), as: UTF8.self)
  #expect(output.contains("Keep this comment"))
  #expect(output.contains("\"permission\": { \"shell\": \"ask\" }"))
  #expect(output.contains("/* keep provider tail */"))
  #expect(output.contains("// keep root tail"))
  #expect(try fixture.document().root.members.filter { $0.key == "provider" }.count == 1)
  #expect(try fixture.document().root.members.filter { $0.key == "model" }.count == 1)
  #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.backupPath)) == Data(original.utf8))
  let attributes = try FileManager.default.attributesOfItem(atPath: receipt.backupPath)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let directory = URL(fileURLWithPath: receipt.backupPath).deletingLastPathComponent()
  #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  #expect(try manager.readBack(receipt))
}

@Test(arguments: ["{}", "{ /* empty comments */ }", "{\"unrelated\":true}", "{\"model\":\"keep/model\"}", "{\"provider\":{}}", "{\"provider\":{\"keep\":{}},\"model\":\"keep/model\"}", "{\"provider\":{\"keep\":{},},\"model\":\"keep/model\",}"])
func clientConfigAccumulatesRootInsertionsAndRestoresDefaults(_ original: String) throws {
  for useUndo in [true, false] {
    let fixture = try ClientConfigFixture(original)
    defer { fixture.cleanup() }
    let before = try fixture.document(), manager = fixture.manager()
    let receipt = try manager.apply(fixture.prepare(manager, makeDefault: true), operationID: "root-patch")
    let document = try fixture.document()
    #expect(document.root.members.filter { $0.key == "provider" }.count == 1)
    #expect(document.root.members.filter { $0.key == "model" }.count == 1)
    #expect(document.rootDefault == "mmx-test/local-alias")
    if useUndo { try manager.undo(receipt) } else { try manager.remove(receipt) }
    let restored = try fixture.document()
    #expect(restored.rootDefault == before.rootDefault)
    #expect(try restored.providerContainer()?.member("mmx-test") == nil)
    if original.contains("keep") { #expect(try restored.providerContainer()?.member("keep") != nil || restored.rootDefault == "keep/model") }
    #expect(try manager.readBack(receipt) == false)
  }
}

@Test func clientConfigExplicitDefaultApprovalShowsOldToNew() throws {
  let fixture = try ClientConfigFixture("{\"model\":\"another-provider/model\"}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let preview = try fixture.prepare(manager, makeDefault: true)
  #expect(preview.changes.contains { $0.contains("another-provider/model → mmx-test/local-alias") })
  let receipt = try manager.apply(preview, operationID: "default-approval")
  #expect(receipt.priorDefault == "another-provider/model")
  try manager.remove(receipt)
  #expect(try fixture.document().rootDefault == "another-provider/model")
}

@Test func clientConfigDefaultOffAndUserChangedDefaultArePreserved() throws {
  let fixture = try ClientConfigFixture("{\"model\":\"keep/model\",\"provider\":{\"keep\":{}}}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let receipt = try manager.apply(fixture.prepare(manager), operationID: "no-default")
  #expect(try fixture.document().rootDefault == "keep/model")
  try manager.undo(receipt)
  #expect(try fixture.document().rootDefault == "keep/model")
  let next = try manager.apply(fixture.prepare(manager, makeDefault: true), operationID: "default")
  let document = try fixture.document(), rootModel = try #require(document.root.member("model"))
  var edit = ConfigJSONPatch()
  edit.set(rootModel.value.start..<rootModel.value.end, configJSONString("new-user/model"))
  try fixture.write(String(decoding: edit.apply(to: document.data), as: UTF8.self))
  #expect(try manager.readBack(next) == false)
  try manager.remove(next)
  #expect(try fixture.document().rootDefault == "new-user/model")
}

@Test func clientConfigRemovalPreservesCommaAdjacentCommentsAndUnrelatedLaterEdits() throws {
  let fixture = try ClientConfigFixture("{\"provider\":{\"keep\":{} /* before comma */, /* after comma */},\"model\":\"keep/model\"}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let receipt = try manager.apply(fixture.prepare(manager, makeDefault: true), operationID: "comments")
  var output = String(decoding: try fixture.bytes(), as: UTF8.self)
  output.insert(contentsOf: ",\"user_later\": true", at: output.index(before: output.endIndex))
  try fixture.write(output)
  try manager.undo(receipt)
  let restored = String(decoding: try fixture.bytes(), as: UTF8.self)
  #expect(restored.contains("/* before comma */"))
  #expect(restored.contains("/* after comma */"))
  #expect(try fixture.document().root.member("user_later") != nil)
}

@Test(arguments: ["kilo", "opencode"])
func clientConfigBothQualifiedTargetsKeepAliasAndWireMapping(_ target: String) throws {
  let fixture = try ClientConfigFixture("{}", target: target)
  defer { fixture.cleanup() }
  let manager = fixture.manager(target: target)
  let receipt = try manager.apply(fixture.prepare(manager, target: target, context: 4096), operationID: "wire-alias")
  let models = try fixture.document().providerContainer()?.member("mmx-test")?.value.member("models")?.value
  #expect(models?.member("local-alias") != nil)
  #expect(models?.member("exact-wire-id") == nil)
  let data = try fixture.bytes()
  #expect(models?.member("local-alias")?.value.member("id")?.value.stringValue(data) == "exact-wire-id")
  #expect(try manager.readBack(receipt))
}

@Test(arguments: [1, 4096, 32768])
func clientConfigNativeLimitsHaveContextAndCappedPolicyOutput(_ context: Int) throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager(), context: context)
  #expect(preview.notes.contains { $0.contains("POLICY") && $0.contains("NOT a verified model maximum") })
  _ = try manager.apply(preview, operationID: "limits")
  let limit = try fixture.document().providerContainer()?.member("mmx-test")?.value.member("models")?.value.member("local-alias")?.value.member("limit")?.value
  #expect(limit?.hasKeys(["context", "output"]) == true)
  #expect(limit?.member("context")?.value.intValue(try fixture.bytes()) == context)
  #expect(limit?.member("output")?.value.intValue(try fixture.bytes()) == min(8192, context))
}

@Test func clientConfigUnknownContextOmitsLimit() throws {
  let fixture = try ClientConfigFixture()
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  _ = try manager.apply(fixture.prepare(manager), operationID: "unknown-context")
  #expect(try fixture.document().providerContainer()?.member("mmx-test")?.value.member("models")?.value.member("local-alias")?.value.member("limit") == nil)
  #expect((try FileManager.default.attributesOfItem(atPath: fixture.config.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func clientConfigCodableAndFingerprintNeverIncludeRawConfigOrKeys() throws {
  let fixture = try ClientConfigFixture("{\"existing_secret\":\"SYNTHETIC_SENTINEL_NEVER_EXPORT\"}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  let encoded = try JSONEncoder().encode(preview), text = String(decoding: encoded, as: UTF8.self)
  #expect(!text.contains("SYNTHETIC_SENTINEL"))
  #expect(!text.contains("fake-key.txt"))
  #expect(!text.contains("approvalFingerprint"))
  #expect(preview.approvalFingerprint.count == 64)
  #expect(preview.approvalFingerprint == (try fixture.prepare(manager)).approvalFingerprint)
  let decoded = try JSONDecoder().decode(ClientConfigPreview.self, from: encoded)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(decoded, operationID: "decoded") }
  try fixture.write("{\"existing_secret\":\"CHANGED_SYNTHETIC_VALUE\"}")
  #expect(preview.approvalFingerprint != (try fixture.prepare(manager)).approvalFingerprint)
}

@Test func clientConfigRejectsSameBytesReplacementInodeAndModeChanges() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  try fixture.write("{}") // atomic replacement with identical content, different inode
  #expect(preview.approvalFingerprint != (try fixture.prepare(manager)).approvalFingerprint)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(preview, operationID: "stale-inode") }
  let fresh = try fixture.prepare(manager)
  try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.config.path)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(fresh, operationID: "stale-mode") }
}

@Test func clientConfigApplyRechecksVersionAndLoaderLastPath() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let old = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  #expect(throws: ClientConfigError.self) { _ = try fixture.manager(version: "7.8.13").apply(preview, operationID: "version-changed") }
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager(version: "7.8.13")) }
  let receipt = try old.apply(preview, operationID: "original")
  #expect(try old.readBack(receipt))
}

@Test func clientConfigReadBackReadsActualDiskAndRefusesOverlappingUserChanges() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), receipt = try manager.apply(fixture.prepare(fixture.manager()), operationID: "read-disk")
  let encoded = try JSONEncoder().encode(receipt)
  let recovered = try JSONDecoder().decode(ClientConfigReceipt.self, from: encoded)
  #expect(try manager.readBack(recovered))
  try fixture.write(String(decoding: try fixture.bytes(), as: UTF8.self).replacingOccurrences(of: "exact-wire-id", with: "user-retargeted"))
  #expect(try manager.readBack(recovered) == false)
  #expect(throws: ClientConfigError.self) { try manager.undo(recovered) }
}

@Test func clientConfigExistingNamespaceIsIdempotentOnlyWhenExact() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  _ = try manager.apply(fixture.prepare(manager), operationID: "first")
  let next = try fixture.prepare(manager)
  _ = try manager.apply(next, operationID: "same")
  #expect(try fixture.document().providerContainer()?.members.count == 1)
  try fixture.write(String(decoding: try fixture.bytes(), as: UTF8.self).replacingOccurrences(of: "exact-wire-id", with: "other-model"))
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(manager) }
}

@Test func clientConfigRejectsFileAncestorSymlinksHardlinksAndLoosePermissions() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let linked = fixture.root.appendingPathComponent("linked.jsonc")
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.config)
  let symlinkManager = ClientConfigManager(home: fixture.root, qualifiedOverrides: ["kilo": linked], versionOverrides: ["kilo": "7.8.12"])
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(symlinkManager) }
  let alias = fixture.root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
  let ancestorManager = ClientConfigManager(home: alias, qualifiedOverrides: ["kilo": alias.appendingPathComponent("kilo.jsonc")], versionOverrides: ["kilo": "7.8.12"])
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(ancestorManager) }
  let hardlink = fixture.root.appendingPathComponent("hardlink.jsonc")
  #expect(Darwin.link(fixture.config.path, hardlink.path) == 0)
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
  try FileManager.default.removeItem(at: hardlink)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.config.path)
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
}

@Test func clientConfigRejectsFIFOAndSymlinkLockWithoutBlocking() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  let lock = fixture.root.appendingPathComponent(".modelmatrix-config.lock")
  try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: fixture.config)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(preview, operationID: "symlink-lock") }
  try FileManager.default.removeItem(at: lock)
  try FileManager.default.removeItem(at: fixture.config)
  #expect(mkfifo(fixture.config.path, 0o600) == 0)
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(manager) }
}

@Test func clientConfigHeldFileLockIsBoundedAndNonblocking() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  let fd = open(fixture.root.appendingPathComponent(".modelmatrix-config.lock").path, O_CREAT | O_RDWR, 0o600)
  #expect(fd >= 0)
  defer { _ = flock(fd, LOCK_UN); close(fd) }
  #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
  let start = ProcessInfo.processInfo.systemUptime
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(preview, operationID: "lock-held") }
  #expect(ProcessInfo.processInfo.systemUptime - start < 2)
}

@Test func clientConfigChoosesLoaderLastAndRefusesInvalidCompetingGlobal() throws {
  let fixture = try ClientConfigFixture()
  defer { fixture.cleanup() }
  let directory = fixture.root.appendingPathComponent(".config/kilo")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  for name in ["config.json", "kilo.jsonc", "opencode.jsonc"] {
    let path = directory.appendingPathComponent(name)
    try "{}".write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }
  let manager = ClientConfigManager(home: fixture.root, versionOverrides: ["kilo": "7.8.12"])
  let preview = try fixture.prepare(manager)
  #expect(preview.configPath == directory.appendingPathComponent("opencode.jsonc").path)
  try "{bad".write(to: directory.appendingPathComponent("opencode.jsonc"), atomically: false, encoding: .utf8)
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(manager) }
}

@Test func clientConfigReceiptRejectsPathsOutsideInjectedScope() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let forged = ClientConfigReceipt(configPath: fixture.root.appendingPathComponent("other.json").path,
    target: "kilo", providerID: "mmx-test", modelKey: "local-alias", operationID: "forged", backupPath: "", makeDefault: false, expectedOwnedHash: "bogus", priorDefault: nil)
  #expect(throws: ClientConfigError.self) { _ = try fixture.manager().readBack(forged) }
  #expect(throws: ClientConfigError.self) { try fixture.manager().remove(forged) }
}

private func fakeClientBinary(root: URL, relative: String, script: String) throws -> URL {
  let path = root.appendingPathComponent(relative)
  try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try script.write(to: path, atomically: false, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
  return path
}

@Test func clientConfigOpenCodeVersionUsesActualKnownBinaryAndIsolatedHome() throws {
  let fixture = try ClientConfigFixture()
  defer { fixture.cleanup() }
  let binary = try fakeClientBinary(root: fixture.root, relative: ".opencode/bin/opencode", script: """
  #!/bin/sh
  test "$#" = 1 && test "$1" = --version || exit 3
  test "$HOME" != "\(fixture.root.path)" || exit 4
  test "$PWD" = "$HOME" || exit 5
  test -z "$OPENCODE_CONFIG" || exit 6
  printf '1.16.2\\n'
  """)
  let manager = ClientConfigManager(home: fixture.root)
  let target = try #require(manager.targets().first { $0["id"] as? String == "opencode" })
  #expect(target["version"] as? String == "1.16.2")
  #expect(target["qualified"] as? Bool == true)
  #expect(target["cli_path"] as? String == binary.path)
  #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".config/opencode").path))
}

@Test func clientConfigOpenCodeVersionTimeoutIsShortAndFailClosed() throws {
  let fixture = try ClientConfigFixture()
  defer { fixture.cleanup() }
  _ = try fakeClientBinary(root: fixture.root, relative: ".opencode/bin/opencode", script: "#!/bin/sh\nexec /bin/sleep 10\n")
  let start = ProcessInfo.processInfo.systemUptime
  let target = try #require(ClientConfigManager(home: fixture.root).targets().first { $0["id"] as? String == "opencode" })
  #expect(target["qualified"] as? Bool == false)
  #expect(ProcessInfo.processInfo.systemUptime - start < 5)
}

@Test func clientConfigKiloUsesManifestNotDirectoryNameAndDeclinesAmbiguity() throws {
  let fixture = try ClientConfigFixture()
  defer { fixture.cleanup() }
  let relative = ".vscode/extensions/kilocode.kilo-code-7.8.12-darwin-arm64"
  _ = try fakeClientBinary(root: fixture.root, relative: relative + "/bin/kilo", script: "#!/bin/sh\nexit 0\n")
  let manifest = fixture.root.appendingPathComponent(relative + "/package.json")
  try "{\"version\":\"7.8.13\"}".write(to: manifest, atomically: false, encoding: .utf8)
  let manager = ClientConfigManager(home: fixture.root)
  var target = try #require(manager.targets().first { $0["id"] as? String == "kilo" })
  #expect(target["version"] as? String == "7.8.13")
  #expect(target["qualified"] as? Bool == false)
  try "{\"version\":\"7.8.12\"}".write(to: manifest, atomically: false, encoding: .utf8)
  target = try #require(manager.targets().first { $0["id"] as? String == "kilo" })
  #expect(target["qualified"] as? Bool == true)
  _ = try fakeClientBinary(root: fixture.root, relative: ".vscode/extensions/kilocode.kilo-code-7.8.14-darwin-arm64/bin/kilo", script: "#!/bin/sh\nexit 0\n")
  target = try #require(manager.targets().first { $0["id"] as? String == "kilo" })
  #expect(target["qualified"] as? Bool == false)
}

@Test func clientConfigMacOSSystemAliasesNormalizeButUserTraversalDoesNot() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  #expect(canonicalURL(URL(fileURLWithPath: "/tmp/example.json")).path == "/private/tmp/example.json")
  #expect(canonicalURL(URL(fileURLWithPath: "/var/example.json")).path == "/private/var/example.json")
  let alias = fixture.root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
  let traversal = URL(fileURLWithPath: alias.path + "/../kilo.jsonc")
  let manager = ClientConfigManager(home: fixture.root, qualifiedOverrides: ["kilo": traversal], versionOverrides: ["kilo": "7.8.12"])
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(manager) }
}

@Test func clientConfigSourceLinkSwapAndUnsafeBackupAreRejectedBeforeReplacement() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), preview = try fixture.prepare(fixture.manager())
  let hardlink = fixture.root.appendingPathComponent("hardlink.json")
  #expect(Darwin.link(fixture.config.path, hardlink.path) == 0)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(preview, operationID: "hardlink-swap") }
  try FileManager.default.removeItem(at: hardlink)
  let backup = fixture.root.appendingPathComponent(".modelmatrix-config-backups")
  try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: fixture.root)
  #expect(throws: ClientConfigError.self) { _ = try manager.apply(fixture.prepare(manager), operationID: "backup-link") }
  #expect(try fixture.bytes() == Data("{}".utf8))
}

@Test(arguments: [0, 1, 2])
func clientConfigRemovalHandlesFirstMiddleLastMembersWithoutEatingComments(_ position: Int) throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  let manager = fixture.manager(), receipt = try manager.apply(fixture.prepare(fixture.manager(), makeDefault: true), operationID: "member-position")
  let initial = try fixture.document()
  let provider = try #require(initial.providerContainer()?.member("mmx-test"))
  let providerBytes = String(decoding: initial.data.subdata(in: provider.value.start..<provider.value.end), as: UTF8.self)
  var providers = ["\"before\":{}", "\"after\":{}"]
  providers.insert("\"mmx-test\":\(providerBytes)", at: position)
  var roots = ["\"provider\":{\(providers.joined(separator: ", /* keep separator */ "))}", "\"unrelated\":true"]
  roots.insert("\"model\":\(configJSONString("mmx-test/local-alias"))", at: position)
  try fixture.write("{\(roots.joined(separator: ", /* keep root separator */ ")), /* keep trailing */}")
  #expect(try manager.readBack(receipt))
  try manager.remove(receipt)
  let after = try fixture.document(), bytes = String(decoding: after.data, as: UTF8.self)
  #expect(after.root.member("model") == nil)
  #expect(after.root.member("unrelated") != nil)
  #expect(try after.providerContainer()?.hasKeys(["before", "after"]) == true)
  #expect(bytes.contains("/* keep separator */"))
  #expect(bytes.contains("/* keep root separator */"))
  #expect(bytes.contains("/* keep trailing */"))
}

@Test func clientConfigKeyFileIsAReferenceOnlyAndSubstitutionInWireIDIsRejected() throws {
  let fixture = try ClientConfigFixture("{}")
  defer { fixture.cleanup() }
  // An unreadable/FIFO sentinel would block a credential-content read. prepare must not read it.
  #expect(mkfifo(fixture.keyFile, 0o600) == 0)
  let manager = fixture.manager()
  let preview = try fixture.prepare(manager)
  #expect(!preview.changes.joined().contains("fake-key"))
  #expect(throws: ClientConfigError.self) {
    _ = try manager.prepare(target: "kilo", providerID: "mmx-test", modelKey: "alias", modelID: "{file:/not-allowed}",
      baseURL: "http://127.0.0.1:17701/v1", keyFile: fixture.keyFile, context: nil, makeDefault: false)
  }
  #expect(throws: ClientConfigError.self) {
    _ = try manager.prepare(target: "kilo", providerID: "mmx-test", modelKey: "alias", modelID: "wire",
      baseURL: "http://127.0.0.1:17701/v1", keyFile: "relative-key", context: nil, makeDefault: false)
  }
}

@Test func clientConfigNativeFileReferenceDoesNotEscapeSlashesBeforeExpansion() {
  let reference = configJSONString("{file:/private/tmp/ModelMatrix/key.key}")
  #expect(reference == "\"{file:/private/tmp/ModelMatrix/key.key}\"")
  #expect(!reference.contains("\\/"))
}

@Test func clientConfigEnabledProviderAllowListPreservesMembersCommentsAndDefault() throws {
  let fixture = try ClientConfigFixture("""
  {
    "enabled_providers": ["keep", /* preserve this member comment */ "other"],
    "model": "keep/model"
  }
  """)
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let preview = try fixture.prepare(manager)
  #expect(preview.changes.contains("Add mmx-test to enabled_providers allow-list"))
  let receipt = try manager.apply(preview, operationID: "allow-list-add")
  let output = String(decoding: try fixture.bytes(), as: UTF8.self)
  #expect(output.contains("preserve this member comment"))
  #expect(try fixture.document().rootDefault == "keep/model")
  #expect(try fixture.document().root.member("enabled_providers")?.value.arrayElements.count == 3)
  #expect(try manager.readBack(receipt))
}

@Test func clientConfigEnabledProviderMembershipIsReadBackAndNotDuplicatedOnRepeatConfigure() throws {
  let fixture = try ClientConfigFixture("{\"enabled_providers\":[\"keep\"]}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let first = try manager.apply(fixture.prepare(manager), operationID: "allow-list-first")
  #expect(first.ownedEnabledProviderMembership == true)
  #expect(try manager.readBack(first))
  let second = try manager.apply(fixture.prepare(manager), operationID: "allow-list-second")
  #expect(second.ownedEnabledProviderMembership == true)
  let values = try fixture.document().root.member("enabled_providers")?.value.arrayElements.compactMap { $0.value.stringValue(try fixture.bytes()) }
  #expect(values?.filter { $0 == "mmx-test" }.count == 1)
}

@Test func clientConfigOwnedAllowListCleanupPreservesConcurrentUnrelatedMembers() throws {
  let fixture = try ClientConfigFixture("{\"enabled_providers\":[\"keep\",\"other\"]}")
  defer { fixture.cleanup() }
  let manager = fixture.manager()
  let receipt = try manager.apply(fixture.prepare(manager), operationID: "allow-list-cleanup")
  try manager.remove(receipt)
  let values = try fixture.document().root.member("enabled_providers")?.value.arrayElements.compactMap { $0.value.stringValue(try fixture.bytes()) }
  #expect(values == ["keep", "other"])
}

@Test(arguments: ["kilo", "opencode"])
func clientConfigProviderFilterContractWorksForBothQualifiedTargets(_ target: String) throws {
  let fixture = try ClientConfigFixture("{\"enabled_providers\":[\"keep\"]}", target: target)
  defer { fixture.cleanup() }
  let manager = fixture.manager(target: target)
  let receipt = try manager.apply(fixture.prepare(manager, target: target), operationID: "filter-\(target)")
  #expect(receipt.ownedEnabledProviderMembership == true)
  #expect(try manager.readBack(receipt))
}

@Test func clientConfigRefusesUserDisabledProviderWithActionableReason() throws {
  let fixture = try ClientConfigFixture("{\"disabled_providers\":[\"mmx-test\"]}")
  defer { fixture.cleanup() }
  do {
    _ = try fixture.prepare(fixture.manager())
    #expect(Bool(false))
  } catch let error as ClientConfigError {
    #expect(error.code == "provider_disabled")
    #expect(error.message.contains("remove that user setting"))
  }
}

@Test(arguments: ["{\"enabled_providers\":{}}", "{\"disabled_providers\":\"mmx-test\"}", "{\"enabled_providers\":[\"keep\",true]}"])
func clientConfigDeclinesInvalidProviderFilterTypes(_ body: String) throws {
  let fixture = try ClientConfigFixture(body)
  defer { fixture.cleanup() }
  #expect(throws: ClientConfigError.self) { _ = try fixture.prepare(fixture.manager()) }
}

@Test func clientConfigPersistedReceiptPreservesAllowListOwnershipAcrossRestart() throws {
  let fixture = try ClientConfigFixture("{\"enabled_providers\":[\"keep\"]}")
  defer { fixture.cleanup() }
  let first = fixture.manager()
  let receipt = try first.apply(fixture.prepare(first), operationID: "filter-before-restart")
  let saved = try JSONDecoder().decode(ClientConfigReceipt.self, from: JSONEncoder().encode(receipt))
  let restarted = fixture.manager()
  let preview = try restarted.prepare(target: "kilo", providerID: "mmx-test", modelKey: "local-alias", modelID: "exact-wire-id",
    baseURL: "http://127.0.0.1:17701/v1", keyFile: fixture.keyFile, context: nil, makeDefault: false, previousReceipt: saved)
  let updated = try restarted.apply(preview, operationID: "filter-after-restart")
  #expect(updated.ownedEnabledProviderMembership == true)
  try restarted.remove(updated)
  #expect(!String(decoding: try fixture.bytes(), as: UTF8.self).contains("mmx-test"))
  #expect(String(decoding: try fixture.bytes(), as: UTF8.self).contains("keep"))
}
