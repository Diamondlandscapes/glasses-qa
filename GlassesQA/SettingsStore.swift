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
        let storedInterval: Double
        if defaults.object(forKey: Keys.interval) != nil {
            storedInterval = defaults.double(forKey: Keys.interval)
        } else {
            storedInterval = 4
        }
        let resolvedInterval = min(10, max(2, storedInterval.rounded()))

        let storedModel = defaults.string(forKey: Keys.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedModel = storedModel.isEmpty ? "gpt-4o-mini" : storedModel

        let storedRate: Double
        if defaults.object(forKey: Keys.rate) != nil {
            storedRate = defaults.double(forKey: Keys.rate)
        } else {
            storedRate = 0.5
        }
        let resolvedRate = min(0.6, max(0.35, storedRate))
        let loadedKey = KeychainStore.load() ?? ""

        intervalSeconds = resolvedInterval
        model = resolvedModel
        speechRate = resolvedRate
        apiKey = loadedKey
        hasAPIKey = !loadedKey.isEmpty
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
