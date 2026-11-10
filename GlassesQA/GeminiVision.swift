import Foundation

enum VisionError: LocalizedError {
    case api(String)
    case empty
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message
        case .empty:
            return "The model returned an empty answer."
        case .rateLimited:
            return "Rate limited. Skipped this photo."
        }
    }
}

enum VisionPrompt {
    static let text = """
    This photo shows a test or quiz. For every numbered question you can read, work in this order and keep the reasoning private. Do not include the reasoning in the output.

    1. Copy the question number exactly as printed. Never infer, increment, or guess a number. If it is not clearly visible, use null.
    2. Transcribe the full question verbatim into question_text.
    3. Transcribe every answer choice verbatim into choices, including the letters. If there are no choices, use an empty string.
    4. Decide the correct choice.
    5. Set answer to the choice letter plus the choice text, such as "C, mitochondria". If there are no choices, set answer to a short factual answer.

    If the question or any choice is cut off or unreadable, set truncated or unreadable to true and set answer to null. Do not guess.

    Return JSON only, no markdown:
    [{"number":12,"question_text":"Which organelle is the powerhouse of the cell?","choices":"A) nucleus B) ribosome C) mitochondria","answer":"C, mitochondria","truncated":false,"unreadable":false}]

    If nothing readable is visible, return [].
    """
}

enum VisionHTTP {
    /// One session so TLS and the HTTP connection stay warm between photos.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

enum GeminiVision {
    static func answer(jpeg: Data, apiKey: String, model: String) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedModel = trimmedModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw VisionError.api("The model name isn't valid.")
        }

        let body = Request(
            contents: [
                Request.Content(parts: [
                    .text(VisionPrompt.text),
                    .image(jpeg)
                ])
            ],
            generationConfig: Request.GenerationConfig(
                temperature: 0,
                maxOutputTokens: 1500,
                thinkingConfig: Request.ThinkingConfig(thinkingBudget: 0)
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await VisionHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            throw VisionError.rateLimited
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error.message
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            if message.isEmpty {
                throw VisionError.api("API error \(status)")
            }
            let clipped = message.count > 80 ? String(message.prefix(80)) : message
            throw VisionError.api("API error \(status): \(clipped)")
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates?
            .first?
            .content?
            .parts?
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw VisionError.empty }
        return text
    }
}

private struct Request: Encodable {
    struct Content: Encodable {
        let parts: [Part]
    }

    enum Part: Encodable {
        case text(String)
        case image(Data)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode(
                    InlineData(mimeType: "image/jpeg", data: data.base64EncodedString()),
                    forKey: .inlineData
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        private struct InlineData: Encodable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
        let thinkingConfig: ThinkingConfig

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxOutputTokens
            case thinkingConfig
        }
    }

    struct ThinkingConfig: Encodable {
        let thinkingBudget: Int
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct Response: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}

private struct APIErrorBody: Decodable {
    struct Inner: Decodable {
        let message: String
    }

    let error: Inner
}
