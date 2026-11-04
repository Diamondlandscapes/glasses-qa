@preconcurrency import MWDATCore
import SwiftUI

@main
struct GlassesQAApp: App {
    @State private var model: AppModel

    init() {
        do {
            try Wearables.configure()
            _model = State(initialValue: AppModel(wearables: Wearables.shared))
        } catch {
            _model = State(initialValue: AppModel(configureError: error.localizedDescription))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    Task {
                        await model.handleCallback(url)
                    }
                }
        }
    }
}
