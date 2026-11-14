import SwiftUI

@main
struct StowApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 480, height: 360)
        .windowResizability(.contentMinSize)
    }
}
