import Foundation

/// Reglas de fechas de REWIND.
///
/// - La selección se basa SIEMPRE en la fecha original de captura (`PHAsset.creationDate`),
///   nunca en la de modificación, usando el calendario y la zona horaria actuales del dispositivo.
/// - "Hace un año" = `Calendar.date(byAdding: .year, value: -1)`.
/// - REGLA DEL 29 DE FEBRERO:
///   1. Si hoy es 29/feb (año bisiesto), el año anterior no tiene 29/feb → se revisa el 28/feb
///      del año anterior (el calendario ajusta al último día válido). Como ese día ya se
///      revisó el 28/feb, no se vuelven a mostrar elementos ya decididos.
///   2. Para que el 29/feb de un año bisiesto no se quede sin revisar nunca, el 28/feb de un año
///      NO bisiesto cuyo año anterior fue bisiesto la sesión incluye 28 y 29 de febrero.
enum DateRules {
    static var calendar: Calendar { Calendar.current }

    static func isLeap(_ date: Date) -> Bool {
        calendar.range(of: .day, in: .year, for: date)?.count == 366
    }

    static func reviewInterval(for today: Date) -> DateInterval {
        let target = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        let start = calendar.startOfDay(for: target)
        let c = calendar.dateComponents([.month, .day], from: today)
        let days = (c.month == 2 && c.day == 28 && !isLeap(today) && isLeap(target)) ? 2 : 1
        let end = calendar.date(byAdding: .day, value: days, to: start)!
        return DateInterval(start: start, end: end)
    }

    static func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
