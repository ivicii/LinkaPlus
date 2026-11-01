import SwiftUI
import Charts

/// An interactive statistics page derived from the lock's activity history.
/// The activity chart can be grouped by hour / day / week / month, and each
/// bar is tappable to reveal its exact count.
struct StatsView: View {
    let activities: [LockActivity]
    let lockName: String
    @Environment(\.dismiss) var dismiss

    enum Gran: String, CaseIterable, Identifiable {
        case uur = "Uur", dag = "Dag", week = "Week", maand = "Maand"
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .uur: return .hour
            case .dag: return .day
            case .week: return .weekOfYear
            case .maand: return .month
            }
        }
        var count: Int {
            switch self {
            case .uur: return 24
            case .dag: return 14
            case .week: return 12
            case .maand: return 12
            }
        }
        var chartUnit: Calendar.Component {
            self == .week ? .weekOfYear : component
        }
    }

    @State private var gran: Gran = .dag
    @State private var selected: Date?
    @State private var showActivityList = false

    private struct Bucket: Identifiable { let date: Date; let count: Int; var id: Date { date } }
    private struct BatteryPoint: Identifiable { let date: Date; let pct: Int; var id: Date { date } }

    private func date(_ a: LockActivity) -> Date? {
        DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt)
    }

    // MARK: Open/close classification (language- and schema-tolerant)

    private enum Dir { case open, close, other }
    private func classify(_ a: LockActivity) -> Dir {
        let t = ((a.msg_title ?? "") + " " + (a.msg_desc ?? "")).lowercased()
        let openWords  = ["unlock", "opened", "geopend", "ontgrendeld", "open"]
        let closeWords = ["locked", "closed", "gesloten", "vergrendeld", "dicht", "slot dicht"]
        if openWords.contains(where: { t.contains($0) })  { return .open }
        if closeWords.contains(where: { t.contains($0) }) { return .close }
        if let d = a.direction {
            if d == 0 { return .open }
            if d == 1 { return .close }
        }
        return .other
    }

    private var opens: Int  { activities.filter { classify($0) == .open }.count }
    private var closes: Int { activities.filter { classify($0) == .close }.count }
    private var lastUsed: Date? { activities.compactMap(date).max() }
    private var currentBattery: Int? { activities.compactMap { $0.batteryPercent }.first { $0 > 0 } }

    // MARK: Bucketing

    private func bucketStart(_ d: Date, _ cal: Calendar) -> Date {
        switch gran {
        case .uur:   return cal.dateInterval(of: .hour, for: d)?.start ?? d
        case .dag:   return cal.startOfDay(for: d)
        case .week:  return cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
        case .maand: return cal.dateInterval(of: .month, for: d)?.start ?? d
        }
    }

    private var buckets: [Bucket] {
        let cal = Calendar.current
        var map: [Date: Int] = [:]
        for a in activities { if let d = date(a) { map[bucketStart(d, cal), default: 0] += 1 } }
        let anchor = bucketStart(Date(), cal)
        return (0..<gran.count).reversed().compactMap { off -> Bucket? in
            guard let d = cal.date(byAdding: gran.component, value: -off, to: anchor) else { return nil }
            let key = bucketStart(d, cal)
            return Bucket(date: key, count: map[key] ?? 0)
        }
    }

    private var selectedBucket: Bucket? {
        guard let selected else { return nil }
        return buckets.first { $0.date == selected }
    }

    private func axisLabel(_ d: Date) -> String {
        switch gran {
        case .uur:   return DateUtils.timeHM(d)
        case .dag:   return d.formatted(.dateTime.day().month(.abbreviated))
        case .week:  return "wk " + d.formatted(.dateTime.week())
        case .maand: return d.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func fullLabel(_ d: Date) -> String {
        switch gran {
        case .uur:   return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        case .dag:   return d.formatted(.dateTime.weekday(.wide).day().month())
        case .week:  return "Week " + d.formatted(.dateTime.week()) + " · " + d.formatted(.dateTime.day().month())
        case .maand: return d.formatted(.dateTime.month(.wide).year())
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
                tilesSection
                activitySection
                batterySection
            }
            .navigationTitle("Statistieken")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sluit") { dismiss() } } }
            .navigationDestination(isPresented: $showActivityList) { activityListView }
        }
    }

    private var activityListView: some View {
        List {
            if activities.isEmpty {
                Text("Nog geen activiteiten.").foregroundStyle(.secondary)
            } else {
                ForEach(activities) { ActivityRow(activity: $0) }
            }
        }
        .navigationTitle("Activiteiten")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var tilesSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                Button { Haptic.tap(.light); showActivityList = true } label: {
                    tile("Activiteiten", "\(activities.count)", "list.bullet", Theme.accent, tappable: true)
                }
                .buttonStyle(.plain)
                tile("Batterij", currentBattery.map { "\($0)%" } ?? "–", batteryIcon(currentBattery),
                     (currentBattery ?? 100) < Theme.batteryLowPct ? Theme.danger : Theme.locked)
                tile("Geopend", "\(opens)", "lock.open", Theme.open)
                tile("Gesloten", "\(closes)", "lock", Theme.locked)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            if let last = lastUsed {
                Text("Laatst gebruikt: \(DateUtils.absoluteWithRelative(last))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var activitySection: some View {
        Section {
            Picker("Periode", selection: $gran) {
                ForEach(Gran.allCases) { g in Text(g.rawValue).tag(g) }
            }
            .pickerStyle(.segmented)
            .onChange(of: gran) { _ in selected = nil }

            // Selected-bar callout (or hint)
            HStack {
                if let b = selectedBucket {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fullLabel(b.date)).font(.subheadline.weight(.semibold))
                        Text("\(b.count) \(b.count == 1 ? "activiteit" : "activiteiten")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                } else {
                    Label("Tik op een balk voor details", systemImage: "hand.tap")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(minHeight: 34)

            activityChart
                .frame(height: 200)
                .padding(.vertical, 4)
        } header: {
            Text("Activiteit per \(gran.rawValue.lowercased())")
        } footer: {
            Text("Wissel tussen uur, dag, week en maand. Tik op een balk voor het exacte aantal.")
        }
    }

    private var activityChart: some View {
        Chart(buckets) { b in
            BarMark(
                x: .value("Tijd", b.date, unit: gran.chartUnit),
                y: .value("Aantal", b.count)
            )
            .foregroundStyle(selected == b.date ? Theme.accent : Theme.accent.opacity(0.28))
            .cornerRadius(4)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisTick()
                if let d = value.as(Date.self) {
                    AxisValueLabel { Text(axisLabel(d)).font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        let plot = geo[proxy.plotAreaFrame]
                        let xPos = location.x - plot.origin.x
                        guard xPos >= 0, xPos <= plot.width,
                              let tapped: Date = proxy.value(atX: xPos) else { return }
                        if let nearest = buckets.min(by: {
                            abs($0.date.timeIntervalSince(tapped)) < abs($1.date.timeIntervalSince(tapped))
                        }) {
                            Haptic.tap(.light)
                            selected = (selected == nearest.date) ? nil : nearest.date
                        }
                    }
            }
        }
    }

    private var batterySection: some View {
        Section("Batterijverloop") {
            if batteryPoints.count < 2 {
                Text("Te weinig batterijgegevens voor een grafiek.").foregroundStyle(.secondary).font(.caption)
            } else {
                Chart(batteryPoints) { p in
                    AreaMark(x: .value("Tijd", p.date), y: .value("Batterij", p.pct))
                        .foregroundStyle(Theme.locked.opacity(0.12))
                    LineMark(x: .value("Tijd", p.date), y: .value("Batterij", p.pct))
                        .foregroundStyle(Theme.locked)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Tijd", p.date), y: .value("Batterij", p.pct))
                        .foregroundStyle(Theme.locked)
                        .symbolSize(50)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 160)
                .padding(.vertical, 6)
            }
        }
    }

    private func batteryIcon(_ pct: Int?) -> String {
        guard let p = pct else { return "battery.0" }
        switch p {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default:    return "battery.100"
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color,
                      tappable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(value).font(.title2.bold()).foregroundStyle(.primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                        .strokeBorder(color.opacity(0.35), lineWidth: 1)
                )
        )
    }
}
