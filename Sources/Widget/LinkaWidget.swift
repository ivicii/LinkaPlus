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

private let toggleColor = Color(red: 0.20, green: 0.52, blue: 1.0)

private let tgOrange = Color(red: 1.00, green: 0.60, blue: 0.18)
private let tgGreen  = Color(red: 0.17, green: 0.83, blue: 0.42)
private let tgBackground = LinearGradient(
    colors: [Color(red: 0.141, green: 0.216, blue: 0.373),
             Color(red: 0.075, green: 0.110, blue: 0.212),
             Color(red: 0.040, green: 0.059, blue: 0.118)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

private extension View {
    /// iOS 17 adds widget content margins itself; iOS 16 needs them by hand.
    @ViewBuilder func legacyWidgetPadding() -> some View {
        if #available(iOS 17.0, *) { self } else { self.padding(14) }
    }
}

/// LINKA ring with an orange→green gradient (open ↔ closed), white shackle and a
/// small "swap" badge. One button that does what the Action button does: open
/// when locked, close when open. The widget can't see the lock; the app decides.
private struct ToggleGlyph: View {
    var size: CGFloat
    var body: some View {
        let r = size * 0.38, t = size * 0.15
        let ex = r * sin(34 * .pi / 180), ey = r * cos(34 * .pi / 180)
        let barH = t * 0.78
        let b = size * 0.36
        ZStack {
            // Stroke gradient is applied before the 90° turn: bottom→top here
            // ends up left (orange) → right (green) on screen.
            Circle().trim(from: 0.0944, to: 0.9056)
                .stroke(LinearGradient(colors: [tgOrange, tgGreen], startPoint: .bottom, endPoint: .top),
                        style: StrokeStyle(lineWidth: t, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: r * 2, height: r * 2)
            Circle().fill(.white).frame(width: t * 0.52, height: t * 0.52)
            Capsule().fill(.white.opacity(0.92))
                .frame(width: ex * 2 + barH, height: barH)
                .offset(y: ey)
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(RadialGradient(colors: [toggleColor.opacity(0.55), toggleColor.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * 0.95))
                .frame(width: size * 2, height: size * 2)
        )
        .overlay(alignment: .topTrailing) {
            ZStack {
                Circle().fill(Color(red: 0.063, green: 0.094, blue: 0.188)).frame(width: b + 6, height: b + 6)
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.63, blue: 1.0),
                                                  Color(red: 0.18, green: 0.42, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: b, height: b)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: b * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .offset(x: size * 0.07, y: -size * 0.05)
        }
    }
}

private struct WidgetCaption: View {
    var body: some View {
        Text("LINKA")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.5))
    }
}

struct LinkaToggleView: View {
    @Environment(\.widgetFamily) var family
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryBackgroundCircle()
                    Image(systemName: "lock.rotation").font(.title3.weight(.semibold))
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "lock.rotation").font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("LINKA").font(.headline)
                        Text("Open / dicht").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                HStack(spacing: 22) {
                    ToggleGlyph(size: 88).padding(.leading, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption()
                        Text("Open / dicht")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .legacyWidgetPadding()
            default:
                VStack(spacing: 0) {
                    HStack { WidgetCaption(); Spacer() }
                    Spacer(minLength: 0)
                    ToggleGlyph(size: 74)
                    Spacer(minLength: 0)
                    Text("Open / dicht")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .legacyWidgetPadding()
            }
        }
        .widgetURL(URL(string: "linkaplus://toggle"))
        .modifier(ToggleBackground(family: family))
    }
}

/// Fancy gradient for the home-screen sizes; lock-screen accessories keep the
/// system's own tinted look.
private struct ToggleBackground: ViewModifier {
    let family: WidgetFamily
    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            content.widgetBackground(Color.clear)
        default:
            content.widgetBackground(tgBackground)
        }
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

/// Kept under the original kind, so a widget already on the home screen turns
/// into the single toggle button by itself after the update.
struct LinkaControlWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaControl", provider: LinkaProvider()) { _ in LinkaToggleView() }
            .configurationDisplayName("Slot open/dicht")
            .description("Eén knop: opent als het slot dicht is, sluit als het open is.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct LinkaDualWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaDual", provider: LinkaProvider()) { _ in LinkaControlView() }
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
        LinkaDualWidget()
        LinkaUnlockWidget()
        LinkaLockWidget()
        if #available(iOS 16.1, *) { TrackingLiveActivity() }
    }
}
