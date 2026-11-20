import Foundation

/// Generates Swedish narration with Epidemic Sound's AI voiceovers.
///
/// Voiceovers aren't in Epidemic Sound's REST API, only in its MCP server, which is
/// JSON-RPC over HTTPS: initialize a session, call `GenerateVoiceover`, poll until done,
/// then fetch the audio from the URL `DownloadVoiceover` returns.
struct EpidemicVoiceClient {
    /// "Helen": British voice artist, speaks Swedish. Chosen by ear.
    static let helenVoiceID = "ef97d9ff-8c9b-46b5-98ae-327f0f0da4f4"
    private static let endpoint = URL(string: "https://www.epidemicsound.com/a/mcp-service/mcp")!

    let apiKey: String
    var voiceID = helenVoiceID
    /// -1 is the slowest the API allows. The default sounded too fast for reading aloud.
    var speed = -1.0

    func narrate(_ text: String) async throws -> Data {
        let sessionID = try await startSession()
        let generation = try await callTool("GenerateVoiceover", [
            "input": ["voiceId": voiceID, "text": text, "languageCode": "sv", "speed": speed],
        ], sessionID: sessionID)
        let id = try MCPResponse.string(at: ["data", "voiceoverGenerate", "id"], in: generation)

        for _ in 0..<90 {
            let poll = try await callTool("PollVoiceoverGenerationStatus", ["id": id], sessionID: sessionID)
            switch try MCPResponse.string(at: ["data", "voiceoverGenerateStatus", "status"], in: poll) {
            case "DONE":
                let download = try await callTool("DownloadVoiceover", ["input": ["id": id]], sessionID: sessionID)
                let link = try MCPResponse.string(at: ["data", "voiceoverDownload", "assetUrl"], in: download)
                guard let url = URL(string: link) else { throw VoiceError.unexpectedResponse }
                let (audio, response) = try await URLSession.shared.data(from: url)
                try Self.check(response, body: audio)
                return audio
            case "FAILED":
                let reason = try? MCPResponse.string(at: ["data", "voiceoverGenerateStatus", "failedReason"], in: poll)
                throw VoiceError.generationFailed(reason ?? "")
            default:
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw VoiceError.timedOut
    }

    private func startSession() async throws -> String? {
        let (_, response) = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "swedish-reader", "version": "1.0"],
            ],
        ], sessionID: nil)
        let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], sessionID: sessionID)
        return sessionID
    }

    private func callTool(_ name: String, _ arguments: [String: Any], sessionID: String?) async throws -> [String: Any] {
        let (body, _) = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ], sessionID: sessionID)
        return try MCPResponse.toolResult(from: body)
    }

    private func post(_ message: [String: Any], sessionID: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: body)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.unexpectedResponse }
        return (body, http)
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw VoiceError.unexpectedResponse }
        switch status {
        case 200..<300: return
        case 401, 403: throw VoiceError.keyRejected
        default: throw VoiceError.http(status, String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}

enum VoiceError: LocalizedError, Equatable {
    case keyRejected
    case http(Int, String)
    case server(String)
    case generationFailed(String)
    case timedOut
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .keyRejected: "the API key was rejected"
        case let .http(status, body): "server error \(status) \(body)"
        case let .server(message): message
        case let .generationFailed(reason): "generation failed \(reason)"
        case .timedOut: "generation took too long"
        case .unexpectedResponse: "unexpected response from the server"
        }
    }
}

/// Parsing for MCP server responses, kept separate so it can be unit tested.
enum MCPResponse {
    /// The JSON-RPC message in a response body. The server may answer with plain JSON
    /// or with a server-sent event stream (`data: {...}` lines).
    static func message(from body: Data) throws -> [String: Any] {
        for line in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let candidate = line.hasPrefix("data:") ? line.dropFirst(5) : line
            guard let json = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any],
                  json["jsonrpc"] != nil
            else { continue }
            return json
        }
        throw VoiceError.unexpectedResponse
    }

    /// A tool's result: the JSON document inside `result.content[0].text`.
    static func toolResult(from body: Data) throws -> [String: Any] {
        let message = try message(from: body)
        if let error = message["error"] as? [String: Any] {
            throw VoiceError.server(error["message"] as? String ?? "unknown error")
        }
        guard let result = message["result"] as? [String: Any],
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        else { throw VoiceError.unexpectedResponse }
        if result["isError"] as? Bool == true { throw VoiceError.server(text) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw VoiceError.server(text)
        }
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw VoiceError.server(first["message"] as? String ?? "unknown error")
        }
        return json
    }

    static func string(at path: [String], in json: [String: Any]) throws -> String {
        var node: Any = json
        for key in path {
            guard let next = (node as? [String: Any])?[key] else { throw VoiceError.unexpectedResponse }
            node = next
        }
        guard let value = node as? String else { throw VoiceError.unexpectedResponse }
        return value
    }
}
