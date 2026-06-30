import SwiftUI

@main
struct BallIQApp: App {
    @StateObject private var container = RepositoryContainer.make()

    init() {
        FontRegistration.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.auth)
                .tint(.accentFill)
                .task { await container.bootstrap() }
        }
    }
}
