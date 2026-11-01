import SwiftUI
import UIKit

extension Color {
    static let rwPurple = Color(red: 0.66, green: 0.55, blue: 0.98)
    static let rwKeep = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let rwDelete = Color(red: 1.0, green: 0.38, blue: 0.36)
}

enum Keys {
    static let onboarded = "onboarded"
    static let notifEnabled = "notifEnabled"
    static let notifHour = "notifHour"
    static let notifMinute = "notifMinute"
    static let userName = "userName"
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(Color.rwPurple.opacity(enabled ? 1 : 0.35),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
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

@MainActor
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .rwPurple
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
