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
    let reference: Date
    let refs: [AssetRef]
    var id: Int { yearsBack }
}

private struct ReviewTarget: Identifiable {
    let id = UUID()
    let reference: Date
    var yearsBack: Int = 1
}

/// Una sesión que se puede ofrecer: un día concreto de un año concreto.
private struct Candidate {
    enum Origin { case today, backlog, olderYear }
    let origin: Origin
    let reference: Date
    let yearsBack: Int
    let refs: [AssetRef]
}

@MainActor
struct HomeView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Query private var decisions: [Decision]
    @AppStorage(Keys.userName) private var userName = ""
    @State private var days: [DayInfo] = []
    @State private var years: [YearInfo] = []
    @State private var estimatedBytes: Int64 = 0
    @State private var showYears = false
    @State private var target: ReviewTarget?
    let onSessionEnd: () -> Void

    private var decidedIDs: Set<String> { Set(decisions.map(\.assetID)) }
    /// Elementos ya deslizados a la izquierda cuyo borrado aún no se ha confirmado.
    private var markedIDs: Set<String> { Set(decisions.filter { !$0.keep && !$0.deleted }.map(\.assetID)) }
    private func pendingCount(_ refs: [AssetRef]) -> Int { refs.filter { !decidedIDs.contains($0.id) }.count }
    private func awaitingCount(_ refs: [AssetRef]) -> Int { refs.filter { markedIDs.contains($0.id) }.count }

    // MARK: Cola de sesiones

    /// Orden natural: hoy (hace 1 año) → días atrasados (más reciente primero) → años anteriores (del más cercano al más lejano).
    private var candidates: [Candidate] {
        var list: [Candidate] = []
        for d in days {
            list.append(Candidate(origin: d.offset == 0 ? .today : .backlog,
                                  reference: d.reference, yearsBack: 1, refs: d.refs))
        }
        for y in years where y.yearsBack >= 2 {
            list.append(Candidate(origin: .olderYear, reference: y.reference, yearsBack: y.yearsBack, refs: y.refs))
        }
        return list
    }

    /// Siguiente sesión que se ofrece. Prioridad: 1) pendiente de confirmar, 2) hoy hace 1 año,
    /// 3) días atrasados, 4) años anteriores. Nunca devuelve sesiones vacías ni ya completadas.
    private var nextSession: Candidate? {
        let decided = decidedIDs
        let marked = markedIDs
        let all = candidates
        if let s = all.first(where: { c in c.refs.contains { marked.contains($0.id) } }) { return s }
        return all.first(where: { c in c.refs.contains { !decided.contains($0.id) } })
    }

    private var estimateKey: String {
        guard let s = nextSession else { return "none" }
        let stamp = Int(s.reference.timeIntervalSince1970)
        return "\(s.yearsBack)-\(stamp)-\(pendingCount(s.refs))-\(awaitingCount(s.refs))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if library.status == .limited { limitedBanner }
                    if !library.hasAccess { deniedBanner }
                    if library.hasAccess { continueCard }
                    if !years.isEmpty { yearsDisclosure }
                    yearProgress
                    StatsGrid(stats: StatsData(decisions: decisions))
                }
                .padding()
            }
            .navigationTitle("REWIND")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { reload() }
        .task(id: estimateKey) { await updateEstimate() }
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

    /// Acción principal única: continuar con la siguiente sesión pendiente.
    private var continueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = nextSession {
                let p = pendingCount(s.refs)
                let c = awaitingCount(s.refs)
                let start = DateRules.reviewInterval(for: s.reference, yearsBack: s.yearsBack).start
                Label {
                    Text(originText(s, pending: p))
                } icon: {
                    Image(systemName: (c > 0 && p == 0) ? "checkmark.shield.fill" : "calendar.badge.clock")
                        .foregroundStyle(Color.rwPurple)
                }
                .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(start, format: .dateTime.day().month(.wide).year()).font(.title2.bold())
                    Text(yearsAgoText(s.yearsBack)).font(.footnote).foregroundStyle(.secondary)
                }
                Text(countsText(pending: p, toConfirm: c)).font(.subheadline)
                if estimatedBytes > 0 {
                    Text("Espacio estimado recuperable: hasta \(estimatedBytes.byteString)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("CONTINUAR LIMPIEZA") {
                    Haptics.tap()
                    target = ReviewTarget(reference: s.reference, yearsBack: s.yearsBack)
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Label {
                    Text("Todo al día")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.rwKeep)
                }
                .font(.headline)
                Text("No tienes recuerdos pendientes de revisar ni de confirmar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func originText(_ s: Candidate, pending p: Int) -> String {
        if p == 0 { return "Pendiente de confirmar" }
        switch s.origin {
        case .today: return "Recuerdos de hoy"
        case .backlog: return "Día atrasado"
        case .olderYear: return "Año anterior"
        }
    }

    private func yearsAgoText(_ n: Int) -> String {
        n == 1 ? "hace 1 año" : "hace \(n) años"
    }

    private func countsText(pending p: Int, toConfirm c: Int) -> String {
        if p > 0 && c > 0 { return "\(p) elementos por revisar · \(c) por confirmar" }
        if p > 0 { return "\(p) elementos por revisar" }
        return "\(c) elementos por confirmar"
    }

    /// Espacio estimado de la sesión ofrecida: lo ya marcado (tamaño guardado) + lo pendiente (como máximo).
    private func updateEstimate() async {
        estimatedBytes = 0
        guard let s = nextSession else { return }
        let ids = Set(s.refs.map(\.id))
        let markedBytes = decisions
            .filter { !$0.keep && !$0.deleted && ids.contains($0.assetID) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        let decided = decidedIDs
        let pendingIDs = s.refs.map(\.id).filter { !decided.contains($0) }
        let pendingBytes = await library.totalSize(of: pendingIDs)
        guard !Task.isCancelled else { return }
        estimatedBytes = markedBytes + pendingBytes
    }

    /// Volver a consultar cualquier año ya revisado (plegado para no competir con la acción principal).
    private var yearsDisclosure: some View {
        DisclosureGroup(isExpanded: $showYears) {
            VStack(spacing: 10) {
                ForEach(years) { y in
                    Button { target = ReviewTarget(reference: y.reference, yearsBack: y.yearsBack) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(yearTitle(y))
                                Text(yearSubtitle(y)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Años de este día").font(.headline)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            if !refs.isEmpty { found.append(YearInfo(yearsBack: n, year: year, reference: now, refs: refs)) }
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
    }
}
