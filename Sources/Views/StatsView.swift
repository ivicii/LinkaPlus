import SwiftUI
import Charts

/// A clean statistics page derived from the lock's activity history.
struct StatsView: View {
    let activities: [LockActivity]
    let lockName: String
    @Environment(\.dismiss) var dismiss

    private struct DayCount: Identifiable { let date: Date; let count: Int; var id: Date { date } }
    private struct BatteryPoint: Identifiable { let date: Date; let pct: Int; var id: Date { date } }

    private func date(_ a: LockActivity) -> Date? {
        DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt)
    }

    private var opens: Int { activities.filter { ($0.msg_title ?? "").localizedCaseInsensitiveContains("unlock") }.count }
    private var closes: Int { activities.filter { ($0.msg_title ?? "").localizedCaseInsensitiveContains("lock") && !($0.msg_title ?? "").localizedCaseInsensitiveContains("unlock") }.count }

    private var lastUsed: Date? { activities.compactMap(date).max() }
    private var currentBattery: Int? { activities.compactMap { $0.batteryPercent }.first { $0 > 0 } }

    private var perDay: [DayCount] {
        let cal = Calendar.current
        var buckets: [Date: Int] = [:]
        for a in activities { if let d = date(a) { buckets[cal.startOfDay(for: d), default: 0] += 1 } }
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { off -> DayCount? in
            guard let day = cal.date(byAdding: .day, value: -off, to: today) else { return nil }
            return DayCount(date: day, count: buckets[day] ?? 0)
        }
    }

    private var batteryPoints: [BatteryPoint] {
        activities.compactMap { a -> BatteryPoint? in
            guard let b = a.batteryPercent, b > 0, let d = date(a) else { return nil }
            return BatteryPoint(date: d, pct: b)
        }
        .sorted { $0.date < $1.date }
        .suffix(60).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        tile("Activiteiten", "\(activities.count)", "list.bullet", .blue)
                        tile("Batterij", currentBattery.map { "\($0)%" } ?? "–", "battery.100", (currentBattery ?? 100) < 20 ? .red : .green)
                        tile("Geopend", "\(opens)", "lock.open", .orange)
                        tile("Gesloten", "\(closes)", "lock", .indigo)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    if let last = lastUsed {
                        Text("Laatst gebruikt: \(DateUtils.absoluteWithRelative(last))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Activiteit (14 dagen)") {
                    if perDay.allSatisfy({ $0.count == 0 }) {
                        Text("Nog geen activiteit in deze periode.").foregroundStyle(.secondary).font(.caption)
                    } else {
                        Chart(perDay) { d in
                            BarMark(x: .value("Dag", d.date, unit: .day), y: .value("Aantal", d.count))
                                .foregroundStyle(.blue.gradient)
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { v in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                        .frame(height: 180)
                        .padding(.vertical, 6)
                    }
                }

                Section("Batterijverloop") {
                    if batteryPoints.count < 2 {
                        Text("Te weinig batterijgegevens voor een grafiek.").foregroundStyle(.secondary).font(.caption)
                    } else {
                        Chart(batteryPoints) { p in
                            LineMark(x: .value("Tijd", p.date), y: .value("Batterij", p.pct))
                                .foregroundStyle(.green)
                            AreaMark(x: .value("Tijd", p.date), y: .value("Batterij", p.pct))
                                .foregroundStyle(.green.opacity(0.12))
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 160)
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Statistieken")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sluit") { dismiss() } } }
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
