import Darwin
import Foundation
import Network

/// No decoded/normalised path can escape into the legacy fallback router.
struct ScopedModelRoute: Equatable {
    let connectionID: String
    let endpoint: String

    static func isReserved(_ path: String) -> Bool {
        // This listener is an origin server, not a forward proxy. Absolute-form
        // and other non-origin targets must never enter legacy model resolution.
        guard path.hasPrefix("/") else { return true }
        var candidate = path
        for _ in 0..<8 {
            let literal = candidate.lowercased()
            if literal == "/connections" || literal.hasPrefix("/connections/") { return true }
            // Classify forms an intermediary may normalize, but only parse the
            // original canonical protected path. Malformed forms get a 404.
            var segments: [String] = []
            for part in candidate.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !segments.isEmpty { segments.removeLast() }; continue }
                segments.append(part.lowercased())
            }
            if segments.first == "connections" { return true }
            guard candidate.contains("%") else { return false }
            guard let decoded = candidate.removingPercentEncoding, decoded != candidate else { return true }
            candidate = decoded
        }
        // Decode work is bounded. Exhaustion is a rejection, never a fallback.
        return true
    }

    static func parse(_ path: String) -> ScopedModelRoute? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[0].isEmpty, parts[1] == "connections", parts[3] == "v1" else { return nil }
        let id = String(parts[2])
        guard id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { return nil }
        let endpoint = "/v1/" + parts.dropFirst(4).joined(separator: "/")
        guard ["/v1/models", "/v1/chat/completions", "/v1/completions"].contains(endpoint) else { return nil }
        return ScopedModelRoute(connectionID: id, endpoint: endpoint)
    }
}

extension RelayConnection {
    func dispatchScoped(_ original: RelayRequest) {
        guard let route = ScopedModelRoute.parse(original.path) else {
            respond(status: 404, message: "Unknown protected connection endpoint.")
            return
        }
        let listing = route.endpoint == "/v1/models"
        guard original.method == (listing ? "GET" : "POST") else {
            respond(status: 405, message: "Use GET for model-list and POST for inference.")
            return
        }
        guard let registry = usage.clientConnections else {
            respond(status: 503, message: "ModelMatrix connections are unavailable.")
            return
        }
        let authHeaders = original.headerLines.filter { $0.0.lowercased() == "authorization" }
        let raw = authHeaders.count == 1 ? authHeaders.first?.1 : nil
        let key = raw?.hasPrefix("Bearer ") == true ? String(raw!.dropFirst(7)) : nil
        var model: String?
        var object: [String: Any]?
        if !listing {
            object = (try? JSONSerialization.jsonObject(with: original.body)) as? [String: Any]
            model = object?["model"] as? String
        }
        do {
            let authorization = try registry.authorize(connectionID: route.connectionID, apiKey: key,
                modelID: model, listing: listing)
            if listing {
                respondJSON(status: 200, object: ["object": "list", "data": [[
                    "id": authorization.modelID, "object": "model", "owned_by": "ModelMatrix",
                ]]])
                return
            }
            guard let object, model != nil else {
                respond(status: 400, message: "Send a JSON object with the exact connection Model ID.")
                return
            }
            record = UsageRecord(startedAt: Date().timeIntervalSince1970, endpoint: route.endpoint)
            record.method = original.method
            record.modelRequested = model
            record.profile = authorization.profile.profile
            record.runtime = authorization.profile.runtime
            record.host = authorization.profile.host ?? "local"
            record.stream = object["stream"] as? Bool ?? false
            record.clientID = authorization.clientID
            record.clientLabel = authorization.clientLabel
            scopedConnectionID = route.connectionID
            promptCharacters = Self.promptCharacters(object)
            metered = true
            inflightID = usage.beginInflight(record)
            var request = original
            request.target = route.endpoint
            // A connection credential identifies its route, never the upstream engine.
            request.headerLines.removeAll { $0.0.lowercased() == "authorization" || $0.0.lowercased() == "x-api-key" }
            request.headers["authorization"] = nil
            request.headers["x-api-key"] = nil
            if authorization.profile.key.hasPrefix("remote:") {
                try connectRemote(authorization: authorization, request: request)
            } else {
                guard let target = exactLocalTarget(authorization.profile), target.ready else {
                    respond(status: 503, message: "The bound model is not ready. Start it in ModelMatrix.")
                    return
                }
                if let upstreamModel = target.upstreamModel,
                   let rewritten = Self.replacingModel(in: request.body, with: upstreamModel) {
                    request.body = rewritten
                }
                connectUpstream(target: target, request: request)
            }
        } catch let failure as ClientConnectionError {
            respond(status: failure.status, message: failure.message)
        } catch {
            respond(status: 502, message: "Could not reach this connection's bound model.")
        }
    }

