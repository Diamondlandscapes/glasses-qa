import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var playSample: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var grokKeyDraft = ""
    @State private var geminiKeyDraft = ""
    @State private var revealGrokKey = false
    @State private var revealGeminiKey = false
    @State private var grokKeyMessage = ""
    @State private var geminiKeyMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $store.provider) {
                        Text("xAI Grok").tag(VisionProvider.grok)
                        Text("Google Gemini").tag(VisionProvider.gemini)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.provider) { _, _ in
                        store.persistPreferences()
                    }
                } header: {
                    Text("Vision provider")
                } footer: {
                    Text("xAI Grok is the default. Each provider keeps its own key.")
                }

                keySection(
                    title: "xAI API key",
                    footer: "From console.x.ai. The key stays in this iPhone's Keychain and is not written into the app or the git repo.",
                    draft: $grokKeyDraft,
                    reveal: $revealGrokKey,
                    message: grokKeyMessage,
                    save: saveGrokKey,
                    remove: {
                        grokKeyDraft = ""
                        saveGrokKey()
                    }
                )

                keySection(
                    title: "Gemini API key",
                    footer: "From aistudio.google.com/apikey. The key stays in this iPhone's Keychain and is not written into the app or the git repo.",
                    draft: $geminiKeyDraft,
                    reveal: $revealGeminiKey,
                    message: geminiKeyMessage,
                    save: saveGeminiKey,
                    remove: {
                        geminiKeyDraft = ""
                        saveGeminiKey()
                    }
                )

                Section {
                    if store.provider == .grok {
                        TextField("Model", text: $store.grokModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: store.grokModel) { _, _ in
                                store.persistPreferences()
                            }
                    } else {
                        TextField("Model", text: $store.geminiModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: store.geminiModel) { _, _ in
                                store.persistPreferences()
                            }
                    }
                } header: {
                    Text("Vision model")
                } footer: {
                    Text(modelFooter)
                }

                Section {
                    Stepper(value: $store.minGapSeconds, in: 1...10, step: 1) {
                        Text(store.minGap == 1 ? "At least 1 second" : "At least \(Int(store.minGap)) seconds")
                    }
                    .onChange(of: store.minGapSeconds) { _, _ in
                        store.persistPreferences()
                    }
                } header: {
                    Text("Minimum gap")
                } footer: {
                    Text("The next photo starts this long after the previous answer returns. Snap now skips the wait.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech speed")
                        Text(rateLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Slider(value: $store.speechRate, in: 0.3...0.65)
                            .onChange(of: store.speechRate) { _, _ in
                                store.persistPreferences()
                            }
                    }
                    Button("Play a sample") {
                        playSample()
                    }
                } header: {
                    Text("Speech speed")
                } footer: {
                    Text("Default is a little slower than the system voice. Each answer is spoken separately, with a short pause. Answers use the current audio route, including the glasses.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                grokKeyDraft = store.grokAPIKey
                geminiKeyDraft = store.geminiAPIKey
                grokKeyMessage = store.hasGrokAPIKey ? "A key is saved." : "No key saved yet."
                geminiKeyMessage = store.hasGeminiAPIKey ? "A key is saved." : "No key saved yet."
            }
        }
    }

    private var modelFooter: String {
        switch store.provider {
        case .grok:
            return "Default is grok-4.20-0309-non-reasoning, the fastest public Grok model that accepts images. It does not reason. If you switch to grok-4.7, reasoning is set to low."
        case .gemini:
            return "Default is gemini-2.5-flash-lite. Thinking is off. The free tier allows about 10 requests a minute."
        }
    }

    private var rateLabel: String {
        let normal = SpeechRate.normal
        if store.speechRate < normal - 0.04 { return "Slower" }
        if store.speechRate > normal + 0.04 { return "Faster" }
        return "Slightly slower than normal"
    }

    private func keySection(
        title: String,
        footer: String,
        draft: Binding<String>,
        reveal: Binding<Bool>,
        message: String,
        save: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        Section {
            HStack {
                Group {
                    if reveal.wrappedValue {
                        TextField("Paste key", text: draft)
                    } else {
                        SecureField("Paste key", text: draft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())

                Button {
                    reveal.wrappedValue.toggle()
                } label: {
                    Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(reveal.wrappedValue ? "Hide \(title)" : "Show \(title)")
            }

            Button("Save key", action: save)
            Button("Remove key", role: .destructive, action: remove)
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func saveGrokKey() {
        do {
            try store.updateGrokAPIKey(grokKeyDraft)
            grokKeyDraft = store.grokAPIKey
            grokKeyMessage = store.hasGrokAPIKey ? "Saved in the Keychain." : "Key removed."
        } catch {
            grokKeyMessage = error.localizedDescription
        }
    }

    private func saveGeminiKey() {
        do {
            try store.updateGeminiAPIKey(geminiKeyDraft)
            geminiKeyDraft = store.geminiAPIKey
            geminiKeyMessage = store.hasGeminiAPIKey ? "Saved in the Keychain." : "Key removed."
        } catch {
            geminiKeyMessage = error.localizedDescription
        }
    }
}
