import SwiftUI
import SwiftData
import Photos
import AVKit

// MARK: - Apoyo visual local

// Los tokens dinámicos (rwKeep, rwDelete, rwFavorite) se aclaran en modo oscuro para leerse como TEXTO sobre
// fondo oscuro. Como RELLENO con icono o texto blanco (botones, sellos, avisos sobre fotos) perderían contraste,
// así que en esos casos se usan los tonos profundos del modo claro en ambos modos (≥ 5:1 con blanco).
private extension Color {
    static let rwKeepFill = Color(hex: 0x0F7F47)
    static let rwDeleteFill = Color(hex: 0xC8323A)
    static let rwFavoriteFill = Color(hex: 0xD41F58)
}

/// Botón de operación destructiva (confirmar el borrado): coral, para no confundirlo con navegar o continuar.
private struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(Color.rwDeleteFill.opacity(enabled ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: RWRadius.button, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Estado que se muestra en la esquina de una miniatura del resumen.
enum ThumbState { case keep, delete }

@MainActor
struct CleaningView: View {
    let referenceDay: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PhotoLibraryService.self) private var library
    @State private var controller: SessionController?
    @State private var yearsBack: Int

    init(referenceDay: Date, yearsBack: Int = 1) {
        self.referenceDay = referenceDay
        _yearsBack = State(initialValue: yearsBack)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let c = controller {
                    if c.assets.isEmpty {
                        ContentUnavailableView("Sin recuerdos", systemImage: "photo.on.rectangle",
                                               description: Text("No hay fotos ni vídeos de ese día."))
                    } else if c.pending.isEmpty {
                        SummaryView(controller: c, onDone: { dismiss() }, onNextYear: { yearsBack = $0 })
                    } else {
                        SwipeDeck(controller: c)
                    }
                } else { ProgressView() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Pausar") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let c = controller {
                        VStack(spacing: 0) {
                            Text(c.interval.start, format: .dateTime.day().month(.abbreviated).year()).font(.headline)
                            Text(c.yearsAgoText).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { controller?.undo(); Haptics.tap() } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                    }
                    .accessibilityLabel("Deshacer")
                    .disabled(!(controller?.canUndo ?? false))
                }
            }
        }
        .task(id: yearsBack) {
            controller = nil
            let c = SessionController(referenceDay: referenceDay, yearsBack: yearsBack, library: library, context: context)
            c.load()
            if c.assets.isEmpty, let older = c.nextYearWithMemories() {
                yearsBack = older   // salta automáticamente los años sin recuerdos
                return
            }
            controller = c
        }
    }
}

// MARK: - Mazo de tarjetas

