import Foundation

/// Incremental decoder for `Transfer-Encoding: chunked` bodies. Used only on
/// the relay's tap copy and to detect the end of a response; the client
/// always receives the upstream bytes unchanged.
public struct ChunkedDecoder: Sendable {
    enum State: Sendable {
        case size
        case data(Int)
        case dataEnd
        case trailers
        case done
    }

    var state: State = .size
    var pending = Data()
    public private(set) var isComplete = false

    public init() {}

    /// Feeds raw chunked bytes and returns the decoded payload bytes.
    public mutating func feed(_ data: Data) -> Data {
        pending.append(data)
        var output = Data()
        loop: while true {
            switch state {
            case .size:
                guard let range = pending.range(of: Data("\r\n".utf8)) else { break loop }
                let line = String(decoding: pending[pending.startIndex..<range.lowerBound], as: UTF8.self)
                pending = Data(pending[range.upperBound...])
                let sizeText = line.split(separator: ";").first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(sizeText, radix: 16) else {
                    state = .done
                    isComplete = true
                    break loop
                }
                state = size == 0 ? .trailers : .data(size)
            case .data(let remaining):
                if pending.isEmpty { break loop }
                let take = min(remaining, pending.count)
                output.append(pending.prefix(take))
                pending = Data(pending.dropFirst(take))
                state = remaining - take == 0 ? .dataEnd : .data(remaining - take)
            case .dataEnd:
                guard pending.count >= 2 else { break loop }
                pending = Data(pending.dropFirst(2))
                state = .size
            case .trailers:
                guard let range = pending.range(of: Data("\r\n".utf8)) else { break loop }
                let isEmptyLine = range.lowerBound == pending.startIndex
                pending = Data(pending[range.upperBound...])
                if isEmptyLine {
                    state = .done
                    isComplete = true
                }
            case .done:
                break loop
            }
        }
        return output
    }
}

/// Extracts usage numbers from an LLM response while it streams through the relay.
///
/// Understands OpenAI-style SSE (`data: {...}`), Ollama's NDJSON streams,
/// and plain JSON bodies, including llama.cpp `timings` and Ollama's
/// `eval_count` / `eval_duration` fields.
public struct UsageAnalyzer: Sendable {
    public enum Format: Sendable {
        case sse
        case ndjson
        case json
    }

    public let format: Format
    let startedAt: Double
    var lineBuffer = Data()
    var jsonBody = Data()
    static let jsonLimit = 16 * 1024 * 1024

    public private(set) var firstTokenAt: Double?
    public private(set) var firstByteAt: Double?
    public private(set) var model: String?
    public private(set) var promptTokens: Int?
    public private(set) var completionTokens: Int?
    public private(set) var contentChunks = 0
    public private(set) var contentCharacters = 0
    public private(set) var reportedTPS: Double?
    public private(set) var reportedTTFTMS: Double?
    public private(set) var errorMessage: String?

    public init(contentType: String?, requestStream: Bool, startedAt: Double) {
        let type = (contentType ?? "").lowercased()
        if type.contains("text/event-stream") {
            format = .sse
        } else if type.contains("ndjson") || (requestStream && !type.contains("application/json")) {
            format = .ndjson
        } else if requestStream && type.contains("application/json") {
            // Ollama streams NDJSON while labelling it application/json on some versions.
            format = .ndjson
        } else {
            format = .json
        }
        self.startedAt = startedAt
    }

