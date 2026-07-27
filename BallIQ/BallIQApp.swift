import SwiftUI

@main
struct BallIQApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = RepositoryContainer.make()

    init() {
        FontRegistration.registerAll()
        // Before any `URLSession.shared` traffic: the default URLCache (~10 MB disk) is smaller
        // than the team-logo bucket (22.5 MB), so crests could never stay cached.
        AppImagePipeline.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.auth)
                .tint(.accentFill)
                .task { await container.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: .didRegisterDeviceToken)) { note in
                    guard let token = note.userInfo?["token"] as? String else { return }
                    container.registerDeviceToken(token)
                }
        }
    }
}
