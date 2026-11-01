import SwiftUI
import SwiftData

@MainActor
struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Keys.onboarded) private var onboarded = false
    @Query private var decisions: [Decision]

    var body: some View {
        Group {
            if onboarded {
                TabView {
                    HomeView(onSessionEnd: reschedule)
                        .tabItem { Label("Hoy", systemImage: "sparkles") }
                    StatsView()
                        .tabItem { Label("Estadísticas", systemImage: "chart.bar.fill") }
                    SettingsView(onChange: reschedule)
                        .tabItem { Label("Ajustes", systemImage: "gearshape.fill") }
                }
            } else {
                OnboardingView()
            }
        }
        .tint(.rwPurple)
        .task { reschedule() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshStatus() }
            if phase != .inactive { reschedule() }
        }
    }

    private func reschedule() {
        let ids = Set(decisions.map(\.assetID))
        Task { await NotificationService.reschedule(library: library, decidedIDs: ids) }
    }
}
