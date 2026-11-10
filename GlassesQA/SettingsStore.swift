import Foundation
import Observation

enum VisionProvider: String, CaseIterable, Identifiable {
    case grok
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grok:
            return "xAI Grok"
        case .gemini:
            return "Google Gemini"
        }
    }

    var defaultModel: String {
        switch self {
        case .grok:
            return "grok-4.20-0309-non-reasoning"
        case .gemini:
            return "gemini-2.5-flash-lite"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let provider = "glassesqa.provider"
        static let minGap = "glassesqa.minGap"
        static let screenZoom = "glassesqa.screenZoom"
        static let photoSpacing = "glassesqa.photoSpacing"
        static let grokModel = "glassesqa.grokModel"
        static let geminiModel = "glassesqa.geminiModel"
        static let rate = "glassesqa.rate"
    }

    var provider: VisionProvider
    var screenZoom: Bool
    var photoSpacing: Double
    var minGapSeconds: Double
    var grokModel: String
    var geminiModel: String
    var speechRate: Double
    private(set) var grokAPIKey: String
    private(set) var geminiAPIKey: String
    private(set) var hasGrokAPIKey: Bool
    private(set) var hasGeminiAPIKey: Bool

    var minGap: TimeInterval {
        min(10, max(1, minGapSeconds.rounded()))
    }

    /// Seconds to wait after an answer before the next photo. Zero keeps the current immediate pace.
    var captureSpacing: TimeInterval {
        let rounded = photoSpacing.rounded()
        if rounded < 2 { return 0 }
        return min(6, rounded)
    }

    var apiKey: String {
        provider == .grok ? grokAPIKey : geminiAPIKey
    }

    var hasAPIKey: Bool {
        provider == .grok ? hasGrokAPIKey : hasGeminiAPIKey
    }

    var modelName: String {
        let raw = provider == .grok ? grokModel : geminiModel
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    var missingKeyMessage: String {
        switch provider {
        case .grok:
            return "Add an xAI API key in Settings."
        case .gemini:
            return "Add a Gemini API key in Settings."
        }
    }

    var missingKeyHint: String {
        switch provider {
        case .grok:
            return "Add an xAI API key in Settings before starting."
        case .gemini:
            return "Add a Gemini API key in Settings before starting."
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let resolvedProvider = VisionProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .grok

        let storedGap: Double
        if defaults.object(forKey: Keys.minGap) != nil {
            storedGap = defaults.double(forKey: Keys.minGap)
        } else {
            storedGap = 1
        }
        let resolvedGap = min(10, max(1, storedGap.rounded()))

        let resolvedZoom: Bool
        if defaults.object(forKey: Keys.screenZoom) != nil {
            resolvedZoom = defaults.bool(forKey: Keys.screenZoom)
        } else {
            resolvedZoom = true
        }

        var resolvedSpacing = defaults.object(forKey: Keys.photoSpacing) == nil
            ? 0
            : defaults.double(forKey: Keys.photoSpacing).rounded()
        if resolvedSpacing > 0 && resolvedSpacing < 2 { resolvedSpacing = 2 }
        resolvedSpacing = min(6, max(0, resolvedSpacing))

        let storedGrok = defaults.string(forKey: Keys.grokModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedGrok = (storedGrok.isEmpty || storedGrok == "grok-4.7")
            ? VisionProvider.grok.defaultModel
            : storedGrok

        let storedGemini = defaults.string(forKey: Keys.geminiModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedGemini = (storedGemini.isEmpty || storedGemini == "gemini-2.5-flash")
            ? VisionProvider.gemini.defaultModel
            : storedGemini

        let storedRate: Double
        if defaults.object(forKey: Keys.rate) != nil {
            storedRate = defaults.double(forKey: Keys.rate)
        } else {
            storedRate = SpeechRate.normal
        }
        let previousFastDefault = abs(storedRate - 0.5) < 0.001 || abs(storedRate - 0.56) < 0.001
        let migratedRate = previousFastDefault ? SpeechRate.normal : storedRate
        let resolvedRate = min(0.65, max(0.3, migratedRate))

        let loadedGrok = KeychainStore.load(account: KeychainStore.grokAccount) ?? ""
        let loadedGemini = KeychainStore.load(account: KeychainStore.geminiAccount) ?? ""

        provider = resolvedProvider
        screenZoom = resolvedZoom
        photoSpacing = resolvedSpacing
        minGapSeconds = resolvedGap
        grokModel = resolvedGrok
        geminiModel = resolvedGemini
        speechRate = resolvedRate
        grokAPIKey = loadedGrok
        geminiAPIKey = loadedGemini
        hasGrokAPIKey = !loadedGrok.isEmpty
        hasGeminiAPIKey = !loadedGemini.isEmpty
    }

    func persistPreferences() {
        let clampedGap = min(10, max(1, minGapSeconds.rounded()))
        if minGapSeconds != clampedGap {
            minGapSeconds = clampedGap
        }
        let trimmedGrok = grokModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGrok = trimmedGrok.isEmpty ? VisionProvider.grok.defaultModel : trimmedGrok
        if grokModel != resolvedGrok {
            grokModel = resolvedGrok
        }
        let trimmedGemini = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGemini = trimmedGemini.isEmpty ? VisionProvider.gemini.defaultModel : trimmedGemini
        if geminiModel != resolvedGemini {
            geminiModel = resolvedGemini
        }
        let clampedRate = min(0.65, max(0.3, speechRate))
        if speechRate != clampedRate {
            speechRate = clampedRate
        }

        var spacing = photoSpacing.rounded()
        if spacing > 0 && spacing < 2 { spacing = 2 }
        spacing = min(6, max(0, spacing))
        if photoSpacing != spacing {
            photoSpacing = spacing
        }

        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(screenZoom, forKey: Keys.screenZoom)
        defaults.set(photoSpacing, forKey: Keys.photoSpacing)
        defaults.set(minGapSeconds, forKey: Keys.minGap)
        defaults.set(grokModel, forKey: Keys.grokModel)
        defaults.set(geminiModel, forKey: Keys.geminiModel)
        defaults.set(speechRate, forKey: Keys.rate)
    }

    func updateGrokAPIKey(_ raw: String) throws {
        let trimmed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if trimmed.isEmpty {
            try KeychainStore.delete(account: KeychainStore.grokAccount)
            grokAPIKey = ""
        } else {
            try KeychainStore.save(trimmed, account: KeychainStore.grokAccount)
            grokAPIKey = trimmed
        }
        hasGrokAPIKey = !grokAPIKey.isEmpty
    }

    func updateGeminiAPIKey(_ raw: String) throws {
        let trimmed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if trimmed.isEmpty {
            try KeychainStore.delete(account: KeychainStore.geminiAccount)
            geminiAPIKey = ""
        } else {
            try KeychainStore.save(trimmed, account: KeychainStore.geminiAccount)
            geminiAPIKey = trimmed
        }
        hasGeminiAPIKey = !geminiAPIKey.isEmpty
    }
}
