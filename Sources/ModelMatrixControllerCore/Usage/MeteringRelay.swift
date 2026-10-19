import Foundation
import Network

/// HTTP request read by the relay (raw header lines preserved).
struct RelayRequest {
    var method: String
    var target: String
    var headerLines: [(String, String)]
    var headers: [String: String]
    var body: Data

    var path: String {
        let end = target.firstIndex(of: "?") ?? target.endIndex
        return String(target[..<end])
    }
}

/// Listens for OpenAI / Ollama API calls, forwards them byte-for-byte to the
/// right model server, and records usage from a tap copy of the response.
public final class MeteringRelay: @unchecked Sendable {
    public let port: UInt16
    let host: String
    /// When set, every request on this listener goes to this target (capture mode).
    let fixedTarget: (@Sendable () -> RelayTarget?)?
    weak var usage: UsageService?
    var listener: NWListener?
    let queue: DispatchQueue
    public private(set) var lastError: String?
    public private(set) var isListening = false

    static let maximumBodyBytes = 64 * 1024 * 1024
    static let maximumHeaderBytes = 64 * 1024

    init(host: String = "127.0.0.1", port: UInt16, usage: UsageService,
         fixedTarget: (@Sendable () -> RelayTarget?)? = nil) {
        self.host = host
        self.port = port
        self.usage = usage
        self.fixedTarget = fixedTarget
        self.queue = DispatchQueue(label: "io.github.hackstar1337.modelmatrix.relay.\(port)")
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, let usage = self.usage else {
                connection.cancel()
                return
            }
            RelayConnection(client: connection, relay: self, usage: usage).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isListening = true
                self.lastError = nil
            case .failed(let error):
                self.isListening = false
                self.lastError = "\(error)"
                FileHandle.standardError.write(Data("relay :\(self.port) failed: \(error)\n".utf8))
            case .cancelled:
                self.isListening = false
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }
}

final class RelayConnection: @unchecked Sendable {
    let client: NWConnection
    let relay: MeteringRelay
    let usage: UsageService
    let queue: DispatchQueue
    var buffer = Data()
    var upstream: NWConnection?
    var record: UsageRecord
    var analyzer: UsageAnalyzer?
    var metered = false
    var inflightID: String?
    var promptCharacters = 0
    var responseStarted = false
    var responseHead = Data()
    var chunked: ChunkedDecoder?
    var remainingBody: Int?
    var bodyComplete = false
    var finished = false
    var sentContinue = false
    var upstreamSettled = false
    var idleTimer: DispatchWorkItem?

    init(client: NWConnection, relay: MeteringRelay, usage: UsageService) {
        self.client = client
        self.relay = relay
        self.usage = usage
        self.queue = DispatchQueue(
            label: "io.github.hackstar1337.modelmatrix.relay.connection",
            target: .global(qos: .userInitiated))
        self.record = UsageRecord(startedAt: Date().timeIntervalSince1970, endpoint: "")
    }

