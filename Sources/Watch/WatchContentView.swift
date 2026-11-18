import SwiftUI

struct WatchContentView: View {
    @StateObject private var conn = WatchConnector.shared

    private var stateText: String {
        guard conn.ready else { return "Niet verbonden" }
        switch conn.locked {
        case true: return "Op slot"
        case false: return "Open"
        default: return "Onbekend"
        }
    }
    private var tint: Color {
        switch conn.locked {
        case true: return .green
        case false: return .orange
        default: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: conn.locked == false ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(tint)
                Text(stateText).font(.headline)
                Spacer()
                if let b = conn.battery {
                    Label("\(b)%", systemImage: "battery.50").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if conn.busy { ProgressView() }

            HStack(spacing: 8) {
                Button { conn.send("unlock") } label: {
                    Label("Open", systemImage: "lock.open.fill").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                Button { conn.send("lock") } label: {
                    Label("Sluit", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .buttonStyle(.borderedProminent)
            .disabled(conn.busy)

            Button { conn.send("status") } label: {
                Label("Vernieuw", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .onAppear { conn.activate() }
    }
}
