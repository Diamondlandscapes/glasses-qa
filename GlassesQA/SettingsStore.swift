import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let interval = "glassesqa.interval"
        static let model = "glassesqa.model"
        static let rate = "glassesqa.rate"
    }

    var intervalSeconds: Double
    var model: String
    var speechRate: Double
    private(set) var apiKey: String
    private(set) var hasAPIKey: Bool

    var captureInterval: TimeInterval {
        min(10, max(2, intervalSeconds.rounded()))
    }

    var modelName: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-4o-mini" : trimmed
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.interval) != nil {
            intervalSeconds = defaults.double(forKey: Keys.interval)
        } else {
            intervalSeconds = 4
        }
        intervalSeconds = min(10, max(2, intervalSeconds.rounded()))

        let storedModel = defaults.string(forKey: Keys.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model = storedModel.isEmpty ? "gpt-4o-mini" : storedModel

        if defaults.object(forKey: Keys.rate) != nil {
            speechRate = defaults.double(forKey: Keys.rate)
        } else {
            speechRate = 0.5
        }
        speechRate = min(0.6, max(0.35, speechRate))

        apiKey = KeychainStore.load() ?? ""
        hasAPIKey = !apiKey.isEmpty
    }

    func persistPreferences() {
        let clampedInterval = min(10, max(2, intervalSeconds.rounded()))
        if intervalSeconds != clampedInterval {
            intervalSeconds = clampedInterval
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? "gpt-4o-mini" : trimmedModel
        if model != resolvedModel {
            model = resolvedModel
        }
        let clampedRate = min(0.6, max(0.35, speechRate))
        if speechRate != clampedRate {
            speechRate = clampedRate
        }

        let defaults = UserDefaults.standard
        defaults.set(intervalSeconds, forKey: Keys.interval)
        defaults.set(model, forKey: Keys.model)
        defaults.set(speechRate, forKey: Keys.rate)
    }

    func updateAPIKey(_ raw: String) throws {
        let trimmed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if trimmed.isEmpty {
            try KeychainStore.delete()
            apiKey = ""
        } else {
            try KeychainStore.save(trimmed)
            apiKey = trimmed
        }
        hasAPIKey = !apiKey.isEmpty
    }
}
