import SwiftUI

@main
struct SimpClientApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum Config {
    static let base = URL(string: "https://simpcity.cr")!
    static let forumsURL = base.appendingPathComponent("forums/")
    static let latestURL = base.appendingPathComponent("whats-new/posts/")
    static let loginURL = base.appendingPathComponent("login/")
}
