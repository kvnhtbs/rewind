import SwiftUI

@MainActor
struct OnboardingView: View {
    @Environment(PhotoLibraryService.self) private var library
    @AppStorage(Keys.onboarded) private var onboarded = false

    private let steps: [(String, String)] = [
        ("clock.arrow.circlepath", "Cada día recuperamos tus fotos y vídeos de hace un año."),
        ("hand.draw.fill", "Desliza a la derecha para conservar y a la izquierda para eliminar."),
        ("lock.shield.fill", "Confirma la limpieza cuando termines. Nada se borra sin tu permiso.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text("REWIND").font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(Color.rwPurple)
            Text("Tu galería acumula miles de recuerdos. Nosotros te ayudamos a decidir cuáles merecen quedarse.")
                .font(.title3.weight(.medium))
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 16) {
                        Image(systemName: s.0).font(.title2).foregroundStyle(Color.rwPurple).frame(width: 40)
                        Text("\(i + 1). \(s.1)").font(.body)
                    }
                }
            }
            Spacer()
            if library.status == .denied || library.status == .restricted {
                Text("Sin acceso a Fotos REWIND no puede funcionar. Puedes activarlo en Ajustes.")
                    .font(.footnote).foregroundStyle(Color.rwDelete)
                Button("Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("Permitir acceso a Fotos") {
                Task {
                    await library.requestAccess()
                    onboarded = true
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Text("Un año después, decide qué recuerdos merecen quedarse.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            Text("Todo se procesa en tu dispositivo. Ninguna foto sale de tu iPhone.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}
