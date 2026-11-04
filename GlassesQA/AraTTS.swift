import Foundation

enum AraTTS {
    /// REST text-to-speech. Response body is raw audio bytes (MP3 by default).
    /// https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
    static func mpeg(text: String, apiKey: String, speed: Double) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/tts")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = Request(
            text: text,
            voiceID: "ara",
            language: "en",
            speed: min(1.5, max(0.7, speed))
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await VisionHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status), !data.isEmpty, !type.contains("json") else {
            throw VisionError.api("Ara voice unavailable")
        }
        return data
    }

    private struct Request: Encodable {
        let text: String
        let voiceID: String
        let language: String
        let speed: Double

        enum CodingKeys: String, CodingKey {
            case text
            case voiceID = "voice_id"
            case language
            case speed
        }
    }
}
