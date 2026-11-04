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
    Read any question visible in this image. The question may be printed, handwritten, or on a screen.

    If there is a clear question, reply in exactly this form and nothing else:
    QUESTION: <the question on one line>
    ANSWER: <a short direct answer, 1-2 sentences>

    If there is no clear question, reply with exactly:
    NONE
    """
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
            ]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
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

    let contents: [Content]
}

private struct Response: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
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
