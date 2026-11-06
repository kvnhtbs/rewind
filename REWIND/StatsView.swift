import SwiftUI
import SwiftData

@MainActor
struct StatsGrid: View {
    let stats: StatsData
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Archivos revisados", value: "\(stats.reviewed)", symbol: "eye.fill")
            StatTile(title: "Conservados", value: "\(stats.kept)", symbol: "heart.fill", color: .rwKeep)
            StatTile(title: "Eliminados", value: "\(stats.deleted)", symbol: "trash.fill", color: .rwDelete)
            StatTile(title: "Espacio liberado", value: stats.freed.byteString, symbol: "externaldrive.fill")
        }
    }
}

/// Elementos revisados y pendientes de la biblioteca. El porcentaje y la barra solo aparecen cuando los datos son fiables.
@MainActor
struct LibraryProgressCard: View {
    let decisions: [Decision]
    @Environment(PhotoLibraryService.self) private var library
    @State private var progress: LibraryProgress?

    private var refreshKey: String {
        let all = Set(decisions.map(\.assetID)).hashValue
        let marked = Set(decisions.filter { !$0.keep && !$0.deleted }.map(\.assetID)).hashValue
        return "\(all)-\(marked)-\(library.status.rawValue)"
    }

    var body: some View {
        Group {
            if library.hasAccess { content }
        }
        .task(id: refreshKey) { await load() }
    }

    private func load() async {
        let all = decisions.map(\.assetID)
        let marked = decisions.filter { !$0.keep && !$0.deleted }.map(\.assetID)
        if let value = await library.libraryProgress(allIDs: all, markedIDs: marked) {
            progress = value
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Progreso de revisión").font(.rwHeadline)
            if let p = progress {
                if let f = p.fraction {
                    RWProgressBar(value: f, height: 6)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(p.reviewed) revisados · \(p.pending) pendientes").font(.subheadline)
                    Spacer()
                    if let f = p.fraction {
                        Text(rwPercentText(f, pending: p.pending)).font(.subheadline.bold())
                    }
                }
                Text("Fotos y vídeos de hace más de un año. Los últimos 12 meses aún no se pueden revisar.")
                    .font(.footnote).foregroundStyle(.secondary)
                if p.awaitingConfirmation > 0 {
                    Label("\(p.awaitingConfirmation) por confirmar: marcados para eliminar, pero todavía no eliminados.",
                          systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if p.isPartialAccess {
                    // Mismo estilo violeta que el aviso de acceso limitado de Inicio (el ámbar queda para las rachas).
                    Label("Acceso parcial a Fotos: solo se cuentan las fotos que has permitido. No se muestra porcentaje.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .rwNotice()
                } else if p.fraction == nil {
                    let message: String = (p.reviewed + p.pending == 0)
                        ? "Aún no hay fotos ni vídeos revisables."
                        : "No se puede calcular un porcentaje fiable ahora mismo."
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Calculando…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rwCard()
    }
}

@MainActor
struct StatsView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Query private var decisions: [Decision]
    @State private var streak: StreakResult?

    var body: some View {
        let stats = StatsData(decisions: decisions)
        let streakKey = "\(DateRules.key(for: Date()))-\(stats.usageDays.hashValue)-\(library.status.rawValue)"
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LibraryProgressCard(decisions: decisions)
                    StatTile(title: "días consecutivos", value: streakText, symbol: "flame.fill", color: .rwStreak)
                    Text("Los días sin recuerdos que revisar no rompen la racha. Hoy no la rompe hasta que termine el día.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        StatTile(title: "Fotos", value: "\(stats.photos)", symbol: "photo.fill")
                        StatTile(title: "Vídeos", value: "\(stats.videos)", symbol: "video.fill")
                    }
                    StatsGrid(stats: stats)
                    Text("El espacio liberado solo cuenta elementos cuyo borrado confirmó iOS. Los elementos en «Eliminados recientemente» liberan espacio real al vaciar esa carpeta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Estadísticas")
        }
        .task(id: streakKey) {
            if let value = await library.streak(activeDays: stats.usageDays) { streak = value }
        }
    }

    private var streakText: String {
        guard let s = streak else { return "–" }
        return s.capped ? "\(s.days)+" : "\(s.days)"
    }
}
