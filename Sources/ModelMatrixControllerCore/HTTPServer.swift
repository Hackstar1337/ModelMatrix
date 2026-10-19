import Foundation
import Network

public final class ControllerHTTPServer: @unchecked Sendable {
  let configuration: ControllerConfiguration
  let router: ControllerRouter
  let queue = DispatchQueue(label: "io.github.hackstar1337.modelmatrix.controller.http")
  /// Profile actions (start/stop/switch/...) run one at a time, in order.
  let actionQueue = DispatchQueue(label: "io.github.hackstar1337.modelmatrix.controller.actions")
  let concurrentQueue = DispatchQueue(
    label: "io.github.hackstar1337.modelmatrix.controller.reads", attributes: .concurrent)
  var listener: NWListener?

  public init(configuration: ControllerConfiguration, router: ControllerRouter) {
    self.configuration = configuration
    self.router = router
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }
}
