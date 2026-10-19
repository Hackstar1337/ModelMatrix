import Foundation
import ModelMatrixControllerCore

extension ModelMatrixControllerMain {
  static func runServe(service: ControllerService, configuration: ControllerConfiguration) throws {
    var usage: UsageService?
    do {
      usage = try UsageService.open(configuration: configuration, service: service)
    } catch {
      FileHandle.standardError.write(Data("usage metering unavailable: \(error)\n".utf8))
    }
    let router = ControllerRouter(
      service: service,
      authToken: configuration.authToken,
      dashboard: DashboardAssets.locate(configuration: configuration),
      usage: usage)
    let server = ControllerHTTPServer(configuration: configuration, router: router)
    try server.start()
    usage?.start()
    router.hub.start()
    service.startWatchdog()
    print("controller=http://\(configuration.host):\(configuration.port)")
    print("dashboard=http://localhost:\(configuration.port)/")
    if let usage { print("relay=\(usage.relayURL)") }
    dispatchMain()
  }

  static func runStatus(_ arguments: [String], service: ControllerService) throws {
    let selected = positionalValues(arguments, after: "status")
    try printJSON(service.statusPayload(selected: selected.isEmpty ? nil : selected))
  }

  static func runList(service: ControllerService) throws {
    let values = try service.profiles.load().values.sorted { $0.name < $1.name }.map { profile in
      [
        "profile": profile.name, "display_name": profile.displayName, "runtime": profile.runtime,
        "request_model": profile.requestModel, "base_url": profile.baseURL,
      ]
    }
    try printJSONObject(["profiles": values])
  }

  static func runIntegrations(service: ControllerService) throws {
    try printJSONObject(["integrations": encodableObjects(service.integrationStatus())])
  }

  static func runIntegration(_ arguments: [String], service: ControllerService) throws {
    let values = positionalValues(arguments, after: "run-integration")
    guard let id = values.first else { throw ControllerError.usage("No integration selected") }
    try service.runIntegration(id, action: values.dropFirst().first ?? "sync")
    try printJSON(service.actionResponse())
  }
}
