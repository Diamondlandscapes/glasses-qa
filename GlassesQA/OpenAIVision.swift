import Foundation

enum VisionError: LocalizedError {
    case api(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message
        case .empty:
            return "OpenAI returned an empty answer."
        }
    }
}

enum OpenAIVision {
    static let prompt = """
    Read any question visible in this image. The question may be printed, handwritten, or on a screen.

    If there is a clear question, reply in exactly this form and nothing else:
    QUESTION: <the question on one line>
    ANSWER: <a short direct answer, 1-2 sentences>

    If there is no clear question, reply with exactly:
    NONE
    """

    static func answer(jpeg: Data, apiKey: String, model: String) async throws -> String {
        let body = Request(
            model: model,
            maxTokens: 300,
            messages: [
                Request.Message(
                    role: "user",
                    content: [
                        .text(prompt),
                        .image(jpeg)
                    ]
                )
            ]
        )
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let api = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw VisionError.api(api.error.message)
            }
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? "HTTP \(status)"
            throw VisionError.api(snippet)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw VisionError.empty }
        return text
    }
}

private struct Request: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    enum Content: Encodable {
        case text(String)
        case image(Data)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode("image_url", forKey: .type)
                try container.encode(
                    ImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())", detail: "high"),
                    forKey: .imageURL
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        private struct ImageURL: Encodable {
            let url: String
            let detail: String
        }
    }

    let model: String
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }
}

private struct Response: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct APIErrorBody: Decodable {
    struct Inner: Decodable {
        let message: String
    }

    let error: Inner
}
