import SwiftUI

@main
struct PeakerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ViewerView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}
