import WidgetKit
import SwiftUI

struct LinkaEntry: TimelineEntry { let date: Date }

struct LinkaProvider: TimelineProvider {
    func placeholder(in context: Context) -> LinkaEntry { LinkaEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (LinkaEntry) -> Void) {
        completion(LinkaEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LinkaEntry>) -> Void) {
        completion(Timeline(entries: [LinkaEntry(date: Date())], policy: .never))
    }
}

// Same flat palette as the app (orange = open, green = locked).
private let openColor   = Color(red: 1.00, green: 0.58, blue: 0.10)
private let lockedColor = Color(red: 0.15, green: 0.78, blue: 0.38)
private let ringColor   = Color(white: 0.90)
private let bgColor     = Color(red: 0.055, green: 0.067, blue: 0.09)

private extension View {
    @ViewBuilder
    func widgetBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(style, for: .widget)
        } else {
            self.background(style)
        }
    }
}

/// Flat LINKA ring (same shape as the app icon / hero).
private struct MiniLock: View {
    let locked: Bool
    let color: Color
    var size: CGFloat = 44
    var body: some View {
        let r = size * 0.38, t = size * 0.15
        let ex = r * sin(34 * .pi / 180), ey = r * cos(34 * .pi / 180)
        let barH = t * 0.78
        ZStack {
            Circle().trim(from: 0.0944, to: 0.9056)
                .stroke(ringColor, style: StrokeStyle(lineWidth: t, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: r * 2, height: r * 2)
            Circle().fill(color).frame(width: t * 0.46, height: t * 0.46)
            Capsule().fill(color)
                .frame(width: locked ? ex * 2 + barH : barH, height: barH)
                .offset(x: locked ? 0 : ex, y: ey)
        }
        .offset(y: -size * 0.03)
        .frame(width: size, height: size)
    }
}

private struct ActionTile: View {
    let lock: Bool
    var body: some View {
        let c = lock ? lockedColor : openColor
        VStack(spacing: 6) {
            MiniLock(locked: lock, color: c, size: 46)
            Text(lock ? "Sluiten" : "Openen")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.opacity(0.18)))
    }
}

/// Medium: two buttons side by side (Link works per area in medium widgets).
struct LinkaControlView: View {
    @Environment(\.widgetFamily) var family
    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 10) {
                Link(destination: URL(string: "linkaplus://unlock")!) { ActionTile(lock: false) }
                Link(destination: URL(string: "linkaplus://lock")!) { ActionTile(lock: true) }
            }
            .widgetBackground(bgColor)
        default:
            // Small widgets only support one tap target → split into two widgets.
            EmptyView().widgetBackground(bgColor)
        }
    }
}

struct LinkaSingleView: View {
    let lock: Bool
    @Environment(\.widgetFamily) var family
    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryBackgroundCircle()
                    Image(systemName: lock ? "lock.fill" : "lock.open.fill").font(.title3.weight(.semibold))
                }
            } else {
                ActionTile(lock: lock)
            }
        }
        .widgetURL(URL(string: lock ? "linkaplus://lock" : "linkaplus://unlock"))
        .widgetBackground(bgColor)
    }
}

private struct AccessoryBackgroundCircle: View {
    var body: some View {
        if #available(iOS 16.0, *) { AccessoryWidgetBackground() } else { Circle().fill(.gray.opacity(0.3)) }
    }
}

struct LinkaControlWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaControl", provider: LinkaProvider()) { _ in LinkaControlView() }
            .configurationDisplayName("Slot openen & sluiten")
            .description("Twee knoppen: openen en sluiten.")
            .supportedFamilies([.systemMedium])
    }
}

struct LinkaUnlockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaUnlock", provider: LinkaProvider()) { _ in LinkaSingleView(lock: false) }
            .configurationDisplayName("Slot openen")
            .description("Tik om je LINKA-slot te openen.")
            .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct LinkaLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaLock", provider: LinkaProvider()) { _ in LinkaSingleView(lock: true) }
            .configurationDisplayName("Slot sluiten")
            .description("Tik om je LINKA-slot te sluiten.")
            .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

// MARK: Live Activity — tracking (recovery) on the lock screen / Dynamic Island

@available(iOS 16.1, *)
struct TrackingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "bicycle.circle.fill")
                    .font(.title).foregroundStyle(Color(red: 0.20, green: 0.52, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.lockName).font(.headline).lineLimit(1)
                    Text(context.state.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let p = context.state.positionText {
                        Text(p).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 1) {
                    if let d = context.state.distanceText {
                        Text(d).font(.title3.weight(.bold).monospacedDigit())
                        Text("afstand").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(context.state.pointCount)").font(.title3.weight(.bold).monospacedDigit())
                        Text("posities").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.lockName, systemImage: "bicycle")
                        .font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.distanceText ?? "\(context.state.pointCount) pos.").font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text(context.state.statusText).font(.caption).lineLimit(1)
                        if let p = context.state.positionText {
                            Text(p).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "bicycle").foregroundStyle(Color(red: 0.20, green: 0.52, blue: 1.0))
            } compactTrailing: {
                Text(context.state.distanceText ?? "\(context.state.pointCount)").font(.caption2.weight(.bold).monospacedDigit())
            } minimal: {
                Image(systemName: "bicycle").foregroundStyle(Color(red: 0.20, green: 0.52, blue: 1.0))
            }
        }
    }
}

@main
struct LinkaWidgets: WidgetBundle {
    var body: some Widget {
        LinkaControlWidget()
        LinkaUnlockWidget()
        LinkaLockWidget()
        if #available(iOS 16.1, *) { TrackingLiveActivity() }
    }
}
