import SwiftUI

@main struct EditorMacOSApp: App {
    var body: some Scene {
        WindowGroup {
            EditorScreen()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}
