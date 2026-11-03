import SwiftUI
import SwiftData

private struct DayInfo: Identifiable {
    let offset: Int
    let reference: Date
    let refs: [AssetRef]
    var id: Int { offset }
}

private struct YearInfo: Identifiable {
    let yearsBack: Int
    let year: Int
    let refs: [AssetRef]
    var id: Int { yearsBack }
}

private struct ReviewTarget: Identifiable {
    let id = UUID()
    let reference: Date
    var yearsBack: Int = 1
}

@MainActor
struct HomeView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Query private var decisions: [Decision]
    @AppStorage(Keys.userName) private var userName = ""
    @State private var days: [DayInfo] = []
    @State private var years: [YearInfo] = []
    @State private var freeable: Int64 = 0
    @State private var target: ReviewTarget?
    let onSessionEnd: () -> Void

    private var decidedIDs: Set<String> { Set(decisions.map(\.assetID)) }
    private func pending(_ d: DayInfo) -> [AssetRef] { d.refs.filter { !decidedIDs.contains($0.id) } }
    private var today: DayInfo? { days.first }
    private var todayPending: [AssetRef] { today.map(pending) ?? [] }
    /// Elementos ya deslizados a la izquierda cuyo borrado aún no se ha confirmado.
    private var markedIDs: Set<String> { Set(decisions.filter { !$0.keep && !$0.deleted }.map(\.assetID)) }
    private func awaitingConfirmation(_ d: DayInfo) -> Int { d.refs.filter { markedIDs.contains($0.id) }.count }
    private var backlog: [DayInfo] {
        days.dropFirst().filter { !pending($0).isEmpty || awaitingConfirmation($0) > 0 }
    }
    private func pendingCount(_ refs: [AssetRef]) -> Int { refs.filter { !decidedIDs.contains($0.id) }.count }
    private func awaitingCount(_ refs: [AssetRef]) -> Int { refs.filter { markedIDs.contains($0.id) }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if library.status == .limited { limitedBanner }
                    if !library.hasAccess { deniedBanner }
                    todayCard
                    if !backlog.isEmpty { backlogSection }
                    if !years.isEmpty { otherYearsSection }
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
            CleaningView(referenceDay: t.reference, yearsBack: t.yearsBack)
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
        let toConfirm = today.map(awaitingConfirmation) ?? 0
        let fallback: YearInfo? = (refs.isEmpty && toConfirm == 0)
            ? years.first(where: { pendingCount($0.refs) > 0 || awaitingCount($0.refs) > 0 }) : nil
        let startYears = fallback?.yearsBack ?? 1
        let buttonTitle: String
        if !refs.isEmpty { buttonTitle = "EMPEZAR LIMPIEZA" }
        else if toConfirm > 0 { buttonTitle = "REVISAR RESUMEN" }
        else if fallback != nil { buttonTitle = "EMPEZAR LIMPIEZA" }
        else { buttonTitle = "NADA PENDIENTE HOY" }
        let fallbackNote: String? = fallback.map {
            "No hay recuerdos pendientes de hace un año. Empezaremos por \(String($0.year))."
        }
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
            if let fallbackNote {
                Text(fallbackNote).font(.footnote).foregroundStyle(.secondary)
            }
            Button(buttonTitle) {
                Haptics.tap(); target = ReviewTarget(reference: Date(), yearsBack: startYears)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled((refs.isEmpty && toConfirm == 0 && fallback == nil) || !library.hasAccess)
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
                            Text(rowSubtitle(d)).font(.footnote).foregroundStyle(.secondary)
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

    private var otherYearsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Años de este día").font(.headline)
            ForEach(years) { y in
                Button { target = ReviewTarget(reference: Date(), yearsBack: y.yearsBack) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(yearTitle(y))
                            Text(yearSubtitle(y)).font(.footnote).foregroundStyle(.secondary)
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

    private func yearTitle(_ y: YearInfo) -> String {
        let unit = y.yearsBack == 1 ? "año" : "años"
        return "\(y.year) · hace \(y.yearsBack) \(unit)"
    }

    private func yearSubtitle(_ y: YearInfo) -> String {
        let p = pendingCount(y.refs)
        let c = awaitingCount(y.refs)
        if p > 0 && c > 0 { return "\(p) pendientes · \(c) por confirmar" }
        if p > 0 { return "\(p) pendientes" }
        if c > 0 { return "\(c) por confirmar" }
        return "Revisado · \(y.refs.count) elementos"
    }

    /// Todos los años (desde hace 1 año) con recuerdos de este mismo día, hasta la foto más antigua.
    private func loadYears(now: Date) -> [YearInfo] {
        guard let oldest = library.oldestCaptureDate() else { return [] }
        let cal = DateRules.calendar
        let oldestYear = cal.component(.year, from: oldest)
        var found: [YearInfo] = []
        var n = 1
        while true {
            let interval = DateRules.reviewInterval(for: now, yearsBack: n)
            let year = cal.component(.year, from: interval.start)
            if year < oldestYear { break }
            let refs = library.refs(in: interval)
            if !refs.isEmpty { found.append(YearInfo(yearsBack: n, year: year, refs: refs)) }
            n += 1
        }
        return found
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

    private func rowSubtitle(_ d: DayInfo) -> String {
        let p = pending(d).count
        let c = awaitingConfirmation(d)
        if p > 0 && c > 0 { return "\(p) elementos · \(c) por confirmar" }
        if p > 0 { return "\(p) elementos" }
        return "\(c) por confirmar"
    }

    private func reload() {
        library.refreshStatus()
        guard library.hasAccess else { days = []; years = []; return }
        let cal = Calendar.current
        let now = Date()
        days = (0..<15).map { n in
            let ref = cal.date(byAdding: .day, value: -n, to: now)!
            return DayInfo(offset: n, reference: ref, refs: library.refs(in: DateRules.reviewInterval(for: ref)))
        }
        years = loadYears(now: now)
        let ids = todayPending.map(\.id)
        Task { freeable = await library.totalSize(of: ids) }
    }
}