    private func exactLocalTarget(_ selected: ClientConnectionProfile) -> RelayTarget? {
        guard let service = usage.service else { return nil }
        return service.withMutationLock {
            guard let source = service.profileFile(named: selected.profile) else { return nil }
            var identity = stat()
            guard lstat(source.path, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG,
                  selected.identityToken == "\(identity.st_dev):\(identity.st_ino):\(identity.st_birthtimespec.tv_sec):\(identity.st_birthtimespec.tv_nsec)" else { return nil }
            guard let profile = try? service.profiles.profile(named: selected.profile),
                  profile.requestModel == selected.modelID,
                  let status = try? service.statusPayload(selected: [selected.profile]).statuses.first,
                  status.ready else { return nil }
            return RelayTarget.from(status: status, profile: profile, activeProfile: nil)
        }
    }

    private func connectRemote(authorization: ClientScopedAuthorization, request: RelayRequest) throws {
        let pieces = authorization.profile.key.split(separator: ":", maxSplits: 2).map(String.init)
        guard pieces.count == 3, let bridge = usage.connectionBridge, bridge.appConnected,
              let gateway = bridge.gateway(id: pieces[1]), gateway.enabled else {
            throw ClientConnectionError(status: 503, code: "host_unavailable", message: "The model's host is unavailable.")
        }
        var base = gateway.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard var parts = URLComponents(string: base + "/api/connect/inference"),
              ["http", "https"].contains(parts.scheme ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil else {
            throw ClientConnectionError(status: 503, code: "host_unavailable", message: "The model's host address is invalid.")
        }
        parts.queryItems = [URLQueryItem(name: "profile", value: authorization.profile.profile),
            URLQueryItem(name: "endpoint", value: request.path),
            URLQueryItem(name: "identity", value: authorization.profile.identityToken)]
        guard let url = parts.url else { return }
        var outgoing = URLRequest(url: url, timeoutInterval: 1800)
        outgoing.httpMethod = "POST"
        outgoing.httpBody = request.body
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        outgoing.setValue("ModelMatrix-Connection", forHTTPHeaderField: "User-Agent")
        if let token = gateway.token { outgoing.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [:]
        settings.httpShouldSetCookies = false
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = 1800
        settings.timeoutIntervalForResource = 1800
        let delegate = RemoteConnectionStream(owner: self)
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: settings, delegate: delegate, delegateQueue: callbacks)
        remoteSession = session
        remoteTask = session.dataTask(with: outgoing)
        armIdleTimer()
        remoteTask?.resume()
    }

    func remoteResponse(status: Int, contentType: String) {
        guard !finished else { return }
        let safeType = contentType.contains("\r") || contentType.contains("\n") ? "application/json" : contentType
        let head = Data("HTTP/1.1 \(status) Response\r\nContent-Type: \(safeType)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        let bytes = process(upstreamData: head)
        client.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(status: 499) }
        })
    }

    func remoteBytes(_ data: Data) {
        guard !finished else { return }
        pendingRemoteWrites += 1
        remoteTask?.suspend()
        armIdleTimer()
        let bytes = process(upstreamData: data)
        client.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingRemoteWrites -= 1
            if error != nil {
                self.finish(status: 499)
            } else if self.remoteCompleted && self.pendingRemoteWrites == 0 {
                self.finish(status: self.record.status)
            } else {
                self.remoteTask?.resume()
            }
        })
    }

    func remoteDone(failed: Bool) {
        guard !finished else { return }
        remoteCompleted = true
        if failed { record.error = "the remote model connection failed"; record.status = 502 }
        if !responseStarted {
            respond(status: 502, message: "The remote model did not answer.")
        } else if pendingRemoteWrites == 0 {
            finish(status: failed ? 502 : record.status)
        }
    }
}

private final class RemoteConnectionStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: RelayConnection?
    init(owner: RelayConnection) { self.owner = owner }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let owner else { completionHandler(.cancel); return }
        let status = response.statusCode
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        owner.queue.async { owner.remoteResponse(status: status, contentType: type) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let owner else { dataTask.cancel(); return }
        owner.queue.async { owner.remoteBytes(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let failed = error != nil
        if let owner { owner.queue.async { owner.remoteDone(failed: failed) } }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never send the gateway credential to a redirect destination.
        completionHandler(nil)
    }
}
