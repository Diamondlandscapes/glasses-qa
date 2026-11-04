import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var playSample: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var revealKey = false
    @State private var keyMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if revealKey {
                                TextField("sk-…", text: $keyDraft)
                            } else {
                                SecureField("sk-…", text: $keyDraft)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealKey ? "Hide API key" : "Show API key")
                    }

                    Button("Save key") {
                        saveKey()
                    }
                    Button("Remove key", role: .destructive) {
                        keyDraft = ""
                        saveKey()
                    }
                    if !keyMessage.isEmpty {
                        Text(keyMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("The key stays in this iPhone's Keychain. It is not written into the app or the git repo.")
                }

                Section {
                    TextField("Model", text: $store.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: store.model) { _, _ in
                            store.persistPreferences()
                        }
                } header: {
                    Text("Vision model")
                } footer: {
                    Text("Default is gpt-4o-mini. Use any model that accepts image input.")
                }

                Section {
                    Stepper(value: $store.intervalSeconds, in: 2...10, step: 1) {
                        Text("Every \(Int(store.captureInterval)) seconds")
                    }
                    .onChange(of: store.intervalSeconds) { _, _ in
                        store.persistPreferences()
                    }
                } header: {
                    Text("Capture interval")
                } footer: {
                    Text("A new photo starts only after the previous one finishes, and at least this many seconds after it began.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rateLabel)
                        Slider(value: $store.speechRate, in: 0.35...0.6)
                            .onChange(of: store.speechRate) { _, _ in
                                store.persistPreferences()
                            }
                    }
                    Button("Play a sample") {
                        playSample()
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Answers use the current audio route. When the glasses are the Bluetooth headset, you hear them there.")
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
                keyDraft = store.apiKey
                keyMessage = store.hasAPIKey ? "A key is saved." : "No key saved yet."
            }
        }
    }

    private var rateLabel: String {
        if store.speechRate < 0.45 { return "Slower" }
        if store.speechRate > 0.54 { return "Faster" }
        return "Normal speed"
    }

    private func saveKey() {
        do {
            try store.updateAPIKey(keyDraft)
            keyDraft = store.apiKey
            keyMessage = store.hasAPIKey ? "Saved in the Keychain." : "Key removed."
        } catch {
            keyMessage = error.localizedDescription
        }
    }
}