@MainActor
struct SwipeDeck: View {
    let controller: SessionController
    @State private var offset: CGSize = .zero
    @State private var flying = false
    @State private var flash: Flash?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Flash: Equatable { let text: String; let keep: Bool }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(controller.reviewedCount + 1) de \(controller.assets.count)")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Spacer()
                    Text("\(controller.pending.count) pendientes").font(.footnote).foregroundStyle(.secondary)
                }
                RWProgressBar(value: Double(controller.reviewedCount) / Double(max(controller.assets.count, 1)), height: 6)
            }
            .padding(.horizontal)

            ZStack {
                if let next = controller.pending.dropFirst().first {
                    MediaCard(asset: next).scaleEffect(0.94).opacity(0.7).id(next.localIdentifier)
                }
                if let top = controller.pending.first {
                    MediaCard(asset: top)
                        .overlay { stamp }
                        .id(top.localIdentifier)
                        .offset(offset)
                        .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 22)))
                        .gesture(
                            DragGesture()
                                .onChanged { if !flying { offset = $0.translation } }
                                .onEnded { v in
                                    if abs(v.translation.width) > 110 { fling(keep: v.translation.width > 0) }
                                    else { withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero } }
                                })
                }
            }
            .padding(.horizontal)
            .overlay(alignment: .top) {
                if let f = flash {
                    Label(f.text, systemImage: f.keep ? "checkmark" : "trash.fill")
                        .font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(f.keep ? Color.rwKeepFill : Color.rwDeleteFill, in: Capsule())
                        .padding(.top, 12)
                        .transition(reduceMotion ? AnyTransition.opacity
                                                 : AnyTransition.move(edge: .top).combined(with: .opacity))
                }
            }

            HStack(spacing: 40) {
                actionButton(symbol: "trash.fill", fill: .rwDeleteFill, textColor: .rwDelete, label: "Eliminar") { fling(keep: false) }
                actionButton(symbol: "checkmark", fill: .rwKeepFill, textColor: .rwKeep, label: "Conservar") { fling(keep: true) }
            }
            .padding(.bottom, 8)
        }
    }

    private var stamp: some View {
        let p = max(-1, min(1, offset.width / 120))
        let isFavorite = controller.pending.first?.isFavorite ?? false
        let leftText: String = isFavorite ? "Favorito: marcado para eliminar" : "Marcado para eliminar"
        let fill: Color = p > 0 ? Color.rwKeepFill : Color.rwDeleteFill
        return ZStack {
            RoundedRectangle(cornerRadius: RWRadius.hero, style: .continuous)
                .fill(fill.opacity(0.4))
            Label(p > 0 ? "¡Guardado!" : leftText,
                  systemImage: p > 0 ? "checkmark" : "trash.fill")
                .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(fill, in: Capsule())
        }
        .opacity(abs(p))
        .allowsHitTesting(false)
    }

    private func actionButton(symbol: String, fill: Color, textColor: Color, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 72, height: 72).background(fill, in: Circle())
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(textColor)
            }
        }
        .accessibilityLabel(label)
    }

    private func fling(keep: Bool) {
        guard !flying, let top = controller.pending.first else { return }
        flying = true
        if keep { Haptics.keep() } else { Haptics.delete() }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            offset = CGSize(width: keep ? 700 : -700, height: 40)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            controller.decide(top, keep: keep)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { offset = .zero }
            flying = false
            let leftText: String = top.isFavorite ? "Favorito marcado para eliminar" : "Marcado para eliminar"
            let f = Flash(text: keep ? "¡Guardado!" : leftText, keep: keep)
            withAnimation(reduceMotion ? nil : Animation.spring) { flash = f }
            try? await Task.sleep(for: .milliseconds(900))
            if flash == f { withAnimation(reduceMotion ? nil : Animation.default) { flash = nil } }
        }
    }
}

// MARK: - Tarjeta multimedia

@MainActor
struct MediaCard: View {
    let asset: PHAsset
    @Environment(PhotoLibraryService.self) private var library
    @State private var image: UIImage?
    @State private var place: String?
    @State private var player: AVPlayer?
    @State private var playing = false

    private var isVideo: Bool { asset.mediaType == .video }

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player).allowsHitTesting(false) }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
            if isVideo && !playing {
                Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .overlay(alignment: .bottom) { info }
        .overlay(alignment: .topTrailing) {
            if asset.isFavorite {
                Label("Favorito", systemImage: "heart.fill")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.rwFavoriteFill, in: Capsule())
                    .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: RWRadius.hero, style: .continuous))
        .overlay {
            // Los favoritos de Apple Fotos llevan borde rosa; el resto, un filete casi invisible (sin sombras).
            RoundedRectangle(cornerRadius: RWRadius.hero, style: .continuous)
                .strokeBorder(asset.isFavorite ? Color.rwFavoriteFill : Color.primary.opacity(0.08),
                              lineWidth: asset.isFavorite ? 3 : 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: RWRadius.hero))
        .onTapGesture { togglePlay() }
        .task(id: asset.localIdentifier) {
            image = await library.image(for: asset, size: CGSize(width: 1080, height: 1440))
            place = await library.placeName(for: asset)
        }
        .onDisappear { player?.pause() }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(isVideo ? "Vídeo · \(durationText)" : "Foto", systemImage: isVideo ? "video.fill" : "photo.fill")
                    .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.55), in: Capsule())
                Spacer()
            }
            if let d = asset.creationDate {
                Label(d.formatted(date: .long, time: .shortened), systemImage: "calendar").font(.subheadline.weight(.semibold))
            }
            if let place { Label(place, systemImage: "mappin.and.ellipse").font(.footnote) }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    private var durationText: String {
        let s = Int(asset.duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func togglePlay() {
        guard isVideo else { return }
        if let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
        } else {
            Task {
                guard let item = await library.playerItem(for: asset) else { return }
                let p = AVPlayer(playerItem: item)
                player = p; p.play(); playing = true
            }
        }
    }
}

