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

/// Siguiente hito por alcanzar. Se calcula siempre a partir de los datos actuales (no se guarda nada):
/// si se deshacen decisiones, el hito se recalcula y nunca muestra un logro que ya no es cierto.
private struct MilestoneProgress {
    let current: Double
    let previous: Double
    let target: Double
    var fraction: Double { target > previous ? min(1, max(0, (current - previous) / (target - previous))) : 0 }
}

private enum Milestones {
    static let reviewed: [Int] = [25, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]
    /// En MB (el sistema de archivos de iOS usa unidades decimales).
    private static let freedMegabytes: [Int] = [100, 500, 1_000, 2_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
    static let freedBytes: [Int64] = freedMegabytes.map { Int64($0) * 1_000_000 }

    static func next(value: Int, in steps: [Int]) -> MilestoneProgress? {
        guard let target = steps.first(where: { $0 > value }) else { return nil }
        let previous = steps.last(where: { $0 <= value }) ?? 0
        return MilestoneProgress(current: Double(value), previous: Double(previous), target: Double(target))
    }

    static func next(bytes value: Int64, in steps: [Int64]) -> MilestoneProgress? {
        guard let target = steps.first(where: { $0 > value }) else { return nil }
        let previous = steps.last(where: { $0 <= value }) ?? 0
        return MilestoneProgress(current: Double(value), previous: Double(previous), target: Double(target))
    }
}

/// Etiqueta compacta sobre el degradado de la tarjeta protagonista.
@MainActor
private struct HeroChip: View {
    let symbol: String
    let text: String
    var symbolColor: Color = .white
    var body: some View {
        Label {
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        } icon: {
            Image(systemName: symbol).foregroundStyle(symbolColor)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.2), in: Capsule())
    }
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
    @State private var progress: LibraryProgress?
    @State private var streak: StreakResult?
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

    private var progressKey: String {
        "\(decidedIDs.hashValue)-\(markedIDs.hashValue)-\(library.status.rawValue)"
    }

