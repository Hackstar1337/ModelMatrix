import Foundation
import Security
import Darwin

/// Test-only constructor injection; the production default performs real scoped HTTP probes.
public typealias ClientVerificationTransport = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

/// A model profile exposed by the controller to connection clients.
public struct ClientConnectionProfile: Sendable, Equatable {
    public let key: String
    public let profile: String
    public let displayName: String
    public let modelID: String
    public let runtime: String
    public let host: String?
    public let readiness: String
    public let context: Int?
    /// A stable source identity. Producers should retain it across trusted renames and
    /// edits; a changed value means that a persisted connection must fail closed.
    public let identityToken: String

    public init(
        key: String,
        profile: String,
        displayName: String? = nil,
        modelID: String,
        runtime: String = "unknown",
        host: String? = nil,
        readiness: String = "unknown",
        context: Int? = nil,
        identityToken: String? = nil
    ) {
        self.key = key
        self.profile = profile
        self.displayName = displayName ?? profile
        self.modelID = modelID
        self.runtime = runtime
        self.host = host
        self.readiness = readiness
        self.context = context
        self.identityToken = identityToken ?? Self.derivedIdentity(
            key: key, profile: profile, modelID: modelID, host: host
        )
    }

    private static func derivedIdentity(key: String, profile: String, modelID: String, host: String?) -> String {
        [key, profile, modelID, host ?? ""].joined(separator: "\u{1f}")
    }
}

public struct ClientRelayState: Sendable, Equatable {
    public let baseURL: String
    public let listening: Bool
    public let error: String?

    public init(baseURL: String, listening: Bool, error: String? = nil) {
        self.baseURL = baseURL
        self.listening = listening
        self.error = error
    }
}

public struct ClientScopedAuthorization: Sendable, Equatable {
    public let profile: ClientConnectionProfile
    public let modelID: String
    public let clientID: String
    public let clientLabel: String

    public init(profile: ClientConnectionProfile, modelID: String, clientID: String, clientLabel: String) {
        self.profile = profile
        self.modelID = modelID
        self.clientID = clientID
        self.clientLabel = clientLabel
    }
}

public struct ClientConnectionError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Durable, authenticated connection state. Router and relay code deliberately remain
/// outside this type: the parent can call these synchronous methods from either path.
public final class ClientConnectionService: @unchecked Sendable {
    private let directory: URL
    private let profilesProvider: @Sendable () -> [ClientConnectionProfile]
    private let relayProvider: @Sendable () -> ClientRelayState
    private let config: ClientConfigManager
    private let verificationTransport: ClientVerificationTransport
    private let lock = NSLock()
    private var state: Registry
    private var storageFailure: ClientConnectionError?

    private let registryName = "connections-state.json"
    private let journalName = "connections-journal.jsonl"
    private let keyDirectoryName = "connection-keys"
    private let stateVersion = 2
    private let planLifetime: TimeInterval = 15 * 60

    public init(
        directory: URL,
        profiles: @escaping @Sendable () -> [ClientConnectionProfile],
        relay: @escaping @Sendable () -> ClientRelayState,
        config: ClientConfigManager = ClientConfigManager(),
        verificationTransport: ClientVerificationTransport? = nil
    ) {
        // Only canonicalize the two macOS system aliases, never a user-controlled link.
        let path = directory.standardizedFileURL.path
        let canonicalPath = path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/")
            ? "/private" + path : path
        self.directory = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        self.profilesProvider = profiles
        self.relayProvider = relay
        self.config = config
        self.verificationTransport = verificationTransport ?? { try ScopedVerificationRequest.perform($0) }
        self.state = Registry(version: 2)
        prepareStorage()
        loadState()
        reconcileJournal()
    }

    // MARK: Public payload API

    public func profilesPayload() -> [String: Any] {
        withLock {
            let rows = profilesProvider().map(profilePayload)
            let relay = relayProvider()
            var payload: [String: Any] = [
                "profiles": rows,
                "relay": [
                    "base_url": relay.baseURL,
                    "server_root": serverRoot(relay.baseURL),
                    "listening": relay.listening
                ]
            ]
            if let relayError = relay.error { payload["relay"] = [
                "base_url": relay.baseURL,
                "server_root": serverRoot(relay.baseURL),
                "listening": relay.listening,
                "error": relayError
            ] }
            return payload
        }
    }

    public func targetsPayload() -> [String: Any] {
        withLock { ["targets": config.targets()] }
    }