    public mutating func feed(_ data: Data, at time: Double) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = time }
        switch format {
        case .json:
            if jsonBody.count < Self.jsonLimit { jsonBody.append(data) }
            // Some "json" responses are really NDJSON streams; handle lines as they come.
            lineBuffer.append(data)
            drainLines(at: time, sse: false, tolerant: true)
        case .sse:
            lineBuffer.append(data)
            drainLines(at: time, sse: true, tolerant: false)
        case .ndjson:
            lineBuffer.append(data)
            drainLines(at: time, sse: false, tolerant: false)
        }
    }

    public mutating func finish(at time: Double) {
        if !lineBuffer.isEmpty {
            lineBuffer.append(Data("\n".utf8))
            drainLines(at: time, sse: format == .sse, tolerant: format == .json)
        }
        if format == .json, let object = try? JSONSerialization.jsonObject(with: jsonBody) as? [String: Any] {
            absorb(object, at: time, streaming: false)
        }
    }

    mutating func drainLines(at time: Double, sse: Bool, tolerant: Bool) {
        while let range = lineBuffer.range(of: Data("\n".utf8)) {
            var line = Data(lineBuffer[lineBuffer.startIndex..<range.lowerBound])
            lineBuffer = Data(lineBuffer[range.upperBound...])
            if line.last == 13 { line.removeLast() }
            guard !line.isEmpty else { continue }
            if sse {
                guard line.starts(with: Data("data:".utf8)) else { continue }
                var payload = line.dropFirst(5)
                while payload.first == 32 { payload = payload.dropFirst() }
                if payload.elementsEqual(Data("[DONE]".utf8)) { continue }
                if let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] {
                    absorb(object, at: time, streaming: true)
                }
            } else if !tolerant {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    absorb(object, at: time, streaming: true)
                }
            }
        }
        if tolerant, lineBuffer.count > Self.jsonLimit { lineBuffer.removeAll() }
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        return nil
    }

    mutating func noteContent(_ text: String?, at time: Double, streaming: Bool) {
        guard let text, !text.isEmpty else { return }
        if firstTokenAt == nil, streaming { firstTokenAt = time }
        contentChunks += 1
        contentCharacters += text.count
    }

    mutating func absorb(_ object: [String: Any], at time: Double, streaming: Bool) {
        if let value = object["model"] as? String, !value.isEmpty { model = value }
        if let error = object["error"] {
            if let text = error as? String {
                errorMessage = text
            } else if let dict = error as? [String: Any] {
                errorMessage = dict["message"] as? String ?? "error"
            }
        }
        // OpenAI chat / completions.
        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    noteContent(delta["content"] as? String, at: time, streaming: streaming)
                    noteContent(delta["reasoning_content"] as? String, at: time, streaming: streaming)
                    noteContent(delta["reasoning"] as? String, at: time, streaming: streaming)
                    if delta["tool_calls"] != nil, firstTokenAt == nil, streaming { firstTokenAt = time }
                }
                if let message = choice["message"] as? [String: Any] {
                    noteContent(message["content"] as? String, at: time, streaming: streaming)
                    noteContent(message["reasoning_content"] as? String, at: time, streaming: streaming)
                }
                noteContent(choice["text"] as? String, at: time, streaming: streaming)
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            if let prompt = Self.int(usage["prompt_tokens"] ?? usage["input_tokens"]) { promptTokens = prompt }
            if let completion = Self.int(usage["completion_tokens"] ?? usage["output_tokens"]) {
                completionTokens = completion
            }
        }
        // llama.cpp server timings.
        if let timings = object["timings"] as? [String: Any] {
            if let predicted = Self.int(timings["predicted_n"]), completionTokens == nil {
                completionTokens = predicted
            }
            if let prompt = Self.int(timings["prompt_n"]), promptTokens == nil { promptTokens = prompt }
            if let perSecond = Self.double(timings["predicted_per_second"]), perSecond > 0 {
                reportedTPS = perSecond
            }
            if let promptMS = Self.double(timings["prompt_ms"]), !streaming { reportedTTFTMS = promptMS }
        }
        // Ollama native (/api/chat, /api/generate, /api/embed).
        if let message = object["message"] as? [String: Any] {
            noteContent(message["content"] as? String, at: time, streaming: streaming)
            noteContent(message["thinking"] as? String, at: time, streaming: streaming)
        }
        if let response = object["response"] as? String {
            noteContent(response, at: time, streaming: streaming)
        }
        if let thinking = object["thinking"] as? String {
            noteContent(thinking, at: time, streaming: streaming)
        }
        if let evalCount = Self.int(object["eval_count"]) { completionTokens = evalCount }
        if let promptCount = Self.int(object["prompt_eval_count"]) { promptTokens = promptCount }
        if let evalCount = Self.int(object["eval_count"]),
            let evalDuration = Self.double(object["eval_duration"]), evalDuration > 0
        {
            reportedTPS = Double(evalCount) / (evalDuration / 1_000_000_000)
        }
        if !streaming || firstTokenAt == nil {
            let load = Self.double(object["load_duration"]) ?? 0
            if let promptDuration = Self.double(object["prompt_eval_duration"]) {
                reportedTTFTMS = (load + promptDuration) / 1_000_000
            }
        }
    }

    /// Final numbers for the usage record.
    public func result(endedAt: Double, requestPromptCharacters: Int) -> (
        promptTokens: Int?, completionTokens: Int?, estimated: Bool, tps: Double?, ttftMS: Double?
    ) {
        var estimated = false
        var prompt = promptTokens
        var completion = completionTokens
        if completion == nil, contentChunks > 0 {
            completion = format == .json ? max(1, contentCharacters / 4) : contentChunks
            estimated = true
        }
        if prompt == nil, requestPromptCharacters > 0, completion != nil {
            prompt = max(1, requestPromptCharacters / 4)
            estimated = true
        }
        var ttft: Double?
        if let firstTokenAt { ttft = max(0, (firstTokenAt - startedAt) * 1000) }
        if ttft == nil { ttft = reportedTTFTMS }
        var tps = reportedTPS
        if tps == nil, let completion, completion > 1 {
            let begin = firstTokenAt ?? (startedAt + (reportedTTFTMS ?? 0) / 1000)
            let seconds = endedAt - begin
            if seconds > 0.05 { tps = Double(completion - (firstTokenAt == nil ? 0 : 1)) / seconds }
        }
        if let value = tps, !value.isFinite || value <= 0 { tps = nil }
        return (prompt, completion, estimated, tps, ttft)
    }
}