    var body: some View {
        let stats = StatsData(decisions: decisions)
        let streakKey = "\(DateRules.key(for: Date()))-\(stats.usageDays.hashValue)-\(library.status.rawValue)"
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if library.status == .limited { limitedBanner }
                    if !library.hasAccess { deniedBanner }
                    if library.hasAccess {
                        heroCard
                        milestonesCard(stats)
                        summaryLine(stats)
                    }
                    if !years.isEmpty { yearsDisclosure }
                }
                .padding()
            }
            .navigationTitle("REWIND")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { reload() }
        .task(id: estimateKey) { await updateEstimate() }
        .task(id: progressKey) { await loadProgress() }
        .task(id: streakKey) {
            if let value = await library.streak(activeDays: stats.usageDays) { streak = value }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { reload() } }
        .fullScreenCover(item: $target, onDismiss: { reload(); onSessionEnd() }) { t in
            CleaningView(referenceDay: t.reference, yearsBack: t.yearsBack)
        }
    }

    // MARK: Cabecera

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let base = h < 13 ? "Buenos días" : (h < 21 ? "Buenas tardes" : "Buenas noches")
        return userName.isEmpty ? base : "\(base), \(userName)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).font(.rwTitle)
            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Tarjeta protagonista

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = nextSession {
                sessionHero(s)
            } else {
                doneHero
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RWGradient.hero, in: RoundedRectangle(cornerRadius: RWRadius.hero, style: .continuous))
    }

    @ViewBuilder
    private func sessionHero(_ s: Candidate) -> some View {
        let p = pendingCount(s.refs)
        let c = awaitingCount(s.refs)
        let start = DateRules.reviewInterval(for: s.reference, yearsBack: s.yearsBack).start
        heroChips(label: originText(s, pending: p),
                  symbol: (c > 0 && p == 0) ? "checkmark.shield.fill" : "calendar.badge.clock")
        VStack(alignment: .leading, spacing: 2) {
            Text(start, format: .dateTime.day().month(.wide).year())
                .font(.rwHeroTitle)
                .foregroundStyle(.white)
            Text(yearsAgoText(s.yearsBack))
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.9))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(countsText(pending: p, toConfirm: c))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if estimatedBytes > 0 {
                Text("Espacio estimado recuperable: hasta \(estimatedBytes.byteString)")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
        heroProgress
        Button("CONTINUAR LIMPIEZA") {
            Haptics.tap()
            target = ReviewTarget(reference: s.reference, yearsBack: s.yearsBack)
        }
        .buttonStyle(HeroButtonStyle())
        .padding(.top, 4)
    }

    /// «Todo al día»: mismo lenguaje visual, sin botón (no hay nada que continuar).
    @ViewBuilder
    private var doneHero: some View {
        if let st = streak, st.days > 0 {
            HeroChip(symbol: "flame.fill", text: streakText(st), symbolColor: .rwStreakOnHero)
        }
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.white)
            Text("Todo al día").font(.rwHeroTitle).foregroundStyle(.white)
        }
        Text("No tienes recuerdos pendientes de revisar ni de confirmar.")
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.9))
        heroProgress
    }

    /// Progreso real de la biblioteca: solo se muestra cuando el dato es fiable (acceso completo y datos coherentes).
    @ViewBuilder
    private var heroProgress: some View {
        if let p = progress, let f = p.fraction {
            VStack(alignment: .leading, spacing: 6) {
                RWProgressBar(value: f, fill: .white, track: Color.black.opacity(0.25), height: 8)
                Text("\(rwPercentText(f, pending: p.pending)) revisado · \(p.pending) pendientes")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }

    private func heroChips(label: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipContent(label: label, symbol: symbol) }
            VStack(alignment: .leading, spacing: 8) { chipContent(label: label, symbol: symbol) }
        }
    }

    @ViewBuilder
    private func chipContent(label: String, symbol: String) -> some View {
        HeroChip(symbol: symbol, text: label)
        if let st = streak, st.days > 0 {
            HeroChip(symbol: "flame.fill", text: streakText(st), symbolColor: .rwStreakOnHero)
        }
    }

    private func streakText(_ s: StreakResult) -> String {
        let n = s.capped ? "\(s.days)+" : "\(s.days)"
        return s.days == 1 ? "\(n) día" : "\(n) días"
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

    // MARK: Hitos y resumen

    @ViewBuilder
    private func milestonesCard(_ stats: StatsData) -> some View {
        let reviewedStep = Milestones.next(value: stats.reviewed, in: Milestones.reviewed)
        // Si hay borrados pero el tamaño no se pudo medir, no se muestra un hito de espacio que sería incorrecto.
        let freedReliable = !(stats.deleted > 0 && stats.freed == 0)
        let freedStep = freedReliable ? Milestones.next(bytes: stats.freed, in: Milestones.freedBytes) : nil
        if reviewedStep != nil || freedStep != nil {
            VStack(alignment: .leading, spacing: 14) {
                Text("Próximos hitos").font(.rwHeadline)
                if let m = reviewedStep {
                    milestoneRow(symbol: "eye.fill", title: "Revisados",
                                 detail: "\(Int(m.current)) de \(Int(m.target))", fraction: m.fraction)
                }
                if let m = freedStep {
                    let detail: String = m.current == 0
                        ? "Objetivo: \(Int64(m.target).byteString)"
                        : "\(Int64(m.current).byteString) de \(Int64(m.target).byteString)"
                    milestoneRow(symbol: "externaldrive.fill", title: "Espacio liberado",
                                 detail: detail, fraction: m.fraction)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rwCard()
        }
    }

    private func milestoneRow(symbol: String, title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(Color.rwStreak)
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            RWProgressBar(value: fraction, fill: .rwStreak, height: 6)
        }
    }

    /// Sustituye a la cuadrícula de cuatro estadísticas: una línea sencilla.
    private func summaryLine(_ stats: StatsData) -> some View {
        HStack(spacing: 16) {
            Label("\(stats.reviewed) revisados", systemImage: "eye.fill")
            if stats.freed > 0 {
                Label("\(stats.freed.byteString) liberados", systemImage: "externaldrive.fill")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: Años de este día (plegado)

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
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: RWRadius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Años de este día").font(.rwHeadline)
        }
        .padding(16)
        .rwCard()
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

    // MARK: Avisos de acceso

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
        .background(Color.rwPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: RWRadius.chip, style: .continuous))
    }

    // MARK: Carga de datos (sin cambios de lógica)

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

    private func loadProgress() async {
        let all = decisions.map(\.assetID)
        let marked = decisions.filter { !$0.keep && !$0.deleted }.map(\.assetID)
        if let value = await library.libraryProgress(allIDs: all, markedIDs: marked) {
            progress = value
        }
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
