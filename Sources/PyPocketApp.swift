import SwiftUI

@main
struct PyPocketApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PocketRootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
                .onOpenURL { url in
                    if url.isFileURL { model.importLocal(url) }
                }
        }
    }
}
