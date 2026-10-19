import Foundation
import ModelMatrixControllerCore

extension ModelMatrixControllerMain {
  static func runCapabilities() throws {
    try printJSONObject([
      "schema_version": "1", "tool": "ModelMatrixController", "native": true,
      "commands": [
        "serve", "serve-web", "status", "list", "start", "stop", "restart", "switch", "activate",
        "stop-all", "integrations", "run-integration", "doctor", "diagnose", "health", "triage",
        "capabilities", "benchmark", "benchmark-worker", "profile-exports", "swiftbar",
        "robot-docs",
      ],
    ])
  }

  static func runRobotDocs() {
    print(
      """
      ModelMatrix native controller

      Read-only probes:
      - ModelMatrixController triage --root Controller
      - ModelMatrixController capabilities --root Controller
      - ModelMatrixController status --root Controller
      - ModelMatrixController doctor --root Controller

      Mutations support --dry-run or --plan before start, stop, restart, switch, and stop-all.
      """)
  }
}
