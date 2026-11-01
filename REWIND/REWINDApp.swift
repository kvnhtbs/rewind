import SwiftUI
import SwiftData

@main
struct REWINDApp: App {
    @State private var library = PhotoLibraryService()
    private let container: ModelContainer = {
        do { return try ModelContainer(for: CleanupSession.self, Decision.self) }
        catch { fatalError("No se pudo crear el almacén SwiftData: \(error)") }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .modelContainer(container)
        }
    }
}
