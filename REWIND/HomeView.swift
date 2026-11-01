import SwiftUI
import SwiftData

private struct DayInfo: Identifiable {
    let offset: Int
    let reference: Date
    let refs: [AssetRef]
    var id: Int { offset }
}

private struct ReviewTarget: Identifiable {
    let id = UUID()
    let reference: Date
}

@MainActor
struct HomeView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Query private var decisions: [Decision]
    @AppStorage(Keys.userName) private var userName = ""
    @State private var days: [DayInfo] = []
    @State private var freeable: Int64 = 0
    @State private var target: ReviewTarget?
    let onSessionEnd: () -> Void

    private var decidedIDs: Set<String> { Set(decisions.map(\.assetID)) }
    private func pending(_ d: DayInfo) -> [AssetRef] { d.refs.filter { !decidedIDs.contains($0.id) } }
    private var today: DayInfo? { days.first }
    private var todayPending: [AssetRef] { today.map(pending) ?? [] }
    private var backlog: [DayInfo] { days.dropFirst().filter { !pending($0).isEmpty } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if library.status == .limited { limitedBanner }
                    if !library.hasAccess { deniedBanner }
                    todayCard
                    if !backlog.isEmpty { backlogSection }
                    yearProgress
                    StatsGrid(stats: StatsData(decisions: decisions))
                }
                .padding()
            }
            .navigationTitle("REWIND")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { reload() }
        .onChange(of: scenePhase) { _, p in if p == .active { reload() } }
        .fullScreenCover(item: $target, onDismiss: { reload(); onSessionEnd() }) { t in
            CleaningView(referenceDay: t.reference)
        }
    }

    // MARK: Secciones

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let base = h < 13 ? "Buenos días" : (h < 21 ? "Buenas tardes" : "Buenas noches")
        return userName.isEmpty ? base : "\(base), \(userName)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.largeTitle.bold())
            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide).year())
                .foregroundStyle(.secondary)
        }
    }

    private var todayCard: some View {
        let refs = todayPending
        let photos = refs.filter { !$0.isVideo }.count
        let videos = refs.count - photos
        let review = DateRules.reviewInterval(for: Date()).start
        return VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Hoy toca revisar el \(review.formatted(.dateTime.day().month(.wide).year()))")
            } icon: { Image(systemName: "calendar.badge.clock").foregroundStyle(Color.rwPurple) }
            .font(.headline)
            HStack(spacing: 12) {
                StatTile(title: "Fotos pendientes", value: "\(photos)", symbol: "photo.fill")
                StatTile(title: "Vídeos pendientes", value: "\(videos)", symbol: "video.fill")
            }
            if freeable > 0 {
                Text("Espacio potencialmente recuperable: hasta \(freeable.byteString)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(refs.isEmpty ? "NADA PENDIENTE HOY" : "EMPEZAR LIMPIEZA") {
                Haptics.tap(); target = ReviewTarget(reference: Date())
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(refs.isEmpty || !library.hasAccess)
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var backlogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Días pendientes").font(.headline)
            ForEach(backlog) { d in
                Button { target = ReviewTarget(reference: d.reference) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(DateRules.reviewInterval(for: d.reference).start,
                                 format: .dateTime.day().month(.wide).year())
                            Text("\(pending(d).count) elementos").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var yearProgress: some View {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let doy = cal.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let used = StatsData(decisions: decisions).usageDays.filter { cal.component(.year, from: $0) == year }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Progreso de limpieza de \(year, format: .number.grouping(.never))").font(.headline)
            ProgressView(value: Double(min(used, doy)), total: Double(doy)).tint(.rwPurple)
            Text("\(used) de \(doy) días revisados").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var limitedBanner: some View {
        banner("Acceso limitado: REWIND solo ve las fotos que seleccionaste.", button: "Gestionar") {
            library.presentLimitedPicker()
        }
    }

    private var deniedBanner: some View {
        banner("REWIND no tiene acceso a tu biblioteca. Actívalo en Ajustes.", button: "Abrir Ajustes") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func banner(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.footnote)
            Spacer()
            Button(button, action: action).font(.footnote.bold())
        }
        .padding(12)
        .background(Color.rwPurple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func reload() {
        library.refreshStatus()
        guard library.hasAccess else { days = []; return }
        let cal = Calendar.current
        let now = Date()
        days = (0..<15).map { n in
            let ref = cal.date(byAdding: .day, value: -n, to: now)!
            return DayInfo(offset: n, reference: ref, refs: library.refs(in: DateRules.reviewInterval(for: ref)))
        }
        let ids = todayPending.map(\.id)
        Task { freeable = await library.totalSize(of: ids) }
    }
}
