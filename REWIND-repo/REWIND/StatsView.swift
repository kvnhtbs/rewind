import SwiftUI
import SwiftData

@MainActor
struct StatsGrid: View {
    let stats: StatsData
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Archivos revisados", value: "\(stats.reviewed)", symbol: "eye.fill")
            StatTile(title: "Conservados", value: "\(stats.kept)", symbol: "heart.fill", color: .rwKeep)
            StatTile(title: "Eliminados", value: "\(stats.deleted)", symbol: "trash.fill", color: .rwDelete)
            StatTile(title: "Espacio liberado", value: stats.freed.byteString, symbol: "externaldrive.fill")
        }
    }
}

@MainActor
struct StatsView: View {
    @Query private var decisions: [Decision]
    var body: some View {
        let stats = StatsData(decisions: decisions)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatTile(title: "días consecutivos", value: "\(stats.streak)", symbol: "flame.fill", color: .orange)
                    HStack(spacing: 12) {
                        StatTile(title: "Fotos", value: "\(stats.photos)", symbol: "photo.fill")
                        StatTile(title: "Vídeos", value: "\(stats.videos)", symbol: "video.fill")
                    }
                    StatsGrid(stats: stats)
                    MonthCalendar(days: stats.usageDays)
                    Text("El espacio liberado solo cuenta elementos cuyo borrado confirmó iOS. Los elementos en «Eliminados recientemente» liberan espacio real al vaciar esa carpeta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Estadísticas")
        }
    }
}

@MainActor
struct MonthCalendar: View {
    let days: Set<Date>
    var body: some View {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let range = cal.range(of: .day, in: .month, for: start)!
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        VStack(alignment: .leading, spacing: 10) {
            Text(start.formatted(.dateTime.month(.wide).year()).capitalized).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 32) }
                ForEach(range, id: \.self) { day in
                    let date = cal.date(byAdding: .day, value: day - 1, to: start)!
                    let done = days.contains(date)
                    ZStack {
                        if done { Circle().fill(Color.rwPurple) }
                        Text("\(day)").font(.caption).foregroundStyle(done ? .white : .primary)
                    }
                    .frame(height: 32)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
