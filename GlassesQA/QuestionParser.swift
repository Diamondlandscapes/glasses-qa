import Foundation

struct NumberedAnswer: Equatable, Identifiable {
    var number: String
    var text: String
    var questionText: String = ""
    var choices: String = ""
    var id: String { number }
}

struct AnswerSet: Equatable {
    var items: [NumberedAnswer]
    var unreadableNumbers: [String] = []

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
            let parsed = jsonItems(text)
            if parsed.items.isEmpty && parsed.unreadableNumbers.isEmpty { return nil }
            return AnswerSet(items: unique(parsed.items), unreadableNumbers: parsed.unreadableNumbers)
        }
        let numbered = unique(numberedItems(text))
        if !numbered.isEmpty {
            return AnswerSet(items: numbered)
        }
        return nil
    }

    /// Jaccard overlap of word tokens. Empty or very short text does not match.
    static func closelyMatches(_ a: String, _ b: String) -> Bool {
        let left = tokens(a)
        let right = tokens(b)
        guard left.count >= 3, right.count >= 3 else { return false }
        let union = left.union(right).count
        guard union > 0 else { return false }
        return Double(left.intersection(right).count) / Double(union) >= 0.8
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(
            normalize(text)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }
        )
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
        guard isRealAnswer(text), Int(item.number) != nil else { return "" }
        if let last = text.last, ".!?".contains(last) {
            return "Question \(item.number): \(text)"
        }
        return "Question \(item.number): \(text)."
    }

    static func speakable(_ items: [NumberedAnswer]) -> String {
        items.map(spokenLine).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// False for a missing answer or a placeholder such as null, none, or n/a.
    static func isRealAnswer(_ raw: String) -> Bool {
        !isPlaceholderToken(raw)
    }

    static func isPlaceholderToken(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let folded = normalize(trimmed)
        let stripped = String(
            folded.unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
            }
        )
        let blocked: Set<String> = [
            "null", "none", "nil", "unknown", "undefined", "na", "n/a", "n.a", "n a",
            "not available", "no answer", "blank", "empty", "unanswered", "tbd", "missing"
        ]
        return blocked.contains(folded) || blocked.contains(stripped)
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

    private static func jsonItems(_ text: String) -> (items: [NumberedAnswer], unreadableNumbers: [String]) {
        let rows = decodeRows(text)
        var items: [NumberedAnswer] = []
        var unreadable: [String] = []
        for row in rows {
            if let item = row.item {
                items.append(item)
            } else if let number = row.unreadableNumber {
                unreadable.append(number)
            }
        }
        return (items, unreadable)
    }

    private static func decodeRows(_ text: String) -> [JSONRow] {
        let data = Data(text.utf8)
        if let rows = try? JSONDecoder().decode([JSONRow].self, from: data) { return rows }
        if let wrapped = try? JSONDecoder().decode(JSONEnvelope.self, from: data) { return wrapped.items }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            let slice = Data(text[start...end].utf8)
            if let rows = try? JSONDecoder().decode([JSONRow].self, from: slice) { return rows }
        }
        return []
    }

    private struct JSONEnvelope: Decodable {
        let items: [JSONRow]
    }

    private struct JSONRow: Decodable {
        let number: Int?
        let questionText: String
        let choices: String
        let answer: String
        let truncated: Bool
        let unreadable: Bool

        enum CodingKeys: String, CodingKey {
            case number
            case questionText = "question_text"
            case questionShort = "question_short"
            case choices
            case answer
            case truncated
            case unreadable
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(Int.self, forKey: .number), value > 0 {
                number = value
            } else if let raw = try? container.decode(String.self, forKey: .number),
                      let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0 {
                number = value
            } else {
                number = nil
            }
            let verbatim = Self.lossyString(container, .questionText)
                ?? Self.lossyString(container, .questionShort)
                ?? ""
            questionText = QuestionParser.isPlaceholderToken(verbatim) ? "" : verbatim
            choices = Self.lossyString(container, .choices) ?? ""
            answer = Self.lossyString(container, .answer) ?? ""
            truncated = Self.flag(container, .truncated)
            unreadable = Self.flag(container, .unreadable)
        }

        private static func flag(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> Bool {
            guard container.contains(key) else { return false }
            if (try? container.decodeNil(forKey: key)) == true { return false }
            return (try? container.decode(Bool.self, forKey: key)) ?? false
        }

        private static func lossyString(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            guard container.contains(key) else { return nil }
            if (try? container.decodeNil(forKey: key)) == true { return nil }
            if let value = try? container.decode(String.self, forKey: key) {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decode(Bool.self, forKey: key) {
                return value ? "True" : "False"
            }
            return nil
        }

        var unreadableNumber: String? {
            guard let number else { return nil }
            if truncated || unreadable || !QuestionParser.isRealAnswer(answer) { return String(number) }
            return nil
        }

        var item: NumberedAnswer? {
            guard let number, unreadableNumber == nil else { return nil }
            let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = body.hasSuffix(".") ? String(body.dropLast()).trimmingCharacters(in: .whitespaces) : body
            guard QuestionParser.isRealAnswer(trimmed) else { return nil }
            return NumberedAnswer(
                number: String(number),
                text: trimmed,
                questionText: questionText,
                choices: choices
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
            guard isRealAnswer(body), !isNone(body) else { return nil }
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
