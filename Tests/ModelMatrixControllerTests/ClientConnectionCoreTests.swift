import Foundation
import Darwin
import Testing
@testable import ModelMatrixControllerCore

@Suite(.serialized)
struct ClientConnectionCoreTests {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
        init(_ value: Value) { stored = value }
    }
    private let relay = ClientRelayState(baseURL: "http://127.0.0.1:17701/v1", listening: true)
    private var profile: ClientConnectionProfile {
        ClientConnectionProfile(key: "local:tiny", profile: "tiny", displayName: "Not a client label", modelID: "wire-tiny", readiness: "running", identityToken: "source-a")
    }

    @Test func testManualConnectionBindsExactModelAndPersistsProtectedKey() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root)
        let id = try connect(service)
        let key = try key(service, id)
        let authorization = try service.authorize(connectionID: id, apiKey: key, modelID: profile.modelID, listing: false)
        assertEqual(authorization.modelID, profile.modelID)
        assertEqual(authorization.profile.key, profile.key)
        assertEqual(authorization.clientLabel, "Other app")
        expectCode("model_mismatch") { _ = try service.authorize(connectionID: id, apiKey: key, modelID: "other", listing: false) }
        let file = root.appendingPathComponent("connection-keys/\(id).key")
        let nativeLoadedKey = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        assertEqual(nativeLoadedKey, key)
        assertEqual(key.utf8.count, 64)
        assertTrue(key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        assertEqual(permissions?.intValue, 0o600)
        assertEqual((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        service.markClientUse(connectionID: id, successful: true)
        assertEqual(try row(service)["traffic_observed"] as? Int, 1)
        assertEqual(try row(service)["client_verified"] as? Bool, false)
        let persisted = try String(contentsOf: root.appendingPathComponent("connections-state.json"), encoding: .utf8)
        assertFalse(persisted.contains(key))
        let restarted = self.service(root)
        assertEqual(try self.key(restarted, id), key)
        assertNoThrow(try restarted.authorize(connectionID: id, apiKey: nativeLoadedKey, listing: true))
    }

    @Test func testListingCanUseStoppedProfileButInferenceAndVerifyFailClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = ClientConnectionProfile(key: "local:tiny", profile: "tiny", modelID: "wire-tiny", readiness: "stopped", identityToken: "source-a")
        let calls = Box(0)
        let service = service(root, profiles: { [p] }, transport: { _ in calls.value += 1; throw TestFailure.failed })
        let id = try connect(service), key = try key(service, id)
        assertNoThrow(try service.authorize(connectionID: id, apiKey: key, listing: true))
        expectCode("model_unavailable") { _ = try service.authorize(connectionID: id, apiKey: key, modelID: p.modelID, listing: false) }
        expectCode("model_unavailable") { _ = try service.verify(id: id) }
        assertEqual(calls.value, 0)
    }

    @Test func testProfileDeletionRevokesKeyAndNeverRetargets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = profile, box = Box([profile])
        let service = service(root, profiles: { box.value })
        let id = try connect(service)
        box.value = []
        service.profileDeleted(key: p.key)
        expectCode("connection_revoked") { _ = try service.secret(id: id, approved: true) }
        box.value = [ClientConnectionProfile(key: p.key, profile: "replacement", modelID: p.modelID, readiness: "running", identityToken: "replacement-source")]
        expectCode("connection_revoked") { _ = try service.authorize(connectionID: id, apiKey: String(repeating: "a", count: 64), listing: true) }
        assertEqual(try row(service)["state"] as? String, "revoked")
        assertEqual(try row(service)["model_id"] as? String, p.modelID)
    }

    @Test func testPlanApprovalIsSingleUseAndRequiresExplicitApproval() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root)
        let id = try planID(service)
        expectCode("approval_required") { _ = try service.apply(planID: id, approved: false) }
        assertNoThrow(try service.planPayload(planID: id))
        _ = try service.apply(planID: id, approved: true)
        expectCode("plan_replayed") { _ = try service.apply(planID: id, approved: true) }
    }

    @Test func testDetailsAreReadOnlyAndLegacyRouteHasNoCredentialOrScopeClaim() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root)
        let details = try service.details(profile: profile.key)
        assertEqual(details["base_url"] as? String, relay.baseURL)
        assertEqual(details["api_key_requirement"] as? String, "not_required")
        assertNil(details["credential_kind"])
        assertNil(details["connection_id"])
        assertTrue((details["summary"] as? String)?.contains("not authenticated or scoped") == true)
        assertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("connections-state.json").path))
        assertEqual((service.listPayload()["connections"] as? [[String: Any]])?.count, 0)
        let id = try connect(service)
        let before = try stateData(root)
        let protected = try service.details(profile: profile.key, connection: id)
        assertEqual(protected["api_key_requirement"] as? String, "required")
        assertEqual(protected["credential_kind"] as? String, "protected_file")
        assertEqual(try stateData(root), before)
    }

    @Test func testDisabledRelayDoesNotManufactureURLsOrCreatePlan() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root, relay: { ClientRelayState(baseURL: "", listening: false) })
        let details = try service.details(profile: profile.key)
        for field in ["base_url", "server_root", "model_list_url", "chat_url"] { assertEqual(details[field] as? String, "") }
        assertEqual(details["api_key_requirement"] as? String, "not_configured")
        expectCode("relay_unavailable") { _ = try service.plan(profile: self.profile.key, target: "manual") }
        assertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("connections-state.json").path))
    }

    @Test func testProductionV1RelayRootGeneratesExactlyOneScopedV1() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root)
        let id = try connect(service)
        assertEqual(try row(service)["base_url"] as? String, "http://127.0.0.1:17701/connections/\(id)/v1")
    }

    @Test func testConfigApprovalSourceSnapshotPersistsAndRejectsChangesBeforeAnyWrites() throws {
        let (root, path, manager) = try configFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root.appendingPathComponent("registry"), config: manager)
        let plan = try service.plan(profile: profile.key, target: "opencode")
        let id = try unwrap((plan["plan"] as? [String: Any])?["id"] as? String)
        let before = try stateData(root.appendingPathComponent("registry"))
        let source = "{\"private_fixture_sentinel\":\"not-a-real-credential\",\"user_changed\":true}\n"
        try protectedWrite(source, path)
        let restarted = self.service(root.appendingPathComponent("registry"), config: manager)
        let restored = try restarted.planPayload(planID: id)
        assertEqual((restored["plan"] as? [String: Any])?["base_url"] as? String, (plan["plan"] as? [String: Any])?["base_url"] as? String)
        expectCode("approval_snapshot_changed") { _ = try restarted.apply(planID: id, approved: true) }
        assertEqual(try stateData(root.appendingPathComponent("registry")), before)
        assertEqual(try String(contentsOf: path, encoding: .utf8), source)
        assertEqual(try keyFiles(root.appendingPathComponent("registry")), [])
        assertFalse(String(data: before, encoding: .utf8)!.contains("private_fixture_sentinel"))
    }

    @Test func testSameBytesDifferentConfigInodeRejectsApproval() throws {
        let (root, path, manager) = try configFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry"), service = service(root.appendingPathComponent("registry"), config: manager)
        let id = try planID(service, target: "opencode")
        let data = try Data(contentsOf: path)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        expectCode("approval_snapshot_changed") { _ = try service.apply(planID: id, approved: true) }
        assertEqual(try keyFiles(directory), [])
    }

    @Test func testLegacyCodablePlanMissingFingerprintRequiresFreshReview() throws {
        let (root, _, manager) = try configFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry"), service = service(root.appendingPathComponent("registry"), config: manager)
        let id = try planID(service, target: "opencode")
        try editRegistry(directory) { registry in
            var plans = registry["plans"] as! [String: [String: Any]]
            plans[id]?.removeValue(forKey: "approvalFingerprint")
            registry["plans"] = plans
        }
        let restarted = self.service(directory, config: manager)
        assertNoThrow(try restarted.planPayload(planID: id))
        expectCode("approval_snapshot_missing") { _ = try restarted.apply(planID: id, approved: true) }
        assertEqual(try keyFiles(directory), [])
    }

    @Test func testChangedConfigPathOrVersionRejectsApprovalWithoutKeys() throws {
        let (root, path, manager) = try configFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry"), service = service(root.appendingPathComponent("registry"), config: manager)
        let id = try planID(service, target: "opencode")
        let other = root.appendingPathComponent("other.json")
        try protectedWrite("{}\n", other)
        let newPathManager = ClientConfigManager(home: root, qualifiedOverrides: ["opencode": other], versionOverrides: ["opencode": "1.16.2"])
        let newPathService = self.service(directory, config: newPathManager)
        expectCode("approval_snapshot_changed") { _ = try newPathService.apply(planID: id, approved: true) }
        let newVersionManager = ClientConfigManager(home: root, qualifiedOverrides: ["opencode": path], versionOverrides: ["opencode": "9.0.0"])
        let newVersionService = self.service(directory, config: newVersionManager)
        assertThrows(try newVersionService.apply(planID: id, approved: true))
        assertEqual(try keyFiles(directory), [])
    }

    @Test func testRelayChangesAfterPlanRejectBeforeMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = Box(self.relay), service = service(root, relay: { relay.value })
        let id = try planID(service), before = try stateData(root)
        relay.value = ClientRelayState(baseURL: "http://127.0.0.1:17702/v1", listening: true)
        expectCode("relay_changed") { _ = try service.apply(planID: id, approved: true) }
        assertEqual(try stateData(root), before)
        assertEqual(try keyFiles(root), [])
    }

    @Test func testStaleSourceRequiresDisconnectThenFreshIdentity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box([profile]), service = service(root, profiles: { box.value })
        let oldID = try connect(service), oldKey = try key(service, oldID)
        box.value = [ClientConnectionProfile(key: profile.key, profile: "tiny", modelID: "replacement-wire", readiness: "running", identityToken: "source-b")]
        expectCode("profile_identity_changed") { _ = try service.authorize(connectionID: oldID, apiKey: oldKey, modelID: self.profile.modelID, listing: false) }
        expectCode("reconnect_required") { _ = try service.plan(profile: self.profile.key, target: "manual") }
        _ = try service.disconnect(id: oldID, removeConfig: false, approved: true)
        let newID = try connect(service)
        #expect(newID != oldID)
        expectCode("connection_revoked") { _ = try service.authorize(connectionID: oldID, apiKey: oldKey, listing: true) }
    }

    @Test func testTrustedRenameKeepsWireIDAndCredentialButRefreshesSourceIdentity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box([profile]), service = service(root, profiles: { box.value })
        let id = try connect(service), key = try key(service, id)
        let renamed = ClientConnectionProfile(key: "local:renamed", profile: "renamed", modelID: profile.modelID, readiness: "running", identityToken: "saved-inode-b")
        box.value = [renamed]
        service.profileChanged(oldKey: profile.key, newKey: renamed.key)
        let authorization = try service.authorize(connectionID: id, apiKey: key, modelID: profile.modelID, listing: false)
        assertEqual(authorization.profile.key, renamed.key)
        assertEqual(authorization.modelID, profile.modelID)
        assertEqual(try self.key(service, id), key)
    }

    @Test func testTrustedWireIDChangeRevokesWithoutRetargetingAndAllowsSafeCleanup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box([profile]), service = service(root, profiles: { box.value })
        let id = try connect(service), key = try key(service, id)
        box.value = [ClientConnectionProfile(key: profile.key, profile: "tiny", modelID: "new-wire", readiness: "running", identityToken: "source-b")]
        service.profileChanged(oldKey: profile.key, newKey: profile.key)
        assertEqual(try row(service)["model_id"] as? String, profile.modelID)
        assertEqual(try row(service)["state"] as? String, "needs_review")
        expectCode("connection_revoked") { _ = try service.authorize(connectionID: id, apiKey: key, modelID: "new-wire", listing: false) }
        assertEqual(try keyFiles(root), [])
        assertNoThrow(try service.disconnect(id: id, removeConfig: true, approved: true))
    }

    @Test func testModelListingAndAuthorizationDoNotWriteRegistryOrObserveTraffic() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root), id = try connect(service), key = try key(service, id), before = try stateData(root)
        _ = try service.authorize(connectionID: id, apiKey: key, listing: true)
        _ = try service.authorize(connectionID: id, apiKey: key, modelID: profile.modelID, listing: false)
        assertEqual(try stateData(root), before)
        assertEqual(try row(service)["traffic_observed"] as? Int, 0)
    }

    @Test func testInferenceRequiresModelAndKeyLengthsCannotWrap() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root), id = try connect(service), key = try key(service, id)
        expectCode("model_required") { _ = try service.authorize(connectionID: id, apiKey: key, listing: false) }
        expectCode("model_required") { _ = try service.authorize(connectionID: id, apiKey: key, modelID: "", listing: false) }
        for invalid in [key + String(repeating: "\0", count: 256), String(key.dropLast()), String(repeating: "z", count: 64)] {
            assertThrows(try service.authorize(connectionID: id, apiKey: invalid, listing: true))
        }
    }

    @Test func testListReadinessAndSourceStateAreFreshWithoutRegistryMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box([profile]), service = service(root, profiles: { box.value })
        _ = try connect(service)
        let before = try stateData(root)
        box.value = [ClientConnectionProfile(key: profile.key, profile: "tiny", modelID: profile.modelID, readiness: "stopped", identityToken: "source-a")]
        assertEqual(try row(service)["readiness"] as? String, "stopped")
        box.value = [ClientConnectionProfile(key: profile.key, profile: "tiny", modelID: profile.modelID, readiness: "running", identityToken: "untrusted-replacement")]
        assertEqual(try row(service)["state"] as? String, "needs_review")
        assertEqual(try row(service)["configured"] as? Bool, false)
        assertEqual(try stateData(root), before)
    }

    @Test func testVerificationMakesBothScopedHTTPProbesOutsideRegistryLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let serviceBox = Box<ClientConnectionService?>(nil), calls = Box([String]())
        let p = profile
        let transport: ClientVerificationTransport = { request in
            let service = try unwrap(serviceBox.value), url = try unwrap(request.url)
            let id = url.path.split(separator: "/")[1].description
            let bearer = try unwrap(request.value(forHTTPHeaderField: "Authorization"))
            let key = String(bearer.dropFirst("Bearer ".count))
            let result = Box<Error?>(nil), semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do { _ = try service.authorize(connectionID: id, apiKey: key, modelID: request.httpMethod == "GET" ? nil : p.modelID, listing: request.httpMethod == "GET") }
                catch { result.value = error }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 1) == .success else { throw TestFailure.failed }
            if let error = result.value { throw error }
            calls.value.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                let body = try unwrap(request.httpBody)
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                assertEqual(json["model"] as? String, p.modelID)
                assertEqual(json["max_tokens"] as? Int, 4)
                assertEqual(json["stream"] as? Bool, false)
            }
            return try Self.probeResponse(request, modelID: p.modelID)
        }
        let service = service(root, transport: transport)
        serviceBox.value = service
        let id = try connect(service)
        _ = try service.verify(id: id)
        assertEqual(calls.value, ["GET", "POST"])
        assertEqual(try row(service)["api_tested"] as? Bool, true)
        assertEqual(try row(service)["client_verified"] as? Bool, false)
        service.markClientUse(connectionID: id, successful: true)
        assertEqual(try row(service)["client_verified"] as? Bool, false)
        expectCode("trusted_report_required") { try service.markClientVerified(connectionID: id) }
    }

    @Test func testVerificationFailureNeverClaimsAPITestedOrClientVerified() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0), p = profile
        let service = service(root, transport: { request in
            calls.value += 1
            return try Self.probeResponse(request, modelID: p.modelID, status: request.httpMethod == "GET" ? 200 : 503)
        })
        let id = try connect(service)
        expectCode("verification_chat_failed") { _ = try service.verify(id: id) }
        assertEqual(calls.value, 2)
        assertEqual(try row(service)["api_tested"] as? Bool, false)
        assertEqual(try row(service)["client_verified"] as? Bool, false)
    }

    @Test func testVerificationRejectsUnscopedModelListAndRedirectResponse() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0)
        let service = service(root, transport: { request in calls.value += 1; return try Self.probeResponse(request, modelID: "wrong-model") })
        let id = try connect(service)
        expectCode("verification_models_failed") { _ = try service.verify(id: id) }
        assertEqual(calls.value, 1)
        let redirectService = self.service(root, transport: { request in
            let data = Data("{\"data\":[]}".utf8)
            return (data, HTTPURLResponse(url: URL(string: "http://127.0.0.1:17702/elsewhere")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        expectCode("verification_models_failed") { _ = try redirectService.verify(id: id) }
    }

    @Test func testDisconnectDuringVerificationDiscardsResult() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box<ClientConnectionService?>(nil), p = profile
        let service = service(root, transport: { request in
            if request.httpMethod == "POST" {
                let id = request.url!.path.split(separator: "/")[1].description
                _ = try unwrap(box.value).disconnect(id: id, removeConfig: false, approved: true)
            }
            return try Self.probeResponse(request, modelID: p.modelID)
        })
        box.value = service
        let id = try connect(service)
        expectCode("connection_revoked") { _ = try service.verify(id: id) }
        assertEqual(try row(service)["api_tested"] as? Bool, false)
    }

    @Test func testUnsafeKeyPermissionsSymlinkAndHardlinkAreRejectedWithoutReadingTargets() throws {
        for mode in ["permissions", "symlink", "hardlink"] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = service(root), id = try connect(service)
            let file = root.appendingPathComponent("connection-keys/\(id).key")
            if mode == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            else {
                let sentinel = root.appendingPathComponent("synthetic-sentinel")
                try protectedWrite(String(repeating: "b", count: 64), sentinel)
                try FileManager.default.removeItem(at: file)
                if mode == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel) }
                else { assertEqual(link(sentinel.path, file.path), 0) }
            }
            assertThrows(try service.secret(id: id, approved: true))
        }
    }

    @Test func testLegacyBinaryKeyIsNotSilentlyRotated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root), id = try connect(service)
        let path = root.appendingPathComponent("connection-keys/\(id).key")
        let invalid = Data(repeating: 0xff, count: 32)
        try invalid.write(to: path)
        assertThrows(try service.secret(id: id, approved: true))
        assertEqual(try Data(contentsOf: path), invalid)
    }

    @Test func testInterruptedApplyRecoveryRevokesKeyAndFailsClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root), id = try connect(service), key = try key(service, id)
        try editRegistry(root) { registry in
            var records = registry["connections"] as! [String: [String: Any]]
            records[id]?["state"] = "applying"
            registry["connections"] = records
        }
        let restarted = self.service(root)
        assertEqual(try row(restarted)["state"] as? String, "needs_review")
        assertEqual(try keyFiles(root), [])
        expectCode("connection_revoked") { _ = try restarted.authorize(connectionID: id, apiKey: key, listing: true) }
    }

    @Test func testLegacyRegistryDoesNotRetainInMemoryOnlyAPITestClaim() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root), id = try connect(service)
        try editRegistry(root) { registry in
            registry["version"] = 1
            var records = registry["connections"] as! [String: [String: Any]]
            records[id]?["apiTested"] = true
            records[id]?["state"] = "api-tested"
            registry["connections"] = records
        }
        let restarted = self.service(root)
        #expect(try row(restarted)["api_tested"] as? Bool == false)
        #expect(try row(restarted)["state"] as? String == "configured")
    }

    @Test func testStorageRejectsUserDirectorySymlinkWithoutFollowingIt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = root.appendingPathComponent("sink"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: sink, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sink)
        let service = service(alias)
        expectCode("unsafe_storage") { _ = try service.plan(profile: self.profile.key, target: "manual") }
        assertEqual(try FileManager.default.contentsOfDirectory(atPath: sink.path), [])
    }

    @Test func testRepeatedConfigureRetainsIdentityKeyAndOriginalDefaultForDisconnect() throws {
        let (root, path, manager) = try configFixture(body: "{\"model\":\"keep/model\",\"provider\":{\"keep\":{\"npm\":\"other\"}}}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root.appendingPathComponent("registry"), config: manager)
        let id = try connect(service, target: "opencode", makeDefault: true), key = try key(service, id)
        assertEqual(try connect(service, target: "opencode", makeDefault: false), id)
        assertEqual(try self.key(service, id), key)
        _ = try service.disconnect(id: id, removeConfig: true, approved: true)
        let output = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        assertEqual(output["model"] as? String, "keep/model")
        assertNotNil((output["provider"] as? [String: Any])?["keep"])
    }

    @Test func testUndoConflictStillRevokesCredentialAndDoesNotRestoreUserConfig() throws {
        let (root, path, manager) = try configFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry"), service = service(root.appendingPathComponent("registry"), config: manager)
        let id = try connect(service, target: "opencode"), key = try key(service, id)
        let changed = "{\"provider\":{},\"user\":true}\n"
        try protectedWrite(changed, path)
        expectCode("undo_conflict") { _ = try service.undo(id: id, approved: true) }
        assertEqual(try keyFiles(directory), [])
        expectCode("connection_revoked") { _ = try service.authorize(connectionID: id, apiKey: key, listing: true) }
        assertEqual(try String(contentsOf: path, encoding: .utf8), changed)
    }

    private enum TestFailure: Error { case failed }
    private static func probeResponse(_ request: URLRequest, modelID: String, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let object: [String: Any] = request.httpMethod == "GET"
            ? ["object": "list", "data": [["id": modelID, "object": "model"]]]
            : ["choices": [["message": ["role": "assistant", "content": "OK"]]]]
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    private func service(_ root: URL, profiles: (@Sendable () -> [ClientConnectionProfile])? = nil, relay: (@Sendable () -> ClientRelayState)? = nil,
                         config: ClientConfigManager? = nil, transport: ClientVerificationTransport? = nil) -> ClientConnectionService {
        let p = profile, r = self.relay
        return ClientConnectionService(directory: root, profiles: profiles ?? { [p] }, relay: relay ?? { r },
                                       config: config ?? ClientConfigManager(home: root), verificationTransport: transport)
    }
    private func planID(_ service: ClientConnectionService, target: String = "manual", makeDefault: Bool = false) throws -> String {
        try unwrap((service.plan(profile: profile.key, target: target, makeDefault: makeDefault)["plan"] as? [String: Any])?["id"] as? String)
    }
    private func connect(_ service: ClientConnectionService, target: String = "manual", makeDefault: Bool = false) throws -> String {
        try unwrap((service.apply(planID: planID(service, target: target, makeDefault: makeDefault), approved: true)["connection"] as? [String: Any])?["id"] as? String)
    }
    private func key(_ service: ClientConnectionService, _ id: String) throws -> String { try unwrap(service.secret(id: id, approved: true)["key"] as? String) }
    private func row(_ service: ClientConnectionService) throws -> [String: Any] { try unwrap((service.listPayload()["connections"] as? [[String: Any]])?.first) }
    private func expectCode(_ code: String, _ action: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        assertThrows(try action(), sourceLocation: sourceLocation) { error in assertEqual((error as? ClientConnectionError)?.code, code, sourceLocation: sourceLocation) }
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modelmatrix-core-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
    private func protectedWrite(_ body: String, _ path: URL) throws {
        try body.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func configFixture(body: String = "{}\n") throws -> (URL, URL, ClientConfigManager) {
        let root = try temporaryRoot(), path = root.appendingPathComponent("opencode.json")
        try protectedWrite(body, path)
        return (root, path, ClientConfigManager(home: root, qualifiedOverrides: ["opencode": path], versionOverrides: ["opencode": "1.16.2"]))
    }
    private func stateData(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent("connections-state.json")) }
    private func keyFiles(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("connection-keys").path) }
    private func editRegistry(_ root: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let path = root.appendingPathComponent("connections-state.json")
        var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        edit(&registry)
        try JSONSerialization.data(withJSONObject: registry).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}


// Keep caller locations in compact helpers; these all record native Swift Testing issues.
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func assertTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func assertFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func assertNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func assertNotNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value != nil, sourceLocation: sourceLocation)
}
private func assertNoThrow<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression() }
    catch { Issue.record("Unexpected operation failure", sourceLocation: sourceLocation) }
}
private func assertThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation, _ handler: ((Error) -> Void)? = nil) {
    do { _ = try expression(); Issue.record("Expected operation to throw", sourceLocation: sourceLocation) }
    catch { handler?(error) }
}
