import Darwin
import Foundation
import Testing
@testable import ModelMatrixControllerCore

@Test func connectScopedReservedPathsNeverFallThroughToLegacyRouting() {
    let id = "c-01234567-abcd-4321-abcd-0123456789ab"
    #expect(ScopedModelRoute.parse("/connections/\(id)/v1/models") == ScopedModelRoute(connectionID: id, endpoint: "/v1/models"))
    #expect(ScopedModelRoute.parse("/connections/\(id)/v1/chat/completions")?.endpoint == "/v1/chat/completions")
    for path in ["/connections", "/connections/../v1/models", "/connections//v1/models",
                 "/%63onnections/\(id)/v1/models", "/connections%2f\(id)/v1/models",
                 "/CONNECTIONS/\(id)/v1/models", "/connections/\(id)/v1/models/extra"] {
        #expect(ScopedModelRoute.isReserved(path))
        #expect(ScopedModelRoute.parse(path) == nil)
    }
    #expect(!ScopedModelRoute.isReserved("/v1/chat/completions"))
}

@Test func connectControllerRoutesRetainBearerAndSameOriginGuards() throws {
    try withFixtureRoot { fixture in
        let core = testConnectCore(fixture)
        let router = ControllerRouter(service: fixture.service, authToken: "test-controller-owner-token", connections: core)
        #expect(router.handle(.init(method: "GET", target: "/api/connect/profiles")).status == 401)
        let authorized = router.handle(.init(method: "GET", target: "/api/connect/profiles",
            headers: ["Authorization": "Bearer test-controller-owner-token"]))
        #expect(authorized.status == 200)
        #expect(authorized.headers["Cache-Control"] == "no-store")
        let forbidden = router.handle(.init(method: "POST", target: "/api/connect/plan",
            headers: ["Authorization": "Bearer test-controller-owner-token", "Content-Type": "application/json", "Origin": "https://untrusted.invalid"],
            body: Data(#"{"profile":"local:test","target":"manual"}"#.utf8)))
        #expect(forbidden.status == 403)
    }
}

@Test func connectDetailsAreReadOnlyAndManualPlansRequireApproval() throws {
    try withFixtureRoot { fixture in
        let core = testConnectCore(fixture)
        let router = ControllerRouter(service: fixture.service, authToken: nil, connections: core)
        let source = fixture.configuration.root.appendingPathComponent("model-profiles/test.env")
        let before = try Data(contentsOf: source)
        let details = router.handle(.init(method: "GET", target: "/api/connect/details?profile=local:test"))
        #expect(details.status == 200)
        let fields = try #require(try JSONSerialization.jsonObject(with: details.body) as? [String: Any])
        #expect(fields["api_key_requirement"] as? String == "not_required")
        #expect(fields["connection_id"] == nil)
        #expect((core.listPayload()["connections"] as? [[String: Any]])?.isEmpty == true)
        let plan = try #require(core.plan(profile: "local:test", target: "manual")["plan"] as? [String: Any])
        let id = try #require(plan["id"] as? String)
        let denied = router.handle(.init(method: "POST", target: "/api/connect/apply", headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: ["plan_id": id, "approved": false])))
        #expect(denied.status == 400)
        #expect(try Data(contentsOf: source) == before)
        #expect((core.listPayload()["connections"] as? [[String: Any]])?.isEmpty == true)
    }
}

@Test func connectTrustedRenameKeepsIdentityButModelReplacementNeverRetargets() throws {
    try withFixtureRoot(profileBodies: ["test": fixtureProfile(port: 59992)]) { fixture in
        let core = testConnectCore(fixture)
        let router = ControllerRouter(service: fixture.service, authToken: nil, connections: core)
        _ = router
        let plan = try #require(core.plan(profile: "local:test", target: "manual")["plan"] as? [String: Any])
        let id = try #require(plan["id"] as? String)
        let connection = try #require(core.apply(planID: id, approved: true)["connection"] as? [String: Any])
        let connectionID = try #require(connection["id"] as? String)
        let key = try #require(core.secret(id: connectionID, approved: true)["key"] as? String)
        let values = ["DISPLAY_NAME": "Renamed", "RUNTIME": "external", "PORT": "59992",
            "REQUEST_MODEL": "test-model", "HEALTHCHECK_MODE": "disabled", "LAUNCH_MODE": "external"]
        try fixture.service.saveProfile(name: "renamed", values: values, originalName: "test")
        let renamed = try core.authorize(connectionID: connectionID, apiKey: key, modelID: "test-model", listing: true)
        #expect(renamed.profile.profile == "renamed")
        #expect(renamed.modelID == "test-model")
        var replaced = values
        replaced["REQUEST_MODEL"] = "different-model"
        try fixture.service.saveProfile(name: "renamed", values: replaced)
        #expect(throws: ClientConnectionError.self) {
            try core.authorize(connectionID: connectionID, apiKey: key, modelID: "different-model", listing: true)
        }
    }
}

@Test func connectDeletingAProfileRevokesItsKeyBeforeSameNameRecreation() throws {
    try withFixtureRoot(profileBodies: ["test": fixtureProfile(port: 59992)]) { fixture in
        let core = testConnectCore(fixture)
        let router = ControllerRouter(service: fixture.service, authToken: nil, connections: core)
        _ = router
        let plan = try #require(core.plan(profile: "local:test", target: "manual")["plan"] as? [String: Any])
        let planID = try #require(plan["id"] as? String)
        let connection = try #require(core.apply(planID: planID, approved: true)["connection"] as? [String: Any])
        let id = try #require(connection["id"] as? String)
        let key = try #require(core.secret(id: id, approved: true)["key"] as? String)
        try fixture.service.deleteProfile("test")
        try fixture.service.saveProfile(name: "test", values: ["PORT": "59992", "REQUEST_MODEL": "test-model", "RUNTIME": "external"])
        #expect(throws: ClientConnectionError.self) { try core.authorize(connectionID: id, apiKey: key, modelID: "test-model", listing: true) }
        #expect(throws: ClientConnectionError.self) { try core.secret(id: id, approved: true) }
    }
}

private func testConnectCore(_ fixture: ControllerFixture) -> ClientConnectionService {
    let service = fixture.service
    return ClientConnectionService(directory: fixture.temporary.appendingPathComponent("connections"), profiles: {
        guard let profiles = try? service.profiles.load() else { return [] }
        return profiles.values.compactMap { profile in
            guard let file = service.profileFile(named: profile.name) else { return nil }
            var identity = stat()
            guard lstat(file.path, &identity) == 0 else { return nil }
            return ClientConnectionProfile(key: "local:\(profile.name)", profile: profile.name, modelID: profile.requestModel,
                runtime: profile.runtime, readiness: "stopped",
                identityToken: "\(identity.st_dev):\(identity.st_ino):\(identity.st_birthtimespec.tv_sec):\(identity.st_birthtimespec.tv_nsec)")
        }
    }, relay: { ClientRelayState(baseURL: "http://127.0.0.1:7701", listening: true) },
       config: ClientConfigManager(home: fixture.temporary))
}

@Test func connectServerRootRetainsProtectedPrefixForClientsAddingV1() throws {
    try withFixtureRoot { fixture in
        let core = testConnectCore(fixture)
        let plan = try #require(core.plan(profile: "local:test", target: "manual")["plan"] as? [String: Any])
        let planID = try #require(plan["id"] as? String)
        let connection = try #require(core.apply(planID: planID, approved: true)["connection"] as? [String: Any])
        let id = try #require(connection["id"] as? String)
        let details = try core.details(profile: "local:test", connection: id)
        let root = try #require(details["server_root"] as? String)
        let base = try #require(details["base_url"] as? String)
        #expect(root + "/v1" == base)
        #expect(root.contains("/connections/" + id))
        let example = try #require(details["request_example"] as? String)
        #expect(example.contains("Content-Type: application/json"))
        #expect(example.contains("<YOUR_MODELMATRIX_KEY>"))
        #expect(example.contains("\"messages\""))
        #expect(example.contains("\"model\""))
    }
}

@Test func connectMalformedAndAbsoluteTargetsCannotReachLegacyFallback() {
    let id = "c-01234567-abcd-4321-abcd-0123456789ab"
    for path in ["//connections/\(id)/v1/models", "/v1/../connections/\(id)/v1/models",
                 "/\\connections/\(id)/v1/models", "http://127.0.0.1:7701/connections/\(id)/v1/models",
                 "https://localhost/connections/\(id)/v1/models", "/connections%zz/\(id)/v1/models"] {
        let request = RelayRequest(method: "GET", target: path, headerLines: [], headers: [:], body: Data())
        #expect(ScopedModelRoute.isReserved(request.path))
        #expect(ScopedModelRoute.parse(request.path) == nil)
    }
    var encoded = "%63onnections"
    for _ in 0..<15 {
        let path = "/\(encoded)/\(id)/v1/models"
        #expect(ScopedModelRoute.isReserved(path))
        #expect(ScopedModelRoute.parse(path) == nil)
        encoded = encoded.replacingOccurrences(of: "%", with: "%25")
    }
    #expect(!ScopedModelRoute.isReserved("/v1/chat/completions"))
    #expect(!ScopedModelRoute.isReserved("/api/chat"))
}
