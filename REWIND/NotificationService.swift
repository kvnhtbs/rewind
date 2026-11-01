import UserNotifications
import Foundation

enum NotificationService {
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Pide permiso solo si aún no se ha preguntado y el usuario tiene los recordatorios activados.
    static func requestIfNeeded() async {
        let enabled = UserDefaults.standard.object(forKey: Keys.notifEnabled) as? Bool ?? true
        if enabled, await status() == .notDetermined { _ = await requestAuthorization() }
    }

    /// Programa las notificaciones de los próximos 14 días, con el recuento real de cada día.
    /// Los días sin contenido pendiente no generan notificación.
    @MainActor
    static func reschedule(library: PhotoLibraryService, decidedIDs: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.notifEnabled) as? Bool ?? true,
              library.hasAccess,
              await status() == .authorized else { return }
        let hour = d.object(forKey: Keys.notifHour) as? Int ?? 20
        let minute = d.object(forKey: Keys.notifMinute) as? Int ?? 0
        let cal = Calendar.current
        let now = Date()

        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour; comps.minute = minute
            guard let fire = cal.date(from: comps), fire > now else { continue }
            let pending = library.refs(in: DateRules.reviewInterval(for: day))
                .filter { !decidedIDs.contains($0.id) }.count
            guard pending > 0 else { continue }

            let content = UNMutableNotificationContent()
            switch offset % 3 {
            case 0:
                content.title = "REWIND"
                content.body = "¿Qué quieres hacer con tus recuerdos de hace un año?"
            case 1:
                content.title = "Hoy toca limpiar tu galería"
                content.body = "Tienes \(pending) recuerdos pendientes."
            default:
                content.title = "Hace un año de este momento"
                content.body = "¿Lo conservamos? \(pending) elementos esperan tu decisión."
            }
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "rewind-\(offset)",
                                                        content: content, trigger: trigger))
        }
    }
}
