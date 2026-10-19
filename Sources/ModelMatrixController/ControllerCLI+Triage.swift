import Foundation
import ModelMatrixControllerCore

extension ModelMatrixControllerMain {
  static func runTriage(service: ControllerService) throws {
    try printJSONObject([
      "health": service.doctor.healthPayload(),
      "profiles": ["names": try service.profiles.load().keys.sorted()],
      "commands": ["status", "doctor", "capabilities", "triage", "robot-docs"],
    ])
  }
}
