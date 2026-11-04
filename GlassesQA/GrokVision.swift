import Foundation

enum GrokVision {
    static func answer(jpeg: Data, apiKey: String, model: String) async throws -> String {
        let body = Request(
            model: model,
            temperature: 0,
            maxTokens: 120,
            reasoningEffort: reasoningEffort(for: model),
            messages: [
                Request.Message(
                    role: "user",
                    content: [
                        .text(VisionPrompt.text),
                        .image(jpeg)
                    ]
                )
            ]
        )
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        let text = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw VisionError.empty }
        return text
    }

    /// grok-4.7, 4.6, and 4.5 always reason and default to high effort.
    /// The non-reasoning model rejects this parameter, so it is omitted there.
    static func reasoningEffort(for model: String) -> String? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.contains("non-reasoning") || id.contains("nonreasoning") || id.contains("multi-agent") {
            return nil
        }
        if id.hasPrefix("grok-4.7") || id.hasPrefix("grok-4.6") || id.hasPrefix("grok-4.5") {
            return "low"
        }
        if id.hasPrefix("grok-4.3") {
            return "none"
        }
        return nil
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
    let temperature: Double
    let maxTokens: Int
    let reasoningEffort: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case messages
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(messages, forKey: .messages)
        if let reasoningEffort {
            try container.encode(reasoningEffort, forKey: .reasoningEffort)
        }
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
