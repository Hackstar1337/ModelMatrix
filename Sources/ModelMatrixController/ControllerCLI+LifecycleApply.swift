import Foundation
import ModelMatrixControllerCore

extension ModelMatrixControllerMain {
    static func applyLifecycle(_ command: String, name: String, service: ControllerService) throws {
        switch command {
        case "start": try service.start(name)
        case "stop": try service.stop(name)
        case "restart": try service.restart(name)
        default: break
        }
    }
}
