import Foundation

struct NumberedAnswer: Equatable, Identifiable {
    var number: String
    var text: String
    var questionShort: String = ""
    var id: String { number }
}

struct AnswerSet: Equatable {
    var items: [NumberedAnswer]

    var display: String {
        QuestionParser.speakable(items)
    }
}

enum QuestionParser {
    static func parse(_ raw: String) -> AnswerSet? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNone(text) { return nil }

        if text.hasPrefix("[") || text.hasPrefix("{") || text.contains("\"number\"") {
            let rows = jsonItems(text) ?? []
            return rows.isEmpty ? nil : AnswerSet(items: unique(rows))
        }
        let numbered = unique(numberedItems(text))
        if !numbered.isEmpty {
            return AnswerSet(items: numbered)
        }
        if isNone(text) { return nil }
        return AnswerSet(items: [NumberedAnswer(number: "1", text: stripTrailingPeriod(text))])
    }

    /// Answers whose number is new or whose text changed since the last spoken set.
    static func freshItems(previous: [String: String], current: [NumberedAnswer]) -> [NumberedAnswer] {
        current.filter { item in
            previous[item.number] != normalize(item.text)
        }
    }

    static func spokenKeys(_ items: [NumberedAnswer]) -> [String: String] {
        var keys: [String: String] = [:]
        for item in items {
            keys[item.number] = normalize(item.text)
        }
        return keys
    }

    static func spokenLine(_ item: NumberedAnswer) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let last = text.last, ".!?".contains(last) {
            return "Question \(item.number): \(text)"
        }
        return "Question \(item.number): \(text)."
    }

    static func speakable(_ items: [NumberedAnswer]) -> String {
        items.map(spokenLine).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func normalize(_ text: String) -> String {
        let collapsed = text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
    }

    private static func jsonItems(_ text: String) -> [NumberedAnswer]? {
        let data = Data(text.utf8)
        if let rows = try? JSONDecoder().decode([JSONRow].self, from: data) {
            return rows.compactMap(\.item)
        }
        if let wrapped = try? JSONDecoder().decode(JSONEnvelope.self, from: data) {
            return wrapped.items.compactMap(\.item)
        }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            let slice = Data(text[start...end].utf8)
            if let rows = try? JSONDecoder().decode([JSONRow].self, from: slice) {
                return rows.compactMap(\.item)
            }
        }
        return nil
    }

    private struct JSONEnvelope: Decodable {
        let items: [JSONRow]
    }

    private struct JSONRow: Decodable {
        let number: Int
        let questionShort: String?
        let answer: String

        enum CodingKeys: String, CodingKey {
            case number
            case questionShort = "question_short"
            case answer
        }

        var item: NumberedAnswer? {
            let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard number > 0, !body.isEmpty else { return nil }
            return NumberedAnswer(
                number: String(number),
                text: body.hasSuffix(".") ? String(body.dropLast()) : body,
                questionShort: questionShort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }

    private static func unique(_ items: [NumberedAnswer]) -> [NumberedAnswer] {
        var order: [String] = []
        var byNumber: [String: NumberedAnswer] = [:]
        for item in items {
            if byNumber[item.number] == nil {
                order.append(item.number)
            }
            byNumber[item.number] = item
        }
        return order.compactMap { byNumber[$0] }
    }

    private static func numberedItems(_ text: String) -> [NumberedAnswer] {
        let pattern = #"(?:Question\s+)?(\d+)\s*[:.)]\s*(.+?)(?=\s*(?:Question\s+)?\d+\s*[:.)]|\s*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let textRange = Range(match.range(at: 2), in: text) else { return nil }
            let number = String(text[numberRange])
            let body = stripTrailingPeriod(String(text[textRange]))
            guard !body.isEmpty, !isNone(body) else { return nil }
            return NumberedAnswer(number: number, text: body)
        }
    }

    private static func stripTrailingPeriod(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if (first == "NONE" || first == "NONE." || first == "NONE:") && !upper.contains(":") {
            return true
        }
        return false
    }
}
