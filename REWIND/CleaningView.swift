import SwiftUI
import SwiftData
import Photos
import AVKit

@MainActor
struct CleaningView: View {
    let referenceDay: Date
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PhotoLibraryService.self) private var library
    @State private var controller: SessionController?

    var body: some View {
        NavigationStack {
            Group {
                if let c = controller {
                    if c.assets.isEmpty {
                        ContentUnavailableView("Sin recuerdos", systemImage: "photo.on.rectangle",
                                               description: Text("No hay fotos ni vídeos de ese día."))
                    } else if c.pending.isEmpty {
                        SummaryView(controller: c, onDone: { dismiss() })
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
                        Text(c.interval.start, format: .dateTime.day().month(.abbreviated).year()).font(.headline)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { controller?.undo(); Haptics.tap() } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                    }
                    .disabled(!(controller?.canUndo ?? false))
                }
            }
        }
        .task {
            let c = SessionController(referenceDay: referenceDay, library: library, context: context)
            c.load()
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

    struct Flash: Equatable { let text: String; let keep: Bool }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(controller.reviewedCount + 1) de \(controller.assets.count)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(controller.pending.count) pendientes").font(.footnote).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(controller.reviewedCount),
                             total: Double(max(controller.assets.count, 1))).tint(.rwPurple)
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
                        .rotationEffect(.degrees(Double(offset.width / 22)))
                        .gesture(
                            DragGesture()
                                .onChanged { if !flying { offset = $0.translation } }
                                .onEnded { v in
                                    if abs(v.translation.width) > 110 { fling(keep: v.translation.width > 0) }
                                    else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero } }
                                })
                }
            }
            .padding(.horizontal)
            .overlay(alignment: .top) {
                if let f = flash {
                    Text(f.text).font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(f.keep ? Color.rwKeep : Color.rwDelete, in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            HStack(spacing: 40) {
                circleButton("trash.fill", .rwDelete, label: "Eliminar") { fling(keep: false) }
                circleButton("heart.fill", .rwKeep, label: "Conservar") { fling(keep: true) }
            }
            .padding(.bottom, 8)
        }
    }

    private var stamp: some View {
        let p = max(-1, min(1, offset.width / 120))
        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill((p > 0 ? Color.rwKeep : Color.rwDelete).opacity(0.4))
            Label(p > 0 ? "¡Guardado!" : "Marcado para eliminar",
                  systemImage: p > 0 ? "heart.fill" : "trash.fill")
                .font(.title2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(p > 0 ? Color.rwKeep : Color.rwDelete, in: Capsule())
        }
        .opacity(abs(p))
        .allowsHitTesting(false)
    }

    private func circleButton(_ symbol: String, _ color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title).foregroundStyle(.white)
                .frame(width: 72, height: 72).background(color, in: Circle())
                .shadow(color: color.opacity(0.4), radius: 10, y: 4)
        }
        .accessibilityLabel(label)
    }

    private func fling(keep: Bool) {
        guard !flying, let top = controller.pending.first else { return }
        flying = true
        if keep { Haptics.keep() } else { Haptics.delete() }
        withAnimation(.easeOut(duration: 0.25)) {
            offset = CGSize(width: keep ? 700 : -700, height: 40)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            controller.decide(top, keep: keep)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { offset = .zero }
            flying = false
            let f = Flash(text: keep ? "¡Guardado!" : "Marcado para eliminar", keep: keep)
            withAnimation(.spring) { flash = f }
            try? await Task.sleep(for: .milliseconds(900))
            if flash == f { withAnimation { flash = nil } }
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
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 28))
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
                    .background(.ultraThinMaterial, in: Capsule())
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
    @State private var confirming = false
    @State private var working = false
    @State private var resultText: String?

    var body: some View {
        let marked = controller.markedAssets
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Resumen").font(.largeTitle.bold())
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(title: "Fotos revisadas", value: "\(controller.photosReviewed)", symbol: "photo.fill")
                    StatTile(title: "Vídeos revisados", value: "\(controller.videosReviewed)", symbol: "video.fill")
                    StatTile(title: "Se conservarán", value: "\(controller.keptCount)", symbol: "heart.fill", color: .rwKeep)
                    StatTile(title: "Para eliminar", value: "\(controller.markedCount)", symbol: "trash.fill", color: .rwDelete)
                }
                if controller.markedBytes > 0 {
                    Text("Espacio que se podría liberar: hasta \(controller.markedBytes.byteString)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !marked.isEmpty {
                    section("Seleccionados para eliminar", "Toca uno para conservarlo", marked, .rwDelete)
                }
                let kept = controller.keptAssets
                if !kept.isEmpty {
                    section("Conservados", "Toca uno para marcarlo para eliminar", kept, .rwKeep)
                }
                if let r = resultText { Text(r).font(.footnote).foregroundStyle(.secondary) }
                if let e = controller.lastError { Text(e).font(.footnote).foregroundStyle(Color.rwDelete) }

                if marked.isEmpty || resultText != nil {
                    Button("TERMINAR", action: onDone).buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("CONFIRMAR LIMPIEZA") { confirming = true }
                        .buttonStyle(PrimaryButtonStyle()).disabled(working)
                }
                Button("Reiniciar sesión") { controller.restart() }
                    .frame(maxWidth: .infinity).foregroundStyle(.secondary)
            }
            .padding()
        }
        .task { await NotificationService.requestIfNeeded() }   // permiso contextual
        .confirmationDialog("¿Eliminar \(controller.markedCount) elementos?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Eliminar \(controller.markedCount)", role: .destructive) {
                Task {
                    working = true
                    let bytes = controller.markedBytes, n = controller.markedCount
                    if await controller.confirmDeletion() {
                        resultText = "Listo: \(n) elementos enviados a «Eliminados recientemente» (\(bytes.byteString)). El espacio se libera del todo cuando esa carpeta se vacía (a los 30 días o manualmente)."
                        Haptics.keep()
                    }
                    working = false
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("iOS te pedirá autorización. Podrás recuperarlos desde «Eliminados recientemente» durante 30 días.")
        }
    }

    private func section(_ title: String, _ hint: String, _ list: [PHAsset], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(color)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(list, id: \.localIdentifier) { a in
                    ThumbView(asset: a).onTapGesture { Haptics.tap(); controller.toggle(a) }
                }
            }
        }
    }
}

@MainActor
struct ThumbView: View {
    let asset: PHAsset
    @Environment(PhotoLibraryService.self) private var library
    @State private var image: UIImage?
    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: asset.localIdentifier) { image = await library.image(for: asset, size: CGSize(width: 240, height: 240)) }
    }
}