    public func details(profile profileKey: String, connection connectionID: String? = nil) throws -> [String: Any] {
        try withThrowingLock {
            let profile = try requireCurrentProfile(profileKey)
            var record: ConnectionRecord?
            if let connectionID {
                let candidate = try requireActiveRecord(connectionID)
                guard candidate.profileKey == profileKey else {
                    throw error(404, "connection_not_found", "Unknown connection for profile")
                }
                try requireIdentity(candidate, current: profile)
                record = candidate
            } else if let candidate = state.connections.values.sorted(by: { $0.createdAt < $1.createdAt }).first(where: {
                $0.profileKey == profileKey && !$0.revoked && !$0.tombstone && $0.state != "needs_review" && $0.state != "applying"
            }) {
                try requireIdentity(candidate, current: profile)
                record = candidate
            }
            let relay = relayProvider()
            let availableRoot = relayRoot(relay)
            let base = availableRoot.map { root in
                record.map { $0.baseURL == scopedBaseURL(root: root, id: $0.id) ? $0.baseURL : "" }
                    ?? (profile.host != nil || profile.key.hasPrefix("remote:") ? "" : joinURL(root, "v1"))
            } ?? ""
            let modelListURL = base.isEmpty ? "" : joinURL(base, "models")
            let chatURL = base.isEmpty ? "" : joinURL(base, "chat/completions")
            var notes = [
                "API testing and real-client verification are reported separately.",
                "Details do not create routes, credentials, change settings, or start models."
            ]
            let requirement: String
            let summary: String
            if record != nil {
                requirement = "required"
                summary = "\(profile.displayName) is bound to \(profile.modelID) through a protected scoped ModelMatrix relay route."
                notes.append("The protected route is immutable to this profile source and exact model ID.")
            } else {
                requirement = base.isEmpty ? "not_configured" : "not_required"
                summary = base.isEmpty
                    ? "The relay is unavailable; no connection URL or credential is configured."
                    : "Legacy ModelMatrix relay details for \(profile.modelID); this route is not authenticated or scoped to this profile."
                notes.append("Apply a reviewed connection plan to create a protected, authenticated scoped route. The legacy route has no connection credential.")
            }
            if base.isEmpty { notes.append("Relay unavailable or changed; no currently usable URL is advertised.") }
            if let relayError = relay.error, !relayError.isEmpty { notes.append("Relay: \(relayError)") }
            let body = try JSONSerialization.data(withJSONObject: [
                "model": profile.modelID, "messages": [["role": "user", "content": "Hello"]], "max_tokens": 128
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let authorization = record == nil ? "" : " -H 'Authorization: Bearer <YOUR_MODELMATRIX_KEY>'"
            let requestExample = base.isEmpty ? "" : "curl \(quote(chatURL)) -H 'Content-Type: application/json'\(authorization) --data \(quote(String(decoding: body, as: UTF8.self)))"
            var result: [String: Any] = [
                "profile": profile.key, "display_name": profile.displayName, "model_id": profile.modelID,
                "provider": "OpenAI-compatible", "base_url": base, "server_root": serverRoot(base),
                "model_list_url": modelListURL, "chat_url": chatURL, "api_key_requirement": requirement,
                "readiness": profile.readiness,
                "capabilities": ["chat": true, "tools": "unknown", "images": "unknown", "embeddings": "unknown"],
                "summary": summary,
                "request_example": requestExample, "notes": notes
            ]
            if let context = profile.context { result["context"] = context }
            if let record { result["connection_id"] = record.id; result["credential_kind"] = "protected_file" }
            return result
        }
    }

    public func listPayload() -> [String: Any] {
        withLock {
            let rows = state.connections.values.sorted { $0.createdAt < $1.createdAt }.map(connectionPayload)
            return ["connections": rows, "operations": state.operations.map(operationPayload)]
        }
    }

    /// Returns the exact saved, nonsecret review payload. It never refreshes approval or writes state.
    public func planPayload(planID: String) throws -> [String: Any] {
        try withThrowingLock {
            try requireStorage()
            try validateIdentifier(planID, field: "plan_id")
            guard let prepared = state.plans[planID] else { throw error(404, "plan_not_found", "Unknown plan") }
            guard !prepared.used else { throw error(409, "plan_replayed", "Plan approval has already been used") }
            guard prepared.expiresAt > Date() else { throw error(409, "plan_expired", "Plan approval has expired") }
            return planPayload(prepared, existing: state.connections[prepared.connectionID] != nil)
        }
    }

    public func plan(profile profileKey: String, target: String, makeDefault: Bool = false) throws -> [String: Any] {
        try withThrowingLock {
            try requireStorage()
            let profile = try requireCurrentProfile(profileKey)
            let normalizedTarget = try normalizedTarget(target)
            let root = try requireRelayRoot()
            let existing = state.connections.values.first(where: {
                $0.profileKey == profileKey && $0.target == normalizedTarget && !$0.revoked && !$0.tombstone
            })
            if let existing {
                guard existing.identityToken == profile.identityToken, existing.modelID == profile.modelID,
                      existing.state != "needs_review", existing.state != "applying",
                      existing.baseURL == scopedBaseURL(root: root, id: existing.id) else {
                    throw error(409, "reconnect_required", "The old connection cannot be retargeted. Explicitly disconnect it, then review a fresh connection plan.")
                }
            }
            let connectionID = existing?.id ?? newIdentifier(prefix: "c")
            let providerID = existing?.providerID ?? "mmx-\(connectionID)"
            // Both qualified native clients map a safe local model alias through its explicit wire id.
            let modelKey = existing?.modelKey ?? modelKey(for: profile.modelID, profileKey: profile.key)
            let baseURL = scopedBaseURL(root: root, id: connectionID)
            var configPath: String?
            var targetVersion: String?
            var fingerprint: String?
            let changes: [String]
            let notes: [String]
            let recovery: String
            if normalizedTarget == "manual" {
                changes = ["Create a protected scoped connection for the selected model."]
                notes = ["Manual app setup does not modify Kilo or OpenCode configuration.", "Use the returned request fields and explicit key action."]
                recovery = "Revoke the scoped route and remove the protected key; no app settings are changed."
            } else {
                let preview = try config.prepare(
                    target: normalizedTarget, providerID: providerID, modelKey: modelKey, modelID: profile.modelID,
                    baseURL: baseURL, keyFile: keyURL(for: connectionID).path, context: profile.context, makeDefault: makeDefault,
                    previousReceipt: try existing?.receiptData.map { try JSONDecoder().decode(ClientConfigReceipt.self, from: $0) }
                )
                configPath = preview.configPath
                targetVersion = preview.targetVersion
                fingerprint = preview.approvalFingerprint
                changes = preview.changes
                notes = preview.notes
                recovery = "Owned provider block and optional default are removed/restored only when hashes and ownership still match."
            }
            let prepared = PreparedPlan(
                id: newIdentifier(prefix: "p"), expiresAt: Date().addingTimeInterval(planLifetime),
                profileKey: profile.key, identityToken: profile.identityToken, target: normalizedTarget,
                connectionID: connectionID, providerID: providerID, modelKey: modelKey, baseURL: baseURL,
                modelID: profile.modelID, makeDefault: makeDefault, context: profile.context,
                configPath: configPath, targetVersion: targetVersion, approvalFingerprint: fingerprint,
                changes: changes, notes: notes, recovery: recovery, used: false
            )
            state.plans = state.plans.filter { !$0.value.used && $0.value.expiresAt > Date() }
            state.plans[prepared.id] = prepared
            try persistState()
            return planPayload(prepared, existing: existing != nil)
        }
    }

    public func apply(planID: String, approved: Bool) throws -> [String: Any] {
        try withThrowingLock {
            try requireStorage()
            guard approved else { throw error(400, "approval_required", "Apply requires explicit approval") }
            try validateIdentifier(planID, field: "plan_id")
            guard var prepared = state.plans[planID] else { throw error(404, "plan_not_found", "Unknown plan") }
            guard !prepared.used else { throw error(409, "plan_replayed", "Plan approval has already been used") }
            guard prepared.expiresAt > Date() else { throw error(409, "plan_expired", "Plan approval has expired") }
            let profile = try requireCurrentProfile(prepared.profileKey)
            guard profile.identityToken == prepared.identityToken, profile.modelID == prepared.modelID,
                  profile.context == prepared.context else {
                throw error(409, "profile_changed", "Profile source or approved model facts changed; review a new plan")
            }
            let root = try requireRelayRoot()
            guard scopedBaseURL(root: root, id: prepared.connectionID) == prepared.baseURL else {
                throw error(409, "relay_changed", "Relay address changed since approval; review a new plan")
            }
            let existing = state.connections[prepared.connectionID]
            if let existing {
                _ = try requireActiveRecord(existing.id)
                try requireIdentity(existing, current: profile)
                guard existing.target == prepared.target, existing.providerID == prepared.providerID,
                      existing.modelKey == prepared.modelKey, existing.baseURL == prepared.baseURL else {
                    throw error(409, "connection_changed", "Connection binding changed; review a new plan")
                }
            }
            guard !state.connections.values.contains(where: {
                $0.id != prepared.connectionID && $0.profileKey == prepared.profileKey && $0.target == prepared.target && !$0.revoked && !$0.tombstone
            }) else {
                throw error(409, "connection_exists", "Another reviewed plan created this connection; review its existing binding")
            }
            // Re-preflight is necessary, but MUST match the originally reviewed snapshot before any write.
            let preview: ClientConfigPreview?
            if prepared.target == "manual" {
                preview = nil
            } else {
                guard let approvedFingerprint = prepared.approvalFingerprint, !approvedFingerprint.isEmpty else {
                    throw error(409, "approval_snapshot_missing", "This legacy plan has no approval snapshot; review a new plan")
                }
                let fresh = try config.prepare(
                    target: prepared.target, providerID: prepared.providerID, modelKey: prepared.modelKey,
                    modelID: prepared.modelID, baseURL: prepared.baseURL, keyFile: keyURL(for: prepared.connectionID).path,
                    context: prepared.context, makeDefault: prepared.makeDefault,
                    previousReceipt: try existing?.receiptData.map { try JSONDecoder().decode(ClientConfigReceipt.self, from: $0) }
                )
                guard fresh.configPath == prepared.configPath, fresh.targetVersion == prepared.targetVersion,
                      fresh.approvalFingerprint == approvedFingerprint else {
                    throw error(409, "approval_snapshot_changed", "Client configuration or target identity changed since approval; review a new plan")
                }
                preview = fresh
            }
            let operationID = newIdentifier(prefix: "op")
            var record = existing ?? ConnectionRecord(
                id: prepared.connectionID, profileKey: profile.key, profile: profile.profile, displayName: profile.displayName,
                modelID: prepared.modelID, runtime: profile.runtime, host: profile.host, identityToken: prepared.identityToken,
                target: prepared.target, providerID: prepared.providerID, modelKey: prepared.modelKey, baseURL: prepared.baseURL,
                state: "applying", configured: false, apiTested: false, clientVerified: false,
                reloadRequired: prepared.target != "manual", readiness: profile.readiness, context: prepared.context,
                configPath: prepared.configPath, message: nil, operationID: operationID, createdAt: Date().timeIntervalSince1970,
                revoked: false, tombstone: false, trafficObserved: 0, successfulTraffic: 0, receiptData: nil
            )
            record.profile = profile.profile
            record.displayName = profile.displayName
            record.runtime = profile.runtime
            record.host = profile.host
            record.readiness = profile.readiness
            record.operationID = operationID
            record.state = "applying"
            record.apiTested = false
            record.clientVerified = false
            prepared.used = true
            state.plans[planID] = prepared
            state.connections[record.id] = record
            try appendJournal(OperationEntry(operationID: operationID, connectionID: record.id, kind: "apply", phase: "started", at: Date().timeIntervalSince1970))
            try persistState()
            do {
                try ensureKey(for: record.id)
                if let preview {
                    let previousReceipt = try decodeReceipt(record.receiptData)
                    let freshReceipt = try config.apply(preview, operationID: operationID)
                    let receipt = preservingPriorDefault(freshReceipt, previous: previousReceipt)
                    record.receiptData = try JSONEncoder().encode(receipt)
                    record.configPath = receipt.configPath
                    record.configured = try config.readBack(receipt)
                    record.reloadRequired = true
                    guard record.configured else { throw error(409, "config_readback_failed", "Client configuration needs ownership-aware review after failed read-back") }
                    record.state = "configured"
                    record.message = "Configured and read back; reload is required before client use."
                } else {
                    record.configured = true
                    record.reloadRequired = false
                    record.state = "configured"
                    record.message = "Protected manual connection created."
                }
                state.connections[record.id] = record
                try appendJournal(OperationEntry(operationID: operationID, connectionID: record.id, kind: "apply", phase: "completed", at: Date().timeIntervalSince1970))
                try persistState()
                return ["connection": connectionPayload(record), "operation_id": operationID, "existing": existing != nil]
            } catch {
                // Partial writes/lost receipts must never leave an authorized route alive.
                deleteKey(record.id)
                record.revoked = true
                record.state = "needs_review"
                record.configured = false
                record.apiTested = false
                record.clientVerified = false
                record.message = sanitizedErrorMessage(error)
                state.connections[record.id] = record
                persistOrFailClosed()
                if let typed = error as? ClientConnectionError { throw typed }
                if let typed = error as? ClientConfigError { throw self.error(typed.status, typed.code, typed.message) }
                throw self.error(500, "apply_failed", "Connection apply failed; its route is disabled pending review")
            }
        }
    }

    public func verify(id: String) throws -> [String: Any] {
        let snapshot = try withThrowingLock {
            let record = try requireActiveRecord(id)
            let profile = try requireCurrentProfile(record.profileKey)
            try requireIdentity(record, current: profile)
            guard isReady(profile.readiness) else { throw error(409, "model_unavailable", "Verification does not start models; start the bound profile separately") }
            let root = try requireRelayRoot()
            guard record.baseURL == scopedBaseURL(root: root, id: record.id) else { throw error(409, "relay_changed", "The bound relay address changed; disconnect and review a fresh connection") }
            return VerificationSnapshot(record: record, key: try readKey(id))
        }
        // No registry lock is held here: the real relay calls authorize() on another thread.
        do {
            let models = try verificationRequest(snapshot, suffix: "models", body: nil, timeout: 4)
            let (modelData, modelResponse) = try verificationTransport(models)
            try validateProbeResponse(modelData, modelResponse, request: models, code: "verification_models_failed")
            guard let object = try? JSONSerialization.jsonObject(with: modelData) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]], rows.count == 1,
                  rows[0]["id"] as? String == snapshot.modelID else {
                throw error(502, "verification_models_failed", "Scoped model-list did not return only the bound model ID")
            }
            try withThrowingLock { try requireVerificationSnapshot(snapshot) }
            let body = try JSONSerialization.data(withJSONObject: [
                "model": snapshot.modelID, "messages": [["role": "user", "content": "Reply OK."]],
                "max_tokens": 4, "stream": false
            ])
            let chat = try verificationRequest(snapshot, suffix: "chat/completions", body: body, timeout: 12)
            let (chatData, chatResponse) = try verificationTransport(chat)
            try validateProbeResponse(chatData, chatResponse, request: chat, code: "verification_chat_failed")
            guard let object = try? JSONSerialization.jsonObject(with: chatData) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]], !choices.isEmpty,
                  let message = choices[0]["message"] as? [String: Any], message["content"] is String else {
                throw error(502, "verification_chat_failed", "Relay chat probe did not return a valid nonstreaming chat response")
            }
            return try withThrowingLock {
                try requireVerificationSnapshot(snapshot)
                var record = try requireActiveRecord(id)
                record.apiTested = true
                record.state = record.configured ? "api-tested" : record.state
                record.message = "Authenticated scoped model-list and short chat probes succeeded. This is API-tested, not verified in a client."
                state.connections[id] = record
                try persistState()
                return ["connection": connectionPayload(record), "message": record.message as Any]
            }
        } catch {
            withLock {
                guard var record = state.connections[id], !record.revoked, !record.tombstone,
                      record.operationID == snapshot.operationID else { return }
                record.apiTested = false
                if record.state == "api-tested" { record.state = record.configured ? "configured" : record.state }
                record.message = "API verification failed; no client verification was claimed and no model was started."
                state.connections[id] = record
                persistOrFailClosed()
            }
            if let typed = error as? ClientConnectionError { throw typed }
            throw self.error(502, "verification_failed", "Relay verification failed or timed out; no model was started")
        }
    }

    private struct VerificationSnapshot {
        let id: String
        let profileKey: String
        let identityToken: String
        let modelID: String
        let baseURL: String
        let operationID: String?
        let key: String
        init(record: ConnectionRecord, key: String) {
            id = record.id; profileKey = record.profileKey; identityToken = record.identityToken
            modelID = record.modelID; baseURL = record.baseURL; operationID = record.operationID; self.key = key
        }
    }

    private func requireVerificationSnapshot(_ snapshot: VerificationSnapshot) throws {
        let record = try requireActiveRecord(snapshot.id)
        let profile = try requireCurrentProfile(record.profileKey)
        try requireIdentity(record, current: profile)
        guard record.profileKey == snapshot.profileKey, record.identityToken == snapshot.identityToken,
              record.modelID == snapshot.modelID, record.baseURL == snapshot.baseURL,
              record.operationID == snapshot.operationID, isReady(profile.readiness),
              scopedBaseURL(root: try requireRelayRoot(), id: record.id) == snapshot.baseURL else {
            throw error(409, "verification_binding_changed", "Connection changed during verification; its result was discarded")
        }
    }

    private func verificationRequest(_ snapshot: VerificationSnapshot, suffix: String, body: Data?, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: joinURL(snapshot.baseURL, suffix)) else { throw error(503, "relay_unavailable", "Invalid relay address") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(snapshot.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func validateProbeResponse(_ data: Data, _ response: HTTPURLResponse, request: URLRequest, code: String) throws {
        guard (200..<300).contains(response.statusCode), response.url == request.url, data.count <= 1_048_576 else {
            throw error(502, code, "The authenticated relay probe failed; response bodies and credentials are not disclosed")
        }
    }

    public func disconnect(id: String, removeConfig: Bool, approved: Bool) throws -> [String: Any] {
        try withThrowingLock {
            guard approved else { throw error(400, "approval_required", "Disconnect requires explicit approval") }
            // Cleanup is allowed for interrupted/revoked records; it never restores a credential.
            var record = try requireRecord(id)
            let operationID = newIdentifier(prefix: "op")
            // Revoke first. A failed config transaction must never leave an authenticated route/key live.
            deleteKey(id)
            record.revoked = true
            record.tombstone = true
            record.state = "disconnected"
            record.configured = false
            record.apiTested = false
            record.clientVerified = false
            record.operationID = operationID
            record.message = "Scoped route and protected key revoked."
            state.connections[id] = record
            try appendJournal(OperationEntry(operationID: operationID, connectionID: id, kind: "disconnect", phase: "started", at: Date().timeIntervalSince1970))
            try persistState()

            var messages = [record.message!]
            if removeConfig, let receipt = try decodeReceipt(record.receiptData) {
                do {
                    try config.remove(receipt)
                    messages.append("Owned client configuration removed when still conflict-free.")
                } catch {
                    messages.append("Client configuration needs review: \(sanitizedErrorMessage(error))")
                    record.state = "needs_review"
                }
            }
            record.message = messages.joined(separator: " ")
            state.connections[id] = record
            try appendJournal(OperationEntry(operationID: operationID, connectionID: id, kind: "disconnect", phase: "completed", at: Date().timeIntervalSince1970))
            try persistState()
            return ["connection": connectionPayload(record), "message": record.message as Any]
        }
    }

    public func undo(id: String, approved: Bool) throws -> [String: Any] {
        try withThrowingLock {
            guard approved else { throw error(400, "approval_required", "Undo requires explicit approval") }
            var record = try requireRecord(id)
            guard let receipt = try decodeReceipt(record.receiptData) else {
                throw error(409, "undo_unavailable", "No owned configuration transaction is available to undo")
            }
            guard !record.revoked else { throw error(409, "key_revoked", "Undo never restores a revoked connection credential") }
            let operationID = newIdentifier(prefix: "op")
            deleteKey(id)
            record.revoked = true
            record.tombstone = true
            record.configured = false
            record.apiTested = false
            record.clientVerified = false
            record.operationID = operationID
            record.state = "needs_review"
            state.connections[id] = record
            try appendJournal(OperationEntry(operationID: operationID, connectionID: id, kind: "undo", phase: "started", at: Date().timeIntervalSince1970))
            try persistState()
            do {
                try config.undo(receipt)
                record.state = "undone"
                record.message = "Owned configuration undone and scoped key revoked; revoked credentials are never restored."
                state.connections[id] = record
                try appendJournal(OperationEntry(operationID: operationID, connectionID: id, kind: "undo", phase: "completed", at: Date().timeIntervalSince1970))
                try persistState()
                return ["connection": connectionPayload(record), "message": record.message as Any]
            } catch {
                record.message = "Owned configuration needs review; the route and credential remain revoked."
                state.connections[id] = record
                persistOrFailClosed()
                throw self.error(409, "undo_conflict", record.message!)
            }
        }
    }

    public func secret(id: String, approved: Bool) throws -> [String: Any] {
        try withThrowingLock {
            guard approved else { throw error(400, "approval_required", "Secret retrieval requires explicit approval") }
            let record = try requireActiveRecord(id)
            try requireIdentity(record, current: requireCurrentProfile(record.profileKey))
            let key = try readKey(id)
            return [
                "key": key,
                "warning": "Treat this credential as a secret. It is scoped to this connection and is not shown in normal payloads."
            ]
        }
    }

    // MARK: Relay/lifecycle integration

    public func authorize(connectionID: String, apiKey: String?, modelID: String? = nil, listing: Bool) throws -> ClientScopedAuthorization {
        try withThrowingLock {
            try authorizeLocked(connectionID: connectionID, apiKey: apiKey, modelID: modelID, listing: listing)
        }
    }

    /// Records relay traffic independently. It intentionally never turns arbitrary
    /// traffic into the trusted `clientVerified` state.
    public func markClientUse(connectionID: String, successful: Bool) {
        withLock {
            guard storageFailure == nil, var record = state.connections[connectionID], !record.revoked, !record.tombstone,
                  record.state != "needs_review", record.state != "applying",
                  let profile = profilesProvider().first(where: { $0.key == record.profileKey }),
                  profile.identityToken == record.identityToken, profile.modelID == record.modelID else { return }
            record.trafficObserved += 1
            if successful { record.successfulTraffic += 1 }
            state.connections[connectionID] = record
            persistOrFailClosed()
        }
    }

    /// A parent-owned trusted client invocation/report may explicitly mark verification.
    public func markClientVerified(connectionID: String, verified: Bool = true, trusted: Bool = false) throws {
        try withThrowingLock {
            guard trusted else { throw error(403, "trusted_report_required", "Only a trusted client report may mark verification") }
            var record = try requireActiveRecord(connectionID)
            try requireIdentity(record, current: requireCurrentProfile(record.profileKey))
            record.clientVerified = verified
            state.connections[connectionID] = record
            try persistState()
        }
    }

    /// Trusted saves may change source inode/identity, but never the captured wire model ID.
    public func profileChanged(oldKey: String, newKey: String) {
        withLock {
            guard let profile = profilesProvider().first(where: { $0.key == newKey }) else { return }
            for key in Array(state.connections.keys) {
                guard var record = state.connections[key], !record.revoked, record.profileKey == oldKey else { continue }
                if record.modelID != profile.modelID {
                    deleteKey(record.id)
                    record.revoked = true
                    record.state = "needs_review"
                    record.configured = false
                    record.apiTested = false
                    record.clientVerified = false
                    record.message = "The profile wire model ID changed. The old route was revoked; explicitly disconnect and review a fresh connection."
                } else {
                    record.profileKey = newKey
                    record.profile = profile.profile
                    record.displayName = profile.displayName
                    record.runtime = profile.runtime
                    record.host = profile.host
                    record.identityToken = profile.identityToken
                    record.readiness = profile.readiness
                    record.context = profile.context
                    record.apiTested = false
                    record.clientVerified = false
                    if record.state == "api-tested" { record.state = "configured" }
                }
                state.connections[key] = record
            }
            persistOrFailClosed()
        }
    }

    public func profileDeleted(key: String) {
        withLock {
            for id in Array(state.connections.keys) {
                guard var record = state.connections[id], record.profileKey == key, !record.tombstone else { continue }
                deleteKey(id)
                record.revoked = true
                record.tombstone = true
                record.state = "revoked"
                record.configured = false
                record.apiTested = false
                record.clientVerified = false
                record.message = "Profile deleted; connection was tombstoned and its key revoked."
                state.connections[id] = record
            }
            persistOrFailClosed()
        }
    }

    // MARK: Locked implementation

    private func authorizeLocked(connectionID: String, apiKey: String?, modelID: String?, listing: Bool) throws -> ClientScopedAuthorization {
        let record = try requireActiveRecord(connectionID)
        let profile = try requireCurrentProfile(record.profileKey)
        try requireIdentity(record, current: profile)
        guard let supplied = apiKey, supplied.utf8.count == 64 else { throw error(401, "api_key_required", "A valid connection key is required") }
        let expected = try readKey(connectionID)
        guard constantTimeEqual(supplied, expected) else { throw error(401, "invalid_api_key", "Invalid connection key") }
        if !listing && (modelID == nil || modelID?.isEmpty == true) {
            throw error(400, "model_required", "Inference requires the exact bound model ID")
        }
        guard modelID == nil || modelID == record.modelID else { throw error(409, "model_mismatch", "Requested model is not bound to this connection") }
        if !listing && !isReady(profile.readiness) { throw error(409, "model_unavailable", "Inference is unavailable while the bound profile is not ready") }
        guard record.baseURL == scopedBaseURL(root: try requireRelayRoot(), id: record.id) else {
            throw error(409, "relay_changed", "The bound relay address changed; disconnect and review a fresh connection")
        }
        // Authorization and model-list are read-only; completion accounting is markClientUse's job.
        return ClientScopedAuthorization(profile: profile, modelID: record.modelID, clientID: record.id, clientLabel: targetLabel(record.target))
    }

    private func requireCurrentProfile(_ key: String) throws -> ClientConnectionProfile {
        guard let profile = profilesProvider().first(where: { $0.key == key }) else {
            throw error(404, "profile_not_found", "Unknown profile: \(key)")
        }
        guard validProfileKey(profile.key), !profile.modelID.isEmpty else {
            throw error(422, "invalid_profile", "Profile key and model ID are required")
        }
        return profile
    }

    private func validProfileKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, (parts[0] == "local" || parts[0] == "remote") else { return false }
        if parts[0] == "local" && parts.count != 2 { return false }
        guard parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }}) else { return false }
        return true
    }

    private func requireRecord(_ id: String) throws -> ConnectionRecord {
        try requireStorage()
        try validateIdentifier(id, field: "id")
        guard let record = state.connections[id] else { throw error(404, "connection_not_found", "Unknown connection") }
        return record
    }

    private func requireActiveRecord(_ id: String) throws -> ConnectionRecord {
        let record = try requireRecord(id)
        guard !record.revoked && !record.tombstone else { throw error(410, "connection_revoked", "Connection is revoked") }
        guard record.state != "needs_review" && record.state != "applying" else {
            throw error(409, "connection_needs_review", "Connection is disabled pending ownership-aware review")
        }
        return record
    }

    private func requireIdentity(_ record: ConnectionRecord, current profile: ClientConnectionProfile) throws {
        guard record.identityToken == profile.identityToken, record.modelID == profile.modelID else {
            throw error(409, "profile_identity_changed", "The bound profile source changed. Explicitly disconnect it and review a fresh connection; old IDs cannot be retargeted")
        }
    }

    private func normalizedTarget(_ target: String) throws -> String {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["kilo", "opencode", "manual"].contains(value) else { throw error(400, "invalid_target", "Target must be kilo, opencode, or manual") }
        return value
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            throw error(400, "invalid_identifier", "Invalid \(field)")
        }
    }

    private func ensureKey(for id: String) throws {
        try validateIdentifier(id, field: "id")
        let url = keyURL(for: id)
        if try readProtected(url, maximumSize: 128, allowMissing: true) != nil {
            _ = try readKey(id) // Invalid old binary keys are not silently replaced or rotated.
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw error(500, "random_failed", "Could not generate a connection credential")
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        try writeProtected(Data(key.utf8), to: url)
        guard try readKey(id) == key else { throw error(500, "key_readback_failed", "Protected credential read-back failed") }
    }

    private func readKey(_ id: String) throws -> String {
        let url = keyURL(for: id)
        guard let data = try readProtected(url, maximumSize: 128, allowMissing: true),
              let raw = String(data: data, encoding: .ascii) else {
            throw error(410, "key_revoked", "Connection credential is unavailable")
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw error(409, "invalid_key_file", "The protected credential is invalid; disconnect and review a fresh connection instead of rotating it")
        }
        return key
    }

    private func deleteKey(_ id: String) {
        guard (try? validateIdentifier(id, field: "id")) != nil else { return }
        do {
            let fd = try openDirectory(keyURL(for: id).deletingLastPathComponent(), owned: true)
            defer { Darwin.close(fd) }
            if unlinkat(fd, "\(id).key", 0) != 0 && errno != ENOENT { throw error(500, "storage_failed", "Could not revoke protected credential file") }
            _ = fsync(fd)
        } catch { storageFailure = self.error(500, "storage_failed", "Protected storage requires review; all connections are disabled") }
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        var difference = a.count ^ b.count // Full-width length comparison, never truncated to UInt8.
        for i in 0..<max(a.count, b.count) {
            difference |= Int((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0))
        }
        return difference == 0
    }

    private func preservingPriorDefault(_ fresh: ClientConfigReceipt, previous: ClientConfigReceipt?) -> ClientConfigReceipt {
        guard let previous, previous.makeDefault, previous.configPath == fresh.configPath,
              previous.providerID == fresh.providerID, previous.modelKey == fresh.modelKey,
              fresh.priorDefault == "\(fresh.providerID)/\(fresh.modelKey)" else { return fresh }
        // A repeated configure must not replace the original prior default with our own selection,
        // or lose old default ownership merely because Make default is off on the new review.
        return ClientConfigReceipt(
            configPath: fresh.configPath, target: fresh.target, providerID: fresh.providerID, modelKey: fresh.modelKey,
            operationID: fresh.operationID, backupPath: fresh.backupPath, makeDefault: true,
            expectedOwnedHash: fresh.expectedOwnedHash, priorDefault: previous.priorDefault
        )
    }

    private func decodeReceipt(_ data: Data?) throws -> ClientConfigReceipt? {
        guard let data else { return nil }
        guard let receipt = try? JSONDecoder().decode(ClientConfigReceipt.self, from: data) else {
            throw error(409, "receipt_needs_review", "Owned configuration receipt is unreadable; the revoked route must not be restored")
        }
        return receipt
    }

    private func isReady(_ readiness: String) -> Bool {
        ["ready", "running", "healthy", "available", "loaded", "online"].contains(readiness.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func profilePayload(_ profile: ClientConnectionProfile) -> [String: Any] {
        var payload: [String: Any] = [
            "key": profile.key, "profile": profile.profile, "display_name": profile.displayName,
            "model_id": profile.modelID, "runtime": profile.runtime, "readiness": profile.readiness
        ]
        if let host = profile.host { payload["host"] = host }
        if let context = profile.context { payload["context"] = context }
        return payload
    }

    private func connectionPayload(_ record: ConnectionRecord) -> [String: Any] {
        let current = profilesProvider().first { $0.key == record.profileKey }
        let identityMatches = current.map { $0.identityToken == record.identityToken && $0.modelID == record.modelID } ?? false
        let invalidBinding = !record.revoked && !record.tombstone && (!identityMatches || storageFailure != nil)
        let readiness = current?.readiness ?? "profile_unavailable"
        var row: [String: Any] = [
            "id": record.id, "profile_key": record.profileKey, "profile": record.profile,
            "display_name": identityMatches ? (current?.displayName ?? record.displayName) : record.displayName,
            "model_id": record.modelID, "target": record.target, "provider_id": record.providerID,
            "model_key": record.modelKey, "base_url": record.baseURL,
            "state": invalidBinding ? "needs_review" : record.state,
            "configured": record.configured && !invalidBinding,
            "api_tested": record.apiTested && !invalidBinding,
            "client_verified": record.clientVerified && !invalidBinding,
            "reload_required": record.reloadRequired, "readiness": readiness,
            "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: record.createdAt)),
            "traffic_observed": record.trafficObserved, "successful_traffic": record.successfulTraffic
        ]
        if let configPath = record.configPath { row["config_path"] = configPath }
        if invalidBinding { row["message"] = "Profile source changed or disappeared; disconnect and review a fresh binding." }
        else if let message = record.message { row["message"] = message }
        if let operationID = record.operationID { row["operation_id"] = operationID }
        if let context = identityMatches ? current?.context : record.context { row["context"] = context }
        return row
    }

    private func planPayload(_ plan: PreparedPlan, existing: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "id": plan.id,
            "expires_at": ISO8601DateFormatter().string(from: plan.expiresAt),
            "profile_key": plan.profileKey, "target": plan.target,
            "title": "Connect \(plan.profileKey) to \(plan.target)",
            "provider_id": plan.providerID, "model_key": plan.modelKey,
            "base_url": plan.baseURL, "model_id": plan.modelID,
            "make_default": plan.makeDefault, "credential_storage": "protected_file",
            "changes": plan.changes, "notes": plan.notes, "recovery": plan.recovery,
            "existing": existing
        ]
        if let path = plan.configPath { result["config_path"] = path }
        if let version = plan.targetVersion { result["target_version"] = version }
        return ["plan": result, "existing": existing]
    }

    private func operationPayload(_ operation: OperationEntry) -> [String: Any] {
        ["operation_id": operation.operationID, "connection_id": operation.connectionID, "kind": operation.kind, "phase": operation.phase,
         "at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: operation.at))]
    }

    private func relayRoot(_ relay: ClientRelayState) -> String? {
        guard relay.listening, relay.error == nil,
              var components = URLComponents(string: relay.baseURL),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(components.path), components.url != nil else { return nil }
        // UsageService.relayURL is the legacy /v1 API root; scoped routes are rooted at the server.
        components.path = ""
        return components.string
    }
    private func requireRelayRoot() throws -> String {
        guard let root = relayRoot(relayProvider()) else { throw error(503, "relay_unavailable", "The model API relay is unavailable; no connection URL can be created") }
        return root
    }
    private func scopedBaseURL(root: String, id: String) -> String { joinURL(root, "connections/\(id)/v1") }
    private func serverRoot(_ base: String) -> String {
        guard !base.isEmpty, var components = URLComponents(string: base), components.scheme != nil, components.host != nil else { return "" }
        // Clients adding /v1 themselves must stay on the same protected connection, not the legacy origin.
        var path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" { path = "" }
        else if path.hasSuffix("/v1") { path.removeLast(3) }
        components.percentEncodedPath = path.isEmpty ? "" : "/" + path
        components.query = nil; components.fragment = nil
        return components.string ?? ""
    }
    private func joinURL(_ base: String, _ suffix: String) -> String {
        guard !base.isEmpty else { return "" }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func targetLabel(_ target: String) -> String {
        switch target { case "kilo": return "Kilo"; case "opencode": return "OpenCode"; default: return "Other app" }
    }

    private func modelKey(for modelID: String, profileKey: String) -> String {
        let raw = "\(profileKey)-\(modelID)".lowercased()
        let safe = raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).prefix(80).description.nonEmptyOr("model")
    }
    private func newIdentifier(prefix: String) -> String { "\(prefix)-\(UUID().uuidString.lowercased())" }
    private func keyURL(for id: String) -> URL { directory.appendingPathComponent(keyDirectoryName, isDirectory: true).appendingPathComponent("\(id).key") }

    private func error(_ status: Int, _ code: String, _ message: String) -> ClientConnectionError { ClientConnectionError(status: status, code: code, message: message) }
    private func sanitizedErrorMessage(_ error: Error) -> String {
        if let typed = error as? ClientConnectionError { return typed.message }
        if let typed = error as? ClientConfigError { return typed.message }
        // Never serialize arbitrary thrown descriptions: they can embed requests, headers or config bytes.
        return "Connection operation failed; protected storage or configuration needs review."
    }

    // MARK: Durable storage

    private struct Registry: Codable {
        var version: Int
        var connections: [String: ConnectionRecord] = [:]
        var plans: [String: PreparedPlan] = [:]
        var operations: [OperationEntry] = []
        init(version: Int) { self.version = version }
    }

    private struct ConnectionRecord: Codable {
        let id: String
        var profileKey: String
        var profile: String
        var displayName: String
        let modelID: String
        var runtime: String
        var host: String?
        var identityToken: String
        var target: String
        var providerID: String
        var modelKey: String
        var baseURL: String
        var state: String
        var configured: Bool
        var apiTested: Bool
        var clientVerified: Bool
        var reloadRequired: Bool
        var readiness: String
        var context: Int?
        var configPath: String?
        var message: String?
        var operationID: String?
        let createdAt: TimeInterval
        var revoked: Bool
        var tombstone: Bool
        var trafficObserved: Int
        var successfulTraffic: Int
        var receiptData: Data?
    }

    private struct PreparedPlan: Codable {
        let id: String
        let expiresAt: Date
        let profileKey: String
        let identityToken: String
        let target: String
        let connectionID: String
        let providerID: String
        let modelKey: String
        let baseURL: String
        let modelID: String
        let makeDefault: Bool
        let context: Int?
        let configPath: String?
        let targetVersion: String?
        let approvalFingerprint: String? // Safe source/target metadata only; backward-compatible Codable.
        let changes: [String]
        let notes: [String]
        let recovery: String
        var used: Bool
    }

    private struct OperationEntry: Codable {
        let operationID: String
        let connectionID: String
        let kind: String
        let phase: String
        let at: TimeInterval
    }

    private func requireStorage() throws {
        if let storageFailure { throw storageFailure }
    }

    private func prepareStorage() {
        do {
            let root = try openDirectory(directory, owned: true, create: true, tighten: true)
            defer { Darwin.close(root) }
            let keys = try openDirectory(directory.appendingPathComponent(keyDirectoryName, isDirectory: true), owned: true, create: true, tighten: true)
            Darwin.close(keys)
        } catch {
            storageFailure = self.error(500, "unsafe_storage", "Protected connection storage is unavailable or unsafe")
        }
    }

    private func loadState() {
        withLock {
            guard storageFailure == nil else { return }
            do {
                guard let data = try readProtected(directory.appendingPathComponent(registryName), maximumSize: 4_194_304, allowMissing: true) else { return }
                let decoded = try JSONDecoder().decode(Registry.self, from: data)
                guard (1...stateVersion).contains(decoded.version),
                      decoded.connections.allSatisfy({ $0.key == $0.value.id && (try? validateIdentifier($0.key, field: "id")) != nil }),
                      decoded.plans.allSatisfy({ $0.key == $0.value.id && (try? validateIdentifier($0.value.connectionID, field: "id")) != nil }) else {
                    throw error(500, "invalid_registry", "Connection registry needs review")
                }
                state = decoded
                if decoded.version == 1 {
                    // Version 1's verify only authorized in memory; it is not HTTP test evidence.
                    for id in Array(state.connections.keys) {
                        state.connections[id]?.apiTested = false
                        if state.connections[id]?.state == "api-tested" { state.connections[id]?.state = "configured" }
                    }
                    state.version = stateVersion
                }
            } catch { storageFailure = self.error(500, "invalid_registry", "Connection registry is unreadable or unsafe; no routes are authorized") }
        }
    }

    private func reconcileJournal() {
        withLock {
            guard storageFailure == nil else { return }
            do {
                let data = try readProtected(directory.appendingPathComponent(journalName), maximumSize: 4_194_304, allowMissing: true)
                var started: [String: OperationEntry] = [:]
                if let data {
                    guard let text = String(data: data, encoding: .utf8) else { throw error(500, "invalid_journal", "Connection journal needs review") }
                    for line in text.split(separator: "\n") {
                        let entry = try JSONDecoder().decode(OperationEntry.self, from: Data(line.utf8))
                        if entry.phase == "started" { started[entry.operationID] = entry }
                        else if entry.phase == "completed" { started.removeValue(forKey: entry.operationID) }
                        else { throw error(500, "invalid_journal", "Connection journal needs review") }
                    }
                }
                var changed = false
                for id in Array(state.connections.keys) {
                    guard var record = state.connections[id] else { continue }
                    let interrupted = record.state == "applying" || record.state == "needs_review" || started.values.contains(where: {
                        $0.connectionID == id && $0.operationID == record.operationID
                    })
                    guard interrupted else { continue }
                    deleteKey(id)
                    record.revoked = true
                    record.configured = false
                    record.apiTested = false
                    record.clientVerified = false
                    record.state = "needs_review"
                    record.message = "Interrupted operation requires ownership-aware review; its route and credential are disabled."
                    state.connections[id] = record
                    changed = true
                }
                if changed { try persistState() }
            } catch { storageFailure = self.error(500, "invalid_journal", "Connection recovery needs review; no routes are authorized") }
        }
    }

    private func persistState() throws {
        try requireStorage()
        do {
            let data = try JSONEncoder().encode(state)
            guard data.count <= 4_194_304 else { throw error(500, "registry_limit", "Connection registry reached its protected size limit") }
            try writeProtected(data, to: directory.appendingPathComponent(registryName))
        } catch {
            storageFailure = self.error(500, "storage_failed", "Connection state could not be saved durably; routes are disabled pending review")
            throw storageFailure!
        }
    }

    private func persistOrFailClosed() {
        do { try persistState() }
        catch { storageFailure = self.error(500, "storage_failed", "Connection state could not be saved durably; routes are disabled pending review") }
    }

    private func appendJournal(_ operation: OperationEntry) throws {
        try requireStorage()
        let url = directory.appendingPathComponent(journalName)
        var data = try readProtected(url, maximumSize: 4_194_304, allowMissing: true) ?? Data()
        data.append(try JSONEncoder().encode(operation))
        data.append(10)
        guard data.count <= 4_194_304 else { throw error(500, "journal_limit", "Connection journal reached its protected size limit") }
        try writeProtected(data, to: url)
        state.operations.append(operation)
        if state.operations.count > 128 { state.operations.removeFirst(state.operations.count - 128) }
    }

    // Descriptor-relative traversal avoids both symlink races and Foundation URL parent loops.
    // No URL.deletingLastPathComponent() iteration at root (the original smoke timeout).
    private func openDirectory(_ url: URL, owned: Bool, create: Bool = false, tighten: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw error(500, "unsafe_storage", "Storage requires an absolute file path") }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw error(500, "storage_failed", "Could not open protected storage") }
        do {
            for component in url.path.split(separator: "/") {
                let name = String(component)
                guard name != "." && name != ".." else { throw error(500, "unsafe_storage", "Unsafe storage component") }
                var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw error(500, "storage_failed", "Could not create protected storage") }
                    child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw error(500, "unsafe_storage", "Storage has an unsafe or unavailable path component") }
                Darwin.close(fd)
                fd = child
            }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw error(500, "unsafe_storage", "Unsafe storage directory") }
            if owned {
                guard info.st_uid == geteuid() else { throw error(500, "unsafe_storage", "Storage directory is not owned by the current user") }
                if tighten { guard fchmod(fd, 0o700) == 0 else { throw error(500, "storage_failed", "Could not protect storage directory") } }
                else if info.st_mode & 0o077 != 0 { throw error(500, "unsafe_storage", "Storage directory permissions are unsafe") }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private func validateProtectedDescriptor(_ fd: Int32, maximumSize: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumSize else {
            throw error(500, "unsafe_storage", "Protected file owner, type, links, permissions or size are unsafe")
        }
    }

    private func readProtected(_ url: URL, maximumSize: Int, allowMissing: Bool = false) throws -> Data? {
        let parent = try openDirectory(url.deletingLastPathComponent(), owned: true)
        defer { Darwin.close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT && allowMissing { return nil }
        guard fd >= 0 else { throw error(500, "unsafe_storage", "Protected file is unavailable or unsafe") }
        defer { Darwin.close(fd) }
        try validateProtectedDescriptor(fd, maximumSize: maximumSize)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw error(500, "storage_failed", "Could not read protected storage") }
            if count == 0 { break }
            guard result.count + count <= maximumSize else { throw error(500, "unsafe_storage", "Protected file exceeds its size limit") }
            result.append(contentsOf: buffer.prefix(count))
        }
        try validateProtectedDescriptor(fd, maximumSize: maximumSize)
        return result
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent(), owned: true)
        defer { Darwin.close(parent) }
        // Refuse unsafe existing files instead of replacing links, foreign files, FIFOs, or broad permissions.
        let old = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if old >= 0 {
            defer { Darwin.close(old) }
            try validateProtectedDescriptor(old, maximumSize: 4_194_304)
        } else if errno != ENOENT { throw error(500, "unsafe_storage", "Unsafe destination file") }
        let name = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error(500, "storage_failed", "Could not stage protected storage") }
        defer { Darwin.close(fd); _ = unlinkat(parent, name, 0) }
        try validateProtectedDescriptor(fd, maximumSize: 4_194_304)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error(500, "storage_failed", "Could not write protected storage") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(parent, name, parent, url.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw error(500, "storage_failed", "Could not commit protected storage") }
        guard try readProtected(url, maximumSize: 4_194_304) == data else { throw error(500, "storage_failed", "Protected storage read-back failed") }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
    private func withThrowingLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}


/// One bounded, credential-isolated synchronous request. Redirects are rejected rather than
/// forwarding a scoped credential elsewhere, response bytes are never logged or retained.
private final class ScopedVerificationRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var failed = false

    static func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let delegate = ScopedVerificationRequest()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        guard delegate.done.wait(timeout: .now() + request.timeoutInterval + 1) == .success else {
            task.cancel()
            throw ClientConnectionError(status: 504, code: "verification_timeout", message: "Relay verification timed out; no model was started")
        }
        delegate.lock.lock(); defer { delegate.lock.unlock() }
        guard !delegate.failed, let response = delegate.response else {
            throw ClientConnectionError(status: 502, code: "verification_transport_failed", message: "Relay verification transport failed; credentials and response bodies are not disclosed")
        }
        return (delegate.bytes, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); failed = true; lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let oversized = response.expectedContentLength > 1_048_576
        if oversized || self.response == nil { failed = true }
        lock.unlock()
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = bytes.count + data.count > 1_048_576
        if oversized { failed = true } else { bytes.append(data) }
        lock.unlock()
        if oversized { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if error != nil { failed = true }; lock.unlock()
        done.signal()
    }
}
