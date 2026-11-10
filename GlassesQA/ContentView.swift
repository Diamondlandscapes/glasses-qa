import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    private let amber = Color(red: 0.91, green: 0.65, blue: 0.29)
    private let card = Color(red: 0.14, green: 0.13, blue: 0.12)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    if let lastError = model.lastError {
                        errorBanner(lastError)
                    }
                    if model.needsFirmwareUpdate {
                        actionRow("Update glasses firmware", systemImage: "arrow.down.circle") {
                            model.updateFirmware()
                        }
                    }
                    if model.needsGlassesAppUpdate {
                        actionRow("Update the app on the glasses", systemImage: "eyeglasses") {
                            model.updateGlassesApp()
                        }
                    }
                    photoCard
                    answerCard
                    if !model.settings.hasAPIKey {
                        Text(model.settings.missingKeyHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    controlButton
                    snapButton
                    resetButton
                    Text("\(model.voiceLabel) · \(model.captureModeLabel) · \(model.latencyLabel)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Color(red: 0.07, green: 0.07, blue: 0.06).ignoresSafeArea())
            .navigationTitle("Glasses QA")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: model.settings) {
                    model.playSample()
                }
            }
        }
        .tint(amber)
        .preferredColorScheme(.dark)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.registrationLabel, systemImage: "eyeglasses")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(model.glassesSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.status)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if !model.timingLabel.isEmpty {
                Text(model.timingLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.registrationState != .registered {
                Text("Meta AI opens so you can approve this app. Developer Mode has to be on for the glasses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if model.registrationState == .registered {
                    model.disconnect()
                } else {
                    model.connect()
                }
            } label: {
                Text(connectTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.sdkReady || model.registrationState == .registering)
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last photo")
                    .font(.headline)
                Spacer()
                if let lastPhotoAt = model.lastPhotoAt {
                    Text(lastPhotoAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let thumbnail = model.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Last photo from the glasses")
                if model.settings.screenZoom {
                    screenPreview
                }
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.viewfinder")
                                .font(.title)
                            Text("The latest frame from the glasses shows up here.")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
            }
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var screenPreview: some View {
        HStack(alignment: .center, spacing: 12) {
            if let cropPreview = model.cropPreview, model.screenLocked {
                Image(uiImage: cropPreview)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Cropped screen")
                Text("Screen locked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "rectangle.dashed")
                    .foregroundStyle(.secondary)
                Text("No screen found. Using the full photo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.answers.isEmpty {
                Text("Point the glasses at a question, then start.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.answers) { item in
                    Text(QuestionParser.spokenLine(item))
                        .font(.title3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.missingLabel.isEmpty {
                    Text(model.missingLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var controlButton: some View {
        Button {
            if model.running || model.isStarting {
                model.userStop()
            } else {
                model.start()
            }
        } label: {
            HStack(spacing: 8) {
                if model.isStarting {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: model.running ? "stop.fill" : "play.fill")
                }
                Text(controlTitle)
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.running ? Color(red: 0.75, green: 0.28, blue: 0.22) : amber)
        .foregroundStyle(model.running ? Color.white : Color.black)
        .disabled(controlDisabled)
        .accessibilityLabel(model.running ? "Stop" : "Start")
    }

    private var snapButton: some View {
        Button {
            model.snapNow()
        } label: {
            Label("Snap now", systemImage: "camera.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(snapDisabled)
    }

    private var resetButton: some View {
        Button {
            model.resetTest()
        } label: {
            Label("New test / Reset", systemImage: "arrow.counterclockwise")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var connectTitle: String {
        switch model.registrationState {
        case .registered:
            return "Disconnect"
        case .registering:
            return "Waiting for Meta AI…"
        case .available, .unavailable:
            return "Connect glasses"
        }
    }

    private var controlTitle: String {
        model.running || model.isStarting ? "Stop" : "Start"
    }

    private var snapDisabled: Bool {
        !model.sdkReady
            || model.registrationState != .registered
            || !model.settings.hasAPIKey
            || model.isStarting
    }

    private var controlDisabled: Bool {
        if model.running || model.isStarting { return false }
        return !model.sdkReady
            || model.registrationState != .registered
            || !model.settings.hasAPIKey
    }

    private var statusColor: Color {
        if model.running { return Color(red: 0.35, green: 0.78, blue: 0.45) }
        if model.registrationState == .registered { return amber }
        return Color.white.opacity(0.35)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(amber)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .background(Color(red: 0.28, green: 0.16, blue: 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView(model: AppModel(configureError: "Preview"))
}