    func start() {
        // The client's state handler holds this object until the socket is
        // cancelled; every completion path ends with `client.cancel()`.
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .cancelled:
                idleTimer?.cancel()
                upstream?.cancel()
                if !finished, metered {
                    record.error = record.error ?? "client closed the connection"
                    finish(status: 499)
                }
                client.stateUpdateHandler = nil
            case .failed:
                client.cancel()
            default:
                break
            }
        }
        client.start(queue: queue)
        readRequest()
    }

    // MARK: - Request

    func readRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            switch parseRequest() {
            case .some(.success(let request)):
                dispatch(request)
            case .some(.failure(let failure)):
                respond(status: failure.status, message: failure.message)
            case .none:
                if complete || error != nil {
                    client.cancel()
                } else {
                    readRequest()
                }
            }
        }
    }

    struct Failure: Error {
        let status: Int
        let message: String
    }

    func parseRequest() -> Result<RelayRequest, Failure>? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > MeteringRelay.maximumHeaderBytes {
                return .failure(Failure(status: 431, message: "request headers too large"))
            }
            return nil
        }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return .failure(Failure(status: 400, message: "invalid request line"))
        }
        var headerLines: [(String, String)] = []
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headerLines.append((name, value))
            headers[name.lowercased()] = value
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer[bodyStart...]
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            if headers["expect"]?.lowercased() == "100-continue" { sendContinueOnce() }
            var decoder = ChunkedDecoder()
            body = decoder.feed(Data(available))
            if body.count > MeteringRelay.maximumBodyBytes {
                return .failure(Failure(status: 413, message: "request body too large"))
            }
            guard decoder.isComplete else { return nil }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .failure(Failure(status: 400, message: "invalid Content-Length")) }
            if length > MeteringRelay.maximumBodyBytes {
                return .failure(Failure(status: 413, message: "request body too large"))
            }
            if available.count < length {
                if headers["expect"]?.lowercased() == "100-continue" { sendContinueOnce() }
                return nil
            }
            body = Data(available.prefix(length))
        }
        return .success(
            RelayRequest(
                method: String(requestLine[0]).uppercased(), target: String(requestLine[1]),
                headerLines: headerLines, headers: headers, body: body))
    }

    func sendContinueOnce() {
        guard !sentContinue else { return }
        sentContinue = true
        client.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
    }

    // MARK: - Dispatch

    func dispatch(_ request: RelayRequest) {
        let path = request.path
        // DNS-rebinding guard: a loopback relay only answers loopback names.
        // The upstream Host header is rewritten, so without this check a
        // rebound web page could bypass a model server's own Host checks.
        if Self.rejectsHost(request.headers["host"], relayHost: relay.host) {
            respond(status: 403, message: "Requests to the relay must be addressed to localhost.")
            return
        }
        record = UsageRecord(startedAt: Date().timeIntervalSince1970, endpoint: path)
        record.method = request.method
        var model: String?
        var stream = false
        if !request.body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        {
            model = object["model"] as? String
            if let value = object["stream"] as? Bool {
                stream = value
            } else if ["/api/chat", "/api/generate"].contains(path) {
                stream = true  // Ollama streams unless told otherwise.
            }
            promptCharacters = Self.promptCharacters(object)
        }
        let fixed = relay.fixedTarget
        if fixed == nil {
            if request.method == "GET", path == "/v1/models" || path == "/models" {
                respondJSON(status: 200, object: usage.relayModelList())
                return
            }
            if request.method == "GET", path == "/" || path == "/health" {
                respondJSON(
                    status: 200,
                    object: ["status": "ok", "service": "modelmatrix-relay", "port": Int(relay.port)])
                return
            }
        }
        metered = RelayRouting.isMetered(method: request.method, path: path)
        record.modelRequested = model
        record.stream = stream
        let target: RelayTarget?
        if let fixed {
            target = fixed()
        } else {
            target = RelayRouting.resolve(model: model, path: path, targets: usage.relayTargets())
        }
        guard let target else {
            if fixed != nil {
                client.cancel()
                return
            }
            respond(
                status: 503,
                message: model.map { "No running model server answers to \($0). Start a profile in ModelMatrix." }
                    ?? "No model server is running. Start a profile in ModelMatrix.")
            return
        }
        record.profile = target.profile
        record.runtime = target.runtime
        record.modelRequested = model
        record.stream = stream
        record.host = "local"
        let identity = ClientIdentity.label(headers: request.headers)
        var process: String?
        if !identity.explicit, case .hostPort(_, let remotePort) = client.endpoint {
            process = ClientIdentity.processName(
                forLocalPort: remotePort.rawValue,
                cacheKey: request.headers["user-agent"] ?? "port-\(remotePort.rawValue)")
        }
        var label = identity.label
        if !identity.explicit, let process, ["Unknown client", "Python (httpx)", "Node.js"].contains(label) {
            label = process == label ? label : "\(process)"
        }
        record.clientLabel = label
        record.clientProcess = process
        record.clientID = ClientIdentity.identifier(label: label, process: process)
        if metered {
            inflightID = usage.beginInflight(record)
        }
        var request = request
        if let upstreamModel = target.upstreamModel, let model, model != upstreamModel,
            let rewritten = Self.replacingModel(in: request.body, with: upstreamModel)
        {
            request.body = rewritten
        }
        connectUpstream(target: target, request: request)
    }

    /// The request body with its "model" replaced (nil if it has none).
    static func replacingModel(in body: Data, with name: String) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            object["model"] is String
        else { return nil }
        object["model"] = name
        return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static func rejectsHost(_ raw: String?, relayHost: String) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        guard DashboardRequestGuard.isLoopbackName(relayHost) else { return false }
        return !DashboardRequestGuard.isLoopbackName(DashboardRequestGuard.hostName(fromHostHeader: raw))
    }

    static func promptCharacters(_ object: [String: Any]) -> Int {
        var total = 0
        if let messages = object["messages"] as? [[String: Any]] {
            for message in messages {
                if let content = message["content"] as? String {
                    total += content.count
                } else if let parts = message["content"] as? [[String: Any]] {
                    for part in parts { total += (part["text"] as? String)?.count ?? 0 }
                }
            }
        }
        if let prompt = object["prompt"] as? String { total += prompt.count }
        if let input = object["input"] as? String { total += input.count }
        if let inputs = object["input"] as? [String] { total += inputs.reduce(0) { $0 + $1.count } }
        if let system = object["system"] as? String { total += system.count }
        return total
    }

    // MARK: - Upstream

    func connectUpstream(target: RelayTarget, request: RelayRequest) {
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!, using: .tcp)
        upstream = connection
        let isCapture = relay.fixedTarget != nil
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.upstreamSettled else { return }
            self.upstreamSettled = true
            connection.cancel()
            self.upstreamFailed(isCapture: isCapture, message: "model server did not accept the connection")
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.upstreamSettled else { return }
                self.upstreamSettled = true
                self.sendUpstream(request: request, target: target)
            case .waiting, .failed:
                guard !self.upstreamSettled else { return }
                self.upstreamSettled = true
                connection.cancel()
                self.upstreamFailed(isCapture: isCapture, message: "could not reach \(target.displayName)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func upstreamFailed(isCapture: Bool, message: String) {
        if isCapture {
            // Behave like a closed port so health checks see the runtime as down.
            usage.endInflight(inflightID)
            finished = true
            client.cancel()
            return
        }
        record.status = 502
        record.error = message
        respond(status: 502, message: message)
    }

    static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "upgrade",
        "content-length", "host", "accept-encoding", "expect", "trailer",
    ]

    func sendUpstream(request: RelayRequest, target: RelayTarget) {
        let path = RelayRouting.upstreamPath(for: request.target, server: target)
        var head = "\(request.method) \(path) HTTP/1.1\r\n"
        head += "Host: \(target.host):\(target.port)\r\n"
        for (name, value) in request.headerLines where !Self.hopByHop.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method) {
            head += "Content-Length: \(request.body.count)\r\n"
        }
        head += "Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
        var message = Data(head.utf8)
        message.append(request.body)
        upstream?.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.upstreamFailed(isCapture: self.relay.fixedTarget != nil, message: "failed to send request")
                return
            }
            self.readUpstream()
        })
    }

    func armIdleTimer() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.record.error = "model server stopped responding"
            self.finish(status: self.record.status == 0 ? 504 : self.record.status)
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + 1800, execute: item)
    }

    func readUpstream() {
        armIdleTimer()
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                let outgoing = self.process(upstreamData: data)
                let done = self.bodyComplete
                self.client.send(content: outgoing, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.record.error = "client closed the connection"
                        self.finish(status: 499)
                    } else if done || complete || error != nil {
                        self.finish(status: self.record.status)
                    } else {
                        self.readUpstream()
                    }
                })
                return
            }
            if complete || error != nil {
                if !self.responseStarted {
                    self.upstreamFailed(isCapture: self.relay.fixedTarget != nil, message: "empty reply from model server")
                } else {
                    self.finish(status: self.record.status)
                }
            } else {
                self.readUpstream()
            }
        }
    }

    /// Returns the bytes to forward to the client (head rewritten once).
    func process(upstreamData data: Data) -> Data {
        let now = Date().timeIntervalSince1970
        if responseStarted {
            tap(data, at: now)
            return data
        }
        responseHead.append(data)
        guard let end = responseHead.range(of: Data("\r\n\r\n".utf8)) else {
            if responseHead.count > MeteringRelay.maximumHeaderBytes {
                responseStarted = true
                return responseHead
            }
            return Data()
        }
        responseStarted = true
        let headText = String(decoding: responseHead[responseHead.startIndex..<end.lowerBound], as: UTF8.self)
        let rest = Data(responseHead[end.upperBound...])
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        record.status = status
        var contentType: String?
        var rewritten = statusLine + "\r\n"
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "connection", "keep-alive":
                continue
            case "content-type":
                contentType = value
            case "content-length":
                remainingBody = Int(value)
            case "transfer-encoding":
                if value.lowercased().contains("chunked") { chunked = ChunkedDecoder() }
            default:
                break
            }
            rewritten += line + "\r\n"
        }
        if chunked != nil { remainingBody = nil }
        rewritten += "Connection: close\r\n\r\n"
        analyzer = UsageAnalyzer(contentType: contentType, requestStream: record.stream, startedAt: record.startedAt)
        if record.method == "HEAD" || status == 204 || status == 304 || remainingBody == 0 {
            bodyComplete = true
        }
        tap(rest, at: now)
        var outgoing = Data(rewritten.utf8)
        outgoing.append(rest)
        return outgoing
    }

    func tap(_ data: Data, at time: Double) {
        guard !data.isEmpty else { return }
        var payload = data
        if chunked != nil {
            payload = chunked!.feed(data)
            if chunked!.isComplete { bodyComplete = true }
        } else if let remaining = remainingBody {
            remainingBody = remaining - data.count
            if remainingBody! <= 0 { bodyComplete = true }
        }
        if metered {
            analyzer?.feed(payload, at: time)
            if let inflightID, let analyzer {
                usage.updateInflight(inflightID, chunks: analyzer.contentChunks, firstTokenAt: analyzer.firstTokenAt)
            }
        }
    }

    // MARK: - Completion

    func finish(status: Int) {
        guard !finished else { return }
        finished = true
        idleTimer?.cancel()
        let now = Date().timeIntervalSince1970
        upstream?.cancel()
        client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [client] _ in
            client.cancel()
        })
        guard metered else { return }
        record.status = status
        record.durationMS = (now - record.startedAt) * 1000
        if var analyzer {
            analyzer.finish(at: now)
            let result = analyzer.result(endedAt: now, requestPromptCharacters: promptCharacters)
            record.promptTokens = result.promptTokens
            record.completionTokens = result.completionTokens
            record.tokensEstimated = result.estimated
            record.tokensPerSecond = result.tps
            record.ttftMS = result.ttftMS
            record.modelServed = analyzer.model ?? record.modelRequested
            if record.error == nil, status >= 400 { record.error = analyzer.errorMessage ?? "HTTP \(status)" }
        }
        record.tier =
            RelayRouting.isCloudModel(record.modelServed) || RelayRouting.isCloudModel(record.modelRequested)
            ? "cloud" : "local"
        usage.endInflight(inflightID)
        usage.record(record)
    }

    func respond(status: Int, message: String) {
        let object: [String: Any] = ["error": ["message": message, "type": "modelmatrix_relay", "code": status]]
        respondJSON(status: status, object: object)
        if metered {
            record.status = status
            record.error = message
            record.durationMS = (Date().timeIntervalSince1970 - record.startedAt) * 1000
            usage.endInflight(inflightID)
            usage.record(record)
        }
    }

    func respondJSON(status: Int, object: [String: Any]) {
        finished = true
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let reason = [200: "OK", 400: "Bad Request", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
                      502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"][status] ?? "Error"
        var message = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8)
        message.append(body)
        upstream?.cancel()
        client.send(content: message, completion: .contentProcessed { [client] _ in client.cancel() })
    }
}
