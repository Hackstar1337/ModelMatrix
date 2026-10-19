import Foundation
import Testing

@testable import ModelMatrixControllerCore

/// Runs the real Controller/start-model-mac.sh against a fake llama-server
/// whose --help is a recorded help text, then reads the options it was
/// started with. The fake exits at once, which also checks that the
/// launcher notices a server that stops during startup.
enum LauncherHarness {
  static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The ModelMatrixController executable built next to the tests.
  static let controller: URL? = {
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
      candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("ModelMatrixController"))
    }
    candidates.append(repository.appendingPathComponent(".build/debug/ModelMatrixController"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }()

  struct Run {
    let status: Int32
    let output: String
    let arguments: [String]
    let seconds: Double

    func value(after flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }
  }

  static func run(help: String?, profile extra: [String: String] = [:]) throws -> Run {
    let controller = try #require(controller, "build the ModelMatrixController product first")
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("mm-launcher-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let profiles = work.appendingPathComponent("model-profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let launcher = work.appendingPathComponent("start-model-mac.sh")
    try FileManager.default.copyItem(at: repository.appendingPathComponent("Controller/start-model-mac.sh"), to: launcher)
    if let help {
      try FileManager.default.copyItem(
        at: repository.appendingPathComponent("Tests/ModelMatrixControllerTests/Fixtures/llama-server/\(help)"),
        to: work.appendingPathComponent("help.txt"))
    }
    let server = work.appendingPathComponent("llama-server")
    try """
      #!/bin/bash
      if [ "${1:-}" = "--help" ]; then
        [ -f '\(work.path)/help.txt' ] && cat '\(work.path)/help.txt'
        exit 0
      fi
      printf '%s\\n' "$@" > '\(work.path)/arguments.txt'
      echo "fake llama-server: stopping"
      exit 1
      """.write(to: server, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    let model = work.appendingPathComponent("model.gguf")
    try Data("GGUF".utf8).write(to: model)
    let port = 20_000 + Int.random(in: 0..<20_000)
    var values = [
      "RUNTIME": "llama.cpp", "MODEL_PATH": model.path, "SERVER_BIN": server.path, "HOST": "127.0.0.1",
      "PORT": "\(port)", "BASE_URL": "http://127.0.0.1:\(port)/v1", "MODEL_ALIAS": "test-model",
      "REQUEST_MODEL": "test-model", "SERVER_MODEL_ID": "test-model", "LOG_ALIAS": "mm-launcher-\(port)",
    ]
    values.merge(extra) { $1 }
    let body = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
    try body.write(to: profiles.appendingPathComponent("test.env"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: "/tmp/mm-launcher-\(port).log") }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [launcher.path]
    var environment = ProcessInfo.processInfo.environment
    environment["MODEL_PROFILE"] = "test"
    environment["MODELMATRIX_CONTROLLER_BIN"] = controller.path
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let started = Date()
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let arguments = (try? String(contentsOf: work.appendingPathComponent("arguments.txt"), encoding: .utf8))?
      .split(separator: "\n").map(String.init) ?? []
    return Run(
      status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), arguments: arguments,
      seconds: Date().timeIntervalSince(started))
  }
}

@Suite(.enabled(if: LauncherHarness.controller != nil), .serialized)
struct LauncherLlamaOptionTests {
  @Test func currentLlamaCppGetsTheValuesItAccepts() throws {
    let run = try LauncherHarness.run(help: "help-b11738.txt")
    #expect(run.value(after: "--model")?.hasSuffix("model.gguf") == true, "\(run.output)")
    #expect(run.value(after: "--flash-attn") == "on")
    #expect(run.value(after: "--reasoning") == "off")  // the profile default "none"
    #expect(run.value(after: "--fit") == "off" && run.value(after: "--fit-ctx") == "0")
    #expect(run.arguments.contains("--metrics") && run.arguments.contains("--cont-batching"))
    #expect(!run.arguments.contains("--mmap") && !run.arguments.contains("--load-mode"))
    // A server that stops during startup is reported at once, not after the timeout.
    #expect(run.status != 0 && run.seconds < 30)
    #expect(run.output.contains("exited while starting") && run.output.contains("fake llama-server: stopping"))
  }

  @Test func currentLlamaCppLoadModeAndReasoningChoices() throws {
    let run = try LauncherHarness.run(
      help: "help-b11738.txt", profile: ["USE_MMAP": "0", "USE_MLOCK": "1", "REASONING": "auto", "FLASH_ATTN": "off"])
    #expect(run.value(after: "--load-mode") == "mlock", "\(run.output)")
    #expect(run.value(after: "--reasoning") == "auto" && run.value(after: "--flash-attn") == "off")
    let odd = try LauncherHarness.run(help: "help-b11738.txt", profile: ["REASONING": "sometimes"])
    #expect(!odd.arguments.contains("--reasoning"))
    #expect(odd.output.contains("Leaving out --reasoning sometimes: this llama-server accepts on|off|auto"))
  }

  @Test func olderLlamaCppGetsItsOwnSpelling() throws {
    let run = try LauncherHarness.run(help: "help-older.txt")
    // --flash-attn was a plain switch; --reasoning and --fit didn't exist.
    #expect(run.arguments.contains("--flash-attn") && run.value(after: "--flash-attn")?.hasPrefix("--") == true, "\(run.output)")
    #expect(!run.arguments.contains("--reasoning") && !run.arguments.contains("--fit"))
    #expect(run.output.contains("Leaving out --reasoning: this llama-server version doesn't have it"))
    #expect(run.arguments.contains("--metrics") && !run.arguments.contains("--mmap"))
    let noMap = try LauncherHarness.run(help: "help-older.txt", profile: ["USE_MMAP": "0", "USE_MLOCK": "1", "FLASH_ATTN": "0"])
    #expect(noMap.arguments.contains("--no-mmap") && noMap.arguments.contains("--mlock"))
    #expect(!noMap.arguments.contains("--flash-attn"))
  }

  @Test func unreadableHelpKeepsTheProfileAsWritten() throws {
    let run = try LauncherHarness.run(help: nil)
    #expect(run.value(after: "--flash-attn") == "1" && run.value(after: "--reasoning") == "none", "\(run.output)")
    #expect(run.arguments.contains("--mmap") && run.value(after: "--fit") == "0")
    #expect(run.output.contains("Could not read the options"))
  }
}
