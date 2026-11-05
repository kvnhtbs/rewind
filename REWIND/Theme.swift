import SwiftUI
import UIKit

// MARK: - Paleta (modo claro y oscuro)
//
// Violeta   → acción principal y navegación
// Verde     → conservar (siempre acompañado del símbolo ✓)
// Coral     → eliminar
// Rosa      → favoritos de Apple Fotos (el corazón se reserva solo para esto)
// Ámbar     → rachas y motivación
//
// Contrastes verificados (WCAG): texto/icono ≥ 4,5:1 sobre las superficies del sistema en claro y oscuro,
// y texto blanco ≥ 4,5:1 sobre cada color de relleno.

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// Color que cambia automáticamente con el modo claro/oscuro del sistema.
    static func rwDynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Violeta de acento (texto, iconos, navegación).
    static let rwPurple = Color.rwDynamic(light: 0x5B3DF5, dark: 0xA88CFA)
    /// Violeta de relleno (botones con texto blanco).
    static let rwPrimaryFill = Color.rwDynamic(light: 0x5B3DF5, dark: 0x6C4BF4)
    /// Conservar.
    static let rwKeep = Color.rwDynamic(light: 0x0F7F47, dark: 0x34C77B)
    /// Eliminar.
    static let rwDelete = Color.rwDynamic(light: 0xC8323A, dark: 0xFF6B66)
    /// Favoritos de Apple Fotos.
    static let rwFavorite = Color.rwDynamic(light: 0xD41F58, dark: 0xFF6B94)
    /// Rachas y motivación.
    static let rwStreak = Color.rwDynamic(light: 0xB45309, dark: 0xFFB340)
    /// Ámbar sobre el degradado de la tarjeta protagonista (fijo en claro y oscuro).
    static let rwStreakOnHero = Color(hex: 0xFFC857)
    /// Texto del botón blanco de la tarjeta protagonista.
    static let rwOnHero = Color(hex: 0x3E22C4)
}

enum RWGradient {
    /// Único degradado de la app (tarjeta protagonista). Estático: sin animación ni desenfoque.
    static let hero = LinearGradient(colors: [Color(hex: 0x3E22C4), Color(hex: 0x5E40F6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Radios y tipografía

enum RWRadius {
    static let chip: CGFloat = 12
    static let button: CGFloat = 16
    static let card: CGFloat = 20
    static let hero: CGFloat = 28
}

extension Font {
    // Cifras y títulos en SF Rounded; el resto de la app usa SF Pro. Todos escalan con Tamaño de texto dinámico.
    static let rwHeroTitle = Font.system(.title, design: .rounded, weight: .bold)
    static let rwTitle = Font.system(.title2, design: .rounded, weight: .bold)
    static let rwHeadline = Font.system(.headline, design: .rounded, weight: .semibold)
}

enum Keys {
    static let onboarded = "onboarded"
    static let notifEnabled = "notifEnabled"
    static let notifHour = "notifHour"
    static let notifMinute = "notifMinute"
    static let userName = "userName"
}

// MARK: - Botones

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(Color.rwPrimaryFill.opacity(enabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: RWRadius.button, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Botón blanco para usar sobre el degradado de la tarjeta protagonista.
struct HeroButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(Color.rwOnHero)
            .background(Color.white, in: RoundedRectangle(cornerRadius: RWRadius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

@MainActor
enum Haptics {
    static func keep() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func delete() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

// MARK: - Tarjetas y componentes

/// Tarjeta estándar: superficie del sistema + filete fino. Sin sombras (mejor rendimiento y más limpio).
struct RWCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: RWRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RWRadius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

extension View {
    func rwCard() -> some View { modifier(RWCardModifier()) }
}

/// Barra de progreso. La animación se desactiva con «Reducir movimiento».
@MainActor
struct RWProgressBar: View {
    let value: Double   // 0...1
    var fill: Color = .rwPurple
    var track: Color = Color.primary.opacity(0.12)
    var height: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = min(max(value, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill)
                    .frame(width: clamped == 0 ? 0 : max(height, geo.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progreso")
        .accessibilityValue("\(Int((clamped * 100).rounded())) por ciento")
    }
}

@MainActor
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .rwPurple
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.rwTitle).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .rwCard()
    }
}

/// Porcentaje legible: nunca "100 %" si queda algo pendiente y "<0,1 %" para valores diminutos.
func rwPercentText(_ fraction: Double, pending: Int) -> String {
    if fraction > 0 && fraction < 0.001 { return "<0,1 %" }
    if pending > 0 && fraction > 0.999 { return "99,9 %" }
    return fraction.formatted(.percent.precision(.fractionLength(0...1)))
}
