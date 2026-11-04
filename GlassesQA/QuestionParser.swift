import Foundation

struct VisionTurn: Equatable {
    var question: String
    var answer: String
}

enum QuestionParser {
    static func parse(_ raw: String) -> VisionTurn? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNone(text) { return nil }

        let lines = text.components(separatedBy: .newlines)
        var question: String?
        var answerParts: [String] = []
        var inAnswer = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if hasPrefix(trimmed, "QUESTION:") {
                question = String(trimmed.dropFirst("QUESTION:".count))
                    .trimmingCharacters(in: .whitespaces)
                inAnswer = false
                continue
            }
            if hasPrefix(trimmed, "ANSWER:") {
                let value = String(trimmed.dropFirst("ANSWER:".count))
                    .trimmingCharacters(in: .whitespaces)
                answerParts = value.isEmpty ? [] : [value]
                inAnswer = true
                continue
            }
            if inAnswer {
                answerParts.append(trimmed)
            }
        }

        let answer = answerParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let question {
            let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedQuestion.isEmpty || isNone(trimmedQuestion) || answer.isEmpty || isNone(answer) {
                return nil
            }
            return VisionTurn(question: trimmedQuestion, answer: answer)
        }

        return VisionTurn(question: text, answer: text)
    }

    static func normalize(_ question: String) -> String {
        let collapsed = question
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        return trimmed
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.uppercased().hasPrefix(prefix)
    }

    private static func isNone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper == "NONE" || upper == "NONE." || upper == "\"NONE\"" || upper == "'NONE'" {
            return true
        }
        let compact = upper
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
        if compact == "NO QUESTION"
            || compact == "NO CLEAR QUESTION"
            || compact == "THERE IS NO QUESTION"
            || compact == "THERE IS NO CLEAR QUESTION" {
            return true
        }
        let first = upper.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if (first == "NONE" || first == "NONE." || first == "NONE:") && !upper.contains("QUESTION:") {
            return true
        }
        return false
    }
}
