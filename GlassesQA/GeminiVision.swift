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
    static func text(answered: [Int]) -> String {
        let known = answeredSummary(answered)
        let frontier = answered.max() ?? 0
        return """
        Read the numbered questions visible in this photo. They may be printed, handwritten, or on a screen.

        Already answered question numbers: \(known).
        The highest answered number is \(frontier).
        Return ONLY questions that are visible and whose numbers are greater than \(frontier).
        Do not return any number that was already answered. Do not go backwards.

        Respond with JSON only, an array, no markdown:
        [{"number":19,"question_short":"powerhouse of the cell","answer":"C, mitochondria"}]

        answer must be short and speakable. If there is a choice letter, include it, then the answer in a few words, like "C, mitochondria" or "True" or "42".
        question_short is a few words naming the question.
        If there are no new questions, return [].
        """
    }

    static func answeredSummary(_ numbers: [Int]) -> String {
        let sorted = Array(Set(numbers)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return "none" }
        if sorted == Array(first...last) {
            return "\(first) through \(last)"
        }
        return sorted.map(String.init).joined(separator: ", ")
    }
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
    static func answer(jpeg: Data, apiKey: String, model: String, answered: [Int]) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedModel = trimmedModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw VisionError.api("The model name isn't valid.")
        }

        let body = Request(
            contents: [
                Request.Content(parts: [
                    .text(VisionPrompt.text(answered: answered)),
                    .image(jpeg)
                ])
            ],
            generationConfig: Request.GenerationConfig(
                temperature: 0,
                maxOutputTokens: 500,
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
            if let api = try? JSONDecoder().decode(APIErrorBody.self, from: data),
               !api.error.message.isEmpty {
                throw VisionError.api(api.error.message)
            }
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? "HTTP \(status)"
            throw VisionError.api(snippet)
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
