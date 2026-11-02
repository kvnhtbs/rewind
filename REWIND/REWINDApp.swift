import SwiftUI
import SwiftData

@main
struct REWINDApp: App {
    @State private var library = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
        }
        .modelContainer(for: [CleanupSession.self, Decision.self])
    }
}
