import SwiftUI

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--rendering-audit") {
                RenderingAuditView()
            } else {
                ContentView()
            }
        }
    }
}