// MARK: - Resumen

@MainActor
struct SummaryView: View {
    let controller: SessionController
    let onDone: () -> Void
    let onNextYear: (Int) -> Void
    @State private var confirming = false
    @State private var working = false
    @State private var showKept = false
    @State private var resultText: String?
    @State private var nextYear: Int?
    @State private var nextYearChecked = false

    var body: some View {
        let marked = controller.markedAssets
        let total = controller.markedCount
        let favoriteCount = controller.markedFavoriteCount
        let keepLabel: String = total > favoriteCount
            ? "Eliminar solo \(total - favoriteCount) y conservar los favoritos"
            : "Conservar los favoritos y no eliminar nada"
        let dialogMessage: String = favoriteCount > 0
            ? "\(favoriteCount) de ellos son favoritos ♥ de Apple Fotos. Elige si quieres eliminarlos también. iOS te pedirá autorización y podrás recuperarlos desde «Eliminados recientemente» durante 30 días."
            : "iOS te pedirá autorización. Podrás recuperarlos desde «Eliminados recientemente» durante 30 días."
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Resumen").font(.rwHeroTitle)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(title: "Fotos revisadas", value: "\(controller.photosReviewed)", symbol: "photo.fill")
                    StatTile(title: "Vídeos revisados", value: "\(controller.videosReviewed)", symbol: "video.fill")
                    StatTile(title: "Se conservarán", value: "\(controller.keptCount)", symbol: "checkmark.circle.fill", color: .rwKeep)
                    StatTile(title: "Para eliminar", value: "\(controller.markedCount)", symbol: "trash.fill", color: .rwDelete)
                }
                if controller.markedBytes > 0 {
                    Text("Espacio que se podría liberar: hasta \(controller.markedBytes.byteString)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if favoriteCount > 0 {
                    Label("\(favoriteCount) favoritos de Apple Fotos entre los seleccionados (con ♥). Se te pedirá confirmación expresa para eliminarlos.",
                          systemImage: "heart.fill")
                        .font(.footnote.bold()).foregroundStyle(Color.rwFavorite)
                }
                let regularMarked = marked.filter { !$0.isFavorite }
                let favoriteMarked = marked.filter { $0.isFavorite }
                if !regularMarked.isEmpty {
                    section("Seleccionados para eliminar (\(regularMarked.count))", "Toca uno para conservarlo",
                            regularMarked, symbol: "trash.fill", color: .rwDelete, state: .delete)
                }
                if !favoriteMarked.isEmpty {
                    section("Favoritos de Apple Fotos (\(favoriteMarked.count))",
                            "Marcados para eliminar: se te pedirá confirmación expresa. Toca uno para conservarlo.",
                            favoriteMarked, symbol: "heart.fill", color: .rwFavorite, state: .delete)
                }
                let kept = controller.keptAssets
                if !kept.isEmpty {
                    DisclosureGroup(isExpanded: $showKept) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Toca uno para marcarlo para eliminar").font(.caption).foregroundStyle(.secondary)
                            thumbGrid(kept, state: .keep)
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text("Conservados (\(kept.count))")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .font(.rwHeadline).foregroundStyle(Color.rwKeep)
                    }
                }
                if let r = resultText { Text(r).font(.footnote).foregroundStyle(.secondary) }
                if let e = controller.lastError { Text(e).font(.footnote).foregroundStyle(Color.rwDelete) }

