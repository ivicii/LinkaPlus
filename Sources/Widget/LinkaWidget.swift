import WidgetKit
import SwiftUI

struct UnlockEntry: TimelineEntry { let date: Date }

struct UnlockProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnlockEntry { UnlockEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (UnlockEntry) -> Void) {
        completion(UnlockEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UnlockEntry>) -> Void) {
        completion(Timeline(entries: [UnlockEntry(date: Date())], policy: .never))
    }
}

private let unlockGradient = LinearGradient(
    colors: [Color(red: 1.00, green: 0.56, blue: 0.0), Color(red: 0.95, green: 0.42, blue: 0.0)],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

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

struct UnlockWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 34, weight: .bold))
            Text("Ontgrendel")
                .font(.headline)
            Text("LINKA")
                .font(.caption2.weight(.semibold))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetBackground(unlockGradient)
        .widgetURL(URL(string: "linkaplus://unlock"))
    }
}

@main
struct LinkaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LinkaUnlock", provider: UnlockProvider()) { _ in
            UnlockWidgetView()
        }
        .configurationDisplayName("Ontgrendel slot")
        .description("Tik om je LINKA-slot te ontgrendelen.")
        .supportedFamilies([.systemSmall])
    }
}
