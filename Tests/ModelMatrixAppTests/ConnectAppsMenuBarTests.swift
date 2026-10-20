import Foundation
import Testing
@testable import ModelMatrixApp

struct ConnectAppsMenuBarTests {
    @Test func connectionStateKeepsConfiguredApiClientAndReloadSeparate() {
        let row = JSONRow([
            "configured": true,
            "api_tested": true,
            "client_verified": false,
            "reload_required": true,
            "readiness": "ready",
        ])
        #expect(ConnectAppsFormatter.connectionState(row) == "Configured · API tested · Reload required · Ready")
    }

    @Test func targetLabelDistinguishesQualificationFromInstallation() {
        #expect(ConnectAppsFormatter.targetLabel(JSONRow(["id": "kilo", "name": "Kilo", "installed": false, "qualified": false])) == "Kilo · not installed")
        #expect(ConnectAppsFormatter.targetLabel(JSONRow(["id": "opencode", "name": "OpenCode", "installed": true, "qualified": false])) == "OpenCode · not qualified")
        #expect(ConnectAppsFormatter.targetLabel(JSONRow(["id": "kilo", "name": "Kilo", "installed": true, "qualified": true])) == "Kilo · ready")
    }

    @Test func copiedDetailsNeverIncludeSecretFields() {
        let details = JSONRow([
            "provider": "OpenAI-compatible",
            "base_url": "http://127.0.0.1:7700/connections/c1/v1",
            "model_id": "wire-model",
            "api_key_requirement": "required",
            "key": "must-not-copy",
            "credential": "must-not-copy",
        ])
        let copied = ConnectAppsFormatter.copyableDetails(details)
        #expect(copied.contains("Base URL: http://127.0.0.1:7700/connections/c1/v1"))
        #expect(copied.contains("Model ID: wire-model"))
        #expect(!copied.contains("must-not-copy"))
        #expect(copied.contains("API key: required"))
        #expect(!copied.split(separator: "\n").contains { $0.hasPrefix("key:") || $0.hasPrefix("credential:") })
    }

    @Test func readinessFormattingIsConservative() {
        #expect(ConnectAppsFormatter.readiness(JSONRow(["readiness": "needs_review"])) == "Needs attention")
        #expect(ConnectAppsFormatter.readiness(JSONRow(["readiness": "stopped"])) == "Stopped")
        #expect(ConnectAppsFormatter.readiness(JSONRow(["readiness": "ready"])) == "Ready")
    }
}

@Test func nativeConnectionDetailsFollowConfiguredScopeButNeverAnotherProfile() {
    let row = JSONRow(["id": "c-test", "configured": true, "profile_key": "local:one"])
    #expect(ConnectAppsFormatter.detailQuery(profileKey: "local:one", connection: row) == ["profile": "local:one", "connection": "c-test"])
    #expect(ConnectAppsFormatter.detailQuery(profileKey: "local:two", connection: row) == ["profile": "local:two"])
    let revoked = JSONRow(["id": "c-test", "configured": false, "profile_key": "local:one"])
    #expect(ConnectAppsFormatter.detailQuery(profileKey: "local:one", connection: revoked) == ["profile": "local:one"])
}