                if marked.isEmpty {
                    finishedBlock
                }
                Button("Reiniciar sesión") { controller.restart() }
                    .frame(maxWidth: .infinity).foregroundStyle(.secondary)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if !marked.isEmpty {
                Button { confirming = true } label: {
                    VStack(spacing: 2) {
                        Label("CONFIRMAR LIMPIEZA", systemImage: "trash.fill")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                        Text(confirmSubtitle(total: total, favorites: favoriteCount, bytes: controller.markedBytes))
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(working)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .overlay(alignment: .top) { Divider() }
            }
        }
        .task { await NotificationService.requestIfNeeded() }   // permiso contextual
        .task(id: marked.isEmpty) {
            nextYear = nil
            nextYearChecked = false
            if marked.isEmpty {
                nextYear = controller.nextYearWithMemories()
                nextYearChecked = true
            }
        }
        .confirmationDialog("¿Eliminar \(total) elementos?",
                            isPresented: $confirming, titleVisibility: .visible) {
            if favoriteCount > 0 {
                Button("Eliminar los \(total) (incluye \(favoriteCount) favoritos)", role: .destructive) {
                    run(includeFavorites: true)
                }
                Button(keepLabel) { run(includeFavorites: false) }
            } else {
                Button("Eliminar \(total)", role: .destructive) { run(includeFavorites: false) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }

    /// Limpieza terminada: pregunta dentro de la app si se quiere revisar otro año atrás.
    private var finishedBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let n = nextYear {
                Text("¿Quieres revisar otro año atrás?").font(.headline)
                Text("Hay recuerdos de este día en \(yearLabel(n)).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Sí, revisar \(yearLabel(n))") { Haptics.tap(); onNextYear(n) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("No, terminar", action: onDone)
                    .frame(maxWidth: .infinity).foregroundStyle(.secondary)
            } else {
                if nextYearChecked {
                    Text("No hay más años anteriores con recuerdos de este día en tu biblioteca.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("TERMINAR", action: onDone).buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func confirmSubtitle(total: Int, favorites: Int, bytes: Int64) -> String {
        var text = "\(total) elementos"
        if favorites > 0 { text += " · \(favorites) favoritos" }
        if bytes > 0 { text += " · hasta \(bytes.byteString)" }
        return text
    }

    private func yearLabel(_ n: Int) -> String {
        let year = controller.year(yearsBack: n)
        let unit = n == 1 ? "año" : "años"
        return "\(year) (hace \(n) \(unit))"
    }

    private func run(includeFavorites: Bool) {
        Task {
            working = true
            if let outcome = await controller.confirmDeletion(includeFavorites: includeFavorites) {
                resultText = describe(outcome)
                if outcome.deleted > 0 { Haptics.keep() }
            }
            working = false
        }
    }

    private func describe(_ o: SessionController.DeletionOutcome) -> String {
        var parts: [String] = []
        if o.deleted > 0 {
            parts.append("Listo: \(o.deleted) elementos enviados a «Eliminados recientemente» (\(o.deletedBytes.byteString)). El espacio se libera del todo cuando esa carpeta se vacía (a los 30 días o manualmente).")
        }
        if o.keptFavorites > 0 {
            parts.append("\(o.keptFavorites) favoritos se han conservado (no se eliminaron).")
        }
        if o.unverified > 0 {
            parts.append("\(o.unverified) elementos no se pudieron verificar y NO se han eliminado; siguen marcados para que puedas reintentarlo.")
        }
        return parts.isEmpty ? "No se ha eliminado nada." : parts.joined(separator: "\n")
    }

    private func section(_ title: String, _ hint: String, _ list: [PHAsset],
                         symbol: String, color: Color, state: ThumbState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.rwHeadline).foregroundStyle(color)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            thumbGrid(list, state: state)
        }
    }

    private func thumbGrid(_ list: [PHAsset], state: ThumbState) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(list, id: \.localIdentifier) { a in
                ThumbView(asset: a, state: state).onTapGesture { Haptics.tap(); controller.toggle(a) }
            }
        }
    }
}

@MainActor
struct ThumbView: View {
    let asset: PHAsset
    var state: ThumbState? = nil
    @Environment(PhotoLibraryService.self) private var library
    @State private var image: UIImage?
    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .overlay(alignment: .topLeading) {
                if asset.isFavorite {
                    // Corazón: exclusivamente favoritos de Apple Fotos. Fondo claro para leerse sobre cualquier foto.
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.rwFavoriteFill)
                        .padding(4).background(Color.white, in: Circle()).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let state {
                    Image(systemName: state == .keep ? "checkmark.circle.fill" : "trash.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, state == .keep ? Color.rwKeepFill : Color.rwDeleteFill)
                        .font(.title3)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: RWRadius.chip, style: .continuous))
            .task(id: asset.localIdentifier) { image = await library.image(for: asset, size: CGSize(width: 240, height: 240)) }
    }
}
